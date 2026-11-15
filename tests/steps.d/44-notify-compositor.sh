#!/bin/sh
# The popups and the history under headless labwc: see-through, no card (tests/test-notify-compositor.sh).
cd "$(dirname "$0")/../.." || exit 1
sh tests/test-notify-compositor.sh
