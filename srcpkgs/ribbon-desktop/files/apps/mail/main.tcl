# main.tcl - Mail (ribbon-mail, U41): the window, its state and its actions. Tcl/Tk, drawn as Mail-A-Ledger,
# -A2-Thread, -A3-Reply, -A4-Search, -A5-Caught-up, -A7-Compose and -A8-Attach (design/mockups; gen_mail.py,
# gen_mail_compose.py, gen_mail_ui.py).
#
#   ribbon-mail                      (the mail folder is ~/Mail, or RIBBON_MAIL_ROOT)
#   RIBBON_MAIL_SCENE = file         a test scene (tests/mail-scene.tcl), run instead of the normal start
#   RIBBON_MAIL_ACCOUNTS = file      the accounts provider to source in place of accounts.tcl (tests)
#
# The model is store.tcl, thread.tcl and search.tcl (U39), sync.tcl over syncstore.tcl (U40) and compose.tcl. The
# chrome is one canvas drawn with the Appearance app's ui library: the rail (ui-rail.tcl), the list (ui-list.tcl),
# the reading pane (ui-reader.tcl); the inline reply and the new message window (ui-compose.tcl) write in Tk text
# widgets placed over it.
#
# Accounts come from the accounts provider (accounts.tcl, U42), when it is there:
#   mail::accounts::configured       {NAME OPTS ...}: OPTS for mail::sync::start (-imap -smtp -password) and
#                                    -address ADDR -fullname NAME (the From of mail sent from it)
#   mail::accounts::sheet DONE       the Add an account sheet (Mail-A6-Account); DONE is called with the new
#                                    account's name once it is added
#   mail::accounts::sheet_up, sheet_paint, sheet_place, sheet_escape   the sheet while it is open: paint draws it
#                                    over the window shaded (ui::dim), and it takes Escape and the wheel
# Without one, the accounts are the folders under ~/Mail and nothing is synced.

namespace eval ::mailapp {
	variable W 1240
	variable H 780
	variable RW 232                 ;# the rail
	variable LW 372                 ;# the list
	variable MEAS 560               ;# the message's measure
	variable win .w
	variable cv .w.c
	variable scene 0
	variable appdir [file dirname [file normalize [info script]]]
	variable state
	array set state {view inboxes conv "" query "" searchfocus 0 scope all unreadonly 0 reply 0 match 0 status ""}
	variable open {}                ;# the accounts open in the rail
	variable convs {}               ;# the list's conversations (or search rows)
	variable conv ""                ;# the open conversation
	variable expanded {}            ;# keys of its messages shown in full
	variable earlier 0              ;# the "N earlier" row is open
	variable lscroll 0
	variable pscroll 0
	variable checked ""             ;# when every account was last checked (seconds)
	variable now ""                 ;# a scene's clock; "" is the real one
	variable c
	array set c {}
}

proc ::mailapp::find_dir {name file} {
	foreach d [list [file normalize [file join $::mailapp::appdir .. $name]] [file normalize [file join $::mailapp::appdir .. .. $name]] /usr/lib/ribbon/$name] {
		if {[file exists [file join $d $file]]} { return $d }
	}
	puts stderr "ribbon-mail: $name/$file was not found"; exit 1
}

proc ::mailapp::libraries {} {
	set shell [find_dir shell raster.tcl]
	set appearance [find_dir appearance ui.tcl]
	foreach d [list /usr/lib/ribbon [file dirname $shell]] { if {$d ni $::auto_path} { lappend ::auto_path $d } }
	package require rbnalpha
	foreach f {text raster wall theme} { uplevel #0 [list source -encoding utf-8 [file join $shell $f.tcl]] }
	uplevel #0 [list source -encoding utf-8 [file join $appearance ui.tcl]]
	uplevel #0 [list source -encoding utf-8 [file join $appearance chooser.tcl]]
	array set ::ui::fonts {
		sg8 {{Ribbon Space Grotesk 600} 8 0.984 0.292}
		sg9 {{Ribbon Space Grotesk 600} 9 0.984 0.292}
		sg12 {{Ribbon Space Grotesk 600} 12 0.984 0.292}
		sg13 {{Ribbon Space Grotesk 600} 13 0.984 0.292}
		sg15 {{Ribbon Space Grotesk 600} 15 0.984 0.292}
		sg26 {{Ribbon Space Grotesk 600} 26 0.984 0.292}
		i15 {{Ribbon Inter 400} 15 0.96875 0.2412}
	}
	foreach f {mime store thread search syncstore sync compose} { uplevel #0 [list source -encoding utf-8 [file join $::mailapp::appdir $f.tcl]] }
	set acc [expr {[info exists ::env(RIBBON_MAIL_ACCOUNTS)] ? $::env(RIBBON_MAIL_ACCOUNTS) : [file join $::mailapp::appdir accounts.tcl]}]
	if {[file exists $acc]} { uplevel #0 [list source -encoding utf-8 $acc] }
	foreach f {ui-rail ui-list ui-reader ui-compose ui-menu} { uplevel #0 [list source -encoding utf-8 [file join $::mailapp::appdir $f.tcl]] }
}

proc ::mailapp::apply_theme {} {
	::theme::load
	ui::colours [dict create BAR $::theme::c(BAR) FIELD $::theme::c(FIELD) PILL $::theme::c(PILL) BORDER $::theme::c(BORDER) \
		FG $::theme::c(FG) MUTED $::theme::c(MUTED) ACCENT $::theme::c(ACCENT) ON_ACCENT $::theme::c(ON_ACCENT) \
		DESK_TOP $::theme::c(DESK_TOP) DESK_BOTTOM $::theme::c(DESK_BOTTOM) DESK_STRIPE $::theme::c(DESK_STRIPE) \
		DESK_STRIPE_ALPHA $::theme::c(DESK_STRIPE_ALPHA)]
	array unset ::mailapp::c
	array set ::mailapp::c [list bar $ui::c(bar) field $ui::c(field) pill $ui::c(pill) border $ui::c(border) fg $ui::c(fg) \
		muted $ui::c(muted) accent $ui::c(accent) ink $ui::c(ink) d2 $ui::c(d2) hit [ui::mix $ui::c(accent) $ui::c(bar) 0.22]]
}

# ---- drawing helpers ----------------------------------------------------------------------------------------
namespace eval ::mailapp {
	variable paths
	array set paths {
		mail {M4 4h16a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z M22 6l-10 7L2 6}
		inbox {M22 12h-6l-2 3h-4l-2-3H2 M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z}
		send {M22 2L11 13 M22 2l-7 20-4-9-9-4z}
		flag {M4 15s1-1 4-1 5 2 8 2 4-1 4-1V3s-1 1-4 1-5-2-8-2-4 1-4 1z M4 22v-7}
		clip {M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48}
		archive {M21 8v13H3V8 M1 3h22v5H1z M10 12h4}
		reply {M9 17l-5-5 5-5 M20 18v-2a4 4 0 0 0-4-4H4}
		replyall {M7 17l-5-5 5-5 M12 17l-5-5 5-5 M22 18v-2a4 4 0 0 0-4-4H7}
		fwd {M15 17l5-5-5-5 M4 18v-2a4 4 0 0 1 4-4h12}
		junk {M12 2a10 10 0 1 0 0 20a10 10 0 1 0 0-20z M4.93 4.93l14.14 14.14}
		draft {M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z M14 3v5h5 M9 15l2 2 4-4}
		checks {M18 6L7 17l-5-5 M22 10l-7.5 7.5L13 16}
		pdf {M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z M14 3v5h5 M9 13h6 M9 17h6}
		plus {M12 5v14 M5 12h14}
		x {M18 6L6 18 M6 6l12 12}
		bold {M6 4h8a4 4 0 0 1 0 8H6z M6 12h9a4 4 0 0 1 0 8H6z}
		italic {M19 4h-9 M14 20H5 M15 4L9 20}
		list {M8 6h13 M8 12h13 M8 18h13 M3 6h.01 M3 12h.01 M3 18h.01}
		link {M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71 M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71}
		image {M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z M8.5 10a1.5 1.5 0 1 0 0-3a1.5 1.5 0 1 0 0 3z M21 15l-5-5L5 21}
		edit {M12 20h9 M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4z}
		search {M4 11a7 7 0 1 0 14 0a7 7 0 1 0 -14 0 M21 21l-4.3-4.3}
		trash {M3 6h18 M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6 M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2}
		sort {M3 6h18 M6 12h12 M10 18h4}
		chev {M6 9l6 6 6-6}
		chevup {M18 15l-6-6-6 6}
		right {M9 18l6-6-6-6}
		download {M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4 M7 10l5 5 5-5 M12 15V3}
		file {M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z M14 3v5h5}
	}
}

proc ::mailapp::icon {name size colour x y {sw 1.9}} {
	variable paths
	set i [raster::icon $paths($name) $size $sw [ui::col $colour] {} 0 0 0]
	$::ui::cv create image [expr {round($x)}] [expr {round($y)}] -image $i -anchor nw -tags page
}

# An icon button: SIZE square, the icon centred; ON draws it on BG.
proc ::mailapp::iconbtn {name x y size isz script {colour ""} {bg ""}} {
	variable c
	if {$bg ne ""} { ui::box $x $y $size $size -fill $bg -radius 8 }
	icon $name $isz [expr {$colour eq "" ? $c(muted) : $colour}] [expr {$x + ($size - $isz) / 2.0}] [expr {$y + ($size - $isz) / 2.0}]
	if {$script ne ""} { ui::hit $x $y $size $size $script }
}

# STR cut to WIDTH with an ellipsis.
proc ::mailapp::elide {f str width} {
	if {[ui::measure $f $str] <= $width} { return $str }
	set lo 0
	set hi [string length $str]
	while {$lo < $hi} {
		set mid [expr {($lo + $hi + 1) / 2}]
		if {[ui::measure $f "[string range $str 0 $mid-1]…"] <= $width} { set lo $mid } else { set hi [expr {$mid - 1}] }
	}
	return "[string trimright [string range $str 0 $lo-1]]…"
}

# A round avatar of SIZE with the name's first letter.
proc ::mailapp::avatar {name x y size} {
	variable c
	set l [string toupper [string index [string trimleft $name {"'( }] 0]]
	ui::box $x $y $size $size -fill $c(pill) -radius [expr {$size / 2.0}]
	set f [dict get {18 sg8 20 sg8 22 sg9 28 sg12 32 sg13 36 sg15} $size]
	ui::text [expr {$x + $size / 2.0}] [ui::lh $y $f $size] $l $f $c(muted) c
}

# The tag chip: "#" and the label, 12 px 500 muted on §field.
proc ::mailapp::chip {x y name {h 26}} {
	variable c
	set w [expr {18 + [ui::measure i12m "#$name"]}]
	ui::box $x $y $w $h -fill $c(field) -radius 7
	ui::text [expr {$x + 9}] [expr {$y + ($h - 15) / 2.0}] "#$name" i12m $c(muted)
	return $w
}

# Text and icons (canvas items, above the page's picture) of rows scrolled under a head are taken off before the head
# is drawn: the head's box covers only the picture.
proc ::mailapp::clear_band {x0 y0 x1 y1} {
	foreach i [$::ui::cv find overlapping $x0 $y0 $x1 $y1] {
		set t [$::ui::cv gettags $i]
		if {"page" in $t && "base" ni $t && "top" ni $t} { $::ui::cv delete $i }
	}
}

proc ::mailapp::clock_now {} {
	variable now
	expr {$now eq "" ? [clock seconds] : $now}
}

# ---- the window ------------------------------------------------------------------------------------------
proc ::mailapp::build {} {
	variable win
	variable W
	variable H
	variable cv
	variable scene
	wm withdraw .
	if {$scene} {
		toplevel $win -class RibbonMail -borderwidth 0 -highlightthickness 0
		wm overrideredirect $win 1
		wm geometry $win ${W}x${H}+100+74
	} else {
		set H [rbn::fit $H]
		if {[rbn::appwindow $win RibbonMail $W $H -fill $::mailapp::c(bar)]} { set ::ui::argbwin $win }
		wm title $win "Mail"
		wm iconname $win "Mail"
		wm minsize $win 1000 600
		wm protocol $win WM_DELETE_WINDOW ::mailapp::quit
		wm geometry $win ${W}x${H}+[expr {max(0, ([winfo screenwidth .] - $W) / 2)}]+[expr {max(0, ([winfo screenheight .] - $H) / 2 + 14)}]
	}
	# rbn::appwindow has already made $win.c (the window's canvas); the scene's plain toplevel has none yet
	if {![winfo exists $cv]} { canvas $cv -width $W -height $H -highlightthickness 0 -borderwidth 0 -background $::mailapp::c(bar) }
	place $cv -x 0 -y 0
	set ::ui::cv $cv
	set ::ui::W $W
	set ::ui::H $H
	set ::ui::ox 0; set ::ui::oy 0
	set ::ui::behind ""; set ::ui::bx 0; set ::ui::by 0
	bind $cv <ButtonPress-1> {mailapp::press %x %y}
	bind $cv <Button-4> {mailapp::wheel %x %y -1}
	bind $cv <Button-5> {mailapp::wheel %x %y 1}
	bind $win <Control-f> {if {![mailapp::modal]} mailapp::search_focus}
	bind $win <Control-n> {if {![mailapp::modal]} mailapp::compose_new}
	bind $win <Control-r> {if {![mailapp::modal]} {mailapp::reply_open reply}}
	bind $win <Escape> {mailapp::escape}
	bind $win <KeyPress> {mailapp::key_top %K %A}
	bind $win <Configure> {if {"%W" eq $::mailapp::win} {::mailapp::resized %w %h}}
}

proc ::mailapp::resized {w h} {
	variable W
	variable H
	variable cv
	if {$w < 1000 || $h < 600 || ($w == $W && $h == $H)} return
	set W $w
	set H $h
	set ::ui::W $W
	set ::ui::H $H
	$cv configure -width $W -height $H
	place $cv -x 0 -y 0 -width $W -height $H
	paint
}

# A press: the topmost hit whose script runs; scripts get no coordinates.
proc ::mailapp::press {x y} {
	variable state
	# a click beside an open menu closes it, and only that
	if {[menu_up]} { menu_close; return }
	foreach h [lreverse $::ui::hits] {
		lassign $h x0 y0 x1 y1 script
		if {$script eq "" || $x < $x0 || $x >= $x1 || $y < $y0 || $y >= $y1} continue
		if {$state(searchfocus) && ![string match *search* $script]} { set state(searchfocus) 0 }
		uplevel #0 $script
		return
	}
	if {$state(searchfocus)} { set state(searchfocus) 0; paint }
}

proc ::mailapp::wheel {x y d} {
	variable RW
	variable LW
	variable lscroll
	variable pscroll
	if {[modal]} return
	if {$x < $RW} {
		set ::mailapp::rscroll [expr {max(0, min([rail_max], $::mailapp::rscroll + $d * 60))}]
	} elseif {$x < $RW + $LW} {
		set lscroll [expr {max(0, min([list_max], $lscroll + $d * 60))}]
	} else {
		set pscroll [expr {max(0, min([pane_max], $pscroll + $d * 60))}]
	}
	paint
}

# The Add an account sheet (accounts provider, ui-account.tcl) is open: the window is drawn shaded under it.
proc ::mailapp::modal {} {
	expr {[info commands ::mail::accounts::sheet_up] ne "" && [::mail::accounts::sheet_up]}
}

proc ::mailapp::paint {} {
	variable cv
	if {![winfo exists $cv]} return
	set sheet [modal]
	set ::ui::dim [expr {$sheet ? 0.5 : 0}]
	ui::begin mail {}
	rail_paint
	if {[caught_up]} {
		caught_paint
	} else {
		list_paint
		pane_paint
	}
	set ::ui::dim 0
	if {$sheet} { ::mail::accounts::sheet_paint }
	ui::finish
	reply_place
	if {$sheet} { ::mail::accounts::sheet_place }
	# a scene has no window manager to keep the new message over Mail
	if {$::mailapp::scene && [winfo exists $::mailapp::cwin]} { raise $::mailapp::cwin }
}

proc ::mailapp::quit {args} {
	reply_save
	compose_save
	exit 0
}

# ---- the accounts the rail shows open ------------------------------------------------------------------------
proc ::mailapp::state_file {} {
	set base [expr {[info exists ::env(XDG_STATE_HOME)] ? $::env(XDG_STATE_HOME) : "$::env(HOME)/.local/state"}]
	return [file join $base ribbon-mail open-accounts]
}

proc ::mailapp::load_open {} {
	variable open
	if {[catch {
		set fh [::open [state_file] r]
		set open [split [string trim [::read $fh]] \n]
		::close $fh
	}]} { set open [lrange [mail::store::accounts] 0 0] }
}

proc ::mailapp::toggle_account {a} {
	variable open
	if {$a in $open} { set open [lsearch -all -inline -not -exact $open $a] } else { lappend open $a }
	catch {
		file mkdir [file dirname [state_file]]
		set fh [::open [state_file] w]
		puts $fh [join $open \n]
		::close $fh
	}
	paint
}

# ---- the model ---------------------------------------------------------------------------------------------
proc ::mailapp::mine {} {
	set out {}
	if {[info commands ::mail::accounts::configured] ne ""} {
		foreach {n o} [::mail::accounts::configured] { if {[dict exists $o -address]} { lappend out [dict get $o -address] } }
	}
	return $out
}

# The list's conversations for the view, or the search's rows.
proc ::mailapp::reload {} {
	variable state
	variable convs
	if {$state(query) ne ""} {
		set r [mail::search::run $state(query) $state(scope)]
		set convs [dict get $r rows]
		set ::mailapp::satts [dict get $r atts]
		return
	}
	set convs [mail::thread::view $state(view)]
	if {$state(unreadonly)} { set convs [lmap c $convs {expr {[dict get $c unread] ? $c : [continue]}}] }
}

# The view of the list; the first conversation opens (the board's ledger shows one open).
proc ::mailapp::show_view {v} {
	variable state
	variable lscroll
	reply_close
	set state(view) $v
	set state(query) ""
	set state(searchfocus) 0
	set lscroll 0
	reload
	open_first
	paint
}

proc ::mailapp::open_first {} {
	variable convs
	variable state
	if {[llength $convs]} {
		set c [lindex $convs 0]
		open_conv [expr {$state(query) ne "" ? [dict get $c msg key] : [dict get $c key]}] 0
	} else {
		set ::mailapp::conv ""
		set state(conv) ""
	}
}

# Opens the conversation KEY (a message key in it): its messages, unread ones marked read.
proc ::mailapp::open_conv {key {mark 1}} {
	variable state
	variable conv
	variable expanded
	variable earlier
	variable pscroll
	reply_close
	set conv ""
	foreach c [mail::thread::view [list account [lindex $key 0]]] {
		foreach m [dict get $c msgs] { if {[dict get $m key] eq $key} { set conv $c; break } }
		if {$conv ne ""} break
	}
	if {$conv eq ""} {
		# a message in junk or trash: alone
		if {[catch {set s [mail::store::summary $key]}]} { return }
		set conv [lindex [mail::thread::build [list $s]] 0]
	}
	set state(conv) $key
	set state(match) 0
	set earlier 0
	set pscroll 0
	# shown in full: the last message, the unread ones, and everything from your last reply on (what came of it)
	set mine [lmap a [mine] {string tolower $a}]
	set msgs [dict get $conv msgs]
	set from 0
	set i 0
	foreach m $msgs {
		if {[string tolower [lindex [dict get $m from] 1]] in $mine || [mail::store::role [dict get $m folder]] eq "sent"} { set from $i }
		incr i
	}
	set expanded {}
	set i 0
	foreach m $msgs {
		if {[dict get $m unread] || ($from && $i >= $from)} { lappend expanded [dict get $m key] }
		incr i
	}
	lappend expanded [dict get [lindex $msgs end] key]
	if {$mark} { mark_read $conv }
}

proc ::mailapp::mark_read {c} {
	set touched {}
	foreach m [dict get $c msgs] {
		if {![dict get $m unread]} continue
		if {[catch {mail::store::add_flags [dict get $m key] S}]} continue
		set af [list [dict get $m account] [dict get $m folder]]
		if {$af ni $touched} { lappend touched $af }
	}
	foreach af $touched { push {*}$af }
}

# A local flag change is sent to the server by the account's sync.
proc ::mailapp::push {acct folder} {
	set server [mail::syncstore::server $acct $folder]
	if {$server ne ""} { catch {mail::sync::push $acct $server} }
}

proc ::mailapp::select {key} {
	open_conv $key
	reload
	paint
}

# ---- actions on the open conversation ----------------------------------------------------------------------
# The messages the action is for: the conversation's messages in the view (all of them in a search).
proc ::mailapp::targets {} {
	variable conv
	variable state
	if {$conv eq ""} { return {} }
	if {$state(query) ne ""} { return [dict get $conv msgs] }
	# the open conversation was threaded over its whole account: only the list's view's messages are its (an
	# inbox conversation's reply stays in Sent)
	set fs [mail::store::folders_of $state(view)]
	set out [lmap m [dict get $conv msgs] {
		expr {[list [dict get $m account] [dict get $m folder]] in $fs && [mail::store::in_view $state(view) $m] ? $m : [continue]}
	}]
	# a message opened outside the view (junk, trash): itself
	if {![llength $out]} { set out [lmap m [dict get $conv msgs] {expr {[dict get $m key] eq $state(conv) ? $m : [continue]}}] }
	return $out
}

proc ::mailapp::toggle_flag {} {
	variable conv
	if {$conv eq ""} return
	set on [dict get $conv flagged]
	set last [lindex [dict get $conv msgs] end]
	foreach m [dict get $conv msgs] {
		if {$on} { catch {mail::store::remove_flags [dict get $m key] F} } elseif {[dict get $m key] eq [dict get $last key]} { catch {mail::store::add_flags [dict get $m key] F} } else continue
		push [dict get $m account] [dict get $m folder]
	}
	refresh_open
}

# Moves the conversation's messages to their account's folder of ROLE (archive, trash).
proc ::mailapp::move_to {role} {
	set ms [targets]
	if {![llength $ms]} return
	foreach m $ms {
		set acct [dict get $m account]
		if {$role eq "trash"} {
			if {[mail::store::role [dict get $m folder]] eq "trash"} {
				move_on_server $m ""
				catch {mail::store::delete [dict get $m key]}
				continue
			}
			set to [mail::store::folder_of $acct trash]
			if {$to eq ""} { set to Trash }
		} else {
			set to [mail::store::folder_of $acct $role]
			if {$to eq ""} { set to Archive }
			if {$to eq [dict get $m folder]} continue
		}
		move_on_server $m $to
		catch {mail::store::move [dict get $m key] $acct $to}
	}
	after_change
}

# The server side of a move (TO "" deletes): through the account's sync, when it has the hooks.
proc ::mailapp::move_on_server {m to} {
	set acct [dict get $m account]
	set server [mail::syncstore::server $acct [dict get $m folder]]
	if {$server eq "" || [info commands ::mail::sync::move] eq ""} return
	set uid [mail::syncstore::uid $acct [dict get $m folder] [lindex [dict get $m key] 2]]
	if {$uid eq ""} return
	set dest [expr {$to eq "" ? "" : [mail::syncstore::server $acct $to]}]
	if {$to ne "" && $dest eq ""} return
	catch {mail::sync::move $acct $server $uid $dest}
}

proc ::mailapp::after_change {} {
	variable state
	reload
	open_first
	paint
}

proc ::mailapp::refresh_open {} {
	variable state
	variable expanded
	set keep $expanded
	set k $state(conv)
	reload
	# a reply being written stays open: only the list is new
	if {$state(reply)} { paint; return }
	if {$k eq "" || [catch {mail::store::path $k}]} {
		open_first
		paint
		return
	}
	# the same conversation stays as it was read: its open rows and where the pane was scrolled to
	set ps $::mailapp::pscroll
	set ea $::mailapp::earlier
	set same [expr {$::mailapp::conv ne "" && $k in [lmap m [dict get $::mailapp::conv msgs] {dict get $m key}]}]
	open_conv $k 0
	if {$same} {
		set expanded $keep
		set ::mailapp::earlier $ea
		set ::mailapp::pscroll $ps
	}
	paint
	if {$::mailapp::pscroll > [pane_max]} { set ::mailapp::pscroll [pane_max]; paint }
}

proc ::mailapp::mark_all_read {} {
	variable convs
	variable state
	foreach c $convs { if {$state(query) eq ""} { mark_read $c } }
	reload
	paint
}

proc ::mailapp::toggle_unreadonly {} {
	variable state
	set state(unreadonly) [expr {!$state(unreadonly)}]
	reload
	paint
}

proc ::mailapp::save_attachment {key section name} {
	set p [chooser::save_file -parent $::mailapp::win -initialfile $name]
	if {$p eq ""} return
	mail::mime::save [mail::mime::parse [mail::store::read $key]] $section $p
}

# ---- search ----------------------------------------------------------------------------------------------------
proc ::mailapp::search_focus {} {
	variable state
	set state(searchfocus) 1
	focus $::mailapp::win
	paint
}

proc ::mailapp::search_clear {} {
	variable state
	set state(query) ""
	set state(searchfocus) 0
	set state(scope) all
	reload
	open_first
	paint
}

proc ::mailapp::escape {} {
	variable state
	if {[menu_up]} { menu_close; return }
	if {[modal]} { ::mail::accounts::sheet_escape; return }
	if {$state(searchfocus) || $state(query) ne ""} { search_clear }
}

proc ::mailapp::key_top {sym char} {
	variable state
	if {!$state(searchfocus)} return
	switch -- $sym {
		BackSpace { set state(query) [string range $state(query) 0 end-1] }
		Return - KP_Enter { set state(searchfocus) 0 }
		Escape { search_clear; return -code break }
		default {
			if {$char eq "" || ![string is print $char]} return
			append state(query) $char
		}
	}
	search_run
	return -code break
}

proc ::mailapp::search_set {q} {
	variable state
	set state(query) $q
	search_run
}

proc ::mailapp::search_run {} {
	variable state
	variable lscroll
	set lscroll 0
	reload
	open_first
	paint
}

proc ::mailapp::set_scope {s} {
	variable state
	set state(scope) $s
	search_run
}

# ---- sync -------------------------------------------------------------------------------------------------------
proc ::mailapp::start_sync {} {
	if {[info commands ::mail::accounts::configured] eq ""} return
	foreach {name opts} [::mail::accounts::configured] {
		set o [dict filter $opts script {k v} {expr {$k in {-imap -smtp -password -poll -idlerestart -retry}}}]
		dict set o -store ::mail::syncstore::cmd
		dict set o -status ::mailapp::sync_status
		mail::sync::start $name $o
	}
}

proc ::mailapp::sync_status {acct st} {
	variable checked
	variable state
	if {[dict get $st checked] ne ""} { set checked [expr {$checked eq "" ? [dict get $st checked] : max($checked, [dict get $st checked])}] }
	# new mail is in the store once a sync settles
	if {[dict get $st state] in {idle waiting}} {
		if {[info exists ::mailapp::repaint]} { after cancel $::mailapp::repaint }
		set ::mailapp::repaint [after 200 ::mailapp::refresh_open]
	}
}

proc ::mailapp::account_added {name} {
	variable open
	start_sync
	if {$name ni $open} { toggle_account $name }
	paint
}

proc ::mailapp::add_account {} {
	if {[info commands ::mail::accounts::sheet] ne ""} { ::mail::accounts::sheet ::mailapp::account_added }
}

# ---- start -----------------------------------------------------------------------------------------------------
proc ::mailapp::start {argv} {
	variable scene
	set scene [info exists ::env(RIBBON_MAIL_SCENE)]
	libraries
	apply_theme
	ui::fonts
	foreach {k v} [array get ::mailapp::paths] { if {![info exists ::ui::paths($k)]} { set ::ui::paths($k) $v } }
	raster::init [file join [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$::env(HOME)/.cache"}] ribbon mail]
	load_open
	build
	if {$scene} {
		uplevel #0 [list source -encoding utf-8 $::env(RIBBON_MAIL_SCENE)]
		return
	}
	reload
	open_first
	paint
	start_sync
}

proc ::mailapp::shot_and_exit {file} {
	variable W
	variable H
	update
	exec import -window root -crop ${W}x${H}+100+74 +repage $file
	exit 0
}

::mailapp::start $argv
