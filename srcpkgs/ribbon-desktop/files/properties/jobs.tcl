# jobs.tcl - the file jobs Properties and the Files Inspector run (rename, chown,
# chmod): each one done by us when we may, else through pkexec. Shared by
# properties/filepages.tcl and properties/inspector.tcl (the Files panel and the
# standalone window source it too). Sourced before either; defines fp:: procs only.

namespace eval fp {
	variable out
	array set out {}
}

# Each job yourself when you may; through pkexec when you may not: a new
# owner (only root gives a file away), the access of a file that isn't
# yours, a rename in a folder you can't write to. A job that fails with
# "not permitted" is tried once more through pkexec.
proc fp::uid {} { exec id -u }
proc fp::privileged {op a b} {
	set me [uid]
	if {$me == 0} { return 0 }
	switch -- $op {
		chown { return 1 }
		chmod { file stat $b st; return [expr {$st(uid) != $me}] }
		rename {
			file stat [file dirname $a] st
			return [expr {$st(uid) != $me && !($st(mode) & 2)}]
		}
	}
	return 0
}
proc fp::run_jobs {jobs done {errs {}}} {
	if {![llength $jobs]} {
		uplevel #0 [list {*}$done $errs]
		return
	}
	set rest [lrange $jobs 1 end]
	lassign [lindex $jobs 0] op a b
	switch -- $op {
		rename { set argv [list mv -n -T -- $a $b] }
		chmod { set argv [list chmod $a -- $b] }
		chown { set argv [list chown -- $a $b] }
	}
	if {![privileged $op $a $b]} {
		switch -- $op {
			rename { set rc [catch {file rename -- $a $b} err] }
			chmod { set rc [catch {file attributes $b -permissions 0$a} err] }
			chown { set rc [catch {file attributes $b -owner $a} err] }
		}
		if {!$rc} { run_jobs $rest $done $errs; return }
		if {![regexp -nocase {permission|not permitted} $err]} { lappend errs $err; run_jobs $rest $done $errs; return }
	}
	set cmd [list pkexec {*}[lreplace $argv 0 0 [lindex [auto_execok [lindex $argv 0]] 0]]]
	if {[catch {::open |[list {*}$cmd </dev/null 2>@1] r} fh]} {
		lappend errs $fh; run_jobs $rest $done $errs; return
	}
	fconfigure $fh -blocking 0
	set ::fp::out($fh) ""
	fileevent $fh readable [list fp::job_read $fh $rest $done $errs]
}
proc fp::job_read {fh rest done errs} {
	variable out
	append out($fh) [read $fh]
	if {![eof $fh]} return
	fconfigure $fh -blocking 1
	if {[catch {close $fh}]} { lappend errs [string trim $out($fh)] }
	unset out($fh)
	run_jobs $rest $done $errs
}

