#!/bin/sh
# The System monitor's window (apps/monitor/main.tcl, monitor::resized; tests/monitor-window.tcl) on the live
# sampler: it opens at the board's size fitted under the shell's bars, which is its least size, and resizes and
# maximises with the page kept at the board's places from its right edge (and no Network column). First under xvfb (wm geometry, no window manager), then under a headless labwc with
# the shipped rc.xml and the shell's margin layer (its 54 px margins; maximised through _NET_WM_STATE, as the title bar's button does):
# the maximised window must stay inside the work area.
# Skips without wish8.6 and xvfb-run; the labwc part skips without labwc and Xwayland.
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
for c in tclsh8.6 wish8.6 xvfb-run; do
	if ! command -v $c >/dev/null 2>&1; then echo "  skip monitor window size (no $c)"; exit 0; fi
done
T=$(mktemp -d /tmp/mw.XXXXXX)
LPID=""
trap '[ -n "$LPID" ] && kill $LPID 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/home"

if env HOME="$T/home" XDG_CACHE_HOME="$T/cache" timeout -k 5 90 xvfb-run -a -s "-screen 0 1440x900x24" \
	wish8.6 -encoding utf-8 tests/monitor-window.tcl resize >"$T/x.out" 2>&1 &&
	grep -q '^monitor window: all checks passed' "$T/x.out"; then
	ok "under xvfb: $(grep -c '^ok ' "$T/x.out") checks (opens fitted, least size, resized: the page at its board places, no Network column)"
else
	sed 's/^/       /' "$T/x.out"; fail "monitor window under xvfb"
fi

if command -v labwc >/dev/null 2>&1 && command -v Xwayland >/dev/null 2>&1; then
	R=$T/rt; mkdir -p "$R" "$T/cfg" "$T/defaults/labwc" "$T/margin/labwc"; chmod 700 "$R"
	# layered as a session has them (--merge-config): the shipped rc.xml (maximised windows without a title bar)
	# under the layer the shell writes for the main display (shell/mod-margin.tcl: the bars' and the dock's 54 px
	# margins); the autostart only says where Xwayland is
	cp srcpkgs/ribbon-desktop/files/xdg/labwc/rc.xml "$T/defaults/labwc/rc.xml"
	echo 'namespace eval display { proc take args {} }; source srcpkgs/ribbon-desktop/files/shell/mod-margin.tcl
		puts -nonewline [margin::text HEADLESS-1]' | tclsh8.6 > "$T/margin/labwc/rc.xml"
	echo 'echo "$DISPLAY" > "$XDG_RUNTIME_DIR/display"' > "$T/defaults/labwc/autostart"
	env -u WAYLAND_DISPLAY -u DISPLAY XDG_RUNTIME_DIR="$R" HOME="$T/home" XDG_CONFIG_HOME="$T/cfg" XDG_CONFIG_DIRS="$T/margin:$T/defaults" \
		WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1 \
		timeout 120 labwc --merge-config >"$T/labwc.log" 2>&1 &
	LPID=$!
	end=$(($(date +%s) + 15)); WD=""
	while [ "$(date +%s)" -lt $end ]; do
		WD=$(find "$R" -maxdepth 1 -regex '.*/wayland-[0-9]*' -printf '%f\n' 2>/dev/null | sort | head -n1)
		[ -n "$WD" ] && break
		sleep 0.2
	done
	if [ -z "$WD" ]; then
		sed 's/^/       /' "$T/labwc.log"; fail "labwc did not start"
	else
		XDG_RUNTIME_DIR="$R" WAYLAND_DISPLAY=$WD wlr-randr --output HEADLESS-1 --custom-mode 1440x900 >/dev/null 2>&1
		end=$(($(date +%s) + 15)); XD=""
		while [ "$(date +%s)" -lt $end ]; do
			[ -s "$R/display" ] && XD=$(cat "$R/display")
			[ -n "$XD" ] && break
			sleep 0.2
		done
		if [ -z "$XD" ]; then
			echo "  skip monitor window under labwc (no Xwayland display)"
		elif env XDG_RUNTIME_DIR="$R" WAYLAND_DISPLAY=$WD DISPLAY=$XD HOME="$T/home" XDG_CACHE_HOME="$T/cache" \
			timeout -k 5 90 wish8.6 -encoding utf-8 tests/monitor-window.tcl labwc >"$T/l.out" 2>&1 &&
			grep -q '^monitor window: all checks passed' "$T/l.out"; then
			ok "under labwc: $(grep -c '^ok ' "$T/l.out") checks (opens inside the work area, maximised inside it, the page at its board places)"
		else
			sed 's/^/       /' "$T/l.out"; fail "monitor window under labwc"
		fi
	fi
	kill $LPID 2>/dev/null; LPID=""
else
	echo "  skip monitor window under labwc (no labwc or Xwayland)"
fi

[ $fails -eq 0 ] && echo "monitor window size: all checks passed" || echo "monitor window size: $fails checks failed"
exit $((fails > 0))
