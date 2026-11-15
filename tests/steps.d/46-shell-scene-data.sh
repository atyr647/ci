#!/bin/sh
# The right bar's panel scenes (tests/shell-scene.tcl) draw the mockup's data through the panels' own reading code:
# Sound's sinks and volumes from pactl/wpctl output (got_sound), Wi-Fi's networks from NetworkManager's model
# (nm_changed), Bluetooth's devices from BlueZ's managed objects (bz_store), Power's profile and brightness
# (got_power), and the tray's tiles from all four. Each scene is drawn under xvfb and dumps the panel's rows
# (panel::blocks) and its drawn text (RIBBON_SCENE_DUMP); a scene that drew empty data ("Wi-Fi Off", "No output",
# "Looking for networks…") fails. Skips without wish8.6 / xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip shell panel scenes' data (no wish8.6 / xvfb-run)"; exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fails=$((fails + 1)); }

# scene: the text lines its panel must draw (one grep -F pattern per line), and the lines it must not
want_sound='Speakers
WH-1000XM5
LG UltraGear (HDMI)'
want_wifi='Hearth
Hearth-Guest
Ludo_2.4
Cafe Lumen'
want_bt='WH-1000XM5
Xbox Wireless Controller
MX Master 3'
want_power='Balanced'
want_tray='Speakers
Hearth
2 connected'
never='Wi-Fi Off
No output
Looking for networks'

for scene in sound wifi bt power tray; do
	mkdir -p "$T/$scene/home" "$T/$scene/rt"; chmod 700 "$T/$scene/rt"
	if ! HOME=$T/$scene/home XDG_RUNTIME_DIR=$T/$scene/rt XDG_CONFIG_HOME=$T/$scene/home/.config XDG_STATE_HOME=$T/$scene/state \
		XDG_CACHE_HOME=$T/$scene/cache DBUS_SESSION_BUS_ADDRESS=unix:path=$T/none DBUS_SYSTEM_BUS_ADDRESS=unix:path=$T/none \
		RIBBON_SHELL_TEST=tests/shell-scene.tcl RIBBON_SCENE=$scene RIBBON_SCENE_DUMP=$T/$scene.txt RIBBON_SHELL_EXIT=2500 \
		timeout -k 5 60 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/shell/main.tcl \
		-name ribbon-shell >"$T/$scene.out" 2>&1; then
		bad "the $scene scene did not run"; sed 's/^/       /' "$T/$scene.out" | tail -15; continue
	fi
	[ -s "$T/$scene.txt" ] || { bad "the $scene scene dumped nothing"; sed 's/^/       /' "$T/$scene.out" | tail -15; continue; }
	eval "want=\$want_$scene"
	# the drawn text is runs of letters placed one by one (text::draw), so a line is compared without its spaces
	miss=$(echo "$want" | while IFS= read -r w; do grep '^text ' "$T/$scene.txt" | tr -d ' ' | grep -qF -- "$(echo "$w" | tr -d ' ')" || echo "$w"; done)
	empty=$(echo "$never" | while IFS= read -r w; do grep -qF -- "$w" "$T/$scene.txt" && echo "$w"; done)
	if [ -z "$miss" ] && [ -z "$empty" ]; then
		ok "the $scene panel draws the mockup's rows ($(echo "$want" | tr '\n' ',' | sed 's/,$//; s/,/, /g'))"
	else
		[ -n "$miss" ] && echo "       missing: $(echo "$miss" | tr '\n' ';')"
		[ -n "$empty" ] && echo "       drawn empty: $(echo "$empty" | tr '\n' ';')"
		sed 's/^/       /' "$T/$scene.txt" | head -40
		bad "the $scene panel's data"
	fi
done

# a slow start (here 1.5 s busy after the scene is set up, so the scene's timers all fall due at once, as under a
# loaded machine): the dump still waits for the reads, so Sound still draws its outputs
printf 'uplevel #0 [list source -encoding utf-8 tests/shell-scene.tcl]\nset e [expr {[clock milliseconds] + 1500}]\nwhile {[clock milliseconds] < $e} {}\n' > "$T/slow.tcl"
mkdir -p "$T/slow/home" "$T/slow/rt"; chmod 700 "$T/slow/rt"
if HOME=$T/slow/home XDG_RUNTIME_DIR=$T/slow/rt XDG_CONFIG_HOME=$T/slow/home/.config XDG_STATE_HOME=$T/slow/state \
	XDG_CACHE_HOME=$T/slow/cache DBUS_SESSION_BUS_ADDRESS=unix:path=$T/none DBUS_SYSTEM_BUS_ADDRESS=unix:path=$T/none \
	RIBBON_SHELL_TEST=$T/slow.tcl RIBBON_SCENE=sound RIBBON_SCENE_DUMP=$T/slow.txt RIBBON_SHELL_EXIT=40000 \
	timeout -k 5 60 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/shell/main.tcl \
	-name ribbon-shell >"$T/slow.out" 2>&1 && grep -q '^text Speakers' "$T/slow.txt" && ! grep -qF 'No output' "$T/slow.txt"; then
	ok "a slow start: the sound panel is dumped once its reads are in (Speakers, not No output)"
else
	bad "a slow start: the sound panel was dumped before its data"; sed 's/^/       /' "$T/slow.txt" "$T/slow.out" 2>/dev/null | head -20
fi

# the parsed values behind the rows: the volume (wpctl's 0.64), the active network first, the connected devices first
if [ -f "$T/sound.txt" ]; then
	grep -q '^block slider .*64' "$T/sound.txt" && ok "Sound: the output slider at wpctl's 64 %" || { bad "Sound: no slider at 64 %"; grep '^block' "$T/sound.txt" | sed 's/^/       /'; }
fi
if [ -f "$T/wifi.txt" ]; then
	first=$(grep -m1 '^block net ' "$T/wifi.txt" | cut -d' ' -f3,4)
	[ "$first" = "Hearth 1" ] && ok "Wi-Fi: the connected network (Hearth) is the first row, marked connected" || bad "Wi-Fi: the first network row is '$first'"
	grep -q '^block net {Cafe Lumen} 0 1 0 ' "$T/wifi.txt" && ok "Wi-Fi: the open network has no lock and one bar (signal 20)" || bad "Wi-Fi: Cafe Lumen's row: $(grep 'Cafe' "$T/wifi.txt" | head -n1)"
fi
if [ -f "$T/bt.txt" ]; then
	mx=$(grep -n '^text .*MX Master 3' "$T/bt.txt" | head -n1 | cut -d: -f1); xb=$(grep -n '^text .*Xbox' "$T/bt.txt" | head -n1 | cut -d: -f1)
	[ -n "$mx" ] && [ -n "$xb" ] && [ "$xb" -lt "$mx" ] && ok "Bluetooth: connected devices above the one that is not" || bad "Bluetooth: device order (Xbox line $xb, MX line $mx)"
fi

[ $fails -eq 0 ] && echo "shell panel scenes' data: all checks passed"
[ $fails -eq 0 ]
