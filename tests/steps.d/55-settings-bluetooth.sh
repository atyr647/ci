#!/bin/sh
# Settings → Bluetooth (BlueZ client, apps/settings/bt.tcl): the client against the BlueZ stand-in (tests/fixtures/bluez-settings.tcl)
# on a private system bus, no display (tests/settings-bluetooth.tcl): the adapter and device reads and their order, the
# radio, scanning, connect, disconnect, trusted, forget, the passkey and confirmation pairings (answered, rejected,
# cancelled), the refused PIN and passkey requests, and the bar's battery list in bluetooth.conf. Skips without tclsh8.6
# or dbus-daemon. NOT covered: a real BlueZ, real radios, the page itself (the page's scene test).
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1 || ! command -v dbus-daemon >/dev/null 2>&1; then
	echo "  skip Settings → Bluetooth (no tclsh8.6 / dbus-daemon)"; exit 0
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
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip Settings → Bluetooth (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
repo=$(pwd)
D=$repo/srcpkgs/ribbon-desktop/files
mkdir -p "$T/cfg"
timeout 120 dbus-daemon --nofork --nopidfile --session --print-address=3 3>"$T/bus.addr" 2>"$T/daemon.log" &
pids="$pids $!"
i=0
while [ ! -s "$T/bus.addr" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
[ -s "$T/bus.addr" ] || { cat "$T/daemon.log"; echo "  FAIL dbus-daemon did not start"; exit 1; }
DBUS_SYSTEM_BUS_ADDRESS=$(cat "$T/bus.addr")
export DBUS_SYSTEM_BUS_ADDRESS
TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}"
export TCLLIBPATH
BT_LOG=$T/bluez.log
export BT_LOG
: >"$BT_LOG"
timeout 120 tclsh8.6 "$repo/tests/fixtures/bluez-settings.tcl" >"$T/fixture.out" 2>&1 &
fixture_pid=$!
pids="$pids $!"
i=0
# up to 30 s: on a loaded machine (a build running beside the suite) Tcl and the bus take a while
while ! grep -q ready "$T/fixture.out" 2>/dev/null && [ $i -lt 600 ]; do
	kill -0 "$fixture_pid" 2>/dev/null || break
	sleep 0.05; i=$((i + 1))
done
grep -q ready "$T/fixture.out" 2>/dev/null || { cat "$T/fixture.out"; echo "  FAIL the BlueZ stand-in did not start"; exit 1; }

st=0
timeout -k 5 120 env XDG_CONFIG_HOME="$T/cfg" HOME="$T" tclsh8.6 tests/settings-bluetooth.tcl "$D" || st=1
if [ "$st" -eq 0 ]; then
	echo "  ok   Settings → Bluetooth: the client against the BlueZ stand-in"
else
	echo "  FAIL Settings → Bluetooth: the client against the BlueZ stand-in"
	sed 's/^/       /' "$T/fixture.out" 2>/dev/null
fi
exit $st
