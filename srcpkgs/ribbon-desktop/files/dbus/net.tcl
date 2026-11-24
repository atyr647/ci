# net.tcl - ribbon::dbus: the transports besides unix sockets, and the
# DBUS_COOKIE_SHA1 mechanism they authenticate with. dbus.tcl reads this
# file when an address uses one, or a bus offers the cookie mechanism.
#
#   tcp:host=H,port=P          a TCP socket (no fd passing)
#   nonce-tcp:host=H,port=P,noncefile=F   the same, sending F's 16 bytes first
#   unixexec:path=P,argv1=A... a program, its stdin and stdout the connection
#                              (a socketpair; ssh host systemd-stdio-bridge)

namespace eval ribbon::dbus::net {}

proc ribbon::dbus::net::connect {kind d} {
	if {$kind eq "unixexec"} {
		if {![dict exists $d path]} { ribbon::dbus::fail org.freedesktop.DBus.Error.BadAddress "unixexec: needs path=" }
		set argv {}
		for {set i 1} {[dict exists $d argv$i]} {incr i} { lappend argv [dict get $d argv$i] }
		lassign [unix_extra::socketpair] here there
		if {[catch {exec [dict get $d path] {*}$argv <@ $there >@ $there 2>@ stderr &} err]} {
			close $here; close $there
			ribbon::dbus::fail org.freedesktop.DBus.Error.SpawnFailed $err
		}
		close $there
		# a program in between passes bytes, not fds
		return [list $here 0]
	}
	if {![dict exists $d port]} { ribbon::dbus::fail org.freedesktop.DBus.Error.BadAddress "$kind: needs port=" }
	set host [expr {[dict exists $d host] ? [dict get $d host] : "localhost"}]
	set nonce ""
	if {$kind eq "nonce-tcp"} {
		if {![dict exists $d noncefile]} { ribbon::dbus::fail org.freedesktop.DBus.Error.BadAddress "nonce-tcp: needs noncefile=" }
		set f [open [dict get $d noncefile] rb]
		set nonce [read $f 16]
		close $f
		if {[string length $nonce] != 16} { ribbon::dbus::fail org.freedesktop.DBus.Error.BadAddress "the nonce file is short" }
	}
	# -async: the bytes wait in Tcl's buffer until the socket is connected
	set ch [socket -async $host [dict get $d port]]
	fconfigure $ch -translation binary -blocking 0
	puts -nonewline $ch $nonce
	return [list $ch 0]
}

# ---- DBUS_COOKIE_SHA1 ------------------------------------------------------
# The server names a cookie in $HOME/.dbus-keyrings/CONTEXT (where libdbus
# keeps them) and a challenge; we prove we can read it.

proc ribbon::dbus::net::user {} { return $::tcl_platform(user) }

# $HOME, else the passwd home (file home; no ~ expansion, which Tcl 9 dropped)
proc ribbon::dbus::net::home {} {
	if {[info exists ::env(HOME)] && $::env(HOME) ne ""} { return $::env(HOME) }
	if {![catch {file home [user]} h]} { return $h }
	error "no home directory"
}

proc ribbon::dbus::net::cookie {bus hex} {
	if {[catch {
		lassign [split [binary decode hex $hex] " "] context id challenge
		if {![regexp {^[^./\\\s][^/\\\s]*$} $context] || ![string is integer -strict $id]} { error "bad cookie request" }
		set home [home]
		set f [open [file join $home .dbus-keyrings $context] rb]
		set keys [read $f]
		close $f
		set secret ""
		foreach line [split $keys \n] {
			if {[lindex $line 0] eq $id} { set secret [lindex $line 2] }
		}
		if {$secret eq ""} { error "no cookie $id" }
		set f [open /dev/urandom rb]
		set mine [binary encode hex [read $f 16]]
		close $f
		set reply "$mine [sha1 $challenge:$mine:$secret]"
	}]} {
		ribbon::dbus::rawsend $bus CANCEL
		return
	}
	ribbon::dbus::rawsend $bus "DATA [binary encode hex $reply]"
}

# SHA-1 (FIPS 180-4) of a string's UTF-8 bytes, in hex.
proc ribbon::dbus::net::sha1 {text} {
	set data [encoding convertto utf-8 $text]
	set n [string length $data]
	append data \x80 [binary format x[expr {(55 - $n) % 64}]W [expr {$n * 8}]]
	set h {0x67452301 0xEFCDAB89 0x98BADCFE 0x10325476 0xC3D2E1F0}
	binary scan $data Iu* words
	for {set i 0} {$i < [llength $words]} {incr i 16} {
		set w [lrange $words $i [expr {$i + 15}]]
		for {set t 16} {$t < 80} {incr t} {
			set x [expr {[lindex $w [expr {$t-3}]] ^ [lindex $w [expr {$t-8}]] ^ [lindex $w [expr {$t-14}]] ^ [lindex $w [expr {$t-16}]]}]
			lappend w [expr {(($x << 1) | ($x >> 31)) & 0xFFFFFFFF}]
		}
		lassign $h a b c d e
		for {set t 0} {$t < 80} {incr t} {
			if {$t < 20} {
				set f [expr {($b & $c) | (~$b & $d)}]; set k 0x5A827999
			} elseif {$t < 40} {
				set f [expr {$b ^ $c ^ $d}]; set k 0x6ED9EBA1
			} elseif {$t < 60} {
				set f [expr {($b & $c) | ($b & $d) | ($c & $d)}]; set k 0x8F1BBCDC
			} else {
				set f [expr {$b ^ $c ^ $d}]; set k 0xCA62C1D6
			}
			set tmp [expr {((($a << 5) | ($a >> 27)) + $f + $e + $k + [lindex $w $t]) & 0xFFFFFFFF}]
			set e $d
			set d $c
			set c [expr {(($b << 30) | ($b >> 2)) & 0xFFFFFFFF}]
			set b $a
			set a $tmp
		}
		set h [lmap x $h y [list $a $b $c $d $e] { expr {($x + $y) & 0xFFFFFFFF} }]
	}
	binary encode hex [binary format I5 $h]
}
