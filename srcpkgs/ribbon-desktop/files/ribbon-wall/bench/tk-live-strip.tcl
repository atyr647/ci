# Cost of a live backdrop: per video frame, load the top strip (W x 54 PPM,
# written by ribbon-wall into /dev/shm or $XDG_RUNTIME_DIR), composite the
# pre-rendered pill layer (RGBA, transparent around the pills) over it and
# let the canvas redisplay.
lassign $argv W frames
set H 54
wm overrideredirect . 1; wm geometry . ${W}x$H+0+0
canvas .c -width $W -height $H -highlightthickness 0 -bd 0; pack .c
# strip frames: two different PPMs so Tk really redraws
foreach k {0 1} {
	set f [open strip$k.ppm wb]
	puts -nonewline $f "P6\n$W $H\n255\n"
	puts -nonewline $f [string repeat [binary format c3 [list [expr {40 + 60*$k}] 50 60]] [expr {$W * $H}]]
	close $f
}
# pill layer: transparent with two opaque rounded-ish boxes (alpha edges)
set pills [image create photo -width $W -height $H]
$pills put #202020 -to 8 8 400 46
$pills put #202020 -to [expr {$W - 500}] 8 [expr {$W - 8}] 46
for {set x 0} {$x < $W} {incr x} { for {set y 0} {$y < $H} {incr y 3} { if {$y < 8 || $y >= 46} { $pills transparency set $x $y 1 } } }
set strip [image create photo -width $W -height $H]
set back [image create photo -width $W -height $H]
.c create image 0 0 -image $strip -anchor nw
.c create text 100 27 -text "12:34  Mon 7 Nov" -fill white -anchor w
update
set t0 [clock microseconds]
for {set i 0} {$i < $frames} {incr i} {
	$back read strip[expr {$i & 1}].ppm -format ppm
	$strip copy $back
	$strip copy $pills -compositingrule overlay
	update idletasks
}
set dt [expr {([clock microseconds] - $t0) / double($frames) / 1000}]
puts [format "W=%d: %.2f ms per strip update (%.1f%% of a core at 30 fps, %.1f%% at 60)" $W $dt [expr {$dt * 3}] [expr {$dt * 6}]]
exit
