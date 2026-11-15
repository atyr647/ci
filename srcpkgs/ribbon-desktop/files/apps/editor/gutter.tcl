# gutter.tcl - Text editor (U28): the Well's marks beside the numbers (STYLE §20, Editor-Final-1).
#   change bars  a 3 px bar at a row's left edge for each line that differs from the text on disk: VADD for a line
#                added, VMOD for a line changed. A removal is a 10 x 3 VDEL tick at the foot of the line the removed
#                lines were under (the top of line 1 when they were above it). Untitled and not-yet-saved documents
#                have no file, so they have no bars.
#   fold chevrons  at x 55 on the first line of a block ({ ... } over lines). Clicking one folds the block: its inner
#                lines are elided, a "···" chip and the closing brace show after the first line. Clicking the chip, or
#                the chevron again, unfolds. Typing or moving the caret into a folded block unfolds it.
# The analysis is pure Tcl (diff::lines, gutter::blocks), so the tests run it without Tk.
#
# Hooks (hooks.tcl): editor::gutter_install runs once after the window is built (it binds the chevron click);
# editor::gutter_draw G runs on every paint, after the numbers.

namespace eval diff {}

namespace eval gutter {
	variable cache          ;# array: ID,saved / ID,cur / ID,res: the last analysis and the texts it was made from
	variable seq 0          ;# fold tag counter
	variable img            ;# array: icon key -> photo
	variable cap 150000     ;# the LCS table's size limit; a larger change is one block (every line in it marked)
}

# The line diff of two lists of lines, as {marks {N kind ...} dels {N pos ...}}. N is a line of NEW (1-based); kind is
# add or mod; a removal sits at the foot of line N (pos bottom), or at the top of line 1 (pos top).
proc diff::lines {old new} {
	variable ::gutter::cap
	set n [llength $old]
	set m [llength $new]
	set p 0
	while {$p < $n && $p < $m && [lindex $old $p] eq [lindex $new $p]} { incr p }
	set s 0
	while {$s < $n - $p && $s < $m - $p && [lindex $old [expr {$n - 1 - $s}]] eq [lindex $new [expr {$m - 1 - $s}]]} {
		incr s
	}
	set om [lrange $old $p [expr {$n - $s - 1}]]
	set nm [lrange $new $p [expr {$m - $s - 1}]]
	set ops [edit_ops $om $nm $cap]
	# walk the ops: a hunk is a run of deletes and inserts between two kept lines. ANCHOR is the number of new lines
	# before the hunk; its inserted lines are ANCHOR+1 .. ANCHOR+K.
	set marks {}
	set dels {}
	set newno $p
	set open 0; set anchor 0; set k 0; set d 0
	foreach op [split $ops {}] {
		if {$op eq "k"} {
			if {$open} { hunk $anchor $k $d marks dels; set open 0; set k 0; set d 0 }
			incr newno
			continue
		}
		if {!$open} { set open 1; set anchor $newno }
		if {$op eq "d"} { incr d } else { incr k; incr newno }
	}
	if {$open} { hunk $anchor $k $d marks dels }
	return [list marks $marks dels $dels]
}

# One hunk after line ANCHOR: K lines inserted, D deleted. Records into the named lists (see diff::lines).
proc diff::hunk {anchor k d marksVar delsVar} {
	upvar 1 $marksVar marks $delsVar dels
	if {$k > 0} {
		for {set i 0} {$i < $k} {incr i} {
			lappend marks [expr {$anchor + 1 + $i}] [expr {$i < $d ? "mod" : "add"}]
		}
		if {$d > $k} { lappend dels [expr {$anchor + $k}] bottom }
	} elseif {$d > 0} {
		if {$anchor <= 0} { lappend dels 1 top } else { lappend dels $anchor bottom }
	}
}

# The ops between old and new lines: k kept, d deleted, i inserted. A longest common subsequence over the middle part
# (the parts equal at both ends are already trimmed); above CAP cells the middle is one block of deletes and inserts.
proc diff::edit_ops {om nm cap} {
	set a [llength $om]
	set b [llength $nm]
	if {$a * $b > $cap} { return [string repeat d $a][string repeat i $b] }
	set w [expr {$b + 1}]
	set L [lrepeat [expr {($a + 1) * $w}] 0]
	for {set i [expr {$a - 1}]} {$i >= 0} {incr i -1} {
		set x [lindex $om $i]
		for {set j [expr {$b - 1}]} {$j >= 0} {incr j -1} {
			if {$x eq [lindex $nm $j]} {
				lset L [expr {$i * $w + $j}] [expr {[lindex $L [expr {($i + 1) * $w + $j + 1}]] + 1}]
			} else {
				set down [lindex $L [expr {($i + 1) * $w + $j}]]
				set right [lindex $L [expr {$i * $w + $j + 1}]]
				lset L [expr {$i * $w + $j}] [expr {max($down, $right)}]
			}
		}
	}
	set ops {}
	set i 0; set j 0
	while {$i < $a && $j < $b} {
		if {[lindex $om $i] eq [lindex $nm $j]} {
			append ops k; incr i; incr j
		} elseif {[lindex $L [expr {($i + 1) * $w + $j}]] >= [lindex $L [expr {$i * $w + $j + 1}]]} {
			append ops d; incr i
		} else {
			append ops i; incr j
		}
	}
	append ops [string repeat d [expr {$a - $i}]] [string repeat i [expr {$b - $j}]]
	return $ops
}

# The blocks of a text: {start end ...} (1-based lines) for each { that opens a block and the line that closes it. A
# line whose text ends in { opens one; a line that starts with } closes the block at its depth (and a } else { line
# closes one and opens the next). Comment lines and backslash-escaped braces are skipped. Returns a dict start -> end.
proc gutter::blocks {lines} {
	set out {}
	set depth 0
	set stack {}                    ;# {start level} for each open block
	set i 0
	foreach line $lines {
		incr i
		set t [string trim $line]
		if {$t eq "" || [string index $t 0] eq "#"} continue
		set clean [regsub -all {\\.} $t {}]
		set opens [regexp -all {\{} $clean]
		set closes [regexp -all {\}} $clean]
		set before $depth
		set depth [expr {$depth + $opens - $closes}]
		set starts [expr {[string index $t 0] eq "\}"}]
		if {$starts && [llength $stack] && [lindex $stack end 1] == $before} {
			set top [lindex $stack end]
			set stack [lrange $stack 0 end-1]
			if {$i > [lindex $top 0]} { dict set out [lindex $top 0] $i }
		}
		while {[llength $stack] && $depth < [lindex $stack end 1]} {
			set top [lindex $stack end]
			set stack [lrange $stack 0 end-1]
			if {$i > [lindex $top 0]} { dict set out [lindex $top 0] $i }
		}
		if {[string index $t end] eq "\{" && ($opens > $closes || $starts)} {
			lappend stack [list $i $depth]
		}
	}
	return $out
}

# The analysis of document ID: {marks dels blocks} from the saved text and the current text. Cached on the texts.
proc gutter::analysis {id} {
	variable cache
	set t [editor::tw $id]
	set cur [$t get 1.0 end-1c]
	set saved $::doc::D($id,saved)
	if {[info exists cache($id,res)] && $cache($id,cur) eq $cur && $cache($id,saved) eq $saved} {
		return $cache($id,res)
	}
	set marks {}; set dels {}
	if {!$::doc::D($id,untitled) && [file isfile $::doc::D($id,path)]} {
		set d [diff::lines [split $saved \n] [split $cur \n]]
		set marks [dict get $d marks]
		set dels [dict get $d dels]
	}
	set res [dict create marks $marks dels $dels blocks [blocks [split $cur \n]]]
	set cache($id,cur) $cur
	set cache($id,saved) $saved
	set cache($id,res) $res
	return $res
}

# The folds of document ID as a dict: first line of a folded block -> its fold tag. Folds whose text is gone are dropped.
proc gutter::folds {id} {
	set t [editor::tw $id]
	set out {}
	set keep {}
	foreach tag $::doc::D($id,folds) {
		set r [$t tag ranges $tag]
		if {![llength $r]} { $t tag delete $tag; continue }
		lappend keep $tag
		set line [lindex [split [lindex $r 0] .] 0]
		dict set out [expr {$line - 1}] $tag
	}
	set ::doc::D($id,folds) $keep
	return $out
}

# Fold the block starting at line S of the active document (no-op when S starts no block, or is already folded).
proc gutter::fold {s} {
	set id $::editor::active
	if {$id eq ""} return
	set blocks [dict get [analysis $id] blocks]
	if {![dict exists $blocks $s] || [dict exists [folds $id] $s]} return
	set t [editor::tw $id]
	variable seq
	set tag fold[incr seq]
	$t tag configure $tag -elide 1
	$t tag add $tag "[expr {$s + 1}].0" "[expr {[dict get $blocks $s] + 1}].0"
	lappend ::doc::D($id,folds) $tag
	editor::schedule
}

proc gutter::unfold {s} {
	set id $::editor::active
	if {$id eq ""} return
	set fs [folds $id]
	if {![dict exists $fs $s]} return
	set tag [dict get $fs $s]
	[editor::tw $id] tag delete $tag
	set ::doc::D($id,folds) [lsearch -all -inline -not -exact $::doc::D($id,folds) $tag]
	editor::schedule
}

# The caret is inside a folded block: unfold it, so the caret is never where it cannot be seen.
proc gutter::reveal {} {
	set id $::editor::active
	if {$id eq "" || ![info exists ::doc::D($id,folds)]} return
	set t [editor::tw $id]
	foreach tag $::doc::D($id,folds) {
		foreach {s e} [$t tag ranges $tag] {
			if {[$t compare insert >= $s] && [$t compare insert < $e]} {
				$t tag delete $tag
				set ::doc::D($id,folds) [lsearch -all -inline -not -exact $::doc::D($id,folds) $tag]
				break
			}
		}
	}
}

# A click on the chevron column folds or unfolds the block of the row clicked.
proc gutter::press {x y} {
	set id $::editor::active
	if {$id eq "" || $x < 40 || $x > 70} return
	set t [editor::tw $id]
	set blocks [dict get [analysis $id] blocks]
	foreach row [well::visible $t] {
		lassign $row n ry
		set h [lindex [$t dlineinfo $n.0] 3]
		if {$y < $ry || $y >= $ry + $h} continue
		if {![dict exists $blocks $n]} return
		if {[dict exists [folds $id] $n]} { unfold $n } else { fold $n }
		return
	}
}

# An icon, cached by its name, size and colour (the chevrons are drawn at every paint).
proc gutter::icon {name size colour} {
	variable img
	set key [list $name $size $colour]
	if {![info exists img($key)]} {
		set img($key) [raster::icon $::editor::paths($name) $size 2.2 [ui::col $colour] {} 0 0 0]
	}
	return $img($key)
}

# The marks for the visible rows of the active document, on gutter canvas G (called after the numbers).
proc gutter::draw {g} {
	set id $::editor::active
	if {$id eq "" || ![info exists ::doc::D($id,w)]} return
	set t [editor::tw $id]
	set rows {}
	foreach row [well::visible $t] {
		lassign $row n y
		lappend rows [list $n $y [lindex [$t dlineinfo $n.0] 3]]
	}
	marks $g $id $rows 0 ""
	chips $id [folds $id]
	diag::schedule $id
	diag::marks $g $id $rows
}

# The change bars, deletion ticks and fold chevrons of document ID on canvas G. ROWS is {line y height} for each line
# on screen; OX is the x of the gutter's left edge on G and TAG (if any) is put on every item.
proc gutter::marks {g id rows ox tag} {
	set a [analysis $id]
	set marks [dict get $a marks]
	set dels [dict get $a dels]
	set blocks [dict get $a blocks]
	set fs [folds $id]
	set bg [well::background]
	set open_col [well::mix $bg $::editor::c(muted) 0.5]
	set tags [expr {$tag eq "" ? "" : "-tags $tag"}]
	foreach row $rows {
		lassign $row n y h
		if {[dict exists $marks $n]} {
			set col [expr {[dict get $marks $n] eq "add" ? $::editor::c(vadd) : $::editor::c(vmod)}]
			$g create rectangle $ox $y [expr {$ox + 3}] [expr {$y + $h}] -fill $col -outline "" {*}$tags
		}
		if {[dict exists $dels $n]} {
			if {[dict get $dels $n] eq "top"} {
				$g create rectangle $ox [expr {$y - 1}] [expr {$ox + 10}] [expr {$y + 2}] -fill $::editor::c(vdel) -outline "" {*}$tags
			} else {
				$g create rectangle $ox [expr {$y + $h - 1}] [expr {$ox + 10}] [expr {$y + $h + 2}] -fill $::editor::c(vdel) -outline "" {*}$tags
			}
		}
		if {[dict exists $blocks $n]} {
			set folded [dict exists $fs $n]
			set img [gutter::icon [expr {$folded ? "right" : "chev"}] 15 [expr {$folded ? $::editor::c(fg) : $open_col}]]
			$g create image [expr {$ox + 48}] [expr {round($y + ($h - 15) / 2.0)}] -image $img -anchor nw {*}$tags
		}
	}
}

# An unfocused pane's marks, drawn on the window canvas under its veil: its lines are the rows overlay_text draws
# (22 px each from the body's top, the first at the document's top line), at the pane's gutter.
proc gutter::draw_pane {p} {
	set id [split::val $p active]
	if {$id eq "" || ![info exists ::doc::D($id,w)]} return
	set t [editor::tw $id $p]
	set top [expr {[info exists ::editor::topof($t)] ? $::editor::topof($t) : 1}]
	set last [lindex [split [$t index end] .] 0]
	set body [editor::body_top]
	set rows {}
	for {set row 0; set n $top} {$row < 31 && $n < $last} {incr row; incr n} {
		lappend rows [list $n [expr {$body + $row * 22}] 22]
	}
	marks $::editor::cv $id $rows [split::px $p] page
}

# The "···" chip and the closing brace of each folded block that is on screen. They are Tk widgets over the text,
# placed at the end of the block's first line; a click on either unfolds it.
proc gutter::chips {id fs} {
	set t [editor::tw $id]
	set page [winfo parent $t]
	foreach w [winfo children $page] {
		if {[string match $page.chip* $w]} { destroy $w }
	}
	set blocks [dict get [analysis $id] blocks]
	dict for {s tag} $fs {
		set info [$t dlineinfo $s.0]
		if {$info eq "" || [lindex $info 3] == 0} continue
		lassign [$t bbox "$s.end"] x y w h
		if {$x eq ""} continue
		set ly [lindex $info 1]
		set f $page.chip$tag
		frame $f -background $::editor::c(field) -highlightthickness 1 -highlightbackground $::editor::c(border) \
			-highlightcolor $::editor::c(border) -borderwidth 0 -takefocus 0
		label $f.dots -text "···" -font ui_i12 -foreground $::editor::c(muted) -background $::editor::c(field) \
			-padx 5 -pady 0 -borderwidth 0 -highlightthickness 0
		label $f.brace -text "\}" -font $::editor::codefont -foreground $::editor::c(syn_pun) -background $::editor::c(bar) \
			-padx 6 -pady 0 -borderwidth 0 -highlightthickness 0
		pack $f.dots -side left
		pack $f.brace -side left
		foreach k [list $f $f.dots $f.brace] { bind $k <ButtonPress-1> [list gutter::unfold $s] }
		place $f -x [expr {$x + 6}] -y [expr {$ly + 3}]
		raise $f
	}
}

proc editor::gutter_install {} {
	bind $::editor::gut <ButtonPress-1> {gutter::press %x %y}
}

proc editor::gutter_draw {g} {
	gutter::draw $g
}
