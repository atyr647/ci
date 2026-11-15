# stage.tcl - the picture: which decoder reads a file, its working copy and the
# part of the picture the stage shows at the current zoom.
#
#   stage::decoder FILE   tk      PNG, GIF, PPM, PGM: Tk 8.6 reads them, no helper
#                         helper  JPEG, WebP, AVIF, BMP, TIFF: ffmpeg (the shell's own
#                                 helper, a runtime dependency of ribbon-desktop);
#                                 gdk-pixbuf-thumbnailer when ffmpeg is missing
#                         none    anything else, or no helper for it
#   stage::load FILE      decode (a working copy of at most 4096 px on its long side)
#   stage::view L T PW PH VX VY VW VH   the visible part as {photo x y}, in window
#                         coordinates; the crop and scale go through ffmpeg, or Tk
#                         (whole steps only) when ffmpeg is missing

namespace eval stage {
	variable tkfmt {png gif ppm pgm}
	variable helperfmt {jpg jpeg webp avif bmp tif tiff}
	variable videofmt {mp4 m4v mkv webm mov avi}   ;# their first frame (video.tcl plays them)
	variable max 4096
	variable src {}      ;# {file nw nh ww wh work photo}: the open picture
	variable view {}     ;# {key photo x y}: the last view
	variable thumbs {}   ;# {w h photo}: the navigator's picture
	variable tmpdir ""
	variable counter 0
}

proc stage::decoder {file} {
	variable tkfmt; variable helperfmt
	set e [string range [string tolower [file extension $file]] 1 end]
	if {$e in $tkfmt} { return tk }
	if {$e in $helperfmt && ([auto_execok ffmpeg] ne "" || [auto_execok gdk-pixbuf-thumbnailer] ne "")} { return helper }
	if {$e in $::stage::videofmt && [auto_execok ffmpeg] ne ""} { return helper }
	return none
}

# A scratch file for the helper's output (the viewer's own cache folder).
proc stage::tmp {ext} {
	variable tmpdir; variable counter
	if {$tmpdir eq ""} {
		set base [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$::env(HOME)/.cache"}]
		set tmpdir [file join $base ribbon viewer]
		file mkdir $tmpdir
	}
	incr counter
	return [file join $tmpdir "view-[pid]-$counter.$ext"]
}

# The picture's stored size from its header (PNG, JPEG, WebP; the others through ffprobe); {0 0} when unknown.
proc stage::header {file} {
	if {![catch {wall::image_size $file} r]} { return $r }
	# TIFF, BMP, AVIF: ffprobe (ffmpeg's own) reads the size
	if {[auto_execok ffprobe] ne "" && ![catch {exec ffprobe -v error -select_streams v:0 \
			-show_entries stream=width,height -of csv=p=0:s=x $file 2>@1} r] && [regexp {^(\d+)x(\d+)} [string trim $r] -> w h]} {
		return [list $w $h]
	}
	return {0 0}
}

# The size the picture is shown at, from its header's NW x NH and the working copy's WW x WH: the header gives
# the stored size, and the helper turns a JPEG upright (EXIF Orientation 5 to 8), so the sides swap when the
# copy's long side is the other one. {WW WH} when the header gave nothing.
proc stage::upright {nw nh ww wh} {
	if {$nw <= 0 || $nh <= 0} { return [list $ww $wh] }
	if {($nw - $nh) * ($ww - $wh) < 0} { return [list $nh $nw] }
	return [list $nw $nh]
}

# Drop the open picture and everything cut from it.
proc stage::close {} {
	variable src; variable view; variable thumbs
	if {[dict size $src] && [dict get $src photo] ne ""} { catch {image delete [dict get $src photo]} }
	if {[dict size $src] && [dict get $src tmp] ne ""} { catch {file delete [dict get $src tmp]} }
	if {[llength $view]} { catch {image delete [lindex $view 1]} }
	foreach t $thumbs { catch {image delete [lindex $t 2]} }
	set src {}; set view {}; set thumbs {}
}

# Open FILE for the stage. Returns 1 when it can be drawn, 0 otherwise.
proc stage::load {file} {
	variable src; variable max
	stage::close
	set dec [stage::decoder $file]
	if {$dec eq "none"} { return 0 }
	set tmp ""; set photo ""; set work $file
	if {$dec eq "tk" && ![catch {image create photo -file $file} photo]} {
		set nw [image width $photo]; set nh [image height $photo]
		set ww $nw; set wh $nh
	} else {
		if {$photo ne ""} { catch {image delete $photo}; set photo "" }
		set tmp [stage::tmp png]
		if {![stage::helper_png $file $tmp]} { return 0 }
		set work $tmp
		set photo [image create photo -file $tmp]
		set ww [image width $photo]; set wh [image height $photo]
		lassign [stage::upright {*}[stage::header $file] $ww $wh] nw nh
	}
	set src [dict create file $file nw $nw nh $nh ww $ww wh $wh work $work photo $photo tmp $tmp]
	return 1
}

# A still for the open picture (a video's frame, video::freeze): PNG drawn in its place at the picture's size.
proc stage::still {png} {
	variable src; variable view; variable thumbs
	if {![dict size $src]} { error "nothing open" }
	set p [image create photo -file $png]
	if {[dict get $src photo] ne ""} { catch {image delete [dict get $src photo]} }
	if {[llength $view]} { catch {image delete [lindex $view 1]} }
	foreach t $thumbs { catch {image delete [lindex $t 2]} }
	set view {}; set thumbs {}
	dict set src photo $p
	dict set src work $png
	dict set src ww [image width $p]; dict set src wh [image height $p]
	if {[dict get $src tmp] ne ""} { catch {file delete [dict get $src tmp]} }
	dict set src tmp $png
}

# A PNG of FILE at most `max` px on its long side, from ffmpeg, or gdk-pixbuf.
proc stage::helper_png {file out} {
	variable max
	if {[auto_execok ffmpeg] ne ""} {
		set vf "scale=w='min(iw,$max)':h='min(ih,$max)':force_original_aspect_ratio=decrease"
		if {![catch {exec ffmpeg -nostdin -v error -y -i $file -frames:v 1 -vf $vf $out </dev/null >/dev/null 2>@1}] && [file exists $out]} { return 1 }
	}
	if {[auto_execok gdk-pixbuf-thumbnailer] ne ""} {
		lassign [stage::header $file] w h
		set s [expr {max($w, $h) > $max || $w == 0 ? $max : max($w, $h)}]
		if {![catch {exec gdk-pixbuf-thumbnailer -s $s $file $out}] && [file exists $out]} { return 1 }
	}
	return 0
}

# The working copy's crop (CX CY CW CH, in working px) at OW x OH display px, as a new photo.
proc stage::crop {cx cy cw ch ow oh} {
	variable src
	set work [dict get $src work]; set wphoto [dict get $src photo]
	set out [image create photo -width $ow -height $oh]
	if {$cw == $ow && $ch == $oh} {
		$out copy $wphoto -from $cx $cy [expr {$cx + $cw}] [expr {$cy + $ch}] -to 0 0 $ow $oh
		return $out
	}
	if {[auto_execok ffmpeg] ne ""} {
		set tmp [stage::tmp png]
		set vf "crop=$cw:$ch:$cx:$cy,scale=$ow:$oh:flags=bicubic"
		if {![catch {exec ffmpeg -nostdin -v error -y -i $work -frames:v 1 -vf $vf $tmp </dev/null >/dev/null 2>@1}] && [file exists $tmp]} {
			image delete $out
			set out [image create photo -file $tmp]
			file delete $tmp
			return $out
		}
		catch {file delete $tmp}
	}
	# Tk only: whole steps, so the size may be off by a step
	set t [image create photo]
	$t copy $wphoto -from $cx $cy [expr {$cx + $cw}] [expr {$cy + $ch}]
	if {$cw > $ow && $ow > 0} { set f [expr {max(1, round(double($cw) / $ow))}]; set t2 [image create photo]; $t2 copy $t -subsample $f; image delete $t; set t $t2 }
	if {$ow > $cw && $cw > 0} { set f [expr {max(1, round(double($ow) / $cw))}]; set t2 [image create photo]; $t2 copy $t -zoom $f; image delete $t; set t $t2 }
	$out copy $t -to 0 0 $ow $oh
	image delete $t
	return $out
}

# The visible part of the picture (placed at L T, PW x PH display px) inside the
# viewport VX VY VW VH. Returns {photo x y}, or "" when nothing shows.
proc stage::view {L T pw ph vx vy vw vh} {
	variable src; variable view
	if {![dict size $src] || [dict get $src photo] eq ""} { return "" }
	set x0 [expr {max($L, $vx)}]; set y0 [expr {max($T, $vy)}]
	set x1 [expr {min($L + $pw, $vx + $vw)}]; set y1 [expr {min($T + $ph, $vy + $vh)}]
	if {$x1 <= $x0 || $y1 <= $y0} { return "" }
	set key [list $L $T $pw $ph $x0 $y0 $x1 $y1]
	if {[llength $view] && [lindex $view 0] eq $key} { return [lrange $view 1 3] }
	if {[llength $view]} { catch {image delete [lindex $view 1]} }
	set nw [dict get $src nw]; set nh [dict get $src nh]
	set s [expr {double($pw) / $nw}]
	set k [expr {double([dict get $src ww]) / $nw}]
	set cx [expr {round(($x0 - $L) / $s * $k)}]; set cy [expr {round(($y0 - $T) / $s * $k)}]
	set cw [expr {max(1, round(($x1 - $x0) / $s * $k))}]; set ch [expr {max(1, round(($y1 - $y0) / $s * $k))}]
	set cw [expr {min($cw, [dict get $src ww] - $cx)}]; set ch [expr {min($ch, [dict get $src wh] - $cy)}]
	if {$cw < 1 || $ch < 1} { set view {}; return "" }
	set photo [stage::crop $cx $cy $cw $ch [expr {$x1 - $x0}] [expr {$y1 - $y0}]]
	set view [list $key $photo $x0 $y0]
	return [list $photo $x0 $y0]
}

# The whole picture at W x H (the navigator's thumbnail). Cached per size.
proc stage::thumb {w h} {
	variable src; variable thumbs
	foreach t $thumbs { if {[lindex $t 0] == $w && [lindex $t 1] == $h} { return [lindex $t 2] } }
	if {![dict size $src] || [dict get $src photo] eq ""} { return "" }
	set p [stage::crop 0 0 [dict get $src ww] [dict get $src wh] $w $h]
	lappend thumbs [list $w $h $p]
	return $p
}

# The open picture's size {w h}, or "" when none is open.
proc stage::size {} {
	variable src
	if {![dict size $src] || [dict get $src photo] eq ""} { return "" }
	list [dict get $src nw] [dict get $src nh]
}
