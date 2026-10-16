#!/usr/bin/env bash
# Microsoft's apt repository, and Visual Studio Code from it.
#
# The fourth vendor repository in this image, on the four steps
# claude-desktop.sh established: fetch the key, pin its fingerprint, write a
# deb822 entry, install. The fingerprint is the one Microsoft documents for its
# "Microsoft (Release signing)" key, which signs every packages.microsoft.com
# repository, not just this one -- so the keyring is referenced by this one
# source entry alone and authorises nothing else.
#
# Trixie's apt verifies with sqv, which has rejected SHA-1 user-ID bindings
# since 2026-02-01 and is why nvidia.sh needs gpgv. This key's binding is
# SHA-256 and the repository verifies under sqv as it is, so nothing here
# reaches for that workaround.
#
# The package's postinst registers the repository itself, as
# /etc/apt/sources.list.d/vscode.sources, with its own dearmoured copy of the
# key at /usr/share/keyrings/microsoft.gpg -- unless debconf says
# code/add-microsoft-repo is false, in which case it writes neither. That is
# preseeded below, before the install. The entry is also named
# vscode-os4.sources rather than vscode.sources: the postinst "refreshes" a
# file by that exact name whenever it finds one, Chrome's way, and separately
# skips writing any entry when another file already points at the repository.
# Either guard alone would do; the debconf answer is the one that also keeps
# the second keyring off the image.
#
# `code`, not `code-insiders`: the stable channel. The .deb is pure /usr --
# the tree under /usr/share/code, a desktop file, completions, a mime type --
# so there is nothing in /opt for bootc-rootfs.sh to fold and nothing under
# /var. chrome-sandbox ships without the setuid bit and is not needed: Debian
# allows unprivileged user namespaces, which is the sandbox Electron uses
# instead. The postinst also registers `code` as an `editor` alternative at
# priority 0, which never makes it the default in auto mode.
set -euo pipefail

fingerprint=BC528686B50D79E339D3721CEB3E94ADBE1229CF
keyring=/usr/share/keyrings/vscode-archive-keyring.asc

curl --proto '=https' --tlsv1.2 -fsSLo "${keyring}" \
  https://packages.microsoft.com/keys/microsoft.asc

# --with-colons rather than parsing the human-readable form: the fpr record's
# tenth field is the fingerprint, with no spaces to strip. `exit` after the
# first match, as in the other vendor scripts.
got="$(gpg --show-keys --with-colons "${keyring}" \
       | awk -F: '$1 == "fpr" { print $10; exit }')"
if [ "${got}" != "${fingerprint}" ]; then
  echo "vscode: signing key is not the documented one, refusing to continue" >&2
  echo "  expected ${fingerprint}" >&2
  echo "  got      ${got:-<no OpenPGP data in the downloaded file>}" >&2
  exit 1
fi

echo 'code code/add-microsoft-repo boolean false' | debconf-set-selections

cat > /etc/apt/sources.list.d/vscode-os4.sources <<EOF
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64 arm64
Signed-By: ${keyring}
EOF

apt-get update
apt-get install -y code

# The postinst should have written neither of these; fail rather than ship a
# second, unpinned entry for the same repository if a later release stops
# honouring the debconf answer.
for leftover in /etc/apt/sources.list.d/vscode.sources \
                /etc/apt/sources.list.d/vscode.list \
                /usr/share/keyrings/microsoft.gpg; do
  if [ -e "${leftover}" ]; then
    echo "vscode: the package wrote ${leftover} despite debconf, refusing to continue" >&2
    exit 1
  fi
done
