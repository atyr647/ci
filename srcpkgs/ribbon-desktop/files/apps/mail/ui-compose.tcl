# ui-compose.tcl - writing (U41): the inline reply under the thread (Mail-A3-Reply: Reply, Reply all or Forward
# with the people it goes to, the text, the attachments, the format buttons, Attach, Insert picture, "Draft
# saved", Discard and Send) and the new message window (Mail-A7-Compose: From, To, Cc, Subject over the same
# composer; Mail-A8-Attach: Attach opens the Ribbon file chooser with Attach as its word). The text is plain: Bold,
# Italic, List and Link write the plain-text marks (*bold*, _italic_, "- ", <link>). The draft is saved to the
# account's Drafts 1.5 s after the last change and when the composer closes; Send hands the message to the
# account's SMTP (mail::sync::send), marks the message answered and removes the draft.

namespace eval ::mailapp {
	variable draft ""            ;# the inline reply's draft (compose.tcl)
	variable rtext .w.reply      ;# its text
	variable rbox {}             ;# where the text sits: x y w h
	variable saved 0             ;# "Draft saved" shows
	variable autosave ""
	variable sendmsg ""          ;# the last send error, shown in place of "Draft saved"
	# the new message window
	variable cwin .compose
	variable cdraft ""
	variable cui
	array set cui {}
}

proc ::mailapp::reply_text_widget {w {send ::mailapp::send_now}} {
	variable c
	if {[winfo exists $w]} return
	text $w -font ui_i15 -wrap word -borderwidth 0 -highlightthickness 0 -padx 0 -pady 0 \
		-background $c(field) -foreground $c(fg) -insertbackground $c(accent) -insertwidth 2 \
		-selectbackground $c(hit) -selectforeground $c(fg) -spacing1 3 -spacing2 6.75 -spacing3 13 -undo 1
	bind $w <<Modified>> [list ::mailapp::text_changed $w]
	bind $w <Control-Return> "$send; break"
}

proc ::mailapp::text_changed {w} {
	variable autosave
	if {![$w edit modified]} return
	$w edit modified 0
	set ::mailapp::saved 0
	if {$autosave ne ""} { after cancel $autosave }
	set autosave [after 1500 ::mailapp::autosave_now]
	after idle ::mailapp::refit
}

proc ::mailapp::refit {} {
	variable state
	if {$state(reply)} { paint }
	if {[winfo exists $::mailapp::cwin]} { compose_paint }
}

# ---- the inline reply -----------------------------------------------------------------------------------------
proc ::mailapp::reply_open {mode} {
	variable conv
	variable state
	variable draft
	variable rtext
	variable pscroll
	if {$conv eq ""} return
	# a reply already open keeps its text, its files and its draft: only who it goes to changes
	if {$state(reply) && $draft ne ""} {
		if {[dict get $draft mode] ne $mode} { reply_mode $mode }
		focus $rtext
		return
	}
	set last [dict get $conv last]
	set draft [mail::compose::reply $last [mine] $mode]
	dict set draft from [from_of [dict get $draft account]]
	reply_text_widget $rtext
	$rtext delete 1.0 end
	$rtext insert 1.0 [string trimleft [dict get $draft text] \n]
	$rtext mark set insert 1.0
	$rtext edit modified 0
	$rtext edit reset
	set state(reply) 1
	set ::mailapp::saved 0
	set ::mailapp::sendmsg ""
	paint
	set pscroll [pane_max]
	paint
	focus $rtext
}

# The From of an account: the provider's address and name, else the account's name.
proc ::mailapp::from_of {acct} {
	if {[info commands ::mail::accounts::configured] ne ""} {
		foreach {n o} [::mail::accounts::configured] {
			if {$n eq $acct && [dict exists $o -address]} {
				return [list [expr {[dict exists $o -fullname] ? [dict get $o -fullname] : ""}] [dict get $o -address]]
			}
		}
	}
	return [list "" $acct]
}

proc ::mailapp::reply_mode {{next ""}} {
	variable draft
	if {$next eq ""} { set next [dict get {reply all all forward forward reply} [dict get $draft mode]] }
	set keep [$::mailapp::rtext get 1.0 end-1c]
	set atts [dict get $draft atts]
	set key [dict get $draft key]
	set d [mail::compose::reply [dict get $::mailapp::conv last] [mine] $next]
	dict set d from [dict get $draft from]
	dict set d key $key
	# the files attached here stay; a forward adds the message's own
	set files [lmap a $atts {expr {[dict exists $a path] ? $a : [continue]}}]
	dict set d atts [expr {$next eq "forward" ? [concat [dict get $d atts] $files] : $files}]
	set draft $d
	$::mailapp::rtext delete 1.0 end
	$::mailapp::rtext insert 1.0 [expr {$next eq "forward" ? "$keep[dict get $d text]" : [regsub {\n\n---------- Forwarded message.*$} $keep ""]}]
	paint
}

proc ::mailapp::reply_close {} {
	variable state
	if {!$state(reply)} return
	reply_save
	set state(reply) 0
	menu_close
	place forget $::mailapp::rtext
}

proc ::mailapp::reply_place {} {
	variable state
	variable rbox
	if {!$state(reply) || ![llength $rbox]} {
		if {[winfo exists $::mailapp::rtext]} { place forget $::mailapp::rtext }
		return
	}
	lassign $rbox x y w h
	if {$y < 52 || $y + $h > $::mailapp::H} { place forget $::mailapp::rtext; return }
	place $::mailapp::rtext -x $x -y $y -width $w -height $h
}

# The draft with the text the composer holds.
proc ::mailapp::reply_draft {} {
	variable draft
	dict set draft text [$::mailapp::rtext get 1.0 end-1c]
	return $draft
}

proc ::mailapp::reply_save {} {
	variable state
	variable draft
	if {!$state(reply) || $draft eq ""} return
	if {[string trim [$::mailapp::rtext get 1.0 end-1c]] eq "" && ![llength [dict get $draft atts]]} {
		# emptied: its saved copy goes too
		set draft [mail::compose::discard $draft]
		return
	}
	if {[catch {set draft [mail::compose::save_draft [reply_draft]]} err]} { puts stderr "ribbon-mail: the draft was not saved: $err"; return }
	$::mailapp::rtext edit modified 0
	set ::mailapp::saved 1
}

proc ::mailapp::autosave_now {} {
	variable state
	set ::mailapp::autosave ""
	if {$state(reply)} { reply_save; paint }
	if {[winfo exists $::mailapp::cwin]} { compose_save; compose_paint }
}

proc ::mailapp::reply_discard {} {
	variable state
	variable draft
	set draft [mail::compose::discard $draft]
	set state(reply) 0
	place forget $::mailapp::rtext
	paint
}

# How many display lines the text takes, at least two.
proc ::mailapp::text_height {w width} {
	set n 0
	set ls [split [$w get 1.0 end-1c] \n]
	foreach l $ls { incr n [llength [ui::wrap i15 $l $width]] }
	return [expr {max(2, $n) * 24.75 + 10 * max(0, [llength $ls] - 1)}]
}

proc ::mailapp::recipient_chip {x y a} {
	variable c
	set name [mail::thread::name $a]
	set w [expr {32 + [ui::measure i12m $name]}]
	ui::box $x $y $w 24 -fill $c(pill) -radius 12
	avatar $name [expr {$x + 3}] [expr {$y + 3}] 18
	ui::text [expr {$x + 24}] [expr {$y + 4.5}] $name i12m $c(fg)
	return $w
}

proc ::mailapp::att_chip {x y a script} {
	variable c
	ui::box $x $y 300 44 -fill $c(bar) -radius 10 -ring [list $c(border) 1]
	ui::box [expr {$x + 8}] [expr {$y + 7}] 30 30 -fill $c(pill) -radius 7
	icon [expr {[string match image/* [mail::compose::att_type [dict get $a name]]] ? "image" : "pdf"}] 16 $c(fg) [expr {$x + 15}] [expr {$y + 14}] 1.8
	ui::text [expr {$x + 48}] [expr {$y + 6}] [elide i13m [dict get $a name] 210] i13m $c(fg)
	ui::text [expr {$x + 48}] [expr {$y + 23}] [mail::compose::size_text [dict get $a size]] i12 $c(muted) w 0 {} 1
	iconbtn x [expr {$x + 266}] [expr {$y + 8}] 28 13 $script
}

# The composer's foot at Y (56 tall) from X to X+W; ATTACH, DISCARD and SEND are its scripts.
proc ::mailapp::composer_foot {x y w attach picture discard send saved msg} {
	variable c
	ui::box $x $y $w 1 -fill $c(border)
	set bx [expr {$x + 12}]
	foreach {ic mark} {bold * italic _ list - link <} {
		iconbtn $ic $bx [expr {$y + 13}] 30 15 [list ::mailapp::format_mark $mark]
		incr bx 32
	}
	ui::box [expr {$x + 144}] [expr {$y + 19}] 1 18 -fill $c(border)
	iconbtn clip [expr {$x + 151}] [expr {$y + 13}] 30 15 $attach $c(fg) $c(pill)
	iconbtn image [expr {$x + 183}] [expr {$y + 13}] 30 15 $picture
	set sx [expr {$x + $w - 90.2}]
	ui::box $sx [expr {$y + 11}] 80.2 34 -fill $c(accent) -radius 9
	ui::text [expr {$sx + 14}] [expr {$y + 20}] Send i13s $c(ink)
	icon send 13 $c(ink) [expr {$sx + 53.2}] [expr {$y + 21.5}] 2
	ui::hit $sx [expr {$y + 11}] 80.2 34 $send
	iconbtn trash [expr {$x + $w - 132.7}] [expr {$y + 11}] 34 15 $discard
	if {$msg ne ""} {
		ui::text [expr {$x + $w - 146}] [expr {$y + 20.5}] [elide i12 $msg 200] i12 $c(accent) e
	} elseif {$saved} {
		ui::text [expr {$x + $w - 144.2}] [expr {$y + 20.5}] "Draft saved" i12 $c(muted) e
	}
}

# The plain-text marks: around the selection (or at the caret) of the text with the focus.
proc ::mailapp::format_mark {mark} {
	set w [focus]
	if {$w eq "" || [winfo class $w] ne "Text"} { set w [expr {[winfo exists $::mailapp::cwin] ? $::mailapp::cui(text) : $::mailapp::rtext}] }
	set sel [$w tag ranges sel]
	switch -- $mark {
		- {
			$w insert "insert linestart" "- "
		}
		< {
			if {[llength $sel]} { $w insert [lindex $sel 1] > ; $w insert [lindex $sel 0] < } else { $w insert insert "<https://>"; $w mark set insert "insert -1c" }
		}
		default {
			if {[llength $sel]} { $w insert [lindex $sel 1] $mark; $w insert [lindex $sel 0] $mark } else { $w insert insert "$mark$mark"; $w mark set insert "insert -1c" }
		}
	}
	focus $w
}

proc ::mailapp::reply_paint {x y} {
	variable c
	variable draft
	variable rbox
	variable rtext
	set mode [dict get $draft mode]
	set word [dict get {reply Reply all {Reply all} forward Forward} $mode]
	set icn [dict get {reply reply all replyall forward fwd} $mode]
	set tw [text_height $rtext 524]
	set atts [dict get $draft atts]
	set ah [expr {[llength $atts] ? 14 + (([llength $atts] + 1) / 2) * 52 - 8 : 0}]
	set h [expr {52 + 16 + $tw + $ah + 14 + 56}]
	ui::box $x $y 560 $h -fill $c(field) -radius 14
	ui::ring $x $y 560 $h 14 $c(accent) 1.5
	ui::box $x [expr {$y + 51}] 560 1 -fill $c(border)
	set mw [expr {28 + [ui::measure i12m $word] + 6 + 12 + 8}]
	ui::box [expr {$x + 16}] [expr {$y + 12}] $mw 28 -fill $c(bar) -radius 7 -ring [list $c(border) 1]
	icon $icn 13 $c(fg) [expr {$x + 25}] [expr {$y + 19.5}] 2
	set ww [ui::text [expr {$x + 44}] [expr {$y + 18.5}] $word i12m $c(fg)]
	icon chev 12 $c(muted) [expr {$x + 50 + $ww}] [expr {$y + 20}] 2
	ui::hit [expr {$x + 16}] [expr {$y + 12}] $mw 28 [list ::mailapp::reply_mode_menu [expr {$x + 16}] [expr {$y + 12}]]
	set rx [expr {$x + 16 + $mw + 14}]
	set rx [expr {$rx + [ui::text $rx [expr {$y + 18.5}] to i12 $c(muted)] + 10}]
	foreach a [concat [dict get $draft to] [dict get $draft cc]] {
		if {$rx > $x + 460} break
		set rx [expr {$rx + [recipient_chip $rx [expr {$y + 14}] $a] + 8}]
	}
	set rbox [list [expr {$x + 18}] [expr {$y + 52 + 16}] 524 $tw]
	set ay [expr {$y + 52 + 16 + $tw + 14}]
	set i 0
	foreach a $atts {
		att_chip [expr {$x + 18 + ($i % 2) * 308}] [expr {$ay + ($i / 2) * 52}] $a [list ::mailapp::reply_remove $i]
		incr i
	}
	composer_foot $x [expr {$y + $h - 56}] 560 {::mailapp::attach reply 0} {::mailapp::attach reply 1} ::mailapp::reply_discard ::mailapp::send_now \
		$::mailapp::saved $::mailapp::sendmsg
	return [expr {$y + $h}]
}

proc ::mailapp::reply_remove {i} {
	variable draft
	dict set draft atts [lreplace [dict get $draft atts] $i $i]
	paint
}

# Attach (or Insert picture: PICTURE 1) through the Ribbon chooser, its word Attach.
proc ::mailapp::attach {where picture} {
	set types [expr {$picture ? {{Pictures {.png .jpg .jpeg .gif .webp}}} : {}}]
	set opts [list -parent [expr {$where eq "reply" ? $::mailapp::win : $::mailapp::cwin}] -multiple 1 -acceptlabel Attach -title Attach]
	if {$picture} { lappend opts -filetypes $types }
	set files [chooser::open_file {*}$opts]
	attach_files $where $files $picture
}

proc ::mailapp::attach_files {where files {inline 0}} {
	foreach f $files {
		if {![file isfile $f]} continue
		set a [dict create path $f name [file tail $f] size [file size $f] inline $inline]
		if {$where eq "reply"} { dict lappend ::mailapp::draft atts $a } else { dict lappend ::mailapp::cdraft atts $a }
	}
	set ::mailapp::saved 0
	if {$where eq "reply"} { paint } else { compose_paint }
}

# Send: the message goes through the account's SMTP; the answered message is marked, the draft removed.
proc ::mailapp::send_now {} {
	variable state
	if {!$state(reply)} return
	send_draft [reply_draft] reply
}

proc ::mailapp::send_draft {d where} {
	if {![llength [mail::compose::recipients $d]]} { send_failed $where "Add someone to send it to"; return }
	if {[catch {set bytes [mail::compose::build $d]} err]} { send_failed $where $err; return }
	if {[info commands ::mail::sync::send] eq "" || [catch {mail::sync::send [dict get $d account] [lindex [dict get $d from] 1] \
			[mail::compose::recipients $d] $bytes [list ::mailapp::sent $d $where]} err]} {
		send_failed $where "Not sent: $err"
	}
}

proc ::mailapp::sent {d where status args} {
	if {$status ne "ok"} { send_failed $where "Not sent: [lindex $args end]"; return }
	if {[dict get $d answers] ne ""} {
		set k [dict get $d answers]
		catch {mail::store::add_flags $k [expr {[dict get $d mode] eq "forward" ? "P" : "R"}]}
		push [lindex $k 0] [lindex $k 1]
	}
	mail::compose::discard $d
	if {$where eq "reply"} {
		set ::mailapp::draft ""
		set ::mailapp::state(reply) 0
		place forget $::mailapp::rtext
		refresh_open
	} else {
		set ::mailapp::cdraft ""
		destroy $::mailapp::cwin
		paint
	}
}

proc ::mailapp::send_failed {where msg} {
	set ::mailapp::sendmsg $msg
	if {$where eq "reply"} { paint } else { compose_paint }
}

# ---- the new message window (Mail-A7-Compose) ------------------------------------------------------------------
# Drawn with the ui library on its own canvas: the library's state is swapped in while it draws or takes a press.
proc ::mailapp::with_canvas {which script} {
	variable cui
	set keys {cv W H hits img base img2 argbwin focusables}
	foreach k $keys { set save($k) [set ::ui::$k] }
	if {$which eq "compose"} {
		foreach k $keys { if {[info exists cui(ui:$k)]} { set ::ui::$k $cui(ui:$k) } }
	}
	set code [catch {uplevel 1 $script} res]
	if {$which eq "compose"} { foreach k $keys { set cui(ui:$k) [set ::ui::$k] } }
	foreach k $keys { set ::ui::$k $save($k) }
	return -code $code $res
}

proc ::mailapp::compose_new {{d ""}} {
	variable cwin
	variable cdraft
	variable cui
	variable c
	variable scene
	if {[winfo exists $cwin]} { raise $cwin; return }
	set accts [mail::store::accounts]
	if {[info commands ::mail::accounts::configured] ne ""} { set accts [dict keys [::mail::accounts::configured]] }
	if {$d eq ""} {
		set acct [expr {[lindex $::mailapp::state(conv) 0] in $accts ? [lindex $::mailapp::state(conv) 0] : [lindex $accts 0]}]
		set d [dict create account $acct from [from_of $acct] to {} cc {} subject "" text "" atts {} inreplyto "" references {} key "" answers "" mode new]
	}
	set cdraft $d
	set ::mailapp::sendmsg ""
	toplevel $cwin -class RibbonMail -borderwidth 0 -highlightthickness 0 -background $c(bar)
	set W 760; set H 680
	if {$scene} {
		wm overrideredirect $cwin 1
		wm geometry $cwin ${W}x${H}+340+110
	} else {
		wm title $cwin "New message"
		wm transient $cwin $::mailapp::win
		wm geometry $cwin ${W}x${H}+[expr {[winfo rootx $::mailapp::win] + 240}]+[expr {[winfo rooty $::mailapp::win] + 36}]
		wm protocol $cwin WM_DELETE_WINDOW ::mailapp::compose_close
	}
	canvas $cwin.c -width $W -height $H -highlightthickness 0 -borderwidth 0 -background $c(bar)
	place $cwin.c -x 0 -y 0
	set cui(ui:cv) $cwin.c; set cui(ui:W) $W; set cui(ui:H) $H; set cui(ui:hits) {}; set cui(ui:img) ""
	set cui(ui:base) ""; set cui(ui:img2) ""; set cui(ui:argbwin) ""; set cui(ui:focusables) {}
	foreach f {to cc subject} {
		entry $cwin.$f -font [expr {$f eq "subject" ? "ui_i14m" : "ui_i13"}] -borderwidth 0 -highlightthickness 0 -background $c(bar) \
			-foreground $c(fg) -insertbackground $c(accent) -insertwidth 2 -selectbackground $c(hit) -selectforeground $c(fg)
		bind $cwin.$f <KeyRelease> [list ::mailapp::compose_key $f %K]
		bind $cwin.$f <FocusOut> [list ::mailapp::compose_take $f]
	}
	$cwin.subject insert 0 [dict get $d subject]
	set cui(text) $cwin.text
	reply_text_widget $cwin.text ::mailapp::compose_send
	$cwin.text configure -background $c(bar)
	$cwin.text insert 1.0 [dict get $d text]
	$cwin.text edit modified 0
	bind $cwin.c <ButtonPress-1> {::mailapp::compose_press %x %y}
	bind $cwin <Control-Return> {::mailapp::compose_send; break}
	bind $cwin <Escape> {if {[::mailapp::menu_up]} ::mailapp::menu_close}
	compose_paint
	focus [expr {[llength [dict get $d to]] ? "$cwin.text" : "$cwin.to"}]
}

# An address typed into To or Cc becomes a chip at a comma, Enter or Tab, or when the field is left.
proc ::mailapp::compose_key {f sym} {
	if {$f eq "subject"} {
		dict set ::mailapp::cdraft subject [$::mailapp::cwin.subject get]
		text_changed_compose
		return
	}
	if {$sym in {comma semicolon Return KP_Enter}} { compose_take $f }
}

proc ::mailapp::text_changed_compose {} {
	set ::mailapp::saved 0
	if {$::mailapp::autosave ne ""} { after cancel $::mailapp::autosave }
	set ::mailapp::autosave [after 1500 ::mailapp::autosave_now]
}

proc ::mailapp::compose_take {f} {
	variable cwin
	if {$f eq "subject" || ![winfo exists $cwin.$f]} return
	set taken 0
	foreach part [split [$cwin.$f get] ",;"] {
		set a [mail::compose::parse_address $part]
		if {$a eq ""} continue
		dict lappend ::mailapp::cdraft $f $a
		set taken 1
	}
	if {$taken} {
		$cwin.$f delete 0 end
		text_changed_compose
		compose_paint
	}
}

proc ::mailapp::compose_remove {f i} {
	dict set ::mailapp::cdraft $f [lreplace [dict get $::mailapp::cdraft $f] $i $i]
	compose_paint
}

# The accounts a message can go from.
proc ::mailapp::compose_accounts {} {
	expr {[info commands ::mail::accounts::configured] ne "" ? [dict keys [::mail::accounts::configured]] : [mail::store::accounts]}
}
# The message goes from account A (its draft moves to that account's Drafts).
proc ::mailapp::compose_from {a} {
	variable cdraft
	if {$a eq [dict get $cdraft account]} return
	set cdraft [mail::compose::discard $cdraft]
	dict set cdraft account $a
	dict set cdraft from [from_of $a]
	compose_paint
}

proc ::mailapp::compose_press {x y} {
	variable cui
	if {[menu_up]} { menu_close; return }
	foreach h [lreverse $cui(ui:hits)] {
		lassign $h x0 y0 x1 y1 script
		if {$script eq "" || $x < $x0 || $x >= $x1 || $y < $y0 || $y >= $y1} continue
		uplevel #0 $script
		return
	}
}

proc ::mailapp::compose_paint {} {
	variable cwin
	variable cdraft
	variable c
	variable cui
	if {![winfo exists $cwin]} return
	with_canvas compose {
		ui::begin compose {}
		set W 760; set H 680
		ui::text 22 22 "New message" sg22 $c(fg) w -0.44
		ui::box 0 70 $W 1 -fill $c(border)
		set y 71
		foreach {label f} {From from To to Cc cc Subject subject} {
			ui::text 22 [expr {$y + 14.5}] $label i13 $c(muted)
			set x 108
			switch -- $f {
				from {
					lassign [dict get $cdraft from] n a
					set acct [dict get $cdraft account]
					set w [expr {4 + 20 + 7 + [ui::measure i12m $acct] + 7 + [ui::measure i12 $a] + 7 + 12 + 8}]
					ui::box $x [expr {$y + 9}] $w 28 -fill $c(bar) -radius 7 -ring [list $c(border) 1]
					avatar $acct [expr {$x + 4}] [expr {$y + 13}] 20
					set tx [expr {$x + 31}]
					set tx [expr {$tx + [ui::text $tx [expr {$y + 15.5}] $acct i12m $c(fg)] + 7}]
					set tx [expr {$tx + [ui::text $tx [expr {$y + 15.5}] $a i12 $c(muted)] + 7}]
					icon chev 12 $c(muted) $tx [expr {$y + 17}] 2
					ui::hit $x [expr {$y + 9}] $w 28 [list ::mailapp::from_menu $x [expr {$y + 9}]]
				}
				to - cc {
					set i 0
					foreach a [dict get $cdraft $f] {
						set w [recipient_chip $x [expr {$y + 11}] $a]
						ui::hit $x [expr {$y + 11}] $w 24 [list ::mailapp::compose_remove $f $i]
						set x [expr {$x + $w + 8}]
						incr i
					}
					place $cwin.$f -x $x -y [expr {$y + 13}] -width [expr {$W - 22 - $x}] -height 20
				}
				subject { place $cwin.subject -x 108 -y [expr {$y + 12}] -width [expr {$W - 130}] -height 22 }
			}
			ui::box 0 [expr {$y + 45}] $W 1 -fill $c(border)
			incr y 46
		}
		set atts [dict get $cdraft atts]
		set ah [expr {[llength $atts] ? (([llength $atts] + 1) / 2) * 52 : 0}]
		set th [expr {$H - 56 - $y - 18 - 14 - $ah}]
		place $cwin.text -x 22 -y [expr {$y + 18}] -width [expr {$W - 44}] -height $th
		set ay [expr {$y + 18 + $th}]
		set i 0
		foreach a $atts {
			att_chip [expr {22 + ($i % 2) * 308}] [expr {$ay + ($i / 2) * 52}] $a [list ::mailapp::compose_unattach $i]
			incr i
		}
		composer_foot 0 [expr {$H - 56}] [expr {$W - 2}] {::mailapp::attach compose 0} {::mailapp::attach compose 1} \
			::mailapp::compose_discard ::mailapp::compose_send $::mailapp::saved $::mailapp::sendmsg
		ui::finish
	}
	# a scene has no window manager to keep the window over Mail
	if {$::mailapp::scene} { raise $cwin }
}

proc ::mailapp::compose_unattach {i} {
	dict set ::mailapp::cdraft atts [lreplace [dict get $::mailapp::cdraft atts] $i $i]
	compose_paint
}

proc ::mailapp::compose_current {} {
	variable cdraft
	variable cwin
	foreach f {to cc} { compose_take $f }
	dict set cdraft subject [$cwin.subject get]
	dict set cdraft text [$cwin.text get 1.0 end-1c]
	return $cdraft
}

proc ::mailapp::compose_save {} {
	variable cdraft
	if {![winfo exists $::mailapp::cwin]} return
	set d [compose_current]
	if {[string trim "[dict get $d subject][dict get $d text]"] eq "" && ![llength [dict get $d atts]] && ![llength [dict get $d to]]} {
		set cdraft [mail::compose::discard $d]
		return
	}
	if {[catch {set cdraft [mail::compose::save_draft $d]} err]} { puts stderr "ribbon-mail: the draft was not saved: $err"; return }
	$::mailapp::cwin.text edit modified 0
	set ::mailapp::saved 1
}

proc ::mailapp::compose_close {} {
	compose_save
	menu_close
	destroy $::mailapp::cwin
	paint
}

proc ::mailapp::compose_discard {} {
	variable cdraft
	set cdraft [mail::compose::discard $cdraft]
	destroy $::mailapp::cwin
	paint
}

proc ::mailapp::compose_send {} {
	send_draft [compose_current] compose
}
