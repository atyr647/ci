# notes-r5.tcl - Notes: the Text style menu built to board Notes-R5-1-Style (design/tools/gen_editor_r4.py), Import, and
# the tree's tag chips. Run by apps/notes/main.tcl through RIBBON_NOTES_SCENE=this file, with RIBBON_NOTES_FIXTURES.
#   RIBBON_R5 = flow (default): the checks below; prints "  ok ..." per check and "notes r5: all checks passed"
#   RIBBON_R5 = style: tests/notes-scene.tcl's edit state with the style menu open (Heading 2 under the pointer), then
#               a screenshot of the window to RIBBON_NOTES_SHOT
# Flow:
# 1. the style menu: opened by a click on the format bar's Text button, 4 under the bar with its left edge on the bar's,
#    200 x 182, the five rows in the board's order with the line's style checked; the row under the pointer is raised;
#    a click on Heading 2 makes the line "## ...", the menu closes and the button reads "Heading 2"; a click on Quote
#    and Text; a second click on Text closes it; it goes with the selection.
# 2. Import (the empty folder's button, Ribbon's chooser stood in for): a note with front matter takes its title as its
#    name and keeps the front matter (pinned holds); its relatively-linked pictures (a subfolder, %20, <angle brackets>
#    with a title) are copied next to it and the links rewritten, a URL, an absolute path, a missing file and a link in
#    code are left; a different picture with a taken name gets a number, the same one is not copied twice; a taken note
#    name gets " 2" (nothing is replaced); CRLF becomes LF; the picture renders on the note's page.
# 3. the tree's TAGS chips: a click filters the tree to the notes with that tag; a second click clears it.
set mode [expr {[info exists ::env(RIBBON_R5)] ? $::env(RIBBON_R5) : "flow"}]
set here [file dirname [file normalize [info script]]]

if {$mode eq "style"} {
	set ::env(RIBBON_SCENE) edit
	set shot $::env(RIBBON_NOTES_SHOT)
	unset ::env(RIBBON_NOTES_SHOT)
	uplevel #0 [list source -encoding utf-8 [file join $here notes-scene.tcl]]
	after 400 {
		# the pointer away from the menu (xvfb starts it mid-screen, over the menu): only the board's row is raised
		event generate $::notesapp::win <Motion> -warp 1 -x 5 -y 5
		update
		notesapp::style_menu
		update
		set m [notesapp::style_menu_path]
		event generate $m.h2 <Enter>
		update
	}
	after 1200 [list notesapp::shot_and_exit $shot]
	return
}

set dir $::env(RIBBON_NOTES_FIXTURES)
file delete -force $dir
file mkdir [file join $dir Ribbon]
set bgerrors {}
proc bgerror {msg} { lappend ::bgerrors $msg; puts stderr "notes-r5: bgerror: $msg\n$::errorInfo" }
set fails 0
proc check {name ok} {
	global fails
	if {$ok} { puts "  ok   $name" } else { puts "  FAIL $name"; incr fails }
}
proc put {path text {binary 0}} {
	file mkdir [file dirname $path]
	set fh [open $path wb]
	if {!$binary} { set text [encoding convertto utf-8 $text] }
	puts -nonewline $fh $text
	close $fh
}
# a click on the window's canvas, as the pointer makes it
proc click {x y} {
	event generate $::notesapp::cv <ButtonPress-1> -x $x -y $y
	event generate $::notesapp::cv <ButtonRelease-1> -x $x -y $y
	update
}
proc get {path} { set fh [open $path rb]; set t [encoding convertfrom utf-8 [read $fh]]; close $fh; return $t }

put [file join $dir Ribbon style.md] "# Style\n\nFirst line here\n\nSecond line #design\n"
put [file join $dir Ribbon other.md] "# Other\n\nNo tags here\n"
notes::store::set_root $dir
notes::index::refresh
set ::notesapp::open {Ribbon}
notesapp::open_note Ribbon style
notesapp::paint
update
set page $notesapp::page

puts "the Text style menu"
proc select_word {word} {
	set p $::notesapp::page
	$p tag remove sel 1.0 end
	set at [$p search -- $word 1.0]
	$p tag add sel $at "$at + [string length $word] chars"
	notesapp::format_update
	update
}
select_word "First"
event generate $notesapp::page_bar.text.l <Button-1>
update
set m [notesapp::style_menu_path]
check "a click on Text opens the menu" [expr {[winfo exists $m] && [winfo ismapped $m]}]
check "its left edge on the bar's, 4 under the bar (40 high)" \
	[expr {[winfo rootx $m] == [winfo rootx $notesapp::page_bar] && [winfo rooty $m] == [winfo rooty $notesapp::page_bar] + 44}]
check "200 x 182: five 34 px rows and 6 px padding" [expr {[winfo reqwidth $m] == 200 && [winfo reqheight $m] == 182}]
set order {}
foreach k {text h1 h2 h3 quote} { lappend order [winfo y $m.$k] }
check "the rows in the board's order, 34 apart from 6" [expr {$order eq {6 40 74 108 142}}]
proc has_check {w} {
	foreach i [$w find withtag all] { if {[$w type $i] eq "image" && [lindex [$w coords $i] 0] == [winfo reqwidth $w] - 24} { return 1 } }
	return 0
}
check "the line's style (Text) is checked, no other" [expr {[has_check $m.text] && ![has_check $m.h1] && ![has_check $m.h2]}]
proc row_bg {w} {
	set img [$w itemcget [lindex [$w find withtag all] 0] -image]
	format #%02X%02X%02X {*}[$img get 20 17]
}
event generate $m.h2 <Enter>
update
check "the row under the pointer is raised in the pill colour" [expr {[row_bg $m.h2] eq [string toupper $notesapp::c(pill)] && [row_bg $m.h1] eq [string toupper $notesapp::c(field)]}]
event generate $m.h2 <Button-1>
update
check "Heading 2 makes the line \"## First line here\"" [string match "*\n## First line here\n*" [notesapp::body_text]]
check "the menu closes on a choice" [expr {![winfo exists $m]}]
select_word "Second"
check "the button reads the selected line's style (Text)" [expr {[$notesapp::page_bar.text.l cget -text] eq "Text"}]
select_word "First"
check "and Heading 2 on the heading" [expr {[$notesapp::page_bar.text.l cget -text] eq "Heading 2"}]
event generate $notesapp::page_bar.text.l <Button-1>
update
check "the reopened menu checks Heading 2" [expr {[has_check $m.h2] && ![has_check $m.text]}]
event generate $m.quote <Button-1>
update
check "Quote makes it \"> First line here\"" [string match "*\n> First line here\n*" [notesapp::body_text]]
select_word "First"
event generate $notesapp::page_bar.text.l <Button-1>
update
event generate $m.text <Button-1>
update
check "Text takes the marker away" [string match "*\nFirst line here\n*" [notesapp::body_text]]
select_word "First"
event generate $notesapp::page_bar.text.l <Button-1>
update
event generate $notesapp::page_bar.text.l <Button-1>
update
check "a second click on Text closes it" [expr {![winfo exists $m]}]
event generate $notesapp::page_bar.text.l <Button-1>
update
$page tag remove sel 1.0 end
notesapp::format_update
update
check "it goes with the selection" [expr {![winfo exists $m]}]
# a line at the foot of the page: the menu stays inside the window, every row can be reached
set keep [$page get 1.0 end-1c]
for {set i 0} {$i < 80} {incr i} { $page insert end "\nfiller $i" }
$page insert end "\nLast words"
$page see end
update
select_word "Last"
event generate $notesapp::page_bar.text.l <Button-1>
update
set top [winfo toplevel $page]
check "at the page's foot the menu is inside the window (its Quote row too)" \
	[expr {[winfo exists $m] && [winfo rooty $m] + [winfo reqheight $m] <= [winfo rooty $top] + [winfo height $top]}]
catch {destroy $m}
$page delete 1.0 end
$page insert 1.0 $keep
$page tag remove sel 1.0 end
notesapp::format_update
update

puts "Import"
set src [file join $dir src]
file mkdir [file join $src img]
exec tclsh8.6 [file join $here make-picture.tcl] photo-blue-1 120 80 [file join $src img pic.png]
exec tclsh8.6 [file join $here make-picture.tcl] photo-dusk-0 120 80 [file join $src "a b.png"]
exec tclsh8.6 [file join $here make-picture.tcl] photo-ember-1 100 60 [file join $src other.png]
put [file join $src trip.md] [string map {\n \r\n} "---\ntitle: \"Trip: Lisbon/Porto\"\npinned: true\nauthor: me\n---\n# Trip\n\n!\[map\](img/pic.png)\n\nSee !\[x\](a%20b.png) and !\[y\](<a b.png> \"the title\") inline.\n\n!\[web\](https://example.org/p.png)\n!\[abs\](/nonexistent/p.png)\n!\[gone\](missing.png)\n`!\[code\](img/pic.png)`\n\n```\n!\[fenced\](img/pic.png)\n```\n"]
put [file join $src Plain.txt] "Just text\n"
put [file join $src second.md] "# Second\n\n!\[same\](img/pic.png)\n!\[other\](sub/pic.png)\n"
file mkdir [file join $src sub]
file copy [file join $src other.png] [file join $src sub pic.png]
# the folder is empty: its page has the Import button
file mkdir [file join $dir Garden]
notes::index::refresh
notesapp::open_folder Garden
notesapp::paint
update
namespace eval chooser {}
proc ::chooser::open_file {args} { set ::chooser_args $args; return $::chooser_files }
set chooser_files [list [file join $src trip.md] [file join $src Plain.txt] [file join $src second.md]]
set hit ""
foreach h $::ui::hits { if {[lindex $h 4] eq "notesapp::import_notes"} { set hit $h } }
check "the empty folder's page has the Import button" [expr {$hit ne ""}]
if {$hit ne ""} {
	lassign $hit x0 y0 x1 y1
	click [expr {($x0 + $x1) / 2}] [expr {($y0 + $y1) / 2}]
	update
}
check "Import asks Ribbon's chooser for Markdown files, several at once" \
	[expr {[info exists chooser_args] && [dict get $chooser_args -multiple] == 1 && [string match "*.md*" [dict get $chooser_args -filetypes]]}]
set g [file join $dir Garden]
check "the front matter's title names the note (a slash becomes a dash)" [file exists [file join $g "Trip: Lisbon-Porto.md"]]
set trip [get [file join $g "Trip: Lisbon-Porto.md"]]
check "the front matter is kept, line ends LF" [expr {[string match "---\ntitle: \"Trip: Lisbon/Porto\"\npinned: true\nauthor: me\n---\n# Trip\n*" $trip] && [string first \r $trip] < 0}]
check "pinned: true holds" [dict get [notes::md::parse $trip] pinned]
check "a picture in a subfolder is copied next to the note and the link rewritten" \
	[expr {[file exists [file join $g pic.png]] && [string first "!\[map\](pic.png)" $trip] >= 0}]
check "%20 and <angle brackets> with a title: copied once, linked by its name" \
	[expr {[file exists [file join $g "a b.png"]] && [string first "!\[x\](<a b.png>)" $trip] >= 0 && [string first "!\[y\](<a b.png> \"the title\")" $trip] >= 0}]
check "a URL, an absolute path and a missing file are left as they are" \
	[expr {[string first "!\[web\](https://example.org/p.png)" $trip] >= 0 && [string first "!\[abs\](/nonexistent/p.png)" $trip] >= 0 && [string first "!\[gone\](missing.png)" $trip] >= 0}]
check "links in code are left as written" \
	[expr {[string first "`!\[code\](img/pic.png)`" $trip] >= 0 && [string first "!\[fenced\](img/pic.png)" $trip] >= 0}]
check "a file without front matter is named by its file (Plain.txt is Plain)" [expr {[get [file join $g Plain.md]] eq "Just text\n"}]
set second [get [file join $g second.md]]
check "the same picture again is not copied twice; a different one with a taken name is \"pic 2.png\"" \
	[expr {[string first "!\[same\](pic.png)" $second] >= 0 && [string first "!\[other\](<pic 2.png>)" $second] >= 0 && [file exists [file join $g "pic 2.png"]] \
		&& [llength [glob -directory $g *.png]] == 3}]
set chooser_files [list [file join $src second.md]]
notesapp::import_notes
check "a taken name gets \" 2\"; the note there is kept" [expr {[file exists [file join $g "second 2.md"]] && [get [file join $g second.md]] eq $second}]
check "the imported notes are in the index" [expr {[llength [notes::index::in_folder Garden]] == 4}]
# a file from elsewhere is untrusted: only pictures are copied (not a key a link points at, nor a .png that is a link
# to one), and its title is made a name as a retitled note's is (no hidden file, no control character, at most 120)
set sec [file join $dir secret]
file mkdir $sec
put [file join $sec id_rsa] "PRIVATE KEY\n"
file link -symbolic [file join $src key.png] [file join $sec id_rsa]
put [file join $src evil.md] "---\ntitle: .env\n---\n!\[k\](../secret/id_rsa)\n!\[l\](key.png)\n!\[ok\](img/pic.png)\n"
put [file join $src tab.md] "---\ntitle: \"a\tb\"\n---\nx\n"
put [file join $src long.md] "---\ntitle: [string repeat x 300]\n---\nx\n"
file mkdir [file join $dir Loot]
set got [notesapp::import_files [list [file join $src evil.md] [file join $src long.md] [file join $src tab.md]] Loot]
set loot [file join $dir Loot]
check "only pictures are copied: not a file a link names, nor a .png that links to one" \
	[expr {![file exists [file join $loot id_rsa]] && ![file exists [file join $loot key.png]] && [file exists [file join $loot pic.png]]}]
check "a title is made a name as a retitled note's: no leading dot, no tab, at most 120 characters" \
	[expr {$got eq [list env [string repeat x 120] a-b] && [file exists [file join $loot env.md]] && [file exists [file join $loot a-b.md]]}]
notesapp::open_note Garden "Trip: Lisbon-Porto"
notesapp::paint
update
set pics 0
foreach i [$notesapp::page image names] { incr pics }
check "the copied picture renders on the note's page" [expr {$pics >= 1 && [info exists notesapp::images([file join $g pic.png])]}]

puts "the tree's tag chips"
notes::index::refresh
set ::notesapp::state(tag) ""
notesapp::open_note Ribbon style
notesapp::paint
update
set hit ""
foreach h $::ui::hits { if {[lindex $h 4] eq "notesapp::set_tag design"} { set hit $h } }
check "the TAGS footer has the #design chip" [expr {$hit ne ""}]
proc names {folder} { set o {}; foreach e [notesapp::visible_notes $folder] { lappend o [dict get $e name] }; return $o }
if {$hit ne ""} {
	lassign $hit x0 y0 x1 y1
	click [expr {($x0 + $x1) / 2}] [expr {($y0 + $y1) / 2}]
	update
}
check "a click filters the tree to the notes tagged #design" [expr {$notesapp::state(tag) eq "design" && [names Ribbon] eq {style}}]
foreach h $::ui::hits { if {[lindex $h 4] eq "notesapp::set_tag design"} { set hit $h } }
lassign $hit x0 y0 x1 y1
click [expr {($x0 + $x1) / 2}] [expr {($y0 + $y1) / 2}]
update
check "a second click clears it" [expr {$notesapp::state(tag) eq "" && [lsort [names Ribbon]] eq {other style}}]

notes::index::refresh
notesapp::paint
update
set hit ""
foreach h $::ui::hits { if {[lindex $h 4] eq "notesapp::new_note"} { set hit $h } }
lassign $hit x0 y0 x1 y1
set before [llength [notes::store::notes Ribbon]]
click [expr {($x0 + $x1) / 2}] [expr {($y0 + $y1) / 2}]
check "the bar's New note button makes a note (a press runs a hit whose proc takes no x y)" [expr {[llength [notes::store::notes Ribbon]] == $before + 1}]
check "no Tcl error was raised" [expr {[llength $bgerrors] == 0}]
if {$fails} { puts "notes r5: $fails checks failed"; exit 1 }
puts "notes r5: all checks passed"
exit 0
