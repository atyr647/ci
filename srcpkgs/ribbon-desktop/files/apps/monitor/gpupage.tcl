# gpupage.tcl - the GPU page (Monitor-R3-Ledger-GPU): the page the rail's GPU row opens. The card's name; four
# meters (Load, Temperature, Power, VRAM); the load and the temperature over the last minute, ten minutes or hour
# (history.tcl's rings); the apps by GPU use with their VRAM; and the card's facts. A figure the driver does not
# give is a dash in a meter and no row among the facts; with no card the page says so and shows nothing else.
# A window wider than the board (monitor::W) widens the meters and the graph, and shares the rest between the apps
# and the card's facts; the span switch keeps its place from the right edge.

namespace eval monitor {
	variable span 60          ;# the graph's span in seconds: 60 600 3600
	variable gsort gpu        ;# the page's app list sorts by gpu or vram
}

proc monitor::set_span {s} { variable span $s; draw }
proc monitor::gsort_by {key args} { variable gsort $key; draw }

# 2540 -> "2,540".
proc monitor::fmt_int {n} {
	set s [expr {round($n)}]
	while {[regsub {^(-?\d+)(\d{3})} $s {\1,\2} s]} {}
	return $s
}

# The facts under "Card": {label value} for each the card gives.
proc monitor::card_facts {card} {
	set out {}
	set g [list dict get $card]
	if {[{*}$g clock] ne ""} {
		lappend out [list Clock "[fmt_int [{*}$g clock]] MHz[expr {[{*}$g mclock] ne "" ? " · memory [fmt_int [{*}$g mclock]] MHz" : ""}]"]
	}
	set hot {}
	if {[{*}$g hot] ne ""} { lappend hot "[{*}$g hot] °C" }
	if {[{*}$g fan] ne ""} { lappend hot "fan [fmt_int [{*}$g fan]] RPM" }
	if {[llength $hot]} { lappend out [list [expr {[{*}$g hot] ne "" ? "Hotspot" : "Fan"}] [join $hot " · "]] }
	if {[{*}$g cap] ne ""} { lappend out [list "Power limit" "[format %.0f [{*}$g cap]] W"] }
	if {[{*}$g bus] ne ""} { lappend out [list Bus [{*}$g bus]] }
	lappend out [list Driver [{*}$g driver]]
	return $out
}

# The four meters: {label value percent}; percent "" draws an empty track.
proc monitor::card_meters {card} {
	set g [list dict get $card]
	set busy [{*}$g busy]; set temp [{*}$g temp]; set pw [{*}$g power]; set cap [{*}$g cap]
	set vu [{*}$g vram_used]; set vt [{*}$g vram_total]
	list \
		[list Load [expr {$busy ne "" ? "[format %.0f $busy]%" : "–"}] $busy] \
		[list Temperature [expr {$temp ne "" ? "$temp °C" : "–"}] $temp] \
		[list Power [expr {$pw ne "" ? "[format %.0f $pw] W" : "–"}] [expr {$pw ne "" && $cap ne "" && $cap > 0 ? 100.0 * $pw / $cap : ""}]] \
		[list VRAM [expr {$vu ne "" ? [fmt_bytes $vu] : "–"}] [expr {$vu ne "" && $vt ne "" && $vt > 0 ? 100.0 * $vu / $vt : ""}]]
}

# One series of the graph as canvas points: values 0-100 over the span, the newest at the right edge.
proc monitor::graph_points {values span x0 y0 w h} {
	set pts {}
	set n [llength $values]
	set i 0
	foreach v $values {
		if {$v ne ""} {
			lappend pts [expr {$x0 + $w - ($n - 1 - $i) * double($w) / ($span - 1)}] [expr {$y0 + $h - max(0, min(100, $v)) * $h / 100.0}]
		}
		incr i
	}
	return $pts
}

proc monitor::gpu_draw {m} {
	variable span
	variable gsort
	set L 308
	set dx [expr {$::monitor::W - 1240}]
	set R [expr {1200 + $dx}]
	set half [expr {$dx / 2}]
	set card [expr {[dict exists $m card] ? [dict get $m card] : ""}]
	if {$card eq ""} {
		ui::text $L [ui::lh 34 sg28 36] "No graphics card" sg28 $ui::c(fg) w -0.56
		return
	}
	ui::text $L [ui::lh 34 sg28 36] [dict get $card name] sg28 $ui::c(fg) w -0.56
	# the line under the name: GameMode when it is on, and the mean load over what the hour's ring holds
	set parts {}
	if {[dict exists $m gamemode] && [dict get $m gamemode]} { lappend parts "GameMode on" }
	set hist [lmap v [ring::series gpu 3600] {expr {$v eq "" ? [continue] : $v}}]
	if {[llength $hist] >= 2} {
		set over [expr {[dict exists $m gpu_secs] ? [dict get $m gpu_secs] : [llength $hist]}]
		lappend parts "[format %.0f [expr {[tcl::mathop::+ {*}$hist] / [llength $hist]}]]% for the last [fmt_span $over]"
	}
	ui::text $L [ui::lh 78 i14 17] [join $parts " · "] i14 $ui::c(muted)
	ui::seg gspan [expr {1008 + $dx}] 34 192 {60 "1 min" 600 "10 min" 3600 "1 h"} $span monitor::set_span 38
	set x $L
	# four meters, 32 apart: 199 wide on the board
	set mw [expr {(892 + $dx - 3 * 32) / 4.0}]
	foreach mt [card_meters $card] {
		lassign $mt label value pct
		ui::text $x 129 $label i13 $ui::c(muted)
		ui::text [expr {$x + $mw}] 129 $value i13s $ui::c(fg) e 0 {} 1
		ui::box $x 152 $mw 3 -fill $ui::c(pill) -radius 2
		if {$pct ne "" && $pct > 0} { ui::box $x 152 [expr {$mw * min(100, $pct) / 100}] 3 -fill $ui::c(fg) -radius 2 }
		set x [expr {$x + $mw + 32}]
	}
	# the graph: 852 x 218, rules at 100 75 50 25 and the foot; load in the text colour, temperature muted
	ui::label $L 187 [dict get {60 "Last minute" 600 "Last 10 minutes" 3600 "Last hour"} $span]
	set tw [ui::text $R 187 Temperature i12 $ui::c(muted) e]
	set lx [expr {$R - $tw - 21}]
	ui::box $lx 193 14 2 -fill $ui::c(muted)
	set lw [ui::text [expr {$lx - 18}] 187 Load i12 $ui::c(muted) e]
	ui::box [expr {$lx - 18 - $lw - 21}] 193 14 2 -fill $ui::c(fg)
	foreach {v gy} {100 212 75 266 50 321 25 375} {
		ui::box $L $gy [expr {852 + $dx}] 1 -fill $ui::c(border)
		ui::text $R [expr {$gy - 7}] $v i11 $ui::c(muted) e 0 {} 1
	}
	ui::box $L 429 [expr {892 + $dx}] 1 -fill $ui::c(border)
	set load [graph_points [ring::series gpu $span] $span $L 212 [expr {852 + $dx}] 218]
	set temp [graph_points [ring::series gputemp $span] $span $L 212 [expr {852 + $dx}] 218]
	if {[llength $load] >= 4} {
		$ui::cv create polygon [lindex $load 0] 430 {*}$load [lindex $load end-1] 430 \
			-fill [ui::col [ui::mix $ui::c(fg) $ui::c(bar) 0.06]] -outline "" -tags page
	}
	if {[llength $temp] >= 4} { $ui::cv create line {*}$temp -fill [ui::col $ui::c(muted)] -width 1.3 -joinstyle round -tags page }
	if {[llength $load] >= 4} { $ui::cv create line {*}$load -fill [ui::col $ui::c(fg)] -width 1.3 -joinstyle round -tags page }
	# the apps by GPU (or VRAM), those that use any
	ui::text $L [ui::lh 452 i12 34] Apps i12 $ui::c(muted)
	foreach {key label right} [list gpu GPU [expr {634 + $half}] vram VRAM [expr {726 + $half}]] {
		set on [expr {$gsort eq $key}]
		ui::text [expr {$on ? $right - 16 : $right}] [ui::lh 452 i12 34] $label [expr {$on ? "i12s" : "i12"}] [expr {$on ? $ui::c(fg) : $ui::c(muted)}] e
		if {$on} { ui::icon down 12 $ui::c(fg) [expr {$right - 12}] 463 2.2 }
		ui::hit [expr {$right - 70}] 452 70 34 [list monitor::gsort_by $key]
	}
	ui::box 298 485 [expr {450 + $half}] 1 -fill $ui::c(border)
	# (Background is not an app to rank: it comes last, as in the table)
	set apps {}; set bg {}
	foreach a [dict get $m apps] {
		if {[dict get $a gpu] <= 0 && [dict get $a vram] <= 0} continue
		if {[dict get $a id] eq ""} { set bg [list $a] } else { lappend apps $a }
	}
	set apps [lrange [lsort -decreasing -command [list monitor::by_field $gsort] $apps] 0 [expr {5 - [llength $bg]}]]
	lappend apps {*}$bg
	set y 486
	set n [llength $apps]; set i 0
	foreach a $apps {
		ui::box 308 [expr {$y + 8}] 24 24 -fill $ui::c(field) -radius 6
		ui::icon [app_icon [dict get $a id]] 13 $ui::c(muted) 313.5 [expr {$y + 13.5}] 1.8
		ui::text 342 [ui::lh $y i13s 40] [dict get $a name] i13s $ui::c(fg)
		ui::text [expr {634 + $half}] [ui::lh $y i13s 40] [format %.0f%% [dict get $a gpu]] i13s $ui::c(fg) e 0 {} 1
		ui::text [expr {726 + $half}] [ui::lh $y i13m 40] [format "%.1f GB" [expr {[dict get $a vram] / 1073741824.0}]] i13m $ui::c(fg) e 0 {} 1
		if {[incr i] < $n} { ui::box 298 [expr {$y + 39}] [expr {450 + $half}] 1 -fill $ui::c(border) }
		incr y 40
	}
	# the card's facts
	set cx [expr {770 + $half}]; set cw [expr {430 + $dx - $half}]
	ui::text $cx [ui::lh 452 i12 34] Card i12 $ui::c(muted)
	ui::box $cx 485 $cw 1 -fill $ui::c(border)
	set facts [card_facts $card]
	if {[dict exists $m display] && [dict get $m display] ne ""} { lappend facts [list Display [dict get $m display]] }
	set y 486
	set n [llength $facts]; set i 0
	foreach f $facts {
		ui::text $cx [ui::lh $y i13 40] [lindex $f 0] i13 $ui::c(muted)
		ui::text [expr {$cx + 124}] [ui::lh $y i13 40] [lindex $f 1] i13 $ui::c(fg) w 0 {} 1
		if {[incr i] < $n} { ui::box $cx [expr {$y + 39}] $cw 1 -fill $ui::c(border) }
		incr y 40
	}
}

# The screen's mode from wlr-randr's "current" line ("2560 × 1440 · 165 Hz"), with "· HDR" when HDR is on
# (monitor::hdr_now), and whether GameMode has a client (gamemoded -s). All optional programs: "" and 0 without them.
proc monitor::display_now {} {
	if {[catch {::exec {*}$::monitor::cmd(randr) 2>/dev/null} text]} { return "" }
	if {![regexp {(\d+)x(\d+) px, ([\d.]+) Hz \([^)]*current} $text -> w h hz]} { return "" }
	set d "$w \u00d7 $h \u00b7 [format %.0f $hz] Hz"
	if {[hdr_now]} { append d " \u00b7 HDR" }
	return $d
}
# HDR is on when `ribbon-hdr status` reports the setting on and this session's compositor runs the renderer it needs
# (Vulkan): saved but not yet applied (before the next login) is not on.
proc monitor::hdr_now {} {
	if {[catch {::exec {*}$::monitor::cmd(hdr) status 2>/dev/null} text]} { return 0 }
	expr {[regexp -line {^HDR: on\M} $text] && [regexp -line {^Renderer in this session: vulkan\M} $text]}
}
proc monitor::gamemode_now {} {
	if {[catch {::exec {*}$::monitor::cmd(gamemode) -s 2>/dev/null} text]} { return 0 }
	return [expr {[regexp {is active} $text] && ![regexp {inactive} $text]}]
}

proc monitor::by_field {key a b} {
	set x [dict get $a $key]; set y [dict get $b $key]
	expr {$x < $y ? -1 : $x > $y ? 1 : 0}
}
