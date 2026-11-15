# viewer-decode.tcl - stage::load on one file per format, in wish (RIBBON_VIEWER_DECODE=FILE):
# prints "size W H" for the native size the stage uses and "view W H" for a crop.
set app [file join [file dirname [file dirname [file normalize [info script]]]] srcpkgs ribbon-desktop files apps viewer]
package require Tk
source -encoding utf-8 [file join $app zoom.tcl]
source -encoding utf-8 [file join $app nav.tcl]
source -encoding utf-8 [file join $app .. .. shell wall.tcl]
source -encoding utf-8 [file join $app stage.tcl]
set f $::env(RIBBON_VIEWER_DECODE)
if {![stage::load $f]} { puts "load FAIL [stage::decoder $f]"; exit 1 }
lassign [stage::size] w h
puts "size $w $h"
lassign [stage::view 0 0 400 300 0 0 400 300] p x y
puts "view [image width $p] [image height $p]"
exit 0
