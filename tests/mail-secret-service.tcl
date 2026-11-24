# mail-secret-service.tcl - a stand-in for the freedesktop Secret Service (org.freedesktop.secrets) on a private
# session bus, for Mail's secret-store tests (tests/mail-secrets.tcl, tests/mail-account-flow.tcl). It is written
# apart from apps/mail/secrets.tcl on purpose and speaks the spec's interfaces: Service (OpenSession "plain",
# CreateCollection, SearchItems, Unlock, Lock, GetSecrets, ReadAlias), Collection (CreateItem, Locked), Item (Delete)
# and Prompt (Prompt, Dismiss; Completed comes 50 ms after Prompt).
#
#   tclsh8.6 tests/mail-secret-service.tcl ?-locked 1? ?-dismiss 1? ?-nodefault 1?
#        -locked 1     the login collection starts locked; Unlock answers with a prompt
#        -dismiss 1    every prompt is dismissed
#        -nodefault 1  there is no collection until CreateCollection (which answers with a prompt)
#
# It needs DBUS_SESSION_BUS_ADDRESS. It prints "ready" once it owns the name. For the tests, /org/ribbon/test
# (org.ribbon.Test) has Dump -> s: a Tcl list of {attributes label secret-text} per item, and Calls -> s: the
# Service and Prompt methods called so far.

lappend auto_path [file join [file dirname [file dirname [file normalize [info script]]]] srcpkgs ribbon-desktop files]
package require ribbon::dbus
set opt [dict create -locked 0 -dismiss 0 -nodefault 0]
foreach {k v} $argv { dict set opt $k $v }
proc bgerror {msg} { puts stderr "secret-service: $msg\n$::errorInfo" }

set root /org/freedesktop/secrets
set coll $root/collection/login
set haveColl [expr {![dict get $opt -nodefault]}]
set locked [dict get $opt -locked]
set items [dict create]       ;# path -> {attrs label secret}
set sessions {}
set n 0
set calls {}

set bus [ribbon::dbus::connect session]

proc err {name text} { throw [list DBUS org.freedesktop.Secret.Error.$name] $text }
proc call {m} { lappend ::calls $m }

proc prompt {result} {
	global bus root n opt
	set p $root/prompt/p[incr n]
	$bus export $p org.freedesktop.Secret.Prompt [list \
		method Prompt s {} [list apply {{p result m wid} {
			call Prompt
			after 50 [list apply {{p result} {
				set dismissed [dict get $::opt -dismiss]
				if {!$dismissed} { {*}[lindex $result 1] }
				$::bus emit $p org.freedesktop.Secret.Prompt Completed bv $dismissed [lindex $result 0]
				$::bus unexport $p
			}} $p $result]
			return
		}} $p $result] \
		method Dismiss {} {} [list apply {{p m} { call Dismiss; $::bus emit $p org.freedesktop.Secret.Prompt Completed bv 1 {s ""}; $::bus unexport $p; return }} $p] \
		signal Completed bv]
	return $p
}

proc export_coll {} {
	global bus coll
	$bus export $coll org.freedesktop.Secret.Collection [list \
		method CreateItem a{sv}(oayays)b oo create_item \
		property Locked b read {-get {apply {{m} { return $::locked }}} -emits false} \
		property Label s read {-value Login -emits false}]
}

proc create_item {m props secret replace} {
	global items coll n locked sessions bus
	call CreateItem
	if {$locked} { err IsLocked "the collection is locked" }
	lassign $secret session params value ctype
	if {$session ni $sessions} { err NoSession "no such session" }
	set attrs [lindex [dict get $props org.freedesktop.Secret.Item.Attributes] 1]
	set label [lindex [dict get $props org.freedesktop.Secret.Item.Label] 1]
	if {$replace} {
		dict for {p it} $items {
			if {[lsort -stride 2 [lindex $it 0]] eq [lsort -stride 2 $attrs]} { set path $p }
		}
	}
	if {![info exists path]} {
		set path $coll/i[incr n]
		$bus export $path org.freedesktop.Secret.Item [list method Delete {} o [list apply {{path m} {
			call Delete
			dict unset ::items $path
			$::bus unexport $path
			return /
		}} $path]]
	}
	dict set items $path [list $attrs $label [encoding convertfrom utf-8 $value]]
	return [list $path /]
}

$bus export $root org.freedesktop.Secret.Service {
	method OpenSession sv vo open_session
	method CreateCollection a{sv}s oo create_collection
	method SearchItems a{ss} aoao search_items
	method Unlock ao aoo unlock
	method Lock ao aoo lock
	method GetSecrets aoo a{o(oayays)} get_secrets
	method ReadAlias s o read_alias
}

proc open_session {m alg input} {
	global sessions root n
	call OpenSession
	if {$alg ne "plain"} { throw {DBUS org.freedesktop.DBus.Error.NotSupported} "only plain" }
	set s $root/session/s[incr n]
	lappend sessions $s
	$::bus export $s org.freedesktop.Secret.Session [list method Close {} {} [list apply {{s m} { return }} $s]]
	return [list {s ""} $s]
}
proc create_collection {m props alias} {
	global haveColl coll
	call CreateCollection
	if {$haveColl} { return [list $coll /] }
	return [list / [prompt [list [list o $coll] {apply {{} { set ::haveColl 1; export_coll }}}]]]
}
proc match {attrs} {
	set out {}
	dict for {p it} $::items {
		set ok 1
		dict for {k v} $attrs { if {![dict exists [lindex $it 0] $k] || [dict get [lindex $it 0] $k] ne $v} { set ok 0 } }
		if {$ok} { lappend out $p }
	}
	return $out
}
proc search_items {m attrs} {
	call SearchItems
	set found [match $attrs]
	if {$::locked} { return [list {} $found] }
	return [list $found {}]
}
proc unlock {m objs} {
	call Unlock
	if {!$::locked} { return [list $objs /] }
	return [list {} [prompt [list [list ao $objs] {set ::locked 0}]]]
}
proc lock {m objs} {
	call Lock
	set ::locked 1
	return [list $objs /]
}
proc get_secrets {m objs session} {
	global items sessions
	call GetSecrets
	if {$session ni $sessions} { err NoSession "no such session" }
	if {$::locked} { err IsLocked "the collection is locked" }
	set out [dict create]
	foreach o $objs {
		if {[dict exists $items $o]} { dict set out $o [list $session "" [encoding convertto utf-8 [lindex [dict get $items $o] 2]] "text/plain"] }
	}
	return $out
}
proc read_alias {m name} {
	call ReadAlias
	if {$name eq "default" && $::haveColl} { return $::coll }
	return /
}
if {$haveColl} export_coll

$bus export /org/ribbon/test org.ribbon.Test {
	method Dump {} s {apply {{m} { return [dict values $::items] }}}
	method Calls {} s {apply {{m} { return $::calls }}}
}
if {[$bus request org.freedesktop.secrets] ne "primary"} { puts stderr "secret-service: the name is taken"; exit 1 }
puts ready
flush stdout
vwait forever
