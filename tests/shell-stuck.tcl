# tests/shell-stuck.tcl - shell/mod-stuck.tcl in tclsh: the shell's "not responding" notice, with the window list
# and the session bus stood in for and a real client that stops reading its display socket (monitor-fixtures/hang.py,
# the display's socket named for the detection). One notice with Wait and End after five looks; none while the
# System monitor's window is open; End runs `ribbon-monitor --end PID` (stood in for) and takes the notice away;
# Wait keeps it away while the app stays stuck; the notice goes when the app responds again (here: when it has gone).
set here [file dirname [file normalize [info script]]]
set repo [file dirname $here]
set fails 0
proc check {name ok} { if {$ok} { puts "  ok   $name" } else { puts "  FAIL $name"; incr ::fails } }
proc wait_for {script ms} {
	set until [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 $script]} {
		if {[clock milliseconds] >= $until} { return 0 }
		after 50 {set ::tick 1}; vwait ::tick
	}
	return 1
}
set T [exec mktemp -d]

# the shell's pieces the module uses
namespace eval wm { variable apps {foot} }
proc wm::windows {} { set i 0; lmap a $::wm::apps { incr i } }
proc wm::get {id key} { lindex $::wm::apps [expr {$id - 1}] }
namespace eval shell {}
proc shell::bus {} { return fakebus }
set ::calls {}
set ::nextid 40
proc fakebus {sub args} {
	if {$sub eq "listen"} return
	set cb [lindex $args 1]
	set member [lindex $args 5]
	set rest [lrange $args 7 end]
	if {$member eq "Notify"} {
		lappend ::calls [list Notify [lindex $rest 3] [lindex $rest 5] [lindex $rest 7]]
		{*}$cb ok [list [incr ::nextid]]
	} else {
		lappend ::calls [list $member {*}$rest]
	}
}
proc notices {} { lsearch -all -inline -index 0 $::calls Notify }

source -encoding utf-8 [file join $repo srcpkgs ribbon-desktop files shell mod-stuck.tcl]
check "the module finds the monitor's detection" [expr {$stuck::ok && [info commands ::monitor::stuck::update] ne ""}]
after cancel $stuck::timer
set stuck::tick_ms 300
set stuck::cmd [list sh -c "echo \"\$@\" > $T/monitor.out" x]

if {[auto_execok ss] eq "" || [auto_execok python3] eq ""} { puts "  skip (no ss / python3)"; exit 0 }
set hang [exec python3 [file join $here monitor-fixtures hang.py] $T/display $T/pid 60 </dev/null >/dev/null 2>/dev/null &]
wait_for [list file exists $T/pid] 5000
set child [string trim [monitor::slurp $T/pid]]
set ::monitor::stuck::displays [list $T/display]

# the monitor's window open: nothing is said
set wm::apps {foot RibbonMonitor}
stuck::tick
after 2500 {set ::tick 1}; vwait ::tick
check "while the System monitor is open, no notice" [expr {[notices] eq {}}]
set wm::apps {foot}
set t0 [clock milliseconds]
check "a client that stops reading: one notice, \"python3 is not responding\", with Wait and End" [expr {[wait_for {expr {[llength [notices]] == 1}} 8000] && [lindex [notices] 0 1] eq "python3 is not responding" && [lindex [notices] 0 2] eq {wait Wait end End} && [lindex [notices] 0 3] == 0}]
check "after five looks (about 5 s at the shell's 1 s; 1.5 s here)" [expr {[clock milliseconds] - $t0 >= 1000}]
after 1200 {set ::tick 1}; vwait ::tick
check "no second notice while it stays stuck" [expr {[llength [notices]] == 1}]
stuck::invoked {} 41 end
check "End: ribbon-monitor --end PID, and the notice is taken away" [expr {[wait_for [list file exists $T/monitor.out] 3000] && [string trim [monitor::slurp $T/monitor.out]] eq "--end $child" && [lsearch -exact $::calls {CloseNotification 41}] >= 0}]
after 1200 {set ::tick 1}; vwait ::tick
check "after End or Wait: no new notice while the same app stays stuck" [expr {[llength [notices]] == 1}]
# it responds (here: it goes); then another app (this tclsh, as the detection would name it) hangs: a new notice
catch {exec kill -9 $child}
after 1200 {set ::tick 1}; vwait ::tick
check "once it responds again, it is forgotten" [expr {$stuck::waited eq {} && [dict size $stuck::notes] == 0}]
after cancel $stuck::timer
set me [pid]
stuck::look $me
check "a later hang is told again" [expr {[llength [notices]] == 2 && [dict size $stuck::notes] == 1}]
stuck::look {}
check "a notice is taken away when its app responds" [expr {[lsearch -exact $::calls {CloseNotification 42}] >= 0 && [dict size $stuck::notes] == 0}]
stuck::look $me
stuck::closed {} 43 2
stuck::look $me
check "closing the notice is Wait" [expr {[llength [notices]] == 3 && $stuck::waited ne {}}]
set wm::apps {}
stuck::tick
check "with no app window nothing is looked at, and nothing is left" [expr {$stuck::waited eq {} && [dict size $stuck::notes] == 0}]
after cancel $stuck::timer
catch {exec kill $hang}
file delete -force $T
puts [expr {$fails ? "shell stuck: checks failed" : "shell stuck: all checks passed"}]
exit [expr {$fails ? 1 : 0}]
