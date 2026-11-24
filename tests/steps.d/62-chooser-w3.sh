#!/bin/sh
# The Ribbon file chooser's New folder and the app's choices (appearance/chooser-main.tcl; boards Chooser-New-Folder
# and Chooser-Save-Choices from design/tools/gen_chooser.py; Chooser-Save-Choices-Open from gen_chooser_w4.py):
#  - tests/chooser-w3-scene.tcl on the boards' folders (tests/chooser/fixture.sh): New folder's button (Save as and
#    Choose a folder, not Open), the folder made and named in its row (Return, Escape, a press elsewhere, Ctrl Shift N,
#    taken and bad names), the choices' strip (checkbox, list by pointer and keys); both states compared with the
#    boards' crops in tests/fixtures/chooser (both blurred, RMSE < 0.05); the answer carries the choices' values;
#  - the FileChooser portal (tests/chooser/portal-choices.sh): an app's choices go to the chooser and their values
#    come back as the results' choices.
# Skips without wish8.6 / xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip chooser w3 (no wish8.6 / xvfb-run)"; exit 0
fi
fails=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
D=$PWD/srcpkgs/ribbon-desktop/files
NOW=$(date -d "2026-11-15 12:00" +%s)
home() { sh tests/chooser/fixture.sh "$T/home"; cp "$D/themes/palettes/ribbon.conf" "$T/home/.config/ribbon/palette.conf"; }
run() { # VAR=VALUE ... -- chooser args
	envs=""; while [ "$1" != "--" ]; do envs="$envs $1"; shift; done; shift
	env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/cache" RIBBON_SHELL_DIR="$D/shell" \
		RIBBON_CHOOSER_DRIVES="$T/home/drives" RIBBON_CHOOSER_NOW="$NOW" $envs \
		timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/appearance/chooser-main.tcl" \
		-name ribbon-chooser -- "$@" >"$T/out" 2>"$T/err"
}
mkdir -p "$T/shots"
S="RIBBON_CHOOSER_TEST=$PWD/tests/chooser-w3-scene.tcl RIBBON_CHOOSER_SCENE=1 CHOOSER_SHOTS=$T/shots CHOOSER_RESULT=$T/res"
CH='{enc Encoding {{utf8 {Unicode (UTF-8)}} {latin1 {Western (ISO-8859-1)}}} utf8} {ext {Automatic file name extension} {} true}'
for m in newfolder choices; do
	home; rm -f "$T/res"
	if [ $m = newfolder ]; then
		run $S CHOOSER_W3=$m -- -mode save -initialdir "$T/home/Documents" -initialfile trip-notes.md
	else
		run $S CHOOSER_W3=$m -- -mode save -initialdir "$T/home/Documents" -initialfile "Council letter.odt" -choices "$CH"
	fi
	r=$?
	[ -f "$T/res" ] && sed 's/^/  /' "$T/res"
	[ $r -eq 0 ] || { sed 's/^/       /' "$T/err"; bad "the $m scene"; }
	if [ $m = choices ]; then
		if [ "$(sed -n 1p "$T/out")" = "-1" ] && [ "$(sed -n 2p "$T/out")" = "{enc latin1} {ext false}" ] &&
			[ "$(sed -n 3p "$T/out")" = "{$T/home/Documents/Council letter.odt}" ]; then
			ok "the answer: the type line, the choices' values ({enc latin1} {ext false}), then the path"
		else sed 's/^/       /' "$T/out"; bad "the answer with choices"; fi
	fi
done
if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1; then
	for s in new-folder choices choices-open; do
		[ -s "$T/shots/$s.png" ] || { bad "no picture of $s"; continue; }
		convert "$T/shots/$s.png" -blur 0x2 "$T/a.png"; convert "tests/fixtures/chooser/$s.png" -blur 0x2 "$T/b.png"
		r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
		if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then ok "$s matches its board (blurred RMSE $r)"; else bad "$s against its board: RMSE ${r:-?}"; fi
	done
else
	echo "  skip the comparison with the boards (no ImageMagick)"
fi
# the FileChooser portal with choices (a private session bus; the service D-Bus activated); unix_extra built when missing
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
		timeout -k 5 240 xvfb-run -a -s "-screen 0 1440x900x24" sh tests/chooser/portal-choices.sh "$T/portal" "$D" >"$T/pout" 2>&1; then
		grep '  ok \|  FAIL ' "$T/pout"
	else
		cat "$T/pout"; sed 's/^/       /' "$T/portal/ses.log" 2>/dev/null | tail -n 20; bad "the FileChooser portal's choices"
	fi
else
	echo "  skip the FileChooser portal's choices (no dbus-daemon or unix_extra)"
fi
[ $fails -eq 0 ] && echo "chooser w3: all checks passed" || { echo "chooser w3: $fails checks failed"; exit 1; }
