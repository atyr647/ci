#!/bin/sh
# kit's system scope puts a kernel that a system change brought into the /usr view on the boot menu, beside the running
# one (srcpkgs/ribbon-kit/files/lib/system.tcl, KernelsBeside): tests/kit-system-kernels.tcl with a stand-in for
# kernel-boot-files. Needs no Mk4tcl, root or mounts; skips without tclsh8.6.
set -u
cd "$(dirname "$0")/../.." || exit 1
command -v tclsh8.6 >/dev/null 2>&1 || { echo "  skip kit's kernels beside the running one (no tclsh8.6)"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
if TMPDIR=$T timeout -k 5 60 tclsh8.6 -encoding utf-8 tests/kit-system-kernels.tcl >"$T/out" 2>&1; then
	echo "  ok   a kernel new in the system view is made bootable beside the running one ($(grep -c '^  ok ' "$T/out") checks)"
else cat "$T/out"; echo "  FAIL kit's kernels beside the running one"; exit 1; fi
