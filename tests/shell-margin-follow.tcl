# shell-margin-follow.tcl - tclsh: labwc's margin layer (shell/mod-margin.tcl) names the main display whenever
# display.tcl's main output changes, also when the new main output has the same rectangle as the old one (the main
# monitor unplugged, and the other one laid out where it was). tests/steps.d/46-shell-multimonitor.sh.
#   tclsh8.6 tests/shell-margin-follow.tcl SHELLDIR SCRATCH
lassign $argv dir tmp
set failed 0
proc check {what cond why} {
	global failed
	if {$cond} { puts "  ok   $what" } else { incr failed; puts "  FAIL $what: $why" }
}
set ::env(XDG_CONFIG_HOME) $tmp/cfg
file mkdir $tmp/cfg/ribbon
set ::env(RIBBON_MARGIN_RC) $tmp/margin-rc.xml
set ::env(RIBBON_MARGIN_RELOAD) ""
catch {file delete $tmp/margin-rc.xml}
unset -nocomplain ::env(RIBBON_SCREEN)
set ::env(WAYLAND_DISPLAY) none
source -encoding utf-8 [file join $dir display.tcl]
proc display::screen {} { list 3840 1080 }
proc display::randr_argv {} { return {} }
proc json {outs} {
	set l {}
	foreach {n x} $outs {
		lappend l "{\"name\": \"$n\", \"enabled\": true, \"modes\": \[{\"width\": 1920, \"height\": 1080, \"current\": true}\], \"position\": {\"x\": $x, \"y\": 0}, \"scale\": 1.0}"
	}
	return "\[[join $l ,]\]"
}
proc slurp {f} { if {[catch {open $f} fh]} { return "" }; set t [read $fh]; close $fh; return $t }
set fh [open $tmp/cfg/ribbon/display.conf w]; puts $fh "main DP-1"; close $fh
display::take [json {DP-1 0 HDMI-1 1920}]
source -encoding utf-8 [file join $dir mod-margin.tcl]
update
check "the margin names the main output" [string match {*output="DP-1"*} [slurp $tmp/margin-rc.xml]] [slurp $tmp/margin-rc.xml]
# DP-1 is unplugged; the compositor lays HDMI-1 out at 0,0, where DP-1 was: same rectangle, another output
if {[display::take [json {HDMI-1 0}]]} { display::changed }
# what the shell does next: its watch reads the outputs again 10 s on
after 50 {set done 1}; vwait done
check "the margin follows the main output to one of the same size and place" \
	[string match {*output="HDMI-1"*} [slurp $tmp/margin-rc.xml]] [slurp $tmp/margin-rc.xml]
if {$failed} { puts "shell margin follow: $failed failed"; exit 1 }
puts "shell margin follow: all checks passed"
