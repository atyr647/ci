# standin.tcl - TEST TOOL (tests/test-greeter-labwc.sh): the greeter's window as ui.tcl makes it (the screen's size
# at +0+0, fullscreen asked for), in one flat colour, run by ribbon-greeter in place of main.tcl. $env(STANDIN_DIR):
# it writes "mapped" there once it is on screen, "closed" if the compositor asks it to close (then exits 1, as
# the greeter would go away), and exits 0 when a file named "quit" appears there.
set dir $env(STANDIN_DIR)
proc note {what} { set f [open [file join $::dir $what] w]; puts $f [clock milliseconds]; close $f }
set W [winfo screenwidth .]; set H [winfo screenheight .]
wm title . "Ribbon login"
wm geometry . ${W}x${H}+0+0
catch {wm attributes . -fullscreen 1}
. configure -background #123456 -cursor left_ptr
wm protocol . WM_DELETE_WINDOW { note closed; exit 1 }
bind . <Map> { after 300 { note mapped } }
proc poll {} { if {[file exists [file join $::dir quit]]} { exit 0 }; after 100 poll }
poll
