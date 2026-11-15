# tests/hud-draw.tcl - the Game HUD's layout and drawing, under Tk (wish8.6, under xvfb).
# The geometry of each layout is checked against the boards (HUD-Default, HUD-Layouts, HUD-Corners, HUD-Toggle,
# HUD-NoFrames: design/mockups/*.dc.html). With HUD_SHOTS set to a directory, the scenes are also grabbed there.
package require Tk
set repo [file dirname [file dirname [file normalize [info script]]]]
source [file join $repo srcpkgs/ribbon-desktop/files/apps/hud/hud.tcl]
hud::init_modules

set fails 0
proc check {name got want} {
	global fails
	if {$got eq $want} { return }
	puts "  FAIL $name: got {$got}, want {$want}"
	incr fails
}
proc near {name got want {tol 0.6}} {
	global fails
	if {abs($got - $want) <= $tol} { return }
	puts "  FAIL $name: got $got, want $want"
	incr fails
}

set fx [file join $repo tests hud-fixtures]
hud::theme_load [file join $repo srcpkgs ribbon-desktop files themes palettes ribbon.conf]
set tmp [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] hud-draw-[pid]]
hud::draw::init [file join $tmp cache]

# the readings of the b snapshot, and the frame source (the board's numbers: 112 FPS, 8.9 ms, 1 % low 84)
hud::data::configure -proc [file join $fx a proc] -sys [file join $fx a sys]
hud::data::sample 0
hud::data::configure -proc [file join $fx b proc] -sys [file join $fx b sys]
hud::data::sample 1000
set ft {}
for {set i 0} {$i < 600} {incr i} { lappend ft [expr {8.9 + 0.5 * sin($i * 1.3) + 0.3 * sin($i * 3.1)}] }
lset ft 562 13.2
lset ft 550 11.6
foreach i {3 77 150 233 301 366 410 488} { lset ft $i 11.9 }
set ::fixture_ft $ft
proc ::fixture_poll {} {
	if {[info exists ::fixture_done]} { return [dict create available 1 times {}] }
	set ::fixture_done 1
	return [dict create available 1 times $::fixture_ft]
}
hud::frames::register fixture ::fixture_poll
hud::frames::set_source fixture
hud::frames::poll

# a view of the HUD: the default settings with overrides, on a W x H screen
proc view {W H args} {
	global fx
	set v [hud::view $W $H]
	foreach {k val} $args { dict set v $k $val }
	return $v
}
proc ops_of {args} {
	return [hud::draw::ops [view {*}$args]]
}
# the ops of one kind whose width is W (the panel) or any
proc find {ops kind args} {
	set out {}
	foreach op $ops {
		if {[lindex $op 0] ne $kind} continue
		set ok 1
		foreach {k v} $args {
			switch -- $k {
				x { if {[lindex $op 1] != $v} { set ok 0 } }
				y { if {[lindex $op 2] != $v} { set ok 0 } }
				w { if {[lindex $op 3] != $v} { set ok 0 } }
				h { if {[lindex $op 4] != $v} { set ok 0 } }
			}
		}
		if {$ok} { lappend out $op }
	}
	return $out
}

# --- Full panel on the default screen (HUD-Default): 236 wide, top right, 24 px from the edges, 383 tall
set ops [ops_of 1440 900 layout full]
set panel [find $ops rrect]
check "full: a panel" [expr {[llength $panel] > 0}] 1
set p [lindex $panel 0]
check "full: panel x (1440 - 24 - 236)" [lindex $p 1] 1180
check "full: panel y" [lindex $p 2] 24
check "full: panel width" [lindex $p 3] 236
check "full: panel height (board: 24 to 407)" [lindex $p 4] 383
near "full: panel radius" [lindex $p 5] 14 0.01
check "full: glass is the bar colour at 86 % over black" [lindex $p 6] [hud::draw::mix #1D1C1B #000000 0.86]
check "full: shadow 0 12 40 at 50 %" [lindex $p 8] {12 20 0.5 #000000}

# the header rule at 49.5 (the board's rule at 73), the FPS block at 62, the graph at 103..137, the rows from 141
set lines [find $ops line]
near "full: header rule y (24 + 49.5; the board has it at 73)" [lindex [lindex $lines end] 2] 73.5 0.1
check "full: six rows, five rules" [llength [find $ops rect h 1]] 5
set meters [find $ops rect h 3]
check "full: four meters (GPU, VRAM, CPU, Memory)" [llength $meters] 8
near "full: GPU meter y (24 + 141 + 30)" [lindex [lindex $meters 1] 2] 195
near "full: GPU meter width 97 %" [lindex [lindex $meters 1] 3] [expr {204*0.97}] 0.01
near "full: VRAM meter width 67 %" [lindex [lindex $meters 3] 3] [expr {204*0.67}] 0.01
set plines [find $ops pline]
check "full: graph polyline has 60 points" [llength [lindex [lindex $plines end] 1]] 120
check "full: graph line is 1.3 px" [lindex [lindex $plines end] 2] 1.3

# --- Compact (HUD-Layouts, middle): the same panel without header and rows: 101 tall
set ops [ops_of 476 900 layout compact]
set p [lindex [find $ops rrect] 0]
check "compact: panel height (board: 24 to 125)" [lindex $p 4] 101
check "compact: panel x in a 476 column" [lindex $p 1] [expr {476-24-236}]

# --- FPS pill (HUD-Layouts, left): 40 tall, 12 radius, the top-right corner, 24 px from the edges
set ops [ops_of 476 900 layout fps]
set p [lindex [find $ops rrect] 0]
check "fps: pill height" [lindex $p 4] 40
near "fps: pill radius" [lindex $p 5] 12 0.01
check "fps: pill top" [lindex $p 2] 24
check "fps: pill right edge at 452" [expr {[lindex $p 1] + [lindex $p 3]}] 452

# --- No frame data (HUD-NoFrames): the same panel and rows, dashes; the graph has a dashed baseline
set frames_on [ops_of 1440 900 layout full]
set frames_off [ops_of 1440 900 layout full frames [dict create ok 0 fps "" ft "" low "" series {}]]
check "no frames: panel is the same" [find $frames_off rrect] [find $frames_on rrect]
check "no frames: the rules and meters are the same" [find $frames_off rect] [find $frames_on rect]
check "no frames: a dashed baseline" [llength [find $frames_off line]] [expr {[llength [find $frames_on line]] + 1}]
check "no frames: the graph polyline is gone (60 points)" [llength [lmap p [find $frames_off pline] {expr {[llength [lindex $p 1]] == 120 ? 1 : [continue]}}]] 0
check "frames: the graph polyline is there (60 points)" [llength [lmap p [find $frames_on pline] {expr {[llength [lindex $p 1]] == 120 ? 1 : [continue]}}]] 1
set texts {}
foreach op [find $frames_off text] { lappend texts [lindex $op 7] }
check "no frames: dash for the number" [expr {"–" in $texts}] 1
check "no frames: No frame data" [expr {"No frame data" in $texts}] 1
check "no frames: dashes for frame time" [expr {"– ms" in $texts}] 1
set compact_on [ops_of 476 900 layout compact]
set compact_off [ops_of 476 900 layout compact frames [dict create ok 0 fps "" ft "" low "" series {}]]
check "no frames compact: same panel" [find $compact_off rrect] [find $compact_on rrect]
set fps_off [ops_of 476 900 layout fps frames [dict create ok 0 fps "" ft "" low "" series {}]]
check "no frames fps: same height" [lindex [find $fps_off rrect] 0 4] 40
check "no frames fps: same right edge" [expr {[lindex [find $fps_off rrect] 0 1] + [lindex [find $fps_off rrect] 0 3]}] 452

# --- Corners (HUD-Corners): each corner keeps 24 px; the panel's anchored corner stays put at scale 100
foreach {pos x y} {top-left 24 24 top-right 1180 24 bottom-left 24 493 bottom-right 1180 493} {
	set p [lindex [find [ops_of 1440 900 layout full pos $pos] rrect] 0]
	check "corner $pos x" [lindex $p 1] $x
	check "corner $pos y" [lindex $p 2] $y
}

# --- Sizes: the panel grows about its anchored corner (top-right stays at the margin)
set p [lindex [find [ops_of 1440 900 layout full scale 150] rrect] 0]
check "scale 150: width" [lindex $p 3] 354
check "scale 150: right edge stays 24 px from the screen edge" [expr {[lindex $p 1] + [lindex $p 3]}] 1416
check "scale 150: height" [lindex $p 4] 575
set p [lindex [find [ops_of 1440 900 layout full scale 90] rrect] 0]
check "scale 90: width" [lindex $p 3] 212
near "scale 90: rounded corners scale" [lindex $p 5] 12.6 0.01

# --- Quick menu open (HUD-Toggle): the HUD moves to right: 358 px
set p [lindex [find [ops_of 1440 900 layout full menu 1] rrect] 0]
check "menu open: right edge at 1440 - 358" [expr {[lindex $p 1] + [lindex $p 3]}] 1082

# --- pin and the optional rows
set pinned [ops_of 1440 900 layout full pinned 1]
check "pinned: a pin background at x 1350, y 38" [llength [find $pinned rrect x 1350 y 38]] 1
set rows_all [ops_of 1440 900 layout full contents {frametime low graph game gpu vram cpu mem power net disk clock}]
check "all contents: eight rows, seven rules" [llength [find $rows_all rect h 1]] 7
set named [ops_of 1440 900 layout full name "Cyberpunk 2077"]
set texts {}
foreach op [find $named text] { lappend texts [lindex $op 7] }
check "name in the header" [expr {"Cyberpunk 2077" in $texts}] 1

# --- the palette and the whole paint: a canvas gets the HUD's items, and a second paint replaces them
set c .hud
canvas $c -width 1440 -height 900 -background #000000
pack $c
update
set pops [ops_of 1440 900 layout full]
hud::draw::paint $c $pops
set n [llength [$c find withtag hud]]
# one canvas item per drawn op; the "hit" ops (the buttons' boxes, for the native surface's input region) draw nothing
set hits [llength [lsearch -all -index 0 $pops hit]]
check "paint: one canvas item per drawn op" $n [expr {[llength $pops] - $hits}]
check "full layout carries the pin and close boxes" [lmap h [lsearch -all -inline -index 0 $pops hit] {lindex $h 1}] {pin close}
hud::draw::paint $c $pops
check "paint: a second paint replaces the first" [llength [$c find withtag hud]] $n
check "paint: layout off draws nothing" [llength [ops_of 1440 900 layout off]] 0
destroy $c

# --- the game's art in the header (HUD-Default: a 20 px rounded square at 16,16 of the panel, with a 1 px inset ring
# of white at 8 %): the launcher's picture through ffmpeg (Steam's art is JPEG), the pill until it is made or without one
proc settle_art {} { hud::art::settle 8000 }
set ah [file join $fx art-home]
hud::art::configure -home $ah -cache [file join $tmp artcache]
set lc [file join $ah .local share Steam appcache librarycache]
check "art: Steam's icon (APPID_icon.jpg)" [hud::art::for_key steam:620] [file join $lc 620_icon.jpg]
check "art: the newer per-app folder's icon (APPID/<sha1>.jpg) before its header" [hud::art::for_key steam:1091500] \
	[file join $lc 1091500 2b1e8e9c7d0e4f1a3b5c6d7e8f9a0b1c2d3e4f5a.jpg]
check "art: the header when there is no icon" [hud::art::for_key steam:400] [file join $lc 400_header.jpg]
check "art: Lutris's icon" [hud::art::for_key lutris:celeste] [file join $ah .local share icons hicolor 128x128 apps lutris_celeste.png]
check "art: a game with no picture" [hud::art::for_key steam:999] ""
check "art: no key" [hud::art::for_key ""] ""
set art620 [hud::art::for_key steam:620]
set ::art_done 0
hud::art::configure -done {incr ::art_done}
set a0 [ops_of 1440 900 layout full name "Portal 2" art $art620]
set px [expr {1440 - 24 - 236}]
check "art: the pill stands in while the picture is made" [llength [find $a0 rrect x [expr {$px + 16}] y 40 w 20 h 20]] 1
check "art: no image op yet" [llength [find $a0 image]] 0
check "art: it is made in the background" [settle_art] 1
check "art: the done command ran (the daemon redraws then)" $::art_done 1
set a1 [ops_of 1440 900 layout full name "Portal 2" art $art620]
set im [find $a1 image]
check "art: an image op at the board's place and size (16,16 of the panel, 20 px)" [lrange [lindex $im 0] 1 4] [list [expr {$px + 16}] 40 20 20]
check "art: the pill is gone" [llength [find $a1 rrect x [expr {$px + 16}] y 40 w 20 h 20]] 0
set png [lindex $im 0 5]
check "art: a PNG in the cache" [list [file extension $png] [file isfile $png]] {.png 1}
set ph [image create photo -file $png]
check "art: 20 x 20 px" [list [image width $ph] [image height $ph]] {20 20}
check "art: the rounded corner is transparent" [$ph transparency get 0 0] 1
check "art: inside the corner it is opaque" [$ph transparency get 10 10] 0
# the centre is the picture's (the cover's sky, #f2e45c, JPEG-near); the edge is lighter by the 8 % ring
lassign [$ph get 10 3] r g b
check "art: the picture's own colour inside" [expr {abs($r - 0xf2) < 12 && abs($g - 0xe4) < 12 && abs($b - 0x5c) < 16}] 1
lassign [$ph get 10 0] r0 g0 b0
check "art: the 1 px ring at the edge is the picture lightened by white at 8 % (blue $b0 over $b)" \
	[expr {$b0 - $b >= 10 && $b0 - $b <= 22}] 1
image delete $ph
set a2 [ops_of 1440 900 layout full scale 150 name "Portal 2" art $art620]
check "art at 150 %: the pill first (another size)" [llength [find $a2 image]] 0
settle_art
set im2 [lindex [find [ops_of 1440 900 layout full scale 150 name "Portal 2" art $art620] image] 0]
check "art at 150 %: 30 px, made at that size (not scaled when drawn)" [lrange $im2 3 4] {30 30}
set ph [image create photo -file [lindex $im2 5]]
check "art at 150 %: the PNG is 30 px" [image width $ph] 30
image delete $ph
# a wide header: the centre square of it (green), not the whole picture squeezed
ops_of 1440 900 layout full art [hud::art::for_key steam:400]; settle_art
set ph [image create photo -file [lindex [find [ops_of 1440 900 layout full art [hud::art::for_key steam:400]] image] 0 5]]
lassign [$ph get 2 10] r g b
check "art: a wide header is centre-cropped (green at the left edge: $r $g $b)" [expr {$g > 150 && $r < 90 && $b < 110}] 1
image delete $ph
# a PNG with its own alpha (Lutris): kept
ops_of 1440 900 layout full art [hud::art::for_key lutris:celeste]; settle_art
check "art: Lutris's PNG icon" [llength [find [ops_of 1440 900 layout full art [hud::art::for_key lutris:celeste]] image]] 1
# a file ffmpeg cannot read, and no ffmpeg: the pill, and no second try
set bad [file join $lc 70_icon.jpg]
ops_of 1440 900 layout full art $bad; settle_art
set b1 [ops_of 1440 900 layout full art $bad]
check "art: a picture that cannot be read keeps the pill" [list [llength [find $b1 image]] [llength [find $b1 rrect x [expr {$px + 16}] y 40]]] {0 1}
check "art: and is not tried again" [dict size $::hud::art::running] 0
hud::art::configure -ffmpeg /nonexistent/ffmpeg -cache [file join $tmp artcache2]
check "art: without ffmpeg, the pill" [llength [find [ops_of 1440 900 layout full art $art620] image]] 0
check "art: without ffmpeg nothing is started" [dict size $::hud::art::running] 0
hud::art::configure -ffmpeg ffmpeg -cache [file join $tmp artcache] -done ""
set ::hud::art::made {}
check "art: a made picture is found in the cache again by a new daemon (no ffmpeg run)" [list [hud::art::png $art620 20 5 1] [dict size $::hud::art::running]] [list $png 0]
# compact and FPS have no header: no art
check "art: the Compact layout has no header art" [llength [find [ops_of 1440 900 layout compact art $art620] image]] 0
# painted: the canvas shows the PNG as an image item
set c .art
canvas $c -width 1440 -height 900 -background #000000
pack $c; update
hud::draw::paint $c $a1
set imgs [lmap i [$c find withtag hud] { expr {[$c type $i] eq "image" && [lsearch -exact [image names] [$c itemcget $i -image]] >= 0 && [string match *photo* [image type [$c itemcget $i -image]]] ? $i : [continue] }}]
set found 0
foreach i $imgs { if {[$c coords $i] eq [list [expr {$px + 16.0}] 40.0]} { set found 1 } }
check "art: the canvas draws the PNG at the header's place" $found 1
destroy $c

# --- screenshots of the boards' scenes (optional): HUD_SHOTS=dir
if {[info exists ::env(HUD_SHOTS)] && [file isdirectory $::env(HUD_SHOTS)]} {
	proc shot {name W H ops} {
		global env
		set c .s
		catch {destroy $c}
		canvas $c -width $W -height $H -background #000000 -highlightthickness 0 -borderwidth 0
		pack $c -side left
		wm geometry . +0+0
		update
		hud::draw::paint $c $ops
		update
		after 300
		update
		if {[catch {exec import -window [winfo id $c] [file join $env(HUD_SHOTS) $name.png]} err]} {
			puts "  note: no shot for $name ($err)"
		} else {
			puts "  shot $name.png"
		}
		destroy $c
	}
	shot hud-default 1440 900 [ops_of 1440 900 layout full pinned 1 name "Cyberpunk 2077"]
	shot hud-toggle 1440 900 [ops_of 1440 900 layout full pinned 1 menu 1 name "Cyberpunk 2077"]
	shot hud-compact 476 900 [ops_of 476 900 layout compact name "Cyberpunk 2077"]
	shot hud-fps 476 900 [ops_of 476 900 layout fps]
	shot hud-nofr-full 476 900 [ops_of 476 900 layout full frames [dict create ok 0 fps "" ft "" low "" series {}] name "Cyberpunk 2077"]
}

catch {file delete -force $tmp}
if {$fails} {
	puts "hud draw: $fails failed"
	exit 1
}
puts "hud draw: all checks passed"
exit 0
