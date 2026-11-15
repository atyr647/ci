# page.tcl - the Catalogue window, drawn as its boards (design/mockups/Catalogue-1..8,
# design/tools/gen_catalogue.py): Properties' Rail window (properties/pages.tcl) with the
# catalogue's sources in the rail; the list of apps with the search field; an app's page with its
# strip, facts, requests and footer; kit's prompt as Properties' sheet (Kit-Sheet-1); the
# download in the footer. It draws source.tcl's model and calls its actions.
#
# Positions are the boards', inside the 1100 x 720 window: the rail is 230 wide, the page's
# content runs from x 270 to 1060 and starts at y 119, the footer is the bottom 72 px.

namespace eval page {
	variable WH 720
	variable nav all        ;# all | kits | flathub | installed
	variable view list      ;# list | app
	variable off 0          ;# the list's first item shown
	variable dialog ""      ;# kit's prompt (kind plan) or a message (dialogs.tcl)
	variable sheetoff 0
	variable items {}       ;# the list as drawn: {kind data}...
	variable theme_mtime ""
	variable NAV {all grid {All apps} kits box {Ribbon kits} flathub layers Flathub installed check Installed}
}
array set ui::paths {
	back   {M15 18l-6-6 6-6}
	search {M4 11a7 7 0 1 0 14 0a7 7 0 1 0 -14 0 M21 21l-4.3-4.3}
	check  {M20 6L9 17l-5-5}
	download {M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4 M7 10l5 5 5-5 M12 15V3}
	image  {M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z M8.5 10a1.5 1.5 0 1 0 0-3a1.5 1.5 0 1 0 0 3z M21 15l-5-5L5 21}
	file   {M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z M14 3v5h5}
	folder {M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z}
	brush  {M12 19l7-7 3 3-7 7-3-3z M18 13l-1.5-7.5L2 2l3.5 14.5L13 18l5-5z M2 2l7.586 7.586 M11 11a2 2 0 1 0 0-4a2 2 0 1 0 0 4z}
	db     {M12 8c4.42 0 8-1.34 8-3s-3.58-3-8-3-8 1.34-8 3 3.58 3 8 3z M4 5v14c0 1.66 3.58 3 8 3s8-1.34 8-3V5 M4 12c0 1.66 3.58 3 8 3s8-1.34 8-3}
	wine   {M8 22h8 M12 15v7 M5 2h14l-1 7a6 6 0 0 1-12 0z}
	chat   {M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z}
	ext    {M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6 M15 3h6v6 M10 14L21 3}
}

proc page::chrome {} {
	array set p [array get theme::c]
	ui::colours [dict create BAR $p(BAR) FIELD $p(FIELD) PILL $p(PILL) BORDER $p(BORDER) FG $p(FG) MUTED $p(MUTED) \
		ACCENT $p(ACCENT) ON_ACCENT $p(ON_ACCENT) DESK_TOP $p(DESK_TOP) DESK_BOTTOM $p(DESK_BOTTOM) \
		DESK_STRIPE $p(DESK_STRIPE) DESK_STRIPE_ALPHA $p(DESK_STRIPE_ALPHA)]
}
proc page::palette_file {} {
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/"}]
	set cfg [expr {[info exists ::env(XDG_CONFIG_HOME)] ? $::env(XDG_CONFIG_HOME) : "$home/.config"}]
	file join $cfg ribbon palette.conf
}
proc page::watch_theme {} {
	variable theme_mtime
	set m [expr {[catch {file mtime [palette_file]} t] ? "" : $t}]
	if {$theme_mtime ne "" && $m ne $theme_mtime} { theme::load; chrome; draw }
	set theme_mtime $m
	after 2000 page::watch_theme
}
proc page::quit {} { exit 0 }

# ---- drawing -------------------------------------------------------------------------------

proc page::draw {} {
	variable pending
	if {[info exists pending] && $pending ne ""} return
	set pending [after idle page::draw_now]
}
proc page::draw_now {} {
	variable pending ""
	variable view
	variable dialog
	set ui::dim [expr {$dialog eq "" ? 0 : ([dict get $dialog kind] eq "plan" ? 0.5 : 0.35)}]
	ui::begin frame[expr {$view eq "app"}] page::frame_boxes
	rail
	if {$view eq "app"} { draw_app } else { draw_list }
	ui::focus_ring
	if {$dialog ne ""} {
		set ui::dim 0
		if {[dict get $dialog kind] eq "plan"} { sheet_draw } else { dlg::draw }
	}
	ui::finish
}

# The window and the rail (once per palette); an app's page has the footer's line.
proc page::frame_boxes {} {
	variable WH
	variable view
	array set c [array get ui::c]
	ui::box 0 0 1100 $WH -fill $c(bar) -radius [ui::outer_radius 16] -ring [list $c(border) 1]
	ui::box 0 0 230 $WH -fill $c(d2) -radius [ui::outer_radius {16 0 0 16}]
	ui::box 229 0 1 $WH -fill $c(border)
	if {$view eq "app"} { ui::hline 230 1100 [expr {$WH - 72}] $c(border) }
}

proc page::clip {f str w {ls 0}} {
	if {[ui::measure $f $str $ls] <= $w} { return $str }
	while {$str ne "" && [ui::measure $f "$str…" $ls] > $w} { set str [string range $str 0 end-1] }
	return "[string trimright $str]…"
}

# The rail: the catalogue's tile, name and what it holds, then the sources and Installed.
proc page::rail {} {
	variable nav
	variable view
	variable NAV
	array set c [array get ui::c]
	w::tile 24 26 box
	ui::text 80 26 Catalogue sg20 $c(fg) w -0.4
	ui::text 80 53 {Kits and Flathub} i12 $c(muted)
	set k 0
	foreach {key ic label} $NAV {
		set y [expr {96 + 44 * $k}]
		set on [expr {$nav eq $key}]
		if {$on} {
			ui::box 16 $y 198 40 -fill $c(field) -radius 10
			ui::box 16 [expr {$y + 10}] 3 20 -fill $c(accent) -radius 2
		}
		ui::icon $ic 16 [expr {$on ? $c(accent) : $c(muted)}] 28 [expr {$y + 12}]
		ui::text 56 [expr {$y + 12}] $label [expr {$on ? "i13s" : "i13m"}] [expr {$on ? $c(fg) : $c(muted)}]
		ui::hit 16 $y 198 40 [list apply {{k x y} { page::go $k }} $key]
		incr k
	}
	set keys [lmap {k - -} $NAV { set k }]
	ui::focusable rail list 16 [expr {96 + 44 * [lsearch -exact $keys $nav]}] 198 40 10 page::rail_key
}
proc page::go {key} {
	variable nav $key
	variable view list
	variable off 0
	draw
}
proc page::rail_key {sym} {
	variable nav
	variable NAV
	set keys [lmap {k - -} $NAV { set k }]
	set i [lsearch -exact $keys $nav]
	switch -- $sym {
		Up { set i [expr {max(0, $i - 1)}] }
		Down { set i [expr {min([llength $keys] - 1, $i + 1)}] }
		default { return 0 }
	}
	go [lindex $keys $i]
	set ui::focus rail
	return 1
}

# ---- the list (Catalogue-1-Browse, -2-Search) ---------------------------------------------------

proc page::navtitle {} {
	variable NAV
	variable nav
	lindex $NAV [expr {[lsearch -exact $NAV $nav] + 2}]
}
# "6 kits · 2,614 on Flathub"; while a source is still loading, what it has so far
proc page::commas {n} {
	set s ""
	while {$n >= 1000} { set s ",[format %03d [expr {$n % 1000}]]$s"; set n [expr {$n / 1000}] }
	return "$n$s"
}
proc page::count_line {K F} {
	variable nav
	set out {}
	if {$nav ne "flathub" && $cat::kitstate eq "ready"} { lappend out "[commas [llength $K]] kit[expr {[llength $K] == 1 ? "" : "s"}]" }
	if {$nav ne "kits" && $cat::flatstate eq "ready"} { lappend out "[commas [llength $F]] on Flathub" }
	join $out " · "
}

proc page::draw_list {} {
	variable off
	variable items
	variable nav
	array set c [array get ui::c]
	lassign [cat::matching $nav [ui::fval q]] K F
	ui::text 270 34 [navtitle] sg28 $c(fg) w -0.56
	ui::text 270 [ui::lh 76 i14 21 1] [count_line $K $F] i14 $c(muted) w 0 {} 1
	# the search field: the board's 280 x 38, the glyph 12 in, the text 37 in
	ui::field q 780 34 280 -ph {Search apps} -pad 37 -onchange {set page::off 0; page::draw} -onenter page::open_first
	ui::icon search 15 [expr {$ui::focus eq "q" ? $c(accent) : $c(muted)}] 792 45.5
	# the items: a source's label (22), its rows (60 each), 22 between the sources
	set items {}
	if {$nav ne "flathub" && [llength $K]} {
		lappend items [list label {Ribbon kits}]
		foreach r $K { lappend items [list row $r] }
	}
	if {$nav ne "kits" && [llength $F]} {
		if {[llength $items]} { lappend items {gap {}} }
		lappend items [list label Flathub]
		foreach r $F { lappend items [list row $r] }
	}
	set off [expr {max(0, min($off, [llength $items] - 1))}]
	set y 119
	set n 0
	for {set i $off} {$i < [llength $items] && $y + 50 <= $::page::WH} {incr i} {
		lassign [lindex $items $i] kind d
		switch -- $kind {
			label { ui::label 270 $y $d; set y [expr {$y + 22}] }
			gap { set y [expr {$y + 22}] }
			row {
				set next [lindex $items [expr {$i + 1}] 0]
				row $y $d $n [expr {$next ne "row"}]
				set y [expr {$y + 60}]
				incr n
			}
		}
	}
	ui::wheel 230 119 870 [expr {$::page::WH - 119}] page::list_scroll
	if {![llength $items]} { empty_line 270 119 }
}
# Why the list is empty: what is still loading, or what a source could not give
proc page::empty_line {x y} {
	array set c [array get ui::c]
	set t ""
	if {$cat::kitstate eq "loading" || $cat::flatstate eq "loading"} { set t Loading… } \
	elseif {[ui::fval q] ne ""} { set t "Nothing found for [ui::fval q]" }
	if {$t ne ""} { ui::text $x [expr {$y + 4}] $t i14 $c(muted) }
}
proc page::row {y r n last} {
	array set c [array get ui::c]
	w::tile 270 [expr {$y + 12}] [cat::glyph [dict get $r title] [dict get $r id] [dict get $r summary]] 36 18 10
	ui::text 320 [expr {$y + 12}] [clip i14s [dict get $r title] 540] i14s $c(fg)
	ui::text 320 [expr {$y + 32}] [clip i13 [dict get $r summary] 540] i13 $c(muted)
	set v [expr {[dict get $r installed] ne "" ? [dict get $r installed] : [dict get $r version]}]
	ui::text 876 [expr {$y + 22}] [clip i13 $v 86] i13 $c(fg) w 0 {} 1
	set right [expr {[dict get $r installed] ne "" ? "Installed" : [cat::fmtsize [dict get $r download]]}]
	ui::text 1060 [expr {$y + 22}] $right i13 $c(muted) e 0 {} 1
	if {!$last && $y + 59 < $::page::WH} { ui::hline 270 1060 [expr {$y + 59}] $c(border) }
	ui::hit 270 $y 790 60 [list apply {{r x y} { page::open_app $r }} $r]
	ui::focusable row$n button 270 $y 790 60 10 [list page::open_app $r]
}
proc page::list_scroll {d} {
	variable off
	variable items
	set o [expr {max(0, min([llength $items] - 1, $off + $d))}]
	if {$o != $off} { set off $o; draw }
}
proc page::open_first {} {
	foreach it $page::items { if {[lindex $it 0] eq "row"} { open_app [lindex $it 1]; return } }
}
proc page::open_app {r} {
	variable view app
	set ui::focus ""
	cat::open_app $r
	draw
}
proc page::back {} {
	variable view list
	if {[dict size $cat::detail] && [dict get $cat::detail source] eq "ref"} { set page::nav flathub }
	draw
}

# ---- an app's page (Catalogue-3, -5, -6, -7, -8) ---------------------------------------------------

proc page::age {secs} {
	if {$secs eq "" || $secs < 0} { return "" }
	foreach {unit n} {day 86400 hour 3600 minute 60} {
		if {$secs >= $n} { set k [expr {$secs / $n}]; return "$k $unit[expr {$k == 1 ? "" : "s"}] old" }
	}
	return "just now"
}
proc page::date {t} {
	if {$t eq "" || $t <= 0} { return "" }
	return "[string trimleft [clock format $t -format %d] 0] [clock format $t -format {%b %Y}]"
}
proc page::keyshort {v} {
	expr {[string length $v] < 30 ? $v : "[string range $v 0 5]…[string range $v end-5 end]"}
}

# The strip (properties/apppages.tcl's ap::strip): the state, its version, the size on the right.
proc page::strip {y icon title detail right} {
	array set c [array get ui::c]
	ui::box 270 $y 790 64 -fill $c(field) -radius 12
	ui::ring 270 $y 790 64 12 $c(border) 1
	ui::box 284 [expr {$y + 14}] 36 36 -fill $c(pill) -radius 10
	ui::icon $icon 17 $c(fg) 293.5 [expr {$y + 23.5}] 2
	set ty [expr {$y + 23.5}]
	set x [expr {334 + [ui::text 334 $ty $title i14s $c(fg)] + 14}]
	ui::text $x $ty $detail i14 $c(muted) w 0 {} 1
	if {$right ne ""} { ui::text 1042 [expr {$y + 24}] $right i13 $c(muted) e 0 {} 1 }
}

proc page::draw_app {} {
	array set c [array get ui::c]
	set D $cat::detail
	set src [dict get $D source]
	# the heading: back, the app's name, what it is and where it comes from
	ui::box 270 35 32 32 -fill $c(field) -radius 8
	ui::icon back 16 $c(fg) 278 43 2
	ui::hit 270 35 32 32 {apply {{x y} { page::back }}}
	ui::focusable back button 270 35 32 32 8 page::back
	ui::text 316 34 [clip sg28 [dict get $D title] 744 -0.56] sg28 $c(fg) w -0.56
	switch -- $src {
		kit { set sub [join [lmap s [list [dict get $D summary] "kit from Ribbon kits"] { if {$s eq ""} continue; set s }] " · "] }
		flathub { set sub [join [lmap s [list [dict get $D summary] "from Flathub"] { if {$s eq ""} continue; set s }] " · "] }
		ref { set sub "[file tail [dict get $D file]] · in [tilde [file dirname [dict get $D file]]]" }
	}
	ui::text 316 [ui::lh 76 i14 21 1] [clip i14 $sub 744] i14 $c(muted) w 0 {} 1
	set inst [dict get $D installed]
	set ver [expr {$inst ne "" ? $inst : [dict get $D version]}]
	set size [expr {$src eq "kit" ? [dict get $D size] : [dict get $D download]}]
	if {$inst ne ""} {
		set when [expr {[dict exists $D when] && [dict get $D when] ne "" && [clock seconds] - [dict get $D when] < 3600 ? "Just now" : ""}]
		strip 119 check Installed $ver $when
	} else {
		strip 119 [expr {$src eq "kit" ? "box" : "layers"}] {Not installed} $ver [cat::fmtsize $size]
	}
	set y 207
	if {$src eq "kit"} { lassign [kit_facts $D] lt left rt right } else { lassign [flat_facts $D] lt left rt right }
	ui::label 270 $y $lt
	set y1 [w::facts 270 [expr {$y + 22}] 379 $left]
	ui::label 681 $y $rt
	set y2 [w::facts 681 [expr {$y + 22}] 379 $right]
	set y [expr {max($y1, $y2) + 24}]
	if {$src eq "kit"} {
		set chips [perms::allowed [perms::requested [dict create perms [expr {[dict exists $D perms] ? [dict get $D perms] : {}}]]]]
	} else { set chips [dict get $D requests] }
	if {[llength $chips]} {
		ui::label 270 $y Requests
		w::chips 270 [expr {$y + 22}] 790 $chips
		set y [expr {$y + 22 + 32 + 24}]
	}
	if {$src eq "kit" && [llength [dict get $D needs]]} {
		set uses [expr {[dict exists $D uses] ? [dict get $D uses] : {}}]
		set libs [lmap n [dict get $D needs] {
			lassign $n name range
			list "" [lindex [split $name .] end] [expr {[dict exists $uses $name] ? [dict get $uses $name] : [join $range " "]}]
		}]
		ui::label 270 $y {Shared libraries}
		w::chips 270 [expr {$y + 22}] 790 $libs
	}
	footer
}
proc page::tilde {p} {
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : ""}]
	if {$home ne "" && [string first $home/ $p/] == 0} { return "~[string range $p [string length $home] end]" }
	if {$p eq $home} { return ~ }
	file tail $p
}
# A kit's facts: KIT (version, size, who it installs for, its short name) and SIGNATURE (kit info's)
proc page::kit_facts {D} {
	set inst [dict get $D installed]
	set left [list [list Version [list [list t [expr {$inst ne "" ? $inst : [dict get $D version]}]]]] \
		[list Size [list [list t [cat::fmtsize [dict get $D size]]]]]]
	if {$inst ne ""} {
		lappend left [list Installed [list [list t [join [lmap s [list {For you} [date [dict get $D when]]] { if {$s eq ""} continue; set s }] " · "]]]]
	} else { lappend left [list Installs {{t {For you}}}] }
	lappend left [list Kit [list [list t [dict get $D short]]]]
	set right {}
	if {[dict exists $D signer]} {
		set s [dict get $D signer]
		lappend right [list Signer [list [list t [expr {[dict get $s name] ne "" ? [dict get $s name] : "Unknown"}]]]]
		set key [expr {[dict get $s key] ne "" ? [dict get $s key] : [dict get $D keyid]}]
		if {$key ne ""} { lappend right [list Key [list [list t [keyshort $key]]]] }
		switch -- [dict get $D sigstate] {
			valid { lappend right {Signature {{i check} {t Valid}}} }
			"" {}
			default { lappend right [list Signature [list [list t [string totitle [dict get $D sigstate]]]]] }
		}
	}
	if {[dict exists $D checked] && [dict get $D checked] > 0} { lappend right [list Index [list [list t [age [expr {[clock seconds] - [dict get $D checked]}]]]]] }
	list Kit $left Signature $right
}
# A Flatpak app's facts: APP (version, download, installed size, who it installs for) and FLATPAK
# (its ID, branch, runtime, licence), as flatpak remote-info gives them
proc page::flat_facts {D} {
	set f [dict get $D facts]
	set get {apply {{f k} { expr {[dict exists $f $k] ? [dict get $f $k] : ""} }}}
	set left {}
	set v [expr {[dict get $D installed] ne "" ? [dict get $D installed] : [dict get $D version]}]
	if {$v ne ""} { lappend left [list Version [list [list t $v]]] }
	if {[dict get $D download] ne ""} { lappend left [list Download [list [list t [cat::fmtsize [dict get $D download]]]]] }
	set is [cat::bytes [{*}$get $f Installed]]
	if {$is ne ""} { lappend left [list {Installed size} [list [list t [cat::fmtsize $is]]]] }
	lappend left [list Installs {{t {For you}}}]
	set right [list [list ID [list [list t [clip i13 [dict get $D id] 250]]]]]
	set br [expr {[{*}$get $f Branch] ne "" ? [{*}$get $f Branch] : ([dict exists $D branch] ? [dict get $D branch] : "")}]
	if {$br ne ""} { lappend right [list Branch [list [list t $br]]] }
	set rt [{*}$get $f Runtime]
	if {$rt ne ""} { lassign [split $rt /] rn - rb; lappend right [list Runtime [list [list t [clip i13 "$rn $rb" 250]]]] }
	set li [{*}$get $f License]
	if {$li ne ""} { lappend right [list Licence [list [list t [clip i13 [cat::licence $li] 250]]]] }
	if {[dict get $D source] eq "ref" && [dict get $D remote] eq "" && [dict get $D url] ne ""} {
		regexp {^[a-z]+://([^/]+)} [dict get $D url] -> host
		if {[info exists host]} { lappend right [list Source [list [list t $host]]] }
	}
	list App $left Flatpak $right
}

# The footer: Install, or Open once it is installed; while it installs, how far it is
proc page::footer {} {
	variable WH
	array set c [array get ui::c]
	set D $cat::detail
	set by [expr {$WH - 55}]
	set J $cat::job
	if {[dict size $J] && [dict get $J id] eq [dict get $D id] && [dict get $J phase] ni {asking plan}} {
		set what [expr {[dict get $J phase] eq "install" ? "Installing" : "Downloading"}]
		set x [expr {270 + [ui::text 270 [expr {$WH - 44.5}] $what i14s $c(fg)] + 18}]
		if {[dict get $J source] eq "kit"} {
			set t "[cat::fmtsize [dict get $J done]] of [cat::fmtsize [dict get $J total]]"
			if {[dict get $J total] <= 0} { set t "" }
		} else { set t [expr {[dict get $J pct] >= 0 ? "[expr {round([dict get $J pct])}] %" : ""}] }
		if {$t ne ""} { set x [expr {$x + [ui::text $x [expr {$WH - 44}] $t i13 $c(muted) w 0 {} 1] + 18}] }
		set cancel [expr {[dict get $J source] ne "kit" || [dict get $J phase] eq "download"}]
		set bx 1060
		if {$cancel} {
			set cw [ui::button_w Cancel ghost]
			set bx [expr {1060 - $cw}]
			ui::button cancel $bx $by Cancel ghost cat::cancel "" $cw
			set bx [expr {$bx - 10}]
		}
		ui::box $x [expr {$WH - 39}] [expr {$bx - $x}] 6 -fill $c(field) -radius 3
		set p [dict get $J pct]
		if {[dict get $J phase] eq "install"} { set p 100 }
		if {$p > 0} { ui::box $x [expr {$WH - 39}] [expr {($bx - $x) * $p / 100.0}] 6 -fill $c(accent) -radius 3 }
		return
	}
	if {[dict get $D installed] ne ""} {
		set w [ui::button_w Open primary ext]
		ui::button open [expr {1060 - $w}] $by Open primary page::launch ext $w
	} elseif {[dict get $D state] eq "ready" && ([dict get $D source] ne "kit" || [dict get $D version] ne "") && (![dict size $J] || [dict get $J id] eq [dict get $D id])} {
		# one install at a time (cat::install): while another app installs, no Install that would do nothing
		# (behind kit's prompt for this one it stays, as Catalogue-4-Sheet draws it)
		set w [ui::button_w Install primary download]
		ui::button install [expr {1060 - $w}] $by Install primary page::install download $w
	}
}
proc page::install {} { cat::install page::plan_sheet }
proc page::launch {} {
	set err [cat::launch]
	if {$err ne ""} { dlg::message "Couldn't open it" $err }
}
# What an install ended with: nothing to say when it worked or you said no
proc page::job_ended {} {
	if {![dict size $::cat::last]} return
	set j $::cat::last
	set ::cat::last {}
	if {[dict get $j phase] eq "failed" && [dict get $j code] != 130} {
		set said [string trim [dict get $j said]]
		dlg::message "Couldn't install it" [expr {$said ne "" ? [lindex [split $said \n] end] : "It stopped with code [dict get $j code]."}]
	}
}

# ---- kit's prompt as a sheet (Kit-Sheet-1, Catalogue-4-Sheet) --------------------------------------
# Properties' sheet (properties/pages.tcl, page::sheet_draw): the app's tile, name and kit, one 48 px
# row per kit, what it downloads, Cancel and kit's question word for word.
proc page::plan_sheet {rows question default} {
	variable dialog
	variable sheetoff 0
	set dialog [dict create kind plan rows $rows question $question default $default]
	set ui::focus [expr {$default ? "pyes" : "pno"}]
	draw
}
proc page::sheet_answer {a} {
	variable dialog ""
	set ui::focus ""
	cat::answer $a
	draw
}
proc page::sheet_scroll {max d} {
	variable sheetoff
	set o [expr {max(0, min($max, $sheetoff + $d))}]
	if {$o != $sheetoff} { set sheetoff $o; draw }
}
proc page::sheet_key {max fit sym} {
	switch -- $sym {
		Up { sheet_scroll $max -1 } Down { sheet_scroll $max 1 }
		Prior { sheet_scroll $max -$fit } Next { sheet_scroll $max $fit }
		default { return 0 }
	}
	return 1
}
proc page::sheet_button {x y q} {
	array set c [array get ui::c]
	set tail " (takes effect at restart)"
	set head $q; set rest ""
	if {[string match "*$tail" $q]} { set head [string range $q 0 end-[string length $tail]]; set rest [string trimleft $tail] }
	set w [expr {36 + [ui::measure i14s $head] + ($rest ne "" ? 6 + [ui::measure i14m $rest] : 0)}]
	set x [expr {$x - $w}]
	ui::box $x $y $w 38 -fill $c(accent) -radius 10
	set tw [ui::text [expr {$x + 18}] [expr {$y + 10.5}] $head i14s $c(ink)]
	if {$rest ne ""} { ui::text [expr {$x + 24 + $tw}] [expr {$y + 10.5}] $rest i14m [ui::mix $c(ink) $c(accent) 0.72] }
	ui::hit $x $y $w 38 {apply {{x y} { page::sheet_answer 1 }}}
	ui::focusable pyes button $x $y $w 38 10 {page::sheet_answer 1}
	return $x
}
proc page::sheet_draw {} {
	variable dialog
	variable sheetoff
	variable WH
	array set c [array get ui::c]
	set D $cat::detail
	set ui::hits {}; set ui::wheels {}; set ui::focusables {}
	ui::layer
	set rows [dict get $dialog rows]
	set down 0
	set sizes [lmap r $rows { set b [dict get $r bytes]; if {![string is wide -strict $b]} { set b 0 }; incr down $b; cat::fmtsize $b }]
	set foot [expr {$down > 0 ? "Download [cat::fmtsize $down]" : "No download"}]
	set tags [expr {[llength [concat {*}[lmap r $rows { dict get $r tags }]]] > 0}]
	set w 640
	set fit [expr {max(1, ($WH - 80 - 88 - 72) / 48)}]
	set shown [expr {min($fit, [llength $rows])}]
	set h [expr {88 + 48 * $shown + 72}]
	set x [expr {(1100 - $w) / 2}]; set y [expr {($WH - $h) / 2}]
	raster::box $ui::img $x $y $w $h -fill [ui::col $c(bar)] -radius 16 -ring [list [ui::col $c(border)] 1] -shadow {24 64 0.6}
	ui::hit $x $y $w $h ""
	set L [expr {$x + 28}]; set R [expr {$x + $w - 28}]
	set icon [cat::glyph [dict get $D title] [dict get $D id] [dict get $D summary]]
	w::tile $L [expr {$y + 26}] $icon
	ui::text [expr {$L + 58}] [expr {$y + 25}] [clip sg20 [dict get $D title] [expr {$R - $L - 58}] -0.4] sg20 $c(fg) w -0.4
	ui::text [expr {$L + 58}] [expr {$y + 53}] [clip i13 [dict get $D short] [expr {$R - $L - 58}]] i13 $c(muted) w 0 {} 1
	ui::hline $L $R [expr {$y + 88}] $c(border)
	set tagw [expr {$tags ? 128 : 0}]
	set sizer [expr {$R - ($tagw ? $tagw + 16 : 0)}]
	set verx [expr {$sizer - 64 - 16 - 164}]
	set ry [expr {$y + 88}]
	set max [expr {max(0, [llength $rows] - $fit)}]
	set sheetoff [expr {min($sheetoff, $max)}]
	set last [expr {$sheetoff + $shown - 1}]
	if {$max} {
		set area [expr {48 * $fit}]
		set th [expr {max(32, $area * $fit / [llength $rows])}]
		set ty [expr {$ry + ($area - $th) * $sheetoff / $max}]
		ui::box [expr {$R + 14}] [expr {$ty + 4}] 4 [expr {$th - 8}] -fill [ui::mix $c(muted) $c(bar) 0.4] -radius 2
		ui::wheel $L $ry [expr {$R - $L}] $area [list page::sheet_scroll $max]
		ui::focusable plist list $L $ry [expr {$R - $L}] $area 8 [list page::sheet_key $max $fit]
	}
	set n 0
	set shownrows [lrange $rows $sheetoff $last]
	foreach r $shownrows size [lrange $sizes $sheetoff $last] {
		set own [expr {[dict get $r fullname] eq [dict get $D name]}]
		w::tile $L [expr {$ry + 10}] [expr {$own ? $icon : "box"}] 28 15 8
		# the app's own row by its name, every other kit by kit's
		ui::text [expr {$L + 40}] [expr {$ry + 16}] [clip i13s [expr {$own ? [dict get $D title] : [dict get $r name]}] [expr {$verx - 16 - $L - 40}]] i13s $c(fg)
		set vx $verx
		if {[dict get $r action] eq "install"} {
			set vx [expr {$vx + [ui::text $vx [expr {$ry + 16}] new i13 $c(muted) w 0 {} 1] + 8}]
			ui::text $vx [expr {$ry + 16}] [dict get $r new] i13 $c(fg) w 0 {} 1
		} else {
			set vx [expr {$vx + [ui::text $vx [expr {$ry + 16}] [dict get $r old] i13 $c(muted) w 0 {} 1] + 6}]
			set vx [expr {$vx + [ui::text $vx [expr {$ry + 16}] → i13 $c(muted)] + 6}]
			ui::text $vx [expr {$ry + 16}] [dict get $r new] i13 $c(fg) w 0 {} 1
		}
		ui::text $sizer [expr {$ry + 16}] $size i13 $c(muted) e 0 {} 1
		set tx $R
		foreach t [lreverse [dict get $r tags]] {
			set tx [expr {$tx - [ui::measure i11s $t] - 14}]
			ui::badge $tx [expr {$ry + 14}] $t [expr {$t eq "security"}]
			set tx [expr {$tx - 6}]
		}
		set ry [expr {$ry + 48}]
		if {[incr n] < [llength $shownrows]} { ui::hline $L $R [expr {$ry - 1}] $c(border) }
	}
	ui::hline $x [expr {$x + $w}] $ry $c(border)
	ui::text $L [expr {$ry + 28}] $foot i13 $c(muted) w 0 {} 1
	set bx [sheet_button $R [expr {$ry + 17}] [dict get $dialog question]]
	set cw [ui::button_w Cancel ghost]
	ui::button pno [expr {$bx - 10 - $cw}] [expr {$ry + 17}] Cancel ghost {page::sheet_answer 0} "" $cw
	ui::focus_ring
}

# ---- keys ----------------------------------------------------------------------------------------

proc page::clicked_outside {} {
	if {$page::dialog ne ""} return
	if {[lindex [ui::focused] 1] eq "field"} { set ui::focus ""; draw }
}
proc page::key {sym char state} {
	variable dialog
	variable view
	update idletasks
	if {$dialog ne ""} {
		if {[dict get $dialog kind] eq "plan"} {
			switch -- $sym {
				Escape { sheet_answer 0 }
				Return - KP_Enter - space { set f [ui::focused]; if {$f ne ""} { uplevel #0 [lindex $f 7] } }
				Tab - Left - Right { ui::cycle 1 }
				ISO_Left_Tab { ui::cycle -1 }
				default { set f [ui::focused]; if {[lindex $f 1] eq "list"} { uplevel #0 [list {*}[lindex $f 7] $sym] } }
			}
			return
		}
		dlg::key $sym $char $state; return
	}
	set f [ui::focused]
	lassign $f id kind
	set ctrl [expr {$state & 4}]
	if {$ctrl && $sym in {q Q w W}} { quit }
	if {$ctrl && $sym in {f F} && $view eq "list"} { set ui::focus q; draw; return }
	switch -- $sym {
		Tab { if {$state & 1} { ui::cycle -1 } else { ui::cycle 1 }; return }
		ISO_Left_Tab { ui::cycle -1; return }
	}
	if {$kind eq "field"} {
		if {$sym eq "Escape"} { if {[ui::fval q] ne ""} { ui::fset q ""; draw } else { set ui::focus ""; draw }; return }
		if {[ui::field_key $id $sym $char $state]} { draw }
		return
	}
	if {$kind eq "button" && $sym in {Return KP_Enter space}} { uplevel #0 [lindex $f 7]; return }
	if {$kind eq "list" && [uplevel #0 [list {*}[lindex $f 7] $sym]]} return
	switch -- $sym {
		Escape - BackSpace { if {$view eq "app"} { back } elseif {$sym eq "Escape"} { quit } }
		Prior { if {$view eq "list"} { list_scroll -5 } }
		Next { if {$view eq "list"} { list_scroll 5 } }
		default {
			# typing on the list searches
			if {$view eq "list" && !$ctrl && $char ne "" && [string is print $char]} {
				set ui::focus q
				ui::field_key q $sym $char $state
				draw
			}
		}
	}
}
