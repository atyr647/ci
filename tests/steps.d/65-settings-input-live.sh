#!/bin/sh
# Settings → Keyboard and mouse against a real labwc (TERM_ROOT=<a root with labwc 0.20>, as 65-term.sh): labwc runs
# with Ribbon's own rc.xml and environment, a terminal-style generated rc.xml, and the xdg-input layer that
# apps/settings/input.tcl generates, on XDG_CONFIG_DIRS in ribbon-session's order. The real backend makes the
# changes and sends labwc its SIGHUP. Checked in labwc's log: both generated files are read at start and again after
# every change, with no configuration error and no XKB error (every switch key, every Caps Lock choice, two layouts
# with variants); a variant that does not exist IS reported (so the check can fail) and going back to one layout
# takes it away again; the terminal rewriting its own file leaves ours in place. With an X server to run labwc on
# (Xvfb: labwc then has a real keyboard, so it compiles the keymap) and xset / xkbcomp in the root, the keyboard
# that X clients see is checked too: the repeat delay and rate, and the layouts in the keymap.
# NOT covered: libinput devices (there are none here), so the mouse and touchpad categories are only parsed.
# Skips without TERM_ROOT, tclsh8.6, or root's rights to chroot.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=${TERM_ROOT:-}
[ -n "$ROOT" ] || { echo "  skip Keyboard and mouse against labwc (TERM_ROOT is not set)"; exit 0; }
command -v tclsh8.6 >/dev/null 2>&1 || { echo "  skip Keyboard and mouse against labwc (no tclsh8.6)"; exit 0; }
[ -x "$ROOT/usr/bin/labwc" ] && [ "$(id -u)" = 0 ] || { echo "  skip Keyboard and mouse against labwc (no labwc in TERM_ROOT, or not root)"; exit 0; }
N=$PWD; D=$N/srcpkgs/ribbon-desktop/files
T0=$ROOT/tmp/rki.$$; T=/tmp/rki.$$
LPID=; XPID=; MP=; MS=; BOUND=
fails=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fails=$((fails + 1)); }; note() { echo "  note $*"; }
stop() { [ -n "$1" ] || return 0; kill "$1" 2>/dev/null; i=0; while kill -0 "$1" 2>/dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done; kill -9 "$1" 2>/dev/null; }
cleanup() {
	[ -n "${KEEPLOG:-}" ] && cp "$T0/labwc.log" "$KEEPLOG" 2>/dev/null
	stop "$LPID"; stop "$XPID"
	# Xwayland is labwc's child and goes with it; anything of ours left under this run's directory
	for p in $(pgrep -f "rki\.$$/" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
	[ -n "$MP" ] && umount "$ROOT/proc" 2>/dev/null
	[ -n "$MS" ] && umount "$ROOT/dev/shm" 2>/dev/null
	[ -n "$BOUND" ] && umount "$ROOT/dev" 2>/dev/null
	rm -rf "${T0:?}"
}
trap cleanup EXIT
mkdir -p "$T0/rt" "$T0/sys/labwc" "$T0/home/.config" "$T0/state/ribbon/xdg/labwc" "$ROOT/proc" "$ROOT/dev/shm"
chmod 700 "$T0/rt"
mountpoint -q "$ROOT/proc" || { mount -t proc proc "$ROOT/proc" 2>/dev/null && MP=1; }
if [ ! -e "$ROOT/dev/urandom" ]; then mount --bind /dev "$ROOT/dev" 2>/dev/null && BOUND=1
else mountpoint -q "$ROOT/dev/shm" || { mount -t tmpfs tmpfs "$ROOT/dev/shm" 2>/dev/null && MS=1; }; fi

# Ribbon's own layer, a terminal-style generated layer, the shell's margin layer and ours, in the session's order
cp "$D/xdg/labwc/rc.xml" "$D/xdg/labwc/environment" "$T0/sys/labwc/"
echo 'echo "$DISPLAY" > "$XDG_RUNTIME_DIR/display"' > "$T0/sys/labwc/autostart"
echo '<labwc_config><keyboard><keybind key="C-A-S-W-F12"><action name="None"/></keybind></keyboard></labwc_config>' > "$T0/state/ribbon/xdg/labwc/rc.xml"
mkdir -p "$T0/state/ribbon/xdg-display/labwc"
echo 'namespace eval display { proc take args {} }; source '"$D"'/shell/mod-margin.tcl
	puts -nonewline [margin::text ""]' | tclsh8.6 > "$T0/state/ribbon/xdg-display/labwc/rc.xml"
dirs=$(sed -n 's/^export XDG_CONFIG_DIRS="\(.*\)"$/\1/p' "$D/bin/ribbon-session" | head -1)
case $dirs in '$state/ribbon/xdg:$state/ribbon/xdg-display:$state/ribbon/xdg-input:/usr/share/ribbon/xdg:/etc/xdg') ok "ribbon-session puts the xdg-input layer between the margin's and Ribbon's";; *) bad "ribbon-session's XDG_CONFIG_DIRS is not what this test runs: $dirs";; esac
CDIRS=$T/state/ribbon/xdg:$T/state/ribbon/xdg-display:$T/state/ribbon/xdg-input:$T/sys
GEN=$T0/state/ribbon/xdg-input/labwc
L=$T0/labwc.log
# the real backend, as the Settings window would call it; it signals labwc itself through LABWC_PID
set_() { env -u XKB_DEFAULT_LAYOUT -u XKB_DEFAULT_VARIANT -u XKB_DEFAULT_OPTIONS -u RIBBON_INPUT_ROOT -u RIBBON_INPUT_RECONFIGURE HOME="$T0/home" XDG_CONFIG_HOME="$T0/home/.config" XDG_STATE_HOME="$T0/state" LABWC_PID="$LPID" \
	timeout -k 2 20 tclsh8.6 -encoding utf-8 tests/settings-input-live.tcl "$D" "$@"; }
mark() { M=$(wc -l < "$L"); }
since() { tail -n +$((M + 1)) "$L"; }
# wait (5 s at most) until labwc has read our rc.xml again since the mark, and has finished that reconfigure
reread() { i=0; while [ $i -lt 50 ]; do since | grep -q "read config file $T/state/ribbon/xdg-input/labwc/rc.xml" && break; sleep 0.1; i=$((i + 1)); done
	[ $i -lt 50 ] || return 1
	j=0; a=-1; while [ $j -lt 20 ]; do b=$(wc -l < "$L"); [ "$b" = "$a" ] && break; a=$b; sleep 0.15; j=$((j + 1)); done; return 0; }
# errors since the mark. Two are not ours and are left out: Ribbon's rc.xml uses a <snapping><range> form that labwc
# 0.20 calls deprecated, and Xwayland's first socket may be taken by another X server on this machine
# (nor are the X11 backend's own complaints about Xvfb).
errors() { since | grep -E '\[ERROR\]|xkbcommon: (ERROR|WARNING)|parser error' | grep -v -e '<snapping><range> is deprecated' -e 'xwayland/sockets.c' -e 'backend/x11/'; }
clean() { # WHAT: labwc read our files again and logged no error
	if ! reread; then bad "$1: labwc did not read the generated rc.xml again"; return 1; fi
	if ! kill -0 "$LPID" 2>/dev/null; then bad "$1: labwc is gone"; return 1; fi
	if errors >"$T0/err"; then sed 's/^/       /' "$T0/err"; bad "$1: labwc reported an error"; return 1; fi
	ok "$1"; }

# the board's state before labwc starts (as `ribbon-input generate` leaves it at login)
LPID=1 RIBBON_INPUT_RECONFIGURE=true; export RIBBON_INPUT_RECONFIGURE
env HOME="$T0/home" XDG_CONFIG_HOME="$T0/home/.config" XDG_STATE_HOME="$T0/state" tclsh8.6 -encoding utf-8 tests/settings-input-live.tcl "$D" \
	layout1=us REPEAT_DELAY=300 REPEAT_RATE=30 NUMLOCK=yes MOUSE_SPEED=0 MOUSE_ACCEL=yes TOUCH_SPEED=0.24 TOUCH_TAP=yes || bad "the settings before the start were refused"
unset RIBBON_INPUT_RECONFIGURE
[ -s "$GEN/rc.xml" ] && [ -s "$GEN/environment" ] || { bad "the generated files are not there"; exit 1; }

# an X server for labwc to run on, so that it has a keyboard (the headless backend has none and compiles no keymap)
X11=0
# (this machine's Xvfb will do: its socket is an abstract one, which the root shares; else the root's own)
XV=; if command -v Xvfb >/dev/null 2>&1; then XV=Xvfb; elif [ -x "$ROOT/usr/bin/Xvfb" ]; then XV="chroot $ROOT Xvfb"; fi
if [ -n "$XV" ]; then
	$XV -displayfd 3 -screen 0 1024x768x24 -nolisten tcp 3>"$T0/xdisp" >/dev/null 2>&1 &
	XPID=$!
	i=0; while [ ! -s "$T0/xdisp" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
	if [ -s "$T0/xdisp" ]; then X11=1; XD=:$(cat "$T0/xdisp"); else stop "$XPID"; XPID=; fi
fi
if [ $X11 = 1 ]; then BACK="WLR_BACKENDS=x11 DISPLAY=$XD"; else BACK="WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1"; note "no Xvfb: labwc runs headless, with no keyboard; the keymap checks are skipped"; fi
# shellcheck disable=SC2086
chroot "$ROOT" env -i PATH=/usr/bin:/bin $BACK WLR_RENDERER=pixman XDG_RUNTIME_DIR=$T/rt HOME=$T/home XDG_CONFIG_HOME=$T/home/.config XDG_CONFIG_DIRS=$CDIRS \
	labwc --merge-config -V >"$L" 2>&1 &
LPID=$!
i=0; while [ ! -s "$T0/rt/display" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$T0/rt/display" ] && kill -0 "$LPID" 2>/dev/null || { sed 's/^/       /' "$L" | tail -20; bad "labwc did not start"; exit 1; }
WDISP=$(cat "$T0/rt/display")
echo "  compositor: $(chroot "$ROOT" labwc -v | head -1) on $([ $X11 = 1 ] && echo "Xvfb $XD" || echo the headless backend)"

M=0
grep -q "read config file $T/sys/labwc/rc.xml" "$L" && grep -q "read config file $T/state/ribbon/xdg/labwc/rc.xml" "$L" && grep -q "read config file $T/state/ribbon/xdg-input/labwc/rc.xml" "$L" \
	&& grep -q "read config file $T/state/ribbon/xdg-display/labwc/rc.xml" "$L" \
	&& ok "labwc merges Ribbon's rc.xml, the terminal's, the margin's and ours" || bad "labwc did not read all four rc.xml files"
grep -q "read environment file $T/state/ribbon/xdg-input/labwc/environment" "$L" && ok "labwc reads our environment file" || bad "labwc did not read the generated environment file"
if errors >"$T0/err"; then sed 's/^/       /' "$T0/err"; bad "labwc reported an error at start"; else ok "labwc starts with the generated files and reports no error"; fi

# what X clients get (through Xwayland): the repeat settings and the keymap
# xset and xkbcomp: the root's, else this machine's (Xwayland's abstract socket is shared with the root)
xq() { if [ -x "$ROOT/usr/bin/$1" ]; then chroot "$ROOT" env DISPLAY="$WDISP" timeout 10 "$@" 2>/dev/null; else env DISPLAY="$WDISP" timeout 10 "$@" 2>/dev/null; fi; }
have() { [ -x "$ROOT/usr/bin/$1" ] || command -v "$1" >/dev/null 2>&1; }
XS=0; XK=0
if [ $X11 = 1 ]; then
	if have xset; then XS=1; else note "no xset: the repeat settings X clients see are not checked"; fi
	if have xkbcomp; then XK=1; else note "no xkbcomp: the keymap X clients get is not checked"; fi
fi
repeat_is() { i=0; while [ $i -lt 50 ]; do xq xset q | grep -q "auto repeat delay: *$1 *repeat rate: *$2\$" && return 0; sleep 0.1; i=$((i + 1)); done; return 1; }
# the keymap's symbols line (its name is the layouts and options it was built from) and its group names
keymap() { xq xkbcomp -w 0 "$WDISP" - | grep -e '^xkb_symbols' -e 'name\[group'; }
caps_is() { xq xkbcomp -w 0 "$WDISP" - | grep -A4 'key <CAPS>' | grep -q -- "$1"; }
symbols_have() { i=0; while [ $i -lt 50 ]; do keymap | grep -qF -- "$1" && return 0; sleep 0.1; i=$((i + 1)); done; return 1; }
if [ $XS = 1 ]; then
	repeat_is 300 30 && ok "X clients see the repeat settings (after 300 ms, 30 a second)" || bad "the repeat settings did not reach X clients: $(xq xset q | grep 'auto repeat delay')"
fi

# ---- changes, each made by the backend, which signals labwc
mark; set_ REPEAT_DELAY=450 REPEAT_RATE=12 NUMLOCK=no MOUSE_SPEED=-0.5 MOUSE_ACCEL=no MOUSE_NATURAL=yes MOUSE_LEFT=yes TOUCH_SPEED=1 TOUCH_TAP=no TOUCH_NATURAL=no TOUCH_DWT=no || bad "a change was refused"
clean "every repeat, mouse and touchpad row changed: labwc reconfigures without complaint"
if [ $XS = 1 ]; then repeat_is 450 12 && ok "  and X clients see the new repeat settings at once (450 ms, 12 a second)" || bad "the new repeat settings did not reach X clients: $(xq xset q | grep 'auto repeat delay')"; fi
mark; set_ 'layout1=us(dvorak)' 'layout2=de(neo)' SWITCH=win_space CAPS=esc || bad "a layout change was refused"
clean "two layouts with variants, Super Space, Caps Lock as Esc"
if [ $XK = 1 ]; then symbols_have 'name[group1]="English (Dvorak)"' && symbols_have 'name[group2]="German (Neo 2)"' && symbols_have 'group(win_space_toggle)' && caps_is Escape && ok "  and the keymap X clients get has both layouts, the switch key and the Caps Lock option" || bad "the keymap is not the one set: $(keymap | tr '\n' ' ')"; fi
for s in alt_shift ctrl_shift alt_space shifts win_space; do
	mark; set_ SWITCH=$s || bad "SWITCH=$s was refused"
	clean "switch key $s is an option XKB knows"
done
for c in ctrl caps esc; do
	mark; set_ CAPS=$c || bad "CAPS=$c was refused"
	clean "Caps Lock as $c"
done
if [ $X11 = 1 ]; then
	# a variant that does not exist passes the settings file's syntax check and must be reported by labwc
	mark; set_ 'layout1=us(zznovariant)' layout2= >/dev/null 2>&1
	if reread && errors | grep -qi 'keymap'; then ok "a variant that does not exist is reported by labwc (the check can fail)"; else bad "labwc did not report a variant that does not exist"; fi
	kill -0 "$LPID" 2>/dev/null || { bad "labwc is gone"; exit 1; }
fi
mark; set_ layout1=fr layout2= CAPS=caps || bad "going back to one layout was refused"
clean "one layout, no variant, no options: the empty values take the earlier ones back"
if [ $XK = 1 ]; then symbols_have 'name[group1]="French"' && caps_is Caps_Lock && ! keymap | grep -q -e 'capslock(' -e 'group2' -e 'group(' && ok "  and the keymap is French alone, with no option left" || bad "the keymap is not French alone: $(keymap | tr '\n' ' ')"; fi

# ---- the terminal rewrites its own generated rc.xml and reloads labwc: ours stays, and is read again
before=$(cksum < "$GEN/rc.xml")
mark
echo '<labwc_config><keyboard><keybind key="C-A-S-W-F11"><action name="None"/></keybind></keyboard><windowRules><windowRule identifier="ribbon-term-*" serverDecoration="no"/></windowRules></labwc_config>' > "$T0/state/ribbon/xdg/labwc/rc.xml.tmp"
mv "$T0/state/ribbon/xdg/labwc/rc.xml.tmp" "$T0/state/ribbon/xdg/labwc/rc.xml"
kill -HUP "$LPID"
clean "after the terminal rewrites its rc.xml our layer is read again"
[ "$(cksum < "$GEN/rc.xml")" = "$before" ] && ok "  and our file is as it was" || bad "our rc.xml changed"
if [ $XS = 1 ]; then repeat_is 450 12 && ok "  and the repeat settings still hold" || bad "the repeat settings were lost"; fi

[ $fails -eq 0 ] && echo "Keyboard and mouse against labwc: all checks passed" || { echo "Keyboard and mouse against labwc: $fails failed"; exit 1; }
