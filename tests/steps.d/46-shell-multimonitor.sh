#!/bin/sh
# Every shell surface on the main display, and the window margin only there (W2):
#   1. Settings → Display's Keep runs `ribbon-shell-ctl display` and its kanshi profile carries it
#      (tests/settings-display-keep.tcl);
#   2. the shell under xvfb on two outputs of different sizes, the main one off 0,0 (tests/shell-multimonitor-scene.tcl):
#      the launcher's results and menu, the panels, the notifications and their history, Files' menus, Alt+Tab's still
#      and labwc's margin go on the main output, and move within a second when it changes; drawn as plain surfaces;
#   3. under headless labwc with two outputs: the same scene on labwc's own outputs, where the notifications are
#      see-through pictures; then (merge-config, Ribbon's own rc.xml under the shell's margin layer) a
#      maximised window keeps clear of the bars on the main output only, and on the other one after
#      `ribbon-shell-ctl display`; ribbon-shell-switch (built here) takes its still of the output it is asked for, by
#      name, scaled to the width asked.
# Skips what the container lacks. Only the processes started here are stopped.
set -u
cd "$(dirname "$0")/../.." || exit 1
D=$PWD/srcpkgs/ribbon-desktop/files
fails=0
command -v tclsh8.6 >/dev/null 2>&1 || { echo "  skip the multi-monitor checks (no tclsh8.6)"; exit 0; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# 1. Settings → Display's Keep
printf '#!/bin/sh\necho "ribbon-shell-ctl $*" >> "%s"\n' "$T/ctl.log" >"$T/bin/ribbon-shell-ctl"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/kanshictl"
chmod +x "$T/bin/ribbon-shell-ctl" "$T/bin/kanshictl"
: >"$T/ctl.log"
if TMPDIR=$T PATH="$T/bin:$PATH" tclsh8.6 tests/settings-display-keep.tcl "$D" "$T/ctl.log" >"$T/keep" 2>&1 &&
	grep -q 'settings display keep: all checks passed' "$T/keep"; then
	sed -n 's/^  ok   /  ok   multi-monitor: Settings: /p' "$T/keep"
else
	sed 's/^/       /' "$T/keep"; echo "  FAIL Settings → Display's Keep (tests/settings-display-keep.tcl)"; fails=1
fi
rm -f "$T/bin/ribbon-shell-ctl" "$T/bin/kanshictl"

# the margin layer follows a change of main output that keeps the rectangle (tests/shell-margin-follow.tcl)
mkdir -p "$T/mf"
if tclsh8.6 tests/shell-margin-follow.tcl "$D/shell" "$T/mf" >"$T/mf.out" 2>&1 &&
	grep -q 'shell margin follow: all checks passed' "$T/mf.out"; then
	sed -n 's/^  ok   /  ok   multi-monitor: margin: /p' "$T/mf.out"
else
	sed 's/^/       /' "$T/mf.out"; echo "  FAIL the margin layer follows the main output (tests/shell-margin-follow.tcl)"; fails=1
fi

# 2. the shell under xvfb
if command -v wish8.6 >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1; then
	cat >"$T/bin/wlr-randr" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --json ]; then
	cat <<'J'
[{"name": "HEADLESS-1", "description": "Headless output 1", "enabled": true,
  "modes": [{"width": 1440, "height": 1080, "refresh": 60.0, "preferred": false, "current": true}],
  "position": {"x": 0, "y": 0}, "transform": "normal", "scale": 1.000000, "adaptive_sync": false},
 {"name": "HEADLESS-2", "description": "Headless output 2", "enabled": true,
  "modes": [{"width": 1600, "height": 900, "refresh": 60.0, "preferred": false, "current": true}],
  "position": {"x": 1440, "y": 180}, "transform": "normal", "scale": 1.000000, "adaptive_sync": false}]
J
	exit 0
fi
exit 1
EOF
	chmod +x "$T/bin/wlr-randr"
	S=$T/x
	{
		mkdir -p "$S/cfg/ribbon" "$S/home" "$S/run" "$S/state" "$S/cache"
		chmod 700 "$S/run"
		cp "$D/themes/palettes/ribbon.conf" "$S/cfg/ribbon/palette.conf"
		echo "main HEADLESS-2" >"$S/cfg/ribbon/display.conf"
		: >"$S/reload.log"
		if HOME=$S/home XDG_CONFIG_HOME=$S/cfg XDG_RUNTIME_DIR=$S/run XDG_STATE_HOME=$S/state XDG_CACHE_HOME=$S/cache \
			PATH="$T/bin:$PATH" WAYLAND_DISPLAY=wayland-ribbon-test RIBBON_TERM_RC=$S/term-rc.xml \
			RIBBON_MARGIN_RC=$S/margin-rc.xml RIBBON_MARGIN_LOG=$S/reload.log RIBBON_MARGIN_RELOAD="echo \"\$1\" >> '$S/reload.log'" \
			DBUS_SESSION_BUS_ADDRESS=unix:path=$S/none RIBBON_SHELL_TEST=tests/shell-multimonitor-scene.tcl \
			timeout -k 5 90 xvfb-run -a -s "-screen 0 3040x1080x24" \
			wish8.6 -encoding utf-8 "$D/shell/main.tcl" -name ribbon-shell >"$S/scene" 2>&1 &&
			grep -q 'shell multi-monitor scene: all checks passed' "$S/scene"; then
			sed -n "s/^  ok   /  ok   multi-monitor (xvfb): /p" "$S/scene"
		else
			sed 's/^/       /' "$S/scene"; echo "  FAIL the multi-monitor scene under xvfb (tests/shell-multimonitor-scene.tcl)"; fails=1
		fi
	}
	rm -f "$T/bin/wlr-randr"
else
	echo "  skip the multi-monitor scene (no wish8.6 / xvfb-run)"
fi

# the session stacks the shell's margin layer between the tools' layer and Settings' input layer
dirs=$(sed -n 's/^export XDG_CONFIG_DIRS="\(.*\)"$/\1/p' "$D/bin/ribbon-session" | head -1)
case $dirs in
	'$state/ribbon/xdg:$state/ribbon/xdg-display:$state/ribbon/xdg-input:'*) echo "  ok   multi-monitor: ribbon-session layers the shell's margin (xdg-display)" ;;
	*) echo "  FAIL multi-monitor: ribbon-session's XDG_CONFIG_DIRS has no xdg-display layer under the tools' ($dirs)"; fails=$((fails + 1)) ;;
esac

# 3. under labwc
live() {
	L=$T/live
	mkdir -p "$L/rt" "$L/home" "$L/cfg/ribbon" "$L/state" "$L/cache" "$L/defaults/labwc"
	chmod 700 "$L/rt"
	cp "$D/themes/palettes/ribbon.conf" "$L/cfg/ribbon/palette.conf"
	echo "main HEADLESS-2" >"$L/cfg/ribbon/display.conf"
	# Ribbon's rc.xml as the defaults layer, the shell's margin layer over it (as ribbon-session stacks them)
	cp "$D/xdg/labwc/rc.xml" "$L/defaults/labwc/rc.xml"
	echo 'echo "$DISPLAY $LABWC_PID" > "$XDG_RUNTIME_DIR/display"' >"$L/defaults/labwc/autostart"
	export XDG_RUNTIME_DIR=$L/rt HOME=$L/home XDG_CONFIG_HOME=$L/cfg XDG_STATE_HOME=$L/state XDG_CACHE_HOME=$L/cache
	export XDG_CONFIG_DIRS="$L/state/ribbon/xdg-display:$L/defaults"
	unset WAYLAND_DISPLAY DISPLAY RIBBON_MARGIN_RC RIBBON_MARGIN_RELOAD
	WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=2 \
		timeout 120 labwc --merge-config >"$L/labwc.log" 2>&1 &
	lpid=$!
	i=0
	while [ ! -s "$L/rt/display" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
	[ -s "$L/rt/display" ] || { kill $lpid 2>/dev/null; tail -5 "$L/labwc.log"; echo "  FAIL labwc did not start"; return 1; }
	read -r DISPLAY LABWC_PID <"$L/rt/display"
	WAYLAND_DISPLAY=$(find "$L/rt" -maxdepth 1 -regex '.*/wayland-[0-9]*' -printf '%f\n' | sort | head -n1)
	export DISPLAY LABWC_PID WAYLAND_DISPLAY
	r=0
	# the scene again, on labwc's own outputs laid out as the stub did it, drawn as see-through pictures (rbnalpha,
	# built here unless RBNALPHA_LIB names a built one)
	if [ -z "${RBNALPHA_LIB:-}" ] || [ ! -f "$RBNALPHA_LIB" ]; then
		mkdir -p "$L/rbn"
		make -s -C "$D/rbnalpha" O="$L/rbn" >/dev/null 2>&1 && RBNALPHA_LIB=$L/rbn/librbnalpha.so && export RBNALPHA_LIB
	fi
	wlr-randr --output HEADLESS-1 --custom-mode 1440x1080 --pos 0,0 >/dev/null 2>&1
	wlr-randr --output HEADLESS-2 --custom-mode 1600x900 --pos 1440,180 >/dev/null 2>&1
	: >"$L/reload.log"
	if RIBBON_MARGIN_RC=$L/margin-rc.xml RIBBON_MARGIN_LOG=$L/reload.log RIBBON_MARGIN_RELOAD="echo \"\$1\" >> '$L/reload.log'" \
		RIBBON_TERM_RC=$L/term-rc.xml DBUS_SESSION_BUS_ADDRESS=unix:path=$L/none RIBBON_SHELL_TEST=tests/shell-multimonitor-scene.tcl \
		timeout -k 5 90 wish8.6 -encoding utf-8 "$D/shell/main.tcl" -name ribbon-shell >"$L/scene" 2>&1 &&
		grep -q 'shell multi-monitor scene: all checks passed' "$L/scene"; then
		sed -n "s/^  ok   /  ok   multi-monitor (labwc): /p" "$L/scene"
	else
		sed 's/^/       /' "$L/scene"; echo "  FAIL the multi-monitor scene under labwc (tests/shell-multimonitor-scene.tcl)"; r=1
	fi
	echo "main HEADLESS-2" >"$L/cfg/ribbon/display.conf"
	wlr-randr --output HEADLESS-1 --custom-mode 1440x900 --pos 0,0 >/dev/null 2>&1
	wlr-randr --output HEADLESS-2 --custom-mode 1280x720 --pos 1440,0 >/dev/null 2>&1
	# the shell, as labwc's autostart starts it (LABWC_PID set): it writes the margin layer and has labwc read it
	DBUS_SESSION_BUS_ADDRESS=unix:path=$L/none RIBBON_SHELL_TEST=$PWD/tests/shell-scene.tcl RIBBON_SCENE=idle \
		timeout 100 wish8.6 -encoding utf-8 "$D/shell/main.tcl" -name ribbon-shell >"$L/shell.out" 2>&1 &
	spid=$!
	# a maximised X window on each output: {x y w h} each, one line per output
	cat >"$L/max.tcl" <<'EOF'
foreach {n x} {a 100 b 1600} { toplevel .$n; wm geometry .$n 300x200+$x+300 }
wm withdraw .
after 600 { foreach n {a b} { wm attributes .$n -zoomed 1 } }
after 1500 { foreach n {a b} { puts "[winfo rootx .$n] [winfo rooty .$n] [winfo width .$n] [winfo height .$n]" }; exit }
EOF
	# wait (up to 15 s) until a maximised window keeps 54 px top and bottom on output $1 (its x, width, height) and
	# none on the other (x, width, height); labwc's title bar is above a window's X top
	margins() {
		i=0
		while [ $i -lt 10 ]; do
			got=$(timeout 10 wish8.6 "$L/max.tcl" 2>/dev/null | tr '\n' ' ')
			set -- $1 $2 $3 $4 $5 $6
			echo "$got" | awk -v mx="$1" -v mw="$2" -v mh="$3" -v ox="$4" -v ow="$5" -v oh="$6" '{
				# the window on each output: the one whose x is in it
				for (k = 1; k <= 8; k += 4) { if ($k >= mx && $k < mx + mw) m = k; if ($k >= ox && $k < ox + ow) o = k }
				if (!m || !o) exit 1
				mb = $(m + 1) + $(m + 3); ob = $(o + 1) + $(o + 3)
				exit !($(m + 1) >= 54 && $(m + 1) < 100 && mb == mh - 54 && $(o + 1) < 54 && ob == oh)
			}' && return 0
			sleep 0.5; i=$((i + 1))
		done
		echo "       maximised windows: $got"; return 1
	}
	if margins 1440 1280 720 0 1440 900; then echo "  ok   multi-monitor: under labwc a maximised window keeps clear of the bars on HEADLESS-2 only"
	else echo "  FAIL multi-monitor: under labwc the margin is not on HEADLESS-2 only"; r=1; fi
	grep -q 'output="HEADLESS-2"' "$L/state/ribbon/xdg-display/labwc/rc.xml" 2>/dev/null ||
		{ echo "  FAIL multi-monitor: the shell's margin layer does not name HEADLESS-2"; r=1; }
	echo "main HEADLESS-1" >"$L/cfg/ribbon/display.conf"
	printf 'display\n' >"$L/rt/ribbon-shell"
	if margins 0 1440 900 1440 1280 720; then echo "  ok   multi-monitor: after \`ribbon-shell-ctl display\` the margin moves to HEADLESS-1"
	else echo "  FAIL multi-monitor: the margin did not move to HEADLESS-1"; r=1; fi
	# ribbon-shell-switch's still, by output name
	B=$L/switch
	mkdir -p "$B"
	if pkg-config --exists wayland-client xkbcommon wayland-protocols 2>/dev/null && command -v wayland-scanner >/dev/null 2>&1 &&
		make -s -C "$D/shell-watch" O="$B" "$B/ribbon-shell-switch" >"$B/build.log" 2>&1; then
		printf 'shot %s 35 HEADLESS-2\nshot %s 0 HEADLESS-1 720\nshot %s 35 NO-SUCH-OUTPUT\nshot %s 35\n' \
			"$B/two.ppm" "$B/one.ppm" "$B/none.ppm" "$B/first.ppm" | { cat; sleep 3; } | timeout 10 "$B/ribbon-shell-switch" >"$B/out" 2>&1
		grep -q "^shot $B/two.ppm 1280 720\$" "$B/out" && grep -q "^shot $B/one.ppm 720 450\$" "$B/out" &&
			grep -q "^shot $B/none.ppm fail\$" "$B/out" && grep -q "^shot $B/first.ppm [0-9]* [0-9]*\$" "$B/out" &&
			[ "$(head -c 2 "$B/two.ppm")" = P6 ] && [ "$(sed -n 2p "$B/one.ppm")" = "720 450" ] &&
			echo "  ok   multi-monitor: Alt+Tab's helper takes the still of the output it names (HEADLESS-2 1280x720; HEADLESS-1 scaled to 720 wide; no such output: fail; none named: the first)" ||
			{ sed 's/^/       /' "$B/out"; echo "  FAIL multi-monitor: ribbon-shell-switch's still by output name"; r=1; }
	else
		echo "  skip ribbon-shell-switch's still by output name (no wayland-client / xkbcommon / wayland-protocols, or it did not build)"
	fi
	[ $r -eq 0 ] || { sed 's/^/       /' "$L/shell.out" | tail -5; }
	kill $spid $lpid 2>/dev/null
	wait $spid $lpid 2>/dev/null
	return $r
}
if command -v labwc >/dev/null 2>&1 && command -v Xwayland >/dev/null 2>&1 && command -v wlr-randr >/dev/null 2>&1 &&
	command -v wish8.6 >/dev/null 2>&1; then
	( live ) || fails=1
else
	echo "  skip the multi-monitor checks under labwc (no labwc / Xwayland / wlr-randr / wish8.6)"
fi
exit $fails
