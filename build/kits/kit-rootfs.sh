#!/bin/sh
# kit-rootfs.sh - a root filesystem made of system kits and nothing else (docs/RECIPES.md, "A root from kits").
#
#   build/kits/kit-rootfs.sh ROOT KIT...        (root; KIT_CONF names the kit.conf with the repository and keys)
#
# ROOT (empty or absent) gets the skeleton of a merged-/usr system (the top directories, /bin /sbin /lib /lib64 as links
# into /usr), then kitd --root installs the named system kits and what they need into it: the kits in
# ROOT/var/lib/kit/store, the merged /usr view in ROOT/var/lib/kit/system/usr with its device list as the installed
# system will read it, and the kits' defaults in /etc and /var (kit-defaults). /usr itself is left EMPTY: it is the view,
# mounted by the initramfs at boot (90ribbon-usrview). No package manager is involved and nothing of the host is copied.
# KITD names another kitd (default: this tree's); the other environment is kitd's (KIT_SWAPMOUNT, KIT_EROFS_MIN, ...).
set -eu
ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
die() { echo "kit-rootfs: $*" >&2; exit 1; }
[ $# -ge 2 ] || die "usage: kit-rootfs.sh ROOT KIT..."
[ "$(id -u)" = 0 ] || die "root makes a root (loop devices and mounts)"
R=$1; shift
case $R in /*) ;; *) R=$PWD/$R ;; esac
[ "$R" != / ] || die "not /"
if [ -d "$R" ] && [ -n "$(ls -A "$R" 2>/dev/null)" ]; then die "$R is not empty"; fi
KITD=${KITD:-$ROOT_DIR/srcpkgs/ribbon-kit/files/bin/kitd}
TCLSH=$(command -v tclsh || command -v tclsh8.6) || die "no tclsh"

mkdir -p "$R"
for d in boot dev etc home mnt proc run sys usr var/lib var/cache var/log; do mkdir -p "$R/$d"; done
mkdir -m 0700 "$R/root"; mkdir -m 1777 "$R/tmp" "$R/var/tmp"
ln -s usr/bin "$R/bin"; ln -s usr/bin "$R/sbin"; ln -s usr/lib "$R/lib"; ln -s usr/lib "$R/lib64"

rc=0
"$TCLSH" "$KITD" --root "$R" grab "$@" || rc=$?
# the view was mounted for the install; an image carries it unmounted
if mountpoint -q "$R/usr" 2>/dev/null; then umount "$R/usr" || umount -l "$R/usr" || die "cannot unmount $R/usr"; fi
[ $rc = 0 ] || die "the kits were not installed (kitd's exit status $rc); $R is left for inspection"
[ -f "$R/var/lib/kit/system/usr/current" ] || die "no /usr view was made in $R"
# kitd's working files are not the image's
rm -rf "$R/var/cache/kit" "$R/var/lib/kit/staging" "$R/var/lib/kit/queue" "$R/var/lib/kit/lock" "$R/var/lib/kit/system/usr"/stage-* 2>/dev/null || :
echo "kit-rootfs: $R: $(grep -c '^kit' "$R/var/lib/kit/system/usr/view-$(cat "$R/var/lib/kit/system/usr/current").erofs.devices") system kits, /usr is view $(cat "$R/var/lib/kit/system/usr/current")"
