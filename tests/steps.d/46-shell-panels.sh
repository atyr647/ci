#!/bin/sh
# The bar's panels over the system bus and the shell's pipes (U50b, shell/controls.tcl, status.tcl, bar.tcl):
# tests/shell-panels.tcl under xvfb, on a private system bus with the NetworkManager stand-in (tests/fixtures/nm.tcl)
# and the BlueZ stand-in (tests/fixtures/bluez.tcl). A stub wpctl sleeps 3 s and logs its calls, so the event loop is
# checked while a volume read or step is pending. Skips without wish8.6, xvfb-run or dbus-daemon.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1 || ! command -v dbus-daemon >/dev/null 2>&1; then
	echo "  skip shell panels (no wish8.6 / xvfb-run / dbus-daemon)"
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
mkdir -p "$T/bin" "$T/stubs" "$T/h" "$T/c" "$T/s" "$T/r" "$T/cfg"
repo=$(pwd)
D=$repo/srcpkgs/ribbon-desktop/files

# the wpctl stub: every call is logged; the call sleeps 3 s, as a slow PipeWire would
cat >"$T/bin/wpctl" <<'SH2'
#!/bin/sh
echo "wpctl $*" >>"$PANEL_STUBS/calls"
sleep 3
case "$1" in
	get-volume) echo "Volume: 0.40" ;;
esac
exit 0
SH2
chmod +x "$T/bin/wpctl"

# the private system bus, then the two stand-ins on it
timeout 120 dbus-daemon --nofork --nopidfile --session --print-address=3 3>"$T/bus.addr" 2>"$T/daemon.log" &
pids="$pids $!"
i=0
while [ ! -s "$T/bus.addr" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
[ -s "$T/bus.addr" ] || { cat "$T/daemon.log"; echo "  FAIL shell panels: dbus-daemon did not start"; exit 1; }
DBUS_SYSTEM_BUS_ADDRESS=$(cat "$T/bus.addr")
export DBUS_SYSTEM_BUS_ADDRESS
NM_LOG=$T/nm.log
BLUEZ_LOG=$T/bluez.log
export NM_LOG BLUEZ_LOG
: >"$NM_LOG"
: >"$BLUEZ_LOG"
# the stand-ins are tclsh scripts that load ribbon::dbus, which needs unix_extra: built here when tclsh lacks it
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip shell panels (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}"
export TCLLIBPATH
for fixture in nm bluez; do
	timeout 120 tclsh8.6 "$repo/tests/fixtures/$fixture.tcl" >"$T/$fixture.out" 2>&1 &
	pids="$pids $!"
	i=0
	while ! grep -q ready "$T/$fixture.out" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
	grep -q ready "$T/$fixture.out" 2>/dev/null || { cat "$T/$fixture.out"; echo "  FAIL shell panels: the $fixture stand-in did not start"; exit 1; }
done

if HOME=$T/h XDG_CACHE_HOME=$T/c XDG_STATE_HOME=$T/s XDG_RUNTIME_DIR=$T/r XDG_CONFIG_HOME=$T/cfg \
	PATH="$T/bin:$PATH" PANEL_STUBS=$T/stubs DBUS_SESSION_BUS_ADDRESS=unix:path=$T/none \
	RIBBON_SHELL_TEST=tests/shell-panels.tcl timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" \
	wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/shell/main.tcl -name ribbon-shell >"$T/out" 2>&1 &&
	! grep -q '  FAIL' "$T/out"; then
	sed -n 's/^  ok   /  ok   panels: /p' "$T/out"
	grep -q 'all panel checks passed' "$T/out" || { echo "  FAIL shell panels: no pass line"; cat "$T/out"; exit 1; }
else
	sed 's/^/       /' "$T/out"
	echo "  FAIL shell panels (tests/shell-panels.tcl)"
	exit 1
fi
