#!/bin/sh
# Game HUD frame layer (VK_LAYER_RIBBON_hud_frames): tests/hud-layer/run.sh. The layer built as the template builds it,
# loaded by the real Vulkan loader through its manifest into a stand-in game on a headless swapchain, its frame times
# read by the HUD's reader; no reader, a reader that leaves, a full pipe, the off switches, two programs at once.
# Runs the layer only where a Vulkan driver presents headless (VK_DRIVER_FILES may name lavapipe's ICD); else the
# build and the manifest only.
set -u
cd "$(dirname "$0")/../.." || exit 1
if timeout -k 5 300 sh tests/hud-layer/run.sh; then
	echo "  ok   Game HUD frame layer (tests/hud-layer/run.sh)"
else
	echo "  FAIL Game HUD frame layer (tests/hud-layer/run.sh)"; exit 1
fi
