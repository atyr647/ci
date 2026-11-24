# main.tcl - Image Viewer: a picture in a window, drawn as the Viewer-Final boards
# (design/handoff/viewer-final.md; design/mockups/Viewer-Final-1-Stage, -2-Info,
# -4-Zoom). Tcl/Tk on the Properties ui model, so the Info panel is the same
# component Properties and Files draw (properties/inspector.tcl), not a fork.
#
#   ribbon-viewer [FILE]     FILE, and the pictures of its folder in Files' order;
#                            with no FILE, ~/Pictures
#
# Keys: Left and Right (previous, next), + and - (zoom), 0 (Fit), 1 (1:1), f (Fill),
# i (Info), Delete (to the trash), F11 (full screen), Ctrl+C (Copy), Alt+Return (Properties), Escape (closes the
# menu or the games list); on a video Space (play, pause) and m (mute). Drag the picture to pan.
#
# A video plays in mpv (video.tcl, Viewer-Final-5-Video); a Steam screenshot's folder is named
# by its game, with the games list (games.tcl, Viewer-Final-6-Steam).
#
# The window starts at the board's 1240 x 800 (fitted under the shell's bars) and resizes and
# maximises; the stage takes the room, the chrome keeps the board's sizes (viewer::resized).
#
# Tests: RIBBON_VIEWER_SCENE=tests/viewer-scene.tcl draws one board state at
# (100, 72) on a 1440 x 900 desktop; RIBBON_VIEWER_SHOT=FILE saves the screen and quits.

if {$tcl_platform(platform) eq "unix"} { encoding system utf-8 }
set appdir [file dirname [file normalize [info script]]]
proc find_dir {name file} {
	global appdir
	foreach d [list [file join $appdir .. .. $name] /usr/lib/ribbon/$name] {
		if {[file exists [file join $d $file]]} { return [file normalize $d] }
	}
	puts stderr "viewer: $name/$file was not found"; exit 1
}
set shelldir [find_dir shell raster.tcl]
set appearancedir [find_dir appearance ui.tcl]
set propsdir [find_dir properties inspector.tcl]
foreach d [list /usr/lib/ribbon [file dirname $shelldir]] { if {$d ni $auto_path} { lappend auto_path $d } }
catch {package require rbnalpha}
foreach f {text raster wall theme tooltip} { source -encoding utf-8 [file join $shelldir $f.tcl] }
namespace eval page {}
foreach f {ui dialogs bgpages} { source -encoding utf-8 [file join $appearancedir $f.tcl] }
foreach f {facts widgets pages jobs openwith inspector} { source -encoding utf-8 [file join $propsdir $f.tcl] }
foreach f {zoom nav stage toolbar info crop wall video games} { source -encoding utf-8 [file join $appdir $f.tcl] }
# Settings' game finder reads Steam's VDF files (libraryfolders, appmanifests): the games list names folders with it
foreach d [list [file join $appdir .. settings] /usr/lib/ribbon/settings] {
	if {[file exists [file join $d games.tcl]]} { source -encoding utf-8 [file join $d games.tcl]; break }
}

namespace eval viewer {
	variable win .v
	variable info 0       ;# the Info panel is open
	variable mode fit     ;# fit | fill | one | zoom
	variable s 1.0        ;# zoom: display px per file px
	variable cx 0.5       ;# zoom: the focus, fractions of the picture
	variable cy 0.5
	variable items {}     ;# the folder's media
	variable at -1        ;# the index of the picture shown
	variable file ""
	variable facts {}     ;# the Info panel's facts of FILE
	variable rect {0 0 0 0}
	variable sw 1240
	variable navbox {0 0}
	variable pan {}       ;# {x y cx cy} while dragging
	variable fs 0         ;# full screen
	variable dir ""
	variable steam {}     ;# a Steam screenshot: {root account appid}
	variable games {}     ;# the account's games (steam::games), read when the list opens
}

proc page::clicked_outside {} {}
proc viewer::noop args {}

# A pointer or key action: hosts get the draw.
proc viewer::redraw args { viewer::draw }
proc viewer::applied {path errs} {
	variable items; variable dir
	set items [nav::items $dir]
	set at [nav::index $items $path]
	if {$at < 0} { set at 0 }
	viewer::show $at
}

# Show item I of the folder (the title, the stage, the Info facts).
proc viewer::show {i} {
	variable items; variable at; variable file; variable mode; variable s; variable cx; variable cy; variable facts
	# the folder emptied (its last item deleted): a video stops
	if {![llength $items]} { if {$video::on} { video::close; viewer::draw }; return }
	set at [expr {max(0, min([llength $items] - 1, $i))}]
	set file [lindex $items $at]
	video::close
	set bar::menu 0
	stage::load $file
	if {$nav::play && [video::is $file]} { video::open $file }
	viewer::steam_of $file
	set mode fit; set s 1.0; set cx 0.5; set cy 0.5
	set facts {}
	catch {set facts [facts::of $file]}
	viewer::draw
}

# Whether FILE is a Steam screenshot: then its game names the title bar.
proc viewer::steam_of {file} {
	variable steam; variable games
	set w [steam::where $file]
	if {![llength $w]} { set steam {}; set gamelist::open 0; return }
	if {![llength $steam] || [dict get $steam root] ne [dict get $w root] || [dict get $steam account] ne [dict get $w account]} {
		set games [steam::games [dict get $w root] [dict get $w account]]
	}
	set steam $w
}

# The game button's name and cover.
proc viewer::game {} {
	variable steam; variable games
	if {![llength $steam]} { return {} }
	set name [dict get $steam appid]
	foreach g $games { if {[dict get $g appid] eq [dict get $steam appid]} { set name [dict get $g name] } }
	list $name [steam::cover [dict get $steam root] [dict get $steam appid]]
}

# Show ITEMS (a game's screenshots), at I.
proc viewer::open_items {list i} {
	variable items; variable dir
	if {![llength $list]} return
	set items $list
	set dir [file dirname [lindex $list 0]]
	viewer::show $i
}

# Show in Files: Files opens on the folder with the file chosen (ribbon-files FILE).
proc viewer::show_in_files {args} {
	variable file
	set gamelist::open 0
	if {$file eq ""} return
	catch {exec ribbon-files $file </dev/null >/dev/null 2>/dev/null &}
	viewer::draw
}

# Copy: the picture onto the clipboard (wl-copy, as PNG: what other apps paste), a video as its file (text/uri-list).
proc viewer::copy {args} {
	variable file
	if {$file eq "" || [auto_execok wl-copy] eq ""} return
	if {[video::is $file]} {
		catch {exec wl-copy --type text/uri-list "file://[nav::escape [file normalize $file]]" </dev/null >/dev/null 2>/dev/null &}
		return
	}
	set png $file
	if {[string tolower [file extension $file]] ne ".png"} {
		set png [stage::tmp png]
		if {[catch {exec ffmpeg -nostdin -v error -y -i $file -frames:v 1 $png </dev/null >/dev/null 2>/dev/null}] || ![file exists $png]} return
	}
	catch {exec wl-copy --type image/png <$png >/dev/null 2>/dev/null &}
	if {$png ne $file} { after 5000 [list catch [list file delete $png]] }
}

# Properties (the menu, Alt+Return): the Properties window on the file shown (ribbon-properties PATH), as Files'.
proc viewer::properties {args} {
	variable file
	set gamelist::open 0
	if {$file eq ""} return
	catch {exec ribbon-properties [file normalize $file] </dev/null >/dev/null 2>/dev/null &}
	viewer::draw
}

# Copy path: the file's path as text, on the clipboard.
proc viewer::copy_path {args} {
	variable file; variable win
	if {$file eq ""} return
	clipboard clear -displayof $win
	clipboard append -displayof $win -- [file normalize $file]
}

# The wheel (D -1 up, 1 down): over something drawn to scroll (the games list, ui::wheel) it scrolls that; else up
# zooms in and down out.
proc viewer::wheel {x y d} {
	foreach h $ui::wheels {
		lassign $h x0 y0 x1 y1
		if {$x >= $x0 && $x < $x1 && $y >= $y0 && $y < $y1} { ui::scroll $x $y $d; return }
	}
	viewer::zstep [expr {-$d}]
}

# Previous (DIR -1) or next (DIR 1) picture, wrapping round the folder.
proc viewer::go {dir args} {
	variable items; variable at
	if {[llength $items] < 2} return
	viewer::show [nav::step $at $dir [llength $items]]
}

proc viewer::set_mode {m args} {
	variable mode; variable s; variable cx; variable cy
	set size [stage::size]
	if {$size eq "" || $video::on} return
	lassign $size nw nh
	set mode $m
	if {$m eq "fit" || $m eq "fill" || $m eq "one"} { set cx 0.5; set cy 0.5 }
	set s [zoom::scale $m $s [zoom::sw $::viewer::info] $nw $nh]
	viewer::draw
}

# One step in or out of the zoom, keeping the focus.
proc viewer::zstep {dir args} {
	variable mode; variable s
	set size [stage::size]
	if {$size eq "" || $video::on} return
	lassign $size nw nh
	set cur [zoom::scale $mode $s [zoom::sw $::viewer::info] $nw $nh]
	set s [zoom::step $cur $dir]
	set mode zoom
	viewer::draw
}

proc viewer::toggle_info {args} {
	variable info
	set info [expr {!$info}]
	viewer::draw
}

proc viewer::fullscreen {args} {
	variable win; variable fs
	set fs [expr {!$fs}]
	catch {wm attributes $win -fullscreen $fs}
	viewer::draw
}

# A click on the navigator centres the view on the point clicked.
proc viewer::nav_click {x y args} {
	variable navbox; variable cx; variable cy; variable mode
	set tx [expr {($x - [lindex $navbox 0]) / 54.0}]
	set ty [expr {($y - [lindex $navbox 1]) / 36.0}]
	set cx [expr {max(0.0, min(1.0, $tx))}]; set cy [expr {max(0.0, min(1.0, $ty))}]
	if {$mode eq "fit"} { set mode zoom }
	viewer::draw
}

# Drag the picture (zoomed): the focus moves against the pointer.
proc viewer::pan_start {x y args} {
	variable pan; variable mode; variable cx; variable cy
	if {$mode eq "fit"} { set pan {}; return }
	set pan [list $x $y $cx $cy]
}
proc viewer::pan_move {x y args} {
	variable pan; variable rect; variable cx; variable cy
	if {$pan eq ""} return
	lassign $pan x0 y0 cx0 cy0
	lassign $rect - - pw ph
	if {$pw > 0 && $ph > 0} {
		set cx [expr {max(0.0, min(1.0, $cx0 - ($x - $x0) / double($pw)))}]
		set cy [expr {max(0.0, min(1.0, $cy0 - ($y - $y0) / double($ph)))}]
	}
	viewer::draw
}
proc viewer::pan_end {x y args} { variable pan; set pan {} }

# Rotate (the photo toolbar): a quarter turn clockwise, saved over the file (crop::rotate_file).
proc viewer::rotate {args} {
	variable file
	crop::rotate_file $file
}

# Delete: the picture to the trash, then the next one in the folder.
proc viewer::trash {args} {
	variable items; variable at; variable file
	if {$file eq ""} return
	if {[nav::bin $file] eq ""} return
	set items [lreplace $items $at $at]
	viewer::show [expr {$at < [llength $items] ? $at : [llength $items] - 1}]
}

# A key: the crop view and the Info edit view take what they need first.
proc viewer::input {sym char state} {
	if {$::crop::on} return
	if {[vinfo::key $sym $char $state]} return
	if {$sym eq "Escape" && ($bar::menu || $gamelist::open)} { set bar::menu 0; set gamelist::open 0; viewer::draw; return }
	if {[video::key_press $sym]} return
	if {$sym in {c C} && ($state & 4)} { viewer::copy; return }
	if {$sym in {Return KP_Enter} && ($state & 8)} { viewer::properties; return }
	viewer::key $sym
}

proc viewer::key {k} {
	switch -- $k {
		Left { viewer::go -1 }
		Right { viewer::go 1 }
		plus - equal - KP_Add { viewer::zstep 1 }
		minus - KP_Subtract { viewer::zstep -1 }
		0 { viewer::set_mode fit }
		1 { viewer::set_mode one }
		f { viewer::set_mode fill }
		i { viewer::toggle_info }
		Delete { viewer::trash }
		F11 { viewer::fullscreen }
	}
}

# The viewer draws its own rounded frame (the 16 px corners and the ring) only when it is not framed by labwc: a
# framed window is square to its edges, and its corners are the compositor's. A scene always draws the rounded one.
proc viewer::own_frame {} {
	expr {[info exists ::env(RIBBON_VIEWER_SCENE)] || [info commands ::rbn::framed] eq "" || ![::rbn::framed]}
}

# The window's static body: the stage (§d2) with its 16 px corners and its ring, or a square fill when framed.
proc viewer::frame {} {
	if {![viewer::own_frame]} {
		ui::box 0 0 $zoom::WW $zoom::WH -fill $ui::c(d2)
		return
	}
	ui::box 0 0 $zoom::WW $zoom::WH -fill $ui::c(d2) -radius 16 -ring [list $ui::c(border) 1]
}

# Corners outside the 16 px arc are see-through (the Info panel is square). Only an own-frame window has see-through
# corners.
proc viewer::corners {} {
	if {![viewer::own_frame]} return
	set W $zoom::WW; set H $zoom::WH
	foreach {ox oy cxp cyp} [list 0 0 16 16  [expr {$W - 16}] 0 [expr {$W - 16}] 16  0 [expr {$H - 16}] 16 [expr {$H - 16}]  [expr {$W - 16}] [expr {$H - 16}] [expr {$W - 16}] [expr {$H - 16}]] {
		for {set j 0} {$j < 16} {incr j} {
			for {set i 0} {$i < 16} {incr i} {
				set px [expr {$ox + $i}]; set py [expr {$oy + $j}]
				set dx [expr {$px + 0.5 - $cxp}]; set dy [expr {$py + 0.5 - $cyp}]
				if {$dx * $dx + $dy * $dy > 256} { $ui::img transparency set $px $py 1 }
			}
		}
	}
}

# Draw the window: the picture, the title bar, the Info panel, the arrows and the toolbar.
proc viewer::draw {} {
	variable info; variable mode; variable s; variable cx; variable cy
	variable items; variable at; variable file; variable facts; variable rect; variable sw
	set W $zoom::WW; set H $zoom::WH; set TB $zoom::TB
	set sw [zoom::sw $info]
	set ::viewer::sw $sw
	set bar::tips {}
	ui::begin [list frame $W $H] viewer::frame
	if {$crop::on} { crop::draw; viewer::corners; ui::finish; return }
	# the stage's hit for panning comes first, so the chrome above it wins
	if {$mode ne "fit"} { ui::hit 0 $TB $sw [expr {$H - $TB}] viewer::pan_start viewer::pan_move viewer::pan_end }
	set size [stage::size]
	if {$size ne ""} {
		lassign $size nw nh
		set rect [zoom::rect $mode $s $cx $cy $info $nw $nh]
		lassign $rect L T pw ph
		set v [stage::view $L $T $pw $ph 0 $TB $sw [expr {$H - $TB}]]
		if {$v ne ""} { lassign $v p x y; $ui::img copy $p -to $x $y }
		# a video: mpv's window over the picture, unless the menu is drawn over it (video::freeze)
		if {$video::on && !$bar::menu} { video::place $L $T $pw $ph }
	}
	set name [expr {$file eq "" ? "" : [file tail $file]}]
	set count [expr {[llength $items] ? "[expr {$at + 1}] of [llength $items]" : ""}]
	bar::titlebar $name $count [viewer::when] $info $sw [viewer::game]
	if {$info && $file ne ""} {
		vinfo::draw $sw $H $facts
	}
	if {$video::on} {
		if {[llength $items] > 1} { bar::arrows $sw }
		video::toolbar $sw
	} elseif {$mode eq "fit"} {
		if {[llength $items] > 1} { bar::arrows $sw }
		bar::toolbar $sw [list \
			[list icon zoomout {viewer::zstep -1}] [list text Fit i13s] [list icon zoomin {viewer::zstep 1}] [list div] \
			[list icon rotate viewer::rotate] [list icon crop crop::start] [list icon expand viewer::fullscreen] [list div] \
			[list icon trash viewer::trash]] 6 6
	} else {
		bar::toolbar $sw [list [list nav] [list div] [list icon zoomout {viewer::zstep -1}] \
			[list text [zoom::label [viewer::cur_scale $sw]] i13s] [list icon zoomin {viewer::zstep 1}] \
			[list div] [list seg] [list spacer]] 4 6
	}
	if {$bar::menu} { bar::menu_draw $sw }
	if {$gamelist::open && [llength $::viewer::steam]} {
		gamelist::draw $::viewer::games [dict get $::viewer::steam root] [dict get $::viewer::steam appid]
	}
	vinfo::overlay
	viewer::corners
	ui::finish
}

# A new window size (resized, maximised, full screen): the canvas follows at once, and the window is drawn again for
# it once the sizes stop coming (a drag sends many). The frame drawn for the old size is let go.
proc viewer::resized {w h} {
	variable win; variable relayout
	if {$w < 2 || $h < 2 || ($w == $zoom::WW && $h == $zoom::WH)} return
	set zoom::WW $w; set zoom::WH $h
	set ui::W $w; set ui::H $h
	$win.c configure -width $w -height $h
	place $win.c -x 0 -y 0 -width $w -height $h
	if {[info exists relayout]} { after cancel $relayout }
	set relayout [after 40 viewer::relayout]
}
proc viewer::relayout {} {
	variable relayout
	unset -nocomplain relayout
	# ui.tcl keeps each key's frame; the old sizes' are not drawn again
	foreach k [array names ::ui::frames] {
		if {[lindex $k 0 0] eq "frame" && [lrange [lindex $k 0] 1 2] ne [list $zoom::WW $zoom::WH]} {
			catch {image delete $::ui::frames($k)}
			unset ::ui::frames($k)
		}
	}
	if {$crop::on} { crop::update } else { viewer::draw }
}

# The display scale of the open picture now, for the toolbar's label.
proc viewer::cur_scale {sw} {
	variable mode; variable s
	set size [stage::size]
	if {$size eq ""} { return 1.0 }
	lassign $size nw nh
	return [zoom::scale $mode $s $sw $nw $nh]
}

# The date and time the picture was taken: EXIF DateTimeOriginal; a video's container creation time; a Steam
# screenshot's name; else the file's mtime.
proc viewer::when {} {
	variable file; variable facts; variable steam; variable whencache
	if {$file eq ""} { return {"" ""} }
	set key [list $file [expr {[catch {file mtime $file} m] ? "" : $m}]]
	if {[info exists whencache] && [lindex $whencache 0] eq $key} { return [lindex $whencache 1] }
	set t ""
	if {[video::is $file]} { set t [video::created $file] }
	if {$t eq "" && [llength $steam]} { set t [steam::taken $file] }
	if {$t eq ""} {
		catch {
			set ex [facts::exif $file]
			if {[dict exists $ex DateTimeOriginal]} { set t [clock scan [dict get $ex DateTimeOriginal] -format {%Y:%m:%d %H:%M:%S}] }
		}
	}
	if {$t eq ""} { catch {set t [file mtime $file]} }
	if {$t eq ""} { return {"" ""} }
	set day [regsub {\s+} [clock format $t -format {%a %e %b}] { }]
	set whencache [list $key [list [string trim $day] [clock format $t -format {%H:%M}]]]
	return [lindex $whencache 1]
}

proc viewer::main {} {
	variable win; variable dir; variable items; variable at; variable file
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}]
	set cache [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$home/.cache"}]
	set scene [info exists ::env(RIBBON_VIEWER_SCENE)]
	theme::load
	raster::init [file join $cache ribbon viewer]
	ui::fonts
	page::chrome
	set what [lindex $::argv 0]
	if {$what eq "" && !$scene} { set what [file join $home Pictures] }
	if {[file isdirectory $what]} { set dir [file normalize $what]; set file "" }
	if {[file isfile $what]} { set file [file normalize $what]; set dir [file dirname $file] }
	wm withdraw .
	if {$scene} {
		toplevel $win -class RibbonImageViewer -borderwidth 0 -highlightthickness 0
		wm overrideredirect $win 1
		wm geometry $win [format {%dx%d+%d+%d} $zoom::WW $zoom::WH 100 72]
	} else {
		# the stage takes what is left under the bars when labwc frames the window (rbn::fit)
		if {[info commands ::rbn::fit] ne ""} { set zoom::WH [rbn::fit $zoom::WH] }
		if {[info commands ::rbn::appwindow] ne ""} {
			if {[rbn::appwindow $win RibbonImageViewer $zoom::WW $zoom::WH -fill $ui::c(d2)]} { set ui::argbwin $win }
		} else {
			toplevel $win -class RibbonImageViewer -borderwidth 0 -highlightthickness 0 -background $ui::c(d2)
		}
		wm title $win "Image Viewer"
		wm iconname $win "Image Viewer"
		# the window resizes and maximises (viewer::resized): the title bar, the toolbar, the edge arrows and the Info
		# panel keep their board sizes and the stage takes the rest. The board's size, fitted under the bars, is where
		# it starts and the least it can be.
		wm minsize $win $zoom::WW $zoom::WH
		wm geometry $win [format {%dx%d} $zoom::WW $zoom::WH]
	}
	# rbn::appwindow has already made $win.c; a scene's plain toplevel has none yet
	if {![winfo exists $win.c]} {
		canvas $win.c -width $zoom::WW -height $zoom::WH -highlightthickness 0 -borderwidth 0 -background $ui::c(d2)
	}
	$win configure -width $zoom::WW -height $zoom::WH
	place $win.c -x 0 -y 0 -width $zoom::WW -height $zoom::WH
	set ui::cv $win.c
	set ui::W $zoom::WW; set ui::H $zoom::WH
	set ui::ox 0; set ui::oy 0
	bind $win.c <ButtonPress-1> {ui::press %x %y}
	bind $win.c <B1-Motion> {ui::motion %x %y}
	bind $win.c <ButtonRelease-1> {ui::release %x %y}
	bind $win.c <MouseWheel> {viewer::wheel %x %y [expr {%D > 0 ? -1 : 1}]}
	bind $win.c <Button-4> {viewer::wheel %x %y -1}
	bind $win.c <Button-5> {viewer::wheel %x %y 1}
	bind $win <KeyPress> {viewer::input %K %A %s}
	bind $win <Configure> {if {"%W" eq $::viewer::win} {viewer::resized %w %h}}
	bind $win <Destroy> {if {"%W" eq $::viewer::win} {video::close 1; video::cleanup}}
	# the icon-only buttons: lit under the pointer, their names as tooltips (with rbnalpha's popups)
	bind $win.c <Motion> {+bar::hover %x %y}
	bind $win.c <Leave> {+bar::hover -1 -1}
	if {[info commands ::rbn::popup] ne ""} { tip::attach $win.c bar::tip_at }
	set nav::play [video::available]
	video::load_conf
	set inspector::redraw viewer::redraw
	set inspector::done viewer::applied
	if {$file ne ""} { set items [nav::items $dir]; set at [nav::index $items $file]; if {$at < 0} { set items [linsert $items 0 $file]; set at 0 } }
	if {$dir ne "" && $file eq ""} { set items [nav::items $dir]; set at 0 }
	if {$scene} {
		uplevel #0 [list source -encoding utf-8 $::env(RIBBON_VIEWER_SCENE)]
	} else {
		if {$file ne ""} { viewer::show $at } else { viewer::draw }
	}
	if {[info exists ::env(RIBBON_VIEWER_SHOT)]} {
		update
		after 300 {
			catch {exec import -window root -crop "$::zoom::WW\x$::zoom::WH+100+72" $::env(RIBBON_VIEWER_SHOT)}
			exit 0
		}
	}
	focus -force $win
}

viewer::main
