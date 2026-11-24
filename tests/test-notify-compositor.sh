#!/bin/sh
# The notification surfaces under a real compositor (headless labwc + XWayland, captured with grim): STYLE §19 says
# there is no card, the text is set on the desktop over a scrim. Over a light window, the popup's entry must not be
# an opaque box (the pixels beside its text follow the scrim, with no edge where the old box ended, and its text is
# there), and the history must be a scrim that fades to the right, not a slab. Skips without labwc, grim, wlr-randr,
# ImageMagick or a C compiler for rbnalpha (RBNALPHA_LIB names a built one).
set -u
cd "$(dirname "$0")/.." || exit 1
for t in labwc grim wlr-randr convert wish8.6 Xwayland; do command -v $t >/dev/null 2>&1 || { echo "  skip notifications under a compositor (no $t)"; exit 0; }; done
F=$PWD/srcpkgs/ribbon-desktop/files
T=$(mktemp -d); PIDS=
trap 'kill $PIDS 2>/dev/null; sleep 0.2; rm -rf "$T"' EXIT
if [ -z "${RBNALPHA_LIB:-}" ] || [ ! -f "$RBNALPHA_LIB" ]; then
	mkdir -p "$T/rbn"; make -s -C "$F/rbnalpha" O="$T/rbn" >/dev/null 2>&1 || { echo "  skip notifications under a compositor (rbnalpha does not build)"; exit 0; }
	RBNALPHA_LIB=$T/rbn/librbnalpha.so
fi
export RBNALPHA_LIB
mkdir -p "$T/rt" "$T/h/.config/ribbon" "$T/c" "$T/s" "$T/labwc"; chmod 700 "$T/rt"
cp "$F/themes/palettes/ribbon.conf" "$T/h/.config/ribbon/palette.conf"
echo '<labwc_config><core><decoration>server</decoration></core></labwc_config>' > "$T/labwc/rc.xml"
cat > "$T/light.tcl" <<'TCL'
wm geometry . 1000x640+40+120
. configure -background #e8e2d8
TCL
# labwc runs autostart once XWayland is up: it says which display that is
echo "echo \"\$DISPLAY\" > $T/display" > "$T/labwc/autostart"
export XDG_RUNTIME_DIR=$T/rt HOME=$T/h XDG_CACHE_HOME=$T/c XDG_STATE_HOME=$T/s XDG_CONFIG_HOME=$T/h/.config
unset WAYLAND_DISPLAY DISPLAY; export DBUS_SESSION_BUS_ADDRESS=unix:path=$T/none
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1 labwc -C "$T/labwc" >"$T/labwc.log" 2>&1 &
PIDS="$PIDS $!"
i=0; while [ ! -s "$T/display" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
[ -s "$T/display" ] || { echo "  skip notifications under a compositor (labwc does not start headless here)"; exit 0; }
DISPLAY=$(cat "$T/display"); WAYLAND_DISPLAY=; for s in "$T"/rt/wayland-[0-9]*; do case ${s##*/} in *.lock) ;; *) WAYLAND_DISPLAY=${s##*/}; break ;; esac; done; export DISPLAY WAYLAND_DISPLAY
wlr-randr --output HEADLESS-1 --custom-mode 1440x900 >/dev/null 2>&1
sleep 0.5
wish8.6 "$T/light.tcl" >/dev/null 2>&1 & PIDS="$PIDS $!"
sleep 1
fails=0
ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
# the brightness (0 to 255) of a pixel, and the brightest pixel of a region W H X Y
px() { convert "$3" -crop 1x1+$1+$2 +repage -colorspace Gray -format '%[fx:int(255*u.p{0,0})]' info: 2>/dev/null; }
peak() { convert "$5" -crop $1x$2+$3+$4 +repage -colorspace Gray -format '%[fx:int(255*maxima)]' info: 2>/dev/null; }
shell() { # the shell with a scene's environment, until killed; each scene starts from an empty state folder, so the
	# history the popup scene saved (nhist::save, $XDG_STATE_HOME/ribbon/notifications) is not in the history scene's list
	rm -rf "$T/s"; mkdir -p "$T/s"
	env "$@" NOTIFY_HOLD=20000 timeout -k 5 40 wish8.6 -encoding utf-8 "$F/shell/main.tcl" -name ribbon-shell >"$T/shell.out" 2>&1 &
	SHELL_PID=$!; PIDS="$PIDS $SHELL_PID"
}
# capture until the region W H X Y holds bright text (at most 15 s)
shot() { i=0; while [ $i -lt 30 ]; do grim "$T/$1.png" 2>/dev/null; p=$(peak $2 $3 $4 $5 "$T/$1.png"); [ "${p:-0}" -ge 200 ] && return 0; sleep 0.5; i=$((i+1)); done; return 1; }

# the popup: the progress board's entry (its foot at y 836, the first keycap's label "Pause" at 78,817, under the
# light window; the old box was x 20 to 440)
shell NOTIFY_SCENE=progress RIBBON_SHELL_TEST=tests/shell-notify.tcl
if shot popup 40 16 78 817; then
	ok "the popup's text is on screen, bright"
	in=$(px 430 698 "$T/popup.png"); out=$(px 452 698 "$T/popup.png"); gap=$(px 430 676 "$T/popup.png")
	[ "$in" -ge 30 ] && ok "beside the text the light window shows through the scrim (brightness $in, an opaque card is 0)" || bad "the popup is an opaque card: brightness $in beside its text"
	d=$((in - out)); [ ${d#-} -le 12 ] && ok "no edge where the old box ended (inside $in, outside $out)" || bad "a hard edge at the entry's right: inside $in, outside $out"
	d=$((in - gap)); [ ${d#-} -le 16 ] && ok "no edge between the entry and the one-liner above it ($in, $gap)" || bad "a hard edge above the entry: $in against $gap"
	far=$(px 900 500 "$T/popup.png"); [ "$far" -ge 200 ] && ok "away from the corner the scrim is gone (brightness $far)" || bad "the scrim covers the window far from the corner: $far"
	keep=${NOTIFY_KEEP:-}; [ -n "$keep" ] && cp "$T/popup.png" "$keep/popup.png"
else
	bad "the popup never showed its text"; sed 's/^/       /' "$T/shell.out"
fi
grep -q '  FAIL' "$T/shell.out" && { bad "the popup scene's own checks"; sed 's/^/       /' "$T/shell.out"; }
kill $SHELL_PID 2>/dev/null; wait $SHELL_PID 2>/dev/null; sleep 0.5

# the history: the list board ("Notifications" at 22,84, above the light window; the scrim is 780 wide and fades
# to the right)
shell NOTIFY_HISTORY_SCENE=list RIBBON_SHELL_TEST=tests/shell-notify-history.tcl
if shot history 200 20 22 72; then
	ok "the history's text is on screen, bright"
	l=$(px 460 600 "$T/history.png"); r=$(px 700 600 "$T/history.png"); e0=$(px 776 600 "$T/history.png"); e1=$(px 784 600 "$T/history.png")
	[ "$r" -ge $((l + 40)) ] && ok "the scrim fades to the right (brightness $l at x 460, $r at x 700)" || bad "the history is a slab: $l at x 460, $r at x 700"
	d=$((e1 - e0)); [ ${d#-} -le 12 ] && ok "no edge at the scrim's right end ($e0, $e1)" || bad "a hard edge at x 780: $e0 against $e1"
	t=$(px 300 250 "$T/history.png"); [ "$t" -ge 20 ] && ok "between the entries the window shows through (brightness $t)" || bad "the column is opaque: $t"
	keep=${NOTIFY_KEEP:-}; [ -n "$keep" ] && cp "$T/history.png" "$keep/history.png"
else
	bad "the history never showed its text"; sed 's/^/       /' "$T/shell.out"
fi
grep -q '  FAIL' "$T/shell.out" && { bad "the history scene's own checks"; sed 's/^/       /' "$T/shell.out"; }
[ $fails -eq 0 ] && echo "notifications under a compositor: all checks passed"
[ $fails -eq 0 ]
