# power-idle.tcl (test) - the idle daemon's battery warning and inhibitors (apps/settings/power-idle.tcl), with the
# screensaver service (apps/settings/screensaver.tcl) D-Bus activated from its .service file. Run by
# tests/steps.d/55-power-idle.sh with a private system bus (DBUS_SYSTEM_BUS_ADDRESS: this process stands in for UPower,
# logind and power-profiles-daemon on it) and a private session bus (DBUS_SESSION_BUS_ADDRESS: this process runs the
# shell's own notification server, shell/notifyd.tcl, on it), SWAYIDLE_LOG and a swayidle stub on PATH, XDG_CONFIG_HOME,
# XDG_RUNTIME_DIR and RIBBON_POWER_ROOT set:
#   tclsh8.6 tests/power-idle.tcl FILES
# Prints one line per check; exits non-zero when one fails.
set D [lindex $argv 0]
set fails 0
proc check {what ok} {
	global fails
	if {$ok} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}
fconfigure stdout -buffering line

source -encoding utf-8 [file join $D apps settings power-idle.tcl]
source -encoding utf-8 [file join $D shell notifyd.tcl]

proc wait_for {cond {ms 6000}} {
	set t [clock milliseconds]
	while {![uplevel 1 [list expr $cond]]} {
		if {[clock milliseconds] - $t > $ms} { return 0 }
		update
		after 20
	}
	return 1
}
proc slurp {f} { if {[catch {open $f} fh]} { return "" }; set t [read $fh]; close $fh; set t }
proc lines {f} { set t [string trimright [slurp $f] \n]; expr {$t eq "" ? {} : [split $t \n]} }

# ---- the stand-ins on the system bus: UPower (its battery set by the test), logind, power-profiles-daemon ----
set sys [ribbon::dbus::connect system]
set UP /org/freedesktop/UPower
set DEV $UP/devices/DisplayDevice
set upfail 0
proc GetDisplayDevice {msg} { if {$::upfail} { error "UPower is restarting" }; return $::DEV }
$sys export $UP org.freedesktop.UPower {
	method GetDisplayDevice "" o GetDisplayDevice
	property OnBattery b read {-value 0}
}
$sys export $DEV org.freedesktop.UPower.Device {
	property Type u read {-value 2}
	property IsPresent b read {-value 1}
	property Percentage d read {-value 82.0}
	property State u read {-value 1}
	property TimeToEmpty x read {-value 0}
	property TimeToFull x read {-value 3600}
}
set suspends {}
proc Suspend {msg interactive} { lappend ::suspends $interactive; return }
$sys export /org/freedesktop/login1 org.freedesktop.login1.Manager {
	method Suspend b "" Suspend
	property LidClosed b read {-value 0}
}
set profiles {}
$sys export /net/hadess/PowerProfiles net.hadess.PowerProfiles {
	property ActiveProfile s readwrite {-value balanced -set {apply {{m v} {lappend ::profiles $v}}}}
	property Profiles aa{sv} read {-value {{Profile {s power-saver}} {Profile {s balanced}} {Profile {s performance}}}}
}
foreach n {org.freedesktop.UPower org.freedesktop.login1 net.hadess.PowerProfiles} {
	if {[$sys request $n] ne "primary"} { puts "  FAIL cannot own $n"; exit 1 }
}
proc battery {onbat pct state tte} {
	$::sys set $::UP org.freedesktop.UPower OnBattery $onbat
	$::sys set $::DEV org.freedesktop.UPower.Device Percentage $pct State $state TimeToEmpty $tte
}

# ---- the notification server: the shell's own (notifyd.tcl), recording what it is sent ----
set ses [ribbon::dbus::connect session]
set shown {}
set closes {}
notifyd::start $ses -show {lappend ::shown} -close {lappend ::closes}
proc last {} { lindex $::shown end }

# One pass of the daemon, in its own coroutine as the loop runs it.
proc pass {} {
	set ::passed 0
	coroutine ::tpass[incr ::tseq] apply {{} { pidle::run; set ::passed 1 }}
	wait_for {$::passed}
}

set SWAY $::env(SWAYIDLE_LOG)
set full_bat [list -w timeout 280 {brightnessctl -q -s set 10%} resume {brightnessctl -q -r} \
	timeout 300 {wlopm --off "*"} resume {wlopm --on "*"} timeout 300 ribbon-lock timeout 900 {loginctl suspend} \
	before-sleep ribbon-lock]

# ---- pure: the levels, the time left, the text ----
check "the levels are 10 % and 5 % above UPower's default action at 2 %" [expr {[pidle::levels 2] eq {10 5}}]
check "an action level of 10 % moves them to 15 % and 12 %" [expr {[pidle::levels 10] eq {15 12}}]
check "no time known: no time" [expr {[pidle::time_left 0] eq ""}]
check "one minute" [expr {[pidle::time_left 50] eq "About 1 minute left."}]
check "over an hour" [expr {[pidle::time_left 3900] eq "About 1 h 5 min left."}]
check "the board's text: Battery at 4%, about 6 minutes, suspends at 2 %" \
	[expr {[pidle::text {pct 4.2 tte 360} {critical HybridSleep critical_pct 2}] eq {{Battery at 4%} {About 6 minutes left. Plug in, or it suspends at 2%.}}}]
check "shut down at 10 %" [expr {[lindex [pidle::text {pct 12 tte 0} {critical PowerOff critical_pct 10}] 1] eq "Plug in, or it shuts down at 10%."}]
check "inhibited: the swayidle arguments keep only the lock before sleep" [expr {[pidle::args 1 yes 1] eq {-w before-sleep ribbon-lock}}]
check "not inhibited: the arguments are power::idle_args'" [expr {[pidle::args 1 yes 0] eq [power::idle_args 1 yes]}]

# ---- the battery warning, through the notification server ----
battery 0 82.0 1 0
check "a pass runs (plugged in, charging)" [pass]
check "plugged in: nothing is sent" [expr {[llength $shown] == 0}]
battery 1 50.0 2 9000
pass
check "on battery at 50 %: nothing is sent" [expr {[llength $shown] == 0}]

battery 1 9.0 2 1800
pass
check "at 9 %: one notification" [expr {[llength $shown] == 1}]
set n [last]
set id1 [dict get $n id]
check "from Power, urgency normal (the low level)" [expr {[dict get $n app] eq "Power" && [dict get $n urgency] == 1}]
check "Battery at 9%, about 30 minutes, suspends at 2 %" \
	[expr {[dict get $n summary] eq "Battery at 9%" && [dict get $n body] eq "About 30 minutes left. Plug in, or it suspends at 2%."}]
check "the two actions: Suspend now (↵) and Power saver" [expr {[dict get $n actions] eq {default {Suspend now} power-saver {Power saver}}}]
pass
check "the same reading again: not sent again" [expr {[llength $shown] == 1}]

battery 1 4.2 2 360
pass
set n [last]
check "at 4 %: the critical one replaces it (same id, not a second)" \
	[expr {[llength $shown] == 2 && [dict get $n id] == $id1 && [dict get $n replaces]}]
check "urgency critical, the board's text" [expr {[dict get $n urgency] == 2 && [dict get $n summary] eq "Battery at 4%"
	&& [dict get $n body] eq "About 6 minutes left. Plug in, or it suspends at 2%."}]
battery 1 3.0 2 240
pass
set n [last]
check "at 3 % while it stands: updated in place" [expr {[llength $shown] == 3 && [dict get $n id] == $id1 && [dict get $n summary] eq "Battery at 3%"}]
pass
check "no change: nothing more is sent" [expr {[llength $shown] == 3}]
set upfail 1
pass
set upfail 0
check "UPower does not answer once: the standing warning is not closed" [expr {[llength $closes] == 0}]
pass
check "and it is not sent again when UPower answers" [expr {[llength $shown] == 3}]

notifyd::invoked $id1 power-saver
check "Power saver sets power-profiles-daemon's mode" [wait_for {$::profiles eq {power-saver}}]
notifyd::invoked $id1 default
check "Suspend now asks logind to suspend" [wait_for {[llength $::suspends] == 1}]
notifyd::closed $id1 2
check "dismissed: the daemon sees it closed" [wait_for {![dict get $pidle::note open]}]
battery 1 2.6 2 200
pass
check "dismissed: it does not come back while the charge goes on falling" [expr {[llength $shown] == 3}]

battery 0 2.6 1 0
pass
check "plugged in after a dismissal: nothing to close" [expr {[llength $closes] == 0}]
battery 1 4.0 2 360
pass
set n [last]
check "unplugged again at 4 %: a new warning (a new crossing)" [expr {[llength $shown] == 4 && [dict get $n urgency] == 2 && [dict get $n id] != $id1}]
check "in power-saver already: only Suspend now is offered" [expr {[dict get $n actions] eq {default {Suspend now}}}]
battery 0 4.0 1 0
pass
check "plugged in: the warning is closed" [expr {$closes eq [list [dict get $n id]]}]
battery 1 4.0 1 0
pass
check "charging on battery power (State charging) sends nothing" [expr {[llength $shown] == 4}]

# ---- the inhibitors: org.freedesktop.ScreenSaver, D-Bus activated ----
proc has_owner {name} { lindex [$::ses call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus NameHasOwner s $name] 0 }
proc inhibitors {} { lindex [$::ses call org.freedesktop.ScreenSaver /org/freedesktop/ScreenSaver org.ribbon.ScreenSaver Inhibitors] 0 }
battery 1 50.0 2 9000
pass
check "no service yet: nothing inhibits, and asking does not start it" [expr {![pidle::inhibited] && ![has_owner org.freedesktop.ScreenSaver]}]
check "on battery: swayidle runs with every timer" [wait_for {[lindex [lines $SWAY] end] eq [join $full_bat " "]}]

set cli [ribbon::dbus::connect session]
set cookie [lindex [$cli call org.freedesktop.ScreenSaver /org/freedesktop/ScreenSaver org.freedesktop.ScreenSaver Inhibit ss Steam "Playing a game"] 0]
check "Inhibit starts the service from its .service file and gives a cookie" [expr {[string is integer -strict $cookie] && $cookie > 0}]
check "the service lists it, with its holder" [expr {[inhibitors] eq [list [list $cookie Steam "Playing a game" [$cli name]]]}]
set n0 [llength [lines $SWAY]]
pass
check "inhibited: swayidle is restarted without its timeouts" \
	[wait_for {[llength [lines $SWAY]] == $n0 + 1 && [lindex [lines $SWAY] end] eq "-w before-sleep ribbon-lock"}]
$cli call org.freedesktop.ScreenSaver /ScreenSaver org.freedesktop.ScreenSaver UnInhibit u 999
check "an unknown cookie (on /ScreenSaver) is ignored" [expr {[llength [inhibitors]] == 1}]
set cli2 [ribbon::dbus::connect session]
$cli2 call org.freedesktop.ScreenSaver /org/freedesktop/ScreenSaver org.freedesktop.ScreenSaver UnInhibit u $cookie
check "UnInhibit of another connection's cookie is ignored" [expr {[llength [inhibitors]] == 1}]
$cli call org.freedesktop.ScreenSaver /org/freedesktop/ScreenSaver org.freedesktop.ScreenSaver UnInhibit u $cookie
check "UnInhibit gives it back" [expr {[llength [inhibitors]] == 0}]
pass
check "given back: the timers return" [wait_for {[lindex [lines $SWAY] end] eq [join $full_bat " "]}]

# a holder that leaves the bus (a game that quits or crashes) takes its inhibit with it
set hf [file join $::env(XDG_RUNTIME_DIR) holder.tcl]
set fh [open $hf w]
puts $fh {
	package require ribbon::dbus
	fconfigure stdout -buffering line
	set b [ribbon::dbus::connect session]
	puts [lindex [$b call org.freedesktop.ScreenSaver /ScreenSaver org.freedesktop.ScreenSaver Inhibit ss mpv video] 0]
	gets stdin
}
close $fh
set h [open |[list [info nameofexecutable] $hf 2>@1] r+]
fconfigure $h -buffering line
set got [gets $h]
check "another process inhibits (on /ScreenSaver)" [expr {[string is integer -strict $got] && [llength [inhibitors]] == 1}]
pass
check "inhibited again" [wait_for {[lindex [lines $SWAY] end] eq "-w before-sleep ribbon-lock"}]
puts $h quit
catch {close $h}
check "the holder left the bus: its inhibit is dropped" [wait_for {[llength [inhibitors]] == 0}]
pass
check "and the timers return" [wait_for {[lindex [lines $SWAY] end] eq [join $full_bat " "]}]
if {[auto_execok gdbus] ne ""} {
	catch {exec gdbus call --session --dest org.freedesktop.ScreenSaver --object-path /org/freedesktop/ScreenSaver \
		--method org.freedesktop.ScreenSaver.Inhibit gdbus test 2>@1} out
	check "gdbus Inhibit answers a cookie" [regexp {^\(uint32 [0-9]+,\)$} [string trim $out]]
	check "gdbus left at once: its inhibit went with it" [wait_for {[llength [inhibitors]] == 0}]
}
# ---- swayidle dies: the idle lock comes back; a stale pid file never kills a stranger (review findings of 17 Nov) ----
proc idle_pid {} { string trim [slurp [power::idle_pidfile]] }
pass
check "a running swayidle counts as alive (its process name, not a zombie)" [wait_for {[power::idle_alive]}]
set n1 [llength [lines $SWAY]]
set old [idle_pid]
exec kill -9 $old
check "killed: it no longer counts as alive" [wait_for {![power::idle_alive]}]
pass
check "the pass right after it died does not respawn it in a loop (10 s between tries)" [expr {[llength [lines $SWAY]] == $n1}]
set power::idle_started 0
pass
check "swayidle killed: the next pass (after the wait) starts it again with the same arguments" \
	[wait_for {[llength [lines $SWAY]] == $n1 + 1 && [lindex [lines $SWAY] end] eq [join $full_bat " "] && [power::idle_alive]}]
check "  and it is a new process" [expr {[idle_pid] ne $old}]
set n2 [llength [lines $SWAY]]
pass
check "alive and unchanged: a pass does nothing" [expr {[llength [lines $SWAY]] == $n2}]
# a pid file that names another program (the number was handed on): never killed, and swayidle starts
set stranger [exec sleep 300 > /dev/null 2>/dev/null &]
set fh [open [power::idle_pidfile] w] ; puts $fh $stranger ; close $fh
exec kill [lindex [split [string trim [exec pgrep -f "real/swayidle 600" 2>/dev/null]] \n] 0]
set power::idle_started 0
check "a pid file that names another program is not alive" [expr {![power::idle_alive]}]
pass
check "swayidle is started although the pid file named a stranger" [wait_for {[power::idle_alive] && [idle_pid] ne $stranger}]
check "  and the stranger was not killed" [expr {![catch {exec kill -0 $stranger}]}]
catch {exec kill $stranger}
exit [expr {$fails ? 1 : 0}]
