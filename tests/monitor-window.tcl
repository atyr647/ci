# monitor-window.tcl - the System monitor's window as the window manager sizes it (apps/monitor/main.tcl,
# monitor::resized), on the live sampler: it opens at the board's 1240 x 760 fitted under the shell's bars (1240 x 750
# on a 900-high screen), that is its least size, and when it is resized (MODE resize: wm geometry, no window manager)
# or maximised through labwc (MODE labwc) the canvas follows and the page keeps the board's places from its right
# edge: Search, the Apps/Processes switch, the columns (no Network column: per-app network has no source), the rows
# as wide as the page; the rail's foot 16 px above the window's foot; on the GPU page the span switch at the right
# edge and the apps' and the card's columns sharing the room. The rail's Network row is not a button.
#   wish8.6 -encoding utf-8 tests/monitor-window.tcl MODE
# Prints "ok LABEL" / "FAIL LABEL", then "monitor window: all checks passed" or the count.
set mode [lindex $argv 0]
set argv {}
set argc 0
set root [file dirname [file dirname [file normalize [info script]]]]
source -encoding utf-8 [file join $root srcpkgs ribbon-desktop files apps monitor main.tcl]

set fails 0
proc check {label ok} {
	global fails
	if {$ok} { puts "ok $label" } else { puts "FAIL $label"; incr fails }
}
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
proc seg_hit {script k} {
	foreach h $ui::hits {
		set p [lindex $h 4]
		if {[lindex $p 0] eq "apply" && [lindex $p 2] eq $script && [lindex $p 3] eq $k} { return $h }
	}
	return ""
}
# The page at the window's size now: the Apps page, then the GPU page.
proc layout {label} {
	set W $monitor::W; set H $monitor::H; set dx [expr {$W - 1240}]
	set win $monitor::win
	check "$label: the canvas is the window's size (${W} x $H)" \
		[expr {[winfo width $win] == $W && [winfo height $win] == $H && [winfo width $win.c] == $W && [winfo height $win.c] == $H}]
	set monitor::metric apps; set monitor::view apps
	monitor::draw
	set p [seg_hit monitor::set_view processes]
	check "$label: the Apps/Processes switch ends 40 px from the right edge" [expr {$p ne "" && abs([lindex $p 2] - ($W - 40)) <= 4}]
	set disk [hit_of {monitor::sort_by disk}]; set cpu [hit_of {monitor::sort_by cpu}]
	check "$label: the columns keep the board's places from the right edge (Disk ends at [expr {1010 + $dx}])" \
		[expr {$disk ne "" && [lindex $disk 2] == 1010 + $dx && $cpu ne "" && [lindex $cpu 2] == 748 + $dx}]
	check "$label: no Network column" [expr {[hit_of {monitor::sort_by net}] eq "" && "net" ni [lmap c $monitor::app_cols {lindex $c 0}]}]
	set rows [lsearch -all -inline -index 4 -glob $ui::hits {monitor::select *}]
	check "$label: the rows are as wide as the page ([expr {912 + $dx}])" [expr {[llength $rows] && [lindex $rows 0 2] - [lindex $rows 0 0] == 912 + $dx}]
	check "$label: rows down to the window's foot" [expr {[llength $rows] >= min([llength [monitor::rows $monitor::model]], ($H - 153) / 40)}]
	# the rail's foot: the game card, 16 px above the window's foot
	set m $monitor::model
	set monitor::model [dict replace $m game [dict create pid 1 name Game secs 60]]
	monitor::draw
	set f [hit_of monitor::hud_compact]
	check "$label: the rail's foot 16 px above the window's foot" [expr {$f ne "" && [lindex $f 3] == $H - 16}]
	set monitor::model $m
	# the GPU page, with a card (this machine may have none)
	set m $monitor::model
	dict set monitor::model card [dict create driver amdgpu name "Radeon RX 7900 XT" busy 97 vram_used 1e9 vram_total 2e10 \
		temp 71 hot 88 fan 1650 power 284 cap 315 clock 2540 mclock 2500 bus "PCIe 4.0" dir ""]
	set monitor::metric gpu
	monitor::draw
	if {1} {
		set s [seg_hit monitor::set_span 3600]
		check "$label: GPU page: the span switch ends 40 px from the right edge" [expr {$s ne "" && abs([lindex $s 2] - ($W - 40)) <= 4}]
		set v [hit_of {monitor::gsort_by vram}]
		check "$label: GPU page: the apps' VRAM column moves by half the extra width" [expr {$v ne "" && [lindex $v 2] == 726 + $dx / 2}]
	}
	set monitor::model $m
	set monitor::metric apps
	monitor::draw
}

after 300 {
	set win $monitor::win
	waitfor {[winfo ismapped $monitor::win] && [winfo height $monitor::win] > 1 && [dict size $monitor::model]} 15000
	after cancel $monitor::timer
	update
	set fit [rbn::fit 760]
	if {$mode eq "labwc"} {
		check "opens 1240 wide, no taller than the board's size fitted under the bars ([winfo width $win] x [winfo height $win])" [expr {[winfo width $win] == 1240 && [winfo height $win] <= $fit}]
		check "opens inside the work area (between the bars' 54 px margins)" [expr {[winfo rooty $win] >= 54 && [winfo rooty $win] + [winfo height $win] <= [winfo screenheight .] - 54}]
	} else {
		check "opens at the board's size fitted under the bars (1240 x $fit)" [expr {[winfo width $win] == 1240 && [winfo height $win] == $fit}]
	}
	check "the least size is that size" [expr {[wm minsize $win] eq [list 1240 $fit]}]
	check "resizable" [expr {[wm resizable $win] eq {1 1}}]
	monitor::draw
	# the rail's Network row is the system's rate, not a button
	set monitor::metric apps
	monitor::draw
	check "the rail's Network row is not a button" [expr {[hit_of {monitor::select_metric net}] eq "" && [hit_of {monitor::select_metric disk}] ne ""}]
	layout "at the start"
	if {$mode eq "labwc"} {
		wm attributes $win -zoomed 1
		waitfor {$monitor::W > 1240 && ![info exists monitor::relayout]} 10000
		update
		check "maximised: wider than the board ($monitor::W x $monitor::H)" [expr {$monitor::W > 1240}]
		check "maximised: inside the work area ([winfo rooty $win] to [expr {[winfo rooty $win] + $monitor::H}])" \
			[expr {[winfo rooty $win] >= 54 && [winfo rooty $win] + $monitor::H <= [winfo screenheight .] - 54}]
	} else {
		wm geometry $win 1420x820
		waitfor {$monitor::W == 1420 && $monitor::H == 820 && ![info exists monitor::relayout]} 10000
		update
		check "resized to 1420 x 820" [expr {$monitor::W == 1420 && $monitor::H == 820}]
	}
	layout "bigger"
	set keys [lmap k [array names ::ui::frames] {lindex $k 0}]
	set stale [lmap k $keys {expr {[string match monitor-* [lindex $k 0]] && [lrange $k 1 2] ne [list $monitor::W $monitor::H] ? $k : [continue]}}]
	check "no frame of an old size is kept" [expr {$stale eq ""}]
	puts [expr {$fails ? "monitor window: $fails checks failed" : "monitor window: all checks passed"}]
	exit [expr {$fails > 0}]
}
