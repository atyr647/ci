#!/bin/sh
# Settings → Default apps, the page (page-defaults.tcl) under xvfb with its model stood in for
# (tests/settings-defaults-scene.tcl): the page drawn in its board's state and compared with the board's crop in
# tests/fixtures/settings-pages/defaults.png (the page right of the rail; both blurred, RMSE), and every dropdown
# pressed as clicks, with the backend call each choice makes. Then the page over the real backend in scratch XDG
# folders (tests/settings-defaults-live.tcl): a click ends in mimeapps.list and xdg-terminals.list on disk. The logic
# behind the page has its own step (55-settings-defaults.sh). Skips without wish8.6 / xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip the Default apps page (no wish8.6 / xvfb-run)"; exit 0
fi
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip the Default apps page (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
D=$PWD/srcpkgs/ribbon-desktop/files
TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}"; export TCLLIBPATH
mkdir -p "$T/home/.config/ribbon"; cp "$D/themes/palettes/ribbon.conf" "$T/home/.config/ribbon/palette.conf"
fails=0
name=defaults
if env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/cache" XDG_DATA_HOME="$T/home/.local/share" \
	RIBBON_SETTINGS_SCENE="$PWD/tests/settings-defaults-scene.tcl" RIBBON_DEFAULTS_SHOT="$T/$name.png" RIBBON_DEFAULTS_RESULT="$T/$name.res" \
	timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" >"$T/out" 2>&1; then
	sed 's/^/  /' "$T/$name.res"
else
	[ -f "$T/$name.res" ] && sed 's/^/  /' "$T/$name.res"; sed 's/^/       /' "$T/out"; echo "  FAIL the Default apps page"; fails=$((fails + 1))
fi
if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1 && [ -s "$T/$name.png" ]; then
	convert "$T/$name.png" -crop 870x720+400+104 +repage -blur 0x2 "$T/a.png"; convert "tests/fixtures/settings-pages/$name.png" -blur 0x2 "$T/b.png"
	r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
	if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then echo "  ok   $name matches the board (blurred RMSE $r)"; else echo "  FAIL $name against the board: RMSE ${r:-?}"; fails=$((fails + 1)); fi
fi
# the same page over the real backend, in scratch XDG folders: two browsers, two terminals, no lists yet
L=$T/live
mkdir -p "$L/share/applications" "$L/bin" "$L/config" "$L/etc"
entry() { printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\nCategories=%s\nMimeType=%s\n' "$2" "$3" "$4" "$5" >"$L/share/applications/$1.desktop"; }
entry firefox Firefox 'firefox %u' 'Network;WebBrowser;' 'text/html;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;'
entry chromium Chromium 'chromium %U' 'Network;WebBrowser;' 'text/html;x-scheme-handler/http;x-scheme-handler/https;'
entry ribbon-terminal Terminal ribbon-terminal 'System;TerminalEmulator;' ''
entry alacritty Alacritty alacritty 'System;TerminalEmulator;' ''
printf '#!/bin/sh\n' >"$L/bin/alacritty"; chmod +x "$L/bin/alacritty"
if env HOME="$T/home" PATH="$L/bin:$PATH" XDG_CONFIG_HOME="$L/config" XDG_CONFIG_DIRS="$L/etc" XDG_DATA_HOME="$L/data-home" XDG_DATA_DIRS="$L/share" \
	RIBBON_DEFAULTS_ROOT="$L/root" XDG_CACHE_HOME="$T/cache" XDG_CURRENT_DESKTOP=Ribbon \
	RIBBON_SETTINGS_SCENE="$PWD/tests/settings-defaults-live.tcl" RIBBON_DEFAULTS_RESULT="$T/live.res" \
	timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" >"$T/out" 2>&1; then
	sed 's/^/  /' "$T/live.res"
else
	[ -f "$T/live.res" ] && sed 's/^/  /' "$T/live.res"; sed 's/^/       /' "$T/out"; echo "  FAIL the Default apps page over the real backend"; fails=$((fails + 1))
fi
[ -n "${RIBBON_KEEP_SHOTS:-}" ] && mkdir -p "$RIBBON_KEEP_SHOTS" && cp "$T"/$name*.png "$RIBBON_KEEP_SHOTS/" 2>/dev/null
[ $fails -eq 0 ] && echo "Default apps page: all checks passed" || { echo "Default apps page: $fails failed"; exit 1; }
