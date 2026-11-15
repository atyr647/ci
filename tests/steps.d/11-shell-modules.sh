#!/bin/sh
# Shell modules (C2): a shell/mod-*.tcl that registers a ctl verb with shell::verb is sourced by main.tcl,
# and its verb is called with the words after it when the shell's FIFO gets the line. The step runs a copy of
# the shell folder with one probe module added, so no module is left in the source tree. Skips without
# wish8.6 or xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip shell modules (no wish8.6 / xvfb-run)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cp -r srcpkgs/ribbon-desktop/files/shell "$T/shell"
# the shell finds rbnalpha next to its folder, as in the source tree
cp -r srcpkgs/ribbon-desktop/files/rbnalpha "$T/rbnalpha"
cat > "$T/shell/mod-probe.tcl" <<'TCL'
shell::verb probe fault_probe_verb
proc fault_probe_verb {args} {
	set fh [open $::env(FAULT_PROBE_OUT) w]
	puts $fh $args
	close $fh
}
TCL
mkdir -p "$T/home" "$T/state" "$T/cache" "$T/run"
if HOME=$T/home XDG_STATE_HOME=$T/state XDG_CACHE_HOME=$T/cache XDG_RUNTIME_DIR=$T/run \
	FAULT_MODE=verb FAULT_PROBE_OUT=$T/probe RIBBON_SHELL_TEST=tests/shell-fault.tcl \
	timeout -k 5 60 xvfb-run -a -s "-screen 0 1440x900x24" \
	wish8.6 -encoding utf-8 "$T/shell/main.tcl" -name ribbon-shell >"$T/out" 2>&1 && ! grep -q '  FAIL' "$T/out"; then
	echo "  ok   a module's shell::verb is called through the FIFO"
	grep '  ok ' "$T/out" | sed 's/^/       /'
else
	sed 's/^/       /' "$T/out"; echo "  FAIL shell modules: the probe verb did not run"; exit 1
fi
