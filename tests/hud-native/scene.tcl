# tests/hud-native/scene.tcl - the HUD scenes of the boards through the native surface and through the Tk canvas, so
# the two drawings can be compared (run.sh does).
#   wish8.6 scene.tcl native SCENE OUT.png     (under the compositor: ribbon-hud-surface draws, "snapshot" writes the PNG)
#   wish8.6 scene.tcl canvas SCENE OUT.png     (any X display: hud::paint draws on a 1440 x 900 black canvas, grabbed to OUT.png)
#   wish8.6 scene.tcl live SCENE               (native, stays up: for screenshots of the surface over a game)
# SCENE: default (Full, pinned, "Cyberpunk 2077" with its art, the board's numbers), compact, fps, nofr (no frame
# data), menu (quick menu open). The numbers are the fixture readings of tests/hud-fixtures and the board's frame times.
package require Tk
wm withdraw .
set repo [file dirname [file dirname [file dirname [file normalize [info script]]]]]
source [file join $repo srcpkgs/ribbon-desktop/files/apps/hud/hud.tcl]
hud::init_modules
lassign $argv mode scene out
set fx [file join $repo tests hud-fixtures]
hud::theme_load [file join $repo srcpkgs ribbon-desktop files themes palettes ribbon.conf]
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/hud-scene-[pid]
hud::draw::init $tmp/cache
hud::art::configure -cache $tmp/cache
hud::data::configure -proc [file join $fx a proc] -sys [file join $fx a sys]
hud::data::sample 0
hud::data::configure -proc [file join $fx b proc] -sys [file join $fx b sys]
hud::data::sample 1000
if {$scene ne "nofr"} {
	set ft {}
	for {set i 0} {$i < 600} {incr i} { lappend ft [expr {8.9 + 0.5 * sin($i * 1.3) + 0.3 * sin($i * 3.1)}] }
	lset ft 562 13.2
	lset ft 550 11.6
	foreach i {3 77 150 233 301 366 410 488} { lset ft $i 11.9 }
	set ::ft $ft
	proc ::poll {} { if {[info exists ::done]} { return [dict create available 1 times {}] }; set ::done 1; dict create available 1 times $::ft }
	hud::frames::register fixture ::poll
	hud::frames::set_source fixture
	hud::frames::poll
}
# the board's cover art, as Steam keeps a game's icon (tests/hud-fixtures/art-home)
hud::set_runtime [list pinned 1 name "Cyberpunk 2077" art [file join $fx art-home .local share Steam appcache librarycache 620_icon.jpg]]
switch -- $scene {
	compact { hud::configure {layout compact} }
	fps { hud::configure {layout fps} }
	menu { hud::set_runtime {menu 1} }
}
set W 1440; set H 900
# the art is made (ffmpeg, in the background) before the picture is taken
hud::ops $W $H 1
if {![hud::art::settle 8000]} { puts "the art was not made"; exit 1 }
if {$mode eq "canvas"} {
	canvas .c -width $W -height $H -background black -highlightthickness 0
	pack .c
	wm geometry . +0+0
	wm deiconify .
	hud::paint .c $W $H
	update
	after 400 { set ::go 1 }
	vwait ::go
	update
	exec import -window [winfo id .c] $out
	puts "canvas $out"
	exit 0
}
if {![hud::surface::start]} { puts "no surface: $::hud::surface::error"; exit 1 }
lassign [hud::surface::size] sw sh
if {$sw != $W} { puts "output is ${sw}x${sh}, not ${W}x${H}"; exit 1 }
hud::surface::show [hud::ops $W $H 1]
if {$mode eq "live"} { puts ready; vwait forever }
after 600 { set ::go 1 }
vwait ::go
hud::surface::put_line "snapshot $out"
after 400 { set ::go 2 }
vwait ::go
set fh [::open $out.box w]; puts $fh $::hud::surface::mapped; ::close $fh
hud::surface::stop
puts "snapshot $out"
exit 0
