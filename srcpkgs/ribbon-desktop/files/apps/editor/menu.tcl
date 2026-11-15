# menu.tcl - Text editor (U30, U31): a small menu card, for the ⋯ menu and the Welcome page's context menus. Its canvas
# is raised above the page, as the find bar's options menu is (find.tcl), because the page is a Tk widget. A row runs
# its script and closes the menu; a press anywhere else closes it (editor::text_press, page::clicked_outside).
#
#   menu::show X Y ROWS     ROWS: {LABEL SCRIPT ?ICON? ?KEYS?} ..., "-" a rule between groups
#   menu::more X Y          the ⋯ menu of the strip pressed at X (boards Editor-R4-1-More, -3-More-Split, -4-More-Welcome)
#
# The card is the Terminal tab menu's (Term-E-3-Menu; gen_editor_r4.py menu()): §field, radius 10 with a 1 px §border
# ring, 6 px padding, 34 px rows, a rule's 11 px (1 px §border, 4 in from the rows' sides). A row with an icon has it at
# 16 (15 px, §muted; §fg on the row under the pointer), the label at 41 in 13/500 and its keys at the right in 12/500
# §muted; a menu of rows without icons (the Welcome page's) is 220 wide with the label at 16. The row under the pointer
# is raised in §pill (radius 8).

namespace eval menu {
	variable open 0
	variable items {}
	variable at {0 0}
	variable canvas .w.mn
	variable img ""
	variable hover -1
	variable RH 34
	variable MW 220
}

# The rows' tops in the card, and its height.
proc menu::layout {} {
	variable items
	variable RH
	set y 6
	set tops {}
	foreach it $items {
		lappend tops $y
		incr y [expr {$it eq "-" ? 11 : $RH}]
	}
	list $tops [expr {$y + 6}]
}

proc menu::width {rows} {
	foreach it $rows { if {$it ne "-" && [lindex $it 2] ne ""} { return 260 } }
	return 220
}

proc menu::show {x y rows} {
	variable open; variable items; variable at; variable MW; variable hover
	set items $rows
	set open 1
	set hover -1
	set MW [width $rows]
	set h [lindex [layout] 1]
	set mx [expr {max(0, min($x, $::editor::W - $MW - 4))}]
	set my [expr {max(0, min($y, $::editor::H - $h - 4))}]
	set at [list $mx $my]
	editor::schedule
}

# The ⋯ menu of the strip pressed at X: the Welcome page's (nothing open), a split pane's, or the single window's. It
# opens 6 under the strip, its right edge on the ⋯ button's (tabs.tcl draws the button 32 wide: at W - 150 on the
# Welcome strip, at W - 215 + 64 in the unsplit window, 40 in from a pane's right edge).
proc menu::more {x y} {
	set W $::editor::W
	if {![llength [split::union]]} {
		set right [expr {$W - 150 + 32}]
		set rows [list [list "Open…" {editor::cmd open} folder "Ctrl O"] [list "New document" {editor::cmd new} filenew "Ctrl N"]]
	} elseif {[split::is_split]} {
		set p [split::pane_at $x]
		if {$p != $split::cur} { split::focus_to $p }
		set right [expr {[split::px $p] + [split::pw $p] - 40 + 32}]
		set rows [list [list Save {editor::cmd save} msave "Ctrl S"] [list "Save as…" {editor::cmd saveas} saveas "Ctrl Shift S"] - \
			[list "Go to line…" {editor::cmd goto} goto "Ctrl L"] [list "Move to other side" {split::move_other} swap ""] - \
			[list "Close pane" {split::close_pane} x ""]]
	} else {
		set right [expr {$W - 215 + 96}]
		set rows [list [list "Open…" {editor::cmd open} folder "Ctrl O"] [list Save {editor::cmd save} msave "Ctrl S"] \
			[list "Save as…" {editor::cmd saveas} saveas "Ctrl Shift S"] - \
			[list "Go to line…" {editor::cmd goto} goto "Ctrl L"] [list "Split view" {editor::cmd split} msplit "Ctrl \\"] - \
			[list Close {editor::cmd close} x "Ctrl W"]]
	}
	show [expr {$right - [width $rows]}] 52 $rows
}

proc menu::hide {} {
	variable open; variable canvas
	set open 0
	if {[winfo exists $canvas]} { place forget $canvas }
}

proc menu::draw {} {
	variable canvas; variable img; variable items; variable MW; variable RH; variable hover
	lassign [layout] tops h
	if {![winfo exists $canvas]} {
		canvas $canvas -width $MW -height $h -highlightthickness 0 -borderwidth 0 -takefocus 0 \
			-background $::editor::c(bar)
		bind $canvas <ButtonPress-1> {menu::click %x %y}
		bind $canvas <Motion> {menu::motion %y}
		bind $canvas <Leave> {menu::motion -1}
	}
	$canvas configure -width $MW -height $h
	$canvas delete all
	if {$img ne ""} { catch {image delete $img} }
	set img [image create photo -width $MW -height $h]
	raster::box $img 0 0 $MW $h -fill $::editor::c(field) -radius 10 -ring [list $::editor::c(border) 1]
	set k 0
	foreach it $items top $tops {
		if {$it eq "-"} {
			$img put [ui::col $::editor::c(border)] -to 10 [expr {$top + 5}] [expr {$MW - 10}] [expr {$top + 6}]
		} elseif {$k == $hover} {
			raster::box $img 6 $top [expr {$MW - 12}] $RH -fill $::editor::c(pill) -radius 8
		}
		incr k
	}
	$canvas create image 0 0 -image $img -anchor nw
	set saved $::ui::cv
	set ::ui::cv $canvas
	set k 0
	foreach it $items top $tops {
		if {$it ne "-"} {
			lassign $it label script icon keys
			set lx 16
			if {$icon ne ""} {
				set i [raster::icon $::editor::paths($icon) 15 2 [ui::col [expr {$k == $hover ? $::editor::c(fg) : $::editor::c(muted)}]]]
				$canvas create image 16 [expr {round($top + 9.5)}] -image $i -anchor nw
				set lx 41
			}
			ui::text $lx [ui::lh $top i13m $RH] $label i13m $::editor::c(fg)
			if {$keys ne ""} { ui::text [expr {$MW - 16}] [ui::lh $top i12m $RH] $keys i12m $::editor::c(muted) e }
		}
		incr k
	}
	set ::ui::cv $saved
}

# Drawn above the page whenever it is open (called at the end of each paint).
proc menu::lift {} {
	variable open; variable canvas; variable at; variable items
	if {$open && [llength $items]} {
		draw
		place $canvas -x [lindex $at 0] -y [lindex $at 1]
		::raise $canvas
	} else {
		hide
	}
}

# The row at Y (card coordinates), or -1 (a rule, the padding, outside).
proc menu::row_at {y} {
	variable items; variable RH
	set k 0
	foreach it $items top [lindex [layout] 0] {
		if {$it ne "-" && $y >= $top && $y < $top + $RH} { return $k }
		incr k
	}
	return -1
}

proc menu::motion {y} {
	variable hover
	set k [expr {$y < 0 ? -1 : [row_at $y]}]
	if {$k != $hover} { set hover $k; draw }
}

proc menu::click {x y} {
	variable items
	set i [row_at $y]
	if {$i < 0} return
	set script [lindex $items $i 1]
	hide
	uplevel #0 $script
	editor::schedule
}

# The menu's icons beside the window's own (main.tcl's editor::paths).
namespace eval editor {
	variable paths
	array set paths {
		saveas {M12 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v3 M7 3v5h8 M7 21v-6h5 M20.4 13.6a1.4 1.4 0 0 1 2 2L17 21l-3 .7.7-3z}
		filenew {M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z M14 3v5h5 M12 11v6 M9 14h6}
		msave {M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z M17 21v-8H7v8 M7 3v5h8}
		msplit {M12 3v18 M3 3h18v18H3z}
		swap {M16 3l4 4-4 4 M20 7H4 M8 21l-4-4 4-4 M4 17h16}
	}
}
