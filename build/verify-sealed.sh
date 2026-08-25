#!/usr/bin/env bash
# Prove a sealed image can be installed, before it is published.
#
# `bootc install` and `bootc switch` refuse a sealed image whose UKI carries a
# composefs= digest that does not match the digest they compute from the image
# itself:
#
#   error: Switching: ... Setting up UKI boot: Writing <kver>.efi to ESP:
#   The UKI has the wrong composefs= parameter (is '02e186...', should be
#   '936f0e...')
#
# Nothing in the build catches that. The digest baked into the UKI is computed
# inside the builder, over a bind-mounted snapshot of the split stage; the
# digest a host computes comes from the layers that were committed and pushed.
# Those are meant to be the same tree, and when they are not, the first thing
# to notice is a machine that will not take the update.
#
# So this runs the host's half of that comparison against the finished image,
# and when the two disagree it prints which paths differ -- the build leaves a
# dumpfile of what it hashed in /boot/os4 (see build/uki-build.sh), and the
# same shape is computed here, so the two diff line for line.
#
# Usage: build/verify-sealed.sh <image-ref>
#        ENGINE=podman build/verify-sealed.sh <image-ref>
#
# The image supplies its own bootc and skopeo, so nothing has to be installed
# to run this beyond the container engine -- and under docker, skopeo, because
# the image has to be copied into containers-storage first: bootc reads images
# through skopeo, which cannot see the docker daemon's graph.
#
# Not free. Budget image-sized free space twice over: once for that copy, once
# for the throwaway composefs repo the digest is hashed into. The repo goes
# under TMPDIR, defaulting to /var/tmp.
set -euo pipefail

image="${1:-}"
[ -n "${image}" ] || { echo "usage: $0 <image-ref>" >&2; exit 2; }
engine="${ENGINE:-docker}"

# containers-storage lives under /var/lib, which the runner user may not own.
# Same idiom the workflow uses for apt.
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

# Not mktemp's default /tmp: this holds a copy of the image, and /tmp is a
# tmpfs on plenty of machines.
scratch="$(mktemp -d "${TMPDIR:-/var/tmp}/os4-verify-XXXXXX")"
mkdir -p "${scratch}/repo" "${scratch}/out"

# shellcheck disable=SC2329 # Invoked by the trap below.
cleanup() {
  # The repo is written by root inside the container, so a non-root caller may
  # need help removing it. Best effort either way.
  rm -rf "${scratch}" 2>/dev/null || ${SUDO} rm -rf "${scratch}" 2>/dev/null || true
  [ -n "${copied:-}" ] && ${SUDO} skopeo delete "containers-storage:${image}" >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

# --------------------------------------------------------------------------
# What a host will compute from the image
# --------------------------------------------------------------------------
# podman already keeps its images in containers-storage; docker does not.
case "${engine}" in
  docker)
    echo "Copying ${image} into containers-storage, where bootc can read it"
    ${SUDO} skopeo copy --quiet "docker-daemon:${image}" "containers-storage:${image}"
    copied=1
    store=/var/lib/containers
    ;;
  podman)
    store="$(dirname "$(podman info --format '{{.Store.GraphRoot}}')")"
    ;;
  *)
    echo "verify-sealed: unknown ENGINE '${engine}' (expected docker or podman)" >&2
    exit 2
    ;;
esac

# bootc and skopeo both come from the image under test. Two of these mounts are
# not obvious:
#
#   --privileged  c/storage remounts the store's overlay directory when it
#                 opens it, which an unprivileged container cannot do
#                 ("remount /var/lib/containers/storage/overlay: operation not
#                 permitted"). This is the mode bootc documents for reading a
#                 host store from inside a container.
#   /var/tmp      bootc hashes into a throwaway composefs repo there, and the
#                 repo wants O_TMPFILE, which the container's own overlay layer
#                 does not support ("Operation not supported (os error 95)").
#                 /var is also empty in a bootc image until systemd-tmpfiles
#                 fills it at boot, and a container never boots, so the
#                 directory has to come from outside regardless.
echo "Computing the composefs digest of ${image}"
expected="$("${engine}" run --rm --privileged \
  --volume "${store}:/var/lib/containers" \
  --volume "${scratch}/repo:/var/tmp" \
  --volume "${scratch}/out:/verify" \
  "${image}" \
  bootc container compute-composefs-digest-from-storage "${image}" \
    --write-dumpfile-to /verify/installed.dump)"

# --------------------------------------------------------------------------
# What the UKI was sealed against
# --------------------------------------------------------------------------
# Read out of the image rather than out of the build log: this is the number
# the signed UKI carries, extracted from its .cmdline section by
# build/uki-build.sh. The section is NUL-padded, and the karg is `composefs=`
# with an optional leading `?` meaning fsverity may be missing.
cmdline="$("${engine}" run --rm "${image}" sh -c 'cat /boot/os4/*.cmdline' | tr -d '\0')"
actual="$(printf '%s' "${cmdline}" | tr ' ' '\n' | sed -n 's/^composefs=?\{0,1\}//p')"

[ -n "${actual}" ] || {
  echo "verify-sealed: no composefs= karg in the UKI cmdline: '${cmdline}'" >&2
  exit 1
}

echo "UKI sealed against: ${actual}"
echo "Image hashes to:    ${expected}"

if [ "${actual}" = "${expected}" ]; then
  echo "verify-sealed: ${image} is installable."
  exit 0
fi

# --------------------------------------------------------------------------
# Disagreement: say what differs, not just that something does
# --------------------------------------------------------------------------
echo >&2
echo "verify-sealed: ${image} would be refused at install time." >&2
"${engine}" run --rm --volume "${scratch}/out:/verify" "${image}" \
  sh -c 'zcat /boot/os4/*.composefs-dump.gz > /verify/built.dump' || {
    echo "verify-sealed: the image carries no build-side dumpfile to compare" >&2
    exit 1
  }

# Both dumpfiles describe the tree after the same transform, so they line up
# entry for entry. Truncated: a genuinely different rootfs would otherwise
# print a quarter of a million lines.
echo >&2
echo "--- what the build hashed (/boot/os4), +++ what the image hashes to" >&2
diff "${scratch}/out/built.dump" "${scratch}/out/installed.dump" | head -n 60 >&2 || true
differing="$(diff "${scratch}/out/built.dump" "${scratch}/out/installed.dump" | grep -c '^[<>]' || true)"
echo >&2
echo "verify-sealed: ${differing} differing dumpfile lines in total." >&2
exit 1
