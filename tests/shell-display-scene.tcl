# shell-display-scene.tcl - RIBBON_SHELL_TEST hook (tests/steps.d/46-shell-display.sh): the shell on an X screen of
# two 1440x900 outputs side by side (Xvfb 2880x900; a stub wlr-randr on PATH lists HEADLESS-1 at 0,0 and HEADLESS-2
# at 1440,0) with display.conf "main HEADLESS-2". The bars, the dock, the power button's panel, a terminal group
# and Alt+Tab are on the main output and at its size; they move when display.conf changes (through
# `ribbon-shell-ctl display` and through the watch). Then, at that place: the tray is not lit while the power
# button's panel is open (board Power-Final-3-Open), and the dock's group count and "+N" are drawn in the text
# colours, not the accent (STYLE §1). A 60 s limit ends the run if anything waits.

set failed 0
interp bgerror {} {apply {{msg opts} { puts "  FAIL background error: [dict get $opts -errorinfo]"; exit 1 }}}
after 60000 {puts "  FAIL the display scene took more than 60 s"; exit 1}
proc ok {what} { puts "  ok   $what" }
proc bad {what why} { global failed; incr failed; puts "  FAIL $what: $why" }
proc check {what cond why} { if {$cond} { ok $what } else { bad $what $why } }

# windows as the shell scene has them, with a group of three Firefox windows
array set wm::tl {
	1 {app RibbonFiles title Downloads state act}
	2 {app foot title Terminal state {}}
	4 {app firefox title GitHub state {}}
	5 {app firefox title Docs state {}}
	7 {app firefox title Mail state {}}
}
set wm::order {1 2 4 5 7}
array set wm::ws {1 {name 1 active 1} 2 {name 2 active 0} 3 {name 3 active 0}}
set wm::wsorder {1 2 3}
wm::changed
set status::wifi on
set status::volume 0.50
set status::battery 82
set status::updates 0
set status::date "Sun 31 May"
set status::time 00:27
proc wm::send {cmd args} {}
# the terminal: its rc.xml in the test's state, labwc not asked
proc term::reload {} {}
proc term::press {chord} {}

proc conf {name} { set f [open [display::confpath] w]; puts $f "main $name"; close $f }
proc geo {w} { update; list [winfo rootx $w] [winfo rooty $w] [winfo width $w] [winfo height $w] }
proc inside {w x0 x1} { lassign [geo $w] x y ww; expr {$x >= $x0 && $x + $ww <= $x1} }
# wait (up to MS) until COND holds, then run SCRIPT
proc waitfor {cond ms script} {
	if {[uplevel #0 [list expr $cond]] || $ms <= 0} { uplevel #0 $script; return }
	after 50 [list waitfor $cond [expr {$ms - 50}] $script]
}

# what a draw puts down: boxes {canvas x w fill}, icons {canvas name colour x}, texts {canvas text colour}
set ::rec {}
rename rbn::box rbn::box_real
proc rbn::box {cv x y w h args} { lappend ::rec [list box $cv $x $w [dict get [dict merge {-fill ""} $args] -fill]]; rbn::box_real $cv $x $y $w $h {*}$args }
rename bar::icon bar::icon_real
proc bar::icon {c name size stroke colour x y {extra {}}} { lappend ::rec [list icon $c $name $colour $x]; bar::icon_real $c $name $size $stroke $colour $x $y $extra }
rename text::draw text::draw_real
proc text::draw {c x y font fill str args} { lappend ::rec [list text $c $str $fill]; text::draw_real $c $x $y $font $fill $str {*}$args }
proc recorded {kind cv} { lmap r $::rec { if {[lindex $r 0] eq $kind && [lindex $r 1] eq $cv} { lrange $r 2 end } else continue } }
proc drawn {} { set ::rec {}; bar::draw; update }
proc tray {} { lsearch -index 0 -inline $bar::placed tray }

proc main_on_2 {} {
	check "display.conf's main output is HEADLESS-2" [expr {[display::main] eq "HEADLESS-2"}] "main [display::main]"
	check "the bars take the main output's place and size" [expr {$bar::X0 == 1440 && $bar::Y0 == 0 && $bar::W == 1440 && $bar::H == 900}] "$bar::X0 $bar::Y0 $bar::W $bar::H"
	drawn
	lassign [geo .bar] x y w h
	check "the bars' window is on HEADLESS-2 only, at its width" [expr {$x == 1440 && $y == 0 && $w == 1440}] "[geo .bar]"
	check "the right bar ends 8 px from HEADLESS-2's right edge" [expr {$bar::rightx + $bar::rightw == 2880 - 8}] "$bar::rightx + $bar::rightw"
	lassign [geo .dock] x y w h
	check "the dock is at the foot of HEADLESS-2, at its width" [expr {$x == 1440 && $y + $h == 900 && $w == 1440}] "[geo .dock]"
	# the power button's panel hangs from the right bar, on the main output
	panel::show session
	update
	# the panel's box (its window reaches further, for the shadow): its right edge is the right bar's
	set bx [expr {[lindex [geo .panel] 0] + [lindex $rbn::shown(.panel,c) 0]}]
	set bw [expr {max(320, $bar::rightw)}]
	check "the power button's panel opens on HEADLESS-2, under the right bar" [expr {$bx >= 1440 && $bx + $bw == 2880 - 8}] "box at $bx, $bw wide; window [geo .panel]"
	panel::close
	# a new terminal group in the middle of the main output; Maximise fills its work area
	term::create g1
	set x $term::G(g1,x); set w $term::G(g1,w)
	check "a new terminal group opens on HEADLESS-2" [expr {$x >= 1440 && $x + $w <= 2880}] "x $x w $w"
	term::snap g1 max
	check "a maximised terminal fills HEADLESS-2 between its bars" [expr {[list $term::G(g1,x) $term::G(g1,y) $term::G(g1,w) $term::G(g1,h)] eq {1440 54 1440 792}}] \
		"[list $term::G(g1,x) $term::G(g1,y) $term::G(g1,w) $term::G(g1,h)]"
	term::snap g1 left
	check "a terminal snapped left takes HEADLESS-2's left half" [expr {$term::G(g1,x) == 1448 && $term::G(g1,w) == 708}] "x $term::G(g1,x) w $term::G(g1,w)"
	# Alt+Tab covers the main output
	alttab::build
	check "Alt+Tab is sized to and placed on HEADLESS-2" [expr {$alttab::scr eq {1440 900} && $alttab::org eq {1440 0}}] "$alttab::scr at $alttab::org"
}

proc session_panel {} {
	array set c [array get theme::c]
	# 68: with the power button's panel open the tray stays as it is with nothing open
	set panel::open session
	drawn
	lassign [tray] - tx tw
	set lit [lmap b [recorded box .bar.c] { lassign $b x w fill; if {$x == $tx && $fill eq $c(FIELD)} { set b } else continue }]
	check "power panel open: no §field box under the tray" [expr {![llength $lit]}] "$lit"
	set icons [lmap i [recorded icon .bar.c] { lassign $i name col x; if {$x >= $tx && $x < $tx + $tw} { list $name $col } else continue }]
	check "power panel open: the tray's glyphs are §muted" [expr {[llength $icons] && [lsearch -all -inline -not -index 1 [lrange $icons 0 end-1] $c(MUTED)] eq {}}] "$icons"
	check "power panel open: the tray's chevron points down" [expr {[lindex $icons end 0] eq "down"}] "$icons"
	lassign [lsearch -index 0 -inline $bar::placed power] - px
	check "power panel open: the power button is lit" [expr {[lsearch -index 0 [recorded box .bar.c] $px] >= 0}] "[recorded box .bar.c]"
	# the tray's own panel still lights the tray
	set panel::open tray
	drawn
	set lit [lmap b [recorded box .bar.c] { lassign $b x w fill; if {$x == $tx && $fill eq $c(FIELD)} { set b } else continue }]
	set icons [lmap i [recorded icon .bar.c] { lassign $i name col x; if {$x >= $tx && $x < $tx + $tw} { list $name $col } else continue }]
	check "tray panel open: the tray is lit (§field, accent glyphs, chevron up)" [expr {[llength $lit] == 1 && [lindex $icons 0 1] eq $c(ACCENT) && [lindex $icons end 0] eq "up-chev"}] "$lit $icons"
	set panel::open ""
	drawn
}

proc dock_counts {} {
	array set c [array get theme::c]
	# 221: a group's count in §muted, §fg when it is the app you are in; never the accent
	drawn
	set n [lsearch -index 0 -inline [recorded text .dock.c] 3]
	check "dock: an inactive group's count is §muted" [expr {[lindex $n 1] eq $c(MUTED)}] "$n"
	set wm::focus 5
	foreach id {1 4 5 7} { dict set wm::tl($id) state [expr {$id == 5 ? "act" : ""}] }
	wm::changed
	drawn
	set n [lsearch -index 0 -inline [recorded text .dock.c] 3]
	check "dock: the count of the group you are in is §fg" [expr {[lindex $n 1] eq $c(FG)}] "$n"
	# more apps than fit: the "+N" button's text
	for {set i 10} {$i < 60} {incr i} { set wm::tl($i) [list app com.example.Application-number-$i title t$i state {}]; lappend wm::order $i }
	wm::changed
	drawn
	set more [lsearch -inline -glob -index 0 [recorded text .dock.c] +*]
	check "dock: the overflow button's +N is §muted" [expr {$more ne "" && [lindex $more 1] eq $c(MUTED)}] "$more"
	set accent [lmap t [recorded text .dock.c] { if {[lindex $t 1] eq $c(ACCENT)} { set t } else continue }]
	check "dock: no text in the accent" [expr {![llength $accent]}] "$accent"
}

proc moved_to_1 {} {
	check "ribbon-shell-ctl display: the bars move to HEADLESS-1" [expr {$bar::X0 == 0 && [lindex [geo .bar] 0] == 0 && [lindex [geo .bar] 2] == 1440}] "X0 $bar::X0, [geo .bar]"
	check "and the dock with them" [expr {[lindex [geo .dock] 0] == 0}] "[geo .dock]"
	# back to HEADLESS-2 by the watch alone (display.conf's time and size, looked at every 2 s)
	conf HEADLESS-2
	waitfor {$bar::X0 == 1440} 6000 finish
}

proc finish {} {
	check "the watch sees display.conf change: the bars are back on HEADLESS-2" [expr {$bar::X0 == 1440 && [lindex [geo .bar] 0] == 1440}] "X0 $bar::X0, [geo .bar]"
	if {$::failed} { puts "shell display scene: $::failed failed"; exit 1 }
	puts "shell display scene: all checks passed"
	exit 0
}

after 300 {
	main_on_2
	session_panel
	dock_counts
	# Settings keeps HEADLESS-1 as the main display and tells the shell (`ribbon-shell-ctl display`, the FIFO)
	conf HEADLESS-1
	set f [open [file join [shell::runtime] ribbon-shell] {WRONLY NONBLOCK}]
	puts $f display
	close $f
	waitfor {$bar::X0 == 0} 3000 moved_to_1
}
