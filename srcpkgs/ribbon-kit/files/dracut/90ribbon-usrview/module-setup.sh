#!/bin/bash
# dracut module: mount the merged erofs /usr view of the installed system kits at boot (docs/SYSTEM-UPDATES.md 7.2,
# D57 C / D58 B; srcpkgs/ribbon-kit/files/lib/mount.tcl builds the views and switches them live, this mounts the
# current one before switch_root). Without a view (no system kit installed yet) /usr stays what is on the root.

check() {
	require_binaries losetup || return 1
	return 0
}

depends() {
	return 0
}

installkernel() {
	instmods loop erofs
}

install() {
	inst_multiple losetup sed
	# after 90ribbon-snapshot: the view is mounted on the root that is booted, a snapshot's overlay included
	# shellcheck disable=SC2154 # dracut sets moddir
	inst_hook pre-pivot 95 "$moddir/ribbon-usrview.sh"
}
