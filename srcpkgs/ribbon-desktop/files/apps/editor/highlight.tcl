# highlight.tcl - Text editor (U27): syntax colours. Two parts, the first with no Tk in it:
#
#   highlight::tokens LANG LINE STATE -> {CLASSES NEWSTATE}, CLASSES a list with one class per character
#       ("" for plain text). STATE carries what a line needs from the line before it (a C block comment, a
#       Markdown code fence); it is "" almost everywhere.
#   highlight::runs CLASSES -> {{START END CLASS} ...} (END exclusive)
#
#   The Tcl rules are gen_editor_r2.py's classify(), rule for rule, in the same order and with the same
#   claim-the-plain-text-first rule, so the boards and the app colour the same tokens. Tcl's regexp has no
#   lookbehind, so the classifier's (?<=...) and (?<!...) checks are done by hand (the char before a match).
#   The other languages are small lexers that keep to the same classes.
#
#   The Tk part retags only what changed: after an edit (idle), highlight::tick compares the text's lines with
#   the lines it last coloured, finds the first and last lines that differ, and retags from the first changed
#   line down, stopping as soon as a line's start state matches what it was (so a new C comment can colour
#   the lines below it, and nothing else is touched).
#
# Classes map to the palette: com SYN_COM italic, str SYN_STR, var SYN_VAR, kw SYN_KW, fn SYN_FN bold,
# num SYN_NUM, opt SYN_OPT, pun SYN_PUN.

namespace eval highlight {
	variable classes {com str var kw fn num opt pun}
	variable colour       ;# class -> #rrggbb, set by highlight::style
	variable stylekey ""
	variable stats        ;# stats(retag): lines retagged, for the tests
	array set stats {retag 0 tick 0}
	variable pending      ;# doc id -> 1 while a tick is queued
	array set pending {}
	variable tclkw {package require namespace eval variable proc set foreach if else return open close puts read
		fconfigure file glob dict lappend regexp split string expr continue lsort list bind grid text after unset for}
	variable shkw {if then else elif fi for while until do done case esac in function return exit local export
		readonly set unset echo cd read shift source eval exec test break continue}
	variable pykw {and as assert break class continue def del elif else except finally for from global if import in
		is lambda nonlocal not or pass raise return try while with yield None True False}
	variable ckw {if else for while do switch case default return break continue struct typedef enum union static const
		void int char long short unsigned signed float double sizeof goto extern inline register volatile auto bool
		true false NULL}
}

# ---- Tcl: the classifier's rules ----

# The rules as gen_editor_r2.py's classify() has them. Each rule claims the characters of its matches that
# are still unclaimed; a match that overlaps a claimed character is dropped (the scan goes on after it).
proc highlight::tok_tcl {line} {
	set n [string length $line]
	set cl [lrepeat $n ""]
	if {[regexp -indices {^\s*#} $line m]} {
		lset_range cl [lindex $m 1] $n com
		return $cl
	}
	variable tclkw
	set kw [join $tclkw |]
	mark cl $line {"(?:[^"\\]|\\.)*"} str 0 "" "" e {\$[\w:]+(?:\([^)]*\))?} var
	mark cl $line {\{[\^#][^\}]*\}} str 0 "" "" e
	mark cl $line {proc ([\w:]+)} fn 1 "" "" s
	mark cl $line {\$[\w:]+(?:\([^)]*\))?} var 0 "" "" e
	mark cl $line {<<\w+>>} str 0 "" "" e
	mark cl $line [format {(?:ttk::\w+|%s)(?![\w:])} $kw] kw 0 "" {[\w:$.-]} e
	mark cl $line {-[a-z][\w-]*} opt 0 {\s} "" e
	mark cl $line {\d+(?:\.\d+)?(?!\w)} num 0 "" {[\w.$#-]} e
	mark cl $line {[{}\[\]\\]} pun 0 "" "" e
	return $cl
}

# Claim the characters of the matches of PAT in LINE for CLS (see tok_tcl). PRE / NOPRE: the character before
# a match must (not) match. GRP 1 takes the first group's span. A match failing PRE/NOPRE is retried one character
# on; one overlapping a claimed character is skipped whole (RESUME e) or from its second character (s).
proc highlight::mark {clvar line pat cls grp pre nopre resume args} {
	upvar 1 $clvar cl
	set n [string length $line]
	set p 0
	while {$p <= $n && [regexp -indices -start $p -- $pat $line m g]} {
		lassign [expr {$grp ? $g : $m}] s e
		set e1 [expr {$e + 1}]
		if {$e1 <= $s} { set p [expr {$s + 1}]; continue }
		set prev [expr {$s > 0 ? [string index $line [expr {$s - 1}]] : ""}]
		if {($pre ne "" && ![regexp -- $pre $prev]) || ($nopre ne "" && [regexp -- $nopre $prev])} {
			set p [expr {$s + 1}]; continue
		}
		set free 1
		for {set i $s} {$i < $e1} {incr i} { if {[lindex $cl $i] ne ""} { set free 0; break } }
		if {!$free} {
			set p [expr {$resume eq "s" ? $s + 1 : $e1}]; continue
		}
		for {set i $s} {$i < $e1} {incr i} { lset cl $i $cls }
		# the inside rules (a $var inside a string)
		foreach {ipat icls} $args {
			set sub [string range $line $s [expr {$e1 - 1}]]
			set q 0
			while {$q < [string length $sub] && [regexp -indices -start $q -- $ipat $sub im]} {
				lassign $im a b
				for {set i $a} {$i <= $b} {incr i} { lset cl [expr {$s + $i}] $icls }
				set q [expr {$b + 1}]
			}
		}
		set p $e1
	}
}

proc highlight::lset_range {clvar from to cls} {
	upvar 1 $clvar cl
	for {set i $from} {$i < $to} {incr i} { lset cl $i $cls }
}

# ---- the other languages: one left-to-right lexer for the programming languages ----

# Shell, Python, C and JSON. Returns {CLASSES STATE}. STATE is "blk" inside a C block comment.
proc highlight::tok_lex {lang line state} {
	variable shkw
	variable pykw
	variable ckw
	set n [string length $line]
	set cl [lrepeat $n ""]
	set i 0
	set kwlist [switch -- $lang {sh {set shkw} py {set pykw} c {set ckw} default {list}}]
	set prevword ""
	if {$lang eq "c" && $state eq "blk"} {
		set e [string first "*/" $line]
		if {$e < 0} { lset_range cl 0 $n com; return [list $cl blk] }
		lset_range cl 0 [expr {$e + 2}] com
		set i [expr {$e + 2}]
	}
	while {$i < $n} {
		set ch [string index $line $i]
		set prev [expr {$i > 0 ? [string index $line [expr {$i - 1}]] : " "}]
		set rest [string range $line $i end]
		# comments
		if {($lang in {sh py} && $ch eq "#" && ($lang eq "py" || $prev in {" " "\t"} || $i == 0))
			|| ($lang eq "c" && [string match "//*" $rest])} {
			lset_range cl $i $n com; break
		}
		if {$lang eq "c" && [string match "/\\**" $rest]} {
			set e [string first "*/" $line [expr {$i + 2}]]
			if {$e < 0} { lset_range cl $i $n com; return [list $cl blk] }
			lset_range cl $i [expr {$e + 2}] com
			set i [expr {$e + 2}]; continue
		}
		# strings, with $vars in shell double quotes
		if {$ch eq "\"" || $ch eq "'"} {
			set j [expr {$i + 1}]
			while {$j < $n && [string index $line $j] ne $ch} {
				if {[string index $line $j] eq "\\"} { incr j }
				incr j
			}
			set j [expr {min($j, $n - 1)}]
			set after [string trimleft [string range $line [expr {$j + 1}] end]]
			lset_range cl $i [expr {$j + 1}] [expr {$lang eq "json" && [string index $after 0] eq ":" ? "opt" : "str"}]
			if {$lang eq "sh" && $ch eq "\""} { varspans cl $line $i [expr {$j + 1}] }
			set i [expr {$j + 1}]; set prevword ""; continue
		}
		# shell and Python and C words, numbers, variables, options
		if {$ch eq "\$" && $lang eq "sh"} {
			regexp -indices {\$\{?[\w@#?*!-]+\}?} [string range $line $i end] m
			if {[info exists m]} { lset_range cl $i [expr {$i + [lindex $m 1] + 1}] var; set i [expr {$i + [lindex $m 1] + 1}]; continue }
		}
		if {[string is alpha -strict $ch] || $ch eq "_"} {
			set j $i
			while {$j < $n && ([string is alnum -strict [string index $line $j]] || [string index $line $j] eq "_")} { incr j }
			set word [string range $line $i [expr {$j - 1}]]
			if {$lang eq "json"} {
				set after [string trimleft [string range $line $j end]]
				set cls [expr {[string index $after 0] eq ":" ? "opt" : [expr {$word in {true false null} ? "kw" : ""}]}]
				if {$cls ne ""} { lset_range cl $i $j $cls }
			} elseif {$prevword in {def class proc function}} {
				lset_range cl $i $j fn
			} elseif {$word in $kwlist} {
				lset_range cl $i $j kw
			} elseif {$lang eq "c" && [string index $line $j] eq "("} {
				lset_range cl $i $j fn
			}
			set prevword $word
			set i $j; continue
		}
		if {[string is digit -strict $ch] && ![string is alnum -strict $prev]} {
			set j $i
			while {$j < $n && ([string is alnum -strict [string index $line $j]] || [string index $line $j] eq ".")} { incr j }
			lset_range cl $i $j num; set i $j; set prevword ""; continue
		}
		if {$lang eq "sh" && $ch eq "-" && ($prev eq " " || $prev eq "\t") && [string is alpha -strict [string index $line [expr {$i + 1}]]]} {
			set j [expr {$i + 1}]
			while {$j < $n && ([string is alnum -strict [string index $line $j]] || [string index $line $j] in {_ -})} { incr j }
			lset_range cl $i $j opt; set i $j; continue
		}
		if {[string first $ch "{}\[\]()"] >= 0} { lset cl $i pun }
		if {$ch ne " " && $ch ne "\t"} { set prevword "" }
		incr i
	}
	return [list $cl ""]
}

# shell: the $vars inside a double-quoted string [from, to)
proc highlight::varspans {clvar line from to} {
	upvar 1 $clvar cl
	set sub [string range $line $from [expr {$to - 1}]]
	set q 0
	while {[regexp -indices -start $q {\$\{?[\w@#?*!-]+\}?} $sub m]} {
		lassign $m a b
		lset_range cl [expr {$from + $a}] [expr {$from + $b + 1}] var
		set q [expr {$b + 1}]
	}
}

# INI and .conf: comments, [sections], key = value. Line-level, no state.
proc highlight::tok_ini {line} {
	set n [string length $line]
	set cl [lrepeat $n ""]
	if {[regexp {^\s*[#;]} $line]} { lset_range cl 0 $n com; return $cl }
	if {[regexp -indices {^\s*\[[^\]]*\]} $line m]} { lset_range cl [lindex $m 0] [expr {[lindex $m 1] + 1}] fn; return $cl }
	set eq [string first "=" $line]
	if {$eq >= 0} {
		set key [string length [string trimright [string range $line 0 [expr {$eq - 1}]]]]
		lset_range cl 0 $key opt
		lset cl $eq pun
		lset_range cl [expr {$eq + 1}] $n str
	}
	return $cl
}

# Diff: file headers, hunks, added and removed lines.
proc highlight::tok_diff {line} {
	set n [string length $line]
	set cl [lrepeat $n ""]
	switch -glob -- $line {
		+++* - ---* - diff* - index* { lset_range cl 0 $n fn }
		@@* { lset_range cl 0 $n kw }
		+* { lset_range cl 0 $n str }
		-* { lset_range cl 0 $n num }
	}
	return $cl
}

# Markdown: headings, quotes, bullets, inline code and code fences (state "fence" inside one).
proc highlight::tok_md {line state} {
	set n [string length $line]
	set cl [lrepeat $n ""]
	if {[regexp {^\s*```} $line]} {
		lset_range cl 0 $n com
		return [list $cl [expr {$state eq "fence" ? "" : "fence"}]]
	}
	if {$state eq "fence"} { lset_range cl 0 $n str; return [list $cl fence] }
	if {[regexp {^#{1,6} } $line]} { lset_range cl 0 $n fn; return [list $cl ""] }
	if {[regexp {^>} $line]} { lset_range cl 0 $n com; return [list $cl ""] }
	if {[regexp -indices {^\s*[-*+] } $line m]} { lset_range cl [lindex $m 0] [expr {[lindex $m 1] + 1}] kw }
	mark cl $line {`[^`]*`} str 0 "" "" e
	return [list $cl ""]
}

# JSON: keys (strings before a colon) are options, values strings, numbers, true/false/null, brackets.
proc highlight::tok_json {line} {
	lindex [tok_lex json $line ""] 0
}

# The tokens for LANG (sh py c json ini diff md tcl, or "") on LINE, starting in STATE: {CLASSES NEWSTATE}.
proc highlight::tokens {lang line state} {
	switch -- $lang {
		tcl { list [tok_tcl $line] "" }
		sh - py - c { tok_lex $lang $line $state }
		json { list [tok_json $line] "" }
		ini { list [tok_ini $line] "" }
		diff { list [tok_diff $line] "" }
		md { tok_md $line $state }
		default { list [lrepeat [string length $line] ""] "" }
	}
}

# Runs of one class: {{start end class} ...}, end exclusive.
proc highlight::runs {cl} {
	set out {}
	set n [llength $cl]
	set i 0
	while {$i < $n} {
		set c [lindex $cl $i]
		if {$c eq ""} { incr i; continue }
		set j $i
		while {$j < $n && [lindex $cl $j] eq $c} { incr j }
		lappend out [list $i $j $c]
		set i $j
	}
	return $out
}

# ---- Tk: the tags, and the retag after an idle tick ----

# Per document: S(ID,lang) the language code ("" = plain, no tags), S(ID,lines) the lines last coloured,
# S(ID,entry) the start state of each line plus the state after the last one (one more entry than lines).
namespace eval highlight {
	variable S
	variable fonts
}

# The colour of each class from the active palette, and the tag set on widget W.
proc highlight::style {w} {
	variable colour
	variable fonts
	foreach cls $::highlight::classes {
		set colour($cls) $::theme::c(SYN_[string toupper $cls])
	}
	set mono $::editor::mono
	set px $::editor::monosize
	if {![info exists fonts(it)]} {
		set fonts(it) [font create ribbon-editor-code-it -family $mono -size -$px -slant italic]
		set fonts(bd) [font create ribbon-editor-code-bd -family $mono -size -$px -weight bold]
	}
	foreach cls $::highlight::classes {
		set f [switch -- $cls { com { set fonts(it) } fn { set fonts(bd) } default { set ::editor::codefont } }]
		$w tag configure syn_$cls -foreground $colour($cls) -font $f
	}
}

# Restyle every open document when the palette has changed (apply_theme calls this each paint).
proc highlight::restyle {} {
	variable colour
	set key [list]
	foreach cls $::highlight::classes { lappend key $::theme::c(SYN_[string toupper $cls]) }
	if {[info exists ::highlight::colour_key] && $key eq $::highlight::colour_key} return
	set ::highlight::colour_key $key
	foreach id [split::union] { style $::doc::D($id,w) }
}

# A document is set up: its tags, then the whole text coloured (one full retag).
proc highlight::install {id} {
	variable S
	set S($id,lang) [::doc::syntax $id]
	set S($id,lines) {}
	set S($id,entry) [list ""]
	style $::doc::D($id,w)
	tick $id
}

# Queue a retag for when Tk is idle (edits come in bursts; one retag covers them).
proc highlight::schedule {id} {
	variable pending
	if {[info exists pending($id)]} return
	set pending($id) [after idle [list ::highlight::tick $id]]
}

# Retag what changed since the last tick. Lines before the first change and after the last keep their tags.
proc highlight::tick {id} {
	variable S
	variable pending
	variable stats
	catch {unset pending($id)}
	if {![info exists ::doc::D($id,w)] || ![info exists S($id,lang)] || $S($id,lang) eq ""} return
	incr stats(tick)
	set lang $S($id,lang)
	set t $::doc::D($id,w)
	set new [split [$t get 1.0 end-1c] \n]
	set old $S($id,lines)
	set entry $S($id,entry)
	set n [llength $new]; set m [llength $old]
	set lim [expr {min($n, $m)}]
	set p 0
	while {$p < $lim && [lindex $new $p] eq [lindex $old $p]} { incr p }
	set q 0
	while {$q < $lim - $p && [lindex $new [expr {$n - 1 - $q}]] eq [lindex $old [expr {$m - 1 - $q}]]} { incr q }
	if {$n == $m && $p == $n} return
	set delta [expr {$n - $m}]
	set newentry [lrange $entry 0 [expr {$p - 1}]]
	set st [lindex $entry $p]
	set k $p
	set same 0
	while {$k < $n} {
		# past the changed lines, a line whose start state is what it was means the rest is still right
		if {$k >= $n - $q && [lindex $entry [expr {$k - $delta}]] eq $st} { set same 1; break }
		lappend newentry $st
		lassign [tokens $lang [lindex $new $k] $st] cl st
		foreach cls $::highlight::classes { $t tag remove syn_$cls [expr {$k + 1}].0 [expr {$k + 1}].end }
		foreach r [runs $cl] {
			lassign $r a b c
			$t tag add syn_$c [expr {$k + 1}].$a [expr {$k + 1}].$b
		}
		incr stats(retag)
		incr k
	}
	if {$same} {
		lappend newentry {*}[lrange $entry [expr {$k - $delta}] end]
	} else {
		lappend newentry $st
	}
	set S($id,lines) $new
	set S($id,entry) $newentry
}

proc editor::highlight_install {id} { highlight::install $id }
