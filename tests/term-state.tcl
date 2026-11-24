# term-state.tcl - the Ribbon Terminal's kept state (mod-term.tcl "kept across a shell restart"), as a pure-Tcl
# unit test: the real fault.tcl and mod-term.tcl are sourced into child interpreters, one per shell, with the
# window manager, Tk and labwc stubbed. Save, a simulated restart (a fresh interpreter on the same state
# folder), restore, then `snap restore` must give the rectangle from before the snap.
# Run by tests/steps.d/65-term.sh. Exits 1 if a check fails; each check prints one line.
set root [file normalize [file join [file dirname [info script]] ..]]
set shell $root/srcpkgs/ribbon-desktop/files/shell
set base [exec mktemp -d]
set ::fails 0
proc check {what cond} {
	if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what"; incr ::fails }
}

# the stubs every shell gets: the window list (wm::), the Tk widgets that the group makes, and labwc
set stubs {
	namespace eval shell {}
	namespace eval wm {
		variable order {}
		variable focus ""
		variable sent {}
		array set tl {}
		array set state {}
	}
	proc wm::changed {args} {}
	proc wm::send {verb id args} { lappend wm::sent [list $verb $id] }
	proc wm::has {id what} { expr {[info exists wm::state($id,$what)] ? $wm::state($id,$what) : 0} }
	proc wm::get {id key} {
		switch -- $key {
			app { return [dict get $wm::tl($id) app] }
			default { return "" }
		}
	}
	proc toplevel {args} {}
	proc canvas {path args} { uplevel #0 [list proc $path {args} {}] }
	proc bindtags {args} { return {} }
	proc bind {args} {}
	proc winfo {args} { return 0 }
	proc pack {args} {}
	proc wm {args} {}
	proc shell::verb {args} {}
	proc shell::runtime {} { return $::env(XDG_RUNTIME_DIR) }
	array set theme::c {BAR #222222}
	set bar::W 1440
	set bar::H 900
}

# a shell: a child interpreter on STATE, with mod-term.tcl sourced as the shell sources it
proc newshell {state} {
	global shell stubs
	set i [interp create]
	$i eval [list set ::env(XDG_STATE_HOME) $state]
	$i eval [list set ::env(XDG_RUNTIME_DIR) $state]
	$i eval [list set ::env(RIBBON_TERM_RC) $state/xdg/labwc/rc.xml]
	$i eval [list set ::env(HOME) $state]
	$i eval [list namespace eval theme {}]
	# the main display's rectangle (shell/display.tcl sets these in the shell): a 1440x900 screen at 0,0
	$i eval [list namespace eval bar {variable X0 0 Y0 0 W 1440 H 900}]
	$i eval $stubs
	$i eval [list source $shell/fault.tcl]
	$i eval [list source $shell/mod-term.tcl]
	# strip.tcl is only drawn with a window; the group's reload is labwc's and must not run here
	$i eval {set ::term::striploaded 1; proc ::term::reload {} {}}
	return $i
}
# the window list of a shell: TABS is {ID APP ...} in tab order
proc windows {i tabs} {
	$i eval [list set wm::order [dict keys $tabs]]
	foreach {id app} $tabs { $i eval [list set wm::tl($id) [dict create app $app]] }
}
proc sh {i script} { $i eval $script }
proc groupstate {i key} { $i eval [list set term::G(g1,$key)] }
proc rect {i} { return [list [groupstate $i x] [groupstate $i y] [groupstate $i w] [groupstate $i h]] }
proc file_of {state} {
	set fh [open $state/ribbon/term-groups]; fconfigure $fh -encoding utf-8; set t [read $fh]; ::close $fh
	return [string trim $t]
}

set state $base/state
file mkdir $state
set tabs1 {t1 ribbon-term-g1-1 t2 ribbon-term-g1-2 t3 ribbon-term-g1-3}
set tabs2 {u1 ribbon-term-g1-1 u2 ribbon-term-g1-2 u3 ribbon-term-g1-3}

# ---- shell 1: a group away from the default rectangle, tab 2 in front, snapped left
puts "term state: kept across a shell restart"
set s1 [newshell $state]
windows $s1 $tabs1
sh $s1 {term::sync}
sh $s1 {term::setrect g1 200 150 900 600}
sh $s1 {term::verb tab 2}
sh $s1 {term::verb snap left}
check "snapped left: the rectangle is the left half" {[rect $s1] eq {8 62 708 776}}
sh $s1 {term::savestate}
check "term-groups: the rectangle, the rectangle before the snap and tab 2" {[file_of $state] eq "g1 8 62 708 776 0 2 200,150,900,600"}
interp delete $s1

# ---- a shell restart: the same state folder, new windows
set s2 [newshell $state]
check "the new shell reads the line back" {[sh $s2 {dict get $term::pending g1 saved}] eq {200 150 900 600}}
windows $s2 $tabs2
sh $s2 {term::sync}
check "the group is back at its snapped rectangle" {[rect $s2] eq {8 62 708 776}}
check "  with its rectangle before the snap" {[groupstate $s2 saved] eq {200 150 900 600}}
check "  and it is not maximised" {[groupstate $s2 max] == 0}
check "  and tab 2 is in front" {[groupstate $s2 cur] eq "u2"}

# ---- snap restore after the restart: the pre-snap rectangle, and the saved one is used up
sh $s2 {term::verb snap restore}
check "snap restore after the restart: the rectangle from before the snap" {[rect $s2] eq {200 150 900 600}}
check "  not maximised" {[groupstate $s2 max] == 0}
check "  the saved rectangle is used up" {[groupstate $s2 saved] eq {}}
interp delete $s2

# ---- a maximised group: the restart keeps the flag, and restore gives the rectangle from before the max
set state2 $base/state2
file mkdir $state2
set s3 [newshell $state2]
windows $s3 $tabs1
sh $s3 {term::sync}
sh $s3 {term::setrect g1 200 150 900 600}
sh $s3 {term::verb snap max}
check "maximised: the work area" {[rect $s3] eq {0 54 1440 792}}
sh $s3 {term::savestate}
interp delete $s3
set s4 [newshell $state2]
windows $s4 $tabs2
sh $s4 {term::sync}
check "maximised after the restart: the flag and the rectangle" {[groupstate $s4 max] == 1 && [rect $s4] eq {0 54 1440 792}}
sh $s4 {term::verb snap restore}
check "  snap restore: the rectangle from before the max" {[rect $s4] eq {200 150 900 600} && [groupstate $s4 max] == 0}
interp delete $s4

file delete -force $base
puts "  [expr {$::fails ? "FAIL" : "ok  "}] term state: $::fails failed"
exit [expr {$::fails ? 1 : 0}]
