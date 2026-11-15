# page-users.tcl - Settings → Users (boards Settings-A9-Users, and its sheets -A9b-Users-Add, -A9c-Users-Password,
# -A9d-Users-Remove): the people with an account on the left as Network's and Bluetooth's list (the tile with the
# initial, the name, Administrator or Standard, "you"), the chosen one on the right (Name with its pencil, Password,
# Administrator, Log in without a password), Add user and Remove in the footer. The logic is users.tcl; every change
# is one run of the helper behind pkexec (bin/ribbon-users-helper has the security design).
#
# What is drawn is what can be done here:
#   - Administrator is there where the system has a wheel group;
#   - Log in without a password is there where the login screen's PAM stack honours the group nopasswdlogin
#     (users.tcl reads /etc/pam.d/greetd); without that the switch would do nothing, so it is left out;
#   - Remove is there for an account that may be removed: not your own, not the only administrator.
# A switch shows what /etc/group says: a refused change or a dismissed password prompt leaves it as it was.
#
# Passwords. They are typed into masked fields (dots; nothing reveals them), handed to users.tcl once, and the
# fields are emptied at that moment, whatever comes of the change: a sheet that stays open after a failure has
# empty password fields. users.tcl writes them to the helper's (or passwd's) standard input and nowhere else.
#
# A sheet's primary button does its job when the form can be sent; otherwise it puts the caret in the first field
# that cannot (a name that is taken or is not a user name, an empty password, two that differ). A change that
# failed says why in the sheet's second line, as a page's subtitle does.
#
# Layout (window coordinates, as Bluetooth's): the list is 290 wide from 270 in 52 px rows from 119 (no label over it: the title names it), a rule at 592
# from 119 to 648, the detail from 625 to 1060 in 48 px rows from 209, the footer under a rule at 648. The sheets
# are sctl::sheet (520 wide): 58 px rows from 94 under its top, the label at 28, a 308 px field at 184.

source -encoding utf-8 [file join [file dirname [file normalize [info script]]] users.tcl]

settings::page users -title Users -icon users -group 4 -order 1 -draw settings::draw_users \
	-rows {Users Name Password Administrator {Log in without a password} {Add user} Remove}

array set ::ui::paths {
	users_user  {M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2 M12 11a4 4 0 1 0 0-8a4 4 0 1 0 0 8z}
	users_none  {M48 48}
}
foreach {k v} {
	sg12 {{Ribbon Space Grotesk 600} 12 0.984 0.292}
	sg20 {{Ribbon Space Grotesk 600} 20 0.984 0.292}
} { if {![info exists ::ui::fonts($k)]} { set ::ui::fonts($k) $v; catch {text::font ui_$k {*}[lrange $v 0 1]} } }

namespace eval usp {
	variable started 0
	variable sel ""          ;# the chosen login ("" yours, else the first)
	variable top 0           ;# the first row of the list that is shown
	variable edit 0          ;# the name is a field
	variable drawn 0
	variable target ""       ;# the login a sheet is about
	variable admin 0         ;# the Add sheet's Administrator switch
	variable keep 0          ;# the Remove sheet's Keep the home folder switch
	variable typed 0         ;# the Add sheet's Username was typed (it no longer follows the full name)
	variable said ""         ;# why the sheet's change failed
	variable ROWS 10         ;# rows of the list that fit
	variable SECRETS {us-cur us-pw1 us-pw2}
}

# ---- small things -----------------------------------------------------------------------------------

proc usp::users {} { dict get [users::model] users }
# The user on the right: the chosen one while the account is there, else you, else the first.
proc usp::chosen {} {
	variable sel
	set first ""; set you ""
	foreach u [users] {
		if {[dict get $u login] eq $sel} { return $u }
		if {$first eq ""} { set first $u }
		if {[dict get $u you]} { set you $u }
	}
	expr {$you ne "" ? $you : $first}
}
proc usp::initial {u} { string toupper [string index [dict get $u name] 0] }
proc usp::kind {u} { expr {[dict get $u admin] ? "Administrator" : "Standard"} }
proc usp::redraw {script} { list apply {{s} { uplevel #0 $s; page::draw }} $script }

# The avatar tile: SIZE px at X Y (28 in the list, 44 in the head and the sheets) with the initial.
proc usp::tile {x y size u {colour ""}} {
	array set c [array get ui::c]
	if {$colour eq ""} { set colour $c(fg) }
	if {$size == 28} {
		ui::box $x $y 28 28 -fill $c(pill) -radius 8
		ui::text [expr {$x + 14}] [expr {$y + 6}] [initial $u] sg12 $colour c
	} else {
		ui::box $x $y 44 44 -fill $c(pill) -radius 12
		ui::text [expr {$x + 22}] [expr {$y + 11}] [initial $u] sg17 $colour c
	}
}

# Forget what the password fields hold: each value is overwritten, then emptied.
proc usp::wipe {} {
	variable SECRETS
	foreach id $SECRETS {
		if {[info exists ::ui::fld($id,text)]} { set ::ui::fld($id,text) [string repeat x [string length $::ui::fld($id,text)]] }
		set ::ui::fld($id,text) ""
		set ::ui::fld($id,cur) 0
	}
}

# A password field (308 x 38 on the boards): the field's box and ring, its text as dots 2 px apart, the caret.
# Nothing draws the text itself. Typing is ui.tcl's own field editing (kind field); Return runs ONENTER.
proc usp::secret {id x y w onenter} {
	array set c [array get ui::c]
	set on [expr {$ui::focus eq $id}]
	set n [string length [ui::fval $id]]
	ui::box $x $y $w 38 -fill $c(field) -radius 10
	if {$on} { ui::ring $x $y $w 38 10 $c(accent) 1.5 } else { ui::ring $x $y $w 38 10 $c(border) 1 }
	set tx [expr {$x + 12}]
	set dot [ui::measure i14 "•" 2]
	set fit [expr {int(($w - 28) / $dot)}]
	set cur [expr {min($::ui::fld($id,cur), $n)}]
	# more dots than fit: the ones around the caret
	set from [expr {max(0, min($cur, $n - $fit))}]
	if {$cur < $from} { set from $cur }
	set shown [expr {min($fit, $n - $from)}]
	if {$shown > 0} { ui::text $tx [ui::lh $y i14 38] [string repeat "•" $shown] i14 $c(fg) w 2 }
	if {$on} { ui::caret_at [expr {$tx + ($cur - $from) * $dot + 1}] [expr {$y + 11}] }
	ui::hit $x $y $w 38 [list usp::secret_click $id $tx $dot $from]
	ui::focusable $id field $x $y $w 38 10 [list "" $onenter 128]
}
proc usp::secret_click {id tx dot from x y} {
	set ::ui::caret 1
	set ui::focus $id
	set n [string length [ui::fval $id]]
	set ::ui::fld($id,cur) [expr {max(0, min($n, $from + int(round(($x - $tx) / $dot))))}]
	page::draw
}

# ---- the list ---------------------------------------------------------------------------------------

proc usp::scroll {d} {
	variable top; variable ROWS
	set top [expr {max(0, min([llength [users]] - $ROWS, $top + $d))}]
	page::draw
}
proc usp::choose {login} {
	variable sel $login
	variable edit 0
}
proc usp::draw_list {cur} {
	variable top; variable ROWS
	array set c [array get ui::c]
	set all [users]
	set top [expr {max(0, min([llength $all] - $ROWS, $top))}]
	set y 119
	foreach u [lrange $all $top [expr {$top + $ROWS - 1}]] {
		set login [dict get $u login]
		set on [expr {$cur ne "" && $login eq [dict get $cur login]}]
		if {$on} { ui::box 270 $y 290 52 -fill $c(field) -radius 10 -ring [list $c(border) 1] }
		tile 282 [expr {$y + 12}] 28 $u [expr {$on ? $c(fg) : $c(muted)}]
		ui::text 322 [expr {$y + 9.5}] [sctl::clip [dict get $u name] 226 i13s] [expr {$on ? "i13s" : "i13m"}] $c(fg)
		ui::text 322 [expr {$y + 27.5}] "[kind $u][expr {[dict get $u you] ? " · you" : ""}]" i12 $c(muted)
		sctl::hit 270 $y 290 52 [list usp::choose $login]
		ui::focusable us-user-$login button 270 $y 290 52 10 [redraw [list usp::choose $login]]
		incr y 52
	}
	if {[llength $all] > $ROWS} { ui::wheel 270 119 290 [expr {52 * $ROWS}] usp::scroll }
}

# ---- the chosen user ----------------------------------------------------------------------------------

# The Name row's value: the name and its pencil, or (after a click on them) a field; Return saves.
proc usp::draw_name {u y} {
	variable edit
	array set c [array get ui::c]
	if {$edit} {
		ui::field us-name 820 [expr {$y + 9}] 240 -h 30 -font i13 -pad 10 -radius 8 -max 120 -onenter usp::name_save
		return
	}
	set name [sctl::clip [dict get $u name] 300]
	set w [ui::text 1036 [expr {$y + 16}] $name i13 $c(fg) e]
	ui::icon edit 14 $c(muted) 1046 [expr {$y + 17}] 1.9
	if {$users::busy} return
	sctl::hit [expr {1032 - $w}] [expr {$y + 8}] [expr {$w + 32}] 32 usp::name_edit
	ui::focusable us-name-edit button 1042 [expr {$y + 13}] 22 22 6 [redraw usp::name_edit]
}
proc usp::name_edit {} {
	variable edit 1
	variable drawn $ui::drawno
	set u [chosen]
	if {$u eq ""} { set edit 0; return }
	ui::fset us-name [dict get $u name]
	set ui::focus us-name
	set ::ui::caret 1
}
# Return: an empty name keeps the field; the name it already has changes nothing.
proc usp::name_save {} {
	variable edit
	set u [chosen]
	set name [users::clean_name [ui::fval us-name]]
	if {$u eq "" || $name eq ""} return
	set edit 0
	set ui::focus ""
	if {$name ne [dict get $u name]} { users::rename [dict get $u login] $name }
}

proc usp::draw_detail {u} {
	array set c [array get ui::c]
	set m [users::model]
	set login [dict get $u login]
	tile 625 119 44 $u
	ui::text 683 120.5 [sctl::clip [dict get $u name] 370 sg17] sg17 $c(fg)
	ui::text 683 145.5 "$login · [kind $u]" i13 $c(muted)
	sctl::label 625 187 Account
	set rows {name password}
	if {[dict get $m wheel]} { lappend rows admin }
	if {[dict get $m nopass]} { lappend rows nopass }
	set y 209
	foreach r $rows {
		set last [expr {$r eq [lindex $rows end]}]
		switch -- $r {
			name {
				sctl::row 625 1060 $y Name $last
				draw_name $u $y
			}
			password {
				sctl::row 625 1060 $y Password $last
				set w [ui::button_w "Change…" field]
				ui::button us-password [expr {1060 - $w}] [expr {$y + 5}] "Change…" field [redraw [list usp::open password $login]]
			}
			admin {
				sctl::row 625 1060 $y Administrator $last
				set on [dict get $u admin]
				sctl::toggle us-admin 1060 $y $on [list users::set_admin $login [expr {!$on}]]
			}
			nopass {
				sctl::row 625 1060 $y "Log in without a password" $last
				set on [dict get $u nopass]
				sctl::toggle us-nopass 1060 $y $on [list users::set_nopass $login [expr {!$on}]]
			}
		}
		incr y 48
	}
}

# The footer: Add user at the left; Remove (ghost, the bin) at the right for an account that may be removed.
proc usp::draw_footer {u} {
	ui::button us-add 270 665 "Add user" field [redraw {usp::open add ""}] plus
	if {$u eq "" || [users::removable [dict get $u login]] ne ""} return
	set w [ui::button_w Remove ghost trash]
	ui::button us-remove [expr {1060 - $w}] 665 Remove ghost [redraw [list usp::open remove [dict get $u login]]] trash
}

# ---- the sheets ---------------------------------------------------------------------------------------

proc usp::open {name login} {
	variable target $login
	variable admin 0
	variable keep 0
	variable typed 0
	variable said ""
	variable edit 0
	if {$users::busy} return
	wipe
	ui::fset us-full ""
	ui::fset us-login ""
	sctl::sheet_open $name usp::closed
	set ui::focus [dict get {add us-full password us-pw1 remove ""} $name]
	if {$name eq "password" && [own]} { set ui::focus us-cur }
	set ::ui::caret 1
}
# Escape, Cancel, or the change was made: nothing typed is kept.
proc usp::closed {} {
	variable said ""
	wipe
}
proc usp::cancel {} {
	if {$users::busy} return
	sctl::sheet_close
	closed
}
# The sheet's account is yours: its password sheet asks for the current password.
proc usp::own {} {
	variable target
	set u [users::user $target]
	expr {$u ne "" && [dict get $u you]}
}
proc usp::rows {name} {
	switch -- $name {
		add { expr {[dict get [users::model] wheel] ? {full login pw1 pw2 admin} : {full login pw1 pw2}} }
		password { expr {[own] ? {cur pw1 pw2} : {pw1 pw2}} }
		remove { list keep }
	}
}
# The Add sheet's Username follows the full name until it is typed in.
proc usp::full_typed {} {
	variable typed
	if {!$typed} { ui::fset us-login [users::suggest_login [ui::fval us-full]] }
}
proc usp::login_typed {} { variable typed 1 }

proc usp::sheet {name} {
	variable target; variable admin; variable keep; variable said
	array set c [array get ui::c]
	set u [users::user $target]
	if {$name ne "add" && $u eq ""} {
		# the account went away under the sheet
		after idle usp::cancel
		return
	}
	set rows [rows $name]
	set h [expr {170 + 58 * [llength $rows]}]
	switch -- $name {
		add { set title "Add user"; set sub Users; set icon users_user; set go Add; set gi plus }
		password { set title "Password for [dict get $u name]"; set sub "$target · [kind $u]"; set icon users_none; set go Change; set gi check }
		remove { set title "Remove [dict get $u name]"; set sub "$target · [kind $u]"; set icon users_none; set go Remove; set gi trash }
	}
	if {$said ne ""} { set sub $said }
	lassign [sctl::sheet 520 $h $icon $title $sub] x y
	if {$name ne "add"} { ui::text [expr {$x + 50}] [expr {$y + 37}] [initial $u] sg17 $c(fg) c }
	set ry [expr {$y + 94}]
	set fx [expr {$x + 184}]
	set right [expr {$x + 492}]
	set submit [list usp::submit $name]
	foreach r $rows {
		set label [dict get {full "Full name" login Username cur "Current password" pw1 Password pw2 "Confirm password" admin Administrator keep "Keep the home folder"} $r]
		if {$r eq "pw1" && $name eq "password"} { set label "New password" }
		ui::text [expr {$x + 28}] [expr {$ry + 21}] $label i13 $c(fg)
		if {$r ne [lindex $rows end]} { ui::hline [expr {$x + 28}] $right [expr {$ry + 57}] $c(border) }
		switch -- $r {
			full { ui::field us-full $fx [expr {$ry + 10}] 308 -max 120 -onchange usp::full_typed -onenter $submit }
			login { ui::field us-login $fx [expr {$ry + 10}] 308 -max 32 -onchange usp::login_typed -onenter $submit }
			cur - pw1 - pw2 { secret us-$r $fx [expr {$ry + 10}] 308 $submit }
			admin {
				ui::toggle [expr {$right - 38}] [expr {$ry + 18}] $admin
				sctl::hit [expr {$right - 42}] [expr {$ry + 13}] 46 32 {set usp::admin [expr {!$usp::admin}]}
				ui::focusable us-sheet-admin toggle [expr {$right - 38}] [expr {$ry + 18}] 38 22 11 [redraw {set usp::admin [expr {!$usp::admin}]}]
			}
			keep {
				ui::toggle [expr {$right - 38}] [expr {$ry + 18}] $keep
				sctl::hit [expr {$right - 42}] [expr {$ry + 13}] 46 32 {set usp::keep [expr {!$usp::keep}]}
				ui::focusable us-sheet-keep toggle [expr {$right - 38}] [expr {$ry + 18}] 38 22 11 [redraw {set usp::keep [expr {!$usp::keep}]}]
			}
		}
		incr ry 58
	}
	set by [expr {$y + $h - 55}]
	set gw [ui::button_w $go primary $gi]
	set cw [ui::button_w Cancel ghost]
	ui::button us-sheet-cancel [expr {$right - $gw - 10 - $cw}] $by Cancel ghost [redraw usp::cancel]
	ui::button us-sheet-go [expr {$right - $gw}] $by $go primary [redraw $submit] $gi
}

# The primary button, or Return in a field. A form that cannot be sent puts the caret in the field to mend.
# What was typed is taken out of the fields before it is handed over, and the copies here are overwritten after.
proc usp::submit {name} {
	variable target; variable admin; variable keep; variable said
	if {$users::busy} return
	set said ""
	set done [list usp::done $name]
	set cur ""; set pw ""
	switch -- $name {
		add {
			set login [ui::fval us-login]
			if {![users::valid_login $login] || ![users::login_free $login]} { return [mend us-login] }
			if {[ui::fval us-pw1] eq ""} { return [mend us-pw1] }
			if {[ui::fval us-pw2] ne [ui::fval us-pw1]} { return [mend us-pw2] }
			set target $login
			set pw [ui::fval us-pw1]
			leave
			users::add $login [ui::fval us-full] $admin $pw $done
		}
		password {
			set own [own]
			if {$own && [ui::fval us-cur] eq ""} { return [mend us-cur] }
			if {[ui::fval us-pw1] eq ""} { return [mend us-pw1] }
			if {[ui::fval us-pw2] ne [ui::fval us-pw1]} { return [mend us-pw2] }
			set pw [ui::fval us-pw1]
			if {$own} { set cur [ui::fval us-cur] }
			leave
			users::set_password $target $pw $cur $done
		}
		remove { users::remove $target $keep $done }
	}
	set pw [string repeat x [string length $pw]]; set cur [string repeat x [string length $cur]]
	unset pw cur
	page::draw
}
# The password fields are emptied and the keyboard leaves them.
proc usp::leave {} {
	wipe
	set ui::focus ""
}
proc usp::mend {id} {
	set ui::focus $id
	set ::ui::caret 1
	set ::ui::fld($id,cur) [string length [ui::fval $id]]
	page::draw
}
# The change's end: made, the sheet closes (a new user is the chosen one); refused or failed, the sheet stays and
# says why; a dismissed password prompt leaves it as it was (the passwords are to be typed again).
proc usp::done {name status msg} {
	variable said; variable sel; variable target
	if {$sctl::sheet ne $name} return
	if {$status eq "ok"} {
		if {$name eq "add"} { set sel $target }
		sctl::sheet_close
		closed
		return
	}
	set said [expr {$status eq "failed" ? $msg : ""}]
	set ui::focus [expr {$name eq "remove" ? "" : $name eq "password" && [own] ? "us-cur" : "us-pw1"}]
	page::draw
}

# ---- the page -----------------------------------------------------------------------------------------

proc usp::begin {} {
	variable started
	if {$started} return
	set started 1
	ui::fonts
	set ::users::onchange usp::changed
	users::start
}
proc usp::changed {} { if {$::settings::sel eq "users"} { page::draw } }

proc settings::draw_users {} {
	array set c [array get ui::c]
	usp::begin
	# the name's field closes when the keyboard left it (Escape, a click elsewhere) or another page was shown
	if {$usp::edit && ($ui::focus ne "us-name" || $ui::drawno != $usp::drawn + 1)} { set usp::edit 0 }
	set usp::drawn $ui::drawno
	set n [llength [usp::users]]
	set u [usp::chosen]
	ui::text 270 34 Users sg28 $c(fg) w -0.56
	set sub [expr {$n == 1 ? "1 user" : $n ? "$n users" : "No users"}]
	if {$users::error ne "" && $sctl::sheet eq ""} { set sub $users::error }
	ui::text 270 [ui::lh 76 i14 21] [sctl::clip $sub 790 i14] i14 $c(muted)
	usp::draw_list $u
	ui::box 592 119 1 529 -fill $c(border)
	if {$u ne ""} { usp::draw_detail $u }
	ui::hline 230 1100 648 $c(border)
	usp::draw_footer $u
	# under a sheet nothing of the page takes the keyboard (its clicks are the sheet's already)
	if {$sctl::sheet ne ""} { set ::ui::focusables {} }
	sctl::overlay usp::sheet
}
