# strip.tcl - the terminal's tab strip, Pills A (docs/TERMINAL.md §7; boards Term-G-Pills-A-1-Tabs and -2-Many).
#
#   strip::draw CANVAS WIDTH TABS STATE   clears CANVAS and draws the strip WIDTH px wide
#   strip::height                          the strip's height (42)
#
# TABS: a list of dicts with id, num (the Alt+number shown), name, active (0/1), activity (0/1; new output), and
# optionally icon (an icon in place of the number: the preferences tab's sliders) and mark (the new-output dot's
# colour, the tab's profile's Tab mark; the accent when absent).
# STATE: a dict with maximized and focused (0/1); neither changes the drawing yet (the board shows neither).
#
# The strip: a 42 px §d2 strip with a 1 px rule at its foot. Numbered pills 28 px tall, 2 px apart, from 8 px in.
# The current pill is raised in the pill colour with its name and a × (muted); other pills have no fill. A pill with
# new output has a 6 px accent dot after its name. + follows the tabs (4 px after them). At the right: preferences,
# a 1 px rule, then minimise, maximise and close, all 30 px squares.
#
# Fold rule: when the tabs don't fit before +, every inactive tab without new output folds to its number (a 28 px
# pill). If that is still too wide, inactive tabs with new output fold too, from the left. The current tab keeps its
# name whatever the width; at a width where even that doesn't fit, its name is clipped. Widths come from the fonts.
#
# Clicks (on the canvas, through the bindings strip::draw sets up) call the term:: callbacks, defined elsewhere:
#   term::activate ID     a click on a pill (any pill, folded or not)
#   term::close ID        a click on the current pill's ×, and a middle click on any pill
#   term::new             + (the board's plus)
#   term::prefs           the preferences icon
#   term::wctl KIND       minimize | maximize | close
#   term::menu ID X Y     a right click on a pill: X Y the screen place under the pill's left end (the tab's menu)
#   term::move_start X Y  a press on empty strip space, X and Y in root coordinates
#   term::move_drag X Y   the pointer moves with the button down after such a press
#   term::move_end X Y    the release after such a press
#   term::wctl maximize   a double-click on empty strip space
#   term::resize_start EDGE X Y  a press on the strip's edge: EDGE t (its top 4 px), l or r (its outer 6 px at either
#                         end), tl or tr (the two top corners); nothing is drawn there, the pointer shows a resize cursor
#   term::resize_drag X Y, term::resize_end X Y  the drag and the release after such a press
#
# Drawing uses the shell's rasteriser and text (shell/raster.tcl, shell/text.tcl) and the palette tokens of
# shell/theme.tcl. Tk font sizes are whole pixels, so the board's 12.5 px tab names are drawn at 13 px.

namespace eval strip {
	variable dir [file dirname [file normalize [info script]]]   ;# this file's directory, read at source time
	variable H 42                       ;# the strip's height
	variable PAD 8                      ;# the strip's side padding
	variable GAP 2                      ;# between pills, + and the controls
	variable PILL_Y 7                   ;# a pill is 28 px tall, at y 7
	variable PILL_H 28
	variable FOLD_W 28                  ;# a folded pill is 28 px wide
	variable XBTN 18                    ;# the × box on the current pill
	variable LIM 189                    ;# the tabs end by WIDTH - LIM: + (4 + 28), the gap and the controls (145) take the rest
	variable CTL_W 145                  ;# preferences, rule and the window controls, at the strip's right
	variable img                        ;# canvas -> the photo the boxes are drawn into
	array set img {}
	variable hits {}                    ;# {x0 y0 x1 y1 kind id}, strip coordinates; the last one that holds the point wins
	variable drawn {}                   ;# {text x} of each name and number drawn last time (the tests read it)
	variable moving 0                   ;# a press on empty space is being dragged
	variable resizing 0                 ;# a press on an edge is being dragged
	variable EDGE 6                     ;# the strip's ends this wide take a resize (inside the 8 px padding)
	variable TOP 4                      ;# its top this tall (above the pills and controls)
	variable cursors                    ;# the X cursor over each edge
	array set cursors {l left_side r right_side t top_side tl top_left_corner tr top_right_corner}
	variable c                          ;# the palette tokens, in the names the strip uses
	array set c {}
	variable font                       ;# name of each text font; asc, desc in em as the browser rounds them
	array set font {
		on  {strip_on  {Ribbon Inter 600} 13 0.96875 0.2412}
		off {strip_off {Ribbon Inter 500} 13 0.96875 0.2412}
		num {strip_num {Ribbon Mono Bold} 11 0.928 0.236}
	}
	variable icons                      ;# 24-grid paths, stroke width, size px (the board's)
	array set icons {
		x        {{M18 6L6 18 M6 6l12 12} 2.2 12}
		plus     {{M12 5v14 M5 12h14} 1.9 15}
		sliders  {{M21 4h-7 M10 4H3 M21 12h-9 M8 12H3 M21 20h-5 M12 20H3 M14 2v4 M8 10v4 M16 18v4} 1.9 15}
		tabprefs {{M21 4h-7 M10 4H3 M21 12h-9 M8 12H3 M21 20h-5 M12 20H3 M14 2v4 M8 10v4 M16 18v4} 2 14}
		minimize {{M5 12h14} 2 15}
		maximize {{M5 5h14v14H5z} 2.1 13}
		close    {{M18 6L6 18 M6 6l12 12} 2 15}
	}
}

# The shell's text and raster, and the palette, if the caller has not sourced them (the editor does).
proc strip::libraries {} {
	if {[llength [info commands ::text::font]] && [llength [info commands ::raster::box]] && [info exists ::theme::c(PILL)]} {
		return
	}
	variable dir
	foreach d [list [file join $dir .. .. shell] /usr/lib/ribbon/shell] {
		if {[file isfile [file join $d text.tcl]]} {
			foreach f {text raster theme} { uplevel #0 [list source -encoding utf-8 [file join $d $f.tcl]] }
			break
		}
	}
	if {![info exists ::theme::c(PILL)]} { ::theme::load }
	# the rasteriser caches its pictures on disk: a directory when the caller has not set one
	if {$::raster::cachedir eq ""} {
		set cache [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : [file join $::env(HOME) .cache]}]
		raster::init [file join $cache ribbon shell]
	}
}

proc strip::height {} {
	variable H
	return $H
}

# The palette's tokens (theme.tcl's keys), read each draw so a theme change shows at the next one.
proc strip::colours {} {
	variable c
	if {![info exists ::theme::c(PILL)]} { ::theme::load }
	foreach {k v} {bar BAR field FIELD pill PILL border BORDER fg FG muted MUTED accent ACCENT d2 DESK_BOTTOM} {
		set c($k) $::theme::c($v)
	}
	# the active pill's shadow (0 1px 2px) is the palette's shadow colour (BAR_SHADOW) at its alpha over the strip
	lassign [raster::rgb $c(d2)] r g b
	lassign [raster::rgb [lindex $::theme::c(BAR_SHADOW) 3]] sr sg sb
	set a [lindex $::theme::c(BAR_SHADOW) 2]
	set c(shadow) [format #%02X%02X%02X [expr {round($r + ($sr - $r) * $a)}] [expr {round($g + ($sg - $g) * $a)}] [expr {round($b + ($sb - $b) * $a)}]]
}

proc strip::fonts {} {
	variable font
	foreach k {on off num} {
		lassign $font($k) name family px asc desc
		text::font $name $family $px
	}
}

# Width of the number at a pill's start (or of the icon that stands for it).
proc strip::num_width {row} {
	variable font
	if {[dict get $row icon] ne ""} { return 14 }
	text::width [lindex $font(num) 0] [dict get $row num]
}
# The number (or the icon) at X, its line centred on CY.
proc strip::num_draw {cv row x cy colour} {
	if {[dict get $row icon] ne ""} { icon $cv [dict get $row icon] [expr {$x + 7}] $cy $colour; return }
	label $cv $x $cy num [dict get $row num] $colour
}

# Width of a tab's pill, as drawn. Padding: 11 left, 5 right with ×, 12 right without; 7 between the parts.
proc strip::row_width {row} {
	variable FOLD_W; variable font; variable XBTN
	if {[dict get $row fold]} { return $FOLD_W }
	set nw [num_width $row]
	set key [expr {[dict get $row on] ? "on" : "off"}]
	set tw [text::width [lindex $font($key) 0] [dict get $row name]]
	# whole pixels, rounded up, as the editor's tabs measure theirs
	if {[dict get $row on]} { return [expr {int(ceil(16 + $nw + 7 + $tw + 7 + $XBTN))}] }
	if {[dict get $row new]} { return [expr {int(ceil(23 + $nw + 7 + $tw + 7 + 6))}] }
	return [expr {int(ceil(23 + $nw + 7 + $tw))}]
}

# Where the tabs end (after the last pill), for ROWS.
proc strip::end_of {rows} {
	variable PAD; variable GAP
	set x $PAD
	foreach r $rows {
		if {$x != $PAD} { incr x $GAP }
		incr x [row_width $r]
	}
	return $x
}

# ROWS with the fold rule applied, for a strip WIDTH px wide: each row gets fold 0/1.
proc strip::fold {rows width} {
	variable LIM
	set lim [expr {$width - $LIM}]
	foreach r $rows { dict set r fold 0 }
	if {[end_of $rows] <= $lim} { return $rows }
	# 1: every inactive tab without new output folds
	for {set i 0} {$i < [llength $rows]} {incr i} {
		set r [lindex $rows $i]
		if {![dict get $r on] && ![dict get $r new]} { dict set r fold 1; lset rows $i $r }
	}
	if {[end_of $rows] <= $lim} { return $rows }
	# 2: inactive tabs with new output fold too, from the left
	for {set i 0} {$i < [llength $rows]} {incr i} {
		set r [lindex $rows $i]
		if {![dict get $r on]} { dict set r fold 1; lset rows $i $r }
		if {[end_of $rows] <= $lim} { return $rows }
	}
	return $rows
}

# A rectangle hit, last one wins.
proc strip::hit_add {x0 y0 w h kind id} {
	variable hits
	lappend hits [list $x0 $y0 [expr {$x0 + $w}] [expr {$y0 + $h}] $kind $id]
}

# {kind id} at a point of the strip, or {} when none.
proc strip::hit {x y} {
	variable hits
	for {set i [expr {[llength $hits] - 1}]} {$i >= 0} {incr i -1} {
		lassign [lindex $hits $i] x0 y0 x1 y1 kind id
		if {$x >= $x0 && $x < $x1 && $y >= $y0 && $y < $y1} { return [list $kind $id] }
	}
	return {}
}

# A rounded box (or a square) in the photo of CV.
proc strip::box {cv x y w h colour radius} {
	variable img
	raster::box $img($cv) $x $y $w $h -fill $colour -radius $radius
}

# A line icon centred at (CX, CY) for the icon named NAME, in COLOUR.
proc strip::icon {cv name cx cy colour} {
	variable icons
	lassign $icons($name) d sw size
	set i [raster::icon $d $size $sw $colour]
	$cv create image [expr {$cx - $size / 2}] [expr {$cy - $size / 2}] -image $i -anchor nw -tags strip
}

# Text with its line box centred on the pill's middle (y 21): the browser's line box, at the font's ascent.
proc strip::label {cv x cy key str colour} {
	variable font
	lassign $font($key) name family px asc desc
	set top [expr {$cy - (round($asc * $px) + round($desc * $px)) / 2.0}]
	set base [expr {floor($top + round($asc * $px) + 0.5)}]
	set y [expr {$base - [font metrics $name -ascent]}]
	variable drawn
	lappend drawn [list $str $x]
	::text::draw $cv $x $y $name $colour $str nw -tnum 1 -tags strip
}

proc strip::draw {cv width tabs state} {
	variable H; variable PAD; variable GAP; variable PILL_Y; variable PILL_H; variable FOLD_W; variable XBTN
	variable CTL_W; variable LIM; variable img; variable hits; variable c; variable font
	libraries
	colours
	fonts
	set width [expr {int($width)}]
	set hits {}
	set drawn {}
	$cv delete all
	$cv configure -width $width -height $H
	# the photo the boxes go into: §d2 with the rule at its foot
	if {![info exists img($cv)] || [catch {image width $img($cv)}]} {
		set img($cv) [image create photo]
	}
	$img($cv) configure -width $width -height $H
	$img($cv) put $c(d2) -to 0 0 $width $H
	$img($cv) put $c(border) -to 0 [expr {$H - 1}] $width $H
	$cv create image 0 0 -image $img($cv) -anchor nw -tags strip
	bind $cv <ButtonPress-1> [list ::strip::press %x %y %X %Y]
	bind $cv <Double-ButtonPress-1> [list ::strip::double %x %y %X %Y]
	bind $cv <ButtonPress-2> [list ::strip::middle %x %y]
	bind $cv <ButtonPress-3> [list ::strip::right $cv %x %y]
	bind $cv <B1-Motion> [list ::strip::motion %X %Y]
	bind $cv <ButtonRelease-1> [list ::strip::release %X %Y]
	bind $cv <Motion> [list ::strip::hover $cv %x %y]
	bind $cv <Leave> [list ::strip::hover $cv -1 -1]

	hit_add 0 0 $width $H empty {}
	# the edges (no pill or control reaches them): top, ends, then the corners, which win
	variable EDGE; variable TOP
	hit_add 0 0 $width $TOP resize t
	hit_add 0 0 $EDGE $H resize l
	hit_add [expr {$width - $EDGE}] 0 $EDGE $H resize r
	hit_add 0 0 $EDGE $TOP resize tl
	hit_add [expr {$width - $EDGE}] 0 $EDGE $TOP resize tr

	# the rows: the tabs as the dicts give them, with the fold for this width
	set rows {}
	foreach t $tabs {
		lappend rows [dict create id [dict get $t id] num [dict get $t num] name [dict get $t name] \
			on [expr {[dict get $t active] ? 1 : 0}] new [expr {[dict get $t activity] ? 1 : 0}] fold 0 \
			icon [expr {[dict exists $t icon] ? [dict get $t icon] : ""}] mark [expr {[dict exists $t mark] ? [dict get $t mark] : ""}]]
	}
	set rows [fold $rows $width]
	# a current name that still doesn't fit is clipped
	set over [expr {[end_of $rows] - ($width - $LIM)}]
	for {set i 0} {$over > 0 && $i < [llength $rows]} {incr i} {
		set r [lindex $rows $i]
		if {![dict get $r on]} continue
		set tw [text::width [lindex $font(on) 0] [dict get $r name]]
		dict set r name [text::clip [lindex $font(on) 0] [dict get $r name] [expr {max(0, $tw - $over)}]]
		lset rows $i $r
		break
	}

	set x $PAD
	foreach r $rows {
		if {$x != $PAD} { incr x $GAP }
		set id [dict get $r id]
		set w [row_width $r]
		set cy [expr {$PILL_Y + $PILL_H / 2}]
		if {[dict get $r fold]} {
			set nw [num_width $r]
			num_draw $cv $r [expr {$x + ($FOLD_W - $nw) / 2}] $cy $c(muted)
			hit_add $x $PILL_Y $FOLD_W $PILL_H activate $id
		} elseif {[dict get $r on]} {
			box $cv $x [expr {$PILL_Y + 1}] $w $PILL_H $c(shadow) 14
			box $cv $x $PILL_Y $w $PILL_H $c(pill) 14
			set nw [num_width $r]
			num_draw $cv $r [expr {$x + 11}] $cy $c(fg)
			label $cv [expr {$x + 11 + $nw + 7}] $cy on [dict get $r name] $c(fg)
			set bx [expr {$x + $w - 5 - $XBTN}]
			icon $cv x [expr {$bx + $XBTN / 2}] $cy $c(muted)
			hit_add $x $PILL_Y $w $PILL_H activate $id
			hit_add $bx [expr {$PILL_Y + 5}] $XBTN $XBTN close $id
		} else {
			set nw [num_width $r]
			num_draw $cv $r [expr {$x + 11}] $cy $c(muted)
			label $cv [expr {$x + 11 + $nw + 7}] $cy off [dict get $r name] $c(muted)
			if {[dict get $r new]} {
				box $cv [expr {$x + $w - 18}] [expr {$cy - 3}] 6 6 [expr {[dict get $r mark] ne "" ? [dict get $r mark] : $c(accent)}] 3
			}
			hit_add $x $PILL_Y $w $PILL_H activate $id
		}
		incr x $w
	}

	# +: after the tabs, 4 px further on (the gap comes first)
	set px [expr {$x + 4 + $GAP}]
	if {[llength $rows] == 0} { set px [expr {$PAD + 4}] }
	icon $cv plus [expr {$px + 14}] [expr {$PILL_Y + 14}] $c(muted)
	hit_add $px $PILL_Y 28 28 new {}

	# the right end: preferences, a 1 px rule, the window controls
	set cx [expr {$width - $PAD - $CTL_W}]
	icon $cv sliders [expr {$cx + 15}] 21 $c(muted)
	hit_add $cx 6 30 30 prefs {}
	$img($cv) put $c(border) -to [expr {$cx + 40}] 12 [expr {$cx + 41}] 30
	foreach {k off} {minimize 51 maximize 83 close 115} {
		set bx [expr {$cx + $off}]
		icon $cv $k [expr {$bx + 15}] 21 $c(muted)
		hit_add $bx 6 30 30 wctl $k
	}
}

# A press: what it hit. The empty strip moves the window (move_start, then drag and release).
proc strip::press {x y X Y} {
	variable moving
	lassign [hit $x $y] kind id
	switch -- $kind {
		activate { ::term::activate $id }
		close    { ::term::close $id }
		new      { ::term::new }
		prefs    { ::term::prefs }
		wctl     { ::term::wctl $id }
		empty    { set moving 1; ::term::move_start $X $Y }
		resize   { variable resizing 1; ::term::resize_start $id $X $Y }
	}
}

# The pointer over the strip: a resize cursor on an edge, the plain one elsewhere (kept while a resize drags).
proc strip::hover {cv x y} {
	variable cursors
	variable resizing
	if {$resizing} return
	lassign [hit $x $y] kind id
	set want [expr {$kind eq "resize" ? $cursors($id) : ""}]
	if {[$cv cget -cursor] ne $want} { $cv configure -cursor $want }
}

# A double-click on empty strip space maximises. On a pill the first click has already done its work.
proc strip::double {x y X Y} {
	variable moving
	lassign [hit $x $y] kind id
	if {$kind eq "empty"} {
		set moving 0
		::term::wctl maximize
	}
}

# A middle click on any pill closes it.
# A right click on a pill: the tab's menu, 4 px under the strip, from the pill's left end.
proc strip::right {cv x y} {
	variable hits
	variable H
	lassign [hit $x $y] kind id
	if {$kind ni {activate close}} return
	set px $x
	foreach h $hits { lassign $h x0 y0 x1 y1 k i; if {$k eq "activate" && $i eq $id} { set px $x0 } }
	::term::menu $id [expr {[winfo rootx $cv] + $px}] [expr {[winfo rooty $cv] + $H + 4}]
}
# The rectangle {x y w h} of tab ID's pill as last drawn, or {}.
proc strip::pill {id} {
	variable hits
	foreach h $hits { lassign $h x0 y0 x1 y1 k i; if {$k eq "activate" && $i eq $id} { return [list $x0 $y0 [expr {$x1 - $x0}] [expr {$y1 - $y0}]] } }
	return {}
}
proc strip::middle {x y} {
	lassign [hit $x $y] kind id
	if {$kind eq "activate" || $kind eq "close"} { ::term::close $id }
}

proc strip::motion {X Y} {
	variable moving
	variable resizing
	if {$moving} { ::term::move_drag $X $Y }
	if {$resizing} { ::term::resize_drag $X $Y }
}

proc strip::release {X Y} {
	variable moving
	variable resizing
	if {$moving} {
		set moving 0
		::term::move_end $X $Y
	}
	if {$resizing} {
		set resizing 0
		::term::resize_end $X $Y
	}
}
