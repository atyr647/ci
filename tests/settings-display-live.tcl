# settings-display-live.tcl - Settings → Display against a real compositor and the wlr-randr installed
# (headless labwc, two outputs; tests/steps.d/50-settings-display.sh starts it): the outputs are read
# (with --json, or from the plain listing when this wlr-randr has none), Apply changes the scale of the
# first output for real, and the revert puts it back. Run: tclsh8.6 tests/settings-display-live.tcl DIR
set D [lindex $argv 0]
set fails 0
proc check {what ok} {
	global fails
	if {$ok} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}
namespace eval page { proc draw {} {} }
set home [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] ribbon-display-live-[pid]]
file mkdir $home
set ::env(HOME) $home
set ::env(XDG_CONFIG_HOME) [file join $home cfg]
source [file join $D apps settings display.tcl]

# wait (with a deadline) until the page's read has finished
proc fetched {} {
	set ::display::loaded 0
	display::fetch
	set t [after 10000 {set ::display::loaded timeout}]
	while {$::display::loaded == 0} { vwait ::display::loaded }
	after cancel $t
	set ::display::loaded
}
proc settle {cond} {
	set end [expr {[clock milliseconds] + 10000}]
	while {![uplevel #0 [list expr $cond]] && [clock milliseconds] < $end} { after 50 {set ::tick 1}; vwait ::tick }
}
set json [expr {[catch {exec wlr-randr --json 2>/dev/null}] == 0}]
check "the outputs are read from the real wlr-randr ([expr {$json ? {--json} : {plain listing, no --json}}])" \
	[expr {[fetched] == 1 && [llength $::display::outs] == 2}]
set o [lindex $::display::outs 0]
set name [dict get $o name]
check "$name is on, [dict get $o w]x[dict get $o h] at [dict get $o r] Hz, scale [dict get $o scale]" \
	[expr {[dict get $o on] && [dict get $o w] > 0 && [dict get $o scale] == 1}]
display::set_val $name scale 1.5
set ::display::snapshot {}
display::apply
settle {$::display::sheet == 1 && $::display::loaded == 1}
check "Apply changes $name to scale 1.5 in the compositor (read back from wlr-randr)" \
	[expr {$::display::sheet == 1 && [dict get [display::out $name] scale] == 1.5}]
display::revert
settle {$::display::snapshot eq {} && $::display::loaded == 1 && [dict get [display::out $name] scale] == 1}
check "the revert puts $name back at scale 1" [expr {[dict get [display::out $name] scale] == 1}]
file delete -force $home
exit [expr {$fails > 0}]
