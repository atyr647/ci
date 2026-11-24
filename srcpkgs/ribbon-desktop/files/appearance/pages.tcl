# pages.tcl - the Appearance app's frame (the rail, the footer), the Theme
# and Colours pages, keys and Apply / Revert. The background pages are in
# bgpages.tcl, dialogs in dialogs.tcl.
#
# Positions are the mockups' (design/mockups/Appear-*.dc.html) inside the
# 1100 x 720 window: the rail is 230 wide, the page's content starts at
# x 270 and ends at 1060, the footer is the bottom 72 px.

namespace eval page {
	variable S
	array set S {
		page theme sel ribbon applied ribbon ytop 0
		edit "" epal {} role ACCENT mode rgb h 0 s 0 v 0 dirty 0
		unlinked {} rtop 0 listH 448
		todesk 1 tologin 1 busy 0 rename "" time ""
		login_launch ""
	}
	variable pages {
		theme palette Theme
		colours drop Colours
		desktop image {Desktop background}
		login lock {Login screen}
	}
	variable dialog ""
	# hosting (Settings, apps/settings): a host proc draws the window's contents in place of
	# the Appearance window's own rail and page; H and dy are its window height and footer offset
	variable host ""
	variable H 720
	variable dy 0
	variable launch {}
	# where the page's content starts: the subtitle's line box ends at
	# 34 + 36 + 6 + 21, then 22 px
	variable TOP 119
}

proc page::init {} {
	variable S
	variable launch
	store::load
	set cur [store::conf_get PALETTE ribbon]
	if {![store::exists $cur]} { set cur [lindex [store::ids] 0] }
	set S(applied) $cur
	set S(sel) $cur
	set S(tologin) [expr {[store::conf_get LOGIN_FOLLOWS_THEME yes] ne "no"}]
	set S(time) [clock format [clock seconds] -format %H:%M]
	bg::init
	set launch [list theme $cur tologin $S(tologin) bg [bg::snapshot]]
	chrome
}

# The app is drawn in the colours the desktop has now, like every other
# window; the theme being looked at or edited shows in the previews.
proc page::chrome {} {
	ui::colours [store::current_palette]
}

proc page::keys {} {
	variable pages
	lmap {k i l} $pages { set k }
}

proc page::go {p} {
	variable S
	if {$p ni [keys]} return
	# the backgrounds are chosen on stage: the window steps aside
	if {$p in {desktop login}} { os::start $p; return }
	if {$p eq "colours" && $S(edit) ne $S(sel)} { edit_start $S(sel) }
	set S(page) $p
	set ui::focus ""
	draw
}

proc page::quit {} { exit 0 }

# The login miniature's clock keeps the time.
proc page::tick {} {
	variable S
	set t [clock format [clock seconds] -format %H:%M]
	if {$t ne $S(time)} { set S(time) $t; draw }
	after [expr {1000 * (60 - [clock seconds] % 60) + 50}] page::tick
}

# ---- drawing -------------------------------------------------------------------

proc page::draw {} {
	variable pending
	# the background sheet is open: it is what is shown
	if {$os::S(open)} { os::draw; return }
	if {[info exists pending] && $pending ne ""} return
	set pending [after idle page::draw_now]
}

proc page::draw_now {} {
	variable pending ""
	variable S
	variable dialog
	variable host
	# a dialog shades the page; so does a hosted page's own sheet (page::shade, set by that page before it asks to
	# be drawn: Settings → Bluetooth's pairing sheet)
	variable shade
	set ui::dim [expr {$dialog ne "" ? 0.35 : [info exists shade] ? $shade : 0}]
	ui::begin frame page::frame_boxes
	if {$host ne ""} { {*}$host } else {
		frame
		draw_$S(page)
	}
	ui::focus_ring
	if {$dialog ne ""} { set ui::dim 0; dlg::draw }
	ui::finish
}

# The window, the rail and the footer's line: drawn once per palette.
proc page::frame_boxes {} {
	variable host
	variable H
	array set c [array get ui::c]
	ui::box 0 0 1100 $H -fill $c(bar) -radius [ui::outer_radius 16] -ring [list $c(border) 1]
	ui::box 0 0 230 $H -fill $c(d2) -radius [ui::outer_radius {16 0 0 16}]
	ui::box 229 0 1 $H -fill $c(border)
	# a host draws its own footer rule
	if {$host eq ""} { ui::hline 230 1100 648 $c(border) }
}

proc page::frame {} {
	variable S
	variable pages
	array set c [array get ui::c]
	ui::text 28 26 Appearance sg22 $c(fg) w -0.44
	set k 0
	foreach {key ic label} $pages {
		set y [expr {80 + 44 * $k}]
		set on [expr {$S(page) eq $key}]
		if {$on} {
			ui::box 16 $y 198 40 -fill $c(field) -radius 10
			ui::box 16 [expr {$y + 10}] 3 20 -fill $c(accent) -radius 2
		}
		ui::icon $ic 16 [expr {$on ? $c(accent) : $c(muted)}] 28 [expr {$y + 12}]
		ui::text 56 [expr {$y + 12}] $label [expr {$on ? "i13s" : "i13m"}] [expr {$on ? $c(fg) : $c(muted)}]
		ui::hit 16 $y 198 40 [list apply {{k x y} { page::go $k }} $key]
		incr k
	}
	ui::focusable rail list 16 [expr {80 + 44 * [lsearch -exact [keys] $S(page)]}] 198 40 10 page::rail_key
}

proc page::rail_key {sym} {
	variable S
	variable pages
	set keys [keys]
	set i [lsearch -exact $keys $S(page)]
	switch -- $sym {
		Up { set i [expr {max(0, $i - 1)}] }
		Down { set i [expr {min([llength $keys] - 1, $i + 1)}] }
		default { return 0 }
	}
	set f $ui::focus
	go [lindex $keys $i]
	set ui::focus $f
	return 1
}

# Title and subtitle.
proc page::head {title sub} {
	variable host
	variable S
	array set c [array get ui::c]
	if {$host ne ""} {
		# hosted, the page is Appearance, with Theme | Colours in its header
		set title Appearance
		ui::seg appearance 904 34 156 {theme Theme colours Colours} $S(page) page::go 38
	}
	ui::text 270 34 $title sg28 $c(fg) w -0.56
	set y 76
	foreach line [ui::wrap i14 $sub 790] { ui::text 270 [ui::lh $y i14 21 1] $line i14 $c(muted); set y [expr {$y + 21}] }
}

# The footer: where Apply goes, and the buttons {id label kind script icon}
# from the right.
proc page::footer {buttons} {
	variable S
	variable dy
	array set c [array get ui::c]
	set x 270
	foreach {key label} {todesk Desktop tologin {Login screen}} {
		ui::toggle $x [expr {673 + $dy}] $S($key)
		set tw [ui::text [expr {$x + 46}] [expr {676 + $dy}] $label i13 $c(muted)]
		ui::hit $x [expr {670 + $dy}] [expr {46 + $tw}] 28 [list apply {{k x y} { page::flip $k }} $key]
		ui::focusable $key toggle $x [expr {673 + $dy}] 38 22 11 [list page::flip $key]
		set x [expr {$x + 46 + $tw + 18}]
	}
	set x 1060
	foreach b $buttons {
		lassign $b id label kind script icon
		set w [ui::button_w $label $kind $icon]
		set x [expr {$x - $w}]
		ui::button $id $x [expr {665 + $dy}] $label $kind $script $icon $w
		set x [expr {$x - 10}]
	}
}

proc page::flip {key} {
	variable S
	set S($key) [expr {!$S($key)}]
	draw
}

# ---- Theme -------------------------------------------------------------------

proc page::swatches {x y p} {
	foreach k {ACCENT FG BAR FIELD} {
		ui::fbox $x $y 12 12 -fill [dict get $p $k] -radius 4 -ring {#FFFFFF 1 0.08}
		set x [expr {$x + 15}]
	}
}

# The name a background shows on its card: the picture's, the pattern's or the colour.
proc page::bg_name {which} {
	if {$which eq "login" && [dict get $::bg::login same]} { return "Same as desktop" }
	set d [expr {$which eq "desktop" ? $::bg::desk : [bg::effective_login]}]
	set mode [expr {$which eq "desktop" ? [dict get $d mode] : [dict get $d source]}]
	switch -- $mode {
		picture { return [file rootname [file tail [dict get $d image]]] }
		video { return [file rootname [file tail [dict get $::bg::desk video]]] }
		slideshow { return Slideshow }
		colour { return [dict get $d colour] }
	}
	return Ribbon
}

proc page::draw_theme {} {
	variable S
	variable TOP
	array set c [array get ui::c]
	head Theme "[store::get $S(applied) name] · [bg_name desktop]"
	# the row of five tiles (142 wide, 20 apart): the built-in themes, then yours
	# (the chosen one; the wheel moves through the rest), then New from current
	ui::label 270 $TOP "Built in"
	ui::label 756 $TOP Yours
	set ty [expr {$TOP + 22}]
	set x 270
	foreach id [store::ids 1] {
		theme_tile $id $x $ty
		set x [expr {$x + 162}]
	}
	set mine [store::ids 0]
	set x 756
	if {[llength $mine]} {
		set S(ytop) [expr {max(0, min($S(ytop), [llength $mine] - 1))}]
		theme_tile [lindex $mine $S(ytop)] $x $ty
		if {[llength $mine] > 1} { ui::wheel $x $ty 142 88 page::theme_wheel }
		set x [expr {$x + 162}]
	}
	new_tile $x $ty

	# what you can do with the theme
	set ay [expr {$ty + 129}]
	set x 270
	foreach {id label icon script} {edit {Edit colours} drop {page::go colours} dup Duplicate copy page::duplicate export Export… "" page::export import Import… "" page::import} {
		set x [expr {$x + [ui::button $id $x $ay $label field $script $icon] + 8}]
	}

	# the two backgrounds: the desktop's, and the login screen's (Change opens Onstage)
	ui::label 270 [expr {$ay + 62}] Backgrounds
	set cy [expr {$ay + 84}]
	set p [store::current_palette]
	thumbs::draw desk $p 270 $cy 387 226 $c(bar) [bg::thumb_bg desktop 387 226]
	thumbs::draw login $p 673 $cy 387 226 $c(bar) [bg::thumb_bg login 387 226]
	thumbs::clock $p 673 $cy 387 226 $S(time)
	set by [expr {$cy + 236}]
	foreach {which x label} {desktop 270 {Desktop background} login 673 {Login screen}} {
		set tw [ui::text $x [expr {$by + 8}] $label i13s $c(fg)]
		ui::text [expr {$x + $tw + 10}] [expr {$by + 8}] [bg_name $which] i13 $c(muted)
		set bw [ui::button_w Change field full]
		ui::button change_$which [expr {$x + 387 - $bw}] [expr {$by - 2}] Change field "page::go $which" full
	}

	footer [list {apply Apply primary page::apply check} {revert Revert ghost page::revert undo}]
}

# One theme in the row: a miniature 142 x 88 with its name under it. The chosen one
# has the accent ring and a check; a built-in has a lock after its name; your own,
# when chosen, can be renamed and deleted from its name line.
proc page::theme_tile {id x y} {
	variable S
	array set c [array get ui::c]
	set t [store::get $id]
	set on [expr {$id eq $S(sel)}]
	set p [expr {$on && $S(edit) eq $id ? $S(epal) : [dict get $t pal]}]
	thumbs::draw desk $p $x $y 142 88 $c(bar)
	if {$on} {
		ui::ring $x $y 142 88 10 $c(accent) 2
		ui::fbox [expr {$x + 118}] [expr {$y + 6}] 18 18 -fill $c(accent) -radius 9
		ui::icon check 10 $c(ink) [expr {$x + 122}] [expr {$y + 10}] 3
	}
	ui::hit $x $y 142 88 [list apply {{id x y} { page::pick $id }} $id]
	if {$on} { ui::focusable themes list $x $y 142 88 10 page::theme_key }
	set ny [expr {$y + 96}]
	if {$S(rename) eq $id} {
		ui::field rename $x $ny 170 -h 28 -radius 8 -pad 6 -max 48 -onenter page::rename_done
		return
	}
	set nw [ui::text $x [expr {$ny + 1}] [dict get $t name] [expr {$on ? "i13s" : "i13m"}] [expr {$on ? $c(fg) : $c(muted)}]]
	set ix [expr {$x + $nw + 6}]
	if {[dict get $t builtin]} {
		ui::icon lock 12 $c(muted) $ix [expr {$ny + 2}]
	} elseif {$on} {
		ui::icon edit 12 $c(muted) $ix [expr {$ny + 2}]
		ui::hit [expr {$ix - 3}] [expr {$ny - 2}] 20 22 [list apply {{id x y} { page::rename_start $id }} $id]
		ui::icon trash 12 $c(muted) [expr {$ix + 22}] [expr {$ny + 2}]
		ui::hit [expr {$ix + 19}] [expr {$ny - 2}] 20 22 [list apply {{id x y} { page::delete $id }} $id]
	}
}

# The dashed tile that makes a theme from the colours on the desktop now.
proc page::new_tile {x y} {
	array set c [array get ui::c]
	ui::dashed $x $y 142 88 10 $c(border)
	ui::icon plus 14 $c(muted) [expr {$x + 64}] [expr {$y + 37}] 2
	ui::text $x [expr {$y + 97}] "New from current" i13m $c(muted)
	ui::hit $x $y 142 88 {apply {{x y} { page::new_from_current }}}
	ui::focusable newtheme button $x $y 142 88 10 page::new_from_current
}

proc page::theme_wheel {d} {
	variable S
	incr S(ytop) $d
	draw
}

# Choose a theme to look at (and to apply).
proc page::pick {id} {
	variable S
	if {$S(rename) ne ""} { set S(rename) "" }
	if {$S(dirty) && $S(edit) ne $id} {
		dlg::confirm "Discard your changes?" "Your changes to [store::get $S(edit) name] are not saved." \
			Discard [list page::pick_now $id] 1
		return
	}
	pick_now $id
}
proc page::pick_now {id} {
	variable S
	if {$S(edit) ne $id} { set S(edit) ""; set S(dirty) 0 }
	set S(sel) $id
	reveal
	chrome
	draw
}

# Keep the chosen theme of yours in the visible part of the list.
proc page::reveal {} {
	variable S
	set i [lsearch -exact [store::ids 0] $S(sel)]
	if {$i >= 0} { set S(ytop) $i }
}

proc page::theme_key {sym} {
	variable S
	set ids [store::ids]
	set i [lsearch -exact $ids $S(sel)]
	switch -- $sym {
		Up { if {$i > 0} { pick [lindex $ids [expr {$i - 1}]] } }
		Down { if {$i < [llength $ids] - 1} { pick [lindex $ids [expr {$i + 1}]] } }
		Home { pick [lindex $ids 0] }
		End { pick [lindex $ids end] }
		F2 { rename_start $S(sel) }
		Delete { delete $S(sel) }
		Return - KP_Enter { go colours }
		default { return 0 }
	}
	set ui::focus themes
	return 1
}

proc page::rename_start {id} {
	variable S
	if {[store::get $id builtin]} return
	set S(rename) $id
	ui::fset rename [store::get $id name]
	set ui::focus rename
	draw
}

proc page::rename_done {} {
	variable S
	set id $S(rename)
	if {$id eq ""} return
	if {[catch {store::rename $id [ui::fval rename]} err]} {
		dlg::message "Can't rename it" $err
		return
	}
	set S(rename) ""
	set ui::focus themes
	reveal
	draw
}

proc page::delete {id} {
	set t [store::get $id]
	if {[dict get $t builtin]} return
	dlg::confirm "Delete [dict get $t name]?" \
		"It goes from your themes. The desktop keeps its colours until you choose another theme." \
		Delete [list page::delete_now $id] 1
}
proc page::delete_now {id} {
	variable S
	set ids [store::ids]
	set i [lsearch -exact $ids $id]
	if {[catch {store::delete $id} err]} { dlg::message "Can't delete it" $err; return }
	if {$S(edit) eq $id} { set S(edit) ""; set S(dirty) 0 }
	if {$S(sel) eq $id} {
		set ids [store::ids]
		set S(sel) [lindex $ids [expr {min($i, [llength $ids] - 1)}]]
		if {![store::exists $S(applied)]} {}
		chrome
	}
	draw
}

proc page::duplicate {} {
	variable S
	if {[catch {store::duplicate $S(sel)} id]} { dlg::message "Can't duplicate it" $id; return }
	pick_now $id
}

# A theme of yours from the colours on the desktop now.
proc page::new_from_current {} {
	set p [store::current_palette]
	set name "[dict get $p NAME] (mine)"
	if {[catch {store::save_new $name $p} id]} { dlg::message "Can't make a theme" $id; return }
	pick_now $id
	go colours
}

proc page::export {} {
	variable S
	set t [store::get $S(sel)]
	set f [dlg::save_file "Export [dict get $t name]" "[dict get $t name].ribbon-theme"]
	if {$f ne ""} { export_to $f }
}
proc page::export_to {f} {
	variable S
	if {[file extension $f] eq ""} { append f .ribbon-theme }
	if {[catch {store::export $S(sel) $f} err]} { dlg::message "Can't export it" $err; return 0 }
	return 1
}

proc page::import {} {
	set f [dlg::open_file "Import a theme" {{{Ribbon themes} {.ribbon-theme .conf}} {{All files} *}}]
	if {$f ne ""} { import_from $f }
}
proc page::import_from {f} {
	if {[catch {store::import $f} id]} {
		dlg::message "Can't import [file tail $f]" "This isn't a theme Ribbon can use: $id."
		return ""
	}
	pick_now $id
	return $id
}

# ---- Colours -------------------------------------------------------------------

proc page::edit_start {id} {
	variable S
	set S(edit) $id
	set S(epal) [store::get $id pal]
	set S(dirty) 0
	set S(unlinked) [unlinked_of $S(epal)]
	ui::fset newname "[store::get $id name] (mine)"
	role $S(role)
}

# The keys that copy another (pal::LINKS) and are not equal to it: their own colour
proc page::unlinked_of {p} {
	set out {}
	foreach {k src} $pal::LINKS {
		if {![string equal -nocase [dict get $p $k] [dict get $p $src]]} { lappend out $k }
	}
	return $out
}

# Choose the role to edit; the picker takes its colour, and the list shows it.
proc page::role {key} {
	variable S
	set S(role) $key
	from_hex [cur_colour]
	show_role $S(listH)
	draw
}

# The picker's H S V from a colour. A grey (or black) has no hue: its H is 0,
# as the boards show it (A4c's white, A4e's black), not the last hue.
proc page::from_hex {hex} {
	variable S
	lassign [pal::rgb2hsv {*}[pal::rgb $hex]] h s v
	set S(h) [expr {$s > 0 && $v > 0 ? $h : 0.0}]
	set S(s) $s; set S(v) $v
	ui::fset hex $hex
}

# The alpha key of ROLE (default: the chosen role), or "" when it has none.
proc page::akey {{k ""}} {
	variable S
	if {$k eq ""} { set k $S(role) }
	foreach {key label a} $pal::ROLES { if {$key eq $k} { return $a } }
	return ""
}
proc page::label_of {k} {
	foreach {key label a} $pal::ROLES { if {$key eq $k} { return $label } }
	return $k
}
# A key that copies another and still follows it
proc page::linked {k} {
	variable S
	expr {[dict exists $pal::LINKS $k] && $k ni $S(unlinked)}
}

# What the picker edits: a colour role of the theme (the Colours page), or
# another colour (S(ptarget): a command that gets "get" or "set HEX"; the
# background sheet's Colour tab). Both pickers are this code. The bar
# shadow's colour is the last part of its value.
proc page::cur_colour {} {
	variable S
	if {[info exists S(ptarget)] && $S(ptarget) ne ""} { return [uplevel #0 [list {*}$S(ptarget) get]] }
	if {$S(role) eq "BAR_SHADOW"} { return [lindex [pal::shadow [dict get $S(epal) BAR_SHADOW]] 3] }
	dict get $S(epal) $S(role)
}

# Set the colour (from the picker). Keys that follow a role follow it,
# unless they are unlinked; editing a linked key unlinks it.
proc page::set_colour {hex {keephsv 0}} {
	variable S
	set hex [string toupper $hex]
	if {[cur_colour] eq $hex} { if {!$keephsv} { from_hex $hex }; draw; return }
	if {[info exists S(ptarget)] && $S(ptarget) ne ""} {
		uplevel #0 [list {*}$S(ptarget) set $hex]
		if {!$keephsv} { from_hex $hex } else { ui::fset hex $hex }
		draw
		return
	}
	if {$S(role) eq "BAR_SHADOW"} {
		lassign [pal::shadow [dict get $S(epal) BAR_SHADOW]] dy blur a -
		dict set S(epal) BAR_SHADOW [pal::shadow_make $dy $blur $a $hex]
	} else {
		if {[dict exists $pal::LINKS $S(role)] && $S(role) ni $S(unlinked)} { lappend S(unlinked) $S(role) }
		set S(epal) [pal::set_key $S(epal) $S(role) $hex $S(unlinked)]
	}
	set S(dirty) 1
	if {!$keephsv} { from_hex $hex } else { ui::fset hex $hex }
	draw
}
# A linked key takes its source's colour again (the reset button)
proc page::relink {} {
	variable S
	set k $S(role)
	if {![dict exists $pal::LINKS $k]} return
	dict set S(epal) $k [dict get $S(epal) [dict get $pal::LINKS $k]]
	set S(unlinked) [lsearch -all -inline -not -exact $S(unlinked) $k]
	set S(dirty) 1
	from_hex [dict get $S(epal) $k]
	draw
}

proc page::set_hsv {h s v} {
	variable S
	set S(h) [expr {max(0.0, min(360.0, $h))}]; set S(s) [expr {max(0.0, min(1.0, $s))}]; set S(v) [expr {max(0.0, min(1.0, $v))}]
	set_colour [pal::hex {*}[pal::hsv2rgb $S(h) $S(s) $S(v)]] 1
}

# The chosen role's alpha, in the palette's 4 decimals
proc page::set_alpha {a} {
	variable S
	set ak [akey]
	if {$ak eq ""} return
	set a [expr {max(0.0, min(1.0, $a))}]
	dict set S(epal) $ak [pal::alpha_str $a]
	set S(dirty) 1
	draw
}

# An alpha in percent: 3%, 6.5%
proc page::alpha_pct {a} {
	set s [format %.1f [expr {$a * 100}]]
	regsub {\.0$} $s {} s
	return "$s%"
}

# Mix FG over BG at A (0..1), as a hex colour
proc page::blend {fg bg a} {
	lassign [pal::rgb $fg] r1 g1 b1
	lassign [pal::rgb $bg] r2 g2 b2
	pal::hex [expr {$r1 * $a + $r2 * (1 - $a)}] [expr {$g1 * $a + $g2 * (1 - $a)}] [expr {$b1 * $a + $b2 * (1 - $a)}]
}

# ---- the role list: the groups and rows as items, top to bottom ----------------
# Each item: {head y title} or {row y key label alpha-key}, y from the list's top.
# Heads and rows are 32 px, the groups 12 apart. Returns {items total}.
proc page::ritems {} {
	set out {}
	set y 0
	foreach {g rs} $pal::GROUPS {
		lappend out [list head $y $g {} {}]
		incr y 32
		foreach {k l a} $rs {
			lappend out [list row $y $k $l $a]
			incr y 32
		}
		incr y 12
	}
	return [list $out [expr {$y - 12}]]
}

# The item index that scrolling to I (within H px) can show: the list
# never scrolls past its last row.
proc page::rclamp {i H} {
	lassign [ritems] items total
	set maxo [expr {max(0, $total - $H)}]
	set imax 0
	for {set j 0} {$j < [llength $items]} {incr j} {
		if {[lindex $items $j 1] <= $maxo} { set imax $j }
	}
	expr {max(0, min($imax, $i))}
}

# The wheel over the list: one item per notch
proc page::rscroll {d} {
	variable S
	set step [expr {$d > 0 ? 1 : -1}]
	set S(rtop) [rclamp [expr {$S(rtop) + $step}] $S(listH)]
	draw
}

# Scroll so the chosen role shows: if it is out of view, its group's head
# is the list's first line.
proc page::show_role {H} {
	variable S
	lassign [ritems] items total
	set ri -1
	set gi 0
	for {set i 0} {$i < [llength $items]} {incr i} {
		lassign [lindex $items $i] type y k
		if {$type eq "head"} { set gi $i }
		if {$type eq "row" && $k eq $S(role)} { set ri $i; break }
	}
	if {$ri < 0} return
	set top [lindex $items $S(rtop) 1]
	set ry [lindex $items $ri 1]
	if {$ry >= $top && $ry + 32 <= $top + $H} return
	set S(rtop) [rclamp $gi $H]
}

# ---- the page -------------------------------------------------------------------

proc page::draw_colours {} {
	variable S
	variable TOP
	array set c [array get ui::c]
	if {$S(edit) ne $S(sel)} { edit_start $S(sel) }
	set t [store::get $S(sel)]
	set builtin [dict get $t builtin]
	set p $S(epal)
	head Colours "Editing [dict get $t name]"
	set y $TOP
	if {$builtin} {
		# the banner: a built-in is saved as a new theme, named here
		set by [expr {$TOP - 6}]
		ui::box 270 $by 790 58 -fill $c(field) -radius 12
		ui::ring 270 $by 790 58 12 $c(border) 1
		ui::icon lock 15 $c(muted) 282 [expr {$by + 21.5}]
		set tt [expr {$by + 21}]
		set x [expr {309 + [ui::text 309 $tt "[dict get $t name] is built in." i13s $c(fg)]}]
		set x [expr {$x + [ui::measure i13 " "]}]
		set x [expr {$x + [ui::text $x $tt "Your changes are saved as a new theme:" i13 $c(muted)] + 12}]
		ui::field newname $x [expr {$by + 10}] 190 -max 48 -onenter page::save_new
		set y [expr {$by + 58 + 16}]
	}
	# the three columns (STYLE §22): they end 16 above the footer's rule (648),
	# whatever the banner
	set H [expr {632 - $y}]
	set S(listH) $H
	set S(rtop) [rclamp $S(rtop) $H]
	draw_roles $y $H $p
	if {$S(role) eq "BAR_SHADOW"} { draw_shadow $y $H $p } else { draw_picker $y $H $p }
	draw_preview $y $H $p
	if {$builtin} {
		footer [list {savenew {Save as new theme} primary page::save_new check} {discard Discard ghost page::discard undo}]
	} else {
		footer [list {save Save primary page::save check} {savenew {Save as new} field page::save_new ""} {discard Discard ghost page::discard undo}]
	}
}

# The role list (270, 250 wide): the groups with their 32 heads, the rows
# (swatch, name, the value in mono and the alpha in percent), a 4 px thumb
# on the right, and the focus on the whole list.
proc page::draw_roles {y H p} {
	variable S
	array set c [array get ui::c]
	lassign [ritems] items total
	set top [lindex $items $S(rtop) 1]
	foreach it $items {
		lassign $it type iy k l a
		set rel [expr {$iy - $top}]
		# a row is drawn when its swatch is at least partly in the list; what
		# runs past the foot is covered by the gap below (see the foot)
		if {$rel < 0 || $rel + 25 > $H + 16} continue
		set ty [expr {$y + $rel}]
		if {$type eq "head"} {
			ui::label 270 [expr {$ty + 10}] $k
			continue
		}
		set on [expr {$k eq $S(role)}]
		set linked [linked $k]
		# the bar shadow's row shows its colour and its opacity
		set col [dict get $p $k]
		if {$k eq "BAR_SHADOW"} {
			lassign [pal::shadow $col] - - sa col
			set a ""
			set a_text [alpha_pct $sa]
		}
		if {$on} { ui::box 270 $ty 240 32 -fill $c(field) -radius 8 }
		ui::fbox 280 [expr {$ty + 7}] 18 18 -fill $col -radius 5 -ring {#FFFFFF 1 0.12}
		ui::text 308 [expr {$ty + 9}] $l [expr {$on ? "i13s" : "i13m"}] [expr {$linked && !$on ? $c(muted) : $c(fg)}]
		set rx 500
		if {$a ne ""} {
			ui::text 500 [expr {$ty + 9}] [alpha_pct [dict get $p $a]] mono12 $c(muted) e
			set rx 456
		} elseif {$k eq "BAR_SHADOW"} {
			ui::text 500 [expr {$ty + 9}] $a_text mono12 $c(muted) e
			set rx 456
		}
		if {$linked} {
			set name [label_of [dict get $pal::LINKS $k]]
			ui::text $rx [expr {$ty + 9}] $name i12m $c(muted) e
			ui::icon link 12 $c(muted) [expr {$rx - [ui::measure i12m $name] - 17}] [expr {$ty + 10}]
		} else {
			ui::text $rx [expr {$ty + 9}] $col mono12 $c(muted) e
		}
		ui::hit 270 $ty 240 [expr {min(32, $H - $rel)}] [list apply {{k x y} { page::role $k }} $k]
	}
	# the foot: a 28 px fade to the bar (STYLE §22), and the 16 px gap under
	# the list covered (a row's spill, up to the footer's rule at 648). A
	# layer, so the rows' text (canvas items) fades with their swatches.
	ui::layer
	for {set f 0} {$f < 28} {incr f} {
		ui::fbox 270 [expr {$y + $H - 28 + $f}] 250 1 -fill $c(bar) -alpha [expr {($f + 1) / 28.0}]
	}
	ui::fbox 270 [expr {$y + $H}] 250 16 -fill $c(bar)
	if {$total > $H} {
		ui::fbox 516 [expr {$y + $top / double($total) * $H}] 4 [expr {$H * $H / double($total)}] -fill $c(pill) -radius 2
	}
	ui::wheel 270 $y 250 $H [list page::rscroll]
	ui::focusable roles list 270 $y 250 $H 8 page::role_key
}

# The picker (544, 282 wide): the role's name and its link state or reset
# button, the SV square, H, the RGB | HSL | HSV tabs and the hex field,
# the three channels, and an A channel for a key with an alpha.
proc page::draw_picker {y H p} {
	variable S
	array set c [array get ui::c]
	set px 544; set pw 282
	set k $S(role)
	ui::label $px $y [label_of $k]
	if {[dict exists $pal::LINKS $k]} {
		if {[linked $k]} {
			set name [label_of [dict get $pal::LINKS $k]]
			set w [ui::measure i12m $name]
			ui::text [expr {$px + $pw}] [expr {$y + 9}] $name i12m $c(muted) e
			ui::icon link 13 $c(muted) [expr {$px + $pw - $w - 19}] [expr {$y + 9}]
		} else {
			set bx [expr {$px + $pw - 28}]
			ui::box $bx [expr {$y + 2}] 28 28 -fill $c(field) -radius 8
			ui::ring $bx [expr {$y + 2}] 28 28 8 $c(border) 1
			ui::icon undo 14 $c(fg) [expr {$bx + 7}] [expr {$y + 9}]
			ui::hit $bx [expr {$y + 2}] 28 28 [list page::relink]
			ui::focusable relink button $bx [expr {$y + 2}] 28 28 8 page::relink
		}
	}
	set hasa [akey]
	set sy [expr {$y + 32}]
	set sh [expr {$H - 32 - 210 - ($hasa eq "" ? 0 : 40)}]
	picker_sv $px $sy $pw $sh
	set py [expr {$sy + $sh + 12}]
	slider_row hue H $px $py $pw [expr {$S(h) / 360.0}] "[expr {round($S(h)) % 360}]°" hue
	set py [expr {$py + 28 + 12}]
	ui::seg pmode $px [expr {$py + 3}] 170 {rgb RGB hsl HSL hsv HSV} $S(mode) page::mode
	ui::field hex [expr {$px + $pw - 112}] $py 112 -max 7 -onchange page::hex_typed -onenter page::hex_done
	set py [expr {$py + 38 + 12}]
	set hex [cur_colour]
	lassign [pal::rgb $hex] r g b
	switch $S(mode) {
		rgb {
			foreach ch {R G B} v [list $r $g $b] i {0 1 2} {
				set lo [lreplace [list $r $g $b] $i $i 0]; set hi [lreplace [list $r $g $b] $i $i 255]
				slider_row ch$ch $ch $px $py $pw [expr {$v / 255.0}] $v [list grad [pal::hex {*}$lo] [pal::hex {*}$hi]]
				set py [expr {$py + 28 + 12}]
			}
		}
		hsl - hsv {
			if {$S(mode) eq "hsl"} {
				lassign [pal::rgb2hsl $r $g $b] - s2 l2
				set rows [list H [expr {$S(h) / 360.0}] S $s2 L $l2]
			} else {
				set rows [list H [expr {$S(h) / 360.0}] S $S(s) V $S(v)]
			}
			foreach {ch v} $rows {
				set num [expr {$ch eq "H" ? round($v * 360) % 360 : round($v * 100)}]
				slider_row ch$ch $ch $px $py $pw $v $num [channel_grad $ch $S(mode)]
				set py [expr {$py + 28 + 12}]
			}
		}
	}
	if {$hasa ne ""} {
		set a [dict get $p $hasa]
		slider_row alpha A $px $py $pw $a [alpha_pct $a] [list alpha $hex]
	}
}

# The bar shadow's editor (A4e): Offset, Blur and Opacity rows of 40, then
# the colour on the SV square, the hue and the hex.
proc page::draw_shadow {y H p} {
	variable S
	array set c [array get ui::c]
	set px 544; set pw 282
	lassign [pal::shadow [dict get $S(epal) BAR_SHADOW]] dy blur a col
	ui::label $px $y "Bar shadow"
	set ry [expr {$y + 32}]
	set rows [list shDY Offset [expr {($dy + 32) / 64.0}] "$dy px" shBLUR Blur [expr {$blur / 48.0}] "$blur px" shA Opacity $a [alpha_pct $a]]
	foreach {id name frac val} $rows {
		ui::text $px [expr {$ry + 13}] $name i13 $c(fg)
		set tx [expr {$px + 70}]; set tw [expr {$pw - 70 - 12 - 52 - 12}]
		ui::fbox $tx [expr {$ry + 18}] $tw 4 -fill $c(pill) -radius 2
		ui::fbox $tx [expr {$ry + 18}] [expr {round($tw * $frac)}] 4 -fill $c(muted) -radius 2
		marker [expr {$tx + $frac * $tw}] [expr {$ry + 20}] #FFFFFF
		ui::hit $tx $ry $tw 40 [list page::slide $id $tx $tw] [list page::slide $id $tx $tw]
		ui::focusable $id slider $tx [expr {$ry + 18}] $tw 12 6 [list page::slider_key $id]
		set vx [expr {$px + $pw - 52}]
		ui::box $vx [expr {$ry + 6}] 52 28 -fill $c(field) -radius 7
		ui::text [expr {$vx + 26}] [expr {$ry + 12}] $val i13 $c(fg) c 0 {} 1
		if {$id ne "shA"} { ui::hline $px [expr {$px + $pw}] [expr {$ry + 39}] $c(border) }
		set ry [expr {$ry + 40}]
	}
	set ry [expr {$ry + 12}]
	ui::label $px [expr {$ry + 9}] "Colour"
	set sy [expr {$ry + 32}]
	set sh [expr {$H - ($sy - $y) - 12 - 28 - 12 - 38}]
	picker_sv $px $sy $pw $sh
	set py [expr {$sy + $sh + 12}]
	slider_row hue H $px $py $pw [expr {$S(h) / 360.0}] "[expr {round($S(h)) % 360}]°" hue
	set py [expr {$py + 28 + 12}]
	ui::field hex $px $py $pw -max 7 -onchange page::hex_typed -onenter page::hex_done
	ui::fbox [expr {$px + $pw - 28}] [expr {$py + 11}] 16 16 -fill [cur_colour] -radius 4
}

# The preview column (850, 210 wide): what the chosen role draws, and for a
# text role the contrast of its pairs under it.
proc page::draw_preview {y H p} {
	variable S
	set px 850; set pw 210
	set k $S(role)
	ui::label $px $y Preview
	set checks [pal::checks $k]
	set cb 0
	if {[llength $checks]} {
		set cb [expr {12 + 32 + [llength $checks] * 28 - 8}]
		set bt [expr {$y + $H - $cb}]
		ui::label $px [expr {$bt + 22}] Contrast
		set by [expr {$bt + 44}]
		foreach chk $checks {
			lassign $chk label fk bk
			set r [pal::contrast [dict get $p $fk] [dict get $p $bk]]
			ui::badge $px $by "$label [pal::ratio_text $r] · [pal::level $r]" 0
			set by [expr {$by + 28}]
		}
	}
	set top [expr {$y + 32}]
	set ph [expr {$H - 32 - $cb}]
	if {[code_role $k]} {
		draw_code $px $top $pw $ph $p $k
		return
	}
	set h1 [expr {($ph - 12) / 2}]
	set h2 [expr {$ph - 12 - $h1}]
	if {$k eq "BAR_SHADOW"} {
		draw_bar_zoom $px $top $pw $h1 $p 1
		draw_desk $px [expr {$top + $h1 + 12}] $pw $h2 $p
	} elseif {[string match DESK_* $k]} {
		draw_desk $px $top $pw $h1 $p 0
		draw_mark_zoom $px [expr {$top + $h1 + 12}] $pw $h2 $p
	} else {
		draw_desk $px $top $pw $h1 $p
		draw_bar_zoom $px [expr {$top + $h1 + 12}] $pw $h2 $p 0
	}
	# the views are clipped at the column's edge (the bar's zoom runs past
	# it): the window's margin is the bar's colour again
	ui::fbox [expr {$px + $pw}] $y 40 $H -fill $ui::c(bar)
}

# ---- the previews ---------------------------------------------------------------

# The code and editor roles: the editor's own colours, from the Code and
# Editor groups
proc page::code_role {k} {
	expr {[string match SYN_* $k] || $k in {LINE WELL MATCH ERR VADD VMOD VDEL}}
}

# The desktop in little (STYLE §22): the wallpaper and its stripes, the
# wordmark, the bars and dock with the bar shadow, a window.
proc page::draw_desk {x y w h p {win 1}} {
	set s [expr {$w / 1440.0}]
	set HH [expr {$h / $s}]
	set x [expr {round($x)}]; set y [expr {round($y)}]
	raster::blit $ui::img [thumbs::wall $p $w $h] 0 0 $w $h $x $y
	ui::corners $x $y $w $h 10 [dict get $p BAR]
	ui::ring $x $y $w $h 10 [dict get $p BORDER] 1
	# the wordmark: DESK_MARK at its alpha over the wallpaper
	set mk [blend [dict get $p DESK_MARK] [dict get $p DESK_TOP] [dict get $p DESK_MARK_ALPHA]]
	ui::text [expr {$x + $w / 2.0}] [expr {$y + $h * 0.5 - 150 * $s * 0.62}] ribbon sg32 $mk c
	# the top bars and the dock, with the bar shadow (box-shadow: sh_half)
	foreach {bx by bw bh r key} {
		8 8 360 38 12 BAR 12 12 90 30 8 PILL 106 12 258 30 8 FIELD
		1052 8 380 38 12 BAR 1172 12 44 30 8 PILL
	} {
		draw_box [expr {$x + $bx * $s}] [expr {$y + $by * $s}] [expr {$bw * $s}] [expr {$bh * $s}] [expr {$r * $s}] [dict get $p $key] $p [expr {$key eq "BAR" ? 0.5 : 0}]
	}
	set dy0 [expr {$y + ($HH - 46) * $s}]
	draw_box [expr {$x + 560 * $s}] $dy0 [expr {320 * $s}] [expr {38 * $s}] [expr {12 * $s}] [dict get $p BAR] $p 0.5
	ui::fbox [expr {$x + 564 * $s}] [expr {$dy0 + 4 * $s}] [expr {74 * $s}] [expr {30 * $s}] -fill [dict get $p FIELD] -radius [expr {8 * $s}]
	ui::fbox [expr {$x + 572 * $s}] [expr {$y + ($HH - 12) * $s}] [expr {58 * $s}] [expr {2.5 * $s}] -fill [dict get $p ACCENT] -radius 1
	# a window with its title bar (not for the wordmark's view: win 0)
	if {$win} {
		ui::fbox [expr {$x + 470 * $s}] [expr {$y + 260 * $s}] [expr {500 * $s}] [expr {300 * $s}] -fill [dict get $p WIN] -radius [expr {12 * $s}]
		ui::ring [expr {$x + 470 * $s}] [expr {$y + 260 * $s}] [expr {500 * $s}] [expr {300 * $s}] [expr {12 * $s}] [dict get $p BORDER] 1
		ui::fbox [expr {$x + 470 * $s}] [expr {$y + 260 * $s}] [expr {500 * $s}] [expr {34 * $s}] -fill [dict get $p BAR] -radius [expr {12 * $s}]
	}
}

# One bar of the desk in little: its box, the bar shadow when it has one
proc page::draw_box {x y w h r colour p shadow} {
	# SHADOW: 0 for none, else the scale of the bar shadow's offset and blur
	set w [expr {round($w)}]; set h [expr {round($h)}]; set r [expr {round($r)}]
	if {!$shadow} {
		ui::fbox $x $y $w $h -fill $colour -radius $r
	} else {
		lassign [pal::shadow [dict get $p BAR_SHADOW]] dy blur a col
		set sc [expr {double($shadow)}]
		lassign [raster::rrect $w $h -fill $colour -radius $r -shadow [list [expr {round($dy * $sc)}] [expr {round($blur * $sc)}] $a $col]] img padx pady
		raster::blit $ui::img $img 0 0 [image width $img] [image height $img] [expr {round($x) - $padx}] [expr {round($y) - $pady}]
	}
	ui::ring $x $y $w $h $r [dict get $p BORDER] 1
}

# The wordmark at about its screen size, over the stripes
proc page::draw_mark_zoom {x y w h p} {
	raster::blit $ui::img [thumbs::wall $p $w $h] 0 0 $w $h [expr {round($x)}] [expr {round($y)}]
	ui::corners [expr {round($x)}] [expr {round($y)}] $w $h 10 [dict get $p BAR]
	ui::ring [expr {round($x)}] [expr {round($y)}] $w $h 10 [dict get $p BORDER] 1
	ui::text [expr {$x + $w / 2.0}] [expr {$y + $h / 2.0 - 30}] ribbon sg58 [blend [dict get $p DESK_MARK] [dict get $p DESK_TOP] [dict get $p DESK_MARK_ALPHA]] c
}

# A bar at one and a half times its size, so its shadow reads (the
# shadow's own offset, blur and opacity when SHADOW)
proc page::draw_bar_zoom {x y w h p {shadow 0}} {
	set x [expr {round($x)}]; set y [expr {round($y)}]
	raster::blit $ui::img [thumbs::wall $p $w $h] 0 0 $w $h $x $y
	ui::corners $x $y $w $h 10 [dict get $p BAR]
	ui::ring $x $y $w $h 10 [dict get $p BORDER] 1
	# a bar at 1.5 times, and a second one at the foot: the shadow reads at this size
	set sc [expr {$shadow ? 1.5 : 0}]
	draw_box [expr {$x + 16}] [expr {$y + 22}] 260 57 18 [dict get $p BAR] $p $sc
	ui::fbox [expr {$x + 22}] [expr {$y + 28}] 105 45 -fill [dict get $p PILL] -radius 12
	ui::fbox [expr {$x + 82}] [expr {$y + 28}] 172 45 -fill [dict get $p FIELD] -radius 12
	draw_box [expr {$x + ($w - 150) / 2.0}] [expr {$y + $h - 30 - 57}] 150 57 18 [dict get $p BAR] $p $sc
	ui::fbox [expr {$x + ($w - 150) / 2.0 + 10}] [expr {$y + $h - 30 - 4 - 3}] 64 3 -fill [dict get $p ACCENT] -radius 2
}

# The editor sample (STYLE §22; the code of the Colours boards): a gutter
# well with line numbers and change bars, the current line, a find match,
# an error, and each token in its colour. The chosen role's tokens (or its
# element) carry a ring.
#   flags: cur (current line), add, mod, del; segments: class letter, then
#   the text (@O and @C are { and }); * marks a find match, ~ an error.
#   The table is the board's own (design/tools/gen_colours.py CODE, classified
#   by gen_editor_r2.classify).
namespace eval page {
variable CODE_LINES {
	{{} {"c# Fade the " "c*mark" "c in"}}
	{{} {"kproc" "g " "ffade" "g " "p@O" "gw a" "p@C" "g " "p@O"}}
	{mod {"g  " "kset" "g c " "s\"" "v\$w" "s." "s*mark" "s\""}}
	{{} {"g  " "kset" "g steps " "n12"}}
	{cur {"g  " "kif" "g " "p@O" "v\$a" "g > " "n0.5" "p@C" "g " "p@O"}}
	{{} {"g    " "v\$c" "g configure " "p\\"}}
	{add {"g      " "o-fill" "g " "s\"#FFFFFF\""}}
	{del {"g  " "p@C"}}
	{{} {"g  " "kafter" "g " "n40" "g " "p\[" "gfade " "v\$w" "p\]"}}
	{mod {"g  " "g~retrun" "g " "v\$steps"}}
	{{} {"p@C"}}
	{{} {}}
	{{} {"ffade" "g .desk " "n0.065"}}
}
variable CODE_CLASS {SYN_COM c SYN_KW k SYN_FN f SYN_VAR v SYN_STR s SYN_NUM n SYN_OPT o SYN_PUN p}
variable CODE_CLASS_COLOUR {c SYN_COM k SYN_KW f SYN_FN v SYN_VAR s SYN_STR n SYN_NUM o SYN_OPT p SYN_PUN g FG}
}


proc page::draw_code {x y w h p k} {
	variable CODE_LINES
	variable CODE_CLASS
	variable CODE_CLASS_COLOUR
	set GW 30
	set LH 20
	set bg [dict get $p BAR]
	set mute [dict get $p MUTED]
	# the chosen token's class (a letter), when the role is a token
	set want ""
	if {[dict exists $CODE_CLASS $k]} { set want [dict get $CODE_CLASS $k] }
	ui::fbox $x $y $w $h -fill $bg -radius 10
	ui::fbox $x $y $GW $h -fill [blend [dict get $p WELL] $bg [dict get $p WELL_ALPHA]] -radius 10
	if {$k eq "WELL"} { ui::ring $x $y $GW $h 10 $mute 1 }
	set i 0
	set ly [expr {$y + 10}]
	foreach line $CODE_LINES {
		lassign $line flags segs
		set cur [expr {$flags eq "cur"}]
		if {$cur} {
			ui::fbox [expr {$x + $GW}] $ly [expr {$w - $GW}] $LH -fill [dict get $p LINE]
			if {$k eq "LINE"} { ui::ring [expr {$x + $GW}] $ly [expr {$w - $GW}] $LH 3 $mute 1 }
		}
		ui::text [expr {$x + $GW - 8}] [expr {$ly + 4}] [expr {$i + 1}] mono10 [expr {$cur ? [dict get $p FG] : [dict get $p SYN_NUM0]}] e
		switch -- $flags {
			mod { ui::fbox [expr {$x + $GW - 3}] [expr {$ly + 2}] 2 [expr {$LH - 4}] -fill [dict get $p VMOD] -radius 1
				if {$k eq "VMOD"} { ui::ring [expr {$x + $GW - 4}] [expr {$ly + 1}] 4 [expr {$LH - 2}] 2 $mute 1 } }
			add { ui::fbox [expr {$x + $GW - 3}] [expr {$ly + 2}] 2 [expr {$LH - 4}] -fill [dict get $p VADD] -radius 1
				if {$k eq "VADD"} { ui::ring [expr {$x + $GW - 4}] [expr {$ly + 1}] 4 [expr {$LH - 2}] 2 $mute 1 } }
			del { tri [expr {$x + $GW - 4}] [expr {$ly + $LH - 4}] [dict get $p VDEL]
				if {$k eq "VDEL"} { ui::ring [expr {$x + $GW - 6}] [expr {$ly + $LH - 6}] 9 12 2 $mute 1 } }
		}
		# the segments; a run of the chosen token's class is ringed as one
		set cx [expr {$x + $GW + 16}]
		set run {}
		set inq 0    ;# inside a string: a variable in it is part of the string's ring
		foreach seg $segs {
			set cl [string index $seg 0]
			set mark [string index $seg 1]
			set text [string range $seg [expr {$mark in {* ~} ? 2 : 1}] end]
			set text [string map {@O \{ @C \}} $text]
			if {$cl eq "~"} { set cl g }
			set colour [dict get $p [dict get $CODE_CLASS_COLOUR $cl]]
			# a function name is bold (the board's font-weight 700)
			set sf [expr {$cl eq "f" ? "mono12b" : "mono12"}]
			set sw [ui::measure $sf $text]
			if {$mark eq "*"} {
				ui::fbox $cx [expr {$ly + 2}] $sw [expr {$LH - 4}] -fill [blend [dict get $p MATCH] $bg [dict get $p MATCH_ALPHA]] -radius 2
				if {$k eq "MATCH"} { ui::ring $cx [expr {$ly + 2}] $sw [expr {$LH - 4}] 2 $mute 1 }
			}
			if {$mark eq "~"} {
				wave $cx [expr {$ly + $LH - 1}] $sw [dict get $p ERR]
				if {$k eq "ERR"} { ui::ring $cx [expr {$ly + 2}] $sw [expr {$LH - 4}] 2 $mute 1 }
			}
			ui::text $cx [expr {$ly + 4}] $text $sf $colour
			if {$want ne "" && ($cl eq $want || ($want eq "s" && $cl eq "v" && $inq))} { lappend run [list $cx $sw] }
			if {$cl eq "s"} { set inq [expr {($inq + [regexp -all {"} $text]) % 2}] }
			set cx [expr {$cx + $sw}]
		}
		foreach {rx rw} [join_runs $run] { ui::ring $rx [expr {$ly + 2}] $rw [expr {$LH - 4}] 3 $mute 1 }
		set ly [expr {$ly + $LH}]
		incr i
	}
}

# The board's "underline wavy", 1 px thick: a sine of 6 px period and 1.5 px swing, W wide, centred on Y.
proc page::wave {x y w colour} {
	set S [expr {int(ceil($w))}]
	if {$S < 4} return
	set u [expr {24.0 / $S}]
	set mid [expr {$S / 2.0}]
	set d "M0 [expr {$mid * $u}]"
	set up 1
	for {set px 0} {$px < $S} {incr px 3} {
		set dy [expr {$up ? -1.5 : 1.5}]
		append d [format " C%.3f %.3f %.3f %.3f %.3f %.3f" [expr {($px + 1.0) * $u}] [expr {($mid + $dy) * $u}] \
			[expr {($px + 2.0) * $u}] [expr {($mid + $dy) * $u}] [expr {($px + 3) * $u}] [expr {$mid * $u}]]
		set up [expr {!$up}]
	}
	set i [raster::icon $d $S $u [ui::col $colour]]
	$ui::cv create image [expr {round($x)}] [expr {round($y - $mid)}] -image $i -anchor nw -tags page
}

# The board's deleted-lines mark: a filled triangle 5 wide and 8 tall, pointing right, its top at Y.
proc page::tri {x y colour} {
	set i [raster::icon {M0 0L15 12L0 24z} 8 0.01 [ui::col $colour] {} 0 0 1]
	$ui::cv create image [expr {round($x)}] [expr {round($y)}] -image $i -anchor nw -tags page
}

# Adjacent {x w} runs of a token's segments as one run each: {x w ...}
proc page::join_runs {runs} {
	set out {}
	foreach r $runs {
		lassign $r x w
		if {[llength $out] && [expr {[lindex $out end-1] + [lindex $out end]}] == $x} {
			lset out end [expr {[lindex $out end] + $w}]
		} else {
			lappend out $x $w
		}
	}
	return $out
}

# A 12 px slider track SW wide at SX TY with its gradient and white knob at
# FRAC; it takes clicks and drags from HY, HH tall. GRAD: hue | {grad #a #b}
# | {alpha #hex} (transparent to the colour, over a checkerboard).
proc page::track {id sx ty sw frac grad hy hh} {
	array set c [array get ui::c]
	set g [ui::mem [list track $sw $grad [ui::col $c(bar)]] {
		set rows {}
		if {[lindex $grad 0] eq "alpha"} {
			lassign [pal::rgb [lindex $grad 1]] hr hg hb
			for {set j 0} {$j < 12} {incr j} {
				set out {}
				for {set i 0} {$i < $sw} {incr i} {
					set t [expr {($i + 0.5) / $sw}]
					set cv [expr {((($i / 8) + ($j / 8)) % 2) ? 154.0 : 106.0}]
					set a [raster::rbox [expr {$i + 0.5}] [expr {$j + 0.5}] 0 0 $sw 12 6]
					foreach ch [list $hr $hg $hb] { lappend out [expr {int($ch * $t + $cv * (1 - $t) + 0.5)}] }
					lappend out [expr {int($a * 255 + 0.5)}]
				}
				lappend rows $out
			}
		} else {
			if {$grad eq "hue"} {
				set stops {0 #FF0000 0.17 #FFFF00 0.33 #00FF00 0.5 #00FFFF 0.67 #0000FF 0.83 #FF00FF 1 #FF0000}
			} else {
				set stops [list 0 [lindex $grad 1] 1 [lindex $grad 2]]
			}
			set row {}
			for {set i 0} {$i < $sw} {incr i} {
				set t [expr {($i + 0.5) / $sw}]
				foreach {t0 c0} [lrange $stops 0 end-2] {t1 c1} [lrange $stops 2 end] {
					if {$t1 eq ""} break
					if {$t >= $t0 && $t <= $t1} break
				}
				set k [expr {($t - $t0) / ($t1 - $t0)}]
				lassign [pal::rgb $c0] r0 g0 b0; lassign [pal::rgb $c1] r1 g1 b1
				lappend row [list [expr {$r0 + ($r1 - $r0) * $k}] [expr {$g0 + ($g1 - $g0) * $k}] [expr {$b0 + ($b1 - $b0) * $k}]]
			}
			for {set j 0} {$j < 12} {incr j} {
				set out {}
				set i 0
				foreach px $row {
					set a [raster::rbox [expr {$i + 0.5}] [expr {$j + 0.5}] 0 0 $sw 12 6]
					lassign $px r g b
					lappend out [expr {int($r + 0.5)}] [expr {int($g + 0.5)}] [expr {int($b + 0.5)}] [expr {int($a * 255 + 0.5)}]
					incr i
				}
				lappend rows $out
			}
		}
		raster::png $sw 12 $rows
	}]
	raster::blit $ui::img $g 0 0 $sw 12 [expr {round($sx)}] [expr {round($ty)}]
	marker [expr {$sx + $frac * $sw}] [expr {$ty + 6}] #FFFFFF
	ui::hit $sx $hy $sw $hh [list page::slide $id $sx $sw] [list page::slide $id $sx $sw]
	ui::focusable $id slider $sx $ty $sw 12 6 [list page::slider_key $id]
}

proc page::slider_set {id frac} {
	variable S
	set frac [expr {max(0.0, min(1.0, $frac))}]
	switch -- $id {
		shDY - shBLUR - shA {
			# the shadow's offset (-32..32), blur (0..48) and opacity
			lassign [pal::shadow [dict get $S(epal) BAR_SHADOW]] dy blur a c
			switch -- $id {
				shDY { set dy [expr {round($frac * 64) - 32}] }
				shBLUR { set blur [expr {round($frac * 48)}] }
				shA { set a [expr {round($frac * 100) / 100.0}] }
			}
			dict set S(epal) BAR_SHADOW [pal::shadow_make $dy $blur $a $c]
			set S(dirty) 1
			draw
			return
		}
	}
	lassign [pal::rgb [cur_colour]] r g b
	switch -- $id {
		hue - chH { set_hsv [expr {$frac * 360}] $S(s) $S(v) }
		chR { set_colour [pal::hex [expr {$frac * 255}] $g $b] }
		chG { set_colour [pal::hex $r [expr {$frac * 255}] $b] }
		chB { set_colour [pal::hex $r $g [expr {$frac * 255}]] }
		chS {
			if {$S(mode) eq "hsl"} {
				lassign [pal::rgb2hsl $r $g $b] - - l
				set_colour [pal::hex {*}[pal::hsl2rgb $S(h) $frac $l]] 1
				lassign [pal::rgb2hsv {*}[pal::rgb [cur_colour]]] - S(s) S(v)
				draw
			} else { set_hsv $S(h) $frac $S(v) }
		}
		chL {
			lassign [pal::rgb2hsl $r $g $b] - s2 -
			set_colour [pal::hex {*}[pal::hsl2rgb $S(h) $s2 $frac]] 1
			lassign [pal::rgb2hsv {*}[pal::rgb [cur_colour]]] - S(s) S(v)
			draw
		}
		chV { set_hsv $S(h) $S(s) $frac }
		alpha { set_alpha $frac }
	}
}

proc page::slider_value {id} {
	variable S
	switch -- $id {
		shDY { lassign [pal::shadow [dict get $S(epal) BAR_SHADOW]] dy; return [list [expr {($dy + 32) / 64.0}] 64] }
		shBLUR { lassign [pal::shadow [dict get $S(epal) BAR_SHADOW]] - blur; return [list [expr {$blur / 48.0}] 48] }
		shA { lassign [pal::shadow [dict get $S(epal) BAR_SHADOW]] - - a; return [list $a 100] }
		alpha {
			set ak [akey]
			if {$ak eq ""} { return [list 0 100] }
			return [list [dict get $S(epal) $ak] 100]
		}
	}
	lassign [pal::rgb [cur_colour]] r g b
	switch -- $id {
		hue - chH { return [list [expr {$S(h) / 360.0}] 360] }
		chR { return [list [expr {$r / 255.0}] 255] }
		chG { return [list [expr {$g / 255.0}] 255] }
		chB { return [list [expr {$b / 255.0}] 255] }
		chS { if {$S(mode) eq "hsl"} { return [list [lindex [pal::rgb2hsl $r $g $b] 1] 100] }; return [list $S(s) 100] }
		chL { return [list [lindex [pal::rgb2hsl $r $g $b] 2] 100] }
		chV { return [list $S(v) 100] }
	}
}

# The number boxes: type a number (Enter sets it), or Up / Down. A typed
# offset is the value itself, so 20 is 20 px.
proc page::num_key {id sym {char ""}} {
	variable S
	lassign [slider_value $id] v n
	if {![info exists S(numbuf)]} { set S(numbuf) "" }
	switch -- $sym {
		Up { slider_set $id [expr {$v + 1.0 / $n}]; return 1 }
		Down { slider_set $id [expr {$v - 1.0 / $n}]; return 1 }
		BackSpace { set S(numbuf) [string range $S(numbuf) 0 end-1]; draw; return 1 }
		Return - KP_Enter {
			if {$S(numbuf) ne ""} {
				if {$id eq "shDY"} { slider_set $id [expr {($S(numbuf) + 32) / 64.0}] } else { slider_set $id [expr {$S(numbuf) / double($n)}] }
			}
			set S(numbuf) ""; draw; return 1
		}
		Escape { set S(numbuf) ""; draw; return 1 }
	}
	if {[string is digit -strict $char] && [string length $S(numbuf)] < 3} { append S(numbuf) $char; draw; return 1 }
	return 0
}


# Choose the role to edit; the picker takes its colour.

# The picker's H S V from a colour (H kept when the colour is grey).

# What the picker edits: a colour role of the theme (the Colours page), or
# another colour (S(ptarget): a command that gets "get" or "set HEX"; the
# background sheet's Colour tab). Both pickers are this code.

# Set the colour (from the picker); keys that follow a role follow it.


proc page::roles_labels {} {
	set out {}
	foreach {k l a} $pal::ROLES { dict set out $k [list $l $a] }
	return $out
}

proc page::alpha_text {a} { return "[expr {round($a * 100)}]%" }

# The saturation / value square at the role's hue, with its marker.
proc page::picker_sv {x y w h {knob {2 6 0.5}}} {
	variable S
	set hue [pal::hex {*}[pal::hsv2rgb $S(h) 1 1]]
	set sq [ui::mem [list sv $w $h $hue] {
		# linear-gradient(0deg, #000, transparent) over
		# linear-gradient(90deg, #fff, hue)
		lassign [pal::rgb $hue] hr hg hb
		set rows {}
		for {set j 0} {$j < $h} {incr j} {
			set k [expr {1.0 - ($j + 0.5) / $h}]
			set row {}
			for {set i 0} {$i < $w} {incr i} {
				set t [expr {($i + 0.5) / $w}]
				lappend row [expr {int((255 + ($hr - 255) * $t) * $k + 0.5)}] [expr {int((255 + ($hg - 255) * $t) * $k + 0.5)}] \
					[expr {int((255 + ($hb - 255) * $t) * $k + 0.5)}] 255
			}
			lappend rows $row
		}
		raster::png $w $h $rows
	}]
	raster::blit $ui::img $sq 0 0 $w $h [expr {round($x)}] [expr {round($y)}]
	ui::corners [expr {round($x)}] [expr {round($y)}] $w $h 10 $ui::c(bar)
	set mx [expr {$x + $S(s) * $w}]; set my [expr {$y + (1 - $S(v)) * $h}]
	marker $mx $my [cur_colour] 1 $knob
	ui::hit [expr {round($x)}] [expr {round($y)}] $w $h [list page::sv_drag $x $y $w $h] [list page::sv_drag $x $y $w $h]
	ui::focusable sv area [expr {round($x)}] [expr {round($y)}] $w $h 10 page::sv_key
}

proc page::sv_drag {x0 y0 w h x y} {
	variable S
	set ui::focus sv
	set_hsv $S(h) [expr {($x - $x0) / double($w)}] [expr {1 - ($y - $y0) / double($h)}]
}
proc page::sv_key {sym} {
	variable S
	switch -- $sym {
		Left { set_hsv $S(h) [expr {$S(s) - 0.01}] $S(v) }
		Right { set_hsv $S(h) [expr {$S(s) + 0.01}] $S(v) }
		Up { set_hsv $S(h) $S(s) [expr {$S(v) + 0.01}] }
		Down { set_hsv $S(h) $S(s) [expr {$S(v) - 0.01}] }
		default { return 0 }
	}
	return 1
}

# A 16 px handle: white with a shadow (sliders), or the colour in a 2 px
# white ring (the square's marker).
proc page::marker {cx cy colour {ringed 0} {shadow {2 6 0.5}}} {
	set d [expr {$ringed ? 20 : 16}]
	set x [expr {$cx - $d / 2.0}]; set y [expr {$cy - $d / 2.0}]
	set ix [expr {int(floor($x))}]; set iy [expr {int(floor($y))}]
	set fx [expr {round(($x - $ix) * 4) / 4.0}]; set fy [expr {round(($y - $iy) * 4) / 4.0}]
	lassign [raster::rrect $d $d -fill #FFFFFF -radius [expr {$d / 2.0}] -shadow $shadow -offset [list $fx $fy]] img padx pady
	raster::blit $ui::img $img 0 0 [image width $img] [image height $img] [expr {$ix - $padx}] [expr {$iy - $pady}]
	if {$ringed} { ui::fbox [expr {$cx - 8}] [expr {$cy - 8}] 16 16 -fill $colour -radius 8 }
}

# A row: the letter, a 12 px slider with its gradient and handle at
# FRAC, the number in a 52 x 28 box. GRAD: hue | {grad #a #b}.
proc page::slider_row {id letter x y w frac num grad} {
	variable S
	array set c [array get ui::c]
	ui::text $x [expr {$y + 6.5}] $letter i12b $c(muted)
	set sx [expr {$x + 26}]; set sw [expr {$w - 26 - 12 - 52}]
	track $id $sx [expr {$y + 8}] $sw $frac $grad [expr {$y - 2}] 32
	# the number
	set nx [expr {$x + $w - 52}]
	set on [expr {$ui::focus eq "n$id"}]
	ui::box $nx $y 52 28 -fill $c(field) -radius 7
	if {$on} { ui::ring $nx $y 52 28 7 $c(accent) 1.5 }
	set shown [expr {$on && [info exists S(numbuf)] && $S(numbuf) ne "" ? $S(numbuf) : $num}]
	ui::text [expr {$nx + 26}] [expr {$y + 6}] $shown i13 $c(fg) c 0 {} 1
	ui::hit $nx $y 52 28 [list apply {{id x y} { set ::page::S(numbuf) ""; set ui::focus n$id; page::draw }} $id]
	ui::focusable n$id num $nx $y 52 28 7 [list page::num_key $id]
}

# A 12 px slider track SW wide at SX TY with its gradient and white knob at
# FRAC; it takes clicks and drags from HY, HH tall.

proc page::channel_grad {ch mode} {
	variable S
	set h $S(h)
	lassign [pal::rgb [cur_colour]] r g b
	switch $ch {
		H { return hue }
		S {
			if {$mode eq "hsl"} { lassign [pal::rgb2hsl $r $g $b] - - l; return [list grad [pal::hex {*}[pal::hsl2rgb $h 0 $l]] [pal::hex {*}[pal::hsl2rgb $h 1 $l]]] }
			return [list grad [pal::hex {*}[pal::hsv2rgb $h 0 $S(v)]] [pal::hex {*}[pal::hsv2rgb $h 1 $S(v)]]]
		}
		L { return [list grad #000000 #FFFFFF] }
		V { return [list grad #000000 [pal::hex {*}[pal::hsv2rgb $h $S(s) 1]]] }
	}
}

# A slider's value from 0..1.
proc page::slide {id sx sw x y} {
	set ui::focus $id
	slider_set $id [expr {($x - $sx) / double($sw)}]
}
proc page::slider_key {id sym} {
	lassign [slider_value $id] v n
	set step [expr {1.0 / $n}]
	switch -- $sym {
		Left - Down { slider_set $id [expr {$v - $step}] }
		Right - Up { slider_set $id [expr {$v + $step}] }
		Prior { slider_set $id [expr {$v + 10 * $step}] }
		Next { slider_set $id [expr {$v - 10 * $step}] }
		Home { slider_set $id 0 }
		End { slider_set $id 1 }
		default { return 0 }
	}
	return 1
}
# The number boxes: type a number (Enter or Tab sets it), or Up / Down.

proc page::mode {m} {
	variable S
	set S(mode) $m
	draw
}

proc page::role_key {sym} {
	variable S
	set keys [lmap {k l a} $pal::ROLES { set k }]
	set i [lsearch -exact $keys $S(role)]
	switch -- $sym {
		Up { set i [expr {max(0, $i - 1)}] }
		Down { set i [expr {min([llength $keys] - 1, $i + 1)}] }
		Home { set i 0 }
		End { set i [expr {[llength $keys] - 1}] }
		default { return 0 }
	}
	role [lindex $keys $i]
	return 1
}

proc page::hex_typed {} {
	set v [string trim [ui::fval hex]]
	if {[string index $v 0] ne "#"} { set v #$v }
	if {[regexp {^#[0-9A-Fa-f]{6}$} $v]} {
		set cur $ui::fld(hex,cur)
		set_colour $v
		ui::fset hex [ui::fval hex]
		set ui::fld(hex,cur) $cur
	}
}
proc page::hex_done {} {
	variable S
	hex_typed
	ui::fset hex [cur_colour]
	draw
}

proc page::discard {} {
	variable S
	edit_start $S(sel)
	draw
}

# Save the edits as a new theme of yours (the banner's name for a
# built-in), and go on with that one.
proc page::save_new {} {
	variable S
	set t [store::get $S(sel)]
	set name [expr {[dict get $t builtin] ? [string trim [ui::fval newname]] : "[dict get $t name] copy"}]
	if {$name eq ""} { set name "[dict get $t name] (mine)" }
	if {[catch {store::save_new $name $S(epal)} id]} { dlg::message "Can't save it" $id; return "" }
	set S(dirty) 0
	set S(sel) $id
	set S(edit) ""
	edit_start $id
	chrome
	draw
	return $id
}

# Save the edits over your own theme.
proc page::save {} {
	variable S
	if {[store::get $S(sel) builtin]} { return [save_new] }
	if {[catch {store::save $S(sel) $S(epal)} err]} { dlg::message "Can't save it" $err; return "" }
	set S(dirty) 0
	set S(epal) [store::get $S(sel) pal]
	chrome
	draw
	return $S(sel)
}

# ---- Apply and Revert ---------------------------------------------------------------

# Apply the chosen theme (saving unsaved edits first) and the backgrounds,
# to where the footer's switches say.
proc page::apply {} {
	variable S
	if {$S(busy)} return
	if {$S(dirty)} {
		if {[save] eq ""} return
	}
	set id $S(sel)
	set jobs {}
	if {$S(todesk)} { lappend jobs [list desktop [list apply $id --quiet --no-login]] }
	lappend jobs [list "" [list login follow [expr {$S(tologin) ? "yes" : "no"}]]]
	if {$S(tologin)} { lappend jobs [list "login screen" [list login $id]] }
	lappend jobs {*}[bg::apply_jobs $S(todesk) $S(tologin)]
	run_jobs $jobs [list page::applied $id]
}

proc page::applied {id errs} {
	variable S
	if {$S(todesk)} { set S(applied) $id; chrome }
	if {[llength $errs]} {
		dlg::message "Not everything was applied" [join $errs \n]
	}
	draw
}

# Run ribbon-theme jobs one after another without freezing the window
# (polkit may ask for a password); then DONE with the problems.
proc page::run_jobs {jobs done {errs {}}} {
	variable S
	if {![llength $jobs]} {
		set S(busy) 0
		. configure -cursor {}
		uplevel #0 [list {*}$done $errs]
		return
	}
	set S(busy) 1
	lassign [lindex $jobs 0] what args
	set rest [lrange $jobs 1 end]
	set c [store::cmd]
	set argv [expr {[file exists $c] && ![file executable $c] ? [list bash $c] : [list $c]}]
	if {[catch {open |[list {*}$argv {*}$args </dev/null 2>@1] r} fh]} {
		if {$what ne ""} { lappend errs "$what: $fh" }
		run_jobs $rest $done $errs
		return
	}
	fconfigure $fh -blocking 0
	set ::page::out($fh) ""
	fileevent $fh readable [list page::job_read $fh $what $rest $done $errs]
}
proc page::job_read {fh what rest done errs} {
	variable out
	append out($fh) [read $fh]
	if {![eof $fh]} return
	fconfigure $fh -blocking 1
	set failed [catch {close $fh}]
	if {$failed && $what ne ""} { lappend errs "$what: [string trim $out($fh)]" }
	unset out($fh)
	run_jobs $rest $done $errs
}

# Back to how things were when the app started: the theme and backgrounds
# chosen then, applied again if Apply changed them since.
proc page::revert {} {
	variable S
	variable launch
	set S(edit) ""; set S(dirty) 0; set S(rename) ""
	set id [dict get $launch theme]
	if {![store::exists $id]} { set id [lindex [store::ids] 0] }
	set S(sel) $id
	set S(tologin) [dict get $launch tologin]
	bg::restore [dict get $launch bg]
	chrome
	reveal
	set follow [expr {$S(tologin) ? "yes" : "no"}]
	if {$S(applied) ne $id || [bg::applied_since] || [store::conf_get LOGIN_FOLLOWS_THEME yes] ne $follow} {
		set jobs [list [list "" [list login follow $follow]]]
		if {$S(applied) ne $id} { lappend jobs [list desktop [list apply $id --quiet --no-login]] }
		lappend jobs {*}[bg::apply_jobs 1 0]
		run_jobs $jobs [list page::applied $id]
	}
	draw
}

# ---- keys ------------------------------------------------------------------------

proc page::clicked_outside {} {
	variable dialog
	variable S
	if {$dialog ne ""} return
	if {$S(rename) ne ""} { set S(rename) ""; draw; return }
	if {[lindex [ui::focused] 1] in {field num}} { set ui::focus ""; draw }
}

proc page::double {x y} {
	variable S
	variable dialog
	if {$dialog ne "" || $S(page) ne "theme"} return
	set x [expr {$x - $ui::ox}]; set y [expr {$y - $ui::oy}]
	if {$x >= 270 && $x < 466 && $y >= 140 && $y < 560} {
		set t [store::get $S(sel)]
		if {![dict get $t builtin]} { rename_start $S(sel) } else { go colours }
	}
}

proc page::key {sym char state} {
	variable S
	variable dialog
	variable pages
	update idletasks
	if {$dialog ne ""} { dlg::key $sym $char $state; return }
	set f [ui::focused]
	lassign $f id kind
	set ctrl [expr {$state & 4}]
	set alt [expr {$state & 8}]
	if {$ctrl && $sym in {q Q w W}} { quit }
	if {$ctrl && $sym in {s S} && $S(page) eq "colours"} { save; return }
	if {$alt && [string match {[1-4]} $sym]} { go [lindex [keys] [expr {$sym - 1}]]; return }
	switch -- $sym {
		Tab { if {$state & 1} { ui::cycle -1 } else { ui::cycle 1 }; return }
		ISO_Left_Tab { ui::cycle -1; return }
	}
	if {$kind eq "field"} {
		if {$sym eq "Escape"} {
			if {$id eq "rename"} { set S(rename) ""; set ui::focus themes } else { set ui::focus "" }
			if {$id eq "hex"} { hex_done }
			draw; return
		}
		if {[ui::field_key $id $sym $char $state]} { draw }
		return
	}
	if {$kind eq "num"} {
		if {[page::num_key [string range $id 1 end] $sym $char]} return
	}
	if {$kind in {button toggle check} && $sym in {Return KP_Enter space}} { uplevel #0 [lindex $f 7]; return }
	if {$kind in {list seg slider area} && [uplevel #0 [list {*}[lindex $f 7] $sym]]} return
	switch -- $sym {
		Escape { if {$S(page) ne "theme"} { go theme } }
		Prior { if {$ctrl} { rail_key Up } }
		Next { if {$ctrl} { rail_key Down } }
	}
}
