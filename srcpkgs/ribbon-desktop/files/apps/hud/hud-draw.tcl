# hud-draw.tcl - the Game HUD's geometry and drawing, as drawn on the HUD-* boards (design/tools/gen_hud.py).
#
# ops lays the HUD out as a flat list of drawing ops in pixels; paint draws them on a Tk canvas. The layout is
# first worked out in CSS pixels of the 100 % HUD (panel 236 wide, padding 14 16 8, a 24 px margin from the
# screen edges), then scaled (90, 100, 125 or 150 %) about the anchored corner. Op forms (pixels):
#   {rrect x y w h radius fill ring shadow ?alpha?}  rounded box; ring {colour width} or ""; shadow {dy blur alpha colour} or "";
#                                            alpha 0..1 is the fill's opacity (default 1; only the native surface uses it)
#   {rect x y w h colour}
#   {text x y anchor family px colour string} family is a Tk family such as "Ribbon Inter 600"
#   {line x1 y1 x2 y2 width colour dash}     dash "" for solid
#   {poly flatpoints colour}                 filled, no outline
#   {pline flatpoints width colour}          open polyline, round joins
#   {hit name x y w h}                       a button's box (pin, close); drawn by nothing, used for the input region
#   {image x y w h path}                     a PNG drawn at x y (it is w x h px: the game's art, rounded and ringed)
# Before the scale the art is {image x y w h radius source ring}: ops asks the image command (image_cmd, given
# source px radius ring; hud.tcl sets hud::art::png) for the PNG, and draws the pill in its place while there is none.
# The glass is the bar colour at the opacity, blended once over the backdrop colour (the canvas, which has no alpha).
# With view key native 1 the glass is the bar colour and the rrect carries the opacity as its alpha: the layer
# surface (hud-surface.tcl, ribbon-hud-surface) draws it see-through.

namespace eval ::hud::draw {
	variable c
	array set c {BAR #1D1C1B FIELD #2A2826 PILL #36302C BORDER #3B3835 FG #EEE9E3 MUTED #A49D95}
	variable cachedir ""
	variable image_cmd ""   ;# source px radius ring -> a PNG path or "" (hud::art::png)
	variable photos {}      ;# PNG path -> Tk photo
	variable fontcache {}
	variable PANEL_W 236    ;# panel width, CSS px
	variable MARGIN 24      ;# distance from the screen edges
	variable MENU_RIGHT 358 ;# right edge of a right-hand HUD while the quick menu is open (HUD-Toggle)
	variable SG "Ribbon Space Grotesk 600"
	variable INTER "Ribbon Inter 600"
	variable REG "Ribbon Inter 400"
	# icons on a 24-unit grid: the pin head (closed), its stem, and the X as two strokes
	variable pin_head {9 3 15 3 14 9 17 12 17 14 7 14 7 12 10 9 9 3}
	variable pin_stem {12 17 12 22}
	variable x_strokes {{18 6 6 18} {6 6 18 18}}
}

# "#rrggbb" -> {r g b}
proc ::hud::draw::rgb {hex} {
	scan [string range $hex 1 end] %2x%2x%2x r g b
	list $r $g $b
}

proc ::hud::draw::hexof {r g b} {
	format #%02x%02x%02x {*}[lmap v [list $r $g $b] {expr {max(0, min(255, round($v)))}}]
}

# weight t of a over b
proc ::hud::draw::mix {a b t} {
	lassign [rgb $a] ar ag ab
	lassign [rgb $b] br bg bb
	hexof [expr {$ar * $t + $br * (1 - $t)}] [expr {$ag * $t + $bg * (1 - $t)}] [expr {$ab * $t + $bb * (1 - $t)}]
}

# the palette the HUD is drawn in: a dict that may hold BAR FIELD PILL BORDER FG MUTED
proc ::hud::draw::set_palette {p} {
	variable c
	foreach k {BAR FIELD PILL BORDER FG MUTED} {
		if {[dict exists $p $k]} { set c($k) [dict get $p $k] }
	}
}

# the directory for the shell's rasterised shapes (raster::init), created if missing
proc ::hud::draw::init {dir} {
	variable cachedir
	file mkdir $dir
	set cachedir $dir
	::raster::init $dir
}

# a named Tk font for FAMILY at PX pixels, created on first use
proc ::hud::draw::font_name {family px} {
	variable fontcache
	set key "$family|$px"
	if {[dict exists $fontcache $key]} { return [dict get $fontcache $key] }
	set name hud_[string map {" " _} $family]_$px
	if {[lsearch -exact [font names] $name] < 0} {
		font create $name -family $family -size -$px
	}
	dict set fontcache $key $name
	return $name
}

# width in pixels of TEXT in FAMILY at PX (Tk measures it)
proc ::hud::draw::measure {family px text} {
	font measure [font_name $family $px] $text
}

# a 24-unit icon grid list {x y x y ...} at a centre CX,CY, drawn SZ px wide
proc ::hud::draw::icon_pts {grid cx cy sz} {
	set k [expr {$sz / 24.0}]
	set out {}
	foreach {x y} $grid { lappend out [expr {$cx - 12 * $k + $x * $k}] [expr {$cy - 12 * $k + $y * $k}] }
	return $out
}

# Move rel ops to pixels: origin ox,oy and scale s. Coordinates and sizes scale; rules stay at least 1 px.
proc ::hud::draw::xform {ops ox oy s} {
	set out {}
	foreach op $ops {
		switch -- [lindex $op 0] {
			rrect {
				lassign [lrange $op 1 end] x y w h r fill ring shadow alpha
				set ring2 ""
				if {$ring ne ""} { lassign $ring rc rw; set ring2 [list $rc [expr {max(1, round($rw * $s))}]] }
				set sh2 ""
				if {$shadow ne ""} {
					lassign $shadow dy bl sa sc
					set sh2 [list [expr {round($dy * $s)}] [expr {round($bl * $s)}] $sa $sc]
				}
				lappend out [list rrect [expr {round($ox + $x * $s)}] [expr {round($oy + $y * $s)}] \
					[expr {round($w * $s)}] [expr {round($h * $s)}] [expr {$r * $s}] $fill $ring2 $sh2 {*}[expr {$alpha ne "" ? [list $alpha] : {}}]]
			}
			rect {
				lassign [lrange $op 1 end] x y w h col
				lappend out [list rect [expr {$ox + $x * $s}] [expr {$oy + $y * $s}] [expr {$w * $s}] [expr {$h * $s}] $col]
			}
			text {
				lassign [lrange $op 1 end] x y anchor fam px col str
				lappend out [list text [expr {$ox + $x * $s}] [expr {$oy + $y * $s}] $anchor $fam [expr {round($px * $s)}] $col $str]
			}
			line {
				lassign [lrange $op 1 end] x1 y1 x2 y2 w col dash
				lappend out [list line [expr {$ox + $x1 * $s}] [expr {$oy + $y1 * $s}] [expr {$ox + $x2 * $s}] [expr {$oy + $y2 * $s}] \
					[expr {max(1, $w * $s)}] $col $dash]
			}
			poly {
				lassign [lrange $op 1 end] pts col
				set p {}
				foreach {x y} $pts { lappend p [expr {$ox + $x * $s}] [expr {$oy + $y * $s}] }
				lappend out [list poly $p $col]
			}
			pline {
				lassign [lrange $op 1 end] pts w col
				set p {}
				foreach {x y} $pts { lappend p [expr {$ox + $x * $s}] [expr {$oy + $y * $s}] }
				lappend out [list pline $p [expr {max(1, $w * $s)}] $col]
			}
			image {
				lassign [lrange $op 1 end] x y w h r src ring
				lappend out [list image [expr {round($ox + $x * $s)}] [expr {round($oy + $y * $s)}] \
					[expr {round($w * $s)}] [expr {round($h * $s)}] [expr {$r * $s}] $src [expr {max(1, round($ring * $s))}]]
			}
			hit {
				lassign [lrange $op 1 end] name x y w h
				lappend out [list hit $name [expr {round($ox + $x * $s)}] [expr {round($oy + $y * $s)}] [expr {round($w * $s)}] [expr {round($h * $s)}]]
			}
		}
	}
	return $out
}

# The Full or Compact panel in CSS pixels, rel to its top-left corner. contents: the shown keys; rows: the metric
# rows from hud::data::rows; glass: the panel colour (used for the graph fill). Returns {ops height}.
proc ::hud::draw::panel {layout contents name pinned frames rows glass {art ""}} {
	variable c
	variable SG
	variable INTER
	variable REG
	variable pin_head
	variable pin_stem
	variable x_strokes
	set ok [dict get $frames ok]
	set ops {}
	set fy 14
	if {$layout eq "full"} {
		# header: a 20 px art, the name, the pin and close buttons (24 px); 12 px under it, a rule, 12 px to the FPS block.
		# The art is the game's picture with the board's 1 px inset ring; the pill stands in for a game with none
		if {$art ne ""} {
			lappend ops [list image 16 16 20 20 5 $art 1]
		} else {
			lappend ops [list rrect 16 16 20 20 5 $c(PILL) "" ""]
		}
		if {[lsearch -exact $contents game] >= 0 && $name ne ""} {
			lappend ops [list text 44 26 w $INTER 12 $c(FG) $name]
		}
		if {$pinned} { lappend ops [list rrect 170 14 24 24 8 $c(FIELD) "" ""] }
		set pc [expr {$pinned ? $c(FG) : $c(MUTED)}]
		lappend ops [list pline [icon_pts $pin_head 182 26 13] 1.05 $pc]
		set stem [icon_pts $pin_stem 182 26 13]
		lappend ops [list line [lindex $stem 0] [lindex $stem 1] [lindex $stem 2] [lindex $stem 3] 1.05 $pc ""]
		foreach s $x_strokes {
			set p [icon_pts $s 208 26 13]
			lappend ops [list line [lindex $p 0] [lindex $p 1] [lindex $p 2] [lindex $p 3] 1.05 $c(MUTED) ""]
		}
		lappend ops [list line 16 49.5 220 49.5 1 $c(BORDER) ""]
		lappend ops [list hit pin 170 14 24 24] [list hit close 196 14 24 24]
		set fy 62
	}
	# FPS block: the number, its label, the right column (frame time, 1 % low), then the graph
	set numtxt [expr {$ok ? [dict get $frames fps] : "–"}]
	set numcol [expr {$ok ? $c(FG) : $c(MUTED)}]
	set numw [measure $SG 36 $numtxt]
	lappend ops [list text 16 [expr {$fy + 15}] w $SG 36 $numcol $numtxt]
	lappend ops [list text [expr {16 + $numw + 8}] [expr {$fy + 21}] w $INTER 12 $c(MUTED) "FPS"]
	set ft_on [expr {[lsearch -exact $contents frametime] >= 0}]
	set low_on [expr {[lsearch -exact $contents low] >= 0}]
	if {$ok} {
		if {$ft_on} { lappend ops [list text 220 [expr {$fy + 7}] e $INTER 12 $c(FG) "[dict get $frames ft] ms"] }
		if {$low_on} { lappend ops [list text 220 [expr {$fy + 24}] e $REG 12 $c(MUTED) "1% low [dict get $frames low]"] }
	} else {
		if {$ft_on} { lappend ops [list text 220 [expr {$fy + 7}] e $INTER 12 $c(MUTED) "– ms"] }
		if {$ft_on || $low_on} { lappend ops [list text 220 [expr {$fy + 24}] e $REG 12 $c(MUTED) "No frame data"] }
	}
	set fpsh 31
	if {[lsearch -exact $contents graph] >= 0} {
		set gy [expr {$fy + 41}]
		if {$ok} {
			set line {}
			set i 0
			foreach v [dict get $frames series] {
				lappend line [expr {16 + $i * 204 / 59.0}] [expr {$gy + 34 - $v * 0.34}]
				incr i
			}
			set area [list 16 [expr {$gy + 34}]]
			lappend area {*}$line 220 [expr {$gy + 34}]
			lappend ops [list poly $area [mix $c(FG) $glass 0.08]]
			lappend ops [list pline $line 1.3 $c(FG)]
		} else {
			lappend ops [list line 16 [expr {$gy + 33.5}] 220 [expr {$gy + 33.5}] 1 $c(BORDER) "3 3"]
		}
		set fpsh [expr {31 + 10 + 34 + 4}]
	}
	set ry [expr {$fy + $fpsh}]
	if {$layout eq "full"} {
		set shown {}
		foreach r $rows {
			if {[lsearch -exact $contents [lindex $r 0]] >= 0} { lappend shown $r }
		}
		set last [expr {[llength $shown] - 1}]
		set k 0
		foreach r $shown {
			lassign $r key label value meter
			# the rows with a meter are 42 px, the others 33, whatever their readings (a dash keeps the height);
			# the rule is the row's last pixel, and there is none under the last row
			set metered [expr {$key in {gpu vram cpu mem}}]
			set h [expr {$metered ? 42 : 33}]
			lappend ops [list text 16 [expr {$ry + 16.5}] w $REG 12 $c(MUTED) $label]
			lappend ops [list text 220 [expr {$ry + 16.5}] e $INTER 12 $c(FG) $value]
			if {$metered} {
				lappend ops [list rect 16 [expr {$ry + 30}] 204 3 $c(PILL)]
				if {$meter ne ""} {
					set pct [expr {max(0, min(100, $meter))}]
					lappend ops [list rect 16 [expr {$ry + 30}] [expr {204 * $pct / 100.0}] 3 $c(FG)]
				}
			}
			if {$k != $last} { lappend ops [list rect 16 [expr {$ry + $h - 1}] 204 1 $c(BORDER)] }
			set ry [expr {$ry + $h}]
			incr k
		}
		set height [expr {$ry + 8}]
	} else {
		set height [expr {$fy + $fpsh + 8}]
	}
	return [list $ops $height]
}

# The whole HUD in pixels. view: dict with W and H (the screen), layout (off fps compact full), pos (top-left
# top-right bottom-left bottom-right), scale (90 100 125 150), opacity (0..100), contents, name, pinned (0/1),
# menu (0/1, the quick menu is open), backdrop (hex), frames (hud::frames::numbers), rows (hud::data::rows), and
# optionally art (the game's picture, hud::art::for_key; "" or missing: the pill).
# Returns the ops; empty when the layout is off.
proc ::hud::draw::ops {view} {
	variable c
	variable PANEL_W
	variable MARGIN
	variable MENU_RIGHT
	variable SG
	variable INTER
	set layout [dict get $view layout]
	if {$layout eq "off"} { return {} }
	set s [expr {[dict get $view scale] / 100.0}]
	set native [expr {[dict exists $view native] && [dict get $view native]}]
	set galpha [expr {$native ? [list [expr {[dict get $view opacity] / 100.0}]] : {}}]
	set glass [expr {$native ? $c(BAR) : [mix $c(BAR) [dict get $view backdrop] [expr {[dict get $view opacity] / 100.0}]]}]
	set frames [dict get $view frames]
	set shadow {12 20 0.5 #000000}
	if {$layout eq "fps"} {
		set ok [dict get $frames ok]
		set numtxt [expr {$ok ? [dict get $frames fps] : "–"}]
		set numcol [expr {$ok ? $c(FG) : $c(MUTED)}]
		set nw [measure $SG 24 $numtxt]
		set pw [expr {14 + $nw + 7 + [measure $INTER 12 "FPS"] + 14}]
		set ph 40
		set rel [list [list rrect 0 0 $pw $ph 12 $glass [list $c(BORDER) 1] $shadow {*}$galpha] \
			[list text 14 20 w $SG 24 $numcol $numtxt] \
			[list text [expr {14 + $nw + 7}] 20 w $INTER 12 $c(MUTED) "FPS"]]
	} else {
		lassign [panel $layout [dict get $view contents] [dict get $view name] [dict get $view pinned] \
			$frames [dict get $view rows] $glass [expr {[dict exists $view art] ? [dict get $view art] : ""}]] body ph
		set pw $PANEL_W
		set rel [concat [list [list rrect 0 0 $pw $ph 14 $glass [list $c(BORDER) 1] $shadow {*}$galpha]] $body]
	}
	# the anchored corner stays at the margin; with the quick menu open a right-hand HUD moves to 358 px from the edge
	set pos [dict get $view pos]
	set vpos [lindex [split $pos -] 0]
	set hpos [lindex [split $pos -] 1]
	if {$hpos eq "right"} {
		set right [expr {[dict get $view menu] ? $MENU_RIGHT : $MARGIN}]
		set ox [expr {[dict get $view W] - $right - $pw * $s}]
	} else {
		set ox $MARGIN
	}
	if {$vpos eq "top"} { set oy $MARGIN } else { set oy [expr {[dict get $view H] - $MARGIN - $ph * $s}] }
	return [images [xform $rel $ox $oy $s]]
}

# the art ops in pixels made drawable: the PNG at their size, or the pill while there is none
proc ::hud::draw::images {ops} {
	variable c
	variable image_cmd
	set out {}
	foreach op $ops {
		if {[lindex $op 0] eq "image" && [llength $op] == 8} {
			lassign [lrange $op 1 end] x y w h r src ring
			set png ""
			if {$image_cmd ne ""} { catch {set png [{*}$image_cmd $src $w $r $ring]} }
			if {$png ne ""} {
				lappend out [list image $x $y $w $h $png]
			} else {
				lappend out [list rrect $x $y $w $h $r $c(PILL) "" ""]
			}
			continue
		}
		lappend out $op
	}
	return $out
}

# Draw ops on CANVAS, tagged hud (the previous drawing is removed). Rounded boxes come from the shell's raster
# (anti-aliased, with shadows) as images; init must have been called.
proc ::hud::draw::paint {canvas ops} {
	$canvas delete hud
	foreach op $ops {
		switch -- [lindex $op 0] {
			rrect {
				lassign [lrange $op 1 end] x y w h r fill ring shadow
				set args [list -radius $r -fill $fill]
				if {$ring ne ""} { lappend args -ring $ring }
				if {$shadow ne ""} { lappend args -shadow $shadow }
				lassign [::raster::rrect $w $h {*}$args] img padx pady
				$canvas create image [expr {$x - $padx}] [expr {$y - $pady}] -image $img -anchor nw -tags hud
			}
			rect {
				lassign [lrange $op 1 end] x y w h col
				$canvas create rectangle $x $y [expr {$x + $w}] [expr {$y + $h}] -fill $col -outline "" -tags hud
			}
			text {
				lassign [lrange $op 1 end] x y anchor fam px col str
				$canvas create text $x $y -text $str -anchor $anchor -font [font_name $fam $px] -fill $col -tags hud
			}
			line {
				lassign [lrange $op 1 end] x1 y1 x2 y2 w col dash
				set args [list -width $w -fill $col]
				if {$dash ne ""} { lappend args -dash $dash }
				$canvas create line $x1 $y1 $x2 $y2 {*}$args -tags hud
			}
			poly {
				lassign [lrange $op 1 end] pts col
				$canvas create polygon {*}$pts -fill $col -outline "" -tags hud
			}
			pline {
				lassign [lrange $op 1 end] pts w col
				$canvas create line {*}$pts -width $w -fill $col -capstyle round -joinstyle round -tags hud
			}
			image {
				lassign [lrange $op 1 end] x y w h path
				set img [photo $path]
				if {$img ne ""} { $canvas create image $x $y -image $img -anchor nw -tags hud }
			}
		}
	}
}

# a Tk photo of a PNG, read once ("" when it cannot be read)
proc ::hud::draw::photo {path} {
	variable photos
	if {[dict exists $photos $path]} { return [dict get $photos $path] }
	if {[catch {image create photo -file $path} img]} { set img "" }
	if {[dict size $photos] > 32} {
		dict for {p i} $photos { if {$i ne ""} { catch {image delete $i} } }
		set photos {}
	}
	dict set photos $path $img
	return $img
}
