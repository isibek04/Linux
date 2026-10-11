#!/usr/bin/env bash
# v4l2loopback, built by DKMS against this image's own kernel and signed with
# the Secure Boot leaf key -- the last of the "os3 has that this does not"
# rows in README.md.
#
# Two signature formats are in play and they are not the same thing.
# build/sign-uki.sh's sbsign call is an Authenticode signature over the whole
# UKI; this is a PKCS#7 signature over one .ko. What they share is the trust
# root -- the CA every host enrols via usr/share/os4/secureboot/README.md --
# but they reach it by different routes, and the module route has two
# constraints the UKI route does not. Without a signature that satisfies both,
# a host that has enrolled the CA (and therefore has lockdown's
# module.sig_enforce engaged) refuses to load this module outright.
#
# First, the chain has to travel with the signature. shim walks from the leaf
# up to the enrolled CA because `sbsign --addcert` puts the CA in the UKI's
# certificate table. The kernel walks a chain too -- pkcs7_validate_trust_one
# tries the last chain certificate's authority key id against the keyring --
# but only over certificates carried inside the PKCS#7 blob, and the kernel's
# own scripts/sign-file signs with CMS_NOCERTS: the blob it emits holds
# nothing but the leaf's issuer-and-serial. Against a keyring holding only the
# CA that is an immediate -ENOKEY, because the serial named in the blob is the
# leaf's and the CA's key is indexed under its own. So the blob is built below
# with `openssl cms -certfile`, which embeds the leaf, and sign-file is used
# only through `-s` to append the trailer the kernel looks for.
#
# Second, `mokutil --import` alone does not put the CA anywhere module
# verification looks. MOK certificates land in .platform, which covers kexec
# and not modules; they reach .machine -- and through it
# .secondary_trusted_keys, which is the keyring module verification searches --
# only once MokListTrustedRT exists, which is what `mokutil --trust-mok` sets.
# That is a host-side step, documented next to the import in
# usr/share/os4/secureboot/README.md.
#
# SB_LEAF_KEY is optional here, unlike sign-uki.sh where it is required: PR
# and non-release builds still need to produce a working image, just with an
# unsigned module. Same arrangement as the sealed variant in publish.yml.
set -euo pipefail

apt-get install -y --no-install-recommends linux-headers-amd64 \
  || apt-get install -y --no-install-recommends linux-headers-generic

# openssl is named here rather than relied on. The signing step below needs
# the binary, and something earlier in the Containerfile happens to pull it in
# today -- which is exactly the kind of dependency that breaks quietly when an
# unrelated package step is reordered. Same reasoning as the empty mok files
# just below: make the outcome follow from this script, not from the order of
# the ones around it.
apt-get install -y --no-install-recommends openssl

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

# build/sign-module.sh holds the openssl and sign-file calls, shared with
# build/nvidia.sh; without a key it leaves the module unsigned and says so.
/tmp/build/sign-module.sh "${kver}" "${ko}"

depmod "${kver}"
