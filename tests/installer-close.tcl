# installer-close.tcl - the window's close button (WM_DELETE_WINDOW, as the
# compositor sends it for the button and Alt+F4) while the install runs and
# after it (RIBBON_INSTALLER_SCENE=this file; tests/steps.d/91-installer.sh
# runs it with a slow fake backend and RIBBON_FAKE_MARKER). While installing
# the close asks first (the Inst-14b sheet): Keep installing (Escape, or its
# button) goes on and the backend runs to its end; on Done it quits.
# RIBBON_CLOSE_STOP=1: Stop installing instead, which ends the window and
# the backend (tests/steps.d/93-installer-dialogs.sh: no marker is made).
set here [file dirname [file normalize [info script]]]
set ::env(RIBBON_INSTALLER_FAKE) [file join $here installer-fake-backend.sh]
proc bgerror {msg} { puts stderr "$msg\n$::errorInfo"; exit 1 }
proc close_button {} { uplevel #0 [wm protocol $app::win WM_DELETE_WINDOW] }

page::probed [exec {*}[backend::cmd probe]]
ui::fset fullname "Alex Tyrone"; page::derive_user
foreach f {upass1 upass2} { ui::fset $f pw }
set page::S(encrypt) 0
page::start
puts "  [expr {$page::S(page) eq "progress" ? "ok  " : "FAIL"}] installing"
proc press {id} {
	update; page::draw_now; update
	lassign [lrange [lsearch -inline -index 0 $ui::focusables $id] 2 5] x y w h
	set x [expr {$x + $w / 2 + $ui::ox}]; set y [expr {$y + $h / 2 + $ui::oy}]
	ui::press $x $y; ui::release $x $y; update
}
proc wait_lines {n} {
	if {[llength $page::S(log)] >= 2} {
		close_button
		update; page::draw_now
		set ids [lmap f $ui::focusables { lindex $f 0 }]
		puts "  [expr {$page::S(closing) && $ids eq {stop keep} && $ui::focus eq "keep" ? "ok  " : "FAIL"}] the close button asks first: Stop installing or Keep installing ($page::S(pct)%)"
		if {[info exists ::env(RIBBON_CLOSE_STOP)]} { press stop; puts "  FAIL Stop installing did not end the window"; exit 1 }
		page::key Escape "" 0
		puts "  [expr {!$page::S(closing) && $page::S(page) eq "progress" ? "ok  " : "FAIL"}] Escape keeps installing"
		close_button
		press keep
		puts "  [expr {!$page::S(closing) && $page::S(page) eq "progress" ? "ok  " : "FAIL"}] so does Keep installing"
		after 50 [list wait_done 0]
		return
	}
	if {$n > 200} { puts "  FAIL the install printed nothing"; exit 1 }
	after 50 [list wait_lines [incr n]]
}
proc wait_done {n} {
	if {$page::S(page) eq "done"} {
		puts "  ok   the install ran to Done"
		close_button
		puts "  FAIL the close button did nothing on Done"
		exit 1
	}
	if {$page::S(err) ne ""} { puts "  FAIL the install stopped: $page::S(err)"; exit 1 }
	if {$n > 600} { puts "  FAIL the install did not finish"; exit 1 }
	after 50 [list wait_done [incr n]]
}
wait_lines 0
