# find.tcl - Text editor (U29): find and replace, mode B (STYLE §20; Editor-Final-3-Find-B; the code list's Find & replace
# items 1 to 6). A bar docked under the tab strip, on the page surface, which pushes the text down; a 1 px rule under it.
#   find row:    the find field (400 wide; search icon; "4 of 6" at its right end), up and down, the options dropdown
#                (132), then at the right the Find | Replace segmented control (32) and the close ×.
#   replace row (Replace mode only): the replace field, Replace, Replace all N, and at the right "N replaced" and Undo.
# Matches have a 10 % wash; the current match has the accent fill and ink text. The options (Match case, Whole word,
# Regular expression) are a dropdown and are saved per user; an invalid pattern reads "No match". Replace, Replace all
# and Undo each act as one undo step. Keys: Ctrl+F (Find), Ctrl+H (Replace, focus in the replace field), Enter and Down
# (next), Shift+Enter and Up (previous), Enter in the replace field (Replace), Ctrl+Alt+Enter (Replace all), Esc (close:
# the caret goes to the current match).
#
# The bar is drawn on the chrome canvas each paint (main.tcl calls find::paint between the tabs and the status line).
# Its fields are ui library fields, so the keys go to ui::field_key while the window has the focus (see find::key).
# The options menu is a small canvas over the page (find::raise_menu), because the page is a Tk widget.

namespace eval find {
	variable open 0
	variable mode find          ;# find | replace (remembered per window)
	variable opts               ;# array: case, word, regex (1 or 0); saved per user
	array set opts {case 1 word 0 regex 0}
	variable cur 0              ;# index of the current match in the active document
	variable matches {}         ;# {start end} character offsets of the matches in the active document
	variable err 0              ;# the pattern does not compile
	variable replaced 0         ;# replacements since the find text last changed
	variable hist               ;# array: ID -> {{n before after} ...}: each Replace's count and the text's sums around it
	variable redo               ;# array: ID -> the same, for the Replaces undone (Redo puts them back)
	array set hist {}
	array set redo {}
	variable menu 0             ;# the options menu is open
	variable mcanvas .w.fm      ;# the options menu's canvas
	variable menuimg ""
	variable X 88               ;# the fields line up with the code (TEXT_X)
	variable FW 400
	variable R1 56              ;# the find row's top; the replace row is 40 lower
	variable R2 96
	variable DDW 132
	variable MENUX 578          ;# the dropdown's left (DD_X)
	variable MENUY 94
}

# The bar's height: none when closed; 52 for the find row; 92 with the replace row too.
proc find::height {} {
	variable open
	variable mode
	if {!$open} { return 0 }
	expr {$mode eq "replace" ? 92 : 52}
}

# ---- the options, saved per user (beside the recent list) ----

proc find::opt_file {} { file join [file dirname [::doc::state_file]] find }

proc find::load {} {
	variable opts
	if {![info exists ::ui::focus]} { set ::ui::focus "" }
	catch {
		set fh [open [opt_file] r]
		set text [read $fh]
		close $fh
		foreach {k v} $text {
			if {[info exists opts($k)] && [string is boolean -strict $v]} { set opts($k) [expr {$v ? 1 : 0}] }
		}
	}
}

proc find::save_opts {} {
	variable opts
	catch {
		set f [opt_file]
		file mkdir [file dirname $f]
		set fh [open $f w]
		puts $fh [list case $opts(case) word $opts(word) regex $opts(regex)]
		close $fh
	}
}

# ---- matching ----

# The pattern for the find text: plain text is escaped (Tcl's RE characters); Whole word wraps it in \y (a word
# boundary on each side).
proc find::pattern {q} {
	variable opts
	if {!$opts(regex)} {
		set out ""
		foreach ch [split $q ""] {
			if {[string first $ch {\.*+?()|^$[]{}}] >= 0} { append out \\ }
			append out $ch
		}
		set q $out
	}
	if {$opts(word)} { set q "\\y(?:$q)\\y" }
	return $q
}

# The matches of the find text in TEXT: {start end} offsets (end exclusive), in order. Empty matches are skipped.
proc find::matches_in {text} {
	variable opts
	variable err
	set err 0
	set q [ui::fval find.q]
	if {$q eq ""} { return {} }
	set pat [pattern $q]
	set flags {}
	if {!$opts(case)} { set flags -nocase }
	if {[catch {regexp {*}$flags -- $pat ""}]} { set err 1; return {} }
	set out {}
	set pos 0
	set n [string length $text]
	while {$pos <= $n && [regexp -indices -start $pos {*}$flags -- $pat $text m]} {
		lassign $m s e
		if {$e >= $s} {
			lappend out [list $s [expr {$e + 1}]]
			set pos [expr {$e + 1}]
		} else {
			set pos [expr {$s + 1}]
		}
	}
	return $out
}

# The matches of the active document, with the current one kept in range.
proc find::compute {} {
	variable matches
	variable cur
	set id $::editor::active
	if {$id eq "" || ![info exists ::doc::D($id,w)]} { set matches {}; return }
	set matches [matches_in [[editor::tw $id] get 1.0 end-1c]]
	if {$cur >= [llength $matches]} { set cur 0 }
}

# The current match: the first at or after the caret (the first match when none is).
proc find::nearest {} {
	variable matches
	variable cur
	set cur 0
	set id $::editor::active
	if {$id eq "" || ![llength $matches]} return
	set pos [[editor::tw $id] count -chars 1.0 insert]
	set i 0
	foreach m $matches {
		if {[lindex $m 0] >= $pos} { set cur $i; return }
		incr i
	}
}

# The caret on the current match, scrolled into view.
proc find::goto {} {
	variable matches
	variable cur
	if {![llength $matches]} return
	set t [editor::tw $::editor::active]
	lassign [lindex $matches $cur] s e
	$t mark set insert "1.0 +${s}c"
	$t see insert
}

# The tags that show the matches, on the active document. find_done (the replaced text) is kept until the bar closes.
proc find::mark {} {
	variable matches
	variable cur
	foreach id [split::union] {
		if {[info exists ::doc::D($id,w)]} {
			[editor::tw $id] tag remove find_hit 1.0 end
			[editor::tw $id] tag remove find_cur 1.0 end
		}
	}
	set id $::editor::active
	if {$id eq ""} return
	set t [editor::tw $id]
	$t tag configure find_hit -background [well::mix $::editor::c(bar) $::editor::c(fg) 0.10]
	$t tag configure find_cur -background $::editor::c(accent) -foreground $::editor::c(on_accent)
	$t tag configure find_done -background [well::mix $::editor::c(bar) $::editor::c(vmod) 0.13]
	foreach m $matches {
		lassign $m s e
		$t tag add find_hit "1.0 +${s}c" "1.0 +${e}c"
	}
	if {[llength $matches]} {
		lassign [lindex $matches $cur] s e
		$t tag add find_cur "1.0 +${s}c" "1.0 +${e}c"
	}
	$t tag raise find_hit
	$t tag raise find_done
	$t tag raise find_cur
}

proc find::clear_tags {} {
	foreach id [split::union] {
		if {[info exists ::doc::D($id,w)]} {
			foreach tg {find_hit find_cur find_done} { [editor::tw $id] tag remove $tg 1.0 end }
		}
	}
}

# ---- showing and closing ----

# Find (MODE find) or Replace (MODE replace) opens the bar, with the focus in its find field or its replace field. With
# one line selected in the text, that line is the find text.
proc find::show_bar {m} {
	variable open
	variable mode
	if {!$open} {
		set open 1
		set id $::editor::active
		if {$id ne ""} {
			set sel [[editor::tw $id] tag ranges sel]
			if {[llength $sel] == 2} {
				set s [[editor::tw $id] get [lindex $sel 0] [lindex $sel 1]]
				if {$s ne "" && ![string match *\n* $s]} { ui::fset find.q $s }
			}
		}
	}
	set mode $m
	set ::ui::focus [expr {$m eq "replace" ? "find.r" : "find.q"}]
	ui::fset find.q [ui::fval find.q]
	ui::fset find.r [ui::fval find.r]
	compute
	nearest
	focus $::editor::win
	ui::blink
	editor::schedule
}

proc find::close_bar {args} {
	variable open
	variable menu
	variable replaced
	if {!$open} return
	compute
	goto
	set open 0
	set menu 0
	set replaced 0
	forget
	clear_tags
	hide_menu
	set ::ui::focus ""
	editor::focus_text
	editor::schedule
}

proc find::escape {} {
	variable menu
	if {$menu} { close_menu; return }
	close_bar
}

# Focus and keys. A press in the text gives the keyboard to the text; the field stays where it was typed.
proc find::text_pressed {} {
	variable menu
	set ::ui::focus ""
	if {$menu} close_menu
}

proc find::field_focus {} {
	expr {[lsearch -exact {find.q find.r} $::ui::focus] >= 0}
}

# A key while the window has the focus: the field being typed in takes it. Returns 1 when it was used.
proc find::key {sym char} {
	variable open
	if {!$open} { return 0 }
	switch -- $sym {
		Down { step 1; return 1 }
		Up { step -1; return 1 }
	}
	if {![field_focus]} { return 0 }
	return [ui::field_key $::ui::focus $sym $char 0]
}

# Return (SHIFT 1 for Shift+Return): the replace field does Replace; the find field goes to the next match.
proc find::enter {shift} {
	if {$::ui::focus eq "find.r"} { replace_one; return }
	step [expr {$shift ? -1 : 1}]
}

# The find text changed: the replace count starts again, and the first match at or after the caret is current.
proc find::changed {} {
	variable replaced
	set replaced 0
	forget
	compute
	nearest
	goto
	editor::schedule
}

# The options changed: the matches are found again, the current one kept.
proc find::refresh {} {
	compute
	editor::schedule
}

proc find::step {d} {
	variable matches
	variable cur
	compute
	set n [llength $matches]
	if {!$n} { editor::schedule; return }
	set cur [expr {($cur + $d + $n) % $n}]
	goto
	editor::schedule
}

proc find::set_mode {m args} {
	variable mode
	set mode $m
	if {$m eq "find" && $::ui::focus eq "find.r"} { set ::ui::focus find.q }
	if {$m eq "replace" && $::ui::focus eq ""} { set ::ui::focus find.r }
	editor::schedule
}

# ---- replacing: each change is one undo step (autoseparators off over the group, so one Undo reverts it) ----

# Replace the text of [s, e) with REP in T, tagged as replaced.
proc find::swap {t s e rep} {
	$t delete "1.0 +${s}c" "1.0 +${e}c"
	$t insert "1.0 +${s}c" $rep [list find_done]
}

# The replacement for the match at [S, E) of TEXT. In Regular expression mode REP is a regsub template: & and \0 are the
# match, \1 to \9 its groups, \& and \\ a literal & and \. Otherwise REP is literal.
proc find::expand {text s e rep} {
	variable opts
	if {!$opts(regex) || ([string first \\ $rep] < 0 && [string first & $rep] < 0)} { return $rep }
	set flags {}
	if {!$opts(case)} { set flags -nocase }
	set pat [pattern [ui::fval find.q]]
	# the same match, from its start: its groups' offsets
	if {[catch {regexp -inline -indices -start $s {*}$flags -- $pat $text} idx] || ![llength $idx]} { return $rep }
	set out ""
	set n [string length $rep]
	for {set i 0} {$i < $n} {incr i} {
		set ch [string index $rep $i]
		if {$ch eq "&"} {
			append out [string range $text $s [expr {$e - 1}]]
		} elseif {$ch eq "\\" && $i + 1 < $n} {
			set nx [string index $rep [incr i]]
			if {[string is digit $nx]} {
				lassign [lindex $idx $nx] gs ge
				if {$gs ne "" && $gs >= 0} { append out [string range $text $gs $ge] }
			} else {
				append out $nx
			}
		} else {
			append out $ch
		}
	}
	return $out
}

proc find::group {script} {
	set t [editor::tw $::editor::active]
	$t edit separator
	$t configure -autoseparators 0
	catch {uplevel 1 $script}
	$t configure -autoseparators 1
	$t edit separator
}

# ---- the count through Undo and Redo: a Replace undone (Ctrl+Z, the Undo button) takes its count off "N replaced", one
# redone puts it back. Each Replace keeps its count and a sum of the text before and after it; an undo whose text is
# the "after" of the last Replace is that Replace's undo. ----

proc find::sum {t} {
	set text [$t get 1.0 end-1c]
	list [string length $text] [zlib crc32 [encoding convertto utf-8 $text]]
}

proc find::forget {} {
	variable hist
	variable redo
	array unset hist
	array unset redo
}

proc find::did_replace {id n before after} {
	variable hist
	variable redo
	lappend hist($id) [list $n $before $after]
	set redo($id) {}
}

# <<Undo>> or <<Redo>> on text T, before the text class acts on it (WHAT: undo | redo). When the text is the last
# Replace's "after" (undo) or the last undone one's "before" (redo), the step is taken here and the count moves only
# when the text comes out as that Replace's other side (the step Tk took may be a typed edit's instead). Returns 1 when
# the step was taken here (the binding then stops the class), 0 when the class is to take it.
proc find::undo_hook {t what} {
	variable hist
	variable redo
	variable replaced
	set id $::editor::active
	if {$id eq ""} { return 0 }
	if {$what eq "undo"} {
		if {![info exists hist($id)] || ![llength $hist($id)]} { return 0 }
		lassign [lindex $hist($id) end] n before after
		if {[sum $t] ne $after} { return 0 }
		# as the text class does: separators around the step, so it does not merge with what follows
		if {[$t cget -autoseparators]} { $t edit separator }
		catch {$t edit undo}
		if {[$t cget -autoseparators]} { $t edit separator }
		if {[sum $t] eq $before} {
			set hist($id) [lrange $hist($id) 0 end-1]
			lappend redo($id) [list $n $before $after]
			set replaced [expr {max(0, $replaced - $n)}]
		}
	} else {
		if {![info exists redo($id)] || ![llength $redo($id)]} { return 0 }
		lassign [lindex $redo($id) end] n before after
		if {[sum $t] ne $before} { return 0 }
		catch {$t edit redo}
		if {[sum $t] eq $after} {
			set redo($id) [lrange $redo($id) 0 end-1]
			lappend hist($id) [list $n $before $after]
			incr replaced $n
		}
	}
	after idle find::after_undo
	return 1
}

proc find::after_undo {} {
	if {!$::find::open} return
	compute
	editor::schedule
}

# Replace changes the current match, then moves on (past the replacement).
proc find::replace_one {args} {
	variable matches
	variable replaced
	variable cur
	if {$::editor::active eq ""} return
	compute
	if {![llength $matches]} { editor::schedule; return }
	set rep [ui::fval find.r]
	lassign [lindex $matches $cur] s e
	set t [editor::tw $::editor::active]
	set text [$t get 1.0 end-1c]
	set rep [expand $text $s $e $rep]
	set before [sum $t]
	group [list find::swap $t $s $e $rep]
	did_replace $::editor::active 1 $before [sum $t]
	incr replaced
	set after [expr {$s + [string length $rep]}]
	compute
	set cur 0
	set i 0
	foreach m $matches {
		if {[lindex $m 0] >= $after} { set cur $i; break }
		incr i
	}
	goto
	editor::schedule
}

# Replace all changes every match, the last first so the earlier offsets hold.
proc find::replace_all {args} {
	variable matches
	variable replaced
	variable cur
	if {$::editor::active eq ""} return
	compute
	if {![llength $matches]} { editor::schedule; return }
	set rep [ui::fval find.r]
	set t [editor::tw $::editor::active]
	set n [llength $matches]
	set text [$t get 1.0 end-1c]
	set reps {}
	foreach m $matches { lassign $m s e; lappend reps [expand $text $s $e $rep] }
	set before [sum $t]
	group [list apply {{t ms reps} {
		foreach m [lreverse $ms] r [lreverse $reps] { lassign $m s e; find::swap $t $s $e $r }
	}} $t $matches $reps]
	did_replace $::editor::active $n $before [sum $t]
	incr replaced $n
	compute
	set cur 0
	editor::schedule
}

# Undo reverts the last Replace or Replace all (one step, see find::group); its count comes off "N replaced".
proc find::undo {args} {
	if {$::editor::active eq ""} return
	set t [editor::tw $::editor::active]
	if {![undo_hook $t undo]} { catch {$t edit undo} }
	$t tag remove find_done 1.0 end
	compute
	editor::schedule
}

# ---- the bar ----

# A label in the chrome's font, cut to MAXW with an ellipsis.
proc find::fit {str f maxw} {
	if {[ui::measure $f $str] <= $maxw} { return $str }
	while {[string length $str] > 1 && [ui::measure $f "$str…"] > $maxw} {
		set str [string range $str 0 end-1]
	}
	return "$str…"
}

# What the dropdown names: the options that are on, or "Options" when none is.
proc find::dropdown_label {} {
	variable opts
	set on {}
	if {$opts(case)} { lappend on "Match case" }
	if {$opts(word)} { lappend on "Whole word" }
	if {$opts(regex)} { lappend on "Regex" }
	if {![llength $on]} { return "Options" }
	return [join $on ", "]
}

# A field button of 32: kind field (a §field fill) or ghost (a ring on the bar). Returns its width.
proc find::button {x y label kind script {icon ""}} {
	set c $::editor::c(field)
	set tw [ui::measure i13m $label]
	set w [expr {24 + $tw + ($icon ne "" ? 21 : 0)}]
	if {$kind eq "field"} {
		ui::box $x $y $w 32 -fill $::editor::c(field) -radius 8 -ring [list $::editor::c(border) 1]
	} else {
		ui::box $x $y $w 32 -fill $::editor::c(bar) -radius 8 -ring [list $::editor::c(border) 1]
	}
	ui::text [expr {$x + 12}] [ui::lh $y i13m 32] $label i13m $::editor::c(fg)
	if {$icon ne ""} { editor::icon $icon 14 $::editor::c(fg) [expr {$x + 12 + $tw + 7}] [expr {$y + 9}] 2 }
	ui::hit $x $y $w 32 $script
	return $w
}

# A 30 by 32 icon button (the chevrons, the close ×): a hit area and a 15 px icon, centred.
proc find::icon_button {x y name colour script} {
	editor::icon $name 15 $colour [expr {$x + 7.5}] [expr {$y + 8.5}] 2
	ui::hit $x $y 30 32 $script
}

# The Find | Replace segmented control: the part widths and the width of the whole.
proc find::seg_parts {} {
	set ws {}
	foreach l {Find Replace} { lappend ws [expr {[ui::measure i13m $l] + 24}] }
	return $ws
}

# The Find | Replace segmented control at X, Y: a §field track, the chosen part raised in §pill (600 §fg), the other
# muted. Returns its width.
proc find::segment {x y} {
	variable mode
	set parts {find Find replace Replace}
	set ws [seg_parts]
	set w [expr {6 + [lindex $ws 0] + 2 + [lindex $ws 1]}]
	ui::box $x $y $w 32 -fill $::editor::c(field) -radius 9 -ring [list $::editor::c(border) 1]
	set px [expr {$x + 3}]
	foreach {k l} $parts pw $ws {
		set on [expr {$k eq $mode}]
		if {$on} { ui::box $px [expr {$y + 3}] $pw 26 -fill $::editor::c(pill) -radius 6 }
		set f [expr {$on ? "i13s" : "i13m"}]
		ui::text [expr {$px + $pw / 2.0}] [ui::lh [expr {$y + 3}] $f 26] $l $f [expr {$on ? $::editor::c(fg) : $::editor::c(muted)}] c
		ui::hit $px [expr {$y + 3}] $pw 26 [list find::set_mode $k]
		set px [expr {$px + $pw + 2}]
	}
	return $w
}

# The count at the field's right end: "4 of 6" with the 4 in §fg 600; "No match" when there is none or the pattern does
# not compile.
proc find::count_text {right top} {
	variable matches
	variable cur
	variable err
	if {[ui::fval find.q] eq ""} return
	if {$err || ![llength $matches]} {
		ui::text $right $top "No match" i12 $::editor::c(muted) e
		return
	}
	set tw [ui::text $right $top " of [llength $matches]" i12 $::editor::c(muted) e]
	ui::text [expr {$right - $tw}] $top [expr {$cur + 1}] i12s $::editor::c(fg) e
}

# The dropdown opens or closes its options menu (a card of three options, 34 high each).
proc find::toggle_menu {args} {
	variable menu
	set menu [expr {!$menu}]
	# the dropdown takes the focus from the field it is under
	if {$menu} { set ::ui::focus "" } else { hide_menu }
	editor::schedule
}

proc find::close_menu {} {
	variable menu
	set menu 0
	hide_menu
	editor::schedule
}

proc find::toggle_opt {k args} {
	variable opts
	set opts($k) [expr {!$opts($k)}]
	save_opts
	refresh
}

# The menu's canvas, drawn in its own photo; ui::text and ui::icon are pointed at it while it is drawn.
proc find::menu_draw {} {
	variable mcanvas
	variable menuimg
	variable opts
	set c $::editor::c(field)
	if {![winfo exists $mcanvas]} {
		canvas $mcanvas -width 210 -height 114 -highlightthickness 0 -borderwidth 0 -takefocus 0 \
			-background $::editor::c(bar)
		bind $mcanvas <ButtonPress-1> {find::menu_click %x %y}
	}
	$mcanvas delete all
	if {$menuimg ne ""} { catch {image delete $menuimg} }
	set menuimg [image create photo -width 210 -height 114]
	raster::box $menuimg 0 0 210 114 -fill $c -radius 10 -ring [list $::editor::c(border) 1]
	$mcanvas create image 0 0 -image $menuimg -anchor nw
	set saved $::ui::cv
	set ::ui::cv $mcanvas
	set row 0
	foreach {k l} {case "Match case" word "Whole word" regex "Regular expression"} {
		set top [expr {6 + 34 * $row}]
		set on $opts($k)
		set f [expr {$on ? "i13s" : "i13m"}]
		ui::text 16 [ui::lh $top $f 34] $l $f $::editor::c(fg)
		if {$on} { ui::icon check 14 $::editor::c(accent) 180 [expr {$top + 10}] 2.4 }
		incr row
	}
	set ::ui::cv $saved
}

# A press on the menu: the option of the row, toggled (the menu stays open).
proc find::menu_click {x y} {
	set i [expr {($y - 6) / 34}]
	if {$y < 6 || $i > 2} return
	toggle_opt [lindex {case word regex} $i]
}

proc find::raise_menu {} {
	variable menu
	variable mcanvas
	variable open
	variable MENUX
	variable MENUY
	if {$open && $menu && ![editor::overlay]} {
		menu_draw
		place $mcanvas -x $MENUX -y $MENUY
		raise $mcanvas
	} else {
		hide_menu
	}
}

proc find::hide_menu {} {
	variable mcanvas
	if {[winfo exists $mcanvas]} { place forget $mcanvas }
}

# Draws the bar (between the tabs and the status line), its matches' tags, and the menu when it is open.
proc find::paint {} {
	variable open
	variable mode
	variable matches
	variable replaced
	variable menu
	variable X
	variable FW
	variable R1
	variable R2
	variable DDW
	if {!$open} return
	compute
	mark
	set bottom [expr {46 + [height] - 1}]
	ui::hline 0 $::editor::W $bottom $::editor::c(border)
	set right [expr {$::editor::W - 10}]
	set close [expr {$right - 30}]

	# the find row
	set fx [expr {$X + $FW - 12}]
	ui::field find.q $X $R1 $FW -h 32 -radius 8 -pad 34 -font mono13 -max 256 -onchange find::changed
	editor::icon search 14 $::editor::c(muted) [expr {$X + 12}] [expr {$R1 + 9}] 1.9
	count_text $fx [ui::lh $R1 i12 32]
	set x1 [expr {$X + $FW + 10}]
	icon_button $x1 $R1 chevup $::editor::c(fg) find::step_up
	icon_button [expr {$x1 + 40}] $R1 chev $::editor::c(fg) find::step_down
	set dx [expr {$x1 + 80}]
	ui::box $dx $R1 $DDW 32 -fill $::editor::c(field) -radius 8
	if {$menu} {
		ui::ring $dx $R1 $DDW 32 8 $::editor::c(accent) 1.5
	} else {
		ui::ring $dx $R1 $DDW 32 8 $::editor::c(border) 1
	}
	ui::text [expr {$dx + 12}] [ui::lh $R1 i13m 32] [fit [dropdown_label] i13m [expr {$DDW - 12 - 10 - 14 - 8}]] i13m $::editor::c(fg)
	editor::icon chev 14 [expr {$menu ? $::editor::c(fg) : $::editor::c(muted)}] [expr {$dx + $DDW - 24}] [expr {$R1 + 9}] 2
	ui::hit $dx $R1 $DDW 32 find::toggle_menu
	set sw [expr {6 + [lindex [seg_parts] 0] + 2 + [lindex [seg_parts] 1]}]
	segment [expr {$close - 10 - $sw}] $R1
	icon_button $close $R1 x $::editor::c(fg) find::close_bar

	if {$mode eq "replace"} {
		ui::field find.r $X $R2 $FW -h 32 -radius 8 -pad 34 -font mono13 -max 256
		editor::icon replace 14 $::editor::c(muted) [expr {$X + 12}] [expr {$R2 + 9}] 1.9
		set bx [expr {$X + $FW + 10}]
		set w [button $bx $R2 "Replace" field find::replace_one]
		set bx [expr {$bx + $w + 10}]
		set n [llength $matches]
		button $bx $R2 "Replace all $n" field find::replace_all
		if {$replaced > 0} {
			set uw [expr {24 + [ui::measure i13m Undo] + 21}]
			set ux [expr {$right - $uw}]
			button $ux $R2 "Undo" ghost find::undo undo
			ui::text [expr {$ux - 12}] [ui::lh $R2 i12 32] "$replaced replaced" i12 $::editor::c(muted) e
		}
	}
}

proc find::step_up {args} { step -1 }
proc find::step_down {args} { step 1 }

# ---- the entry points (the chrome, Ctrl+F, Ctrl+H, the search icon) ----

proc editor::find_install {} { find::load }
proc editor::find_open {x y} { find::show_bar find }
proc editor::replace_open {} { find::show_bar replace }

namespace eval page {}
# ui::field_click and ui::cycle ask for a redraw.
proc page::draw {} { editor::schedule }
