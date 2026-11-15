#!/bin/sh
# Notifications over the bus, end to end: the real shell (under xvfb) on a private session bus, and plain clients
# (gdbus, dbus-send). A Notify that carries actions is answered with its id; clicking its keycap sends ActionInvoked
# and NotificationClosed (reason 2); CloseNotification closes with reason 3; an expired one closes with reason 1.
# The entry the popup shows has its markup taken out, its app's icon from the desktop-entry hint, its own picture
# from image-path, and the progress words a sender gives. Skips without the tools.
set -u
cd "$(dirname "$0")/.." || exit 1
for t in dbus-daemon dbus-send gdbus tclsh8.6 wish8.6 xvfb-run; do command -v $t >/dev/null 2>&1 || { echo "  skip notifications on the bus (no $t)"; exit 0; }; done
T=$(mktemp -d); trap 'kill $SH $MON $BUS 2>/dev/null; rm -rf "$T"' EXIT
SH=; MON=; BUS=
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	mkdir -p "$T/ux"; make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >/dev/null 2>&1 || { echo "  skip notifications on the bus (unix_extra does not build)"; exit 0; }
	ux=$T/ux
fi
cat > "$T/bus.conf" <<XML
<busconfig><type>session</type><listen>unix:dir=$T</listen>
<policy context="default"><allow send_destination="*"/><allow own="*"/><allow receive_sender="*"/><allow eavesdrop="true"/></policy></busconfig>
XML
mkdir -p "$T/h" "$T/c" "$T/s" "$T/r"
dbus-daemon --nofork --nopidfile --config-file="$T/bus.conf" --print-address=3 3>"$T/addr" 2>"$T/daemon.log" & BUS=$!
i=0; while [ ! -s "$T/addr" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
DBUS_SESSION_BUS_ADDRESS=$(cat "$T/addr"); export DBUS_SESSION_BUS_ADDRESS
TCLLIBPATH="${ux:+$ux}${TCLLIBPATH:+${ux:+ }$TCLLIBPATH}"; export TCLLIBPATH
fails=0
ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
# wait (at most $2 tenths of a second) until file $3 has a line matching $1
until_line() { i=0; while [ $i -lt "$2" ]; do grep -q -- "$1" "$3" 2>/dev/null && return 0; sleep 0.1; i=$((i+1)); done; return 1; }

# a paplay that only says it ran (the alert sound)
mkdir -p "$T/bin"; printf '#!/bin/sh\necho played >> %s/sounds\n' "$T" > "$T/bin/paplay"; chmod +x "$T/bin/paplay"
PATH=$T/bin:$PATH HOME=$T/h XDG_CACHE_HOME=$T/c XDG_STATE_HOME=$T/s XDG_RUNTIME_DIR=$T/r NOTIFY_BUS_LOG=$T/log \
	RIBBON_SHELL_TEST=tests/shell-notify-bus.tcl timeout -k 5 60 xvfb-run -a -s "-screen 0 1440x900x24" \
	wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/shell/main.tcl -name ribbon-shell >"$T/shell.out" 2>&1 & SH=$!
until_line "status primary" 150 "$T/log" || { bad "the shell did not take org.freedesktop.Notifications"; cat "$T/shell.out" "$T/log" 2>/dev/null | sed 's/^/       /'; exit 1; }
gdbus monitor --session --dest org.freedesktop.Notifications >"$T/mon" 2>&1 & MON=$!
# gdbus prints this after the round trip that follows its AddMatch: from then on no signal is missed
until_line "is owned by" 50 "$T/mon" || { bad "gdbus monitor did not start"; exit 1; }
notify() { gdbus call --session --timeout 5 --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
	--method org.freedesktop.Notifications.Notify "$@" 2>&1; }

# 1. actions through gdbus: the reply, then the click's two signals
r=$(notify Firefox 0 "" "Download complete" "<b>ribbon-0.3.iso</b> &amp; <i>notes</i>" "['default','Open','show','Show in Files']" "{'desktop-entry': <'firefox'>}" 0)
id=$(echo "$r" | sed -n 's/^(uint32 \([0-9]*\),)$/\1/p')
[ -n "$id" ] && ok "a Notify with actions is answered with its id ($id)" || bad "a Notify with actions got no id: $r"
until_line "ActionInvoked (uint32 ${id:-0}, 'default')" 50 "$T/mon" && ok "clicking the keycap sends ActionInvoked with the action's key" || bad "no ActionInvoked for $id"
until_line "NotificationClosed (uint32 ${id:-0}, uint32 2)" 50 "$T/mon" && ok "and NotificationClosed with reason 2 (dismissed by the person)" || bad "no NotificationClosed reason 2 for $id"
grep -q "arrived ${id:-0} app=Firefox summary=Download complete body=ribbon-0.3.iso & notes icon=line globe" "$T/log" &&
	ok "the entry has its markup taken out and the app's icon from its desktop entry" || bad "the entry as shown: $(grep "arrived ${id:-0} " "$T/log")"

# 2. dbus-send cannot write the hints' a{sv} (it has no variant inside a dict), so its Notify has the wrong
# signature: that must be refused at once, not left to time out (the NoReply the handoff notes saw)
t0=$(date +%s)
r=$(dbus-send --session --print-reply --reply-timeout=8000 --dest=org.freedesktop.Notifications /org/freedesktop/Notifications \
	org.freedesktop.Notifications.Notify string:Steam uint32:0 string: string:Ludo string:"you up?" \
	array:string:default,Reply dict:string:string:a,b int32:0 2>&1)
t1=$(date +%s)
case $r in
	*NoReply*|*"did not receive a reply"*) bad "a Notify with a wrong signature is left without an answer ($((t1 - t0)) s): $r";;
	*Error*) ok "a Notify with a wrong signature (dbus-send's a{ss} hints) is refused at once";;
	*) bad "a Notify with a wrong signature: $r";;
esac

# 3. CloseNotification: reason 3
r=$(notify Files 0 "" "leave me" "" "['cancel','Cancel']" "{'value': <int32 35>, 'x-ribbon-progress-text': <'1.2 of 3.4 GB'>}" 0)
id3=$(echo "$r" | sed -n 's/^(uint32 \([0-9]*\),)$/\1/p')
until_line "arrived ${id3:-0} .*icon=line folder value=35 done=1.2 of 3.4 GB" 30 "$T/log" && ok "a progress entry shows the sender's own words under its bar" || bad "the progress entry: $(grep "arrived ${id3:-0} " "$T/log")"
gdbus call --session --timeout 5 --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
	--method org.freedesktop.Notifications.CloseNotification "${id3:-0}" >/dev/null 2>&1
until_line "NotificationClosed (uint32 ${id3:-0}, uint32 3)" 50 "$T/mon" && ok "CloseNotification closes with reason 3" || bad "no NotificationClosed reason 3"

# 4. expiry: reason 1; its own picture (image-path) when the app has no icon here
printf 'P6\n28 28\n255\n' > "$T/pic.ppm"; head -c 2352 /dev/zero | tr '\0' '\200' >> "$T/pic.ppm"
r=$(notify "Some App" 0 "" "short lived" "" "[]" "{'image-path': <'$T/pic.ppm'>}" 600)
id4=$(echo "$r" | sed -n 's/^(uint32 \([0-9]*\),)$/\1/p')
until_line "arrived ${id4:-0} .*icon=photo " 30 "$T/log" && ok "an app without an icon shows the notification's own picture" || bad "the picture entry: $(grep "arrived ${id4:-0} " "$T/log")"
until_line "NotificationClosed (uint32 ${id4:-0}, uint32 1)" 60 "$T/mon" && ok "an expired notification closes with reason 1" || bad "no NotificationClosed reason 1"
# 5. a progress (a volume level) with its own expire_timeout closes then, with reason 1
r=$(notify Volume 0 "" "Volume" "" "[]" "{'value': <int32 40>}" 600)
id5=$(echo "$r" | sed -n 's/^(uint32 \([0-9]*\),)$/\1/p')
until_line "NotificationClosed (uint32 ${id5:-0}, uint32 1)" 60 "$T/mon" && ok "a progress with an expire_timeout expires with reason 1" || bad "the progress with a timeout never closed ($r)"

# 6. the body's numeric entities (g_markup_escape_text writes ' as &#39;); an urgency that is no number
r=$(notify Mail 0 "" "Re: plans" "Don&#39;t forget &#x26; bring &amp;#39;" "[]" "{'urgency': <nan>}" 0)
id6=$(echo "$r" | sed -n 's/^(uint32 \([0-9]*\),)$/\1/p')
[ -n "$id6" ] && ok "an urgency hint that is no number is answered with an id" || bad "the odd urgency: $r"
until_line "arrived ${id6:-0} app=Mail summary=Re: plans body=Don't forget & bring &#39; " 30 "$T/log" &&
	ok "numeric entities in the body are read, once" || bad "the entities: $(grep "arrived ${id6:-0} " "$T/log")"

# 7. image-data: drawn at 14 px and saved at that size, not as the sender's 64 x 64 bytes (the saved history)
bytes=$(head -c 16384 /dev/zero | tr '\0' 'A')
r=$(notify "Some App" 0 "" "avatar" "" "[]" "{'image-data': <(64, 64, 256, true, 8, 4, b'$bytes')>}" 0)
id7=$(echo "$r" | sed -n 's/^(uint32 \([0-9]*\),)$/\1/p')
until_line "arrived ${id7:-0} .*icon=photo " 30 "$T/log" && ok "an image-data picture is drawn" || bad "the image-data entry: $r $(grep "arrived ${id7:-0} " "$T/log")"
# the history is saved once the entry is in it
until_line "avatar" 30 "$T/s/ribbon/notifications"
sz=$(wc -c < "$T/s/ribbon/notifications" 2>/dev/null || echo 0)
[ "$sz" -gt 0 ] && [ "$sz" -lt 8000 ] && ok "the saved history keeps the picture small ($sz bytes)" || bad "the saved history is $sz bytes after one 64 x 64 picture"

# 8. a flood: the alert sound plays once, not once each
: > "$T/sounds"; sleep 1.1
P=; for i in 1 2 3 4 5 6 7 8 9 10; do notify Chat 0 "" "message $i" "hello" "[]" "{}" 0 >/dev/null & P="$P $!"; done; wait $P
until_line "summary=message 10 " 30 "$T/log"; sleep 0.3
n=$(grep -c played "$T/sounds")
[ "$n" -eq 1 ] && ok "a flood of ten notifications plays the alert once" || bad "a flood of ten played the alert $n times"

r=$(gdbus call --session --timeout 5 --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications --method org.freedesktop.Notifications.GetCapabilities 2>&1)
case $r in *"'actions'"*"'body-markup'"*) ok "the capabilities name actions and body-markup";; *) bad "capabilities: $r";; esac
grep -q '  FAIL' "$T/shell.out" && { bad "the shell reported an error"; sed 's/^/       /' "$T/shell.out"; }
[ $fails -eq 0 ] && echo "notifications on the bus: all checks passed"
[ $fails -eq 0 ]
