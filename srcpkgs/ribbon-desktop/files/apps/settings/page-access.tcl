# page-access.tcl - Settings → Accessibility (board Settings-A14-Accessibility): Text and pointer (Text size 100,
# 125 or 150 %, Cursor size Default, Large or Larger: two segmented controls) and Screen (High contrast, Reduce
# motion: two switches). The logic is access.tcl (the account's access.conf, applied by ribbon-theme).
#
# Layout (window coordinates; the page runs from 270 to 1060): two columns 379 wide (270 and 681), their block labels
# at 119 and 48 px rows from 141 with the rule under the first; the segmented controls 240 wide with their right edge
# at the column's (409..649), 8 under the row's top; the switches at the right column's end, 13 under it.
#
# High contrast redraws Settings at once in its colours (ui::recolour); other Ribbon apps take it when they next draw
# their palette. Text size and the cursor reach the toolkits, foot and labwc through ribbon-theme.

source -encoding utf-8 [file join [file dirname [file normalize [info script]]] access.tcl]

set ::ui::paths(access) {M12 6a1.5 1.5 0 1 0 0-3a1.5 1.5 0 1 0 0 3z M5 9l7 1.5 7-1.5 M12 10.5V15 M8.5 21l3.5-6 3.5 6}

namespace eval accp {
	variable started 0
	variable drawn -1      ;# ui::drawno when the page was last drawn
}

settings::page access -title Accessibility -icon access -group 1 -order 4 -draw settings::draw_access \
	-rows {{Text and pointer} {Text size} {Cursor size} Screen {High contrast} {Reduce motion}}

# The first draw reads; coming back to the page reads again (another app may have changed the file).
proc accp::begin {} {
	variable started; variable drawn
	if {!$started} {
		set started 1
		set acc::onchange accp::changed
		acc::start
	} elseif {$ui::drawno != $drawn + 1} {
		set acc::error ""
		acc::refresh
	}
}
proc accp::changed {} { if {$::settings::sel eq "access"} { page::draw } }

proc accp::contrast {on} {
	if {[acc::set_contrast $on]} { ui::recolour }
}

proc settings::draw_access {} {
	array set c [array get ui::c]
	accp::begin
	set accp::drawn $ui::drawno
	set m [acc::model]
	ui::text 270 34 Accessibility sg28 $c(fg) w -0.56
	ui::text 270 [ui::lh 76 i14 21] [sctl::clip [dict get $m subtitle] 790 i14] i14 $c(muted)
	# Text and pointer
	sctl::label 270 119 {Text and pointer}
	sctl::row 270 649 141 {Text size}
	ui::seg acc-text 409 149 240 {100 100% 125 125% 150 150%} [dict get $m text] {apply {{v} { acc::set_text $v; page::draw }}}
	sctl::row 270 649 189 {Cursor size} 1
	ui::seg acc-cursor 409 197 240 {24 Default 32 Large 48 Larger} [dict get $m cursor] {apply {{v} { acc::set_cursor $v; page::draw }}}
	# Screen
	sctl::label 681 119 Screen
	sctl::row 681 1060 141 {High contrast}
	sctl::toggle acc-contrast 1060 141 [dict get $m contrast] [list accp::contrast [expr {![dict get $m contrast]}]]
	sctl::row 681 1060 189 {Reduce motion} 1
	sctl::toggle acc-motion 1060 189 [dict get $m motion] [list acc::set_motion [expr {![dict get $m motion]}]]
	sctl::overlay
}
