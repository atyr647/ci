# table.tcl - the Ledger's table (Monitor-R3-Ledger, -Ledger-Processes). Two views share the
# page: Apps (each app opens into its processes, a chevron) and Processes (flat). The header
# sorts; a row selects; End on the selected row sends TERM and then KILL (monitor::end_selected); a right click
# opens the row's menu (menu.tcl). Typing in Search keeps the rows whose name, app or command line has the text.
# A process that is not responding (stuck.tcl) carries the tag and, in Processes, comes first.
# An open app with more than seven processes lists its six busiest and an "N more" row with the rest's sums; a
# click on that row lists them all. The sorted column's figures are the heavy ones.
# Rows scroll with the wheel. There is no Network column: nothing gives a process's network bytes without eBPF (/proc's
# net/dev is per namespace), so the board's per-app figure is left out rather than drawn as a dash.
# The window can be wider and taller than the board (monitor::W, H): the columns, Search and the switch keep their
# places from the right edge, the Name column takes the room, and more rows show.

namespace eval monitor {
	variable row_top 153     ;# the first row's top (the header is 119 to 153)
	variable row_h 40
	variable scroll 0        ;# rows scrolled off the top, in pixels
	variable allprocs {}     ;# app ids whose "N more" row was opened: every process is listed
	variable app_cols {{cpu CPU 70} {gpu GPU 62} {mem Memory 84} {disk Disk 80}}
	variable proc_cols {{pid ID 58} {cpu CPU 64} {mem Memory 80} {threads Threads 64}}
}

# Key of a value in the sort: the model field a column shows.
proc monitor::sort_value {item key} {
	switch -- $key {
		cpu { return [dict get $item cpu] }
		gpu { return [dict get $item gpu] }
		vram { return [dict get $item vram] }
		mem { return [dict get $item mem] }
		disk { return [dict get $item disk] }
		threads { return [dict get $item threads] }
		pid { return [dict get $item pid] }
		default { return 0 }
	}
}

# Items sorted by the table's column, largest first; the Background app always comes last.
proc monitor::sorted {items key} {
	set keyed {}
	foreach it $items { lappend keyed [list [sort_value $it $key] $it] }
	set out {}
	foreach k [lsort -index 0 -real -decreasing $keyed] { lappend out [lindex $k 1] }
	return $out
}

# Does a process have the search text (lower case) in its name, its app's name or its command line?
proc monitor::proc_matches {p q} {
	if {$q eq ""} { return 1 }
	foreach k {name app cmdline} {
		if {[dict exists $p $k] && [string first $q [string tolower [dict get $p $k]]] >= 0} { return 1 }
	}
	return 0
}
proc monitor::is_stuck {p} { expr {[dict exists $p stuck] && [dict get $p stuck]} }
# Search changed: back to the top, and no menu on a row that may have gone.
proc monitor::search_changed {args} {
	variable scroll 0
	variable menu ""
	draw
}

# The table's rows, flat, in draw order: {app DICT} or {proc DICT indent}.
proc monitor::rows {m} {
	variable view
	variable sort
	variable expanded
	variable allprocs
	set out {}
	set q [string tolower [string trim [ui::fval search]]]
	if {$view eq "processes"} {
		# those not responding first, then by the column
		set late {}; set rest {}
		foreach p [sorted [dict get $m procs] $sort] {
			if {![proc_matches $p $q]} continue
			if {[is_stuck $p]} { lappend late [list proc $p 0] } else { lappend rest [list proc $p 0] }
		}
		return [concat $late $rest]
	}
	set apps {}; set bg {}
	foreach a [dict get $m apps] { if {[dict get $a id] eq ""} { set bg $a } else { lappend apps $a } }
	if {$bg ne ""} { lappend apps $bg }
	# the named apps by the column, then Background last (it is not an app to rank)
	set named [sorted [lmap a $apps {expr {[dict get $a id] eq "" ? [continue] : $a}}] $sort]
	if {$bg ne ""} { lappend named $bg }
	foreach a $named {
		if {$q ne ""} {
			# an app stays when its name has the text, or one of its processes does
			set hit [expr {[string first $q [string tolower [dict get $a name]]] >= 0}]
			if {!$hit} { foreach p [dict get $m procs] { if {[dict get $p pid] in [dict get $a pids] && [proc_matches $p $q]} { set hit 1; break } } }
			if {!$hit} continue
		}
		lappend out [list app $a 0]
		if {[lsearch -exact $expanded [dict get $a id]] < 0} continue
		set mine {}
		foreach p [dict get $m procs] { if {[lsearch -exact [dict get $a pids] [dict get $p pid]] >= 0} { lappend mine $p } }
		set mine [sorted $mine cpu]
		# an app with many processes shows its six busiest and one row for the rest (a click on it shows them all)
		if {[llength $mine] > 7 && $q eq "" && [dict get $a id] ni $allprocs} {
			set rest [dict create id [dict get $a id] n [expr {[llength $mine] - 6}] cpu 0.0 gpu 0.0 mem 0 disk 0.0]
			foreach p [lrange $mine 6 end] { foreach k {cpu gpu mem disk} { dict set rest $k [expr {[dict get $rest $k] + [dict get $p $k]}] } }
			set mine [lrange $mine 0 5]
		} else { set rest "" }
		foreach p $mine { lappend out [list proc $p 1] }
		if {$rest ne ""} { lappend out [list more $rest 1] }
	}
	return $out
}

# A row, a chevron and the selection. Row hits are registered first so the chevron and End
# (registered after) take precedence: a hit that is registered later wins.
proc monitor::select {key args} {
	variable sel
	set sel $key
	draw
}
proc monitor::toggle {id args} {
	variable expanded
	set i [lsearch -exact $expanded $id]
	if {$i >= 0} { set expanded [lreplace $expanded $i $i] } else { lappend expanded $id }
	# closing an app folds its long list again
	variable allprocs
	set j [lsearch -exact $allprocs $id]
	if {$j >= 0} { set allprocs [lreplace $allprocs $j $j] }
	draw
}
proc monitor::show_all {id args} {
	variable allprocs
	if {$id ni $allprocs} { lappend allprocs $id }
	draw
}
proc monitor::sort_by {key args} {
	variable sort
	set sort $key
	draw
}
proc monitor::set_view {v} {
	variable view
	variable scroll
	set view $v
	set scroll 0
	draw
}
proc monitor::scroll_rows {d} {
	variable scroll
	variable row_h
	variable model
	set n [llength [rows $model]]
	set max [expr {max(0, $n * $row_h - ($::monitor::H - $::monitor::row_top))}]
	set scroll [expr {max(0, min($max, $scroll + $d * $row_h))}]
	draw
}

# Right edges of the columns, from the rightmost one left by widths and 12 px gaps.
proc monitor::col_edges {cols right} {
	set out {}
	set e $right
	foreach c [lreverse $cols] {
		lassign $c key label w
		set out [linsert $out 0 [list $key $label $w $e]]
		set e [expr {$e - $w - 12}]
	}
	return $out
}

# The name a sort column has in the caption: "sorted by CPU".
proc monitor::sort_name {key} {
	switch -- $key {
		cpu { return CPU } gpu { return GPU } mem { return Memory } disk { return Disk }
		threads { return Threads } vram { return VRAM } default { return $key }
	}
}

# Each app's icon, as the boards draw it (an unknown app gets the layers glyph).
proc monitor::app_icon {id} {
	switch -- $id {
		cyberpunk { return game } steam { return store } obs { return rec } firefox { return globe }
		discord { return chat } files { return folder } terminal { return term }
		default { return layers }
	}
}

proc monitor::cell_text {key item} {
	switch -- $key {
		cpu { return [format %.1f%% [dict get $item cpu]] }
		gpu { return [format %.0f%% [dict get $item gpu]] }
		mem { return [fmt_bytes [dict get $item mem]] }
		disk { return [fmt_rate [dict get $item disk]] }
		pid { return [dict get $item pid] }
		threads { return [dict get $item threads] }
	}
	return ""
}

proc monitor::table_draw {m} {
	variable view
	variable sort
	variable sel
	variable row_top
	variable row_h
	variable scroll
	variable app_cols
	variable proc_cols
	variable metric
	set dx [expr {$::monitor::W - 1240}]
	set H $::monitor::H
	set L 308; set R [expr {1200 + $dx}]
	set rw [expr {912 + $dx}]
	set flat [expr {$view eq "processes"}]
	set cols [expr {$flat ? $proc_cols : $app_cols}]
	# Processes has no End column (Monitor-R3-Ledger-Processes): its last column ends at the page's edge
	# (the board's Network column is not drawn: the Apps columns keep their board places, its room stays empty)
	set rightmost [expr {($flat ? 1188 : 1114 - 92 - 12) + $dx}]
	set edges [col_edges $cols $rightmost]
	# the page head
	if {$flat} {
		set title Processes
		set nprocs [llength [dict get $m procs]]
		set threads 0
		foreach p [dict get $m procs] { incr threads [dict get $p threads] }
		set sub "$nprocs processes · [fmt_int $threads] threads · sorted by [sort_name $sort]"
	} else {
		set title Apps
		set napps [llength [dict get $m apps]]
		set nprocs [llength [dict get $m procs]]
		set sub "$napps apps · $nprocs processes · sorted by [sort_name $sort]"
	}
	ui::text $L [ui::lh 34 sg28 36] $title sg28 $ui::c(fg) w -0.56
	ui::text $L [ui::lh 78 i14 17] $sub i14 $ui::c(muted)
	ui::field search [expr {808 + $dx}] 34 220 -ph Search -font i13m -pad 40 -onchange monitor::search_changed -max 48
	ui::icon search 16 $ui::c(muted) [expr {822 + $dx}] 45
	ui::seg seg [expr {1038 + $dx}] 34 162 {apps Apps processes Processes} $view monitor::set_view 38
	# an app not responding: the strip above the table (sheet.tcl, Monitor-R4-Stuck) moves the header and rows down
	set sh [strip_h]
	strip_draw $L $R 119
	set hy [expr {119 + $sh}]
	set row_top [expr {153 + $sh}]
	# the header: Name, then the columns; the sorted one is bright with a chevron
	ui::text $L [ui::lh $hy i12 34] [expr {$flat ? "Process" : "Name"}] i12 $ui::c(muted)
	foreach e $edges {
		lassign $e key label w right
		set on [expr {$key eq $sort}]
		set fg [expr {$on ? $ui::c(fg) : $ui::c(muted)}]
		set tx [expr {$on ? $right - 16 : $right}]
		ui::text $tx [ui::lh $hy [expr {$on ? "i12s" : "i12"}] 34] $label \
			[expr {$on ? "i12s" : "i12"}] $fg e
		if {$on} { ui::icon down 12 $fg [expr {$right - 12}] [expr {$hy + 11}] 2.2 }
		if {[lsearch -exact {cpu gpu mem disk threads} $key] >= 0} {
			ui::hit [expr {$right - $w}] $hy $w 34 [list monitor::sort_by $key]
		}
	}
	ui::box 298 [expr {$hy + 33}] $rw 1 -fill $ui::c(border)
	# the rows, clipped to the page
	set rows [rows $m]
	set n [llength $rows]
	set i 0
	foreach r $rows {
		lassign $r kind item indent
		set top [expr {$row_top + $i * $row_h - $scroll}]
		incr i
		if {$top + $row_h <= $row_top || $top >= $H} continue
		if {$kind eq "more"} {
			ui::box 298 [expr {$top + 39}] $rw 1 -fill $ui::c(border)
			ui::hit 298 $top $rw 40 [list monitor::show_all [dict get $item id]]
			ui::text 342 [ui::lh [expr {$top + 10}] i13m 20] "[dict get $item n] more" i13m $ui::c(muted)
			foreach e $edges {
				lassign $e key2 label2 w2 right2
				ui::text $right2 [ui::lh [expr {$top + 10}] i13m 20] [cell_text $key2 $item] i13m $ui::c(muted) e
			}
			continue
		}
		if {$kind eq "app"} { set key app:[dict get $item id]; set name [dict get $item name]; set count [dict get $item count] } \
		else {
			set key pid:[dict get $item pid]; set name [dict get $item name]
			set count [expr {$flat && [dict exists $item app] ? [dict get $item app] : ""}]
		}
		set on [expr {$sel eq $key}]
		if {$on} { ui::box 298 $top $rw 40 -fill $ui::c(field) -radius 8 }
		ui::box 298 [expr {$top + 39}] $rw 1 -fill $ui::c(border)
		# the row: a click selects it (a right click opens its menu: monitor::context)
		ui::hit 298 $top $rw 40 [list monitor::select $key]
		set cy [expr {$top + 20}]
		set x [expr {$L + ($kind eq "proc" && !$flat ? 34 : 0)}]
		if {$kind eq "app"} {
			set open [expr {[lsearch -exact $::monitor::expanded [dict get $item id]] >= 0}]
			ui::icon [expr {$open ? "down" : "right"}] 14 $ui::c(muted) $L [expr {$cy - 7}] 2
			ui::hit $L [expr {$cy - 14}] 20 28 [list monitor::toggle [dict get $item id]]
			ui::box 328 [expr {$cy - 12}] 24 24 -fill $ui::c(field) -radius 6
			ui::icon [app_icon [dict get $item id]] 13 $ui::c(muted) 333 [expr {$cy - 6}] 1.9
			set x 362
		} elseif {$flat} {
			# a flat process row carries its app's icon
			ui::box 308 [expr {$cy - 12}] 24 24 -fill [expr {$on ? $ui::c(pill) : $ui::c(field)}] -radius 6
			ui::icon [app_icon [expr {[dict exists $item appid] ? [dict get $item appid] : ""}]] 13 $ui::c(muted) 313.5 [expr {$cy - 6.5}] 1.8
			set x 342
		}
		set bright [expr {$kind eq "app" || $flat}]
		set nameFont [expr {$bright ? "i13s" : "i13m"}]
		set nameCol [expr {$bright || $on ? $ui::c(fg) : $ui::c(muted)}]
		set nw [ui::text $x [ui::lh [expr {$cy - 10}] $nameFont 20] $name $nameFont $nameCol]
		if {$kind eq "proc" && [is_stuck $item]} {
			# the tag takes the app name's place
			set tx [expr {$x + $nw + 10}]
			set tw [expr {24 + [ui::measure i11s "Not responding"] + 7}]
			ui::box $tx [expr {$cy - 10}] $tw 20 -fill [ui::mix $ui::c(accent) [expr {$on ? $ui::c(field) : $ui::c(bar)}] 0.16] -radius 6
			ui::icon warn 12 $ui::c(accent) [expr {$tx + 7}] [expr {$cy - 6}] 2.2
			ui::text [expr {$tx + 24}] [ui::lh [expr {$cy - 10}] i11s 20] "Not responding" i11s $ui::c(accent)
		} elseif {$count ne ""} {
			set cw [ui::text [expr {$x + $nw + 10}] [ui::lh [expr {$cy - 10}] i12 20] $count i12 $ui::c(muted)]
			# an app with a process not responding carries the tag after its count (Monitor-R4-Stuck)
			if {$kind eq "app" && [row_stuck_secs $key] ne ""} {
				set tx [expr {$x + $nw + 10 + $cw + 10}]
				set tw [expr {24 + [ui::measure i11s "Not responding"] + 7}]
				ui::box $tx [expr {$cy - 10}] $tw 20 -fill [ui::mix $ui::c(accent) [expr {$on ? $ui::c(field) : $ui::c(bar)}] 0.16] -radius 6
				ui::icon warn 12 $ui::c(accent) [expr {$tx + 7}] [expr {$cy - 6}] 2.2
				ui::text [expr {$tx + 24}] [ui::lh [expr {$cy - 10}] i11s 20] "Not responding" i11s $ui::c(accent)
			}
		}
		foreach e $edges {
			lassign $e key2 label2 w2 right2
			set v [cell_text $key2 $item]
			# the sorted column's figure is the heavy one
			set vf [expr {$bright && $key2 eq $sort ? "i13s" : "i13m"}]
			ui::text $right2 [ui::lh [expr {$cy - 10}] $vf 20] $v $vf \
				[expr {$bright ? $ui::c(fg) : $ui::c(muted)}] e
		}
		if {$on && !$flat && ($::monitor::scene || [llength [row_signalable $key]])} {
			ui::button endbtn [expr {$R - 52}] [expr {$cy - 19}] End ghost monitor::end_selected "" 52
		}
	}
	# the rows' scroll: the wheel over the table
	ui::wheel 298 $row_top $rw [expr {$H - $row_top}] [list monitor::scroll_rows]
}

# The row at a point of the window ("" for none), for the right click.
proc monitor::row_at {x y} {
	variable model
	variable row_top
	variable row_h
	variable scroll
	if {$x < 298 || $x >= 1210 + $::monitor::W - 1240 || $y < $row_top || $y >= $::monitor::H} { return "" }
	set r [lindex [rows $model] [expr {int(($y - $row_top + $scroll) / $row_h)}]]
	if {$r eq ""} { return "" }
	lassign $r kind item
	return [row_key $r]
}
# A row's key: app:ID, pid:PID, or more:ID for an app's "N more" row.
proc monitor::row_key {r} {
	lassign $r kind item
	switch -- $kind {
		app { return app:[dict get $item id] }
		more { return more:[dict get $item id] }
		default { return pid:[dict get $item pid] }
	}
}
