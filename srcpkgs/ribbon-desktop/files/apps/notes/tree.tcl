# tree.tcl - the tree bar (U34): the Notes head and the search field, the folders with their notes (open folders
# are remembered), "N more" rows, the tag chips and Trash at the foot. Drawn on the canvas with the ui library; each
# row's click is a ui::hit. Rows are drawn only inside the list (y 149 to 636); the list scrolls with the wheel
# (wheel), so a long tree reaches its last rows. Search replaces the tree with the results (search-ui.tcl).

namespace eval ::notesapp {
	variable paths
	array set paths {
		search {M10.5 4.5a6 6 0 1 1 0 12a6 6 0 1 1 0-12M15.5 15.5L20 20}
		x {M6 6l12 12M18 6L6 18}
		down {M6 9l6 6 6-6}
		right {M9 6l6 6-6 6}
		inbox {M22 12h-6l-2 3h-4l-2-3H2 M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z}
		pin {M12 17v5 M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z}
		more {M5 12h.01M12 12h.01M19 12h.01}
		checksq {M3 3h18v18H3z M7 12l3 3 7-7}
		plus {M12 5v14M5 12h14}
		edit {M12 20h9 M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4z}
		trash {M3 6h18 M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6 M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2}
		folder {M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z}
		sort {M3 6h18 M7 12h10 M10 18h4}
		file {M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8zM14 3v5h5}
		image {M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z M8.5 10a1.5 1.5 0 1 0 0-3a1.5 1.5 0 1 0 0 3z M21 15l-5-5L5 21}
		link {M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71 M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71}
		up {M18 15l-6-6-6 6}
		chev_right {M9 18l6-6-6-6}
	}
	variable tscroll 0              ;# how far the tree list is scrolled (px)
	variable tree_end 0             ;# the bottom of the tree's rows, unscrolled
	variable dry 0                  ;# 1 while the tree is only measured (no row is drawn)
	variable show_cap 6             ;# the notes an open folder lists before "N more": as many as fit, at most 6
}

# The width of S in font F, whole pixels.
proc ::notesapp::tw {f s} {
	return [expr {round([ui::measure $f $s])}]
}

# An icon at (x, y), size px, in colour (hex).
proc ::notesapp::icon {name size colour x y {sw 1.9}} {
	variable paths
	variable cv
	set i [raster::icon $paths($name) $size $sw [ui::col $colour] {} 0 0 0]
	$cv create image [expr {round($x)}] [expr {round($y)}] -image $i -anchor nw -tags page
}

# Text at (x, y) with its line centred on y; anchor w or e.
proc ::notesapp::label {x y str font colour {anchor w}} {
	ui::text $x [expr {$y - 9}] $str $font $colour $anchor
}

# The date a note shows: its weekday within a week, else day and month.
proc ::notesapp::date_label {mt} {
	set age [expr {[clock seconds] - $mt}]
	if {$age < 6 * 86400} { return [clock format $mt -format %a] }
	set d [string trimleft [clock format $mt -format %d] 0]
	return "$d [clock format $mt -format %b]"
}

# A row of H px at Y is drawn only when it lies inside the list (between the search field and the tag footer).
proc ::notesapp::row_visible {y h} {
	variable dry
	expr {!$dry && $y >= 149 && $y + $h <= $::notesapp::H - 144}
}

# How many notes an open folder lists: six, fewer when the folders below would run past the tag footer (the Empty
# board lists five of Ribbon's notes above the Garden folder). Measured with a dry run of the tree.
proc ::notesapp::fit_show {} {
	variable dry
	variable show_cap
	set dry 1
	for {set n 6} {$n > 2} {incr n -1} {
		set show_cap $n
		set y 149
		foreach f [sub_folders ""] { set y [folder_row $f 0 $y] }
		foreach e [visible_notes ""] { set y [note_row $e 0 $y] }
		if {$y <= $::notesapp::H - 143} break
	}
	set dry 0
	set show_cap $n
}

# The tree bar: 300 px, the desktop's bottom colour, a 1 px border on its right edge. The list is first, so the
# head and the footer that follow are never covered by a row.
proc ::notesapp::tree_paint {} {
	variable BW
	variable H
	variable state
	variable c
	variable tscroll
	variable tree_end
	ui::box 0 0 $BW $H -fill $ui::c(d2)
	ui::box [expr {$BW - 1}] 0 1 $H -fill $ui::c(border)
	ui::hit 0 0 $BW $H {notesapp::noop}
	# head: the Notes title and the new-note button
	ui::text 26 26 "Notes" sg22 $c(fg)
	ui::box 252 22 34 34 -fill $c(field) -radius 9
	icon edit 16 $c(fg) 261 31
	ui::hit 252 22 34 34 {notesapp::new_note}
	# search field
	ui::box 14 72 272 34 -fill $c(field) -radius 9 -ring [list [expr {$state(searchfocus) ? $c(accent) : $c(border)}] 1]
	icon search 14 [expr {$state(searchfocus) ? $c(accent) : $c(muted)}] 26 82 2
	if {$state(query) eq ""} {
		ui::text 46 79 "Search" i13 $c(muted)
	} else {
		ui::text 46 79 $state(query) i13 $c(fg)
		icon x 13 $c(muted) 268 82 2
		ui::hit 262 72 24 34 {notesapp::search_clear}
	}
	ui::hit 14 72 272 34 {notesapp::search_focus}
	if {$state(query) ne ""} {
		search_paint
		return
	}
	# the folders and their notes, scrolled by tscroll
	label 26 131 "FOLDERS" i11s $c(muted)
	icon plus 14 $c(muted) 266 120 2
	ui::hit 258 110 28 28 {notesapp::new_folder}
	fit_show
	set y [expr {149 - $tscroll}]
	foreach f [sub_folders ""] { set y [folder_row $f 0 $y] }
	foreach e [visible_notes ""] { set y [note_row $e 0 $y] }
	set tree_end [expr {$y + $tscroll}]
	# the tags and Trash at the foot
	label 26 [expr {$H - 132}] "TAGS" i11s $c(muted)
	set counts [notes::index::tag_counts]
	set x 22
	set row [expr {$H - 118}]
	foreach t [tag_order $counts] {
		set w [expr {[tw i12m "#$t"] + 18}]
		if {$x + $w > 286} { set x 22; incr row 32 }
		set on [expr {$state(tag) eq $t}]
		set ring [expr {$on ? [list -ring [list $c(border) 1]] : {}}]
		ui::box $x $row $w 26 -fill [expr {$on ? $c(pill) : $c(field)}] -radius 7 {*}$ring
		set fg [expr {$on ? $c(fg) : $c(muted)}]
		set hw [ui::text [expr {$x + 9}] [expr {$row + 6}] "#" i12m [ui::mix $fg [expr {$on ? $c(pill) : $c(field)}] 0.7]]
		ui::text [expr {$x + 9 + [tw i12m "#"]}] [expr {$row + 6}] $t i12m $fg
		ui::hit $x $row $w 26 [list notesapp::set_tag $t]
		incr x [expr {$w + 6}]
	}
	set trash [llength [notes::store::trashed]]
	set on [expr {$state(view) eq "trash"}]
	# a folder row's geometry (folder_row, depth 0): icon at 42, name at 68, count right at 276, 34 high
	set ry [expr {$H - 46}]
	if {$on} { ui::box 14 $ry 272 34 -fill $c(field) -radius 9 }
	icon trash 16 [expr {$on ? $c(fg) : $c(muted)}] 42 [expr {$ry + 9}]
	ui::text 68 [expr {$ry + 8}] "Trash" [expr {$on ? "i13s" : "i13m"}] [expr {$on ? $c(fg) : $c(muted)}]
	ui::text 276 [expr {$ry + 8}] $trash i12 $c(muted) e 0 {} 1
	ui::hit 14 $ry 272 34 {notesapp::show_trash}
}

proc ::notesapp::noop {args} {}

# The wheel scrolls the tree when it is over the tree bar; elsewhere it scrolls the note.
proc ::notesapp::wheel {x y dir} {
	variable tscroll
	variable tree_end
	if {$x >= $::notesapp::BW} {
		ui::scroll $x $y $dir
		return
	}
	set top [expr {max(0, $tree_end - ($::notesapp::H - 144))}]
	set tscroll [expr {max(0, min($top, $tscroll + 33 * $dir))}]
	paint
}

# The tags, most used first (the board's chips run design, todo, ideas, kit, home, recipes), then by name.
proc ::notesapp::tag_order {counts} {
	set rows {}
	dict for {t n} $counts { lappend rows [list $t $n] }
	set out {}
	foreach r [lsort -integer -decreasing -index 1 [lsort -index 0 $rows]] { lappend out [lindex $r 0] }
	return $out
}

# The folders directly under PARENT: Inbox first, then the fullest, then by name (the board: Inbox 7, Ribbon 41,
# Home 23, Recipes 18, Reading 12; under Ribbon Shell 12, Design 9).
proc ::notesapp::sub_folders {parent} {
	set out {}
	foreach f [notes::store::folders] {
		set cut [string last / $f]
		set p [expr {$cut < 0 ? "" : [string range $f 0 [expr {$cut - 1}]]}]
		if {$p eq $parent} { lappend out $f }
	}
	set rows {}
	foreach f $out { lappend rows [list $f [expr {$f eq "Inbox" ? 1 : 0}] [notes::index::count $f]] }
	set sorted {}
	foreach r [lsort -index 0 $rows] { lappend sorted $r }
	set sorted [lsort -integer -decreasing -index 2 $sorted]
	set sorted [lsort -integer -decreasing -index 1 $sorted]
	set out {}
	foreach r $sorted { lappend out [lindex $r 0] }
	return $out
}

# The notes of FOLDER that the tag filter lets through, in index order.
proc ::notesapp::visible_notes {folder} {
	variable state
	set out {}
	foreach e [notes::index::in_folder $folder] {
		if {$state(tag) eq "" || $state(tag) in [dict get $e tags]} { lappend out $e }
	}
	return $out
}

# A folder row at depth D, top Y; its notes below when open. Returns the next free Y. A row outside the list is
# not drawn, but the rows below it still count, so the list keeps its place when it scrolls.
proc ::notesapp::folder_row {folder depth y} {
	variable c
	variable state
	variable open
	set name [file tail $folder]
	set on [expr {$state(folder) eq $folder && $state(note) eq "" && $state(view) eq ""}]
	set x0 [expr {14 + 8 + 20 * $depth}]
	set opened [is_open $folder]
	if {[row_visible $y 34]} {
		if {$on} { ui::box 14 $y 272 34 -fill $c(field) -radius 9 }
		if {$on} { ui::box 14 [expr {$y + 8}] 3 18 -fill $c(accent) -radius 2 }
		icon [expr {$opened ? "down" : "right"}] 12 [expr {$on ? $c(fg) : $c(muted)}] $x0 [expr {$y + 11}] 2.2
		icon [expr {$folder eq "Inbox" ? "inbox" : "folder"}] 16 [expr {$on ? $c(accent) : ($opened ? $c(fg) : $c(muted))}] [expr {$x0 + 20}] [expr {$y + 9}]
		ui::text [expr {$x0 + 46}] [expr {$y + 8}] $name [expr {$on ? "i13s" : "i13m"}] [expr {$on || $opened ? $c(fg) : $c(muted)}]
		ui::text 276 [expr {$y + 8}] [notes::index::count $folder] i12 $c(muted) e 0 {} 1
		ui::hit 14 $y 272 34 [list notesapp::folder_click $folder]
	}
	set y [expr {$y + 35}]
	if {$opened} {
		foreach s [sub_folders $folder] { set y [folder_row $s [expr {$depth + 1}] $y] }
		set all [visible_notes $folder]
		set n 0
		set show [expr {$folder in $::notesapp::more ? 1000000 : $::notesapp::show_cap}]
		foreach e $all {
			if {$n >= $show} break
			set y [note_row $e [expr {$depth + 1}] $y]
			incr n
		}
		if {[llength $all] > $show} {
			set more "[expr {[llength $all] - $show}] more"
			if {[row_visible $y 30]} {
				set x [expr {$x0 + 20}]
				ui::text $x [expr {$y + 7}] $more i12 $c(muted)
				icon right 12 $c(muted) [expr {$x + [tw i12 $more] + 4}] [expr {$y + 9}] 2
				ui::hit 14 $y 272 30 [list notesapp::show_more $folder]
			}
			incr y 31
		}
	}
	return $y
}

proc ::notesapp::folder_click {folder} {
	variable state
	if {$state(folder) eq $folder && $state(note) eq "" && $state(view) eq ""} {
		toggle_open $folder
	} else {
		if {![is_open $folder]} { toggle_open $folder }
		open_folder $folder
	}
	paint
}

proc ::notesapp::show_more {folder} {
	variable more
	lappend more $folder
	paint
}

# A note row: its name, then the pin or the date at the right; the open note has the accent bar.
proc ::notesapp::note_row {e depth y} {
	variable c
	variable state
	set name [dict get $e name]
	set on [expr {$state(note) eq $name && $state(folder) eq [dict get $e folder] && $state(view) eq ""}]
	set x0 [expr {14 + 8 + 20 * $depth + 20}]
	if {[row_visible $y 32]} {
		if {$on} { ui::box 14 $y 272 32 -fill $c(field) -radius 9 }
		if {$on} { ui::box 14 [expr {$y + 8}] 3 16 -fill $c(accent) -radius 2 }
		ui::text $x0 [expr {$y + 7}] $name [expr {$on ? "i13s" : "i13m"}] [expr {$on ? $c(fg) : $c(muted)}]
		if {[dict get $e pinned]} {
			icon pin 12 [expr {$on ? $c(fg) : $c(muted)}] 266 [expr {$y + 10}] 2
		} else {
			ui::text 276 [expr {$y + 7}] [date_label [dict get $e mtime]] i12 $c(muted) e 0 {} 1
		}
		ui::hit 14 $y 272 32 [list notesapp::open_note [dict get $e folder] $name]
	}
	return [expr {$y + 33}]
}

# The "New folder": a folder made and opened in the tree.
proc ::notesapp::new_folder {} {
	variable state
	set parent $state(folder)
	set name [notes::store::create_folder $parent]
	toggle_open [expr {$parent eq "" ? $name : "$parent/$name"}]
	open_folder [expr {$parent eq "" ? $name : "$parent/$name"}]
}

# Trash: the page lists the trashed notes with Restore (trash_paint in editor.tcl).
proc ::notesapp::show_trash {} {
	variable state
	save
	set state(view) trash
	set state(note) ""
	paint
}
