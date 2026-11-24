# editor-flow.tcl - the text editor's behaviour, driven through its own procs under xvfb (run by
# apps/editor/main.tcl through RIBBON_EDITOR_SCENE=this file, with RIBBON_EDITOR_FIXTURES = a temp folder).
# Checks: a file opened and saved unchanged is the same bytes (UTF-8, UTF-8 BOM, CRLF, Latin-1); the dirty flag;
# Save as; the close sheet's three answers (Cancel, Don't save, Save N and close); the open-documents list;
# tab overflow; and the external-change check; the status line's indent (Tabs, Spaces: N) and the Tab key in a
# space-indented document; the window's focus (inactive look, and a file changed on disk while away reloaded when the
# focus comes back). Prints "  ok ..." per check; exits 0 when all pass, 1 otherwise.
set dir $::env(RIBBON_EDITOR_FIXTURES)
file mkdir $dir
set fails 0
set n 0
proc ok {what} { puts "  ok   $what"; flush stdout }
proc bad {what} { global fails; incr fails; puts "  FAIL $what" }
proc check {what cond} { if {[uplevel 1 [list expr $cond]]} { ok $what } else { bad $what } }
proc bgerror {msg} { puts stderr "editor-flow: $msg\n$::errorInfo"; exit 1 }

proc write_bytes {path bytes} {
	set fh [open $path wb]
	fconfigure $fh -translation binary
	puts -nonewline $fh $bytes
	close $fh
}
proc read_bytes {path} { set f [open $path rb]; set b [read $f]; close $f; return $b }

# the byte cases: each is {name bytes}
set cases [list \
	[list utf8-lf [encoding convertto utf-8 "héllo\nwörld ☃\n"]] \
	[list utf8-bom-crlf "\xEF\xBB\xBF[encoding convertto utf-8 "a\r\nbé\r\n"]"] \
	[list latin1 "caf\xE9\nline two\n"] \
	[list crlf "x\r\ny\r\n"] \
	[list no-final-newline "end without newline"] \
]

puts "round trip"
foreach c $cases {
	lassign $c name bytes
	set p [file join $dir rt-$name.txt]
	write_bytes $p $bytes
	set id [editor::open_path $p]
	check "$name: opened, not dirty" {![::doc::dirty $id]}
	check "$name: saved unchanged" {[::doc::save $id] == 1}
	check "$name: same bytes on disk" {[read_bytes $p] eq $bytes}
	editor::force_close $id
}

puts "dirty dot"
set p [file join $dir dirty.txt]
write_bytes $p "one\n"
set id [editor::open_path $p]
$::doc::D($id,w) insert end "two"
check "an edit makes the document dirty" {[::doc::dirty $id]}
::doc::save $id
check "saving clears the dirty flag" {![::doc::dirty $id]}
editor::force_close $id

puts "save as"
set p [file join $dir from.txt]
write_bytes $p "first\n"
set id [editor::open_path $p]
$::doc::D($id,w) insert end "second"
set to [file join $dir to.txt]
check "save as writes the new path" {[::doc::save $id $to] == 1}
check "save as: new file has the text" {[read_bytes $to] eq "first\nsecond"}
check "save as: the document now names the new path" {$::doc::D($id,path) eq $to}
editor::force_close $id

puts "close sheet"
set pa [file join $dir close-a.txt]; set pb [file join $dir close-b.txt]
write_bytes $pa "a\n"; write_bytes $pb "b\n"
set a [editor::open_path $pa]; set b [editor::open_path $pb]
$::doc::D($a,w) insert end "A-edit"
set before $::editor::docs
editor::close_docs [list $a $b]
check "closing with a dirty document shows the sheet" {$::editor::sheet}
sheet::answer cancel
check "Cancel keeps every document open" {$::editor::docs eq $before && !$::editor::sheet}
check "Cancel keeps the edit" {[::doc::dirty $a]}
editor::close_docs [list $a $b]
sheet::answer discard
check "Don't save closes without writing" {[read_bytes $pa] eq "a\n" && $a ni $::editor::docs}
set c [editor::open_path [file join $dir close-b.txt]]
$::doc::D($c,w) insert end "B-edit"
editor::close_docs [list $c]
check "Save N and close shows the sheet for the dirty one" {$::editor::sheet}
sheet::answer save
check "Save and close writes the text, then closes" {[read_bytes $pb] eq "b\nB-edit" && $c ni $::editor::docs}

puts "open documents list"
set ids {}
foreach name {list-1 list-2 list-3} {
	set p [file join $dir $name.txt]; write_bytes $p "$name\n"
	lappend ids [editor::open_path $p]
}
editor::toggle_pop
check "the list opens" {$::editor::pop}
check "the list shows every open document" {[llength [tabs::visible_docs]] == [llength $::editor::docs]}
set ::editor::popq "list-2"
check "typing filters the list" {[llength [tabs::visible_docs]] == 1}
editor::close_pop
check "the list closes" {!$::editor::pop}
set ::editor::popq ""
editor::close_docs $ids

puts "tab overflow"
set many {}
for {set i 1} {$i <= 16} {incr i} {
	set p [file join $dir tab-[format %02d $i].txt]; write_bytes $p "$i\n"
	lappend many [editor::open_path $p]
}
check "sixteen tabs overflow the strip" {[lindex [tabs::layout] 2]}
editor::wheel_strip 1
check "the strip scrolls" {$::editor::scroll > 0}
editor::wheel_strip -1000
check "scrolling stops at the first tab" {$::editor::scroll == 0}
editor::close_docs $many

puts "external change"
set p [file join $dir ext.txt]; write_bytes $p "old\n"
set clean [editor::open_path $p]
write_bytes $p "new from disk\n"
file mtime $p [expr {[file mtime $p] + 30}]
::doc::check_disk $clean
check "a clean document follows the file" {[$::doc::D($clean,w) get 1.0 end-1c] eq "new from disk\n"}
set p2 [file join $dir ext-dirty.txt]; write_bytes $p2 "old\n"
set d [editor::open_path $p2]
$::doc::D($d,w) insert end "mine"
write_bytes $p2 "changed on disk\n"
file mtime $p2 [expr {[file mtime $p2] + 30}]
::doc::check_disk $d
check "a changed document keeps its text and says so" {[$::doc::D($d,w) get 1.0 end-1c] eq "old\nmine" && $::doc::D($d,conflict)}

puts "indent"
# the status line's words, as drawn: ui::text records each string it draws
proc status_words {} {
	set ::drawn {}
	set ::colours {}
	rename ui::text ui::text_real
	proc ui::text {x top str args} { lappend ::drawn $str; lappend ::colours [lindex $args 1]; ui::text_real $x $top $str {*}$args }
	well::status $split::cur
	rename ui::text {}
	rename ui::text_real ui::text
	return $::drawn
}
set p [file join $dir tabbed.tcl]; write_bytes $p "proc a {} {\n\tset x 1\n\tif {\$x} {\n\t\tputs x\n\t}\n}\n"
set tid [editor::open_path $p]
check "a tab-indented file: the status line says Tabs" {"Tabs" in [status_words]}
set p [file join $dir two.py]; write_bytes $p "def f():\n  if x:\n    return 1\n  return 2\n"
set sid [editor::open_path $p]
check "a 2-space file: the status line says Spaces: 2" {"Spaces: 2" in [status_words]}
set w $::doc::D($sid,w)
$w mark set insert 4.end
focus -force $w; update
event generate $w <Return>; event generate $w <Tab>; update
check "the Tab key in it inserts two spaces, not a tab" {[$w get 5.0 5.end] eq "  " && [string first "\t" [$w get 1.0 end]] < 0}
set p [file join $dir four.c]; write_bytes $p "int f() {\n    if (x) {\n        return 1;\n    }\n    /* a\n     * comment\n     */\n}\n"
set fid [editor::open_path $p]
check "a 4-space file with a block comment: Spaces: 4" {"Spaces: 4" in [status_words]}
foreach i [list $tid $sid $fid] { editor::force_close $i }

puts "focus"
set p [file join $dir away.txt]; write_bytes $p "before\n"
set aid [editor::open_path $p]
editor::paint; update; editor::paint; update
check "with the focus: the position is in FG, the band is up" {
	$::editor::winfocus && [winfo ismapped $editor::band1] && [string match "Ln *" [lindex [status_words] 0]] &&
	[lindex $::colours 0] eq $::editor::c(fg)}
# the person goes to another window: a second toplevel takes the focus
toplevel .other; wm geometry .other 200x100+1200+700; update
focus -force .other; update
set end [expr {[clock milliseconds] + 2000}]
while {$::editor::winfocus && [clock milliseconds] < $end} { after 20; update }
check "focus on another window: the editor reads as inactive" {!$::editor::winfocus}
editor::paint; update
check "the current-line band is gone, the position is muted" {
	![winfo ismapped $editor::band1] && [status_words] ne "" && [lindex $::colours 0] eq $::editor::c(muted)}
check "the active tab's name and the strip's buttons are muted, at 50 % (editor::dim)" {
	[editor::dim $::editor::c(fg)] eq [well::mix $::editor::c(fg) $::editor::c(d2) 0.5]}
write_bytes $p "after\n"
file mtime $p [expr {[file mtime $p] + 30}]
check "a file changed on disk meanwhile is not reloaded while away" {[$::doc::D($aid,w) get 1.0 end-1c] eq "before\n"}
focus -force $::doc::D($aid,w); update
set end [expr {[clock milliseconds] + 2000}]
while {!$::editor::winfocus && [clock milliseconds] < $end} { after 20; update }
check "the focus back: active again, and the changed file is reloaded at once" {
	$::editor::winfocus && [$::doc::D($aid,w) get 1.0 end-1c] eq "after\n"}
destroy .other
editor::close_docs [list $aid]
# a reload keeps the syntax colours of the lines that did not change (the reload replaces the whole text)
set p [file join $dir reload.tcl]; write_bytes $p "proc a {} {\n\tset x 1\n}\n"
set rid [editor::open_path $p]
update
write_bytes $p "proc a {} {\n\tset x 2\n}\n"
file mtime $p [expr {[file mtime $p] + 30}]
doc::check_disk $rid
update
check "a file reloaded from disk keeps its syntax colours on the lines that did not change" {
	[$::doc::D($rid,w) get 2.0 2.end] eq "\tset x 2" && "syn_kw" in [$::doc::D($rid,w) tag names 1.1]}
editor::close_docs [list $rid]

if {$fails} { puts "editor flow: $fails checks failed"; exit 1 }
puts "editor flow: all checks passed"
exit 0
