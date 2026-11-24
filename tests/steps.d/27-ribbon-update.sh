#!/bin/sh
# ribbon update and the package seam's update part (tests/ribbon-update.sh): the plan read without root, the
# terminal's order (snapshot, the base's packages, then kit check as the person), the reboot flag a kernel's update
# writes and the line that follows it, and the desktop's --tcl plan and done lines.
set -u
cd "$(dirname "$0")/../.." || exit 1
command -v bash >/dev/null 2>&1 || { echo "  skip ribbon update (no bash)"; exit 0; }
bash tests/ribbon-update.sh
