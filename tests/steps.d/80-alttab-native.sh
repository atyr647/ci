#!/bin/sh
# The Alt+Tab switcher's native half (U19): ribbon-shell-switch (keyboard on a layer-shell overlay, a still of the screen,
# window copies) with the real shell under a headless labwc. tests/alttab-native/run.sh; ALTTAB_ROOT=<test root> runs it
# against that root's labwc (0.8 or later; 0.20.3 has ext-image-copy-capture; CI: build/ci/labwc020.sh); without one it uses the host's labwc and skips
# when that is older than 0.8.
set -u
cd "$(dirname "$0")/../.." || exit 1
for t in pkg-config wayland-scanner wish8.6 grim convert; do
	command -v $t >/dev/null 2>&1 || { echo "  skip alttab native (no $t)"; exit 0; }
done
pkg-config --exists wayland-client xkbcommon wayland-protocols || { echo "  skip alttab native (no wayland-client / xkbcommon / wayland-protocols)"; exit 0; }
sh tests/alttab-native/run.sh ${ALTTAB_ROOT:-}
