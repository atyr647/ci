#!/bin/sh
# Notifications sent before the shell is up: tests/test-notify-activation.sh.
cd "$(dirname "$0")/../.." || exit 1
sh tests/test-notify-activation.sh
