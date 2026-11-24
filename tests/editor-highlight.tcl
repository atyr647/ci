# editor-highlight.tcl - the text editor's syntax colours (U27), run by apps/editor/main.tcl through
# RIBBON_EDITOR_SCENE=this file, with RIBBON_EDITOR_FIXTURES = a temp folder.
# 1. golden tokens: each language's sample lines, as "class:text" runs (highlight::tokens and highlight::runs);
#    the Tcl lines are the classifier's cases in gen_editor_r2.py.
# 2. the Tk tags: a file of each language opened, its syn_ tags on known characters.
# 3. the incremental retag: an edit in the middle of a long file retags one line; an edit that opens a C block
#    comment retags down to where the comment is closed, and no further; an unchanged text retags nothing.
# Prints "  ok ..." per check; exits 0 when all pass, 1 otherwise.
set dir $::env(RIBBON_EDITOR_FIXTURES)
file mkdir $dir
set fails 0
proc ok {what} { puts "  ok   $what"; flush stdout }
proc bad {what got} { global fails; incr fails; puts "  FAIL $what (got: $got)" }
proc check {what cond} { if {[uplevel 1 [list expr $cond]]} { ok $what } else { bad $what "condition false: $cond" } }
proc write_bytes_ {path bytes} { set fh [open $path wb]; puts -nonewline $fh $bytes; close $fh }
proc bgerror {msg} { puts stderr "editor-highlight: $msg\n$::errorInfo"; exit 1 }

# the runs of LINE in LANG as "class:text" joined by " | " (plain text runs are left out)
proc runs_of {lang line {state ""}} {
	lassign [highlight::tokens $lang $line $state] cl ns
	set out {}
	foreach r [highlight::runs $cl] {
		lassign $r a b c
		lappend out "$c:[string range $line $a [expr {$b - 1}]]"
	}
	return [join $out " | "]
}

# ---- 1. golden tokens ----
set golden {
	{tcl {proc ::notes::store::parse {text} {}} {kw:proc | fn:::notes::store::parse | pun:{ | kw:text | pun:} | pun:{}}}
	{tcl {    set pinned [expr {$flag eq "yes"}]} {kw:set | pun:[ | kw:expr | pun:{ | var:$flag | str:"yes" | pun:}]}}
	{tcl {    if {[regexp {^# (.+)$} $line -> title]} continue} {kw:if | pun:{[ | kw:regexp | str:{^# (.+)$} | var:$line | pun:]} | kw:continue}}
	{tcl {lappend tags "[string range $tag 1 end] $x" -nocomplain 42 a1} {kw:lappend | str:"[string range  | var:$tag | str: 1 end]  | var:$x | str:" | opt:-nocomplain | num:42}}
	{tcl {# a comment $x} {com:# a comment $x}}
	{sh {if [ -n "$HOME" ]; then echo '$x' -v; fi # done} {kw:if | pun:[ | opt:-n | str:" | var:$HOME | str:" | pun:] | kw:then | kw:echo | str:'$x' | opt:-v | kw:fi | com:# done}}
	{py {def f(x): return "#fff" + 3  # note} {kw:def | fn:f | pun:( | pun:) | kw:return | str:"#fff" | num:3 | com:# note}}
	{c {int main(int a) /* hi */ return 0x1F; // done} {kw:int | fn:main | pun:( | kw:int | pun:) | com:/* hi */ | kw:return | num:0x1F | com:// done}}
	{json {  "name": "rebos", "n": 12, "ok": true} {opt:"name" | str:"rebos" | opt:"n" | num:12 | opt:"ok" | kw:true}}
	{ini {[core]} {fn:[core]}}
	{ini {mode = fast} {opt:mode | pun:= | str: fast}}
	{diff {+added line} {str:+added line}}
	{diff {@@ -1,2 +1,2 @@} {kw:@@ -1,2 +1,2 @@}}
	{md {# Title} {fn:# Title}}
	{md {Use `code` here} {str:`code`}}
}
foreach g $golden {
	lassign $g lang line want
	set got [runs_of $lang $line]
	if {$got eq $want} { ok "$lang: $line" } else { bad "$lang: $line" $got }
}
# the C block comment runs across lines: the state carries
lassign [highlight::tokens c "/* open" ""] cl st
check "c: an open block comment carries its state" {$st eq "blk"}
check "c: the next line is a comment until its close" {[runs_of c "still inside */ int x;" blk] eq "com:still inside */ | kw:int"}
check "md: a code fence colours its lines as strings" {[runs_of md "x = 1" fence] eq "str:x = 1"}

# ---- 2. the Tk tags: one file of each language ----
set samples [dict create \
	tcl "proc greet {who} {\n    puts \"hello \$who\" ;# say it\n}\n" \
	sh "if \[ -n \"\$HOME\" \]; then\n    echo ok\nfi\n" \
	py "def f(x):\n    return \"#fff\"  # note\n" \
	c "int main(void)\n{\n    /* block */ return 0;\n}\n" \
	json "{\n  \"name\": true\n}\n" \
	ini "\[core\]\nmode = fast\n" \
	diff "--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new\n" \
	md "# Title\n\nUse \`code\`.\n```\nx\n```\n"]
foreach {lang text} $samples {
	set f [file join $dir sample.$lang]
	set fh [open $f wb]; fconfigure $fh -translation binary; puts -nonewline $fh $text; close $fh
	set id [editor::open_path $f]
	set t $::doc::D($id,w)
	set tags [lsort -unique [lmap nm [$t tag names] {expr {[string match syn_* $nm] ? $nm : [continue]}}]]
	if {[llength $tags] >= 3} { ok "$lang: the file has colour tags ($tags)" } else { bad "$lang: colour tags" $tags }
	editor::force_close $id
}
# and the tags land on the right characters, by language
set f [file join $dir t.tcl]; write_bytes_ $f "set x 1\n"
set id [editor::open_path $f]
set t $::doc::D($id,w)
check "tcl: set is a keyword on line 1" {[$t tag names 1.0] eq "syn_kw"}
check "tcl: the keyword's tag colour is the palette's SYN_KW" {[$t tag cget syn_kw -foreground] eq $::theme::c(SYN_KW)}
check "tcl: a number is SYN_NUM" {[$t tag names 1.6] eq "syn_num"}

# ---- 3. the incremental retag ----
set f [file join $dir long.tcl]
set body ""
for {set i 1} {$i <= 200} {incr i} { append body "set v$i \[expr {$i + 1}\] ;# line $i\n" }
write_bytes_ $f $body
set id [editor::open_path $f]
highlight::tick $id
array set ::highlight::stats {retag 0 tick 0}
$::doc::D($id,w) insert 100.0 "# edited\n"
highlight::tick $id
check "an edit in the middle retags only its lines (one changed, one inserted)" {$::highlight::stats(retag) <= 2}
check "retagging keeps the rest coloured" {[llength [$::doc::D($id,w) tag ranges syn_kw]] > 100}
array set ::highlight::stats {retag 0 tick 0}
highlight::tick $id
check "an unchanged text retags nothing" {$::highlight::stats(retag) == 0}
# a C file: opening a block comment near the top retags down to its close, and no further
set c [file join $dir long.c]
set cb ""
for {set i 1} {$i <= 60} {incr i} { append cb "int v$i = $i;\n" }
write_bytes_ $c $cb
set id [editor::open_path $c]
highlight::tick $id
array set ::highlight::stats {retag 0 tick 0}
$::doc::D($id,w) insert 1.0 "/* "
$::doc::D($id,w) insert 5.end " */"
highlight::tick $id
check "a comment that closes on its own line retags only the lines it touches" {$::highlight::stats(retag) <= 6}
# a fresh copy: a comment opened at line 3 with nothing closing it turns the rest of the file into a comment
editor::force_close $id
set c2 [file join $dir long2.c]; write_bytes_ $c2 $cb
set id [editor::open_path $c2]
highlight::tick $id
array set ::highlight::stats {retag 0 tick 0}
$::doc::D($id,w) insert 3.0 "/* "
highlight::tick $id
check "an open comment with nothing closing it retags to the end" {$::highlight::stats(retag) >= 55}

if {$fails} { puts "editor highlight: $fails checks failed"; exit 1 }
puts "editor highlight: all checks passed"
exit 0
