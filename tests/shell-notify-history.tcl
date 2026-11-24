# shell-notify-history.tcl - the notification history, Do Not Disturb and the left bar's bell in the real
# shell (RIBBON_SHELL_TEST=this file, under xvfb; tests/steps.d/42-notify-history.sh).
#   NOTIFY_HISTORY_SCENE = list | dnd | clear | empty | checks
#     list   Notify-Final-5: the history open, Now and Earlier today, the bell with its count
#     dnd    Notify-Final-6: Do Not Disturb on, the until menu open, one held entry with the accent rule
#     clear  Notify-Final-7: the pointer over an entry: its wash and the × clear control
#     empty  Notify-Final-8: Do Not Disturb on and nothing listed, the history closed: the slashed bell only
#     checks the behaviour: the bell, order, keys, clicks, Do Not Disturb holds and expiry, saving, Clear
#   NOTIFY_SHOT=FILE captures the screen (import) once the scene is drawn.
# The D-Bus server does not run here: the close and action calls are recorded instead.

set scene [expr {[info exists ::env(NOTIFY_HISTORY_SCENE)] ? $::env(NOTIFY_HISTORY_SCENE) : "checks"}]
set failed 0
interp bgerror {} {apply {{msg opts} { puts "  FAIL background error: [dict get $opts -errorinfo]"; exit 1 }}}
after 40000 {puts "  FAIL the history checks took more than 40 s"; exit 1}
proc ok {what} { puts "  ok   $what" }
proc bad {what why} { global failed; incr failed; puts "  FAIL $what: $why" }
proc check {what cond why} { if {$cond} { ok $what } else { bad $what $why } }

# no server on the test's bus: the calls the history makes are recorded
proc notify::start {} {}
set ::closed {}
set ::invoked {}
proc notifyd::closed {id reason} { lappend ::closed [list $id $reason] }
proc notifyd::invoked {id key} { lappend ::invoked [list $id $key] }

proc mk {id app summary body urg actions {hints {}}} {
	dict create id $id app $app icon "" summary $summary body $body actions $actions \
		hints $hints urgency $urg timeout 0 sender :1.1 replaces 0
}

# The entries as the history shows them (newest first). Times are set after arrival: arrival stamps now.
proc seed {} {
	set now [clock seconds]
	set old [expr {max([nhist::midnight] + 600, $now - 3700)}]
	set specs [list \
		[list 1 Steam Ludo "you up for a round tonight? bringing the new deck" 1 {default Reply mark {Mark as read}} [expr {$now - 240}]] \
		[list 2 Firefox "Download complete" "ribbon-0.3.iso · 1.4 GB" 1 {default Open S {Show in Files}} [expr {$now - 540}]] \
		[list 3 Screenshot "Screenshot taken" "Pictures/Screenshots/20-51-14.png" 1 {default Open edit Edit} [expr {$now - 1260}]] \
		[list 4 Calendar "Game night at 21:30" "Discord · Ludo, Mara and 3 others" 1 {} $old] \
		[list 5 Files "Backup finished" "41 GB to Backup in 6 min" 1 {default {Show in Files}} [expr {$old - 600}]]]
	# just after midnight today is shorter than the board's times: they are kept in order inside it
	set span [expr {$now - [nhist::midnight]}]
	# the store is oldest first, so the newest arrives last
	foreach s [lreverse $specs] {
		lassign $s id app summary body urg acts t
		if {$span < 1900} { set t [expr {[nhist::midnight] + (6 - $id) * max(1, $span / 6)}] }
		notify::arrive [mk $id $app $summary $body $urg $acts]
		notify::set_field $id time $t
	}
	nhist::sync
}

# where the bell is drawn, from the bar's hits
proc bell_hit {} {
	foreach h $bar::hits {
		if {[lindex $h 4] eq "nhist::bell"} { return $h }
	}
	return ""
}

proc shot {} {
	if {[info exists ::env(NOTIFY_SHOT)] && $::env(NOTIFY_SHOT) ne ""} {
		update
		catch {exec import -window root $::env(NOTIFY_SHOT)}
	}
}

proc texts {} {
	set out {}
	foreach i [$::nhist::cv find all] { if {[$::nhist::cv type $i] eq "text"} { lappend out [$::nhist::cv itemcget $i -text] } }
	return $out
}

proc run_scene {} {
	global scene
	switch -- $scene {
		list {
			seed
			notify::seen
			foreach id $notify::shown { notify::drop $id }
			nhist::show
		}
		dnd {
			seed
			notify::seen
			foreach id $notify::shown { notify::drop $id }
			nhist::dnd_set "for 3h"
			nhist::dnd_set "until 08:00"
			notify::arrive [mk 6 Updates "2 updates waiting" "mesa 25.2.9 and tk 8.6" 1 {default Update later Later}]
			foreach id $notify::shown { notify::drop $id }
			nhist::show
			nhist::menu_toggle
		}
		clear {
			seed
			notify::seen
			foreach id $notify::shown { notify::drop $id }
			nhist::show
			# the pointer over the second entry: its wash and the × clear control
			set top $nhist::top
			foreach r $nhist::rows {
				lassign $r rid ctop cbot
				if {$rid == 2} { nhist::motion 200 [expr {$top + $ctop - $nhist::scroll + 8}] }
			}
		}
		empty {
			nhist::dnd_set "until 08:00"
		}
	}
	# the boards show the history alone: the seeded popups are taken down before the capture
	foreach id $notify::shown { notify::drop $id }
	after 250 finish_scene
}

proc finish_scene {} {
	global scene failed
	switch -- $scene {
		list {
			check "the list shows five entries, newest first" [expr {[nhist::ids] eq {1 2 3 4 5}}] "[nhist::ids]"
			check "the bell counts the five" [expr {[lindex [nhist::bell_info] 0] == 5}] "[nhist::bell_info]"
		}
		dnd {
			check "Do Not Disturb is on" $nhist::dnd "off"
			check "the held entry keeps the accent rule while the list is open" [expr {$nhist::marks eq {6}}] "marks $nhist::marks"
		}
		clear {
			check "the second entry is under the pointer" [expr {$nhist::hover == 2}] "hover is $nhist::hover"
		}
		empty {
			check "Do Not Disturb is on with nothing listed" [expr {$nhist::dnd && [llength [nhist::ids]] == 0}] "dnd $nhist::dnd"
		}
	}
	shot
	# NOTIFY_HOLD=ms keeps the scene up that long (a capture under a compositor)
	if {[info exists ::env(NOTIFY_HOLD)]} { after $::env(NOTIFY_HOLD) [list exit [expr {$failed ? 1 : 0}]]; return }
	exit [expr {$failed ? 1 : 0}]
}

proc checks {} {
	global failed
	seed
	# the bell: count and place (the bar's right edge is 428, the button 46 wide with one digit)
	bar::draw
	set h [bell_hit]
	check "the bell has a hit on the left bar" [expr {$h ne ""}] "no hit"
	if {$h ne ""} {
		check "the bell's right edge is 428" [expr {[lindex $h 2] == 428}] "x1 [lindex $h 2]"
		check "the bell is 46 wide with one digit (47 at most: the digit rounds up)" [expr {abs([lindex $h 2] - [lindex $h 0] - 46) <= 1}] "[expr {[lindex $h 2] - [lindex $h 0]}]"
	}
	check "the bell counts five" [expr {[lindex [nhist::bell_info] 0] == 5}] "[nhist::bell_info]"
	check "the list is newest first" [expr {[nhist::ids] eq {1 2 3 4 5}}] "[nhist::ids]"
	# just after midnight nothing from today can be more than an hour old, so there is only NOW: the oldest seeded
	# entry (seed: midnight + 600 at the earliest) is "earlier" only once it is over an hour old
	if {[clock seconds] - ([nhist::midnight] + 600) > 3600 + 30} {
		check "the groups are Now and Earlier today" [expr {[lmap g [nhist::groups] {lindex $g 0}] eq {NOW {EARLIER TODAY}}}] "[lmap g [nhist::groups] {lindex $g 0}]"
	} elseif {[clock seconds] - ([nhist::midnight] + 600) < 3600 - 30} {
		check "just after midnight the one group is Now" [expr {[lmap g [nhist::groups] {lindex $g 0}] eq {NOW}}] "[lmap g [nhist::groups] {lindex $g 0}]"
	}
	# the bell toggles the list; opening it marks what was unseen and sees it all
	nhist::bell 1
	check "the bell opens the list" $nhist::open "closed"
	check "the list opens with the newest selected" [expr {$nhist::sel == 1}] "sel $nhist::sel"
	check "the five unseen entries keep their rule while it is open" [expr {[llength $nhist::marks] == 5}] "marks $nhist::marks"
	check "opening sees every entry" [expr {[notify::unseen] == 0}] "[notify::unseen] unseen"
	check "the keys go to the list" [expr {$launcher::keytarget eq "nhist::key"}] "keytarget $launcher::keytarget"
	nhist::key Down {} 0
	check "Down selects the next entry" [expr {$nhist::sel == 2}] "sel $nhist::sel"
	nhist::key Up {} 0
	check "Up selects the one above" [expr {$nhist::sel == 1}] "sel $nhist::sel"
	# an entry's own key acts on it: the action goes to the app, the entry closes but stays listed
	nhist::select 2
	set ::closed {}; set ::invoked {}
	nhist::key s S 0
	check "a letter key invokes that action" [expr {[lindex $::invoked 0] eq {2 S}}] "invoked $::invoked"
	check "acting closes it with reason 2" [expr {[lsearch -exact $::closed {2 2}] >= 0}] "closed $::closed"
	check "the entry stays in the list after it closes" [expr {[llength [nhist::ids]] == 5}] "[nhist::ids]"
	# Return is the default action
	nhist::select 3
	set ::invoked {}
	nhist::key Return {} 0
	check "Return invokes the default action" [expr {[lindex $::invoked 0] eq {3 default}}] "invoked $::invoked"
	# Delete clears: closed with reason 2, and off the list
	nhist::select 5
	set ::closed {}
	nhist::key Delete {} 0
	check "Delete takes the entry off the list" [expr {[nhist::ids] eq {1 2 3 4}}] "[nhist::ids]"
	check "Delete sends NotificationClosed reason 2" [expr {[lsearch -exact $::closed {5 2}] >= 0}] "closed $::closed"
	check "the bell counts four" [expr {[lindex [nhist::bell_info] 0] == 4}] "[nhist::bell_info]"
	nhist::key Escape {} 0
	check "Escape closes the list" [expr {!$nhist::open}] "still open"
	check "closing gives the keys back" [expr {$launcher::keytarget eq ""}] "keytarget $launcher::keytarget"
	check "the closed list leaves no surface on screen" [expr {![winfo ismapped .nhist]}] "mapped"

	# Do Not Disturb: a normal arrival is held (no popup, unseen), a critical one shows
	nhist::dnd_set "for 1h"
	check "Do Not Disturb is on for an hour" [expr {$nhist::dnd && $nhist::dnd_end - [clock seconds] > 3500 && $nhist::dnd_end - [clock seconds] <= 3600}] "dnd $nhist::dnd end $nhist::dnd_end"
	check "the hold filter is set" [expr {$notify::hold_filter eq "nhist::hold"}] "filter $notify::hold_filter"
	check "the bell is slashed under Do Not Disturb (its path differs)" [expr {[nhist::bell_icon #000000 1] ne [nhist::bell_icon #000000 0]}] "same icon"
	notify::arrive [mk 7 Mail "Quiet mail" "held" 1 {}]
	check "a held arrival has no popup" [expr {[lsearch -exact $notify::shown 7] < 0}] "shown $notify::shown"
	check "a held arrival is in the list, unseen" [expr {[nhist::ids] eq {7 1 2 3 4}}] "[nhist::ids]"
	notify::arrive [mk 8 Power "Battery at 4%" "" 2 {}]
	check "a critical one still shows" [expr {[lsearch -exact $notify::shown 8] >= 0}] "shown $notify::shown"
	# the expiry turns it off and the hold goes
	nhist::dnd_off
	check "expiry turns Do Not Disturb off" [expr {!$nhist::dnd && $notify::hold_filter eq ""}] "dnd $nhist::dnd"
	notify::arrive [mk 9 Files "Ordinary" "" 1 {}]
	check "after expiry an arrival shows" [expr {[lsearch -exact $notify::shown 9] >= 0}] "shown $notify::shown"

	# saved and read back: the entries, and Do Not Disturb with its end
	nhist::dnd_set "for 3h"
	after cancel $nhist::saving
	nhist::save
	set before [nhist::ids]
	set notify::store {}
	nhist::load
	check "the saved entries come back, in order" [expr {[nhist::ids] eq $before}] "got [nhist::ids], saved $before"
	check "the saved Do Not Disturb comes back with its mode" [expr {$nhist::dnd && $nhist::dnd_mode eq "for 3h"}] "dnd $nhist::dnd mode $nhist::dnd_mode"
	check "a loaded entry is closed and seen" [expr {[dict get [notify::find 2] open] == 0 && [dict get [notify::find 2] seen] == 1}] "entry 2 state"
	# a damaged file is dropped, and the shell starts empty
	set path [nhist::path]
	set fh [open $path w]; puts $fh "this is \{not a list"; close $fh
	set notify::store {}
	nhist::load
	check "a damaged file is dropped" [expr {![file exists $path] && [llength $notify::store] == 0}] "file still there"
	nhist::dnd_off

	# Clear all leaves the empty list: no count on the bell, and the list says so
	seed
	nhist::show
	nhist::clear_all
	check "Clear all empties the list" [expr {[nhist::ids] eq {}}] "[nhist::ids]"
	check "the bell has no count when it is empty" [expr {[lindex [nhist::bell_info] 0] == 0}] "count"
	bar::draw
	set h [bell_hit]
	check "the empty bell is 30 wide" [expr {$h ne "" && [lindex $h 2] - [lindex $h 0] == 30}] "[expr {$h eq "" ? "no hit" : [lindex $h 2] - [lindex $h 0]}]"
	# text::draw splits a line into items: the items, joined in the order drawn, read the line
check "an empty list says so" [expr {[string first "No notifications" [join [texts] ""]] >= 0}] "texts [texts]"
	# the bell again closes it
	nhist::bell 1
	check "the bell closes an open list" [expr {!$nhist::open}] "still open"
	check "the bell reopens it" [expr {[nhist::bell 1; set nhist::open]}] "closed"
	nhist::close

	# the bar's click on an empty part of the bar closes the list too
	nhist::show
	bar::click 700 20 1
	check "a click on the bar's empty part closes the list" [expr {!$nhist::open}] "still open"
	puts [expr {$failed ? "  history checks FAILED" : "  all history checks passed"}]
	exit [expr {$failed ? 1 : 0}]
}

if {$scene eq "checks"} {
	after 300 checks
} else {
	after 300 run_scene
}
