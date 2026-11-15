# dialogs.tcl - questions and messages drawn in the app's own style (as the
# installer's: the page shaded, a 420 px card), and the file dialogs.

namespace eval dlg {}

# Ask before something that can't be undone: TITLE, TEXT, the button's
# LABEL and the SCRIPT it runs.
proc dlg::confirm {title text label script {danger 0}} {
	set page::dialog [dict create kind confirm title $title text $text label $label script $script]
	set ui::focus dcancel
	page::draw
}

proc dlg::message {title text} {
	set page::dialog [dict create kind message title $title text $text label OK script ""]
	set ui::focus dok
	page::draw
}

proc dlg::close {} {
	set page::dialog ""
	set ui::focus ""
	page::draw
}

proc dlg::ok {} {
	set s [dict get $page::dialog script]
	set page::dialog ""
	set ui::focus ""
	if {$s ne ""} { uplevel #0 $s }
	page::draw
}

proc dlg::draw {} {
	set d $page::dialog
	array set c [array get ui::c]
	# only the dialog takes clicks and Tab while it is open
	set ui::hits {}; set ui::wheels {}; set ui::focusables {}
	ui::layer
	set w 420; set x [expr {230 + (870 - $w) / 2}]
	set lines {}
	foreach para [split [dict get $d text] \n] { lappend lines {*}[ui::wrap i14 $para [expr {$w - 48}]] }
	set h [expr {68 + 21 * [llength $lines] + 24 + 38 + 24}]
	# centred in the window: its height is page::WH where the host has one (Properties: 600 for an app that is not a kit)
	set y [expr {([expr {[info exists ::page::WH] ? $::page::WH : 720}] - $h) / 2}]
	ui::box $x $y $w $h -fill $c(bar) -radius 16 -ring [list $c(border) 1]
	ui::hit $x $y $w $h ""
	ui::text [expr {$x + 24}] [expr {$y + 22}] [dict get $d title] sg24 $c(fg) w -0.48
	set ty [expr {$y + 68}]
	foreach line $lines { ui::text [expr {$x + 24}] [ui::lh $ty i14 21] $line i14 $c(muted); set ty [expr {$ty + 21}] }
	set by [expr {$y + $h - 24 - 38}]
	set bw [ui::button_w [dict get $d label] primary]
	set bx [expr {$x + $w - 24 - $bw}]
	ui::button dok $bx $by [dict get $d label] primary dlg::ok "" $bw
	if {[dict get $d kind] eq "confirm"} {
		set cw [ui::button_w Cancel ghost]
		ui::button dcancel [expr {$bx - 10 - $cw}] $by Cancel ghost dlg::close "" $cw
	}
	ui::focus_ring
}

proc dlg::key {sym char state} {
	set f [ui::focused]
	switch -- $sym {
		Escape { close; return }
		Return - KP_Enter - space {
			if {[lindex $f 1] eq "button"} { uplevel #0 [lindex $f 7] } else { ok }
			return
		}
		Tab - Left - Right { ui::cycle 1; return }
		ISO_Left_Tab { ui::cycle -1; return }
	}
}

# ---- file dialogs ----------------------------------------------------------

# Ribbon's own file chooser (chooser.tcl, boards Chooser-*), not Tk's stock dialogs.
source -encoding utf-8 [file join [file dirname [file normalize [info script]]] chooser.tcl]

proc dlg::save_file {title initial} {
	chooser::save_file -parent $app::win -title $title -initialfile $initial \
		-initialdir [store::env HOME /] -defaultextension .ribbon-theme \
		-filetypes {{{Ribbon themes} {.ribbon-theme}} {{All files} *}}
}

proc dlg::parent {} {
	expr {[winfo exists .sheet] && [winfo ismapped .sheet] ? ".sheet" : $app::win}
}

proc dlg::open_file {title types {dir ""} {multiple 0}} {
	if {$dir eq ""} { set dir [store::env HOME /] }
	chooser::open_file -parent [parent] -title $title -initialdir $dir -filetypes $types -multiple $multiple
}

proc dlg::choose_dir {title {dir ""}} {
	if {$dir eq "" || ![file isdirectory $dir]} { set dir [store::env HOME /] }
	chooser::choose_folder -parent [parent] -title $title -initialdir $dir -mustexist 1
}
