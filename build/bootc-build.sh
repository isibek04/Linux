#!/usr/bin/env bash
# Build bootc from source into /output, ready to be COPYed over a Debian root.
#
# Debian ships no bootc package (`bootcd` in the archive is an unrelated
# boot-CD tool), so unlike the Fedora image there is nothing to `apt install`.
# Building it here is what makes this repo self-contained: the only external
# inputs are the Debian archive, crates.io and a tagged bootc release.
set -euo pipefail

# BOOTC_REF is passed through from the Containerfile's build arg. Empty means
# "whatever the newest release is", resolved against the GitHub release API the
# same way os3 resolves the Gitea CLI version. Pin it to a tag (v1.2.3) for a
# reproducible build.
ref="${BOOTC_REF:-}"
if [ -z "${ref}" ]; then
  ref="$(curl -fsSL https://api.github.com/repos/bootc-dev/bootc/releases/latest \
    | jq -re '.tag_name')"
fi
echo "Building bootc ${ref}"

src="$(mktemp -d)"
git clone --depth=1 --branch "${ref}" https://github.com/bootc-dev/bootc.git "${src}"
cd "${src}"

# install-all rather than install: it also lays down the dracut module and the
# systemd units (bootc-fetch-apply-updates.timer among them), which the system
# stage needs in order to disable that timer in favour of the download-only one.
make bin
make install-all DESTDIR=/output

rm -rf "${src}"
