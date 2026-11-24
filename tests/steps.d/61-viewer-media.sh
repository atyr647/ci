#!/bin/sh
# The Image viewer's videos and Steam screenshots (apps/viewer/video.tcl, games.tcl): first without Tk
# (tests/viewer-media.tcl: the folder walk with and without a player, mpv's IPC lines read into the transport and
# the commands written to it, the volume kept; Steam's folders found in a fixture library, named by appmanifests in
# two library folders, counted, sized, newest first, the list's days, the covers in both cache layouts; a crop of a
# WebP, a transparent WebP and a GIF saved as a JPEG or PNG copy, Save over them refused), then with the real mpv
# under xvfb (tests/viewer-video.tcl, the viewer's scene: a 4 s testsrc clip plays in the viewer's window and fills
# the picture's rectangle, the transport's button pauses mpv, the scrubber seeks, the volume slider and button set
# volume and mute, Space plays, the menu opens over the frozen frame, Copy path, the next item stops mpv).
# mpv is driven over its IPC socket (unix_extra; built here when it is not installed). Under xvfb mpv's GPU output
# has no GL, so the test gives it --vo=x11 (RIBBON_VIEWER_MPV_ARGS); the session uses mpv's own default.
# Without tclsh8.6 the step skips; without wish8.6, xvfb-run, mpv or ffmpeg the Tk part skips.
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
T=$(mktemp -d)
R=$(mktemp -d /tmp/rv.XXXXXX)
trap 'rm -rf "$T" "$R"' EXIT

if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip viewer media (no tclsh8.6)"
	exit 0
fi

if tclsh8.6 -encoding utf-8 tests/viewer-media.tcl "$T/media" >"$T/media.out" 2>&1 && grep -q "all checks passed" "$T/media.out"; then
	ok "viewer media: $(grep -c '  ok ' "$T/media.out") checks (walk, mpv's IPC model, Steam's games, the crop copies)"
else
	sed 's/^/       /' "$T/media.out"; fail "viewer media"
fi

for c in wish8.6 xvfb-run mpv ffmpeg; do
	if ! command -v $c >/dev/null 2>&1; then
		echo "  skip the video under mpv (no $c)"
		[ $fails -eq 0 ] && echo "viewer media: all checks passed" || echo "viewer media: $fails checks failed"
		exit $((fails > 0))
	fi
done
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	if [ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ]; then
		mkdir -p "$T/ux"
		make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; fail "unix_extra does not build"; }
		ux=$T/ux
	else
		echo "  skip the video under mpv (no unix_extra, no Tcl headers to build it)"
		[ $fails -eq 0 ] && echo "viewer media: all checks passed" || echo "viewer media: $fails checks failed"
		exit $((fails > 0))
	fi
fi
ffmpeg -nostdin -v error -y -f lavfi -i testsrc=size=640x360:rate=25 -f lavfi -i sine=f=440:sample_rate=48000 -t 4 \
	-pix_fmt yuv420p -c:v libx264 -c:a aac -shortest "$T/clip.mp4" >"$T/ffmpeg.log" 2>&1 || ffmpeg -nostdin -v error -y \
	-f lavfi -i testsrc=size=640x360:rate=25 -t 4 -pix_fmt yuv420p "$T/clip.mp4" >>"$T/ffmpeg.log" 2>&1
mkdir -p "$T/home"
if env HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" XDG_CONFIG_HOME="$T/home/.config" XDG_RUNTIME_DIR="$R" \
	TCLLIBPATH="${ux:+$ux }${TCLLIBPATH:-}" RIBBON_VIEWER_MPV_ARGS="--vo=x11 --ao=null" RIBBON_VIEWER_CLIP="$T/clip.mp4" \
	RIBBON_VIEWER_SCENE="$PWD/tests/viewer-video.tcl" \
	timeout 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/apps/viewer/main.tcl \
	>"$T/video.out" 2>&1 && grep -q "^viewer video: all checks passed" "$T/video.out"; then
	ok "the video under mpv: $(grep -c '^ok ' "$T/video.out") checks (plays in the window, pause, seek, volume, mute, Space, the menu, stopped)"
else
	sed 's/^/       /' "$T/video.out"; fail "the video under mpv"
fi

# Steam by game, the menu and a WebP's Rotate, clicked (tests/viewer-games-flow.tcl); Files and wl-copy are stubs
mkdir -p "$T/bin" "$T/home2"
printf '#!/bin/sh\necho "ribbon-files $*" >>"$RIBBON_VIEWER_STUBLOG"\n' >"$T/bin/ribbon-files"
printf '#!/bin/sh\nprintf "wl-copy %%s " "$*" >>"$RIBBON_VIEWER_STUBLOG"; head -c 4 | tail -c 3 >>"$RIBBON_VIEWER_STUBLOG"; echo >>"$RIBBON_VIEWER_STUBLOG"\n' >"$T/bin/wl-copy"
printf '#!/bin/sh\necho "ribbon-properties $*" >>"$RIBBON_VIEWER_STUBLOG"\n' >"$T/bin/ribbon-properties"
chmod +x "$T/bin/ribbon-files" "$T/bin/wl-copy" "$T/bin/ribbon-properties"
board=$PWD/tests/viewer-fixtures/boards
if env PATH="$T/bin:$PATH" HOME="$T/home2" XDG_CACHE_HOME="$T/home2/.cache" XDG_RUNTIME_DIR="$R" RIBBON_VIEWER_STUBLOG="$T/stub.log" \
	RIBBON_VIEWER_SHOTPIC="$board/steam-shot.jpg" RIBBON_VIEWER_COVERS="$board/steam" TZ=UTC \
	RIBBON_VIEWER_SCENE="$PWD/tests/viewer-games-flow.tcl" \
	timeout 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/apps/viewer/main.tcl \
	>"$T/games.out" 2>&1 && grep -q "^viewer games flow: all checks passed" "$T/games.out"; then
	ok "Steam by game, the menu, a WebP's Rotate: $(grep -c '^ok ' "$T/games.out") checks"
else
	sed 's/^/       /' "$T/games.out"; fail "the games flow"
fi

[ $fails -eq 0 ] && echo "viewer media: all checks passed" || echo "viewer media: $fails checks failed"
exit $((fails > 0))
