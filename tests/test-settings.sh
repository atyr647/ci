#!/bin/sh
# Settings (U08): the registry, the rail and the updates chip's count with no display
# (tests/settings-units.tcl); the Settings app under xvfb in each board state
# (tests/settings-scene.tcl), with the Appearance pages hosted in its window and the
# updates chip checked against the same window without it; and bg::picture's fit for
# pictures smaller than the thumbnail (tests/settings-pictures.tcl); and the viewer's wallpaper
# hand-off through Settings (tests/settings-wallpaper.tcl). Parts that need
# wish8.6, xvfb-run, ImageMagick's import or PIL print skip.
set -u
cd "$(dirname "$0")/.." || exit 1
D=$PWD/srcpkgs/ribbon-desktop/files
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }

for f in "$D"/apps/settings/*.tcl tests/settings-*.tcl; do
	tclsh8.6 /dev/stdin "$f" <<'TCL' || fail "$f: incomplete Tcl"
set fh [open [lindex $argv 0]]; fconfigure $fh -encoding utf-8; set src [read $fh]; close $fh
exit [expr {[info complete $src] ? 0 : 1}]
TCL
done
ok "the Settings Tcl is complete"

if tclsh8.6 tests/settings-units.tcl "$D" >"$T/units.out" 2>&1; then
	ok "the registry, rail, search and the updates count (tests/settings-units.tcl)"
else
	fail "tests/settings-units.tcl"; sed 's/^/       /' "$T/units.out"
fi

if grep -q 'ribbon-settings --page appearance' "$D/bin/ribbon-appearance" &&
	grep -q '^Exec=ribbon-settings$' "$D/apps/settings/applications/ribbon-settings.desktop"; then
	ok "ribbon-appearance opens Settings on Appearance; the launcher is in the desktop entry"
else
	fail "ribbon-appearance or ribbon-settings.desktop does not point at Settings"
fi

if command -v xvfb-run >/dev/null 2>&1 && command -v wish8.6 >/dev/null 2>&1; then
	X="xvfb-run -a -s -screen\ 0\ 1440x900x24"
	h=$T/home; mkdir -p "$h/cfg" "$T/cache"
	if timeout 300 env HOME="$h" XDG_CONFIG_HOME="$h/cfg" XDG_CACHE_HOME="$T/cache" \
		xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 tests/settings-pictures.tcl "$D" "$T" >"$T/pic.out" 2>&1; then
		ok "bg::picture fits pictures smaller than the thumbnail (tests/settings-pictures.tcl)"
	else
		fail "tests/settings-pictures.tcl"; sed 's/^/       /' "$T/pic.out"
	fi
	wh=$T/wall-home; mkdir -p "$wh/cfg" "$T/wall-cache"
	if timeout 120 env HOME="$wh" XDG_CONFIG_HOME="$wh/cfg" XDG_CACHE_HOME="$T/wall-cache" \
		xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 tests/settings-wallpaper.tcl "$D" "$T" >"$T/wall.out" 2>&1; then
		ok "the viewer's wallpaper hand-off: Settings opens the desktop picker with the picture chosen (tests/settings-wallpaper.tcl)"
	else
		fail "tests/settings-wallpaper.tcl"; sed 's/^/       /' "$T/wall.out"
	fi
	for scene in appearance colours search empty updates; do
		c=$T/cache-$scene; mkdir -p "$c/kit"
		# the chip's scene has five updates waiting; the others have none
		if [ "$scene" = updates ]; then
			# kit's own format (lib/verbs.tcl saveUpdates): a dict, one dict per waiting kit
			printf '%s\n' 'checked 1700000000 notify 1 updates {{name firefox short firefox version 1.0 new 1.1 flags {security} download 52000000} {name git short git version 2.0 new 2.1 flags {} download 1200000} {name kernel short kernel version 3.0 new 3.1 flags {restart} download 90000000} {name mesa short mesa version 4.0 new 4.1 flags {} download 33000000} {name zlib short zlib version 5.0 new 5.1 flags {} download 800000}}' > "$c/kit/updates"
		fi
		if timeout 120 env HOME="$h" XDG_CONFIG_HOME="$h/cfg" XDG_CACHE_HOME="$c" RIBBON_SCENE=$scene \
			RIBBON_SETTINGS_SCENE=tests/settings-scene.tcl RIBBON_SETTINGS_SHOT="$T/$scene.png" RIBBON_SETTINGS_EXIT=2500 \
			xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" >"$T/$scene.out" 2>&1 &&
			[ -s "$T/$scene.png" ]; then
			ok "draws Settings in the $scene state"
		else
			fail "the $scene state did not draw"; sed 's/^/       /' "$T/$scene.out" 2>/dev/null
		fi
	done
	if command -v python3 >/dev/null 2>&1 && python3 -c 'import PIL' 2>/dev/null && [ -s "$T/updates.png" ] && [ -s "$T/appearance.png" ]; then
		# the chip sits 7 px in from its left edge, centred on the Updates row (window 1100 x 720 at 170, 104; row top 561, 32 tall)
		if python3 - "$T/updates.png" "$T/appearance.png" <<'PY'
import sys
from PIL import Image
a = Image.open(sys.argv[1]).convert('RGB'); b = Image.open(sys.argv[2]).convert('RGB')
p = (343, 681)  # inside the chip, left of its icon
ok = a.getpixel(p) != b.getpixel(p) and a.getpixel(p)[0] > 200
sys.exit(0 if ok else 1)
PY
		then ok "the updates chip is drawn on the accent when updates are waiting"
		else fail "the updates chip is not at its place on the Updates row"; fi
	else
		echo "  skip the updates chip pixel check (needs python3 with PIL and the scene shots)"
	fi
else
	echo "  skip the Settings scenes and picture fit (needs xvfb-run and wish8.6)"
fi

[ "$fails" -eq 0 ] || { echo "settings: $fails failure(s)"; exit 1; }
echo "settings: all passed"
