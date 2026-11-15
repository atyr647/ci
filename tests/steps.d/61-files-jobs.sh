#!/bin/sh
# Ribbon Files' copy and move jobs (shell/files-jobs.tcl, the queue in shell/files.tcl): the progress
# notification with Pause and Cancel (Notify-Final-3-Progress), the last one when the job is done, and
# Replace killed before each step (tests/files-jobs.tcl). Plain tclsh, no display, no bus.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip files jobs (no tclsh8.6)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
if timeout -k 5 600 tclsh8.6 -encoding utf-8 tests/files-jobs.tcl >"$T/out" 2>&1; then
	grep '  ok ' "$T/out" | sed 's/^/  /'
	echo "files jobs: all checks passed"
else
	sed 's/^/       /' "$T/out"
	echo "files jobs: checks failed"
	exit 1
fi
