# nm.tcl - Settings → Network's NetworkManager client (U13): reads the Wi-Fi radio, the devices and their
# access points, and each device's IP configuration, over the system bus (ribbon::dbus). Nothing forks nmcli.
#
# Every bus call is asynchronous: a read or an action is a coroutine, and a call inside it yields until the bus
# answers, so Tk keeps drawing. Reads are coalesced: a refresh asked for during a read runs once more after it.
# Changes made by NetworkManager (signals on its objects) trigger a refresh.
#
#   nm::refresh                 re-read the model
#   nm::job CMD ARGS...         run CMD (a proc) in a coroutine, then refresh; its error is nm::error
#   nm::connect_ap DEV SSID     AddAndActivateConnection for an open network (no secrets: U13b does the rest)
#   nm::disconnect ACTIVE       DeactivateConnection
#   nm::set_wifi 0|1            the radio (Properties.Set WirelessEnabled)
#
#   nm::connect_secured DEV AP BYTES PSK   a new profile for a secured network (WPA2 or WPA3 by its flags)
#   nm::connect_hidden SSID PSK            AddAndActivateConnection for a hidden network ("" PSK: open)
#   nm::activate PROFILE                   ActivateConnection for a saved profile (on the chosen device)
#   nm::forget PROFILE                     Connection.Delete
#   nm::save_profile PROFILE AUTO METERED PSK   Connection.Update (the saved settings with the secret kept)
#   nm::reveal PROFILE                     the saved Wi-Fi password (GetSecrets; NM answers the owner only)
#   nm::add_wireguard FILE                 AddConnection of a WireGuard .conf; returns the profile's path
#   nm::vpn_toggle PROFILE ACTIVE          ActivateConnection / DeactivateConnection of a VPN profile
#
# The model also holds saved (the profiles: path id type ssid autoconnect metered) and active (the active
# connections: path id type conn, conn being the profile's path). Settings objects are typed as NetworkManager
# sends them; a profile is read with strip and written back from its raw GetSettings reply.
#
# The model is a dict: wifi (0|1), devices (a list of device dicts), error. A device dict holds path, iface, type
# (1 ethernet, 2 Wi-Fi), state, hw, active (the active connection's id, "" if none), activepath, ip (address,
# gateway, dns list), rate (Mb/s), and for Wi-Fi: aps (a list of access-point dicts: path, ssid (text), bytes (the
# raw SSID), strength, flags, wpa, rsn, freq, rate). The pure helpers at the end need no bus and are tested alone.

# ribbon::dbus lives beside the apps (files/dbus here, /usr/lib/ribbon/dbus installed)
foreach d [list /usr/lib/ribbon [file dirname [file dirname [file dirname [file normalize [info script]]]]]] {
	if {$d ni $::auto_path} { lappend ::auto_path $d }
}
package require ribbon::dbus

namespace eval nm {
	variable dest org.freedesktop.NetworkManager
	variable root /org/freedesktop/NetworkManager
	variable bus ""
	variable model {wifi 0 devices {} error "" saved {} active {}}
	variable error ""       ;# the last action's error (shown in the subtitle)
	variable busy 0
	variable again 0
	variable listening 0
	variable loaded 0      ;# the first read has ended (the page shows no state before it)
	variable seq 0
	variable onchange ""    ;# a command run after each model change (the page draws)
	variable settings /org/freedesktop/NetworkManager/Settings
	variable conniface org.freedesktop.NetworkManager.Settings.Connection
}

# ---- the bus ----------------------------------------------------------------------

# Connect to the system bus once (DBUS_SYSTEM_BUS_ADDRESS is honoured by ribbon::dbus::connect system).
proc nm::ensure_bus {} {
	variable bus
	if {$bus ne "" && [llength [info commands $bus]]} { return }
	set bus [ribbon::dbus::connect system]
}

# A call to NetworkManager (yields inside a coroutine): the reply's values.
proc nm::call {path iface member {sig ""} args} {
	variable bus; variable dest
	if {$sig eq ""} { return [$bus call $dest $path $iface $member] }
	$bus call $dest $path $iface $member $sig {*}$args
}

# The properties of one interface, as a dict of plain values.
proc nm::props {path iface} {
	variable bus; variable dest
	set v [lindex [$bus call $dest $path org.freedesktop.DBus.Properties GetAll s $iface] 0]
	ribbon::dbus::strip a{sv} $v
}

# A key of a property dict, or DEF when NetworkManager did not send it.
proc nm::get {d key {def ""}} {
	expr {[dict exists $d $key] ? [dict get $d $key] : $def}
}

# Object paths that mean "none" in NetworkManager.
proc nm::path_or_empty {p} { expr {$p eq "/" ? "" : $p} }

# ---- reading --------------------------------------------------------------------

# Read the whole model; yields while the bus answers. Returns the model dict.
proc nm::read {} {
	variable root
	set m {wifi 0 devices {} error "" saved {} active {}}
	if {[catch {
		nm::ensure_bus
		nm::listen
		set top [nm::props $root org.freedesktop.NetworkManager]
		dict set m wifi [expr {[nm::get $top WirelessEnabled 0] ? 1 : 0}]
		set devs {}
		foreach p [lindex [nm::call $root org.freedesktop.NetworkManager GetDevices] 0] {
			lappend devs [nm::read_device $p]
		}
		dict set m devices $devs
		dict set m saved [nm::read_saved]
		dict set m active [nm::read_active $top]
	} msg]} {
		dict set m error [nm::explain $msg]
	}
	set m
}

# The text for a failure: a bus that has no NetworkManager says so; anything else is the error's own text.
proc nm::explain {msg} {
	if {[lindex $::errorCode 0] eq "DBUS"} {
		set name [lindex $::errorCode 1]
		if {$name in {org.freedesktop.DBus.Error.ServiceUnknown org.freedesktop.DBus.Error.NameHasNoOwner
			org.freedesktop.DBus.Error.NoServer org.freedesktop.DBus.Error.Disconnected}} {
			return "NetworkManager is not running"
		}
	}
	return $msg
}

# One device: its interface, state, active connection, IP configuration and (Wi-Fi) its access points.
proc nm::read_device {p} {
	set d [nm::props $p org.freedesktop.NetworkManager.Device]
	set dev [dict create path $p iface [nm::get $d Interface] type [nm::get $d DeviceType 0] \
		state [nm::get $d State 0] hw [nm::get $d HwAddress] active "" activepath "" \
		ip {address "" gateway "" dns {}} rate 0 aps {}]
	set ac [nm::path_or_empty [nm::get $d ActiveConnection]]
	if {$ac ne ""} {
		set a [nm::props $ac org.freedesktop.NetworkManager.Connection.Active]
		dict set dev active [nm::get $a Id]
		dict set dev activepath $ac
	}
	set ip4 [nm::path_or_empty [nm::get $d Ip4Config]]
	if {$ip4 ne ""} { dict set dev ip [nm::read_ip4 $ip4] }
	if {[dict get $dev type] == 2} {
		set w [nm::props $p org.freedesktop.NetworkManager.Device.Wireless]
		dict set dev rate [expr {[nm::get $w Bitrate 0] / 1000}]
		set active [nm::path_or_empty [nm::get $w ActiveAccessPoint]]
		set aps {}
		foreach ap [nm::get $w AccessPoints {}] { lappend aps [nm::read_ap $ap $active] }
		dict set dev aps $aps
	}
	set dev
}

# IP4Config: the first address, the gateway and the name servers.
proc nm::read_ip4 {p} {
	set c [nm::props $p org.freedesktop.NetworkManager.IP4Config]
	set addr ""
	set first [lindex [nm::get $c AddressData {}] 0]
	if {$first ne ""} { set addr [nm::get $first address] }
	set dns {}
	foreach n [nm::get $c NameserverData {}] { lappend dns [nm::get $n address] }
	dict create address $addr gateway [nm::get $c Gateway] dns $dns
}

proc nm::read_ap {p active} {
	set a [nm::props $p org.freedesktop.NetworkManager.AccessPoint]
	set bytes [nm::get $a Ssid]
	dict create path $p bytes $bytes ssid [nm::ssid_text $bytes] strength [nm::get $a Strength 0] \
		flags [nm::get $a Flags 0] wpa [nm::get $a WpaFlags 0] rsn [nm::get $a RsnFlags 0] \
		freq [nm::get $a Frequency 0] active [expr {$p eq $active}]
}

# Ask NetworkManager for changes once: its objects' property changes come back to nm::changed.
proc nm::listen {} {
	variable bus; variable dest; variable listening
	if {$listening} return
	set listening 1
	$bus listen -sender $dest -path_namespace /org/freedesktop/NetworkManager \
		-interface org.freedesktop.DBus.Properties -member PropertiesChanged nm::changed
}

proc nm::changed args { nm::refresh }

# Start a read. Returns at once; the model and then the page are updated when the read ends.
proc nm::refresh {} {
	variable busy; variable again
	if {$busy} { set again 1; return }
	set busy 1
	coroutine ::nm::read[incr ::nm::seq] nm::run_read
}

proc nm::run_read {} {
	variable busy; variable again; variable model; variable onchange; variable loaded
	while {1} {
		set again 0
		set model [nm::read]
		set loaded 1
		if {!$again} break
	}
	set busy 0
	if {$onchange ne ""} { {*}$onchange }
}

# Run an action (a proc and its arguments) in a coroutine, then refresh. Its error goes to nm::error.
proc nm::job {args} {
	coroutine ::nm::job[incr ::nm::seq] nm::run_job {*}$args
}

proc nm::run_job {args} {
	variable error
	set error ""
	if {[catch {
		nm::ensure_bus
		{*}$args
	} msg]} {
		set error [nm::explain $msg]
	}
	nm::refresh
}

# ---- actions --------------------------------------------------------------------

# Turn the Wi-Fi radio on (1) or off (0).
proc nm::set_wifi {on} {
	variable bus; variable dest; variable root
	$bus call $dest $root org.freedesktop.DBus.Properties Set ssv org.freedesktop.NetworkManager WirelessEnabled [list b [expr {$on ? 1 : 0}]]
}

# Connect device DEV to an open network SSID (its access point AP). The profile is named after the network.
proc nm::connect_ap {dev ap bytes} {
	variable bus; variable dest; variable root
	set conn [dict create \
		connection [dict create id [list s [nm::ssid_text $bytes]] type [list s 802-11-wireless]] \
		802-11-wireless [dict create ssid [list ay $bytes] mode [list s infrastructure]]]
	$bus call $dest $root org.freedesktop.NetworkManager AddAndActivateConnection "a{sa{sv}}oo" $conn $dev $ap
}

proc nm::disconnect {active} {
	variable bus; variable dest; variable root
	$bus call $dest $root org.freedesktop.NetworkManager DeactivateConnection "o" $active
}

# ---- profiles, secrets and VPN (U13b) -----------------------------------------------

# The saved profiles, one dict each: path, id, type, ssid (text), autoconnect (0|1), metered (NM's enum).
proc nm::read_saved {} {
	variable bus; variable dest; variable settings
	set out {}
	foreach p [lindex [$bus call $dest $settings org.freedesktop.NetworkManager.Settings ListConnections] 0] {
		set s [ribbon::dbus::strip a{sa{sv}} [lindex [$bus call $dest $p org.freedesktop.NetworkManager.Settings.Connection GetSettings] 0]]
		set c [nm::get $s connection]
		set w [nm::get $s 802-11-wireless]
		lappend out [dict create path $p id [nm::get $c id] type [nm::get $c type] \
			ssid [nm::ssid_text [nm::get $w ssid]] autoconnect [expr {[nm::get $c autoconnect 1] ? 1 : 0}] \
			metered [nm::get $c metered 0]]
	}
	set out
}

# The active connections: one dict each (path, id, type, conn: the profile's path).
proc nm::read_active {top} {
	variable bus; variable dest
	set out {}
	foreach ac [nm::get $top ActiveConnections {}] {
		set a [nm::props $ac org.freedesktop.NetworkManager.Connection.Active]
		lappend out [dict create path $ac id [nm::get $a Id] type [nm::get $a Type] conn [nm::path_or_empty [nm::get $a Connection]]]
	}
	set out
}

# The settings of a profile, raw (typed), as NetworkManager sends them.
proc nm::raw_settings {path} {
	variable bus; variable dest; variable conniface
	lindex [$bus call $dest $path $conniface GetSettings] 0
}

# The secrets of a setting (GetSecrets), merged into raw settings: NetworkManager drops a secret an Update omits.
proc nm::with_secret {path raw} {
	variable bus; variable dest; variable conniface
	set sec [lindex [$bus call $dest $path $conniface GetSecrets s 802-11-wireless-security] 0]
	if {[dict exists $sec 802-11-wireless-security]} {
		set v [dict get $sec 802-11-wireless-security]
		if {[dict exists $v psk]} { dict set raw 802-11-wireless-security psk [dict get $v psk] }
	}
	set raw
}

# Connect device DEV to a secured network (AP, SSID bytes) with the password PSK; a new profile.
proc nm::connect_secured {dev ap bytes psk sae} {
	variable bus; variable dest; variable root
	set conn [dict create \
		connection [dict create id [list s [nm::ssid_text $bytes]] type [list s 802-11-wireless]] \
		802-11-wireless [dict create ssid [list ay $bytes] mode [list s infrastructure]] \
		802-11-wireless-security [dict create key-mgmt [list s [expr {$sae ? "sae" : "wpa-psk"}]] psk [list s $psk]]]
	$bus call $dest $root org.freedesktop.NetworkManager AddAndActivateConnection "a{sa{sv}}oo" $conn $dev $ap
}

# A hidden network (SSID, password PSK; "" for an open one). Its device is chosen by NetworkManager.
proc nm::connect_hidden {ssid psk} {
	variable bus; variable dest; variable root
	set bytes [encoding convertto utf-8 $ssid]
	set conn [dict create \
		connection [dict create id [list s $ssid] type [list s 802-11-wireless]] \
		802-11-wireless [dict create ssid [list ay $bytes] mode [list s infrastructure] hidden [list b 1]]]
	if {$psk ne ""} {
		dict set conn 802-11-wireless-security [dict create key-mgmt [list s wpa-psk] psk [list s $psk]]
	}
	$bus call $dest $root org.freedesktop.NetworkManager AddAndActivateConnection "a{sa{sv}}oo" $conn / /
}

# Activate a saved profile on its device (a Wi-Fi profile on the Wi-Fi device; the AP is NetworkManager's choice).
proc nm::activate {profile dev} {
	variable bus; variable dest; variable root
	$bus call $dest $root org.freedesktop.NetworkManager ActivateConnection ooo $profile $dev /
}

proc nm::forget {profile} {
	variable bus; variable dest; variable conniface
	$bus call $dest $profile $conniface Delete
}

# Write AUTO (autoconnect) and METERED (0 unknown, 1 yes, 2 no) to a profile; PSK (when not "") replaces its password.
proc nm::save_profile {profile auto metered psk} {
	variable bus; variable dest; variable conniface
	set raw [nm::raw_settings $profile]
	set raw [nm::with_secret $profile $raw]
	dict set raw connection autoconnect [list b [expr {$auto ? 1 : 0}]]
	dict set raw connection metered [list i $metered]
	if {$psk ne ""} {
		dict set raw 802-11-wireless-security psk [list s $psk]
	}
	$bus call $dest $profile $conniface Update "a{sa{sv}}" $raw
}

# The saved Wi-Fi password of a profile; "" when it has none.
proc nm::reveal {profile} {
	variable bus; variable dest; variable conniface
	set sec [lindex [$bus call $dest $profile $conniface GetSecrets s 802-11-wireless-security] 0]
	if {![dict exists $sec 802-11-wireless-security]} { return "" }
	set v [dict get $sec 802-11-wireless-security]
	if {[dict exists $v psk]} { return [lindex [dict get $v psk] 1] }
	return ""
}

# A WireGuard profile from a .conf file: [Interface] PrivateKey and Address, one [Peer] (PublicKey, Endpoint,
# AllowedIPs). Returns the profile's path. Throws when the file has no key or no peer.
proc nm::add_wireguard {file} {
	variable bus; variable dest; variable settings
	if {[catch {::open $file} fh]} { error "cannot read $file" }
	set text [::read $fh]
	::close $fh
	set section ""
	set iface {}
	set peers {}
	foreach line [split $text \n] {
		set line [string trim $line]
		if {$line eq "" || [string index $line 0] eq "#"} continue
		if {[regexp {^\[(\w+)\]$} $line -> section]} {
			if {$section eq "Peer"} { lappend peers {} }
			continue
		}
		if {![regexp {^(\w+)\s*=\s*(.*)$} $line -> k v]} continue
		set v [string trim $v]
		if {$section eq "Interface"} { dict set iface [string tolower $k] $v }
		if {$section eq "Peer" && [llength $peers]} {
			set one [lindex $peers end]
			dict set one [string tolower $k] $v
			lset peers end $one
		}
	}
	if {![dict exists $iface privatekey] || ![llength $peers]} { error "not a WireGuard config" }
	set name [file rootname [file tail $file]]
	set wg [dict create private-key [list s [dict get $iface privatekey]]]
	set plist {}
	foreach p $peers {
		set pd [dict create public-key [list s [dict get $p publickey]] allowed-ips [list as [split [dict get $p allowedips] ", "]]]
		if {[dict exists $p endpoint]} { dict set pd endpoint [list s [dict get $p endpoint]] }
		lappend plist $pd
	}
	dict set wg peers [list aa{sv} $plist]
	set ipv4 [dict create method [list s manual]]
	if {[dict exists $iface address]} {
		regexp {^([^/]+)(?:/(\d+))?} [dict get $iface address] -> addr prefix
		dict set ipv4 address-data [list aa{sv} [list [dict create address [list s $addr] prefix [list u [expr {$prefix eq "" ? 32 : $prefix}]]]]]
	}
	set conn [dict create connection [dict create id [list s $name] type [list s wireguard] interface-name [list s $name]] \
		wireguard $wg ipv4 $ipv4]
	$bus call $dest $settings org.freedesktop.NetworkManager.Settings AddConnection "a{sa{sv}}" $conn
}

# Bring a VPN profile up (ACTIVE 0) or down (ACTIVE 1: the active connection ACTIVEPATH).
proc nm::vpn_toggle {profile activepath on} {
	variable bus; variable dest; variable root
	if {$on} {
		$bus call $dest $root org.freedesktop.NetworkManager ActivateConnection ooo $profile / /
	} else {
		$bus call $dest $root org.freedesktop.NetworkManager DeactivateConnection "o" $activepath
	}
}

# ---- pure helpers (no bus) ------------------------------------------------------

# The SSID as text (UTF-8 when it is valid, else as Latin-1 bytes), "" when hidden.
proc nm::ssid_text {bytes} {
	if {$bytes eq ""} { return "" }
	if {[catch {encoding convertfrom utf-8 $bytes} t]} { return $bytes }
	return $t
}

# 2.4 GHz, 5 GHz or 6 GHz from a frequency in MHz.
proc nm::band {freq} {
	if {$freq >= 5925} { return "6 GHz" }
	if {$freq >= 4900} { return "5 GHz" }
	if {$freq > 0} { return "2.4 GHz" }
	return ""
}

# The security of an access point from its flags (NM80211ApFlags, WpaFlags, RsnFlags).
proc nm::security {flags wpa rsn} {
	if {$rsn & 0x400} {
		return [expr {$rsn & 0x100 ? "WPA2/WPA3" : "WPA3"}]
	}
	if {$rsn} { return WPA2 }
	if {$wpa} { return WPA }
	if {$flags & 0x1} { return WEP }
	return Open
}

# Signal bars 0 to 4 from a strength of 0 to 100.
proc nm::bars {strength} {
	if {$strength >= 80} { return 4 }
	if {$strength >= 55} { return 3 }
	if {$strength >= 30} { return 2 }
	if {$strength >= 5} { return 1 }
	return 0
}

# The Wi-Fi networks to list: one per SSID (the active access point or the strongest), hidden ones left out,
# the active one first, then by strength and name.
proc nm::networks {dev} {
	set aps {}
	foreach ap [dict get $dev aps] {
		if {[dict get $ap ssid] eq ""} continue
		lappend aps $ap
	}
	set sorted [lsort -command nm::order $aps]
	set out {}
	set seen {}
	foreach ap $sorted {
		set k [dict get $ap ssid]
		if {$k in $seen} continue
		lappend seen $k
		lappend out $ap
	}
	set out
}

proc nm::order {a b} {
	# the active network first, then the stronger, then the name (compared as text, so "10" follows "9" by string order)
	set x [expr {[dict get $a active] ? 0 : 1}]
	set y [expr {[dict get $b active] ? 0 : 1}]
	if {$x != $y} { return [expr {$x < $y ? -1 : 1}] }
	set x [dict get $a strength]
	set y [dict get $b strength]
	if {$x != $y} { return [expr {$x > $y ? -1 : 1}] }
	return [string compare [dict get $a ssid] [dict get $b ssid]]
}

# The first device of a type (1 ethernet, 2 Wi-Fi), or "" when there is none.
proc nm::device {type} {
	variable model
	foreach d [dict get $model devices] {
		if {[dict get $d type] == $type} { return $d }
	}
	return ""
}

# The device's state as the page says it: "Connected", "Cable unplugged" or "Not connected".
proc nm::ethernet_state {dev} {
	switch -- [dict get $dev state] {
		100 { return Connected }
		20 { return "Cable unplugged" }
		default { return "Not connected" }
	}
}
