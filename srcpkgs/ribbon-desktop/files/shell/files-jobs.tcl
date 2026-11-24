# files-jobs.tcl - Ribbon Files' copies and moves as one job the person can follow:
# a notification with the progress, Pause and Cancel (Notify-Final-3-Progress), and
# a last one when the job is done. The queue itself (files::queue, run_next, op_read,
# op_finish) is in files.tcl; this file keeps the job's numbers and talks to the
# notification server.
#
# A job starts when the queue starts from idle and ends when it is empty again; a
# paste or drop while it runs joins it. Its size is the sum of its items' sizes,
# measured as they are queued (a file's size at once, a folder's by du in the
# background); fileop_sh reports the bytes copied so far ("done N" lines).
#
# The notification goes to org.freedesktop.Notifications on the session bus (the
# shell's own server, or whichever one owns the name) with the value hint, the
# x-ribbon-progress-text hint ("1.2 of 3.4 GB") and the actions pause/resume and
# cancel. Pause stops the helper and everything under it (SIGSTOP), Resume goes on
# (SIGCONT), Cancel kills them and drops the job's queued items; the next look at
# the folders removes what a killed copy left (files::clear_parts).
#
#   files::notify_send ID SUMMARY BODY ACTIONS HINTS CB   (tests replace it)
#   files::job_action KEY     pause, resume or cancel

namespace eval files {
	variable job {}          ;# the running job (dict), {} when the queue is idle
	variable opbytes         ;# dst -> its item's size in bytes, once known
	array set opbytes {}
	variable nbus ""         ;# the bus the notifications went to, once listened on
	variable nlast 0         ;# when the notification was last sent (ms)
	variable nafter ""
	variable cancelled {}    ;# destinations of killed operations whose end is not reported
}

# ---- sizes -----------------------------------------------------------------------

# Measure SRC for DST's item: a file at once, anything else with du in the background.
proc files::measure {src dst} {
	variable opbytes
	if {![catch {file lstat $src s}] && $s(type) ne "directory"} {
		set opbytes($dst) $s(size)
		return
	}
	if {[catch {::open |[list du -sb -- $src 2>/dev/null]} fh]} return
	fconfigure $fh -blocking 0
	fileevent $fh readable [list files::measured $fh $dst]
}

proc files::measured {fh dst} {
	variable opbytes
	variable job
	set line [gets $fh]
	if {[regexp {^(\d+)} $line -> b]} { set opbytes($dst) $b }
	if {[eof $fh] || [regexp {^\d+} $line]} {
		catch {::close $fh}
		if {[llength $job]} { job_notify }
	}
}

# "1.2 of 3.4 GB": the bytes done in the unit of the total.
proc files::of {done total} {
	set unit B; set n 1
	foreach {u v} {TB 1e12 GB 1e9 MB 1e6 KB 1e3} { if {$total >= $v} { set unit $u; set n $v; break } }
	if {$unit eq "B"} { return "$done of $total B" }
	set a [::format %.1f [expr {$done / $n}]]; set b [::format %.1f [expr {$total / $n}]]
	return "[regsub {\.0$} $a {}] of [regsub {\.0$} $b {}] $unit"
}

# "3 items · Hades II, Proton-GE 9-20 and saves.zip"; one item is its name.
proc files::itemline {names} {
	set n [llength $names]
	if {$n == 1} { return [lindex $names 0] }
	if {$n <= 3} {
		return "$n items · [join [lrange $names 0 end-1] {, }] and [lindex $names end]"
	}
	return "$n items · [join [lrange $names 0 1] {, }] and [expr {$n - 2}] more"
}

# What the destination folder is called in the notification: a drive's name at a drive's root.
proc files::destlabel {dir} {
	set dir [file normalize $dir]
	if {$dir eq [file normalize [home]]} { return Home }
	if {![catch {drives} ds]} {
		foreach d $ds { lassign $d label path; if {$path ne "" && [file normalize $path] eq $dir} { return $label } }
	}
	if {$dir eq "/"} { return System }
	return [file tail $dir]
}

# ---- the job -------------------------------------------------------------------------

# An operation joins the job (the queue calls this for each copy or move it takes).
proc files::job_add {verb name dst src} {
	variable job
	if {![llength $job]} {
		set job [dict create id 0 verb $verb dir [file dirname $dst] names {} dsts {} done 0 cur 0 \
			paused 0 cancelled 0 ok {} quiet 0 pid {}]
	}
	dict lappend job names $name
	dict lappend job dsts $dst
	measure $src $dst
	job_notify
}

proc files::job_total {} {
	variable job
	variable opbytes
	set t 0
	foreach d [dict get $job dsts] { if {[info exists opbytes($d)]} { incr t $opbytes($d) } }
	return $t
}

# The running operation's helper has reported its bytes so far.
proc files::job_progress {bytes} {
	variable job
	if {![llength $job]} return
	dict set job cur $bytes
	job_notify
}

# An operation of the job has ended; ok is 1 when it worked.
proc files::job_step {dst name ok} {
	variable job
	variable opbytes
	if {![llength $job] || $dst ni [dict get $job dsts]} return
	if {[info exists opbytes($dst)]} { dict incr job done $opbytes($dst) }
	dict set job cur 0
	if {$ok} { dict lappend job ok $name }
}

# The queue is empty: the last notification, and the job is over.
proc files::job_end {} {
	variable job
	variable opbytes
	variable nafter
	if {![llength $job]} return
	set j $job
	set job {}
	catch {after cancel $nafter}
	set nafter ""
	foreach d [dict get $j dsts] { unset -nocomplain opbytes($d) }
	if {[dict get $j id] == 0 && [dict get $j quiet]} return
	# a cancelled job's notification went at the Cancel
	if {[dict get $j cancelled]} return
	if {![llength [dict get $j ok]]} {
		if {[dict get $j id]} { notify_close [dict get $j id] }
		return
	}
	set past [expr {[dict get $j verb] eq "Moving" ? "Moved" : "Copied"}]
	notify_send [dict get $j id] "$past to [destlabel [dict get $j dir]]" [itemline [dict get $j ok]] {} {} ""
}

# Send the progress, at most twice a second.
proc files::job_notify {} {
	variable job
	variable nlast
	variable nafter
	if {![llength $job] || [dict get $job quiet] || [dict get $job cancelled]} return
	set now [clock milliseconds]
	if {$now - $nlast < 500} {
		if {$nafter eq ""} { set nafter [after [expr {500 - ($now - $nlast)}] {set ::files::nafter ""; files::job_notify}] }
		return
	}
	set nlast $now
	set total [job_total]
	set done [expr {[dict get $job done] + [dict get $job cur]}]
	if {$total > 0} { set done [expr {min($done, $total)}] }
	set v [expr {$total > 0 ? min(99, int(100.0 * $done / $total)) : 0}]
	set hints [dict create value [list i $v]]
	if {$total > 0} { dict set hints x-ribbon-progress-text [list s [of $done $total]] }
	set acts [expr {[dict get $job paused] ? {resume Resume cancel Cancel} : {pause Pause cancel Cancel}}]
	notify_send [dict get $job id] "[dict get $job verb] to [destlabel [dict get $job dir]]" \
		[itemline [dict get $job names]] $acts $hints files::job_id
}

proc files::job_id {id} {
	variable job
	if {[llength $job] && [string is integer -strict $id]} { dict set job id $id }
}

# ---- Pause, Resume, Cancel ------------------------------------------------------------

# Every process under PID (from /proc), children before their parents' later siblings.
proc files::descendants {pid} {
	set kids {}
	foreach f [glob -nocomplain /proc/\[0-9\]*/stat] {
		if {[catch {::open $f} fh]} continue
		set line [read $fh]; ::close $fh
		set rest [string range $line [expr {[string last ")" $line] + 2}] end]
		lassign [split $rest] state ppid
		if {$ppid eq $pid} { lappend kids [lindex [split $f /] 2] }
	}
	set all {}
	foreach k $kids { lappend all $k {*}[descendants $k] }
	return $all
}

proc files::signal_tree {pids sig} {
	set all {}
	foreach p $pids { lappend all $p {*}[descendants $p] }
	if {[llength $all]} { catch {exec kill -$sig -- {*}$all 2>/dev/null} }
	return $all
}

proc files::job_action {key} {
	variable job
	variable opch
	variable ops
	variable pending
	if {![llength $job]} return
	set pids [expr {$opch eq "" ? {} : [pid $opch]}]
	switch -- $key {
		pause {
			signal_tree $pids STOP
			dict set job paused 1
		}
		resume {
			signal_tree $pids CONT
			dict set job paused 0
		}
		cancel {
			variable opcur
			variable cancelled
			dict set job cancelled 1
			# the job's waiting items go; the running one, when it is the job's, is killed (op_read sees it
			# end, op_finish clears what it left); an Extract or Compress in the queue is not the job's
			set keep {}
			foreach op $ops {
				lassign $op w verb name cmd dst src done fail
				if {$dst in [dict get $job dsts]} {
					set pending [lsearch -all -inline -not -exact $pending $dst]
					if {$fail ne ""} { uplevel #0 $fail }
				} else { lappend keep $op }
			}
			set ops $keep
			if {[llength $opcur] && [lindex $opcur 4] in [dict get $job dsts]} {
				lappend cancelled [lindex $opcur 4]
				set all [signal_tree $pids STOP]
				if {[llength $all]} { catch {exec kill -KILL -- {*}$all 2>/dev/null} }
			}
			if {[dict get $job id]} { notify_close [dict get $job id] }
			# the job is over now: what comes next is a job of its own
			job_end
			return
		}
		default return
	}
	set ::files::nlast 0
	job_notify
}

# ---- the notification server ------------------------------------------------------------

proc files::nbus {} {
	variable nbus
	if {$nbus ne ""} { return $nbus }
	if {[info commands ::shell::bus] eq "" || [catch {shell::bus} b]} { return "" }
	set nbus $b
	catch {$b listen -interface org.freedesktop.Notifications -member ActionInvoked -command list files::notify_invoked}
	catch {$b listen -interface org.freedesktop.Notifications -member NotificationClosed -command list files::notify_closed}
	return $b
}

proc files::notify_send {id summary body actions hints cb} {
	set b [nbus]
	if {$b eq ""} return
	set cmd [list files::notify_sent $cb]
	catch {$b call -command $cmd org.freedesktop.Notifications /org/freedesktop/Notifications \
		org.freedesktop.Notifications Notify susssasa{sv}i Files $id "" $summary $body $actions $hints -1}
}

proc files::notify_sent {cb status args} {
	if {$status eq "ok" && $cb ne ""} { {*}$cb [lindex $args 0 0] }
}

proc files::notify_close {id} {
	set b [nbus]
	if {$b eq "" || !$id} return
	catch {$b call -command {list} org.freedesktop.Notifications /org/freedesktop/Notifications \
		org.freedesktop.Notifications CloseNotification u $id}
}

proc files::notify_invoked {msg id key} {
	variable job
	if {[llength $job] && $id == [dict get $job id]} { job_action $key }
}

# The person closed the progress: it stays closed for this job (the copy goes on).
proc files::notify_closed {msg id reason} {
	variable job
	if {[llength $job] && $id == [dict get $job id] && $reason == 2} {
		dict set job quiet 1
		dict set job id 0
	}
}
