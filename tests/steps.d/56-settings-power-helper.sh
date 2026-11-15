#!/bin/sh
# Settings → Power, the privileged half (U14b): apps/settings/bin/ribbon-power-helper on a fake root and a fake /proc
# (tests/settings-power-helper.tcl): the allow-list, the drop-in and UPower.conf writes, atomic replacement, the safety
# checks, the signals, the charge limit. The page driving the helper through a stub pkexec is in 55-settings-power.sh.
# Skips without tclsh8.6. NOT covered: real root, a real elogind or upowerd, a real polkit prompt, a real battery.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip Settings → Power helper (no tclsh8.6)"; exit 0
fi
D=srcpkgs/ribbon-desktop/files
if timeout -k 5 120 tclsh8.6 tests/settings-power-helper.tcl "$D/apps/settings/bin/ribbon-power-helper" >"${TMPDIR:-/tmp}/ph.$$" 2>&1; then
	sed 's/^/       /' "${TMPDIR:-/tmp}/ph.$$" | grep -v '  ok ' ; rm -f "${TMPDIR:-/tmp}/ph.$$"
	echo "  ok   Settings → Power helper: allow-list, writes, atomic replace, signals, charge limit"
else
	sed 's/^/       /' "${TMPDIR:-/tmp}/ph.$$"; rm -f "${TMPDIR:-/tmp}/ph.$$"
	echo "  FAIL Settings → Power helper"; exit 1
fi
