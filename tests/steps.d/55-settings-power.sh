#!/bin/sh
# Settings → Power (U14): the UPower and power-profiles-daemon client (apps/settings/power.tcl) against the stand-ins
# (tests/fixtures/upower.tcl, tests/fixtures/ppd.tcl) on a private system bus: the battery read, the power mode set and a
# refused name, OnBattery and the four idle states, the swayidle restart on a change (a swayidle stub on PATH), the
# settings file, and the root settings read from a fake root. Then the page under xvfb (tests/settings-power-scene.tcl).
# Skips without tclsh8.6 or dbus-daemon. NOT covered: a real UPower or battery, lid, charge limit, polkit (INTEGRATION REQUEST).
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1 || ! command -v dbus-daemon >/dev/null 2>&1; then
	echo "  skip Settings → Power (no tclsh8.6 / dbus-daemon)"; exit 0
fi
T=$(mktemp -d)
pids=
cleanup() {
	for p in $pids; do kill "$p" 2>/dev/null; done
	[ -f "$T/pidfile" ] && kill "$(cat "$T/pidfile")" 2>/dev/null
	rm -rf "${T:?}"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip Settings → Power (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
repo=$(pwd)
D=$repo/srcpkgs/ribbon-desktop/files
mkdir -p "$T/home" "$T/cfg" "$T/root" "$T/bin"
timeout 300 dbus-daemon --nofork --nopidfile --session --print-address=3 3>"$T/bus.addr" 2>"$T/daemon.log" &
pids="$pids $!"
i=0
while [ ! -s "$T/bus.addr" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
[ -s "$T/bus.addr" ] || { cat "$T/daemon.log"; echo "  FAIL dbus-daemon did not start"; exit 1; }
DBUS_SYSTEM_BUS_ADDRESS=$(cat "$T/bus.addr")
export DBUS_SYSTEM_BUS_ADDRESS
TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}"
export TCLLIBPATH

# the stand-ins: UPower and power-profiles-daemon, each logging its changes
UPOWER_LOG=$T/upower.log; export UPOWER_LOG; : >"$UPOWER_LOG"
PPD_LOG=$T/ppd.log; export PPD_LOG; : >"$PPD_LOG"
timeout 300 tclsh8.6 "$repo/tests/fixtures/upower.tcl" >"$T/upower.out" 2>&1 &
pids="$pids $!"
timeout 300 tclsh8.6 "$repo/tests/fixtures/ppd.tcl" >"$T/ppd.out" 2>&1 &
pids="$pids $!"
for f in upower ppd; do
	i=0
	while ! grep -q ready "$T/$f.out" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
	grep -q ready "$T/$f.out" 2>/dev/null || { cat "$T/$f.out"; echo "  FAIL the $f stand-in did not start"; exit 1; }
done

# a swayidle stub first on PATH: it logs its arguments and runs on (the daemon's pid file names it)
SWAYIDLE_LOG=$T/swayidle.log; export SWAYIDLE_LOG; : >"$SWAYIDLE_LOG"
# (a copy of sleep named swayidle: the daemon only trusts a pid whose process is called swayidle)
mkdir -p "$T/real"; cp "$(command -v sleep)" "$T/real/swayidle"
cat >"$T/bin/swayidle" <<STUB
#!/bin/sh
echo "\$*" >> "\$SWAYIDLE_LOG"
exec "$T/real/swayidle" 600
STUB
chmod +x "$T/bin/swayidle"
XDG_CONFIG_HOME=$T/cfg; export XDG_CONFIG_HOME
XDG_RUNTIME_DIR=$T; export XDG_RUNTIME_DIR
RIBBON_POWER_ROOT=$T/root; export RIBBON_POWER_ROOT
# the helper side (U14b): a stub pkexec that logs and runs the real ribbon-power-helper on the fake root, a wlopm stub
WLOPM_LOG=$T/wlopm.log; export WLOPM_LOG; : >"$WLOPM_LOG"
printf '#!/bin/sh\necho "$*" >> "$WLOPM_LOG"\n' >"$T/bin/wlopm"
PKEXEC_LOG=$T/pkexec.log; export PKEXEC_LOG; : >"$PKEXEC_LOG"
PKEXEC_MODE=$T/pkexec.mode; export PKEXEC_MODE; echo ok >"$PKEXEC_MODE"
cat >"$T/bin/pkexec-stub" <<'STUB'
#!/bin/sh
echo "$*" >> "$PKEXEC_LOG"
case $(cat "$PKEXEC_MODE") in
	cancel) exit 126 ;;
	deny) echo "Error: not authorised" >&2; exit 127 ;;
esac
exec "$@"
STUB
chmod +x "$T/bin/wlopm" "$T/bin/pkexec-stub"
RIBBON_POWER_TEST=1; export RIBBON_POWER_TEST
RIBBON_POWER_PKEXEC=$T/bin/pkexec-stub; export RIBBON_POWER_PKEXEC
RIBBON_POWER_HELPER=$D/apps/settings/bin/ribbon-power-helper; export RIBBON_POWER_HELPER
PATH="$T/bin:$PATH"; export PATH

st=0
timeout -k 5 120 tclsh8.6 tests/settings-power.tcl "$D" >"$T/client.out" 2>&1 || st=1
sed 's/^/       /' "$T/client.out" 2>/dev/null
if [ "$st" -eq 0 ]; then
	echo "  ok   Settings → Power: the client against the stand-ins"
else
	echo "  FAIL Settings → Power: the client against the stand-ins"
fi

# the page, under xvfb, in the Settings app (the scene drives it through its hit areas)
if command -v wish8.6 >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1; then
	: >"$UPOWER_LOG"; : >"$PPD_LOG"; : >"$SWAYIDLE_LOG"; : >"$PKEXEC_LOG"; echo ok >"$PKEXEC_MODE"
	mkdir -p "$T/cache"
	if timeout -k 5 120 env HOME="$T/home" XDG_CACHE_HOME="$T/cache" \
		RIBBON_SETTINGS_SCENE="$repo/tests/settings-power-scene.tcl" RIBBON_POWER_RESULT="$T/scene.txt" \
		xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" >"$T/scene.out" 2>&1; then
		st2=0
	else
		st2=1
	fi
	sed 's/^/       /' "$T/scene.txt" 2>/dev/null
	[ "$st2" -eq 0 ] && echo "  ok   Settings → Power: the page in its states" || { echo "  FAIL Settings → Power: the page in its states"; sed 's/^/       /' "$T/scene.out" 2>/dev/null; st=1; }
else
	echo "  skip Settings → Power page (needs wish8.6 and xvfb-run)"
fi
exit $st
