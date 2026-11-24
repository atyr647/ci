# ui-rail.tcl - the rail (U41, Mail-A-Ledger): the Mail head with New message, the search field (from: tokens as
# a chip, Mail-A4-Search), the unified mailboxes, each account as a tree of its folders, the labels, Trash at the
# foot. Counts: the inboxes, accounts and their folders show unread mail; Flagged and Drafts show how many there
# are; Sent and Archive show none. An account's tree leaves out its Drafts and Trash (unified above and below).

namespace eval ::mailapp {
	variable rscroll 0           ;# the rail's scroll, between the search field and Trash
	variable rail_end 0
	variable rclip 0             ;# rows outside that band are left out
}

proc ::mailapp::rail_max {} {
	variable rail_end
	variable H
	expr {max(0, $rail_end - ($H - 56))}
}

# Is a rail row of height H at Y inside the band (always, outside the scrolled part)?
proc ::mailapp::rail_in {y h} {
	expr {!$::mailapp::rclip || ($y >= 116 && $y + $h <= $::mailapp::H - 56)}
}

# A rail row of 34 px at Y. LEAD: an icon name, or {avatar NAME}. N: the count ("" none); CHEV: "", open, closed.
proc ::mailapp::ritem {y lead text n on depth strong script {chev ""}} {
	variable c
	if {![rail_in $y 34]} return
	set x0 [expr {14 + 22 * $depth}]
	if {$on} {
		ui::box 14 $y 204 34 -fill $c(field) -radius 9
		ui::box 14 [expr {$y + 8}] 3 18 -fill $c(accent) -radius 2
	}
	if {$depth} { ui::box 35 [expr {$y - 1}] 1 36 -fill $c(border) }
	if {[lindex $lead 0] eq "avatar"} {
		avatar [lindex $lead 1] [expr {$x0 + 12}] [expr {$y + 6}] 22
		set tx [expr {$x0 + 46}]
	} else {
		icon $lead 16 [expr {$on ? $c(accent) : $c(muted)}] [expr {$x0 + 12}] [expr {$y + 9}]
		set tx [expr {$x0 + 40}]
	}
	set bold [expr {$on || $strong}]
	set right 208
	if {$chev ne ""} {
		icon [expr {$chev eq "open" ? "chev" : "right"}] 12 $c(muted) 196 [expr {$y + 11}] 2.2
		set right 188
	}
	if {$n ne "" && $n != 0} {
		ui::text $right [expr {$y + 9.5}] $n [expr {$strong ? "i12s" : "i12m"}] [expr {$strong ? $c(fg) : $c(muted)}] e 0 {} 1
	}
	ui::text $tx [expr {$y + 9}] $text [expr {$bold ? "i13s" : "i13m"}] [expr {$bold ? $c(fg) : $c(muted)}]
	if {$script ne ""} { ui::hit 14 $y 204 34 $script }
}

proc ::mailapp::rlabel {y t} {
	variable c
	if {![rail_in [expr {$y - 6}] 20]} return
	ui::text 26 [expr {$y + 1.5}] [string toupper $t] i11s $c(muted) w 1.32
}

proc ::mailapp::rail_paint {} {
	variable c
	variable H
	variable state
	variable open
	variable rscroll
	variable rclip
	variable rail_end
	ui::box 0 0 232 $H -fill $c(d2)
	ui::box 231 0 1 $H -fill $c(border)
	ui::text 26 26 Mail sg22 $c(fg) w -0.44
	iconbtn edit 184 23 34 16 ::mailapp::compose_new $c(fg) $c(field)
	search_field
	set cur [expr {$state(query) eq "" ? $state(view) : ""}]
	set rscroll [expr {max(0, min($rscroll, [rail_max]))}]
	set rclip 1
	set y [expr {120 - $rscroll}]
	set n [dict get [mail::store::view_count inboxes] unread]
	ritem $y inbox "All inboxes" $n [expr {$cur eq "inboxes"}] 0 [expr {$n > 0}] {::mailapp::show_view inboxes}
	incr y 34
	ritem $y flag Flagged [dict get [mail::store::view_count flagged] total] [expr {$cur eq "flagged"}] 0 0 {::mailapp::show_view flagged}
	incr y 34
	ritem $y draft Drafts [dict get [mail::store::view_count drafts] total] [expr {$cur eq "drafts"}] 0 0 {::mailapp::show_view drafts}
	incr y 34
	ritem $y send Sent "" [expr {$cur eq "sent"}] 0 0 {::mailapp::show_view sent}
	incr y 34
	incr y 18
	rlabel $y Accounts
	if {[info commands ::mail::accounts::sheet] ne "" && [rail_in [expr {$y - 2}] 22]} { iconbtn plus 198 [expr {$y - 2}] 22 14 ::mailapp::add_account }
	incr y 25
	foreach a [mail::store::accounts] {
		set u [mail::store::account_unread $a]
		set isopen [expr {$a in $open}]
		ritem $y [list avatar $a] $a $u [expr {$cur eq [list account $a]}] 0 [expr {$u > 0}] [list ::mailapp::toggle_account $a] \
			[expr {$isopen ? "open" : "closed"}]
		incr y 34
		if {!$isopen} continue
		foreach f [mail::store::folders $a] {
			set role [mail::store::role $f]
			if {$role in {drafts trash}} continue
			set cnt [mail::store::count $a $f]
			set u [expr {$role in {sent archive} ? 0 : [dict get $cnt unread]}]
			set ic [dict get {inbox inbox archive archive sent send junk junk {} inbox} $role]
			if {$role eq ""} { set ic archive }
			set v [list folder $a $f]
			ritem $y $ic $f $u [expr {$cur eq $v}] 1 [expr {$role eq "inbox" && $u > 0}] [list ::mailapp::show_view $v]
			incr y 34
		}
	}
	set labels [mail::store::all_labels]
	if {[llength $labels]} {
		incr y 18
		rlabel $y Labels
		incr y 25
		set x 18
		foreach l $labels {
			set w [expr {18 + [ui::measure i12m "#$l"]}]
			if {$x + $w > 218} { set x 18; incr y 32 }
			if {![rail_in $y 26]} { set x [expr {$x + $w + 6}]; continue }
			if {$cur eq [list label $l]} { ui::box $x $y $w 26 -fill $c(pill) -radius 7 }
			if {$cur ne [list label $l]} { chip $x $y $l } else { ui::text [expr {$x + 9}] [expr {$y + 5.5}] "#$l" i12m $c(fg) }
			ui::hit $x $y $w 26 [list ::mailapp::show_view [list label $l]]
			set x [expr {$x + $w + 6}]
		}
	}
	if {[llength $labels]} { incr y 26 }
	set rail_end [expr {$y + 8 + $rscroll}]
	set rclip 0
	ritem [expr {$H - 48}] trash Trash "" [expr {$cur eq "trash"}] 0 0 {::mailapp::show_view trash}
}

# The search field: "Search", or the query with its from: token as a chip, the caret and the clear cross.
proc ::mailapp::search_field {} {
	variable c
	variable state
	set focus [expr {$state(searchfocus) || $state(query) ne ""}]
	ui::box 14 72 204 34 -fill $c(field) -radius 9
	if {$focus} {
		ui::ring 14 72 204 34 9 $c(accent) 1.5
	} else {
		ui::ring 14 72 204 34 9 $c(border) 1
	}
	icon search 14 [expr {$focus ? $c(accent) : $c(muted)}] 25 82 2
	ui::hit 14 72 204 34 ::mailapp::search_focus
	if {$state(query) eq "" && !$state(searchfocus)} {
		ui::text 47 81 Search i13 $c(muted)
		return
	}
	set x 47
	set q $state(query)
	set from ""
	if {[regexp {^\s*from:\s*("[^"]*"|\S+)\s+(.*)$} $q -> from rest]} {
		set from [string trim $from \"]
		set q $rest
		set w [expr {14 + [ui::measure i12m from] + 4 + [ui::measure i12m $from]}]
		ui::box $x 78 $w 22 -fill $c(pill) -radius 6
		set tw [ui::text [expr {$x + 7}] 81.5 from i12m $c(muted)]
		ui::text [expr {$x + 7 + $tw + 4}] 81.5 $from i12m $c(fg)
		set x [expr {$x + $w + 8}]
	}
	set q [elide i13 $q [expr {190 - $x}]]
	set tw [ui::text $x 81 $q i13 $c(fg)]
	if {$state(searchfocus)} { ui::box [expr {$x + $tw}] 81 2 16 -fill $c(accent) }
	if {$state(query) ne ""} {
		icon x 13 $c(muted) 196.8 82.5 2
		ui::hit 190 72 28 34 ::mailapp::search_clear
	}
}
