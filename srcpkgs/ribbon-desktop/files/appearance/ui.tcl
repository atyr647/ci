# ui.tcl - drawing for the Appearance app, on the Ribbon shell's rasteriser,
# the way the installer draws (srcpkgs/ribbon-installer/files/tk/ui.tcl):
# everything that doesn't move is composited into one photo per draw
# (rounded boxes, rings, swatches, thumbnails); text and icons are canvas
# items on top. Coordinates are the mockups' CSS pixels inside the
# 1100 x 720 window.
#
# Text is placed letter by letter where a browser puts it, by the shell's
# text.tcl (advances, kerning and tabular figures from the font file), so
# lines, centring and letter-spacing land where the mockups have them.

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
	variable bx 0
	variable by 0
	variable hits {}       ;# {x0 y0 x1 y1 press ?drag? ?release?}
	variable wheels {}
	variable focusables {} ;# {id kind x y w h r script}
	variable focus ""
	variable kbd 0         ;# focus moved with the keyboard: show it
	variable dim 0         ;# 0..1: a dialog is open, the page is shaded
	variable caret 1
	variable caretfix ""   ;# scenes: "on" / "off" stops the blink
	variable drawno 0
	variable fonts
	# name: family, px size, ascent and descent (em) as the browser rounds
	# them for the line box
	array set fonts {
		i10s {{Ribbon Inter 600} 10 0.96875 0.2412}
		i11s {{Ribbon Inter 600} 11 0.96875 0.2412}
		i12  {{Ribbon Inter 400} 12 0.96875 0.2412}
		i12m {{Ribbon Inter 500} 12 0.96875 0.2412}
		i12s {{Ribbon Inter 600} 12 0.96875 0.2412}
		i12b {{Ribbon Inter 700} 12 0.96875 0.2412}
		i13  {{Ribbon Inter 400} 13 0.96875 0.2412}
		i13m {{Ribbon Inter 500} 13 0.96875 0.2412}
		i13s {{Ribbon Inter 600} 13 0.96875 0.2412}
		i14  {{Ribbon Inter 400} 14 0.96875 0.2412}
		i14m {{Ribbon Inter 500} 14 0.96875 0.2412}
		i14s {{Ribbon Inter 600} 14 0.96875 0.2412}
		sg16 {{Ribbon Space Grotesk 600} 16 0.984 0.292}
		sg17 {{Ribbon Space Grotesk 600} 17 0.984 0.292}
		sg22 {{Ribbon Space Grotesk 600} 22 0.984 0.292}
		sg24 {{Ribbon Space Grotesk 600} 24 0.984 0.292}
		sg28 {{Ribbon Space Grotesk 600} 28 0.984 0.292}
		sg32 {{Ribbon Space Grotesk 600} 32 0.984 0.292}
		sg37 {{Ribbon Space Grotesk 600} 37 0.984 0.292}
		sg58 {{Ribbon Space Grotesk 600} 58 0.984 0.292}
		mono10 {{Ribbon Mono} 10 0.928 0.236}
		mono12 {{Ribbon Mono} 12 0.928 0.236}
		mono12b {{Ribbon Mono Bold} 12 0.928 0.236}
		mono13 {{Ribbon Mono} 13 0.928 0.236}
		i10b {{Ribbon Inter 700} 10 0.96875 0.2412}
	}
	variable c
	array set c {}
	variable tk
	array set tk {}
}

proc ui::fonts {} {
	variable fonts
	foreach {k spec} [array get fonts] {
		lassign $spec fam px
		text::font ui_$k $fam $px
	}
}

# Settings → Accessibility, as Ribbon's own apps take it (shell/text.tcl reads ~/.config/ribbon/access.conf).
namespace eval ui {
	variable lastp ""      ;# the palette ui::colours was last given (ui::recolour)
}
# Reduce motion: an app's animation jumps to its end.
proc ui::reduce_motion {} { text::reduce_motion }
# High contrast: muted text halfway to the text colour, rules and rings 40 % of the way, the rest as the palette.
proc ui::high_contrast {} { text::high_contrast }

# The palette again, as access.conf now says (Settings → Accessibility after a change).
proc ui::recolour {} {
	variable lastp
	if {$lastp ne ""} { colours $lastp }
}

# The palette the app is drawn in (the theme being looked at).
proc ui::colours {p} {
	variable c
	variable lastp $p
	array unset c
	array set c [list bar [dict get $p BAR] field [dict get $p FIELD] pill [dict get $p PILL] \
		border [dict get $p BORDER] fg [dict get $p FG] muted [dict get $p MUTED] \
		accent [dict get $p ACCENT] ink [dict get $p ON_ACCENT] d1 [dict get $p DESK_TOP] \
		d2 [dict get $p DESK_BOTTOM] stripe [dict get $p DESK_STRIPE] stripea [dict get $p DESK_STRIPE_ALPHA]]
	if {[high_contrast]} {
		set c(muted) [mix $c(fg) $c(muted) 0.5]
		set c(border) [mix $c(fg) $c(border) 0.4]
	}
	set c(soft) [mix $c(accent) $c(bar) 0.16]
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

# ---- text ------------------------------------------------------------------

# Where each letter of STR starts and the width: {x0 x1 ... width}.
proc ui::layout {f str {ls 0} {tnum 0}} {
	text::layout ui_$f $str $ls $tnum
}

proc ui::measure {f str {ls 0} {tnum 0}} {
	if {$str eq ""} { return 0 }
	lindex [layout $f $str $ls $tnum] end
}

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

# The height of a line of F with line-height: normal (the browser rounds
# the ascent and the descent each to whole pixels).
proc ui::lhn {f} {
	variable fonts
	lassign $fonts($f) - px asc desc
	expr {round($asc * $px) + round($desc * $px)}
}

# The top of the content area of a line LH px tall that starts at TOP:
# centred (flex centring), or with FLOOR as line-height does it (the
# browser floors the half-leading above).
proc ui::lh {top f lh {floor 0}} {
	set hl [expr {($lh - [lhn $f]) / 2.0}]
	expr {$top + ($floor ? floor($hl) : $hl)}
}

# Text whose content area starts at TOP. ANCHOR w: x is the left edge,
# e: the right edge, c: the centre. Returns the width.
proc ui::text {x top str f colour {anchor w} {ls 0} {tags {}} {tnum 0}} {
	variable cv
	variable fonts
	variable tk
	if {$str eq ""} { return 0 }
	set xs [layout $f $str $ls $tnum]
	set w [lindex $xs end]
	switch $anchor { e { set x [expr {$x - $w}] } c { set x [expr {$x - $w / 2.0}] } }
	lassign $fonts($f) - px asc
	set base [expr {floor($top + round($asc * $px) + 0.5)}]
	if {![info exists tk($f)]} { set tk($f) [font metrics ui_$f -ascent] }
	set y [expr {$base - $tk($f)}]
	text::draw $cv $x $y ui_$f [col $colour] $str nw -ls $ls -tnum $tnum -tags [list page {*}$tags]
	return $w
}

# Uppercase section label (11 px, 600, 0.12em).
proc ui::label {x y t} {
	variable c
	text $x $y [string toupper $t] i11s $c(muted) w 1.32
}

# ---- shapes ----------------------------------------------------------------

proc ui::snap {x y w h} {
	set x0 [expr {round($x)}]; set y0 [expr {round($y)}]
	list $x0 $y0 [expr {round($x + $w) - $x0}] [expr {round($y + $h) - $y0}]
}

# A rounded box into this draw's photo: -fill #hex -radius r -ring {#hex w}
proc ui::box {x y w h args} {
	variable img
	array set o {-fill #000000 -radius 0 -ring {}}
	array set o $args
	lassign [snap $x $y $w $h] x y w h
	if {$w <= 0 || $h <= 0} return
	set o(-fill) [col $o(-fill)]
	if {$o(-ring) ne ""} { lset o(-ring) 0 [col [lindex $o(-ring) 0]] }
	if {$o(-radius) == 0 && $o(-ring) eq ""} {
		$img put $o(-fill) -to $x $y [expr {$x + $w}] [expr {$y + $h}]
		return
	}
	raster::box $img $x $y $w $h -fill $o(-fill) -radius $o(-radius) {*}[expr {$o(-ring) ne "" ? [list -ring $o(-ring)] : ""}]
}

# The radius of a window's outer corner: 0 when labwc frames the window (its corners are the compositor's, so the
# content is square to the edges), R otherwise (an own frame, a scene's bare toplevel).
proc ui::outer_radius {r} {
	variable cv
	if {[info commands ::rbn::squared] ne "" && [::rbn::squared [winfo toplevel $cv]]} { return 0 }
	return $r
}

proc ui::hline {x0 x1 y colour} {
	variable img
	$img put [col $colour] -to [expr {round($x0)}] [expr {round($y)}] [expr {round($x1)}] [expr {round($y) + 1}]
}

# A shape at fractional coordinates (the mockups' miniature desktops): a
# rounded box filled with FILL at ALPHA, an inset ring {#hex width alpha},
# or a circle with the avatar's 150-degree gradient (-grad end-alpha).
proc ui::fbox {x y w h args} {
	variable img
	array set o {-fill #000000 -alpha 1 -radius 0 -ring {} -grad {} -snap 0}
	array set o $args
	if {$o(-snap)} {
		# laid out (not transformed): the browser snaps the box to whole
		# pixels, at least one wide
		set x0 [expr {round($x)}]; set y0 [expr {round($y)}]
		set w [expr {max(1, round($x + $w) - $x0)}]; set h [expr {max(1, round($y + $h) - $y0)}]
		set x $x0; set y $y0
	}
	set ix [expr {int(floor($x))}]; set iy [expr {int(floor($y))}]
	set fx [expr {$x - $ix}]; set fy [expr {$y - $iy}]
	set iw [expr {int(ceil($fx + $w))}]; set ih [expr {int(ceil($fy + $h))}]
	if {$iw <= 0 || $ih <= 0} return
	set fill [col $o(-fill)]
	set ring $o(-ring)
	if {$ring ne ""} { lset ring 0 [col [lindex $ring 0]] }
	set g [mem [list fbox $fx $fy $w $h $fill $o(-alpha) $o(-radius) $ring $o(-grad)] {
		lassign [raster::rgb $fill] fr fg fb
		lassign {0 0 0 0 1} rr rg rb rw ra
		if {$ring ne ""} { lassign $ring rc rw ra; if {$ra eq ""} { set ra 1 }; lassign [raster::rgb $rc] rr rg rb }
		set r $o(-radius)
		set x1 [expr {$fx + $w}]; set y1 [expr {$fy + $h}]
		set rows {}
		for {set j 0} {$j < $ih} {incr j} {
			set row {}
			for {set i 0} {$i < $iw} {incr i} {
				set px [expr {$i + 0.5}]; set py [expr {$j + 0.5}]
				set co [raster::rbox $px $py $fx $fy $x1 $y1 $r]
				if {$co <= 0} { lappend row 0 0 0 0; continue }
				set fa $o(-alpha)
				if {$o(-grad) ne ""} {
					set t [expr {(($px - $fx - $w / 2.0) * 0.5 + ($py - $fy - $h / 2.0) * 0.8660254037844386) / ($w * 0.5 + $h * 0.8660254037844386) + 0.5}]
					set fa [expr {1.0 + ($o(-grad) - 1.0) * min(1.0, max(0.0, $t))}]
				}
				set ci 0
				if {$rw > 0} {
					set ci [expr {$co - [raster::rbox $px $py [expr {$fx + $rw}] [expr {$fy + $rw}] [expr {$x1 - $rw}] [expr {$y1 - $rw}] [expr {max(0.0, $r - $rw)}]]}]
				}
				# the ring (an inset shadow) over the fill
				set a1 [expr {$co * $fa}]; set a2 [expr {$ci * $ra}]
				set a [expr {$a2 + $a1 * (1 - $a2)}]
				if {$a <= 0} { lappend row 0 0 0 0; continue }
				set k [expr {$a2 / $a}]
				lappend row [expr {int($rr * $k + $fr * (1 - $k) + 0.5)}] [expr {int($rg * $k + $fg * (1 - $k) + 0.5)}] \
					[expr {int($rb * $k + $fb * (1 - $k) + 0.5)}] [expr {int(min(1.0, $a) * 255 + 0.5)}]
			}
			lappend rows $row
		}
		raster::png $iw $ih $rows
	}]
	raster::blit $img $g 0 0 $iw $ih $ix $iy
}

# Only a ring (CSS inset box-shadow), composited over what is there.
proc ui::ring {x y w h r colour width {alpha 1}} {
	variable img
	lassign [snap $x $y $w $h] x y w h
	set colour [col $colour]
	# in the app's own colours, the same every start: kept on disk
	set g [raster::cached [list ring $w $h $r $colour $width $alpha] {
		lassign [raster::rgb $colour] cr cg cb
		set ri [expr {max(0.0, $r - $width)}]
		set rows {}
		for {set j 0} {$j < $h} {incr j} {
			set row {}
			for {set i 0} {$i < $w} {incr i} {
				set px [expr {$i + 0.5}]; set py [expr {$j + 0.5}]
				set a [expr {[raster::rbox $px $py 0 0 $w $h $r] - [raster::rbox $px $py $width $width [expr {$w - $width}] [expr {$h - $width}] $ri]}]
				lappend row $cr $cg $cb [expr {int(max(0, $a) * $alpha * 255 + 0.5)}]
			}
			lappend rows $row
		}
		raster::png $w $h $rows
	}]
	raster::blit $img $g 0 0 $w $h $x $y
}

# CSS "border: 1.5px dashed" as the browser draws it at 1x: a 1 px line
# (the width is snapped down), 3 px dashes every 5 px, centred on each
# straight side; the corners' arcs are left faint.
proc ui::dashed {x y w h r colour} {
	variable img
	lassign [snap $x $y $w $h] x y w h
	set colour [col $colour]
	set g [raster::cached [list dashed $w $h $r $colour] {
		lassign [raster::rgb $colour] cr cg cb
		set rows {}
		for {set j 0} {$j < $h} {incr j} {
			set row {}
			for {set i 0} {$i < $w} {incr i} {
				set px [expr {$i + 0.5}]; set py [expr {$j + 0.5}]
				set a [expr {[raster::rbox $px $py 0 0 $w $h $r] - [raster::rbox $px $py 1 1 [expr {$w - 1}] [expr {$h - 1}] [expr {max(0.0, $r - 1)}]]}]
				if {$a > 0} {
					if {$px >= $r && $px <= $w - $r} { set s [expr {$px - $r}]; set len [expr {$w - 2.0 * $r}] } \
					elseif {$py >= $r && $py <= $h - $r} { set s [expr {$py - $r}]; set len [expr {$h - 2.0 * $r}] } \
					else { set len 0 }
					if {$len > 0} {
						set n [expr {int(($len + 2) / 5)}]
						set off [expr {($len - (5 * $n - 2)) / 2.0}]
						# how much of the pixel (s - 0.5 .. s + 0.5) a dash covers
						set k [expr {$s - 0.5 - $off}]
						set cov 0.0
						foreach d [list [expr {floor($k / 5)}] [expr {floor($k / 5) + 1}]] {
							if {$d < 0 || $d >= $n} continue
							set d0 [expr {5 * $d}]
							set cov [expr {$cov + max(0.0, min($k + 1, $d0 + 3) - max($k, $d0))}]
						}
						set a [expr {$a * min(1.0, $cov)}]
					} else { set a [expr {$a * 0.45}] }
				}
				lappend row $cr $cg $cb [expr {int(max(0, $a) * 255 + 0.5)}]
			}
			lappend rows $row
		}
		raster::png $w $h $rows
	}]
	raster::blit $img $g 0 0 $w $h $x $y
}

# What is outside a rounded box's corners, painted in COLOUR (to clip a
# picture to radius R as overflow: hidden does).
proc ui::corners {x y w h r colour} {
	variable img
	set colour [col $colour]
	set n [expr {int(ceil($r)) + 1}]
	set g [mem [list corner $r $colour] {
		lassign [raster::rgb $colour] cr cg cb
		set rows {}
		for {set j 0} {$j < $n} {incr j} {
			set row {}
			for {set i 0} {$i < $n} {incr i} {
				set a [expr {1.0 - [raster::rbox [expr {$i + 0.5}] [expr {$j + 0.5}] 0 0 [expr {2 * $n + 10}] [expr {2 * $n + 10}] $r]}]
				lappend row $cr $cg $cb [expr {int($a * 255 + 0.5)}]
			}
			lappend rows $row
		}
		raster::png $n $n $rows
	}]
	# the four corners, mirrored from the top-left one
	foreach {fx fy} {0 0 1 0 0 1 1 1} {
		set name $g.$fx$fy
		if {$name ni [image names]} {
			image create photo $name
			$name copy $g -subsample [expr {$fx ? -1 : 1}] [expr {$fy ? -1 : 1}]
		}
		raster::blit $img $name 0 0 $n $n [expr {$fx ? $x + $w - $n : $x}] [expr {$fy ? $y + $h - $n : $y}]
	}
}

# A photo built by SCRIPT (PNG bytes), kept in memory: colours being
# edited would otherwise fill the shell's disk cache. Kept while used in
# the last two draws, or while there are few.
proc ui::mem {key script} {
	variable memo
	variable drawno
	if {[info exists memo($key)]} {
		lset memo($key) 1 $drawno
		return [lindex $memo($key) 0]
	}
	set data [uplevel 1 $script]
	set p [image create photo -data $data -format png]
	set memo($key) [list $p $drawno]
	return $p
}
proc ui::mem_trim {} {
	variable memo
	variable drawno
	if {[array size memo] < 600} return
	foreach k [array names memo] {
		lassign $memo($k) p n
		if {$n < $drawno - 1} {
			foreach q [list $p {*}[lsearch -all -inline [image names] $p.*]] { image delete $q }
			unset memo($k)
		}
	}
}

# ---- controls -------------------------------------------------------------------

proc ui::toggle {x y on} {
	variable c
	box $x $y 38 22 -fill [expr {$on ? $c(accent) : $c(pill)}] -radius 11
	box [expr {$on ? $x + 19 : $x + 3}] [expr {$y + 3}] 16 16 -fill [expr {$on ? $c(ink) : $c(muted)}] -radius 8
}

# Checkbox (18 px, radius 5) with the check when on.
proc ui::check {x y on} {
	variable c
	box $x $y 18 18 -fill [expr {$on ? $c(accent) : $c(pill)}] -radius 5
	if {$on} { icon check 11 $c(ink) [expr {$x + 3.5}] [expr {$y + 3.5}] 2.6 }
}

# Badge: 20 tall, 11 px semibold, accent on soft accent (or muted on pill).
proc ui::badge {x y t {accent 1}} {
	variable c
	set w [expr {14 + [measure i11s $t]}]
	box $x $y $w 20 -fill [expr {$accent ? $c(soft) : $c(pill)}] -radius 6
	text [expr {$x + 7}] [expr {$y + 3}] $t i11s [expr {$accent ? $c(accent) : $c(muted)}]
	return $w
}

# ---- icons -----------------------------------------------------------------------

namespace eval ui {
	variable paths
	array set paths {
		palette {M12 22a10 10 0 1 1 10-10c0 2.5-2 3-4 3h-2a2 2 0 0 0-1 3.7A2 2 0 0 1 12 22z M7.5 10.5h.01 M12 7.5h.01 M16.5 10.5h.01}
		drop    {M12 2.7l5.7 5.6a8 8 0 1 1-11.4 0z}
		image   {M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z M8.5 10a1.5 1.5 0 1 0 0-3a1.5 1.5 0 1 0 0 3z M21 15l-5-5L5 21}
		lock    {M5 11h14v10H5z M8 11V7a4 4 0 0 1 8 0v4}
		plus    {M12 5v14 M5 12h14}
		copy    {M9 9h11v11H9z M5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1}
		undo    {M3 7v6h6 M21 17a9 9 0 0 0-15-6.7L3 13}
		link    {M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71 M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71}
		check   {M20 6L9 17l-5-5}
		edit    {M12 20h9 M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4z}
		trash   {M3 6h18 M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6 M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2}
		warn    {M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z M12 9v4 M12 17h.01}
		download {M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4 M7 10l5 5 5-5 M12 15V3}
		folder  {M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z}
		play    {M7 4v16l13-8z}
		up      {M18 15l-6-6-6 6}
		down    {M6 9l6 6 6-6}
		left    {M15 18l-6-6 6-6}
		full    {M8 3H5a2 2 0 0 0-2 2v3 M21 8V5a2 2 0 0 0-2-2h-3 M3 16v3a2 2 0 0 0 2 2h3 M16 21h3a2 2 0 0 0 2-2v-3}
		wins    {M3 5h13v10H3z M8 9h13v10H8z}
		game    {M6 11h4 M8 9v4 M15 12h.01 M18 10h.01 M17.3 5H6.7a4 4 0 0 0-3.96 3.43l-.9 6.3A3 3 0 0 0 4.8 18c.94 0 1.83-.44 2.4-1.2l.8-1.1a2 2 0 0 1 1.6-.8h4.8a2 2 0 0 1 1.6.8l.8 1.1c.57.76 1.46 1.2 2.4 1.2a3 3 0 0 0 2.96-3.27l-.9-6.3A4 4 0 0 0 17.3 5z}
		battery {M3 8h14a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2H3a1 1 0 0 1-1-1V9a1 1 0 0 1 1-1z M22 11v2}
		clock   {M12 22a10 10 0 1 0 0-20a10 10 0 1 0 0 20z M12 6v6l4 2}
		file    {M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z M14 3v5h5}
	}
}

# A line icon, top-left at x y (snapped to the pixel grid as the browser
# snaps an inline SVG).
proc ui::icon {name size colour x y {sw 1.9} {tags {}} {fill 0}} {
	variable cv
	variable paths
	set i [raster::icon $paths($name) $size $sw [col $colour] {} 0 0 $fill]
	$cv create image [expr {round($x)}] [expr {round($y)}] -image $i -anchor nw -tags [list page {*}$tags]
}

# ---- interaction ------------------------------------------------------------------

proc ui::hit {x y w h press {drag ""} {release ""}} {
	variable hits
	lappend hits [list $x $y [expr {$x + $w}] [expr {$y + $h}] $press $drag $release]
}

proc ui::wheel {x y w h script} {
	variable wheels
	lappend wheels [list $x $y [expr {$x + $w}] [expr {$y + $h}] $script]
}

# Something Tab reaches. kind: field | button | list | seg | slider | toggle
# | check | area. SCRIPT runs on Enter / Space (button, toggle, check) or
# gets the key and returns 1 if it used it.
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
	if {[info exists drag] && $drag ne ""} { uplevel #0 [list {*}[lindex $drag 0] [expr {$x - $ox}] [expr {$y - $oy}]] }
}

proc ui::release {x y} {
	variable drag
	variable ox
	variable oy
	if {[info exists drag] && $drag ne "" && [lindex $drag 1] ne ""} { uplevel #0 [list {*}[lindex $drag 1] [expr {$x - $ox}] [expr {$y - $oy}]] }
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
	ring [expr {$x - 3}] [expr {$y - 3}] [expr {$w + 6}] [expr {$h + 6}] [expr {$r + 3}] $c(accent) 1.5
}

# ---- text fields ---------------------------------------------------------------------

namespace eval ui {
	variable fld
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

# A field W x H (38 by default), text 14 px. opts: -ph placeholder
# -right text (muted, 12 px, at the right) -onchange script -onenter script
# -h height -font -ring 0|1 (the border ring when not focused) -pad 12
proc ui::field {id x y w args} {
	variable c
	variable focus
	variable fld
	array set o {-ph "" -right "" -onchange "" -onenter "" -h 38 -font i14 -ring 1 -pad 12 -radius 10 -max 64}
	array set o $args
	set on [expr {$focus eq $id}]
	set val [fval $id]
	set h $o(-h)
	box $x $y $w $h -fill $c(field) -radius $o(-radius)
	if {$on} { ring $x $y $w $h $o(-radius) $c(accent) 1.5 } elseif {$o(-ring)} { ring $x $y $w $h $o(-radius) $c(border) 1 }
	set tx [expr {$x + $o(-pad)}]
	set right [expr {$x + $w - $o(-pad)}]
	set top [lh $y $o(-font) $h]
	if {$o(-right) ne ""} {
		set rw [text $right [lh $y i12 $h] $o(-right) i12 $c(muted) e]
		set right [expr {$right - $rw - 10}]
	}
	if {$val eq "" && $o(-ph) ne ""} {
		text $tx $top $o(-ph) $o(-font) $c(muted)
		set cx $tx
	} else {
		set avail [expr {$right - $tx - 2}]
		set cur [expr {min($fld($id,cur), [string length $val])}]
		set start 0
		while {$start < $cur && [measure $o(-font) [string range $val $start [expr {$cur - 1}]]] > $avail} { incr start }
		set vis [string range $val $start end]
		while {$vis ne "" && [measure $o(-font) $vis] > $avail + 2} { set vis [string range $vis 0 end-1] }
		text $tx $top $vis $o(-font) $c(fg)
		set cx [expr {$tx + [measure $o(-font) [string range $val $start [expr {$cur - 1}]]]}]
	}
	if {$on} { caret_at [expr {$cx + 1}] [expr {$y + ($h - 16) / 2.0}] }
	hit $x $y $w $h [list ui::field_click $id $tx $o(-font)]
	focusable $id field $x $y $w $h $o(-radius) [list $o(-onchange) $o(-onenter) $o(-max)]
}

proc ui::field_click {id tx f x y} {
	variable focus
	variable fld
	variable caret 1
	set focus $id
	set val [fval $id]
	set i 0
	set xs [layout $f $val]
	foreach ch [split $val ""] x0 [lrange $xs 0 end-1] x1 [lrange $xs 1 end] {
		if {$x < $tx + ($x0 + $x1) / 2.0} break
		incr i
	}
	set fld($id,cur) $i
	page::draw
}

# Editing keys for the focused field; returns 1 when the key was used.
proc ui::field_key {id sym char state} {
	variable fld
	variable caret 1
	set f [focused]
	lassign [lindex $f 7] onchange onenter max
	set t [fval $id]; set cur $fld($id,cur)
	set ctrl [expr {$state & 4}]
	switch -- $sym {
		Return - KP_Enter { if {$onenter ne ""} { uplevel #0 $onenter; return 1 }; return 0 }
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
	if {$max ne "" && [string length $t] > $max} { return 1 }
	set changed [expr {$t ne $fld($id,text)}]
	set fld($id,text) $t; set fld($id,cur) $cur
	if {$changed && $onchange ne ""} { uplevel #0 $onchange }
	return 1
}

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

# Width of a button: 18 px padding, 8 px gap to a 15 px icon.
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
		ghost { ring $x $y $w 38 10 $c(border) 1; set fg $c(fg) }
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

# Segmented control (STYLE §8): opts {key label ...}; H is 32 or 38. The track
# is §field with a 1 px ring; the chosen part is raised in §pill (never the
# accent), 600 §fg, the others 500 §muted; 13 px text, parts 2 apart.
proc ui::seg {id x y w opts cur script {h 32} {r ""} {ir ""}} {
	variable c
	variable img
	if {$r eq ""} { set r [expr {$h >= 38 ? 10 : 9}] }
	if {$ir eq ""} { set ir [expr {$h >= 38 ? 8 : 6}] }
	box $x $y $w $h -fill $c(field) -radius $r -ring [list $c(border) 1]
	set n [expr {[llength $opts] / 2}]
	set sw [expr {($w - 6 - 2 * ($n - 1)) / double($n)}]
	set i 0
	foreach {k l} $opts {
		set sx [expr {$x + 3 + $i * ($sw + 2)}]
		set on [expr {$k eq $cur}]
		if {$on} {
			lassign [snap $sx [expr {$y + 3}] $sw [expr {$h - 6}]] px py pw ph
			raster::box $img $px $py $pw $ph -fill [col $c(pill)] -radius $ir -shadow {1 2 0.3}
		}
		text [expr {$sx + $sw / 2.0}] [lh [expr {$y + 3}] [expr {$on ? "i13s" : "i13m"}] [expr {$h - 6}]] $l \
			[expr {$on ? "i13s" : "i13m"}] [expr {$on ? $c(fg) : $c(muted)}] c
		hit $sx [expr {$y + 3}] $sw [expr {$h - 6}] [list apply {{s k x y} { uplevel #0 [list {*}$s $k] }} $script $k]
		incr i
	}
	focusable $id seg $x $y $w $h $r [list ui::seg_key $opts $cur $script]
}

proc ui::seg_key {opts cur script sym} {
	set keys [lmap {k l} $opts { set k }]
	set i [lsearch -exact $keys $cur]
	switch -- $sym {
		Left - Up { set i [expr {max(0, $i - 1)}] }
		Right - Down { set i [expr {min([llength $keys] - 1, $i + 1)}] }
		space { set i [expr {($i + 1) % [llength $keys]}] }
		default { return 0 }
	}
	uplevel #0 [list {*}$script [lindex $keys $i]]
	return 1
}

# ---- a draw ------------------------------------------------------------------------

# Start a draw: a fresh photo with the window's frame (drawn by SCRIPT once
# per KEY) and its corners showing what is behind it.
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
	variable drawno
	incr drawno
	$cv delete page
	variable base
	foreach i [list $base $img2] { if {$i ne ""} { image delete $i } }
	set img2 ""
	variable frames
	set img [set base [image create photo -width $W -height $H]]
	set fk [list $key [col $c(bar)] [array get c]]
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
	if {$argbwin ne ""} { rbn::appframe $argbwin $frames($fk) 16 }
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
	mem_trim
}

# The scene's desktop: wallpaper, a 25% shade, the bars at 55% and the
# window's shadow (0 30px 80px rgba(0,0,0,0.55)), as the installer's scene.
proc ui::desktop {W H} {
	array set c [array get ui::c]
	set key [list 3 [array get theme::c] $W $H]
	set f [raster::keyed_path [raster::dir] desk- $key]
	if {[raster::keyed $f $key]} { return [image create photo -file $f -format png] }
	set rows [wall::rows [array get theme::c] 0 0 $W $H $W $H]
	set k [expr {1.0 / (80 / 2.0 * sqrt(2.0))}]
	set fx {}; set fy {}
	for {set x 0} {$x < $W} {incr x} { lappend fx [expr {0.5 * ([raster::erf [expr {($x + 0.5 - 170) * $k}]] - [raster::erf [expr {($x + 0.5 - 1270) * $k}]])}] }
	for {set y 0} {$y < $H} {incr y} { lappend fy [expr {0.5 * ([raster::erf [expr {($y + 0.5 - 30 - 104) * $k}]] - [raster::erf [expr {($y + 0.5 - 30 - 824) * $k}]])}] }
	set out {}
	for {set y 0} {$y < $H} {incr y} {
		set sy [expr {0.55 * [lindex $fy $y]}]
		set new {}
		foreach {r g b a} [lindex $rows $y] s0 $fx {
			set m [expr {0.75 * (1 - $sy * $s0)}]
			lappend new [expr {int($r * $m + 0.5)}] [expr {int($g * $m + 0.5)}] [expr {int($b * $m + 0.5)}] 255
		}
		lappend out $new
	}
	set P [image create photo -data [raster::png $W $H $out] -format png]
	set Q [image create photo -width $W -height 70]
	$Q copy $P -from 0 0 $W 70 -to 0 0
	foreach {x w} [list 8 330 [expr {$W - 308}] 300] {
		lassign [raster::rrect $w 38 -fill $c(bar) -radius 12 -ring [list $c(border) 1] -shadow {6 20 0.35}] img padx pady
		raster::blit $Q $img 0 0 [image width $img] [image height $img] [expr {$x - $padx}] [expr {8 - $pady}]
	}
	raster::box $Q 12 12 86 30 -fill $c(pill) -radius 8
	raster::box $Q 102 12 232 30 -fill $c(field) -radius 8
	for {set y 0} {$y < 70} {incr y} {
		foreach {x0 x1} [list 0 370 [expr {$W - 340}] $W] {
			set row {}
			for {set x $x0} {$x < $x1} {incr x} {
				lassign [$P get $x $y] r1 g1 b1; lassign [$Q get $x $y] r2 g2 b2
				lappend row [format #%02x%02x%02x [expr {round($r1 + ($r2 - $r1) * 0.55)}] [expr {round($g1 + ($g2 - $g1) * 0.55)}] [expr {round($b1 + ($b2 - $b1) * 0.55)}]]
			}
			$P put [list $row] -to $x0 $y
		}
	}
	image delete $Q
	$P write $f.[pid] -format png
	file rename -force $f.[pid] $f
	raster::store_key $f $key
	return $P
}

# The shell's raster::cached looks its photo up in [image names] on every
# call; the app redraws per key press, so it remembers them.
namespace eval raster { variable memo; array set memo {} }
if {[info commands raster::cached_disk] eq ""} { rename raster::cached raster::cached_disk }
proc raster::cached {key script} {
	variable memo
	if {[info exists memo($key)]} { return $memo($key) }
	set memo($key) [uplevel 1 [list raster::cached_disk $key $script]]
}
