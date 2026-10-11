#!/usr/bin/env bash
# Prove a sealed image can be installed, before it is published.
#
# Usage: build/verify-sealed.sh <image-ref>
#
# `bootc install` and `bootc switch` refuse a sealed image whose UKI carries a
# composefs= digest that does not match the digest they compute from the image
# itself:
#
#   error: Switching: ... Setting up UKI boot: Writing <kver>.efi to ESP:
#   The UKI has the wrong composefs= parameter (is '02e186...', should be
#   '936f0e...')
#
# Nothing in the build catches that, and the first thing to notice is a
# machine that will not take the update. So this runs the host's half of that
# comparison against the finished image, and when the two disagree it prints
# which paths differ -- build/uki-build.sh leaves a dumpfile of what it hashed
# in /boot/os4, the same shape is computed here, and the two diff line for
# line. That diff is what identified the mtime truncation the sealed variant
# was built around; see the Containerfile.
#
# The image supplies its own bootc, so nothing has to be installed to run this
# beyond podman.
#
# Not free: hashing writes every file object into a throwaway composefs repo,
# so budget image-sized free space under TMPDIR, defaulting to /var/tmp.
set -euo pipefail

image="${1:-}"
[ -n "${image}" ] || { echo "usage: $0 <image-ref>" >&2; exit 2; }

# podman reads containers.conf out of the home directory, and a CI runner may
# start the job with HOME unset.
export HOME="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"

scratch="$(mktemp -d "${TMPDIR:-/var/tmp}/os4-verify-XXXXXX")"
mkdir -p "${scratch}/repo" "${scratch}/out"
# shellcheck disable=SC2329 # Invoked by the trap below.
cleanup() { rm -rf "${scratch}" 2>/dev/null || true; }
trap cleanup EXIT

# --------------------------------------------------------------------------
# What a host will compute from the image
# --------------------------------------------------------------------------
# bootc comes from the image under test; the store it reads is the one podman
# already keeps the image in. Two of these are not obvious:
#
#   --privileged  c/storage remounts the store's overlay directory when it
#                 opens it, which an unprivileged container cannot do
#                 ("remount /var/lib/containers/storage/overlay: operation not
#                 permitted"). This is the mode bootc documents for reading a
#                 host store from inside a container.
#   /var/tmp      bootc hashes into a throwaway composefs repo there, and the
#                 repo wants O_TMPFILE, which the container's own overlay
#                 layer does not support ("Operation not supported (os error
#                 95)"). /var is also empty in a bootc image until
#                 systemd-tmpfiles fills it at boot, and a container never
#                 boots, so the directory has to come from outside regardless.
store="$(dirname "$(podman info --format '{{.Store.GraphRoot}}')")"

# Once per EROFS format, because the UKI carries both (see below) and bootc
# checks every digest it finds. V1 is the preferred one and the one
# uki-build.sh wrote its dumpfile for, so it gets the dumpfile here too. The
# two runs are sequential, so the throwaway repo never needs room for two.
digest_of() {
  podman run --rm --privileged \
    --volume "${store}:/var/lib/containers" \
    --volume "${scratch}/repo:/var/tmp" \
    --volume "${scratch}/out:/verify" \
    "${image}" \
    bootc container compute-composefs-digest-from-storage "${image}" "$@"
}

echo "Computing the composefs digests of ${image}"
expected_v1="$(digest_of --erofs-version v1 --write-dumpfile-to /verify/installed.dump)"
expected_v2="$(digest_of --erofs-version v2)"

# --------------------------------------------------------------------------
# What the UKI was sealed against
# --------------------------------------------------------------------------
# Read out of the image rather than out of the build log: this is the number
# the signed UKI carries, extracted from its .cmdline section by
# build/uki-build.sh. The section is NUL-padded. Since bootc 1.17 `ukify`
# writes two kargs: `composefs.digest=v1-sha512-12:<hex>` for the V1 EROFS
# format it now prefers, and `composefs=<hex>` for V2, kept for older bootc
# clients. Either may carry a leading `?` meaning fsverity may be missing.
#
# `|| true` because pipefail would otherwise abort here with nothing said but
# the shell's own error, and an image built before /boot/os4 existed is a case
# worth naming rather than dying on.
cmdline="$(podman run --rm "${image}" sh -c 'cat /boot/os4/*.cmdline' | tr -d '\0')" || true
actual_v1="$(printf '%s' "${cmdline}" | tr ' ' '\n' \
  | sed -n 's/^composefs\.digest=?\{0,1\}v1-sha512-12://p')"
actual_v2="$(printf '%s' "${cmdline}" | tr ' ' '\n' | sed -n 's/^composefs=?\{0,1\}//p')"

[ -n "${actual_v1}" ] || {
  echo "verify-sealed: no composefs.digest= karg found in ${image}." >&2
  echo "The build records it at /boot/os4/<kver>.cmdline; an image built before" >&2
  echo "that existed, or with a bootc older than 1.17, cannot be verified, only" >&2
  echo "rebuilt. Read: '${cmdline}'" >&2
  exit 1
}

echo "UKI sealed against: v1 ${actual_v1}"
echo "                    v2 ${actual_v2:-(none)}"
echo "Image hashes to:    v1 ${expected_v1}"
echo "                    v2 ${expected_v2}"

# A missing V2 karg is fine -- bootc only checks the digests that are there.
if [ "${actual_v1}" = "${expected_v1}" ] \
   && { [ -z "${actual_v2}" ] || [ "${actual_v2}" = "${expected_v2}" ]; }; then
  echo "verify-sealed: ${image} is installable."
  exit 0
fi

# --------------------------------------------------------------------------
# Disagreement: say what differs, not just that something does
# --------------------------------------------------------------------------
echo >&2
echo "verify-sealed: ${image} would be refused at install time." >&2
podman run --rm --volume "${scratch}/out:/verify" "${image}" \
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
