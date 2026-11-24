# A small Tk app, the kit the start-up test runs (tests/startup.tcl): a window with the usual
# widgets, its code and an icon loaded from the kit, gone as soon as it has been drawn once.
set here [file dirname [file normalize [info script]]]
source [file join $here lib ui.tcl]
ui::build . [file join $here share hello.png]
tkwait visibility .
update
exit 0
