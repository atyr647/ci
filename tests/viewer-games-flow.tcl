# viewer-games-flow.tcl - Steam screenshots by game, the title bar's menu and a WebP's Rotate, clicked as a user
# would, in the viewer's scene (RIBBON_VIEWER_SCENE=this file) under xvfb. The Steam library is the Steam scene's
# (tests/viewer-scene-steam.tcl: four games, 804 screenshots); ribbon-files and wl-copy are stubs on PATH that
# record their arguments (RIBBON_VIEWER_STUBLOG). Prints "ok ..." lines, then the summary, and exits.

fconfigure stdout -buffering line
set fails 0
proc check {label ok} {
	global fails
	if {$ok} { puts "ok $label" } else { puts "FAIL $label"; incr fails }
}
proc click {x y} { ui::press $x $y; ui::release $x $y }
proc hit_of {cmd} {
	foreach h [lreverse $ui::hits] { if {[lindex $h 4 0] eq $cmd} { return [lrange $h 0 3] } }
	return ""
}
proc stub_log {} {
	if {[catch {set fh [open $::env(RIBBON_VIEWER_STUBLOG)]}]} { return "" }
	set t [read $fh]; close $fh; return $t
}
proc wait_for {cond ms} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 [list expr $cond]]} {
		if {[clock milliseconds] > $end} { return 0 }
		after 20 {set ::tick 1}; vwait ::tick
	}
	return 1
}

set state steam
source -encoding utf-8 [file join [file dirname [info script]] viewer-scene-steam.tcl]
set gamelist::open 0
viewer::draw
check "a Steam screenshot: the title bar's game button names the game" [expr {[lindex [viewer::game] 0] eq "Cyberpunk 2077"}]
check "newest first: 1 of 412" [expr {$viewer::at == 0 && [llength $viewer::items] == 412}]
check "when it was taken, from Steam's name" [expr {[viewer::when] eq {{Sun 8 Nov} 21:31}}]
set b [hit_of gamelist::toggle]
check "the game button acts" [expr {$b ne ""}]
click [expr {[lindex $b 0] + 10}] 34
check "the button opens the games list" [expr {$gamelist::open}]
# the rows: 44 tall, 2 apart, from 58 + 20 + 44 + 18 + 1 + 10 - 1 (the rule) = 150; Elden Ring is the second
click 200 [expr {150 + 46 + 22}]
check "choosing Elden Ring closes the list and shows its newest screenshot" [expr {!$gamelist::open && [llength $viewer::items] == 233 && $viewer::at == 0
	&& [string match */1245620/screenshots/20261105190000_1.jpg $viewer::file]}]
check "the button names Elden Ring" [expr {[lindex [viewer::game] 0] eq "Elden Ring"}]
viewer::go 1
check "next: the screenshot before it, 2 of 233" [expr {$viewer::at == 1 && [string match *20261105180000_1.jpg $viewer::file]}]
click [expr {[lindex [hit_of gamelist::toggle] 0] + 10}] 34
set sb [hit_of viewer::show_in_files]
click [expr {[lindex $sb 0] + 10}] [expr {[lindex $sb 1] + 10}]
check "Show in Files opens Files on the screenshot shown" [wait_for {[string match "*ribbon-files $viewer::file*" [stub_log]]} 3000]
check "  and closes the list" [expr {!$gamelist::open}]
click [expr {[lindex [hit_of gamelist::toggle] 0] + 10}] 34
focus -force $viewer::win; update
event generate $viewer::win <KeyPress> -keysym Escape -when tail
check "Escape closes the list" [wait_for {!$gamelist::open} 2000]

# a short window: the list holds fewer rows than games, and the wheel (X11's buttons 4 and 5) over it scrolls it,
# down a row and back, without zooming the picture
viewer::resized $zoom::WW 400; viewer::relayout; update
click [expr {[lindex [hit_of gamelist::toggle] 0] + 10}] 34
set mode0 $viewer::mode
event generate $viewer::win.c <Button-5> -x 200 -y 200 -when tail; update
check "the wheel down over the list shows the next row" [expr {$gamelist::open && $gamelist::top == 1 && $viewer::mode eq $mode0}]
event generate $viewer::win.c <Button-4> -x 200 -y 200 -when tail; update
check "  and up again" [expr {$gamelist::top == 0}]
set gamelist::open 0
viewer::resized $zoom::WW 800; viewer::relayout; update

# the menu, on the Cyberpunk 2077 screenshot (a real JPEG): Copy puts the picture on the clipboard as PNG (wl-copy)
viewer::open_items [steam::items [file dirname $shot]] 0
set m [hit_of bar::toggle_menu]
click [expr {[lindex $m 0] + 17}] 34
check "the menu opens" [expr {$bar::menu}]
set ry [expr {$zoom::TB - 10 + 6 + 32 + 16}]
click [expr {$zoom::WW - 16 - 120}] $ry
check "Copy: wl-copy gets the picture as PNG" [wait_for {[string match "*wl-copy --type image/png PNG*" [stub_log]]} 4000]
check "  the menu closes" [expr {!$bar::menu}]
click [expr {[lindex $m 0] + 17}] 34
click 200 400
check "a click outside closes the menu" [expr {!$bar::menu}]
click [expr {[lindex $m 0] + 17}] 34
click [expr {$zoom::WW - 16 - 120}] [expr {$zoom::TB - 10 + 6 + 16}]
check "Show in Files from the menu" [wait_for {[regexp -all {ribbon-files} [stub_log]] >= 2} 3000]
# Properties ends the menu, after a rule (Viewer-Final-9-Menu): 6 + 3 x 32 + 9 down
click [expr {[lindex $m 0] + 17}] 34
click [expr {$zoom::WW - 16 - 120}] [expr {$zoom::TB - 10 + 6 + 3 * 32 + 9 + 16}]
check "Properties from the menu: the Properties window on the file shown" [wait_for {[string match "*ribbon-properties [file normalize $viewer::file]*" [stub_log]]} 3000]
check "  the menu closes" [expr {!$bar::menu}]
click [expr {[lindex $m 0] + 17}] 34
click [expr {$zoom::WW - 16 - 120}] [expr {$zoom::TB - 10 + 6 + 3 * 32 + 4}]
check "the rule takes no click" [expr {[regexp -all {ribbon-properties} [stub_log]] == 1}]
set bar::menu 0; viewer::draw
viewer::input Return \r 8
check "Alt+Return: Properties" [wait_for {[regexp -all {ribbon-properties} [stub_log]] == 2} 3000]

# tooltips: every icon-only button has its name (Tooltip-2-Viewer), and the one under the pointer is lit
viewer::draw
set names [lmap t $bar::tips {lindex $t 1}]
set want [list Menu Info {Set as wallpaper} {Zoom out} {Zoom in} Rotate {Crop and rotate} {Full screen} {Move to Trash}]
check "the icon-only buttons' names: [join $names {, }]" [expr {[llength [lmap n $want { if {$n in $names} { set n } else continue }]] == [llength $want]}]
set r [lsearch -inline -index 1 $bar::tips Info]
lassign $r key - bx by bw bh
set tip [bar::tip_at [expr {$bx + 5}] [expr {$by + 5}]]
check "the Info button's tooltip goes under the title bar (68)" [expr {[lindex $tip 1] eq "Info" && [lindex $tip 4] == 68 && [lindex $tip 5] eq "below"}]
bar::hover [expr {$bx + 5}] [expr {$by + 5}]
check "  and under the pointer it is lit" [expr {$bar::hot eq "info"}]
bar::hover -1 -1
check "  not after the pointer left" [expr {$bar::hot eq ""}]
set bar::menu 1
check "no tooltip while the menu is open" [expr {[bar::tip_at [expr {$bx + 5}] [expr {$by + 5}]] eq ""}]
set bar::menu 0; viewer::draw

# a WebP: Rotate cannot save over it, so it opens the crop view turned, with Save as copy alone
set web [file join $::env(HOME) Pictures w.webp]
file mkdir [file dirname $web]
exec ffmpeg -nostdin -v error -f lavfi -i color=c=0x285a8c:s=320x240 -frames:v 1 -c:v libwebp $web
viewer::open_items [list $web] 0
check "a WebP is no Steam screenshot" [expr {[viewer::game] eq {}}]
viewer::rotate
check "Rotate on a WebP opens the crop view, a quarter turned" [expr {$crop::on && $crop::rot == 1}]
set saves [lmap h $ui::hits { if {[lindex $h 1] < $zoom::TB && [lindex $h 4 0] eq "crop::save"} { lindex $h 4 1 } else continue }]
check "  the title bar has Save as copy and no Save" [expr {$saves eq {copy}}]
set sc [hit_of crop::save]
click [expr {[lindex $sc 0] + 10}] 34
set out [file join [file dirname $web] "w (edited).jpg"]
set wh [expr {[file exists $out] ? [split [string trim [exec ffprobe -v error -show_entries stream=width,height -of csv=p=0 $out]] ,] : {0 0}}]
check "  Save as copy writes w (edited).jpg, turned upright (the crop's inset frame, $wh)" [expr {[lindex $wh 0] > 150 && [lindex $wh 1] > [lindex $wh 0]}]

puts [expr {$fails ? "viewer games flow: $fails checks failed" : "viewer games flow: all checks passed"}]
exit [expr {$fails > 0}]
