#!/bin/sh
# The background picker (Appearance → Desktop background / Login screen, appearance/onstage.tcl) against its boards
# BG-Onstage-Ribbon, -Pictures, -Slideshow, -Video, -Colour-A and -Login (design/tools/gen_onstage.py).
#  1. The sheet: each tab's scene (tests/appearance-scene.tcl, bg-*) drawn under xvfb, its 1280 x 207 box cropped
#     and compared with the board's (tests/fixtures/onstage/boards/*-sheet.png): the top row and the content row
#     each blurred, RMSE. The Ribbon designs tab is compared on its top row only: decision 18
#     (docs/DECISIONS-DELEGATED.md) keeps one design where the board draws eight.
#  2. The whole screen: the same scenes under a headless labwc with XWayland, the stage shown by swaybg on the
#     background layer as in a session, captured with grim and compared, shrunk and blurred, with the board
#     (*-screen.png): the sheet's place, its shadow and the picture behind it. The Login screen tab is left out
#     here: its stage is the greeter's preview window, which labwc 0.7.1 frames with a title bar (the greeter asks
#     for full screen before its window is mapped; see the integration request of W2). The board's own top bars
#     are the shell's, not Appearance's: the top 130 px are not compared.
# The pictures are the boards' stand-in photographs (gen_bgdirs_r3.photo_svg) rendered once into
# tests/fixtures/onstage/pictures; the slideshow folder and the videos are made from them here.
# Also: the Desktop background and Login screen pages open on stage, so Appearance keeps no draw_ proc for them.
# Skips what lacks its tools (wish8.6, xvfb-run, ImageMagick; labwc, grim, swaybg, wlr-randr, ffmpeg, Tk headers).
set -u
cd "$(dirname "$0")/../.." || exit 1
D=$PWD/srcpkgs/ribbon-desktop/files
FX=$PWD/tests/fixtures/onstage
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }

if grep -nE 'proc page::draw_(desktop|login)\b' "$D"/appearance/*.tcl; then
	fail "Appearance still has a draw_ proc for a page that opens on stage (nothing reaches it)"
else
	ok "no draw_ proc for the pages that open on stage"
fi

for c in wish8.6 xvfb-run convert compare; do
	if ! command -v $c >/dev/null 2>&1; then echo "  skip the Onstage scenes (no $c)"; exit $((fails > 0)); fi
done
T=$(mktemp -d)
LP=; AP=
trap 'kill $AP $LP 2>/dev/null; rm -rf "$T"' EXIT

# the fixture folder: pictures/, wallpapers/ (24 pictures, the board's mosaic first), videos/
BG=$T/bg; mkdir -p "$BG/pictures" "$BG/wallpapers" "$BG/videos"
cp "$FX"/pictures/*.png "$BG/pictures/"
i=0; for n in Canyon Glacier Pines Ember; do i=$((i + 1)); cp "$FX/pictures/$n.png" "$BG/wallpapers/0$i $n.png"; done
for k in $(seq 5 24); do cp "$FX/pictures/Moor.png" "$BG/wallpapers/$(printf %02d "$k") Moor.png"; done
tabs="ribbon pictures slideshow colour login"
if command -v ffmpeg >/dev/null 2>&1; then
	for v in Tide:12 Rain:20 Ember:8; do
		n=${v%:*}
		ffmpeg -nostdin -v error -y -loop 1 -i "$FX/pictures/$n.png" -t "${v#*:}" -r 1 -vf scale=640:-2 -c:v libx264 -pix_fmt yuv420p "$BG/videos/$n.mp4" 2>/dev/null
	done
	tabs="$tabs video"
else
	echo "  skip the Video tab (no ffmpeg)"
fi

# rbnalpha (the sheet's see-through window), built from the tree as test-appearance.sh does
RBN=
if [ -f /usr/include/tcl8.6/tk.h ] && mkdir -p "$T/rbn" && timeout 300 make -s -C "$D/rbnalpha" O="$T/rbn" CFLAGS="-O2" >"$T/rbn.log" 2>&1; then
	RBN=$T/rbn/librbnalpha.so
fi

rmse() { compare -metric RMSE "$1" "$2" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p'; }
below() { awk "BEGIN { exit !(${1:-1} < $2) }"; }

# 1. the sheet under xvfb
echo "the sheet (xvfb)"
for tab in $tabs; do
	h=$T/x-$tab; tclsh8.6 tests/appearance-fixture.tcl "$h/cfg" graphite >/dev/null
	env HOME="$h" XDG_CONFIG_HOME="$h/cfg" XDG_CACHE_HOME="$T/cache" XDG_RUNTIME_DIR="$h" APPEARANCE_BG="$BG" ${RBN:+RBNALPHA_LIB=$RBN} \
		RIBBON_APPEARANCE_STAGE=window RIBBON_APPEARANCE_SCENE=tests/appearance-scene.tcl RIBBON_SCENE=bg-$tab \
		RIBBON_APPEARANCE_SHOT="$T/x-$tab.png" RIBBON_APPEARANCE_SHOT_DELAY=1500 \
		timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/appearance/main.tcl" >"$T/x-$tab.out" 2>&1
	if [ ! -s "$T/x-$tab.png" ]; then sed 's/^/       /' "$T/x-$tab.out" | head -20; fail "$tab: the scene was not drawn"; continue; fi
	convert "$T/x-$tab.png" -crop 1280x207+80+673 +repage "$T/sheet.png"
	# limits: the top row carries the tab counts (Ribbon designs 1, not the board's 8); the content row's is
	# under what a 13 px heading in place of a section label gives (0.012)
	parts="top:1280x74+0+0:0.02"
	[ "$tab" = ribbon ] || parts="$parts content:1280x133+0+74:0.009"
	for p in $parts; do
		lim=${p##*:}; p=${p%:*}
		convert "$T/sheet.png" -crop "${p#*:}" +repage -blur 0x2 "$T/a.png"
		convert "$FX/boards/$tab-sheet.png" -crop "${p#*:}" +repage -blur 0x2 "$T/b.png"
		r=$(rmse "$T/a.png" "$T/b.png")
		if below "$r" "$lim"; then ok "$tab, the ${p%%:*} row matches the board (blurred RMSE $r)"; else fail "$tab, the ${p%%:*} row against the board: RMSE ${r:-?}"; fi
	done
done

# 2. the whole screen under labwc
echo "the screen (headless labwc, swaybg, grim)"
for c in labwc grim swaybg wlr-randr Xwayland; do
	if ! command -v $c >/dev/null 2>&1; then echo "  skip the screen (no $c)"; [ $fails -eq 0 ] && echo "Onstage scenes: all checks passed"; exit $((fails > 0)); fi
done
[ -n "$RBN" ] || { echo "  skip the screen (rbnalpha not built: no Tk headers)"; [ $fails -eq 0 ] && echo "Onstage scenes: all checks passed"; exit $((fails > 0)); }
mkdir -p "$T/lcfg" "$T/stub"
cat > "$T/lcfg/rc.xml" <<'XML'
<labwc_config><core><decoration>server</decoration></core>
<windowRules><windowRule identifier="RibbonAppearanceSheet" serverDecoration="no" skipTaskbar="yes" skipWindowSwitcher="yes" fixedPosition="yes"><action name="ToggleAlwaysOnTop" /></windowRule></windowRules>
</labwc_config>
XML
printf 'echo "$DISPLAY" > "$XDG_RUNTIME_DIR/display"\n' > "$T/lcfg/autostart"
# the stage's "pkill -u UID -x swaybg" would reach other sessions' swaybg here: ours end with their compositor
printf '#!/bin/sh\nexit 0\n' > "$T/stub/pkill"; chmod +x "$T/stub/pkill"
for tab in $tabs; do
	[ "$tab" = ribbon ] && continue   # the stage is the pattern (decision 18), the board's another design
	R=$T/l-$tab; mkdir -p "$R/rt"; chmod 700 "$R/rt"; tclsh8.6 tests/appearance-fixture.tcl "$R/cfg" graphite >/dev/null
	( unset WAYLAND_DISPLAY DISPLAY
	  export XDG_RUNTIME_DIR=$R/rt HOME=$R XDG_CONFIG_HOME=$R/cfg XDG_CACHE_HOME=$T/cache DBUS_SESSION_BUS_ADDRESS=unix:path=$R/none
	  WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1 timeout 90 labwc -C "$T/lcfg" >"$R/labwc.log" 2>&1 &
	  LP=$!
	  n=0; while [ ! -s "$R/rt/display" ] && [ $n -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
	  [ -s "$R/rt/display" ] || { kill $LP; exit 1; }
	  DISPLAY=$(cat "$R/rt/display")
	  WAYLAND_DISPLAY=$(find "$R/rt" -maxdepth 1 -regex '.*/wayland-[0-9]*' -printf '%f\n' | sort | head -n1)
	  export DISPLAY WAYLAND_DISPLAY
	  wlr-randr --output HEADLESS-1 --custom-mode 1440x900 >/dev/null 2>&1
	  # the empty output's colour, to see the stage come up
	  grim -g "720,200 1x1" "$R/empty.png"; empty=$(convert "$R/empty.png" -format '%[hex:p{0,0}]' info:)
	  env PATH="$T/stub:$PATH" APPEARANCE_BG="$BG" RBNALPHA_LIB="$RBN" RIBBON_APPEARANCE_STAGE=swaybg \
		RIBBON_APPEARANCE_SCENE=tests/appearance-scene.tcl RIBBON_SCENE=bg-$tab RIBBON_APPEARANCE_READY="$R/ready" \
		timeout 60 wish8.6 -encoding utf-8 "$D/appearance/main.tcl" >"$R/app.out" 2>&1 &
	  AP=$!
	  # drawn (the scene says so), then until swaybg has put the stage up and the screen holds still
	  n=0; while [ ! -e "$R/ready" ] && [ $n -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
	  n=0; while [ $n -lt 100 ]; do
		grim -g "720,200 1x1" "$R/px.png" 2>/dev/null
		[ "$(convert "$R/px.png" -format '%[hex:p{0,0}]' info: 2>/dev/null)" != "$empty" ] && break
		sleep 0.1; n=$((n + 1))
	  done
	  prev=; n=0; while [ $n -lt 50 ]; do
		grim "$T/l-$tab.png"; cur=$(md5sum < "$T/l-$tab.png")
		[ "$cur" = "$prev" ] && break
		prev=$cur; sleep 0.2; n=$((n + 1))
	  done
	  kill $AP $LP 2>/dev/null; wait $AP $LP 2>/dev/null
	) >/dev/null 2>&1
	if [ ! -s "$T/l-$tab.png" ]; then sed 's/^/       /' "$R/app.out" 2>/dev/null | head; fail "$tab: no screen captured"; continue; fi
	convert "$T/l-$tab.png" -resize 360x225 -crop 360x192+0+33 +repage -blur 0x1 "$T/a.png"
	convert "$FX/boards/$tab-screen.png" -crop 360x192+0+33 +repage -blur 0x1 "$T/b.png"
	r=$(rmse "$T/a.png" "$T/b.png")
	if below "$r" 0.013; then ok "$tab: the screen matches the board (shrunk, blurred RMSE $r)"; else fail "$tab: the screen against the board: RMSE ${r:-?}"; fi
done

if [ $fails -eq 0 ]; then echo "Onstage scenes: all checks passed"; else echo "Onstage scenes: $fails checks failed"; exit 1; fi
