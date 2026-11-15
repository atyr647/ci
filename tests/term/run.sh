#!/bin/sh
# run.sh [ROOT] - Ribbon Terminal (foot + the Tk tab strip in the shell, docs/TERMINAL.md) in a headless labwc:
# the real shell (shell/mod-term.tcl, apps/term/strip.tcl), the real ribbon-shell-watch with its virtual keyboard,
# `foot --server` and footclient tabs. Checks: tabs appear and go with footclient windows, switching, Alt+number
# (a foot key binding that calls ribbon-term-ctl), the virtual keyboard's `key` command, the new-output mark,
# a move that keeps the strip and the tabs together, the snap keys, SendToDesktop, and the dock's one Terminal button.
# ROOT: a test root of prebuilt packages with labwc 0.8 or later, foot, wish8.6, grim, ImageMagick (CI: build/ci/labwc020.sh). Without ROOT it uses the host's labwc, which
# must be at least 0.7 for the virtual keyboard; the checks that need ForEach / If in rc.xml (0.8 and later) are skipped.
# SHOTS=dir keeps the screenshots; KEEPLOG=file keeps the log.
set -u
cd "$(dirname "$0")/../.." || exit 1
N=$(pwd); ROOT=${1:-}
D=$N/srcpkgs/ribbon-desktop/files; X=$N/tests/term
T0=${TMPDIR:-/tmp}/rtt.$$; T=$T0; B=$T0/bin
if [ -n "$ROOT" ]; then T0=$ROOT/tmp/rtt.$$; T=/tmp/rtt.$$; B=$T/bin; fi
R() { if [ -n "$ROOT" ]; then chroot "$ROOT" "$@"; else "$@"; fi; }
mkdir -p "$T0/bin" "$T0/rt" "$T0/sys/labwc" "$T0/gen/labwc" "$T0/home/.config/foot" "$T0/home/.config/ribbon" "$T0/cache" "$T0/state" "$T0/shell" "$T0/tabs" "$T0/shots" "$T0/share/applications"
chmod 700 "$T0/rt"
S=$T0/bin
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }; note() { echo "  note $*"; }
reap() { _rf=$(mktemp) || return 0; jobs -p >"$_rf"; while read -r _rp; do kill -"$1" "$_rp" 2>/dev/null; done <"$_rf"; rm -f "$_rf"; }
cleanup() { [ -n "${KEEPLOG:-}" ] && { cp "$T0/term.log" "$KEEPLOG" 2>/dev/null; cp "$T0/labwc.log" "$KEEPLOG.labwc" 2>/dev/null; cp "$T0/shell.out" "$KEEPLOG.shell" 2>/dev/null; cp "$T0/gen/labwc/rc.xml" "$KEEPLOG.rc.xml" 2>/dev/null; cat "$T0"/state/ribbon/shell.log > "$KEEPLOG.fault" 2>/dev/null; }
	reap TERM; pkill -f "rtt\.$$/" 2>/dev/null; sleep 0.5; reap KILL; pkill -9 -f "rtt\.$$/" 2>/dev/null
	if [ -n "$ROOT" ]; then [ -n "${PTS:-}" ] && umount "$ROOT/dev/pts" 2>/dev/null; umount "$ROOT/proc" "$ROOT/dev/shm" 2>/dev/null; [ -n "${BOUND:-}" ] && umount "$ROOT/dev" 2>/dev/null; fi
	[ -n "${SHOTS:-}" ] && cp "$T0"/shots/*.png "$SHOTS"/ 2>/dev/null; rm -rf "$T0"; }
trap cleanup EXIT
for t in labwc foot wish8.6 grim convert wayland-scanner; do
	if [ -z "$ROOT" ] && ! command -v $t >/dev/null 2>&1; then echo "  skip term (no $t)"; exit 0; fi
done
LV=$(R labwc -v 2>/dev/null | sed -n 's/^labwc \([0-9]*\.[0-9]*\).*/\1/p')
case $LV in 0.[0-6]|"") echo "  skip term: labwc ${LV:-?} has no virtual-keyboard support worth testing; run with a test root (labwc 0.8 or later; CI: build/ci/labwc020.sh): tests/term/run.sh ROOT"; exit 0;; esac
OLD=0; case $LV in 0.7) OLD=1;; esac    # no ForEach / If in rc.xml: no placing, no rebinds

# ---- build (host toolchain) ----
make -s -C "$D/shell-watch" O="$S" CFLAGS="-O2 -Wall -Wextra -Werror" ribbon-shell-watch >"$T0/build.log" 2>&1 || { cat "$T0/build.log"; bad "ribbon-shell-watch does not build"; exit 1; }
ok "ribbon-shell-watch builds with -Wall -Wextra -Werror ($(wc -c < "$S/ribbon-shell-watch") bytes)"
make -s -C "$D/rbnalpha" O="$S" >/dev/null 2>&1 && { mkdir -p "$T0/shell-ext/rbnalpha"; cp "$D"/rbnalpha/pkgIndex.tcl "$D"/rbnalpha/rbnalpha.tcl "$S/librbnalpha.so" "$T0/shell-ext/rbnalpha/"; }
cp -r "$D/shell/." "$T0/shell/"; cp -r "$D/rbnalpha" "$T0/rbnalpha"; [ -f "$S/librbnalpha.so" ] && cp "$S/librbnalpha.so" "$T0/rbnalpha/"
mkdir -p "$T0/term"; cp "$D"/apps/term/*.tcl "$T0/term/"
cp "$D/apps/term/bin/ribbon-term-ctl" "$D/apps/term/bin/ribbon-terminal" "$D/bin/ribbon-shell-ctl" "$X/tabsh" "$X/hook.tcl" "$S/"
# the preferences tab (apps/term/prefs-main.tcl) draws with Appearance's ui.tcl and Properties' widgets.tcl
cp -r "$D/appearance" "$D/properties" "$T0/"
printf '#!/bin/sh\nexec wish8.6 -encoding utf-8 %s/term/prefs-main.tcl -name ribbon-term-prefs -- "$@"\n' "$T" > "$S/ribbon-term-prefs"; chmod +x "$S/ribbon-term-prefs"
cp "$D/apps/term/applications/ribbon-terminal.desktop" "$T0/share/applications/"
cp "$D/themes/palettes/ribbon.conf" "$T0/home/.config/ribbon/palette.conf"

# ---- headless labwc: Ribbon's decisions that matter here, and the rebinds of apps/term (the rc.xml INTEGRATION REQUEST) ----
snap() { echo "<keybind key=\"W-$1\"><action name=\"If\"><query identifier=\"ribbon-term-*\"/><then><action name=\"Execute\" command=\"ribbon-term-ctl snap $2\"/></then><else><action name=\"SnapToEdge\" direction=\"$3\"/></else></action></keybind>"; }
sendto() { echo "<keybind key=\"W-S-$1\"><action name=\"If\"><query identifier=\"ribbon-term-*\"/><then><action name=\"Execute\" command=\"ribbon-term-ctl sendto $1\"/></then><else><action name=\"SendToDesktop\" to=\"$1\"/></else></action></keybind>"; }
{
echo '<labwc_config><core><decoration>server</decoration><gap>8</gap></core><margin top="54" bottom="54" />'
echo '<placement><policy>cascade</policy></placement><focus><followMouse>no</followMouse><raiseOnFocus>no</raiseOnFocus></focus>'
echo '<desktops><names><name>1</name><name>2</name><name>3</name></names></desktops>'
echo '<keyboard><default />'
snap Left left left; snap Right right right; snap Up max up; snap Down restore down
sendto 1; sendto 2; sendto 3
echo "<keybind key=\"A-F7\"><action name=\"Execute\" command=\"$B/ribbon-shell-ctl probe\" /></keybind>"
echo '</keyboard>'
echo '<mouse><default /><context name="Frame">'
for b in "A-Left Move" "A-Right Resize"; do set -- $b
	echo "<mousebind button=\"$1\" action=\"Drag\"><action name=\"If\"><query identifier=\"ribbon-term-*\"/><then><action name=\"None\"/></then><else><action name=\"$2\"/></else></action></mousebind>"
done
echo '</context></mouse></labwc_config>'
} > "$T0/sys/labwc/rc.xml"
echo '<labwc_config/>' > "$T0/gen/labwc/rc.xml"
echo 'echo "$DISPLAY" > "$XDG_RUNTIME_DIR/display"' > "$T0/sys/labwc/autostart"
cat > "$T0/home/.config/foot/foot.ini" <<EOF
[main]
shell=$B/tabsh
font=monospace:size=10
pad=8x4
resize-by-cells=no
[csd]
preferred=none
[colors-dark]
background=0a141e
foreground=EEE9E3
[key-bindings]
pipe-visible=[ribbon-term-ctl tab 1] Mod1+1
pipe-visible=[ribbon-term-ctl tab 2] Mod1+2
pipe-visible=[ribbon-term-ctl tab 3] Mod1+3
pipe-visible=[ribbon-term-ctl new] Control+Shift+t
[desktop-notifications]
command=ribbon-term-ctl activity-app \${app-id}
EOF
[ -n "$ROOT" ] && { mkdir -p "$ROOT/proc" "$ROOT/dev/shm"; mount -t proc proc "$ROOT/proc" 2>/dev/null
	if [ ! -e "$ROOT/dev/urandom" ]; then mount --bind /dev "$ROOT/dev" 2>/dev/null && BOUND=1; else mount -t tmpfs tmpfs "$ROOT/dev/shm" 2>/dev/null; fi
	# foot needs a pty
	mkdir -p "$ROOT/dev/pts"; mountpoint -q "$ROOT/dev/pts" || { mount --bind /dev/pts "$ROOT/dev/pts" 2>/dev/null && PTS=1; }; }
# not through R: $! must be labwc's own pid (the shell sends it SIGHUP to reload)
if [ -n "$ROOT" ]; then LWRAP="chroot $ROOT"; else LWRAP=; fi
$LWRAP env PATH=$B:/usr/local/bin:/usr/bin:/bin WAYLAND_DISPLAY='' WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1 \
	XDG_RUNTIME_DIR=$T/rt HOME=$T/home XDG_CONFIG_HOME=$T/home/.config XDG_CONFIG_DIRS=$T/gen:$T/sys labwc -m >"$T0/labwc.log" 2>&1 &
LPID=$!
i=0; while [ ! -s "$T0/rt/display" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
sock=; for f in "$T0"/rt/wayland-*; do case $f in *.lock) ;; *) [ -S "$f" ] && sock=${f##*/} ;; esac; done
[ -n "$sock" ] || { cat "$T0/labwc.log"; echo "no labwc"; exit 1; }
R env XDG_RUNTIME_DIR=$T/rt WAYLAND_DISPLAY=$sock wlr-randr --output HEADLESS-1 --custom-mode 1440x900 >/dev/null 2>&1
DISP=$(cat "$T0/rt/display")
echo "compositor: $(R labwc -v | head -1), $(R foot --version | cut -d' ' -f1-3), socket $sock"
LOG=$T0/term.log; : > "$LOG"
E="XDG_RUNTIME_DIR=$T/rt WAYLAND_DISPLAY=$sock DISPLAY=$DISP HOME=$T/home XDG_CONFIG_HOME=$T/home/.config XDG_CACHE_HOME=$T/cache XDG_STATE_HOME=$T/state XDG_DATA_DIRS=$T/share PATH=$B:/usr/local/bin:/usr/bin:/bin LC_ALL=C.UTF-8 LABWC_PID=$LPID RIBBON_TERM_RC=$T/gen/labwc/rc.xml RIBBON_TERM_LOG=$T/term.log RTT_LOG=$T/term.log RTT_CMD=$T/cmd RTT_TABDIR=$T/tabs SHELL=$B/tabsh RIBBON_SHELL_TEST=$T/bin/hook.tcl"
shot() { R env $E grim "$T/shots/$1.png"; }
px() { convert "$T0/shots/$1.png" -format "%[fx:int(255*p{$2,$3}.r)],%[fx:int(255*p{$2,$3}.g)],%[fx:int(255*p{$2,$3}.b)]" info:; }
FOOT=10,20,30
waitlog() { i=0; while [ "$(grep -c "$1" "$LOG" 2>/dev/null)" -lt "${2:-1}" ] && [ $i -lt ${3:-200} ]; do sleep 0.05; i=$((i + 1)); done; [ "$(grep -c "$1" "$LOG")" -ge "${2:-1}" ]; }
mkfifo "$T0/cmd"; exec 8<>"$T0/cmd"
hk() { echo "$@" >&8; }
# ask the shell what it sees and wait for the answer
ask() { n=$(grep -c " $1 " "$LOG"); hk "$1"; i=0; while [ "$(grep -c " $1 " "$LOG")" -le "$n" ] && [ $i -lt 100 ]; do sleep 0.02; i=$((i + 1)); done; grep " $1 " "$LOG" | tail -1; }
now() { date +%s%3N; }
# askv NAME TCL: the shell evaluates TCL and logs "NAME value"; the line comes back
askv() { n=$(grep -c " $1 " "$LOG"); hk "say $1 $2"; i=0; while [ "$(grep -c " $1 " "$LOG")" -le "$n" ] && [ $i -lt 100 ]; do sleep 0.02; i=$((i + 1)); done; grep " $1 " "$LOG" | tail -1; }
# close windows IDS and wait (up to 5 s) until each is gone from the toplevel stream
closeids() { for id in $1; do hk "wm::send close $id"; j=0; while [ $j -lt 50 ]; do ask "has $id" | grep -q " has $id 0" && break; sleep 0.1; j=$((j + 1)); done; done; }

R env $E wish8.6 -encoding utf-8 $T/shell/main.tcl -name ribbon-shell >"$T0/shell.out" 2>&1 &
SHPID=$!
waitlog hooked 1 400 || { cat "$T0/shell.out"; tail -5 "$LOG"; bad "the shell did not start"; exit 1; }
sleep 0.5

# ---- the virtual keyboard's `key` command ----
j=0
while [ $j -lt 5 ]; do hk "kt A-F7"; waitlog " probe " $((j + 1)) 60; j=$((j + 1)); done
if [ "$(grep -c ' probe ' "$LOG")" -ge 5 ]; then
	ok "key A-F7 pressed on the virtual keyboard reached labwc's keybind (5 of 5)"
	grep ' probe ' "$LOG" | awk '{ s += $3; if (!m || $3 < m) m = $3; n++ } END { printf "  note key to keybind running ribbon-shell-ctl probe: mean %.1f ms, min %.1f ms (includes starting sh + timeout + the shell reading the FIFO)\n", s / n / 1000, m / 1000 }'
else bad "key A-F7 did not reach the keybind ($(grep -c ' probe ' "$LOG") of 5)"; fi

# ---- tabs appear with footclient windows: ribbon-terminal opens the terminal, ribbon-term-ctl new adds tabs ----
t0=$(now); R env $E $B/ribbon-terminal
waitlog "select g1" 1 100
t1=$(now)
R env $E $B/ribbon-term-ctl new; waitlog "select g1" 2 100
R env $E $B/ribbon-term-ctl new; waitlog "select g1" 3 100
sleep 0.5
a=$(ask tabs)
n=$(echo "$a" | grep -o "tabs=[0-9 ]*" | tail -1 | wc -w)
[ "$n" -eq 3 ] && ok "three footclient windows are three tabs of group g1 ($((t1 - t0)) ms from ribbon-terminal to the first tab selected, foot --server started by the shell)" || bad "tabs: $a"
w=$(ask wins)
# the strip's window rule has skipTaskbar: it is not in the toplevel stream (so not in the dock or Alt+Tab); it is checked on screen below
echo "$w" | grep -q "ribbon-term-strip" && bad "the strip is in the toplevel stream: $w" || ok "the strip window is not in the toplevel stream (skipTaskbar), only the three tabs are"
echo "$w" | grep -o "ribbon-term-g1-[0-9]" | sort | tr '\n' ' ' | grep -q "ribbon-term-g1-1 ribbon-term-g1-2 ribbon-term-g1-3" && ok "app-ids ribbon-term-g1-1..3" || bad "app-ids: $w"
[ "$(pgrep -f "rtt\.$$/.*foot --server" | wc -l)" -le 1 ] && ok "one foot --server" || bad "more than one foot server"
nmin=$(echo "$w" | grep -o "ribbon-term-g1-[0-9] [a-z,-]*" | grep -c min)
[ "$nmin" -eq 2 ] && ok "two tabs minimised behind the front one" || bad "minimised tabs: $nmin ($w)"

# ---- the dock: one Terminal button with the count ----
d=$(ask dock)
echo "$d" | grep -q "ribbon-terminal n=3 Terminal" && ok "the dock shows one Terminal button for the three tabs ($(echo "$d" | cut -d' ' -f3-))" || bad "dock: $d"

# ---- switching: activate the new tab, minimise the old ----
switch_to() { # N: wait until the shell has tab N in front and the rest minimised
	i=0; while [ $i -lt 100 ]; do w=$(ask wins); m=$(echo "$w" | grep -o "ribbon-term-g1-$1 [a-z,-]*" | grep -c min); o=$(echo "$w" | grep -o "ribbon-term-g1-[0-9] [a-z,-]*" | grep -c min); [ "$m" -eq 0 ] && [ "$o" -eq 2 ] && return 0; i=$((i + 1)); sleep 0.02; done; return 1; }
t0=$(now); R env $E $B/ribbon-term-ctl tab 1
switch_to 1 && ok "ribbon-term-ctl tab 1: tab 1 up, the other two minimised ($(( $(now) - t0 )) ms including starting ribbon-term-ctl and polling)" || bad "switch to tab 1: $w"
grep "select g1" "$LOG" | tail -1 | awk '{ printf "  note shell side of that switch: activate + minimize + raise written in %.2f ms\n", $NF }'
R env $E $B/ribbon-term-ctl next; switch_to 2 && ok "next: tab 2" || bad "next: $w"
R env $E $B/ribbon-term-ctl prev; switch_to 1 && ok "prev: tab 1" || bad "prev: $w"
# Alt+number: the virtual keyboard presses Alt+3 into the front tab; foot's key binding calls ribbon-term-ctl
t0=$(now); hk "kt A-3"; switch_to 3 && ok "Alt+3 (virtual keyboard, foot pipe binding, ribbon-term-ctl) switched to tab 3 ($(( $(now) - t0 )) ms with polling)" || bad "Alt+3: $w"
hk "kt A-1"; switch_to 1 && ok "Alt+1 switched back to tab 1" || bad "Alt+1: $w"

# ---- new output in a background tab marks it (the title changes: OSC 2) ----
ff=$(ls -tr "$T0"/tabs/fifo.* | sed -n 2p)
echo "build output" > "$ff"; sleep 0.5
a=$(ask tabs)
echo "$a" | grep -q "marks=[0-9]" && ok "a title change in a background tab marks it ($(echo "$a" | grep -o 'marks=[0-9 ]*'))" || bad "no mark: $a"
R env $E $B/ribbon-term-ctl tab 2; sleep 0.4
a=$(ask tabs); echo "$a" | grep -q "marks=[0-9]" && bad "the mark stays on the front tab: $a" || ok "bringing the tab up clears its mark"
R env $E $B/ribbon-term-ctl tab 1; sleep 0.3
# a notification (OSC 777, what foot's urgency/bell path cannot name a tab for) marks the tab through foot's [desktop-notifications] command
ff3=$(ls -tr "$T0"/tabs/fifo.* | sed -n 3p)
echo "notify:finished" > "$ff3"; sleep 0.8
FV=$(R foot --version | sed -n 's/^foot version: 1\.\([0-9]*\).*/\1/p')
a=$(ask tabs)
if echo "$a" | grep -q "marks=[0-9]"; then ok "an OSC 777 notification marks its tab (foot passes \${app-id} to ribbon-term-ctl activity-app)"
elif [ "${FV:-0}" -lt 20 ]; then note "foot 1.$FV has no [desktop-notifications] command with \${app-id} (1.20 and later do): the notification mark is checked with a test root only"
else bad "no mark from the notification: $a"; fi
R env $E $B/ribbon-term-ctl tab 3; sleep 0.3; R env $E $B/ribbon-term-ctl tab 1; sleep 0.3

if [ $OLD -eq 1 ]; then
	note "labwc $LV has no ForEach / If: the strip's place, the rebinds and SendToDesktop are checked only with a test root (labwc 0.8 or later)"
else
# ---- geometry: strip and tabs glued, then moved together ----
sleep 0.5; shot g1; cp "$T0/gen/labwc/rc.xml" "$T0/rc.mid" 2>/dev/null; [ -n "${KEEPLOG:-}" ] && cp "$T0/rc.mid" "$KEEPLOG.rc.mid"
a=$(ask tabs); rect=$(echo "$a" | grep -o "rect=[-0-9,]*" | tail -1 | sed 's/rect=//'); X0=${rect%%,*}; rest=${rect#*,}; Y0=${rest%%,*}
cx=$((X0 + 500))
s=$(px g1 $cx $((Y0 + 20))); f=$(px g1 $cx $((Y0 + 42))); g=$(px g1 $cx $((Y0 + 41)))
[ "$f" = "$FOOT" ] && [ "$g" != "$FOOT" ] && [ "$s" != "$FOOT" ] && ok "the front tab starts at the strip's foot (y $((Y0 + 42)): foot $f; y $((Y0 + 41)): strip $g)" || bad "glue: strip $s, last strip row $g, first foot row $f at $X0,$Y0 ($a)"
hk "term::move_start 700 $((Y0 + 20))"; for k in 1 2 3 4 5; do hk "term::move_drag $((700 + 40 * k)) $((Y0 + 20 + 15 * k))"; sleep 0.06; done; hk "term::move_end 900 $((Y0 + 20 + 75))"
sleep 0.8; shot g2
a=$(ask tabs); rect=$(echo "$a" | grep -o "rect=[-0-9,]*" | tail -1 | sed 's/rect=//'); X1=${rect%%,*}; rest=${rect#*,}; Y1=${rest%%,*}
cx=$((X1 + 500))
f=$(px g2 $cx $((Y1 + 42))); g=$(px g2 $cx $((Y1 + 41))); old=$(px g2 $((X0 + 50)) $((Y0 + 20))); oldf=$(px g2 $((X0 + 50)) $((Y0 + 300)))
[ "$X1" -gt "$X0" ] && [ "$Y1" -gt "$Y0" ] && ok "the group moved from $X0,$Y0 to $X1,$Y1" || bad "the group did not move ($X0,$Y0 -> $X1,$Y1)"
[ "$f" = "$FOOT" ] && [ "$g" != "$FOOT" ] && [ "$g" != "0,0,0" ] && ok "after the move the front tab is still under the strip (foot $f at y $((Y1 + 42)), strip $g above it)" || bad "after the move: foot $f, strip $g"
[ "$old" != "$FOOT" ] && [ "$oldf" != "$FOOT" ] && ok "nothing is left at the old place (strip row $old, tab area $oldf)" || bad "the old place still shows the terminal ($old / $oldf)"
grep ' place g1 ' "$LOG" | awk '$5 == 1 { r += $NF; n++ } END { if (n) printf "  note move: rc.xml rewrite + SIGHUP + key written %.1f ms (mean of %d)\n", r / n, n }'
grep ' place g1 ' "$LOG" | awk '{ r += $NF; n++ } END { if (n) printf "  note every place incl. those without a rewrite: %.2f ms (mean of %d)\n", r / n, n }'

# ---- the snap keys go through the strip (W-Left would otherwise move one tab alone) ----
hk "kt W-Left"; sleep 1.0; a=$(ask tabs); rect=$(echo "$a" | grep -o "rect=[-0-9,]*" | tail -1 | sed 's/rect=//')
shot g3
sx=$(echo "$rect" | cut -d, -f1); sy=$(echo "$rect" | cut -d, -f2)
[ "$sx" = "8" ] && ok "W-Left snapped the group (rect $rect)" || bad "W-Left: $rect"
f=$(px g3 $((sx + 300)) $((sy + 42))); g=$(px g3 $((sx + 300)) $((sy + 41)))
[ "$f" = "$FOOT" ] && [ "$g" != "$FOOT" ] && ok "after the snap the tab is under the strip, together" || bad "after the snap: foot $f, strip $g"
hk "kt W-Down"; sleep 0.8; a=$(ask tabs); echo "$a" | grep -q "rect=$X1,$Y1," && ok "W-Down restored the rectangle from before the snap" || bad "restore: $a"

# ---- SendToDesktop for the whole group (W-S-2 through the strip: the group follows to desktop 2) ----
hk "kt W-S-2"; sleep 1.0; shot g4
f=$(px g4 $((X1 + 500)) $((Y1 + 200))); st=$(px g4 $((X1 + 500)) $((Y1 + 20)))
[ "$f" = "$FOOT" ] && [ "$st" != "0,0,0" ] && ok "W-S-2 sent the group, strip and tab, to desktop 2 (both are on screen after the switch)" || bad "W-S-2: $f at $X1,$Y1"

fi
# ---- a shell restart: the group keeps its rectangle, its saved rectangle and its tab (term-groups in the state folder) ----
# (under labwc 0.7 there is no placing, so the pixel check is only made on 0.8 and later)
R env $E $B/ribbon-term-ctl tab 2; switch_to 2 || bad "tab 2 before the restart: $(ask wins)"
RECT0=$(ask tabs | grep -o "rect=[-0-9,]*" | tail -1 | sed 's/rect=//')
R env $E $B/ribbon-term-ctl snap left; i=0; while [ $i -lt 100 ]; do RECT=$(ask tabs | grep -o "rect=[-0-9,]*" | tail -1 | sed 's/rect=//'); [ "$RECT" != "$RECT0" ] && break; i=$((i + 1)); sleep 0.05; done
ST=$T0/state/ribbon/term-groups; sleep 0.8   # the save is debounced (400 ms)
st=$(cat "$ST" 2>/dev/null)
echo "$st" | grep -q "^g1 $(echo "$RECT" | tr , ' ') 0 2 $RECT0\$" && ok "term-groups holds g1's rectangle $RECT, its rectangle before the snap $RECT0 and tab 2 ($st)" || bad "term-groups before the restart: '$st' (rect $RECT, before $RECT0)"
# the shell itself (SHPID is the subshell around R, not the chrooted wish): two shells would both run the terminal
kill $SHPID 2>/dev/null; pkill -f "rtt\.$$/shell/main\.tcl"; wait $SHPID 2>/dev/null
i=0; while pgrep -f "rtt\.$$/shell/main\.tcl" >/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
R env $E wish8.6 -encoding utf-8 $T/shell/main.tcl -name ribbon-shell >>"$T0/shell.out" 2>&1 &
SHPID=$!
i=0; while [ $i -lt 200 ] && ! ask tabs | grep -q "groups=g1"; do i=$((i + 1)); sleep 0.05; done
[ $i -lt 200 ] || { cat "$T0/shell.out"; bad "the shell did not answer after the restart"; }
i=0; while [ $i -lt 150 ]; do a=$(ask tabs); [ "$(echo "$a" | grep -o "rect=[-0-9,]*" | tail -1 | sed 's/rect=//')" = "$RECT" ] && break; i=$((i + 1)); sleep 0.1; done
[ "$(echo "$a" | grep -o "rect=[-0-9,]*" | tail -1 | sed 's/rect=//')" = "$RECT" ] && ok "after the shell restart the group is back at $RECT" || bad "after the restart: $a (want rect $RECT)"
switch_to 2 && ok "after the shell restart tab 2 is in front and the others are minimised" || bad "after the restart: $(ask wins)"
# snap restore after the restart gives back the rectangle from before the snap (the saved one, kept in term-groups)
R env $E $B/ribbon-term-ctl snap restore; i=0; while [ $i -lt 100 ]; do a=$(ask tabs); [ "$(echo "$a" | grep -o "rect=[-0-9,]*" | tail -1 | sed 's/rect=//')" = "$RECT0" ] && break; i=$((i + 1)); sleep 0.05; done
[ "$(echo "$a" | grep -o "rect=[-0-9,]*" | tail -1 | sed 's/rect=//')" = "$RECT0" ] && ok "after the shell restart snap restore gives back $RECT0 (the rectangle before the snap)" || bad "after the restart, snap restore: $a (want rect $RECT0)"
if [ $OLD -eq 0 ]; then
	R env $E $B/ribbon-term-ctl snap left; sleep 0.8; shot g5; X=${RECT%%,*}; Yr=${RECT#*,}; Y=${Yr%%,*}
	f=$(px g5 $((X + 500)) $((Y + 42))); g=$(px g5 $((X + 500)) $((Y + 41)))
	[ "$f" = "$FOOT" ] && [ "$g" != "$FOOT" ] && ok "the restored tab is under its strip at the restored place" || bad "after the restart: foot $f, strip $g"
fi


# ---- Ask before closing a running command (boards Alert-2, -2b, -2c; shell/alert.tcl as a sheet under the strip) ----
# a fourth tab runs `sleep 100` in front of its shell (tabsh's run:, with job control); closing it asks first
newtab4() {
	R env $E $B/ribbon-term-ctl new
	i=0; while [ $i -lt 100 ]; do a=$(ask tabs); [ "$(echo "$a" | grep -o "tabs=[0-9 ]*" | tail -1 | wc -w)" -eq 4 ] && break; sleep 0.05; i=$((i + 1)); done
	sleep 0.4
	sp=$(askv cursh '[term::shell_of [wm::get $term::G(g1,cur) app]]' | awk '{print $3}')
	[ -n "$sp" ] && [ -p "$T0/tabs/fifo.$sp" ] && echo "run:sleep 100" > "$T0/tabs/fifo.$sp"
	i=0; while [ $i -lt 100 ]; do r=$(askv running '[term::running [wm::get $term::G(g1,cur) app]]'); echo "$r" | grep -q " running sleep 100$" && return 0; sleep 0.05; i=$((i + 1)); done; return 1
}
ntabs() { ask tabs | grep -o "tabs=[0-9 ]*" | tail -1 | wc -w; }
alertis() { askv alert '[alert::isopen] [winfo exists $alert::win] [dict get $alert::spec -title] | [dict get $alert::spec -lines]'; }
noalert() { i=0; while [ $i -lt 60 ]; do askv alert '[expr {[llength [info commands ::alert::isopen]] ? [alert::isopen] : 0}]' | grep -q " alert 0$" && return 0; sleep 0.05; i=$((i + 1)); done; return 1; }
if newtab4; then ok "a tab running sleep 100 in front of its shell is seen as running it (its terminal's foreground group)"; else bad "the busy tab: $(ask tabs) $r"; fi
na=$(grep -c " ask " "$LOG")
R env $E $B/ribbon-term-ctl close; waitlog " ask tab g1 " 1 100
al=$(alertis)
echo "$al" | grep -q " alert 1 1 Close this tab? | {sleep 100 is still running}$" && ok "Ctrl+Shift+W on it asks first: Close this tab? / sleep 100 is still running" || bad "no question: $al"
[ "$(ntabs)" -eq 4 ] && ok "  the tab stays open while it asks" || bad "the tab closed without an answer: $(ask tabs)"
a=$(ask tabs); rect=$(echo "$a" | grep -o "rect=[-0-9,]*" | tail -1 | sed 's/rect=//'); RX=${rect%%,*}; rr=${rect#*,}; RY=${rr%%,*}; rr=${rr#*,}; RW=${rr%%,*}
ax=$(askv ax '[winfo rootx $alert::win.c] [winfo rooty $alert::win.c] [winfo width $alert::win.c] [winfo height $alert::win.c]' | cut -d' ' -f3-)
[ "$ax" = "$((RX + (RW - 440) / 2)) $((RY + 42)) 440 164" ] && ok "  a 440 x 164 sheet under the strip, centred on the window ($ax)" || bad "the sheet's place: $ax (group $rect)"
sleep 0.3; shot ask1
bx=$((RX + (RW - 440) / 2)); by=$((RY + 42))
c=$(px ask1 $((bx + 320)) $((by + 128))); t=$(px ask1 $((bx + 6)) $((by + 6)))
[ "$c" = "255,122,89" ] && ok "  on screen: Close tab in the accent, the sheet's §bar around it ($t)" || bad "on screen: the button's pixel $c, the sheet's $t"
hk "kt Escape"; sleep 0.4
if noalert; then ok "  Esc answers Cancel (the sheet has the keyboard)"; else note "Esc did not reach the sheet under labwc $LV; it is cancelled by hand"; hk "alert::cancel"; noalert; fi
[ "$(ntabs)" -eq 4 ] && ok "Cancel keeps the tab" || bad "Cancel closed the tab: $(ask tabs)"
# the window's close button and Restart terminals ask too, while the tab runs its command
hk "set term::active g1; term::wctl close"; waitlog " ask window g1 " 1 100
al=$(alertis); echo "$al" | grep -q "Close this window? | {sleep 100 is still running}$" && ok "the window's close button asks: Close this window?" || bad "window close: $al"
hk "alert::cancel"; noalert; sleep 0.3
[ "$(ntabs)" -eq 4 ] && ok "  Cancel keeps the window and its tabs" || bad "the window closed: $(ask tabs)"
nr=$(grep -c " restart ribbon-term" "$LOG")
R env $E $B/ribbon-term-ctl restart; waitlog " ask restart g1 " 1 100
al=$(alertis); echo "$al" | grep -q "Restart terminals? | {sleep 100 is still running}$" && ok "Restart terminals asks first: Restart terminals?" || bad "restart: $al"
hk "alert::cancel"; noalert; sleep 0.5
[ "$(grep -c " restart ribbon-term" "$LOG")" -eq "$nr" ] && ok "  Cancel restarts nothing" || bad "Cancel restarted tabs: $(grep " restart ribbon-term" "$LOG" | tail -2)"
# the pill's × (term::close): Close tab, clicked, closes it
hk "term::close \$term::G(g1,cur)"; waitlog " ask tab g1 " 2 100
hk "event generate \$alert::win.c <ButtonRelease-1> -x 330 -y 128"
i=0; while [ $i -lt 50 ] && [ "$(ntabs)" -ne 3 ]; do sleep 0.1; i=$((i + 1)); done
[ "$(ntabs)" -eq 3 ] && noalert && ok "the pill's close asks too, and a click on Close tab closes the tab (3 left)" || bad "Close tab: $(ask tabs) $(alertis)"
# with the switch off nothing asks
printf 'profile Default ask 0\n' > "$T0/home/.config/ribbon/terminal.conf"
newtab4 || bad "the second busy tab: $(ask tabs)"
n0=$(grep -c " ask " "$LOG")
R env $E $B/ribbon-term-ctl close
i=0; while [ $i -lt 50 ] && [ "$(ntabs)" -ne 3 ]; do sleep 0.1; i=$((i + 1)); done
[ "$(ntabs)" -eq 3 ] && [ "$(grep -c " ask " "$LOG")" -eq "$n0" ] && ok "with Ask before closing a running command off, the busy tab closes at once" || bad "ask off: $(ask tabs)"
rm -f "$T0/home/.config/ribbon/terminal.conf"
na=$(grep -c " ask " "$LOG")

# ---- tabs go with footclient windows ----
R env $E $B/ribbon-term-ctl close
# wait until the tab is gone (up to 5 s): a fixed 0.8 s was too short on a busy machine
i=0; n=3
while [ $i -lt 50 ]; do
	a=$(ask tabs); n=$(echo "$a" | grep -o "tabs=[0-9 ]*" | tail -1 | wc -w)
	[ "$n" -eq 2 ] && break
	sleep 0.1; i=$((i + 1))
done
[ "$n" -eq 2 ] && ok "close removed the front tab (2 left)" || bad "close: $a"
[ "$(grep -c " ask " "$LOG")" -eq "$na" ] && ok "  an idle tab (its shell at the prompt) closes at once, nothing asked" || bad "an idle tab asked: $(grep " ask " "$LOG" | tail -1)"
d=$(ask dock); echo "$d" | grep -q "ribbon-terminal n=2 Terminal" && ok "the dock count follows (2)" || bad "dock: $d"
closeids "$(echo "$a" | grep -o "tabs=[0-9 ]*" | tail -1 | sed 's/tabs=//')"
waitlog "group g1 gone" 1 100 && ok "the last tab closed: the group and its strip are gone" || bad "group still there: $(ask tabs)"
st=$(cat "$T0/state/ribbon/term-groups" 2>/dev/null); echo "$st" | grep -q "^g1 " && bad "closing the group left its line in term-groups: $st" || ok "closing the group removed its line from term-groups"
w=$(ask wins); echo "$w" | grep -q "ribbon-term" && bad "windows left: $w" || ok "no terminal window is left"
[ "$(grep -c "<windowRule " "$T0/gen/labwc/rc.xml")" -eq 0 ] && ok "the generated rc.xml holds no rules once the terminal is closed" || bad "rc.xml still has rules"

# ---- preferences: a profile's settings reach a new tab; the preferences are a tab of their own; Restart terminals ----
if [ $OLD -eq 0 ]; then
	# Default's background (a profile colour, footclient -o) is not foot.ini's
	printf 'profile Default bg #305070\n' > "$T0/home/.config/ribbon/terminal.conf"
	R env $E $B/ribbon-terminal; waitlog "group g1 created" 2 100; sleep 1.2
	a=$(ask tabs); RECT=$(echo "$a" | grep -o "rect=[-0-9,]*" | tail -1 | sed 's/rect=//'); X=${RECT%%,*}; Yr=${RECT#*,}; Y=${Yr%%,*}
	shot p1; f=$(px p1 $((X + 500)) $((Y + 120)))
	[ "$f" = "48,80,112" ] && ok "a new tab takes Default's background from terminal.conf (footclient -o)" || bad "profile background: $f at $((X + 500)),$((Y + 120)) ($a)"
	grep -q "spawn ribbon-term-g1-1 Default" "$LOG" && ok "the tab was started with profile Default" || bad "no spawn with a profile in the log"
	# the preferences: ribbon-term-ctl prefs (the strip's sliders, Ctrl+,) opens them as the group's last tab, in front
	R env $E $B/ribbon-term-ctl prefs
	i=0; while [ $i -lt 100 ]; do w=$(ask wins); echo "$w" | grep -q "ribbon-term-g1-prefs" && break; i=$((i + 1)); sleep 0.1; done
	echo "$w" | grep -q "ribbon-term-g1-prefs" && ok "the preferences window has the app-id ribbon-term-g1-prefs" || bad "no preferences window: $w ($(cat "$T0/shell.out" | tail -3))"
	i=0; while [ $i -lt 60 ]; do a=$(ask tabs); [ "$(echo "$a" | grep -o "tabs=[0-9 ]*" | tail -1 | wc -w)" -eq 2 ] && echo "$w" | grep -q "ribbon-term-g1-1 [a-z,]*min" && break; i=$((i + 1)); sleep 0.1; w=$(ask wins); done
	[ "$(echo "$a" | grep -o "tabs=[0-9 ]*" | tail -1 | wc -w)" -eq 2 ] && ok "the preferences are the group's second tab ($(echo "$a" | grep -o 'tabs=[0-9 ]*'))" || bad "preferences tab: $a"
	echo "$w" | grep -q "ribbon-term-g1-1 [a-z,]*min" && ok "the foot tab is minimised behind the preferences" || bad "the foot tab is not behind: $w"
	sleep 1.5; shot p2; f=$(px p2 $((X + 100)) $((Y + 500))); g=$(px p2 $((X + 700)) $((Y + 120)))
	[ "$f" = "$(printf '%d,%d,%d' 0x12 0x11 0x10)" ] && [ "$g" = "$(printf '%d,%d,%d' 0x1d 0x1c 0x1b)" ] && ok "the preferences fill the tab area under the strip (the profiles' side, then the page)" || bad "preferences on screen: side $f, page $g"
	# a second request raises the same preferences, no second window
	R env $E $B/ribbon-term-ctl tab 1; sleep 0.4; R env $E $B/ribbon-term-ctl prefs; sleep 0.8; w=$(ask wins)
	[ "$(echo "$w" | grep -o "ribbon-term-g1-prefs" | wc -l)" -eq 1 ] && echo "$w" | grep -q "ribbon-term-g1-1 [a-z,]*min" && ok "prefs again brings the same preferences tab to the front" || bad "prefs again: $w"
	# Restart terminals: the idle foot tab starts again, with the profile's new background
	printf 'profile Default bg #503020\n' > "$T0/home/.config/ribbon/terminal.conf"
	R env $E $B/ribbon-term-ctl restart; waitlog "spawn ribbon-term-g1-1 Default" 2 100
	R env $E $B/ribbon-term-ctl tab 1; sleep 1.5; shot p3; f=$(px p3 $((X + 500)) $((Y + 120)))
	grep -q "restart ribbon-term-g1-1" "$LOG" && [ "$f" = "80,48,32" ] && ok "Restart terminals started the idle tab again with the new background" || bad "restart: $f ($(grep "restart\|spawn" "$LOG" | tail -3))"
	a=$(ask tabs); closeids "$(echo "$a" | grep -o "tabs=[0-9 ]*" | tail -1 | sed 's/tabs=//')"
	waitlog "group g1 gone" 2 100 && ok "closing both tabs closes the group (the preferences tab with it)" || bad "group still there: $(ask tabs)"

	# ---- Behaviour (the strip's own settings in terminal.conf): Show the strip, New tab goes, Closing the last tab ----
	printf 'profile Default strip two newat next lastclose keep marktab 0\n' > "$T0/home/.config/ribbon/terminal.conf"
	R env $E $B/ribbon-terminal; waitlog "group g1 created" 3 100; sleep 1.2
	a=$(ask tabs); RECT=$(echo "$a" | grep -o "rect=[-0-9,]*" | tail -1 | sed 's/rect=//'); X=${RECT%%,*}; Yr=${RECT#*,}; Y=${Yr%%,*}
	o=$(ask order); echo "$o" | grep -q "hide=1" && ok "one tab and Show the strip: Two or more: the strip is hidden" || bad "strip with one tab: $o"
	shot b1; f=$(px b1 $((X + 500)) $((Y + 20)))
	[ "$f" != "18,17,16" ] && ok "  and nothing of it is on screen (the tab has labwc's title bar there: $f)" || bad "the strip is still drawn: $f"
	R env $E $B/ribbon-term-ctl new; i=0; while [ $i -lt 60 ]; do o=$(ask order); echo "$o" | grep -q "hide=0" && break; i=$((i + 1)); sleep 0.1; done
	echo "$o" | grep -q "hide=0" && ok "a second tab brings the strip back" || bad "strip with two tabs: $o"
	sleep 0.8; shot b2; f=$(px b2 $((X + 500)) $((Y + 20)))
	[ "$f" = "18,17,16" ] && ok "  and it is drawn above the tabs again" || bad "strip not back on screen: $f"
	R env $E $B/ribbon-term-ctl tab 1; sleep 0.4; R env $E $B/ribbon-term-ctl new
	i=0; while [ $i -lt 60 ]; do o=$(ask order); [ "$(echo "$o" | grep -o "ribbon-term-g1-[0-9]" | wc -l)" -eq 3 ] && break; i=$((i + 1)); sleep 0.1; done
	# shellcheck disable=SC2046
	set -- $(echo "$o" | grep -o "ribbon-term-g1-[0-9]*" | sed 's/.*-//')
	[ $# -eq 3 ] && [ "$2" -gt "$1" ] && [ "$2" -gt "$3" ] && ok "New tab goes: Next puts the new tab after the current first tab ($o)" || bad "tab order: $o"
	# Closing the last tab: Opens a new tab
	a=$(ask tabs); closeids "$(echo "$a" | grep -o "tabs=[0-9 ]*" | tail -1 | sed 's/tabs=//')"
	sleep 2; o=$(ask order); a=$(ask tabs)
	echo "$a" | grep -q "groups=g1" && [ "$(echo "$o" | grep -o "ribbon-term-g1-[0-9]*" | wc -l)" -eq 1 ] && ok "closing every tab with Closing the last tab: Opens a new tab leaves one new tab ($o)" || bad "keep: $a / $o"
	R env $E $B/ribbon-term-ctl new; sleep 1; hk "term::wctl close"; sleep 0.2
	waitlog "group g1 gone" 3 100 && ok "the window's close button still closes it" || bad "close button: $(ask tabs)"

	# ---- a tab's menu (apps/term/menu.tcl): the window, and what its rows do ----
	rm -f "$T0/home/.config/ribbon/terminal.conf"
	R env $E $B/ribbon-terminal; waitlog "group g1 created" 4 100; sleep 1; R env $E $B/ribbon-term-ctl new; sleep 1
	a=$(ask tabs)
	# shellcheck disable=SC2046
	set -- $(echo "$a" | grep -o "tabs=[0-9 ]*" | tail -1 | sed 's/tabs=//'); T1=$1; T2=$2
	RECT=$(echo "$a" | grep -o "rect=[-0-9,]*" | tail -1 | sed 's/rect=//'); X=${RECT%%,*}; Yr=${RECT#*,}; Y=${Yr%%,*}
	r=$(askv shellof "[term::shell_of ribbon-term-g1-1]"); echo "$r" | grep -q "shellof [0-9]" && ok "a tab's shell is found by RIBBON_TERM_TAB in its environment" || bad "shell_of: $r"
	hk "term::menu $T2 $((X + 60)) $((Y + 46))"; sleep 0.8
	r=$(askv menu "[winfo exists .termmenu] [winfo ismapped .termmenu]"); echo "$r" | grep -q "menu 1 1" && ok "a right click's callback opens the tab's menu" || bad "menu: $r"
	hk "set tmenu::sub 1; tmenu::draw"; sleep 0.4; shot m1
	f=$(px m1 $((X + 60 + 150)) $((Y + 46 + 3))); g=$(px m1 $((X + 60 + 296 + 100)) $((Y + 46 + 34 + 14)))
	[ "$f" = "42,40,38" ] && [ "$g" = "42,40,38" ] && ok "the menu and, over New tab with profile, the profiles beside it are on screen" || bad "menu on screen: menu $f, profiles $g"
	hk "tmenu::close"; sleep 0.2
	hk "term::menu_do $T2 dup"; i=0; while [ $i -lt 50 ]; do a=$(ask tabs); [ "$(echo "$a" | grep -o "tabs=[0-9 ]*" | tail -1 | wc -w)" -eq 3 ] && break; i=$((i + 1)); sleep 0.1; done
	[ "$(echo "$a" | grep -o "tabs=[0-9 ]*" | tail -1 | wc -w)" -eq 3 ] && ok "Duplicate tab opens a third tab" || bad "duplicate: $a"
	hk "term::rename_start g1 $T1"; sleep 0.3; hk ".term_g1.rename delete 0 end; .term_g1.rename insert 0 build; term::rename_done g1 ribbon-term-g1-1 1"; sleep 0.3
	r=$(askv drawn "\$strip::drawn"); echo "$r" | grep -q "build" && ok "Rename… gives the pill the typed name" || bad "rename: $r"
	hk "term::select g1 $T1"; sleep 0.6; shot s1
	hk "term::menu_do $T1 size 1"; sleep 0.2; hk "term::menu_do $T1 size 1"; sleep 0.2; hk "term::menu_do $T1 size 1"; sleep 0.8; shot s2
	r=$(askv size "[term::tab_size $T1]"); d=$(compare -metric AE "$T0/shots/s1.png" "$T0/shots/s2.png" null: 2>&1 | sed 's/[^0-9].*//')
	echo "$r" | grep -q "size 17" && [ "${d:-0}" -gt 0 ] && ok "Text size: three steps make the tab 17 pt and its page changes ($d px differ)" || bad "text size: $r, $d px differ"
	hk "term::menu_do $T2 window"; i=0; while [ $i -lt 60 ]; do a=$(ask tabs); echo "$a" | grep -q "groups=g1 g2" && echo "$a" | grep -q "g2 cur=$T2 tabs=$T2 " && break; i=$((i + 1)); sleep 0.1; done
	echo "$a" | grep -q "g2 cur=$T2 tabs=$T2 " && ok "Move to a new window: the tab is the one tab of a new group" || bad "move to a new window: $a"
	w=$(ask wins); echo "$w" | grep -q "ribbon-term-g2-1" && ok "  its app-id is ribbon-term-g2-1 (foot's OSC 176)" || bad "app-id after the move: $w"
	# ribbon-terminal run in a folder (Files' "Open terminal here") opens its tab there, whatever the folder is called
	mkdir -p "$T0/a dir with spaces"
	R env $E sh -c "cd '$T/a dir with spaces' && $B/ribbon-terminal"; sleep 1.5
	r=$(askv newcwd "[lmap id [concat {*}[lmap g \$term::groups { set term::G(\$g,tabs) }]] { set p [term::shell_of [wm::get \$id app]]; expr {\$p eq {} ? {} : [file readlink /proc/\$p/cwd]} }]")
	echo "$r" | grep -q "a dir with spaces" && ok "ribbon-terminal run in a folder opens the new tab in that folder" || bad "open terminal here: $r"
	hk "foreach g \$term::groups { set term::active \$g; term::wctl close }"; sleep 1.5
	a=$(ask tabs); echo "$a" | grep -q "groups=$" && ok "both windows close" || { hk "foreach g \$term::groups { set term::active \$g; term::wctl close }"; sleep 1.5; a=$(ask tabs); echo "$a" | grep -q "groups=$" && ok "both windows close" || bad "windows left: $a"; }
fi
grep -i "error\|parse" "$T0/labwc.log" | grep -vi "xkb\|libseat\|session" | head -3
grep -i "error\|invalid" "$T0/shell.out" | head -3
exit $fail
