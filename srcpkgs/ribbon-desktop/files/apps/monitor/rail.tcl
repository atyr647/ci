# rail.tcl - the Ledger's rail (Monitor-R3-Ledger): the title, the Apps row, and the HUD's
# metric rows (CPU, GPU, VRAM, Memory, Disk, Network). Choosing a row sorts the table by it; Network (the whole
# system's rate) has no column to sort, so it is not a button.
# The GPU row opens the GPU page (gpupage.tcl). The foot is the game overlay's Compact card (foot.tcl).

array set ui::paths {
	grid {M4 4h6v6H4z M14 4h6v6h-6z M4 14h6v6H4z M14 14h6v6h-6z}
	right {M9 18l6-6-6-6}
	search {M4 11a7 7 0 1 0 14 0a7 7 0 1 0 -14 0 M21 21l-4.3-4.3}
	x {M18 6L6 18 M6 6l12 12}
	cpu {M6 6h12v12H6z M9 2v4 M15 2v4 M9 18v4 M15 18v4 M2 9h4 M2 15h4 M18 9h4 M18 15h4}
	gpu {M2 7h20v10H2z M6 17v3 M18 17v3 M8 12a2 2 0 1 0 4 0a2 2 0 1 0 -4 0 M15 10h3 M15 14h3}
	memory {M2 7h20v10H2z M6 7v10 M10 7v10 M14 7v10 M18 7v10}
	disk {M22 12H2 M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z M6 16h.01 M10 16h.01}
	wifi {M5 12.55a11 11 0 0 1 14 0 M1.42 9a16 16 0 0 1 21.16 0 M8.53 16.11a6 6 0 0 1 6.95 0 M12 20h.01}
	layers {M12 2L2 7l10 5 10-5-10-5z M2 17l10 5 10-5 M2 12l10 5 10-5}
	store {M3 9l1.5-5h15L21 9 M3 9h18v11H3z M9 13h6}
	globe {M12 22a10 10 0 1 0 0-20a10 10 0 1 0 0 20z M2 12h20 M12 2a15 15 0 0 1 0 20 M12 2a15 15 0 0 0 0 20}
	chat {M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z}
	rec {M12 22a10 10 0 1 0 0-20a10 10 0 1 0 0 20z M12 16a4 4 0 1 0 0-8a4 4 0 1 0 0 8z}
	term {M4 17l6-6-6-6 M12 19h8}
}

# Row geometry from Monitor-R3-Ledger (window coordinates): label centres in the rail.
namespace eval monitor {
	variable rail_rows {
		cpu CPU cpu 163 0 0
		gpu GPU gpu 225 0 0
		vram VRAM cpu 287 0 0
		mem Memory memory 349 0 0
		disk Disk disk 402 0 0
		net Network wifi 464 0 0
	}
}

# Format helpers shared by the rail and the table.
proc monitor::fmt_bytes {b} {
	if {$b >= 1073741824} { return [format %.1f%s [expr {$b / 1073741824.0}] { GB}] }
	if {$b >= 1048576} { return [format %.0f%s [expr {$b / 1048576.0}] { MB}] }
	if {$b >= 1024} { return [format %.0f%s [expr {$b / 1024.0}] { KB}] }
	return "0 B"
}
# A rate in bytes a second; under 1 KB/s is shown as a dash, as the boards do.
proc monitor::fmt_rate {b} {
	if {$b < 1000} { return "\u2013" }
	set m [expr {$b / 1000000.0}]
	return [format [expr {$m >= 1 ? {%.0f MB/s} : {%.1f MB/s}}] $m]
}
# A rate's number alone, to one decimal (the network's detail line and the rail's total).
proc monitor::fmt_mb1 {b} { format %.1f [expr {$b / 1000000.0}] }

# The rail's values: label, value, meter (0-100 or ""), detail line.
proc monitor::rail_values {m} {
	set card_v [dict get $m vram_used]
	set card_t [dict get $m vram_total]
	set mt [dict get $m mem_total]
	set mu [dict get $m mem_used]
	set net [expr {[dict get $m net_rx] + [dict get $m net_tx]}]
	# no card, or a card without the figure: a dash, not a zero
	set nocard [expr {[dict exists $m card] && [dict get $m card] eq ""}]
	set novram [expr {$nocard || ([dict exists $m card] && [dict get [dict get $m card] vram_used] eq "")}]
	dict create \
		cpu  [list [format %.0f%% [dict get $m cpu]] [dict get $m cpu] ""] \
		gpu  [list [expr {$nocard ? "\u2013" : [format %.0f%% [dict get $m gpu]]}] [dict get $m gpu] ""] \
		vram [list [expr {$novram ? "\u2013" : [fmt_bytes $card_v]}] [expr {$card_t > 0 ? 100.0 * $card_v / $card_t : 0}] ""] \
		mem  [list [fmt_bytes $mu] [expr {$mt > 0 ? 100.0 * $mu / $mt : 0}] ""] \
		disk [list [fmt_rate [dict get $m disk]] "" \
			"Read [format %.0f [expr {[dict get $m disk_rd] / 1000000.0}]] \u00b7 write [fmt_rate [dict get $m disk_wr]]"] \
		net  [list "[fmt_mb1 $net] MB/s" "" \
			"\u2193 [fmt_mb1 [dict get $m net_rx]] \u00b7 \u2191 [fmt_rate [dict get $m net_tx]]"]
}

# Choose a rail row: the metric, and the table sort it maps to.
proc monitor::select_metric {key args} {
	variable metric
	variable view
	set metric $key
	set ::monitor::menu ""
	if {$key eq "apps"} { set view apps; draw; return }
	switch -- $key {
		cpu { set ::monitor::sort cpu }
		gpu { set ::monitor::sort gpu }
		vram { set ::monitor::sort vram }
		mem { set ::monitor::sort mem }
		disk { set ::monitor::sort disk }
	}
	draw
}

proc monitor::rail_draw {m} {
	variable metric
	variable rail_rows
	variable view
	ui::text 28 26 "System monitor" sg22 $ui::c(fg) w -0.44
	# the Apps row: its badge is the number of apps
	set on [expr {$metric eq "apps"}]
	if {$on} {
		ui::box 16 80 236 40 -fill $ui::c(field) -radius 10
		ui::box 16 90 3 20 -fill $ui::c(accent) -radius 2
	}
	ui::icon grid 16 [expr {$on ? $ui::c(accent) : $ui::c(muted)}] 28 92
	ui::text 56 [ui::lh 80 i13m 40] Apps [expr {$on ? "i13s" : "i13m"}] [expr {$on ? $ui::c(fg) : $ui::c(muted)}]
	set n [llength [dict get $m apps]]
	set bw [expr {[ui::measure i11s $n 0 1] + 14}]
	ui::box [expr {240 - $bw}] 90 $bw 20 -fill $ui::c(pill) -radius 6
	ui::text [expr {240 - $bw / 2.0}] [ui::lh 90 i11s 20] $n i11s $ui::c(muted) c 0 {} 1
	ui::hit 16 80 236 40 [list monitor::select_metric apps]
	ui::box 28 129 212 1 -fill $ui::c(border)
	set values [rail_values $m]
	foreach {key label icon cy _ _} $rail_rows {
		lassign [dict get $values $key] val pct detail
		set on [expr {$metric eq $key}]
		if {$on} {
			ui::box 16 [expr {$cy - 24}] 236 58 -fill $ui::c(field) -radius 10
			ui::box 16 [expr {$cy - 5}] 3 20 -fill $ui::c(accent) -radius 2
		}
		ui::icon $icon 16 [expr {$on ? $ui::c(accent) : $ui::c(muted)}] 28 [expr {$cy - 8}]
		ui::text 56 [ui::lh [expr {$cy - 10}] [expr {$on ? "i13s" : "i13m"}] 20] $label \
			[expr {$on ? "i13s" : "i13m"}] [expr {$on ? $ui::c(fg) : $ui::c(muted)}]
		ui::text 240 [ui::lh [expr {$cy - 10}] i13s 20] $val i13s $ui::c(fg) e 0 {} 1
		if {$pct ne ""} {
			ui::box 56 [expr {$cy + 16}] 184 3 -fill $ui::c(pill) -radius 2
			set w [expr {184.0 * max(0, min(100, $pct)) / 100}]
			if {$w >= 1} { ui::box 56 [expr {$cy + 16}] $w 3 -fill $ui::c(fg) -radius 2 }
		} elseif {$detail ne ""} {
			ui::text 56 [ui::lh [expr {$cy + 16}] i12 20] $detail i12 $ui::c(muted)
		}
		if {$key ne "net"} { ui::hit 16 [expr {$cy - 24}] 236 58 [list monitor::select_metric $key] }
	}
	foot_draw $m
}
