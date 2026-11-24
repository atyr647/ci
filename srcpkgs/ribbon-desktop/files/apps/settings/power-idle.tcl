# power-idle.tcl - the idle timers' daemon (U14): keeps swayidle running with the timers for the current state (on battery
# or plugged in, with or without the dim), and restarts it when the state or a value in ~/.config/ribbon/power.conf changes.
# Started at login by the labwc autostart:
#   tclsh /usr/lib/ribbon/settings/power-idle.tcl
# The timers themselves are power.tcl's (power::idle_args). Every 2 s a pass also
#   - asks org.freedesktop.ScreenSaver (screensaver.tcl) whether an app holds an inhibit: while one does, swayidle runs
#     without its timeouts (no dim, screen off, lock or suspend), and gets them back when the last one is given back;
#   - warns of a low battery through the notification server (Notify-Final-4-Critical): "Battery at N%" from the app
#     "Power", once when the charge falls to the low level (urgency normal) and once more at the critical level
#     (urgency critical, replacing it), with "Suspend now" (↵, logind's Suspend) and "Power saver" (power-profiles-daemon,
#     offered when it runs and is not in that mode already); closed when the machine is plugged in or charges.
#
#   pidle::args BAT DIM INHIBITED   the swayidle arguments for a state (power::idle_args without its timeouts when inhibited)
#   pidle::levels ACTION_PCT        {low critical}: 10 and 5, kept above UPower's action level (Settings → Power)
#   pidle::warn UPOWER ROOT         the step for one reading: {} (nothing), close, or {notify LEVEL}; it updates pidle::note
#   pidle::run                      one pass (in a coroutine: the bus calls yield)

source -encoding utf-8 [file join [file dirname [file normalize [info script]]] power.tcl]

namespace eval pidle {
	variable sbus ""        ;# the session bus (notifications, the screensaver service)
	variable last ""        ;# the swayidle arguments in effect
	variable note {level none id 0 open 0 summary "" body ""}   ;# the battery warning: the level shown, its id, still up
	variable seq 0
	variable ss org.freedesktop.ScreenSaver
	variable nd org.freedesktop.Notifications
	variable npath /org/freedesktop/Notifications
}

# ---- the session bus -------------------------------------------------------------------------

proc pidle::session {} {
	variable sbus
	variable nd
	if {$sbus ne "" && [llength [info commands $sbus]] && [ribbon::dbus::alive $sbus]} { return $sbus }
	set sbus [ribbon::dbus::connect session]
	$sbus listen -sender $nd -interface $nd -member NotificationClosed pidle::closed
	$sbus listen -sender $nd -interface $nd -member ActionInvoked pidle::invoked
	return $sbus
}

# ---- inhibitors -------------------------------------------------------------------------------

# Whether an app holds an inhibit. The service is not started for this (it starts when an app first asks); without it,
# or when it does not answer, nothing is held.
proc pidle::inhibited {} {
	variable ss
	if {[catch {
		set l [lindex [[pidle::session] call -noautostart 1 -timeout 2000 $ss /org/freedesktop/ScreenSaver org.ribbon.ScreenSaver Inhibitors] 0]
	}]} { return 0 }
	expr {[llength $l] > 0}
}

# power::idle_args, and when inhibited the same without any timeout (the lock before sleep stays).
proc pidle::args {bat dim inhibited} {
	set a [power::idle_args $bat $dim]
	if {!$inhibited} { return $a }
	set out {}
	for {set i 0} {$i < [llength $a]} {incr i} {
		set w [lindex $a $i]
		if {$w eq "timeout"} {
			incr i 2
			if {[lindex $a $i+1] eq "resume"} { incr i 2 }
			continue
		}
		lappend out $w
	}
	return $out
}

proc pidle::apply {bat inhibited} {
	variable last
	set a [pidle::args $bat [power::setting DIM] $inhibited]
	if {[power::idle_current $last {*}$a]} { return 0 }
	set last $a
	power::idle_start {*}$a
	return 1
}

# ---- the battery warning ------------------------------------------------------------------------

proc pidle::levels {action_pct} {
	if {![string is integer -strict $action_pct]} { set action_pct 2 }
	list [expr {max(10, $action_pct + 5)}] [expr {max(5, $action_pct + 2)}]
}

# Running on the battery and not charging (UPower State: 1 charging, 4 fully charged).
proc pidle::discharging {up} {
	expr {[dict get $up bat] && [dict get $up onbattery] && [dict get $up state] ni {1 4}}
}

# "About 6 minutes left." ("" when UPower does not know)
proc pidle::time_left {tte} {
	if {![string is double -strict $tte] || $tte <= 0} { return "" }
	set m [expr {max(1, int(round($tte / 60.0)))}]
	if {$m < 60} { return "About $m minute[expr {$m == 1 ? "" : "s"}] left." }
	return "About [expr {$m / 60}] h [expr {$m % 60}] min left."
}

# The text: {summary body}. ROOT is power::root (the critical action and its level).
proc pidle::text {up root} {
	set pct [expr {int(round([dict get $up pct]))}]
	set verb ""
	switch -nocase -- [dict get $root critical] {
		Suspend - HybridSleep { set verb suspends }
		Hibernate { set verb hibernates }
		PowerOff { set verb "shuts down" }
	}
	set plug [expr {$verb eq "" ? "Plug in." : "Plug in, or it $verb at [dict get $root critical_pct]%."}]
	list "Battery at $pct%" [string trim "[pidle::time_left [dict get $up tte]] $plug"]
}

# One reading: what to do with the warning. Returns {} (nothing), close, {notify LEVEL} (a new level: send it, replacing
# the one before) or {update LEVEL} (the one up gets the new level and time). The note keeps the level until charging.
proc pidle::warn {up root} {
	variable note
	set rank {none 0 low 1 critical 2}
	if {![pidle::discharging $up]} {
		set was [dict get $note open]
		dict set note level none
		dict set note open 0
		return [expr {$was ? "close" : ""}]
	}
	lassign [pidle::levels [dict get $root critical_pct]] low crit
	set pct [dict get $up pct]
	set want [expr {$pct <= $crit ? "critical" : ($pct <= $low ? "low" : "none")}]
	set shown [dict get $note level]
	if {[dict get $rank $want] > [dict get $rank $shown]} {
		dict set note level $want
		return [list notify $want]
	}
	if {$shown ne "none" && [dict get $note open]} {
		lassign [pidle::text $up $root] s b
		if {$s ne [dict get $note summary] || $b ne [dict get $note body]} { return [list update $shown] }
	}
	return ""
}

# The actions: Suspend now (the default, ↵), and Power saver when power-profiles-daemon runs in another mode.
proc pidle::actions {} {
	set acts {default {Suspend now}}
	if {![catch {power::read_ppd} p] && "power-saver" in [dict get $p profiles] && [dict get $p profile] ne "power-saver"} {
		lappend acts power-saver {Power saver}
	}
	return $acts
}

proc pidle::send {level up root} {
	variable note
	variable nd
	variable npath
	lassign [pidle::text $up $root] summary body
	set urgency [expr {$level eq "critical" ? 2 : 1}]
	set id [lindex [[pidle::session] call $nd $npath $nd Notify susssasa{sv}i \
		Power [dict get $note id] "" $summary $body [pidle::actions] [dict create urgency [list y $urgency]] -1] 0]
	dict set note id $id
	dict set note open 1
	dict set note summary $summary
	dict set note body $body
}

proc pidle::close_note {} {
	variable note
	variable nd
	variable npath
	if {[dict get $note id]} { catch {[pidle::session] call $nd $npath $nd CloseNotification u [dict get $note id]} }
}

proc pidle::battery {up} {
	set root [power::root]
	set step [pidle::warn $up $root]
	switch -- [lindex $step 0] {
		close { pidle::close_note }
		notify - update { pidle::send [lindex $step 1] $up $root }
	}
	return $step
}

# The server's signals: the warning was closed (it timed out, or was dismissed, or an action ended it), or an action picked.
proc pidle::closed {msg id reason} {
	variable note
	if {$id == [dict get $note id]} { dict set note open 0 }
}

proc pidle::invoked {msg id key} {
	variable note
	if {$id != [dict get $note id]} return
	switch -- $key {
		default { coroutine ::pidle::act[incr ::pidle::seq] pidle::suspend }
		power-saver { coroutine ::pidle::act[incr ::pidle::seq] pidle::saver }
	}
}

proc pidle::suspend {} {
	catch {
		power::ensure_bus
		$::power::bus call -interactive 1 org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager Suspend b 0
	}
}

proc pidle::saver {} {
	catch { power::ensure_bus; power::do_set_profile power-saver }
}

# ---- the pass ---------------------------------------------------------------------------------

proc pidle::run {} {
	set up {onbattery 0 bat 0 pct 0 state 0 tte 0}
	# a reading that fails (UPower restarting) leaves the warning as it is: it is not taken for mains
	set read [expr {![catch { power::ensure_bus; set up [power::read_upower] }]}]
	pidle::apply [dict get $up onbattery] [pidle::inhibited]
	set closed 0
	catch { set closed [power::read_lid] }
	power::lid_step $closed [dict get $up onbattery]
	if {$read} { catch { pidle::battery $up } }
}

proc pidle::loop {} {
	coroutine ::pidle::pass[incr ::pidle::seq] pidle::once
}

proc pidle::once {} {
	catch {pidle::run}
	after 2000 pidle::loop
}

if {[info exists ::argv0] && [file normalize $::argv0] eq [file normalize [info script]]} {
	pidle::loop
	vwait forever
}
