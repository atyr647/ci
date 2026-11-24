# polkit-keys.tcl - a stand-in for ribbon-polkit-keys (tests/steps.d/70-polkit.sh). The real helper needs a
# Wayland compositor with layer-shell and a keyboard (tests/steps.d/70-polkit-keys.sh runs it under labwc);
# this speaks the same socket protocol on fd 0, with the same rules, and "types" on instruction:
#   events out (one line each): ready, lost, n COUNT, t TEXT (echo mode only), enter esc tab btab up down space
#   commands in: mode text|echo|nav, submit, clear, quit, and "secret" with a descriptor (SCM_RIGHTS):
#                the pipe that submit writes the typed text and a newline to
# What it is told to do comes from $POLKIT_FIX/keys.cmd, a file the test appends lines to (read every 20 ms):
#   type TEXT   characters (collected hidden in text mode, shown in echo mode, ignored in nav mode)
#   key NAME    enter esc tab btab up down space (space is a character unless in nav mode)
#   back        BackSpace
#   lose        the keyboard is taken: prints lost, then keeps running as the real one does
# $POLKIT_FIX/keys.behave, read at start, says how this run goes: ready (default) | refuse (exit 2, no ready:
# the compositor has no layer-shell) | silent (never ready) | closed (exit 0 after ready, at once) .
# $POLKIT_FIX/keys.log gets one line per start, event and command, and never a character typed.
package require unix_extra
set dir $env(POLKIT_FIX)
set log [open $dir/keys.log a]
fconfigure $log -buffering line
proc note {text} { puts $::log "keys [pid] $text" }
set behave ready
catch { set f [open $dir/keys.behave]; set behave [string trim [read $f]]; close $f }
note "start argv [list $argv] behave $behave"
foreach k [lsort [array names env]] { if {[string match POLKIT_* $k] || [string match WAYLAND* $k] || $k eq "DISPLAY"} { note "env $k" } }

set c [unix_extra::fdopen 3]   ;# the wrapper dups the socket (fd 0) to fd 3: a read-only stdin cannot be adopted
fconfigure $c -blocking 0 -translation lf -encoding utf-8 -buffering none
proc ev {line} { catch {puts $::c $line; flush $::c} }
if {$behave eq "refuse"} { puts stderr "ribbon-polkit-keys: compositor lacks wlr-layer-shell"; exit 2 }
if {$behave eq "silent"} {
	# never says ready, but like the real helper it quits when told to or when the socket closes (the agent gone)
	fileevent $c readable {
		while {![catch {gets $c line} n] && $n >= 0} { if {$line eq "quit"} { note quit; exit 0 } }
		if {[catch {eof $c} ended] || $ended} { note "socket closed"; exit 0 }
	}
	after 600000 exit; vwait forever
}

set mode text
set buf ""           ;# what the real helper keeps in its mlock'ed buffer
set secret ""        ;# the channel for the descriptor passed with "secret"
set focus 1
proc changed {} {
	global buf mode
	ev "n [string length $buf]"
	if {$mode eq "echo"} { ev "t $buf" }
}
proc typed {text} {
	global buf mode focus
	if {!$focus || $mode eq "nav"} return
	append buf $text
	changed
}
proc fire {name} {
	global mode buf focus
	if {!$focus} return
	switch -- $name {
		space { if {$mode eq "nav"} { ev space } else { typed " " } }
		esc { set buf ""; ev esc }
		default { ev $name }
	}
}
proc command {line} {
	global c mode buf secret focus
	switch -glob -- $line {
		secret {
			foreach f [unix_extra::fds $c] {
				if {$secret ne ""} { catch {close $secret} }
				set secret $f
			}
			note "secret fd received"
		}
		submit {
			note "submit (mode $mode, [string length $buf] chars)"
			if {$focus && $secret ne ""} { catch {puts -nonewline $secret "$buf\n"; flush $secret} }
			set buf ""; changed
		}
		clear { set buf ""; changed }
		mode* {
			set m [lindex $line 1]
			if {$m in {text echo nav} && $m ne $mode} { set mode $m; set buf ""; ev "n 0" }
			note "mode $mode"
		}
		quit { note quit; exit 0 }
	}
}
fileevent $c readable {
	if {[catch {gets $c line} n] || ($n < 0 && [eof $c])} { note "socket closed"; exit 0 }
	while {$n >= 0} {
		command $line
		if {[catch {gets $c line} n]} break
	}
}

set cmdfile $dir/keys.cmd
set cmdpos [expr {[file exists $cmdfile] ? [file size $cmdfile] : 0}]   ;# only what is added after we start
proc poll {} {
	global cmdfile cmdpos focus
	if {![catch {open $cmdfile} f]} {
		fconfigure $f -translation lf -encoding utf-8
		seek $f $cmdpos
		set data [read $f]
		set cmdpos [tell $f]
		close $f
		foreach line [split $data \n] {
			if {$line eq ""} continue
			set w [lindex $line 0]
			switch -- $w {
				type { typed [string range $line 5 end] }
				key { fire [lindex $line 1] }
				back { if {$::buf ne "" && $::mode ne "nav"} { set ::buf [string range $::buf 0 end-1]; changed } }
				lose { set focus 0; ev lost; note lost }
			}
		}
	}
	after 20 poll
}
ev ready
note ready
if {$behave eq "closed"} { exit 0 }
poll
vwait forever
