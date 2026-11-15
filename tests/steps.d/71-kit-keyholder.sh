#!/bin/sh
# Which trusted key list holds a signing key (srcpkgs/ribbon-kit/files/lib/core.tcl ::kit::keyHolder, ::kit::keyList),
# and the signer Properties (kitlink::trust) and the Catalogue (kitq.tcl) name from it, Ribbon's list first, then every
# other repository's: tests/kit-keyholder.tcl. Needs minisign; skips without it or tclsh8.6.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip the key holder (no tclsh8.6)"
	exit 0
fi
timeout -k 5 120 tclsh8.6 -encoding utf-8 tests/kit-keyholder.tcl || { echo "  FAIL the key holder (tests/kit-keyholder.tcl)"; exit 1; }
