#!/bin/sh
# The main display (U11, shell/display.tcl): the bars, the dock, the panels, a terminal group and Alt+Tab go on the
# output display.conf names, at its size, and move when it changes. tests/shell-display.tcl checks the reader in
# tclsh (wlr-randr's JSON and plain listings, scales and transforms, the fallbacks); tests/shell-display-scene.tcl
# runs the shell under xvfb on a 2880x900 screen that a stub wlr-randr lists as two 1440x900 outputs, and checks
# there the tray while the power button's panel is open (68) and the dock's count colours (221).
# tests/term-resize.tcl drags the terminal strip's edges (171). Skips what the container lacks.
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
command -v tclsh8.6 >/dev/null 2>&1 || { echo "  skip the main display (no tclsh8.6)"; exit 0; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
if TMPDIR=$T tclsh8.6 tests/shell-display.tcl >"$T/unit" 2>&1 && grep -q 'all checks passed' "$T/unit"; then
	sed -n 's/^  ok   /  ok   display: /p' "$T/unit"
else
	sed 's/^/       /' "$T/unit"; echo "  FAIL the main display's reader (tests/shell-display.tcl)"; fails=1
fi
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip the main display scene and the terminal resize (no wish8.6 / xvfb-run)"
	exit $fails
fi
D=$PWD/srcpkgs/ribbon-desktop/files
mkdir -p "$T/bin" "$T/cfg/ribbon" "$T/home" "$T/run" "$T/state" "$T/cache" "$T/r2/run" "$T/r2/state" "$T/r2/cache"
chmod 700 "$T/run" "$T/r2/run"
cp "$D/themes/palettes/ribbon.conf" "$T/cfg/ribbon/palette.conf"
echo "main HEADLESS-2" >"$T/cfg/ribbon/display.conf"
# wlr-randr as labwc answers it with two headless outputs side by side (--json as 0.4 does)
cat >"$T/bin/wlr-randr" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --json ]; then
	cat <<'J'
[{"name": "HEADLESS-1", "description": "Headless output 1", "enabled": true,
  "modes": [{"width": 1440, "height": 900, "refresh": 60.0, "preferred": false, "current": true}],
  "position": {"x": 0, "y": 0}, "transform": "normal", "scale": 1.000000, "adaptive_sync": false},
 {"name": "HEADLESS-2", "description": "Headless output 2", "enabled": true,
  "modes": [{"width": 1440, "height": 900, "refresh": 60.0, "preferred": false, "current": true}],
  "position": {"x": 1440, "y": 0}, "transform": "normal", "scale": 1.000000, "adaptive_sync": false}]
J
	exit 0
fi
exit 1
EOF
chmod +x "$T/bin/wlr-randr"
if HOME=$T/home XDG_CONFIG_HOME=$T/cfg XDG_RUNTIME_DIR=$T/run XDG_STATE_HOME=$T/state XDG_CACHE_HOME=$T/cache \
	PATH="$T/bin:$PATH" WAYLAND_DISPLAY=wayland-ribbon-test RIBBON_TERM_RC=$T/term-rc.xml \
	DBUS_SESSION_BUS_ADDRESS=unix:path=$T/none RIBBON_SHELL_TEST=tests/shell-display-scene.tcl \
	timeout -k 5 90 xvfb-run -a -s "-screen 0 2880x900x24" \
	wish8.6 -encoding utf-8 "$D/shell/main.tcl" -name ribbon-shell >"$T/scene" 2>&1 &&
	grep -q 'shell display scene: all checks passed' "$T/scene"; then
	sed -n 's/^  ok   /  ok   display: /p' "$T/scene"
else
	sed 's/^/       /' "$T/scene"; echo "  FAIL the main display scene (tests/shell-display-scene.tcl)"; fails=1
fi
if [ -f tests/term-resize.tcl ]; then
	if HOME=$T/home XDG_CONFIG_HOME=$T/cfg XDG_RUNTIME_DIR=$T/r2/run XDG_STATE_HOME=$T/r2/state XDG_CACHE_HOME=$T/r2/cache \
		RIBBON_SCREEN=1440x900 RIBBON_TERM_RC=$T/term-rc2.xml \
		DBUS_SESSION_BUS_ADDRESS=unix:path=$T/none RIBBON_SHELL_TEST=tests/term-resize.tcl \
		timeout -k 5 90 xvfb-run -a -s "-screen 0 1440x900x24" \
		wish8.6 -encoding utf-8 "$D/shell/main.tcl" -name ribbon-shell >"$T/resize" 2>&1 &&
		grep -q 'term resize: all checks passed' "$T/resize"; then
		sed -n 's/^  ok   /  ok   terminal: /p' "$T/resize"
	else
		sed 's/^/       /' "$T/resize"; echo "  FAIL the terminal strip's edge resize (tests/term-resize.tcl)"; fails=1
	fi
fi
# Under a real compositor: headless labwc with two 1440x900 outputs side by side and display.conf naming the second.
# Each output is grabbed (grim -o); the bars' band is drawn on the main output only, and moves to the other one
# after display.conf changes and `ribbon-shell-ctl display` is sent. Only the processes started here are stopped.
live() {
	L=$T/live
	mkdir -p "$L/rt" "$L/cfg/ribbon" "$L/labwc" "$L/state" "$L/cache" "$L/home"
	chmod 700 "$L/rt"
	cp "$D/themes/palettes/ribbon.conf" "$L/cfg/ribbon/palette.conf"
	echo "main HEADLESS-2" >"$L/cfg/ribbon/display.conf"
	echo 'echo "$DISPLAY" > "$XDG_RUNTIME_DIR/display"' >"$L/labwc/autostart"
	echo '<labwc_config><core><decoration>server</decoration></core><margin top="54" bottom="54" /></labwc_config>' >"$L/labwc/rc.xml"
	export XDG_RUNTIME_DIR=$L/rt HOME=$L/home XDG_CONFIG_HOME=$L/cfg XDG_STATE_HOME=$L/state XDG_CACHE_HOME=$L/cache
	unset WAYLAND_DISPLAY DISPLAY
	WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=2 \
		timeout 90 labwc -C "$L/labwc" >"$L/labwc.log" 2>&1 &
	lpid=$!
	i=0
	while [ ! -s "$L/rt/display" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
	[ -s "$L/rt/display" ] || { kill $lpid 2>/dev/null; tail -5 "$L/labwc.log"; echo "  FAIL labwc did not start"; return 1; }
	DISPLAY=$(cat "$L/rt/display"); WAYLAND_DISPLAY=$(find "$L/rt" -maxdepth 1 -regex '.*/wayland-[0-9]*' -printf '%f\n' | sort | head -n1)
	export DISPLAY WAYLAND_DISPLAY
	wlr-randr --output HEADLESS-1 --custom-mode 1440x900 --pos 0,0 >/dev/null 2>&1
	wlr-randr --output HEADLESS-2 --custom-mode 1440x900 --pos 1440,0 >/dev/null 2>&1
	DBUS_SESSION_BUS_ADDRESS=unix:path=$L/none RIBBON_SHELL_TEST=$PWD/tests/shell-scene.tcl RIBBON_SCENE=idle \
		timeout 80 wish8.6 -encoding utf-8 "$D/shell/main.tcl" -name ribbon-shell >"$L/shell.out" 2>&1 &
	spid=$!
	# the spread of the left bar's band (x 20-400, y 12-42) on output $1
	band() { grim -t ppm -o "$1" "$L/$1.ppm" 2>/dev/null && tclsh8.6 tests/ppm-band.tcl "$L/$1.ppm" 20 12 400 42; }
	drawn_on() { # wait (up to 20 s) until output $1 shows the bar and $2 does not
		i=0
		while [ $i -lt 100 ]; do
			a=$(band "$1"); b=$(band "$2")
			[ -n "$a" ] && [ -n "$b" ] && awk "BEGIN{exit !($a > 8 && $b < 1)}" && return 0
			sleep 0.2; i=$((i + 1))
		done
		echo "       $1 band spread ${a:-?}, $2 ${b:-?}"; return 1
	}
	r=0
	if drawn_on HEADLESS-2 HEADLESS-1; then echo "  ok   display: under labwc the bars are drawn on the main output (HEADLESS-2) only"
	else echo "  FAIL display: under labwc the bars are not on HEADLESS-2 only"; r=1; fi
	echo "main HEADLESS-1" >"$L/cfg/ribbon/display.conf"
	printf 'display\n' >"$L/rt/ribbon-shell"
	if drawn_on HEADLESS-1 HEADLESS-2; then echo "  ok   display: under labwc they move to HEADLESS-1 when display.conf names it"
	else echo "  FAIL display: under labwc the bars did not move to HEADLESS-1"; r=1; fi
	# HEADLESS-2 moved left of 0,0: X coordinates are the layout's, so its bars are at a negative X
	wlr-randr --output HEADLESS-2 --pos -1440,0 >/dev/null 2>&1
	echo "main HEADLESS-2" >"$L/cfg/ribbon/display.conf"
	printf 'display\n' >"$L/rt/ribbon-shell"
	if drawn_on HEADLESS-2 HEADLESS-1; then echo "  ok   display: under labwc, with HEADLESS-2 left of 0,0, the bars are drawn on it"
	else echo "  FAIL display: under labwc the bars are not on HEADLESS-2 left of 0,0"; r=1; fi
	[ $r -eq 0 ] || sed 's/^/       /' "$L/shell.out" | tail -5
	kill $spid $lpid 2>/dev/null
	wait $spid $lpid 2>/dev/null
	return $r
}
if command -v labwc >/dev/null 2>&1 && command -v grim >/dev/null 2>&1 && command -v Xwayland >/dev/null 2>&1 && command -v wlr-randr >/dev/null 2>&1; then
	( live ) || fails=1
else
	echo "  skip the main display under labwc (no labwc / grim / Xwayland / wlr-randr)"
fi
exit $fails
