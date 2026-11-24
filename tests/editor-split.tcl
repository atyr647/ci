# editor-split.tcl - the text editor's split view (U31), run by apps/editor/main.tcl through RIBBON_EDITOR_SCENE=this
# file, with RIBBON_EDITOR_FIXTURES = a temp folder.
# 1. Ctrl+\ splits and unsplits; Ctrl+1 and Ctrl+2 move the focus between the panes.
# 2. Each pane is at least 320 px wide, at both ends of the rule.
# 3. The rule is dragged (the chrome procs a press, motion and release make), set through split::resize, and a double
#    click on it resets it to halves.
# 4. A tab moves to the other pane; a tab dropped on the far edge of an unsplit window splits it there.
# 5. The same document in both panes (a widget in each, each with its own caret; the status line follows focus; a tab
#    moved to the other pane keeps its caret); the drop mark shows while a tab is dragged across.
# 6. Within one pane a tab dragged along the strip lifts and a gap opens where it would land; dropped, it takes that
#    place in the tab order (pressed and dragged as mouse events on the window's canvas).
# 7. The open-documents list of 30 documents stays inside the window; the wheel scrolls its rows.
# Prints "  ok ..." per check; exits 0 when all pass, 1 otherwise.
set dir $::env(RIBBON_EDITOR_FIXTURES)
file mkdir $dir
set fails 0
proc ok {what} { puts "  ok   $what"; flush stdout }
proc check {what cond} {
	if {[uplevel 1 [list expr $cond]]} { ok $what } else { global fails; incr fails; puts "  FAIL $what" }
}
proc bgerror {msg} { puts stderr "editor-split: $msg\n$::errorInfo"; exit 1 }
proc press {keysym} { focus -force $::editor::win; event generate $::editor::win <$keysym>; update }
proc write_text {path text} {
	set fh [open $path wb]
	fconfigure $fh -translation binary
	puts -nonewline $fh [encoding convertto utf-8 $text]
	close $fh
}

write_text [file join $dir a.txt] "alpha\none\ntwo\nthree\n"
write_text [file join $dir b.txt] "beta\nfour\nfive\n"
set a [editor::open_path [file join $dir a.txt]]
set b [editor::open_path [file join $dir b.txt]]
editor::activate $a
update

puts "keys"
press Control-backslash
check "Ctrl+\\ splits the window" {[split::is_split]}
press Control-backslash
check "Ctrl+\\ again unsplits it" {![split::is_split]}
press Control-backslash
press Control-Key-2
check "Ctrl+2 focuses the right pane" {$split::cur == 1}
press Control-Key-1
check "Ctrl+1 focuses the left pane" {$split::cur == 0}
press Control-Key-2
press Control-Key-1

puts "minimum width"
set split::ratio 0.0
check "a pane's width is at least 320 px at the narrowest split" {[split::pw 0] >= 320}
check "the other pane is then 320 px or more too" {[split::pw 1] >= 320}
set split::ratio 1.0
check "and at the widest split" {[split::pw 1] >= 320 && [split::pw 0] >= 320}
check "the rule can not be dragged past a pane's minimum" {[split::w0] <= $::editor::W - 110 - 320 - 4}

puts "rule"
split::reset
check "the rule starts at halves" {$split::ratio == 0.5}
set r [split::w0]
check "the rule has an 8 px hit area" {[split::on_rule $r 300] && ![split::on_rule [expr {$r + 5}] 300]}
editor::chrome_press $r 300
editor::chrome_motion 500 300
editor::chrome_release 500 300
check "dragging the rule moves it to the pointer" {[split::w0] == 500}
check "the drag is over" {$split::drag eq ""}
split::resize 400
check "split::resize sets the rule from its x" {[split::w0] == 400}
editor::chrome_double 400 300
check "a double click on the rule resets it to halves" {$split::ratio == 0.5}

puts "tabs"
check "the second pane starts with the first pane's tabs" {[llength [split::val 1 docs]] == [llength [split::val 0 docs]]}
split::move_tab 0 1 $b
check "a tab moves to the other pane" {$b in [split::val 1 docs] && $b ni [split::val 0 docs]}
check "the moved tab is active there and focus follows it" {[split::val 1 active] eq $b && $split::cur == 1}
split::unsplit 0
check "unsplit keeps the pane's documents" {![split::is_split] && [llength [split::union]] >= 2}

split::tab_drag 0 $a 10 100
check "a tab dragged over the left edge shows the drop mark there" {$split::drop eq "edge left"}
split::tab_drop 0 $a 10 100
check "dropping it on the far edge splits the window with the tab on that side" {[split::is_split] && $a in [split::val 0 docs] && $split::drop eq ""}
check "and the pane it came from keeps the other tabs" {[llength [split::val 1 docs]] >= 1}

puts "same document"
split::focus_to 0
split::put 0 docs [list $a $b]
editor::activate $a
update
set t0 [editor::tw $a 0]
set t1 [editor::tw $a 1]
check "a document open in both panes has a widget in each" {$t0 ne $t1}
check "both show the same text" {[$t0 get 1.0 end] eq [$t1 get 1.0 end]}

puts "carets"
# The status lines that paint draws, in pane order (the text of each "Ln n, Col n" the Well writes).
proc status_line {} {
	rename ui::text ui::text_real
	proc ui::text {x top str args} {
		if {[string match "Ln *" $str]} { lappend ::status_seen $str }
		uplevel 1 [list ui::text_real $x $top $str {*}$args]
	}
	set ::status_seen {}
	editor::paint
	rename ui::text {}
	rename ui::text_real ui::text
	return $::status_seen
}
split::put 1 docs [list $a]
split::put 1 active $a
split::focus_to 0
split::show 0
split::show 1
$t0 mark set insert 2.1
split::focus_pane 1
[editor::tw $a] mark set insert 3.2
update
check "each pane keeps its own caret" {[$t0 index insert] eq "2.1" && [$t1 index insert] eq "3.2"}
split::focus_pane 0
update
check "focus moves back and both carets stay" {$split::cur == 0 && [$t0 index insert] eq "2.1" && [$t1 index insert] eq "3.2"}
set s [status_line]
check "the status bar of the focused left pane shows its line and column" {[lindex $s 0] eq "Ln 2, Col 2"}
split::focus_pane 1
update
set s [status_line]
check "the status bar follows focus to the right pane" {[lindex $s 1] eq "Ln 3, Col 3"}
split::focus_to 0
set tb [editor::tw $b 0]
$tb mark set insert 2.2
split::move_tab 0 1 $b
check "a tab moved to the other pane keeps its caret" {[[editor::tw $b 1] index insert] eq "2.2"}

puts "drop mark"
split::tab_drag 0 $b [expr {[split::px 1] + 40}] 100
check "a tab dragged over the other pane shows its insertion mark there" {[lindex $split::drop 0] eq "pane" && [lindex $split::drop 1] == 1}
split::tab_drag 0 $b 10 100
check "a tab dragged over its own pane shows no mark" {$split::drop eq ""}
split::tab_drop 0 $b 10 100
check "the mark is gone when the tab is dropped" {$split::drop eq ""}

puts "reorder in one pane"
if {[split::is_split]} { split::toggle }
update
foreach id [split::union] { editor::force_close $id }
set ids {}
foreach n {one two three four} {
	write_text [file join $dir $n.txt] "$n\n"
	lappend ids [editor::open_path [file join $dir $n.txt]]
}
editor::paint; update
# the window's canvas, as the person drags: press on tab 1, move right past tab 3's middle, release
proc tab_x {id} { foreach it [lindex [tabs::layout $split::cur] 0] { lassign $it i x w; if {$i eq $id} { return [expr {$x + 20}] } }; return -1 }
set cv $::editor::cv
set x1 [tab_x [lindex $ids 0]]
# with tab 1 lifted out, tabs 2 and 3 start the row: just past tab 3's middle is the gap after it
set past [expr {14 + [tabs::width [lindex $ids 1]] + [tabs::width [lindex $ids 2]] / 2 + 6}]
event generate $cv <ButtonPress-1> -x $x1 -y 28
event generate $cv <B1-Motion> -x [expr {$x1 + 10}] -y 28
event generate $cv <B1-Motion> -x $past -y 28
editor::paint; update
check "dragged along its own strip, the tab lifts: it is out of the row and a gap is where it would land" {
	[llength $split::lift] == 3 && [lindex $split::lift 1] eq [lindex $ids 0] && [lindex $split::lift 2] == 2 &&
	[lsearch -index 0 [lindex [tabs::layout $split::cur] 0] [lindex $ids 0]] < 0}
event generate $cv <ButtonRelease-1> -x $past -y 28
update
check "dropped past tab 3, tab 1 takes the place after it" {
	$::editor::docs eq [list [lindex $ids 1] [lindex $ids 2] [lindex $ids 0] [lindex $ids 3]] && $split::lift eq ""}
set x4 [tab_x [lindex $ids 3]]
event generate $cv <ButtonPress-1> -x $x4 -y 28
event generate $cv <B1-Motion> -x 20 -y 28
event generate $cv <ButtonRelease-1> -x 20 -y 28
update
check "dragged to the strip's start, the last tab becomes the first" {[lindex $::editor::docs 0] eq [lindex $ids 3]}
set before $::editor::docs
set x2 [tab_x [lindex $ids 1]]
event generate $cv <ButtonPress-1> -x $x2 -y 28
event generate $cv <B1-Motion> -x [expr {$x2 + 2}] -y 28
event generate $cv <ButtonRelease-1> -x [expr {$x2 + 2}] -y 28
update
check "a press that moves 2 px is a click: the order stays" {$::editor::docs eq $before && $::editor::active eq [lindex $ids 1]}

puts "list height"
for {set i 0} {$i < 26} {incr i} {
	write_text [file join $dir many$i.txt] "$i\n"
	editor::open_path [file join $dir many$i.txt]
}
editor::toggle_pop
editor::paint; update
set rows [tabs::max_rows]
set h [expr {8 + 36 + 6 + 36 * min(30, $rows) + 8}]
check "30 documents: the list shows only the rows that fit, and ends inside the window" {
	[llength [tabs::visible_docs]] == 30 && $rows < 30 && 52 + $h <= $::editor::H - 8}
check "it opens with the active document's row in view" {
	[set i [lsearch -exact [tabs::visible_docs] $::editor::active]] >= $tabs::popscroll && $i < $tabs::popscroll + $rows}
set ::tabs::popscroll 0
event generate $cv <Button-5> -x 600 -y 200
update
check "the wheel scrolls its rows" {$tabs::popscroll == 1}
for {set i 0} {$i < 40} {incr i} { event generate $cv <Button-5> -x 600 -y 200 }
update
check "and stops at the last row" {$tabs::popscroll == 30 - $rows}
# typing filters the list from its top: the first match is the one Enter opens, so it is in view
editor::key_top m m
editor::paint; update
check "typing into the scrolled list shows the matches from the first (the one Enter opens)" {
	[llength [tabs::visible_docs]] > $rows && $tabs::popscroll == 0}
editor::close_pop

if {$fails} { puts "editor split: $fails checks failed"; exit 1 }
puts "editor split: all checks passed"
exit 0
