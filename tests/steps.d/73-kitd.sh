#!/bin/sh
# kitd, kit's privileged helper (srcpkgs/ribbon-kit/files/bin/kitd), and the system scope it runs in (lib/system.tcl):
# tests/kitd.tcl on a private bus standing in for the system bus, with a stand-in polkit Authority
# (tests/fixtures/polkit-authority.tcl) and a fake root. D-Bus activation, polkit asked with the caller's bus name,
# the queue (order, Cancel, a kitd killed mid-transaction), the idle exit, Pending; in-process: the system scope's
# paths, refuse, the restart record across boots, settle, waiting from the record and the queue, the never-live
# /proc scan, txn.tcl's amend. Skips without tclsh8.6, dbus-daemon, or unix_extra (built from srcpkgs/tcl-unix-extra
# when Tcl headers are there). NOT covered: a real polkitd and system bus, a second user, system kits installed.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1 || ! command -v dbus-daemon >/dev/null 2>&1; then
	echo "  skip kitd (no tclsh8.6 / dbus-daemon)"; exit 0
fi
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip kitd (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
TCLLIBPATH="${ux:+$ux }${TCLLIBPATH:-}"; export TCLLIBPATH
if timeout -k 5 240 tclsh8.6 -encoding utf-8 tests/kitd.tcl >"$T/out" 2>&1; then
	echo "  ok   kitd: activation, polkit, the queue, Pending; the system scope, the restart record, the never-live scan ($(grep -c '^  ok ' "$T/out") checks)"
else
	sed 's/^/     /' "$T/out"; echo "  FAIL kitd (tests/kitd.tcl)"; exit 1
fi
