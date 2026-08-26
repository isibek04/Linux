#!/usr/bin/env bash
# Remove the per-machine identity that the package steps generated, and refuse
# to continue if something key-shaped is still there.
#
# A postinst that generates a key generates it once, on the machine the package
# is being installed on. In image mode that machine is the build container, and
# whatever it wrote is copied onto every host the image is installed on -- so
# the `ssh-keygen` in openssh-server's postinst does not give each machine a
# host key, it gives every machine the *same* host key, private half included,
# published in the image. Anyone who can pull the image can impersonate any
# host that boots from it. The key's own comment field is the tell:
#
#   ssh-ed25519 AAAAC3Nza... root@buildkitsandbox
#
# So this runs after the last package step and before bootc-rootfs.sh, and for
# each file asks the same two questions: does shipping it make two machines
# claim one identity, and what puts a real one back on first boot.
#
# The removals below are the ones this image's package list actually produces.
# The check at the end is for the next one: a package added to the Containerfile
# later that quietly writes a key in its postinst fails the build here rather
# than being noticed in a published image.
set -euo pipefail

# --------------------------------------------------------------------------
# SSH host keys
# --------------------------------------------------------------------------
# Debian already has the unit to regenerate these -- openssh-server's postinst
# enables sshd-keygen.service into ssh.service.wants -- but it is gated on
# ConditionFirstBoot=yes, and a host that reaches this image through
# `bootc upgrade` is not on its first boot. Its /etc is a three-way merge
# against the image's, so dropping these files here drops them from that host
# too, and with the condition in place nothing would put new ones back: sshd
# would simply fail to start. The drop-in removes the gate (an empty assignment
# resets the condition list). `ssh-keygen -A` creates only what is missing, so
# on every subsequent boot it costs three stat calls.
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub

install -d /usr/lib/systemd/system/sshd-keygen.service.d
cat > /usr/lib/systemd/system/sshd-keygen.service.d/10-os4-every-boot.conf <<'EOF'
# The image ships no host keys (build/strip-identity.sh), so this has to run on
# any boot that finds none -- not only the first. A host upgrading into an image
# whose /etc no longer carries them is not on its first boot.
[Unit]
ConditionFirstBoot=
EOF

# --------------------------------------------------------------------------
# The ssl-cert snakeoil pair
# --------------------------------------------------------------------------
# ssl-cert is here because cups depends on it, and its postinst generates a
# self-signed certificate and key named after the host it ran on. Nothing in
# this image reads them -- no reference in /etc or in any unit file -- so they
# are removed rather than regenerated at boot. If a package that wants one is
# ever added, `make-ssl-cert generate-default-snakeoil` is what makes it, and
# the check at the end of this script is what will point that out.
rm -f /etc/ssl/private/ssl-cert-snakeoil.key /etc/ssl/certs/ssl-cert-snakeoil.pem

# --------------------------------------------------------------------------
# The iSCSI initiator name
# --------------------------------------------------------------------------
# Not a secret, but the file open-iscsi's postinst writes says so itself: the
# InitiatorName must be unique for each initiator, do not duplicate it. An
# image-wide IQN duplicates it across every host. open-iscsi puts a fresh one
# back on its own -- iscsid.service runs /usr/lib/open-iscsi/startup-checks.sh
# as ExecStartPre, which calls iscsi-iname when the file is absent.
rm -f /etc/iscsi/initiatorname.iscsi

# --------------------------------------------------------------------------
# machine-id and hostname
# --------------------------------------------------------------------------
# An image-wide machine-id would give every machine installed from this image
# the same identity. Leave it empty so systemd provisions one on first boot --
# empty rather than absent, which is what systemd reads as "not yet
# provisioned" on a root it may still be mounting read-only.
: > /etc/machine-id

# /etc/hostname is not touched here, and cannot be: it comes from the Debian
# base image, containing `debuerreotype` -- the name of the tool that built it
# -- and the builder bind-mounts its own over the top for the duration of every
# RUN, so a `rm` in this script gets EBUSY and a write would land in the mount
# rather than in the layer. Not a secret, and the check below leaves it alone.

# --------------------------------------------------------------------------
# The check
# --------------------------------------------------------------------------
# Content first, because it needs no list to keep up to date: a PEM private key
# announces itself in its own first line, whatever the file is called and
# whoever wrote it. Then the handful of secrets that are not PEM, by name.
#
# Everything under /etc is in scope, including files a package shipped: a key in
# a .deb is as shared as a key from a postinst. -I skips the binary files that
# live there (ld.so.cache, the console-setup caches) rather than reporting a
# chance match inside one; grep exits 1 on no match, which is the good case.
fail=0
note() { echo "strip-identity: $1" >&2; fail=1; }

while IFS= read -r f; do
  note "private key left in the image: ${f}"
done < <(grep -rlI -- '-----BEGIN .*PRIVATE KEY-----' /etc || true)

# Then by name, for the identities that are not PEM and so have nothing for the
# search above to match on. The first two are re-checked rather than newly
# checked -- the removals above have already dealt with them, and this is what
# would notice if one of those globs ever stopped matching. The nvme pair is the
# forward-looking half: no package in the Containerfile writes them today, and
# nvme-cli's postinst would.
for f in /etc/ssh/ssh_host_*_key /etc/iscsi/initiatorname.iscsi \
         /etc/nvme/hostnqn /etc/nvme/hostid; do
  [ -e "${f}" ] && note "per-machine identity left in the image: ${f}"
done

[ -s /etc/machine-id ] && note "/etc/machine-id is not empty"

if [ "${fail}" -ne 0 ]; then
  echo "strip-identity: each of the above is copied to every host installed" >&2
  echo "from this image. Remove it here and arrange for a per-machine one to" >&2
  echo "be generated on first boot." >&2
  exit 1
fi

echo "strip-identity: no keys or per-machine identity left under /etc"
