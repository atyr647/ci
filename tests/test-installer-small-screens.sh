#!/bin/sh
# The installer on small screens (W2; the Inst-C* boards, design/tools/gen_installer_compact.py): under 828 px high
# the 1100 x 720 window would run under the dock, so it is the compact 1100 x 640 one, centred between the bars.
#   1. tests/installer-small.tcl under xvfb at 1366x768, 1280x800 and 1440x900: the window's size and place, every
#      page clear of its footer, Hardware's drivers list scrolling on a machine with fourteen devices;
#   2. pages drawn at 1366x768 (Welcome at 1280x800) against the Inst-C* boards' crops in
#      tests/fixtures/installer-small (blurred RMSE < 0.05);
#   3. the real installer (the fake backend) under headless labwc with Ribbon's rc.xml and the real shell (its bars
#      and dock), at 1366x768 and 1280x800: labwc puts the window where it asks, between the bars and the dock, its
#      Continue button is on screen, and what grim captures of the window matches the Welcome board;
#   4. under labwc at 1280x720 (clear of the top bars), 1024x768 (a 1024 wide window showing the page, Continue on
#      screen, the rail's left cut) and on two
#      outputs side by side (on the main one, not across both).
# Needs wish8.6 and xvfb-run (1, 2), ImageMagick (2, 3), labwc, Xwayland, grim, wlr-randr and xwininfo (3).
set -u
cd "$(dirname "$0")/.." || exit 1
fails=0
ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fails=$((fails + 1)); }
T=$(mktemp -d); PIDS=
trap 'kill $PIDS 2>/dev/null; sleep 0.2; rm -rf "$T"' EXIT
MAIN=$PWD/srcpkgs/ribbon-installer/files/tk/main.tcl
mkdir -p "$T/home" "$T/cache"
for t in wish8.6 xvfb-run; do command -v $t >/dev/null 2>&1 || { echo "  skip the installer on small screens (no $t)"; exit 0; }; done
xwish() { # screen size, then env assignments
	sz=$1; shift
	env HOME="$T/home" XDG_CACHE_HOME="$T/cache" XDG_RUNTIME_DIR="$T" "$@" \
		timeout -k 5 120 xvfb-run -a -s "-screen 0 ${sz}x24" wish8.6 -encoding utf-8 "$MAIN"
}

# 1. geometry and fit
for sz in 1366x768 1280x800 1440x900; do
	if out=$(xwish $sz RIBBON_INSTALLER_SCENE=tests/installer-small.tcl 2>&1); then
		ok "$sz: $(printf '%s\n' "$out" | grep -c '  ok ') checks (window, pages clear of the footer, Hardware scrolls)"
	else
		printf '%s\n' "$out" | grep -v '^  ok '; bad "$sz: the installer does not fit"
	fi
done

# 2. against the boards
rmse() { # shot, crop, fixture
	convert "$1" -crop "$2" +repage -blur 0x2 "$T/a.png"
	convert "$3" -blur 0x2 "$T/b.png"
	compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p'
}
if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1 && command -v import >/dev/null 2>&1; then
	for p in welcome:1280x800:1100x640+90+80:welcome-1280 keyboard:1366x768:1100x640+133+64:keyboard \
		hardware:1366x768:1100x640+133+64:hardware you:1366x768:1100x640+133+64:you \
		summary:1366x768:1100x640+133+64:summary progress:1366x768:1100x640+133+64:progress done:1366x768:1100x640+133+64:done; do
		IFS=: read -r scene sz crop fx <<EOF
$p
EOF
		rm -f "$T/shot.png"
		xwish $sz RIBBON_INSTALLER_SCENE=tests/installer-scene.tcl RIBBON_SCENE=$scene RIBBON_INSTALLER_SHOT="$T/shot.png" >/dev/null 2>&1
		if [ -s "$T/shot.png" ]; then
			r=$(rmse "$T/shot.png" $crop tests/fixtures/installer-small/$fx.png)
			if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then ok "$scene at $sz matches its Inst-C board (blurred RMSE $r)"
			else bad "$scene at $sz against its Inst-C board: RMSE ${r:-?}"; fi
		else
			bad "no screenshot of $scene at $sz"
		fi
	done
else
	echo "  skip the pages against the Inst-C boards (no ImageMagick)"
fi

# 3. under labwc, with the shell's bars and dock
for t in labwc Xwayland grim wlr-randr xwininfo convert; do
	command -v $t >/dev/null 2>&1 || { echo "  skip the installer under a compositor (no $t)"; [ $fails -eq 0 ] && echo "installer on small screens: all checks passed"; exit $fails; }
done
F=$PWD/srcpkgs/ribbon-desktop/files
if [ -z "${RBNALPHA_LIB:-}" ] || [ ! -f "$RBNALPHA_LIB" ]; then
	mkdir -p "$T/rbn"
	if make -s -C "$F/rbnalpha" O="$T/rbn" >/dev/null 2>&1; then RBNALPHA_LIB=$T/rbn/librbnalpha.so; export RBNALPHA_LIB; fi
fi
# the shell learns the windows (and so draws the dock) from ribbon-shell-watch
mkdir -p "$T/sw"
make -s -C "$F/shell-watch" O="$T/sw" >"$T/sw.log" 2>&1 || echo "  note ribbon-shell-watch does not build here: the shell runs without its dock"
compositor() { # WxH
	W=${1%x*}; H=${1#*x}
	R=$T/c$1; mkdir -p "$R/rt" "$R/h/.config/ribbon" "$R/c" "$R/s" "$R/labwc"; chmod 700 "$R/rt"
	cp "$F/themes/palettes/ribbon.conf" "$R/h/.config/ribbon/palette.conf"
	# Ribbon's own rc.xml: the 54 px margins and the installer's window rule
	cp "$F/xdg/labwc/rc.xml" "$R/labwc/rc.xml"
	echo "echo \"\$DISPLAY\" > $R/display" > "$R/labwc/autostart"
	(
	export XDG_RUNTIME_DIR=$R/rt HOME=$R/h XDG_CACHE_HOME=$R/c XDG_STATE_HOME=$R/s XDG_CONFIG_HOME=$R/h/.config
	unset WAYLAND_DISPLAY DISPLAY; export DBUS_SESSION_BUS_ADDRESS=unix:path=$R/none
	WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1 timeout -k 5 90 labwc -C "$R/labwc" >"$R/labwc.log" 2>&1 &
	echo $! > "$R/pids"
	i=0; while [ ! -s "$R/display" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
	[ -s "$R/display" ] || { echo "  skip the installer under a compositor at $1 (labwc does not start headless here)"; exit 0; }
	DISPLAY=$(cat "$R/display"); WAYLAND_DISPLAY=; for s in "$R"/rt/wayland-[0-9]*; do case ${s##*/} in *.lock) ;; *) WAYLAND_DISPLAY=${s##*/}; break ;; esac; done
	export DISPLAY WAYLAND_DISPLAY
	wlr-randr --output HEADLESS-1 --custom-mode "$1" >/dev/null 2>&1
	# the output has its size once the X screen has it
	i=0; while [ "$(xwininfo -root 2>/dev/null | sed -n 's/.*-geometry \([0-9]*x[0-9]*\).*/\1/p')" != "$1" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
	PATH=$T/sw:$PATH timeout -k 5 60 wish8.6 -encoding utf-8 "$F/shell/main.tcl" -name ribbon-shell >"$R/shell.out" 2>&1 &
	echo $! >> "$R/pids"
	sleep 1
	RIBBON_INSTALLER_FAKE=$PWD/tests/installer-fake-backend.sh timeout -k 5 60 wish8.6 -encoding utf-8 "$MAIN" >"$R/installer.out" 2>&1 &
	echo $! >> "$R/pids"
	# the window, once labwc has mapped it, and then its Continue button drawn (accent, at its place)
	geo=; i=0
	while [ $i -lt 100 ]; do
		info=$(xwininfo -name "Install Ribbon" 2>/dev/null)
		if printf '%s\n' "$info" | grep -q 'Map State: IsViewable'; then
			geo=$(printf '%s\n' "$info" | awk '/Absolute upper-left X/ {x=$NF} /Absolute upper-left Y/ {y=$NF} /Width:/ {w=$NF} /Height:/ {h=$NF} END {print x, y, w, h}')
			set -- $geo
			grim "$R/shot.png" 2>/dev/null
			c=$(convert "$R/shot.png" -crop 1x1+$(($1 + 1052))+$(($2 + 608)) +repage -format '%[fx:int(255*u.r)] %[fx:int(255*u.g)]' info: 2>/dev/null)
			case $c in 2[0-9][0-9]\ 1[0-3][0-9]) break ;; esac
		fi
		sleep 0.2; i=$((i + 1))
	done
	echo "$geo" > "$R/geo"
	)
	PIDS="$PIDS $(cat "$R/pids" 2>/dev/null)"
	[ -s "$R/display" ] || return 0
	geo=$(cat "$R/geo")
	if [ -z "$geo" ]; then bad "$1: the installer's window never showed"; sed 's/^/       /' "$R/installer.out"; return; fi
	set -- $geo
	x=$1; y=$2; w=$3; h=$4
	[ "$w" = 1100 ] && [ "$h" = 640 ] && ok "${W}x$H: labwc shows the compact window, ${w}x$h" || bad "${W}x$H: the window is ${w}x$h, not the compact 1100x640"
	[ "$y" -ge 54 ] && [ $((y + h)) -le $((H - 54)) ] && ok "${W}x$H: it lies between the top bars and the dock: $y to $((y + h))" \
		|| bad "${W}x$H: the window spans $y to $((y + h)); the bars and the dock keep 54 px at each edge"
	[ "$x" = $(((W - 1100) / 2)) ] && [ "$y" = $(((H - 640) / 2)) ] && ok "${W}x$H: labwc keeps it where it asks, at $x, $y" || bad "${W}x$H: labwc put it at $x, $y"
	c=$(convert "$R/shot.png" -crop 1x1+$((x + 1052))+$((y + 608)) +repage -format '%[fx:int(255*u.r)] %[fx:int(255*u.g)]' info: 2>/dev/null)
	case $c in 2[0-9][0-9]\ 1[0-3][0-9]) ok "${W}x$H: Continue is on screen (the accent at its place)" ;; *) bad "${W}x$H: no Continue button where the footer is (pixel $c)" ;; esac
	# the shell's dock under it: its bar is drawn at the screen's foot, clear of the window
	d=$(convert "$R/shot.png" -crop 300x38+$(((W - 300) / 2))+$((H - 46)) +repage -format '%[fx:int(255*standard_deviation*10)]' info: 2>/dev/null)
	[ "${d:-0}" -ge 1 ] && ok "${W}x$H: the dock is at the screen's foot, below the window" || bad "${W}x$H: no dock below the window"
	# the window against the Welcome board (the 1280 board; at 1366 the window is the same)
	convert "$R/shot.png" -crop 1100x640+$x+$y +repage "$R/win.png"
	r=$(rmse "$R/win.png" 1100x640+0+0 tests/fixtures/installer-small/welcome-1280.png)
	if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then ok "${W}x$H: under labwc the window matches the Inst-C1 board (blurred RMSE $r)"
	else bad "${W}x$H: under labwc the window against the Inst-C1 board: RMSE ${r:-?}"; fi
	[ -n "${SMALL_KEEP:-}" ] && cp "$R/shot.png" "$SMALL_KEEP/labwc-${W}x$H.png"
	xargs kill < "$R/pids" 2>/dev/null; sleep 0.3
}
compositor 1366x768
compositor 1280x800

# 4. where labwc puts it on a short screen, a narrow one, and the main one of two outputs side by side
#    placed "OUTPUT[,OUTPUT2]" X Y W H: OUTPUTs are WxH, the second right of the first
placed() {
	spec=$1; ex=$2; ey=$3; ew=$4; eh=$5
	o1=${spec%%,*}; o2=; case $spec in *,*) o2=${spec#*,} ;; esac
	W=${o1%x*}; H=${o1#*x}
	R=$T/p$(printf '%s' "$spec" | tr ',x' '__'); mkdir -p "$R/rt" "$R/h/.config/ribbon" "$R/c" "$R/s" "$R/labwc"; chmod 700 "$R/rt"
	cp "$F/themes/palettes/ribbon.conf" "$R/h/.config/ribbon/palette.conf"
	cp "$F/xdg/labwc/rc.xml" "$R/labwc/rc.xml"
	echo "echo \"\$DISPLAY\" > $R/display" > "$R/labwc/autostart"
	(
	export XDG_RUNTIME_DIR=$R/rt HOME=$R/h XDG_CACHE_HOME=$R/c XDG_STATE_HOME=$R/s XDG_CONFIG_HOME=$R/h/.config
	unset WAYLAND_DISPLAY DISPLAY; export DBUS_SESSION_BUS_ADDRESS=unix:path=$R/none
	WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=$([ -n "$o2" ] && echo 2 || echo 1) timeout -k 5 90 labwc -C "$R/labwc" >"$R/labwc.log" 2>&1 &
	echo $! > "$R/pids"
	i=0; while [ ! -s "$R/display" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
	[ -s "$R/display" ] || { echo "  skip the installer under a compositor at $spec (labwc does not start headless here)"; exit 0; }
	DISPLAY=$(cat "$R/display"); WAYLAND_DISPLAY=; for s in "$R"/rt/wayland-[0-9]*; do case ${s##*/} in *.lock) ;; *) WAYLAND_DISPLAY=${s##*/}; break ;; esac; done
	export DISPLAY WAYLAND_DISPLAY
	wlr-randr --output HEADLESS-1 --custom-mode "$o1" --pos 0,0 >/dev/null 2>&1
	want=$o1
	if [ -n "$o2" ]; then
		wlr-randr --output HEADLESS-2 --custom-mode "$o2" --pos "$W,0" >/dev/null 2>&1
		want=$((W + ${o2%x*}))x$((H > ${o2#*x} ? H : ${o2#*x}))
	fi
	i=0; while [ "$(xwininfo -root 2>/dev/null | sed -n 's/.*-geometry \([0-9]*x[0-9]*\).*/\1/p')" != "$want" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
	RIBBON_INSTALLER_FAKE=$PWD/tests/installer-fake-backend.sh timeout -k 5 60 wish8.6 -encoding utf-8 "$MAIN" >"$R/installer.out" 2>&1 &
	echo $! >> "$R/pids"
	geo=; i=0
	while [ $i -lt 100 ]; do
		info=$(xwininfo -name "Install Ribbon" 2>/dev/null)
		if printf '%s\n' "$info" | grep -q 'Map State: IsViewable'; then
			geo=$(printf '%s\n' "$info" | awk '/Absolute upper-left X/ {x=$NF} /Absolute upper-left Y/ {y=$NF} /Width:/ {w=$NF} /Height:/ {h=$NF} END {print x, y, w, h}')
			set -- $geo
			grim "$R/shot.png" 2>/dev/null
			c=$(convert "$R/shot.png" -crop 1x1+$(($1 + $3 - 48))+$(($2 + $4 - 32)) +repage -format '%[fx:int(255*u.r)] %[fx:int(255*u.g)]' info: 2>/dev/null)
			case $c in 2[0-9][0-9]\ 1[0-3][0-9]) break ;; esac
		fi
		sleep 0.2; i=$((i + 1))
	done
	echo "$geo" > "$R/geo"; echo "$c" > "$R/cont"
	)
	PIDS="$PIDS $(cat "$R/pids" 2>/dev/null)"
	[ -s "$R/display" ] || return 0
	geo=$(cat "$R/geo")
	if [ -z "$geo" ]; then bad "$spec: the installer's window never showed"; sed 's/^/       /' "$R/installer.out"; xargs kill < "$R/pids" 2>/dev/null; return; fi
	set -- $geo
	if [ "$1 $2 $3 $4" = "$ex $ey $ew $eh" ]; then ok "$spec: labwc shows the ${3}x$4 window at $1, $2"
	else bad "$spec: the window is ${3}x$4 at $1, $2, not ${ew}x$eh at $ex, $ey"; fi
	[ "$2" -ge 54 ] && ok "$spec: clear of the top bars" || bad "$spec: the window's top ($2) is under the top bars"
	case $(cat "$R/cont") in 2[0-9][0-9]\ 1[0-3][0-9]) ok "$spec: Continue is on screen" ;; *) bad "$spec: no Continue button where the footer is" ;; esac
	xargs kill < "$R/pids" 2>/dev/null; sleep 0.3
}
placed 1280x720 90 54 1100 640
placed 1024x768 0 64 1024 640
placed 1920x1080,1366x768 410 194 1100 720

[ $fails -eq 0 ] && echo "installer on small screens: all checks passed"
exit $fails
