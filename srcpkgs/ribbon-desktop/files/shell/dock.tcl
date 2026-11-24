# dock.tcl - the open windows, in a bar at the bottom centre of the screen.
#
# Same build as the top bars (38 tall, 8 px from the edge, 12 px radius,
# 30 px buttons): icon and name for every app, windows of the same app
# grouped into one button with a count. The bar grows with what's open and
# stays centred; if it would ever be wider than the screen, the windows
# that don't fit go behind a "+N" button.

namespace eval dock {
	variable hits {}
	variable wmenu ""     ;# what the open menu belongs to: an app's key, or "more"
	variable menuneed 0   ;# the width that menu needs
	variable menux 0      ;# where it stands on the dock: the button's width
	variable menuw 0
	variable overflow {}  ;# groups that didn't fit
}

# Like the top bars, one ARGB window (rbnalpha): the dock's rounded ends,
# ring and shadow are its background, see-through around them; .dock.c
# (the strip's 54 px, in its own coordinates) holds the buttons.
proc dock::init {} {
	rbn::surface .dock -class RibbonShellDock -fill $theme::c(BAR)
	foreach b {1 2 3 4 5} { bind .dock.c <Button-$b> [list dock::click %x %y $b] }
}

# Windows grouped by app, in the order each app first appeared:
# {key ids label icon width active}
proc dock::groups {} {
	set keys {}
	foreach id [wm::windows] {
		set app [wm::get $id app]
		# every tab of every terminal group (ribbon-term-GROUP-N, mod-term.tcl) is one Terminal button
		if {[string match -nocase ribbon-term-* $app]} { set app ribbon-terminal }
		set k [string tolower $app]
		if {![info exists g($k)]} { lappend keys $k; set g($k) [list $app {}] }
		lset g($k) 1 [concat [lindex $g($k) 1] $id]
	}
	set out {}
	foreach k $keys {
		lassign $g($k) app ids
		set label [apps::label $app]
		set n [llength $ids]
		set tw [expr {round(10 + 16 + 8 + [text::width f13m $label] + 12)}]
		if {$n > 1} { incr tw [expr {6 + [badgew $n] - 4}] }
		lappend out [list $k $ids $label [apps::iconfor [apps::forwindow $app] $app] $tw [expr {$wm::focus in $ids}]]
	}
	return $out
}

proc dock::badgew {n} { expr {max(16, round(8 + [text::width f11s $n]))} }

proc dock::draw {} {
	variable hits
	variable wmenu
	variable overflow {}
	# the main display (bar::place): the dock is centred at the foot of it
	set X0 $bar::X0; set Y0 $bar::Y0
	set W $bar::W
	set H [expr {$bar::Y0 + $bar::H}]
	array set c [array get theme::c]
	set solid [expr {[wm::solid] || [theme::solid_bars]}]
	set hits {}
	set D .dock.c
	$D delete all
	$D configure -background $c(BAR)
	set frames {}; set extra {}; set pieces {}

	set tasks [groups]
	# as wide as what's open; past the screen width, a "+N" for the rest
	# (always keeping the app you're in)
	set room [expr {$W - 16}]
	# an open menu widens its button: keep room for that
	variable menuneed
	if {$wmenu ne ""} {
		set t [lsearch -index 0 -inline $tasks $wmenu]
		set natural [expr {$t ne "" ? [lindex $t 4] : 40}]
		set room [expr {$room - max(0, $menuneed - 8 - $natural)}]
	}
	set fit {apply {{tasks extra} { set cw 8; foreach t $tasks { incr cw [lindex $t 4] }; expr {$cw + max(0, 2 * ([llength $tasks] - 1 + $extra))} }}}
	set cw [{*}$fit $tasks 0]
	if {$cw > $room && [llength $tasks] > 1} {
		set shown {}
		set active [lsearch -index 5 -inline $tasks 1]
		if {$active ne ""} { set shown [list $active] }
		foreach t [lsearch -all -inline -not -index 5 $tasks 1] {
			set more [expr {[llength $tasks] - [llength $shown] - 1}]
			set morew [expr {$more > 0 ? round(10 + [text::width f13s "+$more"] + 10) : 0}]
			if {[{*}$fit [concat $shown [list $t]] [expr {$more > 0}]] + $morew > $room} break
			lappend shown $t
		}
		set shown [lmap t $tasks { if {$t in $shown} { set t } else { lappend overflow $t; continue } }]
		set tasks $shown
		set morew [expr {[llength $overflow] ? round(10 + [text::width f13s "+[llength $overflow]"] + 10) : 0}]
		set cw [expr {[{*}$fit $tasks [expr {[llength $overflow] > 0}]] + $morew}]
	}
	# A menu stands on its button, exactly as wide as it: the button widens
	# to fit the menu, and the two are one shape.
	variable menuneed
	set morew 0
	if {[llength $overflow]} { set morew [expr {round(10 + [text::width f13s "+[llength $overflow]"] + 10)}] }
	if {$wmenu ne ""} {
		set k [lsearch -index 0 $tasks $wmenu]
		if {$k >= 0} {
			lset tasks $k 4 [expr {max([lindex $tasks $k 4], $menuneed - 8)}]
		} elseif {$wmenu eq "more"} {
			set morew [expr {max($morew, $menuneed - 8)}]
		}
		set cw [expr {[{*}$fit $tasks [expr {[llength $overflow] > 0}]] + $morew}]
	}
	set cx [expr {int(floor($W / 2.0 - $cw / 2.0))}]
	# places: {key bx tw}
	set places {}
	set bx [expr {$cx + 4}]
	foreach t $tasks { lappend places [list [lindex $t 0] $bx [lindex $t 4]]; set bx [expr {$bx + [lindex $t 4] + 2}] }
	if {$morew} { lappend places [list more $bx $morew] }
	variable menux
	variable menuw
	set menu [lsearch -index 0 -inline $places $wmenu]
	if {$wmenu eq "" || $menu eq "" || $solid} { set menu "" }
	if {$menu ne ""} {
		lassign $menu - mbx mtw
		set menux [expr {$mbx - 4}]; set menuw [expr {$mtw + 8}]
	} else {
		set menux $cx; set menuw $cw
	}
	# the window reaches above the strip for the dock's shadow (canvas y
	# 0 is the strip's top, window y $top)
	set top 0
	if {[llength $tasks] && !$solid} {
		set flushl [expr {$menu ne "" && $menux <= $cx}]
		set flushr [expr {$menu ne "" && $menux + $menuw >= $cx + $cw}]
		set look [theme::look bar -radius [list [expr {$flushl ? 0 : 12}] [expr {$flushr ? 0 : 12}] 12 12]]
		set top [expr {max(0, [lindex [rbn::pads $look] 1] - 8)}]
		lappend frames [list $look $cx [expr {8 + $top}] $cw 38]
		if {$menu ne ""} {
			# the column the menu stands on, then its two edges: straight where
			# it is flush with the end of the dock, else a concave curve
			# (anti-aliased, so in the window's background)
			set x0 [expr {$menux + 1}]; set x1 [expr {$menux + $menuw - 1}]
			$D create rectangle $x0 0 $x1 9 -fill $c(BAR) -width 0
			lappend extra [list $x0 $top [expr {$x1 - $x0}] 9]
			if {$flushl} {
				$D create rectangle $menux 0 [expr {$menux + 1}] 9 -fill $c(BORDER) -width 0
				lappend extra [list $menux $top 1 9]
			} else {
				lappend pieces [rbn::piece [raster::fillet l 8 $c(BAR) $c(BORDER)] [expr {$menux - 8}] $top]
			}
			if {$flushr} {
				$D create rectangle $x1 0 [expr {$x1 + 1}] 9 -fill $c(BORDER) -width 0
				lappend extra [list $x1 $top 1 9]
			} else {
				lappend pieces [rbn::piece [raster::fillet r 8 $c(BAR) $c(BORDER)] $x1 $top]
			}
		}
	}
	set later {}
	foreach t $tasks p $places {
		if {$t eq ""} continue
		lassign $t key ids label ic - active
		lassign $p - bx tw
		set under [expr {$active || $key eq $wmenu ? $c(FIELD) : $c(BAR)}]
		if {$active || $key eq $wmenu} {
			rbn::box $D $bx 12 $tw 30 -fill $c(FIELD) -radius 8 -on $c(BAR)
		}
		if {$active} {
			rbn::box $D [expr {$bx + 8}] 38 [expr {max(6, $tw - 16)}] 2 -fill $c(ACCENT) -radius 1 -on $c(FIELD)
		}
		if {[llength $ids] > 1} {
			set bw [badgew [llength $ids]]
			rbn::box $D [expr {round($bx + 34 + [text::width f13m $label] + 6)}] 19 $bw 16 -fill $c(PILL) -radius 5 -on $under
		}
		lappend later [list $bx $tw $label $ic [expr {$active || $key eq $wmenu}] [llength $ids]]
		hit $bx 12 [expr {$bx + $tw}] 42 [list dock::task $key $ids]
	}
	set morebtn {}
	if {$morew} {
		lassign [lindex $places end] - bx
		set more "+[llength $overflow]"
		rbn::box $D $bx 12 $morew 30 -fill [expr {$wmenu eq "more" ? $c(FIELD) : $c(PILL)}] -radius 8 -on $c(BAR)
		set morebtn [list $bx $more]
		hit $bx 12 [expr {$bx + $morew}] 42 dock::more_menu
	}

	if {$solid} {
		rbn::show .dock $X0 [expr {$H - 54}] $W 54 -extra [list [list 0 0 $W 54]] -raise 0
	} elseif {[llength $frames]} {
		rbn::show .dock $X0 [expr {$H - 54 - $top}] $W [expr {54 + $top}] -frames $frames -pieces $pieces \
			-extra $extra -content [list 0 $top $W 54] -raise 0
	} else {
		# nothing open: an empty, see-through dock
		rbn::show .dock $X0 [expr {$H - 54}] $W 54 -shape {{0 0 0 0}} -input {{0 0 0 0}} -raise 0
	}
	foreach l $later {
		lassign $l bx tw label ic active n
		bar::icon $D $ic 16 1.8 [expr {$active ? $c(ACCENT) : $c(MUTED)}] [expr {$bx + 10}] 19
		text::draw $D [expr {$bx + 34}] 27 f13m [expr {$active ? $c(FG) : $c(MUTED)}] $label w
		if {$n > 1} {
			set bw [badgew $n]
			# the count: §muted, §fg on the app you are in (the accent is for its icon and underline, STYLE §1)
			text::draw $D [expr {$bx + 34 + [text::width f13m $label] + 6 + $bw / 2.0}] 27 f11s [expr {$active ? $c(FG) : $c(MUTED)}] $n center
		}
	}
	if {[llength $morebtn]} {
		lassign $morebtn mx more
		variable wmenu
		text::draw $D [expr {$mx + 10}] 27 f13s [expr {$wmenu eq "more" ? $c(FG) : $c(MUTED)}] $more w
	}
}

proc dock::hit {x0 y0 x1 y1 script} {
	variable hits
	lappend hits [list $x0 $y0 $x1 $y1 $script]
}

proc dock::click {x y b} {
	variable hits
	foreach h $hits {
		lassign $h x0 y0 x1 y1 script
		if {$x >= $x0 && $x < $x1 && $y >= $y0 && $y < $y1} { uplevel #0 [linsert $script end $b]; return }
	}
	launcher::cancel
	panel::close
}

# Click: one window toggles as before; a group cycles through its windows,
# starting from the one used last.
proc dock::task {key ids b} {
	if {[llength $ids] == 1} {
		set id [lindex $ids 0]
		switch $b {
			1 { wm::toggle $id }
			2 { wm::send "close $id" }
			3 { window_menu $key $id }
		}
		return
	}
	switch $b {
		1 {
			set i [lsearch -exact $ids $wm::focus]
			if {$i >= 0} {
				wm::send "activate [lindex $ids [expr {($i + 1) % [llength $ids]}]]"
			} else {
				wm::send "activate [wm::latest $ids]"
			}
		}
		3 { group_menu $key $ids }
	}
}

proc dock::open_menu {key items} {
	variable wmenu $key
	variable menuneed [need $items]
	draw
	variable menux
	variable menuw
	files::popup_menu . [expr {$bar::X0 + $menux}] [expr {$bar::Y0 + $bar::H - 54}] $items $menuw up
}

# The width a menu's longest line needs (popup_menu's layout, "up" mode).
proc dock::need {items} {
	set w 200
	foreach it $items {
		if {$it eq "-"} continue
		lassign $it icon label cmd key accent chips
		set n [expr {38 + [text::width f13 $label] + 16}]
		if {$key ne ""} { set n [expr {$n + 10 + [text::width f11 $key]}] }
		if {[llength $chips]} { set n [expr {$n + 6 + 28 * [llength $chips]}] }
		set w [expr {max($w, $n)}]
	}
	expr {min(round(ceil($w)), $bar::W - 16)}
}

proc dock::window_menu {key id} {
	set maxed [wm::has $id max]
	set chips {}
	foreach ws [wm::workspaces] { lappend chips [list [lindex $ws 1] [lindex $ws 2] [list dock::send_to $id [lindex $ws 1]]] }
	open_menu $key [list \
		[list minus Minimise [list wm::send "minimize $id"]] \
		[list [expr {$maxed ? "restore" : "square"}] [expr {$maxed ? "Restore" : "Maximise"}] [list wm::send "[expr {$maxed ? "unmaximize" : "maximize"}] $id"]] \
		[list ws "Move to" {} {} 0 $chips] \
		- \
		{*}[expr {[set a [apps::forwindow [wm::get $id app]]] ne "" ? [list [list info Properties [list apps::app_properties $a]]] : ""}] \
		[list x Close [list wm::send "close $id"] Super+Q 1]]
}

# A menu line for a window: "App · title", or just the title when the
# menu already belongs to that app.
proc dock::item {id {titleonly 0}} {
	set app [wm::get $id app]
	set label [apps::label $app]
	set title [launcher::short_title [wm::get $id title] $label]
	if {$titleonly && $title ne ""} {
		set label $title
	} elseif {$title ne "" && ![string equal -nocase $title $label]} { append label "  ·  $title" }
	list [apps::iconfor [apps::forwindow $app] $app] $label [list wm::send "activate $id"]
}

# The windows of a group.
proc dock::group_menu {key ids} {
	set items [lmap id $ids { item $id 1 }]
	set a [apps::forwindow [wm::get [lindex $ids 0] app]]
	if {$a ne ""} { lappend items - [list info Properties [list apps::app_properties $a]] }
	open_menu $key $items
}

# The apps that didn't fit.
proc dock::more_menu {b} {
	variable overflow
	if {$b != 1 || ![llength $overflow]} return
	# the "+N" widens for its menu, which can push one more app into it
	variable wmenu more
	variable menuneed 200
	draw
	set items {}
	foreach t $overflow { foreach id [lindex $t 1] { lappend items [item $id] } }
	open_menu more $items
}

# labwc has no command line for "send to workspace", so focus the window
# and press its keybinding (Super+Shift+N in Ribbon's rc.xml).
proc dock::send_to {id name} {
	wm::send "activate $id"
	after 120 [list apps::run "wtype -M logo -M shift -k $name"]
}
