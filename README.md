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

## What os3 has that this does not

Almost everything installed here comes from the Debian archive. There are six
exceptions. Three are vendor apt repositories with a pinned signing key —
Anthropic's, for the Claude desktop app, Google's, for Chrome, and Tailscale's,
for the node agent — and three are bare `.deb`s: Discord, which publishes no
repository; pandoc, which is in the archive but two years behind upstream and
has no backport — see [Pandoc, and a `.deb` worth
pinning](#pandoc-and-a-deb-worth-pinning); and the UDS client, which is
published only by the VDI broker it connects to — see [The UDS client, and a
`.deb` only its server publishes](#the-uds-client-and-a-deb-only-its-server-publishes).
These are the os3 packages that have no Debian equivalent, left out of this
first cut:

| os3 | Why not here |
| --- | --- |
| rpmfusion codecs | No Debian equivalent for the DVD/BluRay side; `deb-multimedia` is the third-party option. Note that trixie's own `ffmpeg` already links `libx264` and `libx265`, so H.264/H.265 playback is not the gap this row once implied. |
| `gamescope` | Not packaged for Debian at all. `mangohud` is installed, and so is `steam` — see below. |
| `tea` | Gitea's CLI is a release binary. Debian ships a `tea` package, but it is an unrelated text editor, so the name is not usable. |
| `uv` | Astral release binary. |
| `nix` | Debian has `nix-bin` and `nix-setup-systemd`; skipped along with the `ostree-state-overlay@nix` unit that goes with it — which would also mean installing `ostree-boot`, since that is where the unit template lives and this image does not currently pull it in. |
| `v4l2loopback`, `akmods` | Debian's route is `v4l2loopback-dkms` built against the image kernel at build time. Not wired up. |
| DNIe PKCS#11 | Upstream ships an RPM. Would need unpacking, and Debian's CA trust layout differs from Fedora's. |

Each is additive — a repo, a keyring and a package name — so they can come back
one at a time. `gh` and `glab` used to be on this list and are not any more:
both are in trixie `main` and are installed. `google-chrome-stable`, `steam`,
`discord` and `tailscale` have come off it too; see below.

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

### Steam, and why not Valve's own `.deb`

`steam-installer` is in trixie `contrib`, which `apt-sources.sh` already
enables; `steam-libs`, `steam-libs-i386` and `steam-devices` are in `main`.
Nothing about Steam needs `non-free`, so the component list is unchanged.

The `.deb` from `repo.steampowered.com` is the obvious alternative, and it is
*not* the one that avoids multiarch — that was the first thing checked.
Valve's `steam-launcher` recommends `steam-libs-i386` exactly as Debian's
package depends on it, because the Steam client is a 32-bit program either
way. Both
packages are also wrappers around the same thing: Debian's `/usr/games/steam`
downloads Valve's own `steam_<version>.tar.gz`, checks it against a SHA-256 in
the script, and unpacks `bootstraplinux_ubuntu12_32.tar.xz` into
`~/.steam/debian-installation`; Valve's ships that same tarball inside the
`.deb`. After first run the client updates itself from Valve's CDN in `$HOME` in
both cases, so the packaged version — 1.0.0.83 in trixie against 1.0.0.87
upstream — is the version of the bootstrap, not of the Steam you end up
running.

What differs is the packaging, and all three differences point the same way for
an image-mode system:

| | `steam-installer` (trixie) | `steam-launcher` (Valve) |
| --- | --- | --- |
| Repository | The archive. No third-party repo, no third key to pin. | Ships `/etc/apt/sources.list.d/steam-stable.list` and `steam-beta.list` as **conffiles**, plus its own keyring. There is no `repo_add_once`-style opt-out to set the way `google-chrome.sh` does; they would have to be deleted after the install. |
| Maintainer scripts | A `preinst` that shows one debconf note about `nvidia-driver-libs:i386`, and a `postrm`. No `postinst` at all, and nothing written to `/var`. | `preinst`/`postinst`/`prerm`/`postrm`. |
| Runtime dependency fixing | None. | `/usr/lib/steam/bin_steamdeps.py`, reached through `Depends: apt, python3-apt, pkexec`, which offers to `apt-get install` missing dependencies when the client starts. On a host with a read-only `/usr` that can only ever fail. |

Valve's package also `Conflicts: steam-devices` while `Provides:`-ing it, so
the two routes are mutually exclusive rather than complementary: you take one
set of udev rules or the other.

So: `steam-installer` and `steam-devices` from the archive, and one
`dpkg --add-architecture i386` before them. The architecture is recorded in
`/var/lib/dpkg/arch`, which `bootc-rootfs.sh` moves into `/usr` along with the
rest of the dpkg database, so a deployed host — and any image built on top of
this one — still knows i386 is enabled.

Adding the architecture makes apt fetch a second set of indices for every source
that does not restrict itself. The Debian entries and the forky pin all publish
i386, so that is fine; the two vendor repositories already pin
`Architectures: amd64 arm64`, which is why enabling i386 does not send apt
looking for indices `dl.google.com` and `downloads.claude.ai` do not have.

The cost is about **494 MiB** of i386 packages: `libllvm19:i386` (143 MiB),
`mesa-vulkan-drivers:i386` (83 MiB) and `mesa-libgallium:i386` (44 MiB) are most
of it — a second, 32-bit copy of the GPU stack. Much of that arrives through
recommends, which are on here as everywhere: `mesa-vulkan-drivers:i386`,
`va-driver-all:i386` and `libsdl2-2.0-0:i386` are all recommends of
`steam-libs` rather than depends, and without them the client comes up with no
32-bit Vulkan and no hardware video decode. One recommend that resolves to
nothing new: `steam-libs` wants `xterm | x-terminal-emulator`, and with a
provider already installed — `konsole`, from `kde-standard` — apt pulls no
second terminal in.

Three things this does not do. Steam's own `README.Debian` suggests running it
as a separate unprivileged user, since games are not sandboxed and can read
everything the account can — that is a per-host decision, not an image one. It
ships `examples/50-steam-no-admin-actions.rules`, a polkit rule that silences
the NetworkManager prompts Steam's SteamOS-derived code raises; it names a
username, so it stays an example here rather than being installed. And it
installs no Nvidia libraries: this image is mesa-only, and the `preinst`
asks for `nvidia-driver-libs:i386` only when it sees `/sys/module/nvidia` —
which, during a container build, is the *build host's* `/sys`, and which the
noninteractive frontend skips in any case. Layering the Nvidia stack on top is
at least possible now that i386 is enabled; it is not attempted here.

### Discord, and a `.deb` with nothing behind it

Discord is the third third-party install, and the one that does not fit the
pattern the other two established. There is no repository: what Discord
publishes is a download endpoint,
`https://discord.com/api/download?platform=linux&format=deb`, which 302s to the
current release on `stable.dl2.discordapp.net`. So there is no signing key, and
therefore no fingerprint to pin — the check `claude-desktop.sh` and
`google-chrome.sh` both perform, and the one this README called the part worth
copying, has no counterpart in `build/discord.sh`.

What authenticates the download is TLS to `discord.com` and to the host the
redirect names, and nothing else. That is worth stating rather than dressing
up. The two assertions the script does make are sanity checks and not a
substitute for a signature:

- **The redirect has to land on Discord's own hosts.** `curl -L` follows
  redirects across hosts, so an endpoint that one day points elsewhere would
  have this image install a stranger's package as root without a word.
  `-w '%{url_effective}'` reports where the chain actually ended, and anything
  outside `discord.com` and `discordapp.net` fails the build.
- **What came back has to be the package it claims to be** — `dpkg-deb -f`
  reports `Package: discord`, or the build stops. This catches an error page
  served with a 200 on it as much as anything else.

#### The `.deb` does not contain Discord

It is 2 MiB, and that is not a compression story. What the package ships is
`/usr/bin/discord`, a 44-line shell script, and a 4 MiB
`/usr/share/discord/updater_bootstrap`. On first launch the script looks for
`~/.config/discord/Discord`, does not find it, and runs the bootstrap, which
downloads the actual application from `updates.discord.com` into
`~/.config/discord/app-<version>/` and execs it. Thereafter Discord updates
itself in the same place.

That is the same arrangement as Debian's `steam-installer`, described above:
the packaged version is the version of the bootstrap, not of the program you
end up running. It is also why the script pins neither a version nor a
checksum. Doing so would break every scheduled build the moment Discord cut a
release, in exchange for pinning a downloader that does not pin what it
downloads.

The consequence is worth being explicit about, because it differs from every
other package in this image: **Discord does not arrive with `bootc upgrade`,
and it is not in the image at all.** It arrives on first launch, per user,
into `~/.config/discord` — which is under `/var/home`, so it is host state
that survives image updates and is invisible to them.

#### Which makes it the easiest vendor package here to ship read-only

The six third-party installs, on what image mode actually asks of them:

| | Trust anchor | Lands in `/opt` | Self-update target |
| --- | --- | --- | --- |
| `claude-desktop` | Anthropic's key, fingerprint pinned | No — `/usr/lib` | apt, so the image |
| `google-chrome-stable` | Google's key, fingerprint pinned | 431 MiB, folded into `/usr/lib/opt`; AppArmor profile re-pointed, daily cron symlink removed | apt, so the image — but `/etc/cron.daily/google-chrome` would write to a read-only `/usr/share/keyrings` |
| `discord` | TLS to `discord.com` | No | `$HOME`, which is writable |
| `tailscale` | Tailscale's key, fingerprint recorded — but not one Tailscale publishes | No — `/usr/bin`, `/usr/sbin` | apt, so the image — unless `--auto-update` is switched on, which shells out to `apt-get` and cannot work here |
| `pandoc` | SHA-256 of the release `.deb`, pinned with its version | No — `/usr/bin` | None; the image |
| `udsclient3` | SHA-256 of the broker's `.deb`, pinned with its version | No — `/usr/lib/UDSClient` | None; the image |

Nothing of Discord's goes to `/opt`, so there is no tree for `bootc-rootfs.sh`
to fold and no path to re-point. Nothing writes to `/usr` after the install
either — the self-updater's target is under `$HOME`, where Chrome's cron script
and Valve's `bin_steamdeps.py` would both be reaching for a `/usr` that is not
writable. It needs no image-mode correction at all — of the other three only
`tailscale` manages that, and for the opposite reason: it writes nowhere after
the install rather than writing somewhere writable.

Two smaller things, neither of them a correction. Its AppArmor profile attaches
to `@{HOME}/.config/discord/app-*/Discord`, which resolves to a path nothing on
this image has unless `apparmor-home.sh` has extended `@{HOMEDIRS}` to cover
`/var/home` — the same tunable `akonadi-server` needed, and the reason
`discord.sh` runs before that step rather than after it. Like Chrome's, the
profile is `flags=(unconfined)`
and grants `userns`, so it is inert on Debian either way. And the `postinst`
opens with `systemctl reload apparmor`, which in a build container with no
running systemd prints `System has not been booted with systemd` and returns 1.
The script is `/bin/sh` without `set -e` and ends on an `rm -f`, so dpkg sees
exit 0 and the install succeeds; the profile is a conffile under
`/etc/apparmor.d` and `apparmor.service` loads it at boot regardless. The line
in the build log is noise, not a failure.

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
vendor entries, for a different reason: those two publish no i386 indices at
all, so the line is what keeps the multiarch Steam enabled from breaking
`apt-get update`, while `pkgs.tailscale.com` does publish i386 and the line only
avoids fetching a ~90 KiB index nothing here would install from.

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
pandoc is the fifth thing here from outside the archive and the second bare
package after Discord.

It is the mirror image of Discord's, though. That script pins nothing because
its `.deb` is a downloader for a program that updates itself under `$HOME`;
pinning it would pin the wrong thing. Pandoc's `.deb` *is* the program, so the
script pins both — the version in the URL and the SHA-256 of the file — and
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

The pin is amd64 only. The image is too — `linux-image-amd64`, `qemu-system-x86`
and the i386 multiarch for Steam all say so; the vendor repos' `Architectures:
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
`uds.mondragon.edu`, and the client is the sixth thing here from outside the
archive and the third bare package after Discord and pandoc.

The pin is pandoc's. The `.deb` is the program rather than a downloader for
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

The package itself is the smallest of the six by a wide margin and asks nothing
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
`bootctl install` (`crates/lib/src/bootloader.rs`, bootc 1.16.9).

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
bootc puts `composefs=<digest>`, the verity digest the whole read-only `/usr`
hangs from (`cmdline_options.extend`, `crates/lib/src/bootc_composefs/boot.rs`).
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
mutually exclusive as of bootc 1.16.9. Untested here; test it in a VM before
believing either half.

## Updates

As in os3: `bootc-fetch-apply-updates.timer` is disabled, and
`bootc-download-updates.timer` replaces it. It runs `bootc upgrade
--download-only` every 8 hours with a 2-hour jitter, so a new deployment is
staged and waiting but nothing reboots until you do.
