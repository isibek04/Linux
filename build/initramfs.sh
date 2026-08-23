#!/usr/bin/env bash
# Put the kernel and an initramfs where bootc expects to find them.
#
# The kernel package's postinst already built an initramfs, but into /boot --
# which belongs to the deployment, not the image, and is emptied later in the
# build. bootc reads both the kernel and its initramfs from the module
# directory instead, so generate one there.
#
# Assumes build/dracut-config.sh has already run.
set -euo pipefail

kdir="$(find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d | sort -V | tail -n1)"
if [ -z "${kdir}" ]; then
  echo "No kernel found under /usr/lib/modules" >&2
  exit 1
fi
kver="$(basename "${kdir}")"
echo "Preparing kernel ${kver}"

dracut --force --kver "${kver}" "${kdir}/initramfs.img"

if [ ! -f "${kdir}/vmlinuz" ]; then
  cp "/boot/vmlinuz-${kver}" "${kdir}/vmlinuz"
fi

# bootc reads the kernel from here, so a missing one is a broken image rather
# than a broken boot three steps later.
test -s "${kdir}/vmlinuz"
test -s "${kdir}/initramfs.img"
echo "Kernel and initramfs in place under ${kdir}"
