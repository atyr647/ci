# settings-power-scene.tcl - Settings → Power (page-power.tcl) drawn under xvfb against the UPower and power-profiles-daemon
# stand-ins (tests/fixtures/upower.tcl, tests/fixtures/ppd.tcl), driven through the page's own hit areas (ui::press), as a click
# is. Sourced by apps/settings/main.tcl through RIBBON_SETTINGS_SCENE, with DBUS_SYSTEM_BUS_ADDRESS on the private bus,
# PPD_LOG and XDG_CONFIG_HOME set (the file the page writes is $XDG_CONFIG_HOME/ribbon/power.conf).
#   RIBBON_POWER_SHOT   = file: a grab of the page (ImageMagick import)
#   RIBBON_POWER_RESULT = file: the checks, one per line ("ok ..." or "FAIL ...")
# Exits 0 when every check passes, 1 otherwise, and 2 when the page does not load in time.

proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }

namespace eval ::pscene {
	variable fails 0
	variable lines {}
	variable grabbed 0
}

proc pscene::check {what ok} {
	variable fails
	variable lines
	if {$ok} { lappend lines "ok   $what" } else { lappend lines "FAIL $what"; incr fails }
}

# Run the event loop until COND is true, or MS pass.
proc pscene::wait {cond {ms 8000}} {
	set t [clock milliseconds]
	while {![uplevel #0 [list expr $cond]]} {
		if {[clock milliseconds] - $t > $ms} { return 0 }
		update
		after 30
	}
	return 1
}

# A click at page coordinates (x, y): the press on the canvas, as the pointer makes it.
proc pscene::click {x y} {
	page::draw_now
	ui::press [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]
	update
}

proc pscene::read_conf {} {
	set f [file join $::env(XDG_CONFIG_HOME) ribbon power.conf]
	if {![file exists $f]} { return {} }
	set fh [open $f]
	set out [split [string trimright [read $fh] \n] \n]
	close $fh
	return $out
}

proc pscene::slurp {f} { if {[catch {open $f} fh]} { return "" }; set t [read $fh]; close $fh; set t }
proc pscene::pklog {} { split [string trimright [pscene::slurp $::env(PKEXEC_LOG)] \n] \n }

proc pscene::log {} {
	if {![file exists $::env(PPD_LOG)]} { return {} }
	set fh [open $::env(PPD_LOG)]
	set out [split [string trimright [read $fh] \n] \n]
	close $fh
	return $out
}

proc pscene::finish {code} {
	variable lines
	if {[info exists ::env(RIBBON_POWER_RESULT)]} {
		set fh [open $::env(RIBBON_POWER_RESULT) w]
		puts $fh [join $lines \n]
		close $fh
	}
	puts [join $lines \n]
	exit $code
}

proc pscene::shot {} {
	if {![info exists ::env(RIBBON_POWER_SHOT)]} return
	page::draw_now; update idletasks
	variable grabbed 0
	after 400 [list apply {{f} { page::draw_now; update idletasks; exec import -window root $f; set ::pscene::grabbed 1 }} $::env(RIBBON_POWER_SHOT)]
	while {!$grabbed} { update; after 20 }
}

proc pscene::run {} {
	settings::select power
	if {![pscene::wait {$::power::loaded && [dict get $::power::model bat]}]} {
		puts stderr "the Power page did not read the battery: error=$::power::error"; exit 2
	}
	page::draw_now
	pscene::check "the subtitle reads Built-in battery, then Balanced" [expr {[power::subtitle] eq "Built-in battery · Balanced"}]
	pscene::shot

	# the power mode: the segmented control's Performance part (the right third of 800..1060 at y 461)
	pscene::click 1010 477
	pscene::wait {[llength [pscene::log]] > 0}
	pscene::check "choosing Performance sets the daemon's profile" [expr {"profile\tperformance" in [pscene::log]}]

	# the idle timers: "Turn off the screen", plugged in (910..1060 at y 269), opens its list; 10 minutes is the fourth item
	pscene::click 950 285
	pscene::check "the plugged-in screen timer opens its list" [expr {$::power::pop eq "pl_off"}]
	pscene::click 950 439
	pscene::check "choosing 10 minutes saves the plugged-in screen timer" [expr {"IDLE_PL_OFF=10" in [pscene::read_conf]}]
	pscene::check "the list closes after a choice" [expr {$::power::pop eq ""}]

	# a click outside an open list closes it and does nothing else
	pscene::click 800 333
	pscene::check "the on-battery lock timer's list is open" [expr {$::power::pop eq "bat_lock"}]
	pscene::click 400 600
	pscene::check "a click outside the list closes it" [expr {$::power::pop eq ""}]
	pscene::check "and the timer is not changed" [expr {"IDLE_BAT_LOCK=" ni [pscene::read_conf]}]

	# the dim switch (plugged in and on battery): turning it off saves no
	pscene::click 600 621
	pscene::check "turning the dim off saves DIM=no" [expr {"DIM=no" in [pscene::read_conf]}]

	# the root rows go through pkexec ribbon-power-helper (a stub pkexec runs the real helper on a fake root)
	set root $::env(RIBBON_POWER_ROOT)
	set dropin [file join $root etc elogind logind.conf.d 50-ribbon-power.conf]
	file delete -force [file join $root etc elogind logind.conf.d]
	file mkdir [file join $root etc UPower] [file join $root sys class power_supply BAT0]
	foreach {f v} [list [file join $root sys class power_supply BAT0 type] Battery \
		[file join $root sys class power_supply BAT0 charge_control_end_threshold] 100 \
		[file join $root etc UPower UPower.conf] "\[UPower\]\nPercentageLow=20\nPercentageCritical=5\nPercentageAction=2\nCriticalPowerAction=HybridSleep\n"] {
		set fh [open $f w]; puts $fh $v; close $fh
	}
	page::draw_now
	# Lid closed (on battery) at 472..622, y 461: its list opens (Suspend, Hibernate, Turn off the screen, Do nothing; items 36 tall from 505)
	pscene::click 540 470
	pscene::check "the lid row opens its list" [expr {$::power::pop eq "lid_bat"}]
	pscene::click 540 631
	pscene::wait {!$::power::rbusy}
	pscene::check "choosing Do nothing writes logind's drop-in through the helper" [expr {[file exists $dropin] && [string match "*HandleLidSwitch=ignore*" [pscene::slurp $dropin]]}]
	pscene::check "pkexec was run once for it" [expr {[llength [pscene::pklog]] == 1}]

	# Power button at 472..622, y 557: Ask is the first item; cancelled, the row stays
	set fh [open $::env(PKEXEC_MODE) w]; puts $fh cancel; close $fh
	pscene::click 540 566
	pscene::check "the power button row opens its list" [expr {$::power::pop eq "power_key"}]
	pscene::click 540 491   ;# the list opens upward here (no room below): Suspend is the third item
	pscene::wait {!$::power::rbusy}
	pscene::check "a cancelled pkexec leaves the power button as it was" [expr {![string match "*HandlePowerKey*" [pscene::slurp $dropin]] && [lindex [power::root_menu power_key] 1] eq "poweroff"}]
	pscene::check "and the subtitle says Cancelled" [expr {[power::subtitle] eq "Cancelled"}]
	set fh [open $::env(PKEXEC_MODE) w]; puts $fh ok; close $fh

	# Charge limit (970..1060, y 557): 80% is the third item
	pscene::click 1000 566
	pscene::check "the charge limit opens its list" [expr {$::power::pop eq "charge"}]
	pscene::click 1000 455   ;# upward too: 80% is the third item
	pscene::wait {!$::power::rbusy}
	pscene::check "choosing 80% writes the battery's threshold" [expr {[string trim [pscene::slurp [file join $root sys class power_supply BAT0 charge_control_end_threshold]]] eq "80"}]
	pscene::check "and the page reads 80%" [expr {[lindex [power::root_menu charge] 1] eq "80"}]

	pscene::shot
	pscene::finish [expr {$::pscene::fails ? 1 : 0}]
}

after 50 pscene::run
