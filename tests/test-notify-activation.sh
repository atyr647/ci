#!/bin/sh
# A notification sent before the shell owns org.freedesktop.Notifications is held by the bus (the session service
# file starts ribbon-notify-wait) and delivered once a server takes the name; with no server it fails after the wait.
set -u
cd "$(dirname "$0")/.." || exit 1
for t in dbus-daemon dbus-send gdbus tclsh8.6; do command -v $t >/dev/null 2>&1 || { echo "  skip notify activation (no $t)"; exit 0; }; done
T=$(mktemp -d); trap 'kill $BUS 2>/dev/null; rm -rf "$T"' EXIT
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	mkdir -p "$T/ux"; make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >/dev/null 2>&1 || { echo "  skip notify activation (unix_extra does not build)"; exit 0; }
	ux=$T/ux
fi
F=$PWD/srcpkgs/ribbon-desktop/files
mkdir -p "$T/services"
sed "s#^Exec=.*#Exec=$F/bin/ribbon-notify-wait#" "$F/dbus-services/org.freedesktop.Notifications.service" > "$T/services/org.freedesktop.Notifications.service"
cat > "$T/bus.conf" <<XML
<busconfig><type>session</type><listen>unix:dir=$T</listen><servicedir>$T/services</servicedir>
<policy context="default"><allow send_destination="*"/><allow own="*"/><allow receive_sender="*"/><allow eavesdrop="true"/></policy></busconfig>
XML
HOME=$T; export HOME
dbus-daemon --nofork --nopidfile --config-file="$T/bus.conf" --print-address=3 3>"$T/addr" 2>"$T/daemon.log" & BUS=$!
i=0; while [ ! -s "$T/addr" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
DBUS_SESSION_BUS_ADDRESS=$(cat "$T/addr"); export DBUS_SESSION_BUS_ADDRESS
TCLLIBPATH="${ux:+$ux}${TCLLIBPATH:+${ux:+ }$TCLLIBPATH}"; export TCLLIBPATH
fails=0
ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
send() { gdbus call --session --timeout 20 --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
	--method org.freedesktop.Notifications.Notify early 0 "" "$1" body '[]' '{}' 5000; }

# 1. sent first, server two seconds later: delivered
send "before the shell" >"$T/send1.out" 2>&1 & S1=$!
sleep 2
cat > "$T/server.tcl" <<TCL
lappend auto_path $F
package require ribbon::dbus
source $F/shell/notifyd.tcl
set b [ribbon::dbus::connect session]
proc show {n} { set f [open $T/got a]; puts \$f [dict get \$n summary]; close \$f }
notifyd::start \$b -show show
after 6000 exit
vwait forever
TCL
tclsh8.6 "$T/server.tcl" >"$T/server.out" 2>&1 & SV=$!
wait $S1 && grep -q "uint32" "$T/send1.out" && ok "a Notify sent before the server is answered once it starts" || { bad "the early Notify was not answered"; cat "$T/send1.out" "$T/server.out"; }
grep -q 'before the shell' "$T/got" 2>/dev/null && ok "the server received that notification" || bad "the server did not receive the early notification"
send "with the server up" >/dev/null 2>&1 && ok "a Notify with the server up still works" || bad "Notify with the server up"
wait $SV 2>/dev/null

# 2. no server at all: the helper gives up after its wait, and the sender gets an error
t0=$(date +%s)
if send "nobody home" >"$T/send2.out" 2>&1; then bad "a Notify with no server succeeded"; else
	t1=$(date +%s); d=$((t1 - t0))
	[ $d -ge 9 ] && [ $d -le 16 ] && ok "with no server the call fails after the helper's wait (${d} s)" || bad "no-server wait was ${d} s"
fi
[ $fails -eq 0 ] && echo "notify activation: all checks passed"
[ $fails -eq 0 ]
