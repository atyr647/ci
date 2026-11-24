# page-language.tcl - Settings → Language and region (board Settings-A13-Language-Region): This account (Language,
# Formats: two dropdowns) and Shown as (the date, the short date, the time, numbers, money and measures as the formats
# chosen give them). The logic is locale.tcl (the account's locale.conf, read by the session at login).
#
# Layout (window coordinates; the page runs from 270 to 1060): two columns 379 wide (270 and 681), their block labels
# at 119 and 48 px rows from 141. The dropdowns are 220 wide, their right edge at the column's (429..649). Shown as is
# the key in §muted at the column's left and the value 122 to its right, as About's facts, in rows as tall as the
# left column's so the two line up.
#
# A change is saved at once; the subtitle then ends "from your next login" (the session sets LANG and the LC_
# variables from the file when it starts; the page compares with them). Its rail item is registry.tcl's "language"
# (group 4, after Date and time).

source -encoding utf-8 [file join [file dirname [file normalize [info script]]] locale.tcl]

set ::ui::paths(lang) {M5 8l6 6 M4 14l6-6 2-3 M2 5h12 M7 2h1 M22 22l-5-10-5 10 M14 18h6}

namespace eval lgp {
	variable started 0
	variable drawn -1      ;# ui::drawno when the page was last drawn
	variable ROWS {date Date short {Short date} time Time numbers Numbers money Money measures Measures}
}

proc lgp::register {} {
	settings::page language -title {Language and region} -icon lang -group 4 -order 4 -draw settings::draw_language \
		-rows {{This account} Language Formats {Shown as} Date {Short date} Time Numbers Money Measures}
}
if {[settings::exists language]} { lgp::register }

# The first draw reads; coming back to the page reads again (another app may have changed the file).
proc lgp::begin {} {
	variable started; variable drawn
	if {!$started} {
		set started 1
		set loc::onchange lgp::changed
		loc::start
	} elseif {$ui::drawno != $drawn + 1} {
		set loc::error ""
		loc::refresh
	}
	set drawn $ui::drawno
}
proc lgp::changed {} { if {$::settings::sel eq "language"} { page::draw } }

proc settings::draw_language {} {
	array set c [array get ui::c]
	lgp::begin
	set m [loc::model]
	ui::text 270 34 {Language and region} sg28 $c(fg) w -0.56
	ui::text 270 [ui::lh 76 i14 21] [sctl::clip [dict get $m subtitle] 790 i14] i14 $c(muted) w 0 {} 1
	# This account
	sctl::label 270 119 {This account}
	sctl::row 270 649 141 Language
	sctl::dropdown lg-language 429 141 220 [dict get $m languages] [dict get $m language] loc::set_language
	sctl::row 270 649 189 Formats 1
	sctl::dropdown lg-formats 429 189 220 [dict get $m regions] [dict get $m formats] loc::set_formats
	# Shown as
	sctl::label 681 119 {Shown as}
	set ex [dict get $m examples]
	set y 141
	set n [expr {[llength $lgp::ROWS] / 2}]
	foreach {k label} $lgp::ROWS {
		ui::text 681 [expr {$y + 16}] $label i13 $c(muted)
		ui::text 803 [expr {$y + 16}] [sctl::clip [dict get $ex $k] 257] i13 $c(fg) w 0 {} 1
		if {[incr n -1]} { ui::hline 681 1060 [expr {$y + 47}] $c(border) }
		incr y 48
	}
	sctl::overlay
}
