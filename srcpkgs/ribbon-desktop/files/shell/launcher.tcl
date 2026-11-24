# launcher.tcl - the left bar's mode pill and field, the results under it
# and the mode menu.
#
# The field is one control with several jobs:
#   - on the empty desktop it types app names, holds them with a blinking
#     cursor, backspaces, rests blank, then types the next one;
#   - while an app has focus it shows where that app is: the folder in
#     Files, the page in the browser, the window title for anything else;
#   - click it (or press Super) to type: apps, files/paths or web.

namespace eval launcher {
	variable keytarget ""   ;# another taker of typed keys (the Wi-Fi password)
	variable editing 0
	variable mode app
	variable query ""
	variable sel 0
	variable menu 0
	variable results {}
	variable words {}
	variable anim {wi 0 len 0 phase type t 0}
	variable timer ""
	variable dropcanvas ""
	variable drophits {}
	variable menuhits {}
}

proc launcher::modes {} {
	return {app {Apps grid {Launch and switch apps}} files {Files folder {Find files, open folders by path}}
		web {Web globe {Search the web or open an address}}}
}

# Strip the app's name from a window title ("Page — Mozilla Firefox").
proc launcher::short_title {title label} {
	if {[regexp {^(.*\S)\s+[-—–]\s+([^-—–]+)$} $title -> head tail]} {
		set t [string tolower $tail]
		if {[string first [string tolower $label] $t] >= 0 || [regexp {mozilla|firefox|chrom|thunar|terminal} $t]} {
			return $head
		}
	}
	return $title
}

proc launcher::view {} {
	variable editing
	variable mode
	variable query
	variable menu
	variable anim
	variable words
	array set c [array get theme::c]
	set v [dict create menu $menu lead search leadcolour $c(MUTED) pre "" text "" \
		caret 0 ghost "" hint "" ring [list $c(BORDER) 1]]
	set m app
	if {$editing} {
		set m $mode
		dict set v ring [list $c(ACCENT) 1.5]
		dict set v caret 1
		switch $m {
			app { dict set v text $query }
			files {
				dict set v lead folder; dict set v leadcolour $c(ACCENT)
				if {[regexp {^[~/]} $query]} {
					set i [string last / $query]
					dict set v pre [string range $query 0 $i]
					dict set v text [string range $query [expr {$i + 1}] end]
					set g [apps::complete $query]
					dict set v ghost $g
					if {$g ne ""} { dict set v hint "Tab ↹" }
				} else {
					dict set v text $query
				}
			}
			web {
				dict set v text $query
				if {$query ne ""} { dict set v hint [expr {[apps::urlish $query] ? "↵ open" : "↵ search"}] }
			}
		}
	} elseif {$wm::focus eq ""} {
		if {![llength $words]} { set words [apps::idlewords] }
		set w [lindex $words [dict get $anim wi]]
		dict set v text [string range $w 0 [expr {[dict get $anim len] - 1}]]
		set ph [dict get $anim phase]
		dict set v caret [expr {$ph in {type erase} || ([dict get $anim t] / 8) % 2 == 0}]
	} else {
		set f $wm::focus
		set app [wm::get $f app]
		set label [apps::label $app]
		set title [short_title [wm::get $f title] $label]
		dict set v leadcolour $c(ACCENT)
		switch [apps::kind $app] {
			files {
				set m files
				dict set v lead folder
				# Ribbon Files tells us its folder directly
				if {[string match -nocase *ribbonfiles* $app] && [files::path] ne ""} { set title [files::path] }
				if {[regexp {^[~/]} $title]} {
					set p [apps::tilde $title]
					if {$p eq "~"} { dict set v text ~ } else {
						set i [string last / $p]
						dict set v pre [string range $p 0 $i]
						dict set v text [string range $p [expr {$i + 1}] end]
					}
				} else { dict set v text $title }
			}
			web { set m web; dict set v lead globe; dict set v text $title }
			default {
				dict set v lead [apps::iconfor [apps::forwindow $app] $app]
				dict set v text $label
				if {$title ne "" && ![string equal -nocase $title $label]} { dict set v ghost "  ·  $title" }
			}
		}
	}
	lassign [dict get [modes] $m] label icon
	dict set v modelabel $label
	dict set v modeicon $icon
	return $v
}

# ---- idle animation ----------------------------------------------------

# Run the 60 ms animation clock only while the idle text is on screen.
proc launcher::anim_sync {} {
	variable editing
	variable timer
	set want [expr {!$editing && $wm::focus eq ""}]
	if {$want && $timer eq ""} {
		set timer [after 60 launcher::tick]
	} elseif {!$want && $timer ne ""} {
		after cancel $timer; set timer ""
	}
}

# type 1 letter / 120 ms, hold 1.8 s (cursor blinks), erase 1 / 60 ms,
# blank 0.84 s (cursor blinks), next word.
proc launcher::tick {} {
	variable anim
	variable words
	variable timer
	set timer [after 60 launcher::tick]
	if {![llength $words]} { set words [apps::idlewords] }
	dict with anim {
		incr t
		set w [lindex $words $wi]
		set before [list $len $phase [expr {($t - 1) / 8 % 2}]]
		switch $phase {
			type { if {$t % 2 == 0} { incr len }
				if {$len >= [string length $w]} { set len [string length $w]; set phase hold; set t 0 } }
			hold { if {$t >= 30} { set phase erase; set t 0 } }
			erase { incr len -1; if {$len <= 0} { set len 0; set phase blank; set t 0 } }
			blank { if {$t >= 14} { set wi [expr {($wi + 1) % [llength $words]}]; set phase type; set t 0 } }
		}
		set after [list $len $phase [expr {$t / 8 % 2}]]
	}
	# redraw only when the text or the cursor actually changed
	if {$before ne $after} { bar::field_items }
}

# ---- editing -----------------------------------------------------------

proc launcher::field_click {b} {
	variable editing
	if {$b != 1} return
	if {!$editing} { start [default_mode] }
}

# Opening the field from an app starts in that app's mode.
proc launcher::default_mode {} {
	if {$wm::focus ne ""} {
		set k [apps::kind [wm::get $wm::focus app]]
		if {$k in {files web}} { return $k }
	}
	return app
}

proc launcher::start {{m app}} {
	variable editing
	variable mode
	variable query
	variable sel
	variable menu
	panel::close
	set editing 1; set mode $m; set query ""; set sel 0; set menu 0
	# in Ribbon Files the field is the address bar: start from its folder
	if {$m eq "files" && [files_focused]} {
		set query [apps::tilde [files::path]]
		if {$query ne "/"} { append query / }
	}
	menu_hide
	input_show
	update_results
	shell::refresh
}

# Is the window in use a Ribbon Files window?
proc launcher::files_focused {} {
	expr {$wm::focus ne "" && [string match -nocase *ribbonfiles* [wm::get $wm::focus app]] && [files::path] ne ""}
}

# Ctrl+L / F6 in Ribbon Files: edit the address in the top bar.
proc launcher::address {} {
	variable editing
	if {!$editing} { start files }
}

proc launcher::toggle {{m ""}} {
	variable editing
	if {$editing} { cancel; return }
	start [expr {$m eq "" ? [default_mode] : $m}]
}

proc launcher::cancel {} {
	variable editing
	variable query
	variable menu
	if {!$editing && !$menu} return
	set editing 0; set query ""; set menu 0
	drop_hide; menu_hide; input_hide
	# hand the keyboard back to the window the user was in
	if {$wm::focus ne ""} { wm::send "activate $wm::focus" }
	shell::refresh
}

proc launcher::key {sym char state} {
	variable keytarget
	if {$keytarget ne ""} { {*}$keytarget $sym $char $state; return }
	variable editing
	variable mode
	variable query
	variable sel
	variable results
	variable menu
	if {!$editing} {
		if {$menu && $sym eq "Escape"} { cancel }
		return
	}
	set ctrl [expr {$state & 4}]
	switch -- $sym {
		Escape { cancel; return }
		Return - KP_Enter {
			if {($state & 8) && [lindex $results $sel 0] eq "app"} { properties $sel; return }
			activate; return
		}
		Tab - ISO_Left_Tab {
			if {$mode eq "files" && [regexp {^[~/]} $query] && [set g [apps::complete $query]] ne ""} {
				append query $g
			} else {
				set order {app files web}
				set mode [lindex $order [expr {([lsearch $order $mode] + 1) % 3}]]
			}
		}
		BackSpace { if {$ctrl} { set query [regsub {\S*\s*$} $query ""] } else { set query [string range $query 0 end-1] } }
		Up { if {$sel > 0} { incr sel -1 }; drop_draw; return }
		Down { if {$sel < [llength $results] - 1} { incr sel }; drop_draw; return }
		default {
			if {$ctrl && $sym eq "u"} { set query "" } elseif {$char ne "" && !$ctrl && [string is print $char]} {
				append query $char
				# a path or an address switches the mode by itself
				if {$mode eq "app" && [string length $query] == 1 && $query in {/ ~}} { set mode files }
				if {$mode eq "app" && [apps::urlish $query] && [regexp {[./:]} $query] && ![llength [apps::search $query]]} { set mode web }
			} else return
		}
	}
	set sel 0
	update_results
	bar::draw
}

proc launcher::update_results {} {
	variable mode
	variable query
	variable results
	variable editing
	set results {}
	if {$editing && $query ne ""} {
		switch $mode {
			app { foreach a [lrange [apps::search $query] 0 5] { lappend results [list app $a] } }
			files {
				if {![regexp {^[~/]} $query]} {
					foreach f [apps::findfiles $query] { lappend results [list file $f] }
					# the index fills in the background; look again shortly
					if {[llength $apps::fileswalk]} { after 300 launcher::refresh_files }
				}
			}
		}
	}
	drop_draw
}

proc launcher::refresh_files {} {
	variable mode
	variable editing
	if {$editing && $mode eq "files"} { update_results }
}

proc launcher::activate {{i ""}} {
	variable mode
	variable query
	variable sel
	variable results
	if {$i eq ""} { set i $sel }
	set r [lindex $results $i]
	switch $mode {
		app { if {$r ne ""} { apps::launch [lindex $r 1] } else return }
		files {
			if {$r ne ""} {
				set p [lindex $r 1 1]
				if {[file isdirectory $p]} { apps::open_path $p } else { apps::reveal $p }
			} elseif {$query ne ""} { apps::open_path $query } else return
		}
		web { apps::open_web $query }
	}
	set ::launcher::editing 0; set query ""
	drop_hide; menu_hide; input_hide
	# back to the window you were in (Ribbon Files has just moved)
	if {$wm::focus ne ""} { wm::send "activate $wm::focus" }
	shell::refresh
}

proc launcher::input_show {} {
	# see-through, and clicks pass through it
	rbn::show .in $bar::X0 [expr {$bar::Y0 + 54}] 1 1 -shape {{0 0 0 0}} -input {{0 0 0 0}}
	focus -force .in
}

proc launcher::input_hide { } { if {[winfo ismapped .in]} { wm withdraw .in } }

# ---- results under the field -------------------------------------------

# A panel that hangs from the left bar: one shape with it (square top, no
# shadow there), see-through around its rounded bottom (rbnalpha).
proc launcher::popup {w} {
	if {[winfo exists $w]} return
	rbn::surface $w -fill $theme::c(BAR)
}

proc launcher::drop_hide {} { rbn::hide .drop }

# The main display moved (display.tcl): what hangs from the left bar goes with it, once the bars have taken their
# new place (bar::moved, a listener too, may run after this one). It is taken off the screen first and shown again
# there: Tk puts a mapped override-redirect window back where it was when it is raised before the move is made.
proc launcher::moved {} {
	drop_hide
	menu_hide
	after idle launcher::follow
}
proc launcher::follow {} {
	switch -- [panel] {
		drop { drop_draw }
		menu { menu_draw }
	}
}
display::on_change launcher::moved

# What hangs from the left bar right now: "drop" (results), "menu" or "".
proc launcher::panel {} {
	variable editing
	variable mode
	variable results
	variable menu
	if {$menu} { return menu }
	if {$editing && [llength $results] && $mode ne "web"} { return drop }
	return ""
}

proc launcher::drop_draw {} {
	variable editing
	variable mode
	variable query
	variable sel
	variable results
	variable drophits
	array set c [array get theme::c]
	set n [llength $results]
	if {!$editing || $n == 0 || $mode eq "web"} { drop_hide; return }
	popup .drop
	set h [expr {round(81.62 + 54 * $n)}]
	set d .drop.c
	$d delete all
	$d configure -background $c(BAR)
	set drophits {}
	set rows {}
	for {set i 0} {$i < $n} {incr i} {
		set y [expr {round(37.31 + 54 * $i)}]
		set isel [expr {$i == $sel}]
		if {$isel} { rbn::box $d 8 $y 444 52 -fill $c(FIELD) -radius 9 -on $c(BAR) }
		rbn::box $d 18 [expr {$y + 9}] 34 34 -fill [expr {$isel ? $c(ACCENT) : $c(PILL)}] -radius 9 -on [expr {$isel ? $c(FIELD) : $c(BAR)}]
		lappend rows [list $i $y $isel]
		lappend drophits [list 8 $y 452 [expr {$y + 52}] $i]
	}
	set fy [expr {round(43.31 + 54 * $n)}]
	$d create rectangle 8 $fy 452 [expr {$fy + 1}] -fill $c(BORDER) -width 0
	set fc [expr {$fy + 1 + 10 + 7.655}]
	# footer keys
	set x 18
	set keys {}
	foreach {k label} {Tab "apps, files, web" ↵ open Esc close} {
		set kw [expr {round(6 + [text::width f11 $k] + 6)}]
		rbn::box $d $x [expr {round($fc - 7.655)}] $kw 15 -fill $c(BAR) -radius 5 -ring [list $c(BORDER) 1] -on $c(BAR)
		lappend keys [list $x $kw $k $label]
		set x [expr {round($x + $kw + 6 + [text::width f11 $label] + ($k eq "Esc" ? 0 : 10) + 6)}]
	}
	# the selected row's return key
	if {$sel < $n} {
		set sy [expr {round(37.31 + 54 * $sel)}]
		set kw [expr {round(7 + [text::width f11 ↵] + 7)}]
		rbn::box $d [expr {442 - $kw}] [expr {$sy + 26 - 9}] $kw 17 -fill $c(BAR) -radius 5 -ring [list $c(BORDER) 1] -on $c(FIELD)
	}

	# header
	set hy 20.66
	bar::spaced $d 18 $hy f11s $c(MUTED) [expr {$mode eq "files" ? "FILES" : "APPS"}] 0.88
	text::draw $d 442 $hy f11 $c(MUTED) "$n result[expr {$n == 1 ? "" : "s"}]" e
	foreach r $rows {
		lassign $r i y isel
		set it [lindex $results $i]
		if {[lindex $it 0] eq "app"} {
			set a [lindex $it 1]
			set name [dict get $a name]; set desc [apps::desc $a]; set ic [apps::iconfor $a [dict get $a id]]
		} else {
			lassign [lindex $it 1] lname path isdir
			set name [file tail $path]; set desc [apps::tilde [file dirname $path]]; set ic [expr {$isdir ? "folder" : "file"}]
		}
		bar::icon $d $ic 18 1.8 [expr {$isel ? $c(ON_ACCENT) : $c(ACCENT)}] 26 [expr {$y + 17}]
		set top [expr {$y + 9.875}]
		set right [expr {$isel ? 442 - 22 - 12 : 442}]
		text::draw $d 64 [expr {round($top + 7.87 + 0.5)}] f13s $c(FG) [bar::clip f13s $name [expr {$right - 64}]] w
		text::draw $d 64 [expr {round($top + 15.73 + 2 + 7.26 + 0.5)}] f12 $c(MUTED) [bar::clip f12 $desc [expr {$right - 64}]] w
		if {$isel} {
			set kw [expr {round(7 + [text::width f11 ↵] + 7)}]
			text::draw $d [expr {442 - $kw / 2.0}] [expr {$y + 26}] f11 $c(MUTED) ↵ center
		}
	}
	foreach k $keys {
		lassign $k x kw key label
		text::draw $d [expr {$x + 6}] [expr {round($fc + 0.5)}] f11 $c(FG) $key w
		text::draw $d [expr {$x + $kw + 6}] [expr {round($fc + 0.5)}] f11 $c(MUTED) $label w
	}
	bind $d <Button-1> {launcher::drop_click %x %y}
	bind $d <Button-3> {launcher::drop_menu %x %y %X %Y}
	bind $d <Motion> {launcher::drop_hover %x %y}
	# square top: it continues the left bar, which grows down to meet it
	rbn::popup .drop [expr {$bar::X0 + 8}] [expr {$bar::Y0 + 54}] 460 $h [theme::look pop -radius {0 0 12 12} -ring [list $c(BORDER) 1 lrb]] -clip t
}

proc launcher::drop_at {x y} {
	variable drophits
	foreach h $drophits {
		lassign $h x0 y0 x1 y1 i
		if {$x >= $x0 && $x < $x1 && $y >= $y0 && $y < $y1} { return $i }
	}
	return ""
}

proc launcher::drop_click {x y} {
	set i [drop_at $x $y]
	if {$i ne ""} { activate $i }
}

# Right-click on a result: open it, or its Properties.
proc launcher::drop_menu {x y X Y} {
	variable results
	set i [drop_at $x $y]
	if {$i eq ""} return
	files::popup_menu .drop $X $Y [list [list right Open [list launcher::activate $i] ↵] \
		[list info Properties [list launcher::properties $i] Alt+↵]]
}

# Properties of a result (an app by its launcher entry, or a file).
proc launcher::properties {i} {
	variable results
	set r [lindex $results $i]
	if {[lindex $r 0] eq "app"} { apps::app_properties [lindex $r 1] } else { apps::properties [lindex $r 1 1] }
	cancel
}

proc launcher::drop_hover {x y} {
	variable sel
	set i [drop_at $x $y]
	if {$i ne "" && $i != $sel} { set sel $i; drop_draw }
}

# ---- the mode menu (click the pill) --------------------------------------

proc launcher::menu_toggle {b} {
	variable menu
	if {$b != 1} return
	if {$menu} { set menu 0; menu_hide } else { set menu 1; drop_hide; menu_draw }
	bar::draw
}

proc launcher::menu_hide {} { rbn::hide .menu }

proc launcher::menu_draw {} {
	variable mode
	variable editing
	variable menuhits
	array set c [array get theme::c]
	popup .menu
	set d .menu.c
	$d delete all
	set mw $bar::leftw
	set cur [expr {$editing ? $mode : [dict get [launcher::view] modelabel]}]
	set menuhits {}
	set i 0
	set items {}
	foreach {key spec} [modes] {
		lassign $spec label icon desc
		set y [expr {round(6 + $i * 52.25)}]
		set on [expr {$key eq $cur || $label eq $cur}]
		if {$on} { rbn::box $d 6 $y [expr {$mw - 12}] 50 -fill $c(FIELD) -radius 8 -on $c(BAR) }
		rbn::box $d 16 [expr {$y + 9}] 30 30 -fill $c(PILL) -radius 8 -on [expr {$on ? $c(FIELD) : $c(BAR)}]
		lappend items [list $y $label $icon $desc]
		lappend menuhits [list 6 $y [expr {$mw - 6}] [expr {$y + 50}] $key]
		incr i
	}
	foreach it $items {
		lassign $it y label icon desc
		bar::icon $d $icon 16 1.9 $c(ACCENT) 23 [expr {$y + 16}]
		text::draw $d 58 [expr {round($y + 9 + 7.87)}] f13s $c(FG) $label w
		text::draw $d 58 [expr {round($y + 9 + 15.73 + 2 + 7.26)}] f12 $c(MUTED) $desc w
	}
	bind $d <Button-1> {launcher::menu_click %x %y}
	rbn::popup .menu [expr {$bar::X0 + 8}] [expr {$bar::Y0 + 54}] $mw 167 [theme::look pop -radius {0 0 12 12} -ring [list $c(BORDER) 1 lrb]] -clip t
}

proc launcher::menu_click {x y} {
	variable menuhits
	variable menu
	foreach h $menuhits {
		lassign $h x0 y0 x1 y1 key
		if {$x >= $x0 && $x < $x1 && $y >= $y0 && $y < $y1} {
			set menu 0
			menu_hide
			start $key
			return
		}
	}
}
