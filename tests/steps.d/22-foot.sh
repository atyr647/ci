#!/bin/sh
# foot (U05): tests/test-foot.sh (foot.ini per palette, OSC recolour, the session terminal entries).
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v python3 >/dev/null 2>&1; then echo "  skip foot (no python3)"; exit 0; fi
if timeout -k 5 300 bash tests/test-foot.sh; then
	echo "  ok   foot (tests/test-foot.sh)"
else
	echo "  FAIL foot (tests/test-foot.sh)"; exit 1
fi
