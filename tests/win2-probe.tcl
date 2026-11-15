# win2-probe.tcl - run inside a real standalone file window (RIBBON_PROPERTIES_PROBE=this file,
# properties/main.tcl with paths): WIN2_PROBE says what to check, and each check prints
# "  ok   ..." or "  FAIL ..." (tests/win2-live.sh reads them).
#   place   print where the window is: "at X Y"
#   live    the window's file (its only path) is changed from outside: chmod, then a rename in its
#           folder, then removal; the window redraws, follows the new name, then closes
#   pair    the window's second file is renamed over its first: it shows that file once
#   stay    keep the window open until it is asked for again (win2::show), then say so and quit
proc probe_wait {cond {ms 6000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {[clock milliseconds] < $end} {
		if {[uplevel #0 [list expr $cond]]} { return 1 }
		after 50 {set ::probe_tick 1}; vwait ::probe_tick
	}
	return 0
}
proc probe_check {what cond {ms 6000}} {
	if {[probe_wait $cond $ms]} { puts "  ok   $what" } else { puts "  FAIL $what"; exit 1 }
	flush stdout
}
switch -- $::env(WIN2_PROBE) {
	place {
		# mapped, and moved where it was put (every place asked for is off the screen's corner);
		# looked at from the event loop, not a nested wait
		proc probe_place {n} {
			if {([winfo ismapped .w] && ([winfo rootx .w] != 0 || [winfo rooty .w] != 0)) || $n > 50} {
				puts "at [winfo rootx .w] [winfo rooty .w]"
				exit 0
			}
			after 100 [list probe_place [incr n]]
		}
		after 100 {probe_place 0}
	}
	live {
		set f [lindex $win2::paths 0]
		set d0 $win2::drawn
		exec chmod 600 $f
		probe_check "a chmod from outside redraws the window" {$win2::drawn > $d0 && ([lindex $win2::sig 0 3] & 0777) == 0600}
		# an editor's save: a new file written beside it and renamed over it (a new inode at the same path)
		set d0 $win2::drawn
		set tmp [file join [file dirname $f] .save-[file tail $f]]
		set fh [::open $tmp w]; puts $fh "saved over"; close $fh
		exec mv $tmp $f
		probe_check "a save that replaces the file: the window stays on it and redraws" {$win2::paths eq [list $f] && $win2::drawn > $d0 && [lindex $win2::sig 0 4] == 11}
		set g [file join [file dirname $f] renamed-[file tail $f]]
		set d0 $win2::drawn
		exec mv $f $g
		probe_check "a rename from outside: the window follows the file to its new name" {$win2::paths eq [list $g] && $win2::drawn > $d0}
		puts "  removing"; flush stdout
		exec rm $g
		# the window closes (exit 0 from page::quit); still here after the wait is a failure
		probe_wait 0 6000
		puts "  FAIL the window stays open after its file is gone"
		exit 1
	}
	pair {
		# two files shown; the second renamed over the first: the window shows that file once
		lassign $win2::paths f g
		set d0 $win2::drawn
		exec mv $g $f
		probe_check "one of two files renamed over the other: the window shows it once" {$win2::paths eq [list $f] && $win2::drawn > $d0}
		exit 0
	}
	stay {
		rename win2::show win2::show_
		proc win2::show {} { win2::show_; puts "  ok   asked again: this window is raised"; flush stdout; after 200 { exit 0 } }
		puts "serving $win2::sock"; flush stdout
		after 30000 { puts "  FAIL never asked again"; exit 1 }
	}
}
