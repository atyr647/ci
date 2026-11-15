#!/bin/sh
# Notes opened on a Markdown file (Files' "Open with Notes", the .desktop file's %F): apps/notes/main.tcl started
# under xvfb with a file outside the store as its argument and tests/notes-open.tcl as its scene, which checks that the
# file is imported into the store's top folder and opens (not an empty note), that opening it again makes no copy, that
# a taken name gets a number, and that a note inside the store opens as itself. Without wish8.6 or xvfb-run the step
# skips. Every run has a hard timeout.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip notes open (no wish8.6 / xvfb-run)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/state" "$T/cache" "$T/store/Work" "$T/out/other"
printf '# Plan\n\n- Buy milk\n' >"$T/out/Plan.md"
printf '# Other plan\n\nSomething else\n' >"$T/out/other/Plan.md"
printf -- '---\ntitle: Trip to Oslo\n---\n# Trip\n' >"$T/out/titled.md"
printf '# Ideas\n\nInside the store\n' >"$T/store/Work/Ideas.md"
printf '# Shouting\n\nUpper case\n' >"$T/store/Work/Loud.MD"
if HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_CACHE_HOME="$T/cache" RIBBON_NOTES_ROOT="$T/store" \
	RIBBON_NOTES_OUTSIDE="$T/out" RIBBON_NOTES_SCENE="$PWD/tests/notes-open.tcl" timeout -k 5 120 \
	xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/apps/notes/main.tcl "$T/out/Plan.md" \
	</dev/null >"$T/out.log" 2>&1 && grep -q "^open: ok" "$T/out.log"
then
	grep '  ok ' "$T/out.log"
	echo "notes open: all checks passed"
else
	sed 's/^/       /' "$T/out.log"; echo "  FAIL notes open"; exit 1
fi
