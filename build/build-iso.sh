#!/bin/bash
# Build the Ribbon OS live/installer ISO with void-mklive.
# Needs root, loop devices and the packages from build/build-packages.sh.
#   sudo build/build-iso.sh
set -euo pipefail
cd "$(dirname "$0")/.."
. config/ribbon.conf
[ "$(id -u)" -eq 0 ] || { echo "build-iso.sh must run as root" >&2; exit 1; }
# the repository as an absolute path (config/ribbon.conf's default already is one; a relative one given in the
# environment is taken from the top of the tree, since mklive runs from out/void-mklive)
case $RIBBON_REPO_DIR in /*) ;; *) RIBBON_REPO_DIR=$PWD/$RIBBON_REPO_DIR ;; esac
[ -e "$RIBBON_REPO_DIR/${RIBBON_ARCH}-repodata" ] || { echo "no Ribbon repository at $RIBBON_REPO_DIR; run build/build-packages.sh first" >&2; exit 1; }

MK=out/void-mklive
[ -d "$MK/.git" ] || git clone --depth 1 "$VOID_MKLIVE_GIT" "$MK"

# The live image boots Ribbon's kernel when its release is in the repository (build/ci/kernel.sh fetch puts it there,
# build/build-packages.sh indexes it), Void's ($RIBBON_KERNEL) otherwise. mklive knows only Void's kernel packages and
# their release names: build/mklive/ribbon-kernel.patch teaches it ribbon-kernel's (VERSION-ribbon_REVISION).
KPKG=$RIBBON_KERNEL
git -C "$MK" checkout -q -- mklive.sh
if ls "$RIBBON_REPO_DIR"/ribbon-kernel-[0-9]*.xbps >/dev/null 2>&1; then
	command -v patch >/dev/null 2>&1 || { echo "build-iso.sh: there is no patch program: the live image cannot boot Ribbon's kernel" >&2; exit 1; }
	patch -s -d "$MK" -p1 < build/mklive/ribbon-kernel.patch ||
		{ echo "build/mklive/ribbon-kernel.patch does not apply to this void-mklive: the live image cannot boot Ribbon's kernel" >&2; exit 1; }
	KPKG=ribbon-kernel
fi
echo "build-iso.sh: the live image boots $KPKG"

strip_list() { sed -e 's/#.*//' "$@" | tr -s ' \n' ' '; }
PKGS=$(strip_list build/packages/live.list)
IGNORE=$(strip_list build/packages/ignore.list)
mkdir -p out/iso

# void-mklive enables runit services by default; Ribbon uses dinit and enables
# its services in iso-postsetup.sh instead.
export DEFAULT_SERVICE_LIST=" "

# For iso-postsetup.sh (offline driver repository).
RIBBON_XBPS_REPOS="-R $RIBBON_REPO_DIR -R $VOID_MIRROR/current -R $VOID_MIRROR/current/nonfree -R $VOID_MIRROR/current/multilib -R $VOID_MIRROR/current/multilib/nonfree"
export RIBBON_XBPS_REPOS RIBBON_ARCH RIBBON_REPO_DIR
export RIBBON_OFFLINE_DRIVERS="${RIBBON_OFFLINE_DRIVERS:-yes}"

# Ribbon's repository is given LAST: mklive puts each -r in front of the ones before it, and xbps takes a package from
# the first repository that has it, so the last -r is the one looked in first. Given first (as it was until 23 Nov),
# Ribbon's builds of Void's packages at the same version (build/overrides) lost to Void's. If mklive stops reversing
# them, this stops rather than build an image of the wrong packages; build/iso-check.sh checks the image itself.
# shellcheck disable=SC2016
grep -qF 'r) XBPS_REPOSITORY="--repository=$OPTARG $XBPS_REPOSITORY";;' "$MK/mklive.sh" ||
	{ echo "build-iso.sh: this void-mklive no longer puts a later -r first: fix the order of the repositories below" >&2; exit 1; }
cd "$MK"
# rd.overlay=1: the live root as dracut's overlayfs over the read-only image (its layer at /run/rootfsbase, which the
# installer copies). mklive asks for it as rd.overlayfs=1, which Void's dracut (dracut-ng 112) does not read: the live
# system then ran on a device-mapper snapshot with 32 MiB to write to, and the first real install in CI found no
# /run/rootfsbase (24 Nov).
./mklive.sh \
	-a "$RIBBON_ARCH" \
	-b ribbon-base \
	-r "$VOID_MIRROR/current/multilib/nonfree" \
	-r "$VOID_MIRROR/current/multilib" \
	-r "$VOID_MIRROR/current/nonfree" \
	-r "$VOID_MIRROR/current" \
	-r "$RIBBON_REPO_DIR" \
	-v "$KPKG" \
	-p "$PKGS" \
	-g "$IGNORE" \
	-I "$OLDPWD/build/live-rootfs" \
	-x "$OLDPWD/build/iso-postsetup.sh" \
	-T "$RIBBON_ISO_TITLE" \
	-C "loglevel=3 split_lock_detect=off rd.overlay=1" \
	-o "$OLDPWD/out/iso/${RIBBON_ISO_NAME}.iso"
cd "$OLDPWD"
sha256sum "out/iso/${RIBBON_ISO_NAME}.iso" > "out/iso/${RIBBON_ISO_NAME}.iso.sha256"
echo "ISO: out/iso/${RIBBON_ISO_NAME}.iso"
