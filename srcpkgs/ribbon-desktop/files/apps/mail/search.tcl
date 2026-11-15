# search.tcl - mail search (U39), the model of Mail-A4-Search. No Tk. A query is words and from: tokens
# (from:anna, from:"Anna Berg", or "from: anna" as the field's token chip gives it). A message matches when every
# word is found (case-insensitive, inside words too: "floor" finds "studio-floor.png") in its subject, its text
# or its attachments' names, and, with from: tokens, its sender's name or address holds one of them. Results are
# conversations: one row per conversation with a match, showing its newest matching message.
#
#   mail::search::parse QUERY        dict from (lowercased tokens) words (lowercased)
#   mail::search::matches S Q        1 when summary S matches the parsed query Q
#   mail::search::spans TEXT WORDS   the {start end} ranges (end exclusive) of the words in TEXT, merged where
#                                    only one character lies between two ("Floor plan" is one highlight)
#   mail::search::snippet TEXT WORDS the preview of a result: from the start, or from the sentence of the first
#                                    match when that is further in; dict text spans
#   mail::search::run QUERY ?SCOPE?  SCOPE: all (default; every folder but junk and trash), inbox, or
#                                    {account NAME}. dict rows atts:
#     rows: one dict per conversation, newest first: msg (the summary), count (messages in the conversation),
#           subject_spans, snippet ({text spans}), att_spans (per attachment of msg, in order)
#     atts: the attachments of the messages that pass the from: tokens whose names hold a word (all of them
#           when the query has no words), newest first: the attachment dict (section name size type inline
#           key from date) with spans

namespace eval ::mail::search {}

proc ::mail::search::parse {query} {
	set from {}
	set words {}
	set q [string trim $query]
	while {$q ne ""} {
		if {[regexp -nocase {^from:\s*"([^"]*)"?\s*(.*)$} $q -> v q] || [regexp -nocase {^from:\s*([^\s"]+)\s*(.*)$} $q -> v q]} {
			if {[string trim $v] ne ""} { lappend from [string tolower [string trim $v]] }
			continue
		}
		if {[regexp {^"([^"]*)"?\s*(.*)$} $q -> v q]} {
			foreach w [regexp -all -inline {\S+} [string tolower $v]] { lappend words $w }
			continue
		}
		regexp {^(\S+)\s*(.*)$} $q -> w q
		# a lone from: with nothing after it is not a word
		if {[string tolower $w] ne "from:"} { lappend words [string tolower $w] }
	}
	return [dict create from $from words $words]
}

proc ::mail::search::from_ok {s q} {
	set from [dict get $q from]
	if {$from eq ""} { return 1 }
	lassign [dict get $s from] n a
	set hay [string tolower "$n\n$a"]
	foreach f $from {
		if {[string first $f $hay] >= 0} { return 1 }
	}
	return 0
}

proc ::mail::search::matches {s q} {
	if {![from_ok $s $q]} { return 0 }
	set words [dict get $q words]
	if {$words eq ""} { return [expr {[dict get $q from] ne ""}] }
	set names {}
	foreach a [dict get $s atts] { lappend names [dict get $a name] }
	set hay [string tolower "[dict get $s subject]\n[dict get $s text]\n[join $names \n]"]
	foreach w $words {
		if {[string first $w $hay] < 0} { return 0 }
	}
	return 1
}

proc ::mail::search::spans {text words} {
	set lower [string tolower $text]
	set raw {}
	foreach w $words {
		set n [string length $w]
		if {$n == 0} continue
		set i 0
		while {[set at [string first $w $lower $i]] >= 0} {
			lappend raw [list $at [expr {$at + $n}]]
			set i [expr {$at + $n}]
		}
	}
	set out {}
	foreach r [lsort -integer -index 0 $raw] {
		lassign $r a b
		if {[llength $out] && $a <= [lindex $out end 1] + 1} {
			lset out end 1 [expr {max([lindex $out end 1], $b)}]
		} else {
			lappend out $r
		}
	}
	return $out
}

proc ::mail::search::snippet {text words {len 200}} {
	set lower [string tolower $text]
	set first -1
	foreach w $words {
		set at [string first $w $lower]
		if {$at >= 0 && ($first < 0 || $at < $first)} { set first $at }
	}
	set start 0
	if {$first >= 40} {
		# from the start of the sentence that holds the first match, if it is near; else from the word
		set start $first
		set cut [expr {max(0, $first - 80)}]
		set head [string range $text $cut [expr {$first - 1}]]
		set end -1
		foreach m [regexp -all -inline -indices {[.!?;:]\s} $head] { set end [lindex $m 1] }
		if {$end >= 0} {
			set start [expr {$cut + $end + 1}]
		} else {
			set sp [string last " " $text [expr {$first - 1}]]
			if {$sp >= 0 && $first - $sp < 30} { set start [expr {$sp + 1}] }
		}
	}
	set s [string trim [string range $text $start [expr {$start + $len - 1}]]]
	if {$start + $len < [string length $text]} {
		set sp [string last " " $s]
		if {$sp > $len / 2} { set s [string range $s 0 [expr {$sp - 1}]] }
		append s "\u2026"
	}
	if {$start > 0 && ![regexp {[.!?;:]\s*$} [string range $text 0 [expr {$start - 1}]]]} { set s "\u2026$s" }
	return [dict create text $s spans [spans $s $words]]
}

proc ::mail::search::scope_view {scope} {
	switch -- [lindex $scope 0] {
		all { return all }
		inbox { return inboxes }
		account { return [list account [lindex $scope 1]] }
		default { error "unknown search scope: $scope" }
	}
}

proc ::mail::search::run {query {scope all}} {
	set q [parse $query]
	set words [dict get $q words]
	set rows {}
	set atts {}
	if {$words eq "" && [dict get $q from] eq ""} { return [dict create rows {} atts {}] }
	set sums [::mail::store::view [scope_view $scope]]
	set hit {}
	foreach s $sums {
		if {[matches $s $q]} { dict set hit [dict get $s key] 1 }
		if {![from_ok $s $q]} continue
		foreach a [dict get $s atts] {
			set sp [spans [dict get $a name] $words]
			if {$words ne "" && $sp eq ""} continue
			lappend atts [dict merge $a [dict create key [dict get $s key] from [dict get $s from] date [dict get $s date] spans $sp]]
		}
	}
	if {[dict size $hit]} {
		# conversations: every message of the accounts searched is threaded, so a hit is shown with its count
		set accts {}
		foreach s $sums { if {[dict exists $hit [dict get $s key]] && [dict get $s account] ni $accts} { lappend accts [dict get $s account] } }
		set all {}
		set have {}
		foreach s $sums { if {[dict get $s account] in $accts} { lappend all $s; dict set have [dict get $s key] 1 } }
		foreach a $accts {
			foreach s [::mail::store::view [list account $a]] {
				if {![dict exists $have [dict get $s key]]} { lappend all $s }
			}
		}
		foreach c [::mail::thread::build $all] {
			set best ""
			foreach m [dict get $c msgs] {
				if {[dict exists $hit [dict get $m key]]} { set best $m }
			}
			if {$best eq ""} continue
			set as {}
			foreach a [dict get $best atts] { lappend as [spans [dict get $a name] $words] }
			lappend rows [dict create msg $best count [dict get $c count] subject_spans [spans [dict get $best subject] $words] \
				snippet [snippet [dict get $best text] $words] att_spans $as]
		}
		set rows [lsort -command {apply {{a b} {
			set c [expr {[dict get $b msg date] - [dict get $a msg date]}]
			expr {$c < 0 ? -1 : ($c > 0 ? 1 : 0)}
		}}} $rows]
	}
	set atts [lsort -command {apply {{a b} {
		set c [expr {[dict get $b date] - [dict get $a date]}]
		expr {$c < 0 ? -1 : ($c > 0 ? 1 : 0)}
	}}} $atts]
	return [dict create rows $rows atts $atts]
}
