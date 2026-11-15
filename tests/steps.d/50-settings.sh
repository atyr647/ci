#!/bin/sh
# Settings (U08): tests/test-settings.sh (the rail, the hosted Appearance pages under xvfb, the picture fit).
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then echo "  skip Settings (no tclsh8.6)"; exit 0; fi
if timeout -k 5 600 sh tests/test-settings.sh; then
	echo "  ok   Settings (tests/test-settings.sh)"
else
	echo "  FAIL Settings (tests/test-settings.sh)"; exit 1
fi
