# wall.tcl - the Ribbon wallpaper's pixels, for what draws a wallpaper
# itself: the wallpaper generator (ribbon-wallpaper's SVG), the login
# screen (a full-screen Tk window) and Appearance's previews. Nothing uses
# it to fake transparency any more: the shell's bars, menus and panels and
# the apps' rounded windows are ARGB windows (rbnalpha), and the compositor
# shows what is really behind them.
#
# The design: a vertical gradient DESK_TOP -> DESK_BOTTOM, 45-degree
# stripes (44 px of every 150 px, CSS repeating-linear-gradient(45deg,
# transparent 0 106px, stripe 106px 150px)) and the "ribbon" wordmark.

namespace eval wall {
	variable image ""      ;# your own picture (wallpaper.conf IMAGE=), or ""
	variable full ""       ;# that picture (or plain colour) at the screen's size, as a photo
	variable fit fill      ;# how the picture is laid out: fill | fit | centre | tile
	variable colour ""     ;# the plain colour (MODE=colour), also around a picture that doesn't fill the screen
	variable mode ""       ;# wallpaper.conf MODE= (pattern picture colour slideshow video)
}

# ---- your own picture ------------------------------------------------------

# Width and height from a PNG, JPEG or WebP header (no decoding needed).
proc wall::image_size {f} {
	set fh [open $f rb]; set d [read $fh 65536]; close $fh
	image_size_data $d $f
}

# The same from the file's first bytes (ribbon-login-theme checks a
# picture's header before it installs it).
proc wall::image_size_data {d {f picture}} {
	if {[string range $d 1 3] eq "PNG"} {
		binary scan $d @16II w h; return [list $w $h]
	}
	if {[string range $d 0 3] eq "RIFF" && [string range $d 8 11] eq "WEBP"} {
		switch -- [string range $d 12 15] {
			"VP8 " { binary scan $d @26ss w h; return [list [expr {$w & 0x3fff}] [expr {$h & 0x3fff}]] }
			"VP8L" { binary scan $d @21i b; return [list [expr {($b & 0x3fff) + 1}] [expr {(($b >> 14) & 0x3fff) + 1}]] }
			"VP8X" { binary scan $d @24cucucucucucu a b c e f g
				return [list [expr {($a | $b << 8 | $c << 16) + 1}] [expr {($e | $f << 8 | $g << 16) + 1}]] }
		}
	}
	# JPEG: walk the segments to a start-of-frame marker
	set i 2
	while {$i < [string length $d] - 9} {
		binary scan $d @${i}cucuSu ff m len
		if {$ff != 0xff} break
		if {$m >= 0xc0 && $m <= 0xcf && $m ni {0xc4 0xc8 0xcc}} {
			binary scan $d @[expr {$i + 5}]SuSu h w; return [list $w $h]
		}
		incr i [expr {2 + $len}]
	}
	error "unknown image format: $f"
}

# Lay the picture out on W x H as swaybg's modes do. FIT: fill (scale to
# cover, crop the middle), fit (scale to show all of it, centred, BG
# around), centre (as it is, centred: cropped, or BG around) or tile (as
# it is, repeated from the top-left). The result is cached and also what
# swaybg shows, so the shell's copy behind its bars matches the screen
# pixel for pixel.
# Where prepare keeps the picture laid out so (whether it is there yet or not).
proc wall::prepare_path {f W H {fit fill} {bg #000000}} {
	if {$fit ni {fill fit centre tile}} { set fit fill }
	if {![regexp {^#[0-9A-Fa-f]{6}$} $bg]} { set bg #000000 }
	set cache [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$::env(HOME)/.cache"}]/ribbon/wallpaper
	file mkdir $cache
	set key "[realpath $f] [file mtime $f] $W $H"
	if {$fit ne "fill"} { append key " $fit $bg" }
	file join $cache img-[format %08x [zlib crc32 $key]]-${W}x$H.png
}

proc wall::prepare {f W H {fit fill} {bg #000000}} {
	if {$fit ni {fill fit centre tile}} { set fit fill }
	if {![regexp {^#[0-9A-Fa-f]{6}$} $bg]} { set bg #000000 }
	set out [prepare_path $f $W $H $fit $bg]
	if {[file exists $out]} { return $out }
	lassign [image_size $f] w h
	switch -- $fit {
		fill { set s [expr {max(double($W) / $w, double($H) / $h)}] }
		fit { set s [expr {min(double($W) / $w, double($H) / $h)}] }
		default { set s 1.0 }
	}
	set size [expr {int(ceil(max($w * $s, $h * $s)))}]
	set tmp $out.[pid].png
	if {[auto_execok gdk-pixbuf-thumbnailer] ne "" && ($s != 1.0 || ![string match -nocase *.png $f])} {
		exec gdk-pixbuf-thumbnailer -s $size $f $tmp
		set t [image create photo -file $tmp]
		file delete $tmp
	} elseif {[auto_execok ffmpeg] ne "" && ![catch {exec ffmpeg -nostdin -v error -y -i $f -frames:v 1 \
			-vf scale=[expr {max(1, round($w * $s))}]:[expr {max(1, round($h * $s))}]:flags=area $tmp </dev/null >/dev/null 2>/dev/null}]} {
		# no gdk-pixbuf: ffmpeg scales as well (area averaging)
		set t [image create photo -file $tmp]
		file delete $tmp
	} else {
		# neither: Tk reads PNG itself, and shrinks in whole steps only
		set t [image create photo -file $f]
		if {$s < 1} {
			set k [expr {$fit eq "fill" ? min([image width $t] / $W, [image height $t] / $H) : int(ceil(1 / $s))}]
			if {$k > 1} { set t2 [image create photo]; $t2 copy $t -subsample $k; image delete $t; set t $t2 }
		}
	}
	# a picture smaller than the screen: gdk-pixbuf won't enlarge, Tk can
	# (in whole steps)
	set z 1
	if {$fit eq "fill"} {
		while {[image width $t] * $z < $W || [image height $t] * $z < $H} { incr z }
	} elseif {$fit eq "fit"} {
		while {[image width $t] * ($z + 1) <= $W && [image height $t] * ($z + 1) <= $H} { incr z }
	}
	if {$z > 1} { set t2 [image create photo]; $t2 copy $t -zoom $z; image delete $t; set t $t2 }
	set o [image create photo -width $W -height $H]
	set tw [image width $t]; set th [image height $t]
	if {$fit eq "tile"} {
		$o copy $t -to 0 0 $W $H
	} else {
		if {$fit ne "fill"} { $o put $bg -to 0 0 $W $H }
		# the middle of the picture on the middle of the screen
		set x0 [expr {($tw - $W) / 2}]; set y0 [expr {($th - $H) / 2}]
		set fx [expr {max(0, $x0)}]; set fy [expr {max(0, $y0)}]
		$o copy $t -from $fx $fy [expr {min($tw, $fx + $W)}] [expr {min($th, $fy + $H)}] \
			-to [expr {max(0, -$x0)}] [expr {max(0, -$y0)}]
	}
	$o write $tmp -format png
	file rename -force $tmp $out
	image delete $t $o
	return $out
}

# A plain colour at W x H, as a file (swaybg shows it too).
proc wall::solid {colour W H} {
	set cache [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$::env(HOME)/.cache"}]/ribbon/wallpaper
	file mkdir $cache
	set out [file join $cache solid-[string range $colour 1 end]-${W}x$H.png]
	if {![file exists $out]} {
		set o [image create photo -width $W -height $H]
		$o put $colour -to 0 0 $W $H
		$o write $out.[pid] -format png
		image delete $o
		file rename -force $out.[pid] $out
	}
	return $out
}

# MODE, FIT and COLOUR from wallpaper.conf (written by "ribbon-theme
# wallpaper"; IMAGE is read by theme::load).
proc wall::conf {} {
	variable fit fill
	variable colour ""
	variable mode ""
	set cfg [expr {[info exists ::env(XDG_CONFIG_HOME)] ? $::env(XDG_CONFIG_HOME) : "$::env(HOME)/.config"}]
	if {[catch {open $cfg/ribbon/wallpaper.conf} fh]} return
	set text [read $fh]; close $fh
	regexp -line {^MODE=([a-z]+)$} $text -> mode
	if {[regexp -line {^FIT=(fill|fit|centre|tile)$} $text -> f]} { set fit $f }
	regexp -line {^COLOUR=(#[0-9A-Fa-f]{6})$} $text -> colour
}

# Show the picture or the plain colour, else the pattern (called at start
# and by "ribbon-shell-ctl wallpaper").
proc wall::use_image {W H} {
	variable image
	variable full
	variable mode
	variable fit
	variable colour
	conf
	set file ""
	if {$mode eq "colour" && $colour ne ""} {
		set image ""
		if {[catch {solid $colour $W $H} file]} { puts stderr "wallpaper: $file"; set file "" }
	} elseif {$image ne "" && [file readable $image]} {
		if {[catch {prepare $image $W $H $fit [expr {$colour ne "" ? $colour : "#000000"}]} file]} { puts stderr "wallpaper: $file"; set file "" }
	}
	# the regions copied from the last picture
	foreach i [image names] { if {[string match ::wall::r* $i]} { image delete $i } }
	if {$full ne ""} { image delete $full; set full "" }
	if {$file eq ""} { set image ""; return }
	set full [image create photo -file $file]
}

# The picture FILE (at the screen's size) blurred as CSS blur(PX) does: a
# Gaussian of that standard deviation, done as three box blurs on a copy
# shrunk by up to PX / 3 and enlarged again smoothly. Pure Tcl takes a few
# seconds, so the result is cached next to the picture. (The login screen
# and the Appearance app's preview of it.)
proc wall::blurred {file px} {
	set out [file rootname $file]-blur$px.png
	if {[file exists $out]} { return $out }
	# CSS blur(PX) is a Gaussian of standard deviation PX. Fastest first:
	# rbnalpha's in C (~40 ms at 2560 x 1440), ffmpeg's gblur (~0.3 s, a
	# process), rbn::blur's Tcl (~1 s), the Tcl below (seconds) last.
	set fast [fast_blur]
	if {!$fast && [auto_execok ffmpeg] ne "" && ![catch {exec ffmpeg -nostdin -v error -y -i $file -vf gblur=sigma=$px \
			-compression_level 1 $out.[pid].png </dev/null >/dev/null 2>/dev/null}]} {
		file rename -force $out.[pid].png $out
		return $out
	}
	if {[rbn]} {
		set src [image create photo -file $file]
		set dst [image create photo]
		if {![catch {rbn::blur $src $dst $px}]} {
			$dst write $out.[pid].png -format png
			image delete $src $dst
			file rename -force $out.[pid].png $out
			return $out
		}
		image delete $src $dst
	}
	set src [image create photo -file $file]
	set W [image width $src]; set H [image height $src]
	set k [expr {max(1, $px / 3)}]
	set small [image create photo]
	$small copy $src -subsample $k
	image delete $src
	set w [image width $small]; set h [image height $small]
	# three channels of the small copy as flat lists
	set R {}; set G {}; set B {}
	foreach row [$small data] {
		foreach hex $row { scan $hex #%2x%2x%2x r g b; lappend R $r; lappend G $g; lappend B $b }
	}
	image delete $small
	set sigma [expr {double($px) / $k}]
	# three passes of a box this wide approximate the Gaussian
	set r [expr {max(1, int(round((sqrt(12.0 * $sigma * $sigma / 3 + 1) - 1) / 2)))}]
	foreach ch {R G B} {
		set v [set $ch]
		for {set pass 0} {$pass < 3} {incr pass} {
			set v [box_h $v $w $h $r]
			set v [box_v $v $w $h $r]
		}
		set $ch $v
	}
	# enlarge with bilinear interpolation, centre-aligned
	set xi {}
	for {set x 0} {$x < $W} {incr x} {
		set fx [expr {min($w - 1.0, max(0.0, ($x + 0.5) / $k - 0.5))}]
		set x0 [expr {int($fx)}]; lappend xi $x0 [expr {min($w - 1, $x0 + 1)}] [expr {$fx - $x0}]
	}
	set rows {}
	for {set y 0} {$y < $H} {incr y} {
		set fy [expr {min($h - 1.0, max(0.0, ($y + 0.5) / $k - 0.5))}]
		set y0 [expr {int($fy)}]; set y1 [expr {min($h - 1, $y0 + 1)}]; set ty [expr {$fy - $y0}]
		set o0 [expr {$y0 * $w}]; set o1 [expr {$y1 * $w}]
		set row {}
		foreach {x0 x1 tx} $xi {
			foreach ch [list $R $G $B] {
				set a [expr {[lindex $ch [expr {$o0 + $x0}]] * (1 - $tx) + [lindex $ch [expr {$o0 + $x1}]] * $tx}]
				set b [expr {[lindex $ch [expr {$o1 + $x0}]] * (1 - $tx) + [lindex $ch [expr {$o1 + $x1}]] * $tx}]
				lappend row [expr {int($a + ($b - $a) * $ty + 0.5)}]
			}
			lappend row 255
		}
		lappend rows $row
	}
	set fh [open $out.[pid] wb]; puts -nonewline $fh [raster::png $W $H $rows]; close $fh
	file rename -force $out.[pid] $out
	return $out
}

# The file a symlink points to (the cache's key for a picture, so a link to
# it shares the cached copies).
proc wall::realpath {f} {
	set n 0
	while {![catch {file type $f} t] && $t eq "link" && [incr n] < 10} {
		set f [file normalize [file join [file dirname $f] [file readlink $f]]]
	}
	return $f
}

# rbnalpha (the Tk extension, /usr/lib/ribbon/rbnalpha; from the source
# tree with RBNALPHA_LIB naming its library): 1 when it can be used, and
# fast_blur: 1 when its blur is the C one.
namespace eval wall { variable here [file dirname [file normalize [info script]]] }
proc wall::rbn {} {
	variable rbn
	if {[info exists rbn]} { return $rbn }
	variable here
	foreach d [list /usr/lib/ribbon [file dirname $here]] { if {$d ni $::auto_path} { lappend ::auto_path $d } }
	set rbn [expr {[info commands ::image] ne "" && ![catch {package require rbnalpha}] && [info commands ::rbn::blur] ne ""}]
}
proc wall::fast_blur {} { expr {[rbn] && [rbn::native]} }

# A cheap stand-in for blurred, for a preview until the real one is ready:
# with rbnalpha's C blur, the real thing (~40 ms); else photo P blurred at
# 1/K of its size (K about a sixteenth of the width) and zoomed back, blocky
# but ~0.1 s.
proc wall::blurred_quick {p px} {
	if {[fast_blur]} {
		set out [image create photo]
		rbn::blur $p $out $px
		return $out
	}
	set W [image width $p]; set H [image height $p]
	set k [expr {max(8, int(round($W / 90.0)))}]
	set small [image create photo]
	$small copy $p -subsample $k
	set w [image width $small]; set h [image height $small]
	set R {}; set G {}; set B {}
	foreach row [$small data] { foreach hex $row { scan $hex #%2x%2x%2x r g b; lappend R $r; lappend G $g; lappend B $b } }
	set sigma [expr {double($px) / $k}]
	set r [expr {max(1, int(round((sqrt(12.0 * $sigma * $sigma / 3 + 1) - 1) / 2)))}]
	foreach ch {R G B} {
		set v [set $ch]
		for {set pass 0} {$pass < 3} {incr pass} { set v [box_h $v $w $h $r]; set v [box_v $v $w $h $r] }
		set $ch $v
	}
	set rows {}
	set i 0
	for {set y 0} {$y < $h} {incr y} {
		set row {}
		for {set x 0} {$x < $w} {incr x} { lappend row [format #%02x%02x%02x [lindex $R $i] [lindex $G $i] [lindex $B $i]]; incr i }
		lappend rows $row
	}
	$small put $rows
	set out [image create photo -width $W -height $H]
	$out copy $small -zoom $k -to 0 0 $W $H
	image delete $small
	return $out
}

# One box-blur pass of radius R along the rows (box_h) or the columns
# (box_v) of a W x H channel; the edges are extended.
proc wall::box_h {v w h r} {
	set out {}
	set n [expr {2 * $r + 1}]
	for {set y 0} {$y < $h} {incr y} {
		set row [lrange $v [expr {$y * $w}] [expr {$y * $w + $w - 1}]]
		set first [lindex $row 0]; set last [lindex $row end]
		set ext [concat [lrepeat $r $first] $row [lrepeat [expr {$r + 1}] $last]]
		set sum 0
		for {set i 0} {$i < $n} {incr i} { incr sum [lindex $ext $i] }
		for {set x 0} {$x < $w} {incr x} {
			lappend out [expr {($sum + $r) / $n}]
			incr sum [expr {[lindex $ext [expr {$x + $n}]] - [lindex $ext $x]}]
		}
	}
	return $out
}
proc wall::box_v {v w h r} {
	# transpose, blur the rows, transpose back
	set t {}
	for {set x 0} {$x < $w} {incr x} { for {set y 0} {$y < $h} {incr y} { lappend t [lindex $v [expr {$y * $w + $x}]] } }
	set t [box_h $t $h $w $r]
	set out {}
	for {set y 0} {$y < $h} {incr y} { for {set x 0} {$x < $w} {incr x} { lappend out [lindex $t [expr {$x * $h + $y}]] } }
	return $out
}

# Position of pixel centre (px, py) along the stripe gradient line.
proc wall::pos {px py W H} {
	set k 0.7071067811865476
	set L [expr {($W + $H) * $k}]
	expr {($px - $W / 2.0) * $k - ($py - $H / 2.0) * $k + $L / 2.0}
}

proc wall::mix {a b t} { expr {$a + ($b - $a) * $t} }

# Rows of RGBA for the screen region x0 y0 w h of a W x H wallpaper.
proc wall::rows {pal x0 y0 w h W H} {
	array set c $pal
	lassign [raster::rgb $c(DESK_TOP)] tr tg tb
	lassign [raster::rgb $c(DESK_BOTTOM)] br bg bb
	lassign [raster::rgb $c(DESK_STRIPE)] sr sg sb
	set sa $c(DESK_STRIPE_ALPHA)
	set k 0.7071067811865476
	set L [expr {($W + $H) * $k}]
	set rows {}
	for {set y $y0} {$y < $y0 + $h} {incr y} {
		set t [expr {($y + 0.5) / double($H)}]
		set r [expr {$tr + ($br - $tr) * $t}]; set g [expr {$tg + ($bg - $tg) * $t}]; set b [expr {$tb + ($bb - $tb) * $t}]
		set R0 [expr {int($r + 0.5)}]; set G0 [expr {int($g + 0.5)}]; set B0 [expr {int($b + 0.5)}]
		set R1 [expr {int($r + ($sr - $r) * $sa + 0.5)}]; set G1 [expr {int($g + ($sg - $g) * $sa + 0.5)}]; set B1 [expr {int($b + ($sb - $b) * $sa + 0.5)}]
		set base [expr {(0.5 - $W / 2.0) * $k - ($y + 0.5 - $H / 2.0) * $k + $L / 2.0}]
		set row {}
		for {set x $x0} {$x < $x0 + $w} {incr x} {
			set p [expr {fmod($base + $x * $k, 150.0)}]
			if {$p >= 106.0} { lappend row $R1 $G1 $B1 255 } else { lappend row $R0 $G0 $B0 255 }
		}
		lappend rows $row
	}
	return $rows
}

# A photo of that region, cached on disk per palette and screen size (the
# login screen paints its background with it).
proc wall::region {pal x0 y0 w h W H} {
	variable full
	if {$full ne ""} {
		set name ::wall::r$x0.$y0.$w.$h
		if {$name ni [image names]} {
			image create photo $name -width $w -height $h
			$name copy $full -from $x0 $y0 [expr {$x0 + $w}] [expr {$y0 + $h}] -to 0 0
		}
		return $name
	}
	raster::cached [list wall $pal $x0 $y0 $w $h $W $H] {
		raster::png $w $h [wall::rows $pal $x0 $y0 $w $h $W $H]
	}
}

# The wallpaper as SVG at exactly W x H (shown 1:1 by swaybg).
proc wall::svg {pal W H} {
	array set c $pal
	set k 0.7071067811865476
	set L [expr {($W + $H) * $k}]
	# stripe bands: pos in [106 + 150n, 150 + 150n]
	set big [expr {$W + $H}]
	set paths ""
	for {set n 0} {106 + 150 * $n < $L} {incr n} {
		set p0 [expr {106 + 150 * $n}]; set p1 [expr {150 + 150 * $n}]
		set pts {}
		foreach {p s} [list $p0 -1 $p0 1 $p1 1 $p1 -1] {
			# point on the gradient line at distance p, then along the band
			set cx [expr {$W / 2.0 + ($p - $L / 2.0) * $k}]
			set cy [expr {$H / 2.0 - ($p - $L / 2.0) * $k}]
			lappend pts [format %.2f [expr {$cx + $s * $big * $k}]] [format %.2f [expr {$cy + $s * $big * $k}]]
		}
		append paths [format {    <path d="M%s %s L%s %s L%s %s L%s %sZ"/>} {*}$pts] \n
	}
	set mark $c(DESK_MARK)
	set markA [expr {[info exists c(DESK_MARK_ALPHA)] ? $c(DESK_MARK_ALPHA) : 1}]
	# wordmark: Space Grotesk 600 148 px, centred as CSS centres it (the
	# trailing -7.4 px letter-spacing counts), line box top at H/2 - 78,
	# baseline from the font's ascent/descent (984/-292 per 1000)
	set base [format %.2f [expr {$H / 2.0 - 78 + (148 - 148 * 1.276) / 2.0 + 148 * 0.984}]]
	return [string cat \
{<?xml version="1.0" encoding="UTF-8"?>} \n \
"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$W\" height=\"$H\" viewBox=\"0 0 $W $H\">" \n \
{  <!-- Ribbon wallpaper, generated by ribbon-wallpaper. -->} \n \
"  <defs><linearGradient id=\"g\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop offset=\"0\" stop-color=\"$c(DESK_TOP)\"/><stop offset=\"1\" stop-color=\"$c(DESK_BOTTOM)\"/></linearGradient></defs>" \n \
"  <rect width=\"$W\" height=\"$H\" fill=\"url(#g)\"/>" \n \
"  <g fill=\"$c(DESK_STRIPE)\" fill-opacity=\"$c(DESK_STRIPE_ALPHA)\">" \n \
$paths \
"  </g>" \n \
"  <text x=\"[expr {$W / 2.0 + 3.3}]\" y=\"$base\" text-anchor=\"middle\" font-family=\"Space Grotesk\" font-weight=\"600\" font-size=\"148\" letter-spacing=\"-7.4\" fill=\"$mark\" fill-opacity=\"$markA\">ribbon</text>" \n \
"</svg>" \n]
}
