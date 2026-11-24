#!/bin/sh
# Settings is one window (C1): a second ribbon-settings hands --page to the running one, which shows it, and exits
# (apps/settings/main.tcl: a unix socket in XDG_RUNTIME_DIR, else Tk's send). Under xvfb (tests/settings-single.sh).
# Skips without wish8.6 / xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip Settings single instance (no wish8.6 / xvfb-run)"; exit 0
fi
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip Settings single instance (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
D=$PWD/srcpkgs/ribbon-desktop/files
TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}"; export TCLLIBPATH
mkdir -p "$T/home/.config/ribbon" "$T/rt" "$T/cache"; chmod 700 "$T/rt"
cp "$D/themes/palettes/ribbon.conf" "$T/home/.config/ribbon/palette.conf"
if env -u WAYLAND_DISPLAY HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/cache" XDG_RUNTIME_DIR="$T/rt" \
	DBUS_SESSION_BUS_ADDRESS="unix:path=$T/none" DBUS_SYSTEM_BUS_ADDRESS="unix:path=$T/none" \
	timeout -k 5 240 xvfb-run -a -s "-screen 0 1440x900x24" sh tests/settings-single.sh "$D" "$T" >"$T/out" 2>&1; then
	cat "$T/out"; echo "Settings single instance: all checks passed"
else
	cat "$T/out"; echo "  FAIL Settings single instance"; exit 1
fi
