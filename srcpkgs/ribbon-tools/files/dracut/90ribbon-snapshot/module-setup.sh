#!/bin/bash
# dracut module: boot read-only snapshots with a writable tmpfs overlay, so a
# snapshot boots into a working desktop, and keep the boot try counter that
# falls back to the last good snapshot by itself (ribbon-snapshot-overlay.sh).
# btrfs: from the menu's "Ribbon OS snapshots" entries (ribbon-limine, or
# grub-btrfs with GRUB): rootflags=subvol=@snapshots/<N>/snapshot. bcachefs
# (and btrfs): ribbon.snapshot=<id>. Nothing is written to the snapshot;
# `ribbon rollback` makes it permanent.

check() {
	return 0
}

depends() {
	# btrfs only where its tools are (a bcachefs system has none; dracut
	# would drop this module with a dependency it cannot meet).
	command -v btrfs >/dev/null 2>&1 && echo btrfs
	return 0
}

installkernel() {
	instmods overlay
	# the EFI partition, for the try counter
	instmods vfat nls_cp437 nls_iso8859-1
}

install() {
	inst_multiple sed mv
	inst_hook pre-pivot 90 "$moddir/ribbon-snapshot-overlay.sh"
}
