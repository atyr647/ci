# sheet.tcl - Text editor (U26): the close sheet (Editor-Final-5). Kit's sheet style: 640 wide, centred on the
# window, a 50 % black veil behind it, a row per document with unsaved changes (checkbox, name, folder, lines
# changed), and the footer: Don't save (field) on the left; Cancel (ghost) and "Save N and close" (primary).
#
# A checked row is saved before its document closes; an unchecked row is closed without saving. Cancel keeps
# every document open. Enter is "Save N and close"; Escape is Cancel.

namespace eval sheet {
	variable ids {}       ;# the dirty documents listed
	variable chk {}       ;# 1 or 0 for each of ids
	variable closing {}   ;# every document the close is for (the listed ones and the clean ones)
}

# Open the sheet for ids (the dirty ones), closing CLOSING when it is answered.
proc sheet::show {ids closing} {
	set sheet::ids $ids
	set sheet::chk {}
	foreach i $ids { lappend sheet::chk 1 }
	set sheet::closing $closing
	set editor::sheet 1
	editor::focus_none
	editor::paint
}

proc sheet::hide {} {
	set editor::sheet 0
	editor::focus_text
	editor::paint
}

proc sheet::toggle {k x y} {
	variable chk
	lset chk $k [expr {![lindex $chk $k]}]
	editor::paint
}

proc sheet::count {} {
	variable chk
	set n 0
	foreach c $chk { incr n $c }
	return $n
}

# Save the checked documents, then close everything the close was for. A document that cannot be saved keeps
# the window open, as does Cancel.
proc sheet::answer {how} {
	variable ids
	variable chk
	variable closing
	if {$how eq "cancel"} { set editor::quitting 0; hide; return }
	if {$how eq "save"} {
		foreach id $ids c $chk {
			if {!$c} continue
			if {![editor::save_doc $id]} { hide; return }
		}
	}
	hide
	foreach id $closing { editor::force_close $id }
	editor::after_close
}

proc sheet::paint {} {
	variable ids
	variable chk
	set W $editor::W; set H $editor::H
	set w 640
	set rows [llength $ids]
	set h [expr {26 + 44 + 18 + 52 * $rows + 72}]
	set x0 [expr {($W - $w) / 2}]
	set y0 [expr {($H - $h) / 2}]
	ui::fbox 0 0 $W $H -fill #000000 -alpha 0.5
	ui::box $x0 $y0 $w $h -fill $editor::c(bar) -radius 16
	ui::ring $x0 $y0 $w $h 16 $editor::c(border) 1
	ui::box [expr {$x0 + 28}] [expr {$y0 + 26}] 40 40 -fill $editor::c(field) -radius 10
	editor::icon save 20 $editor::c(fg) [expr {$x0 + 38}] [expr {$y0 + 36}]
	ui::text [expr {$x0 + 82}] [expr {$y0 + 26}] "Save changes before closing?" sg20 $editor::c(fg)
	ui::text [expr {$x0 + 82}] [expr {$y0 + 52}] "[llength $ids] documents have unsaved changes" i13 $editor::c(muted)
	set ry [expr {$y0 + 26 + 44 + 18}]
	ui::box [expr {$x0 + 28}] [expr {$ry - 1}] 584 1 -fill $editor::c(border)
	set k 0
	foreach id $ids c $chk {
		set on $c
		ui::hit [expr {$x0 + 28}] $ry 584 52 [list sheet::toggle $k]
		checkbox [expr {$x0 + 28}] [expr {$ry + 17}] $on
		ui::text [expr {$x0 + 60}] [expr {$ry + 9}] [doc::name $id] i13s $editor::c(fg)
		ui::text [expr {$x0 + 60}] [expr {$ry + 28}] [doc::folder $id] i12 $editor::c(muted)
		ui::text [expr {$x0 + 612}] [expr {$ry + 19}] "[doc::changed_lines $id] lines changed" i13 $editor::c(muted) e
		if {$k < $rows - 1} { ui::box [expr {$x0 + 28}] [expr {$ry + 51}] 584 1 -fill $editor::c(border) }
		incr ry 52
		incr k
	}
	set fy [expr {$y0 + $h - 72}]
	ui::box $x0 $fy $w 1 -fill $editor::c(border)
	set by [expr {$fy + 17}]
	ui::button sheet-dont [expr {$x0 + 28}] $by "Don’t save" field [list sheet::answer discard]
	set n [count]
	set label "Save $n and close"
	set bw [ui::button_w $label primary save]
	set px [expr {$x0 + $w - 28 - $bw}]
	ui::button sheet-save $px $by $label primary [list sheet::answer save]
	set cw [ui::button_w Cancel ghost]
	ui::button sheet-cancel [expr {$px - 10 - $cw}] $by Cancel ghost [list sheet::answer cancel]
}

# A 18 px checkbox: accent with a check when on, a ring when off.
proc sheet::checkbox {x y on} {
	if {$on} {
		ui::box $x $y 18 18 -fill $editor::c(accent) -radius 5
		editor::icon check 12 $editor::c(on_accent) [expr {$x + 3}] [expr {$y + 3}]
	} else {
		ui::ring $x $y 18 18 5 $editor::c(border) 1.5
	}
}
