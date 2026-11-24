# editor-window.tcl - the text editor's window: resizing and maximising (run by apps/editor/main.tcl through
# RIBBON_EDITOR_SCENE=this file, with RIBBON_EDITOR_FIXTURES = a temp folder).
# 1. (any X server) the window resized to 1600 x 1000 lays itself out for it: the canvas, the page and the Well fill it,
#    the strip's right cluster and the status line's path keep to the right edge, the drawn page has rows to the
#    bottom; back to 1240 x 780 it is the board's layout again; a size under 900 x 600 is not laid out.
# 2. (RIBBON_EDITOR_WM=labwc: a headless labwc with Xwayland) the window, managed by labwc, has no fixed size; a click on
#    its own maximise button (the strip's, drawn when labwc does not frame it) makes labwc maximise it to the output, and
#    a second click gives it back its size.
# Prints "  ok ..." per check; exits 0 when all pass, 1 otherwise.
set dir $::env(RIBBON_EDITOR_FIXTURES)
file mkdir $dir
set fails 0
proc ok {what} { puts "  ok   $what"; flush stdout }
proc check {what cond} {
	if {[uplevel 1 [list expr $cond]]} { ok $what } else { global fails; incr fails; puts "  FAIL $what" }
}
proc bgerror {msg} { puts stderr "editor-window: $msg\n$::errorInfo"; exit 1 }
proc wait_until {cond ms} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel 1 [list expr $cond]]} {
		if {[clock milliseconds] > $end} { return 0 }
		after 20
		update
	}
	return 1
}
proc write_text {path text} {
	set fh [open $path wb]
	fconfigure $fh -translation binary
	puts -nonewline $fh [encoding convertto utf-8 $text]
	close $fh
}
# the hit whose press script is SCRIPT: {x y w h}, or ""
proc hit_of {script} {
	foreach h $::ui::hits {
		lassign $h x0 y0 x1 y1 press
		if {$press eq $script} { return [list $x0 $y0 [expr {$x1 - $x0}] [expr {$y1 - $y0}]] }
	}
	return ""
}
# the x of the right edge of status-line text STR as well::status draws it (ui::text is wrapped to record it), or ""
proc status_right {str} {
	set ::right ""
	rename ui::text ui::text_real
	proc ui::text {x top s args} {
		if {$s eq $::want} { set ::right [expr {$x + [ui::measure [lindex $args 0] $s]}] }
		ui::text_real $x $top $s {*}$args
	}
	set ::want $str
	well::status $split::cur
	rename ui::text {}
	rename ui::text_real ui::text
	return $::right
}

set lines {}
for {set i 1} {$i <= 80} {incr i} { lappend lines "line $i" }
set p [file join $dir long.txt]
write_text $p [join $lines \n]\n
set id [editor::open_path $p]
editor::paint
update
set win $::editor::win

if {![info exists ::env(RIBBON_EDITOR_WM)]} {
	puts "resize"
	wm geometry $win 1600x1000
	check "resized to 1600 x 1000: the editor lays out for it" {[wait_until {$::editor::W == 1600 && $::editor::H == 1000} 3000]}
	editor::paint; update; editor::paint; update
	check "the canvas fills the window" {[winfo width $::editor::cv] == 1600 && [winfo height $::editor::cv] == 1000}
	check "the page takes the width less the Well, and the height less the strip and the status line" {
		[winfo width $::editor::page] == 1600 - 72 && [winfo height $::editor::page] == 1000 - 46 - 32}
	check "the Well runs down to the status line" {[winfo height $::editor::gut] == 1000 - 46 - 32}
	check "the strip's search button keeps to the right edge (215 in)" {[lindex [hit_of editor::find_open] 0] == 1600 - 215}
	check "the tabs may run to the cluster (the strip's tab region grows)" {[tabs::region 0] == 1600 - 333}
	set path [::doc::folder $id]/long.txt
	check "the status line is at the bottom and its path ends 16 px from the right" {[status_right $path] ne "" && abs([status_right $path] - (1600 - 16)) <= 2}
	# the open-documents list draws the page as canvas text: it has rows down to the status line
	editor::toggle_pop
	editor::paint; update
	set last 0
	foreach item [$::editor::cv find all] {
		if {[$::editor::cv type $item] eq "text" && [string match "line *" [$::editor::cv itemcget $item -text]]} {
			set last [expr {max($last, [lindex [$::editor::cv bbox $item] 3])}]
		}
	}
	check "the drawn page (under the list) has text rows down to the status line" {$last > 1000 - 32 - 30 && $last <= 1000 - 32 + 4}
	editor::close_pop
	wm geometry $win 1240x780
	check "back to 1240 x 780: the board's layout" {[wait_until {$::editor::W == 1240 && $::editor::H == 780} 3000]}
	editor::paint; update
	check "the search button is at 1025 again" {[lindex [hit_of editor::find_open] 0] == 1025}
	editor::resized 800 500
	check "a size under 900 x 600 is not laid out" {$::editor::W == 1240 && $::editor::H == 780}
} else {
	puts "maximise (labwc)"
	# a scene's window is bare (override-redirect); here labwc manages it, as the real one is
	wm withdraw $win
	wm overrideredirect $win 0
	wm minsize $win 900 600
	wm geometry $win 1240x780+20+20
	wm deiconify $win
	check "labwc maps the window" {[wait_until {[winfo ismapped $win] && [winfo width $win] == 1240} 5000]}
	editor::paint; update
	set h [hit_of editor::maximize]
	check "the strip draws its own maximise button (labwc does not frame this window)" {$h ne ""}
	set sw [winfo screenwidth $win]
	lassign $h hx hy hw hh
	event generate $::editor::cv <ButtonPress-1> -x [expr {$hx + 10}] -y [expr {$hy + 10}]
	event generate $::editor::cv <ButtonRelease-1> -x [expr {$hx + 10}] -y [expr {$hy + 10}]
	check "a click on it: labwc maximises the window to the output's width" {[wait_until {[winfo width $win] == $sw} 5000]}
	check "and the editor is laid out for the new size" {[wait_until {$::editor::W == $sw && [winfo width $::editor::cv] == $sw} 3000]}
	check "the window manager says it is maximised" {[wm attributes $win -zoomed] == 1}
	editor::paint; update
	set h [hit_of editor::maximize]
	lassign $h hx hy hw hh
	event generate $::editor::cv <ButtonPress-1> -x [expr {$hx + 10}] -y [expr {$hy + 10}]
	event generate $::editor::cv <ButtonRelease-1> -x [expr {$hx + 10}] -y [expr {$hy + 10}]
	check "a second click gives it back its size" {[wait_until {[winfo width $win] == 1240 && $::editor::W == 1240} 5000]}
}

if {$fails} { puts "editor window: $fails checks failed"; exit 1 }
puts "editor window: all checks passed"
exit 0
