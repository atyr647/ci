# term-resize.tcl - RIBBON_SHELL_TEST hook (tests/steps.d/46-shell-display.sh): a terminal group is resized by its
# strip's edges (docs/TERMINAL.md §3.3.2; no grip is drawn, so nothing is added to the boards). The strip is the
# group's top edge: its top 4 px, its outer 6 px at either end and the two top corners take a resize, with a resize
# cursor; a drag goes through term::setrect, so the runtime rc.xml carries the new MoveTo/ResizeTo. The opposite
# edges stay put, the group keeps its least size, and a maximised group is not resized. labwc is not asked
# (term::reload and term::press are stubs); a 60 s limit ends the run if anything waits.

set failed 0
interp bgerror {} {apply {{msg opts} { puts "  FAIL background error: [dict get $opts -errorinfo]"; exit 1 }}}
after 60000 {puts "  FAIL the resize checks took more than 60 s"; exit 1}
proc ok {what} { puts "  ok   $what" }
proc bad {what why} { global failed; incr failed; puts "  FAIL $what: $why" }
proc check {what cond why} { if {$cond} { ok $what } else { bad $what $why } }

proc term::reload {} {}
proc term::press {chord} {}
proc wm::send {cmd args} {}

proc rect {} { list $term::G(g1,x) $term::G(g1,y) $term::G(g1,w) $term::G(g1,h) }
proc rc {} { set f [open $::env(RIBBON_TERM_RC)]; set t [read $f]; close $f; return $t }
# press on the strip at x y (strip coordinates), drag by dx dy, release: as the canvas bindings do
proc drag {x y dx dy} {
	set cv $term::G(g1,top).c
	update
	set X [expr {[winfo rootx $cv] + $x}]; set Y [expr {[winfo rooty $cv] + $y}]
	set term::active g1
	strip::press $x $y $X $Y
	strip::motion [expr {$X + $dx}] [expr {$Y + $dy}]
	strip::release [expr {$X + $dx}] [expr {$Y + $dy}]
	update
}

after 300 {
	term::create g1
	term::redraw g1
	update
	set cv $term::G(g1,top).c
	set w $term::G(g1,w)
	# the edges, by what they hit
	check "the strip's left end takes a resize of the left edge" [expr {[strip::hit 2 20] eq {resize l}}] [strip::hit 2 20]
	check "the strip's right end takes a resize of the right edge" [expr {[strip::hit [expr {$w - 2}] 20] eq {resize r}}] [strip::hit [expr {$w - 2}] 20]
	check "the strip's top takes a resize of the top edge" [expr {[strip::hit 400 1] eq {resize t}}] [strip::hit 400 1]
	check "the top corners resize both ways" [expr {[strip::hit 1 1] eq {resize tl} && [strip::hit [expr {$w - 1}] 1] eq {resize tr}}] "[strip::hit 1 1] [strip::hit [expr {$w - 1}] 1]"
	check "the close button and the + keep their clicks" [expr {[lindex [strip::hit [expr {$w - 8 - 15}] 21] 0] eq "wctl" && [lindex [strip::hit 20 21] 0] eq "new"}] "[strip::hit [expr {$w - 8 - 15}] 21] [strip::hit 20 21]"
	check "the strip between its edges still moves the group" [expr {[strip::hit 600 21] eq {empty {}}}] [strip::hit 600 21]
	# the cursor: a resize one on an edge, the plain one elsewhere
	strip::hover $cv [expr {$w - 2}] 20
	set c1 [$cv cget -cursor]
	strip::hover $cv 1 1
	set c2 [$cv cget -cursor]
	strip::hover $cv 600 30
	set c3 [$cv cget -cursor]
	check "the pointer shows a resize cursor on the edges and the plain one elsewhere" [expr {$c1 eq "right_side" && $c2 eq "top_left_corner" && $c3 eq ""}] "$c1 / $c2 / {$c3}"

	# dragging the right end 120 px right widens the group; its left edge stays
	lassign [rect] x0 y0 w0 h0
	drag [expr {$w0 - 2}] 20 120 30
	check "dragging the right end widens the group by the drag, the left edge stays" [expr {[rect] eq [list $x0 $y0 [expr {$w0 + 120}] $h0]}] "[rect] from $x0 $y0 $w0 $h0"
	update
	check "the strip window follows" [expr {[winfo width $term::G(g1,top)] == $w0 + 120}] "[winfo width $term::G(g1,top)]"
	check "the rc.xml resizes the tabs (ResizeTo with the new width)" [string match "*ResizeTo\" width=\"[expr {$w0 + 120}]\"*" [rc]] [rc]
	# the left end: the right edge stays
	lassign [rect] x0 y0 w0 h0
	drag 2 20 -80 0
	check "dragging the left end 80 px left widens the group to the left, the right edge stays" [expr {[rect] eq [list [expr {$x0 - 80}] $y0 [expr {$w0 + 80}] $h0]}] "[rect] from $x0 $y0 $w0 $h0"
	# the top: the bottom stays
	lassign [rect] x0 y0 w0 h0
	drag 400 1 0 -50
	check "dragging the top 50 px up makes the group taller, its foot stays" [expr {[rect] eq [list $x0 [expr {$y0 - 50}] $w0 [expr {$h0 + 50}]]}] "[rect] from $x0 $y0 $w0 $h0"
	check "the rc.xml places the tabs under the moved strip" [string match "*MoveTo\" x=\"[expr {$x0}]\" y=\"[expr {$y0 - 50 + $term::STRIP}]\"*ResizeTo\" width=\"$w0\" height=\"[expr {$h0 + 50 - $term::STRIP}]\"*" [rc]] [rc]
	# the top right corner, far in: the least size
	lassign [rect] x0 y0 w0 h0
	drag [expr {$w0 - 1}] 1 -2000 2000
	check "the group keeps its least size (480 x 240), anchored at its bottom left" [expr {[rect] eq [list $x0 [expr {$y0 + $h0 - 240}] 480 240]}] "[rect] from $x0 $y0 $w0 $h0"
	# maximised: the edges do nothing
	term::snap g1 max
	set r [rect]
	update
	drag [expr {$term::G(g1,w) - 2}] 20 -100 0
	check "a maximised group is not resized" [expr {[rect] eq $r}] "[rect], was $r"

	if {$failed} { puts "term resize: $failed failed"; exit 1 }
	puts "term resize: all checks passed"
	exit 0
}
