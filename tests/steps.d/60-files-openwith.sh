#!/bin/sh
# Files' Inspector panel and "Opens with" choices (properties/openwith.tcl, shell/files.tcl's panel and open
# action, the Inspector's "Every <type> file" switch): tests/files-openwith.tcl runs inside the shell under
# xvfb, with HOME and the XDG folders in a temp folder. Without wish8.6 or xvfb-run the step skips.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip files openwith (no wish8.6 / xvfb-run)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/config" "$T/state" "$T/cache" "$T/run" "$T/data" "$T/etcxdg"
if HOME="$T/home" XDG_CONFIG_HOME="$T/config" XDG_STATE_HOME="$T/state" XDG_CACHE_HOME="$T/cache" XDG_RUNTIME_DIR="$T/run" XDG_DATA_DIRS="$T/data" XDG_CONFIG_DIRS="$T/etcxdg" \
	RIBBON_SHELL_TEST=tests/files-openwith.tcl timeout -k 5 120 \
	xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/shell/main.tcl -name ribbon-shell >"$T/out" 2>&1 \
	&& grep -q 'files-openwith: all checks passed' "$T/out"; then
	grep '  ok ' "$T/out" | sed 's/^/  /'
	echo "files openwith: all checks passed"
else
	sed 's/^/       /' "$T/out"; echo "files openwith: checks failed"; exit 1
fi
