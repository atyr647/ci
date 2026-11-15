# smtp.tcl - Mail's SMTP submission client (RFC 6409 over RFC 5321): event-driven and non-blocking over mail::net,
# on 465 with TLS from the start (RFC 8314) or on 587 with STARTTLS (RFC 3207). It logs in with AUTH PLAIN, or
# AUTH LOGIN when that is all the server offers, and never sends a password before the connection is TLS (a plain
# connection is only allowed to this computer).
#
#   mail::smtp::send OPTS FROM RCPTS BYTES CMD   sends one message; CMD gets "ok REPLY" (the server's text for
#                                                DATA) or "error KIND MESSAGE". OPTS: -host -port -security
#                                                (tls|starttls|none) -user -password -cafile -timeout MS (connect,
#                                                30000) -replytimeout MS (each reply, 300000; RFC 5321 4.5.3.2)
#                                                FROM and RCPTS are bare addresses; BYTES is the message as written
#                                                (a Bcc: header is left out of what is sent).
#   mail::smtp::probe OPTS CMD                   connect, log in and QUIT: "ok" or "error KIND MESSAGE"
#   mail::smtp::wire BYTES                       the DATA payload: CRLF line ends, dot-stuffed, "." line at the end
#   mail::smtp::without_bcc BYTES                the message without its Bcc: header (folded lines included)
#
# Error kinds: those of mail::net, and auth (login refused), rejected (a recipient was refused: MESSAGE names it),
# toobig (over the server's SIZE), refused (the sender or the message was refused), protocol, closed, timeout.

source [file join [file dirname [info script]] net.tcl]

namespace eval ::mail::smtp {
	variable seq 0
	variable S
	variable buf
	array set S {}
	array set buf {}
}

proc ::mail::smtp::send {opts from rcpts bytes cmd} {
	Start $opts [dict create from $from rcpts $rcpts bytes $bytes] $cmd
}
proc ::mail::smtp::probe {opts cmd} {
	Start $opts {} [list ::mail::smtp::Probed $cmd]
}
proc ::mail::smtp::Probed {cmd status args} {
	if {$status eq "ok"} { {*}$cmd ok } else { {*}$cmd error {*}$args }
}

proc ::mail::smtp::Start {opts job cmd} {
	variable seq
	variable S
	variable buf
	set id smtp[incr seq]
	set o [dict merge {-host "" -port 465 -security tls -user "" -password "" -cafile "" -timeout 30000
		-replytimeout 300000} $opts]
	if {[dict size $job]} {
		foreach a [concat [list [dict get $job from]] [dict get $job rcpts]] {
			if {$a eq "" || [regexp {[\s<>\x00-\x1f]} $a]} {
				after 0 [list {*}$cmd error refused "\"$a\" is not an address that can be sent to"]
				return $id
			}
		}
		if {![llength [dict get $job rcpts]]} {
			after 0 [list {*}$cmd error refused "the message has no recipients"]
			return $id
		}
	}
	set S($id) [dict create opts $o job $job cmd $cmd conn "" ext {} lines {} next "" timer "" rejected {} done 0 wire ""]
	set buf($id) ""
	set conn [mail::net::connect [dict get $o -host] [dict get $o -port] [dict get $o -security] \
		[list -cafile [dict get $o -cafile] -timeout [dict get $o -timeout]] [list ::mail::smtp::Connected $id]]
	dict set S($id) conn $conn
	return $id
}

proc ::mail::smtp::Opt {id k} {
	variable S
	dict get $S($id) opts $k
}

proc ::mail::smtp::Connected {id status args} {
	variable S
	if {![info exists S($id)]} return
	if {$status ne "ok"} { dict set S($id) conn ""; End $id error {*}$args; return }
	mail::net::reader [dict get $S($id) conn] [list ::mail::smtp::Feed $id]
	Expect $id 220 ::mail::smtp::Greeted
}

proc ::mail::smtp::End {id status args} {
	variable S
	variable buf
	if {![info exists S($id)]} return
	set cmd [dict get $S($id) cmd]
	after cancel [dict get $S($id) timer]
	set conn [dict get $S($id) conn]
	if {$conn ne ""} { mail::net::close $conn }
	unset S($id) buf($id)
	{*}$cmd $status {*}$args
}

# wait for a reply; NEXT is called with the code and the reply's lines when it is one of CODES, else the session ends
proc ::mail::smtp::Expect {id codes next {fail ""}} {
	variable S
	dict set S($id) next [list $codes $next $fail]
	dict unset S($id) left
	after cancel [dict get $S($id) timer]
	dict set S($id) timer [after [Opt $id -replytimeout] [list ::mail::smtp::Timeout $id]]
}
proc ::mail::smtp::Timeout {id} {
	variable S
	if {![info exists S($id)]} return
	# still sending the message on a slow link: the reply comes after the last byte; once it has left this process
	# the kernel's send buffer may still hold megabytes, so the last wait grows with the size (64 KB/s)
	set left [mail::net::pending [dict get $S($id) conn]]
	set was [expr {[dict exists $S($id) left] ? [dict get $S($id) left] : -1}]
	dict set S($id) left $left
	set ms [Opt $id -replytimeout]
	if {$left > 0 && ($was < 0 || $left < $was)} {
		dict set S($id) timer [after $ms [list ::mail::smtp::Timeout $id]]
		return
	}
	if {$left == 0 && $was > 0} {
		set ms [expr {$ms + [string length [dict get $S($id) wire]] * 1000 / 65536}]
		dict set S($id) timer [after $ms [list ::mail::smtp::Timeout $id]]
		return
	}
	End $id error timeout "[Opt $id -host] stopped answering"
}

proc ::mail::smtp::Feed {id what data} {
	variable S
	variable buf
	if {![info exists S($id)]} return
	if {$what eq "eof"} { End $id error closed "[Opt $id -host] closed the connection"; return }
	if {$what eq "error"} { End $id error closed $data; return }
	append buf($id) $data
	while {[info exists S($id)]} {
		set e [string first \n $buf($id)]
		if {$e < 0} break
		set line [string trimright [string range $buf($id) 0 $e-1] \r]
		set buf($id) [string range $buf($id) $e+1 end]
		if {![regexp {^(\d{3})([ -]?)(.*)$} $line -> code sep text]} {
			End $id error protocol "a reply that makes no sense: [string range $line 0 80]"
			return
		}
		dict lappend S($id) lines $text
		if {$sep eq "-"} continue
		set lines [dict get $S($id) lines]
		dict set S($id) lines {}
		lassign [dict get $S($id) next] codes next fail
		dict set S($id) next ""
		after cancel [dict get $S($id) timer]
		if {$codes eq ""} {
			End $id error protocol "a reply nobody asked for: $code $text"
			return
		}
		if {$code in $codes} {
			{*}$next $id $code $lines
		} elseif {$fail ne ""} {
			{*}$fail $id $code $lines
		} else {
			Refused $id $code $lines
		}
	}
}

proc ::mail::smtp::Refused {id code lines} {
	set text [Text $lines]
	set kind [expr {$code == 552 || [string match {5.3.4*} $text] ? "toobig" : "refused"}]
	End $id error $kind "the server refused: $code $text"
}
# a reply's text without its enhanced status code
proc ::mail::smtp::Text {lines} {
	set t [join $lines " "]
	regsub {^[245]\.\d{1,3}\.\d{1,3} } $t {} t
	return $t
}

proc ::mail::smtp::Line {id text} {
	variable S
	mail::net::send [dict get $S($id) conn] "$text\r\n"
}

proc ::mail::smtp::Greeted {id code lines} { Ehlo $id }

proc ::mail::smtp::Ehlo {id} {
	variable S
	# the address literal of this end, not the host name (it says nothing about this computer)
	set me [mail::net::sockname [dict get $S($id) conn]]
	set lit [expr {[string first : $me] >= 0 ? "\[IPv6:$me\]" : "\[$me\]"}]
	Line $id "EHLO $lit"
	Expect $id 250 ::mail::smtp::Ehloed
}
proc ::mail::smtp::Ehloed {id code lines} {
	variable S
	set ext {}
	foreach l [lrange $lines 1 end] {
		set w [split [string trim $l]]
		dict set ext [string toupper [lindex $w 0]] [lrange $w 1 end]
	}
	dict set S($id) ext $ext
	set conn [dict get $S($id) conn]
	if {[Opt $id -security] eq "starttls" && ![mail::net::secure $conn]} {
		if {![dict exists $ext STARTTLS]} {
			End $id error tls "[Opt $id -host] does not offer STARTTLS; choose SSL/TLS"
			return
		}
		Line $id STARTTLS
		Expect $id 220 ::mail::smtp::TlsGo
		return
	}
	Auth $id
}
proc ::mail::smtp::TlsGo {id code lines} {
	variable S
	variable buf
	if {$buf($id) ne ""} { End $id error tls "the server sent data before the secure connection started"; return }
	mail::net::starttls [dict get $S($id) conn] [list ::mail::smtp::TlsDone $id]
}
proc ::mail::smtp::TlsDone {id status args} {
	variable S
	if {![info exists S($id)]} return
	if {$status ne "ok"} { dict set S($id) conn ""; End $id error {*}$args; return }
	# the extensions said before TLS are forgotten (RFC 3207 4.2)
	dict set S($id) ext {}
	Ehlo $id
}

proc ::mail::smtp::Auth {id} {
	variable S
	set ext [dict get $S($id) ext]
	set user [encoding convertto utf-8 [Opt $id -user]]
	set pass [encoding convertto utf-8 [Opt $id -password]]
	if {$user eq ""} { Mail $id; return }
	set mechs [expr {[dict exists $ext AUTH] ? [string toupper [dict get $ext AUTH]] : {}}]
	if {"PLAIN" in $mechs} {
		Line $id "AUTH PLAIN [binary encode base64 "\0$user\0$pass"]"
		Expect $id 235 ::mail::smtp::Authed ::mail::smtp::AuthFailed
	} elseif {"LOGIN" in $mechs} {
		Line $id "AUTH LOGIN"
		Expect $id 334 [list ::mail::smtp::LoginUser $user $pass] ::mail::smtp::AuthFailed
	} else {
		End $id error auth "[Opt $id -host] offers no password login"
	}
}
proc ::mail::smtp::LoginUser {user pass id code lines} {
	Line $id [binary encode base64 $user]
	Expect $id 334 [list ::mail::smtp::LoginPass $pass] ::mail::smtp::AuthFailed
}
proc ::mail::smtp::LoginPass {pass id code lines} {
	Line $id [binary encode base64 $pass]
	Expect $id 235 ::mail::smtp::Authed ::mail::smtp::AuthFailed
}
proc ::mail::smtp::AuthFailed {id code lines} {
	set t [Text $lines]
	End $id error auth [expr {$t eq "" ? "the user name or password was not accepted" : $t}]
}
proc ::mail::smtp::Authed {id code lines} { Mail $id }

proc ::mail::smtp::Mail {id} {
	variable S
	set job [dict get $S($id) job]
	if {![dict size $job]} {
		Line $id QUIT
		Expect $id {221} ::mail::smtp::Quit ::mail::smtp::Quit
		dict set S($id) result ""
		return
	}
	set ext [dict get $S($id) ext]
	set wire [wire [without_bcc [dict get $job bytes]]]
	dict set S($id) wire $wire
	set size [expr {[string length $wire] - 5}]
	set params ""
	if {[dict exists $ext SIZE]} {
		set max [lindex [dict get $ext SIZE] 0]
		if {[string is digit -strict $max] && $max > 0 && $size > $max} {
			End $id error toobig "the message is [Mb $size]; [Opt $id -host] takes at most [Mb $max]"
			return
		}
		append params " SIZE=$size"
	}
	if {[dict exists $ext 8BITMIME] && [regexp {[\x80-\xff]} $wire]} { append params " BODY=8BITMIME" }
	set addrs [concat [list [dict get $job from]] [dict get $job rcpts]]
	if {[regexp {[\u0080-\uffff]} [join $addrs]]} {
		if {![dict exists $ext SMTPUTF8]} {
			End $id error refused "[Opt $id -host] does not take addresses with letters outside ASCII"
			return
		}
		append params " SMTPUTF8"
	}
	Line $id [encoding convertto utf-8 "MAIL FROM:<[dict get $job from]>$params"]
	dict set S($id) todo [dict get $job rcpts]
	Expect $id 250 ::mail::smtp::Rcpt
}
proc ::mail::smtp::Mb {n} {
	format "%.1f MB" [expr {$n / 1000000.0}]
}
proc ::mail::smtp::Rcpt {id code lines} {
	variable S
	set todo [dict get $S($id) todo]
	if {![llength $todo]} {
		set rej [dict get $S($id) rejected]
		if {[llength $rej]} {
			# any refused recipient stops the send: nobody gets a message that silently missed someone
			dict set S($id) failed [list rejected "the server refused [join $rej {; }]"]
			Line $id RSET
			Expect $id {250} ::mail::smtp::Abort ::mail::smtp::Abort
			return
		}
		Line $id DATA
		Expect $id 354 ::mail::smtp::Data
		return
	}
	dict set S($id) todo [lrange $todo 1 end]
	set to [lindex $todo 0]
	dict set S($id) rcpt $to
	Line $id [encoding convertto utf-8 "RCPT TO:<$to>"]
	Expect $id {250 251} ::mail::smtp::Rcpt ::mail::smtp::RcptRefused
}
proc ::mail::smtp::RcptRefused {id code lines} {
	variable S
	dict lappend S($id) rejected "[dict get $S($id) rcpt] ($code [Text $lines])"
	Rcpt $id 250 {}
}
proc ::mail::smtp::Abort {id code lines} {
	variable S
	set f [dict get $S($id) failed]
	Line $id QUIT
	End $id error {*}$f
}
proc ::mail::smtp::Data {id code lines} {
	variable S
	# the whole payload goes in one write; mail::net queues what the socket does not take at once
	mail::net::send [dict get $S($id) conn] [dict get $S($id) wire]
	Expect $id 250 ::mail::smtp::Sent
}
proc ::mail::smtp::Sent {id code lines} {
	variable S
	dict set S($id) result [Text $lines]
	Line $id QUIT
	Expect $id {221} ::mail::smtp::Quit ::mail::smtp::Quit
}
proc ::mail::smtp::Quit {id code lines} {
	variable S
	End $id ok [dict get $S($id) result]
}

# ---- the message on the wire ----------------------------------------------------------------------------------------
proc ::mail::smtp::wire {bytes} {
	# CRLF line ends (a bare CR or LF becomes CRLF), then a "." at the start of a line is doubled (RFC 5321 4.5.2)
	set t [string map {\r\n \n \r \n} $bytes]
	if {$t ne "" && [string index $t end] ne "\n"} { append t \n }
	set out ""
	foreach l [split [string range $t 0 end-1] \n] {
		if {[string index $l 0] eq "."} { set l .$l }
		append out $l \r\n
	}
	append out .\r\n
}

proc ::mail::smtp::without_bcc {bytes} {
	set e [string first "\r\n\r\n" $bytes]
	set nl \r\n
	if {$e < 0 || ([string first \n\n $bytes] >= 0 && [string first \n\n $bytes] < $e)} {
		set e [string first \n\n $bytes]
		set nl \n
	}
	if {$e < 0} { return $bytes }
	set head [string range $bytes 0 [expr {$e - 1}]]
	set body [string range $bytes $e end]
	set out {}
	set skip 0
	foreach l [split [string map [list $nl \n] $head] \n] {
		if {[regexp {^[ \t]} $l]} { if {!$skip} { lappend out $l }; continue }
		set skip [regexp -nocase {^bcc:} $l]
		if {!$skip} { lappend out $l }
	}
	return "[join $out $nl]$body"
}
