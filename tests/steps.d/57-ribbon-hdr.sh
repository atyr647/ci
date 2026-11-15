#!/bin/sh
# ribbon-hdr: on and off write the labwc layer and apply in a running session; off under the Vulkan renderer reloads
# labwc so the screen leaves HDR at once (the HUD quick menu's HDR row). tests/ribbon-hdr.sh, stand-in labwc.
set -u
cd "$(dirname "$0")/../.." || exit 1
command -v bash >/dev/null 2>&1 || { echo "  skip ribbon-hdr (no bash)"; exit 0; }
if timeout -k 5 60 sh tests/ribbon-hdr.sh; then echo "  ok   ribbon-hdr (tests/ribbon-hdr.sh)"; else echo "  FAIL ribbon-hdr (tests/ribbon-hdr.sh)"; exit 1; fi
