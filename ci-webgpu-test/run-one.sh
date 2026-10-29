#!/usr/bin/env bash
# usage: run-one.sh <label> <command...>   -- runs wgt, prints one RESULT line, exit 0 only on PASS with the expected hash
# Output goes to a file so a hang or crash still shows what was printed; the command is killed after RUN_ONE_TIMEOUT seconds (default 120).
EXPECTED=${EXPECTED_FNV:-9761e8ede774e783}   # fnv of d[i]=i*i+7 for i<256: independent of GPU, backend and OS
label=$1; shift
tmp=$(mktemp); "$@" >"$tmp" 2>&1 & pid=$!
for _ in $(seq 1 "${RUN_ONE_TIMEOUT:-120}"); do kill -0 $pid 2>/dev/null || break; sleep 1; done
if kill -0 $pid 2>/dev/null; then kill -9 $pid 2>/dev/null; echo "(timed out after ${RUN_ONE_TIMEOUT:-120}s, killed)" >>"$tmp"; rc=124; else wait $pid; rc=$?; fi
out=$(cat "$tmp")
printf '%s\n' "$out" | sed 's/^/    /'; echo "    exit code: $rc"
hash=$(printf '%s\n' "$out" | sed -n 's/.*fnv=\([0-9a-f]*\).*/\1/p' | head -1)
backend=$(printf '%s\n' "$out" | sed -n 's/^adapter: backend=\([0-9]*\).*/\1/p' | head -1)
# Windows builds of the Cosmopolitan runtime report exit codes shifted by 8 bits, so the RESULT line and hash decide there
if printf '%s\n' "$out" | grep -q 'RESULT PASS' && [ "$hash" = "$EXPECTED" ] && { [ $rc -eq 0 ] || [ "$RUNNER_OS" = Windows ]; }; then r=PASS; else r=FAIL; fi
line="RESULT [${RUNNER_LABEL:-local}] $label: $r backend=${backend:-none} fnv=${hash:-none}"
echo "$line"
[ -n "$GITHUB_STEP_SUMMARY" ] && echo "- $line" >> "$GITHUB_STEP_SUMMARY"
[ "$r" = PASS ]
