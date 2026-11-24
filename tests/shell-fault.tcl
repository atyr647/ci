# shell-fault.tcl - the shell's fault isolation, as RIBBON_SHELL_TEST (driven by
# tests/steps.d/10-shell-fault.sh and 11-shell-modules.sh). Exits 0 when the
# checks pass, 1 when one fails; each check prints one line.
#   FAULT_MODE = error   an error in an `after` is logged; the shell goes on
#              = verb    a module's shell::verb is called through the FIFO
#              = state   the saved state comes back after a SIGSEGV restart
#              = plain   the shell only starts (corrupt state, crash-loop checks)
set mode [expr {[info exists ::env(FAULT_MODE)] ? $::env(FAULT_MODE) : "plain"}]
set failed 0
proc check {ok what} {
	global failed
	if {$ok} { puts "  ok   $what" } else { puts "  FAIL $what"; set failed 1 }
}
proc finish {} {
	global failed
	update
	exit $failed
}
set logfile [file join [expr {[info exists ::env(XDG_STATE_HOME)] ? $::env(XDG_STATE_HOME) : ""}] ribbon shell.log]
proc log_text {} {
	global logfile
	if {[catch {set fh [open $logfile r]; set t [read $fh]; close $fh}]} { return "" }
	return $t
}

switch -- $mode {
	error {
		# bgerror: the error is logged and the event loop goes on; no error dialog
		after 10 {error boom-from-after}
		after 500 {
			check [string match "*boom-from-after*" [log_text]] "the error in an after is logged"
			check [expr {![winfo exists .bgerrorDialog] && ![winfo exists .__tk__messagebox]}] "no error dialog"
			set ::alive 1
		}
		after 600 {
			check [info exists ::alive] "the shell keeps running after the error"
			finish
		}
	}
	verb {
		# a module's verb, called with the words after it, through the FIFO
		after 300 {
			set fh [open [file join $::env(XDG_RUNTIME_DIR) ribbon-shell] w]
			# an unknown verb is ignored (no error); the module's verb runs
			puts $fh "nosuch x"
			puts $fh "probe one two"
			close $fh
		}
		after 700 {
			set got ""
			catch {set fh [open $::env(FAULT_PROBE_OUT) r]; set got [string trim [read $fh]]; close $fh}
			check [expr {$got eq "one two"}] "a module's verb runs from the FIFO with its words (got \"$got\")"
			check [expr {![string match "*error*" [log_text]]}] "an unknown verb is ignored, nothing is logged"
			finish
		}
	}
	state {
		# the first run saves a key and crashes (SIGSEGV); the supervisor starts it
		# again and this run reads the key back from shell-state
		if {[fault::get panel] eq ""} {
			fault::save panel test-open
			check [expr {[fault::save workspace 2]}] "state is saved"
			after 300 { exec kill -SEGV [pid] }
		} else {
			check [expr {[fault::get panel] eq "test-open"}] "state comes back after a restart"
			check [expr {[fault::get workspace] eq "2"}] "every saved key comes back"
			finish
		}
	}
	default {
		# plain start: the state the shell loaded (or not, on a crash loop), then the log
		after 300 {
			check [winfo exists .] "the shell starts"
			puts "state panel=[fault::get panel]"
			finish
		}
	}
}
