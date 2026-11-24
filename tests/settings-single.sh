#!/bin/sh
# settings-single.sh - run inside xvfb by tests/steps.d/57-settings-single.sh: one Settings window (C1).
# A first ribbon-settings opens on Power; a second, asked for Network, hands its page over and exits; the first then
# shows Network and is still the only Settings. Once through the socket in XDG_RUNTIME_DIR, once (no runtime dir)
# through Tk's send. Args: FILES-DIR WORK-DIR. Prints ok/FAIL lines; exits 1 on a failure.
D=$1; W=$2
fails=0
cat > "$W/probe.tcl" <<'TCL'
wm withdraw .
# the Settings applications on this display, and the first one's answer to the script given
set apps [lsearch -all -inline -glob [winfo interps] ribbon-settings*]
set r ""
if {[llength $apps] == 1} { catch {send [lindex $apps 0] [lindex $argv 0]} r }
puts "[llength $apps]|$r"
exit
TCL
probe() { timeout 10 wish8.6 "$W/probe.tcl" "$1" 2>/dev/null; }
# wait until the running Settings answers SCRIPT with WANT (10 s)
await() {
	i=0
	while [ $i -lt 100 ]; do
		[ "$(probe "$1")" = "$2" ] && return 0
		sleep 0.1; i=$((i + 1))
	done
	return 1
}
run() { # LABEL (with the env of the caller)
	label=$1
	timeout 60 wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" -name ribbon-settings -- --page power >"$W/first.out" 2>&1 &
	first=$!
	if ! await 'set settings::sel' '1|power'; then
		echo "  FAIL ($label) the first Settings did not open on Power"; sed 's/^/       /' "$W/first.out"; fails=$((fails + 1))
		kill $first 2>/dev/null; wait $first 2>/dev/null; return
	fi
	if timeout 20 wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" -name ribbon-settings -- --page network >"$W/second.out" 2>&1; then
		echo "  ok   ($label) a second ribbon-settings hands its page over and exits"
	else
		echo "  FAIL ($label) the second ribbon-settings did not exit"; sed 's/^/       /' "$W/second.out"; fails=$((fails + 1))
	fi
	if await 'list $settings::sel [llength [lsearch -all [lmap w [winfo children .] {winfo class $w}] RibbonSettings]] [wm state $settings::win]' '1|network 1 normal'; then
		echo "  ok   ($label) the first Settings shows Network, its window shown, and it is the only one"
	else
		echo "  FAIL ($label) after the second launch: $(probe 'list $settings::sel [wm state $settings::win]')"; fails=$((fails + 1))
	fi
	kill $first 2>/dev/null; wait $first 2>/dev/null
}
# the first is on the background picker (Onstage: its own sheet, the Settings window stepped aside) when a second asks
# for Network: the picker closes as Back closes it, and the Settings window shows Network and takes the clicks again
onstage() {
	timeout 60 wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" -name ribbon-settings -- --page desktop >"$W/first.out" 2>&1 &
	first=$!
	if ! await 'set os::S(open)' '1|1'; then
		echo "  FAIL (onstage) the first Settings did not open the background picker"; sed 's/^/       /' "$W/first.out"; fails=$((fails + 1))
		kill $first 2>/dev/null; wait $first 2>/dev/null; return
	fi
	timeout 20 wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" -name ribbon-settings -- --page network >"$W/second.out" 2>&1
	if await 'list $os::S(open) $settings::sel [expr {$ui::cv eq "$settings::win.c"}] [wm state $settings::win]' '1|0 network 1 normal'; then
		echo "  ok   (onstage) a second launch over the background picker closes it and shows Network in the Settings window"
	else
		echo "  FAIL (onstage) over the picker: $(probe 'list open $os::S(open) sel $settings::sel cv $ui::cv [wm state $settings::win]')"; fails=$((fails + 1))
	fi
	kill $first 2>/dev/null; wait $first 2>/dev/null
}
run socket
onstage
if ls "$XDG_RUNTIME_DIR"/ribbon-settings-*.sock >/dev/null 2>&1; then
	echo "  ok   (socket) the running Settings listens in XDG_RUNTIME_DIR"
else
	echo "  FAIL (socket) no socket in XDG_RUNTIME_DIR"; fails=$((fails + 1))
fi
( unset XDG_RUNTIME_DIR; run send; [ $fails -eq 0 ] ) || fails=$((fails + 1))
[ $fails -eq 0 ]
