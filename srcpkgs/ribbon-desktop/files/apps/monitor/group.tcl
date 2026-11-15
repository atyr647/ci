# group.tcl - System monitor: grouping processes into apps (U24).
#
# An app is found, for each process, by walking up its parent chain (the process, then
# its parent, ...) and taking the first ancestor that says which app it is:
#   1. a kit's sandbox: kit run records each launch (ribbon-kit's sandbox.tcl) in
#      $XDG_RUNTIME_DIR/kit/sandbox/<pid of kit run>/, with the kit's name and bubblewrap's
#      --info-fd report; every process in the sandbox shares its pid namespace, and kit run
#      itself is the record's pid. The app is the kit: named by the launcher entry kit
#      exported for it (Exec=kit run NAME), else by the kit's short name.
#   2. a command name that a .desktop file's Exec= names (argv0, then comm).
# A process with no such ancestor is Background. (No launcher on this base, dinit and elogind,
# makes systemd's app-<id>-<n>.scope cgroups, so they are not read.)

namespace eval monitor::group {
	variable dirs [list [file join [expr {[info exists ::env(XDG_DATA_HOME)] && $::env(XDG_DATA_HOME) ne "" ? $::env(XDG_DATA_HOME) :
		[file join [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/"}] .local share]}] applications] \
		/usr/local/share/applications /usr/share/applications]
	# where kit run records its launches ("" for none)
	variable sandboxes [expr {[info exists ::env(XDG_RUNTIME_DIR)] && $::env(XDG_RUNTIME_DIR) ne "" ?
		[file join $::env(XDG_RUNTIME_DIR) kit sandbox] : ""}]
	# programs that start other programs: a .desktop file that runs one of these names no program
	# (kit's own entries, Exec=kit run NAME, name the kit NAME instead: "kit:NAME"); an interpreter's versioned
	# name (tclsh9.0, wish9.1, python3.12, perl5.40) is one too
	variable wrappers {sh bash dash zsh env python python3 perl ruby java wine tclsh wish flatpak pkexec sudo
		xdg-open gtk-launch dbus-launch dbus-run-session steam-runtime-launch-client kit}
	variable read {}       ;# the last answer of desktops: {folders-and-their-times map}
}

# .desktop files in the given folders: dict exec-name -> {id ID name NAME}. Only the [Desktop Entry] section is
# read. The program is Exec's first word, past a leading "env" and its NAME=VALUE words. A file whose program is a
# shell, an interpreter or another wrapper names no program of its own and is left out (every shell script would
# be that app). When several files start the same program, the plainest one names it: shown in the menu and with
# the fewest arguments ("foot", not "foot --server"); the first file wins a tie. The files are read again only when
# a folder's time has changed (a file added, removed or replaced, as packages do): the sampler asks every second.
proc monitor::group::desktops {{dirs ""}} {
	variable wrappers
	variable read
	if {$dirs eq ""} { set dirs $::monitor::group::dirs }
	set stamp [lmap dir $dirs {list $dir [expr {[catch {file mtime $dir} t] ? "" : $t}]}]
	if {[lindex $read 0] eq $stamp} { return [lindex $read 1] }
	set map [dict create]
	set rank [dict create]
	foreach dir $dirs {
		foreach f [lsort [glob -nocomplain [file join $dir *.desktop]]] {
			set id [file rootname [file tail $f]]
			set name ""; set exec ""; set in 0; set hidden 0
			foreach line [split [::monitor::slurp $f] \n] {
				if {[regexp {^\[(.*)\]} $line -> sec]} { set in [expr {$sec eq "Desktop Entry"}]; continue }
				if {!$in} continue
				if {[regexp {^Name=(.*)$} $line -> v] && $name eq ""} { set name [string trim $v] }
				if {[regexp {^Exec=(.*)$} $line -> v] && $exec eq ""} { set exec [string trim $v] }
				if {[regexp {^NoDisplay=\s*true} $line]} { set hidden 1 }
			}
			set words [regexp -all -inline {\S+} $exec]
			if {[file tail [string trim [lindex $words 0] "\"'"]] eq "env"} {
				set words [lrange $words 1 end]
				while {[regexp {^[A-Za-z_][A-Za-z0-9_]*=} [lindex $words 0]]} { set words [lrange $words 1 end] }
			}
			set prog [file tail [string trim [lindex $words 0] "\"'"]]
			if {$prog eq "kit" && [lindex $words 1] eq "run" && [regexp {^[a-z0-9][a-z0-9.-]*$} [lindex $words 2]]} {
				set prog kit:[lindex $words 2]
			} elseif {$prog eq "" || $prog in $wrappers || [regexp {^(tclsh|wish|python|perl|ruby)[0-9][0-9.]*$} $prog]} continue
			set n [expr {$hidden ? 100 : 0}]
			foreach w [lrange $words 1 end] { if {![regexp {^%[A-Za-z]$} $w]} { incr n } }
			if {[dict exists $rank $prog] && [dict get $rank $prog] <= $n} continue
			if {$name eq ""} { set name $id }
			dict set map $prog [dict create id $id name $name]
			dict set rank $prog $n
		}
	}
	set read [list $stamp $map]
	return $map
}

# The kits running in sandboxes: {byns {NS app ...} bypid {PID app ...}}, from kit run's records
# (an app is {id ID name NAME}). A record counts only while its pid is still kit run (a record
# left by a killed one names nothing, even when its pid or namespace number is reused); one
# that bubblewrap has not filled in yet names kit run alone.
proc monitor::group::kits {desktops} {
	variable sandboxes
	set byns [dict create]; set bypid [dict create]
	if {$sandboxes eq ""} { return [list byns $byns bypid $bypid] }
	foreach r [glob -nocomplain -directory $sandboxes -types d *] {
		set pid [file tail $r]
		if {![string is integer -strict $pid]} continue
		if {![regexp {(?:^|/|\x00)kit\x00run\x00} [::monitor::slurp [file join $::monitor::proc_root $pid cmdline]]]} continue
		if {[catch {dict get [::monitor::slurp [file join $r kit]] name} name] || ![regexp {^[a-z0-9][a-z0-9.-]*$} $name]} continue
		set short [expr {[catch {dict get [::monitor::slurp [file join $r kit]] short} s] || $s eq "" ? $name : $s}]
		if {[dict exists $desktops kit:$name]} {
			set app [dict get $desktops kit:$name]
		} else {
			set app [dict create id $name name $short]
		}
		dict set bypid $pid $app
		if {[regexp {"pid-namespace"\s*:\s*(\d+)} [::monitor::slurp [file join $r info]] -> ns]} { dict set byns $ns $app }
	}
	return [list byns $byns bypid $bypid]
}

# The pid namespace a process is in (the number of /proc/PID/ns/pid), or "".
proc monitor::group::pidns {pid} {
	if {[catch {file readlink [file join $::monitor::proc_root $pid ns pid]} l] || ![regexp {^pid:\[(\d+)\]$} $l -> ns]} { return "" }
	return $ns
}

# The app a single process names, or "" when it names none. kits: what kits says.
proc monitor::group::match {p desktops {kits {}}} {
	if {[llength $kits]} {
		if {[dict exists $kits bypid [dict get $p pid]]} { return [dict get $kits bypid [dict get $p pid]] }
		if {[dict size [dict get $kits byns]]} {
			set ns [pidns [dict get $p pid]]
			if {$ns ne "" && [dict exists $kits byns $ns]} { return [dict get $kits byns $ns] }
		}
	}
	foreach n [list [dict get $p exe] [dict get $p comm]] {
		if {$n ne "" && [dict exists $desktops $n]} { return [dict get $desktops $n] }
	}
	return ""
}

# procs: the dicts from monitor::scan (pid ppid comm exe cgroup). Returns a list of
# dicts {id ID name NAME pids {PID ...}}, the Background app last with id "".
proc monitor::group::assign {procs desktops} {
	set kits [kits $desktops]
	if {![dict size [dict get $kits bypid]]} { set kits {} }
	array set by_pid {}
	foreach p $procs { set by_pid([dict get $p pid]) $p }
	array set apps {}
	array set names {}
	foreach p $procs {
		set app ""
		set cur $p
		for {set depth 0} {$depth < 32} {incr depth} {
			set m [match $cur $desktops $kits]
			if {$m ne ""} { set app $m; break }
			set ppid [dict get $cur ppid]
			if {![info exists by_pid($ppid)]} break
			set cur $by_pid($ppid)
		}
		set id [expr {$app eq "" ? "" : [dict get $app id]}]
		set names($id) [expr {$app eq "" ? "Background" : [dict get $app name]}]
		lappend apps($id) [dict get $p pid]
	}
	set out {}
	foreach id [lsort [array names apps]] {
		lappend out [dict create id $id name $names($id) pids $apps($id)]
	}
	return $out
}
