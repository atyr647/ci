# ppd.tcl (fixture) - a power-profiles-daemon stand-in for Settings → Power (U14). It owns net.hadess.PowerProfiles on
# DBUS_SYSTEM_BUS_ADDRESS (a private bus in the test) with the three profiles and balanced active (the board). Each
# change of ActiveProfile is logged, one line, to the file PPD_LOG (appended): "profile NAME". A name it does not
# know is refused, as the daemon refuses one.
lappend auto_path [file join [file dirname [file normalize [info script]]] .. .. srcpkgs ribbon-desktop files]
package require ribbon::dbus
fconfigure stdout -buffering line
set LOG $::env(PPD_LOG)
proc logline {args} {
	global LOG
	set fh [open $LOG a]
	puts $fh [join $args "\t"]
	close $fh
}

set PP /net/hadess/PowerProfiles
set I net.hadess.PowerProfiles

set bus [ribbon::dbus::connect system]

proc ProfileSet {m v} {
	if {$v ni {power-saver balanced performance}} {
		throw {DBUS org.freedesktop.DBus.Error.InvalidArgs} "no such profile $v"
	}
	logline profile $v
}

$bus export $PP $I {
	property ActiveProfile s readwrite {-value balanced -set {apply {{m v} {ProfileSet $m $v}}}}
	property PerformanceDegraded s read {-value {}}
	property Profiles aa{sv} read {-value {{Profile {s power-saver} Driver {s placeholder}} {Profile {s balanced} Driver {s placeholder}} {Profile {s performance} Driver {s placeholder}}}}
}

if {[$bus request $I] ne "primary"} { puts "error cannot own the name"; exit 1 }
puts ready
vwait forever
