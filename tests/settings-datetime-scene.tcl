# settings-datetime-scene.tcl - Settings → Date and time (page-datetime.tcl) in its boards' states (Settings-A10-Date-Time,
# and -A10b-Date-Picker with RIBBON_SCENE=picker), with datetime.tcl's readings and its helper call stood in for: the
# clock stands at Saturday 7 November 2026, 10:42:30 in Europe/London, the settings are an array, and dt::helper records
# what would go to `pkexec ribbon-time-helper` (dt::set_zone, set_date, set_time and set_ntp themselves are the real
# ones). The page's drawing and its hits are what is checked here; datetime.tcl itself is tests/settings-datetime.tcl.
# Sourced by apps/settings/main.tcl through RIBBON_SETTINGS_SCENE.
#   RIBBON_DT_SHOT   = file: a grab of the window (ImageMagick import)
#   RIBBON_DT_RESULT = file: the checks, one per line ("ok ..." or "FAIL ...")
proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }
set ui::caretfix off
namespace eval dscene { variable fails 0; variable lines {}; variable calls {} }
proc dscene::check {what cond} { variable fails; variable lines; if {[uplevel #0 [list expr $cond]]} { lappend lines "ok   $what" } else { lappend lines "FAIL $what ([lindex $::dscene::calls end])"; incr fails } }
proc dscene::click {x y} { page::draw_now; ui::press [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; ui::release [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; update; page::draw_now; update }
proc dscene::key {sym {char ""}} { page::draw_now; settings::key $sym $char 0; update; page::draw_now; update }
proc dscene::last {} { lindex $::dscene::calls end }

set dscene::zone Europe/London
set dscene::zones {UTC Africa/Cairo Africa/Lagos America/Chicago America/Los_Angeles America/New_York America/Sao_Paulo \
	Asia/Kolkata Asia/Shanghai Asia/Tokyo Australia/Sydney Europe/Berlin Europe/London Europe/Paris Pacific/Auckland}
set dscene::now [clock scan "2026-11-07 10:42:30" -format "%Y-%m-%d %H:%M:%S" -timezone :Europe/London]
array set dscene::conf {HOUR24 yes SECONDS no DATE yes WEEKSTART monday}
proc dt::now {} { return $::dscene::now }
proc dt::zone {} { return $::dscene::zone }
proc dt::zones {} { return $::dscene::zones }
proc dt::setting {k} { return $::dscene::conf($k) }
proc dt::conf_set {k v} { lappend ::dscene::calls [list conf $k $v]; set ::dscene::conf($k) $v; return 1 }
proc dt::start {} {}
proc dt::refresh {} {}
# what the helper would be asked, and the system after it
proc dt::helper {args} {
	if {$::dt::busy} { return 0 }
	lappend ::dscene::calls $args
	switch -- [lindex $args 0] {
		zone { set ::dscene::zone [lindex $args 1] }
		ntp { set ::dt::ntpon [expr {[lindex $args 1] eq "on"}] }
		set {
			# the date alone keeps the time of day (the helper reads it then)
			set hms [expr {[llength $args] > 2 ? [lindex $args 2] : [clock format $::dscene::now -format %H:%M:%S -timezone :$::dscene::zone]}]
			set ::dscene::now [clock scan "[lindex $args 1] $hms" -format "%Y-%m-%d %H:%M:%S" -timezone :$::dscene::zone]
		}
	}
	return 1
}
set dt::service chronyd
set dt::ntpon 1

set scene [expr {[info exists ::env(RIBBON_SCENE)] ? $::env(RIBBON_SCENE) : "main"}]
settings::select datetime
page::draw_now; update
if {$scene eq "picker"} {
	# the board: the clock set by hand, the picker open, the filled day moved from the 7th to the 12th
	set dt::ntpon 0
	dscene::click 549 349
	foreach k {Right Right Right Right Right} { dscene::key $k }
}
page::draw_now; update; page::draw_now; update
if {[info exists ::env(RIBBON_DT_SHOT)]} { after 500; update; exec import -window [winfo id $::settings::win] $::env(RIBBON_DT_SHOT) }

if {$scene eq "picker"} {
	dscene::check "a click on Date opens the picker on this month, and the arrows move the filled day" {$dtp::cal && $dtp::sel eq {2026 11 12} && $dtp::cm == 11 && $dscene::calls eq {}}
	dscene::key Return
	dscene::check "Return sets the filled day, the time of day kept" {[dscene::last] eq {set 2026-11-12} && !$dtp::cal}
	dscene::click 549 349
	dscene::click 589 525
	dscene::check "a click on a day sets that date" {[dscene::last] eq {set 2026-11-14} && !$dtp::cal}
	set n [llength $dscene::calls]
	dscene::click 549 349
	dscene::click 621 401
	dscene::check "the right chevron shows the next month" {$dtp::cal && $dtp::cy == 2026 && $dtp::cm == 12}
	dscene::click 589 401
	dscene::click 589 401
	dscene::check "the left chevron the month before" {$dtp::cal && $dtp::cm == 10 && [llength $dscene::calls] == $n}
	dscene::click 429 461
	dscene::check "a day of the month before sets that date too (28 September in October's first week)" {[dscene::last] eq {set 2026-09-28}}
	dscene::click 549 349
	dscene::key Next; dscene::key Up
	dscene::check "Page Down moves the filled day a month on, Up a week back" {$dtp::sel eq {2026 10 21} && $dtp::cm == 10}
	dscene::key Escape
	dscene::check "Escape closes the picker and sets nothing" {!$dtp::cal && [dscene::last] eq {set 2026-09-28}}
	dscene::click 549 349
	dscene::click 900 600
	dscene::check "a click elsewhere closes it" {!$dtp::cal && [dscene::last] eq {set 2026-09-28}}
	dscene::click 549 349
	dscene::click 429 589
	dscene::check "a click on today (28 September by now) sets nothing" {!$dtp::cal && [dscene::last] eq {set 2026-09-28}}
	# the week's first day
	dscene::click 1010 397
	dscene::check "Week starts on: Sunday is saved" {[dscene::last] eq {conf WEEKSTART sunday}}
	dscene::click 549 349
	dscene::click 621 401; dscene::click 621 401
	dscene::check "  and the picker's weeks then start on Sunday (1 November 2026 is one)" {$dtp::cm == 11 && [lindex [dt::month 2026 11 [dt::setting WEEKSTART]] 0] eq {2026 11 1 1}}
	dscene::click 429 461
	dscene::check "  where the first cell is the 1st" {[dscene::last] eq {set 2026-11-01}}
	dscene::click 910 397
	dscene::check "Week starts on: Monday again" {[dscene::last] eq {conf WEEKSTART monday}}
	# the time
	dscene::click 611 397
	dscene::check "a click in Time gives it the keys" {$ui::focus eq "dt-time" && [ui::fval dt-time] eq "10:42"}
	foreach k {End BackSpace BackSpace BackSpace BackSpace BackSpace} { dscene::key $k }
	foreach {k ch} {2 2 3 3 x x colon : 0 0 5 5} { dscene::key $k $ch }
	dscene::check "it takes digits and a colon only" {[ui::fval dt-time] eq "23:05"}
	dscene::key Return
	dscene::check "Return sets the time, the date kept" {[dscene::last] eq {set 2026-11-01 23:05:00} && $ui::focus ne "dt-time"}
	set n [llength $dscene::calls]
	dscene::click 611 397
	foreach k {End BackSpace BackSpace} { dscene::key $k }
	foreach {k ch} {9 9 9 9} { dscene::key $k $ch }
	dscene::key Return
	dscene::check "what is not a time is not sent (23:99)" {[llength $dscene::calls] == $n && $ui::focus eq "dt-time"}
	dscene::key Escape
	dscene::click 611 397
	dscene::key Return
	dscene::check "Return on the time it already is sends nothing" {[llength $dscene::calls] == $n}
	# while the helper is asked
	set dt::busy 1
	dscene::click 549 349
	dscene::click 549 301
	dscene::click 611 397
	dscene::check "while a change is being made the rows take no clicks" {!$dtp::cal && $sctl::pop eq "" && $ui::focus ne "dt-time" && [llength $dscene::calls] == $n}
	set dt::busy 0
	# no time service: the switch row is not there, and the others move up
	set dt::service ""
	dscene::click 630 253
	dscene::check "without a time service there is no switch (the zone's list is on that row)" {$sctl::pop eq "dt-zone" && [llength $dscene::calls] == $n}
	dscene::key Escape
	dscene::click 549 301
	dscene::check "  and Date is the second row" {$dtp::cal}
	dscene::key Escape
} else {
	dscene::click 549 349
	dscene::check "set from the internet: Date takes no clicks" {!$dtp::cal && $dscene::calls eq {}}
	dscene::click 611 397
	dscene::check "  nor does Time" {$ui::focus ne "dt-time" && $dscene::calls eq {}}
	# the zone
	dscene::click 549 301
	dscene::check "a click on Time zone opens its list, the zone chosen" {$sctl::pop eq "dt-zone" && [lindex [dict get $sctl::popd items] [dict get $sctl::popd idx] 0] eq "Europe/London"}
	dscene::check "  which scrolls (15 zones, nine shown)" {[dict get $sctl::popd top] == 6}
	foreach ch {t o k} { dscene::key $ch $ch }
	dscene::check "  and jumps to what is typed (tok: Asia/Tokyo)" {[lindex [dict get $sctl::popd items] [dict get $sctl::popd idx] 0] eq "Asia/Tokyo"}
	dscene::key Return
	dscene::check "Return picks it: the helper is asked for the zone" {[dscene::last] eq {zone Asia/Tokyo} && $sctl::pop eq ""}
	dscene::check "  and the page then shows that zone's time (19:42 JST)" {[dt::time_text [dt::now]] eq "19:42" && [dict get [dt::model] abbr] eq "JST" && [dict get [dt::model] subtitle] eq "Asia/Tokyo · set from the internet"}
	dscene::click 549 301
	set first [lindex [dict get $sctl::popd items] [dict get $sctl::popd top] 0]
	dscene::click 549 347
	dscene::check "a click on a row of the list picks it" {[dscene::last] eq [list zone $first] && $first ne ""}
	set n [llength $dscene::calls]
	dscene::click 549 301
	dscene::key Escape
	dscene::check "Escape closes the list and changes nothing" {$sctl::pop eq "" && [llength $dscene::calls] == $n}
	dscene::click 549 301
	set first [lindex [dict get $sctl::popd items] [dict get $sctl::popd idx] 0]
	dscene::click 549 301
	dscene::check "the zone it already is asks for nothing" {[llength $dscene::calls] == $n}
	dscene::key Escape
	# the display choices
	dscene::click 1040 253
	dscene::check "24-hour clock turns off" {[dscene::last] eq {conf HOUR24 no}}
	dscene::check "  and the strip's time is then 12-hour" {[regexp {^\d{1,2}:42 [AP]M$} [dt::time_text [dt::now]]]}
	dscene::click 1040 253
	dscene::check "  and on again" {[dscene::last] eq {conf HOUR24 yes}}
	dscene::click 1040 301
	dscene::check "Seconds in the bar turns on" {[dscene::last] eq {conf SECONDS yes}}
	dscene::click 1040 349
	dscene::check "Date in the bar turns off" {[dscene::last] eq {conf DATE no}}
	dscene::click 1010 397
	dscene::check "Week starts on: Sunday" {[dscene::last] eq {conf WEEKSTART sunday}}
	# the switch
	dscene::click 630 253
	dscene::check "the switch asks the helper to stop setting the clock from the internet" {[dscene::last] eq {ntp off}}
	dscene::check "  the subtitle is then the zone alone" {[string first "set from" [dict get [dt::model] subtitle]] < 0}
	dscene::click 549 349
	dscene::check "  and Date opens its picker" {$dtp::cal}
	dscene::key Escape
	dscene::click 630 253
	dscene::check "the switch turns it on again" {[dscene::last] eq {ntp on}}
	# a refusal: the row as it was, one line in the subtitle
	set dt::error Cancelled
	page::draw_now; update
	dscene::check "a cancelled prompt is the subtitle" {[dict get [dt::model] subtitle] eq "Cancelled"}
	# another page and back
	settings::select about
	page::draw_now; update
	settings::select datetime
	page::draw_now; update
	dscene::check "coming back to the page clears it" {$dt::error eq ""}
	# a zone nothing names
	set dscene::zone ""
	page::draw_now; update
	dscene::check "the page draws with no zone known" {[dict get [dt::model] zone] eq ""}
}
if {[info exists ::env(RIBBON_DT_RESULT)]} { set f [open $::env(RIBBON_DT_RESULT) w]; puts $f [join $dscene::lines \n]; close $f } else { puts [join $dscene::lines \n] }
exit [expr {$dscene::fails > 0}]
