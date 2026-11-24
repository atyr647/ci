# warm.tcl - the Appearance app's background job: lay a picture out at the
# screen's size and blur it, into the wallpaper cache the greeter shares
# (shell/wall.tcl: wall::prepare, wall::blurred), so neither the app nor
# the login screen waits for it.
#   wish warm.tcl FILE W H FIT BG BLUR
wm withdraw .
set appdir [file dirname [file normalize [info script]]]
foreach d [list [file join [file dirname $appdir] shell] /usr/lib/ribbon/shell] {
	if {[file exists [file join $d wall.tcl]]} { source -encoding utf-8 [file join $d raster.tcl]; source -encoding utf-8 [file join $d wall.tcl]; break }
}
lassign $argv f W H fit bg blur
if {[catch {
	set base [wall::prepare $f $W $H $fit $bg]
	if {$blur > 0} { wall::blurred $base $blur }
} err]} { puts stderr "appearance: $f: $err" }
exit
