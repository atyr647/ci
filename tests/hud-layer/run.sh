#!/bin/sh
# tests/hud-layer/run.sh - VK_LAYER_RIBBON_hud_frames (apps/hud/native/hud-frames-layer.c), the Game HUD's frame
# source for Vulkan games outside gamescope. The layer is built as the template builds it, found by the real Vulkan
# loader through its manifest (ribbon-hud-frames.json, in an implicit_layer.d under XDG_DATA_HOME), and timed with a
# stand-in game (vkpresent.c: presents on a VK_EXT_headless_surface swapchain). The HUD's own reader
# (hud::frames::use_file, as the daemon runs it) reads the pipe.
# Needs cc, the Vulkan headers and loader, tclsh8.6, and a Vulkan driver with headless presentation (Mesa's lavapipe:
# point VK_DRIVER_FILES at its ICD file when it is not installed). Without the driver only the build and the manifest
# are checked.
set -u
cd "$(dirname "$0")/../.." || exit 1
N=$(pwd); D=$N/srcpkgs/ribbon-desktop/files/apps/hud; X=$N/tests/hud-layer
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }; note() { echo "  note $*"; }
for t in cc tclsh8.6; do command -v $t >/dev/null 2>&1 || { echo "  skip HUD frame layer (no $t)"; exit 0; }; done
[ -f /usr/include/vulkan/vulkan.h ] || pkg-config --exists vulkan 2>/dev/null || { echo "  skip HUD frame layer (no Vulkan headers)"; exit 0; }
T=$(mktemp -d "${TMPDIR:-/tmp}/hudlayer.XXXXXX") || exit 1
cleanup() { [ -n "${RP:-}" ] && kill "$RP" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
B=$T/b; mkdir -p "$B" "$T/xd/vulkan/implicit_layer.d" "$T/rt"; chmod 700 "$T/rt"

# ---- L1 the build and the manifest ----
make -s -C "$D/native" O="$B" CFLAGS="-O2 -Wall -Wextra -Werror" layer >"$T/build.log" 2>&1 && [ -s "$B/libribbon-hud-frames.so" ] &&
	ok "L1 libribbon-hud-frames.so builds with -Wall -Wextra -Werror ($(wc -c < "$B/libribbon-hud-frames.so") bytes)" ||
	{ cat "$T/build.log"; bad "L1 the layer does not build"; exit 1; }
if command -v nm >/dev/null 2>&1; then
	syms=$(nm -D --defined-only "$B/libribbon-hud-frames.so" | awk '$2 == "T" { print $3 }' | tr '\n' ' ')
	[ "$syms" = "vkNegotiateLoaderLayerInterfaceVersion " ] && ok "L1 it exports only vkNegotiateLoaderLayerInterfaceVersion" || bad "L1 exports: $syms"
fi
M=$D/native/ribbon-hud-frames.json
mf=$(tclsh8.6 <<EOF
set t [read [open $M]]
foreach {k re} {name {"name": "VK_LAYER_RIBBON_hud_frames"} type {"type": "GLOBAL"} lib {"library_path": "/usr/lib/ribbon/hud/libribbon-hud-frames.so"}
	off {"disable_environment": \{\s*"RIBBON_HUD_FRAMES_DISABLE": "1"\s*\}} neg {"vkNegotiateLoaderLayerInterfaceVersion"}} {
	if {![regexp \$re \$t]} { puts "missing \$k" }
}
EOF
)
if command -v python3 >/dev/null 2>&1 && ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$M" 2>/dev/null; then mf="$mf not JSON"; fi
[ -z "$mf" ] && ok "L1 the manifest: an implicit GLOBAL layer, the installed library path, RIBBON_HUD_FRAMES_DISABLE turns it off" || bad "L1 manifest: $mf"
# a privileged program (setcap or setuid: secure execution) takes no path from its caller's environment; the layer's
# own decision (decide()) in a stand-in made setcap and run as nobody, which needs root, setcap and setpriv
SD=$(mktemp -d "/tmp/hudlayer-sec.XXXXXX") && chmod 755 "$SD" &&
cat > "$SD/h.c" <<EOF
#include "$D/native/hud-frames-layer.c"
int main(void) { decide(); printf("enabled=%d path=%s\n", enabled, out_path); return 0; }
EOF
if [ "$(id -u)" = 0 ] && command -v setcap >/dev/null 2>&1 && command -v setpriv >/dev/null 2>&1 && id nobody >/dev/null 2>&1 &&
	cc -O2 -o "$SD/h" "$SD/h.c" -lpthread 2>"$T/sec.log" && chmod 755 "$SD/h" && setcap cap_sys_nice+ep "$SD/h" 2>>"$T/sec.log"; then
	sec=$(cd / && setpriv --reuid=65534 --regid=65534 --clear-groups env RIBBON_HUD_FRAMES=/etc/hud-sec-test XDG_RUNTIME_DIR=/etc "$SD/h")
	case "$sec" in
	"enabled=0 path=") ok "L1 a setcap program run by another user ignores RIBBON_HUD_FRAMES and XDG_RUNTIME_DIR (off)" ;;
	*) bad "L1 a setcap program takes its caller's path: $sec" ;;
	esac
else
	note "L1 the secure-execution check needs root, setcap and setpriv: not run"
fi
rm -rf "$SD"
sed "s|/usr/lib/ribbon/hud/libribbon-hud-frames.so|$B/libribbon-hud-frames.so|" "$M" >"$T/xd/vulkan/implicit_layer.d/ribbon-hud-frames.json"

if ! cc -O2 -Wall -Wextra -Werror -o "$B/vkpresent" "$X/vkpresent.c" -lvulkan >"$T/vk.log" 2>&1; then
	note "no Vulkan loader to link the stand-in game: the layer is not run ($(tail -1 "$T/vk.log"))"; exit $fail
fi
export XDG_DATA_HOME=$T/xd
unset RIBBON_HUD_FRAMES_DISABLE
FIFO=$T/rt/ribbon-hud-frames
mkfifo -m 600 "$FIFO"
# a game: vkpresent FRAMES MS [RECREATE], with the given extra environment
game() { env RIBBON_HUD_FRAMES="${GF:-$FIFO}" XDG_RUNTIME_DIR=$T/rt "$@"; }
game "$B/vkpresent" 2 1 >"$T/probe.out" 2>&1; rc=$?
if [ $rc = 77 ]; then note "no Vulkan driver with headless presentation here (set VK_DRIVER_FILES to lavapipe's ICD): the layer is not run"; exit $fail; fi
[ $rc = 0 ] || { cat "$T/probe.out"; bad "the stand-in game does not run"; exit 1; }

# ---- the HUD's reader: hud::frames::use_file on the pipe, polled every 16 ms, as the daemon does ----
# reader.tcl SECONDS [KEY]: prints "numbers ok fps ft low n" at the end and "pids P ..." (the producers it saw);
# with KEY the pick is the daemon's (hud::games::producer: the game KEY's processes, from the real /proc)
cat > "$T/reader.tcl" <<'EOF'
lassign $argv secs key fifo
source [file join $::env(HUD_DIR) hud.tcl]
hud::init_modules
hud::frames::use_file $fifo
if {$key ne ""} { hud::frames::configure -pick [list apply {{key cands} { hud::games::producer $key $cands {} }} $key] }
set seen {}
proc tick {} {
	hud::frames::poll
	foreach st $::hud::frames::file_state { dict for {p v} [dict get $st pids] { if {$p ni $::seen} { lappend ::seen $p } } }
	after 16 tick
}
puts ready; flush stdout
tick
after [expr {int($secs * 1000)}] { set ::done 1 }
vwait ::done
set n [hud::frames::numbers]
puts "numbers [dict get $n ok] [dict get $n fps] [dict get $n ft] [dict get $n low] [llength $::hud::frames::times]"
puts "pids $seen"
EOF
reader() { : > "$T/r.out"; HUD_DIR=$D tclsh8.6 "$T/reader.tcl" "$1" "${2:-}" "$FIFO" >"$T/r.out" 2>&1 & RP=$!
	i=0; while ! grep -q ready "$T/r.out" && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done; }
rwait() { wait "$RP" 2>/dev/null; RP=; }
num() { sed -n 's/^numbers //p' "$T/r.out"; }

# ---- L2 a game's frame times reach the HUD ----
echo "L2 a Vulkan game (120 frames, 10 ms apart) with the HUD reading the pipe"
reader 2.6
env RIBBON_HUD_FRAMES="$FIFO" XDG_RUNTIME_DIR=$T/rt "$B/vkpresent" 120 10 >"$T/g.out" 2>&1 & GP=$!
wait $GP; grc=$?; rwait
read -r rok rfps rft rlow rn <<EOF
$(num)
EOF
echo "     $(cat "$T/g.out"); the HUD: ok=$rok fps=$rfps frame time=$rft ms 1% low=$rlow, $rn frame times; producers: $(sed -n 's/^pids //p' "$T/r.out")"
[ "$grc" = 0 ] && ok "L2 the game ran to the end with the layer in it" || bad "L2 the game failed ($grc)"
[ "${rok:-0}" = 1 ] && ok "L2 the HUD has frame data from the layer" || bad "L2 no frame data: $(cat "$T/r.out")"
[ "${rn:-0}" = 119 ] && ok "L2 every frame was timed: 119 frame times for 120 presents (the last ones sent when the swapchain went)" || bad "L2 $rn frame times, not 119"
awk -v f="${rft:-0}" 'BEGIN { exit !(f >= 9.5 && f < 25) }' && ok "L2 the frame time is the presents' pace ($rft ms for 10 ms sleeps plus the frame's work)" || bad "L2 frame time $rft"
sed -n 's/^pids //p' "$T/r.out" | grep -qx "$GP" && ok "L2 the lines carry the game's process id ($GP)" || bad "L2 producers $(sed -n 's/^pids //p' "$T/r.out"), game $GP"

# ---- L3 a recreated swapchain (a resize): the timing goes on ----
cat "$FIFO" > "$T/raw.txt" & CP=$!
sleep 0.2
game "$B/vkpresent" 60 5 30 >/dev/null 2>&1; rc=$?
sleep 0.3; kill $CP 2>/dev/null; wait $CP 2>/dev/null
n=$(tr ' ' '\n' < "$T/raw.txt" | grep -c '^[0-9.]*$')
[ $rc = 0 ] && [ "$n" = 59 ] && ok "L3 a swapchain made from the old one (a resize) keeps the timing: $n frame times for 60 presents" || bad "L3 rc $rc, $n frame times"
awk '{ for (i = 2; i <= NF; i++) if ($i + 0 > 200) bad = 1 } END { exit bad }' "$T/raw.txt" && ok "L3 no frame time spans the swap" || bad "L3 a long frame time at the swap: $(cat "$T/raw.txt" | head -3)"
lines=$(grep -c '^pid=' "$T/raw.txt"); all=$(wc -l < "$T/raw.txt")
[ "$lines" = "$all" ] && [ "$lines" -ge 4 ] && ok "L3 $lines lines (about one per 50 ms), each pid=PID and its frame times" || bad "L3 $lines of $all lines are pid= lines"

# ---- L4 the game never waits on or dies for the HUD ----
echo "L4 no reader, a reader that leaves, a full pipe"
t0=$(date +%s%N); game "$B/vkpresent" 40 2 >/dev/null 2>&1; rc=$?; t1=$(date +%s%N)
[ $rc = 0 ] && ok "L4 nobody reads the pipe (no daemon): the game runs on ($(( (t1 - t0) / 1000000 )) ms for 40 frames)" || bad "L4 the game failed with no reader ($rc)"
( timeout 0.4 cat "$FIFO" > /dev/null ) & CP=$!
sleep 0.1
game "$B/vkpresent" 150 5 >"$T/g4.out" 2>&1; rc=$?
wait $CP 2>/dev/null
[ $rc = 0 ] && ok "L4 the reader went away mid-game: no SIGPIPE, the game ran to the end ($(cat "$T/g4.out"))" || bad "L4 the game died when the reader left (exit $rc)"
# a reader that holds the pipe open and never reads (the daemon while the HUD is hidden): the pipe fills
exec 9<>"$FIFO"
t0=$(date +%s%N); game "$B/vkpresent" 3000 0 >/dev/null 2>&1; rc=$?; t1=$(date +%s%N)
exec 9<&-
[ $rc = 0 ] && ok "L4 a full pipe never blocks the game: 3000 frames in $(( (t1 - t0) / 1000000 )) ms, the overflow dropped" || bad "L4 full pipe: exit $rc"

# ---- L5 off: RIBBON_HUD_FRAMES_DISABLE, gamescope, and a path that is not the daemon's pipe ----
cat "$FIFO" > "$T/off.txt" & CP=$!
sleep 0.2
game env RIBBON_HUD_FRAMES_DISABLE=1 "$B/vkpresent" 20 5 >/dev/null 2>&1; rc1=$?
cp "$B/vkpresent" "$B/gamescope"; game "$B/gamescope" 20 5 >/dev/null 2>&1; rc2=$?
sleep 0.3; kill $CP 2>/dev/null; wait $CP 2>/dev/null
[ $rc1 = 0 ] && [ $rc2 = 0 ] && [ ! -s "$T/off.txt" ] && ok "L5 RIBBON_HUD_FRAMES_DISABLE=1 and gamescope itself write nothing" || bad "L5 rc $rc1/$rc2, wrote: $(head -c 100 "$T/off.txt")"
mv "$FIFO" "$FIFO.keep"; : > "$FIFO"
env -u RIBBON_HUD_FRAMES XDG_RUNTIME_DIR=$T/rt "$B/vkpresent" 20 5 >/dev/null 2>&1
[ ! -s "$FIFO" ] && ok "L5 the default path as a plain file is not written (only the daemon's FIFO is)" || bad "L5 a plain file at the default path was written"
rm -f "$FIFO"; mv "$FIFO.keep" "$FIFO"
: > "$T/frames.txt"; GF=$T/frames.txt game "$B/vkpresent" 20 5 >/dev/null 2>&1
grep -q '^pid=' "$T/frames.txt" && ok "L5 a plain file that RIBBON_HUD_FRAMES names is appended to" || bad "L5 RIBBON_HUD_FRAMES file not written"

# ---- L6 the default path, and two programs at once: the game in front's frames, though another is busier ----
echo "L6 two Vulkan programs: the game (SteamAppId=620, 10 ms) and another (3 ms); the daemon's pick"
reader 3.2 steam:620
env -u RIBBON_HUD_FRAMES XDG_RUNTIME_DIR=$T/rt SteamAppId=620 "$B/vkpresent" 200 10 >/dev/null 2>&1 & G1=$!
env -u RIBBON_HUD_FRAMES XDG_RUNTIME_DIR=$T/rt "$B/vkpresent" 600 3 >/dev/null 2>&1 & G2=$!
wait $G1; wait $G2; rwait
read -r rok rfps rft rlow rn <<EOF
$(num)
EOF
echo "     the HUD: ok=$rok fps=$rfps frame time=$rft ms; producers seen: $(sed -n 's/^pids //p' "$T/r.out") (game $G1, other $G2)"
[ "${rok:-0}" = 1 ] && ok "L6 the layer writes \$XDG_RUNTIME_DIR/ribbon-hud-frames when RIBBON_HUD_FRAMES is not set" || bad "L6 no frame data on the default path"
sed -n 's/^pids //p' "$T/r.out" | tr ' ' '\n' | grep -qx "$G2" && sed -n 's/^pids //p' "$T/r.out" | tr ' ' '\n' | grep -qx "$G1" &&
	ok "L6 both programs' lines arrived, apart" || bad "L6 producers: $(sed -n 's/^pids //p' "$T/r.out")"
awk -v f="${rft:-0}" 'BEGIN { exit !(f >= 9.5 && f < 25) }' && ok "L6 the numbers are the game's (frame time $rft ms), not the busier program's (about 3 ms)" || bad "L6 frame time $rft: not the game's"

[ "$fail" = 0 ] && echo "HUD frame layer: all checks passed"
exit $fail
