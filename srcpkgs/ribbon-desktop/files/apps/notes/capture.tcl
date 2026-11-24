# capture.tcl - Notes quick capture (U35), drawn as Notes-R4-A5-Capture: a 520 x 448 panel that saves to a folder
# (Inbox by default). Its parts: the folder pill (a menu of the folders), the pin, the title, the checklist body,
# an attachment card (a picture kept next to the note), the tags row, and Discard / Save.
#
#   ribbon-notes --capture   hands off to a running Notes over its socket (cap_listen in main.tcl); when none is
#                            running it opens the panel itself and exits after Save or Discard.
#
# The panel draws with plain canvas items (not the ui library, which is one canvas per window). Its procs are
# named cap_* so they never shadow a Tcl command.

namespace eval ::notesapp {
	variable cap
	array set cap {win "" cv "" title "" body "" pinned 0 standalone 0 folder Inbox tags {} attach "" thumb ""
		tagentry "" tagx 0 tagy 0}
	variable capw 520
	variable caph 448
	# the panel's own icons (the tree's paths hold search, x, down, pin and the rest)
	variable capicons
	array set capicons {
		inbox {M22 12h-6l-2 3h-4l-2-3H2 M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z}
		checkbox {M3 3h18v18H3z M7 12l3 3 7-7}
		list {M9 6h11M9 12h11M9 18h11M4 6h.01M4 12h.01M4 18h.01}
		image {M3 3h18v18H3z M8.5 10a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3 M21 15l-5-5L5 21}
		link {M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71 M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71}
		check {M20 6L9 17l-5-5}
		plus {M12 5v14 M5 12h14}
	}
	# the panel's fonts: the button and pill label, and the tag chips
	# (sizes are pixels: a negative size)
	variable capfont {{Ribbon Inter 500} -13}
	variable captagfont {{Ribbon Inter 500} -12}
	variable capbtnfont {{Ribbon Inter 600} -14}     ;# Save (the primary button): 14 px, 600
	variable capbtnfont0 {{Ribbon Inter 400} -14}    ;# Discard (the ghost button): 14 px, 400
}

# The socket the running Notes listens on: $XDG_RUNTIME_DIR/ribbon-notes.sock, else under the cache.
proc ::notesapp::cap_sock {} {
	if {[info exists ::env(XDG_RUNTIME_DIR)] && $::env(XDG_RUNTIME_DIR) ne ""} {
		return [file join $::env(XDG_RUNTIME_DIR) ribbon-notes.sock]
	}
	set base [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$::env(HOME)/.cache"}]
	return [file join $base ribbon ribbon-notes.sock]
}

# A running Notes answers the socket: send it "capture" and report that it took the request.
proc ::notesapp::cap_handoff {} {
	if {[catch {package require unix_sockets}]} { return 0 }
	if {[catch {unix_sockets::connect [cap_sock]} ch]} { return 0 }
	fconfigure $ch -translation lf -encoding utf-8
	puts $ch "capture"
	flush $ch
	close $ch
	return 1
}

# The running app listens. A live socket means another Notes is running, so this one does not listen.
proc ::notesapp::cap_listen {} {
	if {[catch {package require unix_sockets}]} return
	set path [cap_sock]
	if {![catch {unix_sockets::connect $path} ch]} { close $ch; return }
	catch {file delete -force $path}
	file mkdir [file dirname $path]
	if {[catch {unix_sockets::listen $path ::notesapp::cap_accept} err]} {
		puts stderr "ribbon-notes: no capture socket: $err"
	}
}

proc ::notesapp::cap_accept {ch args} {
	fconfigure $ch -blocking 0 -buffering line -translation lf -encoding utf-8
	chan event $ch readable [list ::notesapp::cap_read $ch]
}

proc ::notesapp::cap_read {ch} {
	if {[catch {gets $ch line} n] || [chan eof $ch]} {
		catch {close $ch}
		return
	}
	if {$n < 0} return
	catch {close $ch}
	if {[string trim $line] eq "capture"} {
		after idle ::notesapp::cap_open
	}
}

# The panel: a new one, or the open one raised.
proc ::notesapp::cap_open {{standalone 0}} {
	variable cap
	variable capw
	variable caph
	if {[winfo exists $cap(win)]} {
		wm deiconify $cap(win)
		raise $cap(win)
		focus $cap(title)
		return
	}
	text::font nbody {Ribbon Inter 400} 15
	set cap(standalone) $standalone
	set cap(pinned) 0
	set cap(folder) Inbox
	set cap(tags) {}
	set cap(tagentry) ""
	cap_attach_clear
	set w .cap
	set cap(win) $w
	toplevel $w -class RibbonNotesCapture -borderwidth 0 -highlightthickness 0 -background $::notesapp::c(bar)
	if {[catch {rbn::appwindow $w RibbonNotesCapture $capw $caph -fill $::notesapp::c(bar)}]} {
		wm geometry $w ${capw}x${caph}
	}
	if {[winfo screenwidth .] > 0} {
		wm geometry $w ${capw}x${caph}+[expr {max(0, ([winfo screenwidth .] - $capw) / 2)}]+132
	}
	wm title $w "Quick note"
	wm resizable $w 0 0
	wm protocol $w WM_DELETE_WINDOW ::notesapp::cap_close
	set cap(cv) $w.c
	canvas $cap(cv) -width $capw -height $caph -highlightthickness 0 -borderwidth 0 -background $::notesapp::c(bar)
	place $cap(cv) -x 0 -y 0
	text::font capTitle {Ribbon Space Grotesk 600} 24
	entry $w.t -font capTitle -relief flat -borderwidth 0 -highlightthickness 0 -background $::notesapp::c(bar) \
		-foreground $::notesapp::c(fg) -insertbackground $::notesapp::c(accent) -selectbackground $::notesapp::c(sel)
	place $w.t -x 26 -y 75 -width 468 -height 38
	set cap(title) $w.t
	text $w.b -wrap word -undo 0 -borderwidth 0 -highlightthickness 0 -padx 0 -pady 0 -spacing1 0 -spacing2 3 -spacing3 0 \
		-background $::notesapp::c(bar) -foreground $::notesapp::c(fg) -insertbackground $::notesapp::c(accent) \
		-selectbackground $::notesapp::c(sel) -selectforeground $::notesapp::c(fg) -exportselection 0 \
		-font nbody -cursor xterm
	place $w.b -x 26 -y 119 -width 468 -height 140
	set cap(body) $w.b
	$w.b tag configure elide -elide 1
	$w.b tag configure done -foreground [ui::col $::notesapp::c(muted)] -overstrike 1
	bind $w.b <KeyRelease> ::notesapp::cap_restyle
	bind $w.b <ButtonRelease-1> {::notesapp::cap_click %x %y}
	bind $w <Escape> ::notesapp::cap_close
	bind $w <Control-s> ::notesapp::cap_save
	bind $w.t <Return> {focus $::notesapp::cap(body); break}
	bind $w.b <Control-Return> ::notesapp::cap_save
	cap_draw
	focus $w.t
}

# The chrome: header, divider, body card and tags, footer buttons. Drawn again after each change; the body
# text, the title and an open tag entry are widgets and stay put.
proc ::notesapp::cap_draw {} {
	variable cap
	variable c
	variable paths
	variable capw
	variable caph
	variable capfont
	variable captagfont
	set cv $cap(cv)
	$cv delete all
	cap_round $cv 0 0 $capw $caph 14 $c(bar) -outline $c(border)
	# the folder pill: its name and a chevron; a click opens the folder menu
	set tw [font measure $capfont $cap(folder)]
	set pr [expr {24 + 14 + 8 + $tw + 8 + 13 + 12}]
	set pill [cap_round $cv 14 11 [expr {14 + $pr}] 43 8 $c(field) -outline $c(border)]
	cap_icon $cv inbox 14 $c(muted) 24 20 cap_pick_folder
	$cv create text 46 27 -text $cap(folder) -anchor w -font $capfont -fill [ui::col $c(fg)]
	cap_icon $cv down 13 $c(muted) [expr {46 + $tw + 8}] 20 cap_pick_folder
	cap_area $cv {*}[cap_box_of $cv $pill] cap_pick_folder
	# the header's right side: pin and close
	set px [expr {14 + $pr + 6}]
	cap_icon $cv pin 15 [expr {$cap(pinned) ? $c(accent) : $c(muted)}] [expr {$px + 8}] 20 cap_pin_toggle
	cap_icon $cv x 15 $c(muted) 484 20 cap_close
	$cv create rectangle 0 55 $capw 56 -fill $c(border) -outline ""
	# the attachment card: a thumbnail, the file's name and size, and a remove mark
	set ty 278
	if {$cap(attach) ne ""} {
		set ty 338
		cap_round $cv 26 262 494 322 10 $c(field) -outline $c(border)
		$cv create image 34 270 -image $cap(thumb) -anchor nw
		$cv create text 110 284 -text [file tail $cap(attach)] -anchor w -font {{Ribbon Inter 500} -13} -fill [ui::col $c(fg)]
		$cv create text 110 301 -text [cap_size_text $cap(attach)] -anchor w -font {{Ribbon Inter 400} -12} \
			-fill [ui::col $c(muted)]
		cap_icon $cv x 13 $c(muted) 466 286 cap_attach_clear
	}
	# the tags row: a chip per tag (a click takes it off) and "+ Tag"
	set tx 26
	foreach t $cap(tags) {
		set hw [font measure $captagfont "#"]
		set cw [expr {[font measure $captagfont "#$t"] + 18}]
		set chip [cap_round $cv $tx $ty [expr {$tx + $cw}] [expr {$ty + 26}] 7 $c(field)]
		# the "#" is 70 % of the text colour
		$cv create text [expr {$tx + 9}] [expr {$ty + 13}] -anchor w -font $captagfont -text "#" \
			-fill [ui::col [ui::mix $c(muted) $c(field) 0.7]]
		$cv create text [expr {$tx + 9 + $hw}] [expr {$ty + 13}] -anchor w -font $captagfont -fill [ui::col $c(muted)] \
			-text $t
		cap_area $cv {*}[cap_box_of $cv $chip] [list cap_tag_remove $t]
		incr tx [expr {$cw + 6}]
	}
	set cap(tagx) $tx
	set cap(tagy) $ty
	set pw [expr {[font measure $captagfont Tag] + 40}]
	set plus [cap_round $cv $tx $ty [expr {$tx + $pw}] [expr {$ty + 26}] 7 $c(bar) -outline $c(border)]
	cap_icon $cv plus 12 $c(muted) [expr {$tx + 9}] [expr {$ty + 7}]
	$cv create text [expr {$tx + 27}] [expr {$ty + 13}] -anchor w -font $captagfont -fill [ui::col $c(muted)] -text Tag
	cap_area $cv {*}[cap_box_of $cv $plus] cap_tag_add
	$cv create rectangle 0 384 $capw 385 -fill $c(border) -outline ""
	# the toolbar: the checkbox is the one on a field; the list, picture and link act on the body
	set bx 14
	foreach {icon cmd} {checkbox cap_insert_checkbox list cap_insert_list image cap_insert_picture link cap_insert_link} {
		set bg [expr {$icon eq "checkbox" ? $c(field) : $c(bar)}]
		set fg [expr {$icon eq "checkbox" ? $c(fg) : $c(muted)}]
		set box [cap_round $cv $bx 400 [expr {$bx + 32}] 432 8 $bg]
		cap_icon $cv $icon 15 $fg [expr {$bx + 8}] 408 $cmd
		cap_area $cv {*}[cap_box_of $cv $box] $cmd
		incr bx 34
	}
	# Discard and Save, right aligned at 14 px from the panel's edge
	variable capbtnfont
	variable capbtnfont0
	set sw [expr {[font measure $capbtnfont Save] + 8 + 15 + 36}]
	set sx0 [expr {$capw - 14 - $sw}]
	cap_button $cv $sx0 397 [expr {$capw - 14}] 435 Save $::theme::c(ON_ACCENT) $c(accent) cap_save {} check $capbtnfont
	set dw [expr {[font measure $capbtnfont0 Discard] + 36}]
	cap_button $cv [expr {$sx0 - 10 - $dw}] 397 [expr {$sx0 - 10}] 435 Discard $c(fg) $c(bar) cap_discard $c(border) {} $capbtnfont0
}

# A rounded rectangle, filled, optionally outlined. Returns the polygon's item.
proc ::notesapp::cap_round {cv x0 y0 x1 y1 r fill args} {
	set pts [list [expr {$x0 + $r}] $y0 [expr {$x1 - $r}] $y0 $x1 $y0 $x1 [expr {$y0 + $r}] \
		$x1 [expr {$y1 - $r}] $x1 $y1 [expr {$x1 - $r}] $y1 [expr {$x0 + $r}] $y1 $x0 $y1 \
		$x0 [expr {$y1 - $r}] $x0 [expr {$y0 + $r}] $x0 $y0 [expr {$x0 + $r}] $y0]
	set outline [expr {[llength $args] > 0 ? [lindex $args 1] : ""}]
	return [$cv create polygon $pts -smooth 1 -fill $fill -outline $outline]
}

# The bounding box of an item, as x0 y0 x1 y1.
proc ::notesapp::cap_box_of {cv item} {
	return [$cv bbox $item]
}

# Binds a click command to one or more items, so a click on any of them runs the command. Only the items named
# are bound: a shape that covers the panel (the background) is never given a button's command.
proc ::notesapp::cap_area {cv args} {
	lassign $args x0 y0 x1 y1 cmd
	foreach it [$cv find enclosed [expr {$x0 - 1}] [expr {$y0 - 1}] [expr {$x1 + 1}] [expr {$y1 + 1}]] {
		$cv bind $it <ButtonRelease-1> [list ::notesapp::cap_run $cmd]
	}
}

# Runs a click command: a bare name, or a name with its arguments as a list.
proc ::notesapp::cap_run {cmd} {
	eval [list ::notesapp::[lindex $cmd 0]] [lrange $cmd 1 end]
}

# An icon on the panel: the tree's paths, or the capture's own, drawn with a click command when given. Returns the
# image item.
proc ::notesapp::cap_icon {cv name size colour x y {cmd ""}} {
	variable paths
	variable capicons
	if {[info exists capicons($name)]} {
		set d $capicons($name)
	} else {
		set d $paths($name)
	}
	set img [raster::icon $d $size 1.9 [ui::col $colour] {} 0 0 0]
	set item [$cv create image $x $y -image $img -anchor nw]
	if {$cmd ne ""} {
		$cv bind $item <ButtonRelease-1> ::notesapp::$cmd
	}
	return $item
}

# A text button with a centred label (and an icon after it) on a rounded background. Only its own items take the
# command.
proc ::notesapp::cap_button {cv x0 y0 x1 y1 label fg bg cmd {outline ""} {icon ""} {font ""}} {
	variable capfont
	if {$font eq ""} { set font $capfont }
	set cy [expr {($y0 + $y1) / 2}]
	set bgitem [cap_round $cv $x0 $y0 $x1 $y1 10 $bg -outline $outline]
	set tw [font measure $font $label]
	set iw [expr {$icon eq "" ? 0 : 23}]
	set sx [expr {($x0 + $x1) / 2 - ($tw + $iw) / 2}]
	set items [list $bgitem]
	lappend items [$cv create text $sx $cy -text $label -anchor w -fill [ui::col $fg] -font $font]
	if {$icon ne ""} {
		lappend items [cap_icon $cv $icon 15 $fg [expr {$sx + $tw + 8}] [expr {$cy - 8}]]
	}
	foreach it $items {
		$cv bind $it <ButtonRelease-1> ::notesapp::$cmd
	}
}

# The body's checkbox lines show a box: the "- [ ] " or "- [x] " marker is elided and an image (the editor's
# box) sits before it. Tk leaves images out of get, so the body text is still the Markdown.
proc ::notesapp::cap_restyle {} {
	variable cap
	set w $cap(body)
	set imgs {}
	foreach {k v idx} [$w dump -image 1.0 end] { lappend imgs $idx }
	foreach idx [lreverse $imgs] { $w delete $idx }
	$w tag remove elide 1.0 end
	$w tag remove done 1.0 end
	set last [lindex [split [$w index end] .] 0]
	for {set i 1} {$i < $last} {incr i} {
		set line [$w get $i.0 $i.end]
		if {[regexp {^- \[( |x)\] } $line -> mark]} {
			set done [expr {$mark eq "x"}]
			$w tag add elide $i.0 $i.6
			if {$done} { $w tag add done $i.6 $i.end }
			$w image create $i.0 -image [cap_box $done] -padx 0 -pady 0
		}
	}
}

# A click on a box toggles that line: the box is the image at the line's start (column 0).
proc ::notesapp::cap_click {x y} {
	variable cap
	set w $cap(body)
	set idx [$w index @$x,$y]
	lassign [split $idx .] ln col
	if {$col != 0} return
	set line [$w get $ln.0 $ln.end]
	if {![regexp {^- \[( |x)\] } $line -> mark]} return
	# the box is one index (the image) at column 0, so the marker "[ ]" is the 3rd character after it: "- [ ]"
	set at "$ln.0+4 chars"
	set nxt "$ln.0+5 chars"
	if {[$w get $at $nxt] ne $mark} return
	$w delete $at $nxt
	$w insert $at [expr {$mark eq "x" ? " " : "x"}]
	cap_restyle
}

# The editor's box (box 26, text 56 on the panel).
proc ::notesapp::cap_box {done} {
	variable capbox
	if {[info exists capbox($done)]} { return $capbox($done) }
	# the editor's 30 x 32 box row: the box, the 12 px gap, and the 32 px row of the board
	set out [checkbox $done]
	set capbox($done) $out
	return $out
}

# The toolbar: a checkbox or a bullet at the start of the line, a picture, a link.
proc ::notesapp::cap_insert_checkbox {} {
	variable cap
	$cap(body) insert "insert linestart" "- \[ \] "
	cap_restyle
	focus $cap(body)
}
proc ::notesapp::cap_insert_list {} {
	variable cap
	$cap(body) insert "insert linestart" "- "
	cap_restyle
	focus $cap(body)
}

# Picks a picture to attach: it shows as a card and is copied next to the note on Save. The types are the ones
# Tk reads (the editor's Insert picture takes the same).
proc ::notesapp::cap_insert_picture {} {
	variable cap
	set src [choose open_file -parent $cap(win) -title "Attach a picture" -filetypes [picture_types]]
	if {$src eq ""} return
	cap_attach_set $src
}

# A link in the body: the clipboard's web address as the link, or a placeholder to fill in.
proc ::notesapp::cap_insert_link {} {
	variable cap
	set url ""
	catch {set url [string trim [clipboard get]]}
	if {[regexp {^https?://\S+$} $url]} {
		set text "\[$url\]($url)"
	} else {
		set text {[link text](https://)}
	}
	$cap(body) insert insert $text
	cap_restyle
	focus $cap(body)
}

# An attachment: a thumbnail of the picture (its file is read by Tk) and its name; the card goes with a remove.
proc ::notesapp::cap_attach_set {src} {
	variable cap
	# Tk reads PNG, GIF and PPM; a JPEG (or WebP, AVIF, BMP) goes through ffmpeg, as in the Image Viewer
	if {[catch {load_photo $src} img]} {
		puts stderr "ribbon-notes: cannot read the picture $src: $img"
		return
	}
	# the card's thumbnail is 64 x 44: the picture's middle, cropped to that shape and shrunk to it
	set w [image width $img]
	set h [image height $img]
	set cw [expr {min($w, $h * 64 / 44)}]
	set ch [expr {min($h, $w * 44 / 64)}]
	set x0 [expr {($w - $cw) / 2}]
	set y0 [expr {($h - $ch) / 2}]
	set thumb [image create photo -width 64 -height 44]
	for {set y 0} {$y < 44} {incr y} {
		set sy [expr {$y0 + $y * $ch / 44}]
		set row {}
		for {set x 0} {$x < 64} {incr x} {
			set sx [expr {$x0 + $x * $cw / 64}]
			lappend row [format #%02x%02x%02x {*}[$img get $sx $sy]]
		}
		$thumb put [list $row] -to 0 $y
	}
	# rounded to 6 px, on the card's field colour
	round_photo $thumb 6 [ui::col $::notesapp::c(field)]
	image delete $img
	cap_attach_clear
	set cap(attach) $src
	set cap(thumb) $thumb
	cap_draw
}

proc ::notesapp::cap_attach_clear {} {
	variable cap
	if {$cap(thumb) ne ""} { catch {image delete $cap(thumb)} }
	set cap(thumb) ""
	set cap(attach) ""
	if {[info exists cap(cv)] && $cap(cv) ne "" && [winfo exists $cap(cv)]} { cap_draw }
}

# The size of a file for the card: kilobytes, or megabytes to one place.
proc ::notesapp::cap_size_text {file} {
	set n [file size $file]
	if {$n >= 1000000} { return [format "%.1f MB" [expr {$n / 1000000.0}]] }
	return [format "%d KB" [expr {max(1, round($n / 1000.0))}]]
}

proc ::notesapp::cap_pin_toggle {} {
	variable cap
	set cap(pinned) [expr {!$cap(pinned)}]
	cap_draw
}

# The folder menu under the pill: every folder of the notes, the open choice checked.
proc ::notesapp::cap_pick_folder {} {
	variable cap
	variable c
	set m $cap(win).fm
	catch {destroy $m}
	menu $m -tearoff 0 -font {{Ribbon Inter 400} -13} -background $c(field) -foreground $c(fg) \
		-activebackground $c(pill) -activeforeground $c(fg) -borderwidth 1 -relief flat
	foreach f [notes::store::folders] {
		$m add radiobutton -label $f -variable ::notesapp::cap(folder) -value $f \
			-command [list ::notesapp::cap_set_folder $f]
	}
	set x [expr {[winfo rootx $cap(cv)] + 14}]
	set y [expr {[winfo rooty $cap(cv)] + 46}]
	tk_popup $m $x $y
}

proc ::notesapp::cap_set_folder {folder} {
	variable cap
	set cap(folder) $folder
	cap_draw
}

# A tag: "#" and the name, lower case, a letter first. Returns "" when the text is not a tag.
proc ::notesapp::cap_tag_clean {text} {
	set t [string tolower [string trimleft [string trim $text] #]]
	if {[regexp {^[[:alpha:]][[:alnum:]_/-]*$} $t]} { return $t }
	return ""
}

# "+ Tag" opens an entry at the slot: Return adds the tag, Escape or leaving the entry drops it.
proc ::notesapp::cap_tag_add {} {
	variable cap
	variable c
	variable captagfont
	if {$cap(tagentry) ne "" && [winfo exists $cap(tagentry)]} {
		focus $cap(tagentry)
		return
	}
	set e $cap(win).g
	entry $e -font $captagfont -relief flat -borderwidth 0 -highlightthickness 0 -background $c(field) \
		-foreground $c(fg) -insertbackground $c(accent)
	place $e -x $cap(tagx) -y $cap(tagy) -width 96 -height 26
	bind $e <Return> {::notesapp::cap_tag_commit; break}
	bind $e <Escape> {::notesapp::cap_tag_cancel; break}
	bind $e <FocusOut> ::notesapp::cap_tag_cancel
	set cap(tagentry) $e
	focus $e
}

proc ::notesapp::cap_tag_commit {} {
	variable cap
	if {$cap(tagentry) eq "" || ![winfo exists $cap(tagentry)]} return
	set t [cap_tag_clean [$cap(tagentry) get]]
	cap_tag_cancel
	if {$t ne "" && $t ni $cap(tags)} { lappend cap(tags) $t }
	cap_draw
	focus $cap(body)
}

proc ::notesapp::cap_tag_cancel {} {
	variable cap
	if {$cap(tagentry) eq "" || ![winfo exists $cap(tagentry)]} {
		set cap(tagentry) ""
		return
	}
	set e $cap(tagentry)
	set cap(tagentry) ""
	destroy $e
}

proc ::notesapp::cap_tag_remove {t} {
	variable cap
	set cap(tags) [lsearch -all -inline -not -exact $cap(tags) $t]
	cap_draw
}

proc ::notesapp::cap_discard {} { cap_close }

proc ::notesapp::cap_close {} {
	variable cap
	if {[winfo exists $cap(win)]} { destroy $cap(win) }
	set cap(win) ""
	cap_attach_clear
	if {$cap(standalone)} { exit 0 }
}

# A file name in DIR that is not taken: NAME, then "NAME 2", "NAME 3" and so on before the extension.
proc ::notesapp::cap_unique {dir name} {
	set base [file rootname $name]
	set ext [file extension $name]
	set out $name
	set i 1
	while {[file exists [file join $dir $out]]} {
		incr i
		set out "$base $i$ext"
	}
	return $out
}

# Writes the panel to a new note in its folder: the title as the heading, the body, the picture as a Markdown image
# (a copy next to the note), and the tags on a last line. Then the panel closes.
proc ::notesapp::cap_save {} {
	variable cap
	set title [string trim [$cap(title) get]]
	set body [string trimright [$cap(body) get 1.0 end-1c]]
	set picture $cap(attach)
	if {$title eq "" && [string trim $body] eq "" && $picture eq ""} { cap_close; return }
	set folder $cap(folder)
	set dir [notes::store::dir_of $folder]
	if {[catch {
		set name [notes::store::create_note $folder]
		set blocks {}
		if {$title ne ""} { lappend blocks "# $title" }
		if {[string trim $body] ne ""} { lappend blocks $body }
		if {$picture ne ""} {
			set file [cap_unique $dir [file tail $picture]]
			file copy -- $picture [file join $dir $file]
			lappend blocks "!\[[file rootname $file]\]($file)"
		}
		if {[llength $cap(tags)] > 0} {
			set hs {}
			foreach t $cap(tags) { lappend hs "#$t" }
			lappend blocks [join $hs " "]
		}
		set text "[join $blocks \n\n]\n"
		notes::store::write_note $folder $name [notes::md::build $cap(pinned) 0 {} $text]
		if {$title ne ""} {
			catch {notes::store::rename_note $folder $name $title}
		}
	} err]} {
		puts stderr "ribbon-notes: could not save the note: $err"
		return
	}
	notes::index::refresh
	if {[winfo exists $::notesapp::cv]} { ::notesapp::paint }
	cap_close
}

# The scene's screenshot of the panel alone (the scene keeps the panel at the board's 460, 132).
proc ::notesapp::cap_shot {file} {
	variable cap
	variable capw
	variable caph
	update
	raise $cap(win)
	update
	set x [winfo rootx $cap(win)]
	set y [winfo rooty $cap(win)]
	exec import -window root -crop ${capw}x${caph}+$x+$y +repage $file
	exit 0
}
