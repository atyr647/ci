#!/bin/sh
# The base-specific pieces behind their seams (tests/base-neutral.sh): no package-manager wrapper, make install's
# base lines (Void's xbps.d files and kernel.d hook point only on xbps) and its record on the target, the
# base-neutral kernel hook (boot menu, restart flag), ribbon-dinit's runit compatibility only where /etc/sv is,
# the console keymap from /etc/vconsole.conf. The seam's own parts (services after a change, the keymap, removal by
# make install's record) are in tests/pkg-seam.sh (26-pkg-seam).
set -u
cd "$(dirname "$0")/../.." || exit 1
command -v bash >/dev/null 2>&1 || { echo "  skip base-neutral pieces (no bash)"; exit 0; }
bash tests/base-neutral.sh
