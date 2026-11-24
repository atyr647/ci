# crop.tcl - Crop and rotate (Viewer-Final-8-Crop): the picture with its crop frame
# (thirds, corner brackets, the outside dimmed), the toolbar (aspect, rotate, flip,
# Straighten) and the title bar's Revert, Save as copy and Save.
#
# The edit is a list of steps: quarter turns (clockwise), a horizontal flip, and
# Straighten (a rotation in degrees, clockwise positive, auto-cropped so no corner of the
# background shows); then the crop frame, as fractions of the turned, straightened picture. The preview runs those steps with ffmpeg on the
# working copy, at the stage's size. Save runs the same steps on the original file at
# full size. Tk cannot write JPEG and turning or rotating a 40 MP picture pixel by pixel
# in Tcl is far too slow, so ffmpeg (the viewer's helper) does the pixels. Save keeps the
# EXIF: the original's Exif segment, with Orientation set to 1, since the pixels are
# now upright.
#
#   crop::start    start on the open picture. JPEG, PNG, BMP and a one-page TIFF are written back by Save; the
#                  others (WebP, AVIF, GIF, a TIFF of several pages) only by Save as copy, the one action
#                  (Viewer-Final-10-Crop-Copy), as a JPEG, or a PNG when the picture has transparency
#   crop::rotate_file FILE   the photo toolbar's Rotate: a quarter turn clockwise, saved over FILE; on a picture
#                  Save cannot write, the crop view opens turned, to be saved as a copy
#   crop::draw     the crop view, between ui::begin and ui::finish (viewer::draw)

namespace eval crop {
	variable on 0
	variable writable {.jpg .jpeg .png .bmp .tif .tiff}   ;# what Save writes back (ffmpeg's own encoders)
	variable aspect orig     ;# free | orig | 169 | 11
	variable rot 0           ;# quarter turns, clockwise, 0 to 3
	variable flip 0          ;# a horizontal flip, after the turns
	variable ang 0.0         ;# Straighten, degrees: clockwise is positive
	variable fr {0.065 0.065 0.935 0.935}   ;# the frame x0 y0 x1 y1, fractions of the turned picture
	variable TW 1            ;# the turned picture's size, in working-copy px
	variable TH 1
	variable box {0 0 1 1}   ;# the picture on the stage: L T W H
	variable prev ""         ;# the preview photo, BOX's size
	variable drag {}         ;# {corner I} or {move X Y FR} while the pointer is down
	variable sl {0 1}        ;# the slider's track: x and width
	variable sliding 0
	variable P
	array set P {
		rotl   {M1 4v6h6 M3.51 15a9 9 0 1 0 2.13-9.36L1 10}
		rotate {M23 4v6h-6 M20.49 15a9 9 0 1 1-2.12-9.36L23 10}
		flip   {M8 3H5a2 2 0 0 0-2 2v14c0 1.1.9 2 2 2h3 M16 3h3a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-3 M12 20v2 M12 14v2 M12 8v2 M12 2v2}
		undo   {M3 7v6h6 M21 17a9 9 0 0 0-15-6.7L3 13}
		copy   {M9 9h11v11H9z M5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1}
		check  {M20 6L9 17l-5-5}
	}
}

# ---- the steps ----------------------------------------------------------------------

# The steps as ffmpeg filters: the turns, the flip, then Straighten. Straighten auto-crops: the picture is rotated
# in its own size, then cut to the largest upright rectangle of its aspect that holds no corner of the background
# (crop::fill), so no black corner shows; 2 px more come off each side, where the rotation blends the edge.
proc crop::turn_filters {rot flip ang} {
	set f {}
	switch -- $rot {
		1 { lappend f transpose=1 }
		2 { lappend f transpose=1 transpose=1 }
		3 { lappend f transpose=2 }
	}
	if {$flip} { lappend f hflip }
	if {$ang != 0} {
		set a [expr {abs($ang) * acos(-1) / 180.0}]
		lappend f [format {rotate=%.6f:c=black:ow=iw:oh=ih} [expr {$ang * acos(-1) / 180.0}]]
		set k [format {(%.6f+%.6f*max(iw/ih,ih/iw))} [expr {cos($a)}] [expr {sin($a)}]]
		lappend f "crop=w='2*trunc((iw/$k-4)/2)':h='2*trunc((ih/$k-4)/2)'"
	}
	return $f
}

# How much Straighten by ANG degrees cuts a W x H picture by on each axis (1 when it is not straightened): the
# rotated picture holds an upright W/k x H/k rectangle at its centre.
proc crop::fill {ang w h} {
	set a [expr {abs($ang) * acos(-1) / 180.0}]
	expr {cos($a) + sin($a) * max(double($w) / $h, double($h) / $w)}
}

# The size Save writes for a NW x NH picture: ROT quarter turns, Straighten by ANG degrees (its cut, as
# turn_filters asks ffmpeg for it) and the frame FR (ffmpeg's even sizes), as "W × H" for the title bar.
proc crop::out_size {nw nh rot ang fr} {
	if {$rot % 2} { lassign [list $nh $nw] nw nh }
	set w [expr {double($nw)}]; set h [expr {double($nh)}]
	if {$ang != 0} {
		set a [expr {abs($ang) * acos(-1) / 180.0}]
		set k [expr {[format %.6f [expr {cos($a)}]] + [format %.6f [expr {sin($a)}]] * max($w / $h, $h / $w)}]
		set w [expr {2 * int(($w / $k - 4) / 2)}]; set h [expr {2 * int(($h / $k - 4) / 2)}]
	}
	if {$fr ne {0 0 1 1}} {
		lassign $fr x0 y0 x1 y1
		set w [expr {2 * int($w * [format %.6f [expr {$x1 - $x0}]] / 2)}]
		set h [expr {2 * int($h * [format %.6f [expr {$y1 - $y0}]] / 2)}]
	}
	return "[expr {int($w)}] \u00d7 [expr {int($h)}]"
}

# The working copy's size after the turns (a quarter turn swaps the sides).
proc crop::turned_size {} {
	variable rot
	set w [dict get $::stage::src ww]; set h [dict get $::stage::src wh]
	if {$rot % 2} { return [list $h $w] }
	return [list $w $h]
}

# The aspect's target as a pixel width over height, or "" for Free.
proc crop::target {} {
	variable aspect; variable TW; variable TH
	switch -- $aspect {
		orig { return [expr {double($TW) / $TH}] }
		169 { return [expr {16 / 9.0}] }
		11 { return 1.0 }
	}
	return ""
}

proc crop::inset {} {
	variable fr
	set fr {0.065 0.065 0.935 0.935}
}

# The picture's place on the stage: 84 px under the title bar, an 84 px foot, the
# 76 px side gutters; centred. Remembers the box as L T W H.
proc crop::place {} {
	variable box; variable TW; variable TH
	set W $::zoom::WW; set H $::zoom::WH
	set top [expr {$::zoom::TB + 16}]
	set avail_h [expr {$H - $top - 84}]
	set avail_w [expr {$W - 2 * $::zoom::GUT}]
	set a [expr {double($TW) / $TH}]
	set ph $avail_h; set pw [expr {$ph * $a}]
	if {$pw > $avail_w} { set pw $avail_w; set ph [expr {$pw / $a}] }
	set L [expr {round(($W - $pw) / 2.0)}]
	set T [expr {round($top + ($avail_h - $ph) / 2.0)}]
	set box [list $L $T [expr {round($pw)}] [expr {round($ph)}]]
}

# The preview: the steps run by ffmpeg on the working copy, at the box's size.
proc crop::preview {} {
	variable prev; variable box; variable rot; variable flip; variable ang
	lassign $box L T pw ph
	if {$prev ne ""} { catch {image delete $prev} }
	set prev ""
	if {![dict size $::stage::src]} return
	set vf [turn_filters $rot $flip $ang]
	lappend vf "scale=$pw:$ph:flags=bicubic"
	set out [::stage::tmp png]
	set cmd [list ffmpeg -nostdin -v error -y -i [dict get $::stage::src work] -frames:v 1 -vf [join $vf ,] $out]
	if {![catch {exec {*}$cmd </dev/null >/dev/null 2>@1}] && [file exists $out]} {
		set prev [image create photo -file $out]
	}
	catch {file delete $out}
}

# Lay out and preview again, then redraw.
proc crop::update {} {
	crop::place
	crop::preview
	viewer::draw
}

# ---- opening and the tools ------------------------------------------------------------

# Start on the open picture, with the board's defaults.
proc crop::start {args} {
	variable on; variable aspect; variable rot; variable flip; variable ang; variable TW; variable TH
	set file $::viewer::file
	if {$file eq "" || ![dict size $::stage::src] || ([info exists ::video::on] && $::video::on)} return
	set aspect orig; set rot 0; set flip 0; set ang 0.0
	set ::viewer::info 0   ;# the board's crop view has the stage to itself
	lassign [crop::turned_size] TW TH
	crop::inset
	set on 1
	crop::update
}

proc crop::set_aspect {a} {
	variable aspect; variable fr; variable TW; variable TH
	set aspect $a
	set t [crop::target]
	if {$t ne ""} {
		# the largest frame of that aspect, centred on the current one
		lassign $fr x0 y0 x1 y1
		set w [expr {$x1 - $x0}]; set h [expr {$y1 - $y0}]
		if {($w * $TW) / ($h * $TH) > $t} { set w [expr {$h * $TH * $t / $TW}] } else { set h [expr {$w * $TW / ($TH * $t)}] }
		set cx [expr {($x0 + $x1) / 2.0}]; set cy [expr {($y0 + $y1) / 2.0}]
		set fr [list [expr {$cx - $w / 2.0}] [expr {$cy - $h / 2.0}] [expr {$cx + $w / 2.0}] [expr {$cy + $h / 2.0}]]
	}
	viewer::draw
}

# A quarter turn, CW (+1) or CCW (-1). After a flip the turns run the other way round,
# so the picture turns as the eye sees it.
proc crop::turn {dir} {
	variable rot; variable flip; variable TW; variable TH
	set rot [expr {(($rot + ($flip ? -$dir : $dir)) % 4 + 4) % 4}]
	lassign [crop::turned_size] TW TH
	crop::inset
	crop::update
}

# A horizontal flip, after the turns: a clockwise Straighten turns the other way.
proc crop::flip {args} {
	variable flip; variable ang; variable fr
	set flip [expr {!$flip}]
	set ang [expr {$ang == 0 ? 0.0 : -$ang}]
	lassign $fr x0 y0 x1 y1
	set fr [list [expr {1 - $x1}] $y0 [expr {1 - $x0}] $y1]
	crop::update
}

# Revert: the edit is dropped and the photo toolbar returns.
proc crop::revert {args} {
	variable on
	set on 0
	viewer::draw
}

# Save (over the file) or Save as copy: the file is written, then the viewer shows it.
proc crop::save {mode args} {
	variable rot; variable flip; variable ang; variable fr
	set file $::viewer::file
	if {$mode eq "copy"} { set dst [crop::copy_name $file] } elseif {[crop::can_write $file]} { set dst $file } else { return 0 }
	if {![crop::write $file $dst $rot $flip $ang $fr]} { return 0 }
	set ::crop::on 0
	viewer::applied $dst {}
	return 1
}

# The name of a copy of FILE: "name (edited).ext", then "name (edited 2).ext", "(edited 3)" while those exist.
proc crop::copy_name {file} {
	set dir [file dirname $file]
	set stem [file rootname [file tail $file]]
	set ext [crop::copy_ext $file]
	set dst [file join $dir "$stem (edited)$ext"]
	set k 2
	while {[file exists $dst]} { set dst [file join $dir "$stem (edited $k)$ext"]; incr k }
	return $dst
}

# The copy's extension: the file's own when Save writes that format back; else .jpg, or .png for a picture with an
# alpha channel (ffprobe's pixel format), so its transparency is kept.
proc crop::copy_ext {file} {
	if {[crop::can_write $file]} { return [file extension $file] }
	if {[auto_execok ffprobe] ne "" && ![catch {exec ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt \
			-of default=nw=1:nk=1 $file 2>/dev/null} pf] && [regexp {^(yuva|rgba|bgra|argb|abgr|ya|gbrap|pal8)} [string trim $pf]]} {
		return .png
	}
	return .jpg
}

# Write FILE through the steps (ROT quarter turns, FLIP, Straighten ANG, then the frame FR) into DST, at full size,
# through a hidden part file next to it, so a failed write leaves DST as it was. A JPEG keeps its EXIF with the
# Orientation at 1. Returns 1 when DST was written.
proc crop::write {file dst rot flip ang fr} {
	set dir [file dirname $dst]
	set stem [file rootname [file tail $dst]]
	set ext [string tolower [file extension $dst]]
	set tmp [file join $dir ".$stem.part-[pid]$ext"]
	lassign $fr x0 y0 x1 y1
	set vf [turn_filters $rot $flip $ang]
	if {$fr ne {0 0 1 1}} {
		# whole even sizes and offsets, so the chroma planes stay whole
		lappend vf [format {crop=w='2*trunc(iw*%.6f/2)':h='2*trunc(ih*%.6f/2)':x='2*trunc(iw*%.6f/2)':y='2*trunc(ih*%.6f/2)'} \
			[expr {$x1 - $x0}] [expr {$y1 - $y0}] $x0 $y0]
	}
	if {![llength $vf]} { lappend vf null }
	switch -- $ext {
		.jpg - .jpeg { set enc {-q:v 2} }
		.png { set enc {-c:v png} }
		default { set enc {} }
	}
	set cmd [list ffmpeg -nostdin -v error -y -i $file -vf [join $vf ,] -frames:v 1 {*}$enc $tmp]
	if {[catch {exec {*}$cmd </dev/null >/dev/null 2>@1}] || ![file exists $tmp]} {
		catch {file delete -force $tmp}
		return 0
	}
	if {$ext in {.jpg .jpeg} && [string tolower [file extension $file]] in {.jpg .jpeg}} { catch {crop::keep_exif $file $tmp} }
	file rename -force $tmp $dst
	return 1
}

# Whether Save can write FILE back: a format of crop::writable, and for a TIFF one page only (ffmpeg reads and
# writes the first page, so a scan's or a fax's other pages would be lost). A TIFF whose pages cannot be read is
# not written either.
proc crop::can_write {file} {
	set ext [string tolower [file extension $file]]
	if {$file eq "" || $ext ni $::crop::writable} { return 0 }
	if {$ext ni {.tif .tiff}} { return 1 }
	if {[catch {crop::tiff_pages $file} n]} { return 0 }
	expr {$n == 1}
}

# How many pages (images in the IFD chain) a TIFF has: 1, or 2 for "more than one". Errors on anything but a
# classic TIFF (a BigTIFF too).
proc crop::tiff_pages {file} {
	set fh [::open $file rb]
	try {
		set head [::read $fh 8]
		switch -- [string range $head 0 1] {
			II { set s s; set i i } MM { set s S; set i I }
			default { error "not a TIFF" }
		}
		binary scan $head @2${s}u${i}u magic off
		if {$magic != 42 || $off < 8} { error "not a classic TIFF" }
		seek $fh $off
		if {[binary scan [::read $fh 2] ${s}u n] != 1} { error "no IFD" }
		seek $fh [expr {$off + 2 + 12 * $n}]
		if {[binary scan [::read $fh 4] ${i}u next] != 1} { error "no IFD link" }
		return [expr {$next == 0 ? 1 : 2}]
	} finally {
		::close $fh
	}
}

# The photo toolbar's Rotate: the picture turned a quarter clockwise and saved over the file (crop::write, so a JPEG
# keeps its EXIF with the Orientation at 1). Only what Save writes (crop::can_write). Returns 1 when it was saved.
proc crop::rotate_file {file} {
	if {![crop::can_write $file]} {
		crop::start
		if {$::crop::on} { crop::turn 1 }
		return 0
	}
	if {![crop::write $file $file 1 0 0 {0 0 1 1}]} { return 0 }
	viewer::applied $file {}
	return 1
}

# ---- EXIF --------------------------------------------------------------------------

proc crop::byte {d i} { scan [string index $d $i] %c }

# An unsigned N-byte value at I, little-endian when LE.
proc crop::uint {d i n le} {
	set v 0
	for {set k 0} {$k < $n} {incr k} {
		set sh [expr {8 * ($le ? $k : $n - 1 - $k)}]
		set v [expr {$v | ([crop::byte $d [expr {$i + $k}]] << $sh)}]
	}
	return $v
}

# The APP1 Exif segment of a JPEG, marker included, or "" (D is its first bytes).
proc crop::exif_segment {d} {
	if {[string range $d 0 1] ne "\xff\xd8"} { return "" }
	set n [string length $d]
	set i 2
	while {$i + 4 <= $n} {
		if {[crop::byte $d $i] != 0xff} { return "" }
		set m [crop::byte $d [expr {$i + 1}]]
		if {$m == 0xda || $m == 0xd9} { return "" }
		set len [crop::uint $d [expr {$i + 2}] 2 0]
		if {$m == 0xe1 && [string range $d [expr {$i + 4}] [expr {$i + 9}]] eq "Exif\x00\x00"} {
			return [string range $d $i [expr {$i + 1 + $len}]]
		}
		incr i [expr {2 + $len}]
	}
	return ""
}

# The Exif segment with its Orientation (in IFD0) set to 1.
proc crop::upright {seg} {
	set le [expr {[string range $seg 10 11] eq "II"}]
	set ifd0 [expr {10 + [crop::uint $seg 14 4 $le]}]
	set count [crop::uint $seg $ifd0 2 $le]
	for {set k 0} {$k < $count} {incr k} {
		set e [expr {$ifd0 + 2 + 12 * $k}]
		if {[crop::uint $seg $e 2 $le] == 0x0112} {
			set one [expr {$le ? "\x01\x00" : "\x00\x01"}]
			return [string replace $seg [expr {$e + 8}] [expr {$e + 9}] $one]
		}
	}
	return $seg
}

# Put the EXIF of SRC into DST (a JPEG written by ffmpeg, which keeps none of it).
proc crop::keep_exif {src dst} {
	set f [open $src rb]; set head [read $f 131072]; close $f
	set seg [crop::exif_segment $head]
	if {$seg eq ""} return
	set seg [crop::upright $seg]
	set f [open $dst rb]; set d [read $f]; close $f
	if {[string range $d 0 1] ne "\xff\xd8"} return
	set at 2
	if {[crop::byte $d 2] == 0xff && [crop::byte $d 3] == 0xe0} { set at [expr {4 + [crop::uint $d 4 2 0]}] }
	set f [open $dst wb]
	fconfigure $f -translation binary
	puts -nonewline $f [string range $d 0 [expr {$at - 1}]]$seg[string range $d $at end]
	close $f
}

# ---- the Straighten slider and the crop frame -----------------------------------------

# The slider's value from the pointer: -45 to 45 degrees, in tenths.
proc crop::slide {x} {
	variable sl; variable ang
	lassign $sl sx sw
	set f [expr {max(0.0, min(1.0, ($x - $sx) / double($sw)))}]
	set ang [expr {round((-45 + 90 * $f) * 10) / 10.0}]
	if {$ang == 0} { set ang 0.0 }
	viewer::draw
}
proc crop::slide_press {x y args} { variable sliding; set sliding 1; crop::slide $x }
proc crop::slide_drag {x y args} { crop::slide $x }
proc crop::slide_release {x y args} {
	variable sliding
	if {$sliding} { set sliding 0; crop::preview; viewer::draw }
}

# A corner moved: the opposite corner stays, and a chosen aspect holds.
proc crop::corner_frame {ax ay px py} {
	variable TW; variable TH
	set sx [expr {$px < $ax ? -1 : 1}]; set sy [expr {$py < $ay ? -1 : 1}]
	set roomx [expr {$sx < 0 ? $ax : 1 - $ax}]; set roomy [expr {$sy < 0 ? $ay : 1 - $ay}]
	set w [expr {max(0.05, min($roomx, abs($px - $ax)))}]
	set h [expr {max(0.05, min($roomy, abs($py - $ay)))}]
	set t [crop::target]
	if {$t ne ""} {
		set ht [expr {$w * $TW / ($TH * $t)}]
		if {$ht <= $roomy} { set h $ht } else { set h $roomy; set w [expr {$h * $TH * $t / $TW}] }
	}
	set bx [expr {$ax + $sx * $w}]; set by [expr {$ay + $sy * $h}]
	list [expr {min($ax, $bx)}] [expr {min($ay, $by)}] [expr {max($ax, $bx)}] [expr {max($ay, $by)}]
}

# The corner I (0 TL, 1 TR, 2 BL, 3 BR) and the corner opposite it, as fractions.
proc crop::corner_xy {i} {
	variable fr
	lassign $fr x0 y0 x1 y1
	switch -- $i {
		0 { return [list $x0 $y0] }
		1 { return [list $x1 $y0] }
		2 { return [list $x0 $y1] }
		3 { return [list $x1 $y1] }
	}
}
proc crop::opposite {i} {
	variable fr
	lassign $fr x0 y0 x1 y1
	switch -- $i {
		0 { return [list $x1 $y1] }
		1 { return [list $x0 $y1] }
		2 { return [list $x1 $y0] }
		3 { return [list $x0 $y0] }
	}
}

# The pointer as fractions of the picture.
proc crop::frac {x y} {
	variable box
	lassign $box L T pw ph
	list [expr {($x - $L) / double($pw)}] [expr {($y - $T) / double($ph)}]
}

proc crop::corner_press {i x y args} { variable drag; set drag [list corner $i] }
proc crop::inside_press {x y args} { variable drag fr; set drag [list move $x $y $fr] }

proc crop::drag_move {x y args} {
	variable drag; variable fr
	if {$drag eq ""} return
	lassign $drag kind a b c
	if {$kind eq "corner"} {
		lassign [crop::opposite $a] ax ay
		lassign [crop::frac $x $y] px py
		set fr [crop::corner_frame $ax $ay $px $py]
	} else {
		lassign [crop::frac $x $y] fx fy
		lassign [crop::frac $a $b] sx sy
		lassign $c x0 y0 x1 y1
		set dx [expr {max(-$x0, min(1 - $x1, $fx - $sx))}]
		set dy [expr {max(-$y0, min(1 - $y1, $fy - $sy))}]
		set fr [list [expr {$x0 + $dx}] [expr {$y0 + $dy}] [expr {$x1 + $dx}] [expr {$y1 + $dy}]]
	}
	viewer::draw
}

proc crop::drag_end {x y args} { variable drag; set drag {} }

# ---- drawing ------------------------------------------------------------------------

# An icon at x y, SIZE px in COLOUR (a ui colour value), stroke SW.
proc crop::icon {name size sw colour x y} {
	variable P
	set i [raster::icon $P($name) $size $sw [ui::col $colour] {} 0 0 0]
	$ui::cv create image [expr {round($x)}] [expr {round($y)}] -image $i -anchor nw -tags page
}

# The title bar: the name and the crop's pixel size on the left; on the right Revert
# (ghost), Save as copy (field) and Save (primary), 34 px, compact.
proc crop::titlebar {} {
	variable fr; variable rot
	array set c [array get ui::c]
	set TB $::zoom::TB; set W $::zoom::WW
	set name [file tail $::viewer::file]
	bar::text 22 0 $TB $name i14s $c(fg)
	set size [crop::out_size [dict get $::stage::src nw] [dict get $::stage::src nh] $rot $::crop::ang $fr]
	bar::text [expr {22 + [bar::width i14s $name] + 12}] 0 $TB $size i13 $c(muted)
	set y [expr {($TB - 34) / 2}]
	set x [expr {$W - 16}]
	if {[crop::can_write $::viewer::file]} {
		set buttons [list Save primary check {crop::save over} {Save as copy} field copy {crop::save copy} Revert ghost undo crop::revert]
	} else {
		set buttons [list {Save as copy} primary copy {crop::save copy} Revert ghost undo crop::revert]
	}
	foreach {label kind icon hit} $buttons {
		# the compact button (STYLE.md): padding 14, the label (600 primary, else 500), the 13 px icon 7 after it
		set f [expr {$kind eq "primary" ? "i13s" : "i13m"}]
		set bw [expr {14 + [bar::width $f $label] + 7 + 13 + 14}]
		set x [expr {$x - $bw}]
		switch -- $kind {
			primary { ui::box $x $y $bw 34 -fill $c(accent) -radius 9; set fg $c(ink) }
			field { ui::box $x $y $bw 34 -fill $c(field) -radius 9; set fg $c(fg) }
			ghost { ui::box $x $y $bw 34 -fill $c(bar) -radius 9 -ring [list $c(border) 1]; set fg $c(fg) }
		}
		bar::text [expr {$x + 14}] $y 34 $label $f $fg
		crop::icon $icon 13 2 $fg [expr {$x + $bw - 14 - 13}] [expr {$y + 10.5}]
		ui::hit $x $y $bw 34 $hit
		# 8 between the buttons and the title bar's 2 either side
		set x [expr {$x - 12}]
	}
}

# The toolbar, 44 tall and 20 above the foot: the aspect segment, the turns and the flip,
# then Straighten, its slider and the value. The items sit 2 px apart, as the toolbar's
# do; the pads are 6 and 10.
proc crop::toolbar {} {
	variable aspect; variable ang; variable sl
	array set c [array get ui::c]
	set W $::zoom::WW; set H $::zoom::WH
	set y [expr {$H - 20 - 44}]
	set lw [bar::width i13 "Straighten"]
	set val "[string map {- \u2212} [format %.1f $ang]]\u00b0"
	set g [expr {4 + $lw + 12 + 200 + 14 + 48}]
	set total [expr {6 + 10 + 232 + 13 + 3 * 34 + 13 + $g + 2 * 5}]
	set bx [expr {round(($W - $total) / 2.0)}]
	ui::box $bx $y $total 44 -fill $c(bar) -radius 12 -ring [list $c(border) 1]
	set x [expr {$bx + 6}]
	ui::seg crop.aspect $x [expr {$y + 6}] 232 {free Free orig Original 169 16:9 11 1:1} $aspect crop::set_aspect 32
	incr x [expr {232 + 2}]
	ui::box [expr {$x + 6}] [expr {$y + 13}] 1 18 -fill $c(border)
	incr x [expr {13 + 2}]
	foreach {name hit label} [list rotl crop::turn_ccw {Rotate left} rotate crop::turn_cw {Rotate right} flip crop::flip Flip] {
		bar::tip crop-$name $label $x $y 34 44 [list $y [expr {$y + 44}] above]
		if {[bar::lit crop-$name]} { ui::box $x [expr {$y + 5}] 34 34 -fill $c(field) -radius 8 }
		crop::icon $name 16 1.9 [expr {[bar::lit crop-$name] ? $c(fg) : $c(muted)}] [expr {$x + 9}] [expr {$y + 14}]
		ui::hit $x $y 34 44 $hit
		incr x [expr {34 + 2}]
	}
	ui::box [expr {$x + 6}] [expr {$y + 13}] 1 18 -fill $c(border)
	incr x [expr {13 + 2}]
	# the group: the label, the track (4 px, the knob 18 px), the value
	bar::text [expr {$x + 4}] $y 44 "Straighten" i13 $c(muted)
	set tx [expr {$x + 4 + $lw + 12}]
	set ty [expr {$y + 20}]
	set sl [list $tx 200]
	ui::box $tx [expr {$ty - 2}] 200 4 -fill $c(pill) -radius 2
	set kx [expr {$tx + ($ang + 45) / 90.0 * 200}]
	ui::box $tx [expr {$ty - 2}] [expr {$kx - $tx}] 4 -fill $c(muted) -radius 2
	ui::box [expr {$kx - 9}] [expr {$ty - 7}] 18 18 -fill $c(fg) -radius 9
	ui::hit $tx [expr {$y + 8}] 200 28 crop::slide_press crop::slide_drag crop::slide_release
	bar::text [expr {$tx + 200 + 14 + 48}] $y 44 $val i13 $c(fg) e
}

proc crop::turn_cw {args} { crop::turn 1 }
proc crop::turn_ccw {args} { crop::turn -1 }

# The crop view: the picture, the frame and its outside dimmed, then the title bar and the toolbar.
proc crop::draw {} {
	variable box; variable fr; variable prev
	array set c [array get ui::c]
	lassign $box L T pw ph
	if {$prev ne ""} { $ui::img copy $prev -to $L $T }
	lassign $fr x0 y0 x1 y1
	set X0 [expr {$L + $x0 * $pw}]; set Y0 [expr {$T + $y0 * $ph}]
	set X1 [expr {$L + $x1 * $pw}]; set Y1 [expr {$T + $y1 * $ph}]
	set fw [expr {$X1 - $X0}]; set fh [expr {$Y1 - $Y0}]
	# outside the frame: black at 55 %
	ui::fbox $L $T $pw [expr {$Y0 - $T}] -fill #000000 -alpha 0.55
	ui::fbox $L $Y1 $pw [expr {$T + $ph - $Y1}] -fill #000000 -alpha 0.55
	ui::fbox $L $Y0 [expr {$X0 - $L}] $fh -fill #000000 -alpha 0.55
	ui::fbox $X1 $Y0 [expr {$L + $pw - $X1}] $fh -fill #000000 -alpha 0.55
	ui::ring $X0 $Y0 $fw $fh 0 $c(fg) 1
	foreach t {1 2} {
		ui::fbox [expr {$X0 + $fw * $t / 3.0}] $Y0 1 $fh -fill $c(fg) -alpha 0.35
		ui::fbox $X0 [expr {$Y0 + $fh * $t / 3.0}] $fw 1 -fill $c(fg) -alpha 0.35
	}
	# the corner brackets: 20 long, 3 thick, 3 px outside the frame
	ui::box [expr {$X0 - 3}] [expr {$Y0 - 3}] 20 3 -fill $c(fg)
	ui::box [expr {$X0 - 3}] [expr {$Y0 - 3}] 3 20 -fill $c(fg)
	ui::box [expr {$X1 - 17}] [expr {$Y0 - 3}] 20 3 -fill $c(fg)
	ui::box $X1 [expr {$Y0 - 3}] 3 20 -fill $c(fg)
	ui::box [expr {$X0 - 3}] $Y1 20 3 -fill $c(fg)
	ui::box [expr {$X0 - 3}] [expr {$Y1 - 17}] 3 20 -fill $c(fg)
	ui::box [expr {$X1 - 17}] $Y1 20 3 -fill $c(fg)
	ui::box $X1 [expr {$Y1 - 17}] 3 20 -fill $c(fg)
	# hits: the frame moves, its corners resize (they are tried first)
	ui::hit $X0 $Y0 $fw $fh crop::inside_press crop::drag_move crop::drag_end
	set cx [list $X0 $X1 $X0 $X1]; set cy [list $Y0 $Y0 $Y1 $Y1]
	foreach i {0 1 2 3} {
		ui::hit [expr {[lindex $cx $i] - 12}] [expr {[lindex $cy $i] - 12}] 24 24 [list crop::corner_press $i] crop::drag_move crop::drag_end
	}
	crop::titlebar
	crop::toolbar
}
