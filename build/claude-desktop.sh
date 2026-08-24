#!/usr/bin/env bash
# Anthropic's apt repository, and the Claude desktop app from it.
#
# The first third-party repo in this image, so it is also the first signing key
# that is not Debian's. The key is pinned to the fingerprint Anthropic
# documents and the build fails on a mismatch: a keyring baked into an OS image
# authorises root-owned packages on every host that boots it, and "whatever
# downloads.claude.ai served at build time" is not a trust decision worth
# making silently five builds from now.
#
# CLAUDE_DESKTOP_ADD_REPO=false because the package registers the repository
# itself, as /etc/apt/sources.list.d/claude-desktop.list. This image writes its
# own deb822 entry in the style apt-sources.sh established, and two entries for
# one repo make apt warn on every update.
#
# Linux support is a beta at the time of writing, and Computer Use, dictation
# and the Wayland global hotkey are not in it. Debian 12+ on amd64/arm64 is
# what upstream tests; trixie is 13.
set -euo pipefail

fingerprint=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
keyring=/usr/share/keyrings/claude-desktop-archive-keyring.asc

curl --proto '=https' --tlsv1.2 -fsSLo "${keyring}" \
  https://downloads.claude.ai/claude-desktop/key.asc

# --with-colons rather than parsing the human-readable form: the fpr record's
# tenth field is the fingerprint, with no spaces to strip.
got="$(gpg --show-keys --with-colons "${keyring}" \
       | awk -F: '$1 == "fpr" { print $10; exit }')"
if [ "${got}" != "${fingerprint}" ]; then
  echo "claude-desktop: signing key is not the documented one, refusing to continue" >&2
  echo "  expected ${fingerprint}" >&2
  echo "  got      ${got:-<no OpenPGP data in the downloaded file>}" >&2
  exit 1
fi

install -d /etc/default
cat > /etc/default/claude-desktop <<'EOF'
# This image registers Anthropic's apt repository itself, as
# /etc/apt/sources.list.d/claude-desktop.sources. Keep the package from adding
# a second entry for the same repo.
CLAUDE_DESKTOP_ADD_REPO="false"
EOF

cat > /etc/apt/sources.list.d/claude-desktop.sources <<EOF
Types: deb
URIs: https://downloads.claude.ai/claude-desktop/apt/stable
Suites: stable
Components: main
Architectures: amd64 arm64
Signed-By: ${keyring}
EOF

apt-get update
apt-get install -y claude-desktop
