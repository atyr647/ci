# tests/hud-quick/scene.tcl - a quick-menu board's scene drawn by the real overlay helper (ribbon-hud-surface), for
# the comparison with the board (tests/hud-quick/native.sh composites the picture over the board's game and compares).
#   wish8.6 scene.tcl SCENE OUT.png      SCENE: menu (HUD-Quick-1-Menu), volume (-2-Volume), quit (-3-Quit)
# Runs under a compositor with layer-shell. Env: QFAKE (tests/hud-quick/fakes.sh), RIBBON_HUD_SURFACE.
# The HUD is drawn as on the boards (Full, the fixture readings of tests/hud-fixtures, the boards' frame times), the
# menu from the services' stand-ins (the volume 64 %, 70 % for the Volume board; HDR on); power-profiles-daemon is not
# asked here (its row is checked in tests/hud-quick.tcl): its model is set to the board's Balanced.
package require Tk
wm withdraw .
set repo [file dirname [file dirname [file dirname [file normalize [info script]]]]]
set D [file join $repo srcpkgs ribbon-desktop files]
source [file join $D apps hud hud.tcl]
hud::init_modules
source -encoding utf-8 [file join $D apps hud quick.tcl]
lassign $argv scene out
set fx [file join $repo tests hud-fixtures]
hud::theme_load [file join $D themes palettes ribbon.conf]
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/hud-quick-scene-[pid]
hud::draw::init $tmp/cache
hud::art::configure -cache $tmp/cache
hud::data::configure -proc [file join $fx a proc] -sys [file join $fx a sys]
hud::data::sample 0
hud::data::configure -proc [file join $fx b proc] -sys [file join $fx b sys]
hud::data::sample 1000
set ft {}
for {set i 0} {$i < 600} {incr i} { lappend ft [expr {8.9 + 0.5 * sin($i * 1.3) + 0.3 * sin($i * 3.1)}] }
lset ft 562 13.2
lset ft 550 11.6
set ::ft $ft
proc ::poll {} { if {[info exists ::done]} { return [dict create available 1 times {}] }; set ::done 1; dict create available 1 times $::ft }
hud::frames::register fixture ::poll
hud::frames::set_source fixture
hud::frames::poll
set cover [file join $fx quick cover.png]
hud::set_runtime [list pinned 1 name "Cyberpunk 2077" art $cover menu 1]
hud::configure {layout full}

set Q $::env(QFAKE)
set ::env(RIBBON_WPCTL) [file join $Q wpctl]
set ::env(RIBBON_HDR) [file join $Q ribbon-hdr]
set ::env(WLR_RENDERER) vulkan
if {$scene eq "volume"} { set f [open $Q/vol w]; puts $f 0.70; close $f }

proc waitfor {cond {ms 5000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 [list expr $cond]] && [clock milliseconds] < $end} { after 20 [list set ::tick 1]; vwait ::tick }
	uplevel #0 [list expr $cond]
}
set ::events {}
proc ev {line} { lappend ::events $line }
if {![hud::surface::start -event ev]} { puts stderr "no surface: $::hud::surface::error"; exit 2 }
lassign [hud::surface::size] W H

hud::quick::set_layout full
hud::quick::open win1 "Cyberpunk 2077" $cover [expr {[clock milliseconds] - 77 * 60000 - 5000}]
set ::hud::quick::profiles {power-saver balanced performance}
set ::hud::quick::profile balanced
waitfor {$::hud::quick::volume ne "" && $::hud::quick::hdr eq "on"}
switch -- $scene {
	volume { while {$::hud::quick::focus ne "vol"} { hud::quick::key 108 } }
	quit { while {$::hud::quick::focus ne "quit"} { hud::quick::key 108 }; hud::quick::key 28 }
}
# the art is made by ffmpeg in the background
waitfor {[hud::art::png $cover 28 7 1] ne ""}
lassign [hud::quick::ops $W $H 1] under over
set n [llength $::events]
hud::surface::show [concat $under [hud::ops $W $H 1] $over]
waitfor {[lsearch -glob [lrange $::events $n end] mapped*] >= 0}
set n [llength $::events]
hud::surface::put_line "snapshot $out"
waitfor {[lsearch -exact [lrange $::events $n end] snapshot] >= 0}
hud::surface::stop
file delete -force $tmp
puts "ready $W $H"
exit 0
