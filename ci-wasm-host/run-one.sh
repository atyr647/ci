#!/usr/bin/env bash
# usage: run-one.sh <label> <command...>  -> prints one RESULT line; exit 0 only on PASS
label=$1; shift
out=$("$@" 2>&1); rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
if [ $rc -eq 0 ] && printf '%s\n' "$out" | grep -q 'RESULT PASS'; then r=PASS; else r=FAIL; fi
line="RESULT [${RUNNER_LABEL:-local}] $label: $r"; echo "$line"
[ -n "$GITHUB_STEP_SUMMARY" ] && echo "- $line" >> "$GITHUB_STEP_SUMMARY"
[ "$r" = PASS ]
