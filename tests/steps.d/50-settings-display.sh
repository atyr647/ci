#!/bin/sh
# Settings → Display (U11): the logic with no display (tests/settings-display.tcl), then the
# page under xvfb with stub wlr-randr, ribbon and kanshictl on PATH: the board state draws and
# reads the outputs; Apply writes the wlr-randr line and the HDR commands, the keep sheet
# draws over the shaded page, and the revert timer puts the previous layout back.
set -u
cd "$(dirname "$0")/../.." || exit 1
D=$PWD/srcpkgs/ribbon-desktop/files
if ! command -v tclsh8.6 >/dev/null 2>&1; then echo "  skip Settings → Display (no tclsh8.6)"; exit 0; fi
if ! tclsh8.6 tests/settings-display.tcl "$D" >/dev/null 2>&1; then
	echo "  FAIL Settings → Display logic (tests/settings-display.tcl)"; tclsh8.6 tests/settings-display.tcl "$D" | sed 's/^/       /'; exit 1
fi
echo "  ok   Settings → Display logic (tests/settings-display.tcl)"
if ! command -v xvfb-run >/dev/null 2>&1 || ! command -v wish8.6 >/dev/null 2>&1 || ! command -v import >/dev/null 2>&1 ||
	! python3 -c 'import PIL' 2>/dev/null; then
	echo "  skip Settings → Display scenes (needs xvfb-run, wish8.6, ImageMagick import and python3 with PIL)"; exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/cfg" "$T/cache"
cat > "$T/bin/wlr-randr" <<'SH2'
#!/bin/sh
if [ "$1" = "--json" ]; then cat "$FIXTURE"; exit 0; fi
echo "wlr-randr $*" >> "$STUB_LOG"; exit 0
SH2
cat > "$T/bin/ribbon" <<'SH2'
#!/bin/sh
echo "ribbon $*" >> "$STUB_LOG"
if [ "$1" = hdr ] && [ "$2" = status ]; then echo "HDR: on   SDR white: 280 nits   game env: on"; fi
exit 0
SH2
printf '#!/bin/sh\necho "kanshictl $*" >> "$STUB_LOG"; exit 0\n' > "$T/bin/kanshictl"
chmod +x "$T/bin"/*
scene() { # name, extra env...
	name=$1; shift
	: > "$T/log-$name"
	timeout 120 env PATH="$T/bin:$PATH" FIXTURE="$PWD/tests/fixtures/display-outputs.json" STUB_LOG="$T/log-$name" \
		HOME="$T/home" XDG_CONFIG_HOME="$T/home/cfg" XDG_CACHE_HOME="$T/cache" RIBBON_SCENE=appearance \
		RIBBON_SETTINGS_SCENE=tests/settings-display-scene.tcl RIBBON_DISPLAY_SCENE="$name" \
		RIBBON_SETTINGS_SHOT="$T/$name.png" RIBBON_SETTINGS_EXIT=2600 "$@" \
		xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" >"$T/$name.out" 2>&1
}
fails=0
if scene board RIBBON_DISPLAY_TEXTS="$T/board.texts" && [ -s "$T/board.png" ] && grep -qx 'ribbon hdr status' "$T/log-board" && ! grep -q wlr-randr "$T/log-board"; then
	echo "  ok   the board state draws, reads the outputs and changes nothing"
else
	echo "  FAIL the board state"; sed 's/^/       /' "$T/board.out"; fails=$((fails + 1))
fi
# Colour profile is left out until the compositor loads ICC profiles (DECISIONS-DELEGATED 39): no dead box
if grep -qx 'Variable refresh' "$T/board.texts" && ! grep -q 'Colour profile\|Built-in (EDID)' "$T/board.texts"; then
	echo "  ok   the page draws Variable refresh and no Colour profile row"
else
	echo "  FAIL the Colour profile row is drawn (or the page drew nothing)"; sed "s/^/       /" "$T/board.texts" 2>/dev/null | head -40; fails=$((fails + 1))
fi
if scene sheet && grep -qx -- '--output DP-1 --on --mode 2560x1440@164.998Hz --pos 0,0 --scale 1.25 --transform normal --output eDP-1 --on --mode 2880x1800@90.000Hz --pos 2560,0 --scale 2.0 --transform normal' "$T/log-sheet" 2>/dev/null ||
	grep -q '^wlr-randr --output DP-1 --on --mode 2560x1440@164.998Hz --pos 0,0 --scale 1.25 --transform normal --output eDP-1 ' "$T/log-sheet"; then
	echo "  ok   Apply writes the wlr-randr line for the layout (scale 125 %)"
else
	echo "  FAIL Apply's command line"; sed 's/^/       /' "$T/log-sheet"; fails=$((fails + 1))
fi
if grep -qx 'ribbon hdr on' "$T/log-sheet" && grep -qx 'ribbon hdr sdr-white 280' "$T/log-sheet"; then
	echo "  ok   Apply sets HDR and the SDR white level with ribbon hdr"
else
	echo "  FAIL Apply's HDR commands"; fails=$((fails + 1))
fi
if python3 - "$T/sheet.png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGB')
inside = im.getpixel((170 + 345, 74 + 320))    # the keep sheet's bar, unshaded
outside = im.getpixel((170 + 100, 74 + 400))   # the page under it, shaded
sys.exit(0 if inside[0] >= 25 and outside[0] < 20 else 1)
PY
then echo "  ok   the keep sheet draws over the shaded page"
else echo "  FAIL the keep sheet is not drawn over the shaded page"; fails=$((fails + 1)); fi
: > "$T/log-revert"
if scene sheet RIBBON_DISPLAY_REVERT=1 && [ "$(grep -c '^wlr-randr ' "$T/log-sheet")" -ge 2 ] && grep '^wlr-randr ' "$T/log-sheet" | tail -1 | grep -q -- '--scale 1.000000'; then
	echo "  ok   the revert timer puts the previous layout back (scale 1.000000) unless kept"
else
	echo "  FAIL the revert timer"; sed 's/^/       /' "$T/log-sheet"; fails=$((fails + 1))
fi
if timeout 20 env DISPLAY="${DISPLAY:-}" xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/apps/settings/identify.tcl" 0 0 400 300 1 400 0 400 300 2 >/dev/null 2>&1; then
	echo "  ok   Identify draws each output's number and closes itself (identify.tcl)"
else
	echo "  FAIL identify.tcl"; fails=$((fails + 1))
fi
# Identify takes its colours from the theme: under Fjord the surface is Fjord's BAR and the number its FG
mkdir -p "$T/fjord/ribbon"; cp "$D/themes/palettes/ribbon-fjord.conf" "$T/fjord/ribbon/palette.conf"
cat > "$T/idshot.sh" <<'SH2'
#!/bin/sh
wish8.6 -encoding utf-8 "$1" 0 0 400 300 1 & p=$!
i=0
while [ $i -lt 100 ]; do
	c=$(import -window root -crop 1x1+5+5 txt:- 2>/dev/null | sed -n 2p | grep -o '#[0-9A-F]\{6\}')
	[ -n "$c" ] && [ "$c" != "#000000" ] && break
	sleep 0.1; i=$((i + 1))
done
import -window root -crop 400x300+0+0 +repage -depth 8 -format %c histogram:info:- 2>/dev/null
kill $p 2>/dev/null; wait $p 2>/dev/null
exit 0
SH2
bar=$(sed -n 's/^BAR=#\?//p' "$D/themes/palettes/ribbon-fjord.conf" | tr -d '#"' | tr a-f A-F)
fg=$(sed -n 's/^FG=#\?//p' "$D/themes/palettes/ribbon-fjord.conf" | tr -d '#"' | tr a-f A-F)
timeout 30 env XDG_CONFIG_HOME="$T/fjord" xvfb-run -a -s "-screen 0 1440x900x24" sh "$T/idshot.sh" "$D/apps/settings/identify.tcl" > "$T/idhist" 2>/dev/null
top=$(sort -rn "$T/idhist" | sed -n 1p | grep -o '#[0-9A-F]\{6\} ')
if [ "$top" = "#$bar " ] && grep -q "#$fg " "$T/idhist" && ! grep -q '#1D1C1B\|#EEE9E3' "$D/apps/settings/identify.tcl"; then
	echo "  ok   Identify draws on the theme's surface in its text colour (Fjord: #$bar, #$fg)"
else
	echo "  FAIL Identify's colours under Fjord (surface ${top:-none}, want #$bar and #$fg)"; sed 's/^/       /' "$T/idhist" | head -5; fails=$((fails + 1))
fi
# the page's reader and Apply against a real compositor and the wlr-randr installed (headless labwc, two outputs;
# a wlr-randr without --json, such as 0.3, is read from its plain listing)
if command -v labwc >/dev/null 2>&1 && command -v wlr-randr >/dev/null 2>&1; then
	R=$(mktemp -d /tmp/rdl.XXXXXX); chmod 700 "$R"
	( unset WAYLAND_DISPLAY DISPLAY; mkdir -p "$R/cfg"
	XDG_RUNTIME_DIR=$R WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=2 \
		exec timeout 60 labwc -C "$R/cfg" >"$R/labwc.log" 2>&1 ) & lp=$!
	i=0; while [ $i -lt 100 ] && ! find "$R" -maxdepth 1 -regex '.*/wayland-[0-9]*' | grep -q .; do sleep 0.1; i=$((i + 1)); done
	wl=$(find "$R" -maxdepth 1 -regex '.*/wayland-[0-9]*' -printf '%f\n' | sort | head -n1)
	if [ -n "$wl" ] && env -u DISPLAY XDG_RUNTIME_DIR="$R" WAYLAND_DISPLAY="$wl" wlr-randr --output HEADLESS-1 --custom-mode 1920x1080@60 >/dev/null 2>&1 &&
		env -u DISPLAY XDG_RUNTIME_DIR="$R" WAYLAND_DISPLAY="$wl" timeout 60 tclsh8.6 tests/settings-display-live.tcl "$D" >"$T/live" 2>&1; then
		sed 's/^/  /' "$T/live"
	else
		sed 's/^/       /' "$T/live" "$R/labwc.log" 2>/dev/null | tail -20; echo "  FAIL Settings → Display against headless labwc"; fails=$((fails + 1))
	fi
	kill $lp 2>/dev/null; wait $lp 2>/dev/null; rm -rf "$R"
else
	echo "  skip Settings → Display against a compositor (no labwc / wlr-randr)"
fi
[ "$fails" -eq 0 ] && echo "  ok   Settings → Display scenes" || { echo "  FAIL Settings → Display scenes ($fails)"; exit 1; }
