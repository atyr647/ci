# pages.tcl - the Properties window: what it shows (an app's kit, a file,
# a folder), the frame (the Appearance window's: the rail with the thing's
# identity on top, the page, the footer), the open menu, kit's prompt as a
# sheet, and keys. The pages are apppages.tcl and filepages.tcl.
#
# Positions are the boards' (design/mockups/Props-A*.dc.html) inside the
# 1100 x 720 window: the rail is 230 wide, its pages start at y 96 (under
# the 44 px tile), the page's content starts at x 270, y 119 and ends at
# x 1060, the footer is the bottom 72 px.

namespace eval page {
	variable S
	array set S {kind "" page "" busy 0 title "" sub "" icon "" picture ""}
	variable K {}          ;# an app's facts (kitlink.tcl)
	variable F {}          ;# a file's or folder's facts (facts.tcl)
	variable pages {}      ;# {key icon label} in the rail
	variable dialog ""
	variable WH 720        ;# the window's height: 720, 600 for an app that isn't a kit (Props-A9-NotKit)
	variable menu {}       ;# the open dropdown's menu (widgets.tcl)
	variable menu_hover -1
	variable TOP 119
	variable theme_mtime ""
}

proc page::chrome {} {
	array set p [array get theme::c]
	ui::colours [dict create BAR $p(BAR) FIELD $p(FIELD) PILL $p(PILL) BORDER $p(BORDER) FG $p(FG) MUTED $p(MUTED) \
		ACCENT $p(ACCENT) ON_ACCENT $p(ON_ACCENT) DESK_TOP $p(DESK_TOP) DESK_BOTTOM $p(DESK_BOTTOM) \
		DESK_STRIPE $p(DESK_STRIPE) DESK_STRIPE_ALPHA $p(DESK_STRIPE_ALPHA)]
}

# It follows the active theme: when ribbon-theme writes a new palette the
# window redraws in it.
proc page::palette_file {} {
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/"}]
	set cfg [expr {[info exists ::env(XDG_CONFIG_HOME)] ? $::env(XDG_CONFIG_HOME) : "$home/.config"}]
	file join $cfg ribbon palette.conf
}
proc page::watch_theme {} {
	variable theme_mtime
	set m [expr {[catch {file mtime [palette_file]} t] ? "" : $t}]
	if {$theme_mtime ne "" && $m ne $theme_mtime} { retheme }
	set theme_mtime $m
	after 2000 page::watch_theme
}
proc page::retheme {} {
	theme::load
	chrome
	draw
}

# ---- what is shown ---------------------------------------------------------------------

# KIND path (a file, a folder or a .kit), app (a launcher entry) or kit.
proc page::open {kind what} {
	variable S
	switch -- $kind {
		path {
			if {![file exists $what] && [file type $what] ne "link"} { error "$what: no such file or folder" }
			# a .kit kit can't read here is shown as the file it is
			if {[string match -nocase *.kit $what] && [file isfile $what] && ![catch {kitlink::kitfile $what} K]} {
				open_app $K
			} else { open_file $what }
		}
		app {
			set e [desktop_entry $what]
			if {$e eq ""} { error "there is no app $what" }
			set name [kitlink::for_exec [expr {[dict exists $e Exec] ? [dict get $e Exec] : ""}]]
			if {$name eq "" || [catch {kitlink::installed $name} K] || $K eq ""} { set K [app_only $e] }
			open_app $K
		}
		kit {
			if {[catch {kitlink::installed $what} K] || $K eq ""} { error "$what is not installed" }
			open_app $K
		}
	}
}

# A launcher entry by id (firefox, firefox.desktop) or path.
proc page::desktop_entry {what} {
	if {[file isfile $what]} {
		set fh [::open $what]; fconfigure $fh -encoding utf-8
		set e [facts::desktop_parse [read $fh]]; close $fh
		dict set e file $what
		return $e
	}
	set id [expr {[string match *.desktop $what] ? $what : "$what.desktop"}]
	set apps [facts::apps]
	if {[dict exists $apps $id]} { return [dict get $apps $id] }
	foreach {k e} $apps { if {[string equal -nocase $k $id]} { return $e } }
	return ""
}

# An app that isn't a kit (installed with the system): what its launcher
# entry says, and no kit actions.
proc page::app_only {e} {
	set K [kitlink::empty]
	dict set K title [dict get $e Name]
	dict set K kind [expr {[dict exists $e GenericName] ? [dict get $e GenericName] : ([dict exists $e Comment] ? [dict get $e Comment] : "")}]
	dict set K cats [expr {[dict exists $e Categories] ? [dict get $e Categories] : ""}]
	dict set K source System
	dict set K notkit 1
	dict set K desktop [expr {[dict exists $e file] ? [dict get $e file] : ""}]
	dict set K entry $e
	return $K
}

proc page::open_app {k} {
	variable S
	variable K $k
	variable pages
	variable WH
	set S(kind) app
	if {![dict exists $K notkit]} { dict set K notkit 0 }
	set WH [expr {[dict get $K notkit] ? 600 : 720}]
	set ui::H $WH
	if {[dict get $K indexage] eq ""} { dict set K indexage [kitlink::index_age] }
	set S(icon) [facts::app_icon_for [dict get $K title] [dict get $K cats] [dict get $K name]]
	set S(picture) ""
	set S(title) [dict get $K title]
	set S(sub) [dict get $K kind]
	if {[dict get $K notkit]} {
		set pages {overview info Overview}
	} elseif {![dict get $K installed]} {
		# a .kit that isn't installed has nothing on disk yet (Props-A8-KitFile)
		set pages {overview info Overview permissions shield Permissions libraries layers Libraries signature key Signature}
	} else {
		set pages {overview info Overview permissions shield Permissions storage disk Storage libraries layers Libraries signature key Signature}
	}
	ap::start
	set S(page) overview
}

proc page::open_file {path} {
	variable S
	variable F [facts::of $path]
	variable pages
	set S(kind) [expr {[dict get $F isdir] ? "folder" : "file"}]
	set S(title) [file rootname [dict get $F name]]
	if {[dict get $F isdir]} { set S(title) [dict get $F name] }
	set S(sub) [dict get $F typename]
	set S(icon) [expr {[dict get $F isdir] ? "folder" : [kindicon [dict get $F mime]]}]
	set S(picture) ""
	# one page: the Rail's Photo and Contents pages were ruled out (files have the
	# standalone window, FileProps-Win2-*)
	if {![dict get $F isdir] && [string match image/* [dict get $F mime]]} { set S(picture) [dict get $F path] }
	set pages {general info General}
	fp::start
	set S(page) general
}

proc page::kindicon {m} {
	switch -glob -- $m {
		image/* { return image } audio/* { return music } video/* { return film }
		text/* { return file } application/x-ribbon-kit { return pkg }
		default { return file }
	}
}

proc page::keys {} {
	variable pages
	lmap {k i l} $pages { set k }
}

proc page::go {p} {
	variable S
	if {$p ni [keys]} return
	set S(page) $p
	set ui::focus ""
	menu_close 0
	draw
}

proc page::quit {} { exit 0 }

# ---- drawing --------------------------------------------------------------------------------

proc page::draw {} {
	variable pending
	if {[info exists pending] && $pending ne ""} return
	set pending [after idle page::draw_now]
}

proc page::draw_now {} {
	variable pending ""
	variable WH
	variable S
	variable dialog
	variable menu
	# a sheet dims the window 50 % (STYLE §15), a dialog 35 %
	set ui::dim [expr {$dialog eq "" ? 0 : ([dict get $dialog kind] eq "plan" ? 0.5 : 0.35)}]
	ui::begin frame$WH page::frame_boxes
	frame
	draw_$S(page)
	if {[dict size $menu] && $dialog eq ""} { w::menu_draw $menu }
	ui::focus_ring
	if {$dialog ne ""} {
		set ui::dim 0
		if {[dict get $dialog kind] eq "plan"} { sheet_draw } else { dlg::draw }
	}
	ui::finish
}

# The window, the rail and the footer's line (once per palette).
proc page::frame_boxes {} {
	variable WH
	array set c [array get ui::c]
	ui::box 0 0 1100 $WH -fill $c(bar) -radius [ui::outer_radius 16] -ring [list $c(border) 1]
	ui::box 0 0 230 $WH -fill $c(d2) -radius [ui::outer_radius {16 0 0 16}]
	ui::box 229 0 1 $WH -fill $c(border)
	ui::hline 230 1100 [expr {$WH - 72}] $c(border)
}

# The rail: the thing's tile, name and kind, then its pages.
proc page::frame {} {
	variable S
	variable pages
	array set c [array get ui::c]
	if {$S(picture) eq "" || ![w::picture 24 26 44 44 $S(picture) 12]} { w::tile 24 26 $S(icon) }
	ui::text 80 26 [clip sg20 $S(title) 126 -0.4] sg20 $c(fg) w -0.4
	ui::text 80 53 [clip i12 $S(sub) 126] i12 $c(muted)
	set k 0
	foreach {key ic label} $pages {
		set y [expr {96 + 44 * $k}]
		set on [expr {$S(page) eq $key}]
		if {$on} {
			ui::box 16 $y 198 40 -fill $c(field) -radius 10
			ui::box 16 [expr {$y + 10}] 3 20 -fill $c(accent) -radius 2
		}
		ui::icon $ic 16 [expr {$on ? $c(accent) : $c(muted)}] 28 [expr {$y + 12}]
		ui::text 56 [expr {$y + 12}] $label [expr {$on ? "i13s" : "i13m"}] [expr {$on ? $c(fg) : $c(muted)}]
		ui::hit 16 $y 198 40 [list apply {{k x y} { page::go $k }} $key]
		incr k
	}
	ui::focusable rail list 16 [expr {96 + 44 * [lsearch -exact [keys] $S(page)]}] 198 40 10 page::rail_key
}

# STR cut with an ellipsis to fit W.
proc page::clip {f str w {ls 0}} {
	if {[ui::measure $f $str $ls] <= $w} { return $str }
	while {$str ne "" && [ui::measure $f "$str…" $ls] > $w} { set str [string range $str 0 end-1] }
	return "[string trimright $str]…"
}

proc page::rail_key {sym} {
	set keys [keys]
	set i [lsearch -exact $keys $page::S(page)]
	switch -- $sym {
		Up { set i [expr {max(0, $i - 1)}] }
		Down { set i [expr {min([llength $keys] - 1, $i + 1)}] }
		default { return 0 }
	}
	go [lindex $keys $i]
	set ui::focus rail
	return 1
}

# Title and subtitle.
proc page::head {title sub} {
	array set c [array get ui::c]
	ui::text 270 34 $title sg28 $c(fg) w -0.56
	ui::text 270 [ui::lh 76 i14 21 1] [clip i14 $sub 790] i14 $c(muted)
}

# The footer: LEFT {ghost button} or {text ...} at x 270, BUTTONS {id label
# kind script icon} from the right.
proc page::footer {buttons {left ""}} {
	variable S
	variable WH
	array set c [array get ui::c]
	set by [expr {$WH - 55}]
	switch -- [lindex $left 0] {
		button {
			lassign [lindex $left 1] id label kind script icon
			ui::button $id 270 $by $label $kind [busy_guard $script] $icon
		}
		text { ui::text 270 [expr {$WH - 44}] [lindex $left 1] i13 $c(muted) }
	}
	set x 1060
	foreach b $buttons {
		lassign $b id label kind script icon
		set w [ui::button_w $label $kind $icon]
		set x [expr {$x - $w}]
		ui::button $id $x $by $label $kind [busy_guard $script] $icon $w
		set x [expr {$x - 10}]
	}
}
proc page::busy_guard {script} { list apply {{s} { if {!$::page::S(busy)} { uplevel #0 $s } }} $script }

# ---- the dropdowns' menu ---------------------------------------------------------------------------

proc page::menu_toggle {m} {
	variable menu
	variable menu_hover
	if {[dict size $menu] && [dict get $menu id] eq [dict get $m id]} { menu_close; return }
	set menu $m
	set menu_hover -1
	set ui::focus [dict get $m id]
	draw
}
proc page::menu_close {{redraw 1}} {
	variable menu
	if {![dict size $menu]} return
	set menu {}
	if {$redraw} draw
}
proc page::menu_pick {m key} {
	menu_close 0
	uplevel #0 [list {*}[dict get $m script] $key]
	draw
}
proc page::menu_motion {x y} {
	variable menu
	variable menu_hover
	if {![dict size $menu]} return
	set x [expr {$x - $ui::ox}]; set y [expr {$y - $ui::oy}]
	set n [llength [dict get $menu items]]
	set h [expr {12 + 32 * $n}]
	set my [dict get $menu y]
	if {$my + $h > $::page::WH - 8} { set my [expr {[dict get $menu top] - 8 - $h}] }
	set i [expr {$y >= $my + 6 && $y < $my + 6 + 32 * $n && $x < [dict get $menu x] && $x > [dict get $menu x] - 300 ? int(($y - $my - 6) / 32) : -1}]
	if {$i != $menu_hover} { set menu_hover $i; draw }
}
proc page::menu_key {sym} {
	variable menu
	variable menu_hover
	set n [llength [dict get $menu items]]
	switch -- $sym {
		Escape { menu_close; return 1 }
		Up { set menu_hover [expr {max(0, $menu_hover - 1)}] }
		Down { set menu_hover [expr {min($n - 1, $menu_hover + 1)}] }
		Return - KP_Enter - space { if {$menu_hover >= 0} { menu_pick $menu [lindex [dict get $menu items] $menu_hover 0] }; return 1 }
		default { return 0 }
	}
	draw
	return 1
}

# ---- kit's prompt, as a sheet --------------------------------------------------------------------
# Kit-Sheet-1..4 (STYLE §15 "Sheet"): kit's plan and its question over the window that asked, under a
# 50 % scrim. The header is the app's tile, name and the file or kit it is about; one 48 px row per
# kit (the app's own icon on its row, the box icon on any other), the versions, the size and the
# tags; Uninstall's data questions as checkboxes; a footer with what it downloads or frees, Cancel,
# and kit's question word for word on the primary button. kitlink::renderer calls plan_sheet and
# waits for kitlink::answer; Uninstall (ap::uninstall) passes OPTS: data (the checkboxes: dicts
# name q on) and done (called with the answer and the checkboxes instead of setting the answer).

proc page::plan_sheet {rows question default {opts {}}} {
	variable dialog
	variable sheetoff 0
	set dialog [dict merge [dict create data {} done ""] $opts [dict create kind plan rows $rows question $question default $default]]
	set ui::focus [expr {$default ? "pyes" : "pno"}]
	. configure -cursor {}
	draw
}
proc page::sheet_answer {a} {
	variable dialog
	set done [dict get $dialog done]
	set data [dict get $dialog data]
	set dialog ""
	set ui::focus ""
	if {$done ne ""} {
		draw
		uplevel #0 [list {*}$done $a $data]
		return
	}
	. configure -cursor watch
	draw
	update idletasks
	set kitlink::answer $a
}
# The data checkbox I: on or off (ARGS: where a click was).
proc page::sheet_check {i args} {
	variable dialog
	set d [dict get $dialog data]
	set e [lindex $d $i]
	dict set e on [expr {![dict get $e on]}]
	dict set dialog data [lreplace $d $i $i $e]
	draw
}

# The sheet's facts, without drawing: its width, height, the footer's words and each row's size.
# The size column says "from file" on the row of a .kit opened from a file (it is not downloaded).
proc page::sheet_plan {dialog} {
	variable K
	set rows [dict get $dialog rows]
	set data [dict get $dialog data]
	set file [expr {[info exists K] && [dict exists $K file] && [dict get $K file] ne "" ? [dict get $K file] : ""}]
	set remove 0; set down 0; set freed 0; set sizes {}
	foreach r $rows {
		set b [dict get $r bytes]
		if {![string is wide -strict $b]} { set b 0 }
		if {[dict get $r action] eq "remove"} {
			set remove 1; incr freed $b
			lappend sizes [expr {$b > 0 ? [kitlink::fmtsize $b] : ""}]
		} elseif {$file ne "" && [dict get $r fullname] eq [dict get $K name] && [dict get $r new] eq [dict get $K version]} {
			lappend sizes "from file"
		} else {
			incr down $b
			lappend sizes [expr {$b > 0 ? [kitlink::fmtsize $b] : ""}]
		}
	}
	if {$remove} { set foot "Frees [kitlink::fmtsize $freed]" } elseif {$down > 0} { set foot "Download [kitlink::fmtsize $down]" } else { set foot "No download" }
	# 700 wide when it asks about data (Kit-Sheet-3), else 640
	set w [expr {[llength $data] ? 700 : 640}]
	# the rows that fit: the sheet stops 40 px short of the window's edges, and more rows scroll (Kit-Sheet-5-Long)
	set dh [expr {[llength $data] ? 14 + 60 * [llength $data] - 8 + 22 : 0}]
	set fit [expr {max(1, ($::page::WH - 80 - 88 - 72 - $dh) / 48)}]
	set shown [expr {min($fit, [llength $rows])}]
	set h [expr {88 + 48 * $shown + $dh + 72}]
	dict create w $w h $h foot $foot sizes $sizes tags [expr {[llength [concat {*}[lmap r $rows { dict get $r tags }]]] > 0}] \
		fit $fit shown $shown
}

# Scroll the sheet's rows by D (wheel: one row; Page Up/Down: a sheet's worth), within 0..MAX.
proc page::sheet_scroll {max d} {
	variable sheetoff
	set o [expr {max(0, min($max, $sheetoff + $d))}]
	if {$o != $sheetoff} { set sheetoff $o; draw }
}
proc page::sheet_key {max fit sym} {
	switch -- $sym {
		Up { sheet_scroll $max -1 } Down { sheet_scroll $max 1 }
		Prior { sheet_scroll $max -$fit } Next { sheet_scroll $max $fit }
		Home { sheet_scroll $max -$max } End { sheet_scroll $max $max }
		default { return 0 }
	}
	return 1
}

# The primary button with kit's question: "(takes effect at restart)" in a lighter weight (500, 72 %).
proc page::sheet_button {x y q} {
	array set c [array get ui::c]
	set tail " (takes effect at restart)"
	set head $q; set rest ""
	if {[string match "*$tail" $q]} { set head [string range $q 0 end-[string length $tail]]; set rest [string trimleft $tail] }
	set w [expr {36 + [ui::measure i14s $head] + ($rest ne "" ? 6 + [ui::measure i14m $rest] : 0)}]
	set x [expr {$x - $w}]
	ui::box $x $y $w 38 -fill $c(accent) -radius 10
	set tw [ui::text [expr {$x + 18}] [expr {$y + 10.5}] $head i14s $c(ink)]
	if {$rest ne ""} { ui::text [expr {$x + 24 + $tw}] [expr {$y + 10.5}] $rest i14m [ui::mix $c(ink) $c(accent) 0.72] }
	ui::hit $x $y $w 38 {apply {{x y} { page::sheet_answer 1 }}}
	ui::focusable pyes button $x $y $w 38 10 {page::sheet_answer 1}
	return $x
}

proc page::sheet_draw {} {
	variable dialog
	variable S
	variable K
	array set c [array get ui::c]
	set ui::hits {}; set ui::wheels {}; set ui::focusables {}
	ui::layer
	set rows [dict get $dialog rows]
	set data [dict get $dialog data]
	set P [sheet_plan $dialog]
	set w [dict get $P w]; set h [dict get $P h]
	set x [expr {(1100 - $w) / 2}]; set y [expr {($::page::WH - $h) / 2}]
	raster::box $ui::img $x $y $w $h -fill [ui::col $c(bar)] -radius 16 -ring [list [ui::col $c(border)] 1] -shadow {24 64 0.6}
	ui::hit $x $y $w $h ""
	set L [expr {$x + 28}]; set R [expr {$x + $w - 28}]
	# the header: the app's tile, its name, and the .kit file or the kit's short name
	w::tile $L [expr {$y + 26}] $S(icon)
	set sub [expr {[info exists K] && [dict get $K file] ne "" && ![dict get $K installed] ? [file tail [dict get $K file]] : [dict get $K short]}]
	ui::text [expr {$L + 58}] [expr {$y + 25}] [clip sg20 $S(title) [expr {$R - $L - 58}] -0.4] sg20 $c(fg) w -0.4
	ui::text [expr {$L + 58}] [expr {$y + 53}] [clip i13 $sub [expr {$R - $L - 58}]] i13 $c(muted) w 0 {} 1
	ui::hline $L $R [expr {$y + 88}] $c(border)
	# the rows: name | versions (164) | size (64) | tags (128, when a row has one), 16 apart
	set tagw [expr {[dict get $P tags] ? 128 : 0}]
	set sizer [expr {$R - ($tagw ? $tagw + 16 : 0)}]
	set verx [expr {$sizer - 64 - 16 - 164}]
	set ry [expr {$y + 88}]
	# the rows shown: from the scroll offset, as many as fit
	variable sheetoff
	set fit [dict get $P fit]
	set max [expr {max(0, [llength $rows] - $fit)}]
	set sheetoff [expr {min($sheetoff, $max)}]
	set last [expr {$sheetoff + [dict get $P shown] - 1}]
	set shown [lrange $rows $sheetoff $last]
	if {$max} {
		set area [expr {48 * $fit}]
		# a thin thumb in the margin right of the rows, as long as the share of rows shown
		set th [expr {max(32, $area * $fit / [llength $rows])}]
		set ty [expr {$ry + ($area - $th) * $sheetoff / $max}]
		ui::box [expr {$R + 14}] [expr {$ty + 4}] 4 [expr {$th - 8}] -fill [ui::mix $c(muted) $c(bar) 0.4] -radius 2
		ui::wheel $L $ry [expr {$R - $L}] $area [list page::sheet_scroll $max]
		ui::focusable plist list $L $ry [expr {$R - $L}] $area 8 [list page::sheet_key $max $fit]
	}
	set n 0
	foreach r $shown size [lrange [dict get $P sizes] $sheetoff $last] {
		set own [expr {[info exists K] && [dict get $r fullname] eq [dict get $K name]}]
		w::tile $L [expr {$ry + 10}] [expr {$own ? $S(icon) : "box"}] 28 15 8
		ui::text [expr {$L + 40}] [expr {$ry + 16}] [clip i13s [dict get $r name] [expr {$verx - 16 - $L - 40}]] i13s $c(fg)
		set vx $verx
		switch -- [dict get $r action] {
			install {
				set vx [expr {$vx + [ui::text $vx [expr {$ry + 16}] new i13 $c(muted) w 0 {} 1] + 8}]
				ui::text $vx [expr {$ry + 16}] [dict get $r new] i13 $c(fg) w 0 {} 1
			}
			default {
				set gone [expr {[dict get $r action] eq "remove"}]
				set vx [expr {$vx + [ui::text $vx [expr {$ry + 16}] [dict get $r old] i13 $c(muted) w 0 {} 1] + 6}]
				set vx [expr {$vx + [ui::text $vx [expr {$ry + 16}] → i13 $c(muted)] + 6}]
				ui::text $vx [expr {$ry + 16}] [dict get $r new] i13 [expr {$gone ? $c(muted) : $c(fg)}] w 0 {} 1
			}
		}
		ui::text $sizer [expr {$ry + 16}] $size i13 $c(muted) e 0 {} 1
		set tx $R
		foreach t [lreverse [dict get $r tags]] {
			set tx [expr {$tx - [ui::measure i11s $t] - 14}]
			ui::badge $tx [expr {$ry + 14}] $t [expr {$t eq "security"}]
			set tx [expr {$tx - 6}]
		}
		set ry [expr {$ry + 48}]
		if {[incr n] < [llength $shown] || [llength $data]} { ui::hline $L $R [expr {$ry - 1}] $c(border) }
	}
	# Uninstall's data questions (kit toss's own words), each a checkbox, off until ticked
	if {[llength $data]} {
		set dy [expr {$ry + 14}]
		set i 0
		foreach d $data {
			ui::box $L $dy [expr {$R - $L}] 52 -fill $c(field) -radius 10
			set cx [expr {$L + 16}]; set cy [expr {$dy + 17}]
			if {[dict get $d on]} {
				ui::box $cx $cy 18 18 -fill $c(accent) -radius 5
				ui::icon check 12 $c(ink) [expr {$cx + 3}] [expr {$cy + 3}] 3
			} else {
				ui::box $cx $cy 18 18 -fill $c(field) -radius 5
				ui::ring $cx $cy 18 18 5 $c(muted) 1.5
			}
			# "Also remove its data in PATH (SIZE)?", the path in 600
			set q [dict get $d q]
			set tx [expr {$cx + 30}]; set room [expr {$R - 16 - $tx}]
			if {[regexp {^(Also remove its data in )(.*)( \([^()]*\)\?)$} $q -> pre path post]} {
				set tx [expr {$tx + [ui::text $tx [expr {$dy + 18}] $pre i13 $c(fg) w 0 {} 1]}]
				set pw [expr {$room - [ui::measure i13 $pre 0 1] - [ui::measure i13 $post 0 1]}]
				set tx [expr {$tx + [ui::text $tx [expr {$dy + 18}] [clip i13s $path $pw] i13s $c(fg) w 0 {} 1]}]
				ui::text $tx [expr {$dy + 18}] $post i13 $c(fg) w 0 {} 1
			} else {
				ui::text $tx [expr {$dy + 18}] [clip i13 $q $room] i13 $c(fg) w 0 {} 1
			}
			ui::hit $L $dy [expr {$R - $L}] 52 [list page::sheet_check $i]
			ui::focusable pdata$i check $cx $cy 18 18 5 [list page::sheet_check $i]
			set dy [expr {$dy + 60}]
			incr i
		}
		set ry [expr {$dy - 8 + 22}]
	}
	# the footer: what it downloads or frees, Cancel, and kit's question
	ui::hline $x [expr {$x + $w}] $ry $c(border)
	ui::text $L [expr {$ry + 28}] [dict get $P foot] i13 $c(muted) w 0 {} 1
	set bx [sheet_button $R [expr {$ry + 17}] [dict get $dialog question]]
	set cw [ui::button_w Cancel ghost]
	ui::button pno [expr {$bx - 10 - $cw}] [expr {$ry + 17}] Cancel ghost {page::sheet_answer 0} "" $cw
	ui::focus_ring
}

# ---- doing things with kit -------------------------------------------------------------------

# Run kit's VERB on TARGET (kitlink.tcl), then show what it said and what
# is installed now. AFTER runs with the code.
proc page::kit_do {verb target {after ""}} {
	variable S
	if {$S(busy)} return
	set S(busy) 1
	. configure -cursor watch
	draw
	update
	lassign [kitlink::verb $verb $target] code said
	set S(busy) 0
	. configure -cursor {}
	if {$after ne ""} { uplevel #0 [list {*}$after $code] }
	if {$code == 1} { draw; return $code }
	if {$code != 0} {
		dlg::message [dict get {Grab "Couldn't update it" Mend "Couldn't repair it" Toss "Couldn't uninstall it" Rewind "Couldn't rewind it"} $verb] \
			[expr {$said ne "" ? $said : "kit stopped with code $code."}]
	} elseif {$said ne "" && $verb ne "Toss"} {
		dlg::message $S(title) $said
	}
	draw
	return $code
}

# ---- keys ------------------------------------------------------------------------------------------

proc page::clicked_outside {} {
	variable dialog
	if {$dialog ne ""} return
	menu_close
	if {[lindex [ui::focused] 1] eq "field"} { set ui::focus ""; draw }
}

proc page::key {sym char state} {
	variable S
	variable dialog
	variable menu
	update idletasks
	if {$dialog ne ""} {
		if {[dict get $dialog kind] eq "plan"} {
			# the rows of a long plan (Kit-Sheet-5-Long), when focused, take the scrolling keys
			set f [ui::focused]
			if {[lindex $f 1] eq "list"} {
				if {[uplevel #0 [list {*}[lindex $f 7] $sym]]} return
				if {$sym in {Return KP_Enter space}} return
			}
			switch -- $sym {
				Escape { sheet_answer 0 }
				Return - KP_Enter - space { uplevel #0 [lindex $f 7] }
				Tab - Left - Right { ui::cycle 1 }
				ISO_Left_Tab { ui::cycle -1 }
			}
			return
		}
		dlg::key $sym $char $state; return
	}
	if {[dict size $menu] && [menu_key $sym]} return
	set f [ui::focused]
	lassign $f id kind
	set ctrl [expr {$state & 4}]
	set alt [expr {$state & 8}]
	if {$ctrl && $sym in {q Q w W}} { quit }
	if {$alt && [string match {[1-9]} $sym]} { go [lindex [keys] [expr {$sym - 1}]]; return }
	switch -- $sym {
		Tab { if {$state & 1} { ui::cycle -1 } else { ui::cycle 1 }; return }
		ISO_Left_Tab { ui::cycle -1; return }
	}
	if {$kind eq "field"} {
		if {$sym eq "Escape"} { fp::name_cancel; return }
		if {[ui::field_key $id $sym $char $state]} { draw }
		return
	}
	if {$kind in {button toggle check} && $sym in {Return KP_Enter space}} { uplevel #0 [lindex $f 7]; return }
	if {$kind in {list seg slider area} && [uplevel #0 [list {*}[lindex $f 7] $sym]]} return
	switch -- $sym {
		Escape { quit }
		Prior { if {$ctrl} { rail_key Up } }
		Next { if {$ctrl} { rail_key Down } }
		F2 { if {$S(kind) in {file folder}} { fp::name_edit } }
	}
}
