# settings-input-live.tcl - the driver of tests/steps.d/65-settings-input-live.sh: apply settings through the real
# backend (apps/settings/input.tcl), which writes input.conf, generates labwc's files and signals labwc itself.
#   tclsh8.6 tests/settings-input-live.tcl FILES-DIR KEY=VALUE ...     (layout1=us(dvorak) and layout2=de set a layout)
# Exits 1 when a change is refused. Returns once the reconfigure has been sent.
set args [lassign $argv D]
source -encoding utf-8 [file join $D apps settings input.tcl]
set bad 0
foreach a $args {
	set i [string first = $a]
	set k [string range $a 0 [expr {$i - 1}]]; set v [string range $a [expr {$i + 1}] end]
	switch -- $k {
		layout1 { set ok [inp::set_layout 1 $v] }
		layout2 { set ok [inp::set_layout 2 $v] }
		default { set ok [inp::put $k $v] }
	}
	if {!$ok} { puts stderr "refused: $a ($inp::error)"; set bad 1 }
}
set end [expr {[clock milliseconds] + 3000}]
while {$inp::pending ne "" && [clock milliseconds] < $end} { after 20 {set ::tick 1}; vwait ::tick }
exit $bad
