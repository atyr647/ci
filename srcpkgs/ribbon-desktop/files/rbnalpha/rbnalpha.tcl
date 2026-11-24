# rbnalpha.tcl - see-through rounded windows and crisp rounded widgets for
# Ribbon's Tk programs (package require rbnalpha). The C side is
# rbnalpha.c; docs/TK-CORNERS.md has the design, the API and the numbers.
#
# Looks: a look is a rounded box's options, as raster::rrect takes them
#   {-fill #hex -radius R|{tl tr br bl} -ring {#hex W ?sides?} -shadow {dy blur alpha ?#hex?}}
# Its picture is rendered once (in C), kept on disk per look (sizes are in
# device pixels, so per scale too) and uploaded to the X server once; every
# window of that look, whatever its size, is nine-sliced from it there.
#
# Windows:
#   rbn::surface W ?-class C? ?-managed 0|1? ?-fill #hex?
#       an ARGB toplevel W (override-redirect unless -managed) with an
#       ordinary 24-bit canvas W.c for its contents; returns W.c
#   rbn::popup W X Y WIDTH HEIGHT LOOK ?-clip SIDES? ?-raise 0|1?
#       show W with its box (WIDTH x HEIGHT, its top-left at screen X Y):
#       the look's shadow, anti-aliased edge and ring around W.c, which is
#       placed over the box and cut to its inside. -clip tlrb: those sides
#       are open, square and without shadow (a panel that hangs from a bar,
#       the bar it hangs from). Clicks on the shadow go to whatever is below.
#   rbn::move W X Y  move a popup's box to screen X Y
#   rbn::hide W      withdraw it and let go of its frame's memory (and of the keyboard)
#   rbn::keys W 1|0  hold the keyboard for W once it is on screen (a sheet that takes Esc), or let go of it
#   rbn::show W X Y WW WH ?-frames {{LOOK x y w h ?clip?} ...}?
#       ?-pieces PIECES? ?-content {x y w h}? ?-extra BOXES? ?-shape BOXES?
#       ?-input BOXES?
#       the general form (the bars: several boxes in one window). Boxes are
#       {x y w h ?radius?} in window coordinates; W.c is cut to the frames'
#       insides plus -extra (or exactly -shape), clicks are taken over the
#       frames plus -extra (or exactly -input). {{0 0 0 0}}: nothing.
#   rbn::insides FRAMES      the boxes W.c is cut to for those frames
#   rbn::appwindow W CLASS WIDTH HEIGHT ?-fill #hex?, rbn::appframe W PHOTO R
#       a managed app window that draws its own frame into a photo
#       (Appearance, Properties, the installer): see-through corners
# Widgets:
#   rbn::box CANVAS X Y W H ?-fill? ?-radius? ?-ring? ?-on #hex|""? ?-tags T?
#       a rounded box as canvas items: four corner sprites shared by every
#       box of that look and surface (-on: the colour under it, which the
#       sprites are pre-blended on; "" keeps their alpha) and rectangles
#   rbn::ttk STYLE ?-fill? ?-radius? ?-ring? ?-on? ?-mid 64?
#       a ttk style (STYLE.TButton layout) whose background is a nine-slice
#       image element with a large, pre-blended middle
# Facts:
#   rbn::init DIR    where pictures are cached (default ~/.cache/ribbon/rbnalpha)
#   rbn::native      1 with the C extension; rbn::argb: 1 with real ARGB windows
#   rbn::stats       what is shared, and how much memory it takes

namespace eval rbn {
	variable c [llength [info commands ::rbnalpha::frame]]
	variable argb -1        ;# real ARGB windows (computed on first use)
	variable cachedir ""
	variable meta           ;# photo -> {pad pt pb}
	array set meta {}
	variable looks          ;# look -> {key pad pt pb cap t iw ih}
	array set looks {}
	variable spr            ;# sprite sets
	array set spr {}
	variable shown          ;# window -> what it shows (skip unchanged work)
	array set shown {}
	variable cmap ""        ;# the ARGB colormap every surface shares
	variable keys           ;# held: the window holding the keyboard; try: the next attempt (rbn::keys)
	array set keys {}
}

proc rbn::native {} { variable c; return $c }

proc rbn::argb {} {
	variable argb
	variable c
	if {$argb < 0} {
		set argb [expr {$c && {truecolor 32} in [winfo visualsavailable .]}]
		if {[info exists ::env(RBNALPHA_OFF)]} { set argb 0 }
	}
	return $argb
}

proc rbn::init {dir} {
	variable cachedir $dir
	file mkdir $dir
}

proc rbn::dir {} {
	variable cachedir
	if {$cachedir eq ""} {
		set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}]
		init [file join [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$home/.cache"}] ribbon rbnalpha]
	}
	return $cachedir
}

# Padding a look's shadow adds: {pad pt pb} (left/right, top, bottom).
proc rbn::pads {opts} {
	if {![dict exists $opts -shadow] || [llength [dict get $opts -shadow]] < 3} { return {0 0 0} }
	lassign [dict get $opts -shadow] dy blur
	set pad [expr {int(ceil($blur * 1.5))}]
	list $pad [expr {max(0, $pad - int($dy))}] [expr {$pad + int($dy)}]
}

# The picture of a W x H box of a look (raster::rrect's pixels), cached
# in memory and on disk. Returns {photo pad pt pb}.
proc rbn::picture {w h opts} {
	variable meta
	variable c
	set key [list rbn1 $w $h $opts]
	set name [raster::name [format %08x [zlib crc32 $key]] $key ::rbn::p]
	if {$name ni [image names]} {
		set f [raster::keyed_path [dir] "" $key]
		if {[raster::keyed $f $key] && ![catch {image create photo $name -file $f -format png}]} {
		} elseif {$c} {
			image create photo $name
			rbnalpha::rrect $name $w $h {*}$opts
			catch {$name write $f.[pid] -format png; file rename -force $f.[pid] $f; raster::store_key $f $key}
		} else {
			lassign [raster::rrect $w $h {*}$opts] img
			image create photo $name
			$name copy $img
		}
		set meta($name) [pads $opts]
	}
	list $name {*}$meta($name)
}

# A look: its template, uploaded once. Returns its key.
proc rbn::look {opts} {
	variable looks
	variable c
	# The key is L + the CRC of OPTS; a look with another OPTS and the same CRC takes L<crc>.1, ...
	set crc [format %08x [zlib crc32 [list $opts]]]
	for {set n 0} {1} {incr n} {
		set k L$crc
		if {$n} { append k .$n }
		if {![info exists looks($k)] || [lindex $looks($k) 8] eq $opts} break
	}
	if {![info exists looks($k)]} {
		set r 0
		if {[dict exists $opts -radius]} { set r [tcl::mathfunc::max {*}[dict get $opts -radius]] }
		set cap [expr {int(ceil($r)) + 2}]
		set t [expr {2 * $cap + 1}]
		lassign [picture $t $t $opts] img pad pt pb
		if {$c && [argb]} { rbnalpha::template $k $img }
		set looks($k) [list $img $pad $pt $pb $cap $t [image width $img] [image height $img] $opts]
	}
	return $k
}

# A box that is smaller than its look's template gets its own picture.
proc rbn::exact {k w h} {
	variable looks
	set opts [lindex $looks($k) 8]
	set e $k.${w}x$h
	if {![info exists looks($e)]} {
		lassign [picture $w $h $opts] img pad pt pb
		if {[native] && [argb]} { rbnalpha::template $e $img }
		set looks($e) [list $img $pad $pt $pb 0 0 [image width $img] [image height $img] $opts]
	}
	return $e
}

# The pieces that draw look K's box at x y (window coordinates), w x h.
# clip: sides without a shadow.
proc rbn::pieces {k x y w h {clip ""}} {
	variable looks
	lassign $looks($k) img pad pt pb cap t iw ih
	if {$w < $t || $h < $t} {
		set k [exact $k $w $h]
		lassign $looks($k) img pad pt pb
		set cols [list 0 $iw [expr {$x - $pad}] [expr {$x - $pad + $iw}]]
		set rows [list 0 $ih [expr {$y - $pt}] [expr {$y - $pt + $ih}]]
		set cl [expr {[string first l $clip] >= 0}]; set cr [expr {[string first r $clip] >= 0}]
		set ct [expr {[string first t $clip] >= 0}]; set cb [expr {[string first b $clip] >= 0}]
		lassign $cols s0 s1 d0 d1
		if {$cl} { incr s0 $pad; incr d0 $pad }
		if {$cr} { incr s1 -$pad; incr d1 -$pad }
		lassign $rows r0 r1 e0 e1
		if {$ct} { incr r0 $pt; incr e0 $pt }
		if {$cb} { incr r1 -$pb; incr e1 -$pb }
		return [list [list $k $s0 $r0 [expr {$s1 - $s0}] [expr {$r1 - $r0}] $d0 $e0 [expr {$d1 - $d0}] [expr {$e1 - $e0}]]]
	}
	# columns and rows: {src0 src1 dst0 dst1}. A clipped side has no shadow
	# and no corners: the box's straight middle runs on to its edge there
	# (it joins another shape: a panel hanging from a bar).
	set a [expr {$pad + $cap}]
	set cols {}
	if {[string first l $clip] < 0} { lappend cols [list 0 $a [expr {$x - $pad}] [expr {$x + $cap}]] }
	lappend cols [list $a [expr {$a + 1}] [expr {[string first l $clip] < 0 ? $x + $cap : $x}] [expr {[string first r $clip] < 0 ? $x + $w - $cap : $x + $w}]]
	if {[string first r $clip] < 0} { lappend cols [list [expr {$a + 1}] $iw [expr {$x + $w - $cap}] [expr {$x + $w + $pad}]] }
	set b [expr {$pt + $cap}]
	set rows {}
	if {[string first t $clip] < 0} { lappend rows [list 0 $b [expr {$y - $pt}] [expr {$y + $cap}]] }
	lappend rows [list $b [expr {$b + 1}] [expr {[string first t $clip] < 0 ? $y + $cap : $y}] [expr {[string first b $clip] < 0 ? $y + $h - $cap : $y + $h}]]
	if {[string first b $clip] < 0} { lappend rows [list [expr {$b + 1}] $ih [expr {$y + $h - $cap}] [expr {$y + $h + $pb}]] }
	set out {}
	foreach rw $rows {
		lassign $rw sy0 sy1 dy0 dy1
		foreach cl $cols {
			lassign $cl sx0 sx1 dx0 dx1
			if {$sx1 <= $sx0 || $sy1 <= $sy0 || $dx1 <= $dx0 || $dy1 <= $dy0} continue
			lappend out [list $k $sx0 $sy0 [expr {$sx1 - $sx0}] [expr {$sy1 - $sy0}] $dx0 $dy0 [expr {$dx1 - $dx0}] [expr {$dy1 - $dy0}]]
		}
	}
	return $out
}

# Extra pieces from any picture (a concave fillet, say): {photo x y}.
proc rbn::piece {img x y} {
	variable looks
	set k P$img
	if {![info exists looks($k)]} {
		if {[native] && [argb]} { rbnalpha::template $k $img }
		set looks($k) [list $img 0 0 0 0 0 [image width $img] [image height $img] {}]
	}
	set w [image width $img]; set h [image height $img]
	list $k 0 0 $w $h $x $y $w $h
}

# The inside of a framed box: inset by the ring on its ringed sides.
proc rbn::inside {k x y w h} {
	variable looks
	set opts [lindex $looks($k) 8]
	set r 0
	if {[dict exists $opts -radius]} { set r [dict get $opts -radius] }
	if {[llength $r] != 4} { set r [list $r $r $r $r] }
	set rw 0; set sides tlrb
	if {[dict exists $opts -ring] && [llength [dict get $opts -ring]] >= 2} {
		lassign [dict get $opts -ring] - rw sd
		if {$sd ne ""} { set sides $sd }
	}
	set l [expr {[string first l $sides] >= 0 ? $rw : 0}]; set t [expr {[string first t $sides] >= 0 ? $rw : 0}]
	set rr [expr {[string first r $sides] >= 0 ? $rw : 0}]; set b [expr {[string first b $sides] >= 0 ? $rw : 0}]
	list [expr {$x + $l}] [expr {$y + $t}] [expr {$w - $l - $rr}] [expr {$h - $t - $b}] [lmap v $r { expr {max(0.0, $v - $rw)} }]
}

proc rbn::insides {frames} {
	set out {}
	foreach f $frames {
		lassign $f k x y w h
		lappend out [inside $k $x $y $w $h]
	}
	return $out
}

proc rbn::surface {w args} {
	variable cmap
	set o [dict merge {-class "" -managed 0 -fill #000000} $args]
	forget $w
	set cls [expr {[dict get $o -class] ne "" ? [list -class [dict get $o -class]] : {}}]
	if {[argb]} {
		if {$cmap eq "" || ![winfo exists $cmap]} {
			set cmap .rbnalpha
			toplevel $cmap -visual {truecolor 32} -colormap new -width 1 -height 1
			wm overrideredirect $cmap 1
			wm withdraw $cmap
		}
		toplevel $w -visual {truecolor 32} -colormap $cmap -background "" -borderwidth 0 -highlightthickness 0 {*}$cls
	} else {
		toplevel $w -background [dict get $o -fill] -borderwidth 0 -highlightthickness 0 {*}$cls
	}
	if {![dict get $o -managed]} { wm overrideredirect $w 1 }
	wm withdraw $w
	bindtags $w [linsert [bindtags $w] 0 RbnSurface]
	canvas $w.c -highlightthickness 0 -borderwidth 0 -background [dict get $o -fill]
	if {[argb]} { rbnalpha::plain $w.c }
	place $w.c -x 0 -y 0
	return $w.c
}

# Translate boxes by dx dy.
proc rbn::moved {boxes dx dy} {
	lmap b $boxes { lreplace $b 0 1 [expr {[lindex $b 0] + $dx}] [expr {[lindex $b 1] + $dy}] }
}

proc rbn::show {w x y ww wh args} {
	variable shown
	set o [dict merge [list -frames {} -pieces {} -content [list 0 0 $ww $wh] -extra {} -shape "" -input "" -raise 1] $args]
	set frames [lmap f [dict get $o -frames] { lreplace $f 0 0 [look [lindex $f 0]] }]
	lassign [dict get $o -content] cx cy cw ch
	set extra [dict get $o -extra]
	set shape [dict get $o -shape]
	if {$shape eq ""} { set shape [concat [insides $frames] $extra] }
	set input [dict get $o -input]
	if {$input eq ""} {
		set input $extra
		foreach f $frames {
			lassign $f k bx by bw bh
			lappend input [list $bx $by $bw $bh [lindex [inside $k $bx $by $bw $bh] 4]]
		}
	}
	set g ${ww}x$wh+[expr {int($x)}]+[expr {int($y)}]
	if {[wm geometry $w] ne $g} { wm geometry $w $g }
	set c [list $cx $cy $cw $ch]
	if {![info exists shown($w,c)] || $shown($w,c) ne $c} {
		place $w.c -x $cx -y $cy -width $cw -height $ch
		$w.c configure -width $cw -height $ch
		set shown($w,c) $c
	}
	if {[argb]} {
		# the frames, then the extra pieces over them (a fillet over a ring)
		set pieces {}
		foreach f $frames { lappend pieces {*}[pieces {*}$f] }
		lappend pieces {*}[dict get $o -pieces]
		set key [list $ww $wh $pieces $shape $input $c]
		if {![info exists shown($w)] || $shown($w) ne $key} {
			rbnalpha::frame $w $ww $wh $pieces
			rbnalpha::shape $w.c [moved $shape [expr {-$cx}] [expr {-$cy}]]
			rbnalpha::input $w $input
			set shown($w) $key
		}
	}
	if {[wm state $w] ne "normal"} {
		wm deiconify $w
		# Xwayland 24 under labwc 0.20: a newly mapped ARGB override-redirect window whose input region was set while
		# it was unmapped shows nothing at all until that region is set again (found 24 Nov by tests/term/run.sh against
		# labwc 0.20.3: the terminal's "Close this tab?" sheet was mapped, placed and invisible). Setting it once more,
		# after the map has reached the compositor, makes Xwayland show the window; elsewhere it changes nothing.
		if {[argb]} { after 40 [list rbn::Reinput $w] }
	}
	if {[dict get $o -raise]} { raise $w }
}

# the input region rbn::show last gave W, set again (see rbn::show)
proc rbn::Reinput {w} {
	variable shown
	if {[winfo exists $w] && [winfo ismapped $w] && [info exists shown($w)]} { rbnalpha::input $w [lindex $shown($w) 4] }
}

proc rbn::popup {w x y bw bh look args} {
	set o [dict merge {-clip "" -raise 1} $args]
	set k [look $look]
	variable looks
	lassign $looks($k) - pad pt pb
	set clip [dict get $o -clip]
	set l [expr {[string first l $clip] >= 0 ? 0 : $pad}]; set r [expr {[string first r $clip] >= 0 ? 0 : $pad}]
	set t [expr {[string first t $clip] >= 0 ? 0 : $pt}]; set b [expr {[string first b $clip] >= 0 ? 0 : $pb}]
	show $w [expr {$x - $l}] [expr {$y - $t}] [expr {$bw + $l + $r}] [expr {$bh + $t + $b}] \
		-frames [list [list $look $l $t $bw $bh $clip]] -content [list $l $t $bw $bh] -raise [dict get $o -raise]
}

# Move a popup: its box's top-left to screen x y.
proc rbn::move {w x y} {
	variable shown
	lassign $shown($w,c) cx cy
	wm geometry $w +[expr {int($x) - $cx}]+[expr {int($y) - $cy}]
}

proc rbn::forget {w} {
	variable shown
	array unset shown $w
	array unset shown $w,*
}

# Hide a surface and let go of its frame (the X server frees it once no
# other window shows it, past a small cache); shown again, it gets it back.
# An override-redirect window cannot keep the X focus under a Wayland compositor (see Keys in rbnalpha.c); a
# keyboard grab gets it the keys. It can only be taken once the window is viewable: tried every 25 ms, 40 times.
proc rbn::keys {w on} {
	variable keys
	if {![native]} { return 0 }
	if {[info exists keys(try)]} { after cancel $keys(try); unset keys(try) }
	if {!$on} {
		if {[info exists keys(held)] && $keys(held) eq $w} { catch {rbnalpha::keys $w 0}; unset keys(held) }
		return 1
	}
	Keys $w 40
}
proc rbn::Keys {w tries} {
	variable keys
	unset -nocomplain keys(try)
	if {![winfo exists $w]} { return 0 }
	if {[winfo ismapped $w] && ![catch {rbnalpha::keys $w 1} r] && $r} { set keys(held) $w; return 1 }
	if {$tries > 1} { set keys(try) [after 25 [list rbn::Keys $w [expr {$tries - 1}]]] }
	return 0
}

proc rbn::hide {w} {
	if {![winfo exists $w]} return
	keys $w 0
	if {[wm state $w] ne "withdrawn"} { wm withdraw $w }
	gone $w
}

proc rbn::gone {w} {
	variable shown
	array unset shown $w
	if {[native]} { catch {rbnalpha::release $w} }
}
bind RbnSurface <Destroy> {if {[winfo toplevel %W] eq "%W"} { rbn::gone %W }}

# ---- app windows that draw their own frame -----------------------------------------
#
# The installer draws its whole window, frame included, into a photo. With
# -ownframe 1 (the installer; or RIBBON_OWN_FRAME=1 for every app) rbn::appwindow
# W CLASS WIDTH HEIGHT makes W a managed ARGB toplevel (labwc draws no title
# bar for these classes) with a WIDTH x HEIGHT canvas W.c and returns 1 (or a
# plain toplevel, 0, without ARGB). Otherwise W is a plain managed toplevel that
# labwc frames (title bar, icon, buttons), and the app paints a square window. rbn::appframe W PHOTO RADIUS ?RING?: PHOTO, drawn on a transparent
# background, becomes the window's background, and W.c is cut to the inside
# of its rounded box: the corners are see-through, anti-aliased by the X
# server, whatever is behind.

# The compositor frames Ribbon's app windows (labwc draws the title bar, the
# border and the shadow) unless RIBBON_OWN_FRAME=1 asks for the app's own
# see-through frame. -ownframe 1 keeps the own frame for one window (the
# installer, whose rule keeps its decoration off).
proc rbn::framed {} {
	expr {![info exists ::env(RIBBON_OWN_FRAME)] || $::env(RIBBON_OWN_FRAME) ne "1"}
}

# The tallest client a framed app window can have on this screen: labwc keeps the whole frame (the
# 40 px title bar with its 1 px top border, and the 1 px bottom border) between the shell's bars (rc.xml
# margin top and bottom 54: the client of a 900-high screen starts at y 95)
# and shrinks a taller client at its bottom edge, which clips the app's footer. An app that wants H
# calls rbn::fit H before it sizes its window; the fitted height is what it lays out and draws for.
proc rbn::fit {h} {
	if {![framed]} { return $h }
	set room [expr {[winfo screenheight .] - 54 - 54 - 41 - 1}]
	expr {min($h, $room)}
}

proc rbn::appwindow {w class width height args} {
	set o [dict merge [list -fill #000000 -ownframe [expr {![framed]}]] $args]
	set own [expr {[dict get $o -ownframe] && [argb]}]
	forget $w
	if {$own} {
		surface $w -class $class -managed 1 -fill [dict get $o -fill]
		# an app window shows itself as an ordinary toplevel would
		wm deiconify $w
	} else {
		toplevel $w -class $class -borderwidth 0 -highlightthickness 0 -background [dict get $o -fill]
		canvas $w.c -highlightthickness 0 -borderwidth 0 -background [dict get $o -fill]
		place $w.c -x 0 -y 0
	}
	place $w.c -x 0 -y 0 -width $width -height $height
	$w.c configure -width $width -height $height
	$w configure -width $width -height $height
	# labwc frames the window, so its outer corners are the compositor's: the app draws them square (rbn::squared)
	set ::rbn::corner_square($w) [expr {[framed] && ![dict get $o -ownframe]}]
	return $own
}

# 1 when labwc frames the window W (rbn::appwindow): the app's outer corners are square there.
proc rbn::squared {w} {
	expr {[info exists ::rbn::corner_square($w)] && $::rbn::corner_square($w)}
}

proc rbn::appframe {w photo radius {ring 1}} {
	variable shown
	if {![argb]} return
	set key [list $photo [image width $photo] [image height $photo] $radius $ring]
	if {[info exists shown($w,app)] && $shown($w,app) eq $key} return
	set W [image width $photo]; set H [image height $photo]
	rbnalpha::backdrop $w $photo
	rbnalpha::shape $w.c [list [list $ring $ring [expr {$W - 2 * $ring}] [expr {$H - 2 * $ring}] [expr {max(0, $radius - $ring)}]]]
	rbnalpha::input $w [list [list 0 0 $W $H $radius]]
	set shown($w,app) $key
}

# ---- widgets: corner sprites ----------------------------------------------------

# A look's sprites on a surface: {n tl tr br bl edges}; edges: {side depth colour}.
proc rbn::sprites {opts on} {
	variable spr
	set key [list $opts $on]
	if {[info exists spr($key)]} { return $spr($key) }
	set r 0
	if {[dict exists $opts -radius]} { set r [tcl::mathfunc::max {*}[dict get $opts -radius]] }
	set rw 0
	if {[dict exists $opts -ring] && [llength [dict get $opts -ring]] >= 2} { set rw [lindex [dict get $opts -ring] 1] }
	set n [expr {max(1, int(ceil(max($r, $rw))))}]
	set t [expr {2 * $n + 1}]
	lassign [picture $t $t $opts] img
	set res [list $n]
	foreach {fx fy} [list 0 0 [expr {$n + 1}] 0 [expr {$n + 1}] [expr {$n + 1}] 0 [expr {$n + 1}]] {
		set p [image create photo -width $n -height $n]
		if {$on ne ""} { $p put $on -to 0 0 $n $n }
		$p copy $img -from $fx $fy [expr {$fx + $n}] [expr {$fy + $n}] -to 0 0 \
			-compositingrule [expr {$on ne "" ? "overlay" : "set"}]
		lappend res $p
	}
	set fill [string tolower [dict get $opts -fill]]
	set edges {}
	for {set k 0} {$k < $n} {incr k} {
		foreach {side x y} [list t $n $k b $n [expr {2 * $n - $k}] l $k $n r [expr {2 * $n - $k}] $n] {
			set col [format #%02x%02x%02x {*}[$img get $x $y]]
			if {$col ne $fill} { lappend edges [list $side $k $col] }
		}
	}
	lappend res $edges
	set spr($key) $res
}

proc rbn::box {cv x y w h args} {
	set o [dict merge {-fill #000000 -radius 0 -on "" -tags ""} $args]
	set on [dict get $o -on]; set tags [dict get $o -tags]
	set opts [dict remove $o -on -tags]
	if {[dict exists $opts -ring] && [dict get $opts -ring] eq ""} { dict unset opts -ring }
	lassign [sprites $opts $on] n tl tr br bl edges
	set x [expr {round($x)}]; set y [expr {round($y)}]; set w [expr {round($w)}]; set h [expr {round($h)}]
	set x1 [expr {$x + $w}]; set y1 [expr {$y + $h}]
	set fill [dict get $opts -fill]
	if {$w < 2 * $n || $h < 2 * $n} {
		lassign [picture $w $h $opts] img
		if {$on ne ""} {
			set k [list $w $h $opts $on]
			variable spr
			if {![info exists spr(x$k)]} {
				set p [image create photo -width $w -height $h]
				$p put $on -to 0 0 $w $h
				$p copy $img -to 0 0 -compositingrule overlay
				set spr(x$k) $p
			}
			set img $spr(x$k)
		}
		$cv create image $x $y -image $img -anchor nw -tags $tags
		return
	}
	if {$x1 - $n > $x + $n} { $cv create rectangle [expr {$x + $n}] $y [expr {$x1 - $n}] $y1 -fill $fill -width 0 -tags $tags }
	if {$y1 - $n > $y + $n} { $cv create rectangle $x [expr {$y + $n}] $x1 [expr {$y1 - $n}] -fill $fill -width 0 -tags $tags }
	foreach e $edges {
		lassign $e side k col
		switch $side {
			t { if {$x1 - $n > $x + $n} { $cv create rectangle [expr {$x + $n}] [expr {$y + $k}] [expr {$x1 - $n}] [expr {$y + $k + 1}] -fill $col -width 0 -tags $tags } }
			b { if {$x1 - $n > $x + $n} { $cv create rectangle [expr {$x + $n}] [expr {$y1 - $k - 1}] [expr {$x1 - $n}] [expr {$y1 - $k}] -fill $col -width 0 -tags $tags } }
			l { if {$y1 - $n > $y + $n} { $cv create rectangle [expr {$x + $k}] [expr {$y + $n}] [expr {$x + $k + 1}] [expr {$y1 - $n}] -fill $col -width 0 -tags $tags } }
			r { if {$y1 - $n > $y + $n} { $cv create rectangle [expr {$x1 - $k - 1}] [expr {$y + $n}] [expr {$x1 - $k}] [expr {$y1 - $n}] -fill $col -width 0 -tags $tags } }
		}
	}
	$cv create image $x $y -image $tl -anchor nw -tags $tags
	$cv create image $x1 $y -image $tr -anchor ne -tags $tags
	$cv create image $x1 $y1 -image $br -anchor se -tags $tags
	$cv create image $x $y1 -image $bl -anchor sw -tags $tags
}

# ---- ttk ---------------------------------------------------------------------------

proc rbn::ttk {style args} {
	set o [dict merge {-fill #000000 -radius 0 -on "" -mid 64} $args]
	set on [dict get $o -on]; set mid [dict get $o -mid]
	set opts [dict remove $o -on -mid]
	set r [tcl::mathfunc::max {*}[dict get $opts -radius]]
	set n [expr {max(1, int(ceil($r)))}]
	set t [expr {2 * $n + 1}]
	lassign [picture $t $t $opts] img
	set T [expr {2 * $n + $mid}]
	set p [image create photo -width $T -height $T]
	if {$on ne ""} { $p put $on -to 0 0 $T $T }
	set rule [expr {$on ne "" ? "overlay" : "set"}]
	foreach {sy0 sy1 ty0 ty1} [list 0 $n 0 $n  $n [expr {$n + 1}] $n [expr {$n + $mid}]  [expr {$n + 1}] $t [expr {$n + $mid}] $T] {
		foreach {sx0 sx1 tx0 tx1} [list 0 $n 0 $n  $n [expr {$n + 1}] $n [expr {$n + $mid}]  [expr {$n + 1}] $t [expr {$n + $mid}] $T] {
			$p copy $img -from $sx0 $sy0 $sx1 $sy1 -to $tx0 $ty0 $tx1 $ty1 -compositingrule $rule
		}
	}
	::ttk::style element create $style.box image $p -border $n -padding 0 -sticky nsew
	::ttk::style layout $style.TButton [list $style.box -sticky nsew \
		-children {Button.padding -sticky nsew -children {Button.label -sticky nsew}}]
	return $style.TButton
}

proc rbn::stats {} {
	variable spr
	variable looks
	set d [dict create looks [array size looks] sprite_sets [array size spr]]
	if {[native]} { set d [dict merge $d [rbnalpha::stats]] }
	return $d
}

# ---- blur ------------------------------------------------------------------------------
#
# rbn::blur SRC DST RADIUS ?-dim PERCENT?: photo SRC blurred as CSS
# blur(RADIUS) into DST (a Gaussian of that standard deviation), darkened by
# PERCENT. In C: three box passes on a copy shrunk by RADIUS / 3 (at most
# 8), enlarged bilinearly: 2560 x 1440 at radius 12 to 32 in 32 to 41 ms.
# Without the C library: the same in Tcl on a copy shrunk to at most 320 px
# wide, enlarged by Tk in whole steps (blockier; about a second, not ten).
proc rbn::blur {src dst radius args} {
	set dim 0
	if {[llength $args]} {
		if {[lindex $args 0] ne "-dim" || [llength $args] != 2} { error "wrong # args: should be \"rbn::blur src dst radius ?-dim percent?\"" }
		set dim [lindex $args 1]
	}
	if {[native]} { return [rbnalpha::blur $src $dst $radius -dim $dim] }
	set W [image width $src]; set H [image height $src]
	set k [expr {max(1, int(ceil($radius / 2.0)), int(ceil($W / 320.0)))}]
	set small [image create photo]
	$small copy $src -subsample $k
	set w [image width $small]; set h [image height $small]
	set R {}; set G {}; set B {}
	foreach row [$small data] {
		foreach hex $row { scan $hex #%2x%2x%2x r g b; lappend R $r; lappend G $g; lappend B $b }
	}
	set s [expr {double($radius) / $k}]
	set r [expr {int(round((sqrt(12.0 * $s * $s / 3 + 1) - 1) / 2))}]
	set f [expr {max(0.0, 1.0 - $dim / 100.0)}]
	foreach ch {R G B} {
		set v [set $ch]
		if {$r >= 1} {
			for {set pass 0} {$pass < 3} {incr pass} { set v [boxpass [boxpass $v $w $h $r] $h $w $r] }
		}
		set $ch $v
	}
	set rows {}
	for {set y 0} {$y < $h} {incr y} {
		set row {}
		for {set x 0} {$x < $w} {incr x} {
			set i [expr {$y * $w + $x}]
			lappend row [format #%02x%02x%02x [expr {int([lindex $R $i] * $f + 0.5)}] \
				[expr {int([lindex $G $i] * $f + 0.5)}] [expr {int([lindex $B $i] * $f + 0.5)}]]
		}
		lappend rows $row
	}
	$small put $rows -to 0 0
	set big [image create photo]
	$big copy $small -zoom $k
	$dst blank
	$dst configure -width $W -height $H
	$dst copy $big -from 0 0 $W $H -to 0 0
	$dst configure -width 0 -height 0
	image delete $small $big
}

# One box pass of radius R along the rows of a W x H channel (edges
# extended). The result comes back transposed, so two calls make a
# horizontal and a vertical pass.
proc rbn::boxpass {v w h r} {
	set n [expr {2 * $r + 1}]
	set out {}
	for {set y 0} {$y < $h} {incr y} {
		set row [lrange $v [expr {$y * $w}] [expr {$y * $w + $w - 1}]]
		set ext [concat [lrepeat $r [lindex $row 0]] $row [lrepeat [expr {$r + 1}] [lindex $row end]]]
		set sum 0
		for {set i 0} {$i < $n} {incr i} { incr sum [lindex $ext $i] }
		for {set x 0} {$x < $w} {incr x} {
			lappend out [expr {($sum + $r) / $n}]
			incr sum [expr {[lindex $ext [expr {$x + $n}]] - [lindex $ext $x]}]
		}
	}
	# transpose: the next call walks the columns
	set tr {}
	for {set x 0} {$x < $w} {incr x} { for {set y 0} {$y < $h} {incr y} { lappend tr [lindex $out [expr {$y * $w + $x}]] } }
	return $tr
}
