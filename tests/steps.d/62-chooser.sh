#!/bin/sh
# The Ribbon file chooser (appearance/chooser.tcl and chooser-main.tcl; boards Chooser-* from design/tools/gen_chooser.py):
#  - tests/chooser-scene.tcl: each board's state on the boards' folders (tests/chooser/fixture.sh), drawn where the
#    board puts the window and compared with the board's crop in tests/fixtures/chooser (both blurred, RMSE < 0.05);
#    its rows, places, drives, file types and keys pressed;
#  - an app asking through chooser::open_file / save_file / choose_folder (tests/chooser/client.tcl), the chooser
#    told what to do (tests/chooser/flow.tcl): the paths come back to the app, cancel gives "", the app's window is
#    held while the chooser is open and let go after;
#  - no Ribbon app calls Tk's stock dialogs.
# Skips without wish8.6 / xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip chooser (no wish8.6 / xvfb-run)"; exit 0
fi
fails=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
D=$PWD/srcpkgs/ribbon-desktop/files
NOW=$(date -d "2026-11-15 12:00" +%s)
home() { sh tests/chooser/fixture.sh "$T/home"; cp "$D/themes/palettes/ribbon.conf" "$T/home/.config/ribbon/palette.conf"; }
run() { # VAR=VALUE ... -- chooser args: the chooser alone under xvfb (1440 x 900), its answer in $T/out
	envs=""; while [ "$1" != "--" ]; do envs="$envs $1"; shift; done; shift
	env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/cache" RIBBON_SHELL_DIR="$D/shell" \
		RIBBON_CHOOSER_DRIVES="$T/home/drives" RIBBON_CHOOSER_NOW="$NOW" $envs \
		timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/appearance/chooser-main.tcl" \
		-name ribbon-chooser -- "$@" >"$T/out" 2>"$T/err"
}
client() { # FLOW KIND ARGS...: an app asking, the chooser doing FLOW; what the app got in $T/out
	flow=$1; shift
	env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/cache" RIBBON_SHELL_DIR="$D/shell" \
		RIBBON_CHOOSER_DRIVES="$T/home/drives" RIBBON_CHOOSER_NOW="$NOW" CHOOSER_LIB="$D/appearance/chooser.tcl" \
		RIBBON_CHOOSER_TEST="$PWD/tests/chooser/flow.tcl" CHOOSER_FLOW="$flow" ${HELD:+CHOOSER_HELD=$HELD} \
		timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 tests/chooser/client.tcl "$@" >"$T/out" 2>"$T/err"
}

# the boards' states, one run per mode
home; mkdir -p "$T/shots"
S="RIBBON_CHOOSER_TEST=$PWD/tests/chooser-scene.tcl RIBBON_CHOOSER_SCENE=1 CHOOSER_SHOTS=$T/shots CHOOSER_RESULT=$T/res"
for m in "open|-mode open -initialdir $T/home/Pictures -filetypes '{Pictures {.png .jpg .jpeg}}'" \
	"save|-mode save -initialdir $T/home/Documents -initialfile trip-notes.md" "folder|-mode folder -initialdir $T/home/Pictures"; do
	rm -f "$T/res"
	eval "run $S -- ${m#*|}"
	r=$?
	[ -f "$T/res" ] && sed 's/^/  /' "$T/res"
	[ $r -eq 0 ] || { sed 's/^/       /' "$T/err"; bad "the ${m%%|*} scene"; }
done
if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1; then
	for s in open types save replace folder; do
		[ -s "$T/shots/$s.png" ] || { bad "no picture of $s"; continue; }
		convert "$T/shots/$s.png" -blur 0x2 "$T/a.png"; convert "tests/fixtures/chooser/$s.png" -blur 0x2 "$T/b.png"
		r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
		if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then ok "$s matches its board (blurred RMSE $r)"; else bad "$s against its board: RMSE ${r:-?}"; fi
	done
else
	echo "  skip the comparison with the boards (no ImageMagick)"
fi

# an app asks, the chooser answers
home
P=$T/home/Pictures/Iceland
expect() { # WHAT EXPECTED-FIRST-LINE
	got=$(sed -n 1p "$T/out")
	if [ "$got" = "$2" ] && grep -qx 'grab after: ' "$T/out"; then ok "$1"; else bad "$1: got [$got] $(tail -n 3 "$T/err")"; fi
}
client open-one open_file -initialdir "$T/home/Pictures" -filetypes '{Pictures {.png .jpg .jpeg}}'
expect "Open: a file chosen and Return come back to the app as its path" "$P/Jökulsárlón.jpg"
client open-one open_file -initialdir "$T/home/Pictures" -filetypes '{Pictures {.png .jpg .jpeg}}' -acceptlabel Attach
expect "  -acceptlabel is the primary button's word (Mail's Attach)" "$P/Jökulsárlón.jpg"
client open-double open_file -initialdir "$T/home"
expect "  a double-click on a file chooses it" "$P/Kirkjufell.jpg"
client open-many open_file -multiple 1
expect "  with -multiple, Ctrl+click adds a file: both come back, in the order chosen" "{$P/Vík.jpg $P/Kirkjufell.jpg}"
client open-range open_file -multiple 1 -filetypes "{Pictures {.png .jpg .jpeg}}"
expect "  and Shift+click a range" "{$P/Kirkjufell.jpg $P/Reynisfjara.jpg $P/Seljalandsfoss.png}"
client cancel open_file
expect "  Cancel gives the app an empty answer" "{}"
client escape open_file
expect "  and so does Escape" "{}"
client save-new save_file -initialdir "$T/home/Documents" -initialfile trip-notes.md
expect "Save as: a new name and Return give its path (nothing is written by the chooser)" "$T/home/Documents/new.md"
[ ! -e "$T/home/Documents/new.md" ] || bad "the chooser wrote the file"
client save-ext save_file -initialdir "$T/home/Documents" -defaultextension .md
expect "  -defaultextension is added to a name without one" "$T/home/Documents/plan.md"
client save-replace save_file -initialdir "$T/home/Documents"
expect "  a taken name, asked and Replace: its path" "$T/home/Documents/Budget.md"
client save-tilde save_file -initialdir "$T/home/Documents"
expect "  a name with ~/ goes from the home folder" "$T/home/Music/song-list.txt"
client save-tildename save_file -initialdir "$T/home/Documents"
expect "  a name that only starts with ~ stays in the folder shown" "$T/home/Documents/~draft.txt"
touch "$T/home/Downloads/~old.txt"
client open-tilde open_file
expect "  a file whose name starts with ~ is listed and chosen" "$T/home/Downloads/~old.txt"
client save-as-is save_file -initialfile "~draft.txt"
expect "  an app's name that starts with ~ is a name, in the home folder" "$T/home/~draft.txt"
client save-as-is save_file -initialfile "$T/home/Music/~mix.txt"
expect "  and an app's path to a ~name starts in its folder, the name as it is" "$T/home/Music/~mix.txt"
client open-type2 open_file -filetypes '{JPEG .jpg} {PNG .png}' -typevariable typevar
expect "  the file type changed in the list: a file of that type" "$T/home/Pictures/Iceland/Seljalandsfoss.png"
grep -qx 'type: PNG' "$T/out" && ok "    and -typevariable names the type in use" || bad "    -typevariable: $(grep '^type' "$T/out")"
# what the app asks with goes to the chooser as words, never as the pipeline's redirections or commands
echo precious >"$T/victim"
client cancel open_file -title "2>$T/victim"
expect "  a title like a redirection is only a title" "{}"
[ "$(cat "$T/victim")" = precious ] || bad "    the chooser's errors were written over $T/victim"
client folder-chosen choose_folder -initialdir "$T/home/Pictures" -mustexist 1
expect "Choose a folder: the folder chosen in the list" "$T/home/Pictures/Iceland"
client folder-here choose_folder -initialdir "$T/home/Pictures"
expect "  none chosen: the folder shown" "$T/home/Pictures/Lisbon"
HELD=$T/held client held open_file
expect "the app's window is held (a grab) while the chooser is open, and let go after" "{}"
grep -q '__chooser' "$T/held" 2>/dev/null || bad "  the grab was not the chooser's hold: $(cat "$T/held" 2>/dev/null)"
grep -qx 'typed while held:  shortcut: 0 keys after: .e' "$T/out" && ok "  keys typed at the held window go nowhere (no text, no shortcut); its field has them back after" ||
	bad "  keys reached the held app: $(grep '^typed' "$T/out")"

# an app on tclsh (Tk loaded as a package) runs the chooser on tclsh too
env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/cache" RIBBON_SHELL_DIR="$D/shell" \
	RIBBON_CHOOSER_DRIVES="$T/home/drives" RIBBON_CHOOSER_TEST="$PWD/tests/chooser/flow.tcl" CHOOSER_FLOW=folder-here \
	timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" tclsh8.6 "$D/appearance/chooser-main.tcl" -name ribbon-chooser -- \
	-mode folder -initialdir "$T/home/Pictures" >"$T/out" 2>"$T/err"
[ "$(sed -n 2p "$T/out")" = "$T/home/Pictures/Lisbon" ] && ok "the chooser runs on tclsh as well as on wish" || bad "on tclsh: $(cat "$T/out") $(tail -n 3 "$T/err")"

# the FileChooser portal: GTK, Qt and Flatpak apps get the same chooser through xdg-desktop-portal
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	if [ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ]; then
		mkdir -p "$T/ux"
		make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; bad "unix_extra does not build"; }
		ux=$T/ux
	fi
fi
if command -v dbus-daemon >/dev/null 2>&1 && { [ -n "$ux" ] || echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; }; then
	home; mkdir -p "$T/portal"
	if env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/cache" RIBBON_SHELL_DIR="$D/shell" \
		RIBBON_CHOOSER_DRIVES="$T/home/drives" RIBBON_CHOOSER_NOW="$NOW" TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}" \
		timeout -k 5 240 xvfb-run -a -s "-screen 0 1440x900x24" sh tests/chooser/portal.sh "$T/portal" "$D" >"$T/pout" 2>&1; then
		cat "$T/pout"
	else
		cat "$T/pout"; sed 's/^/       /' "$T/portal/ses.log" 2>/dev/null | tail -n 20; bad "the FileChooser portal"
	fi
else
	echo "  skip the FileChooser portal (no dbus-daemon or unix_extra)"
fi
P1=srcpkgs/ribbon-desktop/files/xdg-desktop-portal/portals/ribbon.portal
if grep -qx 'DBusName=org.freedesktop.impl.portal.desktop.ribbon' "$P1" && grep -qx 'Interfaces=org.freedesktop.impl.portal.FileChooser;' "$P1" &&
	grep -qx 'org.freedesktop.impl.portal.FileChooser=ribbon;gtk' "$D/xdg/xdg-desktop-portal/ribbon-portals.conf"; then
	ok "ribbon.portal names the service and the FileChooser; the Ribbon session prefers it (gtk's while it is not installed)"
else bad "ribbon.portal or ribbon-portals.conf"; fi

# the activated portal starts its chooser on XWayland: the session hands D-Bus activation DISPLAY
grep -q '^dbus-update-activation-environment .*\bDISPLAY\b' "$D/xdg/labwc/autostart" &&
	ok "the session gives D-Bus activated services DISPLAY (the portal's chooser is an X client)" || bad "the autostart does not give D-Bus activation DISPLAY"

# no Ribbon app calls Tk's stock file dialogs
if grep -rn --include='*.tcl' -E 'tk_getOpenFile|tk_getSaveFile|tk_chooseDirectory' srcpkgs/ribbon-desktop/files srcpkgs/ribbon-installer/files | grep -v '^\S*:[0-9]*:\s*#' >"$T/stock"; then
	bad "Tk's stock dialogs are still called:"; sed 's/^/       /' "$T/stock"
else ok "no Ribbon app calls tk_getOpenFile, tk_getSaveFile or tk_chooseDirectory"; fi
grep -q '"${FILESDIR}"/appearance/\*.tcl' srcpkgs/ribbon-desktop/template && grep -q 'usr/lib/ribbon/appearance @files/appearance/\*.tcl' build/install/manifests/ribbon-desktop.manifest &&
	ok "chooser.tcl and chooser-main.tcl are installed with Appearance's files" || bad "the chooser's files are not installed"

[ $fails -eq 0 ] && echo "Chooser: all checks passed" || { echo "Chooser: $fails failed"; exit 1; }
