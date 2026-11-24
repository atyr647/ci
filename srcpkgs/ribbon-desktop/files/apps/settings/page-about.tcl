# page-about.tcl - Settings → About (board Settings-A11-About): the strip (Ribbon's mark, its name, the version and
# whether updates wait, Copy details), This computer (Name, Model, Processor, Memory, Graphics) and System (Kernel,
# Desktop, Disk, Firmware, Installed). The logic is about.tcl; a row it has no value for is not drawn.
#
# Layout (window coordinates; the page runs from 270 to 1060): the strip is 84 tall at 119, its 52 px tile at 286,
# the 38 px ghost button ending 20 from its right edge. Under it two columns 379 wide (270 and 681), a block label
# at 227, then 38 px rows from 249: the label (muted) at the column's left, the value 132 further, a rule under every
# row but the last.
#
# The name: a click on it or its pencil makes it a field in place (letters, digits and hyphens are all it takes);
# Return saves it through about::set_name (pkexec, the helper), Escape or a click elsewhere puts the name back. The
# name shown stays the computer's own: it changes when the helper has changed it. Copy details puts about::details on
# the clipboard.

source -encoding utf-8 [file join [file dirname [file normalize [info script]]] about.tcl]

settings::page about -title About -icon info -group 4 -order 5 -draw settings::draw_about \
	-rows {Version {Copy details} {This computer} Name Model Processor Memory Graphics System Kernel Desktop Disk Firmware Installed}

namespace eval abp {
	variable started 0
	variable edit 0        ;# the name is a field
	variable drawn -1      ;# ui::drawno when the page was last drawn
}

# Ribbon's mark, 26 px: the board's two shapes in the board's two colours.
proc abp::mark {x y} {
	foreach {d colour} {{M3 4l9 16V4z} #F2C14E {M12 4v16l9-16z} #E8457C} {
		set i [raster::icon $d 26 0.01 [ui::col $colour] {} 0 0 1]
		$ui::cv create image [expr {round($x)}] [expr {round($y)}] -image $i -anchor nw -tags page
	}
}

# A column: its label, then its rows.
proc abp::rows {x0 title rows busy} {
	array set c [array get ui::c]
	if {![llength $rows]} return
	sctl::label $x0 227 $title
	set y 249
	set left [llength $rows]
	foreach r $rows {
		lassign $r label value
		ui::text $x0 [expr {$y + 11}] $label i13 $c(muted)
		if {$label eq "Name"} { abp::name [expr {$x0 + 132}] $y $value $busy } else {
			ui::text [expr {$x0 + 132}] [expr {$y + 11}] [sctl::clip $value 247] i13 $c(fg) w 0 {} 1
		}
		if {[incr left -1]} { ui::hline $x0 [expr {$x0 + 379}] [expr {$y + 37}] $c(border) }
		incr y 38
	}
}

# The name's value at X on the row at Y: the name and its pencil, or the field.
proc abp::name {x y host busy} {
	variable edit
	array set c [array get ui::c]
	if {$edit} {
		ui::field about-name [expr {$x - 10}] [expr {$y + 4}] 257 -h 30 -font i13 -pad 10 -radius 8 -max 63 \
			-onchange abp::edit_typed -onenter abp::edit_save
		return
	}
	set w [ui::text $x [expr {$y + 11}] [sctl::clip $host 223] i13 $c(fg) w 0 {} 1]
	ui::icon edit 14 $c(muted) [expr {$x + $w + 10}] [expr {$y + 12}] 1.9
	# while the helper is asked, the name is not edited again
	if {$busy} return
	sctl::hit [expr {$x - 4}] [expr {$y + 3}] [expr {$w + 36}] 32 abp::edit_start
	ui::focusable about-edit button [expr {$x + $w + 6}] [expr {$y + 8}] 22 22 6 {abp::edit_start; page::draw}
}

proc abp::edit_start {} {
	variable edit 1
	ui::fset about-name [lindex [split [dict get [about::model] hostname] .] 0]
	set ui::focus about-name
	set ui::caret 1
	# the keys are the field's, not the rail's search
	if {[info exists ::settings::searching]} { set ::settings::searching 0 }
}
# Only what a name can hold stays in the field.
proc abp::edit_typed {} {
	set t [ui::fval about-name]
	regsub -all {[^A-Za-z0-9-]} $t "" ok
	if {$ok eq $t} return
	set cur [expr {max(0, $ui::fld(about-name,cur) - ([string length $t] - [string length $ok]))}]
	ui::fset about-name $ok
	set ui::fld(about-name,cur) $cur
}
# Return: a name that cannot be one keeps the field open; the computer's own name again changes nothing. The field
# holds only the first label of a name such as box.example.com, so that label unchanged changes nothing either
# (the helper would otherwise set the short name in place of the full one).
proc abp::edit_save {} {
	variable edit
	set name [ui::fval about-name]
	if {![about::valid_name $name]} return
	set edit 0
	set ui::focus ""
	set host [dict get [about::model] hostname]
	if {$name ne $host && $name ne [lindex [split $host .] 0]} { about::set_name $name }
}

proc abp::copy {} {
	clipboard clear
	clipboard append -- [about::details]
}

# The first draw starts the reads; later ones ask for the free space again. A change draws the page while it is shown.
proc abp::begin {} {
	variable started
	if {$started} { about::refresh; return }
	set started 1
	set about::onchange abp::changed
	about::start
}
proc abp::changed {} { if {$::settings::sel eq "about"} { page::draw } }

proc settings::draw_about {} {
	array set c [array get ui::c]
	abp::begin
	# the field closes when the keyboard left it (Escape, a click elsewhere) or another page was shown meanwhile
	if {$abp::edit && ($ui::focus ne "about-name" || $ui::drawno != $abp::drawn + 1)} { set abp::edit 0 }
	set abp::drawn $ui::drawno
	set m [about::model]
	ui::text 270 34 About sg28 $c(fg) w -0.56
	ui::text 270 [ui::lh 76 i14 21] [sctl::clip [dict get $m subtitle] 790 i14] i14 $c(muted) w 0 {} 1
	# the strip
	ui::box 270 119 790 84 -fill $c(field) -radius 12 -ring [list $c(border) 1]
	ui::box 286 135 52 52 -fill $c(pill) -radius 14
	abp::mark 299 148
	set bw [ui::button_w {Copy details} ghost copy]
	set room [expr {1040 - $bw - 16 - 354}]
	ui::text 354 137.5 [sctl::clip [dict get $m name] $room sg22] sg22 $c(fg)
	ui::text 354 168.5 [sctl::clip [dict get $m status] $room] i13 $c(muted) w 0 {} 1
	ui::button about-copy [expr {1040 - $bw}] 142 {Copy details} ghost abp::copy copy
	abp::rows 270 {This computer} [dict get $m computer] [dict get $m busy]
	abp::rows 681 System [dict get $m system] 0
	sctl::overlay
}
