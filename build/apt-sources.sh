#!/usr/bin/env bash
# Point apt at the components this image needs.
#
# contrib and non-free-firmware on top of main: the firmware blobs a laptop
# needs to bring up its wifi and its GPU live in non-free-firmware, and Debian's
# stock image enables main only. non-free itself is deliberately left out --
# nothing in the Containerfile comes from it.
#
# Written as a script rather than inline in the Containerfile because a
# multi-line heredoc inside RUN needs BuildKit, and the CI runner builds with
# whatever docker it has.
set -euo pipefail

suite="${DEBIAN_SUITE:-trixie}"

rm -f /etc/apt/sources.list
cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: ${suite} ${suite}-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: ${suite}-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

apt-get update
