# shell-alttab.tcl - the Alt+Tab switcher's data and grid (U17), with no display:
#   tclsh tests/shell-alttab.tcl
# The grid table comes from an independent reference written from STYLE §21 (not from
# mod-alttab.tcl); the hand-worked cases are worked out on paper in the comments. The
# app list is driven by a scripted ribbon-shell-watch stream through wm::read.
set here [file dirname [file normalize [info script]]]
set shell [file join $here .. srcpkgs ribbon-desktop files shell]

set fails 0
proc check {name ok} {
	global fails
	if {$ok} { puts "  ok   $name" } else { puts "  FAIL $name"; incr fails }
}

# the shell pieces these procs call, without the shell
namespace eval shell { proc verb {name proc} { variable made; lappend made $name } }
namespace eval panel { proc close {} {} }
namespace eval apps {
	proc label {app} { return "L:$app" }
	proc iconfor {a {appid ""}} { return grid }
	proc forwindow {appid} { return "" }
}
proc shell::refresh {} {}
namespace eval wm {}
proc wm::start {} {}
source [file join $shell wm.tcl]
source [file join $shell mod-alttab.tcl]

set oracle {
		1 1 1 1 300 188
		2 1 2 1 300 188
		3 1 3 1 300 188
		4 1 4 1 300 188
		5 1 5 1 243 152
		6 2 3 2 300 188
		7 2 4 2 300 188
		8 2 4 2 300 188
		9 2 5 2 243 152
		10 2 5 2 243 152
		11 3 4 3 300 188
		12 3 4 3 300 188
		13 3 5 3 243 152
		14 3 5 3 243 152
		15 3 5 3 243 152
		16 3 5 4 243 152
		17 3 5 4 243 152
		18 3 5 4 243 152
		19 3 5 4 243 152
		20 3 5 4 243 152
		21 3 5 5 243 152
		22 3 5 5 243 152
		23 3 5 5 243 152
		24 3 5 5 243 152
		25 3 5 5 243 152
		26 3 5 6 243 152
		27 3 5 6 243 152
		28 3 5 6 243 152
		29 3 5 6 243 152
		30 3 5 6 243 152
		31 3 5 7 243 152
		32 3 5 7 243 152
		33 3 5 7 243 152
		34 3 5 7 243 152
		35 3 5 7 243 152
		36 3 5 8 243 152
		37 3 5 8 243 152
		38 3 5 8 243 152
		39 3 5 8 243 152
		40 3 5 8 243 152
}
set fanoracle {
		6 2 3 2 294 184
		7 2 4 2 294 184
		9 2 5 2 243 152
		11 3 4 3 294 184
		13 3 5 3 243 152
		16 3 5 4 243 152
}

# 1. the grid, n = 1..40, against the reference
foreach {n rows cols nrow cw ch} $oracle {
	set s [alttab::shape $n]
	set got [list [dict get $s rows] [dict get $s cols] [dict get $s nrow] [dict get $s cw] [dict get $s ch]]
	check "grid n=$n is $rows x $cols, $cw x $ch" [expr {$got eq [list $rows $cols $nrow $cw $ch]}]
	if {$got ne [list $rows $cols $nrow $cw $ch]} { puts "       got $got want [list $rows $cols $nrow $cw $ch]" }
}

# 2. with a fanned well (the row of the stack): the well is one more line
foreach {n rows cols nrow cw ch} $fanoracle {
	set s [alttab::shape $n 0]
	set got [list [dict get $s cw] [dict get $s ch]]
	check "fan n=$n row 0 is $cw x $ch" [expr {$got eq [list $cw $ch]}]
}

# 3. hand-worked: six apps, 3 + 3, cells 300 x 188 (187.5 rounds to 188 on the even).
#    Lines: row 0 at y 0, row 1 at 188 + 10 + 26 + 28 = 252. Band 252 + 188 + 36 = 476 tall,
#    top = 450 - 238 = 212. Grid width 3*300 + 48 = 948, left = 720 - 474 = 246.
set g [alttab::place 6 -1 -1 0 1440 900 0]
check "six apps: cards at x 246 570 894" [expr {[lsort -integer [lmap c [dict get $g cards] {lindex $c 1}]] eq {246 246 570 570 894 894}}]
check "six apps: top row at y 212, second at 464" [expr {[lsort -unique -integer [lmap c [dict get $g cards] {lindex $c 2}]] eq {212 464}}]
check "six apps: no overflow, no arrows" [expr {[dict get $g cutTop] < 0 && [dict get $g up] < 0 && [dict get $g down] < 0}]

# 4. hand-worked: 22 apps (2-Many). Five across, five rows of 152 cell + 64 pitch: lines 0..4
#    at 0, 216, 432, 648, 864 (the pitch is 152 + 64). Three show from first 0:
#    block = 432 + 152 + 36 = 620, top = 450 - 310 = 140, cut above at 116, the arrow
#    below at 140 + 620 + 68 + 8 = 836 (76 under the three rows), none above.
set g [alttab::place 22 -1 -1 0 1440 900 0]
check "22 apps: three rows shown, top 140" [expr {[dict get $g top] == 140}]
check "22 apps: cut above at 116, below at 828" [expr {[dict get $g cutTop] == 116 && [dict get $g cutBottom] == 828}]
check "22 apps: down arrow at 836, no up arrow" [expr {[dict get $g down] == 836 && [dict get $g up] < 0}]
# scrolled: the sixth line (index 4) chosen. Stepping one line at a time keeps it visible.
set g [alttab::place 22 -1 -1 0 1440 900 2]
check "22 apps: first 2 shows lines 2..4, up arrow" [expr {[dict get $g first] == 2 && [dict get $g up] > 0}]

# 5. follow: the first line moves only when the choice leaves the shown lines
set alttab::first 0
alttab::follow 5 1; check "follow: a choice inside keeps first 0" [expr {$alttab::first == 0}]
alttab::follow 5 3; check "follow: choice at the fourth line scrolls one" [expr {$alttab::first == 1}]
alttab::follow 5 1; check "follow: back within shown keeps 1" [expr {$alttab::first == 1}]
alttab::follow 5 0; check "follow: going above scrolls to it" [expr {$alttab::first == 0}]
alttab::follow 3 2; check "follow: three lines never scroll" [expr {$alttab::first == 0}]

# 6. the app list from a scripted ribbon-shell-watch stream, through wm::read
set stream {
T+ 1
T 1 app firefox
T 1 state -
T 1 done
T+ 2
T 2 app terminal
T 2 state act
T 2 mru 1
T 2 done
T+ 3
T 3 app firefox
T 3 state act
T 3 mru 2
T 3 done
T+ 4
T 4 app files
T 4 state -
T 4 done
T+ 5
T 5 app firefox
T 5 state -
T 5 done
T+ 6
T 6 app ribbon-shell-watch
T 6 state act
T 6 mru 3
T 6 done
ready
}
# the second stream: terminal is used again, then files, so files leads
set stream2 {
T+ 1
T 1 app terminal
T 1 state act
T 1 mru 1
T 1 done
T+ 2
T 2 app files
T 2 state -
T 2 done
T+ 3
T 3 app terminal
T 3 state -
T 3 done
T 2 state act
T 2 mru 2
T 2 done
T 1 state -
T 1 done
T 3 state act
T 3 mru 3
T 3 done
}
namespace eval wm { variable snap {} }
proc wm::changed {} {
	if {[array size wm::tl] == 0} return
	set wm::snap [lmap a [alttab::collect] {dict create app [dict get $a app] ids [dict get $a ids]}]
}
proc feed {text} {
	set f [file tempfile fn]
	puts $f [string trim $text]
	close $f
	set fh [open $fn r]
	set wm::chan $fh
	array unset wm::tl; set wm::order {}
	wm::read
	catch {close $fh}
	file delete $fn
	return $wm::snap
}
set got [feed $stream]
set want {{app firefox ids {3 1 5}} {app terminal ids 2} {app files ids 4}}
check "grouping: apps most recent first, the shell left out" [expr {[llength $got] == 3 && $got eq $want}]
if {$got ne $want} { puts "       got $got" }

set got [feed $stream2]
set want {{app terminal ids {3 1}} {app files ids 2}}
check "grouping: the app used last leads, its windows in use order" [expr {$got eq $want}]
if {$got ne $want} { puts "       got $got" }

# 6b. two terminal groups' tabs (ribbon-term-GROUP-N) are one ribbon-terminal card, all its windows in it
set stream3 {
T+ 1
T 1 app ribbon-term-g1-1
T 1 state -
T 1 done
T+ 2
T 2 app ribbon-term-g1-2
T 2 state act
T 2 mru 1
T 2 done
T+ 3
T 3 app ribbon-term-g2-1
T 3 state -
T 3 done
}
set got [feed $stream3]
set want {{app ribbon-terminal ids {2 1 3}}}
check "alt-tab: tabs of a terminal are one card (ribbon-term-g1-N windows give one card)" [expr {$got eq $want}]
if {$got ne $want} { puts "       got $got" }

# 8. keys on the grid (U19): arrows, the well, W and Q, with no display (draw does nothing until shown)
namespace eval theme { variable c; array set c {} }
proc fakeapps {n} { set a {}; for {set i 0} {$i < $n} {incr i} { lappend a [dict create app a$i label a$i ids [list [expr {$i * 10 + 1}] [expr {$i * 10 + 2}]]] }; return $a }
proc alttab::draw {} {}
set alttab::apps [fakeapps 7]; set alttab::on 1; set alttab::shown 1   ;# 7 apps: 2 rows of 4, a short last row
set sent {}
proc wm::send {cmd args} { lappend ::sent $cmd }
set alttab::sel 0; alttab::move 0 1
check "arrows: down moves a row (4 columns)" [expr {$alttab::sel == 4}]
alttab::move 0 1
check "arrows: down in the last row stays" [expr {$alttab::sel == 4}]
set alttab::sel 3; alttab::move 0 1
check "arrows: down into a short last row goes to its last card" [expr {$alttab::sel == 6}]
alttab::move 0 -1
check "arrows: up goes back a row" [expr {$alttab::sel == 2}]
set alttab::sel 0; alttab::move -1 0
check "arrows: left does not wrap" [expr {$alttab::sel == 0}]
set alttab::sel 6; alttab::move 1 0
check "arrows: right does not wrap" [expr {$alttab::sel == 6}]
set alttab::sel 3; alttab::fan
check "grave: opens the well on the second window" [expr {$alttab::fan && $alttab::fanwin == 1}]
alttab::key grave
check "grave: in the well it moves window by window, wrapping" [expr {$alttab::fanwin == 0}]
check "return target: the chosen window in the well" [expr {[alttab::target] == 31}]
set alttab::on 1; alttab::kill window
check "W: closes the chosen window of the well" [expr {$sent eq {{close 31}} && [llength [dict get [lindex $alttab::apps 3] ids]] == 1 && !$alttab::fan}]
set sent {}; alttab::kill app
check "Q: closes every window of the app and drops its card" [expr {$sent eq {{close 32}} && [llength $alttab::apps] == 6 && $alttab::sel == 3}]

# 9. motion (U18): the scroll eases 160 ms; ghosts take the board's numbers; a fullscreen tag; clicks
set alttab::fake 5000
set alttab::first 0; set alttab::pos_from 0; set alttab::pos_t0 0; set alttab::maxfirst 5
alttab::setfirst 2
set alttab::fake 5080
check "scroll: halfway at 80 ms (smoothstep 0.5)" [expr {abs([alttab::curpos] - 1.0) < 1e-9}]
set alttab::fake 5160
check "scroll: arrived at 160 ms" [expr {abs([alttab::curpos] - 2.0) < 1e-9}]
set alttab::fake ""
# the lift: 98 % of a card up, 84 %, opacity 34 % to nothing over 140 ms
set g [dict create kind lift rect {100 200 300 188} t0 0 dur 140 id 1 icon grid]
set q [alttab::ghost_pose $g 0]
check "lift: starts where the card is, opacity 34 %" [expr {[dict get $q y] == 200 && [dict get $q a] > 0.339 && [dict get $q a] < 0.341}]
set q [alttab::ghost_pose $g 140]
# 188 * 0.84 = 158; the card's 98 % lift is 184.24 from 200, the 15 centring the 84 % size: 200 + 15 - 184.24 -> 31
check "lift: ends 98 % of the card up, at 84 %, invisible" [expr {[dict get $q w] == 252 && [dict get $q h] == 158 && [dict get $q y] == 31 && [dict get $q a] == 0.0}]
set q [alttab::ghost_pose [dict create kind shrink rect {0 0 300 188} t0 0 dur 140] 140]
check "shrink: 92 % and fades to nothing" [expr {[dict get $q w] == 276 && [dict get $q a] == 0.0}]
# a click on a card goes to it; an arrow moves the grid one line
set alttab::on 1
set alttab::hits {}
lappend alttab::hits {10 10 300 188 card 0}
lappend alttab::hits {400 10 300 188 card 1}
set sent {}
proc alttab::finish {activate} { lappend ::sentclick [list $activate $alttab::sel] }
set ::sentclick {}
alttab::click 450 50
check "click: a card goes to that app and activates it" [expr {$::sentclick eq {{1 1}}}]
set ::sentclick {}
alttab::click 5 5
check "click: outside every target does nothing" [expr {$::sentclick eq {}}]
set alttab::on 0
set ::wm::tl(77) [dict create app game title g state {full,act} mru 1]
check "tag: a fullscreen window reads Fullscreen, not its count" [expr {[alttab::tagtext 77 3] eq "Fullscreen"}]
check "tag: a stack reads its count" [expr {[alttab::tagtext 78 3] eq "3"}]
check "tag: one window has none" [expr {[alttab::tagtext 78 1] eq ""}]

# 7. the verb is registered
check "switcher verb is registered" [expr {"switcher" in $shell::made}]

# 8. the two times: the switcher shows inside the tap window (U20)
check "reveal comes before the end of the tap window" [expr {$alttab::revealms > 0 && $alttab::revealms < $alttab::tapms}]

puts [expr {$fails ? "$fails failed" : "all checks passed"}]
exit [expr {$fails ? 1 : 0}]
