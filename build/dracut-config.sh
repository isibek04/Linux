#!/usr/bin/env bash
# Configure dracut, before anything installs a kernel.
#
# Debian's default initramfs generator is initramfs-tools, which has no ostree
# support. dracut does, via the `bootc` module that the builder stage's
# `make install-all` dropped into /usr/lib/dracut/modules.d.
#
# This has to run before the kernel package, not after: installing a kernel
# fires /etc/kernel/postinst.d, which generates an initramfs with whatever
# dracut config is in place at the time. Without these files that run would use
# dracut's stock settings -- host-specific, and with no bootc module -- and
# either fail the build or bake a useless initramfs.
set -euo pipefail

conf=/usr/lib/dracut/dracut.conf.d
mkdir -p "${conf}"

# The bootc dracut module looks for systemd units in the Fedora locations.
# Point it at Debian's before it goes hunting.
cat > "${conf}/30-os4-paths.conf" <<'EOF'
systemdsystemconfdir=/etc/systemd/system
systemdsystemunitdir=/usr/lib/systemd/system
EOF

# hostonly=no because the image has no idea which machine it will boot on: a
# host-specific initramfs baked at build time would only ever work on the
# builder.
cat > "${conf}/30-os4-bootc.conf" <<'EOF'
reproducible=yes
hostonly=no
compress="zstd"
add_dracutmodules+=" bootc "
EOF
