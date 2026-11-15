# editor.tcl - the note page (U34): the Markdown in a Tk text widget on a 620 px measure, styled from
# notes::md::lines and notes::md::spans. The widget holds the body exactly as written (its get is the Markdown
# body), so saving writes back the text that was read: markers are elided, never removed. Checkboxes toggle on a
# click, images are shown in place of their line, code fences draw as code blocks, and a floating bar formats the
# selection. Find marks every match of the search and steps through them. The header is drawn on the canvas.

namespace eval ::notesapp {
	variable rendering 0
	variable page_bar ""        ;# the floating format bar (a frame over the text)
	variable images
	array set images {}         ;# file -> photo name (note pictures, cached)
	variable boxes
	array set boxes {}          ;# checkbox and bullet photos
	variable metan 0            ;# the meta frames made so far (each gets a new name)
	variable cur_body ""        ;# the body the widget last showed, for undo
	variable undo_stack {}
	variable redo_stack {}
	variable last_edit 0
	variable bar_xy {0 0}       ;# where the format bar was last placed (page coordinates)
	variable hrefs
	array set hrefs {}          ;# href<N> tag -> the link's target, for the links of the body as drawn
	variable hrefn 0
	variable press_at ""        ;# the text index a button press went down on (a click on a link opens it)
	variable synstate 0         ;# 1 once the code colours are set up (highlight.tcl found)
}

proc ::notesapp::build_text {win} {
	variable page
	variable page_bar
	variable c
	variable W
	text::font nbody {Ribbon Inter 400} 15
	text::font nbold {Ribbon Inter 600} 15
	text::font nh1 {Ribbon Space Grotesk 600} 32
	text::font nh2 {Ribbon Space Grotesk 600} 20
	text::font nh3 {Ribbon Space Grotesk 600} 17
	text::font nmono {Ribbon Mono} 13
	text::font nbar {Ribbon Inter 500} 13
	text::font ngap {Ribbon Inter 400} 1
	text::font nmeta {Ribbon Inter 400} 13
	text::font nchip {Ribbon Inter 500} 12
	text::font ncap {Ribbon Inter 400} 13
	::font create nital -family {Ribbon Inter 400} -size -15 -slant italic
	# the body is 15 px at line-height 1.7 (25.5 px a line): the spacing between the lines of a paragraph is set here
	::text $page -wrap word -undo 0 -borderwidth 0 -highlightthickness 0 -padx 0 -pady 0 -spacing1 0 -spacing2 6 -spacing3 0 \
		-background $c(bar) -foreground $c(fg) -insertbackground $c(accent) -selectbackground $c(sel) -selectforeground $c(fg) \
		-inactiveselectbackground $c(sel) -exportselection 0 -font nbody -cursor xterm
	$page tag configure body -font nbody -foreground $c(fg)
	# the board's margins: a heading has 22 px above and 12 below; a blank line is a 1 px line (the margins do the work)
	foreach n {0 15 19} { $page tag configure gap$n -font ngap -spacing1 $n -spacing2 0 -spacing3 0 }
	$page tag configure h1 -font nh1 -spacing1 0 -spacing3 12
	$page tag configure h2 -font nh2 -spacing1 22 -spacing3 12
	$page tag configure h3 -font nh3 -spacing1 16 -spacing3 4
	$page tag configure quote -foreground $c(muted) -lmargin1 14 -lmargin2 14
	# a bullet row is 28 px high and its text starts 30 px in, as a checkbox row's does (the box or dot is an image)
	$page tag configure bullet -lmargin1 0 -lmargin2 30
	# a checkbox row is 32 px high (the box image is 32 px high, so no spacing is needed) and its text starts 30 px in
	$page tag configure box -lmargin1 0 -lmargin2 30
	$page tag configure done -overstrike 1 -foreground $c(muted)
	$page tag configure strike -overstrike 1
	$page tag configure code -font nmono -background $c(field)
	# a code block is the board's d2 field with 14 px above and below: the fence lines are 1 px lines that carry it
	$page tag configure codeblock -font nmono -background $c(d2) -lmargin1 16 -lmargin2 16 -rmargin 16 -spacing1 0 -spacing2 0 -spacing3 3
	$page tag configure cbopen -font ngap -background $c(d2) -spacing1 4 -spacing3 14
	$page tag configure cbclose -font ngap -background $c(d2) -spacing1 0 -spacing3 14
	# a picture is its own line, with 10 px under it for the caption (the line that names the file)
	$page tag configure pic -spacing3 10
	$page tag configure caption -font ncap -foreground $c(muted)
	# the meta line under the title: 28 px under it, as the board's margin
	$page tag configure meta -spacing1 0 -spacing3 28
	$page tag configure bold -font nbold
	$page tag configure italic -font nital
	# a link (Notes-R4-A-Tree's "Settings"): the text colour, underlined in the muted colour
	$page tag configure link -foreground $c(fg) -underline 1 -underlinefg $c(muted)
	$page tag bind link <Enter> [list $page configure -cursor hand2]
	$page tag bind link <Leave> [list $page configure -cursor xterm]
	syn_setup
	$page tag configure hit -background $c(hit)
	$page tag configure cur -background $c(soft2) -underline 1
	$page tag configure elide -elide 1
	$page tag raise elide
	place forget $page
	# the format bar (Notes-R4-A2-Edit): Text style, Bold, Italic, Strike, Code, then Link; 40 px high, 30 px buttons
	set bar $win.fmt
	set page_bar $bar
	# the bar takes its width from its buttons (a frame that does not propagate with no -width is 1 px wide); the
	# buttons are packed with 5 px above and below, which makes it 40 px high
	frame $bar -background $c(field) -borderwidth 0 -highlightthickness 0
	frame $bar.pad -width 5 -background $c(field)
	pack $bar.pad -side left -pady 5
	set t [bar_text_button $bar.text]
	pack $t -side left -pady 5
	bar_divider $bar.d1 4
	bar_button $bar.bold B {::notesapp::format_bold} 1
	bar_button $bar.italic I {::notesapp::format_italic} 0
	bar_button $bar.strike S {::notesapp::format_strike} 0
	bar_button $bar.code C {::notesapp::format_code} 0
	bar_divider $bar.d2 4
	bar_button $bar.link L {::notesapp::format_link} 0
	frame $bar.pad2 -width 5 -background $c(field)
	pack $bar.pad2 -side left
	bind $page <<Modified>> {::notesapp::modified}
	bind $page <<Paste>> {::notesapp::paste; break}
	bind $page <ButtonPress-1> {set ::notesapp::press_at [%W index @%x,%y]}
	bind $page <ButtonRelease-1> {::notesapp::clicked %x %y}
	bind $page <KeyRelease> {::notesapp::format_update}
	bind $page <ButtonRelease-1> +{::notesapp::format_update}
}

# A bar button: a 30 px square with its glyph (on = the pressed state, the pill colour). Its glyph is drawn with the
# line icons of the bar.
proc ::notesapp::bar_button {f glyph cmd on} {
	variable c
	set bg [expr {$on ? $c(pill) : $c(field)}]
	set paths [dict create B {M6 4h8a4 4 0 0 1 0 8H6z M6 12h9a4 4 0 0 1 0 8H6z} \
		I {M19 4h-9 M14 20H5 M15 4L9 20} S {M16 4H9a3 3 0 0 0-2.83 4 M14 12a4 4 0 0 1 0 8H6 M4 12h16} \
		C {M16 18l6-6-6-6 M8 6l-6 6 6 6} L {M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71 M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71}]
	set fg [expr {$on ? $c(fg) : $c(muted)}]
	set img [raster::icon [dict get $paths $glyph] 15 1.9 [ui::col $fg]]
	::frame $f -width 30 -height 30 -background $bg -borderwidth 0 -highlightthickness 0
	pack propagate $f 0
	::label $f.i -image $img -background $bg -borderwidth 0 -highlightthickness 0
	place $f.i -relx 0.5 -rely 0.5 -anchor center
	if {$cmd ne ""} {
		foreach w [list $f $f.i] { bind $w <Button-1> $cmd }
	}
	pack $f -side left -padx 1 -pady 5
	return $f
}

proc ::notesapp::bar_divider {f pad} {
	variable c
	::frame $f -width 1 -height 18 -background $c(border) -borderwidth 0 -highlightthickness 0
	pack $f -side left -padx $pad -pady 11
}

# The Text style button: the style of the line the insert point is on, with a chevron; a click opens the style menu.
proc ::notesapp::bar_text_button {f} {
	variable c
	set bg $c(field)
	::frame $f -background $bg -borderwidth 0 -highlightthickness 0
	# 30 px high: the label's pady makes up what its font leaves
	set py [expr {(30 - [::font metrics nbar -linespace]) / 2}]
	::label $f.l -text "Text" -font nbar -foreground $c(fg) -background $bg -borderwidth 0 -highlightthickness 0 -padx 0 -pady $py
	::label $f.i -image [raster::icon {M6 9l6 6 6-6} 13 2 [ui::col $c(muted)]] -background $bg -borderwidth 0 -highlightthickness 0
	pack $f.l -side left -padx {10 6}
	pack $f.i -side left -padx {0 8}
	foreach w [list $f $f.l $f.i] { bind $w <Button-1> {::notesapp::style_menu} }
	return $f
}

# The code colours of a fenced block are the Text editor's (apps/editor/highlight.tcl, its Tk-free tokenizer), in
# the palette's SYN_ colours: comments italic, function names bold, in the note's 13 px mono.
proc ::notesapp::syn_setup {} {
	variable page
	variable synstate
	variable appdir
	set file ""
	foreach d [list [file join $appdir .. editor] [file join $appdir .. .. editor] /usr/lib/ribbon/apps/editor /usr/lib/ribbon/editor] {
		if {[file exists [file join $d highlight.tcl]]} { set file [file normalize [file join $d highlight.tcl]]; break }
	}
	if {$file eq ""} return
	if {[info commands ::highlight::tokens] eq ""} {
		namespace eval ::editor {}
		uplevel #0 [list source -encoding utf-8 $file]
	}
	set fam [::font configure nmono -family]
	set px [expr {abs([::font configure nmono -size])}]
	if {"nmonoi" ni [::font names]} { ::font create nmonoi -family $fam -size -$px -slant italic }
	if {"nmonob" ni [::font names]} { ::font create nmonob -family $fam -size -$px -weight bold }
	foreach cls {com str var kw fn num opt pun} {
		set f [expr {$cls eq "com" ? "nmonoi" : ($cls eq "fn" ? "nmonob" : "nmono")}]
		$page tag configure syn_$cls -foreground $::theme::c(SYN_[string toupper $cls]) -font $f
	}
	set synstate 1
}

# The highlighter's language for a fence line (```tcl, ```sh ...): "" for none or one it has no rules for.
proc ::notesapp::syn_lang {fence} {
	variable synstate
	if {!$synstate} { return "" }
	if {![regexp {^\s*```\s*([A-Za-z0-9_+.-]*)} $fence -> name]} { return "" }
	set name [string tolower $name]
	foreach {lang names} {tcl {tcl tk wish} sh {sh bash shell zsh console} py {py python python3} c {c h cpp c++ cc}
			json {json} ini {ini conf cfg toml desktop} diff {diff patch} md {md markdown}} {
		if {$name in $names} { return $lang }
	}
	return ""
}

# Where the page sits: on its 620 px measure in the middle of the room right of the tree, 84 px down, to 20 px
# above the bottom (the window may be any size; the board's 1240 x 780 puts it at 460).
proc ::notesapp::page_x {} {
	variable W
	variable BW
	variable MEASE
	expr {$BW + ($W - $BW - $MEASE) / 2}
}

proc ::notesapp::page_place {} {
	variable page
	variable H
	variable MEASE
	place $page -x [page_x] -y 84 -width $MEASE -height [expr {$H - 104}]
}

# Places the body (the note's text without its front matter) and styles it.
proc ::notesapp::page_load {folder name {text ""}} {
	variable page
	variable state
	variable rendering
	if {$text eq ""} { set text [notes::store::read_note $folder $name] }
	set body [dict get [notes::md::parse $text] body]
	set rendering 1
	$page delete 1.0 end
	render $body $folder
	set rendering 0
	$page edit modified 0
	variable cur_body [body_text]
	variable undo_stack {}
	variable redo_stack {}
	variable last_edit 0
	$page mark set insert 1.0
	$page yview moveto 0
	page_place
	set state(dirty) 0
	find_marks
}

# The Markdown of the body as it is in the widget. The meta frame sits on its own line after the first line, so
# the text before it loses the newline that comes before the frame; a note of one line has no text after it.
proc ::notesapp::body_text {} {
	variable page
	if {"metamark" ni [$page mark names]} { return [$page get 1.0 end-1c] }
	set before [string range [$page get 1.0 metamark] 0 end-1]
	set after [$page get "metamark + 1 chars" end-1c]
	return "$before$after"
}

# The meta line under the title: the folder, when it was edited, and the note's tags. LAST is the index of the
# note's last body line, so a newline is added after the frame when there is more text.
proc ::notesapp::meta_line {folder body last} {
	variable page
	variable c
	variable state
	variable metan
	set f $page.m[incr metan]
	::frame $f -background $c(bar) -borderwidth 0 -highlightthickness 0
	set mt [file mtime [notes::store::note_path $folder $state(note)]]
	set age [expr {[clock seconds] - $mt}]
	set when [expr {$age < 60 ? "just now" : [expr {[clock format $mt -format %Y%j] == [clock format [clock seconds] -format %Y%j] ? "today, [clock format $mt -format %H:%M]" : [date_label $mt]}]}]
	set where [expr {$folder eq "" ? "Notes" : [file tail $folder]}]
	# the board's meta line: a folder glyph and the folder, a dot, "Edited ...", then the tags as 24 px pills (13 and 12 px)
	set font nmeta
	::label $f.fi -image [raster::icon {M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z} 14 2 [ui::col $c(muted)]] \
		-background $c(bar) -borderwidth 0 -highlightthickness 0
	::label $f.where -text $where -font $font -foreground $c(muted) -background $c(bar) -borderwidth 0 -highlightthickness 0 -padx 0
	::label $f.dot -text "·" -font $font -foreground $c(muted) -background $c(bar) -borderwidth 0 -highlightthickness 0 -padx 0
	::label $f.when -text "Edited $when" -font $font -foreground $c(muted) -background $c(bar) -borderwidth 0 -highlightthickness 0 -padx 0
	pack $f.fi -side left -padx {0 6}
	pack $f.where -side left -padx {0 10}
	pack $f.dot -side left -padx {0 10}
	pack $f.when -side left -padx {0 18}
	# a tag pill: 24 px high, the "#" at 70 % of the text colour
	set py [expr {(24 - [::font metrics nchip -linespace]) / 2}]
	set tagfg $c(muted)
	foreach t [notes::md::tags $body] {
		set bgc $c(field)
		::frame $f.t$t -background $bgc -borderwidth 0 -highlightthickness 0
		::label $f.t$t.h -text "#" -font nchip -foreground [ui::mix $tagfg $bgc 0.7] -background $bgc -borderwidth 0 -padx 0 -pady $py
		::label $f.t$t.n -text $t -font nchip -foreground $tagfg -background $bgc -borderwidth 0 -padx 0 -pady $py
		pack $f.t$t.h $f.t$t.n -side left
		$f.t$t.h configure -padx 0
		pack configure $f.t$t.h -padx {9 0}
		pack configure $f.t$t.n -padx {0 9}
		pack $f.t$t -side left -padx {0 6}
	}
	# the newline before the frame is the first line's own (render adds it when there are more lines)
	if {$last == 0} { $page insert end "\n" meta }
	$page mark set metamark [$page index end-1c]
	$page mark gravity metamark left
	$page window create metamark -window $f -padx 0 -pady 0
	$page tag add meta metamark "metamark + 1 chars"
	if {$last > 0} { $page insert end "\n" meta }
}

# The blank line between two blocks is a 1 px line with the board's margin as its spacing: a heading brings its own
# margin (22 above), a picture 20, a code block 16 after a paragraph, anything else 16.
proc ::notesapp::gap_tag {prevkind nextkind} {
	if {$prevkind eq "h"} { return gap0 }
	switch -- $nextkind {
		h { return gap0 }
		image { return gap19 }
		default { return gap15 }
	}
}

# Writes the lines of BODY with their tags. Every tag range is counted from the start of the line's text, after any
# picture or checkbox image on that line (an image takes one index). Images load from the note's folder.
proc ::notesapp::render {body folder} {
	variable page
	variable hrefs
	variable hrefn
	catch {$page mark unset metamark}
	foreach t [array names hrefs] { catch {$page tag delete $t} }
	array unset hrefs
	set hrefn 0
	set lang ""
	set synst ""
	set entries [notes::md::lines $body]
	set last [expr {[llength $entries] - 1}]
	set k 0
	set fences 0
	set lastpic ""
	set prevkind ""
	foreach e $entries {
		set kind [lindex $e 0]
		set raw [lindex $e end]
		set base [list body]
		set elide {}
		set whole 0
		set photo ""
		set picname ""
		switch $kind {
			fence {
				set base [expr {[incr fences] % 2 ? "cbopen" : "cbclose"}]
				set whole 1
				# the opening fence names the block's language (```tcl): its lines take the code colours
				set lang [expr {$fences % 2 ? [syn_lang $raw] : ""}]
				set synst ""
			}
			code { set base codeblock }
			h {
				set lv [lindex $e 1]
				set base [list h[expr {$lv > 3 ? 3 : $lv}]]
				set elide [list 0 [expr {$lv + 1}]]
			}
			box {
				set base box
				if {[lindex $e 1]} { lappend base done }
				set elide [list 0 [expr {[string length $raw] - [string length [lindex $e 2]]}]]
			}
			bullet {
				set base bullet
				if {[regexp -indices {^\s*[-*] } $raw m]} { set elide [list [lindex $m 0] [expr {[lindex $m 1] + 1}]] }
			}
			quote {
				set base quote
				set elide [list 0 2]
			}
			image {
				set photo [picture [lindex $e 2] $folder]
				if {$photo ne ""} { set whole 1; set base [list body pic]; set picname [lindex $e 2] }
			}
			plain {
				# the line under a picture that names its file is the caption
				if {$lastpic ne "" && $raw eq $lastpic} { set base [list body caption] }
			}
		}
		set lastpic $picname
		set curkind $kind
		# a blank line is the 1 px gap: its spacing is the margin the next block asks for
		if {$kind eq "plain" && $raw eq ""} {
			set nk [expr {$k < $last ? [lindex [lindex $entries [expr {$k + 1}]] 0] : "plain"}]
			set base [gap_tag $prevkind $nk]
		}
		# the picture, checkbox or bullet on the line, then the text; the image carries the line's tags so that the
		# line's margins and spacing are the line's own
		set s [$page index {end - 1 chars}]
		set hasimg 0
		if {$kind eq "image" && $photo ne ""} { $page image create end -image $photo -padx 0 -pady 0; set hasimg 1 }
		if {$kind eq "box"} { $page image create end -image [checkbox [lindex $e 1]] -padx 0 -pady 0 -align center; set hasimg 1 }
		if {$kind eq "bullet"} { $page image create end -image [dot] -padx 0 -pady 0 -align center; set hasimg 1 }
		if {$hasimg} {
			# the image is the first index of the line (an index read straight after creating it can be stale)
			$page tag add [lindex $base 0] $s "$s + 1 chars"
			set s "$s + 1 chars"
		}
		$page insert end $raw $base
		if {$k < $last} { $page insert end "\n" $base }
		# the meta line goes under the first line (the title), as an embedded frame; body_text leaves it out
		if {$k == 0} { meta_line $folder $body $last }
		if {$whole} {
			$page tag add elide $s "$s + [string length $raw] chars"
		} elseif {[llength $elide]} {
			lassign $elide a b
			if {$b > $a} { $page tag add elide "$s + $a chars" "$s + $b chars" }
		}
		if {$kind eq "code" && $lang ne ""} {
			lassign [highlight::tokens $lang $raw $synst] cl synst
			foreach r [highlight::runs $cl] {
				lassign $r a b cls
				$page tag add syn_$cls "$s + $a chars" "$s + $b chars"
			}
		}
		if {$kind ni {fence code image}} {
			# a done checklist item is struck text throughout: its inline code is not drawn as a chip (the board's
			# done "Folders and #tags"); the backticks stay elided
			set struck [expr {$kind eq "box" && [lindex $e 1]}]
			set spans [notes::md::spans $raw]
			for {set i 0} {$i < [llength $spans]} {incr i} {
				lassign [lindex $spans $i] from to tags
				if {$struck && $tags eq "code"} continue
				$page tag add $tags "$s + $from chars" "$s + $to chars"
				# a link's target is in the marks after its text ("](url)"): the text gets its own tag that names it
				if {$tags eq "link"} {
					lassign [lindex $spans [expr {$i + 1}]] mfrom mto
					set url [string range $raw [expr {$mfrom + 2}] [expr {$mto - 2}]]
					set t href[incr hrefn]
					set hrefs($t) $url
					$page tag add $t "$s + $from chars" "$s + $to chars"
				}
			}
		}
		set prevkind $curkind
		incr k
	}
}

# The picture types the file dialogs offer: what Tk reads, and JPEG, WebP, AVIF and BMP when ffmpeg is there.
proc ::notesapp::picture_types {} {
	set e {.png .gif .ppm .pgm}
	if {[auto_execok ffmpeg] ne ""} { lappend e .jpg .jpeg .webp .avif .bmp }
	return [list [list Pictures $e]]
}

# A photo of FILE: Tk reads PNG, GIF, PPM and PGM; JPEG, WebP, AVIF and BMP go through ffmpeg to a PNG, the way the
# Image Viewer reads them (apps/viewer/stage.tcl), at most MAXW px wide. An error when the file cannot be read.
proc ::notesapp::load_photo {file {maxw 0}} {
	set e [string range [string tolower [file extension $file]] 1 end]
	if {$e in {png gif ppm pgm}} { return [image create photo -file $file] }
	if {$e in {jpg jpeg webp avif bmp} && [auto_execok ffmpeg] ne ""} {
		set tmp [file tempfile tmpname .png]
		close $tmp
		set vf [expr {$maxw > 0 ? "scale=w='min(iw,$maxw)':h=-2" : "null"}]
		if {![catch {exec ffmpeg -nostdin -v error -y -i $file -frames:v 1 -vf $vf $tmpname </dev/null >/dev/null 2>@1}] && [file size $tmpname] > 0} {
			set img [image create photo -file $tmpname]
			file delete $tmpname
			return $img
		}
		catch {file delete $tmpname}
	}
	error "cannot read the picture $file"
}

# The photo's corners rounded to R px: the corner pixels are blended with BG by how much of the pixel is inside the
# circle (a photo has no soft alpha, so the colour round it is the one the picture sits on).
proc ::notesapp::round_photo {img r bg} {
	set w [image width $img]
	set h [image height $img]
	if {$r * 2 > $w || $r * 2 > $h} return
	lassign [raster::rgb $bg] br bgc bb
	foreach {cx cy ox oy} [list $r $r 0 0 [expr {$w - $r}] $r [expr {$w - $r}] 0 $r [expr {$h - $r}] 0 [expr {$h - $r}] \
			[expr {$w - $r}] [expr {$h - $r}] [expr {$w - $r}] [expr {$h - $r}]] {
		for {set j 0} {$j < $r} {incr j} {
			for {set i 0} {$i < $r} {incr i} {
				set x [expr {$ox + $i}]
				set y [expr {$oy + $j}]
				# sub-samples of the pixel inside the circle centred on the corner's inner point
				set in 0
				for {set a 0} {$a < 4} {incr a} {
					for {set b 0} {$b < 4} {incr b} {
						set dx [expr {$x + ($a + 0.5) / 4.0 - $cx}]
						set dy [expr {$y + ($b + 0.5) / 4.0 - $cy}]
						if {$dx * $dx + $dy * $dy <= $r * $r} { incr in }
					}
				}
				if {$in == 16} continue
				set cov [expr {$in / 16.0}]
				lassign [$img get $x $y] pr pg pb
				$img put [format #%02x%02x%02x [expr {round($pr * $cov + $br * (1 - $cov))}] \
					[expr {round($pg * $cov + $bgc * (1 - $cov))}] [expr {round($pb * $cov + $bb * (1 - $cov))}]] -to $x $y
			}
		}
	}
}

# The picture of a note: its file, at most the measure (620 px) wide, corners rounded to 12 px; nothing when it
# cannot load.
proc ::notesapp::picture {path folder} {
	variable images
	variable c
	set file [file join [notes::store::dir_of $folder] $path]
	if {![file exists $file]} { return "" }
	if {[info exists images($file)]} { return $images($file) }
	if {[catch {load_photo $file 620} img]} { return "" }
	set w [image width $img]
	set f 1
	while {$w / $f > 620} { incr f }
	if {$f > 1} {
		set small [image create photo]
		$small copy $img -subsample $f
		image delete $img
		set img $small
	}
	round_photo $img 12 [ui::col $c(bar)]
	set images($file) $img
	return $img
}

# A checkbox, drawn once per state.
# The 18 px box (STYLE.md 9): a done box is a pill fill with a 1 px border and a 12 px check in the text colour; an
# open box is a 1.5 px muted ring. The photo is 30 px wide: the box, then the 12 px gap to the text.
proc ::notesapp::checkbox {done} {
	variable boxes
	variable c
	if {[info exists boxes($done)]} { return $boxes($done) }
	# the 18 px box is 24 units of the icon grid; the 1.5 px ring is 2 units, centred 1 unit in
	set ring {M6.67 1 H17.33 A5.67 5.67 0 0 1 23 6.67 V17.33 A5.67 5.67 0 0 1 17.33 23 H6.67 A5.67 5.67 0 0 1 1 17.33 V6.67 A5.67 5.67 0 0 1 6.67 1 Z}
	# the photo is the whole 32 px row (min-height 32): the box sits in its middle, 7 px down
	set out [image create photo -width 30 -height 32]
	set oy 7
	if {$done} {
		set fill [raster::icon {M0 0} 18 1 [ui::col $c(pill)] {0 0 24 24 6.67}]
		set edge [raster::icon $ring 18 1.33 [ui::col $c(border)]]
		set tick [raster::icon {M17.33 8 L10 15.33 L6.67 12} 18 2 [ui::col $c(fg)]]
		foreach layer [list $fill $edge $tick] { $out copy $layer -to 0 $oy 18 [expr {$oy + 18}] -compositingrule overlay }
	} else {
		set edge [raster::icon $ring 18 2 [ui::col $c(muted)]]
		$out copy $edge -to 0 $oy 18 [expr {$oy + 18}] -compositingrule overlay
	}
	set boxes($done) $out
	return $out
}

# The bullet: a 5 px muted dot in an 18 px column, 3 px above the line's middle (the board's translateY(-3px)); the
# photo is 30 px wide (the 12 px gap to the text) and the 28 px of a bullet row.
proc ::notesapp::dot {} {
	variable boxes
	variable c
	if {[info exists boxes(dot)]} { return $boxes(dot) }
	set out [image create photo -width 30 -height 28]
	set d [raster::icon {M0 0} 5 1 [ui::col $c(muted)] {0 0 24 24 12}]
	$out copy $d -to 7 9 12 14 -compositingrule overlay
	set boxes(dot) $out
	return $out
}

# Changes of the text: the note is dirty and its styles are drawn again, keeping the cursor and the view.
proc ::notesapp::modified {} {
	variable page
	variable rendering
	variable state
	if {$rendering} return
	if {![$page edit modified]} return
	$page edit modified 0
	set state(dirty) 1
	restyle
}

# Undo is kept here, not in the text widget: every restyle re-renders the whole body, which the widget's own undo
# cannot follow. A burst of typing (no pause of 0.8 s) is one step. Undo and redo put a body back with set_body.
proc ::notesapp::note_change {body} {
	variable cur_body
	variable undo_stack
	variable redo_stack
	variable last_edit
	if {$body eq $cur_body} return
	if {[clock milliseconds] - $last_edit > 800} {
		lappend undo_stack $cur_body
		if {[llength $undo_stack] > 200} { set undo_stack [lrange $undo_stack end-199 end] }
	}
	set redo_stack {}
	set cur_body $body
	set last_edit [clock milliseconds]
}

proc ::notesapp::undo {} {
	variable undo_stack
	variable redo_stack
	variable cur_body
	variable last_edit
	if {[llength $undo_stack] == 0} return
	lappend redo_stack $cur_body
	set cur_body [lindex $undo_stack end]
	set undo_stack [lrange $undo_stack 0 end-1]
	set last_edit 0
	set_body $cur_body
}

proc ::notesapp::redo {} {
	variable undo_stack
	variable redo_stack
	variable cur_body
	variable last_edit
	if {[llength $redo_stack] == 0} return
	lappend undo_stack $cur_body
	set cur_body [lindex $redo_stack end]
	set redo_stack [lrange $redo_stack 0 end-1]
	set last_edit 0
	set_body $cur_body
}

# Puts BODY in the widget (undo, redo): the note is dirty, the text is styled again.
proc ::notesapp::set_body {body} {
	variable page
	variable rendering
	variable state
	set rendering 1
	$page delete 1.0 end
	render $body $state(folder)
	set rendering 0
	$page edit modified 0
	set state(dirty) 1
	find_marks
	paint
}

proc ::notesapp::restyle {} {
	variable page
	variable rendering
	variable state
	set ins [$page index insert]
	set view [$page yview]
	set body [body_text]
	note_change $body
	set rendering 1
	$page delete 1.0 end
	render $body $state(folder)
	set rendering 0
	$page edit modified 0
	$page mark set insert $ins
	$page yview moveto [lindex $view 0]
	find_marks
}

# A click on a checkbox's box toggles it. The box is hit-tested against the line's real geometry: the display line
# that holds the box (dlineinfo of the line's first index) and the 30 px the box and its gap take at the left.
proc ::notesapp::clicked {x y} {
	variable page
	variable state
	set state(searchfocus) 0
	set idx [$page index @$x,$y]
	if {[link_click $idx]} return
	set ln [lindex [split $idx .] 0]
	set body [body_text]
	set entries [notes::md::lines $body]
	# the meta frame is widget line 2 (no body line); body lines after the title are one line lower
	if {$ln == 2} return
	set e [lindex $entries [expr {($ln > 2 ? $ln - 1 : $ln) - 1}]]
	if {[lindex $e 0] ne "box"} return
	set info [$page dlineinfo "$ln.0"]
	if {$info eq ""} return
	lassign $info lx ly lw lh lb
	if {$x < $lx || $x >= $lx + 30 || $y < $ly || $y >= $ly + $lh} return
	# the box's image takes the line's first index, so the raw "[" (its offset in the line's text, marker elided and
	# still counted) is one index on from the offset
	set raw [lindex $e end]
	regexp -indices {\[( |x|X)\]} $raw m
	set at "$ln.[expr {[lindex $m 0] + 1}]"
	set new [expr {[lindex $e 1] ? { } : {x}}]
	$page delete $at "$at + 3 chars"
	$page insert $at "\[$new\]"
	set state(dirty) 1
	restyle
}

# A click (press and release on the same character, nothing selected) on an http(s) link opens it with xdg-open.
proc ::notesapp::link_click {idx} {
	variable page
	variable hrefs
	variable press_at
	if {$press_at ne $idx || [llength [$page tag ranges sel]] > 0} { return 0 }
	foreach t [$page tag names $idx] {
		if {[info exists hrefs($t)] && [regexp -nocase {^https?://\S+$} $hrefs($t)]} {
			open_url $hrefs($t)
			return 1
		}
	}
	return 0
}

proc ::notesapp::open_url {url} {
	if {[catch {exec xdg-open $url </dev/null >/dev/null 2>/dev/null &} err]} {
		puts stderr "ribbon-notes: could not open $url: $err"
	}
}

# The bar above a selection, with Bold, Italic, Code and Link.
proc ::notesapp::format_update {} {
	variable page
	variable page_bar
	if {![winfo exists $page_bar]} return
	if {[llength [$page tag ranges sel]] == 0} {
		place forget $page_bar
		catch {destroy [style_menu_path]}
		return
	}
	set bb [$page bbox sel.first]
	if {$bb eq ""} { place forget $page_bar; return }
	lassign $bb bx by bw bh
	# the bar sits 2 px in from the selection's start and 46 px above its line (board: bar at 462,168)
	variable bar_xy
	set bar_xy [list [expr {$bx + 2}] [expr {$by - 46}]]
	place $page_bar -x [lindex $bar_xy 0] -y [lindex $bar_xy 1] -in $page
	raise $page_bar
	bar_style_update
}

# The Text button shows the style of the line the selection starts on.
proc ::notesapp::bar_style_update {} {
	variable page
	variable page_bar
	variable c
	variable style_rows
	$page_bar.text.l configure -text [dict get $style_rows [style_kind]]
	# Bold and Italic are pressed while the selection is wrapped in their markers
	set sel [$page get sel.first sel.last]
	set bold [regexp {^\*\*.+\*\*$} $sel]
	set italic [expr {!$bold && [regexp {^\*[^*].*\*$} $sel]}]
	$page_bar.bold configure -background [expr {$bold ? $c(pill) : $c(field)}]
	$page_bar.bold.i configure -background [expr {$bold ? $c(pill) : $c(field)}]
	$page_bar.italic configure -background [expr {$italic ? $c(pill) : $c(field)}]
	$page_bar.italic.i configure -background [expr {$italic ? $c(pill) : $c(field)}]
}

# The Text style menu (board Notes-R5-1-Style, design/tools/gen_editor_r4.py): Text, Heading 1-3 and Quote under the
# format bar, its left edge on the bar's and 4 below it; it closes on a choice, on the Text button again, or when the
# selection goes. The card is the Terminal tab menu's: 200 wide, §field, radius 10 with a 1 px §border ring, 6 px
# padding, 34 px rows (the style's icon at 16, 15 px §muted, §fg on the row under the pointer; the label at 41 in
# 13/500), the row under the pointer raised in §pill (radius 8), the line's own style checked at the right in the accent.
# It is a sibling of the format bar (a child of the window), so it can be placed over the page as the bar is; each row
# is its own canvas ($m.text, $m.h1 ...) on the card's canvas.
namespace eval ::notesapp {
	variable style_rows {text Text h1 "Heading 1" h2 "Heading 2" h3 "Heading 3" quote Quote}
	variable style_icons
	array set style_icons {
		text  {M4 7V4h16v3 M9 20h6 M12 4v16}
		h1    {M4 12h8 M4 18V6 M12 18V6 M17 12l3-2v8}
		h2    {M4 12h8 M4 18V6 M12 18V6 M21 18h-4c0-4 4-3 4-6 0-1.5-2-2.5-4-1}
		h3    {M4 12h8 M4 18V6 M12 18V6 M17.5 10.5c1.7-1 3.5 0 3.5 1.5a2 2 0 0 1-2 2 M17 17.5c2 1.5 4 .3 4-1.5a2 2 0 0 0-2-2}
		quote {M17 6H3 M21 12H8 M21 18H8 M3 12v6}
		check {M5 12l5 5 9-10}
	}
}

proc ::notesapp::style_menu_path {} {
	variable page_bar
	return [winfo parent $page_bar].fmtmenu
}

# The style of the line the selection starts on (else the insert point's): text, h1, h2, h3 or quote.
proc ::notesapp::style_kind {} {
	variable page
	set at [expr {[llength [$page tag ranges sel]] ? "sel.first" : "insert"}]
	set ln [lindex [split [$page index $at] .] 0]
	set line [$page get "$ln.0" "$ln.end"]
	switch -regexp -- $line {
		{^### } { return h3 }
		{^## } { return h2 }
		{^# } { return h1 }
		{^> } { return quote }
	}
	return text
}

proc ::notesapp::style_menu {} {
	variable page
	variable c
	variable bar_xy
	variable style_rows
	set m [style_menu_path]
	if {[winfo exists $m]} { destroy $m; return }
	set W 200
	set H [expr {12 + 34 * [llength $style_rows] / 2}]
	::canvas $m -width $W -height $H -background $c(bar) -borderwidth 0 -highlightthickness 0
	set img [image create photo -width $W -height $H]
	raster::box $img 0 0 $W $H -fill [ui::col $c(field)] -radius 10 -ring [list [ui::col $c(border)] 1]
	$m create image 0 0 -image $img -anchor nw
	bind $m <Destroy> [list catch [list image delete $img]]
	set cur [style_kind]
	set y 6
	foreach {kind label} $style_rows {
		::canvas $m.$kind -width [expr {$W - 12}] -height 34 -background $c(field) -borderwidth 0 -highlightthickness 0
		place $m.$kind -x 6 -y $y
		style_row $m.$kind $kind $label [expr {$kind eq $cur}] 0
		bind $m.$kind <Enter> [list ::notesapp::style_row $m.$kind $kind $label [expr {$kind eq $cur}] 1]
		bind $m.$kind <Leave> [list ::notesapp::style_row $m.$kind $kind $label [expr {$kind eq $cur}] 0]
		bind $m.$kind <Button-1> [list ::notesapp::style_set $kind]
		incr y 34
	}
	# under the bar; a line at the page's foot has it above the bar instead, so every row stays on the page
	set y [expr {[lindex $bar_xy 1] + 44}]
	if {$y + $H > [winfo height $page]} { set y [expr {max(0, [lindex $bar_xy 1] - 4 - $H)}] }
	place $m -x [lindex $bar_xy 0] -y $y -in $page
	raise $m
}

# One row of the style menu: ON is the line's own style (checked), HOVER the row under the pointer (raised).
proc ::notesapp::style_row {w kind label on hover} {
	variable c
	variable style_icons
	$w delete all
	set rw [winfo reqwidth $w]
	set fg [ui::col $c(fg)]
	set bg [expr {$hover ? $c(pill) : $c(field)}]
	set img [image create photo -width $rw -height 34]
	$img put [ui::col $c(field)] -to 0 0 $rw 34
	if {$hover} { raster::box $img 0 0 $rw 34 -fill [ui::col $c(pill)] -radius 8 }
	$w create image 0 0 -image $img -anchor nw
	bind $w <Destroy> [list catch [list image delete $img]]
	set ic [raster::icon $style_icons($kind) 15 2 [ui::col [expr {$hover ? $c(fg) : $c(muted)}]]]
	$w create image 10 [expr {round(9.5)}] -image $ic -anchor nw
	set saved $::ui::cv
	set ::ui::cv $w
	ui::text 35 [ui::lh 0 i13m 34] $label i13m $c(fg)
	set ::ui::cv $saved
	if {$on} {
		$w create image [expr {$rw - 10 - 14}] 10 -image [raster::icon $style_icons(check) 14 2.4 [ui::col $c(accent)]] -anchor nw
	}
}

# Sets the style of the lines under the selection (or the insert point's line): the heading or quote marker is
# replaced; the line's text is kept.
proc ::notesapp::style_set {kind} {
	variable page
	variable page_bar
	variable state
	if {[winfo exists [style_menu_path]]} { destroy [style_menu_path] }
	set prefix [dict get {text {} h1 {# } h2 {## } h3 {### } quote {> }} $kind]
	if {[llength [$page tag ranges sel]] > 0} {
		set first [lindex [split [$page index sel.first] .] 0]
		set last [lindex [split [$page index sel.last] .] 0]
	} else {
		set first [set last [lindex [split [$page index insert] .] 0]]
	}
	for {set ln $first} {$ln <= $last} {incr ln} {
		set line [$page get "$ln.0" "$ln.end"]
		if {![regexp {^(#{1,6} |> )?(.*)$} $line -> old text]} continue
		$page delete "$ln.0" "$ln.end"
		$page insert "$ln.0" "$prefix$text"
	}
	set state(dirty) 1
	restyle
	format_update
}

# The header's ⋯ menu (boards Notes-R5-2-More, -3-More-Empty, design/tools/gen_notes_more.py): New note (Ctrl N),
# New folder, Import… and, with a note open, a rule and Move to Trash. The Text style menu's card, 220 wide,
# right-aligned under the ⋯ button (the header's right edge less 18) and 4 below it; the label at 41, Ctrl N in 12 px
# §muted 16 from the card's right. A child of the window placed over the canvas and the page; it holds the pointer
# (a grab), so a press outside it, Escape or the ⋯ button again closes it, and a row's press closes it and runs it.
namespace eval ::notesapp {
	variable more_rows_note {new "New note" {Ctrl N} folder "New folder" {} import "Import…" {} - - - trash "Move to Trash" {}}
	variable more_rows_empty {new "New note" {Ctrl N} folder "New folder" {} import "Import…" {}}
	variable more_icons
	array set more_icons {
		new    {M12 20h9 M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4z}
		folder {M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z M12 11v6 M9 14h6}
		import {M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z}
		trash  {M3 6h18 M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6 M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2}
	}
	variable more_cmds
	array set more_cmds {new new_note folder new_folder import import_notes trash trash_open}
	# the ⋯ button's three dots as the boards draw them (r 1 circles; tree.tcl's "more" is h.01 strokes, near nothing)
	variable paths
	set paths(dots) {M12 13a1 1 0 1 0 0-2a1 1 0 1 0 0 2z M19 13a1 1 0 1 0 0-2a1 1 0 1 0 0 2z M5 13a1 1 0 1 0 0-2a1 1 0 1 0 0 2z}
}

proc ::notesapp::more_menu_path {} {
	return $::notesapp::win.moremenu
}

# The rows the menu has now: a note open, or the empty folder's.
proc ::notesapp::more_rows {} {
	variable state
	return [expr {$state(note) eq "" ? $::notesapp::more_rows_empty : $::notesapp::more_rows_note}]
}

proc ::notesapp::more_close {} {
	set m [more_menu_path]
	if {[winfo exists $m]} { destroy $m }
}

proc ::notesapp::more_menu {} {
	variable c
	set m [more_menu_path]
	if {[winfo exists $m]} { destroy $m; return }
	set rows [more_rows]
	set W 220
	set H 12
	foreach {kind label key} $rows { incr H [expr {$kind eq "-" ? 11 : 34}] }
	::canvas $m -width $W -height $H -background $c(bar) -borderwidth 0 -highlightthickness 0 -takefocus 1
	set img [image create photo -width $W -height $H]
	raster::box $img 0 0 $W $H -fill [ui::col $c(field)] -radius 10 -ring [list [ui::col $c(border)] 1]
	$m create image 0 0 -image $img -anchor nw
	bind $m <Destroy> [list catch [list image delete $img]]
	set y 6
	foreach {kind label key} $rows {
		if {$kind eq "-"} {
			$img put [ui::col $c(border)] -to 10 [expr {$y + 5}] [expr {$W - 10}] [expr {$y + 6}]
			incr y 11
			continue
		}
		::canvas $m.$kind -width [expr {$W - 12}] -height 34 -background $c(field) -borderwidth 0 -highlightthickness 0
		place $m.$kind -x 6 -y $y
		more_row $m.$kind $kind $label $key 0
		bind $m.$kind <Enter> [list ::notesapp::more_row $m.$kind $kind $label $key 1]
		bind $m.$kind <Leave> [list ::notesapp::more_row $m.$kind $kind $label $key 0]
		bind $m.$kind <ButtonPress-1> [list ::notesapp::more_choose $kind]
		incr y 34
	}
	place $m -in $::notesapp::win -x [expr {$::notesapp::W - 18 - $W}] -y 60
	raise $m
	# a press outside the card (the grab hands it to the card, at a point off it) or Escape closes it
	bind $m <ButtonPress-1> {
		if {"%W" eq [::notesapp::more_menu_path] && (%x < 0 || %y < 0 || %x >= [winfo width %W] || %y >= [winfo height %W])} {
			::notesapp::more_close
		}
	}
	bind $m <Escape> ::notesapp::more_close
	update idletasks
	catch {grab $m}
	focus $m
}

# One row of the ⋯ menu: the icon at 10 (15 px, §muted; §fg under the pointer), the label at 35 in 13/500, the key at
# the right in 12 px §muted; HOVER raises the row in §pill.
proc ::notesapp::more_row {w kind label key hover} {
	variable c
	variable more_icons
	$w delete all
	set rw [winfo reqwidth $w]
	set img [image create photo -width $rw -height 34]
	$img put [ui::col $c(field)] -to 0 0 $rw 34
	if {$hover} { raster::box $img 0 0 $rw 34 -fill [ui::col $c(pill)] -radius 8 }
	$w create image 0 0 -image $img -anchor nw
	bind $w <Destroy> [list catch [list image delete $img]]
	set ic [raster::icon $more_icons($kind) 15 2 [ui::col [expr {$hover ? $c(fg) : $c(muted)}]]]
	$w create image 10 10 -image $ic -anchor nw
	set saved $::ui::cv
	set ::ui::cv $w
	ui::text 35 [ui::lh 0 i13m 34] $label i13m $c(fg)
	if {$key ne ""} { ui::text [expr {$rw - 10}] [ui::lh 0 i12m 34] $key i12m $c(muted) e }
	set ::ui::cv $saved
}

# A row's press: the menu goes, then its action runs.
proc ::notesapp::more_choose {kind} {
	variable more_cmds
	more_close
	$more_cmds($kind)
}

# Move to Trash (the ⋯ menu): the open note goes to the store's trash (Trash at the bar's foot lists it, with
# Restore); the note that followed it in the folder opens (else the one before it, else the empty folder).
proc ::notesapp::trash_open {} {
	variable state
	if {$state(note) eq ""} return
	# the save first: it can rename the note after its title
	save
	set folder $state(folder)
	set name $state(note)
	set before [lmap e [visible_notes $folder] {dict get $e name}]
	set at [lsearch -exact $before $name]
	notes::store::trash_note $folder $name
	notes::index::refresh
	set after [lmap e [visible_notes $folder] {dict get $e name}]
	set state(dirty) 0
	set state(note) ""
	if {[llength $after] == 0} {
		open_folder $folder
	} else {
		open_note $folder [lindex $after [expr {min(max($at, 0), [llength $after] - 1)}]]
	}
}

proc ::notesapp::format_wrap {open close} {
	variable page
	variable state
	if {[llength [$page tag ranges sel]] == 0} return
	set a [$page index sel.first]
	set b [$page index sel.last]
	$page insert $b $close
	$page insert $a $open
	set state(dirty) 1
	restyle
	format_update
}

proc ::notesapp::format_bold {} { format_wrap ** ** }
proc ::notesapp::format_italic {} { format_wrap * * }
proc ::notesapp::format_strike {} { format_wrap ~~ ~~ }
proc ::notesapp::format_code {} { format_wrap ` ` }
# Link: the selection becomes the link's text; with nothing selected an empty link is put at the insert point, with
# the insert point between its brackets.
proc ::notesapp::format_link {} {
	variable page
	variable state
	if {[llength [$page tag ranges sel]] > 0} { format_wrap \[ \](https://); return }
	set at [$page index insert]
	$page insert $at {[](https://)}
	set state(dirty) 1
	restyle
	$page mark set insert "$at + 1 chars"
	focus $page
}

# Marks the matches of the search in the note; the current one is stronger.
proc ::notesapp::find_marks {} {
	variable page
	variable state
	$page tag remove hit 1.0 end
	$page tag remove cur 1.0 end
	set q $state(query)
	set state(hits) 0
	if {$q eq ""} return
	set i 1.0
	set n 0
	while {1} {
		set i [$page search -nocase -count len -- $q $i end]
		if {$i eq ""} break
		$page tag add hit $i "$i + $len chars"
		set i "$i + $len chars"
		incr n
	}
	set state(hits) $n
	if {$n > 0} { cur_mark }
}

proc ::notesapp::cur_mark {} {
	variable page
	variable state
	$page tag remove cur 1.0 end
	set ranges [$page tag ranges hit]
	if {[llength $ranges] == 0} return
	if {$state(current) >= [expr {[llength $ranges] / 2}]} { set state(current) 0 }
	set a [lindex $ranges [expr {2 * $state(current)}]]
	set b [lindex $ranges [expr {2 * $state(current) + 1}]]
	$page tag add cur $a $b
	$page see $a
}

# The next (dir 1) or previous (-1) match.
proc ::notesapp::find_step {dir} {
	variable state
	set n $state(hits)
	if {$n == 0} return
	set state(current) [expr {(($state(current) + $dir) % $n + $n) % $n}]
	cur_mark
	paint
}

# The note's header: the crumbs, the meta line, and the actions (or the find count and steps); with no note open,
# the empty folder block (Notes-R4-A3-Empty).
proc ::notesapp::page_paint {} {
	variable state
	variable c
	variable page
	if {$state(view) eq "trash"} {
		place forget $page
		trash_paint
		return
	}
	if {$state(note) eq ""} {
		place forget $page
		empty_paint
		return
	}
	set folder $state(folder)
	set name $state(note)
	page_place
	# the header's actions keep their distance from the window's right edge (the board's 1240 puts them at 1039..1222)
	set R $::notesapp::W
	set x [page_x]
	set crumbs [expr {$folder eq "" ? {} : [split $folder /]}]
	lappend crumbs $name
	set n [llength $crumbs]
	set i 0
	foreach part $crumbs {
		incr i
		set last [expr {$i == $n}]
		set font [expr {$last ? "i13m" : "i13"}]
		ui::text $x 40 $part $font [expr {$last ? $c(fg) : $c(muted)}]
		set x [expr {$x + [tw $font $part] + 8}]
		if {!$last} {
			icon right 12 $c(muted) $x 40 2
			set x [expr {$x + 20}]
		}
	}
	if {$state(query) ne ""} {
		set cur [expr {$state(hits) == 0 ? 0 : $state(current) + 1}]
		ui::text [expr {$R - 182}] 40 "$cur of $state(hits)" i13 $c(muted) e
		ui::hit [expr {$R - 167}] 26 16 28 {notesapp::find_step -1}
		icon up 16 $c(muted) [expr {$R - 167}] 32 2
		ui::hit [expr {$R - 131}] 26 16 28 {notesapp::find_step 1}
		icon down 16 $c(muted) [expr {$R - 131}] 32 2
	} else {
		icon checksq 16 $c(muted) [expr {$R - 193}] 32 1.9
		ui::hit [expr {$R - 201}] 24 32 32 {notesapp::insert_checkbox}
		icon image 16 $c(muted) [expr {$R - 159}] 32 1.9
		ui::hit [expr {$R - 175}] 24 32 32 {notesapp::insert_image}
		icon link 16 $c(muted) [expr {$R - 126}] 32 1.9
		ui::hit [expr {$R - 142}] 24 32 32 {notesapp::format_link}
	}
	ui::box [expr {$R - 93}] 26 1 28 -fill $c(border)
	icon dots 16 $c(muted) [expr {$R - 42}] 32 1.9
	ui::hit [expr {$R - 50}] 24 32 32 {notesapp::more_menu}
	set pinned [note_pinned]
	if {$pinned} { ui::box [expr {$R - 84}] 24 32 32 -fill $c(field) -radius 8 }
	icon pin 16 [expr {$pinned ? $c(fg) : $c(muted)}] [expr {$R - 76}] 32 1.9
	ui::hit [expr {$R - 84}] 24 32 32 {notesapp::toggle_pin}
}

proc ::notesapp::note_pinned {} {
	variable state
	set p [notes::md::parse [notes::store::read_note $state(folder) $state(note)]]
	return [dict get $p pinned]
}

# The trash: each trashed note with its folder, and Restore.
proc ::notesapp::trash_paint {} {
	variable c
	variable MEASE
	set x [page_x]
	ui::text $x 40 "Trash" sg22 $c(fg)
	set rows [notes::store::trashed]
	if {[llength $rows] == 0} {
		ui::text $x 110 "Trash is empty" i13 $c(muted)
		return
	}
	set y 110
	foreach r $rows {
		lassign $r folder name
		ui::box $x $y $MEASE 52 -fill $c(field) -radius 10
		ui::text [expr {$x + 20}] [expr {$y + 9}] $name i13m $c(fg)
		ui::text [expr {$x + 20}] [expr {$y + 28}] "from [expr {$folder eq "" ? "Notes" : $folder}]" i12 $c(muted)
		set bw [expr {[tw i13s "Restore"] + 28}]
		set bx [expr {$x + $MEASE - 16 - $bw}]
		ui::box $bx [expr {$y + 9}] $bw 34 -fill $c(pill) -radius 9
		ui::text [expr {$bx + 14}] [expr {$y + 17}] "Restore" i13s $c(fg)
		ui::hit $bx [expr {$y + 9}] $bw 34 [list notesapp::restore_note $folder $name]
		incr y 62
	}
}

proc ::notesapp::restore_note {folder name} {
	notes::store::restore_note $folder $name
	notes::index::refresh
	paint
}

# The empty folder (Notes-R4-A3-Empty): its name with the sort and more icons, the tile, the message, and the
# Import and New note buttons (38 px, 14 px text, the icon after the label).
proc ::notesapp::empty_paint {} {
	variable state
	variable c
	set folder $state(folder)
	set title [expr {$folder eq "" ? "Notes" : [file tail $folder]}]
	# the head's icons keep to the right edge; the block stays in the middle of the room right of the tree
	set R $::notesapp::W
	set cx [expr {$::notesapp::BW + ($R - $::notesapp::BW) / 2}]
	set dy [expr {($::notesapp::H - 780) / 2}]
	ui::text 328 26 $title sg22 $c(fg) w
	icon sort 16 $c(muted) [expr {$R - 78}] 32 1.9
	icon dots 16 $c(muted) [expr {$R - 42}] 32 1.9
	ui::hit [expr {$R - 50}] 24 32 32 {notesapp::more_menu}
	ui::box [expr {$cx - 32}] [expr {324 + $dy}] 64 64 -fill $c(field) -radius 18 -ring [list $c(border) 1]
	icon file 28 $c(fg) [expr {$cx - 14}] [expr {342 + $dy}] 1.6
	set msg "$title is empty"
	set w [tw sg22 $msg]
	ui::text [expr {$cx - $w / 2}] [expr {406 + $dy}] $msg sg22 $c(fg)
	# Import (a field button) and New note (the accent button): padding 18, 8 to the 15 px icon
	set iw [expr {[tw i14 "Import"] + 8 + 15 + 36}]
	set nw [expr {[tw i14s "New note"] + 8 + 15 + 36}]
	set x0 [expr {$cx - ($iw + 10 + $nw) / 2}]
	set by [expr {458 + $dy}]
	ui::box $x0 $by $iw 38 -fill $c(field) -radius 10
	ui::text [expr {$x0 + 18}] [expr {$by + 10}] "Import" i14 $c(fg)
	icon folder 15 $c(fg) [expr {$x0 + $iw - 33}] [expr {$by + 11}] 2
	ui::hit $x0 $by $iw 38 {notesapp::import_notes}
	set nx [expr {$x0 + $iw + 10}]
	ui::box $nx $by $nw 38 -fill $c(accent) -radius 10
	ui::text [expr {$nx + 18}] [expr {$by + 10}] "New note" i14s $c(ink)
	icon edit 15 $c(ink) [expr {$nx + $nw - 33}] [expr {$by + 11}] 2
	ui::hit $nx $by $nw 38 {notesapp::new_note}
}

# Ribbon's file chooser (appearance/chooser.tcl, boards Chooser-*): KIND open_file, save_file or choose_folder, with
# Tk's options; loaded the first time it is asked for.
proc ::notesapp::choose {kind args} {
	if {[info commands ::chooser::open_file] eq ""} {
		uplevel #0 [list source -encoding utf-8 [file join [find_dir appearance chooser.tcl] chooser.tcl]]
	}
	chooser::$kind {*}$args
}

# Import (the empty folder's Import button, Notes-R4-A3-Empty): Markdown (or plain text) files chosen in Ribbon's file
# chooser become notes in the open folder (import_files).
proc ::notesapp::import_notes {} {
	variable state
	set files [choose open_file -title "Import notes" -multiple 1 -filetypes {{Markdown {.md .markdown .txt}}}]
	if {![llength $files]} return
	import_files $files $state(folder)
	notes::index::refresh
	if {$state(folder) ne ""} { variable open; if {$state(folder) ni $open} { toggle_open $state(folder) } }
	paint
}

# Each file becomes a note in FOLDER; returns the names given. Nothing already there is replaced, and nothing is lost:
#  - the name is the front matter's "title:" when the file has one (the front matter is kept as it is, so "pinned:"
#    and any other keys still hold), else the file's name; a "/" in it becomes "-";
#  - a name that is taken (in the folder, or by an earlier file of the same import) gets a number: "Plan 2";
#  - a picture the note links by a relative path (![alt](pic.png), ![alt](img/a b.png), ![alt](<a b.png> "title")) is
#    copied next to the note, as Notes keeps pictures, and the link is rewritten to its name there; a different file
#    already there under that name gives the copy a number ("pic 2.png"); the same file is not copied twice. Links to
#    URLs, absolute paths and pictures that are not there are left as they are;
#  - line ends become LF, as the store writes them.
proc ::notesapp::import_files {files folder} {
	set dir [notes::store::dir_of $folder]
	file mkdir $dir
	set names {}
	foreach src $files {
		if {[catch {
			set fh [::open $src rb]
			set text [encoding convertfrom utf-8 [read $fh]]
			close $fh
		}]} continue
		set text [string map {\r\n \n} $text]
		set p [notes::md::parse $text]
		set name [file rootname [file tail $src]]
		foreach l [dict get $p fm] {
			if {[regexp {^title:\s*(.*?)\s*$} $l -> t]} {
				regexp {^"(.*)"$} $t -> t
				regexp {^'(.*)'$} $t -> t
				if {[string trim $t] ne ""} { set name [string trim $t] }
			}
		}
		# made a name as a retitled note's is (rename_by_title): a hidden file is no note, and a name past the file
		# system's limit would stop the import
		set name [import_name $name]
		if {$name eq ""} { set name [import_name [file rootname [file tail $src]]] }
		if {$name eq ""} { set name Untitled }
		set base $name
		set i 1
		while {[file exists [notes::store::note_path $folder $name]] || $name in $names} { set name "$base [incr i]" }
		set body [import_pictures [dict get $p body] [file dirname [file normalize $src]] $dir]
		# (one file that cannot be written does not stop the others)
		if {[catch {notes::store::write_note $folder $name [notes::md::build [dict get $p pinned] [dict get $p has_fm] [dict get $p fm] $body]} err]} {
			puts stderr "ribbon-notes: could not import $src: $err"
			continue
		}
		lappend names $name
	}
	return $names
}

# TEXT made a note's name as rename_by_title makes a title one: "/", "\\" and control characters become "-", no leading
# dots or spaces, at most 120 characters ("" when nothing is left).
proc ::notesapp::import_name {text} {
	set name [string trim [regsub -all {[/\\[:cntrl:]]} $text -]]
	string trim [string range [string trimleft $name ". "] 0 119]
}

# BODY with its relatively-linked pictures copied from FROM into TO and the links pointing at the copies (outside code
# fences and inline code, which show their text as it is).
proc ::notesapp::import_pictures {body from to} {
	set out {}
	set fence 0
	foreach line [split $body \n] {
		if {[regexp {^\s*```} $line]} { set fence [expr {!$fence}] }
		if {!$fence && [string first "!\[" $line] >= 0} {
			set new ""
			set re {!\[([^\]]*)\]\((<[^>]*>|[^)\s]+)(\s+"[^"]*")?\)}
			set code 0
			while {[regexp -indices $re $line all alt path title]} {
				lassign $all s e
				set before [string range $line 0 [expr {$s - 1}]]
				# a backtick before it that is not closed: the link is inside inline code
				set code [expr {($code + [regexp -all {`} $before]) % 2}]
				set link [string range $line $s $e]
				if {!$code} {
					set p [string range $line {*}$path]
					set copied [import_picture [string trim $p <>] $from $to]
					if {$copied ne ""} {
						set tl [expr {[lindex $title 0] >= 0 ? [string range $line {*}$title] : ""}]
						set ref [expr {[string match "* *" $copied] ? "<$copied>" : $copied}]
						set link "!\[[string range $line {*}$alt]\]($ref$tl)"
					}
				}
				append new $before $link
				set line [string range $line [expr {$e + 1}] end]
			}
			set line $new$line
		}
		lappend out $line
	}
	join $out \n
}

# The picture PATH (relative to FROM) copied into TO; returns its name there, or "" when PATH is not a relative path
# to a picture that is there.
proc ::notesapp::import_picture {path from to} {
	if {$path eq "" || [regexp {^[a-zA-Z][a-zA-Z0-9+.-]*:} $path] || [string match /* $path] || [string match ~* $path]} { return "" }
	# %20 and the like, as a Markdown link may write them (the escapes are UTF-8 bytes)
	set dec $path
	if {[regexp {%[0-9A-Fa-f]{2}} $path]} {
		set bytes [encoding convertto utf-8 $path]
		set dec ""
		while {[regexp -indices {%([0-9A-Fa-f]{2})} $bytes all hex]} {
			append dec [string range $bytes 0 [expr {[lindex $all 0] - 1}]] [binary format H2 [string range $bytes {*}$hex]]
			set bytes [string range $bytes [expr {[lindex $all 1] + 1}] end]
		}
		set dec [encoding convertfrom utf-8 $dec$bytes]
	}
	set src [file normalize [file join $from $dec]]
	# only a picture: the file comes from elsewhere, and a link may name any file the user can read (../.ssh/id_rsa),
	# or a .png that is a link to one
	set real $src
	for {set n 0} {$n < 32 && ![catch {file type $real} ty] && $ty eq "link"} {incr n} {
		set real [file normalize [file join [file dirname $real] [file readlink $real]]]
	}
	if {![file isfile $real]} { return "" }
	foreach f [list $src $real] {
		if {[string tolower [file extension $f]] ni {.png .gif .jpg .jpeg .webp .avif .bmp .ppm .pgm .svg}} { return "" }
	}
	set tail [file tail $src]
	set stem [file rootname $tail]
	set ext [file extension $tail]
	set name $tail
	set i 1
	while {[file exists [file join $to $name]]} {
		if {[same_file [file join $to $name] $src]} { return $name }
		set name "$stem [incr i]$ext"
	}
	file copy -- $src [file join $to $name]
	return $name
}

# The two files have the same bytes.
proc ::notesapp::same_file {a b} {
	if {[file size $a] != [file size $b]} { return 0 }
	set fa [::open $a rb]; set fb [::open $b rb]
	set same [expr {[read $fa] eq [read $fb]}]
	::close $fa; ::close $fb
	return $same
}

# Inserts an empty checkbox on the line the insert point is on.
proc ::notesapp::insert_checkbox {} {
	variable page
	variable state
	set ln [lindex [split [$page index insert] .] 0]
	$page insert "$ln.0" "- \[ \] "
	set state(dirty) 1
	restyle
}

# Inserts a picture from a file: the Image button asks for the file, then insert_image_file copies it next to the note.
proc ::notesapp::insert_image {} {
	set src [choose open_file -title "Insert picture" -filetypes [picture_types]]
	if {$src eq ""} return
	insert_image_file $src
}

# Copies the picture SRC next to the note and puts its Markdown line at the insert point's line.
proc ::notesapp::insert_image_file {src} {
	variable state
	set name [file tail $src]
	set dst [file join [notes::store::dir_of $state(folder)] $name]
	if {[file normalize $src] ne [file normalize $dst]} { file copy -force $src $dst }
	insert_picture_line $name
}

# The Markdown line of a picture (its file is in the note's folder), put at the start of the insert point's line.
proc ::notesapp::insert_picture_line {name} {
	variable page
	variable state
	set ln [lindex [split [$page index insert] .] 0]
	$page insert "$ln.0" "!\[[file rootname $name]\]($name)\n"
	set state(dirty) 1
	restyle
}

# Paste: a picture on the clipboard (image/png) becomes a PNG beside the note with its picture line; anything else
# is pasted as text. Tk's clipboard get -type returns the bytes exactly, and it errors when no owner has that type.
proc ::notesapp::paste {} {
	variable page
	variable state
	if {[catch {clipboard get -type image/png} png] || $png eq ""} {
		tk_textPaste $page
		return
	}
	set dir [notes::store::dir_of $state(folder)]
	set n 1
	set name "pasted-[clock format [clock seconds] -format %Y%m%d-%H%M%S].png"
	while {[file exists [file join $dir $name]]} { set name "pasted-[clock format [clock seconds] -format %Y%m%d-%H%M%S]-[incr n].png" }
	set fh [open [file join $dir $name] wb]
	fconfigure $fh -translation binary
	puts -nonewline $fh $png
	close $fh
	insert_picture_line $name
}
