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

strip_list() { sed -e 's/#.*//' "$@" | tr -s ' \n' ' '; }
PKGS=$(strip_list build/packages/live.list)
IGNORE=$(strip_list build/packages/ignore.list)
mkdir -p out/iso

# void-mklive enables runit services by default; Ribbon uses dinit and enables
# its services in iso-postsetup.sh instead.
export DEFAULT_SERVICE_LIST=" "

# For iso-postsetup.sh (offline driver repository).
RIBBON_XBPS_REPOS="-R $RIBBON_REPO_DIR -R $VOID_MIRROR/current -R $VOID_MIRROR/current/nonfree -R $VOID_MIRROR/current/multilib -R $VOID_MIRROR/current/multilib/nonfree"
export RIBBON_XBPS_REPOS RIBBON_ARCH
export RIBBON_OFFLINE_DRIVERS="${RIBBON_OFFLINE_DRIVERS:-yes}"

cd "$MK"
./mklive.sh \
	-a "$RIBBON_ARCH" \
	-b ribbon-base \
	-r "$RIBBON_REPO_DIR" \
	-r "$VOID_MIRROR/current" \
	-r "$VOID_MIRROR/current/nonfree" \
	-r "$VOID_MIRROR/current/multilib" \
	-r "$VOID_MIRROR/current/multilib/nonfree" \
	-v "$RIBBON_KERNEL" \
	-p "$PKGS" \
	-g "$IGNORE" \
	-I "$OLDPWD/build/live-rootfs" \
	-x "$OLDPWD/build/iso-postsetup.sh" \
	-T "$RIBBON_ISO_TITLE" \
	-C "loglevel=3 split_lock_detect=off" \
	-o "$OLDPWD/out/iso/${RIBBON_ISO_NAME}.iso"
cd "$OLDPWD"
sha256sum "out/iso/${RIBBON_ISO_NAME}.iso" > "out/iso/${RIBBON_ISO_NAME}.iso.sha256"
echo "ISO: out/iso/${RIBBON_ISO_NAME}.iso"
