# dbus.tcl - a D-Bus client in pure Tcl: package ribbon::dbus.
#
# The shell talks to D-Bus itself (notifications, polkit, portals, MPRIS,
# UPower) instead of going through GTK or helper daemons. The socket is a
# unix_extra channel, which keeps the fds passed with SCM_RIGHTS (UNIX_FD).
# Everything runs from the event loop: nothing here waits for the bus
# except the commands called without -command, and those wait in vwait
# (the event loop, so Tk keeps drawing) or, inside a coroutine, by yielding.
#
#   lappend auto_path /usr/lib/ribbon        ;# where the shell's modules live
#   package require ribbon::dbus
#   set bus [ribbon::dbus::connect session]  ;# or system, or an address
#                                            ;# (-bus 0: a peer, no bus)
#   $bus call org.freedesktop.DBus / org.freedesktop.DBus GetId
#
# A connection is a command, ::ribbon::dbus::busN, and its state is the
# array of the same name. Its subcommands:
#
#   call ?opts? DEST PATH IFACE MEMBER ?SIG VALUE...?
#        -> the reply's values, as a list. Opts: -command CB, -timeout MS
#        (25000; 0: none), -noreply 1, -noautostart 1, -interactive 1
#        (ALLOW_INTERACTIVE_AUTHORIZATION). With -command it
#        returns at once and CB gets "ok VALUES" or "error {NAME TEXT}".
#        Without, a D-Bus error is a Tcl error with errorCode {DBUS NAME}.
#   emit ?-destination D? PATH IFACE MEMBER ?SIG VALUE...?
#   listen ?-sender S -path P -path_namespace P -interface I -member M
#        -destination D -argN V -argNpath P -arg0namespace N -type T
#        -eavesdrop true? ?-command CB? HANDLER  -> an id. Adds the match
#        rule; HANDLER is called with MSG VALUE... for every message it
#        matches (-type: signal, the default, method_call, method_return
#        or error; a well-known -sender is followed to its owner).
#   unlisten ID
#   export PATH IFACE {method NAME IN OUT HANDLER  signal NAME SIG
#                       property NAME SIG ACCESS OPTIONS ...}  (props.tcl)
#        HANDLER is called with MSG VALUE...; it returns the reply (the
#        value, or a list for several OUT types), or throws an error:
#        throw {DBUS org.example.Error.Name} "text". Introspect and Peer
#        are answered for every exported path.
#   unexport PATH ?IFACE?
#   defer MSG     reply later, with  reply MSG ?VALUE...?  or
#                 error MSG NAME ?TEXT?  (reply takes -signature SIG first)
#   request NAME ?-replace 1? ?-allowreplace 1? ?-noqueue 1? ?-command CB?
#        -> primary, queued, exists or owner (CB gets "ok primary"...)
#   release NAME  -> released, nonexistent or notowner
#   set, changed, get, manage    properties, object managers (props.tcl)
#   monitor ?RULE...? HANDLER    BecomeMonitor (monitor.tcl)
#   name          our unique name
#   close
#
# ribbon::dbus::listen ADDRESS ?-anonymous 1? HANDLER serves peers
# (server.tcl); tcp:, nonce-tcp: and unixexec: addresses, and the
# DBUS_COOKIE_SHA1 mechanism, are in net.tcl. Those files are read on
# first use only.
#
# MSG is a dict: type (call return error signal), serial, flags, path,
# interface, member, error, reply, destination, sender, signature, body,
# fds. Values map to Tcl as: integers and doubles as numbers, b as 0/1,
# s o g as strings, ay as a byte string, other arrays as lists, a{..} as
# dicts, structs as lists, a variant as {SIG VALUE} (strip takes the
# wrappers off), h as a channel (sent: the channel's fd, which is passed by
# the time the command returns, so close it whenever you like; received: a
# new channel that is yours to close).
#
# Also: ribbon::dbus::marshal SIG VALUES ?little|big?,
#       ribbon::dbus::unmarshal SIG BYTES ?little|big? ?FDS?,
#       ribbon::dbus::strip SIG VALUE, ribbon::dbus::types SIG,
#       ribbon::dbus::await SCRIPT: runs SCRIPT with a callback appended
#       and waits for it as the commands without -command do.

package require Tcl 8.6-
package require unix_extra 0.3
package provide ribbon::dbus 1.0

namespace eval ribbon::dbus {
	variable dir [file dirname [file normalize [info script]]]
	variable seq 0
	variable maxfds 16      ;# per message: dbus-daemon's default limit
	variable uid ""
	variable sigs           ;# signature -> its complete types
	array set align {y 1 b 4 n 2 q 2 i 4 u 4 x 8 t 8 d 8 h 4 s 4 o 4 g 1 v 1 a 4 ( 8 \{ 8}
	array set range {y {0 255} n {-32768 32767} q {0 65535} i {-2147483648 2147483647}
		u {0 4294967295} x {-9223372036854775808 9223372036854775807} t {0 18446744073709551615}}
	# binary format/scan codes per endianness
	variable fmt [dict create \
		l {n s q su i i u iu b iu h iu x w t wu d q} \
		B {n S q Su i I u Iu b Iu h Iu x W t Wu d Q}]
	variable B ""           ;# the marshal buffer
	variable F {}           ;# channels marshalled as h
	variable D ""           ;# the unmarshal data, and the position in it
	variable P 0
	variable FDS {}         ;# channels received with the message
	variable E              ;# formats for the current endianness
	variable fields {1 path 2 interface 3 member 4 error 5 reply 6 destination 7 sender 8 signature 9 nfds}
	variable fieldsig {path o interface s member s error s reply u destination s sender s signature g nfds u}
	variable kinds {- call return error signal}
	# what the bus accepts in these header fields (it hangs up on anything else)
	variable names [dict create \
		interface {^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$} \
		error {^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$} \
		member {^[A-Za-z_][A-Za-z0-9_]*$} \
		destination {^(:[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+|[A-Za-z_-][A-Za-z0-9_-]*(\.[A-Za-z_-][A-Za-z0-9_-]*)+)$}]
}

proc ribbon::dbus::fail {code text} { return -code error -level 2 -errorcode [list DBUS $code] $text }

# The rarely used parts live in files of their own, read on first use:
# props.tcl (properties, ObjectManager), net.tcl (tcp:, nonce-tcp:,
# unixexec:, DBUS_COOKIE_SHA1), server.tcl (listening, peer to peer),
# monitor.tcl (BecomeMonitor).
proc ribbon::dbus::need {part} {
	variable dir
	if {![namespace exists [namespace current]::$part]} {
		uplevel #0 [list source -encoding utf-8 [file join $dir $part.tcl]]
	}
}
proc ribbon::dbus::lazy {part cmd bus args} {
	need $part
	tailcall [namespace current]::${part}::$cmd $bus {*}$args
}
proc ribbon::dbus::listen {args} { need server; tailcall [namespace current]::server::listen {*}$args }

# The D-Bus name of a handler's error: {DBUS NAME} errorCodes keep theirs.
proc ribbon::dbus::errname {opts} {
	set ec [dict get $opts -errorcode]
	expr {[lindex $ec 0] eq "DBUS" ? [lindex $ec 1] : "org.freedesktop.DBus.Error.Failed"}
}

# ---- signatures ------------------------------------------------------------

# The complete types of a signature: a{sv}i(ii) -> {a{sv} i (ii)}
proc ribbon::dbus::types {sig} {
	variable sigs
	if {[info exists sigs($sig)]} { return $sigs($sig) }
	if {[array size sigs] > 1000} { array unset sigs }
	if {[string length $sig] > 255} { fail org.freedesktop.DBus.Error.InvalidSignature "signature too long" }
	set out {}
	for {set i 0} {$i < [string length $sig]} {incr i} {
		set j [typeend $sig $i 0 0 0]
		lappend out [string range $sig $i $j]
		set i $j
	}
	set sigs($sig) $out
}

# Where the complete type that starts at i ends. Arrays and structs (dict
# entries count as structs) nest at most 32 deep each.
proc ribbon::dbus::typeend {sig i inarray ad sd} {
	set c [string index $sig $i]
	switch -- $c {
		y - b - n - q - i - u - x - t - d - h - s - o - g - v { return $i }
		a {
			if {$ad >= 32} { fail org.freedesktop.DBus.Error.InvalidSignature "arrays nested too deep in \"$sig\"" }
			return [typeend $sig [expr {$i + 1}] 1 [expr {$ad + 1}] $sd]
		}
		( - \{ {
			if {$sd >= 32} { fail org.freedesktop.DBus.Error.InvalidSignature "structs nested too deep in \"$sig\"" }
			set close [expr {$c eq "(" ? ")" : "\}"}]
			set n 0
			for {incr i} {[string index $sig $i] ne $close} {incr i} {
				if {$i >= [string length $sig]} break
				if {$c eq "\{" && $n == 0 && [string first [string index $sig $i] ybnqiuxtdhsog] < 0} break
				set i [typeend $sig $i 0 $ad [expr {$sd + 1}]]
				incr n
			}
			if {$i < [string length $sig] && $n > 0 && ($c eq "(" || ($inarray && $n == 2))} { return $i }
		}
	}
	fail org.freedesktop.DBus.Error.InvalidSignature "bad signature \"$sig\""
}

proc ribbon::dbus::onetype {sig} {
	if {[llength [types $sig]] != 1} { fail org.freedesktop.DBus.Error.InvalidSignature "\"$sig\" is not one complete type" }
}

# ---- marshalling -----------------------------------------------------------

proc ribbon::dbus::pad {n} {
	variable B
	set p [expr {-[string length $B] & ($n - 1)}]
	if {$p} { append B [binary format x$p] }
}

proc ribbon::dbus::objpath {p} {
	if {![regexp {^/([A-Za-z0-9_]+(/[A-Za-z0-9_]+)*)?$} $p]} {
		fail org.freedesktop.DBus.Error.InvalidArgs "\"$p\" is not an object path"
	}
}

proc ribbon::dbus::put {t v} {
	variable B
	variable E
	variable range
	switch -glob -- $t {
		y - n - q - i - u - x - t {
			if {![string is entier -strict $v] || $v < [lindex $range($t) 0] || $v > [lindex $range($t) 1]} {
				fail org.freedesktop.DBus.Error.InvalidArgs "\"$v\" is not a valid $t"
			}
			if {$t eq "y"} { append B [binary format c $v]; return }
			pad [expr {$t in {x t} ? 8 : $t in {n q} ? 2 : 4}]
			append B [binary format [dict get $E $t] $v]
		}
		b {
			if {![string is boolean -strict $v]} { fail org.freedesktop.DBus.Error.InvalidArgs "\"$v\" is not a boolean" }
			pad 4; append B [binary format [dict get $E i] [expr {$v ? 1 : 0}]]
		}
		d { pad 8; append B [binary format [dict get $E d] $v] }
		s - o - g {
			if {$t eq "o"} { objpath $v }
			if {$t eq "g"} { types $v }
			if {[string first \0 $v] >= 0} { fail org.freedesktop.DBus.Error.InvalidArgs "a string can't hold NUL" }
			set d [encoding convertto utf-8 $v]
			if {$t eq "g"} { append B [binary format c [string length $d]]$d\0; return }
			pad 4; append B [binary format [dict get $E i] [string length $d]]$d[binary format x]
		}
		h {
			variable F
			lappend F $v
			pad 4; append B [binary format [dict get $E i] [expr {[llength $F] - 1}]]
		}
		v {
			if {[llength $v] != 2} { fail org.freedesktop.DBus.Error.InvalidArgs "a variant is {SIG VALUE}, not \"$v\"" }
			lassign $v sig val
			onetype $sig
			put g $sig
			put $sig $val
		}
		a* {
			set et [string range $t 1 end]
			pad 4
			set at [string length $B]
			append B [binary format x4]
			variable align
			pad $align([string index $et 0])
			set start [string length $B]
			if {$et eq "y"} {
				append B [binary format a* $v]
			} elseif {[string index $et 0] eq "\{"} {
				lassign [types [string range $et 1 end-1]] kt vt
				dict for {k val} $v { pad 8; put $kt $k; put $vt $val }
			} else {
				foreach e $v { put $et $e }
			}
			set n [expr {[string length $B] - $start}]
			if {$n > 67108864} { fail org.freedesktop.DBus.Error.LimitsExceeded "array longer than 64 MiB" }
			set B [binary format a*@${at}[dict get $E i] $B $n]
		}
		(* {
			set ts [types [string range $t 1 end-1]]
			if {[llength $v] != [llength $ts]} { fail org.freedesktop.DBus.Error.InvalidArgs "struct $t needs [llength $ts] values, not \"$v\"" }
			pad 8
			foreach et $ts ev $v { put $et $ev }
		}
		default { fail org.freedesktop.DBus.Error.InvalidSignature "bad type \"$t\"" }
	}
}

# Values to bytes for a signature; marshal starts at offset 0, which is
# where a message body starts too (it is 8-aligned).
proc ribbon::dbus::marshal {sig values {endian little}} {
	variable B ""
	variable F {}
	variable E
	variable fmt
	set E [dict get $fmt [expr {$endian eq "big" ? "B" : "l"}]]
	set ts [types $sig]
	if {[llength $ts] != [llength $values]} {
		fail org.freedesktop.DBus.Error.InvalidArgs "signature \"$sig\" needs [llength $ts] values, got [llength $values]"
	}
	foreach t $ts v $values { put $t $v }
	return $B
}

# ---- unmarshalling ---------------------------------------------------------

proc ribbon::dbus::take {size fmt} {
	variable D
	variable P
	set P [expr {($P + $size - 1) & -$size}]
	if {$P + $size > [string length $D]} { fail org.freedesktop.DBus.Error.InvalidArgs "message truncated" }
	binary scan $D @${P}$fmt v
	incr P $size
	return $v
}

proc ribbon::dbus::get {t} {
	variable D
	variable P
	variable E
	switch -glob -- $t {
		y { return [take 1 cu] }
		n - q { return [take 2 [dict get $E $t]] }
		i - u { return [take 4 [dict get $E $t]] }
		x - t { return [take 8 [dict get $E $t]] }
		d { return [take 8 [dict get $E d]] }
		b {
			set v [take 4 [dict get $E b]]
			if {$v > 1} { fail org.freedesktop.DBus.Error.InvalidArgs "boolean $v" }
			return $v
		}
		s - o - g {
			set n [expr {$t eq "g" ? [take 1 cu] : [take 4 [dict get $E u]]}]
			if {$P + $n + 1 > [string length $D]} { fail org.freedesktop.DBus.Error.InvalidArgs "message truncated" }
			binary scan $D @${P}a$n v
			incr P [expr {$n + 1}]
			return [encoding convertfrom utf-8 $v]
		}
		h {
			variable FDS
			set i [take 4 [dict get $E h]]
			if {$i >= [llength $FDS]} { fail org.freedesktop.DBus.Error.InvalidArgs "fd $i was not passed" }
			return [lindex $FDS $i]
		}
		v {
			set sig [get g]
			onetype $sig
			return [list $sig [get $sig]]
		}
		a* {
			variable align
			set n [take 4 [dict get $E u]]
			set et [string range $t 1 end]
			set P [expr {($P + $align([string index $et 0]) - 1) & -$align([string index $et 0])}]
			set end [expr {$P + $n}]
			if {$end > [string length $D] || $n > 67108864} { fail org.freedesktop.DBus.Error.InvalidArgs "message truncated" }
			if {$et eq "y"} {
				binary scan $D @${P}a$n v
				set P $end
				return $v
			}
			set out {}
			if {[string index $et 0] eq "\{"} {
				lassign [types [string range $et 1 end-1]] kt vt
				while {$P < $end} {
					set P [expr {($P + 7) & -8}]
					set k [get $kt]
					dict set out $k [get $vt]
				}
			} else {
				while {$P < $end} { lappend out [get $et] }
			}
			if {$P != $end} { fail org.freedesktop.DBus.Error.InvalidArgs "array length mismatch" }
			return $out
		}
		(* {
			set P [expr {($P + 7) & -8}]
			set out {}
			foreach et [types [string range $t 1 end-1]] { lappend out [get $et] }
			return $out
		}
	}
	fail org.freedesktop.DBus.Error.InvalidSignature "bad type \"$t\""
}

proc ribbon::dbus::unmarshal {sig bytes {endian little} {fds {}}} {
	variable D $bytes
	variable P 0
	variable FDS $fds
	variable E
	variable fmt
	set E [dict get $fmt [expr {$endian eq "big" ? "B" : "l"}]]
	set out {}
	foreach t [types $sig] { lappend out [get $t] }
	if {$P != [string length $D]} { fail org.freedesktop.DBus.Error.InvalidArgs "[expr {[string length $D] - $P}] bytes left over" }
	return $out
}

# A value without its variant wrappers: strip a{sv} {urgency {y 2}} -> urgency 2
proc ribbon::dbus::strip {sig value} {
	switch -glob -- $sig {
		v { lassign $value s v; return [strip $s $v] }
		ay { return $value }
		a\{* {
			lassign [types [string range $sig 2 end-1]] kt vt
			return [dict map {k v} $value { strip $vt $v }]
		}
		a* { set et [string range $sig 1 end]; return [lmap v $value { strip $et $v }] }
		(* { return [lmap t [types [string range $sig 1 end-1]] v $value { strip $t $v }] }
	}
	return $value
}

# ---- messages --------------------------------------------------------------

# A whole message: {bytes channels}. h is a dict of header fields by name.
proc ribbon::dbus::build {endian kind flags serial h sig body} {
	variable fieldsig
	variable fields
	variable kinds
	set data [marshal $sig $body $endian]
	variable F
	set chans $F
	if {$sig ne ""} { dict set h signature $sig }
	if {[llength $chans]} { dict set h nfds [llength $chans] }
	variable names
	set hf {}
	dict for {code name} $fields {
		if {![dict exists $h $name] || [set v [dict get $h $name]] eq ""} continue
		if {[dict exists $names $name] && ([string length $v] > 255 || ![regexp [dict get $names $name] $v])} {
			fail org.freedesktop.DBus.Error.InvalidArgs "\"$v\" is not a valid $name"
		}
		lappend hf [list $code [list [dict get $fieldsig $name] $v]]
	}
	set e [expr {$endian eq "big" ? "B" : "l"}]
	set head [marshal yyyyuua(yv) [list [scan $e %c] [lsearch -exact $kinds $kind] $flags 1 [string length $data] $serial $hf] $endian]
	append head [binary format x[expr {-[string length $head] & 7}]]
	return [list $head$data $chans]
}

# The header of a message as a dict (see the top), and where its body starts.
proc ribbon::dbus::header {bytes} {
	variable fields
	variable kinds
	set endian [expr {[string index $bytes 0] eq "B" ? "big" : "little"}]
	if {[string index $bytes 0] ni {l B}} { fail org.freedesktop.DBus.Error.InvalidArgs "not a D-Bus message" }
	variable D $bytes
	variable P 0
	variable E
	variable fmt
	set E [dict get $fmt [string index $bytes 0]]
	lassign [lmap t {y y y y u u a(yv)} { get $t }] - kind flags version - serial hf
	if {$version != 1 || $kind < 1 || $kind > 4 || $serial == 0} { fail org.freedesktop.DBus.Error.InvalidArgs "bad message header" }
	set m [dict create type [lindex $kinds $kind] serial $serial flags $flags endian $endian \
		path "" interface "" member "" error "" reply 0 destination "" sender "" signature "" nfds 0]
	foreach f $hf {
		lassign $f code v
		if {[dict exists $fields $code]} { dict set m [dict get $fields $code] [lindex $v 1] }
	}
	set P [expr {($P + 7) & -8}]
	return [list $m $P]
}

# The body, after header: m is the header dict, at where the body starts.
proc ribbon::dbus::decode {bytes m at fds} {
	variable D $bytes
	variable P $at
	variable FDS $fds
	set body {}
	foreach t [types [dict get $m signature]] { lappend body [get $t] }
	if {$P != [string length $D]} { fail org.freedesktop.DBus.Error.InvalidArgs "body length mismatch" }
	dict set m body $body
	dict set m fds $fds
	return $m
}

# ---- connections -----------------------------------------------------------

proc ribbon::dbus::opts {argsVar defaults} {
	upvar 1 $argsVar a
	while {[string match -* [lindex $a 0]]} {
		set a [lassign $a k]
		if {$k eq "--"} break
		if {![dict exists $defaults $k] && !([regexp {^-arg([0-9]|[1-5][0-9]|6[0-3])(path|namespace)?$} $k] && [dict exists $defaults -argN])} {
			error "unknown option \"$k\": should be one of [join [dict keys $defaults] {, }]"
		}
		if {![llength $a]} { error "option $k needs a value" }
		set a [lassign $a v]
		dict set defaults $k $v
	}
	return $defaults
}

# The entries of an address (session, system, or a D-Bus address), as
# {transport {key value ...}} in the order to try them.
proc ribbon::dbus::addresses {address} {
	global env
	if {$address eq "session"} {
		if {[info exists env(DBUS_SESSION_BUS_ADDRESS)] && $env(DBUS_SESSION_BUS_ADDRESS) ne ""} {
			set address $env(DBUS_SESSION_BUS_ADDRESS)
		} elseif {[info exists env(XDG_RUNTIME_DIR)]} {
			set address unix:path=$env(XDG_RUNTIME_DIR)/bus
		} else { fail org.freedesktop.DBus.Error.NoServer "no session bus: DBUS_SESSION_BUS_ADDRESS is not set" }
	} elseif {$address eq "system"} {
		if {[info exists env(DBUS_SYSTEM_BUS_ADDRESS)] && $env(DBUS_SYSTEM_BUS_ADDRESS) ne ""} {
			set address $env(DBUS_SYSTEM_BUS_ADDRESS)
		} else { set address unix:path=/run/dbus/system_bus_socket }
	}
	set out {}
	foreach a [split $address ";"] {
		if {![regexp {^([a-z-]+):(.*)$} $a -> kind kv]} continue
		set d {}
		foreach pair [split $kv ,] {
			if {[regexp {^([^=]+)=(.*)$} $pair -> k v]} { dict set d $k [unescape $v] }
		}
		lappend out [list $kind $d]
	}
	if {![llength $out]} { fail org.freedesktop.DBus.Error.BadAddress "no address in \"$address\"" }
	return $out
}

# A connected channel for one address entry, and whether it is a unix socket.
proc ribbon::dbus::transport {kind d} {
	if {$kind eq "unix"} {
		if {[dict exists $d path]} { return [list [unix_extra::connect [dict get $d path]] 1] }
		if {[dict exists $d abstract]} { return [list [unix_extra::connect @[dict get $d abstract]] 1] }
		fail org.freedesktop.DBus.Error.BadAddress "unix: needs path= or abstract= to connect"
	}
	if {$kind ni {tcp nonce-tcp unixexec}} { fail org.freedesktop.DBus.Error.BadAddress "transport $kind: is not supported" }
	need net
	net::connect $kind $d
}

# An address value's %XX escapes are bytes of its UTF-8.
proc ribbon::dbus::unescape {s} {
	set s [encoding convertto utf-8 $s]
	set out ""
	while {[regexp -indices {%([0-9A-Fa-f]{2})} $s all hex]} {
		append out [string range $s 0 [lindex $all 0]-1] [binary format H2 [string range $s {*}$hex]]
		set s [string range $s [lindex $all 1]+1 end]
	}
	encoding convertfrom utf-8 $out$s
}

proc ribbon::dbus::myuid {} {
	variable uid
	if {$uid eq ""} {
		# our own credentials, as the kernel records them on a socketpair
		lassign [unix_extra::socketpair] a b
		set uid [dict get [unix_extra::peercred $a] uid]
		close $a; close $b
	}
	return $uid
}

# connect ?ADDRESS? ?-command CB? ?-timeout MS? ?-auth MECHANISMS?
#         ?-endian little|big? ?-onclose CB? ?-bus 0?
# Without -command it returns once the bus has answered Hello. With it, it
# returns at once and CB gets "ok BUS" or "error {NAME TEXT}". -onclose CB
# is called with the reason when the bus goes away. -bus 0 is a peer to
# peer connection: no Hello, no bus in between (ribbon::dbus::listen).
proc ribbon::dbus::connect {args} {
	set address session
	if {[llength $args] % 2} { set args [lassign $args address] }
	set o [opts args {-command "" -timeout 25000 -auth {EXTERNAL DBUS_COOKIE_SHA1 ANONYMOUS} -endian little -onclose "" -bus 1}]
	set err ""
	set chan ""
	foreach a [addresses $address] {
		if {![catch {transport {*}$a} r]} { lassign $r chan unix; break }
		set err $r
	}
	if {$chan eq ""} { fail org.freedesktop.DBus.Error.NoServer "can't connect to $address: $err" }
	set bus [newbus $chan $unix $o]
	upvar #0 $bus c
	set c(role) client
	puts -nonewline $chan \0
	if {[dict get $o -command] ne ""} {
		set c(ready) [dict get $o -command]
		auth $bus
		return $bus
	}
	if {[catch {await [list [namespace current]::Start $bus]} err opts]} {
		Close $bus
		return -options $opts $err
	}
	return $bus
}

# A connection on a connected channel, still to authenticate.
proc ribbon::dbus::newbus {chan unix o} {
	variable seq
	set bus [namespace current]::bus[incr seq]
	upvar #0 $bus c
	array set c [list chan $chan unix $unix state auth rbuf "" roff 0 fdq {} serial 1 unique "" guid "" \
		unixfd 0 negotiating 0 endian [dict get $o -endian] mechs [dict get $o -auth] offered * mech "" \
		bus [dict get $o -bus] names {} monitor "" calls {} owed {} matches {} owners {} objs {} out {} \
		ready "" onclose [dict get $o -onclose] timer ""]
	set map {}
	foreach {sub cmd} {call Call emit Emit listen Listen unlisten Unlisten export Export unexport Unexport
		defer Defer reply Reply error Fail request Request release Release name Name close Close} {
		dict set map $sub [list [namespace current]::$cmd $bus]
	}
	foreach {sub part cmd} {get props Get set props Set changed props Changed manage props Manage monitor monitor Monitor} {
		dict set map $sub [list [namespace current]::lazy $part $cmd $bus]
	}
	namespace ensemble create -command $bus -map $map -prefixes 0
	fconfigure $chan -blocking 0 -translation binary -buffering full
	fileevent $chan readable [list [namespace current]::readable $bus]
	if {[dict get $o -timeout] > 0} {
		set c(timer) [after [dict get $o -timeout] [list [namespace current]::lost $bus "no answer in time" org.freedesktop.DBus.Error.Timeout]]
	}
	return $bus
}

proc ribbon::dbus::Start {bus cb} {
	upvar #0 $bus c
	set c(ready) $cb
	auth $bus
}

# ---- SASL ------------------------------------------------------------------

proc ribbon::dbus::rawsend {bus line} {
	upvar #0 $bus c
	if {[catch {puts -nonewline $c(chan) $line\r\n; flush $c(chan)} err]} { lost $bus $err }
}

# Offer the next mechanism (of those the server offered, once it has said):
# EXTERNAL (our uid), DBUS_COOKIE_SHA1 (net.tcl), ANONYMOUS.
proc ribbon::dbus::auth {bus} {
	upvar #0 $bus c
	set mech ""
	while {[llength $c(mechs)]} {
		set c(mechs) [lassign $c(mechs) mech]
		if {$c(offered) eq "*" || $mech in $c(offered)} break
		set mech ""
	}
	set c(mech) $mech
	switch -- $mech {
		EXTERNAL { rawsend $bus "AUTH EXTERNAL [binary encode hex [myuid]]" }
		DBUS_COOKIE_SHA1 { need net; rawsend $bus "AUTH DBUS_COOKIE_SHA1 [binary encode hex [net::user]]" }
		ANONYMOUS { rawsend $bus "AUTH ANONYMOUS [binary encode hex ribbon::dbus]" }
		"" { lost $bus "the bus accepted none of our mechanisms" org.freedesktop.DBus.Error.AuthFailed }
		default { lost $bus "unknown mechanism $mech" org.freedesktop.DBus.Error.AuthFailed }
	}
}

proc ribbon::dbus::authline {bus line} {
	upvar #0 $bus c
	if {$c(role) eq "server"} { server::authline $bus $line; return }
	switch -glob -- $line {
		"OK *" {
			set c(guid) [lindex $line 1]
			if {!$c(unix)} { begin $bus; return }
			set c(negotiating) 1
			rawsend $bus NEGOTIATE_UNIX_FD
		}
		AGREE_UNIX_FD { set c(unixfd) $c(unix); begin $bus }
		ERROR* { if {$c(negotiating)} { begin $bus } else { rawsend $bus CANCEL } }
		REJECTED* { set c(offered) [lrange $line 1 end]; auth $bus }
		DATA* {
			if {$c(mech) eq "DBUS_COOKIE_SHA1"} { net::cookie $bus [lindex $line 1] } else { rawsend $bus DATA }
		}
		default { lost $bus "unexpected \"$line\" from the bus" org.freedesktop.DBus.Error.AuthFailed }
	}
}

# BEGIN, and Hello (serial 1) ahead of anything queued meanwhile.
proc ribbon::dbus::begin {bus} {
	upvar #0 $bus c
	rawsend $bus BEGIN
	if {$c(state) eq "closed"} return
	if {!$c(bus)} { ready $bus; return }
	set c(state) hello
	lassign [build $c(endian) call 0 1 {path /org/freedesktop/DBus interface org.freedesktop.DBus
		member Hello destination org.freedesktop.DBus} "" {}] bytes
	set c(out) [linsert $c(out) 0 [list $bytes {}]]
	dict set c(calls) 1 [list [list [namespace current]::hello $bus] ""]
	flushout $bus
}

proc ribbon::dbus::hello {bus status values} {
	upvar #0 $bus c
	if {$status ne "ok"} { lost $bus [lindex $values 1] [lindex $values 0]; return }
	set c(unique) [lindex $values 0]
	ready $bus
}

proc ribbon::dbus::ready {bus} {
	upvar #0 $bus c
	after cancel $c(timer)
	set c(state) ready
	flushout $bus
	set cb $c(ready)
	set c(ready) ""
	if {$cb ne ""} { run $cb ok $bus }
}

# ---- the wire --------------------------------------------------------------

proc ribbon::dbus::alive {bus} {
	upvar #0 $bus c
	expr {[info exists c(state)] && $c(state) ne "closed"}
}

proc ribbon::dbus::readable {bus} {
	upvar #0 $bus c
	if {[catch {read $c(chan)} data]} { lost $bus $data; return }
	# the fds came with what was just read; D-Bus messages say how many
	# they carry, so they are taken from this queue in order
	if {$c(unix) && [catch {lappend c(fdq) {*}[unix_extra::fds $c(chan) -all]} err]} { lost $bus $err; return }
	append c(rbuf) $data
	while {$c(state) eq "auth"} {
		set i [string first \r\n $c(rbuf)]
		if {$i < 0} break
		set line [string range $c(rbuf) 0 $i-1]
		set c(rbuf) [encoding convertto iso8859-1 [string range $c(rbuf) $i+2 end]]
		authline $bus $line
		if {![alive $bus]} return
	}
	if {$c(state) eq "auth" && [string length $c(rbuf)] > 16384} { lost $bus "authentication line too long"; return }
	while {[alive $bus] && $c(state) ne "auth"} {
		set m [nextmsg $bus]
		if {$m eq ""} break
		dispatch $bus $m
	}
	if {![alive $bus]} return
	if {$c(roff)} {
		binary scan $c(rbuf) @$c(roff)a* c(rbuf)
		set c(roff) 0
	}
	if {[eof $c(chan)]} { lost $bus "the bus closed the connection" }
}

# The next whole message in the read buffer, or "".
proc ribbon::dbus::nextmsg {bus} {
	upvar #0 $bus c
	set have [expr {[string length $c(rbuf)] - $c(roff)}]
	if {$have < 16} { return "" }
	binary scan $c(rbuf) @$c(roff)a1x3 e
	set f [expr {$e eq "B" ? "Iu" : "iu"}]
	binary scan $c(rbuf) @[expr {$c(roff) + 4}]${f}x4$f blen flen
	set len [expr {16 + (($flen + 7) & ~7) + $blen}]
	if {$len > 134217728} { lost $bus "message too large"; return "" }
	if {$have < $len} { return "" }
	binary scan $c(rbuf) @$c(roff)a$len m
	incr c(roff) $len
	return $m
}

proc ribbon::dbus::send {bus kind flags h sig body} {
	upvar #0 $bus c
	if {![alive $bus]} { fail org.freedesktop.DBus.Error.Disconnected "not connected" }
	if {$c(monitor) ne ""} { fail org.freedesktop.DBus.Error.NotSupported "a monitor sends nothing" }
	set serial [incr c(serial)]
	lassign [build $c(endian) $kind $flags $serial $h $sig $body] bytes chans
	if {[llength $chans] && $c(state) eq "auth"} {
		fail org.freedesktop.DBus.Error.NotSupported "fds can be sent once connect's callback has run"
	}
	if {[llength $chans] && !$c(unixfd)} { fail org.freedesktop.DBus.Error.NotSupported "this bus does not pass fds" }
	variable maxfds
	if {[llength $chans] > $maxfds} {
		fail org.freedesktop.DBus.Error.LimitsExceeded "[llength $chans] fds in one message, the bus takes $maxfds"
	}
	lappend c(out) [list $bytes $chans]
	flushout $bus
	return $serial
}

# Write what is queued. Tcl buffers plain bytes on the non-blocking socket
# and writes them out from the event loop. A message with fds goes out with
# sendfds, at once: only if the socket is full (the bus isn't reading) does
# that wait, so that the channels sent can be closed as soon as send returns.
proc ribbon::dbus::flushout {bus} {
	upvar #0 $bus c
	if {$c(state) ne "auth" && [catch {write $bus} err]} { lost $bus $err }
}
proc ribbon::dbus::write {bus} {
	upvar #0 $bus c
	while {[llength $c(out)]} {
		lassign [lindex $c(out) 0] bytes chans
		set c(out) [lrange $c(out) 1 end]
		if {![llength $chans]} { puts -nonewline $c(chan) $bytes; continue }
		if {[catch {unix_extra::sendfds $c(chan) $chans $bytes} n opts]} {
			if {[lindex [dict get $opts -errorcode] 1] ne "EAGAIN"} { return -options $opts $n }
			fconfigure $c(chan) -blocking 1
			set err [catch {unix_extra::sendfds $c(chan) $chans $bytes} n opts]
			fconfigure $c(chan) -blocking 0
			if {$err} { return -options $opts $n }
		}
		if {$n < [string length $bytes]} { puts -nonewline $c(chan) [string range $bytes $n end] }
	}
	flush $c(chan)
}

# The bus is gone: everything waiting is told so (from the event loop, so
# no callback runs inside the command that noticed).
proc ribbon::dbus::lost {bus why {name org.freedesktop.DBus.Error.Disconnected}} {
	upvar #0 $bus c
	if {![alive $bus]} return
	set was $c(state)
	set c(state) closed
	after cancel $c(timer)
	catch {close $c(chan)}
	foreach ch $c(fdq) { catch {close $ch} }
	set c(fdq) {}
	set c(out) {}
	dict for {serial p} $c(calls) {
		lassign $p cb timer
		after cancel $timer
		after 0 [list [namespace current]::run $cb error [list $name $why]]
	}
	set c(calls) {}
	if {$c(ready) ne ""} { after 0 [list [namespace current]::run $c(ready) error [list $name $why]] }
	set c(ready) ""
	if {$was eq "ready" && $c(onclose) ne ""} { after 0 [list [namespace current]::run $c(onclose) $why] }
}

# A callback, at global level; its errors are background errors.
proc ribbon::dbus::run {cmd args} {
	if {[catch {uplevel #0 [list {*}$cmd {*}$args]} err opts]} {
		{*}[interp bgerror {}] $err $opts
	}
}

# Run [SEND CALLBACK] and wait for the callback: yield inside a coroutine,
# otherwise vwait (the event loop runs meanwhile). Errors become Tcl errors.
proc ribbon::dbus::await {send} {
	variable seq
	if {[info coroutine] ne ""} {
		{*}$send [list [namespace current]::resume [info coroutine]]
		set r [yield]
	} else {
		set v [namespace current]::wait[incr seq]
		{*}$send [list [namespace current]::wake $v]
		vwait $v
		set r [set $v]
		unset $v
	}
	lassign $r status values
	if {$status ne "ok"} {
		return -code error -errorcode [list DBUS [lindex $values 0]] [lindex $values 1]
	}
	return $values
}
proc ribbon::dbus::wake {var args} { set $var $args }
proc ribbon::dbus::resume {coro args} { $coro $args }

# ---- incoming --------------------------------------------------------------

proc ribbon::dbus::dispatch {bus bytes} {
	upvar #0 $bus c
	if {[catch {header $bytes} h]} { lost $bus "bad message from the bus: $h"; return }
	lassign $h m at
	set n [dict get $m nfds]
	if {$n > [llength $c(fdq)]} { lost $bus "a message lost its fds"; return }
	set fds [lrange $c(fdq) 0 $n-1]
	set c(fdq) [lrange $c(fdq) $n end]
	if {[catch {decode $bytes $m $at $fds} m]} {
		foreach f $fds { catch {close $f} }
		lost $bus "bad message from the bus: $m"
		return
	}
	if {$c(monitor) ne ""} { run $c(monitor) $m; return }
	set mine [ours $bus $m]
	if {[dict get $m type] ne "signal"} { observe $bus $m }
	if {!$mine && [dict get $m type] ne "signal"} { closefds $m; return }
	switch -- [dict get $m type] {
		return - error {
			set r [dict get $m reply]
			if {![dict exists $c(calls) $r]} { closefds $m; return }
			lassign [dict get $c(calls) $r] cb timer
			dict unset c(calls) $r
			after cancel $timer
			if {[dict get $m type] eq "return"} {
				run $cb ok [dict get $m body]
			} else {
				set text [expr {[string index [dict get $m signature] 0] eq "s" ? [lindex [dict get $m body] 0] : ""}]
				run $cb error [list [dict get $m error] $text]
			}
		}
		signal {
			# the bus tells us which names we have
			if {[dict get $m sender] eq "org.freedesktop.DBus" && [dict get $m member] in {NameAcquired NameLost}} {
				set n [lindex [dict get $m body] 0]
				set c(names) [lsearch -all -inline -not -exact $c(names) $n]
				if {[dict get $m member] eq "NameAcquired"} { lappend c(names) $n }
			}
			set used 0
			dict for {id l} $c(matches) {
				lassign $l rule cmd
				if {![alive $bus]} return
				if {[dict exists $c(matches) $id] && [matches $bus $rule $m]} {
					set used 1
					run $cmd $m {*}[dict get $m body]
				}
			}
			if {!$used} { closefds $m }
		}
		call { incoming $bus $m }
	}
}

proc ribbon::dbus::closefds {m} { foreach f [dict get $m fds] { catch {close $f} } }

# Is the message for us? Not if we were only eavesdropping on it.
proc ribbon::dbus::ours {bus m} {
	upvar #0 $bus c
	set d [dict get $m destination]
	# (Hello's reply tells us our unique name: until then, all is ours)
	expr {$d eq "" || $c(unique) eq "" || $d eq $c(unique) || $d in $c(names)}
}

# Calls, returns and errors go to the listeners whose rules match them
# (eavesdropping, -type method_call ...), as well as where they belong.
proc ribbon::dbus::observe {bus m} {
	upvar #0 $bus c
	dict for {id l} $c(matches) {
		lassign $l rule cmd
		if {[alive $bus] && [dict exists $c(matches) $id] && [dict exists $rule type] && [matches $bus $rule $m]} {
			run $cmd $m {*}[dict get $m body]
		}
	}
}

proc ribbon::dbus::matches {bus rule m} {
	upvar #0 $bus c
	dict for {k v} $rule {
		switch -glob -- $k {
			type {
				set t [dict get {method_call call method_return return error error signal signal} $v]
				if {[dict get $m type] ne $t} { return 0 }
			}
			sender {
				set s [dict get $m sender]
				if {$s ne $v && !([dict exists $c(owners) $v] && [dict get $c(owners) $v] eq $s)} { return 0 }
			}
			path - interface - member - destination { if {[dict get $m $k] ne $v} { return 0 } }
			path_namespace {
				set p [dict get $m path]
				if {$v ne "/" && $p ne $v && ![string match $v/* $p]} { return 0 }
			}
			eavesdrop {}
			arg* {
				regexp {^arg([0-9]+)(.*)$} $k -> i how
				if {[string index [lindex [types [dict get $m signature]] $i] 0] ni {s o}} { return 0 }
				set a [lindex [dict get $m body] $i]
				switch -- $how {
					"" { if {$a ne $v} { return 0 } }
					path {
						# equal, or one ends in / and starts the other
						if {$a ne $v && !([string index $v end] eq "/" && [string first $v $a] == 0)
							&& !([string index $a end] eq "/" && [string first $a $v] == 0)} { return 0 }
					}
					namespace { if {$a ne $v && [string first $v. $a] != 0} { return 0 } }
				}
			}
		}
	}
	return 1
}

# A method call for us: our objects, Introspect and Peer.
proc ribbon::dbus::incoming {bus m} {
	upvar #0 $bus c
	set path [dict get $m path]
	set iface [dict get $m interface]
	set member [dict get $m member]
	set sig [dict get $m signature]
	if {$iface eq "org.freedesktop.DBus.Peer" || ($iface eq "" && $member in {Ping GetMachineId})} {
		switch -- $member {
			Ping { answer $bus $m "" {} }
			GetMachineId { answer $bus $m s [list [machineid]] }
			default { answer $bus $m s [list "no method $member"] org.freedesktop.DBus.Error.UnknownMethod }
		}
		return
	}
	if {$iface in {org.freedesktop.DBus.Properties org.freedesktop.DBus.ObjectManager}
		&& [namespace exists props] && [props::incoming $bus $m]} return
	set children [children $bus $path]
	if {![dict exists $c(objs) $path] && ![llength $children] && !([info exists c(managers)] && [dict exists $c(managers) $path])} {
		closefds $m
		answer $bus $m s [list "no object at $path"] org.freedesktop.DBus.Error.UnknownObject
		return
	}
	if {$member eq "Introspect" && $iface in {"" org.freedesktop.DBus.Introspectable}} {
		answer $bus $m s [list [introspect $bus $path $children]]
		return
	}
	set spec ""
	set ifaces [expr {[dict exists $c(objs) $path] ? [dict get $c(objs) $path] : {}}]
	dict for {i d} $ifaces {
		if {($iface eq "" || $iface eq $i) && [dict exists $d methods $member]} { set spec [dict get $d methods $member]; break }
	}
	if {$spec eq ""} {
		closefds $m
		if {$iface ne "" && ![dict exists $ifaces $iface]} {
			answer $bus $m s [list "no interface $iface at $path"] org.freedesktop.DBus.Error.UnknownInterface
		} else {
			answer $bus $m s [list "no method $member in $iface at $path"] org.freedesktop.DBus.Error.UnknownMethod
		}
		return
	}
	lassign $spec in out handler
	if {$sig ne $in} {
		closefds $m
		answer $bus $m s [list "$member takes \"$in\", not \"$sig\""] org.freedesktop.DBus.Error.InvalidArgs
		return
	}
	set key [list [dict get $m sender] [dict get $m serial]]
	if {!([dict get $m flags] & 1)} { dict set c(owed) $key [list $out 0] }
	set code [catch {uplevel #0 [list {*}$handler $m {*}[dict get $m body]]} res opts]
	if {![alive $bus] || ![dict exists $c(owed) $key]} return
	if {$code == 1} {
		Fail $bus $m [errname $opts] $res
	} elseif {![lindex [dict get $c(owed) $key] 1]} {
		switch -- [llength [types $out]] {
			0 { set res {} }
			1 { set res [list $res] }
		}
		if {[catch {Reply $bus -signature $out $m {*}$res} err]} {
			Fail $bus $m org.freedesktop.DBus.Error.Failed "bad reply: $err"
			{*}[interp bgerror {}] $err [dict create -code 1 -level 0 -errorcode NONE -errorinfo "$err\n    (reply to $member)"]
		}
	}
}

# A method return or error, unless the caller wanted none.
proc ribbon::dbus::answer {bus m sig values {error ""}} {
	if {[dict get $m flags] & 1} return
	set h [list reply [dict get $m serial] destination [dict get $m sender]]
	if {$error ne ""} {
		send $bus error 0 [dict set h error $error] $sig $values
	} else {
		send $bus return 0 $h $sig $values
	}
}

proc ribbon::dbus::machineid {} {
	foreach f {/etc/machine-id /var/lib/dbus/machine-id} {
		if {![catch {open $f} fh]} { set id [string trim [read $fh]]; close $fh; return $id }
	}
	return ""
}

# The next path elements under path, of the paths we export.
proc ribbon::dbus::children {bus path} {
	upvar #0 $bus c
	set pre [expr {$path eq "/" ? "/" : "$path/"}]
	set out {}
	foreach p [dict keys $c(objs)] {
		if {[string first $pre $p] == 0 && $p ne $path} {
			set n [lindex [split [string range $p [string length $pre] end] /] 0]
			if {$n ni $out} { lappend out $n }
		}
	}
	return $out
}

proc ribbon::dbus::introspect {bus path children} {
	upvar #0 $bus c
	set x "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"\n"
	append x " \"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n<node>\n"
	append x " <interface name=\"org.freedesktop.DBus.Introspectable\">\n"
	append x "  <method name=\"Introspect\"><arg type=\"s\" direction=\"out\"/></method>\n </interface>\n"
	append x " <interface name=\"org.freedesktop.DBus.Peer\">\n  <method name=\"Ping\"/>\n"
	append x "  <method name=\"GetMachineId\"><arg type=\"s\" direction=\"out\"/></method>\n </interface>\n"
	if {[dict exists $c(objs) $path]} {
		dict for {iface d} [dict get $c(objs) $path] {
			append x " <interface name=\"$iface\">\n"
			dict for {name spec} [dict get $d methods] {
				lassign $spec in out
				append x "  <method name=\"$name\">"
				foreach t [types $in] { append x "<arg type=\"$t\" direction=\"in\"/>" }
				foreach t [types $out] { append x "<arg type=\"$t\" direction=\"out\"/>" }
				append x "</method>\n"
			}
			dict for {name sig} [dict get $d signals] {
				append x "  <signal name=\"$name\">"
				foreach t [types $sig] { append x "<arg type=\"$t\"/>" }
				append x "</signal>\n"
			}
			if {[dict exists $d props]} { append x [props::xml [dict get $d props]] }
			append x " </interface>\n"
		}
	}
	if {[namespace exists props]} { append x [props::standard $bus $path] }
	foreach n $children { append x " <node name=\"$n\"/>\n" }
	append x "</node>\n"
}

# ---- the connection's subcommands --------------------------------------------

proc ribbon::dbus::Call {bus args} {
	upvar #0 $bus c
	set o [opts args {-command "" -timeout 25000 -noreply 0 -noautostart 0 -interactive 0}]
	if {[llength $args] < 4} { error "wrong # args: should be \"$bus call ?options? dest path interface member ?signature value ...?\"" }
	set values [lassign $args dest path iface member sig]
	set h [list path $path interface $iface member $member destination $dest]
	set flags [expr {([dict get $o -noreply] ? 1 : 0) | ([dict get $o -noautostart] ? 2 : 0) | ([dict get $o -interactive] ? 4 : 0)}]
	if {$flags & 1} { send $bus call $flags $h $sig $values; return }
	set go [list [namespace current]::Pending $bus [dict get $o -timeout] $flags $h $sig $values]
	if {[dict get $o -command] eq ""} { return [await $go] }
	{*}$go [dict get $o -command]
	return
}

proc ribbon::dbus::Pending {bus timeout flags h sig values cb} {
	upvar #0 $bus c
	set serial [send $bus call $flags $h $sig $values]
	set timer [expr {$timeout > 0 ? [after $timeout [list [namespace current]::expire $bus $serial]] : ""}]
	dict set c(calls) $serial [list $cb $timer]
}

proc ribbon::dbus::expire {bus serial} {
	upvar #0 $bus c
	if {![alive $bus] || ![dict exists $c(calls) $serial]} return
	set cb [lindex [dict get $c(calls) $serial] 0]
	dict unset c(calls) $serial
	run $cb error {org.freedesktop.DBus.Error.NoReply "no reply in time"}
}

proc ribbon::dbus::Emit {bus args} {
	set o [opts args {-destination ""}]
	set values [lassign $args path iface member sig]
	send $bus signal 0 [list path $path interface $iface member $member destination [dict get $o -destination]] $sig $values
	return
}

proc ribbon::dbus::rule {d} {
	set r {}
	dict for {k v} $d { lappend r "$k='[string map {' '\\''} $v]'" }
	join $r ,
}

proc ribbon::dbus::Listen {bus args} {
	upvar #0 $bus c
	variable seq
	set o [opts args {-type signal -sender "" -path "" -path_namespace "" -interface "" -member "" -destination ""
		-eavesdrop "" -argN "" -command ""}]
	if {[llength $args] != 1} { error "wrong # args: should be \"$bus listen ?options? handler\"" }
	if {[dict get $o -type] ni {signal method_call method_return error}} { error "bad -type \"[dict get $o -type]\"" }
	set rule {}
	dict for {k v} $o { if {$k ni {-command -argN} && $v ne ""} { dict set rule [string range $k 1 end] $v } }
	set id [incr seq]
	dict set c(matches) $id [list $rule [lindex $args 0]]
	# signals carry the sender's unique name: follow a well-known one's owner
	set s [dict get $o -sender]
	if {$s eq "" || [string match :* $s] || $s eq "org.freedesktop.DBus" || [dict exists $c(owners) $s] || !$c(bus)} {
		set s ""
	} else {
		dict set c(owners) $s ""
		set r [list type signal sender org.freedesktop.DBus member NameOwnerChanged arg0 $s]
		dict set c(matches) [incr seq] [list $r [list [namespace current]::owner $bus]]
		driver $bus AddMatch s [list [rule $r]] [namespace current]::ignore
	}
	set go [list [namespace current]::Subscribe $bus $rule $s]
	if {[dict get $o -command] eq ""} { await $go } else { {*}$go [dict get $o -command] }
	return $id
}

# AddMatch; then, for a well-known sender, who owns it now; then CB.
proc ribbon::dbus::Subscribe {bus rule name cb} {
	upvar #0 $bus c
	if {!$c(bus)} { after 0 [list [namespace current]::run $cb ok {}]; return }
	driver $bus AddMatch s [list [rule $rule]] [list [namespace current]::subscribed $bus $name $cb]
}
proc ribbon::dbus::subscribed {bus name cb status values} {
	if {$status ne "ok" || $name eq ""} { run $cb $status $values; return }
	if {[catch {driver $bus GetNameOwner s [list $name] [list [namespace current]::owned $bus $name $cb]} err]} {
		run $cb error [list org.freedesktop.DBus.Error.Disconnected $err]
	}
}
proc ribbon::dbus::owned {bus name cb status values} {
	upvar #0 $bus c
	# an error here is NameHasNoOwner: nobody has it yet
	if {$status eq "ok" && [alive $bus]} { dict set c(owners) $name [lindex $values 0] }
	run $cb ok {}
}
proc ribbon::dbus::owner {bus m name old new} {
	upvar #0 $bus c
	dict set c(owners) $name $new
}
proc ribbon::dbus::ignore {args} {}

# A call to the bus itself, answered through CB.
proc ribbon::dbus::driver {bus member sig values cb} {
	Pending $bus 25000 0 [list path /org/freedesktop/DBus interface org.freedesktop.DBus member $member \
		destination org.freedesktop.DBus] $sig $values $cb
}

proc ribbon::dbus::Unlisten {bus id} {
	upvar #0 $bus c
	if {![dict exists $c(matches) $id]} return
	set rule [lindex [dict get $c(matches) $id] 0]
	dict unset c(matches) $id
	if {[alive $bus] && $c(bus)} { driver $bus RemoveMatch s [list [rule $rule]] [namespace current]::ignore }
}

proc ribbon::dbus::Export {bus path iface spec} {
	upvar #0 $bus c
	objpath $path
	set methods {}
	set signals {}
	while {[llength $spec]} {
		set spec [lassign $spec kind name]
		switch -- $kind {
			method {
				set spec [lassign $spec in out handler]
				types $in; types $out
				dict set methods $name [list $in $out $handler]
			}
			signal { set spec [lassign $spec sig]; types $sig; dict set signals $name $sig }
			property {
				need props
				set spec [lassign $spec sig access popts]
				dict set props $name [props::declare $name $sig $access $popts]
			}
			default { error "export: \"$kind\" should be method, signal or property" }
		}
	}
	set d [dict create methods $methods signals $signals]
	if {[info exists props]} { dict set d props $props }
	set new [expr {![dict exists $c(objs) $path $iface]}]
	dict set c(objs) $path $iface $d
	if {$new && [namespace exists props]} { props::added $bus $path $iface }
	return
}

proc ribbon::dbus::Unexport {bus path {iface ""}} {
	upvar #0 $bus c
	if {![dict exists $c(objs) $path]} return
	set gone [expr {$iface eq "" ? [dict keys [dict get $c(objs) $path]] : [lsearch -all -inline -exact [dict keys [dict get $c(objs) $path]] $iface]}]
	if {[namespace exists props] && [llength $gone]} { props::removed $bus $path $gone }
	if {$iface eq ""} { dict unset c(objs) $path; return }
	if {[dict exists $c(objs) $path $iface]} { dict unset c(objs) $path $iface }
	if {[dict exists $c(objs) $path] && ![dict size [dict get $c(objs) $path]]} { dict unset c(objs) $path }
}

proc ribbon::dbus::Defer {bus m} {
	upvar #0 $bus c
	set key [list [dict get $m sender] [dict get $m serial]]
	if {[dict exists $c(owed) $key]} { dict set c(owed) $key [list [lindex [dict get $c(owed) $key] 0] 1] }
}

proc ribbon::dbus::Reply {bus args} {
	upvar #0 $bus c
	set o [opts args {-signature ""}]
	set values [lassign $args m]
	set key [list [dict get $m sender] [dict get $m serial]]
	if {![dict exists $c(owed) $key]} return
	set sig [expr {[dict get $o -signature] ne "" ? [dict get $o -signature] : [lindex [dict get $c(owed) $key] 0]}]
	answer $bus $m $sig $values
	dict unset c(owed) $key
}

proc ribbon::dbus::Fail {bus m name {text ""}} {
	upvar #0 $bus c
	set key [list [dict get $m sender] [dict get $m serial]]
	if {![dict exists $c(owed) $key]} return
	dict unset c(owed) $key
	answer $bus $m s [list $text] $name
}

proc ribbon::dbus::Request {bus args} {
	set a [lassign $args name]
	set o [opts a {-replace 0 -allowreplace 0 -noqueue 0 -command ""}]
	set flags [expr {([dict get $o -allowreplace] ? 1 : 0) | ([dict get $o -replace] ? 2 : 0) | ([dict get $o -noqueue] ? 4 : 0)}]
	set words {{} primary queued exists owner}
	if {[dict get $o -command] ne ""} {
		Call $bus -command [list [namespace current]::named $words [dict get $o -command]] \
			org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus RequestName su $name $flags
		return
	}
	lindex $words [lindex [Call $bus org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus RequestName su $name $flags] 0]
}
proc ribbon::dbus::named {words cb status values} {
	if {$status eq "ok"} { set values [lindex $words [lindex $values 0]] }
	run $cb $status $values
}

proc ribbon::dbus::Release {bus name} {
	lindex {{} released nonexistent notowner} [lindex [Call $bus org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ReleaseName s $name] 0]
}

proc ribbon::dbus::Name {bus} { upvar #0 $bus c; return $c(unique) }

proc ribbon::dbus::Close {bus} {
	upvar #0 $bus c
	set c(onclose) ""
	lost $bus "closed"
	rename $bus ""
	unset c
}
