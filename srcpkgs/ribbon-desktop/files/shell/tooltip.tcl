# tooltip.tcl - the tooltip of an icon-only button, for the shell and every app (boards Tooltip-1-Bar and
# Tooltip-2-Viewer, design/tools/gen_tray.py). The tooltip is the button's name and nothing else. It comes 500 ms
# after the pointer stops over the button, goes when the pointer leaves it or presses, and does not come back for
# that button until the pointer has left it; moving straight on to another button shows that one's name at once.
# A pill: 26 tall, padding 0 9, radius 8, the bar's colour with a 1 px border ring and the menu shadow, 12 px 500
# text; centred on the button, 6 px clear of the bar or toolbar it is in (under it, or over it when it is at the
# foot of a window or there is no room below). Needs text.tcl, raster.tcl and rbnalpha (the shell's, which the apps
# load too); colours come from theme::c (the shell) or ui::c (the apps).
#
#   tip::attach W RESOLVER    W (a canvas whose buttons are drawn into it) gets tooltips: on pointer motion
#                             RESOLVER is called with x y (W's coordinates) and returns "" (no button there) or
#                             {KEY NAME CX TOP BOTTOM ?SIDE?}: the button (KEY, any word that tells it from the
#                             others), its name, its centre's x, and the top and bottom of what it sits in (the
#                             bar, the toolbar), in W's coordinates. SIDE: below (the default) or above.
#   tip::widget W NAME ?SIDE? a whole widget is one button
#   tip::hide                 take it down now (a panel opens, the window goes)
#
# W's own bindings are left as they are: the tooltip's are on a bind tag of its own, put first.

namespace eval tip {
	variable delay 500       ;# ms the pointer rests before the name comes
	variable chain 400       ;# ms after one went in which the next comes at once
	variable resolvers       ;# W -> RESOLVER
	array set resolvers {}
	variable cur ""          ;# {W KEY} under the pointer
	variable shown ""        ;# {W KEY} whose name is up
	variable pressed ""      ;# {W KEY} pressed: no name until the pointer leaves it
	variable timer ""
	variable last 0          ;# when a name last went down (ms)
	variable win .ribbontip
}

proc tip::attach {w resolver} {
	variable resolvers
	set resolvers($w) $resolver
	if {"RibbonTip" ni [bindtags $w]} { bindtags $w [linsert [bindtags $w] 0 RibbonTip] }
}

proc tip::widget {w name {side below}} {
	attach $w [list tip::whole $w $name $side]
}
proc tip::whole {w name side x y} {
	list whole $name [expr {[winfo width $w] / 2.0}] 0 [winfo height $w] $side
}

bind RibbonTip <Motion> {tip::motion %W %x %y}
bind RibbonTip <Leave> {tip::motion %W -100000 -100000}
bind RibbonTip <ButtonPress> {tip::press %W %x %y}
bind RibbonTip <Destroy> {tip::forget %W}

proc tip::forget {w} {
	variable resolvers
	variable cur
	unset -nocomplain resolvers($w)
	if {[lindex $cur 0] eq $w} { set cur ""; hide }
}

proc tip::resolve {w x y} {
	variable resolvers
	if {![info exists resolvers($w)] || $x < -10000} { return "" }
	if {[catch {uplevel #0 [list {*}$resolvers($w) $x $y]} r]} { return "" }
	return $r
}

proc tip::motion {w x y} {
	variable cur
	variable shown
	variable pressed
	variable timer
	variable delay
	variable chain
	variable last
	set r [resolve $w $x $y]
	set key [expr {$r eq "" ? "" : [list $w [lindex $r 0]]}]
	if {$key ne $pressed} { set pressed "" }
	if {$key eq $cur} return
	set cur $key
	after cancel $timer
	if {$shown ne ""} { hide }
	if {$key eq "" || [lindex $r 1] eq ""} return
	set wait [expr {[clock milliseconds] - $last < $chain ? 0 : $delay}]
	set timer [after $wait [list tip::show $w $r]]
}

proc tip::press {w x y} {
	variable cur
	variable pressed
	variable timer
	after cancel $timer
	set pressed $cur
	hide
}

proc tip::hide {} {
	variable shown
	variable win
	variable timer
	variable last
	after cancel $timer
	if {$shown ne ""} { set last [clock milliseconds] }
	set shown ""
	if {[winfo exists $win]} { rbn::hide $win }
}

# Colours: the shell's palette (theme::c), or the app's (ui::c).
proc tip::colours {} {
	if {[array exists ::theme::c] && [info exists ::theme::c(BAR)]} {
		return [list $::theme::c(BAR) $::theme::c(BORDER) $::theme::c(FG) \
			[expr {[info exists ::theme::c(MENU_SHADOW)] ? $::theme::c(MENU_SHADOW) : {18 40 0.45 #000000}}]]
	}
	list $::ui::c(bar) $::ui::c(border) $::ui::c(fg) {18 40 0.45 #000000}
}

proc tip::show {w r} {
	variable cur
	variable shown
	variable pressed
	variable win
	lassign $r key name cx top bottom side
	if {![winfo exists $w] || ![winfo viewable $w] || [list $w $key] ne $cur || $cur eq $pressed} return
	if {$side eq ""} { set side below }
	lassign [colours] bg ring fg shadow
	set f [text::fontof {Ribbon Inter 500} 12]
	set tw [expr {round(9 + [text::width $f $name] + 9)}]
	set th 26
	set rx [winfo rootx $w]; set ry [winfo rooty $w]
	# the screen W is on: the X screen (several outputs side by side are one screen; the pill stays on it)
	set sw [winfo screenwidth $w]; set sh [winfo screenheight $w]
	set X [expr {round($rx + $cx - $tw / 2.0)}]
	set X [expr {max(8, min($sw - 8 - $tw, $X))}]
	set below [expr {round($ry + $bottom + 6)}]
	set above [expr {round($ry + $top - 6 - $th)}]
	if {$side eq "below"} { set Y [expr {$below + $th > $sh ? $above : $below}] } else { set Y [expr {$above < 0 ? $below : $above}] }
	if {![winfo exists $win]} { rbn::surface $win -class RibbonTooltip -fill $bg }
	set c $win.c
	$c delete all
	$c configure -background $bg
	text::draw $c 9 13 $f $fg $name w
	rbn::popup $win $X $Y $tw $th [list -fill $bg -radius 8 -ring [list $ring 1] -shadow $shadow]
	set shown [list $w $key]
}
