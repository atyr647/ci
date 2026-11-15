#!/bin/sh
# tests/install-template-tree.sh PACKAGE WORKDIR [DISTDIR]
#
# What srcpkgs/PACKAGE/template installs, found without build/install: the template's do_install runs under bash
# (as xbps-src runs it) with stand-ins for xbps-src's helpers (vinstall vbin vman vconf vlicense vdoc vmkdir vcopy)
# that put the files into WORKDIR/destdir, and a stand-in make that carries out the install lines of a Makefile's
# `make install` (make -n). FILESDIR is the package's files/ staged as build/build-packages.sh stages it for
# xbps-src (plus LICENSE, kit/kitfmt and kit/kittrust for ribbon-kit, and ribbon-base's repository URLs). A source that is not there (something
# do_build would have made, or a third-party distfile) is put down as an empty file, so the layout is whole.
#
# WORKDIR/sources lists, per installed path, where the template took it from:
#   DEST<TAB>files|built|dist|made|external
#   files: the package's files/; built: ${wrksrc} (do_build's output); dist: ${XBPS_SRCDISTDIR} (a distfile);
#   made: written by do_install itself; external: a relative path do_install did not write (the distfile's tree).
set -eu
[ $# -ge 2 ] || { echo "usage: $0 PACKAGE WORKDIR [DISTDIR]" >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
pkg=$1 W=$2 DIST=${3:-}
T=$ROOT/srcpkgs/$pkg/template
[ -f "$T" ] || { echo "no template $T" >&2; exit 2; }
rm -rf "$W"
mkdir -p "$W/destdir" "$W/files" "$W/wrksrc" "$W/cwd" "$W/srcdist"
W=$(cd "$W" && pwd)
if [ -d "$ROOT/srcpkgs/$pkg/files" ]; then cp -a "$ROOT/srcpkgs/$pkg/files/." "$W/files/"; fi
cp "$ROOT/LICENSE" "$W/files/LICENSE"
if [ "$pkg" = ribbon-kit ]; then
	mkdir -p "$W/files/kitfmt" "$W/files/kittrust"
	cp "$ROOT"/kit/kitfmt/kitfmt.tcl "$ROOT"/kit/kitfmt/sha256.tcl "$ROOT"/kit/kitfmt/pkgIndex.tcl \
		"$ROOT"/kit/kitfmt/kitpack "$W/files/kitfmt/"
	cp "$ROOT"/kit/kittrust/kittrust.tcl "$ROOT"/kit/kittrust/pkgIndex.tcl "$W/files/kittrust/"
fi
if [ "$pkg" = ribbon-base ]; then # the repository URLs, filled in as build/build-packages.sh fills them in
	# shellcheck disable=SC1091
	. "$ROOT/config/ribbon.conf"
	: "${RIBBON_REPO_URL:=https://github.com/atyr647/ribbon/releases/download/repo-current}"
	: "${RIBBON_CHANNEL_URL:=${VOID_MIRROR}/current}"
	sed -i -e "s|@RIBBON_REPO@|${RIBBON_REPO_URL}|g" -e "s|@RIBBON_CHANNEL@|${RIBBON_CHANNEL_URL}|g" \
		"$W/files/xbps-repository-main.conf"
fi
: > "$W/sources"

W="$W" T="$T" DIST="$DIST" bash -e -c '
umask 022
XBPS_CROSS_BASE=
CC=cc CXX=c++ CFLAGS= LDFLAGS= CXXFLAGS=
. "$T"
FILESDIR=$W/files wrksrc=$W/wrksrc DESTDIR=$W/destdir XBPS_SRCDISTDIR=$W/srcdist
mkdir -p "$XBPS_SRCDISTDIR/$pkgname-$version"
if [ -n "$DIST" ]; then for d in $distfiles; do n=${d##*>}; [ -f "$DIST/$n" ] && cp "$DIST/$n" "$XBPS_SRCDISTDIR/$pkgname-$version/$n"; done; fi
kind() {
	case $1 in
		"$FILESDIR"/*) echo files ;;
		"$wrksrc"/*) echo built ;;
		"$XBPS_SRCDISTDIR"/*) echo dist ;;
		*) if [ -e "$1" ]; then echo made; else echo external; fi ;;
	esac
}
_put() { # SRC MODE DEST(relative to DESTDIR, full path)
	_s=$1; case $_s in /*) ;; *) _s=$PWD/$_s ;; esac
	_k=$(kind "$_s")
	mkdir -p "$DESTDIR/$(dirname "$3")"
	if [ -f "$_s" ]; then cp "$_s" "$DESTDIR/$3"; else : > "$DESTDIR/$3"; fi
	chmod "$2" "$DESTDIR/$3"
	printf "/%s\t%s\n" "$3" "$_k" >> "$W/sources"
}
vinstall() { _n=${4:-$(basename "$1")}; _put "$1" "$2" "$3/$_n"; }
vbin() { vinstall "$1" 755 usr/bin ${2:+"$2"}; }
vman() { _sec=${1##*.}; vinstall "$1" 644 "usr/share/man/man$_sec" ${2:+"$2"}; }
vconf() { vinstall "$1" 644 etc ${2:+"$2"}; }
vlicense() { vinstall "$1" 644 "usr/share/licenses/$pkgname" ${2:+"$2"}; }
vdoc() { vinstall "$1" 644 "usr/share/doc/$pkgname" ${2:+"$2"}; }
vmkdir() { mkdir -p "$DESTDIR/$1"; [ -z "${2:-}" ] || chmod "$2" "$DESTDIR/$1"; }
vcopy() {
	_k=$(kind "$1")
	_into=$2/$(basename "$1"); [ -d "$DESTDIR/$2" ] || _into=$2
	cp -a $1 ${DESTDIR}/${2}   # as xbps-src does it: into the directory when it is there, as it when it is not
	(cd "$1" && find . -type f) | while read -r _f; do printf "/%s\t%s\n" "$_into/${_f#./}" "$_k" >> "$W/sources"; done
}
make() { # only the install lines of `make install` are carried out, from make -n
	case " $* " in *" install "*) ;; *) return 0 ;; esac
	_dir=.; _prev=
	for _a in "$@"; do [ "$_prev" = -C ] && _dir=$_a; _prev=$_a; done
	# what install needs (the build) is taken as made: make -o for each of its prerequisites
	_old=$(command make -pn -k "$@" 2>/dev/null | sed -n "s/^install: *//p" | head -n1)
	set -- "$@" $(for _p in $_old; do printf -- "-o %s " "$_p"; done)
	command make -n -k "$@" 2>/dev/null | while read -r _cmd _opt _src _dst; do
		[ "$_cmd" = install ] || continue
		case $_src in /*) ;; *) _src=$_dir/$_src ;; esac
		case $_opt in -Dm[0-7]*) _put "$_src" "${_opt#-Dm}" "${_dst#"$DESTDIR"/}" ;; esac
	done
}
# xbps-src runs do_install in ${wrksrc}: relative paths in a third-party template (build/libMk4tcl*.so in mk4tcl)
# are what do_build made there
cd "$W/wrksrc"
do_install
if type post_install >/dev/null 2>&1; then post_install; fi
'
