#!/bin/sh
# System monitor, round 4 (design/tools/gen_monitor_r4.py): the window drawn under xvfb from tests/monitor-r4-scene.tcl
# for each board (Monitor-R4-Priority, -Stuck, -End, -Services) and compared with the board's render in
# tests/monitor-fixtures/boards-r4 (the 1240 x 760 window; both blurred, RMSE < 0.05); then tests/monitor-r4.tcl
# against sacrificial processes and stand-ins (renice, the End sheet, the strip, --end, Services and its helper).
# MONITOR_APP=DIR runs another copy of apps/monitor (its main.tcl). Skips without wish8.6, xvfb-run or ImageMagick.
set -u
cd "$(dirname "$0")/../.." || exit 1
for c in wish8.6 xvfb-run convert compare import python3; do
	if ! command -v $c >/dev/null 2>&1; then echo "  skip monitor round 4 (no $c)"; exit 0; fi
done
APP=${MONITOR_APP:-srcpkgs/ribbon-desktop/files/apps/monitor}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
for board in priority stuck end services; do
	HOME="$T" XDG_CACHE_HOME="$T/cache" XDG_CONFIG_HOME="$T/config" RIBBON_MONITOR_R4=$board RIBBON_MONITOR_SHOT="$T/$board.png" \
		RIBBON_MONITOR_SCENE=tests/monitor-r4-scene.tcl timeout -k 5 60 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 \
		"$APP/main.tcl" -name ribbon-monitor >"$T/out" 2>&1
	if [ ! -s "$T/$board.png" ]; then
		sed 's/^/       /' "$T/out"; echo "  FAIL $board: the scene was not drawn"; fails=$((fails + 1)); continue
	fi
	convert "$T/$board.png" -crop 1240x760+100+84 +repage -blur 0x2 "$T/a.png"
	convert "tests/monitor-fixtures/boards-r4/$board.png" -blur 0x2 "$T/b.png"
	r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
	if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then
		echo "  ok   $board matches Monitor-R4 (blurred RMSE $r)"
	else
		echo "  FAIL $board against Monitor-R4: RMSE ${r:-?}"; fails=$((fails + 1))
	fi
done
mkdir -p "$T/flow"
if HOME="$T" XDG_CACHE_HOME="$T/cache" XDG_CONFIG_HOME="$T/config" RIBBON_MONITOR_T="$T/flow" RIBBON_MONITOR_SCENE=tests/monitor-r4.tcl \
	timeout -k 5 150 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$APP/main.tcl" -name ribbon-monitor >"$T/out" 2>&1 \
	&& grep -q 'monitor-r4: all checks passed' "$T/out"; then
	grep -E '  (ok|skip) ' "$T/out"
else
	sed 's/^/       /' "$T/out"; echo "  FAIL the round-4 flows"; fails=$((fails + 1))
fi
if [ "$fails" -eq 0 ]; then echo "monitor round 4: all checks passed"; else echo "monitor round 4: checks failed"; exit 1; fi
