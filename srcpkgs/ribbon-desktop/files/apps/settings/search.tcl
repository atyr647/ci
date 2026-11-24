# search.tcl - search over the row labels of every page (C4). A query
# matches an item when its title or one of its row labels contains it, without
# regard to case. The rail shows only the matching items while a query is set.

namespace eval settings {
	variable query ""
	variable searching 0   ;# the search field has the keyboard
}

# The item ids the query leaves in the rail, in rail order.
proc settings::matching {q} {
	if {$q eq ""} { return [ids] }
	variable info
	set out {}
	foreach id [ids] {
		set hit [string match -nocase *$q* [dict get $info($id) title]]
		foreach r [dict get $info($id) rows] { if {[string match -nocase *$q* $r]} { set hit 1 } }
		if {$hit} { lappend out $id }
	}
	set out
}

proc settings::search_key {sym char state} {
	variable query
	variable searching
	switch -- $sym {
		BackSpace { set query [string range $query 0 end-1] }
		Escape { set query ""; set searching 0 }
		Return - KP_Enter { set searching 0 }
		default {
			if {[string length $char] == 1 && [scan $char %c code] == 1 && $code >= 32 && $code != 127} {
				append query $char
			} else {
				return 0
			}
		}
	}
	page::draw
	return 1
}

# Keys go to the search field while it has them, else to the page.
proc settings::key {sym char state} {
	variable searching
	variable query
	variable sel
	# Escape closes the Rewind sheet first (Updates' sheet is modal over the page)
	if {$sym eq "Escape" && $sel eq "updates" && $::kupd::sheet} { kupd::sheet_close; return }
	# an open dropdown list takes every key (it jumps to what is typed); Escape closes it, or a page's sheet
	if {$::sctl::pop ne ""} { sctl::pop_key $sym $char; return }
	if {$sym eq "Escape" && [sctl::escape]} return
	if {$searching && ![expr {$state & 4}]} {
		if {[search_key $sym $char $state]} return
	}
	if {$sym eq "Escape" && $query ne ""} { set_query ""; return }
	page::key $sym $char $state
}

proc settings::set_query {q} {
	variable query
	variable searching
	set query $q
	set searching [expr {$q ne ""}]
	page::draw
}

# A click on the field: the keyboard goes to the search.
proc settings::focus_search {} {
	variable searching
	set searching 1
	page::draw
}
