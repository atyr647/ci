# thread.tcl - conversations (U39). No Tk. Messages are threaded by Message-ID and References (In-Reply-To where
# a message has no References) with Jamie Zawinski's algorithm (https://www.jwz.org/doc/threading.html): the
# references build a tree of containers, links that would make a loop are refused, empty containers are pruned,
# and the roots that are left are joined by subject. Unlike the original, two roots are joined by subject only
# when one of them is a reply ("Re: Invoice" joins "Invoice"; two monthly "Invoice" mails stay apart). A message
# that comes twice (the same Message-ID in Inbox and in Sent) is kept once, the first given.
#
#   mail::thread::build SUMMARIES           the conversations of store summaries, newest first (see below)
#   mail::thread::view VIEW                 the conversations of a store view: every message of the view's
#                                           accounts (outside junk and trash) is threaded, so a reply from Sent
#                                           is in its conversation, and the conversations with a message in the
#                                           view are kept
#   mail::thread::base_subject SUBJECT      the subject without Re:/Fwd:/[list] prefixes
#   mail::thread::is_reply SUBJECT          1 when it starts with Re: (or a translation of it)
#   mail::thread::day_group T ?NOW?         today, yesterday, week (2 to 6 days ago) or earlier
#   mail::thread::when_list T ?NOW?         the list's time: 10:31, Yesterday, Thursday, 2 Oct, 2 Oct 2025
#   mail::thread::when_reader T ?NOW?       a message's time: Today, 10:31 / Yesterday, 18:05 / Tue, 09:02 /
#                                           2 Oct, 09:02 / 2 Oct 2025, 09:02
#   mail::thread::recipients SUMMARY MINE   "to me, Jonas Ek, Lea Moreau" (MINE: your addresses)
#   mail::thread::name ADDRESS              the name to show for a {name address} pair
#
# A conversation is a dict: key (its first message's key), subject (its first message's), sender (the first
# message's sender's name), msgs (the summaries, oldest first, each with parent: the key of the message it
# answers, or ""), count, latest (the newest message's date), last (the newest message), unread (how many),
# flagged (any), labels and accounts (in the order met), atts (every attachment, the newest message's first, each
# with its message's key, sender and date added). view adds inview (the keys of its messages in the view) and
# shown (the newest of them: the list shows its time and snippet, and is sorted by it).

namespace eval ::mail::thread {
	variable tz ""   ;# the time zone for times; "" is the system's
}

proc ::mail::thread::base_subject {s} {
	set s [string trim $s]
	while 1 {
		set before $s
		# Re: Re[2]: Fwd: Fw: and their translations (Aw, Sv, Vs, Antw, Odp, Wg, Tr, Rv, Ynt, Res)
		regsub -nocase {^(re|fwd?|aw|sv|vs|antw|odp|wg|tr|rv|ynt|res|ref|r\u00e9f)\s*(\[\d+\]|\(\d+\))?\s*:\s*} $s {} s
		regsub {^\[[^\]]*\]\s*} $s {} s
		regsub -nocase {\s*\((fwd|fw)\)$} $s {} s
		set s [string trim $s]
		if {$s eq $before} break
	}
	return [string tolower [regsub -all {\s+} $s " "]]
}

proc ::mail::thread::is_reply {s} {
	set s [string trim $s]
	regsub {^(\[[^\]]*\]\s*)+} $s {} s
	return [regexp -nocase {^(re|aw|sv|vs|antw|odp|ynt|res|r)\s*(\[\d+\]|\(\d+\))?\s*:} $s]
}

# Is A the same as, or below, B? (Walks up from A.)
proc ::mail::thread::below {a b} {
	upvar 1 parent parent
	set seen {}
	while {$a ne ""} {
		if {$a eq $b} { return 1 }
		if {[dict exists $seen $a]} { return 0 }
		dict set seen $a 1
		set a $parent($a)
	}
	return 0
}

proc ::mail::thread::unlink {c} {
	upvar 1 parent parent kids kids
	set p $parent($c)
	if {$p eq ""} return
	set i [lsearch -exact $kids($p) $c]
	if {$i >= 0} { set kids($p) [lreplace $kids($p) $i $i] }
	set parent($c) ""
}

proc ::mail::thread::link {p c} {
	upvar 1 parent parent kids kids
	unlink $c
	set parent($c) $p
	lappend kids($p) $c
}

proc ::mail::thread::container {id} {
	upvar 1 parent parent kids kids msg msg
	if {![info exists parent($id)]} {
		set parent($id) ""
		set kids($id) {}
		set msg($id) ""
	}
}

proc ::mail::thread::build {sums} {
	array set parent {}
	array set kids {}
	array set msg {}
	set fake 0
	set seen {}
	# 1. a container per Message-ID, and the reference chains as parent links
	foreach s $sums {
		set id [dict get $s msgid]
		if {$id ne "" && [info exists msg($id)] && $msg($id) ne ""} continue
		if {$id eq ""} { set id "\0[incr fake]" }
		container $id
		set msg($id) $s
		set prev ""
		foreach r [dict get $s refs] {
			if {$r eq $id} continue
			container $r
			# a link the references already give is not changed; one that would make a loop is refused
			if {$prev ne "" && $parent($r) eq "" && ![below $prev $r]} { link $prev $r }
			set prev $r
		}
		# the message's own parent is the last reference, whatever an earlier message's references said
		unlink $id
		if {$prev ne "" && ![below $prev $id]} { link $prev $id }
	}
	# 2. the roots
	set roots {}
	foreach id [array names parent] {
		if {$parent($id) eq ""} { lappend roots $id }
	}
	set roots [lsort $roots]
	# 3. empty containers pruned: one with no children goes; one with children gives them to its parent, except
	# at the top where it stays to hold two or more
	set roots [prune $roots]
	# 4. roots joined by subject: a reply (or an empty container) whose subject an original (a root that is not
	# a reply) has goes under the newest such original not later than it, else under the oldest; replies with no
	# original go under the oldest of them
	set groups {}
	foreach r $roots {
		set s [subject_of $r]
		if {$s ne ""} { dict lappend groups $s $r }
	}
	set joined {}
	dict for {s rs} $groups {
		if {[llength $rs] < 2} continue
		set orig {}
		set rest {}
		set dated {}
		foreach r $rs { lappend dated [list [first_date $r] $r] }
		foreach d [lsort -integer -index 0 [lsort -index 1 $dated]] {
			set r [lindex $d 1]
			set fd($r) [lindex $d 0]
			if {$msg($r) ne "" && ![is_reply [dict get $msg($r) subject]]} { lappend orig $r } else { lappend rest $r }
		}
		if {$orig eq ""} { set orig [list [lindex $rest 0]]; set rest [lrange $rest 1 end] }
		foreach r $rest {
			set to [lindex $orig 0]
			foreach o $orig { if {$fd($o) <= $fd($r)} { set to $o } }
			# under the original: the flattening below passes through an empty container
			link $to $r
			dict set joined $r 1
		}
	}
	set out {}
	foreach r $roots {
		if {![dict exists $joined $r]} { lappend out $r }
	}
	# 5. each root's tree, flattened oldest first
	set convs {}
	foreach r $out {
		set ms {}
		set stack [list [list $r ""]]
		while {[llength $stack]} {
			lassign [lindex $stack end] c up
			set stack [lrange $stack 0 end-1]
			set here $up
			if {$msg($c) ne ""} {
				lappend ms [dict replace $msg($c) parent $up]
				set here [dict get $msg($c) key]
			}
			foreach k [lreverse $kids($c)] { lappend stack [list $k $here] }
		}
		if {$ms eq ""} continue
		lappend convs [conversation [::mail::store::sort_by_date $ms]]
	}
	return [lsort -command {apply {{a b} {
		set c [expr {[dict get $b latest] - [dict get $a latest]}]
		if {$c != 0} { return [expr {$c < 0 ? -1 : 1}] }
		return [string compare [dict get $a key] [dict get $b key]]
	}}} $convs]
}

proc ::mail::thread::prune {roots} {
	upvar 1 parent parent kids kids msg msg
	# without recursion: a References chain thousands long (hostile or broken mail) is as deep as it is long
	set order {}
	set stack $roots
	while {[llength $stack]} {
		set x [lindex $stack end]
		set stack [lreplace $stack end end]
		lappend order $x
		lappend stack {*}$kids($x)
	}
	# every container after its children: an empty one with children gives them to its parent in its place
	foreach x [lreverse $order] {
		set nk {}
		foreach c $kids($x) {
			if {$msg($c) ne ""} { lappend nk $c; continue }
			foreach k $kids($c) {
				set parent($k) $x
				lappend nk $k
			}
			set kids($c) {}
		}
		set kids($x) $nk
	}
	# at the top an empty container stays to hold two or more; with one, that one is the root
	set out {}
	foreach c $roots {
		if {$msg($c) ne "" || [llength $kids($c)] > 1} { lappend out $c; continue }
		lappend out {*}$kids($c)
		set kids($c) {}
	}
	foreach c $out { set parent($c) "" }
	return $out
}

# The date of the oldest message in a container's tree.
proc ::mail::thread::first_date {c} {
	upvar 1 msg msg kids kids
	set best ""
	set stack [list $c]
	while {[llength $stack]} {
		set x [lindex $stack end]
		set stack [lrange $stack 0 end-1]
		if {$msg($x) ne "" && ($best eq "" || [dict get $msg($x) date] < $best)} { set best [dict get $msg($x) date] }
		lappend stack {*}$kids($x)
	}
	return [expr {$best eq "" ? 0 : $best}]
}

proc ::mail::thread::subject_of {c} {
	upvar 1 msg msg kids kids
	if {$msg($c) ne ""} { return [base_subject [dict get $msg($c) subject]] }
	foreach k $kids($c) {
		if {$msg($k) ne ""} { return [base_subject [dict get $msg($k) subject]] }
	}
	return ""
}

proc ::mail::thread::conversation {ms} {
	set first [lindex $ms 0]
	set last [lindex $ms end]
	set unread 0
	set flagged 0
	set labels {}
	set accounts {}
	set atts {}
	foreach m $ms {
		if {[dict get $m unread]} { incr unread }
		if {[dict get $m flagged]} { set flagged 1 }
		foreach l [dict get $m labels] { if {$l ni $labels} { lappend labels $l } }
		if {[dict get $m account] ni $accounts} { lappend accounts [dict get $m account] }
	}
	foreach m [lreverse $ms] {
		foreach a [dict get $m atts] {
			lappend atts [dict merge $a [dict create key [dict get $m key] from [dict get $m from] date [dict get $m date]]]
		}
	}
	return [dict create key [dict get $first key] subject [dict get $first subject] sender [name [dict get $first from]] \
		msgs $ms count [llength $ms] latest [dict get $last date] last $last unread $unread flagged $flagged \
		labels $labels accounts $accounts atts $atts]
}

proc ::mail::thread::view {v} {
	set inview [::mail::store::view $v]
	set keys {}
	set accts {}
	foreach s $inview {
		dict set keys [dict get $s key] 1
		if {[dict get $s account] ni $accts} { lappend accts [dict get $s account] }
	}
	# the view's own messages come first, so a copy of a message in the view wins over its copy elsewhere
	set all $inview
	foreach a $accts {
		foreach s [::mail::store::view [list account $a]] {
			if {![dict exists $keys [dict get $s key]]} { lappend all $s }
		}
		# a conversation in junk or trash is threaded with what the view holds of it there
	}
	set out {}
	foreach c [build $all] {
		set mine {}
		foreach m [dict get $c msgs] {
			if {[dict exists $keys [dict get $m key]]} { lappend mine [dict get $m key] }
		}
		if {$mine eq ""} continue
		set shown ""
		foreach m [dict get $c msgs] {
			if {[dict exists $keys [dict get $m key]]} { set shown $m }
		}
		lappend out [dict replace $c inview $mine shown $shown]
	}
	# the list is in the order of the newest message of each conversation that the view holds
	return [lsort -command {apply {{a b} {
		set c [expr {[dict get $b shown date] - [dict get $a shown date]}]
		if {$c != 0} { return [expr {$c < 0 ? -1 : 1}] }
		return [string compare [dict get $a key] [dict get $b key]]
	}}} $out]
}

# ---- times and names ---------------------------------------------------------------------------------

proc ::mail::thread::fmt {t f} {
	variable tz
	if {$tz ne ""} { return [clock format $t -format $f -timezone $tz -locale C] }
	return [clock format $t -format $f -locale C]
}

proc ::mail::thread::days_ago {t now} {
	variable tz
	set opts [expr {$tz ne "" ? [list -timezone $tz] : {}}]
	set d0 [clock scan [fmt $now %Y-%m-%d] -format %Y-%m-%d {*}$opts]
	set d1 [clock scan [fmt $t %Y-%m-%d] -format %Y-%m-%d {*}$opts]
	# a day is not always 86400 seconds (summer time): round
	return [expr {round(($d0 - $d1) / 86400.0)}]
}

proc ::mail::thread::day_group {t {now ""}} {
	if {$now eq ""} { set now [clock seconds] }
	set d [days_ago $t $now]
	if {$d <= 0} { return today }
	if {$d == 1} { return yesterday }
	if {$d <= 6} { return week }
	return earlier
}

proc ::mail::thread::when_list {t {now ""}} {
	if {$now eq ""} { set now [clock seconds] }
	switch [day_group $t $now] {
		today { return [fmt $t %H:%M] }
		yesterday { return Yesterday }
		week { return [fmt $t %A] }
	}
	if {[fmt $t %Y] eq [fmt $now %Y]} { return [string trim [fmt $t "%e %b"]] }
	return [string trim [fmt $t "%e %b %Y"]]
}

proc ::mail::thread::when_reader {t {now ""}} {
	if {$now eq ""} { set now [clock seconds] }
	set hm [fmt $t %H:%M]
	switch [day_group $t $now] {
		today { return "Today, $hm" }
		yesterday { return "Yesterday, $hm" }
		week { return "[fmt $t %a], $hm" }
	}
	if {[fmt $t %Y] eq [fmt $now %Y]} { return "[string trim [fmt $t "%e %b"]], $hm" }
	return "[string trim [fmt $t "%e %b %Y"]], $hm"
}

proc ::mail::thread::name {addr} {
	lassign $addr n a
	if {[string trim $n] ne ""} { return [string trim $n] }
	return $a
}

proc ::mail::thread::recipients {s mine} {
	set lower {}
	foreach m $mine { lappend lower [string tolower $m] }
	set me 0
	set names {}
	foreach a [concat [dict get $s to] [dict get $s cc]] {
		if {[string tolower [lindex $a 1]] in $lower} { set me 1; continue }
		set n [name $a]
		if {$n ne "" && $n ni $names} { lappend names $n }
	}
	if {$me} { set names [linsert $names 0 me] }
	if {$names eq ""} { return "" }
	return "to [join $names {, }]"
}
