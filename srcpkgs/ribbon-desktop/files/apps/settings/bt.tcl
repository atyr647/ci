# bt.tcl - Settings → Bluetooth's BlueZ client (U-Bluetooth): reads the adapter, its devices, their battery and
# signal, and the pairing agent's prompts, over the system bus (ribbon::dbus). Nothing forks bluetoothctl.
#
# Every bus call is asynchronous: an action is a coroutine (bt::job), and a call inside it yields until the bus
# answers, so Tk keeps drawing. Reads are coalesced: a refresh asked for during a read runs once more after it.
# BlueZ's changes (PropertiesChanged under /org/bluez, InterfacesAdded and InterfacesRemoved) trigger a refresh.
#
#   bt::start                   read the model and listen for BlueZ (again: harmless)
#   bt::refresh                 re-read the model
#   bt::job CMD ARGS...         run CMD (a proc) in a coroutine, then refresh; its error is bt::error
#   bt::model                   the model dict (below); well formed before the first read ends
#   bt::subtitle                "No Bluetooth adapter", "Off", "N connected" or "On"
#   bt::set_power 0|1           Adapter1.Powered
#   bt::scan 0|1                Adapter1.StartDiscovery / StopDiscovery
#   bt::connect PATH            Device1.Connect
#   bt::disconnect PATH         Device1.Disconnect
#   bt::forget PATH             Adapter1.RemoveDevice
#   bt::set_trusted PATH 0|1    Device1.Trusted
#   bt::pair PATH               the pairing agent is registered; Device1.Pair, then Trusted and Connect
#   bt::pair_answer 1|0         answers a pending RequestConfirmation (0 rejects it)
#   bt::pair_cancel             Device1.CancelPairing, and any pending answer is rejected
#   bt::pairing                 the pairing prompt: {path name kindlabel kind code entered} ({} when none);
#                               kind is plain (Pair running, nothing to show), code (type the code on the device),
#                               or confirm (the user says whether the code matches)
#   bt::bar_battery ADDRESS     1 when the bar shows this device's battery (bluetooth.conf, BAR_BATTERY)
#   bt::set_bar_battery ADDRESS 0|1
#
# The model is a dict: available, powered, discovering (0|1), alias, adapter (its path), devices (a list of device
# dicts: path name address kind kindlabel paired connected trusted battery rssi). The pure helpers at the end need
# no bus and are tested alone: bt::kind, bt::kind_label, bt::summarize, bt::order, bt::subtitle_of.

# ribbon::dbus lives beside the apps (files/dbus here, /usr/lib/ribbon installed)
foreach d [list /usr/lib/ribbon [file dirname [file dirname [file dirname [file normalize [info script]]]]]] {
	if {$d ni $::auto_path} { lappend ::auto_path $d }
}
package require ribbon::dbus

namespace eval bt {
	variable dest org.bluez
	variable bus ""
	variable listening ""   ;# the bus the signals are listened on
	variable agent_bus ""   ;# the bus the pairing agent is exported and registered on
	variable agent_path /org/ribbon/btagent
	variable current {available 0 powered 0 discovering 0 alias "" adapter "" devices {}}
	variable error ""       ;# the last action's error (shown in the subtitle)
	variable busy 0
	variable again 0
	variable loaded 0       ;# the first read has ended (the page shows no state before it)
	variable seq 0
	variable onchange ""    ;# a command run after each model change (the page draws)
	variable pairing {}
	variable pair_path ""   ;# the device being paired ("" when none)
	variable pair_cancelled 0
	variable pending ""     ;# the RequestConfirmation message waiting for pair_answer
}

# ---- the bus ----------------------------------------------------------------------

proc bt::ensure_bus {} {
	variable bus
	if {$bus ne "" && [llength [info commands $bus]]} { return }
	set bus [ribbon::dbus::connect system]
}

# A call to BlueZ (yields inside a coroutine): the reply's values.
proc bt::call {path iface member args} {
	variable bus; variable dest
	$bus call $dest $path $iface $member {*}$args
}

# Properties.Set on an object: SIG is the variant's type (b, s, ...).
proc bt::set_prop {path iface name sig value} {
	bt::call $path org.freedesktop.DBus.Properties Set ssv $iface $name [list $sig $value]
}

# A key of a property dict, or DEF.
proc bt::pget {d key {def ""}} {
	if {[dict exists $d $key]} { return [dict get $d $key] }
	return $def
}

# 1 for a bus boolean that is set (or 1), 0 otherwise.
proc bt::flag {v} {
	if {$v ne "" && $v ne "0" && $v ne "false"} { return 1 }
	return 0
}

# The text for a failure: a bus without BlueZ says so; anything else is the error's own text.
proc bt::explain {msg opts} {
	if {[dict exists $opts -errorcode] && [lindex [dict get $opts -errorcode] 0] eq "DBUS"} {
		if {[lindex [dict get $opts -errorcode] 1] in {org.freedesktop.DBus.Error.ServiceUnknown
			org.freedesktop.DBus.Error.NameHasNoOwner org.freedesktop.DBus.Error.NoServer org.freedesktop.DBus.Error.Disconnected}} {
			return "BlueZ is not running"
		}
	}
	return $msg
}

# The error name of a failure (org.bluez.Error.X), or "".
proc bt::errname {opts} {
	if {[dict exists $opts -errorcode] && [lindex [dict get $opts -errorcode] 0] eq "DBUS"} { return [lindex [dict get $opts -errorcode] 1] }
	return ""
}

# ---- reading --------------------------------------------------------------------

# Read the model from BlueZ's ObjectManager; yields while the bus answers. A bus with no BlueZ gives the empty model.
proc bt::fetch {} {
	if {[catch {
		bt::ensure_bus
		bt::listen
		set r [lindex [bt::call / org.freedesktop.DBus.ObjectManager GetManagedObjects] 0]
		set objs [ribbon::dbus::strip a{oa{sa{sv}}} $r]
	}]} {
		return [bt::summarize {}]
	}
	bt::summarize $objs
}

proc bt::listen {} {
	variable bus; variable dest; variable listening
	if {$listening eq $bus} return
	set listening $bus
	$bus listen -sender $dest -path_namespace /org/bluez -interface org.freedesktop.DBus.Properties \
		-member PropertiesChanged bt::changed
	$bus listen -sender $dest -interface org.freedesktop.DBus.ObjectManager -member InterfacesAdded bt::changed
	$bus listen -sender $dest -interface org.freedesktop.DBus.ObjectManager -member InterfacesRemoved bt::changed
}

proc bt::changed args { bt::refresh }

# Start a read. Returns at once; the model and then the page are updated when the read ends.
proc bt::refresh {} {
	variable busy; variable again; variable seq
	if {$busy} { set again 1; return }
	set busy 1
	coroutine ::bt::read[incr seq] bt::run_read
}

proc bt::run_read {} {
	variable busy; variable again; variable current; variable onchange; variable loaded
	while {1} {
		set again 0
		set current [bt::fetch]
		set loaded 1
		if {!$again} break
	}
	set busy 0
	if {$onchange ne ""} { {*}$onchange }
}

proc bt::start {} { bt::refresh }

proc bt::model {} {
	variable current
	set current
}

# The model's adapter path; an action without one is an error.
proc bt::adapter {} {
	set a [dict get [bt::model] adapter]
	if {$a eq ""} { error "No Bluetooth adapter" }
	set a
}

# The device with PATH in the model, or {}.
proc bt::device_of {path} {
	foreach d [dict get [bt::model] devices] {
		if {[dict get $d path] eq $path} { return $d }
	}
	return {}
}

# ---- jobs -----------------------------------------------------------------------

# Run an action (a proc and its arguments) in a coroutine, then refresh. Its error goes to bt::error.
proc bt::job {args} {
	variable seq
	coroutine ::bt::job[incr seq] bt::run_job {*}$args
}

proc bt::run_job {args} {
	variable error
	set error ""
	if {[catch {
		bt::ensure_bus
		{*}$args
	} msg opts]} {
		set error [bt::explain $msg $opts]
	}
	bt::refresh
}

proc bt::set_power {on} { bt::job bt::do_power $on }
proc bt::scan {on} { bt::job bt::do_scan $on }
proc bt::connect {path} { bt::job bt::do_connect $path }
proc bt::disconnect {path} { bt::job bt::do_disconnect $path }
proc bt::forget {path} { bt::job bt::do_forget $path }
proc bt::set_trusted {path on} { bt::job bt::do_trusted $path $on }
proc bt::pair {path} { bt::job bt::do_pair $path }
proc bt::pair_cancel {} { bt::job bt::do_pair_cancel }

proc bt::do_power {on} {
	bt::set_prop [bt::adapter] org.bluez.Adapter1 Powered b [expr {$on ? 1 : 0}]
}

# Discovery is asked for and may already be as asked: BlueZ's "in progress", "not started" and "not ready" are not errors.
proc bt::do_scan {on} {
	set member [expr {$on ? "StartDiscovery" : "StopDiscovery"}]
	if {[catch {bt::call [bt::adapter] org.bluez.Adapter1 $member} msg opts]} {
		if {![regexp -nocase {in progress|not started|not ready|no discovery started} $msg]} {
			return -options $opts $msg
		}
	}
}

proc bt::do_connect {path} { bt::call $path org.bluez.Device1 Connect }
proc bt::do_disconnect {path} { bt::call $path org.bluez.Device1 Disconnect }
proc bt::do_forget {path} { bt::call [bt::adapter] org.bluez.Adapter1 RemoveDevice o $path }
proc bt::do_trusted {path on} { bt::set_prop $path org.bluez.Device1 Trusted b [expr {$on ? 1 : 0}] }

# Pair a device: the agent is registered, Pair runs (a long timeout: the user may take a minute), then the device
# is trusted and connected. A Connect that fails after a good pair is not an error.
proc bt::do_pair {path} {
	variable bus; variable dest; variable pair_path; variable pair_cancelled
	bt::ensure_agent
	set pair_path $path
	set pair_cancelled 0
	bt::set_pairing [bt::pairing_of $path plain "" 0]
	set r [catch {$bus call -timeout 120000 $dest $path org.bluez.Device1 Pair} msg opts]
	set pair_path ""
	bt::reject_pending org.bluez.Error.Canceled "Pairing ended"
	bt::set_pairing {}
	if {$r} {
		if {$pair_cancelled} return
		return -options $opts $msg
	}
	bt::set_prop $path org.bluez.Device1 Trusted b 1
	catch {$bus call -timeout 60000 $dest $path org.bluez.Device1 Connect}
}

proc bt::do_pair_cancel {} {
	variable pair_path; variable pair_cancelled; variable bus; variable dest
	if {$pair_path eq ""} return
	set pair_cancelled 1
	bt::reject_pending org.bluez.Error.Rejected "Pairing canceled"
	catch {$bus call $dest $pair_path org.bluez.Device1 CancelPairing}
}

# ---- the pairing agent --------------------------------------------------------------

# Export the agent on this bus and register it with BlueZ (KeyboardDisplay, as a device with a screen and keys).
proc bt::ensure_agent {} {
	variable bus; variable dest; variable agent_bus; variable agent_path
	if {$agent_bus eq $bus} return
	$bus export $agent_path org.bluez.Agent1 [list \
		method Release "" "" bt::agent_none \
		method RequestPinCode o s bt::agent_reject \
		method DisplayPinCode os "" bt::agent_display_pin \
		method RequestPasskey o u bt::agent_reject \
		method DisplayPasskey ouq "" bt::agent_display_passkey \
		method RequestConfirmation ou "" bt::agent_confirm \
		method RequestAuthorization o "" bt::agent_authorize \
		method AuthorizeService os "" bt::agent_authorize \
		method Cancel "" "" bt::agent_cancel]
	if {[catch {$bus call $dest /org/bluez org.bluez.AgentManager1 RegisterAgent os $agent_path KeyboardDisplay} msg opts]} {
		if {[bt::errname $opts] ne "org.bluez.Error.AlreadyExists"} { return -options $opts $msg }
	}
	set agent_bus $bus
}

# The prompt for a device: its name and kind from the model.
proc bt::pairing_of {path kind code entered} {
	set d [bt::device_of $path]
	if {[dict size $d]} {
		set name [dict get $d name]
		set label [dict get $d kindlabel]
	} else {
		set name $path
		set label Device
	}
	dict create path $path name $name kindlabel $label kind $kind code $code entered $entered
}

proc bt::set_pairing {d} {
	variable pairing; variable onchange
	set pairing $d
	if {$onchange ne ""} { {*}$onchange }
}

# A display for the device being paired (or any device the agent names, when no pairing is shown).
proc bt::show_pairing {device kind code entered} {
	bt::set_pairing [bt::pairing_of $device $kind $code $entered]
}

proc bt::agent_none args { }

# Input the stand-in cannot take here (a PIN or a passkey to type into this screen): BlueZ is told so.
proc bt::agent_reject args {
	throw {DBUS org.bluez.Error.Rejected} "This device needs a PIN, which this screen cannot take"
}

proc bt::agent_display_pin {m device code} { bt::show_pairing $device code $code 0 }

proc bt::agent_display_passkey {m device passkey entered} {
	bt::show_pairing $device code [format %06d $passkey] $entered
}

# The user says whether the code matches; the answer is sent by bt::pair_answer.
proc bt::agent_confirm {m device passkey} {
	variable bus; variable pair_path; variable pending
	if {$device ne $pair_path} { throw {DBUS org.bluez.Error.Rejected} "Not pairing this device" }
	$bus defer $m
	set pending $m
	bt::show_pairing $device confirm [format %06d $passkey] 0
}

proc bt::agent_authorize {m device args} {
	variable pair_path
	if {$device ne $pair_path} { throw {DBUS org.bluez.Error.Rejected} "Not pairing this device" }
}

# BlueZ cancelled the pairing: the prompt goes, and a pending answer is rejected.
proc bt::agent_cancel {m} {
	bt::reject_pending org.bluez.Error.Canceled "Pairing canceled"
	bt::set_pairing {}
}

proc bt::pair_answer {ok} {
	variable bus; variable pending; variable pairing
	if {$pending eq ""} return
	set m $pending
	set pending ""
	if {$ok} {
		$bus reply $m
	} else {
		$bus error $m org.bluez.Error.Rejected "Not confirmed"
	}
	if {[dict size $pairing]} { bt::set_pairing [bt::pairing_of [dict get $pairing path] plain "" 0] }
}

proc bt::reject_pending {name text} {
	variable bus; variable pending
	if {$pending eq ""} return
	set m $pending
	set pending ""
	catch {$bus error $m $name $text}
}

# ---- the settings file: ~/.config/ribbon/bluetooth.conf (KEY=VALUE lines) -------------------

proc bt::conf_file {} {
	set cfg [expr {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""
		? $::env(XDG_CONFIG_HOME) : [file join [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}] .config]}]
	file join $cfg ribbon bluetooth.conf
}

proc bt::conf_lines {} {
	set f [bt::conf_file]
	if {[catch {open $f} fh]} { return {} }
	set t [read $fh]
	close $fh
	if {$t eq ""} { return {} }
	split [string trimright $t \n] \n
}

# The addresses whose battery the bar shows (BAR_BATTERY, upper case; the file's last line wins).
proc bt::bar_list {} {
	set list {}
	foreach line [bt::conf_lines] {
		if {[regexp {^BAR_BATTERY=(.*)$} $line -> v]} {
			set list {}
			foreach a [split $v " "] { if {$a ne ""} { lappend list [string toupper $a] } }
		}
	}
	set list
}

proc bt::bar_battery {addr} {
	expr {[lsearch -exact [bt::bar_list] [string toupper $addr]] >= 0 ? 1 : 0}
}

proc bt::set_bar_battery {addr on} {
	set addr [string toupper $addr]
	set list [lsearch -all -inline -not -exact [bt::bar_list] $addr]
	if {$on} { lappend list $addr }
	bt::conf_set BAR_BATTERY [join $list " "]
}

# Write KEY=VALUE: its line is replaced (or added), and every other line stays as it was. Written to a temporary file
# and renamed over the old one.
proc bt::conf_set {key value} {
	set f [bt::conf_file]
	set out {}
	set done 0
	foreach line [bt::conf_lines] {
		if {[regexp "^${key}=" $line]} {
			if {!$done} { lappend out "${key}=$value"; set done 1 }
		} elseif {$line ne ""} {
			lappend out $line
		}
	}
	if {!$done} { lappend out "${key}=$value" }
	file mkdir [file dirname $f]
	set tmp "$f.tmp"
	set fh [open $tmp w]
	puts $fh [join $out \n]
	close $fh
	file rename -force $tmp $f
}

# ---- pure helpers (no bus) ----------------------------------------------------------

# The kind of a device from its Icon (BlueZ's icon name), else from its Class (the major and minor device class).
proc bt::kind {icon {class ""}} {
	switch -- $icon {
		audio-headset - audio-headphones - audio-card { return headphones }
		input-mouse { return mouse }
		input-keyboard { return kbd }
		phone { return phone }
		input-gaming { return pad }
		video-display { return monitor }
	}
	if {[string match audio-speaker* $icon]} { return speaker }
	if {$class eq "" || ![string is integer -strict $class]} { return bt }
	set major [expr {($class >> 8) & 0x1f}]
	set minor [expr {($class >> 2) & 0x3f}]
	switch -- $major {
		2 { return phone }
		4 {
			if {$minor in {1 2 6}} { return headphones }
			if {$minor == 5} { return speaker }
			return bt
		}
		5 {
			set kb [expr {($minor & 0x10) != 0}]
			set ptr [expr {($minor & 0x20) != 0}]
			if {$kb && !$ptr} { return kbd }
			if {$ptr && !$kb} { return mouse }
			if {!$kb && !$ptr && ($minor & 0x0f) == 2} { return pad }
			return bt
		}
	}
	return bt
}

proc bt::kind_label {kind} {
	dict get {headphones Headphones mouse Mouse kbd Keyboard phone Phone pad Controller speaker Speaker
		monitor Display bt Device} $kind
}

# Device order: paired first (connected before the rest, then by name); then unpaired by signal, strongest first.
proc bt::order {a b} {
	if {[dict get $a paired] != [dict get $b paired]} { return [expr {[dict get $a paired] ? -1 : 1}] }
	if {[dict get $a paired]} {
		if {[dict get $a connected] != [dict get $b connected]} { return [expr {[dict get $a connected] ? -1 : 1}] }
	} else {
		set ra [bt::rssi_key $a]
		set rb [bt::rssi_key $b]
		if {$ra != $rb} { return [expr {$ra > $rb ? -1 : 1}] }
	}
	set c [string compare -nocase [dict get $a name] [dict get $b name]]
	if {$c} { return $c }
	string compare [dict get $a path] [dict get $b path]
}

proc bt::rssi_key {d} {
	set r [dict get $d rssi]
	if {$r eq ""} { return -1000 }
	return $r
}

# One device of the model from its BlueZ properties and interfaces, or "" when it is not listed: an unpaired device
# without a name is left out.
proc bt::device {path d ifaces} {
	set paired [bt::flag [bt::pget $d Paired]]
	set name [bt::pget $d Name]
	if {!$paired && $name eq ""} { return "" }
	set addr [bt::pget $d Address]
	set alias [bt::pget $d Alias]
	set shown [expr {$alias ne "" ? $alias : ($name ne "" ? $name : $addr)}]
	set battery ""
	if {[dict exists $ifaces org.bluez.Battery1]} {
		set battery [bt::pget [dict get $ifaces org.bluez.Battery1] Percentage ""]
	}
	set kind [bt::kind [bt::pget $d Icon] [bt::pget $d Class ""]]
	dict create path $path name $shown address $addr kind $kind kindlabel [bt::kind_label $kind] \
		paired $paired connected [bt::flag [bt::pget $d Connected]] trusted [bt::flag [bt::pget $d Trusted]] \
		battery $battery rssi [bt::pget $d RSSI ""]
}

# The model from BlueZ's objects (path -> interface -> properties): the first adapter, and its devices.
proc bt::summarize {objs} {
	set none [dict create available 0 powered 0 discovering 0 alias "" adapter "" devices {}]
	set adapter ""
	foreach p [lsort [dict keys $objs]] {
		if {[dict exists $objs $p org.bluez.Adapter1]} { set adapter $p; break }
	}
	if {$adapter eq ""} { return $none }
	set a [dict get $objs $adapter org.bluez.Adapter1]
	set devs {}
	foreach p [lsort [dict keys $objs]] {
		if {![dict exists $objs $p org.bluez.Device1]} continue
		set d [dict get $objs $p org.bluez.Device1]
		if {[dict exists $d Adapter] && [dict get $d Adapter] ne $adapter} continue
		set dev [bt::device $p $d [dict get $objs $p]]
		if {$dev ne ""} { lappend devs $dev }
	}
	dict create available 1 powered [bt::flag [bt::pget $a Powered]] \
		discovering [bt::flag [bt::pget $a Discovering]] alias [bt::pget $a Alias] \
		adapter $adapter devices [lsort -command bt::order $devs]
}

proc bt::subtitle_of {m} {
	if {![dict get $m available]} { return "No Bluetooth adapter" }
	if {![dict get $m powered]} { return Off }
	set n 0
	foreach d [dict get $m devices] { if {[dict get $d connected]} { incr n } }
	if {$n} { return "$n connected" }
	return On
}

proc bt::subtitle {} { bt::subtitle_of [bt::model] }
