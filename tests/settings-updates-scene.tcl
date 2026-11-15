# settings-updates-scene.tcl -- Settings → Updates (page-updates.tcl) in the boards' states, or a flow
# that drives the page's own procs against the stand-in kit (tests/settings-updates-kit.tcl). Sourced by
# apps/settings/main.tcl through RIBBON_SETTINGS_SCENE, with RIBBON_KIT and RIBBON_KIT_UPDATER pointing at the
# stand-in and HOME / XDG_CONFIG_HOME / XDG_CACHE_HOME at a scratch home (tests/settings-updates.tcl sets them).
#   RIBBON_UPDATES_STATE = main (Settings-A3-Updates) | rewind (Settings-A3b-Rewind) | dropdown | flow | system (the
#                          system's packages through the real ribbon-update, RIBBON_UPDATE, on the stand-in package
#                          seam tests/fixtures/updates-seam, RIBBON_SEAM_STUB, and its stand-in pkexec)
#   RIBBON_UPDATES_SHOT  = file: a screenshot of the state (ImageMagick import)
#   RIBBON_UPDATES_RESULT = file: the checks, one per line ("ok ..." or "FAIL ...")
# Exits 0 when every check passes, 1 otherwise, and 2 when the page does not come up in time.

proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }

namespace eval ::kscene {
	variable fails 0
	variable lines {}
	variable state main
}
set ::kscene::state [expr {[info exists ::env(RIBBON_UPDATES_STATE)] ? $::env(RIBBON_UPDATES_STATE) : "main"}]

proc kscene::check {what ok} {
	variable fails
	variable lines
	if {$ok} { lappend lines "ok   $what" } else { lappend lines "FAIL $what"; incr fails }
}

# Run the event loop until COND (an expression, evaluated at the top level) is true, or MS pass.
proc kscene::wait {cond {ms 8000}} {
	set t [clock milliseconds]
	while {![uplevel #0 [list expr $cond]]} {
		if {[clock milliseconds] - $t > $ms} { return 0 }
		update
		after 30
	}
	return 1
}

proc kscene::finish {code} {
	variable lines
	if {[info exists ::env(RIBBON_UPDATES_RESULT)]} {
		set fh [open $::env(RIBBON_UPDATES_RESULT) w]
		puts $fh [join $lines \n]
		close $fh
	}
	puts [join $lines \n]
	exit $code
}

proc kscene::shot {} {
	# grab from an after callback, as tests/settings-scene.tcl does, once the window has painted
	if {![info exists ::env(RIBBON_UPDATES_SHOT)]} return
	variable grabbed 0
	# draw the page as it is now (the sheet included), then grab once it has painted
	page::draw; update idletasks
	after 600 [list apply {{f} { page::draw; update idletasks; exec import -window root $f; set ::kscene::grabbed 1 }} $::env(RIBBON_UPDATES_SHOT)]
	while {!$grabbed} { update; after 20 }
}

proc kscene::conf {key} {
	set path [file join $::env(XDG_CONFIG_HOME) kit updates.conf]
	if {[catch {open $path r} fh]} { return "" }
	fconfigure $fh -encoding utf-8
	set v ""
	foreach l [split [read $fh] \n] { if {[regexp "^\\s*$key\\s*=\\s*(.*?)\\s*\$" $l -> x]} { set v $x } }
	close $fh
	set v
}

proc kscene::run {} {
	settings::select updates
	if {![wait {$kupd::started && $kupd::busy eq "" && [llength $kupd::hist] > 0 && [llength $kupd::rows] > 0}]} {
		puts stderr "the Updates page did not load its plan and history: started=$::kupd::started busy=$::kupd::busy err=$::kupd::err rows=[llength $::kupd::rows] hist=[llength $::kupd::hist]"; exit 2
	}
	switch -- $::kscene::state {
		main {
			check "the waiting list has five kits from kit's plan" [expr {[llength $::kupd::rows] == 5}]
			check "the question is kit's own" [expr {[dict get $::kupd::plan question] eq "Update? (takes effect at restart)"}]
			check "the history has four changes, newest first" [expr {[llength $::kupd::hist] == 4}]
			check "the cursor's change has a Rewind plan of five kits" [expr {[llength [kupd::rplan_rows]] == 5}]
			shot
			finish [expr {[lsearch -glob $::kscene::lines "FAIL*"] < 0 ? 0 : 1}]
		}
		rewind {
			kupd::rewind_open
			wait {$kupd::sheet}
			settings::key Escape "" 0
			check "Escape closes the Rewind sheet (settings::key)" [expr {!$kupd::sheet}]
			kupd::rewind_open
			check "Rewind opens the sheet again with kit's plan" [wait {$kupd::sheet}]
			shot
			finish [expr {[lsearch -glob $::kscene::lines "FAIL*"] < 0 ? 0 : 1}]
		}
		dropdown {
			kupd::open_dd interval
			wait {$kupd::dd eq "interval"}
			shot
			finish [expr {[lsearch -glob $::kscene::lines "FAIL*"] < 0 ? 0 : 1}]
		}
		flow {
			flow
		}
		system {
			system
		}
	}
}

proc kscene::seam {file text} {
	set fh [open [file join $::env(RIBBON_SEAM_STUB) $file] w]; puts -nonewline $fh $text; close $fh
}
proc kscene::seamfile {file} {
	if {[catch {open [file join $::env(RIBBON_SEAM_STUB) $file]} fh]} { return "" }
	set t [read $fh]; close $fh; return $t
}

# The system's packages beside the kits: the waiting list, the question, Update (pkexec ribbon-update first, then kit),
# the restart card; a refusal and a failed check said in the subtitle.
proc kscene::system {} {
	variable lines
	set names [lmap r $::kupd::rows { dict get $r name }]
	check "the waiting list is kit's five kits, then the system's package (ribbon-update --tcl)" [expr {$names eq {firefox ffmpeg mesa openssl linux linux6.18}}]
	set r [lindex $::kupd::rows end]
	check "the system's row reads as kit's: from → to, size, restart" [expr {[dict get $r old] eq "6.18.58" && [dict get $r new] eq "6.18.60" && [dict get $r bytes] == 14000000 && [dict get $r tags] eq "restart"}]
	check "one question in kit's words for both" [expr {[dict get $::kupd::plan question] eq "Update? (takes effect at restart)"}]
	check "the subtitle counts both: 6 waiting" [string match "6 waiting · checked *" [kupd::subtitle]]
	check "the check asked the seam and changed nothing on the system (no pkexec)" [expr {"pkg_updates" in [split [seamfile log] \n] && ![string match *pkexec* [seamfile log]] && ![string match *pkg_upgrade* [seamfile log]]}]
	check "the check left the system's list in the cache, which the page lists until a plan arrives" [expr {[lmap r [kupd::cache_rows] { dict get $r name }] eq {linux6.18}
		&& [dict get [lindex [kupd::cache_rows] 0] old] eq "6.18.58" && [dict get [lindex [kupd::cache_rows] 0] tags] eq "restart"}]
	seam log ""
	kupd::update
	check "Update is busy while it runs" [expr {$::kupd::busy eq "update"}]
	wait {$kupd::busy eq "" && [string match Updated* $kupd::doneline]} 30000
	set lg [split [string trim [seamfile log]] \n]
	check "pkexec ribbon-update --tcl --yes first (a snapshot, the packages), then kit check --tcl --yes" [expr {[string match "pkexec bash *ribbon-update --tcl --yes" [lindex $lg 0]] &&
		[lsearch -glob $lg "ribbon-snapshot pre ribbon update *"] > 0 && [lsearch $lg "pkg_upgrade -y"] > 0 && [lsearch $lg "check --tcl --yes"] > [lsearch $lg "pkg_upgrade -y"]}]
	check "the seam updated the system (linux6.18 6.18.60)" [string match "*linux6.18 6.18.60*" [seamfile installed]]
	check "the result counts both, and a restart to finish" [string match "Updated 6 kits · today, *· restart to finish" $::kupd::doneline]
	check "the restart card has both restarts, the system's (run first) then kit's" [expr {$::kupd::restart eq {{linux6.18 6.18.60} {linux 6.18.60}}}]
	check "the reboot flag is written" [file exists [file join $::env(RIBBON_RUN) reboot-required]]
	wait {$kupd::busy eq ""}
	check "after the update the list is read again: the system's row is gone" [expr {"linux6.18" ni [lmap r $::kupd::rows { dict get $r name }]}]
	# refused by polkit: the reason stays in the subtitle through the check after it; the row is still waiting
	seam plan "linux6.18|6.18.60|6.18.61|15000000|update|restart\n"
	seam deny ""
	kupd::check
	wait {$kupd::busy eq "" && "linux6.18" in [lmap r $kupd::rows { dict get $r name }]}
	kupd::update
	wait {$kupd::busy eq "" && $kupd::err ne ""} 30000
	wait {$kupd::busy eq ""}
	check "refused: pkexec's reason is the subtitle" [expr {[kupd::subtitle] eq "Error executing command as another user: Not authorized"}]
	check "and the system's row still waits" [expr {"linux6.18" in [lmap r $::kupd::rows { dict get $r name }] && ![string match *6.18.61* [seamfile installed]]}]
	file delete [file join $::env(RIBBON_SEAM_STUB) deny]
	# the system's check failing: its reason, and kit's rows still listed
	seam fail-check ""
	kupd::check
	wait {$kupd::busy eq ""}
	check "a failed system check: the seam's reason, kit's five rows still there" [expr {$::kupd::err eq "the repository could not be reached" && [llength $::kupd::rows] == 5}]
	file delete [file join $::env(RIBBON_SEAM_STUB) fail-check]
	shot
	finish [expr {[lsearch -glob $lines "FAIL*"] < 0 ? 0 : 1}]
}

# The switches, the Rewind sheet and Update, through the page's own procs and kit's answers.
proc kscene::flow {} {
	variable lines
	kupd::write notify no
	wait {$kupd::busy eq ""}
	check "Notify writes notify = no through kit-updater --set" [expr {[kscene::conf notify] eq "no"}]
	check "the page reads the switch back" [expr {![kupd::on [kupd::cfg notify]]}]
	kupd::write download yes
	wait {$kupd::busy eq ""}
	check "Download automatically writes download = yes" [expr {[kscene::conf download] eq "yes"}]
	kupd::write install 03:00
	wait {$kupd::busy eq ""}
	check "a time writes install = 03:00" [expr {[kscene::conf install] eq "03:00"}]
	kupd::write install off
	wait {$kupd::busy eq ""}
	check "switching install off writes install = off" [expr {[kscene::conf install] eq "off"}]
	check "the time is kept while the switch is off" [expr {$kupd::time eq "03:00"}]
	kupd::write interval 12h
	wait {$kupd::busy eq ""}
	check "Check every writes interval = 12h" [expr {[kscene::conf interval] eq "12h"}]
	check "the dropdown shows the label kit's value has" [expr {[kupd::label_of interval 12h] eq "12 hours"}]
	kupd::rewind_open
	check "Rewind opens the sheet with kit's plan" [expr {$kupd::sheet && [llength [kupd::rplan_rows]] == 5}]
	kupd::rewind_go
	wait {$kupd::busy eq "" && !$kupd::sheet}
	check "Rewind runs kit rewind --tcl --yes" [string match Rewound* $kupd::doneline]
	wait {$kupd::busy eq "" && [llength $kupd::plan] > 0}
	kupd::update
	wait {$kupd::busy eq "" && [llength $kupd::restart] == 1}
	check "Update runs kit check --tcl --yes and shows the restart card" [string match "Updated 5 kits*" $kupd::doneline]
	finish [expr {[lsearch -glob $lines "FAIL*"] < 0 ? 0 : 1}]
}

# Start the state from a timer, not an idle callback: Tk maps the window in idle time, and a nested update inside an
# idle callback never maps it, so the grab would show nothing. Wait until the first draw has asked kit, then run.
after 100 ::kscene::run
