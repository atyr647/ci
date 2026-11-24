#!/bin/sh
# Notifications over a private session bus, end to end (actions, signals, hints): tests/test-notify-bus.sh.
cd "$(dirname "$0")/../.." || exit 1
sh tests/test-notify-bus.sh
