#!/bin/sh
# ribbon-polkit's card (apps/polkit/card.tcl) in the boards' states, drawn by its own main.tcl under xvfb with
# RIBBON_POLKIT_SCENE=tests/polkit-card-scene.tcl (no bus, no agent): "card" against Polkit-A-Card and "choose"
# against Polkit-A2-Choose, each grab cropped to the card and compared with the board's crop in
# tests/fixtures/polkit-card (both blurred, RMSE < 0.05). "error" and "details" have no board of their own: they
# must draw, at the card's place, taller than the plain card (the message line; Details open). The agent's
# behaviour is 70-polkit.sh, the keyboard 70-polkit-keys.sh. Skips without wish8.6 / xvfb-run / ImageMagick.
set -u
cd "$(dirname "$0")/../.." || exit 1
for c in wish8.6 tclsh8.6 xvfb-run import convert compare; do
	command -v "$c" >/dev/null 2>&1 || { echo "  skip the polkit card against its boards (no $c)"; exit 0; }
done
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip the polkit card (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
D=$PWD/srcpkgs/ribbon-desktop/files
TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}"; export TCLLIBPATH
mkdir -p "$T/home/.config/ribbon"; cp "$D/themes/palettes/ribbon.conf" "$T/home/.config/ribbon/palette.conf"
fails=0
# scene SCENE: draws it, sets L T W H (the card on the screen); the grab is $T/SCENE.png
scene() {
	rm -f "$T/$1.res" "$T/$1.png"
	if ! env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/cache" RIBBON_POLKIT_SCENE="$PWD/tests/polkit-card-scene.tcl" \
		RIBBON_SCENE="$1" RIBBON_POLKIT_SHOT="$T/$1.png" RIBBON_POLKIT_RESULT="$T/$1.res" \
		timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/apps/polkit/main.tcl" >"$T/out" 2>&1 \
		|| [ ! -s "$T/$1.png" ] || [ ! -s "$T/$1.res" ]; then
		sed 's/^/       /' "$T/out"; echo "  FAIL the $1 scene did not draw"; fails=$((fails + 1)); return 1
	fi
	read -r L Tp W H <"$T/$1.res"
}
board() { # SCENE FIXTURE BOARD
	scene "$1" || return
	convert "$T/$1.png" -crop "${W}x${H}+${L}+${Tp}" +repage -blur 0x2 "$T/a.png"
	convert "tests/fixtures/polkit-card/$2.png" -blur 0x2 "$T/b.png"
	bs=$(identify -format '%wx%h' "$T/b.png")
	if [ "$bs" != "${W}x${H}" ]; then echo "  FAIL $1: the card is ${W}x${H}, $3 draws it $bs"; fails=$((fails + 1)); return; fi
	r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
	if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then echo "  ok   $1 matches $3 (${W}x${H} at $L,$Tp, blurred RMSE $r)"; else echo "  FAIL $1 against $3: RMSE ${r:-?}"; fails=$((fails + 1)); fi
}
board card card Polkit-A-Card
board choose choose Polkit-A2-Choose
H0=290
for s in error details; do
	scene "$s" || continue
	if [ "$H" -gt "$H0" ] && [ "$W" = 440 ] && [ "$L" = 500 ]; then echo "  ok   $s draws (440x$H, taller than the card's $H0)"; else echo "  FAIL $s: ${W}x$H at $L,$Tp"; fails=$((fails + 1)); fi
done
[ $fails -eq 0 ] && echo "  ok   polkit card against its boards" || { echo "  FAIL polkit card: $fails failed"; exit 1; }
