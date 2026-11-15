# history.tcl - System monitor: rolling histories (U24). A series keeps one value a second
# for the last minute, ten minutes and an hour (three rings, trimmed on each push).
# Named monitor::ring, not history, so it does not shadow Tcl's history command.

namespace eval monitor::ring {
	variable spans {60 600 3600}
	variable data
	array set data {}
}

# Add one value to the series KEY (for example "cpu" or "gpu") in all three rings.
proc monitor::ring::push {key value} {
	variable spans
	variable data
	foreach n $spans {
		set k "$key/$n"
		set l [expr {[info exists data($k)] ? $data($k) : {}}]
		lappend l $value
		if {[llength $l] > $n} { set l [lrange $l end-[expr {$n - 1}] end] }
		set data($k) $l
	}
}

# The values of KEY over the last SPAN seconds (60, 600 or 3600), oldest first.
proc monitor::ring::series {key span} {
	variable data
	if {[info exists data($key/$span)]} { return $data($key/$span) }
	return {}
}
