# ppm-band.tcl FILE X0 Y0 X1 Y1 - the spread (standard deviation of the grey level) of a binary PPM's
# rectangle: about 0 for a flat background, well above it where something is drawn (tests/steps.d/46-shell-display.sh).
lassign $argv file x0 y0 x1 y1
set f [open $file rb]
set data [read $f]
close $f
# the header: P6, width, height, maxval, each after whitespace (no comments from grim)
if {![regexp {^P6\s+(\d+)\s+(\d+)\s+(\d+)\s} $data hdr w h max]} { puts stderr "not a binary PPM: $file"; exit 2 }
set off [string length $hdr]
set n 0; set sum 0.0; set sq 0.0
for {set y $y0} {$y < $y1 && $y < $h} {incr y} {
	set row [string range $data [expr {$off + ($y * $w + $x0) * 3}] [expr {$off + ($y * $w + $x1) * 3 - 1}]]
	binary scan $row cu* px
	foreach {r g b} $px {
		set v [expr {0.299 * $r + 0.587 * $g + 0.114 * $b}]
		set sum [expr {$sum + $v}]; set sq [expr {$sq + $v * $v}]; incr n
	}
}
if {!$n} { puts 0; exit 0 }
set m [expr {$sum / $n}]
puts [format %.1f [expr {sqrt(max(0, $sq / $n - $m * $m))}]]
