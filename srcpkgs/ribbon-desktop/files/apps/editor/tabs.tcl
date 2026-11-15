# tabs.tcl - Text editor (U26, U30, U31): the title strip. One window: the joined tabs (Editor-Final-1), the overflow
# (Editor-Final-2: the strip scrolls, "+" stays pinned, "N" opens the open-documents list) and the list. The right
# cluster (search, split, ⋯, window controls) is 215 wide. Split (Editor-Final-4-Split-B): each pane has its own tabs,
# "+" and a "⋯" at its right end, and the window controls sit in a 110 px zone behind a full-height rule. The Welcome
# page's strip shows only "⋯" and the window controls. STYLE §20.
#
# Geometry, window coordinates (a pane's tabs are offset by its x, split::px): strip 0..46 (rule at 45); a tab is 36
# tall at y 10, 14 + name + 8 + 18 + 8 wide, 96 to 220. A pane's tabs start 14 px into it.
#   ui::hit order: a later hit wins, so the strip's drag area goes first, then tabs, their close slots, the list.

namespace eval tabs {
}

# The width of a tab for document ID.
proc tabs::width {id} {
	set w [expr {int(ceil([ui::measure i13s [doc::name $id]] + 48))}]
	expr {min(220, max(96, $w))}
}

# The width the tabs may take before "+" (and the count button) in pane P: the window's, unsplit, else the pane's less
# the "+" and the "⋯".
proc tabs::region {p} {
	if {![split::is_split]} { return [expr {$editor::W - 333}] }
	expr {[split::pw $p] - 150}
}

# {{id x w} ...} in strip coordinates (before scroll), the total width of the tabs, and whether they overflow. While a
# tab of pane P is dragged within it (split::lift), the tab is out of the row and a gap of its width is where it lands.
proc tabs::layout {{p ""}} {
	if {$p eq ""} { set p $split::cur }
	set x 14
	set items {}
	set docs [split::val $p docs]
	set gap -1
	if {[llength $split::lift] && [lindex $split::lift 0] == $p} {
		lassign $split::lift lp lid gap
		set docs [lsearch -exact -all -inline -not $docs $lid]
	}
	set k 0
	foreach id $docs {
		if {$k == $gap} { incr x [width $lid] }
		set w [width $id]
		lappend items [list $id $x $w]
		incr x $w
		incr k
	}
	if {$gap >= $k} { incr x [width $lid] }
	set total [expr {$x - 14}]
	list $items $total [expr {$total > [region $p]}]
}

# Keep pane P's scroll inside its strip.
proc tabs::clamp {p} {
	lassign [layout $p] items total over
	set R [expr {$over ? [region $p] : $total}]
	set most [expr {max(0, $total - $R)}]
	if {!$over} {
		split::put $p scroll 0
	} else {
		split::put $p scroll [expr {max(0, min($most, [split::val $p scroll]))}]
	}
}

# Scroll the focused pane's strip so that tab ID is visible.
proc tabs::reveal {id} {
	set p $split::cur
	set R [region $p]
	lassign [layout $p] items total over
	foreach it $items {
		lassign $it i x w
		if {$i ne $id} continue
		set x0 [expr {$x - [split::val $p scroll]}]
		if {$x0 < 14} { split::put $p scroll [expr {$x - 14}] }
		if {$x0 + $w > 14 + $R} { split::put $p scroll [expr {$x + $w - (14 + $R)}] }
	}
	clamp $p
}

# The tab under the window point (x, y), or "".
proc tabs::at {x y} {
	if {$y < 10 || $y >= 46} { return "" }
	set p [split::pane_at $x]
	set lx [expr {$x - [split::px $p]}]
	set R [region $p]
	set scroll [split::val $p scroll]
	lassign [layout $p] items total over
	foreach it $items {
		lassign $it i ix w
		set x0 [expr {$ix - $scroll}]
		if {$lx >= max(14, $x0) && $lx < $x0 + $w && $lx < 14 + $R + 1} { return $i }
	}
	return ""
}

# The strips: one per pane when split (with the rule's chrome), else the single window's strip.
proc tabs::paint_strips {} {
	if {[split::is_split]} {
		foreach p [split::panes] { paint_pane $p }
		split_chrome
	} else {
		paint_pane $split::cur
	}
}

# A pane's strip: the tabs, the cut edges, "+" and the count button, then "⋯" (split) or the right cluster (single).
proc tabs::paint_pane {p} {
	variable region
	set ox [split::px $p]
	set pw [split::pw $p]
	set bar $editor::c(bar); set d2 $editor::c(d2); set border $editor::c(border)
	set muted $editor::c(muted); set fg $editor::c(fg)
	clamp $p
	lassign [layout $p] items total over
	set R [expr {$over ? [region $p] : $total}]
	set scroll [split::val $p scroll]
	set active [split::val $p active]
	ui::box $ox 0 $pw 46 -fill $d2
	ui::box $ox 45 $pw 1 -fill $border
	foreach it $items {
		lassign $it id ix w
		set x [expr {$ox + $ix - $scroll}]
		if {$x + $w <= $ox + 14 || $x >= $ox + 14 + $R} continue
		set on [expr {$id eq $active}]
		set hov [expr {$id eq $editor::hover && !$on}]
		draw_tab $p $id $x $w $on $hov
	}
	# the cut edges and everything past the tabs: the strip colour, so nothing shows past "+"
	ui::box $ox 0 14 46 -fill $d2
	ui::box [expr {$ox + 14 + $R}] 0 [expr {$pw - 14 - $R}] 46 -fill $d2
	# the active tab's feet come after the cut edges, so the left one shows in the strip's first 14 px
	foreach it $items {
		lassign $it id ix w
		if {$id eq $active} { feet [expr {$ox + $ix - $scroll}] $w }
	}
	lifted $p $items $ox $scroll
	set plusx [expr {$ox + ($over ? 14 + $R + 6 : 14 + $total + 6)}]
	ui::hit $plusx 14 28 28 [list editor::new_doc]
	editor::icon plus 15 [editor::dim $muted] [expr {$plusx + 6.5}] 20.5
	if {$over} {
		set cx [expr {$plusx + 30}]
		set open $editor::pop
		if {$open && $p == $split::cur} { ui::box $cx 14 48 28 -fill $editor::c(field) -radius 8 }
		ui::text [expr {$cx + 9}] 19 [llength $items] i12s [expr {$open ? $fg : $muted}]
		editor::icon down 14 [expr {$open ? $fg : $muted}] [expr {$cx + 28}] 21
		ui::hit $cx 14 48 28 [list tabs::toggle]
	}
	if {[split::is_split]} {
		more_button [expr {$ox + $pw - 40}]
		return
	}
	# unsplit: the right cluster: search, split, more | minimise, maximise, close
	set rx [expr {$editor::W - 215}]
	foreach {nm cmd} {search editor::find_open split editor::split_toggle more editor::more_menu} {
		ui::hit $rx 7 32 32 [list {*}$cmd]
		editor::icon $nm 16 [editor::dim $muted] [expr {$rx + 8}] 15
		incr rx 32
	}
	# a framed window has labwc's buttons (and its maximised strip has them too): no controls here
	if {![editor::own_controls]} return
	ui::box [expr {$rx + 8}] 14 1 18 -fill [editor::dim $border]
	set cx [expr {$rx + 17}]
	foreach {nm cmd} {min editor::minimize max editor::maximize x editor::quit} {
		ui::hit $cx 7 30 32 [list {*}$cmd]
		editor::icon $nm 12 [editor::dim $muted] [expr {$cx + 9}] 17
		incr cx 32
	}
	# the list is drawn by editor::paint, above the page
}

# The tab being dragged within pane P (split::lift): lifted off the strip into the gap where it will land, 10 px in and
# 3 px up, 34 tall, in the field colour with a 1 px ring and its name in 13/600 (the boards' lifted tab, gen_editor_final
# lifted()). The gap is the place in ITEMS' order the drop takes.
proc tabs::lifted {p items ox scroll} {
	if {![llength $split::lift] || [lindex $split::lift 0] != $p} return
	lassign $split::lift lp id gap
	set x 14
	set k 0
	foreach it $items {
		if {$k == $gap} break
		set x [expr {[lindex $it 1] + [lindex $it 2]}]
		incr k
	}
	set w [width $id]
	set x [expr {$ox + $x - $scroll + 10}]
	ui::box $x 7 $w 34 -fill $editor::c(field) -radius 9
	ui::box $x 30 $w 11 -fill $editor::c(field)
	ui::ring $x 7 $w 43 9 $editor::c(border) 1
	ui::box $x 41 $w 5 -fill $editor::c(d2)
	ui::box $x 45 $w 1 -fill $editor::c(border)
	name_fade $x $w [doc::name $id] i13s $editor::c(fg) $editor::c(field) [expr {$w - 48}]
}

# "⋯" at X in the strip: its menu (editor::more_menu).
proc tabs::more_button {x} {
	ui::hit $x 7 32 32 [list editor::more_menu]
	editor::icon more 16 [editor::dim $editor::c(muted)] [expr {$x + 8}] 15
}

# The window controls: a 110 px zone at the window's right, behind a full-height rule. Never dimmed.
proc tabs::control_zone {} {
	if {![editor::own_controls]} return
	set zx [expr {$editor::W - 110}]
	set fg $editor::c(muted)   ;# the boards draw the window controls in muted (Editor-Final-1 to -7)
	ui::box $zx 0 110 46 -fill $editor::c(d2)
	ui::box $zx 0 1 $editor::H -fill $editor::c(border)
	set cx [expr {$zx + 7}]
	foreach {nm cmd} {min editor::minimize max editor::maximize x editor::quit} {
		ui::hit $cx 7 32 32 [list {*}$cmd]
		editor::icon $nm 12 $fg [expr {$cx + 10}] 17
		incr cx 32
	}
}

# The strip of the Welcome page: "⋯" and the window controls.
proc tabs::paint_welcome_strip {} {
	ui::box 0 0 $editor::W 46 -fill $editor::c(d2)
	ui::box 0 45 $editor::W 1 -fill $editor::c(border)
	more_button [expr {$editor::W - 150}]
	control_zone
}

# The active tab's curved feet: a 10 px fillet at each bottom corner, a bar square with a strip-coloured disc at its
# outer corner, joining the tab's walls to the rule.
proc tabs::feet {x w} {
	set bar $editor::c(bar); set d2 $editor::c(d2); set r 10
	ui::box [expr {$x - $r}] [expr {46 - $r}] $r $r -fill $bar
	ui::box [expr {$x - 2 * $r}] [expr {46 - 2 * $r}] [expr {2 * $r}] [expr {2 * $r}] -fill $d2 -radius $r
	ui::box [expr {$x + $w}] [expr {46 - $r}] $r $r -fill $bar
	ui::box [expr {$x + $w}] [expr {46 - 2 * $r}] [expr {2 * $r}] [expr {2 * $r}] -fill $d2 -radius $r
}

# One tab of pane P at X. ON: joined to the page (bar fill, with curved feet where its walls meet the rule). Otherwise a
# hovered tab gets the field fill and a 1 px separator on its right edge when the next tab is not the active one.
# A press activates the tab (in its pane); a drag that ends on another pane's strip or page moves it there.
proc tabs::draw_tab {p id x w on hov} {
	set fg $editor::c(fg); set muted $editor::c(muted)
	set bar $editor::c(bar); set d2 $editor::c(d2)
	if {$on} {
		ui::box $x 10 $w 40 -fill $bar -radius 10
	} elseif {$hov} {
		ui::box $x 12 $w 30 -fill $editor::c(field) -radius 8
	} elseif {$id ne [split::val $p active]} {
		ui::box [expr {$x + $w - 1}] 21 1 14 -fill $editor::c(border)
	}
	set bgc [expr {$on ? $bar : ($hov ? $editor::c(field) : $d2)}]
	# an inactive window's active tab keeps its weight and takes the muted colour (Editor-Final-7)
	set col [expr {($on && $editor::winfocus) || $hov ? $fg : $muted}]
	set fnt [expr {$on ? "i13s" : "i13m"}]
	set nw [expr {$w - 14 - 8 - 18 - 8}]
	name_fade $x $w [doc::name $id] $fnt $col $bgc $nw
	set sx [expr {$x + $w - 8 - 18}]
	set sy 19
	ui::hit $x 10 $w 36 [list tabs::press_tab $p $id] [list split::tab_drag $p $id] [list split::tab_drop $p $id]
	if {$hov} {
		ui::box $sx $sy 18 18 -fill $editor::c(pill) -radius 9
		editor::icon x 9 $fg [expr {$sx + 4.5}] [expr {$sy + 4.5}]
	} elseif {[doc::dirty $id]} {
		ui::box [expr {$sx + 5.5}] [expr {$sy + 5.5}] 7 7 -fill [expr {$on && $editor::winfocus ? $fg : $muted}] -radius 3.5
	} elseif {$on} {
		editor::icon x 10 $muted [expr {$sx + 4}] [expr {$sy + 4}]
	}
	ui::hit $sx $sy 18 18 [list tabs::press_close $p $id]
}

# The name in the tab's name area at X + 14, width NW. A name that fits is drawn whole. One that does not is cut
# where it reaches NW and its last 36 px fade into the tab's colour (BGC), letter by letter, instead of ending in "...".
proc tabs::name_fade {x w name fnt col bgc nw} {
	set x0 [expr {$x + 14}]
	if {[ui::measure $fnt $name] <= $nw} {
		ui::text $x0 20 $name $fnt $col
		return
	}
	set n [string length $name]
	while {$n > 0 && [ui::measure $fnt [string range $name 0 [expr {$n - 1}]]] > $nw} { incr n -1 }
	set clip [string range $name 0 [expr {$n - 1}]]
	set fadeat [expr {[ui::measure $fnt $clip] - 36}]
	for {set k 0} {$k < [string length $clip]} {incr k} {
		set px [ui::measure $fnt [string range $clip 0 [expr {$k - 1}]]]
		set t [expr {max(0.0, min(1.0, ($px - $fadeat) / 36.0))}]
		ui::text [expr {$x0 + $px}] 20 [string index $clip $k] $fnt [well::mix $col $bgc $t]
	}
}

# A press on a tab: its pane takes the focus, then the tab is shown.
proc tabs::press_tab {p id x y} {
	set split::pressx $x
	split::focus_to $p
	editor::activate $id
}

proc tabs::press_close {p id x y} {
	split::focus_to $p
	editor::close_docs [list $id]
}

proc tabs::toggle {args} { editor::toggle_pop }

namespace eval tabs { variable popscroll 0 }

# The rows the open-documents list can show in the window: it starts at y 52 and ends 8 px above the bottom edge.
proc tabs::max_rows {} {
	expr {max(1, ($editor::H - 8 - 52 - 8 - 36 - 6 - 8) / 36)}
}

# The wheel over the open list scrolls its rows (D: -1 up, 1 down).
proc tabs::pop_wheel {d} {
	variable popscroll
	set most [expr {max(0, [llength [visible_docs]] - [max_rows])}]
	set popscroll [expr {max(0, min($most, $popscroll + $d))}]
	editor::schedule
}

# Open the list with the active document's row in view.
proc tabs::pop_reveal {} {
	variable popscroll
	set i [lsearch -exact [visible_docs] $editor::active]
	set fit [max_rows]
	if {$i < 0} { set popscroll 0; return }
	if {$i < $popscroll} { set popscroll $i }
	if {$i >= $popscroll + $fit} { set popscroll [expr {$i - $fit + 1}] }
}

# The open-documents list (Editor-Final-2): 420 wide, under the strip, ending at the count button's right edge. It lists
# the focused pane's tabs.
proc tabs::popover {items} {
	set fg $editor::c(fg); set muted $editor::c(muted); set field $editor::c(field)
	variable popscroll
	set rows [visible_docs]
	set n [llength $rows]
	set x [expr {[split::px $split::cur] + 14 + [region $split::cur] + 36 + 48 - 420}]
	set y 52
	# at most as many rows as fit above the window's bottom edge (8 px clear of it); the rest scroll (the wheel)
	set fit [max_rows]
	set popscroll [expr {max(0, min($popscroll, $n - $fit))}]
	set shown [expr {min($n, $fit)}]
	set h [expr {8 + 36 + 6 + 36 * max(1, $shown) + 8}]
	ui::box $x $y 420 $h -fill $field -radius 12
	ui::ring $x $y 420 $h 12 $editor::c(border) 1
	ui::hit $x $y 420 $h [list editor::noop]
	ui::box [expr {$x + 8}] [expr {$y + 8}] 404 36 -fill $editor::c(bar) -radius 9
	ui::ring [expr {$x + 8}] [expr {$y + 8}] 404 36 9 $editor::c(accent) 1.5
	editor::icon search 14 $muted [expr {$x + 20}] [expr {$y + 19}]
	if {$editor::popq eq ""} {
		ui::text [expr {$x + 44}] [expr {$y + 19}] "Open documents" i13 $muted
	} else {
		ui::text [expr {$x + 44}] [expr {$y + 19}] $editor::popq i13 $fg
		set tw [ui::measure i13 $editor::popq]
		ui::box [expr {$x + 44 + $tw + 1}] [expr {$y + 16}] 2 16 -fill $editor::c(accent)
	}
	set ry [expr {$y + 8 + 36 + 6}]
	if {!$n} {
		ui::text [expr {$x + 20}] [expr {$ry + 11}] "No match" i12 $muted
	}
	foreach id [lrange $rows $popscroll [expr {$popscroll + $shown - 1}]] {
		set on [expr {$id eq $editor::active}]
		if {$on} { ui::box [expr {$x + 8}] $ry 404 36 -fill $editor::c(pill) -radius 8 }
		editor::icon [kind_icon $id] 15 [expr {$on ? $fg : $muted}] [expr {$x + 18}] [expr {$ry + 10}]
		ui::text [expr {$x + 43}] [expr {$ry + 11}] [doc::name $id] [expr {$on ? "i13s" : "i13m"}] $fg
		ui::text [expr {$x + 165}] [expr {$ry + 12}] [doc::folder $id] i12 $muted
		if {[doc::dirty $id]} {
			ui::box [expr {$x + 412 - 22}] [expr {$ry + 14}] 7 7 -fill [expr {$on ? $fg : $muted}] -radius 3.5
		}
		ui::hit [expr {$x + 8}] $ry 404 36 [list tabs::pick $id]
		incr ry 36
	}
}

# The list's icon for a document, by its kind: braces for code, hash for Markdown, gear for settings, lines for text.
proc tabs::kind_icon {id} {
	if {$::doc::D($id,untitled)} { return lines }
	switch -- [string tolower [file extension $::doc::D($id,path)]] {
		.tcl - .tk - .json - .py - .c - .h - .sh - .js { return braces }
		.md - .markdown { return hash }
		.ini - .conf - .toml - .desktop - .xml - .cfg { return gear }
		default { return lines }
	}
}

# Documents in the list: the focused pane's tab order, filtered by what has been typed (case-insensitive).
proc tabs::visible_docs {} {
	set out {}
	foreach id $editor::docs {
		if {$editor::popq eq "" || [string first [string tolower $editor::popq] [string tolower [doc::name $id]]] >= 0} {
			lappend out $id
		}
	}
	return $out
}

proc tabs::pick {id x y} {
	editor::close_pop
	editor::activate $id
}
