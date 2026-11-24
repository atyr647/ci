#!/bin/sh
# postinstall's btrfs snapshot step (srcpkgs/ribbon-tools/files/bin/postinstall, step_snapshots): when `snapper create-config`
# fails, /.snapshots (unmounted and removed just before, because snapper wants to make it) is made and mounted again, so the
# fstab line for @snapshots still has its folder. The step works on the machine's real /.snapshots, so this is a STRUCTURAL
# check of the failure branch (the order of its lines), not a run; the rest of the step is run in the installer's tests.
set -u
cd "$(dirname "$0")/../.." || exit 1
f=srcpkgs/ribbon-tools/files/bin/postinstall
body=$(awk '/snapper --no-dbus -c root create-config/ { on = 1 } on { print } /^\t\t\t\tbtrfs subvolume delete/ { exit }' "$f")
if printf '%s\n' "$body" | grep -q 'snapper setup failed' &&
	printf '%s\n' "$body" | awk '/snapper setup failed/ { f = 1 } f && /mkdir -p \/\.snapshots/ { m = 1 } m && /mount \/\.snapshots/ { u = 1 } u && /return 0/ { r = 1 } END { exit !r }'; then
	echo "  ok   snapper failing: /.snapshots is made and mounted again before the step returns"
else
	printf '%s\n' "$body" | sed 's/^/    /'
	echo "  FAIL postinstall's snapper failure branch does not restore /.snapshots"; exit 1
fi
