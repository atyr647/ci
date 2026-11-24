#!/bin/sh
# The shell's fault isolation (shell/fault.tcl; HANDOFF robustness 4a and 4b), in the real shell under
# xvfb, driven by tests/shell-fault.tcl as RIBBON_SHELL_TEST. An error in an `after` is logged and the
# shell goes on, with no dialog; a corrupt state file is dropped and the shell still starts; a state saved
# before a SIGSEGV is read back by the next start (a stub supervisor restarts the shell); a crash loop starts
# once without the saved state, and then gives up with status 1 and a log line. Without wish8.6 or xvfb-run
# the step skips.
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip shell fault (no wish8.6 / xvfb-run)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
SHELL_MAIN=${SHELL_MAIN:-srcpkgs/ribbon-desktop/files/shell/main.tcl}

# one start of the shell in its own home, state, cache and runtime folders: run_shell NAME MODE
run_shell() {
	n=$1; mode=$2
	mkdir -p "$T/$n/home" "$T/$n/state" "$T/$n/cache" "$T/$n/run"
	HOME=$T/$n/home XDG_STATE_HOME=$T/$n/state XDG_CACHE_HOME=$T/$n/cache XDG_RUNTIME_DIR=$T/$n/run \
		FAULT_MODE=$mode FAULT_PROBE_OUT=$T/$n/probe RIBBON_SHELL_TEST=tests/shell-fault.tcl \
		timeout -k 5 60 xvfb-run -a -s "-screen 0 1440x900x24" \
		wish8.6 -encoding utf-8 "$SHELL_MAIN" -name ribbon-shell >"$T/$n.out" 2>&1
}
log() { cat "$T/$1/state/ribbon/shell.log" 2>/dev/null; }
show() { sed 's/^/       /' "$T/$1.out"; }
now() { date +%s; }

# 1. an error in an after: logged, the shell goes on
if run_shell err error; then
	if grep -q '  FAIL' "$T/err.out"; then show err; fail "error in an after: a check failed"; else ok "error in an after: logged, the shell goes on, no dialog"; fi
else
	show err; fail "error in an after: the shell stopped"
fi
case $(log err) in *boom-from-after*) ;; *) fail "error in an after: not in shell.log" ;; esac

# 2. a corrupt state file is dropped; the shell starts
mkdir -p "$T/corrupt/state/ribbon" "$T/corrupt/run"
printf '\000\377 junk\nno key here\n' > "$T/corrupt/state/ribbon/shell-state"
if run_shell corrupt plain && [ ! -e "$T/corrupt/state/ribbon/shell-state" ] && grep -q 'shell-state dropped' "$T/corrupt/state/ribbon/shell.log" 2>/dev/null; then
	ok "a corrupt state file is dropped and the shell starts"
else
	show corrupt; fail "a corrupt state file was not dropped, or the shell did not start"
fi

# 3. state saved before a crash comes back after the restart (stub supervisor: restart until it exits 0)
rc=1; i=0
while [ "$rc" -ne 0 ] && [ "$i" -lt 3 ]; do
	run_shell rt state; rc=$?; i=$((i + 1))
done
if [ "$i" -eq 2 ] && [ "$rc" -eq 0 ] && grep -q '  ok   state comes back after a restart' "$T/rt.out"; then
	ok "state saved before a SIGSEGV is read back by the restarted shell"
else
	show rt; fail "state round trip: starts $i, status $rc"
fi

# 4. the third start in a minute runs without the saved state, and logs it
mkdir -p "$T/cl3/state/ribbon" "$T/cl3/run"
printf 'panel stale\n' > "$T/cl3/state/ribbon/shell-state"
t=$(now); printf '%s\n%s\n' "$((t - 20))" "$((t - 10))" > "$T/cl3/run/ribbon-shell.starts"
if run_shell cl3 plain && grep -qx 'state panel=' "$T/cl3.out" && grep -q 'starting without the saved state' "$T/cl3/state/ribbon/shell.log" 2>/dev/null; then
	ok "crash loop, third start: the saved state is ignored, and logged"
else
	show cl3; fail "crash loop, third start"
fi

# 5. the fourth start in a minute gives up: status 1 and a log line, and the shell does not start
mkdir -p "$T/cl4/state/ribbon" "$T/cl4/run"
t=$(now); printf '%s\n%s\n%s\n' "$((t - 30))" "$((t - 20))" "$((t - 10))" > "$T/cl4/run/ribbon-shell.starts"
if run_shell cl4 plain; then
	show cl4; fail "crash loop, fourth start: the shell did not give up"
elif grep -q 'giving up' "$T/cl4/state/ribbon/shell.log" 2>/dev/null && ! grep -q 'state panel=' "$T/cl4.out"; then
	ok "crash loop, fourth start: gives up with status 1, logged"
else
	show cl4; fail "crash loop, fourth start: no give-up line in shell.log"
fi

[ "$fails" -eq 0 ] || { echo "shell fault: $fails failure(s)"; exit 1; }
