# files-props-open.tcl - Files' Properties placement and its open action's default app, in the shell
# (RIBBON_SHELL_TEST; tests/steps.d/60-files-props-open.sh runs it with HOME, XDG_CONFIG_* and XDG_DATA_* in a
# temp folder: XDG_DATA_DIRS holds the test's apps and type tree only). Each check prints one line.
# Placement (HANDOFF "File properties window" 4, read by properties/win2.tcl): the menu's Properties passes
# --beside the right-clicked tile's rectangle in grid view, --beside the menu's point in list view and on the
# empty area; Alt+Return passes --over the Files window's rectangle; and ribbon-properties' own parser reads them.
# Open (files::activate): a file's own choice first, then the default the Inspector names (facts::handlers, with
# its parent types: an SVG opens where the Inspector says), an app the launcher hides included; xdg-open only when
# there is none; an app installed while the shell runs is seen.
proc bgerror {msg} { puts stderr "error: $msg\n$::errorInfo"; exit 1 }
set fails 0
proc check {what cond} {
	global fails
	if {[catch {uplevel 1 [list expr $cond]} ok] || !$ok} { puts "  FAIL files: $what"; incr fails; return }
	puts "  ok   files: $what"
}
proc write_file {path text} {
	file mkdir [file dirname $path]
	set fh [open $path w]; fconfigure $fh -encoding utf-8; puts -nonewline $fh $text; close $fh
}
proc wait_for {script {ms 5000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 $script]} {
		if {[clock milliseconds] > $end} { return 0 }
		after 20; update
	}
	return 1
}
# the shell starts programs through apps::run: the test records the commands
proc apps::run {cmd} { lappend ::ran $cmd }
set ::ran {}
# the menu's items are recorded and the menu is not shown; a row is chosen by running its command
rename files::popup_menu files::real_popup_menu
proc files::popup_menu {w X Y items args} { set ::menu $items }
proc menu_cmd {label} {
	foreach it $::menu { if {[lindex $it 1] eq $label} { return [lindex $it 2] } }
	return ""
}

set data [lindex [split $::env(XDG_DATA_DIRS) :] 0]
set root [file join $::env(HOME) work]
file delete -force $root
write_file $root/a/drawing.svg "<?xml version=\"1.0\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"4\"/>\n"
write_file $root/a/notes.txt "one\n"
write_file $root/a/song.flac "fLaC"
write_file $root/a/blob.bin "\x00\x01\x02"
write_file $root/a/main.rs "fn main() {}\n"
write_file $root/a/plan.md "# plan\n"

files::modules
set w [files::show $root/a]
wm geometry [winfo toplevel $w] 1000x640+120+90
check "the window is shown" {[wait_for {expr {[winfo ismapped $w.main] && [llength $files::st($w,tiles)]}}]}
update

# ---- Properties: where it opens ------------------------------------------------------------------------
set files::st($w,view) grid; files::draw $w; update
set tile ""
foreach t $files::st($w,tiles) { if {[lindex $t 4] eq "notes.txt"} { set tile $t } }
lassign $tile x0 y0 x1 y1
set cx [expr {int(($x0 + $x1) / 2)}]; set cy [expr {int(($y0 + $y1) / 2 - [$w.main canvasy 0])}]
set X [expr {[winfo rootx $w.main] + $cx}]; set Y [expr {[winfo rooty $w.main] + $cy}]
files::context $w $cx $cy $X $Y
set cmd [menu_cmd Properties]
check "the file menu's Properties asks for the menu's placement" {$cmd eq [list files::props $w menu]}
set ::ran {}
uplevel #0 $cmd
set want "--beside [expr {[winfo rootx $w.main] + int($x0)}] [expr {[winfo rooty $w.main] + int($y0 - [$w.main canvasy 0])}] [expr {int($x1 - $x0)}] [expr {int($y1 - $y0)}]"
check "grid view: --beside the right-clicked tile's rectangle (root coordinates)" {[lindex $::ran 0] eq "ribbon-properties $want [apps::shellquote $root/a/notes.txt]"}
lassign [lrange $want 1 end] bx by bw bh
check "the tile's rectangle holds the point that was clicked" {$X >= $bx && $X < $bx + $bw && $Y >= $by && $Y < $by + $bh}

# scrolled: the rectangle is where the tile is on screen, not in the canvas
for {set i 0} {$i < 60} {incr i} { write_file $root/a/f[format %02d $i].txt "x\n" }
files::load $w; files::draw $w; update
set last [lindex $files::st($w,tiles) end]
files::scroll $w 2000; update
set sy [$w.main canvasy 0]
check "the folder scrolls" {$sy > 0}
lassign $last x0 y0 x1 y1 lname
set cx [expr {int(($x0 + $x1) / 2)}]; set cy [expr {int(($y0 + $y1) / 2 - $sy)}]
files::context $w $cx $cy [expr {[winfo rootx $w.main] + $cx}] [expr {[winfo rooty $w.main] + $cy}]
set ::ran {}
uplevel #0 [menu_cmd Properties]
lassign [lrange [lindex $::ran 0] 2 5] bx by
check "scrolled grid view: the tile's on-screen top" {$by == [winfo rooty $w.main] + int($y0 - $sy) && $by < [winfo rooty $w.main] + [winfo height $w.main]}
foreach i [glob -directory $root/a f*.txt] { file delete $i }
files::load $w; files::draw $w; files::scroll $w -5000; update

# list view: beside the point the menu was asked at
set files::st($w,view) list; files::draw $w; update
set tile ""
foreach t $files::st($w,tiles) { if {[lindex $t 4] eq "main.rs"} { set tile $t } }
lassign $tile x0 y0 x1 y1
set cx 200; set cy [expr {int(($y0 + $y1) / 2 - [$w.main canvasy 0])}]
set X [expr {[winfo rootx $w.main] + $cx}]; set Y [expr {[winfo rooty $w.main] + $cy}]
files::context $w $cx $cy $X $Y
set ::ran {}
uplevel #0 [menu_cmd Properties]
check "list view: --beside the menu's point" {[lindex $::ran 0] eq "ribbon-properties --beside $X $Y 0 0 [apps::shellquote $root/a/main.rs]"}

# the empty area's menu: the folder, beside the point
set files::st($w,view) grid; set files::st($w,sel) {}; files::draw $w; update
set ey [expr {[winfo height $w.main] - 6}]
files::context $w 6 $ey [expr {[winfo rootx $w.main] + 6}] [expr {[winfo rooty $w.main] + $ey}]
set cmd [menu_cmd Properties]
check "the empty area's Properties asks for the menu's placement" {$cmd eq [list files::props $w menu]}
set ::ran {}
uplevel #0 $cmd
check "the empty area: the folder, --beside the menu's point" {[lindex $::ran 0] eq "ribbon-properties --beside [expr {[winfo rootx $w.main] + 6}] [expr {[winfo rooty $w.main] + $ey}] 0 0 [apps::shellquote $root/a]"}

# Alt+Return: centred on the window that asked
set files::st($w,sel) [list plan.md]; set files::st($w,anchor) plan.md
set ::ran {}
files::key $w Return "\r" 8
set t [winfo toplevel $w]
check "Alt+Return: --over the Files window" {[lindex $::ran 0] eq "ribbon-properties --over [winfo rootx $t] [winfo rooty $t] [winfo width $t] [winfo height $t] [apps::shellquote $root/a/plan.md]"}

# ribbon-properties reads what Files passes (its own argument loop, properties/main.tcl)
set src [file join [file dirname $files::here] properties main.tcl]
set fh [open $src]; set text [read $fh]; close $fh
check "ribbon-properties takes --beside and --over" {[string first "--beside - --over" $text] >= 0}
set ::ran {}
files::props $w menu
set args [lrange [lindex $::ran 0] 1 end]
set ::argv [lrange $args 0 end-1]
check "the placement is four whole numbers, as properties/main.tcl requires" {[llength [lrange $args 1 4]] == 4 && [llength [lmap n [lrange $args 1 4] { if {![string is integer -strict $n]} continue; set n }]] == 4}

# ---- open: the Inspector's default before xdg-open -------------------------------------------------------
files::set_view $w grid
set ::ran {}
files::activate $w drawing.svg
set inspector [lindex [facts::handlers [facts::mime $root/a/drawing.svg]] 0]
check "the Inspector names the text editor for an SVG (its parent types)" {$inspector eq "ribbon-test-editor.desktop"}
check "Files opens an SVG where the Inspector says" {[string match "testedit *drawing.svg*" [lindex $::ran 0]]}
set ::ran {}
files::activate $w notes.txt
check "a text file opens in the default text editor" {[string match "testedit *notes.txt*" [lindex $::ran 0]]}
set ::ran {}
files::activate $w song.flac
check "the default may be an app the launcher hides (NoDisplay)" {[string match "hiddenplayer *song.flac*" [lindex $::ran 0]]}
set ::ran {}
files::activate $w blob.bin
check "a file no app takes goes to xdg-open" {[string match "xdg-open *blob.bin*" [lindex $::ran 0]]}
openwith::choose $root/a/notes.txt ribbon-test-other.desktop
set ::ran {}
files::activate $w notes.txt
check "the file's own choice still comes first" {[string match "otherapp *notes.txt*" [lindex $::ran 0]]}
# an app installed while the shell runs: a new default for its type
write_file $data/applications/ribbon-test-bin.desktop "\[Desktop Entry\]\nType=Application\nName=Bin\nExec=binview %f\nMimeType=application/x-test-bin;\n"
write_file $::env(XDG_CONFIG_HOME)/mimeapps.list "\[Default Applications\]\napplication/x-test-bin=ribbon-test-bin.desktop\ntext/plain=ribbon-test-editor.desktop\n"
file mtime $data/applications [expr {[clock seconds] + 5}]
proc facts::mime {path} { expr {[string match *.bin $path] ? "application/x-test-bin" : "text/plain"} }
::apps::load
set ::ran {}
files::activate $w blob.bin
check "an app installed since the shell started opens its type" {[string match "binview *blob.bin*" [lindex $::ran 0]]}

if {$fails} { puts "files-props-open: $fails checks failed"; exit 1 }
puts "files-props-open: all checks passed"
exit 0
