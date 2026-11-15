#!/bin/sh
# Game HUD (U22): tests/test-hud.sh (the readers on fixture trees, the layouts and drawing under xvfb).
set -u
cd "$(dirname "$0")/../.." || exit 1
if timeout -k 5 300 sh tests/test-hud.sh; then
	echo "  ok   Game HUD (tests/test-hud.sh)"
else
	echo "  FAIL Game HUD (tests/test-hud.sh)"; exit 1
fi
