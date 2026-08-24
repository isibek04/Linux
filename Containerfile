# A Debian workstation, shipped as a bootable container.
#
# The Debian counterpart to os3 (Fedora). The tooling and the workflows are
# deliberately close to it; the base is not, and cannot be; the desktop is KDE
# Plasma rather than os3's LXQt, which is a deliberate divergence and not a
# packaging constraint.
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

# KDE Plasma 6, where os3 has LXQt. `kde-standard` is Debian's Plasma workspace
# plus the standard KDE application set -- one tier above `kde-plasma-desktop`,
# well short of `kde-full`, and roughly the shape the `lxqt` metapackage had.
# sddm is still the greeter.
#
# A desktop metapackage without its recommends is a desktop with no volume
# control or file associations, which is what first made this line an exception
# to the old --no-install-recommends default; it is now the rule, and it matters
# more here than it did under LXQt. systemsettings, kscreen, kinfocenter,
# spectacle, powerdevil, discover, kio-extras, breeze-gtk-theme and the KDE
# portal are every one of them a recommend rather than a depend. Installed
# without them, kde-standard is a shell you cannot change the screen resolution
# from.
#
# Wayland by default, X11 still there. plasma-workspace hard-depends on
# kwin-wayland, so the Wayland session is not optional and is what Plasma 6
# offers first; kwin-x11 arrives as a kde-plasma-desktop recommend and is left
# alone, so the X11 session stays in sddm's list as a fallback for the machines
# and GPUs where Wayland still misbehaves. It costs about 2 MiB.
#
# xserver-xorg is no longer named here and is still installed: sddm
# hard-depends on `xserver-xorg | xserver` whatever the session does, and
# sddm's own Wayland greeter is marked experimental in 0.21. So the greeter
# runs on Xorg and the session it starts is Wayland unless you pick otherwise.
# Flipping the greeter too is one DisplayServer=wayland in
# /usr/lib/sddm/sddm.conf.d, whenever upstream drops the label.
#
# plasma-nm replaces network-manager-gnome. It ships its own OpenVPN
# configuration UI, so only the NetworkManager-side plugin is still wanted and
# network-manager-openvpn-gnome is gone; print-manager replaces
# system-config-printer on the same reasoning. Both are named explicitly rather
# than left to a recommend -- plasma-nm is recommended here, print-manager is
# not recommended by anything in this image at all.
RUN apt-get install -y \
      kde-standard \
      sddm \
      plasma-nm \
      network-manager network-manager-openvpn \
      pipewire pipewire-pulse pipewire-audio wireplumber \
      xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-kde \
      xdg-user-dirs \
      fonts-dejavu fonts-liberation2 fonts-noto fonts-noto-color-emoji \
      cups cups-filters print-manager \
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
      bash-completion btop curl direnv git gnupg jq less man-db neovim \
      nodejs npm podman python3 rsync skopeo uidmap unzip wget zip \
      acct openssh-server power-profiles-daemon \
      gh glab

# Anthropic's apt repository and the Claude desktop app from it. Wants curl and
# gnupg from the step above, and like every other package step it has to stay
# ahead of bootc-rootfs.sh. The pinned signing key and the reason the package is
# told not to register its own repo are both in build/claude-desktop.sh.
RUN /tmp/build/claude-desktop.sh

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
