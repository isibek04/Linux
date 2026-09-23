#!/usr/bin/env bash
# v4l2loopback, built by DKMS against this image's own kernel and signed with
# the Secure Boot leaf key -- the last of the "os3 has that this does not"
# rows in README.md.
#
# Two signature formats are in play and they are not the same thing.
# build/sign-uki.sh's sbsign call is an Authenticode signature over the whole
# UKI; this is a PKCS#7 signature over one .ko, made with the kernel's own
# scripts/sign-file. What they share is the trust root: shim already verifies
# the UKI by walking the leaf up to the CA every host enrols via
# usr/share/os4/secureboot/README.md's `mokutil --import`, and lockdown's
# module verification walks MOK-enrolled certificates the same way -- so a
# module signed with that same leaf key needs no second enrolment. Without a
# signature at all, a host that has enrolled the CA (and therefore has
# lockdown's module.sig_enforce engaged) refuses to load this module outright.
#
# SB_LEAF_KEY is optional here, unlike sign-uki.sh where it is required: PR
# and non-release builds still need to produce a working image, just with an
# unsigned module. Same arrangement as the sealed variant in publish.yml.
set -euo pipefail

apt-get install -y --no-install-recommends linux-headers-amd64 \
  || apt-get install -y --no-install-recommends linux-headers-generic

# dkms tries to sign every module it builds by default (Debian's dkms 3.2.2,
# unlike the shim-signed-driven scheme this used to be), auto-generating a
# throwaway MOK keypair at /var/lib/dkms/mok.{key,pub} via `openssl req` the
# first time it finds those files missing. That key would be real, would
# land in this layer's diff, and would still be sitting in the pushed image
# even after bootc-rootfs.sh empties /var in a later layer -- OCI layers are
# additive history, not a final state. Pre-creating both files empty makes
# dkms find them already present and skip generation, so the attempt fails on
# a garbage key deterministically -- not by accident of whether some other
# package happened to pull in the openssl binary by the time this step runs.
# The real signature, below, replaces this failed one entirely.
mkdir -p /var/lib/dkms
touch /var/lib/dkms/mok.key /var/lib/dkms/mok.pub

# The package's own postinst runs `dkms install` against every kernel it
# finds headers for, which is the one just installed above -- this is what
# actually builds the module. v4l2loopback-utils is the Suggests that makes
# the loopback devices configurable (v4l2loopback-ctl) rather than fixed at
# whatever the module's default is.
apt-get install -y v4l2loopback-dkms v4l2loopback-utils

kdirs=(/usr/lib/modules/*)
[ "${#kdirs[@]}" -eq 1 ] || {
  echo "v4l2loopback: expected exactly one kernel under /usr/lib/modules, found: ${kdirs[*]}" >&2
  exit 1
}
kver="$(basename "${kdirs[0]}")"

ko="$(find "/usr/lib/modules/${kver}/updates/dkms" -name 'v4l2loopback.ko*' -print -quit)"
[ -n "${ko}" ] || {
  echo "v4l2loopback: dkms did not install a module for ${kver}" >&2
  exit 1
}

# Shipped uncompressed rather than matching dkms's own .xz: signing has to
# happen on the raw ELF (the signature is a trailer on the actual bytes the
# kernel loads), and re-compressing one ~200 KiB module afterward is not
# worth reproducing dkms's compression settings for.
case "${ko}" in
  *.xz) unxz "${ko}"; ko="${ko%.xz}" ;;
  *.zst) unzstd --rm "${ko}"; ko="${ko%.zst}" ;;
  *.gz) gunzip "${ko}"; ko="${ko%.gz}" ;;
esac

key=/run/secrets/sb_leaf_key
if [ -s "${key}" ]; then
  # scripts/sign-file lives under the headers' build symlink -- see
  # build/uki-build.sh's comment on the same tool for why sbsign was not
  # reused here instead: shim's chain-walk story applies to the UKI, not to
  # module verification, but the hash algorithm still has to match what the
  # kernel was built to check (CONFIG_MODULE_SIG_HASH=sha256 on this kernel).
  "/usr/lib/modules/${kver}/build/scripts/sign-file" sha256 \
    "${key}" /usr/share/os4/secureboot/leaf.crt.pem "${ko}"
  echo "v4l2loopback: signed ${ko} for ${kver}"
else
  echo "v4l2loopback: SB_LEAF_KEY not provided -- shipping ${ko} unsigned." >&2
  echo "It will fail to load under Secure Boot lockdown until signed." >&2
fi

depmod "${kver}"
