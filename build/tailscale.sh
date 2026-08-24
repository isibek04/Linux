#!/usr/bin/env bash
# Tailscale's apt repository, and the node agent from it.
#
# The third vendor repository in this image, and the same four steps
# claude-desktop.sh established: fetch the key, pin its fingerprint, write a
# deb822 entry, install. Tailscale's own scripts/installer.sh does three of
# those on Debian -- it writes whatever pkgs.tailscale.com serves into
# /usr/share/keyrings, drops the repo's own one-line .list next to it, and
# installs `tailscale tailscale-archive-keyring` -- and then ends on
# `systemctl enable --now tailscaled`. The pin is what this script adds; the
# enable is what it leaves out.
#
# The fingerprint below is not one Tailscale documents anywhere -- there is no
# published fingerprint to check against, the way Anthropic and Google both
# have one. It is the key pkgs.tailscale.com serves, read off the repository
# and recorded here, which is a weaker claim than the other two make and worth
# saying plainly. What it buys is still the thing worth having: the key baked
# into this image cannot change without the change being a commit.
#
# The keyring is deliberately not under the vendor's own filename. `tailscale`
# recommends `tailscale-archive-keyring`, recommends are on throughout this
# image, so that package arrives with it and ships
# /usr/share/keyrings/tailscale-archive-keyring.gpg -- straight over the file
# this script just fingerprint-checked, if the two shared a name. Today they
# are the same key, the package's .gpg being the dearmoured form of the .asc
# fetched here; under a name of our own that stays true whether or not a later
# release changes it. The package's copy is then referenced by nothing, like
# the google-chrome.gpg Chrome's postinst leaves behind.
#
# The repository is keyed by Debian codename rather than a `stable` suite, so
# the suite follows apt-sources.sh's. A codename Tailscale does not publish
# 404s on the key fetch and stops the build, which is the right way for that to
# fail.
#
# Architectures is pinned as it is on the other two vendor repos, for a
# different reason. Those two publish no i386 indices at all, so the line is
# what keeps the multiarch Steam enabled from breaking `apt-get update`;
# pkgs.tailscale.com does publish i386, so here it only avoids fetching a
# ~90 KiB index for an architecture nothing in this image would install
# tailscale on.
#
# Nothing needs correcting for image mode, which makes this the second vendor
# package after Discord that ships as it is. The .deb is two Go binaries in
# /usr (about 74 MiB together), three units in /usr/lib/systemd/system and one
# conffile in /etc/default -- nothing in /opt to fold into /usr/lib/opt, and
# nothing under /var for bootc-rootfs.sh to transcribe. tailscaled's state
# lives in /var/lib/tailscale, which its unit creates at runtime through
# StateDirectory=tailscale rather than the package shipping it.
#
# What is deliberate is that the daemon does not run. The postinst enables
# tailscaled.service through deb-systemd-helper; enable-units.sh disables it
# again, and the reasoning for that is there rather than here.
set -euo pipefail

fingerprint=2596A99EAAB33821893C0A79458CA832957F5868
keyring=/usr/share/keyrings/tailscale-archive-keyring.asc
track=stable
suite="${DEBIAN_SUITE:-trixie}"

# The armoured key rather than installer.sh's .noarmor.gpg: apt has taken
# either since 1.4, the other two vendor keyrings here are .asc, and it keeps
# the fingerprint check below identical to theirs.
curl --proto '=https' --tlsv1.2 -fsSLo "${keyring}" \
  "https://pkgs.tailscale.com/${track}/debian/${suite}.asc"

# --with-colons rather than parsing the human-readable form: the fpr record's
# tenth field is the fingerprint, with no spaces to strip. `exit` after the
# first match -- the signing subkey carries an fpr record of its own.
got="$(gpg --show-keys --with-colons "${keyring}" \
       | awk -F: '$1 == "fpr" { print $10; exit }')"
if [ "${got}" != "${fingerprint}" ]; then
  echo "tailscale: signing key is not the recorded one, refusing to continue" >&2
  echo "  expected ${fingerprint}" >&2
  echo "  got      ${got:-<no OpenPGP data in the downloaded file>}" >&2
  exit 1
fi

cat > /etc/apt/sources.list.d/tailscale.sources <<EOF
Types: deb
URIs: https://pkgs.tailscale.com/${track}/debian
Suites: ${suite}
Components: main
Architectures: amd64 arm64
Signed-By: ${keyring}
EOF

apt-get update
apt-get install -y tailscale
