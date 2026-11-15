# toolbar.tcl - the Image Viewer's chrome, drawn on the Properties ui model:
# the title bar (name, "N of M", when it was taken, the buttons), the edge
# arrows, and the floating toolbar, which becomes the zoom toolbar when zoomed.
# Geometry and icons are Viewer-Final-1-Stage's (design/tools/gen_viewer_final.py).
#
# The title bar's buttons are Set as wallpaper (wall.tcl; not on a video), Info and the menu
# (Viewer-Final-9-Menu: Show in Files, Copy, Copy path, Properties). Favourite and Share are not built (no
# backend; the boards leave them out). Rotate turns the picture (viewer::rotate), Crop opens crop.tcl.

namespace eval bar {
	variable menu 0     ;# the title bar's menu is open
	variable tips {}    ;# this draw's icon-only buttons: {KEY NAME X Y W H TOP BOTTOM SIDE} (tooltip.tcl)
	variable hot ""     ;# the one under the pointer: lit (§field, §fg icon), as on Tooltip-2-Viewer
	variable NAMES
	array set NAMES {
		zoomout {Zoom out} zoomin {Zoom in} rotate Rotate crop {Crop and rotate} expand {Full screen}
		trash {Move to Trash} wall {Set as wallpaper} info Info more Menu left Previous right Next
	}
	variable P
	array set P {
		zoomout {M4 11a7 7 0 1 0 14 0a7 7 0 1 0 -14 0 M21 21l-4.3-4.3 M8 11h6}
		zoomin  {M4 11a7 7 0 1 0 14 0a7 7 0 1 0 -14 0 M21 21l-4.3-4.3 M11 8v6 M8 11h6}
		rotate  {M23 4v6h-6 M20.49 15a9 9 0 1 1-2.12-9.36L23 10}
		crop    {M6 2v14a2 2 0 0 0 2 2h14 M18 22V8a2 2 0 0 0-2-2H2}
		expand  {M15 3h6v6 M9 21H3v-6 M21 3l-7 7 M3 21l7-7}
		trash   {M3 6h18 M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6 M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2}
		wall    {M3 4h18v12H3z M8 20h8 M12 16v4}
		info    {M12 22a10 10 0 1 0 0-20a10 10 0 1 0 0 20z M12 16v-4 M12 8h.01}
		more    {M12 13a1 1 0 1 0 0-2a1 1 0 1 0 0 2z M19 13a1 1 0 1 0 0-2a1 1 0 1 0 0 2z M5 13a1 1 0 1 0 0-2a1 1 0 1 0 0 2z}
		folder  {M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z}
		copy    {M9 9h11v11H9z M5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1}
		link    {M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71 M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71}
		left    {M15 18l-6-6 6-6}
		right   {M9 18l6-6-6-6}
	}
}

# An icon at x y, SIZE px, in COLOUR (a ui colour value), stroke SW.
proc bar::icon {name size sw colour x y} {
	variable P
	set i [raster::icon $P($name) $size $sw [ui::col $colour] {} 0 0 0]
	$ui::cv create image [expr {round($x)}] [expr {round($y)}] -image $i -anchor nw -tags page
}

# A text line at x, centred in a box of height h from y. ANCHOR w, c or e.
proc bar::text {x y h str f colour {anchor w}} {
	ui::text $x [ui::lh $y $f $h] $str $f $colour $anchor
}

# Text width in px.
proc bar::width {f str} {
	ui::measure $f $str
}

# ---- tooltips (shell/tooltip.tcl; boards Tooltip-2-Viewer, gen_tray.py) ----------------------------------------------
# Every icon-only button has its name as a tooltip, and the one under the pointer is lit. TIP is where the button sits:
# {TOP BOTTOM SIDE}, the bar or toolbar it is in (the pill goes 6 px clear of it: below a bar at the top, above a
# toolbar at the foot).
proc bar::tip {key name x y w h tip} {
	variable tips
	lassign $tip top bottom side
	lappend tips [list $key $name $x $y $w $h $top $bottom $side]
}
proc bar::lit {key} { variable hot; expr {$hot eq $key} }
proc bar::under {x y} {
	variable tips
	if {$bar::menu || $::gamelist::open} { return "" }
	foreach t [lreverse $tips] {
		lassign $t key name bx by bw bh
		if {$x >= $bx && $x < $bx + $bw && $y >= $by && $y < $by + $bh} { return $t }
	}
	return ""
}
# tip::attach's resolver
proc bar::tip_at {x y} {
	set t [bar::under $x $y]
	if {$t eq ""} { return "" }
	lassign $t key name bx by bw bh top bottom side
	list $key $name [expr {$bx + $bw / 2.0}] $top $bottom $side
}
# The pointer moved (X Y in the window; -1 -1 it left): the button under it is lit.
proc bar::hover {x y} {
	variable hot
	set t [bar::under $x $y]
	set k [lindex $t 0]
	if {$k ne $hot} { set hot $k; viewer::draw }
}

# A 34 px icon button at x y: when ON, a field-coloured square behind it. The menu's dots are 17 px. TIP: its
# tooltip's place ({TOP BOTTOM SIDE}, bar::tip); a button with one is lit under the pointer.
proc bar::button {x y name on hit {tip {}} {label {}}} {
	variable P
	variable NAMES
	if {[llength $tip]} {
		if {$label eq ""} { set label $NAMES($name) }
		bar::tip $name $label $x $y 34 34 $tip
		if {[bar::lit $name]} { set on 1 }
	}
	if {$on} { ui::box $x $y 34 34 -fill $ui::c(field) -radius 8 }
	set s [expr {$name eq "more" ? 17 : 16}]
	set o [expr {(34 - $s) / 2.0}]
	bar::icon $name $s 1.9 [expr {$on ? $ui::c(fg) : $ui::c(muted)}] [expr {$x + $o}] [expr {$y + $o}]
	if {$hit ne ""} { ui::hit $x $y 34 34 $hit }
}

# The title bar: the name and "N of M" on the left, the day and time, then the
# buttons, on the right, at the stage's right edge (SW: the window, or the stage
# beside the Info panel). INFO is the Info panel's state. A Steam screenshot has the game
# button in the name's place (games.tcl); a video has no Set as wallpaper.
proc bar::titlebar {name count when info sw {game {}}} {
	variable menu
	set y 0; set h $zoom::TB; set WW $sw
	if {[llength $game]} {
		set x [expr {[gamelist::button {*}$game] + 12}]
	} else {
		set x 22
		bar::text $x $y $h $name i14s $ui::c(fg)
		set x [expr {$x + [bar::width i14s $name] + 12}]
	}
	bar::text $x $y $h $count i13 $ui::c(muted)
	# the right side, from the window's edge inwards
	set x [expr {$WW - 16}]
	set first 1
	set buttons [list more bar::toggle_menu info viewer::toggle_info]
	if {!$::video::on} { lappend buttons wall vwall::wallpaper }
	foreach {b hit} $buttons {
		if {!$first} { set x [expr {$x - 2}] }
		set first 0
		set x [expr {$x - 34}]
		bar::button $x [expr {($h - 34) / 2}] $b [expr {($b eq "info" && $info) || ($b eq "more" && $menu)}] $hit [list 0 $h below]
	}
	set x [expr {$x - 2 - 6}]
	ui::box $x [expr {($h - 18) / 2}] 1 18 -fill $ui::c(border)
	set x [expr {$x - 1 - 6 - 2}]
	lassign $when day time
	set tw [bar::width i13s $time]; set dw [bar::width i13 $day]
	set x [expr {$x - (4 + $dw + 6 + $tw + 4)}]
	bar::text [expr {$x + 4}] $y $h $day i13 $ui::c(muted)
	bar::text [expr {$x + 4 + $dw + 6}] $y $h $time i13s $ui::c(fg)
}

# The edge arrows, 40 px circles 18 px in from the stage's sides, centred on the
# stage below the title bar. SW is the stage's width.
proc bar::arrows {sw} {
	set y [expr {$zoom::TB + ($zoom::WH - $zoom::TB) / 2 - 20}]
	foreach {side x dir} [list left 18 -1 right [expr {$sw - 18 - 40}] 1] {
		bar::tip $side $bar::NAMES($side) $x $y 40 40 [list $y [expr {$y + 40}] below]
		ui::box $x $y 40 40 -fill [expr {[bar::lit $side] ? $ui::c(field) : $ui::c(bar)}] -radius 20 -ring [list $ui::c(border) 1]
		bar::icon $side 18 2 $ui::c(fg) [expr {$x + 11}] [expr {$y + 11}]
		ui::hit $x $y 40 40 [list viewer::go $dir]
	}
}

# The toolbar's items: {icon NAME HIT}, {text LABEL WIDTH FONT}, {div}, {nav},
# {seg}, {spacer}. Widths follow the boards: 34 per icon, 48 minimum for text,
# a 1 px divider with 6 px either side, 2 px between items.
proc bar::item_width {it} {
	lassign $it kind a b
	switch -- $kind {
		icon { return 34 }
		text { return [expr {max(48, [bar::width $b $a])}] }
		div { return 13 }
		nav { return 61 }
		seg { return 135 }
		spacer { return 1 }
	}
}

# Lay out ITEMS centred on a stage SW wide, in a 44 px toolbar: its outer
# corner at 20 px above the window's foot. PAD is the left and right padding.
proc bar::toolbar {sw items pad_l pad_r} {
	set total [expr {$pad_l + $pad_r + 2 * ([llength $items] - 1)}]
	foreach it $items { incr total [bar::item_width $it] }
	set x0 [expr {($sw - $total) / 2 + $pad_l}]
	set y [expr {$zoom::WH - 20 - 44}]
	ui::box [expr {($sw - $total) / 2}] $y $total 44 -fill $ui::c(bar) -radius 12 -ring [list $ui::c(border) 1]
	set x $x0
	foreach it $items {
		set w [bar::item_width $it]
		lassign $it kind a b
		switch -- $kind {
			icon {
				bar::button $x [expr {$y + 5}] $a 0 $b [list $y [expr {$y + 44}] above]
			}
			text {
				bar::text [expr {$x + $w / 2.0}] $y 44 $a $b $ui::c(fg) c
			}
			div { ui::box [expr {$x + 6}] [expr {$y + 13}] 1 18 -fill $ui::c(border) }
			nav { bar::navigator [expr {$x + 1}] [expr {$y + 4}] }
			seg { ui::seg viewer-seg $x [expr {$y + 6}] 135 {fit Fit fill Fill one 1:1} $::viewer::mode viewer::set_mode 32 }
		}
		incr x [expr {$w + 2}]
	}
}

# The navigator: the picture in 54 x 36 with the visible part outlined.
proc bar::navigator {x y} {
	set t [stage::thumb 54 36]
	if {$t eq ""} { ui::box $x $y 54 36 -fill $ui::c(field) -radius 6; return }
	$ui::img copy $t -to $x $y
	lassign $::viewer::rect L T pw ph
	lassign [zoom::viewport $L $pw $::viewer::sw] f0 f1
	lassign [zoom::viewport $T $ph [expr {$zoom::WH - $zoom::TB}]] g0 g1
	set rx [expr {$x + round($f0 * 54)}]; set ry [expr {$y + round($g0 * 36)}]
	set rw [expr {max(4, round(($f1 - $f0) * 54))}]; set rh [expr {max(4, round(($g1 - $g0) * 36))}]
	ui::ring $rx $ry $rw $rh 2 $ui::c(fg) 2
	set ::viewer::navbox [list $x $y]
	ui::hit $x $y 54 36 viewer::nav_click
}

# ---- the title bar's menu (Viewer-Final-9-Menu) ------------------------------------------------------

proc bar::toggle_menu {args} {
	variable menu
	set menu [expr {!$menu}]
	if {$menu} { video::freeze }
	viewer::draw
}

proc bar::close_menu {args} {
	variable menu
	set menu 0
	viewer::draw
}

# The menu under the title bar's last button, its right edge on the button's (16 in from the stage's edge), 58
# down: Files' menu anatomy (240 wide, padding 6, radius 10, rows 32 tall with the 16 px §muted icon, the label
# and the key in 11 px §muted); Properties after a rule ends it, as in Files.
proc bar::menu_draw {sw} {
	array set c [array get ui::c]
	set rows [list folder "Show in Files" "" viewer::show_in_files copy Copy Ctrl+C viewer::copy link "Copy path" "" viewer::copy_path \
		- - - - info Properties "Alt+\u21b5" viewer::properties]
	set w 240; set h [expr {6 + 4 * 32 + 9 + 6}]
	set x [expr {$sw - 16 - $w}]; set y [expr {$zoom::TB - 10}]
	ui::hit 0 0 $zoom::WW $zoom::WH bar::close_menu
	ui::layer
	ui::box $x $y $w $h -fill $c(bar) -radius 10 -ring [list $c(border) 1]
	set ry [expr {$y + 6}]
	foreach {icon label key hit} $rows {
		# a rule: 1 px §border, 4 px clear above and below, 4 in from the rows' sides
		if {$icon eq "-"} { ui::box [expr {$x + 10}] [expr {$ry + 4}] [expr {$w - 20}] 1 -fill $c(border); incr ry 9; continue }
		bar::icon $icon 16 1.8 $c(muted) [expr {$x + 16}] [expr {$ry + 8}]
		bar::text [expr {$x + 42}] $ry 32 $label i13 $c(fg)
		if {$key ne ""} { ui::text [expr {$x + $w - 16}] [ui::lh $ry i11 32] $key i11 $c(muted) e }
		ui::hit [expr {$x + 6}] $ry [expr {$w - 12}] 32 [list bar::menu_do $hit]
		incr ry 32
	}
}

proc bar::menu_do {hit args} {
	variable menu
	set menu 0
	uplevel #0 [list {*}$hit]
	viewer::draw
}
