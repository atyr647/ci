#!/bin/sh
# The shell's notification popups (shell/mod-notify.tcl, STYLE §19): the four Notify-Final boards' states in the
# real shell under xvfb (tests/shell-notify.tcl as RIBBON_SHELL_TEST): the surface at the bottom left, the text at
# x 48, the one accent rule at x 28, the foot 64 above the bottom. Then a shell with no session bus starts and runs
# on with the server off. Skips without wish8.6 or xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip notifications (no wish8.6 / xvfb-run)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
for sc in popup burst progress critical checks nobus; do
	mkdir -p "$T/$sc/h" "$T/$sc/c" "$T/$sc/s" "$T/$sc/r"
	if HOME=$T/$sc/h XDG_CACHE_HOME=$T/$sc/c XDG_STATE_HOME=$T/$sc/s XDG_RUNTIME_DIR=$T/$sc/r \
		DBUS_SESSION_BUS_ADDRESS=unix:path=$T/none NOTIFY_SCENE=$sc RIBBON_SHELL_TEST=tests/shell-notify.tcl \
		timeout -k 5 60 xvfb-run -a -s "-screen 0 1440x900x24" \
		wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/shell/main.tcl -name ribbon-shell >"$T/$sc.out" 2>&1 &&
		! grep -q '  FAIL' "$T/$sc.out"; then
		sed -n 's/^  ok   /  ok   notify ('"$sc"'): /p' "$T/$sc.out"
	else
		sed 's/^/       /' "$T/$sc.out"; echo "  FAIL notifications: the $sc scene"; fails=$((fails + 1))
	fi
done
[ "$fails" -eq 0 ]
