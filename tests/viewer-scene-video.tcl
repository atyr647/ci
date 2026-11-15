# viewer-scene-video.tcl - the video states of tests/viewer-scene.tcl (RIBBON_VIEWER_STATE video or paused):
# ~/Pictures/Iceland with six pictures before glacier-walk.mp4 and twenty after it (7 of 27), the clip made by the
# test from the board's frame (RIBBON_VIEWER_CLIP; its creation_time is the board's Sat 15 Aug 10:12 UTC, the test
# runs in UTC). mpv stands in (video::standin): the stage keeps the clip's first frame and the transport draws
# the board's model, 0:42 of 2:15 at volume 70, playing (video) or paused with the sound off (paused).

set folder [file join $::env(HOME) Pictures Iceland]
file mkdir $folder
foreach n {Askja Dettifoss Eldgja Fjadrargljufur Geysir Gljufrabui} {
	close [open [file join $folder $n.png] w]
}
for {set i 1} {$i <= 20} {incr i} { close [open [file join $folder [format {Kverk-%02d.png} $i]] w] }
set clip [file join $folder glacier-walk.mp4]
file copy -force $::env(RIBBON_VIEWER_CLIP) $clip
set nav::play 1
set video::standin 1
set viewer::dir $folder
set viewer::items [nav::items $folder]
viewer::show [nav::index $viewer::items $clip]
set video::dur 135.0
set video::pos 42.3
set video::vol 70
if {$state eq "paused"} { set video::paused 1; set video::muted 1 }
viewer::draw
