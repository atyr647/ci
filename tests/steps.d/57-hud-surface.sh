#!/bin/sh
# Game HUD surface and toggle (U23): tests/hud-native/run.sh. The real ribbon-hud-surface (a layer-shell overlay with an
# empty input region) and daemon under a headless labwc, over a fullscreen Wayland client: the Super+F12 cycle, above a
# fullscreen client, see-through glass, clicks and keys pass through, the interactive buttons, the quick-menu move, Close,
# and the cairo drawing against the Tk canvas drawing. HUD_ROOT=<root> runs it against that root's labwc: a root of
# prebuilt packages with labwc 0.8 or later (0.20.x on Ribbon's base; CI makes one, build/ci/labwc020.sh), entered with
# chroot, so it needs root's rights. A HUD_ROOT that cannot be used fails the step (it never falls back to the host's
# labwc). Without one the host's labwc runs (the container's is 0.7.1). Skips without labwc, wish8.6, grim,
# ImageMagick, cairo or wayland headers.
set -u
cd "$(dirname "$0")/../.." || exit 1
if [ -n "${HUD_ROOT:-}" ]; then
	R=$HUD_ROOT
	if [ ! -x "$R/usr/bin/labwc" ]; then echo "  FAIL Game HUD surface: HUD_ROOT=$R has no usr/bin/labwc"; exit 1; fi
	if [ "$(id -u)" != 0 ]; then echo "  FAIL Game HUD surface: HUD_ROOT needs root's rights (chroot)"; exit 1; fi
	LV=$(chroot "$R" labwc -v 2>/dev/null | sed -n 's/^labwc \([0-9][0-9.]*\).*/\1/p' | head -n1)
	case $LV in
	"") echo "  FAIL Game HUD surface: labwc in HUD_ROOT=$R does not run"; exit 1 ;;
	0.[0-7]|0.[0-7].*) echo "  FAIL Game HUD surface: HUD_ROOT=$R has labwc $LV; a root is for labwc 0.8 or later"; exit 1 ;;
	esac
	echo "  note Game HUD surface against labwc $LV in $R"
fi
if timeout -k 5 400 sh tests/hud-native/run.sh ${HUD_ROOT:-}; then
	echo "  ok   Game HUD surface (tests/hud-native/run.sh)"
else
	echo "  FAIL Game HUD surface (tests/hud-native/run.sh)"; exit 1
fi
