# markdown.tcl - the Markdown of a note (U33): the front matter (pinned), the #tags, the title, each line's kind
# and the inline spans on a line. Pure string code: the editor draws what this returns, and the store writes back
# exactly the text it read (build of parse is the identity for a note whose pinned line is "pinned: true").
#
#   notes::md::parse TEXT          dict: pinned 0|1, has_fm 0|1, fm (its lines, pinned line included), body
#   notes::md::build PINNED HAS_FM FM BODY   the file's text
#   notes::md::lines BODY          one entry per line: {fence} {code} {h LEVEL TEXT} {box DONE TEXT} {image ALT PATH}
#                                  {bullet} {quote} {plain}; each entry's last element is the raw line
#   notes::md::spans LINE          {from to tags} for the inline marks (code, bold, italic, strike ~~text~~, link); the
#                                  markers are tagged "elide"
#   notes::md::tags BODY           the #tags (lower case, sorted, unique), outside code
#   notes::md::title BODY          the text of the first level-1 heading, or ""

namespace eval ::notes::md {}

proc ::notes::md::parse {text} {
	set pinned 0
	set has 0
	set fm {}
	set body $text
	if {[string match "---\n*" $text]} {
		set lines [split $text \n]
		set n [llength $lines]
		for {set i 1} {$i < $n} {incr i} {
			if {[lindex $lines $i] eq "---"} {
				set has 1
				set fm [lrange $lines 1 [expr {$i - 1}]]
				set body [join [lrange $lines [expr {$i + 1}] end] \n]
				break
			}
		}
	}
	foreach l $fm {
		if {[regexp {^pinned:\s*(\S+)\s*$} $l -> v] && [string tolower $v] in {true yes 1}} { set pinned 1 }
	}
	return [dict create pinned $pinned has_fm $has fm $fm body $body]
}

proc ::notes::md::build {pinned has_fm fm body} {
	set out {}
	set found 0
	foreach l $fm {
		if {[regexp {^pinned:} $l]} {
			set found 1
			lappend out "pinned: [expr {$pinned ? {true} : {false}}]"
		} else {
			lappend out $l
		}
	}
	if {!$found && $pinned} { set out [linsert $out 0 "pinned: true"] }
	if {!$has_fm && [llength $out] == 0} { return $body }
	set head "---\n"
	foreach l $out { append head $l "\n" }
	return "$head---\n$body"
}

proc ::notes::md::lines {body} {
	set out {}
	set fence 0
	foreach line [split $body \n] {
		if {[regexp {^\s*```} $line]} {
			set fence [expr {!$fence}]
			lappend out [list fence $line]
		} elseif {$fence} {
			lappend out [list code $line]
		} elseif {[regexp {^(#{1,6}) (.*)$} $line -> h t]} {
			lappend out [list h [string length $h] $t $line]
		} elseif {[regexp {^\s*[-*] \[( |x|X)\] (.*)$} $line -> c t]} {
			lappend out [list box [expr {$c ne " "}] $t $line]
		} elseif {[regexp {^!\[([^\]]*)\]\(([^)]*)\)\s*$} $line -> alt path]} {
			lappend out [list image $alt $path $line]
		} elseif {[regexp {^\s*[-*] } $line]} {
			lappend out [list bullet $line]
		} elseif {[regexp {^> } $line]} {
			lappend out [list quote $line]
		} else {
			lappend out [list plain $line]
		}
	}
	return $out
}

# Each entry is {kind ... raw}: the raw line is the last element.
proc ::notes::md::raw {entry} { lindex $entry end }

proc ::notes::md::spans {line} {
	set out {}
	set re {`([^`]+)`|\*\*([^*]+)\*\*|\*([^*\s][^*]*)\*|~~([^~]+)~~|\[([^\]]+)\]\(([^)]+)\)}
	set pos 0
	while {[regexp -indices -start $pos $re $line m g1 g2 g3 gs g4 g5]} {
		lassign $m s e
		if {[lindex $g1 0] >= 0} {
			lappend out [list $s [expr {$s + 1}] elide] [list [expr {$s + 1}] $e code] [list $e [expr {$e + 1}] elide]
		} elseif {[lindex $g2 0] >= 0} {
			lappend out [list $s [expr {$s + 2}] elide] [list [expr {$s + 2}] [expr {$e - 1}] bold] [list [expr {$e - 1}] [expr {$e + 1}] elide]
		} elseif {[lindex $g3 0] >= 0} {
			lappend out [list $s [expr {$s + 1}] elide] [list [expr {$s + 1}] $e italic] [list $e [expr {$e + 1}] elide]
		} elseif {[lindex $gs 0] >= 0} {
			lappend out [list $s [expr {$s + 2}] elide] [list [expr {$s + 2}] [expr {$e - 1}] strike] [list [expr {$e - 1}] [expr {$e + 1}] elide]
		} else {
			# [text](url): the brackets and the target are marks; the text is the link
			lappend out [list $s [expr {$s + 1}] elide] [list [lindex $g4 0] [expr {[lindex $g4 1] + 1}] link] \
				[list [expr {[lindex $g4 1] + 1}] [expr {$e + 1}] elide]
		}
		set pos [expr {$e + 1}]
	}
	return $out
}

proc ::notes::md::tags {body} {
	set found {}
	foreach entry [lines $body] {
		set k [lindex $entry 0]
		if {$k in {fence code image}} continue
		set line [regsub -all {`[^`]*`} [raw $entry] {}]
		foreach {all t} [regexp -all -inline {(?:^|\s)#([[:alpha:]][[:alnum:]_/-]*)} $line] {
			lappend found [string tolower $t]
		}
	}
	return [lsort -unique $found]
}

proc ::notes::md::title {body} {
	foreach entry [lines $body] {
		if {[lindex $entry 0] eq "h" && [lindex $entry 1] == 1} { return [lindex $entry 2] }
	}
	return ""
}
