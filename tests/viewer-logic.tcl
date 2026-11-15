# viewer-logic.tcl - the Image Viewer's logic without Tk: zoom limits and steps, the
# fit and fill geometry, the navigator's view, navigation order and wrap, the decoder
# for each format, and Delete to a fake trash (freedesktop layout).
#   tclsh8.6 -encoding utf-8 tests/viewer-logic.tcl WORKDIR
set work [lindex $argv 0]
set app [file join [file dirname [file dirname [file normalize [info script]]]] srcpkgs ribbon-desktop files apps viewer]
source -encoding utf-8 [file join $app zoom.tcl]
source -encoding utf-8 [file join $app nav.tcl]
source -encoding utf-8 [file join $app stage.tcl]

set fails 0
proc check {label ok} {
	global fails
	if {$ok} { puts "  ok   $label" } else { puts "  FAIL $label"; incr fails }
}

# zoom: the steps stay within the limits and go up and down by the step
check "zoom step in" [expr {abs([zoom::step 1.0 1] - 1.25) < 1e-9}]
check "zoom step out" [expr {abs([zoom::step 1.0 -1] - 0.8) < 1e-9}]
check "zoom max" [expr {[zoom::step 7.9 1] == 8.0}]
check "zoom min" [expr {[zoom::step 0.051 -1] == 0.05}]
check "label 45%" [expr {[zoom::label 0.45] eq "45%"}]

# fit: 1440 x 2880 in the fit box (1088 x 648), centred between the title bar and the foot
set r [zoom::rect fit 0 0.5 0.5 0 1440 2880]
check "fit size 324 x 648" [expr {[lindex $r 2] == 324 && [lindex $r 3] == 648}]
check "fit centred" [expr {[lindex $r 0] == (1240 - 324) / 2 && [lindex $r 1] == 68}]
# fit with the Info panel open: the stage is 910 wide
set r [zoom::rect fit 0 0.5 0.5 1 1440 2880]
check "fit beside Info" [expr {[lindex $r 0] == (910 - 324) / 2}]
# 1:1 of a 7728 px picture: its own size, centred on the focus, clamped to the stage
set r [zoom::rect one 0 0.5 0.5 0 7728 5152]
check "one is native size" [expr {[lindex $r 2] == 7728}]
check "one clamps to the stage" [expr {[lindex $r 0] <= 0 && [lindex $r 0] + 7728 >= 1240}]
# fill covers the stage below the title bar
set r [zoom::rect fill 0 0.5 0.5 0 1544 1029]
check "fill covers the stage" [expr {[lindex $r 2] >= 1240 && [lindex $r 3] >= 732}]
# zoom 45 % of 7728 x 5152 at focus 0.6: 3478 wide, the picture's left at 620 - 0.6 * 3478
set r [zoom::rect zoom 0.45 0.6 0.5 0 7728 5152]
check "zoom 45 % width" [expr {[lindex $r 2] == 3478}]
check "zoom focus centred" [expr {abs([lindex $r 0] - (620 - 2087)) <= 1}]
# the navigator's view: the whole picture when it fits, a part when it doesn't
lassign [zoom::viewport 0 1240 1240] f0 f1
check "viewport whole" [expr {$f0 == 0.0 && $f1 == 1.0}]
lassign [zoom::viewport -1000 3000 1240] f0 f1
check "viewport part" [expr {abs($f0 - 1000.0/3000) < 1e-9 && abs($f1 - 2240.0/3000) < 1e-9}]

# navigation: Files' order, wrap both ways, arrows over one picture do nothing
set dir [file join $work folder]
file mkdir $dir
foreach n {b.png A.jpg notes.txt c.PNG clip.mp4 d.svg e.heic pic.tif Ärmel.webp} { close [open [file join $dir $n] w] }
file mkdir [file join $dir Sub]
set items [nav::items $dir]
set names [lmap p $items { file tail $p }]
check "pictures the stage draws, dictionary order (no video, SVG or HEIC)" [expr {$names eq {A.jpg b.png c.PNG pic.tif Ärmel.webp}}]
check "wrap forward" [expr {[nav::step 4 1 5] == 0}]
check "wrap back" [expr {[nav::step 0 -1 5] == 4}]
check "one picture" [expr {[nav::step 0 1 1] == 0}]
check "kind image" [expr {[nav::kind a.webp] eq "image"}]
check "a video is not walked" [expr {[nav::kind a.MP4] eq ""}]
check "tiff is walked" [expr {[nav::kind a.TIFF] eq "image"}]
check "kind other" [expr {[nav::kind a.txt] eq ""}]

# Delete: the file goes to the trash's files/ with its .trashinfo
set xdg [file join $work xdg]
set ::env(XDG_DATA_HOME) $xdg
set victim [file join $dir b.png]
set name [nav::bin $victim]
check "trashed name" [expr {$name eq "b.png"}]
check "file moved" [expr {![file exists $victim] && [file exists [file join $xdg Trash files b.png]]}]
set info [file join $xdg Trash info b.png.trashinfo]
check "trashinfo written" [file exists $info]
if {[file exists $info]} {
	set fh [open $info]; set body [read $fh]; close $fh
	check "trashinfo path" [string match "*Path=*/folder/b.png*" $body]
}
close [open $victim w]
check "second trash gets a new name" [expr {[nav::bin $victim] eq "b 2.png"}]

# decoders: Tk reads PNG, GIF, PPM; ffmpeg-era formats need the helper; the rest is none
check "png is tk" [expr {[stage::decoder a.png] eq "tk"}]
check "gif is tk" [expr {[stage::decoder a.GIF] eq "tk"}]
check "ppm is tk" [expr {[stage::decoder a.ppm] eq "tk"}]
check "heic has no decoder" [expr {[stage::decoder a.heic] eq "none"}]
check "a video's first frame comes through ffmpeg" [expr {[stage::decoder a.mp4] eq ([auto_execok ffmpeg] ne "" ? "helper" : "none")}]
set helper [expr {[auto_execok ffmpeg] ne "" || [auto_execok gdk-pixbuf-thumbnailer] ne ""}]
check "jpeg is helper when a helper exists" [expr {[stage::decoder a.jpg] eq ($helper ? "helper" : "none")}]
check "tiff is helper when a helper exists" [expr {[stage::decoder a.tif] eq ($helper ? "helper" : "none")}]
# every kind the folder walk lists has a decoder (with a helper), so no walked picture is a blank stage
if {$helper} {
	set blank {}
	foreach e $nav::image { if {[stage::decoder a.$e] eq "none"} { lappend blank $e } }
	check "every walked kind decodes ($blank)" [expr {$blank eq ""}]
}
# the .desktop file claims only what the stage decodes: TIFF in, SVG out
set fh [open [file join $app org.ribbon.imageviewer.desktop]]; set de [read $fh]; close $fh
regexp {MimeType=([^\n]*)} $de -> mimes
check "MimeType has image/tiff" [expr {"image/tiff" in [split $mimes ";"]}]
check "MimeType has no SVG" [expr {"image/svg+xml" ni [split $mimes ";"]}]
set ext {png png jpeg jpg gif gif webp webp bmp bmp avif avif tiff tif x-portable-pixmap ppm x-portable-graymap pgm}
set undecoded {}
# the video types are the kinds the viewer walks as videos (nav::video, played in mpv)
set vext {mp4 mp4 x-m4v m4v x-matroska mkv webm webm quicktime mov x-msvideo avi}
set vbad {}
foreach m [split [string trimright $mimes ";"] ";"] {
	if {![string match video/* $m]} continue
	if {![dict exists $vext [string range $m 6 end]] || [dict get $vext [string range $m 6 end]] ni $nav::video} { lappend vbad $m }
}
check "every video MimeType is a kind the viewer plays ($vbad)" [expr {$vbad eq ""}]
check "MimeType has the videos the viewer plays" [expr {[llength [lsearch -all [split $mimes ";"] video/*]] == 6}]
foreach m [split [string trimright $mimes ";"] ";"] {
	if {[string match video/* $m]} continue
	set e [dict get $ext [string range $m 6 end]]
	if {[stage::decoder a.$e] eq "none" && ($helper || $e in {png gif ppm pgm})} { lappend undecoded $m }
}
check "every MimeType decodes ($undecoded)" [expr {$undecoded eq ""}]

puts [expr {$fails ? "viewer logic: $fails checks failed" : "viewer logic: all checks passed"}]
exit [expr {$fails > 0}]
