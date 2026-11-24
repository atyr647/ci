# viewer-scene-steam.tcl - the Steam state of tests/viewer-scene.tcl: a Steam library in a temp HOME with four
# games' screenshots (Cyberpunk 2077 412, Elden Ring 233, Hades II 98, Factorio 61: 804, 6.2 GB as sparse files),
# their appmanifests and icons (RIBBON_VIEWER_COVERS, cut from the board), the newest Cyberpunk 2077 screenshot
# (RIBBON_VIEWER_SHOTPIC) shown with the games list open, on the board's day (gamelist::now, Sun 8 Nov 2026 22:00).

set root [file join $::env(HOME) .local share Steam]
file mkdir [file join $root steamapps] [file join $root appcache librarycache]
set games {1091500 {Cyberpunk 2077} 412 20261108213104 1245620 {Elden Ring} 233 20261105190000 1145350 {Hades II} 98 20261101200000 427520 Factorio 61 20261018180000}
set each [expr {6200000000 / 804}]
foreach {id name n last} $games {
	set fh [open [file join $root steamapps appmanifest_$id.acf] w]
	puts $fh "\"AppState\"\n\{\n\t\"appid\"\t\t\"$id\"\n\t\"name\"\t\t\"$name\"\n\}"
	close $fh
	file copy -force [file join $::env(RIBBON_VIEWER_COVERS) ${id}_icon.jpg] [file join $root appcache librarycache ${id}_icon.jpg]
	set dir [file join $root userdata 1 760 remote $id screenshots]
	file mkdir [file join $dir thumbnails]
	set t [clock scan $last -format %Y%m%d%H%M%S]
	for {set k 0} {$k < $n} {incr k} {
		set f [file join $dir "[clock format [expr {$t - 3600 * $k}] -format %Y%m%d%H%M%S]_1.jpg"]
		# a sparse file of the screenshots' share of 6.2 GB
		set fh [open $f w]; chan configure $fh -translation binary; seek $fh [expr {$each - 1}]; puts -nonewline $fh x; close $fh
	}
}
set shot [file join $root userdata 1 760 remote 1091500 screenshots 20261108213104_1.jpg]
file copy -force $::env(RIBBON_VIEWER_SHOTPIC) $shot
set gamelist::now [clock scan {2026-11-08 22:00} -format {%Y-%m-%d %H:%M}]
set viewer::items [steam::items [file dirname $shot]]
set viewer::dir [file dirname $shot]
viewer::show 0
set gamelist::open 1
viewer::draw
