# ui-list.tcl - the list (U41): the view's name and unread count, Filter (only unread) and Mark all read; the
# conversations as dense text rows grouped by day (Today, Yesterday, This week, Earlier: Mail-A-Ledger,
# Mail-A9-Earlier); a row shows the unread dot, the sender (a mailing list's name for list mail), the number of
# messages, the flag, the time, the subject, the account, the snippet, the attachment and the labels. In a search
# (Mail-A4-Search) the head is Results with the scope, and the rows are the matches with the words highlighted,
# then the matching attachments. With nothing in the inboxes the list and the pane give way to All caught up
# (Mail-A5-Caught-up).

namespace eval ::mailapp {
	variable satts {}
	variable list_end 0
}

proc ::mailapp::view_name {v} {
	switch -- [lindex $v 0] {
		inboxes { return "All inboxes" }
		flagged { return Flagged }
		drafts { return Drafts }
		sent { return Sent }
		trash { return Trash }
		archive { return Archive }
		junk { return Junk }
		label { return "#[lindex $v 1]" }
		account { return [lindex $v 1] }
		folder { return [lindex $v 2] }
	}
	return $v
}

proc ::mailapp::list_max {} {
	variable list_end
	variable H
	expr {max(0, $list_end - $H + 12)}
}

proc ::mailapp::caught_up {} {
	variable state
	variable convs
	expr {$state(query) eq "" && $state(view) eq "inboxes" && ![llength $convs] && !$state(unreadonly)}
}

# The row's attachment text: one name; several photos as "N photos".
proc ::mailapp::att_text {atts} {
	set atts [lmap a $atts {expr {[dict get $a inline] && ![string match image/* [dict get $a type]] ? [continue] : $a}}]
	if {![llength $atts]} { return "" }
	set imgs [lmap a $atts {expr {[string match image/* [dict get $a type]] ? $a : [continue]}}]
	if {[llength $atts] > 1 && [llength $imgs] == [llength $atts]} { return "[llength $atts] photos" }
	foreach a $atts { if {![string match image/* [dict get $a type]]} { return [dict get $a name] } }
	return [dict get [lindex $atts 0] name]
}

# Text with highlighted SPANS ({start end} ...) at X TOP in F; cut at WIDTH. Returns the width drawn.
proc ::mailapp::htext {x top str f colour spans width} {
	variable c
	set s [elide $f $str $width]
	if {[llength $spans]} {
		set xs [ui::layout $f $s]
		set n [string length $s]
		foreach sp $spans {
			lassign $sp a b
			if {$a >= $n} continue
			set b [expr {min($b, $n)}]
			set x0 [lindex $xs $a]
			set x1 [expr {$b >= $n ? [lindex $xs end] : [lindex $xs $b]}]
			set lh [ui::lhn $f]
			ui::box [expr {$x + $x0 - 1}] [expr {$top - 1}] [expr {$x1 - $x0 + 2}] [expr {$lh + 2}] -fill $c(hit) -radius 3
		}
	}
	return [ui::text $x $top $s $f $colour]
}

# One row at Y (top); returns its height. R: sender count when subject account snippet atts labels unread flagged
# key, and the spans of a search.
proc ::mailapp::mrow {y r on} {
	variable c
	set unread [dict get $r unread]
	set fg $c(fg)
	set mu $c(muted)
	set h [expr {[dict get $r meta] ? 99 : 77}]
	if {$on} { ui::box 242 $y 352 $h -fill $c(field) -radius 10 }
	if {$unread} { ui::box 250 [expr {$y + 16}] 7 7 -fill $fg -radius 3.5 }
	set w [ui::text 264 [expr {$y + 11}] [elide i13s [dict get $r sender] 200] [expr {$unread ? "i13s" : "i13m"}] $fg]
	set right 582
	set tw [ui::text $right [expr {$y + 11.5}] [dict get $r when] [expr {$unread ? "i12s" : "i12"}] [expr {$unread ? $fg : $mu}] e 0 {} 1]
	if {[dict get $r flagged]} { icon flag 12 $fg [expr {$right - $tw - 18}] [expr {$y + 13}] 2.2 }
	if {[dict get $r count] > 1} {
		set n [dict get $r count]
		set cw [expr {14 + [ui::measure i11s $n 0 1]}]
		ui::box [expr {264 + $w + 7}] [expr {$y + 10}] $cw 18 -fill $c(pill) -radius 6
		ui::text [expr {264 + $w + 14}] [expr {$y + 12}] $n i11s $mu w 0 {} 1
	}
	set aw [ui::text $right [expr {$y + 31.5}] [dict get $r account] i12 $mu e]
	htext 264 [expr {$y + 31}] [dict get $r subject] [expr {$unread ? "i13m" : "i13"}] [expr {$unread ? $fg : $mu}] \
		[dict get $r sspans] [expr {318 - $aw - 8}]
	htext 264 [expr {$y + 51}] [dict get $r snippet] i12 $mu [dict get $r nspans] 318
	if {[dict get $r meta]} {
		set x 264
		if {[dict get $r att] ne ""} {
			icon clip 12 $mu $x [expr {$y + 74.5}] 2
			set x [expr {$x + 17 + [htext [expr {$x + 17}] [expr {$y + 73}] [dict get $r att] i12 $mu [dict get $r aspans] 200] + 12}]
		}
		foreach l [dict get $r labels] { set x [expr {$x + [ui::text $x [expr {$y + 73}] "#$l" i12 $mu] + 12}] }
	}
	ui::hit 242 $y 352 $h [list ::mailapp::select [dict get $r key]]
	return $h
}

# The rows of the list, from the conversations (or the search's matches).
proc ::mailapp::rows {} {
	variable convs
	variable state
	set now [clock_now]
	set out {}
	foreach cv $convs {
		if {$state(query) ne ""} {
			set s [dict get $cv msg]
			set n [dict get $cv count]
			set sspans [dict get $cv subject_spans]
			set snip [dict get $cv snippet text]
			set nspans [dict get $cv snippet spans]
			set att ""
			set aspans {}
			foreach a [dict get $s atts] sp [dict get $cv att_spans] {
				if {[dict get $a inline] && ![string match image/* [dict get $a type]]} continue
				set att [dict get $a name]
				set aspans $sp
				break
			}
			set sender [mail::thread::name [dict get $s from]]
			set unread [dict get $s unread]
			set flagged [dict get $s flagged]
			set labels [dict get $s labels]
			set group ""
		} else {
			set s [dict get $cv shown]
			set n [dict get $cv count]
			set sspans {}
			set nspans {}
			set aspans {}
			set snip [dict get $s snippet]
			set att [att_text [dict get $s atts]]
			set first [lindex [dict get $cv msgs] 0]
			set sender [expr {[dict exists $first list] && [dict get $first list] ne "" ? [dict get $first list] : [dict get $cv sender]}]
			set unread [expr {[dict get $cv unread] > 0}]
			set flagged [dict get $cv flagged]
			set labels [dict get $cv labels]
			set group [mail::thread::day_group [dict get $s date] $now]
		}
		set subj [expr {$state(query) eq "" ? [dict get $cv subject] : [dict get $s subject]}]
		lappend out [dict create key [dict get $s key] sender $sender count $n when [mail::thread::when_list [dict get $s date] $now] \
			subject $subj account [dict get $s account] snippet $snip att $att labels $labels unread $unread flagged $flagged \
			sspans $sspans nspans $nspans aspans $aspans group $group meta [expr {$att ne "" || [llength $labels]}]]
	}
	return $out
}

proc ::mailapp::glabel {y t} {
	variable c
	ui::text 254 $y [string toupper $t] i11s $c(muted) w 1.32
}

proc ::mailapp::list_head {} {
	variable c
	variable state
	ui::box 603 0 1 $::mailapp::H -fill $c(border)
	if {$state(query) ne ""} {
		set w [ui::text 254 22 Results sg22 $c(fg) w -0.44]
		ui::text [expr {254 + $w + 10}] 31 [llength $::mailapp::convs] i13 $c(muted) w 0 {} 1
		set acct [scope_account]
		set opts [list all "All mail" inbox Inbox]
		if {$acct ne ""} { lappend opts [list account $acct] $acct }
		set cur $state(scope)
		# the scope as the board's 32 px segments: 12 px words in parts that fit them
		ui::box 405.6 20 186.4 32 -fill $c(field) -radius 9
		set x 408.6
		foreach {k l} $opts {
			set w [expr {22 + [ui::measure i12s $l]}]
			if {$k eq $cur} { ui::box $x 23 $w 26 -fill $c(pill) -radius 6 }
			ui::text [expr {$x + $w / 2.0}] 28.5 $l [expr {$k eq $cur ? "i12s" : "i12m"}] [expr {$k eq $cur ? $c(fg) : $c(muted)}] c
			ui::hit $x 23 $w 26 [list ::mailapp::set_scope $k]
			set x [expr {$x + $w}]
		}
		return
	}
	set w [ui::text 254 22 [view_name $state(view)] sg22 $c(fg) w -0.44]
	set u [dict get [mail::store::view_count $state(view)] unread]
	if {$u} { ui::text [expr {254 + $w + 10.9}] 31 "$u unread" i13 $c(muted) w 0 {} 1 }
	iconbtn sort 526 20 32 15 ::mailapp::toggle_unreadonly [expr {$state(unreadonly) ? $c(fg) : ""}] [expr {$state(unreadonly) ? $c(field) : ""}]
	iconbtn checks 560 20 32 15 ::mailapp::mark_all_read
}

# The account a search can be narrowed to: the open message's.
proc ::mailapp::scope_account {} {
	variable state
	if {[lindex $state(scope) 0] eq "account"} { return [lindex $state(scope) 1] }
	if {$state(conv) ne ""} { return [lindex $state(conv) 0] }
	return ""
}

proc ::mailapp::list_paint {} {
	variable c
	variable state
	variable lscroll
	variable list_end
	variable H
	set y [expr {70 - $lscroll}]
	set group "-"
	set first 1
	foreach r [rows] {
		if {$state(query) eq "" && [dict get $r group] ne $group} {
			set group [dict get $r group]
			if {!$first} { incr y 13 }
			if {$y > 52 && $y < $H} { glabel $y [dict get {today Today yesterday Yesterday week {This week} earlier Earlier} $group] }
			incr y 21
		} elseif {$first && $state(query) ne ""} {
			glabel $y Messages
			incr y 22
		}
		set first 0
		set h [expr {[dict get $r meta] ? 99 : 77}]
		if {$y + $h > 70 && $y < $H} { mrow $y $r [expr {[dict get $r key] in [conv_keys]}] }
		incr y [expr {$h + 1}]
	}
	if {$state(query) ne ""} {
		incr y 13
		if {[llength $::mailapp::satts]} {
			if {$y > 52} { glabel $y Attachments }
			incr y 32
			set now [clock_now]
			foreach a $::mailapp::satts {
				if {$y > 52 && $y + 52 < $H} {
					ui::box 264 [expr {$y + 2}] 28 28 -fill $c(pill) -radius 7
					icon [expr {[string match image/* [dict get $a type]] ? "image" : "pdf"}] 15 $c(fg) 270.5 [expr {$y + 8.5}] 1.8
					htext 304 $y [dict get $a name] i13m $c(fg) [dict get $a spans] 270
					set day [mail::thread::when_list [dict get $a date] $now]
					if {[mail::thread::day_group [dict get $a date] $now] eq "today"} { set day today }
					ui::text 304 [expr {$y + 17}] "[mail::thread::name [dict get $a from]] · $day · [mail::compose::size_text [dict get $a size]]" i12 $c(muted)
					ui::hit 242 [expr {$y - 10}] 352 52 [list ::mailapp::select [dict get $a key]]
				}
				incr y 53
			}
		}
	}
	set list_end [expr {$y + $lscroll}]
	# the head is drawn over rows scrolled under it
	clear_band 233 0 602 69
	ui::box 232 0 371 70 -fill $c(bar)
	list_head
}

proc ::mailapp::conv_keys {} {
	variable conv
	if {$conv eq ""} { return {} }
	lmap m [dict get $conv msgs] {dict get $m key}
}

# ---- All caught up --------------------------------------------------------------------------------------------
proc ::mailapp::caught_paint {} {
	variable c
	variable W
	variable H
	variable checked
	ui::text 256 22 [view_name inboxes] sg22 $c(fg) w -0.44
	iconbtn sort 1160 20 32 15 ::mailapp::toggle_unreadonly
	set cx [expr {232 + ($W - 232) / 2.0}]
	set cy [expr {70 + ($H - 70) / 2.0 - 40}]
	set top [expr {round($cy - 97)}]
	ui::box [expr {$cx - 32}] $top 64 64 -fill $c(pill) -radius 18 -ring [list $c(border) 1]
	icon checks 28 $c(fg) [expr {$cx - 14}] [expr {$top + 18}] 1.7
	ui::text $cx [expr {$top + 82}] "All caught up" sg22 $c(fg) c -0.44
	set n [llength [mail::store::accounts]]
	set t "$n account[expr {$n == 1 ? "" : "s"}]"
	if {$checked ne ""} { append t " · checked [clock format $checked -format %H:%M]" }
	ui::text $cx [expr {$top + 115}] $t i14 $c(muted) c 0 {} 1
	set bw1 [ui::button_w Archive field archive]
	set bw2 [ui::button_w "New message" primary edit]
	set x [expr {$cx - ($bw1 + 10 + $bw2) / 2.0}]
	ui::button archive $x [expr {$top + 157}] Archive field {::mailapp::show_view archive} archive
	ui::button new [expr {$x + $bw1 + 10}] [expr {$top + 157}] "New message" primary ::mailapp::compose_new edit
}
