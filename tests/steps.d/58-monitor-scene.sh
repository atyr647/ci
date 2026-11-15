#!/bin/sh
# System monitor against its boards: the window drawn in wish under xvfb from tests/monitor-scene.tcl (the board's
# numbers set as the model) and compared with the board's render in tests/monitor-fixtures/boards (the 1240 x 760
# window of Monitor-R3-Ledger, -Ledger-Processes with the row menu and the Not responding tag, and -Ledger-GPU;
# both blurred, RMSE). What the build leaves out on purpose keeps the figure above zero: the menu's Priority entry
# (its submenu has no board), per-app network (the board now leaves the Network column empty too) and the game's cover art (a glyph).
# Skips without wish8.6, xvfb-run or ImageMagick.
set -u
cd "$(dirname "$0")/../.." || exit 1
for c in wish8.6 xvfb-run convert compare import; do
	if ! command -v $c >/dev/null 2>&1; then echo "  skip monitor scenes (no $c)"; exit 0; fi
done
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
for board in ledger processes gpu; do
	HOME="$T" XDG_CACHE_HOME="$T/cache" XDG_CONFIG_HOME="$T/config" RIBBON_MONITOR_BOARD=$board RIBBON_MONITOR_SHOT="$T/$board.png" \
		RIBBON_MONITOR_SCENE=tests/monitor-scene.tcl timeout -k 5 60 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 \
		srcpkgs/ribbon-desktop/files/apps/monitor/main.tcl -name ribbon-monitor >"$T/out" 2>&1
	if [ ! -s "$T/$board.png" ]; then
		sed 's/^/       /' "$T/out"; echo "  FAIL $board: the scene was not drawn"; fails=$((fails + 1)); continue
	fi
	convert "$T/$board.png" -crop 1240x760+100+84 +repage -blur 0x2 "$T/a.png"
	convert "tests/monitor-fixtures/boards/$board.png" -blur 0x2 "$T/b.png"
	r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
	if awk "BEGIN { exit !(${r:-1} < 0.035) }"; then
		echo "  ok   $board matches the board (blurred RMSE $r)"
	else
		echo "  FAIL $board against the board: RMSE ${r:-?}"; fails=$((fails + 1))
	fi
done
if [ "$fails" -eq 0 ]; then echo "monitor scenes: all checks passed"; else echo "monitor scenes: checks failed"; exit 1; fi
