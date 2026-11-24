# rbnalpha: see-through rounded windows, rounded widgets, fast blur.
# Installed in /usr/lib/ribbon/rbnalpha; lappend auto_path /usr/lib/ribbon.
# From the source tree, RBNALPHA_LIB names a librbnalpha.so built elsewhere.
# Without the C library the Tcl side still loads (rbn::native is 0): plain
# rectangular windows, and pictures and blurs in Tcl.
package ifneeded rbnalpha 1.0 [list apply {{dir} {
	set so [file join $dir librbnalpha[info sharedlibextension]]
	if {![file exists $so] && [info exists ::env(RBNALPHA_LIB)]} { set so $::env(RBNALPHA_LIB) }
	if {[file exists $so] && ![info exists ::env(RBNALPHA_NOC)]} { load $so Rbnalpha }
	source -encoding utf-8 [file join $dir rbnalpha.tcl]
	package provide rbnalpha 1.0
}} $dir]
