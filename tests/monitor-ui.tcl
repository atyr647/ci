# tests/monitor-ui.tcl - the System monitor window's checks, run under xvfb with the board scene:
# RIBBON_MONITOR_SCENE=tests/monitor-ui.tcl wish8.6 apps/monitor/main.tcl (tests/steps.d/58-monitor-ui.sh).
# On the scene's model: the rail's sorting, the "N more" row, Search, the GPU page's controls and the rail's foot
# (the overlay's command stood in for by $RIBBON_MONITOR_T/rec.sh). Then on the live sampler and sacrificial
# processes: the row menu's entries through real clicks (Pause is SIGSTOP, Resume SIGCONT, Force end SIGKILL,
# End SIGTERM then SIGKILL; Copy command line; Open file location and Properties start their programs, stood in
# for), the keys, and the Not responding tag.
source [file join [file dirname [file normalize [info script]]] monitor-scene.tcl]

proc ui_check {name ok} {
	if {$ok} { puts "  ok   $name" } else { puts "  FAIL $name"; incr ::ui_fails }
}
set ::ui_fails 0
set T $::env(RIBBON_MONITOR_T)

proc click {x y} {
	ui::press [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]
	ui::release [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]
}
proc wait_for {script ms} {
	set until [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 $script]} {
		if {[clock milliseconds] >= $until} { return 0 }
		after 20 {set ::tick 1}; vwait ::tick
	}
	return 1
}
proc state_of {pid} {
	set st [monitor::parse_pid_stat [monitor::slurp /proc/$pid/stat]]
	expr {[dict exists $st state] ? [dict get $st state] : ""}
}
proc slurp_out {name} { string trim [monitor::slurp [file join $::T $name.out]] }
proc row_keys {} { lmap r [monitor::rows $::monitor::model] {monitor::row_key $r} }
# Right click the row of a process (it must be on the page), and click an entry of the menu where it is drawn.
proc menu_on {pid} {
	set y [monitor::row_y pid:$pid]
	if {$y eq ""} { return 0 }
	monitor::context [expr {600 + $::ui::ox}] [expr {$y + 20 + $::ui::oy}]
	expr {$::monitor::menu ne "" && [dict get $::monitor::menu key] eq "pid:$pid"}
}
proc menu_labels {} { lmap r [monitor::menu_rows [dict get $::monitor::menu key]] {expr {$r eq "-" ? "-" : [lindex $r 2]}} }
proc menu_click {item} {
	set ry [expr {[dict get $::monitor::menu y] + 5}]
	foreach r [monitor::menu_rows [dict get $::monitor::menu key]] {
		if {$r eq "-"} { incr ry 10; continue }
		if {[lindex $r 0] eq $item} { click [expr {[dict get $::monitor::menu x] + 100}] [expr {$ry + 17}]; return 1 }
		incr ry 35
	}
	return 0
}
proc is_sleep {pid} { string match "sleep *" [monitor::parse_cmdline [monitor::slurp /proc/$pid/cmdline]] }
proc sleeper {secs {shield 0}} {
	if {$shield} { return [exec sh -c "trap '' TERM; exec sleep $secs" </dev/null >/dev/null 2>/dev/null &] }
	return [exec sleep $secs </dev/null >/dev/null 2>/dev/null &]
}

proc run_checks {} {
	global T
	set ::monitor::scene 0
	array set ::monitor::cmd [list files [list sh $T/rec.sh files] props [list sh $T/rec.sh props] hud [list sh $T/rec.sh hud]]
	set m $::monitor::model
	set ::monitor::view apps
	# the first named app after each rail choice
	foreach {metric want} {cpu cyberpunk gpu cyberpunk mem cyberpunk disk steam} {
		monitor::select_metric $metric
		set first ""
		foreach r [monitor::rows $m] {
			if {[lindex $r 0] eq "app"} { set first [dict get [lindex $r 1] id]; break }
		}
		ui_check "sort by $metric puts $want first" [expr {$first eq $want}]
	}
	monitor::select_metric cpu
	click 100 100
	ui_check "the rail's Apps row is the table again" [expr {$::monitor::metric eq "apps"}]

	# an open app with many processes: six, and a row for the rest
	set keys [row_keys]
	set more [lindex [monitor::rows $m] [lsearch -exact $keys more:cyberpunk]]
	ui_check "an app's processes: the six busiest and \"25 more\"" [expr {[llength [lsearch -all -glob $keys pid:*]] == 6 && [dict get [lindex $more 1] n] == 25 && abs([dict get [lindex $more 1] mem] - 141 * 1048576.0) < 1}]
	click 600 [expr {[monitor::row_y more:cyberpunk] + 20}]
	ui_check "a click on \"25 more\" lists them all" [expr {[llength [lsearch -all -glob [row_keys] pid:*]] == 31 && "more:cyberpunk" ni [row_keys]}]
	click 315 [expr {[monitor::row_y app:cyberpunk] + 20}]
	ui_check "the chevron closes the app" [expr {[lsearch -glob [row_keys] pid:*] < 0}]

	# Search: a click gives it the keys, the rows are filtered as the text changes, Escape clears it
	click 900 53
	ui_check "a click on Search gives it the focus" [expr {$::ui::focus eq "search"}]
	foreach c {f i r E} { monitor::key $c $c 0 }
	ui_check "typing in Search keeps the rows with the text (any case)" [expr {[ui::fval search] eq "firE" && [row_keys] eq {app:firefox}}]
	monitor::key BackSpace "" 0; monitor::key BackSpace "" 0; monitor::key BackSpace "" 0
	monitor::key i i 0; monitor::key l l 0
	ui_check "editing the text filters again" [expr {[row_keys] eq {app:files}}]
	foreach c {x y z} { monitor::key $c $c 0 }
	ui_check "a text nothing has leaves no rows" [expr {[row_keys] eq {}}]
	monitor::key Escape "" 0
	ui_check "Escape clears Search" [expr {[ui::fval search] eq "" && $::ui::focus eq "" && [llength [row_keys]] == 8}]
	ui::fset search wineserver; monitor::search_changed
	ui_check "an app stays when one of its processes has the text" [expr {[row_keys] eq {app:cyberpunk}}]
	ui::fset search ""; monitor::search_changed

	# the GPU page: the rail's GPU row, the span and the list's sort
	click 100 225
	ui_check "the rail's GPU row opens the GPU page" [expr {$::monitor::metric eq "gpu"}]
	click 1104 53
	ui_check "10 min is the graph's span" [expr {$::monitor::span == 600}]
	click 1170 53
	ui_check "1 h is the graph's span" [expr {$::monitor::span == 3600}]
	click 700 469
	ui_check "the VRAM heading sorts the apps by VRAM" [expr {$::monitor::gsort eq "vram"}]
	set nocard $m; dict set nocard card ""; dict set nocard vram_used 0; dict set nocard vram_total 0
	set ::monitor::model $nocard
	ui_check "no card: the page draws, the rail says a dash" [expr {![catch {monitor::draw}] && [lindex [dict get [monitor::rail_values $nocard] gpu] 0] eq "–"}]
	set ::monitor::model $m
	click 100 100

	# the rail's foot starts the overlay's Compact layout
	click 130 670
	ui_check "the foot's card runs: ribbon-hud layout compact" [expr {[wait_for [list file exists $T/hud.out] 5000] && [slurp_out hud] eq "layout compact"}]
	set nogame $m; dict set nogame game ""
	set ::monitor::model $nogame; monitor::draw
	file delete $T/hud.out
	click 130 670
	after 300 {set ::tick 1}; vwait ::tick
	ui_check "no game, no card and no click" [expr {![file exists $T/hud.out]}]

	# the monitor looks while it is busy, so the pointer's events on its own display socket are unread at every
	# look: it is not "not responding" itself
	if {[auto_execok xdotool] ne "" && [auto_execok ss] ne ""} {
		set ::monitor::stuck::need 3
		set self {}
		for {set i 0} {$i < 5} {incr i} {
			exec xdotool mousemove [expr {400 + $i * 20}] 400 mousemove [expr {500 + $i * 20}] 420
			set self [concat $self [monitor::stuck::update]]
		}
		ui_check "the monitor does not tag itself as not responding" [expr {[pid] ni $self}]
		set ::monitor::stuck::need 5
		array unset ::monitor::stuck::seen
		update
	}

	# the live sampler and sacrificial processes
	# (their durations are this run's own, so another run of this test beside it is not in the rows)
	set tag [expr {200000 + [pid] % 50000 * 10}]
	set a [sleeper [expr {$tag + 1}]]; set b [sleeper [expr {$tag + 2}] 1]; set c [sleeper [expr {$tag + 3}]]
	# a child is the test's own program until it has become sleep
	foreach p [list $a $b $c] { wait_for [list is_sleep $p] 3000 }
	monitor::refresh
	set ::monitor::view processes
	ui::fset search "sleep [string range $tag 0 end-1]"; monitor::search_changed
	ui_check "Search finds processes by their command line" [expr {[lsort [row_keys]] eq [lsort [list pid:$a pid:$b pid:$c]]}]
	ui_check "a right click on a row opens its menu and selects the row" [expr {[menu_on $a] && $::monitor::sel eq "pid:$a"}]
	ui_check "the menu's entries are the board's" [expr {[menu_labels] eq {End {Force end} Pause - Priority {Open file location} {Copy command line} - Properties}}]
	menu_click pause
	ui_check "Pause stops the process (SIGSTOP)" [expr {[wait_for [list expr "\[state_of $a\] eq {T}"] 3000] && $::monitor::menu eq ""}]
	monitor::refresh
	menu_on $a
	ui_check "a stopped process's entry reads Resume" [expr {[lindex [menu_labels] 2] eq "Resume"}]
	menu_click pause
	ui_check "Resume lets it run again (SIGCONT)" [wait_for [list expr "\[state_of $a\] ni {T {}}"] 3000]
	monitor::refresh
	menu_on $a; menu_click copy
	ui_check "Copy command line puts it on the clipboard" [expr {![catch {clipboard get} got] && $got eq "sleep [expr {$tag + 1}]"}]
	set exe [file readlink /proc/$a/exe]
	menu_on $a; menu_click location
	ui_check "Open file location shows the program's file in Files" [expr {[wait_for [list file exists $T/files.out] 5000] && [slurp_out files] eq $exe}]
	monitor::select pid:$a
	monitor::key Return "" 8
	ui_check "Alt Enter opens the file's Properties" [expr {[wait_for [list file exists $T/props.out] 5000] && [slurp_out props] eq $exe}]
	file delete $T/props.out
	menu_on $a; menu_click props
	ui_check "Properties in the menu does the same" [expr {[wait_for [list file exists $T/props.out] 5000] && [slurp_out props] eq $exe}]
	monitor::select pid:$a
	monitor::key Menu "" 0
	ui_check "the Menu key opens the selected row's menu" [expr {$::monitor::menu ne "" && [dict get $::monitor::menu key] eq "pid:$a"}]
	monitor::key Down "" 0; monitor::key Down "" 0
	ui_check "Down moves through the entries" [expr {[dict get $::monitor::menu hover] eq "kill"}]
	monitor::key Escape "" 0
	ui_check "Escape closes the menu and does nothing" [expr {$::monitor::menu eq "" && [monitor::alive $a]}]
	menu_on $a
	click 400 700
	ui_check "a click outside closes the menu" [expr {$::monitor::menu eq "" && [monitor::alive $a]}]

	# what the menu does not signal: the monitor itself, the Background app as a whole (the session's own
	# programs), and a pid that has come to name another process since the rows were read
	proc able {key} { lmap r [monitor::menu_rows $key] {expr {$r eq "-" ? [continue] : [lindex $r 4]}} }
	ui_check "the monitor's own row: End, Force end and Pause are muted" [string match {0 0 0 *} [able pid:[pid]]]
	ui_check "the Background app's row: End, Force end and Pause are muted" [string match {0 0 0 *} [able app:]]
	set ::monitor::view apps; set ::monitor::sel app:; monitor::draw
	ui_check "the Background app's row has no End button" [expr {[lsearch -glob $::ui::hits {*monitor::end_selected*}] < 0}]
	set ::monitor::sel ""; set ::monitor::view processes; monitor::draw
	proc restart_in_model {pid} {
		set ps {}
		foreach p [dict get $::monitor::model procs] { if {[dict get $p pid] == $pid} { dict set p start 1 }; lappend ps $p }
		dict set ::monitor::model procs $ps
	}
	menu_on $a
	restart_in_model $a
	menu_click pause
	after 300 {set ::tick 1}; vwait ::tick
	ui_check "an entry is not sent to a pid whose process is not the row's any more" [expr {[state_of $a] ni {T {}}}]
	monitor::refresh
	set ::monitor::sel pid:$a
	restart_in_model $a
	monitor::refresh
	ui_check "a selected process that has gone (its pid taken by another) is no longer selected" [expr {$::monitor::sel eq ""}]
	monitor::refresh

	# not responding: the tag's rows come first; a process stopped on purpose is not tagged
	proc ::monitor::stuck::update {} [list return [list $c $a]]
	monitor::refresh
	set first [lindex [monitor::rows $::monitor::model] 0 1]
	ui_check "processes not responding are tagged and come first" [expr {[lrange [row_keys] 0 1] eq [list pid:$c pid:$a] || [lrange [row_keys] 0 1] eq [list pid:$a pid:$c]}]
	ui_check "the others are not tagged" [expr {[monitor::is_stuck $first] && ![monitor::is_stuck [monitor::proc_of $b]]}]
	menu_on $c; menu_click pause
	wait_for [list expr "\[state_of $c\] eq {T}"] 3000
	monitor::refresh
	ui_check "a process that was paused is not \"not responding\"" [expr {![monitor::is_stuck [monitor::proc_of $c]] && [monitor::is_stuck [monitor::proc_of $a]]}]
	proc ::monitor::stuck::update {} { return {} }

	# Force end is SIGKILL at once; End is SIGTERM, and SIGKILL two seconds later for what ignores it
	menu_on $a; menu_click kill
	ui_check "Force end kills at once (SIGKILL)" [expr {[wait_for [list expr "!\[monitor::alive $a\]"] 1500] && $::monitor::sel eq ""}]
	monitor::refresh
	monitor::select pid:$b
	set t0 [clock milliseconds]
	monitor::key Delete "" 0
	set took [expr {[clock milliseconds] - $t0}]
	after 400 {set ::tick 1}; vwait ::tick
	ui_check "Del ends: SIGTERM first, and the window does not wait" [expr {$took < 1000 && [monitor::alive $b]}]
	ui_check "what ignores SIGTERM is killed after the grace time" [wait_for [list expr "!\[monitor::alive $b\]"] 6000]
	monitor::refresh
	monitor::select pid:$c
	monitor::key Delete "" 1
	ui_check "Shift Del is Force end (a stopped process too)" [wait_for [list expr "!\[monitor::alive $c\]"] 1500]
	# End on the selected row of the Apps view (the button)
	set d [sleeper [expr {$tag + 4}]]
	wait_for [list is_sleep $d] 3000
	set ::monitor::sel pid:$d
	monitor::end_selected
	ui_check "End stops a sacrificial process" [wait_for [list expr "!\[monitor::alive $d\]"] 3000]
	foreach p [list $a $b $c $d] { catch {exec kill -9 $p} }
}

proc bgerror {msg} { puts "  FAIL background error: $msg\n$::errorInfo"; exit 1 }
after 300 {
	if {[catch {run_checks} err]} { puts "  FAIL the checks raised: $err\n$::errorInfo"; exit 1 }
	puts [expr {$::ui_fails ? "monitor-ui: $::ui_fails failure(s)" : "monitor-ui: all checks passed"}]
	exit [expr {$::ui_fails ? 1 : 0}]
}
