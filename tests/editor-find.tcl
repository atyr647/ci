# editor-find.tcl - the text editor's find and replace (U29), run by apps/editor/main.tcl through RIBBON_EDITOR_SCENE=this
# file, with RIBBON_EDITOR_FIXTURES = a temp folder (and XDG_STATE_HOME, where the options are saved).
# 1. the counts: plain text, Match case, Whole word, a regular expression, an invalid one ("No match"), an empty find.
# 2. the current match: the first at or after the caret; Enter and Down go on, Shift+Enter and Up go back, with wrap.
# 3. the keys, as events on the window: Ctrl+F (find, the focus in the find field), Ctrl+H (replace, the focus in the
#    replace field), Enter in the replace field (Replace), Ctrl+Alt+Enter (Replace all), Esc (close, the caret on the
#    current match); the page sits under the bar while it is open.
# 4. Replace and Replace all are one undo step each; Undo reverts the last; the options are saved per user.
# 5. Ctrl+Z and Ctrl+Shift+Z in the text (as key events) keep "N replaced" right; a regular expression's replacement
#    takes its groups (\1, &), and a plain one is literal.
# Prints "  ok ..." per check; exits 0 when all pass, 1 otherwise.
set dir $::env(RIBBON_EDITOR_FIXTURES)
file mkdir $dir
set fails 0
proc ok {what} { puts "  ok   $what"; flush stdout }
proc check {what cond} {
	if {[uplevel 1 [list expr $cond]]} { ok $what } else { global fails; incr fails; puts "  FAIL $what" }
}
proc bgerror {msg} { puts stderr "editor-find: $msg\n$::errorInfo"; exit 1 }
proc write_text {path text} {
	set fh [open $path wb]
	fconfigure $fh -translation binary
	puts -nonewline $fh [encoding convertto utf-8 $text]
	close $fh
}
proc press {keysym} { focus -force $::editor::win; event generate $::editor::win <$keysym>; update }

set src "text one\nTexting and text\nthe word texts\nconst x = 1\n"
set p [file join $dir find.txt]
write_text $p $src
set id [editor::open_path $p]
editor::activate $id
set t $::doc::D($id,w)
proc count {} { llength $::find::matches }
proc doc_text {} { $::doc::D($::editor::active,w) get 1.0 end-1c }

puts "counts"
ui::fset find.q text
find::show_bar find
check "Ctrl+F's bar opens in Find mode with the focus in the find field" {$::find::open && $::find::mode eq "find" && $::ui::focus eq "find.q"}
check "the page sits under the bar" {[update idletasks; winfo y $::editor::page] == [editor::body_top]}
check "plain text, Match case: three matches" {[find::changed; count] == 3}
set ::find::opts(case) 0; find::refresh
check "Match case off: four (Texting counts)" {[count] == 4}
set ::find::opts(case) 1; set ::find::opts(word) 1; find::refresh
check "Whole word: two (texts is not a whole word)" {[count] == 2}
set ::find::opts(word) 0; set ::find::opts(regex) 1; ui::fset find.q {\d}; find::changed
check "a regular expression: one digit" {[count] == 1}
ui::fset find.q {x = 1}; set ::find::opts(regex) 0; find::changed
check "plain text is literal: x = 1 is one match" {[count] == 1}
ui::fset find.q {(}; set ::find::opts(regex) 1; find::changed
check "an invalid regular expression: no match, and the flag is set" {[count] == 0 && $::find::err}
ui::fset find.q ""; set ::find::opts(regex) 0; find::changed
check "an empty find has no matches" {[count] == 0 && !$::find::err}

puts "current"
ui::fset find.q text; set ::find::opts(case) 1; set ::find::opts(word) 0; find::changed
$t mark set insert 2.0
find::nearest
check "the current match is the first at or after the caret" {$::find::cur == 1}
press Return
check "Enter goes to the next match" {$::find::cur == 2}
press Return
check "Enter past the last wraps to the first" {$::find::cur == 0}
press Shift-Return
check "Shift+Enter goes to the previous match, wrapping" {$::find::cur == 2}
press Down
check "Down goes to the next match" {$::find::cur == 0}
press Up
check "Up goes to the previous match" {$::find::cur == 2}
check "the caret is on the current match" {[$t index insert] eq [$t index "1.0 +[lindex [lindex $::find::matches 2] 0]c"]}
check "the dropdown names what is on" {[find::dropdown_label] eq "Match case"}
find::toggle_opt case
check "or Options when nothing is" {[find::dropdown_label] eq "Options"}
find::toggle_opt case

puts "keys"
press Escape
check "Esc closes the bar and puts the caret on the current match" {!$::find::open && [editor::body_top] == 46}
press Control-f
check "Ctrl+F opens the find bar again" {$::find::open && $::find::mode eq "find"}
press Escape
press Control-h
check "Ctrl+H opens Replace with the focus in the replace field" {$::find::open && $::find::mode eq "replace" && $::ui::focus eq "find.r"}
check "the page moves down for the replace row" {[update idletasks; winfo y $::editor::page] == 46 + 92}
ui::fset find.r body
$t mark set insert 1.0; find::changed
press Return
check "Enter in the replace field replaces the current match" {[doc_text] eq "body one\nTexting and text\nthe word texts\nconst x = 1\n"}
check "the count shows one replaced" {$::find::replaced == 1}
check "and the matches left are the two after it" {[count] == 2}
find::undo
check "Undo reverts the replace (one step)" {[doc_text] eq $src && $::find::replaced == 0}
ui::fset find.r T
press Control-Alt-Return
check "Ctrl+Alt+Enter replaces all" {[doc_text] eq "T one\nTexting and T\nthe word Ts\nconst x = 1\n" && $::find::replaced == 3}
catch {$t edit undo}
check "Undo after Replace all is one step: the whole text comes back" {[doc_text] eq $src}

puts "replace and undo"
ui::fset find.r T; $t mark set insert 1.0; find::changed
find::replace_all
check "Replace all changes every match in one call" {[doc_text] eq "T one\nTexting and T\nthe word Ts\nconst x = 1\n"}
find::undo
check "the Undo button reverts it" {[doc_text] eq $src && $::find::replaced == 0}
ui::fset find.r T; $t mark set insert 1.0; find::changed
find::replace_one
find::replace_one
check "two Replaces, one at a time, change the first two" {[doc_text] eq "T one\nTexting and T\nthe word texts\nconst x = 1\n"}
check "the count is two" {$::find::replaced == 2}
catch {$t edit undo}
check "Ctrl+Z reverts the last Replace only" {[doc_text] eq "T one\nTexting and text\nthe word texts\nconst x = 1\n"}
find::undo
ui::fset find.r ""

puts "undo keys"
# the keys as the person presses them in the text: Tk's <<Undo>> and <<Redo>> (Control-z, Control-Z)
proc tkey {keysym} { global t; focus -force $t; update; event generate $t <$keysym>; update }
ui::fset find.q text; ui::fset find.r T; $t mark set insert 1.0; find::changed
find::replace_one
find::replace_one
check "two Replaces: the count is two" {$::find::replaced == 2}
tkey Control-z
check "Ctrl+Z in the text reverts the last Replace and the count says one" {
	[doc_text] eq "T one\nTexting and text\nthe word texts\nconst x = 1\n" && $::find::replaced == 1}
tkey Control-z
check "a second Ctrl+Z reverts the first and the count says none" {[doc_text] eq $src && $::find::replaced == 0}
tkey Control-Z
check "Ctrl+Shift+Z puts the first back and the count says one" {
	[doc_text] eq "T one\nTexting and text\nthe word texts\nconst x = 1\n" && $::find::replaced == 1}
tkey Control-z
find::replace_all
check "Replace all of three: the count is three" {$::find::replaced == 3}
$t insert end "z"
tkey Control-z
check "Ctrl+Z of a typed edit after it leaves the count alone" {$::find::replaced == 3}
tkey Control-z
check "the next Ctrl+Z reverts the Replace all and the count goes back to none" {[doc_text] eq $src && $::find::replaced == 0}
# a Replace undone, then a typed edit undone: Ctrl+Shift+Z redoes the edit (Tk's redo of the Replace went with the edit)
find::replace_one
tkey Control-z
$t insert end "q"
tkey Control-z
tkey Control-Z
check "Ctrl+Shift+Z that redoes a typed edit, not the Replace, leaves the count at none" {
	[doc_text] eq "${src}q" && $::find::replaced == 0}
$t delete 1.0 end; $t insert 1.0 $src; $t edit reset; find::changed
# a Replace, then a typed character and its deletion: the text is the Replace's again, but Ctrl+Z undoes the deletion
find::replace_one
$t insert end "x"
$t delete "end-2c" "end-1c"
tkey Control-z
check "Ctrl+Z that undoes a deletion, not the Replace, keeps the count at one" {
	[doc_text] eq "T one\nTexting and text\nthe word texts\nconst x = 1\nx" && $::find::replaced == 1}
$t delete 1.0 end; $t insert 1.0 $src; $t edit reset; find::changed

puts "regex replace"
set rsrc "width=640 height=480\nplain & text\n"
$t delete 1.0 end; $t insert 1.0 $rsrc; $t edit reset
set ::find::opts(regex) 1
ui::fset find.q {(\w+)=(\d+)}; ui::fset find.r {\2=\1}; $t mark set insert 1.0; find::changed
find::replace_one
check "a regular expression's replacement takes its groups: (w+)=(d+) to 2=1" {
	[doc_text] eq "640=width height=480\nplain & text\n"}
find::replace_all
check "Replace all expands the groups of each match" {[doc_text] eq "640=width 480=height\nplain & text\n"}
ui::fset find.q {[a-z]+}; ui::fset find.r {<&>}; $t mark set insert 1.0; find::changed
find::replace_one
check "& is the whole match" {[string range [doc_text] 0 13] eq "640=<width> 48"}
set ::find::opts(regex) 0
ui::fset find.q {plain}; ui::fset find.r {\1 & x}; find::changed
find::replace_all
check "without Regular expression the replacement is literal" {[string first {\1 & x & text} [doc_text]] >= 0}
$t delete 1.0 end; $t insert 1.0 $src; $t edit reset
ui::fset find.q text; ui::fset find.r ""; find::changed

puts "options"
set ::find::opts(word) 0
find::toggle_opt word
check "an option toggles, and the dropdown names it" {$::find::opts(word) && [find::dropdown_label] eq "Match case, Whole word"}
check "the options are saved per user" {[file exists [find::opt_file]]}
set ::find::opts(word) 0
find::load
check "and load again from the saved file" {$::find::opts(word) == 1 && $::find::opts(case) == 1}
find::menu_click 10 40
check "a click on a menu row toggles that option" {$::find::opts(word) == 0}
find::close_menu
check "the menu closes" {!$::find::menu}
press Escape
check "Esc closes the bar" {!$::find::open && [winfo y $::editor::page] == 46}

editor::force_close $id
if {$fails} { puts "editor find: $fails checks failed"; exit 1 }
puts "editor find: all checks passed"
exit 0
