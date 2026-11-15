# page-display.tcl - Settings → Display (U11, board Settings-A1-Display): the
# outputs drawn at their places, the chosen output's controls, Identify, Revert
# and Apply, and the keep-or-revert sheet. Positions are the board's inside the
# Settings window (rail 230 wide, content from x 270 to 1060, footer rule at
# 648 + page::dy). The logic is in display.tcl.

source -encoding utf-8 [file join [file dirname [file normalize [info script]]] display.tcl]

set ::ui::paths(monitor) {M4 3h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z M8 21h8 M12 17v4}

namespace eval display {
	variable asked 0        ;# the outputs have been asked for
	variable sel ""         ;# the output the controls edit
	variable pop ""         ;# the open dropdown's control id: res, rate, rot
	variable popitems {}    ;# its {value label} choices
	variable popidx 0
	variable rect           ;# control id -> {x y w} of the dropdown, for its list
	array set rect {}
	variable sl             ;# the slider track: sx0 and sx1
	array set sl {sx0 0 sx1 0}
	variable lab_rows {426 474 522 570}   ;# the four rows of both columns (48 tall)
}

# A hit that runs SCRIPT, as a button does.
proc display::hit {x y w h script} {
	ui::hit $x $y $w $h [list apply {{s x y} { uplevel #0 $s }} $script]
}

# The output's name as the page shows it: its model, else its connector name.
proc display::label {n} {
	set m [display::out $n]
	set model [dict get $m model]
	if {$model eq "" || $model eq "Unknown"} { return $n }
	return $model
}

# The output's place and size in the layout, in logical pixels: x y w h.
proc display::logical {n} {
	set s [display::val $n scale]
	set w [expr {[display::val $n w] / double($s)}]
	set h [expr {[display::val $n h] / double($s)}]
	if {[display::val $n transform] in {90 270}} { lassign [list $h $w] w h }
	list [display::val $n x] [display::val $n y] $w $h
}

proc display::res_key {n} { return "[display::val $n w]x[display::val $n h]" }

proc display::res_label {n} {
	set k [display::res_key $n]
	foreach i [display::res_items $n] { if {[lindex $i 0] eq $k} { return [lindex $i 1] } }
	return [string map {x " × "} $k]
}

proc display::rot_label {t} {
	switch -- $t { 90 { return "90°" } 180 { return "180°" } 270 { return "270°" } default { return Normal } }
}

# A dropdown: 32 tall, radius 8, a field with a border ring and a chevron.
proc display::dropdown {id x y w label} {
	variable rect
	array set c [array get ui::c]
	set rect($id) [list $x $y $w]
	ui::box $x $y $w 32 -fill $c(field) -radius 8 -ring [list $c(border) 1]
	if {$ui::focus eq $id && $ui::kbd} { ui::ring $x $y $w 32 8 $c(accent) 1.5 }
	ui::text [expr {$x + 12}] [ui::lh $y i13 32] $label i13 $c(fg)
	ui::icon down 14 $c(muted) [expr {$x + $w - 10 - 14}] [expr {$y + 9}] 2
	display::hit $x $y $w 32 [list display::open_pop $id]
	ui::focusable $id button $x $y $w 32 8 [list display::open_pop $id]
}

# The scale in whole percent, for the segmented control.
proc display::scale_key {n} { expr {round([display::val $n scale] * 100)} }

proc display::set_scale {pct} {
	variable sel
	display::set_val $sel scale [format %.2f [expr {$pct / 100.0}]]
	page::draw
}

proc display::hdr_on {} { expr {[display::hdr_val on] ? 1 : 0} }

proc display::toggle_hdr {} {
	variable want_hdr
	dict set want_hdr on [expr {![display::hdr_on]}]
	page::draw
}

proc display::toggle_adaptive {} {
	variable sel
	display::set_val $sel adaptive [expr {![display::val $sel adaptive]}]
	page::draw
}

# Switch an output on or off; the last one on stays on.
proc display::toggle_on {} {
	variable sel
	variable outs
	if {[display::val $sel on]} {
		set n 0
		foreach o $outs { if {[display::val [dict get $o name] on]} { incr n } }
		if {$n <= 1} return
	}
	display::set_val $sel on [expr {![display::val $sel on]}]
	page::draw
}

proc display::set_main {n} {
	variable main
	set main $n
	page::draw
}

proc display::select {n} {
	variable sel
	variable pop
	set sel $n
	set pop ""
	page::draw
}

# Dropdown items and the current choice for control ID.
proc display::pop_items {id} {
	variable sel
	switch -- $id {
		res {
			set items [display::res_items $sel]
			return [list $items [display::res_key $sel]]
		}
		rate {
			set items [display::rate_items $sel [display::val $sel w] [display::val $sel h]]
			return [list $items [display::val $sel r]]
		}
		rot {
			return [list {{normal Normal} {90 90°} {180 180°} {270 270°}} [display::val $sel transform]]
		}
	}
	return [list {} ""]
}

proc display::open_pop {id args} {
	variable pop
	variable popitems
	variable popidx
	lassign [display::pop_items $id] items cur
	set pop $id
	set popitems $items
	set popidx [lsearch -exact -index 0 $items $cur]
	if {$popidx < 0} { set popidx 0 }
	set ui::focus pop
	page::draw
}

proc display::pop_close {} {
	variable pop
	set pop ""
	set ui::focus ""
	page::draw
}

proc display::pop_choose {v} {
	variable pop
	variable sel
	switch -- $pop {
		res {
			lassign [split $v x] w h
			display::set_val $sel w $w
			display::set_val $sel h $h
			# keep the refresh rate when this size has it, else the fastest
			set rates [lmap r [display::rate_items $sel $w $h] { lindex $r 0 }]
			if {[display::val $sel r] ni $rates && [llength $rates]} { display::set_val $sel r [lindex $rates 0] }
		}
		rate { display::set_val $sel r $v }
		rot { display::set_val $sel transform $v }
	}
	set pop ""
	set ui::focus ""
	page::draw
}

proc display::pop_pick {i} {
	variable popitems
	display::pop_choose [lindex [lindex $popitems $i] 0]
}

# Keys while a dropdown is open: Up and Down move, Return chooses, Escape closes.
proc display::pop_key {sym} {
	variable popitems
	variable popidx
	switch -- $sym {
		Up { set popidx [expr {max(0, $popidx - 1)}] }
		Down { set popidx [expr {min([llength $popitems] - 1, $popidx + 1)}] }
		Return - KP_Enter - space { display::pop_pick $popidx }
		Escape { display::pop_close }
		default { return 0 }
	}
	page::draw
	return 1
}

# The open dropdown's list, over the rows (drawn in the layer above them).
proc display::popup_draw {} {
	variable pop
	variable popitems
	variable popidx
	variable rect
	array set c [array get ui::c]
	lassign $rect($pop) x y w
	set w [expr {max($w, 190)}]
	set n [llength $popitems]
	set h [expr {12 + 36 * $n}]
	set top [expr {$y + 38}]
	if {$top + $h > 708} { set top [expr {$y - 6 - $h}] }
	ui::layer
	ui::box $x $top $w $h -fill $c(bar) -radius 12 -ring [list $c(border) 1]
	set cur [lindex [display::pop_items $pop] 1]
	set i 0
	foreach item $popitems {
		lassign $item v label
		set iy [expr {$top + 6 + 36 * $i}]
		if {$i == $popidx} { ui::box [expr {$x + 6}] $iy [expr {$w - 12}] 36 -fill $c(field) -radius 8 }
		set on [expr {$v eq $cur}]
		ui::text [expr {$x + 18}] [ui::lh $iy [expr {$on ? "i13s" : "i13m"}] 36] $label [expr {$on ? "i13s" : "i13m"}] $c(fg)
		if {$on} { ui::icon check 14 $c(accent) [expr {$x + $w - 18 - 14}] [expr {$iy + 11}] 2.4 }
		display::hit [expr {$x + 6}] $iy [expr {$w - 12}] 36 [list display::pop_pick $i]
		incr i
	}
	ui::focusable pop list $x $top $w $h 12 display::pop_key
}

# The keep-or-revert sheet over the whole window, shown after Apply.
proc display::sheet_draw {} {
	variable secs
	array set c [array get ui::c]
	# the page under the sheet is shaded by ui::dim (set before the page was drawn); the sheet is not
	set ui::dim 0
	ui::layer
	set w 440; set h 170
	set x [expr {(1100 - $w) / 2}]; set y [expr {(720 - $h) / 2}]
	ui::box $x $y $w $h -fill $c(bar) -radius 16 -ring [list $c(border) 1]
	ui::text [expr {$x + 24}] [expr {$y + 24}] "Keep these display settings?" sg24 $c(fg) w -0.48
	ui::text [expr {$x + 24}] [expr {$y + 64}] "Reverting in $secs s unless you keep them." i14 $c(muted)
	set by [expr {$y + $h - 24 - 38}]
	set kw [ui::button_w "Keep changes" primary]
	set kx [expr {$x + $w - 24 - $kw}]
	set rw [ui::button_w Revert ghost]
	set rx [expr {$kx - 10 - $rw}]
	ui::button keep $kx $by "Keep changes" primary display::keep "" $kw
	ui::button sheetrevert $rx $by Revert ghost display::revert "" $rw
	ui::focusable sheet list $x $y $w $h 16 display::sheet_key
}

proc display::sheet_key {sym} {
	switch -- $sym {
		Escape { display::revert }
		Return - KP_Enter { display::keep }
		default { return 0 }
	}
	return 1
}

# The slider for SDR white: a neutral track and an 18 px knob, 80 to 440 nits (the board's knob place).
proc display::slide_at {x y} {
	variable sl
	variable nits_min
	variable nits_max
	set f [expr {($x - $sl(sx0)) / double($sl(sx1) - $sl(sx0))}]
	set f [expr {max(0.0, min(1.0, $f))}]
	dict set display::want_hdr nits [expr {int(round($nits_min + $f * ($nits_max - $nits_min)))}]
	page::draw
}

proc display::slide_key {sym} {
	variable nits_min
	variable nits_max
	set n [display::hdr_val nits]
	switch -- $sym {
		Left { set n [expr {max($nits_min, $n - 10)}] }
		Right { set n [expr {min($nits_max, $n + 10)}] }
		default { return 0 }
	}
	dict set display::want_hdr nits $n
	page::draw
	return 1
}

# A toggle at x y (38 x 22) with its hit and focus stop.
proc display::toggle {id x y on script} {
	ui::toggle $x $y $on
	display::hit $x $y 38 22 $script
	ui::focusable $id toggle $x $y 38 22 11 $script
}

# The header: the chosen output's name, its connector, Main display and On.
proc display::form_head {} {
	variable sel
	variable main
	array set c [array get ui::c]
	set name [display::label $sel]
	set w [ui::text 270 396 $name sg17 $c(fg)]
	ui::text [expr {270 + $w + 12}] [ui::lh 396 i13 22] $sel i13 $c(muted)
	set x 1022
	display::toggle on_$sel $x 396 [display::val $sel on] display::toggle_on
	set wOn [ui::measure i13 On]
	ui::text [expr {$x - 8}] [ui::lh 396 i13 22] On i13 $c(fg) e
	set x2 [expr {$x - 8 - $wOn - 18 - 38}]
	display::toggle main_$sel $x2 396 [expr {$main eq $sel}] [list display::set_main $sel]
	ui::text [expr {$x2 - 8}] [ui::lh 396 i13 22] "Main display" i13 $c(muted) e
}

# The two columns of controls for the chosen output.
proc display::form_rows {} {
	variable sel
	variable sl
	variable nits_min
	variable nits_max
	array set c [array get ui::c]
	# the right column has three rows: Colour profile is left out until the compositor loads ICC profiles
	# (DECISIONS-DELEGATED 39), so no rule sits under Variable refresh
	foreach y {426 474 522 570} { ui::hline 270 667 $y $c(border) }
	foreach y {426 474 522} { ui::hline 699 1060 $y $c(border) }
	# left column: Resolution, Refresh rate, Scale, Rotation
	ui::text 270 [ui::lh 426 i13m 48] Resolution i13m $c(fg)
	display::dropdown res 477 434 190 [display::res_label $sel]
	ui::text 270 [ui::lh 474 i13m 48] "Refresh rate" i13m $c(fg)
	display::dropdown rate 477 482 190 [display::hz [display::val $sel r]]
	ui::text 270 [ui::lh 522 i13m 48] Scale i13m $c(fg)
	ui::seg scale 377 530 290 {100 100% 125 125% 150 150% 200 200%} [display::scale_key $sel] display::set_scale 32
	ui::text 270 [ui::lh 570 i13m 48] Rotation i13m $c(fg)
	display::dropdown rot 477 578 190 [display::rot_label [display::val $sel transform]]
	# right column: HDR, SDR brightness, Variable refresh
	ui::text 699 [ui::lh 426 i13m 48] HDR i13m $c(fg)
	display::toggle hdr 1022 439 [display::hdr_on] display::toggle_hdr
	set lw [ui::text 699 [ui::lh 474 i13m 48] "SDR brightness" i13m $c(fg)]
	set nits [display::hdr_val nits]
	set vw [ui::measure i13 "$nits nits"]
	ui::text 1060 [ui::lh 474 i13 48] "$nits nits" i13 $c(fg) e
	set sx0 [expr {699 + $lw + 46}]
	set sx1 [expr {1060 - $vw - 14}]
	set sl(sx0) $sx0; set sl(sx1) $sx1
	set f [expr {($nits - $nits_min) / double($nits_max - $nits_min)}]
	set kx [expr {$sx0 + $f * ($sx1 - $sx0)}]
	set on [display::hdr_on]
	ui::box $sx0 496 [expr {$kx - $sx0}] 4 -fill $c(muted) -radius 2
	ui::box $kx 496 [expr {$sx1 - $kx}] 4 -fill $c(pill) -radius 2
	ui::box [expr {$kx - 9}] 489 18 18 -fill [expr {$on ? $c(fg) : $c(muted)}] -radius 9
	if {$on} {
		ui::hit [expr {$sx0 - 9}] 474 [expr {$sx1 - $sx0 + 18}] 48 [list display::slide_at] [list display::slide_at]
		ui::focusable hdrslide slider $sx0 474 [expr {$sx1 - $sx0}] 48 0 display::slide_key
	}
	ui::text 699 [ui::lh 522 i13m 48] "Variable refresh" i13m $c(fg)
	display::toggle adaptive 1022 535 [display::val $sel adaptive] display::toggle_adaptive
}

# The output boxes: each output at its place, to scale, numbered in the order read.
# The canvas: the board's well, 790 x 245 at (270, 120). Outputs that share a top edge ("arranged side by side")
# are drawn in a row, bottom-aligned, 9 apart, at one scale that fits the well (the tallest at 0.66 of its height,
# the row at 0.6 of its width) and centred on the well. Any other arrangement keeps its places, scaled to fit.
proc display::canvas {} {
	variable outs
	variable sel
	array set c [array get ui::c]
	ui::box 270 120 790 245 -fill $c(d2) -radius 12
	for {set gx 286} {$gx < 1050} {incr gx 16} {
		for {set gy 136} {$gy < 350} {incr gy 16} { ui::box $gx $gy 1 1 -fill $c(border) }
	}
	if {![llength $outs]} return
	set rects {}
	set tops {}
	foreach o $outs {
		set n [dict get $o name]
		lassign [display::logical $n] x y w h
		lappend rects $n [list $x $y $w $h]
		lappend tops $y
	}
	# where each box goes: name -> {left top width height} in window pixels
	array set at {}
	if {[llength [lsort -unique $tops]] == 1} {
		# left to right, by the logical x
		set byx {}
		foreach {n r} $rects { lappend byx [list [lindex $r 0] $n $r] }
		set byx [lsort -real -index 0 $byx]
		set sumw 0; set maxh 1
		foreach e $byx { lassign $e x n r; set sumw [expr {$sumw + [lindex $r 2]}]; if {[lindex $r 3] > $maxh} { set maxh [lindex $r 3] } }
		set gaps [expr {9 * ([llength $byx] - 1)}]
		set s [expr {min(0.66 * 245 / $maxh, (474 - $gaps) / $sumw)}]
		set tw [expr {$sumw * $s + $gaps}]
		set bottom [expr {120 + 245 / 2.0 + $maxh * $s / 2}]
		set x [expr {270 + (790 - $tw) / 2}]
		foreach e $byx {
			lassign $e rx n r
			lassign $r rx ry w h
			set bw [expr {$w * $s}]; set bh [expr {$h * $s}]
			set at($n) [list $x [expr {$bottom - $bh}] $bw $bh]
			set x [expr {$x + $bw + 9}]
		}
	} else {
		set x0 1e9; set y0 1e9; set x1 -1e9; set y1 -1e9
		foreach {n r} $rects {
			lassign $r x y w h
			set x0 [expr {min($x0, $x)}]; set y0 [expr {min($y0, $y)}]
			set x1 [expr {max($x1, $x + $w)}]; set y1 [expr {max($y1, $y + $h)}]
		}
		set bw [expr {max(1, $x1 - $x0)}]; set bh [expr {max(1, $y1 - $y0)}]
		set s [expr {min(0.6 * 790 / $bw, 0.66 * 245 / $bh)}]
		set ox [expr {270 + (790 - $bw * $s) / 2 - $x0 * $s}]
		set oy [expr {120 + (245 - $bh * $s) / 2 - $y0 * $s}]
		foreach {n r} $rects {
			lassign $r x y w h
			set at($n) [list [expr {$ox + $x * $s}] [expr {$oy + $y * $s}] [expr {$w * $s}] [expr {$h * $s}]]
		}
	}
	set i 0
	foreach {n r} $rects {
		incr i
		lassign $at($n) bx by bwid bhgt
		set on [expr {$n eq $sel}]
		ui::box $bx $by $bwid $bhgt -fill [expr {$on ? $c(field) : $c(bar)}] -radius 10 \
			-ring [list $c(border) 1]
		if {$on} { ui::ring $bx $by $bwid $bhgt 10 $c(accent) 1.5 }
		ui::text [expr {$bx + 14}] [expr {$by + 10}] $i sg22 [expr {$on ? $c(fg) : $c(muted)}]
		# the box says what the output is now (its mode, and its scale or refresh)
		set o [display::out $n]
		if {[dict get $o on]} {
			set s2 [dict get $o scale]
			set sub "[dict get $o w] × [dict get $o h] · "
			if {$s2 != 1} { append sub "[expr {round($s2 * 100)}]%" } else { append sub [display::hz [dict get $o r]] }
		} else {
			set sub "Off"
		}
		set bottom [expr {$by + $bhgt - 14}]
		ui::text [expr {$bx + 14}] [expr {$bottom - 16}] $sub i12 $c(muted)
		ui::text [expr {$bx + 14}] [expr {$bottom - 34}] [display::label $n] i12s [expr {$on ? $c(fg) : $c(muted)}]
		display::hit $bx $by $bwid $bhgt [list display::select $n]
		ui::focusable box-$n button $bx $by $bwid $bhgt 10 [list display::select $n]
	}
}

# The footer: Identify on the left, Revert and Apply on the right (the footer rule is the host's).
proc display::footer {} {
	set dy $::page::dy
	ui::button identify 270 [expr {665 + $dy}] Identify ghost display::identify monitor
	set aw [ui::button_w Apply primary check]
	set ax [expr {1060 - $aw}]
	ui::button apply $ax [expr {665 + $dy}] Apply primary display::apply check $aw
	set rw [ui::button_w Revert ghost undo]
	ui::button revert [expr {$ax - 10 - $rw}] [expr {665 + $dy}] Revert ghost display::discard_all undo $rw
}

proc display::discard_all {} {
	variable main
	display::discard
	set main [display::main_default]
	page::draw
}

# The page: the subtitle, the output boxes, the controls, the footer, and any open list or sheet.
proc display::page_draw {} {
	variable asked
	variable sel
	variable outs
	variable pop
	variable sheet
	variable main
	array set c [array get ui::c]
	if {!$asked} { set asked 1; display::fetch }
	# under the sheet the page is shaded (ui::dim, as the Appearance dialogs shade it)
	set ui::dim [expr {$sheet ? 0.5 : 0}]
	# the rail was drawn first: its hits and stops stay under this page's
	set base_hits $ui::hits
	set base_wheels $ui::wheels
	if {$sel eq "" || [display::out $sel] eq {}} {
		if {[llength $outs]} { set sel [expr {$main ne "" ? $main : [dict get [lindex $outs 0] name]}] }
	}
	ui::text 270 34 Display sg28 $c(fg) w -0.56
	set y 76
	foreach line [ui::wrap i14 [display::subtitle] 790] { ui::text 270 [ui::lh $y i14 21 1] $line i14 $c(muted); incr y 21 }
	display::canvas
	if {[llength $outs] && $sel ne ""} { display::form_head; display::form_rows }
	display::footer
	ui::hline 230 1100 [expr {648 + $::page::dy}] $c(border)
	if {$pop ne "" || $sheet} {
		# a list or the sheet is modal: only its own stops and, for a list, a click outside closes it
		set ui::hits $base_hits
		set ui::wheels $base_wheels
		set ui::focusables {}
		if {$sheet} {
			ui::hit 0 0 1100 720 ""
			display::sheet_draw
			set ui::focus sheet
		} else {
			display::hit 230 0 870 720 display::pop_close
			display::popup_draw
			if {$ui::focus ne "pop"} { set ui::focus pop }
		}
	}
}

# Apply is the board's primary: the layout and HDR change, and the keep sheet opens.
# Keep and Revert live in that sheet; Revert discards pending edits.
settings::page display -title Display -icon monitor -group 1 -order 2 -draw display::page_draw \
	-rows {Resolution {Refresh rate} Scale Rotation HDR {SDR brightness} {Variable refresh} \
		{Main display} On Identify Revert Apply}
