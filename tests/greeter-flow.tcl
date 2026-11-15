# greeter-flow.tcl - the greeter's real code path against tests/fake-greetd.py
# (RIBBON_GREETER_TEST=this file, GREETD_SOCK=the fake's socket,
# RIBBON_GREETER_FAKELOG=its request log). Keys go in as X events, so the
# bindings, Caps Lock detection and the socket handling are all exercised.
# Prints "ok ..." lines; exits 1 on the first failure.
set fx [file normalize [file join [file dirname [info script]] fixtures greeter]]
set repo [file dirname [file dirname [file normalize [info script]]]]
set tmp [sys::env RIBBON_GREETER_STATE /tmp]
set fh [open $tmp/passwd w]
puts $fh "alex:x:1000:1000:Alex Tyrone:/home/alex:/bin/bash
sam:x:1001:1001:Sam:/home/sam:/bin/bash
locked:x:1002:1002:Locked Out:/home/locked:/bin/bash
ghost:x:1003:1003:Ghost:/home/ghost:/bin/bash
guest:x:1004:1004:Guest:/home/guest:/bin/bash"
close $fh
set ::env(RIBBON_GREETER_PASSWD) $tmp/passwd
set ::env(RIBBON_GREETER_SESSIONS) [list [file join $repo srcpkgs ribbon-desktop files sessions] $fx/sessions]
set ::env(RIBBON_GREETER_ICONS) $tmp/icons
set ::env(RIBBON_GREETER_XKB) $fx/00-keyboard.conf
set fh [open [sys::statefile] w]; puts $fh "user=alex\nsession.alex=ribbon"; close $fh

proc bgerror {msg} { puts stderr "FAIL background error: $msg\n$::errorInfo"; exit 1 }
proc fail {what} { puts stderr "FAIL $what"; exit 1 }
proc ok {what} { puts "ok   $what" }

# Wait (running the event loop) until COND holds, up to 5 s.
proc wait_for {cond what} {
	set end [expr {[clock milliseconds] + 5000}]
	while {![uplevel #0 [list expr $cond]]} {
		if {[clock milliseconds] > $end} { fail "timed out: $what" }
		after 20 {set ::tick 1}; vwait ::tick
	}
	update
}

# Type into the greeter as the X server would deliver it.
proc type {text {state 0}} {
	foreach ch [split $text ""] {
		set ks [expr {[string is digit $ch] || [string is alpha $ch] ? $ch : [dict get {" " space} $ch]}]
		event generate . <KeyPress> -keysym $ks -state $state -when tail
	}
	update
}
proc key {ks {state 0}} { event generate . <KeyPress> -keysym $ks -state $state -when tail; update }

# The fake's log: every request the greeter sent, decoded.
proc requests {} {
	set fh [open $::env(RIBBON_GREETER_FAKELOG)]; set t [read $fh]; close $fh
	set out {}
	foreach l [split [string trim $t] \n] { if {$l ne ""} { lappend out [json::decode $l] } }
	return $out
}
proc last_request {} { lindex [requests] end }

proc lines {} { set out {}; foreach l [login::lines] { lappend out [lindex $l 1] }; return $out }

set ::started {}
set login::onstart { lappend ::started [list [login::user] $login::sess] }

# ---- 1: the last user, a wrong password, Caps Lock, then the right one
login::start
if {$login::view ne "password" || [dict get [login::user] name] ne "alex"} { fail "alex is not pre-selected" }
ok "the last user (alex) is pre-selected"
wait_for {$login::prompt ne ""} "alex's password prompt"
if {[lines] ne {{Enter your password}}} { fail "prompt line: [lines]" }
ok "PAM's Password: prompt reads 'Enter your password'"
type wrong
if {$login::secret ne "wrong"} { fail "typed: $login::secret" }
key Return
wait_for {!$login::busy && $login::prompt ne ""} "a fresh prompt after the wrong password"
if {[lines] ne {{That password didn't work}} || $login::secret ne ""} { fail "wrong password state: [lines] / '$login::secret'" }
ok "a wrong password shows the error, clears the field and asks again"
type ABC 2
if {!$login::caps || [lindex [lines] end] ne "Caps Lock is on"} { fail "caps lock: [lines]" }
ok "Caps Lock is detected from the key state"
key Caps_Lock 2
if {$login::caps} { fail "caps lock still on after pressing Caps Lock" }
key BackSpace; key BackSpace; key BackSpace
type secret
key Return
wait_for {[llength $::started] == 1} "alex's session to start"
set r [last_request]
if {[dict get $r type] ne "start_session" || [dict get $r cmd] ne "ribbon-session"} { fail "start_session: $r" }
foreach e {XDG_SESSION_TYPE=wayland XDG_SESSION_DESKTOP=ribbon XDG_CURRENT_DESKTOP=Ribbon:wlroots} {
	if {$e ni [dict get $r env]} { fail "start_session env lacks $e: $r" }
}
ok "the right password starts ribbon-session with its environment"
sys::state_load
if {[sys::state_get user] ne "alex"} { fail "last user not remembered" }
ok "the last login is remembered"

# ---- 2: the picker, then a fingerprint note, a password and a code
login::begin
wait_for {$login::prompt ne ""} "a new prompt"
key Escape
if {$login::view ne "users"} { fail "Escape on an empty field doesn't open the picker" }
key Right
key Return
if {[dict get [login::user] name] ne "sam"} { fail "the picker chose [dict get [login::user] name]" }
ok "Other user: the arrow keys and Enter choose sam"
wait_for {$login::prompt ne ""} "sam's password prompt"
if {[lines] ne {{Place your finger on the reader} {Enter your password}}} { fail "info line: [lines]" }
ok "an info message (fingerprint) is shown and acknowledged"
type pw
key Return
wait_for {$login::prompt eq "Verification code:"} "the second prompt"
if {$login::echo || [lines] ne {{Verification code}}} { fail "visible prompt: echo $login::echo [lines]" }
ok "a second, visible prompt follows in the same conversation"
type 123456
key KP_Enter
wait_for {[llength $::started] == 2} "sam's session to start"
ok "a two-step conversation logs in"
set acks 0
foreach r [requests] { if {[dict get $r type] eq "post_auth_message_response" && ![dict exists $r response]} { incr acks } }
if {$acks != 1} { fail "the info message was acknowledged $acks times" }

# ---- 3: PAM's own error, then failure
login::pick_user 2
wait_for {[lines] eq {{Your account has expired}} && !$login::busy} "the expired-account error"
ok "a PAM error message is shown as the reason"

# ---- 4: greetd refuses the session (not a password problem)
login::pick_user 3
wait_for {[string match "*no such user*" [lindex [lines] 0]]} "greetd's error"
ok "greetd's own errors are shown"

# ---- 5: no password needed
login::pick_user 4
wait_for {[llength $::started] == 3} "guest's session"
ok "a user without authentication logs straight in"

# ---- 6: the session menu (Greet-4): click the pill, arrows, Enter keeps it
login::pick_user 0
wait_for {$login::prompt ne "" && !$login::busy} "alex's prompt again"
set ids {}
foreach s $login::sessions { lappend ids [dict get $s id] }
if {$ids ne {ribbon ribbon-game labwc steam text-console}} { fail "sessions in this order: $ids" }
if {[lmap s $login::sessions {lindex [sys::session_label $s] 1}] ne {{· desktop} {· game mode} {· plain session} {· Big Picture (gamescope)} {· text login}}} {
	fail "session labels: [lmap s $login::sessions {sys::session_label $s}]"
}
ok "sessions: Ribbon's first, each with what it is"
proc pill {} { update; ui::click 20 [expr {$ui::H - 27}] 1; update }
pill
if {!$login::smenu || $login::shi != 0} { fail "the pill didn't open the menu on the kept session" }
key Down; key Down
type x
if {$login::shi != 2 || $login::sess != 0 || $login::secret ne ""} { fail "arrows: highlighted $login::shi, kept $login::sess, typed '$login::secret'" }
key Escape
if {$login::smenu || $login::sess != 0} { fail "Esc changed the session or left the menu open" }
ok "the pill opens the menu; arrows move, typing doesn't reach the field, Esc leaves it as it was"
pill
key Up
key Return
if {$login::smenu || [dict get [lindex $login::sessions $login::sess] id] ne "text-console"} { fail "Enter kept [lindex $login::sessions $login::sess]" }
ok "Up wraps to the last session and Enter keeps it"
pill
update
# the second row (game mode): the menu's rows are 40 px from its SESSION label
set row [lsearch -index 4 -all -inline $ui::hits {login::session_keep 1}]
if {![llength $row]} { fail "no row for game mode in the menu" }
lassign [lindex $row 0] x0 y0
ui::click [expr {$x0 + 5}] [expr {$y0 + 5}] 1
if {$login::smenu || $login::sess != 1} { fail "clicking a row: kept $login::sess" }
pill
ui::click 700 300 1
if {$login::smenu || $login::sess != 1} { fail "a click elsewhere didn't just close the menu" }
ok "a click on a row keeps it; a click elsewhere closes the menu"
type secret
key Return
wait_for {[llength $::started] == 4} "alex's game-mode session"
set r [last_request]
if {[dict get $r cmd] ne {ribbon-session --game} || "XDG_SESSION_DESKTOP=ribbon-game" ni [dict get $r env]} { fail "start_session: $r" }
sys::state_load
if {[sys::state_get session.alex] ne "ribbon-game"} { fail "the chosen session isn't remembered" }
ok "the kept session is the one started, and remembered for alex"

# ---- 7: account pictures (AccountsService's icon), else the letter
if {[ui::face [login::user] 96] ne ""} { fail "a picture without one" }
file mkdir $tmp/icons
set p [image create photo -width 120 -height 80]
$p put #2E6FD8 -to 0 0 120 80
$p put #F2C14E -to 40 20 80 60
$p write $tmp/icons/alex -format png
image delete $p
set img [ui::face [login::user] 96]
if {$img eq "" || [image width $img] != 96} { fail "alex's picture wasn't loaded" }
if {[$img get 48 48] ne {242 193 78} || [$img transparency get 0 0] != 1 || [$img transparency get 48 2] != 0} {
	fail "the picture isn't the middle square in a circle: [$img get 48 48]"
}
ok "an account picture is cropped to its middle square, in a circle"

foreach r [requests] { if {[dict get $r type] eq "cancel_session"} { set cancelled 1 } }
if {![info exists cancelled]} { fail "no cancel_session was sent" }
ok "cancel_session ends conversations that failed or were left"
exit 0
