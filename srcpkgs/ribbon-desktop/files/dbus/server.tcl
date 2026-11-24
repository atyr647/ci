# server.tcl - ribbon::dbus: listening for peer-to-peer connections, with
# no bus in between. dbus.tcl reads this file on the first
# ribbon::dbus::listen.
#
#   set srv [ribbon::dbus::listen ADDRESS ?-anonymous 1? ?-endian E? HANDLER]
#   $srv address     the address to give clients (connect ... -bus 0)
#   $srv close
#
# ADDRESS: unix:path=P, unix:abstract=N, unix:dir=D or unix:tmpdir=D (a new
# name in D), tcp:host=H,port=P (port 0: any). HANDLER is called with each
# connection once it has authenticated, a connection like connect's but
# with no bus: calls and signals go straight to the peer (destination "").
# Unix sockets take EXTERNAL from our own uid only; -anonymous 1 also takes
# ANONYMOUS, from anyone, which is the only way in over tcp.

namespace eval ribbon::dbus::server { variable seq 0 }

proc ribbon::dbus::server::random {n} {
	set f [open /dev/urandom rb]
	set r [binary encode hex [read $f $n]]
	close $f
	return $r
}

proc ribbon::dbus::server::listen {address args} {
	variable seq
	if {![llength $args]} { error "wrong # args: should be \"ribbon::dbus::listen address ?options? handler\"" }
	set handler [lindex $args end]
	set args [lrange $args 0 end-1]
	set o [ribbon::dbus::opts args {-anonymous 0 -endian little}]
	lassign [lindex [ribbon::dbus::addresses $address] 0] kind d
	set srv [namespace current]::srv[incr seq]
	upvar #0 $srv s
	set s(guid) [random 16]
	set s(handler) $handler
	set s(o) $o
	switch -- $kind {
		unix {
			if {[dict exists $d path]} {
				set p [dict get $d path]
			} elseif {[dict exists $d abstract]} {
				set p @[dict get $d abstract]
			} elseif {[dict exists $d dir] || [dict exists $d tmpdir]} {
				set p [file join [expr {[dict exists $d dir] ? [dict get $d dir] : [dict get $d tmpdir]}] dbus-[random 8]]
			} else { ribbon::dbus::fail org.freedesktop.DBus.Error.BadAddress "unix: needs path=, abstract=, dir= or tmpdir=" }
			set s(chan) [unix_extra::listen $p [list [namespace current]::accept $srv 1]]
			set s(address) [expr {[string index $p 0] eq "@" ? "unix:abstract=[string range $p 1 end]" : "unix:path=[escape $p]"}]
		}
		tcp {
			set host [expr {[dict exists $d host] ? [dict get $d host] : "localhost"}]
			set port [expr {[dict exists $d port] ? [dict get $d port] : 0}]
			set s(chan) [socket -server [list [namespace current]::tcpaccept $srv] -myaddr $host $port]
			set s(address) tcp:host=[escape $host],port=[lindex [fconfigure $s(chan) -sockname] 2]
		}
		default { ribbon::dbus::fail org.freedesktop.DBus.Error.BadAddress "can't listen on $kind:" }
	}
	append s(address) ,guid=$s(guid)
	namespace ensemble create -command $srv -map [dict create \
		address [list [namespace current]::Address $srv] close [list [namespace current]::Close $srv]]
	return $srv
}

# An address value, %-escaped where D-Bus wants it.
proc ribbon::dbus::server::escape {v} {
	set out ""
	foreach ch [split [encoding convertto utf-8 $v] ""] {
		if {[regexp {[-0-9A-Za-z_/.\\*]} $ch]} { append out $ch } else { append out %[binary encode hex $ch] }
	}
	return $out
}

proc ribbon::dbus::server::Address {srv} { upvar #0 $srv s; return $s(address) }
proc ribbon::dbus::server::Close {srv} {
	upvar #0 $srv s
	catch {close $s(chan)}
	rename $srv ""
	unset s
}

proc ribbon::dbus::server::tcpaccept {srv chan addr port} { accept $srv 0 $chan }

proc ribbon::dbus::server::accept {srv unix chan} {
	upvar #0 $srv s
	set bus [ribbon::dbus::newbus $chan $unix [dict merge {-auth {} -onclose "" -bus 0 -timeout 25000} \
		[dict create -endian [dict get $s(o) -endian]]]]
	upvar #0 $bus c
	array set c [list role server guid $s(guid) nul 0 authed 0 anonymous [dict get $s(o) -anonymous] \
		ready [list [namespace current]::begun $s(handler)]]
}

proc ribbon::dbus::server::begun {handler status bus} {
	if {$status eq "ok"} { uplevel #0 [list {*}$handler $bus] }
}

proc ribbon::dbus::server::mechs {bus} {
	upvar #0 $bus c
	set m {}
	if {$c(unix)} { lappend m EXTERNAL }
	if {$c(anonymous)} { lappend m ANONYMOUS }
	return $m
}

# The server's half of the SASL conversation.
proc ribbon::dbus::server::authline {bus line} {
	upvar #0 $bus c
	if {!$c(nul)} {
		if {[string index $line 0] ne "\0"} { ribbon::dbus::lost $bus "no NUL byte first" org.freedesktop.DBus.Error.AuthFailed; return }
		set c(nul) 1
		set line [string range $line 1 end]
	}
	switch -- [lindex [split $line " "] 0] {
		AUTH {
			lassign [split $line " "] - mech resp
			if {$mech ni [mechs $bus] || $c(authed)} { reject $bus; return }
			set c(mech) $mech
			if {$mech eq "ANONYMOUS"} { ok $bus; return }
			if {[llength [split $line " "]] < 3} { ribbon::dbus::rawsend $bus DATA; return }
			external $bus $resp
		}
		DATA {
			if {$c(mech) eq "EXTERNAL" && !$c(authed)} { external $bus [lindex [split $line " "] 1] } else { ribbon::dbus::rawsend $bus "ERROR \"no DATA expected\"" }
		}
		NEGOTIATE_UNIX_FD {
			if {$c(authed) && $c(unix)} { set c(unixfd) 1; ribbon::dbus::rawsend $bus AGREE_UNIX_FD } else { ribbon::dbus::rawsend $bus "ERROR \"no fd passing here\"" }
		}
		BEGIN {
			if {$c(authed)} { ribbon::dbus::ready $bus } else { ribbon::dbus::lost $bus "BEGIN before OK" org.freedesktop.DBus.Error.AuthFailed }
		}
		CANCEL - ERROR { set c(authed) 0; reject $bus }
		default { ribbon::dbus::rawsend $bus "ERROR \"unknown command\"" }
	}
}

# EXTERNAL: the peer's uid, from the kernel, is ours (and the one it claims).
proc ribbon::dbus::server::external {bus resp} {
	upvar #0 $bus c
	set uid [dict get [unix_extra::peercred $c(chan)] uid]
	if {$uid == [ribbon::dbus::myuid] && ($resp eq "" || (![catch {binary decode hex -strict $resp} claimed] && $claimed eq $uid))} {
		ok $bus
	} else { reject $bus }
}

proc ribbon::dbus::server::ok {bus} {
	upvar #0 $bus c
	set c(authed) 1
	ribbon::dbus::rawsend $bus "OK $c(guid)"
}
proc ribbon::dbus::server::reject {bus} { ribbon::dbus::rawsend $bus "REJECTED [join [mechs $bus]]" }
