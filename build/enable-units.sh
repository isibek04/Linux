#!/usr/bin/env bash
# Enable the units the image boots with.
#
# Split out of the Containerfile because two of the groups below need a presence
# check rather than a plain `systemctl enable`, and a shell loop reads better
# here than as a backslash-continued RUN.
set -euo pipefail

# Units that must exist. A missing one is a real problem -- something in the
# Containerfile's package list did not install what it was supposed to -- so
# these are enabled unguarded and the build fails if one is absent.
systemctl set-default graphical.target
systemctl enable \
  NetworkManager.service \
  sddm.service \
  systemd-resolved.service \
  systemd-timesyncd.service \
  cups.service \
  acct.service \
  power-profiles-daemon.service \
  ssh.service

# Optional units, enabled if present. The libvirt sockets are socket-activated
# so nothing runs until a VM is asked for; they are guarded because Debian's
# split of the monolithic libvirtd into modular daemons is still in progress and
# the exact unit set differs between releases.
optional=(
  virtqemud.socket
  virtnetworkd.socket
  virtstoraged.socket
  virtnodedevd.socket
  virtnwfilterd.socket
  virtsecretd.socket
  virtinterfaced.socket
  virtlogd.socket
  virtlockd.socket
)
for unit in "${optional[@]}"; do
  if systemctl list-unit-files "${unit}" --no-legend | grep -q .; then
    systemctl enable "${unit}"
  else
    echo "note: ${unit} is not in this Debian release, skipping"
  fi
done

# bootc's own fetch-apply timer reboots into the new image on its own schedule,
# which is not what anyone wants on a machine they are using. Swap it for the
# download-only timer in usr/lib/systemd/system, which stages the update and
# stops. Guarded on the same principle: if a future bootc drops the unit there
# is nothing to disable, and that is not a build failure.
if systemctl list-unit-files bootc-fetch-apply-updates.timer --no-legend | grep -q .; then
  systemctl disable bootc-fetch-apply-updates.timer
else
  echo "note: bootc-fetch-apply-updates.timer not shipped by this bootc, nothing to disable"
fi
systemctl enable bootc-download-updates.timer

# Installed and deliberately not enabled. tailscale.sh puts the node agent in
# the image, and the package's postinst enables tailscaled.service through
# deb-systemd-helper -- so without this line every machine installed from this
# image would boot a VPN daemon that has never been logged in: a tun device,
# a socket and port 41641, all of it idle until someone runs `tailscale up`.
#
# `tailscale up` is a per-machine step whatever this image does. It needs a
# login, and the node it registers is named after the host, so there is nothing
# useful to bake in. So the agent ships and the daemon is off, and
# `systemctl enable --now tailscaled` is part of setting a machine up. It has
# to be done once: /etc is writable and merged on a deployed host, so the
# enable survives `bootc upgrade`, and the state under /var/lib/tailscale that
# the login writes is host state that upgrades do not touch either.
#
# systemctl rather than `deb-systemd-helper disable`, which is what put the
# symlink there: the helper refuses to run outside a maintainer script. It
# reads the same /etc symlink anyway, so a derived image that upgrades the
# package sees a unit the admin disabled and leaves it alone.
#
# Unguarded, like the first group above: the Containerfile installs the
# package, so a missing unit means that step did not do what it says.
systemctl disable tailscaled.service

# New users get their home under /var/home: / is read-only and /home is a
# symlink into /var.
#
# trixie's shadow ships that line commented out -- `# HOME=/home` -- so a
# substitution anchored on `^HOME=` matches nothing, exits 0, and leaves
# useradd on its built-in /home default. Match the commented form too, append
# the line if some future release drops it entirely, and assert the result:
# this failed silently once already, and a no-op sed under `set -e` looks
# exactly like a successful one.
if grep -qE '^#?[[:space:]]*HOME=' /etc/default/useradd; then
  sed -i 's|^#\?[[:space:]]*HOME=.*|HOME=/var/home|' /etc/default/useradd
else
  echo 'HOME=/var/home' >> /etc/default/useradd
fi
grep -qx 'HOME=/var/home' /etc/default/useradd
