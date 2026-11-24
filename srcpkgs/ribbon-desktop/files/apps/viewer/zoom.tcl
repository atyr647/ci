# zoom.tcl - the Image Viewer's geometry (no Tk): where the picture sits on
# the stage for each zoom mode, the zoom steps and the navigator's view.
# Viewer-Final-1-Stage (fit) and -4-Zoom (zoomed): the window is 1240 x 800,
# the title bar 68 tall, the picture fitted between the title bar and an 84 px
# foot, clear of 76 px side gutters; zoomed, it fills the stage below the title
# bar, and 100 % is the file's own pixels.
#
# Modes: fit, fill (covers the stage), one (1:1) and zoom (a custom scale S with
# the focus at CX, CY, fractions of the picture; S is display px per file px).

namespace eval zoom {
	variable WW 1240
	variable WH 800
	variable TB 68     ;# title bar
	variable GUT 76    ;# side gutters of the fitted picture (the edge arrows sit in them)
	variable FOOT 84   ;# the foot under the fitted picture (the toolbar is in it)
	variable PW 330    ;# the Info panel, docked at the right
	variable MIN 0.05
	variable MAX 8.0
	variable STEP 1.25
}

# The stage's width: the window less the Info panel when it is open.
proc zoom::sw {info} {
	variable WW; variable PW
	expr {$info ? $WW - $PW : $WW}
}

# Display px per file px for MODE on a stage SW wide.
proc zoom::scale {mode s sw nw nh} {
	variable WH; variable TB; variable FOOT; variable GUT
	switch -- $mode {
		fit { return [expr {min(double($sw - 2 * $GUT) / $nw, double($WH - $TB - $FOOT) / $nh)}] }
		fill { return [expr {max(double($sw) / $nw, double($WH - $TB) / $nh)}] }
		one { return 1.0 }
		default { return $s }
	}
}

# One axis of the picture: centred when it fits, else placed so the focus F (a
# fraction of the picture) is at the middle, and never past the viewport's edges.
proc zoom::place {v p f} {
	if {$p <= $v} { return [expr {($v - $p) / 2}] }
	set o [expr {round($v / 2.0 - $f * $p)}]
	return [expr {min(0, max($v - $p, $o))}]
}

# The picture's rectangle {L T W H} in the window: fitted in the fit box, else
# placed in the stage below the title bar.
proc zoom::rect {mode s cx cy info nw nh} {
	variable WH; variable TB; variable FOOT; variable GUT
	set sw [zoom::sw $info]
	set sc [zoom::scale $mode $s $sw $nw $nh]
	set pw [expr {max(1, round($nw * $sc))}]
	set ph [expr {max(1, round($nh * $sc))}]
	if {$mode eq "fit"} {
		set ah [expr {$WH - $TB - $FOOT}]
		return [list [expr {($sw - $pw) / 2}] [expr {$TB + ($ah - $ph) / 2}] $pw $ph]
	}
	return [list [zoom::place $sw $pw $cx] [expr {$TB + [zoom::place [expr {$WH - $TB}] $ph $cy]}] $pw $ph]
}

# The next zoom scale S one step IN (DIR 1) or OUT (DIR -1), kept within the limits.
proc zoom::step {s dir} {
	variable STEP; variable MIN; variable MAX
	set n [expr {$s * pow($STEP, $dir)}]
	return [expr {max($MIN, min($MAX, $n))}]
}

# The label of a scale: "45%".
proc zoom::label {s} {
	return "[expr {round($s * 100)}]%"
}

# The part of a picture of width PW2 at L that a stage SW wide shows, as
# fractions {f0 f1} of the picture.
proc zoom::viewport {L pw sw} {
	set f0 [expr {max(0.0, double(-$L) / $pw)}]
	set f1 [expr {min(1.0, double($sw - $L) / $pw)}]
	return [list $f0 $f1]
}
