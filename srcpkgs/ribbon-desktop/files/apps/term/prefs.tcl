# prefs.tcl - Ribbon Terminal's preferences, the Page direction (docs/TERMINAL.md §6; boards Term-P-Page-1-Look and
# Term-P-Page-2-Profile). A tab of its own: a Tk window with the app-id ribbon-term-GROUP-prefs, which the shell's
# terminal module (shell/mod-term.tcl) takes into GROUP's tabs, places in the tabs' rectangle under the strip and
# shows and minimises like a foot tab.
#
#   ribbon-term-prefs GROUP          (the strip's sliders button, Ctrl+, in a terminal, the tab menu's Preferences…)
#   RIBBON_TERM_PREFS_SCENE = file   a test scene (tests/term-prefs-scene.tcl)
#
# Layout (window coordinates, from the boards' 1240 x 742 tab area): the profiles down a 220 px §d2 side, the page
# from 256 with 36 px margins, Look | Behaviour | Keys at the top right, two columns (430 and 482 on the board, 36
# apart; they share a narrower window in that ratio) and a 64 px footer under a rule. Rows are 44 tall with a rule
# under each but a block's last; a block's label is 22 above its first row.
#
# Default has every foot setting, each row with its control; its colours follow the theme until one is set. Another
# profile takes each row from Default (muted, with the link) until its link is pressed; then the row is its own, bold,
# with its control and an undo that gives it back. A changed foot setting carries the "New tabs" tag until Restart
# terminals (which restarts the tabs that are not running a command). The profiles are apps/term/profiles.tcl.

namespace eval tp {
	variable sel Default        ;# the profile shown
	variable seg look           ;# look | behaviour | keys
	variable group ""
	variable win .w
	variable scene 0
	variable SIDE 220
	variable FOOT 64
	variable naming 0           ;# the title is being renamed
	variable slide ""           ;# the opacity slider's track while it is dragged: {x w}
}

# icons the page needs beyond ui.tcl's (24 grid, as the boards draw them)
array set ui::paths {
	sliders {M21 4h-7 M10 4H3 M21 12h-9 M8 12H3 M21 20h-5 M12 20H3 M14 2v4 M8 10v4 M16 18v4}
	chev    {M6 9l6 6 6-6}
	minus   {M5 12h14}
	x       {M18 6L6 18 M6 6l12 12}
	refresh {M23 4v6h-6 M1 20v-6h6 M3.51 9a9 9 0 0 1 14.85-3.36L23 10 M1 14l4.64 4.36A9 9 0 0 0 20.49 15}
	user    {M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2 M12 11a4 4 0 1 0 0-8a4 4 0 1 0 0 8z}
}

# ---- the page namespace ui.tcl and widgets.tcl call ---------------------------------------------

namespace eval page {
	variable menu {}
	variable menu_hover -1
	variable pending ""
}
proc page::draw {} {
	variable pending
	if {$pending ne ""} return
	set pending [after idle page::draw_now]
}
proc page::draw_now {} {
	variable pending ""
	tp::draw
}
proc page::quit {} { exit 0 }
proc page::clicked_outside {} {
	if {$::tp::recording ne ""} { set ::tp::recording ""; draw }
	menu_close
	if {$::tp::naming} { tp::name_done 1 }
}
proc page::menu_toggle {m} {
	variable menu
	variable menu_hover
	if {[dict size $menu] && [dict get $menu id] eq [dict get $m id]} { menu_close; return }
	set menu $m
	set menu_hover -1
	draw
}
proc page::menu_close {{redraw 1}} {
	variable menu
	if {![dict size $menu]} return
	set menu {}
	if {$redraw} draw
}
proc page::menu_pick {m key} {
	menu_close 0
	uplevel #0 [list {*}[dict get $m script] $key]
	draw
}
proc page::menu_motion {x y} {
	variable menu
	variable menu_hover
	if {![dict size $menu]} return
	lassign [tp::menu_box $menu] mx my mw mh
	set n [llength [dict get $menu items]]
	set i [expr {$x >= $mx && $x < $mx + $mw && $y >= $my + 6 && $y < $my + 6 + 32 * $n ? int(($y - $my - 6) / 32) : -1}]
	if {$i != $menu_hover} { set menu_hover $i; draw }
}

# ---- reading the page ------------------------------------------------------------------------

proc tp::W {} { return $ui::W }
proc tp::H {} { return $ui::H }
# The columns: left x, left width, right x, right width.
proc tp::cols {} {
	variable SIDE
	set C [expr {[W] - $SIDE - 72}]
	set L [expr {round(($C - 36) * 430.0 / 912)}]
	set R [expr {$C - 36 - $L}]
	list [expr {$SIDE + 36}] $L [expr {$SIDE + 36 + $L + 36}] $R
}

# A block's label: 11 px caps, muted, tracked.
proc tp::label {x y t} {
	ui::text $x $y [string toupper $t] i11s $ui::c(muted) w 1.32
}
# A row 44 tall from Y, LABEL at X; the rule under it unless LAST. HOW: plain (Default's rows), own, linked.
proc tp::row {x w y label how {last 0}} {
	array set c [array get ui::c]
	switch -- $how {
		plain { ui::text $x [expr {$y + 14}] $label i13 $c(fg) }
		own { ui::text $x [expr {$y + 14}] $label i13s $c(fg) }
		linked { ui::text $x [expr {$y + 14}] $label i13m $c(muted) }
	}
	if {!$last} { ui::hline $x [expr {$x + $w}] [expr {$y + 43}] $c(border) }
	return [ui::measure [expr {$how eq "plain" ? "i13" : $how eq "own" ? "i13s" : "i13m"}] $label]
}
# The "New tabs" tag after a row's label.
proc tp::tag {x y} { ui::badge $x [expr {$y + 12}] "New tabs" 0 }

# A run script: called with x y by a hit, it runs SCRIPT and redraws.
proc tp::do {script} { list apply {{s x y} { uplevel #0 $s; page::draw }} $script }

# The linked end of a row (another profile's row from Default): the value muted, the link that makes it its own.
proc tp::linked_value {right y value key} {
	array set c [array get ui::c]
	ui::text [expr {$right - 38}] [expr {$y + 14}] $value i13 $c(muted) e
	ui::icon link 14 $c(muted) [expr {$right - 21}] [expr {$y + 15}] 2
	ui::hit [expr {$right - 28}] [expr {$y + 8}] 28 28 [do [list tp::link_off $key]]
}
# The undo at a row's end (a profile's own row, a colour Default set): 28 x 28, ringed.
proc tp::undo {right y key} {
	array set c [array get ui::c]
	ui::ring [expr {$right - 28}] [expr {$y + 8}] 28 28 8 $c(border) 1
	ui::icon undo 14 $c(fg) [expr {$right - 21}] [expr {$y + 15}] 2
	ui::hit [expr {$right - 28}] [expr {$y + 8}] 28 28 [do [list tp::link_on $key]]
}
proc tp::link_off {key} {
	variable sel
	prof::put $sel $key [prof::get $sel $key]
	if {$key in {bg fg cur sel mark}} {
		# a colour that followed the theme starts as the colour it was
		set c [prof::colours $sel]
		prof::put $sel $key [dict get $c $key]
	}
}
proc tp::link_on {key} { variable sel; prof::drop $sel $key }

# ---- controls ---------------------------------------------------------------------------------

# A stepper: 100 x 32, − VALUE unit +.
proc tp::stepper {x y v unit key lo hi} {
	array set c [array get ui::c]
	ui::box $x $y 100 32 -fill $c(field) -radius 8 -ring [list $c(border) 1]
	ui::icon minus 14 $c(fg) [expr {$x + 8}] [expr {$y + 9}] 2.2
	ui::icon plus 14 $c(fg) [expr {$x + 78}] [expr {$y + 9}] 2.2
	set w1 [ui::measure i13m $v]; set w2 [ui::measure i13m " $unit"]
	set tx [expr {$x + 50 - ($w1 + $w2) / 2.0}]
	ui::text $tx [expr {$y + 8}] $v i13m $c(fg)
	ui::text [expr {$tx + $w1}] [expr {$y + 8}] " $unit" i13m $c(muted)
	ui::hit $x $y 30 32 [do [list tp::set_num $key [expr {max($lo, $v - 1)}]]]
	ui::hit [expr {$x + 70}] $y 30 32 [do [list tp::set_num $key [expr {min($hi, $v + 1)}]]]
	ui::focusable step-$key area $x $y 100 32 8 [list tp::step_key $key $v $lo $hi]
}
proc tp::step_key {key v lo hi sym} {
	switch -- $sym {
		Left - Down - minus { tp::set_num $key [expr {max($lo, $v - 1)}] }
		Right - Up - plus - equal { tp::set_num $key [expr {min($hi, $v + 1)}] }
		default { return 0 }
	}
	page::draw
	return 1
}
proc tp::set_num {key v} { variable sel; prof::put $sel $key $v }
proc tp::set_val {key v} { variable sel; prof::put $sel $key $v; page::draw }

# The opacity slider: a 142 px track, the value at the row's end.
proc tp::slider {right y v} {
	variable slide
	array set c [array get ui::c]
	set x [expr {$right - 200}]
	set frac [expr {($v - 30) / 70.0}]
	ui::box $x [expr {$y + 20}] 142 4 -fill $c(pill) -radius 2
	ui::box $x [expr {$y + 20}] [expr {142 * $frac}] 4 -fill $c(muted) -radius 2
	ui::box [expr {$x + 142 * $frac - 9}] [expr {$y + 13}] 18 18 -fill $c(fg) -radius 9
	ui::text $right [expr {$y + 14}] "$v %" i13 $c(fg) e
	set f [list apply {{x0 x y} { tp::slide_to $x0 $x }} $x]
	ui::hit [expr {$x - 10}] [expr {$y + 8}] 162 28 $f $f [list apply {{x y} { prof::save }}]
	ui::focusable opacity slider $x [expr {$y + 13}] 142 18 9 [list tp::slide_key $v]
}
proc tp::slide_to {x0 x} {
	variable sel
	set v [expr {30 + round(70 * min(1.0, max(0.0, ($x - $x0) / 142.0)))}]
	if {$v != [prof::get $sel opacity]} { dict set prof::P $sel opacity $v; page::draw }
}
proc tp::slide_key {v sym} {
	switch -- $sym {
		Left - Down { tp::set_num opacity [expr {max(30, $v - 1)}] }
		Right - Up { tp::set_num opacity [expr {min(100, $v + 1)}] }
		default { return 0 }
	}
	page::draw
	return 1
}

# A colour swatch: 18 px, radius 5, ringed.
proc tp::swatch {x y col {s 18} {r 5}} {
	ui::box $x $y $s $s -fill $col -radius $r -ring [list $ui::c(border) 1]
}

# ---- the side: profiles -------------------------------------------------------------------------

# What a profile's side row says under its name.
proc tp::summary {n} {
	if {$n eq "Default"} { return "[prof::get Default font] [prof::get Default size]" }
	set parts {}
	if {[prof::own $n command] && [prof::get $n command] ne ""} { lappend parts [prof::get $n command] }
	if {[prof::own $n font]} { lappend parts [prof::get $n font] }
	if {[prof::own $n size]} { lappend parts "[prof::get $n size] pt" }
	set cols 0
	foreach k {bg fg cur sel mark} { if {[prof::own $n $k]} { set cols 1 } }
	if {$cols} { lappend parts "own colours" }
	if {[prof::own $n blink]} { lappend parts [expr {[prof::get $n blink] ? "blink" : "no blink"}] }
	if {![llength $parts]} { return "As Default" }
	# two things fit the side's width
	join [lrange $parts 0 1] " · "
}

proc tp::side {} {
	variable sel
	variable SIDE
	array set c [array get ui::c]
	ui::box 0 0 $SIDE [H] -fill $c(d2)
	ui::box [expr {$SIDE - 1}] 0 1 [H] -fill $c(border)
	tp::label 24 22 Profiles
	set y 48
	foreach n $prof::order {
		set on [expr {$n eq $sel}]
		if {$on} { ui::box 12 $y 196 50 -fill $c(field) -radius 9 }
		ui::text 24 [expr {$y + 8}] $n [expr {$on ? "i13s" : "i13m"}] [expr {$on ? $c(fg) : $c(muted)}]
		ui::text 24 [expr {$y + 27}] [summary $n] i12 $c(muted)
		ui::hit 12 $y 196 50 [do [list tp::pick $n]]
		incr y 52
	}
	ui::icon plus 15 $c(muted) 24 [expr {$y + 15.5}] 2
	ui::text 48 [expr {$y + 15}] "New profile" i13m $c(muted)
	ui::hit 12 [expr {$y + 6}] 196 34 [do {tp::pick [prof::create]}]
}
proc tp::pick {n} {
	variable sel
	variable naming
	set sel $n
	set naming 0
	page::menu_close 0
}

# ---- the page ----------------------------------------------------------------------------------

proc tp::draw {} {
	variable sel
	variable seg
	variable SIDE
	variable FOOT
	variable naming
	if {![dict exists $prof::P $sel]} { set sel Default }
	array set c [array get ui::c]
	ui::begin tp {}
	side
	lassign [cols] lx lw rx rw
	set right [expr {$rx + $rw}]
	# the title (a click renames a profile other than Default), the segments
	if {$naming} {
		ui::field name [expr {$lx - 10}] 22 300 -h 38 -font sg24 -onenter {tp::name_done 1} -max 24
	} else {
		ui::text $lx 26.5 $sel sg24 $c(fg) w -0.48
		if {$sel ne "Default"} { ui::hit $lx 22 [expr {[ui::measure sg24 $sel -0.48] + 8}] 38 [do tp::name_start] }
	}
	ui::seg segs [expr {$right - 330}] 26 330 {look Look behaviour Behaviour keys Keys} $seg {apply {{k} { set ::tp::seg $k; page::draw }}}
	switch -- $seg {
		look { look $lx $lw $rx $rw }
		behaviour { behaviour $lx $lw $rx $rw }
		keys { keys $lx $lw $rx $rw }
	}
	# the footer
	set fy [expr {[H] - $FOOT}]
	ui::box $SIDE $fy [expr {[W] - $SIDE}] $FOOT -fill $c(bar)
	ui::hline $SIDE [W] $fy $c(border)
	if {$sel eq "Default"} {
		foot_button $lx [expr {$fy + 15}] "Reset profile" undo ghost {prof::reset_default}
	} else {
		foot_button $lx [expr {$fy + 15}] "Delete profile" x ghost {prof::delete $::tp::sel; set ::tp::sel Default}
	}
	set bw [expr {28 + [ui::measure i13m "Restart terminals"] + 8 + 13}]
	foot_button [expr {$right - $bw}] [expr {$fy + 15}] "Restart terminals" refresh field {tp::restart}
	if {[dict size $page::menu]} { menu_draw $page::menu }
	ui::focus_ring
	ui::finish
}

# A footer button: 34 tall, radius 9, 13 px, the icon after the label.
proc tp::foot_button {x y label icon kind script} {
	array set c [array get ui::c]
	set w [expr {28 + [ui::measure i13m $label] + 8 + 13}]
	if {$kind eq "ghost"} { ui::ring $x $y $w 34 9 $c(border) 1 } else { ui::box $x $y $w 34 -fill $c(field) -radius 9 }
	set tw [ui::text [expr {$x + 14}] [expr {$y + 9}] $label i13m $c(fg)]
	ui::icon $icon 13 $c(fg) [expr {$x + 14 + $tw + 7}] [expr {$y + 10.5}] 2
	ui::hit $x $y $w 34 [do $script]
	ui::focusable btn-$label button $x $y $w 34 9 [list apply {{s} { uplevel #0 $s; page::draw }} $script]
}

# Renaming: the title becomes a field; Return or a click elsewhere keeps the name (if it is free and fits).
proc tp::name_start {} {
	variable naming 1
	variable sel
	ui::fset name $sel
	set ui::focus name
}
proc tp::name_done {keep} {
	variable naming
	variable sel
	set naming 0
	set ui::focus ""
	set new [string trim [ui::fval name]]
	if {$keep && $new ne $sel && $new ne "" && [prof::okname $new] && ![dict exists $prof::P $new]} {
		set prof::P [dict create {*}[concat {*}[lmap n $prof::order { list [expr {$n eq $sel ? $new : $n}] [dict get $prof::P $n] }]]]
		if {[dict exists $prof::A $sel]} { dict set prof::A $new [dict get $prof::A $sel]; dict unset prof::A $sel }
		set prof::order [lmap n $prof::order { expr {$n eq $sel ? $new : $n} }]
		prof::save
		set sel $new
	}
	page::draw
}

proc tp::restart {} {
	variable scene
	if {!$scene} { catch {exec ribbon-term-ctl restart &} }
	prof::applied
}

# ---- Look -------------------------------------------------------------------------------------

proc tp::look {lx lw rx rw} {
	variable sel
	array set c [array get ui::c]
	set def [expr {$sel eq "Default"}]
	set lr [expr {$lx + $lw}]
	# TEXT
	tp::label $lx 78 Text
	set fonts [lmap f [mono_fonts] { list $f $f }]
	set y 100
	foreach {key label} {font Font size Size lineh {Line height} pad Padding} {
		set how [expr {$def ? "plain" : [prof::own $sel $key] ? "own" : "linked"}]
		set lw_ [row $lx $lw $y $label $how [expr {$key eq "pad"}]]
		if {[prof::changed $sel $key]} { tag [expr {$lx + $lw_ + 8}] $y }
		set v [prof::get $sel $key]
		if {$how eq "linked"} {
			linked_value $lr $y [value_text $key $v] $key
		} else {
			set cr [expr {$def ? $lr : $lr - 38}]
			switch -- $key {
				font { w::dropdown font [expr {$cr - 176}] [expr {$y + 6}] 176 32 $fonts $v {tp::set_val font} }
				size { stepper [expr {$cr - 100}] [expr {$y + 6}] $v pt size 6 48 }
				lineh { ui::seg lineh [expr {$cr - 196}] [expr {$y + 6}] 196 {font Font 1.2 1.2 1.4 1.4} $v {tp::set_val lineh} }
				pad { ui::seg pad [expr {$cr - 196}] [expr {$y + 6}] 196 {8 8 16 16 24 24} $v {tp::set_val pad} }
			}
			if {!$def} { undo $lr $y $key }
		}
		incr y 44
	}
	# CURSOR
	tp::label $lx 298 Cursor
	set y 320
	foreach {key label} {cursor Style blink Blink} {
		set how [expr {$def ? "plain" : [prof::own $sel $key] ? "own" : "linked"}]
		set lw_ [row $lx $lw $y $label $how [expr {$key eq "blink"}]]
		if {[prof::changed $sel $key]} { tag [expr {$lx + $lw_ + 8}] $y }
		set v [prof::get $sel $key]
		if {$how eq "linked"} {
			linked_value $lr $y [value_text $key $v] $key
		} else {
			set cr [expr {$def ? $lr : $lr - 38}]
			if {$key eq "cursor"} {
				ui::seg cursor [expr {$cr - 236}] [expr {$y + 6}] 236 {block Block beam Beam underline Underline} $v {tp::set_val cursor}
			} else {
				w::switch_ blink [expr {$cr - 38}] [expr {$y + 11}] $v [list tp::set_val blink [expr {!$v}]]
			}
			if {!$def} { undo $lr $y $key }
		}
		incr y 44
	}
	if {$def} {
		# WINDOW
		tp::label $lx 430 Window
		set lw_ [row $lx $lw 452 Opacity plain 1]
		if {[prof::changed $sel opacity]} { tag [expr {$lx + $lw_ + 8}] 452 }
		slider $lr 452 [prof::get $sel opacity]
	} else {
		# OPENS FOR
		tp::label $lx 430 {Opens for}
		set cmd [prof::get $sel command]
		row $lx $lw 452 Command [expr {$cmd ne "" ? "own" : "plain"}] 1
		set items [list [list "" None] {*}[lmap p {ssh mosh sudo su toolbox distrobox} { list $p $p }]]
		w::dropdown command [expr {$lr - 38 - 150}] 458 150 32 $items $cmd {tp::set_val command}
		if {$cmd ne ""} { undo $lr 452 command }
	}
	preview $rx $rw
	colours $rx $rw
}

# How a linked row shows its value.
proc tp::value_text {key v} {
	switch -- $key {
		size { return "$v pt" }
		lineh { return [expr {$v eq "font" ? "Font" : $v}] }
		cursor { return [string totitle $v] }
		default { return $v }
	}
}

# The monospace families fontconfig has (JetBrains Mono first), for the Font dropdown.
proc tp::mono_fonts {} {
	variable monos
	if {[info exists monos]} { return $monos }
	set l {}
	catch { foreach f [split [exec fc-list :spacing=mono family 2>/dev/null] "\n"] { set f [lindex [split $f ,] 0]; if {$f ne "" && $f ni $l} { lappend l $f } } }
	set l [lsort -dictionary $l]
	set monos [linsert [lsearch -all -inline -not -exact $l "JetBrains Mono"] 0 "JetBrains Mono"]
	set cur [prof::get $::tp::sel font]
	if {$cur ni $monos} { lappend monos $cur }
	return $monos
}

# The preview: a few lines of a session in the profile's font, size and colours, 172 tall.
proc tp::preview {rx rw} {
	variable sel
	array set c [array get ui::c]
	tp::label $rx 78 Preview
	set k [prof::colours $sel]
	set y0 100; set h 172
	ui::box $rx $y0 $rw $h -fill [dict get $k bg] -radius 10 -ring [list $c(border) 1]
	set sz [prof::get $sel size]
	set lh [prof::get $sel lineh]
	set pitch [expr {round($sz * 1.25 * ($lh eq "font" ? 1.1 : $lh))}]
	set fn [mono_font $sz 0]; set fb [mono_font $sz 1]
	set fg [dict get $k fg]
	set host [expr {[prof::get $sel command] eq "ssh"}]
	set prompt [expr {$host ? [list [list pi@kitchen $fb regular2] [list " ~ " $fb fg]] : [list [list ~/src/ribbon $fb fg] [list " on " $fn fg] [list main $fn regular6] [list " " $fn fg]]}]
	set lines [list \
		[list {*}$prompt [list "\$ git status -s" $fn fg]] \
		[list [list " M " $fn regular2] [list design/STYLE.md $fn fg]] \
		[list [list "?? " $fn regular1] [list docs/TERMINAL.md $fn fg]] \
		[list {*}$prompt [list "\$ kit check" $fn fg]] \
		[list [list "  openssl   3.0.13  " $fn fg] [list "→" $fn bright0] [list " 3.0.14   1 MB" $fn fg]] \
		[list [list "1 update · 1 MB" $fn fg]] \
		[list {*}$prompt [list "\$ " $fn fg]]]
	set ty [expr {$y0 + 11}]
	set cw [font measure $fn M]
	foreach l $lines {
		if {$ty + $pitch > $y0 + $h - 6} break
		set tx [expr {$rx + 16}]
		foreach run $l {
			lassign $run t f col
			set colour [expr {$col eq "fg" ? $fg : [dict get $k $col]}]
			$ui::cv create text $tx [expr {$ty + ($pitch - [font metrics $f -linespace]) / 2.0}] -text $t -font $f -fill $colour -anchor nw -tags page
			set tx [expr {$tx + [font measure $f $t]}]
		}
		set last $tx; set lasty $ty
		incr ty $pitch
	}
	# the cursor after the last prompt
	set cc [dict get $k cur]
	switch -- [prof::get $sel cursor] {
		beam { ui::box $last [expr {$lasty + ($pitch - $sz * 1.1) / 2.0}] 2 [expr {$sz * 1.1}] -fill $cc }
		block { ui::box $last [expr {$lasty + ($pitch - $sz * 1.2) / 2.0}] $cw [expr {$sz * 1.2}] -fill $cc }
		underline { ui::box $last [expr {$lasty + ($pitch + $sz) / 2.0}] $cw 2 -fill $cc }
	}
}
proc tp::mono_font {sz bold} {
	set name tpmono$sz$bold
	if {$name ni [font names]} {
		font create $name -family [prof::get $::tp::sel font] -size -$sz -weight [expr {$bold ? "bold" : "normal"}]
	} else {
		font configure $name -family [prof::get $::tp::sel font]
	}
	return $name
}

# COLOURS: Default has the scheme, background, text, cursor, selection and the palette; another profile background,
# text, cursor, its tab mark and selection.
proc tp::colours {rx rw} {
	variable sel
	array set c [array get ui::c]
	set def [expr {$sel eq "Default"}]
	set right [expr {$rx + $rw}]
	tp::label $rx 294 Colours
	set k [prof::colours $sel]
	set y 316
	if {$def} {
		row $rx $rw $y Scheme plain
		set items {}
		set theme [dict get [prof::theme_palette] NAME]
		lappend items [list "" "$theme · theme"]
		foreach s [prof::schemes] { lappend items $s }
		w::dropdown scheme [expr {$right - 196}] [expr {$y + 6}] 196 32 $items [prof::get Default scheme] {tp::set_val scheme}
		incr y 44
		set rows {bg Background fg Text cur Cursor sel Selection}
	} else {
		set rows {bg Background fg Text cur Cursor mark {Tab mark} sel Selection}
	}
	foreach {key label} $rows {
		set own [prof::own $sel $key]
		set lw_ [row $rx $rw $y $label [expr {$own ? "own" : "linked"}] [expr {!$def && $key eq "sel"}]]
		if {[prof::changed $sel $key]} { tag [expr {$rx + $lw_ + 8}] $y }
		set hex [dict get $k $key]
		tp::swatch [expr {$right - 56}] [expr {$y + 13}] $hex
		ui::hit [expr {$right - 60}] [expr {$y + 8}] 28 28 [list apply {{key x y} { tp::colour_menu $key }} $key]
		if {$own} {
			set v [prof::get $sel $key]
			ui::text [expr {$right - 66}] [expr {$y + 14}] [expr {[string index $v 0] eq "#" ? [string toupper $v] : [string totitle $v]}] mono12 $c(fg) e
			tp::undo $right $y $key
		} else {
			ui::text [expr {$right - 66}] [expr {$y + 14.5}] [expr {$def ? "Theme" : "Default"}] i12 $c(muted) e
			ui::icon link 14 $c(muted) [expr {$right - 21}] [expr {$y + 15}] 2
			ui::hit [expr {$right - 28}] [expr {$y + 8}] 28 28 [do [list tp::link_off $key]]
		}
		incr y 44
	}
	if {$def} {
		row $rx $rw $y Palette linked 1
		set i 0
		foreach n {0 1 2 3 4 5 6 7} {
			tp::swatch [expr {$right - 194 + 20 * $i}] [expr {$y + 14}] [dict get $k bright$n] 16 4
			incr i
		}
		ui::icon link 14 $c(muted) [expr {$right - 21}] [expr {$y + 15}] 2
	}
}

# A colour row's swatch opens a menu of the scheme's eight colours (picking one makes the row the profile's own).
proc tp::colour_menu {key} {
	variable sel
	lassign [cols] - - rx rw
	set k [prof::colours $sel]
	set items {}
	foreach n $prof::colours i {0 1 2 3 4 5 6 7} { lappend items [list $n [string totitle $n] [dict get $k regular$i]] }
	set y [expr {316 + 44 * ([lsearch -exact {bg fg cur sel} $key] + ($sel eq "Default" ? 1 : 0))}]
	if {$sel ne "Default"} { set y [expr {316 + 44 * [lsearch -exact {bg fg cur mark sel} $key]}] }
	page::menu_toggle [dict create id colour-$key x [expr {$rx + $rw - 32}] y [expr {$y + 40}] top [expr {$y + 8}] items $items \
		cur [prof::get $sel $key] script [list tp::set_val $key] swatches 1]
}

# The open menu, drawn above the page: 6 px padding, 32 px rows, the current one checked. Placed under its
# control's right edge, or above it when it would pass the footer.
proc tp::menu_box {m} {
	set items [dict get $m items]
	set wd 200
	foreach it $items { set wd [expr {max($wd, 32 + ([dict exists $m swatches] ? 26 : 0) + [ui::measure i13 [lindex $it 1]] + 24)}] }
	set wd [expr {int(ceil($wd))}]
	set h [expr {12 + 32 * [llength $items]}]
	set x [expr {[dict get $m x] - $wd}]; set y [dict get $m y]
	if {$y + $h > [H] - 8} { set y [expr {[dict get $m top] - 8 - $h}] }
	list $x $y $wd $h
}
proc tp::menu_draw {m} {
	array set c [array get ui::c]
	lassign [menu_box $m] x y wd h
	ui::layer
	raster::box $ui::img [expr {round($x)}] [expr {round($y)}] $wd $h -fill $c(bar) -radius 12 -ring [list $c(border) 1] -shadow {16 40 0.5}
	ui::hit 0 0 [W] [H] {apply {{x y} { page::menu_close }}}
	set iy [expr {$y + 6}]
	set k 0
	foreach it [dict get $m items] {
		lassign $it key label sw
		if {$k == $page::menu_hover} { ui::box [expr {$x + 6}] $iy [expr {$wd - 12}] 32 -fill $c(field) -radius 8 }
		set tx [expr {$x + 16}]
		if {[dict exists $m swatches]} { tp::swatch $tx [expr {$iy + 8}] $sw 16 4; set tx [expr {$tx + 26}] }
		ui::text $tx [expr {$iy + 8}] $label i13 $c(fg)
		if {$key eq [dict get $m cur]} { ui::icon check 14 $c(accent) [expr {$x + $wd - 30}] [expr {$iy + 9}] 2.4 }
		ui::hit [expr {$x + 6}] $iy [expr {$wd - 12}] 32 [list apply {{m key x y} { page::menu_pick $m $key }} $m $key]
		set iy [expr {$iy + 32}]
		incr k
	}
}

# ---- Behaviour and Keys ------------------------------------------------------------------------

# Behaviour (board Term-P-Sheet-2-Behaviour's rows in the page's columns): the strip's tab rules on the left (Default's
# only, as they are the strip's: another profile shows them linked), scrollback and the bell on the right (per profile).
# "Ask before closing a running command" is the switch of the strip's question (boards Alert-2, -2b, -2c; shell/mod-term.tcl).
proc tp::behaviour {lx lw rx rw} {
	variable sel
	array set c [array get ui::c]
	set def [expr {$sel eq "Default"}]
	set lr [expr {$lx + $lw}]
	tp::label $lx 78 Tabs
	set y 100
	set rows {
		strip {Show the strip} seg {always Always two {Two or more}}
		newin {New tab opens in} seg {home Home same {Same folder}}
		newat {New tab goes} seg {next Next end {At the end}}
		lastclose {Closing the last tab} drop {window {Closes the window} keep {Opens a new tab}}
		ask {Ask before closing a running command} switch {1 On 0 Off}
	}
	foreach {key label kind opts} $rows {
		set last [expr {$key eq "ask"}]
		if {!$def} {
			row $lx $lw $y $label linked $last
			ui::text [expr {$lr - 38}] [expr {$y + 14}] [dict get $opts [prof::get Default $key]] i13 $c(muted) e
			ui::icon link 14 $c(muted) [expr {$lr - 21}] [expr {$y + 15}] 2
		} else {
			row $lx $lw $y $label plain $last
			set v [prof::get Default $key]
			if {$kind eq "seg"} {
				ui::seg $key [expr {$lr - 220}] [expr {$y + 6}] 220 $opts $v [list tp::set_val $key]
			} elseif {$kind eq "switch"} {
				w::switch_ $key [expr {$lr - 38}] [expr {$y + 11}] $v [list tp::set_val $key [expr {!$v}]]
			} else {
				w::dropdown $key [expr {$lr - 220}] [expr {$y + 6}] 220 32 [lmap {k l} $opts { list $k $l }] $v [list tp::set_val $key]
			}
		}
		incr y 44
	}
	# SCROLLBACK
	set right [expr {$rx + $rw}]
	tp::label $rx 78 Scrollback
	set y 100
	foreach {key label} {lines Lines wheel {Wheel scrolls}} {
		set how [expr {$def ? "plain" : [prof::own $sel $key] ? "own" : "linked"}]
		set w_ [row $rx $rw $y $label $how [expr {$key eq "wheel"}]]
		if {[prof::changed $sel $key]} { tag [expr {$rx + $w_ + 8}] $y }
		set v [prof::get $sel $key]
		if {$how eq "linked"} {
			linked_value $right $y [expr {$key eq "lines" ? [group_digits $v] : "$v lines"}] $key
		} else {
			set cr [expr {$def ? $right : $right - 38}]
			if {$key eq "lines"} {
				w::dropdown lines [expr {$cr - 130}] [expr {$y + 6}] 130 32 [lmap n {1000 10000 50000 100000} { list $n [group_digits $n] }] $v {tp::set_val lines}
			} else {
				stepper [expr {$cr - 100}] [expr {$y + 6}] $v lines wheel 1 10
			}
			if {!$def} { undo $right $y $key }
		}
		incr y 44
	}
	# BELL
	tp::label $rx 210 Bell
	set y 232
	foreach {key label} {bell Bell marktab {Mark the tab} notify {Notify when not in front}} {
		set strip [expr {$key eq "marktab"}]
		set how [expr {$def ? "plain" : $strip ? "linked" : [prof::own $sel $key] ? "own" : "linked"}]
		set w_ [row $rx $rw $y $label $how [expr {$key eq "notify"}]]
		if {[prof::changed $sel $key]} { tag [expr {$rx + $w_ + 8}] $y }
		set v [prof::get $sel $key]
		if {$how eq "linked"} {
			set t [expr {$key eq "bell" ? [string totitle $v] : $v ? "On" : "Off"}]
			if {$strip} {
				ui::text [expr {$right - 38}] [expr {$y + 14}] $t i13 $c(muted) e
				ui::icon link 14 $c(muted) [expr {$right - 21}] [expr {$y + 15}] 2
			} else { linked_value $right $y $t $key }
		} else {
			set cr [expr {$def ? $right : $right - 38}]
			if {$key eq "bell"} {
				ui::seg bell [expr {$cr - 200}] [expr {$y + 6}] 200 {off Off flash Flash sound Sound} $v {tp::set_val bell}
			} else {
				w::switch_ $key [expr {$cr - 38}] [expr {$y + 11}] $v [list tp::set_val $key [expr {!$v}]]
			}
			if {!$def} { undo $right $y $key }
		}
		incr y 44
	}
}
# 50000 -> "50 000", as the board writes it
proc tp::group_digits {n} {
	regsub -all {(\d)(?=(\d{3})+$)} $n {\1 } n
	return $n
}
# Keys (board Term-P-Sheet-3-Keys's rows in the page's columns): tabs and windows on the left, text on the right. A
# click on a row's keys records the next chord (the row's keys in an accent ring with a caret; Esc keeps the old one).
# The keys are Default's: another profile shows them linked.
namespace eval tp { variable recording "" }
proc tp::keys {lx lw rx rw} {
	variable sel
	variable recording
	array set c [array get ui::c]
	set def [expr {$sel eq "Default"}]
	tp::label $lx 78 {Tabs and windows}
	tp::label $rx 78 Text
	foreach {ids x w} [list {new close next prev tabn left right prefs} $lx $lw {copy paste find link pprev pnext bigger smaller} $rx $rw] {
		set y 100
		foreach id $ids {
			lassign [prof::keydef $id] label - how
			set w_ [row $x $w $y $label [expr {$def ? "plain" : "linked"}] [expr {$id eq [lindex $ids end]}]]
			if {[prof::changed Default key_$id]} { tag [expr {$x + $w_ + 8}] $y }
			set caps [expr {$id eq "tabn" ? {Alt 1…9} : [chord_caps [prof::get Default key_$id]]}]
			set right [expr {$x + $w}]
			if {$recording eq $id} {
				set cw [expr {[caps_width [lrange $caps 0 end-1]] + 2 + 20}]
				set bw [expr {max(100, $cw)}]
				ui::box [expr {$right - $bw}] [expr {$y + 6}] $bw 32 -fill $c(field) -radius 8 -ring [list $c(accent) 1.5]
				set cx [expr {$right - $bw + 10}]
				foreach k [lrange $caps 0 end-1] { set cx [expr {[cap $cx [expr {$y + 11}] $k] + 4}] }
				ui::box [expr {$cx}] [expr {$y + 14}] 2 16 -fill $c(accent)
			} else {
				set cx [expr {$right - [caps_width $caps]}]
				foreach k $caps { set cx [expr {[cap $cx [expr {$y + 11}] $k [expr {$def ? $c(fg) : $c(muted)}]] + 4}] }
				if {$def && $how ne "fixed"} {
					ui::hit [expr {$right - [caps_width $caps] - 6}] [expr {$y + 6}] [expr {[caps_width $caps] + 6}] 32 [do [list tp::record $id]]
				}
			}
			incr y 44
		}
	}
}
# A key cap: 22 tall, radius 5, 11 px semibold, 6 px either side (22 wide at least). Returns its right edge.
proc tp::cap {x y t {fg ""}} {
	array set c [array get ui::c]
	if {$fg eq ""} { set fg $c(fg) }
	set w [expr {max(22, 12 + [ui::measure i11s $t])}]
	ui::box $x $y $w 22 -fill $c(field) -radius 5 -ring [list $c(border) 1]
	ui::text [expr {$x + $w / 2.0}] [expr {$y + 4}] $t i11s $fg c
	expr {$x + $w}
}
proc tp::caps_width {caps} {
	set w 0
	foreach k $caps { incr w [expr {int(max(22, 12 + [ui::measure i11s $k])) + 4}] }
	expr {$w - 4}
}
# foot's chord (Control+Shift+t) as the caps the board writes (Ctrl Shift T).
proc tp::chord_caps {chord} {
	set out {}
	foreach p [split $chord +] {
		switch -- $p {
			Control { lappend out Ctrl } Shift { lappend out Shift } Mod1 { lappend out Alt } Mod4 { lappend out Super }
			Next { lappend out PgDn } Prior { lappend out PgUp } comma { lappend out , } equal { lappend out = }
			minus { lappend out − } plus { lappend out + } period { lappend out . } slash { lappend out / }
			Return { lappend out Enter } Escape { lappend out Esc }
			default { lappend out [expr {[string length $p] == 1 ? [string toupper $p] : $p}] }
		}
	}
	return $out
}
proc tp::record {id} { variable recording $id; set ui::focus "" }
# A key while recording: the chord (with at least Ctrl, Alt or Super, unless a function key) becomes the row's, if no
# other row has it. Esc keeps the old one.
proc tp::record_key {sym state} {
	variable recording
	if {$sym eq "Escape"} { set recording ""; page::draw; return }
	if {[regexp {^(Shift|Control|Alt|Meta|Super|Hyper|ISO)_} $sym] || $sym in {Caps_Lock Num_Lock}} return
	set mods {}
	if {$state & 4} { lappend mods Control }
	if {$state & 1} { lappend mods Shift }
	if {$state & 8} { lappend mods Mod1 }
	if {$state & 64} { lappend mods Mod4 }
	if {![regexp {^F[0-9]+$} $sym] && ![llength [lsearch -all -inline -not -exact $mods Shift]]} return
	set key [expr {[string length $sym] == 1 ? [string tolower $sym] : $sym}]
	set chord [join [list {*}$mods $key] +]
	foreach {k l d h} $prof::keys { if {$k ne $recording && [prof::get Default key_$k] eq $chord} { return } }
	prof::put Default key_$recording $chord
	set recording ""
	page::draw
}

# ---- keys -------------------------------------------------------------------------------------

proc tp::key {sym char state} {
	variable naming
	if {$::tp::recording ne ""} { tp::record_key $sym $state; return }
	if {[dict size $page::menu]} {
		if {$sym eq "Escape"} { page::menu_close }
		return
	}
	if {$naming} {
		switch -- $sym {
			Escape { tp::name_done 0 }
			Return - KP_Enter { tp::name_done 1 }
			default { ui::field_key name $sym $char $state; page::draw }
		}
		return
	}
	switch -- $sym {
		Tab { ui::cycle 1; return }
		ISO_Left_Tab { ui::cycle -1; return }
	}
	set f [ui::focused]
	if {$f ne ""} {
		lassign $f id kind - - - - - script
		if {$kind in {button toggle} && $sym in {Return KP_Enter space}} { uplevel #0 $script; page::draw; return }
		if {$kind ni {button toggle} && [uplevel #0 [list {*}$script $sym]]} { page::draw; return }
	}
}
