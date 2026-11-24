# welcome.tcl - Text editor (U31): the Welcome page (Editor-Final-6-Welcome-B), shown whenever nothing is open. Title,
# subtitle "Nothing open · N pinned · M recent", up to four pinned cards (the first nine lines of each file in mono, over
# its name and folder), the recent files in two columns filled column by column (12 entries, relative times), and the
# footer with Open folder… (left), Open… and New document (right). Open folder… picks a folder and opens the file chooser
# there; the folder is remembered as where the chooser starts next time (DECISIONS-DELEGATED 41: no project model).
#
# Pins: the state folder's "pinned" file, a Tcl list of paths, at most four, in order. Recent: the editor's recent file.
# Click a card or a row to open it; drag a card to reorder; right-click for the menu: a card's is Unpin, a row's is Pin
# or Unpin and Remove from recent (the boards show no menu; these are the only entries the spec names). A missing file
# is shown muted and cannot be opened. Long folder paths fade out at their clip edge. Geometry is in window coordinates
# (40 px margins).

namespace eval welcome {
	variable pins {}
	variable MAXPIN 4
	variable NREC 12
	variable CW 279          ;# card width
	variable CSTEP 294       ;# card pitch
	variable CTOP 182
	variable CH 220
	variable RH 40           ;# recent row height
	variable LEFT 40
	variable COLX {40 636}
	variable COLW 564
	variable mini ""         ;# the preview's mono face (11 px)
}

proc editor::welcome_install {} {
	set ::ui::fonts(sg28) {{Ribbon Space Grotesk 600} 28 0.984 0.292}
	set welcome::mini [font create ribbon-editor-mini -family $::editor::mono -size -11]
	welcome::load_pins
}

proc welcome::pins_file {} { file join [file dirname [::doc::state_file]] pinned }

proc welcome::load_pins {} {
	variable pins
	set pins {}
	if {[catch {set fh [open [pins_file] r]; set text [read $fh]; close $fh}]} return
	foreach p $text {
		if {[string index $p 0] eq "/" && $p ni $pins} { lappend pins $p }
	}
	set pins [lrange $pins 0 3]
}

proc welcome::save_pins {} {
	variable pins
	catch {
		set f [pins_file]
		file mkdir [file dirname $f]
		set fh [open $f w]
		puts $fh $pins
		close $fh
	}
}

proc welcome::pin {p} {
	variable pins; variable MAXPIN
	if {[llength $pins] < $MAXPIN && $p ni $pins} { lappend pins $p; save_pins }
	editor::schedule
}

proc welcome::unpin {p} {
	variable pins
	set pins [lsearch -exact -all -inline -not $pins $p]
	save_pins
	editor::schedule
}

proc welcome::move_pin {i j} {
	variable pins
	set p [lindex $pins $i]
	set pins [lreplace $pins $i $i]
	set pins [linsert $pins $j $p]
	save_pins
	editor::schedule
}

proc welcome::recent {} {
	variable NREC
	lrange [::doc::recent_load] 0 [expr {$NREC - 1}]
}

proc welcome::remove_recent {p} {
	set list [lsearch -exact -all -inline -not [::doc::recent_load] $p]
	catch {
		set fh [open [::doc::state_file] w]
		puts $fh $list
		close $fh
	}
	editor::schedule
}

proc welcome::open_file {p} {
	if {[file isfile $p]} { editor::open_path $p }
}

proc welcome::open_btn {args} { editor::cmd open }

# Open folder…: the folder chooser (starting at the remembered folder, else home); a folder chosen becomes where the
# file chooser starts, and the file chooser opens there.
proc welcome::folder_btn {args} {
	set d [chooser::choose_folder -parent $::editor::win -initialdir [::doc::start_dir] -mustexist 1 -title "Open folder"]
	if {$d eq ""} return
	::doc::set_start_dir $d
	editor::open_dialog
}
proc welcome::new_btn {args} { editor::cmd new }
proc welcome::press_pin {i x y} { }
proc welcome::press_row {p x y} { open_file $p }

# A pinned card's release: the card it was dropped on (the same card opens the file, another moves it there).
proc welcome::drop_pin {i x y} {
	variable pins; variable LEFT; variable CSTEP
	set n [llength $pins]
	set j [expr {int(($x - $LEFT) / $CSTEP)}]
	set j [expr {max(0, min($n - 1, $j))}]
	if {$j == $i} {
		open_file [lindex $pins $i]
	} else {
		move_pin $i $j
	}
}

# The shell of the welcome page's sizes: the recent heading's y depends on whether any card is shown.
proc welcome::recent_label_y {} {
	variable pins
	expr {[llength $pins] ? 420 : 162}
}

# "Relative" time for a file's modification, against NOW (default: the clock): Today / Yesterday with the time, a
# weekday within the week, then a date.
proc welcome::when {mtime {now ""}} {
	if {$now eq ""} { set now [clock seconds] }
	set day [clock format $mtime -format %Y-%j]
	if {$day eq [clock format $now -format %Y-%j]} { return "Today, [clock format $mtime -format %H:%M]" }
	if {$day eq [clock format [expr {$now - 86400}] -format %Y-%j]} { return "Yesterday, [clock format $mtime -format %H:%M]" }
	if {$now - $mtime < 6 * 86400} { return [clock format $mtime -format %A] }
	set d [string trim [clock format $mtime -format %e]]
	if {[clock format $mtime -format %Y] eq [clock format $now -format %Y]} {
		return "$d [clock format $mtime -format %b]"
	}
	return "$d [clock format $mtime -format {%b %Y}]"
}

# The icon of a file, by its kind (as the tabs' list).
proc welcome::kind {p} {
	switch -- [string tolower [file extension $p]] {
		.tcl - .tk - .json - .py - .c - .h - .sh - .js { return braces }
		.md - .markdown { return hash }
		.ini - .conf - .toml - .desktop - .xml - .cfg { return gear }
		default { return lines }
	}
}

# The first nine lines of P, from its first 4 KB, with tabs as four spaces.
proc welcome::preview {p} {
	if {![file isfile $p]} { return {} }
	if {[catch {
		set fh [open $p r]
		fconfigure $fh -encoding utf-8 -translation lf
		set text [read $fh 4096]
		close $fh
	}]} { return {} }
	set out {}
	foreach line [lrange [split $text \n] 0 8] { lappend out [string map {\t "    "} $line] }
	return $out
}

# TEXT at (X, Y) in font F and colour COL, on background BG, cut at XMAX: the last FW px before the cut fade from COL
# to BG (one canvas item per character, each mixed by its place in the fade). Returns the x where it stopped.
proc welcome::fade {x y text f col bg xmax {fw 36}} {
	set n [string length $text]
	set end $x
	for {set i 0} {$i < $n} {incr i} {
		set px [expr {$x + [ui::measure $f [string range $text 0 [expr {$i - 1}]]]}]
		set cw [ui::measure $f [string index $text $i]]
		# a glyph drawn alone can be wider than its share of the run (kerning, rounding): check both
		if {$px + $cw > $xmax || $x + [ui::measure $f [string range $text 0 $i]] > $xmax} break
		set t [expr {max(0.0, min(1.0, double($px - ($xmax - $fw)) / $fw))}]
		ui::text $px $y [string index $text $i] $f [expr {$t > 0 ? [well::mix $col $bg $t] : $col}] w 0 folderfade
		set end [expr {max($px + $cw, $x + [ui::measure $f [string range $text 0 $i]])}]
	}
	return $end
}

# The folder as the status line shows it (~ for home).
proc welcome::folder {p} {
	set d [file dirname $p]
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : ""}]
	if {$home ne "" && ($d eq $home || [string match "$home/*" $d])} { set d "~[string range $d [string length $home] end]" }
	return $d
}

# What is under (x, y): {pin I}, {row PATH} or {}.
proc welcome::cell {x y} {
	variable pins; variable CTOP; variable CH; variable CSTEP; variable CW; variable LEFT
	variable RH; variable COLX; variable COLW; variable NREC
	if {[llength $pins] && $y >= $CTOP && $y < $CTOP + $CH} {
		set i [expr {int(($x - $LEFT) / $CSTEP)}]
		if {$i >= 0 && $i < [llength $pins] && ($x - $LEFT) - $i * $CSTEP < $CW} { return [list pin $i] }
	}
	set ry0 [expr {[recent_label_y] + 26}]
	if {$y >= $ry0 && $y < $ry0 + 6 * $RH} {
		set col [expr {$x >= [lindex $COLX 1] ? 1 : 0}]
		if {$x >= [lindex $COLX $col] && $x < [lindex $COLX $col] + $COLW} {
			set k [expr {$col * 6 + ($y - $ry0) / $RH}]
			set recent [recent]
			if {$k < [llength $recent]} { return [list row [lindex $recent $k]] }
		}
	}
	return {}
}

# The context menu of a card or a row.
proc welcome::context {x y} {
	variable pins
	set c [cell $x $y]
	if {$c eq ""} return
	lassign $c kind arg
	if {$kind eq "pin"} {
		set p [lindex $pins $arg]
		menu::show $x $y [list [list "Unpin" [list welcome::unpin $p]]]
	} else {
		set rows {}
		if {$arg in $pins} {
			lappend rows [list "Unpin" [list welcome::unpin $arg]]
		} elseif {[llength $pins] < 4} {
			lappend rows [list "Pin" [list welcome::pin $arg]]
		}
		lappend rows [list "Remove from recent" [list welcome::remove_recent $arg]]
		menu::show $x $y $rows
	}
}

# The subtitle: "Nothing open · N pinned · M recent".
proc welcome::subtitle {} {
	variable pins
	return "Nothing open · [llength $pins] pinned · [llength [recent]] recent"
}

# The page: drawn on the window's canvas (no Tk page is up while nothing is open).
proc welcome::paint {} {
	variable pins; variable CW; variable CSTEP; variable CTOP; variable CH; variable RH; variable COLX
	set c $::editor::c(fg)
	set fg $::editor::c(fg); set muted $::editor::c(muted); set field $::editor::c(field)
	set bar $::editor::c(bar); set border $::editor::c(border); set accent $::editor::c(accent)
	set oncol $::editor::c(on_accent)
	set W $::editor::W; set H $::editor::H
	set recent [recent]
	ui::box 0 46 $W [expr {$H - 46}] -fill $bar
	ui::text 40 80 "Text editor" sg28 $fg
	ui::text 40 120 [subtitle] i13 $muted
	if {[llength $pins]} {
		ui::text 40 162 "PINNED" i12 $muted
		for {set i 0} {$i < 4} {incr i} {
			card $i [expr {40 + $i * $CSTEP}] $CTOP $field $bar $border $muted $fg
		}
	}
	set ly [recent_label_y]
	ui::text 40 $ly "RECENT" i12 $muted
	set ry0 [expr {$ly + 26}]
	set k 0
	foreach p $recent {
		set col [expr {$k / 6}]
		set x [lindex $COLX $col]
		set y [expr {$ry0 + ($k % 6) * $RH}]
		row $p $x $y $muted $fg $bar
		incr k
	}
	# the footer sits on the bottom edge (it is 72 px tall when the page is the full 780 px)
	set fy [expr {$H - 72}]
	ui::box 0 $fy $W 1 -fill $border
	# the buttons as Editor-Final-6-Welcome-B: 38 tall, 17 below the rule, 14 px labels, a 15 px icon 8 after the label;
	# Open folder… a ghost (ring only) at the left margin, Open… and New document at the right one
	set by [expr {$fy + 17}]
	set bw [expr {18 + [ui::measure i14 "Open folder…"] + 8 + 15 + 18}]
	ui::hit 40 $by $bw 38 [list welcome::folder_btn]
	ui::ring 40 $by $bw 38 10 $border 1
	ui::text 58 [expr {$by + 10}] "Open folder…" i14 $fg
	editor::icon folderopen 15 $fg [expr {58 + [ui::measure i14 "Open folder…"] + 8}] [expr {$by + 11}] 2
	set nw [expr {18 + [ui::measure i14s "New document"] + 8 + 15 + 18}]
	set nx [expr {$W - 40 - $nw}]
	set ow [expr {18 + [ui::measure i14 "Open…"] + 8 + 15 + 18}]
	set ox [expr {$nx - 10 - $ow}]
	ui::hit $ox $by $ow 38 [list welcome::open_btn]
	ui::box $ox $by $ow 38 -fill $field -radius 10
	ui::ring $ox $by $ow 38 10 $border 1
	ui::text [expr {$ox + 18}] [expr {$by + 10}] "Open…" i14 $fg
	editor::icon folder 15 $fg [expr {$ox + 18 + [ui::measure i14 "Open…"] + 8}] [expr {$by + 11}] 2
	ui::hit $nx $by $nw 38 [list welcome::new_btn]
	ui::box $nx $by $nw 38 -fill $accent -radius 10
	ui::text [expr {$nx + 18}] [expr {$by + 10}] "New document" i14s $oncol
	editor::icon plus 15 $oncol [expr {$nx + 18 + [ui::measure i14s "New document"] + 8}] [expr {$by + 11}] 2
}

# One pinned card at (X, Y): the first nine lines (or "Not found"), the name and the folder under them.
proc welcome::card {i x y field bar border muted fg} {
	variable pins; variable CW; variable CH; variable mini
	ui::box $x $y $CW $CH -fill $field -radius 12
	ui::ring $x $y $CW $CH 12 $border 1
	if {$i >= [llength $pins]} return
	set p [lindex $pins $i]
	set ok [file isfile $p]
	ui::box [expr {$x + 1}] [expr {$y + 1}] [expr {$CW - 2}] 166 -fill $bar
	if {$ok} {
		set ly [expr {$y + 14}]
		foreach line [preview $p] {
			$::editor::cv create text [expr {$x + 14}] $ly -text $line -anchor nw -font $mini -fill $fg -tags page
			incr ly 16
		}
	} else {
		ui::text [expr {$x + 14}] [expr {$y + 14}] "Not found" i12 $muted
	}
	ui::box [expr {$x + 1}] [expr {$y + 167}] [expr {$CW - 2}] 1 -fill $border
	editor::icon [kind $p] 16 [expr {$ok ? $fg : $muted}] [expr {$x + 14}] [expr {$y + 178}]
	ui::text [expr {$x + 38}] [expr {$y + 176}] [file tail $p] i13s [expr {$ok ? $fg : $muted}]
	fade [expr {$x + 38}] [expr {$y + 195}] [folder $p] i12 $muted $field [expr {$x + $CW - 14}]
	ui::hit $x $y $CW $CH [list welcome::press_pin $i] [list editor::noop] [list welcome::drop_pin $i]
}

# One recent row at (X, Y): icon, name, folder and the relative time (right aligned to the column's edge).
proc welcome::row {p x y muted fg {bar ""}} {
	variable COLW; variable RH
	if {$bar eq ""} { set bar $::editor::c(bar) }
	set ok [file isfile $p]
	set col [expr {$ok ? $fg : $muted}]
	editor::icon [kind $p] 16 $col [expr {$x + 2}] [expr {$y + 12}]
	ui::text [expr {$x + 30}] [expr {$y + 11}] [file tail $p] i13s $col
	# the folder runs to the time's left (clipped, with a fade); a missing file has no time
	set xmax [expr {$x + $COLW}]
	if {$ok} {
		set when [when [file mtime $p]]
		ui::text [expr {$x + $COLW}] [expr {$y + 13}] $when i12 $muted e
		set xmax [expr {$x + $COLW - [ui::measure i12 $when] - 24}]
	}
	fade [expr {$x + 152}] [expr {$y + 13}] [folder $p] i12 $muted $bar $xmax
	ui::box $x [expr {$y + $RH - 1}] $COLW 1 -fill $::editor::c(border)
	ui::hit $x $y $COLW $RH [list welcome::press_row $p]
}
