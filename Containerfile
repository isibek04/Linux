# A Debian workstation, shipped as a bootable container.
#
# The Debian counterpart to os3 (Fedora). The desktop, the tooling and the
# workflows are deliberately close to it; the base is not, and cannot be.
# Fedora publishes a ready-made fedora-bootc image and packages bootc itself,
# so os3 starts from `FROM quay.io/fedora/fedora-bootc:44` and is done. Debian
# publishes no equivalent image and has no bootc package at all -- `bootcd` in
# the archive is an unrelated boot-CD tool. So the first stage here builds bootc
# from source, and the second assembles the bootable root by hand before
# installing the desktop on it.
#
# Everything installed comes from the Debian archive. That makes this smaller
# than os3: a handful of things os3 gets from rpmfusion, third-party repos or
# vendor downloads are not here. README.md lists them.

# --------------------------------------------------------------------------
# Stage 1: bootc from source
# --------------------------------------------------------------------------
FROM docker.io/library/debian:trixie AS builder

ARG DEBIAN_FRONTEND=noninteractive

# Tag of bootc-dev/bootc to build. Empty resolves to the newest release at
# build time; set it to a tag (e.g. v1.7.0) to pin the build.
ARG BOOTC_REF=""

# The C-side build inputs. rustc and cargo come from rustup rather than the
# archive because bootc's minimum supported Rust version moves faster than a
# Debian stable release does. The ostree packages come from forky via a
# pin (see ostree-forky.sh): bootc needs libostree >= 2025.3, trixie has
# 2025.2.
#
# --no-install-recommends stays in this stage. Nothing here is shipped -- only
# /output is copied into stage 2 -- so recommends would buy the image nothing
# and cost the build time. Stage 2 installs with recommends on throughout.
COPY build/ostree-forky.sh /tmp/build/
RUN /tmp/build/ostree-forky.sh \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl git go-md2man jq \
      libostree-dev libzstd-dev make ostree pkgconf \
 && rm -rf /var/lib/apt/lists/*

ENV CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    PATH=/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- --profile minimal --default-toolchain stable -y

COPY build/bootc-build.sh /tmp/build/
RUN /tmp/build/bootc-build.sh

# --------------------------------------------------------------------------
# Stage 2: the image
# --------------------------------------------------------------------------
FROM docker.io/library/debian:trixie

# ARG rather than ENV: apt must not prompt during the build, but the deployed
# system should not inherit a noninteractive frontend.
ARG DEBIAN_FRONTEND=noninteractive

COPY --from=builder /output/ /
COPY usr/ /usr/
COPY build/ /tmp/build/

# apt-sources.sh writes the trixie sources; ostree-forky.sh layers the forky
# pin on top so the runtime libostree matches the one bootc was built against.
RUN /tmp/build/apt-sources.sh && /tmp/build/ostree-forky.sh && apt-get upgrade -y

# Before the kernel: its postinst generates an initramfs with whatever dracut
# config exists at that moment.
RUN /tmp/build/dracut-config.sh

# Bootable-container plumbing: the kernel and its firmware, an initramfs
# generator that knows about ostree, the ostree stack bootc links against, and
# the bootloader bootc installs. Nothing user-facing yet.
#
# Recommends are left on here, as everywhere below. On this line in particular
# that is what brings in intel-microcode and amd64-microcode (recommended by
# firmware-linux), the GPU firmware firmware-misc-nonfree recommends, and
# shim-signed. dracut Conflicts: initramfs-tools, so the microcode packages'
# recommend on initramfs-tools is dropped rather than fighting the generator
# this image actually uses.
#
# The wifi, bluetooth and audio-DSP blobs have to be named explicitly, though.
# Fedora has one linux-firmware package and os3 gets the lot without asking;
# Debian splits the same tree per vendor and nothing in this image recommends
# the pieces a laptop needs, so firmware-linux alone leaves a machine with no
# wifi. iwlwifi and atheros carry their vendors' bluetooth firmware too, and
# sof-signed is what modern Intel laptops need before they make any sound.
# Named rather than "every firmware-* in the archive": that would add ~944 MiB,
# most of it enterprise NICs and firmware-qcom-soc, which is 298 MiB of
# Qualcomm SoC blobs for machines this amd64 image cannot boot on.
#
# The kernel metapackage is tried under both names: trixie is around where
# Debian began offering the architecture-independent `linux-image-generic`
# alongside the classic `linux-image-amd64`, and which one resolves depends on
# the state of the archive at build time.
RUN apt-get install -y \
      dracut \
      ostree \
      systemd-boot systemd-boot-efi \
      systemd-resolved systemd-timesyncd \
      libnss-myhostname libnss-resolve \
      firmware-linux-free firmware-linux \
      firmware-iwlwifi firmware-atheros firmware-realtek firmware-brcm80211 \
      firmware-sof-signed firmware-intel-sound firmware-cirrus \
      btrfs-progs cryptsetup dosfstools e2fsprogs fdisk lvm2 xfsprogs \
      ca-certificates \
 && { apt-get install -y linux-image-amd64 \
      || apt-get install -y linux-image-generic; }

# LXQt, matching os3's desktop. Debian's `lxqt` metapackage covers roughly what
# the lxqt-desktop and lxqt-apps groups cover there; sddm is the greeter. A
# desktop metapackage without its recommends is a desktop with no volume
# control or file associations, which is what first made this line an exception
# to the old --no-install-recommends default; it is now the rule.
RUN apt-get install -y \
      lxqt \
      sddm \
      xserver-xorg \
      network-manager network-manager-gnome \
      network-manager-openvpn network-manager-openvpn-gnome \
      pipewire pipewire-pulse pipewire-audio wireplumber \
      xdg-desktop-portal xdg-desktop-portal-gtk xdg-user-dirs \
      fonts-dejavu fonts-liberation2 fonts-noto fonts-noto-color-emoji \
      cups cups-filters system-config-printer \
      firefox-esr

# Media playback and the GPU stack. Narrower than os3's multimedia group by
# necessity: Debian has no rpmfusion, and the patent-encumbered decoders os3
# pulls from there have no home in the archive.
RUN apt-get install -y \
      ffmpeg \
      gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav \
      libgl1-mesa-dri mesa-vulkan-drivers vulkan-tools \
      obs-studio \
      mangohud

# Virtualisation, as in os3. Recommends matter here: they are what give
# virt-manager its SPICE console (gir1.2-spiceclientgtk-3.0) and qemu its
# display and OpenGL modules, none of which is optional in practice for a
# desktop that runs VMs.
RUN apt-get install -y \
      libvirt-daemon-system libvirt-clients \
      qemu-system-x86 qemu-utils \
      virt-manager \
      bridge-utils dnsmasq-base ovmf swtpm swtpm-tools

# Terminal tooling and the container stack. uidmap is what makes podman work
# rootless -- and podman's recommends are what make it work at all beyond that:
# passt and slirp4netns for rootless networking, aardvark-dns, catatonit,
# fuse-overlayfs, containers-storage.
#
# gh and glab are both in trixie main, so they need no third-party repo. The
# Gitea CLI still does: Debian's `tea` package is an unrelated text editor.
RUN apt-get install -y \
      bash-completion btop curl direnv git jq less man-db neovim \
      nodejs npm podman python3 rsync skopeo uidmap unzip wget zip \
      acct openssh-server power-profiles-daemon \
      gh glab

RUN /tmp/build/initramfs.sh

RUN /tmp/build/enable-units.sh

# Everything above this line is an ordinary Debian root. This is the step that
# makes it bootable -- and it empties /var, so nothing may install a package
# after it.
RUN /tmp/build/bootc-rootfs.sh && rm -rf /tmp/build

# os3 has a setcap step at this point, restoring file capabilities that the CI
# runner's docker drops when it pulls and re-pushes the base image's layers.
# There is no equivalent to do here: dpkg records no capabilities in its
# database to restore them from, and the binaries that need elevated rights on
# Debian -- newuidmap and newgidmap, the ones whose loss broke rootless podman
# on os3 -- are setuid rather than capability-based, and setuid bits survive.

RUN bootc container lint --no-truncate

LABEL containers.bootc="1" \
      ostree.bootable="1"

# Only relevant when this image is run as a container rather than booted: keeps
# the default entrypoint running under systemd.
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
