# mail-sync.tcl - Mail's IMAP and SMTP clients and the account sync (apps/mail/{net,imap,smtp,sync}.tcl) against
# tests/mail-fixture-server.tcl on 127.0.0.1, with a stand-in for the mail store. Run by tests/steps.d/64-mail-sync.sh
# with tclsh8.6; exits 1 on a failure.
#
# MAIL_TEST_CERTS (a directory with good.pem/good.key for localhost and 127.0.0.1, and other.pem/other.key for
# other.test only) turns on the TLS checks; they also need the tls package. Without either they print skip.
set here [file dirname [file normalize [info script]]]
set app [file join $here .. srcpkgs ribbon-desktop files apps mail]
source [file join $app sync.tcl]
set fixture [file join $here mail-fixture-server.tcl]
set tclsh [info nameofexecutable]
set certs [expr {[info exists ::env(MAIL_TEST_CERTS)] ? $::env(MAIL_TEST_CERTS) : ""}]
set tls [expr {$certs ne "" && [file exists [file join $certs good.pem]] && ![catch {package require tls}]}]
set PW "pa ss\"w\u00f6rd"
set USER maya@lind.page

set fails 0
proc ok {name cond} {
	global fails
	if {$cond} { puts "  ok   $name" } else { puts "  FAIL $name"; incr fails }
}
proc skip {name} { puts "  skip $name" }

# wait (running the event loop) until the condition holds or MS pass; returns the condition's value
proc until {cond {ms 8000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 [list expr $cond]]} {
		if {[clock milliseconds] > $end} { return 0 }
		after 10 {set ::tick_ [clock milliseconds]}
		vwait ::tick_
	}
	return 1
}
# call a client API with a callback and wait for its answer
proc call {args} {
	set ::answer ""
	{*}$args [list apply {{args} {set ::answer $args}}]
	until {$::answer ne ""} 15000
	return $::answer
}

# ---- fixture servers ----------------------------------------------------------------------------------------------
set servers {}
proc server {args} {
	global fixture tclsh servers
	set f [open [list | $tclsh $fixture {*}$args 2>@stderr] r+]
	fconfigure $f -translation lf -encoding utf-8 -buffering line
	gets $f line
	lappend servers $f
	return [dict create chan $f {*}[lrange $line 1 end]]
}
proc ctl {srv args} {
	set f [dict get $srv chan]
	puts $f $args
	# the answer is read with the event loop running, so that the clients in this process keep working
	set ::ctl_ ""
	fileevent $f readable [list apply {{f} { set ::ctl_ [gets $f] }} $f]
	until {$::ctl_ ne ""} 10000
	fileevent $f readable {}
	return [string range $::ctl_ 2 end]
}
proc b64 {s} { binary encode base64 $s }

# a message in bytes, CRLF line ends
proc msg {n {extra ""}} {
	return "From: Anna Berg <anna@hearth.studio>\r\nTo: maya@lind.page\r\nSubject: Message $n\r\nMessage-ID: <m$n@hearth.studio>\r\n\r\nBody of $n.\r\n$extra"
}

# ---- the stand-in store --------------------------------------------------------------------------------------------
namespace eval st {
	variable F ; array set F {}       ;# acct,folder -> {display role delim}
	variable M ; array set M {}       ;# acct,folder -> dict uid -> {flags date bytes}
	variable T ; array set T {}       ;# acct,folder -> state dict
	variable P ; array set P {}       ;# acct,folder -> pending list
	variable calls {}
}
proc st::store {method acct args} {
	variable F; variable M; variable T; variable P; variable calls
	lappend calls [list $method {*}[lrange $args 0 1]]
	set k "$acct,[lindex $args 0]"
	switch -- $method {
		folders { return [lmap x [array names F $acct,*] {string range $x [string length $acct,] end}] }
		folder { set F($k) [lrange $args 1 end]; if {![info exists M($k)]} { set M($k) {} } }
		drop { unset -nocomplain F($k) M($k) T($k) }
		state { return [expr {[info exists T($k)] ? $T($k) : {}}] }
		setstate { set T($k) [lindex $args 1] }
		reset { set M($k) {}; set T($k) {} }
		uids {
			set out {}
			if {[info exists M($k)]} { dict for {u m} $M($k) { dict set out $u [dict get $m flags] } }
			return $out
		}
		deliver { lassign $args f u fl d b; dict set M($k) $u [dict create flags $fl date $d bytes $b] }
		flags { lassign $args f u fl; dict set M($k) $u flags $fl }
		expunge { dict unset M($k) [lindex $args 1] }
		pending { return [expr {[info exists P($k)] ? $P($k) : {}}] }
		pushed {
			set u [lindex $args 1]
			set P($k) [lmap p $P($k) { if {[lindex $p 0] == $u} continue; set p }]
		}
	}
	return ""
}
proc st::count {acct f} {
	variable M
	expr {[info exists M($acct,$f)] ? [dict size $M($acct,$f)] : 0}
}
proc st::bytes {acct f uid} {
	variable M
	if {![info exists M($acct,$f)] || ![dict exists $M($acct,$f) $uid]} { return "" }
	dict get $M($acct,$f) $uid bytes
}
proc st::flagsof {acct f uid} {
	variable M
	if {![info exists M($acct,$f)] || ![dict exists $M($acct,$f) $uid]} { return "-" }
	lsort [dict get $M($acct,$f) $uid flags]
}

set statuses {}
proc onstatus {acct s} { lappend ::statuses [list $acct $s] }
proc state {acct} { dict get [mail::sync::status $acct] state }
proc logof {srv} { ctl $srv log }
proc count_in {list pattern} { llength [lsearch -all -glob $list $pattern] }

puts "-- units"
# ---- modified UTF-7 ------------------------------------------------------------------------------------------------
ok "utf7: Caf\u00e9 is Caf&AOk-" [expr {[mail::imap::utf7_encode "Caf\u00e9"] eq "Caf&AOk-"}]
ok "utf7: & is &-" [expr {[mail::imap::utf7_encode "R&D"] eq "R&-D" && [mail::imap::utf7_decode "R&-D"] eq "R&D"}]
set rfc "~peter/mail/\u53f0\u5317/\u65e5\u672c\u8a9e"
ok "utf7: RFC 3501's example both ways" [expr {[mail::imap::utf7_encode $rfc] eq "~peter/mail/&U,BTFw-/&ZeVnLIqe-" &&
	[mail::imap::utf7_decode "~peter/mail/&U,BTFw-/&ZeVnLIqe-"] eq $rfc}]
set emoji "Trips \U1F682"
ok "utf7: a character outside the BMP round-trips (surrogates)" [expr {[mail::imap::utf7_decode [mail::imap::utf7_encode $emoji]] eq $emoji}]

# ---- the response tokenizer ------------------------------------------------------------------------------------------
set lit "a (b) \"c\r\n{3}\r\n"
set p [mail::imap::parse "(UID 7 FLAGS (\\Seen \$Label) BODY\[HEADER.FIELDS (DATE FROM)\] {[string length $lit]}\r\n$lit INTERNALDATE \"1-Nov-2026 10:00:00 +0000\" X NIL Q \"a\\\"b\\\\c\")"]
set d [mail::imap::FetchDict [lindex $p 0]]
ok "parse: a literal keeps its bytes (parentheses, quotes, CRLF inside)" [expr {[dict get $d {BODY[HEADER.FIELDS (DATE FROM)]}] eq $lit}]
ok "parse: flags as a list, NIL as empty, quoted escapes" [expr {[dict get $d FLAGS] eq [list \\Seen \$Label] && [dict get $d X] eq "" && [dict get $d Q] eq "a\"b\\c"}]
ok "parse: atoms and quoted strings" [expr {[dict get $d UID] == 7 && [dict get $d INTERNALDATE] eq "1-Nov-2026 10:00:00 +0000"}]

# ---- astrings ---------------------------------------------------------------------------------------------------------
ok "astring: an atom stays bare" [expr {[mail::imap::Astring maya@lind.page] eq "maya@lind.page"}]
ok "astring: space, quote and backslash are quoted" [expr {[mail::imap::Astring "a b\"c\\"] eq "\"a b\\\"c\\\\\""}]
ok "astring: 8-bit bytes and line ends need a literal" [expr {[mail::imap::Astring "w\xc3\xb6"] eq "" && [mail::imap::Astring "a\r\nb"] eq ""}]

# ---- certificate names ------------------------------------------------------------------------------------------------
set names {{dns mail.lind.page} {dns *.lind.page} {ip 127.0.0.1} {ip 2001:db8:0:0:0:0:0:1}}
ok "host: an exact name matches" [mail::net::host_matches mail.lind.page $names]
ok "host: case and a trailing dot do not matter" [mail::net::host_matches MAIL.Lind.Page. $names]
ok "host: *.lind.page covers one label" [mail::net::host_matches imap.lind.page $names]
ok "host: *.lind.page does not cover two labels or lind.page itself" [expr {![mail::net::host_matches a.b.lind.page $names] && ![mail::net::host_matches lind.page $names]}]
ok "host: a wildcard over a public suffix (*.page) matches nothing" [expr {![mail::net::host_matches lind.page {{dns *.page}}]}]
ok "host: an address matches an IP entry, not a DNS one" [expr {[mail::net::host_matches 127.0.0.1 $names] && ![mail::net::host_matches 127.0.0.1 {{dns 127.0.0.1}}]}]
ok "host: IPv6 spellings compare equal" [mail::net::host_matches 2001:db8::1 $names]
ok "host: another name does not match" [expr {![mail::net::host_matches evil.example $names]}]
if {$tls} {
	set fh [open [file join $certs good.pem]]; set pem [read $fh]; close $fh
	ok "cert: subjectAltName read from the DER" [expr {[mail::net::cert_names $pem] eq {{dns localhost} {ip 127.0.0.1}}}]
} else { skip "cert: subjectAltName read from the DER (no certificates or tls)" }

# ---- SMTP payload --------------------------------------------------------------------------------------------------
set w [mail::smtp::wire "A\n.hidden\r\n..two\rlast"]
ok "smtp: CRLF line ends, dot-stuffing, the end line" [expr {$w eq "A\r\n..hidden\r\n...two\r\nlast\r\n.\r\n"}]
set m "From: a@b\r\nBcc: x@y,\r\n z@w\r\nTo: c@d\r\n\r\nBcc: in the body stays\r\n"
ok "smtp: Bcc (folded too) is left out of what is sent, not out of the body" [expr {[mail::smtp::without_bcc $m] eq "From: a@b\r\nTo: c@d\r\n\r\nBcc: in the body stays\r\n"}]

# ---- the event loop is never blocked: a ticker runs through everything below -------------------------------------
set ticks 0
proc ticker {} { incr ::ticks; after 5 ticker }
ticker

puts "-- IMAP sessions (plain, loopback)"
set s1 [server -plainauth 1]
set P1 [dict get $s1 imap]
proc iopts {port args} { dict merge [list -host 127.0.0.1 -port $port -security none -user $::USER -password $::PW] $args }
set r [call mail::imap::probe [iopts $P1]]
ok "probe: AUTHENTICATE PLAIN with the initial response (SASL-IR)" [expr {$r eq "ok" && [count_in [logof $s1] {AUTHENTICATE PLAIN}] == 1}]
set r [call mail::imap::probe [iopts $P1 -password wrong]]
ok "probe: a wrong password is an auth error" [expr {[lindex $r 0] eq "error" && [lindex $r 1] eq "auth"}]
ctl $s1 caps -SASL-IR
set r [call mail::imap::probe [iopts $P1]]
ok "probe: AUTHENTICATE PLAIN answering the server's \"+\"" [expr {$r eq "ok"}]
ctl $s1 caps -AUTH=PLAIN -LITERAL+
set r [call mail::imap::probe [iopts $P1]]
ok "probe: LOGIN with the password as a synchronizing literal (8-bit)" [expr {$r eq "ok" && [count_in [logof $s1] {LOGIN maya@lind.page}] == 1}]
ctl $s1 caps +LOGINDISABLED
set r [call mail::imap::probe [iopts $P1]]
ok "probe: no password login offered is an auth error" [expr {[lrange $r 0 1] eq {error auth}}]
ctl $s1 caps -LOGINDISABLED +AUTH=PLAIN +LITERAL+ +SASL-IR
set ::up ""
mail::imap::open [iopts $P1 -idletimeout 800] {apply {{st args} {
	if {$st ne "ok"} { set ::up [list $st {*}$args]; return }
	set ::upsid [lindex $args 0]
	set ::upbig "Subject: big\r\n\r\n[string repeat "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde\r\n" 100000]"
	ctl $::s1 slowread on
	mail::imap::append_msg $::upsid Drafts {} $::upbig {apply {{st args} { set ::up [list $st {*}$args] }}}
}}}
until {$::up ne ""} 30000
ctl $s1 slowread off
ok "a large APPEND on a slow link is not cut off by the reply deadline" [expr {[lindex $::up 0] eq "ok" &&
	[lindex [lindex [ctl $s1 dump Drafts] end] 2] == [string length $::upbig]}]
catch {mail::imap::close $::upsid}
ctl $s1 expunge Drafts [lindex [lindex [ctl $s1 dump Drafts] end] 0]
set r [call mail::imap::probe [iopts 1 -host 192.0.2.10]]
ok "plain text to another computer is refused before connecting" [expr {[lrange $r 0 1] eq {error insecure}}]
set dead [socket -server {apply {{s a p} {close $s}}} -myaddr 127.0.0.1 0]
set dp [lindex [fconfigure $dead -sockname] 2]
close $dead
set r [call mail::imap::probe [iopts $dp]]
ok "a refused connection is a connect error" [expr {[lrange $r 0 1] eq {error connect}}]

puts "-- sync (plain, loopback)"
set big [string repeat "0123456789abcdef\r\n" 9000]
ctl $s1 deliver INBOX {\\Seen} [b64 [msg 1 ".starts with a dot\r\n{5}\r\nnot a literal ) ( \"\r\n"]]
ctl $s1 deliver INBOX {} [b64 [msg 2 "8-bit: \xc3\xa9t\xc3\xa9\r\n"]]
ctl $s1 deliver INBOX {\\Flagged} [b64 [msg 3 $big]]
ctl $s1 deliver Caf&AOk- {} [b64 [msg 4]]
ctl $s1 trickle on
set t0 $ticks
mail::sync::start p [list -imap [iopts $P1] -smtp [list -host 127.0.0.1 -port [dict get $s1 smtp] -security none -user $USER] \
	-password [list apply {{a} {return $::PW}}] -store st::store -status onstatus -poll 600000 -retry {300}]
ok "the first sync finishes and the account idles on the Inbox" [until {[state p] eq "idle"} 30000]
ctl $s1 trickle off
ok "folders: selectable ones only, with their roles and names as text" [expr {
	[lsort [st::store folders p]] eq [lsort {INBOX Sent Drafts Trash Caf&AOk-}] &&
	$st::F(p,Sent) eq {Sent sent /} && $st::F(p,INBOX) eq {INBOX inbox /} && $st::F(p,Caf&AOk-) eq "Caf\u00e9 {} /"}]
ok "messages: every byte as the server has it (dot line, literal-looking text, 8-bit, 160 KB) through split reads" [expr {
	[st::bytes p INBOX 1] eq [msg 1 ".starts with a dot\r\n{5}\r\nnot a literal ) ( \"\r\n"] &&
	[st::bytes p INBOX 2] eq [msg 2 "8-bit: \xc3\xa9t\xc3\xa9\r\n"] && [st::bytes p INBOX 3] eq [msg 3 $big] &&
	[st::bytes p Caf&AOk- 1] eq [msg 4]}]
ok "messages: flags come with them" [expr {[st::flagsof p INBOX 1] eq {{\Seen}} && [st::flagsof p INBOX 3] eq {{\Flagged}} && [st::flagsof p INBOX 2] eq ""}]
ok "the state records UIDVALIDITY and UIDNEXT" [expr {[dict get [st::store state p INBOX] uidnext] == 4 && [dict get [st::store state p INBOX] uidvalidity] ne ""}]
ok "the checked time is set" [expr {[dict get [mail::sync::status p] checked] ne ""}]
ok "the event loop kept running during the sync" [expr {$ticks - $t0 > 20}]
set L [logof $s1]
ok "bodies are fetched with BODY.PEEK (the server's \\Seen is not set by syncing)" [expr {[count_in $L {UID FETCH * BODY.PEEK*}] >= 2 && [count_in $L {UID FETCH *BODY\[\]*}] == 0}]
ok "the account idles with IDLE" [expr {[lindex $L end] eq "IDLE "}]

ctl $s1 deliver INBOX {} [b64 [msg 5]]
ok "IDLE: a new message arrives in the store without a poll" [until {[st::count p INBOX] == 4} 8000]
ok "IDLE: it was ended with DONE and resumed" [until {[state p] eq "idle"} 5000]
ctl $s1 flags INBOX 2 {\\Seen \\Answered}
ok "IDLE: a flag set on the server reaches the store" [until {[st::flagsof p INBOX 2] eq {{\Answered} {\Seen}}} 8000]
ok "CONDSTORE: only flags changed since the last sync are fetched" [expr {[count_in [logof $s1] {UID FETCH 1:* (UID FLAGS) (CHANGEDSINCE *)}] >= 1}]
ctl $s1 expunge INBOX 1
ok "IDLE: a message removed on the server is removed from the store" [until {[st::flagsof p INBOX 1] eq "-"} 8000]
set st::P(p,INBOX) [list [list 3 {\\Seen} {\\Flagged}]]
mail::sync::push p INBOX
proc srvflags {srv box uid} { foreach m [ctl $srv dump $box] { if {[lindex $m 0] == $uid} { return [lsort [lindex $m 1]] } }; return - }
ok "push: a local flag change goes to the server (+FLAGS and -FLAGS)" [until {[srvflags $s1 INBOX 3] eq {{\Seen}}} 8000]
ok "push: and is no longer pending" [until {$st::P(p,INBOX) eq {}} 3000]
ok "push: the server's answer does not undo it" [expr {[st::flagsof p INBOX 3] eq {{\Flagged}} || [st::flagsof p INBOX 3] eq {{\Seen}}}]
set st::calls {}
mail::sync::check p
ok "check: every folder is checked again" [until {[state p] eq "idle" && [lsearch -glob $st::calls {setstate Caf&AOk- *}] >= 0} 8000]
set before [count_in [logof $s1] {UID FETCH 1:* (UID FLAGS)*}]
set st::calls {}
mail::sync::check p
until {[state p] eq "idle" && [lsearch -glob $st::calls {setstate Caf&AOk- *}] >= 0} 8000
ok "CONDSTORE: an unchanged folder fetches no flags at all" [expr {[count_in [logof $s1] {UID FETCH 1:* (UID FLAGS)*}] == $before}]

# 30 new messages: fetched in batches of 25, the state saved after each
for {set i 10} {$i < 40} {incr i} { ctl $s1 deliver Drafts {} [b64 [msg $i]] }
set st::calls {}
mail::sync::check p
ok "batches: 30 new messages all arrive" [until {[st::count p Drafts] == 30} 15000]
ok "batches: in two UID FETCHes, the state saved after each" [expr {[count_in $st::calls {setstate Drafts *}] >= 2}]

set v [ctl $s1 renumber INBOX]
set st::calls {}
mail::sync::check p
ok "UIDVALIDITY changed: the store is told and the folder is fetched again" [until {[lsearch $st::calls {reset INBOX}] >= 0 && [st::count p INBOX] == 3 && [dict exists [st::store state p INBOX] uidvalidity] && [dict get [st::store state p INBOX] uidvalidity] == $v} 8000]

puts "-- connection loss and polling"
until {[state p] eq "idle"} 5000
set statuses {}
ctl $s1 kick
ok "a dropped connection shows as offline" [until {[lsearch -glob $statuses {p *state offline*}] >= 0} 8000]
ok "and is retried: the account idles again" [until {[state p] eq "idle"} 8000]
ctl $s1 deliver INBOX {} [b64 [msg 50]]
ok "after the retry new mail still arrives" [until {[st::count p INBOX] == 4} 8000]
mail::sync::stop p
ok "stop: the account is stopped" [expr {[state p] eq "stopped"}]

mail::sync::start r [list -imap [iopts $P1 -idletimeout 600] -password [list apply {{a} {return $::PW}}] -store st::store -status onstatus -poll 600000 \
	-idlerestart 400 -retry {300}]
until {[state r] eq "idle"} 8000
set n [count_in [logof $s1] DONE]
ok "IDLE is ended and started again every -idlerestart" [until {[count_in [logof $s1] DONE] >= $n + 2 && [state r] eq "idle"} 5000]
set statuses {}
ctl $s1 mute on
ok "a server that stops answering is noticed at the IDLE restart (offline, timeout)" [until {[lsearch -glob $statuses {r *state offline*kind timeout*}] >= 0} 5000]
ctl $s1 mute off
ok "and the account comes back when it answers again" [until {[state r] eq "idle"} 8000]
mail::sync::stop r

# the store fails (a full disk) while a batch's state is saved: the account is offline, and once the store works the
# retry brings the mail; it is not stuck in "syncing" for good
set ::storefail 0
proc failing_store {method args} {
	if {$method eq "setstate" && $::storefail} { error "No space left on device" }
	st::store $method {*}$args
}
mail::sync::start sf [list -imap [iopts $P1] -password [list apply {{a} {return $::PW}}] -store failing_store -status onstatus \
	-poll 600000 -retry {300}]
until {[state sf] eq "idle"} 8000
set n [st::count sf INBOX]
set statuses {}
set ::storefail 1
ctl $s1 deliver INBOX {} [b64 [msg 52]]
ok "a store that fails takes the account offline, naming the failure" [until {[lsearch -glob $statuses {sf *state offline*No space*}] >= 0} 8000]
set ::storefail 0
ok "and once it works again the retry finishes the sync" [until {[state sf] eq "idle" && [dict get [st::store state sf INBOX] uidnext] > [lindex [lsort -integer [dict keys $st::M(sf,INBOX)]] end]} 8000]
mail::sync::stop sf

ctl $s1 caps -IDLE
mail::sync::start q [list -imap [iopts $P1] -password [list apply {{a} {return $::PW}}] -store st::store -poll 700 -retry {300}]
ok "without IDLE the account waits for the next poll" [until {[state q] eq "waiting"} 8000]
set n [st::count q INBOX]
ctl $s1 deliver INBOX {} [b64 [msg 51]]
ok "the poll picks up new mail" [until {[st::count q INBOX] == $n + 1} 5000]
mail::sync::stop q
ctl $s1 caps +IDLE

mail::sync::start bad [list -imap [iopts $P1] -password [list apply {{a} {return wrong}}] -store st::store -retry {100}]
ok "a refused login stops the account with an auth error (no retry)" [until {[state bad] eq "error"} 8000]
set n [count_in [logof $s1] {AUTHENTICATE*}]
until {0} 400
ok "and it is not retried by itself" [expr {[count_in [logof $s1] {AUTHENTICATE*}] == $n && [dict get [mail::sync::status bad] kind] eq "auth"}]
mail::sync::stop bad

puts "-- SMTP (plain, loopback)"
proc sopts {port args} { dict merge [list -host 127.0.0.1 -port $port -security none -user $::USER -password $::PW] $args }
set SP [dict get $s1 smtp]
set m "From: Maya Lind <maya@lind.page>\nTo: Anna Berg <anna@hearth.studio>\nBcc: lea@moreau.example\nSubject: Run sheet\n\nSee you at 18:00.\n.\n..and a dotted line\n"
set r [call mail::smtp::send [sopts $SP] maya@lind.page {anna@hearth.studio lea@moreau.example} $m]
set got [lindex [ctl $s1 sent] end]
ok "send: the server takes it (AUTH PLAIN, MAIL, RCPT for each)" [expr {[lindex $r 0] eq "ok" && [lindex $got 0] eq "maya@lind.page" && [lindex $got 1] eq {anna@hearth.studio lea@moreau.example}}]
ok "send: the message arrives byte for byte (CRLF, unstuffed), without its Bcc header" [expr {[binary decode base64 [lindex $got 2]] eq [string map [list \n \r\n] [mail::smtp::without_bcc $m]]}]
set L [logof $s1]
ok "send: EHLO names an address literal, not the host name; SIZE is declared" [expr {[count_in $L {SMTP EHLO \[127.0.0.1\]}] >= 1 && [count_in $L {SMTP MAIL FROM:<maya@lind.page> SIZE=*}] >= 1}]
set n [llength [ctl $s1 sent]]
set r [call mail::smtp::send [sopts $SP] maya@lind.page {anna@hearth.studio reject@lind.page} $m]
ok "send: a refused recipient fails the send and names the address" [expr {[lrange $r 0 1] eq {error rejected} && [string match *reject@lind.page* [lindex $r 2]] && [llength [ctl $s1 sent]] == $n}]
set r [call mail::smtp::send [sopts $SP] maya@lind.page anna@hearth.studio "Subject: big\r\n\r\n[string repeat x 250000]"]
ok "send: over the server's SIZE fails before DATA" [expr {[lrange $r 0 1] eq {error toobig} && [llength [ctl $s1 sent]] == $n}]
set r [call mail::smtp::send [sopts $SP -password wrong] maya@lind.page anna@hearth.studio $m]
ok "send: a wrong password is an auth error" [expr {[lrange $r 0 1] eq {error auth}}]
set r [call mail::smtp::send [sopts $SP] "bad <addr>" anna@hearth.studio $m]
ok "send: an address with <> or spaces is refused before connecting" [expr {[lrange $r 0 1] eq {error refused}}]
set s6 [server -plainauth 1 -smtpsize 20000000]
ctl $s6 slowread on
set big6 "Subject: big\r\n\r\n[string repeat "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde\r\n" 100000]"
set r [call mail::smtp::send [sopts [dict get $s6 smtp] -replytimeout 800] maya@lind.page anna@hearth.studio $big6]
ok "send: a large message on a slow link is not cut off by the reply deadline" [expr {$r ne "" && [lindex $r 0] eq "ok" &&
	[string length [binary decode base64 [lindex [lindex [ctl $s6 sent] end] 2]]] == [string length $big6]}]
set r [call mail::smtp::probe [sopts $SP]]
ok "probe: SMTP Test connection logs in and quits" [expr {$r eq "ok"}]
set s2 [server]
set r [call mail::smtp::send [sopts [dict get $s2 smtp]] maya@lind.page anna@hearth.studio $m]
ok "send: no AUTH offered (the server wants TLS first) is an auth error" [expr {[lrange $r 0 1] eq {error auth}}]

puts "-- sending from an account: the copy in Sent"
mail::sync::start p [list -imap [iopts $P1] -smtp [list -host 127.0.0.1 -port $SP -security none -user $USER] \
	-password [list apply {{a} {return $::PW}}] -store st::store -poll 600000 -retry {300}]
until {[state p] eq "idle"} 10000
set n [st::count p Sent]
set r [call mail::sync::send p maya@lind.page {anna@hearth.studio} $m]
ok "sync send: ok once the server took it" [expr {$r eq "ok"}]
ok "sync send: a copy is saved to Sent with \\Seen and comes into the store" [until {[st::count p Sent] == $n + 1} 8000]
set sentuid [lindex [lsort -integer [dict keys $st::M(p,Sent)]] end]
ok "sync send: the Sent copy keeps the Bcc header (CRLF line ends)" [expr {[st::bytes p Sent $sentuid] eq [string map [list \n \r\n] $m] && [st::flagsof p Sent $sentuid] eq {{\Seen}}}]
mail::sync::stop p

set s3 [server -plainauth 1 -nosent 1 -caps +X-GM-EXT-1]
mail::sync::start g [list -imap [iopts [dict get $s3 imap]] -smtp [list -host 127.0.0.1 -port [dict get $s3 smtp] -security none -user $USER] \
	-password [list apply {{a} {return $::PW}}] -store st::store -poll 600000]
until {[state g] eq "idle"} 10000
set r [call mail::sync::send g maya@lind.page {anna@hearth.studio} $m]
until {0} 500
ok "Gmail (X-GM-EXT-1): no copy is appended (Gmail files its own)" [expr {$r eq "ok" && [count_in [logof $s3] APPEND*] == 0}]
mail::sync::stop g
set s4 [server -plainauth 1 -nosent 1]
mail::sync::start n [list -imap [iopts [dict get $s4 imap]] -smtp [list -host 127.0.0.1 -port [dict get $s4 smtp] -security none -user $USER] \
	-password [list apply {{a} {return $::PW}}] -store st::store -poll 600000]
until {[state n] eq "idle"} 10000
set r [call mail::sync::send n maya@lind.page {anna@hearth.studio} $m]
ok "no Sent folder: one is made and the copy saved there" [until {[st::count n Sent] == 1} 8000]
ok "and it is known as the Sent folder" [expr {[lindex $st::F(n,Sent) 1] eq "sent" && [count_in [logof $s4] {CREATE Sent}] == 1}]
mail::sync::stop n
# servers that keep every folder under the Inbox (Courier, cPanel): INBOX/Sent without SPECIAL-USE is the Sent folder
set s6 [server -plainauth 1 -nosent 1]
ctl $s6 mailbox INBOX/Sent
mail::sync::start c [list -imap [iopts [dict get $s6 imap]] -smtp [list -host 127.0.0.1 -port [dict get $s6 smtp] -security none -user $USER] \
	-password [list apply {{a} {return $::PW}}] -store st::store -poll 600000]
until {[state c] eq "idle"} 10000
set r [call mail::sync::send c maya@lind.page {anna@hearth.studio} $m]
ok "INBOX/Sent (no SPECIAL-USE) is the Sent folder: the copy goes there, no Sent is made" [expr {$r eq "ok" &&
	[until {[st::count c INBOX/Sent] == 1} 8000] && [count_in [logof $s6] {CREATE*}] == 0 && [lindex $st::F(c,INBOX/Sent) 1] eq "sent"}]
mail::sync::stop c
set pw [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] mail-sync-host-[pid]]
set r [call mail::imap::probe [iopts 143 -host ">$pw" -security starttls]]
ok "a host that would be a redirection to getent is refused, and no file is made" [expr {[lrange $r 0 1] eq {error resolve} && ![file exists $pw]}]
file delete -force $pw

puts "-- end to end: the Maildir store (store.tcl through syncstore.tcl)"
source [file join $app syncstore.tcl]
set mroot [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] mail-sync-[pid]]
file delete -force $mroot
mail::store::set_root [file join $mroot Mail]
mail::store::set_cache_root [file join $mroot cache]
set s5 [server -plainauth 1 -nosent 1]
ctl $s5 mailbox Gesendet \\Sent
ctl $s5 deliver INBOX {\\Seen travel} [b64 [msg 70]]
ctl $s5 deliver INBOX {} [b64 [msg 71]]
proc e2e_start {} {
	mail::sync::start home [list -imap [iopts [dict get $::s5 imap]] -smtp [list -host 127.0.0.1 -port [dict get $::s5 smtp] -security none -user $::USER] \
		-password [list apply {{a} {return $::PW}}] -store ::mail::syncstore::cmd -poll 600000 -retry {300}]
}
e2e_start
ok "Maildir: the first sync finishes" [until {[state home] eq "idle"} 15000]
proc keyof {folder n} {
	foreach k [mail::store::keys home $folder] { if {[string match "*Message $n\r\n*" [mail::store::read $k]]} { return $k } }
	return ""
}
set k70 [keyof Inbox 70]
set k71 [keyof Inbox 71]
ok "Maildir: the server's INBOX is Inbox, a \\Sent folder named Gesendet is Sent, Caf&AOk- is Caf\u00e9" [expr {
	[lsort [mail::store::folders home]] eq [lsort [list Inbox Sent Drafts Trash "Caf\u00e9"]] && [mail::store::role Sent] eq "sent"}]
ok "Maildir: each store folder knows its server folder" [expr {[mail::syncstore::server home Inbox] eq "INBOX" &&
	[mail::syncstore::server home Sent] eq "Gesendet" && [mail::syncstore::server home "Caf\u00e9"] eq "Caf&AOk-"}]
ok "Maildir: messages are files with the server's bytes" [expr {$k70 ne "" && $k71 ne "" && [mail::store::read $k70] eq [msg 70]}]
ok "Maildir: \\Seen is S in the name; a keyword is a label; an unread message is in new/" [expr {
	[mail::store::flags $k70] eq "S[mail::store::keyword_letter home Inbox travel 0]" && [mail::store::labels $k70] eq "travel" &&
	[file tail [file dirname [mail::store::path $k71]]] eq "new"}]
ok "Maildir: the index reads them (the Ledger's model)" [expr {[llength [mail::store::messages home Inbox]] == 2}]
ctl $s5 flags INBOX 2 {\\Flagged}
ok "Maildir: a flag set on the server renames the file (F)" [until {[mail::store::flags $k71] eq "F"} 8000]
mail::store::add_flags $k71 S
mail::store::add_label $k71 ribbon
mail::sync::push home [mail::syncstore::server home Inbox]
ok "Maildir: a flag and a label set in the store reach the server" [until {[srvflags $s5 INBOX 2] eq [lsort {\\Flagged \\Seen ribbon}]} 8000]
until {[state home] eq "idle"} 5000
set n [count_in [logof $s5] {UID STORE*}]
mail::sync::check home
until {[state home] eq "idle"} 8000
until {0} 300
ok "Maildir: once on the server a change is not sent again" [expr {[count_in [logof $s5] {UID STORE*}] == $n}]
ok "Maildir: the state is kept next to the messages" [file exists [file join $mroot Mail home Inbox .ribbon-sync]]
mail::sync::stop home
# a new run of the app: nothing in memory
array unset ::mail::syncstore::st
array unset ::mail::syncstore::names
set n [count_in [logof $s5] {UID FETCH * (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK*}]
e2e_start
until {[state home] eq "idle"} 10000
ok "Maildir: after a restart nothing is fetched again" [expr {[count_in [logof $s5] {UID FETCH * (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK*}] == $n &&
	[llength [mail::store::keys home Inbox]] == 2}]
ctl $s5 expunge INBOX 1
ok "Maildir: a message removed on the server is removed here" [until {[llength [mail::store::keys home Inbox]] == 1} 8000]
ctl $s5 renumber INBOX
mail::sync::check home
until {[state home] eq "idle"} 8000
until {[llength [mail::store::keys home Inbox]] == 1 && [dict exists [mail::syncstore::M_state home INBOX] uidnext] && [dict get [mail::syncstore::M_state home INBOX] uidnext] == 2} 5000
ok "Maildir: a UIDVALIDITY change replaces the copies, it does not double them" [expr {[llength [mail::store::keys home Inbox]] == 1 &&
	[mail::store::read [lindex [mail::store::keys home Inbox] 0]] eq [msg 71]}]
set r [call mail::sync::send home maya@lind.page {anna@hearth.studio} $m]
ok "Maildir: a sent message is saved to the server's Gesendet and comes into Sent, seen" [expr {$r eq "ok" &&
	[until {[llength [mail::store::keys home Sent]] == 1} 8000] && [mail::store::flags [lindex [mail::store::keys home Sent] 0]] eq "S"}]
mail::sync::stop home
# two server folders that come out with one name never share a store folder (and so one UID map)
mail::syncstore::cmd folder two Gesendet Gesendet sent /
mail::syncstore::cmd folder two Sent Sent "" /
ok "Maildir: a \\Sent Gesendet named Sent and the server's own Sent get two store folders" [expr {
	[mail::syncstore::local two Gesendet] eq "Sent" && [mail::syncstore::local two Sent] ni {"" Sent}}]
# server names the store would refuse ("~old": a home directory) or mistake ("new": the parent Maildir's own new/)
set s7 [server -plainauth 1]
ctl $s7 mailbox ~old
ctl $s7 mailbox Projects/new
ctl $s7 deliver ~old {} [b64 [msg 80]]
ctl $s7 deliver Projects/new {} [b64 [msg 81]]
ctl $s7 deliver INBOX {} [b64 [msg 82]]
mail::sync::start odd [list -imap [iopts [dict get $s7 imap]] -password [list apply {{a} {return $::PW}}] \
	-store ::mail::syncstore::cmd -poll 600000]
ok "Maildir: folders named ~old and Projects/new sync as _old and Projects/_new, and the rest of the account syncs" [expr {
	[until {[state odd] eq "idle"} 15000] && [llength [mail::store::keys odd Inbox]] == 1 &&
	[mail::syncstore::local odd ~old] eq "_old" && [llength [mail::store::keys odd _old]] == 1 &&
	[mail::syncstore::local odd Projects/new] eq "Projects/_new" && [llength [mail::store::keys odd Projects/_new]] == 1}]
mail::sync::stop odd

puts "-- moves and deletes on the server (Archive, Delete; MOVE, UIDPLUS, neither)"
proc srvuids {srv box} { lmap m [ctl $srv dump $box] {lindex $m 0} }
proc srvdeleted {srv box} { lmap m [ctl $srv dump $box] { if {"\\Deleted" ni [lindex $m 1]} continue; lindex $m 0 } }
# what Mail's Archive does (mailapp::move_to): the server move asked for, then the store's move
proc archive_here {acct key to} {
	lassign $key a f u
	mail::sync::move $acct [mail::syncstore::server $a $f] [mail::syncstore::uid $a $f $u] [mail::syncstore::server $a $to]
	mail::store::move $key $a $to
}
proc delete_here {acct key} {
	lassign $key a f u
	mail::sync::move $acct [mail::syncstore::server $a $f] [mail::syncstore::uid $a $f $u] ""
	mail::store::delete $key
}
proc mv_start {acct srv} {
	mail::sync::start $acct [list -imap [iopts [dict get $srv imap]] -password [list apply {{a} {return $::PW}}] \
		-store ::mail::syncstore::cmd -poll 600000 -retry {300}]
}
proc keyin {acct folder n} {
	foreach k [mail::store::keys $acct $folder] { if {[string match "*Message $n\r\n*" [mail::store::read $k]]} { return $k } }
	return ""
}
foreach {acct caps how} {mv {+MOVE} "UID MOVE" cp {} "UID COPY, \\Deleted, UID EXPUNGE" pl {-UIDPLUS} "UID COPY and \\Deleted"} {
	set sv [server -plainauth 1 -caps $caps]
	ctl $sv mailbox Archive \\Archive
	ctl $sv deliver INBOX {} [b64 [msg 90]]
	ctl $sv deliver INBOX {\\Seen} [b64 [msg 91]]
	ctl $sv deliver INBOX {} [b64 [msg 92]]
	mv_start $acct $sv
	until {[state $acct] eq "idle" && [llength [mail::store::keys $acct Inbox]] == 3} 15000
	set k [keyin $acct Inbox 91]
	ok "$acct: the store's message knows its server UID" [expr {$k ne "" && [mail::syncstore::uid $acct Inbox [lindex $k 2]] == 2}]
	set nk [archive_here $acct $k Archive]
	ok "$acct: Archive reaches the server ($how)" [until {([srvuids $sv INBOX] eq {1 3} || ($acct eq "pl" && [srvdeleted $sv INBOX] eq {2})) &&
		[llength [srvuids $sv Archive]] == 1} 8000]
	set L [logof $sv]
	switch -- $acct {
		mv { ok "$acct: one UID MOVE, nothing copied" [expr {[count_in $L {UID MOVE 2 Archive}] == 1 && [count_in $L {UID COPY*}] == 0}] }
		cp { ok "$acct: copied, marked and expunged by UID only" [expr {[count_in $L {UID COPY 2 Archive}] == 1 &&
			[count_in $L {UID STORE 2 +FLAGS.SILENT (\\Deleted)}] == 1 && [count_in $L {UID EXPUNGE 2}] == 1 && [count_in $L EXPUNGE*] == 0}] }
		pl { ok "$acct: copied and marked, never expunged (that would take what other clients marked)" [expr {
			[count_in $L {UID COPY 2 Archive}] == 1 && [count_in $L {UID STORE 2 +FLAGS.SILENT (\\Deleted)}] == 1 &&
			[count_in $L *EXPUNGE*] == 0}] }
	}
	until {[state $acct] eq "idle"} 8000
	mail::sync::check $acct
	until {[state $acct] eq "idle"} 8000
	until {0} 200
	ok "$acct: the server's copy in Archive is the one moved here, not a second (matched by [expr {$acct eq "pl" ? "Message-ID" : "COPYUID"}])" [expr {
		[llength [mail::store::keys $acct Archive]] == 1 && ![catch {mail::store::path $nk}] &&
		[mail::syncstore::uid $acct Archive [lindex $nk 2]] eq [lindex [srvuids $sv Archive] 0]}]
	ok "$acct: the Inbox keeps the other two, on both sides" [expr {[llength [mail::store::keys $acct Inbox]] == 2 &&
		([srvuids $sv INBOX] eq {1 3} || ($acct eq "pl" && [srvdeleted $sv INBOX] eq {2}))}]
	# a flag set on the moved copy afterwards reaches the server's copy
	mail::store::add_flags $nk F
	mail::sync::push $acct Archive
	ok "$acct: a flag on the moved copy reaches the server's copy" [until {[lsearch -exact [lindex [ctl $sv dump Archive] 0 1] \\Flagged] >= 0} 8000]
	# to Trash, then deleted from Trash
	set k3 [keyin $acct Inbox 92]
	set tk [archive_here $acct $k3 Trash]
	until {[llength [srvuids $sv Trash]] == 1} 8000
	until {[state $acct] eq "idle"} 8000
	set tk [lindex [mail::store::keys $acct Trash] 0]
	delete_here $acct $tk
	ok "$acct: Delete in Trash removes it from the server's Trash" [until {[srvuids $sv Trash] eq {} &&
		![llength [mail::syncstore::M_moves $acct]]} 8000]
	if {$acct eq "pl"} { ok "$acct: without UIDPLUS the delete in Trash is an EXPUNGE there" [expr {[count_in [logof $sv] EXPUNGE*] == 1}] }
	# asked for just before a quit: done at the next start
	set k1 [keyin $acct Inbox 90]
	archive_here $acct $k1 Archive
	mail::sync::stop $acct
	array unset ::mail::syncstore::st
	array unset ::mail::syncstore::names
	ok "$acct: a move not yet done is kept with the folder" [expr {[llength [mail::syncstore::M_moves $acct]] == 1}]
	mv_start $acct $sv
	ok "$acct: and is done when Mail starts again" [until {[lsearch [ctl $sv dump Archive] "* *[string length [msg 90]]"] >= 0 &&
		[llength [mail::syncstore::M_moves $acct]] == 0} 10000]
	until {[state $acct] eq "idle"} 8000
	mail::sync::check $acct
	until {[state $acct] eq "idle"} 8000
	ok "$acct: Archive holds two, each once" [expr {[llength [mail::store::keys $acct Archive]] == 2}]
	mail::sync::stop $acct
}
# a move kept over a quit while the server renumbered the folder: the UID it names is not that message any more
set sv [server -plainauth 1 -caps +MOVE]
ctl $sv mailbox Archive \\Archive
ctl $sv deliver INBOX {} [b64 [msg 95]]
mv_start rn $sv
until {[state rn] eq "idle" && [llength [mail::store::keys rn Inbox]] == 1} 15000
archive_here rn [keyin rn Inbox 95] Archive
mail::sync::stop rn
ctl $sv renumber INBOX
array unset ::mail::syncstore::st
array unset ::mail::syncstore::names
mv_start rn $sv
until {[state rn] eq "idle"} 10000
ok "a move kept over a UIDVALIDITY change is not done on another message" [expr {[srvuids $sv Archive] eq {} &&
	[count_in [logof $sv] {UID MOVE*}] == 0 && [llength [mail::syncstore::M_moves rn]] == 0}]
# refused: the folder is gone on the server
ctl $sv deliver INBOX {} [b64 [msg 96]]
mail::sync::check rn
until {[llength [mail::store::keys rn Inbox]] >= 2 && [state rn] eq "idle"} 8000
set u [mail::syncstore::uid rn Inbox [lindex [keyin rn Inbox 96] 2]]
mail::sync::move rn INBOX $u Nowhere
ok "a move the server refuses ends, and says so in the status" [until {[dict get [mail::sync::status rn] kind] eq "move" &&
	[llength [mail::syncstore::M_moves rn]] == 0} 8000]
mail::sync::stop rn
file delete -force $mroot

if {$tls} {
	puts "-- TLS"
	set ca [file join $certs good.pem]
	set t1 [server -cert $ca -key [file join $certs good.key]]
	proc topts {port sec args} { dict merge [list -host localhost -port $port -security $sec -user $::USER -password $::PW -cafile $::ca] $args }
	set r [call mail::imap::probe [topts [dict get $t1 imaps] tls]]
	ok "IMAPS: TLS from the start to localhost (looked up without blocking), certificate checked" [expr {$r eq "ok"}]
	set r [call mail::imap::probe [topts [dict get $t1 imaps] tls -host 127.0.0.1]]
	ok "IMAPS: to an address, matched against the certificate's IP entry" [expr {$r eq "ok"}]
	set r [call mail::imap::probe [topts [dict get $t1 imap] starttls]]
	ok "IMAP STARTTLS: upgraded before the password goes out" [expr {$r eq "ok" && [lsearch -exact [logof $t1] {STARTTLS }] >= 0}]
	set L [logof $t1]
	ok "IMAP STARTTLS: the login comes after STARTTLS" [expr {[lsearch -exact $L {STARTTLS }] < [lsearch -glob -start [lsearch -exact $L {STARTTLS }] $L AUTHENTICATE*]}]
	ctl $t1 inject on
	set r [call mail::imap::probe [topts [dict get $t1 imap] starttls]]
	ok "IMAP STARTTLS: a response injected before the handshake is refused" [expr {[lrange $r 0 1] eq {error tls}}]
	set r [call mail::smtp::probe [topts [dict get $t1 smtp] starttls]]
	ok "SMTP STARTTLS: an injected reply is refused" [expr {[lrange $r 0 1] eq {error tls}}]
	ctl $t1 inject off
	set r [call mail::imap::probe [topts [dict get $t1 imaps] tls -cafile ""]]
	ok "a certificate the system does not trust is refused" [expr {[lrange $r 0 1] eq {error tls}}]
	set r [call mail::imap::probe [topts [dict get $s1 imap] starttls]]
	ok "STARTTLS asked of a server that does not offer it is refused (no plain fallback)" [expr {[lrange $r 0 1] eq {error tls}}]
	set t2 [server -cert [file join $certs other.pem] -key [file join $certs other.key]]
	set r [call mail::imap::probe [topts [dict get $t2 imaps] tls -cafile [file join $certs other.pem]]]
	ok "a trusted certificate for another host is refused, naming it" [expr {[lrange $r 0 1] eq {error tls} && [string match *other.test* [lindex $r 2]]}]
	set r [call mail::smtp::send [topts [dict get $t1 smtps] tls] maya@lind.page anna@hearth.studio $m]
	ok "SMTPS (465): sent over TLS" [expr {$r ne "" && [lindex $r 0] eq "ok"}]
	set r [call mail::smtp::send [topts [dict get $t1 smtp] starttls] maya@lind.page anna@hearth.studio $m]
	ok "submission (587) with STARTTLS: EHLO again, AUTH only after TLS, sent" [expr {[lindex $r 0] eq "ok" && [count_in [logof $t1] {SMTP EHLO*}] >= 4}]
	ctl $t1 deliver INBOX {} [b64 [msg 60]]
	mail::sync::start t [list -imap [topts [dict get $t1 imaps] tls] -password [list apply {{a} {return $::PW}}] -store st::store -poll 600000]
	ok "sync over TLS: the account idles" [until {[state t] eq "idle"} 15000]
	ok "sync over TLS: the message is in the store" [expr {[st::bytes t INBOX 1] eq [msg 60]}]
	ctl $t1 deliver INBOX {} [b64 [msg 61]]
	ok "sync over TLS: IDLE brings new mail" [until {[st::count t INBOX] == 2} 8000]
	mail::sync::stop t
} else {
	skip "TLS (needs MAIL_TEST_CERTS and the tls package)"
}

foreach f $servers { catch {puts $f quit; flush $f}; catch {close $f} }
if {$fails} { puts "mail-sync: $fails failed"; exit 1 }
puts "mail-sync: ok"
exit 0
