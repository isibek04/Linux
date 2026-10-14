#!/usr/bin/env bash
# NVIDIA's proprietary driver, for the `linux:*-nvidia` images only.
#
# Runs in every build and does nothing unless the NVIDIA_DRIVER build arg names
# a driver branch: publish.yml passes `--build-arg NVIDIA_DRIVER=580` for the
# nvidia variant and nothing for the others, so the layers above this step are
# shared between them and everything from here down is built once per variant.
#
# 580 because it is the last branch that drives Maxwell, Pascal and Volta --
# 590 dropped them -- and the MX130 this variant exists for is Maxwell. It is
# also the open kernel modules' blind spot: those start at Turing, so this is
# nvidia-kernel-dkms, the proprietary module, named so that apt cannot pick
# nvidia-kernel-open-dkms for the `|` in nvidia-driver's Depends.
#
# Where it comes from is the awkward part. Debian has no 580 at all -- trixie
# and its backports stop at 550, sid too -- and NVIDIA's own debian13
# repository starts at 590. The 580 packages exist only in NVIDIA's debian12
# (bookworm) repository. They are self-contained binaries against libc, X and
# Wayland, and install and build against trixie's 6.12 kernel cleanly; three of
# their companion libraries need newer versions than trixie has, which the pin
# below handles.
#
# And the repository cannot be verified by trixie's apt as it stands. Its
# signing key, cudatools <cudatools@nvidia.com>, binds its user ID with a SHA-1
# self-signature, and trixie's sqv rejects SHA-1 bindings from 2026-02-01:
#
#   Signing key on EB693B3035CD5710E231E123A4B469963BF863CC is not bound:
#   ... SHA1 is not considered secure since 2026-02-01T00:00:00Z
#
# The signature on the repository's InRelease is SHA-256; only the key's
# self-certification is SHA-1. So this one `apt-get update` verifies with
# gpgv, which is what bookworm's apt used and still accepts the key, and it
# does so for this source alone: the update is pointed at the NVIDIA .sources
# file and nothing else, and no apt.conf setting is written, so the image's
# apt keeps sqv for every other repository. The key itself is still pinned to
# its fingerprint first, the way every other vendor key here is.
#
# Because a host's own `apt update` could not verify it either, the source,
# its key and its pin are removed again once the driver is installed. The
# driver is updated the way everything else is, by the next image build.
#
# The module is signed with the Secure Boot leaf key, the same way
# v4l2loopback's is and for the same reason; see build/sign-module.sh. Unsigned
# without the key, which only a local build or a fork's pull request lacks --
# publish.yml builds this variant only when the sealed one is built, and the
# sealed one needs the key.
set -euo pipefail

branch="${NVIDIA_DRIVER:-}"
if [ -z "${branch}" ]; then
  echo "nvidia: NVIDIA_DRIVER not set -- not installing the NVIDIA driver."
  exit 0
fi
case "${branch}" in
  *[!0-9]*) echo "nvidia: NVIDIA_DRIVER must be a branch number such as 580, got '${branch}'" >&2; exit 1 ;;
esac

fingerprint=EB693B3035CD5710E231E123A4B469963BF863CC
repo=https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/
keyring=/usr/share/keyrings/nvidia-cuda-debian12.asc
sources=/etc/apt/sources.list.d/nvidia-cuda-debian12.sources
prefs=/etc/apt/preferences.d/nvidia-driver

# gpgv for the update below, xz-utils to recompress the signed modules. Both
# are named rather than relied on.
apt-get install -y --no-install-recommends gpgv xz-utils

curl --proto '=https' --tlsv1.2 -fsSLo "${keyring}" "${repo}3bf863cc.pub"

got="$(gpg --show-keys --with-colons "${keyring}" \
       | awk -F: '$1 == "fpr" { print $10; exit }')"
if [ "${got}" != "${fingerprint}" ]; then
  echo "nvidia: signing key is not the documented one, refusing to continue" >&2
  echo "  expected ${fingerprint}" >&2
  echo "  got      ${got:-<no OpenPGP data in the downloaded file>}" >&2
  exit 1
fi

cat > "${sources}" <<EOF
Types: deb
URIs: ${repo}
Suites: /
Signed-By: ${keyring}
EOF

# The whole repository goes to 100, so nothing in it is ever chosen over
# trixie's own version of a package -- it carries CUDA and a good deal else.
# Raised to 990 are the driver's own sources, at the requested branch only
# (the repository carries 590 and newer as well, which would drop Maxwell);
# and the three companion libraries NVIDIA also publishes as egl-wayland,
# egl-gbm and egl-x11, because nvidia-driver-libs at 580 wants
# libnvidia-egl-wayland1 >= 1:1.1.19 where trixie has 1.1.18, and
# libnvidia-egl-xcb1 and -xlib1, which trixie does not package at all.
# Pinned by source name, as mesa-backports.sh does, so every binary of each
# moves together.
cat > "${prefs}" <<EOF
Package: *
Pin: origin developer.download.nvidia.com
Pin-Priority: 100

Package: src:nvidia-graphics-drivers src:nvidia-modprobe src:nvidia-persistenced src:nvidia-settings src:nvidia-xconfig
Pin: version ${branch}.*
Pin-Priority: 990

Package: src:egl-wayland src:egl-gbm src:egl-x11
Pin: origin developer.download.nvidia.com
Pin-Priority: 990
EOF

# This source only, with gpgv; see the top of the file. List-Cleanup off, or
# apt would throw away the Debian lists this update was not asked to refresh.
apt-get update \
  -o Dir::Etc::SourceList="${sources}" \
  -o Dir::Etc::SourceParts=- \
  -o APT::Get::List-Cleanup=0 \
  -o APT::Key::GPGVCommand=gpgv

# v4l2loopback.sh has already installed the kernel headers DKMS builds
# against, and created the empty /var/lib/dkms/mok.{key,pub} that stop dkms
# generating a key of its own. Both are its business; this script relies on
# them having happened, and checks the one it cannot do without.
[ -e /var/lib/dkms/mok.key ] || {
  echo "nvidia: /var/lib/dkms/mok.key is missing -- v4l2loopback.sh must run first," >&2
  echo "or dkms will generate a private key into this layer." >&2
  exit 1
}

# nvidia-smi is its own package, which nothing in the driver's dependencies
# names. It comes from the same source, so the pin above keeps it on the
# branch, and libnvidia-ml1, the NVML library it is a front end to, is already
# a dependency of the GL and EGL cores.
apt-get install -y nvidia-driver nvidia-kernel-dkms nvidia-smi

installed="$(dpkg-query -W -f '${Version}' nvidia-driver)"
case "${installed}" in
  "${branch}".*) echo "nvidia: installed nvidia-driver ${installed}" ;;
  *) echo "nvidia: expected the ${branch} branch, got nvidia-driver ${installed}" >&2; exit 1 ;;
esac
smi="$(dpkg-query -W -f '${Version}' nvidia-smi)"
[ "${smi}" = "${installed}" ] || {
  echo "nvidia: nvidia-smi ${smi} does not match nvidia-driver ${installed}" >&2
  exit 1
}

rm -f "${sources}" "${keyring}" "${prefs}"
rm -rf /var/lib/apt/lists/developer.download.nvidia.com_*

kdirs=(/usr/lib/modules/*)
[ "${#kdirs[@]}" -eq 1 ] || {
  echo "nvidia: expected exactly one kernel under /usr/lib/modules, found: ${kdirs[*]}" >&2
  exit 1
}
kver="$(basename "${kdirs[0]}")"

mapfile -t kos < <(find "/usr/lib/modules/${kver}/updates/dkms" -name 'nvidia*.ko*')
[ "${#kos[@]}" -gt 0 ] || {
  echo "nvidia: dkms did not install any nvidia modules for ${kver}" >&2
  exit 1
}

# Unlike v4l2loopback's ~200 KiB, nvidia.ko is ~100 MiB uncompressed, so the
# modules go back to xz after signing -- with the settings dkms and the kernel
# use, since kmod decompresses before the kernel checks the signature.
raw=()
for ko in "${kos[@]}"; do
  case "${ko}" in
    *.xz) unxz "${ko}"; ko="${ko%.xz}" ;;
    *.zst) unzstd --rm "${ko}"; ko="${ko%.zst}" ;;
    *.gz) gunzip "${ko}"; ko="${ko%.gz}" ;;
  esac
  raw+=("${ko}")
done
/tmp/build/sign-module.sh "${kver}" "${raw[@]}"
xz --check=crc32 --lzma2=dict=1MiB "${raw[@]}"

# DKMS keeps its own copy of every module it built, unsigned -- ~90 MiB under
# /var/lib/dkms/nvidia/<version>/<kver> -- which would otherwise sit in this
# layer for good, whatever bootc-rootfs.sh does to /var later. The installed
# modules are what the image needs; nothing rebuilds them on a host.
rm -rf "/var/lib/dkms/nvidia/"*"/${kver}"

# The suspend hooks the driver's modprobe.d asks for. It sets
# NVreg_PreserveVideoMemoryAllocations=1, under which NVIDIA's documented
# contract is that these units save and restore video memory around a
# suspend; the package ships them and enables none. nvidia-powerd is left off:
# it is Dynamic Boost, for Ampere and later laptops.
systemctl enable \
  nvidia-suspend.service \
  nvidia-resume.service \
  nvidia-hibernate.service \
  nvidia-suspend-then-hibernate.service

# Keep both drivers out of the initramfs. The package blacklists nouveau (and
# nova-core) in /etc/modprobe.d, which covers the booted root -- but the
# initramfs is built with hostonly=no, and dracut's drm module then takes
# every DRM driver it finds: nouveau, which would bind the card before the
# real root's blacklist exists, and the nvidia modules with ~70 MiB of GSP
# firmware this generation of card never loads, in a UKI that lives on the
# ESP. The nvidia modules load from the root instead, which is all a desktop
# needs. Exact module names, with underscores: dracut anchors each entry, and
# converts only the first `-` in the whole list.
cat > /usr/lib/dracut/dracut.conf.d/40-os4-nvidia.conf <<'EOF'
omit_drivers+=" nouveau nova_core nvidia nvidia_drm nvidia_modeset nvidia_uvm nvidia_peermem "
EOF

depmod "${kver}"
