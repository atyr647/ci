# openwith.tcl - "Opens with" choices for one file, kept apart from the type's default
# (mimeapps.list). The choices are in $XDG_STATE_HOME/ribbon/openwith (default
# ~/.local/state/ribbon/openwith): one line per file, the path, a TAB, then the app's
# desktop id. Writes replace the file atomically (a temp file, then rename).
#
# Files' open action reads it first (shell/files.tcl), the Inspector's "Every <type>
# file" switch writes it when the switch is off, and renames, moves and deletes keep
# it in step. Sourced by the shell and by Properties; defines openwith:: procs only.

namespace eval openwith {}

proc openwith::store {} {
	set state [expr {[info exists ::env(XDG_STATE_HOME)] && $::env(XDG_STATE_HOME) ne ""
		? $::env(XDG_STATE_HOME) : [expr {[info exists ::env(HOME)] ? "$::env(HOME)/.local/state" : "/tmp"}]}]
	return [file join $state ribbon openwith]
}

# All {path app} pairs in file order; a malformed line is skipped.
proc openwith::table {} {
	set out {}
	set f [openwith::store]
	if {[catch {open $f r} fh]} { return $out }
	fconfigure $fh -encoding utf-8
	foreach line [split [read $fh] \n] {
		if {[regexp {^([^\t]+)\t(\S+)$} $line -> p app]} { lappend out [list $p $app] }
	}
	close $fh
	return $out
}

# The app chosen for PATH, or "" when the type's default applies.
proc openwith::get {path} {
	set app ""
	foreach pair [openwith::table] {
		if {[lindex $pair 0] eq $path} { set app [lindex $pair 1] }
	}
	return $app
}

# Write PAIRS atomically.
proc openwith::write {pairs} {
	set f [openwith::store]
	file mkdir [file dirname $f]
	set tmp $f.tmp[pid]
	set fh [open $tmp w]
	fconfigure $fh -encoding utf-8 -translation lf
	foreach pair $pairs { puts $fh "[lindex $pair 0]\t[lindex $pair 1]" }
	close $fh
	file rename -force $tmp $f
}

# A path with a TAB or a newline cannot be kept in the file; it is not stored.
proc openwith::storable {path} { expr {![regexp {[\t\n\r]} $path]} }

# Choose APP for PATH; "" forgets the choice (the type's default applies again).
proc openwith::choose {path app} {
	if {![openwith::storable $path]} { return 0 }
	set pairs {}
	foreach pair [openwith::table] { if {[lindex $pair 0] ne $path} { lappend pairs $pair } }
	if {$app ne ""} { lappend pairs [list $path $app] }
	if {[llength $pairs] == [llength [openwith::table]] && $app eq ""} return
	openwith::write $pairs
	return 1
}

# PATH was renamed or moved to NEW: its choice and those of what is inside it follow.
proc openwith::moved {old new} {
	if {$old eq $new || ![openwith::storable $new]} return
	set pairs {}
	foreach pair [openwith::table] {
		lassign $pair p app
		if {$p eq $new} continue
		if {$p eq $old} { set p $new } elseif {[string first $old/ $p] == 0} { set p $new[string range $p [string length $old] end] }
		lappend pairs [list $p $app]
	}
	openwith::write $pairs
}

# PATH was deleted: its choice and those of what is inside it go.
proc openwith::forget {path} {
	set pairs {}
	foreach pair [openwith::table] {
		set p [lindex $pair 0]
		if {$p eq $path || [string first $path/ $p] == 0} continue
		lappend pairs $pair
	}
	openwith::write $pairs
}
