#!/bin/sh
# The file Inspector (srcpkgs/ribbon-desktop/files/properties/inspector.tcl): its facts
# on a fixture (sizes, text files, language, a photo's EXIF from tests/make-exif.py: camera, date,
# GPS, the exposure strip; a folder's count), then each board state drawn headless in Graphite,
# Fjord and Moss (tests/inspector-scene.tcl): image (pinned footer, and the map tile in its place),
# viewer (no preview, follow footer), edit view, folder, text and a multi-selection. A pinned footer
# ends at the panel's foot, a follow footer above it, then the edit view
# (tests/inspector-edit-flow.tcl): its rows, undo, Revert, Apply's jobs on files (rename, mode, the
# type's app, the pkexec path with a stub).
# Without tclsh8.6 or wish8.6 or xvfb-run the parts that need them skip.
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip inspector (no tclsh8.6)"
	exit 0
fi

# the EXIF fixtures (PIL): big-endian and little-endian photos with GPS and exposure, and a bare
# one; without PIL the EXIF checks skip
exifdir=""
if python3 -c 'import PIL' >/dev/null 2>&1; then
	exifdir=$T/exif
	mkdir -p "$exifdir"
	python3 tests/make-exif.py "$exifdir" >/dev/null 2>&1 || exifdir=""
fi
if tclsh8.6 -encoding utf-8 tests/inspector-facts.tcl "$T/facts" "$exifdir" >"$T/facts.out" 2>&1; then
	grep -c '  ok ' "$T/facts.out" | sed 's/^/  ok   facts: /; s/$/ checks/'
	grep '  skip' "$T/facts.out"
else
	sed 's/^/       /' "$T/facts.out"; fail "inspector facts"
fi

if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip the scenes (no wish8.6 / xvfb-run)"
	[ $fails -eq 0 ] && echo "inspector: all checks passed" || echo "inspector: $fails checks failed"
	exit $((fails > 0))
fi

# each board state in each scheme: drawn, its footer where it belongs
D=$PWD/srcpkgs/ribbon-desktop/files/properties/main.tcl
for scheme in graphite fjord moss; do
	h=$T/home-$scheme
	tclsh8.6 -encoding utf-8 tests/properties-fixture.tcl "$h" "$scheme" "$T/pics" >/dev/null 2>&1
	for scene in image viewer folder text multi edit edit-folder; do
		out=$T/$scheme-$scene.png
		log=$T/$scheme-$scene.log
		if env HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" XDG_DATA_DIRS="$h/.local/share" XDG_CACHE_HOME="$T/cache" KIT_LIB=/nonexistent \
			RIBBON_PROPERTIES_SCENE=tests/inspector-scene.tcl RIBBON_SCENE=$scene RIBBON_PROPERTIES_SHOT="$out" \
			timeout 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D" >"$log" 2>&1 &&
			[ -s "$out" ]; then
			end=$(sed -n 's/.*footer ends at \([0-9]*\) of a panel ending at \([0-9]*\).*/\1 \2/p' "$log")
			set -- $end
			if [ -n "${1:-}" ] && [ "$scene" = viewer ] && [ "$1" -lt "$2" ]; then ok "$scheme: $scene drawn, its footer follows the content ($1 of $2)"
			elif [ -n "${1:-}" ] && [ "$scene" != viewer ] && [ "$1" -eq "$2" ]; then ok "$scheme: $scene drawn, its footer pinned to the foot ($1)"
			elif [ -n "${1:-}" ]; then fail "$scheme: $scene footer at $1, panel ends at $2 (not where it belongs)"
			else fail "$scheme: $scene drew, but reported no footer position"; sed 's/^/       /' "$log"; fi
			# the map tile of the image state, from the photo's pixels the scene reads: its corner
			# is the panel's ground, its pin the accent, and the tile sits where the board has it
			if [ "$scene" = image ]; then
				box=$(sed -n 's/.*map at \([0-9]*\) \([0-9]*\) \([0-9]*\) \([0-9]*\).*/\1 \2 \3 \4/p' "$log")
				if [ -n "$box" ] && python3 -c '
import sys
t = [l for l in open(sys.argv[1]) if " map at " in l][-1].split()
i = t.index("at")
v = dict(zip(t[i + 5::2], t[i + 6::2]))
rgb = lambda k: tuple(map(int, v[k].split(",")))
pin = rgb("pin")
sys.exit(0 if rgb("corner") == rgb("ground") and max(pin) - min(pin) > 60 and pin != rgb("mid") else 1)
' "$log"; then
					ok "$scheme: the map tile is at $box, its corner the ground and its pin the accent (a saturated colour)"
				else
					fail "$scheme: the map tile (${box:-none}) is not drawn where the board has it"; sed 's/^/       /' "$log"
				fi
			fi
		else
			fail "$scheme: $scene did not draw"; sed 's/^/       /' "$log"
		fi
	done
done

# the edit view's flow: the rows, Apply's jobs on real files, with a stub pkexec
h=$T/home-flow
tclsh8.6 -encoding utf-8 tests/properties-fixture.tcl "$h" graphite "$T/pics-flow" >/dev/null 2>&1
if env HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" XDG_DATA_DIRS="$h/.local/share" XDG_CACHE_HOME="$T/cache-flow" KIT_LIB=/nonexistent \
	RIBBON_PROPERTIES_SCENE=tests/inspector-edit-flow.tcl RIBBON_INSPECTOR_WORK="$T/work-flow" \
	timeout 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D" >"$T/flow.log" 2>&1; then
	grep -c '  ok ' "$T/flow.log" | sed 's/^/  ok   edit view: /; s/$/ checks/'
else
	sed 's/^/       /' "$T/flow.log"; fail "inspector edit view flow"
fi

[ $fails -eq 0 ] && echo "inspector: all checks passed" || echo "inspector: $fails checks failed"
[ $fails -eq 0 ]
