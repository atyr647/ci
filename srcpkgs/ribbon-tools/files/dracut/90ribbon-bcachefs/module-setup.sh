#!/bin/bash
# dracut module: mount a (possibly encrypted) bcachefs root - Ribbon OS.
check() {
	require_binaries bcachefs || return 1
	return 255   # only when asked for (add_dracutmodules+=" ribbon-bcachefs ")
}
depends() { return 0; }
installkernel() { instmods bcachefs; }
install() {
	inst_multiple bcachefs
	[ -e /usr/bin/mount.bcachefs ] && inst /usr/bin/mount.bcachefs
	inst_hook pre-mount 50 "$moddir/ribbon-bcachefs-unlock.sh"
}
