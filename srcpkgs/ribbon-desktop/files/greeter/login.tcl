# login.tcl - the conversation with greetd (and through it, PAM), and the
# keys and clicks that drive it.
#
# Any PAM stack works: each auth_message is shown as it comes. A secret or
# visible prompt takes what you type; info and error messages are shown
# and acknowledged at once, so PAM goes on (pam_fprintd's "Place your
# finger" while it waits for the reader, then maybe a password prompt).

namespace eval login {
	variable users {}       ;# dicts: name full letter
	variable cur 0          ;# the user whose password is asked
	variable pick 0         ;# the user highlighted in the picker
	variable view password  ;# password | users
	variable secret ""      ;# what you typed
	variable echo 1         ;# 1: a secret prompt (dots), 0: a visible one
	variable prompt ""      ;# PAM's prompt; "" while none is pending
	variable msgs {}        ;# {error|info text} from PAM and greetd
	variable caps 0
	variable busy 0         ;# a request is with greetd
	variable sessions {}
	variable sess 0
	variable smenu 0        ;# the session menu is open (Greet-4)
	variable shi 0          ;# ... and the session highlighted in it
	variable layouts us
	variable lay 0
	variable time ""
	variable date ""
	variable started ""     ;# the user greetd's session is for
	variable answered 0     ;# you answered a prompt in this conversation
	variable onstart ""     ;# test hook: called instead of exiting
}

proc login::user {} {
	variable users
	variable cur
	if {![llength $users]} { return [dict create name "" full "" letter ""] }
	lindex $users $cur
}

# ---- what the screen shows -----------------------------------------------

proc login::layout_text {} {
	variable layouts
	variable lay
	sys::layout_label [lindex $layouts $lay]
}

proc login::session_words {} {
	variable sessions
	variable sess
	if {![llength $sessions]} { return [list Ribbon "· desktop"] }
	sys::session_label [lindex $sessions $sess]
}

# Message lines under the field: PAM's errors and notes, then its prompt
# (unless something went wrong: the error says what to do), then Caps Lock.
proc login::lines {} {
	variable msgs
	variable prompt
	variable caps
	set out [lrange $msgs end-2 end]
	set err [expr {[lsearch -index 0 $out error] >= 0}]
	if {!$err && $prompt ne ""} { lappend out [list info [prompt_text $prompt]] }
	if {$caps} { lappend out {caps {Caps Lock is on}} }
	return $out
}

# "Password:" as the mockup words it; other prompts as PAM words them.
proc login::prompt_text {p} {
	set p [string trim $p]
	if {[regexp -nocase {^(\S+'s\s+)?password\s*:?$} $p]} { return "Enter your password" }
	string trimright $p ": "
}

proc login::clock_tick {} {
	variable time
	variable date
	set now [clock seconds]
	set time [clock format $now -format %H:%M]
	set date [regsub {  } [clock format $now -format "%A %e %B"] { }]
	ui::redraw
	after [expr {(60 - $now % 60) * 1000 - [clock milliseconds] % 1000 + 50}] login::clock_tick
}

# ---- start ------------------------------------------------------------------

proc login::start {} {
	variable users
	variable cur
	variable pick
	variable view
	variable sessions
	variable sess
	variable layouts
	variable lay
	sys::state_load
	set users [sys::users]
	set sessions [sys::sessions]
	set layouts [sys::layouts]
	set lay 0
	# the last person to log in, with the session they chose
	set cur 0
	set i [lsearch -index 1 $users [sys::state_get user]]
	if {$i >= 0} { set cur $i }
	set pick $cur
	pick_session
	# more than one person and none remembered: let them choose
	set view [expr {[llength $users] > 1 && $i < 0 ? "users" : "password"}]
	set greetd::onclose login::lost
	if {[info exists ::env(GREETD_SOCK)] && $::env(GREETD_SOCK) ne ""} {
		if {[catch {greetd::connect $::env(GREETD_SOCK)} err]} {
			note error "Can't reach greetd: $err"
		} elseif {$view eq "password"} { begin }
	}
	ui::redraw
}

proc login::pick_session {} {
	variable sessions
	variable sess
	set sess 0
	set i [lsearch -index 1 $sessions [sys::state_get session.[dict get [user] name]]]
	if {$i >= 0} { set sess $i }
}

proc login::lost {why} {
	note error "Lost greetd ($why)"
	ui::redraw
}

proc login::note {kind text} {
	variable msgs
	lappend msgs [list $kind $text]
}

# ---- the conversation -------------------------------------------------------

# Ask greetd for a session for the current user (cancelling one in progress).
proc login::begin {} {
	variable started
	variable prompt ""
	variable secret ""
	variable busy 1
	variable answered 0
	if {![greetd::connected]} { set busy 0; return }
	if {$started ne ""} { greetd::send {type cancel_session} login::ignore }
	set started [dict get [user] name]
	greetd::send [dict create type create_session username $started] login::response
	ui::redraw
}

proc login::ignore {resp} {}

proc login::response {resp} {
	variable prompt
	variable echo
	variable busy
	variable secret
	variable msgs
	switch -- [dict get $resp type] {
		auth_message {
			set text [expr {[dict exists $resp auth_message] ? [dict get $resp auth_message] : ""}]
			switch -- [dict get $resp auth_message_type] {
				secret - visible {
					set prompt $text
					set echo [expr {[dict get $resp auth_message_type] eq "secret"}]
					set busy 0
				}
				info - error {
					note [dict get $resp auth_message_type] [string trim $text]
					set busy 1
					greetd::send {type post_auth_message_response} login::response
				}
			}
		}
		success {
			# authenticated (or no authentication needed): start the session
			set prompt ""
			set busy 1
			launch
		}
		error {
			variable started
			set prompt ""
			set secret ""
			set busy 0
			if {[dict get $resp error_type] eq "auth_error"} {
				# PAM may have said why (an expired account); else it was the password
				if {[lsearch -index 0 $msgs error] < 0} { set msgs [list {error {That password didn't work}}] }
			} else {
				note error [string trim [dict get $resp description]]
			}
			# greetd's conversation is over. After a wrong answer, ask again
			# at once; a failure nobody typed for (an expired account) waits
			# for Enter, or it would only repeat itself.
			variable answered
			if {[greetd::connected]} {
				greetd::send {type cancel_session} login::ignore
				set started ""
				if {$answered} { after 0 login::begin }
			}
		}
	}
	ui::redraw
}

proc login::launch {} {
	variable sessions
	variable sess
	if {![llength $sessions]} {
		note error "No sessions installed"
		set ::login::busy 0
		return
	}
	set s [lindex $sessions $sess]
	lassign [sys::session_start $s] cmd env
	greetd::send [dict create type start_session cmd $cmd env $env] [list login::launched [dict get [user] name] [dict get $s id]]
}

proc login::launched {user session resp} {
	variable onstart
	if {[dict get $resp type] eq "success"} {
		sys::state_save $user $session
		# greetd starts the session once the greeter is gone
		if {$onstart ne ""} { uplevel #0 $onstart; return }
		exit 0
	}
	response $resp
}

proc login::submit {{b 1}} {
	variable busy
	variable prompt
	variable secret
	variable msgs
	variable view
	if {$view ne "password" || $busy} return
	if {$prompt eq ""} {
		# nothing asked: try again after a failure
		if {$::login::started eq "" && [greetd::connected]} { set msgs {}; begin }
		return
	}
	variable answered 1
	set msgs {}
	set busy 1
	set prompt ""
	greetd::send [dict create type post_auth_message_response response $secret] login::response
	set secret ""
	ui::redraw
}

# ---- keys ---------------------------------------------------------------

# Caps Lock from the event's modifier state (X's Lock bit). The state is
# from before the event, so pressing Caps Lock itself flips it.
proc login::caps_from {key state press} {
	variable caps
	if {![string is integer -strict $state]} return
	set on [expr {($state & 2) != 0}]
	if {$key eq "Caps_Lock" && $press} { set on [expr {!$on}] }
	if {$key eq "Caps_Lock" && !$press} return
	if {$on != $caps} { set caps $on; ui::redraw }
}

proc login::key {k a state} {
	variable view
	variable secret
	variable busy
	variable prompt
	caps_from $k $state 1
	if {$::login::smenu} {
		switch -- $k {
			Up - KP_Up { session_move -1 }
			Down - KP_Down - Tab { session_move 1 }
			Return - KP_Enter - space { session_keep $::login::shi }
			Escape { session_close }
		}
		return
	}
	if {$view eq "users"} {
		switch -- $k {
			Left - KP_Left { pick_move -1 }
			Right - KP_Right { pick_move 1 }
			Tab { pick_move [expr {$state & 1 ? -1 : 1}] }
			Return - KP_Enter - space { pick_user $::login::pick }
			Escape { if {$prompt ne "" || $busy} { set view password; ui::redraw } }
		}
		return
	}
	switch -- $k {
		Return - KP_Enter { submit; return }
		BackSpace {
			if {$state & 4} { set secret "" } else { set secret [string range $secret 0 end-1] }
		}
		Escape {
			if {$secret ne ""} { set secret "" } elseif {[llength $::login::users] > 1} { picker; return }
		}
		default {
			# Ctrl+U clears, like a terminal; other control keys do nothing
			if {($state & 4) && [string tolower $k] eq "u"} { set secret "" } elseif {$a ne "" && [string is print $a] && !($state & 4)} {
				append secret $a
			} else return
		}
	}
	ui::redraw
}

proc login::focus_field {b} { focus -force . }

# ---- the picker ----------------------------------------------------------

proc login::picker {{b 1}} {
	variable view users
	variable pick $::login::cur
	ui::redraw
}

proc login::pick_move {d} {
	variable pick
	variable users
	set n [llength $users]
	set pick [expr {($pick + $d + $n) % $n}]
	ui::redraw
}

proc login::pick_user {i {b 1}} {
	variable cur
	variable pick
	variable view
	variable msgs
	set view password
	if {$i != $cur || ![greetd::connected] || $::login::started eq ""} {
		set cur $i
		set pick $i
		set msgs {}
		pick_session
		begin
	}
	ui::redraw
}

# ---- the pills ---------------------------------------------------------

proc login::layout_next {b} {
	variable layouts
	variable lay
	if {[llength $layouts] < 2} return
	set n [expr {($lay + ($b == 3 ? -1 : 1) + [llength $layouts]) % [llength $layouts]}]
	if {[sys::set_layout [lindex $layouts $n]]} { set lay $n; ui::redraw }
}

# The session menu (Greet-4) rises out of the pill: ↑ ↓ (or the mouse)
# choose, Enter or a click keeps the choice, Esc or a click elsewhere
# leaves the session as it was.
proc login::session_open {{b 1}} {
	variable sessions
	variable smenu
	if {$smenu} { session_close; return }
	if {![llength $sessions]} return
	set smenu 1
	variable shi $::login::sess
	ui::redraw
}

proc login::session_close {{b 1}} {
	variable smenu 0
	ui::redraw
}

proc login::session_move {d} {
	variable shi
	set n [llength $::login::sessions]
	set shi [expr {($shi + $d + $n) % $n}]
	ui::redraw
}

proc login::session_keep {i {b 1}} {
	variable sess $i
	variable shi $i
	variable smenu 0
	ui::redraw
}

proc login::power {what b} {
	if {$b != 1} return
	set err [sys::power $what]
	if {$err ne ""} { note error [lindex [split [string trim $err] \n] 0]; ui::redraw }
}
