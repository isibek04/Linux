#!/usr/bin/env bash
# Sign out-of-tree kernel modules with the Secure Boot leaf key.
#
# Usage: build/sign-module.sh <kver> <module.ko>...
#
# Shared by build/v4l2loopback.sh and build/nvidia.sh. The why -- two
# signature formats on one trust root, the leaf that has to travel inside the
# blob, `mokutil --trust-mok` on the host -- is at the top of v4l2loopback.sh;
# this is the how.
#
# Each module must be an uncompressed ELF: the signature is a trailer on the
# bytes the kernel is handed, and kmod hands it the decompressed ones, so a
# caller that wants a compressed module signs first and compresses after.
#
# The key is optional, as it is for every caller: absent, the modules are left
# unsigned and the build log says so. Exits non-zero only on a real failure.
set -euo pipefail

kver="${1:?usage: $0 <kver> <module.ko>...}"
shift

key=/run/secrets/sb_leaf_key
cert=/usr/share/os4/secureboot/leaf.crt.pem

if [ ! -s "${key}" ]; then
  for ko in "$@"; do
    echo "sign-module: SB_LEAF_KEY not provided -- shipping ${ko} unsigned." >&2
  done
  echo "Unsigned modules fail to load under Secure Boot lockdown." >&2
  exit 0
fi

sig="$(mktemp)"
trap 'rm -f "${sig}"' EXIT

for ko in "$@"; do
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
  echo "sign-module: signed ${ko} for ${kver}"
done
