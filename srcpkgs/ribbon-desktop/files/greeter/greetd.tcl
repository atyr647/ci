# greetd.tcl - greetd's IPC: JSON messages over the unix socket in
# $GREETD_SOCK, each preceded by its length (32 bits, native byte order).
#
# greetd answers every request with exactly one response (success, error or
# auth_message), so requests wait in a queue and go out one at a time. The
# socket is non-blocking and read from the event loop: the screen keeps
# drawing while PAM waits (a fingerprint reader can take seconds).
#
#   greetd::connect PATH
#   greetd::send REQUEST-DICT CALLBACK     the callback gets the response dict
#
# Requests: create_session username | post_auth_message_response ?response?
#           start_session cmd env | cancel_session

namespace eval greetd {
	variable chan ""
	variable buf ""
	variable queue {}       ;# {json callback} waiting to be sent
	variable waiting ""     ;# the callback of the request on the wire
	variable onclose ""     ;# called if greetd hangs up
}

proc greetd::connect {path} {
	variable chan
	variable buf ""
	package require unix_sockets
	set chan [unix_sockets::connect $path]
	fconfigure $chan -translation binary -blocking 0 -buffering none
	fileevent $chan readable greetd::readable
}

proc greetd::connected {} { variable chan; expr {$chan ne ""} }

# The request as JSON. Values are typed here, as greetd expects them.
proc greetd::encode {req} {
	set type [dict get $req type]
	set args [list type [json::str $type]]
	switch -- $type {
		create_session { lappend args username [json::str [dict get $req username]] }
		post_auth_message_response {
			# info and error messages are acknowledged with no response
			if {[dict exists $req response]} { lappend args response [json::str [dict get $req response]] }
		}
		start_session {
			lappend args cmd [json::strs [dict get $req cmd]] env [json::strs [dict get $req env]]
		}
		cancel_session {}
		default { error "greetd: unknown request $type" }
	}
	json::obj {*}$args
}

# One frame: native-endian 32-bit length, then the UTF-8 JSON.
proc greetd::frame {json} {
	set data [encoding convertto utf-8 $json]
	return [binary format n [string length $data]]$data
}

proc greetd::send {req callback} {
	variable queue
	lappend queue [list [encode $req] $callback]
	pump
}

proc greetd::pump {} {
	variable chan
	variable queue
	variable waiting
	if {$waiting ne "" || ![llength $queue] || $chan eq ""} return
	set queue [lassign $queue next]
	lassign $next json waiting
	if {[catch {puts -nonewline $chan [frame $json]; flush $chan} err]} { hangup $err }
}

proc greetd::readable {} {
	variable chan
	variable buf
	variable waiting
	if {[catch {read $chan} data] || ($data eq "" && [eof $chan])} { hangup [expr {[info exists data] ? $data : "eof"}]; return }
	append buf $data
	while {[string length $buf] >= 4} {
		binary scan $buf nu len
		if {[string length $buf] < 4 + $len} break
		set json [encoding convertfrom utf-8 [string range $buf 4 [expr {3 + $len}]]]
		set buf [string range $buf [expr {4 + $len}] end]
		if {[catch {json::decode $json} resp]} { set resp [dict create type error error_type error description $resp] }
		set cb $waiting
		set waiting ""
		if {$cb ne ""} { uplevel #0 [linsert $cb end $resp] }
		pump
	}
}

proc greetd::hangup {why} {
	variable chan
	variable waiting
	variable queue
	variable onclose
	catch {close $chan}
	set chan ""
	set cb $waiting
	set waiting ""
	set queue {}
	if {$cb ne ""} { uplevel #0 [linsert $cb end [dict create type error error_type error description "greetd closed the connection"]] }
	if {$onclose ne ""} { uplevel #0 [linsert $onclose end $why] }
}
