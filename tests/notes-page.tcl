# notes-page.tcl - a Tk test of the note page's W1 fixes, run as a scene by apps/notes/main.tcl:
#   RIBBON_NOTES_SCENE=this file, RIBBON_NOTES_FIXTURES = a folder made here.
# Checks: the Text style menu opens (no Tcl error) and sets a heading; a click on an http(s) link runs xdg-open with
# its target (a stub on PATH) and the link is drawn in the board's style; a fenced tcl block takes the code colours;
# a done checklist item draws its inline code as struck text, not a chip; a changed title renames the note's file
# (with its versions); the window resizes and the page follows. Prints "page: ok" and exits 0, or exits 1.
set dir $::env(RIBBON_NOTES_FIXTURES)
file delete -force $dir
file mkdir [file join $dir Ribbon]
set bgerrors {}
proc bgerror {msg} { lappend ::bgerrors $msg; puts stderr "notes-page: bgerror: $msg" }
set fails 0
proc check {name ok} {
	global fails
	if {$ok} { puts "  ok   $name" } else { puts "  FAIL $name"; incr fails }
}
# waits (at most MS) until SCRIPT is true, letting events run
proc wait_for {script {ms 5000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 $script]} {
		if {[clock milliseconds] > $end} { return 0 }
		after 20
		update
	}
	return 1
}
set body0 "# Page\n\nRead \[the docs\](https://example.org/docs) first, and \[this\](file:///etc/passwd) not.\n\n- \[x\] Folders and `#tags`\n- \[ \] Open with `code`\n\n```tcl\nproc save {name} {\n    set path \$name\n}\n```\n"
set fh [open [file join $dir Ribbon page.md] w]
fconfigure $fh -encoding utf-8 -translation lf
puts -nonewline $fh $body0
close $fh
notes::store::set_root $dir
notes::index::refresh
set ::notesapp::open {Ribbon}
notesapp::open_note Ribbon page
notesapp::paint
update
set page $notesapp::page

# ---- the Text style menu (124): it opens without a Tcl error and Heading 2 sets "## "
$page tag remove sel 1.0 end
set at [$page search -- "Read" 1.0]
$page tag add sel $at "$at + 4 chars"
notesapp::format_update
update
event generate $notesapp::page_bar.text.l <Button-1>
update
set m [notesapp::style_menu_path]
check "the Text style menu opens with no Tcl error" [expr {[llength $bgerrors] == 0 && [winfo exists $m] && [winfo ismapped $m]}]
check "the menu sits under the format bar" [expr {[winfo exists $m] && [winfo rooty $m] >= [winfo rooty $notesapp::page_bar] + 40 - 2}]
if {[winfo exists $m.h2]} { event generate $m.h2 <Button-1>; update }
check "Heading 2 makes the line a level-2 heading" [string match "*\n## Read \\\[the docs\\\]*" [notesapp::body_text]]
check "the menu closes on a choice" [expr {![winfo exists $m]}]
notesapp::undo
update
check "undo takes the heading back" [expr {[notesapp::body_text] eq $body0}]
$page tag remove sel 1.0 end
notesapp::format_update

# ---- links (130): the board's style, and a click opens an http(s) target with xdg-open
check "a link is the text colour, underlined in the muted colour" \
	[expr {[$page tag cget link -foreground] eq $notesapp::c(fg) && [$page tag cget link -underline] == 1 && [$page tag cget link -underlinefg] eq $notesapp::c(muted)}]
set stub [file join $dir bin]
file mkdir $stub
set log [file join $dir xdg-open.log]
set fh [open [file join $stub xdg-open] w]
puts $fh "#!/bin/sh\nprintf '%s\\n' \"\$*\" >> '$log'"
close $fh
file attributes [file join $stub xdg-open] -permissions 0755
set ::env(PATH) "$stub:$::env(PATH)"
proc click_on {idx} {
	set p $::notesapp::page
	$p see $idx
	update
	lassign [$p bbox $idx] x y w h
	event generate $p <ButtonPress-1> -x [expr {$x + 2}] -y [expr {$y + $h / 2}]
	event generate $p <ButtonRelease-1> -x [expr {$x + 2}] -y [expr {$y + $h / 2}]
	update
}
set at [$page search -- "the docs" 1.0]
check "the link text is tagged link" [expr {"link" in [$page tag names $at]}]
click_on "$at + 2 chars"
proc logged {} {
	if {![file exists $::log]} { return "" }
	set f [open $::log]
	set t [string trim [read $f]]
	close $f
	return $t
}
check "a click on the link runs xdg-open with its target" [wait_for {expr {[logged] eq "https://example.org/docs"}}]
check "the click changed nothing in the note" [expr {[notesapp::body_text] eq $body0}]
set at [$page search -- "this" 1.0]
click_on "$at + 1 chars"
after 300
update
set lines [split [logged] \n]
check "a file: link is not opened" [expr {[llength $lines] == 1}]
# a drag that selects over the link opens nothing
set at [$page search -- "the docs" 1.0]
$page tag add sel $at "$at + 3 chars"
notesapp::link_click [$page index "$at + 1 chars"]
set lines [split [logged] \n]
check "a selection over the link does not open it" [expr {[llength $lines] == 1}]
$page tag remove sel 1.0 end

# the header's Link button with nothing selected puts an empty link at the insert point
$page mark set insert "[$page search -- "first" 1.0]"
notesapp::format_link
check "Link with no selection inserts an empty link" [string match {*\[\](https://)first*} [notesapp::body_text]]
notesapp::undo
check "undo takes the link back" [expr {[notesapp::body_text] eq $body0}]

# ---- code colours (130): the fenced tcl block's keyword and variable
set at [$page search -- "proc save" 1.0]
check "the code block's keyword takes the keyword colour" [expr {"syn_kw" in [$page tag names $at] && [$page tag cget syn_kw -foreground] eq $::theme::c(SYN_KW)}]
set at [$page search -- "\$name" [$page search -- "set path" 1.0]]
check "a variable takes the variable colour" [expr {"syn_var" in [$page tag names $at]}]

# ---- a done item's inline code is struck text (257); an open item's is the code chip
set at [$page search -- "#tags" 1.0]
check "#tags in the done item is not a code chip" [expr {"code" ni [$page tag names $at] && "done" in [$page tag names $at]}]
check "its backticks stay hidden" [expr {"elide" in [$page tag names "$at - 1 chars"]}]
set at [$page search -- "code" [$page search -- "Open with" 1.0]]
check "inline code in an open item is still a chip" [expr {"code" in [$page tag names $at]}]

# ---- the title renames the file (126)
notesapp::new_note
update
check "a new note is Untitled" [expr {$notesapp::state(note) eq "Untitled"}]
$page insert 1.0 "# Groceries"
update
notesapp::save
set rd [notes::store::dir_of Ribbon]
check "saving with a title renames the file" [expr {[file exists [file join $rd Groceries.md]] && ![file exists [file join $rd Untitled.md]]}]
check "the open note is the renamed one" [expr {$notesapp::state(note) eq "Groceries"}]
check "the versions followed the rename" [expr {[llength [glob -nocomplain -directory [file join $rd .versions] Groceries.*.md]] >= 1 && [llength [glob -nocomplain -directory [file join $rd .versions] Untitled.*.md]] == 0}]
set names {}
foreach e [notes::index::in_folder Ribbon] { lappend names [dict get $e name] }
check "the tree lists Groceries" [expr {"Groceries" in $names && "Untitled" ni $names}]
# a second note with the same title gets a number
notesapp::new_note
$page insert 1.0 "# Groceries"
update
notesapp::save
check "the same title in the folder gets a number" [expr {$notesapp::state(note) eq "Groceries 2" && [file exists [file join $rd "Groceries 2.md"]]}]
# a slash in the title is no folder
$page delete 1.0 "1.0 lineend"
$page insert 1.0 "# Bread / flour"
update
notesapp::save
check "a slash in the title becomes a dash" [expr {$notesapp::state(note) eq "Bread - flour" && [file exists [file join $rd "Bread - flour.md"]]}]
# a note whose file name is not its title is not renamed when only its text changes
notesapp::open_note Ribbon page
$page insert end "More."
update
notesapp::save
check "an edit that keeps the title keeps the name" [expr {$notesapp::state(note) eq "page" && [file exists [file join $rd page.md]]}]
# a retitle onto a taken name does not move a note off a name it already has: "Milk 2" retitled "Milk" (Milk.md is
# another note) stays "Milk 2"
foreach {n t} {Milk "# Milk\n" "Milk 2" "# Milk list\n"} {
	set fh [open [file join $rd "$n.md"] w]
	puts -nonewline $fh $t
	close $fh
}
notes::index::refresh
notesapp::open_note Ribbon "Milk 2"
$page delete 1.0 "1.0 lineend"
$page insert 1.0 "# Milk"
update
notesapp::save
check "a retitle to a taken name keeps a number it already has" [expr {$notesapp::state(note) eq "Milk 2" && [file exists [file join $rd "Milk 2.md"]] && ![file exists [file join $rd "Milk 3.md"]]}]
# a click on the open note's own row (drawn with its old name) after a retitle that was not saved yet: the save
# renames it, and the click opens it under its new name
notesapp::new_note
update
$page insert 1.0 "# Shopping"
update
set r [catch {notesapp::open_note Ribbon Untitled} err]
update
check "opening the retitled note by its old name opens it under the new one" [expr {!$r && $notesapp::state(note) eq "Shopping" && [string match "# Shopping*" [notesapp::body_text]]}]
if {$r} { puts stderr "notes-page: $err" }

# ---- the window resizes (139): the page stays on its measure in the middle, the actions keep to the right edge
wm geometry $notesapp::win 1600x1000
update
check "the window takes the new size" [wait_for {expr {$::notesapp::W == 1600 && $::notesapp::H == 1000}}]
update
check "the canvas follows" [expr {[winfo width $notesapp::cv] == 1600 && [winfo height $notesapp::cv] == 1000}]
check "the page is centred right of the tree" [expr {[winfo x $page] == 300 + (1600 - 300 - 620) / 2 && [winfo width $page] == 620 && [winfo height $page] == 1000 - 104}]
set pin 0
foreach h $::ui::hits { if {[lindex $h 4] eq "notesapp::toggle_pin" && [lindex $h 0] == 1600 - 84} { set pin 1 } }
check "the pin keeps its place from the right edge" $pin
set foot 0
foreach h $::ui::hits { if {[lindex $h 4] eq "notesapp::show_trash" && [lindex $h 1] == 1000 - 46} { set foot 1 } }
check "the tree's foot follows the bottom" $foot
check "no Tcl error was raised" [expr {[llength $bgerrors] == 0}]

if {$fails} { puts "page: $fails check(s) failed"; exit 1 }
puts "page: ok"
exit 0
