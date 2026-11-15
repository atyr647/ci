# make-picture.tcl - pictures for the login theme tests (tests/test-login-theme.sh,
# the greeter's login background scenes in tests/run.sh).
#   tclsh8.6 tests/make-picture.tcl KIND W H OUT
#   bands    a real PNG: the middle #3060A0, the top and bottom (H - 900) / 2
#            rows #C03030 and #30C030 (on a 1440 x 900 screen the login
#            screen must crop those away)
#   png      only a PNG header saying W x H (enough for the size checks)
#   jpeg     only a JPEG header (JFIF, then a baseline frame of W x H)
#   webp     only a WebP header (VP8X, W x H)
#   photo-SCENE-RIDGE  a real PNG: the Properties boards' photo (gen_props.py's
#            photo(): SCENE dusk|blue|ice|ember|fern, RIDGE 0..2), drawn as the
#            browser draws its gradients and clip-path
set repo [file dirname [file dirname [file normalize [info script]]]]
source -encoding utf-8 [file join $repo srcpkgs ribbon-desktop files shell raster.tcl]
lassign $argv kind W H out

proc chunk {type data} {
	string cat [binary format I [string length $data]] $type $data [binary format I [zlib crc32 $type$data]]
}

# gen_props.py's SCENES and RIDGES
set SCENES {
	dusk  {#0f2433 #24485a #d39158 #e8b06e #101c22 #0c151a {255 205 140}}
	blue  {#0b1a2c #1d3e5e #6f9bb8 #a9c7d6 #0d1823 #08111a {190 220 240}}
	ice   {#30505e #7da3ad #d8e4e2 #eef3f0 #2b3f47 #1a2a31 {235 245 245}}
	ember {#1c1410 #4a2a1c #c46a3a #e89a5a #160f0c #0d0907 {255 170 110}}
	fern  {#16241c #2f4a36 #9db07a #c9d49a #101a13 #0a110c {220 230 170}}
}
set RIDGES {
	{0 100 0 62 12 40 22 55 34 18 46 48 55 36 66 64 78 30 90 52 100 44 100 100}
	{0 100 0 48 15 30 28 58 40 42 52 20 63 50 74 38 86 60 100 34 100 100}
	{0 100 0 70 18 52 30 66 45 28 60 56 72 46 84 62 100 50 100 100}
}

# Is (px, py) inside the polygon (even-odd)?
proc inside {poly px py} {
	set in 0
	set n [expr {[llength $poly] / 2}]
	for {set i 0; set j [expr {$n - 1}]} {$i < $n} {set j $i; incr i} {
		set xi [lindex $poly [expr {2 * $i}]]; set yi [lindex $poly [expr {2 * $i + 1}]]
		set xj [lindex $poly [expr {2 * $j}]]; set yj [lindex $poly [expr {2 * $j + 1}]]
		if {($yi > $py) != ($yj > $py) && $px < ($xj - $xi) * ($py - $yi) / double($yj - $yi) + $xi} { set in [expr {!$in}] }
	}
	return $in
}

# The photo: a vertical gradient (sky, horizon, water), an elliptical glow,
# the ridge's silhouette and the glow's reflection.
proc photo {scene ridge W H} {
	lassign [dict get $::SCENES $scene] t m g hz land deep glow
	set stops [list 0 $t 0.36 $m 0.59 $g 0.62 $hz 0.625 $land 1 $deep]
	lassign $glow gr gg gb
	lassign [raster::rgb $land] lr lg lb
	set poly {}
	foreach {px py} [lindex $::RIDGES $ridge] { lappend poly [expr {$px / 100.0 * $W}] [expr {0.30 * $H + $py / 100.0 * 0.33 * $H}] }
	set rows {}
	for {set y 0} {$y < $H} {incr y} {
		set fy [expr {($y + 0.5) / $H}]
		# the sky-to-water gradient at this row
		foreach {s0 c0} [lrange $stops 0 end-2] {s1 c1} [lrange $stops 2 end] {
			if {$s1 eq "" || $fy <= $s1} break
		}
		set k [expr {$s1 > $s0 ? min(1.0, max(0.0, ($fy - $s0) / ($s1 - $s0))) : 1.0}]
		lassign [raster::rgb $c0] r0 g0 b0; lassign [raster::rgb $c1] r1 g1 b1
		set br [expr {$r0 + ($r1 - $r0) * $k}]; set bgc [expr {$g0 + ($g1 - $g0) * $k}]; set bb [expr {$b0 + ($b1 - $b0) * $k}]
		# the reflection: top 63% to the bottom, glow 0.3 fading out by 45%
		set ra 0.0
		set y63 [expr {0.63 * $H}]
		if {$y + 0.5 >= $y63} {
			set f [expr {($y + 0.5 - $y63) / ($H - $y63)}]
			set ra [expr {0.3 * max(0.0, 1.0 - $f / 0.45)}]
		}
		set row {}
		for {set x 0} {$x < $W} {incr x} {
			set r $br; set gc $bgc; set b $bb
			# the glow: radial-gradient(40% 22% at 62% 60%, glow 0.7, transparent 70%)
			set dx [expr {($x + 0.5 - 0.62 * $W) / (0.40 * $W)}]; set dy [expr {($y + 0.5 - 0.60 * $H) / (0.22 * $H)}]
			set d [expr {sqrt($dx * $dx + $dy * $dy)}]
			set a [expr {$d < 0.7 ? 0.7 * (1.0 - $d / 0.7) : 0.0}]
			set r [expr {$r + ($gr - $r) * $a}]; set gc [expr {$gc + ($gg - $gc) * $a}]; set b [expr {$b + ($gb - $b) * $a}]
			# the ridge, 4 x 4 samples
			set cov 0
			if {$y + 1 > 0.30 * $H && $y < 0.63 * $H + 1} {
				foreach sy {0.125 0.375 0.625 0.875} { foreach sx {0.125 0.375 0.625 0.875} { incr cov [inside $poly [expr {$x + $sx}] [expr {$y + $sy}]] } }
			}
			set cv [expr {$cov / 16.0}]
			set r [expr {$r + ($lr - $r) * $cv}]; set gc [expr {$gc + ($lg - $gc) * $cv}]; set b [expr {$b + ($lb - $b) * $cv}]
			if {$ra > 0} { set r [expr {$r + ($gr - $r) * $ra}]; set gc [expr {$gc + ($gg - $gc) * $ra}]; set b [expr {$b + ($gb - $b) * $ra}] }
			lappend row [expr {int($r + 0.5)}] [expr {int($gc + 0.5)}] [expr {int($b + 0.5)}] 255
		}
		lappend rows $row
	}
	raster::png $W $H $rows
}

switch -- $kind {
	bands {
		set crop [expr {max(0, ($H - 900) / 2)}]
		set rows {}
		foreach {n rgb} [list $crop {192 48 48} [expr {$H - 2 * $crop}] {48 96 160} $crop {48 192 48}] {
			if {$n > 0} { lappend rows {*}[lrepeat $n [lrepeat $W {*}$rgb 255]] }
		}
		set d [raster::png $W $H $rows]
	}
	png {
		set d [string cat "\x89PNG\r\n\x1a\n" [chunk IHDR [binary format IIccccc $W $H 8 6 0 0 0]] [chunk IDAT [zlib compress [string repeat \0 64]]] [chunk IEND ""]]
	}
	jpeg {
		set d [string cat "\xff\xd8" "\xff\xe0" [binary format S 16] "JFIF\0\x01\x01\0\0\x01\0\x01\0\0" \
			"\xff\xc0" [binary format ScSSc 17 8 $H $W 3] [string repeat "\x01\x11\0" 3] "\xff\xd9"]
	}
	webp {
		set body [string cat WEBP VP8X [binary format i 10] [binary format i 0] \
			[string range [binary format i [expr {$W - 1}]] 0 2] [string range [binary format i [expr {$H - 1}]] 0 2]]
		set d [string cat RIFF [binary format i [string length $body]] $body]
	}
	default {
		if {![regexp {^photo-([a-z]+)-([0-2])$} $kind -> scene ridge]} { puts stderr "make-picture.tcl: unknown kind $kind"; exit 2 }
		set d [photo $scene $ridge $W $H]
	}
}
set fh [open $out wb]; puts -nonewline $fh $d; close $fh
