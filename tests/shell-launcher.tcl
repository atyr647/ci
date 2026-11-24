# shell-launcher.tcl - RIBBON_SHELL_TEST hook for the launcher's flows (tests/steps.d/46-shell-launcher.sh, on
# Xvfb): typing a query and the ranking of its results (name prefix, word, substring, generic name, letters in
# order; ties by use, then name; at most six), the .desktop rules (NoDisplay, Hidden, OnlyShowIn, Type, the data
# home before the data dirs), launching through the real apps::run (Exec's field codes dropped, Terminal=true in
# ribbon-terminal, the use count kept), Alt+Enter and the right-click menu for Properties, the modes (Tab, a path
# or an address switching by itself, the mode menu's clicks), Files mode (the index, Tab completion, a folder
# or a file opened in Ribbon Files, another folder app chosen in mimeapps.list), Web mode (an address, a search)
# and Escape. The step puts fixture .desktop files in XDG_DATA_HOME / XDG_DATA_DIRS and stand-ins on PATH that
# log the commands they were started with to LAUNCH_LOG.

set failed 0
interp bgerror {} {apply {{msg opts} { puts "  FAIL background error: [dict get $opts -errorinfo]"; exit 1 }}}
after 60000 {puts "  FAIL the launcher checks took more than 60 s"; exit 1}
proc ok {what} { puts "  ok   $what" }
proc bad {what why} { global failed; incr failed; puts "  FAIL $what: $why" }
proc check {what cond why} { if {$cond} { ok $what } else { bad $what $why } }

# wm::send would reach labwc: record it
set ::sent {}
proc wm::send {cmd args} { lappend ::sent [join [concat $cmd $args]] }

set LOG $::env(LAUNCH_LOG)
proc logged {} {
	if {[catch {open $::LOG} fh]} { return {} }
	set t [read $fh]; close $fh
	lmap l [split [string trimright $t \n] \n] { string trimright $l }
}
proc clearlog {} { close [open $::LOG w] }
# waits (the event loop runs) until the log has a line matching PATTERN, at most 10 s; returns the line or ""
proc waitlog {pattern} {
	set end [expr {[clock milliseconds] + 10000}]
	while {[clock milliseconds] < $end} {
		foreach l [logged] { if {[string match $pattern $l]} { return $l } }
		after 50 {set ::tick 1}; vwait ::tick
	}
	return ""
}
proc settle {ms} { after $ms {set ::tick 1}; vwait ::tick }
proc dict_get {d k} { expr {[dict exists $d $k] ? [dict get $d $k] : ""} }
# types STR into the launcher, key by key, as the keyboard does
proc type {str} {
	foreach ch [split $str ""] {
		set map [dict create " " space / slash ~ asciitilde . period : colon - minus]
		launcher::key [expr {[dict exists $map $ch] ? [dict get $map $ch] : $ch}] $ch 0
	}
}
proc names {} { lmap r $launcher::results { dict get [lindex $r 1] name } }
proc usage {id} { expr {[info exists apps::usage($id)] ? $apps::usage($id) : 0} }

after 300 {
	# ---- apps: the .desktop rules and the ranking
	apps::load
	set all [lmap a $apps::list { dict get $a name }]
	foreach n {{Stash NoDisplay} {Stash Hidden} {Stash KDE} {Stuff link}} {
		check "a .desktop entry that must not be listed is not: $n" [expr {$n ni $all}] "listed: $all"
	}
	check "an entry for this desktop (OnlyShowIn=Ribbon) is listed" [expr {"Mist" in $all}] "listed: $all"
	check "the data home's steam.desktop hides the data dirs' one" [expr {"Steam" in $all && "Old Steam" ni $all}] "listed: $all"

	launcher::start app
	check "the field opens for typing in Apps mode" [expr {$launcher::editing && $launcher::mode eq "app"}] "editing $launcher::editing mode $launcher::mode"
	type st
	set want {Strawberry {Star Citizen} Steam {Big Steam} Mist {Photo Tool}}
	check "typing st ranks the apps: name prefix (most used first, then by name), word, substring, generic name; six at most" \
		[expr {[names] eq $want}] "results {[names]}"
	check "the results are drawn under the field" [expr {[winfo exists .drop] && [winfo ismapped .drop] && [llength $launcher::drophits] == 6}] \
		"drop [winfo exists .drop] hits [llength $launcher::drophits]"
	type e
	check "typing more ranks again (ste: prefix, word, then letters in order, most used first)" \
		[expr {[names] eq {Steam {Big Steam} Strawberry {Sound Tuner} {Star Citizen}}}] "results {[names]}"
	launcher::key BackSpace {} 0
	check "BackSpace takes the letter back (st again)" [expr {[names] eq $want}] "results {[names]}"
	launcher::key BackSpace {} 4
	check "Ctrl+BackSpace clears the word" [expr {$launcher::query eq "" && [names] eq {}}] "query '$launcher::query'"
	type stu
	check "letters in order find an app (stu: Sound Tuner)" [expr {[names] eq {{Sound Tuner}}}] "results {[names]}"
	launcher::key u u 4
	check "Ctrl+U clears the field" [expr {$launcher::query eq ""}] "query '$launcher::query'"

	# ---- launching: Down, Enter; Exec's field codes are dropped; the use count goes up and is kept
	type st
	launcher::key Down {} 0
	check "Down selects the second result" [expr {$launcher::sel == 1}] "sel $launcher::sel"
	clearlog
	set before [usage rsi]
	launcher::key Return {} 0
	set l [waitlog "rsi-launcher*"]
	check "Enter launches the selected app through its Exec, field codes dropped (rsi-launcher --run)" [expr {$l eq "rsi-launcher --run"}] "log {[logged]}"
	check "the field closes after a launch" [expr {!$launcher::editing && $launcher::query eq "" && ![winfo ismapped .drop]}] "editing $launcher::editing"
	check "the launch is counted" [expr {[usage rsi] == $before + 1}] "rsi used [usage rsi], was $before"
	set fh [open [apps::usagefile]]; set saved [read $fh]; close $fh
	check "the count is kept in the state folder (launcher-usage)" [expr {[dict_get $saved rsi] == $before + 1}] "file: $saved"

	# a terminal program opens in Ribbon Terminal
	clearlog
	launcher::start app; type htop; launcher::key Return {} 0
	set l [waitlog "ribbon-terminal*"]
	check "Terminal=true runs the program in ribbon-terminal (ribbon-terminal -e htop)" [expr {$l eq "ribbon-terminal -e htop"}] "log {[logged]}"

	# a click on a result launches it
	clearlog
	launcher::start app; type st
	lassign [lindex $launcher::drophits 2] x0 y0 x1 y1
	launcher::drop_click [expr {$x0 + 20}] [expr {$y0 + 20}]
	set l [waitlog "steam*"]
	check "a click on the third result launches it (Steam: steam -silent)" [expr {$l eq "steam -silent"}] "log {[logged]}"

	# Alt+Enter: the app's Properties
	clearlog
	launcher::start app; type straw
	launcher::key Return {} 8
	set l [waitlog "ribbon-properties*"]
	check "Alt+Enter opens the app's Properties (ribbon-properties --app strawberry)" [expr {$l eq "ribbon-properties --app strawberry"}] "log {[logged]}"
	check "and closes the field" [expr {!$launcher::editing}] "editing $launcher::editing"
	# the right-click menu on a result: Open and Properties
	launcher::start app; type straw
	lassign [lindex $launcher::drophits 0] x0 y0 x1 y1
	set ::menuitems {}
	rename files::popup_menu _popup_menu
	proc files::popup_menu {w X Y items} { set ::menuitems $items }
	launcher::drop_menu [expr {$x0 + 20}] [expr {$y0 + 20}] 100 100
	rename files::popup_menu {}; rename _popup_menu files::popup_menu
	check "right-click on a result offers Open and Properties" [expr {[lmap i $::menuitems {lindex $i 1}] eq {Open Properties}}] "items {$::menuitems}"
	clearlog
	eval [lindex $::menuitems 0 2]
	set l [waitlog "strawberry*"]
	check "its Open launches the app" [expr {$l eq "strawberry"}] "log {[logged]}"

	# ---- modes
	launcher::start app
	launcher::key Tab {} 0
	check "Tab moves to Files mode" [expr {$launcher::mode eq "files"}] "mode $launcher::mode"
	launcher::key Tab {} 0
	check "Tab again moves to Web mode" [expr {$launcher::mode eq "web"}] "mode $launcher::mode"
	launcher::key Tab {} 0
	check "and back to Apps" [expr {$launcher::mode eq "app"}] "mode $launcher::mode"
	type /
	check "typing / in Apps mode switches to Files" [expr {$launcher::mode eq "files"}] "mode $launcher::mode"
	launcher::cancel
	launcher::start app; type example.org
	check "an address no app matches switches to Web (example.org)" [expr {$launcher::mode eq "web" && ![winfo ismapped .drop]}] "mode $launcher::mode"
	clearlog
	launcher::key Return {} 0
	set l [waitlog "xdg-open*"]
	check "Enter opens the address in the browser (https://example.org)" [expr {$l eq "xdg-open https://example.org"}] "log {[logged]}"
	clearlog
	launcher::start web; type "tcl tk/8"
	launcher::key Return {} 0
	set l [waitlog "xdg-open*"]
	check "words in Web mode are a search, encoded (tcl+tk%2F8)" [expr {$l eq "xdg-open https://duckduckgo.com/?q=tcl+tk%2F8"}] "log {[logged]}"

	# the mode menu: click the pill, then a mode
	launcher::cancel
	launcher::menu_toggle 1
	check "a click on the pill opens the mode menu" [expr {$launcher::menu && [winfo ismapped .menu] && [llength $launcher::menuhits] == 3}] "menu $launcher::menu"
	lassign [lindex $launcher::menuhits 1] x0 y0 x1 y1 key
	launcher::menu_click [expr {$x0 + 30}] [expr {$y0 + 20}]
	check "its second row starts Files mode" [expr {$key eq "files" && $launcher::mode eq "files" && $launcher::editing && !$launcher::menu && ![winfo ismapped .menu]}] \
		"key $key mode $launcher::mode editing $launcher::editing"
	launcher::cancel
	launcher::menu_toggle 1
	lassign [lindex $launcher::menuhits 2] x0 y0 x1 y1 key
	launcher::menu_click [expr {$x0 + 30}] [expr {$y0 + 20}]
	check "its third row starts Web mode" [expr {$launcher::mode eq "web" && $launcher::editing}] "mode $launcher::mode"
	launcher::key Escape {} 0
	launcher::menu_toggle 1
	launcher::key Escape {} 0
	check "Escape closes the mode menu" [expr {!$launcher::menu && ![winfo ismapped .menu]}] "menu $launcher::menu"

	# ---- Files mode: the index, Tab completion, opening
	launcher::start files
	type report
	set end [expr {[clock milliseconds] + 10000}]
	while {![llength $launcher::results] && [clock milliseconds] < $end} { settle 100 }
	set found [lmap r $launcher::results { lindex $r 1 1 }]
	check "Files mode finds a file under home by name, as the index fills (report)" \
		[expr {[file join $::env(HOME) Documents report-2026.txt] in $found}] "results {$found}"
	check "a hidden folder is not indexed" [expr {[lsearch -glob $found */.secret/*] < 0}] "results {$found}"
	set before [lsort [winfo children .]]
	launcher::key Return {} 0
	settle 200
	set new [lindex [lmap w [lsort [winfo children .]] { expr {$w ni $before ? $w : [continue]} }] 0]
	check "Enter on a file shows it in Ribbon Files, selected" \
		[expr {$new ne "" && [winfo class $new] eq "RibbonFiles" && [files::path $new] eq [file join $::env(HOME) Documents] && $files::st($new,sel) eq "report-2026.txt"}] \
		"window '$new' path '[expr {$new ne "" ? [files::path $new] : ""}]'"
	if {$new ne ""} { catch {files::close_window $new} }

	launcher::start files; type ~/Doc
	launcher::key Tab {} 0
	check "Tab completes a typed path (~/Doc → ~/Documents/)" [expr {$launcher::query eq "~/Documents/" && $launcher::mode eq "files"}] "query '$launcher::query'"
	set before [lsort [winfo children .]]
	launcher::key Return {} 0
	settle 200
	set new [lindex [lmap w [lsort [winfo children .]] { expr {$w ni $before ? $w : [continue]} }] 0]
	check "Enter on a typed folder opens it in Ribbon Files" \
		[expr {$new ne "" && [files::path $new] eq [file join $::env(HOME) Documents]}] "window '$new'"
	if {$new ne ""} { catch {files::close_window $new} }

	# another folder app chosen in Settings → Default apps: the folder goes to it through xdg-open
	file mkdir $::env(XDG_CONFIG_HOME)
	set fh [open [file join $::env(XDG_CONFIG_HOME) mimeapps.list] w]
	puts $fh "\[Default Applications\]\ninode/directory=org.other.Folders.desktop;"
	close $fh
	clearlog
	launcher::start files; type ~/Documents
	launcher::key Return {} 0
	set l [waitlog "xdg-open*"]
	check "with another folder app chosen, a typed folder goes to it (xdg-open)" [expr {$l eq "xdg-open [file join $::env(HOME) Documents]"}] "log {[logged]}"
	file delete [file join $::env(XDG_CONFIG_HOME) mimeapps.list]

	# Ctrl+L in Files: the address, in Files mode; Escape closes and hands the keyboard back
	launcher::address
	check "the address verb opens the field in Files mode" [expr {$launcher::editing && $launcher::mode eq "files"}] "mode $launcher::mode"
	set wm::focus 7
	set ::sent {}
	launcher::key Escape {} 0
	check "Escape closes the field and gives the keyboard back to the window in use" \
		[expr {!$launcher::editing && ![winfo ismapped .drop] && $::sent eq {{activate 7}}}] "editing $launcher::editing sent {$::sent}"
	set wm::focus ""

	exit [expr {$failed ? 1 : 0}]
}
