#!/bin/sh
# Files' Properties placement (--beside the tile or the menu's point, --over the window for Alt+Return) and its open
# action (the file's choice, then the default the Inspector names, then xdg-open): tests/files-props-open.tcl runs
# inside the shell under xvfb, with HOME and the XDG folders in a temp folder; XDG_DATA_DIRS holds the test's own
# apps and type tree, so what the host has installed does not count. Without wish8.6 or xvfb-run the step skips.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip files props/open (no wish8.6 / xvfb-run)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/config" "$T/etcxdg" "$T/state" "$T/cache" "$T/run" "$T/data/applications" "$T/data/mime"
D="$T/data/applications"
printf '[Desktop Entry]\nType=Application\nName=Test editor\nExec=testedit %%F\nMimeType=text/plain;\n' >"$D/ribbon-test-editor.desktop"
printf '[Desktop Entry]\nType=Application\nName=Other\nExec=otherapp %%u\n' >"$D/ribbon-test-other.desktop"
printf '[Desktop Entry]\nType=Application\nName=Hidden player\nExec=hiddenplayer %%U\nNoDisplay=true\nMimeType=audio/flac;audio/x-flac;\n' >"$D/ribbon-test-player.desktop"
printf '[Default Applications]\ntext/plain=ribbon-test-editor.desktop\n' >"$T/etcxdg/mimeapps.list"
printf 'image/svg+xml application/xml\napplication/xml text/plain\n' >"$T/data/mime/subclasses"
printf 'audio/x-flac audio/flac\n' >"$T/data/mime/aliases"
if HOME="$T/home" XDG_CONFIG_HOME="$T/config" XDG_CONFIG_DIRS="$T/etcxdg" XDG_STATE_HOME="$T/state" XDG_CACHE_HOME="$T/cache" \
	XDG_RUNTIME_DIR="$T/run" XDG_DATA_HOME="$T/home/.local/share" XDG_DATA_DIRS="$T/data" \
	RIBBON_SHELL_TEST=tests/files-props-open.tcl timeout -k 5 120 \
	xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/shell/main.tcl -name ribbon-shell >"$T/out" 2>&1 \
	&& grep -q 'files-props-open: all checks passed' "$T/out"; then
	grep '  ok ' "$T/out" | sed 's/^/  /'
	echo "files props/open: all checks passed"
else
	sed 's/^/       /' "$T/out"; echo "files props/open: checks failed"; exit 1
fi
