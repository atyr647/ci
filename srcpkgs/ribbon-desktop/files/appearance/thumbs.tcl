# thumbs.tcl - the miniature desktop and login screen the pages show, in
# a palette being looked at or edited. As the mockups draw them: the
# wallpaper (the theme's gradient and stripes, CSS-size: the stripes are
# not scaled down), the bars, dock and a window at 1/6.9 of a 1440 px
# screen, and the login clock, avatar and field.

namespace eval thumbs {}

# The mockups' miniature desktop, for a thumbnail W px wide: {x y w h r
# colour-key ?outer-ring?}, each to a tenth of a pixel as the boards
# round them.
proc thumbs::desk_parts {w} {
	set s [expr {$w / 1440.0}]
	set out {}
	foreach {x y bw bh r col} {
		8 8 360 38 12 bar   12 12 90 30 8 pill   106 12 258 30 8 field
		1052 8 380 38 12 bar   1172 12 44 30 8 pill
		560 856 320 38 12 bar   564 860 74 30 8 field   572 890 58 2.4 8 accent
		470 260 500 300 12 win   470 260 500 34 12 field
	} {
		set v {}
		foreach n [list $x $y $bw $bh] { lappend v [expr {round($n * $s * 10) / 10.0}] }
		lappend v [expr {max(2.0, round($r * $s * 10) / 10.0)}] $col
		lappend out $v
	}
	return $out
}

# The login miniature's sizes: clock px and top, avatar size and top,
# field w h r and top (the boards' own numbers).
proc thumbs::login_parts {w h} {
	switch -- ${w}x$h {
		200x188 { return {17 21 13 60 47 6 2 79} }
		190x119 { return {16 20 13 57 45 6 2 75} }
		440x275 { return {37 46 29 131 104 14 4 174} }
	}
	set s [expr {$w / 1440.0}]
	list [expr {round(120 * $s)}] [expr {round(150 * $s)}] [expr {round(96 * $s)}] [expr {round(420 * $s)}] \
		[expr {round(340 * $s)}] [expr {round(46 * $s)}] [expr {max(2, round(12 * $s))}] [expr {round(570 * $s)}]
}

# The background of a thumbnail: the theme's wallpaper at W x H.
proc thumbs::wall {p w h} {
	ui::mem [list wall [dict get $p DESK_TOP] [dict get $p DESK_BOTTOM] [dict get $p DESK_STRIPE] [dict get $p DESK_STRIPE_ALPHA] $w $h] {
		raster::png $w $h [wall::rows $p 0 0 $w $h $w $h]
	}
}

# Draw a thumbnail of KIND (desk | login) in palette P at x y, W x H, on
# a page of colour PAGEBG. BG: {pattern} | {photo IMG} (a picture already
# at W x H). Returns nothing; the login clock is text, drawn by
# thumbs::clock after.
proc thumbs::draw {kind p x y w h pagebg {bg pattern}} {
	set x [expr {round($x)}]; set y [expr {round($y)}]
	set key [list thumb $kind $p $w $h [ui::col $pagebg] $bg]
	set t [ui::mem $key {
		set keep $ui::img
		set ui::img [image create photo -width $w -height $h]
		if {[lindex $bg 0] eq "photo"} {
			$ui::img copy [lindex $bg 1]
		} else {
			$ui::img copy [thumbs::wall $p $w $h]
		}
		ui::ring 0 0 $w $h 10 [dict get $p BORDER] 1
		if {$kind eq "desk"} {
			foreach part [desk_parts $w] {
				lassign $part px py pw ph r col
				set colour [dict get $p [dict get {bar BAR pill PILL field FIELD accent ACCENT win BAR} $col]]
				if {$col eq "win"} {
					# box-shadow: 0 0 0 1px border, outside the window
					ui::fbox [expr {$px - 1}] [expr {$py - 1}] [expr {$pw + 2}] [expr {$ph + 2}] -fill [dict get $p BORDER] -radius [expr {$r + 1}] -snap 1
				}
				ui::fbox $px $py $pw $ph -fill $colour -radius $r -snap 1
			}
		} else {
			lassign [login_parts $w $h] - - av avy fw fh fr fy
			ui::fbox [expr {($w - $av) / 2.0}] $avy $av $av -fill [dict get $p ACCENT] -radius [expr {$av / 2.0}] -grad 0.35
			ui::fbox [expr {($w - $fw) / 2.0}] $fy $fw $fh -fill [dict get $p FIELD] -radius $fr -ring [list [dict get $p ACCENT] 1]
		}
		ui::corners 0 0 $w $h 10 $pagebg
		set out [$ui::img data -format png]
		image delete $ui::img
		set ui::img $keep
		set out
	}]
	raster::blit $ui::img $t 0 0 $w $h $x $y
}

# The login miniature's clock: "HH:MM", the colon in the accent.
proc thumbs::clock {p x y w h time} {
	lassign [login_parts $w $h] px top
	set f [dict get {16 sg16 17 sg17 32 sg32 37 sg37} $px]
	# line-height 0.9: the content area overhangs the line box
	set ctop [ui::lh [expr {$y + $top}] $f [expr {0.9 * $px}] 1]
	set ls [expr {-0.05 * $px}]
	set xs [ui::layout $f $time $ls]
	# centred as CSS centres it, the last letter-spacing included
	set x0 [expr {$x + ($w - [lindex $xs end]) / 2.0}]
	foreach ch [split $time ""] cx [lrange $xs 0 end-1] {
		ui::text [expr {$x0 + $cx}] $ctop $ch $f [expr {$ch eq ":" ? [dict get $p ACCENT] : [dict get $p FG]}]
	}
}
