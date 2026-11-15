#!/bin/sh
# Settings → Game overlay (U20 store and detection, U21 page): tests/settings-games.tcl (the store, the defaults and
# own-settings fallback, contents as one set, hidden, hand-added games, the file, and detection on the launcher fixtures
# in tests/fixtures/launchers, with no network) and, under xvfb, the page in its eight board states
# (tests/settings-games-scene.tcl), then a game's art in its tiles and preview, the Add sheet's Art chooser and the
# "ribbon-hud reload" a change sends. Skips without tclsh8.6.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then echo "  skip Settings → Game overlay (no tclsh8.6)"; exit 0; fi
st=0
if timeout -k 5 120 tclsh8.6 tests/settings-games.tcl "$(pwd)" </dev/null >"${TMPDIR:-/tmp}/settings-games.$$.out" 2>&1; then
	echo "  ok   Settings → Game overlay: the store and detection"
else
	echo "  FAIL Settings → Game overlay: the store and detection"; sed 's/^/       /' "${TMPDIR:-/tmp}/settings-games.$$.out"; st=1
fi
rm -f "${TMPDIR:-/tmp}/settings-games.$$.out"
if command -v wish8.6 >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 && [ -f tests/settings-games-scene.tcl ]; then
	T=$(mktemp -d)
	# the page tells the HUD about a change with "ribbon-hud reload": a stand-in that keeps its arguments
	printf '#!/bin/sh\necho "$*" >> "$0.log"\n' > "$T/ribbon-hud"; chmod +x "$T/ribbon-hud"
	if timeout -k 5 300 env HOME="$T/home" RIBBON_HUD_CMD="$T/ribbon-hud" XDG_CACHE_HOME="$T/cache" XDG_CONFIG_HOME="$T/cfg" \
		RIBBON_GAMES_CONF="$T/cfg/ribbon/game-overlay.conf" RIBBON_GAMES_HOME="$(pwd)/tests/fixtures/launchers/none" \
		RIBBON_SETTINGS_SCENE="$(pwd)/tests/settings-games-scene.tcl" RIBBON_GAMES_RESULT="$T/scene.txt" \
		xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/apps/settings/main.tcl \
		>"$T/scene.out" 2>&1; then
		sed 's/^/       /' "$T/scene.txt" 2>/dev/null
		if grep -q '^ok' "$T/scene.txt" 2>/dev/null && ! grep -q '^FAIL' "$T/scene.txt" 2>/dev/null; then
			echo "  ok   Settings → Game overlay: the page in its eight states, game art, the Add sheet, the HUD told"
		else
			echo "  FAIL Settings → Game overlay: the page in its eight states"; st=1
		fi
	else
		echo "  FAIL Settings → Game overlay: the page did not run"; sed 's/^/       /' "$T/scene.out" | tail -20; st=1
	fi
	rm -rf "$T"
else
	echo "  skip Settings → Game overlay page (needs wish8.6, xvfb-run and the scene)"
fi
exit $st
