#!/usr/bin/env bash
# usage: run-one.sh <label> <command...>  -> prints one RESULT line; exit 0 only on PASS
# Output goes to a file so a hang still shows what was printed; the command is stopped after RUN_ONE_TIMEOUT seconds (default 60).
label=$1; shift
tmp=$(mktemp); "$@" >"$tmp" 2>&1 & pid=$!
for _ in $(seq 1 "${RUN_ONE_TIMEOUT:-60}"); do kill -0 $pid 2>/dev/null || break; sleep 1; done
if kill -0 $pid 2>/dev/null; then kill -9 $pid 2>/dev/null; echo "    (timed out after ${RUN_ONE_TIMEOUT:-60}s, killed)" >>"$tmp"; rc=124; else wait $pid; rc=$?; fi
sed 's/^/    /' "$tmp"; echo "    exit code: $rc"
if [ $rc -eq 0 ] && grep -q 'RESULT PASS' "$tmp"; then r=PASS; else r=FAIL; fi
line="RESULT [${RUNNER_LABEL:-local}] $label: $r"; echo "$line"
[ -n "$GITHUB_STEP_SUMMARY" ] && echo "- $line" >> "$GITHUB_STEP_SUMMARY"
[ "$r" = PASS ]
