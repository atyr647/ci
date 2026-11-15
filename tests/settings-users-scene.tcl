# settings-users-scene.tcl - Settings → Users (page-users.tcl) in its boards' states: Settings-A9-Users (RIBBON_SCENE
# main), and the sheets -A9b-Users-Add (add), -A9c-Users-Password (password), -A9d-Users-Remove (remove), with
# users.tcl's model and changes stood in for (the page's drawing, its clicks and its typing are what is checked here;
# users.tcl itself is tests/settings-users.tcl, the helper tests/settings-users-helper.tcl). The sheets are filled in
# by typing, key by key, as a person would. RIBBON_SCENE real stands in for nothing in users.tcl: the page's clicks
# and typing go through the real users.tcl to a stand-in pkexec and passwd (RIBBON_USERS_PKEXEC, RIBBON_USERS_PASSWD,
# which record their arguments, environment and standard input under RIBBON_USERS_LOG) over a fixture root.
# Sourced by apps/settings/main.tcl through RIBBON_SETTINGS_SCENE.
#   RIBBON_USERS_SHOT   = file: a grab of the window (ImageMagick import)
#   RIBBON_USERS_RESULT = file: the checks, one per line ("ok ..." or "FAIL ...")
proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }
namespace eval uscene { variable fails 0; variable lines {}; variable calls {}; variable next ok; variable msg "" }
proc uscene::check {what cond} { variable fails; variable lines; if {[uplevel #0 [list expr $cond]]} { lappend lines "ok   $what" } else { lappend lines "FAIL $what"; incr fails } }
proc uscene::settle {} { update; page::draw_now; update }
proc uscene::click {x y} { page::draw_now; ui::press [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; ui::release [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; settle }
proc uscene::key {sym {char ""}} { settings::key $sym $char 0; settle }
proc uscene::type {text} { foreach ch [split $text ""] { settings::key [expr {$ch eq " " ? "space" : $ch}] $ch 0 }; settle }
proc uscene::last {} { lindex $::uscene::calls end }
# every text the canvas holds (a password must be in none of them)
proc uscene::texts {} {
	set out {}
	foreach i [$::ui::cv find all] { if {[$::ui::cv type $i] eq "text"} { lappend out [$::ui::cv itemcget $i -text] } }
	return $out
}
proc uscene::user {login uid name admin you nopass} { dict create login $login uid $uid name $name full $name admin $admin you $you nopass $nopass }
proc uscene::model {users {wheel 1} {nopass 1}} {
	set ::users::M [dict create users $users wheel $wheel nopass $nopass me adam]
	set ::users::taken [dict create root 1 wheel 1]
	foreach u $users { dict set ::users::taken [dict get $u login] 1 }
}
proc uscene::board {} {
	model [list [user adam 1000 Adam 1 1 0] [user mira 1001 Mira 0 0 0] [user guest 1002 Guest 0 0 0]]
}
proc uscene::edit {login key value} {
	set l {}
	foreach u [dict get $::users::M users] { if {[dict get $u login] eq $login} { dict set u $key $value }; lappend l $u }
	dict set ::users::M users $l
}
# a change ends as uscene::next says: ok (the model changes as the real files would), failed (with uscene::msg) or cancelled
proc uscene::end {done what apply} {
	variable calls; variable next; variable msg
	lappend calls $what
	set ::users::error [expr {$next eq "failed" ? $msg : ""}]
	if {$next eq "ok"} { uplevel #0 $apply }
	if {$done ne ""} { uplevel #0 [list {*}$done $next [expr {$next eq "failed" ? $msg : ""}]] }
	users::changed
}
set scene [expr {[info exists ::env(RIBBON_SCENE)] ? $::env(RIBBON_SCENE) : "main"}]
if {$scene ne "real"} {
proc users::start {} {}
proc users::refresh {} { return 0 }
proc users::add {login full admin password {done ""}} {
	uscene::end $done [list add $login $full $admin $password] [list apply {{l f a} {
		dict lappend ::users::M users [uscene::user $l 1003 [expr {$f ne "" ? $f : $l}] $a 0 0]; dict set ::users::taken $l 1
	}} $login $full $admin]
}
proc users::remove {login keep {done ""}} {
	uscene::end $done [list remove $login $keep] [list apply {{l} {
		dict set ::users::M users [lmap u [dict get $::users::M users] { if {[dict get $u login] eq $l} continue; set u }]
	}} $login]
}
proc users::rename {login full {done ""}} { uscene::end $done [list rename $login $full] [list uscene::edit $login name $full] }
proc users::set_admin {login on {done ""}} { uscene::end $done [list admin $login $on] [list uscene::edit $login admin $on] }
proc users::set_nopass {login on {done ""}} { uscene::end $done [list nopass $login $on] [list uscene::edit $login nopass $on] }
proc users::set_password {login new current {done ""}} { uscene::end $done [list password $login $new $current] {} }
}
# real: wait (with a deadline) for the change that is running to end
proc uscene::idle {} {
	set end [expr {[clock milliseconds] + 15000}]
	while {$::users::busy && [clock milliseconds] < $end} { update; after 10 }
	settle
}
proc uscene::log {name} { set f [open [file join $::env(RIBBON_USERS_LOG) $name] rb]; set t [encoding convertfrom utf-8 [read $f]]; close $f; return $t }
proc uscene::lastargv {} { lindex [split [string trimright [log argv] \n] \n] end }
proc uscene::clearlog {} { foreach n {argv stdin env passwd.argv passwd.stdin} { close [open [file join $::env(RIBBON_USERS_LOG) $n] w] } }

set ui::caretfix [expr {$scene eq "main" ? "off" : "on"}]
set ui::caret [expr {$scene ne "main"}]
if {$scene ne "real"} { uscene::board }
set users::error ""
settings::select users
uscene::settle

set PW1 "Kestrel-41"       ;# ten characters, as the board's ten dots
set PW2 "Lantern-Quay"     ;# twelve
set CUR "old-pass9"        ;# nine
switch -- $scene {
	add {
		uscene::click 330 684
		uscene::type "Jonas Lindqvist"
		uscene::key Tab; uscene::key Tab
		uscene::type $PW1
		uscene::key Tab
		uscene::type $PW1
	}
	password {
		uscene::click 1010 281
		uscene::type $CUR
		uscene::key Tab
		uscene::type $PW2
		uscene::key Tab
		uscene::type $PW2
	}
	remove {
		uscene::click 400 219
		uscene::click 1000 684
	}
}
if {[info exists ::env(RIBBON_USERS_SHOT)]} { after 500; update; exec import -window [winfo id $::settings::win] $::env(RIBBON_USERS_SHOT) }

switch -- $scene {
	add {
		uscene::check "Add user opens the Add sheet over the shaded page" {$sctl::sheet eq "add" && $page::shade == 0.5}
		uscene::check "the user name follows the full name as it is typed (Jonas Lindqvist: jonas)" {[ui::fval us-login] eq "jonas" && [ui::fval us-full] eq "Jonas Lindqvist"}
		uscene::check "Tab went through the fields: the caret is in Confirm password" {$ui::focus eq "us-pw2" && [ui::fval us-pw1] eq $PW1 && [ui::fval us-pw2] eq $PW1}
		uscene::check "a password is drawn as dots: no text on the canvas holds it" {[lsearch -glob [uscene::texts] "*$PW1*"] < 0 && [lsearch -glob [uscene::texts] "*Kestrel*"] < 0}
		uscene::click 400 219
		uscene::check "under the sheet the list takes no clicks" {$usp::sel ne "mira" && $sctl::sheet eq "add"}
		uscene::key Tab
		uscene::check "  and Tab stays in the sheet" {[string match us-sheet-* $ui::focus]}
		uscene::click 763 485
		uscene::check "the sheet's Administrator switch turns on" {$usp::admin == 1 && $uscene::calls eq {}}
		# a name that is taken, then one that is not a user name: nothing is sent, the caret goes to the name
		ui::fset us-login mira; uscene::click 740 554
		uscene::check "Add with a user name that is taken sends nothing; the caret is in Username" {$uscene::calls eq {} && $ui::focus eq "us-login" && $sctl::sheet eq "add"}
		ui::fset us-login "Jonas L"; uscene::click 740 554
		uscene::check "  nor with one that is not a user name" {$uscene::calls eq {} && $ui::focus eq "us-login"}
		ui::fset us-login wheel; uscene::click 740 554
		uscene::check "  nor with a group's name" {$uscene::calls eq {} && $ui::focus eq "us-login"}
		ui::fset us-login jonas
		ui::fset us-pw2 "Kestrel-42"; uscene::click 740 554
		uscene::check "  nor with two passwords that differ: the caret is in Confirm password" {$uscene::calls eq {} && $ui::focus eq "us-pw2"}
		ui::fset us-pw2 ""; ui::fset us-pw1 ""; uscene::click 740 554
		uscene::check "  nor with no password: the caret is in Password" {$uscene::calls eq {} && $ui::focus eq "us-pw1"}
		# the prompt is dismissed: the sheet stays, the passwords are gone
		ui::fset us-pw1 $PW1; ui::fset us-pw2 $PW1
		set uscene::next cancelled; uscene::click 740 554
		uscene::check "Add calls users::add LOGIN FULLNAME ADMIN PASSWORD" {[uscene::last] eq [list add jonas {Jonas Lindqvist} 1 $PW1]}
		uscene::check "  a dismissed prompt leaves the sheet open, with its names" {$sctl::sheet eq "add" && [ui::fval us-login] eq "jonas" && $usp::said eq ""}
		uscene::check "  and the password fields empty (nothing typed is kept after it was handed over)" {[ui::fval us-pw1] eq "" && [ui::fval us-pw2] eq "" && [lsearch -glob [array get ::ui::fld] "*$PW1*"] < 0}
		# a failure says why in the sheet
		ui::fset us-pw1 $PW1; ui::fset us-pw2 $PW1
		set uscene::next failed; set uscene::msg "The password was not accepted; no user was added"; uscene::click 740 554
		uscene::check "a change that failed keeps the sheet and says why in it" {$sctl::sheet eq "add" && $usp::said eq $uscene::msg && [ui::fval us-pw1] eq ""}
		# Return in the last field sends it
		set uscene::next ok; set uscene::calls {}
		uscene::click 600 369; uscene::type $PW1; uscene::key Tab; uscene::type $PW1; uscene::key Return
		uscene::check "Return in a field sends the form; made, the sheet closes and the new user is the chosen one" {[uscene::last] eq [list add jonas {Jonas Lindqvist} 1 $PW1] && $sctl::sheet eq "" && $page::shade == 0 && [dict get [usp::chosen] login] eq "jonas"}
		uscene::check "  the list has four users" {[llength [usp::users]] == 4}
		# Cancel and Escape
		uscene::click 330 684; uscene::type "Pat"; uscene::key Tab; uscene::key Tab; uscene::type $PW1
		set n [llength $uscene::calls]
		uscene::click 618 554
		uscene::check "Cancel closes the sheet, sends nothing and forgets what was typed" {$sctl::sheet eq "" && [llength $uscene::calls] == $n && [ui::fval us-pw1] eq ""}
		uscene::click 330 684
		uscene::check "  the sheet opens empty the next time" {$sctl::sheet eq "add" && [ui::fval us-full] eq "" && [ui::fval us-login] eq "" && $usp::admin == 0}
		uscene::type "Pat"; uscene::key Tab; uscene::type "p"
		uscene::click 600 253; uscene::type "ty"
		uscene::check "a user name that was typed no longer follows the full name" {[ui::fval us-login] eq "patp" && [ui::fval us-full] eq "Patty"}
		uscene::key Tab; uscene::key Tab; uscene::type $PW1
		uscene::key Escape
		uscene::check "Escape closes it too, and the password is forgotten" {$sctl::sheet eq "" && [ui::fval us-pw1] eq "" && [llength $uscene::calls] == $n}
		# no wheel group: no Administrator row in the sheet (four rows)
		uscene::model [dict get $users::M users] 0
		uscene::click 330 684
		uscene::check "without a wheel group the Add sheet has no Administrator switch" {[usp::rows add] eq {full login pw1 pw2}}
		uscene::key Escape
	}
	password {
		uscene::check "Change… opens your password sheet with Current password first" {$sctl::sheet eq "password" && [usp::rows password] eq {cur pw1 pw2} && $usp::target eq "adam"}
		uscene::check "the three fields hold what was typed, the caret in the last" {[ui::fval us-cur] eq $CUR && [ui::fval us-pw1] eq $PW2 && [ui::fval us-pw2] eq $PW2 && $ui::focus eq "us-pw2"}
		uscene::check "no text on the canvas holds a password" {[lsearch -glob [uscene::texts] "*$PW2*"] < 0 && [lsearch -glob [uscene::texts] "*$CUR*"] < 0}
		ui::fset us-pw2 "Lantern-Quax"; uscene::click 720 496
		uscene::check "Change with two new passwords that differ sends nothing" {$uscene::calls eq {} && $ui::focus eq "us-pw2"}
		ui::fset us-pw2 $PW2; ui::fset us-cur ""; uscene::click 720 496
		uscene::check "  nor without the current password" {$uscene::calls eq {} && $ui::focus eq "us-cur"}
		ui::fset us-cur $CUR
		set uscene::next failed; set uscene::msg "The current password is not right"; uscene::click 720 496
		uscene::check "Change calls users::set_password LOGIN NEW CURRENT" {[uscene::last] eq [list password adam $PW2 $CUR]}
		uscene::check "  a wrong current password: the sheet stays and says so, the fields are empty, the caret in the first" {$sctl::sheet eq "password" && $usp::said eq $uscene::msg && [ui::fval us-cur] eq "" && [ui::fval us-pw1] eq "" && [ui::fval us-pw2] eq "" && $ui::focus eq "us-cur"}
		uscene::check "  no variable of the page or the fields holds a password any more" {[lsearch -glob [array get ::ui::fld] "*$PW2*"] < 0 && [lsearch -glob [array get ::ui::fld] "*$CUR*"] < 0 && [lsearch -glob [lmap v [info vars ::usp::*] { expr {[array exists $v] ? "" : [set $v]} }] "*Lantern*"] < 0}
		set uscene::next ok
		uscene::type $CUR; uscene::key Tab; uscene::type $PW2; uscene::key Tab; uscene::type $PW2; uscene::key Return
		uscene::check "typed again and Return: changed, the sheet closes" {[uscene::last] eq [list password adam $PW2 $CUR] && $sctl::sheet eq "" && $page::shade == 0}
		# someone else's password: no Current password row
		uscene::click 400 219
		uscene::click 1010 281
		uscene::check "another user's sheet has no Current password" {$sctl::sheet eq "password" && $usp::target eq "mira" && [usp::rows password] eq {pw1 pw2} && $ui::focus eq "us-pw1"}
		uscene::type $PW1; uscene::key Tab; uscene::type $PW1
		# two rows: the sheet is 286 tall from 217, its buttons at 448
		uscene::click 720 467
		uscene::check "  Change sends the new password and no current one" {[uscene::last] eq [list password mira $PW1 {}] && $sctl::sheet eq ""}
		uscene::click 1010 281
		uscene::click 600 467
		uscene::check "  Cancel sends nothing" {$sctl::sheet eq "" && [llength $uscene::calls] == 3}
	}
	remove {
		uscene::check "a click on Mira shows her; Remove opens the sheet" {$usp::sel eq "mira" && $sctl::sheet eq "remove" && $usp::target eq "mira" && $page::shade == 0.5}
		uscene::click 618 438
		uscene::check "Cancel closes it and removes nobody" {$sctl::sheet eq "" && $uscene::calls eq {}}
		uscene::click 1000 684
		set uscene::next failed; set uscene::msg "mira is logged in"; uscene::click 730 438
		uscene::check "Remove calls users::remove LOGIN 0 (the home folder goes too)" {[uscene::last] eq {remove mira 0}}
		uscene::check "  refused: the sheet stays and says why" {$sctl::sheet eq "remove" && $usp::said eq "mira is logged in" && [llength [usp::users]] == 3}
		uscene::click 763 369
		uscene::check "Keep the home folder turns on" {$usp::keep == 1}
		set uscene::next cancelled; uscene::click 730 438
		uscene::check "  a dismissed prompt leaves the sheet as it was" {[uscene::last] eq {remove mira 1} && $sctl::sheet eq "remove" && $usp::keep == 1 && $usp::said eq ""}
		set uscene::next ok; uscene::click 730 438
		uscene::check "  Remove then calls users::remove LOGIN 1; she is gone and you are shown" {[uscene::last] eq {remove mira 1} && $sctl::sheet eq "" && [llength [usp::users]] == 2 && [dict get [usp::chosen] login] eq "adam"}
	}
	real {
		set H /usr/bin/ribbon-users-helper
		uscene::check "the real users.tcl read the fixture: three people, you are adam, both switches' rows are there" {[lmap u [usp::users] { dict get $u login }] eq {adam mira guest} && [dict get [usp::chosen] login] eq "adam" && [dict get $users::M wheel] && [dict get $users::M nopass]}
		uscene::click 400 219
		uscene::clearlog
		uscene::click 1041 329; uscene::idle
		uscene::check "the Administrator switch runs: pkexec HELPER admin mira on" {[uscene::lastargv] eq "$H admin mira on" && [uscene::log stdin] eq ""}
		uscene::click 1041 377; uscene::idle
		uscene::check "Log in without a password runs: pkexec HELPER nopass mira on" {[uscene::lastargv] eq "$H nopass mira on"}
		uscene::click 1052 233; uscene::type " Quill"; uscene::key Return; uscene::idle
		uscene::check "the name's Return runs: pkexec HELPER rename mira Mira Quill" {[uscene::lastargv] eq "$H rename mira Mira Quill"}
		uscene::clearlog
		uscene::click 1010 281; uscene::type $PW1; uscene::key Tab; uscene::type $PW1; uscene::key Return; uscene::idle
		uscene::check "another user's password: pkexec HELPER passwd mira, the password on its standard input only" {[uscene::lastargv] eq "$H passwd mira" && [uscene::log stdin] eq "mira\n$PW1\n" && [string first $PW1 [uscene::log argv]] < 0 && [string first $PW1 [uscene::log env]] < 0 && $sctl::sheet eq ""}
		uscene::clearlog
		uscene::click 1000 684; uscene::click 730 438; uscene::idle
		uscene::check "Remove runs: pkexec HELPER remove mira delete" {[uscene::lastargv] eq "$H remove mira delete" && $sctl::sheet eq ""}
		uscene::clearlog
		uscene::click 330 684; uscene::type "Jonas Lindqvist"; uscene::key Tab; uscene::key Tab; uscene::type $PW2; uscene::key Tab; uscene::type $PW2; uscene::click 740 554; uscene::idle
		uscene::check "Add runs: pkexec HELPER add jonas off Jonas Lindqvist, LOGIN and PASSWORD on its standard input only" {[uscene::lastargv] eq "$H add jonas off Jonas Lindqvist" && [uscene::log stdin] eq "jonas\n$PW2\n" && [string first $PW2 [uscene::log argv]] < 0 && [string first $PW2 [uscene::log env]] < 0 && $sctl::sheet eq ""}
		# your own password: passwd(1) as you, no pkexec
		uscene::clearlog
		uscene::click 400 167
		uscene::click 1010 281; uscene::type $CUR; uscene::key Tab; uscene::type $PW2; uscene::key Tab; uscene::type $PW2; uscene::key Return; uscene::idle
		uscene::check "your own password: passwd with no argument, CURRENT NEW NEW on its standard input; pkexec is not run" {[uscene::log argv] eq "" && [string trim [uscene::log passwd.argv]] eq "" && [uscene::log passwd.stdin] eq "$CUR\n$PW2\n$PW2\n" && $sctl::sheet eq ""}
		# the prompt dismissed (pkexec exits 126): the switch and the sheet stay
		set f [open [file join $::env(RIBBON_USERS_LOG) exit] w]; puts $f 126; close $f
		uscene::click 400 219
		uscene::click 1010 281; uscene::type $PW1; uscene::key Tab; uscene::type $PW1; uscene::key Return; uscene::idle
		uscene::check "a dismissed prompt: the sheet stays, its fields empty, nothing is said" {$sctl::sheet eq "password" && [ui::fval us-pw1] eq "" && $usp::said eq "" && $users::error eq ""}
		uscene::key Escape
		# the helper's refusal comes back into the sheet
		set f [open [file join $::env(RIBBON_USERS_LOG) exit] w]; puts $f "2 ribbon-users-helper: mira is logged in"; close $f
		uscene::click 1000 684; uscene::click 730 438; uscene::idle
		uscene::check "a refusal: the sheet stays and says the helper's line" {$sctl::sheet eq "remove" && $usp::said eq "mira is logged in"}
		uscene::key Escape
		uscene::click 1041 329; uscene::idle
		uscene::check "  on a switch it is the page's second line" {$users::error eq "mira is logged in"}
	}
	default {
		uscene::check "you are the chosen user at first" {[dict get [usp::chosen] login] eq "adam"}
		uscene::click 1000 684
		uscene::check "Remove is not offered for your own account" {$sctl::sheet eq "" && [users::removable adam] eq "you"}
		# the name: the pencil makes it a field; Return saves
		uscene::click 1052 233
		uscene::check "the pencil makes the name a field holding it" {$usp::edit && $ui::focus eq "us-name" && [ui::fval us-name] eq "Adam"}
		uscene::type " Q:,"; uscene::key Return
		uscene::check "Return saves it: users::rename LOGIN NAME, cleaned of : and ," {[uscene::last] eq {rename adam {Adam Q}} && !$usp::edit}
		uscene::click 1052 233; uscene::key Return
		uscene::check "Return with the name unchanged calls nothing" {[uscene::last] eq {rename adam {Adam Q}} && [llength $uscene::calls] == 1 && !$usp::edit}
		uscene::click 1052 233; uscene::type "zz"; uscene::key Escape
		uscene::check "Escape leaves the field and the name as it was" {!$usp::edit && [llength $uscene::calls] == 1}
		uscene::click 1052 233; uscene::key BackSpace; uscene::key BackSpace; uscene::key BackSpace; uscene::key BackSpace; uscene::key BackSpace; uscene::key BackSpace; uscene::key Return
		uscene::check "an empty name is not saved" {[llength $uscene::calls] == 1 && $usp::edit}
		uscene::click 800 500
		uscene::check "  a click elsewhere closes the field" {!$usp::edit}
		# the switches
		uscene::click 1041 377
		uscene::check "Log in without a password calls users::set_nopass LOGIN 1" {[uscene::last] eq {nopass adam 1} && [dict get [usp::chosen] nopass]}
		set uscene::next cancelled; uscene::click 1041 377
		uscene::check "  a dismissed prompt leaves the switch as it was" {[uscene::last] eq {nopass adam 0} && [dict get [usp::chosen] nopass]}
		set uscene::next failed; set uscene::msg "adam is the only administrator"; uscene::click 1041 329
		uscene::check "Administrator calls users::set_admin LOGIN 0; refused, the switch stays on" {[uscene::last] eq {admin adam 0} && [dict get [usp::chosen] admin] && $users::error eq $uscene::msg}
		set uscene::next ok
		# another user
		uscene::click 400 219
		uscene::check "a click on Mira shows her" {[dict get [usp::chosen] login] eq "mira" && [users::removable mira] eq ""}
		uscene::click 1041 329
		uscene::check "Administrator for Mira: users::set_admin mira 1" {[uscene::last] eq {admin mira 1} && [dict get [usp::chosen] admin]}
		uscene::click 1041 329
		uscene::check "  and off again" {[uscene::last] eq {admin mira 0}}
		uscene::click 1000 684
		uscene::check "Remove opens the confirm sheet for her" {$sctl::sheet eq "remove" && $usp::target eq "mira"}
		uscene::key Escape
		uscene::check "  Escape closes it" {$sctl::sheet eq "" && $page::shade == 0}
		uscene::click 1010 281
		uscene::check "Change… opens the password sheet" {$sctl::sheet eq "password" && $usp::target eq "mira"}
		uscene::key Escape
		uscene::click 330 684
		uscene::check "Add user opens the Add sheet" {$sctl::sheet eq "add"}
		uscene::key Escape
		# the only administrator is not removed, whoever it is
		uscene::edit adam admin 0; uscene::edit mira admin 1
		set n [llength $uscene::calls]
		uscene::click 1000 684
		uscene::check "Remove is not offered for the only administrator" {$sctl::sheet eq "" && [users::removable mira] eq "admin"}
		uscene::edit adam admin 1
		# what the system does not have is not drawn
		uscene::model [dict get $users::M users] 1 0
		uscene::click 1041 377
		uscene::check "no PAM line for nopasswdlogin: no Log in without a password row" {[llength $uscene::calls] == $n}
		uscene::model [dict get $users::M users] 0 0
		uscene::click 1041 329
		uscene::check "no wheel group: no Administrator row" {[llength $uscene::calls] == $n}
		# many users: the list scrolls
		set many {}
		for {set k 0} {$k < 14} {incr k} { lappend many [uscene::user u$k [expr {1000 + $k}] "User $k" [expr {$k == 0}] [expr {$k == 0}] 0] }
		uscene::model $many
		uscene::settle
		ui::scroll [expr {400 + $ui::ox}] [expr {300 + $ui::oy}] 1; ui::scroll [expr {400 + $ui::ox}] [expr {300 + $ui::oy}] 1; uscene::settle
		uscene::click 400 167
		uscene::check "fourteen users: the wheel scrolls the list (the first row is then the third user)" {$usp::top == 2 && $usp::sel eq "u2"}
		for {set k 0} {$k < 20} {incr k} { ui::scroll [expr {400 + $ui::ox}] [expr {300 + $ui::oy}] 1 }
		uscene::settle
		uscene::check "  and stops at the last" {$usp::top == 4}
		uscene::model {}
		uscene::settle
		uscene::check "the page draws with no users at all" {[usp::chosen] eq ""}
		uscene::click 330 684
		uscene::check "  and Add user still opens its sheet" {$sctl::sheet eq "add"}
	}
}
if {[info exists ::env(RIBBON_USERS_RESULT)]} { set f [open $::env(RIBBON_USERS_RESULT) w]; puts $f [join $uscene::lines \n]; close $f } else { puts [join $uscene::lines \n] }
exit [expr {$uscene::fails > 0}]
