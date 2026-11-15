# notes-more.tcl - Notes: the header's ⋯ menu built to boards Notes-R5-2-More and -3-More-Empty
# (design/tools/gen_notes_more.py). Run by apps/notes/main.tcl through RIBBON_NOTES_SCENE=this file, with
# RIBBON_NOTES_FIXTURES.
#   RIBBON_MORE = flow (default): the checks below; "  ok ..." per check and "notes more: all checks passed"
#   RIBBON_MORE = note | empty: tests/notes-scene.tcl's tree (or empty) state with the ⋯ menu open and the board's row
#                 under the pointer (Move to Trash, New folder), then a screenshot of the window to RIBBON_NOTES_SHOT
# Flow:
# 1. a press on the header's ⋯ (a note open) opens the menu right-aligned under it, 220 x 159 at (W - 238, 60), rows
#    New note, New folder, Import…, Move to Trash; a press outside it, Escape, or the ⋯ again closes it.
# 2. each row does its job: New note makes and opens a note in the folder; New folder makes a folder under the open
#    one; Import… asks Ribbon's chooser (stood in for) and imports the file; Move to Trash moves the file under
#    .trash, opens the note that followed it, Trash lists it and Restore puts it back; the last note of a folder
#    trashed leaves the empty folder.
# 3. the empty folder's ⋯ menu: New note, New folder, Import… (220 x 114), and New note there makes the first note.
fconfigure stdout -encoding utf-8
set mode [expr {[info exists ::env(RIBBON_MORE)] ? $::env(RIBBON_MORE) : "flow"}]
set here [file dirname [file normalize [info script]]]

if {$mode in {note empty}} {
	set ::env(RIBBON_SCENE) [expr {$mode eq "note" ? "tree" : "empty"}]
	set shot $::env(RIBBON_NOTES_SHOT)
	unset ::env(RIBBON_NOTES_SHOT)
	uplevel #0 [list source -encoding utf-8 [file join $here notes-scene.tcl]]
	after 400 [list apply {{mode} {
		# the pointer off the window (xvfb starts it mid-screen): only the board's row is raised
		event generate $::notesapp::win <Motion> -warp 1 -x 5 -y 5
		update
		notesapp::more_menu
		update
		set m [notesapp::more_menu_path]
		event generate $m.[expr {$mode eq "note" ? "trash" : "folder"}] <Enter>
		update
	}} $mode]
	after 1200 [list notesapp::shot_and_exit $shot]
	return
}

set dir $::env(RIBBON_NOTES_FIXTURES)
file delete -force $dir
file mkdir [file join $dir Ribbon]
set bgerrors {}
proc bgerror {msg} { lappend ::bgerrors $msg; puts stderr "notes-more: bgerror: $msg\n$::errorInfo" }
set fails 0
proc check {name ok} {
	global fails
	if {$ok} { puts "  ok   $name" } else { puts "  FAIL $name"; incr fails }
}
proc put {path text} {
	file mkdir [file dirname $path]
	set fh [open $path wb]
	puts -nonewline $fh [encoding convertto utf-8 $text]
	close $fh
}
proc click {x y} {
	event generate $::notesapp::cv <ButtonPress-1> -x $x -y $y
	event generate $::notesapp::cv <ButtonRelease-1> -x $x -y $y
	update
}
proc menu_open {} { winfo exists [notesapp::more_menu_path] }
# the ⋯ button: 32 px, its right edge 18 from the window's, in the 80 px header
proc press_more {} { click [expr {$::notesapp::W - 34}] 40 }
proc row {kind} {
	set w [notesapp::more_menu_path].$kind
	event generate $w <ButtonPress-1> -x 20 -y 17
	update
}
proc names {folder} { lmap e [notes::index::in_folder $folder] {dict get $e name} }

put [file join $dir Ribbon "First.md"] "# First\n\nOne\n"
put [file join $dir Ribbon "Second.md"] "# Second\n\nTwo\n"
put [file join $dir Ribbon "Third.md"] "# Third\n\nThree\n"
# the index orders newest first: Third, Second, First
set t [clock seconds]
foreach {n d} {First 300 Second 200 Third 100} { file mtime [file join $dir Ribbon "$n.md"] [expr {$t - $d}] }
notes::store::set_root $dir
notes::index::refresh
set ::notesapp::open {Ribbon}
notesapp::open_note Ribbon Second
notesapp::paint
update
set W $::notesapp::W

puts "the ⋯ menu of a note"
press_more
set m [notesapp::more_menu_path]
check "a press on the header's ⋯ opens the menu" [menu_open]
update idletasks
check "the menu is right-aligned under the ⋯, 4 below it: 220 x 159 at (W - 238, 60)" \
	[expr {[winfo x $m] == $W - 238 && [winfo y $m] == 60 && [winfo width $m] == 220 && [winfo height $m] == 159}]
set kids [lmap w [winfo children $m] {winfo name $w}]
check "the rows are New note, New folder, Import… and Move to Trash, in the board's places" \
	[expr {$kids eq {new folder import trash} && [winfo y $m.new] == 6 && [winfo y $m.folder] == 40 && [winfo y $m.import] == 74 \
		&& [winfo y $m.trash] == 119 && [winfo x $m.new] == 6 && [winfo width $m.new] == 208}]
check "the menu takes the pointer while it is open" [expr {[grab current] eq $m}]
event generate $m <ButtonPress-1> -x -300 -y 200
update
check "a press outside the menu closes it" [expr {![menu_open] && [grab current] eq ""}]
press_more
event generate $m <Escape>
update
check "Escape closes it" [expr {![menu_open]}]
press_more
event generate $m <ButtonPress-1> -x [expr {$W - 34 - ($W - 238)}] -y -20
update
check "the ⋯ again closes it" [expr {![menu_open]}]

puts "its rows"
press_more
row new
set n [names Ribbon]
check "New note makes a note in the open folder and opens it; the menu goes" \
	[expr {![menu_open] && [llength $n] == 4 && $::notesapp::state(folder) eq "Ribbon" \
		&& $::notesapp::state(note) ni {First Second Third} && $::notesapp::state(note) in $n}]
notesapp::open_note Ribbon Second
press_more
row folder
check "New folder makes a folder under the open one" \
	[expr {![menu_open] && [llength [glob -nocomplain -type d -directory [file join $dir Ribbon] *]] == 1}]
set newf $::notesapp::state(folder)
file delete -force [file join $dir {*}[split $newf /]]
namespace eval chooser {}
proc ::chooser::open_file {args} { set ::chooser_args $args; return $::chooser_files }
put [file join $dir .. src "Brought in.md"] "# Brought in\n\nFrom elsewhere\n"
set chooser_files [list [file normalize [file join $dir .. src "Brought in.md"]]]
notesapp::open_note Ribbon Second
press_more
row import
check "Import… asks Ribbon's chooser for Markdown files and imports them into the open folder" \
	[expr {![menu_open] && [info exists chooser_args] && [dict get $chooser_args -multiple] == 1 \
		&& [file exists [file join $dir Ribbon "Brought in.md"]]}]
file delete [file join $dir Ribbon "Brought in.md"]
foreach f [glob -nocomplain -directory [file join $dir Ribbon] *.md] {
	if {[file rootname [file tail $f]] ni {First Second Third}} { file delete $f }
}
notes::index::refresh
foreach {n d} {First 300 Second 200 Third 100} { file mtime [file join $dir Ribbon "$n.md"] [expr {$t - $d}] }
notes::index::refresh
notesapp::open_note Ribbon Second
$::notesapp::page insert end "Edited before the trash\n"
update
press_more
row trash
set trashed ""
catch {set fh [open [file join $dir .trash Ribbon Second.md]]; set trashed [read $fh]; close $fh}
check "a note edited and then trashed keeps its edit" [string match "*Edited before the trash*" $trashed]
check "Move to Trash moves the note's file under .trash" \
	[expr {![menu_open] && ![file exists [file join $dir Ribbon Second.md]] && [file exists [file join $dir .trash Ribbon Second.md]]}]
# the edit made Second the newest (Second, Third, First): Third followed it
check "the note that followed it opens" [expr {$::notesapp::state(note) eq "Third" && $::notesapp::state(folder) eq "Ribbon"}]
check "Trash lists it" [expr {[list Ribbon Second] in [notes::store::trashed]}]
notesapp::restore_note Ribbon Second
check "Restore puts it back" [expr {[file exists [file join $dir Ribbon Second.md]] && "Second" in [names Ribbon]}]
put [file join $dir Lone "Only.md"] "# Only\n\nAlone\n"
notes::index::refresh
notesapp::open_note Lone Only
press_more
row trash
check "the last note of a folder trashed leaves the empty folder" \
	[expr {$::notesapp::state(note) eq "" && $::notesapp::state(folder) eq "Lone" && [names Lone] eq ""}]

puts "the empty folder's ⋯ menu"
press_more
update idletasks
set kids [lmap w [winfo children $m] {winfo name $w}]
check "it has New note, New folder and Import…, 220 x 114 at (W - 238, 60)" \
	[expr {[menu_open] && $kids eq {new folder import} && [winfo width $m] == 220 && [winfo height $m] == 114 \
		&& [winfo x $m] == $W - 238 && [winfo y $m] == 60}]
row new
check "New note there makes the folder's first note and opens it" \
	[expr {![menu_open] && [llength [names Lone]] == 1 && $::notesapp::state(note) eq [lindex [names Lone] 0]}]

check "no background errors" [expr {[llength $bgerrors] == 0}]
if {$fails} { puts "notes more: $fails checks failed"; exit 1 }
puts "notes more: all checks passed"
exit 0
