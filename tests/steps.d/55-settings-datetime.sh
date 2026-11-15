#!/bin/sh
# Settings → Date and time (the backend, apps/settings/datetime.tcl) with no display (tests/settings-datetime.tcl): the
# display choices' file (clock.conf, atomic, damaged, unwritable), the shell told through its FIFO, the zone list from
# tzdata.zi / zone1970.tab / zone.tab / the directory, the zone from /etc/localtime and its fallbacks, times in the zone
# and in a new zone within the same process, the calendar's months, the time service's state (dinit's mark, a dinitctl
# stand-in), and every change through a pkexec stand-in and the REAL ribbon-time-helper on a fake root (a cancelled
# prompt, a refusal, the event loop free while it waits); then the real tzdata of this machine. Skips without tclsh8.6
# or the zone files. NOT covered: a real polkit prompt, a real dinit, the page itself (57-settings-datetime-page.sh).
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip Settings → Date and time (no tclsh8.6)"; exit 0
fi
if [ ! -f /usr/share/zoneinfo/Europe/London ] || [ ! -f /usr/share/zoneinfo/Asia/Tokyo ] || [ ! -f /usr/share/zoneinfo/UTC ]; then
	echo "  skip Settings → Date and time (no zone files in /usr/share/zoneinfo)"; exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
D=$PWD/srcpkgs/ribbon-desktop/files
mkdir -p "$T/home" "$T/cfg" "$T/run" "$T/tmp"
if env -u TZ HOME="$T/home" XDG_CONFIG_HOME="$T/cfg" XDG_RUNTIME_DIR="$T/run" TMPDIR="$T/tmp" \
	timeout -k 5 150 tclsh8.6 -encoding utf-8 tests/settings-datetime.tcl "$D" >"$T/dt.out" 2>&1; then
	grep -v '^  ok ' "$T/dt.out" | grep -v '^date and time: all checks passed$' | sed 's/^/     /'
	echo "  ok   Settings → Date and time: the backend on a fake root, through the real helper ($(grep -c '^  ok ' "$T/dt.out") checks)"
else
	grep -v '^  ok ' "$T/dt.out" | sed 's/^/       /'
	echo "  FAIL Settings → Date and time: the backend"
	exit 1
fi
