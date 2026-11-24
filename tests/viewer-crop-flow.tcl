# viewer-crop-flow.tcl - the Image Viewer's crop and rotate, driven as a user would drive it
# (and the Info panel's EXIF read: RIBBON_VIEWER_EXIF, a folder of make-exif.py's JPEGs):
# the aspect, a turn, a flip, Straighten, a corner dragged and the frame moved, then Save as
# copy. Each step is checked on the state it leaves (the frame's pixel aspect, the turned
# size, the Straighten value) and the file Save writes is read back at its size.
#   RIBBON_VIEWER_SCENE=tests/viewer-crop-flow.tcl RIBBON_VIEWER_PIC=FILE.png (a PNG: Tk reads it back)
#   wish8.6 apps/viewer/main.tcl   (the scene runs inside the viewer, then the script exits)
# Prints "ok LABEL" or "FAIL LABEL" lines, then "viewer crop flow: all checks passed" or the count.

set fails 0
proc check {label ok} {
	global fails
	if {$ok} { puts "ok $label" } else { puts "FAIL $label"; incr fails }
}

set folder [file join $::env(HOME) Pictures Iceland]
file mkdir $folder
set pic [file join $folder "Jökulsárlón.png"]
file copy -force $::env(RIBBON_VIEWER_PIC) $pic
set viewer::dir $folder
set viewer::items [nav::items $folder]
set viewer::at [nav::index $viewer::items $pic]
set viewer::file $pic
stage::load $pic
set viewer::facts [facts::of $pic]
viewer::draw

# Info: the photo's camera and date come from its EXIF (RIBBON_VIEWER_EXIF: make-exif.py's folder)
if {[info exists ::env(RIBBON_VIEWER_EXIF)]} {
	set ex [facts::exif [file join $::env(RIBBON_VIEWER_EXIF) mm.jpg]]
	check "Info: the camera from EXIF" [expr {[facts::camera $ex] eq "Fujifilm X-T5"}]
	check "Info: the date taken from EXIF" [dict exists $ex DateTimeOriginal]
}

crop::start
check "crop opens on the board's inset frame" [expr {$crop::on && abs([lindex $crop::fr 0] - 0.065) < 1e-9}]

# the aspect: 1:1 makes the frame's pixel sides equal
crop::set_aspect 11
lassign $crop::fr x0 y0 x1 y1
set pw [expr {($x1 - $x0) * $crop::TW}]; set ph [expr {($y1 - $y0) * $crop::TH}]
check "1:1 frame is square" [expr {abs($pw - $ph) < 0.5}]

# a clockwise turn swaps the sides; a flip reverses the next turn
set tw0 $crop::TW; set th0 $crop::TH
crop::turn 1
check "a turn swaps the picture's sides" [expr {$crop::TW == $th0 && $crop::TH == $tw0}]
check "the turn: rot 1" [expr {$crop::rot == 1}]
crop::flip
check "flip: the flag is on and Straighten mirrors (0 stays 0)" [expr {$crop::flip == 1 && $crop::ang == 0}]

# Straighten: the slider's value from a pointer at the track's middle plus a quarter
lassign $crop::sl sx sw
crop::slide [expr {$sx + $sw * 0.75}]
check "Straighten reads 22.5 degrees at three quarters of the track" [expr {abs($crop::ang - 22.5) < 0.05}]
crop::slide [expr {$sx + $sw * 0.5}]
check "Straighten back at the middle: 0" [expr {$crop::ang == 0.0}]
crop::slide [expr {$sx + $sw * 0.5 + 10}]
check "Straighten in tenths of a degree" [expr {abs($crop::ang * 10 - round($crop::ang * 10)) < 1e-9}]

# the corner: dragging the bottom right corner in keeps the top left
crop::revert
crop::start
lassign $crop::box L T bw bh
lassign $crop::fr x0 y0 x1 y1
set cxp [expr {$L + $x1 * $bw}]; set cyp [expr {$T + $y1 * $bh}]
crop::corner_press 3 $cxp $cyp
crop::drag_move [expr {$cxp - 60}] [expr {$cyp - 40}]
crop::drag_end 0 0
lassign $crop::fr nx0 ny0 nx1 ny1
check "the corner moves, the top left stays" [expr {abs($nx0 - $x0) < 1e-9 && abs($ny0 - $y0) < 1e-9 && $nx1 < $x1 && $ny1 < $y1}]

# a 16:9 frame: its pixel width over height is 16 : 9
crop::set_aspect 169
lassign $crop::fr x0 y0 x1 y1
set r [expr {(($x1 - $x0) * $crop::TW) / (($y1 - $y0) * $crop::TH)}]
check "16:9 frame" [expr {abs($r - 16 / 9.0) < 0.01}]

# Save as copy writes the crop at its size: 16:9 of the turned, flipped picture
set state_fr $crop::fr
set viewer::file $pic
set ::crop::rot 0; set ::crop::flip 0; set ::crop::ang 0.0
set ::crop::fr {0.1 0.1 0.9 0.9}
set ::crop::on 1
set made [crop::save copy]
set out [file join $folder "Jökulsárlón (edited).png"]
check "save as copy writes (edited)" [expr {$made eq 1 && [file exists $out]}]
if {[file exists $out]} {
	set im [image create photo -file $out]
	check "the copy is the frame's size (80% of 1544 x 1029: 1234 x 822)" [expr {[image width $im] == 1234 && [image height $im] == 822}]
	image delete $im
}
check "the viewer shows the copy" [expr {$viewer::file eq $out}]
check "crop leaves edit mode on save" [expr {!$::crop::on}]

# The photo toolbar, on the copy: no button without an action (the title bar has Set as wallpaper and Info only,
# the toolbar's six icons each have one), and Rotate, clicked, turns the file clockwise and shows it again.
viewer::draw
update
set bar_hits {}; set tool_hits {}
foreach h $ui::hits {
	lassign $h x0 y0 x1 y1 press
	if {$y1 <= $zoom::TB} { lappend bar_hits [lindex $press 0] }
	if {$y0 >= $zoom::WH - 64 && $y1 <= $zoom::WH - 20} { lappend tool_hits [lindex $press 0] }
}
check "title bar: Set as wallpaper, Info and the menu, each acting (no Favourite or Share)" [expr {[lsort $bar_hits] eq {bar::toggle_menu viewer::toggle_info vwall::wallpaper}}]
check "toolbar: every icon acts (6 hits, Rotate among them)" [expr {[llength $tool_hits] == 6 && "viewer::rotate" in $tool_hits && "" ni $tool_hits}]
set rot ""
foreach h $ui::hits { if {[lindex $h 4] eq "viewer::rotate"} { set rot $h } }
if {$rot ne ""} {
	set im [image create photo -file $out]
	set bl [$im get 0 [expr {[image height $im] - 1}]]; set tl [$im get 0 0]
	image delete $im
	lassign $rot x0 y0 x1 y1
	set cx [expr {($x0 + $x1) / 2}]; set cy [expr {($y0 + $y1) / 2}]
	event generate $viewer::win.c <ButtonPress-1> -x $cx -y $cy
	event generate $viewer::win.c <ButtonRelease-1> -x $cx -y $cy
	update
	set im [image create photo -file $out]
	check "Rotate clicked: the file is turned (822 x 1234)" [expr {[image width $im] == 822 && [image height $im] == 1234}]
	check "Rotate clicked: clockwise (the bottom left comes to the top left, the top left to the top right)" \
		[expr {[$im get 0 0] eq $bl && [$im get [expr {[image width $im] - 1}] 0] eq $tl}]
	image delete $im
	check "Rotate clicked: the viewer shows the turned picture" [expr {$viewer::file eq $out && [stage::size] eq {822 1234}}]
}

if {$fails == 0} { puts "viewer crop flow: all checks passed" } else { puts "viewer crop flow: $fails checks failed" }
exit [expr {$fails > 0}]
