#!/bin/sh
# Dark or light for GTK 4, libadwaita and Firefox (color-scheme in GSettings, ribbon-portals.conf), Adwaita in place of arc-theme, no purple scheme: tests/test-theme-scheme.sh.
set -u
cd "$(dirname "$0")/../.." || exit 1
if timeout -k 5 120 sh tests/test-theme-scheme.sh; then
	echo "  ok   theme color-scheme, portals, no purple (tests/test-theme-scheme.sh)"
else
	echo "  FAIL theme color-scheme, portals, no purple (tests/test-theme-scheme.sh)"; exit 1
fi
