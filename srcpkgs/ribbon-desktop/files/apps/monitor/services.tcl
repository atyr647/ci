# services.tcl - System monitor: dinit's services (Monitor-R4-Services), the person's own (`dinitctl --user`, the
# instance turnstile starts at login) or the system's. No Tk here: the page is servicespage.tcl.
#
# The system's dinit answers only root on its control socket, so the system's list and its Start, Stop and Restart
# go through ribbon-services-helper under pkexec (policy/org.ribbon.services.policy: the list is allowed for the
# person at the machine without a password, a change asks for an administrator's). The services the session stands
# on (boot, system, loginready, dbus, elogind, greetd, turnstiled, udevd, recovery, early-*; the person's own
# ribbon-shell and ribbon-polkit) are never stopped or restarted from here; the helper refuses the system's too.
#
# `dinitctl list` prints a line per service:
#   [{+}     ] dbus (pid: 1402)        started, its target started
#   [     {-}] sshd                    stopped
#   [{ }<<   ] chronyd                 starting (an "s" for "+": started, skipped)
#   [   >>{ }] cupsd                   stopping
#   [     {X}] syncthing (exit status: 1)   failed to start
#   [[+]     ] boot                    started, marked active (started on its own, not as a dependency)
# The first three columns are the started side, the last three the stopped side; braces mark the target state,
# square brackets a service marked active.
#
#   monitor::services::parse TEXT          {name state pid} dicts; state running starting stopping stopped failed
#   monitor::services::fetch SCOPE ?CB?    the list for user or system (CB: called later with it); "" when it cannot be had
#   monitor::services::act SCOPE VERB NAME ?CB?   start, stop or restart; CB gets 1 or 0
#   monitor::services::can SCOPE VERB NAME is the action offered for the service

namespace eval monitor::services {
	variable cmd
	array set cmd {dinitctl dinitctl pkexec pkexec helper /usr/bin/ribbon-services-helper}
	variable protected {boot system loginready dbus elogind greetd turnstiled udevd recovery early-* ribbon-shell ribbon-polkit}
}

proc monitor::services::parse {text} {
	set out {}
	foreach line [split $text \n] {
		# the columns between the outer brackets may hold a bracketed one themselves ("[[+]     ] boot")
		if {![regexp {^\s*\[((?:\[[^]]*\]|[^][])*)\]\s+(\S+)(.*)$} $line -> st name rest]} continue
		set started [string range $st 0 2]
		set state stopped
		if {[regexp {[+s]} $started]} { set state running } \
		elseif {[string first X $st] >= 0} { set state failed } \
		elseif {[string first << $st] >= 0} { set state starting } \
		elseif {[string first >> $st] >= 0} { set state stopping }
		set pid ""
		regexp {\(pid: (\d+)\)} $rest -> pid
		lappend out [dict create name $name state $state pid $pid running [expr {$state eq "running"}]]
	}
	return $out
}

# The command that lists or changes the services of a scope.
proc monitor::services::argv {scope args} {
	variable cmd
	if {$scope eq "user"} { return [list {*}$cmd(dinitctl) --user {*}$args] }
	return [list {*}$cmd(pkexec) {*}$cmd(helper) {*}$args]
}

proc monitor::services::available {scope} {
	variable cmd
	if {$scope eq "user"} { return [expr {[auto_execok [lindex $cmd(dinitctl) 0]] ne ""}] }
	expr {[auto_execok [lindex $cmd(pkexec) 0]] ne "" && [file executable [lindex $cmd(helper) 0]]}
}

# The list now (no CB), or read in the background and handed to CB. "" when it cannot be had.
proc monitor::services::fetch {scope {cb ""}} {
	if {![available $scope]} { if {$cb ne ""} { after 0 [list {*}$cb ""] }; return "" }
	set argv [argv $scope list]
	if {$cb eq ""} {
		if {[catch {set text [::exec {*}$argv 2>/dev/null]}]} { return "" }
		return [parse $text]
	}
	if {[catch {::open |[concat $argv [list 2>/dev/null]] r} ch]} { after 0 [list {*}$cb ""]; return "" }
	fconfigure $ch -blocking 0 -encoding utf-8
	fileevent $ch readable [list monitor::services::read_list $ch "" $cb]
	return ""
}
proc monitor::services::read_list {ch acc cb} {
	append acc [::read $ch]
	if {![eof $ch]} { fileevent $ch readable [list monitor::services::read_list $ch $acc $cb]; return }
	fconfigure $ch -blocking 1
	set ok [expr {![catch {::close $ch}]}]
	{*}$cb [expr {$ok || [string trim $acc] ne "" ? [parse $acc] : ""}]
}

proc monitor::services::protected {name} {
	variable protected
	foreach p $protected { if {[string match $p $name]} { return 1 } }
	return 0
}

# Is VERB offered for a service in STATE: Start for one not running, Stop and Restart for one that is (not for the
# services the session stands on).
proc monitor::services::can {verb name state} {
	switch -- $verb {
		start { return [expr {$state in {stopped failed}}] }
		stop - restart { return [expr {$state in {running starting} && ![protected $name]}] }
	}
	return 0
}

# Start, stop or restart: in the background, CB gets 1 when dinit did it.
proc monitor::services::act {scope verb name {cb ""}} {
	if {$verb ni {start stop restart} || ![regexp {^[A-Za-z0-9_][A-Za-z0-9@._+-]*$} $name]} { return 0 }
	if {$verb ne "start" && [protected $name]} { return 0 }
	if {[catch {::open |[concat [argv $scope $verb $name] [list 2>/dev/null]] r} ch]} { if {$cb ne ""} { {*}$cb 0 }; return 0 }
	fconfigure $ch -blocking 0
	fileevent $ch readable [list monitor::services::acted $ch $cb]
	return 1
}
proc monitor::services::acted {ch cb} {
	::read $ch
	if {![eof $ch]} return
	fconfigure $ch -blocking 1
	set ok [expr {![catch {::close $ch}]}]
	if {$cb ne ""} { {*}$cb $ok }
}
