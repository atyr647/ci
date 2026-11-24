# net.tcl - the connection under Mail's IMAP and SMTP clients: an event-driven, non-blocking TCP connection that
# is TLS from the start (IMAPS 993, SMTPS 465) or upgraded with STARTTLS (IMAP 143, submission 587). Nothing here
# waits: the name is looked up by a `getent ahosts` child process, the connect is asynchronous, the TLS handshake
# is driven from fileevents, and every step has a deadline.
#
#   mail::net::connect HOST PORT SECURITY OPTS CMD   a new connection id; CMD is called later with "ok ID" or
#                                                    "error KIND MESSAGE". SECURITY is tls, starttls (plain until
#                                                    mail::net::starttls) or none, which only a loopback host may use.
#                                                    OPTS: -cafile FILE (the CAs to trust; default the system's
#                                                    /etc/ssl/certs), -timeout MS (connect and handshake, 30000)
#   mail::net::reader ID CMD     CMD is called with "data BYTES" for each chunk read, "eof {}" when the peer closes
#                                and "error MESSAGE" on a read or write error
#   mail::net::send ID BYTES     queues bytes; they go out as the socket takes them
#   mail::net::starttls ID CMD   the TLS handshake on a connection that is plain so far; CMD gets "ok ID" or
#                                "error tls MESSAGE". Refused if bytes the peer sent are still unread (RFC 3207/2595:
#                                anything sent before the handshake is an injection)
#   mail::net::pending ID        bytes still queued to go out
#   mail::net::secure ID         1 once the connection is TLS
#   mail::net::peer ID           the host name the connection was made to
#   mail::net::sockname ID       the local address
#   mail::net::close ID
#
# Error kinds: resolve (the name has no address), connect (refused, unreachable, timed out), tls (no tls package,
# handshake failed, certificate not trusted or not for this host), insecure (plain text to a remote host).
#
# Certificates: the chain must verify against the CAs (-require), and the host name must be one of the certificate's
# subjectAltName DNS names (a "*." wildcard covers one leftmost label) or, for an address, one of its IP addresses.
# The common name is not used (RFC 6125). TLS 1.2 is the oldest version offered.

namespace eval ::mail::net {
	variable seq 0
	variable conns           ;# array: id -> dict
	array set conns {}
	variable cadir /etc/ssl/certs
}

proc ::mail::net::loopback {host} {
	set h [string tolower [string trimright $host .]]
	expr {$h eq "localhost" || $h eq "::1" || [regexp {^127\.\d+\.\d+\.\d+$} $h]}
}

proc ::mail::net::is_ip {host} {
	expr {[regexp {^\d+\.\d+\.\d+\.\d+$} $host] || [string first : $host] >= 0}
}

proc ::mail::net::connect {host port security opts cmd} {
	variable seq
	variable conns
	if {$security ni {tls starttls none}} { error "security must be tls, starttls or none" }
	set id mailnet[incr seq]
	set o [dict merge {-cafile "" -timeout 30000} $opts]
	set conns($id) [dict create host $host port $port security $security cafile [dict get $o -cafile] \
		timeout [dict get $o -timeout] cmd $cmd sock "" secure 0 reader "" out "" addrs {} timer "" pipe "" \
]
	# the name goes to getent as a word of a command pipeline, where one starting with < > | or 2> would be a
	# redirection (">~/.profile" truncates that file) and one starting with - an option: only a host name's letters
	if {![is_ip $host] && ![regexp {^[[:alnum:]_][[:alnum:]._-]*$} $host]} {
		after 0 [list ::mail::net::Fail $id resolve "\"$host\" is not a host name"]
		return $id
	}
	if {$security eq "none" && ![loopback $host]} {
		after 0 [list ::mail::net::Fail $id insecure "plain text is only allowed to this computer; choose SSL/TLS or STARTTLS"]
		return $id
	}
	if {$security eq "tls" && [catch {package require tls}]} {
		after 0 [list ::mail::net::Fail $id tls "TLS is not available (the Tcl tls package is missing)"]
		return $id
	}
	Arm $id
	if {[is_ip $host]} {
		dict set conns($id) addrs [list $host]
		after 0 [list ::mail::net::Next $id]
	} else {
		Resolve $id
	}
	return $id
}

# a deadline for the current step; Fail when it passes
proc ::mail::net::Arm {id} {
	variable conns
	if {![info exists conns($id)]} return
	after cancel [dict get $conns($id) timer]
	dict set conns($id) timer [after [dict get $conns($id) timeout] [list ::mail::net::Timeout $id]]
}
proc ::mail::net::Disarm {id} {
	variable conns
	if {![info exists conns($id)]} return
	after cancel [dict get $conns($id) timer]
	dict set conns($id) timer ""
}
proc ::mail::net::Timeout {id} {
	variable conns
	if {![info exists conns($id)]} return
	set host [dict get $conns($id) host]
	Fail $id connect "$host did not answer in time"
}

# ---- name lookup without blocking: getent ahosts in a child process ------------------------------------------
proc ::mail::net::Resolve {id} {
	variable conns
	set host [dict get $conns($id) host]
	set getent [auto_execok getent]
	if {$getent eq "" || [catch {::open [list | {*}$getent ahosts $host 2>/dev/null] r} pipe]} {
		# no getent: Tcl's own lookup (it blocks while it looks)
		dict set conns($id) addrs [list $host]
		after 0 [list ::mail::net::Next $id]
		return
	}
	fconfigure $pipe -blocking 0 -translation lf
	dict set conns($id) pipe $pipe
	dict set conns($id) gbuf ""
	fileevent $pipe readable [list ::mail::net::Resolved $id $pipe]
}
proc ::mail::net::Resolved {id pipe} {
	variable conns
	if {![info exists conns($id)]} { catch {::close $pipe}; return }
	set chunk [read $pipe]
	dict append conns($id) gbuf $chunk
	if {![eof $pipe]} return
	fconfigure $pipe -blocking 1
	catch {::close $pipe}
	dict set conns($id) pipe ""
	set addrs {}
	foreach line [split [dict get $conns($id) gbuf] \n] {
		if {[llength $line] >= 2 && [lindex $line 1] eq "STREAM" && [lindex $line 0] ni $addrs} {
			lappend addrs [lindex $line 0]
		}
	}
	if {![llength $addrs]} {
		Fail $id resolve "[dict get $conns($id) host] was not found"
		return
	}
	# IPv4 first: a host that has an AAAA record but no IPv6 route would otherwise wait out the timeout
	set v4 [lsearch -all -inline -regexp $addrs {^\d+\.}]
	set v6 [lsearch -all -inline -not -regexp $addrs {^\d+\.}]
	dict set conns($id) addrs [concat $v4 $v6]
	Next $id
}

# try the next address
proc ::mail::net::Next {id {why ""}} {
	variable conns
	if {![info exists conns($id)]} return
	set addrs [dict get $conns($id) addrs]
	if {![llength $addrs]} {
		set host [dict get $conns($id) host]
		Fail $id connect [expr {$why ne "" ? "$host: $why" : "could not connect to $host"}]
		return
	}
	dict set conns($id) addrs [lrange $addrs 1 end]
	set a [lindex $addrs 0]
	if {[catch {socket -async $a [dict get $conns($id) port]} s]} {
		after 0 [list ::mail::net::Next $id $s]
		return
	}
	dict set conns($id) sock $s
	fconfigure $s -blocking 0 -translation binary -buffering none
	fileevent $s writable [list ::mail::net::Connected $id $s]
}
proc ::mail::net::Connected {id s} {
	variable conns
	if {![info exists conns($id)]} return
	fileevent $s writable {}
	set err [fconfigure $s -error]
	if {$err ne ""} {
		catch {::close $s}
		dict set conns($id) sock ""
		Next $id $err
		return
	}
	if {[dict get $conns($id) security] eq "tls"} {
		Handshake $id [list ::mail::net::Ready $id]
	} else {
		Ready $id
	}
}
proc ::mail::net::Ready {id args} {
	variable conns
	if {![info exists conns($id)]} return
	if {[llength $args] && [lindex $args 0] eq "error"} {
		Fail $id {*}[lrange $args 1 end]
		return
	}
	Disarm $id
	set cmd [dict get $conns($id) cmd]
	# reading starts when mail::net::reader names who takes the bytes
	after 0 [list {*}$cmd ok $id]
}

proc ::mail::net::Fail {id kind msg} {
	variable conns
	if {![info exists conns($id)]} return
	set cmd [dict get $conns($id) cmd]
	Drop $id
	{*}$cmd error $kind $msg
}

# ---- TLS --------------------------------------------------------------------------------------------------------
proc ::mail::net::TlsOpts {id} {
	variable conns
	variable cadir
	set host [dict get $conns($id) host]
	set o [list -require 1 -request 1 -ssl2 0 -ssl3 0 -tls1 0 -tls1.1 0 -tls1.2 1 -tls1.3 1 -command ::mail::net::TlsCb]
	set ca [dict get $conns($id) cafile]
	if {$ca ne ""} { lappend o -cafile $ca } else { lappend o -cadir $cadir }
	if {![is_ip $host]} { lappend o -servername $host }
	return $o
}

# tls's callback: the chain check keeps OpenSSL's verdict (the status), and its messages are not printed on stderr
# (the handshake error says what went wrong)
proc ::mail::net::TlsCb {option args} {
	if {$option eq "verify"} { return [lindex $args 3] }
	return 1
}

proc ::mail::net::Handshake {id done} {
	variable conns
	set s [dict get $conns($id) sock]
	if {[catch {tls::import $s {*}[TlsOpts $id]} err]} {
		{*}$done error tls "TLS could not start: $err"
		return
	}
	fconfigure $s -blocking 0 -translation binary -buffering none
	dict set conns($id) hsdone $done
	Shake $id
}
proc ::mail::net::Shake {id} {
	variable conns
	if {![info exists conns($id)]} return
	set s [dict get $conns($id) sock]
	set done [dict get $conns($id) hsdone]
	if {[catch {tls::handshake $s} r]} {
		fileevent $s readable {}
		fileevent $s writable {}
		regsub {^handshake failed: } $r {} r
		{*}$done error tls "the secure connection to [dict get $conns($id) host] failed: $r"
		return
	}
	if {!$r} {
		fileevent $s readable [list ::mail::net::Shake $id]
		return
	}
	fileevent $s readable {}
	fileevent $s writable {}
	set host [dict get $conns($id) host]
	set st [tls::status $s]
	set names [cert_names [dict get $st certificate]]
	if {![host_matches $host $names]} {
		set shown [join [lmap n $names {lindex $n 1}] ", "]
		{*}$done error tls "the certificate is for [expr {$shown eq "" ? "no host name" : $shown}], not $host"
		return
	}
	dict set conns($id) secure 1
	{*}$done ok
}

proc ::mail::net::starttls {id cmd} {
	variable conns
	if {![info exists conns($id)]} { after 0 [list {*}$cmd error connect "the connection is closed"]; return }
	if {[catch {package require tls}]} {
		after 0 [list ::mail::net::StartFail $id $cmd "TLS is not available (the Tcl tls package is missing)"]
		return
	}
	set s [dict get $conns($id) sock]
	fileevent $s readable {}
	if {[chan pending input $s] > 0} {
		after 0 [list ::mail::net::StartFail $id $cmd "the server sent data before the secure connection started"]
		return
	}
	Arm $id
	Handshake $id [list ::mail::net::Upgraded $id $cmd]
}
proc ::mail::net::StartFail {id cmd msg} {
	Drop $id
	{*}$cmd error tls $msg
}
proc ::mail::net::Upgraded {id cmd args} {
	variable conns
	if {![info exists conns($id)]} return
	if {[lindex $args 0] eq "error"} {
		Drop $id
		{*}$cmd error {*}[lrange $args 1 end]
		return
	}
	Disarm $id
	if {[dict get $conns($id) reader] ne ""} {
		fileevent [dict get $conns($id) sock] readable [list ::mail::net::Readable $id]
	}
	{*}$cmd ok $id
}

# ---- reading and writing --------------------------------------------------------------------------------------
proc ::mail::net::reader {id cmd} {
	variable conns
	dict set conns($id) reader $cmd
	fileevent [dict get $conns($id) sock] readable [list ::mail::net::Readable $id]
}

proc ::mail::net::Readable {id} {
	variable conns
	if {![info exists conns($id)]} return
	set s [dict get $conns($id) sock]
	set cmd [dict get $conns($id) reader]
	if {[catch {read $s} data]} {
		Drop $id
		if {$cmd ne ""} { {*}$cmd error $data }
		return
	}
	if {$data ne "" && $cmd ne ""} { {*}$cmd data $data }
	if {![info exists conns($id)]} return
	if {[eof $s]} {
		Drop $id
		if {$cmd ne ""} { {*}$cmd eof {} }
	}
}

proc ::mail::net::send {id bytes} {
	variable conns
	if {![info exists conns($id)]} { return 0 }
	set s [dict get $conns($id) sock]
	if {[catch {puts -nonewline $s $bytes; flush $s} err]} {
		set cmd [dict get $conns($id) reader]
		Drop $id
		if {$cmd ne ""} { after 0 [list {*}$cmd error $err] }
		return 0
	}
	return 1
}

# bytes queued to go out (a large APPEND or DATA on a slow link): a reply deadline waits while this shrinks
proc ::mail::net::pending {id} {
	variable conns
	if {![info exists conns($id)]} { return 0 }
	if {[catch {chan pending output [dict get $conns($id) sock]} n]} { return 0 }
	return $n
}

proc ::mail::net::secure {id} {
	variable conns
	expr {[info exists conns($id)] && [dict get $conns($id) secure]}
}
proc ::mail::net::peer {id} {
	variable conns
	dict get $conns($id) host
}
proc ::mail::net::sockname {id} {
	variable conns
	if {![info exists conns($id)]} { return "" }
	lindex [fconfigure [dict get $conns($id) sock] -sockname] 0
}
proc ::mail::net::alive {id} {
	variable conns
	info exists conns($id)
}

proc ::mail::net::Drop {id} {
	variable conns
	if {![info exists conns($id)]} return
	after cancel [dict get $conns($id) timer]
	set s [dict get $conns($id) sock]
	if {$s ne ""} {
		catch {fileevent $s readable {}}
		catch {fileevent $s writable {}}
		catch {::close $s}
	}
	set p [dict get $conns($id) pipe]
	if {$p ne ""} { catch {fconfigure $p -blocking 0}; catch {::close $p} }
	unset conns($id)
}
proc ::mail::net::close {id} { Drop $id }

# ---- the certificate's names: subjectAltName out of the DER -----------------------------------------------------
# returns {dns NAME} and {ip ADDRESS} pairs
proc ::mail::net::cert_names {pem} {
	if {![regexp -- {-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----} $pem -> b64]} { return {} }
	if {[catch {binary decode base64 [string map {\n "" \r "" " " ""} $b64]} der]} { return {} }
	set names {}
	if {[catch {
		lassign [Der $der 0] - cs cl                 ;# Certificate SEQUENCE
		lassign [Der $der $cs] - ts tl               ;# tbsCertificate SEQUENCE
		set p $ts
		set end [expr {$ts + $tl}]
		while {$p < $end} {
			lassign [Der $der $p] tag vs vl
			if {$tag == 0xA3} {
				lassign [Der $der $vs] - es el       ;# Extensions SEQUENCE
				set q $es
				while {$q < $es + $el} {
					lassign [Der $der $q] - xs xl    ;# Extension SEQUENCE
					lassign [Der $der $xs] otag os ol
					set oid [string range $der $os [expr {$os + $ol - 1}]]
					set r [expr {$os + $ol}]
					lassign [Der $der $r] t2 s2 l2
					if {$t2 == 0x01} { set r [expr {$s2 + $l2}]; lassign [Der $der $r] t2 s2 l2 }
					if {$oid eq "\x55\x1d\x11" && $t2 == 0x04} {
						lassign [Der $der $s2] - gs gl   ;# GeneralNames SEQUENCE
						set g $gs
						while {$g < $gs + $gl} {
							lassign [Der $der $g] gt vs2 vl2
							set v [string range $der $vs2 [expr {$vs2 + $vl2 - 1}]]
							if {$gt == 0x82} { lappend names [list dns [string tolower $v]] }
							if {$gt == 0x87} { lappend names [list ip [IpText $v]] }
							set g [expr {$vs2 + $vl2}]
						}
					}
					set q [expr {$xs + $xl}]
				}
			}
			set p [expr {$vs + $vl}]
		}
	}]} { return {} }
	return $names
}
# one DER header at POS: {tag valuestart valuelength}
proc ::mail::net::Der {der pos} {
	binary scan [string index $der $pos] cu tag
	binary scan [string index $der [expr {$pos + 1}]] cu len
	set p [expr {$pos + 2}]
	if {$len & 0x80} {
		set n [expr {$len & 0x7f}]
		if {$n < 1 || $n > 4} { error "bad DER length" }
		set len 0
		for {set i 0} {$i < $n} {incr i} {
			binary scan [string index $der $p] cu b
			set len [expr {($len << 8) | $b}]
			incr p
		}
	}
	if {$p + $len > [string length $der]} { error "DER runs past its end" }
	list $tag $p $len
}
proc ::mail::net::IpText {bytes} {
	if {[string length $bytes] == 4} {
		binary scan $bytes cu4 b
		return [join $b .]
	}
	if {[string length $bytes] == 16} {
		binary scan $bytes Su8 w
		return [Ip6Norm [join [lmap x $w {format %x $x}] :]]
	}
	return ""
}
# an IPv6 address in one spelling (eight groups, no leading zeros) so that two spellings compare equal
proc ::mail::net::Ip6Norm {a} {
	set a [string tolower [string trim $a {[]}]]
	if {[string first :: $a] >= 0} {
		lassign [split [string map {:: |} $a] |] l r
		set lg [expr {$l eq "" ? {} : [split $l :]}]
		set rg [expr {$r eq "" ? {} : [split $r :]}]
		set g [concat $lg [lrepeat [expr {8 - [llength $lg] - [llength $rg]}] 0] $rg]
	} else {
		set g [split $a :]
	}
	join [lmap x $g {format %x [scan $x %x]}] :
}

# does HOST match one of NAMES (from cert_names)?
proc ::mail::net::host_matches {host names} {
	set h [string tolower [string trimright $host .]]
	if {[is_ip $h]} {
		set want [expr {[string first : $h] >= 0 ? [Ip6Norm $h] : $h}]
		foreach n $names {
			if {[lindex $n 0] eq "ip" && [lindex $n 1] eq $want} { return 1 }
		}
		return 0
	}
	foreach n $names {
		lassign $n kind pat
		if {$kind ne "dns"} continue
		set pat [string trimright $pat .]
		if {$pat eq $h} { return 1 }
		# "*.example.com" covers exactly one label, and never a bare suffix or a public suffix like "*.com"
		if {[string match {\*.*} $pat] && [llength [split $pat .]] >= 3} {
			set rest [string range $pat 2 end]
			set dot [string first . $h]
			if {$dot > 0 && [string range $h [expr {$dot + 1}] end] eq $rest} { return 1 }
		}
	}
	return 0
}
