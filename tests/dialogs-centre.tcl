# dialogs-centre.tcl - appearance/dialogs.tcl's card is centred in its window's height: page::WH where the host
# sets one (Properties: 600 for an app that is not a kit, Props-A9-NotKit), else 720. dlg::draw runs here with the
# ui primitives stood in for (they record the card's box); tclsh, no display. Run by tests/steps.d/52-dialogs-centre.sh.
set fails 0
proc check {what ok} {
	global fails
	if {[uplevel 1 [list expr $ok]]} { puts "  ok   dialogs: $what" } else { puts "  FAIL dialogs: $what"; incr fails }
}
set src [file join [file dirname [file normalize [info script]]] .. srcpkgs ribbon-desktop files appearance dialogs.tcl]
set fh [open $src]; fconfigure $fh -encoding utf-8; set text [read $fh]; close $fh
# only dlg::draw (the file also sources the chooser, which needs Tk)
if {![regexp {\nproc dlg::draw \{\} \{\n.*?\n\}\n} $text body]} { puts "  FAIL dialogs: dlg::draw not found"; exit 1 }
namespace eval dlg {}
namespace eval page { variable dialog "" }
namespace eval ui {
	variable c; array set c {bar #111 border #222 fg #eee muted #999}
	variable hits {} wheels {} focusables {} boxes {}
	proc layer {} {}
	proc wrap {font text w} { list $text }
	proc box {x y w h args} { variable boxes; lappend boxes [list $x $y $w $h] }
	proc hit {args} {}
	proc text {args} {}
	proc lh {y args} { return $y }
	proc button_w {args} { return 80 }
	proc button {args} {}
	proc focus_ring {} {}
}
eval $body
proc card {} {
	set ui::boxes {}
	set page::dialog [dict create kind message title "Couldn't update it" text "One line" label OK script ""]
	dlg::draw
	lindex $ui::boxes 0
}
lassign [card] x y w h
check "without page::WH the card is centred in 720 px" {$y == (720 - $h) / 2}
set ::page::WH 600
lassign [card] x y w h
check "with page::WH 600 the card is centred in 600 px (y [expr {(600 - $h) / 2}])" {$y == (600 - $h) / 2}
set ::page::WH 720
lassign [card] x y w h
check "with page::WH 720 the card is centred in 720 px" {$y == (720 - $h) / 2}
if {$fails} { puts "dialogs: $fails check(s) failed"; exit 1 }
puts "dialogs: all checks passed"
