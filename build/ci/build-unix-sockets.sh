#!/bin/sh
# build-unix-sockets.sh - build unix_sockets (Unix domain socket channels for Tcl) as srcpkgs/tcl-unix-sockets/template
# builds it, its patches applied, for CI: the check job's unix_sockets, so that the steps that need it (the Notes
# quick-capture hand-off, the greeter conversations, the FUSE tests) run instead of failing or skipping on a runner
# that has no package for it.
#
#   build/ci/build-unix-sockets.sh TARBALL OUT
#
# TARBALL is the template's distfile (checked against the template's checksum; any other tarball is refused). OUT
# receives the package directory as `make install-binaries` lays it out (the shared library and pkgIndex.tcl) and
# license.terms; OUT can go on TCLLIBPATH as it is. Tcl is found through tclConfig.sh (TCL_CONFIG=FILE, else the usual
# places). Third-party source: run this in CI, not on a development machine.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
[ $# -eq 2 ] || { echo "usage: $0 UNIX_SOCKETS-TARBALL OUT" >&2; exit 2; }
SRC=$1 OUT=$2
die() { echo "build-unix-sockets: $*" >&2; exit 1; }
eval "$(set +eu; XBPS_CROSS_BASE=; . "$ROOT/srcpkgs/tcl-unix-sockets/template" >/dev/null 2>&1
	printf 'version=%s checksum=%s wrksrc=%s\n' "$version" "$checksum" "$wrksrc")"
[ -n "$version" ] && [ -n "$checksum" ] && [ -n "$wrksrc" ] || die "cannot read srcpkgs/tcl-unix-sockets/template"
[ -f "$SRC" ] || die "no $SRC"
have=$(sha256sum "$SRC" | cut -d' ' -f1)
[ "$have" = "$checksum" ] || die "$SRC is not the template's distfile (sha256 $have, the template has $checksum)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
tar xzf "$SRC" -C "$T" || die "$SRC does not unpack"
S=$T/$wrksrc
[ -f "$S/configure" ] || die "$SRC holds no $wrksrc/configure"
for p in "$ROOT"/srcpkgs/tcl-unix-sockets/patches/*.patch; do
	patch -s -d "$S" -p1 < "$p" || die "$(basename "$p") does not apply"
done

if [ -z "${TCL_CONFIG:-}" ]; then
	for c in /usr/lib/tcl8.6/tclConfig.sh /usr/lib/x86_64-linux-gnu/tcl8.6/tclConfig.sh /usr/lib64/tclConfig.sh \
		/usr/lib/tclConfig.sh; do
		[ -f "$c" ] && { TCL_CONFIG=$c; break; }
	done
fi
[ -f "${TCL_CONFIG:-}" ] || die "no tclConfig.sh (install Tcl 8.6's development files, or set TCL_CONFIG)"

# the template's gnu-configure build and its make_install_target, into a staging root
(cd "$S" && ./configure --prefix=/usr --exec-prefix=/usr --with-tcl="$(dirname "$TCL_CONFIG")") >"$T/configure.log" 2>&1 ||
	{ cat "$T/configure.log"; die "configure failed"; }
make -C "$S" >"$T/make.log" 2>&1 || { tail -n 40 "$T/make.log"; die "make failed"; }
make -C "$S" DESTDIR="$T/dest" install-binaries >"$T/install.log" 2>&1 || { tail -n 40 "$T/install.log"; die "make install-binaries failed"; }
idx=$(find "$T/dest" -name pkgIndex.tcl | head -n1)
[ -n "$idx" ] || die "make install-binaries installed no pkgIndex.tcl"
mkdir -p "$OUT"
cp -R "$(dirname "$idx")" "$OUT/"
cp "$S/license.terms" "$OUT/license.terms"
echo 'exit [catch {package require unix_sockets}]' | TCLLIBPATH=$OUT tclsh8.6 || die "the build in $OUT does not load"
echo "build-unix-sockets: unix_sockets $version in $OUT"
