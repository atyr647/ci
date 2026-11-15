#!/bin/sh
# The idle daemon (apps/settings/power-idle.tcl): the low and critical battery warnings sent to the shell's notification
# server (shell/notifyd.tcl) as the charge falls, replaced not repeated, their actions (logind's Suspend,
# power-profiles-daemon's power-saver) and the close on mains; and the screensaver inhibitors (apps/settings/screensaver.tcl,
# started by the session bus from dbus-services/org.freedesktop.ScreenSaver.service): swayidle loses its timeouts while
# one is held and gets them back on UnInhibit or when the holder leaves the bus. tests/power-idle.tcl, on a private
# system bus (UPower, logind and PPD stood in for) and a private session bus. Skips without tclsh8.6 or dbus-daemon.
# NOT covered: a real UPower, logind or portal (xdg-desktop-portal-gtk's Inhibit fallback to this service).
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1 || ! command -v dbus-daemon >/dev/null 2>&1; then
	echo "  skip power idle daemon (no tclsh8.6 / dbus-daemon)"; exit 0
fi
T=$(mktemp -d)
pids=
cleanup() {
	for p in $pids; do kill "$p" 2>/dev/null; done
	[ -f "$T/ribbon-idle.pid" ] && kill "$(cat "$T/ribbon-idle.pid")" 2>/dev/null
	rm -rf "${T:?}"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip power idle daemon (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
repo=$(pwd)
D=$repo/srcpkgs/ribbon-desktop/files
TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}"
export TCLLIBPATH
mkdir -p "$T/cfg" "$T/root" "$T/bin" "$T/services"

# the session bus activates the screensaver service from the shipped .service file (its Exec pointed at the source tree)
tcl=$(command -v tclsh8.6)
sed "s#^Exec=.*#Exec=$tcl $D/apps/settings/screensaver.tcl#" "$D/dbus-services/org.freedesktop.ScreenSaver.service" \
	>"$T/services/org.freedesktop.ScreenSaver.service"
grep -q '^Name=org.freedesktop.ScreenSaver$' "$T/services/org.freedesktop.ScreenSaver.service" ||
	{ echo "  FAIL the .service file does not name org.freedesktop.ScreenSaver"; exit 1; }
cat >"$T/session.conf" <<XML
<busconfig><type>session</type><listen>unix:dir=$T</listen><servicedir>$T/services</servicedir>
<policy context="default"><allow send_destination="*"/><allow own="*"/><allow receive_sender="*"/></policy></busconfig>
XML
timeout 300 dbus-daemon --nofork --nopidfile --session --print-address=3 3>"$T/sys.addr" 2>"$T/sys.log" &
pids="$pids $!"
timeout 300 dbus-daemon --nofork --nopidfile --config-file="$T/session.conf" --print-address=3 3>"$T/ses.addr" 2>"$T/ses.log" &
pids="$pids $!"
for f in sys ses; do
	i=0
	while [ ! -s "$T/$f.addr" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
	[ -s "$T/$f.addr" ] || { cat "$T/$f.log"; echo "  FAIL dbus-daemon ($f) did not start"; exit 1; }
done
DBUS_SYSTEM_BUS_ADDRESS=$(cat "$T/sys.addr"); export DBUS_SYSTEM_BUS_ADDRESS
DBUS_SESSION_BUS_ADDRESS=$(cat "$T/ses.addr"); export DBUS_SESSION_BUS_ADDRESS

SWAYIDLE_LOG=$T/swayidle.log; export SWAYIDLE_LOG; : >"$SWAYIDLE_LOG"
cat >"$T/bin/swayidle" <<'STUB'
#!/bin/sh
echo "$*" >> "$SWAYIDLE_LOG"
exec sleep 600
STUB
printf '#!/bin/sh\nexit 0\n' >"$T/bin/wlopm"
chmod +x "$T/bin/swayidle" "$T/bin/wlopm"
PATH="$T/bin:$PATH"; export PATH
XDG_CONFIG_HOME=$T/cfg; export XDG_CONFIG_HOME
XDG_RUNTIME_DIR=$T; export XDG_RUNTIME_DIR
RIBBON_POWER_ROOT=$T/root; export RIBBON_POWER_ROOT

st=0
timeout -k 5 150 tclsh8.6 tests/power-idle.tcl "$D" >"$T/out" 2>&1 || st=1
sed 's/^/       /' "$T/out"
# the activated service ends with the session bus (killed with the pids above); nothing of it may be left in the log
if [ "$st" -eq 0 ]; then
	echo "  ok   power idle daemon: battery warnings and screensaver inhibitors"
else
	sed 's/^/       /' "$T/ses.log"
	echo "  FAIL power idle daemon: battery warnings and screensaver inhibitors"
fi
exit $st
