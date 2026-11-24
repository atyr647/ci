# preview.tcl - the login screen as the Appearance app shows it behind its
# sheet (RIBBON_GREETER_TEST=this file, with RIBBON_GREETER_ETC pointing at
# the candidate palette, background and options.conf). It never talks to
# greetd and takes no input: what you see is how the login screen will
# look, your account chosen and a password being typed. The corner pills
# and "Other user" are left out, as the sheet covers that part.
#   RIBBON_PREVIEW_USER  the account shown (default: $USER)
#   RIBBON_PREVIEW_TIME  "HH:MM|Day D Month" instead of the clock (tests)
#   RIBBON_PREVIEW_STATUS "WIFI|BATTERY" (on|82) instead of the sensors (tests)
set ui::preview 1
set st [sys::statefile]
file mkdir [file dirname $st]
set who [expr {[info exists ::env(RIBBON_PREVIEW_USER)] ? $::env(RIBBON_PREVIEW_USER) : [expr {[info exists ::env(USER)] ? $::env(USER) : ""}]}]
set fh [open $st w]; puts $fh "user=$who"; close $fh
unset -nocomplain ::env(GREETD_SOCK)
login::start
set login::view password
set login::prompt "Password: "
set login::secret 12345678
if {[info exists ::env(RIBBON_PREVIEW_TIME)]} {
	lassign [split $::env(RIBBON_PREVIEW_TIME) |] login::time login::date
} else {
	login::clock_tick
}
if {[info exists ::env(RIBBON_PREVIEW_STATUS)]} {
	lassign [split $::env(RIBBON_PREVIEW_STATUS) |] status::wifi status::battery
} else {
	status::wifi_tick
	status::battery_tick
}
# "reload": the palette, the picture and options.conf again (the app has
# changed them, or has made the real blur for the cheap one shown)
proc preview_reload {} {
	destroy .c
	catch { image delete $ui::bg $ui::wallimg }
	if {$wall::full ne ""} { catch { image delete $wall::full } }
	set wall::full ""
	theme::load
	set wall::image [greeter::background]
	set ui::opt [greeter::options]
	ui::init
	foreach ev {<KeyPress> <KeyRelease>} { bind . $ev {} }
	foreach ev {<ButtonPress-1> <ButtonPress-3> <Motion>} { bind .c $ev {} }
	ui::redraw
}

# under the Appearance sheet, always: it may come up after it
bind . <Map> { after 30 { catch { lower . } } }
after 100 { catch { lower . } }
foreach ev {<KeyPress> <KeyRelease>} { bind . $ev {} }
foreach ev {<ButtonPress-1> <ButtonPress-3> <Motion>} { bind .c $ev {} }
# the Appearance app asks for a redraw with new settings on stdin
if {[info exists ::env(RIBBON_PREVIEW_STDIN)]} {
	fconfigure stdin -blocking 0
	# a slider drag sends many: read them all, reload once
	fileevent stdin readable {
		set reload 0
		while {[gets stdin line] >= 0} {
			if {$line eq "quit"} exit
			if {$line eq "reload"} { set reload 1 }
		}
		if {[eof stdin]} exit
		if {$reload} preview_reload
	}
}
