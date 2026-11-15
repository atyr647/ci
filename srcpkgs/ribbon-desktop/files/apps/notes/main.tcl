# main.tcl - Notes (ribbon-notes, U34): the window, the 300 px tree bar, the note on a 620 px measure, saving.
# Tcl/Tk, drawn as Notes-R4-A-Tree, -A2-Edit, -A3-Empty and -A4-Search (design/mockups, gen_notes_r4.py).
#
#   ribbon-notes [FILE...]        (the notes folder is ~/Notes, or RIBBON_NOTES_ROOT)
#   ribbon-notes --capture        the quick-capture panel (capture.tcl): handed to a running Notes, else opened here
#   RIBBON_NOTES_SCENE = file     a test scene (tests/notes-scene.tcl), run instead of the normal start
#
# The model is apps/notes/{store,markdown,index}.tcl (U33). The chrome is one canvas drawn with the Appearance
# app's ui library (tree.tcl, search-ui.tcl); the note is a Tk text widget (editor.tcl) placed over the canvas.

namespace eval ::notesapp {
	variable W 1240
	variable H 780
	variable BW 300                 ;# the tree bar
	variable MEASE 620              ;# the note's measure
	variable win .w
	variable cv .w.c
	variable page .w.t              ;# the Markdown text
	variable scene 0
	variable appdir [file dirname [file normalize [info script]]]
	variable mono "Ribbon Mono"
	variable state
	array set state {folder "" note "" dirty 0 query "" searchfocus 0 tag "" hits 0 current 0 findq "" view ""}
	variable open {}                ;# folders open in the tree
	variable more {}                ;# folders showing every note
	variable c
	array set c {}
	variable sheet ""
}

# The directories of the shared libraries and the notes' own folder, as the editor does.
proc ::notesapp::find_dir {name file} {
	foreach d [list [file normalize [file join $::notesapp::appdir .. $name]] [file normalize [file join $::notesapp::appdir .. .. $name]] /usr/lib/ribbon/$name] {
		if {[file exists [file join $d $file]]} { return $d }
	}
	puts stderr "ribbon-notes: $name/$file was not found"; exit 1
}

# The libraries are sourced at global level (source runs in the caller's namespace, so the ui library must be
# sourced with uplevel #0 for ::ui to be built), the same as the editor.
proc ::notesapp::libraries {} {
	set shell [find_dir shell raster.tcl]
	set appearance [find_dir appearance ui.tcl]
	foreach d [list /usr/lib/ribbon [file dirname $shell]] { if {$d ni $::auto_path} { lappend ::auto_path $d } }
	package require rbnalpha
	foreach f {text raster wall theme} { uplevel #0 [list source -encoding utf-8 [file join $shell $f.tcl]] }
	uplevel #0 [list source -encoding utf-8 [file join $appearance ui.tcl]]
	set ::ui::fonts(sg20) {{Ribbon Space Grotesk 600} 20 0.984 0.292}
	foreach f {store markdown index} { uplevel #0 [list source -encoding utf-8 [file join $::notesapp::appdir $f.tcl]] }
	foreach f {tree search-ui editor capture} { uplevel #0 [list source -encoding utf-8 [file join $::notesapp::appdir $f.tcl]] }
}

# The colours of the active theme, in the names ui.tcl uses.
proc ::notesapp::apply_theme {} {
	::theme::load
	ui::colours [dict create BAR $::theme::c(BAR) FIELD $::theme::c(FIELD) PILL $::theme::c(PILL) BORDER $::theme::c(BORDER) \
		FG $::theme::c(FG) MUTED $::theme::c(MUTED) ACCENT $::theme::c(ACCENT) ON_ACCENT $::theme::c(ON_ACCENT) \
		DESK_TOP $::theme::c(DESK_TOP) DESK_BOTTOM $::theme::c(DESK_BOTTOM) DESK_STRIPE $::theme::c(DESK_STRIPE) \
		DESK_STRIPE_ALPHA $::theme::c(DESK_STRIPE_ALPHA)]
	array unset ::notesapp::c
	array set ::notesapp::c [list bar $ui::c(bar) field $ui::c(field) pill $ui::c(pill) border $ui::c(border) fg $ui::c(fg) \
		muted $ui::c(muted) accent $ui::c(accent) ink $ui::c(ink) d2 $ui::c(d2) \
		hit [ui::mix $ui::c(accent) $ui::c(bar) 0.22] soft2 [ui::mix $ui::c(accent) $ui::c(bar) 0.30] \
		sel [ui::mix $ui::c(fg) $ui::c(bar) 0.14] \
		rowon $ui::c(field)]
}

# The window: a plain toplevel for a scene, else the ARGB window rbnalpha makes (see-through corners).
proc ::notesapp::build {} {
	variable win
	variable W
	variable H
	variable cv
	variable page
	variable scene
	wm withdraw .
	if {$scene} {
		toplevel $win -class RibbonNotes -borderwidth 0 -highlightthickness 0
		wm overrideredirect $win 1
		wm geometry $win ${W}x${H}+100+74
	} else {
		# labwc keeps the frame on the screen: a taller page than the room under the bars is fitted (rbn::fit)
		set H [rbn::fit $H]
		if {[rbn::appwindow $win RibbonNotes $W $H -fill $::notesapp::c(bar)]} { set ::ui::argbwin $win }
		wm title $win "Notes"
		wm iconname $win "Notes"
		# the window can be resized and maximised: the tree keeps its 300 px, the note its measure (resized)
		wm minsize $win 900 600
		wm protocol $win WM_DELETE_WINDOW ::notesapp::quit
		wm geometry $win ${W}x${H}+[expr {max(0, ([winfo screenwidth .] - $W) / 2)}]+[expr {max(0, ([winfo screenheight .] - $H) / 2 + 14)}]
	}
	if {![winfo exists $cv]} { canvas $cv -width $W -height $H -highlightthickness 0 -borderwidth 0 -background $::notesapp::c(bar) }
	place $cv -x 0 -y 0
	set ::ui::cv $cv
	set ::ui::W $W
	set ::ui::H $H
	set ::ui::ox 0; set ::ui::oy 0
	set ::ui::behind ""; set ::ui::bx 0; set ::ui::by 0
	bind $cv <ButtonPress-1> {notesapp::press %x %y}
	bind $cv <B1-Motion> {ui::motion %x %y}
	bind $cv <ButtonRelease-1> {ui::release %x %y}
	bind $cv <Button-4> {notesapp::wheel %x %y -1}
	bind $cv <Button-5> {notesapp::wheel %x %y 1}
	notesapp::build_text $win
	bind $win <Control-f> {notesapp::search_focus}
	bind $win <Control-s> {notesapp::save}
	bind $win <Control-n> {notesapp::new_note}
	bind $win <Control-z> {notesapp::undo}
	bind $win <Control-Z> {notesapp::redo}
	bind $win <Control-y> {notesapp::redo}
	bind $win <Control-b> {notesapp::format_bold}
	bind $win <Control-i> {notesapp::format_italic}
	bind $win <Control-e> {notesapp::format_code}
	bind $win <Control-k> {notesapp::format_link}
	bind $win <Control-g> {notesapp::find_step 1}
	bind $win <Control-G> {notesapp::find_step -1}
	bind $win <Escape> {notesapp::escape}
	bind $win <KeyPress> {notesapp::key_top %K %A}
	bind $win <Destroy> {if {"%W" eq $::notesapp::win} {::notesapp::save}}
	bind $win <Configure> {if {"%W" eq $::notesapp::win} {::notesapp::resized %w %h}}
}

# A new window size (the person resized or maximised it): the canvas follows it and everything is drawn again for
# it. Nothing below the minimum size is laid out (the window manager keeps to wm minsize).
proc ::notesapp::resized {w h} {
	variable W
	variable H
	variable cv
	if {$w < 900 || $h < 600 || ($w == $W && $h == $H)} return
	set W $w
	set H $h
	set ::ui::W $W
	set ::ui::H $H
	$cv configure -width $W -height $H
	place $cv -x 0 -y 0 -width $W -height $H
	paint
}

# Keys go to the search field while it has the focus; everything else goes to the text.
proc ::notesapp::key_top {sym char} {
	variable state
	if {!$state(searchfocus)} return
	search_key $sym $char
	return -code break
}

proc ::notesapp::escape {} {
	variable state
	if {$state(searchfocus) || $state(query) ne ""} {
		search_clear
	}
}

# A press on the canvas: the ui library's hit test, where a hit's script gets the x and y only when its proc takes
# them (ui::press appends them to every script, and Notes' buttons, folders, notes and chips name procs that take
# none: each press of one raised "wrong # args").
proc ::notesapp::press {x y} {
	foreach h [lreverse $::ui::hits] {
		lassign $h x0 y0 x1 y1 script
		if {$script eq "" || $x < $x0 || $x >= $x1 || $y < $y0 || $y >= $y1} continue
		set cmd [namespace which [lindex $script 0]]
		if {$cmd ne "" && [llength [info procs $cmd]]} {
			set want [info args $cmd]
			if {[lindex $want end] ne "args" && [llength $want] < [llength $script] + 1} {
				set ::ui::drag ""
				set ::ui::kbd 0
				uplevel #0 $script
				return
			}
		}
		break
	}
	ui::press $x $y
}

# Draw everything: the chrome on the canvas, the text widget where it is.
proc ::notesapp::paint {} {
	variable cv
	if {![winfo exists $cv]} return
	ui::begin notes {}
	tree_paint
	page_paint
	ui::finish
}

proc ::notesapp::quit {args} {
	save
	exit 0
}

# ---- the folders the tree remembers ------------------------------------------------------------------
proc ::notesapp::state_file {} {
	set base [expr {[info exists ::env(XDG_STATE_HOME)] ? $::env(XDG_STATE_HOME) : "$::env(HOME)/.local/state"}]
	return [file join $base ribbon-notes open-folders]
}

proc ::notesapp::load_open {} {
	variable open
	if {[catch {
		set fh [::open [state_file] r]
		set open [split [string trim [read $fh]] \n]
		close $fh
	}]} { set open {} }
}

proc ::notesapp::save_open {} {
	variable open
	if {[catch {
		set f [state_file]
		file mkdir [file dirname $f]
		set fh [::open $f w]
		puts $fh [join $open \n]
		close $fh
	}]} return
}

proc ::notesapp::toggle_open {folder} {
	variable open
	if {$folder in $open} {
		set open [lsearch -all -inline -not -exact $open $folder]
	} else {
		lappend open $folder
	}
	save_open
}

proc ::notesapp::is_open {folder} {
	variable open
	expr {$folder in $open}
}

# ---- the note -------------------------------------------------------------------------------------------
# Writes the note if its text has changed since it was read.
proc ::notesapp::save {} {
	variable state
	if {$state(note) eq "" || !$state(dirty)} return
	set text [page_text]
	set old [notes::store::read_note $state(folder) $state(note)]
	if {$text ne $old} {
		notes::store::write_note $state(folder) $state(note) $text
		# a title that changed renames the file (and its versions) after it: ~/Notes/<folder>/<title>.md
		set was [notes::md::title [dict get [notes::md::parse $old] body]]
		set now [notes::md::title [dict get [notes::md::parse $text] body]]
		if {$now ne $was} { rename_by_title $now }
	}
	set state(dirty) 0
	notes::index::refresh
}

# The open note takes the file name TITLE: a "/", a backslash or a control character becomes "-", leading dots and
# spaces go (a hidden file is no note), at most 120 characters; a name another note of the folder has gets " 2",
# " 3"... An empty title keeps the name.
proc ::notesapp::rename_by_title {title} {
	variable state
	set name [string trim [regsub -all {[/\\[:cntrl:]]} $title -]]
	set name [string trim [string trimleft $name ". "]]
	set name [string trim [string range $name 0 119]]
	if {$name eq "" || $name eq $state(note)} return
	set base $name
	set i 1
	# (a numbered name the note already has is its own: "Milk 2" retitled "Milk" next to Milk.md stays "Milk 2")
	while {$name ne $state(note) && [file exists [notes::store::note_path $state(folder) $name]]} {
		incr i
		set name "$base $i"
	}
	if {$name eq $state(note)} return
	if {[catch {notes::store::rename_note $state(folder) $state(note) $name} err]} {
		puts stderr "ribbon-notes: could not rename the note: $err"
		return
	}
	set state(note) $name
	# the tree row and the crumbs take the new name (Ctrl+S saves without a redraw)
	after idle ::notesapp::paint
}

proc ::notesapp::open_note {folder name} {
	variable state
	# the save can rename the open note after its title: a click on its row (drawn with the old name) opens it as renamed
	set was [list $state(folder) $state(note)]
	save
	if {[list $folder $name] eq $was} { set name $state(note) }
	set state(folder) $folder
	set state(note) $name
	set state(view) ""
	set state(dirty) 0
	# the folder and its parents are open, so the note shows in the tree
	set parts [expr {$folder eq "" ? {} : [split $folder /]}]
	set acc ""
	foreach p $parts {
		set acc [expr {$acc eq "" ? $p : "$acc/$p"}]
		if {!([is_open $acc])} { toggle_open $acc }
	}
	page_load $folder $name
	paint
}

proc ::notesapp::open_folder {folder} {
	variable state
	save
	set state(folder) $folder
	set state(note) ""
	set state(view) ""
	paint
}

proc ::notesapp::new_note {} {
	variable state
	save
	set name [notes::store::create_note $state(folder)]
	notes::index::refresh
	open_note $state(folder) $name
}

# Pins or unpins the open note.
proc ::notesapp::toggle_pin {} {
	variable state
	if {$state(note) eq ""} return
	set p [notes::md::parse [page_text]]
	set text [notes::md::build [expr {![dict get $p pinned]}] [dict get $p has_fm] [dict get $p fm] [dict get $p body]]
	page_load $state(folder) $state(note) $text
	set state(dirty) 1
	save
	paint
}

# Text the note page holds, with its front matter: the file's text.
proc ::notesapp::page_text {} {
	variable page
	variable state
	set body [body_text]
	set p [notes::md::parse [notes::store::read_note $state(folder) $state(note)]]
	return [notes::md::build [dict get $p pinned] [dict get $p has_fm] [dict get $p fm] $body]
}

# The tag chips: click one to show only the notes with it.
proc ::notesapp::set_tag {t} {
	variable state
	if {$state(tag) eq $t} { set state(tag) "" } else { set state(tag) $t }
	paint
}

# Starts the app: the window, the state, the first note, the first draw.
proc ::notesapp::start {argv} {
	variable scene
	variable state
	set scene [info exists ::env(RIBBON_NOTES_SCENE)]
	libraries
	apply_theme
	ui::fonts
	raster::init [file join [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$::env(HOME)/.cache"}] ribbon notes]
	load_open
	notes::index::refresh
	if {[lsearch -exact $argv --capture] >= 0} {
		# quick capture: a running Notes takes the request; otherwise the panel is this process's only window
		if {[cap_handoff]} { exit 0 }
		wm withdraw .
		cap_open 1
		return
	}
	build
	if {!$scene} { cap_listen }
	# a file named on the command line (Files' "Open with Notes", the .desktop file's %F)
	set first ""
	foreach a $argv { if {$a ne "--" && $a ne "--capture"} { set first $a } }
	if {$first ne ""} { open_arg $first }
	if {$scene} {
		uplevel #0 [list source -encoding utf-8 $::env(RIBBON_NOTES_SCENE)]
	}
	paint
}

# Opens the Markdown file PATH: a note in the store opens as itself; any other file (outside the store, or not a .md
# in it) is imported into the store's top folder as the Import button imports (import_files: its title or name, a
# number when the name is taken, its pictures copied) and that note opens. A file opened again whose text the
# top-folder note of its name already holds opens that note, not a second copy. Returns {folder name}, or {} when the
# file cannot be read.
proc ::notesapp::open_arg {path} {
	set path [file normalize $path]
	set root [file normalize [notes::store::root]]
	# (a note is NAME.md in a folder the tree shows: not "X.MD", nor in .trash or another hidden folder)
	set rel [string range $path [string length $root/] end]
	if {[string match *.md $path] && [string first $root/ $path] == 0 && [file isfile $path]
		&& ![llength [lsearch -all -glob [lrange [file split $rel] 0 end-1] .*]]} {
		set f [file dirname $rel]
		if {$f eq "."} { set f "" }
		set name [file rootname [file tail $path]]
		open_note $f $name
		return [list $f $name]
	}
	if {[catch {
		set fh [::open $path rb]
		set text [string map {\r\n \n} [encoding convertfrom utf-8 [read $fh]]]
		close $fh
	}]} { return {} }
	# the same file opened again: the note it made, while that still holds the same text (as the import writes it)
	set p [notes::md::parse $text]
	set made [notes::md::build [dict get $p pinned] [dict get $p has_fm] [dict get $p fm] [dict get $p body]]
	# (the name import_files gives it: its title, else its file's name; then "Name 2", "Name 3" when taken)
	set base [import_name [file rootname [file tail $path]]]
	foreach l [dict get $p fm] {
		if {[regexp {^title:\s*(.*?)\s*$} $l -> t]} {
			regexp {^"(.*)"$} $t -> t
			regexp {^'(.*)'$} $t -> t
			if {[import_name $t] ne ""} { set base [import_name $t] }
		}
	}
	foreach name [notes::store::notes ""] {
		if {$name ne $base && !([string first "$base " $name] == 0 && [string is digit -strict [string range $name [string length "$base "] end]])} continue
		if {![catch {notes::store::read_note "" $name} t] && ($t eq $text || $t eq $made)} {
			open_note "" $name
			return [list "" $name]
		}
	}
	set names [import_files [list $path] ""]
	if {![llength $names]} { return {} }
	notes::index::refresh
	open_note "" [lindex $names 0]
	return [list "" [lindex $names 0]]
}

# Saves the window (ImageMagick import, the window's 1240 x 780 at 100,74 in a scene) and exits.
proc ::notesapp::shot_and_exit {file} {
	variable W
	variable H
	update
	exec import -window root -crop ${W}x${H}+100+74 +repage $file
	exit 0
}

::notesapp::start $argv
