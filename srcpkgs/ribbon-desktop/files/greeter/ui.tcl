# ui.tcl - the login screen, drawn as the approved mockups draw it
# (design/mockups/Greet-*.dc.html; CSS px, 1440 x 900 board).
#
# As in the Ribbon shell, everything that doesn't move is composited into
# one photo the size of the screen: the theme wallpaper, the pills with
# their shadows, the field, the avatars (shell/raster.tcl does the
# anti-aliasing). Text and icons sit on top as canvas items. Positions are
# the mockups' own: the column is centred, and its offsets from the
# middle of the screen are those of the 900 px board.

namespace eval ui {
	variable W 1440
	variable H 900
	variable bg ""          ;# the composited background photo
	variable wallimg ""     ;# the wallpaper at screen size
	variable opt {FIT fill BLUR 0 DIM 0 CLOCK yes COLOUR ""}   ;# options.conf
	variable preview 0      ;# drawn for the Appearance app (greeter/preview.tcl)
	variable hits {}        ;# {x0 y0 x1 y1 script}
	variable hover ""       ;# the power button under the pointer
	# The mockups' own line icons (24 x 24 viewBox)
	array set ::theme::icon {
		g-kbd     {M2 6h20v12H2z M6 10h.01 M10 10h.01 M14 10h.01 M18 10h.01 M7 14h10}
		g-moon    {M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z}
		g-restart {M1 4v6h6 M3.51 15a9 9 0 1 0 2.13-9.36L1 10}
		g-power   {M18.36 6.64a9 9 0 1 1-12.73 0 M12 2v10}
		g-arrow   {M5 12h14 M12 5l7 7-7 7}
		g-alert   {M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z M12 9v4 M12 17h.01}
	}
}

# The mockups' fonts at their weights (shell/text.tcl).
proc ui::fonts {} {
	foreach {name family size} {
		gclock {Ribbon Space Grotesk 600} 120
		gav40  {Ribbon Space Grotesk 600} 40
		gav37  {Ribbon Space Grotesk 600} 37
		g18s   {Ribbon Inter 600} 18
		g18    {Ribbon Inter 400} 18
		g16    {Ribbon Inter 400} 16
		g15    {Ribbon Inter 400} 15
		g15s   {Ribbon Inter 600} 15
		g13    {Ribbon Inter 400} 13
		g13s   {Ribbon Inter 600} 13
		g12    {Ribbon Inter 400} 12
		g11s   {Ribbon Inter 600} 11
	} {
		text::font $name $family $size
	}
}

# Where each letter goes, {x0 x1 ... width}, and the width: the font file's
# advances and kerning with CSS letter-spacing LS (shell/text.tcl).
proc ui::layout {font text {ls 0}} { text::layout $font $text $ls }
proc ui::adv {font text {ls 0}} { text::width $font $text $ls }

# Text with its baseline at y, each letter where a browser would put it.
# anchor: w (x is the left edge), c (centred on x) or e (the right edge).
proc ui::text {x y font colour text {anchor w} {ls 0}} {
	set top [expr {round($y) - [font metrics $font -ascent]}]
	text::draw .c $x $top $font $colour $text [dict get {w nw c n e ne} $anchor] -ls $ls
}

# A line icon of SIZE with its top-left at x y: snapped to the pixel grid,
# as the browser snaps an inline SVG.
proc ui::icon {name size stroke colour x y} {
	set img [theme::icon $name $size $stroke $colour]
	.c create image [expr {int(floor($x + 0.5))}] [expr {int(floor($y + 0.5))}] -image $img -anchor nw
}

proc ui::hit {x0 y0 x1 y1 script} {
	variable hits
	lappend hits [list $x0 $y0 $x1 $y1 $script]
}

# ---- shapes the shell's raster.tcl doesn't draw --------------------------

# A rounded box with a translucent fill and an inset ring (the chosen user's
# glass card), or a circle filled with the avatar's 150-degree gradient,
# accent to accent at 35 % (grad = the end alpha).
proc ui::shape {w h r fill alpha {ring {}} {rw 0} {grad {}}} {
	raster::cached [list greeter-shape $w $h $r $fill $alpha $ring $rw $grad] {
		lassign [raster::rgb $fill] fr fg fb
		if {$ring ne ""} { lassign [raster::rgb $ring] rr rg rb }
		# CSS linear-gradient(150deg): the line runs along (sin, -cos) of the
		# angle, long enough that the corners get 0 and 1
		set dx 0.5; set dy 0.8660254037844386
		set len [expr {$w * $dx + $h * $dy}]
		set rows {}
		for {set y 0} {$y < $h} {incr y} {
			set row {}
			for {set x 0} {$x < $w} {incr x} {
				set px [expr {$x + 0.5}]; set py [expr {$y + 0.5}]
				set co [raster::rbox $px $py 0 0 $w $h $r]
				if {$co <= 0} { lappend row 0 0 0 0; continue }
				set fa $alpha
				if {$grad ne ""} {
					set t [expr {(($px - $w / 2.0) * $dx + ($py - $h / 2.0) * $dy) / $len + 0.5}]
					set t [expr {min(1.0, max(0.0, $t))}]
					set fa [expr {1.0 + ($grad - 1.0) * $t}]
				}
				set ci $co
				if {$rw > 0} { set ci [raster::rbox $px $py $rw $rw [expr {$w - $rw}] [expr {$h - $rw}] [expr {max(0.0, $r - $rw)}]] }
				set ra [expr {$co - $ci}]
				set fA [expr {$ci * $fa}]
				set a [expr {$ra + $fA}]
				if {$a <= 0} { lappend row 0 0 0 0; continue }
				if {$ra > 0} {
					set k [expr {$ra / $a}]
					lappend row [expr {int($rr * $k + $fr * (1 - $k) + 0.5)}] [expr {int($rg * $k + $fg * (1 - $k) + 0.5)}] \
						[expr {int($rb * $k + $fb * (1 - $k) + 0.5)}] [expr {int($a * 255 + 0.5)}]
				} else {
					lappend row $fr $fg $fb [expr {int($a * 255 + 0.5)}]
				}
			}
			lappend rows $row
		}
		raster::png $w $h $rows
	}
}

# Your account picture as a SIZE px circle (cover-cropped, anti-aliased
# edge), or "" when there is none or Tk can't read it. Made once per
# picture and kept in the drawing cache.
proc ui::face {user size} {
	set f [sys::face $user]
	if {$f eq ""} { return "" }
	if {[catch {raster::cached [list greeter-face $f [file mtime $f] [file size $f] $size] { face_png $f $size }} img]} {
		puts stderr "ribbon-greeter: $f: $img"
		return ""
	}
	return $img
}

proc ui::face_png {f size} {
	set src [image create photo -file $f]
	set w [image width $src]; set h [image height $src]
	# the middle square, brought near twice the size with Tk's subsample,
	# then averaged down to SIZE (each output pixel the mean of its area)
	set side [expr {min($w, $h)}]
	set k [expr {max(1, $side / (2 * $size))}]
	set sq [image create photo]
	$sq copy $src -from [expr {($w - $side) / 2}] [expr {($h - $side) / 2}] \
		[expr {($w + $side) / 2}] [expr {($h + $side) / 2}] -subsample $k $k
	image delete $src
	set n [image width $sq]
	set px {}
	foreach row [$sq data] {
		set r {}
		foreach hex $row { scan $hex #%2x%2x%2x cr cg cb; lappend r [list $cr $cg $cb] }
		lappend px $r
	}
	image delete $sq
	set step [expr {double($n) / $size}]
	set rows {}
	for {set y 0} {$y < $size} {incr y} {
		set y0 [expr {int($y * $step)}]; set y1 [expr {max($y0 + 1, int(($y + 1) * $step))}]
		set row {}
		for {set x 0} {$x < $size} {incr x} {
			set x0 [expr {int($x * $step)}]; set x1 [expr {max($x0 + 1, int(($x + 1) * $step))}]
			set sr 0; set sg 0; set sb 0; set cnt 0
			for {set yy $y0} {$yy < $y1} {incr yy} {
				foreach p [lrange [lindex $px $yy] $x0 [expr {$x1 - 1}]] {
					lassign $p cr cg cb
					incr sr $cr; incr sg $cg; incr sb $cb; incr cnt
				}
			}
			set a [raster::rbox [expr {$x + 0.5}] [expr {$y + 0.5}] 0 0 $size $size [expr {$size / 2.0}]]
			lappend row [expr {($sr + $cnt / 2) / $cnt}] [expr {($sg + $cnt / 2) / $cnt}] [expr {($sb + $cnt / 2) / $cnt}] \
				[expr {int(max(0.0, min(1.0, $a)) * 255 + 0.5)}]
		}
		lappend rows $row
	}
	raster::png $size $size $rows
}

proc ui::put {img x y} {
	variable bg
	raster::blit $bg $img 0 0 [image width $img] [image height $img] $x $y
}

# ---- setup ----------------------------------------------------------------

proc ui::init {} {
	variable W
	variable H
	variable bg
	variable wallimg
	set W [winfo screenwidth .]
	set H [winfo screenheight .]
	if {[info exists ::env(RIBBON_SCREEN)] && [regexp {^(\d+)x(\d+)$} $::env(RIBBON_SCREEN) -> W H]} {}
	fonts
	wm title . "Ribbon login"
	wm geometry . ${W}x${H}+0+0
	catch {wm attributes . -fullscreen 1}
	# asked again once mapped: labwc (through XWayland) ignores a full-screen request made before the window is
	# mapped and frames it with a title bar ("Ribbon login"). A tag of its own, so a <Map> binding on "." (the
	# Appearance preview's, greeter/preview.tcl) does not replace it.
	if {"RibbonGreeterFull" ni [bindtags .]} { bindtags . [linsert [bindtags .] 0 RibbonGreeterFull] }
	bind RibbonGreeterFull <Map> {if {"%W" eq "."} {catch {wm attributes . -fullscreen 1}}}
	. configure -background $theme::c(DESK_BOTTOM) -cursor left_ptr
	canvas .c -width $W -height $H -highlightthickness 0 -borderwidth 0 -background $theme::c(DESK_BOTTOM)
	pack .c
	set bg [image create photo -width $W -height $H]
	# the login picture, scaled and cropped to the screen (once; cached)
	variable opt
	set colour [dict get $opt COLOUR]
	if {$wall::image ne ""} {
		if {[catch {
			set f [set base [wall::prepare $wall::image $W $H [dict get $opt FIT] [expr {$colour ne "" ? $colour : $theme::c(DESK_BOTTOM)}]]]
			set blur [dict get $opt BLUR]
			variable preview
			if {$blur > 0 && $preview && ![file exists [file rootname $f]-blur$blur.png] && ![wall::fast_blur]} {
				# the Appearance app's preview: the cheap blur until the app
				# has made the real one (it then says "reload")
				set src [image create photo -file $f]
				set q [wall::blurred_quick $src $blur]
				image delete $src
				set q
			} else {
				if {$blur > 0} { set f [wall::blurred $f $blur] }
				image create photo -file $f
			}
		} img]} {
			puts stderr "ribbon-greeter: login background $wall::image: $img; using the ribbon pattern"
		} else {
			set wall::full $img
			# the copies for earlier pictures or screen sizes
			# (not in a preview: the cache is the Appearance app's)
			if {!$preview} {
				foreach old [glob -nocomplain -directory [file dirname $f] img-*.png] {
					if {$old ne $f && $old ne $base} { file delete $old }
				}
			}
		}
	}
	if {$wall::full eq "" && $colour ne ""} {
		set wall::full [image create photo -width $W -height $H]
		$wall::full put $colour -to 0 0 $W $H
	}
	# else the theme wallpaper's gradient and stripes, exactly (shell/wall.tcl),
	# in bands so the first start (nothing cached yet) stays small
	set wallimg [image create photo -width $W -height $H]
	for {set y 0} {$y < $H} {incr y 64} {
		set band [wall::region [array get theme::c] 0 $y $W [expr {min(64, $H - $y)}] $W $H]
		$wallimg copy $band -to 0 $y
		image delete $band
	}
	# dimmed: black at DIM percent over it
	if {[dict get $opt DIM] > 0} {
		set a [expr {int(round([dict get $opt DIM] * 2.55))}]
		set shade [image create photo -data [raster::png 1 1 [list [list 0 0 0 $a]]] -format png]
		$wallimg copy $shade -to 0 0 $W $H -compositingrule overlay
		image delete $shade
	}
	bind . <KeyPress> {login::key %K %A %s}
	bind . <KeyRelease> {login::caps_from %K %s 0}
	bind .c <Motion> {login::caps_from "" %s 0; ui::motion %x %y}
	bind .c <Leave> {ui::motion -1 -1}
	bind .c <ButtonPress-1> {ui::click %x %y 1}
	bind .c <ButtonPress-3> {ui::click %x %y 3}
	# a preview never takes the keyboard from the Appearance sheet
	variable preview
	if {!$preview} { focus -force . }
}

proc ui::click {x y b} {
	variable hits
	foreach h [lreverse $hits] {
		lassign $h x0 y0 x1 y1 script
		if {$x >= $x0 && $x < $x1 && $y >= $y0 && $y < $y1} { uplevel #0 [linsert $script end $b]; return }
	}
}

proc ui::motion {x y} {
	variable hits
	variable hover
	set h ""
	foreach t $hits {
		lassign $t x0 y0 x1 y1 script
		if {[lindex $script 0] eq "login::power" && $x >= $x0 && $x < $x1 && $y >= $y0 && $y < $y1} { set h [lindex $script 1] }
	}
	.c configure -cursor [expr {[hand $x $y] ? "hand2" : "left_ptr"}]
	if {$h ne $hover} { set hover $h; redraw }
}

proc ui::hand {x y} {
	variable hits
	foreach t $hits {
		lassign $t x0 y0 x1 y1
		if {$x >= $x0 && $x < $x1 && $y >= $y0 && $y < $y1} { return 1 }
	}
	return 0
}

proc ui::redraw {} {
	after cancel ui::draw
	after idle ui::draw
}

# ---- the screen -------------------------------------------------------------

proc ui::draw {} {
	variable W
	variable H
	variable bg
	variable wallimg
	variable hits {}
	array set c [array get theme::c]
	.c delete all
	$bg copy $wallimg -to 0 0
	set pill [list -fill $c(BAR) -radius 12 -ring [list $c(BORDER) 1] -shadow $c(BAR_SHADOW)]
	set later {}

	# ---- top right: keyboard layout | Wi-Fi, battery
	set items [list [list icon g-kbd 15 1.9 19.5] [list text g13 $c(MUTED) [login::layout_text]]]
	set status {}
	if {$status::wifi ne ""} { lappend status [list icon [expr {$status::wifi eq "on" ? "wifi" : "wifi-off"}] 15 1.9 19.5] }
	if {$status::battery ne ""} {
		lappend status [list icon battery 16 1.9 19] [list text g13s $c(FG) "[expr {min(100, $status::battery)}]%"]
	}
	if {[llength $status]} { lappend items {divider} {*}$status }
	set pw 24
	foreach i $items {
		switch [lindex $i 0] {
			icon { set pw [expr {$pw + [lindex $i 2]}] }
			text { set pw [expr {$pw + [adv [lindex $i 1] [lindex $i 3]]}] }
			divider { set pw [expr {$pw + 1}] }
		}
	}
	set pw [expr {$pw + 12 * ([llength $items] - 1)}]
	set px [expr {$W - 8 - $pw}]
	raster::box $bg [expr {round($px)}] 8 [expr {$W - 8 - round($px)}] 38 {*}$pill
	set x [expr {$px + 12}]
	foreach i $items {
		switch [lindex $i 0] {
			icon {
				lassign $i - name sz st y
				lappend later [list icon $name $sz $st $c(MUTED) $x $y]
				set x [expr {$x + $sz + 12}]
			}
			text {
				lassign $i - font col t
				lappend later [list text $x 32 $font $col $t]
				set x [expr {$x + [adv $font $t] + 12}]
			}
			divider {
				$bg put $c(BORDER) -to [expr {round($x)}] 19 [expr {round($x) + 1}] 35
				set x [expr {$x + 13}]
			}
		}
	}
	hit [expr {round($px)}] 8 [expr {$W - 8}] 46 login::layout_next

	# ---- bottom left: the session, or the menu rising out of it
	# (not in a preview: the Appearance sheet covers the corners)
	set sy [expr {$H - 46}]
	variable preview
	if {$preview} {
	} elseif {$login::smenu} {
		set later [session_menu $later $pill]
	} else {
		lassign [login::session_words] s1 s2
		set sw [expr {12 + [adv g13s $s1] + 8 + [adv g13 $s2] + 8 + 12 + 12}]
		raster::box $bg 8 $sy [expr {round(8 + $sw) - 8}] 38 {*}$pill
		lappend later [list text 20 [expr {$sy + 24}] g13s $c(ACCENT) $s1]
		set x [expr {20 + [adv g13s $s1] + 8}]
		lappend later [list text $x [expr {$sy + 24}] g13 $c(MUTED) $s2]
		set x [expr {$x + [adv g13 $s2] + 8}]
		lappend later [list icon down 12 2.2 $c(MUTED) $x [expr {$sy + 13}]]
		hit 8 $sy [expr {8 + $sw}] [expr {$sy + 38}] login::session_open
	}

	# ---- bottom right: suspend, restart, power off
	variable hover
	set bx [expr {$W - 8 - 114}]
	if {!$preview} { raster::box $bg $bx $sy 114 38 {*}$pill }
	foreach {k name} [expr {$preview ? {} : {suspend g-moon restart g-restart poweroff g-power}}] {
		set x [expr {$bx + 4}]
		if {$hover eq $k} { raster::box $bg $x [expr {$sy + 4}] 34 30 -fill $c(FIELD) -radius 8 }
		lappend later [list icon $name 15 1.9 [expr {$hover eq $k ? $c(FG) : $c(MUTED)}] [expr {$x + 9.5}] [expr {$sy + 11.5}]]
		hit $x [expr {$sy + 4}] [expr {$x + 34}] [expr {$sy + 34}] [list login::power $k]
		incr bx 36
	}

	# ---- the clock: Space Grotesk 600 120 px, letter-spacing -0.05em,
	# line-height 0.9, the colon in the accent; the date under it
	set top [expr {$H / 2 - 300}]
	variable opt
	if {[dict get $opt CLOCK] eq "no"} {
		if {$login::view eq "users"} { users $later } else { password $later }
		return
	}
	set t $login::time
	set xs [layout gclock $t -6]
	set x [expr {($W - [lindex $xs end]) / 2.0}]
	foreach ch [split $t ""] cx [lrange $xs 0 end-1] {
		lappend later [list text [expr {$x + $cx}] [expr {$top + 95}] gclock [expr {$ch eq ":" ? $c(ACCENT) : $c(FG)}] $ch]
	}
	lappend later [list ctext [expr {$W / 2.0}] [expr {$top + 130}] g16 $c(MUTED) $login::date]

	if {$login::view eq "users"} { users $later } else { password $later }
}

# Greet-4: the sessions in a 280 px menu that rises out of the pill as one
# shape: SESSION, a 40 px row each (the highlighted one filled, the kept
# one ticked), a rule, and the pill's own row with its chevron turned up.
# Anywhere else closes it (registered first, so the rows win).
proc ui::session_menu {later pill} {
	variable W
	variable H
	variable bg
	array set c [array get theme::c]
	set sessions $login::sessions
	set n [llength $sessions]
	set lh 14              ;# 11 px Inter, line-height normal (11 + 3, as rounded)
	set h [expr {6 + 6 + $lh + 8 + 40 * $n + 6 + 1 + 38}]
	set top [expr {round($H - 8 - $h)}]
	hit 0 0 $W $H login::session_close
	raster::box $bg 8 $top 280 [expr {$H - 8 - $top}] {*}$pill
	lappend later [list text 22 [expr {$top + 12 + 11}] g11s $c(MUTED) SESSION 1.32]
	set y [expr {$top + 6 + 6 + $lh + 8}]
	set i 0
	foreach s $sessions {
		set ry [expr {round($y)}]
		if {$i == $login::shi} { raster::box $bg 12 $ry 272 40 -fill $c(FIELD) -radius 8 }
		lassign [sys::session_label $s] s1 s2
		set base [expr {$y + 20 + 4.7188}]
		lappend later [list text 22 $base g13s [expr {$s1 eq "Ribbon" ? $c(ACCENT) : $c(FG)}] $s1]
		set x [expr {22 + [adv g13s $s1] + 8}]
		set room [expr {$i == $login::sess ? 260 - 8 - $x : 274 - $x}]
		lappend later [list text $x $base g13 $c(MUTED) [text::clip g13 $s2 $room]]
		if {$i == $login::sess} { lappend later [list icon check 14 2.4 $c(ACCENT) 260 [expr {$y + 13}]] }
		hit 12 $ry 284 [expr {$ry + 40}] [list login::session_keep $i]
		set y [expr {$y + 40}]
		incr i
	}
	set y [expr {$y + 6}]
	$bg put $c(BORDER) -to 18 [expr {round($y)}] 278 [expr {round($y) + 1}]
	set y [expr {$y + 1}]
	lassign [login::session_words] s1 s2
	set base [expr {$y + 19 + 4.7188}]
	lappend later [list text 24 $base g13s $c(ACCENT) $s1]
	lappend later [list text [expr {24 + [adv g13s $s1] + 8}] $base g13 $c(MUTED) $s2]
	lappend later [list icon up-chev 12 2.2 $c(ACCENT) 260 [expr {$y + 13}]]
	hit 8 [expr {round($y)}] 288 [expr {$H - 8}] login::session_close
	return $later
}

# Draw the queued text and icons over the finished background.
proc ui::finish {later} {
	variable bg
	.c create image 0 0 -image $bg -anchor nw
	foreach l $later {
		switch [lindex $l 0] {
			text { lassign $l - x y font col t ls; text $x $y $font $col $t w [expr {$ls eq "" ? 0 : $ls}] }
			ctext { lassign $l - x y font col t; text $x $y $font $col $t c }
			icon { lassign $l - name sz st col x y; icon $name $sz $st $col $x $y }
			rect { lassign $l - x0 y0 x1 y1 col; .c create rectangle $x0 $y0 $x1 $y1 -fill $col -width 0 }
		}
	}
}

# Greet-1 / Greet-2: avatar, name, the field and what PAM says.
proc ui::password {later} {
	variable W
	variable H
	array set c [array get theme::c]
	set u [login::user]
	set T [expr {$H / 2 - 30}]
	set cx [expr {$W / 2.0}]
	# avatar: your picture, or your initial on the accent fading to 35 %
	set pic [face $u 96]
	if {$pic ne ""} { put $pic [expr {$W / 2 - 48}] $T } else {
		put [shape 96 96 48 $c(ACCENT) 1 {} 0 0.35] [expr {$W / 2 - 48}] $T
		lappend later [list ctext $cx [expr {$T + 62}] gav40 $c(ON_ACCENT) [dict get $u letter]]
	}
	lappend later [list ctext $cx [expr {$T + 129}] g18s $c(FG) [dict get $u full]]

	# the field: 340 x 46, a 1.5 px accent ring, the arrow button inside
	# (while the session menu has the keys: a plain ring, a quiet button)
	set menu $login::smenu
	set fx [expr {$W / 2 - 170}]; set fy [expr {$T + 149}]
	raster::box $::ui::bg $fx $fy 340 46 -fill $c(FIELD) -radius 12 -ring [expr {$menu ? [list $c(BORDER) 1] : [list $c(ACCENT) 1.5]}]
	raster::box $::ui::bg [expr {$fx + 300}] [expr {$fy + 6}] 34 34 -fill [expr {$menu ? $c(PILL) : $c(ACCENT)}] -radius 9
	lappend later [list icon g-arrow 16 2.2 [expr {$menu ? $c(MUTED) : $c(ON_ACCENT)}] [expr {$fx + 309}] [expr {$fy + 15}]]
	hit [expr {$fx + 300}] [expr {$fy + 6}] [expr {$fx + 334}] [expr {$fy + 40}] login::submit
	# what you typed (dots, letter-spaced 3 px, or the text for a visible
	# prompt) and the caret, centred in the space left of the button
	set n [string length $login::secret]
	set mid [expr {$fx + 46 + 122}]
	set base [expr {$fy + 30}]
	if {$menu && !$n} {
		lappend later [list ctext $mid [expr {$fy + 23 - 9.074 + 0.96875 * 15}] g15 $c(MUTED) Password]
	} elseif {$login::echo} {
		set dw [expr {[adv g18 •] + 3}]
		set gw [expr {$n * $dw + ($n ? 2 : 0) + 2}]
		set x [expr {$mid - $gw / 2.0}]
		for {set i 0} {$i < $n} {incr i} {
			lappend later [list text $x $base g18 $c(FG) •]
			set x [expr {$x + $dw}]
		}
	} else {
		set t $login::secret
		while {$t ne "" && [adv g18 $t] > 236} { set t [string range $t 1 end] }
		set tw [adv g18 $t]
		set gw [expr {$tw + ($t ne "" ? 2 : 0) + 2}]
		set x [expr {$mid - $gw / 2.0}]
		if {$t ne ""} { lappend later [list text $x $base g18 $c(FG) $t] }
		set x [expr {$x + $tw}]
	}
	if {$n} { set x [expr {$x + 2}] }
	if {!$login::busy && !$menu} {
		$::ui::bg put $c(ACCENT) -to [expr {round($x)}] [expr {$fy + 13}] [expr {round($x) + 2}] [expr {$fy + 33}]
	}

	# messages: what went wrong (accent) or what to do (muted), Caps Lock
	set y [expr {$T + 211}]
	set lines [expr {$menu ? {{info {↑ ↓ to choose a session · Enter to keep it}}} : [login::lines]}]
	foreach l $lines {
		lassign $l kind t
		switch $kind {
			error { lappend later [list ctext $cx [expr {$y + 13}] g13s $c(ACCENT) $t] }
			info { lappend later [list ctext $cx [expr {$y + 13}] g13 $c(MUTED) $t] }
			caps {
				set gw [expr {13 + 6 + [adv g13 $t]}]
				set x [expr {$cx - $gw / 2.0}]
				lappend later [list icon g-alert 13 1.9 $c(MUTED) $x [expr {$y + 1.5}]]
				lappend later [list text [expr {$x + 19}] [expr {$y + 13}] g13 $c(MUTED) $t]
			}
		}
		set y [expr {$y + 24}]
	}
	# "Other user": the picker
	if {[llength $login::users] > 1 && !$menu && !$ui::preview} {
		set y [expr {$y - 8 + 16 + 6}]
		lappend later [list ctext $cx [expr {$y + 12}] g12 $c(MUTED) "Other user"]
		set ow [adv g12 "Other user"]
		hit [expr {$cx - $ow / 2 - 6}] [expr {$y - 3}] [expr {$cx + $ow / 2 + 6}] [expr {$y + 18}] login::picker
	}
	hit $fx $fy [expr {$fx + 300}] [expr {$fy + 46}] login::focus_field
	finish $later
}

# Greet-3: the people who can log in, ← → and Enter.
proc ui::users {later} {
	variable W
	variable H
	array set c [array get theme::c]
	set top [expr {$H / 2 - 10}]
	set cards {}
	set total 0
	foreach u $login::users {
		set w [expr {max(88, [adv g15s [dict get $u full]]) + 44}]
		lappend cards $w
		set total [expr {$total + $w}]
	}
	set total [expr {$total + 28 * ([llength $cards] - 1)}]
	set x [expr {($W - $total) / 2.0}]
	set i 0
	foreach u $login::users w $cards {
		set sel [expr {$i == $login::pick}]
		set cx [expr {$x + $w / 2.0}]
		if {$sel} { put [shape [expr {int(round($w))}] 155 16 $c(BAR) 0.86 $c(ACCENT) 1.5] [expr {round($x)}] $top }
		set pic [face $u 88]
		if {$pic ne ""} {
			put $pic [expr {round($cx - 44)}] [expr {$top + 18}]
		} else {
			if {$sel} {
				put [shape 88 88 44 $c(ACCENT) 1 {} 0 0.35] [expr {round($cx - 44)}] [expr {$top + 18}]
			} else {
				put [shape 88 88 44 $c(PILL) 1] [expr {round($cx - 44)}] [expr {$top + 18}]
			}
			lappend later [list ctext $cx [expr {$top + 75}] gav37 [expr {$sel ? $c(ON_ACCENT) : $c(MUTED)}] [dict get $u letter]]
		}
		lappend later [list ctext $cx [expr {$top + 133}] g15s [expr {$sel ? $c(FG) : $c(MUTED)}] [dict get $u full]]
		hit [expr {round($x)}] $top [expr {round($x + $w)}] [expr {$top + 155}] [list login::pick_user $i]
		set x [expr {$x + $w + 28}]
		incr i
	}
	lappend later [list ctext [expr {$W / 2.0}] [expr {$H - 73}] g13 $c(MUTED) "← → to choose · Enter to continue"]
	finish $later
}
