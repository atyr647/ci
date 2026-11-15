# bar.tcl - the two bars across the top of the screen (the dock of open
# windows is at the bottom: dock.tcl).
#
# Geometry follows the Ribbon mockups exactly (CSS px): bars 38 tall at
# 8 px from the edges, 4 px padding, 12 px radius, 30 px controls with
# 8 px radius. The strip is one ARGB window (rbnalpha): the bars' rounded
# ends, rings and soft shadows are its background, painted by the X server
# and blended by the compositor over whatever is behind, a picture or a
# video; between and around the bars it is see-through, and clicks there
# reach the desktop. Pills, fields, text and icons are canvas items in
# .bar.c, which is cut to the bars' insides. The idle animation only
# moves the field's items.

# the main display's rectangle (display.tcl, read from display.conf and the compositor)
source -encoding utf-8 [file join [file dirname [file normalize [info script]]] display.tcl]

namespace eval bar {
	variable X0 0         ;# the main display's place on the X screen: the bars and the dock go there
	variable Y0 0
	variable W 1440       ;# the main display's size
	variable H 900
	variable hits {}      ;# {x0 y0 x1 y1 script}
	variable field {}     ;# field geometry for the fast text path: {x width}
	variable leftw 0      ;# the left bar's width (the mode menu matches it)
	variable rightx 0     ;# the right bar's place on the screen, X0 included (its panels hang from it)
	variable rightw 0
	variable hover ""     ;# the window control under the pointer
	variable wshover ""   ;# the workspace part under the pointer (its id)
	variable pwhover 0    ;# the power button under the pointer
	variable placed {}    ;# the right bar's items: {kind x width}, from the last draw
	variable wsparts {}   ;# the switcher's parts: {id x active}, from the last draw
	variable wsaved ""    ;# the workspace last written to the shell's state (fault::save)
	variable restore {}   ;# what was open before a restart in this login: {ws ID panel KIND}, used once
}

proc bar::init {} {
	bar::place
	display::on_change bar::moved
	display::start
	wm withdraw .
	# a restart within this login restores the workspace and the open panel (fault.tcl's state)
	variable restore
	if {[bar::session_restart] && [llength [info commands ::fault::get]]} {
		set restore [list ws [fault::get workspace ""] panel [fault::get panel ""]]
	}
	# An unmanaged (override-redirect) window: it sits exactly at the top
	# of the screen on every workspace, above windows; labwc keeps new and
	# maximized windows below it (the margin layer mod-margin.tcl writes).
	rbn::surface .bar -class RibbonShellBar -fill $theme::c(BAR)
	wm title .bar Ribbon
	# Keyboard input: labwc gives keys only to managed windows, so while
	# you type, a 1 x 1 managed window (see-through, kept at the bottom by
	# a window rule) holds the focus and forwards keys.
	rbn::surface .in -class RibbonShellInput -managed 1 -fill $theme::c(BAR)
	wm title .in "Ribbon input"
	bind .in <KeyPress> {launcher::key %K %A %s}
	foreach b {1 2 3 4 5} { bind .bar.c <Button-$b> "bar::click %x %y $b" }
	bind .bar.c <Motion> {bar::motion %x %y}
	bind .bar.c <Leave> {bar::motion -1 -1}
}

# The bars' and the dock's place: the main display's rectangle.
proc bar::place {} {
	variable X0; variable Y0; variable W; variable H
	lassign [display::rect] X0 Y0 W H
}
# The main display changed (Settings kept another, or a monitor came or went): move there.
proc bar::moved {} {
	bar::place
	shell::refresh
}

# The tray's quick settings are open (Wi-Fi, sound, Bluetooth, power, storage): not the updates panel, and not
# the power button's session panel, which lights only the power button (board Power-Final-3-Open).
proc bar::tray_open {} { expr {$panel::open ni {"" updates session sni}} }

proc bar::hit {x0 y0 x1 y1 script} {
	variable hits
	lappend hits [list $x0 $y0 $x1 $y1 $script]
}

proc bar::click {x y b} {
	variable hits
	foreach h $hits {
		lassign $h x0 y0 x1 y1 script
		if {$x >= $x0 && $x < $x1 && $y >= $y0 && $y < $y1} { uplevel #0 [linsert $script end $b]; return }
	}
	launcher::cancel
	panel::close
	nhist::close
}

# Put a line icon of SIZE at float position x y (top-left).
proc bar::icon {c name size stroke colour x y {extra {}}} {
	set ix [expr {int(floor($x))}]; set iy [expr {int(floor($y))}]
	set img [theme::icon $name $size $stroke $colour [expr {$x - $ix}] [expr {$y - $iy}] $extra]
	$c create image $ix $iy -image $img -anchor nw
}

# Text with tabular figures (CSS font-variant-numeric: tabular-nums), from
# the font's 'tnum' glyphs (text.tcl). Returns the width.
proc bar::tabwidth {font text} { text::width $font $text 0 1 }
proc bar::tabtext {c x y font colour text} { text::draw $c $x $y $font $colour $text w -tnum 1 }

# Letter-spaced text (CSS letter-spacing). Returns the width.
proc bar::spaced {c x y font colour text ls} { text::draw $c $x $y $font $colour $text w -ls $ls }

# Full redraw: called (coalesced) whenever something visible changes.
# ~/.config/ribbon/power.conf (KEY=VALUE lines): the value of KEY, the last line wins, or DEF. Read the way
# store::conf_get reads theme.conf (the Settings power page writes this file).
proc bar::power_conf {key def} { conf power $key $def }
# KEY of $XDG_CONFIG_HOME/ribbon/NAME.conf (Settings' files: power, sound, bluetooth), or DEF.
proc bar::conf {name key def} {
	set v $def
	set cfg [expr {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""
		? $::env(XDG_CONFIG_HOME) : [file join [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}] .config]}]
	if {![catch {::open [file join $cfg ribbon $name.conf]} fh]} {
		foreach line [split [::read $fh] \n] { regexp "^${key}=(.*)\$" $line -> v }
		::close $fh
	}
	return $v
}

proc bar::draw {} {
	after idle { if {$panel::open ne ""} { panel::draw } }
	variable W
	variable H
	variable hits
	variable field
	variable wshover
	variable pwhover
	array set c [array get theme::c]
	# solid strips under a maximized window (no seam: the strip runs
	# straight into its title bar), or over a video with BARS=solid
	set solid [expr {[wm::solid] || [theme::solid_bars]}]
	set v [launcher::view]
	set hits {}
	set wsp {}
	set C .bar.c
	$C delete all
	$C configure -background $c(BAR)
	set frames {}

	# ---- left bar: mode pill + field
	set mlabel [dict get $v modelabel]
	set mw [expr {round(9 + 15 + 6 + [text::width f13s $mlabel] + 6 + 13 + 7)}]
	set fx [expr {12 + $mw + 4}]
	# With results or the mode menu open, the left bar grows down into them
	# as one shape (results: the bar widens to their 460 px).
	set panel [launcher::panel]
	# the bell (the notifications button, its count) sits at the bar's right end: 6 after the field (STYLE §12)
	lassign [nhist::bell_info] bcount bdnd bopen
	set bw [expr {$bcount > 0 ? round(9 + 15 + 6 + [text::width f12s $bcount] + 9) : 30}]
	set lw [expr {$panel eq "drop" ? 460 : 424}]
	set fw [expr {$lw - 18 - $mw - $bw}]
	variable leftw $lw
	if {!$solid} {
		if {$panel ne ""} {
			lappend frames [list [theme::look pop -radius {12 12 0 0} -ring [list $c(BORDER) 1 tlr]] 8 8 $lw 46 b]
		} else {
			lappend frames [list [theme::look bar] 8 8 $lw 38]
		}
	}
	set menu [dict get $v menu]
	rbn::box $C 12 12 $mw 30 -fill [expr {$menu ? $c(ACCENT) : $c(PILL)}] -radius 8 -on $c(BAR)
	rbn::box $C $fx 12 $fw 30 -fill $c(FIELD) -radius 8 -ring [dict get $v ring] -on $c(BAR)

	# ---- right bar: status icons, updates, clock, workspaces
	# the tray: one button showing Wi-Fi and battery at a glance, opening
	# quick settings (Wi-Fi, Bluetooth, sound, power) under the bar
	set glyphs {}
	if {$status::wifi ne ""} { lappend glyphs [list [expr {$status::wifi eq "on" ? "wifi" : "wifi-off"}] 15 1.9 {}] }
	# the volume (crossed out when muted); sound.conf's BAR=no hides it (Settings → Sound, Volume in the bar)
	if {$status::volume ne "" && [conf sound BAR yes] ne "no"} { lappend glyphs [list [expr {$status::muted ? "volume-x" : "volume"}] 15 1.9 {}] }
	# a Bluetooth device's battery, for the devices bluetooth.conf's BAR_BATTERY lists (Settings → Bluetooth, Show
	# battery in the bar): the first of them that is connected and reports one
	set want [string toupper [conf bluetooth BAR_BATTERY ""]]
	if {$want ne "" && [info exists ::panel::data(devs)]} {
		foreach d $::panel::data(devs) {
			lassign $d mac name on icon pct
			if {$on && $pct ne "" && [string toupper $mac] in $want} {
				lappend glyphs [list bt 15 1.9 {}] [list pct [expr {round([text::width f12s "$pct%"])}] 0 "$pct%"]
				break
			}
		}
	}
	# running out of disk space: a drive, in the accent, until it's sorted
	if {[status::storage_state] ne "ok"} { lappend glyphs [list drive 15 1.9 {} $theme::c(ACCENT)] }
	if {$status::battery ne ""} {
		set bw [expr {max(0.5, 12.2 * min(100, $status::battery) / 100.0)}]
		lappend glyphs [list battery 17 1.7 [list 4 10 $bw 4 0.5]]
		# the percentage beside it; power.conf's BAR_PERCENT=no hides it (the default is yes)
		if {[power_conf BAR_PERCENT yes] ne "no"} {
			set pct "$status::battery%"
			lappend glyphs [list pct [expr {round([text::width f12s $pct])}] 0 $pct]
		}
	}
	set items {}
	# apps' tray icons (mod-tray.tcl, tray.tcl): left of the quick-settings button (board Tray-1-Icons)
	if {[llength [info commands ::tray::width]] && [set sniw [tray::width]] > 0} { lappend items [list sni $sniw] }
	set trayw [expr {9 + 13 + 9}]
	foreach g $glyphs { incr trayw [expr {[lindex $g 1] + 7}] }
	lappend items [list tray $trayw]
	if {$status::updates > 0} { lappend items [list updates [expr {round(9 + 13 + 5 + [text::width f12s $status::updates] + 9)}]] }
	lappend items {divider 13}
	# the date is left out with Settings' "Date in the bar" off (status::date is then empty), and its gap with it
	set clockw [expr {round(8 + ($status::date ne "" ? [tabwidth f13 $status::date] + 8 : 0) + [tabwidth f13s $status::time] + 8)}]
	lappend items [list clock $clockw]
	set wss [wm::workspaces]
	bar::remember_ws $wss
	variable restore
	if {$restore ne {}} { after idle bar::restore }
	# the workspace switcher: a segmented track, 26 tall, with a 24 x 22 part
	# per workspace, 2 apart, in a 30 px slot (STYLE §12, ws_switch)
	if {[llength $wss]} { lappend items [list ws [expr {26 * [llength $wss] + 10}]] }
	# the power button: 30 x 30, after the switcher (Power-Final boards; its panel is session)
	lappend items {power 30}
	# window controls only while the focused window is maximized or fullscreen: the state in which the bars
	# join into one solid strip (wm::solid). A floating window, or none, shows no controls.
	if {[wm::solid]} { lappend items {divider 13} {wctl 94} }
	# the bar is 480 px at least, its items right-aligned with 12 px on the
	# left and 4 on the right; any slack is left of the tray (STYLE §12)
	set content [expr {4 * ([llength $items] - 1)}]
	foreach i $items { incr content [lindex $i 1] }
	set rw [expr {max(480, 16 + $content)}]
	set rx [expr {$W - 8 - $rw}]
	variable X0
	variable Y0
	variable rightx [expr {$X0 + $rx}]
	variable rightw $rw
	if {!$solid} {
		if {$panel::open ne ""} {
			lappend frames [list [theme::look pop -radius {12 12 0 0} -ring [list $c(BORDER) 1 tlr]] $rx 8 $rw 46 b]
		} else {
			lappend frames [list [theme::look bar] $rx 8 $rw 38]
		}
	}
	set x [expr {$rx + $rw - 4 - $content}]
	set place {}
	foreach i $items {
		lassign $i kind iw
		switch $kind {
			tray { if {[tray_open]} { rbn::box $C $x 12 $iw 30 -fill $c(FIELD) -radius 8 -on $c(BAR) } }
			updates { rbn::box $C $x 12 $iw 30 -fill $c(ACCENT) -radius 8 -on $c(BAR) }
			power { if {$pwhover || $panel::open eq "session"} { rbn::box $C $x 12 $iw 30 -fill $c(FIELD) -radius 8 -on $c(BAR) } }
			wctl {
				variable hover
				if {$hover ne "" && $wm::focus ne ""} {
					set hx [expr {$x + 32 * [lsearch {min max close} $hover]}]
					rbn::box $C $hx 12 30 30 -fill [expr {$hover eq "close" ? $c(ACCENT) : $c(FIELD)}] -radius 8 -on $c(BAR)
				}
			}
			ws {
				# the track, then the parts: the one you are on is accent, the one under the pointer §pill
				set tw [expr {26 * [llength $wss] + 2}]
				rbn::box $C [expr {$x + 4}] 14 $tw 26 -fill $c(FIELD) -radius 8 -ring [list $c(BORDER) 1] -on $c(BAR)
				set bx [expr {$x + 6}]
				foreach w $wss {
					lassign $w id name active
					if {$active} {
						rbn::box $C $bx 16 24 22 -fill $c(ACCENT) -radius 6 -on $c(FIELD)
					} elseif {$id eq $wshover} {
						rbn::box $C $bx 16 24 22 -fill $c(PILL) -radius 6 -on $c(FIELD)
					}
					incr bx 26
				}
			}
		}
		lappend place [list $kind $x $iw]
		set x [expr {$x + $iw + 4}]
	}

	# ---- the window: the bars' frames, or a solid strip; then text and icons
	if {$solid} {
		rbn::show .bar $X0 $Y0 $W 54 -extra [list [list 0 0 $W 54]] -raise 0
	} else {
		# tall enough for the bars' shadows; only the bars take clicks
		set wh 54
		foreach f $frames {
			lassign $f look - fy - fh clip
			if {[string first b $clip] < 0} { set wh [expr {max($wh, $fy + $fh + [lindex [rbn::pads $look] 2])}] }
		}
		rbn::show .bar $X0 $Y0 $W $wh -frames $frames -content [list 0 0 $W 54] -raise 0
	}

	# mode pill
	set pc [expr {$menu ? $c(ON_ACCENT) : $c(ACCENT)}]
	icon $C [dict get $v modeicon] 15 1.9 $pc 21 19.5
	text::draw $C 42 27 f13s $pc $mlabel w
	icon $C [expr {$menu ? "up-chev" : "down"}] 13 2.2 $pc [expr {42 + [text::width f13s $mlabel] + 6}] 20.5
	hit 12 12 [expr {12 + $mw}] 42 launcher::menu_toggle
	# field
	set field [list $fx $fw]
	hit $fx 12 [expr {$fx + $fw}] 42 launcher::field_click
	field_items
	# the bell: open it lit (§field, §fg); slashed under Do Not Disturb; the count beside it when there is one
	set bx [expr {$fx + $fw + 6}]
	if {$bopen} { rbn::box $C $bx 12 $bw 30 -fill $c(FIELD) -radius 8 -on $c(BAR) }
	set img [nhist::bell_icon [expr {$bopen ? $c(FG) : $c(MUTED)}] $bdnd]
	$C create image [expr {$bcount > 0 ? $bx + 9 : round($bx + ($bw - 15) / 2.0)}] 20 -image $img -anchor nw
	if {$bcount > 0} { text::draw $C [expr {$bx + 30}] 27 f12s $c(FG) $bcount w }
	hit $bx 12 [expr {$bx + $bw}] 42 nhist::bell

	# right bar contents
	foreach p $place {
		lassign $p kind x iw
		switch $kind {
			sni { tray::draw $C $x }
			tray {
				set col [expr {[tray_open] ? $c(ACCENT) : $c(MUTED)}]
				hit $x 12 [expr {$x + $iw}] 42 [list panel::toggle tray]
				set gx [expr {$x + 9}]
				foreach g $glyphs {
					lassign $g name sz st extra gc
					if {$name eq "pct"} {
						text::draw $C $gx 27 f12s $col $extra w
					} else {
						icon $C $name $sz $st [expr {$gc ne "" ? $gc : $col}] $gx [expr {27 - $sz / 2.0}] $extra
					}
					set gx [expr {$gx + $sz + 7}]
				}
				icon $C [expr {[tray_open] ? "up-chev" : "down"}] 13 2.2 $col $gx 20.5
			}
			updates {
				# the arrow and the count, both §ink (ON_ACCENT) on the accent: nothing else
				icon $C up 13 2.4 $c(ON_ACCENT) [expr {$x + 9}] 20.5
				text::draw $C [expr {$x + 9 + 13 + 5}] 27 f12s $c(ON_ACCENT) $status::updates w
				hit $x 12 [expr {$x + $iw}] 42 status::updates_click
			}
			divider { $C create rectangle [expr {$x + 6}] 19 [expr {$x + 7}] 35 -fill $c(BORDER) -width 0 }
			power {
				# the 15 px power icon, centred in the 30 px button: §muted, §fg when lit (hover or open)
				set on [expr {$pwhover || $panel::open eq "session"}]
				icon $C power 15 1.9 [expr {$on ? $c(FG) : $c(MUTED)}] [expr {$x + 7.5}] 19.5
				hit $x 12 [expr {$x + $iw}] 42 [list panel::toggle session]
			}
			wctl {
				variable hover
				set f $wm::focus
				# dimmed (35%) when there is no window to act on
				set col [expr {$f eq "" ? [mix $c(BAR) $c(MUTED) 0.35] : $c(MUTED)}]
				set maxed [expr {$f ne "" && [wm::has $f max]}]
				foreach {k icon sz st} [list min minus 15 1.8 max [expr {$maxed ? "restore" : "square"}] 13 2 close x 15 1.8] {
					set ic [expr {$f ne "" && $hover eq $k ? ($k eq "close" ? $c(ON_ACCENT) : $c(FG)) : $col}]
					icon $C $icon $sz $st $ic [expr {$x + 15 - $sz / 2.0}] [expr {27 - $sz / 2.0}]
					hit $x 12 [expr {$x + 30}] 42 [list bar::wctl $k]
					set x [expr {$x + 32}]
				}
			}
			clock {
				set tx [expr {$x + 8}]
				if {$status::date ne ""} {
					tabtext $C $tx 27 f13 $c(MUTED) $status::date
					set tx [expr {$tx + [tabwidth f13 $status::date] + 8}]
				}
				tabtext $C $tx 27 f13s $c(FG) $status::time
			}
			ws {
				# numbers 1, 2, 3 in the parts: 12 px, tabular; the current one 600 in §ink
				set bx [expr {$x + 6}]
				set n 0
				foreach w $wss {
					lassign $w id name active
					incr n
					if {$active} { set col $c(ON_ACCENT); set font f12s } else {
						set col [expr {$id eq $wshover ? $c(FG) : $c(MUTED)}]; set font f12m
					}
					text::draw $C [expr {$bx + 12}] 27 $font $col $n center -tnum 1
					hit $bx 16 [expr {$bx + 24}] 38 [list bar::workspace $id]
					lappend wsp [list $id $bx $active]
					incr bx 26
				}
				# the rest of the track steps through the workspaces when scrolled
				hit [expr {$x + 4}] 14 [expr {$x + 4 + 26 * [llength $wss] + 2}] 40 [list bar::ws_track]
			}
		}
	}
	variable placed $place
	variable wsparts $wsp
	dock::draw
}

# The field's contents: redrawn on their own for the idle animation.
proc bar::field_items {} {
	variable field
	array set c [array get theme::c]
	lassign $field fx fw
	set C .bar.c
	$C delete field
	set v [launcher::view]
	set lead [dict get $v lead]
	set img [theme::icon $lead 15 [expr {$lead eq "search" ? 2 : 1.9}] [dict get $v leadcolour] 0 0.5]
	$C create image [expr {$fx + 10}] 19 -image $img -anchor nw -tags field
	set hint [dict get $v hint]
	set right [expr {$fx + $fw - 10}]
	if {$hint ne ""} {
		text::draw $C $right 27 f11 $c(MUTED) $hint e -tags field
		set right [expr {$right - [text::width f11 $hint] - 8}]
	}
	set x [expr {$fx + 33}]
	set pre [dict get $v pre]; set text [dict get $v text]; set ghost [dict get $v ghost]
	if {$pre ne ""} { text::draw $C $x 27 f13 $c(MUTED) $pre w -tags field }
	set x [expr {$x + [text::width f13 $pre] + 1}]
	set text [clip f13m $text [expr {$right - $x}]]
	if {$text ne ""} { text::draw $C $x 27 f13m $c(FG) $text w -tags field }
	set x [expr {$x + [text::width f13m $text]}]
	if {[dict get $v caret]} {
		set x [expr {round($x) + 1}]
		set cimg [lindex [raster::rrect 2 15 -fill $c(ACCENT) -radius 1 -offset {0 0.5}] 0]
		$C create image $x 19 -image $cimg -anchor nw -tags field
		incr x 2
	}
	set ghost [clip f13 $ghost [expr {$right - $x - 1}]]
	if {$ghost ne ""} { text::draw $C [expr {$x + 1}] 27 f13 $c(MUTED) $ghost w -tags field }
}

# Text cut to fit WIDTH (the field clips, like CSS overflow: hidden).
proc bar::clip {font text width} { text::clip $font $text $width }

# Mix two colours: a + (b - a) * t
proc bar::mix {a b t} {
	lassign [raster::rgb $a] r1 g1 b1; lassign [raster::rgb $b] r2 g2 b2
	format #%02X%02X%02X [expr {round($r1 + ($r2 - $r1) * $t)}] [expr {round($g1 + ($g2 - $g1) * $t)}] [expr {round($b1 + ($b2 - $b1) * $t)}]
}

# The window controls act on the window you're in.
proc bar::wctl {k b} {
	set f $wm::focus
	if {$b != 1 || $f eq ""} return
	switch $k {
		min { wm::send "minimize $f" }
		max { wm::send [expr {[wm::has $f max] ? "unmaximize" : "maximize"} ] $f }
		close { wm::send "close $f" }
	}
}

proc bar::motion {x y} {
	variable hits
	variable hover
	variable wshover
	variable pwhover
	set h ""
	set wh ""
	set ph 0
	foreach t $hits {
		lassign $t x0 y0 x1 y1 script
		if {$x < $x0 || $x >= $x1 || $y < $y0 || $y >= $y1} continue
		if {[lindex $script 0] eq "bar::wctl"} { set h [lindex $script 1] }
		if {[lindex $script 0] eq "bar::workspace"} { set wh [lindex $script 1] }
		if {[lindex $script 0] eq "panel::toggle" && [lindex $script 1] eq "session"} { set ph 1 }
	}
	if {$h ne $hover || $wh ne $wshover || $ph != $pwhover} { set hover $h; set wshover $wh; set pwhover $ph; draw }
}

proc bar::workspace {id b} { if {$b == 1} { wm::send "ws $id" } elseif {$b in {4 5}} { ws_scroll $b } }

# A button on the switcher's track, between or around its parts: scroll steps.
proc bar::ws_track {b} { if {$b in {4 5}} { ws_scroll $b } }

# Scroll on the switcher: previous / next workspace (wraps round).
proc bar::ws_scroll {b} {
	if {$b ni {4 5}} return
	set wss [wm::workspaces]
	if {![llength $wss]} return
	set i [lsearch -index 2 $wss 1]
	set j [expr {($i + ($b == 4 ? -1 : 1) + [llength $wss]) % [llength $wss]}]
	wm::send "ws [lindex $wss $j 0]"
}

# the chip opens the updates panel (updates.tcl)
proc status::updates_click {b} { if {$b == 1} { upd::toggle } }

# The workspace the shell last saw, for a restart (fault.tcl's state): written when it changes.
proc bar::remember_ws {wss} {
	variable wsaved
	if {![llength [info commands ::fault::save]]} return
	foreach w $wss {
		if {[lindex $w 2] && [lindex $w 0] ne $wsaved} {
			set wsaved [lindex $w 0]
			fault::save workspace $wsaved
		}
	}
}

# True when this shell is a restart within the same login: the first start of a login leaves a marker in
# $XDG_RUNTIME_DIR (cleared at logout), so a login never switches workspace or reopens a panel.
proc bar::session_restart {} {
	if {![info exists ::env(XDG_RUNTIME_DIR)] || $::env(XDG_RUNTIME_DIR) eq ""} { return 0 }
	set mark [file join $::env(XDG_RUNTIME_DIR) ribbon-shell.session]
	if {[file exists $mark]} { return 1 }
	catch {
		set fh [open $mark w]
		close $fh
	}
	return 0
}

# Restores the workspace and the panel the shell had open, once, after its first draw.
proc bar::restore {} {
	variable restore
	if {$restore eq {}} return
	set r $restore
	set restore {}
	set ws [dict get $r ws]
	if {$ws ne ""} {
		foreach w [wm::workspaces] {
			if {[lindex $w 0] eq $ws && ![lindex $w 2]} { wm::send "ws $ws" }
		}
	}
	set p [dict get $r panel]
	if {$p in {tray sound wifi bt power storage session}} { panel::show $p }
}
