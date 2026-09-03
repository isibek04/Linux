#!/usr/bin/env bash
# Pandoc, from the `.deb` on its GitHub release.
#
# trixie ships pandoc 3.1.11.1, from early 2024, and nothing newer reaches it:
# there is no trixie-backports build, and forky's 3.10.2 is linked against
# forky's glibc, so pinning it the way ostree-forky.sh pins libostree would
# pull a second libc into the image. Upstream publishes no apt repository
# either -- only per-release `.deb`s on github.com/jgm/pandoc/releases -- so
# this is the fifth thing here that is not from the archive, and the second
# after Discord that comes as a bare package rather than from a repo.
#
# What it is not is a second Discord. That script cannot pin anything because
# its `.deb` is a downloader for a program that updates itself; this one is the
# program, so it pins both the version and the SHA-256 of the file, and the
# build fails if the bytes differ. Upstream signs neither the `.deb` nor a
# checksum list, so there is no key to check the way claude-desktop.sh does --
# the hash below was taken from the file GitHub served when the pin was set,
# and like tailscale.sh's fingerprint it is a record of what the build first
# saw rather than a second opinion. It still buys the same thing: the bytes
# this image installs as root cannot change without the change being a
# commit. Bumping VERSION means fetching the new file, reading its hash, and
# changing both constants, which is the point.
#
# The package is as plain as a `.deb` gets: one 156 MiB static Haskell binary
# at /usr/bin/pandoc, two symlinks to it (pandoc-lua, pandoc-server), three
# man pages, a copyright file, and no maintainer scripts at all. Depends are
# libc6, libgmp10 and zlib1g, all already installed; the Suggests are TeX Live
# pieces that texlive-full already covers. Nothing in /opt or /var, so
# bootc-rootfs.sh has nothing to correct, and `pandoc` upgrades the way every
# other package here does -- in the next image. It Replaces: pandoc-data,
# which only matters if Debian's own pandoc had been installed first; it is
# not, and nothing in this image recommends it.
#
# amd64 only. The image is: linux-image-amd64, qemu-system-x86 and the i386
# multiarch for Steam all say so, and the two vendor repos' `Architectures:
# amd64 arm64` lines are about which indices apt fetches, not about a second
# build. Upstream does publish an arm64 `.deb`; adding it is a second hash and
# a case statement, when there is a build to want it.
set -euo pipefail

version=3.11
sha256=89d4c9d97818c62a97157f0072844e4602c6cee795bf84abd1aee7273abcda99

arch="$(dpkg --print-architecture)"
if [ "${arch}" != "amd64" ]; then
  echo "pandoc: only amd64 is pinned here, and this build is ${arch}" >&2
  exit 1
fi

# The -1 is the Debian revision upstream stamps on every release's `.deb`.
url="https://github.com/jgm/pandoc/releases/download/${version}/pandoc-${version}-1-${arch}.deb"

deb="$(mktemp --suffix=.deb)"
trap 'rm -f "${deb}"' EXIT

# github.com 302s to release-assets.githubusercontent.com with a short-lived
# signed URL; -L follows it. No host check as in discord.sh: with the hash
# pinned, where the bytes came from is not what authenticates them.
curl --proto '=https' --tlsv1.2 -fsSL -o "${deb}" "${url}"

got="$(sha256sum "${deb}" | awk '{ print $1 }')"
if [ "${got}" != "${sha256}" ]; then
  echo "pandoc: ${url} is not the file this build was pinned to, refusing to continue" >&2
  echo "  expected ${sha256}" >&2
  echo "  got      ${got}" >&2
  exit 1
fi

echo "pandoc: installing $(dpkg-deb -f "${deb}" Version) from ${url}"

# Through apt rather than dpkg so the three Depends are resolved rather than
# assumed, against the indices already fetched. No apt-get update: this step
# adds no source.
apt-get install -y "${deb}"
