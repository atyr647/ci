# notes-more.tcl - Notes: the header's ⋯ menu built to boards Notes-R5-2-More and -3-More-Empty
# (design/tools/gen_notes_more.py). Run by apps/notes/main.tcl through RIBBON_NOTES_SCENE=this file, with
# RIBBON_NOTES_FIXTURES.
#   RIBBON_MORE = flow (default): the checks below; "  ok ..." per check and "notes more: all checks passed"
#   RIBBON_MORE = note | empty: tests/notes-scene.tcl's tree (or empty) state with the ⋯ menu open and the board's row
#                 under the pointer (Move to Trash, New folder), then a screenshot of the window to RIBBON_NOTES_SHOT
# Flow:
# 1. a press on the header's ⋯ (a note open) opens the menu right-aligned under it, 220 x 193 at (W - 238, 60), rows
#    New note, New folder, Import…, Move to…, Move to Trash; a press outside it, Escape, or the ⋯ again closes it.
# 2. each row does its job: New note makes and opens a note in the folder; New folder makes a folder under the open
#    one; Import… asks Ribbon's chooser (stood in for) and imports the file; Move to Trash moves the file under
#    .trash, opens the note that followed it, Trash lists it and Restore puts it back; the last note of a folder
#    trashed leaves the empty folder.
# 3. the empty folder's ⋯ menu: New note, New folder, Import… (220 x 114), and New note there makes the first note.
# 4. Move to… (board Notes-W4-2-Move): the folders in the menu's place in the tree's order, sub-folders 20 in, the
#    note's own checked; a press on one moves the note's file and its earlier texts there and keeps it open; a name
#    taken there is numbered; the wheel scrolls a list longer than the window.
# 5. the empty folder's sort button (Notes-W4-3-Sort): Last edited (checked) and Name, 200 x 80 right-aligned under
#    it; Name orders the tree's notes by name (pinned first), is kept in the state directory, and comes back.
fconfigure stdout -encoding utf-8
set mode [expr {[info exists ::env(RIBBON_MORE)] ? $::env(RIBBON_MORE) : "flow"}]
set here [file dirname [file normalize [info script]]]

if {$mode in {note empty move-menu move sort}} {
	set ::env(RIBBON_SCENE) [expr {$mode in {empty sort} ? "empty" : "tree"}]
	set shot $::env(RIBBON_NOTES_SHOT)
	unset ::env(RIBBON_NOTES_SHOT)
	uplevel #0 [list source -encoding utf-8 [file join $here notes-scene.tcl]]
	after 400 [list apply {{mode} {
		# the pointer off the window (xvfb starts it mid-screen): only the board's row is raised
		event generate $::notesapp::win <Motion> -warp 1 -x 5 -y 5
		update
		switch $mode {
			move { notesapp::move_menu }
			sort { notesapp::sort_menu }
			default { notesapp::more_menu }
		}
		update
		set m [notesapp::more_menu_path]
		# the board's row under the pointer: Move to Trash, New folder, Move to…, Home (the fifth folder), Name
		set row [dict get {note trash empty folder move-menu move move f4 sort name} $mode]
		event generate $m.$row <Enter>
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
check "the menu is right-aligned under the ⋯, 4 below it: 220 x 193 at (W - 238, 60)" \
	[expr {[winfo x $m] == $W - 238 && [winfo y $m] == 60 && [winfo width $m] == 220 && [winfo height $m] == 193}]
set kids [lmap w [winfo children $m] {winfo name $w}]
check "the rows are New note, New folder, Import…, Move to… and Move to Trash, in the board's places" \
	[expr {$kids eq {new folder import move trash} && [winfo y $m.new] == 6 && [winfo y $m.folder] == 40 && [winfo y $m.import] == 74 \
		&& [winfo y $m.move] == 119 && [winfo y $m.trash] == 153 && [winfo x $m.new] == 6 && [winfo width $m.new] == 208}]
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

puts "Move to…"
file mkdir [file join $dir Ribbon Shell] [file join $dir Home]
put [file join $dir Ribbon "Moving.md"] "# Moving\n\nGoes home\n"
put [file join $dir Ribbon .versions "Moving.1700000000.md"] "# Moving\n\nolder\n"
put [file join $dir Home "Twin.md"] "# Twin\n\nalready home\n"
put [file join $dir Ribbon "Twin.md"] "# Twin\n\nfrom Ribbon\n"
notes::index::refresh
notesapp::open_note Ribbon Moving
press_more
row move
set kids [lmap w [winfo children $m] {winfo name $w}]
set fl [notesapp::all_folders ""]
check "Move to… shows every folder in the tree's order in the menu's place, 34 px rows" \
	[expr {[menu_open] && [llength $kids] == [llength $fl] && [winfo x $m] == $W - 238 && [winfo y $m] == 60 \
		&& [winfo height $m] == 12 + 34 * [llength $fl] && [lsearch -exact $fl Ribbon/Shell] == [lsearch -exact $fl Ribbon] + 1}]
set home [lsearch -exact $fl Home]
event generate $m.f$home <ButtonPress-1> -x 20 -y 17
update
check "a press on Home moves the note's file and its earlier texts there; it stays open" \
	[expr {![menu_open] && ![file exists [file join $dir Ribbon Moving.md]] && [file exists [file join $dir Home Moving.md]] \
		&& [file exists [file join $dir Home .versions Moving.1700000000.md]] \
		&& $::notesapp::state(folder) eq "Home" && $::notesapp::state(note) eq "Moving" && "Moving" in [names Home]}]
notesapp::open_note Ribbon Twin
notesapp::move_open Home
check "a name taken in the folder is numbered; the note there keeps its own" \
	[expr {[file exists [file join $dir Home "Twin 2.md"]] && [string match "*already home*" [notes::store::read_note Home Twin]] \
		&& $::notesapp::state(note) eq "Twin 2"}]
notesapp::move_open Home
check "moving to the folder it is in does nothing" [expr {[file exists [file join $dir Home "Twin 2.md"]] && $::notesapp::state(note) eq "Twin 2"}]
for {set i 0} {$i < 30} {incr i} { file mkdir [file join $dir [format "Many %02d" $i]] }
notes::index::refresh
notesapp::move_menu
update idletasks
set fit $::notesapp::card_fit
check "a list longer than the window shows what fits and the wheel scrolls it" \
	[expr {$fit < [llength [notesapp::all_folders ""]] && [winfo height $m] == 12 + 34 * $fit && [winfo ismapped $m.f0]}]
event generate $m.f0 <Button-5>
update
check "  (the first row goes, the next comes up)" [expr {$::notesapp::card_top == 1 && ![winfo ismapped $m.f0] && [winfo y $m.f1] == 6}]
notesapp::more_close
for {set i 0} {$i < 30} {incr i} { file delete [file join $dir [format "Many %02d" $i]] }

puts "the sort menu"
put [file join $dir Sorted "beta.md"] "# beta\n\nb\n"
put [file join $dir Sorted "Alpha.md"] "# Alpha\n\na\n"
put [file join $dir Sorted "Gamma.md"] "---\npinned: true\n---\n# Gamma\n\ng\n"
foreach {n d} {Alpha 300 beta 100 Gamma 500} { file mtime [file join $dir Sorted "$n.md"] [expr {$t - $d}] }
file mkdir [file join $dir Bare]
notes::index::refresh
notesapp::open_folder Bare
check "the tree lists a folder's notes pinned first, then newest" \
	[expr {[lmap e [notesapp::visible_notes Sorted] {dict get $e name}] eq {Gamma beta Alpha}}]
# the sort button: 32 px left of the ⋯ one, 2 apart
click [expr {$W - 68}] 40
update idletasks
set kids [lmap w [winfo children $m] {winfo name $w}]
check "a press on the empty folder's sort button opens Last edited and Name, 200 x 80 at (W - 252, 60)" \
	[expr {[menu_open] && $kids eq {edited name} && [winfo x $m] == $W - 252 && [winfo y $m] == 60 && [winfo width $m] == 200 && [winfo height $m] == 80}]
row name
check "Name orders them by name (pinned still first) and closes the menu" \
	[expr {![menu_open] && [lmap e [notesapp::visible_notes Sorted] {dict get $e name}] eq {Gamma Alpha beta}}]
set sf [file join $::env(XDG_STATE_HOME) ribbon-notes sort]
check "the order is kept in the state directory" [expr {[file exists $sf] && [string trim [read [set fh [open $sf]]]] eq "name"}]
close $fh
unset ::notesapp::sort_by
check "  and read back" [expr {[notesapp::sort_by] eq "name"}]
click [expr {$W - 68}] 40
row edited
check "Last edited puts the newest first again" \
	[expr {[lmap e [notesapp::visible_notes Sorted] {dict get $e name}] eq {Gamma beta Alpha}}]

check "no background errors" [expr {[llength $bgerrors] == 0}]
if {$fails} { puts "notes more: $fails checks failed"; exit 1 }
puts "notes more: all checks passed"
exit 0
