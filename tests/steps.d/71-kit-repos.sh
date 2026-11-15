#!/bin/sh
# Kit trust T7 A (docs/KIT-TRUST.md section 6): per-repository key lists. tests/kit-repos.tcl loads the kit CLI's
# core with /etc/kit/repos.d-style files: Ribbon's list and another publisher's, each with its own roots; the other's
# app kits verify, its system kits never do (only Ribbon's list grants the system role), a list for another repository
# than its file names is refused and anchors nothing, a key Ribbon's list holds is judged by Ribbon's list alone,
# Ribbon's mirrors come from its repository file. tests/kit-publish.sh runs the publishing routine of section 5 as CI
# would (a 2-of-3 root ceremony, kit pack of Ribbon Notes, kitseal, kitindex build) with the test-only keys, and a
# client that has only Ribbon's repository file installs Notes from the file:// mirror and another publisher's .kit
# once its repository file is there. Needs tclsh8.6 and minisign; the publishing run also needs Mk4tcl
# (KITFMT_MK4TCL=<dir>) and skips without it.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1 || ! command -v minisign >/dev/null 2>&1; then
	echo "  skip per-repository key lists (no tclsh8.6 / minisign)"
	exit 0
fi
status=0
timeout -k 5 300 tclsh8.6 tests/kit-repos.tcl || { echo "  FAIL per-repository key lists (tests/kit-repos.tcl)"; status=1; }
timeout -k 5 600 sh tests/kit-publish.sh || { echo "  FAIL publishing kits (tests/kit-publish.sh)"; status=1; }
exit $status
