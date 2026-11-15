# notes-scene.tcl - puts the Notes window into one of its boards' states, for the review screenshots
# (design/mockups Notes-R4-A-Tree, -A2-Edit, -A3-Empty, -A4-Search). Run by apps/notes/main.tcl through
# RIBBON_NOTES_SCENE=this file.
#   RIBBON_SCENE            = tree | edit | empty | search (default tree)
#   RIBBON_NOTES_FIXTURES   = the folder the notes are written to (made here; it becomes the notes root)
#   RIBBON_NOTES_SHOT       = file: a screenshot of the window, then exit
# Any Tcl error fails: bgerror prints it and exits 1.
set scene [expr {[info exists ::env(RIBBON_SCENE)] ? $::env(RIBBON_SCENE) : "tree"}]
set dir $::env(RIBBON_NOTES_FIXTURES)
proc bgerror {msg} { puts stderr "notes-scene: $msg\n$::errorInfo"; exit 1 }

proc note {folder name text {when ""}} {
	global dir
	set d [expr {$folder eq "" ? $dir : [file join $dir {*}[split $folder /]]}]
	file mkdir $d
	set path [file join $d "$name.md"]
	set fh [open $path w]
	fconfigure $fh -encoding utf-8 -translation lf
	puts -nonewline $fh $text
	close $fh
	# the list's dates: a week of weekdays (Thu, Wed, Tue as the board shows them) and older day-month dates
	if {$when ne ""} { file mtime $path $when }
}

file delete -force $dir
file mkdir [file join $dir Ribbon]
# a picture for the notes, drawn by the same helper the tests use
# the image strip of Notes-R4-A4-Search: five photo thumbnails on a card, the second one chosen (accent ring)
set here [file dirname [file normalize [info script]]]
set now [clock seconds]
set thumbs {photo-blue-0 photo-dusk-1 photo-ice-0 photo-ember-1 photo-fern-0}
set card [image create photo -width 620 -height 106]
$card put {#121110} -to 0 0 620 106
$card put {#3B3835} -to 0 0 620 1
$card put {#3B3835} -to 0 105 620 106
$card put {#3B3835} -to 0 0 1 106
$card put {#3B3835} -to 619 0 620 106
for {set i 0} {$i < 5} {incr i} {
	set x [expr {16 + $i * 118}]
	set f [file join $dir thumb$i.png]
	exec tclsh8.6 [file join $here make-picture.tcl] [lindex $thumbs $i] 104 64 $f
	set t [image create photo -file $f]
	$card copy $t -to $x 16
	image delete $t
	file delete $f
	# the bar under each thumbnail: pill colour, the chosen one white and wider
	set bw [expr {$i == 1 ? 40 : 28}]
	$card put [expr {$i == 1 ? {#EEE9E3} : {#36302C}}] -to $x 87 [expr {$x + $bw}] 91
}
# the accent ring round the chosen thumbnail
set rx [expr {16 + 118}]
$card put {#FF7A59} -to [expr {$rx - 3}] 13 [expr {$rx + 107}] 16
$card put {#FF7A59} -to [expr {$rx - 3}] 80 [expr {$rx + 107}] 83
$card put {#FF7A59} -to [expr {$rx - 3}] 13 [expr {$rx}] 83
$card put {#FF7A59} -to [expr {$rx + 104}] 13 [expr {$rx + 107}] 83
$card write [file join $dir Ribbon onstage-tiles.png] -format png

# the pictures of the notes: one-bar.png is the edit board's 620 x 150 blue photo (a PNG); evening-light.jpg is the tree
# board's 620 x 220 dusk photo, a real JPEG made with ffmpeg (Tk reads no JPEG, so the app goes through ffmpeg too)
exec tclsh8.6 [file join $here make-picture.tcl] photo-blue-1 620 150 [file join $dir Ribbon one-bar.png]
exec tclsh8.6 [file join $here make-picture.tcl] photo-dusk-0 620 220 [file join $dir evening-light.png]
exec ffmpeg -nostdin -v error -y -i [file join $dir evening-light.png] -q:v 2 [file join $dir Ribbon evening-light.jpg]
file delete [file join $dir evening-light.png]

# which of the two cuts of the note exist: the tree, empty and capture boards list the first cut (and no second);
# the edit board lists the second (and no first); the search board has the first
set first [expr {$scene ne "edit"}]
set second [expr {$scene eq "edit"}]
set earlier [expr {$scene eq "search" ? "Earlier, a list of tiles was tried and dropped.\n\n" : ""}]
if {$first} {
	note Ribbon "Notes app, first cut" "---
pinned: true
---
# Notes app, first cut

${earlier}One bar on the left, the note on the right. Every note is a Markdown file in \`~/Notes\`, so grep, git and backups just work.

## Must have

- \[x\] Search titles and text as you type
- \[x\] Pin notes to the top
- \[x\] Folders and \`#tags\`
- \[ \] Checkboxes that survive a round trip to Markdown
- \[ \] Paste an image; it is kept next to the note

## Look

The bar from \[Settings\](https://ribbon.example/settings), headings in Space Grotesk, text in Inter at 15 px on a 620 px measure.

!\[evening-light\](evening-light.jpg)
evening-light.jpg

#design
"
}
if {$second} {
	note Ribbon "Notes app, second cut" "---
pinned: true
---
# Notes app, second cut

One bar holds folders, notes and tags; the note sits on a measured page. Formatting appears where you select, so the page keeps no toolbar.

## Checklist

- \[x\] Search titles and text as you type
- \[x\] Pin notes to the top
- \[ \] Checkboxes that survive a round trip to \`- \[ \]\`

!\[one-bar\](one-bar.png)
one-bar.png

## Saving

\`\`\`tcl
proc ::notes::store::save {name text} {
    set path \[file join \$root \$name.md\]
    file rename -force \$path.new \$path
}
\`\`\`

#design
"
}
note Ribbon "Release checklist 0.9" "---\npinned: true\n---\n# Release checklist 0.9\n\n- \[ \] Tag the build\n\n#todo\n"
note Ribbon "Onstage tile sizes" "# Onstage tile sizes\n\nTiles are 140 × 88 with an 8 + 17 caption under them. Groups get a 17 label and an 8 gap over 88-high cards, so both end on the same line.\n\n## Strip\n\n- Eight across at 1440, six at 1280\n- The chosen tile takes the accent ring; nothing else does\n- Captions in Inter 13, muted until chosen\n\n!\[onstage-tiles.png\](onstage-tiles.png)\nonstage-tiles.png\n\n## Open questions\n\n- \[ \] Do tiles shrink below 1280?\n\n#design\n"
note Ribbon "foot palette mapping" "Foot palette mapping, to do after the kit sheet.\n"
note Ribbon "Kit sheet wording" "Kit sheet wording: one tile per kit, name, version, size.\n"
note Ribbon "Dock menus" "Dock menus rise out of the tile as one shape.\n"
note Ribbon "Greeter blur timings" "Blur timings for the greeter, in milliseconds.\n"
note Ribbon/Shell "Tiling in labwc" "# Tiling in labwc\n\nSnap to halves; tile rules in rc.xml\n\n#kit\n"
note Ribbon/Shell "Panel layout" "Panel layout notes.\n"
note Ribbon/Design "Palette roles" "Palette roles: bar, field, pill, accent.\n"
note Inbox "Call the dentist" "Ask about Thursday.\n"
note Inbox "Water the plants" "Every Sunday.\n"
note Home "Bathroom" "Tiles from Topps, 30 × 60 matt.\n\n#home\n"
note Home "Kitchen wall" "Zellige tiles, 10 × 10, sage glaze.\n"
note Recipes "Bread on a quarry tile" "Preheat the tile for 45 min at 250°.\n\n#recipes\n"
note Reading "Notes on Kit" "The kit format in one page.\n"
# the folder sizes of the board (Inbox 7, Ribbon 41 = 20 + Shell 12 + Design 9, Home 23, Recipes 18, Reading 12): the
# rest are short entries, some carrying the tags the foot chips count (design 6, todo 5, ideas 4, kit 3, home 2, recipes 1)
proc fill {folder prefix total {tags {}}} {
	global dir
	set d [expr {$folder eq "" ? $dir : [file join $dir {*}[split $folder /]]}]
	set have [llength [glob -nocomplain -directory $d -types f *.md]]
	for {set i 1} {$have + $i - 1 < $total} {incr i} {
		set t [lindex $tags [expr {$i - 1}]]
		note $folder "$prefix $i" "Entry $i.\n[expr {$t ne "" ? "\n#$t\n" : ""}]" [expr {[clock seconds] - (20 + $i) * 86400}]
	}
}
fill Ribbon "Journal entry" 20 {design design design design todo todo todo todo ideas ideas ideas ideas}
fill Ribbon/Shell "Shell note" 12 {kit kit}
fill Ribbon/Design "Design note" 9
fill Inbox "Inbox note" 7
fill Home "Home note" 23 {home}
fill Recipes "Recipe" 18
fill Reading "Reading" 12
# three notes in the trash (the foot's Trash count)
foreach i {1 2 3} { note Reading "Old draft $i" "Old draft.\n" }
# the dates the lists show: Thu, Wed, Tue, Mon are this week's weekdays; the search board's are day and month
set now [clock seconds]
set mt [dict create {Ribbon/Notes app, first cut.md} [expr {$now - 600}] {Ribbon/Notes app, second cut.md} $now \
	{Ribbon/Release checklist 0.9.md} [expr {$now - 7200}] {Ribbon/Onstage tile sizes.md} [expr {$now - 3 * 86400}] \
	{Ribbon/foot palette mapping.md} [expr {$now - 4 * 86400}] {Ribbon/Kit sheet wording.md} [expr {$now - 5 * 86400}] \
	{Ribbon/Greeter blur timings.md} [expr {$now - 5 * 86400 - 20 * 3600}] \
	{Ribbon/Dock menus.md} [clock scan "2026-10-19 12:00"] {Ribbon/Shell/Tiling in labwc.md} [clock scan "2026-10-09 12:00"] \
	{Home/Bathroom.md} [clock scan "2026-10-12 12:00"] {Home/Kitchen wall.md} [clock scan "2026-09-03 12:00"] \
	{Recipes/Bread on a quarry tile.md} [clock scan "2026-08-28 12:00"]]
dict for {f t} $mt { if {[file exists [file join $dir $f]]} { file mtime [file join $dir $f] $t } }
if {$scene eq "empty"} { file mkdir [file join $dir Garden] }

# the state each board shows
notes::store::set_root $dir
set ::notesapp::open {Ribbon}
set ::notesapp::more {}
notes::index::refresh
foreach i {1 2 3} { notes::store::trash_note Reading "Old draft $i" }
notes::index::refresh
switch $scene {
	tree {
		notesapp::open_note Ribbon "Notes app, first cut"
	}
	edit {
		notesapp::open_note Ribbon "Notes app, second cut"
		# the board selects "appears where you select" and the format bar sits above it (Notes-R4-A2-Edit)
		set p $::notesapp::page
		set at [$p search -- "appears where you select" 1.0]
		$p tag add sel $at "$at + [string length {appears where you select}] chars"
		update
		notesapp::format_update
	}
	empty {
		set ::notesapp::open {Ribbon Garden}
		notesapp::open_folder Garden
	}
	search {
		set ::notesapp::state(query) tile
		notesapp::find_marks
		notesapp::open_result Ribbon "Onstage tile sizes"
		set ::notesapp::state(searchfocus) 0
	}
	capture {
		# the quick-capture panel over the window, with the board's note in it (Notes-R4-A5-Capture): the picture
		# card (miso-aubergine.jpg, a real JPEG made with ffmpeg and padded to the board's 1.2 MB with trailing bytes,
		# which a JPEG reader ignores) and the two tags
		exec tclsh8.6 [file join $here make-picture.tcl] photo-ember-2 240 160 [file join $dir miso-aubergine.png]
		exec ffmpeg -nostdin -v error -y -i [file join $dir miso-aubergine.png] -q:v 2 [file join $dir miso-aubergine.jpg]
		set pad [expr {1200000 - [file size [file join $dir miso-aubergine.jpg]]}]
		set fh [open [file join $dir miso-aubergine.jpg] ab]
		fconfigure $fh -translation binary
		puts -nonewline $fh [string repeat \0 $pad]
		close $fh
		notesapp::cap_open 0
		$::notesapp::cap(title) insert 0 "Groceries for Sunday"
		$::notesapp::cap(body) insert 1.0 "- \[x\] Oat milk\n- \[ \] Lemons\n- \[ \] Parmesan\n- \[ \] Bread flour, 1.5 kg"
		set ::notesapp::cap(tags) {home recipes}
		notesapp::cap_attach_set [file join $dir miso-aubergine.jpg]
		notesapp::cap_restyle
	}
	default {
		puts stderr "notes-scene: no scene $scene"; exit 1
	}
}
notesapp::paint

if {[info exists ::env(RIBBON_NOTES_SHOT)]} {
	if {$scene eq "capture"} {
		after 900 [list notesapp::cap_shot $::env(RIBBON_NOTES_SHOT)]
	} else {
		after 900 [list notesapp::shot_and_exit $::env(RIBBON_NOTES_SHOT)]
	}
}
