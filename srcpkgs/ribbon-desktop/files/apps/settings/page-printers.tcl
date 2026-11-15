# page-printers.tcl - Settings → Printers (board Settings-A12-Printers): the printers on the left as Bluetooth's list
# (the default one checked), the driverless ones on the network under NEARBY (a click adds one), and the chosen one on
# the right: Details (connection, address), Options (Default printer, Paper, Two-sided) and its Queue (a job's x
# cancels it). The footer removes it or prints CUPS's test page. The logic is printers.tcl (CUPS).
#
# Layout (window coordinates, as Bluetooth's): the list is 290 wide from 270 in 52 px rows from 119, NEARBY 18 under
# it and its 44 px rows 24 under that; a rule at 592 from 119 to 648; the detail from 625 to 1060: the 44 px tile at
# 119, DETAILS at 187 and 38 px facts from 209, OPTIONS 20 under them and 48 px rows, QUEUE 20 under those and 44 px
# rows; the footer under a rule at 648. Its rail item is registry.tcl's "printers" (group 2, after Bluetooth).

source -encoding utf-8 [file join [file dirname [file normalize [info script]]] printers.tcl]

array set ::ui::paths {
	printer {M6 9V2h12v7 M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2 M6 14h12v8H6z}
	prn_file {M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z M14 2v6h6}
	prn_x {M18 6L6 18 M6 6l12 12}
	prn_trash {M3 6h18 M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6 M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2}
}

namespace eval prp {
	variable started 0
	variable drawn -1
	variable sel ""        ;# the chosen printer's queue name
	variable adding ""     ;# the nearby printer being added (its address)
	variable SIDES {None Off DuplexNoTumble {Long edge} DuplexTumble {Short edge}}
	variable PAPERS {A4 A4 A5 A5 A3 A3 Letter Letter Legal Legal Executive Executive B5 B5 Env10 {Envelope #10} EnvDL {Envelope DL}}
}

proc prp::register {} {
	settings::page printers -title Printers -icon printer -group 2 -order 3 -draw settings::draw_printers \
		-rows {Printers Nearby Details Connection Address Options {Default printer} Paper Two-sided Queue {Print a test page}}
}
if {[settings::exists printers]} { prp::register }

proc prp::begin {} {
	variable started; variable drawn
	if {!$started} {
		set started 1
		set prn::onchange prp::changed
		prn::start
		prn::scan
	} elseif {$ui::drawno != $drawn + 1} {
		set prn::error ""
		prn::refresh
		prn::scan
	}
	set drawn $ui::drawno
}
proc prp::changed {} {
	variable adding
	if {!$prn::busy} { set adding "" }
	if {$::settings::sel eq "printers"} { page::draw }
}
proc prp::hit {x y w h script} { ui::hit $x $y $w $h [list apply {{s x y} { uplevel #0 $s; page::draw }} $script] }

# The chosen printer: the one clicked, else the default, else the first.
proc prp::chosen {m} {
	variable sel
	set ps [dict get $m printers]
	foreach p $ps { if {[dict get $p name] eq $sel} { return $p } }
	foreach p $ps { if {[dict get $p default]} { return $p } }
	lindex $ps 0
}

proc prp::draw_list {m cur} {
	variable adding
	array set c [array get ui::c]
	set y 119
	foreach p [dict get $m printers] {
		set name [dict get $p name]
		set on [expr {$cur ne "" && $name eq [dict get $cur name]}]
		if {$on} { ui::box 270 $y 290 52 -fill $c(field) -radius 10 -ring [list $c(border) 1] }
		ui::icon printer 16 [expr {[dict get $p state] eq "offline" ? $c(muted) : $c(fg)}] 282 [expr {$y + 18}]
		ui::text 310 [expr {$y + 9.5}] [sctl::clip [dict get $p label] 200 [expr {$on ? "i13s" : "i13m"}]] [expr {$on ? "i13s" : "i13m"}] $c(fg)
		ui::text 310 [expr {$y + 27.5}] [prn::label_of [dict get $p state]] i12 $c(muted)
		if {[dict get $p default]} { ui::icon check 15 $c(accent) 533 [expr {$y + 18.5}] 2.4 }
		prp::hit 270 $y 290 52 [list set ::prp::sel $name]
		ui::focusable prn-$name button 270 $y 290 52 10 [list set ::prp::sel $name]
		incr y 52
		if {$y + 52 > 470} break
	}
	if {$y > 119} { incr y 18 }
	set w [ui::text 270 [expr {$y + 1}] NEARBY i11s $c(muted) w 1.32]
	# the arrows look again
	ui::icon refresh 12 $c(muted) [expr {270 + $w + 8}] [expr {$y + 2}] 2
	if {!$prn::scanning} {
		prp::hit [expr {270 + $w + 2}] [expr {$y - 4}] 24 22 prn::scan
		ui::focusable prn-scan button [expr {270 + $w + 2}] [expr {$y - 4}] 24 22 6 prn::scan
	}
	incr y 24
	foreach n [dict get $m nearby] {
		if {$y + 44 > 648} break
		set uri [dict get $n uri]
		ui::icon printer 16 $c(muted) 282 [expr {$y + 14}]
		ui::text 310 [expr {$y + 14}] [sctl::clip [dict get $n label] 170 i13m] i13m $c(fg)
		if {$uri eq $adding} { ui::text 548 [expr {$y + 14.5}] "Adding…" i12 $c(muted) e } elseif {!$prn::busy} {
			set run [list prp::add $uri [dict get $n label]]
			prp::hit 270 $y 290 44 $run
			ui::focusable prn-near-$uri button 270 $y 290 44 10 $run
		}
		incr y 44
	}
}
proc prp::add {uri label} {
	variable adding
	if {[prn::add $uri $label]} { set adding $uri }
}

proc prp::fact {y key value last} {
	array set c [array get ui::c]
	ui::text 625 [expr {$y + 11}] $key i13 $c(muted)
	ui::text 747 [expr {$y + 11}] [sctl::clip $value 313] i13 $c(fg) w 0 {} 1
	if {!$last} { ui::hline 625 1060 [expr {$y + 37}] $c(border) }
}
proc prp::connection {uri} {
	if {[regexp {^ipps?://(localhost|127\.0\.0\.1)[:/]} $uri] || [string match usb:* $uri]} { return USB }
	if {[regexp {^(ipps?|dnssd)://} $uri]} { return "Network · driverless" }
	if {[regexp {^([a-z]+):} $uri -> s]} { return "Network · $s" }
	return ""
}

proc prp::draw_detail {p} {
	variable SIDES; variable PAPERS
	array set c [array get ui::c]
	set name [dict get $p name]
	ui::box 625 119 44 44 -fill $c(pill) -radius 12
	ui::icon printer 20 $c(fg) 637 131 1.8
	ui::text 683 120.5 [sctl::clip [dict get $p label] 370 sg17] sg17 $c(fg)
	ui::text 683 145.5 "Printer · [prn::label_of [dict get $p state]]" i13 $c(muted)
	ui::text 625 187 DETAILS i11s $c(muted) w 1.32
	prp::fact 209 Connection [connection [dict get $p uri]] 0
	prp::fact 247 Address [dict get $p uri] 1
	# OPTIONS: what this printer offers
	set y 305
	ui::text 625 $y OPTIONS i11s $c(muted) w 1.32
	incr y 22
	set rows default
	if {[llength [dict get $p papers]]} { lappend rows paper }
	if {[llength [dict get $p sideses]] && [dict get $p sideses] eq {None DuplexNoTumble DuplexTumble}} { lappend rows sides }
	foreach r $rows {
		set last [expr {$r eq [lindex $rows end]}]
		switch -- $r {
			default {
				ui::text 625 [expr {$y + 16}] "Default printer" i13 $c(fg)
				set on [dict get $p default]
				ui::toggle 1022 [expr {$y + 13}] $on
				# the default stays until another is made the default (CUPS has no "none" for an account)
				if {!$on} {
					prp::hit 1018 [expr {$y + 8}] 46 32 [list prn::set_default $name]
					ui::focusable prn-default toggle 1022 [expr {$y + 13}] 38 22 11 [list apply {{n} { prn::set_default $n; page::draw }} $name]
				}
			}
			paper {
				ui::text 625 [expr {$y + 16}] Paper i13 $c(fg)
				set items {}
				foreach s [dict get $p papers] {
					if {[string match Custom* $s]} continue
					lappend items [list $s [expr {[dict exists $PAPERS $s] ? [dict get $PAPERS $s] : $s}]]
				}
				sctl::dropdown prn-paper 920 $y 140 $items [dict get $p paper] [list prn::set_paper $name]
			}
			sides {
				ui::text 625 [expr {$y + 16}] Two-sided i13 $c(fg)
				ui::seg prn-sides 800 [expr {$y + 8}] 260 $SIDES [dict get $p sides] [list apply {{n v} { prn::set_sides $n $v; page::draw }} $name]
			}
		}
		if {!$last} { ui::hline 625 1060 [expr {$y + 47}] $c(border) }
		incr y 48
	}
	# QUEUE, when there is one
	set jobs [dict get $p jobs]
	if {![llength $jobs]} return
	incr y 20
	ui::text 625 $y QUEUE i11s $c(muted) w 1.32
	incr y 22
	set k [llength $jobs]
	foreach j $jobs {
		if {$y + 44 > 648} break
		incr k -1
		set id [dict get $j id]
		ui::icon prn_file 16 $c(muted) 626 [expr {$y + 14}]
		ui::text 655 [expr {$y + 14}] [sctl::clip [dict get $j file] 280] i13 $c(fg)
		ui::text 1022 [expr {$y + 14}] [expr {[dict get $j state] eq "printing" ? "Printing" : "Waiting"}] i13 $c(muted) e
		ui::icon prn_x 14 $c(muted) 1039 [expr {$y + 15}] 2
		prp::hit 1032 [expr {$y + 8}] 28 28 [list prn::cancel $id]
		ui::focusable prn-job-$id button 1032 [expr {$y + 8}] 28 28 8 [list apply {{i} { prn::cancel $i; page::draw }} $id]
		if {$k && $y + 88 <= 648} { ui::hline 625 1060 [expr {$y + 43}] $c(border) }
		incr y 44
	}
}

# The footer, right to left from 1060: Print a test page (field, when CUPS's page is there), Remove (ghost, the bin).
proc prp::draw_footer {p} {
	set name [dict get $p name]
	set x 1060
	if {[prn::has_testpage]} {
		set w [ui::button_w "Print a test page" field]
		set x [expr {$x - $w}]
		ui::button prn-test $x 665 "Print a test page" field [list apply {{n} { prn::test_page $n; page::draw }} $name]
		set x [expr {$x - 10}]
	}
	set run [expr {$prn::busy ? "" : [list apply {{n} { prn::remove $n; page::draw }} $name]}]
	set w [ui::button_w Remove ghost prn_trash]
	ui::button prn-remove [expr {$x - $w}] 665 Remove ghost $run prn_trash
}

proc settings::draw_printers {} {
	array set c [array get ui::c]
	prp::begin
	set m [prn::model]
	ui::text 270 34 Printers sg28 $c(fg) w -0.56
	ui::text 270 [ui::lh 76 i14 21] [sctl::clip [dict get $m subtitle] 790 i14] i14 $c(muted) w 0 {} 1
	if {[dict get $m available]} {
		set p [prp::chosen $m]
		prp::draw_list $m $p
		ui::box 592 119 1 529 -fill $c(border)
		if {$p ne ""} {
			prp::draw_detail $p
			ui::hline 230 1100 648 $c(border)
			prp::draw_footer $p
		}
	}
	sctl::overlay
}
