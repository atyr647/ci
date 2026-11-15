# polkit-authority.tcl - a stand-in for polkitd's Authority, for the services that ask it (tests/kitd.tcl): it owns
# org.freedesktop.PolicyKit1 on DBUS_SYSTEM_BUS_ADDRESS (a private bus) and answers CheckAuthorization from the file
# $POLKIT_FIX/answer: "yes", "no" or "challenge" (not authorized, authentication would be needed); "none" never answers
# (the call times out). It leaves when its stdin closes. Each call is logged to $POLKIT_FIX/calls, one Tcl list per line:
#   {SENDER SUBJECT-KIND SUBJECT-NAME ACTION FLAGS}
lappend auto_path [file join [file dirname [file normalize [info script]]] .. .. srcpkgs ribbon-desktop files]
package require ribbon::dbus
set fix $env(POLKIT_FIX)
set bus [ribbon::dbus::connect system]

proc Check {msg subject action details flags cancel} {
	global fix
	set s [ribbon::dbus::strip (sa{sv}) $subject]
	set name [expr {[dict exists [lindex $s 1] name] ? [dict get [lindex $s 1] name] : ""}]
	set ch [open $fix/calls a]; puts $ch [list [dict get $msg sender] [lindex $s 0] $name $action $flags]; close $ch
	set answer no
	catch {set f [open $fix/answer]; set answer [string trim [read $f]]; close $f}
	switch -- $answer {
		yes { return [list 1 0 {}] }
		challenge { return [list 0 1 {}] }
		none { $::bus defer $msg; return }
		default { return [list 0 0 {}] }
	}
}
$bus export /org/freedesktop/PolicyKit1/Authority org.freedesktop.PolicyKit1.Authority {
	method CheckAuthorization (sa{sv})sa{ss}us (bba{ss}) Check
}
if {[$bus request org.freedesktop.PolicyKit1] ne "primary"} { puts "error: cannot own the name"; exit 1 }
puts ready
flush stdout
# the test's pipe closing (it ended, or died) ends this too
fileevent stdin readable {if {[gets stdin line] < 0} exit}
vwait forever
