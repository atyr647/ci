# editor-r4.tcl - the text editor's ⋯ menus and Go to line (boards Editor-R4-1-More, -2-Goto, -3-More-Split,
# -4-More-Welcome; design/tools/gen_editor_r4.py), run by apps/editor/main.tcl through RIBBON_EDITOR_SCENE=this file.
#   RIBBON_R4 = flow (default): the checks below; prints "  ok ..." per check, exits 0 when all pass
#   RIBBON_R4 = more | goto | moresplit | morewelcome: the board's state on top of tests/editor-scene.tcl's (normal, split
#               or welcome), then a screenshot of the window to RIBBON_R4_SHOT
# Flow:
# 1. the ⋯ menu of each strip holds the board's rows (labels, icons, keys, rules), right-aligned under its ⋯ button and
#    6 under the strip; the row under the pointer is raised; each row does its job (Save writes the file, Split view
#    splits, Close closes, Move to other side, Close pane, Open… and New document on the Welcome page).
# 2. Go to line: Ctrl+L as a key event (on the window and in the text) opens the row in the find bar's place, the page
#    under it; only digits are typed; Enter puts the caret at the line's start and closes it; past the end goes to the
#    last line; Esc closes it and leaves the caret; Ctrl+F closes it, and Ctrl+L closes the find bar; in a split it acts
#    on the focused pane's document; the menu's "Go to line…" opens it.
set mode [expr {[info exists ::env(RIBBON_R4)] ? $::env(RIBBON_R4) : "flow"}]
proc bgerror {msg} { puts stderr "editor-r4: $msg\n$::errorInfo"; exit 1 }

if {$mode ne "flow"} {
	set shot $::env(RIBBON_R4_SHOT)
	unset -nocomplain ::env(RIBBON_EDITOR_SHOT) ::env(RIBBON_EDITOR_EXIT)
	set ::env(RIBBON_SCENE) [dict get {more normal goto normal moresplit split morewelcome welcome} $mode]
	uplevel #0 [list source -encoding utf-8 [file join [file dirname [file normalize [info script]]] editor-scene.tcl]]
	proc r4_state {} {
		global mode
		switch -- $mode {
			more { editor::more_menu [expr {$::editor::W - 151 + 10}] 20; set ::menu::hover 4 }
			goto { goto::open; ui::fset goto.q 35; $::doc::D([lindex $::editor::docs 0],w) yview 8.0 }
			moresplit { editor::more_menu [expr {[split::px 0] + [split::pw 0] - 30}] 20; set ::menu::hover 4 }
			morewelcome { editor::more_menu [expr {$::editor::W - 140}] 20; set ::menu::hover 0 }
		}
		editor::paint
	}
	proc r4_shot {} {
		global shot
		editor::paint
		update
		if {[catch {exec import -window [winfo id $::editor::win] $shot} err]} { puts stderr "editor-r4: shot: $err"; exit 1 }
		if {$::menu::open} { puts "editor-r4: menu at $::menu::at size $::menu::MW [lindex [menu::layout] 1]" }
		puts "editor-r4: $shot"
		exit 0
	}
	after 500 r4_state
	after 1300 r4_shot
	return
}

set dir $::env(RIBBON_EDITOR_FIXTURES)
file mkdir $dir
set fails 0
proc ok {what} { puts "  ok   $what"; flush stdout }
proc check {what cond} {
	if {[uplevel 1 [list expr $cond]]} { ok $what } else { global fails; incr fails; puts "  FAIL $what" }
}
proc write_text {path text} {
	set fh [open $path wb]
	fconfigure $fh -translation binary
	puts -nonewline $fh [encoding convertto utf-8 $text]
	close $fh
}
proc read_text {path} { set fh [open $path rb]; set t [encoding convertfrom utf-8 [read $fh]]; close $fh; return $t }
proc press {w keysym} { focus -force $w; event generate $w <$keysym>; update }
proc type {str} { foreach ch [split $str ""] { press $::editor::win Key-$ch } }
# the menu's rows as {label icon keys}, "-" for a rule
proc rows {} {
	set out {}
	foreach it $::menu::items { lappend out [expr {$it eq "-" ? "-" : [list [lindex $it 0] [lindex $it 2] [lindex $it 3]]}] }
	return $out
}
# a click on the row LABEL of the open menu, as the canvas gets it
proc click_row {label} {
	lassign [menu::layout] tops
	set k [lsearch -exact -index 0 $::menu::items $label]
	if {$k < 0} { error "no row $label" }
	editor::paint
	update
	event generate $::menu::canvas <ButtonPress-1> -x 40 -y [expr {[lindex $tops $k] + 17}]
	update
}

set lines {}
for {set i 1} {$i <= 200} {incr i} { lappend lines "line $i" }
set src [join $lines \n]\n
set p [file join $dir long.txt]
write_text $p $src
set q [file join $dir other.txt]
write_text $q "one\ntwo\nthree\n"

puts "the Welcome page's menu"
editor::paint
editor::more_menu [expr {$::editor::W - 140}] 20
check "Welcome: Open… and New document, with icons and keys" {[rows] eq [list [list Open… folder "Ctrl O"] [list "New document" filenew "Ctrl N"]]}
check "it opens 6 under the strip, its right edge on the ⋯ button's (W - 150 + 32)" \
	{$::menu::at eq [list [expr {$::editor::W - 118 - 260}] 52] && $::menu::MW == 260}
proc ::chooser::open_file {args} { return $::chosen }
proc ::chooser::save_file {args} { return $::chosen }
set chosen $q
click_row "Open…"
check "Open… opens the file the chooser gives" {[llength $::editor::docs] == 1 && $::doc::D($::editor::active,path) eq [file normalize $q]}
editor::force_close $::editor::active
editor::paint
editor::more_menu [expr {$::editor::W - 140}] 20
click_row "New document"
check "New document opens an untitled document" {[llength $::editor::docs] == 1 && $::doc::D($::editor::active,untitled)}
editor::force_close $::editor::active
editor::paint

puts "the window's menu"
set id [editor::open_path $p]
editor::activate $id
set t $::doc::D($id,w)
editor::paint
editor::more_menu [expr {$::editor::W - 151 + 10}] 20
check "the board's rows: Open…, Save, Save as… | Go to line…, Split view | Close" \
	{[rows] eq [list [list Open… folder "Ctrl O"] [list Save msave "Ctrl S"] [list "Save as…" saveas "Ctrl Shift S"] - [list "Go to line…" goto "Ctrl L"] [list "Split view" msplit "Ctrl \\"] - [list Close x "Ctrl W"]]}
check "260 wide, right-aligned under the ⋯ button (W - 215 + 96), 6 under the strip" \
	{$::menu::at eq [list [expr {$::editor::W - 119 - 260}] 52]}
lassign [menu::layout] tops h
check "34 px rows, 11 px rules, 6 px padding: 266 tall" {$h == 6 + 6 * 34 + 2 * 11 + 6 && [lindex $tops 4] == 6 + 3 * 34 + 11}
editor::paint; update
event generate $::menu::canvas <Motion> -x 40 -y [expr {[lindex $tops 4] + 10}]
update
check "the row under the pointer is raised (Go to line…)" {$::menu::hover == 4}
event generate $::menu::canvas <Motion> -x 40 -y [expr {[lindex $tops 3] + 5}]
update
check "a rule is no row" {$::menu::hover == -1}
$t insert end "added\n"
click_row Save
check "Save writes the file" {[read_text $p] eq "${src}added\n" && !$::menu::open}
$t delete end-7c end-1c
editor::save_active
set chosen [file join $dir r.txt]
write_text $chosen "r\n"
editor::more_menu [expr {$::editor::W - 151 + 10}] 20
click_row "Open…"
check "Open… opens another file beside it" {[llength $::editor::docs] == 2 && $::doc::D($::editor::active,path) eq [file normalize $chosen]}
editor::force_close $::editor::active
editor::activate $id
set chosen [file join $dir copy.txt]
editor::more_menu [expr {$::editor::W - 151 + 10}] 20
click_row "Save as…"
check "Save as… writes the document where the chooser says" {[file exists $chosen] && [read_text $chosen] eq $src && $::doc::D($id,path) eq [file normalize $chosen]}
editor::more_menu [expr {$::editor::W - 151 + 10}] 20
click_row "Go to line…"
check "Go to line… opens the row with the focus in its field" {$::goto::open && $::ui::focus eq "goto.q"}
press $::editor::win Escape
editor::more_menu [expr {$::editor::W - 151 + 10}] 20
click_row "Split view"
check "Split view splits the window" {[split::is_split]}

puts "a split pane's menu"
editor::paint
set lx [expr {[split::px 0] + [split::pw 0] - 30}]
editor::more_menu $lx 20
check "the board's rows: Save, Save as… | Go to line…, Move to other side | Close pane" \
	{[rows] eq {{Save msave {Ctrl S}} {{Save as…} saveas {Ctrl Shift S}} - {{Go to line…} goto {Ctrl L}} {{Move to other side} swap {}} - {{Close pane} x {}}}}
check "right-aligned under the pane's ⋯ (its right less 8)" \
	{[lindex $::menu::at 0] == [split::px 0] + [split::pw 0] - 8 - 260 && [lindex $::menu::at 1] == 52}
set id2 [editor::open_path $q]
editor::activate $id2
editor::more_menu $lx 20
click_row "Move to other side"
check "Move to other side moves the document to the other pane" {[lsearch -exact [split::val 1 docs] $id2] >= 0 && [lsearch -exact [split::val 0 docs] $id2] < 0}

puts "Go to line in a split: the focused pane's document"
split::focus_to 0
editor::activate $id
set t0 [editor::tw $id 0]
press $t0 Control-l
type 150
press $::editor::win Return
check "pane 0: Ctrl+L, 150, Enter: the caret on line 150 of long.txt" {[$t0 index insert] eq "150.0" && !$::goto::open}
split::focus_to 1
set t1 [editor::tw $id2 1]
$t1 mark set insert 1.0
press $t1 Control-l
type 3
press $::editor::win Return
check "pane 1: the caret on line 3 of other.txt, pane 0's caret kept" {[$t1 index insert] eq "3.0" && [$t0 index insert] eq "150.0"}
editor::more_menu [expr {[split::px 1] + [split::pw 1] - 30}] 20
click_row "Close pane"
check "Close pane leaves one pane" {![split::is_split]}

puts "Go to line"
editor::activate $id
set t [editor::tw $id]
$t mark set insert 10.3
press $t Control-l
check "Ctrl+L in the text opens the row, the field focused and empty" {$::goto::open && $::ui::focus eq "goto.q" && [ui::fval goto.q] eq ""}
editor::paint; update idletasks
check "the page sits under the row (46 + 52)" {[editor::body_top] == 98 && [winfo y $::editor::page] == 98}
type 1a2b0
check "only digits are typed (1a2b0 reads 120)" {[ui::fval goto.q] eq "120"}
press $::editor::win Return
check "Enter: the caret at the start of line 120, the row closed, the text focused" \
	{[$t index insert] eq "120.0" && !$::goto::open && [focus] eq $t && [editor::body_top] == 46}
press $::editor::win Control-l
type 9999
press $::editor::win Return
check "past the end: the last line (the empty one after the file's last newline, as the Well numbers it)" {[$t index insert] eq [$t index "end-1c linestart"] && [$t index insert] eq "201.0"}
$t mark set insert 7.2
press $t Control-l
type 50
press $::editor::win Escape
check "Esc closes it and leaves the caret" {!$::goto::open && [$t index insert] eq "7.2"}
press $t Control-l
press $::editor::win Return
check "Enter on an empty field only closes" {!$::goto::open && [$t index insert] eq "7.2"}
press $t Control-l
press $::editor::win Control-f
check "Ctrl+F closes it and opens find" {!$::goto::open && $::find::open}
press $::editor::win Control-l
check "Ctrl+L closes the find bar" {$::goto::open && !$::find::open && [editor::body_top] == 98}
editor::paint
set ::ui::focus ""
ui::press [expr {$goto::X + 50}] [expr {$goto::R1 + 10}]
check "a click in the field gives it the keyboard" {$::ui::focus eq "goto.q"}
ui::press [expr {$::editor::W - 30}] [expr {$goto::R1 + 10}]
check "the × closes it" {!$::goto::open}
editor::more_menu [expr {$::editor::W - 151 + 10}] 20
click_row Close
check "Close closes the active document" {[lsearch -exact $::editor::docs $id] < 0 && [llength $::editor::docs] == 1}

if {$fails} { puts "editor r4: $fails checks failed"; exit 1 }
puts "editor r4: all checks passed"
exit 0
