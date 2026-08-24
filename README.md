# os4

A Debian 13 (trixie) workstation, built and shipped as a bootable container.
The Debian counterpart to [os3](https://git.sebz.me/sebastian/os3), which does
the same thing on Fedora.

Same shape as os3 — a desktop on a `bootc` image, published to `git.sebz.me` by
Forgejo Actions, updates staged in the background rather than applied on a
reboot you did not ask for — with one deliberate difference: the desktop is KDE
Plasma 6, where os3 runs LXQt.

```
bootc switch git.sebz.me/sebastian/os4:main
```

## Why this repo is longer than os3's

os3's Containerfile starts with one line:

```dockerfile
FROM quay.io/fedora/fedora-bootc:44
```

Debian has no counterpart to that. There is no official Debian bootc base
image, and no `bootc` package in the archive either — `bootcd` is an unrelated
boot-CD tool. What exists is a community proof-of-concept
([bootcrew/mono](https://github.com/bootcrew/mono)), which tracks Debian
unstable and is explicit about being an experiment.

So os4 builds its own base rather than depending on that, and the first half of
the Containerfile is the part os3 gets for free:

| Step | What it does |
| --- | --- |
| `build/bootc-build.sh` | Builds `bootc` from a tagged upstream release in a Rust builder stage. |
| `build/apt-sources.sh` | Enables `contrib` and `non-free-firmware` alongside `main`. |
| `build/dracut-config.sh` | Configures dracut before a kernel exists to trigger it — Debian's default generator, initramfs-tools, has no ostree support. |
| `build/initramfs.sh` | Puts the kernel and a dracut initramfs where bootc reads them, rather than in `/boot`. |
| `build/enable-units.sh` | Enables the boot-time units, guarding the ones whose names differ between Debian releases. |
| `build/bootc-rootfs.sh` | Turns the ordinary Debian root into the ostree/composefs layout. |

The base plumbing follows the bootcrew reference closely, with three departures
noted below.

### The dpkg database is moved into /usr

`bootc-rootfs.sh` empties `/var`, and on Debian that is where the package
database lives. Deleting it would leave a deployed host unable to answer
`dpkg -l`, and would make the image useless as a base for a derived image that
wants to install one more package.

So the database moves to `/usr/lib/sysimage/dpkg` — mirroring where Fedora
already keeps its rpmdb, which is why os3 never had to think about this — and
`/var/lib/dpkg` becomes a symlink to it, recreated at boot by tmpfiles. The
copy under `/usr` is read-only, as everything under `/usr` is, so `apt install`
on a deployed host still will not work. That is the point of an image-mode
system; reading the database is what this preserves.

### The /var tmpfiles entries are generated, not written

bootc only materialises the image's `/var` on the initial install. A host that
reaches a new image through `bootc upgrade` keeps the `/var` it already has, so
a directory that a newly added package expects there never appears.

os3 handles this with a hand-written `libvirt-bootc.conf`, covering the one
package where the problem was noticed. os4 instead walks the `/var` tree the
packages actually built and transcribes every directory and symlink into
`/usr/lib/tmpfiles.d/zz-os4-var.conf` at build time. It covers every package
rather than the remembered one, and it reads the real modes and owners off the
tree instead of hardcoding names that differ between the distributions —
Debian's libvirt runs as `libvirt-qemu`, Fedora's as `qemu`.

### /opt is image content, not host state

The ostree convention is `/opt` → `/var/opt`, and that is what `bootc-rootfs.sh`
used to write. It has the same problem as everything else in `/var`: bootc only
materialises the image's `/var` on the initial install, so vendor software
installed to `/opt` at build time simply never appears on a host that arrives
through `bootc upgrade`. The tmpfiles generator above exists precisely because
of that, and a 431 MiB browser is not a directory you want to recreate with a
tmpfiles entry.

So `/opt` is the one state directory that is moved rather than emptied. Whatever
the package steps put there goes to `/usr/lib/opt` — the same relocation
rpm-ostree does — and `/opt` becomes a symlink to it. Vendor software that
installs to `/opt` then ships read-only and composefs-verified like the rest of
`/usr`, and upgrades arrive with the image.

What this costs is a writable `/opt` on a deployed host. `/usr/local` is still
backed by `/var` and is where machine-local additions belong. ostree's
`ostree-state-overlay@opt.service` would hand writability back, but it ships in
`ostree-boot`, which this image does not install and which also carries ostree's
own boot-time units into an image that boots off bootc's dracut module instead —
so it is a change to test rather than a drop-in. Upstream's own guidance, in
`ostree-state-overlay@.service(8)`, is to prefer symlinking just the parts that
need to be mutable into `/var` over overlaying the whole directory anyway.

Two things follow for anything installed under `/opt`. Paths baked into the
software have to be re-pointed at `/usr/lib/opt` if they are matched literally
rather than followed — Chrome's AppArmor profile is the live example. And
anything that expects to write inside its own `/opt` directory at runtime needs
that subdirectory symlinked into `/var`; nothing in this image does yet.

## The desktop is KDE Plasma

os3 runs LXQt. This runs Plasma 6.3, which is what trixie ships.

Debian offers the desktop at three sizes, and the middle one is what is
installed. Numbers below are apt's own resolution of each desktop line against
trixie, recommends on, because that is how this image installs:

| Desktop line | Packages | Installed size |
| --- | --- | --- |
| `kde-plasma-desktop` plus apps named by hand | 1730 | 4482 MiB |
| **`kde-standard`** | **1903** | **4765 MiB** |
| `kde-full` | 2367 | 6744 MiB |
| the `lxqt` line this replaces | 1894 | 5140 MiB |

`kde-standard` is `kde-plasma-desktop` plus 283 MiB, most of it KDE PIM — kmail,
korganizer, akregator, kaddressbook and the akonadi server behind them — with
juk and dragonplayer as the media players. Akonadi's first backend alternative
is `akonadi-backend-sqlite` and that is what resolves, so none of it drags in a
database daemon. `kde-full` is another 1979 MiB on top: the education suite,
games, a full TeX Live, marble's map data and 126 MiB of wallpapers.

Worth noting that the tier chosen is *smaller* than the LXQt line it replaces,
by 375 MiB. `lxqt`'s own recommends pull thunderbird, smplayer, hexchat, qmmp,
qpdfview, xscreensaver and gucharmap; Plasma's pull a desktop.

### Wayland by default, X11 kept as a fallback

`plasma-workspace` depends on `kwin-wayland`, so the Wayland session is not
optional, and it is the one Plasma 6 offers first. The X11 session is
`kwin-x11`, which arrives as a `kde-plasma-desktop` recommend and is left in
place: it is about 2 MiB, and it is what you pick at the greeter on a machine
whose GPU is not ready for Wayland yet. `xwaylandvideobridge` comes in too, so
X11 apps can still see Wayland windows when screen sharing.

The greeter itself is on Xorg. `sddm` hard-depends on `xserver-xorg | xserver`
whatever the session does, and sddm 0.21 documents its own Wayland greeter as
experimental. So Xorg is installed either way and the greeter uses it; the
session it starts is Wayland unless you choose otherwise. Flipping the greeter
as well is one `DisplayServer=wayland` in `/usr/lib/sddm/sddm.conf.d`, whenever
upstream drops the label.

### What changed alongside the metapackage

| Was | Is | Why |
| --- | --- | --- |
| `lxqt` | `kde-standard` | The desktop. |
| `network-manager-gnome` | `plasma-nm` | The applet. Named explicitly rather than left to a recommend. |
| `network-manager-openvpn-gnome` | *(dropped)* | plasma-nm ships its own OpenVPN configuration UI. The NetworkManager-side `network-manager-openvpn` plugin stays. |
| `system-config-printer` | `print-manager` | The KDE printer KCM. Nothing in this image recommends it, so it is named. |
| `xserver-xorg` | *(unnamed)* | Still installed, as an sddm dependency rather than a choice. See above. |
| — | `xdg-desktop-portal-kde` | Arrives as a `plasma-desktop` recommend; named because screen sharing and file dialogs depend on it. `xdg-desktop-portal-gtk` stays for GTK apps. |

`enable-units.sh` needed no change: `sddm.service` is the greeter under both
desktops, and `power-profiles-daemon` is what powerdevil talks to.

## What os3 has that this does not

Almost everything installed here comes from the Debian archive. There are two
exceptions, both vendor apt repositories with a pinned signing key: Anthropic's,
for the Claude desktop app, and Google's, for Chrome. These are the os3 packages
that have no Debian equivalent, left out of this first cut:

| os3 | Why not here |
| --- | --- |
| rpmfusion codecs | No Debian equivalent for the DVD/BluRay side; `deb-multimedia` is the third-party option. Note that trixie's own `ffmpeg` already links `libx264` and `libx265`, so H.264/H.265 playback is not the gap this row once implied. |
| `discord` | Vendor `.deb` download only. |
| `steam`, `gamescope` | `steam-installer` is in `contrib`, which is enabled here, but wants i386 multiarch; gamescope is not packaged for Debian at all. `mangohud` is installed. |
| `tailscale` | `pkgs.tailscale.com` apt repo. |
| `tea` | Gitea's CLI is a release binary. Debian ships a `tea` package, but it is an unrelated text editor, so the name is not usable. |
| `uv` | Astral release binary. |
| `nix` | Debian has `nix-bin` and `nix-setup-systemd`; skipped along with the `ostree-state-overlay@nix` unit that goes with it — which would also mean installing `ostree-boot`, since that is where the unit template lives and this image does not currently pull it in. |
| `v4l2loopback`, `akmods` | Debian's route is `v4l2loopback-dkms` built against the image kernel at build time. Not wired up. |
| DNIe PKCS#11 | Upstream ships an RPM. Would need unpacking, and Debian's CA trust layout differs from Fedora's. |

Each is additive — a repo, a keyring and a package name — so they can come back
one at a time. `gh` and `glab` used to be on this list and are not any more:
both are in trixie `main` and are installed. `google-chrome-stable` has come off
it too; see below.

`claude-desktop` was the first row actually done the additive way, in
`build/claude-desktop.sh`, and `google-chrome.sh` follows it: fetch the key,
**pin its fingerprint**, write a deb822 entry, install the package. The pin is
the part worth copying — a keyring baked into the image authorises root-owned
packages on every host that boots it.

### Chrome, and why not just `chromium`

`chromium` is in trixie `main` and would need no third-party repository at all.
The usual arguments for Google's build mostly do not apply to it: Debian builds
with `proprietary_codecs=true` and `ffmpeg_branding="Chrome"`, so H.264 and AAC
work; `use_vaapi=true` on amd64, so hardware decode is compiled in;
`is_official_build=true`; and Google-assigned API keys ship in
`/etc/chromium.d/apikeys`. Nor is it stale — trixie tracks upstream closely
enough that its `chromium` and `google-chrome-stable` are usually on the same
milestone. Installed size is comparable too, around 375 MiB against Chrome's
440 MiB.

What Debian cannot ship is the part that decided it:

| | `chromium` (trixie) | `google-chrome-stable` |
| --- | --- | --- |
| Widevine CDM | Compiled in (`enable_widevine=true`), but no CDM binary. `widevine-installer` is in `contrib` and reaches trixie only through backports. So no Netflix, Prime Video or Spotify web. | Bundled. |
| Chromecast | `--media-router=0` in `/etc/chromium.d/default-flags`, from Debian bug #833477. | On. |
| Component updater | Not wired to Google's component server: no CRLSet revocation updates, no origin-trial tokens. | On. |
| Sync | Debian's API keys are present, but Google restricted the sync API to official builds in 2021. | Works. |
| Channels | — | `beta`, `unstable`, `canary` also in the repo. |

`plasma-browser-integration` arrives with `kde-standard` and supports both, and
`claude-desktop` already creates `/etc/opt/chrome/native-messaging-hosts`. Both
browsers can be installed side by side if you would rather have the archive
build as well; `update-alternatives` sorts out `x-www-browser`.

Two things in Chrome's packaging need correcting for an image-mode system, and
`build/google-chrome.sh` does both. Its AppArmor profile attaches to the literal
path `/opt/google/chrome/chrome`, and AppArmor matches the resolved path rather
than the symlink, so the profile has to be re-pointed at `/usr/lib/opt` once
`bootc-rootfs.sh` has moved the tree — it is inert on Debian, which does not
restrict unprivileged user namespaces the way Ubuntu does, but a profile that
silently matches nothing is worse than none. And `/etc/cron.daily/google-chrome`
symlinks into `/opt/google/chrome/cron/`, where the script calls `install_key`
unconditionally and writes to `/usr/share/keyrings` — read-only on a deployed
host. Nothing runs it today, because this image installs no cron daemon; the
symlink is removed so that stays true if one is ever added.

## Recommends are installed

Stage 2 installs with apt's recommends left on, everywhere. Debian's
`--no-install-recommends` habit comes from servers, where a lean root is the
point; this image is a desktop, and a good deal of what makes one work is
recommended rather than depended on. Concretely, leaving them on is what brings
in `intel-microcode` and `amd64-microcode`, the GPU firmware, `shim-signed`,
podman's rootless networking (`passt`, `slirp4netns`, `aardvark-dns`),
virt-manager's SPICE console and qemu's display modules — every one of which
had to be noticed and added by hand otherwise.

It costs roughly 180 packages and 700 MiB of installed size against the old
flag-everywhere build, the bulk of it a C toolchain reached through
`npm` → `node-gyp` → `build-essential`, plus `buildah` from podman.

Stage 1 keeps `--no-install-recommends`: nothing there is shipped, only
`/output` is copied forward, so recommends would cost build time and buy the
image nothing.

## Firmware is named explicitly

The one thing recommends do not cover. Fedora has a single `linux-firmware`
package, so os3 gets every blob without asking for any; Debian splits the same
tree per vendor, and `firmware-linux` pulls only the graphics and misc pieces.
Nothing recommends the rest, so the wifi, bluetooth and audio-DSP firmware is
listed by name: `firmware-iwlwifi`, `firmware-atheros`, `firmware-realtek`,
`firmware-brcm80211`, `firmware-sof-signed`, `firmware-intel-sound`,
`firmware-cirrus`. About 286 MiB, and without it a laptop booting this image
has no wifi.

Named rather than "everything in `non-free-firmware`", which would be ~944 MiB
— mostly enterprise NICs, plus 298 MiB of `firmware-qcom-soc` for Qualcomm SoCs
this amd64 image cannot run on.

The setcap step at the end of os3's Containerfile has no counterpart here. It
restores file capabilities that the CI runner's docker drops when it re-pushes
the base image's layers; dpkg records no capabilities to restore them from, and
the binaries whose loss broke rootless podman on os3 — `newuidmap`,
`newgidmap` — are setuid rather than capability-based on Debian, and setuid
bits survive.

## Workflows

| Workflow | Trigger | Notes |
| --- | --- | --- |
| `publish.yml` | push to `main`, PRs, releases, every other day | Builds on the `hetzner-host` runner with the host's docker, then pushes with `skopeo copy --format oci` — not `docker push`, see [OCI media types are not optional](#oci-media-types-are-not-optional). Signs the pushed digest with cosign when `COSIGN_PRIVATE_KEY` is set. PRs build without pushing. |
| `build-disk.yml` | manual | os3's anaconda-ISO workflow, adapted. Anaconda is Fedora's installer and cannot install a Debian root, so this produces a qcow2 (or raw, or vmdk) disk image instead. Does not currently work — see [Installing to a disk](#installing-to-a-disk). |
| `cleanup-packages.yml` | daily | Unchanged from os3 apart from the package name. |

## Installing to a disk

`bootc switch` covers a host that is already running an image-mode system.
Getting to the first one means writing this image to a disk, and of the two
routes that looked available, one does not work.

### bootc-image-builder does not build this image

`build-disk.yml` has never run, and running bootc-image-builder against the
published image by hand shows it cannot. osbuild's `org.osbuild.selinux` stage
runs `setfiles` against
`/etc/selinux/targeted/contexts/files/file_contexts` unconditionally, and a
Debian root has no targeted policy for it to read:

```
/run/osbuild/tree/etc/selinux/targeted/contexts/files/file_contexts: No such file or directory
error: cannot run osbuild: error running osbuild: exit status 1
```

It dies there every time, before writing any disk, and no bib flag disables the
stage. The workflow needs either `selinux-policy-default` installed into the
image or a manifest with that stage patched out before it produces anything.
Until then it is kept for the record rather than because it works.

### OCI media types are not optional

`bootc install` reads the image out of the local container storage, through
skopeo's image proxy. The proxy presents whatever is stored as OCI, and an OCI
manifest needs an OCI config — so for an image stored as Docker schema 2, the
proxy re-encodes the config and asks storage for a blob at the *new* digest.
Storage only ever held the original. The install dies after formatting the
disk and before writing a byte of it:

```
error: Installing to disk: Getting container info: failed to invoke method
GetBlob: locating item named "sha256:1d7d2e562b06..." for image with ID
"fb792ea47559..." (consider removing the image to resolve the issue):
file does not exist
```

The message's own advice does not work. The digest is derived from the
manifest, so `podman rmi` and a fresh pull reproduce it exactly. Nothing is
corrupt; the request is for a blob that never existed.

This is why a locally built image installed while the published one could not:
`podman build` writes OCI manifests, `docker push` writes schema 2, and the
Containerfile is the same either way. `publish.yml` now pushes with
`skopeo copy --format oci`, so the published image is OCI from here on.

For an image already in storage as schema 2, convert it on the way in and the
image ID becomes the config digest bootc was asking for:

```
podman rmi git.sebz.me/sebastian/os4:main
skopeo copy --format oci \
  docker://git.sebz.me/sebastian/os4:main \
  containers-storage:git.sebz.me/sebastian/os4:main
```

### bootc install to-disk, with two flags that are not optional

Run from the image itself, against a file over loopback:

```
truncate -s 40G disk.raw
podman run --rm --privileged --pid=host \
  --security-opt label=type:unconfined_t \
  -v /dev:/dev -v /var/lib/containers:/var/lib/containers -v .:/work \
  git.sebz.me/sebastian/os4:main \
  bootc install to-disk --via-loopback --wipe --filesystem ext4 \
    --composefs-backend --bootloader systemd \
    --target-imgref git.sebz.me/sebastian/os4:main /work/disk.raw
```

`--composefs-backend` is what makes it work. bootc installs bootloaders through
bootupd, which Debian does not package and this image therefore does not carry.
With the ostree backend that leaves nothing it will accept — `Bootloader::Grub`
is the only arm that installs anything, and systemd-boot falls through to a
hard `bootupd is required for ostree-based installs`
(`crates/lib/src/install.rs`, bootc 1.16.9). systemd-boot is implemented only
under the composefs backend. The image already asks for composefs in
`prepare-root.conf` and bootc formats the root with `-O verity` for it, so this
is the layout it was built for, not a workaround.

`--target-imgref` points the installed system at the published image. It
matters whenever the thing being installed is a locally derived tag: without
it the deployment tracks an image reference that exists only on the build host,
and `bootc upgrade` has nothing to fetch.

### An encrypted root, and the package it depends on

`to-disk` offers exactly two root layouts: `--block-setup direct`, the default,
and `--block-setup tpm2-luks`. Anything else — a passphrase-unlocked LUKS
container, LVM, RAID — means building the block devices by hand and using
`bootc install to-filesystem` instead.

tpm2-luks works with the composefs backend. The two backends share the whole
block-device path: `install_to_disk` calls `baseline::install_create_rootfs`,
which is where LUKS is set up, and only branches on the backend afterwards in
`install_to_filesystem_impl`. The kargs that baseline generates reach the boot
entry, because `setup_composefs_bls_boot` extends its cmdline with
`root_setup.kargs` (`crates/lib/src/bootc_composefs/boot.rs`, bootc 1.16.9).
`-O verity` is still applied to the ext4 root, on the `/dev/mapper` device
rather than the partition, so the `verity=require` this image asks for in
`prepare-root.conf` holds over dm-crypt.

What it needs from the image is `tpm2-tools`, and not for anything a user would
type. dracut's `91tpm2-tss` is the only module that puts libtss2 and
`libcryptsetup-token-systemd-tpm2.so` into the initrd, its `check()` is
`require_binaries tpm2 || return 1`, and `01systemd-cryptsetup` only picks a
module up as a dependency when its check returns 255. Miss the binary and the
initrd is built with `systemd-cryptsetup` but nothing to reach `/dev/tpmrm0`
with — systemd-cryptsetup dlopens libtss2 rather than linking it, so no
automatic dependency tracking saves it. The install itself succeeds either way,
since enrolment runs from the container, which does have the libraries; the
disk then fails to unlock its root on first boot. `tpm2-tools` is on the
block-tools line in the Containerfile for this reason alone.

Two edges remain sharp even with the package in place. bootc enrols the TPM
with `systemd-cryptenroll --wipe-slot=all` (`crates/lib/src/install/baseline.rs`),
so the TPM is the *only* keyslot on the installed disk, and it writes
`luks.options=tpm2-device=auto,headless=true` into the boot entry, which
suppresses the passphrase prompt whether or not a passphrase slot exists.
Enrolling a recovery key is therefore the first thing to do after first boot,
while the TPM can still authorise the new slot:

```
systemd-cryptenroll --unlock-tpm2-device=auto --recovery-key /dev/nvme0n1p4
```

That key is a way back in from live media or from a boot where `headless=true`
has been edited out of the cmdline in the systemd-boot menu, not something the
normal boot path will ever ask for. The realistic way to need it is PCR 7:
systemd-cryptenroll binds to it by default, it measures Secure Boot state, and
a firmware update is enough to change it.

Partition 4, not 3: tpm2-luks is the one setup whose `requires_bootpart()` is
true, so the disk gains a separate XBOOTLDR `/boot` between the ESP and the
root, on top of the 1 MiB BIOS-BOOT partition bootc writes on x86_64 whether
or not anything will ever boot from it. `lsblk -f` and the `crypto_LUKS` row
settle it on any given disk.

### What the installed disk still does not have

No user accounts. Nothing in the Containerfile runs `useradd`, and root has no
password, so a disk installed as above boots to an sddm greeter with nobody to
log in as. Either pass `--root-ssh-authorized-keys` and create the account over
ssh on first boot, or install a thin derived image that adds one — `useradd`
needs `/var/home` created first, since tmpfiles only makes it at boot and
`/home` is a symlink into a `/var` the image ships empty.

UEFI is required: the image installs systemd-boot and no BIOS bootloader.
Secure Boot has to be off — `/usr/lib/systemd/boot/efi/` holds only the
unsigned `systemd-bootx64.efi`, with no signed counterpart for `shim-signed` to
chainload.

## Updates

As in os3: `bootc-fetch-apply-updates.timer` is disabled, and
`bootc-download-updates.timer` replaces it. It runs `bootc upgrade
--download-only` every 8 hours with a 2-hour jitter, so a new deployment is
staged and waiting but nothing reboots until you do.
