# ui-account.tcl - Mail's Add an account sheet (U42, Mail-A6-Account; design/tools/gen_mail.py a6_account): over the
# shaded window, the provider (Gmail, Outlook, Fastmail, iCloud, IMAP), Name, Email, User name, Password (shown with
# the eye), the incoming IMAP and outgoing SMTP servers (host, port, SSL/TLS / STARTTLS / None, Normal password), and
# Test connection, Cancel, Add account. Read by accounts.tcl when Tk is there; main.tcl draws it from its paint.
#
# A named provider fills in its servers; IMAP finds them for the address (mail::accounts::detect) when the Email field
# is left, unless they were typed in by hand. Test connection logs in to both servers; Add account does the same, and
# only then saves the password to the Secret Service and the account to its file. What they found is the line left
# of Cancel (the composer's line: muted, the accent for a failure).
#
#   mail::accounts::sheet DONE        open the sheet; DONE is called with the new account's name once it is added
#   mail::accounts::sheet_up          1 while it is open
#   mail::accounts::sheet_paint       its drawing, last in mailapp::paint (the window drawn shaded under it)
#   mail::accounts::sheet_place       its text fields placed over the canvas (after the drawing)
#   mail::accounts::sheet_escape      Escape: the open menu, else the sheet (Cancel)

namespace eval ::mail::accounts {
	variable sh
	array set sh {menu "" up 0 done "" provider imap pop "" show 0 status "" bad 0 busy 0 edited 0 useredited 0 auto "" focus "" x 0 y 0 detecting ""}
	variable sec
	array set sec {imap tls smtp tls}
	variable entries {name email user password imaphost imapport smtphost smtpport}
	variable secnames {tls SSL/TLS starttls STARTTLS none None}
	variable runs 0
	variable SW 700
	variable SH 614
}
array set ::ui::fonts {
	sg18 {{Ribbon Space Grotesk 600} 18 0.984 0.292}
	sg20 {{Ribbon Space Grotesk 600} 20 0.984 0.292}
}
array set ::mailapp::paths {
	at {M12 16a4 4 0 1 0 0-8 4 4 0 0 0 0 8z M16 8v5a3 3 0 0 0 6 0v-1a10 10 0 1 0-3.92 7.94}
	server {M2 4h20v6H2z M2 14h20v6H2z M6 7h.01 M6 17h.01}
	eye {M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z M9 12a3 3 0 1 0 6 0a3 3 0 1 0 -6 0}
	check {M20 6L9 17l-5-5}
}

proc ::mail::accounts::W {f} { return $::mailapp::win.acc_$f }

proc ::mail::accounts::sheet {done} {
	variable sh
	variable sec
	variable entries
	set c [array get ::mailapp::c]
	if {$sh(up)} return
	array set sh [list up 1 done $done provider imap pop "" show 0 status "" bad 0 busy 0 edited 0 useredited 0 auto "" detecting ""]
	array set sec {imap tls smtp tls}
	set ::mailapp::state(searchfocus) 0
	foreach f $entries {
		set w [W $f]
		destroy $w
		entry $w -font ui_i14 -borderwidth 0 -highlightthickness 0 -relief flat -background $::mailapp::c(field) \
			-foreground $::mailapp::c(fg) -insertbackground $::mailapp::c(accent) -insertwidth 2 -insertborderwidth 0 \
			-selectbackground $::mailapp::c(hit) -selectforeground $::mailapp::c(fg) -selectborderwidth 0
		bind $w <FocusIn> [list ::mail::accounts::Focus $f]
		bind $w <FocusOut> [list ::mail::accounts::Unfocus $f]
		bind $w <KeyRelease> [list ::mail::accounts::Typed $f %K]
		bind $w <Return> {::mail::accounts::Add; break}
		bind $w <KP_Enter> {::mail::accounts::Add; break}
		bind $w <Escape> {::mail::accounts::sheet_escape; break}
	}
	[W password] configure -show •
	foreach f {imapport smtpport} { [W $f] insert 0 [expr {$f eq "imapport" ? 993 : 465}] }
	mailapp::paint
	focus [W name]
}

proc ::mail::accounts::sheet_up {} { return $::mail::accounts::sh(up) }

proc ::mail::accounts::Close {} {
	variable sh
	variable entries
	foreach f $entries { destroy [W $f] }
	set sh(up) 0
	set sh(pop) ""
	focus $::mailapp::win
	mailapp::paint
}

proc ::mail::accounts::sheet_escape {} {
	variable sh
	if {$sh(pop) ne ""} { set sh(pop) ""; mailapp::paint; return }
	Cancel
}

proc ::mail::accounts::Cancel {} {
	variable sh
	set sh(busy) 0
	Close
}

proc ::mail::accounts::Nothing {} {}

proc ::mail::accounts::Val {f} { string trim [[W $f] get] }
proc ::mail::accounts::Set {f v} {
	set w [W $f]
	$w delete 0 end
	$w insert 0 $v
}

# The sheet's fields as a dict for check, test and add.
proc ::mail::accounts::Form {} {
	variable sec
	dict create name [Val name] address [Val email] user [Val user] \
		imap [list [Val imaphost] [Val imapport] $sec(imap)] smtp [list [Val smtphost] [Val smtpport] $sec(smtp)]
}

foreach {k v} {check {M20 6L9 17l-5-5} alert {M12 2a10 10 0 1 0 0 20a10 10 0 1 0 0-20z M12 8v4 M12 16h.01}} {
	if {![info exists ::mailapp::paths($k)]} { set ::mailapp::paths($k) $v }
}
# BAD: 0 a step under way, 1 refused, 2 both servers answered
proc ::mail::accounts::Say {text {bad 0}} {
	variable sh
	set sh(status) $text
	set sh(bad) $bad
	if {$sh(up)} { mailapp::paint }
}

# ---- what typing does --------------------------------------------------------------------------------------------------
proc ::mail::accounts::Focus {f} {
	variable sh
	set sh(focus) $f
	set sh(pop) ""
	mailapp::paint
}
proc ::mail::accounts::Unfocus {f} {
	variable sh
	if {$sh(focus) eq $f} { set sh(focus) "" }
	if {$f eq "email"} { Lookup }
	if {$sh(up)} { mailapp::paint }
}
proc ::mail::accounts::Typed {f sym} {
	variable sh
	switch -- $f {
		email {
			# the user name follows the address until it is typed in itself
			if {!$sh(useredited)} { Set user [Val email] }
		}
		user { set sh(useredited) 1 }
		imaphost - imapport - smtphost - smtpport { if {$sym ni {Tab ISO_Left_Tab Shift_L Shift_R Control_L Control_R}} { set sh(edited) 1 } }
	}
}

proc ::mail::accounts::Fill {imap smtp} {
	variable sec
	lassign $imap h p s
	Set imaphost $h; Set imapport $p; set sec(imap) $s
	lassign $smtp h p s
	Set smtphost $h; Set smtpport $p; set sec(smtp) $s
}

proc ::mail::accounts::Provider {key} {
	variable sh
	set sh(provider) $key
	set sh(pop) ""
	if {$key ne "imap"} {
		set p [provider $key]
		Fill [dict get $p imap] [dict get $p smtp]
		set sh(edited) 0
	} else {
		Lookup 1
	}
	mailapp::paint
}

# Finds the servers for the address (IMAP chosen, servers not typed in by hand).
proc ::mail::accounts::Lookup {{force 0}} {
	variable sh
	set e [Val email]
	if {!$sh(up) || $sh(provider) ne "imap" || $sh(edited) || ![valid_address $e]} return
	if {!$force && $sh(auto) eq [string tolower $e]} return
	set sh(auto) [string tolower $e]
	set sh(detecting) [string tolower $e]
	Say "Looking up [lindex [split $e @] end]…"
	detect $e [list ::mail::accounts::Found [string tolower $e]]
}
proc ::mail::accounts::Found {email r} {
	variable sh
	variable providers
	if {!$sh(up) || $sh(detecting) ne $email} return
	set sh(detecting) ""
	if {$sh(edited) || $sh(provider) ne "imap" || [string tolower [Val email]] ne $email} { Say ""; return }
	Fill [dict get $r imap] [dict get $r smtp]
	if {!$sh(useredited)} { Set user [dict get $r user] }
	# a named provider's servers: its card
	if {[dict exists $providers [dict get $r source]]} { set sh(provider) [dict get $r source] }
	Say ""
}

proc ::mail::accounts::Security {which key} {
	variable sec
	variable sh
	set defaults {imap {tls 993 starttls 143 none 143} smtp {tls 465 starttls 587 none 587}}
	set port [Val ${which}port]
	if {$port eq "" || $port == [dict get $defaults $which $sec($which)]} { Set ${which}port [dict get $defaults $which $key] }
	set sec($which) $key
	set sh(edited) 1
	set sh(pop) ""
	mailapp::paint
}

proc ::mail::accounts::Pop {which} {
	variable sh
	set sh(pop) [expr {$sh(pop) eq $which ? "" : $which}]
	mailapp::paint
}

proc ::mail::accounts::Eye {} {
	variable sh
	set sh(show) [expr {!$sh(show)}]
	[W password] configure -show [expr {$sh(show) ? "" : "•"}]
	mailapp::paint
}

# ---- Test connection and Add account ----------------------------------------------------------------------------------
proc ::mail::accounts::Problem {which r} {
	lassign $r - kind msg
	set w [string toupper $which]
	switch -- $kind {
		auth { return "$w: wrong user name or password" }
		resolve { return "$w server not found" }
		connect { return "No connection to the $w server" }
		tls { return "$w: the certificate is not trusted" }
		insecure { return "$w needs SSL/TLS or STARTTLS" }
		default { return "$w: $msg" }
	}
}

proc ::mail::accounts::Run {then} {
	variable sh
	if {$sh(busy)} return
	set d [Form]
	set msg [check $d]
	if {$then eq "test" && [string match "* is in Mail already" $msg]} { set msg "" }
	if {$msg ne ""} { Say $msg 1; return }
	set pw [[W password] get]
	if {$pw eq ""} { Say "The password is empty" 1; return }
	# busy holds the run's number: an answer for a run left by Cancel (or an earlier sheet) is not this one's
	variable runs
	set sh(busy) [incr runs]
	Say [expr {$then eq "test" ? "Testing…" : "Logging in…"}]
	test $d $pw [list ::mail::accounts::Ran $sh(busy) $then $d $pw]
}
proc ::mail::accounts::Ran {run then d pw r} {
	variable sh
	if {!$sh(up) || $sh(busy) != $run} return
	set sh(busy) 0
	foreach k {imap smtp} {
		if {[dict get $r $k] ne "ok"} { Say [Problem $k [dict get $r $k]] 1; return }
	}
	if {$then eq "test"} { Say "IMAP and SMTP log in" 2; return }
	# the password that logged in, not one typed meanwhile
	if {[catch {add $d $pw} name]} { Say $name 1; return }
	catch {mail::store::create_folder $name Inbox}
	set done $sh(done)
	Close
	if {$done ne ""} { uplevel #0 [list {*}$done $name] }
}
proc ::mail::accounts::Test {} { Run test }
proc ::mail::accounts::Add {} { Run add }

# ---- drawing -----------------------------------------------------------------------------------------------------------
proc ::mail::accounts::Label {x y t} {
	ui::text $x $y [string toupper $t] i11s $::mailapp::c(muted) w 1.32
}

proc ::mail::accounts::Field {f x y w} {
	variable sh
	set c $::mailapp::c(field)
	ui::box $x $y $w 38 -fill $c -radius 10
	if {$sh(focus) eq $f} {
		ui::ring $x $y $w 38 10 $::mailapp::c(accent) 1.5
	} else {
		ui::ring $x $y $w 38 10 $::mailapp::c(border) 1
	}
	ui::hit $x $y $w 38 [list focus [W $f]]
	set sh(at,$f) [list $x $y $w]
}

proc ::mail::accounts::Drop {which x y w} {
	variable sh
	variable sec
	variable secnames
	set mc $::mailapp::c(muted)
	foreach {k part} [list sec [list $x 120] auth [list [expr {$x + 128}] [expr {$w - 128}]]] {
		lassign $part dx dw
		ui::box $dx $y $dw 38 -fill $::mailapp::c(field) -radius 10
		ui::ring $dx $y $dw 38 10 [expr {$sh(pop) eq "$which$k" ? $::mailapp::c(accent) : $::mailapp::c(border)}] [expr {$sh(pop) eq "$which$k" ? 1.5 : 1}]
		set label [expr {$k eq "sec" ? [dict get $secnames $sec($which)] : "Normal password"}]
		ui::text [expr {$dx + 12}] [expr {$y + 10.5}] $label i14 $::mailapp::c(fg)
		mailapp::icon chev 14 $mc [expr {$dx + $dw - 24}] [expr {$y + 10.5}] 2
		ui::hit $dx $y $dw 38 [list ::mail::accounts::Pop $which$k]
		set sh(drop,$which$k) [list $dx $y $dw]
	}
}

# A button of the sheet (ui::button's look; Mail's hits take no coordinates).
proc ::mail::accounts::Button {x y label kind script {icon ""}} {
	set c [array get ::mailapp::c]
	set f [expr {$kind eq "primary" ? "i14s" : "i14"}]
	set w [ui::button_w $label $kind $icon]
	switch $kind {
		primary { ui::box $x $y $w 38 -fill [dict get $c accent] -radius 10; set fg [dict get $c ink] }
		ghost { ui::ring $x $y $w 38 10 [dict get $c border] 1; set fg [dict get $c fg] }
		field { ui::box $x $y $w 38 -fill [dict get $c field] -radius 10; set fg [dict get $c fg] }
	}
	set tw [ui::text [expr {$x + 18}] [expr {$y + 10.5}] $label $f $fg]
	if {$icon ne ""} { mailapp::icon $icon 15 $fg [expr {$x + 18 + $tw + 8}] [expr {$y + 11.5}] 2 }
	ui::hit $x $y $w 38 $script
	return $w
}

proc ::mail::accounts::sheet_paint {} {
	variable sh
	variable SW
	variable SH
	variable providers
	if {!$sh(up)} return
	array set c [array get ::mailapp::c]
	set x [expr {($::mailapp::W - $SW) / 2}]
	set y [expr {max(12, ($::mailapp::H - $SH + 2) / 2)}]
	set sh(x) $x; set sh(y) $y
	ui::layer
	# nothing under the sheet takes a click while it is open
	ui::hit 0 0 $::mailapp::W $::mailapp::H ::mail::accounts::Nothing
	raster::box $::ui::img $x $y $SW $SH -fill [ui::col $c(bar)] -radius 16 -ring [list $c(border) 1] -shadow {24 64 0.6}
	# the head: the tile, the title and where the mail is kept
	ui::box [expr {$x + 28}] [expr {$y + 26}] 44 44 -fill [ui::mix $c(pill) $c(field) 0.5] -radius 12 -ring [list $c(border) 1]
	mailapp::icon at 22 $c(fg) [expr {$x + 39}] [expr {$y + 37}] 1.7
	ui::text [expr {$x + 86}] [expr {$y + 25}] "Add an account" sg20 $c(fg) w -0.4
	ui::text [expr {$x + 86}] [expr {$y + 53}] "Kept in ~/Mail on this computer" i13 $c(muted)
	ui::hline [expr {$x + 28}] [expr {$x + $SW - 28}] [expr {$y + 88}] $c(border)
	# the providers
	Label [expr {$x + 28}] [expr {$y + 110}] Provider
	set i 0
	foreach k {gmail outlook fastmail icloud imap} letter {G O F i ""} {
		set tx [expr {$x + 28 + $i * 130.8}]
		set ty [expr {$y + 135}]
		set on [expr {$sh(provider) eq $k}]
		if {$on} {
			ui::box $tx $ty 120.8 84 -fill $c(field) -radius 12
			ui::ring $tx $ty 120.8 84 12 $c(accent) 1.5
		} else {
			ui::ring $tx $ty 120.8 84 12 $c(border) 1
		}
		ui::box [expr {$tx + 43.4}] [expr {$ty + 12.5}] 34 34 -fill $c(pill) -radius 10
		if {$k eq "imap"} {
			mailapp::icon server 20 $c(fg) [expr {$tx + 50.4}] [expr {$ty + 19.5}] 1.8
			set name IMAP
		} else {
			ui::text [expr {$tx + 60.4}] [expr {$ty + 18}] $letter sg18 $c(fg) c
			set name [dict get $providers $k name]
		}
		ui::text [expr {$tx + 60.4}] [expr {$ty + 55.5}] $name [expr {$on ? "i13s" : "i13m"}] [expr {$on ? $c(fg) : $c(muted)}] c
		ui::hit $tx $ty 120.8 84 [list ::mail::accounts::Provider $k]
		incr i
	}
	# the person and the login
	set lx [expr {$x + 28}]; set rx [expr {$x + 366}]
	Label $lx [expr {$y + 243}] Name
	Label $rx [expr {$y + 243}] Email
	Field name $lx [expr {$y + 268}] 306
	Field email $rx [expr {$y + 268}] 306
	Label $lx [expr {$y + 322}] "User name"
	Label $rx [expr {$y + 322}] Password
	Field user $lx [expr {$y + 347}] 306
	Field password $rx [expr {$y + 347}] 306
	mailapp::icon eye 15 [expr {$sh(show) ? $c(fg) : $c(muted)}] [expr {$rx + 279}] [expr {$y + 358.5}] 1.9
	ui::hit [expr {$rx + 270}] [expr {$y + 347}] 36 38 ::mail::accounts::Eye
	# the servers
	foreach which {imap smtp} sx [list $lx $rx] t {"Incoming · IMAP" "Outgoing · SMTP"} {
		Label $sx [expr {$y + 409}] $t
		Field ${which}host $sx [expr {$y + 434}] 235.1
		Field ${which}port [expr {$sx + 243.1}] [expr {$y + 434}] 62.9
		Drop $which $sx [expr {$y + 480}] 306
	}
	# the foot
	ui::hline $x [expr {$x + $SW}] [expr {$y + $SH - 72}] $c(border)
	set by [expr {$y + $SH - 55}]
	set tw [Button [expr {$x + 28}] $by "Test connection" ghost ::mail::accounts::Test checks]
	set aw [ui::button_w "Add account" primary]
	set ax [expr {$x + $SW - 28 - $aw}]
	Button $ax $by "Add account" primary ::mail::accounts::Add
	set cw [ui::button_w Cancel field]
	set cx [expr {$ax - 10 - $cw}]
	Button $cx $by Cancel field ::mail::accounts::Cancel
	# the answer (Mail-A15-Tested, -A16-Refused): a check and the text when both servers took the login, the accent
	# and a mark when something was refused; "Testing…" and the like plain
	if {$sh(status) ne ""} {
		set room [expr {$cx - 14 - ($x + 28 + $tw + 14)}]
		set col [dict get [list 0 $c(muted) 1 $c(accent) 2 $c(fg)] $sh(bad)]
		set mark [dict get {0 "" 1 alert 2 check} $sh(bad)]
		if {$mark ne ""} { set room [expr {$room - 21}] }
		set t [mailapp::elide i12 $sh(status) $room]
		ui::text [expr {$cx - 14}] [expr {$by + 11.5}] $t i12 $col e
		if {$mark ne ""} { mailapp::icon $mark 14 $col [expr {$cx - 14 - [ui::measure i12 $t] - 21}] [expr {$by + 12}] 2.2 }
	}
	if {$sh(pop) ne ""} { Menu }
}

# The open menu of a server's security or login (Settings' dropdown: rows of 36, the choice checked).
proc ::mail::accounts::Menu {} {
	variable sh
	variable sec
	variable secnames
	array set c [array get ::mailapp::c]
	set which [string range $sh(pop) 0 3]
	set kind [string range $sh(pop) 4 end]
	lassign $sh(drop,$sh(pop)) dx dy dw
	if {$kind eq "sec"} {
		set items {}
		foreach {k l} $secnames { lappend items [list $k $l] }
		set cur $sec($which)
	} else {
		set items {{password {Normal password}}}
		set cur password
	}
	set w [expr {max($dw, 190)}]
	set h [expr {12 + 36 * [llength $items]}]
	set top [expr {$dy + 44}]
	# no room below in the window: above the dropdown
	if {$top + $h > $::mailapp::H - 8} { set top [expr {$dy - 6 - $h}] }
	set sh(menu) [list $dx $top [expr {$dx + $w}] [expr {$top + $h}]]
	ui::layer
	ui::hit 0 0 $::mailapp::W $::mailapp::H [list set ::mail::accounts::sh(pop) ""]\;mailapp::paint
	raster::box $::ui::img [expr {round($dx)}] [expr {round($top)}] $w $h -fill [ui::col $c(bar)] -radius 12 -ring [list $c(border) 1] -shadow {16 40 0.5}
	set i 0
	foreach it $items {
		lassign $it k label
		set iy [expr {$top + 6 + 36 * $i}]
		set on [expr {$k eq $cur}]
		set f [expr {$on ? "i13s" : "i13m"}]
		ui::text [expr {$dx + 18}] [expr {$iy + 10}] $label $f $c(fg)
		if {$on} { mailapp::icon check 14 $c(accent) [expr {$dx + $w - 32}] [expr {$iy + 11}] 2.4 }
		ui::hit [expr {$dx + 6}] $iy [expr {$w - 12}] 36 [expr {$kind eq "sec" ? [list ::mail::accounts::Security $which $k] : [list ::mail::accounts::Pop $sh(pop)]}]
		incr i
	}
}

# The entries over their boxes (a menu open over one hides it).
proc ::mail::accounts::sheet_place {} {
	variable sh
	variable entries
	if {!$sh(up)} return
	if {[winfo exists $::mailapp::rtext]} { place forget $::mailapp::rtext }
	set menu [expr {$sh(pop) ne "" ? $sh(menu) : ""}]
	foreach f $entries {
		lassign $sh(at,$f) x y w
		set ew [expr {$w - 24 - ($f eq "password" ? 30 : 0)}]
		set ok 1
		if {$menu ne ""} {
			lassign $menu mx0 my0 mx1 my1
			if {$x < $mx1 && $x + $w > $mx0 && $y < $my1 && $y + 38 > $my0} { set ok 0 }
		}
		if {$ok} { place [W $f] -x [expr {round($x + 12)}] -y [expr {round($y + 9)}] -width [expr {round($ew)}] -height 20 } else { place forget [W $f] }
	}
}
