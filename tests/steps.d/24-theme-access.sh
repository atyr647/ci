#!/bin/sh
# Settings → Accessibility through ribbon-theme: access.conf to GTK, X resources, GSettings, foot and labwc's cursor (tests/test-theme-access.sh).
set -u
cd "$(dirname "$0")/../.." || exit 1
if timeout -k 5 180 sh tests/test-theme-access.sh; then
	echo "  ok   ribbon-theme applies access.conf (tests/test-theme-access.sh)"
else
	echo "  FAIL ribbon-theme applies access.conf (tests/test-theme-access.sh)"; exit 1
fi
