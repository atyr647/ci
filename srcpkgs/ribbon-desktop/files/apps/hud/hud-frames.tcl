# hud-frames.tcl - the frame source for the Game HUD's FPS, frame time, 1 % low and graph.
#
# A frame source is registered with a name and a poll command. The HUD calls the active source's poll every
# frame; it returns a dict:
#   {available 1 times {ms ms ...}}   the source runs; the frame times (ms) since the last poll, oldest first
#   {available 0}                     no frame data: the HUD shows dashes and "No frame data"
# The "stub" source always reports unavailable. The "file" source (hud::frames::use_file PATH ...) reads files or
# FIFOs that a producer appends frame data to. In a session the daemon (main.tcl) gives it the compositor's pipe,
# $XDG_RUNTIME_DIR/ribbon-hud-stats, which ribbon-gamescope (ribbon-gaming) hands to gamescope as its --stats-path,
# and before it, for the Automatic source, the pipe of Ribbon's Vulkan layer ($XDG_RUNTIME_DIR/ribbon-hud-frames, or
# RIBBON_HUD_FRAMES: apps/hud/native/hud-frames-layer.c, an implicit layer in every Vulkan program, which writes
# "pid=PID ms ms ..." lines). A game that is neither Vulkan nor under gamescope has no producer: "No frame data".
#
# Numbers: frame time is the mean of the last 30 frames; FPS is 1000 / frame time; 1 % low is 1000 divided by
# the 99th-percentile frame time of the last 600 frames. The graph is the last 60 frame times on a 0-20 ms
# scale (100 % = 20 ms).

namespace eval ::hud::frames {
	variable sources [dict create stub ::hud::frames::stub_poll]
	variable active stub
	variable times {}      ;# the last 600 frame times, ms
	variable available 0
	variable gen 0         ;# counts changes (new frame times, availability), so the HUD redraws only when something changed
}

proc ::hud::frames::stub_poll {} {
	return [dict create available 0]
}

# register NAME PROC: PROC is a command with no arguments that returns a poll dict
proc ::hud::frames::register {name proc} {
	variable sources
	dict set sources $name $proc
}

# make NAME the source to poll; an unknown name is an error
proc ::hud::frames::set_source {name} {
	variable sources
	variable active
	if {![dict exists $sources $name]} { error "hud::frames: no frame source $name" }
	set active $name
}

# one poll of the active source: keeps its frame times and sets availability
proc ::hud::frames::poll {} {
	variable sources
	variable active
	variable times
	variable available
	variable gen
	set r [{*}[dict get $sources $active]]
	if {![dict exists $r available] || ![dict get $r available]} {
		if {$available} { incr gen }
		set available 0
		return
	}
	if {!$available} { incr gen }
	set available 1
	# another producer: its numbers start afresh
	if {[dict exists $r restart] && [dict get $r restart]} { set times {}; incr gen }
	foreach t [dict get $r times] {
		if {[string is double -strict $t] && $t > 0} { lappend times $t; incr gen }
	}
	if {[llength $times] > 600} { set times [lrange $times end-599 end] }
}

# forget the frame times (a new game, or the source stopped)
proc ::hud::frames::reset {} {
	variable times
	variable available
	variable gen
	set times {}
	set available 0
	incr gen
}

# The numbers for the draw: {ok 0|1 fps ft low series}. Values are "" when ok is 0.
proc ::hud::frames::numbers {} {
	variable times
	variable available
	if {!$available || [llength $times] == 0} {
		return [dict create ok 0 fps "" ft "" low "" series {}]
	}
	set recent [lrange $times end-29 end]
	if {[llength $recent] == 0} { set recent $times }
	set sum 0.0
	foreach t $recent { set sum [expr {$sum + $t}] }
	set ft [expr {$sum / [llength $recent]}]
	set sorted [lsort -real $times]
	set idx [expr {int(ceil(0.99 * [llength $sorted])) - 1}]
	if {$idx < 0} { set idx 0 }
	set p99 [lindex $sorted $idx]
	set series {}
	foreach t [lrange $times end-59 end] {
		lappend series [expr {min(100.0, max(0.0, $t / 20.0 * 100))}]
	}
	return [dict create ok 1 fps [expr {round(1000.0 / $ft)}] ft [format %.1f $ft] \
		low [expr {round(1000.0 / $p99)}] series $series]
}

# The "file" source: each PATH (a file or a FIFO) gets frame data appended by a producer; each poll takes what is new.
# With several paths the first one that has had data lately is the one shown (Automatic: the layer's file, else the
# compositor's pipe): in the last 2 s, or for a path whose last data was an fps= line, in the time 450 frames take at
# that rate (gamescope writes a line every 300 frames). None lately (or no file) means unavailable. Makes "file" the
# active source. The data is whitespace-separated words: a number is one frame time in ms; fps=N (a line of
# gamescope's --stats-path pipe, its mean over the last 300 frames) is 300 frame times of 1000/N ms; any other
# key=value word is skipped. A line that starts with pid=PID is that process's (the layer's lines); the others are
# an untagged producer's ("" below). When several processes write to one path the pick command chooses
# (hud::frames::configure -pick CMD: called with a list of {pid frames} of the processes that wrote lately, the one
# shown last first, then the busiest; returns the pid to show, "" being the untagged producer's, or anything else,
# such as -, for none). Without one the first is shown. A switch
# to another process starts the numbers afresh.
# A FIFO is kept open for reading and writing: a producer never blocks in its open or gets a broken pipe between polls.
# hud::frames::drain: what the pipes hold from before the HUD came up is not frames of now: the next read drops it
# (all but the last fps= line, a mean that still holds).
proc ::hud::frames::use_file {args} {
	variable file_state
	if {[info exists file_state]} {
		foreach st $file_state { if {[dict get $st chan] ne ""} { catch {::close [dict get $st chan]} } }
	}
	set file_state {}
	foreach path $args { lappend file_state [dict create path $path offset 0 last 0 chan "" hold 2000 pids {} chosen - fresh 1] }
	register file ::hud::frames::file_poll
	set_source file
	reset
}

# the paths of the file source, in order ({} when it is not in use)
proc ::hud::frames::file_paths {} {
	variable file_state
	if {![info exists file_state]} { return {} }
	lmap st $file_state { dict get $st path }
}

proc ::hud::frames::configure {args} {
	foreach {k v} $args {
		if {$k eq "-pick"} { variable pick; set pick $v } else { error "hud::frames::configure: unknown option $k" }
	}
}

# the next read of each path drops what was waiting (see use_file)
proc ::hud::frames::drain {} {
	variable file_state
	if {![info exists file_state]} return
	set i 0
	foreach st $file_state { lset file_state $i [dict set st fresh 1]; incr i }
}

# TEXT by producer: a dict pid -> its frame times ("" for the lines without a pid= word)
proc ::hud::frames::parse_groups {text} {
	set by {}
	foreach line [split $text \n] {
		set pid ""
		if {[regexp {^\s*pid=([0-9]+)(.*)$} $line -> pid line]} {}
		if {[string trim $line] eq ""} continue
		dict append by $pid " $line"
	}
	set out {}
	dict for {pid t} $by {
		set times [parse $t]
		if {[llength $times]} { dict set out $pid $times }
	}
	return $out
}

# the frame times in TEXT (see use_file)
proc ::hud::frames::parse {text} {
	set out {}
	foreach t [split $text] {
		if {$t eq ""} continue
		if {[string is double -strict $t]} {
			lappend out $t
		} elseif {[regexp {^fps=([0-9.]+)$} $t -> f] && [string is double -strict $f] && $f > 0} {
			lappend out {*}[lrepeat 300 [expr {1000.0 / $f}]]
		}
		if {[llength $out] > 1200} { set out [lrange $out end-599 end] }
	}
	return [lrange $out end-599 end]
}

# what is new on one path: {state groups} (groups: parse_groups)
proc ::hud::frames::file_read {st} {
	set path [dict get $st path]
	set text ""
	if {[catch {file type $path} type]} { set type "" }
	if {$type eq "fifo"} {
		if {[dict get $st chan] eq ""} {
			if {![catch {::open $path {RDWR NONBLOCK}} fh]} {
				fconfigure $fh -blocking 0 -translation binary
				dict set st chan $fh
			}
		}
		if {[dict get $st chan] ne "" && [catch {::read [dict get $st chan]} text]} {
			catch {::close [dict get $st chan]}
			dict set st chan ""
			set text ""
		}
	} else {
		if {[dict get $st chan] ne ""} { catch {::close [dict get $st chan]}; dict set st chan "" }
		if {$type eq "file" && ![catch {::open $path {RDONLY NONBLOCK}} fh]} {
			set size [file size $path]
			if {$size < [dict get $st offset]} { dict set st offset 0 }
			seek $fh [dict get $st offset]
			set text [::read $fh]
			dict set st offset [expr {[dict get $st offset] + [string length $text]}]
			::close $fh
		}
	}
	# the backlog of a pipe the HUD did not read: only its last fps= line stands
	if {[dict get $st fresh]} {
		dict set st fresh 0
		set lastfps [lindex [regexp -all -inline {(?:^|\s)fps=[0-9.]+(?=\s|$)} $text] end]
		set text [string trim $lastfps]
	}
	# how long this path's data stays current: an fps= line's 300 frames and half as many again at that rate
	set fps [lindex [regexp -all -inline {(?:^|\s)fps=([0-9.]+)(?=\s|$)} $text] end]
	if {[string is double -strict $fps] && $fps > 0} {
		dict set st hold [expr {max(2000, int(450000.0 / $fps))}]
	} elseif {[regexp {(?:^|\s)[0-9.]+(?:\s|$)} $text]} {
		dict set st hold 2000
	}
	return [list $st [parse_groups $text]]
}

proc ::hud::frames::file_poll {} {
	variable file_state
	variable pick
	set now [clock milliseconds]
	set result [dict create available 0]
	set i 0
	foreach st $file_state {
		lassign [file_read $st] st groups
		# the producers of this path that wrote lately: pid -> {last frames}
		set pids [dict get $st pids]
		dict for {pid times} $groups {
			dict set pids $pid [list $now [llength $times]]
		}
		dict for {pid v} $pids {
			if {![dict exists $groups $pid]} { dict set pids $pid [list [lindex $v 0] 0] }
			if {$now - [lindex $v 0] > [dict get $st hold]} { dict unset pids $pid }
		}
		if {[dict size $groups]} { dict set st last $now }
		# a path silent for longer than its data holds has no producer now
		if {$now - [dict get $st last] > [dict get $st hold]} { set pids {} }
		dict set st pids $pids
		set chosen ""
		if {[dict size $pids] && ![dict get $result available]} {
			# the one shown last first, then the busiest
			set cands {}
			dict for {pid v} $pids { lappend cands [list $pid [lindex $v 1]] }
			set cands [lsort -integer -decreasing -index 1 $cands]
			set at [lsearch -exact -index 0 $cands [dict get $st chosen]]
			if {$at > 0} { set cands [linsert [lreplace $cands $at $at] 0 [lindex $cands $at]] }
			set chosen [lindex $cands 0 0]
			if {[info exists pick] && $pick ne ""} {
				if {[catch {uplevel #0 [list {*}$pick $cands]} chosen] || ![dict exists $pids $chosen]} { set chosen "" }
			}
			if {[dict exists $pids $chosen]} {
				set new [expr {[dict exists $groups $chosen] ? [dict get $groups $chosen] : {}}]
				set result [dict create available 1 times $new]
				if {[dict get $st chosen] ni [list - $chosen]} { dict set result restart 1 }
				dict set st chosen $chosen
			}
		}
		lset file_state $i $st
		incr i
	}
	return $result
}
