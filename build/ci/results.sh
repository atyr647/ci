#!/bin/sh
# results.sh - fetch what the last CI run left on the CI repository's ribbon-results branch into DIR
# (default out/ci-results): summary.txt (the RESULT lines of the checks, the image and the boot test), the checks'
# failures, skips and log tail, serial.log, the screenshots, the build logs' tails.
#   build/ci/results.sh [CI-CLONE] [DIR]
#   build/ci/results.sh --wait REVISION MINUTES [CI-CLONE] [DIR]
#        poll (every 2 minutes) until the results are those of REVISION (the "revision:" line of summary.txt, as
#        export.sh printed it), for at most MINUTES; exits 1 when the deadline passes first
set -eu
cd "$(dirname "$0")/../.."
wait_rev='' deadline=''
if [ "${1:-}" = --wait ]; then
	wait_rev=${2:?usage: results.sh --wait REVISION MINUTES [CI-CLONE] [DIR]}
	deadline=$(($(date +%s) + ${3:?usage: results.sh --wait REVISION MINUTES [CI-CLONE] [DIR]} * 60))
	shift 3
fi
CI=${1:-../ci}; OUT=${2:-out/ci-results}
fetch() {
	git -C "$CI" fetch -q --depth 1 origin "+ribbon-results:refs/remotes/origin/ribbon-results"
	rm -rf "$OUT"; mkdir -p "$OUT"
	git -C "$CI" archive origin/ribbon-results | tar -x -C "$OUT"
}
if [ -n "$wait_rev" ]; then
	while :; do
		fetch 2>/dev/null || :
		grep -q "^revision: $wait_rev" "$OUT/summary.txt" 2>/dev/null && break
		[ "$(date +%s)" -lt "$deadline" ] || { echo "results.sh: no results for $wait_rev before the deadline" >&2; exit 1; }
		sleep 120
	done
else
	fetch
fi
cat "$OUT/summary.txt" 2>/dev/null || ls "$OUT"
