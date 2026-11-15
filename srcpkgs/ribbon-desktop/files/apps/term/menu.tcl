# menu.tcl - a terminal tab's menu (docs/TERMINAL.md §6 "Menu"; board Term-P-Menu-1-Tab): a right click on a tab's
# pill. Loaded by the shell with the strip (shell/mod-term.tcl); it draws with the shell's text, raster and rbnalpha.
#
#   tmenu::open ID X Y     the menu of tab ID (a window id), its top-left at screen X Y (under the pill)
#   tmenu::close
#
# The menu: 300 wide, §field, radius 10, 6 px padding, 34 px rows (icon at 16, label at 41, the keys at the right),
# rules between the three groups; the row under the pointer is raised in §pill. "New tab with profile" opens the
# profiles beside it (210 wide, each with what sets it apart). "Text size" is a stepper in the row: it changes that
# tab's size at once and the menu stays. What a row does is the terminal's (term::menu_do ID WHAT ?ARG?).

namespace eval tmenu {
	variable win .termmenu
	variable id ""            ;# the tab the menu is for
	variable hover ""         ;# the row under the pointer
	variable sub 0            ;# the profiles are open
	variable subhover ""
	variable at {0 0}         ;# the menu's top-left on screen
	variable rows {}          ;# {key y h} of the rows drawn, menu coordinates
	variable profiles {}      ;# {name what} of the submenu
	variable icons
	array set icons {
		new     {M12 5v14 M5 12h14}
		profile {M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2 M12 11a4 4 0 1 0 0-8a4 4 0 1 0 0 8z}
		dup     {M9 9h11v11H9z M5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1}
		rename  {M12 20h9 M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4z}
		size    {M4 7V4h16v3 M9 20h6 M12 4v16}
		restart {M23 4v6h-6 M1 20v-6h6 M3.51 9a9 9 0 0 1 14.85-3.36L23 10 M1 14l4.64 4.36A9 9 0 0 0 20.49 15}
		prefs   {M21 4h-7 M10 4H3 M21 12h-9 M8 12H3 M21 20h-5 M12 20H3 M14 2v4 M8 10v4 M16 18v4}
		window  {M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6 M15 3h6v6 M10 14L21 3}
		close   {M18 6L6 18 M6 6l12 12}
		chev    {M9 6l6 6-6 6}
		minus   {M5 12h14}
		plus    {M12 5v14 M5 12h14}
	}
	# key, label, the key of profiles.tcl whose chord shows at the right ("" none); "-" a rule
	variable items {
		new     {New tab}                    new
		profile {New tab with profile}       ""
		dup     {Duplicate tab}              ""
		rename  "Rename…"               ""
		-       ""                           ""
		size    {Text size}                  ""
		restart {Restart with new settings}  ""
		prefs   "Preferences…"          prefs
		-       ""                           ""
		window  {Move to a new window}       ""
		close   {Close tab}                  close
	}
}

# The chord of a key as the menu writes it: "Ctrl Shift T".
proc tmenu::chord {key} {
	if {$key eq "" || ![llength [info commands ::prof::get]]} { return "" }
	set names {Control Ctrl Shift Shift Mod1 Alt Mod4 Super Next PgDn Prior PgUp comma , equal = minus \u2212}
	set out {}
	foreach p [split [prof::get Default key_$key] +] {
		lappend out [expr {[dict exists $names $p] ? [dict get $names $p] : [string length $p] == 1 ? [string toupper $p] : $p}]
	}
	join $out " "
}

proc tmenu::icon {cv name size sw colour x y} {
	variable icons
	set i [raster::icon $icons($name) $size $sw $colour]
	$cv create image [expr {round($x)}] [expr {round($y)}] -image $i -anchor nw
}

proc tmenu::open {tab X Y} {
	variable win
	variable id $tab
	variable hover ""
	variable sub 0
	variable subhover ""
	variable at [list $X $Y]
	variable profiles {}
	destroy $win
	if {[llength [info commands ::prof::get]]} {
		foreach n $prof::order {
			set what ""
			if {$n ne "Default"} {
				if {[prof::get $n command] ne ""} { set what [prof::get $n command] } elseif {[prof::own $n size]} { set what "[prof::get $n size] pt" }
			}
			lappend profiles [list $n $what]
		}
	}
	rbn::surface $win -fill $theme::c(FIELD)
	bind $win.c <Motion> {tmenu::motion %x %y}
	bind $win.c <ButtonPress-1> {tmenu::click %x %y}
	bind $win <Escape> {tmenu::close}
	draw
	update idletasks
	catch {grab -global $win}
	bind $win <ButtonPress> {tmenu::outside %X %Y}
}

proc tmenu::close {} {
	variable win
	variable id ""
	catch {grab release $win}
	destroy $win
}

# The window: the menu's box, and the profiles' box beside "New tab with profile" while they are open. Everything
# is drawn at the offset the look's shadow leaves (ox, oy).
proc tmenu::draw {} {
	variable win
	variable id
	variable hover
	variable sub
	variable subhover
	variable at
	variable rows
	variable items
	variable profiles
	variable off
	array set c [array get theme::c]
	set cv $win.c
	$cv delete all
	text::font tm13 {Ribbon Inter 500} 13
	text::font tm12 {Ribbon Inter 500} 12
	set look [theme::look menu -fill $c(FIELD)]
	set k [rbn::look $look]
	lassign $rbn::looks($k) - pad pt pb
	set W 300
	set h 12
	# the rule's space is 14 px after the first group and 11 after the second, as the board has them
	set nrule 0
	foreach {key label kk} $items { incr h [expr {$key eq "-" ? ([incr nrule] == 1 ? 14 : 11) : $key eq "size" ? 37 : 34}] }
	set sh [expr {12 + 34 * [llength $profiles]}]
	set frames [list [list $look $pad $pt $W $h ""]]
	set ww [expr {$pad + $W + $pad}]; set wh [expr {$pt + $h + $pb}]
	if {$sub} {
		lappend frames [list $look [expr {$pad + 296}] [expr {$pt + 34}] 210 $sh ""]
		set ww [expr {$pad + 296 + 210 + $pad}]; set wh [expr {$pt + max($h, 34 + $sh) + $pb}]
	}
	set off [list $pad $pt]
	set ox $pad; set oy $pt
	set rows {}
	set y 6
	set later {}
	set nrule 0
	foreach {key label kk} $items {
		if {$key eq "-"} {
			$cv create rectangle [expr {$ox + 10}] [expr {$oy + $y + 5}] [expr {$ox + $W - 10}] [expr {$oy + $y + 6}] -fill $c(BORDER) -width 0
			incr y [expr {[incr nrule] == 1 ? 14 : 11}]; continue
		}
		set rh [expr {$key eq "size" ? 37 : 34}]
		set on [expr {$hover eq $key || ($key eq "profile" && $sub)}]
		if {$on && $key ne "size"} { rbn::box $cv [expr {$ox + 6}] [expr {$oy + $y}] [expr {$W - 12}] 34 -fill $c(PILL) -radius 8 -on $c(FIELD) }
		lappend rows [list $key $y $rh]
		set ty [expr {$oy + $y}]
		icon $cv $key 15 2 [expr {$on ? $c(FG) : $c(MUTED)}] [expr {$ox + 16}] [expr {$ty + 9.5}]
		lappend later [list text::draw $cv [expr {$ox + 41}] [expr {$ty + 17}] tm13 $c(FG) $label w]
		switch -- $key {
			profile { icon $cv chev 14 2.2 $c(FG) [expr {$ox + 270}] [expr {$ty + 10}] }
			size {
				set bx [expr {$ox + 190}]; set by [expr {$oy + $y + 2}]
				rbn::box $cv $bx $by 100 30 -fill $c(BAR) -radius 8 -on $c(FIELD)
				icon $cv minus 14 2.2 $c(FG) [expr {$bx + 8}] [expr {$by + 8}]
				icon $cv plus 14 2.2 $c(FG) [expr {$bx + 78}] [expr {$by + 8}]
				set v [::term::tab_size $id]
				set w1 [text::width tm13 $v]; set w2 [text::width tm13 " pt"]
				set tx [expr {$bx + 50 - ($w1 + $w2) / 2.0}]
				lappend later [list text::draw $cv $tx [expr {$by + 15}] tm13 $c(FG) $v w]
				lappend later [list text::draw $cv [expr {$tx + $w1}] [expr {$by + 15}] tm13 $c(MUTED) " pt" w]
			}
			default {
				set ch [chord $kk]
				if {$ch ne ""} { lappend later [list text::draw $cv [expr {$ox + 284}] [expr {$ty + 17}] tm12 $c(MUTED) $ch e] }
			}
		}
		incr y $rh
	}
	if {$sub} {
		set sx [expr {$ox + 296}]; set sy [expr {$oy + 34}]
		set y 6
		foreach p $profiles {
			lassign $p name what
			set on [expr {$subhover eq $name}]
			if {$on} { rbn::box $cv [expr {$sx + 6}] [expr {$sy + $y}] 198 34 -fill $c(PILL) -radius 8 -on $c(FIELD) }
			icon $cv profile 15 2 [expr {$on ? $c(FG) : $c(MUTED)}] [expr {$sx + 16}] [expr {$sy + $y + 9.5}]
			lappend later [list text::draw $cv [expr {$sx + 41}] [expr {$sy + $y + 17}] tm13 $c(FG) $name w]
			if {$what ne ""} { lappend later [list text::draw $cv [expr {$sx + 194}] [expr {$sy + $y + 17}] tm12 $c(MUTED) $what e] }
			incr y 34
		}
	}
	foreach l $later { {*}$l }
	lassign $at X Y
	rbn::show $win [expr {$X - $pad}] [expr {$Y - $pt}] $ww $wh -frames $frames -content [list 0 0 $ww $wh]
}

# What is at a point of the window: {row KEY}, {minus}, {plus}, {profile NAME} or {}.
proc tmenu::what {x y} {
	variable rows
	variable sub
	variable profiles
	variable off
	lassign $off ox oy
	set x [expr {$x - $ox}]; set y [expr {$y - $oy}]
	if {$sub && $x >= 296 && $x < 506 && $y >= 40} {
		set i [expr {int(($y - 40) / 34)}]
		if {$i < [llength $profiles]} { return [list profile [lindex $profiles $i 0]] }
		return {}
	}
	if {$x < 0 || $x >= 300} { return {} }
	foreach r $rows {
		lassign $r key ry rh
		if {$y >= $ry && $y < $ry + $rh} {
			if {$key eq "size"} {
				if {$x >= 190 && $x < 222} { return minus }
				if {$x >= 258 && $x < 290} { return plus }
			}
			return [list row $key]
		}
	}
	return {}
}

proc tmenu::motion {x y} {
	variable hover
	variable sub
	variable subhover
	lassign [what $x $y] kind key
	set h $hover; set s $sub; set sh $subhover
	switch -- $kind {
		row { set hover $key; set subhover ""; set sub [expr {$key eq "profile"}] }
		minus - plus { set hover size; set sub 0 }
		profile { set subhover $key }
		default { set hover ""; set subhover "" }
	}
	if {$h ne $hover || $s != $sub || $sh ne $subhover} draw
}

proc tmenu::click {x y} {
	variable id
	variable sub
	lassign [what $x $y] kind key
	set tab $id
	switch -- $kind {
		minus { ::term::menu_do $tab size -1; draw }
		plus { ::term::menu_do $tab size 1; draw }
		profile { close; after idle [list ::term::menu_do $tab profile $key] }
		row {
			if {$key eq "profile"} { set sub 1; draw; return }
			if {$key eq "size"} return
			close
			after idle [list ::term::menu_do $tab $key]
		}
	}
}

# A press outside both boxes closes the menu.
proc tmenu::outside {X Y} {
	variable win
	if {![winfo exists $win]} return
	set x [expr {$X - [winfo rootx $win]}]; set y [expr {$Y - [winfo rooty $win]}]
	if {[what $x $y] eq {}} {
		variable off
		lassign $off ox oy
		# the padding and the rules inside the menu are still the menu
		if {$x >= $ox && $x < $ox + 300 && $y >= $oy && $y < [winfo height $win] - $oy} return
		close
	}
}
