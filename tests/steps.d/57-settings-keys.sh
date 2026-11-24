#!/bin/sh
# Settings, the host's keyboard and search (apps/settings/main.tcl, rail.tcl) under xvfb (tests/settings-keys-scene.tcl):
# Appearance's own shortcuts only on Appearance, the rail by Ctrl+Page Up/Down and by Tab then Up/Down, the search
# field's focus (ring, caret), Return opening the only match, and a click elsewhere ending the search.
# Skips without wish8.6 / xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip Settings keys (no wish8.6 / xvfb-run)"; exit 0
fi
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip Settings keys (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
D=$PWD/srcpkgs/ribbon-desktop/files
TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}"; export TCLLIBPATH
mkdir -p "$T/home/.config/ribbon" "$T/cache"; cp "$D/themes/palettes/ribbon.conf" "$T/home/.config/ribbon/palette.conf"
if env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/cache" DBUS_SESSION_BUS_ADDRESS="unix:path=$T/none" \
	DBUS_SYSTEM_BUS_ADDRESS="unix:path=$T/none" RIBBON_SETTINGS_SCENE="$PWD/tests/settings-keys-scene.tcl" RIBBON_KEYS_RESULT="$T/res" RIBBON_FIXTURES="$PWD/tests/fixtures" \
	timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" >"$T/out" 2>&1; then
	sed 's/^/  /' "$T/res"; echo "Settings keys: all checks passed"
else
	if [ -f "$T/res" ]; then sed 's/^/  /' "$T/res"; else sed 's/^/       /' "$T/out" | head -30; fi
	echo "  FAIL Settings keys"; exit 1
fi
