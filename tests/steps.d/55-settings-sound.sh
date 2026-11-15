#!/bin/sh
# Settings → Sound (the backend, apps/settings/sound.tcl): the device, stream and Bluetooth-card model read from pactl,
# the actions (volume, balance, mute, default, card profile), the subscription, the input level, and the settings file,
# against the fake pactl and parec (tests/fixtures/fake-pactl, fake-parec) with no display (tests/settings-sound.tcl).
# Skips without tclsh8.6. NOT covered: a real PipeWire, real devices, the page itself.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip Settings → Sound (no tclsh8.6)"; exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
repo=$(pwd)
D=$repo/srcpkgs/ribbon-desktop/files
mkdir -p "$T/state" "$T/cfg" "$T/home"
cp "$repo"/tests/fixtures/pactl-json/*.json "$T/state/"
st=0
if env HOME="$T/home" XDG_CONFIG_HOME="$T/cfg" \
	RIBBON_PACTL="$repo/tests/fixtures/fake-pactl" RIBBON_PAREC="$repo/tests/fixtures/fake-parec" \
	PACTL_STATE="$T/state" PACTL_LOG="$T/pactl.log" \
	timeout -k 5 150 tclsh8.6 tests/settings-sound.tcl "$D" >"$T/sound.out" 2>&1; then
	echo "  ok   Settings → Sound: the backend against the pactl stand-in"
else
	cat "$T/sound.out"
	echo "  FAIL Settings → Sound: the backend against the pactl stand-in"
	st=1
fi
exit $st
