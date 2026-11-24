# flow.tcl - what the chooser (appearance/chooser-main.tcl) is told to do in one of tests/steps.d/62-chooser.sh's
# runs through chooser::open_file / save_file / choose_folder (RIBBON_CHOOSER_TEST=this file, CHOOSER_FLOW=what).
proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }
after 30000 { puts stderr "flow: timeout"; exit 1 }
set H $::env(HOME)
proc click_name {name {state 0}} {
	set i [lsearch -exact -index 0 $page::items $name]
	set page::mods $state
	page::click_row $i
}
set flow [expr {[info exists ::env(CHOOSER_FLOW)] ? $::env(CHOOSER_FLOW) : ""}]
if {[info exists ::env(CHOOSER_FLOW_FILE)]} { set f [open $::env(CHOOSER_FLOW_FILE)]; set flow [read $f]; close $f }
switch $flow {
	open-one {
		# a portal caller's accept_label ("_Upload") is the primary button's word: else nothing is chosen
		if {$page::o(-acceptlabel) ne ""} {
			page::draw_now
			set b [lsearch -inline -index 0 $ui::focusables ok]
			if {[lindex $b 4] != [ui::button_w [string map {_ ""} $page::o(-acceptlabel)] primary]} { page::cancel }
		}
		page::go $H/Pictures/Iceland; click_name Jökulsárlón.jpg; page::key Return "" 0
	}
	open-double { page::go $H/Pictures/Iceland; page::double 500 [expr {94 + 40 * 4 + 19}] }
	open-many { page::go $H/Pictures/Iceland; click_name Vík.jpg; click_name Kirkjufell.jpg 4; page::accept }
	open-range { page::go $H/Pictures/Iceland; click_name Kirkjufell.jpg; click_name Seljalandsfoss.png 1; page::accept }
	cancel { page::cancel }
	wait { }
	escape { page::key Escape "" 0 }
	save-new { ui::fset name new.md; page::key Return "" 0 }
	save-ext { ui::fset name plan; page::accept }
	save-replace { ui::fset name Budget.md; page::accept; after 200 { page::replace 1 } }
	save-tilde { ui::fset name ~/Music/song-list.txt; page::accept }
	save-tildename { ui::fset name ~draft.txt; page::accept }
	save-as-is {
		# the name the app gave, as it is in the field (a ~name shown as itself, not ./~name)
		if {[string match ./* [ui::fval name]]} { puts stderr "flow: the field says [ui::fval name]"; page::cancel }
		page::accept
	}
	open-tilde {
		# a file whose name starts with ~ is listed and chosen as itself (not as a user's home folder)
		page::go $H/Downloads
		if {[lsearch -exact -index 0 $page::items ~old.txt] < 0} { puts stderr "flow: ~old.txt is not listed"; page::cancel }
		click_name ~old.txt; page::accept
	}
	open-type2 {
		# the second file type chosen in the list, then a file of that type: the type in use comes back too
		page::pick_type 1; page::go $H/Pictures/Iceland; click_name Seljalandsfoss.png; page::accept
	}
	folder-chosen { click_name Iceland; page::accept }
	folder-here { page::go $H/Pictures/Lisbon; page::accept }
	held {
		# the asking app's window is held: the client's grab is on while the chooser is open
		proc held_poll {n} {
			set g ""
			if {![catch {open $::env(CHOOSER_HELD)} f]} { set g [read $f]; close $f }
			if {$g ne ""} { page::cancel }
			if {$n <= 0} { puts stderr "flow: no grab"; exit 1 }
			after 100 [list held_poll [expr {$n - 1}]]
		}
		held_poll 100
	}
}
