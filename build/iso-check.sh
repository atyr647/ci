#!/bin/sh
# iso-check.sh ROOTFS - what the live image must hold before it is packed (run by build/iso-postsetup.sh; a failure
# stops build/build-iso.sh). Two things that went wrong unnoticed until 23 Nov:
#   1. Every package of Ribbon's repository (RIBBON_REPO_DIR) that is installed in the image was installed from that
#      repository. void-mklive puts each -r in front of the ones before it, so the repository given first was looked in
#      last: where Ribbon overrides a package of Void's at the same version (base-files, bcachefs-tools) the image
#      took Void's.
#   3. (Below, found 24 Nov) the package database is consistent: xbps-pkgdb -a finds no package file edited after
#      it was installed and no dependency unmet. The image had three such faults (greetd's PAM file edited by
#      ribbon-desktop's INSTALL, ribbon-desktop's autostart edited by iso-postsetup.sh, ribbon-gaming needing the
#      wine-32bit that wine replaces); every installed system copied them, and ribbon-doctor reported them there.
#   2. Every kernel in the image has the modules of the root filesystems the installer offers and no kernel has in
#      its own tree: zfs and bcachefs, built by DKMS when the image is made. A build that failed said "FAILED!" in the
#      log and the image went on without the module.
# Needs xbps-query, xbps-uhelper and xbps-pkgdb (Void); RIBBON_ISO_MODULES names the modules (default "zfs bcachefs").
set -u
ROOTFS=${1:?usage: iso-check.sh ROOTFS}
: "${RIBBON_REPO_DIR:?iso-check.sh: RIBBON_REPO_DIR is not set}"
bad=0
say() { echo "iso-check: $*" >&2; bad=1; }

n=0
for f in "$RIBBON_REPO_DIR"/*.xbps; do
	[ -f "$f" ] || continue
	pv=$(xbps-uhelper binpkgver "$f") || { say "$(basename "$f") cannot be read"; continue; }
	name=$(xbps-uhelper getpkgname "$pv")
	inst=$(xbps-query -r "$ROOTFS" -p pkgver "$name" 2>/dev/null) || continue	# not installed in the image
	repo=$(xbps-query -r "$ROOTFS" -p repository "$name" 2>/dev/null)
	n=$((n + 1))
	if [ "$inst" != "$pv" ]; then say "$name: the image has $inst, Ribbon's repository $pv"
	elif [ "${repo%/}" != "${RIBBON_REPO_DIR%/}" ]; then say "$name ($pv) was installed from $repo, not from Ribbon's repository"; fi
done
[ "$n" -gt 0 ] || say "nothing of Ribbon's repository ($RIBBON_REPO_DIR) is installed in the image"

k=0
for d in "$ROOTFS"/usr/lib/modules/*/; do
	[ -d "$d" ] || continue
	v=$(basename "$d"); k=$((k + 1))
	for m in ${RIBBON_ISO_MODULES-zfs bcachefs}; do
		[ -n "$(find "$d" -name "$m.ko" -o -name "$m.ko.*" | head -n1)" ] ||
			say "kernel $v has no $m module (did DKMS fail to build it? see the log above)"
	done
done
[ "$k" -gt 0 ] || say "the image has no kernel modules at all"

if ! db=$(xbps-pkgdb -r "$ROOTFS" -a 2>&1); then
	say "the package database reports problems (xbps-pkgdb -a):"
	printf '%s\n' "$db" | head -n 20 | sed 's/^/iso-check:   /' >&2
fi

[ "$bad" = 0 ] || exit 1
echo "iso-check: $n packages from Ribbon's repository, $k kernels with their modules (${RIBBON_ISO_MODULES-zfs bcachefs}), the package database consistent"
