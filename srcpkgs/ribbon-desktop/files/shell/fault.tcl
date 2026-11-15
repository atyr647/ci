# fault.tcl - the shell's fault isolation (HANDOFF "Robustness" 4a and 4b).
#
# - interp bgerror: an error in an `after`, a fileevent or a binding is logged
#   to $XDG_STATE_HOME/ribbon/shell.log, and the shell keeps running. Never a
#   dialog.
# - shell-state: a small file of "key value" lines (fault::save, fault::get).
#   It is written atomically (a temporary name, then rename) and validated on
#   load; a file that does not parse is deleted.
# - crash loop: the shell counts its own starts in the last minute. The third
#   start in that minute runs without the saved state; the fourth exits with
#   status 1 and logs that it gave up. dinit's restart limit stops the
#   restarts (ribbon-dinit's ribbon-shell service). A start counts whether or
#   not the one before it crashed.
#
# Sourced first by main.tcl, so the handler is in place before the first error.

namespace eval fault {
	variable state [dict create]
	variable loaded 0
	variable ignored 0
	variable window 60
	variable max_log 1048576
}

proc fault::dir {} {
	if {[info exists ::env(XDG_STATE_HOME)] && $::env(XDG_STATE_HOME) ne ""} {
		set base $::env(XDG_STATE_HOME)
	} else {
		set base [file join $::env(HOME) .local state]
	}
	return [file join $base ribbon]
}

# One line to the shell log, with the time. Never raises: the log is not
# allowed to be the next error.
proc fault::log {text} {
	catch {
		set dir [fault::dir]
		file mkdir $dir
		set path [file join $dir shell.log]
		if {[file exists $path] && [file size $path] > $fault::max_log} {
			file rename -force $path $path.1
		}
		set fh [open $path a]
		fconfigure $fh -encoding utf-8
		set line [string map [list "\n" " | " "\r" " "] $text]
		puts $fh "[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] $line"
		close $fh
	}
	return
}

# The handler for Tcl errors nobody catches. It logs and returns: the event
# loop goes on, and Tk's own error dialog is never shown.
proc fault::bgerror {msg {opts {}}} {
	catch {
		set info [expr {[dict exists $opts -errorinfo] ? [dict get $opts -errorinfo] : ""}]
		fault::log "error: $msg | [string range $info 0 500]"
	}
	return
}
interp bgerror {} fault::bgerror

# --- the state file -----------------------------------------------------------

# "key value" lines: a key is a short lowercase word, a value is plain text of
# at most 200 characters. The whole file is at most 4 KiB.
proc fault::valid {key value} {
	expr {[regexp {^[a-z][a-z_]{0,31}$} $key] && [string length $value] <= 200 && ![regexp {[[:cntrl:]]} $value]}
}

proc fault::load {} {
	variable state
	variable loaded
	variable ignored
	set state [dict create]
	set loaded 1
	if {$ignored} { return $state }
	set path [file join [fault::dir] shell-state]
	if {![file exists $path]} { return $state }
	if {[catch {
		if {[file size $path] > 4096} { error "larger than 4 KiB" }
		set fh [open $path r]
		fconfigure $fh -encoding utf-8
		set text [read $fh]
		close $fh
		foreach line [split $text "\n"] {
			if {$line eq ""} { continue }
			if {![regexp {^([a-z][a-z_]{0,31}) (.*)$} $line -> k v] || ![fault::valid $k $v]} {
				error "line does not parse: [string range $line 0 40]"
			}
			dict set state $k $v
		}
	} err]} {
		fault::log "shell-state dropped: $err"
		catch {file delete $path}
		set state [dict create]
	}
	return $state
}

proc fault::get {key {default ""}} {
	variable state
	variable loaded
	if {!$loaded} { fault::load }
	if {[dict exists $state $key]} { return [dict get $state $key] }
	return $default
}

# Returns 1 when written. Writes the whole state each time, to a temporary name
# in the same folder, then renames it over the old file. (Tcl has no fsync; a
# power cut right after the rename can leave an empty file, which load drops.)
proc fault::save {key value} {
	variable state
	variable loaded
	if {!$loaded} { fault::load }
	if {![fault::valid $key $value]} {
		fault::log "shell-state: not saved, bad key or value: [string range $key 0 40]"
		return 0
	}
	dict set state $key $value
	set dir [fault::dir]
	set path [file join $dir shell-state]
	set tmp [file join $dir .shell-state.[pid].tmp]
	if {[catch {
		file mkdir $dir
		set fh [open $tmp w]
		fconfigure $fh -encoding utf-8
		dict for {k v} $state { puts $fh "$k $v" }
		close $fh
		file rename -force $tmp $path
	} err]} {
		catch {file delete $tmp}
		fault::log "shell-state not saved: $err"
		return 0
	}
	return 1
}

# --- crash loops ----------------------------------------------------------------

# Records this start and returns how many starts there were in the last
# $window seconds, this one included. The record is a list of times in
# $XDG_RUNTIME_DIR (or the state folder), kept short.
proc fault::starts {} {
	variable window
	set now [clock seconds]
	set base [expr {[info exists ::env(XDG_RUNTIME_DIR)] ? $::env(XDG_RUNTIME_DIR) : [fault::dir]}]
	set path [file join $base ribbon-shell.starts]
	set recent {}
	catch {
		set fh [open $path r]
		set text [read $fh]
		close $fh
		foreach t [split $text] {
			if {[string is integer -strict $t] && $now - $t < $window && $t <= $now} { lappend recent $t }
		}
	}
	lappend recent $now
	set recent [lrange $recent end-15 end]
	catch {
		file mkdir $base
		set fh [open $path w]
		puts $fh [join $recent "\n"]
		close $fh
	}
	return [llength $recent]
}

# The crash-loop policy, run once when the shell starts (main.tcl).
proc fault::start_policy {} {
	variable ignored
	set n [fault::starts]
	if {$n >= 4} {
		fault::log "crash loop: $n starts in a minute, giving up (dinit stops restarting the shell at its limit)"
		exit 1
	}
	if {$n == 3} {
		set ignored 1
		fault::log "crash loop: 3 starts in a minute, starting without the saved state"
	}
	return $ignored
}

# True when dinit started this process. ribbon-shell execs wish, so the shell
# is dinit's direct child, and its parent's name is dinit.
proc fault::supervised {} {
	set ok 0
	catch {
		set fh [open /proc/self/stat r]
		set s [read $fh]
		close $fh
		set rest [string range $s [expr {[string last ") " $s] + 2}] end]
		set ppid [lindex $rest 1]
		set fh [open /proc/$ppid/comm r]
		set comm [string trim [read $fh]]
		close $fh
		set ok [expr {$comm eq "dinit"}]
	}
	return $ok
}
