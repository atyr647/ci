# diagnostics.tcl - Text editor (U32): nagelfar's findings on the Well (Editor-Final-7-Diagnostics).
#   badge    at x 9, 44 x 18 on each line with a finding. An error is a filled tag with an ink number; a warning is an
#            outline in WARN. The error whose card is up is outlined too.
#   wave     a 1 px wavy underline in ERR or WARN under the phrase the message names, or, when it names none, under the
#            line's text from its first non-blank character. Tk text has no wavy style, so it is a 4 px canvas over the
#            text (the text's background, the wave in the colour). Clicks on it reach the text.
#   card     the hover card under the line: the message (the phrase in mono) and "nagelfar".
#   status   "1 error" and "1 warning" before the path, the counts that are not zero.
# nagelfar is a Tcl checker: it runs only for a Tcl document, on a temporary copy of the text once the text has been
# still for 700 ms, in the background (a pipe read as it comes, so the window never waits on it), when it is on PATH;
# when it is not, nothing shows. Its lines are "Line N: E|W|N message"; the notes (N) are not shown. nagelfar gives no columns, so
# the range is the phrase the message names (the quoted text, else the words after " to "), where it occurs on the line.
# Hooks: gutter::draw calls diag::schedule and diag::marks; well::status calls diag::status.

namespace eval diag {
	variable res              ;# array: ID -> {{line sev msg phrase} ...} from the last run
	variable want             ;# array: ID -> the text the last or pending run is for
	variable timer            ;# array: ID -> the pending run's after id
	variable chan             ;# array: ID -> {channel tempfile text output} of the run in progress
	variable delay 700        ;# ms of no change before a run
	variable hits {}          ;# the badges of the last paint: {x0 y0 x1 y1 id line row_y row_h}
	variable cardline 0       ;# the line whose card is up (0: none)
	variable cardpage ""      ;# the page the card is in
	variable bound            ;# array: gutter canvas -> 1 once its hover is bound
	variable paths            ;# icons on a 24 grid, as main.tcl's
	array set paths {
		err  {M12 22a10 10 0 1 0 0-20a10 10 0 1 0 0 20z M15 9l-6 6 M9 9l6 6}
		warn {M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z M12 9v4 M12 17h.01}
	}
}

# nagelfar's path on PATH, or "" (read at each call: a test may change PATH).
proc diag::tool {} {
	foreach d [split $::env(PATH) :] {
		set f [file join $d nagelfar]
		if {[file isfile $f] && [file executable $f]} { return $f }
	}
	return ""
}

# The phrase a message names: the quoted text, else the words after " to " ("Wrong number of arguments to string range").
proc diag::phrase {msg} {
	if {[regexp {"([^"]+)"} $msg -> q]} { return $q }
	if {[regexp { to ([^"]+)$} $msg -> p]} { return $p }
	return ""
}

# The findings in nagelfar's output OUT: {line sev msg phrase} for each error (E) and warning (W) line.
proc diag::parse {out} {
	set found {}
	foreach l [split $out \n] {
		if {![regexp {^\s*Line\s+(\d+):\s+([EW])\s+(.*\S)\s*$} $l -> n sev msg]} continue
		lappend found [list $n $sev $msg [phrase $msg]]
	}
	return $found
}

# Schedule a run of nagelfar on document ID after its text has been still for a while. Called on every paint: a text
# that is the one the last run or the pending run is for schedules nothing.
proc diag::schedule {id} {
	variable want
	variable timer
	variable delay
	if {$id eq "" || ![info exists ::doc::D($id,w)]} return
	if {[::doc::lang $id] ne "Tcl"} { catch {unset ::diag::res($id)}; return }
	set cur [[editor::tw $id] get 1.0 end-1c]
	if {[info exists want($id)] && $want($id) eq $cur} return
	set want($id) $cur
	catch {after cancel $timer($id)}
	set timer($id) [after $delay [list diag::run $id]]
}

# Start nagelfar on document ID's text, from a temporary file, in the background: its output is read as it comes
# (diag::readable) and the findings are kept when it ends. A run still going for an older text is dropped.
proc diag::run {id} {
	variable res
	variable timer
	variable chan
	catch {unset timer($id)}
	if {![info exists ::doc::D($id,w)]} return
	stop $id
	set exe [tool]
	if {$exe eq "" || [::doc::lang $id] ne "Tcl"} {
		catch {unset res($id)}
		return
	}
	set cur [[editor::tw $id] get 1.0 end-1c]
	set fh [file tempfile name]
	fconfigure $fh -encoding utf-8
	puts -nonewline $fh $cur
	close $fh
	if {[catch {open |[list $exe $name 2>/dev/null] r} ch]} {
		catch {file delete $name}
		return
	}
	fconfigure $ch -blocking 0 -encoding utf-8
	set chan($id) [list $ch $name $cur ""]
	fileevent $ch readable [list diag::readable $id $ch]
}

# nagelfar's output for document ID on channel CH: kept until the end, then parsed into the findings.
proc diag::readable {id ch} {
	variable chan
	variable res
	if {![info exists chan($id)] || [lindex $chan($id) 0] ne $ch} { catch {close $ch}; return }
	set data [read $ch]
	lset chan($id) 3 "[lindex $chan($id) 3]$data"
	if {![eof $ch]} return
	lassign $chan($id) ch name cur out
	unset chan($id)
	catch {close $ch}
	catch {file delete $name}
	if {![info exists ::doc::D($id,w)]} return
	set res($id) [parse $out]
	editor::schedule
}

# Drop document ID's run in progress, if any.
proc diag::stop {id} {
	variable chan
	if {![info exists chan($id)]} return
	lassign $chan($id) ch name
	unset chan($id)
	catch {fileevent $ch readable {}}
	catch {close $ch}
	catch {file delete $name}
}

# The finding each line shows: its first error, else its first warning, as {sev msg phrase}, keyed by line.
proc diag::by_line {id} {
	variable res
	set out [dict create]
	if {![info exists res($id)]} { return $out }
	foreach sev {E W} {
		foreach f $res($id) {
			lassign $f n s msg phrase
			if {$s eq $sev && ![dict exists $out $n]} { dict set out $n [list $sev $msg $phrase] }
		}
	}
	return $out
}

# The number of errors and of warnings of document ID: {errors warnings}.
proc diag::counts {id} {
	variable res
	set e 0
	set w 0
	if {[info exists res($id)]} {
		foreach f $res($id) {
			switch -- [lindex $f 1] {
				E { incr e }
				W { incr w }
			}
		}
	}
	return [list $e $w]
}

proc diag::count_text {n sev} {
	if {$sev eq "E"} { return "$n [expr {$n == 1 ? "error" : "errors"}]" }
	return "$n [expr {$n == 1 ? "warning" : "warnings"}]"
}

# The badges of the visible lines ROWS ({line y height}) and the waves under their phrases, on gutter canvas G.
proc diag::marks {g id rows} {
	variable hits
	variable bound
	variable cardline
	if {![info exists bound($g)]} {
		bind $g <Motion> [list diag::hover $g %x %y]
		bind $g <Leave> [list diag::hover $g -1 -1]
		set bound($g) 1
	}
	set bad [by_line $id]
	set bg [well::background]
	set err $::theme::c(ERR)
	set warn $::theme::c(WARN)
	set hits {}
	foreach row $rows {
		lassign $row n y h
		if {![dict exists $bad $n]} continue
		lassign [dict get $bad $n] sev msg phrase
		set y0 [expr {$y + 2}]
		set y1 [expr {$y0 + 18}]
		lappend hits [list 9 $y0 59 $y1 $id $n $y $h]
		if {$sev eq "E" && $n != $cardline} {
			# the arrow tag, 50 x 18 as the board's svg
			set pts {}
			foreach {px py} {4 0 41.5 0 43.8 1.1 49.2 8.9 43.8 16.9 41.5 18 4 18 0 14 0 4} {
				lappend pts [expr {9 + $px}] [expr {$y0 + $py}]
			}
			$g create polygon {*}$pts -fill $err -outline "" -smooth 1 -tags diag
			set col $::editor::c(on_accent)
		} else {
			# an outline over the gutter's colour: it hides the line number the paint drew under it
			set col [expr {$sev eq "E" ? $err : $warn}]
			$g create polygon {*}[rounded 9.5 [expr {$y0 + 0.5}] 52.5 [expr {$y1 - 0.5}] 5] -fill $bg -outline $col -width 1 -smooth 1 -tags diag
		}
		text::draw $g 48 [expr {$y + 2}] ui_i12s $col $n ne -tags diag
	}
	waves $id
}

# The corner points of a rounded box, for a smooth polygon (each corner is a point the curve passes near).
proc diag::rounded {x0 y0 x1 y1 r} {
	return [list [expr {$x0 + $r}] $y0 [expr {$x1 - $r}] $y0 $x1 $y0 $x1 [expr {$y0 + $r}] \
		$x1 [expr {$y1 - $r}] $x1 $y1 [expr {$x1 - $r}] $y1 [expr {$x0 + $r}] $y1 $x0 $y1 \
		$x0 [expr {$y1 - $r}] $x0 [expr {$y0 + $r}] $x0 $y0]
}

# The waves under the phrases of document ID's findings: a 4 px canvas over the text, its top 1 px above the baseline
# shows the wave. Destroyed and made again at each paint.
proc diag::waves {id} {
	variable res
	set t [editor::tw $id]
	set page [winfo parent $t]
	foreach w [winfo children $page] {
		if {[string match $page.diagwave* $w]} { destroy $w }
	}
	if {![info exists res($id)]} return
	set bg [$t cget -background]
	set k 0
	foreach f $res($id) {
		lassign $f n sev msg phrase
		if {$phrase eq ""} {
			# no phrase: the line's text without its leading and trailing blanks
			set line [$t get $n.0 $n.end]
			set lead [expr {[string length $line] - [string length [string trimleft $line]]}]
			set body [string trim $line]
			if {$body eq ""} continue
			set s [$t index "$n.0 + $lead chars"]
			set e [$t index "$s + [string length $body] chars"]
		} else {
			set s [$t search -exact -- $phrase $n.0 $n.end]
			if {$s eq ""} continue
			set e [$t index "$s + [string length $phrase] chars"]
		}
		set b1 [$t bbox $s]
		set b2 [$t bbox "$e - 1 chars"]
		if {$b1 eq "" || $b2 eq ""} continue
		set x0 [lindex $b1 0]
		set x1 [expr {[lindex $b2 0] + [lindex $b2 2]}]
		set y [expr {[lindex $b1 1] + [lindex $b1 3] - 3}]
		set w [expr {$x1 - $x0}]
		if {$w < 2} continue
		set c $page.diagwave[incr k]
		canvas $c -width $w -height 4 -highlightthickness 0 -borderwidth 0 -background $bg -takefocus 0
		set pts {}
		for {set i 0} {$i <= $w} {incr i} {
			lappend pts $i [expr {1.5 + 1.2 * sin(3.14159265 * $i / 2.0)}]
		}
		$c create line {*}$pts -fill [expr {$sev eq "E" ? $::theme::c(ERR) : $::theme::c(WARN)}] -width 1
		place $c -x [expr {$x0 + [winfo x $t]}] -y [expr {$y + [winfo y $t]}]
		bind $c <ButtonPress-1> [list diag::through $t $c %x %y ButtonPress-1]
		bind $c <B1-Motion> [list diag::through $t $c %x %y B1-Motion]
		bind $c <ButtonRelease-1> [list diag::through $t $c %x %y ButtonRelease-1]
		raise $c
	}
}

# A press, drag or release on a wave goes to the text under it.
proc diag::through {t c x y ev} {
	set tx [expr {$x + [winfo x $c] - [winfo x $t]}]
	set ty [expr {$y + [winfo y $c] - [winfo y $t]}]
	event generate $t <$ev> -x $tx -y $ty
}

# The hover of gutter canvas G at X Y: the card of the badge under the pointer, or none.
proc diag::hover {g x y} {
	variable hits
	variable cardline
	set hit ""
	foreach h $hits {
		lassign $h x0 y0 x1 y1
		if {$x >= $x0 && $x < $x1 && $y >= $y0 && $y < $y1} { set hit $h }
	}
	if {$hit eq ""} {
		card_hide
		return
	}
	lassign $hit x0 y0 x1 y1 id n ry rh
	if {$n != $cardline} { card_show $id $n $ry $rh }
}

# The card of line N of document ID, under the line at Y (height H) in the page.
proc diag::card_show {id n y h} {
	variable cardline
	variable cardpage
	variable paths
	card_hide
	set t [editor::tw $id]
	set page [winfo parent $t]
	lassign [dict get [by_line $id] $n] sev msg phrase
	set c $::editor::c(field)
	set f $page.diagcard
	frame $f -background $c -highlightthickness 1 -highlightbackground $::editor::c(border) \
		-highlightcolor $::editor::c(border) -borderwidth 0 -takefocus 0
	label $f.icon -image [raster::icon $paths(err) 14 2.1 [ui::col $::theme::c(ERR)] {} 0 0 0] \
		-background $c -borderwidth 0 -highlightthickness 0
	pack $f.icon -side left -padx {10 9} -pady 9
	set k [expr {$phrase ne "" ? [string first $phrase $msg] : -1}]
	if {$k >= 0} {
		set pre [string range $msg 0 [expr {$k - 1}]]
		set post [string range $msg [expr {$k + [string length $phrase]}] end]
	} else {
		set pre $msg
		set phrase ""
		set post ""
	}
	set code ribbon-diag-code
	if {$code ni [font names]} { font create $code -family $::editor::mono -size -12 }
	label $f.pre -text $pre -font ui_i13 -foreground $::editor::c(fg) -background $c -borderwidth 0 -highlightthickness 0
	label $f.code -text $phrase -font $code -foreground $::editor::c(fg) -background $c -borderwidth 0 -highlightthickness 0
	label $f.post -text $post -font ui_i13 -foreground $::editor::c(fg) -background $c -borderwidth 0 -highlightthickness 0
	label $f.src -text nagelfar -font ui_i12 -foreground $::editor::c(muted) -background $c -borderwidth 0 -highlightthickness 0
	pack $f.pre $f.code $f.post -side left
	pack $f.src -side left -padx {4 12}
	place $f -x 18 -y [expr {$y + $h + 7}]
	raise $f
	set cardpage $page
	set cardline $n
	editor::schedule
}

# Take the card down (and the badge's outline with it).
proc diag::card_hide {} {
	variable cardline
	variable cardpage
	if {$cardline == 0} return
	catch {destroy $cardpage.diagcard}
	set cardline 0
	editor::schedule
}

# The status line's counts, drawn right to left ending at XR, on the text row TOP. Returns the {sev text} drawn.
proc diag::status {id xr top} {
	variable paths
	lassign [counts $id] e w
	set items {}
	if {$e > 0} { lappend items [list E [count_text $e E]] }
	if {$w > 0} { lappend items [list W [count_text $w W]] }
	if {![llength $items]} { return {} }
	set total 0
	foreach it $items {
		lassign $it sev s
		set total [expr {$total + 13 + 6 + [ui::measure i12 $s]}]
	}
	set total [expr {$total + 20 * ([llength $items] - 1)}]
	set x [expr {$xr - $total}]
	set drawn {}
	foreach it $items {
		lassign $it sev s
		set col [expr {$sev eq "E" ? $::theme::c(ERR) : $::theme::c(WARN)}]
		set icon [raster::icon [expr {$sev eq "E" ? $paths(err) : $paths(warn)}] 13 2.1 [ui::col $col] {} 0 0 0]
		$::ui::cv create image [expr {round($x)}] [expr {round($top)}] -image $icon -anchor nw -tags page
		ui::text [expr {$x + 13 + 6}] $top $s i12 $::editor::c(muted)
		set x [expr {$x + 13 + 6 + [ui::measure i12 $s] + 20}]
		lappend drawn [list $sev $s]
	}
	return $drawn
}
