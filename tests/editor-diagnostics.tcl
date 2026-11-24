# editor-diagnostics.tcl - the text editor's nagelfar diagnostics (U32), run by apps/editor/main.tcl through
# RIBBON_EDITOR_SCENE=this file, with RIBBON_EDITOR_FIXTURES = a temp folder.
# A stub nagelfar, written here and put first on PATH, prints known findings (and a note, which is not shown) and logs
# each call, so the checks can count runs.
# 1. the output parser (diag::parse): errors and warnings only, and the phrase each message names.
# 2. the run: nagelfar runs for the text once it has been still (the debounce), and not for each edit.
# 3. the gutter: a filled badge for an error, an outlined one for a warning; the error under the pointer is outlined and
#    its hover card shows the message, the phrase in mono and "nagelfar".
# 4. the text: a wave under each phrase, on the phrase; a press on a wave reaches the text under it.
# 5. the status line's counts.
# 6. without nagelfar on PATH: no badges, waves, counts or runs.
# 7. only a Tcl document is checked (a Python one never calls nagelfar), and a run is in the background: with a slow
#    nagelfar the event loop keeps going while it runs.
# With RIBBON_EDITOR_SHOT set, the window is also saved to that file in the board's state (the error on line 32 hovered,
# the window unfocused, as Editor-Final-7 draws it).
# Prints "  ok ..." per check; exits 0 when all pass, 1 otherwise.
set dir $::env(RIBBON_EDITOR_FIXTURES)
file mkdir $dir
set fails 0
proc ok {what} { puts "  ok   $what"; flush stdout }
proc check {what cond} {
	if {[uplevel 1 [list expr $cond]]} { ok $what } else { global fails; incr fails; puts "  FAIL $what" }
}
proc bgerror {msg} { puts stderr "editor-diagnostics: $msg\n$::errorInfo"; exit 1 }
proc write_text {path text} {
	set fh [open $path wb]
	fconfigure $fh -translation binary
	puts -nonewline $fh [encoding convertto utf-8 $text]
	close $fh
}
proc paint_now {} { editor::paint; update idletasks; update }
# polls (no fixed sleep) until COND holds, for at most MS; returns whether it held
proc wait_until {cond ms} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel 1 [list expr $cond]]} {
		if {[clock milliseconds] > $end} { return 0 }
		after 20
		update
	}
	return 1
}
# the y of the row of line N on screen (from the Well's visible rows), or ""
proc row_of {t n} {
	foreach row [well::visible $t] { lassign $row ln y; if {$ln == $n} { return $y } }
	return ""
}
# the number of times nagelfar has been called (one line of the log per call)
proc runs {} {
	set f [file join $::env(RIBBON_EDITOR_FIXTURES) calls.log]
	if {![file exists $f]} { return 0 }
	set fh [open $f r]
	set text [string trim [read $fh]]
	close $fh
	if {$text eq ""} { return 0 }
	return [llength [split $text \n]]
}
# the number of items of TYPE on the gutter canvas, tagged diag, whose OPT is COL
proc badge_count {type opt col} {
	set n 0
	foreach item [$::editor::gut find withtag diag] {
		if {[$::editor::gut type $item] eq $type && [$::editor::gut itemcget $item $opt] eq $col} { incr n }
	}
	return $n
}
# the waves (canvases) on the page of text T
proc waves_on {t} {
	set page [winfo parent $t]
	return [lsearch -all -inline -glob [winfo children $page] $page.diagwave*]
}

# ---- the stub nagelfar: three findings, and a note that is not shown ----
set bin [file join $dir bin]
file mkdir $bin
set stub [file join $bin nagelfar]
write_text $stub {#!/bin/sh
echo call >> "$NAGELFAR_LOG"
cat <<'EOF'
Line   15: E Too many arguments in this call
Line   17: W Command "parse" is used before it is defined
Line   29: N Something a note says
Line   32: E Wrong number of arguments to string range
nagelfar: 3 messages
EOF
}
file attributes $stub -permissions 0755
set ::env(NAGELFAR_LOG) [file join $dir calls.log]
set ::env(PATH) "$bin:$::env(PATH)"

# the document: 40 lines, with the lines the findings are on (15, 17, 32) as the board's store.tcl has them
set lines {}
for {set i 1} {$i <= 40} {incr i} { lappend lines "    set v$i \[list $i\]" }
lset lines 14 {    set text [read $f]}
lset lines 16 {    dict set index [file rootname [file tail $path]] [parse $text]}
lset lines 31 {            lappend tags [string range $tag 1]}
set p [file join $dir store.tcl]
write_text $p [join $lines \n]\n

# ---- 1. the parser ----
puts "parse"
set sample "Line   15: E Too many arguments in this call\nLine   17: W Command \"parse\" is used before it is defined\nLine   29: N Something a note says\nLine   32: E Wrong number of arguments to string range\nnagelfar: 3 messages\n"
set found [diag::parse $sample]
check "errors and warnings are findings; a note and other lines are not" {[llength $found] == 3}
check "each finding has its line and its severity" {
	[lindex $found 0 0] == 15 && [lindex $found 0 1] eq "E" && [lindex $found 1 1] eq "W" && [lindex $found 2 0] == 32}
check "a quoted phrase is the phrase the message names" {[lindex $found 1 3] eq "parse"}
check "the words after ' to ' are the phrase the message names" {[lindex $found 2 3] eq "string range"}
check "a message that names nothing has no phrase" {[lindex $found 0 3] eq ""}

# ---- 2. the run ----
puts "run"
set id [editor::open_path $p]
set t $::doc::D($id,w)
check "nagelfar is on PATH" {[diag::tool] ne ""}
check "the findings come once the text has been still for a while" {
	[wait_until {[info exists ::diag::res($id)]} 5000] && [llength $::diag::res($id)] == 3}
check "nagelfar ran once for the text" {[runs] == 1}
check "the counts are two errors and one warning" {[diag::counts $id] eq {2 1}}

# ---- 3. the gutter: badges and the hover card ----
puts "gutter"
paint_now
check "an error is a filled badge (ERR), a warning an outlined one (WARN)" {
	[badge_count polygon -fill $::theme::c(ERR)] == 2 && [badge_count polygon -outline $::theme::c(WARN)] == 1}
set ry [row_of $t 32]
check "the error on line 32 is on screen" {$ry ne ""}
diag::hover $::editor::gut 30 [expr {$ry + 5}]
set page [winfo parent $t]
check "the pointer on the badge of line 32 raises its card" {[winfo exists $page.diagcard]}
check "the card has the message, its phrase in mono, and the source" {
	[$page.diagcard.pre cget -text] eq "Wrong number of arguments to " && \
	[$page.diagcard.code cget -text] eq "string range" && [$page.diagcard.src cget -text] eq "nagelfar"}
paint_now
check "the hovered error is outlined (ERR) instead of filled" {
	[badge_count polygon -outline $::theme::c(ERR)] == 1 && [badge_count polygon -fill $::theme::c(ERR)] == 1}
diag::hover $::editor::gut -1 -1
check "the pointer leaving the badge takes the card down" {![winfo exists $page.diagcard]}
paint_now
check "and the error is filled again" {[badge_count polygon -fill $::theme::c(ERR)] == 2}

# ---- 4. the text: the waves under the phrases ----
puts "waves"
check "three waves: under 'parse' on line 17, 'string range' on line 32 and line 15's text (its message names nothing)" {
	[llength [waves_on $t]] == 3}
# line 15's finding names no phrase: its wave runs under the line's text from its first non-blank character
set b15 [$t bbox 15.4]
set e15 [$t bbox "15.end - 1 chars"]
set wave15 ""
foreach w [waves_on $t] {
	if {[dict get [place info $w] -x] == [lindex $b15 0] + [winfo x $t]} { set wave15 $w }
}
check "a message that names nothing waves under its line's text, from the first non-blank character" {
	$wave15 ne "" && [$wave15 cget -width] == [lindex $e15 0] + [lindex $e15 2] - [lindex $b15 0]}
set s [$t search -exact -- "string range" 32.0 32.end]
set b [$t bbox $s]
set e [$t index "$s + 12 chars"]
set bl [$t bbox "$e - 1 chars"]
set want_x [expr {[lindex $b 0] + [winfo x $t]}]
set want_w [expr {[lindex $bl 0] + [lindex $bl 2] - [lindex $b 0]}]
set wave ""
foreach w [waves_on $t] {
	if {[dict get [place info $w] -x] == $want_x} { set wave $w }
}
check "the wave of line 32 starts at the first letter of its phrase" {$wave ne ""}
check "and is as wide as the phrase" {$wave ne "" && [$wave cget -width] == $want_w}
$t mark set insert 29.0
event generate $wave <ButtonPress-1> -x 6 -y 1
event generate $wave <ButtonRelease-1> -x 6 -y 1
# the caret lands on line 32 inside the phrase (Tk rounds a press to a character boundary, so not one column)
lassign [split [$t index insert] .] cl cc
check "a press on a wave reaches the text under it: the caret moves into the phrase on its line" {
	$cl == 32 && $cc >= 26 && $cc <= 38}

# ---- 5. the status line ----
puts "status"
set drawn [diag::status $id 900 20]
check "the status line draws the counts: two errors and one warning" {
	$drawn eq {{E {2 errors}} {W {1 warning}}}}
check "and the words are the counts as the board has them" {
	[diag::count_text 1 E] eq "1 error" && [diag::count_text 1 W] eq "1 warning"}

# ---- debounce: edits within the delay make one run, after them ----
puts "debounce"
set r0 [runs]
for {set i 0} {$i < 3} {incr i} {
	$t insert end "x"
	paint_now
}
check "three edits within the delay make one run, after the delay" {[wait_until {[runs] > $r0} 5000]}
after 1000
update
check "and not another" {[runs] == $r0 + 1}
editor::force_close $id

# ---- 6. without nagelfar on PATH ----
puts "absent"
set saved_path $::env(PATH)
set empty [file join $dir empty]
file mkdir $empty
set ::env(PATH) $empty
set id2 [editor::open_path $p]
set t2 $::doc::D($id2,w)
paint_now
$t2 insert end "y"
paint_now
after 1000
update
check "without nagelfar on PATH: no tool, no run, no badge, no wave and no count" {
	[diag::tool] eq "" && [runs] == $r0 + 1 && [diag::counts $id2] eq {0 0} && \
	[badge_count polygon -fill $::theme::c(ERR)] == 0 && [llength [waves_on $t2]] == 0}
set ::env(PATH) $saved_path
editor::force_close $id2

# ---- 7. only Tcl, and in the background ----
puts "tcl only, background"
set r1 [runs]
set py [file join $dir tool.py]
write_text $py "def f(:\n    return 1\n"
set idpy [editor::open_path $py]
paint_now
$::doc::D($idpy,w) insert end "x = 2\n"
paint_now
after 1200
update
check "a Python document never calls nagelfar and shows no finding" {[runs] == $r1 && [diag::counts $idpy] eq {0 0}}
editor::force_close $idpy
# a slow nagelfar (1.5 s): the loop keeps ticking while it runs, and the findings come when it ends
set slow [file join $dir slowbin]
file mkdir $slow
write_text [file join $slow nagelfar] {#!/bin/sh
echo call >> "$NAGELFAR_LOG"
sleep 1.5
echo 'Line    2: E Too many arguments in this call'
}
file attributes [file join $slow nagelfar] -permissions 0755
set saved_path $::env(PATH)
set ::env(PATH) "$slow:$saved_path"
set ps [file join $dir slow.tcl]
write_text $ps "set a 1\nset b 2 3\n"
set ids [editor::open_path $ps]
set ::ticks 0
proc tick {} { incr ::ticks; set ::tickid [after 50 tick] }
set r2 [runs]
diag::run $ids
tick
check "the run starts at once (nagelfar has been called)" {[wait_until {[runs] > $r2} 3000]}
set t0 $::ticks
check "and while it runs the event loop keeps going (timers fire)" {[wait_until {$::ticks >= $t0 + 10} 1200] && ![info exists ::diag::res($ids)]}
check "its findings come when it ends" {[wait_until {[info exists ::diag::res($ids)]} 4000] && [diag::counts $ids] eq {1 0}}
after cancel $::tickid
set ::env(PATH) $saved_path
editor::force_close $ids

# ---- the board's state, for the screenshot ----
if {[info exists ::env(RIBBON_EDITOR_SHOT)]} {
	set id3 [editor::open_path $p]
	set t3 $::doc::D($id3,w)
	wait_until {[info exists ::diag::res($id3)]} 5000
	editor::activate $id3
	$t3 mark set insert 29.47
	$t3 yview 8.0
	paint_now
	diag::hover $::editor::gut 30 [expr {[row_of $t3 32] + 5}]
	editor::set_focus 0
	paint_now
	after 200
	update
	if {[catch {exec import -window [winfo id $::editor::win] $::env(RIBBON_EDITOR_SHOT)} err]} {
		puts "  FAIL screenshot: $err"; incr fails
	} else {
		ok "saves the board's state to the screenshot"
	}
}

if {$fails} { puts "editor diagnostics: $fails checks failed"; exit 1 }
puts "editor diagnostics: all checks passed"
exit 0
