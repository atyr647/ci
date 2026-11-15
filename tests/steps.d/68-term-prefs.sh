#!/bin/sh
# Ribbon Terminal's preferences (apps/term/prefs.tcl, the Page direction): tests/term-prefs-scene.tcl draws Look,
# Profile, Behaviour and Keys under xvfb, compares Look and Profile with the board crops in tests/fixtures/term-prefs
# (both blurred, RMSE), and runs the page's actions (links, undo, steppers, colours, tags, profiles, keys) against
# terminal.conf. The preferences as a tab of the terminal are checked live by tests/term/run.sh. Skips without
# wish8.6 / xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip the terminal's preferences (no wish8.6 / xvfb-run)"; exit 0
fi
D=$PWD/srcpkgs/ribbon-desktop/files
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
run() { # SCENE [extra env...]: a fresh config each time
	h=$T/home-$1; rm -rf "$h"; mkdir -p "$h/.config/ribbon"; cp "$D/themes/palettes/ribbon.conf" "$h/.config/ribbon/palette.conf"
	sc=$1; shift
	env HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_CACHE_HOME="$T/cache" RIBBON_TERM_PREFS_SCENE=tests/term-prefs-scene.tcl RIBBON_SCENE=$sc "$@" \
		timeout -k 5 90 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/apps/term/prefs-main.tcl"
}
for sc in look profile behaviour keys; do
	if run $sc RIBBON_TERM_PREFS_SHOT="$T/$sc.png" >"$T/out" 2>&1 && [ -s "$T/$sc.png" ]; then echo "  ok   draws $sc"; else echo "  FAIL draws $sc"; sed 's/^/       /' "$T/out"; fails=$((fails + 1)); fi
done
if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1; then
	for sc in look profile; do
		[ -s "$T/$sc.png" ] || continue
		convert "$T/$sc.png" -blur 0x2 "$T/a.png"; convert "tests/fixtures/term-prefs/$sc.png" -blur 0x2 "$T/b.png"
		r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
		if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then echo "  ok   $sc matches the board (blurred RMSE $r)"; else echo "  FAIL $sc against the board: RMSE ${r:-?}"; fails=$((fails + 1)); fi
	done
else echo "  skip the board comparison (no ImageMagick)"; fi
if run flow >"$T/out" 2>&1; then grep '  ok ' "$T/out"; else sed 's/^/       /' "$T/out"; fails=$((fails + 1)); fi
[ $fails -eq 0 ] && echo "terminal preferences: all checks passed" || { echo "terminal preferences: $fails failed"; exit 1; }
