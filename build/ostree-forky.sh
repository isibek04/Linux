#!/usr/bin/env bash
# Pull the ostree stack from forky instead of trixie.
#
# bootc (every release since well before v1.10) builds against the ostree
# crate with the v2025_3 feature, so its ostree-sys build script demands
# `ostree-1 >= 2025.3` from pkg-config. trixie ships 2025.2; forky/sid ship
# 2025.7. Without this the builder stage dies with:
#   Package 'ostree-1' has version '2025.2', required version is '>= 2025.3'
#
# The pin matters in *both* stages: the bootc binary links libostree-1.so.1
# dynamically, so the runtime image must carry the same-or-newer libostree
# it was built against, not trixie's 2025.2.
#
# Everything else stays on trixie: forky as a whole is pinned to 100 (below
# the 500 of a default source), and only the ostree binaries are raised
# above it. A dist-upgrade will therefore not drift onto testing.
#
# The source fetches Packages only. By default apt also pulls forky's AppStream
# catalog (DEP-11) and its icon tarballs into /var/lib/swcatalog, and forky's
# icons are JPEG XL. Trixie's kimageformats JXL plugin spins forever in
# QImageReader::jumpToNextImage on them, so any Plasma search that matches a
# forky-only app (typing "key" finds Keyman and GNOME Keysign) hangs
# plasmashell and then aborts it. Discover has no use for a catalog of
# packages pinned to 100 anyway.
#
# Written as a script rather than inline in the Containerfile for the same
# reason as apt-sources.sh: heredocs in RUN need BuildKit.
set -euo pipefail

cat > /etc/apt/sources.list.d/forky.sources <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: forky
Components: main
Targets: Packages
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

cat > /etc/apt/preferences.d/ostree-forky <<EOF
Package: *
Pin: release n=forky
Pin-Priority: 100

Package: ostree ostree-boot libostree-1-1 libostree-dev gir1.2-ostree-1.0
Pin: release n=forky
Pin-Priority: 990
EOF

apt-get update
