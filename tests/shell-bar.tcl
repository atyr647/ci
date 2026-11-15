# shell-bar.tcl - RIBBON_SHELL_TEST hook for the bar's workspace switcher and
# updates chip (tests/run.sh, on Xvfb): the parts and which one is current,
# clicks and scroll, a live workspace change, the chip shown or hidden, the
# right bar's 480 px least width, reading kit's cache file, the power button
# and its session panel, and the window controls (only while maximized).
# Every check is synchronous; a 30 s limit ends the run if anything waits.

set failed 0
interp bgerror {} {apply {{msg opts} { puts "  FAIL background error: [dict get $opts -errorinfo]"; exit 1 }}}
after 30000 {puts "  FAIL the bar checks took more than 30 s"; exit 1}
proc ok {what} { puts "  ok   $what" }
proc bad {what why} { global failed; incr failed; puts "  FAIL $what: $why" }
proc check {what cond why} { if {$cond} { ok $what } else { bad $what $why } }

# the same three workspaces as the scene: the second one is the one you are on
array set wm::ws {1 {name 1 active 0} 2 {name 2 active 1} 3 {name 3 active 0}}
set wm::wsorder {1 2 3}
set status::updates 3
set status::date "Sun 31 May"
set status::time 00:27

# clicks and scroll call wm::send; record what would reach labwc
set ::sent {}
proc wm::send {cmd args} { lappend ::sent [join [concat $cmd $args]] }

# the parts drawn last time: {id x active}, the chip's place {kind x width}
proc parts {} { set bar::wsparts }
proc kinds {} { lmap p $bar::placed { lindex $p 0 } }
proc redraw {} { bar::draw; update }
# the centre of part N (1-based) in the drawn order
proc partx {n} { lindex [parts] [expr {$n - 1}] 1 }
# the ids of the parts you are on
proc current {} { set out {}; foreach p [parts] { if {[lindex $p 2]} { lappend out [lindex $p 0] } }; return $out }

after 300 {
	redraw
	# the switcher: one part per workspace, the second one current
	check "the switcher has one part per workspace" [expr {[llength [parts]] == 3}] "[llength [parts]] parts"
	check "the parts are the workspaces, in order" [expr {[lmap p [parts] {lindex $p 0}] eq {1 2 3}}] "[parts]"
	check "only the second part is current" [expr {[current] eq {2}}] "current [current]"

	# the chip: shown with updates waiting, between the tray and the clock
	check "the updates chip is shown with updates waiting" [expr {"updates" in [kinds]}] "kinds [kinds]"
	# the right bar: 480 px at least, its last item (the window controls) 4 px from its right edge
	set rx $bar::rightx; set rw $bar::rightw
	check "the right bar is 480 px at least" [expr {$rw >= 480}] "$rw px"
	lassign [lindex $bar::placed end] kind wx ww
	check "the right bar's items end 4 px from its right edge" [expr {$wx + $ww == $rx + $rw - 4}] "ends at [expr {$wx + $ww}], bar ends at [expr {$rx + $rw - 4}]"

	# the chip opens the updates panel; nothing of Xfce is left behind it
	check "the chip's click opens the updates panel, not a terminal" [expr {[string first xfce [info body status::updates_click]] < 0 && [string first upd::toggle [info body status::updates_click]] >= 0}] [info body status::updates_click]

	# nothing waiting: no chip, and the bar keeps its 480 px with the items at the right
	set status::updates 0
	redraw
	check "the updates chip is hidden when nothing is waiting" [expr {"updates" ni [kinds]}] "kinds [kinds]"
	check "without the chip the bar is still 480 px" [expr {$bar::rightw == 480}] "$bar::rightw px"
	lassign [lindex $bar::placed end] kind wx ww
	check "without the chip the items still end 4 px from the right" [expr {$wx + $ww == $bar::rightx + $bar::rightw - 4}] "ends at [expr {$wx + $ww}]"
	set status::updates 3
	redraw

	# one and five workspaces: one part each, no more
	array set wm::ws {1 {name 1 active 1}}; set wm::wsorder {1}
	redraw
	check "one workspace gives one part" [expr {[llength [parts]] == 1 && [lindex [parts] 0 2] == 1}] "[parts]"
	for {set i 1} {$i <= 5} {incr i} { set wm::ws($i) [list name $i active [expr {$i == 1}]] }
	set wm::wsorder {1 2 3 4 5}
	redraw
	check "five workspaces give five parts" [expr {[llength [parts]] == 5}] "[llength [parts]] parts"
	array unset wm::ws
	array set wm::ws {1 {name 1 active 0} 2 {name 2 active 1} 3 {name 3 active 0}}
	set wm::wsorder {1 2 3}
	redraw

	# clicks: a part switches to its workspace
	set sent {}; set ::sent {}
	bar::click [expr {[partx 1] + 12}] 27 1
	check "clicking the first part switches to workspace 1" [expr {$::sent eq {{ws 1}}}] "sent {$::sent}"
	set ::sent {}
	bar::click [expr {[partx 3] + 12}] 27 1
	check "clicking the third part switches to workspace 3" [expr {$::sent eq {{ws 3}}}] "sent {$::sent}"

	# scroll on a part steps (from the one you are on): up is previous, down is next
	set ::sent {}
	bar::click [expr {[partx 2] + 12}] 27 4
	check "scrolling up on the switcher goes to the previous workspace" [expr {$::sent eq {{ws 1}}}] "sent {$::sent}"
	set ::sent {}
	bar::click [expr {[partx 2] + 12}] 27 5
	check "scrolling down on the switcher goes to the next workspace" [expr {$::sent eq {{ws 3}}}] "sent {$::sent}"
	# scroll on the track between the parts steps too
	set ::sent {}
	bar::click [expr {[partx 1] - 2}] 15 5
	check "scrolling on the track steps through the workspaces" [expr {$::sent eq {{ws 3}}}] "sent {$::sent}"
	# a click on the track itself does nothing
	set ::sent {}
	bar::click [expr {[partx 1] - 2}] 15 1
	check "a click on the track between parts sends nothing" [expr {$::sent eq {}}] "sent {$::sent}"

	# hover: the part under the pointer
	bar::motion [expr {[partx 3] + 12}] 27
	check "the part under the pointer is the hovered one" [expr {$bar::wshover eq "3"}] "hover '$bar::wshover'"
	bar::motion -1 -1
	check "leaving the bar clears the hover" [expr {$bar::wshover eq ""}] "hover '$bar::wshover'"

	# live: a workspace change from labwc moves the current part
	set wm::ws(1) {name 1 active 1}; set wm::ws(2) {name 2 active 0}
	wm::changed
	update
	check "a workspace change from labwc moves the current part" [expr {[current] eq {1}}] "current [current]"

	# kit's cache file: ~/.cache/kit/updates, a Tcl dict (kit-updater writes it)
	set tmp [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] ribbon-bar-test-[pid]]
	set ::env(XDG_CACHE_HOME) $tmp
	file mkdir [file join $tmp kit]
	set f [file join $tmp kit updates]
	proc wr {path text} { set fh [open $path w]; puts -nonewline $fh $text; close $fh }
	set body {updates {{name firefox short firefox version 134.0.1 new 134.0.2 flags {} download 1} {name ffmpeg short ffmpeg version 7.1 new 7.1.1 flags {} download 1}}}
	wr $f "checked 1794000000 notify 1 $body"; status::updates_read
	check "the chip reads the count from kit's cache file" [expr {$status::updates == 2}] "count $status::updates"
	wr $f "checked 1794000000 notify 0 $body"; status::updates_read
	check "kit's notify = no hides the chip" [expr {$status::updates == 0}] "count $status::updates"
	wr $f {checked 1794000000 notify 1 updates {}}; status::updates_read
	check "nothing waiting in kit's file: no chip" [expr {$status::updates == 0}] "count $status::updates"
	file mkdir [file join $tmp ribbon]
	set sysf [file join $tmp ribbon system-updates]
	wr $sysf {checked 1794000000 updates {{name linux6.18 short linux6.18 version 6.18.62_1 new 6.18.63_1 flags restart download 0}}}
	wr $f "checked 1794000000 notify 1 $body"; status::updates_read
	check "the chip counts the system's waiting packages too (ribbon update --tcl's file)" [expr {$status::updates == 3}] "count $status::updates"
	wr $f {checked 1794000000 notify 1 updates {}}; status::updates_read
	check "only system packages waiting: the chip shows" [expr {$status::updates == 1}] "count $status::updates"
	file delete $sysf
	wr $f "not a dict \{"; status::updates_read
	check "a damaged cache file: no chip, no error" [expr {$status::updates == 0}] "count $status::updates"
	file delete -force $tmp
	set status::updates 9
	status::updates_read
	check "no cache file yet: no chip" [expr {$status::updates == 0}] "count $status::updates"

	# ---- the window controls: only while the focused window is maximized (the solid strip's state)
	set ::ran {}
	proc apps::run {cmd} { lappend ::ran $cmd }
	proc window_focus {state} {
		array unset wm::tl; array set wm::tl [list 1 [list app foot title Terminal state $state]]
		set wm::order {1}
		set wm::focus ""   ;# wm::changed keeps the last focus unless a window is active
		wm::changed; redraw
	}
	# the bar's items as {kind x width}: the power button's place
	proc power_item {} { set i [lsearch -exact -index 0 $bar::placed power]; if {$i < 0} { return {} }; lindex $bar::placed $i }

	window_focus {}
	check "with no window focused there are no window controls" [expr {"wctl" ni [kinds]}] "kinds [kinds]"
	check "with no window focused the power button is the last item" [expr {[lindex [kinds] end] eq "power"}] "kinds [kinds]"
	window_focus act
	check "a floating focused window shows no window controls" [expr {"wctl" ni [kinds] && ![wm::solid]}] "kinds [kinds]"
	check "a floating focused window leaves the power button last" [expr {[lindex [kinds] end] eq "power"}] "kinds [kinds]"
	window_focus act,max
	check "a maximized window shows the controls after the power button" [expr {[lrange [kinds] end-2 end] eq {power divider wctl}}] "kinds [kinds]"
	check "a maximized window is the solid strip's state" [expr {[wm::solid]}] "wm::solid is 0"
	window_focus act
	check "un-maximizing hides the controls again" [expr {"wctl" ni [kinds] && [lindex [kinds] end] eq "power"}] "kinds [kinds]"
	check "un-maximized, the right bar is still 480 px at least" [expr {$bar::rightw >= 480}] "$bar::rightw px"
	window_focus {}

	# ---- the power button: 30 x 30, after the switcher; hover; a click opens the session panel
	set pwi [power_item]
	check "the power button is 30 px wide" [expr {[lindex $pwi 2] == 30}] "[lindex $pwi 2] px"
	set wsi [lsearch -exact -index 0 $bar::placed ws]
	check "the power button comes right after the switcher, 4 px apart" [expr {[lindex $pwi 1] == [lindex $bar::placed $wsi 1] + [lindex $bar::placed $wsi 2] + 4}] "power at [lindex $pwi 1]"
	set px [expr {[lindex $pwi 1] + 15}]
	bar::motion $px 27
	check "the power button is hovered under the pointer" [expr {$bar::pwhover == 1}] "pwhover $bar::pwhover"
	bar::motion -1 -1
	check "leaving the power button clears its hover" [expr {$bar::pwhover == 0}] "pwhover $bar::pwhover"
	bar::click $px 27 1
	check "a click on the power button opens the session panel" [expr {$panel::open eq "session"}] "open '$panel::open'"
	set rows {}
	foreach b [panel::blocks session] { if {[lindex $b 0] eq "srow"} { lappend rows [lindex $b 3] } }
	check "the session panel has five rows: Lock, Sleep, Log out, Restart, Shut down" [expr {$rows eq {Lock Sleep {Log out} Restart {Shut down}}}] "rows {$rows}"
	check "the first row is focused when the panel opens" [expr {$panel::sel == 0}] "sel $panel::sel"

	# keys: Down and Up move the focus, the focus stops at the ends
	launcher::key Down {} 0
	check "Down moves the focus to the second row" [expr {$panel::sel == 1}] "sel $panel::sel"
	launcher::key Down {} 0; launcher::key Down {} 0; launcher::key Down {} 0; launcher::key Down {} 0
	check "Down stops at the last row" [expr {$panel::sel == 4}] "sel $panel::sel"
	launcher::key Up {} 0
	check "Up moves the focus back" [expr {$panel::sel == 3}] "sel $panel::sel"
	# the pointer over a row focuses it (row k spans 8 + 42k .. 48 + 42k)
	panel::session_hover [expr {8 + 42 * 1 + 20}]
	check "the pointer over a row focuses it" [expr {$panel::sel == 1}] "sel $panel::sel"
	panel::session_hover [expr {8 + 42 * 1 + 41}]
	check "the gap between rows focuses nothing" [expr {$panel::sel == 1}] "sel $panel::sel"

	# Enter on each row runs its command (stubbed) and the panel closes
	set cmds {ribbon-lock {loginctl suspend} {labwc --exit} {loginctl reboot} {loginctl poweroff}}
	for {set k 0} {$k < 5} {incr k} {
		panel::show session
		for {set j 0} {$j < $k} {incr j} { launcher::key Down {} 0 }
		set ::ran {}
		launcher::key Return {} 0
		check "Enter on row [expr {$k + 1}] runs its command" [expr {$::ran eq [list [lindex $cmds $k]]}] "ran {$::ran}"
		check "the panel closes when row [expr {$k + 1}] runs" [expr {$panel::open eq ""}] "open '$panel::open'"
	}

	# Escape closes
	panel::show session
	launcher::key Escape {} 0
	check "Escape closes the session panel" [expr {$panel::open eq "" && $launcher::keytarget eq ""}] "open '$panel::open'"

	# the power key: the verb opens the session panel when POWER_KEY_ASK=yes and does nothing otherwise
	proc bar::power_conf {key def} { if {$key eq "POWER_KEY_ASK"} { return $::askpower }; return $def }
	set verb [dict get $shell::verbs power-menu]
	set ::askpower no
	eval $verb
	check "the power key does nothing with POWER_KEY_ASK=no" [expr {$panel::open eq ""}] "open '$panel::open'"
	set ::askpower yes
	eval $verb
	check "the power key opens the session panel with POWER_KEY_ASK=yes" [expr {$panel::open eq "session"}] "open '$panel::open'"
	panel::close

	# the dock is the only task list: two windows of one app are one dock item, counted
	array unset wm::tl
	array set wm::tl {1 {app foot title Terminal state {}} 2 {app foot title Terminal state {}} 3 {app firefox title Web state {}}}
	set wm::order {1 2 3}
	wm::changed; update
	set groups [dock::groups]
	check "two windows of one app are one dock item with a count of 2" [expr {[llength $groups] == 2 && [lindex $groups 0 0] eq "foot" && [lindex $groups 0 1] eq {1 2}}] "groups {$groups}"
	check "the other app keeps its own dock item" [expr {[lindex $groups 1 0] eq "firefox" && [lindex $groups 1 1] eq {3}}] "groups {$groups}"

	puts [expr {$failed ? "  $failed bar check(s) failed" : "  all bar checks passed"}]
	exit [expr {$failed ? 1 : 0}]
}
