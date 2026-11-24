#!/bin/sh
# build/install/build.sh - build Ribbon's own native pieces and generated files, on any base, into O.
#
#   build/install/build.sh [PACKAGE ...]          (default: every package in build/install/manifests)
#
# Environment: O (output, default out/build; each package gets O/PACKAGE), CC, CFLAGS, LDFLAGS, CXX, CXXFLAGS,
# DISTDIR (default out/distfiles: the templates' third-party distfiles, by the names the templates give them,
# checked against the templates' checksums; what is missing is left out and said), METAKIT (the Metakit fork's
# source; mkkitfs is built only with it), RIBBON_REPO_URL and RIBBON_CHANNEL_URL (ribbon-base's xbps.d file;
# defaults as build/build-packages.sh).
#
# Only this repository's sources are compiled. Third-party code (tkdnd, unix_sockets, Mk4tcl, Metakit, void-runit,
# the fonts) is never built here; those are dependencies (out/build/dependencies.txt, from build/install/deps.sh).
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
O=${O:-$ROOT/out/build}
case $O in /*) ;; *) O=$ROOT/$O ;; esac
DISTDIR=${DISTDIR:-$ROOT/out/distfiles}
case $DISTDIR in /*) ;; *) DISTDIR=$ROOT/$DISTDIR ;; esac
CC=${CC:-cc}
CFLAGS=${CFLAGS:--O2 -g}
LDFLAGS=${LDFLAGS:-}
CXX=${CXX:-c++}
CXXFLAGS=${CXXFLAGS:--O2 -g}
METAKIT=${METAKIT:-}
export CC CFLAGS LDFLAGS CXX CXXFLAGS

say() { printf '%s\n' "build: $*"; }
die() { printf '%s\n' "build: $*" >&2; exit 1; }

# distfile NAME PACKAGE: print DISTDIR/NAME when it is there and matches PACKAGE's template checksum; nothing when
# it is not there; stop when it is there but differs (a wrong download must not be installed)
distfile() {
	f=$DISTDIR/$1
	[ -f "$f" ] || return 0
	want=$(
		# shellcheck disable=SC1090
		set +eu; XBPS_CROSS_BASE=; . "srcpkgs/$2/template" >/dev/null 2>&1
		i=0; for d in $distfiles; do i=$((i + 1)); case $d in *">$1") echo "$i" ;; esac; done | {
			read -r n || exit 0; j=0; for c in $checksum; do j=$((j + 1)); [ "$j" = "$n" ] && echo "$c"; done; :; }
	)
	[ -n "$want" ] || die "$1 is not a distfile of $2"
	have=$(sha256sum "$f" | cut -d' ' -f1)
	[ "$have" = "$want" ] || die "$f does not match the checksum in srcpkgs/$2/template"
	echo "$f"
}

build_ribbon_desktop() {
	F=srcpkgs/ribbon-desktop/files B=$O/ribbon-desktop
	mkdir -p "$B"
	make -s -C "$F/shell-watch" O="$B" ribbon-shell-watch ribbon-shell-switch
	make -s -C "$F/rbnalpha" O="$B"
	make -s -C "$F/ribbon-wall" O="$B" LIBDIR=/usr/lib/ribbon/wall
	make -s -C "$F/apps/polkit/native" O="$B"
	make -s -C "$F/apps/hud/native" O="$B"
	make -s -C "$F/apps/hud/native" O="$B" layer
	# shellcheck disable=SC2086
	$CC $CFLAGS -Wall -Wextra $LDFLAGS -o "$B/ribbon-fswatch" "$F/fswatch/ribbon-fswatch.c"
	sg=$(distfile SpaceGrotesk-wght.ttf ribbon-desktop)
	rm -f "$B/SpaceGrotesk-SemiBold.ttf"
	if [ -n "$sg" ]; then
		python3 "$F/greeter/space-grotesk-semibold.py" "$sg" "$B/SpaceGrotesk-SemiBold.ttf"
	else
		say "ribbon-desktop: no $DISTDIR/SpaceGrotesk-wght.ttf, so no Space Grotesk SemiBold (the fonts are left out)"
	fi
	# every colour scheme's wallpaper and the default scheme's window theme (the template does this in do_install)
	rm -rf "$B/render" "$B/wallpapers"
	mkdir -p "$B/wallpapers"
	for p in "$F"/themes/palettes/*.conf; do
		p=$(basename "$p" .conf)
		bash "$F/bin/ribbon-theme" render-from "$F/themes" "$p" "$B/render/$p" >/dev/null
		cp "$B/render/$p/wallpaper.svg" "$B/wallpapers/$p.svg"
	done
}

build_ribbon_base() {
	B=$O/ribbon-base
	mkdir -p "$B"
	# shellcheck disable=SC1091
	. config/ribbon.conf
	: "${RIBBON_REPO_URL:=https://github.com/atyr647/ribbon/releases/download/repo-current}"
	: "${RIBBON_CHANNEL_URL:=${VOID_MIRROR}/current}"
	sed -e "s|@RIBBON_REPO@|${RIBBON_REPO_URL}|g" -e "s|@RIBBON_CHANNEL@|${RIBBON_CHANNEL_URL}|g" \
		srcpkgs/ribbon-base/files/xbps-repository-main.conf > "$B/xbps-repository-main.conf"
}

build_ribbon_dinit() {
	B=$O/ribbon-dinit
	mkdir -p "$B"
	echo ribbon > "$B/hostname"
	printf 'LANG=en_US.UTF-8\nLC_COLLATE=C\n' > "$B/locale.conf"
}

build_ribbon_tools() {
	B=$O/ribbon-tools
	mkdir -p "$B"
	echo 'add_dracutmodules+=" ribbon-snapshot "' > "$B/ribbon-snapshot.conf"
	printf '# Written by ribbon-scheduler. SCHEDULER=off uses the kernel EEVDF scheduler.\nSCHEDULER=scx_lavd\nARGS=""\nGAMEMODE_ARGS="--performance"\n' > "$B/scheduler.conf"
	printf '# Written by ribbon-swap. Change with: ribbon swap set ...\nZRAM_SIZE=50%%\nZRAM_ALGO=zstd\nSWAPFILE_SIZE=off\nHIBERNATE=no\n' > "$B/swap.conf"
}

build_tcl_unix_extra() {
	B=$O/tcl-unix-extra
	mkdir -p "$B"
	if [ -n "${TCL_CONFIG:-}" ]; then
		make -s -C srcpkgs/tcl-unix-extra/files O="$B" TCL_CONFIG="$TCL_CONFIG"
	else
		make -s -C srcpkgs/tcl-unix-extra/files O="$B"
	fi
}

build_ribbon_kit() {
	B=$O/ribbon-kit
	mkdir -p "$B"
	make -s -C srcpkgs/ribbon-kit/files/landlock O="$B"
}

build_mkkitfs() {
	B=$O/mkkitfs
	if [ -z "$METAKIT" ]; then
		rm -f "$B/mkkitfs"
		say "mkkitfs: skipped (set METAKIT to the Metakit fork's source, branch kit-fixes, to build it)"
		return 0
	fi
	mkdir -p "$B"
	make -s -C srcpkgs/mkkitfs/files METAKIT="$METAKIT" O="$B"
}

pkgs=$*
[ -n "$pkgs" ] || pkgs=$(for m in build/install/manifests/*.manifest; do basename "$m" .manifest; done)
mkdir -p "$O"
for p in $pkgs; do
	[ -f "build/install/manifests/$p.manifest" ] || die "no package $p (build/install/manifests/$p.manifest)"
	say "$p"
	case $p in
		ribbon-desktop) build_ribbon_desktop ;;
		ribbon-base) build_ribbon_base ;;
		ribbon-dinit) build_ribbon_dinit ;;
		ribbon-tools) build_ribbon_tools ;;
		tcl-unix-extra) build_tcl_unix_extra ;;
		ribbon-kit) build_ribbon_kit ;;
		mkkitfs) build_mkkitfs ;;
		*) mkdir -p "$O/$p" ;;   # nothing to build: scripts and data only
	esac
done
sh build/install/deps.sh > "$O/dependencies.txt"
say "dependencies: $O/dependencies.txt"
