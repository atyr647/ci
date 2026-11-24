# stuck.tcl - System monitor: which processes are not responding. No UI here.
#
# A window's program talks to the display over a unix socket (the Wayland socket, or the X server's for an X
# program). What the display sends it - input, frames, the "are you there" ping - waits in the program's end of
# that socket until the program reads it. A program that responds reads within milliseconds; one that hangs
# leaves it there. So a process is "not responding" when its end of a display socket has had unread data on
# every look for `need` seconds running, never less than the look before. (The compositor's own ping timeout says
# the same thing, but labwc tells nobody.) A program the display has sent nothing to is not found; neither is one
# that was paused on purpose (main.tcl leaves stopped processes out), nor the monitor itself: it looks while it is
# busy looking, so its own socket can hold the pointer's events at every look though it reads them right after.
#
# The kernel's socket table is read with `ss -xn` (iproute2). Without ss nothing is ever marked.
#
#   monitor::stuck::update    one look; returns the pids not responding now (call once a second)
#   monitor::stuck::secs PID  how long PID's display socket has held unread data, in seconds
#
# The shell loads this file too (shell/mod-stuck.tcl, the "not responding" notice while the monitor is closed), with
# proc.tcl for monitor::proc_root and monitor::self.

namespace eval monitor::stuck {
	variable ss {ss -xn}
	variable need 5          ;# looks in a row with unread data before a process is marked
	variable displays ""     ;# the display sockets' paths ("": this session's, see paths)
	variable seen            ;# client inode -> {unread-bytes looks first-ms}
	array set seen {}
	variable since [dict create]   ;# pid -> when its socket's unread data was first seen (ms), for the pids marked
}

# The display sockets of this session: the Wayland socket and the X servers' (file and abstract names).
proc monitor::stuck::paths {} {
	variable displays
	if {$displays ne ""} { return $displays }
	set out {}
	if {[info exists ::env(XDG_RUNTIME_DIR)]} {
		set wd [expr {[info exists ::env(WAYLAND_DISPLAY)] ? $::env(WAYLAND_DISPLAY) : "wayland-0"}]
		lappend out [expr {[string match /* $wd] ? $wd : [file join $::env(XDG_RUNTIME_DIR) $wd]}]
	}
	lappend out /tmp/.X11-unix/X* @/tmp/.X11-unix/X*
	return $out
}

# `ss -xn` lines of connected stream sockets: {inode peer-inode unread local-address} each.
proc monitor::stuck::parse {text} {
	set out {}
	foreach line [split $text \n] {
		set f [regexp -all -inline {\S+} $line]
		if {[lindex $f 0] ne "u_str" || [lindex $f 1] ne "ESTAB" || [llength $f] < 8} continue
		lassign $f - - rq - local inode - peer
		if {![string is integer -strict $inode] || ![string is integer -strict $peer] || ![string is integer -strict $rq]} continue
		lappend out [list $inode $peer $rq $local]
	}
	return $out
}

# The programs' ends of the display sockets: dict inode -> unread bytes. The display's end of a connection is
# named after its socket; the other end (its peer) is the program's.
proc monitor::stuck::clients {socks paths} {
	set peers [dict create]
	foreach s $socks {
		lassign $s inode peer rq local
		foreach p $paths { if {[string match $p $local]} { dict set peers $peer 1; break } }
	}
	set out [dict create]
	foreach s $socks {
		lassign $s inode peer rq local
		if {[dict exists $peers $inode]} { dict set out $inode $rq }
	}
	return $out
}

# The processes that hold each socket: dict inode -> pids, from the fd links of the processes we may read.
proc monitor::stuck::owners {inodes} {
	set out [dict create]
	if {![dict size $inodes]} { return $out }
	foreach d [glob -nocomplain -directory $::monitor::proc_root -types d {[0-9]*}] {
		if {[catch {glob -nocomplain -directory [file join $d fd] *} fds]} continue
		foreach fd $fds {
			if {[catch {file readlink $fd} l] || ![regexp {^socket:\[(\d+)\]$} $l -> ino]} continue
			if {[dict exists $inodes $ino]} { dict lappend out $ino [file tail $d] }
		}
	}
	return $out
}

proc monitor::stuck::update {} {
	variable ss
	variable need
	variable seen
	variable since
	if {[catch {::exec {*}$ss 2>/dev/null} text]} { array unset seen; set since [dict create]; return {} }
	set ms [clock milliseconds]
	set now [clients [parse $text] [paths]]
	set late [dict create]
	foreach ino [array names seen] { if {![dict exists $now $ino]} { unset seen($ino) } }
	dict for {ino rq} $now {
		if {$rq <= 0} { unset -nocomplain seen($ino); continue }
		lassign [expr {[info exists seen($ino)] ? $seen($ino) : [list 0 0 $ms]}] before looks first
		if {$rq < $before} { set looks 0; set first $ms }
		set seen($ino) [list $rq [incr looks] $first]
		if {$looks >= $need} { dict set late $ino $first }
	}
	set pids {}
	set was $since
	set since [dict create]
	dict for {ino owners} [owners $late] {
		foreach p $owners {
			if {$p == $::monitor::self} continue
			if {$p ni $pids} { lappend pids $p }
			set t [dict get $late $ino]
			if {[dict exists $was $p]} { set t [expr {min($t, [dict get $was $p])}] }
			if {![dict exists $since $p] || $t < [dict get $since $p]} { dict set since $p $t }
		}
	}
	return $pids
}

proc monitor::stuck::secs {pid} {
	variable since
	if {![dict exists $since $pid]} { return 0 }
	expr {max(0, ([clock milliseconds] - [dict get $since $pid]) / 1000)}
}
