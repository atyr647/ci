# ribbon-term-tabs (prototype, docs/TERMINAL.md §3): a Tk tab strip docked over foot windows.
#
# One `foot --server` serves every tab. A tab is a footclient window with the app-id
# ribbon-term-GROUP-N. The strip (this Tk window, on XWayland) sits on the window's top edge and
# switches tabs through ribbon-shell-watch (activate the chosen tab, then minimise the one it covers).
# labwc can't be asked where a Wayland window is, so the strip owns the group's geometry: it writes
# a window rule (where a new tab maps) and a keybind (move and resize every tab of the group) into a
# merged rc.xml, reloads labwc, and presses the keybind through a virtual keyboard. The same keybind
# moves the strip, so the strip and its tabs move in one frame.
#
# usage: wish tabs.tcl -name ribbon-term-strip-GROUP -- GROUP X Y W H
#   env RTT_WATCH  ribbon-shell-watch          RTT_RC    the generated rc.xml (merge-config)
#       RTT_KEY    command that presses the group's keybind (default: wtype the chord)
#       RTT_PALETTE palette.conf                RTT_LOG   timings and events, one per line
package require Tk 8.6-
lassign $argv G X Y W H
set STRIP 46
array set C {d2 #121110 bar #1D1C1B field #2A2826 pill #36302C border #3B3835 fg #EEE9E3 muted #A49D95 accent #FF7A59}
if {[info exists env(RTT_PALETTE)] && [file readable $env(RTT_PALETTE)]} {
	set f [open $env(RTT_PALETTE)]
	foreach l [split [read $f] \n] {
		if {[regexp {^(BAR|FIELD|PILL|BORDER|FG|MUTED|ACCENT|DESK_BOTTOM)=(#[0-9A-Fa-f]{6})} $l -> k v]} {
			set C([dict get {BAR bar FIELD field PILL pill BORDER border FG fg MUTED muted ACCENT accent DESK_BOTTOM d2} $k]) $v
		}
	}
	close $f
}
set LOG [expr {[info exists env(RTT_LOG)] ? [open $env(RTT_LOG) a] : "stdout"}]
fconfigure $LOG -buffering line
proc log {args} { puts $::LOG "[clock milliseconds] [join $args]" }
proc us {} { clock microseconds }

# ---------------------------------------------------------------- tabs: id -> {n title}, order, current
set order {}; set cur ""; set seq 0; set pending {}
array set tab {}

# ---------------------------------------------------------------- geometry: the generated rc.xml
proc rc_write {} {
	global G X Y W H STRIP env
	set fy [expr {$Y + $STRIP}]; set fh [expr {$H - $STRIP}]
	set q "ribbon-term-$G-*"; set qs "ribbon-term-strip-$G"
	set mv "<action name=\"MoveTo\" x=\"$X\" y=\"$fy\"/><action name=\"ResizeTo\" width=\"$W\" height=\"$fh\"/>"
	set ms "<action name=\"MoveTo\" x=\"$X\" y=\"$Y\"/>"
	set f [open $env(RTT_RC).tmp w]
	puts $f "<labwc_config><keyboard>"
	# place: every tab and the strip, in one action list (one frame)
	puts $f "<keybind key=\"C-A-S-W-F12\"><action name=\"ForEach\"><query identifier=\"$q\"/><then>$mv</then></action>"
	puts $f "  <action name=\"ForEach\"><query identifier=\"$qs\"/><then>$ms<action name=\"Raise\"/></then></action>"
	puts $f "  <action name=\"ForEach\"><query identifier=\"$q\"/><then><action name=\"Raise\"/></then></action></keybind>"
	# raise: the strip back over its window after something covered it
	puts $f "<keybind key=\"C-A-S-W-F11\"><action name=\"ForEach\"><query identifier=\"$qs\"/><then><action name=\"Raise\"/></then></action>"
	puts $f "  <action name=\"ForEach\"><query identifier=\"$q\"/><then><action name=\"Raise\"/></then></action></keybind>"
	puts $f "</keyboard><windowRules>"
	puts $f "<windowRule identifier=\"$q\" serverDecoration=\"no\">$mv</windowRule>"
	puts $f "<windowRule identifier=\"$qs\" serverDecoration=\"no\" skipTaskbar=\"yes\" skipWindowSwitcher=\"yes\"/>"
	puts $f "</windowRules></labwc_config>"
	close $f
	file rename -force $env(RTT_RC).tmp $env(RTT_RC)
}
proc reload {} { exec kill -HUP $::env(LABWC_PID) }
proc press {k} {
	if {[info exists ::env(RTT_KEY)]} { exec {*}$::env(RTT_KEY) $k } else { exec wtype -M ctrl -M alt -M shift -M logo -k $k -m logo -m shift -m alt -m ctrl }
}
# move every tab of the group to the strip's geometry
proc regroup {why} {
	set t0 [us]; rc_write; reload; set t1 [us]; press F12; set t2 [us]
	log move $why rc+hup [expr {($t1 - $t0) / 1000.0}] key [expr {($t2 - $t1) / 1000.0}]
}

# ---------------------------------------------------------------- the compositor (ribbon-shell-watch)
set watch [open |[list $env(RTT_WATCH) 2>@stderr] r+]
fconfigure $watch -buffering line -blocking 0
fileevent $watch readable on_watch
array set app {}; array set title {}
proc send {cmd} { puts $::watch $cmd }
proc on_watch {} {
	global watch app title tab order cur pending G
	while {[gets $watch l] >= 0} {
		set w [split $l]
		switch -- [lindex $w 0] {
			T+ {}
			T {
				set id [lindex $w 1]
				switch -- [lindex $w 2] {
					app { set app($id) [lindex $w 3] }
					title { set title($id) [join [lrange $w 3 end]] }
					state {
						if {[info exists tab($id)] && [string match *act* [lindex $w 3]] && $id ne $cur} {
							# a tab was raised from outside (Alt+Tab, the dock): it becomes the current tab
							log external $id; select $id
						}
						if {[info exists tab($id)] && $id eq $cur && [string match *act* [lindex $w 3]]} { restack }
					}
					done {
						if {[info exists app($id)] && [string match "ribbon-term-$G-*" $app($id)] && ![info exists tab($id)]} {
							set tab($id) $app($id); lappend order $id
							log mapped $id [expr {[dict exists $pending $app($id)] ? ([us] - [dict get $pending $app($id)]) / 1000.0 : "-"}]
							select $id
						}
						if {[info exists tab($id)]} { draw }
					}
				}
			}
			T- {
				set id [lindex $w 1]
				if {[info exists tab($id)]} {
					set k [lsearch $order $id]; set order [lreplace $order $k $k]; unset tab($id)
					log closed $id
					if {![llength $order]} { log empty; exit 0 }
					if {$id eq $cur} { set cur ""; select [lindex $order [expr {min($k, [llength $order] - 1)}]] }
					draw
				}
			}
			ready { log ready }
		}
	}
	if {[eof $watch]} { log watch-eof; exit 1 }
}

# ---------------------------------------------------------------- actions
proc newtab {{cmd {}}} {
	global G seq pending
	incr seq; set a "ribbon-term-$G-$seq"
	dict set pending $a [us]
	exec footclient -N --app-id $a {*}$cmd 2>>[expr {[info exists ::env(RTT_LOG)] ? $::env(RTT_LOG) : "/dev/null"}] &
}
proc select {id} {
	global cur
	if {$id eq $cur} return
	set old $cur; set cur $id
	set t0 [us]
	send "activate $id"
	if {$old ne ""} { send "minimize $old" }
	log select $id from $old [expr {([us] - $t0) / 1000.0}]
	restack; draw
}
proc closetab {id} { send "close $id" }
# keep the strip over its window: labwc raises the foot window on a click, not the strip
proc restack {} { set t0 [us]; press F11; log raise [expr {([us] - $t0) / 1000.0}] }

# ---------------------------------------------------------------- drawing (the Term-E strip, simplified)
font create rtt -family Inter -size -13 -weight normal
font create rttb -family Inter -size -13 -weight bold
wm geometry . ${W}x${STRIP}+${X}+${Y}
# labwc makes this window 60 px tall whatever its size hints say (LAB_MIN_VIEW_HEIGHT; measured, Tk's
# minsize and resizable don't change it). The tabs sit in the top 46; the window under it covers the rest,
# so every raise puts the strip first and the tabs over it.
. configure -background $C(d2)
canvas .c -highlightthickness 0 -background $C(d2) -height $STRIP
pack .c -fill both -expand 1
proc label_of {id} {
	global title
	set t [expr {[info exists title($id)] ? $title($id) : "foot"}]
	expr {[string length $t] > 22 ? "[string range $t 0 20]…" : $t}
}
proc draw {} {
	global order cur C W STRIP
	.c delete all
	set x 14
	foreach id $order {
		set on [expr {$id eq $cur}]
		set t [label_of $id]; set f [expr {$on ? "rttb" : "rtt"}]
		set tw [expr {[font measure $f $t] + 56}]
		if {$on} {
			.c create rectangle $x 8 [expr {$x + $tw}] $STRIP -fill $C(bar) -outline "" -tags [list tab $id]
			.c create line $x $STRIP $x 8 [expr {$x + $tw}] 8 [expr {$x + $tw}] $STRIP -fill $C(border)
		} else {
			.c create rectangle $x 8 [expr {$x + $tw}] [expr {$STRIP - 1}] -fill "" -outline "" -tags [list tab $id]
		}
		.c create text [expr {$x + 16}] 27 -anchor w -text $t -font $f -fill [expr {$on ? $C(fg) : $C(muted)}] -tags [list tab $id]
		.c create text [expr {$x + $tw - 18}] 27 -text × -font rtt -fill $C(muted) -tags [list x $id]
		incr x [expr {$tw + 2}]
	}
	.c create text [expr {$x + 16}] 27 -text + -font rttb -fill $C(muted) -tags plus
	.c create line 0 [expr {$STRIP - 1}] $W [expr {$STRIP - 1}] -fill $C(border) -tags rule
	.c lower rule
	foreach {i g} {0 × 1 □ 2 –} { .c create text [expr {$W - 22 - 34 * $i}] 27 -text $g -font rtt -fill $C(muted) -tags wc$i }
}
.c bind tab <Button-1> { select [lindex [.c gettags current] 1] }
.c bind x <Button-1> { closetab [lindex [.c gettags current] 1] }
.c bind plus <Button-1> newtab
.c bind wc0 <Button-1> { foreach id $order { closetab $id } }
# drag the empty strip to move the window: the strip follows the pointer, the tabs follow the strip
set drag {}
bind .c <Button-1> { if {[.c find withtag current] eq "" || "rule" in [.c gettags current]} { set drag [list %X %Y $X $Y [us]] } }
bind .c <B1-Motion> {
	if {$drag ne ""} {
		lassign $drag px py ox oy
		set X [expr {$ox + %X - $px}]; set Y [expr {$oy + %Y - $py}]
		if {[us] - [lindex $drag 4] > 50000} { lset drag 4 [us]; regroup drag }
	}
}
bind .c <ButtonRelease-1> { if {$drag ne ""} { set drag {}; regroup drop } else { restack } }

# ---------------------------------------------------------------- test hooks: commands on stdin
fconfigure stdin -blocking 0 -buffering line
fileevent stdin readable {
	while {[gets stdin l] > 0} {
		switch -- [lindex $l 0] {
			new { newtab [lrange $l 1 end] }
			select { select [lindex $order [lindex $l 1]] }
			close { closetab [lindex $order [lindex $l 1]] }
			moveto { lassign [lrange $l 1 end] X Y; regroup cmd }
			tabs { log tabs cur $cur order $order }
			quit { exit 0 }
		}
	}
	if {[eof stdin]} { fileevent stdin readable {} }
}
rc_write; reload
draw
log strip $G $X $Y $W $H
bind . <Configure> { if {"%W" eq "."} { log configure %w x %h at [winfo rootx .],[winfo rooty .] } }
