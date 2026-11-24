# page-bluetooth.tcl - Settings → Bluetooth (boards Settings-A6-Bluetooth and Settings-A6b-Bluetooth-Pair): the
# radio's switch, your devices and the ones nearby on the left as Network's list, the chosen device on the right
# (battery, sound, address; connect automatically, what it is used for, its battery in the bar), Forget and
# Disconnect / Connect in the footer. A device nearby pairs on a click; a code to type or to confirm comes as a
# sheet over the page. The logic is bt.tcl (BlueZ on the system bus) and, for a headset's sound, sound.tcl.
#
# Layout (window coordinates, as Network's): the list is 290 wide from 270, a rule at 592 from 119 to 648, the
# detail from 625 to 1060, the footer under a rule at 648. A device row is 52 tall with its state under the name
# (44 nearby, where there is none); NEARBY starts 18 under your devices.

foreach f {bt sound} { source -encoding utf-8 [file join [file dirname [file normalize [info script]]] $f.tcl] }

settings::page bluetooth -title Bluetooth -icon bluetooth -group 2 -order 2 -draw settings::draw_bluetooth \
	-rows {Bluetooth Nearby Battery Address {Connect automatically} {Use for} {Show battery in the bar} Forget Disconnect}

array set ::ui::paths {
	bt_headphones {M3 14h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a9 9 0 0 1 18 0v7a2 2 0 0 1-2 2h-1a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h3}
	bt_mouse      {M12 2a6 6 0 0 1 6 6v8a6 6 0 0 1-12 0V8a6 6 0 0 1 6-6z M12 6v4}
	bt_kbd        {M2 6h20v12H2z M6 10h.01 M10 10h.01 M14 10h.01 M18 10h.01 M7 14h10}
	bt_phone      {M7 2h10a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2z M12 18h.01}
	bt_pad        {M6 11h4 M8 9v4 M15 12h.01 M18 10h.01 M17.3 5H6.7a4 4 0 0 0-4 3.6C2.2 11 2 14 2 15a3 3 0 0 0 3 3c1 0 1.5-.5 2-1l1.4-1.4A2 2 0 0 1 9.8 15h4.4a2 2 0 0 1 1.4.6L17 17c.5.5 1 1 2 1a3 3 0 0 0 3-3c0-1-.2-4-.7-6.4a4 4 0 0 0-4-3.6z}
	bt_speaker    {M4 4h16v16H4z M12 14a2 2 0 1 0 0-4a2 2 0 1 0 0 4z M12 7h.01}
	bt_monitor    {M4 3h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z M8 21h8 M12 17v4}
	bt_bt         {M7 7l10 10-5 5V2l5 5L7 17}
	bt_trash      {M3 6h18 M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6 M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2}
}
set ::ui::fonts(sg20) {{Ribbon Space Grotesk 600} 20 0.984 0.292}
set ::ui::fonts(sg26) {{Ribbon Space Grotesk 600} 26 0.984 0.292}

namespace eval btp {
	variable started 0
	variable sel ""         ;# the chosen device's path ("" the first of yours)
}

# A hit that runs SCRIPT and redraws; nothing under an open sheet takes hits.
proc btp::hit {x y w h script} {
	if {[dict size $::bt::pairing] && [dict get $::bt::pairing kind] ne "plain"} return
	ui::hit $x $y $w $h [list apply {{s x y} { uplevel #0 $s; page::draw }} $script]
}
proc btp::icon_of {d} {
	set i bt_[dict get $d kind]
	expr {[info exists ::ui::paths($i)] ? $i : "bt_bt"}
}
proc btp::devices {} { dict get [bt::model] devices }
# The device shown on the right: the chosen one while it is still yours, else the first of yours.
proc btp::chosen {} {
	variable sel
	set first ""
	foreach d [devices] {
		if {![dict get $d paired]} continue
		if {[dict get $d path] eq $sel} { return $d }
		if {$first eq ""} { set first $d }
	}
	return $first
}
proc btp::state {d} {
	if {![dict get $d connected]} { return "Not connected" }
	set b [dict get $d battery]
	expr {$b ne "" ? "Connected · $b%" : "Connected"}
}

# The list from TOP: your devices, then the ones nearby (a click pairs).
proc btp::draw_list {top} {
	array set c [array get ui::c]
	set cur [chosen]
	set curpath [expr {$cur ne "" ? [dict get $cur path] : ""}]
	set y $top
	set near {}
	foreach d [devices] {
		if {![dict get $d paired]} { lappend near $d; continue }
		set on [dict get $d connected]
		set path [dict get $d path]
		if {$path eq $curpath} { ui::box 270 $y 290 52 -fill $c(field) -radius 10 -ring [list $c(border) 1] }
		ui::icon [icon_of $d] 16 [expr {$on ? $c(fg) : $c(muted)}] 282 [expr {$y + 18}]
		ui::text 310 [expr {$y + 9.5}] [clip [dict get $d name] 200] [expr {$on ? "i13s" : "i13m"}] $c(fg)
		ui::text 310 [expr {$y + 27.5}] [state $d] i12 $c(muted) w 0 {} 1
		if {$on} { ui::icon check 15 $c(accent) 533 [expr {$y + 18.5}] 2.4 }
		btp::hit 270 $y 290 52 [list set ::btp::sel $path]
		ui::focusable btdev-$path button 270 $y 290 52 10 [list set ::btp::sel $path]
		incr y 52
	}
	if {![dict get [bt::model] powered]} { return $y }
	if {$y > $top} { incr y 18 }
	set w [ui::text 270 [expr {$y + 1}] NEARBY i11s $c(muted) w 1.32]
	if {[dict get [bt::model] discovering]} { ui::icon refresh 12 $c(muted) [expr {270 + $w + 8}] [expr {$y + 2}] 2 }
	incr y 24
	set pairing [expr {[dict size $::bt::pairing] ? [dict get $::bt::pairing path] : ""}]
	foreach d $near {
		if {$y + 44 > 640} break
		set path [dict get $d path]
		ui::icon [icon_of $d] 16 $c(muted) 282 [expr {$y + 14}]
		ui::text 310 [expr {$y + 14}] [clip [dict get $d name] 170] i13m $c(fg)
		if {$path eq $pairing} { ui::text 548 [expr {$y + 14.5}] "Pairing…" i12 $c(muted) e } elseif {$pairing eq ""} {
			btp::hit 270 $y 290 44 [list bt::pair $path]
			ui::focusable btnear-$path button 270 $y 290 44 10 [list bt::pair $path]
		}
		incr y 44
	}
	return $y
}

# A fact row (38 tall): the key muted at 625, the value at 747, a rule under it unless LAST.
proc btp::fact {y key value last} {
	array set c [array get ui::c]
	ui::text 625 [expr {$y + 11}] $key i13 $c(muted)
	if {$value ne ""} { ui::text 747 [expr {$y + 11}] $value i13 $c(fg) w 0 {} 1 }
	if {!$last} { ui::hline 625 1060 [expr {$y + 37}] $c(border) }
}

proc btp::draw_detail {d} {
	array set c [array get ui::c]
	set path [dict get $d path]
	set addr [dict get $d address]
	ui::box 625 119 44 44 -fill $c(pill) -radius 12
	ui::icon [icon_of $d] 20 $c(fg) 637 131 1.8
	ui::text 683 120.5 [clip [dict get $d name] 370 sg17] sg17 $c(fg)
	ui::text 683 145.5 "[dict get $d kindlabel] · [expr {[dict get $d connected] ? "Connected" : "Not connected"}]" i13 $c(muted)
	# DETAILS
	ui::text 625 187 DETAILS i11s $c(muted) w 1.32
	set card ""
	foreach k [dict get [snd::model] cards] { if {[string equal -nocase [dict get $k address] $addr]} { set card $k } }
	set rows {}
	if {[dict get $d battery] ne ""} { lappend rows battery }
	if {$card ne "" && [dict get $card codec] ne ""} { lappend rows sound }
	lappend rows address
	set y 209
	foreach r $rows {
		set last [expr {$r eq "address"}]
		switch -- $r {
			battery {
				btp::fact $y Battery "" $last
				set b [dict get $d battery]
				ui::box 747 [expr {$y + 17}] 120 4 -fill $c(pill) -radius 2
				if {$b > 0} { ui::box 747 [expr {$y + 17}] [expr {120 * $b / 100.0}] 4 -fill $c(accent) -radius 2 }
				ui::text 879 [expr {$y + 11}] "$b%" i13 $c(fg) w 0 {} 1
			}
			sound { btp::fact $y Sound [dict get $card codec] $last }
			address { btp::fact $y Address $addr $last }
		}
		incr y 38
	}
	# CONNECTION
	incr y 20
	ui::text 625 $y CONNECTION i11s $c(muted) w 1.32
	incr y 22
	set conn {auto}
	if {$card ne "" && [llength [dict get $card profiles]] > 1} { lappend conn use }
	if {[dict get $d battery] ne ""} { lappend conn bar }
	foreach r $conn {
		set last [expr {$r eq [lindex $conn end]}]
		switch -- $r {
			auto {
				ui::text 625 [expr {$y + 16}] "Connect automatically" i13 $c(fg)
				set on [dict get $d trusted]
				set run [list bt::set_trusted $path [expr {!$on}]]
				ui::toggle 1022 [expr {$y + 13}] $on
				btp::hit 1018 [expr {$y + 8}] 46 32 $run
				ui::focusable bt-auto toggle 1022 [expr {$y + 13}] 38 22 11 $run
			}
			use {
				ui::text 625 [expr {$y + 16}] "Use for" i13 $c(fg)
				if {![dict size $::bt::pairing] || [dict get $::bt::pairing kind] eq "plain"} {
					ui::seg bt-use 880 [expr {$y + 8}] 180 {sound Sound calls Calls} [dict get $card profile] [list snd::set_card_profile $addr]
				}
			}
			bar {
				ui::text 625 [expr {$y + 16}] "Show battery in the bar" i13 $c(fg)
				set on [bt::bar_battery $addr]
				set run [list bt::set_bar_battery $addr [expr {!$on}]]
				ui::toggle 1022 [expr {$y + 13}] $on
				btp::hit 1018 [expr {$y + 8}] 46 32 $run
				ui::focusable bt-bar toggle 1022 [expr {$y + 13}] 38 22 11 $run
			}
		}
		if {!$last} { ui::hline 625 1060 [expr {$y + 47}] $c(border) }
		incr y 48
	}
}

# The footer's buttons, right to left from 1060: Disconnect or Connect (field), Forget (ghost, the bin).
proc btp::draw_footer {d} {
	set path [dict get $d path]
	set on [dict get $d connected]
	set label [expr {$on ? "Disconnect" : "Connect"}]
	set run [expr {$on ? [list bt::disconnect $path] : [list bt::connect $path]}]
	set open [expr {[dict size $::bt::pairing] && [dict get $::bt::pairing kind] ne "plain"}]
	set w [ui::button_w $label field]
	set x [expr {1060 - $w}]
	if {$open} { set run ""; set forget "" } else { set forget [list bt::forget $path] }
	ui::button bt-conn $x 665 $label field [list apply {{s} { uplevel #0 $s; page::draw }} $run]
	set fw [ui::button_w Forget ghost bt_trash]
	ui::button bt-forget [expr {$x - 10 - $fw}] 665 Forget ghost [list apply {{s} { uplevel #0 $s; page::draw }} $forget] bt_trash
}

# TEXT cut to WIDTH px in font F, with an ellipsis.
proc btp::clip {text width {f i13s}} {
	if {[ui::measure $f $text] <= $width} { return $text }
	while {[string length $text] > 1 && [ui::measure $f "$text…"] > $width} { set text [string range $text 0 end-1] }
	return "$text…"
}

# The pairing sheet (board A6b), over the shaded page: the device, its code in six boxes, what to do with it.
# A code to type on the device waits for it (Cancel); a code to compare has Cancel and Pair.
proc btp::draw_sheet {} {
	set p $::bt::pairing
	if {![dict size $p] || [dict get $p kind] eq "plain"} return
	array set c [array get ui::c]
	ui::layer
	set x 290; set y 236; set w 520; set h 292
	raster::box $ui::img $x $y $w $h -fill $c(bar) -radius 16 -ring [list $c(border) 1] -shadow {24 64 0.6}
	ui::hit 0 0 1100 720 {apply {{x y} {}}}
	ui::box [expr {$x + 28}] [expr {$y + 26}] 44 44 -fill $c(pill) -radius 12
	ui::icon bt_bt 22 $c(fg) [expr {$x + 39}] [expr {$y + 37}] 1.7
	set name [dict get $p name]
	ui::text [expr {$x + 86}] [expr {$y + 25}] [clip "Pair $name" 400 sg20] sg20 $c(fg) w -0.4
	ui::text [expr {$x + 86}] [expr {$y + 53}] [dict get $p kindlabel] i13 $c(muted)
	ui::hline [expr {$x + 28}] [expr {$x + $w - 28}] [expr {$y + 88}] $c(border)
	set code [dict get $p code]
	set n [string length $code]
	set cx [expr {$x + ($w - (44 * $n + 10 * ($n - 1))) / 2.0}]
	for {set k 0} {$k < $n} {incr k} {
		ui::box [expr {$cx + 54 * $k}] [expr {$y + 111}] 44 56 -fill $c(field) -radius 10 -ring [list $c(border) 1]
		ui::text [expr {$cx + 54 * $k + 22}] [expr {$y + 122}] [string index $code $k] sg26 $c(fg) c 0 {} 1
	}
	set typed [expr {[dict get $p kind] eq "code"}]
	set line [expr {$typed ? "Type this code on $name, then press Enter" : "Check that $name shows this code"}]
	ui::text [expr {$x + $w / 2.0}] [expr {$y + 181}] [clip $line 460 i13] i13 $c(muted) c
	ui::hline $x [expr {$x + $w}] [expr {$y + 220}] $c(border)
	set right [expr {$x + $w - 28}]
	if {$typed} {
		ui::text [expr {$x + 28}] [expr {$y + 248}] "Waiting for the [string tolower [dict get $p kindlabel]]" i13 $c(muted)
	} else {
		set pw [ui::button_w Pair primary]
		ui::button bt-pair-yes [expr {$right - $pw}] [expr {$y + 237}] Pair primary {bt::pair_answer 1; page::draw}
		set right [expr {$right - $pw - 10}]
	}
	set cw [ui::button_w Cancel ghost]
	ui::button bt-pair-cancel [expr {$right - $cw}] [expr {$y + 237}] Cancel ghost {bt::pair_cancel; page::draw}
}

proc settings::draw_bluetooth {} {
	array set c [array get ui::c]
	settings::bt_started
	set m [bt::model]
	set open [expr {[dict size $::bt::pairing] && [dict get $::bt::pairing kind] ne "plain"}]
	# the window under an open sheet is shaded, as the board's scrim (page::shade, read before the frame is drawn)
	if {[btp::shade] != $::ui::dim} { after idle page::draw }
	ui::text 270 34 Bluetooth sg28 $c(fg) w -0.56
	ui::text 270 [ui::lh 76 i14 21] [expr {$::bt::error ne "" ? $::bt::error : [bt::subtitle]}] i14 $c(muted)
	if {[dict get $m available]} {
		set on [dict get $m powered]
		set run [list bt::set_power [expr {!$on}]]
		ui::text 270 123 BLUETOOTH i11s $c(muted) w 1.32
		ui::toggle 510 119 $on
		btp::hit 506 114 46 32 $run
		ui::focusable bt-radio toggle 510 119 38 22 11 $run
		btp::draw_list 149
		ui::box 592 119 1 529 -fill $c(border)
		set d [btp::chosen]
		if {$d ne ""} {
			btp::draw_detail $d
			ui::hline 230 1100 648 $c(border)
			btp::draw_footer $d
		}
	}
	if {$open} { set ui::dim 0; btp::draw_sheet }
}

# The first draw starts the reads and the search for devices nearby; the search stops when another page is shown.
proc settings::bt_started {} {
	if {$::btp::started} return
	set ::btp::started 1
	ui::fonts
	set ::bt::onchange {btp::changed}
	bt::start
	# a headset's sound profile comes from sound.tcl
	set ::snd::onchange settings::snd_any
	snd::start
	after 400 btp::scan
}
proc btp::scan {} {
	if {$::settings::sel eq "bluetooth" && [dict get [bt::model] powered] && ![dict get [bt::model] discovering]} { bt::scan 1 }
}
# Sets page::shade for the sheet's state and returns it.
proc btp::shade {} {
	set ::page::shade [expr {$::settings::sel eq "bluetooth" && [dict size $::bt::pairing] && [dict get $::bt::pairing kind] ne "plain" ? 0.5 : 0}]
}
proc btp::changed {} {
	variable started
	btp::shade
	if {$::settings::sel eq "bluetooth"} { page::draw; after idle btp::scan } elseif {$started} {
		set started 0
		if {[dict get [bt::model] discovering]} { bt::scan 0 }
	}
}

# sound.tcl has one change callback and two pages that follow it (Sound, and Bluetooth for a headset's profile).
proc settings::snd_any {} { foreach p {sndp::changed btp::changed} { if {[llength [info commands ::$p]]} { $p } } }
