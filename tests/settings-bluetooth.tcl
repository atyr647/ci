# settings-bluetooth.tcl - Settings → Bluetooth's BlueZ client (apps/settings/bt.tcl) against the BlueZ stand-in
# (tests/fixtures/bluez-settings.tcl) on a private system bus, with no display. Run by tests/steps.d/55-settings-bluetooth.sh
# with DBUS_SYSTEM_BUS_ADDRESS (the private bus), BT_LOG (the stand-in's log) and XDG_CONFIG_HOME (a scratch folder):
#   tclsh8.6 tests/settings-bluetooth.tcl FILES
# FILES is the srcpkgs/ribbon-desktop/files folder. Prints one line per check; exits non-zero when a check fails.
set D [lindex $argv 0]
set LOG $::env(BT_LOG)
set fails 0
proc check {what ok} {
	global fails
	if {$ok} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}

source [file join $D apps settings bt.tcl]

# Run the event loop until COND (a script) is true and no read is running; fail after 8 s.
proc settle {{cond 1}} {
	set t [clock milliseconds]
	while {1} {
		if {$bt::busy == 0 && [uplevel #0 [list expr $cond]]} { return 1 }
		if {[clock milliseconds] - $t > 8000} { return 0 }
		update
		after 10
	}
}

# The stand-in's log: its lines (tab-separated).
proc logged {} {
	set out {}
	if {[catch {open $::env(BT_LOG)} fh]} { return {} }
	foreach line [split [read $fh] \n] { if {$line ne ""} { lappend out $line } }
	close $fh
	set out
}
proc logged_has {line} { expr {[lsearch -exact [logged] $line] >= 0} }

# A device of the model by its path, and one of its fields ("" when it is not listed).
proc dev {path} {
	foreach d [dict get [bt::model] devices] { if {[dict get $d path] eq $path} { return $d } }
	return {}
}
proc field {path key} {
	set d [dev $path]
	if {[dict size $d]} { return [dict get $d $key] }
	return ""
}

set AD /org/bluez/hci0
set H /org/bluez/hci0/dev_AA_BB_CC_00_00_01
set M /org/bluez/hci0/dev_AA_BB_CC_00_00_02
set K /org/bluez/hci0/dev_AA_BB_CC_00_00_03
set P /org/bluez/hci0/dev_AA_BB_CC_00_00_04
set NOPE /org/bluez/hci0/dev_00_00_00_00_00_00

# ---- the pure helpers (no bus) ----------------------------------------------------
check "the model before any read is well formed" [expr {
	[dict get [bt::model] available] == 0 && [dict get [bt::model] powered] == 0 &&
	[dict get [bt::model] discovering] == 0 && [dict get [bt::model] alias] eq "" &&
	[dict get [bt::model] adapter] eq "" && [dict get [bt::model] devices] eq ""}]
check "and its subtitle is no adapter" [expr {[bt::subtitle] eq "No Bluetooth adapter"}]

set kinds {audio-headset headphones audio-headphones headphones audio-card headphones input-mouse mouse
	input-keyboard kbd phone phone input-gaming pad video-display monitor audio-speakers speaker}
foreach {icon want} $kinds {
	check "the kind of icon $icon is $want" [expr {[bt::kind $icon] eq $want}]
}
check "a device with no icon: a headset class is headphones" [expr {[bt::kind "" 1048] eq "headphones"}]
check "a keyboard class is a keyboard" [expr {[bt::kind "" 1344] eq "kbd"}]
check "a mouse class is a mouse" [expr {[bt::kind "" 1424] eq "mouse"}]
check "a phone class is a phone" [expr {[bt::kind "" 512] eq "phone"}]
check "an unknown device is a bt device" [expr {[bt::kind "" 0] eq "bt" && [bt::kind mystery-icon] eq "bt"}]
check "kind labels" [expr {[bt::kind_label headphones] eq "Headphones" && [bt::kind_label kbd] eq "Keyboard" &&
	[bt::kind_label pad] eq "Controller" && [bt::kind_label speaker] eq "Speaker" && [bt::kind_label bt] eq "Device"}]

# a board's objects: one adapter, devices in its name
proc fake {name paired connected rssi} {
	set d [dict create Address $name Name $name Alias $name Adapter /a Paired $paired Connected $connected Trusted $paired]
	if {$rssi ne ""} { dict set d RSSI $rssi }
	dict create org.bluez.Device1 $d
}
set objs [dict create /a [dict create org.bluez.Adapter1 [dict create Powered 1 Alias {Ribbon Laptop} Discovering 0]]]
dict set objs /a/d1 [fake Zeta 1 1 ""]
dict set objs /a/d2 [fake Alpha 1 0 ""]
dict set objs /a/d3 [fake Near 0 0 -60]
dict set objs /a/d4 [fake Far 0 0 -80]
dict set objs /a/d5 [fake Strong 0 0 -40]
dict set objs /a/d6 [dict create org.bluez.Device1 [dict create Address AA:00 Alias AA:00 Adapter /a Paired 0 Connected 0 RSSI -20]]
dict set objs /a/d7 [dict create org.bluez.Device1 [dict create Address BB Name Elsewhere Adapter /other Paired 1 Connected 1]]
set m [bt::summarize $objs]
check "the model's order: connected first, then paired by name, then the nearby by signal (nameless and other adapters left out)" \
	[expr {[lmap d [dict get $m devices] {dict get $d name}] eq {Zeta Alpha Strong Near Far}}]
check "the adapter's fields" [expr {[dict get $m available] && [dict get $m powered] && [dict get $m alias] eq {Ribbon Laptop} &&
	[dict get $m adapter] eq "/a"}]
check "the subtitle counts connected devices" [expr {[bt::subtitle_of $m] eq "1 connected"}]
check "the subtitle when the radio is off" [expr {[bt::subtitle_of [dict replace $m powered 0]] eq "Off"}]
check "the subtitle when nothing is connected" [expr {[bt::subtitle_of [bt::summarize [dict create /a [dict create org.bluez.Adapter1 {Powered 1}]]]] eq "On"}]

# ---- the settings file -----------------------------------------------------------------
set conf [bt::conf_file]
check "the settings file is in the config folder" [expr {$conf eq [file join $::env(XDG_CONFIG_HOME) ribbon bluetooth.conf]}]
check "no battery in the bar at first" [expr {![bt::bar_battery AA:BB:CC:00:00:01]}]
file mkdir [file dirname $conf]
set fh [open $conf w]; puts $fh "# kept\nFOO=bar"; close $fh
bt::set_bar_battery AA:BB:CC:00:00:01 1
check "a device's battery is set for the bar" [bt::bar_battery AA:BB:CC:00:00:01]
bt::set_bar_battery aa:bb:cc:00:00:01 1
bt::set_bar_battery AA:BB:CC:00:00:02 1
check "two addresses, once each" [expr {[bt::bar_battery AA:BB:CC:00:00:02] && [llength [bt::bar_list]] == 2}]
bt::set_bar_battery AA:BB:CC:00:00:01 0
check "a device's battery is removed from the bar" [expr {![bt::bar_battery AA:BB:CC:00:00:01] && [bt::bar_battery AA:BB:CC:00:00:02]}]
set fh [open $conf]; set text [read $fh]; close $fh
check "the other lines of the file are kept" [expr {[string first "FOO=bar" $text] >= 0 && [string first "# kept" $text] >= 0}]
check "the file's temporary copy is gone" [expr {![file exists $conf.tmp]}]
check "the value is upper case, one line" [expr {[regexp -all {BAR_BATTERY=} $text] == 1 && [regexp {BAR_BATTERY=[0-9A-F:]+} $text]}]

# ---- the BlueZ stand-in -------------------------------------------------------------
# the control connection: it calls the stand-in's test interface, as the stand-in is the BlueZ the test drives
set ctl [ribbon::dbus::connect system]
bt::start
check "the first read ends" [settle {$bt::loaded}]
set names {}
foreach d [dict get [bt::model] devices] { lappend names [dict get $d name] }
check "the devices in order: the paired (the connected first), then the nearby by signal; nameless left out" \
	[expr {$names eq {Headphones {MX Anywhere 2} {Pixel Phone} {Keychron K2}}}]
check "the adapter is on, not scanning, with its alias" [expr {[dict get [bt::model] available] && [dict get [bt::model] powered] &&
	![dict get [bt::model] discovering] && [dict get [bt::model] alias] eq {Ribbon Laptop} && [dict get [bt::model] adapter] eq $AD}]
check "the headphones: paired, connected, trusted, battery 76, kind Headphones" [expr {
	[field $H paired] == 1 && [field $H connected] == 1 && [field $H trusted] == 1 &&
	[field $H battery] == 76 && [field $H kind] eq "headphones" && [field $H kindlabel] eq "Headphones"}]
check "the mouse: paired, not connected, no battery" [expr {[field $M paired] == 1 && [field $M connected] == 0 &&
	[field $M battery] eq "" && [field $M kind] eq "mouse"}]
check "the phone nearby: unpaired, its signal, kind Phone" [expr {[field $P paired] == 0 && [field $P rssi] == -40 &&
	[field $P kind] eq "phone" && [field $P kindlabel] eq "Phone"}]
check "the keyboard nearby: kind Keyboard" [expr {[field $K kindlabel] eq "Keyboard" && [field $K rssi] == -48}]
check "the subtitle: one connected" [expr {[bt::subtitle] eq "1 connected"}]

# power
bt::set_power 0
check "the radio turns off" [settle {![dict get [bt::model] powered]}]
check "the subtitle says Off" [expr {[bt::subtitle] eq "Off"}]
check "the stand-in logged the power change" [logged_has "power\t0"]
bt::set_power 1
check "the radio turns on" [settle {[dict get [bt::model] powered]}]

# scan: starting when it runs already is not an error
bt::scan 1
check "a scan starts" [settle {[dict get [bt::model] discovering]}]
set ::changes 0
set bt::onchange {incr ::changes}
set n $::changes
bt::scan 1
settle {$::changes > $n}
check "a second start (already running) is not an error" [expr {$bt::error eq "" && [dict get [bt::model] discovering]}]
bt::scan 0
check "the scan stops" [settle {![dict get [bt::model] discovering]}]

# connect, disconnect, trusted
bt::disconnect $H
check "the headphones disconnect" [settle {[field $H connected] == 0}]
bt::connect $H
check "and connect again" [settle {[field $H connected] == 1}]
bt::connect $M
check "the mouse connects" [settle {[field $M connected] == 1}]
bt::set_trusted $M 0
check "the mouse is untrusted" [settle {[field $M trusted] == 0}]
bt::set_trusted $M 1
check "and trusted again" [settle {[field $M trusted] == 1}]
check "the stand-in logged them" [expr {[logged_has "connect\t$M"] && [logged_has "trusted\t$M\t1"]}]

# an action that fails: its error is shown, and the next action starts with none
bt::connect $NOPE
check "a failing action sets the error" [settle {$bt::error ne ""}]
bt::connect $H
check "the next action clears it" [expr {$bt::error eq ""}]

# pairing by passkey, cancelled
bt::pair $K
check "pairing shows a plain prompt, then the passkey to type" [settle {[dict size $bt::pairing] && [dict get $bt::pairing kind] eq "code"}]
check "the passkey, nothing typed, and the device's name" [expr {[dict get $bt::pairing path] eq $K &&
	[dict get $bt::pairing code] eq "123456" && [dict get $bt::pairing entered] == 0 &&
	[dict get $bt::pairing name] eq "Keychron K2" && [dict get $bt::pairing kindlabel] eq "Keyboard"}]
bt::pair_cancel
check "a cancelled pairing clears the prompt, and is not an error" [settle {[dict size $bt::pairing] == 0}]
check "after a cancel, the keyboard is still unpaired" [expr {[field $K paired] == 0 && $bt::error eq ""}]
check "the stand-in logged the cancel" [logged_has "cancel\t$K"]

# pairing by passkey, to the end: the digits typed on the device are counted
bt::pair $K
check "a second pairing asks for the passkey" [settle {[dict size $bt::pairing] && [dict get $bt::pairing kind] eq "code"}]
$ctl call org.bluez /org/ribbon/bluezTest org.ribbon.BlueZTest Type oq $K 3
check "the digits typed so far" [settle {[dict get $bt::pairing entered] == 3}]
$ctl call org.bluez /org/ribbon/bluezTest org.ribbon.BlueZTest Finish o $K
check "the pairing ends with the prompt cleared" [settle {[dict size $bt::pairing] == 0}]
check "the keyboard ends paired, trusted and connected" [settle {[field $K paired] eq 1 && [field $K connected] eq 1}]
check "and trusted" [expr {[field $K trusted] == 1 && $bt::error eq ""}]

# pairing by confirmation: the answer decides
bt::pair $P
check "a confirmation shows the code to match" [settle {[dict size $bt::pairing] && [dict get $bt::pairing kind] eq "confirm"}]
check "the code is six digits" [expr {[dict get $bt::pairing code] eq "654321"}]
bt::pair_answer 0
check "rejecting ends the pairing with an error" [settle {[dict size $bt::pairing] == 0 && $bt::error ne ""}]
check "the phone stays unpaired" [expr {[field $P paired] == 0}]
bt::pair $P
check "a second pairing asks again" [settle {[dict size $bt::pairing] && [dict get $bt::pairing kind] eq "confirm"}]
bt::pair_answer 1
check "accepting ends the pairing with the phone paired, trusted and connected" [settle {
	[dict size $bt::pairing] == 0 && [field $P paired] eq 1 && [field $P connected] eq 1}]
check "and trusted, with no error" [expr {[field $P trusted] == 1 && $bt::error eq ""}]
check "the stand-in logged the answers" [expr {[logged_has "answer\t$P\tok"] && [logged_has "answer\t$P\terror\torg.bluez.Error.Rejected"]}]

# the agent refuses what it has no screen for: a PIN and a passkey
set me [$bt::bus name]
set code [catch {$bt::bus call $me $bt::agent_path org.bluez.Agent1 RequestPinCode o $K} msg opts]
check "a PIN request is refused" [expr {$code && [lindex [dict get $opts -errorcode] 1] eq "org.bluez.Error.Rejected"}]
set code [catch {$bt::bus call $me $bt::agent_path org.bluez.Agent1 RequestPasskey o $K} msg opts]
check "a passkey request is refused" [expr {$code && [lindex [dict get $opts -errorcode] 1] eq "org.bluez.Error.Rejected"}]

# forgetting removes the device from the list
bt::forget $M
check "the mouse is forgotten and not listed" [settle {[dev $M] eq ""}]
check "the stand-in logged it" [logged_has "forget\t$M"]

puts [expr {$fails ? "  $fails check(s) failed" : "  all Bluetooth client checks passed"}]
exit [expr {$fails ? 1 : 0}]
