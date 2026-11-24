# nm-secrets.tcl - Settings → Network, part 2 (U13b, board Settings-A2-Network): the saved half of the page. The
# CONNECTION section of a saved network (Connect automatically, Metered, Addresses: the profile's ipv4.method,
# Password with its reveal), the
# Hidden network row, the VPN rows (WireGuard), the sheets (the password of a secured network, a hidden network, a
# WireGuard file to import), and the footer's Add connection, Forget and Save. The bus calls are in nm.tcl.
#
# Sourced by page-network.tcl after nm.tcl. Coordinates are the page's (see page-network.tcl). A sheet is drawn over
# the page and takes the hits; the page's own hits are off while a sheet is open (nm::hit, footer_button).
#
# The password field is not masked by ui::field (it has no secret option): while it has text the dots are drawn over
# its text (the caret is then hidden). INTEGRATION REQUEST: ui::field -secret.

namespace eval nm {
	variable sheet ""       ;# "" | join | password | hidden | wireguard
	variable sheet_ap {}    ;# join: {dev DEVPATH ap APPATH bytes SSID sae 0|1 ssid TEXT}; password: {profile PATH}
	variable sheet_err ""   ;# the sheet's message
	variable reveal 0       ;# the saved password of the chosen network is shown
	variable shown ""       ;# that password, read when shown
	variable edit {}        ;# pending edits of the chosen profile: {path P autoconnect B metered B ipv4 METHOD}
}

# The saved Wi-Fi profile for SSID, or "".
proc nm::profile_for {ssid} {
	variable model
	foreach p [dict get $model saved] {
		if {[dict get $p type] eq "802-11-wireless" && [dict get $p ssid] eq $ssid} { return $p }
	}
	return ""
}

# The saved VPN profiles (WireGuard or VPN), each with active: the active connection's path, "" when it is down.
proc nm::vpns {} {
	variable model
	set out {}
	foreach p [dict get $model saved] {
		if {[dict get $p type] ni {wireguard vpn}} continue
		set act ""
		foreach a [dict get $model active] {
			if {[dict get $a conn] eq [dict get $p path]} { set act [dict get $a path] }
		}
		lappend out [dict merge $p [dict create active $act]]
	}
	set out
}

# A profile's value as shown: the pending edit when there is one, else the saved one.
proc nm::value {p key} {
	variable edit
	if {[dict exists $edit $key] && [dict get $edit path] eq [dict get $p path]} { return [dict get $edit $key] }
	switch -- $key {
		autoconnect { return [dict get $p autoconnect] }
		metered { return [expr {[dict get $p metered] in {1 3}}] }
		ipv4 { return [dict get [nm::ipv4_of [dict get $p path]] method] }
	}
}

# ---- Addresses: the profile's ipv4.method ----------------------------------------------
# Read from the profile's settings (GetSettings) when the chosen profile is first drawn, kept until the model is
# read again; written with Save (Connection.Update, the settings with the secret kept). The list offers Automatic
# (DHCP) and, when the profile has addresses of its own, Manual; a profile set otherwise (link-local, shared, off)
# shows that and can be set back to Automatic. Editing the addresses themselves has no board yet.

namespace eval nm {
	variable ipv4 ;# profile path -> {method M addrs N}; {method "" addrs 0} while it is read
	array set ipv4 {}
	variable ipv4_labels {"" "" auto "Automatic (DHCP)" manual Manual link-local Link-local shared Shared disabled Off}
}
# a new read of the model (every property change NetworkManager signals) makes what was read of the profiles old:
# it is read again when next asked, and shown as it was until then (not blank, the dropdown keeps the keyboard)
namespace eval nm { variable ipv4_old; array set ipv4_old {} }
trace add variable ::nm::model write [list apply {args { foreach p [array names ::nm::ipv4] { set ::nm::ipv4_old($p) 1 } }}]

# The ipv4 method of profile PATH and the count of its own addresses; the first ask starts the read.
proc nm::ipv4_of {path} {
	variable ipv4
	variable ipv4_old
	if {![info exists ipv4($path)]} {
		set ipv4($path) {method "" addrs 0}
		coroutine ::nm::ip4[incr ::nm::seq] nm::run_ipv4_read $path
	} elseif {[info exists ipv4_old($path)]} {
		unset ipv4_old($path)
		coroutine ::nm::ip4[incr ::nm::seq] nm::run_ipv4_read $path
	}
	set ipv4($path)
}

proc nm::run_ipv4_read {path} {
	variable ipv4
	if {[catch {
		nm::ensure_bus
		set ipv4($path) [nm::ipv4_read $path]
	} msg]} {
		# (a read again that fails keeps what was read before)
		if {[dict get $ipv4($path) method] eq ""} { set ipv4($path) {method auto addrs 0} }
		set ::nm::error [nm::explain $msg]
	}
	page::draw
}

# The method and the address count from a profile's settings (no ipv4 setting: NetworkManager's default, auto).
proc nm::ipv4_read {path} {
	set s [ribbon::dbus::strip a{sa{sv}} [nm::raw_settings $path]]
	set v [nm::get $s ipv4]
	set n [llength [nm::get $v address-data]]
	if {!$n} { set n [llength [nm::get $v addresses]] }
	dict create method [nm::get $v method auto] addrs $n
}

# The list's items for profile P: {value label}.
proc nm::ipv4_items {p} {
	variable ipv4_labels
	set have [nm::ipv4_of [dict get $p path]]
	set items [list [list auto [dict get $ipv4_labels auto]]]
	set saved [dict get $have method]
	if {[dict get $have addrs] > 0 || $saved eq "manual"} { lappend items [list manual [dict get $ipv4_labels manual]] }
	if {$saved ni {auto manual ""} && [dict exists $ipv4_labels $saved]} { lappend items [list $saved [dict get $ipv4_labels $saved]] }
	set items
}

# A pick in the list: a pending edit of the chosen profile, saved with Save.
proc nm::set_ipv4 {path m} {
	variable edit
	if {![dict exists $edit path] || [dict get $edit path] ne $path} { set edit [dict create path $path] }
	dict set edit ipv4 $m
	page::draw
}

# Write METHOD as profile PATH's ipv4.method.
proc nm::save_ipv4 {path method} {
	variable bus; variable dest; variable conniface
	set raw [nm::with_secret $path [nm::raw_settings $path]]
	dict set raw ipv4 method [list s $method]
	$bus call $dest $path $conniface Update "a{sa{sv}}" $raw
}

# Save: the switches, then the method when it was changed.
proc nm::save_all {path auto met psk method} {
	nm::save_profile $path $auto $met $psk
	if {$method ne ""} { nm::save_ipv4 $path $method }
}

# Flip a pending edit (KEY autoconnect or metered) of the chosen profile P.
proc nm::flip {p key} {
	variable edit
	if {![dict exists $edit path] || [dict get $edit path] ne [dict get $p path]} { set edit [dict create path [dict get $p path]] }
	dict set edit $key [expr {![nm::value $p $key]}]
	page::draw
}

# Clear the pending edits (the selection changed).
proc nm::forget_edits {} { variable edit; set edit {} }

# Save the chosen profile P: its autoconnect, metered and Addresses values (pending or saved).
proc nm::save {p} {
	variable edit
	set auto [expr {[nm::value $p autoconnect] ? 1 : 0}]
	set met [expr {[nm::value $p metered] ? 1 : 2}]
	set path [dict get $p path]
	set method ""
	if {[dict exists $edit ipv4] && [dict get $edit path] eq $path && [dict get $edit ipv4] ne [dict get [nm::ipv4_of $path] method]} {
		set method [dict get $edit ipv4]
	}
	nm::forget_edits
	nm::job nm::save_all $path $auto $met "" $method
}

# Show or hide the saved password of profile P (read through GetSecrets when shown).
proc nm::toggle_reveal {p} {
	variable reveal; variable seq
	if {$reveal} { set reveal 0; page::draw; return }
	coroutine ::nm::reveal[incr seq] nm::run_reveal [dict get $p path]
}

proc nm::run_reveal {path} {
	variable reveal; variable shown; variable error
	if {[catch {
		nm::ensure_bus
		set shown [nm::reveal $path]
		set reveal 1
	} msg]} {
		set error [nm::explain $msg]
	}
	page::draw
}

# ---- sheets ----------------------------------------------------------------------

proc nm::sheet_open {kind {ap {}}} {
	variable sheet; variable sheet_ap; variable sheet_err; variable reveal
	set sheet $kind; set sheet_ap $ap; set sheet_err ""; set reveal 0
	foreach f {nm_pass nm_ssid nm_path} { ui::fset $f "" }
	set ::ui::focus [expr {$kind eq "hidden" ? "nm_ssid" : ($kind eq "wireguard" ? "nm_path" : "nm_pass")}]
	page::draw
}

proc nm::sheet_close {} {
	variable sheet; variable sheet_err
	set sheet ""; set sheet_err ""
	foreach f {nm_pass nm_ssid nm_path} { ui::fset $f "" }
	set ::ui::focus ""
	page::draw
}

# Enter in a sheet's field: the sheet's action.
proc nm::sheet_submit {} {
	variable sheet; variable sheet_ap; variable sheet_err
	set pass [ui::fval nm_pass]
	switch -- $sheet {
		join {
			if {[string length $pass] < 8} { set sheet_err "The password is at least 8 characters."; page::draw; return }
			nm::job nm::connect_secured [dict get $sheet_ap dev] [dict get $sheet_ap ap] [dict get $sheet_ap bytes] $pass [dict get $sheet_ap sae]
		}
		password {
			if {[string length $pass] < 8} { set sheet_err "The password is at least 8 characters."; page::draw; return }
			set p [dict get $sheet_ap profile]
			nm::job nm::save_profile [dict get $p path] [nm::value $p autoconnect] [expr {[nm::value $p metered] ? 1 : 2}] $pass
		}
		hidden {
			set ssid [string trim [ui::fval nm_ssid]]
			if {$ssid eq ""} { set sheet_err "Type the network's name."; page::draw; return }
			if {$pass ne "" && [string length $pass] < 8} { set sheet_err "The password is at least 8 characters."; page::draw; return }
			nm::job nm::connect_hidden $ssid $pass
		}
		wireguard {
			set file [string trim [ui::fval nm_path]]
			if {$file eq ""} { set sheet_err "Type the path of a WireGuard file."; page::draw; return }
			nm::job nm::add_wireguard $file
		}
	}
	nm::sheet_close
}

# The sheet's card: its title and line, its field or fields, its message, Cancel and its action.
proc nm::draw_sheet {} {
	variable sheet; variable sheet_err
	# no sheet: the open dropdown's list (Addresses), over the page
	if {$sheet eq ""} { sctl::overlay; return }
	array set c [array get ui::c]
	set h [dict get {join 236 password 236 hidden 300 wireguard 236} $sheet]
	set x 455; set w 420; set y 220
	ui::box $x $y $w $h -fill $c(bar) -radius 14
	switch -- $sheet {
		join { set title "Join [dict get $::nm::sheet_ap ssid]"; set sub "Wi-Fi · password"; set action Join }
		password { set title "Wi-Fi password"; set sub [dict get [dict get $::nm::sheet_ap profile] id]; set action Save }
		hidden { set title "Hidden network"; set sub ""; set action Join }
		wireguard { set title "Add a WireGuard connection"; set sub ""; set action Import }
	}
	ui::text [expr {$x + 24}] [ui::lh [expr {$y + 22}] sg17 26] $title sg17 $c(fg)
	ui::text [expr {$x + 24}] [ui::lh [expr {$y + 50}] i12 18] $sub i12 $c(muted)
	set fy [expr {$y + 88}]
	if {$sheet eq "hidden"} {
		ui::text [expr {$x + 24}] [ui::lh $fy i11s 16] "NETWORK NAME" i11s $c(muted) w 1.3
		ui::field nm_ssid [expr {$x + 24}] [expr {$fy + 20}] 372 -ph "Network name" -onenter nm::sheet_submit -max 32
		incr fy 70
		ui::text [expr {$x + 24}] [ui::lh $fy i11s 16] PASSWORD i11s $c(muted) w 1.3
		nm::draw_pass [expr {$x + 24}] [expr {$fy + 20}] 372
	} elseif {$sheet eq "wireguard"} {
		ui::text [expr {$x + 24}] [ui::lh $fy i11s 16] "CONFIG FILE" i11s $c(muted) w 1.3
		ui::field nm_path [expr {$x + 24}] [expr {$fy + 20}] 372 -ph "/home/you/office.conf" -onenter nm::sheet_submit -max 200
	} else {
		ui::text [expr {$x + 24}] [ui::lh $fy i11s 16] PASSWORD i11s $c(muted) w 1.3
		nm::draw_pass [expr {$x + 24}] [expr {$fy + 20}] 372
	}
	if {$sheet_err ne ""} { ui::text [expr {$x + 24}] [ui::lh [expr {$y + $h - 96}] i12 18] $sheet_err i12 $c(fg) }
	set by [expr {$y + $h - 58}]
	set bx [expr {$x + $w - 24}]
	set aw [ui::button_w $action primary]
	set bx [expr {$bx - $aw}]
	ui::button nm_sheet_go $bx $by $action primary nm::sheet_submit "" $aw
	set cw [ui::button_w Cancel ghost]
	ui::button nm_sheet_cancel [expr {$bx - 10 - $cw}] $by Cancel ghost nm::sheet_close "" $cw
}

# A password field: the field, with its text drawn as dots over it.
proc nm::draw_pass {x y w} {
	array set c [array get ui::c]
	ui::field nm_pass $x $y $w -ph "Password" -onenter nm::sheet_submit -max 64
	set n [string length [ui::fval nm_pass]]
	if {$n} {
		ui::box [expr {$x + 2}] [expr {$y + 2}] [expr {$w - 4}] 34 -fill $c(field) -radius 8
		ui::text [expr {$x + 12}] [ui::lh $y i14 38] [string repeat "•" $n] i14 $c(fg)
	}
}

# ---- rows ------------------------------------------------------------------------

# The CONNECTION section of a saved network P (the AP is AP, a dict): the rows are 48 tall from 421.
proc nm::draw_connection {p ap} {
	array set c [array get ui::c]
	set secure [expr {[nm::security [dict get $ap flags] [dict get $ap wpa] [dict get $ap rsn]] ne "Open"}]
	ui::text 625 [ui::lh 380 i11s 16] CONNECTION i11s $c(muted) w 1.3
	set rows {autoconnect metered addresses}
	if {$secure} { lappend rows password }
	set top 403
	foreach r $rows {
		set cy [expr {$top + 24}]
		switch -- $r {
			autoconnect {
				ui::text 625 [ui::lh $top i13 48] "Connect automatically" i13 $c(fg)
				ui::toggle 1022 [expr {$cy - 11}] [nm::value $p autoconnect]
				nm::hit 1022 [expr {$cy - 11}] 38 22 [list nm::flip_chosen autoconnect]
			}
			metered {
				ui::text 625 [ui::lh $top i13 48] Metered i13 $c(fg)
				ui::toggle 1022 [expr {$cy - 11}] [nm::value $p metered]
				nm::hit 1022 [expr {$cy - 11}] 38 22 [list nm::flip_chosen metered]
			}
			addresses {
				ui::text 625 [ui::lh $top i13 48] Addresses i13 $c(fg)
				set m [nm::value $p ipv4]
				if {$::nm::sheet eq "" && $m ne ""} {
					sctl::dropdown nm_ipv4 880 $top 180 [nm::ipv4_items $p] $m [list nm::set_ipv4 [dict get $p path]]
				} else {
					# a sheet is open (the page takes no clicks), or the profile is still being read
					ui::box 880 [expr {$top + 8}] 180 32 -fill $c(field) -radius 8 -ring [list $c(border) 1]
					ui::text 892 [expr {$top + 16}] [dict get $::nm::ipv4_labels $m] i13 $c(fg) w 0 {} 1
					ui::icon sctl_chev 14 $c(muted) 1036 [expr {$top + 17}] 2
				}
			}
			password {
				ui::text 625 [ui::lh $top i13 48] Password i13 $c(fg)
				# the board: the dots (2 px apart) end 10 before the 15 px eye, which ends at the column's edge
				if {$::nm::reveal} {
					ui::text 1035 [ui::lh $top i13 48] $::nm::shown i13 $c(fg) e
				} else {
					ui::text 1035 [ui::lh $top i13 48] "••••••••••" i13 $c(muted) e 2
				}
				ui::icon eye 15 $c(muted) 1045 [expr {$cy - 7.5}] 1.9
				nm::hit 1041 [expr {$cy - 12}] 23 24 [list nm::toggle_reveal_chosen]
			}
		}
		incr top 48
		if {$r ne [lindex $rows end]} { ui::hline 625 1060 [expr {$top - 1}] $c(border) }
	}
}

# The chosen saved network's toggles and reveal (the page's hits, off while a sheet is open).
proc nm::flip_chosen {key} {
	set ch [nm::chosen]
	if {[dict get $ch kind] ne "ap"} return
	set p [nm::profile_for [dict get [dict get $ch ap] ssid]]
	if {$p ne ""} { nm::flip $p $key }
}

proc nm::toggle_reveal_chosen {} {
	set ch [nm::chosen]
	if {[dict get $ch kind] ne "ap"} return
	set p [nm::profile_for [dict get [dict get $ch ap] ssid]]
	if {$p ne ""} { nm::toggle_reveal $p }
}

# The Hidden network row, under the networks (44 tall, the plus at the icon's place).
proc nm::draw_hidden_row {y} {
	array set c [array get ui::c]
	ui::icon plus 16 $c(muted) 282 [expr {$y + 14}]
	ui::text 312 [ui::lh $y i13m 44] "Hidden network…" i13m $c(muted)
	nm::hit 270 $y 290 44 [list nm::sheet_open hidden]
}

# A VPN row (52 tall): its name, its state, and a switch that brings it up or down.
proc nm::draw_vpn_row {v y chosen} {
	array set c [array get ui::c]
	set path [dict get $v path]
	if {$path eq $chosen} { ui::box 270 $y 290 52 -fill $c(field) -radius 10 }
	ui::icon shield 16 $c(muted) 282 [expr {$y + 18}]
	ui::text 312 [ui::lh [expr {$y + 8}] i13s 22] [dict get $v id] i13s $c(fg)
	set on [expr {[dict get $v active] ne ""}]
	ui::text 312 [ui::lh [expr {$y + 30}] i12 18] "WireGuard" i12 $c(muted)
	ui::toggle 510 [expr {$y + 15}] $on
	nm::hit 510 [expr {$y + 15}] 38 22 [list nm::vpn_switch $v $on]
	nm::hit 270 $y 230 52 [list nm::pick $path]
}

proc nm::vpn_switch {v on} {
	nm::job nm::vpn_toggle [dict get $v path] [dict get $v active] [expr {!$on}]
}

# The footer's left button and the saved network's actions (Forget, Save), drawn by page-network's footer.
proc nm::draw_actions {ch} {
	if {$::nm::sheet ne ""} return
	set kind [dict get $ch kind]
	ui::button nm_add 270 665 "Add connection" ghost nm::sheet_open_wg "plus" [ui::button_w "Add connection" ghost plus]
	if {$kind eq "vpn"} {
		set v [dict get $ch vpn]
		nm::footer_button nm_vpn_forget Forget ghost [list nm::forget_run [dict get $v path]]
		return
	}
	if {$kind ne "ap"} return
	set ap [dict get $ch ap]
	set p [nm::profile_for [dict get $ap ssid]]
	if {$p eq ""} return
	nm::footer_button nm_save Save primary [list nm::save $p]
	nm::footer_button nm_forget Forget ghost [list nm::forget_run [dict get $p path]]
}

proc nm::forget_run {path} {
	nm::forget_edits
	set ::nm::sel ""
	nm::job nm::forget $path
}

proc nm::sheet_open_wg {} { nm::sheet_open wireguard }
