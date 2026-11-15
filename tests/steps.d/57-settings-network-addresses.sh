#!/bin/sh
# Settings → Network, the saved network's Addresses dropdown (its ipv4.method read and written with Save) and the
# sheets' text, under xvfb against the NetworkManager stand-in (tests/fixtures/nm.tcl) on a private system bus
# (tests/settings-network-addresses-scene.tcl). Skips without tclsh8.6, dbus-daemon, wish8.6 or xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1 || ! command -v dbus-daemon >/dev/null 2>&1; then
	echo "  skip Settings → Network addresses (no tclsh8.6 / dbus-daemon)"; exit 0
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
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip Settings → Network (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
repo=$(pwd)
D=$repo/srcpkgs/ribbon-desktop/files
mkdir -p "$T/home"
timeout 120 dbus-daemon --nofork --nopidfile --session --print-address=3 3>"$T/bus.addr" 2>"$T/daemon.log" &
pids="$pids $!"
i=0
while [ ! -s "$T/bus.addr" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
[ -s "$T/bus.addr" ] || { cat "$T/daemon.log"; echo "  FAIL dbus-daemon did not start"; exit 1; }
DBUS_SYSTEM_BUS_ADDRESS=$(cat "$T/bus.addr")
export DBUS_SYSTEM_BUS_ADDRESS
TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}"
export TCLLIBPATH

NM_LOG=$T/nm.log
export NM_LOG
# the stand-in is started fresh for each part: the client checks change its profiles, the page starts from the first state
start_fixture() {
	: >"$NM_LOG"
	timeout 120 tclsh8.6 "$repo/tests/fixtures/nm.tcl" >"$T/fixture.out" 2>&1 &
	fixture_pid=$!
	pids="$pids $fixture_pid"
	i=0
	while ! grep -q ready "$T/fixture.out" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
	grep -q ready "$T/fixture.out" 2>/dev/null || { cat "$T/fixture.out"; echo "  FAIL the NetworkManager stand-in did not start"; exit 1; }
}
start_fixture

if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip Settings → Network addresses (needs wish8.6 and xvfb-run)"; exit 0
fi
mkdir -p "$T/cache" "$T/cfg"
if timeout -k 5 120 env HOME="$T/home" XDG_CACHE_HOME="$T/cache" XDG_CONFIG_HOME="$T/cfg" \
	RIBBON_SETTINGS_SCENE="$repo/tests/settings-network-addresses-scene.tcl" RIBBON_NETWORK_RESULT="$T/scene.txt" ${RIBBON_NETWORK_SHOT:+RIBBON_NETWORK_SHOT="$RIBBON_NETWORK_SHOT"} \
	xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" >"$T/scene.out" 2>&1; then
	sed 's/^/  /' "$T/scene.txt"
	echo "  ok   Settings → Network: Addresses and the sheets"
else
	sed 's/^/       /' "$T/scene.out" "$T/scene.txt" 2>/dev/null
	echo "  FAIL Settings → Network: Addresses and the sheets"; exit 1
fi
