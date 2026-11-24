# look.tcl - Ribbon's procedural wallpapers ("designs", files *.look), drawn
# in pure Tcl at an output's exact pixel size and scale, any aspect ratio.
#
#   ribbon-wall --tcl look.tcl DESIGN.look PALETTE.conf WIDTH HEIGHT SCALE OUT.png
#   (or tclsh look.tcl ...)
#
# ribbon-wall runs it on a cache miss (a new design, palette, output size or
# scale) and shows the PNG 1:1. A design is a small declarative file (see
# looks/ribbon.look and render below): read as data, every value checked,
# never evaluated, so a design from anywhere can't run anything. Lengths are
# CSS px times the scale, or relative to the screen (vw, vh, vmin, vmax,
# clamp()); marks are anchored inside a safe area (clear of the bars) and
# shrink to fit it, so one file serves ultrawide, portrait, tiny and 8K
# screens alike. Colours are palette keys, so designs follow the theme.
#
# Speed: nothing here loops over pixels except a mark's anti-aliased edges.
# Each row is a list of runs {length r g b}; layers split and blend runs; a
# row becomes bytes through [string repeat] and Tcl's zlib (C).
# Layers:
#   stripes {angle A period LEN width LEN offset LEN colour KEY alpha KEY|N}
#       repeating bands like CSS repeating-linear-gradient(Adeg, ...):
#       band n covers O + nP .. O + nP + W along the gradient line;
#       edges anti-aliased analytically (box filter across the edge)
#   mark {glyphs FILE size LEN colour KEY alpha KEY [fit F] [anchor A]
#         [margin LEN] [dx LEN] [dy LEN]}
#       glyph outlines (glyphs.py, data), at most F of the safe area's width
#       and height; anchor centre (as CSS centres the wordmark) or n s e w
#       ne nw se sw; nonzero fill, 4 sub-scanlines, exact horizontal coverage
#   disc {cx FRAC cy FRAC r LEN colour KEY alpha KEY}
#       a circle (centre as a fraction of the screen), anti-aliased

namespace eval look {}

proc look::rgb {hex} { scan [string range $hex 1 end] %2x%2x%2x r g b; list $r $g $b }

# A palette key's value, or a number as is.
proc look::val {pal v} { expr {[dict exists $pal $v] ? [dict get $pal $v] : $v} }

# ---- runs ------------------------------------------------------------------

# Blend colour (r g b) at alpha a over the runs where coverage runs
# {x0 x1 cov ...} (sorted, disjoint) say so.
proc look::blend {runs cov r g b a} {
	set out {}
	set x 0
	set ci 0; set nc [llength $cov]
	lassign [lrange $cov 0 2] c0 c1 cc
	foreach {len rr gg bb} $runs {
		set end [expr {$x + $len}]
		while {$x < $end} {
			if {$ci >= $nc || $c0 >= $end} {          ;# no coverage in the rest of this run
				lappend out [expr {$end - $x}] $rr $gg $bb; set x $end; break
			}
			if {$x < $c0} {                          ;# uncovered part before the next segment
				lappend out [expr {$c0 - $x}] $rr $gg $bb; set x $c0; continue
			}
			set e [expr {min($end, $c1)}]            ;# covered part
			set k [expr {$a * $cc}]
			lappend out [expr {$e - $x}] [expr {$rr + ($r - $rr) * $k}] [expr {$gg + ($g - $gg) * $k}] [expr {$bb + ($b - $bb) * $k}]
			set x $e
			if {$x >= $c1} {
				incr ci 3
				if {$ci < $nc} { lassign [lrange $cov $ci [expr {$ci + 2}]] c0 c1 cc }
			}
		}
	}
	return $out
}

# Runs -> RGB bytes.
proc look::bytes {runs} {
	set s ""
	foreach {len r g b} $runs {
		append s [string repeat [binary format cucucu [expr {round($r)}] [expr {round($g)}] [expr {round($b)}]] $len]
	}
	return $s
}

# ---- stripes: analytic coverage per row --------------------------------------

proc look::stripes_setup {W H S angle period width offset} {
	set t [expr {$angle * acos(-1) / 180.0}]
	set dx [expr {sin($t)}]; set dy [expr {-cos($t)}]
	set L [expr {$W * abs($dx) + $H * abs($dy)}]
	# p(x, y) = (x - W/2) dx + (y - H/2) dy + L/2, at pixel centres
	set c0 [expr {-$W / 2.0 * $dx - $H / 2.0 * $dy + $L / 2.0}]
	set P [expr {$period * $S}]; set Wd [expr {$width * $S}]; set O [expr {$offset * $S}]
	# the box filter: a pixel's footprint across the bands
	set h [expr {(abs($dx) + abs($dy)) / 2.0}]
	list $dx $dy $c0 $P $Wd $O $h
}

proc look::stripes_row {st y W} {
	lassign $st dx dy c0 P Wd O h
	set crow [expr {($y + 0.5) * $dy + $c0}]
	set out {}
	if {abs($dx) < 1e-9} {                          ;# horizontal bands: one value per row
		set p $crow
		set n [expr {floor(($p - $O) / $P)}]
		set a [expr {$O + $n * $P}]; set b [expr {$a + $Wd}]
		set c [expr {max(0.0, min($p + $h, $b) - max($p - $h, $a)) / (2 * $h)}]
		if {$c > 0} { lappend out 0 $W $c }
		return $out
	}
	# pc(x) = dx (x + 0.5) + crow; walk the bands crossing this row in x order
	set p0 [expr {$dx * 0.5 + $crow}]; set p1 [expr {$dx * ($W - 0.5) + $crow}]
	set lo [expr {min($p0, $p1) - $h}]; set hi [expr {max($p0, $p1) + $h}]
	set n0 [expr {int(floor(($lo - $O - $Wd) / $P))}]; set n1 [expr {int(ceil(($hi - $O) / $P))}]
	set bands {}
	for {set n $n0} {$n <= $n1} {incr n} {
		set a [expr {$O + $n * $P}]; set b [expr {$a + $Wd}]
		# x where pc = v: (v - crow) / dx - 0.5
		set xa [expr {($a - $crow) / $dx - 0.5}]; set xb [expr {($b - $crow) / $dx - 0.5}]
		lappend bands [list [expr {min($xa, $xb)}] $a $b]
	}
	if {$dx < 0} { set bands [lsort -real -index 0 $bands] }
	set ex [expr {$h / abs($dx)}]                    ;# edge width in pixels
	set last 0
	foreach band $bands {
		lassign $band - a b
		set xa [expr {($a - $crow) / $dx - 0.5}]; set xb [expr {($b - $crow) / $dx - 0.5}]
		if {$xa > $xb} { lassign [list $xb $xa] xa xb }
		set xs [expr {max($last, int(ceil($xa - $ex)))}]; set xe [expr {min($W, int(floor($xb + $ex)) + 1)}]
		if {$xs >= $xe} continue
		# full: the whole footprint inside the band
		set fs [expr {max($xs, int(ceil($xa + $ex)))}]; set fe [expr {min($xe, int(floor($xb - $ex)) + 1)}]
		if {$fs >= $fe} { set fs $xe; set fe $xe }
		for {set x $xs} {$x < $fs} {incr x} {
			set pc [expr {$dx * ($x + 0.5) + $crow}]
			set c [expr {max(0.0, min($pc + $h, $b) - max($pc - $h, $a)) / (2 * $h)}]
			if {$c > 0} { lappend out $x [expr {$x + 1}] $c }
		}
		if {$fe > $fs} { lappend out $fs $fe 1.0 }
		for {set x [expr {max($fe, $fs)}]} {$x < $xe} {incr x} {
			set pc [expr {$dx * ($x + 0.5) + $crow}]
			set c [expr {max(0.0, min($pc + $h, $b) - max($pc - $h, $a)) / (2 * $h)}]
			if {$c > 0} { lappend out $x [expr {$x + 1}] $c }
		}
		set last $xe
	}
	return $out
}

# ---- polygons: nonzero fill with 4 sub-scanlines ------------------------------

# Flatten "M x y L x y Q cx cy x y" contours (transformed by scale s and
# offset ox oy) into edges {x0 y0 x1 y1 dir}; returns {edges ymin ymax}.
proc look::edges {contours s ox oy} {
	set edges {}
	set ymin 1e9; set ymax -1e9
	set nq [expr {max(3, int($s / 40))}]
	foreach c $contours {
		set pts {}
		set i 0; set n [llength $c]
		while {$i < $n} {
			switch -- [lindex $c $i] {
				M - L { lappend pts [expr {[lindex $c $i+1] * $s + $ox}] [expr {[lindex $c $i+2] * $s + $oy}]; incr i 3 }
				Q {
					lassign [lrange $pts end-1 end] x0 y0
					set cx [expr {[lindex $c $i+1] * $s + $ox}]; set cy [expr {[lindex $c $i+2] * $s + $oy}]
					set x1 [expr {[lindex $c $i+3] * $s + $ox}]; set y1 [expr {[lindex $c $i+4] * $s + $oy}]
					for {set k 1} {$k <= $nq} {incr k} {
						set t [expr {double($k) / $nq}]; set u [expr {1 - $t}]
						lappend pts [expr {$u*$u*$x0 + 2*$u*$t*$cx + $t*$t*$x1}] [expr {$u*$u*$y0 + 2*$u*$t*$cy + $t*$t*$y1}]
					}
					incr i 5
				}
				default { incr i }
			}
		}
		lappend pts {*}[lrange $pts 0 1]
		foreach {ax ay} [lrange $pts 0 end-2] {bx by} [lrange $pts 2 end] {
			if {$bx eq "" || $ay == $by} continue
			set ymin [expr {min($ymin, $ay, $by)}]; set ymax [expr {max($ymax, $ay, $by)}]
			if {$ay < $by} { lappend edges [list $ax $ay $bx $by 1] } else { lappend edges [list $bx $by $ax $ay -1] }
		}
	}
	list [lsort -real -index 1 $edges] $ymin $ymax
}

# Coverage runs {x0 x1 cov} of the polygon on pixel row y.
proc look::poly_row {edges y W} {
	array set part {}
	array set diff {}
	foreach sub {0.125 0.375 0.625 0.875} {
		set yc [expr {$y + $sub}]
		set xs {}
		foreach e $edges {
			lassign $e ax ay bx by d
			if {$ay > $yc} break
			if {$yc < $by} { lappend xs [list [expr {$ax + ($yc - $ay) * ($bx - $ax) / ($by - $ay)}] $d] }
		}
		set w 0
		foreach xd [lsort -real -index 0 $xs] {
			lassign $xd x d
			if {$w == 0} { set a $x }
			incr w $d
			if {$w == 0} {                            ;# span a .. x, a quarter row high
				set a [expr {max(0.0, $a)}]; set b [expr {min(double($W), $x)}]
				if {$b <= $a} continue
				set ia [expr {int($a)}]; set ib [expr {int($b)}]
				if {$ia == $ib} { set part($ia) [expr {([info exists part($ia)] ? $part($ia) : 0) + ($b - $a) * 0.25}]; continue }
				set part($ia) [expr {([info exists part($ia)] ? $part($ia) : 0) + ($ia + 1 - $a) * 0.25}]
				if {$ib > $ia + 1} {
					set k [expr {$ia + 1}]
					set diff($k) [expr {([info exists diff($k)] ? $diff($k) : 0) + 0.25}]
					set diff($ib) [expr {([info exists diff($ib)] ? $diff($ib) : 0) - 0.25}]
				}
				if {$b > $ib} { set part($ib) [expr {([info exists part($ib)] ? $part($ib) : 0) + ($b - $ib) * 0.25}] }
			}
		}
	}
	# sweep: constant coverage between event points, single pixels at partials
	set keys [lsort -integer -unique [concat [array names part] [array names diff]]]
	set out {}
	set run 0.0
	set prev ""
	foreach k $keys {
		if {$prev ne "" && $run > 1e-6 && $k > $prev} { lappend out $prev $k [expr {min(1.0, $run)}] }
		if {[info exists diff($k)]} { set run [expr {$run + $diff($k)}] }
		if {[info exists part($k)]} {
			set c [expr {min(1.0, $run + $part($k))}]
			if {$c > 1e-6} { lappend out $k [expr {$k + 1}] $c }
			set prev [expr {$k + 1}]
		} else { set prev $k }
	}
	# merge the single pixels that overlap a following constant run start
	set m {}
	foreach {a b c} $out {
		if {[llength $m] && [lindex $m end-1] > $a} continue
		lappend m $a $b $c
	}
	return $m
}

# ---- reading a design: data only ---------------------------------------------------

# A file as a dict, never evaluated: comment lines dropped, then parsed as a
# Tcl list. Anything that isn't a well-formed dict is refused.
proc look::data {f} {
	set fh [open $f]; set text [read $fh]; close $fh
	set keep {}
	foreach line [split $text \n] { if {![regexp {^\s*#} $line]} { lappend keep $line } }
	set d [join $keep \n]
	if {![string is list $d] || [llength $d] % 2} { error "$f: not a design file (KEY VALUE pairs)" }
	return $d
}

proc look::num {v what} {
	if {![string is double -strict $v]} { error "$what: not a number: $v" }
	return $v
}

# A length in device pixels. LEN is CSS px (times the output's scale), or
# {N vw|vh|vmin|vmax} (percent of the screen's logical width, height, smaller
# or larger side), or {clamp MIN PREFERRED MAX} of those (as CSS clamp()).
proc look::len {v} {
	variable L
	if {[llength $v] == 1} { return [expr {[num $v length] * $L(S)}] }
	if {[lindex $v 0] eq "clamp" && [llength $v] == 4} {
		lassign [lrange $v 1 end] a b c
		return [expr {min([len $c], max([len $a], [len $b]))}]
	}
	if {[llength $v] == 2} {
		lassign $v n u
		set n [num $n length]
		switch -- $u {
			px { return [expr {$n * $L(S)}] }
			vw { return [expr {$n / 100.0 * $L(W)}] }
			vh { return [expr {$n / 100.0 * $L(H)}] }
			vmin { return [expr {$n / 100.0 * min($L(W), $L(H))}] }
			vmax { return [expr {$n / 100.0 * max($L(W), $L(H))}] }
		}
	}
	error "not a length: $v"
}

# A colour: a palette key or #RRGGBB.
proc look::colour {pal v} {
	if {[dict exists $pal $v]} { set v [dict get $pal $v] }
	if {![regexp {^#[0-9A-Fa-f]{6}$} $v]} { error "not a colour: $v" }
	rgb $v
}
proc look::alpha {pal v} {
	if {[dict exists $pal $v]} { set v [dict get $pal $v] }
	set v [num $v alpha]
	expr {min(1.0, max(0.0, $v))}
}

# Where a W x H box goes inside the safe area for ANCHOR (centre, n, s, e,
# w, ne, nw, se, sw), MARGIN in from its edges.
proc look::anchor {a w h margin} {
	variable L
	lassign $L(safe) sx0 sy0 sx1 sy1
	set cx [expr {($sx0 + $sx1 - $w) / 2.0}]; set cy [expr {($sy0 + $sy1 - $h) / 2.0}]
	set x [expr {[string match *w $a] ? $sx0 + $margin : [string match *e $a] ? $sx1 - $margin - $w : $cx}]
	set y [expr {[string match n* $a] ? $sy0 + $margin : [string match s* $a] ? $sy1 - $margin - $h : $cy}]
	list $x $y
}

# ---- render ------------------------------------------------------------------
#
# A design ("look") file:
#   name NAME
#   safe {top LEN bottom LEN left LEN right LEN}   kept clear for marks (the bars)
#   gradient {TOPKEY BOTTOMKEY}                    vertical, palette keys or #hex
#   layers {KIND {OPTION VALUE ...} ...}
# Lengths: see look::len. Every value is checked; a design is data and can't
# run anything. At most 32 layers.

proc look::render {lookf palf W H S out} {
	variable L
	set W [expr {int([num $W width])}]; set H [expr {int([num $H height])}]; set S [num $S scale]
	if {$W < 1 || $H < 1 || $W > 32768 || $H > 32768 || $S <= 0 || $S > 8} { error "bad size ${W}x$H@$S" }
	array set L [list W [expr {$W / $S}] H [expr {$H / $S}] S $S]
	set pal {DESK_TOP #2B2825 DESK_BOTTOM #121110 DESK_STRIPE #FFFFFF DESK_STRIPE_ALPHA 0.03 DESK_MARK #FFFFFF DESK_MARK_ALPHA 0.065}
	if {![catch {open $palf} fh]} {
		foreach line [split [read $fh] \n] {
			if {[regexp {^\s*([A-Z_0-9]+)=(.*)$} $line -> k v]} { dict set pal $k [string trim [string trim $v] \"'] }
		}
		close $fh
	}
	set spec [data $lookf]
	# the safe area, in device pixels
	set safe {top 0 bottom 0 left 0 right 0}
	if {[dict exists $spec safe]} { set safe [dict merge $safe [dict get $spec safe]] }
	set L(safe) [list [len [dict get $safe left]] [len [dict get $safe top]] \
		[expr {$W - [len [dict get $safe right]]}] [expr {$H - [len [dict get $safe bottom]]}]]
	lassign [colour $pal [lindex [dict get $spec gradient] 0]] tr tg tb
	lassign [colour $pal [lindex [dict get $spec gradient] 1]] br bg bb
	set layers {}
	set specl [dict get $spec layers]
	if {[llength $specl] % 2 || [llength $specl] > 64} { error "layers: KIND {OPTIONS} pairs, at most 32" }
	foreach {kind args} $specl {
		if {[llength $args] % 2} { error "$kind: options must be KEY VALUE pairs" }
		set o [dict merge {alpha 1 dx 0 dy 0 anchor centre margin 0 fit 1 colour #FFFFFF} $args]
		lassign [colour $pal [dict get $o colour]] r g b
		set a [alpha $pal [dict get $o alpha]]
		switch -- $kind {
			stripes {
				lappend layers [list stripes [stripes_setup $W $H 1.0 [num [dict get $o angle] angle] \
					[len [dict get $o period]] [len [dict get $o width]] [len [dict get $o offset]]] $r $g $b $a]
			}
			mark {
				set gf [file join [file dirname $lookf] [file tail [dict get $o glyphs]]]
				set gd [data $gf]
				set adv [num [dict get $gd advance] advance]
				set contours [dict get $gd contours]
				if {[llength $contours] > 512} { error "$gf: too many contours" }
				# the outline's box in em units
				set ex0 1e9; set ey0 1e9; set ex1 -1e9; set ey1 -1e9
				foreach c $contours {
					foreach {x y} [regexp -all -inline {[-0-9.]+} $c] {
						set ex0 [expr {min($ex0, $x)}]; set ex1 [expr {max($ex1, $x)}]
						set ey0 [expr {min($ey0, $y)}]; set ey1 [expr {max($ey1, $y)}]
					}
				}
				# its size, shrunk to fit FIT of the safe area (tiny or portrait screens)
				set size [len [dict get $o size]]
				lassign $L(safe) sx0 sy0 sx1 sy1
				set fit [num [dict get $o fit] fit]
				set k [expr {min(1.0, $fit * ($sx1 - $sx0) / ($adv * $size), $fit * ($sy1 - $sy0) / (($ey1 - $ey0) * $size))}]
				set size [expr {$size * $k}]
				set dx [len [dict get $o dx]]; set dy [len [dict get $o dy]]
				if {[dict get $o anchor] eq "centre"} {
					# centred as CSS centres the 148 px wordmark: the advance
					# (trailing letter-spacing included) across, the line box
					# (ascent 984, descent 292 per 1000) on the middle
					set ox [expr {($sx0 + $sx1) / 2.0 - $adv * $size / 2.0 + $dx}]
					set oy [expr {($sy0 + $sy1) / 2.0 + (-78 + (148 - 148 * 1.276) / 2.0 + 148 * 0.984) * $size / 148.0 + $dy}]
				} else {
					lassign [anchor [dict get $o anchor] [expr {($ex1 - $ex0) * $size}] [expr {($ey1 - $ey0) * $size}] [len [dict get $o margin]]] bx by
					set ox [expr {$bx - $ex0 * $size + $dx}]; set oy [expr {$by - $ey0 * $size + $dy}]
				}
				puts [format "layout mark %.1f %.1f %.1f %.1f size %.2f" [expr {$ox + $ex0 * $size}] [expr {$oy + $ey0 * $size}] \
					[expr {$ox + $ex1 * $size}] [expr {$oy + $ey1 * $size}] $size]
				lassign [edges $contours $size $ox $oy] ed y0 y1
				lappend layers [list poly [list $ed [expr {int(floor($y0))}] [expr {int(ceil($y1))}]] $r $g $b $a]
			}
			disc {
				set rr [len [dict get $o r]]
				set cx [expr {[num [dict get $o cx] cx] * $W}]; set cy [expr {[num [dict get $o cy] cy] * $H}]
				set n [expr {max(32, min(4096, int($rr)))}]
				set c "M [expr {$cx + $rr}] $cy"
				for {set i 1} {$i < $n} {incr i} { append c " L [expr {$cx + $rr * cos(2 * acos(-1) * $i / $n)}] [expr {$cy + $rr * sin(2 * acos(-1) * $i / $n)}]" }
				lassign [edges [list $c] 1 0 0] ed y0 y1
				lappend layers [list poly [list $ed [expr {int(floor($y0))}] [expr {int(ceil($y1))}]] $r $g $b $a]
			}
			default { error "unknown layer kind: $kind" }
		}
	}
	set z [zlib stream compress -level 6]
	for {set y 0} {$y < $H} {incr y} {
		set t [expr {($y + 0.5) / $H}]
		set runs [list $W [expr {$tr + ($br - $tr) * $t}] [expr {$tg + ($bg - $tg) * $t}] [expr {$tb + ($bb - $tb) * $t}]]
		foreach l $layers {
			lassign $l kind st r g b a
			if {$kind eq "stripes"} {
				set cov [stripes_row $st $y $W]
			} else {
				lassign $st ed y0 y1
				if {$y < $y0 || $y > $y1} continue
				set cov [poly_row $ed $y $W]
			}
			if {[llength $cov]} { set runs [blend $runs $cov $r $g $b $a] }
		}
		$z put "\x00[bytes $runs]"
	}
	$z finalize
	set data [$z get]; $z close
	set png "\x89PNG\r\n\x1a\n"
	foreach {type d} [list IHDR [binary format IIccccc $W $H 8 2 0 0 0] IDAT $data IEND ""] {
		append png [binary format I [string length $d]] $type $d [binary format I [zlib crc32 $type$d]]
	}
	file mkdir [file dirname $out]
	set tmp $out.[pid]
	set fh [open $tmp wb]; puts -nonewline $fh $png; close $fh
	file rename -force $tmp $out
}

if {[info exists argv0] && [file tail $argv0] eq "look.tcl"} {
	lassign $argv lookf palf W H S out
	look::render $lookf $palf $W $H $S $out
}
