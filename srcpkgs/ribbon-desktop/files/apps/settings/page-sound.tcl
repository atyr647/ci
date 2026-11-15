# page-sound.tcl - Settings → Sound (board Settings-A5-Sound): the output and the input (their devices, the one in
# use checked; volume with its mute; the output's balance; the input's level), what is playing now (a volume and a
# mute each, the alerts' among them), and three options. The logic is sound.tcl (PipeWire through pactl, the
# settings file $XDG_CONFIG_HOME/ribbon/sound.conf).
#
# Layout (window coordinates; the page runs from 270 to 1060): the left column is 420 wide (270..690), a rule at 722
# from 119 to 686, the right column from 755. A block's label is at 119; its rows start 22 under it. A device row is
# 52 tall (the one in use in §field, ringed, with the check); 10 under the devices come the 48 px rows. A volume row
# is its label, a 32 px mute button at 406 (846 on the right), the slider, and the value at the row's right end.

source -encoding utf-8 [file join [file dirname [file normalize [info script]]] sound.tcl]

settings::page sound -title Sound -icon speaker -group 1 -order 3 -draw settings::draw_sound \
	-rows {Output Input Volume Balance Level {Playing now} Alerts {Louder than 100%} {Sound for alerts} {Volume in the bar}}

array set ::ui::paths {
	snd_speaker    {M4 4h16v16H4z M12 14a2 2 0 1 0 0-4a2 2 0 1 0 0 4z M12 7h.01}
	snd_monitor    {M4 3h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z M8 21h8 M12 17v4}
	snd_headphones {M3 14h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a9 9 0 0 1 18 0v7a2 2 0 0 1-2 2h-1a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h3}
	snd_mic        {M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3z M19 10v2a7 7 0 0 1-14 0v-2 M12 19v3}
	snd_vol        {M11 5L6 9H2v6h4l5 4z M15.5 8.5a5 5 0 0 1 0 7 M19 5a10 10 0 0 1 0 14}
	snd_volx       {M11 5L6 9H2v6h4l5 4z M22 9l-6 6 M16 9l6 6}
	snd_globe      {M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0 M2 12h20 M12 2a15 15 0 0 1 4 10a15 15 0 0 1-4 10a15 15 0 0 1-4-10a15 15 0 0 1 4-10z}
	snd_game       {M6 11h4 M8 9v4 M15 12h.01 M18 10h.01 M17.3 5H6.7a4 4 0 0 0-4 3.6C2.2 11 2 14 2 15a3 3 0 0 0 3 3c1 0 1.5-.5 2-1l1.4-1.4A2 2 0 0 1 9.8 15h4.4a2 2 0 0 1 1.4.6L17 17c.5.5 1 1 2 1a3 3 0 0 0 3-3c0-1-.2-4-.7-6.4a4 4 0 0 0-4-3.6z}
	snd_music      {M9 18V5l12-2v13 M9 18a3 3 0 1 1-6 0a3 3 0 0 1 6 0z M21 16a3 3 0 1 1-6 0a3 3 0 0 1 6 0z}
	snd_apps       {M4 4h6v6H4z M14 4h6v6h-6z M4 14h6v6H4z M14 14h6v6h-6z}
	snd_bell       {M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9 M13.73 21a2 2 0 0 1-3.46 0}
}

namespace eval sndp {
	variable started 0
}

proc sndp::hit {x y w h script} {
	ui::hit $x $y $w $h [list apply {{s x y} { uplevel #0 $s; page::draw }} $script]
}
proc sndp::label {x y t} { ui::text $x $y [string toupper $t] i11s $ui::c(muted) w 1.32 }

# A device row at Y (52 tall, 420 wide from 270): the one in use has the field, the ring and the check.
proc sndp::device {y kind d} {
	array set c [array get ui::c]
	set on [dict get $d default]
	if {$on} { ui::box 270 $y 420 52 -fill $c(field) -radius 10 -ring [list $c(border) 1] }
	# a Bluetooth headset is headphones as an input too (sound.tcl calls every input a microphone)
	set icon snd_[expr {$kind eq "source" && [dict get $d address] ne "" ? "headphones" : [dict get $d kind]}]
	if {![info exists ::ui::paths($icon)]} { set icon snd_speaker }
	ui::icon $icon 16 [expr {$on ? $c(fg) : $c(muted)}] 282 [expr {$y + 18}]
	ui::text 310 [expr {$y + 9.5}] [dict get $d label] [expr {$on ? "i13s" : "i13m"}] $c(fg)
	ui::text 310 [expr {$y + 27.5}] [dict get $d sub] i12 $c(muted)
	if {$on} { ui::icon check 15 $c(accent) 663 [expr {$y + 18.5}] 2.4 } else {
		sndp::hit 270 $y 420 52 [list snd::set_default $kind [dict get $d id]]
		ui::focusable dev-$kind-[dict get $d id] button 270 $y 420 52 10 [list snd::set_default $kind [dict get $d id]]
	}
}

# A slider: a 4 px track W wide from X at the row's middle (the row's top is Y), filled to FRAC, an 18 px knob.
# SCRIPT gets the fraction (0..1) under the pointer on a press and while it is dragged.
proc sndp::slider {id x y w frac script} {
	array set c [array get ui::c]
	set frac [expr {max(0.0, min(1.0, $frac))}]
	ui::box $x [expr {$y + 22}] $w 4 -fill $c(pill) -radius 2
	if {$frac > 0} { ui::box $x [expr {$y + 22}] [expr {$w * $frac}] 4 -fill $c(muted) -radius 2 }
	ui::box [expr {$x + $w * $frac - 9}] [expr {$y + 15}] 18 18 -fill $c(fg) -radius 9
	set f [list apply {{x0 w s x y} { uplevel #0 [list {*}$s [expr {max(0.0, min(1.0, ($x - $x0) / double($w)))}]]; page::draw }} $x $w $script]
	ui::hit [expr {$x - 9}] [expr {$y + 8}] [expr {$w + 18}] 32 $f $f
	ui::focusable $id slider $x [expr {$y + 15}] $w 18 9 [list sndp::slider_key $frac $script]
}
proc sndp::slider_key {frac script sym} {
	switch -- $sym {
		Left - Down { set frac [expr {$frac - 0.02}] }
		Right - Up { set frac [expr {$frac + 0.02}] }
		default { return 0 }
	}
	uplevel #0 [list {*}$script [expr {max(0.0, min(1.0, $frac))}]]
	page::draw
	return 1
}

# The top of the volume scale: 100, or 150 with Louder than 100%.
proc sndp::top {} { expr {[snd::setting OVER] eq "yes" ? 150 : 100} }

# A volume row at Y: LABEL at X0 (an icon before it on the right column), the mute button at BX, the slider SW wide
# from BX + 44, the value ending at X1; a rule under it unless LAST.
proc sndp::volume_row {y x0 x1 bx sw label kind id vol muted last {icon ""}} {
	array set c [array get ui::c]
	set tx $x0
	if {$icon ne ""} { ui::icon $icon 16 $c(muted) [expr {$x0 + 1}] [expr {$y + 16}]; set tx [expr {$x0 + 30}] }
	ui::text $tx [expr {$y + 16}] $label i13 $c(fg)
	ui::box $bx [expr {$y + 8}] 32 32 -fill $c(field) -radius 8 -ring [list $c(border) 1]
	ui::icon [expr {$muted ? "snd_volx" : "snd_vol"}] 15 [expr {$muted ? $c(muted) : $c(fg)}] [expr {$bx + 8.5}] [expr {$y + 16.5}]
	set mute [list sndp::set_mute $kind $id [expr {!$muted}]]
	sndp::hit $bx [expr {$y + 8}] 32 32 $mute
	ui::focusable mute-$kind-$id toggle $bx [expr {$y + 8}] 32 32 8 $mute
	sndp::slider vol-$kind-$id [expr {$bx + 44}] $y $sw [expr {$vol / double([sndp::top])}] [list sndp::set_volume $kind $id]
	ui::text $x1 [expr {$y + 16}] "$vol%" i13 $c(fg) e 0 {} 1
	if {!$last} { ui::hline $x0 $x1 [expr {$y + 47}] $c(border) }
}
proc sndp::set_volume {kind id frac} {
	set v [expr {round($frac * [sndp::top])}]
	if {$kind eq "alerts"} { snd::conf_set ALERT_VOLUME [expr {min(100, $v)}] } else { snd::set_volume $kind $id $v }
}
proc sndp::set_mute {kind id on} {
	if {$kind eq "alerts"} { snd::conf_set ALERTS [expr {$on ? "no" : "yes"}] } else { snd::set_mute $kind $id $on }
}
# The balance: the middle holds the knob within 4 %.
proc sndp::set_balance {id frac} {
	set b [expr {round(($frac - 0.5) * 200)}]
	if {abs($b) <= 8} { set b 0 }
	snd::set_balance $id $b
}

# One side (output or input) from TOP: its label, its devices, its volume, then the balance or the level.
# Returns the y its last row ends at.
proc sndp::side {top title kind devices} {
	array set c [array get ui::c]
	sndp::label 270 $top $title
	set y [expr {$top + 22}]
	set cur ""
	foreach d $devices {
		sndp::device $y $kind $d
		if {[dict get $d default]} { set cur $d }
		incr y 52
	}
	if {$cur eq ""} { return $y }
	incr y 10
	sndp::volume_row $y 270 690 406 186 Volume $kind [dict get $cur id] [dict get $cur volume] [dict get $cur muted] 0
	incr y 48
	if {$kind eq "sink"} {
		ui::text 270 [expr {$y + 16}] Balance i13 $c(fg)
		sndp::slider balance 450 $y 240 [expr {([dict get $cur balance] + 100) / 200.0}] [list sndp::set_balance [dict get $cur id]]
	} else {
		ui::text 270 [expr {$y + 16}] Level i13 $c(fg)
		set n [expr {round($::snd::level / 5.0)}]
		for {set k 0} {$k < 20} {incr k} {
			ui::box [expr {553 + 7 * $k}] [expr {$y + 18}] 4 12 -fill [expr {$k < $n ? $c(fg) : $c(pill)}] -radius 1
		}
	}
	expr {$y + 48}
}

proc settings::draw_sound {} {
	array set c [array get ui::c]
	settings::snd_started
	ui::text 270 34 Sound sg28 $c(fg) w -0.56
	ui::text 270 [ui::lh 76 i14 21] [snd::subtitle] i14 $c(muted)
	set m [snd::model]
	if {![dict get $m available]} return
	set y [sndp::side 119 Output sink [dict get $m sinks]]
	sndp::side [expr {$y + 22}] Input source [dict get $m sources]
	ui::box 722 119 1 567 -fill $c(border)
	# PLAYING NOW: the streams, then the alerts
	sndp::label 755 119 {Playing now}
	set y 141
	# the mute buttons stand at 846 as on the board; a longer app name moves the column right (the sliders
	# shorten, to 70 px at least) so that the name is whole
	set need 56
	foreach s [dict get $m streams] { set need [expr {max($need, min(102, ceil([ui::measure i13 [dict get $s app]])))}] }
	set bx [expr {int(790 + $need)}]
	set sw [expr {1006 - $bx - 44}]
	foreach s [dict get $m streams] {
		set icon snd_[dict get $s icon]
		if {![info exists ::ui::paths($icon)]} { set icon snd_apps }
		sndp::volume_row $y 755 1060 $bx $sw [sndp::clip [dict get $s app] $need] stream [dict get $s id] [dict get $s volume] [dict get $s muted] 0 $icon
		incr y 48
	}
	sndp::volume_row $y 755 1060 $bx $sw Alerts alerts 0 [snd::setting ALERT_VOLUME] [expr {[snd::setting ALERTS] ne "yes"}] 1 snd_bell
	incr y 48
	# OPTIONS
	set y [expr {$y + 24}]
	sndp::label 755 $y Options
	incr y 22
	foreach {key label} {OVER {Louder than 100%} ALERTS {Sound for alerts} BAR {Volume in the bar}} {
		ui::text 755 [expr {$y + 16}] $label i13 $c(fg)
		set on [expr {[snd::setting $key] eq "yes"}]
		ui::toggle 1022 [expr {$y + 13}] $on
		set run [list snd::conf_set $key [expr {$on ? "no" : "yes"}]]
		sndp::hit 1018 [expr {$y + 8}] 46 32 $run
		ui::focusable opt-$key toggle 1022 [expr {$y + 13}] 38 22 11 $run
		if {$key ne "BAR"} { ui::hline 755 1060 [expr {$y + 47}] $c(border) }
		incr y 48
	}
}

# TEXT cut to WIDTH px (13 px), with an ellipsis.
proc sndp::clip {text width} {
	if {[ui::measure i13 $text] <= $width} { return $text }
	while {[string length $text] > 1 && [ui::measure i13 "$text…"] > $width} { set text [string range $text 0 end-1] }
	return "$text…"
}

# The first draw starts the reads; a change draws the page again while it is the one shown. The input level runs
# only while the page is shown.
proc settings::snd_started {} {
	if {$::sndp::started} return
	set ::sndp::started 1
	set ::snd::onchange settings::snd_any
	set ::snd::onlevel {sndp::changed}
	snd::start
	snd::level_start
}
proc sndp::changed {} {
	if {$::settings::sel eq "sound"} { page::draw } elseif {$::sndp::started} {
		# another page is shown: the level stops until Sound is drawn again
		snd::level_stop
		set ::snd::onlevel ""
		set ::sndp::started 0
	}
}

# sound.tcl has one change callback and two pages that follow it (Sound, and Bluetooth for a headset's profile).
proc settings::snd_any {} { foreach p {sndp::changed btp::changed} { if {[llength [info commands ::$p]]} { $p } } }
