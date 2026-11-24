# ui.tcl - drawing for the installer, on the Ribbon shell's rasteriser.
#
# Everything that doesn't move is composited into one photo per draw
# (rounded boxes, rings, fills); text and icons are canvas items on top.
# Coordinates are the mockup's CSS pixels inside the 1100 x 720 window
# (1100 x 640 on a small screen: page::layout).
#
# Text is placed glyph by glyph from the font file's advances and kerning,
# not Xft's rounded ones (the shell's text.tcl, shared with the shell and
# the login screen), so lines, wraps, centring and letter-spacing land
# where the browser puts them in the mockups.

namespace eval ui {
	variable W 1100
	variable H 720
	variable ox 0          ;# where the window sits on the canvas
	variable oy 0
	variable cv ""         ;# the canvas
	variable img ""        ;# the photo boxes go into
	variable base ""       ;# this draw's photo
	variable img2 ""       ;# ... and the one above it (a dialog)
	variable behind ""     ;# photo of what is behind the window (its corners)
	variable argbwin ""    ;# the window, when it is ARGB (rbnalpha): see-through corners
	variable cut 0         ;# px of the window's left not shown (a screen under 1100 wide)
	variable bx 0          ;# ... and where the window is in it
	variable by 0
	variable hits {}       ;# {x0 y0 x1 y1 press ?drag? ?release?}
	variable wheels {}     ;# {x0 y0 x1 y1 script}
	variable focusables {} ;# {id kind x y w h r script}
	variable focus ""
	variable kbd 0         ;# focus moved with the keyboard: show it
	variable dim 0         ;# 0..1: a dialog is open, the page is shaded
	variable caret 1       ;# caret blink phase
	variable caretfix ""   ;# scenes: "on" / "off" stops the blink
	variable fonts
	# name: family, -weight, px size, ascent and descent (em) as the
	# browser rounds them for the line box
	array set fonts {
		i11s {{Ribbon Inter 600} normal 11 0.96875 0.2412}
		i12  {{Ribbon Inter 400} normal 12 0.96875 0.2412}
		i12s {{Ribbon Inter 600} normal 12 0.96875 0.2412}
		i13  {{Ribbon Inter 400} normal 13 0.96875 0.2412}
		i13m {{Ribbon Inter 500} normal 13 0.96875 0.2412}
		i13s {{Ribbon Inter 600} normal 13 0.96875 0.2412}
		i14  {{Ribbon Inter 400} normal 14 0.96875 0.2412}
		i14s {{Ribbon Inter 600} normal 14 0.96875 0.2412}
		i15s {{Ribbon Inter 600} normal 15 0.96875 0.2412}
		sg16b {{Ribbon Space Grotesk 700} normal 16 0.984 0.292}
		sg20 {{Ribbon Space Grotesk 600} normal 20 0.984 0.292}
		sg22 {{Ribbon Space Grotesk 600} normal 22 0.984 0.292}
		sg24 {{Ribbon Space Grotesk 600} normal 24 0.984 0.292}
		sg28 {{Ribbon Space Grotesk 600} normal 28 0.984 0.292}
		sg30 {{Ribbon Space Grotesk 600} normal 30 0.984 0.292}
		sg36 {{Ribbon Space Grotesk 600} normal 36 0.984 0.292}
		sg40 {{Ribbon Space Grotesk 600} normal 40 0.984 0.292}
		sg54 {{Ribbon Space Grotesk 600} normal 54 0.984 0.292}
		mono12 {{Ribbon Mono} normal 12 0.928 0.236}
	}
	variable c
	array set c {}
}

proc ui::fonts {} {
	variable fonts
	foreach {k spec} [array get fonts] {
		lassign $spec fam - px
		text::font ui_$k $fam $px
	}
}

# Palette from the shell's theme (the user's active Ribbon scheme).
proc ui::colours {} {
	variable c
	array set t [array get theme::c]
	array set c [list bar $t(BAR) field $t(FIELD) pill $t(PILL) border $t(BORDER) fg $t(FG) \
		muted $t(MUTED) accent $t(ACCENT) ink $t(ON_ACCENT) d1 $t(DESK_TOP) d2 $t(DESK_BOTTOM) \
		stripe $t(DESK_STRIPE) stripea $t(DESK_STRIPE_ALPHA)]
	set c(soft) [mix $c(accent) $c(bar) 0.16]
	set c(softd2) [mix $c(accent) $c(d2) 0.16]
	set c(softf) [mix $c(accent) $c(field) 0.16]
}

# a over b with alpha t
proc ui::mix {a b t} {
	lassign [raster::rgb $a] r1 g1 b1; lassign [raster::rgb $b] r2 g2 b2
	format #%02X%02X%02X [expr {round($r2 + ($r1 - $r2) * $t)}] [expr {round($g2 + ($g1 - $g2) * $t)}] [expr {round($b2 + ($b1 - $b2) * $t)}]
}

# A colour as drawn now (shaded while a dialog is open).
proc ui::col {hex} {
	variable dim
	if {$dim == 0} { return $hex }
	mix #000000 $hex $dim
}

# ---- text -------------------------------------------------------------------

proc ui::adv {f ch} { text::width ui_$f $ch }

# Width of TEXT in font F with letter-spacing LS (CSS: after every glyph).
proc ui::measure {f text {ls 0}} { text::width ui_$f $text $ls }

# Greedy word wrap at WIDTH, as the browser does for normal text.
proc ui::wrap {f text width {ls 0}} {
	set lines {}; set cur ""
	foreach word [split $text " "] {
		set try [expr {$cur eq "" ? $word : "$cur $word"}]
		if {$cur ne "" && [measure $f $try $ls] > $width + 0.01} {
			lappend lines $cur; set cur $word
		} else { set cur $try }
	}
	lappend lines $cur
	return $lines
}

# Text whose line box (content area) starts at TOP. ANCHOR w: x is the
# left edge, e: the right edge, c: the centre. Returns the width.
proc ui::text {x top str f colour {anchor w} {ls 0} {tags {}}} {
	variable cv
	variable fonts
	if {$str eq ""} { return 0 }
	set w [measure $f $str $ls]
	switch $anchor { e { set x [expr {$x - $w}] } c { set x [expr {$x - $w / 2.0}] } }
	lassign $fonts($f) - - px asc
	set base [expr {floor($top + round($asc * $px) + 0.5)}]
	set y [expr {$base - [font metrics ui_$f -ascent]}]
	text::draw $cv $x $y ui_$f [col $colour] $str nw -ls $ls -tags [list page {*}$tags]
	return $w
}

# Uppercase section label (11 px, 600, 0.12em): 14 tall plus 8 below.
proc ui::label {x y t {ls 1.32}} {
	variable c
	text $x $y [string toupper $t] i11s $c(muted) w $ls
}

# ---- shapes -------------------------------------------------------------------

# Snap like the browser: edges to whole pixels.
proc ui::snap {x y w h} {
	set x0 [expr {round($x)}]; set y0 [expr {round($y)}]
	list $x0 $y0 [expr {round($x + $w) - $x0}] [expr {round($y + $h) - $y0}]
}

# A rounded box into this draw's photo: -fill #hex -radius r
# -ring {#hex width}
proc ui::box {x y w h args} {
	variable img
	array set o {-fill #000000 -radius 0 -ring {} -shadow {}}
	array set o $args
	lassign [snap $x $y $w $h] x y w h
	if {$w <= 0 || $h <= 0} return
	set o(-fill) [col $o(-fill)]
	if {$o(-ring) ne ""} { lset o(-ring) 0 [col [lindex $o(-ring) 0]] }
	if {$o(-radius) == 0 && $o(-ring) eq ""} {
		$img put $o(-fill) -to $x $y [expr {$x + $w}] [expr {$y + $h}]
		return
	}
	raster::box $img $x $y $w $h -fill $o(-fill) -radius $o(-radius) {*}[expr {$o(-ring) ne "" ? [list -ring $o(-ring)] : ""}] \
		{*}[expr {$o(-shadow) ne "" ? [list -shadow $o(-shadow)] : ""}]
}

proc ui::hline {x0 x1 y colour} {
	variable img
	$img put [col $colour] -to [expr {round($x0)}] [expr {round($y)}] [expr {round($x1)}] [expr {round($y) + 1}]
}

# A box filled with a CSS linear-gradient(ANGLEdeg, rgba(C1, A1),
# rgba(C2, A2)), composited over what is there. radius may be "round".
proc ui::gradbox {x y w h radius angle c1 a1 c2 a2} {
	variable img
	lassign [snap $x $y $w $h] x y w h
	set c1 [col $c1]; set c2 [col $c2]
	set g [raster::cached [list grad $w $h $radius $angle $c1 $a1 $c2 $a2] {
		lassign [raster::rgb $c1] r1 g1 b1; lassign [raster::rgb $c2] r2 g2 b2
		set k [expr {acos(-1) / 180.0 * $angle}]
		set dx [expr {sin($k)}]; set dy [expr {-cos($k)}]
		set len [expr {abs($w * $dx) + abs($h * $dy)}]
		set r [expr {$radius eq "round" ? min($w, $h) / 2.0 : $radius}]
		set rows {}
		for {set j 0} {$j < $h} {incr j} {
			set row {}
			for {set i 0} {$i < $w} {incr i} {
				set px [expr {$i + 0.5}]; set py [expr {$j + 0.5}]
				set cov [raster::rbox $px $py 0 0 $w $h $r]
				set t [expr {min(1.0, max(0.0, (($px - $w / 2.0) * $dx + ($py - $h / 2.0) * $dy) / $len + 0.5))}]
				# premultiplied interpolation, as the browser does
				set a [expr {$a1 + ($a2 - $a1) * $t}]
				if {$a <= 0 || $cov <= 0} { lappend row 0 0 0 0; continue }
				set pr [expr {($r1 * $a1 + ($r2 * $a2 - $r1 * $a1) * $t) / $a}]
				set pg [expr {($g1 * $a1 + ($g2 * $a2 - $g1 * $a1) * $t) / $a}]
				set pb [expr {($b1 * $a1 + ($b2 * $a2 - $b1 * $a1) * $t) / $a}]
				lappend row [expr {int($pr + 0.5)}] [expr {int($pg + 0.5)}] [expr {int($pb + 0.5)}] [expr {int($a * $cov * 255 + 0.5)}]
			}
			lappend rows $row
		}
		raster::png $w $h $rows
	}]
	raster::blit $img $g 0 0 $w $h $x $y
}

# Radio: 18 px; on is a 5 px accent ring, off a 1 px muted one.
proc ui::radio {x y on bg} {
	variable c
	if {$on} { box $x $y 18 18 -fill $bg -radius 9 -ring [list $c(accent) 5] } else {
		box $x $y 18 18 -fill $bg -radius 9 -ring [list $c(muted) 1]
	}
}

proc ui::toggle {x y on} {
	variable c
	box $x $y 38 22 -fill [expr {$on ? $c(accent) : $c(pill)}] -radius 11
	box [expr {$on ? $x + 19 : $x + 3}] [expr {$y + 3}] 16 16 -fill [expr {$on ? $c(ink) : $c(muted)}] -radius 8
}

# Badge (20 tall, 11 px semibold): returns its width.
proc ui::badge {x y t {accent 0} {bg ""} {anchor w}} {
	variable c
	set w [expr {14 + [measure i11s $t]}]
	if {$anchor eq "e"} { set x [expr {$x - $w}] }
	if {$bg eq ""} { set bg $c(bar) }
	box $x $y $w 20 -fill [expr {$accent ? [mix $c(accent) $bg 0.16] : $c(pill)}] -radius 6
	text [expr {$x + 7}] [expr {$y + 3}] $t i11s [expr {$accent ? $c(accent) : $c(muted)}]
	return $w
}

# Checkbox square (SIZE 18 or 20, radius 5 or 6) with the check when on.
proc ui::check {x y on {size 18}} {
	variable c
	box $x $y $size $size -fill [expr {$on ? $c(accent) : $c(pill)}] -radius [expr {$size == 20 ? 6 : 5}]
	if {$on} {
		set is [expr {$size == 20 ? 12 : 11}]
		icon check $is $c(ink) [expr {$x + ($size - $is) / 2.0}] [expr {$y + ($size - $is) / 2.0}] 2.6
	}
}

# ---- icons ---------------------------------------------------------------------

namespace eval ui {
	variable paths
	array set paths {
		check {M20 6L9 17l-5-5}
		globe {M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0 M2 12h20 M12 2a15 15 0 0 1 0 20 M12 2a15 15 0 0 0 0 20}
		kbd {M2 6h20v12H2z M6 10h.01 M10 10h.01 M14 10h.01 M18 10h.01 M7 14h10}
		disk {M22 12H2 M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z M6 16h.01 M10 16h.01}
		lock {M5 11h14v10H5z M8 11V7a4 4 0 0 1 8 0v4}
		chip {M6 6h12v12H6z M9 2v4 M15 2v4 M9 18v4 M15 18v4 M2 9h4 M2 15h4 M18 9h4 M18 15h4}
		box {M21 16V8l-9-5-9 5v8l9 5 9-5z M3.3 7L12 12l8.7-5 M12 22V12}
		user {M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2 M12 11a4 4 0 1 0 0-8a4 4 0 1 0 0 8z}
		list {M8 6h13 M8 12h13 M8 18h13 M3 6h.01 M3 12h.01 M3 18h.01}
		wifi {M5 12.55a11 11 0 0 1 14 0 M1.42 9a16 16 0 0 1 21.16 0 M8.53 16.11a6 6 0 0 1 6.95 0 M12 20h.01}
		wifi-off {M1 1l22 22 M16.72 11.06A10.94 10.94 0 0 1 19 12.55 M5 12.55a10.94 10.94 0 0 1 5.17-2.39 M10.71 5.05A16 16 0 0 1 22.58 9 M1.42 9a15.91 15.91 0 0 1 4.7-2.88 M8.53 16.11a6 6 0 0 1 6.95 0 M12 20h.01}
		battery {M3 8h14a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2H3a1 1 0 0 1-1-1V9a1 1 0 0 1 1-1z M22 11v2}
		search {M4 11a7 7 0 1 0 14 0a7 7 0 1 0 -14 0 M21 21l-4.3-4.3}
		arrow {M5 12h14 M12 5l7 7-7 7}
		sparkle {M12 3l1.9 5.8L20 10l-6.1 1.2L12 17l-1.9-5.8L4 10l6.1-1.2z}
		plus {M12 5v14 M5 12h14}
		eye {M1 12C1 12 5 4 12 4C19 4 23 12 23 12C23 12 19 20 12 20C5 20 1 12 1 12z M9 12a3 3 0 1 0 6 0a3 3 0 1 0 -6 0}
		eye-off {M1 1l22 22 M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94 M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19 M14.12 14.12a3 3 0 1 1-4.24-4.24}
		restart {M1 4v6h6 M3.51 15a9 9 0 1 0 2.13-9.36L1 10}
		warn {M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z M12 9v4 M12 17h.01}
		cpu {M6 6h12v12H6z M9 2v4 M15 2v4 M9 18v4 M15 18v4 M2 9h4 M2 15h4 M18 9h4 M18 15h4}
		vol {M11 5L6 9H2v6h4l5 4z M15.54 8.46a5 5 0 0 1 0 7.07 M19.07 4.93a10 10 0 0 1 0 14.14}
		pad {M6 11h4 M8 9v4 M15 12h.01 M18 10h.01 M17.3 5H6.7a4 4 0 0 0-3.96 3.43l-.9 6.3A3 3 0 0 0 4.8 18c.94 0 1.83-.44 2.4-1.2l.8-1.1a2 2 0 0 1 1.6-.8h4.8a2 2 0 0 1 1.6.8l.8 1.1c.57.76 1.46 1.2 2.4 1.2a3 3 0 0 0 2.96-3.27l-.9-6.3A4 4 0 0 0 17.3 5z}
		finger {M12 11v3a8 8 0 0 1-1 4 M8 11a4 4 0 0 1 8 0v1 M4 11a8 8 0 0 1 16 0v2 M16 15a12 12 0 0 1-1 4 M8 15a6 6 0 0 1-1 3}
		bt {M7 7l10 10-5 5V2l5 5L7 17}
		x {M18 6L6 18 M6 6l12 12}
		monitor {M4 3h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z M8 21h8 M12 17v4}
		camera {M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z M12 17a4 4 0 1 0 0-8a4 4 0 1 0 0 8z}
		printer {M6 9V2h12v7 M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2 M6 14h12v8H6z}
		net {M2 12h20 M5 6h14v12H5z}
	}
}

# A line icon, top-left at x y (fractions kept to a quarter pixel).
proc ui::icon {name size colour x y {sw 1.9} {tags {}}} {
	variable cv
	variable paths
	set ix [expr {int(floor($x))}]; set iy [expr {int(floor($y))}]
	set ix [expr {round($x)}]; set iy [expr {round($y)}]; set fx 0; set fy 0
	set i [raster::icon $paths($name) $size $sw [col $colour] {} $fx $fy]
	$cv create image $ix $iy -image $i -anchor nw -tags [list page {*}$tags]
}

# ---- interaction ----------------------------------------------------------------

proc ui::hit {x y w h press {drag ""} {release ""}} {
	variable hits
	lappend hits [list $x $y [expr {$x + $w}] [expr {$y + $h}] $press $drag $release]
}

proc ui::wheel {x y w h script} {
	variable wheels
	lappend wheels [list $x $y [expr {$x + $w}] [expr {$y + $h}] $script]
}

# Something Tab reaches: kind field | list | button; script runs on
# Enter / Space (button) or gets the key (list).
proc ui::focusable {id kind x y w h r script} {
	variable focusables
	lappend focusables [list $id $kind $x $y $w $h $r $script]
}

proc ui::press {x y} {
	variable hits
	variable drag
	variable ox
	variable oy
	variable kbd 0
	update idletasks
	set x [expr {$x - $ox}]; set y [expr {$y - $oy}]
	set drag ""
	foreach h [lreverse $hits] {
		lassign $h x0 y0 x1 y1 press dr rel
		if {$x >= $x0 && $x < $x1 && $y >= $y0 && $y < $y1} {
			if {$dr ne ""} { set drag [list $dr $rel] }
			if {$press ne ""} { uplevel #0 [list {*}$press $x $y] }
			return
		}
	}
	page::clicked_outside
}

proc ui::motion {x y} {
	variable drag
	variable ox
	variable oy
	if {$drag ne ""} { uplevel #0 [list {*}[lindex $drag 0] [expr {$x - $ox}] [expr {$y - $oy}]] }
}

proc ui::release {x y} {
	variable drag
	variable ox
	variable oy
	if {$drag ne "" && [lindex $drag 1] ne ""} { uplevel #0 [list {*}[lindex $drag 1] [expr {$x - $ox}] [expr {$y - $oy}]] }
	set drag ""
}

proc ui::scroll {x y d} {
	variable wheels
	variable ox
	variable oy
	set x [expr {$x - $ox}]; set y [expr {$y - $oy}]
	foreach h [lreverse $wheels] {
		lassign $h x0 y0 x1 y1 script
		if {$x >= $x0 && $x < $x1 && $y >= $y0 && $y < $y1} { uplevel #0 [list {*}$script $d]; return }
	}
}

# Tab / Shift-Tab
proc ui::cycle {dir} {
	variable focusables
	variable focus
	variable kbd 1
	set ids [lmap f $focusables { lindex $f 0 }]
	if {![llength $ids]} return
	set i [lsearch -exact $ids $focus]
	set i [expr {$i < 0 ? ($dir > 0 ? 0 : [llength $ids] - 1) : ($i + $dir + [llength $ids]) % [llength $ids]}]
	set focus [lindex $ids $i]
	page::draw
}

proc ui::focused {} {
	variable focusables
	variable focus
	lsearch -inline -index 0 $focusables $focus
}

# The keyboard focus ring for controls other than fields.
proc ui::focus_ring {} {
	variable kbd
	variable c
	if {!$kbd} return
	set f [focused]
	if {$f eq "" || [lindex $f 1] eq "field"} return
	lassign $f - - x y w h r
	box [expr {$x - 3}] [expr {$y - 3}] [expr {$w + 6}] [expr {$h + 6}] -fill $c(bar) -radius [expr {$r + 3}] -ring [list $c(accent) 1.5]
}

# ---- text fields ---------------------------------------------------------------------

namespace eval ui {
	variable fld          ;# fld(id,text) fld(id,cur)
	array set fld {}
}

proc ui::fval {id} {
	variable fld
	if {![info exists fld($id,text)]} { set fld($id,text) ""; set fld($id,cur) 0 }
	return $fld($id,text)
}

proc ui::fset {id text} {
	variable fld
	set fld($id,text) $text
	set fld($id,cur) [string length $text]
}

# A 38 px field. opts: -ph placeholder -icon name -right {script drawing
# right-aligned content, given x (right edge) and y; returns its width}
# -secret 0|1 -prefix text -onchange script -w width -font
proc ui::field {id x y w args} {
	variable c
	variable focus
	variable fld
	variable caret
	array set o {-ph "" -icon "" -right "" -secret 0 -prefix "" -onchange "" -font i14}
	array set o $args
	set on [expr {$focus eq $id}]
	set val [fval $id]
	box $x $y $w 38 -fill $c(field) -radius 10 -ring [expr {$on ? [list $c(accent) 1.5] : [list $c(border) 1]}]
	set tx [expr {$x + 12}]
	if {$o(-icon) ne ""} {
		icon $o(-icon) 15 [expr {$on ? $c(accent) : $c(muted)}] $tx [expr {$y + 11.5}]
		set tx [expr {$tx + 25}]
	}
	set right [expr {$x + $w - 12}]
	if {$o(-right) ne ""} {
		set rw [uplevel #0 [list {*}$o(-right) $right $y]]
		if {$rw > 0} { set right [expr {$right - $rw - 10}] }
	}
	set shown [expr {$o(-secret) ? [string repeat • [string length $val]] : $val}]
	set top [expr {$y + 10.5}]
	if {$o(-prefix) ne ""} { set tx [expr {$tx + [text $tx $top $o(-prefix) $o(-font) $c(fg)]}] }
	if {$val eq "" && $o(-ph) ne "" && !($on && $o(-prefix) ne "")} {
		text $tx $top $o(-ph) $o(-font) $c(muted)
		set cx $tx
		if {$on} { set cx [expr {$tx - 1}] }
	} else {
		# keep the caret in view: show the tail when it doesn't fit
		set avail [expr {$right - $tx - 4}]
		set cur [expr {min($fld($id,cur), [string length $shown])}]
		set start 0
		while {$start < $cur && [measure $o(-font) [string range $shown $start [expr {$cur - 1}]]] > $avail} { incr start }
		set vis [string range $shown $start end]
		while {$vis ne "" && [measure $o(-font) $vis] > $avail + 4} { set vis [string range $vis 0 end-1] }
		text $tx $top $vis $o(-font) $c(fg)
		set cx [expr {$tx + [measure $o(-font) [string range $shown $start [expr {$cur - 1}]]]}]
	}
	if {$on} { caret_at [expr {$cx + 1}] [expr {$y + 11}] }
	hit $x $y $w 38 [list ui::field_click $id $tx $o(-font) $o(-secret)]
	focusable $id field $x $y $w 38 10 $o(-onchange)
}

proc ui::field_click {id tx f secret x y} {
	variable focus
	variable fld
	variable caret 1
	set focus $id
	set val [fval $id]
	set shown [expr {$secret ? [string repeat • [string length $val]] : $val}]
	set i 0; set pen $tx
	foreach ch [split $shown ""] {
		set a [adv $f $ch]
		if {$x < $pen + $a / 2.0} break
		set pen [expr {$pen + $a}]; incr i
	}
	set fld($id,cur) $i
	page::draw
}

# Editing keys for the focused field; returns 1 when the key was used.
proc ui::field_key {id sym char state} {
	variable fld
	variable focusables
	variable caret 1
	set t [fval $id]; set cur $fld($id,cur)
	set ctrl [expr {$state & 4}]
	switch -- $sym {
		BackSpace {
			if {$cur == 0} { return 1 }
			if {$ctrl} {
				set k [string wordstart $t [expr {$cur - 1}]]
				set t [string replace $t $k [expr {$cur - 1}]]; set cur $k
			} else { set t [string replace $t [expr {$cur - 1}] [expr {$cur - 1}]]; incr cur -1 }
		}
		Delete { if {$cur < [string length $t]} { set t [string replace $t $cur $cur] } }
		Left { if {$cur > 0} { incr cur -1 } }
		Right { if {$cur < [string length $t]} { incr cur } }
		Home { set cur 0 }
		End { set cur [string length $t] }
		default {
			if {$ctrl && $sym in {a A}} { set cur [string length $t] } \
			elseif {$ctrl && $sym in {u U}} { set t ""; set cur 0 } \
			elseif {$ctrl && $sym in {v V}} {
				if {![catch {clipboard get} clip]} {
					set clip [string map {\n "" \r "" \t " "} $clip]
					set t [string range $t 0 [expr {$cur - 1}]]$clip[string range $t $cur end]; incr cur [string length $clip]
				}
			} elseif {!$ctrl && $char ne "" && [string is print $char]} {
				set t [string range $t 0 [expr {$cur - 1}]]$char[string range $t $cur end]; incr cur
			} else { return 0 }
		}
	}
	set changed [expr {$t ne $fld($id,text)}]
	set fld($id,text) $t; set fld($id,cur) $cur
	if {$changed} {
		set f [lsearch -inline -index 0 $focusables $id]
		set script [lindex $f 7]
		if {$script ne ""} { uplevel #0 $script }
	}
	return 1
}

# The caret is a canvas item, so blinking needs no redraw.
proc ui::caret_at {x y} {
	variable cv
	variable c
	variable caret
	$cv create rectangle [expr {round($x)}] [expr {round($y)}] [expr {round($x) + 2}] [expr {round($y) + 16}] \
		-fill [col $c(accent)] -width 0 -tags {page caret} -state [expr {$caret ? "normal" : "hidden"}]
}

proc ui::blink {} {
	variable caret
	variable caretfix
	after cancel ui::blink
	if {$caretfix ne ""} { set caret [expr {$caretfix eq "on"}]; return }
	set caret [expr {!$caret}]
	variable cv
	if {$cv ne ""} { $cv itemconfigure caret -state [expr {$caret ? "normal" : "hidden"}] }
	after 530 ui::blink
}

# ---- buttons -------------------------------------------------------------------

# Width of a button: 18 px padding, 8 px gap to an icon.
proc ui::button_w {label kind {icon ""}} {
	set f [expr {$kind eq "primary" ? "i14s" : "i14"}]
	expr {36 + [measure $f $label] + ($icon ne "" ? 23 : 0)}
}

# kind primary | ghost | field; x y is the top-left.
proc ui::button {id x y label kind script {icon ""} {w ""}} {
	variable c
	set f [expr {$kind eq "primary" ? "i14s" : "i14"}]
	if {$w eq ""} { set w [button_w $label $kind $icon] }
	switch $kind {
		primary { box $x $y $w 38 -fill $c(accent) -radius 10; set fg $c(ink) }
		ghost { box $x $y $w 38 -fill $c(bar) -radius 10 -ring [list $c(border) 1]; set fg $c(fg) }
		field { box $x $y $w 38 -fill $c(field) -radius 10; set fg $c(fg) }
	}
	set cw [expr {[measure $f $label] + ($icon ne "" ? 23 : 0)}]
	set tx [expr {$x + ($w - $cw) / 2.0}]
	set tw [text $tx [expr {$y + 10.5}] $label $f $fg]
	if {$icon ne ""} { icon $icon 15 $fg [expr {$tx + $tw + 8}] [expr {$y + 11.5}] 2 }
	hit $x $y $w 38 [list apply {{s x y} { uplevel #0 $s }} $script]
	focusable $id button $x $y $w 38 10 $script
	return $w
}

# Segmented control (STYLE §8): opts {key label ...}; 38 tall, 3 px inset. The
# chosen part is raised neutral (§pill, §fg 600), never the accent.
proc ui::seg {id x y w opts cur script} {
	variable c
	box $x $y $w 38 -fill $c(field) -radius 10 -ring [list $c(border) 1]
	set n [expr {[llength $opts] / 2}]
	set sw [expr {($w - 6 - 2 * ($n - 1)) / double($n)}]
	set i 0
	foreach {k l} $opts {
		set sx [expr {$x + 3 + $i * ($sw + 2)}]
		set on [expr {$k eq $cur}]
		if {$on} { box $sx [expr {$y + 3}] $sw 32 -fill $c(pill) -radius 8 -shadow {1 2 0.3} }
		text [expr {$sx + $sw / 2.0}] [expr {$y + 11}] $l [expr {$on ? "i13s" : "i13m"}] [expr {$on ? $c(fg) : $c(muted)}] c
		hit $sx [expr {$y + 3}] $sw 32 [list apply {{s k x y} { uplevel #0 [list {*}$s $k] }} $script $k]
		incr i
	}
	focusable $id seg $x $y $w 38 10 [list ui::seg_key $opts $cur $script]
}

# Compact field button (STYLE §11): 34 tall, 13 px, 500, for buttons in rows.
# Returns its width. x is the right edge when anchor is e, else the left.
proc ui::cbutton {id x y label script {anchor w}} {
	variable c
	set w [expr {[measure i13m $label] + 28}]
	if {$anchor eq "e"} { set x [expr {$x - $w}] }
	box $x $y $w 34 -fill $c(field) -radius 9
	text [expr {$x + $w / 2.0}] [expr {$y + 9}] $label i13m $c(fg) c
	hit $x $y $w 34 [list apply {{s x y} { uplevel #0 $s }} $script]
	focusable $id button $x $y $w 34 9 $script
	return $w
}

proc ui::seg_key {opts cur script sym} {
	set keys [lmap {k l} $opts { set k }]
	set i [lsearch -exact $keys $cur]
	switch -- $sym {
		Left - Up { set i [expr {max(0, $i - 1)}] }
		Right - Down - space { set i [expr {$sym eq "space" ? ($i + 1) % [llength $keys] : min([llength $keys] - 1, $i + 1)}] }
		default { return 0 }
	}
	uplevel #0 [list {*}$script [lindex $keys $i]]
	return 1
}

# ---- a draw ------------------------------------------------------------------------

# Start a draw: a fresh photo with the window's corners showing what is
# behind it (the wallpaper, or the scene's desktop).
proc ui::begin {key script} {
	variable argbwin
	variable cv
	variable img
	variable img2
	variable behind
	variable bx
	variable by
	variable W
	variable H
	variable c
	variable hits {}
	variable wheels {}
	variable focusables {}
	$cv delete page
	variable base
	foreach i [list $base $img2] { if {$i ne ""} { image delete $i } }
	set img2 ""
	variable frames
	set img [set base [image create photo -width $W -height $H]]
	# the frame (window, rail, its marks) is the same for every draw of a
	# step: it is drawn once and copied
	set fk [list $key [col $c(bar)]]
	if {![info exists frames($fk)]} {
		set f [image create photo -width $W -height $H]
		# an ARGB window (rbnalpha): the corners stay transparent, and the
		# frame becomes the window's background (see-through corners)
		if {$argbwin eq ""} { $f put $c(bar) -to 0 0 $W $H }
		if {$behind ne ""} {
			foreach {x y} [list 0 0 [expr {$W - 16}] 0 0 [expr {$H - 16}] [expr {$W - 16}] [expr {$H - 16}]] {
				$f copy $behind -from [expr {$bx + $x}] [expr {$by + $y}] [expr {$bx + $x + 16}] [expr {$by + $y + 16}] -to $x $y
			}
		}
		set img $f
		uplevel #0 $script
		set frames($fk) $f
		set img $base
	}
	$img copy $frames($fk)
	if {$argbwin ne ""} {
		variable cut
		set fr $frames($fk)
		if {$cut > 0} {
			# the window shows the frame from x = cut
			if {![info exists frames(cut,$fk)]} {
				set frames(cut,$fk) [image create photo -width [expr {$W - $cut}] -height $H]
				$frames(cut,$fk) copy $fr -from $cut 0 $W $H -to 0 0
			}
			set fr $frames(cut,$fk)
		}
		rbn::appframe $argbwin $fr 16
	}
	$cv create image 0 0 -image $img -anchor nw -tags {page base}
}

# Boxes drawn after this go above everything drawn so far (a dialog).
proc ui::layer {} {
	variable cv
	variable img
	variable img2
	variable W
	variable H
	set img2 [image create photo -width $W -height $H]
	$cv create image 0 0 -image $img2 -anchor nw -tags {page top}
	set img $img2
}

proc ui::finish {} {
	variable cv
	variable ox
	variable oy
	$cv move page $ox $oy
}

# A list's foot fading to §bar over what is drawn there, its text too (an
# image above the canvas's text): CSS linear-gradient(transparent, §bar).
proc ui::fade {x y w h} {
	variable cv
	variable c
	lassign [snap $x $y $w $h] x y w h
	set colour [col $c(bar)]
	set g [raster::cached [list fade $w $h $colour] {
		lassign [raster::rgb $colour] cr cg cb
		set rows {}
		for {set j 0} {$j < $h} {incr j} {
			set a [expr {int(($j + 0.5) / $h * 255 + 0.5)}]
			set row {}
			for {set i 0} {$i < $w} {incr i} { lappend row $cr $cg $cb $a }
			lappend rows $row
		}
		raster::png $w $h $rows
	}]
	$cv create image $x $y -image $g -anchor nw -tags page
}

# A scrolling list's thumb (4 wide, §pill) at X, over the list's Y..Y+H:
# N rows, VIS of them shown from TOP.
proc ui::thumb {x y h n vis top} {
	variable c
	set th [expr {max(16.0, $h * $vis / double($n))}]
	set ty [expr {$y + ($h - $th) * $top / double(max(1, $n - $vis))}]
	box $x $ty 4 $th -fill $c(pill) -radius 2
}

# Only a ring (CSS inset box-shadow that shows above the children, as the
# mockups' clipped bars draw it), composited over what is there.
proc ui::ring {x y w h r colour width} {
	variable img
	lassign [snap $x $y $w $h] x y w h
	set colour [col $colour]
	set g [raster::cached [list ring $w $h $r $colour $width] {
		lassign [raster::rgb $colour] cr cg cb
		set ri [expr {max(0.0, $r - $width)}]
		set rows {}
		for {set j 0} {$j < $h} {incr j} {
			set row {}
			for {set i 0} {$i < $w} {incr i} {
				set px [expr {$i + 0.5}]; set py [expr {$j + 0.5}]
				set a [expr {[raster::rbox $px $py 0 0 $w $h $r] - [raster::rbox $px $py $width $width [expr {$w - $width}] [expr {$h - $width}] $ri]}]
				lappend row $cr $cg $cb [expr {int(max(0, $a) * 255 + 0.5)}]
			}
			lappend rows $row
		}
		raster::png $w $h $rows
	}]
	raster::blit $img $g 0 0 $w $h $x $y
}

# The shell's raster::cached looks its photo up in [image names] on every
# call; the installer redraws a page per key press, so it remembers them.
namespace eval raster { variable memo; array set memo {} }
rename raster::cached raster::cached_disk
proc raster::cached {key script} {
	variable memo
	if {[info exists memo($key)]} { return $memo($key) }
	set memo($key) [uplevel 1 [list raster::cached_disk $key $script]]
}
