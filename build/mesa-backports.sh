#!/usr/bin/env bash
# Take Mesa from trixie-backports instead of trixie.
#
# trixie ships Mesa 25.0, whose NVK (the Vulkan driver on nouveau) starts at
# Turing. Maxwell, Pascal and Volta were enabled in 25.1, so on 25.0 a laptop's
# Maxwell dGPU has no Vulkan device at all; backports carries 26.1. The Intel
# and AMD drivers move forward with it, since they are the same source package.
#
# Only two source packages are raised, by source name so that every binary
# built from each moves together: mesa itself, and elfutils, whose libelf the
# backported Mesa needs a newer version of. Pinning elfutils whole rather than
# just libelf1t64 keeps libelf and libdw on one version. Everything else in
# backports stays at its default 100 and is never chosen on its own.
#
# The source fetches Packages only, for the reason ostree-forky.sh gives: a
# catalog of packages apt will not install is no use to Discover.
set -euo pipefail

cat > /etc/apt/sources.list.d/trixie-backports.sources <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-backports
Components: main contrib non-free-firmware
Targets: Packages
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

cat > /etc/apt/preferences.d/mesa-backports <<EOF
Package: src:mesa src:elfutils
Pin: release n=trixie-backports
Pin-Priority: 990
EOF

apt-get update
