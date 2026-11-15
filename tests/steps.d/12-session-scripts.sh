#!/bin/sh
# The session's small scripts against stand-ins and fixture paths (tests/test-session-scripts.sh): ribbon-firstrun,
# ribbon-conky and its layouts, the ribbon-power-limit boot service, greetd-launch.
cd "$(dirname "$0")/../.." || exit 1
sh tests/test-session-scripts.sh
