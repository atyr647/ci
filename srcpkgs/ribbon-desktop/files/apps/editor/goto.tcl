# goto.tcl - Text editor: Go to line (board Editor-R4-2-Goto, design/tools/gen_editor_r4.py). Ctrl+L, or "Go to line…"
# in the ⋯ menu, puts one row in the find bar's place under the tab strip: the line field (400 wide, as the find field;
# the go-to icon; the document's line count, "of 53", at its right end) and the close × at the right. It acts on the
# focused pane's document. Digits only; Enter puts the caret at the start of that line (past the end: the last line)
# and closes the row; Esc or × closes it and leaves the caret where it was. Find and Go to line share the place: opening
# one closes the other.
#
# The row is drawn on the chrome canvas each paint (main.tcl calls goto::paint beside find::paint, and body_top adds
# goto::height); its field is a ui library field, so the keys go to ui::field_key while the window has the focus.

namespace eval goto {
	variable open 0
	variable X 88               ;# the field lines up with the code (TEXT_X), as the find field
	variable FW 400
	variable R1 56              ;# the row's top: 10 under the strip
}

proc goto::height {} {
	variable open
	expr {$open ? 52 : 0}
}

proc goto::open {} {
	variable open
	if {$::editor::active eq ""} return
	if {$::find::open} { find::close_bar }
	menu::hide
	set open 1
	ui::fset goto.q ""
	set ::ui::focus goto.q
	focus $::editor::win
	ui::blink
	editor::schedule
}

proc goto::close {args} {
	variable open
	if {!$open} return
	set open 0
	if {$::ui::focus eq "goto.q"} { set ::ui::focus "" }
	editor::focus_text
	editor::schedule
}

# The active document's line count (a text widget ends in a newline it does not show).
proc goto::count {} {
	set t [editor::tw $::editor::active]
	expr {max(1, [lindex [split [$t index end-1c] .] 0])}
}

# Only digits stay in the field.
proc goto::changed {} {
	set v [ui::fval goto.q]
	regsub -all {[^0-9]} $v "" d
	if {$d ne $v} { ui::fset goto.q $d }
	editor::schedule
}

# Enter: the caret to the start of the line typed (clamped to the document), the row closes. An empty field only closes.
proc goto::go {} {
	set v [ui::fval goto.q]
	if {$v ne "" && $::editor::active ne ""} {
		set n [expr {min(max(1, [scan $v %d]), [count])}]
		set t [editor::tw $::editor::active]
		$t tag remove sel 1.0 end
		$t mark set insert $n.0
		$t see insert
	}
	close
}

# A key while the window has the focus: the field takes it. Returns 1 when it was used.
proc goto::key {sym char} {
	variable open
	if {!$open || $::ui::focus ne "goto.q"} { return 0 }
	if {$sym in {Return KP_Enter}} { go; return 1 }
	return [ui::field_key goto.q $sym $char 0]
}

proc goto::paint {} {
	variable open
	variable X
	variable FW
	variable R1
	if {!$open} return
	if {$::editor::active eq ""} { set open 0; return }
	ui::hline 0 $::editor::W [expr {46 + [height] - 1}] $::editor::c(border)
	ui::field goto.q $X $R1 $FW -h 32 -radius 8 -pad 34 -font mono13 -max 9 -onchange goto::changed -onenter goto::go
	editor::icon goto 14 $::editor::c(muted) [expr {$X + 12}] [expr {$R1 + 9}] 1.9
	ui::text [expr {$X + $FW - 12}] [ui::lh $R1 i12 32] "of [count]" i12 $::editor::c(muted) e
	set close [expr {$::editor::W - 40}]
	editor::icon x 15 $::editor::c(fg) [expr {$close + 7.5}] [expr {$R1 + 8.5}] 2
	ui::hit $close $R1 30 32 goto::close
}

set ::editor::paths(goto) {M15 10l5 5-5 5 M4 4v7a4 4 0 0 0 4 4h12}
