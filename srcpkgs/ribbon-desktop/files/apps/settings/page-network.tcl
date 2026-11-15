# page-network.tcl - Settings → Network (U13, board Settings-A2-Network; HANDOFF "Settings → Network", part 1): the
# Wi-Fi radio, the networks (one per SSID: the active one first, then the strongest), the wired device, the chosen
# network's or device's facts, and Connect or Disconnect. The bus work is nm.tcl (NetworkManager over ribbon::dbus,
# asynchronous). Part 2 (U13b, nm-secrets.tcl): the password sheet for a secured network, the CONNECTION section of a
# saved network (Connect automatically, Metered, Addresses, Password), Hidden network, WireGuard rows and their import,
# and the footer's Add connection, Forget and Save.
#
# Layout (window coordinates; the page runs from 270 to 1060): the list column is 290 wide at 270, a 1 px rule at 592,
# the detail pane from 625. The footer rule is at 648 and the buttons at 665 (STYLE 4, 6, 11, 13).

source -encoding utf-8 [file join [file dirname [file normalize [info script]]] nm.tcl]
source -encoding utf-8 [file join [file dirname [file normalize [info script]]] nm-secrets.tcl]

settings::page network -title Network -icon wifi -group 2 -order 1 -draw settings::draw_network \
	-rows {Wi-Fi Ethernet {IP address} Gateway DNS Hardware Connect Disconnect}

# the plug glyph (the rail has the Wi-Fi and refresh glyphs)
set ::ui::paths(plug) {M12 22v-5 M9 8V2 M15 8V2 M18 8v5a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V8z}
set ::ui::paths(shield) {M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z}
set ::ui::paths(eye) {M2 12C2 12 5.5 5 12 5C18.5 5 22 12 22 12C22 12 18.5 19 12 19C5.5 19 2 12 2 12z M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z}
set ::ui::paths(chevron) {M6 9l6 6 6-6}

namespace eval nm {
	variable sel ""        ;# the chosen row: an access point's path or a device's path ("": the active one)
	variable started 0     ;# the first read has been asked for
}

# A hit that runs SCRIPT, as the buttons do. Off while a sheet is open (the sheet takes the clicks).
proc nm::hit {x y w h script} {
	if {$::nm::sheet ne ""} return
	ui::hit $x $y $w $h [list apply {{s x y} { uplevel #0 $s }} $script]
}

# Choose a row; the detail pane shows it. Pending edits of another network are dropped.
proc nm::pick {path} {
	variable sel
	set sel $path
	nm::forget_edits
	page::draw
}

# The chosen row as a dict {kind ap|dev|none, dev (device dict), ap (access-point dict)}. With nothing chosen,
# the active network, or the wired device when it is connected.
proc nm::chosen {} {
	variable sel
	set wifi [nm::device 2]
	set eth [nm::device 1]
	set want $sel
	if {$want eq ""} {
		if {$wifi ne ""} {
			foreach ap [nm::networks $wifi] { if {[dict get $ap active]} { set want [dict get $ap path]; break } }
		}
		if {$want eq "" && $eth ne "" && [dict get $eth state] == 100} { set want [dict get $eth path] }
	}
	if {$wifi ne ""} {
		foreach ap [dict get $wifi aps] {
			if {[dict get $ap path] eq $want} { return [dict create kind ap dev $wifi ap $ap] }
		}
	}
	foreach d [nm::devices] {
		if {[dict get $d path] eq $want} { return [dict create kind dev dev $d ap {} vpn {}] }
	}
	foreach v [nm::vpns] {
		if {[dict get $v path] eq $want} { return [dict create kind vpn dev {} ap {} vpn $v] }
	}
	dict create kind none dev {} ap {} vpn {}
}

# The paths the list shows as chosen (the same rule as nm::chosen).
proc nm::chosen_path {} {
	set ch [nm::chosen]
	switch -- [dict get $ch kind] {
		ap { return [dict get $ch ap path] }
		dev { return [dict get $ch dev path] }
		vpn { return [dict get $ch vpn path] }
		default { return "" }
	}
}

proc nm::devices {} { variable model; dict get $model devices }

# The subtitle is the state of the page (or the error): the connection, the radio.
proc nm::subtitle {} {
	variable model; variable error; variable loaded
	if {$error ne ""} { return $error }
	if {!$loaded} { return "" }
	if {[dict get $model error] ne ""} { return [dict get $model error] }
	set w [nm::device 2]
	if {$w ne "" && ![dict get $model wifi]} { return "Wi-Fi is off" }
	if {$w ne "" && [dict get $w active] ne ""} { return "Connected to [dict get $w active]" }
	set e [nm::device 1]
	if {$e ne "" && [dict get $e state] == 100} { return "Connected to [dict get $e active]" }
	return "Not connected"
}

# Signal bars: four, the lit ones in §fg, the rest in §pill. Bottom-aligned on the row's centre YC.
proc nm::draw_bars {x yc strength} {
	array set c [array get ui::c]
	set lit [nm::bars $strength]
	for {set i 0} {$i < 4} {incr i} {
		set h [expr {5 + 3 * $i}]
		ui::box [expr {$x + 4 * $i}] [expr {round($yc + 7 - $h)}] 3 $h -fill [expr {$i < $lit ? $c(fg) : $c(pill)}] -radius 1
	}
}

# The list: the networks (52 tall when joined, 44 otherwise), then OTHER with the wired device (52). Returns the
# bottom of the list.
proc nm::draw_list {top} {
	array set c [array get ui::c]
	set wifi [nm::device 2]
	set chosen [nm::chosen_path]
	set y $top
	if {$wifi ne ""} {
		foreach ap [nm::networks $wifi] {
			set active [dict get $ap active]
			set h [expr {$active ? 52 : 44}]
			set path [dict get $ap path]
			if {$path eq $chosen} { ui::box 270 $y 290 $h -fill $c(field) -radius 10 }
			set yc [expr {$y + $h / 2.0}]
			nm::draw_bars 282 $yc [dict get $ap strength]
			if {$active} {
				ui::text 312 [ui::lh [expr {$y + 8}] i13s 22] [dict get $ap ssid] i13s $c(fg)
				ui::text 312 [ui::lh [expr {$y + 30}] i12 18] "Connected · [nm::band [dict get $ap freq]]" i12 $c(muted)
				ui::icon check 14 $c(accent) 534 [expr {round($yc - 7)}] 2.4
			} else {
				ui::text 312 [ui::lh $y i13m $h] [dict get $ap ssid] i13m $c(fg)
			}
			if {[nm::security [dict get $ap flags] [dict get $ap wpa] [dict get $ap rsn]] ne "Open"} {
				ui::icon lock 12 $c(muted) 512 [expr {round($yc - 6)}]
			}
			nm::hit 270 $y 290 $h [list nm::pick $path]
			set y [expr {$y + $h}]
		}
	}
	if {$wifi ne ""} {
		nm::draw_hidden_row $y
		incr y 44
	}
	set eth [nm::device 1]
	set vpns [nm::vpns]
	if {$eth ne "" || [llength $vpns]} {
		if {$y > $top} { set y [expr {$y + 24}] }
		ui::text 270 [ui::lh $y i11s 16] OTHER i11s $c(muted) w 1.3
		set y [expr {$y + 24}]
	}
	if {$eth ne ""} {
		set path [dict get $eth path]
		if {$path eq $chosen} { ui::box 270 $y 290 52 -fill $c(field) -radius 10 }
		ui::icon plug 16 $c(muted) 282 [expr {$y + 18}]
		ui::text 312 [ui::lh [expr {$y + 8}] i13s 22] Ethernet i13s $c(fg)
		ui::text 312 [ui::lh [expr {$y + 30}] i12 18] [nm::ethernet_state $eth] i12 $c(muted)
		nm::hit 270 $y 290 52 [list nm::pick $path]
		set y [expr {$y + 52}]
	}
	foreach v $vpns {
		nm::draw_vpn_row $v $y $chosen
		set y [expr {$y + 52}]
	}
	set y
}

# One fact row: the key (112, muted) and the value (§fg), 38 tall, with a rule under it unless it is the last.
proc nm::fact {top key value last} {
	array set c [array get ui::c]
	ui::text 625 [ui::lh $top i13 38] $key i13 $c(muted)
	ui::text 749 [ui::lh $top i13 38] $value i13 $c(fg)
	if {!$last} { ui::hline 625 1060 [expr {$top + 37}] $c(border) }
}

# The facts of a joined device: its address, gateway, name servers and hardware address.
proc nm::joined_facts {dev} {
	set ip [dict get $dev ip]
	set dns [join [dict get $ip dns] ", "]
	list \
		[list "IP address" [nm::dash [dict get $ip address]]] \
		[list Gateway [nm::dash [dict get $ip gateway]]] \
		[list DNS [nm::dash $dns]] \
		[list Hardware [nm::dash [dict get $dev hw]]]
}

proc nm::dash {s} { expr {$s eq "" ? "—" : $s} }

# The detail pane: the tile, the name, the line under it, and the facts.
proc nm::draw_detail {} {
	array set c [array get ui::c]
	set ch [nm::chosen]
	if {[dict get $ch kind] eq "none"} return
	if {[dict get $ch kind] eq "vpn"} { return [nm::draw_vpn_detail [dict get $ch vpn]] }
	set dev [dict get $ch dev]
	set joined [expr {[dict get $dev state] == 100}]
	if {[dict get $ch kind] eq "ap"} {
		set ap [dict get $ch ap]
		set sec [nm::security [dict get $ap flags] [dict get $ap wpa] [dict get $ap rsn]]
		set joined [dict get $ap active]
		set icon wifi
		set name [dict get $ap ssid]
		set kind [expr {$joined ? "Wi-Fi · $sec · [dict get $dev rate] Mb/s" : "Wi-Fi · $sec · [nm::band [dict get $ap freq]]"}]
	} else {
		set icon plug
		set name Ethernet
		set kind [nm::ethernet_state $dev]
	}
	ui::box 625 119 44 44 -fill $c(field) -radius 12
	ui::icon $icon 20 $c(fg) 637 131
	ui::text 683 [ui::lh 119 sg17 24] $name sg17 $c(fg) w -0.2
	ui::text 683 [ui::lh 146 i12 18] $kind i12 $c(muted)
	ui::text 625 [ui::lh 187 i11s 16] DETAILS i11s $c(muted) w 1.3
	if {[dict get $ch kind] eq "ap" && !$joined} {
		set facts [list [list Security $sec] [list Band [nm::band [dict get $ap freq]]] \
			[list Hardware [nm::dash [dict get $dev hw]]]]
	} elseif {$joined} {
		set facts [nm::joined_facts $dev]
	} else {
		set facts [list [list Hardware [nm::dash [dict get $dev hw]]]]
	}
	set top 209
	set n [llength $facts]
	set i 0
	foreach f $facts {
		incr i
		nm::fact $top [lindex $f 0] [lindex $f 1] [expr {$i == $n}]
		incr top 38
	}
	if {[dict get $ch kind] eq "ap" && [nm::profile_for [dict get [dict get $ch ap] ssid]] ne ""} {
		nm::draw_connection [nm::profile_for [dict get [dict get $ch ap] ssid]] [dict get $ch ap]
	}
}

# A VPN profile's detail: its tile, name, state and facts.
proc nm::draw_vpn_detail {v} {
	array set c [array get ui::c]
	ui::box 625 119 44 44 -fill $c(field) -radius 12
	ui::icon shield 20 $c(fg) 637 131
	ui::text 683 [ui::lh 119 sg17 24] [dict get $v id] sg17 $c(fg) w -0.2
	set on [expr {[dict get $v active] ne ""}]
	ui::text 683 [ui::lh 146 i12 18] [expr {$on ? "WireGuard · Connected" : "WireGuard · Off"}] i12 $c(muted)
	ui::text 625 [ui::lh 187 i11s 16] DETAILS i11s $c(muted) w 1.3
	nm::fact 209 Type WireGuard 0
	nm::fact 247 Status [expr {$on ? "Connected" : "Not connected"}] 1
}

# The footer: Disconnect for a joined network or device; Connect for an open network that is not joined.
proc nm::draw_footer {} {
	set ch [nm::chosen]
	nm::draw_actions $ch
	if {[dict get $ch kind] eq "none" || [dict get $ch kind] eq "vpn"} return
	set dev [dict get $ch dev]
	if {[dict get $ch kind] eq "ap"} {
		set ap [dict get $ch ap]
		if {[dict get $ap active]} {
			nm::footer_button nm_disconnect Disconnect ghost [list nm::job nm::disconnect [dict get $dev activepath]]
		} elseif {[nm::security [dict get $ap flags] [dict get $ap wpa] [dict get $ap rsn]] eq "Open"} {
			nm::footer_button nm_connect Connect primary \
				[list nm::job nm::connect_ap [dict get $dev path] [dict get $ap path] [dict get $ap bytes]]
		} elseif {[nm::profile_for [dict get $ap ssid]] ne ""} {
			nm::footer_button nm_connect Connect primary [list nm::connect_saved [dict get $dev path] [dict get $ap ssid]]
		} else {
			nm::footer_button nm_connect Connect primary [list nm::sheet_open join [dict create dev [dict get $dev path] \
				ap [dict get $ap path] bytes [dict get $ap bytes] ssid [dict get $ap ssid] \
				sae [expr {[nm::security [dict get $ap flags] [dict get $ap wpa] [dict get $ap rsn]] eq "WPA3"}]]]
		}
	} elseif {[dict get $dev state] == 100} {
		nm::footer_button nm_disconnect Disconnect ghost [list nm::job nm::disconnect [dict get $dev activepath]]
	}
}

# Join a saved network P on the device DEV (the activation takes NetworkManager's chosen access point).
proc nm::connect_saved {dev ssid} {
	set p [nm::profile_for $ssid]
	nm::job nm::activate [dict get $p path] $dev
}

# A footer button at the right edge (the last one is the rightmost).
proc nm::footer_button {id label kind script} {
	if {$::nm::sheet ne ""} return
	set w [ui::button_w $label $kind]
	set x [expr {$::nm::footer_x - $w}]
	ui::button $id $x 665 $label $kind $script "" $w
	set ::nm::footer_x [expr {$x - 10}]
}

proc settings::draw_network {} {
	array set c [array get ui::c]
	settings::nm_started
	ui::text 270 34 Network sg28 $c(fg) w -0.56
	set sub [nm::subtitle]
	ui::text 270 [ui::lh 76 i14 21] $sub i14 [expr {[string match "*not running*" $sub] ? $c(fg) : $c(muted)}]
	set wifi [nm::device 2]
	if {$wifi ne ""} {
		set on [dict get $::nm::model wifi]
		set run [list nm::job nm::set_wifi [expr {$on ? 0 : 1}]]
		ui::text 270 [ui::lh 122 i11s 16] "WI-FI" i11s $c(muted) w 1.3
		ui::toggle 510 119 $on
		nm::hit 510 119 38 22 $run
		ui::focusable wifi_radio toggle 510 119 38 22 11 $run
	}
	nm::draw_list 149
	ui::box 592 119 1 529 -fill $c(border)
	nm::draw_detail
	ui::hline 230 1100 648 $c(border)
	set ::nm::footer_x 1060
	nm::draw_footer
	nm::draw_sheet
}

# The first draw starts the first read; when it ends the page is drawn again (nm::onchange).
proc settings::nm_started {} {
	if {$::nm::started} return
	set ::nm::started 1
	set ::nm::onchange page::draw
	nm::refresh
}
