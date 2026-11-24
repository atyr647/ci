#!/bin/sh
# The Image Viewer (srcpkgs/ribbon-desktop/files/apps/viewer): the logic without Tk (zoom
# limits and steps, the fit and zoom geometry, navigation order and wrap, the decoders, Delete
# to a fake trash: tests/viewer-logic.tcl), then each board state drawn headless and compared with its board
# (tests/viewer-scene.tcl: photo = Viewer-Final-1-Stage, info = -2-Info, zoom = -4-Zoom, menu = -9-Menu,
# tip = Tooltip-2-Viewer (Rotate lit under the pointer), tipname = its name over the toolbar (the pill's inside, 45 x 16
# at 605,709 in the window: without rbnalpha's C side the pill's window is opaque out to its shadow),
# video = -5-Video and paused = -11-Video-Paused on a clip made from the board's frame, steam = -6-Steam with a
# Steam library in the scene's HOME (screenshot and covers cut from the board); the boards in
# tests/viewer-fixtures/boards are design/tools/render.js renders at 1440 x 900 cut to the 1240 x 800 window
# at 100,72, and picture.png is the board's photo cut from Viewer-Final-1-Stage at 234,140, 972 x 648),
# then a JPEG and a WebP decoded through stage::load when ffmpeg and PIL are there.
# Without tclsh8.6 the step skips; without wish8.6 or xvfb-run the scenes skip.
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip viewer (no tclsh8.6)"
	exit 0
fi

if tclsh8.6 -encoding utf-8 tests/viewer-logic.tcl "$T/logic" >"$T/logic.out" 2>&1; then
	ok "viewer logic: $(grep -c '  ok ' "$T/logic.out") checks"
else
	sed 's/^/       /' "$T/logic.out"; fail "viewer logic"
fi

if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip the scenes (no wish8.6 / xvfb-run)"
	[ $fails -eq 0 ] && echo "viewer: all checks passed" || echo "viewer: $fails checks failed"
	exit $((fails > 0))
fi

app=$PWD/srcpkgs/ribbon-desktop/files/apps/viewer/main.tcl
# each state against its board: the board's own picture stands in for the photo (tests/viewer-fixtures/boards/
# picture.png, cut from Viewer-Final-1-Stage's render), the window is cut from the board's render at (100, 72) and
# both are blurred (RMSE < 0.035, as the monitor's scenes).
board=$PWD/tests/viewer-fixtures/boards
have_im=1
for c in convert compare; do command -v $c >/dev/null 2>&1 || have_im=0; done
states="photo info zoom menu tip tipname steam"
# the video states: a 2 s clip of the board's frame, made on Sat 15 Aug 10:12 (UTC, the scenes run in UTC)
if command -v ffmpeg >/dev/null 2>&1 && ffmpeg -nostdin -v error -y -loop 1 -i "$board/video-frame.png" -t 2 -r 2 -pix_fmt yuv420p \
	-metadata creation_time=2026-08-15T10:12:00Z "$T/clip.mp4" >/dev/null 2>&1; then
	states="$states video paused"
else
	echo "  skip the video scenes (no ffmpeg)"
fi
for state in $states; do
	out=$T/$state.png
	if mkdir -p "$T/home-$state" && env TZ=UTC HOME="$T/home-$state" XDG_CACHE_HOME="$T/cache" RIBBON_VIEWER_PIC="$board/picture.png" \
		RIBBON_VIEWER_CLIP="$T/clip.mp4" RIBBON_VIEWER_SHOTPIC="$board/steam-shot.jpg" RIBBON_VIEWER_COVERS="$board/steam" \
		RIBBON_VIEWER_STATE=$state RIBBON_VIEWER_SCENE="$PWD/tests/viewer-scene.tcl" RIBBON_VIEWER_SHOT="$out" \
		timeout 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$app" >"$T/$state.log" 2>&1 && [ -s "$out" ]; then
		if grep -q "FAIL\|can't\|error" "$T/$state.log"; then fail "$state: a Tcl error"; sed 's/^/       /' "$T/$state.log"
		elif [ $have_im -eq 0 ]; then ok "$state drawn (no ImageMagick: not compared)"
		else
			if [ "$state" = tipname ]; then
				convert "$out" +repage -crop 45x16+605+709 +repage -blur 0x2 "$T/a.png"
				convert "$board/tip.png" -crop 45x16+605+709 +repage -blur 0x2 "$T/b.png"
			else
				convert "$out" +repage -blur 0x2 "$T/a.png"
				convert "$board/$state.png" -blur 0x2 "$T/b.png"
			fi
			r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
			if awk "BEGIN { exit !(${r:-1} < 0.035) }"; then ok "$state matches its board (blurred RMSE $r)"
			else fail "$state against its board: RMSE ${r:-?}"; fi
		fi
	else
		fail "$state did not draw"; sed 's/^/       /' "$T/$state.log"
	fi
done

if python3 -c 'import PIL' >/dev/null 2>&1 && command -v ffmpeg >/dev/null 2>&1; then
	python3 - "$T/p.jpg" "$T/p.webp" <<'PY'
import sys
from PIL import Image
im = Image.new('RGB', (640, 480), (40, 90, 140))
im.save(sys.argv[1], 'JPEG'); im.save(sys.argv[2], 'WEBP')
# a phone's portrait photo: stored 640 x 480 on its side, EXIF Orientation 6 (shown 480 x 640)
ex = im.getexif(); ex[0x0112] = 6
im.save(sys.argv[1].replace('p.jpg', 'p6.jpg'), 'JPEG', exif=ex.tobytes())
# a scan bigger than the stage's 4096 px working copy
Image.new('RGB', (5000, 300), (40, 90, 140)).save(sys.argv[1].replace('p.jpg', 'big.tif'))
PY
	for f in p.jpg p.webp; do
		if env RIBBON_VIEWER_DECODE="$T/$f" timeout 60 xvfb-run -a wish8.6 -encoding utf-8 tests/viewer-decode.tcl >"$T/$f.out" 2>&1 &&
			grep -q '^size 640 480$' "$T/$f.out" && grep -q '^view 400 300$' "$T/$f.out"; then
			ok "$f decoded through ffmpeg (640 x 480, crop 400 x 300)"
		else
			fail "$f did not decode"; sed 's/^/       /' "$T/$f.out"
		fi
	done
	# the size the stage works in is the picture's as shown: upright (EXIF), and the file's own beyond 4096 px
	for fw in "p6.jpg 480 640" "big.tif 5000 300"; do
		set -- $fw
		if env RIBBON_VIEWER_DECODE="$T/$1" timeout 60 xvfb-run -a wish8.6 -encoding utf-8 tests/viewer-decode.tcl >"$T/$1.out" 2>&1 &&
			grep -q "^size $2 $3\$" "$T/$1.out"; then
			ok "$1: the stage's size is $2 x $3"
		else
			fail "$1: the stage's size is not $2 x $3"; sed 's/^/       /' "$T/$1.out"
		fi
	done
else
	echo "  skip jpeg and webp decode (no PIL or no ffmpeg)"
fi

[ $fails -eq 0 ] && echo "viewer: all checks passed" || echo "viewer: $fails checks failed"
exit $((fails > 0))
