# mod-notify-history.tcl - the notification history, Do Not Disturb and the left bar's bell
# (STYLE §12 and §19; Notify-Final-5 to 8). A shell module (C2).
#
# The history hangs from the left bar (top 66, text at x 22, the rule at x 8, to x 428), newest first:
# "Now" (the last hour), then "Earlier today". The bell opens it, and Super+N does too
# (ribbon-shell-ctl notify-history). It reads and changes the store in mod-notify.tcl only through its
# hooks: notify::history, notify::seen, notify::dismiss, notify::forget, notify::act, notify::keycaps,
# notify::onchange and notify::hold_filter.
#
# The list shows today's entries (since local midnight). It is saved whole to
# $XDG_STATE_HOME/ribbon/notifications, with Do Not Disturb and its end time: one Tcl list, written to a
# temporary name and renamed over the old file, read back with lindex and checked, never sourced.
#
# Keys while it is open: Up and Down select; the entry's own keys act on it (Return for the default
# action, its letter for the rest); Delete clears it; Escape closes it (or its dropdown). The mouse does
# the same: a click selects, a keycap acts, the × clears, Clear and Clear all clear, the switch and the
# until dropdown set Do Not Disturb. Nothing is on screen while it is closed.

namespace eval nhist {
	variable open 0
	variable sel ""        ;# the selected entry's id
	variable marks {}      ;# unseen when it opened, or arrived while open: they keep the accent rule
	variable hits {}       ;# {x0 y0 x1 y1 script}, from the last draw
	variable rows {}       ;# {id top bottom}: the entries' tops in the list's own coordinates
	variable scroll 0
	variable content 0
	variable viewport 0
	variable hover ""
	variable menu 0        ;# the until dropdown is open
	variable dnd 0         ;# Do Not Disturb is on
	variable dnd_mode {until 08:00}   ;# the chosen mode: for 1h, for 3h, until HH:MM, forever
	variable dnd_end 0     ;# when it ends (epoch seconds); 0 is until turned off
	variable timer ""
	variable saving ""
	variable scrimkey ""
	variable scrimimg ""
	variable fonts_ok 0
	variable top 164       ;# the list's top edge on the screen
	variable cv ""         ;# the canvas the last draw drew on (the surface's, or the stage)
	variable drawing 0
	# the bell and the × (Lucide-style line paths, as the other icons are drawn)
	variable bell_path {M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9 M10.3 21a1.94 1.94 0 0 0 3.4 0}
	variable bell_off_path {M8.7 3A6 6 0 0 1 18 8a21.3 21.3 0 0 0 .6 5 M17 17H3s3-2 3-9a4.7 4.7 0 0 1 .3-1.7 M10.3 21a1.94 1.94 0 0 0 3.4 0 M2 2l20 20}
}

# ---- the store, read through its hooks ------------------------------------------

proc nhist::midnight {} {
	clock scan [clock format [clock seconds] -format {%Y-%m-%d 00:00}] -format {%Y-%m-%d %H:%M}
}

# The entries the list shows: today's, newest first.
proc nhist::listed {} {
	set mid [nhist::midnight]
	set out {}
	foreach e [notify::history] { if {[dict get $e time] >= $mid} { lappend out $e } }
	return $out
}

# {label entries} for each group that has entries: "Now" (the last hour), then "Earlier today".
proc nhist::groups {} {
	set now [clock seconds]
	set hour {}; set earlier {}
	foreach e [nhist::listed] {
		if {[dict get $e time] >= $now - 3600} { lappend hour $e } else { lappend earlier $e }
	}
	set out {}
	if {[llength $hour]} { lappend out [list NOW $hour] }
	if {[llength $earlier]} { lappend out [list {EARLIER TODAY} $earlier] }
	return $out
}

# For the bar: the count shown on the bell, whether Do Not Disturb is on, whether the list is open.
proc nhist::bell_info {} {
	variable dnd
	variable open
	list [llength [nhist::listed]] $dnd $open
}

proc nhist::changed {kind id} {
	variable open
	variable marks
	# an entry that arrives while the list is open is unseen, and keeps its rule
	if {$kind eq "arrived" && $open && $id ni $marks} { lappend marks $id }
	nhist::save_soon
	nhist::sync
}

# Redraw what is open, and the bar's bell.
proc nhist::sync {} {
	nhist::draw
	if {[winfo exists .bar]} { bar::draw }
}

# ---- Do Not Disturb --------------------------------------------------------------

# A held entry: Do Not Disturb holds every popup but a critical one.
proc nhist::hold {e} {
	variable dnd
	expr {$dnd && [dict get $e urgency] != 2}
}

proc nhist::mode_label {mode} {
	switch -glob -- $mode {
		"for 1h" { return "For 1 hour" }
		"for 3h" { return "For 3 hours" }
		"until *" { return "Until [lindex $mode 1]" }
		default { return "Until I turn it off" }
	}
}

# Turns Do Not Disturb on until END (epoch seconds, 0 for until it is turned off).
proc nhist::dnd_apply {mode end} {
	variable dnd
	variable dnd_mode
	variable dnd_end
	variable timer
	if {$timer ne ""} { after cancel $timer; set timer "" }
	set dnd 1; set dnd_mode $mode; set dnd_end $end
	set notify::hold_filter nhist::hold
	set now [clock seconds]
	if {$end > 0} { set timer [after [expr {max(1, $end - $now) * 1000}] nhist::dnd_off] }
}

# The chosen mode, from now: "for 1h", "for 3h", "until HH:MM" (the next such time) or "forever".
proc nhist::dnd_set {mode} {
	set now [clock seconds]
	switch -glob -- $mode {
		"for 1h" { set end [expr {$now + 3600}] }
		"for 3h" { set end [expr {$now + 3 * 3600}]  }
		"until *" {
			set t [clock scan "[clock format $now -format %Y-%m-%d] [lindex $mode 1]" -format {%Y-%m-%d %H:%M}]
			if {$t <= $now} { incr t 86400 }
			set end $t
		}
		default { set end 0 }
	}
	nhist::dnd_apply $mode $end
	nhist::save_soon
	nhist::sync
}

proc nhist::dnd_off {} {
	variable dnd
	variable timer
	variable dnd_end
	set timer ""
	set dnd 0; set dnd_end 0
	set notify::hold_filter ""
	nhist::save_soon
	nhist::sync
}

proc nhist::dnd_click {} {
	variable dnd
	variable dnd_mode
	variable menu
	set menu 0
	if {$dnd} { nhist::dnd_off } else { nhist::dnd_set $dnd_mode }
}

proc nhist::menu_toggle {} {
	variable menu
	set menu [expr {!$menu}]
	nhist::draw
}

proc nhist::dnd_pick {mode} {
	variable menu
	set menu 0
	nhist::dnd_set $mode
}

# ---- open, close, the bell -------------------------------------------------------

proc nhist::bell {b} { if {$b == 1} { nhist::toggle } }

proc nhist::toggle {args} {
	variable open
	if {$open} { nhist::close } else { nhist::show }
}

proc nhist::show {} {
	variable open
	variable marks
	variable sel
	variable scroll
	variable menu
	launcher::cancel
	panel::close
	set marks {}
	foreach e [notify::history] { if {[dict get $e seen] == 0} { lappend marks [dict get $e id] } }
	set open 1; set menu 0; set scroll 0
	# Super+N with a popup up opens the list with that popup's entry selected (the newest); otherwise nothing is
	set ids [nhist::ids]
	set sel ""
	foreach id [lreverse $notify::shown] { if {$id in $ids} { set sel $id; break } }
	# every entry is seen now; the rule stays on the marked ones while the list is open
	notify::seen
	set launcher::keytarget nhist::key
	launcher::input_show
	nhist::sync
}

proc nhist::close {} {
	variable open
	variable marks
	variable menu
	if {!$open} return
	set open 0; set marks {}; set menu 0
	rbn::hide .nhist
	if {$launcher::keytarget eq "nhist::key"} {
		set launcher::keytarget ""
		launcher::input_hide
	}
	if {[winfo exists .bar]} { bar::draw }
}

# The listed ids, in display order.
proc nhist::ids {} {
	lmap e [nhist::listed] { dict get $e id }
}

# ---- acting on entries ----------------------------------------------------------

# Clears one entry: closed with reason 2 if it is still up, then taken off the list.
proc nhist::clear_one {id} {
	variable sel
	set ids [nhist::ids]
	set i [lsearch -exact $ids $id]
	if {$sel eq $id} {
		# the selection moves to the next entry down, or the one above at the end
		set next [expr {$i + 1 < [llength $ids] ? [lindex $ids $i+1] : ($i > 0 ? [lindex $ids $i-1] : "")}]
		set sel $next
	}
	notify::dismiss $id
	notify::forget $id
}

proc nhist::clear_ids {ids} {
	foreach id $ids { nhist::clear_one $id }
	nhist::sync
}

proc nhist::clear_all {} { nhist::clear_ids [nhist::ids] }

proc nhist::select {id} {
	variable sel
	set sel $id
	nhist::reveal $id
	nhist::sync
}

# An action's keycap: the action's identifier goes to the app (notify::act).
proc nhist::act_click {id action} {
	notify::act $id $action
	nhist::sync
}

# Scrolls the list so that ID shows.
proc nhist::reveal {id} {
	variable rows
	variable scroll
	variable viewport
	foreach r $rows {
		lassign $r rid ctop cbot
		if {$rid ne $id} continue
		if {$ctop < $scroll} { set scroll $ctop }
		if {$cbot > $scroll + $viewport} { set scroll [expr {$cbot - $viewport}] }
		if {$scroll < 0} { set scroll 0 }
	}
}

# ---- keys, the mouse ------------------------------------------------------------

# The launcher's key route while the list is open (launcher::key hands keys here).
proc nhist::key {sym char state} {
	variable open
	variable sel
	variable menu
	if {!$open} return
	set ids [nhist::ids]
	set i [lsearch -exact $ids $sel]
	switch -- $sym {
		Escape {
			if {$menu} { set menu 0; nhist::draw } else { nhist::close }
			return
		}
		Up - KP_Up { if {$i > 0} { nhist::select [lindex $ids $i-1] }; return }
		Down - KP_Down { if {$i >= 0 && $i + 1 < [llength $ids]} { nhist::select [lindex $ids $i+1] } elseif {$i < 0 && [llength $ids]} { nhist::select [lindex $ids 0] }; return }
		Delete - KP_Delete { if {$sel ne ""} { nhist::clear_one $sel; nhist::sync }; return }
		Return - KP_Enter {
			if {$sel eq ""} return
			foreach {k l a} [notify::keycaps $sel] { if {$k eq "↵"} { nhist::act_click $sel $a; return } }
			return
		}
	}
	if {$sel eq "" || [string length $char] != 1 || ![string is alpha -strict $char]} return
	foreach {k l a} [notify::keycaps $sel] {
		if {[string equal -nocase $k $char]} { nhist::act_click $sel $a; return }
	}
}

# A click: the topmost hit under the pointer runs its script.
proc nhist::press {x y} {
	variable hits
	foreach h [lreverse $hits] {
		lassign $h x0 y0 x1 y1 script
		if {$x >= $x0 && $x < $x1 && $y >= $y0 && $y < $y1} { uplevel #0 $script; return }
	}
}

proc nhist::motion {x y} {
	variable rows
	variable top
	variable scroll
	variable hover
	set h ""
	if {$x >= 12 && $x < 438} {
		foreach r $rows {
			lassign $r rid ctop cbot
			set t [expr {$top + $ctop - $scroll}]
			if {$y >= $t && $y < $top + $cbot - $scroll} { set h $rid }
		}
	}
	if {$h ne $hover} { set hover $h; nhist::draw }
}

proc nhist::wheel {d} {
	variable scroll
	variable content
	variable viewport
	set max [expr {max(0, $content - $viewport)}]
	set scroll [expr {max(0, min($max, $scroll + $d))}]
	nhist::draw
}

# ---- drawing --------------------------------------------------------------------

proc nhist::fonts {} {
	variable fonts_ok
	if {$fonts_ok} return
	notify::fonts
	foreach {name family px} {
		nHead {Ribbon Space Grotesk 600} 28
		nTitle17 {Ribbon Space Grotesk 600} 17
		nDnd {Ribbon Inter 500} 13
		nDndB {Ribbon Inter 600} 13
		nClear {Ribbon Inter 500} 12
		nSec {Ribbon Inter 600} 11
		nEmpty {Ribbon Inter 400} 14
	} { text::font $name $family $px }
	set fonts_ok 1
}

# The scrim: §d2 down the left side (90 % to 74 % at 42 % of its width, then none), from the piece's top.
# Under a short list it fades out over 180 px below FADEY (or does not fade when FADEY is negative).
proc nhist::scrim_png {bg fadey w h s} {
	lassign [raster::rgb $bg] r g b
	set sw [expr {int(ceil($w / double($s)))}]
	set sh [expr {int(ceil($h / double($s)))}]
	set rows {}
	for {set j 0} {$j < $sh} {incr j} {
		set y [expr {$j * $s + $s / 2.0}]
		set vf 1.0
		if {$fadey >= 0 && $y > $fadey} { set vf [expr {max(0.0, 1 - ($y - $fadey) / 180.0)}] }
		set row {}
		for {set i 0} {$i < $sw} {incr i} {
			set f [expr {($i * $s + $s / 2.0) / double($w)}]
			if {$f <= 0.42} { set a [expr {0.9 - 0.16 * $f / 0.42}] } else { set a [expr {0.74 * (1 - ($f - 0.42) / 0.58)}] }
			lappend row $r $g $b [expr {int(round(255 * max(0.0, $a * $vf)))}]
		}
		lappend rows $row
	}
	raster::png $sw $sh $rows
}

proc nhist::scrim {fadey h} {
	variable scrimkey
	variable scrimimg
	set bg $::theme::c(DESK_BOTTOM)
	set key [list $bg $fadey $h]
	if {$scrimimg ne "" && $scrimkey eq $key} { return $scrimimg }
	set small [raster::cached [list nhist-scrim $bg $fadey $h] [list nhist::scrim_png $bg $fadey 780 $h 8]]
	set img [image create photo]
	$img copy $small -zoom 8 8
	if {$scrimimg ne ""} { catch {image delete $scrimimg} }
	set scrimimg $img
	set scrimkey $key
	return $img
}

# One entry's parts from its text: the title lines, the body lines, whether it has a progress bar and its
# keycaps. Returns {title body progress acts h}: h is the content height, from its app line's top.
proc nhist::geom {e} {
	set title [notify::wrap nTitle17 [dict get $e summary] 406 2]
	set body [expr {[dict get $e body] eq "" ? {} : [notify::wrap nBody [dict get $e body] 406 2]}]
	set prog [expr {[dict get $e value] ne ""}]
	set acts [notify::keycaps [dict get $e id]]
	# the title (22 tall, 22 below the app line), then the body 4 below it, 21 per line; the keycaps 9 below
	set lb [expr {22 + 22 * [llength $title]}]
	if {[llength $body]} { incr lb [expr {4 + 21 * [llength $body]}] }
	if {$prog} { incr lb 34 }
	set h $lb
	if {[llength $acts]} { set h [expr {$lb + 9 + 22}] }
	list $title $body $prog $acts $h
}

# One entry at ITOP (its app line's top), faded by A. Returns nothing; adds its hits and rows.
proc nhist::entry {c e itop a} {
	variable sel
	variable hover
	variable hits
	variable rows
	variable top
	variable scroll
	variable marks
	lassign [nhist::geom $e] title body prog acts h
	set id [dict get $e id]
	set ctop [expr {$itop - $top + $scroll}]
	lappend rows [list $id $ctop [expr {$ctop + $h}]]
	array set k [array get ::theme::c]
	# the wash under the pointer or on the selection, with the × at its end
	if {$id eq $sel || $id eq $hover} {
		# the wash covers the entry's block, from the rule above it to the rule below
		rbn::box $c 12 [expr {$itop - 14}] 426 [expr {$h + 31}] -fill $k(FIELD) -radius 10 -on ""
	}
	if {$id in $marks} {
		rbn::box $c 8 $itop 3 $h -fill $k(ACCENT) -radius 2 -on ""
	}
	set tone [expr {$a}]
	# app line: the app's icon (notify::icon: the same one the popup draws), its name at 44, then the time
	set app [dict get $e app]
	set ax [expr {22 + [notify::icon $c $e 22 [expr {$itop + 4}] $tone]}]
	text::draw $c $ax [expr {$itop + 11}] nApp [notify::tone $tone] $app w
	set aw [text::width nApp $app]
	text::draw $c [expr {$ax + $aw + 8}] [expr {$itop + 11}] nTime [notify::tone [expr {0.6 * $tone}]] [notify::ago [dict get $e time]] w
	if {$id eq $sel || $id eq $hover} {
		rbn::box $c 406 $itop 22 22 -fill $k(FIELD) -radius 6 -ring [list $k(BORDER) 1] -on ""
		bar::icon $c x 12 2 $k(MUTED) 411 [expr {$itop + 5}]
		lappend hits [list 406 $itop 428 [expr {$itop + 22}] [list nhist::clear_one $id]]
	}
	# the title, the body, the progress
	set y [expr {$itop + 36}]
	foreach line $title {
		text::draw $c 22 $y nTitle17 [notify::tone $tone] $line w
		incr y 22
	}
	# the body's first line sits 25 below the title's last line
	set y [expr {$y - 22 + 25}]
	if {[llength $body]} {
		foreach line $body {
			text::draw $c 22 $y nBody [notify::tone [expr {0.76 * $tone}]] $line w
			incr y 21
		}
		set y [expr {$y - 21}]
	}
	set y [expr {$itop + 22 + 22 * [llength $title] + ([llength $body] ? 4 + 21 * [llength $body] : 0)}]
	if {$prog} {
		set v [dict get $e value]
		set bar [expr {$y + 10}]
		$c create rectangle 22 $bar 428 [expr {$bar + 4}] -fill [notify::tone [expr {0.18 * $tone}]] -width 0
		$c create rectangle 22 $bar [expr {22 + 406 * $v / 100.0}] [expr {$bar + 4}] -fill [notify::tone $tone] -width 0
		text::draw $c 22 [expr {$bar + 22}] nSmall [notify::tone [expr {0.6 * $tone}]] [notify::done $e] w
		set eta [notify::eta $e]
		if {$eta ne ""} { text::draw $c 428 [expr {$bar + 22}] nSmall [notify::tone [expr {0.6 * $tone}]] $eta e }
	}
	# the keycaps, 8 apart from the label; a click acts on the one it is over
	if {[llength $acts]} {
		set ky [expr {$itop + $h - 22}]
		set x 22
		set first 1
		foreach {key label action} $acts {
			set kw [expr {max(22, [text::width nKey $key] + 12)}]
			rbn::box $c $x $ky $kw 22 -fill $k(FIELD) -radius 5 -ring [list $k(BORDER) 1] -on ""
			text::draw $c [expr {$x + $kw / 2.0}] [expr {$ky + 11}] nKey [notify::tone $tone] $key c
			set lx [expr {$x + $kw + 8}]
			set lf [expr {$first ? "nAct" : "nActQ"}]
			set lw [text::width $lf $label]
			text::draw $c $lx [expr {$ky + 11}] $lf [notify::tone [expr {($first ? 1.0 : 0.76) * $tone}]] $label w
			lappend hits [list $x $ky [expr {$lx + $lw + 12}] [expr {$ky + 22}] [list nhist::act_click $id $action]]
			set x [expr {$lx + $lw + 20}]
			set first 0
		}
	}
	# the rest of the entry selects it
	lappend hits [list 12 [expr {$itop - 14}] 438 [expr {$itop + $h + 17}] [list nhist::select $id]]
}

proc nhist::draw {} {
	variable open
	variable hits
	variable rows
	variable scroll
	variable content
	variable viewport
	variable top
	variable dnd
	variable dnd_mode
	variable menu
	variable sel
	variable marks
	variable cv
	variable drawing
	if {!$open} return
	# a draw asked for while another reads the stage waits for it
	if {$drawing} { after 5 nhist::draw; return }
	nhist::fonts
	set w .nhist
	if {![winfo exists $w]} {
		rbn::surface $w
		# on the surface, not its canvas: a see-through surface has no canvas under the pointer
		bind $w <ButtonPress-1> {nhist::press %x %y}
		bind $w <Motion> {nhist::motion %x %y}
		bind $w <Leave> {nhist::motion -1 -1}
		bind $w <Button-4> {nhist::wheel -40}
		bind $w <Button-5> {nhist::wheel 40}
	}
	# the main display's height, from its top left (display.tcl)
	lassign [display::rect] ox oy - H
	# under a compositor the history is one see-through picture (npaint, in mod-notify.tcl): the entries
	# are drawn on its stage, in three layers: the header, the list (cut to its viewport), the dropdown
	set paint [npaint::on]
	set c [expr {$paint ? [npaint::stage nhist 464 $H] : "$w.c"}]
	set cv $c
	array set k [array get ::theme::c]
	$c delete all
	set hits {}; set rows {}
	set listed [nhist::listed]
	set n [llength $listed]
	# the header: the title, the count at 60 %
	text::draw $c 22 84 nHead $k(FG) "Notifications" w
	if {$n} {
		text::draw $c [expr {22 + [text::width nHead "Notifications"] + 10}] 84 nHead [notify::tone 0.6] $n w
	}
	# the Do Not Disturb row: the switch, its label, the until dropdown, Clear all
	# the switch (STYLE §9): 38 x 22, radius 11, a 16 px knob 3 in; off it is §pill with a §muted knob
	rbn::box $c 22 122 38 22 -fill [expr {$dnd ? $k(ACCENT) : $k(PILL)}] -radius 11 -on ""
	rbn::box $c [expr {$dnd ? 41 : 25}] 125 16 16 -fill [expr {$dnd ? $k(ON_ACCENT) : $k(MUTED)}] -radius 8 -on ""
	lappend hits [list 22 116 60 150 nhist::dnd_click]
	text::draw $c 70 133 [expr {$dnd ? "nDndB" : "nDnd"}] $k(FG) "Do Not Disturb" w
	if {$dnd} {
		set lab [nhist::mode_label $dnd_mode]
		set bx [expr {70 + [text::width nDndB "Do Not Disturb"] + 12}]
		set bw [expr {[text::width nDnd $lab] + 44}]
		rbn::box $c $bx 117 $bw 32 -fill $k(FIELD) -radius 8 -ring [list [expr {$menu ? $k(ACCENT) : $k(BORDER)}] 1] -on ""
		text::draw $c [expr {$bx + 12}] 133 nDnd $k(FG) $lab w
		bar::icon $c down 13 2.2 $k(FG) [expr {$bx + $bw - 23}] 127.5
		lappend hits [list $bx 117 [expr {$bx + $bw}] 149 nhist::menu_toggle]
	}
	if {$n} {
		rbn::box $c 350 117 78 32 -fill $k(BAR) -radius 8 -ring [list $k(BORDER) 1] -on ""
		text::draw $c 389 133 nDnd $k(FG) "Clear all" c
		lappend hits [list 350 117 428 149 nhist::clear_all]
	}
	$c addtag hdr all
	# the list: from the top edge under the Do Not Disturb row, to 64 above the foot
	set top 164
	set bottom [expr {$H - 64}]
	set viewport [expr {$bottom - $top}]
	set fadey -1
	if {!$n} {
		$c create rectangle 22 $top 428 [expr {$top + 1}] -fill $k(BORDER) -width 0
		text::draw $c 22 [expr {$top + 22}] nEmpty [notify::tone 0.76] "No notifications" w
		set content 0
		set scroll 0
	} else {
		set cy [expr {$top - $scroll}]
		set groups [nhist::groups]
		foreach g $groups {
			lassign $g label ents
			set ids [lmap e $ents { dict get $e id }]
			# the group label: 30 tall, with Clear at its right
			if {$cy + 30 > $top && $cy < $bottom} {
				bar::spaced $c 22 [expr {$cy + 18}] nSec [notify::tone 0.6] $label 0.88
				text::draw $c 428 [expr {$cy + 18}] nClear [notify::tone 0.6] "Clear" e
				lappend hits [list 380 $cy 428 [expr {$cy + 30}] [list nhist::clear_ids $ids]]
			}
			incr cy 43
			set last [expr {[llength $ents] - 1}]
			set idx 0
			foreach e $ents {
				lassign [nhist::geom $e] - - - - eh
				set id [dict get $e id]
				if {$cy + $eh > $top && $cy < $bottom} {
					set a 1.0
					if {$cy > $bottom - 48} { set a [expr {max(0.0, ($bottom - $cy) / 48.0)}] }
					nhist::entry $c $e $cy $a
				} else {
					# still a row, so the selection and the scroll know where it is
					lappend rows [list $id [expr {$cy - $top + $scroll}] [expr {$cy - $top + $scroll + $eh}]]
				}
				# 17 under the entry, then (between entries) the rule and 14 above the next one
				incr cy [expr {$eh + 17}]
				if {$idx < $last} {
					$c create rectangle 22 $cy 428 [expr {$cy + 1}] -fill $k(BORDER) -width 0
					incr cy 15
				}
				incr idx
			}
		}
		set content [expr {$cy + $scroll - $top}]
		# a short list fades its scrim out below its last line
		if {$content <= $viewport} { set endy $cy; set scroll 0 } else {
			set max [expr {$content - $viewport}]
			if {$scroll > $max} { set scroll $max }
		}
	}
	# a long list: the thumb, 3 wide, 12 right of the column
	if {$content > $viewport} {
		set th [expr {max(24.0, $viewport * $viewport / double($content))}]
		set ty [expr {$top + ($viewport - $th) * $scroll / double($content - $viewport)}]
		$c create rectangle 437 $ty 440 [expr {$ty + $th}] -fill [notify::tone 0.6] -width 0
	}
	$c addtag lst withtag !hdr
	# the dropdown hangs over the list
	if {$menu} {
		rbn::box $c 174 157 180 160 -fill $k(BAR) -radius 10 -ring [list $k(BORDER) 1] -on ""
		# four rows of 38, from 4 under the card's top edge (the board's rows centre at 180, 218, 256, 294)
		set y 161
		foreach {mode label} {{for 1h} {For 1 hour} {for 3h} {For 3 hours} {until 08:00} {Until 08:00} forever {Until I turn it off}} {
			set on [expr {$mode eq $dnd_mode}]
			if {$on} { rbn::box $c 180 [expr {$y + 2}] 168 34 -fill $k(FIELD) -radius 8 -on "" }
			text::draw $c 192 [expr {$y + 19}] [expr {$on ? "nDndB" : "nDnd"}] $k(FG) $label w
			if {$on} { bar::icon $c check 15 2.2 $k(ACCENT) 325 [expr {$y + 11.5}] }
			lappend hits [list 174 $y 354 [expr {$y + 38}] [list nhist::dnd_pick $mode]]
			incr y 38
		}
	}
	$c addtag menu withtag {!hdr && !lst}
	# the window is the screen's height, its scrim hangs from under the bar, and only the column takes clicks
	set fadey -1
	if {[info exists endy]} { set fadey [expr {int(($endy - 54) / 8) * 8}] }
	if {$paint} {
		set drawing 1
		set code [catch {npaint::render nhist $c 780 $H [list [nhist::scrim $fadey [expr {$H - 54}]] 0 54] \
			[list {hdr ""} [list lst [list 0 $top 780 $bottom]] {menu ""}]} img]
		set drawing 0
		if {!$code && $img ne ""} {
			npaint::present $w $ox $oy 780 $H $img [list [list 0 66 440 [expr {$H - 66}]]] 0
			if {[winfo exists .bar]} { catch {raise .bar} }
			return
		}
		if {$code} { notify::log "painting the history failed: $img"; set npaint::ok 0 }
		# the stage could not be read: drawn again, as a plain column
		return [nhist::draw]
	}
	rbn::show $w $ox $oy 780 $H -pieces [list [rbn::piece [nhist::scrim $fadey [expr {$H - 54}]] 0 54]] \
		-shape [list [list 0 54 780 [expr {$H - 54}]]] -input [list [list 0 66 440 [expr {$H - 66}]]] -raise 0
	# under the bar, never over it
	if {[winfo exists .bar]} { catch {raise .bar} }
}

# The bell's icon as an image: the slashed one under Do Not Disturb.
proc nhist::bell_icon {colour dnd} {
	variable bell_path
	variable bell_off_path
	raster::icon [expr {$dnd ? $bell_off_path : $bell_path}] 15 1.9 $colour
}

# ---- the saved state -------------------------------------------------------------

proc nhist::path {} {
	if {[info exists ::env(XDG_STATE_HOME)] && $::env(XDG_STATE_HOME) ne ""} {
		set base $::env(XDG_STATE_HOME)
	} else {
		set base [file join $::env(HOME) .local state]
	}
	return [file join $base ribbon notifications]
}

proc nhist::save_soon {} {
	variable saving
	if {$saving ne ""} { after cancel $saving }
	set saving [after 200 nhist::save]
}

# The record: the Do Not Disturb settings first, then every entry (open 0: the popups do not outlive the shell).
proc nhist::save {} {
	variable saving
	variable dnd
	variable dnd_end
	variable dnd_mode
	set saving ""
	set items [list [dict create v 1 dnd $dnd end $dnd_end mode $dnd_mode]]
	foreach e $notify::store { lappend items [dict replace $e open 0] }
	set path [nhist::path]
	if {[catch {
		file mkdir [file dirname $path]
		set tmp "$path.[pid].tmp"
		set fh [open $tmp w]
		fconfigure $fh -encoding utf-8
		puts -nonewline $fh $items
		::close $fh
		file rename -force $tmp $path
	} err]} {
		catch {file delete $tmp}
		notify::log "history not saved: $err"
	}
}

# An entry read back has every key the store uses, and well-formed actions and hints.
proc nhist::valid {e} {
	foreach k {id app summary body actions hints urgency timeout time seen open value t0 v0} {
		if {![dict exists $e $k]} { return 0 }
	}
	if {![string is integer -strict [dict get $e id]]} { return 0 }
	if {[catch {llength [dict get $e actions]}] || [llength [dict get $e actions]] % 2} { return 0 }
	if {[catch {dict size [dict get $e hints]}]} { return 0 }
	return 1
}

# Reads the saved record back at start-up. A file that does not read is dropped, and the shell starts empty.
proc nhist::load {} {
	variable dnd
	variable dnd_end
	variable dnd_mode
	set path [nhist::path]
	if {![file exists $path]} return
	set head {}
	set store {}
	if {[catch {
		set fh [open $path r]
		fconfigure $fh -encoding utf-8
		set items [read $fh]
		::close $fh
		set head [lindex $items 0]
		foreach e [lrange $items 1 end] {
			if {[nhist::valid $e]} { lappend store [dict replace $e open 0 seen 1] }
		}
	} err]} {
		notify::log "history dropped: $err"
		catch {file delete $path}
		return
	}
	# entries from before today are not shown: they go now
	set mid [nhist::midnight]
	set kept {}
	foreach e $store { if {[dict get $e time] >= $mid} { lappend kept $e } }
	set notify::store $kept
	# a new notification must not reuse an id the list still shows
	set max 0
	foreach e $kept { set max [expr {max($max, [dict get $e id])}] }
	if {[info exists notifyd::next] && $max > $notifyd::next} { set notifyd::next $max }
	if {[catch {dict get $head dnd}]} return
	set end [dict get $head end]
	set mode [dict get $head mode]
	if {[dict get $head dnd] && ($end == 0 || $end > [clock seconds])} {
		nhist::dnd_apply $mode $end
	}
	set dnd_mode $mode
}

# ---- start-up ----------------------------------------------------------------------

# The store's hooks and the saved record, once every module is sourced: this file sorts before
# mod-notify.tcl, and the notification server starts from the idle queue after this (queued first here).
proc nhist::init {} {
	notify::onchange nhist::changed
	nhist::load
}
after idle nhist::init
shell::verb notify-history nhist::toggle

