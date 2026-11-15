# choices-flow.tcl - what the chooser does in tests/chooser/portal-choices.tcl (RIBBON_CHOOSER_TEST=this file; the
# flow's name in CHOOSER_FLOW_FILE): the app's choices changed or left as they came, then chosen.
set f [open $::env(CHOOSER_FLOW_FILE)]; set flow [read $f]; close $f
switch $flow {
	save-changed {
		# the list's second option and the checkbox off, then a name and Save
		if {[lmap c $page::choices { lindex $c 0 }] ne {enc ext}} { puts stderr "flow: choices [list $page::choices]"; page::cancel }
		set page::cval(enc) latin1
		page::choice_toggle ext
		ui::fset name letter.txt
		page::accept
	}
	open-defaults {
		page::go $::env(HOME)/Pictures/Iceland
		page::select [list Vík.jpg]
		page::accept
	}
	cancel { page::cancel }
}
