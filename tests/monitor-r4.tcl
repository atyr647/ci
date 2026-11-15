# tests/monitor-r4.tcl - the System monitor's round-4 pieces against real processes and stand-ins, run under xvfb as a
# scene (tests/steps.d/58-monitor-r4.sh): Priority's submenu renices every thread of a sacrificial process (Low,
# Normal, High; the pkexec route and the muted level for a person who is not an administrator); the End sheet (an
# app with two processes, a process not responding; Cancel signals nothing, End ends exactly the listed processes);
# the strip (Wait puts it away, End opens the sheet, the table moves down by it); `--end PID`; Services from a
# dinitctl stand-in (the person's own) and through the real ribbon-services-helper under a pkexec stand-in (the
# system's): the list, Start, Stop, Restart, and what is never stopped.
source [file join [file dirname [file normalize [info script]]] monitor-scene.tcl]

set ::fails 0
proc check {name ok} { if {$ok} { puts "  ok   $name" } else { puts "  FAIL $name"; incr ::fails } }
set T $::env(RIBBON_MONITOR_T)
set repo [file normalize [file join [file dirname [info script]] ..]]

proc click {x y} {
	ui::press [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]
	ui::release [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]
}
# Click the middle of the last drawn hit whose script matches PATTERN; 0 when there is none.
proc click_hit {pattern} {
	foreach h [lreverse $::ui::hits] {
		lassign $h x0 y0 x1 y1 press
		if {[string match $pattern $press]} { click [expr {($x0 + $x1) / 2.0}] [expr {($y0 + $y1) / 2.0}]; return 1 }
	}
	return 0
}
proc has_hit {pattern} { expr {[lsearch -glob [lmap h $::ui::hits {lindex $h 4}] $pattern] >= 0} }
proc wait_for {script ms} {
	set until [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 $script]} {
		if {[clock milliseconds] >= $until} { return 0 }
		after 20 {set ::tick 1}; vwait ::tick
	}
	return 1
}
proc sleeper {{shield 0}} {
	if {$shield} { return [exec sh -c "trap '' TERM; exec sleep 300" </dev/null >/dev/null 2>/dev/null &] }
	return [exec sleep 300 </dev/null >/dev/null 2>/dev/null &]
}
proc nices {pid} { lmap t [monitor::tasks_of $pid] {monitor::nice_of $pid $t} }
proc script {path body} {
	set ch [open $path w]; puts $ch "#!/bin/sh\n$body"; close $ch
	file attributes $path -permissions 0755
}
proc log {} { string trim [monitor::slurp $::T/log] }
# The pkexec stand-in's last line is renice N for exactly the threads of PID: pkexec /path/renice N -p TID...
proc prio_logged {n pid} {
	set last [lindex [split [log] \n] end]
	expr {[regexp {^pkexec (/\S*/renice) (-?\d+) -p (.*)$} $last -> - got tids] && $got == $n
		&& [lsort -integer $tids] eq [monitor::tasks_of $pid] && [llength $tids] >= 4}
}

proc run {} {
	global T repo
	set ::monitor::scene 0
	set ::monitor::view processes
	set ::monitor::metric apps
	set ::monitor::sel ""
	set ::ui::focus ""

	# ---- Priority -----------------------------------------------------------------------------------------------
	# a process with threads: python's, so every thread's level is seen to change
	set thr [exec python3 -c {import threading,time
for i in range(3): threading.Thread(target=time.sleep, args=(300,), daemon=True).start()
time.sleep(300)} </dev/null >/dev/null 2>/dev/null &]
	wait_for [list expr "\[llength \[monitor::tasks_of $thr\]\] >= 4"] 3000
	monitor::refresh
	ui::fset search python3; monitor::search_changed
	set y [monitor::row_y pid:$thr]
	monitor::context [expr {600 + $::ui::ox}] [expr {$y + 20 + $::ui::oy}]
	set prio [lsearch -inline -index 0 [monitor::menu_rows pid:$thr] prio]
	check "the row menu has Priority, at the process's level (Normal)" [expr {[lindex $prio 2] eq "Priority" && [lindex $prio 3] eq "Normal" && [lindex $prio 4]}]
	click_hit {*menu_pick prio*}
	check "a click on Priority opens its submenu: Low, Normal (ticked), High" [expr {[dict get $::monitor::menu sub] && [lmap r [monitor::level_rows pid:$thr] {lrange $r 1 2}] eq {{Low 0} {Normal 1} {High 0}}}]
	click_hit {*menu_pick low*}
	check "Low renices every thread to 10" [expr {[wait_for [list expr "\[lsort -unique \[nices $thr\]\] eq {10}"] 3000] && [llength [nices $thr]] >= 4}]
	monitor::refresh
	set y [monitor::row_y pid:$thr]
	monitor::context [expr {600 + $::ui::ox}] [expr {$y + 20 + $::ui::oy}]
	check "the entry then reads Low" [expr {[lindex [lsearch -inline -index 0 [monitor::menu_rows pid:$thr] prio] 3] eq "Low"}]
	# Going back from Low to Normal raises the priority: root renices directly; anyone else is past RLIMIT_NICE's
	# floor and goes through pkexec, which only an administrator is offered. The stand-ins make this person one
	# (they change nothing for root, whose route is always direct).
	set root [expr {[lindex $::monitor::me 1] eq "0"}]
	script $T/pkexec "echo \"pkexec \$*\" >> $T/log; exec \"\$@\""
	set ::monitor::cmd(groups) [list echo users wheel]
	set ::monitor::cmd(pkexec) $T/pkexec
	unset -nocomplain ::monitor::is_admin
	# the keys: Down to Priority, Right into the submenu, Down to Normal, Return
	dict set ::monitor::menu hover pause
	monitor::key Down "" 0; monitor::key Right "" 0; monitor::key Down "" 0
	check "Right opens the submenu on its first level, Down moves in it" [expr {[dict get $::monitor::menu subhover] eq "normal"}]
	monitor::key Return "" 0
	if {$root} {
		check "Return on Normal puts every thread back to 0" [expr {[wait_for [list expr "\[lsort -unique \[nices $thr\]\] eq {0}"] 3000] && [log] eq ""}]
	} else {
		check "Return on Normal (not root) goes through pkexec renice 0 for every thread" [wait_for [list prio_logged 0 $thr] 3000]
		puts "  skip every thread back at 0 (not root: the pkexec stand-in cannot raise a priority; root checks it)"
	}
	monitor::refresh
	if {$root} {
		check "High (as root: renice itself) gives -5" [expr {[monitor::set_level pid:$thr high] eq "direct" && [lsort -unique [nices $thr]] eq {-5}}]
	} else {
		puts "  skip High as root renices itself (not root; this person's High through pkexec is checked below)"
	}
	exec kill -KILL $thr
	ui::fset search ""; monitor::search_changed; set ::monitor::menu ""
	file delete $T/log

	# a person who is not root, on a process at Normal: raising above RLIMIT_NICE's floor needs pkexec, and only an
	# administrator gets it (the process stays ours to signal: only the kernel's nice rule is played as another user)
	set thr [exec python3 -c {import threading,time
for i in range(3): threading.Thread(target=time.sleep, args=(300,), daemon=True).start()
time.sleep(300)} </dev/null >/dev/null 2>/dev/null &]
	wait_for [list expr "\[llength \[monitor::tasks_of $thr\]\] >= 4"] 3000
	monitor::refresh
	set keep $::monitor::me
	set ::monitor::me {1000 1000}
	rename ::monitor::row_signalable ::monitor::row_signalable_real
	proc ::monitor::row_signalable {key} { return [list [string range $key 4 end]] }
	set ::monitor::cmd(groups) [list echo users audio]
	unset -nocomplain ::monitor::is_admin
	check "not an administrator: High is muted, Low still offered" [expr {[lsort -unique [nices $thr]] eq {0} && [lmap r [monitor::level_rows pid:$thr] {lindex $r 3}] eq {1 1 0}}]
	set ::monitor::cmd(groups) [list echo users wheel]
	unset -nocomplain ::monitor::is_admin
	check "an administrator: High goes through pkexec renice -5 for every thread" [expr {[monitor::set_level pid:$thr high] eq "pkexec" && [wait_for [list prio_logged -5 $thr] 3000]}]
	if {$root} {
		check "and every thread is then at -5" [wait_for [list expr "\[lsort -unique \[nices $thr\]\] eq {-5}"] 3000]
	} else {
		puts "  skip every thread then at -5 (not root: the pkexec stand-in cannot raise a priority; root checks it)"
	}
	check "lowering again needs no pkexec" [expr {[monitor::prio_route $thr 10] eq "direct"}]
	set ::monitor::me $keep
	rename ::monitor::row_signalable {}
	rename ::monitor::row_signalable_real ::monitor::row_signalable
	exec kill -KILL $thr
	ui::fset search ""; monitor::search_changed; set ::monitor::menu ""

	# ---- the End sheet --------------------------------------------------------------------------------------------
	set a [sleeper]; set b [sleeper 1]
	monitor::refresh
	# the two as one app's processes (the live grouping would put sleep in Background)
	proc ::monitor::as_app {a b} {
		set apps [dict get $::monitor::model apps]
		lappend apps [dict create id testapp name "Test app" count 2 cpu 0.0 gpu 0.0 mem 0 disk 0 vram 0 pids [list $a $b]]
		dict set ::monitor::model apps $apps
		set procs {}
		foreach p [dict get $::monitor::model procs] { if {[dict get $p pid] in [list $a $b]} { dict set p appid testapp }; lappend procs $p }
		dict set ::monitor::model procs $procs
	}
	monitor::as_app $a $b
	check "End on a process that responds: no sheet" [expr {![monitor::end_ask pid:$a] && $::monitor::sheet eq ""}]
	set ::monitor::view apps; set ::monitor::sel app:testapp
	monitor::menu_open app:testapp 600 200
	click_hit {*menu_pick end*}
	check "End on an app with two processes opens the sheet listing both" [expr {$::monitor::sheet ne "" && [lsort [dict get $::monitor::sheet pids]] eq [lsort [list $a $b]] && [llength [monitor::sheet_rows]] == 2}]
	check "the sheet takes every click: the page under it has none" [expr {[lindex $::ui::hits end-2 4] ne "" && [has_hit *sheet_end*] && [has_hit *sheet_cancel*]}]
	click_hit {*sheet_cancel*}
	after 300 {set ::tick 1}; vwait ::tick
	check "Cancel closes it and signals nothing" [expr {$::monitor::sheet eq "" && [monitor::alive $a] && [monitor::alive $b]}]
	monitor::as_app $a $b
	monitor::end_ask app:testapp
	monitor::key Escape "" 0
	check "Escape is Cancel" [expr {$::monitor::sheet eq "" && [monitor::alive $a]}]
	monitor::as_app $a $b
	monitor::end_ask app:testapp
	click_hit {*sheet_end*}
	check "End ends the listed processes: SIGTERM at once" [wait_for [list expr "!\[monitor::alive $a\]"] 1500]
	check "and SIGKILL after the grace time for what ignores it" [wait_for [list expr "!\[monitor::alive $b\]"] 6000]
	# a process not responding asks first, even alone; the sheet says for how long
	set c [sleeper]
	monitor::refresh
	set ::monitor::stuck::since [dict create $c [expr {[clock milliseconds] - 12000}]]
	set procs {}
	foreach p [dict get $::monitor::model procs] { if {[dict get $p pid] == $c} { dict set p stuck 1 }; lappend procs $p }
	dict set ::monitor::model procs $procs
	check "End on a process not responding opens the sheet, 12 s" [expr {[monitor::end_ask pid:$c] && [dict get $::monitor::sheet stuck] == 12}]
	monitor::key Return "" 0
	check "Return on the sheet is End" [wait_for [list expr "!\[monitor::alive $c\]"] 1500]

	# ---- the strip ------------------------------------------------------------------------------------------------
	set d [sleeper]
	monitor::refresh
	set ::monitor::view apps
	set ::monitor::stuck::since [dict create $d [expr {[clock milliseconds] - 41000}]]
	set procs {}
	foreach p [dict get $::monitor::model procs] { if {[dict get $p pid] == $d} { dict set p stuck 1 }; lappend procs $p }
	dict set ::monitor::model procs $procs
	monitor::draw
	check "a process not responding: the strip, for its row, 41 s" [expr {[lrange [monitor::strip_row] 0 0] eq [list pid:$d] && [lindex [monitor::strip_row] 2] == 41 && [has_hit *strip_wait*] && [has_hit *strip_end*]}]
	check "the table's header and rows move down by the strip (72)" [expr {$::monitor::row_top == 225}]
	click_hit {*strip_end*}
	check "End on the strip opens the sheet for its row" [expr {$::monitor::sheet ne "" && [dict get $::monitor::sheet pids] eq [list $d]}]
	monitor::sheet_cancel
	click_hit {*strip_wait*}
	check "Wait puts the strip away and the table back up" [expr {[monitor::strip_row] eq "" && $::monitor::row_top == 153 && ![has_hit *strip_wait*]}]
	dict set ::monitor::model procs [lmap p [dict get $::monitor::model procs] {dict set p stuck 0}]
	monitor::strip_row
	check "once it responds, a later hang shows the strip again" [expr {$::monitor::waited eq {}}]
	set ::monitor::view processes
	dict set ::monitor::model procs [lmap p [dict get $::monitor::model procs] {expr {[dict get $p pid] == $d ? [dict set p stuck 1] : $p}}]
	check "in Processes there is no strip (the row comes first, tagged)" [expr {[monitor::strip_row] eq ""}]
	# ribbon-monitor --end PID: the sheet for its row once the first sample is in
	set ::monitor::end_pid $d
	monitor::draw
	check "--end PID opens the sheet for the row holding it" [expr {$::monitor::sheet ne "" && [dict get $::monitor::sheet pids] eq [list $d] && $::monitor::end_pid eq ""}]
	monitor::sheet_cancel
	exec kill -KILL $d

	# ---- Services -----------------------------------------------------------------------------------------------------
	set fx [file join $repo tests monitor-fixtures dinit-list-r4.txt]
	set sv [monitor::services::parse [monitor::slurp $fx]]
	check "dinitctl list: name, state and pid of each line" [expr {[lmap s $sv {list [dict get $s name] [dict get $s state] [dict get $s pid]}] eq {{boot running {}} {dbus running 1402} {pipewire running 1418} {wireplumber starting {}} {foot-server stopping 1466} {ribbon-notes-sync stopped {}} {syncthing failed {}}}}]
	# dinit marks a service started on its own (boot, or one started with `dinitctl start`) with [ ] in place of { }
	set marked [monitor::services::parse "\[\[+\]     \] boot\n\[\[ \]<<   \] syncthing\n\[\[+\]     \] sshd (pid: 711)\n\[{+}     \] loginready (has console)"]
	check "a service marked active (\[+\] rather than {+}) keeps its name and state" [expr {[lmap s $marked {list [dict get $s name] [dict get $s state] [dict get $s pid]}] eq {{boot running {}} {syncthing starting {}} {sshd running 711} {loginready running {}}}}]
	check "the session's shell and polkit agent (the person's own services) are not stopped or restarted from here" [expr {![monitor::services::can stop ribbon-shell running] && ![monitor::services::can restart ribbon-polkit running] && [monitor::services::can stop pipewire running]}]
	# pkexec takes the first action (in no set order) whose exec.path matches and whose exec.argv1, when it has one,
	# is the first argument: every verb must match exactly one action, the list without a password, the rest an admin's
	set pol [monitor::slurp [file join $repo srcpkgs ribbon-desktop files apps monitor policy org.ribbon.services.policy]]
	set acts [lrange [split [string map [list "<action " \x01] $pol] \x01] 1 end]
	set ok [expr {[llength $acts] > 0}]
	foreach verb {list start stop restart} {
		set hit {}
		foreach a $acts {
			if {![regexp {exec\.path">/usr/bin/ribbon-services-helper<} $a]} continue
			if {[regexp {exec\.argv1">([^<]*)<} $a -> v1] && $v1 ne $verb} continue
			lappend hit $a
		}
		if {[llength $hit] != 1} { set ok 0; continue }
		regexp {<allow_active>([^<]*)<} [lindex $hit 0] -> active
		if {$verb eq "list" ? $active ne "yes" : ![string match auth_admin* $active]} { set ok 0 }
	}
	check "the polkit policy: one action for each of list, start, stop, restart (list without a password)" $ok
	script $T/dinitctl "echo \"\$*\" >> $T/log
case \"\$*\" in *list) cat '$fx' ;; *' stop dbus'|*' restart boot') exit 1 ;; esac"
	set ::monitor::services::cmd(dinitctl) $T/dinitctl
	file delete $T/log
	monitor::services_open
	check "the rail's Services row opens the page; the list is read in the background" [expr {$::monitor::metric eq "services" && [wait_for {expr {[llength $::monitor::svc_list] == 7}} 3000]}]
	check "the person's own: dinitctl --user list" [expr {[log] eq "--user list"}]
	monitor::draw
	click_hit {*services_select pipewire*}
	check "a running service selected: Restart and Stop" [expr {[has_hit *services_do\ restart\ pipewire*] && [has_hit *services_do\ stop\ pipewire*] && ![has_hit *services_do\ start*]}]
	click_hit {*services_do stop pipewire*}
	check "Stop: dinitctl --user stop pipewire, then the list again" [wait_for {expr {[string match "*--user stop pipewire\n--user list" [log]]}} 3000]
	click_hit {*services_select syncthing*}
	check "a failed one: Start only" [expr {[has_hit *services_do\ start\ syncthing*] && ![has_hit *services_do\ stop*]}]
	click_hit {*services_select dbus*}
	check "what the session stands on: no Stop or Restart" [expr {![has_hit *services_do*]}]
	check "and the library refuses it too" [expr {![monitor::services::act user stop dbus] && ![monitor::services::act user start {bad name}]}]
	# the system's: through the real helper under pkexec (stood in for)
	script $T/pk "exec env RIBBON_SERVICES_TEST=1 RIBBON_SERVICES_DINITCTL=$T/dinitctl \"\$@\""
	array set ::monitor::services::cmd [list pkexec $T/pk helper [file join $repo srcpkgs ribbon-desktop files apps monitor bin ribbon-services-helper]]
	file delete $T/log
	monitor::draw
	click [expr {1200 - 30}] 53
	check "System: the helper's list" [expr {$::monitor::svc_scope eq "system" && [wait_for {expr {[llength $::monitor::svc_list] == 7}} 3000] && [log] eq "list"}]
	click_hit {*services_select pipewire*}
	click_hit {*services_do restart pipewire*}
	check "Restart on the system's: the helper runs dinitctl restart pipewire" [wait_for {expr {[string match "*restart pipewire*" [log]]}} 3000]
	set h [lindex $::monitor::services::cmd(helper) 0]
	check "the helper refuses to stop dbus or boot, a bad name, and extra words" [expr {
		[catch {exec env RIBBON_SERVICES_TEST=1 RIBBON_SERVICES_DINITCTL=$T/dinitctl $h stop dbus 2>/dev/null}] &&
		[catch {exec env RIBBON_SERVICES_TEST=1 RIBBON_SERVICES_DINITCTL=$T/dinitctl $h restart early-udev 2>/dev/null}] &&
		[catch {exec env RIBBON_SERVICES_TEST=1 RIBBON_SERVICES_DINITCTL=$T/dinitctl $h start -x 2>/dev/null}] &&
		[catch {exec env RIBBON_SERVICES_TEST=1 RIBBON_SERVICES_DINITCTL=$T/dinitctl $h list extra 2>/dev/null}] &&
		![string match "*dbus*" [log]]}]
	check "the helper starts a stopped service" [expr {![catch {exec env RIBBON_SERVICES_TEST=1 RIBBON_SERVICES_DINITCTL=$T/dinitctl $h start sshd}] && [string match "*start sshd" [log]]}]
	check "and outside a test it runs only as root (under pkexec)" [expr {[catch {exec env PKEXEC_UID=1000 RIBBON_SERVICES_TEST=1 RIBBON_SERVICES_DINITCTL=/bin/true setpriv --reuid=65534 --regid=65534 --clear-groups $h list 2>/dev/null}]}]
	click 100 100
	check "the Apps row leaves Services" [expr {$::monitor::metric eq "apps"}]
}

after 300 {
	if {[catch run err]} { puts "  FAIL error: $err\n$::errorInfo"; incr ::fails }
	puts [expr {$::fails ? "monitor-r4: checks failed" : "monitor-r4: all checks passed"}]
	exit [expr {$::fails ? 1 : 0}]
}
