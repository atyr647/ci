# page-power.tcl - Settings → Power (U14, board Settings-A-Rail, the Power page): the battery (level, time left, health,
# cycles), the idle timers for battery and plugged in, the dim, the lid and power key, the power mode, the critical
# level, the charge limit and the bar's percentage. The logic is power.tcl (UPower and power-profiles-daemon over
# ribbon::dbus, the settings file, the swayidle arguments).
#
# Layout (window coordinates; the page runs from 270 to 1060, the rail is 230 wide): the battery row at 119 (64 tall),
# WHEN IDLE at 207, BUTTONS AND LID and BATTERY at 429 in two columns (the left is 352.56 wide, a 32 gap, the right
# 405.44). Rows are 48 tall (STYLE 6). The page has no footer on the board.
#
# The lid (both rows), the power button, the critical level and action, and the charge limit are root settings: a choice
# runs `pkexec ribbon-power-helper set NAME VALUE` (apps/settings/bin/ribbon-power-helper). A refusal or a cancelled
# prompt leaves the row as it was and puts one line in the subtitle.

source -encoding utf-8 [file join [file dirname [file normalize [info script]]] power.tcl]

settings::page power -title Power -icon battery -group 3 -order 1 -draw settings::draw_power \
	-rows {Battery Health Cycles {Power mode} {Turn off the screen} Lock Suspend {Lid closed} {Lid closed, plugged in} \
		{Power button} {Dim before turning off} {Critical level} {Charge limit} {Percentage in the bar}}

namespace eval power {
	variable pop ""        ;# the open dropdown's id (an idle timer), "" when none is open
	variable popitems {}   ;# its {value label} items
	variable popidx 0
	variable popcur ""     ;# the open list's current value
	variable popcmd ""     ;# the command that takes (id value) when an item is chosen
	variable rect          ;# dropdown id -> {x y w}, for its list
	array set rect {}
}

# A hit that runs SCRIPT, as the page's buttons do.
proc power::hit {x y w h script} {
	ui::hit $x $y $w $h [list apply {{s x y} { uplevel #0 $s }} $script]
}

# A block label: 11 px, caps, muted, 16 tall, its top at Y.
proc power::block {x y text} {
	array set c [array get ui::c]
	ui::text $x [ui::lh $y i11s 16] $text i11s $c(muted) w 1.32
}

# A row's label (13 px) at X0, 48 tall from TOP, with a 1 px rule under it (none under the last row).
proc power::row {x0 x1 top label last} {
	array set c [array get ui::c]
	ui::text $x0 [ui::lh $top i13 48] $label i13 $c(fg)
	if {!$last} { ui::hline $x0 $x1 [expr {$top + 47}] $c(border) }
}

# A dropdown: 32 tall, radius 8, a field with a ring and a chevron. ID "" is read only (no hit, no focus).
proc power::dropdown {id x y w label} {
	variable rect
	array set c [array get ui::c]
	ui::box $x $y $w 32 -fill $c(field) -radius 8 -ring [list $c(border) 1]
	if {$id ne "" && $ui::focus eq $id && $ui::kbd} { ui::ring $x $y $w 32 8 $c(accent) 1.5 }
	ui::text [expr {$x + 12}] [ui::lh $y i13 32] $label i13 $c(fg)
	ui::icon down 14 $c(muted) [expr {$x + $w - 10 - 14}] [expr {$y + 9}] 2
	if {$id eq ""} return
	set rect($id) [list $x $y $w]
	power::hit $x $y $w 32 [list power::open_pop $id]
	ui::focusable $id button $x $y $w 32 8 [list power::open_pop $id]
}

# A switch (38 x 22) that flips a setting in power.conf.
proc power::toggle_switch {id x y on key} {
	ui::toggle $x $y $on
	power::hit $x $y 38 22 [list power::toggle_conf $key]
	ui::focusable $id toggle $x $y 38 22 11 [list power::toggle_conf $key]
}

proc power::toggle_conf {key} {
	power::conf_set $key [expr {[power::setting $key] eq "yes" ? "no" : "yes"}]
	page::draw
}

# Two values are the same: as numbers when both are, else as text.
proc power::same {a b} {
	expr {$a eq $b || ([string is double -strict $a] && [string is double -strict $b] && $a == $b)}
}

# Open a dropdown: the idle timers' (minutes) or a root setting's (power::root_menu); its current item chosen, the
# list's keys on. A root row does not open while a helper is running.
proc power::open_pop {id} {
	variable pop; variable popitems; variable popidx; variable popcur; variable popcmd
	if {$id in {bat_off pl_off bat_lock pl_lock bat_suspend pl_suspend}} {
		set popitems [power::timeout_items]
		set popcur [power::setting [power::key_of $id]]
		set popcmd power::pick_idle
	} else {
		if {$::power::rbusy} return
		lassign [power::root_menu $id] popitems popcur
		set popcmd power::root_set
	}
	set pop $id
	set popidx 0
	set i 0
	foreach item $popitems {
		if {[power::same [lindex $item 0] $popcur]} { set popidx $i }
		incr i
	}
	set ui::focus power-pop
	page::draw
}

proc power::close_pop {} {
	variable pop
	set pop ""
	page::draw
}

# Choose item I of the open list: the list closes and the choice is made (an idle timer is saved and the idle daemon
# applies it; a root setting goes to the helper).
proc power::pick {i} {
	variable pop; variable popitems; variable popcmd
	set id $pop
	set value [lindex [lindex $popitems $i] 0]
	set pop ""
	{*}$popcmd $id $value
	page::draw
}

proc power::pick_idle {id value} {
	power::conf_set [power::key_of $id] $value
}

# Keys while the list is open: Up and Down move, Return chooses, Escape closes.
proc power::pop_key {sym} {
	variable popitems; variable popidx
	switch -- $sym {
		Up { set popidx [expr {max(0, $popidx - 1)}] }
		Down { set popidx [expr {min([llength $popitems] - 1, $popidx + 1)}] }
		Return - KP_Enter - space { power::pick $popidx; return 1 }
		Escape { power::close_pop; return 1 }
		default { return 0 }
	}
	page::draw
	return 1
}

# The open list, drawn over the page: six rows of 36 and a 12 px pad, under the field (or over it, near the foot).
# A catch-all hit over the content closes it on a click elsewhere; the list's own items are the latest hits.
proc power::popup_draw {} {
	variable pop; variable popitems; variable popidx; variable rect
	array set c [array get ui::c]
	lassign $rect($pop) x y w
	set w [expr {max($w, 190)}]
	set n [llength $popitems]
	set h [expr {12 + 36 * $n}]
	set top [expr {$y + 38}]
	if {$top + $h > 708} { set top [expr {$y - 6 - $h}] }
	ui::layer
	power::hit 230 0 870 720 [list power::close_pop]
	ui::box $x $top $w $h -fill $c(bar) -radius 12 -ring [list $c(border) 1]
	set i 0
	foreach item $popitems {
		lassign $item v label
		set iy [expr {$top + 6 + 36 * $i}]
		if {$i == $popidx} { ui::box [expr {$x + 6}] $iy [expr {$w - 12}] 36 -fill $c(field) -radius 8 }
		set on [power::same $v $::power::popcur]
		set f [expr {$on ? "i13s" : "i13m"}]
		ui::text [expr {$x + 18}] [ui::lh $iy $f 36] $label $f $c(fg)
		if {$on} { ui::icon check 14 $c(accent) [expr {$x + $w - 18 - 14}] [expr {$iy + 11}] 2.4 }
		ui::hit [expr {$x + 6}] $iy [expr {$w - 12}] 36 [list apply {{s x y} { uplevel #0 $s }} [list power::pick $i]]
		incr i
	}
	ui::focusable power-pop list $x $top $w $h 12 power::pop_key
}

# The battery row: the well and the icon, the level and the time line, the meter, and Health and Cycles at the right.
proc power::draw_battery {top} {
	array set c [array get ui::c]
	ui::box 270 $top 790 64 -fill $c(field) -radius 12 -ring [list $c(border) 1]
	ui::box 284 [expr {$top + 14}] 36 36 -fill $c(pill) -radius 10
	ui::icon battery 18 $c(fg) 293 [expr {$top + 23}] 1.9
	if {!$::power::loaded} return
	set m $::power::model
	if {![dict get $m bat]} {
		ui::text 334 [ui::lh $top i14 64] "No battery" i14 $c(muted)
		return
	}
	set frac [expr {max(0.0, min(1.0, [dict get $m pct] / 100.0))}]
	set x 334
	set w [ui::text $x [ui::lh $top sg22 64] "[expr {round([dict get $m pct])}]%" sg22 $c(fg) w -0.44 {} 1]
	set x [expr {$x + $w + 14}]
	set t [power::time_text [dict get $m state] [dict get $m tte] [dict get $m ttf]]
	if {$t ne ""} {
		set x [expr {$x + [ui::text $x [ui::lh $top i14 64] $t i14 $c(muted)] + 14}]
	}
	set x [expr {$x + 6}]
	ui::box $x [expr {$top + 29}] 180 6 -fill $c(pill) -radius 3
	if {$frac > 0} { ui::box $x [expr {$top + 29}] [expr {180 * $frac}] 6 -fill $c(accent) -radius 3 }
	set health [expr {[dict get $m health] < 0 ? "—" : "[expr {round([dict get $m health])}]%"}]
	set cycles [expr {[dict get $m cycles] < 0 ? "—" : [dict get $m cycles]}]
	set cw [power::pair_width Cycles $cycles]
	set xc [expr {1040 - $cw}]
	power::pair $xc $top Cycles $cycles
	power::pair [expr {$xc - 22 - [power::pair_width Health $health]}] $top Health $health
}

# "Label value" in 13 px: the label muted, the value 600 and tabular. Returns the width.
proc power::pair {x top label value} {
	array set c [array get ui::c]
	set w1 [ui::text $x [ui::lh $top i13 64] "$label " i13 $c(muted)]
	set w2 [ui::text [expr {$x + $w1}] [ui::lh $top i13 64] $value i13s $c(fg) w 0 {} 1]
	expr {$w1 + $w2}
}

proc power::pair_width {label value} {
	expr {[ui::measure i13 "$label "] + [ui::measure i13s $value 0 1]}
}

# WHEN IDLE: the header (On battery, Plugged in) and the three timers.
proc power::draw_idle {top} {
	array set c [array get ui::c]
	power::block 270 $top "WHEN IDLE"
	set y [expr {$top + 24}]
	ui::text 748 [ui::lh $y i12 30] "On battery" i12 $c(muted)
	ui::text 910 [ui::lh $y i12 30] "Plugged in" i12 $c(muted)
	ui::hline 270 1060 [expr {$y + 29}] $c(border)
	set y [expr {$y + 30}]
	foreach {label kind last} {"Turn off the screen" off 0 "Lock" lock 0 "Suspend" suspend 1} {
		power::row 270 1060 $y $label $last
		set upper [string toupper $kind]
		power::dropdown bat_$kind 748 [expr {$y + 8}] 150 [power::timeout_label [power::setting IDLE_BAT_$upper]]
		power::dropdown pl_$kind 910 [expr {$y + 8}] 150 [power::timeout_label [power::setting IDLE_PL_$upper]]
		incr y 48
	}
}

# A root setting's dropdown: the label of the current item (an item's label, else the file's own value in the page's words).
proc power::root_dropdown {id x y w root} {
	lassign [power::root_menu $id] items cur
	set label [expr {$cur eq "" ? "—" : [expr {$id in {crit_pct charge} ? "$cur%" : [power::action_label $cur]}]}]
	foreach item $items {
		if {[power::same [lindex $item 0] $cur]} { set label [lindex $item 1] }
	}
	power::dropdown $id $x $y $w $label
}

# The two columns: BUTTONS AND LID (root settings) and BATTERY (power mode, then the root's level and limit, the bar).
proc power::draw_columns {top} {
	array set c [array get ui::c]
	set lx 270
	set lend 622.56
	set rx 654.56
	power::block $lx $top "BUTTONS AND LID"
	power::block $rx $top "BATTERY"
	set root [power::root]
	set y [expr {$top + 24}]
	power::row $lx $lend $y "Lid closed" 0
	power::root_dropdown lid_bat [expr {$lend - 150}] [expr {$y + 8}] 150 $root
	power::row $lx $lend [expr {$y + 48}] "Lid closed, plugged in" 0
	power::root_dropdown lid_pl [expr {$lend - 170}] [expr {$y + 56}] 170 $root
	power::row $lx $lend [expr {$y + 96}] "Power button" 0
	power::root_dropdown power_key [expr {$lend - 150}] [expr {$y + 104}] 150 $root
	power::row $lx $lend [expr {$y + 144}] "Dim before turning off" 1
	power::toggle_switch dim [expr {$lend - 38}] [expr {$y + 157}] [expr {[power::setting DIM] eq "yes"}] DIM

	set bat [dict get $::power::model bat]
	set last [expr {!$bat}]
	power::row $rx 1060 $y "Power mode" $last
	set cur [dict get $::power::model profile]
	ui::seg power_mode 800 [expr {$y + 8}] 260 {power-saver Saver balanced Balanced performance Performance} \
		$cur power::set_profile 32
	if {$bat} {
		power::row $rx 1060 [expr {$y + 48}] "Critical level" 0
		power::root_dropdown crit_pct 840 [expr {$y + 56}] 90 $root
		power::root_dropdown crit_act 940 [expr {$y + 56}] 120 $root
		power::row $rx 1060 [expr {$y + 96}] "Charge limit" 0
		power::root_dropdown charge 970 [expr {$y + 104}] 90 $root
		power::row $rx 1060 [expr {$y + 144}] "Percentage in the bar" 1
		power::toggle_switch bar [expr {1060 - 38}] [expr {$y + 157}] [expr {[power::setting BAR_PERCENT] eq "yes"}] BAR_PERCENT
	}
}

proc settings::power_started {} {
	if {$::power::started} return
	set ::power::started 1
	set ::power::onchange page::draw
	power::refresh
}

proc settings::draw_power {} {
	array set c [array get ui::c]
	settings::power_started
	ui::text 270 34 Power sg28 $c(fg) w -0.56
	ui::text 270 [ui::lh 76 i14 21] [power::subtitle] i14 $c(muted)
	power::draw_battery 119
	power::draw_idle 207
	power::draw_columns 429
	if {$::power::pop ne ""} { power::popup_draw }
}
