# mod-stuck.tcl - "<App> is not responding" while the System monitor is closed (a shell module, C2). The monitor's
# own detection (apps/monitor/stuck.tcl: the app's end of its display socket keeps unread data for five looks running)
# runs here once a second, only while there is an app window and not while the monitor's window is open (the monitor
# shows its own strip then, Monitor-R4-Stuck). An app found not responding gets one notification through the shell's
# notifications (Notify-Final's look): the summary "<App> is not responding", the actions Wait and End.
#   Wait (or closing it)  no other notice for that app until it has responded again
#   End                   the System monitor opens on its End sheet for that app (`ribbon-monitor --end PID`)
# The notice is taken away when the app responds again. The app's name is the monitor's (apps/monitor/group.tcl: a
# kit's or a .desktop file's name, else the process's own).

namespace eval stuck {
	variable timer ""
	variable notes [dict create]   ;# key -> {id PID}: the notices showing
	variable waited {}             ;# keys Wait was said to, until they respond again
	variable sent [dict create]    ;# notification id -> key
	variable ok 0                  ;# the monitor's files were found and loaded
	variable cmd [list ribbon-monitor]
	variable tick_ms 1000
	variable nbus ""
}

# The monitor's detection, proc.tcl and the app grouping, from the installed monitor or the repository's.
proc stuck::load {} {
	variable ok
	set here [file dirname [file normalize [info script]]]
	foreach d [list [file join $here .. apps monitor] /usr/lib/ribbon/monitor] {
		if {![file exists [file join $d stuck.tcl]]} continue
		foreach f {proc group stuck} { uplevel #0 [list source -encoding utf-8 [file join $d $f.tcl]] }
		set ok 1
		return
	}
}
stuck::load

# Is the System monitor's window open?
proc stuck::monitor_open {} {
	foreach id [wm::windows] { if {[string match -nocase *ribbon*monitor* [wm::get $id app]]} { return 1 } }
	return 0
}

# The app each pid belongs to: dict pid -> {key name}.
proc stuck::apps_of {pids} {
	set procs [monitor::scan]
	set out [dict create]
	foreach a [monitor::group::assign $procs [monitor::group::desktops]] {
		foreach p [dict get $a pids] {
			if {$p in $pids && [dict get $a id] ne ""} { dict set out $p [list app:[dict get $a id] [dict get $a name]] }
		}
	}
	foreach p $pids {
		if {[dict exists $out $p]} continue
		foreach q $procs { if {[dict get $q pid] == $p} { dict set out $p [list pid:$p [dict get $q comm]] } }
	}
	return $out
}

proc stuck::tick {} {
	variable timer
	variable tick_ms
	after cancel $timer
	set timer [after $tick_ms stuck::tick]
	if {![llength [wm::windows]]} { forget_all; return }
	if {[monitor_open]} return
	look [monitor::stuck::update]
}

# One look's answer: notices for the apps newly stuck, none for those that respond again.
proc stuck::look {pids} {
	variable notes
	variable waited
	set now [dict create]
	if {[llength $pids]} {
		dict for {pid an} [apps_of $pids] {
			lassign $an key name
			if {![dict exists $now $key]} { dict set now $key [list $pid $name] }
		}
	}
	foreach key [dict keys $notes] { if {![dict exists $now $key]} { withdraw $key } }
	set waited [lmap k $waited { expr {[dict exists $now $k] ? $k : [continue]} }]
	dict for {key pn} $now {
		lassign $pn pid name
		if {[dict exists $notes $key] || $key in $waited} continue
		dict set notes $key [list 0 $pid]
		announce $key "$name is not responding"
	}
}

proc stuck::forget_all {} {
	variable notes
	foreach key [dict keys $notes] { withdraw $key }
	set ::stuck::waited {}
}

# ---- the notification ---------------------------------------------------------------------------------------------

proc stuck::bus {} {
	variable nbus
	if {$nbus ne ""} { return $nbus }
	if {[info commands ::shell::bus] eq "" || [catch {shell::bus} b]} { return "" }
	set nbus $b
	catch {$b listen -interface org.freedesktop.Notifications -member ActionInvoked -command list stuck::invoked}
	catch {$b listen -interface org.freedesktop.Notifications -member NotificationClosed -command list stuck::closed}
	return $b
}

proc stuck::announce {key summary} {
	set b [bus]
	if {$b eq ""} return
	catch {$b call -command [list stuck::sent $key] org.freedesktop.Notifications /org/freedesktop/Notifications \
		org.freedesktop.Notifications Notify susssasa{sv}i "System monitor" 0 utilities-system-monitor $summary "" \
		{wait Wait end End} [dict create urgency {y 1} resident {b 1} desktop-entry {s ribbon-monitor}] 0}
}
proc stuck::sent {key status args} {
	variable notes
	variable sent
	if {$status ne "ok" || ![dict exists $notes $key]} return
	set id [lindex $args 0 0]
	dict set notes $key [lreplace [dict get $notes $key] 0 0 $id]
	dict set sent $id $key
}

proc stuck::withdraw {key} {
	variable notes
	variable sent
	if {![dict exists $notes $key]} return
	set id [lindex [dict get $notes $key] 0]
	dict unset notes $key
	if {!$id} return
	dict unset sent $id
	set b [bus]
	if {$b ne ""} {
		catch {$b call -command list org.freedesktop.Notifications /org/freedesktop/Notifications \
			org.freedesktop.Notifications CloseNotification u $id}
	}
}

proc stuck::invoked {msg id action} {
	variable sent
	variable notes
	variable cmd
	if {![dict exists $sent $id]} return
	set key [dict get $sent $id]
	set pid [lindex [dict get $notes $key] 1]
	lappend ::stuck::waited $key
	withdraw $key
	if {$action eq "end"} { catch {exec {*}$cmd --end $pid </dev/null >/dev/null 2>/dev/null &} }
}

# Closed by the person (reason 2): as Wait.
proc stuck::closed {msg id reason} {
	variable sent
	variable notes
	if {![dict exists $sent $id]} return
	set key [dict get $sent $id]
	dict unset sent $id
	if {[dict exists $notes $key]} { dict unset notes $key }
	if {$reason == 2 && $key ni $::stuck::waited} { lappend ::stuck::waited $key }
}

if {$stuck::ok} { after idle stuck::tick }
