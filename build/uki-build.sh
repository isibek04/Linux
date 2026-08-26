#!/usr/bin/env bash
# Build and sign the UKI for the sealed image variant.
#
# Runs inside the Containerfile's `uki-tools` stage, as a container rather
# than as a build step -- build/sign-uki.sh is what starts it, and the
# Containerfile explains at length why this cannot be a RUN. The short of it:
# the composefs digest sealed into the UKI has to be computed over the split
# image as *committed*, because tar has no sub-second mtime field and a
# builder's live filesystem does. So /target below is the split image mounted
# from its own layers, not a stage snapshot.
#
# What the caller provides:
#
#   /target                  the split image, mounted read-only
#   /out                     an empty directory, filled as a /boot overlay
#   /var/tmp                  a real filesystem, image-sized: the digest is
#                            computed into a throwaway composefs repo there,
#                            and a container's overlay layer supports neither
#                            the space nor O_TMPFILE
#   /run/secrets/sb_leaf_key the leaf private key
#
# `bootc container ukify` computes the composefs digest of /target, collects
# kargs from /target/usr/lib/bootc/kargs.d, and hands both to the real ukify
# as the embedded cmdline. Signing is NOT left to ukify, deliberately:
# ukify's --secureboot-* options sign with the one certificate they are
# given, and shim can only verify our leaf-signed UKI by walking the chain
# up to the MOK-enrolled CA -- which requires the chain to be embedded in
# the Authenticode signature. sbsign's --addcert is what does that, so the
# UKI is built unsigned and signed in a second step.
#
# Both certificates are read from the image itself: the repo commits them
# under usr/share/os4/secureboot, so they are already in /target and CI has
# nothing to provide beyond the key.
#
# Two by-products land in /out/os4, for build/verify-sealed.sh and for whoever
# has to debug the next digest mismatch:
#
#   <kver>.composefs-dump.gz  the measured tree exactly as it was hashed here
#   <kver>.cmdline            the cmdline read back out of the signed UKI
#
# The dumpfile is what turns "the digests differ" into "these paths differ":
# `bootc container compute-composefs-digest-from-storage --write-dumpfile-to`
# produces the same shape from a finished image, so the two diff line for
# line. It is how the mtime truncation above was found. The cmdline is read
# back with objcopy rather than remembered from the digest computed here, so
# what is recorded is what the signed artifact actually carries.
set -euo pipefail

readonly BOOTC=/output/usr/bin/bootc
readonly CERTS=/target/usr/share/os4/secureboot
readonly KEY=/run/secrets/sb_leaf_key

[ -d /target/usr ] || {
  echo "uki-build: /target does not look like a rootfs -- mount the split" >&2
  echo "image there with --mount type=image. See build/sign-uki.sh." >&2
  exit 1
}
[ -s "${KEY}" ] || {
  echo "uki-build: ${KEY} is missing or empty." >&2
  echo "Provide the leaf key: SB_LEAF_KEY=... build/sign-uki.sh ..." >&2
  exit 1
}
for f in "${CERTS}/leaf.crt.pem" "${CERTS}/ca.crt.pem"; do
  [ -s "${f}" ] || { echo "uki-build: ${f} missing from the image" >&2; exit 1; }
done

# Exactly one kernel: the split stage extracted whatever initramfs.sh
# prepared, and two kernels would mean the image build changed shape.
kdirs=(/target/kernel/*)
[ "${#kdirs[@]}" -eq 1 ] || {
  echo "uki-build: expected exactly one kernel under /target/kernel, found: ${kdirs[*]}" >&2
  exit 1
}
kver="$(basename "${kdirs[0]}")"
echo "Building UKI for ${kver}"

mkdir -p /out/EFI/Linux /out/os4
unsigned="$(mktemp -d)/unsigned.efi"

"${BOOTC}" container ukify \
  --rootfs /target \
  --kernel-dir "/target/kernel/${kver}" \
  --write-dumpfile-to "/out/os4/${kver}.composefs-dump" \
  -- \
  --output "${unsigned}"

sbsign \
  --key "${KEY}" \
  --cert "${CERTS}/leaf.crt.pem" \
  --addcert "${CERTS}/ca.crt.pem" \
  --output "/out/EFI/Linux/${kver}.efi" \
  "${unsigned}"
rm -f "${unsigned}"

# Verified against the CA, not the leaf: sbverify treats --cert as the trust
# anchor for a chain walk, which both matches what shim will do against the
# MOK-enrolled CA and fails on a leaf (not self-signed, so no chain ever
# terminates at it). What this still cannot prove is shim's own walk on real
# firmware -- that is what the VM test with OVMF is for.
sbverify --cert "${CERTS}/ca.crt.pem" "/out/EFI/Linux/${kver}.efi"
echo "Signed UKI at /out/EFI/Linux/${kver}.efi"

# The .cmdline section of the signed UKI, which is the number a host will hold
# the image to. Left as the raw section content, NUL padding and all; the
# reader strips it.
objcopy -O binary --only-section=.cmdline \
  "/out/EFI/Linux/${kver}.efi" "/out/os4/${kver}.cmdline"
echo "UKI cmdline: $(tr -d '\0' < "/out/os4/${kver}.cmdline")"

# A quarter of a million lines of text, and every sealed image would otherwise
# carry it uncompressed.
gzip -9 "/out/os4/${kver}.composefs-dump"
