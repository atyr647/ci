# upower.tcl (fixture) - a UPower stand-in for Settings → Power (U14). It owns org.freedesktop.UPower on
# DBUS_SYSTEM_BUS_ADDRESS (a private bus in the test) and answers as the board's state: a built-in battery at 82 %
# with 3 h 40 min to empty, health 91 %, 312 cycles, on the AC adapter (OnBattery 0). OnBattery is writable here (a
# test hook: the real property is read only) and each change is logged, one line, to the file UPOWER_LOG (appended):
# "onbattery 0|1". Stand-in only: the real UPower has no such setter.
lappend auto_path [file join [file dirname [file normalize [info script]]] .. .. srcpkgs ribbon-desktop files]
package require ribbon::dbus
fconfigure stdout -buffering line
set LOG $::env(UPOWER_LOG)
proc logline {args} {
	global LOG
	set fh [open $LOG a]
	puts $fh [join $args "\t"]
	close $fh
}

set UP /org/freedesktop/UPower
set DEV ${UP}/devices/DisplayDevice

set bus [ribbon::dbus::connect system]

proc GetDisplayDevice {msg} { global DEV; return $DEV }

$bus export $UP org.freedesktop.UPower {
	method GetDisplayDevice "" o GetDisplayDevice
	property OnBattery b readwrite {-value 0 -set {apply {{m v} {logline onbattery [expr {$v ? 1 : 0}]}}}}
	property LidIsClosed b read {-value 0}
}

# The battery: a Li-ion pack, the level, the time left, its capacity against the design, and the cycles.
$bus export $DEV org.freedesktop.UPower.Device {
	property Type u read {-value 2}
	property IsPresent b read {-value 1}
	property Percentage d read {-value 82.0}
	property State u read {-value 2}
	property TimeToEmpty x read {-value 13200}
	property TimeToFull x read {-value 0}
	property Capacity d read {-value 91.0}
	property ChargeCycles i read {-value 312}
}

if {[$bus request org.freedesktop.UPower] ne "primary"} { puts "error cannot own the name"; exit 1 }
puts ready
vwait forever
