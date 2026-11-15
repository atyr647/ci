# client.tcl - an app asking through appearance/chooser.tcl (tests/steps.d/62-chooser.sh): wish client.tcl KIND ARGS...
# prints what chooser::KIND answered, as a Tcl list ({} when cancelled).
proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }
encoding system utf-8
fconfigure stdout -encoding utf-8
source -encoding utf-8 $::env(CHOOSER_LIB)
wm geometry . 600x400+100+100
update
set kind [lindex $argv 0]
# the app's own field, with the keys, and a shortcut on its window
entry .e
pack .e
bind . <Control-s> { set ::shortcut 1 }
set ::shortcut 0
focus -force .e
update
if {[info exists ::env(CHOOSER_HELD)]} {
	# while the chooser is open: the app's window given the keyboard back (as a click on it does: Tk puts the keys
	# where the window last had them) and typed at, then what holds the window written where the chooser's flow reads it
	after 300 {
		catch {focus -force [focus -lastfor .]}
		update
		set w [focus]
		if {$w ne ""} {
			event generate $w <KeyPress> -keysym a
			event generate $w <KeyPress> -keysym s -state 4
		}
		update
		set f [open $::env(CHOOSER_HELD) w]; puts -nonewline $f [grab current]; close $f
	}
}
set r [chooser::$kind -parent . {*}[lrange $argv 1 end]]
puts [list $r]
puts "grab after: [grab current]"
puts "typed while held: [.e get] shortcut: $::shortcut keys after: [focus -lastfor .]"
if {[info exists ::typevar]} { puts "type: $::typevar" }
exit 0
