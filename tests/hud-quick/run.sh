#!/bin/sh
# tests/hud-quick/run.sh - the Game HUD's quick menu (apps/hud/quick.tcl, boards HUD-Quick-*):
#   1. the model, the keys, the services (stand-ins: tests/hud-quick/fakes.sh, power-profiles-daemon on a private bus)
#      and the geometry against the boards' DOM boxes: tests/hud-quick.tcl under xvfb
#   2. the real daemon and ribbon-hud-surface under a headless labwc: tests/hud-quick/native.sh
# Needs wish8.6 and xvfb-run (else skips); power-profiles-daemon is stood in for when dbus-daemon and unix_extra are here.
set -u
cd "$(dirname "$0")/../.." || exit 1
for t in wish8.6 xvfb-run; do command -v $t >/dev/null 2>&1 || { echo "  skip HUD quick menu (no $t)"; exit 0; }; done
T=$(mktemp -d "${TMPDIR:-/tmp}/hudquick.XXXXXX") || exit 1
DP=
cleanup() { [ -n "$DP" ] && kill "$DP" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
sh tests/hud-quick/fakes.sh "$T/q"
fail=0
SYS=
if command -v dbus-daemon >/dev/null 2>&1 && echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	dbus-daemon --session --nofork --print-address=3 --print-pid=4 3>"$T/addr" 4>"$T/pid" &
	i=0; while [ ! -s "$T/addr" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
	DP=$(cat "$T/pid" 2>/dev/null); SYS=$(head -n1 "$T/addr")
fi
if env QFAKE="$T/q" ${SYS:+DBUS_SYSTEM_BUS_ADDRESS="$SYS"} TMPDIR="$T" xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 tests/hud-quick.tcl >"$T/out" 2>&1; then
	echo "  ok   HUD quick menu: model, keys, services and geometry ($(grep -c '^  ok' "$T/out") checks)"
else
	echo "  FAIL HUD quick menu: model, keys, services and geometry"; grep -v '^  ok' "$T/out" | sed 's/^/       /'; fail=1
fi
grep '^  note' "$T/out" | sed 's/^/     /'
if [ -f tests/hud-quick/native.sh ]; then sh tests/hud-quick/native.sh || fail=1; fi
exit $fail
