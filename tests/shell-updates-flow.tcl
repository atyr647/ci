# shell-updates-flow.tcl - RIBBON_SHELL_TEST hook for the bar's updates panel (started by tests/shell-updates.tcl
# on Xvfb, with kit's fixture store as HOME and RIBBON_KIT naming this tree's kit): the chip opens the panel,
# the panel shows kit's plan and question, Cancel closes it, the button runs kit's grab (as a subprocess,
# kit check --tcl --yes), then Done, History and Rewind through kit rewind. Also the pages as the boards draw
# them, from the boards' own data, for RIBBON_UPDATES_SHOTS (a screenshot of each state). Every wait has a
# limit and a 140 s one ends the run.

set RIBBON_SCENE idle
set ::env(RIBBON_SCENE) idle
source -encoding utf-8 [file join [file dirname [info script]] shell-scene.tcl]

encoding system utf-8        ;# kit prints UTF-8 (the arrow), whatever the locale of this X session says
set failed 0
interp bgerror {} {apply {{msg opts} { puts "  FAIL background error: [dict get $opts -errorinfo]"; exit 1 }}}
after 140000 {puts "  FAIL the updates panel checks took more than 140 s"; exit 1}
proc ok {what} { puts "  ok   $what" }
proc bad {what why} { global failed; incr failed; puts "  FAIL $what: $why" }
proc check {what cond why} { if {[uplevel 1 [list expr $cond]]} { ok $what } else { bad $what $why } }
proc until {what cond {ms 30000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 [list expr $cond]]} {
		if {[clock milliseconds] > $end} { bad $what "timed out after $ms ms" ; return 0 }
		after 40; update
	}
	ok $what
	return 1
}

# ---- helpers --------------------------------------------------------------------------------------------
set HOME $::env(HOME)
proc shot {name} {
	if {![info exists ::env(RIBBON_UPDATES_SHOTS)]} return
	update; after 400; update
	catch {exec import -window root [file join $::env(RIBBON_UPDATES_SHOTS) $name.png]}
}
proc texts {} {
	set out {}
	foreach i [.panel.c find all] { if {[.panel.c type $i] eq "text"} { lappend out [.panel.c itemcget $i -text] } }
	return $out
}
# what the panel draws, as one string without spaces (text runs split at spaces)
proc drawn {} { string map {" " ""} [join [texts] ""] }
proc click {label} {
	if {![info exists ::upd::rects($label)]} { bad "button $label" "not drawn: [array names ::upd::rects]"; return 0 }
	lassign $::upd::rects($label) x0 y0 x1 y1
	panel::press [expr {($x0 + $x1) / 2}] [expr {($y0 + $y1) / 2}]
	return 1
}
proc active {} { set f [open $::HOME/.local/share/kit/active]; set t [read $f]; close $f; return $t }
proc version {name} {
	foreach l [split [active] \n] { set f [split $l \t]; if {[lindex $f 0] eq "kit" && [lindex $f 1] eq $name && [lindex $f 4] ne "prev"} { return [lindex $f 2] } }
	return ""
}
proc root {name} { foreach l [split [active] \n] { set f [split $l \t]; if {[lindex $f 0] eq "kit" && [lindex $f 1] eq $name} { return [lindex $f 3] } } }
proc names {rows} { lmap r $rows { dict get $r name } }
set ::ran {}
proc apps::run {cmd} { lappend ::ran $cmd }
set ::sent {}
proc wm::send {cmd args} { lappend ::sent [join [concat $cmd $args]] }
proc has {label} { info exists ::upd::rects($label) }
# the stand-in package seam's state (tests/fixtures/updates-seam): a file's contents
proc seam {file text} { set f [open $::env(RIBBON_SEAM_STUB)/$file w]; puts -nonewline $f [subst -nocommands -novariables $text]; if {$text ne ""} { puts $f "" }; close $f }
proc seamfile {file} { set f [open $::env(RIBBON_SEAM_STUB)/$file]; set t [read $f]; close $f; return $t }
proc seamlog {} { string trim [seamfile log] }
# no ribbon-update or kit still running (the panel's background refresh after an update reads the chip's count again)
proc quiet {} { set end [expr {[clock milliseconds] + 20000}]; while {[array size upd::buf] && [clock milliseconds] < $end} { after 40; update } }
proc redraw {} { bar::draw; update }

# ---- the flow ---------------------------------------------------------------------------------------------
proc flow {} {
	global HOME failed
	set kitcmd $::env(RIBBON_KIT)
	status::updates_read
	redraw
	check "the chip is shown with kit's four updates waiting (read from ~/.cache/kit/updates)" {$status::updates == 4 && "updates" in [lmap p $bar::placed {lindex $p 0}]} "updates $status::updates"
	lassign [lsearch -inline -index 0 $bar::placed updates] - cx cw

	# the system's packages beside the kits: ribbon-update --tcl's plan joins kit's, kit's rows first, one question
	seam plan "linux6.18|6.18.58|6.18.60|14000000|update|restart\nlibfoo||1.2|5000|install|"
	bar::click [expr {$cx + $cw / 2}] 27 1
	until "with system updates waiting, the chip opens the panel" {$panel::open eq "updates" && $upd::page eq "plan"}
	update
	set rows [dict get $upd::plan rows]
	check "the plan has kit's four kits, then the system's packages (ribbon-update --tcl)" {[names $rows] eq {Firefox ffmpeg mesa openssl linux6.18 libfoo}} [names $rows]
	check "the system's rows read as kit's: from → to, size, the restart tag; a new package as new" {[dict get [lindex $rows 4] old] eq "6.18.58" && [dict get [lindex $rows 4] new] eq "6.18.60" &&
		[dict get [lindex $rows 4] bytes] == 14000000 && [dict get [lindex $rows 4] tags] eq "restart" && [dict get [lindex $rows 5] action] eq "install"} $rows
	check "one question for them all, kit's words: Install 1 and update 5? (takes effect at restart)" {[dict get $upd::plan question] eq "Install 1 and update 5? (takes effect at restart)"} [dict get $upd::plan question]
	set d [drawn]
	check "the panel draws the system's rows, the restart tag, 6 waiting and the button with its tail" {[string match *linux6.18* $d] && [string match *6.18.58* $d] && [string match *restart* $d] &&
		[string match *6waiting* $d] && [has {Install 1 and update 5?}] && [string match "*Download[string map {{ } {}} [upd::fmtsize [upd::total $rows]]]*" $d]} $d
	check "the check asked the seam and changed nothing (no pkexec, no update)" {[seamlog] eq "pkg_updates"} [seamlog]
	click Cancel
	seam plan ""; seam log ""

	# the chip opens the panel: kit check --tcl brings the plan
	bar::click [expr {$cx + $cw / 2}] 27 1
	until "clicking the chip opens the updates panel" {$panel::open eq "updates" && $upd::page eq "plan"}
	update
	set rows [dict get $upd::plan rows]
	check "the plan has the four kits, in kit's order (firefox's row shows its launcher's name)" {[names $rows] eq {Firefox ffmpeg mesa openssl}} [names $rows]
	check "the question is kit's own: Update?" {[dict get $upd::plan question] eq "Update?"} [dict get $upd::plan question]
	check "security is tagged on firefox and openssl only" {[lmap r $rows { dict get $r tags }] eq {security {} {} security}} [lmap r $rows { dict get $r tags }]
	check "the panel is the bar's width, hanging under it" {$bar::rightw >= 480 && [winfo exists .panel]} "$bar::rightw"
	check "the tray does not light up for the updates panel" {$panel::open eq "updates"} ""
	# the same plan kit check prints on a terminal
	catch {exec {*}$kitcmd check < /dev/null 2>@1} cli
	set okrows 1
	foreach r $rows {
		set re "^  [dict get $r name] +[dict get $r old] +→ +[dict get $r new] +[upd::fmtsize [dict get $r bytes]]"
		if {[dict get $r tags] ne ""} { append re " +[dict get $r tags]" }
		append re {$}
		if {![regexp -line $re $cli]} { set okrows 0; puts "         | no line like $re in\n$cli" }
	}
	check "every row is a line of kit check's plan: name, from → to, size, tag" {$okrows} ""
	check "and kit check asks the question the button carries" {[string first "\nUpdate? \[Y/n\]" $cli] > 0} $cli
	set d [drawn]
	check "the panel shows the title, the plan, the total and the button" {[string match *Updates* $d] && [string match *4waiting* $d] && [string match *Firefox* $d] && [string match *security* $d] &&
		[string match "*Download[string map {{ } {}} [upd::fmtsize [upd::total $rows]]]*" $d] && [string match *Update?* $d] && [string match *Cancel* $d] && [string match *History* $d]} $d
	shot live-1-panel

	# Cancel closes it
	click Cancel
	check "Cancel closes the panel" {$panel::open eq ""} $panel::open
	check "and nothing was installed" {[version org.mozilla.firefox] eq "134.0.1"} [version org.mozilla.firefox]

	# the button runs kit's grab; firefox is running, so it keeps the old version until its next start
	bar::click [expr {$cx + $cw / 2}] 27 1
	until "the chip opens the panel again" {$panel::open eq "updates" && $upd::page eq "plan"}
	update
	set run $HOME/.local/share/kit/running/[root org.mozilla.firefox].[pid]
	file mkdir [file dirname $run]
	set f [open $run w]; puts $f org.mozilla.firefox; close $f
	check "the primary button carries the question" {[has {Update?}]} [array names upd::rects]
	click Update?
	check "the button is busy while kit works (dimmed, Cancel answers nothing)" {$upd::busy == 1} $upd::busy
	update
	click Cancel
	check "Cancel does not close the panel while kit works" {$panel::open eq "updates"} $panel::open
	shot live-2-busy
	until "kit's grab finishes: the Done page" {$upd::page eq "done" && !$upd::busy} 60000
	update
	file delete $run
	check "kit really switched them (the active set has the new versions)" {[version org.mozilla.firefox] eq "134.0.2" && [version org.ribbon.test.ffmpeg] eq "7.1.1" && [version org.ribbon.test.mesa] eq "25.2.8" && [version org.ribbon.test.openssl] eq "3.0.14"} [active]
	set drows [dict get $upd::done rows]
	check "Done lists each kit with its new version, as kit says it" {[names $drows] eq {Firefox ffmpeg mesa openssl} && [lmap r $drows { dict get $r old }] eq {134.0.2 7.1.1 25.2.8 3.0.14} && [lsort -unique [lmap r $drows { dict get $r new }]] eq {switched}} $drows
	check "Still running old versions: firefox (the kit's short name: restart runs kit run on it)" {[dict get $upd::done stale] eq {{firefox {}}}} [dict get $upd::done stale]
	set d [drawn]
	check "Done shows Updated, 4 kits, the notes, the running strip and its Restart button" {[string match *Updated* $d] && [string match *4kits* $d] && [string match *Fromitsnextstart* $d] && [string match *Switched* $d] &&
		[string match *STILLRUNNINGOLDVERSIONS* $d] && [has {Restart}]} $d
	check "no Restart to finish without a restart pending" {![string match *Restarttofinish* $d] && ![has {Restart now}]} $d
	check "nothing waiting from the system: no pkexec, no system update" {![string match *pkexec* [seamlog]] && ![string match *pkg_upgrade* [seamlog]]} [seamlog]
	check "the panel stays open after the update, and the chip is gone (nothing waiting)" {$panel::open eq "updates" && $status::updates == 0 && "updates" ni [lmap p $bar::placed {lindex $p 0}]} "open $panel::open updates $status::updates"
	shot live-3-done
	click Restart
	check "Restart closes the app's windows and starts it again through kit" {[llength $::ran] == 0} $::ran
	after 1500; update
	check "kit run firefox is what starts it" {[llength $::ran] == 1 && [string match "*run 'firefox'" [lindex $::ran 0]] && [string match *tclsh* [lindex $::ran 0]]} $::ran
	check "and the strip is gone" {[dict get $upd::done stale] eq {}} [dict get $upd::done stale]

	# History: kit rewind --tcl lists the changes, newest first
	click History
	until "History opens" {$upd::page eq "history"}
	update
	set titles [lmap e $upd::hist { dict get $e title }]
	check "the history lists the update, then the first install (from kit's history)" {$titles eq {{Updated 4 kits} {Installed 4 kits}}} $titles
	check "the update's line names its kits" {[dict get [lindex $upd::hist 0] sub] eq "firefox, ffmpeg, mesa, openssl"} [lindex $upd::hist 0]
	set d [drawn]
	check "History shows the changes and the Rewind button on the newest" {[string match *History* $d] && [string match *2changes* $d] && [string match *Updated4kits* $d] && [has {Rewind}] && [string match *Allhistory* $d]} $d
	shot live-4-history
	# the back tile returns to the Done page it came from
	panel::press [expr {$upd::pad + 20}] 36
	check "the back tile returns to Done" {$upd::page eq "done"} $upd::page
	click History
	until "History again" {$upd::page eq "history"}
	update

	# Rewind: its plan, no download, then kit rewind does it
	click Rewind
	check "Rewind shows the plan of taking the update back, with kit's question" {$upd::page eq "rewind" && [dict get $upd::rplan question] eq "Rewind?" &&
		[lmap r [dict get $upd::rplan rows] { list [dict get $r name] [dict get $r old] [dict get $r new] }] eq {{Firefox 134.0.2 134.0.1} {ffmpeg 7.1.1 7.1} {mesa 25.2.8 25.2.7} {openssl 3.0.14 3.0.13}}} $upd::rplan
	update
	set d [drawn]
	check "the Rewind page: its title, the change, No download, Cancel and the question" {[string match *Rewind* $d] && [string match "*Updated4kits·today*" $d] && [string match *Nodownload* $d] && [string match *Cancel* $d] && [has {Rewind?}]} $d
	shot live-5-rewind
	click Cancel
	check "Cancel on Rewind goes back to History" {$upd::page eq "history"} $upd::page
	click Rewind
	update
	click Rewind?
	check "the Rewind button is busy while kit works" {$upd::busy == 1} $upd::busy
	until "kit's rewind finishes: the Done page" {$upd::page eq "done" && !$upd::busy} 60000
	update
	check "kit really rewound them" {[version org.mozilla.firefox] eq "134.0.1" && [version org.ribbon.test.ffmpeg] eq "7.1" && [version org.ribbon.test.mesa] eq "25.2.7" && [version org.ribbon.test.openssl] eq "3.0.13"} [active]
	check "the rewind is logged on top (install, update, rewound)" {[llength [glob -nocomplain $HOME/.local/share/kit/history/*]] == 3} [glob -nocomplain $HOME/.local/share/kit/history/*]
	check "Done after a rewind says Rewound" {[string match *Rewound* [drawn]]} [drawn]

	# Restart to finish: kit tells it in the result (a system kit that takes effect at restart)
	set upd::done [dict create rows {{name linux old 6.18.60 new switched action done bytes {} tags {}}} lines {} stale {} restart {{linux 6.18.60}} time [clock seconds]]
	panel::draw; update
	check "a pending restart shows Restart to finish, Later and Restart now" {[string match *Restarttofinish* [drawn]] && [has {Later}] && [has {Restart now}] && [string match *Atrestart* [drawn]]} [drawn]
	click "Restart now"
	check "Restart now asks the system to restart" {[lindex $::ran end] eq "loginctl reboot"} $::ran
	click Later
	check "Later closes the panel" {$panel::open eq "" && $upd::page eq ""} "open $panel::open page $upd::page"
	# the notes: a plan row carrying kit's note (U03d) shows it under the row, in the plan
	set upd::plan [dict create rows [list [dict create name notes short notes old 1.5 new 1.0 action update bytes {} tags {} \
		note {notes 1.0 may not open data written by 1.5} kind app root x fullname notes]] question {Update?} checked [clock seconds]]
	set upd::page plan ; set upd::err ""
	panel::show updates ; update
	check "a plan row's note shows under the row" {[string match "*notes1.0maynotopendatawrittenby1.5*" [drawn]]} [drawn]
	panel::close
	set upd::page ""

	# the system's update: pkexec ribbon-update --tcl --yes first, then kit's grab; Done shows it, with Restart to finish
	set kitwrap $::env(RIBBON_UPDATES_FIXTURE)/kitwrap
	set f [open $kitwrap w]; puts $f "#!/bin/sh\necho \"kit \$*\" >> $::env(RIBBON_SEAM_STUB)/log\nexec [join $kitcmd { }] \"\$@\""; close $f
	file attributes $kitwrap -permissions 0755
	set ::env(RIBBON_KIT) $kitwrap
	seam plan "linux6.18|6.18.58|6.18.60|14000000|update|restart"
	set status::updates 1; redraw
	lassign [lsearch -inline -index 0 $bar::placed updates] - cx cw
	bar::click [expr {$cx + $cw / 2}] 27 1
	until "the kits rewound and the system's update waiting: the panel opens on both" {$panel::open eq "updates" && $upd::page eq "plan"}
	update
	check "the plan is the kits, then the system's row, its question with the restart tail" {[names [dict get $upd::plan rows]] eq {Firefox ffmpeg mesa openssl linux6.18} && [dict get $upd::plan question] eq "Update? (takes effect at restart)"} $upd::plan
	seam log ""
	click Update?
	check "the button is busy while the system updates" {$upd::busy == 1} $upd::busy
	until "the system's update finishes: the Done page" {$upd::page eq "done" && !$upd::busy} 60000
	update
	set lg [split [string trim [seamlog]] \n]
	check "pkexec ribbon-update --tcl --yes ran first (a snapshot, then the packages), then kit check --tcl --yes" {[string match "pkexec bash *ribbon-update --tcl --yes" [lindex $lg 0]] &&
		[lsearch -glob $lg "ribbon-snapshot pre ribbon update *"] > 0 && [lsearch $lg "pkg_upgrade -y"] > [lsearch -glob $lg "ribbon-snapshot pre*"] &&
		[lsearch -glob $lg "kit check --tcl --yes"] > [lsearch $lg "pkg_upgrade -y"]} $lg
	check "the seam really updated it (installed: linux6.18 6.18.60)" {[string match "*linux6.18 6.18.60*" [seamfile installed]]} [seamfile installed]
	check "Done: both results, the system's row switched; the restart list from ribbon-update" {[names [dict get $upd::done rows]] eq {linux6.18 Firefox ffmpeg mesa openssl} &&
		[dict get [lindex [dict get $upd::done rows] 0] new] eq "switched" && [dict get $upd::done restart] eq {{linux6.18 6.18.60}}} $upd::done
	check "kit's part really ran (the kits at their new versions again)" {[version org.mozilla.firefox] eq "134.0.2"} [active]
	check "the kernel's update wrote the reboot flag ribbon-update and pending share" {[file exists $::env(RIBBON_RUN)/reboot-required]} ""
	set d [drawn]
	check "Done shows Updated, 5 kits, the row At restart, Restart to finish, Later and Restart now" {[string match *Updated* $d] && [string match *5kits* $d] && [string match *linux6.18* $d] && [string match *Atrestart* $d] &&
		[string match *Restarttofinish* $d] && [has {Restart now}] && [has Later]} $d
	until "after the update the system's list is read again: its cache file (the chip's count) has nothing waiting" {![catch {
		set f [open $::HOME/.cache/ribbon/system-updates]; set c [read $f]; close $f; set c}] && [dict get $c updates] eq {} && [array size upd::buf] == 0} 20000
	click Later
	# refused: pkexec's answer where the subtitle is, the plan still there
	seam plan "linux6.18|6.18.60|6.18.61|14000000|update|restart"
	seam deny ""
	set upd::page ""
	quiet
	set status::updates 1; redraw
	lassign [lsearch -inline -index 0 $bar::placed updates] - cx cw
	bar::click [expr {$cx + $cw / 2}] 27 1
	until "the panel opens on the next system update" {$panel::open eq "updates" && $upd::page eq "plan"}
	update
	check "only the system's row now (the kits are up to date)" {[names [dict get $upd::plan rows]] eq {linux6.18}} $upd::plan
	click {Update?}
	until "refused by polkit: the plan stays, pkexec's reason where the subtitle is" {!$upd::busy && $upd::page eq "plan" && $upd::err eq "Error executing command as another user: Not authorized"} 30000
	check "and the seam was not asked to update" {![string match "*6.18.61*" [seamfile installed]]} [seamfile installed]
	panel::close
	file delete $::env(RIBBON_SEAM_STUB)/deny
	# the system's check failing: the reason, and kit's plan still shown
	seam fail-check ""
	set upd::page ""
	quiet
	set status::updates 1; redraw
	lassign [lsearch -inline -index 0 $bar::placed updates] - cx cw
	bar::click [expr {$cx + $cw / 2}] 27 1
	until "a failed system check: the panel opens with its reason" {$panel::open eq "updates" && $upd::err eq "the repository could not be reached"} 30000
	panel::close
	file delete $::env(RIBBON_SEAM_STUB)/fail-check
	seam plan ""
	set ::env(RIBBON_KIT) $kitcmd

	# kit missing or failing: the plan page opens empty, the reason where the subtitle is
	set ::env(RIBBON_KIT) /nonexistent/kit
	set status::updates 1; redraw
	lassign [lsearch -inline -index 0 $bar::placed updates] - cx cw
	bar::click [expr {$cx + $cw / 2}] 27 1
	until "without kit the panel opens, saying so" {$panel::open eq "updates" && $upd::err eq "kit is not installed"} 10000
	panel::close
	set ::env(RIBBON_KIT) $kitcmd

	if {[info exists ::env(RIBBON_UPDATES_SHOTS)]} { boards }
	puts [expr {$failed ? "  $failed updates panel check(s) failed" : "  all updates panel checks passed"}]
	exit [expr {$failed ? 1 : 0}]
}

# The four boards' own data (design/tools/gen_kitui.py: 5 kits and 47 MB waiting, a restart among them), drawn by
# the panel as it draws kit's, for the side-by-side review (RIBBON_UPDATES_SHOTS=DIR: board-N.png).
proc boards {} {
	proc row {name old new bytes tags} { dict create name $name old $old new $new action update bytes $bytes tags $tags kind app root x fullname $name }
	proc at {hm {day ""}} { clock scan "[expr {$day eq "" ? [clock format [clock seconds] -format %Y-%m-%d] : $day}] $hm" -format "%Y-%m-%d %H:%M" }
	set up [list [row firefox 134.0.1 134.0.2 12000000 security] [row ffmpeg 7.1 7.1.1 4000000 {}] [row mesa 25.2.7 25.2.8 16000000 {}] \
		[row openssl 3.0.13 3.0.14 1000000 security] [row linux 6.18.58 6.18.60 14000000 restart]]
	set back [lmap r $up { dict merge $r [dict create old [dict get $r new] new [dict get $r old] bytes 0 tags [expr {[dict get $r tags] eq "restart" ? {} : [dict get $r tags]}]] }]
	set hist [list \
		[dict create icon up title "Updated 5 kits" sub "firefox, ffmpeg, mesa, openssl, linux" time [at 14:20]] \
		[dict create icon plus title "Installed Tally" sub "tally 1.0.2" time [at 18:42 2026-11-06]] \
		[dict create icon undo title "Rewound MK Studio" sub "1.5.0 → 1.4.0 · held" time [at 09:02 2026-11-05]] \
		[dict create icon up title "Updated MK Studio" sub "1.4.0 → 1.5.0" time [at 21:10 2026-11-04]] \
		[dict create icon trash title "Uninstalled Krita" sub "krita 5.2.6" time [at 16:30 2026-11-02]] \
		[dict create icon up title "Updated 3 kits" sub "gtk3, pipewire, sqlite" time [at 16:05 2026-11-02]]]
	set status::date "Sat 7 Nov"
	# 2 plan: waiting
	set status::time 14:18; set status::updates 5
	set upd::plan [dict create rows $up question "Update? (takes effect at restart)" checked [at 14:02]]
	set upd::page plan; set upd::err ""; set upd::busy 0
	redraw; panel::show updates; update; shot board-2-plan
	# 3 done
	set status::time 14:26; set status::updates 0
	set upd::kind update
	set upd::done [dict create rows [lmap r $up { dict create name [dict get $r name] old [dict get $r new] new switched action done bytes {} tags {} }] lines {} \
		stale {{firefox {ffmpeg mesa}}} restart {{linux 6.18.60}} time [at 14:20]]
	set upd::page done
	redraw; panel::draw; update; shot board-3-done
	# 4 history
	set status::time 14:31
	set upd::hist $hist; set upd::hover 0
	set upd::page history; set upd::back done
	redraw; panel::draw; update; shot board-4-history
	# 5 rewind
	set upd::rplan [dict create rows $back question Rewind?]
	set upd::page rewind
	redraw; panel::draw; update; shot board-5-rewind
	set upd::page ""
	panel::close
}
after 600 flow
