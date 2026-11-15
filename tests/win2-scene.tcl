# win2-scene.tcl - the standalone file window (properties/win2.tcl) on one or more files or
# folders, as RIBBON_PROPERTIES_SCENE. RIBBON_WIN2_PATH is the item, or several separated by |;
# RIBBON_WIN2_EDIT=1 opens the edit view on the (one) item; RIBBON_PROPERTIES_SHOT (optional)
# takes a screenshot and quits. Prints one line per check; exits 1 when the window did not draw.
proc bgerror {msg} { puts stderr "$msg\n$::errorInfo"; exit 1 }
set paths [split $::env(RIBBON_WIN2_PATH) |]
if {[catch {win2::open $paths $app::win 1} err]} { puts "  FAIL win2 did not draw: $err\n$::errorInfo"; exit 1 }
if {[info exists ::env(RIBBON_WIN2_EDIT)] && $::env(RIBBON_WIN2_EDIT)} {
	inspector::edit_begin [facts::of [lindex $paths 0]]
	win2::draw
}
update
set n [llength [$ui::cv find withtag page]]
if {$n < 1} { puts "  FAIL win2 drew nothing"; exit 1 }
puts "  ok   win2 drawn for [file tail [lindex $paths 0]] ([llength $paths] item(s), $n items)"
if {[info exists ::env(RIBBON_PROPERTIES_SHOT)]} {
	after 400 [list apply {{out} { exec import -window root $out; exit 0 }} $::env(RIBBON_PROPERTIES_SHOT)]
} else {
	after 200 {exit 0}
}
