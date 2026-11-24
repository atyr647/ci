# mail-accounts.tcl - Mail's accounts provider (apps/mail/accounts.tcl, U42) without Tk: the accounts file and the
# Secret Service (tests/mail-secret-service.tcl on a private dbus-daemon), the checks before an account is added,
# Thunderbird's autoconfig format, finding the servers for an address against a fixture HTTP server and a fixture DNS
# server (TCP) on 127.0.0.1, and Test connection against tests/mail-fixture-server.tcl.
# Prints "ok ..." lines and "accounts: ok"; any failure exits 1.   tclsh8.6 tests/mail-accounts.tcl (unix_extra on
# TCLLIBPATH)

set here [file dirname [file normalize [info script]]]
set files [file join [file dirname $here] srcpkgs ribbon-desktop files]
lappend auto_path $files
package require ribbon::dbus
source -encoding utf-8 [file join $files apps mail accounts.tcl]

set fails 0
set pids {}
proc ok {cond what} {
	if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what"; incr ::fails }
}
proc until {cond {ms 8000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 [list expr $cond]]} {
		if {[clock milliseconds] > $end} { return 0 }
		after 10 {set ::tick_ 1}
		vwait ::tick_
	}
	return 1
}
proc cleanup {} { foreach p $::pids { catch {exec kill $p} } }
after 120000 {puts "  FAIL timed out"; cleanup; exit 1}

set T [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] mailacc[pid]]
file delete -force $T
file mkdir $T
set ::env(XDG_CONFIG_HOME) $T/config

# ---- the Secret Service stand-in --------------------------------------------------------------------------------------
set fh [open |[list dbus-daemon --config-file=[file join $here mail-fixtures session-bus.conf] --nofork --print-address=1] r]
lappend pids {*}[pid $fh]
gets $fh addr
set ::env(DBUS_SESSION_BUS_ADDRESS) $addr
set ss [open |[list [info nameofexecutable] [file join $here mail-secret-service.tcl] 2>@stderr] r]
lappend pids {*}[pid $ss]
gets $ss line
if {$line ne "ready"} { puts "  FAIL the secret service stand-in did not start"; cleanup; exit 1 }
mail::secrets::address $addr

# ---- the file and the secret store -----------------------------------------------------------------------------------
set pw "pa ss\"wörd"
set d [dict create name "Maya Lind" address maya@lind.page user maya@lind.page imap {imap.lind.page 993 tls} smtp {smtp.lind.page 465 tls}]
ok {[mail::accounts::configured] eq ""} "no file: no accounts"
ok {[mail::accounts::check $d] eq ""} "a complete account passes the checks"
ok {[mail::accounts::check [dict replace $d address maya@]] eq "The email address is not complete"} "an address without a domain is refused"
ok {[mail::accounts::check [dict replace $d imap {imap.lind.page 99999 tls}]] eq "The IMAP port is not a port number"} "a port out of range is refused"
ok {[mail::accounts::check [dict replace $d smtp {{smtp lind} 465 tls}]] eq "The SMTP server is not a host name"} "a host with a space is refused"
ok {[mail::accounts::check [dict replace $d imap {imap.lind.page 143 none}]] eq "The IMAP server needs SSL/TLS or STARTTLS"} "plain text to a remote server is refused"
ok {[mail::accounts::check [dict replace $d imap {127.0.0.1 143 none}]] eq ""} "plain text to this computer is allowed"
ok {[mail::accounts::add $d $pw] eq "maya@lind.page"} "an account is added under its address"
set c [mail::accounts::configured]
ok {[dict keys $c] eq "maya@lind.page"} "configured lists it"
set o [dict get $c maya@lind.page]
ok {[dict get $o -address] eq "maya@lind.page" && [dict get $o -fullname] eq "Maya Lind"} "with its address and name (the From)"
ok {[dict get $o -imap] eq {-host imap.lind.page -port 993 -security tls -user maya@lind.page}} "with its IMAP server for the sync"
ok {[dict get $o -smtp] eq {-host smtp.lind.page -port 465 -security tls -user maya@lind.page}} "and its SMTP server"
ok {[{*}[dict get $o -password] maya@lind.page] eq $pw} "the sync's password callback reads the password from the Secret Service"
set f [file join $T config ribbon mail-accounts.conf]
set fh [open $f r]; set text [read $fh]; close $fh
ok {[string first "wörd" $text] < 0 && [string first "pa ss" $text] < 0} "the password is not in the file"
ok {[file attributes $f -permissions] eq "00600"} "the file is the user's only (0600)"
ok {[mail::accounts::check $d] eq "maya@lind.page is in Mail already"} "the same address twice is refused"
set d2 [dict create name "Maya Lind" address maya@hearth.studio user maya imap {mail.hearth.studio 143 starttls} smtp {mail.hearth.studio 587 starttls}]
mail::accounts::add $d2 other
ok {[dict keys [mail::accounts::configured]] eq {maya@lind.page maya@hearth.studio}} "a second account follows the first (the file's order)"
ok {[mail::accounts::password maya@hearth.studio] eq "other" && [mail::accounts::password maya@lind.page] eq $pw} "each has its own password"
# a refused secret store: nothing is written
mail::secrets::address unix:path=$T/nobus
ok {[catch {mail::accounts::add [dict replace $d address x@y.test] p} err] && [string match "The password could not be saved:*" $err]} \
	"no secret store: the account is not added"
ok {"x@y.test" ni [dict keys [mail::accounts::configured]]} "and the file is unchanged"
mail::secrets::address $addr

# ---- Thunderbird's format ----------------------------------------------------------------------------------------------
set xml {<?xml version="1.0"?>
<clientConfig version="1.1"><emailProvider id="lind.page"><domain>lind.page</domain>
<incomingServer type="pop3"><hostname>pop.lind.page</hostname><port>995</port><socketType>SSL</socketType></incomingServer>
<incomingServer type="imap"><hostname>oauth.lind.page</hostname><port>993</port><socketType>SSL</socketType><authentication>OAuth2</authentication><username>%EMAILADDRESS%</username></incomingServer>
<incomingServer type="imap"><hostname>imap.%EMAILDOMAIN%</hostname><port>143</port><socketType>STARTTLS</socketType><authentication>password-cleartext</authentication><username>%EMAILLOCALPART%</username></incomingServer>
<incomingServer type="imap"><hostname>IMAPS.lind.page</hostname><port>993</port><socketType>SSL</socketType><authentication>OAuth2</authentication><authentication>password-cleartext</authentication><username>%EMAILLOCALPART%</username></incomingServer>
<outgoingServer type="smtp"><hostname>smtp.lind.page</hostname><port>587</port><socketType>STARTTLS</socketType><authentication>password-cleartext</authentication></outgoingServer>
</emailProvider></clientConfig>}
set r [mail::accounts::parse_autoconfig $xml maya@lind.page]
ok {[dict get $r imap] eq {imaps.lind.page 993 tls}} "autoconfig: the IMAP server with TLS and a password login wins (OAuth-only and POP left out)"
ok {[dict get $r smtp] eq {smtp.lind.page 587 starttls} && [dict get $r user] eq "maya"} "autoconfig: SMTP with STARTTLS; %EMAILLOCALPART% is the user name"
ok {[mail::accounts::parse_autoconfig {<clientConfig><incomingServer type="imap"><hostname>a</hostname><port>143</port><socketType>plain</socketType></incomingServer></clientConfig>} a@b.c] eq ""} \
	"autoconfig: plain text only, or no SMTP: nothing"

# ---- fixture HTTP and DNS servers --------------------------------------------------------------------------------------
proc http_conn {s args} {
	fconfigure $s -translation binary -blocking 0
	set ::hbuf($s) ""
	fileevent $s readable [list http_read $s]
}
proc http_read {s} {
	append ::hbuf($s) [read $s]
	if {[string first "\r\n\r\n" $::hbuf($s)] < 0} { if {[eof $s]} { close $s }; return }
	regexp {^GET (\S+)} $::hbuf($s) -> path
	lappend ::hits $path
	set conf {<clientConfig version="1.1"><emailProvider id="x"><incomingServer type="imap"><hostname>imap.%EMAILDOMAIN%</hostname><port>993</port><socketType>SSL</socketType><username>%EMAILADDRESS%</username></incomingServer><outgoingServer type="smtp"><hostname>smtp.%EMAILDOMAIN%</hostname><port>465</port><socketType>SSL</socketType></outgoingServer></emailProvider></clientConfig>}
	set out "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
	if {[string match /auto/a.test/* $path]} {
		set out "HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: [string length $conf]\r\n\r\n$conf"
	} elseif {[string match /auto/r.test/* $path]} {
		set out "HTTP/1.1 302 Found\r\nLocation: /moved/r.test\r\nContent-Length: 0\r\n\r\n"
	} elseif {[string match /moved/r.test $path]} {
		# chunked, in two parts
		set a [string range $conf 0 99]; set b [string range $conf 100 end]
		set out "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n[format %x [string length $a]]\r\n$a\r\n[format %x [string length $b]]\r\n$b\r\n0\r\n\r\n"
	} elseif {[string match /auto/n.test/* $path]} {
		# a user name with line breaks (the accounts file is one line per key)
		set c [string map {<username>%EMAILADDRESS%</username> "<username>%EMAILADDRESS%\n\[x@evil.test\]\nimap=evil.test 993 tls</username>"} $conf]
		set out "HTTP/1.1 200 OK\r\nContent-Length: [string length $c]\r\n\r\n$c"
	} elseif {$path eq "/ispdb/hosting.example"} {
		set c [string map {%EMAILDOMAIN% hosting.example} $conf]
		set out "HTTP/1.1 200 OK\r\nContent-Length: [string length $c]\r\n\r\n$c"
	}
	puts -nonewline $s $out
	close $s
}
set hsrv [socket -server http_conn -myaddr 127.0.0.1 0]
set hport [lindex [fconfigure $hsrv -sockname] 2]

# DNS: SRV for s.test, MX for g.test (Google) and h.test (a host whose provider is in the ISPDB)
proc dns_name {n} { set o ""; foreach l [split $n .] { append o [binary format c [string length $l]]$l }; return $o\0 }
proc dns_conn {s args} {
	fconfigure $s -translation binary -blocking 0
	set ::dbuf($s) ""
	fileevent $s readable [list dns_read $s]
}
proc dns_read {s} {
	append ::dbuf($s) [read $s]
	if {[string length $::dbuf($s)] < 2} { if {[eof $s]} { close $s }; return }
	binary scan $::dbuf($s) S len
	if {[string length $::dbuf($s)] < $len + 2} return
	set q [string range $::dbuf($s) 2 [expr {$len + 1}]]
	binary scan $q S id
	# the question: name and type
	set pos 12; set labels {}
	while {[binary scan $q @${pos}cu n] && $n} { lappend labels [string range $q [expr {$pos + 1}] [expr {$pos + $n}]]; incr pos [expr {$n + 1}] }
	binary scan $q @[expr {$pos + 1}]S type
	set name [join $labels .]
	lappend ::dnsq "$name $type"
	set ans {}
	switch -- "$name $type" {
		"_imaps._tcp.s.test 33" { lappend ans [binary format SSS 0 1 993][dns_name mail.s.test] }
		"_submissions._tcp.s.test 33" { lappend ans [binary format SSS 0 1 0][dns_name .] }
		"_submission._tcp.s.test 33" { lappend ans [binary format SSS 0 1 587][dns_name mail.s.test] }
		"g.test 15" { lappend ans [binary format S 10][dns_name alt1.aspmx.l.google.com] [binary format S 1][dns_name aspmx.l.google.com] }
		"_imaps._tcp.t.test 33" { lappend ans [binary format S 0] }
		"h.test 15" { lappend ans [binary format S 5][dns_name mx1.hosting.example] }
	}
	set r [binary format SSSSSS $id 0x8180 1 [llength $ans] 0 0][string range $q 12 [expr {$pos + 4}]]
	foreach a $ans {
		# the answer's name is a pointer to the question's
		append r [binary format SSSIS 0xc00c $type 1 300 [string length $a]]$a
	}
	puts -nonewline $s [binary format S [string length $r]]$r
	close $s
}
set dsrv [socket -server dns_conn -myaddr 127.0.0.1 0]
set dport [lindex [fconfigure $dsrv -sockname] 2]

set mail::accounts::urls [list http://127.0.0.1:$hport/auto/%D/config?emailaddress=%E]
set mail::accounts::ispdb http://127.0.0.1:$hport/ispdb/%D
set mail::accounts::nameservers [list 127.0.0.1:$dport]
proc detect {email} {
	set ::found ""
	set ::hits {}; set ::dnsq {}
	mail::accounts::detect $email {apply {{r} { set ::found [list r $r] }}}
	until {$::found ne ""} 20000
	return [lindex $::found 1]
}
set r [detect maya@gmail.com]
ok {[dict get $r imap] eq {imap.gmail.com 993 tls} && [dict get $r smtp] eq {smtp.gmail.com 465 tls} && [dict get $r source] eq "gmail" && ![llength $::hits] && ![llength $::dnsq]} \
	"a named provider's domain needs no lookup"
set r [detect "anna+x@a.test"]
ok {[dict get $r imap] eq {imap.a.test 993 tls} && [dict get $r smtp] eq {smtp.a.test 465 tls} && [dict get $r user] eq "anna+x@a.test" && [dict get $r source] eq "autoconfig"} \
	"the domain's autoconfig gives the servers and the user name"
ok {[lindex $::hits 0] eq "/auto/a.test/config?emailaddress=anna%2Bx%40a.test"} "with the address encoded in the query"
set r [detect bo@r.test]
ok {[dict get $r imap] eq {imap.r.test 993 tls} && [dict get $r source] eq "autoconfig"} "a redirect is followed and a chunked answer read"
set r [detect bo@s.test]
ok {[dict get $r imap] eq {mail.s.test 993 tls} && [dict get $r smtp] eq {mail.s.test 587 starttls} && [dict get $r source] eq "srv"} \
	"SRV records (RFC 6186/8314): _imaps, and _submission when _submissions says \".\""
set r [detect bo@g.test]
ok {[dict get $r imap] eq {imap.gmail.com 993 tls} && [dict get $r source] eq "gmail"} "an MX at Google gives Gmail's servers (lowest preference first)"
set r [detect bo@h.test]
ok {[dict get $r imap] eq {imap.hosting.example 993 tls} && [dict get $r source] eq "ispdb" && "/ispdb/hosting.example" in $::hits} \
	"an MX host's domain is looked up in the ISPDB"
set r [detect bo@nothing.test]
ok {[dict get $r imap] eq {imap.nothing.test 993 tls} && [dict get $r smtp] eq {smtp.nothing.test 465 tls} && [dict get $r source] eq "guess"} \
	"nothing answers: imap. and smtp. of the domain"
set r [detect bo@t.test]
ok {[dict get $r source] eq "guess"} "a cut-off SRV record in a DNS answer does not stop the lookup"
set r [detect bo@n.test]
ok {[dict get $r imap] eq {imap.n.test 993 tls} && [dict get $r user] eq "bo@n.test"} "an autoconfig user name with a line break is not taken"
ok {[mail::accounts::check [dict replace $d address new@lind.page user "maya\n\[x@evil.test\]"]] ne ""} \
	"a user name with a line break is refused (it would write a second account into the file)"
ok {[mail::accounts::check [dict replace $d address new@lind.page name "Maya\nimap=evil.test 993 tls"]] ne ""} "and so is a name with one"
set mail::accounts::nameservers [list 127.0.0.1:1]
set t0 [clock milliseconds]
set r [detect bo@nothing.test]
ok {[dict get $r source] eq "guess" && [clock milliseconds] - $t0 < 15000} "a name server that refuses the connection does not stop the lookup"
set mail::accounts::urls {https://autoconfig.%D/mail/config-v1.1.xml?emailaddress=%E}
set ::fr ""
coroutine fetchco apply {{} { set ::fr [list r [mail::accounts::Fetch http://example.invalid/x]] }}
until {$::fr ne ""}
ok {$::fr eq {r {}}} "plain HTTP to another computer is never fetched"

# ---- Test connection -----------------------------------------------------------------------------------------------------
set srv [open |[list [info nameofexecutable] [file join $here mail-fixture-server.tcl] -plainauth 1 2>@stderr] r+]
lappend pids {*}[pid $srv]
fconfigure $srv -buffering line
gets $srv line
lassign $line - - imap - - - smtp
set t [dict create user maya@lind.page imap [list 127.0.0.1 $imap none] smtp [list 127.0.0.1 $smtp none]]
proc test {d pw} {
	set ::tested ""
	mail::accounts::test $d $pw {apply {{r} { set ::tested [list r $r] }}}
	until {$::tested ne ""} 30000
	return [lindex $::tested 1]
}
set r [test $t $pw]
ok {[dict get $r imap] eq "ok" && [dict get $r smtp] eq "ok"} "Test connection logs in to IMAP and SMTP"
set r [test $t wrong]
ok {[lindex [dict get $r imap] 1] eq "auth" && [lindex [dict get $r smtp] 1] eq "auth"} "a wrong password: both say auth"
set r [test [dict replace $t imap [list 127.0.0.1 1 none]] $pw]
ok {[lindex [dict get $r imap] 1] eq "connect" && [dict get $r smtp] eq "ok"} "a closed port: connect, the other server still answers"

close $srv
cleanup
file delete -force $T
if {$fails} { puts "accounts: $fails failed"; exit 1 }
puts "accounts: ok"
exit 0
