#!/bin/sh
# kit run's trust policy (DECISIONS-DELEGATED 27; srcpkgs/ribbon-kit/files/lib/launch.tcl, mkkitfsd's trust-other):
# tests/kit-run-trust.tcl runs kits through the mkkitfsd that kit run starts, with kittrust in mode installed over
# Ribbon's key list and another repository's: right role and key run, an unknown key and the wrong role are refused,
# an installed kit whose key expired since still runs, one whose key was revoked since does not. Needs FUSE, mkkitfs
# on the PATH (tests/run.sh builds it from KIT_METAKIT_TARBALL), Mk4tcl (KITFMT_MK4TCL), unix_sockets, bubblewrap and
# minisign; skips without them.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip kit run's trust policy (no tclsh8.6)"
	exit 0
fi
timeout -k 5 300 tclsh8.6 -encoding utf-8 tests/kit-run-trust.tcl || { echo "  FAIL kit run's trust policy (tests/kit-run-trust.tcl)"; exit 1; }
