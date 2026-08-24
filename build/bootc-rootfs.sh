#!/usr/bin/env bash
# Turn a conventional Debian root into the layout bootc boots from.
#
# Three things happen here, in this order, and the order matters:
#
#   1. The dpkg database moves out of /var into /usr, because step 3 empties
#      /var and the package database must survive.
#   2. The /var tree the packages just built is transcribed into tmpfiles.d
#      entries, so it can be recreated at boot.
#   3. /var and the other state directories are emptied and replaced with
#      symlinks into /var, which is what ostree expects to find. /opt is the
#      one that does not go to /var: it is image content, so it moves to
#      /usr/lib/opt instead.
#
# Run this as the last step before `bootc container lint`: anything that
# installs packages or writes to /var afterwards will be thrown away.
set -euo pipefail

# --------------------------------------------------------------------------
# 1. Keep the dpkg database
# --------------------------------------------------------------------------
# Fedora already keeps its rpmdb in /usr/lib/sysimage/rpm, so os3 got this for
# free. Debian's is under /var/lib/dpkg, which step 3 would delete -- leaving a
# deployed host unable to answer `dpkg -l` and, worse, making this image
# useless as a base for a derived image that wants to install another package.
# Move it into /usr and leave a symlink behind; the symlink is picked up by
# step 2 and recreated at boot.
#
# /usr/lib/dpkg is already taken (dpkg ships its method scripts there), hence
# /usr/lib/sysimage/dpkg, matching the rpm convention.
if [ -d /var/lib/dpkg ] && [ ! -L /var/lib/dpkg ]; then
  mkdir -p /usr/lib/sysimage
  rm -rf /usr/lib/sysimage/dpkg
  mv /var/lib/dpkg /usr/lib/sysimage/dpkg
  ln -sT ../../usr/lib/sysimage/dpkg /var/lib/dpkg
fi

# Drop the package lists and .deb cache: several hundred MB of nothing, and
# regenerating them is one `apt update` away.
apt-get clean
rm -rf /var/lib/apt/lists/* /var/log/apt/* /var/cache/debconf/*-old

# --------------------------------------------------------------------------
# 2. Transcribe /var into tmpfiles.d
# --------------------------------------------------------------------------
# bootc only materialises the image's /var on the initial install. A host that
# reaches a new image through `bootc upgrade` keeps the /var it already has, so
# any directory a newly added package expects there simply never appears --
# which is also what `bootc container lint` warns about with its var-tmpfiles
# check.
#
# os3 hand-wrote these entries for libvirt. Generating them from the tree the
# packages actually built is both less work and more accurate: it picks up
# every package rather than the one that was noticed, and it reads the real
# modes and owners instead of hardcoding names that differ between Debian and
# Fedora (libvirt-qemu vs qemu, for one).
out=/usr/lib/tmpfiles.d/zz-os4-var.conf
{
  cat <<'EOF'
# Generated during the image build by build/bootc-rootfs.sh -- do not edit.
# One entry per directory and symlink that the packages in the Containerfile
# created under /var, so that `bootc upgrade` onto an existing host recreates
# what that host has never seen. Modes and owners are read from the built tree.
EOF
  # Directories, shallowest first, so a parent's mode is applied before the
  # children that systemd-tmpfiles would otherwise create it for implicitly.
  find /var -mindepth 1 -type d -printf '%d\td %p %#m %u %g -\n' \
    | sort -k1,1n | cut -f2-
  # Symlinks: /var/lock and /var/run point into /run, and /var/lib/dpkg now
  # points at the copy under /usr.
  find /var -mindepth 1 -type l -printf 'L %p - - - - %l\n'
} > "${out}"
echo "Wrote $(grep -c '^[dL]' "${out}") tmpfiles.d entries to ${out}"

# --------------------------------------------------------------------------
# 3. Empty the state directories and link them into /var (except /opt)
# --------------------------------------------------------------------------
# shellcheck disable=SC2114 # Emptying these is the entire point of the script.
rm -rf /boot /home /root /usr/local /srv /mnt /var
mkdir -p /sysroot /boot /usr/lib/ostree /var

# /opt is the exception: it belongs to the image rather than to host state, so
# it is moved instead of emptied. Everything the package steps installed there
# goes under /usr, and the conventional path becomes a symlink to it. Vendor
# software that installs to /opt therefore ships read-only and
# composefs-verified like the rest of /usr -- and, unlike anything under
# /var/opt, actually arrives on a host that reaches this image through
# `bootc upgrade` rather than a fresh install.
#
# The cost is that /opt is no longer writable on a deployed host. /usr/local is
# still backed by /var and is where machine-local additions go. ostree's
# ostree-state-overlay@opt.service would hand writability back, but it ships in
# ostree-boot, which this image does not install and which also carries
# ostree's own boot-time units into an image that boots off bootc's dracut
# module instead. Upstream's own guidance, in
# ostree-state-overlay@.service(8), is to prefer symlinking the parts that need
# to be mutable into /var over overlaying the whole directory anyway.
mkdir -p /usr/lib/opt
if [ -d /opt ] && [ ! -L /opt ]; then
  find /opt -mindepth 1 -maxdepth 1 -exec mv -t /usr/lib/opt {} +
  rmdir /opt
fi
ln -sT usr/lib/opt /opt

ln -sT sysroot/ostree /ostree
ln -sT var/roothome /root
ln -sT var/home /home
ln -sT var/srv /srv
ln -sT var/mnt /mnt
ln -sT ../var/usrlocal /usr/local

# The targets of those symlinks are not in the generated file above -- they
# never existed in the built tree -- so declare them separately.
cat > /usr/lib/tmpfiles.d/os4-base-dirs.conf <<'EOF'
# Targets of the /-level symlinks that replace the state directories.
d /var/home     0755 root root -
d /var/srv      0755 root root -
d /var/mnt      0755 root root -
d /var/usrlocal 0755 root root -
d /var/roothome 0700 root root -
d /run/media    0755 root root -
EOF

# /etc/resolv.conf has to be a symlink into /run for systemd-resolved, and /etc
# is writable on a deployed host, so tmpfiles restores it rather than the image
# shipping a dangling link.
cat > /usr/lib/tmpfiles.d/os4-resolv-conf.conf <<'EOF'
L! /etc/resolv.conf - - - - ../run/systemd/resolve/stub-resolv.conf
EOF

# --------------------------------------------------------------------------
# Boot-time root setup
# --------------------------------------------------------------------------
# composefs gives the deployed root a verified, read-only image; sysroot
# readonly keeps /sysroot from being writable out from under it.
cat > /usr/lib/ostree/prepare-root.conf <<'EOF'
[composefs]
enabled = yes

[sysroot]
readonly = true
EOF

# An image-wide machine-id would give every machine installed from this image
# the same identity. Leave it empty so systemd provisions one on first boot.
: > /etc/machine-id
