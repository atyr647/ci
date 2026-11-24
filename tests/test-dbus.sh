#!/bin/sh
# ribbon::dbus (srcpkgs/ribbon-desktop/files/dbus) against private buses:
# a dbus-daemon --session of its own, and one on an abstract socket that
# only takes ANONYMOUS. tests/dbus.tcl does the checks; it runs in wish
# under xvfb-run when it can (the shell's event loop), else in tclsh.
# unix_extra is built from srcpkgs/tcl-unix-extra unless it is installed.
# Every program run here has a hard time limit, and the buses are stopped
# on any exit: a stuck check fails, it never hangs the suite.
set -u
cd "$(dirname "$0")/.." || exit 1
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
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip ribbon::dbus (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi

# a home of its own: the buses' DBUS_COOKIE_SHA1 keyring is made there, and
# gdbus and notify-send write nothing to the real one
HOME=$T
export HOME
bus() { # bus NAME DBUS-DAEMON-ARGS...: start a bus, wait for its address
	name=$1; shift
	# (timeout: the bus ends even if this script is killed outright)
	timeout 600 dbus-daemon --nofork --nopidfile --print-address=3 "$@" 3>"$T/$name.addr" 2>>"$T/daemon.log" &
	pids="$pids $!"
	i=0
	while [ ! -s "$T/$name.addr" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
	[ -s "$T/$name.addr" ] || { cat "$T/daemon.log"; echo "  FAIL dbus-daemon ($name) did not start"; exit 1; }
}
bus session --session
cat >"$T/anon.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>custom</type>
  <listen>unix:abstract=ribbon-dbus-test-$$</listen>
  <auth>ANONYMOUS</auth>
  <allow_anonymous/>
  <policy context="default"><allow send_destination="*"/><allow own="*"/><allow receive_sender="*"/></policy>
</busconfig>
EOF
bus anon --config-file="$T/anon.conf"
cat >"$T/tcp.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>custom</type>
  <listen>tcp:host=127.0.0.1,port=0</listen>
  <listen>nonce-tcp:host=127.0.0.1,port=0</listen>
  <auth>DBUS_COOKIE_SHA1</auth>
  <!-- where the kernel has AppArmor with D-Bus mediation (Ubuntu, so CI), dbus-daemon asks every new
       connection for its peer's label, which a TCP socket has none of, and drops it before AUTH -->
  <apparmor mode="disabled"/>
  <policy context="default"><allow send_destination="*"/><allow own="*"/><allow receive_sender="*"/></policy>
</busconfig>
EOF
bus tcp --config-file="$T/tcp.conf"

DBUS_SESSION_BUS_ADDRESS=$(cat "$T/session.addr")
RIBBON_DBUS_ANON=$(cat "$T/anon.addr")
RIBBON_DBUS_TCP=$(cat "$T/tcp.addr")
TCLLIBPATH="${ux:+$ux}${TCLLIBPATH:+${ux:+ }$TCLLIBPATH}"
export DBUS_SESSION_BUS_ADDRESS RIBBON_DBUS_ANON RIBBON_DBUS_TCP TCLLIBPATH
st=0
if command -v xvfb-run >/dev/null 2>&1 && command -v wish8.6 >/dev/null 2>&1; then
	xvfb-run -a -s "-screen 0 640x480x24" timeout -k 5 150 wish8.6 tests/dbus.tcl || st=1
	# the shell itself: no D-Bus before its notification server starts, which loads
	# ribbon::dbus through shell::bus (shell/mod-notify.tcl, shell/notifyd.tcl)
	echo "the shell"
	XDG_RUNTIME_DIR=$T RIBBON_SHELL_TEST=tests/shell-dbus.tcl xvfb-run -a -s "-screen 0 1440x900x24" \
		timeout -k 5 60 wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/shell/main.tcl -name ribbon-shell 2>"$T/shell.err" || {
		cat "$T/shell.err"; echo "  FAIL the shell's D-Bus loading"; st=1
	}
else
	timeout -k 5 150 tclsh8.6 tests/dbus.tcl || st=1
	echo "  skip the shell's D-Bus loading (no xvfb-run / wish8.6)"
fi
exit $st
