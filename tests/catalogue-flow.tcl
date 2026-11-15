# catalogue-flow.tcl - drives the real Catalogue window (RIBBON_CATALOGUE_PROBE, run by
# apps/catalogue/main.tcl) against tests/catalogue-kit.tcl's repository: the list from kit's index,
# a search, a row clicked, the kit's page, Install, kit's prompt as a sheet answered with its
# button, the download in the footer, Installed with Open, back to the list. One line per check
# in CATALOGUE_FLOW_OUT: "ok NAME" or "FAIL NAME DETAIL".
set out [open $::env(CATALOGUE_FLOW_OUT) w]
proc check {name cond {detail ""}} { puts $::out [list [expr {$cond ? "ok" : "FAIL"}] $name $detail]; flush $::out }
proc wait {cond {ms 60000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 [list expr $cond]] && [clock milliseconds] < $end} { after 50 { set ::tick 1 }; vwait ::tick }
	uplevel #0 [list expr $cond]
}
# a real click in the middle of what Tab reaches as ID
proc click {id} {
	update
	set f [lsearch -inline -index 0 $ui::focusables $id]
	if {$f eq ""} { return 0 }
	lassign $f - - x y w h
	set x [expr {int($x + $w / 2 + $ui::ox)}]; set y [expr {int($y + $h / 2 + $ui::oy)}]
	event generate $ui::cv <ButtonPress-1> -x $x -y $y
	event generate $ui::cv <ButtonRelease-1> -x $x -y $y
	update
	return 1
}
# what the last draw wrote, string by string (text.tcl splits a string into kerned runs)
rename ui::text ui::text_
proc ui::text {args} { lappend ::strs [lindex $args 2]; ui::text_ {*}$args }
rename ui::begin ui::begin_
proc ui::begin {args} { set ::strs {}; ui::begin_ {*}$args }
set strs {}
proc texts {} { update; return $::strs }
proc drawn {s} { expr {[lsearch -exact [texts] $s] >= 0} }
proc run {} {
	check "kit's index loads into the list" [wait {$cat::kitstate eq "ready"}] "$cat::kitstate $cat::kitwhy"
	check "... its apps, not its libraries, under Ribbon kits" [wait {[drawn Obs] && [drawn Hello] && [drawn {RIBBON KITS}] && ![drawn Libgreet]} 5000] [texts]
	check "... counted" [drawn {2 kits}] [texts]
	# typing searches
	focus $ui::cv
	foreach ch {h e l} { page::key $ch $ch 0 }
	check "typing searches: only what matches" [wait {[drawn Hello] && ![drawn Obs]} 5000] [texts]
	page::key Escape "" 0
	check "Escape clears the search" [wait {[drawn Obs]} 5000] [texts]
	set i [lsearch -index 1 [lmap it $page::items { if {[lindex $it 0] ne "row"} continue; list x [dict get [lindex $it 1] short] }] obs]
	check "a row opens its app's page" [click row$i]
	check "... with kit info's facts: its signature and requests" [wait {$page::view eq "app" && [dict get $cat::detail state] eq "ready"} 30000] $cat::detail
	check "... who signed it, by the trusted key list's name" [wait {[dict get $cat::detail signer name] ne "" && ![string match "*\t*" [dict get $cat::detail signer name]] && [drawn [dict get $cat::detail signer name]]} 5000] [dict get $cat::detail signer]
	check "... drawn: the strip, Install, the requests" [wait {[drawn {Not installed}] && [drawn Install] && [drawn Camera] && [drawn Valid]} 5000] [texts]
	check "Install asks with kit's prompt" [click install]
	check "... as the sheet, kit's question on its button" [wait {$page::dialog ne "" && [dict get $page::dialog kind] eq "plan"} 30000] [texts]
	check "... word for word" [drawn Install?] [texts]
	check "... and its rows: the app by name, the library by kit's" [expr {[drawn Obs] && [drawn libgreet]}] [lmap r [dict get $page::dialog rows] { dict get $r name }]
	set seen 0
	trace add variable ::cat::job write {apply {{a b c} { if {[dict size $::cat::job] && [dict get $::cat::job phase] in {download install}} { set ::seen 1 } }}}
	check "its button answers yes" [click pyes]
	check "the footer shows the download" [wait {$::seen} 30000]
	check "it installs" [wait {[dict get $cat::detail installed] eq "31.0.1"} 60000] $cat::detail
	check "... and the page says Installed, with Open" [wait {[drawn Installed] && [lsearch -index 0 $ui::focusables open] >= 0} 10000] [texts]
	check "... and nothing went wrong" [expr {$page::dialog eq ""}] $page::dialog
	check "back to the list" [click back]
	check "... where it is Installed" [wait {$page::view eq "list" && [drawn Installed]} 10000] [texts]
	page::go installed
	check "Installed lists it, by its launcher entry's name" [wait {[drawn {OBS Studio}] && ![drawn Hello]} 10000] [texts]
	check "the window's flow ended" 1
	close $::out
	exit 0
}
after 300 run
