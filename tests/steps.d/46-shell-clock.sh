#!/bin/sh
# The bar's clock and Settings → Date and time's choices (shell/status.tcl, bar.tcl): tests/shell-clock.tcl in the real
# shell under xvfb, with its own config and runtime directories: the clock's words for every choice in clock.conf
# (24-hour or not, seconds, the date), the once-a-second tick only with seconds, a file changed by hand noticed on the
# tick, Settings' own save shown at once through the shell's FIFO, and the system's zone followed when its link moves,
# all without restarting the shell. Skips without wish8.6 / xvfb-run or the zone files. NOT covered: the real
# /etc/localtime changing (a stand-in link is used), an /etc/localtime that is a copy rather than a link.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip the bar's clock (no wish8.6 / xvfb-run)"; exit 0
fi
if [ ! -f /usr/share/zoneinfo/Asia/Tokyo ] || [ ! -f /usr/share/zoneinfo/America/New_York ] || [ ! -f /usr/share/zoneinfo/Pacific/Auckland ]; then
	echo "  skip the bar's clock (no zone files in /usr/share/zoneinfo)"; exit 0
fi
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
D=$PWD/srcpkgs/ribbon-desktop/files
mkdir -p "$T/home" "$T/cfg" "$T/run" "$T/cache"
chmod 700 "$T/run"
if env -u TZ HOME="$T/home" XDG_CONFIG_HOME="$T/cfg" XDG_RUNTIME_DIR="$T/run" XDG_CACHE_HOME="$T/cache" RIBBON_FILES="$D" \
	RIBBON_SHELL_TEST=tests/shell-clock.tcl timeout -k 5 60 \
	xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/shell/main.tcl" -name ribbon-shell >"$T/out" 2>&1; then
	grep -v '^  ok ' "$T/out" | grep -v '^bar clock: all checks passed$' | sed 's/^/     /'
	echo "  ok   the bar's clock follows Settings → Date and time and the zone, without a restart ($(grep -c '^  ok ' "$T/out") checks)"
else
	grep -v '^  ok ' "$T/out" | sed 's/^/       /'
	echo "  FAIL the bar's clock (tests/shell-clock.tcl)"
	exit 1
fi
