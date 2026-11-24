# widgets.tcl - PROTOTYPE (docs/TK-CORNERS.md): rounded widget corners in
# Tk 8.6, four ways, side by side at 1x 1.25x 1.5x 2x, and their cost.
#
#   wish widgets.tcl show CACHEDIR      draw the comparison board
#   wish widgets.tcl bench CACHEDIR     print timings and memory
#
# A  poly    canvas polygon, -smooth (Tk's own drawing: aliased)
# B  photo   one photo per widget, filled by raster::box (today's shell)
# C  quad    four shared corner sprites + canvas rectangles: the sprites
#            come from one raster.tcl template per look; resizing moves
#            items, nothing is rendered
# C2 quad-o  the same with sprites pre-blended on the surface colour
#            (opaque: no alpha read-back when Tk draws them)
# D  ttk     a ttk image element nine-sliced by ttk itself (-border)
lassign $argv mode cache
set here [file dirname [file normalize [info script]]]
source [file join $here .. shell raster.tcl]
raster::init $cache
array set c {BAR #1D1C1B FIELD #2A2826 PILL #36302C BORDER #3B3835 FG #EEE9E3
	MUTED #A49D95 ACCENT #FF7A59 WIN #232120 ON_ACCENT #1A0F0B}

namespace eval rr {}

# ---- A: smoothed polygon ----------------------------------------------------
proc rr::poly {cv x y w h r fill {ring ""} {tags ""}} {
	# exact circular corners as raw Bezier segments (k = 0.5523), so only
	# the aliasing differs from the other approaches
	set x1 [expr {$x + $w}]; set y1 [expr {$y + $h}]
	set k [expr {$r * 0.5523}]
	set pts [list [expr {$x+$r}] $y  [expr {$x+$r}] $y [expr {$x1-$r}] $y  [expr {$x1-$r}] $y \
		[expr {$x1-$r+$k}] $y $x1 [expr {$y+$r-$k}]  $x1 [expr {$y+$r}] \
		$x1 [expr {$y+$r}] $x1 [expr {$y1-$r}]  $x1 [expr {$y1-$r}] \
		$x1 [expr {$y1-$r+$k}] [expr {$x1-$r+$k}] $y1  [expr {$x1-$r}] $y1 \
		[expr {$x1-$r}] $y1 [expr {$x+$r}] $y1  [expr {$x+$r}] $y1 \
		[expr {$x+$r-$k}] $y1 $x [expr {$y1-$r+$k}]  $x [expr {$y1-$r}] \
		$x [expr {$y1-$r}] $x [expr {$y+$r}]  $x [expr {$y+$r}] \
		$x [expr {$y+$r-$k}] [expr {$x+$r-$k}] $y  [expr {$x+$r}] $y]
	$cv create polygon $pts -smooth raw -fill $fill \
		-outline [expr {$ring eq "" ? "" : [lindex $ring 0]}] -width [expr {$ring eq "" ? 0 : [lindex $ring 1]}] -tags $tags
}

# ---- B: a photo per widget ----------------------------------------------------
proc rr::photo {cv x y w h r fill {ring ""} {tags ""}} {
	set p [image create photo -width $w -height $h]
	set o [list -fill $fill -radius $r]
	if {$ring ne ""} { lappend o -ring $ring }
	raster::box $p 0 0 $w $h {*}$o
	$cv create image $x $y -image $p -anchor nw -tags $tags
}
proc rr::photo_resize {cv item w h r fill {ring ""}} {
	set p [$cv itemcget $item -image]
	$p blank; $p configure -width $w -height $h
	set o [list -fill $fill -radius $r]
	if {$ring ne ""} { lappend o -ring $ring }
	raster::box $p 0 0 $w $h {*}$o
}

# ---- C: four corner sprites + rectangles ---------------------------------------
# Sprites for a look: {n tl tr br bl}, shared by every box of that look.
# BG non-empty: pre-blend onto that colour (opaque sprites).
proc rr::sprites {r fill ring {bg ""}} {
	variable spr
	set key [list $r $fill $ring $bg]
	if {[info exists spr($key)]} { return $spr($key) }
	set n [expr {int(ceil($r))}]
	set t [expr {2 * $n + 1}]
	set o [list -fill $fill -radius $r]
	if {$ring ne ""} { lappend o -ring $ring }
	lassign [raster::rrect $t $t {*}$o] img
	set res [list $n]
	foreach {fx fy} [list 0 0 [expr {$n + 1}] 0 [expr {$n + 1}] [expr {$n + 1}] 0 [expr {$n + 1}]] {
		set p [image create photo -width $n -height $n]
		if {$bg ne ""} { $p put $bg -to 0 0 $n $n }
		$p copy $img -from $fx $fy [expr {$fx + $n}] [expr {$fy + $n}] -to 0 0 \
			-compositingrule [expr {$bg ne "" ? "overlay" : "set"}]
		lappend res $p
	}
	set spr($key) $res
}
proc rr::quad {cv x y w h r fill {ring ""} {tags ""} {bg ""}} {
	lassign [sprites $r $fill $ring $bg] n tl tr br bl
	set id [list]
	set x1 [expr {$x + $w}]; set y1 [expr {$y + $h}]
	lappend id [$cv create rectangle [expr {$x+$n}] $y [expr {$x1-$n}] $y1 -fill $fill -width 0 -tags $tags]
	lappend id [$cv create rectangle $x [expr {$y+$n}] $x1 [expr {$y1-$n}] -fill $fill -width 0 -tags $tags]
	if {$ring ne ""} {
		lassign $ring rc rw
		lappend id [$cv create rectangle [expr {$x+$n}] $y [expr {$x1-$n}] [expr {$y+$rw}] -fill $rc -width 0 -tags $tags]
		lappend id [$cv create rectangle [expr {$x+$n}] [expr {$y1-$rw}] [expr {$x1-$n}] $y1 -fill $rc -width 0 -tags $tags]
		lappend id [$cv create rectangle $x [expr {$y+$n}] [expr {$x+$rw}] [expr {$y1-$n}] -fill $rc -width 0 -tags $tags]
		lappend id [$cv create rectangle [expr {$x1-$rw}] [expr {$y+$n}] $x1 [expr {$y1-$n}] -fill $rc -width 0 -tags $tags]
	}
	lappend id [$cv create image $x $y -image $tl -anchor nw -tags $tags]
	lappend id [$cv create image $x1 $y -image $tr -anchor ne -tags $tags]
	lappend id [$cv create image $x1 $y1 -image $br -anchor se -tags $tags]
	lappend id [$cv create image $x $y1 -image $bl -anchor sw -tags $tags]
	return $id
}
proc rr::quad_resize {cv ids x y w h n {ring ""}} {
	set x1 [expr {$x + $w}]; set y1 [expr {$y + $h}]
	set i 0
	$cv coords [lindex $ids $i] [expr {$x+$n}] $y [expr {$x1-$n}] $y1; incr i
	$cv coords [lindex $ids $i] $x [expr {$y+$n}] $x1 [expr {$y1-$n}]; incr i
	if {$ring ne ""} {
		set rw [lindex $ring 1]
		$cv coords [lindex $ids $i] [expr {$x+$n}] $y [expr {$x1-$n}] [expr {$y+$rw}]; incr i
		$cv coords [lindex $ids $i] [expr {$x+$n}] [expr {$y1-$rw}] [expr {$x1-$n}] $y1; incr i
		$cv coords [lindex $ids $i] $x [expr {$y+$n}] [expr {$x+$rw}] [expr {$y1-$n}]; incr i
		$cv coords [lindex $ids $i] [expr {$x1-$rw}] [expr {$y+$n}] $x1 [expr {$y1-$n}]; incr i
	}
	$cv coords [lindex $ids $i] $x $y; incr i
	$cv coords [lindex $ids $i] $x1 $y; incr i
	$cv coords [lindex $ids $i] $x1 $y1; incr i
	$cv coords [lindex $ids $i] $x $y1
}

# ---- D: ttk image element -------------------------------------------------------
# MID: size of the template's middle, which ttk tiles (one Tk_RedrawImage
# per tile). OPAQUE: pre-blend the corners onto BG (no alpha read-back).
proc rr::ttkstyle {name r fill {ring ""} {fg #EEE9E3} {bg #232120} {mid 1} {opaque 0}} {
	set n [expr {int(ceil($r))}]
	set t [expr {2 * $n + 1}]
	set o [list -fill $fill -radius $r]
	if {$ring ne ""} { lappend o -ring $ring }
	lassign [raster::rrect $t $t {*}$o] img
	set T [expr {2 * $n + $mid}]
	set p [image create photo -width $T -height $T]
	if {$opaque} { $p put $bg -to 0 0 $T $T }
	set rule [expr {$opaque ? "overlay" : "set"}]
	foreach {sy0 sy1 ty0 ty1} [list 0 $n 0 $n  $n [expr {$n+1}] $n [expr {$n+$mid}]  [expr {$n+1}] $t [expr {$n+$mid}] $T] {
		foreach {sx0 sx1 tx0 tx1} [list 0 $n 0 $n  $n [expr {$n+1}] $n [expr {$n+$mid}]  [expr {$n+1}] $t [expr {$n+$mid}] $T] {
			$p copy $img -from $sx0 $sy0 $sx1 $sy1 -to $tx0 $ty0 $tx1 $ty1 -compositingrule $rule
		}
	}
	ttk::style element create $name.bg image $p -border $n -padding 0 -sticky nsew
	ttk::style layout $name.TButton [list background -sticky nsew -children [list $name.bg -sticky nsew \
		-children {Button.padding -sticky nsew -children {Button.label -sticky nsew}}]]
	ttk::style configure $name.TButton -background $bg -foreground $fg -anchor center -padding 0
	ttk::style map $name.TButton -background {}
	return $name.TButton
}

# ---- the board ------------------------------------------------------------------
proc board {} {
	global c
	. configure -background $c(WIN)
	canvas .cv -width 1900 -height 600 -background $c(WIN) -highlightthickness 0 -bd 0
	pack .cv
	set approaches {A poly B photo C quad C2 quad-o D ttk}
	set y 40
	foreach {tag name} $approaches {
		.cv create text 16 [expr {$y + 20}] -text "$tag $name" -fill $c(MUTED) -anchor w -font {Inter -13}
		set x 120
		foreach s {1 1.25 1.5 2} {
			set h [expr {int(round(34 * $s))}]
			set r [expr {8.0 * $s}]
			set rw [expr {max(1, int(round($s)))}]
			set ring [list $c(BORDER) $rw]
			set bw [expr {int(round(96 * $s))}]
			set fw [expr {int(round(150 * $s))}]
			set f [list Inter [expr {-int(round(13 * $s))}]]
			set k [string map {. _} $s]
			if {$tag eq "D"} {
				set st1 [rr::ttkstyle btn$k $r $c(PILL)]
				set st2 [rr::ttkstyle fld$k [expr {$r * 1.25}] $c(FIELD) $ring $c(MUTED)]
				set st3 [rr::ttkstyle acc$k [expr {$h / 2.0}] $c(ACCENT) {} $c(ON_ACCENT)]
				ttk::style configure $st1 -font $f; ttk::style configure $st2 -font $f; ttk::style configure $st3 -font $f
				ttk::button .cv.b$k -style $st1 -text Cancel
				ttk::button .cv.f$k -style $st2 -text "Search\u2026"
				ttk::button .cv.a$k -style $st3 -text OK
				.cv create window $x $y -window .cv.b$k -anchor nw -width $bw -height $h
				.cv create window [expr {$x + $bw + 8}] $y -window .cv.f$k -anchor nw -width $fw -height $h
				.cv create window [expr {$x + $bw + $fw + 16}] $y -window .cv.a$k -anchor nw -width $h -height $h
			} else {
				set p [dict get {A poly B photo C quad C2 quad} $tag]
				set extra [expr {$tag eq "C2" ? [list {} $c(WIN)] : {}}]
				rr::$p .cv $x $y $bw $h $r $c(PILL) {} {} {*}[lrange $extra 1 end]
				.cv create text [expr {$x + $bw / 2}] [expr {$y + $h / 2}] -text Cancel -fill $c(FG) -font $f
				set fx [expr {$x + $bw + 8}]
				rr::$p .cv $fx $y $fw $h [expr {$r * 1.25}] $c(FIELD) $ring {} {*}[lrange $extra 1 end]
				.cv create text [expr {$fx + 12 * $s}] [expr {$y + $h / 2}] -text "Search\u2026" -fill $c(MUTED) -font $f -anchor w
				set ax [expr {$x + $bw + $fw + 16}]
				rr::$p .cv $ax $y $h $h [expr {$h / 2.0}] $c(ACCENT) {} {} {*}[lrange $extra 1 end]
				.cv create text [expr {$ax + $h / 2}] [expr {$y + $h / 2}] -text OK -fill $c(ON_ACCENT) -font $f
			}
			incr x [expr {$bw + $fw + $h + 48}]
		}
		incr y 110
	}
}

# ---- the bench ---------------------------------------------------------------------
proc rss {} {
	set fh [open /proc/self/status]; set t [read $fh]; close $fh
	regexp {VmRSS:\s+(\d+)} $t -> kb
	return $kb
}
proc ms {script} { format %.1f [expr {[lindex [time {uplevel 1 $script} 1] 0] / 1000.0}] }

proc bench {} {
	global c
	set N 200
	canvas .cv -width 1400 -height 900 -background $c(WIN) -highlightthickness 0 -bd 0
	pack .cv
	update
	expr {srand(7)}
	set geo {}
	for {set i 0} {$i < $N} {incr i} {
		lappend geo [expr {($i % 8) * 170 + 10}] [expr {($i / 8) * 34 + 10}] [expr {60 + int(rand() * 100)}]
	}
	set ring [list $c(BORDER) 1]
	foreach {tag p} {A poly B photo C quad C2 quad-o} {
		.cv delete all
		foreach i [image names] { if {[string match image* $i] || [string match ::raster* $i]} { catch {image delete $i} } }
		array unset ::rr::spr
		file delete -force $::cache; raster::init $::cache
		update
		set extra [expr {$tag eq "C2" ? [list {} $c(WIN)] : {}}]
		set fn [expr {$tag eq "C2" ? "quad" : $p}]
		# cold: the first box of a look renders its template (raster.tcl, pure Tcl)
		set cold [ms {rr::$fn .cv -100 -100 50 28 8 $c(FIELD) $ring {} {*}[lrange $extra 1 end]}]
		.cv delete all
		set m0 [rss]
		set items {}
		set t0 [clock microseconds]
		foreach {x y w} $geo {
			lappend items [rr::$fn .cv $x $y $w 28 8 $c(FIELD) $ring {} {*}[lrange $extra 1 end]]
		}
		set tcreate [expr {([clock microseconds] - $t0) / 1000.0}]
		set t0 [clock microseconds]; update; set tdraw [expr {([clock microseconds] - $t0) / 1000.0}]
		set m1 [rss]
		# resize every box (+20 px) and redraw
		set t0 [clock microseconds]
		foreach {x y w} $geo it $items {
			switch $tag {
				A { .cv delete $it; rr::poly .cv $x $y [expr {$w + 20}] 28 8 $c(FIELD) $ring }
				B { rr::photo_resize .cv $it [expr {$w + 20}] 28 8 $c(FIELD) $ring }
				default { rr::quad_resize .cv $it $x $y [expr {$w + 20}] 28 8 $ring }
			}
		}
		update
		set tresize [expr {([clock microseconds] - $t0) / 1000.0}]
		# full repaint (expose of the whole canvas)
		set t0 [clock microseconds]
		pack forget .cv; update; pack .cv; update
		set texpose [expr {([clock microseconds] - $t0) / 1000.0}]
		set npix 0; set nimg 0
		foreach i [image names] { if {[image type $i] eq "photo"} { incr nimg; incr npix [expr {[image width $i] * [image height $i]}] } }
		puts [format "%-7s cold %7.1f ms | create %3d boxes %6.1f ms + draw %6.1f ms | resize all %6.1f ms | expose %6.1f ms | photos %3d, %7d px (%5.0f KB client + same in X) | RSS +%d KB | items %d" \
			$tag$p $cold $N $tcreate $tdraw $tresize $texpose $nimg $npix [expr {$npix * 4 / 1024.0}] [expr {$m1 - $m0}] [llength [.cv find all]]]
	}
	# D: ttk buttons (the same 200, as widgets with a label each)
	destroy .cv
	foreach {mid opaque} {1 0 64 0 64 1} {
		file delete -force $::cache; raster::init $::cache
		destroy .f
		frame .f -width 1400 -height 900 -background $c(WIN); pack .f; update
		set cold [ms {set st [rr::ttkstyle bench$mid$opaque 8 $c(FIELD) $ring #EEE9E3 $c(WIN) $mid $opaque]}]
		set m0 [rss]
		set t0 [clock microseconds]
		set i 0
		foreach {x y w} $geo {
			ttk::button .f.b$i -style $st -text "Button $i"
			place .f.b$i -x $x -y $y -width $w -height 28
			incr i
		}
		set tcreate [expr {([clock microseconds] - $t0) / 1000.0}]
		set t0 [clock microseconds]; update; set tdraw [expr {([clock microseconds] - $t0) / 1000.0}]
		set m1 [rss]
		set t0 [clock microseconds]
		set i 0
		foreach {x y w} $geo { place .f.b$i -width [expr {$w + 20}]; incr i }
		update
		set tresize [expr {([clock microseconds] - $t0) / 1000.0}]
		set t0 [clock microseconds]
		pack forget .f; update; pack .f; update
		set texpose [expr {([clock microseconds] - $t0) / 1000.0}]
		puts [format "%-7s cold %7.1f ms | create %3d boxes %6.1f ms + draw %6.1f ms | resize all %6.1f ms | expose %6.1f ms | one template (mid %d, opaque %d), 200 widgets with labels | RSS +%d KB" \
			Dttk $cold $N $tcreate $tdraw $tresize $texpose $mid $opaque [expr {$m1 - $m0}]]
	}
}

if {$mode eq "show"} { board } else { bench; exit }
