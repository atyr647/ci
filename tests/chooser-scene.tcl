# chooser-scene.tcl - the Ribbon file chooser (appearance/chooser-main.tcl) in each Chooser-* board's state on the
# boards' folders (tests/chooser/fixture.sh), grabbed for tests/steps.d/62-chooser.sh to compare with the boards;
# and its clicks and keys. RIBBON_CHOOSER_TEST=this file, RIBBON_CHOOSER_SCENE=1, one run per -mode.
#   CHOOSER_SHOTS  = dir: open.png types.png (open), save.png replace.png (save), folder.png (folder)
#   CHOOSER_RESULT = file: the checks, one per line ("ok ..." or "FAIL ...")
proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }
namespace eval cs { variable fails 0; variable lines {} }
proc cs::check {what cond} {
	variable fails; variable lines
	if {[uplevel #0 [list expr $cond]]} { lappend lines "ok   $what" } else { lappend lines "FAIL $what"; incr fails }
}
proc cs::wait {ms} { set ::cs::w 0; after $ms {set ::cs::w 1}; vwait ::cs::w }
proc cs::shot {name} {
	page::draw_now; update
	if {![info exists ::env(CHOOSER_SHOTS)]} return
	cs::wait 300
	exec import -window [winfo id .w] [file join $::env(CHOOSER_SHOTS) $name.png]
}
proc cs::click {x y {state 0}} { page::draw_now; set page::mods $state; ui::press $x $y; ui::release $x $y; update }
proc cs::names {} { lmap e $page::items { lindex $e 0 } }
proc cs::finish {} {
	if {[info exists ::env(CHOOSER_RESULT)]} {
		set f [open $::env(CHOOSER_RESULT) w]; puts $f [join $cs::lines \n]; close $f
	} else { puts stderr [join $cs::lines \n] }
	exit [expr {$cs::fails > 0 ? 1 : 0}]
}
after 60000 { puts stderr "FAIL timeout"; exit 1 }
set ui::caretfix on
set H $::env(HOME)
# the rows' tops (window coordinates): 94, then every 40
proc cs::row_y {i} { expr {94 + 40 * $i + 19} }

switch $page::o(-mode) {
	open {
		cs::check "the sidebar: Home, Downloads, Pictures, Documents, Music (no Trash)" {[lmap p [page::places] { lindex $p 0 }] eq {Home Downloads Pictures Documents Music}}
		cs::check "the drives: System and Games" {[lmap d $page::drives { lindex $d 0 }] eq {System Games}}
		cs::check "the file types: Pictures, then All files added" {[lmap t $page::types { lindex $t 0 }] eq {Pictures {All files}}}
		# into Iceland (a double-click on its row), so Back has somewhere to go
		set i [lsearch -exact [cs::names] Iceland]
		page::double 500 [cs::row_y $i]
		update
		cs::check "a double-click on a folder opens it" {[file tail $page::dir] eq "Iceland" && [llength $page::back] == 1}
		cs::check "only pictures and folders are listed, folders first" {[cs::names] eq {Drone Panoramas {Höfn harbour.jpg} Jökulsárlón.jpg Kirkjufell.jpg Reynisfjara.jpg Seljalandsfoss.png Skógafoss.jpg Vík.jpg}}
		cs::click 500 [cs::row_y 3]
		cs::check "a click chooses a row" {$page::sel eq {Jökulsárlón.jpg}}
		# Chooser-Open
		cs::shot open
		cs::check "the kind, size and date columns" {[page::kind Jökulsárlón.jpg 0] eq "JPEG image" && [page::human 21600000] eq "21.6 MB" && [page::when [file mtime "$H/Pictures/Iceland/Jökulsárlón.jpg"]] eq "12 Oct"}
		# Chooser-Open-Types: the list open, the pointer on All files
		cs::click 300 540
		cs::check "a click on the file types opens their list" {$page::pop}
		set page::popidx 1
		cs::shot types
		page::key Return "" 0
		cs::check "  Return picks All files: the route is listed too" {!$page::pop && $page::type == 1 && "route.gpx" in [cs::names]}
		cs::click 300 540
		cs::click 300 460
		cs::check "  a click on Pictures in the list picks it back" {!$page::pop && $page::type == 0 && "route.gpx" ni [cs::names]}
		# keys: Down, type-ahead, Backspace up, Alt+Left/Right
		page::key Down "" 0
		cs::check "Down chooses the next row" {$page::sel eq {Kirkjufell.jpg}}
		page::key s s 0
		cs::check "typing a letter chooses the first name with it" {$page::sel eq {Seljalandsfoss.png}}
		page::key BackSpace "" 0
		cs::check "Backspace goes to the folder above, Iceland chosen" {[file tail $page::dir] eq "Pictures" && $page::sel eq {Iceland}}
		page::key Left "" 8
		cs::check "Alt+Left goes back" {[file tail $page::dir] eq "Iceland"}
		page::key Right "" 8
		cs::check "  and Alt+Right forward" {[file tail $page::dir] eq "Pictures"}
		cs::click 100 [expr {38 + 34 * 3 + 16}]
		cs::check "a place in the sidebar goes there (Documents)" {[file tail $page::dir] eq "Documents"}
		cs::click 100 [expr {256 + 39 + 10}]
		cs::check "a drive goes to its mount point (none here: nothing changes)" {[file tail $page::dir] eq "Documents"}
		cs::click 100 [expr {256 + 10}]
		cs::check "  System goes to /" {$page::dir eq "/"}
		cs::finish
	}
	save {
		cs::check "Save as starts in the folder asked for with the name in the field, the field focused" {[file tail $page::dir] eq "Documents" && [ui::fval name] eq "trip-notes.md" && $ui::focus eq "name"}
		cs::check "every file is listed when no type is asked for" {[cs::names] eq {Letters Recipes Work Budget.md {Packing list.txt} Reading.md {Taxes 2025.pdf}}}
		cs::shot save
		# typing a name that is taken chooses its row; Save asks before replacing it
		ui::fset name ""
		foreach ch [split Budget.md ""] { page::key $ch $ch 0 }
		cs::check "typing a name that is there chooses its row" {[ui::fval name] eq "Budget.md" && $page::sel eq {Budget.md}}
		page::key Return "" 0
		cs::check "Return on a taken name asks first" {$page::ask eq [file join $H Documents Budget.md]}
		cs::shot replace
		cs::click 400 300
		cs::check "  a click outside the question does nothing" {$page::ask ne ""}
		page::key Escape "" 0
		cs::check "  Escape (Cancel) leaves it, the name kept and focused" {$page::ask eq "" && [ui::fval name] eq "Budget.md" && $ui::focus eq "name"}
		cs::click 400 [expr {94 + 40 * 5 + 19}]
		cs::check "a click on a file puts its name in the field" {[ui::fval name] eq "Reading.md"}
		ui::fset name Work
		page::key Return "" 0
		cs::check "a folder's name and Return go into it" {[file tail $page::dir] eq "Work" && [ui::fval name] eq ""}
		cs::finish
	}
	folder {
		cs::check "only folders are listed" {[cs::names] eq {Family Iceland Lisbon Scans Screenshots Wallpapers}}
		cs::click 500 [cs::row_y 1]
		cs::check "a click chooses Iceland" {$page::sel eq {Iceland}}
		cs::shot folder
		cs::finish
	}
}
