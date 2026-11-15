#!/bin/sh
# Polkit agent core (U15, apps/polkit): tests/polkit-agent.tcl drives the agent against a fake polkitd and a
# fake polkit-agent-helper-1 on a private bus (success, retry, cancels, queueing, the picker, callers other
# than polkitd, polkitd restarting, failures, no password leaking). Then ribbon-polkit's own main.tcl with
# the real card runs under xvfb (tests/polkit-card.tcl). Skips without tclsh8.6, dbus-daemon, or
# unix_extra (built from srcpkgs/tcl-unix-extra when Tcl headers are there). NOT covered: real PAM, the
# setuid helper, a real polkitd and elogind (design/handoff/u15.md).
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1 || ! command -v dbus-daemon >/dev/null 2>&1; then
	echo "  skip polkit agent (no tclsh8.6 / dbus-daemon)"
	exit 0
fi
T=$(mktemp -d)
pids=
cleanup() {
	for p in $pids; do kill "$p" 2>/dev/null; done
	rm -rf "${T:?}"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip polkit agent (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
repo=$(pwd)
HOME=$T
export HOME
mkdir -p "$T/w"
timeout 300 dbus-daemon --nofork --nopidfile --session --print-address=3 3>"$T/bus.addr" 2>"$T/daemon.log" &
pids="$pids $!"
i=0
while [ ! -s "$T/bus.addr" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
[ -s "$T/bus.addr" ] || { cat "$T/daemon.log"; echo "  FAIL dbus-daemon did not start"; exit 1; }

# the bus stands in for the system bus; the fixtures and the agent find it the usual way
DBUS_SYSTEM_BUS_ADDRESS=$(cat "$T/bus.addr")
TCLLIBPATH="${ux:+$ux }$repo/srcpkgs/ribbon-desktop/files${TCLLIBPATH:+ $TCLLIBPATH}"
export DBUS_SYSTEM_BUS_ADDRESS TCLLIBPATH
# the stand-in for polkit-agent-helper-1. The agent gives its child a clean environment, so the wrapper
# supplies what the real helper has by itself (the system bus socket, here the private bus)
cat >"$T/helper.sh" <<EOS
#!/bin/sh
POLKIT_FIX=$T DBUS_SYSTEM_BUS_ADDRESS='$DBUS_SYSTEM_BUS_ADDRESS' TCLLIBPATH='$TCLLIBPATH' exec tclsh8.6 $repo/tests/fixtures/polkit-helper.tcl "\$@"
EOS
chmod +x "$T/helper.sh"
# the stand-in for ribbon-polkit-keys: it needs unix_extra to receive the pipe the agent passes it
cat >"$T/keys.sh" <<EOS
#!/bin/sh
POLKIT_FIX=$T TCLLIBPATH='$TCLLIBPATH' exec tclsh8.6 $repo/tests/fixtures/polkit-keys.tcl "\$@" 3<&0
EOS
chmod +x "$T/keys.sh"

st=0
POLKIT_T=$T timeout -k 5 150 tclsh8.6 tests/polkit-agent.tcl || st=1

if command -v xvfb-run >/dev/null 2>&1 && command -v wish8.6 >/dev/null 2>&1; then
	rm -f "$T/helper.log"
	POLKIT_T=$T timeout -k 5 150 tclsh8.6 tests/polkit-card.tcl || st=1
else
	echo "  skip ribbon-polkit with the card (no xvfb-run / wish8.6)"
fi
if [ "$st" -eq 0 ]; then echo "  ok   polkit agent core"; else echo "  FAIL polkit agent core"; fi
exit $st
