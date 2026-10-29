#!/usr/bin/env bash
# usage: run-one.sh <label> <command...>   -- runs wgt, prints one RESULT line, exit 0 only on PASS with the expected hash
EXPECTED=${EXPECTED_FNV:-9761e8ede774e783}   # fnv of d[i]=i*i+7 for i<256: independent of GPU, backend and OS
label=$1; shift
out=$("$@" 2>&1); rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
hash=$(printf '%s\n' "$out" | sed -n 's/.*fnv=\([0-9a-f]*\).*/\1/p' | head -1)
backend=$(printf '%s\n' "$out" | sed -n 's/^adapter: backend=\([0-9]*\).*/\1/p' | head -1)
if [ $rc -eq 0 ] && printf '%s\n' "$out" | grep -q 'RESULT PASS' && [ "$hash" = "$EXPECTED" ]; then r=PASS; else r=FAIL; fi
line="RESULT [${RUNNER_LABEL:-local}] $label: $r backend=${backend:-none} fnv=${hash:-none}"
echo "$line"
[ -n "$GITHUB_STEP_SUMMARY" ] && echo "- $line" >> "$GITHUB_STEP_SUMMARY"
[ "$r" = PASS ]
