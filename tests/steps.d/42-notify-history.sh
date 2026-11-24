#!/bin/sh
# The notification history, Do Not Disturb and the left bar's bell (shell/mod-notify-history.tcl; STYLE §12, §19):
# the behaviour checks in the real shell under xvfb (tests/shell-notify-history.tcl), then the four Notify-Final
# board states drawn in graphite, fjord and moss. Skips without wish8.6 or xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip notification history (no wish8.6 / xvfb-run)"
	exit 0
fi
P=srcpkgs/ribbon-desktop/files/themes/palettes
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
run() { # NAME, the scene (or checks), the palette
	mkdir -p "$T/$1/h" "$T/$1/cfg/ribbon" "$T/$1/s" "$T/$1/r"
	cp "$P/$3.conf" "$T/$1/cfg/ribbon/palette.conf"
	if HOME=$T/$1/h XDG_CONFIG_HOME=$T/$1/cfg XDG_STATE_HOME=$T/$1/s XDG_RUNTIME_DIR=$T/$1/r \
		DBUS_SESSION_BUS_ADDRESS=unix:path=$T/none NOTIFY_HISTORY_SCENE=$2 RIBBON_SHELL_TEST=tests/shell-notify-history.tcl \
		timeout -k 5 60 xvfb-run -a -s "-screen 0 1440x900x24" \
		wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/shell/main.tcl -name ribbon-shell >"$T/$1.out" 2>&1 &&
		! grep -q '  FAIL' "$T/$1.out"; then
		if [ "$2" = checks ]; then
			sed -n 's/^  ok   /  ok   history: /p' "$T/$1.out"
			grep -q 'all history checks passed' "$T/$1.out" || { echo "  FAIL notification history: no pass line"; exit 1; }
		else
			echo "  ok   history draws the $2 board in $3"
		fi
	else
		sed 's/^/       /' "$T/$1.out"
		echo "  FAIL notification history: $2 ($3)"
		fails=$((fails + 1))
	fi
}
run checks checks ribbon
for scheme in "list ribbon" "dnd ribbon" "clear ribbon" "empty ribbon" "list ribbon-fjord" "dnd ribbon-fjord" "list ribbon-moss" "empty ribbon-moss"; do
	set -- $scheme
	run "$1-$2" "$1" "$2"
done
[ "$fails" -eq 0 ]
