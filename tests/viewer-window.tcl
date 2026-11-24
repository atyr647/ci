# viewer-window.tcl - the Image Viewer's window as the window manager sizes it (apps/viewer/main.tcl,
# viewer::resized): it opens at the board's 1240 x 800 fitted under the shell's bars (1240 x 750 on a
# 900-high screen), that is its least size, and when it is resized (MODE resize: wm geometry, no window
# manager) or maximised through labwc (MODE labwc: _NET_WM_STATE_MAXIMIZED, the title bar's button) the
# canvas follows and the chrome keeps its board place: the title bar's menu at 16 px from the right
# edge, the edge arrows 18 px in, the toolbar 20 px above the foot and centred, the picture fitted
# between them. Under labwc the maximised window must stay inside the work area (rc.xml's margins).
#   wish8.6 -encoding utf-8 tests/viewer-window.tcl PICTURE MODE
# Prints "ok LABEL" / "FAIL LABEL", then "viewer window: all checks passed" or the count.
set pic [lindex $argv 0]
set mode [lindex $argv 1]
set argv [list $pic]
set argc 1
set root [file dirname [file dirname [file normalize [info script]]]]
source -encoding utf-8 [file join $root srcpkgs ribbon-desktop files apps viewer main.tcl]

set fails 0
proc check {label ok} {
	global fails
	if {$ok} { puts "ok $label" } else { puts "FAIL $label"; incr fails }
}
# Wait (events running) until COND holds, at most MS.
proc waitfor {cond ms} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 [list expr $cond]] && [clock milliseconds] < $end} {
		after 30 [list set ::tick 1]; vwait ::tick
	}
	uplevel #0 [list expr $cond]
}
proc hit_of {cmd} {
	foreach h $ui::hits { if {[lindex $h 4] eq $cmd} { return $h } }
	return ""
}
# The chrome at its board places for the window's size now.
proc layout {label} {
	set W $zoom::WW; set H $zoom::WH
	set win $viewer::win
	check "$label: the canvas is the window's size (${W} x $H)" \
		[expr {[winfo width $win] == $W && [winfo height $win] == $H && [winfo width $win.c] == $W && [winfo height $win.c] == $H}]
	set more [hit_of bar::toggle_menu]
	set info [hit_of viewer::toggle_info]
	check "$label: the menu 16 px from the right edge, Info beside it" [expr {$more ne "" && [lindex $more 2] == $W - 16 && $info ne "" && [lindex $info 2] == $W - 16 - 34 - 2}]
	set next [hit_of {viewer::go 1}]
	check "$label: the next arrow 18 px in, centred on the stage" [expr {$next ne "" && [lindex $next 2] == $W - 18
		&& [lindex $next 1] == $zoom::TB + ($H - $zoom::TB) / 2 - 20}]
	set rot [hit_of viewer::rotate]; set trash [hit_of viewer::trash]; set out [hit_of {viewer::zstep -1}]
	check "$label: the toolbar 20 px above the foot, centred" [expr {$rot ne "" && [lindex $rot 3] == $H - 20 - 5
		&& abs(([lindex $out 0] - 6 + [lindex $trash 2] + 6) / 2.0 - $W / 2.0) <= 1}]
	lassign $viewer::rect L T pw ph
	check "$label: the picture fitted between the title bar, the gutters and the foot" [expr {$L >= $zoom::GUT && $L + $pw <= $W - $zoom::GUT
		&& $T >= $zoom::TB && $T + $ph <= $H - $zoom::FOOT && ($L - $zoom::GUT <= 1 || $T - $zoom::TB <= 1 || ($W - $zoom::GUT - $L - $pw) <= 1)}]
}

after 200 {
	set win $viewer::win
	waitfor {[winfo ismapped $viewer::win] && [winfo height $viewer::win] > 1} 10000
	update
	set fit [rbn::fit 800]
	if {$mode eq "labwc"} {
		check "opens 1240 wide and no taller than the board's size fitted under the bars ([winfo width $win] x [winfo height $win])" [expr {[winfo width $win] == 1240 && [winfo height $win] <= $fit}]
		check "opens inside the work area (between the bars' 54 px margins)" [expr {[winfo rooty $win] >= 54 && [winfo rooty $win] + [winfo height $win] <= [winfo screenheight .] - 54}]
	} else {
		check "opens at the board's size fitted under the bars (1240 x $fit)" [expr {[winfo width $win] == 1240 && [winfo height $win] == $fit}]
	}
	check "the least size is that size" [expr {[wm minsize $win] eq [list 1240 $fit]}]
	check "resizable" [expr {[wm resizable $win] eq {1 1}}]
	layout "at the start"
	set pw0 [lindex $viewer::rect 2]
	if {$mode eq "labwc"} {
		wm attributes $win -zoomed 1
		waitfor {$zoom::WW > 1240 && ![info exists viewer::relayout]} 10000
		update
		check "maximised: wider than the board ($zoom::WW x $zoom::WH)" [expr {$zoom::WW > 1240}]
		check "maximised: inside the work area ([winfo rooty $win] to [expr {[winfo rooty $win] + $zoom::WH}])" \
			[expr {[winfo rooty $win] >= 54 && [winfo rooty $win] + $zoom::WH <= [winfo screenheight .] - 54}]
	} else {
		wm geometry $win 1400x820
		waitfor {$zoom::WW == 1400 && $zoom::WH == 820 && ![info exists viewer::relayout]} 10000
		update
		check "resized to 1400 x 820" [expr {$zoom::WW == 1400 && $zoom::WH == 820}]
	}
	layout "bigger"
	check "bigger: the picture grows" [expr {[lindex $viewer::rect 2] > $pw0}]
	# the Info panel docks at the new right edge, the stage takes the rest
	viewer::toggle_info
	update
	set rot [hit_of viewer::rotate]
	check "Info: the toolbar centred on the stage beside the panel" [expr {$rot ne "" && abs(([lindex [hit_of {viewer::zstep -1}] 0] - 6 + [lindex [hit_of viewer::trash] 2] + 6) / 2.0 - ($zoom::WW - $zoom::PW) / 2.0) <= 1}]
	viewer::toggle_info
	# only the frame of the size now is kept
	set keys [lsearch -all -inline -index 0 [lmap k [array names ::ui::frames] {lindex $k 0}] frame]
	check "only the frame of the size now is kept" [expr {[llength $keys] == 1 && [lrange [lindex $keys 0] 1 2] eq [list $zoom::WW $zoom::WH]}]
	if {[info exists ::env(VIEWER_WINDOW_SHOT)]} { catch {exec grim $::env(VIEWER_WINDOW_SHOT)} }
	puts [expr {$fails ? "viewer window: $fails checks failed" : "viewer window: all checks passed"}]
	exit [expr {$fails > 0}]
}
