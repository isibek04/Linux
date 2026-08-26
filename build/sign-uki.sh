#!/usr/bin/env bash
# Build and sign the sealed variant's UKI, outside the image build.
#
# Usage: SB_LEAF_KEY="$(cat leaf.key)" build/sign-uki.sh <split-image> <tools-image> [outdir]
#
# The result is a /boot overlay in outdir (default uki-out/), which the
# Containerfile's `sealed` stage copies in with one COPY:
#
#   uki-out/EFI/Linux/<kver>.efi   the signed UKI
#   uki-out/os4/<kver>.cmdline     what it was sealed against
#   uki-out/os4/<kver>.composefs-dump.gz
#
# This exists because the digest inside the UKI must be computed over the
# split image as committed, not over the builder's live filesystem -- tar
# stores mtimes to the second, a filesystem to the nanosecond, and a digest
# taken over the latter matches nothing a host will ever compute. The
# Containerfile tells that story in full above its uki-tools stage.
#
# `--mount type=image` is what makes it cheap: podman mounts the split image
# from its own layers straight into the tools container, so the tree seen at
# /target is the tree a host unpacks, with the timestamps it will have. No
# copy, no `podman image mount` and no user namespace to arrange around it.
set -euo pipefail

split_image="${1:-}"
tools_image="${2:-}"
outdir="${3:-uki-out}"

if [ -z "${split_image}" ] || [ -z "${tools_image}" ]; then
  echo "usage: SB_LEAF_KEY=... $0 <split-image> <tools-image> [outdir]" >&2
  exit 2
fi
[ -n "${SB_LEAF_KEY:-}" ] || {
  echo "sign-uki: SB_LEAF_KEY is unset -- nothing to sign with." >&2
  exit 2
}

# podman reads containers.conf out of the home directory, and forgejo-runner
# starts the job with HOME unset.
export HOME="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"

# Not mktemp's default /tmp: the digest is computed into a throwaway composefs
# repo the size of the image, and /tmp is a tmpfs on plenty of machines.
scratch="$(mktemp -d "${TMPDIR:-/var/tmp}/os4-uki-XXXXXX")"
# The key never touches the image and never becomes a layer: it is written to
# a private file for the length of one container run.
keydir="$(mktemp -d)"
chmod 700 "${keydir}"
cleanup() { rm -rf "${keydir}" "${scratch}"; }
# shellcheck disable=SC2329 # Invoked by the trap below.
trap cleanup EXIT
printf '%s\n' "${SB_LEAF_KEY}" > "${keydir}/sb_leaf_key"
chmod 600 "${keydir}/sb_leaf_key"

rm -rf "${outdir}"
mkdir -p "${outdir}"

podman run --rm \
  --mount "type=image,source=${split_image},destination=/target,rw=false" \
  --volume "$(realpath "${outdir}"):/out" \
  --volume "${scratch}:/var/tmp" \
  --volume "${keydir}/sb_leaf_key:/run/secrets/sb_leaf_key:ro" \
  "${tools_image}" \
  uki-build

echo "sign-uki: ${outdir} holds:"
find "${outdir}" -type f -printf '  %p (%s bytes)\n'
