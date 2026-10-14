# os4

A Debian 13 (trixie) workstation, built and shipped as a bootable container.
The Debian counterpart to [os3](https://git.sebz.me/sebastian/os3), which does
the same thing on Fedora.

Same shape as os3 — a desktop on a `bootc` image, published to `ghcr.io` by
GitHub Actions and signed keylessly with cosign, updates staged in the
background rather than applied on a reboot you did not ask for — with one
deliberate difference: the desktop is KDE Plasma 6, where os3 runs LXQt.

```
bootc switch ghcr.io/isibek04/os4:main
```

Two more images are published under a second package, `linux`, both of them
the sealed variant described under [Secure Boot](#secure-boot):

| Image | What it is |
| --- | --- |
| `ghcr.io/isibek04/linux:main` | `os4:main-sealed`, the same manifest under a second name |
| `ghcr.io/isibek04/linux:main-nvidia` | The same sealed build with NVIDIA's 580 driver in it — see [NVIDIA's driver, in the `-nvidia` image](#nvidias-driver-in-the--nvidia-image) |

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
| `build/bootc-build.sh` | Builds `bootc` from a tagged upstream release in a Rust builder stage. The tag is pinned in the Containerfile's `BOOTC_REF`, not resolved at build time: `publish.yml` builds on a timer, and the boot path is not something an unattended build should be free to change. |
| `build/apt-sources.sh` | Enables `contrib` and `non-free-firmware` alongside `main`. |
| `build/dracut-config.sh` | Configures dracut before a kernel exists to trigger it — Debian's default generator, initramfs-tools, has no ostree support. |
| `build/initramfs.sh` | Puts the kernel and a dracut initramfs where bootc reads them, rather than in `/boot`. |
| `build/enable-units.sh` | Enables the boot-time units, guarding the ones whose names differ between Debian releases. |
| `build/bootc-rootfs.sh` | Turns the ordinary Debian root into the ostree/composefs layout. |
| `build/apparmor-home.sh` | Teaches AppArmor's `@{HOME}` that home directories live under `/var`. |

The base plumbing follows the bootcrew reference closely, with five departures
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

### TeX Live's generated tree is moved into /usr too

`texlive-full` is the second case of the same problem, and the bigger one.
Debian's TeX does not ship its formats: `tex-common`'s postinst and triggers
build them at install time into `/var/lib/texmf`, Debian's `TEXMFSYSVAR`,
along with the assembled `fmtutil.cnf` and `updmap.cfg`, the hyphenation
config, the merged font maps and the `ls-R` filename databases for every tree.
None of that belongs to a package, so the file-entry generator below does not
see it, and step 3 of `bootc-rootfs.sh` left a deployed host with the empty
directory skeleton and nothing in it. Every pointer into the tree dangled —
`/usr/share/texmf/ls-R`, `texmf-dist/ls-R`, both `web2c/fmtutil.cnf` and
`web2c/updmap.cfg`, the three `language.*` files — and `pdflatex` stopped at
"I can't find the format file".

The tree is a pure function of the installed packages, which makes it image
content that happens to live at a `/var` path. So it moves to `/usr/lib/texmf`
and `/var/lib/texmf` becomes a symlink to it, on the dpkg pattern above. That
is right on both paths a host reaches an image by: a fresh install gets the
formats with everything else, and `bootc upgrade` brings the dumps that match
the new binaries rather than leaving the previous release's in a `/var` that
upgrades never touch. The alternative — a first-boot unit running
`fmtutil-sys --all` — would spend on every machine, after every upgrade, the
minutes the build has already spent once.

The symlink's tmpfiles entry is `L+` rather than `L`. A host that booted the
image before this fix has the empty directory tree at `/var/lib/texmf`, and a
plain `L` creates its symlink only where nothing is; `L+` removes what is there
first. The generator confines `L+` to the two paths the script itself moved,
since those are the only ones where a directory at the path is known to be a
leftover of this image's own layout rather than somebody's state.

The cost is the same as for dpkg: `TEXMFSYSVAR` is read-only, so
`fmtutil-sys`, `updmap-sys` and `mktexlsr` fail on a deployed host, the same
way `apt install` does. Per-user configuration is untouched — `TEXMFVAR` and
`TEXMFCONFIG` are under `$HOME`, which is where `fmtutil-user`, `updmap-user`
and on-demand `mktexfmt` write — and a system-wide change is an edit under
`/etc/texmf` followed by an image rebuild, which is where a change to `/usr`
belongs on this system. `/usr/lib` rather than `/usr/share` because the `.fmt`
dumps are engine- and architecture-specific.

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

#### Files, not just directories

Directories and symlinks describe themselves in tmpfiles. Regular files do not:
an entry can create an empty file but not fill one. So a *file* a package
shipped under `/var` needs its content kept somewhere that survives the step
that empties `/var`, and the generator above transcribed neither the file nor
its content — it emitted nothing at all for them.

Missing this is worse than the upgrade-path problem the generator was written
for, because it is not confined to the upgrade path. `bootc-rootfs.sh` empties
the `/var` that ships **in the image**, so on a fresh `bootc install` there is
nothing left for bootc to materialise either. `bootc container lint` does not
catch it; its `var-tmpfiles` check is about directories.

So those files now move to `/usr/share/factory/var`, alongside everything else
that goes under `/usr`, and the generator emits systemd-tmpfiles `C` entries —
whose bare argument resolves to exactly that path. `C` copies only when the
destination does not exist, so a file a host has since edited is left alone.

Which files count is asked of dpkg rather than read off the tree. A `.list`
entry is content some package installed, which is precisely what has to
survive; build residue — apt's package lists, dpkg's own logs, `/var/backups` —
belongs to no package and is skipped without needing a list of exceptions to
maintain.

The set is small, and worth being accurate about, because most of what dpkg
lists under `/var` is *not* affected. Of ~350 `.list` entries under `/var` on a
desktop root, around 228 are symlinks — `/var/lib/ghostscript/CMap/*` points
into `/usr/share/poppler`, and every one of those was already covered by the
`L` entries — and about 100 are directories, covered by the `d` entries. What
was actually being lost is the couple of dozen regular files left over: the
hunspell dispatch tables under `/var/lib/dictionaries-common`, which is how
hunspell dictionaries are found at all, `usb.ids`, `/var/lib/xkb`'s compiled
cache marker, `tex-common`'s `fmtutil` and font-map fragments on an image that
installs TeX — the *inputs* to the tree the section above relocates, not the
tree itself. Two hundred-odd KiB of content, and every one of them silently
absent before this.

It is worth fixing at that size anyway. The cost is a few hundred KiB under
`/usr` and no build-time complexity, and the failure mode is the expensive kind
— a file that is simply not there, on a system where `apt install --reinstall`
is not available to put it back. It also stops being a question of which
packages happen to be in the Containerfile today: the generator now covers the
file case for whatever gets added later, rather than being correct by accident
for the current package list.

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

### AppArmor has to be told where home is

`/home` is a symlink to `/var/home` and `/root` one to `/var/roothome`, which is
the ostree layout and not negotiable. AppArmor matches the path a process
actually resolves to rather than the symlink it typed — the same rule that makes
`google-chrome.sh` re-point Chrome's profile at `/usr/lib/opt` — and every
profile in the archive names a user's files through `@{HOME}`, which
apparmor's `tunables/home` builds out of `@{HOMEDIRS}`, which is `/home/` and
nothing else.

So on an untreated image every `owner @{HOME}/...` rule matches a path that no
process here ever has, and a confined application is denied its own files.
`build/apparmor-home.sh` appends `/var/home/` and `/var/roothome/` through
`tunables/home.d`, apparmor's own extension point for exactly this.

os3 never had to think about it. Fedora is on SELinux, which decides on the
label a file carries rather than on the path an access names, and the
`fedora-bootc` base ships the same `/home` → `/var/home` layout already
labelled. Here the layout is assembled by hand, and the policy that comes with
the archive was written for the layout Debian normally has.

The bug this fixes is worth describing, because nothing about it points at
AppArmor. `kde-standard` installs KDE PIM, `akonadi-server` ships an *enforcing*
profile, and kmail stores everything through akonadi. Without the tunable the
server cannot create its SQLite database, crashes on startup, is restarted
twice, and gives up — reporting:

```
Cannot remove old log file '~/.local/share/akonadi/Akonadi.error.old': Permission denied
KCrash: Application 'akonadiserver' crashing...
org.kde.pim.akonadicontrol: Application '/usr/bin/akonadiserver' crashed too often. Giving up!
```

against a directory the invoking user owns outright, mode 775. AppArmor writes
its denials to the audit log and never to the application, so the only thing
visible is a permission error that the permissions plainly allow. `dmesg` is
where the answer is, and the mail client is not what makes anyone look there.

It is also not only kmail. `@{HOME}` is in nearly every profile the archive
ships, so this is the one line that keeps every confined desktop application on
this image able to read the home directory it was pointed at.

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

### Mesa comes from trixie-backports

Trixie's Mesa is 25.0, and its NVK — the Vulkan driver that runs on nouveau —
only starts at Turing. Maxwell, Pascal and Volta were enabled in 25.1, so on
25.0 a laptop's Maxwell dGPU (a GeForce MX130 here) has no Vulkan device at
all, and `vulkaninfo` lists the Intel iGPU and llvmpipe. `trixie-backports`
carries 26.1.

`build/mesa-backports.sh` adds the backports source and raises exactly two
source packages to 990: `mesa`, and `elfutils`, whose `libelf` the backported
Mesa needs a newer version of. Pinning by source name moves every binary built
from each together — all of Mesa's drivers on one version, `libelf` and `libdw`
on one version — and the rest of backports stays at its default 100, where apt
never picks it on its own. It runs straight after `apt-sources.sh`, because
`kde-standard` pulls Mesa in well before the GPU stack names it.

This does not make the dGPU fast. Nouveau cannot raise Maxwell's clocks on its
own, so the card stays at its boot clocks, which NVK does nothing about. The
`-nvidia` image below is the answer to that.

### NVIDIA's driver, in the `-nvidia` image

`linux:main-nvidia` is the sealed image with NVIDIA's proprietary driver in
place of nouveau. The branch is 580, because it is the last one that drives
Maxwell, Pascal and Volta — 590 dropped them. It is the proprietary kernel
module, `nvidia-kernel-dkms`, not the open one, which starts at Turing.

Getting 580 onto trixie takes more than an apt line:

- **Debian has no 580.** Trixie, its backports and sid all stop at 550, and
  NVIDIA's own `debian13` repository starts at 590. The 580 packages exist only
  in NVIDIA's `debian12` repository. They are self-contained binaries against
  libc, X and Wayland, and they install and build against trixie's 6.12 kernel
  cleanly.
- **Three companion libraries come along.** `nvidia-driver-libs` at 580 wants
  `libnvidia-egl-wayland1` 1.1.19 or later, and trixie has 1.1.18. It also
  wants `libnvidia-egl-xcb1` and `-xlib1`, which trixie does not package.
  `build/nvidia.sh` pins NVIDIA's repository to 100 as a whole, then raises
  only the driver's own sources (at `580.*`, since the repository carries 590
  and newer as well) and `egl-wayland`, `egl-gbm` and `egl-x11` to 990. Nothing
  else in it, and it carries CUDA and a good deal more, is ever chosen.
- **Trixie's apt cannot verify the repository.** The signing key, `cudatools`
  (`EB69 3B30 35CD 5710 E231 E123 A4B4 6996 3BF8 63CC`), binds its user ID with
  a SHA-1 self-signature, and trixie's `sqv` has rejected those since
  2026-02-01. The signature on the repository itself is SHA-256. So the key is
  fingerprint-pinned as every vendor key here is, and one `apt-get update`,
  pointed at the NVIDIA source alone, verifies with `gpgv`, which is what
  bookworm's apt used. No apt.conf setting is written, so every other
  repository keeps `sqv`. The source, its key and its pin are removed again
  once the driver is in, because a host's own `apt update` could not verify it
  either. The driver is updated the way everything else is: by the next image
  build, at the newest 580 point release.

The rest is what a driver needs in image mode:

- **The modules are signed** with the Secure Boot leaf key, the same way and
  for the same reason as [v4l2loopback's](#v4l2loopback-and-a-module-signature-that-is-not-the-ukis).
  The `openssl` and `sign-file` calls now live in `build/sign-module.sh`, which
  both scripts call. The modules go back to xz after signing: `nvidia.ko` is
  ~100 MiB uncompressed. They load under lockdown on a host that has enrolled
  the os4 CA *and* run `mokutil --trust-mok`, which the sealed image needs
  anyway.
- **Neither nouveau nor nvidia goes in the initramfs.** The package blacklists
  nouveau in `/etc/modprobe.d`, but the initramfs is built `hostonly=no`, and
  dracut's drm module takes every DRM driver it finds. That would mean nouveau
  binding the card before the root's blacklist exists, and the nvidia modules
  with ~70 MiB of GSP firmware a Maxwell card never loads, in a UKI that lives
  on the ESP. A dracut `omit_drivers` keeps both out, and nvidia loads from
  the root.
- **The suspend units are enabled.** The package sets
  `NVreg_PreserveVideoMemoryAllocations=1`, which relies on
  `nvidia-suspend`, `-resume`, `-hibernate` and `-suspend-then-hibernate` to
  save video memory, and enables none of them. `nvidia-drm.modeset=1` is the
  package's own default, so the Wayland session works as it is.
- **`nvidia-smi` is installed alongside.** It is a package of its own that
  the driver does not pull in, from the same source and so on the same pinned
  version; the NVML library it talks to already comes with the driver.
- **DKMS's copy of the modules is deleted** in the same layer, so ~90 MiB of
  unsigned duplicates do not ride along in the image's history.

It is the one variant built with an argument. The Containerfile declares
`ARG NVIDIA_DRIVER` just after the v4l2loopback step, and `build/nvidia.sh`
does nothing when it is empty. So every layer above it is shared with the
other images, and only the tail is built again: the driver, the initramfs,
`bootc-rootfs.sh` and the sealed stages. The build has its own UKI, because a
different tree is a different composefs digest. It is built only when the
sealed variant is, so it always has the key. It is verified with
`verify-sealed.sh` like the sealed image. A failure in it fails the job only
at the very end, after everything else has been pushed: it depends on a
repository nothing else here touches.

Build it locally with:

```
podman build --target rootfs --build-arg NVIDIA_DRIVER=580 \
  --secret id=sb_leaf_key,env=SB_LEAF_KEY -f Containerfile .
```

## What os3 has that this does not

Almost everything installed here comes from the Debian archive. There are six
exceptions. Three are vendor apt repositories with a pinned signing key —
Anthropic's, for the Claude desktop app, Google's, for Chrome, and Tailscale's,
for the node agent — and three are bare `.deb`s: pandoc, which is in the archive
but two years behind upstream and has no backport — see [Pandoc, and a `.deb`
worth pinning](#pandoc-and-a-deb-worth-pinning); the UDS client, which is
published only by the VDI broker it connects to — see [The UDS client, and a
`.deb` only its server publishes](#the-uds-client-and-a-deb-only-its-server-publishes);
and GLPI Agent, which trixie does not package at all — see [GLPI Agent, and an
inventory that is opt-in per machine](#glpi-agent-and-an-inventory-that-is-opt-in-per-machine).
These are the os3 packages that have no Debian equivalent, left out of this
first cut:

| os3 | Why not here |
| --- | --- |
| rpmfusion codecs | No Debian equivalent for the DVD/BluRay side; `deb-multimedia` is the third-party option. Note that trixie's own `ffmpeg` already links `libx264` and `libx265`, so H.264/H.265 playback is not the gap this row once implied. |
| `gamescope` | Not packaged for Debian at all. `mangohud` is installed. |
| `steam`, `discord` | Were installed here once and have been taken out. |
| `tea` | Gitea's CLI is a release binary. Debian ships a `tea` package, but it is an unrelated text editor, so the name is not usable. |
| `uv` | Astral release binary. |
| `nix` | Debian has `nix-bin` and `nix-setup-systemd`; skipped along with the `ostree-state-overlay@nix` unit that goes with it — which would also mean installing `ostree-boot`, since that is where the unit template lives and this image does not currently pull it in. |
| `akmods` | Fedora's generic DKMS-alike, with no single Debian equivalent -- `v4l2loopback`, the one thing os3 uses it for, is wired up directly below instead. |
| DNIe PKCS#11 | Upstream ships an RPM. Would need unpacking, and Debian's CA trust layout differs from Fedora's. |

Each is additive — a repo, a keyring and a package name — so they can come back
one at a time. `gh` and `glab` used to be on this list and are not any more:
both are in trixie `main` and are installed. `google-chrome-stable` and
`tailscale` have come off it too; see below.

`claude-desktop` was the first row actually done the additive way, in
`build/claude-desktop.sh`, and `google-chrome.sh` and `tailscale.sh` follow it:
fetch the key, **pin its fingerprint**, write a deb822 entry, install the
package. The pin is the part worth copying — a keyring baked into the image
authorises root-owned packages on every host that boots it.

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

#### Chrome's fontconfig, and a desktop that crashes an hour later

A third correction is not in Chrome's packaging but in its binary, and it is
the reason two images in a row "worked for a while" and then lost Plasma.

Chrome links its own fontconfig statically, and the copy in Chrome 154 writes
cache format 12. Trixie's libfontconfig writes format 9. Both use the same
`~/.cache/fontconfig`. When Chrome builds its cache it writes
`<hash>-le64.cache-12` for every font directory and then replaces the
`-cache-9`, `-10` and `-11` entries for the same directories with symlinks to
its own file. Trixie's fontconfig does not reject a cache whose format number
is newer than its own, so the next program to load fonts maps a format-12 file as
format 9. The layout differs and `FcCharSetHasChar` walks off the end:
plasmashell dies in `QQuickText` layout three times and systemd gives up, and
`kscreenlocker_greet` dies the same way, so the screen cannot be unlocked.
Programs already running are unaffected; they mapped their caches at start.
That is why the crash waits for the next login or lock after the first Chrome
launch on a new image.

A new image is what triggers it. The font directories' mtimes change with every
build, both cache formats go stale at once, and Chrome is the first to rebuild.
Once Chrome's format-12 files exist it leaves the `-9` names alone. The two
formats coexist in one directory without harm, and it is only the links that do
damage.

The bug is Chromium's, tracked as
[crbug 565132857](https://issues.chromium.org/issues/565132857), a P0 release
blocker for M154. The links come from a change to Chromium's bundled
fontconfig (`366787e4` in its fontconfig mirror) that assumed older readers
could use format 12. Reports there cover system fontconfig 2.15 through 2.17
and other programs besides Plasma (Konsole, Okular, Telegram), and reports
elsewhere name Brave too. A Chromium engineer notes that the formats only
diverge when Type 1 or WOFF fonts sit in fontconfig's directories. texlive-full
puts plenty of both under `/usr/share/fonts`, which is why this image hits it
after every rebuild.

The fix is `os4-fontconfig-unlink.path` and its `.service`, per-user units
enabled for every account. The path unit watches `~/.cache/fontconfig`, and the
service deletes symlinks in it the moment they appear, plus once per login for
anything left while nothing was watching. Debian's fontconfig never creates a
link, so nothing legitimate is lost. Chrome's own format-12 files stay, so
Chrome does not rebuild. Both start limits are off: Chrome writes a few hundred
entries in one burst, and systemd's default of five starts in ten seconds
stopped the cleaner halfway through when it was first tried.

The units are a stopgap. Chromium has a fix in review aimed at M154 and M155.
Once the image carries a Chrome that no longer creates the links, delete both
units and their line in `build/enable-units.sh`. Until then they cost nothing,
because a service with no links to delete does nothing. To check a Chrome
version without touching the real cache:

```bash
T=$(mktemp -d)
XDG_CACHE_HOME=$T google-chrome --headless=new --user-data-dir=$T/profile --screenshot=$T/s.png 'data:text/html,<p>x</p>'
find $T/fontconfig -type l | wc -l
```

Anything other than 0 means the units are still needed.

The obvious alternative, which is to point Chrome at a cache directory of its
own with `FONTCONFIG_FILE` in its launcher, was tested and rejected. Every
process Chrome starts inherits the variable. That includes `xdg-open`, which
opens downloads in Okular or LibreOffice, and the native messaging hosts. Those
processes then read Chrome's private directory with trixie's fontconfig and
crash the same way. `FONTCONFIG_NO_CHECK_CACHE_VERSION`, which only Chrome's
copy understands, does not stop the links either. The `FONTCONFIG_FILE`
approach is also the workaround most of the upstream thread recommends, and one
reproduction there shows Okular crashing under exactly that variable.

If it happens anyway, for example on a host that has not reached this image
yet, the way out is from a text console:
`mv ~/.cache/fontconfig ~/.cache/fontconfig.bad && loginctl unlock-sessions`,
then `systemctl --user restart plasma-plasmashell`.

### The third-party installs, side by side

What image mode actually asks of each of the six:

| | Trust anchor | Lands in `/opt` | Self-update target |
| --- | --- | --- | --- |
| `claude-desktop` | Anthropic's key, fingerprint pinned | No — `/usr/lib` | apt, so the image |
| `google-chrome-stable` | Google's key, fingerprint pinned | 431 MiB, folded into `/usr/lib/opt`; AppArmor profile re-pointed, daily cron symlink removed | apt, so the image — but `/etc/cron.daily/google-chrome` would write to a read-only `/usr/share/keyrings` |
| `tailscale` | Tailscale's key, fingerprint recorded — but not one Tailscale publishes | No — `/usr/bin`, `/usr/sbin` | apt, so the image — unless `--auto-update` is switched on, which shells out to `apt-get` and cannot work here |
| `pandoc` | SHA-256 of the release `.deb`, pinned with its version | No — `/usr/bin` | None; the image |
| `udsclient3` | SHA-256 of the broker's `.deb`, pinned with its version | No — `/usr/lib/UDSClient` | None; the image |
| `glpi-agent` | SHA-256 of the release `.deb`, pinned with its version | No — `/usr/share/glpi-agent`; empty `/var/lib/glpi-agent` becomes a tmpfiles entry | None; the image |

### Tailscale, and a daemon that ships disabled

The third vendor apt repository here, and the most recent row to come off the
os3 list above. `build/tailscale.sh` is the pattern `claude-desktop.sh` set —
fetch the key, pin its fingerprint, write a deb822 entry, install — and what is
worth spelling out is where it departs from Tailscale's own installer. Reduced
to what it does on a Debian host, `scripts/installer.sh` is:

```sh
curl … "https://pkgs.tailscale.com/$TRACK/$OS/$VERSION.noarmor.gpg" \
  > /usr/share/keyrings/tailscale-archive-keyring.gpg
curl … "https://pkgs.tailscale.com/$TRACK/$OS/$VERSION.tailscale-keyring.list" \
  > /etc/apt/sources.list.d/tailscale.list
apt-get install -y tailscale tailscale-archive-keyring
systemctl enable --now tailscaled
```

The middle of that is what this image wants too — a keyring, a source entry,
the package. The last line is not, and the first is missing a check.

#### The pin is real; the claim behind it is weaker than the other two

The key `pkgs.tailscale.com` serves is
`2596A99EAAB33821893C0A79458CA832957F5868`, *Tailscale Inc. (Package repository
signing key)*, and `tailscale.sh` refuses to continue if the fetch returns
anything else. But unlike Anthropic and Google, Tailscale publishes no
fingerprint alongside the repository to check that against: the constant in the
script was read off the key the repository serves, not out of documentation. So
it is not a second opinion about the key — it is a record of the one the build
first saw, which is still enough to make a change to it a commit rather than a
Tuesday.

The repository is keyed by Debian codename rather than a `stable` suite, so the
suite follows `apt-sources.sh`'s `DEBIAN_SUITE`. A codename Tailscale does not
publish 404s on the key fetch and stops the build, which is the right way for
that to fail. `Architectures: amd64 arm64` is set as it is on the other two
vendor entries. No foreign architecture is enabled in this image, so today the
line changes nothing; it is there so that enabling one later does not send apt
asking for indices — `pkgs.tailscale.com` publishes i386, the other two do not.

#### The keyring goes under a name of this image's own

`tailscale` *recommends* `tailscale-archive-keyring`, and [recommends are
installed](#recommends-are-installed), so that package arrives with it and ships
`/usr/share/keyrings/tailscale-archive-keyring.gpg` — over the top of the file
the script just fingerprint-checked, if the two shared a name. So this image's
copy is the armoured form under `.asc`, and the package's is left referenced by
nothing, like the `google-chrome.gpg` Chrome's `postinst` drops. Today they are
the same key and the `.gpg` is byte-for-byte the `.noarmor.gpg` the installer
would have fetched; the point of the separate name is that this stays true
whether or not that holds tomorrow.

#### Nothing else needs correcting, and that is unusual here

The `.deb` is two Go binaries — `/usr/bin/tailscale` and `/usr/sbin/tailscaled`,
about 74 MiB together — three units in `/usr/lib/systemd/system`, and one
conffile, `/etc/default/tailscaled`. Nothing in `/opt` for `bootc-rootfs.sh` to
fold into `/usr/lib/opt`, and nothing under `/var` for it to transcribe:
`tailscaled.service` carries `StateDirectory=tailscale`, so `/var/lib/tailscale`
is created by systemd at first start rather than shipped by the package. The
DNS side needs nothing either — `systemd-resolved` is installed and
`/etc/resolv.conf` is the stub symlink `bootc-rootfs.sh` restores, which is what
MagicDNS wants to talk to.

What it must not be told to do is update itself. `tailscale set --auto-update`
runs the platform's package manager, which on Debian means `apt-get install`
against `/etc/apt/sources.list.d/tailscale.list` — a file this image does not
write, into a `/usr` it cannot write, with a dpkg database that lives in
`/usr/lib/sysimage/dpkg` and is read-only too. Auto-update is off by default;
leave it off. New Tailscale versions arrive the way everything else here does,
in the next image.

#### The daemon is installed and left off

The `postinst` enables `tailscaled.service` through `deb-systemd-helper`;
`enable-units.sh` disables it again. Without that, every machine installed from
this image would boot a VPN agent that has never been logged in — a tun device,
a socket and port 41641, idle until someone runs `tailscale up`.

And `tailscale up` is a per-machine step whatever the image does: it needs a
login, and the node it registers is named after the host, so there is nothing
useful to bake in. Turning it on is once per machine:

```
sudo systemctl enable --now tailscaled
sudo tailscale up
```

Both halves survive updates. The enable is a symlink under `/etc`, which is
writable on a deployed host and merged across a `bootc upgrade`; the login is
state under `/var/lib/tailscale`, which upgrades do not touch. It also survives
the package: `enable-units.sh` uses `systemctl disable` rather than
`deb-systemd-helper disable` — the helper refuses to run outside a maintainer
script — and since the helper decides by looking at that same `/etc` symlink, a
derived image that upgrades `tailscale` sees a unit the admin disabled and
leaves it alone.

### Pandoc, and a `.deb` worth pinning

trixie's `pandoc` is 3.1.11.1, released in January 2024; upstream is at 3.11.
Nothing closes that gap from inside Debian: `trixie-backports` has no pandoc at
all, and forky's 3.10.2 is built against forky's glibc, so pinning it the way
`ostree-forky.sh` pins libostree would pull a second libc into the image for one
program. Upstream publishes no apt repository either — only a `.deb` per release
on `github.com/jgm/pandoc/releases`. So `build/pandoc.sh` installs that, and
pandoc is the fourth thing here from outside the archive and the first bare
package.

With no repository there is no repository key, so the script pins the file
itself — the version in the URL and the SHA-256 of the `.deb` — and
refuses to install anything else. Upstream signs neither the package nor a
checksum list, so there is no key to fingerprint the way the three repos are;
the hash was read off the file GitHub served when the pin was set, which puts it
in the same class as Tailscale's fingerprint: a record of what the build first
saw, not a second opinion about it. It still buys the property the pins exist
for. The bytes this image installs as root cannot change without the change
being a commit, and a scheduled `publish.yml` build cannot pick up a release
nobody has looked at. Bumping it is two constants in one file.

The package itself asks nothing of image mode. It is one 156 MiB static Haskell
binary at `/usr/bin/pandoc`, two symlinks to it — `pandoc-lua` and
`pandoc-server` — three man pages and a copyright file, with no maintainer
scripts at all. Its Depends are `libc6`, `libgmp10` and `zlib1g`, all already
here; its Suggests are TeX Live pieces `texlive-full` already covers. Nothing in
`/opt`, nothing under `/var`, nothing that writes to `/usr` after install. It
carries `Replaces: pandoc-data`, which only matters if Debian's own `pandoc`
were installed first, and it is not: it comes off the archive list in the same
step, and none of the trixie packages that recommend it are in this image.

The pin is amd64 only. The image is too — `linux-image-amd64` and
`qemu-system-x86` both say so; the vendor repos' `Architectures:
amd64 arm64` lines are about which indices apt fetches, not about a second
build. Upstream does publish an arm64 `.deb`, and adding it is a second hash and
a `case` statement, when there is a build to want it.

### The UDS client, and a `.deb` only its server publishes

UDS is Virtual Cable's OpenUDS, the VDI broker behind `uds.mondragon.edu`. Its
web portal hands the browser a `uds://` URL when a service is clicked, and the
client is what handles it: it asks the broker for the connection details, opens
the tunnel and starts `xfreerdp`. Upstream publishes it nowhere — no apt
repository, and the GitHub release for 4.0 has no assets — because the client
ships with the broker, which serves it from `/uds/res/clients/` on its own host
alongside a Windows installer, a Mac package, an RPM and two AppImage tarballs.
So `build/udsclient.sh` fetches `udsclient3_4.0.0_all.deb` from
`uds.mondragon.edu`, and the client is the fifth thing here from outside the
archive and the second bare package after pandoc.

The pin is pandoc's. The `.deb` is the program, not a downloader for
one, so the script holds its version and its SHA-256 and refuses anything else;
nobody signs the file or a checksum list, so the hash is once more a record of
what the build first saw, and the trust anchor is TLS to the broker plus that
record. The failure mode is the useful part. The broker has redeployed the same
4.0.0 file for years — its `Last-Modified` is well after the package's own
changelog — and when the university upgrades the broker, the file changes and
the scheduled build stops until the two constants are bumped. That is also the
only notice this image gets that the broker moved, and it matters more here
than for pandoc: a UDS broker checks the client's version and can refuse one
that is too old, so a client that kept installing unpinned would be one that
stopped working without a word.

The package itself is the smallest of the five by a wide margin and asks nothing
of image mode. 106 KiB, `Architecture: all`, no maintainer scripts: twenty-odd
Python files under `/usr/lib/UDSClient`, a `.desktop` file and a doc directory.
Its Depends are all in trixie `main` — `python3-pyqt6`, `freerdp3-x11`,
`python3-certifi`, `python3-cryptography`, `python3-psutil`,
`desktop-file-utils` — and apt resolves them from the indices already fetched.
Nothing in `/opt`, nothing under `/var`; at runtime it writes the RDP files it
generates to the temp directory and nothing else, so there is no `$HOME` state
to speak of and nothing that reaches for a read-only `/usr`.

The `.desktop` file is the one part that has to land right. It declares
`MimeType=x-scheme-handler/uds;x-scheme-handler/udss;`, which is how the browser
finds a handler for the portal's links, and that only takes effect once
`update-desktop-database` has folded it into
`/usr/share/applications/mimeinfo.cache`. `desktop-file-utils` registers a dpkg
file trigger on `/usr/share/applications`, so installing through apt runs it at
build time and the cache ships under `/usr` with everything else — which is why
the trigger-owning package being a hard Depends is worth noticing, and why this
step, like every package step, stays ahead of `bootc-rootfs.sh`. The file also
passes `-platform xcb` on its `Exec` line, so the Qt window runs on Xwayland
under the Plasma Wayland session rather than natively. It works, and it is
upstream's call rather than this image's to override.

The same `Exec` line does get one edit, for a fault that is the university's.
The tunnel server the client connects to for the RDP session,
`udstunel.mondragon.edu:11443`, serves its leaf certificate without the
intermediate that signed it — `GEANT TLS RSA 1`, under a HARICA root that
`ca-certificates` already trusts. The broker on `uds.mondragon.edu:443` sends
its full chain, so the portal works; the tunnel does not, and where a browser
or Windows would fetch the missing intermediate from the leaf's AIA URL, a
Python `ssl` client does not, so every session died at the tunnel handshake
with `CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate`. The
client reads `CERTIFICATE_BUNDLE_PATH` and adds that file to the default trust
store for both its REST calls and the tunnel socket, so `build/udsclient.sh`
prepends `env CERTIFICATE_BUNDLE_PATH=/usr/share/os4/udsclient/GEANT-TLS-RSA-1.pem`
to the `Exec` line, and the intermediate is committed under
[`usr/share/os4/udsclient`](usr/share/os4/udsclient/README.md) beside a note
on where it came from. Scoping the fix to the client keeps the system store
untouched — it is a workaround for a misconfigured server, not a new trust
decision — and the script verifies the committed file against the system store
before using it, and refuses to edit an `Exec` line other than the one it
expects, so a new `.deb` that moves the line fails the build instead of
shipping half-patched. If the tunnel is ever configured to send its chain, the
file becomes redundant and harmless.

### GLPI Agent, and an inventory that is opt-in per machine

GLPI is the asset-inventory system the university's IT runs at
`eaz-mgep.mondragon.edu`, and GLPI Agent is what reports a machine to it:
hardware and serial numbers, installed software, network interfaces, users.
IT's instructions are a shell script that fetches upstream's
`glpi-agent-<version>-linux-installer.pl` from the latest GitHub release and
runs it as root with `--server` and `--install`. That installer is a
self-extracting Perl script carrying the same `.deb`s published beside it on
the release, and on Debian it installs them through apt — which on a deployed
host means writing to a read-only `/usr`, so it cannot work here.
`build/glpi-agent.sh` does the same thing at build time instead, from
`glpi-agent_<version>-1_all.deb` directly, and the agent is the sixth thing
here from outside the archive and the third bare package.

trixie has no `glpi-agent`; what Debian still ships is its predecessor,
`fusioninventory-agent`, which upstream no longer maintains. The pin is
pandoc's: version and SHA-256 are constants, and anything else stops the
build. Where IT's script resolves "latest" every time it runs, a new release
here is a commit. GitHub records a digest for each release asset and the pinned
one matched it, but that is GitHub vouching for what it stored, not upstream
signing anything, so the hash is once more a record of what the build first
saw. Only the core package is installed — the release's `-task-network`,
`-deploy`, `-collect` and `-esx` packages are left out, as the installer's
default does: local inventory is the only task IT asks for.

What image mode asks of it is small. 4 MiB, `Architecture: all`, Perl modules
under `/usr/share/glpi-agent` and a handful of programs; the Depends are all in
trixie `main`. Two of its Recommends matter — `libio-socket-ssl-perl`, without
which it cannot talk to an https server at all (the script checks for it), and
`dmidecode`, where serial numbers and BIOS data come from. The postinst copies
the default configs into `/etc/glpi-agent` with `ucf`, so they ship as `/etc`
defaults; `ucf`'s registry under `/var/lib/ucf` belongs to no package and does
not survive `bootc-rootfs.sh`, which only matters to a derived image upgrading
the package with apt. `/var/lib/glpi-agent` is an empty directory in the
package, so the generated tmpfiles entries recreate it; it is where the agent
keeps its device ID, which the first run writes — nothing in the build runs
the agent, so the image ships no ID.

The server URL — the one thing taken from IT's script, since its
`NO_SSL_CHECK=0` is already the default — goes into
`/etc/glpi-agent/conf.d/os4-server.cfg`, which `agent.cfg` includes and which
package upgrades leave alone. The server sends its full chain to a HARICA root
in `ca-certificates`, so unlike the UDS tunnel there is nothing to work around.

The daemon ships disabled, for the reason `tailscaled` does and one more. The
postinst enables `glpi-agent.service`; left that way, every machine installed
from this image — test VMs included — would report its inventory to the
university within the hour, whether or not it belongs in that inventory.
`enable-units.sh` turns it off, and a machine that should be reported opts in
once:

```sh
sudo systemctl enable --now glpi-agent
```

The symlink is in `/etc` and survives `bootc upgrade`. `sudo glpi-agent` sends
one inventory immediately instead of waiting for the daemon's first,
randomised run.

### v4l2loopback, and a module signature that is not the UKI's

`v4l2loopback-dkms` is Debian's route to a virtual camera device — the thing
OBS or a screen-share needs to hand its output to a browser as if it were a
webcam. `build/v4l2loopback.sh` installs `linux-headers-amd64` alongside it,
which is what triggers the package's own postinst to build the module through
DKMS against this image's kernel, and `v4l2loopback-utils` for
`v4l2loopback-ctl`, the tool that configures how many devices exist and what
they are named.

An unsigned out-of-tree module is exactly what Secure Boot's lockdown refuses
to load, though — not tainted, refused outright — on any host where lockdown
is engaged, which is every host booted with Secure Boot on regardless of
whose key signed the chain that got it there. So the module is signed, with
`scripts/sign-file` (a PKCS#7 signature over the `.ko`, a different format
from sbsign's Authenticode signature over the whole UKI) using the same
leaf key that signs the sealed variant's UKI. That reuse is deliberate: the
[Secure Boot](#secure-boot) section above only covers the boot chain, but the
module's *verification* keyring is the same MOK store a host populates with
`mokutil --import usr/share/os4/secureboot/ca.crt.der` — so a module signed
by the leaf, which chains to that CA, needs no second key or second
enrolment on a host that has already enrolled it for the sealed variant.

That last clause is the part worth being plain about: **only** a host that
has enrolled the os4 CA trusts this signature. A classic-tag host that has
never needed the CA for anything — its boot chain is entirely Debian's own,
per the section above — will refuse this module exactly as it would an
unsigned one, until it runs the same `mokutil --import` once. Nothing here
does that automatically; it is the same physical-presence step the sealed
variant already documents, just now also useful off it.

Signing happens in the main image build, not in the sealed variant's separate
`sign-uki.sh` pass — a kernel module has no tar-mtime-digest problem, so
there is nothing forcing it out of a plain `RUN`. `SB_LEAF_KEY` reaches that
`RUN` as a build secret (`--mount=type=secret`), mounted only for the
step and never written to a layer, the same guarantee `--mount=type=secret`
gives publish.yml's build args. It is optional there the way it is for the
sealed variant: unset, the module ships unsigned and a comment in the build
log says so, which is what every PR and non-release build does; publish.yml
supplies it for the tags that matter.

One more thing had to be headed off explicitly rather than left to chance.
Debian's `dkms` (3.2.2) tries to sign every module it builds by default, and
finding no key at `/var/lib/dkms/mok.key` it generates one on the spot with
`openssl req` — a real private key, written into this layer's diff, still
recoverable from the pushed image even after `bootc-rootfs.sh` empties `/var`
in a later layer, because OCI layers are additive history. Whether that
happens depends on whether some earlier step happened to pull in the
`openssl` binary — not something this build wants to depend on by accident.
`build/v4l2loopback.sh` pre-creates both files empty before installing the
package, so dkms finds them already present, skips generation, and its
signing attempt fails deterministically on a garbage key instead — no
private key material is ever generated here that this script does not
control. The real signature, from the leaf key, replaces that failed one.

## Recommends are installed

Stage 2 installs with apt's recommends left on, everywhere. Debian's
`--no-install-recommends` habit comes from servers, where a lean root is the
point; this image is a desktop, and a good deal of what makes one work is
recommended rather than depended on. Concretely, leaving them on is what brings
in `intel-microcode` and `amd64-microcode`, the GPU firmware, `efibootmgr`,
podman's rootless networking (`passt`, `slirp4netns`, `aardvark-dns`),
virt-manager's SPICE console and qemu's display modules — every one of which
had to be noticed and added by hand otherwise.

`shim-signed` used to be on that list. It is still a recommend — of
`systemd-boot`, not of `firmware-linux` — but it is now named explicitly in the
Containerfile, because it is the Microsoft-signed binary the whole Secure Boot
chain starts from and that is not a thing to leave to a recommend.

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

## The image ships no host identity

A `postinst` that generates a key generates it once, on the machine the package
is being installed on. In image mode that machine is the build container, and
what it wrote is copied onto every host installed from the image — so
`openssh-server`'s `ssh-keygen` did not give each machine a host key, it gave
every machine the *same* host key, private half included, in a published image.
The comment field the key carried said so plainly:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII6ODJSwEvelfusDZHVgtkAaAztBrO/AtbWlapaFXaFw root@buildkitsandbox
```

Anyone who could pull the image could impersonate any host that booted from it,
and decrypt any session they could capture. `build/strip-identity.sh` runs after
the last package step and removes what the package steps generated:

| What | Why it cannot ship | What puts a real one back |
| --- | --- | --- |
| `/etc/ssh/ssh_host_*_key` | Every host answers with one identity, and the private half is public | `sshd-keygen.service`, with the drop-in below |
| `/etc/ssl/private/ssl-cert-snakeoil.key` and its `.pem` | A shared private key, from `ssl-cert`, which `cups` depends on | Nothing — no file in `/etc` and no unit in this image references it. `make-ssl-cert generate-default-snakeoil` is what makes one if something ever needs it |
| `/etc/iscsi/initiatorname.iscsi` | Not a secret, but the file itself says the IQN must be unique per initiator | `iscsid.service`'s `ExecStartPre` runs `startup-checks.sh`, which calls `iscsi-iname` when the file is absent |
| `/etc/machine-id` | One systemd identity for every machine | systemd, on first boot, from the empty file left behind |

Debian already ships the unit that regenerates SSH host keys, and
`openssh-server`'s `postinst` already enables it into `ssh.service.wants` — but
it is gated on `ConditionFirstBoot=yes`, and a host reaching this image through
`bootc upgrade` is not on its first boot. Its `/etc` is a three-way merge
against the image's, so dropping the keys here drops them from that host too,
and with the gate in place nothing would put new ones back: `sshd` would fail to
start. A drop-in resets the condition — an empty assignment clears the list —
and `ssh-keygen -A` creates only what is missing, so every later boot costs
three `stat` calls.

`/etc/hostname` is the one thing left alone, and it cannot be otherwise: it
comes from the Debian base image, containing `debuerreotype` — the name of the
tool that built that image — and the builder bind-mounts its own over the top
for the duration of every `RUN`, so a `rm` gets `EBUSY` and a write lands in the
mount rather than in the layer. Not a secret; a host that has never had a
hostname set is called that until something sets one.

The script ends by checking its own work, and that half is for the next package
rather than this one. Every file under `/etc` is searched for a PEM private-key
header — content rather than a list of names, so it needs no maintenance — and
the identities that are not PEM are checked by name. A package added to the
Containerfile later that quietly writes a key in its `postinst` fails the build
there, rather than being noticed in a published image.

Hosts installed before this was fixed still have the shared keys in their
writable `/etc`, where the merge leaves them if they were ever modified. After
upgrading:

```
sudo rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
sudo ssh-keygen -A
sudo systemctl restart ssh
```

Clients will report a changed host key on the next connection, which is the
correct outcome and the point of the exercise.

## Workflows

| Workflow | Trigger | Notes |
| --- | --- | --- |
| `publish.yml` | push to `main`, PRs, releases, every other day | Builds with rootful podman on a GitHub-hosted `ubuntu-24.04` runner, with the container store moved to the runner's `/mnt` disk for space, then pushes to `ghcr.io/<owner>/os4` with `skopeo copy --format oci` — not `docker push`, see [OCI media types are not optional](#oci-media-types-are-not-optional). The sealed image also goes to `ghcr.io/<owner>/linux` under the plain tag names, and the nvidia variant to the same package with `-nvidia`. Signs each pushed digest with keyless cosign, in each package it was pushed to. PRs build without pushing. |
| `build-disk.yml` | manual | os3's anaconda-ISO workflow, adapted. Anaconda is Fedora's installer and cannot install a Debian root, so this produces a qcow2 (or raw, or vmdk) disk image instead. Does not currently work — see [Installing to a disk](#installing-to-a-disk). |
| `cleanup-packages.yml` | daily | Prunes `ghcr.io` versions of both `os4` and `linux` older than 30 days beyond the newest 10, never touching a digest tagged `latest`, `main` or a version number (or their `-sealed` and `-nvidia` twins). A cosign signature goes when the image it signs does, and not before. `workflow_dispatch` has a dry-run switch. |

Repository secrets: `SB_LEAF_KEY` (the Secure Boot leaf key; without it the
sealed variant is skipped and v4l2loopback ships unsigned), and
`S3_ACCESS_KEY_ID`/`S3_SECRET_ACCESS_KEY` for `build-disk.yml`. Registry access
and signing need none: both run on the job's own `GITHUB_TOKEN` and OIDC token.

The package is private until made public in its settings on GitHub. Hosts that
`bootc switch` to it while it is private need credentials in
`/etc/ostree/auth.json`.

### Verifying a signature

Signing is keyless: there is no public key to distribute. cosign gets a
short-lived certificate from Sigstore's Fulcio naming the workflow that ran,
and logs the signature in the public Rekor transparency log — which also makes
the repository and workflow names public, private repository or not.
Verifying means checking that identity:

```
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/isibek04/Linux/\.github/workflows/publish\.yml@refs/(heads/main|tags/v.+)$' \
  ghcr.io/isibek04/os4:main
```

The `linux` images verify the same way, with `ghcr.io/isibek04/linux:main` or
`ghcr.io/isibek04/linux:main-nvidia` as the last argument: they are signed in
that package too.

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
podman rmi ghcr.io/isibek04/os4:main
skopeo copy --format oci \
  docker://ghcr.io/isibek04/os4:main \
  containers-storage:ghcr.io/isibek04/os4:main
```

### bootc install to-disk, with two flags that are not optional

Run from the image itself, against a file over loopback:

```
truncate -s 40G disk.raw
podman run --rm --privileged --pid=host \
  --security-opt label=type:unconfined_t \
  -v /dev:/dev -v /var/lib/containers:/var/lib/containers -v .:/work \
  ghcr.io/isibek04/os4:main \
  bootc install to-disk --via-loopback --wipe --filesystem ext4 \
    --composefs-backend --bootloader systemd \
    --target-imgref ghcr.io/isibek04/os4:main /work/disk.raw
```

`--composefs-backend` is what makes it work. bootc installs bootloaders through
bootupd, which Debian does not package and this image therefore does not carry.
With the ostree backend that leaves nothing it will accept — `Bootloader::Grub`
is the only arm that installs anything, and systemd-boot falls through to a
hard `bootupd is required for ostree-based installs`
(`crates/lib/src/install.rs`, bootc 1.17.1). systemd-boot is implemented only
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
`root_setup.kargs` (`crates/lib/src/bootc_composefs/boot.rs`, bootc 1.17.1).
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

## Secure Boot

It works, with Debian's signatures and nobody's own keys. Two packages and one
boot-time service, and none of it needs a key generated or a certificate
enrolled.

The chain is the ordinary distro one:

```
firmware --db--> shim --Debian CA--> systemd-boot --shim_lock--> kernel
```

Firmware trusts Microsoft, Microsoft signed shim, shim carries Debian's CA
inside itself, and Debian signed both systemd-boot and the kernel with it. Note
that `linux-image-amd64` already resolves to the *signed* kernel — the unsigned
build is the one carrying an explicit `-unsigned` suffix in the archive — so
copying `/boot/vmlinuz-$kver` into the module directory in
`build/initramfs.sh` carries a valid signature with it. Nothing here re-signs a
kernel, because there is nothing to gain by doing so.

Debian's shim is dual-signed, by the `Microsoft Corporation UEFI CA 2011` and
the `Microsoft UEFI CA 2023`, so it boots on firmware from either side of the
CA rollover.

### The package that was missing

`systemd-boot` declares `systemd-boot-efi-signed | systemd-boot-efi`, signed
alternative first — but the Containerfile names `systemd-boot-efi` explicitly,
which satisfies the dependency directly and stops apt ever reaching for the
alternative. That is the whole reason this image used to have no signed
bootloader, and why the README used to claim Debian shipped none.
`systemd-boot-efi-amd64-signed` is now named alongside it.

Nothing else was needed to make bootc use it: `bootctl install` skips a `.efi`
when a `.efi.signed` sits beside it and drops the suffix at the destination
(systemd 257, `src/bootctl/bootctl-install.c`), and bootc calls plain
`bootctl install` (`crates/lib/src/bootloader.rs`, bootc 1.17.1).

### The part bootc does not do

`bootctl` knows nothing about shim. It writes systemd-boot to
`EFI/systemd/systemd-bootx64.efi` and to the removable-media path
`EFI/BOOT/BOOTX64.EFI`, and stops — and Debian's CA is not in any firmware's
db, so with Secure Boot on the firmware refuses both.

`usr/libexec/os4-secureboot-esp` inserts the missing link, from
`os4-secureboot-esp.service` on every boot. It leaves `EFI/systemd` alone — a
fine unsigned-chain bootloader for a machine with Secure Boot off — and builds
the chain in `EFI/BOOT`:

| file | content | signed by |
| --- | --- | --- |
| `BOOTX64.EFI` | `shimx64.efi.signed` | Microsoft (2011 + 2023) |
| `grubx64.efi` | `systemd-bootx64.efi.signed` | Debian Secure Boot CA |
| `mmx64.efi` | `mmx64.efi.signed` | Debian Secure Boot CA |

`grubx64.efi` is not a typo and there is no GRUB in this image. Debian's shim
has its second stage fixed at build time to the string `\grubx64.efi`, resolved
relative to shim's own directory; renaming the file is how you point shim at a
different loader without rebuilding it. `fbx64.efi` is deliberately not copied:
it is shim's NVRAM-entry builder, it needs a `BOOT<arch>.CSV` this image does
not ship, and shim only invokes it when it finds it alongside — so leaving it
out is what sends shim straight to its second stage.

`EFI/BOOT` and not `EFI/systemd` because it is the UEFI removable-media path,
which is what fires when there is no NVRAM entry at all — the
bootc-image-builder case, where `--generic-image` implies `--no-variables`.

The removable-media path alone is not enough where there *is* an NVRAM entry:
`bootc install to-disk` creates "Linux Boot Manager", first in `BootOrder`,
pointing at the unshimmed `EFI/systemd/systemd-bootx64.efi`, and Secure Boot
firmware refuses it and moves on — to Windows, on a dual boot. So the script
also adds an `os4 (shim)` entry for `EFI\BOOT\BOOTX64.EFI`, once, first in
`BootOrder`; an order rearranged after that is left alone. Shim boots fine with
Secure Boot off too, so the entry is safe to add before turning it on.

The ESP is the one systemd-boot reports it was loaded from
(`LoaderDevicePartUUID`), so a second ESP — Windows' own, on a dual boot — does
not make the choice ambiguous.

It has to run on the deployed host rather than in the build: the ESP does not
exist until something installs the image to a disk, and neither
`bootc install to-disk` nor bootc-image-builder offers a hook between laying
the bootloader down and finishing. It is idempotent, which is also what makes
it the repair path if anything ever re-runs `bootctl install`.

The first boot after an install is still a Secure-Boot-off boot — the chain is
not on the ESP until the service has run once. Turn Secure Boot on at the
second boot.

### What this does and does not cover

It covers the bootloader and the kernel. It does not cover the initramfs, and
more to the point it does not cover the kernel command line — which is where
bootc puts the verity digest the whole read-only `/usr` hangs from
(`cmdline_options.extend`, `crates/lib/src/bootc_composefs/boot.rs`). As of
bootc 1.17 a fresh install writes it as `composefs.digest=v1-sha512-12:<hex>`;
older installs and the legacy format use `composefs=<hex>`.
In the BLS layout that digest lives in a plain-text entry on an unsigned FAT
partition.

Closing that means UKIs, which means a signing key of one's own, because nobody
else will sign an initramfs built here. bootc's composefs backend supports
Type 2 entries, but on terms worth knowing before starting: the UKI must live
in `/boot/EFI/Linux` rather than `/usr/lib/modules`, because `/boot` is the only
tree composefs empties before computing the digest the UKI has to embed
(`REQUIRED_TOPLEVEL_TO_EMPTY_DIRS`, composefs-rs `composefs-boot/src/lib.rs`) —
so the build becomes two-pass. And `setup_composefs_uki_boot` never reads
`root_setup.kargs`, which is what carries `rd.luks.uuid=` and
`luks.options=` in the BLS path, so UKI and `--block-setup tpm2-luks` look
mutually exclusive as of bootc 1.17.1. Untested here; test it in a VM before
believing either half.

## Updates

As in os3: `bootc-fetch-apply-updates.timer` is disabled, and
`bootc-download-updates.timer` replaces it. It runs `bootc upgrade
--download-only` every 8 hours with a 2-hour jitter, so a new deployment is
staged and waiting but nothing reboots until you do.
