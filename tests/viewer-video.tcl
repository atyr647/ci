# viewer-video.tcl - a video in the Image viewer with the real mpv (apps/viewer/video.tcl), run as the viewer's
# scene (RIBBON_VIEWER_SCENE=this file) under xvfb: RIBBON_VIEWER_CLIP (a 4 s clip the test makes) in a folder
# with a picture, opened as a user would. Checked through a second connection to mpv's IPC socket, as a user's
# eyes would: mpv embeds in the viewer's window and plays; the transport's play/pause button pauses mpv; a click
# on the scrubber seeks; the volume slider and the mute button set mpv's volume and mute (and the volume is kept);
# Space plays again; the menu opens over the video with mpv's window hidden over its frame, Copy path copies, and
# mpv shows again; the next item stops mpv. Prints "ok ..." lines, then the summary, and exits.

fconfigure stdout -buffering line
set fails 0
proc check {label ok} {
	global fails
	if {$ok} { puts "ok $label" } else { puts "FAIL $label"; incr fails }
}
proc done {} {
	puts [expr {$::fails ? "viewer video: $::fails checks failed" : "viewer video: all checks passed"}]
	video::close 1
	exit [expr {$::fails > 0}]
}
# wait up to MS for the condition (a Tcl expression), the event loop running
proc wait_for {cond ms} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 [list expr $cond]]} {
		if {[clock milliseconds] > $end} { return 0 }
		after 20 {set ::tick 1}; vwait ::tick
	}
	return 1
}
# mpv's own answer to get_property, over a connection of the test's own
proc mpv_get {prop} {
	if {![info exists ::probe]} {
		set ::probe [unix_extra::connect $video::sock]
		fconfigure $::probe -buffering line -translation lf -blocking 1
	}
	puts $::probe "{\"command\":\[\"get_property\",\"$prop\"\],\"request_id\":7}"
	flush $::probe
	while {[gets $::probe line] >= 0} {
		if {[string match {*"request_id":7*} $line]} {
			if {[regexp {"data":("[^"]*"|[^,\}]+)} $line -> d]} { return [string trim $d \"] }
			return ""
		}
	}
	return ""
}

set folder [file join $::env(HOME) Videos]
file mkdir $folder
set clip [file join $folder clip.mp4]
file copy -force $::env(RIBBON_VIEWER_CLIP) $clip
close [open [file join $folder zz.png] w]

check "mpv and the IPC package are there" [video::available]
set nav::play [video::available]
set viewer::dir $folder
set viewer::items [nav::items $folder]
check "the video is walked" [expr {[lsearch -exact $viewer::items $clip] == 0}]
viewer::show 0
update
check "mpv's window over the picture" [wait_for {$video::win ne "" && [winfo ismapped $video::win]} 3000]
check "mpv answers on its socket" [wait_for {$video::chan ne ""} 6000]
if {$video::chan eq ""} done
check "mpv plays in the viewer's window" [expr {[mpv_get wid] eq [winfo id $video::win] || [mpv_get wid] == [winfo id $video::win]}]
check "the length reaches the transport" [wait_for {abs($video::dur - 4.0) < 0.2} 3000]
check "the position moves" [wait_for {$video::pos > 0.3} 4000]
check "playing: mpv is not paused" [expr {[mpv_get pause] eq "false"}]
# the screen: mpv's picture fills the fitted rectangle (the clip is ffmpeg's testsrc; 55 % across is its yellow bar)
if {[auto_execok import] ne ""} {
	set shot [file join $::env(HOME) live.png]
	exec import -window root $shot
	set ph [image create photo -file $shot]
	set fx [expr {[winfo rootx $video::win] + round([winfo width $video::win] * 0.55)}]
	set fy [expr {[winfo rooty $video::win] + 8}]
	lassign [$ph get $fx $fy] r g b
	lassign [$ph get [expr {[winfo rootx $video::win] - 20}] $fy] r2 g2 b2
	check "mpv's picture fills its window (yellow at 55 %, top), the stage beside it ($r $g $b; $r2 $g2 $b2)" \
		[expr {$r > 150 && $g > 150 && $b < 100 && $r2 < 60 && $g2 < 60 && $b2 < 60}]
}

# the transport on the board's geometry: the toolbar 808 wide, centred, 20 above the foot
set tx [expr {($zoom::WW - 808) / 2}]
set ty [expr {$zoom::WH - 20 - 44}]
ui::press [expr {$tx + 6 + 16}] [expr {$ty + 22}]; ui::release [expr {$tx + 6 + 16}] [expr {$ty + 22}]
check "the play/pause button pauses mpv" [wait_for {[mpv_get pause] eq "true"} 2000]
check "the transport shows play" [expr {$video::paused}]
# the scrubber: 440 px from x+106; a click at its middle
set sx [expr {$tx + 106 + 220}]
ui::press $sx [expr {$ty + 22}]; ui::release $sx [expr {$ty + 22}]
check "a click on the scrubber seeks to the middle" [wait_for {abs([mpv_get time-pos] - 2.0) < 0.35} 3000]
# the volume slider: 84 px from x+657; a click at a quarter
set vx [expr {$tx + 657 + 21}]
ui::press $vx [expr {$ty + 22}]; ui::release $vx [expr {$ty + 22}]
check "the volume slider sets mpv's volume" [wait_for {abs([mpv_get volume] - 25) < 1} 2000]
ui::press [expr {$tx + 615 + 17}] [expr {$ty + 22}]; ui::release [expr {$tx + 615 + 17}] [expr {$ty + 22}]
check "the volume button mutes" [wait_for {[mpv_get mute] eq "true"} 2000]
set fh [open [video::conf]]; set conf [read $fh]; close $fh
check "volume and mute kept" [expr {[string match *volume=25* $conf] && [string match *muted=1* $conf]}]
focus -force $viewer::win; update
event generate $viewer::win <KeyPress> -keysym space -when tail
check "Space plays again" [wait_for {[mpv_get pause] eq "false"} 2000]

# the menu over the video: mpv's frame stands on the stage, its window hidden
ui::press [expr {$zoom::WW - 16 - 17}] 34; ui::release [expr {$zoom::WW - 16 - 17}] 34
check "the menu opens" [expr {$bar::menu}]
check "mpv's window is hidden over its frame" [wait_for {![winfo ismapped $video::win]} 2000]
check "the stage holds mpv's frame" [expr {[dict get $stage::src work] eq $video::frozen}]
# Copy path: the third row
set my [expr {$zoom::TB - 10 + 6 + 2 * 32 + 16}]
ui::press [expr {$zoom::WW - 16 - 120}] $my; ui::release [expr {$zoom::WW - 16 - 120}] $my
check "Copy path copies the video's path" [expr {[clipboard get] eq $clip}]
check "the menu closes and mpv shows again" [wait_for {!$bar::menu && [winfo ismapped $video::win]} 2000]

# the next item: mpv is stopped
set pid $video::pid
viewer::go 1
check "the next item stops mpv" [wait_for {[catch {exec kill -0 $pid}]} 3000]
check "a picture has the photo toolbar again" [expr {!$video::on}]

# back to the video: the socket of the mpv now playing outlives the last one's clean-up (the last close's delete
# must not take the new mpv's socket before the viewer has connected to it)
viewer::go -1
check "the video again: mpv answers" [wait_for {$video::chan ne ""} 6000]
after 900 {set ::tick 1}; vwait ::tick
check "the playing mpv's socket is still there" [file exists $video::sock]
# the menu opened and the next item shown at once: mpv's frame, landing late, does not take the next picture's place
image create photo red -width 64 -height 48; red put #c03020 -to 0 0 64 48; red write [file join $folder zz.png] -format png
bar::toggle_menu
viewer::go 1
check "the picture after the video is open" [dict exists $stage::src work]
after 1200 {set ::tick 1}; vwait ::tick
check "a late frame from the last video leaves the picture shown" [expr {[dict exists $stage::src work] && [dict get $stage::src work] ne $video::frozen}]
# a folder of one video, deleted: mpv stops
set solo [file join $::env(HOME) Solo]
file mkdir $solo
file copy -force $clip [file join $solo one.mp4]
viewer::open_items [list [file join $solo one.mp4]] 0
check "the lone video plays" [wait_for {$video::chan ne ""} 6000]
set pid $video::pid
viewer::trash
check "the lone video deleted: mpv stops" [wait_for {[catch {exec kill -0 $pid}] && !$video::on} 3000]
done
