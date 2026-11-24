#!/bin/sh
# tests/run.sh's scene loops (the shell's, the greeter's and the installer's pages) print a failing scene's own
# output: each loop is taken from run.sh as it is and run with an xvfb-run on PATH that prints a line and fails,
# and that line must come out before the loop's FAIL line. Plain sh, no display.
set -u
cd "$(dirname "$0")/../.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "scene output: ${RIBBON_SCENE:-}${RIBBON_GREETER_SCENE:-}"\nexit 1\n' >"$T/bin/xvfb-run"; chmod +x "$T/bin/xvfb-run"
fails=0
loop() {  # NAME FIRST-LINE (a string in it) LAST-LINE (a regular expression) SCENE
	awk -v a="$2" -v b="$3" 'index($0, a) { on = 1 } on { print } on && $0 ~ b { exit }' tests/run.sh >"$T/$1.sh"
	if ! grep -q . "$T/$1.sh"; then echo "  FAIL run.sh: the $1 scene loop was not found"; fails=$((fails + 1)); return; fi
	( status=0; cache=$T; PATH="$T/bin:$PATH"; . "$T/$1.sh" ) >"$T/$1.out" 2>&1
	# the scene's line, then its FAIL line
	if [ "$(grep -n -m1 "scene output: $4" "$T/$1.out" | cut -d: -f1)" -lt "$(grep -n -m1 "FAIL .*$4" "$T/$1.out" | cut -d: -f1)" ] 2>/dev/null; then
		echo "  ok   run.sh prints a failing $1 scene's output ($4)"
	else
		sed 's/^/       /' "$T/$1.out" | head -20; echo "  FAIL run.sh does not print a failing $1 scene's output"; fails=$((fails + 1))
	fi
}
loop shell 'log=$(mktemp)' '^[[:space:]]*rm -f "[$]log"$' idle
loop greeter 'for scene in password wrong' '^[[:space:]]*done$' password
loop installer 'for scene in welcome keyboard' '^[[:space:]]*done$' welcome
[ $fails -eq 0 ] && echo "run.sh scene logs: all checks passed"
[ $fails -eq 0 ]
