# proc.tcl - System monitor (ribbon-monitor): readers for /proc, and the sampler
# that turns two samples into rates. No UI here (U24); main.tcl draws it.
#
#   monitor::sample        one snapshot: whole-system counters and every process
#   monitor::rates P C     rates between two snapshots (CPU %, bytes/s, per process)
#   monitor::signal PIDS SIG ?STARTS?, monitor::end PIDS, monitor::alive PID, monitor::signalable PIDS
#
# Roots are variables so tests point them at fixture trees (tests/monitor-fixtures).
# Per-process network is not in /proc, so a process carries no network rate.

namespace eval monitor {
	variable proc_root /proc
	variable sys_root /sys
	variable clk 100       ;# USER_HZ: procfs counts clock ticks at 100 a second on every Linux
	variable page 4096     ;# bytes per page (statm counts pages)
	variable kill kill     ;# the command that sends a signal
	variable self [pid]    ;# this process
	variable me ""         ;# our real and effective uid ("": read from /proc/self/status when first needed)
}

# The whole file as text, or "" when it cannot be read (a process may exit mid-scan).
proc monitor::slurp {path} {
	if {[catch {
		set f [::open $path r]
		set d [::read $f]
		::close $f
	}]} { return "" }
	return $d
}

# "cpu  user nice system idle iowait irq softirq steal ..." and one line per CPU.
proc monitor::parse_stat {text} {
	set busy 0; set total 0; set ncpu 0
	foreach line [split $text \n] {
		if {[regexp {^cpu\s+(.*)$} $line -> rest]} {
			lassign [concat $rest {0 0 0 0 0 0 0 0}] user nice sys idle iowait irq softirq steal
			set total [expr {$user + $nice + $sys + $idle + $iowait + $irq + $softirq + $steal}]
			set busy [expr {$total - $idle - $iowait}]
		} elseif {[regexp {^cpu\d+\s} $line]} {
			incr ncpu
		}
	}
	return [dict create busy $busy total $total ncpu $ncpu]
}

# Bytes, keyed by the field name (MemTotal, MemAvailable, SwapFree, ...).
proc monitor::parse_meminfo {text} {
	set d [dict create]
	foreach line [split $text \n] {
		if {[regexp {^(\w+):\s+(\d+)} $line -> k v]} { dict set d $k [expr {$v * 1024}] }
	}
	return $d
}

# Received and sent bytes, summed over every interface but lo.
proc monitor::parse_netdev {text} {
	set rx 0; set tx 0
	foreach line [split $text \n] {
		if {![regexp {^\s*([^:\s]+):\s*(.*)$} $line -> ifc rest]} continue
		if {$ifc eq "lo"} continue
		incr rx [lindex $rest 0]
		incr tx [lindex $rest 8]
	}
	return [dict create rx $rx tx $tx]
}

# Sectors read and written, summed over whole disks (sd*, vd*, hd*, xvd*, nvme*n*), 512 bytes a sector.
proc monitor::parse_diskstats {text} {
	set rd 0; set wr 0
	foreach line [split $text \n] {
		set f [regexp -all -inline {\S+} $line]
		if {[llength $f] < 10} continue
		if {![regexp {^(sd[a-z]+|vd[a-z]+|hd[a-z]+|xvd[a-z]+|nvme\d+n\d+)$} [lindex $f 2]]} continue
		incr rd [expr {[lindex $f 5] * 512}]
		incr wr [expr {[lindex $f 9] * 512}]
	}
	return [dict create read $rd write $wr]
}

# /proc/PID/stat. comm sits in parentheses and may hold spaces and ")", so it is cut at the outer ones.
proc monitor::parse_pid_stat {text} {
	set l [string first "(" $text]
	set r [string last ")" $text]
	if {$l < 0 || $r < $l} { return "" }
	set comm [string range $text [expr {$l + 1}] [expr {$r - 1}]]
	set f [regexp -all -inline {\S+} [string range $text [expr {$r + 1}] end]]
	# f[0] is field 3 (state); utime is field 14, stime 15, num_threads 20, starttime 22
	return [dict create comm $comm state [lindex $f 0] ppid [lindex $f 1] \
		utime [lindex $f 11] stime [lindex $f 12] threads [lindex $f 17] start [lindex $f 19]]
}

# Resident pages, from /proc/PID/statm (second field).
proc monitor::parse_statm {text} {
	set n [lindex [regexp -all -inline {\S+} $text] 1]
	return [expr {[string is integer -strict $n] ? $n : 0}]
}

# read_bytes and write_bytes from /proc/PID/io (0 when the file is not readable).
proc monitor::parse_io {text} {
	set rd 0; set wr 0
	regexp {read_bytes:\s*(\d+)} $text -> rd
	regexp {write_bytes:\s*(\d+)} $text -> wr
	return [dict create read $rd write $wr]
}

# The cgroup's leaf name from /proc/PID/cgroup ("0::/user.slice/.../app-steam-1.scope").
proc monitor::parse_cgroup {text} {
	set path ""
	regexp {(?m)^0::(\S+)} $text -> path
	return [file tail $path]
}

# argv of /proc/PID/cmdline (NUL-separated), joined with spaces.
proc monitor::parse_cmdline {raw} {
	return [string trim [join [split [string trimright $raw \0] \0] " "]]
}

# Every numeric entry under proc_root: one dict per process that could be read.
proc monitor::scan {} {
	variable proc_root
	variable page
	set out {}
	foreach name [glob -nocomplain -directory $proc_root -tails -types d *] {
		if {![string is integer -strict $name]} continue
		set base [file join $proc_root $name]
		set st [parse_pid_stat [slurp [file join $base stat]]]
		if {$st eq ""} continue
		set cmd [parse_cmdline [slurp [file join $base cmdline]]]
		# argv0 by a regexp, not lindex: a command line may hold unbalanced quotes
		set argv0 ""
		regexp {^(\S+)} $cmd -> argv0
		set argv0 [file tail $argv0]
		if {$argv0 eq ""} { set argv0 [dict get $st comm] }
		set io [parse_io [slurp [file join $base io]]]
		lappend out [dict create pid $name ppid [dict get $st ppid] comm [dict get $st comm] \
			exe $argv0 cmd $cmd state [dict get $st state] threads [dict get $st threads] start [dict get $st start] \
			ticks [expr {[dict get $st utime] + [dict get $st stime]}] \
			rss [expr {[parse_statm [slurp [file join $base statm]]] * $page}] \
			disk [expr {[dict get $io read] + [dict get $io write]}] \
			cgroup [parse_cgroup [slurp [file join $base cgroup]]]]
	}
	return $out
}

# One snapshot of the whole system. Time is in milliseconds.
proc monitor::sample {} {
	variable proc_root
	return [dict create time [clock milliseconds] \
		cpu [parse_stat [slurp [file join $proc_root stat]]] \
		mem [parse_meminfo [slurp [file join $proc_root meminfo]]] \
		net [parse_netdev [slurp [file join $proc_root net dev]]] \
		disk [parse_diskstats [slurp [file join $proc_root diskstats]]] \
		procs [scan]]
}

# Rates between two snapshots. cpu is the whole machine in percent; each process's cpu is
# its share of the whole machine too (so the rows add up to the machine's figure), and a
# process that was not in the previous snapshot has no rate yet.
proc monitor::rates {prev cur} {
	variable clk
	variable page
	set dt [expr {([dict get $cur time] - [dict get $prev time]) / 1000.0}]
	if {$dt <= 0} { set dt 1.0 }
	set pc [dict get $prev cpu]; set cc [dict get $cur cpu]
	set dtot [expr {[dict get $cc total] - [dict get $pc total]}]
	set dbusy [expr {[dict get $cc busy] - [dict get $pc busy]}]
	set ncpu [dict get $cc ncpu]; if {$ncpu < 1} { set ncpu 1 }
	set cpu [expr {$dtot > 0 ? 100.0 * $dbusy / $dtot : 0.0}]
	set pn [dict get $prev net]; set cn [dict get $cur net]
	set pd [dict get $prev disk]; set cd [dict get $cur disk]
	set before [dict create]
	foreach p [dict get $prev procs] { dict set before [dict get $p pid] $p }
	set procs {}
	foreach p [dict get $cur procs] {
		set pid [dict get $p pid]
		set pct 0.0; set dsk 0.0
		if {[dict exists $before $pid]} {
			set q [dict get $before $pid]
			set pct [expr {100.0 * ([dict get $p ticks] - [dict get $q ticks]) / $clk / $dt / $ncpu}]
			set dsk [expr {([dict get $p disk] - [dict get $q disk]) / $dt}]
		}
		dict set p cpu [expr {max(0.0, $pct)}]
		dict set p disk_rate [expr {max(0.0, $dsk)}]
		lappend procs $p
	}
	return [dict create cpu [expr {max(0.0, $cpu)}] ncpu $ncpu \
		mem [dict get $cur mem] \
		net_rx [expr {max(0.0, ([dict get $cn rx] - [dict get $pn rx]) / $dt)}] \
		net_tx [expr {max(0.0, ([dict get $cn tx] - [dict get $pn tx]) / $dt)}] \
		disk_rd [expr {max(0.0, ([dict get $cd read] - [dict get $pd read]) / $dt)}] \
		disk_wr [expr {max(0.0, ([dict get $cd write] - [dict get $pd write]) / $dt)}] \
		procs $procs]
}

# Is the process still running? A zombie has exited, so it does not count.
proc monitor::alive {pid} {
	variable proc_root
	set st [parse_pid_stat [slurp [file join $proc_root $pid stat]]]
	if {$st eq ""} { return 0 }
	return [expr {[dict get $st state] ni {Z X x}}]
}

# A process's start time (clock ticks after boot): with its pid it names one process, as the pid of a process that
# has gone may be given to a new one. "" when it is gone.
proc monitor::start_of {pid} {
	variable proc_root
	set st [parse_pid_stat [slurp [file join $proc_root $pid stat]]]
	return [expr {$st eq "" ? "" : [dict get $st start]}]
}

# dict pid -> start time, of the pids that are there now.
proc monitor::idents {pids} {
	set out [dict create]
	foreach p $pids { set s [start_of $p]; if {$s ne ""} { dict set out $p $s } }
	return $out
}

# The processes never signalled: init, this monitor and the processes it runs under, and the session's compositor
# (labwc) and shell (ribbon-shell). Ending one of them ends the session or the monitor itself.
proc monitor::protected {pid {above ""}} {
	variable self
	if {$pid == 1 || $pid == $self} { return 1 }
	if {$above eq ""} { set above [ancestors] }
	if {$pid in $above} { return 1 }
	variable proc_root
	set st [parse_pid_stat [slurp [file join $proc_root $pid stat]]]
	if {$st ne "" && [dict get $st comm] eq "labwc"} { return 1 }
	set argv [split [string trimright [slurp [file join $proc_root $pid cmdline]] \0] \0]
	if {[file tail [lindex $argv 0]] eq "ribbon-shell"} { return 1 }
	set i [lsearch -exact $argv -name]
	return [expr {$i >= 0 && [lindex $argv $i+1] eq "ribbon-shell"}]
}

# The processes this monitor runs under: its parent, the parent's parent, ... (init left out).
proc monitor::ancestors {} {
	variable proc_root
	variable self
	set out {}
	set cur $self
	for {set depth 0} {$depth < 64} {incr depth} {
		set st [parse_pid_stat [slurp [file join $proc_root $cur stat]]]
		if {$st eq "" || [dict get $st ppid] <= 1} break
		set cur [dict get $st ppid]
		lappend out $cur
	}
	return $out
}

# May we signal the process? Root may signal any; another user may signal a process whose real or saved uid is
# its real or effective uid (kill(2)).
proc monitor::permitted {pid} {
	variable proc_root
	variable me
	if {$me eq ""} {
		regexp {(?m)^Uid:\s+(\d+)\s+(\d+)} [slurp /proc/self/status] -> r e
		set me [expr {[info exists e] ? [list $r $e] : {0 0}}]
	}
	lassign $me ruid euid
	if {$euid == 0} { return 1 }
	if {![regexp {(?m)^Uid:\s+(\d+)\s+\d+\s+(\d+)} [slurp [file join $proc_root $pid status]] -> tr ts]} { return 0 }
	return [expr {$tr in [list $ruid $euid] || $ts in [list $ruid $euid]}]
}

# The pids of the list that may be signalled: there, ours to signal, and not protected.
proc monitor::signalable {pids} {
	set out {}
	set above [ancestors]
	foreach p $pids { if {[start_of $p] ne "" && [permitted $p] && ![protected $p $above]} { lappend out $p } }
	return $out
}

# Send a signal (a name such as STOP, CONT, TERM or KILL) to each pid that may be signalled. STARTS (dict pid ->
# start time, see idents) names the processes meant: a pid whose process has another start time now is not sent.
proc monitor::signal {pids sig {starts ""}} {
	variable kill
	set sent {}
	foreach p [signalable $pids] {
		if {[dict exists $starts $p] && [start_of $p] ne [dict get $starts $p]} continue
		if {[catch {::exec {*}$kill -$sig $p}]} continue
		lappend sent $p
	}
	return $sent
}

# End: TERM, then KILL whatever is still alive after the grace period (milliseconds).
# Returns the pids that needed KILL.
proc monitor::end {pids {grace 2000}} {
	set ids [idents $pids]
	set pids [signal $pids TERM $ids]
	set until [expr {[clock milliseconds] + $grace}]
	while {1} {
		set left {}
		foreach p $pids { if {[alive $p] && [start_of $p] eq [dict get $ids $p]} { lappend left $p } }
		if {![llength $left]} { return {} }
		if {[clock milliseconds] >= $until} break
		after 50
	}
	return [signal $left KILL $ids]
}
