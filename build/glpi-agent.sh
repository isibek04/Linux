#!/usr/bin/env bash
# GLPI Agent, from the `.deb` on its GitHub release, pointed at the
# university's GLPI server.
#
# GLPI is the asset-inventory system the university's IT runs at
# eaz-mgep.mondragon.edu, and the agent is what reports a machine to it:
# hardware, serial numbers, installed software, network interfaces, users. IT
# hands out a shell script that fetches upstream's `linux-installer.pl` and runs
# it as root, and that installer is a self-extracting Perl script that carries
# the same `.deb`s published beside it on the release and installs them through
# apt. On a deployed host that cannot work -- /usr is read-only and there is no
# `apt install` -- so this does here what the installer does there, at build
# time, from the `.deb` directly.
#
# It is the sixth thing here from outside the Debian archive and the third bare
# `.deb`, after pandoc and the UDS client. trixie has no glpi-agent package
# (Debian still ships its predecessor, fusioninventory-agent, which is
# unmaintained upstream), and upstream publishes no apt repository. The pin is
# pandoc's shape: the version and the file's SHA-256 are both constants and the
# build fails if the bytes differ. GitHub records a digest for each release
# asset, and the one below matched it when the pin was set; that is GitHub
# vouching for what it stored, not upstream signing anything, so like pandoc's
# hash this is a record of what the build first saw. It still buys the thing
# the pins are for: what this image installs as root cannot change without the
# change being a commit. IT's script resolves "latest" on every run; here
# bumping it is fetching the new file, reading its hash, and changing both
# constants.
#
# Only the core package. The release also has glpi-agent-task-network,
# -deploy, -collect and -esx, and the installer's default ("typical") install
# leaves them out too: local inventory is the only task IT's script asks for.
#
# What the package asks of image mode, which is little:
#
#   - 4 MiB, `Architecture: all`: Perl modules under /usr/share/glpi-agent,
#     five programs in /usr/bin, glpi-agent.service. Its Depends are all in
#     trixie main and apt resolves them here. Its Recommends matter:
#     libio-socket-ssl-perl is what lets it speak https at all, and dmidecode
#     is where serial numbers and the BIOS come from. Recommends are on, as
#     everywhere, and the check after the install makes the first one a hard
#     requirement anyway.
#   - The postinst copies the default configs from /usr/share/glpi-agent/etc
#     into /etc/glpi-agent through ucf. /etc is image content that a host
#     three-way merges, so they ship as defaults. ucf's own registry under
#     /var/lib/ucf belongs to no package's .list and does not survive
#     bootc-rootfs.sh, which matters only to a derived image that upgrades the
#     package with apt: ucf will treat the configs as locally edited and ask.
#   - /var/lib/glpi-agent is an empty directory in the package's .list, so
#     bootc-rootfs.sh turns it into a tmpfiles entry. That is where the agent
#     keeps its device ID and the last inventory, so it is per-host state and
#     correctly not image content -- nothing in the build runs the agent, so
#     the image carries no ID (see strip-identity.sh for why that matters).
#   - The postinst also enables glpi-agent.service. enable-units.sh disables it
#     again; see there and README.md for why the daemon ships off.
#
# The server goes into /etc/glpi-agent/conf.d, which agent.cfg includes and
# which upstream says package upgrades leave alone. It is the URL from IT's
# script and nothing else from it: their NO_SSL_CHECK=0 is already the default,
# and the server sends its full chain to a HARICA root in ca-certificates, so
# unlike the UDS tunnel there is nothing to work around.
#
# amd64 is not checked for: the package is `Architecture: all`.
set -euo pipefail

version=1.20
sha256=fd36518282f08d3ccd6bb728e8be98963ce2d41359308cef21f8e7976c4ad37b

server=https://eaz-mgep.mondragon.edu/front/inventory.php

# The -1 is the Debian revision upstream stamps on every release's `.deb`.
url="https://github.com/glpi-project/glpi-agent/releases/download/${version}/glpi-agent_${version}-1_all.deb"

deb="$(mktemp --suffix=.deb)"
trap 'rm -f "${deb}"' EXIT

# github.com 302s to release-assets.githubusercontent.com, as in pandoc.sh; -L
# follows it, and with the hash pinned the landing host is not what
# authenticates the bytes.
curl --proto '=https' --tlsv1.2 -fsSL -o "${deb}" "${url}"

got="$(sha256sum "${deb}" | awk '{ print $1 }')"
if [ "${got}" != "${sha256}" ]; then
  echo "glpi-agent: ${url} is not the file this build was pinned to, refusing to continue" >&2
  echo "  expected ${sha256}" >&2
  echo "  got      ${got}" >&2
  exit 1
fi

echo "glpi-agent: installing $(dpkg-deb -f "${deb}" Version) from ${url}"

# Through apt rather than dpkg so the Depends are resolved rather than assumed,
# against the indices already fetched. No apt-get update: this step adds no
# source.
apt-get install -y "${deb}"

# A Recommend in name only: without it every report to an https server fails.
perl -MIO::Socket::SSL -e 1

install -d /etc/glpi-agent/conf.d
cat > /etc/glpi-agent/conf.d/os4-server.cfg <<EOF
# Written by build/glpi-agent.sh in the image build. The university's GLPI
# server, as given in IT's install script. The daemon ships disabled:
# sudo systemctl enable --now glpi-agent
server = ${server}
EOF

# That the program starts at all. --version exits before reading the config or
# touching /var/lib/glpi-agent, so it generates no device ID either.
glpi-agent --version
