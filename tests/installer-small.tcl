# installer-small.tcl - the installer on the screen it runs on (main.tcl with
# RIBBON_INSTALLER_SCENE=this file, under xvfb at 1440x900, 1366x768 or
# 1280x800; tests/test-installer-small-screens.sh):
#   - the window: 1100 x 720 at 170, 104 on 1440 x 900; under 828 px high the
#     compact 1100 x 640 of the Inst-C* boards, centred between the top bars
#     and the dock (labwc's 54 px margins), its footer and Continue inside;
#   - every page in the mockups' states: nothing in the page column reaches
#     the footer (texts, hits and Tab stops end 16 px above its line);
#   - Hardware on a machine with fourteen devices: the drivers list scrolls
#     (wheel, Up/Down on it) instead of running under the footer, and the
#     last device's toggle can be reached and works.
# Prints "  ok ..." / "  FAIL ..." lines; exits 1 on a failure.
set ::env(RIBBON_SCENE) welcome
uplevel #0 [list source -encoding utf-8 [file join [file dirname [file normalize [info script]]] installer-scene.tcl]]
set fails 0
proc ok {m} { puts "  ok   $m" }
proc bad {m} { incr ::fails; puts "  FAIL $m" }
proc check {cond m} { if {[uplevel 1 [list expr $cond]]} { ok $m } else { bad $m } }

set SW [winfo screenwidth .]; set SH [winfo screenheight .]
set small [expr {$SH < 828}]
set H $ui::H
check {$H == ($small ? 640 : 720)} "${SW}x$SH: the window is 1100 x $H ([expr {$small ? "compact, Inst-C*" : "Inst-*"}])"
lassign [app::place $SW $SH] wx wy
if {$small} {
	check {$wx == ($SW - 1100) / 2 && $wy == ($SH - 640) / 2} "it is centred between the bars and the dock: $wx, $wy"
} else {
	check {$SW != 1440 || ($wx == 170 && $wy == 104)} "it is where the boards put it: $wx, $wy"
}
check {$wy >= 54 && $wy + $H <= $SH - 54} "it clears the top bars and the dock (labwc's margins): $wy to [expr {$wy + $H}] of $SH"
check {$page::FL == $H - 72 + ($small ? 8 : 0)} "the footer's line is at $page::FL ([expr {$H - $page::FL}] px footer)"

# the page column's content must end clear of the footer's line
proc body_clear {what} {
	set FL $page::FL
	set worst -1e9; set who ""
	foreach h $ui::hits {
		lassign $h x0 y0 x1 y1
		if {$x0 >= 250 && $y0 < $FL && $y1 - $y0 < 600 && $y1 > $worst} { set worst $y1; set who "a hit at $x0,$y0" }
	}
	foreach f $ui::focusables {
		lassign $f id kind x y w h
		if {$x >= 250 && $y < $FL && $y + $h > $worst} { set worst [expr {$y + $h}]; set who "Tab stop $id" }
	}
	foreach i [$ui::cv find withtag page] {
		if {[$ui::cv type $i] ne "text"} continue
		lassign [$ui::cv bbox $i] x0 y0 x1 y1
		set x0 [expr {$x0 - $ui::ox}]; set y0 [expr {$y0 - $ui::oy}]; set y1 [expr {$y1 - $ui::oy}]
		if {$x0 >= 250 && $y0 < $FL && $y1 > $worst} { set worst $y1; set who "\"[$ui::cv itemcget $i -text]\"" }
	}
	if {$worst <= $FL - 16} { ok "$what: the page ends at [expr {round($worst)}], clear of the footer at $FL" } else { bad "$what: $who reaches [expr {round($worst)}], the footer's line is at $FL" }
}
proc footer_in {what} {
	set b ""
	foreach f $ui::focusables { if {[lindex $f 0] in {continue close restart}} { set b $f } }
	if {$b eq ""} { bad "$what: no Continue"; return }
	lassign $b id kind x y w h
	set bottom [expr {$::wy + $y + $h}]
	check {$y > $page::FL && $bottom <= $::SH - 54} "$what: $id is in the footer and on screen above the dock (its foot at $bottom of $::SH)"
}

# every page as the boards show it
foreach {scene setup} {
	welcome {}
	keyboard { set page::S(layout) 1; ui::fset tzq lond; page::tz_changed; ui::fset keytest {£ @ " #} }
	disk {}
	alongside { set page::S(mode) alongside; page::set_keep 520000000000 }
	manual { set page::S(mode) manual }
	setup { ui::fset pass1 correcthorse }
	hardware { set page::S(swap) custom; ui::fset swapgb 24 }
	apps {}
	you scene_user
	summary scene_user
	progress { scene_user; set page::S(pct) 62; set page::S(stepname) "Copying Ribbon"; set page::S(log) [lrepeat 30 {==> a line}] }
	done {}
} {
	eval $setup
	set page::S(page) $scene
	page::draw_now
	update
	body_clear $scene
	if {$scene in {welcome hardware summary}} { footer_in $scene }
}

# a laptop that finds fourteen devices
set many {}
foreach {cat dev} {Graphics {Intel Iris Xe} Graphics {NVIDIA GeForce RTX 3050 Laptop} Wi-Fi {Intel AX211} Ethernet {Realtek RTL8111}
	Processor {Intel Core i7-12700H} Audio {Intel Smart Sound} Bluetooth {Intel AX211} {Fingerprint reader} {Goodix 27c6:63ac}
	Webcam {Integrated Camera} Thunderbolt {Intel Thunderbolt 4} Touchpad {ELAN 0672} Sensors {Intel ISH} Storage {Samsung PM9A1} Firmware {LVFS}} {
	set id d[llength $many]
	if {$dev eq "NVIDIA GeForce RTX 3050 Laptop"} {
		lappend many [list id $id category $cat device $dev ids {} driver "NVIDIA, proprietary (latest)" status install \
			choices {{latest Latest} {580 "580 series"} {nouveau Nouveau}} default latest]
	} elseif {$cat in {Wi-Fi Audio Fingerprint\ reader Thunderbolt}} {
		lappend many [list id $id category $cat device $dev ids {} driver "$cat driver" status install choices {} default {}]
	} else {
		lappend many [list id $id category $cat device $dev ids {} driver "in the kernel" status builtin choices {} default {}]
	}
}
dict set page::probe drivers $many
set page::S(drivers) {}
foreach d $many { if {[dict get $d status] eq "install"} { dict set page::S(drivers) [dict get $d id] [dict get $d default] } }
set page::S(swap) zram
set page::S(drvtop) 0
set page::S(page) hardware
set ui::focus ""
page::draw_now; update
body_clear "Hardware with 14 devices"
set ids [lmap f $ui::focusables { lindex $f 0 }]
check {"drivers" in $ids} "the drivers list is a Tab stop that scrolls"
check {"drv-d9" ni $ids} "the devices that do not fit are not drawn under the footer"
footer_in "Hardware with 14 devices"
# the wheel over the list
set lst [lsearch -inline -index 0 $ui::focusables drivers]
lassign $lst - - lx ly lw lh
ui::scroll [expr {$ui::ox + $lx + 100}] [expr {$ui::oy + $ly + 20}] 1
page::draw_now; update
check {$page::S(drvtop) == 1} "the wheel scrolls the list a row"
# Up/Down with the list focused, to the end
set ui::focus drivers
for {set k 0} {$k < 20} {incr k} { page::key Down "" 0 }
page::draw_now; update
set ids [lmap f $ui::focusables { lindex $f 0 }]
check {"drv-d9" in $ids} "at the end of the list the last device's toggle (Thunderbolt) is reachable"
body_clear "Hardware scrolled to the end"
set tb [lsearch -inline -index 0 $ui::focusables drv-d9]
lassign $tb - - tx ty tw th
ui::press [expr {$ui::ox + $tx + 10}] [expr {$ui::oy + $ty + 10}]
catch {ui::release [expr {$ui::ox + $tx + 10}] [expr {$ui::oy + $ty + 10}]}
update
check {![dict exists $page::S(drivers) d9]} "its toggle works: Thunderbolt is skipped"
page::key Prior "" 0
page::draw_now; update
check {$page::S(drvtop) < 3} "Page Up goes back up the list (top $page::S(drvtop))"

update
exit [expr {$fails ? 1 : 0}]
