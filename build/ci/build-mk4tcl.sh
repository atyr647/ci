#!/bin/sh
# build-mk4tcl.sh - build Mk4tcl (Metakit for Tcl, from Ribbon's Metakit fork) as srcpkgs/mk4tcl/template builds it,
# for CI: the check job's Mk4tcl (KITFMT_MK4TCL, so that the kit steps of tests/run.sh run) and the files
# build/install/manifests/mk4tcl.manifest installs (make install-mk4tcl O=...).
#
#   build/ci/build-mk4tcl.sh METAKIT OUT
#
# METAKIT is the template's distfile (checked against the template's checksum; any other tarball is refused) or a
# directory holding its unpacked source. OUT receives libMk4tclVERSION.so, pkgIndex.tcl (the line the template's
# do_install writes) and license.terms; OUT can go on TCLLIBPATH as it is. Tcl is found through tclConfig.sh
# (TCL_CONFIG=FILE, else the usual places). Third-party source: run this in CI, not on a development machine.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
[ $# -eq 2 ] || { echo "usage: $0 METAKIT-TARBALL|METAKIT-SOURCE OUT" >&2; exit 2; }
SRC=$1 OUT=$2
die() { echo "build-mk4tcl: $*" >&2; exit 1; }
# the template's version, commit and checksum
eval "$(set +eu; XBPS_CROSS_BASE=; . "$ROOT/srcpkgs/mk4tcl/template" >/dev/null 2>&1
	printf 'version=%s commit=%s checksum=%s\n' "$version" "$_mkcommit" "$checksum")"
[ -n "$version" ] && [ -n "$commit" ] && [ -n "$checksum" ] || die "cannot read srcpkgs/mk4tcl/template"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
if [ -f "$SRC" ]; then
	have=$(sha256sum "$SRC" | cut -d' ' -f1)
	[ "$have" = "$checksum" ] || die "$SRC is not the template's distfile (sha256 $have, the template has $checksum)"
	tar xzf "$SRC" -C "$T" || die "$SRC does not unpack"
	SRC=$T/metakit-$commit
fi
[ -f "$SRC/tcl/configure" ] && [ -f "$SRC/license.terms" ] || die "$SRC is not the Metakit source (no tcl/configure)"
SRC=$(cd "$SRC" && pwd)

if [ -z "${TCL_CONFIG:-}" ]; then
	for c in /usr/lib/tcl8.6/tclConfig.sh /usr/lib/x86_64-linux-gnu/tcl8.6/tclConfig.sh /usr/lib64/tclConfig.sh \
		/usr/lib/tclConfig.sh; do
		[ -f "$c" ] && { TCL_CONFIG=$c; break; }
	done
fi
[ -f "${TCL_CONFIG:-}" ] || die "no tclConfig.sh (install Tcl 8.6's development files, or set TCL_CONFIG)"
# shellcheck disable=SC1090
. "$TCL_CONFIG"
inc=${TCL_INCLUDE_SPEC#-I}
[ -f "$inc/tcl.h" ] || die "no tcl.h in $inc (from $TCL_CONFIG)"
[ -f "$TCL_STUB_LIB_PATH" ] || die "no Tcl stub library $TCL_STUB_LIB_PATH (from $TCL_CONFIG)"

# the template's do_configure and do_build: Metakit's own TEA build in build/, its config.h replaced by the one that
# is right on every architecture, Tcl linked through its stubs
CXX=${CXX:-c++}
B=$T/build
mkdir -p "$B"
(cd "$B" && CC=$CXX sh "$SRC/tcl/configure" --prefix=/usr --with-tcl="$(dirname "$TCL_CONFIG")" \
	--with-tclinclude="$inc") >"$T/configure.log" 2>&1 || { cat "$T/configure.log"; die "configure failed"; }
cp "$ROOT/srcpkgs/mk4tcl/files/config.h" "$B/config.h"
make -C "$B" CC="$CXX" SHLIB_LD_LIBS="$TCL_STUB_LIB_PATH" >"$T/make.log" 2>&1 || { tail -n 40 "$T/make.log"; die "make failed"; }
[ -f "$B/libMk4tcl$version.so" ] || die "the build made no libMk4tcl$version.so"

# the template's do_install, into OUT
mkdir -p "$OUT"
cp "$B/libMk4tcl$version.so" "$OUT/"
chmod 755 "$OUT/libMk4tcl$version.so"
# shellcheck disable=SC2016
printf 'package ifneeded Mk4tcl %s [list load [file join $dir libMk4tcl%s.so] Mk4tcl]\n' "$version" "$version" \
	> "$OUT/pkgIndex.tcl"
cp "$SRC/license.terms" "$OUT/license.terms"
echo "build-mk4tcl: Mk4tcl $version (Metakit $commit) in $OUT"
