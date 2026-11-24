# settings-network.tcl - Settings → Network's client (apps/settings/nm.tcl) against the NetworkManager stand-in
# (tests/fixtures/nm.tcl) on a private system bus, with no display. Run by tests/steps.d/55-settings-network.sh:
#   DBUS_SYSTEM_BUS_ADDRESS=<private bus> NM_LOG=<log file> TCLLIBPATH="<unix_extra> <files>" tclsh8.6 tests/settings-network.tcl FILES
# FILES is the srcpkgs/ribbon-desktop/files folder. Prints one line per check; exits non-zero on the first failure.
set D [lindex $argv 0]
set LOG $::env(NM_LOG)
set fails 0
proc check {what ok} {
	global fails
	if {$ok} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}

source [file join $D apps settings nm.tcl]
source [file join $D apps settings nm-secrets.tcl]

# A background step finished: the model's change callback counts them.
set changes 0
set nm::onchange {incr ::changes}

# Run the event loop until the count of changes passes N and no read is running; fail after 8 s.
proc settle {n} {
	set t [clock milliseconds]
	while {$::changes <= $n || $nm::busy} {
		if {[clock milliseconds] - $t > 8000} { return 0 }
		update
		after 10
	}
	return 1
}
proc settled {} { settle [expr {$::changes}] }

proc logged {} {
	global LOG
	if {![file exists $LOG]} { return {} }
	set fh [open $LOG]
	set out [split [string trimright [read $fh] \n] \n]
	close $fh
	return $out
}

# ---- the read ----------------------------------------------------------------------
set n $changes
nm::refresh
check "a read finishes" [settle $n]
set m $nm::model
check "the read reports no error" [expr {[dict get $m error] eq ""}]
check "the Wi-Fi radio is on" [expr {[dict get $m wifi] == 1}]
set devs [dict get $m devices]
check "two devices: Wi-Fi and wired" [expr {[llength $devs] == 2}]
set wifi [nm::device 2]
set eth [nm::device 1]
check "wlan0 is the Wi-Fi device" [expr {[dict get $wifi iface] eq "wlan0"}]
check "the active connection is Hearth" [expr {[dict get $wifi active] eq "Hearth"}]
check "the IP address and gateway are read" [expr {[dict get $wifi ip address] eq "192.168.1.42" && [dict get $wifi ip gateway] eq "192.168.1.1"}]
check "the name servers are read in order" [expr {[dict get $wifi ip dns] eq {192.168.1.1 9.9.9.9}}]
check "the hardware address and the Wi-Fi rate (866 Mb/s)" [expr {[dict get $wifi hw] eq "C8:94:02:5E:11:A7" && [dict get $wifi rate] == 866}]
check "eth0 is unplugged" [expr {[nm::ethernet_state $eth] eq "Cable unplugged"}]

# ---- the list: the board's order, one per network, no hidden one ----------------------
set nets [nm::networks $wifi]
set names {}
foreach a $nets { lappend names [dict get $a ssid] }
check "the networks, active first then by strength: [join $names {, }]" \
	[expr {$names eq [list Hearth Hearth-Guest Ludo_2.4 Vodafone-7C2 "Cafe Lumen"]}]
check "the weaker copy of Hearth is left out" [expr {[llength $nets] == 5}]
check "the hidden network is left out" [expr {"" ni $names}]
set h [lindex $nets 0]
check "Hearth is WPA3 (SAE) on 5 GHz with four bars" [expr {[nm::security [dict get $h flags] [dict get $h wpa] [dict get $h rsn]] eq "WPA3" && [nm::band [dict get $h freq]] eq "5 GHz" && [nm::bars [dict get $h strength]] == 4}]
set cafe [lindex $nets 4]
check "Cafe Lumen is open" [expr {[nm::security [dict get $cafe flags] [dict get $cafe wpa] [dict get $cafe rsn]] eq "Open"}]
check "Hearth-Guest is WPA2 on 2.4 GHz" [expr {[nm::security 1 0 0x100] eq "WPA2" && [nm::band 2412] eq "2.4 GHz"}]

# ---- actions: connect to an open network, disconnect, the radio ------------------------
set n $changes
nm::job nm::connect_ap [dict get $eth path] [dict get $cafe path] [dict get $cafe bytes]
check "connecting to an open network is sent and the model refreshed" [settle $n]
check "the connect call named Cafe Lumen on the device with its access point" \
	[expr {"connect\tCafe Lumen\t[dict get $eth path]\t[dict get $cafe path]\tnone\t0\t" in [logged]}]
check "no error after connecting" [expr {$nm::error eq ""}]

set n $changes
nm::job nm::disconnect [dict get $wifi activepath]
check "disconnecting sends DeactivateConnection for the active connection" [settle $n]
check "the deactivate line is in the log" \
	[expr {[lsearch -glob [logged] "deactivate\t[dict get $wifi activepath]"] >= 0}]

set n $changes
nm::job nm::set_wifi 0
check "turning the radio off is sent" [settle $n]
check "the radio line says 0" [expr {"wifi\t0" in [logged]}]
check "the model reads the radio off" [expr {[dict get $nm::model wifi] == 0}]

set n $changes
nm::job nm::set_wifi 1
check "turning the radio on again" [settle $n]
check "the radio line says 1" [expr {"wifi\t1" in [logged]}]

# ---- an action that NetworkManager refuses leaves the error for the page --------------
set n $changes
nm::job nm::disconnect "/org/freedesktop/NetworkManager/ActiveConnection/99"
check "a refused action is reported, not thrown" [settle $n]
check "the refusal is kept as the error" [expr {$nm::error ne ""}]

# ---- the error text when there is no NetworkManager ----------------------------------
set ::errorCode {DBUS org.freedesktop.DBus.Error.ServiceUnknown}
check "no NetworkManager on the bus is named" [expr {[nm::explain "x"] eq "NetworkManager is not running"}]
set ::errorCode NONE
check "other errors keep their text" [expr {[nm::explain "boom"] eq "boom"}]

# ---- the order of the list: active first, then strength, then the name -----------------
set sorted [lsort -command nm::order [list \
	[dict create active 0 strength 50 ssid B] [dict create active 1 strength 10 ssid Z] \
	[dict create active 0 strength 50 ssid A] [dict create active 0 strength 80 ssid C]]]
set order {}
foreach a $sorted { lappend order [dict get $a ssid] }
check "nm::order: active, then strength, then the name as text ($order)" [expr {$order eq {Z C A B}}]
check "bands: 6 GHz from 5925 MHz, none from 0" [expr {[nm::band 5955] eq "6 GHz" && [nm::band 0] eq ""}]
check "SSIDs decode as UTF-8" [expr {[nm::ssid_text [encoding convertto utf-8 "Café"]] eq "Café"}]

# ---- U13b: saved profiles, secured and hidden networks, save, forget, reveal, WireGuard --------
set wifi [nm::device 2]
set profiles [dict get $nm::model saved]
set hearth [nm::profile_for Hearth]
check "the saved Wi-Fi profile Hearth is read (autoconnect on, path /Settings/1)" \
	[expr {$hearth ne "" && [dict get $hearth autoconnect] == 1 && [dict get $hearth path] eq "/org/freedesktop/NetworkManager/Settings/1"}]
check "the WireGuard profile Office is a VPN row, down" \
	[expr {[llength [nm::vpns]] == 1 && [dict get [lindex [nm::vpns] 0] id] eq "Office" && [dict get [lindex [nm::vpns] 0] active] eq ""}]
check "a network with no saved profile has none (Cafe Lumen)" [expr {[nm::profile_for "Cafe Lumen"] eq ""}]

# a secured network: a new profile with the password, WPA2 then WPA3 (SAE)
set guest ""
foreach ap [nm::networks $wifi] { if {[dict get $ap ssid] eq "Hearth-Guest"} { set guest $ap } }
set n $changes
nm::job nm::connect_secured [dict get $wifi path] [dict get $guest path] [dict get $guest bytes] "correct horse" 0
check "a secured join sends WPA-PSK with the password" [settle $n] 
check "the join line says wpa-psk and that a password was sent" \
	[expr {"connect\tHearth-Guest\t[dict get $wifi path]\t[dict get $guest path]\twpa-psk\t1\t" in [logged]}]
set n $changes
nm::job nm::connect_secured [dict get $wifi path] [dict get $guest path] [dict get $guest bytes] "correct horse" 1
settle $n
check "a WPA3 join sends SAE" [expr {"connect\tHearth-Guest\t[dict get $wifi path]\t[dict get $guest path]\tsae\t1\t" in [logged]}]

# a hidden network: a new profile named as typed, no password (open) and then with one
set n $changes
nm::job nm::connect_hidden "Quiet Room" ""
settle $n
check "a hidden open network is added with hidden set" [expr {"connect\tQuiet Room\t/\t/\tnone\t0\thidden" in [logged]}]
set n $changes
nm::job nm::connect_hidden "Quiet Room" "secretpass"
settle $n
check "a hidden secured network is sent with its password" [expr {"connect\tQuiet Room\t/\t/\twpa-psk\t1\thidden" in [logged]}]

# the saved profile: the password is read through GetSecrets (shown on reveal)
check "the saved password is read (GetSecrets)" [expr {[nm::reveal [dict get $hearth path]] eq "hunter2!!"}]

# Save writes autoconnect and metered, and keeps the password (the Update carries it from GetSecrets)
set n $changes
nm::job nm::save_profile [dict get $hearth path] 0 2 ""
settle $n
check "Save sends the new autoconnect and metered values, and keeps the password" \
	[expr {"update\t[dict get $hearth path]\t0\t2\t1" in [logged]}]

# a password change goes through the same Update
set n $changes
nm::job nm::save_profile [dict get $hearth path] 1 0 "newpassword"
settle $n
check "a changed password is written with the profile" [expr {"update\t[dict get $hearth path]\t1\t0\t1" in [logged]}]

# activate a saved profile on the device (join by profile, not by a new one)
set n $changes
nm::job nm::activate [dict get $hearth path] [dict get $wifi path]
settle $n
check "joining a saved network activates its profile on the device" \
	[expr {"activate\t[dict get $hearth path]\t[dict get $wifi path]" in [logged]}]

# WireGuard: a .conf file becomes a profile (its key, peer and address)
set conf [file join [file dirname $LOG] office.conf]
set fh [open $conf w]
puts $fh "# the office\n\[Interface\]\nPrivateKey = abcKEY=\nAddress = 10.8.0.2/24\n\n\[Peer\]\nPublicKey = pubKEY=\nEndpoint = vpn.example:51820\nAllowedIPs = 0.0.0.0/0, ::/0"
close $fh
set n $changes
nm::job nm::add_wireguard $conf
settle $n
check "a WireGuard file is imported: its name, peer key, endpoint and address" \
	[expr {"wireguard\toffice\tpubKEY=\tvpn.example:51820\t10.8.0.2" in [logged]}]
check "a file that is not WireGuard is refused, with the error kept" [expr {[catch {nm::add_wireguard [file join [file dirname $LOG] none.conf]} e] && $e ne ""}]

# a VPN switch brings the profile up and down
set office [lindex [nm::vpns] 0]
set n $changes
nm::job nm::vpn_toggle [dict get $office path] "" 1
settle $n
check "a VPN is brought up (ActivateConnection on its profile)" \
	[expr {"activate\t[dict get $office path]\t/" in [logged]}]

# forget: the profile is deleted
set n $changes
nm::job nm::forget [dict get $office path]
settle $n
check "Forget deletes the profile" [expr {"forget\t[dict get $office path]" in [logged]}]

if {$fails} { puts "$fails check(s) failed"; exit 1 }
puts "all checks passed"
