# os4

A Debian 13 (trixie) workstation, built and shipped as a bootable container.
The Debian counterpart to [os3](https://git.sebz.me/sebastian/os3), which does
the same thing on Fedora.

Same shape as os3: LXQt on a `bootc` image, published to `git.sebz.me` by
Forgejo Actions, updates staged in the background rather than applied on a
reboot you did not ask for.

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

The base plumbing follows the bootcrew reference closely, with two departures
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

## What os3 has that this does not

Everything installed here comes from the Debian archive. These are the os3
packages that have no Debian equivalent, left out of this first cut:

| os3 | Why not here |
| --- | --- |
| rpmfusion codecs | No Debian equivalent for the DVD/BluRay side; `deb-multimedia` is the third-party option. Note that trixie's own `ffmpeg` already links `libx264` and `libx265`, so H.264/H.265 playback is not the gap this row once implied. |
| `google-chrome-stable` | Google's own apt repo. Firefox ESR is installed instead; `chromium` is in main if a Blink browser is wanted without the repo. |
| `discord` | Vendor `.deb` download only. |
| `steam`, `gamescope` | `steam-installer` is in `contrib`, which is enabled here, but wants i386 multiarch; gamescope is not packaged for Debian at all. `mangohud` is installed. |
| `tailscale` | `pkgs.tailscale.com` apt repo. |
| `tea` | Gitea's CLI is a release binary. Debian ships a `tea` package, but it is an unrelated text editor, so the name is not usable. |
| `uv` | Astral release binary. |
| `nix` | Debian has `nix-bin` and `nix-setup-systemd`; skipped along with the `ostree-state-overlay@nix` unit that goes with it. |
| `v4l2loopback`, `akmods` | Debian's route is `v4l2loopback-dkms` built against the image kernel at build time. Not wired up. |
| DNIe PKCS#11 | Upstream ships an RPM. Would need unpacking, and Debian's CA trust layout differs from Fedora's. |

Each is additive — a repo, a keyring and a package name — so they can come back
one at a time. `gh` and `glab` used to be on this list and are not any more:
both are in trixie `main` and are installed.

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

The setcap step at the end of os3's Containerfile has no counterpart here. It
restores file capabilities that the CI runner's docker drops when it re-pushes
the base image's layers; dpkg records no capabilities to restore them from, and
the binaries whose loss broke rootless podman on os3 — `newuidmap`,
`newgidmap` — are setuid rather than capability-based on Debian, and setuid
bits survive.

## Workflows

| Workflow | Trigger | Notes |
| --- | --- | --- |
| `publish.yml` | push to `main`, PRs, releases, every other day | Unchanged from os3. Builds on the `hetzner-host` runner with the host's docker, pushes to `git.sebz.me`, signs with cosign when `COSIGN_PRIVATE_KEY` is set. PRs build without pushing. |
| `build-disk.yml` | manual | os3's anaconda-ISO workflow, adapted. Anaconda is Fedora's installer and cannot install a Debian root, so this produces a qcow2 (or raw, or vmdk) disk image instead. |
| `cleanup-packages.yml` | daily | Unchanged from os3 apart from the package name. |

`build-disk.yml` is the one that has never run. bootc-image-builder's Debian
support is untested upstream; if it refuses the image, `bootc install to-disk`
run from the image itself is the fallback.

## Updates

As in os3: `bootc-fetch-apply-updates.timer` is disabled, and
`bootc-download-updates.timer` replaces it. It runs `bootc upgrade
--download-only` every 8 hours with a 2-hour jitter, so a new deployment is
staged and waiting but nothing reboots until you do.
