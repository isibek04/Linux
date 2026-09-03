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
# Almost everything installed comes from the Debian archive. Five things do
# not: three vendor apt repositories -- Anthropic's, for the Claude desktop
# app, Google's, for Chrome, and Tailscale's, for the node agent -- each with
# its signing key pinned to a fingerprint the build refuses to proceed without,
# and two bare `.deb`s: Discord, which publishes no repository at all and so
# has no key to pin, and pandoc, whose GitHub release is pinned by version and
# SHA-256 instead because trixie's is two years old and there is no backport.
# Tailscale's is the weakest of the three pins: it documents no fingerprint to
# check the key against the way the other two do, so what build/tailscale.sh
# records is simply the key the repository serves -- which at least makes a
# change to it a commit. That still makes this smaller than os3: a handful of
# things os3 gets from rpmfusion, other third-party repos or vendor downloads
# are not here. README.md lists them.

# --------------------------------------------------------------------------
# Stage 1: bootc from source
# --------------------------------------------------------------------------
FROM docker.io/library/debian:trixie AS builder

ARG DEBIAN_FRONTEND=noninteractive

# Tag of bootc-dev/bootc to build. Pinned, because this is the boot path and
# publish.yml builds on a schedule: left empty it resolves to whatever the
# newest upstream release happens to be when the timer fires, so an unattended
# build could replace the thing that mounts the root filesystem with a version
# nobody has booted. Bumping it is a commit, which is where a change like that
# belongs.
#
# v1.16.9 is also the release the README's source references were read against
# (the bootupd/systemd-boot branch in install.rs, the kargs handling in
# bootc_composefs/boot.rs), so pinning it keeps the documentation and the
# binary describing the same program.
#
# Set to a different tag to test one; empty still means "newest release".
ARG BOOTC_REF="v1.16.9"

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
FROM docker.io/library/debian:trixie AS rootfs

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
# efibootmgr and mokutil (recommended and depended on by systemd-boot).
# dracut Conflicts: initramfs-tools, so the microcode packages' recommend on
# initramfs-tools is dropped rather than fighting the generator this image
# actually uses.
#
# The two signed-EFI packages are what make Secure Boot possible, and both are
# named rather than left to apt.
#
# `shim-signed` is only a systemd-boot *recommend*, so it arrives either way
# today -- but it is the Microsoft-signed binary the whole chain starts from,
# which is not something to hold on a recommend. It pulls
# shim-helpers-amd64-signed (MokManager and the fallback loader) as a hard
# dependency.
#
# `systemd-boot-efi-amd64-signed` has to be named because otherwise it is not
# installed at all. systemd-boot declares
# `systemd-boot-efi-signed | systemd-boot-efi` and the signed alternative is
# listed first, but naming systemd-boot-efi explicitly on this line satisfies
# the dependency directly, so apt never considers the alternative. The result
# is an image whose /usr/lib/systemd/boot/efi holds only the unsigned
# systemd-bootx64.efi -- which is what the README used to describe as Debian
# not shipping a signed one at all.
#
# With it installed, `bootctl install` picks the signed binary on its own:
# install_binaries() skips a `.efi` when a `.efi.signed` sits beside it, and
# copy_one_file() drops the suffix at the destination (systemd 257,
# src/bootctl/bootctl-install.c). bootc calls plain `bootctl install`
# (crates/lib/src/bootloader.rs, bootc 1.16.9), so it inherits that behaviour
# without knowing anything about it.
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
# tpm2-tools is installed for the initramfs, not for the command line.
# dracut's 91tpm2-tss module is the only one that puts libtss2 and
# libcryptsetup-token-systemd-tpm2.so into the initrd, and its check() is
# `require_binaries tpm2 || return 1`. With the binary missing that returns 1
# rather than 255, so the hostonly=no dependency scan in 01systemd-cryptsetup
# skips the module -- and systemd-cryptsetup dlopens libtss2 rather than
# linking it, so nothing else drags the library in either. The initrd then has
# no way to reach /dev/tpmrm0: `bootc install --block-setup tpm2-luks` enrols
# the key happily and the installed disk fails to unlock its root at boot,
# with `--wipe-slot=all` having left the TPM as the only keyslot.
#
# The kernel metapackage is tried under both names: trixie is around where
# Debian began offering the architecture-independent `linux-image-generic`
# alongside the classic `linux-image-amd64`, and which one resolves depends on
# the state of the archive at build time.
RUN apt-get install -y \
      dracut \
      ostree \
      systemd-boot systemd-boot-efi systemd-boot-efi-amd64-signed \
      shim-signed \
      systemd-resolved systemd-timesyncd \
      libnss-myhostname libnss-resolve \
      firmware-linux-free firmware-linux \
      firmware-iwlwifi firmware-atheros firmware-realtek firmware-brcm80211 \
      firmware-sof-signed firmware-intel-sound firmware-cirrus \
      btrfs-progs cryptsetup tpm2-tools dosfstools e2fsprogs fdisk lvm2 xfsprogs \
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
      speech-dispatcher firefox-esr

# Media playback and the GPU stack. Narrower than os3's multimedia group by
# necessity: Debian has no rpmfusion, and the patent-encumbered decoders os3
# pulls from there have no home in the archive.
RUN apt-get install -y \
      ffmpeg \
      gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav \
      libgl1-mesa-dri mesa-vulkan-drivers vulkan-tools \
      obs-studio \
      mangohud

# Steam, and the i386 multiarch it needs.
#
# The client is still a 32-bit program -- steamwebhelper above all -- so the
# 32-bit halves of mesa, Vulkan and VA-API have to be present even to play
# 64-bit games, and that means telling dpkg about i386 before apt is asked for
# anything. The architecture is recorded in /var/lib/dpkg/arch, which
# bootc-rootfs.sh moves into /usr with the rest of the dpkg database, so a
# deployed host still knows about it and can still resolve :i386 packages.
#
# Adding the architecture makes apt fetch a second set of indices for every
# source that does not say otherwise -- the Debian entries and the forky pin,
# all of which publish i386. It stays enabled for every apt run below, which is
# what makes the two vendor repositories' `Architectures: amd64 arm64` load
# bearing: without it, the apt-get update inside claude-desktop.sh and
# google-chrome.sh would ask dl.google.com and downloads.claude.ai for i386
# indices neither of them publishes.
#
# steam-installer is in contrib, which apt-sources.sh already enables;
# steam-libs, steam-libs-i386 and steam-devices are in main. Nothing here comes
# from non-free, so the component list is unchanged.
#
# Recommends are on, as everywhere, and they matter more here than usual:
# mesa-vulkan-drivers:i386, va-driver-all:i386 and libsdl2-2.0-0:i386 are all
# recommends of steam-libs rather than depends, and without them the client
# runs without 32-bit Vulkan or hardware video decode. The bill is about 494
# MiB of i386 packages, of which libllvm19:i386 (143 MiB),
# mesa-vulkan-drivers:i386 (83 MiB) and mesa-libgallium:i386 (44 MiB) are the
# bulk: a second, 32-bit copy of the GPU stack the step above installed.
#
# steam-devices is a steam-libs recommend and would arrive anyway; it is named
# because it is the half that is useful on its own -- udev rules for
# controllers, VR headsets and the Steam Deck -- and because a future
# --no-install-recommends here should not silently drop it.
#
# Debian's package rather than Valve's own .deb, and why, is in README.md.
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y \
      steam-installer \
      steam-devices

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
#
# texlive-full builds its formats and filename databases into /var/lib/texmf
# from this step's postinst triggers, and nothing under /var survives
# bootc-rootfs.sh. That script moves the tree into /usr; see its step 1 and
# README.md before touching either.
RUN apt-get install -y \
      bash-completion btop curl direnv git gnupg jq less man-db neovim \
      nodejs npm podman python3 rsync skopeo uidmap unzip wget zip \
      acct openssh-server pkexec power-profiles-daemon \
      gh glab texlive-full

# Pandoc from the `.deb` on its GitHub release rather than the archive: trixie
# has 3.1.11.1 and no backport, and upstream publishes no apt repository, so
# this is the second bare package here after Discord -- but unlike Discord it is
# the program itself and not a downloader, so build/pandoc.sh pins the version
# and the file's SHA-256 and fails on a mismatch. Bumping it is a commit. Wants
# curl from the step above; one static binary under /usr/bin, nothing in /opt
# or /var, no maintainer scripts. Same constraint as every package step: ahead
# of bootc-rootfs.sh.
RUN /tmp/build/pandoc.sh

# Anthropic's apt repository and the Claude desktop app from it. Wants curl and
# gnupg from the step above, and like every other package step it has to stay
# ahead of bootc-rootfs.sh. The pinned signing key and the reason the package is
# told not to register its own repo are both in build/claude-desktop.sh.
RUN /tmp/build/claude-desktop.sh

# Google's apt repository and Chrome from it, on the same terms: a pinned
# signing key, this image's own deb822 entry, and the package told not to
# register a second one. Firefox ESR above is still installed; this is the
# Blink half of the pair. Debian's `chromium` is in main and would need no
# repository at all, but it ships no Widevine CDM -- Debian's widevine-installer
# is in contrib and only reaches trixie through backports -- and it disables the
# media router by default, so DRM video and Chromecast are what the third-party
# repo buys here.
#
# Unlike claude-desktop, which installs to /usr/lib, Chrome unpacks 431 MiB into
# /opt. bootc-rootfs.sh folds that into /usr/lib/opt; google-chrome.sh re-points
# the AppArmor profile at the path it will actually have. Same constraint as
# every package step: it has to stay ahead of bootc-rootfs.sh.
RUN /tmp/build/google-chrome.sh

# Discord, from the vendor `.deb` -- no repository, so no signing key to pin,
# which makes it the weakest of the three third-party installs and the one
# README.md is most explicit about. The download is 2 MiB and contains no
# Discord: the package is a launcher plus an updater bootstrap that fetches the
# application into ~/.config/discord on first run, the same arrangement
# Debian's steam-installer uses. Nothing of it lands in /opt, and its
# self-updates land in $HOME rather than in a read-only /usr, so this is the
# rare vendor package that needs no image-mode correction at all. Same
# constraint as every package step: ahead of bootc-rootfs.sh.
RUN /tmp/build/discord.sh

# Tailscale's apt repository and the node agent from it, on the terms the first
# two vendor repos set: a key fetched, its fingerprint checked, this image's own
# deb822 entry. Like Discord and unlike the other two, it needs no image-mode
# correction: two binaries in /usr, three units, one conffile, nothing in /opt
# and nothing under /var, so this step is the whole of it.
#
# Where it diverges from upstream's scripts/installer.sh, apart from the pin, is
# that the daemon is left disabled: the package's postinst enables
# tailscaled.service, enable-units.sh turns it off again, and `tailscale up` on
# a machine is what turns it on. Same constraint as every package step: ahead of
# bootc-rootfs.sh.
RUN /tmp/build/tailscale.sh

RUN /tmp/build/initramfs.sh

RUN /tmp/build/enable-units.sh

# The other half of the fact enable-units.sh teaches useradd: home is under
# /var here, and AppArmor's @{HOME} has to be told so too. /home is a symlink
# to /var/home and AppArmor matches the resolved path, so out of the box every
# `owner @{HOME}/...` rule on this image names a path nothing has -- which is
# why kmail could not start, akonadi-server's profile being an enforcing one.
# See build/apparmor-home.sh.
RUN /tmp/build/apparmor-home.sh

# The postinst scripts above generated this machine's identity on the way past
# -- SSH host keys, a snakeoil certificate, an iSCSI initiator name -- and in
# image mode "this machine" is the build container, so all of it would be
# copied onto every host installed from the image. build/strip-identity.sh
# removes it, arranges for the parts that are needed to be regenerated on first
# boot, and fails the build if anything key-shaped is still under /etc. It has
# to run after the last package step, for the obvious reason.
RUN /tmp/build/strip-identity.sh

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

# --------------------------------------------------------------------------
# Stages 3-5: the sealed variant
# --------------------------------------------------------------------------
# A second image built from the same rootfs, published as the `-sealed` tags:
# kernel, initramfs and kernel arguments fused into one UKI, signed with the
# leaf key of usr/share/os4/secureboot, with the composefs digest of the whole
# root filesystem embedded in the cmdline. bootc's composefs backend
# (experimental in the pinned v1.16.9) verifies that digest at boot, so the
# signature on the UKI seals everything from firmware to /usr.
#
# A separate variant rather than a change to the main image, and the reason is
# the deployed hosts: an image containing a UKI makes `bootc install` select
# the composefs backend automatically, and the split rootfs below no longer
# carries vmlinuz/initramfs.img under /usr/lib/modules -- which is exactly
# where the ostree backend on every existing machine looks during
# `bootc upgrade`. The main tags therefore stay as they are, and the sealed
# tags exist for fresh installs, until composefs is what the machines run.
#
# The split: the kernel and initramfs move out of the rootfs and into the UKI,
# so shipping them twice would only cost space.
FROM rootfs AS split
RUN mkdir /kernel && bootc container split-kernel-and-rootfs --rootfs / --output /kernel

# The UKI is not built here, and that is the whole subtlety of this variant.
#
# `bootc container ukify` hashes a directory. A directory inside a build is the
# builder's live filesystem, whose mtimes carry nanoseconds. The image that
# filesystem is committed to carries tar, and tar has no sub-second mtime
# field, so every timestamp a host reads back out is truncated to whole
# seconds. The digest sealed into the UKI and the digest computed from the
# published image therefore disagree on very nearly every inode, and bootc
# refuses the image at install time:
#
#   The UKI has the wrong composefs= parameter (is '29329a34...', should be
#   '1d3dc3b0...')
#
# Measured, not reasoned: the dumpfile diff from the run that established this
# was 55632 lines, and every one of them was a mtime that agreed to the second
# and differed after the decimal point. (Exactly one differed in whole
# seconds: /etc, because the builder creates /etc/hosts for each RUN and this
# image ships none, so creating it moves the directory's mtime in the snapshot
# while the committed layer keeps the parent's.)
#
# So the digest is computed where a host computes it -- over the committed
# image, unpacked from its layers. build/sign-uki.sh mounts the split image
# and runs the tools stage below against that mount. Nothing about stage
# ordering can substitute: the only tree with the right timestamps is one that
# has been through a tar.
#
# The tools stage therefore ships nothing and is never run during the build.
# FROM builder rather than a fresh Debian: the bootc binary it built is at
# /output/usr/bin/bootc and the libostree it links against is already
# installed there. binutils is for one objcopy call, reading the .cmdline
# section back out of the signed UKI.
#
# Signing is a plain sbsign call rather than ukify's --secureboot-* options
# because shim verifies the leaf by walking the chain up to the MOK-enrolled
# CA, and embedding that chain (sbsign --addcert) is the part ukify cannot
# express. Details in build/uki-build.sh.
FROM builder AS uki-tools
RUN apt-get update && apt-get install -y --no-install-recommends \
      binutils sbsigntool systemd-boot-efi systemd-ukify \
 && rm -rf /var/lib/apt/lists/*
COPY build/uki-build.sh /usr/local/bin/uki-build

# The sealed image: the split rootfs, plus everything build/sign-uki.sh
# produced. That directory is a /boot overlay -- EFI/Linux/<kver>.efi is the
# signed UKI, os4/ is the build's record of what it hashed and signed -- so
# one COPY installs both. Building this target without running sign-uki.sh
# first fails here, which is the intended order made visible.
#
# Copying into /boot cannot move the digest the UKI was sealed against:
# composefs empties /boot and /sysroot outright before hashing --
# transform_for_boot() calls clear() on both and resets /boot's mtime from
# /usr's -- so files and directories underneath them are outside the measured
# tree. Both must exist, which bootc-rootfs.sh sees to. Verified against bootc
# v1.16.9 by hashing two images differing only in what the COPY had to create:
# same digest either way.
#
# Labels, STOPSIGNAL and CMD are inherited from the rootfs stage through FROM,
# so nothing repeats here.
FROM split AS sealed
COPY uki-out/ /boot/

# Default target: the classic image. Stages build in dependency order but a
# bare `podman build` produces the *last* stage, which the sealed chain above
# would otherwise have silently changed to an image that cannot upgrade an
# ostree host -- and whose build fails without uki-out/ besides. This empty
# re-alias puts the default back. CI is explicit throughout: --target rootfs
# for the main tags, then split, uki-tools and sealed for the -sealed ones.
FROM rootfs
