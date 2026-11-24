# agent.tcl - the polkit authentication agent core (U15). No window in this file.
#
# ribbon-polkit is its own process (BUILD-PLAN C6), so the password is typed
# into, held by and sent from a process that is not the shell. This file:
#   - registers org.freedesktop.PolicyKit1.AuthenticationAgent for the
#     session with polkitd, on the system bus, with ribbon::dbus;
#   - answers BeginAuthentication and CancelAuthentication, but only from the
#     bus name that owns org.freedesktop.PolicyKit1 (polkitd);
#   - works out who may authenticate (the identities polkitd offers, groups
#     expanded) and whether the person must be asked to pick one;
#   - runs the PAM conversation through polkit-agent-helper-1 over its pipe
#     protocol and hands each step to a UI through a small command table.
# The Tk card (card.tcl) only draws. Keys come from ribbon-polkit-keys, a native Wayland client that holds
# the keyboard exclusively while a card is up (docs/POLKIT-WAYLAND.md): no X11 client can read what is typed,
# and the PASSWORD NEVER ENTERS TCL. It goes from that helper straight into the pipe that is
# polkit-agent-helper-1's stdin (a descriptor passed over SCM_RIGHTS), never through Tk, X or this process's
# memory. Tcl learns only counts ("n 7": draw seven dots) and key names (tab, up, enter ...).
# No keyboard helper, or one the compositor will not give the keyboard to: no card, the request fails.
#
# Starting:
#   polkit::start BUS ?-ui {show C prompt C info C error C done C key C}?
#       ?-session ID? ?-locale L? ?-helper PATH? ?-keys PATH? ?-registered CMD?
#   polkit::stop                 unregister and cancel everything
#
# The UI table: each entry is a command prefix, called with the request id
# (r1, r2, ... ours; never polkit's cookie) first. A UI command that fails
# cancels that request, so a broken card can never leave polkitd waiting.
#   show ID INFO     the keyboard is ours; a request became the active one. INFO is a dict:
#                      action     the action id (org.ribbon.x.y)
#                      message    the text polkit supplies
#                      icon       icon name, may be ""
#                      details    dict of the action's details (polkit.caller-pid ...)
#                      identities list of dicts: uid name display kind
#                      identity   the name selected now
#                      choose     1 if a picker must be shown (more than one
#                                 identity, or the person is not one of them)
#   prompt ID TEXT ECHO   PAM asks for something; ECHO 0 is a password. The answer is typed on the keyboard
#                         helper and sent with polkit::submit.
#   info ID TEXT          PAM_TEXT_INFO
#   error ID TEXT         PAM_ERROR_MSG, or "Sorry, that didn't work..." after
#                         a wrong password (a new prompt follows)
#   done ID RESULT        success, failure or cancelled: the card closes
#   key ID NAME ?ARG?     from the keyboard helper: count N (characters typed so far), text STRING (only when
#                         the prompt is echoed: PAM says it is not secret), enter esc tab btab up down space
# What the UI calls back:
#   polkit::submit ID          send what was typed (Enter in the field, or the button); 1 if sent, 0 if
#                              nothing was typed in a hidden prompt; an error if no prompt waits
#   polkit::focus ID field|other   where the card's focus is: in the field every printable key is a
#                              character (Space too); elsewhere characters are ignored and Space is an event
#   polkit::cancel ID          the person dismissed the card
#   polkit::choose ID NAME     the person picked another account
#
# The password: see design/handoff/u16.md. There is no polkit::answer: no text from the UI reaches PAM.

package require Tcl 8.6-

namespace eval polkit {
	variable bus ""
	variable authority org.freedesktop.PolicyKit1
	variable apath /org/ribbon/PolicyKit1/AuthenticationAgent
	variable aiface org.freedesktop.PolicyKit1.AuthenticationAgent
	variable ui {}
	variable session ""
	variable locale ""
	variable helper ""
	variable keys ""
	variable keyshelpers {/usr/lib/ribbon/polkit/ribbon-polkit-keys}
	variable keystimeout 4000
	variable onreg ""
	variable registered 0
	variable watch ""
	variable seq 0
	variable req          ;# id -> dict (see enqueue)
	variable queue {}     ;# ids waiting, oldest first
	variable active ""    ;# the id on the card now
	variable passwd /etc/passwd
	variable group /etc/group
	variable helpers {/usr/lib/polkit-1/polkit-agent-helper-1 /usr/libexec/polkit-agent-helper-1
		/usr/lib/policykit-1/polkit-agent-helper-1}
	variable maxcookie 512
	array set req {}
}

# ---- logging: events only, never a cookie, a prompt's answer or a password
proc polkit::log {text} {
	catch {puts stderr "ribbon-polkit: $text"}
}

# ---- accounts
# /etc/passwd and /etc/group only (no NSS: LDAP and friends are not read).
proc polkit::passwd_rows {} {
	variable passwd
	set rows {}
	if {[catch {open $passwd r} f]} { return $rows }
	fconfigure $f -encoding utf-8
	foreach line [split [read $f] \n] {
		set p [split $line :]
		# name:x:uid:gid:gecos:home:shell
		if {[llength $p] >= 4 && [string is integer -strict [lindex $p 2]]} {
			lappend rows [dict create name [lindex $p 0] uid [lindex $p 2] gid [lindex $p 3] \
				display [lindex [split [lindex $p 4] ,] 0]]
		}
	}
	close $f
	return $rows
}

proc polkit::group_members {gid} {
	variable group
	set names {}
	if {![catch {open $group r} f]} {
		fconfigure $f -encoding utf-8
		foreach line [split [read $f] \n] {
			set p [split $line :]
			if {[llength $p] >= 4 && [lindex $p 2] eq $gid} {
				foreach m [split [lindex $p 3] ,] { if {$m ne ""} { lappend names $m } }
			}
		}
		close $f
	}
	foreach row [passwd_rows] {
		if {[dict get $row gid] eq $gid} { lappend names [dict get $row name] }
	}
	return [lsort -unique $names]
}

# Names go into argv of a setuid program: no leading dash, no odd characters.
proc polkit::safe_name {n} {
	regexp {^[A-Za-z0-9_.][A-Za-z0-9_.@$-]*$} $n
}

# Polkit's identities (strip'd a(sa{sv})) as accounts we can ask PAM about:
# a list of {uid name display kind}. unix-group is expanded to its members;
# anything else (netgroups) is dropped. Duplicates are merged; the person
# running this comes first, then by uid.
proc polkit::identities {raw {me ""}} {
	if {$me eq ""} { set me [uid] }
	set rows [passwd_rows]
	set found {}
	foreach id $raw {
		lassign $id kind d
		switch -- $kind {
			unix-user {
				if {![dict exists $d uid]} continue
				foreach r $rows { if {[dict get $r uid] == [dict get $d uid]} { dict set found [dict get $r uid] [list $r user] } }
			}
			unix-group {
				if {![dict exists $d gid]} continue
				foreach n [group_members [dict get $d gid]] {
					foreach r $rows { if {[dict get $r name] eq $n} { dict set found [dict get $r uid] [list $r group] } }
				}
			}
		}
	}
	set out {}
	dict for {u v} $found {
		lassign $v r kind
		set n [dict get $r name]
		if {![safe_name $n]} continue
		set disp [dict get $r display]
		lappend out [dict create uid $u name $n display [expr {$disp ne "" ? $disp : $n}] kind $kind]
	}
	lsort -command [list polkit::byme $me] $out
}
proc polkit::byme {me a b} {
	set ma [expr {[dict get $a uid] == $me ? 0 : 1}]
	set mb [expr {[dict get $b uid] == $me ? 0 : 1}]
	if {$ma != $mb} { return [expr {$ma - $mb}] }
	expr {[dict get $a uid] - [dict get $b uid]}
}

# The picker is shown only when there is a real choice: more than one account,
# or the person is not among them (then a single account is still named).
proc polkit::needs_picker {ids {me ""}} {
	if {$me eq ""} { set me [uid] }
	if {[llength $ids] > 1} { return 1 }
	foreach i $ids { if {[dict get $i uid] == $me} { return 0 } }
	return 1
}

proc polkit::uid {} {
	# no [id]: our own uid from /proc
	if {![catch {open /proc/self/status r} f]} {
		set s [read $f]; close $f
		if {[regexp {\nUid:\s+(\d+)} $s -> u]} { return $u }
	}
	return -1
}

# ---- starting and registering
proc polkit::start {b args} {
	variable bus $b
	variable ui; variable session; variable locale; variable helper; variable keys; variable onreg
	variable aiface; variable apath; variable authority; variable watch
	set o [dict merge {-ui {} -session "" -locale "" -helper "" -keys "" -registered ""} $args]
	set ui [dict get $o -ui]
	set session [dict get $o -session]
	set locale [dict get $o -locale]
	set helper [dict get $o -helper]
	set keys [dict get $o -keys]
	set onreg [dict get $o -registered]
	if {$locale eq ""} {
		set locale en_US.UTF-8
		foreach v {LC_ALL LC_MESSAGES LANG} {
			if {[info exists ::env($v)] && $::env($v) ne ""} { set locale $::env($v); break }
		}
	}
	$bus export $apath $aiface {
		method BeginAuthentication sssa{ss}sa(sa{sv}) "" polkit::Begin
		method CancelAuthentication s "" polkit::Cancel
	}
	# polkitd comes and goes: register again when it returns, and drop the
	# requests of one that has gone (their callers are not waiting any more)
	set watch [$bus listen -sender org.freedesktop.DBus -interface org.freedesktop.DBus -member NameOwnerChanged \
		-arg0 $authority polkit::OwnerChanged]
	register
}

proc polkit::stop {} {
	variable bus; variable watch; variable apath; variable registered
	if {$bus eq ""} return
	variable queue; variable active
	foreach id [concat $active $queue] { finish $id cancelled }
	if {$registered} {
		catch {$bus call -noreply 1 $::polkit::authority /org/freedesktop/PolicyKit1/Authority \
			org.freedesktop.PolicyKit1.Authority UnregisterAuthenticationAgent "(sa{sv})o" [subject] $apath}
		set registered 0
	}
	catch {$bus unlisten $watch}
	catch {$bus unexport $apath}
}

# (sa{sv}): the session we speak for.
proc polkit::subject {} {
	variable session
	list unix-session [list session-id [list s $session]]
}

# elogind: $XDG_SESSION_ID, else ask logind which session our pid is in.
proc polkit::find_session {} {
	variable bus
	if {[info exists ::env(XDG_SESSION_ID)] && $::env(XDG_SESSION_ID) ne ""} { return $::env(XDG_SESSION_ID) }
	set p [lindex [$bus call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager \
		GetSessionByPID u [pid]] 0]
	# the object path ends in the id, with _XX escapes
	set id [lindex [split $p /] end]
	while {[regexp {_([0-9a-f]{2})} $id m hex]} {
		set id [string map [list $m [binary format H2 $hex]] $id]
	}
	return $id
}

proc polkit::register {} {
	variable bus; variable session; variable locale; variable apath; variable authority
	if {$session eq ""} {
		if {[catch {find_session} s]} {
			log "no session id (XDG_SESSION_ID unset and logind did not answer): $s"
			registered_cb error [list NoSession $s]
			return
		}
		set session $s
	}
	$bus call -command [list polkit::Registered] $authority /org/freedesktop/PolicyKit1/Authority \
		org.freedesktop.PolicyKit1.Authority RegisterAuthenticationAgent "(sa{sv})so" [subject] $locale $apath
}
proc polkit::Registered {status values} {
	variable registered
	if {$status eq "ok"} {
		set registered 1
		log "registered for session $::polkit::session"
	} else {
		set registered 0
		log "could not register: [lindex $values 0] [lindex $values 1]"
	}
	registered_cb $status $values
}
proc polkit::registered_cb {status values} {
	variable onreg
	if {$onreg ne ""} { catch {uplevel #0 [list {*}$onreg $status $values]} }
}

proc polkit::OwnerChanged {msg name old new} {
	variable registered
	if {$old ne ""} {
		# polkitd went away: nobody is waiting for these
		set registered 0
		variable queue; variable active
		foreach id [concat $active $queue] { finish $id cancelled -noreply 1 }
	}
	if {$new ne ""} { after 200 polkit::register }
}

# ---- who is calling
# The caller must be the owner of org.freedesktop.PolicyKit1 right now.
# (The system bus' own policy keeps other users from sending to us at all;
# this is the second lock.) Asked of the bus each time: polkitd can restart.
proc polkit::from_polkitd {msg cmd} {
	variable bus; variable authority
	set sender [dict get $msg sender]
	$bus defer $msg
	$bus call -command [list polkit::Owner $msg $sender $cmd] org.freedesktop.DBus /org/freedesktop/DBus \
		org.freedesktop.DBus GetNameOwner s $authority
}
proc polkit::Owner {msg sender cmd status values} {
	variable bus
	if {$status ne "ok" || [lindex $values 0] ne $sender || $sender eq ""} {
		log "refused [dict get $msg member] from $sender: not the owner of org.freedesktop.PolicyKit1"
		$bus error $msg org.freedesktop.DBus.Error.AccessDenied "only polkitd may call this"
		return
	}
	if {[catch {uplevel #0 [list {*}$cmd $msg]} err]} {
		log "[dict get $msg member] failed: [lindex [split $err \n] 0]"
		$bus error $msg org.freedesktop.DBus.Error.Failed "bad request"
	}
}

proc polkit::Begin {msg action message icon details cookie identities} {
	from_polkitd $msg [list polkit::Begin2 $action $message $icon $details $cookie $identities]
}
proc polkit::Cancel {msg cookie} {
	from_polkitd $msg [list polkit::Cancel2 $cookie]
}

# ---- requests
# A cookie goes to the helper's stdin as one line: no newline or other control
# character may be in it, or the rest would be read as answers to PAM.
proc polkit::valid_cookie {c} {
	variable maxcookie
	expr {$c ne "" && [string length $c] <= $maxcookie && ![regexp {[[:cntrl:]]} $c]}
}

proc polkit::Begin2 {action message icon details cookie identities msg} {
	variable bus; variable req; variable queue; variable seq
	if {![valid_cookie $cookie]} {
		log "refused a request with a bad cookie"
		$bus error $msg org.freedesktop.DBus.Error.InvalidArgs "bad cookie"
		return
	}
	foreach r [array names req] {
		if {[dict get $req($r) cookie] eq $cookie} {
			$bus error $msg org.freedesktop.DBus.Error.InvalidArgs "cookie in use"
			return
		}
	}
	set ids [identities [ribbon::dbus::strip a(sa{sv}) $identities]]
	if {![llength $ids]} {
		log "refused request for $action: no account to authenticate as"
		$bus error $msg org.freedesktop.PolicyKit1.Error.Failed "no usable identity"
		return
	}
	set id r[incr seq]
	set sel [dict get [lindex $ids 0] name]
	set req($id) [dict create cookie $cookie action $action message $message icon $icon details $details \
		identities $ids identity $sel msg $msg chan "" pending 0 tries 0 gen 0 \
		kchan "" kpid "" kgen 0 kready 0 shown 0 echo 0 count 0 mode text]
	lappend queue $id
	log "$id queued: $action (as [expr {[llength $ids]}] account(s))"
	next
}

proc polkit::Cancel2 {cookie msg} {
	variable bus; variable req
	foreach id [array names req] {
		if {[dict get $req($id) cookie] eq $cookie} { finish $id cancelled }
	}
	$bus reply $msg
}

# One card at a time; the rest wait their turn. The card is shown only once the keyboard helper
# says it holds the keyboard ("ready"); until then nothing is on screen.
proc polkit::next {} {
	variable active; variable queue
	if {$active ne "" || ![llength $queue]} return
	set queue [lassign $queue id]
	set active $id
	if {[catch {start_keys $id} err]} {
		log "$id: no keyboard helper, no card: [lindex [split $err \n] 0]"
		finish $id failure
	}
}

proc polkit::show {id} {
	variable req
	set r $req($id)
	set ids [dict get $r identities]
	if {[catch {callui show $id [dict create action [dict get $r action] message [dict get $r message] \
		icon [dict get $r icon] details [dict get $r details] identities $ids identity [dict get $r identity] \
		choose [needs_picker $ids]]} err]} {
		log "$id: the UI could not show it: [lindex [split $err \n] 0]"
		finish $id cancelled
		return
	}
	dict set req($id) shown 1
	begin_session $id
}

proc polkit::callui {what id args} {
	variable ui
	if {![dict exists $ui $what]} { error "no ui $what" }
	uplevel #0 [list {*}[dict get $ui $what] $id {*}$args]
}
# For the calls that must not stop the agent: errors are logged, never rethrown.
proc polkit::tellui {what id args} {
	if {[catch {callui $what $id {*}$args} err]} { log "$id: ui $what failed: [lindex [split $err \n] 0]" }
}

# ---- the keyboard helper (ribbon-polkit-keys)
# One per active request. fd 0 of the helper is one end of a unix socket pair: it writes events (one line
# each), reads commands, and takes the pipe for each PAM conversation over SCM_RIGHTS. See native/rpk-keys.c.
proc polkit::find_keys {} {
	variable keys; variable keyshelpers
	if {$keys ne ""} { if {[file executable $keys]} { return $keys }; error "$keys is not executable" }
	foreach h $keyshelpers { if {[file executable $h]} { return $h } }
	error "ribbon-polkit-keys not found"
}

proc polkit::start_keys {id} {
	variable req; variable keystimeout
	package require unix_extra
	set h [find_keys]
	lassign [unix_extra::socketpair] a b
	if {[catch {exec $h --socket <@ $b >/dev/null 2>@ stderr &} pids]} { catch {close $a}; catch {close $b}; error $pids }
	close $b
	fconfigure $a -blocking 0 -translation lf -encoding utf-8 -buffering none
	set gen [dict get $req($id) kgen]
	dict set req($id) kchan $a
	dict set req($id) kpid [lindex $pids 0]
	dict set req($id) kready 0
	fileevent $a readable [list polkit::keys_readable $id $gen $a]
	after $keystimeout [list polkit::keys_timeout $id $gen]
}

proc polkit::keys_send {id line} {
	variable req
	if {![info exists req($id)]} return
	set a [dict get $req($id) kchan]
	if {$a eq ""} return
	if {[catch {puts $a $line; flush $a}]} { log "$id: the keyboard helper is gone" }
}

proc polkit::keys_stop {id} {
	variable req
	if {![info exists req($id)]} return
	set a [dict get $req($id) kchan]
	dict set req($id) kchan ""
	dict incr req($id) kgen
	if {$a eq ""} return
	catch {puts $a quit; flush $a}
	catch {fileevent $a readable {}}
	catch {close $a}
	# it quits when the socket closes; make sure of it (the keyboard is not safe while it lives)
	set pid [dict get $req($id) kpid]
	if {$pid ne ""} { after 1500 [list polkit::keys_reap $pid] }
}
proc polkit::keys_reap {pid} { catch {exec kill -TERM $pid 2>/dev/null} }

proc polkit::keys_timeout {id gen} {
	variable req
	if {![info exists req($id)] || [dict get $req($id) kgen] != $gen || [dict get $req($id) kready]} return
	log "$id: the keyboard helper did not get the keyboard in time"
	finish $id failure
}

proc polkit::keys_readable {id gen a} {
	variable req
	if {![info exists req($id)] || [dict get $req($id) kgen] != $gen} return
	while 1 {
		if {[catch {gets $a line} n]} { set n -1 }
		if {$n < 0} {
			if {[catch {eof $a} ended] || $ended} { keys_gone $id }
			return
		}
		keys_event $id $line
		if {![info exists req($id)] || [dict get $req($id) kgen] != $gen} return
	}
}

# The keyboard helper ended: before it said ready, the request fails with no card; after, the
# keyboard is not exclusively ours any more, so the request is cancelled like "lost".
proc polkit::keys_gone {id} {
	variable req
	if {[dict get $req($id) kready]} {
		log "$id: the keyboard helper ended: cancelled"
		finish $id cancelled
	} else {
		log "$id: the keyboard helper ended before it had the keyboard (the compositor refused, or it crashed): no card"
		finish $id failure
	}
}

proc polkit::keys_event {id line} {
	variable req
	set sp [string first " " $line]
	set word [expr {$sp < 0 ? $line : [string range $line 0 $sp-1]}]
	set arg [expr {$sp < 0 ? "" : [string range $line $sp+1 end]}]
	switch -- $word {
		ready {
			if {[dict get $req($id) kready]} return
			dict set req($id) kready 1
			show $id
		}
		lost {
			# another client has the keyboard, or the surface was closed: what is typed may be going elsewhere
			if {![dict get $req($id) kready]} { keys_gone $id; return }
			log "$id: the keyboard was taken: cancelled"
			finish $id cancelled
		}
		n {
			if {![string is integer -strict $arg]} return
			dict set req($id) count $arg
			if {[dict get $req($id) shown]} { tellui key $id count $arg }
		}
		t { if {[dict get $req($id) shown]} { tellui key $id text $arg } }
		enter - esc - tab - btab - up - down - space {
			if {[dict get $req($id) shown]} { tellui key $id $word }
		}
		default { log "$id: unknown line from the keyboard helper" }
	}
}

# What the helper does with keys follows the card's focus (see the header).
proc polkit::focus {id where} {
	variable req
	if {![info exists req($id)]} return
	dict set req($id) mode [expr {$where eq "field" ? "text" : "nav"}]
	apply_mode $id
}
proc polkit::apply_mode {id} {
	variable req
	set m [dict get $req($id) mode]
	if {$m eq "text" && [dict get $req($id) echo]} { set m echo }
	keys_send $id "mode $m"
}

# ---- the helper session
proc polkit::find_helper {} {
	variable helper; variable helpers
	if {$helper ne ""} { return $helper }
	foreach h $helpers { if {[file executable $h]} { return $h } }
	error "polkit-agent-helper-1 not found"
}

# polkit-agent-helper-1 USER; the cookie is the first line on its stdin; it
# prints PAM_PROMPT_ECHO_OFF|PAM_PROMPT_ECHO_ON|PAM_ERROR_MSG|PAM_TEXT_INFO text,
# SUCCESS or FAILURE, and reads one line for each prompt. On SUCCESS it has
# already told polkitd itself (it is setuid root; we are not).
proc polkit::begin_session {id} {
	variable req
	set r $req($id)
	set user [dict get $r identity]
	if {![safe_name $user]} { finish $id failure; return }
	# a clean environment for the child (the helper is setuid root: it gets a fixed PATH and
	# the locale, nothing else of ours). Unset one by one: [array unset ::env] leaves the real environment alone.
	set saved [array get ::env]
	foreach k [array names ::env] { unset ::env($k) }
	set ::env(PATH) /usr/bin:/bin:/usr/sbin:/sbin
	foreach v {LANG LC_ALL LC_MESSAGES} { if {[dict exists $saved $v]} { set ::env($v) [dict get $saved $v] } }
	set code [catch {
		set h [find_helper]
		# stdin of the PAM helper is a pipe whose write end only we (the cookie) and the keyboard
		# helper (the answers) ever hold
		lassign [chan pipe] pr pw
		set ch [open |[list $h $user <@ $pr] r]
		close $pr
	} err]
	foreach k [array names ::env] { unset ::env($k) }
	array set ::env $saved
	if {$code} {
		log "$id: cannot start the helper: [lindex [split $err \n] 0]"
		tellui error $id "Authentication is not available."
		finish $id failure
		return
	}
	fconfigure $ch -blocking 0 -buffering line -translation lf -encoding utf-8
	set gen [dict get $r gen]
	dict set req($id) chan $ch
	dict set req($id) pending 0
	fileevent $ch readable [list polkit::readable $id $gen $ch]
	if {[catch {puts $pw [dict get $r cookie]; flush $pw} err]} {
		catch {close $pw}
		log "$id: cannot talk to the helper: [lindex [split $err \n] 0]"
		tellui error $id "Authentication is not available."
		end_session $id
		finish $id failure
		return
	}
	if {[catch {unix_extra::sendfds [dict get $req($id) kchan] [list $pw] "secret\n"} err]} {
		# the keyboard helper is gone: nothing could be typed, and the keyboard is not ours
		catch {close $pw}
		log "$id: cannot reach the keyboard helper: [lindex [split $err \n] 0]: cancelled"
		end_session $id
		finish $id cancelled
		return
	}
	close $pw
}

proc polkit::end_session {id} {
	variable req
	if {![info exists req($id)]} return
	set ch [dict get $req($id) chan]
	dict set req($id) chan ""
	dict set req($id) pending 0
	dict incr req($id) gen
	keys_send $id clear
	if {$ch eq ""} return
	catch {fileevent $ch readable {}}
	catch {set p [pid $ch]; exec kill -TERM {*}$p 2>/dev/null}
	# nonblocking: close detaches the child and does not wait for it
	catch {fconfigure $ch -blocking 0}
	catch {close $ch}
}

proc polkit::readable {id gen ch} {
	variable req
	if {![info exists req($id)] || [dict get $req($id) gen] != $gen} { catch {close $ch}; return }
	set n [expr {[catch {gets $ch line} n] ? -1 : $n}]
	if {$n < 0} {
		# -1 with no end of file is only half a line so far
		if {[catch {eof $ch} ended] || $ended} {
			log "$id: the helper ended"
			tellui error $id "Authentication is not available."
			end_session $id
			finish $id failure
		}
		return
	}
	set sp [string first " " $line]
	set word [expr {$sp < 0 ? $line : [string range $line 0 $sp-1]}]
	set text [expr {$sp < 0 ? "" : [string range $line $sp+1 end]}]
	switch -- $word {
		PAM_PROMPT_ECHO_OFF - PAM_PROMPT_ECHO_ON {
			dict set req($id) pending 1
			set echo [expr {$word eq "PAM_PROMPT_ECHO_ON"}]
			dict set req($id) echo $echo
			# the mode stays what the card last asked for (its focus), across conversations
			keys_send $id clear
			apply_mode $id
			if {[catch {callui prompt $id $text $echo} err]} {
				log "$id: the UI could not prompt: [lindex [split $err \n] 0]"
				end_session $id
				finish $id cancelled
			}
		}
		PAM_ERROR_MSG { tellui error $id $text }
		PAM_TEXT_INFO { tellui info $id $text }
		SUCCESS {
			log "$id: authenticated"
			end_session $id
			finish $id success
		}
		FAILURE {
			dict incr req($id) tries
			log "$id: authentication failed (try [dict get $req($id) tries])"
			end_session $id
			tellui error $id "Sorry, that didn't work. Please try again."
			# a new conversation, as every agent does: PAM's own delay and lockout
			# are what limit the tries
			after idle [list polkit::retry $id]
		}
		default { log "$id: unknown line from the helper" }
	}
}
proc polkit::retry {id} {
	variable req; variable active
	if {[info exists req($id)] && $active eq $id && [dict get $req($id) chan] eq ""} { begin_session $id }
}

# ---- what the UI calls
# Nothing typed passes through here: the keyboard helper writes the answer into the PAM helper's stdin.
# This only tells it when. A hidden prompt with nothing typed is not sent (PAM would just fail it).
proc polkit::submit {id} {
	variable req
	if {![info exists req($id)] || ![dict get $req($id) pending]} {
		error "no prompt waiting for an answer" "" {POLKIT NOPROMPT}
	}
	if {![dict get $req($id) echo] && [dict get $req($id) count] == 0} { return 0 }
	dict set req($id) pending 0
	keys_send $id submit
	return 1
}

proc polkit::cancel {id} {
	variable req
	if {![info exists req($id)]} return
	finish $id cancelled
}

# Another account: the conversation starts again for it.
proc polkit::choose {id name} {
	variable req; variable active
	if {![info exists req($id)] || $active ne $id} return
	set ok 0
	foreach i [dict get $req($id) identities] { if {[dict get $i name] eq $name} { set ok 1 } }
	if {!$ok} { error "not one of the offered accounts: $name" }
	if {$name eq [dict get $req($id) identity] && [dict get $req($id) chan] ne ""} return
	end_session $id
	dict set req($id) identity $name
	begin_session $id
}

# The end of a request: tell the UI, answer polkitd, take the next.
proc polkit::finish {id result args} {
	variable req; variable queue; variable active; variable bus
	if {![info exists req($id)]} return
	set noreply [expr {[lindex $args 0] eq "-noreply" && [lindex $args 1]}]
	end_session $id
	keys_stop $id
	set msg [dict get $req($id) msg]
	set wasactive [expr {$active eq $id}]
	set shown [dict get $req($id) shown]
	unset req($id)
	set queue [lsearch -all -inline -not -exact $queue $id]
	if {$wasactive} { set active ""; if {$shown} { tellui done $id $result } }
	if {!$noreply} {
		if {$result eq "cancelled"} {
			catch {$bus error $msg org.freedesktop.PolicyKit1.Error.Cancelled "Authentication was cancelled"}
		} else {
			catch {$bus reply $msg}
		}
	}
	log "$id: $result"
	after idle polkit::next
}
