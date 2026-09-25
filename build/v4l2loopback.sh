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

key=/run/secrets/sb_leaf_key
cert=/usr/share/os4/secureboot/leaf.crt.pem
if [ -s "${key}" ]; then
  # Every flag here is load-bearing, because pkcs7_verify checks the shape of
  # the blob before it ever looks at the signature:
  #
  #   -binary        no MIME canonicalisation; the signature is over the
  #                  module's bytes as they are.
  #   (no -nodetach) detached, so the blob carries the signature alone and the
  #                  module it covers stays the file the kernel reads.
  #   -noattr        no authenticated attributes. VERIFYING_MODULE_SIGNATURE
  #                  rejects a blob outright if have_authattrs is set -- the
  #                  opposite of the firmware case, which requires them.
  #   -md sha256     what this kernel was built to check
  #                  (CONFIG_MODULE_SIG_SHA256=y on Debian's 6.12).
  #   -certfile      the leaf, which is the whole point: it gives
  #                  pkcs7_find_key something to match the signer against, and
  #                  then the leaf's authority key id is the CA's subject key
  #                  id, which is what the enrolled CA is found by.
  #
  # The default signer identifier is issuer-and-serial rather than -keyid, and
  # that has to stay the default: it is what pkcs7_find_key compares against
  # the embedded certificate. The eContentType is likewise left at openssl's
  # default of pkcs7-data, which is the only one the module case accepts.
  sig="$(mktemp)"
  openssl cms -sign -binary -noattr -md sha256 \
    -in "${ko}" \
    -signer "${cert}" -inkey "${key}" -certfile "${cert}" \
    -outform DER -out "${sig}"

  # sign-file's `-s` path skips the key and the CMS generation entirely and
  # does only the part that is tedious to reimplement: copy the module, append
  # the blob, then the 12-byte struct module_signature (id_type PKEY_ID_PKCS7,
  # big-endian length) and the "~Module signature appended~" magic. The hash
  # name and certificate are positional placeholders it never reads in this
  # mode; they are passed as written rather than as dummies so the line still
  # says what was signed and with what. scripts/ reaches it through the build
  # symlink the headers package puts under /usr/lib/modules/<ver>.
  "/usr/lib/modules/${kver}/build/scripts/sign-file" -s "${sig}" sha256 \
    "${cert}" "${ko}"
  rm -f "${sig}"
  echo "v4l2loopback: signed ${ko} for ${kver}"
else
  echo "v4l2loopback: SB_LEAF_KEY not provided -- shipping ${ko} unsigned." >&2
  echo "It will fail to load under Secure Boot lockdown until signed." >&2
fi

depmod "${kver}"
