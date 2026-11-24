#!/bin/sh
# The repository index's lines beyond the kits, as the Catalogue reads them (tests/kit-catalogue-index.tcl): a title
# line names an app that is not installed ("OBS Studio", srcpkgs/ribbon-kit/files/lib/repo.tcl), and kitq.tcl says why
# there is no index when none can be had. Needs Mk4tcl (KITFMT_MK4TCL) and minisign; skips without them or without tclsh8.6.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip the Catalogue's index lines (no tclsh8.6)"
	exit 0
fi
# the test packs and signs real kits: without Mk4tcl or minisign it cannot run (as kitfmt's own tests skip)
if ! command -v minisign >/dev/null 2>&1 || ! printf 'lappend auto_path {%s}\nexit [catch {package require Mk4tcl}]\n' "${KITFMT_MK4TCL:-}" | tclsh8.6 >/dev/null 2>&1; then
	echo "  skip the Catalogue's index lines (needs Mk4tcl: KITFMT_MK4TCL, and minisign)"
	exit 0
fi
timeout -k 5 300 tclsh8.6 -encoding utf-8 tests/kit-catalogue-index.tcl || { echo "  FAIL the Catalogue's index lines (tests/kit-catalogue-index.tcl)"; exit 1; }
