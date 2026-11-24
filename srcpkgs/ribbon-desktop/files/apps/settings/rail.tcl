# rail.tcl - the Settings rail (Settings-A-Rail): the title, the search
# field, the sixteen items in four groups, and the updates chip on Updates.
# The chip reads kit's cache file the way shell/status.tcl does: shown only
# when updates are waiting.

namespace eval ui {
	variable paths
}
# the rail's icons: the board's own paths (the others are in ui.tcl)
array set ui::paths {
	search {M4 11a7 7 0 1 0 14 0a7 7 0 1 0 -14 0 M21 21l-4.3-4.3}
	monitor {M4 3h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z M8 21h8 M12 17v4}
	speaker {M11 5L6 9H2v6h4l5 4z M15.54 8.46a5 5 0 0 1 0 7.07 M19.07 4.93a10 10 0 0 1 0 14.14}
	wifi {M5 12.55a11 11 0 0 1 14 0 M1.42 9a16 16 0 0 1 21.16 0 M8.53 16.11a6 6 0 0 1 6.95 0 M12 20h.01}
	bluetooth {M7 7l10 10-5 5V2l5 5L7 17}
	keyboard {M2 6h20v12H2z M6 10h.01 M10 10h.01 M14 10h.01 M18 10h.01 M7 14h10}
	grid {M4 4h6v6H4z M14 4h6v6h-6z M4 14h6v6H4z M14 14h6v6h-6z}
	users {M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2 M9 11a4 4 0 1 0 0-8a4 4 0 1 0 0 8z M23 21v-2a4 4 0 0 0-3-3.87 M16 3.13a4 4 0 0 1 0 7.75}
	refresh {M23 4v6h-6 M1 20v-6h6 M3.51 9a9 9 0 0 1 14.85-3.36L23 10 M1 14l4.64 4.36A9 9 0 0 0 20.49 15}
	info {M12 22a10 10 0 1 0 0-20a10 10 0 1 0 0 20z M12 16v-4 M12 8h.01}
	arrowup {M12 19V5 M5 12l7-7 7 7}
	access {M12 6a1.5 1.5 0 1 0 0-3a1.5 1.5 0 1 0 0 3z M5 9l7 1.5 7-1.5 M12 10.5V15 M8.5 21l3.5-6 3.5 6}
	printer {M6 9V2h12v7 M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2 M6 14h12v8H6z}
	lang {M5 8l6 6 M4 14l6-6 2-3 M2 5h12 M7 2h1 M22 22l-5-10-5 10 M14 18h6}
	overlay {M3 4h18v16H3z M13 7h5v6h-5z}
}

namespace eval settings {
	variable updates 0     ;# the updates waiting (0 hides the chip)
	variable rowtop 132    ;# the first item's top, in the window
	variable pitch 32      ;# an item is 32 tall and touches the next (STYLE 3): 16 items end at 689
	variable groupgap 15   ;# a group's rule sits between two groups
}

# The rail's own drawing: the window's rail, drawn by the host (settings::draw).
proc settings::rail {} {
	variable sel
	variable query
	variable searching
	variable rowtop
	variable pitch
	variable groupgap
	array set c [array get ui::c]
	ui::text 28 26 Settings sg22 $c(fg) w -0.44
	# the search field; while it has the keyboard, the 1.5 px accent ring and the caret after the query (STYLE 7)
	if {$searching} {
		ui::box 16 80 198 34 -fill $c(field) -radius 9 -ring [list $c(accent) 1.5]
	} else {
		ui::box 16 80 198 34 -fill $c(field) -radius 9 -ring [list $c(border) 1]
	}
	ui::icon search 16 $c(muted) 28 89
	if {$query eq ""} {
		ui::text 52 [ui::lh 80 i13m 34] Search i13m $c(muted)
	} else {
		ui::text 52 [ui::lh 80 i13m 34] $query i13m $c(fg)
	}
	if {$searching} { ui::caret_at [expr {52 + ($query eq "" ? 0 : [ui::measure i13m $query]) + 1}] 89 }
	ui::hit 16 80 198 34 [list apply {{x y} { settings::search_on }}]
	# the items, in four groups; a query leaves only the matches
	set y $rowtop
	set prev ""
	variable sely ""
	foreach id [matching $query] {
		set g [get $id group]
		if {$query eq "" && $prev ne "" && $g != $prev} {
			# the rule between groups: 5 below the last item's gap, then 5 and the next item's 4
			ui::box 28 [expr {$y + 7}] 174 1 -fill $c(border)
			incr y $groupgap
		}
		set prev $g
		rail_item $id $y
		if {$id eq $sel} { set sely $y }
		incr y $pitch
	}
}

# The rail's places for the keyboard, registered after the page's (so Tab goes through the page first, then the
# search field and the chosen rail item, where Up and Down move the choice as Ctrl+Page Up/Down do). Not while a
# dropdown's list or a sheet is open.
proc settings::rail_focus {} {
	variable sely
	if {[sctl::busy] || [settings::modal]} return
	ui::focusable search button 16 80 198 34 9 settings::search_on
	variable pitch
	if {[info exists sely] && $sely ne ""} { ui::focusable rail list 16 $sely 198 $pitch 10 settings::rail_key }
}

# A page's own modal sheet or list is open: its hit over the whole window (Display's keep sheet, Bluetooth's
# pairing) takes the clicks the rail would get, so the rail takes no keys either.
proc settings::modal {} {
	foreach h $::ui::hits {
		lassign $h x0 y0 x1 y1
		if {$x0 <= 0 && $y0 <= 0 && $x1 >= 1100 && $y1 >= 720} { return 1 }
	}
	return 0
}

# The search field takes the keyboard (a click on it, or Return on it after Tab): no page control keeps it.
proc settings::search_on {} {
	set ::ui::focus ""
	settings::focus_search
}

# Up and Down on the rail: the item above or below, among those the query leaves. 1 when the key was the rail's.
proc settings::rail_key {sym} {
	switch -- $sym {
		Up - Prior { set d -1 }
		Down - Next { set d 1 }
		Home { set d -99 }
		End { set d 99 }
		default { return 0 }
	}
	settings::rail_step $d
	set ::ui::focus rail
	set ::ui::kbd 1
	page::draw
	return 1
}

# Move the rail's choice D items (clamped at the ends), over the items the query leaves.
proc settings::rail_step {d} {
	variable sel
	variable query
	set ids [matching $query]
	if {![llength $ids]} return
	set i [lsearch -exact $ids $sel]
	if {$i < 0} { set i [expr {$d > 0 ? -1 : [llength $ids]}] }
	set i [expr {max(0, min([llength $ids] - 1, $i + $d))}]
	select [lindex $ids $i]
}

# Keys, before search.tcl's settings::key: Return in the search opens the only match; Tab leaves the search.
proc settings::keypress {sym char state} {
	variable searching
	variable query
	# the search field reached by Tab takes what is typed, as after a click on it
	if {!$searching && $::ui::focus eq "search" && !($state & 12) && $::sctl::pop eq "" && $::page::dialog eq ""
		&& ($sym eq "BackSpace" || ([string length $char] == 1 && [scan $char %c code] == 1 && $code > 32 && $code != 127))} {
		settings::search_on
	}
	if {$searching && !($state & 4) && $::sctl::pop eq ""} {
		if {$sym in {Return KP_Enter}} {
			set m [matching $query]
			if {[llength $m] == 1} {
				set query ""
				set searching 0
				select [lindex $m 0]
				return
			}
		} elseif {$sym in {Tab ISO_Left_Tab}} {
			set searching 0
		}
	}
	settings::key $sym $char $state
}

# A press anywhere but on the search field takes the keyboard from the search (the query and its filter stay).
proc settings::press {x y} {
	variable searching
	if {$searching} {
		set px [expr {$x - $::ui::ox}]; set py [expr {$y - $::ui::oy}]
		if {!($px >= 16 && $px < 214 && $py >= 80 && $py < 114)} {
			set searching 0
			page::draw
		}
	}
	ui::press $x $y
}

# An item: PITCH tall, the icon and label centred on it (8 under the top at 32), the current one's accent bar 10 in
# from its top and bottom.
proc settings::rail_item {id y} {
	variable sel
	variable pitch
	array set c [array get ui::c]
	set on [expr {$sel eq $id}]
	set in [expr {($pitch - 16) / 2}]
	if {$on} {
		ui::box 16 $y 198 $pitch -fill $c(field) -radius 10
		ui::box 16 [expr {$y + 10}] 3 [expr {$pitch - 20}] -fill $c(accent) -radius 2
	}
	ui::icon [get $id icon] 16 [expr {$on ? $c(accent) : $c(muted)}] 28 [expr {$y + $in}]
	ui::text 56 [expr {$y + $in}] [get $id title] [expr {$on ? "i13s" : "i13m"}] [expr {$on ? $c(fg) : $c(muted)}]
	ui::hit 16 $y 198 $pitch [list apply {{id x y} { settings::select $id }} $id]
	if {$id eq "updates"} { updates_chip $y }
}

# The accent chip with the count, 20 tall, at the row's right (12 in), centred on the item.
proc settings::updates_chip {y} {
	variable updates
	if {$updates <= 0} return
	array set c [array get ui::c]
	set t $updates
	set tw [ui::measure i11s $t]
	set w [expr {7 + 10 + 3 + $tw + 7}]
	set x [expr {214 - 12 - $w}]
	set cy [expr {$y + ($::settings::pitch - 20) / 2}]
	ui::box $x $cy $w 20 -fill $c(accent) -radius 6
	ui::icon arrowup 10 $c(ink) [expr {$x + 7}] [expr {$cy + 5}] 2
	ui::text [expr {$x + 7 + 10 + 3}] [ui::lh $cy i11s 20] $t i11s $c(ink)
}

# Kit's cache file, read as the shell's status does: notify yes and the
# list of waiting kits. No file, notify off or a broken file: 0.
proc settings::updates_read {} {
	set n 0
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/"}]
	set cache [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$home/.cache"}]
	# kit's waiting kits (kit-updater) and the system's packages (ribbon update --tcl), both in kit's form; kit's
	# notify (default yes) says whether the count shows at all
	set notify 1
	foreach f [list [file join $cache kit updates] [file join $cache ribbon system-updates]] {
		if {[catch {open $f r} fh]} continue
		fconfigure $fh -encoding utf-8
		set text [read $fh]
		close $fh
		if {[catch {dict size $text}]} continue
		if {[dict exists $text notify] && ![string is true -strict [dict get $text notify]]} { set notify 0 }
		if {[dict exists $text updates]} { incr n [llength [dict get $text updates]] }
	}
	if {!$notify} { set n 0 }
	set n
}

# Read the cache now and once a minute; redraw when the count changes.
proc settings::updates_tick {} {
	variable updates
	set n [updates_read]
	if {$n != $updates} { set updates $n; page::draw }
	after 60000 settings::updates_tick
}
