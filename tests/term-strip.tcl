# term-strip.tcl - the terminal's Pills A tab strip (apps/term/strip.tcl) under xvfb, in wish8.6 (tests/steps.d).
# The strip is drawn at the boards' width (1240 px) for the four-tab board and the thirteen-tab board, and checked
# against the board crops in tests/fixtures/term-strip (both blurred, RMSE). The term:: callbacks are stubs that
# record their calls. A hard 60 s limit ends the run if anything waits.

set failed 0
interp bgerror {} {apply {{msg opts} { puts "  FAIL background error: [dict get $opts -errorinfo]"; exit 1 }}}
after 60000 {puts "  FAIL the strip checks took more than 60 s"; exit 1}
proc ok {what} { puts "  ok   $what" }
proc bad {what why} { global failed; incr failed; puts "  FAIL $what: $why" }
proc check {what cond why} { if {$cond} { ok $what } else { bad $what $why } }

set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
set tmp [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] term-strip-[pid]]
file mkdir $tmp
set ::env(XDG_CACHE_HOME) [file join $tmp cache]
set ::env(HOME) $tmp

# the callbacks the strip calls: record them
set ::calls {}
namespace eval term {}
proc term::activate {id} { lappend ::calls [list activate $id] }
proc term::close {id} { lappend ::calls [list close $id] }
proc term::new {} { lappend ::calls [list new] }
proc term::prefs {} { lappend ::calls [list prefs] }
proc term::wctl {kind} { lappend ::calls [list wctl $kind] }
proc term::move_start {X Y} { lappend ::calls [list move_start $X $Y] }
proc term::move_drag {X Y} { lappend ::calls [list move_drag $X $Y] }
proc term::move_end {X Y} { lappend ::calls [list move_end $X $Y] }

source -encoding utf-8 [file join $root srcpkgs/ribbon-desktop/files/apps/term/strip.tcl]

# the boards' tabs (design/tools/gen_term_fp.py TABS, MANY; gen_term_g.py Pills A)
proc tab {id name active activity} { dict create id $id num $id name $name active $active activity $activity }
set four [list [tab 1 ~/src/ribbon 1 0] [tab 2 htop 0 0] [tab 3 pi@kitchen 0 0] [tab 4 {kit update} 0 1]]
set many [list [tab 1 ~/src/ribbon 0 0] [tab 2 htop 0 0] [tab 3 pi@kitchen 0 0] [tab 4 {kit update} 0 1] \
	[tab 5 {journalctl -f} 0 1] [tab 6 make 1 0] [tab 7 {nvim rc.xml} 0 0] [tab 8 ~/Downloads 0 0] \
	[tab 9 {ssh nas} 0 0] [tab 10 {man foot.ini} 0 0] [tab 11 python3 0 0] \
	[tab 12 {cargo build --release} 0 0] [tab 13 {tail -f /var/log/socklog/everything/current} 0 0]]
set state {maximized 0 focused 1}
set W 1240

canvas .cv -width $W -height [strip::height] -highlightthickness 0 -borderwidth 0
pack .cv
wm geometry . +0+0
proc redraw {tabs} { strip::draw .cv $::W $tabs $::state; update }

# the strip's pills, in order: {id x0 x1 folded}, and the other hits by kind
proc pills {} {
	set out {}
	foreach h $strip::hits {
		lassign $h x0 y0 x1 y1 kind id
		if {$kind eq "activate"} { lappend out [list $id $x0 $x1 [expr {$x1 - $x0 == 28}]] }
	}
	set out
}
proc hits_of {kind} {
	set out {}
	foreach h $strip::hits { lassign $h x0 y0 x1 y1 k id; if {$k eq $kind} { lappend out $h } }
	set out
}
proc center {x0 x1} { expr {($x0 + $x1) / 2} }
# a colour at (x, y) of the strip's photo
proc hex {rgb} { lassign $rgb r g b; format #%02X%02X%02X $r $g $b }
proc pixel {x y} { hex [$strip::img(.cv) get $x $y] }
# canvas text items: the strings drawn
proc texts {} {
	set out {}
	foreach i [.cv find all] { if {[.cv type $i] eq "text"} { lappend out [.cv itemcget $i -text] } }
	set out
}
proc clicks {script} { set ::calls {}; uplevel 1 $script; return $::calls }

after 200 {
	redraw $::four
	set pl [pills]
	check "the four-tab strip has four pills, in order" [expr {[lmap p $pl {lindex $p 0}] eq {1 2 3 4}}] "$pl"
	check "the strip is 42 px tall" [expr {[strip::height] == 42}] "[strip::height]"
	check "the four tabs are not folded" [expr {[lmap p $pl {lindex $p 3}] eq {0 0 0 0}}] "$pl"
	check "the pills are 28 px tall in the strip's 42" [expr {[.cv cget -height] == 42}] "[.cv cget -height]"

	# the current pill is raised: its × is in the strip and its name is drawn in the fg colour
	set closes [hits_of close]
	check "the current pill has its x (and only it, the x)" [expr {[llength $closes] == 1 && [lindex $closes 0 5] eq "1"}] "$closes"
	check "the current name is drawn" [expr {[lsearch -exact -index 0 $strip::drawn {~/src/ribbon}] >= 0}] "$strip::drawn"
	set cur [lindex $pl 0]
	set inpill [pixel [expr {[lindex $cur 1] + 14}] 10]
	check "the current pill is filled with the pill colour" [expr {$inpill eq [string toupper $::theme::c(PILL)]}] "pixel $inpill, pill $::theme::c(PILL)"
	set other [lindex $pl 1]
	check "an inactive pill has no fill" [expr {[pixel [expr {[lindex $other 1] + 14}] 10] eq [string toupper $::theme::c(DESK_BOTTOM)]}] "pixel [pixel [expr {[lindex $other 1] + 14}] 10]"

	# the activity dot: on pill 4 (kit update) only, 6 px in accent, 18 px in from its right edge
	set p4 [lindex $pl 3]
	set dotx [expr {[lindex $p4 2] - 15}]
	check "the activity dot is accent on the pill with new output" [expr {[pixel $dotx 21] eq [string toupper $::theme::c(ACCENT)]}] "pixel [pixel $dotx 21]"
	set p2 [lindex $pl 1]
	check "no dot on a pill without new output" [expr {[pixel [expr {[lindex $p2 2] - 15}] 21] ne [string toupper $::theme::c(ACCENT)]}] "pixel [pixel [expr {[lindex $p2 2] - 15}] 21]"

	# + after the tabs, then the right end's controls
	set plus [hits_of new]
	check "+ comes after the last pill" [expr {[lindex $plus 0 0] > [lindex $p4 2]}] "$plus vs [lindex $p4 2]"

	# clicks: each calls the right callback with the right arguments
	set c [clicks {
		strip::press [expr {[center {*}[lrange [lindex $pl 1] 1 2]]}] 21 0 0 }]
	check "a click on pill 2 activates tab 2" [expr {$c eq {{activate 2}}}] "calls $c"
	set cl [lindex $closes 0]
	set c [clicks { strip::press [expr {[lindex $cl 0] + 9}] 21 0 0 }]
	check "a click on the current pill's x closes tab 1" [expr {$c eq {{close 1}}}] "calls $c"
	set c [clicks { strip::middle [expr {[lindex $pl 2 1] + 14}] 21 }]
	check "a middle click on pill 3 closes tab 3" [expr {$c eq {{close 3}}}] "calls $c"
	set c [clicks { strip::press [expr {[lindex $plus 0 0] + 14}] 21 0 0 }]
	check "a click on + calls term::new" [expr {$c eq {new}}] "calls $c"
	set c [clicks { strip::press [expr {[lindex [hits_of prefs] 0 0] + 15}] 21 0 0 }]
	check "a click on the preferences icon calls term::prefs" [expr {$c eq {prefs}}] "calls $c"
	foreach {k} {minimize maximize close} {
		set h [lindex [hits_of wctl] [lsearch -index 5 [hits_of wctl] $k]]
		set c [clicks { strip::press [expr {[lindex $h 0] + 15}] 21 0 0 }]
		check "the $k control calls term::wctl $k" [expr {$c eq [list [list wctl $k]]}] "calls $c"
	}
	set c [clicks { strip::press 600 20 1000 500; strip::motion 1010 520; strip::release 1012 530 }]
	check "a press on empty space starts a move, then drag and release" \
		[expr {$c eq {{move_start 1000 500} {move_drag 1010 520} {move_end 1012 530}}}] "calls $c"
	set c [clicks { strip::double 600 20 1000 500 }]
	check "a double-click on empty space maximises" [expr {$c eq {{wctl maximize}}}] "calls $c"

	# the real bindings: a click on pill 2 through the canvas (the window is mapped by now)
	update
	set c [clicks {
		event generate .cv <ButtonPress-1> -x [expr {[center {*}[lrange [lindex $pl 1] 1 2]]}] -y 21
		update }]
	check "a canvas click on pill 2 is bound to term::activate 2" [expr {$c eq {{activate 2}}}] "calls $c"

	# the screenshot against the board, both blurred (as tests/shell-bar.tcl does)
	set fix [file join $root tests/fixtures/term-strip]
	if {[auto_execok import] ne "" && [auto_execok convert] ne "" && [auto_execok compare] ne ""} {
		foreach {name board} [list tabs pills-a-1-tabs many pills-a-2-many] {
			set tabsl [expr {$name eq "tabs" ? $::four : $::many}]
			redraw $tabsl
			set shot [file join $tmp $name.png]
			exec import -window [winfo id .cv] $shot
			set crop [file join $tmp $name-crop.png]
			exec convert $shot -crop ${::W}x42+0+0 +repage $crop
			set bb [file join $tmp $name-board-blur.png]
			set cb [file join $tmp $name-crop-blur.png]
			exec convert [file join $fix $board.png] -blur 0x1.5 $bb
			exec convert $crop -blur 0x1.5 $cb
			set r [catch {exec compare -metric RMSE $cb $bb null: 2>@1} out]
			set rmse 1
			regexp {\(([0-9.e+-]+)\)} $out -> rmse
			check "the $name strip matches the board (blurred RMSE $rmse)" [expr {$rmse < 0.05}] "RMSE $rmse: $out"
		}
	} else {
		puts "  skip the strip's screenshots (no import / convert / compare)"
	}

	file delete -force $tmp
	if {$failed == 0} { puts "term-strip: all checks passed" } else { puts "term-strip: $failed failed"; exit 1 }
	exit 0
}
