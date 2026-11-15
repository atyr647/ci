# menu.tcl - the row menu (Monitor-R3-Ledger-Processes): a right click on a row, or the Menu key on the selected
# one. End (Del) asks the processes to quit and kills what is left two seconds later; Force end (Shift Del) kills at once; Pause
# stops them (SIGSTOP) and reads Resume while they are stopped (SIGCONT); Open file location shows the program's
# file in Files; Copy command line puts it on the clipboard; Properties (Alt Enter) opens the file's Properties.
# An app's row acts on all its processes; the file entries use its first process. An entry that cannot act (the
# program's file is not ours to see; no process of the row may be signalled: another user's, the session's own,
# see monitor::signalable, or the Background app as a whole) is drawn muted and takes no click. A signal goes only
# to the processes the rows were read from (a pid and its start time), not to a new one that has taken the pid.
# Priority (Monitor-R4-Priority) opens a submenu beside it: Low, Normal, High, the current one ticked. It sets the nice
# level of every thread of the row's processes (renice): Low 10, Normal 0, High -5. Lowering a process's priority is
# always ours to do; raising it is the kernel's call (RLIMIT_NICE): what the limit does not allow goes through pkexec
# (an administrator's password), and only for a member of an administrators' group; otherwise the level is muted.
# End on an app with several processes, or on one not responding, asks first (sheet.tcl).
#
# The menu is 236 wide, padding 5, rows 34 with 1 px between, rules between the groups; the submenu 168 wide, its first
# entry level with Priority.

array set ui::paths {
	power {M18.36 6.64a9 9 0 1 1-12.73 0 M12 2v10}
	pause {M9 5v14 M15 5v14}
	play {M6 4l14 8-14 8z}
	info {M12 22a10 10 0 1 0 0-20a10 10 0 1 0 0 20z M12 16v-4 M12 8h.01}
	sort {M3 6h18 M6 12h12 M10 18h4}
	check {M20 6L9 17l-5-5}
}

namespace eval monitor {
	variable menu ""          ;# "" or dict: key (the row) x y hover
	variable cmd
	array set cmd {files ribbon-files props ribbon-properties hud ribbon-hud randr wlr-randr gamemode gamemoded hdr ribbon-hdr
		renice renice pkexec pkexec groups {id -Gn}}
	variable menu_items {end kill pause - prio location copy - props}
	variable levels {low Low 10 normal Normal 0 high High -5}
	variable admin_groups {wheel sudo admin}
}

# The pids a row stands for, the first being the one its file entries use.
proc monitor::row_pids {key} {
	variable model
	if {[string match pid:* $key]} { return [list [string range $key 4 end]] }
	if {[string match app:* $key]} {
		set id [string range $key 4 end]
		foreach a [dict get $model apps] { if {[dict get $a id] eq $id} { return [lsort -integer [dict get $a pids]] } }
	}
	return {}
}

# The pids of a row that its End, Force end and Pause act on: those that may be signalled; none for the Background
# app (every program of the session that is not an app, the compositor's and the shell's helpers among them).
proc monitor::row_signalable {key} {
	if {$key eq "app:"} { return {} }
	return [signalable [row_pids $key]]
}

# dict pid -> start time of the rows' processes, as the model read them.
proc monitor::model_idents {pids} {
	set out [dict create]
	foreach pid $pids {
		set p [proc_of $pid]
		if {$p ne "" && [dict exists $p start]} { dict set out $pid [dict get $p start] }
	}
	return $out
}

# A process of the model by pid ("" when it is gone).
proc monitor::proc_of {pid} {
	variable model
	foreach p [dict get $model procs] { if {[dict get $p pid] == $pid} { return $p } }
	return ""
}

# The program file of a process: where /proc/PID/exe points. "" when it cannot be read.
proc monitor::exe_of {pid} {
	if {[catch {file readlink [file join $::monitor::proc_root $pid exe]} path]} { return "" }
	regsub { \(deleted\)$} $path "" path
	return $path
}

proc monitor::cmdline_of {pid} {
	parse_cmdline [slurp [file join $::monitor::proc_root $pid cmdline]]
}

# Are all of the row's processes stopped (state T)? Then Pause is Resume.
proc monitor::paused {pids} {
	if {![llength $pids]} { return 0 }
	foreach pid $pids {
		set p [proc_of $pid]
		if {$p eq "" || ![dict exists $p state] || [dict get $p state] ne "T"} { return 0 }
	}
	return 1
}

# The entries for a row: {item icon label keys able} each, "-" for a rule.
proc monitor::menu_rows {key} {
	variable menu_items
	set pids [row_pids $key]
	set first [lindex $pids 0]
	set has [expr {[llength $pids] > 0}]
	set can [expr {$::monitor::scene ? $has : [llength [row_signalable $key]] > 0}]
	set exe [expr {$has ? [exe_of $first] : ""}]
	set cl [expr {$has ? [cmdline_of $first] : ""}]
	# a scene's processes are not running: its menu is drawn as the board draws it
	if {$::monitor::scene} { set exe -; set cl - }
	set out {}
	foreach it $menu_items {
		switch -- $it {
			- { lappend out - }
			end { lappend out [list end x End Del $can] }
			kill { lappend out [list kill power "Force end" "Shift Del" $can] }
			pause { if {[paused $pids]} { lappend out [list pause play Resume "" $can] } else { lappend out [list pause pause Pause "" $can] } }
			prio { lappend out [list prio sort Priority [level_label [level_of $pids]] $can 1] }
			location { lappend out [list location folder "Open file location" "" [expr {$exe ne ""}]] }
			copy { lappend out [list copy copy "Copy command line" "" [expr {$cl ne ""}]] }
			props { lappend out [list props info Properties "Alt ↵" [expr {$exe ne ""}]] }
		}
	}
	return $out
}

proc monitor::menu_height {rows} {
	set h 9
	foreach r $rows { incr h [expr {$r eq "-" ? 10 : 35}] }
	return $h
}

# ---- Priority -------------------------------------------------------------------------------------------------

# The nice level of a process or thread (field 19 of its stat), "" when it cannot be read.
proc monitor::nice_of {pid {task ""}} {
	set f [file join $::monitor::proc_root $pid]
	if {$task ne ""} { set f [file join $f task $task] }
	set t [slurp [file join $f stat]]
	set i [string last ")" $t]
	if {$i < 0} { return "" }
	set n [lindex [split [string trim [string range $t [expr {$i + 2}] end]]] 16]
	expr {[string is integer -strict $n] ? $n : ""}
}

# Every thread of a process (its task ids; the process alone when they cannot be listed).
proc monitor::tasks_of {pid} {
	set ts [glob -nocomplain -tails -directory [file join $::monitor::proc_root $pid task] {[0-9]*}]
	expr {[llength $ts] ? [lsort -integer $ts] : [list $pid]}
}

# The level a row is at: its first process's (low above 0, high below), "" when it cannot be read.
proc monitor::level_of {pids} {
	if {$::monitor::scene} { return normal }
	set n [nice_of [lindex $pids 0]]
	if {$n eq ""} { return "" }
	expr {$n > 0 ? "low" : ($n < 0 ? "high" : "normal")}
}
proc monitor::level_label {level} {
	foreach {k label n} $::monitor::levels { if {$k eq $level} { return $label } }
	return ""
}
proc monitor::level_nice {level} {
	foreach {k label n} $::monitor::levels { if {$k eq $level} { return $n } }
	return 0
}

# The lowest nice level the kernel lets this user give the process without privilege: 20 - its RLIMIT_NICE (soft).
proc monitor::nice_floor {pid} {
	foreach line [split [slurp [file join $::monitor::proc_root $pid limits]] \n] {
		if {[regexp {^Max nice priority\s+(\d+)} $line -> lim]} { return [expr {20 - min(40, $lim)}] }
	}
	return 20
}

# Is this user in an administrators' group (pkexec then asks for their own password)?
proc monitor::admin {} {
	variable is_admin
	if {![info exists is_admin]} {
		set is_admin 0
		if {![catch {::exec {*}$::monitor::cmd(groups) 2>/dev/null} gs]} {
			foreach g $::monitor::admin_groups { if {$g in $gs} { set is_admin 1 } }
		}
	}
	return $is_admin
}

# How a nice level is given to processes: "direct" (renice as this user), "pkexec" (an administrator's password), or ""
# (it cannot be: the level would raise a process above what the limit allows, and this user is not an administrator).
proc monitor::prio_route {pids nice} {
	set route direct
	foreach pid $pids {
		set cur [nice_of $pid]
		if {$cur eq "" || $nice >= $cur || [lindex $::monitor::me 1] eq "0" || $nice >= [nice_floor $pid]} continue
		set route pkexec
	}
	if {$route eq "pkexec" && ([auto_execok [lindex $::monitor::cmd(pkexec) 0]] eq "" || ![admin])} { return "" }
	return $route
}

# The submenu's entries for a row: {level label ticked able} each.
proc monitor::level_rows {key} {
	set sig [expr {$::monitor::scene ? [row_pids $key] : [row_signalable $key]}]
	set cur [level_of [row_pids $key]]
	set out {}
	foreach {k label n} $::monitor::levels {
		set able [expr {[llength $sig] && ($::monitor::scene || [prio_route $sig $n] ne "")}]
		lappend out [list $k $label [expr {$k eq $cur}] $able]
	}
	return $out
}

# Give the row's processes a level: every thread of each (renice sets one thread's). Returns the route taken.
proc monitor::set_level {key level} {
	variable cmd
	set sig [row_signalable $key]
	set ids [model_idents [row_pids $key]]
	set pids {}
	foreach p $sig { if {![dict exists $ids $p] || [start_of $p] eq [dict get $ids $p]} { lappend pids $p } }
	if {![llength $pids]} { return "" }
	set n [level_nice $level]
	set route [prio_route $pids $n]
	set tids {}
	foreach p $pids { lappend tids {*}[tasks_of $p] }
	switch -- $route {
		direct { catch {::exec {*}$cmd(renice) $n -p {*}$tids >/dev/null 2>/dev/null} }
		pkexec {
			# the password prompt is the polkit agent's; the table shows the new level at the sample after it
			catch {::exec {*}$cmd(pkexec) {*}[auto_execok [lindex $cmd(renice) 0]] {*}[lrange $cmd(renice) 1 end] $n -p {*}$tids >/dev/null 2>/dev/null &}
		}
	}
	return $route
}

# A menu opened elsewhere (the keys' Del, a scene) has no submenu fields yet.
proc monitor::menu_norm {} {
	variable menu
	foreach {k v} {sub 0 subhover ""} { if {$menu ne "" && ![dict exists $menu $k]} { dict set menu $k $v } }
}

# ---- the menu -------------------------------------------------------------------------------------------------

# Open the menu for a row with its top-left at x y (window coordinates), kept inside the page.
proc monitor::menu_open {key x y} {
	variable menu
	variable sel
	if {[row_pids $key] eq ""} { draw; return }
	set sel $key
	set h [menu_height [menu_rows $key]]
	set x [expr {max(298, min($::monitor::W - 236 - 8, $x))}]
	set y [expr {max(8, min($::monitor::H - $h - 8, $y))}]
	set menu [dict create key $key x $x y $y hover "" sub 0 subhover ""]
	draw
}

proc monitor::menu_close {args} {
	variable menu
	if {$menu eq ""} return
	set menu ""
	draw
}

# End: ask the processes to quit now (SIGTERM) and kill what is still there after the grace time (SIGKILL). The
# window stays live in between.
# IDS (dict pid -> start time) names the processes meant; by default the ones there now.
proc monitor::end_soon {pids {grace 2000} {ids ""}} {
	if {$ids eq ""} { set ids [idents $pids] }
	set sent [signal $pids TERM $ids]
	after $grace [list ::monitor::end_rest $sent $ids]
}
proc monitor::end_rest {pids ids} {
	set left {}
	foreach p $pids { if {[alive $p]} { lappend left $p } }
	if {[llength $left]} { signal $left KILL $ids }
	if {[winfo exists $::monitor::win]} { refresh }
}

# What an entry does. Returns 1 when it acted.
proc monitor::menu_do {item key} {
	variable cmd
	set pids [row_pids $key]
	set first [lindex $pids 0]
	if {![llength $pids]} { return 0 }
	set ids [model_idents $pids]
	switch -- $item {
		end - kill - pause { set sig [row_signalable $key]; if {![llength $sig]} { return 0 } }
	}
	switch -- $item {
		end { if {![end_ask $key]} { end_soon $sig 2000 $ids } }
		kill { ::monitor::signal $sig KILL $ids }
		pause { ::monitor::signal $sig [expr {[paused $pids] ? "CONT" : "STOP"}] $ids }
		location {
			set exe [exe_of $first]
			if {$exe eq ""} { return 0 }
			catch {::exec {*}$cmd(files) $exe >/dev/null 2>/dev/null &}
		}
		copy {
			set text [cmdline_of $first]
			if {$text eq ""} { return 0 }
			clipboard clear
			clipboard append -- $text
		}
		props {
			set exe [exe_of $first]
			if {$exe eq ""} { return 0 }
			catch {::exec {*}$cmd(props) $exe >/dev/null 2>/dev/null &}
		}
		low - normal - high { if {[set_level $key $item] eq ""} { return 0 } }
		default { return 0 }
	}
	return 1
}

# A click on an entry: do it, close the menu, and sample again so the table shows what changed. Priority opens its
# submenu instead.
proc monitor::menu_pick {item args} {
	variable menu
	variable sel
	if {$menu eq ""} return
	menu_norm
	if {$item eq "prio"} { dict set menu sub 1; dict set menu hover prio; draw; return }
	set key [dict get $menu key]
	set menu ""
	if {$::monitor::scene} { draw; return }
	menu_do $item $key
	if {$item in {end kill} && $::monitor::sheet eq ""} { set sel "" }
	refresh
}

# The submenu's place: beside the menu, its first entry level with Priority (left of the menu when there is no room).
proc monitor::sub_xy {} {
	variable menu
	set ry [expr {[dict get $menu y] + 5}]
	foreach r [menu_rows [dict get $menu key]] {
		if {$r eq "-"} { incr ry 10; continue }
		if {[lindex $r 0] eq "prio"} break
		incr ry 35
	}
	set x [expr {[dict get $menu x] + 240}]
	if {$x + 168 > $::monitor::W - 8} { set x [expr {[dict get $menu x] - 172}] }
	set h [menu_height {a b c}]
	return [list $x [expr {max(8, min($::monitor::H - $h - 8, $ry - 5))}]]
}

# The pointer over the menu: the entry under it is raised; resting on Priority opens its submenu.
proc monitor::menu_motion {x y} {
	variable menu
	if {$menu eq ""} return
	menu_norm
	set at ""
	if {[dict get $menu sub]} {
		lassign [sub_xy] sx sy
		if {$x >= $sx && $x < $sx + 168 && $y >= $sy && $y < $sy + [menu_height {a b c}]} {
			set sat ""
			set ry [expr {$sy + 5}]
			foreach r [level_rows [dict get $menu key]] {
				if {$y >= $ry && $y < $ry + 34 && [lindex $r 3]} { set sat [lindex $r 0] }
				incr ry 35
			}
			if {$sat ne [dict get $menu subhover]} { dict set menu subhover $sat; draw }
			return
		}
	}
	set ry [expr {[dict get $menu y] + 5}]
	foreach r [menu_rows [dict get $menu key]] {
		if {$r eq "-"} { incr ry 10; continue }
		if {$x >= [dict get $menu x] + 5 && $x < [dict get $menu x] + 231 && $y >= $ry && $y < $ry + 34 && [lindex $r 4]} { set at [lindex $r 0] }
		incr ry 35
	}
	if {$at eq ""} return
	set sub [expr {$at eq "prio"}]
	if {$at ne [dict get $menu hover] || $sub != [dict get $menu sub]} {
		dict set menu hover $at; dict set menu sub $sub; dict set menu subhover ""
		draw
	}
}

# Up and Down move through the entries, Return picks, Escape closes; Right opens Priority's submenu, Left closes it.
# Returns 1 when the key was the menu's.
proc monitor::menu_key {sym} {
	variable menu
	if {[sheet_key $sym]} { return 1 }
	if {$menu eq ""} { return 0 }
	menu_norm
	if {[dict get $menu sub] && [dict get $menu subhover] ne ""} {
		set able {}
		foreach r [level_rows [dict get $menu key]] { if {[lindex $r 3]} { lappend able [lindex $r 0] } }
		set i [lsearch -exact $able [dict get $menu subhover]]
		switch -- $sym {
			Escape - Left { dict set menu subhover ""; draw }
			Down { dict set menu subhover [lindex $able [expr {($i + 1) % max(1, [llength $able])}]]; draw }
			Up { dict set menu subhover [lindex $able [expr {$i <= 0 ? [llength $able] - 1 : $i - 1}]]; draw }
			Return - KP_Enter { menu_pick [dict get $menu subhover] }
		}
		return 1
	}
	set able {}
	foreach r [menu_rows [dict get $menu key]] { if {$r ne "-" && [lindex $r 4]} { lappend able [lindex $r 0] } }
	set i [lsearch -exact $able [dict get $menu hover]]
	switch -- $sym {
		Escape { menu_close }
		Down { dict set menu hover [lindex $able [expr {($i + 1) % max(1, [llength $able])}]]; dict set menu sub 0; draw }
		Up { dict set menu hover [lindex $able [expr {$i <= 0 ? [llength $able] - 1 : $i - 1}]]; dict set menu sub 0; draw }
		Right {
			if {[dict get $menu hover] eq "prio"} {
				set first ""
				foreach r [level_rows [dict get $menu key]] { if {[lindex $r 3] && $first eq ""} { set first [lindex $r 0] } }
				dict set menu sub 1; dict set menu subhover $first; draw
			}
		}
		Return - KP_Enter {
			if {[dict get $menu hover] eq "prio"} { menu_key Right } elseif {$i >= 0} { menu_pick [lindex $able $i] }
		}
	}
	return 1
}

# Drawn last, above the page, and the End sheet above it (sheet.tcl). A press outside the menu closes it (the first
# hit covers the window).
proc monitor::menu_draw {} {
	variable menu
	if {$menu ne ""} { menu_draw_open }
	sheet_draw
}
proc monitor::menu_draw_open {} {
	variable menu
	menu_norm
	set rows [menu_rows [dict get $menu key]]
	set x [dict get $menu x]; set y [dict get $menu y]
	ui::layer
	ui::hit 0 0 $::monitor::W $::monitor::H [list monitor::menu_close]
	ui::box $x $y 236 [menu_height $rows] -fill $ui::c(bar) -radius 12 -ring [list $ui::c(border) 1]
	ui::hit $x $y 236 [menu_height $rows] [list monitor::menu_noop]
	set ry [expr {$y + 5}]
	foreach r $rows {
		if {$r eq "-"} { ui::box [expr {$x + 11}] [expr {$ry + 4}] 214 1 -fill $ui::c(border); incr ry 10; continue }
		lassign $r item icon label keys able more
		set on [expr {$able && [dict get $menu hover] eq $item}]
		if {$on} { ui::box [expr {$x + 5}] $ry 226 34 -fill $ui::c(field) -radius 7 }
		ui::icon $icon 15 [expr {$on ? $ui::c(fg) : $ui::c(muted)}] [expr {$x + 15}] [expr {$ry + 9.5}] 1.9
		ui::text [expr {$x + 40}] [ui::lh $ry i13 34] $label i13 [expr {$able ? $ui::c(fg) : $ui::c(muted)}]
		if {$more eq "1"} {
			if {$keys ne ""} { ui::text [expr {$x + 204}] [ui::lh $ry i12 34] $keys i12 $ui::c(muted) e }
			ui::icon right 13 $ui::c(muted) [expr {$x + 208}] [expr {$ry + 10.5}] 2
		} elseif {$keys ne ""} { ui::text [expr {$x + 221}] [ui::lh $ry i12 34] $keys i12 $ui::c(muted) e }
		if {$able} { ui::hit [expr {$x + 5}] $ry 226 34 [list monitor::menu_pick $item] }
		incr ry 35
	}
	if {[dict get $menu sub]} {
		lassign [sub_xy] sx sy
		set h [menu_height {a b c}]
		ui::box $sx $sy 168 $h -fill $ui::c(bar) -radius 12 -ring [list $ui::c(border) 1]
		ui::hit $sx $sy 168 $h [list monitor::menu_noop]
		set ry [expr {$sy + 5}]
		foreach r [level_rows [dict get $menu key]] {
			lassign $r level label ticked able
			set on [expr {$able && [dict get $menu subhover] eq $level}]
			if {$on} { ui::box [expr {$sx + 5}] $ry 158 34 -fill $ui::c(field) -radius 7 }
			if {$ticked} { ui::icon check 15 $ui::c(fg) [expr {$sx + 15}] [expr {$ry + 9.5}] 2 }
			ui::text [expr {$sx + 40}] [ui::lh $ry i13 34] $label i13 [expr {$able ? $ui::c(fg) : $ui::c(muted)}]
			if {$able} { ui::hit [expr {$sx + 5}] $ry 158 34 [list monitor::menu_pick $level] }
			incr ry 35
		}
	}
}
proc monitor::menu_noop {args} {}

# The End sheet and the strip for an app not responding are End's own (sheet.tcl).
source -encoding utf-8 [file join [file dirname [file normalize [info script]]] sheet.tcl]
