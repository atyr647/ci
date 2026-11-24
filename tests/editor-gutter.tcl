# editor-gutter.tcl - the text editor's Well marks (U28), run by apps/editor/main.tcl through RIBBON_EDITOR_SCENE=this
# file, with RIBBON_EDITOR_FIXTURES = a temp folder.
# 1. the line diff (diff::lines) and the blocks (gutter::blocks), on lists and texts: changes, inserts, removals at
#    the top, the bottom and in the middle, the LCS on a moved line, and the size cap.
# 2. the change bars of a document against its file on disk: after an edit, after a save, for an untitled document;
#    the bars on the gutter canvas after a paint, and their place after a scroll.
# 3. folds: a Tcl proc folds and unfolds (its inner lines are elided), the chip is on screen, the caret inside a
#    folded block unfolds it, and a click on the chevron folds it.
# Prints "  ok ..." per check; exits 0 when all pass, 1 otherwise.
set dir $::env(RIBBON_EDITOR_FIXTURES)
file mkdir $dir
set fails 0
proc ok {what} { puts "  ok   $what"; flush stdout }
proc check {what cond} {
	if {[uplevel 1 [list expr $cond]]} { ok $what } else { global fails; incr fails; puts "  FAIL $what" }
}
proc bgerror {msg} { puts stderr "editor-gutter: $msg\n$::errorInfo"; exit 1 }
proc write_text {path text} {
	set fh [open $path wb]
	fconfigure $fh -translation binary
	puts -nonewline $fh [encoding convertto utf-8 $text]
	close $fh
}
# the number of bars of colour COL on the gutter canvas (after a paint)
proc bars {col} {
	set n 0
	foreach item [$::editor::gut find all] {
		if {[$::editor::gut type $item] eq "rectangle" && [$::editor::gut itemcget $item -fill] eq $col} { incr n }
	}
	return $n
}
# the y of each bar of colour COL on the gutter canvas (after a paint)
proc bar_rows {col} {
	set ys {}
	foreach item [$::editor::gut find all] {
		if {[$::editor::gut type $item] eq "rectangle" && [$::editor::gut itemcget $item -fill] eq $col} {
			lappend ys [lindex [$::editor::gut coords $item] 1]
		}
	}
	return $ys
}
proc paint_now {} { editor::paint; update idletasks; update }
# whether line N of T has a box on screen (an elided line has one of height 0)
proc shown {t n} { set i [$t dlineinfo $n.0]; expr {$i ne "" && [lindex $i 3] > 0} }

# ---- 1. the diff and the blocks ----
puts "diff"
check "identical texts: no marks" {[dict get [diff::lines {a b c} {a b c}] marks] eq "" && [dict get [diff::lines {a b c} {a b c}] dels] eq ""}
check "a line changed in place is changed (mod)" {[dict get [diff::lines {a b c} {a X c}] marks] eq {2 mod}}
check "lines added at the end are added" {[dict get [diff::lines {a} {a b c}] marks] eq {2 add 3 add}}
check "a line removed in the middle leaves a removal at the foot of the line above" {
	[dict get [diff::lines {a b c} {a c}] dels] eq {1 bottom} && [dict get [diff::lines {a b c} {a c}] marks] eq ""}
check "a line removed at the top is a removal at the top of line 1" {[dict get [diff::lines {a b} {b}] dels] eq {1 top}}
check "two lines replaced by three: two changed and one added" {
	[dict get [diff::lines {a b c d} {a X Y Z d}] marks] eq {2 mod 3 mod 4 add}}
check "three lines replaced by one: a change, and a removal under it" {
	[dict get [diff::lines {a b c d e} {a X e}] marks] eq {2 mod} && [dict get [diff::lines {a b c d e} {a X e}] dels] eq {2 bottom}}
check "a common line keeps its place (LCS): two separate changes" {
	[dict get [diff::lines {1 2 3 4 5} {1 9 3 8 5}] marks] eq {2 mod 4 mod}}
check "above the size cap a change is one block of deletes and inserts" {[diff::edit_ops {a b} {c} 0] eq "ddi"}

puts "blocks"
set code {proc a {} {
    foreach x {1 2} {
        if {$x} {
            puts $x
        } else {
            puts no
        }
    }
}}
set b [gutter::blocks [split $code \n]]
check "proc, foreach and if blocks end on their closing lines, and } else { opens the next" {
	[dict get $b 1] == 9 && [dict get $b 2] == 8 && [dict get $b 3] == 5 && [dict get $b 5] == 7 && [dict size $b] == 4}
set cl [list "# proc x \{" "set y 1"]
check "a comment line that holds a brace opens no block" {[dict size [gutter::blocks $cl]] == 0}

# ---- 2. the change bars of a document ----
puts "change bars"
set p [file join $dir bars.tcl]
set disk ""
for {set i 1} {$i <= 40} {incr i} { append disk "line $i\n" }
write_text $p $disk
set id [editor::open_path $p]
set t $::doc::D($id,w)
check "a file as on disk has no change bars" {[dict size [dict get [gutter::analysis $id] marks]] == 0}
$t delete 5.0 5.end
$t insert 5.0 "CHANGED"
$t insert 9.end "\nADDED ONE\nADDED TWO"
paint_now
set m [dict get [gutter::analysis $id] marks]
check "an edited line is a changed bar" {[dict get $m 5] eq "mod"}
check "two added lines are added bars" {[dict get $m 10] eq "add" && [dict get $m 11] eq "add"}
check "the gutter canvas holds one change bar per marked line (after a paint)" {
	[bars $::editor::c(vmod)] == 1 && [bars $::editor::c(vadd)] == 2}
$t delete 20.0 21.0
check "a removal leaves a removal tick under the line above it" {[dict get [gutter::analysis $id] dels] ne ""}
check "saving makes the text the file's text: no bars" {
	[::doc::save $id] == 1 && [dict size [dict get [gutter::analysis $id] marks]] == 0 && [dict size [dict get [gutter::analysis $id] dels]] == 0}
paint_now
check "and the gutter canvas shows none after the save" {[bars $::editor::c(vmod)] == 0 && [bars $::editor::c(vadd)] == 0}

# the bar follows its line when the text scrolls
$t delete 1.0 1.end
$t insert 1.0 "FIRST"
$t insert 30.0 "LATE "
$t yview moveto 0
paint_now
# every change bar and removal tick on screen is on the row of its line: the rows of the marked lines that show
proc rows_match {t marks} {
	set want {}
	dict for {n kind} $marks { if {[shown $t $n]} { lappend want [lindex [$t dlineinfo $n.0] 1] } }
	set got [concat [bar_rows $::editor::c(vmod)] [bar_rows $::editor::c(vadd)]]
	set want [lsort -integer [lmap y $want { expr {round($y)} }]]
	set got [lsort -integer [lmap y $got { expr {round($y)} }]]
	expr {[llength $want] > 0 && $want eq $got}
}
$t yview 25
paint_now
check "scrolled down, each bar that shows is on the row of its line" {
	[$t index @0,0] ne "1.0" && [shown $t 30] && [rows_match $t [dict get [gutter::analysis $id] marks]]
}
$t yview moveto 0
paint_now
check "scrolled back, the bar for line 1 is on the row of line 1" {
	[rows_match $t [dict get [gutter::analysis $id] marks]] && [shown $t 1]
}
editor::force_close $id

set u [editor::new_doc]
check "an untitled document has no change bars" {[dict size [dict get [gutter::analysis $u] marks]] == 0}
editor::force_close $u

# ---- 3. folds ----
puts "folds"
set p2 [file join $dir fold.tcl]
write_text $p2 "proc one {} {\n    puts a\n    puts b\n}\nproc two {} {\n    puts c\n}\n"
set id [editor::open_path $p2]
set t $::doc::D($id,w)
paint_now
gutter::fold 1
check "a fold hides the inner lines of its proc" {![shown $t 2] && ![shown $t 3] && ![shown $t 4] && [shown $t 1]}
check "the line after the block shows" {[shown $t 5]}
check "the fold is recorded for its line" {[dict exists [gutter::folds $id] 1]}
paint_now
check "the chip is on screen for a folded block" {
	[llength [lsearch -all -inline -glob [winfo children $::editor::page] *chip*]] == 1
}
gutter::unfold 1
check "unfolding shows the lines again" {[shown $t 2]}
gutter::fold 1
$t mark set insert 2.0
gutter::reveal
check "the caret inside a folded block unfolds it" {[shown $t 2] && [dict size [gutter::folds $id]] == 0}
paint_now
gutter::press 55 [expr {[lindex [$t dlineinfo 1.0] 1] + 3}]
check "a click on the chevron folds the block" {[dict exists [gutter::folds $id] 1]}
gutter::press 55 [expr {[lindex [$t dlineinfo 1.0] 1] + 3}]
check "a second click unfolds it" {[dict size [gutter::folds $id]] == 0}
gutter::fold 2
check "a fold of a line that opens no block does nothing" {[dict size [gutter::folds $id]] == 0}
editor::force_close $id

if {$fails} { puts "editor gutter: $fails checks failed"; exit 1 }
puts "editor gutter: all checks passed"
exit 0
