#!/bin/sh
# The installer's dialogs, error and edge screens (the Inst-11 .. Inst-15 and Inst-5b boards,
# design/tools/gen_installer_dialogs.py):
#   - each drawn (tests/installer-scene.tcl) against its board's crop in tests/fixtures/installer-dialogs
#     (blurred RMSE < 0.05): the New and Edit partition sheets, Windows not ready, Summary and Manual refused
#     by the backend's check, the install's error, the close sheet while installing, the probe refused,
#     Hardware's scrolling drivers list;
#   - tests/installer-dialogs.tcl at 1440x900 and 1366x768: the sheets, Check again, the check's refusals,
#     Try again, disks and partitions that scroll, where the window goes (small, narrow, short screens and
#     two outputs);
#   - tests/installer-close.tcl with RIBBON_CLOSE_STOP=1: Stop installing ends the window and the backend
#     (a slow fake backend never gets to make RIBBON_FAKE_MARKER);
#   - tests/installer-flow.tcl at 1366x768 (its clicks follow page::head and the footer).
# Needs wish8.6 and xvfb-run; the board compare ImageMagick.
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fails=$((fails + 1)); }
for t in wish8.6 xvfb-run; do command -v $t >/dev/null 2>&1 || { echo "  skip the installer's dialogs (no $t)"; exit 0; }; done
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
MAIN=srcpkgs/ribbon-installer/files/tk/main.tcl
xwish() { # screen size, then env assignments
	sz=$1; shift
	mkdir -p "$T/home" "$T/cache"
	env HOME="$T/home" XDG_CACHE_HOME="$T/cache" XDG_RUNTIME_DIR="$T" "$@" \
		timeout -k 5 120 xvfb-run -a -s "-screen 0 ${sz}x24" wish8.6 -encoding utf-8 "$MAIN"
}

# 1. against the boards
if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1 && command -v import >/dev/null 2>&1; then
	for p in dialog:Inst-11-Partition edit:Inst-11b-Edit unsafe:Inst-12-Unsafe check:Inst-13-Check planerror:Inst-13b-PlanError \
		error:Inst-14-Error close:Inst-14b-Close noprobe:Inst-15-NoProbe hwscroll:Inst-5b-Hardware; do
		scene=${p%%:*}; board=${p#*:}
		rm -f "$T/shot.png"
		xwish 1440x900 RIBBON_INSTALLER_SCENE=tests/installer-scene.tcl RIBBON_SCENE=$scene RIBBON_INSTALLER_SHOT="$T/shot.png" >"$T/scene.log" 2>&1
		if [ -s "$T/shot.png" ]; then
			convert "$T/shot.png" -crop 1100x720+170+104 +repage -blur 0x2 "$T/a.png"
			convert tests/fixtures/installer-dialogs/$scene.png -blur 0x2 "$T/b.png"
			r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
			if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then ok "$scene matches $board (blurred RMSE $r)"
			else bad "$scene against $board: RMSE ${r:-?}"; fi
		else
			sed 's/^/       /' "$T/scene.log"; bad "no screenshot of $scene"
		fi
	done
else
	echo "  skip the dialogs against their boards (no ImageMagick)"
fi

# 2. what they do
for sz in 1440x900 1366x768; do
	if out=$(xwish $sz RIBBON_INSTALLER_SCENE=tests/installer-dialogs.tcl 2>&1); then
		ok "$sz: $(printf '%s\n' "$out" | grep -c '  ok ') checks (sheets, Check again, refusals, Try again, scrolling, placement)"
	else
		printf '%s\n' "$out" | grep -v '^  ok '; bad "$sz: the installer's dialogs"
	fi
done

# 3. Stop installing ends the install
rm -f "$T/finished" "$T"/*.answers
xwish 1440x900 RIBBON_INSTALLER_SCENE=tests/installer-close.tcl RIBBON_CLOSE_STOP=1 RIBBON_FAKE_DELAY=0.25 RIBBON_FAKE_MARKER="$T/finished" >"$T/stop.out" 2>&1; rc=$?
# the backend would have finished within about 6 s
i=0; while [ ! -e "$T/finished" ] && [ $i -lt 80 ]; do sleep 0.1; i=$((i + 1)); done
if [ $rc -eq 1 ] && ! grep -q FAIL "$T/stop.out" && [ ! -e "$T/finished" ]; then
	ok "Stop installing closes the window and stops the backend (it never finished)"
else
	sed 's/^/       /' "$T/stop.out"; bad "Stop installing (exit $rc, backend finished: $([ -e "$T/finished" ] && echo yes || echo no))"
fi

left=$(find "$T" -maxdepth 1 -name '*.answers' -exec basename {} \;)
if [ -z "$left" ]; then ok "Stop installing leaves no answers file (the name, the disk) in the runtime dir"
else bad "Stop installing left $left in the runtime dir"; fi

# 4. the flow on a small screen
if out=$(xwish 1366x768 RIBBON_INSTALLER_SCENE=tests/installer-flow.tcl 2>&1); then
	ok "1366x768: the whole flow, $(printf '%s\n' "$out" | grep -c '  ok ') checks, to Done"
else
	printf '%s\n' "$out" | grep -v '^  ok '; bad "1366x768: the installer flow"
fi

[ $fails -eq 0 ] && echo "installer dialogs: all checks passed"
exit $fails
