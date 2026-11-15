#!/bin/sh
# The installer on 1366x768 and 1280x800 screens: the compact window of the Inst-C* boards, clear of the bars and the
# dock, against the boards and under headless labwc with the real shell (tests/test-installer-small-screens.sh).
cd "$(dirname "$0")/../.." || exit 1
sh tests/test-installer-small-screens.sh
