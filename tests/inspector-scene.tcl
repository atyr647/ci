# inspector-scene.tcl - the file Inspector drawn in one of its boards' states, on
# a 1440 x 900 desktop, for screenshots and pixel comparison (run by
# properties/main.tcl with RIBBON_PROPERTIES_SCENE=this file; the home from
# tests/properties-fixture.tcl, and tests/inspector-scene.sh-style callers set it).
#   RIBBON_SCENE = image  (FileProps-Inspector-Image: Files' panel, pinned footer)
#                  viewer (Viewer-Final-2-Info: the Image viewer's Info, no preview, follow footer)
#                  folder (FileProps-Inspector-Folder)
#                  text   (FileProps-Inspector-Text)
#                  multi  (FileProps-Inspector-Multi: five selected)
#                  edit   (FileProps-Inspector-Edit: the photo's edit view, Group changed, undo shown)
#                  edit-folder (the folder's edit view: Access only, no Opens with)
#   RIBBON_PROPERTIES_SHOT = file: take a screenshot (ImageMagick import) and quit
#   RIBBON_PROPERTIES_EXIT = ms: quit after drawing; any Tcl error fails
set scene [expr {[info exists ::env(RIBBON_SCENE)] ? $::env(RIBBON_SCENE) : "image"}]
if {[info exists ::env(RIBBON_PROPERTIES_EXIT)] || [info exists ::env(RIBBON_PROPERTIES_SHOT)]} {
	proc bgerror {msg} { puts stderr "$msg\n$::errorInfo"; exit 1 }
}
set ui::caretfix off
set repo [file dirname [file dirname [file normalize [info script]]]]
source -encoding utf-8 [file join $repo srcpkgs ribbon-desktop files properties inspector.tcl]

# The boards' photo: its size and EXIF (the fixture's picture is a small PNG).
# Everything else of the file is the real stat, with the boards' dates and owner.
rename facts::exif facts::exif_real
rename facts::image_size facts::image_size_real
set JPG "Jökulsárlón.jpg"
proc facts::exif {path} {
	if {[string match *Jökulsárlón.jpg $path]} {
		return {Make FUJIFILM Model X-T5 LensModel {XF16-55mmF2.8 R LM WR} ExposureTime 0.004 FNumber 8.0 ISO 125 FocalLength 23.0
			DateTimeOriginal {2026:08:14 21:43:00} GPSLatitudeRef N GPSLatitude {64.0 4.0 41.08} GPSLongitudeRef W GPSLongitude {16.0 13.0 51.6}}
	}
	# the second picture, taken a day after the first: Taken reads 14 - 16 Aug
	if {[string match *Fjallsárlón.png $path]} { return {DateTimeOriginal {2026:08:16 10:12:00}} }
	return [facts::exif_real $path]
}
proc facts::image_size {path} {
	if {[string match *Jökulsárlón.jpg $path]} { return {7728 5152} }
	return [facts::image_size_real $path]
}
proc at {s} { clock scan $s -format {%Y-%m-%d %H:%M} }

# a file as the boards have it: its size, dates and owner
proc item {path args} {
	set F [facts::of $path]
	dict set F owner ada
	dict set F group ada
	dict set F mode 0644
	dict set F btime [at {2026-08-14 21:43}]
	dict set F mtime [at {2026-08-15 10:02}]
	dict set F atime [at {2026-08-15 08:31}]
	return [dict merge $F $args]
}

set home $::env(HOME)
set iceland [file join $home Pictures Iceland]
set photo [file join $iceland $JPG]

# the folder's newest pictures at the mosaic's size: the fixture's are too small to
# cut a thumbnail from (the same five names, drawn by the fixture's own generator)
proc big_pictures {dir} {
	foreach {name kind} {Fjallsárlón.png photo-blue-1 Svínafell.png photo-ice-2 Vestrahorn.png photo-dusk-0 Þórsmörk.png photo-fern-1 Reynisfjara.png photo-ember-2} {
		exec tclsh8.6 [file join $::repo tests make-picture.tcl] $kind 180 180 [file join $dir $name]
	}
}

# the folder's numbers, as the boards have them (the count's own are the fixture's)
proc folder_counts {path} {
	facts::count $path {}
	while {$facts::W(busy)} { update }
	array set facts::W {files 198 dirs 16 bytes 3104226817 photos,n 164 photos,b 2400000000 videos,n 12 videos,b 640000000
		documents,n 6 documents,b 38000000 other,n 16 other,b 16000000}
}

# a source file for the text board: 214 lines of Rust
proc text_file {} {
	set dir [file join $::env(HOME) Projects atlas src]
	file mkdir $dir
	set f [file join $dir main.rs]
	if {1} {
		set fh [open $f w]; fconfigure $fh -encoding utf-8
		puts $fh "//! atlas: a tile server for offline maps"
		puts $fh "use std::io;"
		for {set i 3} {$i < 215} {incr i} { puts $fh [format {fn tile_%d(z: u8, x: u32, y: u32) -> u32 { z as u32 + x * %d + y }} $i $i] }
		close $fh
	}
	return $f
}

set panel {}
switch -- $scene {
	image {
		set F [item $photo typename {JPEG image} size 21604113]
		set panel [list 1052 100 792 [list $F] -w 380 -pad 24 -top 20 -preview 1 -footer pinned]
	}
	viewer {
		set F [item $photo typename {JPEG image} size 21604113]
		set panel [list 1010 72 800 [list $F] -w 330 -pad 24 -top 0 -preview 0 -footer follow -keys 76]
	}
	folder {
		big_pictures $iceland
		# Modified yesterday at 22:14, Created 2 Jun 2026, the drive as the boards have it
		set yesterday [expr {[clock scan [clock format [clock add [clock seconds] -1 day] -format %Y-%m-%d] -format %Y-%m-%d] + 22 * 3600 + 14 * 60}]
		set F [item $iceland btime [at {2026-06-02 18:20}] mtime $yesterday]
		set inspector::cache(drive,$iceland) {System 412000000000}
		folder_counts $iceland
		set panel [list 1052 100 792 [list $F] -w 380 -pad 24 -top 20 -preview 1 -footer pinned]
	}
	text {
		set F [item [text_file]]
		set panel [list 1052 100 792 [list $F] -w 380 -pad 24 -top 20 -preview 1 -footer pinned]
	}
	multi {
		big_pictures $iceland
		# the board's five: 812 MB together, modified 15 Aug to 2 Sep, one with no group access (Mixed)
		foreach {n size day mode} {Jökulsárlón.jpg 21604113 {2026-08-15 10:02} 0644 Fjallsárlón.png 205300264 {2026-08-16 10:12} 0644 Svínafell.png 198000000 {2026-08-20 18:40} 0644 Vestrahorn.png 201000000 {2026-08-28 09:30} 0644 Reynisfjara.png 186000000 {2026-09-02 16:05} 0604} {
			lappend items [item [file join $iceland $n] size $size mtime [at $day] mode $mode]
		}
		set panel [list 1052 100 792 $items -w 380 -pad 24 -top 20 -preview 1 -footer pinned]
	}
	edit-folder {
		big_pictures $iceland
		set F [item $iceland btime [at {2026-06-02 18:20}] mtime [at {2026-08-15 10:02}]]
		set inspector::cache(drive,$iceland) {System 412000000000}
		folder_counts $iceland
		set panel [list 1052 100 792 [list $F] -w 380 -pad 24 -top 20 -preview 1 -footer pinned]
		inspector::edit_begin $F
	}
	edit {
		set F [item $photo typename {JPEG image} size 21604113]
		set panel [list 1052 100 792 [list $F] -w 380 -pad 24 -top 20 -preview 1 -footer pinned]
		# the board's state: Group changed from read only, so its undo shows
		inspector::edit_begin $F
		inspector::pick g {read & write}
	}
	default { error "no scene $scene" }
}

# the desktop the panel sits on: the bar, as the Files window's column
proc inspector_frame {} {
	array set c [array get ui::c]
	ui::box 0 0 $ui::W $ui::H -fill $c(bar)
}
proc inspector_draw {} {
	set ui::W 1440
	set ui::H 900
	set ui::ox 0
	set ui::oy 0
	set ui::behind ""
	set ui::bx 0
	set ui::by 0
	ui::begin inspector inspector_frame
	lassign $::panel x y h items
	set rest [lrange $::panel 4 end]
	set end [inspector::draw $x $y $h $items {*}$rest]
	# the open dropdown's menu, drawn above the panel as the host does
	if {[dict size $page::menu]} { w::menu_draw $page::menu }
	ui::finish
	# the footer's bottom: the step checks it against the panel's foot (pinned) or
	# its content (follow)
	puts "inspector: $::scene footer ends at $end of a panel ending at [expr {$y + $h}]"
	# the place block's map tile: where it was drawn (x y w h), and the photo's pixels at the
	# ground beside it, the rounded corner, the pin and the middle (read from the photo, not the
	# screen, so the check does not depend on a capture)
	if {[llength $inspector::lastplace]} {
		lassign $inspector::lastplace mx my mw mh
		set pins {}
		foreach {k px py} [list ground [expr {$mx - 3}] [expr {$my - 3}] corner $mx $my \
			pin [expr {$mx + $mw / 2}] [expr {$my + round(0.65 * $mh)}] mid [expr {$mx + $mw / 4}] [expr {$my + $mh / 2}]] {
			lappend pins $k [join [$ui::img get $px $py] ,]
		}
		puts "inspector: $::scene map at $inspector::lastplace $pins"
	}
	set inspector::lastplace {}
	return $end
}

# edits redraw the panel
set inspector::redraw inspector_draw

after idle {
	inspector_draw
	update
}

if {[info exists ::env(RIBBON_PROPERTIES_SHOT)]} {
	after 600 {
		update
		exec import -window root $::env(RIBBON_PROPERTIES_SHOT)
		exit 0
	}
} elseif {[info exists ::env(RIBBON_PROPERTIES_EXIT)]} {
	after $::env(RIBBON_PROPERTIES_EXIT) { update; exit 0 }
}
