#!/bin/sh
# The login screen in labwc, not cage (STACK S8, §3.4 option A): ribbon-greeter runs labwc -C on the locked-down
# config in xdg/labwc-greeter with itself as the startup command, which runs the greeter and then ends labwc.
#   1. the config parses, binds one key and one mouse button to nothing (so labwc loads none of its defaults), has
#      no Execute or Exit anywhere and empty menus; nothing Ribbon ships runs cage, and no template depends on it;
#   2. under a headless labwc (WLR_BACKENDS=headless): a stand-in for the greeter's window (tests/greeter-labwc/
#      standin.tcl, the window ui.tcl makes) covers the whole output with no frame (grim); labwc's default keys,
#      typed on a virtual keyboard (tests/greeter-labwc/chords.c), close it and run a terminal with an empty
#      config (the control), and do nothing at all with the greeter's; and when the greeter exits, labwc does too,
#      so greetd's greeter session ends.
# Needs labwc, wish8.6, grim, cc, wayland-scanner and wayland-client/xkbcommon headers; skips what it cannot do.
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
D=$ROOT/srcpkgs/ribbon-desktop/files
CFG=$D/xdg/labwc-greeter
G=$D/greeter/ribbon-greeter
status=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; status=1; }

# ---- 1. the config and the scripts
if command -v xmllint >/dev/null 2>&1; then
	if xmllint --noout "$CFG/rc.xml" "$CFG/menu.xml" 2>/dev/null; then ok "rc.xml and menu.xml parse"; else bad "the greeter's labwc config does not parse"; fi
	nk=$(xmllint --xpath 'count(//keyboard/keybind)' "$CFG/rc.xml"); nm=$(xmllint --xpath 'count(//mouse//mousebind)' "$CFG/rc.xml")
	na=$(xmllint --xpath "count(//keybind/action[@name!='None'] | //mousebind/action[@name!='None'])" "$CFG/rc.xml")
	[ "$nk" -ge 1 ] && [ "$nm" -ge 1 ] && [ "$na" = 0 ] && ok "one key and one mouse button bound to None (labwc's defaults stay out)" ||
		bad "rc.xml: $nk keybinds, $nm mousebinds, $na actions other than None"
	ne=$(xmllint --xpath "count(//action[@name='Execute' or @name='Exit' or @name='Reconfigure' or @name='ShowMenu'])" "$CFG/rc.xml" "$CFG/menu.xml" 2>/dev/null | tr -d '\n')
	ni=$(xmllint --xpath 'count(//menu/*)' "$CFG/menu.xml")
	{ [ -z "$ne" ] || [ "$ne" = 0 ] || [ "$ne" = 00 ]; } && [ "$ni" = 0 ] && ok "no Execute, Exit, Reconfigure or ShowMenu; root and client menus empty" ||
		bad "the greeter's config can run or show something (actions $ne, menu items $ni)"
	[ "$(xmllint --xpath "string(//windowRule[@identifier='ribbon-greeter']/@serverDecoration)" "$CFG/rc.xml")" = no ] &&
		ok "the greeter's window rule: no frame" || bad "no frameless window rule for ribbon-greeter"
else echo "  skip the config checks (no xmllint)"; fi
[ ! -e "$CFG/autostart" ] && [ ! -e "$CFG/environment" ] && ok "no autostart or environment file in the greeter's config" ||
	bad "the greeter's labwc config has an autostart or environment file"
if sh -n "$G" && ! grep -Eq '^[^#]*\bcage\b' "$G" && grep -q 'labwc -C "\$cfg"' "$G"; then ok "ribbon-greeter starts labwc -C, not cage"; else bad "ribbon-greeter still runs cage"; fi
hits=$(grep -n -w cage srcpkgs/*/template build/install/deps.map build/install/manifests/*.manifest build/packages/*.list 2>/dev/null |
	grep -v ':[0-9]*:[[:space:]]*#' || true)
[ -z "$hits" ] && ok "no template, deps.map row, manifest or package list names cage" || bad "cage is still a dependency: $hits"

# ---- 2. headless labwc
for t in labwc wish8.6 grim cc wayland-scanner pkg-config python3; do
	command -v $t >/dev/null 2>&1 || { echo "  skip the headless labwc checks (no $t)"; exit $status; }
done
pkg-config --exists wayland-client xkbcommon || { echo "  skip the headless labwc checks (no wayland-client / xkbcommon)"; exit $status; }
T=$(mktemp -d) || exit 1
PIDS=
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; [ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
XML=$ROOT/tests/hud-native/virtual-keyboard-unstable-v1.xml
# pkg-config's output is a list of flags, split into words on purpose
# shellcheck disable=SC2046
wayland-scanner client-header "$XML" "$T/virtual-keyboard-unstable-v1-client-protocol.h" && wayland-scanner private-code "$XML" "$T/vk.c" &&
	cc -O2 -Wall -Wextra -Werror -I"$T" -o "$T/chords" tests/greeter-labwc/chords.c "$T/vk.c" $(pkg-config --cflags --libs wayland-client xkbcommon) ||
	{ bad "the key tool does not build"; exit 1; }
# the programs labwc's default keys run, as stand-ins that say they ran
mkdir -p "$T/bin"
for p in alacritty foot xterm bemenu-run amixer brightnessctl pactl wpctl; do
	printf '#!/bin/sh\necho "%s $*" >> "%s/ran"\n' "$p" "$T" > "$T/bin/$p"; chmod +x "$T/bin/$p"
done
# run CONFIG-DIR NAME: ribbon-greeter with the stand-in under a headless labwc; sets RT and GP (its PID)
run() {
	S=$T/$2; RT=$T/rt-$2; mkdir -p "$S" "$RT" "$S/home"; chmod 700 "$RT"
	env -u WAYLAND_DISPLAY -u DISPLAY HOME="$S/home" XDG_RUNTIME_DIR="$RT" PATH="$T/bin:$PATH" STANDIN_DIR="$S" \
		XDG_CONFIG_HOME="$S/home/.config" XKB_DEFAULT_LAYOUT=us \
		WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1 \
		RIBBON_GREETER_LABWC="$1" RIBBON_GREETER_MAIN="$ROOT/tests/greeter-labwc/standin.tcl" \
		timeout -k 2 60 sh "$G" >"$S/log" 2>&1 &
	GP=$!; PIDS="$PIDS $GP"
	i=0; while [ ! -e "$S/mapped" ] && [ $i -lt 200 ] && kill -0 $GP 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
	WL=$(find "$RT" -maxdepth 1 -regex '.*/wayland-[0-9]*' -printf '%f\n' 2>/dev/null | sort | head -n1)
	[ -e "$S/mapped" ] && [ -n "$WL" ]
}
keys() { # CHORD...: typed on the virtual keyboard of the labwc in $RT
	printf '%s\n' "$@" | env XDG_RUNTIME_DIR="$RT" WAYLAND_DISPLAY="$WL" "$T/chords" > "$T/chords.out" 2>&1
	grep -q bad "$T/chords.out" && echo "       chords: $(grep bad "$T/chords.out" | tr '\n' ' ')"
	sleep 1   # what a key starts has a second to show (there is no event to wait for when nothing should happen)
}
gone() { # PID: it ends within 10 s
	i=0; while kill -0 $1 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
	! kill -0 $1 2>/dev/null
}

# the control: an empty config gets labwc's defaults, and the same keys reach them
mkdir -p "$T/empty"
if run "$T/empty" control; then
	keys "Super_L Return" "Alt_L F3"
	k1=$(cat "$T/ran" 2>/dev/null | tr '\n' ';'); : > "$T/ran"
	keys "Alt_L F4"
	if [ -n "$k1" ] && [ -e "$T/control/closed" ]; then ok "control: with labwc's defaults these keys run a program ($k1) and close the greeter"
	else bad "control: the typed keys did not reach labwc's defaults (ran: '$k1', closed: $([ -e "$T/control/closed" ] && echo yes || echo no))"; fi
	gone $GP && ok "control: the greeter closed, so labwc ended" || bad "control: labwc kept running after the greeter closed"
else
	sed 's/^/       /' "$T/control/log" | tail -n 5; bad "control: the stand-in greeter did not come up under labwc"
fi

: > "$T/ran"
if run "$CFG" locked; then
	ok "ribbon-greeter brings up the greeter in labwc with the greeter config"
	env XDG_RUNTIME_DIR="$RT" WAYLAND_DISPLAY="$WL" grim -t ppm "$T/shot.ppm" 2>/dev/null
	if python3 - "$T/shot.ppm" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
parts = d.split(maxsplit=4)
w, h = int(parts[1]), int(parts[2]); px = parts[4]
bad = [(x, y) for x in (0, w // 2, w - 1) for y in (0, h // 2, h - 1) if tuple(px[(y * w + x) * 3:(y * w + x) * 3 + 3]) != (0x12, 0x34, 0x56)]
sys.exit(1 if bad or w < 640 else 0)
PY
	then ok "the greeter covers the whole output with no frame (corners, edges and middle are its colour)"
	else bad "the greeter is framed or does not cover the output"; fi
	keys "Alt_L F4" "Alt_L Tab" "Super_L Return" "Alt_L F3" "Alt_L space" "Super_L a" "Super_L Left" "Alt_L Left" \
		"XF86AudioMute" "XF86AudioRaiseVolume" "XF86MonBrightnessUp" "Control_L Alt_L BackSpace"
	if [ ! -s "$T/ran" ] && [ ! -e "$T/locked/closed" ] && kill -0 $GP 2>/dev/null; then
		ok "labwc's default keys (close, switch, terminal, launcher, window menu, maximize, snap, volume, brightness) do nothing"
	else bad "a key got through: ran '$(cat "$T/ran" 2>/dev/null | tr '\n' ';')', closed: $([ -e "$T/locked/closed" ] && echo yes || echo no)"; fi
	touch "$T/locked/quit"
	gone $GP && ok "the greeter exits (a session started): labwc ends with it" || bad "labwc kept running after the greeter exited"
	grep -i 'error' "$T/locked/log" | grep -i -E 'rc\.xml|menu\.xml|config' | sed 's/^/       /'
else
	sed 's/^/       /' "$T/locked/log" | tail -n 5; bad "the stand-in greeter did not come up under labwc with the greeter config"
fi
exit $status
