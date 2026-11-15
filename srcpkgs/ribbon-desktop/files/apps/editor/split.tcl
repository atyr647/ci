# split.tcl - Text editor (U30): the split view (Editor-Final-4-Split-B, STYLE §20). Two panes side by side, each with its
# own tabs, "+", "⋯", Well gutter, text and 32 px status line. The window controls sit in a 110 px zone behind a
# full-height rule. Only the focused pane's text is a Tk page; the other pane is drawn as canvas text under a 42 % veil
# (no caret, no current-line band).
#
# Pane state: the focused pane's tabs, active document and strip scroll are editor::docs, editor::active and
# editor::scroll (the code before the split reads them). A pane that is not focused keeps them in
# split::saved(P,docs|active|scroll). A document shown in both panes has a peer text widget per pane: doc::D(ID,w) is
# pane 0's widget and doc::D(ID,wP) pane P's. A peer shares the text and the tags (so highlighting, folds and find
# marks show in both) and keeps its own caret and scroll.
#
# Keys: Ctrl+\ splits and unsplits; Ctrl+1 and Ctrl+2 focus a pane. The rule is 1 px with an 8 px hit area and a 7 x 40
# grip; a pane is at least 320 px wide; a double click puts the rule back at halves; the ratio is kept for the window.
# Unsplitting or closing a pane moves its tabs to the other pane, so no document is closed by it.

namespace eval split {
	variable open 0          ;# the split view is on
	variable cur 0           ;# the focused pane: 0 (left) or 1 (right)
	variable ratio 0.5       ;# pane 0's share of the pane area
	variable MIN 320         ;# the narrowest pane
	variable drag ""         ;# "rule" while the divider is dragged
	variable tabmoved 0      ;# a tab press became a drag
	variable drop ""         ;# while a tab is dragged: {pane P X} (insert at X in pane P's strip) or {edge left|right}
	variable lift {}         ;# while a tab is dragged within its own strip: {P ID GAP} (lands at index GAP of the rest)
	variable pressx 0        ;# where the tab press was, so a small jitter is not a drag
	array set saved {0,docs {} 0,active {} 0,scroll 0 1,docs {} 1,active {} 1,scroll 0}
}

# The window's text areas: a Tk widget's pane, the editor's page frame and Well for pane P.
proc editor::pagew {p} { if {$p == 0} { return $::editor::page }; return "$::editor::page$p" }
proc editor::gutw {p} { if {$p == 0} { return $::editor::gut }; return "$::editor::gut$p" }

# The text widget of document ID shown in pane P (default: the focused pane). Pane 0's is the document's own widget.
proc editor::tw {id {p ""}} {
	if {$id eq ""} { return "" }
	if {$p eq ""} { set p $split::cur }
	if {$p == 0} { return $::doc::D($id,w) }
	if {[info exists ::doc::D($id,w$p)]} { return $::doc::D($id,w$p) }
	return [split::make_peer $id $p]
}

proc editor::split_toggle {args} { split::toggle }

proc split::is_split {} { variable open; return $open }

# The panes on screen, in order. Unsplit, only the focused one.
proc split::panes {} {
	variable open; variable cur
	if {$open} { return {0 1} }
	return [list $cur]
}

# Pane 0's width when split. The area is the window less the controls' zone (110 px); pane 0 ends 4 px before the rule
# and pane 1 starts 4 px after it, so the rule's 8 px hit area is not text.
proc split::w0 {} {
	variable ratio; variable MIN
	set area [expr {$::editor::W - 110}]
	set w [expr {int($area * $ratio + 0.5)}]
	expr {max($MIN + 4, min($area - $MIN - 4, $w))}
}

proc split::px {p} {
	variable open
	if {!$open || $p == 0} { return 0 }
	expr {[w0] + 4}
}

proc split::pw {p} {
	variable open
	if {!$open} { return $::editor::W }
	if {$p == 0} { return [expr {[w0] - 4}] }
	expr {$::editor::W - 110 - [px 1]}
}

# The rule's hit area, and the pane under x.
proc split::on_rule {x y} {
	variable open
	if {!$open} { return 0 }
	set r [w0]
	expr {$x >= $r - 4 && $x < $r + 4}
}

proc split::pane_at {x} {
	variable open; variable cur
	if {!$open} { return $cur }
	expr {$x < [w0] ? 0 : 1}
}

proc split::resize {x} {
	variable ratio
	set ratio [expr {double($x) / ($::editor::W - 110)}]
	editor::schedule
}

proc split::reset {} {
	variable ratio
	set ratio 0.5
	editor::schedule
}

# The value KEY (docs, active, scroll) of pane P: the editor's own variable for the focused pane.
proc split::val {p key} {
	variable cur; variable saved
	if {$p == $cur} { return [set ::editor::$key] }
	return $saved($p,$key)
}

proc split::put {p key v} {
	variable cur; variable saved
	if {$p == $cur} { set ::editor::$key $v } else { set saved($p,$key) $v }
}

# Copy the editor's variables into the focused pane's saved state, and back.
proc split::snap {} {
	variable cur; variable saved
	foreach k {docs active scroll} { set saved($cur,$k) [set ::editor::$k] }
}

proc split::select {p} {
	variable cur; variable saved
	set cur $p
	foreach k {docs active scroll} { set ::editor::$k $saved($p,$k) }
}

# Focus pane P: its state becomes the editor's, and its active document is the one on screen there.
proc split::focus_to {p} {
	variable cur
	if {$p == $cur} return
	snap
	select $p
	show $p
}

proc split::focus_pane {p} {
	variable open
	if {!$open} return
	focus_to $p
	editor::schedule
	editor::focus_text
}

# Pack pane P's active document into its page frame (one document per frame).
proc split::show {p} {
	set id [val $p active]
	if {$id eq ""} return
	set frame [editor::pagew $p]
	set w [editor::tw $id $p]
	foreach s [pack slaves $frame] { if {$s ne $w} { pack forget $s } }
	if {[lsearch -exact [pack slaves $frame] $w] < 0} { pack $w -in $frame -fill both -expand 1 }
}

# Pane P's frame and Well, made when the split is first used.
proc split::make_pane {p} {
	if {$p == 0 || [winfo exists [editor::pagew $p]]} return
	set f [editor::pagew $p]
	frame $f -width 100 -height 100 -background $::editor::bg -borderwidth 0 -highlightthickness 0
	pack propagate $f 0
	set g [editor::gutw $p]
	canvas $g -width 72 -height 100 -highlightthickness 0 -borderwidth 0
	bind $g <ButtonPress-1> {gutter::press %x %y}
}

# A peer of document ID's widget for pane P, with the same options; its scroll reports to editor::scrolled.
proc split::make_peer {id p} {
	make_pane $p
	set prim $::doc::D($id,w)
	set new [$prim peer create [editor::pagew $p].t$id]
	foreach o {-wrap -undo -autoseparators -font -padx -pady -spacing1 -spacing3 -tabs -background -foreground
		-insertbackground -selectbackground -inactiveselectbackground -borderwidth -highlightthickness -relief} {
		$new configure $o [$prim cget $o]
	}
	$new configure -yscrollcommand [list editor::scrolled $id $new]
	editor::bind_text $new
	set ::doc::D($id,w$p) $new
	return $new
}

# Split (both panes start on the focused pane's documents and active document) or unsplit.
proc split::toggle {args} {
	variable open; variable cur; variable saved
	if {$open} { unsplit $cur; return }
	snap
	set open 1
	set other [expr {1 - $cur}]
	make_pane $other
	foreach k {docs active scroll} { set saved($other,$k) $saved($cur,$k) }
	show 0
	show 1
	editor::schedule
}

# Keep KEEP: the other pane's tabs join its tabs and the split goes.
proc split::unsplit {keep} {
	variable open; variable saved; variable cur
	if {!$open} return
	focus_to $keep
	set other [expr {1 - $keep}]
	foreach id $saved($other,docs) { if {$id ni $::editor::docs} { lappend ::editor::docs $id } }
	set open 0
	show $cur
	editor::schedule
}

# A pane with no tabs goes: the other pane stays.
proc split::tidy {} {
	variable open
	if {!$open} return
	foreach p {0 1} {
		if {[val $p docs] eq ""} { unsplit [expr {1 - $p}]; return }
	}
}

proc split::neighbour {lst i} {
	if {![llength $lst]} { return "" }
	lindex $lst [expr {min($i, [llength $lst] - 1)}]
}

# Whether document ID is among the tabs of a pane other than the focused one.
proc split::in_other {id} {
	variable cur
	foreach p [panes] {
		if {$p != $cur && $id in [val $p docs]} { return 1 }
	}
	return 0
}

# Move tab ID from pane FROM to pane TO, and focus TO.
proc split::move_tab {from to id} {
	if {$from == $to} return
	snap
	set fd [val $from docs]
	set i [lsearch -exact $fd $id]
	if {$i < 0} return
	# A tab the other pane did not show yet takes its caret along (its widget there is new, at 1.0).
	set fresh [expr {$id ni [val $to docs]}]
	set at [expr {$fresh ? [[editor::tw $id $from] index insert] : ""}]
	set fd [lreplace $fd $i $i]
	put $from docs $fd
	if {[val $from active] eq $id} { put $from active [neighbour $fd $i] }
	set td [val $to docs]
	if {$id ni $td} { lappend td $id }
	put $to docs $td
	put $to active $id
	focus_to $to
	show $to
	if {$fresh} { set w [editor::tw $id $to]; $w mark set insert $at; $w see insert }
	tidy
	editor::schedule
}

proc split::move_other {} {
	variable cur
	move_tab $cur [expr {1 - $cur}] [val $cur active]
}

proc split::close_pane {} {
	variable cur
	unsplit [expr {1 - $cur}]
}

# A tab dropped on the other pane's strip (or page) moves there; dropped on the far edge of an unsplit window, it
# splits: the tab gets its own pane on that side.
# The drop mark follows the pointer: an insertion bar in the strip of the pane it would join (not its own), or the
# edge of an unsplit window it would split at.
proc split::tab_drag {p id x y} {
	variable tabmoved; variable open; variable drop; variable lift; variable pressx
	if {!$tabmoved && abs($x - $pressx) < 4 && $y < 46} return
	set tabmoved 1
	set drop ""
	set lift {}
	if {$y < 46 && [pane_at $x] == $p} {
		# within its own strip: the tab lifts and a gap opens where it would land
		set lift [list $p $id [gap_at $p $id $x]]
	} elseif {$open} {
		set q [pane_at $x]
		if {$q != $p} { set drop [list pane $q $x] }
	} elseif {$y >= 46} {
		if {$x < 48} {
			set drop [list edge left]
		} elseif {$x >= $::editor::W - 110 - 48} {
			set drop [list edge right]
		}
	}
	editor::schedule
}

proc split::tab_drop {p id x y} {
	variable tabmoved; variable open; variable drop; variable lift
	set moved $tabmoved
	set tabmoved 0
	set drop ""
	set lift {}
	if {!$moved} return
	if {$y < 46 && [pane_at $x] == $p} {
		reorder $p $id [gap_at $p $id $x]
		editor::schedule
		return
	}
	if {$open} {
		set q [pane_at $x]
		if {$q != $p} { move_tab $p $q $id }
		editor::schedule
		return
	}
	if {$y < 46} { editor::schedule; return }
	if {$x < 48} {
		edge_split $id left
	} elseif {$x >= $::editor::W - 110 - 48} {
		edge_split $id right
	}
	editor::schedule
}

# The place in pane P's tabs, the dragged tab ID left out, where a drop at window X lands: before the first tab whose
# middle is right of X.
proc split::gap_at {p id x} {
	set lx [expr {$x - [px $p] + [val $p scroll]}]
	set k 0
	set tx 14
	foreach d [val $p docs] {
		if {$d eq $id} continue
		set w [tabs::width $d]
		if {$lx < $tx + $w / 2} { return $k }
		incr tx $w
		incr k
	}
	return $k
}

# Tab ID of pane P goes to place I of the other tabs.
proc split::reorder {p id i} {
	set rest [lsearch -exact -all -inline -not [val $p docs] $id]
	put $p docs [linsert $rest $i $id]
}

# The drop mark while a tab is dragged (drawn over the strips): a 2 px bar where the tab would go, or a 48 px wash on
# the window edge it would split at. No accent.
proc split::draw_drop {} {
	variable drop
	if {$drop eq ""} return
	lassign $drop kind a b
	if {$kind eq "edge"} {
		set x [expr {$a eq "left" ? 0 : $::editor::W - 110 - 48}]
		ui::fbox $x 46 48 [expr {$::editor::H - 46}] -fill $::editor::c(fg) -alpha 0.12
		return
	}
	set x0 [px $a]
	set x [expr {max($x0 + 2, min($x0 + [pw $a] - 2, $b))}]
	ui::box $x 8 2 32 -fill $::editor::c(fg)
}

proc split::edge_split {id side} {
	variable open; variable saved; variable cur
	if {$open} return
	snap
	set rest [lsearch -exact -all -inline -not $saved($cur,docs) $id]
	if {$rest eq ""} { set rest [list $id] }
	set ra $saved($cur,active)
	if {$ra eq $id || $ra ni $rest} { set ra [neighbour $rest 0] }
	set rs $saved($cur,scroll)
	if {$side eq "right"} {
		set saved(0,docs) $rest; set saved(0,active) $ra; set saved(0,scroll) $rs
		set saved(1,docs) [list $id]; set saved(1,active) $id; set saved(1,scroll) 0
		set focusp 1
	} else {
		set saved(0,docs) [list $id]; set saved(0,active) $id; set saved(0,scroll) 0
		set saved(1,docs) $rest; set saved(1,active) $ra; set saved(1,scroll) $rs
		set focusp 0
	}
	set open 1
	make_pane 1
	select $focusp
	show 0
	show 1
	editor::schedule
}

# The chrome of a split window: the gap and rule between the panes, the grip, and the controls' zone.
proc tabs::split_chrome {} {
	set W $editor::W; set H $editor::H
	set r [split::w0]
	ui::box [expr {$r - 4}] 0 8 46 -fill $editor::c(d2)
	ui::box $r 0 1 $H -fill $editor::c(border)
	ui::box [expr {$r - 3}] [expr {($H - 32 + 46) / 2 - 20}] 7 40 -fill $editor::c(field) -radius 3.5
	control_zone
}

# Every document open in either pane, in tab order of the panes.
proc split::union {} {
	set out {}
	foreach p [panes] {
		foreach id [val $p docs] { if {$id ni $out} { lappend out $id } }
	}
	return $out
}

proc editor::split_install {} {}
