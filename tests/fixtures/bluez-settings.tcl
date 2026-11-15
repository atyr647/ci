# bluez-settings.tcl (fixture) - a BlueZ stand-in for Settings → Bluetooth. It owns org.bluez on DBUS_SYSTEM_BUS_ADDRESS (a
# private bus in the test) and answers as the board's state: one adapter "Ribbon Laptop" (powered, not scanning), and
# six objects: headphones (paired, connected, trusted, battery 76), a mouse (paired, not connected), a keyboard and a
# phone nearby (unpaired, named), and a nameless device nearby (left out of the list).
#
# Pairing: the keyboard asks for a passkey: its Pair calls the agent's DisplayPasskey (123456) and waits for the
# test's control Finish (then Pair succeeds, and the device is paired) or CancelPairing. The phone asks for a
# confirmation: its Pair calls the agent's RequestConfirmation (654321) and succeeds or fails by the agent's answer.
# The agent is the client that called RegisterAgent (its sender). The control interface is at /org/ribbon/bluezTest
# (org.ribbon.BlueZTest): Type PATH N (the agent's DisplayPasskey with N digits typed), Finish PATH.
#
# Every action is logged, one tab-separated line each, to the file BT_LOG (appended): "power 0|1", "scan 0|1", "connect
# PATH", "disconnect PATH", "trusted PATH 0|1", "forget PATH", "pair PATH", "passkey PATH CODE N", "confirm PATH CODE",
# "answer PATH ok|error NAME", "paired PATH", "cancel PATH", "agent SENDER".
lappend auto_path [file join [file dirname [file normalize [info script]]] .. .. srcpkgs ribbon-desktop files]
package require ribbon::dbus
fconfigure stdout -buffering line
set LOG $::env(BT_LOG)
proc logline {args} {
	global LOG
	set fh [open $LOG a]
	puts $fh [join $args "\t"]
	close $fh
}

set AD /org/bluez/hci0
set KBD /org/bluez/hci0/dev_AA_BB_CC_00_00_03
set PHONE /org/bluez/hci0/dev_AA_BB_CC_00_00_04
set disc 0
set agentsender ""
set agentpath ""
array set pendingPair {}

# the property signatures of a device
array set SIGS {Address s Name s Alias s Icon s Adapter o Paired b Connected b Trusted b RSSI n}

set bus [ribbon::dbus::connect system]

# ---- the adapter ------------------------------------------------------------------
proc PoweredSet {m v} { logline power $v }
proc StartDisc {m} {
	global bus AD disc
	if {$disc} { throw {DBUS org.bluez.Error.InProgress} "Operation already in progress" }
	set disc 1
	$bus set $AD org.bluez.Adapter1 Discovering 1
	logline scan 1
}
proc StopDisc {m} {
	global bus AD disc
	if {!$disc} { throw {DBUS org.bluez.Error.Failed} "No discovery started" }
	set disc 0
	$bus set $AD org.bluez.Adapter1 Discovering 0
	logline scan 0
}
proc RemoveDev {m dev} {
	global bus
	logline forget $dev
	$bus unexport $dev
}
$bus export $AD org.bluez.Adapter1 [list \
	property Address s read [list -value 00:1A:7D:DA:71:13] \
	property Alias s read [list -value {Ribbon Laptop}] \
	property Powered b readwrite [list -value 1 -set PoweredSet] \
	property Discovering b read [list -value 0] \
	method StartDiscovery "" "" StartDisc \
	method StopDiscovery "" "" StopDisc \
	method RemoveDevice o "" RemoveDev]

# ---- the devices ------------------------------------------------------------------
proc TrustedSet {m v} { logline trusted [dict get $m path] $v }
proc DevConnect {m} {
	global bus
	set p [dict get $m path]
	$bus set $p org.bluez.Device1 Connected 1
	logline connect $p
}
proc DevDisconnect {m} {
	global bus
	set p [dict get $m path]
	$bus set $p org.bluez.Device1 Connected 0
	logline disconnect $p
}
proc Ignore args {}

# Pair: the keyboard asks for its passkey, the phone for a confirmation; both are answered later (deferred).
proc PairDev {m} {
	global bus pendingPair agentsender agentpath KBD PHONE
	set p [dict get $m path]
	logline pair $p
	if {$p eq $KBD} {
		$bus defer $m
		set pendingPair($p) $m
		$bus call -command Ignore $agentsender $agentpath org.bluez.Agent1 DisplayPasskey ouq $p 123456 0
		logline passkey $p 123456 0
	} elseif {$p eq $PHONE} {
		$bus defer $m
		set pendingPair($p) $m
		$bus call -command [list ConfirmDone $p] $agentsender $agentpath org.bluez.Agent1 RequestConfirmation ou $p 654321
		logline confirm $p 654321
	} else {
		throw {DBUS org.bluez.Error.Failed} "nothing to pair with this device"
	}
}
# The agent's answer to RequestConfirmation: ok pairs the phone; an error is the Pair's error.
proc ConfirmDone {p status values} {
	global bus pendingPair
	if {![info exists pendingPair($p)]} return
	set pm $pendingPair($p)
	unset pendingPair($p)
	if {$status eq "ok"} {
		logline answer $p ok
		$bus set $p org.bluez.Device1 Paired 1
		logline paired $p
		$bus reply $pm
	} else {
		logline answer $p error [lindex $values 0]
		$bus error $pm [lindex $values 0] [lindex $values 1]
	}
}
proc CancelPairing {m} {
	global bus pendingPair
	set p [dict get $m path]
	logline cancel $p
	if {[info exists pendingPair($p)]} {
		set pm $pendingPair($p)
		unset pendingPair($p)
		$bus error $pm org.bluez.Error.AuthenticationCanceled "Authentication Canceled"
	}
}

proc export_device {p props} {
	global bus SIGS
	set spec {}
	dict for {k v} $props {
		if {$k eq "Trusted"} {
			lappend spec property $k $SIGS($k) readwrite [list -value $v -set TrustedSet]
		} else {
			lappend spec property $k $SIGS($k) read [list -value $v]
		}
	}
	lappend spec method Connect "" "" DevConnect method Disconnect "" "" DevDisconnect \
		method Pair "" "" PairDev method CancelPairing "" "" CancelPairing
	$bus export $p org.bluez.Device1 $spec
}

set ADAPTER /org/bluez/hci0
export_device /org/bluez/hci0/dev_AA_BB_CC_00_00_01 [dict create Address AA:BB:CC:00:00:01 Name WH-1000XM4 \
	Alias Headphones Icon audio-headset Adapter $ADAPTER Paired 1 Connected 1 Trusted 1]
$bus export /org/bluez/hci0/dev_AA_BB_CC_00_00_01 org.bluez.Battery1 [list property Percentage y read [list -value 76]]
export_device /org/bluez/hci0/dev_AA_BB_CC_00_00_02 [dict create Address AA:BB:CC:00:00:02 Name {MX Anywhere 2} \
	Alias {MX Anywhere 2} Icon input-mouse Adapter $ADAPTER Paired 1 Connected 0 Trusted 1]
export_device $KBD [dict create Address AA:BB:CC:00:00:03 Name {Keychron K2} Alias {Keychron K2} \
	Icon input-keyboard Adapter $ADAPTER Paired 0 Connected 0 Trusted 0 RSSI -48]
export_device $PHONE [dict create Address AA:BB:CC:00:00:04 Name {Pixel Phone} Alias {Pixel Phone} \
	Icon phone Adapter $ADAPTER Paired 0 Connected 0 Trusted 0 RSSI -40]
# a nameless device nearby: BlueZ's alias is its address, and it has no Name
export_device /org/bluez/hci0/dev_AA_BB_CC_00_00_05 [dict create Address AA:BB:CC:00:00:05 Alias AA:BB:CC:00:00:05 \
	Icon audio-speakers Adapter $ADAPTER Paired 0 Connected 0 Trusted 0 RSSI -30]

# ---- the pairing agent's manager: the client that registers is the agent ----------------
proc RegisterAgent {m agent cap} {
	global agentsender agentpath
	set agentsender [dict get $m sender]
	set agentpath $agent
	logline agent $agentsender
}
$bus export /org/bluez org.bluez.AgentManager1 [list method RegisterAgent os "" RegisterAgent]

# ---- the test's control --------------------------------------------------------------
proc TypeDigits {m p n} {
	global bus agentsender agentpath
	logline passkey $p 123456 $n
	$bus call -command Ignore $agentsender $agentpath org.bluez.Agent1 DisplayPasskey ouq $p 123456 $n
}
proc FinishPair {m p} {
	global bus pendingPair
	if {![info exists pendingPair($p)]} { throw {DBUS org.ribbon.Error.NoPairing} "nothing is pairing with $p" }
	set pm $pendingPair($p)
	unset pendingPair($p)
	$bus set $p org.bluez.Device1 Paired 1
	logline paired $p
	$bus reply $pm
}
$bus export /org/ribbon/bluezTest org.ribbon.BlueZTest [list \
	method Type oq "" TypeDigits \
	method Finish o "" FinishPair]

$bus manage /
if {[$bus request org.bluez] ne "primary"} { puts "error cannot own the name"; exit 1 }
puts ready
vwait forever
