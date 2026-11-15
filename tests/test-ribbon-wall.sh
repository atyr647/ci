#!/bin/sh
# test-ribbon-wall.sh - ribbon-wall, the wallpaper (srcpkgs/ribbon-desktop/files/ribbon-wall).
#
# Builds it (-Werror), draws the Ribbon design at many sizes and aspect
# ratios, refuses design files that try to run code, checks the video
# length rule (--probe), then runs it in a headless labwc (when there is
# one) and checks: the design per output, previews of every kind and Revert
# (with crossfades), a preview's owner going away, a slideshow (and that a
# preview writes nothing), videos kept resident and streamed with a resident
# head (seamless loop points, from presentation feedback), the length limit,
# the pause rules (fullscreen window, PAUSE_FULLSCREEN=no, game hint,
# battery), output hotplug and mode and scale changes, and a palette change
# re-rendering the design. Both renderers: GL (EGL; Mesa's llvmpipe here)
# and wl_shm.
set -u
cd "$(dirname "$0")/.." || exit 1
W=srcpkgs/ribbon-desktop/files/ribbon-wall
PAL=srcpkgs/ribbon-desktop/files/themes/palettes/ribbon.conf
T=$(mktemp -d)
status=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; status=1; }
cleanup() {
	[ -n "${RW:-}" ] && kill "$RW" 2>/dev/null
	[ -n "${LABWC:-}" ] && kill "$LABWC" 2>/dev/null
	rm -rf "${T:?}"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

# ---- build ----------------------------------------------------------------------
if ! make -s -C "$W" O="$T" CFLAGS="-O2 -Werror" >"$T/build.log" 2>&1; then
	cat "$T/build.log"; fail "ribbon-wall does not build"; exit 1
fi
ok "ribbon-wall builds with -Wall -Wextra -Werror ($(wc -c < "$T/ribbon-wall") bytes)"
RWB=$T/ribbon-wall

# ---- designs at any size ----------------------------------------------------------------
png_size() { od -An -tu1 -j16 -N8 "$1" | awk '{ printf "%dx%d", $1*16777216+$2*65536+$3*256+$4, $5*16777216+$6*65536+$7*256+$8 }'; }
for s in "1920 1080 1" "3440 1440 1" "5120 1440 1" "1080 1920 1" "320 240 1" "2880 1620 1.5" "3840 2160 2" "800 1280 1.25"; do
	set -- $s
	out=$T/look-$1x$2.png
	lay=$("$RWB" --tcl $W/look.tcl $W/looks/ribbon.look $PAL "$1" "$2" "$3" "$out" 2>&1)
	if [ "$(png_size "$out")" != "$1x$2" ]; then fail "design at $1x$2@$3: $lay"; continue; fi
	# the wordmark stays inside the safe area (8 px sides, 54 px bars), centred
	if echo "$lay" | awk -v W="$1" -v H="$2" -v S="$3" '/^layout mark/ {
			x0 = $3; y0 = $4; x1 = $5; y1 = $6
			ok = x0 >= 8 * S && x1 <= W - 8 * S && y0 >= 54 * S && y1 <= H - 54 * S && ((x0 + x1) / 2 - W / 2) ^ 2 < (W * 0.02) ^ 2
			exit !ok }'; then ok "design at $1x$2@$3 ($(echo "$lay" | awk '/size/ { print "wordmark " $8 " px" }'))"
	else fail "design at $1x$2@$3: wordmark outside the safe area: $lay"; fi
done
# a design file is data: one that tries to run something is refused, and nothing runs
cat > "$T/evil.look" <<EOF
name Evil
gradient {DESK_TOP DESK_BOTTOM}
layers {
	stripes {angle [exec touch $T/pwned] period 150 width 44 offset 106 colour DESK_STRIPE alpha 0.1}
}
EOF
printf 'advance [exec touch %s/pwned]\ncontours {}\n' "$T" > "$T/evil.glyphs"
printf 'gradient {DESK_TOP DESK_BOTTOM}\nlayers {mark {glyphs evil.glyphs size 148}}\n' > "$T/evil2.look"
printf 'gradient {DESK_TOP DESK_BOTTOM}\nlayers {stripes {angle 45 period {1 vw [exec touch %s/pwned]} width 4 offset 0}}\n' "$T" > "$T/evil3.look"
n=0
for e in evil evil2 evil3; do
	if ! "$RWB" --tcl $W/look.tcl "$T/$e.look" $PAL 64 48 1 "$T/$e.png" >/dev/null 2>&1 && [ ! -e "$T/$e.png" ]; then n=$((n + 1)); fi
done
if [ $n = 3 ] && [ ! -e "$T/pwned" ]; then ok "design files are data: 3 that try to run code are refused, nothing ran"
else fail "design files: $n of 3 refused; pwned: $([ -e "$T/pwned" ] && echo yes || echo no)"; fi

# ---- test clips: a moving gradient that loops exactly, its frame number as a barcode ----
have_clips=0
if command -v ffmpeg >/dev/null 2>&1 && cc -O2 -o "$T/genclip" $W/bench/genclip.c -lm 2>/dev/null; then
	enc="-c:v libx264 -preset veryfast -g 30"
	ffmpeg -hide_banner -loglevel error -h encoder=libx264 >/dev/null 2>&1 || enc="-c:v mpeg4 -q:v 4 -g 30"
	"$T/genclip" 640 360 60 | ffmpeg -hide_banner -loglevel error -f rawvideo -pix_fmt yuv420p -s 640x360 -r 30 -i - $enc -y "$T/loop.mp4" &&
		have_clips=1
fi
if [ $have_clips = 1 ]; then
	if "$RWB" --probe "$T/loop.mp4" | grep -q 'duration 2.000.* ok 1'; then ok "--probe accepts a 2 s clip"; else fail "--probe: $("$RWB" --probe "$T/loop.mp4")"; fi
	out=$(RIBBON_WALL_MAX_SECONDS=1 "$RWB" --probe "$T/loop.mp4"); rc=$?
	if [ $rc = 1 ] && echo "$out" | grep -q 'too long: 2.0 s, at most 1 s'; then ok "--probe refuses a clip over the length limit (exit 1, says the limit)"
	else fail "--probe length limit: $rc $out"; fi
	if ! "$RWB" --probe $PAL >/dev/null; then ok "--probe refuses a file that isn't a video"; else fail "--probe took a text file"; fi
else
	echo "  skip video clips (no ffmpeg or cc)"
fi

# ---- in a compositor ------------------------------------------------------------------
if ! command -v labwc >/dev/null 2>&1 || ! command -v wlr-randr >/dev/null 2>&1; then
	echo "  skip ribbon-wall in a compositor (no labwc / wlr-randr)"
	exit $status
fi
export XDG_RUNTIME_DIR=$T/rt HOME=$T/home XDG_CONFIG_HOME=$T/home/.config XDG_CACHE_HOME=$T/home/.cache XDG_STATE_HOME=$T/home/.state
export RIBBON_WALL_LIB=$W RIBBON_WALL_PALETTE=$T/palette.conf RIBBON_WALL_POWER=$T/power
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME/ribbon" "$T/labwc" "$T/power" "$T/pics/sub"
chmod 700 "$XDG_RUNTIME_DIR"
cp $PAL "$T/palette.conf"
for i in 1 2 3; do tclsh8.6 tests/make-picture.tcl bands $((1200 + 100 * i)) 900 "$T/pics/p$i.png"; done
cp "$T/pics/p1.png" "$T/pics/sub/p4.png"
echo '<labwc_config><core><decoration>server</decoration></core></labwc_config>' > "$T/labwc/rc.xml"
echo 'echo "$DISPLAY" > "$XDG_RUNTIME_DIR/display"' > "$T/labwc/autostart"
WAYLAND_DISPLAY='' WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=2 \
	labwc -C "$T/labwc" >"$T/labwc.log" 2>&1 &
LABWC=$!
i=0; while [ ! -s "$XDG_RUNTIME_DIR/display" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
sock=
for f in "$XDG_RUNTIME_DIR"/wayland-*; do case $f in *.lock) ;; *) [ -S "$f" ] && sock=${f##*/} ;; esac; done
[ -n "$sock" ] || { cat "$T/labwc.log"; fail "headless labwc did not start"; exit 1; }
export WAYLAND_DISPLAY=$sock
wlr-randr --output HEADLESS-1 --custom-mode 1280x720 >/dev/null 2>&1
wlr-randr --output HEADLESS-2 --custom-mode 640x480 --pos 1280,0 >/dev/null 2>&1
FIFO=$XDG_RUNTIME_DIR/ribbon-wall
LOG=$T/rw.log

say() { printf '%s\n' "$*" > "$FIFO"; }
# wait (up to $2 s) for a line matching $1 in the log after mark $M
waitfor() {
	i=0
	while [ $i -lt $((${2:-10} * 10)) ]; do
		tail -n +"$M" "$LOG" | grep -Eq -- "$1" && return 0
		sleep 0.1; i=$((i + 1))
	done
	return 1
}
mark() { M=$(($(wc -l < "$LOG") + 1)); }
check() { # label regex [seconds]
	if waitfor "$2" "${3:-10}"; then ok "$1"; else fail "$1 (no '$2' in the log)"; tail -n +"$M" "$LOG" | sed 's/^/       /' | tail -n 8; fi
}
# the colour at x y of output 1, from grim (PPM)
pixel() {
	command -v grim >/dev/null 2>&1 || { echo ""; return; }
	grim -t ppm -o HEADLESS-1 "$T/shot.ppm" 2>/dev/null || { echo ""; return; }
	python3 - "$T/shot.ppm" "$1" "$2" <<'EOF'
import sys
d = open(sys.argv[1], 'rb').read()
parts = d.split(b'\n', 3)
w, h = map(int, parts[1].split())
x, y = int(sys.argv[2]), int(sys.argv[3])
o = len(d) - w * h * 3 + (y * w + x) * 3
print('#%02X%02X%02X' % tuple(d[o:o + 3]))
EOF
}
near() { # colour colour tolerance
	python3 -c "import sys; a, b = sys.argv[1], sys.argv[2]; t = int(sys.argv[3])
sys.exit(0 if a and all(abs(int(a[i:i+2], 16) - int(b[i:i+2], 16)) <= t for i in (1, 3, 5)) else 1)" "$1" "$2" "$3"
}
start() { # renderer [env...]
	r=$1; shift
	rm -f "$FIFO"
	: > "$LOG"; M=1
	env RIBBON_WALL_RENDERER="$r" RIBBON_WALL_MIN_INTERVAL=1 RIBBON_WALL_STATS="$T/stats" "$@" "$RWB" >>"$LOG" 2>&1 &
	RW=$!
	i=0; while [ ! -p "$FIFO" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}
stop() { say quit; i=0; while kill -0 "$RW" 2>/dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done; kill "$RW" 2>/dev/null; RW=; }

for renderer in gl shm; do
	echo "  -- renderer: $renderer"
	rm -rf "$XDG_CACHE_HOME" "$XDG_STATE_HOME"
	printf 'MODE=pattern\n' > "$XDG_CONFIG_HOME/ribbon/wallpaper.conf"
	wlr-randr --output HEADLESS-1 --custom-mode 1280x720 --scale 1 >/dev/null 2>&1
	wlr-randr --output HEADLESS-2 --custom-mode 640x480 --scale 1 >/dev/null 2>&1
	start $renderer
	if [ $renderer = gl ] && ! waitfor '^renderer gl' 5; then echo "  skip GL (no EGL here): $(grep -m1 renderer "$LOG")"; stop; continue; fi
	check "starts with the design, drawn for each output's size" 'design-rendered HEADLESS-2 look-ribbon-[0-9a-f]+-640x480@1.png' 20
	waitfor 'design-rendered HEADLESS-1 look-ribbon-[0-9a-f]+-1280x720@1.png' 20 || fail "design for HEADLESS-1"
	sleep 0.5
	c=$(pixel 640 700); near "$c" "#141312" 6 && ok "the design is on screen (bottom of the gradient $c)" || fail "design pixel $c"

	# previews: a colour, a picture (crossfading), Revert
	mark; say "preview colour fade=0 #C02040"; check "preview colour" '^preview colour'
	sleep 0.3; c=$(pixel 640 360); near "$c" "#C02040" 2 && ok "  shown at once: $c" || fail "colour preview pixel $c"
	mark; say "preview picture fade=1500 fit=fill $T/pics/p2.png"; check "preview picture (with a crossfade)" '^preview picture'
	sleep 0.5; c=$(pixel 640 360)
	if [ -n "$c" ] && ! near "$c" "#C02040" 10 && ! near "$c" "#3060A0" 10; then ok "  mid-crossfade: $c (between #C02040 and #3060A0)"
	else fail "mid-crossfade pixel $c"; fi
	sleep 1.5; c=$(pixel 640 360); near "$c" "#3060A0" 3 && ok "  then the picture: $c" || fail "picture preview pixel $c"
	mark; say "preview end"; check "Revert ends the preview" '^preview end'
	sleep 0.8; c=$(pixel 640 700); near "$c" "#141312" 6 && ok "  the saved design is back: $c" || fail "after revert pixel $c"
	grep -q '^MODE=pattern$' "$XDG_CONFIG_HOME/ribbon/wallpaper.conf" && [ "$(wc -l < "$XDG_CONFIG_HOME/ribbon/wallpaper.conf")" = 1 ] &&
		ok "  previews wrote nothing to wallpaper.conf" || fail "wallpaper.conf changed by a preview"

	# a preview whose app quits (no Apply, no Revert) is reverted
	sleep 30 & owner=$!
	mark; say "preview colour owner=$owner #20A040"; check "preview with owner=PID" '^preview colour'
	kill $owner; check "  the owner quit: reverted" '^preview end' 6

	# a slideshow preview: changes on its interval, writes nothing
	mark; say "preview slideshow interval=1 crossfade=0.2 shuffle=no subdirs=yes $T/pics"
	if waitfor "^slide .*p1.png" 5 && waitfor "^slide .*p2.png" 5 && waitfor "^slide .*p3.png" 5 && waitfor "^slide .*sub/p4.png" 5; then
		ok "slideshow preview: every picture, subfolders too, in order"
	else fail "slideshow preview"; fi
	[ ! -e "$XDG_STATE_HOME/ribbon/slideshow" ] && ! grep -q IMAGE "$XDG_CONFIG_HOME/ribbon/wallpaper.conf" &&
		ok "  a previewed slideshow keeps no state" || fail "preview slideshow wrote state"
	# Apply: the app writes wallpaper.conf, then "reload"
	printf 'MODE=slideshow\nSLIDESHOW_DIR=%s\nINTERVAL=1\nCROSSFADE=0.2\nSHUFFLE=no\nSUBDIRS=no\nFIT=fill\n' "$T/pics" > "$XDG_CONFIG_HOME/ribbon/wallpaper.conf"
	mark; say reload; check "Apply (reload) shows the saved slideshow" '^reload slideshow'
	waitfor "^slide .*p2.png" 6 && sleep 0.3
	if grep -q "^IMAGE=$T/pics/p" "$XDG_CONFIG_HOME/ribbon/wallpaper.conf" && grep -q "pos" "$XDG_STATE_HOME/ribbon/slideshow"; then
		ok "  the slideshow writes IMAGE back and keeps its place ($(sed -n 's/^IMAGE=.*\///p' "$XDG_CONFIG_HOME/ribbon/wallpaper.conf"))"
	else fail "slideshow IMAGE / state"; fi

	if [ $have_clips = 1 ]; then
		# a video kept whole in memory, then one streamed with a resident head
		for store in resident stream; do
			stop
			printf 'MODE=video\nVIDEO=%s\nFIT=fill\n' "$T/loop.mp4" > "$XDG_CONFIG_HOME/ribbon/wallpaper.conf"
			if [ $store = stream ]; then start $renderer RIBBON_WALL_RESIDENT_MB=0.05; else start $renderer; fi
			check "video ($store)" "^video .*store $store" 10
			sleep 7
			mark; say "status $T/status"; sleep 0.5
			st=$(cat "$T/status" 2>/dev/null)
			passes=$(echo "$st" | sed -n 's/.*passes \([0-9]*\).*/\1/p')
			[ "${passes:-0}" -ge 2 ] && ok "  it loops (decoder passes: $passes)" || fail "  video loops: $st"
			if [ $store = stream ]; then
				exact=$(echo "$st" | sed -n 's/.*seeks_exact \([0-9]*\).*/\1/p')
				[ "${exact:-0}" -ge 1 ] && ok "  streamed: seeks to the keyframe after the resident head ($exact exact)" || fail "  stream seeks: $st"
			fi
			# the loop point is like any other frame: its interval no longer than
			# the slowest other one in the same run, and the count goes on (59 ->
			# 0, or as many frames on as elsewhere when a slow software path skips
			# some). Wall-clock gaps on a loaded machine are noisy, so a failure
			# is measured once more on a fresh stretch of frames.
			n0=0; tries=0
			while :; do
				tries=$((tries + 1))
				if tail -n +$((n0 + 1)) "$T/stats" | grep -v '#' | python3 -c '
import sys, statistics
rows = [tuple(map(float, l.split())) for l in sys.stdin if l.strip()][30:]
pairs = list(zip(rows, rows[1:]))
wrap = [(b[0] - a[0], (b[1] - a[1]) % 60) for a, b in pairs if b[1] < a[1]]
other = [(b[0] - a[0], b[1] - a[1]) for a, b in pairs if b[1] >= a[1]]
ti = sorted(t for t, _ in other); steps = [d for _, d in other]
if not wrap: print("no loop seen"); sys.exit(1)
print("loops %d, loop-point interval max %.1f ms, other frames median %.1f ms, max %.1f ms" % (len(wrap), max(t for t, _ in wrap) * 1e3, statistics.median(ti) * 1e3, ti[-1] * 1e3))
sys.exit(0 if max(t for t, _ in wrap) <= ti[-1] + 0.002 and max(d for _, d in wrap) <= max(steps) else 1)' > "$T/loop.txt"; then
					ok "  seamless: $(cat "$T/loop.txt")$([ $tries -gt 1 ] && echo " (second measurement)")"; break
				elif [ $tries -ge 2 ]; then fail "  loop point: $(cat "$T/loop.txt")"; break
				fi
				n0=$(wc -l < "$T/stats"); sleep 7
			done
		done

		# the Appearance app's stage adapter (appearance/preview.tcl): its own
		# lines make a slideshow and a video play, and its Revert reverts
		if [ $renderer = gl ]; then
			adapter() { tclsh8.6 /dev/stdin "$@" <<'TCL'
namespace eval store {}; namespace eval raster { variable cachedir /tmp }
source srcpkgs/ribbon-desktop/files/appearance/preview.tcl
puts [stage::wall_line [lindex $argv 0]]
TCL
			}
			mark; say "$(adapter "picture $T/pics/p1.png fill #000000 {slideshow $T/pics 60 0.2 no no}" | sed 's/ owner=[0-9]*//; s/interval=60/interval=1/')"
			if waitfor '^preview slideshow' 5 && waitfor "^slide .*p2.png" 5; then ok "the Appearance adapter's slideshow preview plays"; else fail "adapter slideshow: $(tail -n +"$M" "$LOG" | head -3)"; fi
			mark; say "$(adapter "video $T/loop.mp4 {}" | sed 's/ owner=[0-9]*//')"
			check "  its video preview plays" "^video .*loop.mp4 " 8
			sleep 2.5; mark; say "status $T/status"; sleep 0.5
			grep -q 'passes [1-9]' "$T/status" && ok "  (looping)" || fail "adapter video not looping: $(cat "$T/status")"
			mark; say "preview end"; check "  its Revert ends the preview" '^preview end'
		fi

		# pause rules: a fullscreen window pauses (PAUSE_FULLSCREEN, default yes)
		if command -v wish8.6 >/dev/null 2>&1; then
			mark
			DISPLAY=$(cat "$XDG_RUNTIME_DIR/display") wish8.6 <<'EOF' >/dev/null 2>&1 &
wm title . Fullscreen; after 400 {wm attributes . -fullscreen 1}; after 4000 exit
EOF
			check "a fullscreen window pauses the video" '^pause HEADLESS-1 1 fullscreen' 6
			waitfor '^pause HEADLESS-2 1 fullscreen' 2 && ok "  on every output" || fail "  HEADLESS-2 not paused"
			check "  and it plays again when the window goes" '^pause HEADLESS-1 0' 6
			mark
			printf 'PAUSE_FULLSCREEN=no\n' >> "$XDG_CONFIG_HOME/ribbon/wallpaper.conf"; say reload
			DISPLAY=$(cat "$XDG_RUNTIME_DIR/display") wish8.6 <<'EOF' >/dev/null 2>&1 &
wm title . Fullscreen; after 400 {wm attributes . -fullscreen 1}; after 2500 exit
EOF
			sleep 2
			if tail -n +"$M" "$LOG" | grep -q '^pause HEADLESS-1 1'; then fail "PAUSE_FULLSCREEN=no still paused"; else ok "PAUSE_FULLSCREEN=no: a fullscreen window doesn't pause it"; fi
			sleep 1
		fi
		mark; say "hint game on"; sleep 0.5
		if tail -n +"$M" "$LOG" | grep -q '^pause HEADLESS-1 1'; then fail "a game paused it with PAUSE_GAME off"; else ok "PAUSE_GAME off (the default): a game doesn't pause it"; fi
		printf 'PAUSE_GAME=yes\n' >> "$XDG_CONFIG_HOME/ribbon/wallpaper.conf"; mark; say reload
		check "PAUSE_GAME=yes: a game pauses it" '^pause HEADLESS-1 1 game'
		mark; say "hint game off"; check "  and the game ending resumes it" '^pause HEADLESS-1 0'
		printf 'Battery\n' > "$T/power/type"; mkdir -p "$T/power/AC"; printf 'Mains\n' > "$T/power/AC/type"; printf '0\n' > "$T/power/AC/online"
		mkdir -p "$T/power/BAT0"; mv "$T/power/type" "$T/power/BAT0/type"
		printf 'PAUSE_BATTERY=yes\n' >> "$XDG_CONFIG_HOME/ribbon/wallpaper.conf"; mark; say reload
		check "PAUSE_BATTERY=yes: on battery it pauses" '^pause HEADLESS-1 1 battery'
		printf '1\n' > "$T/power/AC/online"; mark; say reload
		check "  and on mains it plays" '^pause HEADLESS-1 0'

		# the length limit: refused cleanly, the picture (IMAGE) shown instead
		stop
		printf 'MODE=video\nVIDEO=%s\nIMAGE=%s\n' "$T/loop.mp4" "$T/pics/p3.png" > "$XDG_CONFIG_HOME/ribbon/wallpaper.conf"
		start $renderer RIBBON_WALL_MAX_SECONDS=1
		check "a video over the length limit is refused" '^video-refused too long: 2.0 s, at most 1 s'
		sleep 0.5; c=$(pixel 640 360); near "$c" "#3060A0" 3 && ok "  its picture (IMAGE) is shown instead" || fail "refused video fallback $c"
		mark; say "preview video $T/loop.mp4"; check "  a preview of it is refused the same way" '^video-refused too long'
	fi

	# outputs: hotplug, a mode change, scale changes (integer and fractional)
	stop
	printf 'MODE=pattern\n' > "$XDG_CONFIG_HOME/ribbon/wallpaper.conf"
	start $renderer
	waitfor 'design-rendered HEADLESS-2' 20
	mark; wlr-randr --output HEADLESS-2 --off; check "an output unplugged" '^output-gone HEADLESS-2'
	mark; wlr-randr --output HEADLESS-2 --on --custom-mode 800x600; check "  and plugged in again: drawn for it" 'design-(rendered|shown) HEADLESS-2 .*800x600@1' 20
	mark; wlr-randr --output HEADLESS-1 --custom-mode 1600x900; check "a mode change: the design at the new size" 'design-rendered HEADLESS-1 .*1600x900@1' 20
	mark; wlr-randr --output HEADLESS-1 --scale 2; check "scale 2: drawn at full resolution" '^output HEADLESS-1 1600 900 2$' 10
	waitfor 'look-ribbon-[0-9a-f]+-1600x900@2' 20 && ok "  (design 1600x900@2)" || fail "  design at scale 2"
	mark; wlr-randr --output HEADLESS-1 --scale 1.5
	if waitfor '^output HEADLESS-1 1(599|600|601) 900 1.5$' 10; then ok "scale 1.5 (fractional-scale): 1600x900 pixels for a 1067x600 desktop"
		waitfor 'design-rendered HEADLESS-1 .*1(599|600|601)x900@1.5' 10 && ok "  (design 1600x900@1.5)" || fail "  design at scale 1.5"
	elif waitfor '^output HEADLESS-1 ' 5; then ok "scale 1.5: $(tail -n +"$M" "$LOG" | grep '^output HEADLESS-1' | tail -n 1) (no fractional-scale here)"
	else fail "scale 1.5"; fi
	mark; wlr-randr --output HEADLESS-1 --scale 1 --custom-mode 1280x720
	waitfor '^output HEADLESS-1 1280 720 1$' 10 || fail "back to 1280x720"
	# cached: the second time at a size takes no render
	mark; wlr-randr --output HEADLESS-1 --custom-mode 1600x900; sleep 1.5
	if tail -n +"$M" "$LOG" | grep -q 'design-rendered HEADLESS-1'; then fail "rendered again for a size it had"; else ok "a size seen before comes from the cache (no render)"; fi
	wlr-randr --output HEADLESS-1 --custom-mode 1280x720
	# a palette change: drawn anew on reload
	sed -i "s/^DESK_TOP=.*/DESK_TOP=#2040$([ $renderer = gl ] && echo 60 || echo 80)/" "$T/palette.conf"
	mark; say reload; check "a new palette: the design drawn again" 'design-rendered HEADLESS-1' 20
	stop
done

exit $status
