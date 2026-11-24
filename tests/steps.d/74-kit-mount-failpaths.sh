#!/bin/sh
# mount.tcl's failure paths with stand-in tools (tests/kit-mount-failpaths.tcl): a device losetup attached before it
# refused direct I/O is detached again; a switch whose old view does not detach after kit-swapmount slid the new one
# beneath it fails, keeps `current` on the old view and leaves no new view files or stage behind. No root needed.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip mount.tcl's failure paths (no tclsh8.6)"
	exit 0
fi
timeout -k 5 120 tclsh8.6 -encoding utf-8 tests/kit-mount-failpaths.tcl || { echo "  FAIL mount.tcl's failure paths (tests/kit-mount-failpaths.tcl)"; exit 1; }
