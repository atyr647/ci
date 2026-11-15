#!/bin/sh
# System monitor window: tests/monitor-ui.tcl runs the Ledger in wish under xvfb with the board scene and then on
# the live sampler: the rail, the "N more" row, Search, the GPU page's controls, the rail's foot (ribbon-hud stood
# in for), the row menu through clicks on sacrificial processes (STOP, CONT, KILL, TERM then KILL, the clipboard,
# Files and Properties stood in for), the keys and the Not responding tag. Skips without wish8.6/xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip monitor window (no wish8.6 / xvfb-run)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# the programs the window starts, stood in for: each writes its arguments to NAME.out
printf '#!/bin/sh\nn=$1; shift\necho "$@" > "%s/$n.part" && mv "%s/$n.part" "%s/$n.out"\n' "$T" "$T" "$T" > "$T/rec.sh"
if HOME="$T" XDG_CACHE_HOME="$T/cache" XDG_CONFIG_HOME="$T/config" RIBBON_MONITOR_T="$T" RIBBON_MONITOR_SCENE=tests/monitor-ui.tcl timeout -k 5 120 \
	xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 \
	srcpkgs/ribbon-desktop/files/apps/monitor/main.tcl -name ribbon-monitor >"$T/out" 2>&1 \
	&& grep -q 'monitor-ui: all checks passed' "$T/out"; then
	grep '  ok ' "$T/out" | sed 's/^/  /'
	echo "monitor window: all checks passed"
else
	sed 's/^/       /' "$T/out"; echo "monitor window: checks failed"; exit 1
fi
