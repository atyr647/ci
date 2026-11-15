# editor-welcome.tcl - the text editor's Welcome page (U31), run by apps/editor/main.tcl through RIBBON_EDITOR_SCENE=this
# file, with RIBBON_EDITOR_FIXTURES = a temp folder (and XDG_STATE_HOME, where the pins are saved).
# 1. Pin and unpin: at most four, saved to the state folder and read back.
# 2. Reorder: a card moved to another place.
# 3. The twelve recent files, filled column by column (the first column's six, then the second's).
# 4. Relative times, against a fixed clock: Today, Yesterday, a weekday within the week, then a date.
# 5. The preview is nine lines; a missing pinned file cannot be opened; the menus hold the spec's entries.
# 6. The subtitle counts; a long folder path is cut at its clip edge with a fade.
# Prints "  ok ..." per check; exits 0 when all pass, 1 otherwise.
set dir $::env(RIBBON_EDITOR_FIXTURES)
file mkdir $dir
set fails 0
proc ok {what} { puts "  ok   $what"; flush stdout }
proc check {what cond} {
	if {[uplevel 1 [list expr $cond]]} { ok $what } else { global fails; incr fails; puts "  FAIL $what" }
}
proc bgerror {msg} { puts stderr "editor-welcome: $msg\n$::errorInfo"; exit 1 }
proc write_text {path text} {
	set fh [open $path wb]
	fconfigure $fh -translation binary
	puts -nonewline $fh [encoding convertto utf-8 $text]
	close $fh
}

# Fourteen files in a folder whose names say their index, each opened once (so the recent list holds them).
set files {}
for {set i 0} {$i < 14} {incr i} {
	set f [file join $dir f$i.txt]
	write_text $f "line $i\n"
	lappend files $f
}
foreach f $files { ::doc::recent_add $f }
set now [clock scan "2026-11-08 12:00:00" -format "%Y-%m-%d %H:%M:%S"]
set fmt "%Y-%m-%d %H:%M:%S"

puts "recent"
check "the Welcome page lists twelve recent files" {[llength [welcome::recent]] == 12}
check "the most recently opened is first" {[lindex [welcome::recent] 0] eq [lindex $files end]}

set ry0 [expr {[welcome::recent_label_y] + 26}]
set RH $welcome::RH
set cx0 [expr {[lindex $welcome::COLX 0] + 20}]
set cx1 [expr {[lindex $welcome::COLX 1] + 20}]
set rec [welcome::recent]
check "the first column's top row is the first recent file" {[welcome::cell $cx0 [expr {$ry0 + 5}]] eq [list row [lindex $rec 0]]}
check "the first column's last row is the sixth" {[welcome::cell $cx0 [expr {$ry0 + 5 + 5 * $RH}]] eq [list row [lindex $rec 5]]}
check "the second column starts with the seventh, not the second" {[welcome::cell $cx1 [expr {$ry0 + 5}]] eq [list row [lindex $rec 6]]}
check "and ends with the twelfth" {[welcome::cell $cx1 [expr {$ry0 + 5 + 5 * $RH}]] eq [list row [lindex $rec 11]]}

puts "pins"
welcome::unpin [lindex $rec 0]
set welcome::pins {}
welcome::pin [lindex $rec 0]
welcome::pin [lindex $rec 1]
welcome::pin [lindex $rec 2]
check "a file is pinned" {[llength $welcome::pins] == 3}
welcome::pin [lindex $rec 3]
welcome::pin [lindex $rec 4]
check "no more than four pins" {[llength $welcome::pins] == 4}
check "a fifth pin is refused" {[lindex $rec 4] ni $welcome::pins}
check "the pins are saved to the state folder" {[file exists [welcome::pins_file]]}
set welcome::pins {}
welcome::load_pins
check "and read back, in order" {$welcome::pins eq [lrange $rec 0 3]}
welcome::unpin [lindex $rec 1]
check "unpin takes a file out" {[lindex $rec 1] ni $welcome::pins && [llength $welcome::pins] == 3}

puts "reorder"
set welcome::pins [lrange $rec 0 2]
welcome::move_pin 0 2
check "a card moved to the end" {$welcome::pins eq [list [lindex $rec 1] [lindex $rec 2] [lindex $rec 0]]}
set welcome::pins [lrange $rec 0 2]
welcome::drop_pin 0 [expr {$welcome::LEFT + 1 * $welcome::CSTEP + 5}] 200
check "a card dropped on the next card takes its place" {[lindex $welcome::pins 1] eq [lindex $rec 0]}
set welcome::pins [lrange $rec 0 2]
welcome::drop_pin 2 [expr {$welcome::LEFT + 5}] 200
check "a card dropped on the first card moves to the front" {[lindex $welcome::pins 0] eq [lindex $rec 2]}

puts "menus"
set welcome::pins [lrange $rec 0 1]
set cy [expr {$welcome::CTOP + 10}]
welcome::context [expr {$welcome::LEFT + 10}] $cy
check "a pinned card's menu offers Unpin only" {[llength $::menu::items] == 1 && [lindex $::menu::items 0 0] eq "Unpin"}
menu::hide
set ry [expr {[welcome::recent_label_y] + 26 + 5}]
welcome::context [expr {$cx0}] $ry
check "a recent row's menu offers Unpin when it is pinned" {[lindex $::menu::items 0 0] eq "Unpin"}
menu::hide
set welcome::pins [lrange $rec 0 1]
welcome::context $cx1 [expr {[welcome::recent_label_y] + 26 + 5}]
check "a row's menu offers Pin and Remove from recent" {[join [lmap r $::menu::items {lindex $r 0}] ","] eq "Pin,Remove from recent"}
menu::hide
set welcome::pins {}
welcome::pin [lindex $rec 0]
puts "times"
check "a file changed ten minutes ago reads Today, with its time" {[welcome::when [expr {$now - 600}] $now] eq "Today, 11:50"}
check "a file from yesterday reads Yesterday, with its time" \
	{[welcome::when [clock scan "2026-11-07 18:05:00" -format $fmt] $now] eq "Yesterday, 18:05"}
set wd [clock scan "2026-11-04 09:00:00" -format $fmt]
check "a file from the last week reads its weekday" {[welcome::when $wd $now] eq [clock format $wd -format %A]}
check "an older file reads its day and month" \
	{[welcome::when [clock scan "2026-10-30 09:00:00" -format $fmt] $now] eq "30 Oct"}
check "a file from an earlier year reads the year too" \
	{[welcome::when [clock scan "2024-01-01 09:00:00" -format $fmt] $now] eq "1 Jan 2024"}

puts "preview and missing files"
set long [file join $dir long.txt]
set text ""
for {set i 1} {$i <= 20} {incr i} { append text "row $i\n" }
write_text $long $text
check "a preview is nine lines" {[llength [welcome::preview $long]] == 9}
check "its first line is the file's first" {[lindex [welcome::preview $long] 0] eq "row 1"}
set missing [file join $dir gone.txt]
set n [llength $::editor::docs]
welcome::open_file $missing
check "a missing file does not open" {[llength $::editor::docs] == $n}

puts "subtitle and fade"
set welcome::pins [lrange $rec 0 1]
check "the subtitle counts the pins and the recent files" \
	{[welcome::subtitle] eq "Nothing open · 2 pinned · 12 recent"}
set deep [file join $dir [string repeat "a-long-folder-name/" 8]]
file mkdir $deep
set bar $::editor::c(bar)
$::editor::cv delete folderfade
set end [welcome::fade 100 50 $deep i12 $::editor::c(muted) $bar 300]
check "a long folder path is cut at the clip edge" {$end <= 300}
set maxx 0
# each letter's right edge from its anchor and its measured width (a canvas bbox is rounded out and may be a
# pixel or so wider than the glyph, so it can't tell 299.8 from 301)
foreach i [$::editor::cv find withtag folderfade] {
	set x1 [expr {[lindex [$::editor::cv coords $i] 0] + [ui::measure i12 [$::editor::cv itemcget $i -text]]}]
	if {$x1 > $maxx} { set maxx $x1 }
}
check "no folder text is drawn past the clip edge" {$maxx <= 300}
if {$maxx > 300} { puts "       (the last character ends at $maxx, the fade returned $end)" }
check "its last characters are drawn in a colour mixed toward the background" {
	[$::editor::cv itemcget [lindex [$::editor::cv find withtag folderfade] end] -fill] ne $::editor::c(muted)
}

puts "footer"
# the footer's buttons, as Editor-Final-6-Welcome-B draws them: Open folder… (a ghost) at the left margin, Open… and New
# document at the right one, each 38 tall and 17 px under the footer's rule
foreach id [split::union] { editor::force_close $id }
editor::paint; update
set fy [expr {$::editor::H - 72}]
proc hit_at {x y} {
	foreach h [lreverse $::ui::hits] {
		lassign $h x0 y0 x1 y1 press
		if {$x >= $x0 && $x < $x1 && $y >= $y0 && $y < $y1} { return [list $x0 $y0 [expr {$x1 - $x0}] [expr {$y1 - $y0}] $press] }
	}
	return ""
}
set hf [hit_at 60 [expr {$fy + 30}]]
check "Open folder… is at the footer's left, 38 tall, 17 under the rule" {
	[lindex $hf 4] eq "welcome::folder_btn" && [lindex $hf 0] == 40 && [lindex $hf 1] == $fy + 17 && [lindex $hf 3] == 38 &&
	abs([lindex $hf 2] - 148) <= 3}
set ho [hit_at 950 [expr {$fy + 30}]]
set hn [hit_at 1100 [expr {$fy + 30}]]
check "Open… and New document end at the right margin, 10 apart" {
	[lindex $ho 4] eq "welcome::open_btn" && [lindex $hn 4] eq "welcome::new_btn" &&
	[lindex $hn 0] + [lindex $hn 2] == $::editor::W - 40 && [lindex $ho 0] + [lindex $ho 2] + 10 == [lindex $hn 0] &&
	abs([lindex $ho 0] - 922) <= 3}
# the choosers stand in for Ribbon's file chooser (chooser.tcl): each records how it was asked and answers with a folder or a file
set picked [file join $dir proj]
file mkdir $picked
write_text [file join $picked main.tcl] "set x 1\n"
set ::asked {}
proc chooser::choose_folder {args} { lappend ::asked [list dir $args]; return $::picked }
proc chooser::open_file {args} { lappend ::asked [list file $args]; return [file join $::picked main.tcl] }
event generate $::editor::cv <ButtonPress-1> -x 60 -y [expr {$fy + 30}]
event generate $::editor::cv <ButtonRelease-1> -x 60 -y [expr {$fy + 30}]
update
check "a click on Open folder… asks for a folder, then opens the file chooser in it" {
	[llength $::asked] == 2 && [lindex $::asked 0 0] eq "dir" && [lindex $::asked 1 0] eq "file" &&
	[dict get [lindex $::asked 1 1] -initialdir] eq $picked}
check "and the file chosen there is opened" {
	[llength [split::union]] == 1 && $::doc::D([lindex [split::union] 0],path) eq [file join $picked main.tcl]}
check "the folder is remembered: where the chooser starts next time" {[::doc::start_dir] eq $picked}
set ::asked {}
editor::open_dialog
check "Open… (Ctrl+O) starts in it too" {[dict get [lindex $::asked 0 1] -initialdir] eq $picked}
foreach id [split::union] { editor::force_close $id }
set ::asked {}
proc chooser::choose_folder {args} { lappend ::asked [list dir $args]; return "" }
welcome::folder_btn
check "Cancel in the folder chooser opens nothing and keeps the folder" {
	[llength $::asked] == 1 && ![llength [split::union]] && [::doc::start_dir] eq $picked &&
	[dict get [lindex $::asked 0 1] -initialdir] eq $picked}

if {$fails} { puts "editor welcome: $fails checks failed"; exit 1 }
puts "editor welcome: all checks passed"
exit 0
