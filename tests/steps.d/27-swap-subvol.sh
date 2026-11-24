#!/bin/bash
# A swap file and ribbon-reserve's spare file are never put in a btrfs subvolume that snapshots take
# (common.sh ensure_swap_subvol; review finding of 17 Nov: on a layout without the installer's @swap mounted at /swap both
# landed inside @, where an active swap file blocks the snapshot and a snapshot pins the spare's extents). On a real
# btrfs in a loop image; and the installer's chroot does not leave a swap file active (RIBBON_INSTALLING).
# Skips unless root with losetup, mkfs.btrfs and a kernel that mounts btrfs.
set -u
cd "$(dirname "$0")/../.." || exit 1
T=$(mktemp -d /tmp/swapsub.XXXXXX) || exit 1
LOOP=
cleanup() { umount "$T/m" 2>/dev/null; [ -z "$LOOP" ] || losetup -d "$LOOP" 2>/dev/null; rm -rf "${T:?}"; }
trap cleanup EXIT INT TERM
fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
for t in losetup mkfs.btrfs btrfs mountpoint truncate; do command -v "$t" >/dev/null 2>&1 || { echo "  skip swap subvolumes (no $t)"; exit 0; }; done
[ "$(id -u)" = 0 ] || { echo "  skip swap subvolumes (not root)"; exit 0; }
grep -qw btrfs /proc/filesystems || { echo "  skip swap subvolumes (this kernel has no btrfs)"; exit 0; }
truncate -s 400M "$T/img"
LOOP=$(losetup -f --show "$T/img" 2>/dev/null) || { echo "  skip swap subvolumes (no loop device)"; exit 0; }
mkfs.btrfs -q -f "$LOOP" >/dev/null 2>&1 || { echo "  skip swap subvolumes (mkfs.btrfs failed)"; exit 0; }
mkdir -p "$T/m"
mount "$LOOP" "$T/m" 2>/dev/null || { echo "  skip swap subvolumes (cannot mount btrfs here)"; exit 0; }
lib() { RIBBON_ROOT=$T/m bash -c ". srcpkgs/ribbon-tools/files/lib/common.sh; $1" 2>"$T/err"; }

lib ensure_swap_subvol; rc=$?
if [ $rc = 0 ] && btrfs subvolume show "$T/m/swap" >/dev/null 2>&1; then ok "no /swap: a subvolume is made there (nested in the root's, so the root's snapshots leave it out)"; else bad "create: rc=$rc $(cat "$T/err")"; fi
lib ensure_swap_subvol && ok "  and asking again changes nothing" || bad "second call: $(cat "$T/err")"
# an active swap file would block a snapshot of the root if it were inside it; in the nested subvolume it does not matter
: > "$T/m/swap/f"; chattr +C "$T/m/swap/f" 2>/dev/null; fallocate -l 64M "$T/m/swap/f"
if btrfs subvolume snapshot "$T/m" "$T/m/snap1" >/dev/null 2>&1 && [ ! -e "$T/m/snap1/swap/f" ]; then ok "a snapshot of the root does not contain /swap's files"; else bad "snapshot holds the swap folder's files"; fi
lsattr -d "$T/m/swap" 2>/dev/null | cut -c1-20 | grep -q C && ok "  the subvolume is NOCOW (what is made in it later is, as a swap file needs)" || bad "swap subvolume is not NOCOW: $(lsattr -d "$T/m/swap" 2>&1)"

# an empty plain folder is replaced by the subvolume; one with files in it is refused
btrfs subvolume delete "$T/m/snap1" "$T/m/swap" >/dev/null 2>&1
mkdir "$T/m/swap"
lib ensure_swap_subvol && btrfs subvolume show "$T/m/swap" >/dev/null 2>&1 && ok "an empty /swap folder becomes the subvolume" || bad "empty folder: $(cat "$T/err")"
btrfs subvolume delete "$T/m/swap" >/dev/null 2>&1
mkdir "$T/m/swap"; : > "$T/m/swap/precious"
lib ensure_swap_subvol; rc=$?
if [ $rc = 1 ] && [ -e "$T/m/swap/precious" ] && grep -q 'not a btrfs subvolume' "$T/err"; then ok "a /swap folder with files in it is refused (exit 1) and left as it is"; else bad "full folder: rc=$rc $(cat "$T/err")"; fi

# another filesystem: nothing to do (a plain directory on this machine's own root is not btrfs unless it is)
if [ "$(findmnt -no FSTYPE /)" != btrfs ]; then
	RIBBON_ROOT='' bash -c ". srcpkgs/ribbon-tools/files/lib/common.sh; ensure_swap_subvol" && [ ! -e /swap ] && ok "on another filesystem it does nothing" || bad "non-btrfs root"
fi

# the swap tool uses it and does not swapon while installing
sw=srcpkgs/ribbon-tools/files/bin/ribbon-swap
grep -q 'ensure_swap_subvol' "$sw" && grep -q 'RIBBON_INSTALLING' "$sw" && grep -q 'ensure_swap_subvol' srcpkgs/ribbon-tools/files/bin/ribbon-reserve &&
	grep -q 'RIBBON_INSTALLING=1' srcpkgs/ribbon-installer/files/bin/ribbon-install && ok "ribbon-swap and ribbon-reserve make the subvolume first; the installer's chroot sets RIBBON_INSTALLING, which ribbon-swap reads before swapon" || bad "the pieces are not wired"
exit $fail
