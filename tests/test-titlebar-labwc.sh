#!/bin/sh
# Ribbon's app windows under a real labwc (headless, with XWayland): each app is started from the tree under
# Ribbon's own rc.xml and its rendered window theme (the default scheme's themerc, as ribbon-desktop installs it),
# its window found on the X display by its class, and its frame read from a grim shot: labwc's title bar above the
# client area (the theme's title colour under the frame's border, the title text at its left and the buttons at
# its right),
# its 1 px border at the side, and the class is the one rc.xml's windowRules leave alone. A window whose class has
# a serverDecoration="no" rule (RibbonInstaller) gets no title bar. Maximise and fixed-size behaviour need labwc
# 0.20 and are not checked here. Run by tests/steps.d/67-titlebar.sh; skips without labwc, Xwayland, grim,
# wlr-randr, xwininfo, ImageMagick or wish8.6.
set -u
cd "$(dirname "$0")/.." || exit 1
for t in labwc Xwayland grim wlr-randr xwininfo convert wish8.6 tclsh8.6; do
	command -v $t >/dev/null 2>&1 || { echo "  skip title bars under labwc (no $t)"; exit 0; }
done
D=$PWD/srcpkgs/ribbon-desktop/files
T=$(mktemp -d); PIDS=
trap 'kill $PIDS 2>/dev/null; rm -rf "$T"' EXIT
fails=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fails=$((fails + 1)); }

# Settings needs unix_extra; build it when it is not installed
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 && ux=$T/ux || echo "  (unix_extra does not build: Settings is left out)"
fi
TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}"; export TCLLIBPATH

# Ribbon's rc.xml and the window theme it names (Ribbon), rendered from the default scheme as the package does
mkdir -p "$T/rt" "$T/home/.config/ribbon" "$T/data/themes" "$T/cache" "$T/state" "$T/lw"; chmod 700 "$T/rt"
cp "$D/themes/palettes/ribbon.conf" "$T/home/.config/ribbon/palette.conf"
bash "$D/bin/ribbon-theme" render-from "$D/themes" ribbon "$T/render" >"$T/render.log" 2>&1 && cp -r "$T/render/themes/Ribbon" "$T/data/themes/" ||
	{ cat "$T/render.log"; echo "  FAIL the window theme does not render"; exit 1; }
TH=$T/data/themes/Ribbon/openbox-3/themerc
hex() { sed -n "s/^$1: *#\(......\).*/\1/p" "$TH"; }
rgb() { h=$1; echo "$((0x$(echo "$h" | cut -c1-2))) $((0x$(echo "$h" | cut -c3-4))) $((0x$(echo "$h" | cut -c5-6)))"; }
TITLE=$(rgb "$(hex window.active.title.bg.color)"); BORDER=$(rgb "$(hex window.active.border.color)")
BTNH=$(sed -n 's/^window.button.height: *//p' "$TH")
cp "$D/xdg/labwc/rc.xml" "$T/lw/rc.xml"
echo "echo \"\$DISPLAY\" > $T/display" > "$T/lw/autostart"
export XDG_RUNTIME_DIR=$T/rt HOME=$T/home XDG_CONFIG_HOME=$T/home/.config XDG_DATA_HOME=$T/data XDG_CACHE_HOME=$T/cache XDG_STATE_HOME=$T/state
unset WAYLAND_DISPLAY DISPLAY RIBBON_OWN_FRAME; export DBUS_SESSION_BUS_ADDRESS=unix:path=$T/none DBUS_SYSTEM_BUS_ADDRESS=unix:path=$T/none
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1 labwc -C "$T/lw" >"$T/labwc.log" 2>&1 &
PIDS="$PIDS $!"
i=0; while [ ! -s "$T/display" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$T/display" ] || { echo "  skip title bars under labwc (labwc does not start headless here)"; exit 0; }
DISPLAY=$(cat "$T/display"); WAYLAND_DISPLAY=
for s in "$T"/rt/wayland-[0-9]*; do case ${s##*/} in *.lock) ;; *) WAYLAND_DISPLAY=${s##*/}; break ;; esac; done
export DISPLAY WAYLAND_DISPLAY
wlr-randr --output HEADLESS-1 --custom-mode 1440x900 >/dev/null 2>&1
echo "     $(labwc -v 2>/dev/null | head -n1), theme Ribbon (title $TITLE, border $BORDER, buttons $BTNH px high)"

# pixel helpers on a grab
px() { convert "$1" -crop 1x1+$2+$3 +repage -format '%[fx:int(255*u.r)] %[fx:int(255*u.g)] %[fx:int(255*u.b)]' info: 2>/dev/null; }
near() { echo "$1 $2" | awk -v t="${3:-6}" '{ d = 0; for (i = 1; i <= 3; i++) { x = $i - $(i + 3); if (x < 0) x = -x; if (x > d) d = x } exit !(d <= t) }'; }
peak() { convert "$1" -crop $2x$3+$4+$5 +repage -colorspace Gray -format '%[fx:int(255*maxima)]' info: 2>/dev/null; }
# the client window of CLASS on the X display: "W H X Y" (absolute), or nothing
client() { xwininfo -root -tree 2>/dev/null | grep "(\"[^\"]*\" \"$1\")" | grep -v ' 1x1+' |
	sed -n 's/.* \([0-9]*\)x\([0-9]*\)+-*[0-9]*+-*[0-9]* *+\(-*[0-9]*\)+\(-*[0-9]*\)$/\1 \2 \3 \4/p' | awk '$1 > 100 && $2 > 100' | head -n1; }

# check NAME CLASS FRAMED COMMAND...: starts COMMAND, waits for its window, grabs the screen and reads the frame
check() {
	name=$1 cls=$2 framed=$3; shift 3
	"$@" >"$T/$cls.out" 2>&1 & app=$!; PIDS="$PIDS $app"
	i=0; g=; while [ -z "$g" ] && [ $i -lt 150 ]; do sleep 0.1; g=$(client "$cls"); i=$((i + 1)); done
	if [ -z "$g" ]; then bad "$name: no $cls window under labwc"; sed 's/^/       /' "$T/$cls.out" | tail -5; kill $app 2>/dev/null; return; fi
	set -- $g; w=$1 h=$2 x=$3 y=$4
	# the frame is drawn once labwc has the window: grab until two grabs agree (at most 5 s)
	grim "$T/$cls.png"; j=0
	while [ $j -lt 50 ]; do cp "$T/$cls.png" "$T/prev.png"; sleep 0.1; grim "$T/$cls.png"; cmp -s "$T/$cls.png" "$T/prev.png" && break; j=$((j + 1)); done
	# the title bar: from just above the client, the rows of the theme's title colour (at a third of the width,
	# away from the title text and the buttons)
	cx=$((x + w / 3)); tb=0; yy=$((y - 1))
	while [ $yy -ge 0 ] && near "$(px "$T/$cls.png" $cx $yy)" "$TITLE" 3; do tb=$((tb + 1)); yy=$((yy - 1)); done
	if [ "$framed" = 1 ]; then
		# above the strip the frame's border; in it the title (the theme's bright label colour) at the left and the
		# buttons (iconify, maximize, close) at the right; the border again beside the client
		top=$(px "$T/$cls.png" $cx $((y - tb - 1)))
		if [ "$tb" -ge 16 ] && near "$top" "$BORDER" 3; then
			txt=$(peak "$T/$cls.png" $((w / 2)) $((tb - 4)) $x $((y - tb + 2)))
			btn=$(peak "$T/$cls.png" 100 $((tb - 4)) $((x + w - 100)) $((y - tb + 2)))
			lb=$(px "$T/$cls.png" $((x - 1)) $((y + h / 2)))
			if [ "${txt:-0}" -ge 200 ] && [ "${btn:-0}" -ge 130 ] && near "$lb" "$BORDER" 3; then
				ok "$name ($cls): labwc's title bar above the client ($tb px of the theme's title colour under its border, the title at the left, the buttons at the right), the 1 px border beside it"
			else bad "$name ($cls): a $tb px title strip, but title $txt (want >= 200), buttons $btn (>= 130), side border $lb (theme $BORDER)"; fi
		else
			bad "$name ($cls): no title bar above the client at $x,$y ($tb px of $TITLE, then $top; the theme's border is $BORDER)"
		fi
	else
		[ "$tb" -lt 4 ] && ok "$name ($cls): no title bar (rc.xml's serverDecoration=\"no\" rule)" || bad "$name ($cls): a $tb px title bar despite its rule"
	fi
	keep=${TITLEBAR_KEEP:-}; [ -n "$keep" ] && cp "$T/$cls.png" "$keep/titlebar-$cls.png"
	kill $app 2>/dev/null; wait $app 2>/dev/null
	i=0; while [ -n "$(client "$cls")" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}

W="wish8.6 -encoding utf-8"
printf 'hello\n' > "$T/home/note.txt"
convert -size 640x400 gradient:'#3b6ea5-#e8c070' "$T/home/picture.png" 2>/dev/null
[ -n "$ux" ] || echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null && check Settings RibbonSettings 1 $W "$D/apps/settings/main.tcl"
check Appearance RibbonAppearance 1 $W "$D/appearance/main.tcl"
check Properties RibbonProperties 1 $W "$D/properties/main.tcl" "$T/home/note.txt"
check "Text editor" RibbonEditor 1 $W "$D/apps/editor/main.tcl" "$T/home/note.txt"
check "System monitor" RibbonMonitor 1 $W "$D/apps/monitor/main.tcl"
check Notes RibbonNotes 1 $W "$D/apps/notes/main.tcl"
check "Image Viewer" RibbonImageViewer 1 $W "$D/apps/viewer/main.tcl" "$T/home/picture.png"
# a window rc.xml keeps undecorated
cat > "$T/plain.tcl" <<'TCL'
wm withdraw .
toplevel .w -class RibbonInstaller -background #808080 -width 600 -height 400
TCL
check "A window with a no-decoration rule" RibbonInstaller 0 $W "$T/plain.tcl"

[ $fails -eq 0 ] && echo "title bars under labwc: all checks passed"
[ $fails -eq 0 ]
