# page-keyboard.tcl - Settings → Keyboard and mouse (board Settings-A7-Keyboard-Mouse): the keyboard's layouts, the
# key that switches between them, what Caps Lock is, key repeat and Num Lock; the mouse's speed, acceleration,
# scrolling direction and hand; and, when a touchpad is attached, its speed, tap to click, scrolling direction and
# rest while typing. The logic is input.tcl (the settings file $XDG_CONFIG_HOME/ribbon/input.conf, labwc's files
# derived from it, labwc reconfigured after a change).
#
# Layout (window coordinates; the page runs from 270 to 1060): the left column is 420 wide (270..690), a rule at 722
# from 119 to 686, the right column from 755. A block's label is at 119 (the touchpad's at 357); its 48 px rows start
# 22 under it. On the left a row's dropdown is 200 wide and ends at 690, its segmented control and slider start at
# 450 (the slider 166 wide, its value ending at 690); on the right a slider is 200 wide and ends at 1060.

source -encoding utf-8 [file join [file dirname [file normalize [info script]]] input.tcl]

settings::page keyboard -title {Keyboard and mouse} -icon keyboard -group 3 -order 3 -draw settings::draw_keyboard \
	-rows {Layout {Second layout} {Switch layout with} {Caps Lock is} {Repeat after} {Repeat speed} {Num Lock on at login}
		{Pointer speed} Acceleration {Natural scrolling} Left-handed {Tap to click} {Off while typing}}

namespace eval kbdp {}

# The sliders' scales: Repeat after 100..600 ms in steps of 10, Repeat speed 8..48 a second, a pointer's speed
# -1..1 (libinput's scale) in steps of 0.02.
proc kbdp::delay {frac} { inp::put REPEAT_DELAY [expr {100 + 10 * round($frac * 50)}] }
proc kbdp::rate {frac} { inp::put REPEAT_RATE [expr {8 + round($frac * 40)}] }
proc kbdp::speed {key frac} { inp::put $key [format %.2f [expr {round(($frac * 2 - 1) * 50) / 50.0}]] }
proc kbdp::caps {v} { inp::put CAPS $v; page::draw }

# The board's segmented control: ui::seg, but as the board lays it out - the segments share the width equally unless
# a label with its 12 px of padding either side is wider (Caps Lock: 90), which then has its own width and the
# others share the rest.
proc kbdp::seg {id x y w opts cur script} {
	array set c [array get ui::c]
	ui::box $x $y $w 32 -fill $c(field) -radius 9 -ring [list $c(border) 1]
	set n [expr {[llength $opts] / 2}]
	set free [expr {$w - 6 - 2 * ($n - 1)}]
	set ws [lrepeat $n ""]
	set left $n
	# widen what does not fit an equal share, until every remaining segment fits its share
	for {set pass 0} {$pass < $n && $left > 0} {incr pass} {
		set share [expr {$free / double($left)}]
		set i 0; set changed 0
		foreach {k l} $opts {
			set need [expr {ceil([ui::measure i13s $l]) + 24}]
			if {[lindex $ws $i] eq "" && $need > $share} { lset ws $i $need; set free [expr {$free - $need}]; incr left -1; set changed 1 }
			incr i
		}
		if {!$changed} break
	}
	set share [expr {$left > 0 ? $free / double($left) : 0}]
	set sx [expr {$x + 3}]
	set i 0
	foreach {k l} $opts {
		set sw [expr {[lindex $ws $i] eq "" ? $share : [lindex $ws $i]}]
		set on [expr {$k eq $cur}]
		if {$on} {
			lassign [ui::snap $sx [expr {$y + 3}] $sw 26] px py pw ph
			raster::box $ui::img $px $py $pw $ph -fill [ui::col $c(pill)] -radius 6 -shadow {1 2 0.3}
		}
		set f [expr {$on ? "i13s" : "i13m"}]
		ui::text [expr {$sx + $sw / 2.0}] [ui::lh [expr {$y + 3}] $f 26] $l $f [expr {$on ? $c(fg) : $c(muted)}] c
		ui::hit $sx [expr {$y + 3}] $sw 26 [list apply {{s k x y} { uplevel #0 [list {*}$s $k] }} $script $k]
		set sx [expr {$sx + $sw + 2}]
		incr i
	}
	ui::focusable $id seg $x $y $w 32 9 [list ui::seg_key $opts $cur $script]
}

# A switch's row at Y between X0 and X1.
proc kbdp::switch_row {x0 x1 y label key m {last 0}} {
	set on [expr {[dict get $m $key] eq "yes"}]
	sctl::row $x0 $x1 $y $label $last
	sctl::toggle kbd-$key $x1 $y $on [list inp::put $key [expr {$on ? "no" : "yes"}]]
}

proc settings::draw_keyboard {} {
	array set c [array get ui::c]
	set m [inp::model]
	ui::text 270 34 {Keyboard and mouse} sg28 $c(fg) w -0.56
	ui::text 270 [ui::lh 76 i14 21] [inp::subtitle] i14 $c(muted)

	sctl::label 270 119 Keyboard
	set layouts [inp::layouts]
	sctl::row 270 690 141 Layout
	sctl::dropdown kbd-layout 490 141 200 $layouts [inp::layout_value 1] {inp::set_layout 1}
	sctl::row 270 690 189 {Second layout}
	sctl::dropdown kbd-layout2 490 189 200 [linsert $layouts 0 {{} None}] [inp::layout_value 2] {inp::set_layout 2}
	sctl::row 270 690 237 {Switch layout with}
	sctl::dropdown kbd-switch 490 237 200 [inp::switches] [dict get $m SWITCH] {inp::put SWITCH}
	sctl::row 270 690 285 {Caps Lock is}
	kbdp::seg kbd-caps 450 293 240 {caps {Caps Lock} ctrl Ctrl esc Esc} [dict get $m CAPS] kbdp::caps
	sctl::row 270 690 333 {Repeat after}
	sctl::slider kbd-delay 450 333 166 [expr {([dict get $m REPEAT_DELAY] - 100) / 500.0}] kbdp::delay
	sctl::value 690 333 "[dict get $m REPEAT_DELAY] ms"
	sctl::row 270 690 381 {Repeat speed}
	sctl::slider kbd-rate 450 381 166 [expr {([dict get $m REPEAT_RATE] - 8) / 40.0}] kbdp::rate
	sctl::value 690 381 "[dict get $m REPEAT_RATE] / s"
	kbdp::switch_row 270 690 429 {Num Lock on at login} NUMLOCK $m 1

	ui::box 722 119 1 567 -fill $c(border)

	sctl::label 755 119 Mouse
	sctl::row 755 1060 141 {Pointer speed}
	sctl::slider kbd-mouse-speed 860 141 200 [expr {([dict get $m MOUSE_SPEED] + 1) / 2.0}] {kbdp::speed MOUSE_SPEED}
	kbdp::switch_row 755 1060 189 Acceleration MOUSE_ACCEL $m
	kbdp::switch_row 755 1060 237 {Natural scrolling} MOUSE_NATURAL $m
	kbdp::switch_row 755 1060 285 Left-handed MOUSE_LEFT $m 1

	if {[dict get $m touchpad]} {
		sctl::label 755 357 Touchpad
		sctl::row 755 1060 379 {Pointer speed}
		sctl::slider kbd-touch-speed 860 379 200 [expr {([dict get $m TOUCH_SPEED] + 1) / 2.0}] {kbdp::speed TOUCH_SPEED}
		kbdp::switch_row 755 1060 427 {Tap to click} TOUCH_TAP $m
		kbdp::switch_row 755 1060 475 {Natural scrolling} TOUCH_NATURAL $m
		kbdp::switch_row 755 1060 523 {Off while typing} TOUCH_DWT $m 1
	}
	sctl::overlay
}
