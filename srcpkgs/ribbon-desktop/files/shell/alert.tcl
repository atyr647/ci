# alert.tcl - Ribbon's alert: a short question or refusal in the sheet's anatomy (design/STYLE.md §15) at the
# dialog's width, 440 (boards design/mockups/Alert-*, design/tools/gen_alerts.py). The 44 tile, the 20 px title and
# the 13 px line or lines under it; a 1 px rule and the 72 px footer with the buttons, the last one the default
# (the accent, Return). No body, no helper text. Shared by the shell (the terminal's questions, shell/mod-term.tcl)
# and Appearance (the onstage sheet's refusals); it needs text.tcl, raster.tcl, theme.tcl and rbnalpha loaded.
#
#   alert::open ?-option value ...?   show it; returns 0 (and shows nothing) while another alert is open
#     -icon NAME|PATHDATA   the tile's icon: film image terminal refresh, or a 24-unit SVG path
#     -title TEXT  -lines {TEXT ...}
#     -buttons {{KEY LABEL} ...}  left to right; the last is the default (primary). Esc answers the first.
#     -at {X Y}   the box's top-left on the screen; default: centred on the screen
#     -hang 0|1   the top edge is a strip's: square, no ring, no shadow above (a sheet under the terminal's strip)
#     -modal 0|1  grab the pointer for this application while it is open (Appearance; not the shell, whose bars
#                 must keep working)
#     -command SCRIPT  run with the answer's KEY appended once it is answered
#   alert::ask ?-option value ...?    the same, waiting (vwait) for the answer; returns its KEY, or "" when another
#                 alert was already open
#   alert::answer KEY   answer the open alert (as a click on that button would)
#   alert::cancel       answer it with the first button (Esc)
#   alert::isopen       1 while an alert is open
#   alert::paint CANVAS SPEC   draw an alert's contents (SPEC: the options as a dict) at 0,0 of CANVAS; returns
#                 {W H buttons}, buttons {KEY X Y W H} in canvas coordinates. The window's own drawing, and the
#                 scene test's.

namespace eval alert {
	variable win .ribbon_alert
	variable W 440
	variable spec {}          ;# the open alert's options
	variable hits {}          ;# {KEY x y w h} of its buttons
	variable result           ;# alert::ask waits on result(N)
	array set result {}
	variable seq 0
	variable back {}          ;# the window that had the keyboard before the alert took it
	variable icons
	array set icons {
		film     {M4 3h16a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z M7 3v18 M17 3v18 M3 12h18 M3 7.5h4 M3 16.5h4 M17 7.5h4 M17 16.5h4}
		image    {M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z M8.5 10a1.5 1.5 0 1 0 0-3a1.5 1.5 0 1 0 0 3z M21 15l-5-5L5 21}
		terminal {M4 17l6-6-6-6 M12 19h8}
		refresh  {M23 4v6h-6 M1 20v-6h6 M3.51 9a9 9 0 0 1 14.85-3.36L23 10 M1 14l4.64 4.36A9 9 0 0 0 20.49 15}
	}
	# the board's measures: padding 26 28, the tile 44 and 14 from the text, the title's line 23, 3 to the
	# lines (18 each), 22 under the header, the footer 72 with 38 tall buttons 10 apart
	variable PT 26
	variable PX 28
	variable HB 22
	variable FOOT 72
}

proc alert::colours {} {
	array set c [array get theme::c]
	dict create bar $c(BAR) field $c(FIELD) pill $c(PILL) border $c(BORDER) fg $c(FG) muted $c(MUTED) \
		accent $c(ACCENT) ink [expr {[info exists c(ON_ACCENT)] && $c(ON_ACCENT) ne "" ? $c(ON_ACCENT) : $c(BAR)}]
}

proc alert::fonts {} {
	text::font alert_t {Ribbon Space Grotesk 600} 20
	text::font alert_l {Ribbon Inter 400} 13
	text::font alert_b {Ribbon Inter 400} 14
	text::font alert_p {Ribbon Inter 600} 14
}

# The halfway colour of two #rrggbb (the tile's 160° gradient from the raised tone to the field's, as its middle).
proc alert::mix {a b} {
	scan $a #%2x%2x%2x r0 g0 b0; scan $b #%2x%2x%2x r1 g1 b1
	::format #%02X%02X%02X [expr {($r0 + $r1) / 2}] [expr {($g0 + $g1) / 2}] [expr {($b0 + $b1) / 2}]
}

# The lines as drawn: each given line wrapped to the text column at word boundaries.
proc alert::wrap {lines width} {
	set out {}
	foreach l $lines {
		set cur ""
		foreach w [split $l " "] {
			# a word wider than the column (a path) is cut
			if {[text::width alert_l $w] > $width} { set w "[text::clip alert_l $w [expr {$width - [text::width alert_l \u2026]}]]\u2026" }
			set t [expr {$cur eq "" ? $w : "$cur $w"}]
			if {$cur ne "" && [text::width alert_l $t] > $width} { lappend out $cur; set cur $w } else { set cur $t }
		}
		lappend out $cur
	}
	return $out
}

proc alert::height {n} {
	variable PT; variable HB; variable FOOT
	expr {$PT + max(44, 23 + 3 + 18 * $n) + $HB + $FOOT}
}

proc alert::paint {cv spec} {
	variable W; variable PT; variable PX; variable HB; variable FOOT
	variable icons
	fonts
	set k [colours]
	set o [dict merge {-icon "" -title "" -lines {} -buttons {{ok OK}}} $spec]
	set tx [expr {$PX + 44 + 14}]
	set lines [wrap [dict get $o -lines] [expr {$W - $tx - $PX}]]
	set H [height [llength $lines]]
	$cv delete all
	$cv configure -background [dict get $k bar]
	$cv create rectangle 0 0 $W $H -fill [dict get $k bar] -width 0
	# the tile and its icon
	rbn::box $cv $PX $PT 44 44 -fill [mix [dict get $k pill] [dict get $k field]] -radius 12 -ring [list [dict get $k border] 1] -on [dict get $k bar]
	set d [dict get $o -icon]
	if {[info exists icons($d)]} { set d $icons($d) }
	if {$d ne ""} { $cv create image [expr {$PX + 11}] [expr {$PT + 11}] -image [raster::icon $d 22 1.7 [dict get $k fg]] -anchor nw }
	# the title and the lines
	text::draw $cv $tx [expr {$PT + 11.5}] alert_t [dict get $k fg] [dict get $o -title] w -ls -0.4
	set y [expr {$PT + 23 + 3 + 9}]
	foreach l $lines { text::draw $cv $tx $y alert_l [dict get $k muted] $l w -tnum 1; incr y 18 }
	# the footer: its rule, then the buttons from the right
	set fy [expr {$H - $FOOT}]
	$cv create rectangle 0 $fy $W [expr {$fy + 1}] -fill [dict get $k border] -width 0
	set by [expr {$fy + 17}]
	set bx [expr {$W - $PX}]
	set bs [dict get $o -buttons]
	set out {}
	for {set i [expr {[llength $bs] - 1}]} {$i >= 0} {incr i -1} {
		lassign [lindex $bs $i] key label
		set prim [expr {$i == [llength $bs] - 1}]
		set f [expr {$prim ? "alert_p" : "alert_b"}]
		set bw [expr {round([text::width $f $label]) + 36}]
		set bx [expr {$bx - $bw}]
		if {$prim} {
			rbn::box $cv $bx $by $bw 38 -fill [dict get $k accent] -radius 10 -on [dict get $k bar]
			text::draw $cv [expr {$bx + $bw / 2.0}] [expr {$by + 19}] $f [dict get $k ink] $label center
		} else {
			rbn::box $cv $bx $by $bw 38 -fill [dict get $k bar] -radius 10 -ring [list [dict get $k border] 1] -on [dict get $k bar]
			text::draw $cv [expr {$bx + $bw / 2.0}] [expr {$by + 19}] $f [dict get $k fg] $label center
		}
		set out [linsert $out 0 [list $key $bx $by $bw 38]]
		set bx [expr {$bx - 10}]
	}
	list $W $H $out
}

proc alert::isopen {} {
	variable spec
	expr {[dict size $spec] > 0}
}

proc alert::open {args} {
	variable win
	variable spec
	variable hits
	variable W
	if {[isopen]} { return 0 }
	set o [dict merge {-icon "" -title "" -lines {} -buttons {{ok OK}} -at "" -hang 0 -modal 0 -command ""} $args]
	set spec $o
	variable back [focus]
	set k [colours]
	catch {::destroy $win}
	set cv [rbn::surface $win -fill [dict get $k bar]]
	catch {wm attributes $win -type dialog}
	lassign [paint $cv $o] w h hits
	$cv configure -width $w -height $h
	set at [dict get $o -at]
	if {$at eq ""} {
		# centred on the main display in the shell (display.tcl), else on the X screen
		if {[llength [info commands ::display::rect]]} { lassign [display::rect] ox oy ow oh } else {
			lassign [list 0 0 [winfo screenwidth .] [winfo screenheight .]] ox oy ow oh
		}
		set at [list [expr {$ox + ($ow - $w) / 2}] [expr {$oy + ($oh - $h) / 2}]]
	}
	lassign $at x y
	set look [list -fill [dict get $k bar] -radius [expr {[dict get $o -hang] ? {0 0 16 16} : 16}] \
		-ring [list [dict get $k border] 1 [expr {[dict get $o -hang] ? "lrb" : "tlrb"}]] -shadow {24 64 0.6}]
	rbn::popup $win $x $y $w $h $look -clip [expr {[dict get $o -hang] ? "t" : ""}]
	bind $cv <ButtonRelease-1> {alert::click %x %y}
	bind $win <KeyPress-Escape> {alert::cancel}
	foreach key {Return KP_Enter} { bind $win <KeyPress-$key> {alert::answer [lindex [lindex [dict get $alert::spec -buttons] end] 0]} }
	update idletasks
	# the keyboard: a dialog-type window, which the compositor may give focus to once it is mapped
	catch {focus -force $win}
	after 80 [list catch [list focus -force $win.c]]
	if {[dict get $o -modal]} { catch {grab $win} }
	return 1
}

proc alert::click {x y} {
	variable hits
	foreach h $hits {
		lassign $h key bx by bw bh
		if {$x >= $bx && $x < $bx + $bw && $y >= $by && $y < $by + $bh} { answer $key; return }
	}
}

proc alert::answer {key} {
	variable win
	variable spec
	variable hits
	if {![isopen]} return
	set cmd [dict get $spec -command]
	set spec {}; set hits {}
	catch {grab release $win}
	rbn::hide $win
	catch {::destroy $win}
	# the keyboard back to the window that had it (Appearance's sheet takes keys); X would leave it nowhere
	variable back
	if {$back ne "" && [winfo exists $back]} { catch {focus -force $back} }
	set back {}
	if {$cmd ne ""} { uplevel #0 [list {*}$cmd $key] }
}

proc alert::cancel {} {
	variable spec
	if {![isopen]} return
	answer [lindex [lindex [dict get $spec -buttons] 0] 0]
}

proc alert::ask {args} {
	variable result
	variable seq
	set n [incr seq]
	set v ::alert::result($n)
	if {![open {*}$args -command [list apply {{v key} { set $v $key }} $v]]} { return "" }
	vwait $v
	set key [set $v]
	unset $v
	return $key
}
