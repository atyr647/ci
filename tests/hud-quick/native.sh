#!/bin/sh
# tests/hud-quick/native.sh - the quick menu on the real overlay helper and daemon, in a headless labwc (the host's;
# 0.7.1 in the container). Needs labwc, wish8.6, grim, ImageMagick, cairo and the wayland headers (else skips).
#   Q1 the boards: each scene (tests/hud-quick/scene.tcl) drawn by ribbon-hud-surface, put over the board's game as the
#      compositor does, compared with HUD-Quick-1-Menu, -2-Volume and -3-Quit (the card's region, blurred RMSE < 0.05)
#   Q2 Super+Esc (an rc.xml bind: ribbon-hud quick) over a fullscreen game: the menu opens, the game is dimmed, the
#      surface has the keyboard and the game gets no keys; Right steps the Overlay layout (the HUD comes up beside the
#      menu); Down and Right step the volume; Esc closes and the game has the keyboard again
#   Q3 the controller (evdev: RIBBON_HUD_INPUT holds FIFOs that carry input_event records): the home button opens and
#      B closes; a controller plugged in later is found
#   Q4 the actions: Screenshot (after the menu has gone), Back to desktop (the game is minimised), Quit game (asks;
#      the game's window is closed)
set -u
cd "$(dirname "$0")/../.." || exit 1
N=$(pwd)
D=$N/srcpkgs/ribbon-desktop/files
X=$N/tests/hud-native
FX=$N/tests/hud-fixtures/quick
for t in labwc wish8.6 grim convert compare wayland-scanner ffmpeg; do
	command -v $t >/dev/null 2>&1 || { echo "  skip HUD quick menu on the overlay (no $t)"; exit 0; }
done
pkg-config --exists wayland-client cairo wayland-protocols xkbcommon || { echo "  skip HUD quick menu on the overlay (no wayland-client / cairo / xkbcommon headers)"; exit 0; }
T=$(mktemp -d "${TMPDIR:-/tmp}/hq.XXXXXX") || exit 1
B=$T/bin
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }; note() { echo "  note $*"; }
LWPID=
cleanup() {
	[ -n "$LWPID" ] && kill "$LWPID" 2>/dev/null
	pkill -f "$T/" 2>/dev/null
	_k=0; while pgrep -f "$T/" >/dev/null 2>&1 && [ $_k -lt 40 ]; do sleep 0.05; _k=$((_k + 1)); done
	pkill -9 -f "$T/" 2>/dev/null
	[ -n "${KEEP:-}" ] && cp -r "$T" "$KEEP" 2>/dev/null
	rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$B" "$T/rt" "$T/lw" "$T/home/.config/ribbon" "$T/cache" "$T/shots" "$T/input"; chmod 700 "$T/rt"

# ---- build: the overlay helper as the template builds it, the test tools of tests/hud-native ----
make -s -C "$D/apps/hud/native" O="$B" CFLAGS="-O2 -Wall -Wextra -Werror" >"$T/build.log" 2>&1 || { cat "$T/build.log"; bad "ribbon-hud-surface does not build"; exit 1; }
XDGX=$(pkg-config --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml
wayland-scanner client-header "$XDGX" "$B/xdg-shell-client-protocol.h"; wayland-scanner private-code "$XDGX" "$B/xdg-x.c"
wayland-scanner client-header "$X/virtual-keyboard-unstable-v1.xml" "$B/virtual-keyboard-unstable-v1-client-protocol.h"; wayland-scanner private-code "$X/virtual-keyboard-unstable-v1.xml" "$B/vk.c"
# the keyboard tool with the arrow keys added
sed 's|if (!strcmp(n, "Esc")) return KEY_ESC;|if (!strcmp(n, "Esc")) return KEY_ESC;\n\tif (!strcmp(n, "Left")) return KEY_LEFT;\n\tif (!strcmp(n, "Right")) return KEY_RIGHT;\n\tif (!strcmp(n, "Up")) return KEY_UP;\n\tif (!strcmp(n, "Down")) return KEY_DOWN;|' "$X/vkeys.c" > "$B/vkeys.c"
grep -q KEY_LEFT "$B/vkeys.c" || { bad "the keyboard tool could not be given the arrow keys"; exit 1; }
WL_FLAGS=$(pkg-config --cflags --libs wayland-client); WLK_FLAGS=$(pkg-config --cflags --libs wayland-client xkbcommon)
wayland-scanner client-header "$X/wlr-virtual-pointer-unstable-v1.xml" "$B/wlr-virtual-pointer-unstable-v1-client-protocol.h"; wayland-scanner private-code "$X/wlr-virtual-pointer-unstable-v1.xml" "$B/vp.c"
cc -O2 -Wall -I"$B" -o "$B/wlgame" "$X/wlgame.c" "$B/xdg-x.c" $WL_FLAGS &&
cc -O2 -Wall -I"$B" -o "$B/vptr" "$X/vptr.c" "$B/vp.c" $WL_FLAGS &&
cc -O2 -Wall -I"$B" -o "$B/vkeys" "$B/vkeys.c" "$B/vk.c" $WLK_FLAGS || { bad "test tools do not build"; exit 1; }
WATCH=; make -s -C "$D/shell-watch" O="$B" ribbon-shell-watch CFLAGS="-O2" >"$T/watch.log" 2>&1 && WATCH=$B/ribbon-shell-watch
cp -r "$D/apps/hud" "$T/hud"; rm -rf "$T/hud/native"; mkdir -p "$T/shell" "$T/settings"
cp "$D/apps/settings/hudstore.tcl" "$D/apps/settings/games.tcl" "$T/settings/"
cp -r "$D/shell/." "$T/shell/"
cp "$D/themes/palettes/ribbon.conf" "$T/home/.config/ribbon/palette.conf"
cp "$D/apps/hud/bin/ribbon-hud" "$B/ribbon-hud"; chmod +x "$B/ribbon-hud"
sh "$N/tests/hud-quick/fakes.sh" "$T/q"
cat > "$T/fonts.conf" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <include ignore_missing="yes">/etc/fonts/fonts.conf</include>
  <include ignore_missing="yes">$D/shell/fonts.conf</include>
</fontconfig>
EOF
# the controller that is there from the start
mkfifo "$T/input/event0"

# ---- headless labwc with the two binds ----
HENV="RIBBON_HUD_DIR=$T/hud RIBBON_HUD_SURFACE=$B/ribbon-hud-surface RIBBON_HUD_LOG=$T/hud.log FONTCONFIG_FILE=$T/fonts.conf RIBBON_HUD_WATCH=$WATCH RIBBON_HUD_INPUT=$T/input RIBBON_WPCTL=$T/q/wpctl RIBBON_HDR=$T/q/ribbon-hdr RIBBON_SCREENSHOT=$T/q/ribbon-screenshot DBUS_SYSTEM_BUS_ADDRESS=unix:path=$T/no-bus RIBBON_GAMES_CONF=$T/home/.config/ribbon/game-overlay.conf"
cat > "$T/lw/rc.xml" <<EOF
<labwc_config><core><decoration>server</decoration></core>
<keyboard><default />
<keybind key="W-F12"><action name="Execute" command="$B/ribbon-hud cycle" /></keybind>
<keybind key="W-Escape"><action name="Execute" command="$B/ribbon-hud quick" /></keybind>
</keyboard></labwc_config>
EOF
echo 'echo "$DISPLAY" > "$XDG_RUNTIME_DIR/display"' > "$T/lw/autostart"
env WAYLAND_DISPLAY='' WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1 \
	XDG_RUNTIME_DIR=$T/rt HOME=$T/home XDG_CACHE_HOME=$T/cache $HENV labwc -C "$T/lw" >"$T/labwc.log" 2>&1 &
LWPID=$!
sock=; i=0
while [ -z "$sock" ] && [ $i -lt 100 ]; do
	for f in "$T"/rt/wayland-*; do case $f in *.lock) ;; *) [ -S "$f" ] && sock=${f##*/} ;; esac; done
	sleep 0.05; i=$((i + 1))
done
[ -n "$sock" ] || { tail -5 "$T/labwc.log"; bad "labwc did not start"; exit 1; }
# 1440x900 as the boards (wlr-randr through a short link: the socket path is long)
if command -v wlr-randr >/dev/null 2>&1; then
	ln -sf "$T/rt" "/tmp/hq-rt.$$"; XDG_RUNTIME_DIR=/tmp/hq-rt.$$ WAYLAND_DISPLAY=$sock wlr-randr --output HEADLESS-1 --custom-mode 1440x900 >/dev/null 2>&1; rm -f "/tmp/hq-rt.$$"
fi
i=0; while [ ! -s "$T/rt/display" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
E="DISPLAY=$(cat "$T/rt/display" 2>/dev/null) XDG_RUNTIME_DIR=$T/rt WAYLAND_DISPLAY=$sock HOME=$T/home XDG_CONFIG_HOME=$T/home/.config XDG_CACHE_HOME=$T/cache TMPDIR=$T PATH=$B:/usr/local/bin:/usr/bin:/bin $HENV QFAKE=$T/q"
poll() { _l=$(($1 * 20)); shift; _i=0; while ! "$@"; do [ $_i -ge $_l ] && return 1; sleep 0.05; _i=$((_i + 1)); done; return 0; }

# ---- Q1 the boards ----
echo "Q1 the scenes drawn by ribbon-hud-surface against the boards (the card's region, x 1096-1440, y 0-560)"
for sc in menu:1-Menu volume:2-Volume quit:3-Quit; do
	name=${sc%%:*}; board=$FX/board-${sc#*:}.png
	if ! env $E timeout 60 wish8.6 -encoding utf-8 "$N/tests/hud-quick/scene.tcl" "$name" "$T/shots/$name-surface.png" >"$T/scene-$name.log" 2>&1; then
		bad "Q1 $name: the scene did not draw: $(tail -2 "$T/scene-$name.log")"; continue
	fi
	read -r _ SW SH < "$T/scene-$name.log"
	if [ "$SW" != 1440 ] || [ "$SH" != 900 ]; then note "Q1 the output is ${SW}x$SH, not the boards' 1440x900: no comparison"; break; fi
	# the surface covers the screen (the dim): put its picture over the board's game, as the compositor does
	convert "$T/shots/$name-surface.png" -crop 360x560+1080+0 +repage "$T/shots/$name-crop.png"
	convert "$FX/game.png" "$T/shots/$name-crop.png" -composite "$T/shots/$name.png"
	convert "$T/shots/$name.png" -crop 344x560+16+0 +repage -blur 0x2 "$T/shots/$name-b.png"
	convert "$board" -crop 344x560+16+0 +repage -blur 0x2 "$T/shots/$name-board.png"
	r=$(compare -metric RMSE "$T/shots/$name-b.png" "$T/shots/$name-board.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
	if [ -n "$r" ] && awk -v r="$r" 'BEGIN { exit !(r < 0.05) }'; then ok "Q1 $name: the card matches HUD-Quick-${sc#*:} (blurred RMSE $r)"; else bad "Q1 $name: blurred RMSE ${r:-?} against HUD-Quick-${sc#*:}"; fi
	[ -n "${SHOTS:-}" ] && cp "$T/shots/$name.png" "$SHOTS/hud-quick-$name.png"
done

echo 0.64 > "$T/q/vol"   # the Volume scene left 0.70
# ---- the game and the keyboard ----
LOG=$T/hud.log; : > "$LOG"
GL=$T/game.out; : > "$GL"
env $E "$B/wlgame" bars steam_app_620 "Portal 2" >"$GL" 2>&1 &
poll 6 grep -q mapped "$GL" || bad "the game did not map"
mkfifo "$T/vk.in"; exec 8<>"$T/vk.in"
env $E "$B/vkeys" <&8 >"$T/vk.out" 2>&1 &
vk() { n=$(wc -l < "$T/vk.out"); echo "$@" >&8; i=0; while [ "$(wc -l < "$T/vk.out")" -le "$n" ] && [ $i -lt 100 ]; do sleep 0.02; i=$((i + 1)); done; }
count() { grep -c "$1" "$2" 2>/dev/null || true; }
hudstate() { n=$(count 'state ' "$LOG"); env $E "$B/ribbon-hud" state; i=0; while [ "$(count 'state ' "$LOG")" -le "$n" ] && [ $i -lt 60 ]; do sleep 0.05; i=$((i + 1)); done; grep 'state ' "$LOG" | tail -1; }
# the argument is a glob pattern (stateis '*focus=shot*'), matched as one on purpose
# shellcheck disable=SC2254
stateis() { st=$(hudstate); case $st in $1) return 0 ;; esac; return 1; }
waitstate() { poll "${2:-5}" stateis "$1"; }
lmark() { LMARK=$(wc -l < "$LOG"); }
logsince() { tail -n +$((LMARK + 1)) "$LOG"; }
waitsince() { poll "${2:-5}" sh -c "tail -n +$((LMARK + 1)) '$LOG' | grep -q '$1'"; }
gmark() { GOFF=$(wc -c < "$GL"); }
gnew() { tail -c +$((GOFF + 1)) "$GL" | tr -d '\0'; }
shot() { env $E grim "$T/shots/$1.png"; }
px() { convert "$T/shots/$1.png" -format "%[fx:int(255*p{$2,$3}.r)] %[fx:int(255*p{$2,$3}.g)] %[fx:int(255*p{$2,$3}.b)]" info:; }
# the game's picture once it is up
shot game
GPX=$(px game 100 800)
SE() { vk "down Super"; vk "tap Esc"; vk "up Super"; }

# ---- Q2 Super+Esc ----
echo "Q2 Super+Esc over the fullscreen game"
gmark; lmark
SE
waitstate '*quick={open=1*' 10 && ok "Q2 the bind opened the menu (the daemon started on the press)" || bad "Q2 not open: $st"
case $st in *"window=$"*|*"window=}"*) bad "Q2 the menu does not know the game's window: $st" ;; *window=*) ok "Q2 the menu belongs to the game's window ($(echo "$st" | sed 's/.*window=\([^}]*\)}.*/\1/'))" ;; esac
waitsince 'surface focus 1' 5 && ok "Q2 the surface has the keyboard (exclusive)" || bad "Q2 the surface never got the keyboard: $(logsince | grep surface | tail -3)"
dimmed() { shot q2; d=$(px q2 100 800); [ -n "$d" ] && [ "$d" != "$GPX" ]; }
if poll 5 dimmed; then
	exp=$(echo "$GPX" | awk '{ printf "%d %d %d", 0.65 * $1 + 0.5, 0.65 * $2 + 0.5, 0.65 * $3 + 0.5 }')
	echo "$d $exp" | awk '{ m = 0; for (i = 1; i <= 3; i++) { x = $i - $(i + 3); if (x < 0) x = -x; if (x > m) m = x } exit !(m <= 4) }' &&
		ok "Q2 the game is dimmed (35 % black: $GPX -> $d)" || bad "Q2 the dim: $GPX -> $d, expected $exp"
else bad "Q2 the game is not dimmed"; fi
vk "tap Right"
waitstate '*layout=fps*' && ok "Q2 Right on Overlay: the HUD's layout is FPS" || bad "Q2 Right: $st"
case $st in *menu=1*shown=1*) ok "Q2 the HUD is up with the menu (the menu flag moves it to 358 px)";; *) bad "Q2 the HUD with the menu: $st";; esac
vk "tap Right"; vk "tap Right"
waitstate '*layout=full*' && ok "Q2 Right twice more: Full" || bad "Q2 Full: $st"
vk "tap Down"
waitstate '*focus=vol*' && ok "Q2 Down: Volume (no Performance or HDR here: no power-profiles-daemon, a pixman session)" || bad "Q2 Down: $st"
vk "tap Right"
poll 5 grep -q '5%+' "$T/q/wpctl.calls" && ok "Q2 Right on Volume: wpctl set-volume 5%+" || bad "Q2 no volume step"
waitstate '*volume=69*' && ok "Q2 the row reads 69 % back" || bad "Q2 volume: $st"
sleep 0.2
# (Super, 125, reaches the game before the bind fires: it is the bind's modifier, pressed while the game had the keyboard)
[ -z "$(gnew | grep '^key ' | grep -v '^key 125$')" ] && ok "Q2 the game got no keys while the menu was open (Left, Right, Down, Esc went to the menu)" || bad "Q2 the game got keys: $(gnew | grep '^key ' | head -3)"
vk "tap Esc"
waitstate '*quick={open=0*' && ok "Q2 Esc closed the menu" || bad "Q2 Esc: $st"
waitsince 'surface focus 0' 5 && ok "Q2 the surface gave the keyboard back" || bad "Q2 the keyboard was not given back"
gmark; vk "tap a"
poll 3 sh -c "tail -c +$((GOFF + 1)) '$GL' | tr -d '\\0' | grep -qi key" && ok "Q2 the game has the keyboard again" || bad "Q2 the game gets no keys after the menu closed"

# ---- Q3 the controller ----
echo "Q3 the controller's buttons (evdev records through FIFOs)"
# one input_event (timeval 16 bytes, type, code, value) and a SYN_REPORT; CODE in octal bytes (low high)
zeros() { _z=0; while [ $_z -lt "$1" ]; do printf '\000'; _z=$((_z + 1)); done; }
# the record is made in a file and written in one go (a FIFO gives a reader what is there: evdev gives whole events)
press() { { zeros 16; printf '\001\000'; printf "$2"; printf '\001\000\000\000'; zeros 24; } > "$T/ev.bin"; cat "$T/ev.bin" > "$T/input/$1"; }
HOME_B='\074\001'; A_B='\060\001'; B_B='\061\001'; DOWN_B='\041\002'
press event0 "$HOME_B"
waitstate '*quick={open=1*' && ok "Q3 the home button opened the menu" || bad "Q3 home: $st"
press event0 "$B_B"
waitstate '*quick={open=0*' && ok "Q3 B closed it" || bad "Q3 B: $st"
mkfifo "$T/input/event7"
sleep 0.2
press event7 "$HOME_B"
waitstate '*quick={open=1*' && ok "Q3 a controller plugged in later (event7) is found: its home button opens the menu" || bad "Q3 hotplug: $st"
press event7 "$B_B"; waitstate '*quick={open=0*' || bad "Q3 B on event7: $st"

# ---- Q4 the actions ----
echo "Q4 Screenshot, Back to desktop, Quit game"
SE; waitstate '*quick={open=1*' || bad "Q4 open: $st"
k=0; until stateis '*focus=shot*' || [ $k -ge 8 ]; do vk "tap Down"; k=$((k + 1)); done
lmark; vk "tap Return"
poll 5 test -e "$T/q/shot.done" && ok "Q4 Screenshot: ribbon-screenshot ran" || bad "Q4 no screenshot"
logsince | awk '/quick close/ { c = NR } /quick run / { r = NR } END { exit !(c && r && c < r) }' && ok "Q4 it ran after the menu had closed and the surface had redrawn" || bad "Q4 order: $(logsince | grep quick | tail -4)"
if [ -n "$WATCH" ]; then
	press event0 "$HOME_B"; waitstate '*quick={open=1*' || bad "Q4 open: $st"
	k=0; until stateis '*focus=desk*' || [ $k -ge 8 ]; do press event0 "$DOWN_B"; k=$((k + 1)); done
	lmark; press event0 "$A_B"
	waitsince 'front id= ' 5 && ok "Q4 Back to desktop: the game's window was minimised (nothing in front)" || bad "Q4 desktop: $(logsince | tail -3)"
	# the second game, in front, quit through the question
	env $E "$B/wlgame" 203040 steam_app_1245620 "Elden" >"$T/game2.out" 2>&1 &
	poll 6 grep -q mapped "$T/game2.out" || bad "Q4 the second game did not map"
	lmark; waitsince 'front .*app=steam_app_1245620' 5
	SE; waitstate '*quick={open=1*' || bad "Q4 open over the second game: $st"
	k=0; until stateis '*focus=quit*' || [ $k -ge 8 ]; do vk "tap Down"; k=$((k + 1)); done
	vk "tap Return"
	waitstate '*ask=cancel*' && ok "Q4 Quit game asks first (Cancel in focus)" || bad "Q4 no question: $st"
	vk "tap Up"; vk "tap Return"
	gone() { ! pgrep -f "$B/wlgame 203040" >/dev/null 2>&1; }
	poll 5 gone && ok "Q4 Quit game: the game's window was closed (the game left)" || bad "Q4 the second game is still running"
	waitstate '*quick={open=0*' || bad "Q4 the menu is still open: $st"
else
	note "Q4 Back to desktop and Quit game not checked: ribbon-shell-watch does not build here"
fi
# ---- Q5 only over a game, Steam's Guide, the mouse, a held key ----
echo "Q5 only over a game; the home button while Steam runs; clicks; key repeat"
if [ -n "$WATCH" ]; then
	# nothing in front now (the first game minimised, the second quit)
	lmark; SE
	waitsince 'quick ignored: no game in front' 5 && stateis '*quick={open=0*' && ok "Q5 Super+Esc on the desktop opens nothing" || bad "Q5 Super+Esc on the desktop: $(logsince | grep quick | tail -2) $st"
	lmark; press event0 "$HOME_B"
	waitsince 'quick ignored: no game in front' 5 && stateis '*quick={open=0*' && ok "Q5 nor does the home button" || bad "Q5 home on the desktop: $st"
	lmark
	env $E "$B/wlgame" bars steam_app_620 "Portal 2" >"$T/game3.out" 2>&1 &
	poll 6 grep -q mapped "$T/game3.out" || bad "Q5 the game did not map"
	waitsince 'front .*game=1' 5 || bad "Q5 the game is not in front: $(logsince | tail -2)"
	# a Steam client: its Guide opens Steam's overlay, so the home button is left to it
	cp /bin/sleep "$B/steam"; "$B/steam" 60 & STEAM=$!
	lmark; press event0 "$HOME_B"
	waitsince 'home left to Steam' 5 && stateis '*quick={open=0*' && ok "Q5 Steam runs: the home button opens Steam's overlay only, not ours too" || bad "Q5 home with Steam: $st"
	SE; waitstate '*quick={open=1*' && ok "Q5 Super+Esc still opens ours while Steam runs" || bad "Q5 Super+Esc with Steam: $st"
	kill $STEAM 2>/dev/null
	poll 3 grep -q ' surface repeat [0-9]' "$LOG" && ok "Q5 the surface has the compositor's key repeat ($(grep -m1 ' surface repeat' "$LOG" | cut -d' ' -f4-))" || bad "Q5 no repeat info from the surface"
	# a held Down (labwc: 25 a second after 600 ms) walks the rows to the last
	vk "down Down"; sleep 1.2; vk "up Down"
	waitstate '*focus=quit*' && ok "Q5 a held Down repeats down to Quit game" || bad "Q5 key repeat: $st"
	sleep 0.3; stateis '*focus=quit*' || bad "Q5 it went on after the key was let go: $st"
	vk "tap Up"; waitstate '*focus=desk*' && ok "Q5 a tap is one step" || bad "Q5 tap: $st"
	# the mouse, through the compositor: the card is at 1098,12; Volume's row at 158 (no Performance or HDR here)
	mkfifo "$T/vp.in"; exec 9<>"$T/vp.in"; : > "$T/vp.out"
	env $E "$B/vptr" <&9 >"$T/vp.out" 2>&1 &
	vp() { n=$(wc -l < "$T/vp.out"); echo "$@" >&9; i=0; while [ "$(wc -l < "$T/vp.out")" -le "$n" ] && [ $i -lt 100 ]; do sleep 0.02; i=$((i + 1)); done; }
	vp size 1440 900
	ups=$(grep -c '5%+' "$T/q/wpctl.calls")
	upmore() { [ "$(grep -c '5%+' "$T/q/wpctl.calls")" -gt "$ups" ]; }
	lmark; vp move 1398 193; vp click
	poll 5 upmore && ok "Q5 a click on Volume's right half: up 5 %" || bad "Q5 click on Volume: $(tail -1 "$T/q/wpctl.calls") / $(logsince | grep -v 'state\|mapped' | tail -4)"
	waitstate '*focus=vol*' || bad "Q5 the clicked row has no focus: $st"
	vp move 400 500; vp click
	waitstate '*quick={open=0*' && ok "Q5 a click on the game closes the menu" || bad "Q5 click off the card: $st"
	vp click
	sleep 0.3; stateis '*quick={open=0*' && ok "Q5 with the menu closed a click opens nothing" || bad "Q5 after: $st"
	exec 9>&-
else
	note "Q5 not checked: ribbon-shell-watch does not build here"
fi
env $E "$B/ribbon-hud" quit
exit $fail
