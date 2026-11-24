# page-games.tcl - Settings → Game overlay (U21, HUD-Settings-B-1…8, locked list): the games list column (200 wide:
# search, the pinned Defaults row, the games, a Hidden section) and the pane (525 wide: the 100 tall head with a 160 x 100
# preview, the rows, the Contents eye list). The store is hudstore.tcl (U20) and detection is games.tcl.
#
# Window coordinates (the page starts at x 270; the rail is 230): the list column 270…470, the divider at 502, the pane
# 535…1060, the footer rule at 648 with its buttons at 665. Rows are 48 (a 76 tall Position row); a row's slot is 28 wide
# after its control (controls end at 1032 on a game, 1060 on Defaults): a link glyph when inherited, a reset button when
# set here. The overlay off dims the rows below Overlay to 40 % (ui::dim), and they stay editable.

source -encoding utf-8 [file join [file dirname [file normalize [info script]]] hudstore.tcl]
source -encoding utf-8 [file join [file dirname [file normalize [info script]]] games.tcl]

settings::page game -title {Game overlay} -icon overlay -group 3 -order 2 -draw settings::draw_games \
	-rows {Overlay {Show when a game starts} Layout Position Scale Transparency {Frame source} Contents Shortcut \
		{Last played} {Add game} {Reset to defaults} {Hide game} {Show in list} Edit Remove}

# the eye and the search glyphs under this page's own names (another page may define its own "eye")
array set ui::paths {
	geye {M1 12C1 12 5 5 12 5C19 5 23 12 23 12C23 12 19 19 12 19C5 19 1 12 1 12z M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z}
	geyeoff {M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94 M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19 M14.12 14.12a3 3 0 1 1-4.24-4.24 M1 1l22 22}
	gsearch {M11 19a8 8 0 1 0 0-16a8 8 0 0 0 0 16z M21 21l-4.35-4.35}
	gx {M18 6L6 18 M6 6l12 12}
}

namespace eval games {
	variable sel defaults       ;# "defaults" or a game key
	variable query ""           ;# the search text (the field holds it too)
	variable sort played        ;# played | name | playtime
	variable show all           ;# all | own | off
	variable hidden_open 1      ;# the Hidden section
	variable top 0              ;# the list's scroll, in px
	variable games {}           ;# every game: dicts key name source art played playtime
	variable menu ""            ;# "" | sort | frame | source   (an open menu)
	variable sheet ""           ;# "" | add | edit   (the Add/Edit sheet)
	variable sheetkey ""
	variable sheet_art ""       ;# the picture chosen in the sheet ("": none)
	variable scanned 0
	variable rowh 52
	variable listtop 258
	variable listbot 632
	variable pos_labels {tl {Top left} tr {Top right} bl {Bottom left} br {Bottom right}}
	variable layout_labels {fps FPS compact Compact full Full}
	variable scale_labels {90 90% 100 100% 125 125% 150 150%}
	variable source_labels {auto Automatic compositor Compositor}
	variable contents_names {frametime {Frame time} low1 {1% low} graph {Frame graph} gamename {Game name} gpu GPU vram VRAM \
		cpu CPU mem Memory power Power net Network disk Disk clock Clock}
	variable contents_grid {frametime low1 graph gamename gpu vram cpu mem power net disk clock}
}

# ---- data ---------------------------------------------------------------------------------------

# Write the store and tell the Game HUD. The HUD follows the file by itself while it is up; "ribbon-hud reload" makes
# it read now, and starts it when a game is to get the HUD by itself (Show when a game starts). RIBBON_HUD_CMD names
# the command in the tests. Returns what the write returned.
proc games::save {} {
	variable reload_job
	set ok [hud::write_file]
	if {[info exists reload_job]} { after cancel $reload_job }
	set reload_job [after 150 games::hud_reload]
	return $ok
}

proc games::hud_reload {} {
	variable reload_job
	unset -nocomplain reload_job
	set cmd [expr {[info exists ::env(RIBBON_HUD_CMD)] ? $::env(RIBBON_HUD_CMD) : [auto_execok ribbon-hud]}]
	if {$cmd ne ""} { catch {exec {*}$cmd reload >/dev/null 2>/dev/null &} }
}

# Rescan the launchers when the page opens (Steam, Heroic, Lutris), merged with the games added by hand.
proc games::rescan {} {
	variable games
	set found [gdetect::all $::env(HOME)]
	set added {}
	dict for {key a} [hud::added] {
		lappend added [dict create key $key name [dict get $a name] source added art [dict get $a art] played 0 playtime 0]
	}
	set games [concat $found $added]
	# a game that is gone (uninstalled, removed) cannot stay chosen
	variable sel
	if {$sel ne "defaults" && [dict size [games::find $sel]] == 0} { set sel defaults }
}

proc games::find {key} {
	variable games
	foreach g $games { if {[dict get $g key] eq $key} { return $g } }
	return ""
}

proc games::source_text {g} {
	switch -- [dict get $g source] {
		steam { return Steam }
		heroic { return {Heroic · GOG or Epic} }
		lutris { return Lutris }
		default { return "Added by you · [string range [dict get $g key] 5 end]" }
	}
}

# The list's rows after the search, the show filter and the sort: visible games, and the hidden ones.
proc games::visible {} {
	variable games
	variable query
	variable show
	variable sort
	set vis {}; set hid {}
	foreach g $games {
		set k [dict get $g key]
		if {$query ne "" && ![string match -nocase "*$query*" [dict get $g name]]} continue
		if {[hud::is_hidden $k]} { lappend hid $g; continue }
		if {$show eq "own" && [hud::own_count $k] == 0} continue
		if {$show eq "off" && [hud::effective $k on]} continue
		lappend vis $g
	}
	switch -- $sort {
		name { set vis [lsort -command {apply {{a b} { string compare -nocase [dict get $a name] [dict get $b name] }}} $vis] }
		playtime { set vis [lsort -command {apply {{a b} { expr {[dict get $b playtime] - [dict get $a playtime]} }}} $vis] }
		default { set vis [lsort -command {apply {{a b} { expr {[dict get $b played] - [dict get $a played]} }}} $vis] }
	}
	list $vis $hid
}

# ---- drawing helpers -------------------------------------------------------------------------------

proc games::hit {x y w h script} {
	ui::hit $x $y $w $h [list apply {{s x y} { uplevel #0 $s }} $script]
}

# A row label: 13 px, inherited (muted, 500) or set here (fg, 600); its slot (28) after the control.
proc games::label {x top text own} {
	array set c [array get ui::c]
	ui::text $x [ui::lh $top [expr {$own ? "i13s" : "i13m"}] 48] $text [expr {$own ? "i13s" : "i13m"}] [expr {$own ? $c(fg) : $c(muted)}]
}

# The slot after a row's control: a reset button when set here (28 x 28), a link glyph when inherited.
proc games::slot {top own script} {
	array set c [array get ui::c]
	set y [expr {$top + 10}]
	if {$own} {
		ui::box 1032 $y 28 28 -fill $c(field) -radius 8 -ring [list $c(border) 1]
		ui::icon undo 14 $c(fg) 1039 [expr {$y + 7}] 2
		games::hit 1032 $y 28 28 $script
	} else {
		ui::icon link 14 $c(muted) 1039 [expr {$top + 17}] 2
	}
}

# A seg over a row's control (248 wide, 32 tall, its top at TOP + 8, right at XR).
proc games::seg {id xr top opts cur cmd} {
	ui::seg $id [expr {$xr - 248}] [expr {$top + 8}] 248 $opts $cur [list games::set_field $cmd] 32
}

# Set a field on the current selection: Defaults (sel defaults) or the game's override.
proc games::set_field {field value} {
	variable sel
	if {$sel eq "defaults"} { hud::put_default $field $value } else { hud::put $sel $field $value }
	games::save
	page::draw
}

proc games::reset_field {field} {
	variable sel
	hud::drop $sel $field
	games::save
	page::draw
}

proc games::toggle_field {field} {
	variable sel
	set v [hud::effective $sel $field]
	games::set_field $field [expr {$v eq "1" ? 0 : 1}]
}

# ---- list column ----------------------------------------------------------------------------------

proc games::draw_list {} {
	variable sel
	variable top
	variable rowh
	variable listtop
	variable listbot
	variable query
	array set c [array get ui::c]
	lassign [games::visible] vis hid
	# search: a 34 tall field at 120; the field keeps its text
	ui::box 270 120 200 34 -fill $c(field) -radius 9 -ring [list $c(border) 1]
	ui::icon gsearch 14 $c(muted) 282 130
	ui::field gsearch 300 120 140 -h 34 -ph {Search games} -pad 0 -ring 0 -onchange games::search_changed
	if {$query ne ""} {
		ui::icon gx 12 $c(muted) 452 131
		games::hit 446 124 26 26 [list games::search_clear]
	}
	# the pinned Defaults row (52)
	games::row_frame 262 166 52 [expr {$sel eq "defaults"}]
	ui::icon wins 22 $c(fg) 270 181
	ui::text 310 [ui::lh 176 i13s 18] Defaults i13s $c(fg)
	ui::text 310 [ui::lh 196 i12m 16] [games::defaults_sub] i12m $c(muted)
	games::hit 262 166 216 52 [list games::choose defaults]
	# the games: a label, then the rows, scrolled
	set label [expr {[games::query_on] ? "RESULTS · [llength $vis]" : "GAMES"}]
	games::label_block 270 236 $label
	games::sort_menu_button
	set n [llength $vis]
	set total [expr {$n * $rowh}]
	if {[llength $hid] > 0} { incr total 36; if {$::games::hidden_open} { incr total [expr {[llength $hid] * $rowh}] } }
	set view [expr {$listbot - $listtop}]
	set maxtop [expr {max(0, $total - $view)}]
	if {$top > $maxtop} { set top $maxtop }
	if {$top < 0} { set top 0 }
	set y [expr {$listtop - $top}]
	foreach g $vis {
		games::game_row $g $y
		incr y $rowh
	}
	if {[llength $hid] > 0} {
		games::hidden_header $y [llength $hid]
		incr y 36
		if {$::games::hidden_open} {
			foreach g $hid { games::game_row $g $y; incr y $rowh }
		}
	}
	games::scrollbar $total $view
}

proc games::query_on {} { variable query; expr {$query ne ""} }

proc games::search_changed {args} { variable query; set query [string trim [ui::fval gsearch]]; set ::games::top 0; page::draw }
proc games::search_clear {} { variable query; set query ""; ui::fset gsearch ""; page::draw }

proc games::defaults_sub {} {
	set d [hud::defaults]
	variable layout_labels
	variable pos_labels
	return "[dict get $layout_labels [dict get $d layout]] · [string tolower [dict get $pos_labels [dict get $d pos]]]"
}

proc games::label_block {x top text} {
	array set c [array get ui::c]
	ui::text $x [ui::lh $top i11s 16] $text i11s $c(muted) w 1.32
}

# The "Last played ⌄" menu button at the right of the GAMES label.
proc games::sort_menu_button {} {
	variable sort
	array set c [array get ui::c]
	set lab [dict get {played {Last played} name Name playtime {Play time}} $sort]
	ui::text 452 [ui::lh 236 i12m 16] $lab i12m $c(muted) e
	ui::icon down 12 $c(muted) 458 238 2
	games::hit 360 232 110 24 [list games::open_menu sort]
}

proc games::row_frame {x y h on} {
	array set c [array get ui::c]
	if {$on} { ui::box $x $y 216 52 -fill $c(field) -radius 10 }
}

proc games::game_row {g y} {
	array set c [array get ui::c]
	variable sel
	set k [dict get $g key]
	set on [expr {$sel eq $k}]
	if {$y + 52 < 258 || $y > 632} return
	if {$on} { ui::box 262 $y 216 52 -fill $c(field) -radius 10 }
	games::tile $g 270 [expr {$y + 12}] 28 [expr {$on ? $c(field) : ""}]
	ui::text 310 [ui::lh [expr {$y + 10}] i13s 18] [dict get $g name] i13s $c(fg)
	ui::text 310 [ui::lh [expr {$y + 30}] i12m 16] [hud::state_text $k] i12m $c(muted)
	games::hit 262 $y 216 52 [list games::choose $k]
}

proc games::hidden_header {y n} {
	variable hidden_open
	array set c [array get ui::c]
	ui::box 270 [expr {$y + 7}] 200 1 -fill $c(border)
	ui::text 270 [ui::lh [expr {$y + 14}] i11s 16] "HIDDEN · $n" i11s $c(muted) w 1.32
	ui::icon [expr {$hidden_open ? "down" : "down"}] 12 $c(muted) 452 [expr {$y + 16}] 2
	games::hit 262 $y 216 36 [list games::toggle_hidden_open]
}

proc games::toggle_hidden_open {} {
	variable hidden_open
	set hidden_open [expr {!$hidden_open}]
	page::draw
}

# The launcher's art (Steam's library JPEG, a Lutris banner, the picture chosen for a game added by hand) as a W x H
# photo, scaled to cover and cropped in the middle (appearance's os::thumb: ffmpeg, cached). "" when there is none or
# it cannot be read.
proc games::art_photo {g w h} {
	if {![dict exists $g art]} { return "" }
	set f [file normalize [dict get $g art]]
	if {[dict get $g art] eq "" || ![file isfile $f]} { return "" }
	if {[catch {os::thumb $f $w $h} p]} { return "" }
	return $p
}

# The colours a tile without art takes (by the game's name).
proc games::tile_colours {} { return {#2b3a55 #5a2d2d #2d4a36 #4a3d2a #2d4a4a} }

# A square tile for a game: its art, else its initial on a colour from its name. BG is the colour under the tile's
# rounded corners.
proc games::tile {g x y s {bg ""}} {
	array set c [array get ui::c]
	set r [expr {$s >= 44 ? 10 : 7}]
	set p [games::art_photo $g $s $s]
	if {$p ne ""} {
		raster::blit $ui::img $p 0 0 $s $s [expr {round($x)}] [expr {round($y)}]
		ui::corners [expr {round($x)}] [expr {round($y)}] $s $s $r [expr {$bg eq "" ? $c(bar) : $bg}]
		return
	}
	set name [dict get $g name]
	set cols [games::tile_colours]
	set fill [lindex $cols [expr {[string length $name] % [llength $cols]}]]
	ui::box $x $y $s $s -fill $fill -radius $r
	ui::text [expr {$x + $s / 2.0}] [ui::lh $y i13s $s] [string toupper [string index $name 0]] i13s $c(fg) c
}

proc games::scrollbar {total view} {
	variable top
	variable listtop
	array set c [array get ui::c]
	if {$total <= $view} return
	set th [expr {max(24, $view * $view / $total)}]
	set ty [expr {$listtop + ($view - $th) * $top / ($total - $view)}]
	ui::box 486 $ty 3 $th -fill $c(muted) -radius 2
}

# ---- rows of the pane ----------------------------------------------------------------------------

proc games::choose {key} {
	variable sel
	set sel $key
	page::draw
}

proc games::open_menu {which} {
	variable menu
	set menu [expr {$menu eq $which ? "" : $which}]
	page::draw
}

# The pane: the head (100 tall), then the rows (48 each; Position 76), then Contents.
proc games::draw_pane {} {
	variable sel
	variable sheet
	array set c [array get ui::c]
	set d [expr {$sel eq "defaults"}]
	set g [expr {$d ? "" : [games::find $sel]}]
	games::draw_head $d $g
	set xr [expr {$d ? 1060 : 1032}]
	# overlay on? (the rows below are dimmed when it is off)
	set on [hud::effective $sel on]
	games::row_toggle 140 Overlay on $xr $d $sel
	# the rows below Overlay dim to 40 % when it is off; a sheet's dim (the base) stays under them
	set base $ui::dim
	set ui::dim [expr {max($base, $on eq "1" ? 0 : 0.6)}]
	games::row_toggle 188 [expr {$d ? "Show when a game starts" : "Show when the game starts"}] start $xr $d $sel
	games::row_seg 236 Layout layout $xr $d $sel
	games::row_pos 284 $xr $d $sel
	games::row_seg 360 Scale scale $xr $d $sel
	games::row_transp 408 $xr $d $sel
	games::row_source 456 $xr $d $sel
	set ui::dim $base
	games::draw_contents $xr $d $sel
}

# The head: the tile (44), the name (SG 20 over 22 here), a state tag, the source and the facts.
proc games::draw_head {d g} {
	variable sel
	array set c [array get ui::c]
	if {$d} {
		ui::box 535 34 44 44 -fill $c(field) -radius 10 -ring [list $c(border) 1]
		ui::icon wins 22 $c(fg) 546 45
		ui::text 593 [ui::lh 36 sg22 24] Defaults sg22 $c(fg) w -0.44
		ui::text 593 [ui::lh 62 i13 18] [games::head_sub_defaults] i13 $c(muted)
		ui::text 535 [ui::lh 118 i13 20] Shortcut i13 $c(muted)
		games::shortcut_tags 623 118
	} else {
		games::tile $g 535 34 44
		set name [dict get $g name]
		ui::text 593 [ui::lh 36 sg22 24] $name sg22 $c(fg) w -0.44
		set nw [expr {round([ui::measure sg22 $name])}]
		set tag [hud::state_text $sel]
		set tw [expr {round([ui::measure i12m $tag]) + 16}]
		ui::box [expr {593 + $nw + 10}] 40 $tw 22 -fill $c(field) -radius 6
		ui::text [expr {593 + $nw + 18}] [ui::lh 40 i12m 22] $tag i12m $c(fg)
		ui::text 593 [ui::lh 62 i13 18] [games::source_text $g] i13 $c(muted)
		ui::text 535 [ui::lh 90 i13 20] {Last played} i13 $c(muted)
		set when [gdetect::played_text [dict get $g played]]
		set play [gdetect::playtime_text [dict get $g playtime]]
		set v [expr {$when eq "" ? "Never" : $when}]
		if {$play ne ""} { append v " · $play" }
		ui::text 623 [ui::lh 90 i13 20] $v i13 $c(fg)
		ui::text 535 [ui::lh 114 i13 20] Shortcut i13 $c(muted)
		games::shortcut_tags 623 114
	}
	# the preview, 160 x 100 at the head's right: the effective settings over the art (no overlay when it is off)
	games::preview 900 34
}

proc games::head_sub_defaults {} {
	variable games
	set n [llength $games]
	set own 0
	foreach g $games { if {[hud::own_count [dict get $g key]] > 0} { incr own } }
	return "$n games · $own with their own"
}

proc games::shortcut_tags {x y} {
	array set c [array get ui::c]
	foreach t {Super F12 {All games}} {
		set w [expr {round([ui::measure i12m $t]) + 16}]
		ui::box $x $y $w 20 -fill $c(field) -radius 6
		ui::text [expr {$x + 8}] [ui::lh $y i12m 20] $t i12m $c(fg)
		incr x [expr {$w + 6}]
	}
}

# The 160 x 100 preview: a field-coloured frame with the overlay's corner box at the chosen position and scale.
proc games::preview {x y} {
	variable sel
	array set c [array get ui::c]
	ui::box $x $y 160 100 -fill $c(field) -radius 8 -ring [list $c(border) 1]
	set g [expr {$sel eq "defaults" ? {} : [games::find $sel]}]
	set p [expr {[dict size $g] ? [games::art_photo $g 160 100] : ""}]
	if {$p ne ""} {
		raster::blit $ui::img $p 0 0 160 100 $x $y
		ui::corners $x $y 160 100 8 $c(bar)
		ui::ring $x $y 160 100 8 $c(border) 1
	}
	if {[hud::effective $sel on] ne "1"} return
	set pos [hud::effective $sel pos]
	set s [expr {[hud::effective $sel scale] / 100.0}]
	set w [expr {round(54 * $s)}]; set h [expr {round(30 * $s)}]
	set px [expr {$pos in {tr br} ? $x + 160 - $w - 6 : $x + 6}]
	set py [expr {$pos in {bl br} ? $y + 100 - $h - 6 : $y + 6}]
	ui::box $px $py $w $h -fill $c(bar) -radius 4
}

# Rows of the pane, each with its label, control and slot.
proc games::row_toggle {top label field xr d sel} {
	array set c [array get ui::c]
	set own [expr {!$d && [dict exists [hud::own_fields $sel] $field]}]
	games::label 535 $top $label [expr {$d ? 1 : $own}]
	ui::toggle [expr {$xr - 38}] [expr {$top + 13}] [hud::effective $sel $field]
	games::hit [expr {$xr - 38}] [expr {$top + 13}] 38 22 [list games::toggle_field $field]
	if {!$d} { games::slot $top $own [list games::reset_field $field] }
	ui::hline 535 1060 [expr {$top + 47}] $c(border)
}

proc games::row_seg {top label field xr d sel} {
	variable layout_labels
	variable scale_labels
	array set c [array get ui::c]
	set own [expr {!$d && [dict exists [hud::own_fields $sel] $field]}]
	games::label 535 $top $label [expr {$d ? 1 : $own}]
	if {$field eq "layout"} {
		set opts $layout_labels
	} else {
		set opts $scale_labels
	}
	ui::seg game_$field [expr {$xr - 248}] [expr {$top + 8}] 248 $opts [hud::effective $sel $field] \
		[list games::set_field $field] 32
	if {!$d} { games::slot $top $own [list games::reset_field $field] }
	ui::hline 535 1060 [expr {$top + 47}] $c(border)
}

proc games::row_pos {top xr d sel} {
	variable pos_labels
	array set c [array get ui::c]
	set own [expr {!$d && [dict exists [hud::own_fields $sel] pos]}]
	games::label 535 $top Position [expr {$d ? 1 : $own}]
	set cur [hud::effective $sel pos]
	set x [expr {$xr - 248}]
	ui::box $x [expr {$top + 6}] 248 64 -fill $c(field) -radius 9 -ring [list $c(border) 1]
	foreach {k i} {tl {0 0} tr {1 0} bl {0 1} br {1 1}} {
		lassign $i cx cy
		set bx [expr {$x + 3 + $cx * 122}]; set by [expr {$top + 9 + $cy * 28}]
		if {$k eq $cur} { ui::box $bx $by 118 26 -fill $c(pill) -radius 6 }
		ui::text [expr {$bx + 59}] [ui::lh $by [expr {$k eq $cur ? "i13s" : "i13m"}] 26] [dict get $pos_labels $k] \
			[expr {$k eq $cur ? "i13s" : "i13m"}] [expr {$k eq $cur ? $c(fg) : $c(muted)}] c
		games::hit $bx $by 118 26 [list games::set_field pos $k]
	}
	if {!$d} { games::slot $top $own [list games::reset_field pos] }
	ui::hline 535 1060 [expr {$top + 75}] $c(border)
}

proc games::row_transp {top xr d sel} {
	array set c [array get ui::c]
	set own [expr {!$d && [dict exists [hud::own_fields $sel] transp]}]
	games::label 535 $top Transparency [expr {$d ? 1 : $own}]
	set v [hud::effective $sel transp]
	set x0 [expr {$xr - 248}]; set w 193
	ui::box $x0 [expr {$top + 22}] $w 4 -fill $c(pill) -radius 2
	set kx [expr {$x0 + round($w * $v / 50.0)}]
	ui::box [expr {$x0}] [expr {$top + 22}] [expr {$kx - $x0}] 4 -fill $c(fg) -radius 2
	ui::box [expr {$kx - 7}] [expr {$top + 17}] 14 14 -fill $c(fg) -radius 7
	ui::text [expr {$xr}] [ui::lh [expr {$top + 14}] i13 20] "$v%" i13 $c(fg) e
	ui::hit $x0 [expr {$top + 10}] $w 28 [list games::slider_at $sel $x0 $w] [list games::slider_at $sel $x0 $w]
	ui::hline 535 1060 [expr {$top + 47}] $c(border)
	if {!$d} { games::slot $top $own [list games::reset_field transp] }
}

# A click on the slider sets the value from its x (0 to 50 %).
proc games::slider_at {sel x0 w x y} {
	set v [expr {round(max(0, min(50, ($x - $x0) * 50.0 / $w)))}]
	if {$v != [hud::effective $sel transp]} { games::set_field transp $v }
}

proc games::row_source {top xr d sel} {
	variable source_labels
	array set c [array get ui::c]
	set own [expr {!$d && [dict exists [hud::own_fields $sel] source]}]
	games::label 535 $top {Frame source} [expr {$d ? 1 : $own}]
	set cur [hud::effective $sel source]
	set lab [dict get $source_labels $cur]
	set x [expr {$xr - 248}]
	ui::box $x [expr {$top + 8}] 248 32 -fill $c(field) -radius 8 -ring [list $c(border) 1]
	ui::text [expr {$x + 12}] [ui::lh [expr {$top + 8}] i13 32] $lab i13 $c(fg)
	ui::icon down 14 $c(muted) [expr {$x + 248 - 24}] [expr {$top + 17}] 2
	games::hit $x [expr {$top + 8}] 248 32 [list games::open_menu frame]
	if {!$d} { games::slot $top $own [list games::reset_field source] }
	ui::hline 535 1060 [expr {$top + 47}] $c(border)
}

# Contents: a 4 x 3 eye list (30 tall) under its label at 517; the set is overridden as one.
proc games::draw_contents {xr d sel} {
	variable contents_names
	variable contents_grid
	array set c [array get ui::c]
	set own [expr {!$d && [dict exists [hud::own_fields $sel] contents]}]
	games::label_block 535 517 CONTENTS
	if {!$d} { games::slot 511 $own [list games::reset_field contents] }
	set on [hud::contents_on $sel]
	set cols {535 674 813 953}
	foreach {name} $contents_grid {
		set i [lsearch -exact $contents_grid $name]
		set col [expr {$i / 3}]; set row [expr {$i % 3}]
		set x [lindex $cols $col]; set y [expr {541 + $row * 30}]
		set isOn [expr {$name in $on}]
		ui::text $x [ui::lh $y i13 30] [dict get $contents_names $name] i13 [expr {$isOn ? $c(fg) : $c(muted)}]
		if {$isOn} { ui::icon geye 16 $c(fg) [expr {$x + 90}] [expr {$y + 7}] 1.9 } else { ui::icon geyeoff 16 $c(muted) [expr {$x + 90}] [expr {$y + 7}] 1.9 }
		games::hit $x $y 120 30 [list games::contents_toggle $name]
		if {$row < 2} { ui::hline $x [expr {$x + 118}] [expr {$y + 29}] $c(border) }
	}
}

proc games::contents_toggle {name} {
	variable sel
	if {$sel eq "defaults"} {
		set on [hud::defaults]
		set cur [dict get $on contents]
		if {$name in $cur} { set cur [lsearch -all -inline -not -exact $cur $name] } else { lappend cur $name }
		games::set_field contents $cur
	} else {
		hud::contents_toggle $sel $name
		games::save
		page::draw
	}
}

# ---- footer --------------------------------------------------------------------------------------

proc games::draw_footer {} {
	variable sel
	variable sheet
	array set c [array get ui::c]
	ui::hline 230 1100 648 $c(border)
	ui::button add_game 270 665 {Add game…} field [list games::open_sheet add] plus
	if {$sel eq "defaults"} return
	set x 1060
	set g [games::find $sel]
	# left to right, as the boards have them: Reset to defaults (own settings), then Hide game, or for a game added by
	# hand Edit… and Remove (B-4); a hidden game has Show in list (B-8)
	set items {}
	if {[hud::is_hidden $sel]} {
		set items [list [list show_in_list {Show in list} ghost [list games::set_hidden $sel 0] geye]]
	} elseif {[hud::own_count $sel] > 0} {
		set items [list [list reset_all {Reset to defaults} ghost [list games::reset_game $sel] undo]]
	}
	if {[dict get $g source] eq "added"} {
		lappend items [list edit_game Edit… ghost [list games::open_sheet edit $sel] edit] \
			[list remove_game Remove ghost [list games::remove $sel] trash]
	} elseif {![hud::is_hidden $sel]} {
		lappend items [list hide_game {Hide game} ghost [list games::set_hidden $sel 1] geyeoff]
	}
	foreach it [lreverse $items] {
		lassign $it id label kind script icon
		set w [ui::button_w $label $kind $icon]
		set x [expr {$x - $w}]
		ui::button $id $x 665 $label $kind $script $icon $w
		set x [expr {$x - 10}]
	}
}

proc games::set_hidden {key flag} {
	hud::set_hidden $key $flag
	games::save
	page::draw
}

proc games::reset_game {key} {
	hud::reset $key
	games::save
	page::draw
}

proc games::remove {key} {
	variable sel
	hud::remove_game $key
	games::save
	set sel defaults
	games::rescan
	page::draw
}

# ---- entry points -------------------------------------------------------------------------------

proc settings::draw_games {} {
	variable ::games::sel
	variable ::games::scanned
	array set c [array get ui::c]
	# the page is dimmed under the sheet, which draws over it (games::draw_sheet)
	set ui::dim [expr {$::games::sheet ne "" ? 0.35 : 0}]
	if {!$::games::scanned} {
		set ::games::scanned 1
		games::rescan
	}
	lassign [hud::counts [lmap g $::games::games {dict get $g key}]] n own off
	ui::text 270 34 {Game overlay} sg28 $c(fg) w -0.56
	ui::text 270 [ui::lh 76 i14 21] "$n games · $own own · $off off" i14 $c(muted)
	games::draw_list
	ui::box 502 34 1 598 -fill $c(border)
	games::draw_pane
	games::draw_footer
	if {$::games::menu ne ""} { games::draw_menu }
	if {$::games::sheet ne ""} { games::draw_sheet }
	set ui::dim 0
}

# ---- menus: the sort and show menu (over the list), the frame source menu (under its dropdown) -------

proc games::draw_menu {} {
	variable menu
	variable sort
	variable show
	variable source_labels
	array set c [array get ui::c]
	# above everything drawn so far (the rows' text is canvas items, not the page's photo)
	ui::layer
	# a click outside closes the menu; the items are registered after it, so they win
	if {$menu eq "sort"} {
		set x 262; set y 258; set w 216; set h 300
		ui::hit 0 0 1100 720 [list games::close_menu]
		ui::box $x $y $w $h -fill $c(bar) -radius 12 -ring [list $c(border) 1]
		ui::text [expr {$x + 16}] [ui::lh [expr {$y + 14}] i11s 16] {SORT BY} i11s $c(muted) w 1.32
		set iy [expr {$y + 36}]
		foreach {k lab} {played {Last played} name Name playtime {Play time}} {
			games::menu_item $x $iy $w $lab [expr {$sort eq $k}] [list games::pick_sort $k]
			incr iy 36
		}
		ui::hline [expr {$x + 16}] [expr {$x + $w - 16}] [expr {$iy + 6}] $c(border)
		ui::text [expr {$x + 16}] [ui::lh [expr {$iy + 16}] i11s 16] SHOW i11s $c(muted) w 1.32
		set iy [expr {$iy + 38}]
		set counts [hud::counts [lmap g $::games::games {dict get $g key}]]
		lassign $counts n own off
		foreach {k lab cnt} [list all {All games} $n own {Own settings} $own off {Overlay off} $off] {
			games::menu_item $x $iy $w $lab [expr {$show eq $k}] [list games::pick_show $k] $cnt
			incr iy 36
		}
	} elseif {$menu eq "frame"} {
		set x 812; set y 496; set w 248
		ui::hit 0 0 1100 720 [list games::close_menu]
		ui::box $x $y $w 80 -fill $c(bar) -radius 10 -ring [list $c(border) 1]
		set iy [expr {$y + 4}]
		foreach {k lab} $source_labels {
			games::menu_item $x $iy $w $lab [expr {[hud::effective ::games::sel source] eq $k}] [list games::pick_field source $k]
			incr iy 36
		}
	}
}

proc games::menu_item {x y w lab chosen script {count ""}} {
	array set c [array get ui::c]
	if {$chosen} { ui::box [expr {$x + 6}] $y [expr {$w - 12}] 36 -fill $c(field) -radius 8 }
	ui::text [expr {$x + 16}] [ui::lh $y i13 36] $lab [expr {$chosen ? "i13s" : "i13m"}] [expr {$chosen ? $c(fg) : $c(fg)}]
	if {$count ne ""} { ui::text [expr {$x + $w - 36}] [ui::lh $y i13 36] $count i13 $c(muted) e }
	if {$chosen} { ui::icon check 14 $c(accent) [expr {$x + $w - 26}] [expr {$y + 11}] 2 }
	ui::hit $x $y $w 36 [list games::menu_pick $script]
}

proc games::menu_pick {script x y} { uplevel #0 $script; games::close_menu_quiet }

proc games::pick_sort {k} { variable sort; set sort $k; page::draw }
proc games::pick_show {k} { variable show; set show $k; page::draw }
proc games::pick_field {field v} { games::set_field $field $v }
proc games::close_menu {args} { variable menu; set menu ""; page::draw }
proc games::close_menu_quiet {} { variable menu; set menu "" }

# ---- the Add / Edit sheet (board HUD-Settings-B-5): program, name and art over the dimmed page ------

proc games::open_sheet {mode {key ""}} {
	variable sheet
	variable sheetkey
	set sheet $mode
	set sheetkey $key
	variable sheet_art
	if {$mode eq "edit"} {
		set g [games::find $key]
		ui::fset sheet_prog [dict get [hud::added] $key program]
		ui::fset sheet_name [dict get $g name]
		set sheet_art [dict get $g art]
	} else {
		ui::fset sheet_prog ""
		ui::fset sheet_name ""
		set sheet_art ""
	}
	page::draw
}

proc games::close_sheet {} {
	variable sheet
	set sheet ""
	page::draw
}

proc games::sheet_add {} {
	variable sheet
	variable sheetkey
	set prog [string trim [ui::fval sheet_prog]]
	if {$prog eq ""} return
	set name [string trim [ui::fval sheet_name]]
	if {$name eq ""} { set name [file rootname [file tail $prog]] }
	variable sheet_art
	if {$sheet eq "edit"} {
		hud::rename_game $sheetkey $name
		hud::set_art $sheetkey $sheet_art
	} else {
		set key [hud::add_game $name $prog $sheet_art]
	}
	games::save
	set sheet ""
	games::rescan
	page::draw
}

# Dim the page under the sheet (ui::dim, as the dialogs do), then draw the sheet over it at full strength.
proc games::draw_sheet {} {
	variable sheet
	array set c [array get ui::c]
	set ui::dim 0
	# the page under the sheet takes no clicks: this hit is registered before the sheet's controls
	ui::hit 0 0 1100 720 ""
	ui::box 230 183 640 344 -fill $c(bar) -radius 16 -ring [list $c(border) 1]
	ui::box 258 207 44 44 -fill $c(field) -radius 10
	ui::icon game 22 $c(fg) 269 218
	set title [expr {$sheet eq "edit" ? "Edit game" : "Add a game"}]
	ui::text 316 [ui::lh 205 sg22 24] $title sg22 $c(fg) w -0.44
	ui::text 316 [ui::lh 232 i13 18] {Game overlay} i13 $c(muted)
	ui::hline 258 842 271 $c(border)
	ui::text 258 [ui::lh 287 i13 38] Program i13 $c(fg)
	ui::field sheet_prog 366 287 380 -h 38
	ui::button sheet_choose 754 287 Choose… ghost [list games::choose_program] "" 88
	ui::hline 258 842 335 $c(border)
	ui::text 258 [ui::lh 345 i13 38] Name i13 $c(fg)
	ui::field sheet_name 366 345 476 -h 38
	ui::hline 258 842 393 $c(border)
	ui::text 258 [ui::lh 397 i13 36] Art i13 $c(fg)
	variable sheet_art
	set p [games::art_photo [dict create art $sheet_art] 36 36]
	if {$p ne ""} {
		raster::blit $ui::img $p 0 0 36 36 366 397
		ui::corners 366 397 36 36 8 $c(bar)
		ui::text 414 [ui::lh 397 i13 36] [file tail $sheet_art] i13 $c(fg)
	} else {
		ui::box 366 397 36 36 -fill $c(field) -radius 8
		ui::icon game 18 $c(muted) 375 406
		ui::text 414 [ui::lh 397 i13 36] {From the program} i13 $c(muted)
	}
	ui::button sheet_art 754 397 Choose… ghost [list games::choose_art] image 88
	ui::hline 258 842 455 $c(border)
	ui::button sheet_cancel 622 472 Cancel ghost [list games::close_sheet] "" 82
	ui::button sheet_add 714 472 [expr {$sheet eq "edit" ? "Save" : "Add game"}] primary [list games::sheet_add] plus 128
}

# The art chooser: a picture file for the game's tile (the same file dialog). The picture is kept by its path.
proc games::choose_art {} {
	variable sheet_art
	if {[llength [info commands ::dlg::open_file]] == 0} return
	catch {
		set f [dlg::open_file {Choose art} {{Pictures {.png .jpg .jpeg .webp .gif .bmp}} {{All files} *}}]
		if {$f ne ""} { set sheet_art $f }
	}
	page::draw
}

# The program chooser: the desktop's file dialog where it is there (not run in the headless scene).
proc games::choose_program {} {
	if {[llength [info commands ::dlg::open_file]] == 0} return
	catch {
		set f [dlg::open_file {Choose a program} {}]
		if {$f ne ""} { ui::fset sheet_prog $f }
	}
	page::draw
}
