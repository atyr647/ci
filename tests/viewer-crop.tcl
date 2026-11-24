# viewer-crop.tcl - Crop and rotate (srcpkgs/ribbon-desktop/files/apps/viewer/crop.tcl) without
# Tk: the steps' state (turns, flip, the reversed turns after a flip), the file each save writes
# (read back with PIL by tests/viewer-crop-check.py: the pixels of the crop, the turns, the
# flip, a Straighten turn's direction, the EXIF kept with its orientation at 1), and the
# wallpaper hand-off (vwall::wallpaper runs ribbon-appearance --page desktop --picture FILE --back {Image Viewer}; a stub
# on PATH records it).
#   tclsh8.6 -encoding utf-8 tests/viewer-crop.tcl WORKDIR
set work [lindex $argv 0]
set root [file dirname [file dirname [file normalize [info script]]]]
set app [file join $root srcpkgs ribbon-desktop files apps viewer]
set check [file join $root tests viewer-crop-check.py]
file mkdir $work

set fails 0
proc check {label ok} {
	global fails
	if {$ok} { puts "  ok   $label" } else { puts "  FAIL $label"; incr fails }
}

# The viewer and the stage, without Tk: the open picture is a fixture PNG, and the
# save hands its file to the viewer, which only records it here.
namespace eval viewer {
	variable file ""
	variable info 0
	variable last ""
	proc draw {args} {}
	proc applied {path errs} { variable last; set last $path }
}
source -encoding utf-8 [file join $app zoom.tcl]
source -encoding utf-8 [file join $app nav.tcl]
source -encoding utf-8 [file join $app stage.tcl]
source -encoding utf-8 [file join $app crop.tcl]
# Tk's photos are not here: the preview is not checked by this test
proc crop::update {args} {}
proc crop::preview {args} {}

set env(XDG_CACHE_HOME) [file join $work cache]

proc py {args} {
	global check
	set out [exec python3 $check {*}$args 2>@1]
	return [string trim $out]
}

# Each save: the state, the file it writes, the checker's line.
proc run_save {src mode turns flip ang fr} {
	global check work
	lassign $fr x0 y0 x1 y1
	set crop::rot $turns; set crop::flip $flip; set crop::ang $ang; set crop::fr $fr
	set viewer::file $src
	set ::crop::on 1
	crop::save $mode
	return $viewer::last
}

# The fixtures (PIL): quad.png and quad.jpg (EXIF orientation 6, Make FUJIFILM).
if {[catch {exec python3 $check make $work} err]} {
	puts "  skip viewer crop (no PIL: $err)"
	exit 0
}
set png [file join $work quad.png]
set jpg [file join $work quad.jpg]
set stage_src [dict create file $png nw 200 nh 120 ww 200 wh 120 work $png photo "" tmp ""]

# 1. the state: a turn is clockwise, a turn after a flip runs the other way round
set crop::rot 0; set crop::flip 0
set crop::TW 200; set crop::TH 120
set ::stage::src $stage_src
crop::turn 1
check "turn clockwise: rot 1" [expr {$crop::rot == 1}]
crop::turn -1
check "turn back: rot 0" [expr {$crop::rot == 0}]
crop::turn -1
check "counter-clockwise from 0 is 3" [expr {$crop::rot == 3}]
set crop::flip 1; set crop::rot 0
crop::turn 1
check "after a flip a clockwise turn runs back: rot 3" [expr {$crop::rot == 3}]
check "turn filters" [expr {[crop::turn_filters 1 1 0] eq {transpose=1 hflip}}]
check "straighten filter: the rotation, then the cut" [expr {[lindex [crop::turn_filters 0 0 -1.2] 0] eq "rotate=-0.020944:c=black:ow=iw:oh=ih"
	&& [string match "crop=w='2\\*trunc((iw/(0.999781+0.020942\\*max(iw/ih,ih/iw))-4)/2)':h=*" [lindex [crop::turn_filters 0 0 -1.2] 1]]}]
check "straighten's cut: 1 at 0 degrees, cos + sin x the long side's ratio" [expr {[crop::fill 0.0 200 120] == 1.0
	&& abs([crop::fill 30.0 200 120] - (cos(acos(-1) / 6) + 0.5 * 200 / 120.0)) < 1e-9 && [crop::fill -30.0 120 200] == [crop::fill 30.0 200 120]}]

# 2. a crop of the PNG: the pixels inside the frame, lossless
set out [run_save $png copy 0 0 0.0 {0.25 0.25 0.75 0.75}]
puts "  [py expect $png $out 0 0 0.25 0.25 0.75 0.75 0]"
check "crop copy named (edited)" [string match "*quad (edited).png" $out]
set r [py expect $png $out 0 0 0.25 0.25 0.75 0.75 0]
check "crop: 100 x 60 from the middle, pixel for pixel" [string match "ok*" $r]

# 3. a quarter turn clockwise, the whole picture
set out [run_save $png copy 1 0 0.0 {0 0 1 1}]
set r [py expect $png $out 1 0 0 0 1 1 0]
check "clockwise turn: pixel for pixel" [string match "ok*" $r]
puts "  $r"

# 4. a flip after a turn
set out [run_save $png copy 1 1 0.0 {0 0 1 1}]
set r [py expect $png $out 1 1 0 0 1 1 0]
check "turn and flip: pixel for pixel" [string match "ok*" $r]
puts "  $r"

# 5. Straighten: 30 degrees clockwise turns a point at (130, 40) about the centre (100, 60)
#    to about (136, 58); the picture is then cut to the upright rectangle inside the turned one
#    (200 x 120 over 0.866 + 0.5 x 200/120, less 2 px a side: 112 x 66, so at 44, 27): the dot is at
#    about (92, 31), and no corner of the background shows
set out [run_save $png copy 0 0 30.0 {0 0 1 1}]
set r [py dot $out 92 31]
check "straighten: the dot turns clockwise (30 degrees)" [string match "ok*" $r]
puts "  $r"
set r [py noblack $out 112 66]
check "straighten auto-crops: no black corners" [string match "ok*" $r]
puts "  $r"
set out [run_save $png copy 0 0 -3.5 {0 0 1 1}]
set r [py noblack $out [expr {2 * int((200 / [crop::fill -3.5 200 120] - 4) / 2)}] [expr {2 * int((120 / [crop::fill -3.5 200 120] - 4) / 2)}]]
check "straighten -3.5 degrees: no black corners" [string match "ok*" $r]
puts "  $r"

# 6. a JPEG with EXIF: the saved file is upright, keeps its Make and says orientation 1
set out [run_save $jpg copy 0 0 0.0 {0 0 1 1}]
set r [py expect $jpg $out 0 0 0 0 1 1 8]
check "JPEG crop: upright, 160 x 240 displayed, pixels close" [string match "ok*" $r]
puts "  $r"
check "JPEG keeps EXIF, orientation 1" [string match "ok*" [py exif $out FUJIFILM]]

# 7. Save over the file: the file itself changes
set over [file join $work over.png]
file copy -force $png $over
set out [run_save $over over 0 0 0.0 {0.25 0.25 0.75 0.75}]
check "save over: the same file" [expr {$out eq $over}]
set r [py expect $png $over 0 0 0.25 0.25 0.75 0.75 0]
check "save over writes the crop" [string match "ok*" $r]

# 8. a second copy of the same picture gets a new name
set twice [file join $work twice.png]
file copy -force $png $twice
set first [run_save $twice copy 0 0 0.0 {0.25 0.25 0.75 0.75}]
set second [run_save $twice copy 0 0 0.0 {0.25 0.25 0.75 0.75}]
check "copies: (edited), then (edited 2)" [expr {[string match "*twice (edited).png" $first] && [string match "*twice (edited 2).png" $second]}]

# the title bar's size is the size Save writes, straightened and cropped too
set out [run_save $png copy 1 0 7.5 {0.1 0.2 0.9 0.85}]
set img [exec python3 -c "from PIL import Image; import sys; print(*Image.open(sys.argv\[1\]).size)" $out]
check "the crop's size in the title bar is the saved file's ([crop::out_size 200 120 1 7.5 {0.1 0.2 0.9 0.85}], saved $img)" \
	[expr {[crop::out_size 200 120 1 7.5 {0.1 0.2 0.9 0.85}] eq [join $img " \u00d7 "]}]
set out [run_save $png copy 0 0 -3.5 {0 0 1 1}]
set img [exec python3 -c "from PIL import Image; import sys; print(*Image.open(sys.argv\[1\]).size)" $out]
check "the straightened size in the title bar is the saved file's ([crop::out_size 200 120 0 -3.5 {0 0 1 1}], saved $img)" \
	[expr {[crop::out_size 200 120 0 -3.5 {0 0 1 1}] eq [join $img " \u00d7 "]}]

# 9. the photo toolbar's Rotate: a quarter turn clockwise saved over the file, which the viewer shows again; a JPEG
#    keeps its EXIF with the orientation at 1; a TIFF is turned too; a WebP (Save cannot write it) is left alone
set rp [file join $work rot.png]
file copy -force $png $rp
set viewer::last ""
check "rotate a PNG: saved" [expr {[crop::rotate_file $rp] == 1 && $viewer::last eq $rp}]
set r [py expect $png $rp 1 0 0 0 1 1 0]
check "rotate a PNG: turned clockwise in place, pixel for pixel (120 x 200)" [string match "ok*" $r]
puts "  $r"
set rj [file join $work rot.jpg]
file copy -force $jpg $rj
check "rotate a JPEG: saved" [expr {[crop::rotate_file $rj] == 1}]
set r [py expect $jpg $rj 1 0 0 0 1 1 8]
check "rotate a JPEG: the displayed picture turned clockwise (240 x 160)" [string match "ok*" $r]
puts "  $r"
check "rotate a JPEG: keeps EXIF, orientation 1" [string match "ok*" [py exif $rj FUJIFILM]]
py tiff $work
set rt [file join $work quad.tif]
check "rotate a TIFF: saved" [expr {[crop::rotate_file $rt] == 1}]
set r [py expect $png $rt 1 0 0 0 1 1 0]
check "rotate a TIFF: turned clockwise, pixel for pixel" [string match "ok*" $r]
set rw [file join $work rot.webp]
file copy -force $png $rw
set before [file mtime $rw]
check "rotate a WebP: not written" [expr {[crop::rotate_file $rw] == 0 && [file mtime $rw] == $before}]
# a TIFF of more than one page (a scan, a fax) is not written: the encoder keeps the first page only
py pages $work
set rp2 [file join $work pages.tif]
set before [file mtime $rp2]
check "rotate a TIFF of two pages: not written, both pages kept" [expr {[crop::rotate_file $rp2] == 0
	&& [file mtime $rp2] == $before && [py npages $rp2] == 2}]
check "Save can write a one-page TIFF, not one of two pages" [expr {[crop::can_write $rt] && ![crop::can_write $rp2]}]
check "rotate leaves no part file" [expr {![llength [glob -nocomplain -directory $work .*part-*]]}]

# 10. the wallpaper hand-off: ribbon-appearance on PATH gets the page and the picture
set stub [file join $work stubs]
file mkdir $stub
set log [file join $work appearance.args]
set fh [open [file join $stub ribbon-appearance] w]
puts $fh "#!/bin/sh\nprintf '%s\\n' \"\$@\" > [list $log]"
close $fh
file attributes [file join $stub ribbon-appearance] -permissions 0755
set ::env(PATH) "$stub:$::env(PATH)"
source -encoding utf-8 [file join $app wall.tcl]
set viewer::file $png
vwall::wallpaper
set deadline [expr {[clock milliseconds] + 5000}]
while {![file exists $log] && [clock milliseconds] < $deadline} { after 50; update }
if {[file exists $log]} {
	set fh [open $log]; set got [split [string trim [read $fh]] \n]; close $fh
	check "wallpaper: ribbon-appearance --page desktop --picture FILE --back {Image Viewer}" \
		[expr {$got eq [list --page desktop --picture $png --back {Image Viewer}]}]
} else {
	check "wallpaper: ribbon-appearance ran" 0
}

if {$fails == 0} { puts "viewer crop: all checks passed" } else { puts "viewer crop: $fails checks failed" }
exit [expr {$fails > 0}]
