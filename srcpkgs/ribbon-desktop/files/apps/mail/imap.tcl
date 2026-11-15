# imap.tcl - Mail's IMAP4rev1 client (RFC 3501): event-driven and non-blocking over mail::net (TLS on 993 or
# STARTTLS on 143). One command is in flight at a time per session; later ones wait in a queue. Each call takes a
# callback that is later called with "ok RESULT" or "error KIND MESSAGE".
#
#   mail::imap::open OPTS CMD        a session id. OPTS: -host -port -security (tls|starttls|none) -user -password
#                                    -cafile -timeout MS (connect, 30000) -idletimeout MS (no reply to a command for
#                                    that long ends the session, 90000) -onevent CMD (called with each response the
#                                    server sends unasked: {type exists n N}, {type expunge n N}, {type fetch n N
#                                    data DICT}, {type bye text T}) -onclose CMD (called with "KIND MESSAGE" once the
#                                    session ends without mail::imap::close). CMD gets "ok SID" once logged in
#                                    (AUTHENTICATE PLAIN when offered, else LOGIN).
#   mail::imap::caps SID             the capabilities (upper case)
#   mail::imap::has SID CAP
#   mail::imap::mailboxes SID CMD        ok {{name NAME flags {\HasNoChildren \Sent ...} delim /} ...}; NAME as sent
#                                    (modified UTF-7; mail::imap::utf7_decode gives the text)
#   mail::imap::select SID BOX CMD   ok {exists N uidvalidity N uidnext N flags L permanentflags L readonly 0|1
#                                    highestmodseq N}; BOX as LIST gave it. -examine opens it read-only
#   mail::imap::uid_search SID CRITERIA CMD     ok {UID ...}; CRITERIA is the IMAP text, e.g. "UID 5:*"
#   mail::imap::uid_fetch SID SET ITEMS CMD ?EACH? ?MODIFIERS?  ok {}; EACH (when given) is called with a dict
#                                    per message (keys upper case: UID FLAGS RFC822.SIZE INTERNALDATE BODY[] ...) as
#                                    it arrives; MODIFIERS e.g. "CHANGEDSINCE 812" (RFC 7162)
#   mail::imap::uid_store SID SET OP FLAGS CMD  OP is +FLAGS.SILENT, -FLAGS.SILENT or FLAGS.SILENT
#   mail::imap::append_msg SID BOX FLAGS BYTES CMD  ok {uidvalidity N uid N} (empty without UIDPLUS)
#   mail::imap::uid_copy SID SET BOX CMD   ok {uidvalidity N src {UID ...} dst {UID ...}} (COPYUID, RFC 4315; empty
#                                    without UIDPLUS)
#   mail::imap::uid_move SID SET BOX CMD   UID MOVE (RFC 6851, when the server has MOVE): as uid_copy
#   mail::imap::uid_expunge SID SET CMD    UID EXPUNGE (UIDPLUS): only those of SET that have \Deleted
#   mail::imap::expunge SID CMD      EXPUNGE: every message of the folder that has \Deleted
#   mail::imap::create SID BOX CMD
#   mail::imap::noop SID CMD
#   mail::imap::idle SID CMD         IDLE (RFC 2177); the server's news goes to -onevent; CMD is called when it ends
#   mail::imap::done SID             ends IDLE
#   mail::imap::idling SID           1 while IDLE runs
#   mail::imap::logout SID CMD       LOGOUT, then the session is closed
#   mail::imap::close SID            closes it now
#   mail::imap::probe OPTS CMD       connect, log in and log out: "ok" or "error KIND MESSAGE" (Test connection)
#   mail::imap::utf7_encode TEXT / utf7_decode NAME    mailbox names (RFC 3501 5.1.3)
#
# Error kinds: those of mail::net, and auth (the server refused the user name or password), no (a command was
# refused), protocol (a reply that makes no sense), closed (the server hung up), timeout, failed (handling a reply
# raised an error, e.g. in a callback).
#
# Bytes: the connection is binary. Message bodies and literals are byte strings; user names and passwords go out as
# UTF-8.

source [file join [file dirname [info script]] net.tcl]

namespace eval ::mail::imap {
	variable seq 0
	variable S                ;# array: SID -> session dict
	variable buf              ;# array: SID -> bytes not parsed yet
	variable scan             ;# array: SID -> where the scan for a complete response resumes
	array set S {}
	array set buf {}
	array set scan {}
}

proc ::mail::imap::open {opts cmd} {
	variable seq
	variable S
	variable buf
	variable scan
	set sid imap[incr seq]
	set o [dict merge {-host "" -port 993 -security tls -user "" -password "" -cafile "" -timeout 30000
		-idletimeout 90000 -onevent "" -onclose ""} $opts]
	set S($sid) [dict create opts $o cmd $cmd conn "" caps {} tag 0 queue {} cur "" state connecting \
		idling 0 timer "" closing 0 newcaps 0 preauth 0 wantdone 0 sent 0]
	set buf($sid) ""
	set scan($sid) 0
	set conn [mail::net::connect [dict get $o -host] [dict get $o -port] [dict get $o -security] \
		[list -cafile [dict get $o -cafile] -timeout [dict get $o -timeout]] [list ::mail::imap::Connected $sid]]
	dict set S($sid) conn $conn
	return $sid
}

proc ::mail::imap::Opt {sid name} {
	variable S
	dict get $S($sid) opts $name
}

proc ::mail::imap::Connected {sid status args} {
	variable S
	if {![info exists S($sid)]} return
	if {$status ne "ok"} {
		Finish $sid {*}$args
		return
	}
	set conn [dict get $S($sid) conn]
	mail::net::reader $conn [list ::mail::imap::Feed $sid]
	dict set S($sid) state greeting
	Arm $sid
}

# the session could not be opened, or ended: the open callback (or -onclose) hears why
proc ::mail::imap::Finish {sid kind msg} {
	variable S
	if {![info exists S($sid)]} return
	set state [dict get $S($sid) state]
	set cmd [dict get $S($sid) cmd]
	set onclose [Opt $sid -onclose]
	set cur [dict get $S($sid) cur]
	set queue [dict get $S($sid) queue]
	set closing [dict get $S($sid) closing]
	Drop $sid
	# commands waiting for an answer hear it too
	if {$state eq "ready"} {
		if {$cur ne ""} { catch {{*}[dict get $cur cb] error $kind $msg} }
		foreach c $queue { catch {{*}[dict get $c cb] error $kind $msg} }
		if {!$closing && $onclose ne ""} { {*}$onclose $kind $msg }
	} else {
		{*}$cmd error $kind $msg
	}
}

proc ::mail::imap::Drop {sid} {
	variable S
	variable buf
	variable scan
	if {![info exists S($sid)]} return
	after cancel [dict get $S($sid) timer]
	set conn [dict get $S($sid) conn]
	if {$conn ne ""} { mail::net::close $conn }
	unset S($sid) buf($sid) scan($sid)
}

proc ::mail::imap::close {sid} {
	variable S
	if {![info exists S($sid)]} return
	dict set S($sid) closing 1
	Drop $sid
}

# no reply for -idletimeout while a command waits (or before the greeting): the connection is dead
proc ::mail::imap::Arm {sid} {
	variable S
	after cancel [dict get $S($sid) timer]
	dict set S($sid) timer [after [Opt $sid -idletimeout] [list ::mail::imap::Timeout $sid]]
}
proc ::mail::imap::Disarm {sid} {
	variable S
	after cancel [dict get $S($sid) timer]
	dict set S($sid) timer ""
}
proc ::mail::imap::Timeout {sid} {
	variable S
	if {![info exists S($sid)]} return
	# still sending (a large APPEND): the server answers once it has it all. Once the last byte has left this
	# process, the kernel's send buffer may still hold megabytes, so the last wait grows with the size (64 KB/s)
	set left [mail::net::pending [dict get $S($sid) conn]]
	set was [expr {[dict exists $S($sid) left] ? [dict get $S($sid) left] : -1}]
	dict set S($sid) left $left
	if {$left > 0 && ($was < 0 || $left < $was)} { Arm $sid; return }
	if {$left == 0 && $was > 0} {
		after cancel [dict get $S($sid) timer]
		set ms [expr {[Opt $sid -idletimeout] + [dict get $S($sid) sent] * 1000 / 65536}]
		dict set S($sid) timer [after $ms [list ::mail::imap::Timeout $sid]]
		return
	}
	Finish $sid timeout "[Opt $sid -host] stopped answering"
}

# ---- reading: complete responses out of the byte stream ----------------------------------------------------------
proc ::mail::imap::Feed {sid what data} {
	variable S
	variable buf
	variable scan
	if {![info exists S($sid)]} return
	if {$what eq "eof"} { Finish $sid closed "[Opt $sid -host] closed the connection"; return }
	if {$what eq "error"} { Finish $sid closed $data; return }
	if {[dict get $S($sid) timer] ne ""} { Arm $sid }
	append buf($sid) $data
	set p $scan($sid)
	while {1} {
		set e [string first \r\n $buf($sid) $p]
		if {$e < 0} break
		# a line ending in {N} carries N bytes of literal after its CRLF
		if {[string index $buf($sid) $e-1] eq "\}" && [regexp {\{(\d+)\}$} [string range $buf($sid) [expr {max($p, $e - 24)}] $e-1] -> n]} {
			set need [expr {$e + 2 + $n}]
			# short: the next read resumes at this segment's start, so its header is measured again
			if {[string length $buf($sid)] < $need} break
			set p $need
			continue
		}
		# the response leaves the buffer before it is handled: what follows it is all that is unread (STARTTLS)
		set resp [string range $buf($sid) 0 $e-1]
		set buf($sid) [string range $buf($sid) $e+2 end]
		set p 0
		# an error in handling it (a response that cannot be parsed, a store that cannot write) ends the session: its
		# commands and -onclose hear why, instead of the session waiting on a reply that was already taken
		if {[catch {Handle $sid $resp} err]} {
			if {[info exists S($sid)]} { Finish $sid failed $err }
			return
		}
		if {![info exists S($sid)]} return
	}
	set scan($sid) $p
}

# one response, literals inline ("{N}\r\n" and the bytes)
proc ::mail::imap::Handle {sid resp} {
	variable S
	if {[string index $resp 0] eq "+"} {
		Continue $sid [string trimleft [string range $resp 1 end] " "]
		return
	}
	set sp [string first " " $resp]
	if {$sp < 0} { Finish $sid protocol "a reply that makes no sense: $resp"; return }
	set tag [string range $resp 0 $sp-1]
	set rest [string range $resp $sp+1 end]
	if {$tag eq "*"} {
		Untagged $sid $rest
	} else {
		Tagged $sid $tag $rest
	}
}

# "OK [CODE args] text" -> {status OK code CODE args ARGS text TEXT}
proc ::mail::imap::Status {rest} {
	set r [dict create status "" code "" args "" text ""]
	if {![regexp {^([A-Za-z]+)(?: (.*))?$} $rest -> st tail]} { return $r }
	dict set r status [string toupper $st]
	if {[regexp {^\[([A-Za-z0-9.-]+)(?: ([^\]]*))?\] ?(.*)$} $tail -> code args text]} {
		dict set r code [string toupper $code]
		dict set r args $args
		dict set r text $text
	} else {
		dict set r text $tail
	}
	return $r
}

proc ::mail::imap::Untagged {sid rest} {
	variable S
	if {[regexp -nocase {^(OK|NO|BAD|PREAUTH|BYE)\M} $rest]} {
		set st [Status $rest]
		set status [dict get $st status]
		if {[dict get $S($sid) state] eq "greeting"} {
			Greeting $sid $st
			return
		}
		if {$status eq "BYE"} {
			Event $sid [dict create type bye text [dict get $st text]]
			dict set S($sid) bye [dict get $st text]
			return
		}
		Code $sid $st
		return
	}
	if {[regexp {^(\d+) ([A-Za-z]+)(?: (.*))?$} $rest -> n what tail]} {
		set what [string toupper $what]
		switch -- $what {
			EXISTS { set ev [dict create type exists n $n] }
			RECENT { set ev [dict create type recent n $n] }
			EXPUNGE { set ev [dict create type expunge n $n] }
			FETCH {
				set ev [dict create type fetch n $n data [FetchDict [lindex [parse $tail] 0]]]
			}
			default { set ev [dict create type [string tolower $what] n $n] }
		}
		Data $sid $ev
		return
	}
	if {[regexp {^([A-Za-z0-9=.-]+)(?: (.*))?$} $rest -> what tail]} {
		set what [string toupper $what]
		switch -- $what {
			CAPABILITY { dict set S($sid) caps [string toupper [split [string trim $tail]]]; return }
			FLAGS { set ev [dict create type flags flags [lindex [parse $tail] 0]] }
			LIST - LSUB {
				lassign [parse $tail] flags delim name
				set ev [dict create type list flags $flags delim $delim name $name]
			}
			SEARCH {
				set uids {}
				foreach t [parse $tail] { if {[string is digit -strict $t]} { lappend uids $t } }
				set ev [dict create type search uids $uids]
			}
			default { set ev [dict create type [string tolower $what] data [parse $tail]] }
		}
		Data $sid $ev
		return
	}
	Finish $sid protocol "a reply that makes no sense: [string range $rest 0 80]"
}

# untagged data: to the command in flight, and what the server says unasked to -onevent
proc ::mail::imap::Data {sid ev} {
	variable S
	set cur [dict get $S($sid) cur]
	set taken 0
	if {$cur ne "" && [dict get $cur ondata] ne ""} {
		set taken [{*}[dict get $cur ondata] $ev]
	}
	if {!$taken && [dict get $ev type] in {exists expunge fetch}} { Event $sid $ev }
}
proc ::mail::imap::Event {sid ev} {
	set cmd [Opt $sid -onevent]
	if {$cmd ne ""} { {*}$cmd $ev }
}

# response codes in untagged OK lines (SELECT's UIDVALIDITY, UIDNEXT, PERMANENTFLAGS ...)
proc ::mail::imap::Code {sid st} {
	variable S
	set cur [dict get $S($sid) cur]
	if {[dict get $st code] eq "CAPABILITY"} {
		dict set S($sid) caps [string toupper [split [string trim [dict get $st args]]]]
	}
	if {$cur ne "" && [dict get $cur ondata] ne ""} {
		{*}[dict get $cur ondata] [dict create type code code [dict get $st code] args [dict get $st args]]
	}
}

# FETCH's (KEY value KEY value ...) as a dict with upper-case keys
proc ::mail::imap::FetchDict {items} {
	set d {}
	foreach {k v} $items {
		set k [string toupper $k]
		# BODY.PEEK[] comes back as BODY[]; an origin octet <N> is dropped
		regsub {<\d+>$} $k {} k
		dict set d $k $v
	}
	return $d
}

# ---- the tokenizer: a response's data as Tcl lists (parentheses nest; NIL is "") ------------------------------
proc ::mail::imap::parse {s} {
	set stack {}
	set cur {}
	set n [string length $s]
	set p 0
	while {$p < $n} {
		set c [string index $s $p]
		switch -- $c {
			" " { incr p }
			"(" { lappend stack $cur; set cur {}; incr p }
			")" {
				set inner $cur
				set cur [lindex $stack end]
				set stack [lrange $stack 0 end-1]
				lappend cur $inner
				incr p
			}
			"\"" {
				set out ""
				incr p
				while {$p < $n} {
					set q [string first "\"" $s $p]
					set b [string first "\\" $s $p]
					if {$q < 0} { append out [string range $s $p end]; set p $n; break }
					if {$b >= 0 && $b < $q} {
						append out [string range $s $p $b-1] [string index $s $b+1]
						set p [expr {$b + 2}]
						continue
					}
					append out [string range $s $p $q-1]
					set p [expr {$q + 1}]
					break
				}
				lappend cur $out
			}
			"\{" {
				set e [string first "\}" $s $p]
				set len [string trimright [string range $s $p+1 $e-1] +]
				if {$e < 0 || ![string is digit -strict $len]} { error "bad literal" }
				set from [expr {$e + 3}]
				lappend cur [string range $s $from [expr {$from + $len - 1}]]
				set p [expr {$from + $len}]
			}
			default {
				# an atom; a [section] inside it may hold spaces and parentheses, an <origin> may follow it
				set q $p
				while {$q < $n} {
					set c [string index $s $q]
					if {$c eq " " || $c eq "(" || $c eq ")"} break
					if {$c eq "\["} {
						set close [string first "\]" $s $q]
						if {$close < 0} { set q $n; break }
						set q [expr {$close + 1}]
						continue
					}
					incr q
				}
				set atom [string range $s $p $q-1]
				lappend cur [expr {[string toupper $atom] eq "NIL" ? "" : $atom}]
				set p $q
			}
		}
	}
	while {[llength $stack]} {
		set inner $cur
		set cur [lindex $stack end]
		set stack [lrange $stack 0 end-1]
		lappend cur $inner
	}
	return $cur
}

# ---- logging in ------------------------------------------------------------------------------------------------
proc ::mail::imap::Greeting {sid st} {
	variable S
	set status [dict get $st status]
	if {$status eq "BYE"} { Finish $sid closed "the server refused the connection: [dict get $st text]"; return }
	if {$status ni {OK PREAUTH}} { Finish $sid protocol "the server's greeting makes no sense"; return }
	if {[dict get $st code] eq "CAPABILITY"} {
		dict set S($sid) caps [string toupper [split [string trim [dict get $st args]]]]
	}
	dict set S($sid) preauth [expr {$status eq "PREAUTH"}]
	dict set S($sid) state login
	Disarm $sid
	Caps $sid [list ::mail::imap::StartTls $sid]
}

# CAPABILITY when the server has not said them
proc ::mail::imap::Caps {sid next} {
	variable S
	if {[llength [dict get $S($sid) caps]]} { {*}$next ok {}; return }
	Cmd $sid {{t CAPABILITY}} $next
}

proc ::mail::imap::StartTls {sid status args} {
	variable S
	if {![info exists S($sid)]} return
	if {$status ne "ok"} { Finish $sid {*}$args; return }
	if {"IMAP4REV1" ni [dict get $S($sid) caps] && "IMAP4" ni [dict get $S($sid) caps]} {
		Finish $sid protocol "[Opt $sid -host] is not an IMAP4rev1 server"
		return
	}
	if {[Opt $sid -security] ne "starttls" || [mail::net::secure [dict get $S($sid) conn]]} {
		Auth $sid
		return
	}
	if {[dict get $S($sid) preauth]} {
		Finish $sid tls "the server logged in before STARTTLS"
		return
	}
	if {"STARTTLS" ni [dict get $S($sid) caps]} {
		Finish $sid tls "[Opt $sid -host] does not offer STARTTLS; choose SSL/TLS"
		return
	}
	Cmd $sid {{t STARTTLS}} [list ::mail::imap::TlsGo $sid]
}
proc ::mail::imap::TlsGo {sid status args} {
	variable S
	variable buf
	if {![info exists S($sid)]} return
	if {$status ne "ok"} { Finish $sid tls "STARTTLS was refused: [lindex $args end]"; return }
	if {$buf($sid) ne ""} { Finish $sid tls "the server sent data before the secure connection started"; return }
	# what the server said before TLS is forgotten (RFC 3501 6.2.1)
	dict set S($sid) caps {}
	dict set S($sid) state tls
	Arm $sid
	mail::net::starttls [dict get $S($sid) conn] [list ::mail::imap::TlsDone $sid]
}
proc ::mail::imap::TlsDone {sid status args} {
	variable S
	if {![info exists S($sid)]} return
	if {$status ne "ok"} {
		dict set S($sid) conn ""
		Finish $sid {*}[lrange $args 0 end]
		return
	}
	Disarm $sid
	dict set S($sid) state login
	Caps $sid [list ::mail::imap::AuthAfterTls $sid]
}
proc ::mail::imap::AuthAfterTls {sid status args} {
	if {$status ne "ok"} { Finish $sid {*}$args; return }
	Auth $sid
}

proc ::mail::imap::Auth {sid} {
	variable S
	if {[dict get $S($sid) preauth]} { LoggedIn $sid ok {}; return }
	set caps [dict get $S($sid) caps]
	set user [encoding convertto utf-8 [Opt $sid -user]]
	set pass [encoding convertto utf-8 [Opt $sid -password]]
	if {"AUTH=PLAIN" in $caps} {
		set ir [binary encode base64 "\0$user\0$pass"]
		if {"SASL-IR" in $caps} {
			Cmd $sid [list {t "AUTHENTICATE PLAIN "} [list t $ir]] [list ::mail::imap::LoggedIn $sid]
		} else {
			Cmd $sid {{t "AUTHENTICATE PLAIN"}} [list ::mail::imap::LoggedIn $sid] \
				-oncont [list ::mail::imap::SaslReply $sid $ir]
		}
		return
	}
	if {"LOGINDISABLED" in $caps} {
		Finish $sid auth "[Opt $sid -host] offers no password login"
		return
	}
	Cmd $sid [list {t "LOGIN "} [list a $user] {t " "} [list a $pass]] [list ::mail::imap::LoggedIn $sid]
}
proc ::mail::imap::SaslReply {sid ir text} {
	variable S
	set cur [dict get $S($sid) cur]
	if {[dict get $cur sent_ir]} {
		# a second challenge: cancel (RFC 4959)
		Raw $sid "*\r\n"
		return
	}
	dict set S($sid) cur sent_ir 1
	Raw $sid "$ir\r\n"
}

proc ::mail::imap::LoggedIn {sid status args} {
	variable S
	if {![info exists S($sid)]} return
	if {$status ne "ok"} {
		lassign $args kind msg
		if {$kind eq "no"} { set kind auth }
		Finish $sid $kind [expr {$msg eq "" ? "the user name or password was not accepted" : $msg}]
		return
	}
	# a server may have said new capabilities in the tagged OK; else ask
	if {[dict get $S($sid) newcaps]} {
		Ready $sid
	} else {
		dict set S($sid) caps {}
		Caps $sid [list ::mail::imap::Ready $sid]
	}
}
proc ::mail::imap::Ready {sid args} {
	variable S
	if {![info exists S($sid)]} return
	if {[llength $args] && [lindex $args 0] ne "ok"} { Finish $sid {*}[lrange $args 1 end]; return }
	dict set S($sid) state ready
	set cmd [dict get $S($sid) cmd]
	{*}$cmd ok $sid
}

# ---- commands --------------------------------------------------------------------------------------------------
# PARTS: {t TEXT} as is, {a STRING} an astring (atom, quoted or literal as needed), {l BYTES} a literal.
# Options: -ondata CMD (gets each untagged response; returns 1 when it used it), -oncont CMD (gets the text of a
# "+" continuation the command did not ask for by a literal).
proc ::mail::imap::Cmd {sid parts cb args} {
	variable S
	if {![info exists S($sid)]} { after 0 [list {*}$cb error closed "the session is closed"]; return }
	set c [dict create parts $parts cb $cb ondata "" oncont "" sent_ir 0 newcaps 0]
	foreach {k v} $args {
		switch -- $k {
			-ondata { dict set c ondata $v }
			-oncont { dict set c oncont $v }
		}
	}
	dict lappend S($sid) queue $c
	if {[dict get $S($sid) cur] eq ""} { Pump $sid }
}

proc ::mail::imap::Pump {sid} {
	variable S
	if {![info exists S($sid)]} return
	if {[dict get $S($sid) cur] ne ""} return
	set q [dict get $S($sid) queue]
	if {![llength $q]} return
	set c [lindex $q 0]
	dict set S($sid) queue [lrange $q 1 end]
	dict incr S($sid) tag
	set tag R[dict get $S($sid) tag]
	dict set c tag $tag
	# the command as chunks; after each synchronizing literal header the rest waits for "+"
	set chunks {}
	set line "$tag "
	set literalplus [expr {"LITERAL+" in [dict get $S($sid) caps]}]
	foreach part [dict get $c parts] {
		lassign $part kind v
		switch -- $kind {
			t { append line $v }
			a {
				set q [Astring $v]
				if {$q ne ""} { append line $q; continue }
				set kind l
			}
		}
		if {$kind eq "l"} {
			if {$literalplus} {
				append line "\{[string length $v]+\}\r\n" $v
			} else {
				append line "\{[string length $v]\}\r\n"
				lappend chunks $line
				set line $v
			}
		}
	}
	append line \r\n
	lappend chunks $line
	dict set c chunks [lrange $chunks 1 end]
	dict set S($sid) cur $c
	dict set S($sid) sent [string length [join $chunks ""]]
	dict unset S($sid) left
	dict set S($sid) newcaps 0
	Arm $sid
	Raw $sid [lindex $chunks 0]
}

# an astring as an atom or a quoted string, or "" when only a literal will do
proc ::mail::imap::Astring {v} {
	if {$v ne "" && [regexp {^[!#$&'+,./0-9:;<=>?@A-Z^_`a-z|~-]+$} $v] && [string toupper $v] ne "NIL"} { return $v }
	if {[regexp {[\r\n\x00\x80-\xff]} $v] || [string length $v] > 1000} { return "" }
	return "\"[string map {\\ \\\\ \" \\\"} $v]\""
}

proc ::mail::imap::Raw {sid bytes} {
	variable S
	if {![mail::net::send [dict get $S($sid) conn] $bytes]} {
		# mail::net reports the failure to the reader, which finishes the session
	}
}

proc ::mail::imap::Continue {sid text} {
	variable S
	set cur [dict get $S($sid) cur]
	if {$cur eq ""} { Finish $sid protocol "the server asked for more where nothing was sent"; return }
	set chunks [dict get $cur chunks]
	if {[llength $chunks]} {
		dict set S($sid) cur chunks [lrange $chunks 1 end]
		Raw $sid [lindex $chunks 0]
		return
	}
	if {[dict get $cur oncont] ne ""} {
		{*}[dict get $cur oncont] $text
		return
	}
	Finish $sid protocol "the server asked for more where nothing was sent"
}

proc ::mail::imap::Tagged {sid tag rest} {
	variable S
	set cur [dict get $S($sid) cur]
	if {$cur eq "" || [dict get $cur tag] ne $tag} {
		Finish $sid protocol "an answer to a command that was not sent ($tag)"
		return
	}
	set st [Status $rest]
	if {[dict get $st code] eq "CAPABILITY"} {
		dict set S($sid) caps [string toupper [split [string trim [dict get $st args]]]]
		dict set S($sid) newcaps 1
	}
	dict set S($sid) cur ""
	dict set S($sid) idling 0
	Disarm $sid
	set cb [dict get $cur cb]
	set status [dict get $st status]
	if {$status eq "OK"} {
		set r [dict create code [dict get $st code] args [dict get $st args] text [dict get $st text]]
		{*}$cb ok $r
	} elseif {$status eq "NO"} {
		set kind [expr {[dict get $st code] in {AUTHENTICATIONFAILED AUTHORIZATIONFAILED EXPIRED} ? "auth" : "no"}]
		if {[dict get $st code] eq "TRYCREATE"} { set kind trycreate }
		{*}$cb error $kind [dict get $st text]
	} else {
		{*}$cb error protocol "the server did not understand: [dict get $st text]"
	}
	if {[info exists S($sid)]} { after 0 [list ::mail::imap::Pump $sid] }
}

proc ::mail::imap::caps {sid} {
	variable S
	dict get $S($sid) caps
}
proc ::mail::imap::has {sid cap} {
	variable S
	expr {[string toupper $cap] in [dict get $S($sid) caps]}
}
proc ::mail::imap::alive {sid} {
	variable S
	expr {[info exists S($sid)] && [dict get $S($sid) state] eq "ready"}
}
proc ::mail::imap::idling {sid} {
	variable S
	expr {[info exists S($sid)] && [dict get $S($sid) idling]}
}

# ---- the commands Mail uses ------------------------------------------------------------------------------------
proc ::mail::imap::Collector {var ev} {
	upvar #0 $var acc
	lappend acc $ev
	return [expr {[dict get $ev type] ni {exists expunge fetch recent}}]
}

proc ::mail::imap::mailboxes {sid cb} {
	set var ::mail::imap::acc[incr ::mail::imap::seq]
	set $var {}
	Cmd $sid {{t {LIST "" "*"}}} [list ::mail::imap::ListDone $var $cb] -ondata [list ::mail::imap::Collector $var]
}
proc ::mail::imap::ListDone {var cb status args} {
	upvar #0 $var acc
	set evs $acc
	unset acc
	if {$status ne "ok"} { {*}$cb error {*}$args; return }
	set out {}
	foreach ev $evs {
		if {[dict get $ev type] ne "list"} continue
		lappend out [dict create name [dict get $ev name] flags [dict get $ev flags] delim [dict get $ev delim]]
	}
	{*}$cb ok $out
}

proc ::mail::imap::select {sid box cb args} {
	set verb [expr {"-examine" in $args ? "EXAMINE" : "SELECT"}]
	set var ::mail::imap::acc[incr ::mail::imap::seq]
	set $var [dict create exists 0 uidvalidity "" uidnext "" flags {} permanentflags {} highestmodseq "" readonly 0]
	set parts [list [list t "$verb "] [list a $box]]
	if {[has $sid CONDSTORE]} { lappend parts {t " (CONDSTORE)"} }
	Cmd $sid $parts [list ::mail::imap::SelectDone $var $cb] -ondata [list ::mail::imap::SelectData $var]
}
proc ::mail::imap::SelectData {var ev} {
	upvar #0 $var r
	switch -- [dict get $ev type] {
		exists { dict set r exists [dict get $ev n] }
		flags { dict set r flags [dict get $ev flags] }
		code {
			switch -- [dict get $ev code] {
				UIDVALIDITY { dict set r uidvalidity [string trim [dict get $ev args]] }
				UIDNEXT { dict set r uidnext [string trim [dict get $ev args]] }
				HIGHESTMODSEQ { dict set r highestmodseq [string trim [dict get $ev args]] }
				PERMANENTFLAGS { dict set r permanentflags [lindex [parse [dict get $ev args]] 0] }
			}
		}
		default { return 0 }
	}
	return 1
}
proc ::mail::imap::SelectDone {var cb status args} {
	upvar #0 $var r
	set res $r
	unset r
	if {$status ne "ok"} { {*}$cb error {*}$args; return }
	if {[dict get [lindex $args 0] code] eq "READ-ONLY"} { dict set res readonly 1 }
	{*}$cb ok $res
}

proc ::mail::imap::uid_search {sid criteria cb} {
	set var ::mail::imap::acc[incr ::mail::imap::seq]
	set $var {}
	Cmd $sid [list [list t "UID SEARCH $criteria"]] [list ::mail::imap::SearchDone $var $cb] \
		-ondata [list ::mail::imap::SearchData $var]
}
proc ::mail::imap::SearchData {var ev} {
	upvar #0 $var r
	if {[dict get $ev type] ne "search"} { return 0 }
	lappend r {*}[dict get $ev uids]
	return 1
}
proc ::mail::imap::SearchDone {var cb status args} {
	upvar #0 $var r
	set res [lsort -integer -unique $r]
	unset r
	if {$status ne "ok"} { {*}$cb error {*}$args; return }
	{*}$cb ok $res
}

proc ::mail::imap::uid_fetch {sid set items cb {each ""} {modifiers ""}} {
	set m [expr {$modifiers eq "" ? "" : " ($modifiers)"}]
	Cmd $sid [list [list t "UID FETCH $set ($items)$m"]] [list ::mail::imap::Done $cb] \
		-ondata [list ::mail::imap::FetchData $each]
}
proc ::mail::imap::FetchData {each ev} {
	if {[dict get $ev type] ne "fetch"} { return 0 }
	set d [dict get $ev data]
	# a FETCH without UID is news the server sends unasked (another client changed flags): -onevent takes it
	if {![dict exists $d UID]} { return 0 }
	if {$each ne ""} { {*}$each $d }
	return 1
}
proc ::mail::imap::Done {cb status args} {
	if {$status ne "ok"} { {*}$cb error {*}$args; return }
	{*}$cb ok {}
}

proc ::mail::imap::uid_store {sid set op flags cb} {
	if {$op ni {+FLAGS.SILENT -FLAGS.SILENT FLAGS.SILENT}} { error "bad STORE operation $op" }
	Cmd $sid [list [list t "UID STORE $set $op ([join $flags " "])"]] [list ::mail::imap::Done $cb]
}

proc ::mail::imap::append_msg {sid box flags bytes cb} {
	Cmd $sid [list {t "APPEND "} [list a $box] [list t " ([join $flags " "]) "] [list l $bytes]] \
		[list ::mail::imap::AppendDone $cb]
}
proc ::mail::imap::AppendDone {cb status args} {
	if {$status ne "ok"} { {*}$cb error {*}$args; return }
	set r [lindex $args 0]
	set out {}
	if {[dict get $r code] eq "APPENDUID"} {
		lassign [dict get $r args] v u
		set out [dict create uidvalidity $v uid $u]
	}
	{*}$cb ok $out
}

proc ::mail::imap::uid_copy {sid set box cb} {
	set var ::mail::imap::copyuid[incr ::mail::imap::seq]
	set $var {}
	Cmd $sid [list [list t "UID COPY $set "] [list a $box]] [list ::mail::imap::CopyDone $var $cb] \
		-ondata [list ::mail::imap::CopyData $var]
}
proc ::mail::imap::uid_move {sid set box cb} {
	set var ::mail::imap::copyuid[incr ::mail::imap::seq]
	set $var {}
	Cmd $sid [list [list t "UID MOVE $set "] [list a $box]] [list ::mail::imap::CopyDone $var $cb] \
		-ondata [list ::mail::imap::CopyData $var]
}
# MOVE gives COPYUID in an untagged OK before its EXPUNGEs (RFC 6851 4.3); COPY in the tagged OK
proc ::mail::imap::CopyData {var ev} {
	if {[dict get $ev type] eq "code" && [string toupper [dict get $ev code]] eq "COPYUID"} {
		set $var [dict get $ev args]
		return 1
	}
	return 0
}
proc ::mail::imap::CopyDone {var cb status args} {
	upvar #0 $var got
	set code $got
	unset got
	if {$status ne "ok"} { {*}$cb error {*}$args; return }
	set r [lindex $args 0]
	if {[string toupper [dict get $r code]] eq "COPYUID"} { set code [dict get $r args] }
	set out {}
	if {[llength $code] == 3 && [string is digit -strict [lindex $code 0]]} {
		lassign $code v src dst
		set out [dict create uidvalidity $v src [UidSet $src] dst [UidSet $dst]]
	}
	{*}$cb ok $out
}
# a uid-set ("4,7:9") as its UIDs in order
proc ::mail::imap::UidSet {set} {
	set out {}
	foreach r [split $set ,] {
		if {[regexp {^(\d+):(\d+)$} $r -> a b]} {
			set step [expr {$a <= $b ? 1 : -1}]
			for {set u $a} {$u != $b + $step} {incr u $step} { lappend out $u }
		} elseif {[string is digit -strict $r]} { lappend out $r }
	}
	return $out
}
proc ::mail::imap::uid_expunge {sid set cb} {
	Cmd $sid [list [list t "UID EXPUNGE $set"]] [list ::mail::imap::Done $cb]
}
proc ::mail::imap::expunge {sid cb} {
	Cmd $sid {{t EXPUNGE}} [list ::mail::imap::Done $cb]
}

proc ::mail::imap::create {sid box cb} {
	Cmd $sid [list {t "CREATE "} [list a $box]] [list ::mail::imap::Done $cb]
}

proc ::mail::imap::noop {sid cb} {
	Cmd $sid {{t NOOP}} [list ::mail::imap::Done $cb]
}

proc ::mail::imap::idle {sid cb} {
	variable S
	Cmd $sid {{t IDLE}} [list ::mail::imap::Done $cb] -oncont [list ::mail::imap::Idling $sid]
}
proc ::mail::imap::Idling {sid text} {
	variable S
	dict set S($sid) idling 1
	# while idle, silence is normal
	Disarm $sid
	if {[dict get $S($sid) wantdone]} {
		dict set S($sid) wantdone 0
		done $sid
	}
}
proc ::mail::imap::done {sid} {
	variable S
	if {![info exists S($sid)]} return
	set cur [dict get $S($sid) cur]
	if {$cur eq "" || [dict get $cur parts] ne {{t IDLE}}} return
	if {![dict get $S($sid) idling]} {
		# the "+" has not come yet: DONE goes out as soon as it does
		dict set S($sid) wantdone 1
		return
	}
	dict set S($sid) idling 0
	Arm $sid
	Raw $sid "DONE\r\n"
}

proc ::mail::imap::logout {sid cb} {
	variable S
	if {![info exists S($sid)]} { after 0 [list {*}$cb ok {}]; return }
	dict set S($sid) closing 1
	Cmd $sid {{t LOGOUT}} [list ::mail::imap::LoggedOut $sid $cb]
}
proc ::mail::imap::LoggedOut {sid cb status args} {
	close $sid
	{*}$cb ok {}
}

# Test connection: connect, log in, log out
proc ::mail::imap::probe {opts cb} {
	open $opts [list ::mail::imap::Probed $cb]
}
proc ::mail::imap::Probed {cb status args} {
	if {$status ne "ok"} { {*}$cb error {*}$args; return }
	set sid [lindex $args 0]
	logout $sid [list ::mail::imap::ProbeEnd $cb]
}
proc ::mail::imap::ProbeEnd {cb args} { {*}$cb ok }

# ---- modified UTF-7 mailbox names (RFC 3501 5.1.3) -------------------------------------------------------------
proc ::mail::imap::utf7_encode {text} {
	set out ""
	set run ""
	foreach ch [split $text ""] {
		scan $ch %c code
		if {$code >= 0x20 && $code <= 0x7e} {
			if {$run ne ""} { append out [Utf7Run $run]; set run "" }
			append out [expr {$ch eq "&" ? "&-" : $ch}]
		} else {
			append run $ch
		}
	}
	if {$run ne ""} { append out [Utf7Run $run] }
	return $out
}
proc ::mail::imap::Utf7Run {run} {
	set b ""
	foreach ch [split $run ""] {
		scan $ch %c code
		if {$code > 0xffff} {
			set c [expr {$code - 0x10000}]
			append b [binary format SS [expr {0xd800 | ($c >> 10)}] [expr {0xdc00 | ($c & 0x3ff)}]]
		} else {
			append b [binary format S $code]
		}
	}
	return "&[string map {/ ,} [string trimright [binary encode base64 $b] =]]-"
}
proc ::mail::imap::utf7_decode {name} {
	set out ""
	while {[regexp -indices {&([A-Za-z0-9+,]*)-} $name all run]} {
		lassign $all a e
		lassign $run r1 r2
		append out [string range $name 0 $a-1]
		set chunk [string range $name $r1 $r2]
		if {$chunk eq ""} {
			append out &
		} else {
			set b64 [string map {, /} $chunk]
			while {[string length $b64] % 4} { append b64 = }
			if {[catch {binary decode base64 $b64} b]} {
				append out [string range $name $a $e]
			} else {
				binary scan $b Su* units
				set i 0
				while {$i < [llength $units]} {
					set u [lindex $units $i]
					if {$u >= 0xd800 && $u < 0xdc00 && $i + 1 < [llength $units]} {
						set l [lindex $units [incr i]]
						set u [expr {0x10000 + (($u - 0xd800) << 10) + ($l - 0xdc00)}]
					}
					append out [format %c $u]
					incr i
				}
			}
		}
		set name [string range $name $e+1 end]
	}
	append out $name
}
