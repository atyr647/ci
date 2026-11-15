#!/bin/sh
# run.sh [ROOT] - proves that a layer-shell surface with exclusive keyboard takes the keys away from X11 clients.
# Headless labwc (as tests/test-ribbon-wall.sh), a Tk window on XWayland (stands in for the card), an X11
# "keylogger" (XI2 raw events + XQueryKeymap), and a virtual keyboard that types through Wayland.
# ROOT: run labwc, Xwayland and the clients inside this chroot (a Void root: labwc 0.20.3, Xwayland 24.1, Tk 8.6.18);
# without it, the host's (labwc 0.7.1, Xwayland 23.2.6, Tk 8.6.14).
set -u
cd "$(dirname "$0")/.." || exit 1
N=$(pwd); ROOT=${1:-}
T0=${TMPDIR:-/tmp}/rpk.$$; T=$T0; B=$T0/bin
if [ -n "$ROOT" ]; then T0=$ROOT/tmp/rpk.$$; T=/tmp/rpk.$$; B=$T/bin; fi   # T: as seen by the programs
R() { if [ -n "$ROOT" ]; then chroot "$ROOT" "$@"; else "$@"; fi; }
mkdir -p "$T0/bin" "$T0/rt" "$T0/labwc"; chmod 700 "$T0/rt"
S=$T0/bin
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
# signal our background jobs (reap TERM|KILL). jobs -p must run in this shell, not in $(...): dash's subshell has no job table
reap() { _rf=$(mktemp) || return 0; jobs -p >"$_rf"; while read -r _rp; do kill -"$1" "$_rp" 2>/dev/null; done <"$_rf"; rm -f "$_rf"; }
cleanup() { reap TERM; pkill -f "rpk\.$$/" 2>/dev/null; sleep 0.5; reap KILL; pkill -9 -f "rpk\.$$/" 2>/dev/null; if [ -n "$ROOT" ]; then umount "$ROOT/proc" "$ROOT/dev/shm" 2>/dev/null; fi; rm -rf "$T0"; }
trap cleanup EXIT

# ---- build (host toolchain; the programs run in the root against its libraries) ----
P=$(pkg-config --variable=pkgdatadir wayland-protocols)
make -s -C "$N" O="$S" CFLAGS="-O2 -Werror" || exit 1
wayland-scanner client-header test/virtual-keyboard-unstable-v1.xml "$S/virtual-keyboard-unstable-v1-client-protocol.h"
wayland-scanner private-code test/virtual-keyboard-unstable-v1.xml "$S/vk.c"
wayland-scanner client-header test/wlr-virtual-pointer-unstable-v1.xml "$S/wlr-virtual-pointer-unstable-v1-client-protocol.h"
wayland-scanner private-code test/wlr-virtual-pointer-unstable-v1.xml "$S/vp.c"
# pkg-config's flags are a list of words: the variable is split into them on purpose
WLK_FLAGS=$(pkg-config --cflags --libs wayland-client xkbcommon)
cc -O2 -Wall -Wextra -Werror -I"$S" -o "$S/vkbd" test/vkbd.c "$S/vk.c" "$S/vp.c" $WLK_FLAGS || exit 1
cc -O2 -Wall -Wextra -Werror -o "$S/xspy" test/xspy.c -lX11 -lXi || exit 1
cp test/card-stub.tcl test/compose.fixture "$S/"

# ---- headless labwc ----
[ -n "$ROOT" ] && { mkdir -p "$ROOT/proc" "$ROOT/dev/shm"; mount -t proc proc "$ROOT/proc" 2>/dev/null; mount -t tmpfs tmpfs "$ROOT/dev/shm" 2>/dev/null; }
echo '<labwc_config><core><decoration>server</decoration></core></labwc_config>' > "$T0/labwc/rc.xml"
echo 'echo "$DISPLAY" > "$XDG_RUNTIME_DIR/display"' > "$T0/labwc/autostart"
export XDG_RUNTIME_DIR=$T/rt HOME=$T XDG_CONFIG_HOME=$T/c
R env WAYLAND_DISPLAY='' WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1 \
	XDG_RUNTIME_DIR=$T/rt HOME=$T labwc -C "$T/labwc" >"$T0/labwc.log" 2>&1 &
i=0; while [ ! -s "$T0/rt/display" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
sock=; for f in "$T0"/rt/wayland-*; do case $f in *.lock) ;; *) [ -S "$f" ] && sock=${f##*/} ;; esac; done
[ -n "$sock" ] || { cat "$T0/labwc.log"; echo "no labwc"; exit 1; }
DISP=$(cat "$T0/rt/display")
echo "compositor: $(R labwc -v | head -1), $(R Xwayland -version 2>&1 | sed -n 1p | sed 's/.*Version //'), socket $sock, X display $DISP"
E="XDG_RUNTIME_DIR=$T/rt WAYLAND_DISPLAY=$sock DISPLAY=$DISP HOME=$T"

# virtual keyboard first (a headless seat has no keyboard until one exists)
mkfifo "$T0/vk"
R env $E $B/vkbd <"$T0/vk" >"$T0/vkbd.out" 2>&1 &
exec 9>"$T0/vk"
vk() { echo "$@" >&9; n=$(wc -l < "$T0/vkbd.out"); i=0; while [ "$(wc -l < "$T0/vkbd.out")" -le "$n" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done; }
mkfifo "$T0/spy.in"
R env $E $B/xspy <"$T0/spy.in" >"$T0/spy.out" 2>&1 &
exec 8>"$T0/spy.in"
R env $E tclsh /dev/null 2>/dev/null
# Tk: wish, else (a host with only the versioned name) the wish of the root's tclsh
WISH=wish; R sh -c 'command -v wish' >/dev/null 2>&1 || WISH=wish$(echo 'puts [info tclversion]' | R tclsh 2>/dev/null)
R env $E $WISH $B/card-stub.tcl "$T/tk.log" >"$T0/wish.out" 2>&1 &
i=0; while ! grep -q 'tk mapped' "$T0/tk.log" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
sleep 0.5
echo "spy: $(head -1 "$T0/spy.out")"
grep -h 'tk ' "$T0/tk.log" | tr '\n' ';'; echo
count() { grep -c "$1" "$2" 2>/dev/null || true; }
snap() { SPY0=$(count 'press' "$T0/spy.out"); RAW0=$(count 'raw press' "$T0/spy.out"); KM0=$(count 'keymap press' "$T0/spy.out"); TK0=$(count 'tk key' "$T0/tk.log"); }
delta() { RAW=$(( $(count 'raw press' "$T0/spy.out") - RAW0 )); KM=$(( $(count 'keymap press' "$T0/spy.out") - KM0 )); TK=$(( $(count 'tk key' "$T0/tk.log") - TK0 )); }

# ---- S0 control: no helper. The harness must see keys, or the later zeros mean nothing ----
echo "S0 control (no helper): type 'abc' with the Tk window focused"
snap; vk type abc; sleep 0.3; delta
echo "     X11 spy: raw=$RAW keymap-poll=$KM   Tk window: $TK"
[ "$RAW" = 3 ] && [ "$TK" = 3 ] && ok "S0 harness works: the spy and Tk both get all 3 keys" || bad "S0 control (the harness cannot see keys; later zeros prove nothing)"

# ---- S1 the helper holds the keyboard ----
mkfifo "$T0/k.in"
R env $E XCOMPOSEFILE=$B/compose.fixture $B/ribbon-polkit-keys --secret-fd 3 <"$T0/k.in" >"$T0/k.out" 3>"$T0/secret" 2>"$T0/k.err" &
KP=$!
exec 7>"$T0/k.in"
i=0; while ! grep -q '^ready' "$T0/k.out" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
grep -q '^ready' "$T0/k.out" && ok "S1 helper got keyboard focus (wl_keyboard.enter on its surface)" || { bad "S1 helper never got focus"; cat "$T0/k.err"; }
echo "S1 type 'abc', BackSpace, 'de', Return"
snap; vk type abc; vk key BackSpace; vk type de; vk key Return; sleep 0.2
[ ! -s "$T0/secret" ] && ok "S1 Return alone writes nothing: the card (agent) decides what Enter means" || bad "S1 Return wrote the secret"
echo submit >&7; sleep 0.3; delta
echo "     X11 spy: raw=$RAW keymap-poll=$KM   Tk window: $TK"
echo "     helper said: $(tr '\n' ' ' < "$T0/k.out")"
[ "$RAW" = 0 ] && [ "$KM" = 0 ] && ok "S1 X11 spy saw 0 keys (XI2 raw + XQueryKeymap)" || bad "S1 the X11 spy saw keys: raw=$RAW keymap=$KM"
[ "$TK" = 0 ] && ok "S1 the Tk window (X11, even though it was focused before) got 0 keys" || bad "S1 Tk got $TK keys"
[ "$(cat "$T0/secret")" = "abde" ] && ok "S1 the helper wrote the exact password to the secret fd" || bad "S1 secret was '$(cat "$T0/secret")'"
[ "$(tr '\n' ' ' < "$T0/k.out")" = "ready n 1 n 2 n 3 n 2 n 3 n 4 enter n 0 " ] && ok "S1 the card's event stream carries counts only, never characters" || bad "S1 stream"
grep -q 'abc\|abde' "$T0/k.out" && bad "S1 the stream leaks the text"

# ---- S1b navigation and echo mode: Tab, arrows and Space are events when focus is not in the field ----
echo "S1b mode nav: Tab, Down, Up, Shift+Tab, space, then letters (not collected); then mode echo"
: > "$T0/k.mark"; L0=$(wc -l < "$T0/k.out")
echo "mode nav" >&7; vk key Tab; vk key Down; vk key Up; vk key ShiftTab; vk type " q"; sleep 0.3
got=$(tail -n +$((L0 + 1)) "$T0/k.out" | tr '\n' ' ')
[ "$got" = "n 0 tab down up btab space " ] && ok "S1b nav mode: tab down up btab space are events, 'q' is ignored" || bad "S1b nav stream: $got"
L0=$(wc -l < "$T0/k.out"); echo "mode echo" >&7; vk type hi; sleep 0.3
got=$(tail -n +$((L0 + 1)) "$T0/k.out" | tr '\n' ' ')
[ "$got" = "n 0 n 1 t h n 2 t hi " ] && ok "S1b echo mode shows the text (a prompt PAM says is not secret)" || bad "S1b echo stream: $got"
echo "mode text" >&7; sleep 0.2
echo "clear" >&7; sleep 0.2
[ "$(grep -c '^t ' "$T0/k.out")" = 2 ] && ok "S1b hidden mode never sends text again" || bad "S1b t lines"
grep -q "^t .*abde" "$T0/k.out" && bad "S1b the earlier password appeared in a t line"
snap

# ---- S1c dead keys and Compose (us intl; the helper's Compose table is test/compose.fixture) ----
echo "S1c keymap us(intl): ´e \`a ¨q, ´j (no sequence), ´BackSpace, b BackSpace BackSpace ¨q, submit"
vk keymap us intl; sleep 0.2; L0=$(wc -l < "$T0/k.out")
vk sym dead_acute; sleep 0.2
[ "$(wc -l < "$T0/k.out")" = "$L0" ] && ok "S1c a dead key alone types nothing (no dot yet)" || bad "S1c the dead key alone: $(tail -n 1 "$T0/k.out")"
vk type e; vk sym dead_grave; vk type a; vk sym dead_diaeresis; vk type q
vk sym dead_acute; vk type j; vk sym dead_acute; vk key BackSpace; vk type b; vk key BackSpace; vk key BackSpace
vk sym dead_diaeresis; vk type q; sleep 0.3
got=$(tail -n +$((L0 + 1)) "$T0/k.out" | tr '\n' ' ')
[ "$got" = "n 1 n 2 n 3 n 4 n 3 n 2 n 3 " ] && ok "S1c each composed character counts once; a cancelled sequence and a forgotten dead key add nothing" || bad "S1c stream: $got"
echo submit >&7; sleep 0.3
[ "$(tail -n 1 "$T0/secret")" = "éà☃" ] && ok "S1c the secret is the composed text 'éà☃' (the fixture's own sequence: its table is the one used)" || bad "S1c secret was '$(tail -n 1 "$T0/secret")'"
echo "S1c 'ab', a dead key, Ctrl+BackSpace (clears all, the dead key with it), 'e', submit"
L0=$(wc -l < "$T0/k.out")
vk type ab; vk sym dead_acute; vk key CtrlBackSpace; vk type e; sleep 0.3
got=$(tail -n +$((L0 + 1)) "$T0/k.out" | tr '\n' ' ')
[ "$got" = "n 1 n 2 n 0 n 1 " ] && ok "S1c Ctrl+BackSpace with a dead key pending still clears the field" || bad "S1c Ctrl+BackSpace with a dead key pending: $got"
echo submit >&7; sleep 0.3
[ "$(tail -n 1 "$T0/secret")" = "e" ] && ok "S1c the dead key went with the cleared field (secret 'e')" || bad "S1c secret after Ctrl+BackSpace was '$(tail -n 1 "$T0/secret")'"
vk keymap us; sleep 0.2
snap

# ---- S2 clicking on the Tk window must not steal the keyboard ----
echo "S2 click on the Tk window (virtual pointer), then type 'xyz'"
snap; CL0=$(count 'tk click' "$T0/tk.log")
vk move 640 360; vk click; sleep 0.2
CL=$(( $(count 'tk click' "$T0/tk.log") - CL0 ))
[ "$CL" = 1 ] && ok "S2 the click reached the Tk window (so it is a fair test of focus stealing)" || bad "S2 the click did not reach Tk ($CL)"
snap; vk type xyz; sleep 0.3; delta
echo "     X11 spy: raw=$RAW keymap-poll=$KM   Tk window: $TK   helper: $(tail -n 3 "$T0/k.out" | tr '\n' ' ')"
[ "$RAW" = 0 ] && [ "$TK" = 0 ] && ok "S2 still 0 keys for X11 after a click on the X11 window" || bad "S2 click stole the keyboard (raw=$RAW tk=$TK)"
[ "$(tail -n 1 "$T0/k.out")" = "n 3" ] && ok "S2 helper kept the keyboard: 'xyz' arrived there" || bad "S2 helper stream: $(tail -n 1 "$T0/k.out")"

# ---- S2b a card that appears AFTER the helper (the real order of events is helper first, card second) ----
echo "S2b a new Tk window maps while the helper holds the keyboard; type 'mno'"
R env $E $WISH $B/card-stub.tcl "$T/tk2.log" >"$T0/wish2.out" 2>&1 &
W2=$!
i=0; while ! grep -q 'tk mapped' "$T0/tk2.log" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
sleep 0.5; snap; TK20=$(count 'tk key' "$T0/tk2.log"); vk type mno; sleep 0.3; delta
TK2=$(( $(count 'tk key' "$T0/tk2.log") - TK20 ))
echo "     X11 spy: raw=$RAW   old Tk: $TK   new Tk (focus -force): $TK2   helper: $(tail -n 1 "$T0/k.out")"
[ "$RAW" = 0 ] && [ "$TK" = 0 ] && [ "$TK2" = 0 ] && ok "S2b a window that maps (and calls focus -force) later still gets nothing" || bad "S2b raw=$RAW tk=$TK tk2=$TK2"
[ "$(grep -c '^lost' "$T0/k.out")" = 0 ] && ok "S2b the helper never reported 'lost' through all of this" || bad "S2b helper lost focus"

# ---- S2c key repeat: hold a key for 1.5 s ----
echo "S2c hold 'k' for 1.5 s (the helper repeats it itself: Wayland sends no repeats)"
N0=$(tail -n 1 "$T0/k.out" | cut -d' ' -f2); vk hold k 1500; sleep 0.3
N1=$(tail -n 1 "$T0/k.out" | cut -d' ' -f2); sleep 0.6; N2=$(tail -n 1 "$T0/k.out" | cut -d' ' -f2)
echo "     count $N0 -> $N1 (settled at $N2 half a second later)"
[ $((N1 - N0)) -ge 8 ] && [ "$N1" = "$N2" ] && ok "S2c repeat works ($((N1 - N0)) characters) and stops on release" || bad "S2c repeat: $N0 -> $N1 -> $N2"
echo "S2d a second layer-shell client takes exclusive keyboard (a hostile or buggy native client)"
mkfifo "$T0/kb.in"; R env $E $B/ribbon-polkit-keys 3>"$T0/secretB" <"$T0/kb.in" >"$T0/kb.out" 2>&1 & KB=$!; exec 5>"$T0/kb.in"
sleep 1; vk type zz; sleep 0.3
echo "     first helper: $(tail -n 2 "$T0/k.out" | tr '\n' ' ')   second: $(tr '\n' ' ' < "$T0/kb.out")"
if grep -q '^lost' "$T0/k.out"; then ok "S2d the first helper is TOLD it lost the keyboard ('lost'): the card must stop and warn"; else bad "S2d first helper got no 'lost' (it would keep showing a field nobody types into)"; fi
echo quit >&5; wait $KB 2>/dev/null; exec 5>&-

# ---- S3 the helper goes away: keys return to X11 ----
echo "S3 helper quits; type 'qrs'"
echo quit >&7; wait $KP 2>/dev/null; sleep 0.3
snap; TK20=$(count 'tk key' "$T0/tk2.log"); vk type qrs; sleep 0.3; delta
TK2=$(( $(count 'tk key' "$T0/tk2.log") - TK20 ))
echo "     X11 spy: raw=$RAW keymap-poll=$KM   Tk window that has the focus (the newest): $TK2"
kill $W2 2>/dev/null
[ "$RAW" = 3 ] && [ "$TK2" = 3 ] && ok "S3 after the helper exits the X11 clients get keys again (S1's zeros were the helper's doing)" || bad "S3 raw=$RAW tk2=$TK2"

# ---- S4 resources ----
echo "S4 helper costs"
mkfifo "$T0/k2.in"; R env $E $B/ribbon-polkit-keys 3>/dev/null <"$T0/k2.in" >"$T0/k2.out" 2>&1 & KP=$!; exec 6>"$T0/k2.in"; sleep 1
pid=$(pgrep -f "ribbon-polkit-keys" | tail -1)
grep -E 'VmRSS|VmHWM' /proc/$pid/status | tr '\n' ' '; grep -E '^Pss:' /proc/$pid/smaps_rollup
XP=$(pgrep -x Xwayland | head -1); [ -n "$XP" ] && { printf '%s' "Xwayland (shared with every X client): "; grep -E 'VmRSS' /proc/$XP/status; }
strip -o "$S/k.stripped" "$S/ribbon-polkit-keys"; echo "     binary: $(wc -c < $S/ribbon-polkit-keys) bytes, stripped $(wc -c < $S/k.stripped)"
echo quit >&6; wait $KP 2>/dev/null

[ -n "$(grep -i 'error' "$T0/labwc.log" | grep -v keysym)" ] && { echo "labwc errors:"; grep -i error "$T0/labwc.log" | grep -v keysym | head -5; }
exit $fail
