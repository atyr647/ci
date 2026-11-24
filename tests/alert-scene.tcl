# alert-scene.tcl - Ribbon's alert (shell/alert.tcl) under xvfb, in wish8.6 (tests/steps.d/69-alert.sh).
# Draws boards Alert-1-Video-Long, Alert-1b-Not-Applied and Alert-2-Term-Close-Tab and compares each with its board
# crop in tests/fixtures/alert (both blurred, RMSE, 2 px inside the edge, where the window's frame draws the ring);
# checks the buttons' places against the board; then opens real alerts and answers them by click, Return and Esc,
# through -command and through alert::ask (vwait). A hard 60 s limit ends the run if anything waits.

set failed 0
interp bgerror {} {apply {{msg opts} { puts "  FAIL background error: [dict get $opts -errorinfo]"; exit 1 }}}
after 60000 {puts "  FAIL the alert checks took more than 60 s"; exit 1}
proc ok {what} { puts "  ok   $what" }
proc bad {what why} { global failed; incr failed; puts "  FAIL $what: $why" }
proc check {what cond why} { if {$cond} { ok $what } else { bad $what $why } }

set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
set tmp [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] alert-scene-[pid]]
file mkdir $tmp
set ::env(XDG_CACHE_HOME) [file join $tmp cache]
set ::env(HOME) $tmp
set sh [file join $root srcpkgs/ribbon-desktop/files/shell]
foreach f {text raster theme} { source -encoding utf-8 [file join $sh $f.tcl] }
lappend auto_path [file join $root srcpkgs/ribbon-desktop/files]
package require rbnalpha
theme::load
source -encoding utf-8 [file join $sh alert.tcl]
wm geometry . 1x1+0+0

set specs {
	alert-1-video-long {-icon film -title {This video is too long} -lines {{Dunes.mp4 is 6:12 long, more than 5 minutes}} -buttons {{ok OK}}}
	alert-1b-not-applied {-icon image -title {Not everything was applied} -lines {{login screen: permission denied} {desktop background: ribbon-wall is not running}} -buttons {{ok OK}}}
	alert-2-term-close-tab {-icon terminal -title {Close this tab?} -lines {{kit update is still running}} -buttons {{cancel Cancel} {close {Close tab}}}}
}
# the boards' boxes (dump of the boards: design/tools/gen_alerts.py)
set heights {alert-1-video-long 164 alert-1b-not-applied 182 alert-2-term-close-tab 164}

after 200 {
	set fix [file join $root tests/fixtures/alert]
	set tools [expr {[auto_execok import] ne "" && [auto_execok convert] ne "" && [auto_execok compare] ne ""}]
	foreach {name spec} $specs {
		catch {destroy .s}
		toplevel .s -borderwidth 0 -highlightthickness 0
		wm overrideredirect .s 1
		canvas .s.c -highlightthickness 0 -borderwidth 0
		pack .s.c
		lassign [alert::paint .s.c $spec] w h buttons
		.s.c configure -width $w -height $h
		wm geometry .s ${w}x$h+0+0
		update; after 300; update
		check "$name: the alert is 440 x [dict get $heights $name] as the board's" [expr {$w == 440 && $h == [dict get $heights $name]}] "${w}x$h"
		set ::btns($name) $buttons
		if {!$tools} continue
		set shot [file join $tmp $name.png]
		exec import -window [winfo id .s.c] $shot
		set iw [expr {$w - 4}]; set ih [expr {$h - 4}]
		set cb [file join $tmp $name-crop.png]; set bb [file join $tmp $name-board.png]
		exec convert $shot -crop ${iw}x$ih+2+2 +repage -blur 0x1.5 $cb
		exec convert [file join $fix $name.png] -crop ${iw}x$ih+2+2 +repage -blur 0x1.5 $bb
		catch {exec compare -metric RMSE $cb $bb null: 2>@1} out
		set rmse 1
		regexp {\(([0-9.e+-]+)\)} $out -> rmse
		check "$name matches the board (blurred RMSE $rmse)" [expr {$rmse < 0.05}] "RMSE $rmse: $out"
	}
	if {!$tools} { puts "  skip the screenshots (no import / convert / compare)" }
	destroy .s
	# the buttons where the board has them: Cancel 220.3 + 81.9, Close tab 312.2 + 99.8, both at y 109, 38 tall
	set b $::btns(alert-2-term-close-tab)
	lassign [lindex $b 0] k0 x0 y0 w0 h0
	lassign [lindex $b 1] k1 x1 y1 w1 h1
	check "Close tab is the right button, 28 from the edge, 38 tall at y 109" [expr {$k1 eq "close" && $x1 + $w1 == 412 && $y1 == 109 && $h1 == 38 && abs($w1 - 99.8) <= 1.5}] "$b"
	check "Cancel is 10 to its left" [expr {$k0 eq "cancel" && $x0 + $w0 == $x1 - 10 && abs($w0 - 81.9) <= 1.5}] "$b"
	lassign [lindex $::btns(alert-1-video-long) 0] k x y w h
	check "a refusal has one button, OK, at the right" [expr {[llength $::btns(alert-1-video-long)] == 1 && $k eq "ok" && $x + $w == 412}] "$::btns(alert-1-video-long)"

	# a real alert: -command gets the key of the button clicked
	set ::got {}
	set spec [dict get $specs alert-2-term-close-tab]
	check "alert::open shows the alert" [expr {[alert::open {*}$spec -command {lappend ::got}] && [alert::isopen]}] "isopen [alert::isopen]"
	update
	check "its window is mapped" [winfo ismapped $alert::win] "not mapped"
	check "a second alert is refused while one is open" [expr {![alert::open {*}$spec -command {lappend ::got}]}] "opened twice"
	lassign [lindex $b 1] k x y w h
	event generate $alert::win.c <ButtonRelease-1> -x [expr {$x + 10}] -y [expr {$y + 10}]
	update
	check "a click on Close tab answers close" [expr {$::got eq "close" && ![alert::isopen] && ![winfo exists $alert::win]}] "got '$::got', open [alert::isopen]"
	set ::got {}
	alert::open {*}$spec -command {lappend ::got}
	update
	event generate $alert::win.c <ButtonRelease-1> -x 5 -y 5
	update
	check "a click beside the buttons answers nothing" [expr {$::got eq "" && [alert::isopen]}] "got '$::got'"
	focus -force $alert::win; update
	event generate $alert::win <KeyPress> -keysym Escape
	update
	check "Esc answers the first button (cancel)" [expr {$::got eq "cancel" && ![alert::isopen]}] "got '$::got'"
	set ::got {}
	alert::open {*}$spec -command {lappend ::got}
	update; focus -force $alert::win; update
	event generate $alert::win <KeyPress> -keysym Return
	update
	check "Return answers the default (the last, the accent)" [expr {$::got eq "close" && ![alert::isopen]}] "got '$::got'"
	# alert::ask waits for the answer
	after 300 {
		lassign [lindex $::btns(alert-1-video-long) 0] k x y w h
		event generate $alert::win.c <ButtonRelease-1> -x [expr {$x + 5}] -y [expr {$y + 5}]
	}
	set t0 [clock milliseconds]
	set r [alert::ask {*}[dict get $specs alert-1-video-long] -modal 1]
	check "alert::ask waits for the click and returns its key" [expr {$r eq "ok" && [clock milliseconds] - $t0 >= 250}] "'$r' after [expr {[clock milliseconds] - $t0}] ms"
	check "the modal alert let go of its grab" [expr {[grab current] eq ""}] "grab [grab current]"
	# the keyboard goes back where it was (Appearance's sheet takes keys: os::key, page::key)
	toplevel .app; entry .app.e; pack .app.e; wm geometry .app 300x100+600+600
	update; after 200; focus -force .app.e; update
	after 300 {alert::answer ok}
	alert::ask {*}[dict get $specs alert-1-video-long] -modal 1
	update; after 200; update
	check "after the alert the keyboard is back where it was" [expr {[focus] eq ".app.e"}] "focus '[focus]'"
	destroy .app
	# with no -at it is centred on the X screen, or on the shell's main display when display.tcl is loaded
	alert::open {*}[dict get $specs alert-1-video-long]
	update
	set aw [winfo width $alert::win.c]; set ah [winfo height $alert::win.c]
	set sx [expr {([winfo screenwidth .] - $aw) / 2}]; set sy [expr {([winfo screenheight .] - $ah) / 2}]
	check "with no -at the alert is centred on the screen" [expr {abs([winfo rootx $alert::win.c] - $sx) <= 1 && abs([winfo rooty $alert::win.c] - $sy) <= 1}] "[winfo rootx $alert::win.c],[winfo rooty $alert::win.c] not $sx,$sy"
	alert::answer ok; update
	namespace eval ::display { proc rect {} { return {300 120 800 600} } }
	alert::open {*}[dict get $specs alert-1-video-long]
	update
	set sx [expr {300 + (800 - $aw) / 2}]; set sy [expr {120 + (600 - $ah) / 2}]
	check "in the shell it is centred on the main display (display::rect)" [expr {abs([winfo rootx $alert::win.c] - $sx) <= 1 && abs([winfo rooty $alert::win.c] - $sy) <= 1}] "[winfo rootx $alert::win.c],[winfo rooty $alert::win.c] not $sx,$sy"
	alert::answer ok; update
	rename ::display::rect {}
	# a long word (a path) is cut to the column
	set lines [alert::wrap [list "a [string repeat x 200]"] 326]
	check "a word wider than the column is cut with an ellipsis" [expr {[llength $lines] == 2 && [string index [lindex $lines 1] end] eq "…" && [text::width alert_l [lindex $lines 1]] <= 326}] "$lines"
	file delete -force $tmp
	if {$failed} { puts "alert: $failed checks failed"; exit 1 }
	puts "alert: all checks passed"
	exit 0
}
