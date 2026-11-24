# search-ui.tcl - search (U34): the field in the tree bar filters the tree to the results, grouped by folder, with
# a snippet and the match highlighted. Keys go to the field while it has the focus (the canvas takes the focus, so
# the text widget does not take the letters). Opening a result opens the note with its matches marked.

proc ::notesapp::search_focus {} {
	variable state
	variable cv
	variable page
	set state(searchfocus) 1
	focus -force $cv
	paint
}

proc ::notesapp::search_clear {} {
	variable state
	variable page
	set state(query) ""
	set state(searchfocus) 0
	set state(current) 0
	find_marks
	if {[winfo exists $page] && [winfo ismapped $page]} { focus $page }
	paint
}

proc ::notesapp::search_key {sym char} {
	variable state
	switch -- $sym {
		BackSpace { set state(query) [string range $state(query) 0 end-1] }
		Escape { search_clear; return }
		Return - Tab - Up - Down - Left - Right { return }
		default {
			if {$char ne "" && [scan $char %c] >= 32} { append state(query) $char }
		}
	}
	set state(current) 0
	find_marks
	paint
}

# Cuts S so that it fits in WIDTH pixels of font F, with an ellipsis.
proc ::notesapp::fit {s f width} {
	if {[tw $f $s] <= $width} { return $s }
	set n [string length $s]
	while {$n > 1 && [tw $f "[string range $s 0 [expr {$n - 1}]]..."] > $width} { incr n -1 }
	return "[string range $s 0 [expr {$n - 1}]]..."
}

# The folder path above F ("" for a top-level folder); the notes at the root are the folder "".
proc ::notesapp::parent_of {f} {
	set i [string last / $f]
	if {$i < 0} { return "" }
	return [string range $f 0 [expr {$i - 1}]]
}

# The results in the tree bar, as the board draws them: each folder with the hits in it and below (a row of 35 px),
# its notes newest first (52 px each), then its subfolders nested 20 px deeper. Folders are ordered newest first.
proc ::notesapp::search_paint {} {
	variable state
	variable c
	variable sfolder
	set hits [notes::index::search $state(query)]
	set n [llength $hits]
	label 26 130 "RESULTS" i11s $c(muted)
	ui::text 284 121 "$n [expr {$n == 1 ? {note} : {notes}}]" i11s $c(muted) e
	if {$n == 0} {
		ui::text 26 163 "No notes match" i13 $c(muted)
		return
	}
	# per folder: its notes, the hits in it and below, and the newest of them
	set sfolder [dict create]
	foreach h [lsort -command ::notesapp::newer $hits] {
		set f [dict get $h folder]
		set mt [dict get $h mtime]
		set g $f
		while {1} {
			if {![dict exists $sfolder $g]} { dict set sfolder $g [dict create notes {} count 0 newest 0] }
			set e [dict get $sfolder $g]
			if {$g eq $f} { dict set e notes [concat [dict get $e notes] [list $h]] }
			dict set e count [expr {[dict get $e count] + 1}]
			if {$mt > [dict get $e newest]} { dict set e newest $mt }
			dict set sfolder $g $e
			set p [parent_of $g]
			if {$g eq "" || $p eq ""} break
			set g $p
		}
	}
	set y 145
	foreach f [search_children ""] { set y [search_branch $f 0 $y] }
}

# Newest first (the hits of one folder keep this order; pinned notes take their place by date).
proc ::notesapp::newer {a b} {
	set ma [dict get $a mtime]
	set mb [dict get $b mtime]
	if {$ma != $mb} { return [expr {$ma > $mb ? -1 : 1}] }
	return [string compare [dict get $a name] [dict get $b name]]
}

# The folders with hits directly under P (the top level for ""), newest first; "" is the notes at the root.
proc ::notesapp::search_children {p} {
	variable sfolder
	set out {}
	dict for {g e} $sfolder {
		if {$p eq "" && $g eq ""} { lappend out $g; continue }
		if {$g ne "" && [parent_of $g] eq $p} { lappend out $g }
	}
	return [lsort -command ::notesapp::by_newest_folder $out]
}

proc ::notesapp::by_newest_folder {a b} {
	variable sfolder
	set ma [dict get [dict get $sfolder $a] newest]
	set mb [dict get [dict get $sfolder $b] newest]
	if {$ma != $mb} { return [expr {$ma > $mb ? -1 : 1}] }
	return [string compare $a $b]
}

# One folder: its row at Y, its notes, then its subfolders at DEPTH + 1. Returns the next free row.
proc ::notesapp::search_branch {f depth y} {
	variable c
	variable sfolder
	set e [dict get $sfolder $f]
	set x [expr {27 + 20 * $depth}]
	set name [expr {$f eq "" ? "Notes" : [file tail $f]}]
	icon down 12 $c(muted) $x [expr {$y + 14}] 2.2
	icon folder 16 $c(muted) [expr {$x + 23}] [expr {$y + 12}]
	ui::text [expr {$x + 41}] [expr {$y + 9}] $name i13m $c(fg)
	ui::text 270 [expr {$y + 9}] [dict get $e count] i12 $c(muted) e 0 {} 1
	set y [expr {$y + 35}]
	foreach h [dict get $e notes] { set y [result_row $h $y $depth] }
	if {$f eq ""} { return $y }
	foreach g [search_children $f] { set y [search_branch $g [expr {$depth + 1}] $y] }
	return $y
}

# A result at Y (its box is 50 px high): the name and date, then the snippet with the match marked.
proc ::notesapp::result_row {h y depth} {
	variable c
	variable state
	set name [dict get $h name]
	set folder [dict get $h folder]
	set x0 [expr {62 + 20 * $depth}]
	set on [expr {$state(note) eq $name && $state(folder) eq $folder}]
	if {$on} { ui::box 14 $y 272 50 -fill $c(field) -radius 9 }
	if {$on} { ui::box 14 [expr {$y + 8}] 3 32 -fill $c(accent) -radius 2 }
	ui::text $x0 [expr {$y + 7}] [fit $name i13m [expr {212 - 20 * $depth}]] [expr {$on ? "i13s" : "i13m"}] $c(fg)
	if {[dict get $h pinned]} {
		icon pin 12 $c(muted) 270 [expr {$y + 10}] 2
	} else {
		ui::text 276 [expr {$y + 7}] [date_label [dict get $h mtime]] i12 $c(muted) e 0 {} 1
	}
	set snip [dict get $h snippet]
	set text [dict get $snip text]
	set at [dict get $snip at]
	set len [dict get $snip len]
	set x $x0
	set top [expr {$y + 26}]
	set text [fit $text i12 [expr {224 - 20 * $depth}]]
	if {$at + $len <= [string length $text]} {
		set pre [string range $text 0 [expr {$at - 1}]]
		set mt [string range $text $at [expr {$at + $len - 1}]]
		set post [string range $text [expr {$at + $len}] end]
		ui::text $x $top $pre i12 $c(muted)
		set x [expr {$x + [tw i12 $pre]}]
		set w [tw i12 $mt]
		ui::box $x [expr {$top + 1}] $w 16 -fill $c(hit) -radius 3
		ui::text $x $top $mt i12 $c(fg)
		ui::text [expr {$x + $w}] $top $post i12 $c(muted)
	} else {
		ui::text $x $top $text i12 $c(muted)
	}
	ui::hit 14 $y 272 50 [list notesapp::open_result $folder $name]
	return [expr {$y + 52}]
}

proc ::notesapp::open_result {folder name} {
	variable state
	set state(current) 0
	open_note $folder $name
}
