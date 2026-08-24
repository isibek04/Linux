#!/usr/bin/env bash
# Discord, from the vendor `.deb`.
#
# The third piece of software here that is not in the Debian archive, and the
# first that does not come from an apt repository: Discord publishes no repo at
# all, only a download endpoint that 302s to the current release --
# https://discord.com/api/download?platform=linux&format=deb, redirecting today
# to stable.dl2.discordapp.net/apps/linux/<version>/discord-<version>.deb.
#
# So there is no signing key to pin, and the fingerprint check that
# claude-desktop.sh and google-chrome.sh both perform has no counterpart here.
# What authenticates the download is TLS to discord.com and to whatever host
# the redirect names, and nothing else. That is a weaker trust anchor than the
# other two vendor packages have, and it is worth being plain about rather than
# dressing up: the two checks below are sanity checks, not a substitute.
#
# The `.deb` is also not what it used to be, which changes what pinning would
# even buy. It is 2 MiB and contains no Discord. What it ships is
# /usr/bin/discord -- a shell script -- and a 4 MiB
# /usr/share/discord/updater_bootstrap; on first launch the script looks for
# ~/.config/discord/Discord, does not find it, and runs the bootstrap, which
# downloads the actual application from updates.discord.com into
# ~/.config/discord/app-<version>/. Thereafter Discord updates itself there.
#
# That is the same shape as Debian's steam-installer, which README.md already
# describes: the packaged version is the version of the bootstrap, not of the
# program you end up running. It is also why this script does not pin a version
# or a checksum. Doing so would break every scheduled build the moment Discord
# cut a release, in exchange for pinning a downloader that does not pin what it
# downloads.
#
# The upside of that design is that it suits image mode unusually well. Nothing
# lands in /opt, so unlike Chrome there is no tree for bootc-rootfs.sh to fold
# into /usr/lib/opt and no path to re-point. Nothing writes to /usr after the
# install either -- the self-updater's target is under $HOME, which is writable
# on a deployed host, where Chrome's cron script and Steam's bin_steamdeps.py
# would both be reaching for a read-only /usr.
#
# Its AppArmor profile does need /var/home to be known, though. The profile
# attaches to @{HOME}/.config/discord/app-*/Discord, which resolves to a path
# nothing here has unless apparmor-home.sh has extended @{HOMEDIRS} -- the same
# tunable akonadi-server needed, and the reason this step is placed before that
# one. Like Chrome's, the profile is `flags=(unconfined)` and grants `userns`,
# so it is inert on Debian either way; a profile that silently attaches to
# nothing is still the wrong thing to ship.
#
# One thing in the postinst is noisy and harmless. It opens with
# `systemctl reload apparmor`, which in a build container with no running
# systemd prints "System has not been booted with systemd" and returns 1. The
# script is /bin/sh without `set -e` and ends on an `rm -f`, so dpkg sees exit
# 0 and the install succeeds; the profile is a conffile under /etc/apparmor.d
# and apparmor.service loads it at boot regardless. The `for DIR in /home/*`
# cache-clearing loop below it matches nothing at build time for the same
# reason there are no users yet.
set -euo pipefail

url='https://discord.com/api/download?platform=linux&format=deb'

deb="$(mktemp --suffix=.deb)"
trap 'rm -f "${deb}"' EXIT

# -w '%{url_effective}' reports where the redirect chain actually ended. Worth
# asserting: -L follows redirects across hosts, so an endpoint that one day
# points somewhere else would have this image install a stranger's package as
# root without a word.
effective="$(curl --proto '=https' --tlsv1.2 -fsSL -o "${deb}" \
             -w '%{url_effective}' "${url}")"

host="${effective#*://}"
host="${host%%/*}"
host="${host%%:*}"
case "${host}" in
  discord.com|*.discord.com|discordapp.net|*.discordapp.net) ;;
  *)
    echo "discord: download redirected off Discord's own hosts, refusing" >&2
    echo "  ended at ${effective}" >&2
    exit 1
    ;;
esac

# And that what came back is the package it claims to be rather than an error
# page with a 200 on it. dpkg-deb exits non-zero on anything that is not an
# archive, so the failure is caught either way.
name="$(dpkg-deb -f "${deb}" Package 2>/dev/null || true)"
if [ "${name}" != "discord" ]; then
  echo "discord: ${effective} is not the discord package, refusing to continue" >&2
  echo "  Package: ${name:-<not a Debian archive>}" >&2
  exit 1
fi

echo "discord: installing $(dpkg-deb -f "${deb}" Version) from ${effective}"

# No apt-get update: this step adds no source, and the indices the dependencies
# resolve against are the ones already fetched above. Installing through apt
# rather than dpkg is what pulls the Depends in -- and the Recommends, which
# are on here as everywhere: libva2 and libpipewire-0.3-0, both already in this
# image, and libunity9, which is not. That last one is Ubuntu's old Unity
# launcher API -- taskbar badges and progress bars -- and does nothing under
# Plasma; it is still in trixie, and it and its chain cost about 1.5 MiB, so it
# is left to arrive rather than excluded by hand.
apt-get install -y "${deb}"
