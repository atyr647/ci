#!/bin/sh
# Tcl 9 no longer expands a ~ at the start of a file name (Tcl's own file commands, open, glob, source): the home
# folder is taken from HOME. This lints the Tcl under srcpkgs for a tilde path given to a file command (the sweep for
# Ribbon's own Tcl/Tk 9 at independence, docs/STACK.md section 4); strings that are matched, shown or expanded by the
# program itself (apps.tcl, the launcher, the file chooser) are no file names and are not flagged.
set -u
cd "$(dirname "$0")/../.." || exit 1
hits=$(grep -rnE '(file (normalize|join|nativename|dirname|tail|exists|isdirectory|isfile|readable|writable|mkdir|delete|copy|rename|stat|size|type|attributes|mtime)|open|glob|source|cd|exec|slurp|spit)( +-[a-z]+)* +"?~(/|[]} "]|$)' \
	srcpkgs --include='*.tcl' --include='ribbon-*' --include=kit --include=kitd 2>/dev/null | grep -Ev ':[0-9]+:[[:space:]]*#' || true)
if [ -z "$hits" ]; then
	echo "  ok   no Tcl file command is given a ~ path (Tcl 9 does not expand it)"
else
	echo "$hits" | sed 's/^/    /'
	echo "  FAIL a ~ path reaches a Tcl file command"; exit 1
fi
