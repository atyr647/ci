# catalogue-footer.tcl - the app page's footer while another app installs (RIBBON_CATALOGUE_SCENE=this
# file, run by apps/catalogue/main.tcl under xvfb): cat::install runs one install at a time, so another
# app's page offers no Install that would do nothing; its own page shows the progress.
set ::env(RIBBON_SCENE) flathub
uplevel #0 [list source -encoding utf-8 [file join [file dirname [file normalize [info script]]] catalogue-scene.tcl]]
set fails 0
proc ok {name cond {detail ""}} {
	if {$cond} { puts "  ok   $name" } else { puts "  FAIL $name"; if {$detail ne ""} { puts "       $detail" }; incr ::fails }
}
proc ids {} { update; lmap f $ui::focusables { lindex $f 0 } }
after 300 {
	ok "a Flathub app's page offers Install" [expr {"install" in [ids]}] [ids]
	set cat::job [dict create source kit id org.example.obs fh "" phase download done 86000000 total 214000000 pct 40.0 said "" code ""]
	page::draw
	ok "while another app installs, its page has no Install that does nothing" [expr {"install" ni [ids]}] [ids]
	set cat::detail [dict merge $cat::detail [dict create id org.example.obs]]
	page::draw
	ok "... and the installing app's page shows the download, with Cancel" [expr {"cancel" in [ids]}] [ids]
	dict set cat::job phase asking
	page::draw
	ok "... while kit's prompt for it is up, its Install stays behind the sheet (Catalogue-4-Sheet)" [expr {"install" in [ids] && "cancel" ni [ids]}] [ids]
	set cat::job {}
	set cat::detail [discord]
	page::draw
	ok "once it has ended, Install is back" [expr {"install" in [ids]}] [ids]
	exit [expr {$fails ? 1 : 0}]
}
