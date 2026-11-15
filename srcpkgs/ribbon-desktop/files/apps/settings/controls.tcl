# controls.tcl - the controls Settings' pages share (namespace sctl), drawn with Appearance's ui.tcl as the boards
# draw them (STYLE 6): block labels, 48 px rows, switches, sliders, dropdowns with their list, and a sheet over
# the shaded window. A page sources this file (it is harmless to source twice) and, at the END of its draw proc,
# calls `sctl::overlay`, which draws whatever is open above the page: the dropdown's list, or the page's sheet.
#
#   sctl::label X Y TEXT                         a block label (11 px caps, muted, tracked), its text top at Y
#   sctl::row X0 X1 Y LABEL ?LAST?               a 48 px row: LABEL (13 px) at X0, a rule under it to X1 unless LAST
#   sctl::toggle ID X1 Y ON SCRIPT               the row's switch, ending at X1; SCRIPT runs on a click
#   sctl::slider ID X Y W FRAC SCRIPT            a slider W wide from X on the row at Y; SCRIPT gets 0..1 appended,
#                                                on a press and while dragged (Left/Right move it by 2 %)
#   sctl::value X1 Y TEXT                        the value a slider's row ends with (13 px, tabular), ending at X1
#   sctl::dropdown ID X Y W ITEMS CUR SCRIPT ?ICON?   a 32 px dropdown at X, Y+8 on the row at Y. ITEMS is a list of
#                                                {value label}; CUR the value shown; SCRIPT gets the value picked
#                                                appended. Its list opens under it (over it near the window's foot),
#                                                scrolls past nine rows, and jumps to what is typed.
#   sctl::button ID X Y LABEL KIND SCRIPT ?ICON? a 32 px button on the row at Y (KIND field | ghost | primary),
#                                                starting at X; returns its width. sctl::button_w LABEL ?ICON?
#   sctl::hit X Y W H SCRIPT                     a click area that runs SCRIPT and redraws
#   sctl::sheet_open NAME ?CANCEL?               open the page's sheet NAME (the window is shaded; CANCEL runs when
#   sctl::sheet_close                            Escape or sctl::sheet_close closes it)
#   sctl::sheet W H ICON TITLE SUB               in the page's sheet-drawing proc: the sheet's box, its tile, title
#                                                and subtitle; returns {x y} of the box. The body starts at y+88
#                                                (under a rule), the footer's rule is at y+H-72, its buttons at
#                                                y+H-55 (38 px buttons, ui::button), 28 px side margins.
#   sctl::overlay ?SHEETPROC?                    at the end of the page's draw: the open list, or (when the page's
#                                                sheet is open) SHEETPROC, called with the sheet's name
#   sctl::escape                                 Escape: closes the list or the sheet; 1 when it closed something
#   sctl::clip TEXT WIDTH ?FONT?                 TEXT cut to WIDTH px with an ellipsis
#
# While a sheet is open the page under it takes no clicks (the sheet's own hits come later, so they win). A page
# asks `sctl::busy` before it registers keyboard focus for controls under a sheet if it cares; clicks need nothing.

namespace eval sctl {
	variable pop ""          ;# the open dropdown's id
	variable popd {}         ;# its dict: x y w items cur script idx top (first row shown)
	variable sheet ""        ;# the open sheet's name
	variable cancel ""       ;# what closing it by Escape runs
	variable typed ""        ;# letters typed into an open list, and when
	variable typedat 0
	variable ROWS 9          ;# a list shows nine rows, then scrolls
}
foreach {k v} {
	sctl_chev  {M6 9l6 6 6-6}
	sctl_check {M20 6L9 17l-5-5}
} { set ::ui::paths($k) $v }
foreach {k v} {
	sg20 {{Ribbon Space Grotesk 600} 20 0.984 0.292}
} { if {![info exists ::ui::fonts($k)]} { set ::ui::fonts($k) $v; catch {text::font ui_$k {*}[lrange $v 0 1]} } }

proc sctl::busy {} { variable sheet; variable pop; expr {$sheet ne "" || $pop ne ""} }

proc sctl::hit {x y w h script} {
	ui::hit $x $y $w $h [list apply {{s x y} { uplevel #0 $s; page::draw }} $script]
}
proc sctl::label {x y text} { ui::text $x $y [string toupper $text] i11s $ui::c(muted) w 1.32 }
proc sctl::row {x0 x1 y label {last 0}} {
	ui::text $x0 [expr {$y + 16}] $label i13 $ui::c(fg)
	if {!$last} { ui::hline $x0 $x1 [expr {$y + 47}] $ui::c(border) }
}
proc sctl::toggle {id x1 y on script} {
	ui::toggle [expr {$x1 - 38}] [expr {$y + 13}] $on
	sctl::hit [expr {$x1 - 42}] [expr {$y + 8}] 46 32 $script
	ui::focusable $id toggle [expr {$x1 - 38}] [expr {$y + 13}] 38 22 11 [list apply {{s} { uplevel #0 $s; page::draw }} $script]
}
proc sctl::value {x1 y text} { ui::text $x1 [expr {$y + 16}] $text i13 $ui::c(fg) e 0 {} 1 }
proc sctl::slider {id x y w frac script} {
	array set c [array get ui::c]
	set frac [expr {max(0.0, min(1.0, double($frac)))}]
	ui::box $x [expr {$y + 22}] $w 4 -fill $c(pill) -radius 2
	if {$frac > 0} { ui::box $x [expr {$y + 22}] [expr {$w * $frac}] 4 -fill $c(muted) -radius 2 }
	ui::box [expr {$x + $w * $frac - 9}] [expr {$y + 15}] 18 18 -fill $c(fg) -radius 9
	set f [list apply {{x0 w s x y} { uplevel #0 [list {*}$s [expr {max(0.0, min(1.0, ($x - $x0) / double($w)))}]]; page::draw }} $x $w $script]
	ui::hit [expr {$x - 9}] [expr {$y + 8}] [expr {$w + 18}] 32 $f $f
	ui::focusable $id slider $x [expr {$y + 15}] $w 18 9 [list sctl::slider_key $frac $script]
}
proc sctl::slider_key {frac script sym} {
	switch -- $sym {
		Left - Down { set frac [expr {$frac - 0.02}] }
		Right - Up { set frac [expr {$frac + 0.02}] }
		default { return 0 }
	}
	uplevel #0 [list {*}$script [expr {max(0.0, min(1.0, $frac))}]]
	page::draw
	return 1
}
proc sctl::clip {text width {f i13}} {
	if {[ui::measure $f $text] <= $width} { return $text }
	while {[string length $text] > 1 && [ui::measure $f "$text…"] > $width} { set text [string range $text 0 end-1] }
	return "$text…"
}

# ---- buttons on a row -----------------------------------------------------------------------------

proc sctl::button_w {label {icon ""}} { expr {int(ceil(28 + [ui::measure i13m $label] + ($icon ne "" ? 21 : 0)))} }
proc sctl::button {id x y label kind script {icon ""}} {
	array set c [array get ui::c]
	set w [button_w $label $icon]
	set by [expr {$y + 8}]
	switch -- $kind {
		ghost { ui::ring $x $by $w 32 8 $c(border) 1; set fg $c(fg) }
		primary { ui::box $x $by $w 32 -fill $c(accent) -radius 8; set fg $c(ink) }
		default { ui::box $x $by $w 32 -fill $c(field) -radius 8 -ring [list $c(border) 1]; set fg $c(fg) }
	}
	set tw [ui::text [expr {$x + 14}] [expr {$by + 8}] $label i13m $fg]
	if {$icon ne ""} { ui::icon $icon 13 $fg [expr {$x + 14 + $tw + 8}] [expr {$by + 9.5}] 2 }
	sctl::hit $x $by $w 32 $script
	ui::focusable $id button $x $by $w 32 8 [list apply {{s} { uplevel #0 $s; page::draw }} $script]
	return $w
}

# ---- dropdowns -----------------------------------------------------------------------------------

proc sctl::dropdown {id x y w items cur script {icon ""}} {
	variable pop
	array set c [array get ui::c]
	set by [expr {$y + 8}]
	set label $cur
	foreach it $items { if {[lindex $it 0] eq $cur} { set label [lindex $it 1] } }
	set open [expr {$pop eq $id}]
	ui::box $x $by $w 32 -fill $c(field) -radius 8 -ring [list [expr {$open ? $c(accent) : $c(border)}] [expr {$open ? 1.5 : 1}]]
	set tx [expr {$x + 12}]
	if {$icon ne ""} { ui::icon $icon 14 $c(muted) $tx [expr {$by + 9}]; set tx [expr {$tx + 22}] }
	ui::text $tx [expr {$by + 8}] [clip $label [expr {$x + $w - 30 - $tx}]] i13 $c(fg) w 0 {} 1
	ui::icon sctl_chev 14 $c(muted) [expr {$x + $w - 24}] [expr {$by + 9}] 2
	set d [dict create x $x y $by w $w items $items cur $cur script $script]
	sctl::hit $x $by $w 32 [list sctl::pop_toggle $id $d]
	ui::focusable $id list $x $by $w 32 8 [list sctl::dropdown_key $id $d]
}
# On the closed dropdown: Return or Space opens it, Up and Down step the value.
proc sctl::dropdown_key {id d sym} {
	set vals [lmap it [dict get $d items] { lindex $it 0 }]
	set i [lsearch -exact $vals [dict get $d cur]]
	switch -- $sym {
		Return - KP_Enter - space { pop_toggle $id $d; page::draw; return 1 }
		Up { set i [expr {max(0, $i - 1)}] }
		Down { set i [expr {min([llength $vals] - 1, $i + 1)}] }
		default { return 0 }
	}
	uplevel #0 [list {*}[dict get $d script] [lindex $vals $i]]
	page::draw
	return 1
}
proc sctl::pop_toggle {id d} {
	variable pop; variable popd; variable ROWS; variable typed
	if {$pop eq $id} { set pop ""; return }
	set pop $id
	set vals [lmap it [dict get $d items] { lindex $it 0 }]
	set i [expr {max(0, [lsearch -exact $vals [dict get $d cur]])}]
	dict set d idx $i
	dict set d top [expr {max(0, min([llength $vals] - $ROWS, $i - $ROWS / 2))}]
	set popd $d
	set typed ""
	set ui::focus sctl-pop
}
proc sctl::pop_close {} { variable pop ""; page::draw }
proc sctl::pop_pick {i} {
	variable pop; variable popd
	set d $popd
	set pop ""
	uplevel #0 [list {*}[dict get $d script] [lindex [dict get $d items] $i 0]]
	page::draw
}
proc sctl::pop_move {i} {
	variable popd; variable ROWS
	set n [llength [dict get $popd items]]
	set i [expr {max(0, min($n - 1, $i))}]
	dict set popd idx $i
	set top [dict get $popd top]
	if {$i < $top} { set top $i } elseif {$i >= $top + $ROWS} { set top [expr {$i - $ROWS + 1}] }
	dict set popd top $top
}
proc sctl::pop_scroll {d} {
	variable popd; variable ROWS
	set n [llength [dict get $popd items]]
	dict set popd top [expr {max(0, min(max(0, $n - $ROWS), [dict get $popd top] + 3 * $d))}]
	page::draw
}
# Keys in the open list: Up, Down, Page Up/Down, Home, End move; Return picks; Escape closes; letters jump to the
# first item that starts with what was typed in the last second (else one that contains it).
proc sctl::pop_key {sym {char ""}} {
	variable popd; variable ROWS; variable typed; variable typedat
	set i [dict get $popd idx]
	switch -- $sym {
		Up { pop_move [expr {$i - 1}] }
		Down { pop_move [expr {$i + 1}] }
		Prior { pop_move [expr {$i - $ROWS}] }
		Next { pop_move [expr {$i + $ROWS}] }
		Home { pop_move 0 }
		End { pop_move 100000 }
		Return - KP_Enter { pop_pick $i; return 1 }
		Escape { pop_close; return 1 }
		default {
			if {$char eq "" || ![string is print -strict $char]} { return 0 }
			set now [clock milliseconds]
			if {$now - $typedat > 1000} { set typed "" }
			set typedat $now
			append typed [string tolower $char]
			set labels [lmap it [dict get $popd items] { string tolower [lindex $it 1] }]
			set j [lsearch -glob $labels "$typed*"]
			if {$j < 0} { set j [lsearch -glob $labels "*$typed*"] }
			if {$j >= 0} { pop_move $j }
		}
	}
	page::draw
	return 1
}
proc sctl::pop_draw {} {
	variable pop; variable popd; variable ROWS
	array set c [array get ui::c]
	set items [dict get $popd items]
	set n [llength $items]
	set shown [expr {min($n, $ROWS)}]
	set x [dict get $popd x]; set y [dict get $popd y]
	set w [expr {max([dict get $popd w], 190)}]
	foreach it $items { set w [expr {max($w, int(ceil(36 + [ui::measure i13s [lindex $it 1]] + 36)))}] }
	set w [expr {min($w, 420)}]
	if {$x + $w > 1090} { set x [expr {1090 - $w}] }
	set h [expr {12 + 36 * $shown}]
	set top [expr {$y + 38}]
	if {$top + $h > 708} { set top [expr {$y - 6 - $h}] }
	ui::layer
	ui::hit 0 0 1100 720 {apply {{x y} { sctl::pop_close }}}
	raster::box $ui::img [expr {round($x)}] [expr {round($top)}] $w $h -fill $c(bar) -radius 12 -ring [list $c(border) 1] -shadow {16 40 0.5}
	set first [dict get $popd top]
	for {set k 0} {$k < $shown} {incr k} {
		set i [expr {$first + $k}]
		lassign [lindex $items $i] v label
		set iy [expr {$top + 6 + 36 * $k}]
		if {$i == [dict get $popd idx]} { ui::box [expr {$x + 6}] $iy [expr {$w - 12}] 36 -fill $c(field) -radius 8 }
		set on [expr {$v eq [dict get $popd cur]}]
		set f [expr {$on ? "i13s" : "i13m"}]
		ui::text [expr {$x + 18}] [expr {$iy + 10}] [clip $label [expr {$w - 60}] $f] $f $c(fg) w 0 {} 1
		if {$on} { ui::icon sctl_check 14 $c(accent) [expr {$x + $w - 32}] [expr {$iy + 11}] 2.4 }
		ui::hit [expr {$x + 6}] $iy [expr {$w - 12}] 36 [list apply {{i x y} { sctl::pop_pick $i }} $i]
	}
	# more above or below: a 3 px thumb at the list's right edge
	if {$n > $shown} {
		set th [expr {max(18.0, ($h - 16) * $shown / double($n))}]
		set ty [expr {$top + 8 + ($h - 16 - $th) * $first / double($n - $shown)}]
		ui::box [expr {$x + $w - 6}] $ty 3 $th -fill $c(pill) -radius 1.5
	}
	ui::wheel $x $top $w $h sctl::pop_scroll
	ui::focusable sctl-pop list $x $top $w $h 12 sctl::pop_key
}

# ---- sheets --------------------------------------------------------------------------------------

proc sctl::sheet_open {name {onclose ""}} {
	variable sheet $name
	variable cancel $onclose
	variable pop ""
	set ::page::shade 0.5
	set ui::focus ""
	page::draw
}
proc sctl::sheet_close {} {
	variable sheet ""
	variable cancel ""
	set ::page::shade 0
	set ui::focus ""
	page::draw
}
# The sheet's box (W x H, centred in the window, radius 16, ringed, with its shadow), the tile with ICON, TITLE
# (Space Grotesk 20) and SUB (13 px muted), and the rule under them. Clicks outside the sheet do nothing.
proc sctl::sheet {w h icon title sub} {
	array set c [array get ui::c]
	set x [expr {(1100 - $w) / 2}]; set y [expr {(720 - $h) / 2}]
	ui::layer
	raster::box $ui::img $x $y $w $h -fill $c(bar) -radius 16 -ring [list $c(border) 1] -shadow {24 64 0.6}
	ui::hit 0 0 1100 720 {apply {{x y} {}}}
	ui::box [expr {$x + 28}] [expr {$y + 26}] 44 44 -fill $c(pill) -radius 12
	ui::icon $icon 22 $c(fg) [expr {$x + 39}] [expr {$y + 37}] 1.7
	ui::text [expr {$x + 86}] [expr {$y + 25}] [clip $title [expr {$w - 114}] sg20] sg20 $c(fg) w -0.4
	ui::text [expr {$x + 86}] [expr {$y + 53}] [clip $sub [expr {$w - 114}]] i13 $c(muted)
	ui::hline [expr {$x + 28}] [expr {$x + $w - 28}] [expr {$y + 88}] $c(border)
	ui::hline $x [expr {$x + $w}] [expr {$y + $h - 72}] $c(border)
	list $x $y
}

# ---- the page's last call ------------------------------------------------------------------------

proc sctl::overlay {{sheetproc ""}} {
	variable pop; variable sheet
	if {$sheet ne "" && $sheetproc ne ""} {
		# the page was drawn shaded (page::shade); the sheet itself is not
		set ui::dim 0
		uplevel #0 [list {*}$sheetproc $sheet]
	}
	if {$pop ne ""} { set ui::dim 0; pop_draw }
}
proc sctl::escape {} {
	variable pop; variable sheet; variable cancel
	if {$pop ne ""} { pop_close; return 1 }
	if {$sheet ne ""} {
		set c $cancel
		sheet_close
		if {$c ne ""} { uplevel #0 $c }
		return 1
	}
	return 0
}
# Leaving a page: nothing of it stays open.
proc sctl::reset {} {
	variable pop ""; variable sheet ""; variable cancel ""
	set ::page::shade 0
}
