# settings-keyboard-scene.tcl - Settings → Keyboard and mouse (page-keyboard.tcl) in its board's state
# (Settings-A7-Keyboard-Mouse), with input.tcl stood in for (the page's drawing and its hits are what is checked
# here; input.tcl itself is tests/settings-input.tcl). Sourced by apps/settings/main.tcl through RIBBON_SETTINGS_SCENE.
#   RIBBON_KBD_SHOT   = file: a grab of the window (ImageMagick import)
#   RIBBON_KBD_RESULT = file: the checks, one per line ("ok ..." or "FAIL ...")
proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }
set ui::caretfix off
namespace eval kscene { variable fails 0; variable lines {}; variable calls {} }
proc kscene::check {what cond} { variable fails; variable lines; if {[uplevel #0 [list expr $cond]]} { lappend lines "ok   $what" } else { lappend lines "FAIL $what ([lindex $::kscene::calls end])"; incr fails } }
proc kscene::click {x y} { page::draw_now; ui::press [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; ui::release [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; update }
proc kscene::last {} { lindex $::kscene::calls end }

# the board's state
set kscene::M [dict create LAYOUT us VARIANT {} LAYOUT2 {} VARIANT2 {} SWITCH win_space CAPS caps \
	REPEAT_DELAY 300 REPEAT_RATE 30 NUMLOCK yes \
	MOUSE_SPEED 0.00 MOUSE_ACCEL yes MOUSE_NATURAL no MOUSE_LEFT no \
	TOUCH_SPEED 0.24 TOUCH_TAP yes TOUCH_NATURAL yes TOUCH_DWT yes touchpad 1]
set kscene::L {{us(dvorak) {English (Dvorak)}} {gb {English (UK)}} {us {English (US)}} {fr French} {de German} {de(neo) {German (Neo 2)}}}
set kscene::refuse 0
proc inp::model {} { return $::kscene::M }
proc inp::layouts {} { return $::kscene::L }
proc inp::switches {} { return {{win_space {Super Space}} {alt_shift {Alt Shift}} {ctrl_shift {Ctrl Shift}} {alt_space {Alt Space}} {shifts {Both Shift keys}}} }
proc inp::layout_value {n} {
	set l [dict get $::kscene::M LAYOUT[expr {$n == 2 ? 2 : ""}]]; set v [dict get $::kscene::M VARIANT[expr {$n == 2 ? 2 : ""}]]
	expr {$v ne "" ? "$l\($v\)" : $l}
}
proc inp::subtitle {} { foreach it $::kscene::L { if {[lindex $it 0] eq [inp::layout_value 1]} { return "[lindex $it 1] · mouse[expr {[dict get $::kscene::M touchpad] ? ", touchpad" : ""}]" } } }
proc inp::put {k v} {
	lappend ::kscene::calls [list put $k $v]
	if {$::kscene::refuse} { return 0 }
	dict set ::kscene::M $k $v
	return 1
}
proc inp::set_layout {n value} {
	lappend ::kscene::calls [list layout $n $value]
	if {$::kscene::refuse} { return 0 }
	set l $value; set v ""
	regexp {^([^()]*)\(([^()]*)\)$} $value -> l v
	dict set ::kscene::M LAYOUT[expr {$n == 2 ? 2 : ""}] $l; dict set ::kscene::M VARIANT[expr {$n == 2 ? 2 : ""}] $v
	return 1
}

settings::select keyboard
page::draw_now
update
if {[info exists ::env(RIBBON_KBD_SHOT)]} { after 500; update; exec import -window [winfo id $::settings::win] $::env(RIBBON_KBD_SHOT) }

# ---- every control, as clicks (window coordinates)
# Layout: its list opens under it (six rows of 36 from 193); the fifth is German
kscene::click 590 165
kscene::check "a click on Layout opens its list" {$sctl::pop eq "kbd-layout"}
if {[info exists ::env(RIBBON_KBD_SHOT)]} { page::draw_now; update; after 300; update; exec import -window [winfo id $::settings::win] [file rootname $::env(RIBBON_KBD_SHOT)]-list.png }
kscene::click 590 [expr {193 + 36 * 4 + 18}]
kscene::check "  a click on German makes it the layout" {[kscene::last] eq {layout 1 de} && $sctl::pop eq ""}
kscene::click 590 165
settings::key e e 0; settings::key n n 0
settings::key Down {} 0
settings::key Return {} 0
kscene::check "  typed letters jump (en: English (Dvorak)), Down and Return pick the next (English (UK))" {[kscene::last] eq {layout 1 gb}}
kscene::click 590 165
settings::key Escape {} 0
kscene::check "  Escape closes the list and changes nothing" {$sctl::pop eq "" && [kscene::last] eq {layout 1 gb}}
kscene::click 590 165
kscene::click 590 [expr {193 + 18}]
kscene::check "  a variant is picked with its layout (English (Dvorak))" {[kscene::last] eq {layout 1 us(dvorak)}}
# Second layout: None first, then the layouts
kscene::click 590 213
kscene::check "a click on Second layout opens its list" {$sctl::pop eq "kbd-layout2"}
kscene::click 590 [expr {241 + 36 * 6 + 18}]
kscene::check "  a click on German (Neo 2) makes it the second layout" {[kscene::last] eq {layout 2 de(neo)}}
kscene::click 590 213
kscene::click 590 [expr {241 + 18}]
kscene::check "  None takes the second layout away" {[kscene::last] eq {layout 2 {}}}
# Switch layout with
kscene::click 590 261
kscene::click 590 [expr {289 + 36 + 18}]
kscene::check "Switch layout with: Alt Shift" {[kscene::last] eq {put SWITCH alt_shift}}
# Caps Lock is
kscene::click 580 309
kscene::check "Caps Lock is: Ctrl" {[kscene::last] eq {put CAPS ctrl}}
kscene::click 652 309
kscene::check "Caps Lock is: Esc" {[kscene::last] eq {put CAPS esc}}
kscene::click 498 309
kscene::check "Caps Lock is: Caps Lock" {[kscene::last] eq {put CAPS caps}}
# the sliders
kscene::click 450 357
kscene::check "Repeat after: the left end is 100 ms" {[kscene::last] eq {put REPEAT_DELAY 100}}
kscene::click 616 357
kscene::check "Repeat after: the right end is 600 ms" {[kscene::last] eq {put REPEAT_DELAY 600}}
kscene::click 533 357
kscene::check "Repeat after: the middle is 350 ms" {[kscene::last] eq {put REPEAT_DELAY 350}}
kscene::click 450 405
kscene::check "Repeat speed: the left end is 8 a second" {[kscene::last] eq {put REPEAT_RATE 8}}
kscene::click 616 405
kscene::check "Repeat speed: the right end is 48 a second" {[kscene::last] eq {put REPEAT_RATE 48}}
kscene::click 671 453
kscene::check "Num Lock on at login turns off" {[kscene::last] eq {put NUMLOCK no}}
kscene::click 671 453
kscene::check "  and on again" {[kscene::last] eq {put NUMLOCK yes}}
# the mouse
kscene::click 860 165
kscene::check "the mouse's Pointer speed: the left end is -1" {[kscene::last] eq {put MOUSE_SPEED -1.00}}
kscene::click 1060 165
kscene::check "  the right end is 1" {[kscene::last] eq {put MOUSE_SPEED 1.00}}
kscene::click 960 165
kscene::check "  the middle is 0" {[kscene::last] eq {put MOUSE_SPEED 0.00}}
kscene::click 1041 213
kscene::check "Acceleration turns off" {[kscene::last] eq {put MOUSE_ACCEL no}}
kscene::click 1041 261
kscene::check "the mouse's Natural scrolling turns on" {[kscene::last] eq {put MOUSE_NATURAL yes}}
kscene::click 1041 309
kscene::check "Left-handed turns on" {[kscene::last] eq {put MOUSE_LEFT yes}}
# the touchpad
kscene::click 1010 403
kscene::check "the touchpad's Pointer speed: three quarters along is 0.5" {[kscene::last] eq {put TOUCH_SPEED 0.50}}
kscene::click 1041 451
kscene::check "Tap to click turns off" {[kscene::last] eq {put TOUCH_TAP no}}
kscene::click 1041 499
kscene::check "the touchpad's Natural scrolling turns off" {[kscene::last] eq {put TOUCH_NATURAL no}}
kscene::click 1041 547
kscene::check "Off while typing turns off" {[kscene::last] eq {put TOUCH_DWT no}}
# the keyboard: Left on the focused Repeat after slider is 10 ms less
set ui::focus kbd-delay
page::draw_now
settings::key Left {} 0
kscene::check "Left on the Repeat after slider is one step (10 ms) less" {[kscene::last] eq {put REPEAT_DELAY 340}}
# a change the backend refuses leaves the row as it was
set kscene::refuse 1
set before [dict get $kscene::M MOUSE_LEFT]
kscene::click 1041 309
kscene::check "a refused change is asked for and the row stays" {[kscene::last] eq {put MOUSE_LEFT no} && [dict get $kscene::M MOUSE_LEFT] eq $before}
set kscene::refuse 0
# no touchpad: no Touchpad block, and nothing to press where it was
dict set kscene::M touchpad 0
set n [llength $kscene::calls]
kscene::click 1041 451; kscene::click 1010 403; kscene::click 1041 547
kscene::check "with no touchpad its block is not there (clicks where it was do nothing)" {[llength $kscene::calls] == $n}
kscene::click 1041 213
kscene::check "  and the mouse's rows still are" {[kscene::last] eq {put MOUSE_ACCEL yes}}
if {[info exists ::env(RIBBON_KBD_SHOT)]} { page::draw_now; update; after 300; update; exec import -window [winfo id $::settings::win] [file rootname $::env(RIBBON_KBD_SHOT)]-notouch.png }

if {[info exists ::env(RIBBON_KBD_RESULT)]} { set f [open $::env(RIBBON_KBD_RESULT) w]; puts $f [join $kscene::lines \n]; close $f } else { puts [join $kscene::lines \n] }
exit [expr {$kscene::fails > 0}]
