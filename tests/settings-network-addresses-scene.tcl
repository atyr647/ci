# settings-network-addresses-scene.tcl -- Settings → Network, the saved network's Addresses dropdown and the sheets'
# text (nm-secrets.tcl), drawn under xvfb against the NetworkManager stand-in (tests/fixtures/nm.tcl) and driven
# through the page's own hit areas (ui::press), as clicks are. Run by tests/steps.d/57-settings-network-addresses.sh.
#   RIBBON_NETWORK_RESULT = file: the checks, one per line ("ok ..." or "FAIL ...")
# Exits 0 when every check passes, 1 otherwise, 2 when the page does not load in time.

proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }

namespace eval ::ascene {
	variable fails 0
	variable lines {}
	variable drawn {}   ;# {text colour} of every ui::text since the last draw
}
proc ascene::check {what ok} {
	variable fails; variable lines
	if {$ok} { lappend lines "ok   $what" } else { lappend lines "FAIL $what"; incr fails }
}
proc ascene::wait {cond {ms 8000}} {
	set t [clock milliseconds]
	while {![uplevel #0 [list expr $cond]]} {
		if {[clock milliseconds] - $t > $ms} { return 0 }
		update
		after 30
	}
	return 1
}
# Draw now and keep what was drawn.
proc ascene::draw {} {
	variable drawn
	set drawn {}
	page::draw_now
	update idletasks
}
trace add execution ui::text enter [list ::apply {{cmd op} { lappend ::ascene::drawn [list [lindex $cmd 3] [lindex $cmd 5]] }}]
proc ascene::texts {} { lmap d $::ascene::drawn { lindex $d 0 } }
proc ascene::colour_of {t} { foreach d $::ascene::drawn { if {[lindex $d 0] eq $t} { return [lindex $d 1] } }; return "" }
proc ascene::click {x y} {
	ascene::draw
	ui::press [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]
	update
}
proc ascene::finish {code} {
	variable lines
	if {[info exists ::env(RIBBON_NETWORK_RESULT)]} {
		set fh [open $::env(RIBBON_NETWORK_RESULT) w]; puts $fh [join $lines \n]; close $fh
	}
	puts [join $lines \n]
	exit $code
}
proc ascene::hearth {} { nm::profile_for Hearth }

proc ascene::run {} {
	settings::select network
	if {![ascene::wait {$::nm::loaded && [llength [dict get $::nm::model devices]] == 2}]} {
		puts stderr "the Network page did not read its devices: error=$::nm::error"; exit 2
	}
	variable path [dict get [ascene::hearth] path]
	ascene::draw
	ascene::wait {[dict get [nm::ipv4_of [dict get [ascene::hearth] path]] method] ne ""}
	ascene::draw
	ascene::check "Addresses reads Hearth's ipv4.method: Automatic (DHCP)" \
		[expr {[dict get [nm::ipv4_of $path] method] eq "auto" && "Automatic (DHCP)" in [ascene::texts]}]
	if {[info exists ::env(RIBBON_NETWORK_SHOT)]} { after 300 {set ::ascene::shot 1}; vwait ::ascene::shot; ascene::draw; exec import -window root $::env(RIBBON_NETWORK_SHOT) }
	ascene::check "an automatic profile with no addresses of its own offers only Automatic (DHCP)" \
		[expr {[llength [nm::ipv4_items [ascene::hearth]]] == 1}]

	# NetworkManager's property changes (a signal strength, a scan) read the model again: Addresses keeps showing the
	# method (and keeps the keyboard) while the profile is read again, it does not go blank in between
	set ::ui::focus nm_ipv4
	set ::ascene::shown {}
	set tr [list ::apply {{cmd op} { lappend ::ascene::shown [nm::value [lindex $cmd 1] ipv4] }}]
	trace add execution nm::draw_connection enter $tr
	nm::refresh
	ascene::wait {!$::nm::busy}
	ascene::draw
	ascene::wait {[dict get [nm::ipv4_of [dict get [ascene::hearth] path]] method] ne ""}
	ascene::draw
	trace remove execution nm::draw_connection enter $tr
	ascene::check "a new read of the model keeps Addresses drawn (Automatic (DHCP)) and focused (drawn as: $::ascene::shown)" \
		[expr {[lsort -unique $::ascene::shown] eq "auto" && "nm_ipv4" in [lmap f $::ui::focusables { lindex $f 0 }]}]
	ascene::wait {[dict get [nm::ipv4_of [dict get [ascene::hearth] path]] method] ne ""}
	set ::ui::focus ""

	# the profile is made manual elsewhere (nmcli, another tool): the page shows Manual
	nm::ensure_bus
	set raw [nm::raw_settings $path]
	dict set raw ipv4 [dict create method [list s manual] \
		address-data [list aa{sv} [list [dict create address [list s 192.168.1.50] prefix [list u 24]]]]]
	$nm::bus call $nm::dest $path $nm::conniface Update "a{sa{sv}}" $raw
	nm::refresh
	ascene::wait {[dict get [nm::ipv4_of [dict get [ascene::hearth] path]] method] eq "manual"}
	ascene::draw
	ascene::check "a manual profile shows Manual" [expr {"Manual" in [ascene::texts] && "Automatic (DHCP)" ni [ascene::texts]}]

	# the dropdown opens its list (Automatic (DHCP), Manual), a pick is pending, Save writes ipv4.method
	ascene::click 970 523
	ascene::draw
	ascene::check "a click on Addresses opens its list with Automatic (DHCP) and Manual" \
		[expr {$::sctl::pop eq "nm_ipv4" && [llength [dict get $::sctl::popd items]] == 2 && "Automatic (DHCP)" in [ascene::texts]}]
	ascene::click 900 568
	ascene::draw
	ascene::check "picking Automatic (DHCP) closes the list and shows it, pending" \
		[expr {$::sctl::pop eq "" && [nm::value [ascene::hearth] ipv4] eq "auto" && "Automatic (DHCP)" in [ascene::texts]
			&& [dict get [nm::ipv4_read $path] method] eq "manual"}]
	ascene::click 1030 684
	ascene::wait {[dict get [nm::ipv4_read $::ascene::path] method] eq "auto"}
	ascene::check "Save writes ipv4.method auto to the profile (Connection.Update)" [expr {[dict get [nm::ipv4_read $path] method] eq "auto"}]
	ascene::wait {!$::nm::busy && [dict get [nm::ipv4_of [dict get [ascene::hearth] path]] method] eq "auto"}
	ascene::draw
	ascene::check "after Save the page reads the profile again: Automatic (DHCP)" [expr {"Automatic (DHCP)" in [ascene::texts]}]

	# the eye at the Password row's end (the board's place) shows the saved password
	ascene::click 1052 571
	ascene::wait {$::nm::reveal}
	ascene::draw
	ascene::check "the eye shows the saved password" [expr {$::nm::reveal && "hunter2!!" in [ascene::texts]}]

	# the hidden network sheet: no helper lines, the label is PASSWORD, an error is drawn in the text colour
	set y [expr {149 + 52 + 44 * ([llength [nm::networks [nm::device 2]]] - 1)}]
	ascene::click 400 [expr {$y + 22}]
	ascene::draw
	set t [ascene::texts]
	ascene::check "the Hidden network row opens its sheet" [expr {$::nm::sheet eq "hidden"}]
	ascene::check "the hidden sheet has no helper line, and its password label is PASSWORD" \
		[expr {"Hidden network" in $t && "PASSWORD" in $t && "NETWORK NAME" in $t
			&& [lsearch -glob $t "Joins a network*"] < 0 && [lsearch -glob $t "*EMPTY FOR OPEN*"] < 0}]
	ascene::click 831 480
	ascene::draw
	ascene::check "Join with no name says so in the text colour, not the accent" \
		[expr {[ascene::colour_of "Type the network's name."] eq $::ui::c(fg)}]
	nm::sheet_close
	ascene::click 300 684
	ascene::draw
	set t [ascene::texts]
	ascene::check "Add connection opens the WireGuard sheet, with no helper line" \
		[expr {$::nm::sheet eq "wireguard" && "Add a WireGuard connection" in $t && [lsearch -glob $t "Imports*"] < 0}]
	ascene::finish [expr {$::ascene::fails ? 1 : 0}]
}
after 50 ascene::run
