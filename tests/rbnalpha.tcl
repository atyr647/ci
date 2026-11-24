# rbnalpha.tcl - checks for the rbnalpha Tk extension (tests/run.sh):
# its C picture equals raster.tcl's to the bit, its blur is a Gaussian, and
# the rbn:: windows and widgets work (under Xvfb: no compositor, so this
# checks the X side only). Prints "ok ..." / "FAIL ..."; exits 1 on a FAIL.
set here [file dirname [file normalize [info script]]]
set files [file join $here .. srcpkgs ribbon-desktop files]
lappend auto_path $files
package require rbnalpha
source -encoding utf-8 [file join $files shell raster.tcl]
set tmp [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] rbnalpha-test-[pid]]
file mkdir $tmp
rbn::init $tmp
set fails 0
proc check {what ok} {
	if {$ok} { puts "  ok   rbnalpha: $what" } else { puts "  FAIL rbnalpha: $what"; incr ::fails }
}
check "the C library is loaded" [rbn::native]

# the same pixels as raster.tcl's pure-Tcl rrect
rename ::rbnalpha::rrect ::rbnalpha::rrect_c
raster::init $tmp/tcl
set same 1
foreach spec {
	{89 38 -fill #1D1C1B -radius 12 -ring {#3B3835 1} -shadow {6 20 0.35 #000000}}
	{60 46 -fill #1D1C1B -radius {12 12 0 0} -ring {#3B3835 1 tlr}}
	{104 108 -fill #2A2826 -radius 10 -ring {#FF7A59 1.5}}
	{2 15 -fill #FF7A59 -radius 1 -offset {0 0.5}}
} {
	lassign [raster::rrect {*}$spec] a
	set b [image create photo]
	rbnalpha::rrect_c $b {*}$spec
	if {[$a data -format png] ne [$b data -format png]} { set same 0 }
}
rename ::rbnalpha::rrect_c ::rbnalpha::rrect
check "rrect draws raster.tcl's pixels, bit for bit" $same

# blur: a flat picture stays flat, a step becomes a smooth ramp
set p [image create photo -width 400 -height 100]
$p put #204060 -to 0 0 200 100
$p put #e0c0a0 -to 200 0 400 100
set q [image create photo]
set ms [expr {[lindex [time {rbn::blur $p $q 12 -dim 50} 1] 0] / 1000.0}]
lassign [$q get 5 50] r0 g0 b0
lassign [$q get 199 50] r1
lassign [$q get 230 50] r2
check "blur keeps a flat area and dims it (-dim 50: #204060 -> [format #%02x%02x%02x $r0 $g0 $b0])" \
	[expr {abs($r0 - 16) <= 1 && abs($g0 - 32) <= 1 && abs($b0 - 48) <= 1}]
check "blur makes a step a ramp ($r0 < $r1 < $r2, [format %.1f $ms] ms)" [expr {$r0 < $r1 && $r1 < $r2 && [image width $q] == 400}]

# windows: an ARGB popup with its shadow, its canvas cut to the box
if {[rbn::argb]} {
	set cv [rbn::surface .t -fill #1D1C1B]
	rbn::box $cv 10 10 100 30 -fill #36302C -radius 8 -on #1D1C1B
	rbn::popup .t 200 200 240 160 [list -fill #1D1C1B -radius 12 -ring {#3B3835 1} -shadow {18 40 0.45 #000000}]
	update
	check "a popup's window holds its box and shadow ([winfo width .t] x [winfo height .t])" \
		[expr {[winfo width .t] == 240 + 2 * 60 && [winfo height .t] == 160 + 42 + 78 && [winfo depth .t] == 32 && [winfo depth $cv] != 32}]
	check "its canvas sits on the box ([winfo x $cv],[winfo y $cv])" [expr {[winfo x $cv] == 60 && [winfo y $cv] == 42}]
	set st [rbnalpha::stats]
	rbn::popup .t 200 200 240 160 [list -fill #1D1C1B -radius 12 -ring {#3B3835 1} -shadow {18 40 0.45 #000000}]
	set cv2 [rbn::surface .u -fill #1D1C1B]
	rbn::popup .u 600 200 240 160 [list -fill #1D1C1B -radius 12 -ring {#3B3835 1} -shadow {18 40 0.45 #000000}]
	update
	set st2 [rbnalpha::stats]
	check "two popups of one look and size share one frame (frames [dict get $st2 frames], reused [dict get $st2 reused])" \
		[expr {[dict get $st2 frames] == [dict get $st frames] && [dict get $st2 reused] > [dict get $st reused]}]
} else {
	puts "  skip rbnalpha: windows (no 32-bit visual)"
}
file delete -force $tmp
exit [expr {$fails > 0}]
