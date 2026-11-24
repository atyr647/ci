# sheet.tcl - System monitor: the End sheet (Monitor-R4-End) and the strip for an app that is not responding
# (Monitor-R4-Stuck).
#
# End on an app with more than one process, or on a row with a process that is not responding, opens the sheet: the
# app, its processes (name, ID, CPU, memory; the largest first, at most eight rows, then "N more"), Cancel and End.
# End sends TERM to exactly the processes listed (a pid and its start time) and KILL to what is left two seconds later
# (monitor::end_soon). A single process that responds ends at once, as before.
# The strip sits above the Apps table while a process is not responding (stuck.tcl): the app (or the process, for one of
# the Background app's), how long, Wait and End. Wait puts the strip away until that app has responded again; End
# opens the sheet. `ribbon-monitor --end PID` (the shell's "not responding" notice, shell/mod-stuck.tcl) opens the
# sheet for the row that holds PID once the first sample is in.
#
# Sheet geometry: 560 wide, centred, 28 in; the head 88 (a 44 tile, the title in Space Grotesk 20, a 13 px line),
# the list's header 34 and rows 40, the foot 72 with 38 px buttons. Under it the window is shaded (45 % black).
# Strip geometry: 56 tall above the table's header, 16 above it, R3-Panel's stuck card.

set ui::fonts(sg20) {{Ribbon Space Grotesk 600} 20 0.984 0.292}

namespace eval monitor {
	variable sheet ""         ;# "" or dict: key name pids ids stuck secs
	variable waited {}        ;# the strip's keys the person said Wait to, until no process of theirs is stuck
	variable end_pid ""       ;# --end PID: the sheet for its row, once the first sample is in
	variable scrim ""
	variable sheet_max 8      ;# rows listed before "N more"
}
foreach {k v} $::argv { if {$k eq "--end" && [string is integer -strict $v]} { set ::monitor::end_pid $v } }

# The row a process is shown in in Apps: its app, or the process itself for the Background app.
proc monitor::row_of_pid {pid} {
	set p [proc_of $pid]
	if {$p eq ""} { return "" }
	if {[dict exists $p appid] && [dict get $p appid] ne ""} {
		foreach a [dict get $::monitor::model apps] { if {[dict get $a id] eq [dict get $p appid]} { return app:[dict get $p appid] } }
	}
	return pid:$pid
}

# A row's name as the table shows it.
proc monitor::row_name {key} {
	variable model
	if {[string match app:* $key]} {
		set id [string range $key 4 end]
		foreach a [dict get $model apps] { if {[dict get $a id] eq $id} { return [dict get $a name] } }
		return ""
	}
	set p [proc_of [string range $key 4 end]]
	expr {$p eq "" ? "" : [dict get $p name]}
}

# How long the row's first process that is not responding has not been (seconds), or "" when none is stuck.
proc monitor::row_stuck_secs {key} {
	set best ""
	foreach pid [row_pids $key] {
		set p [proc_of $pid]
		if {$p eq "" || ![is_stuck $p]} continue
		set s [stuck::secs $pid]
		if {$best eq "" || $s > $best} { set best $s }
	}
	return $best
}

# End on a row: the sheet when the row is an app with more than one process, or has one not responding. Returns 1
# when the sheet was opened (the caller then signals nothing).
proc monitor::end_ask {key {force 0}} {
	set sig [expr {$::monitor::scene ? [row_pids $key] : [row_signalable $key]}]
	if {![llength $sig]} { return 0 }
	set secs [row_stuck_secs $key]
	if {!$force && $secs eq "" && !([string match app:* $key] && [llength $sig] > 1)} { return 0 }
	set ::monitor::sheet [dict create key $key name [row_name $key] pids $sig ids [model_idents $sig] stuck $secs]
	set ::monitor::menu ""
	draw
	return 1
}

proc monitor::sheet_cancel {args} {
	set ::monitor::sheet ""
	draw
}

# End on the sheet: the processes it listed, TERM then KILL.
proc monitor::sheet_end {args} {
	variable sheet
	if {$sheet eq ""} return
	set s $sheet
	set sheet ""
	if {$::monitor::scene} { draw; return }
	end_soon [dict get $s pids] 2000 [dict get $s ids]
	if {$::monitor::sel eq [dict get $s key]} { set ::monitor::sel "" }
	refresh
}

proc monitor::sheet_key {sym} {
	if {$::monitor::sheet eq ""} { return 0 }
	switch -- $sym {
		Escape { sheet_cancel }
		Return - KP_Enter { sheet_end }
	}
	return 1
}

proc monitor::fmt_cpu {v} { format %.1f%% $v }
proc monitor::plural {n one many} { expr {$n == 1 ? "1 $one" : "$n $many"} }

# The sheet's rows: {name pid cpu mem} of its processes still in the model, the largest in memory first.
proc monitor::sheet_rows {} {
	variable sheet
	set out {}
	foreach pid [dict get $sheet pids] {
		set p [proc_of $pid]
		if {$p ne ""} { lappend out [list [dict get $p name] $pid [dict get $p cpu] [dict get $p mem]] }
	}
	lsort -real -decreasing -index 3 $out
}

proc monitor::sheet_draw {} {
	variable sheet
	variable scrim
	variable end_pid
	if {$end_pid ne "" && [dict size $::monitor::model] && [llength [dict get $::monitor::model procs]]} {
		set key [row_of_pid $end_pid]
		set end_pid ""
		if {$key ne "" && [end_ask $key 1]} return
	}
	if {$sheet eq ""} return
	set W $::monitor::W; set H $::monitor::H
	set rows [sheet_rows]
	set n [llength $rows]
	set mem 0
	foreach r $rows { set mem [expr {$mem + [lindex $r 3]}] }
	set shown [expr {$n > $::monitor::sheet_max ? $::monitor::sheet_max - 1 : $n}]
	set listed [expr {$n > $shown ? $shown + 1 : $n}]
	set h [expr {88 + 34 + 40 * $listed + 8 + 72}]
	set x [expr {($W - 560) / 2}]
	set y [expr {max(24, ($H - $h) / 2 - 29)}]
	ui::layer
	if {$scrim eq ""} {
		set scrim [image create photo -data [raster::png 16 16 [lrepeat 16 [string repeat {0 0 0 115 } 16]]] -format png]
	}
	$ui::img copy $scrim -to 0 0 $W $H
	# the page under the sheet takes no clicks
	ui::hit 0 0 $W $H [list monitor::menu_noop]
	ui::box $x $y 560 $h -fill $ui::c(bar) -radius 16 -ring [list $ui::c(border) 1]
	set L [expr {$x + 28}]; set R [expr {$x + 532}]
	ui::box $L [expr {$y + 24}] 44 44 -fill $ui::c(field) -radius 12 -ring [list $ui::c(border) 1]
	set k [dict get $sheet key]
	if {[string match app:* $k]} { set id [string range $k 4 end] } else {
		set p [proc_of [string range $k 4 end]]
		set id [expr {$p ne "" && [dict exists $p appid] ? [dict get $p appid] : ""}]
	}
	set icon [app_icon $id]
	ui::icon $icon 22 $ui::c(fg) [expr {$L + 11}] [expr {$y + 35}] 1.7
	ui::text [expr {$L + 58}] [expr {$y + 23}] "End [dict get $sheet name]?" sg20 $ui::c(fg) w -0.4
	set sub [list [plural $n process processes] [fmt_bytes $mem]]
	if {[dict get $sheet stuck] ne ""} { set sub [linsert $sub 0 "Not responding · [dict get $sheet stuck] s"] }
	ui::text [expr {$L + 58}] [ui::lh [expr {$y + 51}] i13 16] [join $sub " · "] i13 $ui::c(muted)
	# the list: Process, then ID, CPU and Memory from the right
	set hy [expr {$y + 88}]
	set cols [list [list ID [expr {$R - 172}]] [list CPU [expr {$R - 92}]] [list Memory $R]]
	ui::text $L [ui::lh $hy i12 34] Process i12 $ui::c(muted)
	foreach c $cols { ui::text [lindex $c 1] [ui::lh $hy i12 34] [lindex $c 0] i12 $ui::c(muted) e }
	ui::box $L [expr {$hy + 33}] 504 1 -fill $ui::c(border)
	set ry [expr {$hy + 34}]
	set i 0
	foreach r [lrange $rows 0 [expr {$shown - 1}]] {
		lassign $r name pid cpu m
		ui::text $L [ui::lh [expr {$ry + 10}] i13s 20] $name i13s $ui::c(fg)
		foreach v [list $pid [fmt_cpu $cpu] [fmt_bytes $m]] c $cols { ui::text [lindex $c 1] [ui::lh [expr {$ry + 10}] i13m 20] $v i13m $ui::c(fg) e }
		incr i
		if {$i < $listed} { ui::box $L [expr {$ry + 39}] 504 1 -fill $ui::c(border) }
		incr ry 40
	}
	if {$listed > $shown} {
		set rest [lrange $rows $shown end]
		set c 0.0; set m 0
		foreach r $rest { set c [expr {$c + [lindex $r 2]}]; set m [expr {$m + [lindex $r 3]}] }
		ui::text $L [ui::lh [expr {$ry + 10}] i13m 20] "[llength $rest] more" i13m $ui::c(muted)
		foreach v [list "" [fmt_cpu $c] [fmt_bytes $m]] col $cols { ui::text [lindex $col 1] [ui::lh [expr {$ry + 10}] i13m 20] $v i13m $ui::c(muted) e }
		incr ry 40
	}
	# the foot: Cancel, and End as the one primary
	set fy [expr {$ry + 8}]
	ui::box $x $fy 560 1 -fill $ui::c(border)
	set ew [ui::button_w End primary x]
	set cw [ui::button_w Cancel ghost]
	ui::button sheet_end [expr {$R - $ew}] [expr {$fy + 17}] End primary monitor::sheet_end x
	ui::button sheet_cancel [expr {$R - $ew - 10 - $cw}] [expr {$fy + 17}] Cancel ghost monitor::sheet_cancel
}

# ---- the strip ------------------------------------------------------------------------------------------------

# The row the strip is for: the first one with a process not responding that the person has not said Wait to.
# {key name secs}, or "" for none. A waited row is forgotten once none of its processes is stuck.
proc monitor::strip_row {} {
	variable model
	variable waited
	# Apps only: in Processes the process not responding comes first with its tag (Monitor-R3-Ledger-Processes)
	if {![dict size $model] || $::monitor::view ne "apps"} { return "" }
	set keys {}
	foreach p [dict get $model procs] {
		if {![is_stuck $p]} continue
		set key [row_of_pid [dict get $p pid]]
		if {$key ne "" && $key ni $keys} { lappend keys $key }
	}
	set waited [lmap k $waited { expr {$k in $keys ? $k : [continue]} }]
	foreach key $keys {
		if {$key in $waited} continue
		return [list $key [row_name $key] [row_stuck_secs $key]]
	}
	return ""
}

# The strip's height with its gap (72), or 0 when there is none: the table's header and rows move down by it.
proc monitor::strip_h {} { expr {[strip_row] eq "" ? 0 : 72} }

proc monitor::strip_wait {key args} {
	lappend ::monitor::waited $key
	draw
}
proc monitor::strip_end {key args} {
	end_ask $key 1
}

# A compact button (34 tall): ghost or field, a 13 px label, an optional icon after it. Returns its width.
proc monitor::cbutton {x y label kind script {icon ""}} {
	set w [expr {28 + [ui::measure i13m $label] + ($icon ne "" ? 20 : 0)}]
	if {$kind eq "ghost"} { ui::ring $x $y $w 34 9 $ui::c(border) 1 } else { ui::box $x $y $w 34 -fill $ui::c(field) -radius 9 }
	set tw [ui::text [expr {$x + 14}] [ui::lh $y i13m 34] $label i13m $ui::c(fg)]
	if {$icon ne ""} { ui::icon $icon 13 $ui::c(fg) [expr {$x + 14 + $tw + 7}] [expr {$y + 10.5}] 2 }
	ui::hit $x $y $w 34 $script
	return $w
}

# The strip, from L to R with its top at Y (the page's coordinates).
proc monitor::strip_draw {L R y} {
	set s [strip_row]
	if {$s eq ""} return
	lassign $s key name secs
	ui::box $L $y [expr {$R - $L}] 56 -fill $ui::c(field) -radius 10 -ring [list $ui::c(border) 1]
	set id [expr {[string match app:* $key] ? [string range $key 4 end] : ""}]
	ui::box [expr {$L + 12}] [expr {$y + 14}] 28 28 -fill $ui::c(pill) -radius 7
	ui::icon [app_icon $id] 14 $ui::c(fg) [expr {$L + 19}] [expr {$y + 21}] 1.8
	ui::text [expr {$L + 52}] [ui::lh [expr {$y + 12}] i13s 16] $name i13s $ui::c(fg)
	ui::text [expr {$L + 52}] [ui::lh [expr {$y + 29}] i12 15] "Not responding · $secs s" i12 $ui::c(muted)
	set ew [expr {28 + [ui::measure i13m End] + 20}]
	set ex [expr {$R - 10 - $ew}]
	monitor::cbutton $ex [expr {$y + 11}] End field [list monitor::strip_end $key] x
	set ww [expr {28 + [ui::measure i13m Wait]}]
	monitor::cbutton [expr {$ex - 8 - $ww}] [expr {$y + 11}] Wait ghost [list monitor::strip_wait $key]
}
