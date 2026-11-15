# viewer-scene.tcl - the Image Viewer in one of its boards' states, drawn on a
# 1440 x 900 desktop at (100, 72) (apps/viewer/main.tcl, RIBBON_VIEWER_SCENE=this file).
#   RIBBON_VIEWER_STATE = photo   Viewer-Final-1-Stage: fit, the photo toolbar
#                         info    Viewer-Final-2-Info: the Info panel docked, the stage narrower
#                         zoom    Viewer-Final-4-Zoom: 45 %, the zoom toolbar, no edge arrows
#                         edit    Viewer-Final-3-Info-Edit: the Info panel in edit (rename, Access, Opens with)
#                         crop    Viewer-Final-8-Crop: the crop frame, the toolbar and the title bar's Save
#                         menu    Viewer-Final-9-Menu: the title bar's menu open
#                         tip     Tooltip-2-Viewer: the pointer rests on Rotate: it is lit (its name not yet up)
#                         tipname Tooltip-2-Viewer: its name over the toolbar (the step compares the pill's inside: under
#                                 xvfb, without rbnalpha's C side, the pill's window is opaque out to its shadow)
#                         cropcopy  Viewer-Final-10-Crop-Copy: crop on Jökulsárlón.webp, Save as copy alone
#                         video   Viewer-Final-5-Video: glacier-walk.mp4 (7 of 27) playing at 0:42 of 2:15
#                         paused  Viewer-Final-11-Video-Paused: the same, paused with the sound off
#                         steam   Viewer-Final-6-Steam: a Cyberpunk 2077 screenshot with the games list open
# RIBBON_VIEWER_CLIP = the video (the test makes it from the board's frame); RIBBON_VIEWER_SHOTPIC = the Steam
# screenshot, RIBBON_VIEWER_COVERS = a folder of <appid>_icon.jpg (both cut from the board's render).
# The folder is ~/Pictures/Iceland: Jökulsárlón.jpg (a picture of 1544 x 1029, the board's
# 1.5 ratio) and 26 more names after it, so the title reads "1 of 27".
# RIBBON_VIEWER_PIC = the picture to copy in as Jökulsárlón.jpg (the test makes it).

set state [expr {[info exists ::env(RIBBON_VIEWER_STATE)] ? $::env(RIBBON_VIEWER_STATE) : "photo"}]
if {$state in {video paused}} { source -encoding utf-8 [file join [file dirname [info script]] viewer-scene-video.tcl]; return }
if {$state eq "steam"} { source -encoding utf-8 [file join [file dirname [info script]] viewer-scene-steam.tcl]; return }
set folder [file join $::env(HOME) Pictures Iceland]
file mkdir $folder
set pic [file join $folder "Jökulsárlón.jpg"]
if {![file exists $pic] && [info exists ::env(RIBBON_VIEWER_PIC)]} { file copy -force $::env(RIBBON_VIEWER_PIC) $pic }
if {$state eq "cropcopy"} {
	# a real WebP of the picture: Save cannot write it back
	set webp [file join $folder "Jökulsárlón.webp"]
	exec ffmpeg -nostdin -v error -y -i $pic -c:v libwebp -lossless 1 $webp
	file delete $pic
	set pic $webp
}
# 26 more names after Jökulsárlón in dictionary order: the picture is 1 of 27
for {set i 1} {$i <= 26} {incr i} {
	set n [file join $folder [format {Kverk-%02d.png} $i]]
	if {![file exists $n]} { close [open $n w] }
}
# the picture's EXIF and size, as the board has them (the fixture is a PNG)
rename facts::exif facts::exif_real
proc facts::exif {path} {
	# the board's photo: the Info panel's exposure strip, camera, date and map (Viewer-Final-2-Info)
	if {[string match *Jökulsárlón.jpg $path]} {
		return {Make FUJIFILM Model X-T5 LensModel {XF16-55mmF2.8 R LM WR} ExposureTime 0.004 FNumber 8.0 ISO 125 FocalLength 23.0
			DateTimeOriginal {2026:08:14 21:43:00} GPSLatitudeRef N GPSLatitude {64.0 4.0 41.08} GPSLongitudeRef W GPSLongitude {16.0 13.0 51.6}}
	}
	return [facts::exif_real $path]
}
set viewer::dir $folder
set viewer::items [nav::items $folder]
set viewer::at [nav::index $viewer::items $pic]
set viewer::file $pic
if {$state eq "info"} { set viewer::info 1 }
stage::load $pic
# the board's photo is 7728 x 5152 (the fixture is a 1544 x 1029 copy): the header size stands in
set stage::src [dict replace $stage::src nw 7728 nh 5152]
set viewer::facts [facts::of $pic]
if {$state eq "zoom"} { set viewer::mode zoom; set viewer::s 0.45; set viewer::cx 0.6; set viewer::cy 0.5 }
if {$state eq "edit"} {
	# the board's file: a 21.6 MB JPEG of ada's, which Image Viewer (the default), darktable, GIMP and Firefox open
	set apps [file join $::env(HOME) .local share applications]
	file mkdir $apps [file join $::env(HOME) .config]
	foreach {id name} {org.ribbon.imageviewer.desktop {Image Viewer} darktable.desktop darktable gimp.desktop GIMP firefox.desktop Firefox} {
		set fh [open [file join $apps $id] w]
		puts $fh "\[Desktop Entry\]\nType=Application\nName=$name\nExec=true %F\nMimeType=image/jpeg;"
		close $fh
	}
	set fh [open [file join $::env(HOME) .config mimeapps.list] w]
	puts $fh "\[Default Applications\]\nimage/jpeg=org.ribbon.imageviewer.desktop\n\[Added Associations\]\nimage/jpeg=darktable.desktop;gimp.desktop;firefox.desktop;"
	close $fh
	set ::env(XDG_DATA_DIRS) [file join $::env(HOME) none]
	set viewer::facts [dict replace $viewer::facts mime image/jpeg typename "JPEG image" size 21600000 owner ada]
	set viewer::info 1; inspector::edit_begin $viewer::facts
}
if {$state eq "menu"} { set bar::menu 1 }
if {$state in {crop cropcopy}} { crop::start } else { viewer::draw }
if {$state in {tip tipname}} {
	# the pointer on Rotate once the window is up; the name at once (tipname) or not before the shot (tip)
	set tip::delay [expr {$state eq "tip" ? 100000 : 0}]
	# (now, before the shot is set up: the window is mapped first)
	update
	set r [lsearch -inline -index 0 $bar::tips rotate]
	lassign $r - - bx by bw bh
	event generate $viewer::win.c <Motion> -x [expr {$bx + 17}] -y [expr {$by + 17}] -warp 0
	update
}
