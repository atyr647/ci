# bluez.tcl (fixture) - a BlueZ stand-in for the shell's Bluetooth panel (U50b). It owns org.bluez on
# DBUS_SYSTEM_BUS_ADDRESS (a private bus in the test) and answers as a board's state: an adapter hci0 (powered), a
# paired and connected headset "Headphones" with a battery of 64%, a paired keyboard that is not connected, and a
# speaker that was found but is not paired (not listed). The object manager is at "/", as BlueZ's is.
# Every change is logged, one tab-separated line each, to BLUEZ_LOG (appended): "power 0|1", "connect PATH",
# "disconnect PATH". Each change is a property change, so it emits PropertiesChanged as BlueZ's does.
lappend auto_path [file join [file dirname [file normalize [info script]]] .. .. srcpkgs ribbon-desktop files]
package require ribbon::dbus
fconfigure stdout -buffering line
set LOG $::env(BLUEZ_LOG)
proc logline {args} {
	global LOG
	set fh [open $LOG a]
	puts $fh [join $args "\t"]
	close $fh
}

set A /org/bluez/hci0
set HEAD ${A}/dev_AA_BB_CC_DD_EE_FF
set KEYB ${A}/dev_11_22_33_44_55_66
set SPKR ${A}/dev_99_88_77_66_55_44
set bus [ribbon::dbus::connect system]

$bus export $A org.bluez.Adapter1 [list \
	property Address s read {-value 00:11:22:33:44:55} \
	property Alias s read {-value ribbon} \
	property Powered b readwrite {-value 1 -set {apply {{m v} {logline power [expr {$v ? 1 : 0}]}}}} ]

# A device: its properties, and Connect and Disconnect (they change Connected, which emits)
proc devexport {path mac alias icon paired conn bat} {
	global bus
	set spec [list \
		property Address s read [list -value $mac] \
		property Alias s read [list -value $alias] \
		property Name s read [list -value $alias] \
		property Icon s read [list -value $icon] \
		property Paired b read [list -value $paired] \
		property Connected b read [list -value $conn] \
		property Adapter o read [list -value /org/bluez/hci0] \
		method Connect "" "" BzConnect \
		method Disconnect "" "" BzDisconnect]
	$bus export $path org.bluez.Device1 $spec
	if {$bat ne ""} {
		$bus export $path org.bluez.Battery1 [list property Percentage y read [list -value $bat]]
	}
}
devexport $HEAD AA:BB:CC:DD:EE:FF Headphones audio-headset 1 1 64
devexport $KEYB 11:22:33:44:55:66 Keyboard input-keyboard 1 0 ""
devexport $SPKR 99:88:77:66:55:44 Speaker audio-card 0 0 ""

proc BzConnect {msg} {
	global bus
	set p [dict get $msg path]
	logline connect $p
	$bus set $p org.bluez.Device1 Connected 1
	return
}
proc BzDisconnect {msg} {
	global bus
	set p [dict get $msg path]
	logline disconnect $p
	$bus set $p org.bluez.Device1 Connected 0
	return
}

$bus manage /

if {[$bus request org.bluez] ne "primary"} { puts "error cannot own the name"; exit 1 }
puts ready
vwait forever
