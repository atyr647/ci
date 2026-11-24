# shell-dbus.tcl - RIBBON_SHELL_TEST hook for the shell's notification server
# (tests/test-dbus.sh, on its private bus). The shell starts without ribbon::dbus;
# the server starts once the shell is up (mod-notify.tcl, after idle), and that
# first call loads ribbon::dbus through shell::bus. notify-send, on the same bus,
# then drives the server: a notification, a replacement, an expiry, and an action.

set failed 0
set here [file dirname [file normalize [info script]]]
# a background error ends the run (wish would show a dialog and wait)
interp bgerror {} {apply {{msg opts} { puts "  FAIL background error: [dict get $opts -errorinfo]"; exit 1 }}}
after 40000 {puts "  FAIL the shell's D-Bus checks took more than 40 s"; exit 1}
proc ok {what} { puts "  ok   $what" }
proc bad {what why} { global failed; incr failed; puts "  FAIL $what: $why" }
proc rss {} { exec awk {/VmRSS/ {print $2}} /proc/[pid]/status }
# milliseconds since this process started (the kernel counts in ticks)
proc since_start {} {
	set f [open /proc/self/stat]; set stat [read $f]; close $f
	set f [open /proc/uptime]; set up [lindex [read $f] 0]; close $f
	set ticks [lindex [string range $stat [string last ) $stat]+2 end] 19]
	expr {round(($up - $ticks / double([exec getconf CLK_TCK])) * 1000)}
}

# before the server starts (the hook is sourced before the shell's idle work)
set loaded [expr {[package provide ribbon::dbus] ne "" || [namespace exists ::ribbon::dbus] || [package provide unix_extra] ne ""}]
if {$loaded} { bad "the shell starts without ribbon::dbus" "it is loaded" } else {
	ok "the shell starts without ribbon::dbus or unix_extra (up in [since_start] ms, [expr {[rss] / 1024}] MB)"
}

# run a notify-send and wait for its output, without blocking the shell's loop
proc send {args} {
	set f [open |[list notify-send -p {*}$args 2>@1] r]
	fconfigure $f -blocking 0
	set out ""
	fileevent $f readable [list [info coroutine]]
	while {![eof $f]} { yield; append out [read $f] }
	fconfigure $f -blocking 1
	catch {close $f}
	return [string trim $out]
}

proc consumer {} {
	global failed
	# the server starts on its own, a moment after the shell is up
	set n 0
	while {$::notify::status eq "off" && $n < 100} { after 50 [list [info coroutine]]; yield; incr n }
	if {$::notify::status eq "primary"} { ok "the server starts after the shell is up and owns the name" } else {
		bad "the server starts" "status is {$::notify::status}"; exit 1
	}
	if {[package provide ribbon::dbus] eq ""} { bad "shell::bus loads ribbon::dbus" "not loaded" } else {
		ok "the server's start loads ribbon::dbus, through shell::bus (+[expr {[rss] / 1024}] MB)"
	}
	if {[shell::bus] eq [shell::bus]} { ok "  later calls share that connection" } else { bad "shell::bus keeps one connection" "a second one" }

	set id [send "From the shell test"]
	set e [notify::find $id]
	if {$e ne "" && [dict get $e summary] eq "From the shell test" && $id in $::notify::shown} {
		ok "notify-send's notification is on the popups (id $id)"
	} else { bad "notify-send in the shell" "id {$id}, entry {$e}" }

	set id2 [send -r $id "Replaced in place"]
	if {$id2 == $id && [dict get [notify::find $id] summary] eq "Replaced in place" && [llength [notify::history]] == 1} {
		ok "  a replacement keeps the id and the entry"
	} else { bad "replaces_id" "got id {$id2}" }

	# a short one fades off the popups after its time, and stays in the history
	set short [send -t 600 "Short one"]
	# (until it has gone, at most 5 s: its 600 ms and the fade)
	set n 0; while {$short in $::notify::shown && $n < 100} { after 50 [list [info coroutine]]; yield; incr n }
	if {$short ni $::notify::shown && [dict get [notify::find $short] open] == 0 && [dict get [notify::find $short] seen] == 0} {
		ok "  an expired notification leaves the popups, stays in the history, unseen"
	} else { bad "expiry" "shown {$::notify::shown}" }

	# an action: the popup goes, and the history keeps it (in-process; the bus
	# call of Notify with actions is not checked here, see the report)
	notify::arrive [dict create id 500 app Test summary "With an action" body "" urgency 1 timeout 0 \
		sender :1.9 replaces 0 hints {} actions {default Open later Later}]
	if {500 in $::notify::shown} { ok "  a notification with actions is on the popups" } else { bad "an action notification" "not shown" }
	notify::act 500 default
	if {500 ni $::notify::shown && [dict get [notify::find 500] open] == 0} {
		ok "  its default action takes the popup away, and the history keeps it"
	} else { bad "an action" "still on the popups" }
	notify::seen
	if {[notify::unseen] == 0} { ok "  seen marks the history read" } else { bad "seen" "[notify::unseen] unseen" }
	exit [expr {$failed ? 1 : 0}]
}
after 300 {coroutine shelldbus consumer}
