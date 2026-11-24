#!/bin/sh
# The initramfs mounts the system kits' merged /usr view at boot (srcpkgs/ribbon-kit/files/dracut/90ribbon-usrview):
# tests/kit-usrview-initramfs.sh runs its pre-pivot hook on a fake root with stand-in losetup and mount.
set -u
cd "$(dirname "$0")/../.." || exit 1
sh tests/kit-usrview-initramfs.sh || { echo "  FAIL the initramfs's /usr view (tests/kit-usrview-initramfs.sh)"; exit 1; }
