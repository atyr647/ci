# settings-network-scene.tcl -- Settings → Network (page-network.tcl) drawn under xvfb against the NetworkManager
# stand-in (tests/fixtures/nm.tcl), and driven through the page's own hit areas (ui::press), as a click is.
# Sourced by apps/settings/main.tcl through RIBBON_SETTINGS_SCENE, with DBUS_SYSTEM_BUS_ADDRESS on the private bus and
# NM_LOG set.
#   RIBBON_NETWORK_SHOT   = file: a grab of the page (ImageMagick import)
#   RIBBON_NETWORK_RESULT = file: the checks, one per line ("ok ..." or "FAIL ...")
# Exits 0 when every check passes, 1 otherwise, and 2 when the page does not load in time.

proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }

namespace eval ::nscene {
	variable fails 0
	variable lines {}
}

proc nscene::check {what ok} {
	variable fails
	variable lines
	if {$ok} { lappend lines "ok   $what" } else { lappend lines "FAIL $what"; incr fails }
}

# Run the event loop until COND is true, or MS pass.
proc nscene::wait {cond {ms 8000}} {
	set t [clock milliseconds]
	while {![uplevel #0 [list expr $cond]]} {
		if {[clock milliseconds] - $t > $ms} { return 0 }
		update
		after 30
	}
	return 1
}

# A click at page coordinates (x, y): the press on the canvas, as the pointer makes it.
proc nscene::click {x y} {
	page::draw_now
	ui::press [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]
	update
}

proc nscene::log {} {
	if {![file exists $::env(NM_LOG)]} { return {} }
	set fh [open $::env(NM_LOG)]
	set out [split [string trimright [read $fh] \n] \n]
	close $fh
	return $out
}

proc nscene::finish {code} {
	variable lines
	if {[info exists ::env(RIBBON_NETWORK_RESULT)]} {
		set fh [open $::env(RIBBON_NETWORK_RESULT) w]
		puts $fh [join $lines \n]
		close $fh
	}
	puts [join $lines \n]
	exit $code
}

proc nscene::shot {} {
	if {![info exists ::env(RIBBON_NETWORK_SHOT)]} return
	page::draw_now; update idletasks
	after 400 [list apply {{f} { page::draw_now; update idletasks; exec import -window root $f; set ::nscene::grabbed 1 }} $::env(RIBBON_NETWORK_SHOT)]
	variable grabbed 0
	while {!$grabbed} { update; after 20 }
}

proc nscene::run {} {
	settings::select network
	if {![nscene::wait {$::nm::loaded && [llength [dict get $::nm::model devices]] == 2}]} {
		puts stderr "the Network page did not read its devices: error=$::nm::error"; exit 2
	}
	page::draw_now
	# the board's state: Hearth joined, the detail pane shows its facts, the radio is on
	nscene::check "the subtitle says Connected to Hearth" [expr {[nm::subtitle] eq "Connected to Hearth"}]
	set ch [nm::chosen]
	nscene::check "the detail shows the joined network Hearth" \
		[expr {[dict get $ch kind] eq "ap" && [dict get [dict get $ch ap] active] && [dict get [dict get $ch ap] ssid] eq "Hearth"}]
	nscene::check "the list has five networks, Hearth first" \
		[expr {[llength [nm::networks [nm::device 2]]] == 5 && [dict get [lindex [nm::networks [nm::device 2]] 0] ssid] eq "Hearth"}]
	nscene::shot

	# the Cafe Lumen row is open: choosing it shows Connect at the footer's right, and Connect joins it
	set cafe ""
	foreach ap [nm::networks [nm::device 2]] { if {[dict get $ap ssid] eq "Cafe Lumen"} { set cafe [dict get $ap path] } }
	# the rows: Hearth 149 (52), then 44 each: Hearth-Guest 201, Ludo 245, Vodafone 289, Cafe 333
	nscene::click 400 355
	page::draw_now
	nscene::check "choosing Cafe Lumen shows it as the chosen network" [expr {[nm::chosen_path] eq $cafe}]
	nscene::click 1040 684
	nscene::wait {[llength [nscene::log]] > 0}
	nscene::check "Connect joins Cafe Lumen on the Wi-Fi device" \
		[expr {"connect\tCafe Lumen\t[dict get [nm::device 2] path]\t$cafe\tnone\t0\t" in [nscene::log]}]

	# the radio: a click on the switch turns the radio off, and the log says so
	nscene::click 520 130
	nscene::wait {[dict get $::nm::model wifi] == 0 || [lsearch -glob [nscene::log] "wifi*"] >= 0}
	nscene::check "the switch turns the radio off" [expr {"wifi\t0" in [nscene::log]}]

	nscene::finish [expr {$::nscene::fails ? 1 : 0}]
}

after 50 nscene::run
