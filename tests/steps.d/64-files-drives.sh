#!/bin/sh
# Ribbon Files' DRIVES rows and free space (shell/files-drives.tcl): tests/files-drives.tcl under xvfb, on a private
# system bus with the UDisks2 stand-in (tests/fixtures/udisks.tcl), and a df stub on PATH that sleeps 3 s and logs
# its calls, so a draw that waited for df would show. Then once with no UDisks2 (the rows are df's).
# Skips without wish8.6, xvfb-run or dbus-daemon.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1 || ! command -v dbus-daemon >/dev/null 2>&1; then
	echo "  skip files drives (no wish8.6 / xvfb-run / dbus-daemon)"
	exit 0
fi
T=$(mktemp -d)
pids=
cleanup() {
	for p in $pids; do kill "$p" 2>/dev/null; done
	rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
repo=$(pwd)
D=$repo/srcpkgs/ribbon-desktop/files
mkdir -p "$T/bin" "$T/state" "$T/mnt/Backup"
UDISKS_MNT=$T/mnt/Backup
UDISKS_STATE=$T/state
UDISKS_LOG=$T/udisks.log
DF_LOG=$T/df.log
DF_SLEEP=3
export UDISKS_MNT UDISKS_STATE UDISKS_LOG DF_LOG DF_SLEEP
: >"$UDISKS_LOG"

# df: GNU df's two outputs Files asks for, after a sleep; the stick is listed once the stand-in has mounted it
cat >"$T/bin/df" <<'SH'
#!/bin/sh
echo "df $*" >>"$DF_LOG"
sleep "$DF_SLEEP"
case "$*" in
*used,size,target*)
	echo "     Used     Size Mounted on"
	echo "50000000000 100000000000 /"
	echo "10000000000 20000000000 /mnt/games/ssd"
	echo "1000000 500000000 /boot/efi"
	[ -e "$UDISKS_STATE/mounted" ] && echo "8000000000 32000000000 $UDISKS_MNT"
	;;
*avail,target*)
	echo "    Avail Mounted on"
	echo "123456789 /"
	;;
esac
exit 0
SH
chmod +x "$T/bin/df"

# the stand-in is a tclsh script that loads ribbon::dbus, which needs unix_extra: built here when tclsh lacks it
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip files drives (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}"
export TCLLIBPATH

timeout 300 dbus-daemon --nofork --nopidfile --session --print-address=3 3>"$T/bus.addr" 2>"$T/daemon.log" &
pids="$pids $!"
i=0
while [ ! -s "$T/bus.addr" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
[ -s "$T/bus.addr" ] || { cat "$T/daemon.log"; echo "  FAIL files drives: dbus-daemon did not start"; exit 1; }
bus=$(cat "$T/bus.addr")

timeout 300 env DBUS_SYSTEM_BUS_ADDRESS="$bus" tclsh8.6 "$repo/tests/fixtures/udisks.tcl" >"$T/udisks.out" 2>&1 &
pids="$pids $!"
i=0
while ! grep -q ready "$T/udisks.out" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
grep -q ready "$T/udisks.out" 2>/dev/null || { cat "$T/udisks.out"; echo "  FAIL files drives: the UDisks2 stand-in did not start"; exit 1; }

fail=0
run_mode() {  # MODE SYSTEM-BUS
	m=$1
	h=$T/home-$m; mkdir -p "$h/c" "$h/s" "$h/r" "$h/cfg"
	: >"$DF_LOG"
	if env HOME="$h" XDG_CACHE_HOME="$h/c" XDG_STATE_HOME="$h/s" XDG_RUNTIME_DIR="$h/r" XDG_CONFIG_HOME="$h/cfg" \
		PATH="$T/bin:$PATH" DBUS_SYSTEM_BUS_ADDRESS="$2" DBUS_SESSION_BUS_ADDRESS=unix:path=$T/none \
		FILES_DRIVES_MODE=$m RIBBON_SHELL_TEST=tests/files-drives.tcl timeout -k 5 150 xvfb-run -a -s "-screen 0 1440x900x24" \
		wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/shell/main.tcl -name ribbon-shell >"$T/out-$m" 2>&1 &&
		grep -q 'all drive checks passed' "$T/out-$m"; then
		sed -n "s/^  ok   /  ok   files drives ($m): /p" "$T/out-$m"
	else
		sed 's/^/       /' "$T/out-$m"
		echo "  FAIL files drives ($m) (tests/files-drives.tcl)"
		fail=1
	fi
}
run_mode udisks "$bus"
rm -f "$UDISKS_STATE/mounted"
run_mode nobus "unix:path=$T/no-bus"
[ $fail = 0 ] && echo "files drives: all checks passed"
exit $fail
