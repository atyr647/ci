#!/bin/sh
# labwc's keys and desktop menu (tests/test-labwc-keys.sh), and what Print and the menu's Web browser run:
# ribbon-screenshot with its notification on a private bus, and ribbon-browser (tests/test-screenshot.sh).
cd "$(dirname "$0")/../.." || exit 1
sh tests/test-labwc-keys.sh || exit 1
sh tests/test-screenshot.sh
