# pactl.tcl - a fake pactl for Settings → Sound (apps/settings/sound.tcl): answers the list and info commands from the
# pactl-shaped JSON fixtures in tests/fixtures/pactl-json, on the state copies in PACTL_STATE (made by the test step), and
# logs each set-* call to PACTL_LOG, one line each. A set changes the state copy and appends a change event to
# PACTL_STATE/events; `subscribe` prints those events as pactl does ("Event 'change' on sink #1"). Run through the
# fixtures/fake-pactl wrapper (RIBBON_PACTL).
set S $::env(PACTL_STATE)
set LOG $::env(PACTL_LOG)

proc readf {f} {
	set fh [open $f]
	set t [read $fh]
	close $fh
	return $t
}

proc writef {f text} {
	set fh [open $f w]
	puts -nonewline $fh $text
	close $fh
}

# The text of the object in FILE that contains NEEDLE (the top-level objects start with a line "  {"), changed by
# SCRIPT (a command prefix that gets the object's text and returns the new text).
proc edit_object {file needle script} {
	set text [readf $file]
	set bounds [regexp -all -inline -indices {\n  \{\n} $text]
	set ranges {}
	if {[llength $bounds] == 0} {
		lappend ranges [list 0 [expr {[string length $text] - 1}]]
	} else {
		set starts {}
		foreach b $bounds {
			lappend starts [expr {[lindex $b 1] + 1}]
		}
		set k 0
		foreach s $starts {
			if {$k + 1 < [llength $starts]} {
				set end [expr {[lindex [lindex $bounds [expr {$k + 1}]] 0] - 1}]
			} else {
				set end [expr {[string length $text] - 1}]
			}
			lappend ranges [list $s $end]
			incr k
		}
	}
	foreach r $ranges {
		lassign $r s e
		set chunk [string range $text $s $e]
		if {[string first $needle $chunk] < 0} continue
		set new [{*}$script $chunk]
		writef $file "[string range $text 0 [expr {$s - 1}]]$new[string range $text [expr {$e + 1}] end]"
		return
	}
	error "no object with $needle in $file"
}

# Channel volumes: the value_percent of each channel in order, set to VALS (one value for all, or one each).
proc set_channels {vals chunk} {
	set hits [regexp -all -inline -indices {"value_percent": "[^"]*"} $chunk]
	set n [llength $hits]
	for {set j [expr {$n - 1}]} {$j >= 0} {incr j -1} {
		lassign [lindex $hits $j] hs he
		set v [expr {[llength $vals] == 1 ? [lindex $vals 0] : [lindex $vals $j]}]
		set chunk "[string range $chunk 0 [expr {$hs - 1}]]\"value_percent\": \"${v}%\"[string range $chunk [expr {$he + 1}] end]"
	}
	return $chunk
}

proc set_mute_in {on chunk} {
	if {$on} { set v true } else { set v false }
	regsub {"mute": (true|false)} $chunk "\"mute\": $v"
}

proc set_profile_in {name chunk} {
	regsub {"active_profile": "[^"]*"} $chunk "\"active_profile\": \"$name\""
}

proc event {what} {
	global S
	set fh [open [file join $S events] a]
	puts $fh "Event 'change' on $what"
	close $fh
}

proc logline {args} {
	global LOG
	set fh [open $LOG a]
	puts $fh [join $args " "]
	close $fh
}

# The file of a list.
set files {sinks sinks.json sources sources.json sink-inputs sink-inputs.json cards cards.json info info.json}

set args $argv
while {[lindex $args 0] eq "-f"} { set args [lrange $args 2 end] }
set cmd [lindex $args 0]
set rest [lrange $args 1 end]

switch -glob -- $cmd {
	info {
		puts -nonewline [readf [file join $S info.json]]
	}
	list {
		set what [lindex $rest 0]
		puts -nonewline [readf [file join $S ${what}.json]]
	}
	subscribe {
		set ev [file join $S events]
		close [open $ev a]
		set pos [file size $ev]
		# it ends with its reader (a broken pipe) or after 100 s, so a test that dies leaves no pactl behind
		set end [expr {[clock seconds] + 100}]
		while {[clock seconds] < $end} {
			set size [file size $ev]
			if {$size > $pos} {
				set fh [open $ev]
				seek $fh $pos
				set text [read $fh]
				close $fh
				if {[catch {puts -nonewline $text; flush stdout}]} {exit 0}
				set pos $size
			}
			after 30
		}
		exit 0
	}
	set-sink-volume {
		lassign $rest id
		set vals [lrange $rest 1 end]
		logline set-sink-volume $id {*}$vals
		edit_object [file join $S sinks.json] "\"index\": $id," [list set_channels $vals]
		event "sink #$id"
	}
	set-source-volume {
		lassign $rest id
		set vals [lrange $rest 1 end]
		logline set-source-volume $id {*}$vals
		edit_object [file join $S sources.json] "\"index\": $id," [list set_channels $vals]
		event "source #$id"
	}
	set-sink-input-volume {
		lassign $rest id
		set vals [lrange $rest 1 end]
		logline set-sink-input-volume $id {*}$vals
		edit_object [file join $S sink-inputs.json] "\"index\": $id," [list set_channels $vals]
		event "sink-input #$id"
	}
	set-sink-mute {
		lassign $rest id on
		logline set-sink-mute $id $on
		edit_object [file join $S sinks.json] "\"index\": $id," [list set_mute_in $on]
		event "sink #$id"
	}
	set-source-mute {
		lassign $rest id on
		logline set-source-mute $id $on
		edit_object [file join $S sources.json] "\"index\": $id," [list set_mute_in $on]
		event "source #$id"
	}
	set-sink-input-mute {
		lassign $rest id on
		logline set-sink-input-mute $id $on
		edit_object [file join $S sink-inputs.json] "\"index\": $id," [list set_mute_in $on]
		event "sink-input #$id"
	}
	set-default-sink {
		lassign $rest name
		logline set-default-sink $name
		set text [readf [file join $S info.json]]
		regsub {"default_sink_name": "[^"]*"} $text "\"default_sink_name\": \"$name\"" text
		writef [file join $S info.json] $text
		event "server"
	}
	set-default-source {
		lassign $rest name
		logline set-default-source $name
		set text [readf [file join $S info.json]]
		regsub {"default_source_name": "[^"]*"} $text "\"default_source_name\": \"$name\"" text
		writef [file join $S info.json] $text
		event "server"
	}
	set-card-profile {
		lassign $rest name profile
		logline set-card-profile $name $profile
		edit_object [file join $S cards.json] "\"name\": \"$name\"" [list set_profile_in $profile]
		event "card #5"
	}
	default {
		puts stderr "fake pactl: unknown command $cmd"
		exit 1
	}
}
