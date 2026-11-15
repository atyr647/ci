# mail-fixture-server.tcl - a small IMAP4rev1 and SMTP submission server on 127.0.0.1 for Mail's sync tests
# (tests/mail-sync.tcl). It is written apart from apps/mail on purpose: it shares no code with the clients it tests.
#
#   tclsh8.6 tests/mail-fixture-server.tcl ?-cert FILE -key FILE? ?-user NAME -password PW? ?-caps "-IDLE +X"?
#
# It prints one line, "ports imap N imaps N smtp N smtps N" (imaps and smtps are 0 without -cert/-key or the tls
# package), and then reads control commands on stdin, one Tcl list a line, answering each with one line "R ...":
#
#   deliver BOX FLAGS B64          a new message (base64 bytes) in BOX; idle clients hear EXISTS     R uid
#   flags BOX UID FLAGS            set a message's flags; idle clients hear FETCH                     R ok
#   expunge BOX UID                remove a message; idle clients hear EXPUNGE                        R ok
#   (clients' UID COPY, UID MOVE (with +MOVE in -caps or caps), UID EXPUNGE (UIDPLUS) and EXPUNGE are served too;
#   COPYUID comes with UIDPLUS)
#   renumber BOX                   a new UIDVALIDITY and new UIDs from 1                               R uidvalidity
#   mailbox BOX ?SPECIALUSE?       create a mailbox                                                   R ok
#   dump BOX                       R {uid flags size} ...
#   body BOX UID                   R base64 bytes
#   sent                           what SMTP took: R {from rcpts b64} ...
#   log                            R the commands clients sent, one list item each (passwords hidden)
#   caps SPEC                      change what is offered, e.g. "-IDLE -AUTH=PLAIN +LOGINDISABLED"    R ok
#   trickle on|off                 plain connections: replies go out 7 bytes at a time (3001 in long runs)
#   slowread on|off                take what clients send 64 KB at a time, 25 ms apart (a slow uplink)
#   mute on|off                    IMAP commands are taken and never answered
#   inject on|off                  STARTTLS: send a stray line with the OK (an injection a client must refuse)
#   kick                           drop every connection                                               R ok
#   quit
#
# Mailboxes at the start: INBOX, Sent (\Sent), Drafts (\Drafts), Trash (\Trash), "Caf&AOk-" (Caf\u00e9, for the
# modified UTF-7 names). The user is maya@lind.page with the password "pa ss\"w\u00f6rd" unless -user/-password say.
# -smtpsize N sets SMTP's SIZE (200000); -nosent 1 leaves Sent out; -plainauth 1 offers SMTP AUTH without TLS (for plain loopback tests).
# SMTP refuses any recipient with "reject" in it and messages over 200000 bytes (SIZE 200000).

set opt [dict create -smtpsize 200000 -cert "" -key "" -user maya@lind.page -password "pa ss\"w\u00f6rd" -caps ""]
foreach {k v} $argv { dict set opt $k $v }
# a client that gives up mid-handshake is part of the tests: no messages for it
proc bgerror {args} {}
set tlsok [expr {[dict get $opt -cert] ne "" && ![catch {package require tls}]}]

set caps {IMAP4rev1 LITERAL+ SASL-IR AUTH=PLAIN IDLE UIDPLUS CONDSTORE SPECIAL-USE}
set inject 0
set trickle 0
set mute 0
set slowread 0
set modseq 1
set log {}
set sent {}
set boxes [dict create]
proc mkbox {name {use ""}} {
	global boxes
	dict set boxes $name [dict create uidvalidity [expr {1000 + [dict size $boxes] * 7 + int([clock seconds] % 1000)}] \
		uidnext 1 msgs {} use $use]
}
foreach {b u} {INBOX "" Sent \\Sent Drafts \\Drafts Trash \\Trash Caf&AOk- ""} {
	if {$b eq "Sent" && [dict exists $opt -nosent]} continue
	mkbox $b $u
}
proc applycaps {spec} {
	global caps
	foreach w $spec {
		set c [string range $w 1 end]
		if {[string index $w 0] eq "-"} { set caps [lsearch -all -inline -not -exact $caps $c] } else { lappend caps $c }
	}
}
applycaps [dict get $opt -caps]

# ---- connections: line + literal framing -----------------------------------------------------------------------
array set C {}
proc conn_new {s proto tls} {
	global C
	fconfigure $s -blocking 0 -translation binary -buffering none
	set C($s) [dict create proto $proto tls $tls state notauth box "" buf "" idle "" auth 0 data 0 mail "" rcpt {} lit 0 greeted 0]
	if {$tls} {
		dict set C($s) shaking 1
		fileevent $s readable [list shake $s]
	} else {
		greet $s
		fileevent $s readable [list readable $s]
	}
}
proc shake {s} {
	global C
	if {[catch {tls::handshake $s} r]} { drop $s; return }
	if {!$r} return
	dict set C($s) shaking 0
	if {![dict get $C($s) tls]} { dict set C($s) tls 1 }
	if {![dict get $C($s) greeted]} { greet $s }
	fileevent $s readable [list readable $s]
}
proc greet {s} {
	global C caps
	dict set C($s) greeted 1
	if {[dict get $C($s) proto] eq "imap"} {
		out $s "* OK \[CAPABILITY [capstr $s]\] fixture ready"
	} else {
		out $s "220 fixture.test ESMTP ready"
	}
}
proc out {s line} {
	global trickle C
	if {$trickle && [info exists C($s)] && ![dict get $C($s) tls]} {
		# a few bytes at a time, each in its own write: the client must put responses and literals together
		set q [expr {[dict exists $C($s) outq] ? [dict get $C($s) outq] : ""}]
		dict set C($s) outq "$q$line\r\n"
		if {$q eq ""} { after 1 [list drain $s] }
		return
	}
	if {[catch {puts -nonewline $s "$line\r\n"; flush $s}]} { drop $s }
}
proc drain {s} {
	global C
	if {![info exists C($s)]} return
	set q [dict get $C($s) outq]
	# 7 bytes at a time; a long run (a message body) in odd 3001-byte pieces, so that splits land anywhere
	set n [expr {[string length $q] > 512 ? 3001 : 7}]
	if {[catch {puts -nonewline $s [string range $q 0 [expr {$n - 1}]]; flush $s}]} { drop $s; return }
	dict set C($s) outq [string range $q $n end]
	if {[string length $q] > $n} { after 1 [list drain $s] }
}
proc drop {s} {
	global C
	catch {close $s}
	unset -nocomplain C($s)
}
proc readable {s} {
	global C
	if {![info exists C($s)]} return
	global slowread
	if {$slowread} {
		# a slow link: 64 KB, then nothing for 25 ms
		if {[catch {read $s 65536} d]} { drop $s; return }
		fileevent $s readable {}
		after 25 [list apply {{s} { if {[info exists ::C($s)]} { fileevent $s readable [list readable $s] } }} $s]
	} elseif {[catch {read $s} d]} { drop $s; return }
	if {[eof $s] && $d eq ""} { drop $s; return }
	dict append C($s) buf $d
	while {[info exists C($s)]} {
		set b [dict get $C($s) buf]
		if {[dict get $C($s) proto] eq "smtp" && [dict get $C($s) data]} {
			set e [string first "\r\n.\r\n" "\r\n$b"]
			if {$e < 0} break
			set body [string range $b 0 [expr {$e - 1}]]
			dict set C($s) buf [string range $b [expr {$e + 3}] end]
			dict set C($s) data 0
			smtp_data $s $body
			continue
		}
		# a line, and with IMAP the literals it announces
		set p 0
		set line ""
		set lits {}
		set ok 0
		while {1} {
			set e [string first "\r\n" $b $p]
			if {$e < 0} break
			set seg [string range $b $p [expr {$e - 1}]]
			if {[dict get $C($s) proto] eq "imap" && [regexp {\{(\d+)(\+?)\}$} $seg -> n plus]} {
				if {[string length $b] < $e + 2 + $n} {
					if {$plus eq "" && [dict get $C($s) lit] <= $e} {
						out $s "+ go ahead"
						dict set C($s) lit [expr {$e + 1}]
					}
					break
				}
				append line [regsub {\{\d+\+?\}$} $seg {}]
				lappend lits [string range $b [expr {$e + 2}] [expr {$e + 1 + $n}]]
				append line "\x01[expr {[llength $lits] - 1}]\x01"
				set p [expr {$e + 2 + $n}]
				continue
			}
			append line $seg
			set p [expr {$e + 2}]
			set ok 1
			break
		}
		if {!$ok} break
		dict set C($s) buf [string range $b $p end]
		dict set C($s) lit 0
		if {[dict get $C($s) proto] eq "imap"} { imap_line $s $line $lits } else { smtp_line $s $line }
	}
	if {[info exists C($s)] && [eof $s]} { drop $s }
}

# ---- IMAP --------------------------------------------------------------------------------------------------------
proc capstr {s} {
	global C caps tlsok
	set l {}
	foreach c $caps {
		if {[dict get $C($s) tls] && $c eq "STARTTLS"} continue
		lappend l $c
	}
	if {!$tlsok || [dict get $C($s) tls]} { set l [lsearch -all -inline -not -exact $l STARTTLS] } elseif {"STARTTLS" ni $l} { lappend l STARTTLS }
	if {[dict get $C($s) auth]} { set l [lsearch -all -inline -not -glob $l AUTH=*] }
	join $l " "
}
# a client's arguments: atoms, quoted strings, literals (\x01N\x01) and (lists)
proc args_of {str lits} {
	set out {}
	set stack {}
	set i 0
	set n [string length $str]
	while {$i < $n} {
		set c [string index $str $i]
		if {$c eq " "} { incr i; continue }
		if {$c eq "("} { lappend stack $out; set out {}; incr i; continue }
		if {$c eq ")"} { set in $out; set out [lindex $stack end]; set stack [lrange $stack 0 end-1]; lappend out $in; incr i; continue }
		if {$c eq "\""} {
			set v ""
			incr i
			while {$i < $n} {
				set c [string index $str $i]
				if {$c eq "\\"} { incr i; append v [string index $str $i]; incr i; continue }
				if {$c eq "\""} { incr i; break }
				append v $c
				incr i
			}
			lappend out $v
			continue
		}
		if {$c eq "\x01"} {
			set e [string first "\x01" $str [expr {$i + 1}]]
			lappend out [lindex $lits [string range $str [expr {$i + 1}] [expr {$e - 1}]]]
			set i [expr {$e + 1}]
			continue
		}
		set j $i
		while {$j < $n && [string index $str $j] ni {" " ( )}} {
			if {[string index $str $j] eq "\["} { set j [string first "\]" $str $j] }
			incr j
		}
		lappend out [string range $str $i [expr {$j - 1}]]
		set i $j
	}
	return $out
}
proc imap_line {s line lits} {
	global C log opt caps inject boxes mute
	# a server that has stopped answering (a dead route): commands are taken and never answered
	if {$mute} { lappend log "MUTED $line"; return }
	if {[dict get $C($s) idle] ne ""} {
		if {[string toupper $line] eq "DONE"} {
			lappend log DONE
			out $s "[dict get $C($s) idle] OK IDLE done"
			dict set C($s) idle ""
		} else {
			out $s "* BAD expected DONE"
		}
		return
	}
	if {[dict exists $C($s) sasl]} {
		set tag [dict get $C($s) sasl]
		dict unset C($s) sasl
		if {$line eq "*"} { out $s "$tag BAD cancelled"; return }
		auth_plain $s $tag $line
		return
	}
	set sp [string first " " $line]
	set tag [string range $line 0 [expr {$sp - 1}]]
	set rest [string range $line [expr {$sp + 1}] end]
	regexp {^(\S+)\s*(.*)$} $rest -> verb argstr
	set verb [string toupper $verb]
	if {$verb eq "UID"} {
		regexp {^(\S+)\s*(.*)$} $argstr -> v2 argstr
		set verb "UID [string toupper $v2]"
	}
	lappend log [expr {$verb in {LOGIN AUTHENTICATE} ? "$verb [lindex [args_of $argstr $lits] 0]" : "$verb $argstr"}]
	set a [args_of $argstr $lits]
	set st [dict get $C($s) state]
	switch -- $verb {
		CAPABILITY { out $s "* CAPABILITY [capstr $s]"; out $s "$tag OK done" }
		NOOP { out $s "$tag OK done" }
		LOGOUT { out $s "* BYE bye"; out $s "$tag OK done"; drop $s }
		STARTTLS {
			if {[dict get $C($s) tls] || "STARTTLS" ni [split [capstr $s]]} { out $s "$tag BAD no"; return }
			if {$inject} {
				puts -nonewline $s "$tag OK begin TLS\r\n* OK injected\r\n"; flush $s
			} else {
				out $s "$tag OK begin TLS"
			}
			fileevent $s readable {}
			tls::import $s -server 1 -certfile [dict get $opt -cert] -keyfile [dict get $opt -key]
			fconfigure $s -blocking 0 -translation binary -buffering none
			dict set C($s) tls 1
			dict set C($s) shaking 1
			fileevent $s readable [list shake $s]
		}
		LOGIN {
			if {"LOGINDISABLED" in $caps} { out $s "$tag NO \[PRIVACYREQUIRED\] LOGIN is disabled"; return }
			lassign $a u p
			login $s $tag [encoding convertfrom utf-8 $u] [encoding convertfrom utf-8 $p]
		}
		AUTHENTICATE {
			if {[string toupper [lindex $a 0]] ne "PLAIN" || "AUTH=PLAIN" ni $caps} { out $s "$tag NO no such mechanism"; return }
			if {[llength $a] > 1} {
				if {"SASL-IR" ni $caps} { out $s "$tag BAD no SASL-IR"; return }
				auth_plain $s $tag [lindex $a 1]
			} else {
				dict set C($s) sasl $tag
				out $s "+ "
			}
		}
		default {
			if {$st eq "notauth"} { out $s "$tag BAD log in first"; return }
			imap_auth_cmd $s $tag $verb $a $argstr
		}
	}
}
proc auth_plain {s tag b64} {
	if {[catch {binary decode base64 $b64} raw]} { out $s "$tag BAD bad base64"; return }
	lassign [split $raw \0] z u p
	login $s $tag [encoding convertfrom utf-8 $u] [encoding convertfrom utf-8 $p]
}
proc login {s tag u p} {
	global C opt
	if {$u ne [dict get $opt -user] || $p ne [dict get $opt -password]} {
		out $s "$tag NO \[AUTHENTICATIONFAILED\] Invalid credentials"
		return
	}
	dict set C($s) state auth
	dict set C($s) auth 1
	out $s "$tag OK \[CAPABILITY [capstr $s]\] logged in"
}
proc uidset {spec box} {
	global boxes
	set uids [lmap m [dict get $boxes $box msgs] {dict get $m uid}]
	set max [expr {[llength $uids] ? [lindex $uids end] : 0}]
	set out {}
	foreach r [split $spec ,] {
		if {[regexp {^(\d+|\*):(\d+|\*)$} $r -> x y]} {
			if {$x eq "*"} { set x $max }
			if {$y eq "*"} { set y $max }
			if {$x > $y} { lassign [list $x $y] y x }
		} elseif {$r eq "*"} { set x $max ; set y $max } else { set x $r ; set y $r }
		foreach u $uids { if {$u >= $x && $u <= $y && $u ni $out} { lappend out $u } }
	}
	lsort -integer $out
}
proc seqno {box uid} {
	global boxes
	set i 0
	foreach m [dict get $boxes $box msgs] { incr i; if {[dict get $m uid] == $uid} { return $i } }
	return 0
}
proc msg {box uid} {
	global boxes
	foreach m [dict get $boxes $box msgs] { if {[dict get $m uid] == $uid} { return $m } }
	return ""
}
proc setmsg {box uid key val} {
	global boxes
	set l {}
	foreach m [dict get $boxes $box msgs] {
		if {[dict get $m uid] == $uid} { dict set m $key $val }
		lappend l $m
	}
	dict set boxes $box msgs $l
}
proc lit {bytes} { return "{[string length $bytes]}\r\n$bytes" }
proc imap_auth_cmd {s tag verb a argstr} {
	global C boxes modseq caps
	switch -- $verb {
		LIST {
			foreach b [dict keys $boxes] {
				set f [expr {[dict get $boxes $b use] ne "" && "SPECIAL-USE" in $caps ? "\\HasNoChildren [dict get $boxes $b use]" : "\\HasNoChildren"}]
				out $s "* LIST ($f) \"/\" \"$b\""
			}
			out $s "* LIST (\\Noselect \\HasChildren) \"/\" \"\[Folders\]\""
			out $s "$tag OK done"
		}
		CREATE {
			set b [lindex $a 0]
			if {[dict exists $boxes $b]} { out $s "$tag NO exists"; return }
			mkbox $b
			out $s "$tag OK created"
		}
		SELECT - EXAMINE {
			set b [lindex $a 0]
			if {$b eq "\[Folders\]" || ![dict exists $boxes $b]} { out $s "$tag NO no such mailbox"; return }
			dict set C($s) state selected
			dict set C($s) box $b
			dict set C($s) condstore [expr {[string toupper [lindex $a 1]] eq "CONDSTORE"}]
			set bx [dict get $boxes $b]
			out $s "* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)"
			out $s "* [llength [dict get $bx msgs]] EXISTS"
			out $s "* 0 RECENT"
			out $s "* OK \[PERMANENTFLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft \\*)\] ok"
			out $s "* OK \[UIDVALIDITY [dict get $bx uidvalidity]\] ok"
			out $s "* OK \[UIDNEXT [dict get $bx uidnext]\] ok"
			if {"CONDSTORE" in $caps} { out $s "* OK \[HIGHESTMODSEQ $modseq\] ok" }
			out $s "$tag OK \[[expr {$verb eq "EXAMINE" ? "READ-ONLY" : "READ-WRITE"}]\] selected"
		}
		IDLE {
			if {"IDLE" ni $caps} { out $s "$tag BAD no IDLE"; return }
			dict set C($s) idle $tag
			out $s "+ idling"
		}
		APPEND {
			set b [lindex $a 0]
			if {![dict exists $boxes $b]} { out $s "$tag NO \[TRYCREATE\] no such mailbox"; return }
			set flags [expr {[llength $a] > 2 ? [lindex $a 1] : {}}]
			set uid [deliver $b $flags [lindex $a end]]
			out $s "$tag OK [expr {"UIDPLUS" in $caps ? "\[APPENDUID [dict get $boxes $b uidvalidity] $uid\] " : ""}]appended"
		}
		default {
			if {[dict get $C($s) state] ne "selected"} { out $s "$tag BAD select first"; return }
			set b [dict get $C($s) box]
			switch -- $verb {
				"UID SEARCH" {
					set crit [string toupper $argstr]
					if {[regexp {^UID (\S+)$} $crit -> set]} { set uids [uidset $set $b] } else { set uids [uidset 1:* $b] }
					out $s "* SEARCH[join [lmap u $uids {string cat " " $u}] ""]"
					out $s "$tag OK done"
				}
				"UID FETCH" {
					set set [lindex $a 0]
					set items [string toupper [lindex $a 1]]
					set since ""
					if {[llength $a] > 2 && [string toupper [lindex $a 2 0]] eq "CHANGEDSINCE"} { set since [lindex $a 2 1] }
					foreach uid [uidset $set $b] {
						set m [msg $b $uid]
						if {$since ne "" && [dict get $m modseq] <= $since} continue
						set parts [list UID $uid]
						foreach it $items {
							switch -- $it {
								UID {}
								FLAGS { lappend parts "FLAGS ([join [dict get $m flags] " "])" }
								RFC822.SIZE { lappend parts "RFC822.SIZE [string length [dict get $m bytes]]" }
								INTERNALDATE { lappend parts "INTERNALDATE \"[clock format [dict get $m date] -format {%d-%b-%Y %H:%M:%S +0000} -gmt 1]\"" }
								MODSEQ { lappend parts "MODSEQ ([dict get $m modseq])" }
								BODY.PEEK\[\] { lappend parts "BODY\[\] [lit [dict get $m bytes]]" }
								BODY\[\] {
									lappend parts "BODY\[\] [lit [dict get $m bytes]]"
									if {"\\Seen" ni [dict get $m flags]} { setmsg $b $uid flags [linsert [dict get $m flags] end \\Seen] }
								}
							}
						}
						if {$since ne "" && "MODSEQ" ni $items} { lappend parts "MODSEQ ([dict get $m modseq])" }
						out $s "* [seqno $b $uid] FETCH ([join $parts " "])"
					}
					out $s "$tag OK done"
				}
				"UID STORE" {
					lassign $a set op flags
					set op [string toupper $op]
					incr modseq
					foreach uid [uidset $set $b] {
						set f [dict get [msg $b $uid] flags]
						switch -glob -- $op {
							+FLAGS* { foreach x $flags { if {$x ni $f} { lappend f $x } } }
							-FLAGS* { set f [lmap x $f { if {$x in $flags} continue; set x }] }
							FLAGS* { set f $flags }
						}
						setmsg $b $uid flags $f
						setmsg $b $uid modseq $modseq
						if {![string match *.SILENT $op]} { out $s "* [seqno $b $uid] FETCH (UID $uid FLAGS ([join $f " "]))" }
						notify $b $s "* [seqno $b $uid] FETCH (FLAGS ([join $f " "]))"
					}
					out $s "$tag OK stored"
				}
				"UID COPY" - "UID MOVE" {
					lassign $a set to
					if {$verb eq "UID MOVE" && "MOVE" ni $caps} { out $s "$tag BAD unknown command"; return }
					if {![dict exists $boxes $to]} { out $s "$tag NO \[TRYCREATE\] no such mailbox"; return }
					set src {}
					set dst {}
					foreach uid [uidset $set $b] {
						set m [msg $b $uid]
						lappend src $uid
						lappend dst [deliver $to [lsearch -all -inline -not -exact [dict get $m flags] \\Recent] [dict get $m bytes]]
					}
					set code [expr {"UIDPLUS" in $caps && [llength $src] ?
						"\[COPYUID [dict get $boxes $to uidvalidity] [join $src ,] [join $dst ,]\] " : ""}]
					if {$verb eq "UID COPY"} { out $s "$tag OK ${code}copied"; return }
					if {$code ne ""} { out $s "* OK ${code}moved" }
					foreach uid $src { expunge_uid $b $uid $s }
					out $s "$tag OK moved"
				}
				"UID EXPUNGE" - EXPUNGE {
					if {$verb eq "UID EXPUNGE" && "UIDPLUS" ni $caps} { out $s "$tag BAD unknown command"; return }
					set only [expr {$verb eq "UID EXPUNGE" ? [uidset [lindex $a 0] $b] : ""}]
					foreach m [dict get $boxes $b msgs] {
						if {"\\Deleted" ni [dict get $m flags]} continue
						if {$verb eq "UID EXPUNGE" && [dict get $m uid] ni $only} continue
						expunge_uid $b [dict get $m uid] $s
					}
					out $s "$tag OK expunged"
				}
				CLOSE { dict set C($s) state auth; out $s "$tag OK closed" }
				default { out $s "$tag BAD unknown command" }
			}
		}
	}
}
# a message leaves BOX: the client S that removed it hears EXPUNGE, and so does every other client there
proc expunge_uid {box uid s} {
	global boxes
	set n [seqno $box $uid]
	if {!$n} return
	set l {}
	foreach m [dict get $boxes $box msgs] { if {[dict get $m uid] != $uid} { lappend l $m } }
	dict set boxes $box msgs $l
	out $s "* $n EXPUNGE"
	notify $box $s "* $n EXPUNGE"
}
# tell every other client that has BOX selected
proc notify {box except line} {
	global C
	foreach s [array names C] {
		if {$s eq $except || [dict get $C($s) proto] ne "imap" || [dict get $C($s) box] ne $box} continue
		if {[dict get $C($s) state] ne "selected"} continue
		out $s $line
	}
}
proc deliver {box flags bytes} {
	global boxes modseq
	set uid [dict get $boxes $box uidnext]
	dict set boxes $box uidnext [expr {$uid + 1}]
	incr modseq
	set l [dict get $boxes $box msgs]
	lappend l [dict create uid $uid flags $flags bytes $bytes date [clock seconds] modseq $modseq]
	dict set boxes $box msgs $l
	notify $box "" "* [llength [dict get $boxes $box msgs]] EXISTS"
	return $uid
}

# ---- SMTP ---------------------------------------------------------------------------------------------------------
proc smtp_line {s line} {
	global C log opt sent tlsok inject
	if {[dict exists $C($s) smtpauth]} {
		smtp_auth_step $s $line
		return
	}
	regexp {^(\S+)\s*(.*)$} $line -> verb arg
	set verb [string toupper $verb]
	lappend log "SMTP $verb[expr {$verb eq "AUTH" ? " [lindex $arg 0]" : " $arg"}]"
	switch -- $verb {
		EHLO {
			dict set C($s) ehlo 1
			set l [list "250-fixture.test hello $arg" "250-SIZE [dict get $opt -smtpsize]" "250-8BITMIME"]
			if {$tlsok && ![dict get $C($s) tls]} { lappend l "250-STARTTLS" }
			if {[dict get $C($s) tls] || [dict exists $opt -plainauth]} { lappend l "250-AUTH PLAIN LOGIN" }
			lappend l "250 ENHANCEDSTATUSCODES"
			foreach x $l { out $s $x }
		}
		STARTTLS {
			if {[dict get $C($s) tls] || !$tlsok} { out $s "503 no"; return }
			if {$inject} { puts -nonewline $s "220 go ahead\r\n250 injected\r\n"; flush $s } else { out $s "220 go ahead" }
			fileevent $s readable {}
			tls::import $s -server 1 -certfile [dict get $opt -cert] -keyfile [dict get $opt -key]
			fconfigure $s -blocking 0 -translation binary -buffering none
			dict set C($s) tls 1
			dict set C($s) ehlo 0
			fileevent $s readable [list shake $s]
		}
		AUTH {
			if {![dict get $C($s) tls] && ![dict exists $opt -plainauth]} { out $s "538 5.7.11 encryption required"; return }
			set mech [string toupper [lindex $arg 0]]
			if {$mech eq "PLAIN"} {
				if {[llength $arg] > 1} { smtp_plain $s [lindex $arg 1] } else { dict set C($s) smtpauth plain; out $s "334 " }
			} elseif {$mech eq "LOGIN"} {
				dict set C($s) smtpauth login-user
				out $s "334 [binary encode base64 Username:]"
			} else { out $s "504 no such mechanism" }
		}
		MAIL {
			if {![dict get $C($s) auth]} { out $s "530 5.7.0 authentication required"; return }
			if {![regexp -nocase {^FROM:<([^>]*)>(.*)$} $arg -> from params]} { out $s "501 syntax"; return }
			if {[regexp -nocase {SIZE=(\d+)} $params -> sz] && $sz > [dict get $opt -smtpsize]} { out $s "552 5.3.4 message too big"; return }
			dict set C($s) mail $from
			dict set C($s) rcpt {}
			out $s "250 2.1.0 ok"
		}
		RCPT {
			if {![regexp -nocase {^TO:<([^>]*)>} $arg -> to]} { out $s "501 syntax"; return }
			if {[string match *reject* $to]} { out $s "550 5.1.1 <$to> no such user"; return }
			dict lappend C($s) rcpt $to
			out $s "250 2.1.5 ok"
		}
		DATA {
			if {![llength [dict get $C($s) rcpt]]} { out $s "503 no recipients"; return }
			dict set C($s) data 1
			out $s "354 go ahead"
		}
		RSET { dict set C($s) rcpt {}; dict set C($s) mail ""; out $s "250 ok" }
		NOOP { out $s "250 ok" }
		QUIT { out $s "221 bye"; drop $s }
		default { out $s "502 unknown" }
	}
}
proc smtp_auth_step {s line} {
	global C
	set step [dict get $C($s) smtpauth]
	dict unset C($s) smtpauth
	if {$line eq "*"} { out $s "501 cancelled"; return }
	switch -- $step {
		plain { smtp_plain $s $line }
		login-user {
			dict set C($s) loginuser [binary decode base64 $line]
			dict set C($s) smtpauth login-pass
			out $s "334 [binary encode base64 Password:]"
		}
		login-pass { smtp_check $s [dict get $C($s) loginuser] [binary decode base64 $line] }
	}
}
proc smtp_plain {s b64} {
	lassign [split [binary decode base64 $b64] \0] z u p
	smtp_check $s $u $p
}
proc smtp_check {s u p} {
	global C opt
	if {[encoding convertfrom utf-8 $u] ne [dict get $opt -user] || [encoding convertfrom utf-8 $p] ne [dict get $opt -password]} {
		out $s "535 5.7.8 authentication failed"
		return
	}
	dict set C($s) auth 1
	out $s "235 2.7.0 ok"
}
proc smtp_data {s body} {
	global C sent opt
	# undo dot-stuffing
	set lines [split $body \n]
	set un {}
	foreach l $lines { lappend un [expr {[string index $l 0] eq "." ? [string range $l 1 end] : $l}] }
	set body [join $un \n]
	if {[string length $body] > [dict get $opt -smtpsize]} { out $s "552 too big"; return }
	lappend sent [list [dict get $C($s) mail] [dict get $C($s) rcpt] [binary encode base64 $body]]
	out $s "250 2.0.0 queued"
}

# ---- listeners and the control channel ------------------------------------------------------------------------------
proc accept {proto tls s addr port} { conn_new $s $proto $tls }
set L1 [socket -server [list accept imap 0] -myaddr 127.0.0.1 0]
set L2 [socket -server [list accept smtp 0] -myaddr 127.0.0.1 0]
set p3 0
set p4 0
if {$tlsok} {
	set L3 [tls::socket -server [list accept imap 1] -certfile [dict get $opt -cert] -keyfile [dict get $opt -key] -myaddr 127.0.0.1 0]
	set L4 [tls::socket -server [list accept smtp 1] -certfile [dict get $opt -cert] -keyfile [dict get $opt -key] -myaddr 127.0.0.1 0]
	set p3 [lindex [fconfigure $L3 -sockname] 2]
	set p4 [lindex [fconfigure $L4 -sockname] 2]
}
puts "ports imap [lindex [fconfigure $L1 -sockname] 2] imaps $p3 smtp [lindex [fconfigure $L2 -sockname] 2] smtps $p4"
flush stdout

proc control {} {
	global boxes log sent caps inject trickle mute slowread C
	if {[gets stdin line] < 0} { if {[eof stdin]} { exit 0 }; return }
	set cmd [lindex $line 0]
	set r ok
	switch -- $cmd {
		deliver { set r [deliver [lindex $line 1] [lindex $line 2] [binary decode base64 [lindex $line 3]]] }
		flags {
			lassign $line - b uid f
			global modseq
			incr modseq
			setmsg $b $uid flags $f
			setmsg $b $uid modseq $modseq
			notify $b "" "* [seqno $b $uid] FETCH (FLAGS ([join $f " "]))"
		}
		expunge {
			lassign $line - b uid
			set n [seqno $b $uid]
			set l {}
			foreach m [dict get $boxes $b msgs] { if {[dict get $m uid] != $uid} { lappend l $m } }
			dict set boxes $b msgs $l
			if {$n} { notify $b "" "* $n EXPUNGE" }
		}
		renumber {
			set b [lindex $line 1]
			set i 0
			set l {}
			foreach m [dict get $boxes $b msgs] { dict set m uid [incr i]; lappend l $m }
			dict set boxes $b msgs $l
			dict set boxes $b uidnext [expr {$i + 1}]
			dict set boxes $b uidvalidity [expr {[dict get $boxes $b uidvalidity] + 1}]
			set r [dict get $boxes $b uidvalidity]
		}
		mailbox { mkbox [lindex $line 1] [lindex $line 2] }
		dump { set r [lmap m [dict get $boxes [lindex $line 1] msgs] {list [dict get $m uid] [dict get $m flags] [string length [dict get $m bytes]]}] }
		body { set r [binary encode base64 [dict get [msg [lindex $line 1] [lindex $line 2]] bytes]] }
		sent { set r $sent }
		log { set r $log }
		caps { applycaps [lrange $line 1 end] }
		inject { set inject [expr {[lindex $line 1] eq "on"}] }
		trickle { set trickle [expr {[lindex $line 1] eq "on"}] }
		mute { set mute [expr {[lindex $line 1] eq "on"}] }
		slowread { set slowread [expr {[lindex $line 1] eq "on"}] }
		kick { foreach s [array names C] { drop $s } }
		quit { exit 0 }
		default { set r "unknown"}
	}
	puts "R $r"
	flush stdout
}
fconfigure stdin -blocking 0 -translation lf -encoding utf-8
fconfigure stdout -translation lf -encoding utf-8
fileevent stdin readable control
vwait forever
