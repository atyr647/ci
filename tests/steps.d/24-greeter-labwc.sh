#!/bin/sh
# The login screen in labwc with a locked-down config, not cage (STACK S8): tests/test-greeter-labwc.sh, headless labwc.
set -u
cd "$(dirname "$0")/../.." || exit 1
if timeout -k 5 180 sh tests/test-greeter-labwc.sh; then
	echo "  ok   greeter in labwc (tests/test-greeter-labwc.sh)"
else
	echo "  FAIL greeter in labwc (tests/test-greeter-labwc.sh)"; exit 1
fi
