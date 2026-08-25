#!/usr/bin/env bash
# Build and sign the UKI for the sealed image variant.
#
# Runs in the Containerfile's `uki` tools stage, whose RUN line provides:
#
#   /target                  the split rootfs, bind-mounted read-only
#   /kernel/<kver>/          vmlinuz + initramfs.img, split out of it
#   /run/secrets/sb_leaf_key the leaf private key, a BuildKit secret --
#                            mounted for this one RUN and never a layer
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
# Both certificates are read from the rootfs itself: the repo commits them
# under usr/share/os4/secureboot, so they are already in /target and CI has
# nothing to provide beyond the key.
set -euo pipefail

readonly BOOTC=/output/usr/bin/bootc
readonly CERTS=/target/usr/share/os4/secureboot
readonly KEY=/run/secrets/sb_leaf_key

[ -s "${KEY}" ] || {
  echo "uki-build: /run/secrets/sb_leaf_key is missing or empty." >&2
  echo "Build the sealed target with: --secret id=sb_leaf_key,env=SB_LEAF_KEY" >&2
  exit 1
}
for f in "${CERTS}/leaf.crt.pem" "${CERTS}/ca.crt.pem"; do
  [ -s "${f}" ] || { echo "uki-build: ${f} missing from the rootfs" >&2; exit 1; }
done

# Exactly one kernel: the split stage extracted whatever initramfs.sh
# prepared, and two kernels would mean the image build changed shape.
kdirs=(/kernel/*)
[ "${#kdirs[@]}" -eq 1 ] || {
  echo "uki-build: expected exactly one kernel under /kernel, found: ${kdirs[*]}" >&2
  exit 1
}
kver="$(basename "${kdirs[0]}")"
echo "Building UKI for ${kver}"

mkdir -p /out
unsigned="$(mktemp -d)/unsigned.efi"

"${BOOTC}" container ukify \
  --rootfs /target \
  --kernel-dir "/kernel/${kver}" \
  -- \
  --output "${unsigned}"

sbsign \
  --key "${KEY}" \
  --cert "${CERTS}/leaf.crt.pem" \
  --addcert "${CERTS}/ca.crt.pem" \
  --output "/out/${kver}.efi" \
  "${unsigned}"
rm -f "${unsigned}"

# Verified against the CA, not the leaf: sbverify treats --cert as the trust
# anchor for a chain walk, which both matches what shim will do against the
# MOK-enrolled CA and fails on a leaf (not self-signed, so no chain ever
# terminates at it). What this still cannot prove is shim's own walk on real
# firmware -- that is what the VM test with OVMF is for.
sbverify --cert "${CERTS}/ca.crt.pem" "/out/${kver}.efi"
echo "Signed UKI at /out/${kver}.efi"
