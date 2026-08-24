#!/usr/bin/env bash
# Teach AppArmor where this image keeps home directories.
#
# @{HOME} is the variable every profile uses to name a user's own files, and
# apparmor's tunables/home builds it out of @{HOMEDIRS}, which is `/home/` and
# nothing else. Here /home is a symlink to /var/home and /root a symlink to
# /var/roothome -- and AppArmor matches the resolved path, not the symlink,
# the same rule that makes google-chrome.sh re-point Chrome's profile. So every
# `owner @{HOME}/...` rule in every profile names a path that no process on
# this image ever has, and a confined application is denied its own files.
#
# akonadi-server is where that stops being theoretical. It ships an enforcing
# profile, kmail and korganizer store everything through it, and kde-standard
# installs the lot. Without the line below the server cannot create its SQLite
# database: it crashes on startup, three times, and gives up. What it prints is
#
#   Cannot remove old log file '~/.local/share/akonadi/Akonadi.error.old':
#   Permission denied
#
# against a directory the invoking user owns outright with mode 775, because
# AppArmor reports its denials to the audit log and never to the application.
# Nothing in that message suggests policy, which is what makes it expensive.
#
# tunables/home.d is apparmor's own extension point, included from
# tunables/home. It is included *after* @{HOME} is defined, which is fine:
# parser variables expand where they are used rather than where they are set,
# so appending to @{HOMEDIRS} here still reaches @{HOME}. The neighbouring
# `ubuntu` file in that directory is the one `dpkg-reconfigure apparmor`
# generates by scanning /etc/passwd, and it is empty -- correctly, since this
# image ships no user accounts for it to find.
#
# apparmor itself is installed whether or not anything asked for it: linux-image
# recommends it, and this image installs with recommends on.
set -euo pipefail

tunable=/etc/apparmor.d/tunables/home.d/os4

# The extension point has to exist, or the file below is written and silently
# never read. Assert it rather than trust it: a tunable that expands to the
# wrong thing looks exactly like one that expands to the right thing until
# something is denied.
if ! grep -q 'tunables/home\.d' /etc/apparmor.d/tunables/home; then
  echo "apparmor-home: tunables/home no longer includes tunables/home.d," >&2
  echo "  so ${tunable} would be ignored. Find where @{HOMEDIRS} is set now." >&2
  exit 1
fi

install -d "$(dirname "${tunable}")"
cat > "${tunable}" <<'EOF'
# Home directories on this image live under /var: /home is a symlink to
# /var/home, /root a symlink to /var/roothome, and AppArmor matches the
# resolved path rather than the symlink. Without these two lines every
# `owner @{HOME}/...` rule in every profile names a path nothing here has.
#
# Written during the image build by build/apparmor-home.sh.
@{HOMEDIRS}+=/var/home/
@{HOME}+=/var/roothome/
EOF

# Confirm the parser agrees. -Q parses without loading, so this works in a
# build container with no securityfs mounted; the probe profile exists only to
# give it something that pulls in tunables/global. The parser writes one
# "Cache read/write disabled: interface file missing" line to stderr for the
# same reason, which is noise rather than failure -- and stderr is left alone,
# because a step whose entire job is to fail loudly should not be redirecting
# it anywhere.
probe="$(mktemp)"
trap 'rm -f "${probe}"' EXIT
cat > "${probe}" <<'EOF'
abi <abi/3.0>,
#include <tunables/global>
profile os4-apparmor-home-probe /nonexistent/os4-apparmor-home-probe {
  owner @{HOME}/.local/share/** r,
}
EOF

variables="$(apparmor_parser -Q -b /etc/apparmor.d -D variables "${probe}")"
for expected in '@HOMEDIRS = .*"/var/home/"' '@HOME = .*"/var/roothome/"'; do
  if ! grep -qE "^${expected}" <<<"${variables}"; then
    echo "apparmor-home: ${tunable} did not reach the parser as expected" >&2
    echo "  wanted a line matching: ^${expected}" >&2
    grep -E '^@(HOME|HOMEDIRS) ' <<<"${variables}" >&2
    exit 1
  fi
done

echo "Wrote ${tunable}; @{HOMEDIRS} and @{HOME} now cover /var"
