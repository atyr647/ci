# widgets.tcl - the Properties boards' parts on top of the Appearance app's
# ui.tcl: the icon tile, fact rows, chips, dropdowns and their menu, the
# name field, an undo button and pictures. Sizes are gen_props.py's.

array set ui::paths {
	info     {M12 22a10 10 0 1 0 0-20a10 10 0 1 0 0 20z M12 16v-4 M12 8h.01}
	shield   {M12 22c0 0 8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z}
	layers   {M12 2L2 7l10 5 10-5-10-5z M2 17l10 5 10-5 M2 12l10 5 10-5}
	disk     {M22 12H2 M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z M6 16h.01 M10 16h.01}
	key      {M21 2l-2 2m-7.61 7.61a5.5 5.5 0 1 1-7.778 7.778 5.5 5.5 0 0 1 7.777-7.777zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4}
	wrench   {M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z}
	home     {M3 10l9-7 9 7v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z M9 22V12h6v10}
	monitor  {M4 3h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z M8 21h8 M12 17v4}
	vol      {M11 5L6 9H2v6h4l5 4z M15.54 8.46a5 5 0 0 1 0 7.07 M19.07 4.93a10 10 0 0 1 0 14.14}
	mic      {M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3z M19 10v2a7 7 0 0 1-14 0v-2 M12 19v3}
	chip     {M6 6h12v12H6z M9 2v4 M15 2v4 M9 18v4 M15 18v4 M2 9h4 M2 15h4 M18 9h4 M18 15h4}
	camera   {M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z M12 17a4 4 0 1 0 0-8a4 4 0 1 0 0 8z}
	pad      {M6 11h4 M8 9v4 M15 12h.01 M18 10h.01 M17.3 5H6.7a4 4 0 0 0-3.96 3.43l-.9 6.3A3 3 0 0 0 4.8 18c.94 0 1.83-.44 2.4-1.2l.8-1.1a2 2 0 0 1 1.6-.8h4.8a2 2 0 0 1 1.6.8l.8 1.1c.57.76 1.46 1.2 2.4 1.2a3 3 0 0 0 2.96-3.27l-.9-6.3A4 4 0 0 0 17.3 5z}
	bell     {M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18c0 0-3-2-3-9 M13.73 21a2 2 0 0 1-3.46 0}
	cast     {M2 16.1A5 5 0 0 1 5.9 20 M2 12.05A9 9 0 0 1 9.95 20 M2 8V6a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-6 M2 20h.01}
	box      {M21 16V8l-9-5-9 5v8l9 5 9-5z M3.3 7L12 12l8.7-5 M12 22V12}
	power    {M18.36 6.64a9 9 0 1 1-12.73 0 M12 2v10}
	user     {M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2 M12 11a4 4 0 1 0 0-8a4 4 0 1 0 0 8z}
	users    {M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2 M9 11a4 4 0 1 0 0-8a4 4 0 1 0 0 8z M23 21v-2a4 4 0 0 0-3-3.87 M16 3.13a4 4 0 0 1 0 7.75}
	globe    {M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0 M2 12h20 M12 2a15 15 0 0 1 0 20 M12 2a15 15 0 0 0 0 20}
	film     {M4 3h16a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z M7 3v18 M17 3v18 M3 12h18 M3 7.5h4 M3 16.5h4 M17 7.5h4 M17 16.5h4}
	ext      {M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6 M15 3h6v6 M10 14L21 3}
	aperture {M12 22a10 10 0 1 0 0-20a10 10 0 1 0 0 20z M14.31 8l5.74 9.94 M9.69 8h11.48 M7.38 12l5.74-9.94 M9.69 16L3.95 6.06 M14.31 16H2.83 M16.62 12l-5.74 9.94}
	chev     {M6 9l6 6 6-6}
	x        {M18 6L6 18 M6 6l12 12}
	lines    {M4 6h16 M4 12h16 M4 18h10}
	paint    {M4 3h16v18H4z M8 7h8 M8 11h8 M8 15h5}
	grid     {M4 4h6v6H4z M14 4h6v6h-6z M4 14h6v6H4z M14 14h6v6h-6z}
	terminal {M4 17l6-6-6-6 M12 19h8}
	game     {M6 11h4 M8 9v4 M15 12h.01 M18 10h.01 M17.3 5H6.7a4 4 0 0 0-3.96 3.43l-.9 6.3A3 3 0 0 0 4.8 18c.94 0 1.83-.44 2.4-1.2l.8-1.1a2 2 0 0 1 1.6-.8h4.8a2 2 0 0 1 1.6.8l.8 1.1c.57.76 1.46 1.2 2.4 1.2a3 3 0 0 0 2.96-3.27l-.9-6.3A4 4 0 0 0 17.3 5z}
	music    {M9 18V5l12-2v13 M6 21a3 3 0 1 0 0-6a3 3 0 1 0 0 6z M18 19a3 3 0 1 0 0-6a3 3 0 1 0 0 6z}
	code     {M16 18l6-6-6-6 M8 6l-6 6 6 6}
	sliders  {M4 21v-7 M4 10V3 M12 21v-9 M12 8V3 M20 21v-5 M20 12V3 M1 14h6 M9 8h6 M17 16h6}
	pkg      {M21 16V8l-9-5-9 5v8l9 5 9-5z M3.3 7L12 12l8.7-5 M12 22V12}
	pause    {M8 5v14 M16 5v14}
	chevr    {M9 18l6-6-6-6}
	database {M4 5a8 3 0 1 0 16 0a8 3 0 1 0 -16 0 M4 5v14a8 3 0 0 0 16 0V5 M4 12a8 3 0 0 0 16 0}
	rec      {M12 22a10 10 0 1 0 0-20a10 10 0 1 0 0 20z M12 15a3 3 0 1 0 0-6a3 3 0 1 0 0 6z}
	doc      {M4 3h16v18H4z M8 7h8 M8 11h8 M8 15h5}
}

namespace eval w {}

# The icon tile (the rail's identity): a rounded square in a 160-degree
# gradient from PILL to FIELD with a 1 px ring, and a line icon.
# The window's height (pages.tcl's page::WH; 720 where the Rail pages aren't loaded).
proc w::wh {} { expr {[info exists ::page::WH] ? $::page::WH : 720} }

proc w::tile {x y icon {size 44} {isz 22} {r 12}} {
	array set c [array get ui::c]
	set top [ui::col $c(pill)]; set bot [ui::col $c(field)]; set ring [ui::col $c(border)]
	set g [ui::mem [list tile $size $r $top $bot $ring] {
		lassign [raster::rgb $top] r1 g1 b1; lassign [raster::rgb $bot] r2 g2 b2; lassign [raster::rgb $ring] rr rg rb
		set a [expr {160 * acos(-1) / 180}]
		set dx [expr {sin($a)}]; set dy [expr {-cos($a)}]
		set len [expr {abs($size * $dx) + abs($size * $dy)}]
		set rows {}
		for {set j 0} {$j < $size} {incr j} {
			set row {}
			for {set i 0} {$i < $size} {incr i} {
				set px [expr {$i + 0.5}]; set py [expr {$j + 0.5}]
				set co [raster::rbox $px $py 0 0 $size $size $r]
				set ci [raster::rbox $px $py 1 1 [expr {$size - 1}] [expr {$size - 1}] [expr {$r - 1}]]
				set t [expr {min(1.0, max(0.0, (($px - $size / 2.0) * $dx + ($py - $size / 2.0) * $dy) / $len + 0.5))}]
				set f [expr {$co > 0 ? ($co - $ci) / $co : 0}]
				lappend row [expr {int(($r1 + ($r2 - $r1) * $t) * (1 - $f) + $rr * $f + 0.5)}] \
					[expr {int(($g1 + ($g2 - $g1) * $t) * (1 - $f) + $rg * $f + 0.5)}] \
					[expr {int(($b1 + ($b2 - $b1) * $t) * (1 - $f) + $rb * $f + 0.5)}] [expr {int($co * 255 + 0.5)}]
			}
			lappend rows $row
		}
		raster::png $size $size $rows
	}]
	raster::blit $ui::img $g 0 0 $size $size [expr {round($x)}] [expr {round($y)}]
	set o [expr {($size - $isz) / 2.0}]
	ui::icon $icon $isz $c(fg) [expr {$x + $o}] [expr {$y + $o}] 1.7
}

# A picture: FILE scaled to cover W x H and cropped in the middle (the
# Appearance app's thumbnails, bg::picture), corners R, the faint ring.
# Returns 0 when the file can't be shown.
proc w::picture {x y w h file {r 10}} {
	lassign [ui::snap $x $y $w $h] x y w h
	if {[catch {bg::picture $file $w $h} p]} { return 0 }
	raster::blit $ui::img $p 0 0 $w $h $x $y
	ui::corners $x $y $w $h $r $ui::c(bar)
	ui::ring $x $y $w $h $r #FFFFFF 1 0.06
	return 1
}

# ---- text runs -------------------------------------------------------------------------
# A row's value: runs, 8 px apart: {t TEXT} {m TEXT} (muted) {s TEXT}
# (semibold) {i ICON ?colour?} (14 px, stroke 2.4 for the check, else 2).
proc w::runs {x top runs {f i13}} {
	array set c [array get ui::c]
	set first 1
	foreach r $runs {
		if {!$first} { set x [expr {$x + 8}] }
		set first 0
		lassign $r k v col
		switch -- $k {
			t { set x [expr {$x + [ui::text $x $top $v $f $c(fg) w 0 {} 1]}] }
			m { set x [expr {$x + [ui::text $x $top $v $f $c(muted) w 0 {} 1]}] }
			s { set x [expr {$x + [ui::text $x $top $v i13m $c(fg) w 0 {} 1]}] }
			i {
				if {$col eq ""} { set col $c(accent) }
				ui::icon $v 14 $col $x [expr {$top + 1}] [expr {$v eq "check" ? 2.4 : 2}]
				set x [expr {$x + 14}]
			}
		}
	}
	return $x
}

# A fact: KEY (muted) and its value runs, H tall, a line under it unless
# LAST. RIGHT: an icon at the row's right end {icon script}.
proc w::kv {x y w h kw key runs {last 0} {right ""}} {
	array set c [array get ui::c]
	set top [expr {$y + ($h - 16) / 2.0}]
	ui::text $x $top $key i13 $c(muted)
	w::runs [expr {$x + $kw + 12}] $top $runs
	if {$right ne ""} {
		lassign $right icon script
		ui::icon $icon 14 $c(muted) [expr {$x + $w - 14}] [expr {$y + ($h - 14) / 2.0}] 2
		if {$script ne ""} { ui::hit [expr {$x + $w - 20}] [expr {$y + ($h - 26) / 2.0}] 26 26 [list apply {{s x y} { uplevel #0 $s }} $script] }
	}
	if {!$last} { ui::hline $x [expr {$x + $w}] [expr {$y + $h - 1}] $c(border) }
}

# Facts: {key runs ?right?} rows, H tall each; returns the y below them.
proc w::facts {x y w rows {h 38} {kw 112}} {
	set n 0
	foreach r $rows {
		lassign $r k v right
		kv $x $y $w $h $kw $k $v [expr {$n == [llength $rows] - 1}] $right
		set y [expr {$y + $h}]
		incr n
	}
	return $y
}

# ---- chips ---------------------------------------------------------------------------------

proc w::chip_w {icon text state} {
	expr {24 + ($icon ne "" ? 22 : 0) + [ui::measure i13 $text] + ($state ne "" ? 8 + [ui::measure i13 $state] : 0)}
}

# 32 tall, FIELD, radius 8: an icon, the text and a muted state.
proc w::chip {x y icon text {state ""} {script ""}} {
	array set c [array get ui::c]
	set cw [chip_w $icon $text $state]
	ui::box $x $y $cw 32 -fill $c(field) -radius 8
	set tx [expr {$x + 12}]
	if {$icon ne ""} { ui::icon $icon 14 $c(muted) $tx [expr {$y + 9}]; set tx [expr {$tx + 22}] }
	set tx [expr {$tx + [ui::text $tx [expr {$y + 8}] $text i13 $c(fg)]}]
	if {$state ne ""} { ui::text [expr {$tx + 8}] [expr {$y + 8}] $state i13 $c(muted) }
	if {$script ne ""} { ui::hit $x $y $cw 32 [list apply {{s x y} { uplevel #0 $s }} $script] }
	return $cw
}

# Chips in one line from X, at most MAX and as many as fit in W.
proc w::chips {x y w items {max 6}} {
	set x0 $x
	set n 0
	foreach it $items {
		lassign $it icon text state script
		set cw [chip_w $icon $text $state]
		if {$n >= $max || $x + $cw > $x0 + $w + 0.01} break
		chip $x $y $icon $text $state $script
		set x [expr {$x + $cw + 8}]
		incr n
	}
	return $n
}

# ---- dropdowns and their menu ------------------------------------------------------------------

# ID: what it edits; ITEMS {key label ?icon?}; CUR the key shown; SCRIPT
# gets the key chosen. Opens the menu under its right edge.
proc w::dropdown {id x y w h items cur script {icon ""}} {
	array set c [array get ui::c]
	set open [expr {[dict exists $page::menu id] && [dict get $page::menu id] eq $id}]
	set label $cur
	foreach it $items { if {[lindex $it 0] eq $cur} { set label [lindex $it 1] } }
	ui::box $x $y $w $h -fill $c(field) -radius 8
	if {$open} { ui::ring $x $y $w $h 8 $c(accent) 1.5 } else { ui::ring $x $y $w $h 8 $c(border) 1 }
	set tx [expr {$x + 12}]
	if {$icon ne ""} { ui::icon $icon 14 $c(muted) $tx [expr {$y + ($h - 14) / 2.0}]; set tx [expr {$tx + 22}] }
	ui::text $tx [expr {$y + ($h - 16) / 2.0}] $label i13 $c(fg) w 0 {} 1
	ui::icon chev 14 [expr {$open ? $c(fg) : $c(muted)}] [expr {$x + $w - 24}] [expr {$y + ($h - 14) / 2.0}] 2
	w::dropdown_hit $id $x $y $w $h $items $cur $script
}

# The click and the keys of a dropdown drawn elsewhere (the footer's lead and tile): its menu
# opens on the page (page::menu_toggle) and SCRIPT gets the key picked, appended to it.
proc w::dropdown_hit {id x y w h items cur script} {
	set m [dict create id $id x [expr {$x + $w}] y [expr {$y + $h + 8}] top $y items $items cur $cur script $script]
	ui::hit $x $y $w $h [list apply {{m x y} { page::menu_toggle $m }} $m]
	ui::focusable $id list $x $y $w $h 8 [list w::dropdown_key $m]
}

proc w::dropdown_key {m sym} {
	set keys [lmap it [dict get $m items] { lindex $it 0 }]
	set i [lsearch -exact $keys [dict get $m cur]]
	switch -- $sym {
		Up - Left { set i [expr {max(0, $i - 1)}] }
		Down - Right { set i [expr {min([llength $keys] - 1, $i + 1)}] }
		Return - KP_Enter - space { page::menu_toggle $m; return 1 }
		default { return 0 }
	}
	uplevel #0 [list {*}[dict get $m script] [lindex $keys $i]]
	return 1
}

# The open menu (drawn above the page): 6 px padding, 32 px rows, a check
# on the current item, the hovered one in FIELD.
proc w::menu_draw {m} {
	array set c [array get ui::c]
	set items [dict get $m items]
	set wd 236
	foreach it $items {
		set wd [expr {max($wd, 32 + ([lindex $it 2] ne "" ? 25 : 0) + [ui::measure i13 [lindex $it 1]] + ([lindex $it 0] eq [dict get $m cur] ? 24 : 0))}]
	}
	set wd [expr {int(ceil($wd))}]
	set h [expr {12 + 32 * [llength $items]}]
	set x [expr {[dict get $m x] - $wd}]; set y [dict get $m y]
	if {$y + $h > [w::wh] - 8 && [dict exists $m top]} { set y [expr {[dict get $m top] - 8 - $h}] }
	ui::layer
	raster::box $ui::img [expr {round($x)}] [expr {round($y)}] $wd $h -fill $c(bar) -radius 12 -ring [list $c(border) 1] -shadow {16 40 0.5}
	# a click anywhere else closes it
	ui::hit 0 0 1100 [w::wh] {apply {{x y} { page::menu_close }}}
	set iy [expr {$y + 6}]
	set k 0
	foreach it $items {
		lassign $it key label icon
		if {$k == $page::menu_hover} { ui::box [expr {$x + 6}] $iy [expr {$wd - 12}] 32 -fill $c(field) -radius 8 }
		set tx [expr {$x + 16}]
		if {$icon ne ""} { ui::icon $icon 15 $c(muted) $tx [expr {$iy + 8.5}]; set tx [expr {$tx + 25}] }
		ui::text $tx [expr {$iy + 8}] $label i13 $c(fg)
		if {$key eq [dict get $m cur]} { ui::icon check 14 $c(accent) [expr {$x + $wd - 30}] [expr {$iy + 9}] 2.4 }
		ui::hit [expr {$x + 6}] $iy [expr {$wd - 12}] 32 [list apply {{m key x y} { page::menu_pick $m $key }} $m $key]
		set iy [expr {$iy + 32}]
		incr k
	}
}

# ---- small controls --------------------------------------------------------------------------

# A switch (38 x 22) that flips.
proc w::switch_ {id x y on script} {
	ui::toggle $x $y $on
	ui::hit [expr {$x - 4}] [expr {$y - 5}] 46 32 [list apply {{s x y} { uplevel #0 $s }} $script]
	ui::focusable $id toggle $x $y 38 22 11 $script
}

# The row's undo: 26 x 26, FIELD, radius 7.
proc w::undo {x y script} {
	array set c [array get ui::c]
	ui::box $x $y 26 26 -fill $c(field) -radius 7
	ui::icon undo 13 $c(fg) [expr {$x + 6.5}] [expr {$y + 6.5}] 2
	ui::hit $x $y 26 26 [list apply {{s x y} { uplevel #0 $s }} $script]
}

# A text field with an edit icon at its right (the name field): 38 tall,
# 14 px text, ring BORDER (ACCENT while editing).
proc w::namefield {id x y w onenter onchange} {
	array set c [array get ui::c]
	set on [expr {$ui::focus eq $id}]
	set val [ui::fval $id]
	ui::box $x $y $w 38 -fill $c(field) -radius 10
	if {$on} { ui::ring $x $y $w 38 10 $c(accent) 1.5 } else { ui::ring $x $y $w 38 10 $c(border) 1 }
	ui::icon edit 14 [expr {$on ? $c(accent) : $c(muted)}] [expr {$x + $w - 26}] [expr {$y + 12}] 2
	set tx [expr {$x + 12}]
	set avail [expr {$w - 12 - 26 - 10}]
	set cur [expr {min($ui::fld($id,cur), [string length $val])}]
	set start 0
	while {$start < $cur && [ui::measure i14 [string range $val $start [expr {$cur - 1}]]] > $avail} { incr start }
	set vis [string range $val $start end]
	while {$vis ne "" && [ui::measure i14 $vis] > $avail + 2} { set vis [string range $vis 0 end-1] }
	ui::text $tx [expr {$y + 10.5}] $vis i14 $c(fg)
	if {$on} { ui::caret_at [expr {$tx + [ui::measure i14 [string range $val $start [expr {$cur - 1}]]] + 1}] [expr {$y + 11}] }
	ui::hit $x $y $w 38 [list ui::field_click $id $tx i14]
	ui::focusable $id field $x $y $w 38 10 [list $onchange $onenter 255]
}
