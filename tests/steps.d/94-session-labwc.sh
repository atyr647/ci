#!/bin/sh
# The whole session: make install, then the installed ribbon-session under headless labwc with its real autostart,
# through a stand-in user dinit and without one (tests/test-session-labwc.sh).
cd "$(dirname "$0")/../.." || exit 1
timeout -k 10 900 sh tests/test-session-labwc.sh
