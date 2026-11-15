# nm.tcl (fixture) - a NetworkManager stand-in for Settings → Network (U13). It owns org.freedesktop.NetworkManager
# on DBUS_SYSTEM_BUS_ADDRESS (a private bus in the test) and answers as the board's state: a Wi-Fi device "wlan0"
# connected to Hearth, an unplugged "eth0", six access points and a hidden one (a weaker copy of Hearth among
# them). Every action is logged, one tab-separated line each, to the file NM_LOG (appended): "connect SSID DEVICE
# AP", "deactivate PATH", "wifi 0|1". The Wi-Fi radio is a property: a Set emits PropertiesChanged.
# Profiles (U13b): Settings lists two saved profiles, Hearth (Wi-Fi, WPA2 with the password hunter2!!, connect
# automatically, not metered) and Office (WireGuard, down). Logged: "connect SSID DEVICE AP KEYMGMT SECRET HIDDEN"
# (SECRET 1 when a password was sent), "update PATH AUTOCONNECT METERED SECRET", "forget PATH",
# "activate PATH DEVICE", "wireguard NAME PUBLICKEY ENDPOINT ADDRESS".
lappend auto_path [file join [file dirname [file normalize [info script]]] .. .. srcpkgs ribbon-desktop files]
package require ribbon::dbus
fconfigure stdout -buffering line
set LOG $::env(NM_LOG)
proc logline {args} {
	global LOG
	set fh [open $LOG a]
	puts $fh [join $args "\t"]
	close $fh
}

set NM /org/freedesktop/NetworkManager
set I org.freedesktop.NetworkManager
set ac0 ${NM}/ActiveConnection/0
set devs [list ${NM}/Devices/0 ${NM}/Devices/1]
set aps {}
foreach n {1 2 3 4 5 6 7} { lappend aps ${NM}/AccessPoint/$n }

# The access points: number, SSID, strength, flags, WPA flags, RSN flags, frequency (MHz). Flags: 1 = privacy.
# RSN 0x100 is PSK, 0x400 SAE. Number 7 is hidden (an empty SSID) and so is left out of the list.
set apdata {
	1 Hearth 82 1 0 0x400 5180
	2 Hearth 31 1 0 0x100 2412
	3 Hearth-Guest 61 1 0 0x100 2437
	4 Ludo_2.4 47 1 0 0x100 2412
	5 Vodafone-7C2 22 1 0 0x100 2462
	6 {Cafe Lumen} 12 0 0 0 5180
	7 {} 70 1 0 0x100 2437
}

set bus [ribbon::dbus::connect system]
set SETTINGS ${NM}/Settings
set conn1 ${SETTINGS}/1
set conn2 ${SETTINGS}/2
# the saved profiles: their settings as NetworkManager keeps them (typed, secrets apart)
array set profiles [list \
	$conn1 [list connection [list id {s Hearth} type {s 802-11-wireless} autoconnect {b 1} metered {i 0}] \
		802-11-wireless [list ssid {ay Hearth} mode {s infrastructure}] \
		802-11-wireless-security [list key-mgmt {s wpa-psk}]] \
	$conn2 [list connection [list id {s Office} type {s wireguard} autoconnect {b 0} metered {i 0}] \
		wireguard [list private-key {s XFuwqtest}]]]
set secrets [list $conn1 [list 802-11-wireless-security [list psk {s hunter2!!}]]]
set nextconn 3

# The root: the device list, the radio and the connect and disconnect methods.
proc GetDevices {msg} { global devs; return $devs }
proc AddAndActivate {msg conn dev ap} {
	global ac0
	set id [lindex [dict get $conn connection id] 1]
	set hidden [expr {[dict exists $conn 802-11-wireless hidden] ? "hidden" : ""}]
	set keymgmt [expr {[dict exists $conn 802-11-wireless-security] ? [lindex [dict get $conn 802-11-wireless-security key-mgmt] 1] : "none"}]
	set secret [expr {[dict exists $conn 802-11-wireless-security psk] ? 1 : 0}]
	logline connect $id $dev $ap $keymgmt $secret $hidden
	# the stand-in does not make a new active connection: it answers with the existing one
	return [list $ac0 $ac0]
}
proc Deactivate {msg active} {
	global ac0
	# an unknown active connection is refused, as NetworkManager does
	if {$active ne $ac0} { throw {DBUS org.freedesktop.NetworkManager.Error.ActiveConnectionNotFound} "no such active connection" }
	logline deactivate $active
	return
}
proc WifiSet {m v} { logline wifi $v }
proc ActivateConn {msg conn dev ap} {
	global ac0 profiles
	if {![info exists profiles($conn)]} { throw {DBUS org.freedesktop.NetworkManager.Error.UnknownConnection} "no such profile" }
	logline activate $conn $dev
	return $ac0
}
proc ListConns {msg} { global profiles; return [lsort [array names profiles]] }
proc GetSettings {msg} { global profiles; return $profiles([dict get $msg path]) }
proc Update {msg conn} {
	global profiles
	set p [dict get $msg path]
	set auto [lindex [dict get $conn connection autoconnect] 1]
	set met [lindex [dict get $conn connection metered] 1]
	set secret [expr {[dict exists $conn 802-11-wireless-security psk] ? 1 : 0}]
	logline update $p $auto $met $secret
	set profiles($p) $conn
	return
}
proc Delete {msg} { global profiles; set p [dict get $msg path]; logline forget $p; unset profiles($p); return }
proc GetSecretsFor {msg setting} { global secrets; set p [dict get $msg path]; if {[dict exists $secrets $p]} { return [dict get $secrets $p] }; return {} }
proc AddConn {msg conn} {
	global nextconn profiles SETTINGS bus
	set p ${SETTINGS}/$nextconn
	incr nextconn
	set peer [lindex [dict get $conn wireguard peers] 1 0]
	set addr [lindex [dict get [lindex [lindex [dict get $conn ipv4 address-data] 1] 0] address] 1]
	logline wireguard [lindex [dict get $conn connection id] 1] [lindex [dict get $peer public-key] 1] [lindex [dict get $peer endpoint] 1] $addr
	set profiles($p) $conn
	$bus export $p org.freedesktop.NetworkManager.Settings.Connection [list \
		method GetSettings "" a{sa{sv}} GetSettings \
		method GetSecrets s a{sa{sv}} GetSecretsFor \
		method Update a{sa{sv}} "" Update \
		method Delete "" "" Delete]
	return $p
}

$bus export $NM $I {
	method GetDevices "" ao GetDevices
	method AddAndActivateConnection a{sa{sv}}oo oo AddAndActivate
	method ActivateConnection ooo o ActivateConn
	method DeactivateConnection o "" Deactivate
	property WirelessEnabled b readwrite {-value 1 -set {apply {{m v} {WifiSet $m $v}}}}
	property ActiveConnections ao read {-value {}}
}

$bus export $SETTINGS org.freedesktop.NetworkManager.Settings {
	method ListConnections "" ao ListConns
	method AddConnection a{sa{sv}} o AddConn
}

$bus export ${NM}/Devices/0 org.freedesktop.NetworkManager.Device [subst {
	property Interface s read {-value wlan0}
	property DeviceType u read {-value 2}
	property State u read {-value 100}
	property HwAddress s read {-value C8:94:02:5E:11:A7}
	property ActiveConnection o read {-value $ac0}
	property Ip4Config o read {-value ${NM}/IP4Config/0}
}]
$bus export ${NM}/Devices/0 org.freedesktop.NetworkManager.Device.Wireless [subst {
	property AccessPoints ao read {-value {$aps}}
	property ActiveAccessPoint o read {-value ${NM}/AccessPoint/1}
	property Bitrate u read {-value 866700}
	property HwAddress s read {-value C8:94:02:5E:11:A7}
}]

# The wired device: unplugged.
$bus export ${NM}/Devices/1 org.freedesktop.NetworkManager.Device {
	property Interface s read {-value eth0}
	property DeviceType u read {-value 1}
	property State u read {-value 20}
	property HwAddress s read {-value 52:54:00:AB:CD:01}
	property ActiveConnection o read {-value /}
	property Ip4Config o read {-value /}
}

# The active connection on wlan0.
$bus export $ac0 org.freedesktop.NetworkManager.Connection.Active [subst {
	property Connection o read {-value $conn1}
	property Id s read {-value Hearth}
	property Type s read {-value 802-11-wireless}
	property State u read {-value 2}
	property Devices ao read {-value [list ${NM}/Devices/0]}
}]

# The DHCP lease of wlan0: the address, the gateway and two name servers.
$bus export ${NM}/IP4Config/0 org.freedesktop.NetworkManager.IP4Config {
	property AddressData aa{sv} read {-value {{address {s 192.168.1.42} prefix {u 24}}}}
	property Gateway s read {-value 192.168.1.1}
	property NameserverData aa{sv} read {-value {{address {s 192.168.1.1}} {address {s 9.9.9.9}}}}
}

foreach {n ssid strength flags wpa rsn freq} $apdata {
	set p ${NM}/AccessPoint/$n
	# an empty SSID is a hidden network: NetworkManager sends no bytes for it
	set bytes [expr {$ssid eq "" ? "" : [encoding convertto utf-8 $ssid]}]
	$bus export $p org.freedesktop.NetworkManager.AccessPoint [list \
		property Ssid ay read [list -value $bytes] \
		property Strength y read [list -value $strength] \
		property Flags u read [list -value $flags] \
		property WpaFlags u read [list -value $wpa] \
		property RsnFlags u read [list -value $rsn] \
		property Frequency u read [list -value $freq] \
		property HwAddress s read [list -value 02:00:00:00:00:0$n]]
}

# the saved profiles: each one answers the Connection interface
foreach c [list $conn1 $conn2] {
	$bus export $c org.freedesktop.NetworkManager.Settings.Connection [list \
		method GetSettings "" a{sa{sv}} GetSettings \
		method GetSecrets s a{sa{sv}} GetSecretsFor \
		method Update a{sa{sv}} "" Update \
		method Delete "" "" Delete]
}

if {[$bus request $I] ne "primary"} { puts "error cannot own the name"; exit 1 }
puts ready
vwait forever
