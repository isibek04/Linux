#!/usr/bin/env bash
# The UDS client, from the `.deb` the university's broker serves.
#
# UDS is Virtual Cable's OpenUDS, the VDI broker behind uds.mondragon.edu. Its
# web portal hands the browser a `uds://` URL when a service is clicked, and
# this package is what handles it: a Python 3 program under /usr/lib/UDSClient
# that asks the broker for the connection details, opens the tunnel and starts
# xfreerdp. The portal's client-download page lists a Windows installer, a Mac
# package, an RPM, two AppImage tarballs and this `.deb`, and the `.deb` is the
# only one of the six that is an actual package for this system.
#
# It is the sixth thing here that is not from the Debian archive, and the third
# bare `.deb` after Discord and pandoc. Where it comes from is different from
# both: upstream publishes no apt repository and no release artefacts at all --
# the GitHub release for 4.0 has no assets -- because the client is shipped by
# the broker that it talks to, from /uds/res/clients/ on the broker's own host.
# So the download is from uds.mondragon.edu, and what authenticates it is TLS to
# that host plus the pin below.
#
# The pin is pandoc's shape rather than Discord's. Discord's `.deb` is a
# downloader for a program that updates itself under $HOME, so pinning it
# would pin the wrong thing; this `.deb` is the program, so the version and the
# file's SHA-256 are both constants and the build fails if the bytes differ.
# Nobody signs the file or a checksum list, so like pandoc's hash and
# tailscale.sh's fingerprint the value below is a record of what the build
# first saw rather than a second opinion. It still buys the thing the pins are
# for: what this image installs as root cannot change without the change being
# a commit.
#
# The failure mode is a feature here. The broker redeploys the same 4.0.0 file
# -- its Last-Modified is years after the package's own changelog -- and when
# the university upgrades the broker the file changes, this script refuses it,
# and the scheduled build stops until the two constants are bumped. That is
# also the signal that the broker moved, which matters more than usual: a UDS
# broker checks the client's version and can refuse one that is too old, so a
# client that silently kept installing would be a client that silently stopped
# working. Bumping it is fetching the new file, reading its hash, and changing
# both constants.
#
# The package asks nothing of image mode. 106 KiB, `Architecture: all`, no
# maintainer scripts: twenty-odd Python files under /usr/lib/UDSClient, a
# .desktop file, and a doc directory. Its Depends are all in trixie main --
# python3-pyqt6 (or pyqt5), freerdp3-x11, python3-certifi, python3-cryptography,
# python3-psutil, desktop-file-utils -- and apt resolves them here. Nothing in
# /opt, nothing under /var; at runtime it writes the RDP files it generates to
# the temp directory and nothing else.
#
# The .desktop file is the part that has to land right. It declares
# MimeType=x-scheme-handler/uds;x-scheme-handler/udss;, which is how the browser
# finds the handler for the portal's links, and that declaration only takes
# effect once update-desktop-database has folded it into
# /usr/share/applications/mimeinfo.cache. desktop-file-utils registers a dpkg
# file trigger on /usr/share/applications, so installing through apt runs it at
# build time and the cache ships in /usr with the rest -- which is the reason
# the trigger-owning package being a hard Depends matters here, and the reason
# this step, like every package step, stays ahead of bootc-rootfs.sh.
#
# One thing the file says that is worth knowing rather than changing: its Exec
# line passes `-platform xcb`, so the Qt window runs on Xwayland under the
# Plasma Wayland session rather than natively. It works; it is upstream's call
# and not this image's to override.
set -euo pipefail

version=4.0.0
sha256=10d0f35bfa4cbad80dcce97d67babe4406b03b6ab1d90becc4b086d78b25bd86

url="https://uds.mondragon.edu/uds/res/clients/udsclient3_${version}_all.deb"

deb="$(mktemp --suffix=.deb)"
trap 'rm -f "${deb}"' EXIT

# No -L: the broker serves the file directly, and a redirect appearing where
# there was none is a change worth stopping on. With the hash pinned, where the
# bytes came from is not what authenticates them anyway, as in pandoc.sh.
curl --proto '=https' --tlsv1.2 -fsS -o "${deb}" "${url}"

got="$(sha256sum "${deb}" | awk '{ print $1 }')"
if [ "${got}" != "${sha256}" ]; then
  echo "udsclient: ${url} is not the file this build was pinned to, refusing to continue" >&2
  echo "  expected ${sha256}" >&2
  echo "  got      ${got}" >&2
  exit 1
fi

echo "udsclient: installing $(dpkg-deb -f "${deb}" Version) from ${url}"

# Through apt rather than dpkg so the Depends are resolved rather than assumed,
# against the indices already fetched. No apt-get update: this step adds no
# source. Recommends are on, as everywhere; the package declares none.
apt-get install -y "${deb}"
