# raster.tcl - anti-aliased drawing for the Ribbon shell, in pure Tcl.
#
# Tk 8.6 draws aliased shapes and has no alpha in [image put], so the shell
# rasterises its rounded shapes, shadows and line icons here, encodes them
# as PNG (zlib + crc32 are built into Tcl) and loads them as photos. Results
# are cached on disk, keyed by every parameter, so this only runs the first
# time a colour scheme is used; after that the shell just loads PNGs. With
# the rbnalpha extension loaded, rounded boxes, rings and shadows are drawn
# by its C copy of this code (rbnalpha::rrect: the same pixels).

namespace eval raster {
	variable cachedir ""
	variable keys {}   ;# image name -> the full key it was made for
}

proc raster::init {dir} {
	variable cachedir $dir
	file mkdir $dir
}
# The cache directory: what init set, else $XDG_CACHE_HOME/ribbon/raster (made on first use). Never "", which
# would put the cache files in whatever directory the program was started from.
proc raster::dir {} {
	variable cachedir
	if {$cachedir eq ""} {
		set c [expr {[info exists ::env(XDG_CACHE_HOME)] && $::env(XDG_CACHE_HOME) ne "" ? $::env(XDG_CACHE_HOME) : [file join [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}] .cache]}]
		set cachedir [file join $c ribbon raster]
		catch {file mkdir $cachedir}
	}
	return $cachedir
}

# rgb "#rrggbb" -> {r g b}
proc raster::rgb {hex} {
	scan [string range $hex 1 end] %2x%2x%2x r g b
	list $r $g $b
}

# Encode RGBA rows (list of rows, each a flat list r g b a ...) as PNG bytes.
proc raster::png {w h rows} {
	set raw ""
	foreach row $rows {
		append raw \x00 [binary format c* $row]
	}
	set out "\x89PNG\r\n\x1a\n"
	foreach {type data} [list IHDR [binary format IIccccc $w $h 8 6 0 0 0] \
			IDAT [zlib compress $raw 9] IEND ""] {
		append out [binary format I [string length $data]] $type $data \
			[binary format I [zlib crc32 $type$data]]
	}
	return $out
}

# Cache keys are CRC32s (names and file names; fast), so two keys can share one.
# The full key is kept beside each entry: in memory, in raster::keys, and on disk,
# in a sidecar FILE.png.key. An entry is used only when its key matches; a mismatch
# is a miss, and the entry is rebuilt. Two keys with one CRC get two image names
# (IMG, IMG.1, ...) in memory and take turns at the disk file.

# The image name for KEY (CRC): the first one free, or one already made for KEY.
# PREFIX is the name's start (other modules name their photos their own way). KEY is
# recorded for the name, so a later key with the same CRC takes the next one.
proc raster::name {crc key {prefix ::raster::img}} {
	variable keys
	for {set n 0} {1} {incr n} {
		set name $prefix$crc
		if {$n} { append name .$n }
		if {![dict exists $keys $name] || [dict get $keys $name] eq $key} {
			dict set keys $name $key
			return $name
		}
	}
}

# The disk file for KEY in DIR: PREFIX, the CRC32 of KEY, .png. Its full key sits beside
# it (raster::store_key); check it with raster::keyed before using the file.
proc raster::keyed_path {dir prefix key} {
	file join $dir $prefix[format %08x [zlib crc32 $key]].png
}

# Write DATA (PNG bytes) as the disk entry F for KEY: atomically, then the key beside it.
proc raster::write_keyed {f key data} {
	set tmp $f.[pid]
	set fh [open $tmp wb]; puts -nonewline $fh $data; close $fh
	file rename -force $tmp $f
	store_key $f $key
}

# The key stored beside F ("" when there is none): for a derived file, its base's key.
proc raster::key_of {f} {
	if {![file exists $f.key]} { return "" }
	set fh [open $f.key rb]; set got [read $fh]; close $fh
	return $got
}

# Does the disk entry F hold KEY? Its sidecar must be there and say the same.
proc raster::keyed {f key} {
	if {![file exists $f] || ![file exists $f.key]} { return 0 }
	if {[catch {set fh [open $f.key rb]; set got [read $fh]; close $fh}]} { return 0 }
	expr {$got eq [encoding convertto utf-8 $key]}
}

# Write KEY beside F (after F itself is in place, so a crash leaves a mismatch).
proc raster::store_key {f key} {
	set tmp $f.key.[pid]
	set fh [open $tmp wb]; puts -nonewline $fh [encoding convertto utf-8 $key]; close $fh
	file rename -force $tmp $f.key
}

# Return a photo for KEY, building it with SCRIPT (which returns PNG bytes)
# only when it isn't in the disk cache yet.
proc raster::cached {key script} {
	variable cachedir
	variable keys
	set crc [format %08x [zlib crc32 $key]]
	set name [name $crc $key]
	if {[dict exists $keys $name] && $name in [image names]} { return $name }
	set f [file join [dir] $crc.png]
	if {![keyed $f $key]} {
		set data [uplevel 1 $script]
		set tmp $f.[pid]
		set fh [open $tmp wb]; puts -nonewline $fh $data; close $fh
		file rename -force $tmp $f
		store_key $f $key
	}
	image create photo $name -file $f -format png
	return $name
}

# The same for a picture made in C by CMD (%P: the photo).
proc raster::cached_c {key cmd} {
	variable cachedir
	variable keys
	set crc [format %08x [zlib crc32 $key]]
	set name [name $crc $key]
	if {[dict exists $keys $name] && $name in [image names]} { return $name }
	set f [file join [dir] $crc.png]
	if {[keyed $f $key] && ![catch {image create photo $name -file $f -format png}]} {
		return $name
	}
	image create photo $name
	{*}[string map [list %P $name] $cmd]
	if {![catch {$name write $f.[pid] -format png; file rename -force $f.[pid] $f}]} { store_key $f $key }
	return $name
}

# erf, Abramowitz & Stegun 7.1.26 (|error| < 1.5e-7)
proc raster::erf {x} {
	set s [expr {$x < 0 ? -1.0 : 1.0}]
	set x [expr {abs($x)}]
	set t [expr {1.0 / (1.0 + 0.3275911 * $x)}]
	set y [expr {1.0 - ((((1.061405429*$t - 1.453152027)*$t + 1.421413741)*$t \
		- 0.284496736)*$t + 0.254829592)*$t*exp(-$x*$x)}]
	expr {$s * $y}
}

# Coverage of a rounded box (x0 y0 x1 y1, radius r) at pixel centre px py.
# r is one radius, or four: top-left top-right bottom-right bottom-left.
proc raster::rbox {px py x0 y0 x1 y1 r} {
	set cx [expr {($x0 + $x1) / 2.0}]; set cy [expr {($y0 + $y1) / 2.0}]
	if {[llength $r] == 4} {
		set r [lindex $r [expr {$py < $cy ? ($px < $cx ? 0 : 1) : ($px < $cx ? 3 : 2)}]]
	}
	set qx [expr {abs($px - $cx) - (($x1 - $x0) / 2.0 - $r)}]
	set qy [expr {abs($py - $cy) - (($y1 - $y0) / 2.0 - $r)}]
	set ox [expr {max($qx, 0.0)}]; set oy [expr {max($qy, 0.0)}]
	set d [expr {hypot($ox, $oy) + min(max($qx, $qy), 0.0) - $r}]
	expr {min(1.0, max(0.0, 0.5 - $d))}
}

# A rounded rectangle, optionally with an inset ring (CSS "inset 0 0 0 Npx")
# and an outer drop shadow (CSS "0 DYpx BLURpx rgba(0,0,0,A)").
#   opts: -fill #hex -ring {#hex width ?sides?} -shadow {dy blur alpha ?#hex?}
#         -radius r | {tl tr br bl}
# Ring sides is a subset of "tlrb" (default all): an open side lets two
# shapes join without a seam (the bar and the results hanging from it).
# The image is w x h plus room for the shadow; returns {photo padx pady}.
proc raster::rrect {w h args} {
	array set o {-fill #000000 -ring {} -shadow {} -radius 0 -offset {0 0}}
	array set o $args
	set pad 0; set pt 0; set pb 0
	lassign $o(-offset) ox oy
	if {$o(-shadow) ne ""} {
		lassign $o(-shadow) dy blur sa sc
		if {$sc eq ""} { set sc #000000 }
		lassign [rgb $sc] sr sg sb
		set pad [expr {int(ceil($blur * 1.5))}]
		set pt [expr {max(0, $pad - $dy)}]; set pb [expr {$pad + $dy}]
	}
	set key [list rrect $w $h [array get o]]
	# the same pixels, about a thousand times faster, from rbnalpha (C)
	if {[llength [info commands ::rbnalpha::rrect]]} {
		return [list [cached_c $key [list ::rbnalpha::rrect %P $w $h {*}[array get o]]] $pad $pt]
	}
	set img [cached $key {
		set iw [expr {int(ceil($w + $ox)) + 2 * $pad}]; set ih [expr {int(ceil($h + $oy)) + $pt + $pb}]
		lassign [rgb $o(-fill)] fr fg fb
		if {![info exists sr]} { set sr 0; set sg 0; set sb 0 }
		set rw 0
		set sides tlrb
		if {$o(-ring) ne ""} {
			lassign $o(-ring) rc rw sd
			lassign [rgb $rc] rr rg rb
			if {$sd ne ""} { set sides $sd }
		}
		set r $o(-radius)
		set x0 [expr {$pad + $ox}]; set y0 [expr {$pt + $oy}]; set x1 [expr {$x0 + $w}]; set y1 [expr {$y0 + $h}]
		# separable Gaussian shadow (rect approximation; sigma = blur / 2)
		set fx {}; set fy {}
		if {$o(-shadow) ne ""} {
			set k [expr {1.0 / ($blur / 2.0 * sqrt(2.0))}]
			for {set x 0} {$x < $iw} {incr x} {
				set p [expr {$x + 0.5}]
				lappend fx [expr {0.5 * ([erf [expr {($p - $x0) * $k}]] - [erf [expr {($p - $x1) * $k}]])}]
			}
			for {set y 0} {$y < $ih} {incr y} {
				set p [expr {$y + 0.5 - $dy}]
				lappend fy [expr {0.5 * ([erf [expr {($p - $y0) * $k}]] - [erf [expr {($p - $y1) * $k}]])}]
			}
		}
		set rows {}
		for {set y 0} {$y < $ih} {incr y} {
			set row {}
			set py [expr {$y + 0.5}]
			set sy [expr {$fy eq "" ? 0.0 : [lindex $fy $y]}]
			for {set x 0} {$x < $iw} {incr x} {
				set px [expr {$x + 0.5}]
				set co [rbox $px $py $x0 $y0 $x1 $y1 $r]
				set s [expr {$fx eq "" ? 0.0 : $sa * $sy * [lindex $fx $x]}]
				if {$rw > 0 && $co > 0} {
					set ri {}
					foreach rr0 [expr {[llength $r] == 4 ? $r : [list $r $r $r $r]}] { lappend ri [expr {max(0.0, $rr0 - $rw)}] }
					set ci [rbox $px $py \
						[expr {[string first l $sides] >= 0 ? $x0+$rw : $x0-$rw-50}] \
						[expr {[string first t $sides] >= 0 ? $y0+$rw : $y0-$rw-50}] \
						[expr {[string first r $sides] >= 0 ? $x1-$rw : $x1+$rw+50}] \
						[expr {[string first b $sides] >= 0 ? $y1-$rw : $y1+$rw+50}] $ri]
					set f [expr {$co > 0 ? ($co - $ci) / $co : 0}]
					set cr [expr {$rr*$f + $fr*(1-$f)}]; set cg [expr {$rg*$f + $fg*(1-$f)}]; set cb [expr {$rb*$f + $fb*(1-$f)}]
				} else {
					set cr $fr; set cg $fg; set cb $fb
				}
				set a [expr {$co + $s * (1.0 - $co)}]
				if {$a <= 0.0} { lappend row 0 0 0 0; continue }
				set k2 [expr {$co / $a}]; set k3 [expr {1.0 - $k2}]
				lappend row [expr {int($cr*$k2 + $sr*$k3 + 0.5)}] [expr {int($cg*$k2 + $sg*$k3 + 0.5)}] \
					[expr {int($cb*$k2 + $sb*$k3 + 0.5)}] [expr {int($a*255 + 0.5)}]
			}
			lappend rows $row
		}
		png $iw $ih $rows
	}]
	list $img $pad $pt
}

# Copy src region (fx0 fy0 fx1 fy1) to dst at tx ty, tiling it over
# tx..tx1 when tx1 is given, clipped to dst's top-left (Tk refuses
# negative destinations), alpha-composited.
proc raster::blit {dst src fx0 fy0 fx1 fy1 tx ty {tx1 ""}} {
	set tw [expr {$tx1 eq "" ? $fx1 - $fx0 : $tx1 - $tx}]
	if {$tx < 0} {
		if {$tx1 eq ""} { set fx0 [expr {$fx0 - $tx}] }
		set tw [expr {$tw + $tx}]; set tx 0
	}
	if {$ty < 0} { set fy0 [expr {$fy0 - $ty}]; set ty 0 }
	if {$tw <= 0 || $fy1 <= $fy0 || $fx1 <= $fx0} return
	$dst copy $src -from $fx0 $fy0 $fx1 $fy1 -to $tx $ty [expr {$tx + $tw}] \
		[expr {$ty + $fy1 - $fy0}] -compositingrule overlay
}

# Draw a rounded rectangle of any width into photo DST at x y (top-left of
# the box itself), compositing over what is there. A narrow template is
# rendered once and stretched by tiling its middle column (9-slice), so
# widths that change with text cost only C-level photo copies.
proc raster::box {dst x y w h args} {
	array set o {-radius 0 -shadow {}}
	array set o $args
	set cap [expr {int(ceil([tcl::mathfunc::max {*}$o(-radius)])) + 2}]
	set tw [expr {2 * $cap + 1}]
	if {$w <= $tw} {
		lassign [rrect $w $h {*}$args] img padx pady
		blit $dst $img 0 0 [image width $img] [image height $img] [expr {$x - $padx}] [expr {$y - $pady}]
		return
	}
	lassign [rrect $tw $h {*}$args] img padx pady
	set iw [image width $img]; set ih [image height $img]
	set lx [expr {$x - $padx}]; set ty [expr {$y - $pady}]
	set lw [expr {$padx + $cap}]
	set mx [expr {$x + $cap}]; set mx1 [expr {$x + $w - $cap}]
	blit $dst $img 0 0 $lw $ih $lx $ty
	blit $dst $img $lw 0 [expr {$lw + 1}] $ih $mx $ty $mx1
	blit $dst $img [expr {$lw + 1}] 0 $iw $ih $mx1 $ty
}

# A concave corner where a column rises out of a bar's top edge (the dock
# and a menu standing on it): R x R outside a quarter circle, filled, with
# a 1 px ring along the arc. SIDE l: the column is to the right of it (place
# at column x - R, bar top - R); r: mirrored (place at column right - 1).
proc raster::fillet {side r fill ring} {
	cached [list fillet $side $r $fill $ring] {
		lassign [rgb $fill] fr fg fb
		lassign [rgb $ring] rr rg rb
		set n [expr {$r + 1}]
		set rows {}
		for {set y 0} {$y < $n} {incr y} {
			set row {}
			for {set x 0} {$x < $n} {incr x} {
				set cf 0.0; set cr 0.0
				foreach sy {0.125 0.375 0.625 0.875} {
					foreach sx {0.125 0.375 0.625 0.875} {
						set px [expr {$side eq "l" ? $x + $sx : $n - $x - $sx}]
						set d [expr {hypot($px, $y + $sy)}]
						if {$d >= $r + 1} { set cf [expr {$cf + 0.0625}] } elseif {$d >= $r} { set cr [expr {$cr + 0.0625}] }
					}
				}
				set a [expr {$cf + $cr}]
				if {$a <= 0} { lappend row 0 0 0 0; continue }
				set k [expr {$cr / $a}]
				lappend row [expr {int($rr*$k + $fr*(1-$k) + 0.5)}] [expr {int($rg*$k + $fg*(1-$k) + 0.5)}] \
					[expr {int($rb*$k + $fb*(1-$k) + 0.5)}] [expr {int($a*255 + 0.5)}]
			}
			lappend rows $row
		}
		png $n $n $rows
	}
}

# ---- line icons ------------------------------------------------------

# Parse an SVG path (M L H V A C S Z, absolute and relative) into polylines.
proc raster::path {d} {
	set toks [regexp -all -inline {[MmLlHhVvAaCcSsZz]|-?(?:\d+\.?\d*|\.\d+)(?:e-?\d+)?} $d]
	set lines {}; set cur {}
	set x 0.0; set y 0.0; set sx 0.0; set sy 0.0
	set cmd M; set i 0; set n [llength $toks]
	set qx {}; set qy {}   ;# the last cubic's second control point, for S ("" after anything else)
	while {$i < $n} {
		set t [lindex $toks $i]
		if {[string is alpha $t]} { set cmd $t; incr i
			if {$cmd in {Z z}} {
				lappend cur $sx $sy; set x $sx; set y $sy; set qx {}; set qy {}
				lappend lines $cur; set cur [list $x $y]; continue
			}
		}
		set rel [string is lower $cmd]
		set up [string toupper $cmd]
		if {$up eq "S"} {
			# S: a cubic whose first control point is the last one's second, mirrored (the current point when the
			# command before was not C or S)
			lassign [lrange $toks $i [expr {$i+3}]] c e f g; incr i 4
			if {$rel} { set c [expr {$x+$c}]; set e [expr {$y+$e}]; set f [expr {$x+$f}]; set g [expr {$y+$g}] }
			if {$qx eq ""} { set a $x; set b $y } else { set a [expr {2*$x - $qx}]; set b [expr {2*$y - $qy}] }
			for {set k 1} {$k <= 12} {incr k} {
				set t2 [expr {$k / 12.0}]; set u [expr {1 - $t2}]
				lappend cur [expr {$u*$u*$u*$x + 3*$u*$u*$t2*$a + 3*$u*$t2*$t2*$c + $t2*$t2*$t2*$f}] \
					[expr {$u*$u*$u*$y + 3*$u*$u*$t2*$b + 3*$u*$t2*$t2*$e + $t2*$t2*$t2*$g}]
			}
			set qx $c; set qy $e; set x $f; set y $g
			continue
		}
		if {$up ne "C"} { set qx {}; set qy {} }
		switch -- $up {
			M {
				lassign [lrange $toks $i [expr {$i+1}]] a b; incr i 2
				if {$rel} { set x [expr {$x+$a}]; set y [expr {$y+$b}] } else { set x $a; set y $b }
				if {[llength $cur] > 2} { lappend lines $cur }
				set cur [list $x $y]; set sx $x; set sy $y
				set cmd [expr {$rel ? "l" : "L"}]
			}
			L {
				lassign [lrange $toks $i [expr {$i+1}]] a b; incr i 2
				if {$rel} { set x [expr {$x+$a}]; set y [expr {$y+$b}] } else { set x $a; set y $b }
				lappend cur $x $y
			}
			H { set a [lindex $toks $i]; incr i
				set x [expr {$rel ? $x+$a : $a}]; lappend cur $x $y }
			V { set a [lindex $toks $i]; incr i
				set y [expr {$rel ? $y+$a : $a}]; lappend cur $x $y }
			C {
				lassign [lrange $toks $i [expr {$i+5}]] a b c e f g; incr i 6
				if {$rel} { set a [expr {$x+$a}]; set b [expr {$y+$b}]; set c [expr {$x+$c}]
					set e [expr {$y+$e}]; set f [expr {$x+$f}]; set g [expr {$y+$g}] }
				for {set k 1} {$k <= 12} {incr k} {
					set t2 [expr {$k / 12.0}]; set u [expr {1 - $t2}]
					lappend cur [expr {$u*$u*$u*$x + 3*$u*$u*$t2*$a + 3*$u*$t2*$t2*$c + $t2*$t2*$t2*$f}] \
						[expr {$u*$u*$u*$y + 3*$u*$u*$t2*$b + 3*$u*$t2*$t2*$e + $t2*$t2*$t2*$g}]
				}
				set qx $c; set qy $e; set x $f; set y $g
			}
			A {
				lassign [lrange $toks $i [expr {$i+6}]] rx ry rot large sweep ex ey; incr i 7
				if {$rel} { set ex [expr {$x+$ex}]; set ey [expr {$y+$ey}] }
				foreach {px py} [arc $x $y $rx $ry $rot $large $sweep $ex $ey] { lappend cur $px $py }
				set x $ex; set y $ey
			}
		}
	}
	if {[llength $cur] >= 2} { lappend lines $cur }
	return $lines
}

# SVG elliptical arc (endpoint form, no rotation needed by our icons) -> points
proc raster::arc {x1 y1 rx ry rot large sweep x2 y2} {
	if {$rx == 0 || $ry == 0} { return [list $x2 $y2] }
	set rx [expr {abs($rx)}]; set ry [expr {abs($ry)}]
	set dx [expr {($x1 - $x2) / 2.0}]; set dy [expr {($y1 - $y2) / 2.0}]
	set l [expr {($dx*$dx)/($rx*$rx) + ($dy*$dy)/($ry*$ry)}]
	if {$l > 1} { set rx [expr {$rx*sqrt($l)}]; set ry [expr {$ry*sqrt($l)}] }
	set num [expr {$rx*$rx*$ry*$ry - $rx*$rx*$dy*$dy - $ry*$ry*$dx*$dx}]
	set den [expr {$rx*$rx*$dy*$dy + $ry*$ry*$dx*$dx}]
	set co [expr {$den == 0 ? 0 : sqrt(max(0.0, $num / $den))}]
	if {$large == $sweep} { set co [expr {-$co}] }
	set cxp [expr {$co * $rx * $dy / $ry}]; set cyp [expr {-$co * $ry * $dx / $rx}]
	set cx [expr {$cxp + ($x1 + $x2) / 2.0}]; set cy [expr {$cyp + ($y1 + $y2) / 2.0}]
	set a1 [expr {atan2(($y1 - $cy) / $ry, ($x1 - $cx) / $rx)}]
	set a2 [expr {atan2(($y2 - $cy) / $ry, ($x2 - $cx) / $rx)}]
	set da [expr {$a2 - $a1}]
	set pi 3.141592653589793
	if {$sweep && $da < 0} { set da [expr {$da + 2*$pi}] }
	if {!$sweep && $da > 0} { set da [expr {$da - 2*$pi}] }
	set steps [expr {max(4, int(ceil(abs($da) / ($pi / 16))))}]
	set pts {}
	for {set k 1} {$k <= $steps} {incr k} {
		set a [expr {$a1 + $da * $k / $steps}]
		lappend pts [expr {$cx + $rx*cos($a)}] [expr {$cy + $ry*sin($a)}]
	}
	return $pts
}

# Coverage mask of a stroked path: size px (viewBox 24), stroke width in
# viewBox units, round caps and joins. Returns rows of 0..1 floats.
proc raster::strokemask {d size width {ox 0} {oy 0}} {
	set s [expr {$size / 24.0}]
	set iw [expr {int(ceil($size + $ox))}]; set ih [expr {int(ceil($size + $oy))}]
	set hw [expr {$width * $s / 2.0}]
	set segs {}
	foreach line [path $d] {
		set pts {}
		foreach {px py} $line { lappend pts [expr {$px*$s + $ox}] [expr {$py*$s + $oy}] }
		if {[llength $pts] == 2} { lappend pts {*}$pts }
		foreach {ax ay} [lrange $pts 0 end-2] {bx by} [lrange $pts 2 end] {
			if {$bx eq ""} break
			lappend segs [list $ax $ay $bx $by]
		}
	}
	# Each segment with its bounding box grown by the stroke: a pixel only
	# measures the segments near it (rows first, then columns).
	set reach [expr {$hw + 1.0}]
	set boxed {}
	foreach sg $segs {
		lassign $sg ax ay bx by
		lappend boxed [list $ax $ay $bx $by [expr {min($ax,$bx) - $reach}] [expr {max($ax,$bx) + $reach}] \
			[expr {min($ay,$by) - $reach}] [expr {max($ay,$by) + $reach}]]
	}
	set rows {}
	for {set y 0} {$y < $ih} {incr y} {
		set row {}
		set py [expr {$y + 0.5}]
		set near {}
		foreach b $boxed { if {$py >= [lindex $b 6] && $py <= [lindex $b 7]} { lappend near $b } }
		for {set x 0} {$x < $iw} {incr x} {
			set px [expr {$x + 0.5}]
			set best 1e9
			foreach b $near {
				lassign $b ax ay bx by x0 x1
				if {$px < $x0 || $px > $x1} continue
				set vx [expr {$bx-$ax}]; set vy [expr {$by-$ay}]
				set ll [expr {$vx*$vx + $vy*$vy}]
				set t [expr {$ll == 0 ? 0 : max(0.0, min(1.0, (($px-$ax)*$vx + ($py-$ay)*$vy) / $ll))}]
				set d2 [expr {hypot($px - $ax - $t*$vx, $py - $ay - $t*$vy)}]
				if {$d2 < $best} { set best $d2 }
			}
			lappend row [expr {$best > $reach ? 0.0 : min(1.0, max(0.0, $hw + 0.5 - $best))}]
		}
		lappend rows $row
	}
	return $rows
}

proc raster::fillmask {d size {ox 0} {oy 0}} {
	set s [expr {$size / 24.0}]
	set iw [expr {int(ceil($size + $ox))}]; set ih [expr {int(ceil($size + $oy))}]
	set edges {}
	foreach line [path $d] {
		set pts {}
		foreach {px py} $line { lappend pts [expr {$px*$s + $ox}] [expr {$py*$s + $oy}] }
		lappend pts {*}[lrange $pts 0 1]
		foreach {ax ay} [lrange $pts 0 end-2] {bx by} [lrange $pts 2 end] {
			if {$bx eq "" || $ay == $by} continue
			lappend edges [list $ax $ay $bx $by]
		}
	}
	set cov [lrepeat $ih [lrepeat $iw 0.0]]
	for {set sy 0} {$sy < $ih * 4} {incr sy} {
		set yc [expr {($sy + 0.5) / 4.0}]
		set y [expr {$sy / 4}]
		set xs {}
		foreach e $edges {
			lassign $e ax ay bx by
			if {($ay <= $yc && $yc < $by) || ($by <= $yc && $yc < $ay)} {
				lappend xs [expr {$ax + ($yc - $ay) * ($bx - $ax) / ($by - $ay)}]
			}
		}
		set row [lindex $cov $y]
		foreach {a b} [lsort -real $xs] {
			if {$b eq ""} break
			for {set x [expr {max(0, int(floor($a)))}]} {$x < min($iw, int(ceil($b)))} {incr x} {
				set o [expr {min($b, $x + 1.0) - max($a, double($x))}]
				if {$o > 0} { lset row $x [expr {[lindex $row $x] + 0.25 * $o}] }
			}
		}
		lset cov $y $row
	}
	return $cov
}

# A line icon in COLOUR as a photo. extra: filled rounded boxes in viewBox
# units {x y w h r ...} (the battery level). fill: an alpha (0..1) to also
# fill the outline in the same colour (the mockups' tinted folders).
proc raster::icon {d size width colour {extra {}} {ox 0} {oy 0} {fill 0}} {
	cached [list icon $d $size $width $colour $extra $ox $oy $fill] {
		set mask [strokemask $d $size $width $ox $oy]
		set fm [expr {$fill > 0 ? [fillmask $d $size $ox $oy] : ""}]
		lassign [rgb $colour] cr cg cb
		set s [expr {$size / 24.0}]
		set iw [expr {int(ceil($size + $ox))}]; set ih [expr {int(ceil($size + $oy))}]
		set rows {}
		for {set y 0} {$y < $ih} {incr y} {
			set row {}
			set mrow [lindex $mask $y]
			set frow [expr {$fm eq "" ? "" : [lindex $fm $y]}]
			for {set x 0} {$x < $iw} {incr x} {
				set a [lindex $mrow $x]
				if {$frow ne ""} { set a [expr {$a + min(1.0, [lindex $frow $x]) * $fill * (1 - $a)}] }
				foreach {bx by bw bh br} $extra {
					set c [rbox [expr {$x+0.5}] [expr {$y+0.5}] [expr {$bx*$s + $ox}] [expr {$by*$s + $oy}] \
						[expr {($bx+$bw)*$s + $ox}] [expr {($by+$bh)*$s + $oy}] [expr {$br*$s}]]
					set a [expr {$a + $c * (1 - $a)}]
				}
				lappend row $cr $cg $cb [expr {int($a*255 + 0.5)}]
			}
			lappend rows $row
		}
		png $iw $ih $rows
	}
}
