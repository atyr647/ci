# chooser-w3-scene.tcl - the Ribbon file chooser's New folder (board Chooser-New-Folder) and the app's choices (board
# Chooser-Save-Choices), for tests/steps.d/62-chooser-w3.sh. RIBBON_CHOOSER_TEST=this file, RIBBON_CHOOSER_SCENE=1,
# on the boards' folders (tests/chooser/fixture.sh).
#   CHOOSER_W3     = newfolder (-mode save in ~/Documents) | choices (-mode save with -choices; it ends by choosing,
#                    so the answer is on stdout)
#   CHOOSER_SHOTS  = dir: new-folder.png or choices.png
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
proc cs::click {x y {state 0}} { page::draw_now; update; set page::mods $state; page::press_commit $x $y; ui::press $x $y; ui::release $x $y; update }
proc cs::key {sym {char ""} {state 0}} { page::key $sym $char $state; page::draw_now; update }
proc cs::names {} { lmap e $page::items { lindex $e 0 } }
proc cs::hit_of {pattern} {
	foreach h $ui::hits { if {[string match $pattern [lindex $h 4]]} { return [lrange $h 0 3] } }
	return {}
}
proc cs::finish {{code ""}} {
	if {[info exists ::env(CHOOSER_RESULT)]} {
		set f [open $::env(CHOOSER_RESULT) w]; puts $f [join $cs::lines \n]; close $f
	} else { puts stderr [join $cs::lines \n] }
	if {$code ne ""} return
	exit [expr {$cs::fails > 0 ? 1 : 0}]
}
after 60000 { puts stderr "FAIL timeout"; exit 1 }
set ui::caretfix on
set H $::env(HOME)
set D $H/Documents
proc cs::row_y {name} { expr {94 + 40 * [lsearch -exact [cs::names] $name] + 19} }

switch $::env(CHOOSER_W3) {
	newfolder {
		page::draw_now
		cs::check "Save as: the New folder button at the toolbar's right end (842, 8, 30 x 30)" {[cs::hit_of *page::new_folder*] eq {842 8 872 38}}
		set page::o(-mode) open; page::draw_now
		cs::check "Open has no New folder button" {[cs::hit_of *page::new_folder*] eq {}}
		set page::o(-mode) folder; page::draw_now
		cs::check "Choose a folder has it" {[cs::hit_of *page::new_folder*] ne {}}
		set page::o(-mode) save; page::draw_now
		cs::click 857 23
		cs::check "a press on it makes \"New folder\" in the folder shown" {[file isdirectory $D/New\ folder]}
		cs::check "the new folder is chosen, listed with the folders, its name in the field with the keys" \
			{$page::sel eq {{New folder}} && $page::renaming eq "New folder" && $ui::focus eq "rename" && [lsearch -exact [cs::names] {New folder}] == 1}
		# the board's state: the folder's row, the name field focused, the Name field keeping trip-notes.md
		file mtime $D/New\ folder [clock scan "2026-11-15 10:00"]
		page::read_dir
		cs::shot new-folder
		cs::check "the field is the board's: 240 x 32 at the name's place in its row (240, 137)" {$page::rbox eq {240 137 240 32}}
		ui::fset rename Trips
		cs::key Return
		cs::check "Return renames it to what was typed; the keys go back to the Name field" \
			{[file isdirectory $D/Trips] && ![file exists $D/New\ folder] && $page::renaming eq "" && $ui::focus eq "name" && $page::sel eq {Trips}}
		cs::check "  the Name field still holds the file's name" {[ui::fval name] eq "trip-notes.md"}
		cs::key N N 5
		cs::check "Ctrl Shift N makes another (the name is free again: \"New folder\")" {[file isdirectory $D/New\ folder] && $page::renaming eq "New folder"}
		ui::fset rename Changed
		cs::key Escape
		cs::check "Escape keeps the name it was made with and leaves the chooser open" {[file isdirectory $D/New\ folder] && ![file exists $D/Changed] && $page::renaming eq ""}
		cs::click 857 23
		cs::check "a taken name gets a number: \"New folder 2\"" {[file isdirectory $D/New\ folder\ 2] && $page::renaming eq "New folder 2"}
		ui::fset rename Work
		cs::key Return
		cs::check "a name that is taken keeps the folder's own" {[file isdirectory $D/New\ folder\ 2] && [file isdirectory $D/Work]}
		cs::click 857 23
		ui::fset rename a/b
		cs::key Return
		cs::check "a name with a / keeps the folder's own" {[file isdirectory $D/New\ folder\ 3] && ![file exists $D/a]}
		cs::click 857 23
		ui::fset rename Pressed
		cs::click 600 [cs::row_y Letters]
		cs::check "a press elsewhere keeps the name typed (and the row pressed is chosen)" {[file isdirectory $D/Pressed] && $page::renaming eq "" && $page::sel eq {Letters}}
		# leaving the folder while naming ends the naming there (the name typed is kept); the folder of that name in
		# the folder gone to is not touched
		page::go $D/Letters
		cs::key N N 5
		ui::fset rename Moved
		cs::key Up "" 8
		cs::check "Alt Up while naming renames the new folder, not the one of its name in the folder above" \
			{$page::dir eq $D && [file isdirectory $D/New\ folder] && ![file exists $D/Moved] && [file isdirectory $D/Letters/Moved] && $page::renaming eq ""}
		set page::o(-mode) open; page::draw_now
		cs::key N N 5
		cs::check "Open makes no folder on Ctrl Shift N" {$page::renaming eq "" && ![file exists $D/New\ folder\ 4]}
		page::args [list -mode save -choices {{bad x} {other O {{a A} {b B}} zzz} {flag F {} maybe}}]
		cs::check "choices: one of the wrong shape is left out, a default not among the options is the first, a checkbox not \"true\" is off" \
			{[lmap c $page::choices { lindex $c 0 }] eq {other flag} && $page::cval(other) eq "a" && $page::cval(flag) eq "false"}
		cs::finish
	}
	choices {
		page::draw_now
		cs::check "the choices: Encoding (a list, UTF-8) and the extension (a checkbox, on)" \
			{[lmap c $page::choices { lindex $c 0 }] eq {enc ext} && $page::cval(enc) eq "utf8" && $page::cval(ext) eq "true"}
		cs::check "the strip is one 52 line under the list; the list shows 8 rows, not 10" {[page::strip_h] == 52 && [page::rows_shown] == 8}
		cs::shot choices
		# the checkbox: its box and label
		lassign [lsearch -inline -index 0 [lrange [page::choice_layout] 0 end-1] ext] - - ex eline
		set ey [expr {580 - 72 - [page::strip_h] + 52 * $eline + 26}]
		cs::click [expr {$ex + 40}] $ey
		cs::check "a press on the checkbox's label turns it off" {$page::cval(ext) eq "false"}
		cs::click [expr {$ex + 9}] $ey
		cs::check "  and on again" {$page::cval(ext) eq "true"}
		lassign [lsearch -inline -index 0 [lrange [page::choice_layout] 0 end-1] enc] - - lx lline
		set dx [expr {$lx + [ui::measure i13 Encoding] + 12 + 90}]
		set dy [expr {580 - 72 - [page::strip_h] + 52 * $lline + 26}]
		cs::click $dx $dy
		cs::check "a press on the list's dropdown opens its options" {$page::cpop eq "enc"}
		set top [expr {580 - 72 - [page::strip_h] + 52 * $lline + 10 - 6 - (12 + 36 * 2)}]
		cs::click $dx [expr {$top + 6 + 36 + 18}]
		cs::check "a press on an option takes it and closes the list" {$page::cval(enc) eq "latin1" && $page::cpop eq ""}
		cs::click $ex $ey
		cs::check "the checkbox again: off" {$page::cval(ext) eq "false"}
		# Tab to the dropdown, Down opens it, Up and Return take UTF-8 back
		set ui::focus choice-enc
		cs::key Down
		cs::key Up
		cs::key Return
		cs::check "the keys: the list opens on Down, Up and Return take the option" {$page::cval(enc) eq "utf8" && $page::cpop eq ""}
		set ui::focus choice-enc
		cs::key Down
		cs::key Down
		cs::key Return
		ui::fset name "Council letter.odt"
		set ui::focus name
		cs::finish keep
		cs::key Return
	}
}
