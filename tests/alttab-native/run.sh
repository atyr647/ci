#!/bin/sh
# run.sh [ROOT] - the Alt+Tab switcher's native half (U19) in a headless labwc: the real shell with the real
# ribbon-shell-watch and ribbon-shell-switch, app windows on XWayland, a layer-shell bar, a fullscreen
# Wayland "game", and a virtual keyboard that types Alt+Tab through Wayland. Checks what was measured:
# stacking above the shell's bar and dock and above a fullscreen game, exclusive keyboard, Alt release
# activating, the 150 ms tap, W and Q, the blurred still, and window capture where labwc offers it.
# ROOT: a test root of prebuilt packages with labwc 0.8 or later (0.20.3 has ext-image-copy-capture; CI: build/ci/labwc020.sh);
# without it, the host's labwc.
# SHOTS=dir: keep the screenshots there.
set -u
cd "$(dirname "$0")/../.." || exit 1
N=$(pwd); ROOT=${1:-}
D=$N/srcpkgs/ribbon-desktop/files
T0=${TMPDIR:-/tmp}/alttab.$$; T=$T0; B=$T0/bin
if [ -n "$ROOT" ]; then T0=$ROOT/tmp/alttab.$$; T=/tmp/alttab.$$; B=$T/bin; fi
R() { if [ -n "$ROOT" ]; then chroot "$ROOT" "$@"; else "$@"; fi; }
mkdir -p "$T0/bin" "$T0/rt" "$T0/lw" "$T0/home/.config/ribbon" "$T0/cache" "$T0/state" "$T0/shell"; chmod 700 "$T0/rt"
S=$T0/bin
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }; note() { echo "  note $*"; }
# signal our background jobs (reap TERM|KILL). jobs -p must run in this shell, not in $(...): dash's subshell has no job table
reap() { _rf=$(mktemp) || return 0; jobs -p >"$_rf"; while read -r _rp; do kill -"$1" "$_rp" 2>/dev/null; done <"$_rf"; rm -f "$_rf"; }
cleanup() { [ -n "${KEEPLOG:-}" ] && cp "$T0/alttab.log" "$KEEPLOG" 2>/dev/null; [ -n "${KEEPLOG:-}" ] && cp "$T0/labwc.log" "$KEEPLOG.labwc" 2>/dev/null; reap TERM; pkill -f "alttab\.$$/" 2>/dev/null; sleep 0.5; reap KILL; pkill -9 -f "alttab\.$$/" 2>/dev/null
	if [ -n "$ROOT" ]; then umount "$ROOT/proc" "$ROOT/dev/shm" 2>/dev/null; [ -n "${BOUND:-}" ] && umount "$ROOT/dev" 2>/dev/null; fi
	[ -n "${SHOTS:-}" ] && [ -d "$T0/shots" ] && cp "$T0"/shots/*.png "$SHOTS"/ 2>/dev/null
	[ -n "${KEEPOUT:-}" ] && cp "$T0/shell.out" "$KEEPOUT" 2>/dev/null; rm -rf "$T0"; }
trap cleanup EXIT
for t in labwc wish8.6 grim convert wayland-scanner; do
	if [ -z "$ROOT" ] && ! command -v $t >/dev/null 2>&1; then echo "  skip alttab native (no $t)"; exit 0; fi
done
mkdir -p "$T0/shots"
# labwc 0.7.1 (the container's) reports neither the keys held nor the modifiers when a surface gets the keyboard, so
# a virtual-keyboard test cannot tell a held Alt from a released one (the test root's 0.20.3 does). Run with ROOT.
LV=$(R labwc -v 2>/dev/null | sed -n 's/^labwc \([0-9]*\.[0-9]*\).*/\1/p')
[ -n "${PROFILE:-}" ] && LV=profile   # PROFILE=n: time n opens (any labwc; the checks are skipped), see the PROFILE block
case $LV in 0.[0-7]) echo "  skip alttab native: labwc $LV here; run with a test root (labwc 0.8 or later; CI: build/ci/labwc020.sh): tests/alttab-native/run.sh ROOT"; exit 0;; esac

# ---- build (host toolchain; the programs run in the root against its libraries) ----
make -s -C "$D/shell-watch" O="$S" CFLAGS="-O2 -Wall -Wextra -Werror" >"$T0/build.log" 2>&1 || { cat "$T0/build.log"; bad "shell-watch does not build"; exit 1; }
ok "ribbon-shell-watch and ribbon-shell-switch build with -Wall -Wextra -Werror ($(wc -c < "$S/ribbon-shell-switch") bytes)"
X=$N/tests/alttab-native
XDG=$(pkg-config --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml
LAYER=$D/ribbon-wall/wlr-layer-shell-unstable-v1.xml
wayland-scanner client-header "$X/virtual-keyboard-unstable-v1.xml" "$S/virtual-keyboard-unstable-v1-client-protocol.h"
wayland-scanner private-code "$X/virtual-keyboard-unstable-v1.xml" "$S/vk.c"
wayland-scanner client-header "$LAYER" "$S/wlr-layer-shell-unstable-v1-client-protocol.h"; wayland-scanner private-code "$LAYER" "$S/ls.c"
wayland-scanner client-header "$XDG" "$S/xdg-shell-client-protocol.h"; wayland-scanner private-code "$XDG" "$S/xdg.c"
# pkg-config's flags are a list of words: the variables are split into them on purpose
WLK_FLAGS=$(pkg-config --cflags --libs wayland-client xkbcommon)
WL_FLAGS=$(pkg-config --cflags --libs wayland-client)
cc -O2 -Wall -Wextra -Werror -I"$S" -o "$S/altkeys" "$X/altkeys.c" "$S/vk.c" $WLK_FLAGS &&
cc -O2 -Wall -Wextra -Werror -I"$S" -o "$S/wlclient" "$X/wlclient.c" "$S/ls.c" "$S/xdg.c" $WL_FLAGS || { bad "test tools do not build"; exit 1; }
# the C half of rbnalpha, when Tk's headers are here (blur is the slow part without it)
make -s -C "$D/rbnalpha" O="$S" >/dev/null 2>&1 && { mkdir -p "$T0/shell-ext/rbnalpha"; cp "$D"/rbnalpha/pkgIndex.tcl "$D"/rbnalpha/rbnalpha.tcl "$S/librbnalpha.so" "$T0/shell-ext/rbnalpha/"; }
cp -r "$D/shell/." "$T0/shell/"; cp -r "$D/rbnalpha" "$T0/rbnalpha"; [ -f "$S/librbnalpha.so" ] && cp "$S/librbnalpha.so" "$T0/rbnalpha/"
cp "$D/themes/palettes/ribbon.conf" "$T0/home/.config/ribbon/palette.conf"
cp "$D/bin/ribbon-shell-ctl" "$S/"; cp "$X/appwin.tcl" "$X/hook.tcl" "$S/"

# ---- headless labwc, with the binds the integration request asks for ----
cat > "$T0/lw/rc.xml" <<EOF
<labwc_config><core><decoration>server</decoration></core>
<keyboard><default />
<keybind key="A-Tab"><action name="Execute" command="$B/ribbon-shell-ctl switcher next" /></keybind>
<keybind key="A-S-Tab"><action name="Execute" command="$B/ribbon-shell-ctl switcher prev" /></keybind>
<keybind key="A-grave"><action name="Execute" command="$B/ribbon-shell-ctl switcher app" /></keybind>
</keyboard></labwc_config>
EOF
echo 'echo "$DISPLAY" > "$XDG_RUNTIME_DIR/display"' > "$T0/lw/autostart"
# labwc needs /dev/urandom (ext-foreign-toplevel identifiers) and /dev/shm
[ -n "$ROOT" ] && { mkdir -p "$ROOT/proc" "$ROOT/dev/shm"; mount -t proc proc "$ROOT/proc" 2>/dev/null
	if [ ! -e "$ROOT/dev/urandom" ]; then mount --bind /dev "$ROOT/dev" 2>/dev/null && BOUND=1; else mount -t tmpfs tmpfs "$ROOT/dev/shm" 2>/dev/null; fi; }
R env WAYLAND_DISPLAY='' WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1 \
	XDG_RUNTIME_DIR=$T/rt HOME=$T/home labwc -C "$T/lw" >"$T0/labwc.log" 2>&1 &
i=0; while [ ! -s "$T0/rt/display" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
sock=; for f in "$T0"/rt/wayland-*; do case $f in *.lock) ;; *) [ -S "$f" ] && sock=${f##*/} ;; esac; done
[ -n "$sock" ] || { cat "$T0/labwc.log"; echo "no labwc"; exit 1; }
DISP=$(cat "$T0/rt/display")
echo "compositor: $(R labwc -v | head -1), socket $sock, X display $DISP"
# REVIEW: the boards are 1440x900 (the socket path is too long for wlr-randr from here, hence the short link)
if [ -n "${REVIEW:-}" ] && command -v wlr-randr >/dev/null 2>&1; then
	ln -sf "$T0/rt" "/tmp/alttab-rt.$$"; XDG_RUNTIME_DIR=/tmp/alttab-rt.$$ WAYLAND_DISPLAY=$sock wlr-randr --output HEADLESS-1 --custom-mode 1440x900 >/dev/null 2>&1; rm -f "/tmp/alttab-rt.$$"
fi
E="XDG_RUNTIME_DIR=$T/rt WAYLAND_DISPLAY=$sock DISPLAY=$DISP HOME=$T/home XDG_CONFIG_HOME=$T/home/.config XDG_CACHE_HOME=$T/cache XDG_STATE_HOME=$T/state PATH=$B:/usr/local/bin:/usr/bin:/bin"
LOG=$T0/alttab.log; : > "$LOG"
mkfifo "$T0/ak"; R env $E $B/altkeys <"$T0/ak" >"$T0/ak.out" 2>&1 &
exec 9>"$T0/ak"
key() { echo "$@" >&9; n=$(wc -l < "$T0/ak.out"); i=0; while [ "$(wc -l < "$T0/ak.out")" -le "$n" ] && [ $i -lt 100 ]; do sleep 0.02; i=$((i + 1)); done; }
shot() { R env $E grim "$T/shots/$1.png"; }
px() { convert "$T0/shots/$1.png" -format "%[fx:int(255*p{$2,$3}.r)] %[fx:int(255*p{$2,$3}.g)] %[fx:int(255*p{$2,$3}.b)]" info:; }
near() { echo "$1 $2" | awk '{ d = 0; for (i = 1; i <= 3; i++) { x = $i - $(i + 3); if (x < 0) x = -x; if (x > d) d = x } exit !(d <= '"${3:-24}"') }'; }
count() { grep -c "$1" "$LOG" 2>/dev/null || true; }
waitlog() { i=0; while ! grep -q "$1" "$LOG" 2>/dev/null && [ $i -lt ${2:-100} ]; do sleep 0.05; i=$((i + 1)); done; grep -q "$1" "$LOG"; }

# ---- the shell (bar and dock), its helper, and app windows ----
mkfifo "$T0/cmd"; exec 8<>"$T0/cmd"
SHELLENV="${PROFILE:+ALTTAB_PROFILE=1} RIBBON_ALTTAB_PROBE=$T/probe ALTTAB_LOG=$T/alttab.log ALTTAB_CMD=$T/cmd RIBBON_SHELL_TEST=$T/bin/hook.tcl RIBBON_SWITCH_HELPER=$B/ribbon-shell-switch"
R env $E $SHELLENV wish8.6 -encoding utf-8 $T/shell/main.tcl -name ribbon-shell >"$T0/shell.out" 2>&1 &
waitlog hooked 200 || { cat "$T0/shell.out"; bad "the shell did not start"; exit 1; }
sh_do() { echo "$@" > "$T0/cmd"; }
KL=$T0/keys.log; : > "$KL"
WN=0
mkwin() { WN=$((WN + 1)); R env $E wish8.6 $B/appwin.tcl "$1" "$2" "$3" "$T/keys.log" >"$T0/win-$WN.out" 2>&1 & i=0; while ! grep -q mapped "$T0/win-$WN.out" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; sleep 0.3; }
if [ -n "${REVIEW:-}" ]; then
	# the AltTab-1 board's six apps (the last window of each app is its front one, the most recent)
	mkwin ribbon-mail Inbox "#16a085"; mkwin steam Library "#34495e"; mkwin ribbon-editor patch-notes.md "#7f8c8d"; mkwin foot \~/src/ribbon "#2c3e50"
	mkwin firefox Mail "#e67e22"; mkwin firefox "Build logs" "#d35400"; mkwin firefox "Proton compatibility" "#e74c3c"
	mkwin ribbonfiles "Games SSD" "#8e44ad"; mkwin ribbonfiles Pictures "#9b59b6"; mkwin ribbonfiles Downloads "#3498db"
else
	mkwin Alpha one "#c0392b"; mkwin Beta two "#2980b9"; mkwin Alpha three "#c0392b"; mkwin Gamma four "#27ae60"
fi
sleep 1
sh_do state; sleep 0.3
shot before
if [ -n "${PROFILE:-}" ]; then
	# PROFILE=n: n cold opens (helper not running), then n warm ones; "us since the key" per stage (probe labels
	# are alttab::probe's). The key press is stamped just before altkeys is told to type it.
	P=$T0/probe; ms() { awk -v t0="$1" '{ printf "%s=%.0f ", $2, ($1 - t0 / 1000) / 1000 }' "$P"; echo; }
	run1() {
		: > "$P"; t0=$(date +%s%N); key "down Alt"; key "tap Tab"; sleep 1.0
		echo "  $1: $(ms "$t0")"; sh_do "alttab::close"; key "up Alt"; sleep 0.5
	}
	j=0; while [ $j -lt $PROFILE ]; do sh_do "alttab::hstop"; sleep 0.4; run1 cold; j=$((j + 1)); done
	sh_do "alttab::hstart"; sleep 1
	j=0; while [ $j -lt $PROFILE ]; do run1 warm; j=$((j + 1)); done
	exit 0
fi
CAPS=
sh_do "alttab::hstart"; sleep 0.8; sh_do 'say caps [set alttab::hcaps]'; sleep 0.3
grep -q 'caps shot cap' "$LOG" && CAPS=cap
grep -q 'caps shot' "$LOG" && ok "the helper starts and lists what the compositor offers: $(grep ' caps ' "$LOG" | tail -1 | sed 's/.* caps //')" || bad "helper caps: $(tail -3 "$LOG")"

if [ -n "${REVIEW:-}" ]; then
	sh_do "alttab::hstart"; sleep 0.8
	key "down Alt"; key "tap Tab"; sleep 2; shot review-apps
	key "down Shift"; key "tap Tab"; key "up Shift"; sleep 0.2; key "tap grave"; sleep 1.5; shot review-stack
	key "tap Esc"; key "tap Esc"; key "up Alt"; sleep 0.3
	R env $E $B/wlclient game 1a3a5c >"$T0/game.out" 2>&1 &
	sleep 1.5; key "down Alt"; key "tap Tab"; sleep 2; shot review-game
	key "tap Esc"; key "up Alt"; sleep 0.3
	exit 0
fi
# ---- S1 Alt+Tab held: shows after 150 ms, above the bar and dock ----
echo "S1 Alt+Tab, held"
key "down Alt"; key "tap Tab"
waitlog 'call reveal' 60 && ok "S1 the labwc bind reached the shell and the switcher opened (call reveal)" || { bad "S1 no reveal: $(tail -5 "$LOG")"; }
sleep 1.2
sh_do state; sleep 0.2
echo "     $(grep ' state ' "$LOG" | tail -1 | sed 's/^[0-9]* //')"
shot s1
# sharpness of the bar's and the dock's strips: crisp in the desktop, soft (blurred still) when the switcher covers them
edge() { convert "$T0/shots/$1.png" -crop "$2" +repage -colorspace Gray -edge 1 -format '%[fx:maxima]' info:; }
for strip in "440x50+0+0 bar" "500x50+390+670 dock"; do
	set -- $strip; e0=$(edge before $1); e1=$(edge s1 $1)
	echo "     $2 strip sharpness: $e0 on the desktop, $e1 with the switcher"
	awk -v a="$e0" -v b="$e1" 'BEGIN { exit !(a > 0.5 && b < 0.2) }' && ok "S1 the switcher covers the shell's $2 (its edges are gone: only the blurred still is there)" || bad "S1 the $2 still shows through the switcher"
done
cp "$T0/shots/s1.png" "$T0/shots/board-apps.png"

# ---- S2 keys reach the shell, the window below gets none ----
echo "S2 Tab, Shift+Tab, arrows with the helper holding the keyboard"
: > "$KL"
S0=$(count 'call step')
key "tap Tab"; key "down Shift"; key "tap Tab"; key "up Shift"; sleep 0.3
S1=$(count 'call step')
[ $((S1 - S0)) -ge 2 ] && ok "S2 A-Tab and A-S-Tab each stepped once through the binds ($((S1 - S0)) steps)" || bad "S2 steps: $((S1 - S0))"
M0=$(count 'call move')
key "tap Right"; key "tap Left"; key "tap Down"; key "tap Up"; sleep 0.3
M1=$(count 'call move')
[ $((M1 - M0)) -ge 4 ] && ok "S2 the helper reported the arrow keys ($((M1 - M0)) moves)" || bad "S2 arrows: $((M1 - M0)) moves"
key "tap a"; sleep 0.3
[ ! -s "$KL" ] && ok "S2 the focused app window got no key while the helper held the keyboard (the a was not delivered)" || bad "S2 the app saw: $(cat "$KL")"
if grep -q ' key tab' "$LOG"; then note "while the helper holds the keyboard this labwc hands the bound Tab to the helper, not to the bind (one step either way)"; else note "this labwc consumes the bound Tab: the step comes from ribbon-shell-ctl"; fi
F0=$(count 'call fan')
key "tap grave"; sleep 0.3
[ "$(count 'call fan')" -gt "$F0" ] && ok "S2 the grave key fanned the chosen stack" || note "grave: no fan (the chosen app has one window)"

# ---- S3 capture ----
echo "S3 window capture"
if [ "$CAPS" = cap ]; then
	waitlog cap-done 40 && ok "S3 labwc offers ext-image-copy-capture with a toplevel source: the helper copied windows" || bad "S3 no capture came back"
	sh_do 'say pictures [array names alttab::ph]'; sleep 0.3
	grep ' pictures ' "$LOG" | tail -1 | sed 's/^[0-9]* /     /'
	shot s3
	cp "$T0/shots/s3.png" "$T0/shots/board-thumbs.png"
else
	note "this labwc has no ext-image-copy-capture: cards stay icons (the fallback)"
	! grep -q cap-done "$LOG" && ok "S3 no capture was asked for, the icon fallback is in use" || bad "S3 capture ran without support"
fi
sh_do 'say bg [expr {$alttab::bg ne ""}]'; sleep 0.3
grep -q ' bg 1' "$LOG" && ok "S3 the still behind the cards was taken, blurred and dimmed (wlr-screencopy)" || bad "S3 no still: $(grep -i shot "$LOG" | tail -2)"

HP=$(pgrep -f "alttab\.$$/bin/ribbon-shell-switch" | head -1)
[ -n "$HP" ] && echo "     helper memory: $(grep -E 'VmRSS' /proc/$HP/status | tr -s ' \t' ' ') (Pss $(awk '/^Pss:/ { print $2 " kB" }' /proc/$HP/smaps_rollup 2>/dev/null))"
O0=$(grep -m1 'call open' "$LOG" | cut -d' ' -f1); SD=$(grep -m1 'shot-done' "$LOG" | cut -d' ' -f1); CD=$(grep -m1 'cap-done' "$LOG" | cut -d' ' -f1); RV=$(grep -m1 'call reveal' "$LOG" | cut -d' ' -f1)
echo "     from the bind to: still blurred $((SD - O0)) ms, switcher drawn $((RV - O0)) ms, first window copy $((CD - O0)) ms"
# ---- S4 W closes, Alt release activates ----
echo "S4 W, then release Alt"
key "tap w"; sleep 0.5
grep -q 'call kill window' "$LOG" && grep -q 'send .close' "$LOG" && ok "S4 W closed the chosen window (send close)" || bad "S4 W: $(tail -4 "$LOG")"
key "up Alt"; sleep 0.8
waitlog 'send .activate' 20 && ok "S4 releasing Alt activated a window ($(grep 'send .activate' "$LOG" | tail -1 | sed 's/^[0-9]* //'))" || bad "S4 no activation"
sh_do state; sleep 0.3
grep ' state ' "$LOG" | tail -1 | grep -q 'on=0' && ok "S4 the switcher closed" || bad "S4 still open"
: > "$KL"; key "tap a"; sleep 0.4
[ -s "$KL" ] && ok "S4 the keyboard went back to the app after the switcher closed" || bad "S4 the app got no key afterwards (the helper still holds it?)"

# ---- S5 a tap under 150 ms ----
echo "S5 a tap: Alt+Tab, released at once"
R0=$(count 'call reveal'); A0=$(count 'send .activate')
key "down Alt"; key "tap Tab"; key "up Alt"; sleep 0.8
R1=$(count 'call reveal'); A1=$(count 'send .activate')
[ $((R1 - R0)) -eq 0 ] && ok "S5 nothing was shown for a tap" || bad "S5 the switcher showed for a tap"
[ $((A1 - A0)) -eq 1 ] && ok "S5 the tap switched windows (one activate)" || bad "S5 activations: $((A1 - A0))"

# ---- S6 over a fullscreen game ----
echo "S6 a fullscreen Wayland game"
R env $E $B/wlclient game 0000ff >"$T0/game.out" 2>&1 &
i=0; while ! grep -q mapped "$T0/game.out" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; sleep 0.8
shot game
sleep 0.3
key "down Alt"; key "tap Tab"; sleep 1.5
shot s6
p=$(px s6 700 20); g=$(px game 700 20)
echo "     the game at (700,20): $g; with the switcher up: $p"
! near "$p" "0 0 255" 40 && ok "S6 the switcher is above a fullscreen game (the game stays fullscreen)" || bad "S6 the game covers the switcher"
cp "$T0/shots/s6.png" "$T0/shots/board-game.png"
key "tap Esc"; key "up Alt"; sleep 0.6

# ---- S7 a layer-shell bar: measured ----
echo "S7 a layer-shell top bar (measured, not required)"
kill %5 2>/dev/null
pkill -f "alttab\.$$/bin/wlclient game" 2>/dev/null; sleep 0.5
R env $E $B/wlclient bar 00ff00 60 >"$T0/bar.out" 2>&1 &
i=0; while ! grep -q mapped "$T0/bar.out" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; sleep 0.5
key "down Alt"; key "tap Tab"; sleep 1.5; shot s7
p=$(px s7 700 20)
if near "$p" "0 255 0" 20; then note "a layer-shell TOP bar is drawn above the Tk switcher (override-redirect X windows sit under the top layer): $p"; else note "the switcher is above a layer-shell top bar: $p"; fi
key "tap Esc"; sh_do "alttab::close"; key "up Alt"; sleep 0.5

[ "$fail" = 0 ] && echo "alttab native: all checks passed"
exit $fail
