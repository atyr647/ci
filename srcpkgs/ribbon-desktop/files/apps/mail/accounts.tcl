# accounts.tcl - Mail's accounts provider (U42): the accounts Mail syncs, their servers, and their passwords in the
# Secret Service (secrets.tcl; decisions 47 and 48: app passwords over IMAP/SMTP, never in files; OAuth later).
# main.tcl sources it; the Add an account sheet (Mail-A6-Account) is ui-account.tcl, read when Tk is there.
#
#   mail::accounts::configured        {NAME OPTS ...} in the file's order. OPTS: -address -fullname, -imap and
#                                     -smtp for mail::sync::start ({-host -port -security -user}), -password (the
#                                     Secret Service lookup, called as "CMD NAME")
#   mail::accounts::password NAME     the account's password from the Secret Service (an error when it has none)
#   mail::accounts::add D PASSWORD    saves a new account: D has name address user imap smtp ({HOST PORT SECURITY});
#                                     the password goes to the Secret Service first, then the account to the file.
#                                     The account's name is its address. Errors are Tcl errors with a message for
#                                     the sheet
#   mail::accounts::check D           "" or what is wrong with D (empty fields, a bad port, a taken address)
#   mail::accounts::test D PASSWORD CMD   logs in to both servers (mail::imap::probe, mail::smtp::probe) at once;
#                                     CMD gets {imap RESULT smtp RESULT}, RESULT "ok" or {error KIND MESSAGE}
#   mail::accounts::detect EMAIL CMD  finds the servers for an address; CMD gets {imap {H P S} smtp {H P S} user U
#                                     source SRC}, or "" when nothing answers. In order: the providers the sheet
#                                     names (no lookup), the domain's own autoconfig (https://autoconfig.DOMAIN/ and
#                                     https://DOMAIN/.well-known/autoconfig/, Thunderbird's config-v1.1 format),
#                                     Thunderbird's ISPDB, the domain's SRV records (RFC 6186, RFC 8314), its MX
#                                     host's provider (a named one, then the ISPDB), and last imap./smtp.DOMAIN
#   mail::accounts::provider KEY      a named provider's servers: {name N imap {H P S} smtp {H P S} domains {...}}
#
# The file: $XDG_CONFIG_HOME/ribbon/mail-accounts.conf (~/.config/ribbon/mail-accounts.conf), mode 0600, one
# section per account named by its address:
#     [maya@lind.page]
#     name=Maya Lind
#     address=maya@lind.page
#     user=maya@lind.page
#     imap=imap.lind.page 993 tls
#     smtp=smtp.lind.page 465 tls
# SECURITY is tls (from the start: IMAPS, SMTPS), starttls or none (only for a server on this computer).
# The Secret Service item of an account has the attributes xdg:schema=org.ribbon.Mail and account=NAME.
#
# Lookups: HTTPS through mail::net (TLS 1.2+, the certificate checked against the host name; plain HTTP only to
# this computer), DNS over TCP to the resolv.conf name servers. For the tests: mail::accounts::urls (the autoconfig
# URL templates, %D the domain, %E the address), mail::accounts::nameservers ({HOST:PORT ...}) and
# mail::accounts::conf_file (the file).

if {[info commands ::mail::net::connect] eq ""} { source [file join [file dirname [info script]] net.tcl] }
if {[info commands ::mail::imap::probe] eq ""} { source [file join [file dirname [info script]] imap.tcl] }
if {[info commands ::mail::smtp::probe] eq ""} { source [file join [file dirname [info script]] smtp.tcl] }
source [file join [file dirname [info script]] secrets.tcl]

namespace eval ::mail::accounts {
	variable conf_file ""
	variable urls {
		https://autoconfig.%D/mail/config-v1.1.xml?emailaddress=%E
		https://%D/.well-known/autoconfig/mail/config-v1.1.xml?emailaddress=%E
		https://autoconfig.thunderbird.net/v1.1/%D
	}
	variable ispdb https://autoconfig.thunderbird.net/v1.1/%D
	variable nameservers ""
	variable timeout 8000
	variable seq 0
	variable providers {
		gmail {name Gmail imap {imap.gmail.com 993 tls} smtp {smtp.gmail.com 465 tls}
			domains {gmail.com googlemail.com} mx {google.com googlemail.com}}
		outlook {name Outlook imap {outlook.office365.com 993 tls} smtp {smtp-mail.outlook.com 587 starttls}
			domains {outlook.com hotmail.com live.com msn.com outlook.de outlook.fr hotmail.co.uk hotmail.de hotmail.fr live.co.uk}
			mx {outlook.com}}
		fastmail {name Fastmail imap {imap.fastmail.com 993 tls} smtp {smtp.fastmail.com 465 tls}
			domains {fastmail.com fastmail.fm fastmail.net fastmail.org fastmail.to fastmail.us} mx {messagingengine.com}}
		icloud {name iCloud imap {imap.mail.me.com 993 tls} smtp {smtp.mail.me.com 587 starttls}
			domains {icloud.com me.com mac.com} mx {icloud.com}}
	}
}

# ---- the file ------------------------------------------------------------------------------------------------------
proc ::mail::accounts::File {} {
	variable conf_file
	if {$conf_file ne ""} { return $conf_file }
	set base [expr {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne "" ? $::env(XDG_CONFIG_HOME) : [file join $::env(HOME) .config]}]
	file join $base ribbon mail-accounts.conf
}

# {NAME {key value ...} ...} as the file has them
proc ::mail::accounts::Read {} {
	set out {}
	if {[catch {set fh [::open [File] r]}]} { return {} }
	fconfigure $fh -encoding utf-8
	set text [::read $fh]
	::close $fh
	set cur ""
	foreach line [split $text \n] {
		set line [string trim $line]
		if {$line eq "" || [string match {[#;]*} $line]} continue
		if {[regexp {^\[(.+)\]$} $line -> name]} {
			set cur $name
			if {![dict exists $out $cur]} { dict set out $cur {} }
			continue
		}
		if {$cur eq "" || ![regexp {^([A-Za-z-]+)\s*=\s*(.*)$} $line -> k v]} continue
		dict set out $cur [string tolower $k] $v
	}
	return $out
}

proc ::mail::accounts::Write {accts} {
	set f [File]
	file mkdir [file dirname $f]
	set text "# Ribbon Mail's accounts. The passwords are in the Secret Service (org.freedesktop.secrets), not here.\n"
	dict for {name d} $accts {
		append text "\n\[$name\]\n"
		foreach k {name address user imap smtp} { if {[dict exists $d $k]} { append text "$k=[dict get $d $k]\n" } }
	}
	set tmp $f.tmp[pid]
	set fh [::open $tmp {WRONLY CREAT TRUNC} 0600]
	fconfigure $fh -encoding utf-8 -translation lf
	puts -nonewline $fh $text
	::close $fh
	file rename -force $tmp $f
}

# "HOST PORT SECURITY" -> {-host H -port P -security S -user U}, or "" when it is not one
proc ::mail::accounts::Server {spec user} {
	if {[catch {lassign $spec host port sec}] || [llength $spec] != 3} { return "" }
	if {$host eq "" || ![string is integer -strict $port] || $port < 1 || $port > 65535 || $sec ni {tls starttls none}} { return "" }
	dict create -host $host -port $port -security $sec -user $user
}

proc ::mail::accounts::configured {} {
	set out {}
	dict for {name d} [Read] {
		set addr [expr {[dict exists $d address] ? [dict get $d address] : $name}]
		set user [expr {[dict exists $d user] ? [dict get $d user] : $addr}]
		set o [dict create -address $addr -fullname [expr {[dict exists $d name] ? [dict get $d name] : ""}]]
		set imap [expr {[dict exists $d imap] ? [Server [dict get $d imap] $user] : ""}]
		set smtp [expr {[dict exists $d smtp] ? [Server [dict get $d smtp] $user] : ""}]
		# an account whose servers the file does not give in full is shown, not synced
		if {$imap ne "" && $smtp ne ""} {
			dict set o -imap $imap
			dict set o -smtp $smtp
			dict set o -password ::mail::accounts::password
		}
		dict set out $name $o
	}
	return $out
}

proc ::mail::accounts::Attrs {name} {
	dict create xdg:schema org.ribbon.Mail account $name
}

proc ::mail::accounts::password {name} {
	mail::secrets::lookup [Attrs $name]
}

proc ::mail::accounts::provider {key} {
	variable providers
	dict get $providers $key
}

# ---- adding ----------------------------------------------------------------------------------------------------------
proc ::mail::accounts::valid_address {a} {
	regexp {^[^@\s<>(),;:"\[\]\\]+@[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$} $a
}

proc ::mail::accounts::valid_host {h} {
	expr {[regexp {^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*\.?$} $h] ||
		[regexp {^\d+\.\d+\.\d+\.\d+$} $h] || [regexp {^[0-9A-Fa-f:]+$} $h]}
}

proc ::mail::accounts::check {d} {
	set addr [string trim [dict get $d address]]
	if {![valid_address $addr]} { return "The email address is not complete" }
	if {[string trim [dict get $d user]] eq ""} { return "The user name is empty" }
	# the accounts file has one line per key: a line break would start another key or account
	if {[regexp {[[:cntrl:]]} [string trim [dict get $d user]]]} { return "The user name is not one line" }
	if {[regexp {[[:cntrl:]]} [string trim [dict get $d name]]]} { return "The name is not one line" }
	foreach k {imap smtp} w {IMAP SMTP} {
		lassign [dict get $d $k] host port sec
		if {![valid_host $host]} { return "The $w server is not a host name" }
		if {![string is integer -strict $port] || $port < 1 || $port > 65535} { return "The $w port is not a port number" }
		if {$sec eq "none" && ![mail::net::loopback $host]} { return "The $w server needs SSL/TLS or STARTTLS" }
	}
	foreach n [dict keys [Read]] { if {[string equal -nocase $n $addr]} { return "$addr is in Mail already" } }
	return ""
}

proc ::mail::accounts::add {d pw} {
	set msg [check $d]
	if {$msg ne ""} { error $msg }
	set name [string trim [dict get $d address]]
	if {[catch {mail::secrets::store [Attrs $name] "Mail: $name" $pw} err]} { error "The password could not be saved: $err" }
	set all [Read]
	dict set all $name [dict create name [string trim [dict get $d name]] address $name user [string trim [dict get $d user]] \
		imap [join [dict get $d imap]] smtp [join [dict get $d smtp]]]
	if {[catch {Write $all} err]} {
		catch {mail::secrets::clear [Attrs $name]}
		error "The account could not be saved: $err"
	}
	return $name
}

# ---- Test connection -------------------------------------------------------------------------------------------------
proc ::mail::accounts::test {d pw cmd} {
	variable seq
	set id t[incr seq]
	variable T
	set T($id) [dict create imap "" smtp "" cmd $cmd]
	set user [string trim [dict get $d user]]
	foreach k {imap smtp} {
		lassign [dict get $d $k] host port sec
		set o [dict create -host $host -port $port -security $sec -user $user -password $pw -timeout 20000]
		if {[catch {mail::${k}::probe $o [list ::mail::accounts::Tested $id $k]} err]} {
			after 0 [list ::mail::accounts::Tested $id $k error protocol $err]
		}
	}
	return $id
}
proc ::mail::accounts::Tested {id k status args} {
	variable T
	if {![info exists T($id)]} return
	dict set T($id) $k [expr {$status eq "ok" ? "ok" : [list error {*}$args]}]
	if {[dict get $T($id) imap] eq "" || [dict get $T($id) smtp] eq ""} return
	set r [dict filter $T($id) key imap smtp]
	set cmd [dict get $T($id) cmd]
	unset T($id)
	{*}$cmd $r
}

# ---- finding the servers ---------------------------------------------------------------------------------------------
proc ::mail::accounts::detect {email cmd} {
	variable seq
	set co ::mail::accounts::detect[incr seq]
	coroutine $co ::mail::accounts::Detect $email $cmd
	return $co
}

proc ::mail::accounts::Detect {email cmd} {
	variable providers
	variable urls
	variable ispdb
	set email [string trim $email]
	set domain [string tolower [lindex [split $email @] end]]
	set r ""
	dict for {k p} $providers {
		if {$domain in [dict get $p domains]} { set r [dict create imap [dict get $p imap] smtp [dict get $p smtp] user $email source $k] }
	}
	if {$r eq ""} {
		foreach u $urls {
			set url [string map [list %D $domain %E [Urlenc $email]] $u]
			set r [Autoconfig $url $email]
			if {$r ne ""} { dict set r source autoconfig; break }
		}
	}
	if {$r eq ""} {
		set r [Srv $domain $email]
	}
	if {$r eq ""} {
		# the domain's mail is handled by a provider (Google Workspace, Microsoft 365, Fastmail ...)
		set mx [lindex [Dns $domain 15] 0]
		if {$mx ne ""} {
			set labels [split [string tolower [string trimright [lindex $mx 1] .]] .]
			foreach n {2 3} {
				if {[llength $labels] < $n} continue
				set base [join [lrange $labels end-[expr {$n - 1}] end] .]
				dict for {k p} $providers {
					if {$base in [dict get $p mx]} { set r [dict create imap [dict get $p imap] smtp [dict get $p smtp] user $email source $k] }
				}
				if {$r ne ""} break
				set r [Autoconfig [string map [list %D $base] $ispdb] $email]
				if {$r ne ""} { dict set r source ispdb; break }
			}
		}
	}
	if {$r eq ""} {
		set r [dict create imap [list imap.$domain 993 tls] smtp [list smtp.$domain 465 tls] user $email source guess]
	}
	after 0 [list {*}$cmd $r]
}

proc ::mail::accounts::Urlenc {s} {
	set out ""
	foreach b [split [encoding convertto utf-8 $s] ""] {
		if {[string match {[A-Za-z0-9._~-]} $b]} { append out $b } else { append out [format %%%02X [scan $b %c]] }
	}
	return $out
}

# Thunderbird's config-v1.1: the first IMAP and SMTP servers that take a password (TLS preferred to STARTTLS)
proc ::mail::accounts::Autoconfig {url email} {
	set body [Fetch $url]
	if {$body eq ""} { return "" }
	parse_autoconfig [encoding convertfrom utf-8 $body] $email
}

proc ::mail::accounts::parse_autoconfig {xml email} {
	lassign [split $email @] local domain
	set map [list %EMAILADDRESS% $email %EMAILLOCALPART% $local %EMAILDOMAIN% $domain]
	set r [dict create]
	foreach {tag kind key} {incomingServer imap imap outgoingServer smtp smtp} {
		set best ""
		foreach {- attrs inner} [regexp -all -inline "<$tag\\s(\[^>\]*?)>(.*?)</$tag>" $xml] {
			if {![regexp "type\\s*=\\s*\[\"'\]$kind\[\"'\]" $attrs]} continue
			set f [dict create]
			foreach el {hostname port socketType username} {
				if {[regexp "<$el>(\[^<\]*)</$el>" $inner -> v]} { dict set f $el [string map $map [Unxml [string trim $v]]] }
			}
			set auths [lmap {- a} [regexp -all -inline {<authentication>([^<]*)</authentication>} $inner] {string trim $a}]
			if {![llength $auths]} { set auths password-cleartext }
			if {![llength [lsearch -all -inline -regexp $auths {^(password-cleartext|plain)$}]]} continue
			if {![dict exists $f hostname] || ![dict exists $f port] || ![string is integer -strict [dict get $f port]]} continue
			set sec [dict get {SSL tls TLS tls STARTTLS starttls plain none} [expr {[dict exists $f socketType] && [dict get $f socketType] in {SSL TLS STARTTLS plain} ? [dict get $f socketType] : "plain"}]]
			if {$sec eq "none"} continue
			set rank [expr {$sec eq "tls" ? 0 : 1}]
			if {$best eq "" || $rank < [lindex $best 0]} { set best [list $rank $f $sec] }
		}
		if {$best eq ""} { return "" }
		lassign $best - f sec
		dict set r $key [list [string tolower [dict get $f hostname]] [dict get $f port] $sec]
		# a user name is one line (the accounts file has one line per key)
		if {$kind eq "imap"} { dict set r user [expr {[dict exists $f username] && ![regexp {[[:cntrl:]]} [dict get $f username]] ? [dict get $f username] : $email}] }
	}
	return $r
}

proc ::mail::accounts::Unxml {s} {
	string map {&lt; < &gt; > &quot; \" &apos; ' &amp; &} $s
}

# RFC 6186 / RFC 8314: _imaps (or _imap, STARTTLS) and _submissions (or _submission, STARTTLS); a target of "."
# means the service is not offered
proc ::mail::accounts::Srv {domain email} {
	set r [dict create]
	foreach {key names} {imap {_imaps._tcp tls _imap._tcp starttls} smtp {_submissions._tcp tls _submission._tcp starttls}} {
		foreach {n sec} $names {
			set recs [lsort -integer -index 0 [Dns $n.$domain 33]]
			set rec [lindex $recs 0]
			if {$rec eq ""} continue
			lassign $rec prio weight port target
			set target [string trimright $target .]
			if {$target eq "" || $port == 0} continue
			dict set r $key [list [string tolower $target] $port $sec]
			break
		}
	}
	if {![dict exists $r imap] || ![dict exists $r smtp]} { return "" }
	dict set r user $email
	dict set r source srv
	return $r
}

# ---- HTTP GET over mail::net (inside the detect coroutine) -------------------------------------------------------------
# The body of a 200 answer, or "" (any failure). Redirects (up to 3) are followed to https, or to this computer.
proc ::mail::accounts::Fetch {url {hops 0}} {
	variable timeout
	if {![regexp {^(https?)://([^/:?#]+|\[[^\]]+\])(?::(\d+))?([^#]*)$} $url -> scheme host port path]} { return "" }
	set host [string trim $host {[]}]
	if {$port eq ""} { set port [expr {$scheme eq "https" ? 443 : 80}] }
	if {$path eq "" || [string index $path 0] eq "?"} { set path /$path }
	set co [info coroutine]
	set id [mail::net::connect $host $port [expr {$scheme eq "https" ? "tls" : "none"}] [list -timeout $timeout] \
		[list ::mail::accounts::Wake $co connected]]
	set timer [after [expr {$timeout * 2}] [list ::mail::accounts::Wake $co timeout]]
	lassign [yield] ev status cid
	if {$ev ne "connected" || $status ne "ok"} {
		after cancel $timer
		if {$ev eq "timeout"} { catch {mail::net::close $id} }
		return ""
	}
	set hostname [expr {[string first : $host] >= 0 ? "\[$host\]" : $host}]
	if {$port != ($scheme eq "https" ? 443 : 80)} { append hostname :$port }
	mail::net::reader $cid [list ::mail::accounts::Wake $co]
	mail::net::send $cid "GET $path HTTP/1.1\r\nHost: $hostname\r\nUser-Agent: Ribbon-Mail\r\nAccept: application/xml, text/xml\r\nConnection: close\r\n\r\n"
	set buf ""
	while 1 {
		set ev [yield]
		lassign $ev kind data
		if {$kind eq "data"} {
			append buf $data
			if {[string length $buf] > 1048576} { set buf ""; break }
			continue
		}
		if {$kind eq "timeout" || $kind eq "error"} { set buf "" }
		break
	}
	after cancel $timer
	catch {mail::net::close $cid}
	set end [string first "\r\n\r\n" $buf]
	if {$end < 0} { return "" }
	set head [split [string range $buf 0 [expr {$end - 1}]] \n]
	set body [string range $buf [expr {$end + 4}] end]
	if {![regexp {^HTTP/1\.[01] (\d\d\d)} [lindex $head 0] -> code]} { return "" }
	set h [dict create]
	foreach l [lrange $head 1 end] {
		if {[regexp {^([^:]+):\s*(.*?)\s*$} $l -> k v]} { dict set h [string tolower $k] $v }
	}
	if {$code in {301 302 303 307 308} && $hops < 3 && [dict exists $h location]} {
		set loc [dict get $h location]
		if {[string match /* $loc]} { set loc $scheme://$hostname$loc }
		if {[string match https://* $loc] || ([regexp {^http://([^/:]+)} $loc -> lh] && [mail::net::loopback $lh])} {
			return [Fetch $loc [expr {$hops + 1}]]
		}
		return ""
	}
	if {$code ne "200"} { return "" }
	if {[dict exists $h transfer-encoding] && [string match -nocase *chunked* [dict get $h transfer-encoding]]} {
		set out ""
		while 1 {
			set nl [string first "\r\n" $body]
			if {$nl < 0} { return "" }
			set n [string trim [lindex [split [string range $body 0 [expr {$nl - 1}]] {;}] 0]]
			if {![string is xdigit -strict $n]} { return "" }
			set n [expr {"0x$n"}]
			if {$n == 0} break
			append out [string range $body [expr {$nl + 2}] [expr {$nl + 1 + $n}]]
			set body [string range $body [expr {$nl + 4 + $n}] end]
		}
		set body $out
	} elseif {[dict exists $h content-length] && [string is integer -strict [dict get $h content-length]]} {
		set body [string range $body 0 [expr {[dict get $h content-length] - 1}]]
	}
	return $body
}

proc ::mail::accounts::Wake {co args} {
	if {[llength [info commands $co]]} { $co $args }
}

# ---- DNS over TCP (inside the detect coroutine) ------------------------------------------------------------------------
# Records of TYPE (33 SRV: {prio weight port target}, 15 MX: {pref host}) for NAME, from the first name server that
# answers; {} when none has any.
proc ::mail::accounts::Servers {} {
	variable nameservers
	if {$nameservers ne ""} { return $nameservers }
	set out {}
	if {![catch {set fh [::open /etc/resolv.conf r]}]} {
		foreach l [split [::read $fh] \n] {
			if {[regexp {^\s*nameserver\s+(\S+)} $l -> a]} { lappend out [expr {[string first : $a] >= 0 ? "\[$a\]:53" : "$a:53"}] }
		}
		::close $fh
	}
	if {![llength $out]} { set out 127.0.0.1:53 }
	return $out
}

proc ::mail::accounts::Dns {name type} {
	variable timeout
	set name [string trimright $name .]
	if {![regexp {^[A-Za-z0-9_.-]+$} $name]} { return {} }
	set qid [expr {int(rand() * 65535)}]
	set q [binary format SSSSSS $qid 0x0100 1 0 0 0]
	foreach l [split $name .] { append q [binary format c [string length $l]]$l }
	append q [binary format cSS 0 $type 1]
	set co [info coroutine]
	foreach ns [Servers] {
		if {![regexp {^\[?([^\]]+?)\]?:(\d+)$} $ns -> host port]} continue
		if {[catch {socket -async $host $port} s]} continue
		fconfigure $s -translation binary -blocking 0
		set timer [after [expr {$timeout / 2}] [list ::mail::accounts::Wake $co timeout]]
		fileevent $s writable [list ::mail::accounts::Wake $co writable]
		set ev [lindex [yield] 0]
		fileevent $s writable {}
		if {$ev ne "writable" || [fconfigure $s -error] ne ""} { after cancel $timer; catch {close $s}; continue }
		if {[catch {puts -nonewline $s [binary format S [string length $q]]$q; flush $s}]} { after cancel $timer; catch {close $s}; continue }
		set buf ""
		fileevent $s readable [list ::mail::accounts::Wake $co readable]
		set ok 0
		while 1 {
			set ev [lindex [yield] 0]
			if {$ev ne "readable"} break
			if {[catch {read $s} d] || ($d eq "" && [eof $s])} break
			append buf $d
			if {[string length $buf] >= 2} {
				binary scan $buf S len
				set len [expr {$len & 0xffff}]
				if {[string length $buf] >= $len + 2} { set ok 1; break }
			}
		}
		after cancel $timer
		catch {close $s}
		if {!$ok} continue
		set r [Answers [string range $buf 2 [expr {$len + 1}]] $qid $type]
		if {$r ne "fail"} { return $r }
	}
	return {}
}

# The answers of TYPE in a DNS reply; "fail" for a reply that is not one (a server error: try the next server)
proc ::mail::accounts::Answers {msg qid type} {
	if {[string length $msg] < 12} { return fail }
	binary scan $msg SSSSSS id flags qd an ns ar
	if {($id & 0xffff) != $qid || !($flags & 0x8000)} { return fail }
	set rcode [expr {$flags & 0xf}]
	if {$rcode == 3} { return {} }
	if {$rcode != 0} { return fail }
	set pos 12
	for {set i 0} {$i < ($qd & 0xffff)} {incr i} {
		lassign [Name $msg $pos] - pos
		incr pos 4
	}
	set out {}
	for {set i 0} {$i < ($an & 0xffff)} {incr i} {
		lassign [Name $msg $pos] - pos
		if {[binary scan $msg @${pos}SSIS t cls ttl rdlen] != 4} { return fail }
		set t [expr {$t & 0xffff}]; set rdlen [expr {$rdlen & 0xffff}]
		set rd [expr {$pos + 10}]
		# a record cut short by the reply's end: not a reply (an untrusted server's)
		if {$rd + $rdlen > [string length $msg]} { return fail }
		if {$t == $type && $type == 33} {
			if {$rdlen < 7 || [binary scan $msg @${rd}SSS prio weight port] != 3} { return fail }
			lappend out [list [expr {$prio & 0xffff}] [expr {$weight & 0xffff}] [expr {$port & 0xffff}] [lindex [Name $msg [expr {$rd + 6}]] 0]]
		} elseif {$t == $type && $type == 15} {
			if {$rdlen < 3 || [binary scan $msg @${rd}S pref] != 1} { return fail }
			lappend out [list [expr {$pref & 0xffff}] [lindex [Name $msg [expr {$rd + 2}]] 0]]
		}
		set pos [expr {$rd + $rdlen}]
	}
	if {$type == 15} { set out [lsort -integer -index 0 $out] }
	return $out
}

# a (compressed) name at POS: {NAME NEXT}
proc ::mail::accounts::Name {msg pos} {
	set labels {}
	set next ""
	for {set hops 0} {$hops < 64} {incr hops} {
		if {[binary scan $msg @${pos}cu n] != 1} break
		if {$n == 0} { incr pos; break }
		if {($n & 0xc0) == 0xc0} {
			binary scan $msg @${pos}S p
			if {$next eq ""} { set next [expr {$pos + 2}] }
			set pos [expr {$p & 0x3fff}]
			continue
		}
		lappend labels [string range $msg [expr {$pos + 1}] [expr {$pos + $n}]]
		set pos [expr {$pos + 1 + $n}]
	}
	list [join $labels .] [expr {$next eq "" ? $pos : $next}]
}

if {[info commands ::tk] ne ""} { source -encoding utf-8 [file join [file dirname [info script]] ui-account.tcl] }
