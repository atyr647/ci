#!/bin/sh
# kitfmt, the .kit reader and writer (kit/kitfmt): its own tcltest suite, kit/kitfmt/tests/all.tcl (kitfmt.test: the
# golden kits, every refusal, signatures, statements, images). Needs Mk4tcl (KITFMT_MK4TCL, or installed); skips
# without it or without tclsh8.6.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip kitfmt's tests (no tclsh8.6)"
	exit 0
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
printf 'lappend auto_path {%s}\npackage require Mk4tcl\n' "${KITFMT_MK4TCL:-}" >"$work/mk4.tcl"
if ! tclsh8.6 "$work/mk4.tcl" >/dev/null 2>&1; then
	echo "  skip kitfmt's tests (no Mk4tcl: KITFMT_MK4TCL)"
	exit 0
fi
# all.tcl exits 0 on a test file that does not load: that counts as a failure here
if TMPDIR=$work timeout -k 5 600 tclsh8.6 kit/kitfmt/tests/all.tcl >"$work/out" 2>&1 && ! grep -q '^Test file error' "$work/out" \
	&& grep -Eq '^all\.tcl:.*Total[[:space:]]+[1-9]' "$work/out"; then
	grep -E '^all\.tcl:' "$work/out" | sed 's/^/  ok   kitfmt: /'
else
	cat "$work/out"; echo "  FAIL kitfmt's tests (kit/kitfmt/tests/all.tcl)"; exit 1
fi
