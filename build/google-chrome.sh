#!/usr/bin/env bash
# Google's apt repository, and Chrome from it.
#
# The claude-desktop.sh pattern -- fetch the key, pin its fingerprint, write a
# deb822 entry, install -- with three Chrome-specific corrections.
#
# The repo entry is named google-chrome-os4.sources rather than the name Chrome
# uses itself. Chrome's postinst writes its own google-chrome.sources unless
# /etc/default/google-chrome says repo_add_once="false" -- but it recreates
# that file regardless if a file by that exact name already exists, on the
# theory that a dist-upgrade may have commented it out. Under our own name it
# recognises nothing, finds no google-chrome.sources to refresh, and leaves the
# repo alone. It still drops an unused /usr/share/keyrings/google-chrome.gpg,
# which nothing references.
#
# The AppArmor profile has to be re-pointed. Chrome attaches it to the literal
# path /opt/google/chrome/chrome, and AppArmor matches the resolved path rather
# than the symlink -- so once bootc-rootfs.sh folds the tree into /usr/lib/opt,
# the profile silently stops attaching to anything. It grants `userns` and is
# inert on Debian, which does not restrict unprivileged user namespaces the way
# Ubuntu does; a profile that quietly matches nothing is still worse than no
# profile at all. apparmor is in this image whether or not anything asked for
# it -- linux-image, man-db and libvirt-daemon-common all recommend it -- so the
# postinst's `[ -f /etc/apparmor.d/abi/4.0 ]` guard passes and the copy happens.
#
# And the daily cron symlink goes. /etc/cron.daily/google-chrome points into
# /opt/google/chrome/cron/, and that script calls install_key unconditionally,
# writing to /usr/share/keyrings -- read-only on a deployed host. Nothing runs
# it today because this image installs no cron daemon; removing it keeps that
# from becoming a daily failure the moment one is added.
set -euo pipefail

fingerprint=EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796
keyring=/usr/share/keyrings/google-chrome-archive-keyring.asc

curl --proto '=https' --tlsv1.2 -fsSLo "${keyring}" \
  https://dl.google.com/linux/linux_signing_key.pub

# --with-colons rather than parsing the human-readable form: the fpr record's
# tenth field is the fingerprint, with no spaces to strip. `exit` after the
# first match -- the subkeys carry fpr records of their own.
got="$(gpg --show-keys --with-colons "${keyring}" \
       | awk -F: '$1 == "fpr" { print $10; exit }')"
if [ "${got}" != "${fingerprint}" ]; then
  echo "google-chrome: signing key is not the documented one, refusing to continue" >&2
  echo "  expected ${fingerprint}" >&2
  echo "  got      ${got:-<no OpenPGP data in the downloaded file>}" >&2
  exit 1
fi

# Written before the install, not after: the postinst reads this file, and an
# absent one makes it write repo_add_once="true" and register its own
# repository. install_device_trust_key_management_command is deliberately not
# set -- with it, the postinst creates a chromemgmt group that no sysusers.d
# entry backs, which is exactly what bootc's sysusers lint warns about.
install -d /etc/default
cat > /etc/default/google-chrome <<'EOF'
# This image registers Google's apt repository itself, as
# /etc/apt/sources.list.d/google-chrome-os4.sources. Keep the package, and the
# daily cron script it ships, from adding a second entry for the same repo.
repo_add_once="false"
repo_reenable_on_distupgrade="false"
EOF

cat > /etc/apt/sources.list.d/google-chrome-os4.sources <<EOF
Types: deb
URIs: https://dl.google.com/linux/chrome/deb/
Suites: stable
Components: main
Architectures: amd64 arm64
Signed-By: ${keyring}
EOF

apt-get update
apt-get install -y google-chrome-stable

# Re-point the AppArmor profile at the path the tree will actually have once
# bootc-rootfs.sh has run. Both copies: the one the postinst installed under
# /etc, and the source it would copy again on a later upgrade.
for profile in /etc/apparmor.d/google-chrome-stable \
               /opt/google/chrome/apparmor.d/google-chrome-stable; do
  if [ -f "${profile}" ]; then
    sed -i 's|/opt/google/chrome/chrome|/usr/lib/opt/google/chrome/chrome|' \
      "${profile}"
  fi
done

rm -f /etc/cron.daily/google-chrome
