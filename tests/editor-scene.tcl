# editor-scene.tcl - put the text editor into one of its boards' states, for screenshots
# (design/mockups/Editor-Final-1-Normal, -2-Many, -5-Close, and the open-documents list). Run by apps/editor/main.tcl
# through RIBBON_EDITOR_SCENE=this file.
#   RIBBON_SCENE          = normal | many | close | list | find | replace | split | welcome | diagnostics (default normal)
#     (diagnostics: Editor-Final-7: the normal state with a stub nagelfar's warning on line 17 and error on line 32, the
#      error's card up, and the window unfocused; the board's breakpoint tag on line 15 is not built: no debugger)
#     (normal: Editor-Final-1, with the change bars of its file on disk and a fold; find: Editor-Final-3-Find-B's top
#      window, the options menu open; replace: its bottom window, after one Replace)
#   RIBBON_EDITOR_FIXTURES = folder for files that are not in the project folders (created here)
#   RIBBON_EDITOR_SHOT     = file: take a screenshot of the window (ImageMagick import) and exit
#   RIBBON_EDITOR_EXIT     = ms: quit after drawing (default 1500 with a shot, else none)
# The boards' folders are under $HOME (~/src/ribbon-notes, ~/src/ribbon-shell, ~/Documents, ~/.config/...), so the
# status line and the sheet read as the boards do. Paths under /etc are not written: those documents are new
# (unsaved) paths, which the list shows as the board does.
# Any Tcl error fails: bgerror prints it and exits 1.
set scene [expr {[info exists ::env(RIBBON_SCENE)] ? $::env(RIBBON_SCENE) : "normal"}]
set dir $::env(RIBBON_EDITOR_FIXTURES)
set home $::env(HOME)
file mkdir $dir
proc bgerror {msg} { puts stderr "editor-scene: $msg\n$::errorInfo"; exit 1 }

# A file with TEXT in FOLDER (default: the fixtures folder). Returns its path.
proc fixture {name text {folder ""}} {
	global dir
	set d [expr {$folder eq "" ? $dir : $folder}]
	file mkdir $d
	set f [file join $d $name]
	set fh [open $f wb]
	fconfigure $fh -translation binary
	puts -nonewline $fh [encoding convertto utf-8 $text]
	close $fh
	return $f
}

set store {# store.tcl - the notes store
#
# One Markdown file per note under the root. The index maps each note's
# name to its title, its tags and whether it is pinned.
#

namespace eval ::notes::store {}

proc ::notes::store::load {} {
	variable root
	variable index
	foreach path [glob -nocomplain -directory $root -types f *.md] {
		set f [open $path r]
		fconfigure $f -encoding utf-8
		set text [read $f]
		close $f
		dict set index [file rootname [file tail $path]] [parse $text]
	}
	return [dict size $index]
}

proc ::notes::store::parse {text} {
	set title ""
	set tags {}
	set pinned 0
	foreach line [split $text \n] {
		if {$title eq "" && [regexp {^# (.+)$} $line -> title]} continue
		if {[regexp {^pinned: (yes|no)$} $line -> flag]} {
			set pinned [expr {$flag eq "yes"}]
		}
		foreach tag [regexp -all -inline {#[\w-]+} $line] {
			lappend tags [string range $tag 1 end]
		}
	}
	return [dict create title $title tags [lsort -unique $tags] pinned $pinned]
}

proc ::notes::store::save {name text} {
	variable root
	set f [open [file join $root $name.md] w]
	fconfigure $f -encoding utf-8
	puts -nonewline $f $text
	close $f
}
}
set ui {# ui.tcl - a small library
namespace eval ::ui {
	variable W 1100
	variable H 720
}

proc ::ui::box {x y w h args} {
	variable cv
	$cv create rectangle $x $y [expr {$x + $w}] [expr {$y + $h}] -outline "" -fill #222222
}
}
set desk "\[Desktop Entry\]\nName=Notes\nExec=notes %F\nType=Application\nMimeType=text/markdown;\n"
set readme "# Notes\n\nA small notes app for the desk.\n\n- one file per note\n- tags with #hash\n"
set notes [file join $home src ribbon-notes]

# The file on disk as the board's change bars say it was: line 25 changed, lines 28 to 30 added in the buffer, and a line
# gone after line 34 (the buffer is $store; the disk copy differs from it in those places).
set disk {}
set n 0
foreach l [split $store \n] {
	incr n
	if {$n == 25} { set l "\tset pinned 1" }
	if {$n >= 28 && $n <= 30} continue
	lappend disk $l
	if {$n == 34} { lappend disk "\t# tags were split here" }
}
set disk [join $disk \n]
if {$scene eq "diagnostics"} {
	set bin [file join $dir bin]
	file mkdir $bin
	set fh [open [file join $bin nagelfar] w]
	# the board's lines 17 and 32 are, in the scene's text, the lines with "[parse $text]" and "string range"
	set ::wl [expr {[lsearch -regexp [split $store \n] {\[parse \$text\]}] + 1}]
	set ::el [expr {[lsearch -regexp [split $store \n] {string range}] + 1}]
	puts $fh "#!/bin/sh\necho 'Line $::wl: W Command \"parse\" is used before it is defined'\necho 'Line $::el: E Wrong number of arguments to string range'"
	close $fh
	file attributes [file join $bin nagelfar] -permissions 0755
	set ::env(PATH) "$bin:$::env(PATH)"
}
switch -- $scene {
	normal - diagnostics {
		set a [fixture store.tcl $disk $notes]
		fixture ui.tcl $ui $notes
		fixture notes.desktop $desk $notes
		fixture README.md $readme $notes
		editor::open_path $a
		editor::open_path [file join $notes ui.tcl]
		editor::open_path [file join $notes notes.desktop]
		editor::open_path [file join $notes README.md]
		editor::activate [lindex $::editor::docs 0]
		set w $::doc::D([lindex $::editor::docs 0],w)
		$w delete 1.0 end
		$w insert 1.0 $store
		# the text is replaced whole: the highlighter colours it from the top, as it does a file it opens
		highlight::install [lindex $::editor::docs 0]
		$w edit modified 1
		$w mark set insert 29.47
		$w see insert
		$w yview 8.0
		# the proc that saves is folded, as on the board (its line is found: the scene's text is not the board's)
		editor::paint
		gutter::fold [expr {[lsearch -regexp [split $store \n] {^proc ::notes::store::save}] + 1}]
		if {$scene eq "diagnostics"} {
			set did [lindex $::editor::docs 0]
			diag::run $did
			proc diag_ready {did w n} {
				if {![info exists ::diag::res($did)]} { after 50 [list diag_ready $did $w $n]; return }
				editor::set_focus 0
				editor::paint
				update idletasks
				foreach row [well::visible $w] {
					lassign $row ln y
					if {$ln == $::el} { diag::hover $::editor::gut 30 [expr {$y + 5}] }
				}
			}
			after 200 [list diag_ready $did $w 0]
		}
	}
	find - replace {
		set a [editor::open_path [fixture store.tcl $store $notes]]
		editor::activate $a
		set w $::doc::D($a,w)
		# the caret in the parse proc's body: the first "text" from there is current (4 of 6, as on the board)
		set ln [expr {[lsearch -regexp [split $store \n] {split \$text}] + 1}]
		$w mark set insert $ln.20
		editor::find_open 0 0
		ui::fset find.q text
		find::compute
		find::nearest
		find::goto
		find::mark
		if {$scene eq "find"} {
			find::toggle_menu
		} else {
			find::set_mode replace
			ui::fset find.r body
			find::replace_one
			set ::ui::focus find.r
			editor::schedule
		}
	}
	many {
		# the board's twelve documents, in its tab order; store.tcl (active) and ui.tcl are edited
		set rows [list \
			[list [file join $home Documents] todo.txt "todo\n"] \
			[list /etc/dinit.d kit-updater ""] \
			[list $notes store.tcl $store] \
			[list $notes ui.tcl $ui] \
			[list $notes notes.desktop $desk] \
			[list $notes README.md $readme] \
			[list [file join $home src ribbon-shell] main.tcl "set x 1\n"] \
			[list [file join $home src ribbon-shell] bar.tcl "set y 2\n"] \
			[list [file join $home .config labwc] rc.xml "<labwc/>\n"] \
			[list [file join $home .config mpv] config.toml "osd = yes\n"] \
			[list [file join $home .config foot] foot.ini "\[main\]\n"] \
			[list /etc fstab "# fs\n"]]
		set ids {}
		foreach row $rows {
			lassign $row folder name text
			if {[string match /etc* $folder]} {
				lappend ids [editor::open_path [file join $folder $name]]
			} else {
				lappend ids [editor::open_path [fixture $name $text $folder]]
			}
		}
		foreach id [lrange $ids 2 3] { $::doc::D($id,w) insert end "x" }
		editor::activate [lindex $ids 2]
		editor::toggle_pop
	}
	close {
		set ids {}
		lappend ids [editor::open_path [fixture store.tcl $store $notes]]
		lappend ids [editor::open_path [fixture ui.tcl $ui $notes]]
		lappend ids [editor::open_path [fixture notes.desktop $desk $notes]]
		# four new lines in store.tcl and three in ui.tcl, as the board's "4 lines changed" and "3 lines changed"
		$::doc::D([lindex $ids 0],w) insert 1.0 "a\nb\nc\nd\n"
		$::doc::D([lindex $ids 1],w) insert 1.0 "x\ny\nz\n"
		$::doc::D([lindex $ids 2],w) insert end " "
		editor::activate [lindex $ids 0]
		editor::close_docs [lrange $ids 0 1]
	}
	list {
		set ids {}
		foreach name {store.tcl ui.tcl notes.desktop README.md} body [list $store $ui $desk $readme] {
			lappend ids [editor::open_path [fixture $name $body $notes]]
		}
		editor::activate [lindex $ids 0]
		editor::toggle_pop
	}
	split {
		# Editor-Final-4-Split-B: the left pane (store.tcl, README.md) is focused, its caret on line 29; the right pane
		# (ui.tcl, notes.desktop, main.tcl) is the veiled one. Both start with all five documents.
		set ids {}
		foreach row [list [list $notes store.tcl $store] [list $notes README.md $readme] [list $notes ui.tcl $ui] \
			[list $notes notes.desktop $desk] [list [file join $home src ribbon-shell] main.tcl "set x 1\n"]] {
			lassign $row folder name text
			lappend ids [editor::open_path [fixture $name $text $folder]]
		}
		lassign $ids storeid readmeid uiid deskid mainid
		split::toggle
		split::focus_to 1
		editor::close_docs [list $storeid $readmeid]
		split::focus_to 0
		editor::close_docs [list $uiid $deskid $mainid]
		editor::activate $storeid
		$::doc::D($storeid,w) mark set insert 29.47
		$::doc::D($storeid,w) tag add sel 29.11 29.34
		split::focus_to 1
		editor::activate $uiid
		split::focus_to 0
	}
	welcome {
		# Editor-Final-6-Welcome-B: four pinned files and twelve recent ones, the newest first, with their times. The
		# fourth pin is under /etc and does not exist, so it shows muted.
		set now [clock seconds]
		set all {}
		foreach row [list [list [file join $home Documents] todo.txt "renew the passport\n"] \
			[list [file join $home .config labwc] rc.xml "<labwc/>\n"] [list $notes store.tcl $store] \
			[list $notes ui.tcl $ui] [list $notes notes.desktop $desk] [list $notes README.md $readme] \
			[list [file join $home src ribbon-shell] main.tcl "set x 1\n"] \
			[list [file join $home src ribbon-shell] bar.tcl "set y 2\n"] \
			[list [file join $home .config foot] foot.ini "\[main\]\n"] \
			[list [file join $home .config mpv] config.toml "osd = yes\n"] \
			[list [file join $home src ribbon-desktop bin] ribbon-theme "#!/bin/sh\n"] \
			[list $dir kit-updater "kit\n"]] {
			lassign $row folder name text
			lappend all [fixture $name $text $folder]
		}
		set times {300 4000 90000 200000 400000 500000 700000 900000 90000000 120000000 150000000 200000000}
		foreach f $all t $times { file mtime $f [expr {$now - $t}] }
		foreach f [lreverse [lrange $all 0 11]] { ::doc::recent_add $f }
		foreach f [list [lindex $all 0] [lindex $all 1] [lindex $all 2] /etc/fstab] { welcome::pin $f }
	}
	default { puts stderr "editor-scene: unknown RIBBON_SCENE $scene"; exit 2 }
}

after 300 [list editor::paint]
if {[info exists ::env(RIBBON_EDITOR_SHOT)]} {
	after 900 [list editor::shot_and_exit $::env(RIBBON_EDITOR_SHOT)]
} elseif {[info exists ::env(RIBBON_EDITOR_EXIT)]} {
	after $::env(RIBBON_EDITOR_EXIT) exit
}
proc editor::shot_and_exit {file} {
	update
	set id [winfo id $::editor::win]
	if {[catch {exec import -window $id $file} err]} { puts stderr "editor-scene: shot: $err"; exit 1 }
	puts "editor-scene: $file"
	exit 0
}
