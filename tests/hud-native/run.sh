#!/bin/sh
# run.sh [ROOT] - the Game HUD's on-screen surface and toggle (U23) in a headless labwc.
# The real ribbon-hud (daemon, started by the Super+F12 bind) and the real ribbon-hud-surface (layer-shell overlay)
# over a fullscreen Wayland "game" (wlgame: reports every pointer and keyboard event it gets). Virtual keyboard and
# pointer through Wayland. Checks: the toggle cycle, the HUD above a fullscreen client, see-through glass, clicks pass
# through to the client, the keyboard stays with the client, the interactive buttons and their names (tooltips), the
# quick-menu move, Close,
# costs, and the native drawing against the Tk canvas drawing of the same ops.
# ROOT: a test root of prebuilt packages with labwc 0.8 or later (CI: build/ci/labwc020.sh); without it the host's labwc. REVIEW=1 SHOTS=dir: board-sized pictures only.
# SHOTS=dir: keep the screenshots there. Fonts: tests/hud-native/fonts.conf names Ribbon's font families.
set -u
cd "$(dirname "$0")/../.." || exit 1
N=$(pwd); ROOT=${1:-}
D=$N/srcpkgs/ribbon-desktop/files
X=$N/tests/hud-native
T0=${TMPDIR:-/tmp}/hudnat.$$; T=$T0; B=$T0/bin
if [ -n "$ROOT" ]; then T0=$ROOT/tmp/hudnat.$$; T=/tmp/hudnat.$$; B=$T/bin; fi
R() { if [ -n "$ROOT" ]; then chroot "$ROOT" "$@"; else "$@"; fi; }
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }; note() { echo "  note $*"; }
# signal our background jobs (reap TERM|KILL). jobs -p must run in this shell, not in $(...): dash's subshell has no job table
reap() { _rf=$(mktemp) || return 0; jobs -p >"$_rf"; while read -r _rp; do kill -"$1" "$_rp" 2>/dev/null; done <"$_rf"; rm -f "$_rf"; }
cleanup() { reap TERM; pkill -f "hudnat\.$$/" 2>/dev/null
	_k=0; while pgrep -f "hudnat\.$$/" >/dev/null 2>&1 && [ $_k -lt 20 ]; do sleep 0.05; _k=$((_k + 1)); done; pkill -9 -f "hudnat\.$$/" 2>/dev/null
	if [ -n "$ROOT" ]; then umount "$ROOT/proc" "$ROOT/dev/shm" 2>/dev/null; [ -n "${BOUND:-}" ] && umount "$ROOT/dev" 2>/dev/null; fi
	[ -n "${SHOTS:-}" ] && [ -d "$T0/shots" ] && cp "$T0"/shots/*.png "$SHOTS"/ 2>/dev/null
	[ -n "${KEEPLOG:-}" ] && cp "$T0/hud.log" "$KEEPLOG" 2>/dev/null
	rm -rf "$T0"; }
trap cleanup EXIT
for t in labwc wish8.6 grim convert compare wayland-scanner wlr-randr xvfb-run import; do
	if [ -z "$ROOT" ] && ! command -v $t >/dev/null 2>&1; then echo "  skip HUD surface (no $t)"; exit 0; fi
done
pkg-config --exists wayland-client cairo wayland-protocols || { echo "  skip HUD surface (no wayland-client / cairo / wayland-protocols)"; exit 0; }
mkdir -p "$T0/bin" "$T0/rt" "$T0/lw" "$T0/home/.config/ribbon" "$T0/cache" "$T0/shots" "$T0/sc"; chmod 700 "$T0/rt"
S=$T0/bin

# ---- build (host toolchain; the programs run in the root against its libraries) ----
make -s -C "$D/apps/hud/native" O="$S" CFLAGS="-O2 -Wall -Wextra -Werror" >"$T0/build.log" 2>&1 || { cat "$T0/build.log"; bad "ribbon-hud-surface does not build"; exit 1; }
ok "ribbon-hud-surface builds with -Wall -Wextra -Werror ($(wc -c < "$S/ribbon-hud-surface") bytes)"
XDG=$(pkg-config --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml
wayland-scanner client-header "$XDG" "$S/xdg-shell-client-protocol.h"; wayland-scanner private-code "$XDG" "$S/xdg-x.c"
wayland-scanner client-header "$X/wlr-virtual-pointer-unstable-v1.xml" "$S/wlr-virtual-pointer-unstable-v1-client-protocol.h"; wayland-scanner private-code "$X/wlr-virtual-pointer-unstable-v1.xml" "$S/vp.c"
wayland-scanner client-header "$X/virtual-keyboard-unstable-v1.xml" "$S/virtual-keyboard-unstable-v1-client-protocol.h"; wayland-scanner private-code "$X/virtual-keyboard-unstable-v1.xml" "$S/vk.c"
# pkg-config's flags are a list of words: the variables are split into them on purpose
WL_FLAGS=$(pkg-config --cflags --libs wayland-client)
WLK_FLAGS=$(pkg-config --cflags --libs wayland-client xkbcommon)
cc -O2 -Wall -Wextra -Werror -I"$S" -o "$S/wlgame" "$X/wlgame.c" "$S/xdg-x.c" $WL_FLAGS &&
cc -O2 -Wall -Wextra -Werror -I"$S" -o "$S/vptr" "$X/vptr.c" "$S/vp.c" $WL_FLAGS &&
cc -O2 -Wall -Wextra -Werror -I"$S" -o "$S/vkeys" "$X/vkeys.c" "$S/vk.c" $WLK_FLAGS || { bad "test tools do not build"; exit 1; }
cp -r "$D/apps/hud" "$T0/hud"; rm -rf "$T0/hud/native"; mkdir -p "$T0/shell" "$T0/settings" "$T0/proc";
cp "$D/apps/settings/hudstore.tcl" "$D/apps/settings/games.tcl" "$T0/settings/"
cp "$N/srcpkgs/ribbon-gaming/files/ribbon-gamescope" "$S/ribbon-gamescope"; chmod +x "$S/ribbon-gamescope"
# the shell's window helper, as it is: the daemon runs its own instance of it to know the game in front
WATCH=; if make -s -C "$D/shell-watch" O="$S" ribbon-shell-watch CFLAGS="-O2" >"$T0/watch.log" 2>&1; then WATCH=$B/ribbon-shell-watch; else note "ribbon-shell-watch does not build here: no game detection checks"; fi
cp -r "$D/shell/." "$T0/shell/"; cp "$D/shell/raster.tcl" "$T0/shell/"
cp -r "$N/tests/hud-fixtures" "$T0/fixtures"
# the launchers' fixture home, with Steam's library cache holding Portal 2's icon (the header's art)
cp -r "$N/tests/fixtures/launchers/steam" "$T0/gameshome"
mkdir -p "$T0/gameshome/.local/share/Steam/appcache/librarycache"
cp "$N/tests/hud-fixtures/art-home/.local/share/Steam/appcache/librarycache/620_icon.jpg" "$T0/gameshome/.local/share/Steam/appcache/librarycache/"
cp "$D/themes/palettes/ribbon.conf" "$T0/home/.config/ribbon/palette.conf"
BAR=$(sed -n 's/^BAR=//p' "$D/themes/palettes/ribbon.conf" | head -1 | tr -d '"#')
BR=$((0x$(echo "$BAR" | cut -c1-2))); BG=$((0x$(echo "$BAR" | cut -c3-4))); BB=$((0x$(echo "$BAR" | cut -c5-6)))
# the real build makes SpaceGrotesk-SemiBold; fonts.conf here names Ribbon's families on what the machine has
FC=$T0/fonts.conf
cat > "$FC" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <include ignore_missing="yes">/etc/fonts/fonts.conf</include>
  <include ignore_missing="yes">$D/shell/fonts.conf</include>
</fontconfig>
EOF
FCT=$T/fonts.conf

# ---- headless labwc with the Super+F12 bind of rc.xml ----
HUDCTL="$B/ribbon-hud"; cp "$D/apps/hud/bin/ribbon-hud" "$S/ribbon-hud"; chmod +x "$S/ribbon-hud"
HENV="RIBBON_HUD_DIR=$T/hud RIBBON_HUD_SURFACE=$B/ribbon-hud-surface RIBBON_HUD_LOG=$T/hud.log RIBBON_HUD_FRAMES=$T/frames.txt FONTCONFIG_FILE=$FCT RIBBON_HUD_WATCH=$WATCH RIBBON_HUD_PROC=$T/proc RIBBON_GAMES_CONF=$T/home/.config/ribbon/game-overlay.conf RIBBON_GAMES_HOME=$T/gameshome"
cat > "$T0/lw/rc.xml" <<EOF
<labwc_config><core><decoration>server</decoration></core>
<keyboard><default />
<keybind key="W-F12"><action name="Execute" command="$HUDCTL cycle" /></keybind>
</keyboard></labwc_config>
EOF
echo 'echo "$DISPLAY" > "$XDG_RUNTIME_DIR/display"' > "$T0/lw/autostart"
[ -n "$ROOT" ] && { mkdir -p "$ROOT/proc" "$ROOT/dev/shm"; mount -t proc proc "$ROOT/proc" 2>/dev/null
	if [ ! -e "$ROOT/dev/urandom" ]; then mount --bind /dev "$ROOT/dev" 2>/dev/null && BOUND=1; else mount -t tmpfs tmpfs "$ROOT/dev/shm" 2>/dev/null; fi; }
R env WAYLAND_DISPLAY='' WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1 \
	XDG_RUNTIME_DIR=$T/rt HOME=$T/home XDG_CACHE_HOME=$T/cache $HENV labwc -C "$T/lw" >"$T0/labwc.log" 2>&1 &
i=0; while [ ! -s "$T0/rt/display" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
sock=; for f in "$T0"/rt/wayland-*; do case $f in *.lock) ;; *) [ -S "$f" ] && sock=${f##*/} ;; esac; done
[ -n "$sock" ] || { cat "$T0/labwc.log"; echo "no labwc"; exit 1; }
DISP=$(cat "$T0/rt/display")
echo "compositor: $(R labwc -v | head -1), socket $sock, X display $DISP"
# the boards are 1440x900 (the socket path is too long for wlr-randr from here, hence the short link)
ln -sf "$T0/rt" "/tmp/hudnat-rt.$$"; XDG_RUNTIME_DIR=/tmp/hudnat-rt.$$ WAYLAND_DISPLAY=$sock wlr-randr --output HEADLESS-1 --custom-mode 1440x900 >/dev/null 2>&1; rm -f "/tmp/hudnat-rt.$$"
E="XDG_RUNTIME_DIR=$T/rt WAYLAND_DISPLAY=$sock DISPLAY=$DISP HOME=$T/home XDG_CONFIG_HOME=$T/home/.config XDG_CACHE_HOME=$T/cache PATH=$B:/usr/local/bin:/usr/bin:/bin $HENV"
LOG=$T0/hud.log; : > "$LOG"
W=1440; H=900
shot() { R env $E grim "$T/shots/$1.png"; }
px() { convert "$T0/shots/$1.png" -format "%[fx:int(255*p{$2,$3}.r)] %[fx:int(255*p{$2,$3}.g)] %[fx:int(255*p{$2,$3}.b)]" info:; }
near() { echo "$1 $2" | awk '{ d = 0; for (i = 1; i <= 3; i++) { x = $i - $(i + 3); if (x < 0) x = -x; if (x > d) d = x } exit !(d <= '"${3:-24}"') }'; }
count() { grep -c "$1" "$2" 2>/dev/null || true; }
waitlog() { i=0; while [ "$(count "$1" "$LOG")" -le "${3:-0}" ] && [ $i -lt ${2:-100} ]; do sleep 0.05; i=$((i + 1)); done; [ "$(count "$1" "$LOG")" -gt "${3:-0}" ]; }
mkfifo "$T0/vp.in" "$T0/vk.in"
exec 7<>"$T0/vp.in"; exec 8<>"$T0/vk.in"
R env $E $B/vptr <&7 >"$T0/vp.out" 2>&1 &
R env $E $B/vkeys <&8 >"$T0/vk.out" 2>&1 &
pt() { echo "$@" >&7; n=$(wc -l < "$T0/vp.out"); i=0; while [ "$(wc -l < "$T0/vp.out")" -le "$n" ] && [ $i -lt 100 ]; do sleep 0.02; i=$((i + 1)); done; }
vk() { n=$(wc -l < "$T0/vk.out"); echo "$@" >&8; i=0; while [ "$(wc -l < "$T0/vk.out")" -le "$n" ] && [ $i -lt 100 ]; do sleep 0.02; i=$((i + 1)); done; }
F12() { vk "down Super"; vk "tap F12"; vk "up Super"; }
# the pointer helper answers each line once it is done ("ok"): the size first
pt "size $W $H"
hudstate() { n=$(count 'state ' "$LOG"); R env $E $HUDCTL state; waitlog 'state ' 60 "$n"; grep 'state ' "$LOG" | tail -1; }
mapped_box() { grep 'surface mapped' "$LOG" | tail -1 | sed 's/.*mapped //'; }
# the last mapped box, read in one go: MBX MBY MBW MBH (the box is "x y w h")
read_box() { read -r MBX MBY MBW MBH <<EOF
$(mapped_box)
EOF
}
# shellcheck disable=SC2120 # an optional limit; no caller passes one yet
waitmapped() { n=$(count 'surface mapped' "$LOG"); i=0; while [ "$(count 'surface mapped' "$LOG")" -le "$n" ] && [ $i -lt ${1:-60} ]; do sleep 0.05; i=$((i + 1)); done; }
waithidden() { i=0; while [ "$(count 'surface hidden' "$LOG")" -le "$1" ] && [ $i -lt ${2:-60} ]; do sleep 0.05; i=$((i + 1)); done; }
# ---- deadline waits, no fixed sleeps: each polls until its condition holds, at most a limit, and says whether it held
# poll SECONDS COMMAND...: COMMAND (a function or a program) every 50 ms until it succeeds
poll() { _l=$(($1 * 20)); shift; _i=0; while ! "$@"; do [ $_i -ge $_l ] && return 1; sleep 0.05; _i=$((_i + 1)); done; return 0; }
# waitstate PATTERN [SECONDS]: asks the daemon's state until it matches the case PATTERN; the last answer is in st
# shellcheck disable=SC2254 # $1 is a case pattern on purpose
stateis() { st=$(hudstate); case $st in $1) return 0 ;; esac; return 1; }
waitstate() { poll "${2:-5}" stateis "$1"; }
# settle NAME [TEST...]: grabs the screen until two grabs in a row are the same picture (the compositor and the
# surface have drawn) and TEST holds on it, at most 5 s
settle() {
	_n=$1; shift; _j=0
	R env $E grim "$T/shots/$_n.png"
	while [ $_j -lt 50 ]; do
		cp "$T0/shots/$_n.png" "$T0/shots/prev.png"
		sleep 0.1; R env $E grim "$T/shots/$_n.png"
		if cmp -s "$T0/shots/$_n.png" "$T0/shots/prev.png" && { [ $# -eq 0 ] || "$@"; }; then return 0; fi
		_j=$((_j + 1))
	done
	return 1
}
# tests for settle: the grab NAME is (or is not) the game alone; its pixel X Y is (not) near R G B within TOL
isgame() { cmp -s "$T0/shots/$1.png" "$T0/shots/game.png"; }
notgame() { ! isgame "$1"; }
pxnear() { near "$(px "$1" "$2" "$3")" "$4" "$5"; }
pxfar() { ! pxnear "$@"; }

# ---- the game: fullscreen, stripes, reports its input ----
GL=$T0/game.out; : > "$GL"
gmark() { GOFF=$(wc -c < "$GL"); }
gnew() { tail -c +$((GOFF + 1)) "$GL" | tr -d '\0'; }
gmark
R env $E $B/wlgame bars >"$GL" 2>&1 &
waitg() { i=0; while ! grep -q "$1" "$GL" 2>/dev/null && [ $i -lt 60 ]; do sleep 0.1; i=$((i + 1)); done; }
waitg mapped
pt "move 100 800"
# the game's picture once it has settled: its stripes at both corners
gameup() { [ -n "$(px game 5 5)" ] && [ "$(px game 5 5)" != "0 0 0" ]; }
settle game gameup
GB=$(px game 5 5); GB2=$(px game $((W - 5)) $((H - 5)))
echo "     the game at its corners: $GB / $GB2"
[ -n "$GB" ] && ok "the game is fullscreen (its stripes reach both corners of the ${W}x${H} output)" || bad "no game picture"

# ---- REVIEW: the boards' scenes over the game, for the eye ----
if [ -n "${REVIEW:-}" ]; then
	for sc in default menu compact fps nofr; do
		: > "$T0/live.out"
		R env $E wish8.6 -encoding utf-8 "$X/scene.tcl" live $sc >"$T0/live.out" 2>&1 & LP=$!
		poll 10 grep -q ready "$T0/live.out"
		settle review-$sc notgame review-$sc; pkill -f "scene.tcl live" 2>/dev/null; settle review-gone isgame review-gone
	done
	exit 0
fi

# ---- S1 the toggle: Super+F12 cycles Off -> FPS -> Compact -> Full -> Off ----
echo "S1 Super+F12 (a labwc bind: ribbon-hud cycle; the daemon starts on the first press)"
t0=$(date +%s%3N)
F12
waitlog 'surface mapped' 100 || { bad "S1 the bind did not show the HUD: $(tail -3 "$LOG")"; cat "$T0/labwc.log" | tail -3; }
t1=$(grep 'surface mapped' "$LOG" | head -1 | cut -d' ' -f1)
echo "     first press to a drawn HUD (daemon start, helper start, first frame): $((t1 - t0)) ms"
waitstate '*layout=fps*'; echo "     $st" | cut -c1-110
case $st in *layout=fps*) ok "S1 press 1: FPS";; *) bad "S1 press 1: $st";; esac
settle s1-fps notgame s1-fps
read_box; FBX=$MBX; FBY=$MBY; FBW=$MBW; FBH=$MBH
echo "     surface box $FBX $FBY ${FBW}x$FBH"
# the pill: 24 px from the top and right edges
PX=$((W - 24 - 40)); PY=$((24 + 20))
p=$(px s1-fps $PX $PY)
! near "$p" "$GB" 60 && ok "S1 the FPS pill is on screen over the game (top right: $p)" || bad "S1 no pill over the game ($p)"
F12; waitmapped; waitstate '*layout=compact*'; case $st in *layout=compact*) ok "S1 press 2: Compact";; *) bad "S1 press 2: $st";; esac
read_box; CBH=$MBH; settle s1-compact notgame s1-compact
F12; waitmapped; waitstate '*layout=full*'; case $st in *layout=full*) ok "S1 press 3: Full";; *) bad "S1 press 3: $st";; esac
read_box; FUX=$MBX; FUY=$MBY; FUW=$MBW; FUH=$MBH; settle s1-full notgame s1-full
echo "     box heights: FPS $FBH, Compact $CBH, Full $FUH (panel 40 / 101 / 383 plus shadow room)"
[ "$FBH" -lt "$CBH" ] && [ "$CBH" -lt "$FUH" ] && ok "S1 the three layouts have growing surfaces" || bad "S1 box heights $FBH $CBH $FUH"
nh=$(count 'surface hidden' "$LOG")
F12; waithidden "$nh"
waitstate '*layout=off*'; case $st in *layout=off*) ok "S1 press 4: Off (the surface is unmapped)";; *) bad "S1 press 4: $st";; esac
settle s1-off isgame s1-off
d=$(compare -metric AE "$T0/shots/game.png" "$T0/shots/s1-off.png" null: 2>&1)
[ "$d" = 0 ] && ok "S1 Off leaves the game's picture untouched (0 pixels differ)" || bad "S1 Off: $d pixels differ from the game alone"
F12; waitmapped; waitstate '*layout=fps*'; case $st in *layout=fps*) ok "S1 press 5: back to FPS (the cycle goes on)";; *) bad "S1 press 5: $st";; esac
# back to Full for the rest
F12; waitmapped; F12; waitmapped; waitstate '*layout=full*mapped=1*'
read_box; FUX=$MBX; FUY=$MBY; FUW=$MBW; FUH=$MBH

# ---- S2 above a fullscreen client; S3 see-through ----
echo "S2 above the fullscreen game, S3 see-through"
settle s2 notgame s2
# outside the surface the picture is the game's; inside it is not
out=$(convert "$T0/shots/game.png" -crop 300x300+100+300 +repage "$T0/shots/g-out.png"; convert "$T0/shots/s2.png" -crop 300x300+100+300 +repage "$T0/shots/s-out.png"; compare -metric AE "$T0/shots/g-out.png" "$T0/shots/s-out.png" null: 2>&1)
[ "$out" = 0 ] && ok "S2 away from the HUD the game is unchanged" || bad "S2 the picture changed away from the HUD ($out pixels)"
convert "$T0/shots/game.png" -crop ${FUW}x${FUH}+${FUX}+${FUY} +repage "$T0/shots/g-in.png"; convert "$T0/shots/s2.png" -crop ${FUW}x${FUH}+${FUX}+${FUY} +repage "$T0/shots/s-in.png"
inn=$(compare -metric AE -fuzz 2% "$T0/shots/g-in.png" "$T0/shots/s-in.png" null: 2>&1)
echo "     inside the surface box: $inn of $((FUW * FUH)) pixels differ from the game alone"
[ "$inn" -gt $((FUW * FUH / 2)) ] && ok "S2 the HUD is drawn above the fullscreen game" || bad "S2 the HUD is not above the game"
# a point in the empty header (no game name set), on two different stripes
PXL=$((W - 24 - 236)); PYL=$((24 + 26))
for xx in $((PXL + 70)) $((PXL + 110)); do
	g=$(px game $xx $PYL); h=$(px s2 $xx $PYL)
	exp=$(echo "$g" | awk -v r="$BR" -v g2="$BG" -v b="$BB" '{ printf "%d %d %d", 0.86 * r + 0.14 * $1 + 0.5, 0.86 * g2 + 0.14 * $2 + 0.5, 0.86 * b + 0.14 * $3 + 0.5 }')
	echo "     at $xx,$PYL: game $g, HUD $h, glass over game expected $exp"
	near "$h" "$exp" 4 && ok "S3 the glass is see-through: bar colour at 86 % over the game's pixel" || bad "S3 $h is not $exp"
done
h1=$(px s2 $((PXL + 70)) $PYL); h2=$(px s2 $((PXL + 110)) $PYL)
! near "$h1" "$h2" 1 && ok "S3 two points of glass over different stripes differ ($h1 / $h2): an opaque panel would show one colour" || bad "S3 the glass is opaque ($h1 / $h2)"
cp "$T0/shots/s2.png" "$T0/shots/board-full-over-game.png"

# ---- S4 clicks pass through; S5 the keyboard stays with the game ----
echo "S4 clicks pass through, S5 the keyboard stays with the game"
# gsaw PATTERN: the game has reported PATTERN since gmark (waited for, at most 3 s)
gsaw() { poll 3 gfind "$1"; }
gfind() { gnew | grep -q "$1"; }
gmark
pt "move 300 400"; pt "move $((PXL + 70)) $PYL"; pt click
gsaw "click $((PXL + 70)) $PYL" && ok "S4 a click on the HUD's glass reached the game ($(gnew | grep click | tail -1))" || bad "S4 the click did not reach the game: $(gnew | tr '\n' ' ')"
PINX=$((PXL + 182)); PINY=$PYL
pt "move $PINX $PINY"; pt click
gsaw "click $PINX $PINY" && ok "S4 a click on the pin button reached the game too (the HUD takes no input by default)" || bad "S4 the pin click did not reach the game"
st=$(hudstate); case $st in *pinned=0*) ok "S4 the HUD did not take the click (still unpinned)";; *) bad "S4 $st";; esac
! gnew | grep -q 'ptr-leave' && ok "S4 moving the pointer over the HUD never took it from the game (no ptr-leave)" || bad "S4 the game lost the pointer: $(gnew | tr '\n' ' ')"
vk "tap a"
gsaw '^key 30' && ok "S5 a key typed with the HUD up arrived at the game" || bad "S5 the game got no key: $(gnew | tr '\n' ' ')"
! gnew | grep -q 'kbd-leave' && ok "S5 the game never lost keyboard focus (no kbd-leave since the HUD showed)" || bad "S5 the game lost the keyboard"
R env $E $HUDCTL layout fps; waitstate '*layout=fps*mapped=1*'; pt "move 300 400"; gmark; vk "tap a"
gsaw '^key 30' && ok "S5 and after a layout change" || bad "S5 key after layout change"
R env $E $HUDCTL layout full; waitstate '*layout=full*mapped=1*'

# ---- S6 interactive: the buttons take clicks, nothing else does ----
echo "S6 interactive 1: the pin and close buttons take clicks, the rest still passes through"
R env $E $HUDCTL interactive 1; waitstate '*interactive=1*'; gmark
pt "move 300 400"; pt "move $PINX $PINY"; pt click
waitstate '*pinned=1*'; case $st in *pinned=1*) ok "S6 the click on the pin button pinned the HUD";; *) bad "S6 not pinned: $st";; esac
! gnew | grep -q 'click' && ok "S6 the game did not get that click" || bad "S6 the game got the pin click"
gmark; pt "move $((PXL + 70)) $PYL"; pt click
gsaw "click $((PXL + 70)) $PYL" && ok "S6 a click on the glass beside the buttons still reaches the game" || bad "S6 the glass took the click"
settle s6-pinned notgame s6-pinned
# the buttons' names (tooltip.tcl's rules, drawn on the surface): not at once, then the name, gone on leaving; after a
# press not back until the pointer has left
pt "move 300 400"; TM=$(wc -l < "$LOG"); pt "move $PINX $PINY"
waitstate '*tip=pin *' && ok "S6 the pin button's name comes" || bad "S6 no name for the pin button: $st"
t1=$(tail -n +$((TM + 1)) "$LOG" | awk '/ surface motion / { print $1; exit }'); t2=$(tail -n +$((TM + 1)) "$LOG" | awk '/ tip pin$/ { print $1; exit }')
[ -n "$t1" ] && [ -n "$t2" ] && [ $((t2 - t1)) -ge 450 ] && ok "S6 not at once: $((t2 - t1)) ms after the pointer came" || bad "S6 the name's wait: motion ${t1:-?}, name ${t2:-?}"
shot s6-tip
r=$(convert "$T/shots/s6-tip.png" -crop 60x40+$((PINX - 30))+$((PINY + 30)) +repage -format '%[fx:maxima.r]' info: 2>/dev/null)
awk -v r="${r:-0}" 'BEGIN { exit !(r > 0.8) }' && ok "S6 its pill is drawn under the header (light text at $((PINX - 30)),$((PINY + 30)))" || bad "S6 no pill under the pin button (max red ${r:-?})"
TM=$(wc -l < "$LOG"); pt "move $((PXL + 208)) $PINY"
waitstate '*tip=close *' && ok "S6 moving on to Close: its name" || bad "S6 no name for Close: $st"
t1=$(tail -n +$((TM + 1)) "$LOG" | awk '/ surface motion / { print $1; exit }'); t2=$(tail -n +$((TM + 1)) "$LOG" | awk '/ tip close$/ { print $1; exit }')
[ -n "$t1" ] && [ -n "$t2" ] && [ $((t2 - t1)) -lt 300 ] && ok "S6 at once ($((t2 - t1)) ms): the pointer came straight from a shown name" || bad "S6 Close's name waited: motion ${t1:-?}, name ${t2:-?}"
pt "move 300 400"
waitstate '*tip= *' && ok "S6 the name goes when the pointer leaves" || bad "S6 the name stayed: $st"
R env $E $HUDCTL interactive 0; waitstate '*interactive=0*'; gmark; pt "move 300 400"; pt "move $PINX $PINY"; pt click
gsaw "click $PINX $PINY" && ok "S6 interactive 0: the pin button passes the click through again" || bad "S6 the button still takes clicks"
R env $E $HUDCTL pin 0; waitstate '*pinned=0*'

# ---- S7 the quick menu moves the HUD ----
echo "S7 menu 1: the right-hand HUD moves to 358 px from the right edge"
bx0=$FUX; n=$(count 'surface mapped' "$LOG")
R env $E $HUDCTL menu 1; i=0; while [ "$(count 'surface mapped' "$LOG")" -le "$n" ] && [ $i -lt 60 ]; do sleep 0.05; i=$((i + 1)); done
read_box; bx1=$MBX
echo "     surface box x: $bx0 -> $bx1"
[ $((bx0 - bx1)) -eq 334 ] && ok "S7 the surface moved 334 px left (24 -> 358 from the edge)" || bad "S7 the move was $((bx0 - bx1)) px"
settle s7-menu notgame s7-menu
R env $E $HUDCTL menu 0; waitmapped; waitstate '*menu=0*'; read_box; [ "$MBX" = "$bx0" ] && ok "S7 menu 0 puts it back" || bad "S7 back at $MBX, not $bx0"

# ---- S8 close hides it; the next cycle brings it back ----
echo "S8 close"
nh=$(count 'surface hidden' "$LOG"); R env $E $HUDCTL close; waithidden "$nh"
pt "move 100 800"; settle s8-closed isgame s8-closed; d=$(compare -metric AE "$T0/shots/game.png" "$T0/shots/s8-closed.png" null: 2>&1)
[ "$d" = 0 ] && ok "S8 Close hides the HUD" || bad "S8 close: $d pixels differ"
F12; waitmapped; waitstate '*hidden=0*'; case $st in *layout=full*hidden=0*|*hidden=0*layout=full*) ok "S8 Super+F12 brings it back in the layout it had";; *) bad "S8 $st";; esac

# ---- S9 costs ----
echo "S9 costs"
HP=$(pgrep -f "hudnat\.$$/bin/ribbon-hud-surface" | head -1)
[ -n "$HP" ] && echo "     ribbon-hud-surface: $(grep -E 'VmRSS' /proc/$HP/status | tr -s ' \t' ' ') (Pss $(awk '/^Pss:/ { print $2 " kB" }' /proc/$HP/smaps_rollup 2>/dev/null)), binary $(wc -c < "$S/ribbon-hud-surface") bytes"
DP=$(pgrep -f "hudnat\.$$/hud/main.tcl" | head -1)
[ -n "$DP" ] && echo "     ribbon-hud daemon (wish): $(grep -E 'VmRSS' /proc/$DP/status | tr -s ' \t' ' ') (Pss $(awk '/^Pss:/ { print $2 " kB" }' /proc/$DP/smaps_rollup 2>/dev/null))"
# the CPU time over a measured window (not a wait: the window is the measurement)
c0=$(awk '{ print $14 + $15 }' /proc/$DP/stat 2>/dev/null); sleep 5; c1=$(awk '{ print $14 + $15 }' /proc/$DP/stat 2>/dev/null)
[ -n "$c0" ] && echo "     daemon CPU while the Full HUD is up with no frame data: $((c1 - c0)) ticks in 5 s ($(( (c1 - c0) * 100 / 500 / 1 ))% of a core... 1 tick = 10 ms)"
hc0=$(awk '{ print $14 + $15 }' /proc/$HP/stat 2>/dev/null); sleep 3; hc1=$(awk '{ print $14 + $15 }' /proc/$HP/stat 2>/dev/null)
[ -n "$hc0" ] && echo "     helper CPU: $((hc1 - hc0)) ticks in 3 s"

# ---- S9b the frame source: the file transport (no game producer is reachable here: the producer is this loop) ----
echo "S9b frame times through the file source (hud::frames::use_file; RIBBON_HUD_FRAMES)"
st=$(hudstate); case $st in *frames=0*) ok "S9b with nothing writing frame times the HUD says so (frames=0: dashes and No frame data)";; *) bad "S9b $st";; esac
(i=0; while [ $i -lt 40 ]; do echo "8.9 9.1 8.7 8.9" >> "$T0/frames.txt"; sleep 0.1; i=$((i + 1)); done) &
waitstate '*frames=1*'; case $st in *frames=1*) ok "S9b frame times appended to the file give numbers (frames=1)";; *) bad "S9b $st";; esac
settle s9b-frames notgame s9b-frames
# the feed runs 4 s; two seconds after it stops the numbers are unavailable again
waitstate '*frames=0*' 10; case $st in *frames=0*) ok "S9b two seconds without frame times: unavailable again";; *) bad "S9b $st";; esac

# ---- S11 Settings → Game overlay: the store's file is the HUD's settings, and a change to it is followed ----
echo "S11 the Game overlay store (game-overlay.conf, written as the Settings page writes it)"
CONF=$T0/home/.config/ribbon/game-overlay.conf
store() { printf 'source %s\nhud::read_file\n%s\nhud::write_file\n' "$D/apps/settings/hudstore.tcl" "$1" | RIBBON_GAMES_CONF=$CONF tclsh8.6; }
logsince() { tail -n +$((LMARK + 1)) "$LOG"; }
# R runs its command as a child of a subshell, so $! is not the game: the games are ended by their own command line
killgame() { pkill -f "hudnat\.$$/bin/wlgame $1" 2>/dev/null; }
lmark() { LMARK=$(wc -l < "$LOG"); }
waitsince() { i=0; while ! logsince | grep -q "$1" && [ $i -lt ${2:-100} ]; do sleep 0.05; i=$((i + 1)); done; logsince | grep -q "$1"; }
st=$(hudstate); case $st in *"position top-right scale 100 opacity 86"*) ok "S11 no file: the built-in Defaults (top right, 100 %, 86 %)";; *) bad "S11 $st";; esac
lmark
store 'hud::put_default pos bl; hud::put_default scale 125; hud::put_default transp 30
hud::put steam:620 pos tl; hud::put steam:620 layout compact; hud::put steam:620 contents {frametime graph}
hud::put steam:1245620 on 0'
waitsince 'settings key=defaults.*position=bottom-left scale=125 opacity=70' 80 && ok "S11 the daemon read the changed file by itself: $(logsince | grep 'settings key' | tail -1 | cut -d' ' -f2- | cut -c1-100)" || bad "S11 the change was not followed: $(logsince | tail -3)"
waitsince 'surface mapped' 60; read_box
echo "     surface box $MBX $MBY ${MBW}x$MBH"
[ "$MBX" -lt 60 ] && [ $((MBY + MBH)) -gt $((H - 60)) ] && ok "S11 the surface re-anchored to the bottom left corner" || bad "S11 the box is at $MBX $MBY ${MBW}x$MBH"
[ "$MBW" -gt $((FUW + 40)) ] && ok "S11 and is drawn at 125 % (box $MBW px wide, $FUW at 100 %)" || bad "S11 scale: box width $MBW against $FUW"
settle s11-store notgame s11-store
# a point in the panel's empty header: 24 px margin, the header is the panel's top (the panel is 383 x 1.25 tall)
gx=$((24 + 110)); gy=$((H - 24 - 479 + 32)); g=$(px game $gx $gy); h=$(px s11-store $gx $gy)
exp=$(echo "$g" | awk -v r="$BR" -v g2="$BG" -v b="$BB" '{ printf "%d %d %d", 0.70 * r + 0.30 * $1 + 0.5, 0.70 * g2 + 0.30 * $2 + 0.5, 0.70 * b + 0.30 * $3 + 0.5 }')
echo "     at $gx,$gy: game $g, HUD $h, glass at 70 % expected $exp"
near "$h" "$exp" 6 && ok "S11 Transparency 30 %: the glass is the bar colour at 70 % over the game" || bad "S11 glass $h, expected $exp"
# the state query after reload is answered after the reload was handled (the daemon reads its FIFO in order)
R env $E $HUDCTL reload; st=$(hudstate); case $st in *layout=full*shown=1*) ok "S11 reload with nothing changed keeps the HUD as it is";; *) bad "S11 reload: $st";; esac

if [ -z "$WATCH" ]; then note "S12-S15 skipped (no ribbon-shell-watch)"; else
st=$(hudstate); case $st in *watch=1*) ok "S12 the daemon follows the compositor's windows (its own ribbon-shell-watch)";; *) bad "S12 no window helper: $st";; esac
# ---- S12 a game starts: detection, Show when a game starts, its own settings, its name ----
echo "S12 a game window (app id steam_app_620, as Proton's windows are) comes up"
R env $E $HUDCTL layout off; waitstate '*layout=off*'
lmark
R env $E $B/wlgame 203040 steam_app_620 "Portal 2 - Vulkan" >"$T0/game2.out" 2>&1 & G2=$!
waitsince 'game start key=steam:620 layout=compact' 100 && ok "S12 the HUD shows itself for the game, in the game's own layout (Compact)" || bad "S12 no game start: $(logsince | tail -4)"
logsince | grep -q 'front .*app=steam_app_620 game=1 key=steam:620 name=Portal 2$' && ok "S12 the window is the Steam game 620, named from its manifest (Portal 2)" || bad "S12 $(logsince | grep front | tail -2)"
logsince | grep -q 'settings key=steam:620 .*layout=compact position=top-left scale=125 opacity=70 contents=frametime,graph' && ok "S12 the record in effect is the game's own fields over Defaults" || bad "S12 $(logsince | grep settings | tail -2)"
waitsince 'surface mapped' 60; read_box
[ "$MBX" -lt 60 ] && [ "$MBY" -lt 60 ] && ok "S12 the HUD is at the game's corner (top left: box $MBX $MBY)" || bad "S12 box $MBX $MBY"
settle s12-game pxfar s12-game 60 60 "32 48 64" 20; p=$(px s12-game 60 60); ! near "$p" "32 48 64" 20 && ok "S12 it is drawn over the game ($p over 32 48 64)" || bad "S12 nothing over the game at 60,60 ($p)"
st=$(hudstate); case $st in *shown=1*game=1*key=steam:620*) ok "S12 state: shown, game, steam:620";; *) bad "S12 $st";; esac
logsince | grep -q 'front .*art=1 app=steam_app_620' && ok "S12 the game's art was found (Steam's library cache: 620_icon.jpg)" || bad "S12 no art: $(logsince | grep front | tail -1)"
# Full shows the header: the art at 16,16 of the panel (x 1.25 at the top left), 25 px, the cover's yellow sky
R env $E $HUDCTL layout full; waitsince 'surface mapped.*' 60; settle s12-art pxnear s12-art $((24 + 20 + 12)) $((24 + 20 + 5)) "242 228 92" 40
p=$(px s12-art $((24 + 20 + 12)) $((24 + 20 + 5)))
near "$p" "242 228 92" 40 && ok "S12 the header shows the game's art, not the pill ($p is the cover's sky)" || bad "S12 the header art is $p, not the cover"
R env $E $HUDCTL layout compact; waitstate '*layout=compact*mapped=1*'
# ---- S13 focus: unpinned it is up only while the game is in front; pinned it stays ----
echo "S13 the game loses focus (another window comes up), pin, and the game closes"
nh=$(count 'surface hidden' "$LOG")
R env $E $B/wlgame 101010 other "Other" >"$T0/game3.out" 2>&1 & G3=$!
i=0; while [ "$(count 'surface hidden' "$LOG")" -le "$nh" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
st=$(hudstate); case $st in *layout=compact*shown=0*) ok "S13 another window in front: the unpinned HUD is hidden (its layout is kept)";; *) bad "S13 $st";; esac
n=$(count 'surface mapped' "$LOG"); killgame 101010; i=0; while [ "$(count 'surface mapped' "$LOG")" -le "$n" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
st=$(hudstate); case $st in *shown=1*key=steam:620*) ok "S13 the game is in front again: the HUD is back";; *) bad "S13 $st";; esac
R env $E $HUDCTL pin 1; waitstate '*pinned=1*'
lmark; : > "$T0/game3.out"; R env $E $B/wlgame 101010 other "Other" >"$T0/game3.out" 2>&1 & G3=$!
# the daemon has seen the other window in front (its front line), then the state
waitsince 'front .*app=other ' 100 || bad "S13 the other window was not seen in front: $(logsince | tail -2)"
st=$(hudstate); case $st in *pinned=1*shown=1*) ok "S13 pinned: the HUD stays up when the game loses focus";; *) bad "S13 pinned: $st";; esac
# the pinned HUD is still the game's: another program's frame times (pid 4242, no game's process) are not shown as
# its numbers; the game's own process (4343: SteamAppId=620 in the stand-in /proc) is
mkdir -p "$T0/proc/4343"; printf 'thegame\0' > "$T0/proc/4343/cmdline"; printf 'SteamAppId=620\0' > "$T0/proc/4343/environ"
printf '4343 (thegame) S 1 4343\n' > "$T0/proc/4343/stat"
(i=0; while [ $i -lt 30 ]; do echo "pid=4242 3.0 3.1 2.9 3.0" >> "$T0/frames.txt"; sleep 0.1; i=$((i + 1)); done) & FEED=$!
if waitstate '*frames=1*' 2; then bad "S13 pinned, another window in front: another program's frame times are shown as the game's ($st)"
else ok "S13 pinned, another window in front: another program's frame times are not shown as the game's"; fi
wait $FEED 2>/dev/null
(i=0; while [ $i -lt 30 ]; do echo "pid=4343 10.0 10.1 9.9 10.0" >> "$T0/frames.txt"; sleep 0.1; i=$((i + 1)); done) & FEED=$!
waitstate '*frames=1*' 3 && ok "S13 pinned, another window in front: the game's own frame times are shown" || bad "S13 pinned: the game's frames not shown ($st)"
wait $FEED 2>/dev/null; rm -rf "$T0/proc/4343"
waitstate '*frames=0*' 10 || bad "S13 the frame times did not stop ($st)"
lmark; killgame 101010; waitsince 'front .*app=steam_app_620 ' 100 || bad "S13 the game did not come back in front"
R env $E $HUDCTL pin 0; waitstate '*pinned=0*'
lmark; killgame 203040
waitsince 'window closed layout=off' 100 && ok "S13 the game closed: its HUD is gone" || bad "S13 $(logsince | tail -3)"
waitstate '*layout=off*game=0*key=defaults*'; case $st in *layout=off*game=0*key=defaults*) ok "S13 back on the first window: off, Defaults";; *) bad "S13 $st";; esac
# ---- S14 a game whose overlay is off, and Show when a game starts off ----
echo "S14 overlay off for a game; Show when a game starts off"
lmark
R env $E $B/wlgame 203040 steam_app_1245620 "Elden" >"$T0/game2.out" 2>&1 & G2=$!
waitsince 'front .*key=steam:1245620' 100 || bad "S14 the game was not seen: $(logsince | tail -3)"
# a game start is logged with the front line it follows; the state query is a barrier for anything queued after it
hudstate >/dev/null; ! logsince | grep -q 'game start' && ok "S14 a game with its overlay off gets no HUD" || bad "S14 it got one"
F12; waitsince 'cycle ignored' 60 && ok "S14 Super+F12 does nothing for it (the overlay is off for steam:1245620)" || bad "S14 $(logsince | tail -3)"
lmark; killgame 203040; waitsince 'front .*game=0' 100 || bad "S14 the closed game is still in front: $(logsince | tail -2)"
store 'hud::put_default start 0'
lmark
R env $E $B/wlgame 203040 steam_app_620 "Portal 2" >"$T0/game2.out" 2>&1 & G2=$!
waitsince 'front .*key=steam:620' 100 || bad "S14 the game was not seen"
hudstate >/dev/null; ! logsince | grep -q 'game start' && ok "S14 Show when a game starts off: the game gets no HUD by itself" || bad "S14 it showed"
n=$(count 'surface mapped' "$LOG"); F12; i=0; while [ "$(count 'surface mapped' "$LOG")" -le "$n" ] && [ $i -lt 60 ]; do sleep 0.05; i=$((i + 1)); done
st=$(hudstate); case $st in *layout=fps*shown=1*key=steam:620*) ok "S14 Super+F12 still brings it up, with the game's settings";; *) bad "S14 $st";; esac
# ---- S15 the frame source: Automatic reads the layer's file, Compositor only the compositor's pipe ----
echo "S15 the frame source row, and gamescope's stats pipe through ribbon-gamescope (a stand-in gamescope)"
(i=0; while [ $i -lt 100 ]; do echo "8.9 9.1 8.7 8.9" >> "$T0/frames.txt"; sleep 0.1; i=$((i + 1)); done) & FEED=$!
waitstate '*frames=1*source=auto*'; case $st in *frames=1*source=auto*) ok "S15 Automatic: the layer's file gives frame numbers";; *) bad "S15 $st";; esac
lmark; store 'hud::put steam:620 source compositor'; waitsince 'settings key=steam:620 .*source=compositor' 80 || bad "S15 the source change was not followed"
waitstate '*frames=0*source=compositor*'; case $st in *frames=0*source=compositor*) ok "S15 Compositor: the layer's file is not read (No frame data without a compositor producer)";; *) bad "S15 $st";; esac
kill $FEED 2>/dev/null
# a stand-in gamescope: writes "fps=" lines to its --stats-path, as the real one writes its statistics
printf '%s\n' '#!/bin/sh' 'p=; while [ $# -gt 0 ]; do case $1 in --stats-path) p=$2; shift ;; --) shift; break ;; esac; shift; done' \
	'echo "stats-path=$p cmd=$*" > "$GS_OUT"' 'exec 3>"$p"; i=0; while [ $i -lt 30 ]; do echo "fps=144.0" >&3; sleep 0.1; i=$((i + 1)); done' > "$S/gamescope"
chmod +x "$S/gamescope"
R env $E GS_OUT=$T/gs.out $B/ribbon-gamescope -f -- thegame --arg >/dev/null 2>&1 &
poll 5 grep -qs stats-path "$T0/gs.out"; waitstate '*frames=1*source=compositor*'
grep -q "stats-path=$T/rt/ribbon-hud-stats cmd=thegame --arg" "$T0/gs.out" 2>/dev/null && ok "S15 ribbon-gamescope hands gamescope the HUD's pipe and the game's command ($(cat "$T0/gs.out"))" || bad "S15 wrapper: $(cat "$T0/gs.out" 2>/dev/null)"
case $st in *frames=1*source=compositor*) ok "S15 the compositor's pipe gives frame numbers (fps=144 lines)";; *) bad "S15 $st";; esac
lmark; killgame 203040; waitsince 'window closed' 100 || bad "S15 the game's window did not close: $(logsince | tail -2)"
fi

# ---- S16 the session's start: ribbon-hud start brings the daemon up only when the store asks for it ----
echo "S16 ribbon-hud start (labwc's autostart) and reload (Settings)"
R env $E $HUDCTL quit; i=0; while [ -e "$T0/rt/ribbon-hud.pid" ] && [ $i -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
store 'hud::put_default start 0; hud::drop steam:620 source'
# ribbon-hud start returns once the daemon is up or has left by itself
R env $E $HUDCTL start
[ ! -e "$T0/rt/ribbon-hud.pid" ] && ok "S16 nothing asks for Show when a game starts: no daemon is left running" || bad "S16 a daemon runs"
store 'hud::put_default start 1'
if [ -n "$WATCH" ]; then
: > "$T0/game2.out"; R env $E $B/wlgame 203040 steam_app_620 "Portal 2" >"$T0/game2.out" 2>&1 & G2=$!
i=0; while ! grep -q mapped "$T0/game2.out" 2>/dev/null && [ $i -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
lmark; R env $E $HUDCTL reload
waitsince 'game start key=steam:620 layout=compact' 100 && ok "S16 Settings turned it on (reload): the daemon starts and the game in front gets its HUD" || bad "S16 $(logsince | tail -4)"
lmark; killgame 203040; waitsince 'window closed' 100 || bad "S16 the game's window did not close"
else
R env $E $HUDCTL start; [ -e "$T0/rt/ribbon-hud.pid" ] && ok "S16 with Show when a game starts on, start leaves the daemon running" || bad "S16 no daemon"
fi

# ---- S10 the native drawing against the Tk canvas drawing of the same ops ----
echo "S10 the surface's drawing (cairo) against the Tk canvas drawing, 1440x900 boards scenes"
R env $E $HUDCTL quit; i=0; while [ -e "$T0/rt/ribbon-hud.pid" ] && [ $i -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
if [ -n "$ROOT" ]; then note "S10 is not run against a root (it needs the repo tree and xvfb on the host)"; else
for sc in default compact fps nofr menu; do
	R env $E wish8.6 -encoding utf-8 "$X/scene.tcl" native $sc $T/sc/n-$sc.png >"$T0/scene-n.out" 2>&1
	if [ ! -s "$T0/sc/n-$sc.png" ]; then bad "S10 $sc: no native picture: $(cat "$T0/scene-n.out" | tail -2)"; continue; fi
	read -r BX BY _ < "$T0/sc/n-$sc.png.box"
	convert -size ${W}x${H} xc:black "$T0/sc/n-$sc.png" -geometry +$BX+$BY -composite "$T0/sc/nf-$sc.png"
	FONTCONFIG_FILE=$FC xvfb-run -a -s "-screen 0 ${W}x${H}x24" wish8.6 -encoding utf-8 "$X/scene.tcl" canvas $sc "$T0/sc/c-$sc.png" >"$T0/scene-c.out" 2>&1
	[ -s "$T0/sc/c-$sc.png" ] || { bad "S10 $sc: no canvas picture: $(tail -2 "$T0/scene-c.out")"; continue; }
	r=$(compare -metric RMSE "$T0/sc/nf-$sc.png" "$T0/sc/c-$sc.png" null: 2>&1 | sed 's/.*(\(.*\))/\1/')
	echo "     $sc: RMSE $r (0 = identical, 1 = black against white)"
	awk -v r="$r" 'BEGIN { exit !(r < 0.04) }' && ok "S10 $sc: the surface and the canvas draw the same HUD (RMSE $r < 0.04)" || bad "S10 $sc differs from the canvas (RMSE $r)"
	cp "$T0/sc/nf-$sc.png" "$T0/shots/native-$sc.png"; cp "$T0/sc/c-$sc.png" "$T0/shots/canvas-$sc.png"
done
fi

[ -n "$(grep -i 'error' "$T0/labwc.log" | grep -v keysym)" ] && { echo "labwc errors:"; grep -i error "$T0/labwc.log" | grep -v keysym | head -5; }
[ -s "$T0/hud.log" ] && grep -q ' error ' "$T0/hud.log" && { bad "the daemon logged errors:"; grep ' error ' "$T0/hud.log" | head -3; }
[ "$fail" = 0 ] && echo "HUD surface: all checks passed"
exit $fail
