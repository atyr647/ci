# files-openwith.tcl - Files' Inspector panel and "Opens with" choices, in the shell
# (RIBBON_SHELL_TEST; tests/steps.d/60-files-openwith.sh runs it with HOME and XDG_* in a temp
# folder). Exits 0 when every check passes; each check prints one line.
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
proc ran {} { set ::ran {} }
# a desktop app the shell can start: the test's own, with its command recorded
proc apps::run {cmd} { lappend ::ran $cmd }
proc inject_apps {} {
	set apps::byid(ribbon-test-editor) [dict create id ribbon-test-editor.desktop name Test exec "testedit %f" terminal 0 wmclass "" icon ""]
	set apps::byid(ribbon-test-other) [dict create id ribbon-test-other.desktop name Other exec "otherapp %u" terminal 0 wmclass "" icon ""]
}

set root [file join $::env(HOME) work]
file delete -force $root
write_file $root/a/main.rs "fn main() {}\n"
write_file $root/a/notes.txt "one\ntwo\n"
write_file $root/a/plain.md "# plain\n"
write_file $root/a/draft.txt "draft\n"
file mkdir $root/a/sub

files::modules
# the store's follow-ups, in the shell: the open action, rename, delete
openwith::choose $root/a/main.rs ribbon-test-editor.desktop
set w [files::show $root/a]
inject_apps
ran
files::activate $w main.rs
check "Files' open action reads the choice first" {[string match "testedit *main.rs*" [lindex $::ran 0]]}
ran
files::activate $w notes.txt
check "a file without a choice goes to the system default" {[string match "xdg-open *notes.txt*" [lindex $::ran 0]]}

# rename in Files: the choice follows the file
entry $w.main.rename
$w.main.rename insert 0 main-renamed.rs
files::rename_done $w main.rs
check "rename in Files moves the choice to the new name" {[openwith::get $root/a/main-renamed.rs] eq "ribbon-test-editor.desktop" && [openwith::get $root/a/main.rs] eq ""}

# delete in Files: the choice goes with the file
openwith::choose $root/a/notes.txt ribbon-test-other.desktop
files::really_delete $w [list $root/a/notes.txt]
check "delete removes the choice" {[openwith::get $root/a/notes.txt] eq ""}

# Properties (Alt+Return, the menu) opens the standalone window for the selection; the panel is
# the toolbar's button. The window is a separate program: the test records the command.
check "the panel starts shut" {!$files::st($w,insp)}
set ::ran {}
files::key $w Return "\r" 8
check "Alt+Return asks for the standalone window" {[lindex $::ran 0] eq "ribbon-properties --over [winfo rootx [winfo toplevel $w]] [winfo rooty [winfo toplevel $w]] [winfo width [winfo toplevel $w]] [winfo height [winfo toplevel $w]] [apps::shellquote $root/a/main-renamed.rs]"}
check "Alt+Return leaves the panel shut" {!$files::st($w,insp)}
files::insp_toggle $w
update
check "the toolbar's button opens the Inspector panel" {$files::st($w,insp) && [winfo ismapped $w.insp]}
check "the panel draws the folder when nothing is selected" {[llength [$w.insp find all]] > 0}
set files::st($w,sel) [list main-renamed.rs]
files::layout $w
update
check "the panel follows the selection" {[llength [$w.insp find all]] > 0}

# the edit view in the panel: typing renames, Enter applies, Esc leaves the view
write_file $root/a/panel.txt "x\n"
set files::st($w,sel) [list panel.txt]
files::layout $w
update
inspector::edit_begin [facts::of $root/a/panel.txt]
files::insp_draw $w
check "the edit view opens with the name focused" {$inspector::edit && [ui::focused] ne "" && [lindex [ui::focused] 0] eq "insp.name"}
files::key $w End "" 0
files::key $w z z 0
check "a key types into the panel's name field" {[ui::fval insp.name] eq "panel.txtz"}
files::key $w BackSpace "" 0
check "BackSpace edits the name field" {[ui::fval insp.name] eq "panel.txt"}
files::key $w Escape "" 0
check "Esc leaves the edit view" {!$inspector::edit}
check "the file keeps its name after Esc" {[file exists $root/a/panel.txt]}

# a dropdown in the panel's footer: clicking it opens its menu, and a pick runs the job (the
# others' level, through the mode bits)
set F [facts::of $root/a/panel.txt]
set ::ran {}
proc click_hit {pattern} {
	foreach h $ui::hits {
		lassign $h x0 y0 x1 y1 press
		if {[string match $pattern $press]} { ui::press [expr {($x0 + $x1) / 2}] [expr {($y0 + $y1) / 2}]; return 1 }
	}
	return 0
}
files::insp_draw $w
check "a footer dropdown is clickable" {[click_hit "*page::menu_toggle*"]}
check "the click opens its menu" {[dict size $page::menu] > 0}
files::insp_draw $w
set mode0 [expr {[file attributes $root/a/panel.txt -permissions] & 0777}]
proc click_key {key} {
	foreach h $ui::hits {
		lassign $h x0 y0 x1 y1 press
		if {[string match *menu_pick* $press] && [lindex $press end] eq $key} { ui::press [expr {($x0 + $x1) / 2}] [expr {($y0 + $y1) / 2}]; return 1 }
	}
	return 0
}
check "a menu row is clickable and picks" {[click_key {no access}]}
set mode1 [expr {[file attributes $root/a/panel.txt -permissions] & 0777}]
check "the pick sets the others' level" {($mode1 & 7) == 0}

# the Inspector's switch: "this file only" stores the choice, "every file" sets the type
set plain $root/a/plain.md
set F [facts::of $plain]
inspector::edit_begin $F
check "the switch is on when the file has no choice of its own" {$inspector::E(every) == 1}
inspector::pick_app ribbon-test-other.desktop
inspector::toggle_every
inspector::apply {}
check "switch off: the choice is this file's" {[openwith::get $plain] eq "ribbon-test-other.desktop"}
inspector::edit_begin [facts::of $plain]
check "the edit view starts with the file's own choice and the switch off" {$inspector::E(opens) eq "ribbon-test-other.desktop" && $inspector::E(every) == 0}
inspector::toggle_every
inspector::apply {}
check "switch on: the file's own choice is dropped" {[openwith::get $plain] eq ""}
set mimeapps [file join $::env(XDG_CONFIG_HOME) mimeapps.list]
set fh [open $mimeapps r]; set mtext [read $fh]; close $fh
check "switch on: the type's default is in mimeapps.list" \
	{[string first "[dict get $F mime]=ribbon-test-other.desktop" $mtext] >= 0}

# a rename in the edit view keeps the choice with the file
openwith::choose $root/a/draft.txt ribbon-test-editor.desktop
inspector::edit_begin [facts::of $root/a/draft.txt]
ui::fset insp.name renamed.txt
inspector::apply {}
check "rename in the Inspector moves the choice" {[file exists $root/a/renamed.txt] && [openwith::get $root/a/renamed.txt] eq "ribbon-test-editor.desktop" && [openwith::get $root/a/draft.txt] eq ""}

if {$fails} { puts "files-openwith: $fails checks failed"; exit 1 }
puts "files-openwith: all checks passed"
exit 0
