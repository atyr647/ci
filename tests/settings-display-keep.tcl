# settings-display-keep.tcl - Settings → Display's Keep tells the shell (W2): display.conf is written, then
# `ribbon-shell-ctl display` runs (a stand-in on PATH logs it), and the kanshi profile written for the layout carries
# `exec ribbon-shell-ctl display`, so a layout kanshi puts on later moves the bars as well.
# Run: tclsh8.6 tests/settings-display-keep.tcl DIR LOG (DIR = the files/ folder, LOG = the stand-in's log).
set D [lindex $argv 0]
set log [lindex $argv 1]
set fails 0
proc check {what ok {why ""}} {
	global fails
	if {$ok} { puts "  ok   $what" } else { puts "  FAIL $what${why}"; incr fails }
}
proc slurp {f} { if {[catch {open $f} fh]} { return "" }; set t [read $fh]; close $fh; return $t }
namespace eval page { proc draw {} {} }
set home [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] ribbon-display-keep-[pid]]
file mkdir $home
set ::env(HOME) $home
set ::env(XDG_CONFIG_HOME) [file join $home cfg]
source [file join $D apps settings display.tcl]

set fh [open [file join [file dirname [file dirname [file dirname $D]]] tests fixtures display-outputs.json]]
set ::display::outs [display::parse [read $fh]]
close $fh
set ::display::loaded 1
set ::display::main eDP-1

# the user's own kanshi profile is kept, and has no exec of ours
file mkdir [file join $home cfg kanshi]
set fh [open [file join $home cfg kanshi config] w]
puts $fh "profile docked \{\n\toutput DP-1 enable\n\}"
close $fh

display::keep
# the shell is told in the background: wait (up to 5 s) for the stand-in
set t [clock milliseconds]
while {[string first "ribbon-shell-ctl display" [slurp $log]] < 0 && [clock milliseconds] - $t < 5000} {
	after 20 {set ::tick 1}; vwait ::tick
}
check "Keep writes the main display to display.conf" [expr {[display::main_conf] eq "eDP-1"}]
check "Keep runs `ribbon-shell-ctl display`, so the bars move at once" [expr {[string first "ribbon-shell-ctl display" [slurp $log]] >= 0}] ": log [slurp $log]"
set kc [slurp [file join $home cfg kanshi config]]
set ours ""
regexp {profile ribbon-[^\n]* \{\n(.*?)\n\}} $kc -> ours
check "the kanshi profile ends with `exec ribbon-shell-ctl display`" [expr {[lindex [split $ours \n] end] eq "\texec ribbon-shell-ctl display"}] ": $kc"
check "the user's own profile is kept, without it" [expr {[string first "profile docked \{\n\toutput DP-1 enable\n\}" $kc] >= 0}] ": $kc"
display::keep
set kc [slurp [file join $home cfg kanshi config]]
check "keeping again leaves one exec line, in one ribbon profile" \
	[expr {[regexp -all {exec ribbon-shell-ctl display} $kc] == 1 && [regexp -all {profile ribbon-} $kc] == 1}] ": $kc"
file delete -force $home
if {$fails} { puts "settings display keep: $fails failed"; exit 1 }
puts "settings display keep: all checks passed"
