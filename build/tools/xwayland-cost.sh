#!/bin/sh
# xwayland-cost.sh - what running the Tk desktop through XWayland costs
# (docs/STACK.md §3.2). Starts a headless labwc (pixman renderer), runs a
# small Tk window and then the Ribbon shell (tests/shell-scene.tcl) through
# labwc's XWayland, and reports:
#   - resident and proportional memory (RSS, PSS) of labwc, Xwayland and wish,
#     and the same shell under Xvfb for comparison
#   - how long the first X client waits for XWayland to start (labwc starts it
#     lazily) and how long a second one waits
#   - fractional scaling: a Tk window of 1-pixel black and white stripes,
#     captured with grim at output scale 1, 1.5 and 2; more than two grey
#     levels means the compositor resampled (blurred) the X11 buffer
#
# Needs labwc, Xwayland, Xvfb, wish8.6, grim, wlr-randr and python3 with PIL.
# Usage: build/tools/xwayland-cost.sh [SCRATCH_DIR]   (default: mktemp -d)
set -u
repo=$(cd "$(dirname "$0")/../.." && pwd)
work=${1:-$(mktemp -d)}
mkdir -p "$work/run" "$work/cfg" "$work/home"
chmod 700 "$work/run"
pids=""
cleanup() { for p in $pids; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT INT TERM

mem() { # pid -> "RSS PSS" in MiB
	awk '/^Rss:/{r=$2} /^Pss:/{p=$2} END{printf "%6.1f %6.1f", r/1024, p/1024}' "/proc/$1/smaps_rollup" 2>/dev/null
}
row() { printf '  %-44s %s MiB (RSS PSS)\n' "$1" "$(mem "$2")"; }
now() { date +%s%N; }

cat > "$work/cfg/rc.xml" <<'EOF'
<?xml version="1.0"?>
<labwc_config><core><decoration>server</decoration></core></labwc_config>
EOF
cat > "$work/plain.tcl" <<'EOF'
# a plain Tk window; prints the time it was first mapped
wm geometry . 400x300+0+0
label .l -text "Ribbon" -font {Sans 24}; pack .l -expand 1 -fill both
tkwait visibility .
puts [clock microseconds]; flush stdout
EOF
cat > "$work/stripes.tcl" <<'EOF'
# 1-pixel black/white vertical stripes, 200x100, at the top left
wm overrideredirect . 1; wm geometry . 200x100+0+0
canvas .c -width 200 -height 100 -highlightthickness 0 -bd 0 -bg white
pack .c
for {set x 0} {$x < 200} {incr x 2} { .c create line $x 0 $x 100 -fill black -width 1 }
tkwait visibility .; puts ready; flush stdout
EOF

export XDG_RUNTIME_DIR="$work/run" WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman
labwc -C "$work/cfg" -s "sh -c 'env > $work/env'" > "$work/labwc.log" 2>&1 &
lab=$!; pids="$lab"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$work/env" ] && break; sleep 0.5; done
DISPLAY=$(sed -n 's/^DISPLAY=//p' "$work/env"); WAYLAND_DISPLAY=$(sed -n 's/^WAYLAND_DISPLAY=//p' "$work/env")
export DISPLAY WAYLAND_DISPLAY
echo "labwc $(labwc --version 2>/dev/null | awk '{print $2}'), $(Xwayland -version 2>&1 | sed -n 's/.*Xwayland Version \([^ ]*\).*/Xwayland \1/p'), Tk $(echo 'puts [info patchlevel]' | tclsh8.6)"
echo "memory"
row "labwc, no X client yet" "$lab"
xw=$(pgrep -a -x Xwayland | awk -v d="$DISPLAY" '$3 == d {print $1; exit}')
[ -n "$xw" ] && echo "  (Xwayland already running)" || echo "  Xwayland: not started yet (lazy)"

t0=$(now)
wish8.6 "$work/plain.tcl" > "$work/plain.out" 2>&1 &
w1=$!; pids="$pids $w1"
for _ in $(seq 1 40); do [ -s "$work/plain.out" ] && break; sleep 0.1; done
t1=$(head -n 1 "$work/plain.out")
sleep 1
xw=$(pgrep -a -x Xwayland | awk -v d="$DISPLAY" '$3 == d {print $1; exit}')
row "Xwayland, one plain Tk window" "$xw"
row "wish, plain Tk window" "$w1"
row "labwc, with XWayland running" "$lab"

t2=$(now)
wish8.6 "$work/plain.tcl" > "$work/plain2.out" 2>&1 &
w2=$!; pids="$pids $w2"
for _ in $(seq 1 40); do [ -s "$work/plain2.out" ] && break; sleep 0.1; done
t3=$(head -n 1 "$work/plain2.out")
kill "$w2" 2>/dev/null

HOME="$work/home" RIBBON_SHELL_TEST="$repo/tests/shell-scene.tcl" RIBBON_SCENE=launcher \
	wish8.6 -encoding utf-8 "$repo/srcpkgs/ribbon-desktop/files/shell/main.tcl" -name ribbon-shell \
	> "$work/shell.log" 2>&1 &
sh1=$!; pids="$pids $sh1"
sleep 8
row "wish, Ribbon shell (launcher scene)" "$sh1"
row "Xwayland, plain window + shell" "$xw"
row "labwc" "$lab"

Xvfb :77 -screen 0 1280x720x24 -nolisten tcp > /dev/null 2>&1 &
xv=$!; pids="$pids $xv"
sleep 1
HOME="$work/home" DISPLAY=:77 RIBBON_SHELL_TEST="$repo/tests/shell-scene.tcl" RIBBON_SCENE=launcher \
	wish8.6 -encoding utf-8 "$repo/srcpkgs/ribbon-desktop/files/shell/main.tcl" -name ribbon-shell \
	> "$work/shell-xvfb.log" 2>&1 &
sh2=$!; pids="$pids $sh2"
sleep 8
row "wish, Ribbon shell under Xvfb" "$sh2"
row "Xvfb, shell only" "$xv"
kill "$sh1" "$sh2" "$w1" 2>/dev/null

echo "first map (process start to tkwait visibility)"
echo "  first X client (XWayland starts lazily): $(( (t1 - t0 / 1000) / 1000 )) ms"
echo "  second X client:                         $(( (t3 - t2 / 1000) / 1000 )) ms"

echo "fractional scaling (Tk window of 1 px stripes, grey levels in the capture)"
out=$(wlr-randr 2>/dev/null | awk 'NR==1{print $1}')
wish8.6 "$work/stripes.tcl" > "$work/stripes.out" 2>&1 &
st=$!; pids="$pids $st"
for _ in $(seq 1 40); do [ -s "$work/stripes.out" ] && break; sleep 0.1; done
for s in 1 1.5 2; do
	wlr-randr --output "$out" --scale "$s" 2>/dev/null
	sleep 1.5
	grim -g "0,0 120x60" "$work/stripes-$s.png" 2>/dev/null
	python3 -I - "$work/stripes-$s.png" "$s" <<'EOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("L")
w, h = im.size
px = im.tobytes()
levels = set(px)
mid = sum(1 for v in px if 16 < v < 240)
print(f"  scale {sys.argv[2]:>3}: capture {w}x{h} px, {len(levels)} grey levels, {100*mid/(w*h):.0f}% of pixels neither black nor white")
EOF
done
echo "(work dir: $work)"
