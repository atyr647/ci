#!/bin/sh
# fuzz-sanitize.sh -- the fuzz pass (fuzz.py) on a mkkitfs built with AddressSanitizer and
# UndefinedBehaviorSanitizer (make fuzz builds it, Metakit included).  Two passes:
#   1. ITER damaged kits through the confined reader (src/confine.cpp), as it runs for real: any
#      sanitizer report, crash or hang is a failure (exit codes 86 ASan, 87 UBSan);
#   2. ITER/5 more, unconfined (MKKITFS_UNCONFINED, honoured only by sanitizer builds), with
#      LeakSanitizer on: it needs ptrace, which the confinement takes away.
#
#   sh fuzz-sanitize.sh SANITIZED_MKKITFS [ITER [SEED]]       (RIBBON_TREE: the golden kits' tree)
set -u
here=$(cd "$(dirname "$0")" && pwd)
top=${RIBBON_TREE:-$(cd "$here/../../../.." && pwd)}
M=${1:?usage: fuzz-sanitize.sh SANITIZED_MKKITFS [ITER [SEED]]}
iter=${2:-2000}
seed=${3:-1}
gold=$top/kit/kitfmt/tests/golden
keys=$top/kit/kitfmt/tests/keys/test.pub
command -v python3 >/dev/null 2>&1 || { echo "  skip sanitizer fuzz pass (no python3)"; exit 0; }
status=0
export UBSAN_OPTIONS=halt_on_error=1:exitcode=87:print_stacktrace=1
if out=$(ASAN_OPTIONS=exitcode=86:detect_leaks=0:abort_on_error=0 FUZZ_SANITIZER=1 \
	python3 "$here/fuzz.py" "$M" "$gold" "$keys" "$iter" "$seed" 2>&1); then
	echo "  ok   ASan+UBSan, confined: $(printf '%s\n' "$out" | tail -1)"
else
	printf '%s\n' "$out" | tail -40; echo "  FAIL ASan+UBSan fuzz pass (confined)"; status=1
fi
leak=$((iter / 5)); [ "$leak" -ge 1 ] || leak=1
if out=$(ASAN_OPTIONS=exitcode=86:detect_leaks=1:abort_on_error=0 MKKITFS_UNCONFINED=1 FUZZ_SANITIZER=1 \
	python3 "$here/fuzz.py" "$M" "$gold" "$keys" "$leak" "$((seed + 1000003))" 2>&1); then
	echo "  ok   LeakSanitizer, unconfined: $(printf '%s\n' "$out" | tail -1)"
else
	printf '%s\n' "$out" | tail -40; echo "  FAIL LeakSanitizer fuzz pass"; status=1
fi
exit $status
