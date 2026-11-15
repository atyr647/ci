# secrets.tcl - Mail's passwords in the freedesktop Secret Service (org.freedesktop.secrets on the session bus),
# spoken over ribbon::dbus (decision 47: never in files). Any provider works; Ribbon ships gnome-keyring, which PAM
# unlocks at login. Nothing here keeps a password: each lookup asks the service again.
#
#   mail::secrets::store ATTRS LABEL SECRET   saves SECRET (text) under ATTRS (a dict of strings) in the default
#                                             collection, replacing an item with the same ATTRS
#   mail::secrets::lookup ATTRS               the secret of the first item that has ATTRS; an error when there is
#                                             none (errorCode {SECRETS none})
#   mail::secrets::clear ATTRS                deletes every item that has ATTRS
#   mail::secrets::available                  1 when a provider answers on the session bus
#
# Errors are Tcl errors whose errorCode is {SECRETS KIND}: none (no such item), service (no provider, or it
# refused), dismissed (the unlock prompt was dismissed), locked (the collection stays locked).
#
# The session uses the "plain" algorithm: the secret crosses the session bus (a socket only this user can open)
# as is, as libsecret's own tools allow. The unlock prompt, when the collection is locked, is the provider's
# (Prompt.Prompt with no parent window); its answer is awaited for up to two minutes.
#
#   mail::secrets::address ADDR               the bus to use (tests: a private bus with a stand-in service)

namespace eval ::mail::secrets {
	variable bus ""
	variable address session
	variable session ""
	variable dest org.freedesktop.secrets
	variable root /org/freedesktop/secrets
	variable promptwait 120000
	variable seq 0
}

proc ::mail::secrets::address {addr} {
	variable address
	Drop
	set address $addr
}

proc ::mail::secrets::Fail {kind msg} {
	return -code error -level 2 -errorcode [list SECRETS $kind] $msg
}

proc ::mail::secrets::Drop {} {
	variable bus
	variable session
	if {$bus ne ""} { catch {$bus close} }
	set bus ""
	set session ""
}

proc ::mail::secrets::Bus {} {
	variable bus
	variable address
	if {$bus ne "" && [llength [info commands $bus]]} { return $bus }
	if {[catch {package require ribbon::dbus}]} {
		foreach d {/usr/lib/ribbon} { if {$d ni $::auto_path} { lappend ::auto_path $d } }
		if {[catch {package require ribbon::dbus} err]} { Fail service "the D-Bus library is missing: $err" }
	}
	if {[catch {ribbon::dbus::connect $address -onclose ::mail::secrets::Drop} b]} {
		Fail service "the session bus is not there: $b"
	}
	set bus $b
	return $bus
}

# A call to the service; a D-Bus error becomes a {SECRETS service} error (a bus that went away is reopened once).
proc ::mail::secrets::Call {path iface member args} {
	variable dest
	for {set try 0} {$try < 2} {incr try} {
		set b [Bus]
		if {![catch {$b call $dest $path $iface $member {*}$args} r opts]} { return $r }
		set code [lindex [dict get $opts -errorcode] 1]
		if {$code eq "org.freedesktop.DBus.Error.Disconnected" && $try == 0} { Drop; continue }
		if {$code in {org.freedesktop.DBus.Error.ServiceUnknown org.freedesktop.DBus.Error.NameHasNoOwner}} {
			Fail service "no secret store answers (org.freedesktop.secrets): is gnome-keyring running?"
		}
		Fail service "the secret store refused $member: $r"
	}
}

proc ::mail::secrets::available {} {
	variable dest
	if {[catch {Bus} b]} { return 0 }
	if {[catch {$b call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus NameHasOwner s $dest} r]} { return 0 }
	if {[lindex $r 0]} { return 1 }
	# a provider started by D-Bus activation counts too
	if {[catch {$b call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ListActivatableNames} r]} { return 0 }
	expr {$dest in [lindex $r 0]}
}

proc ::mail::secrets::Session {} {
	variable session
	variable root
	if {$session ne "" && [Bus] ne ""} { return $session }
	set r [Call $root org.freedesktop.Secret.Service OpenSession sv plain {s ""}]
	set session [lindex $r 1]
	return $session
}

# Runs PROMPT (an object path; "/" is none) and waits for its Completed signal: the result variant's value.
proc ::mail::secrets::Prompt {prompt} {
	variable seq
	variable promptwait
	if {$prompt in {"" /}} { return "" }
	set b [Bus]
	set v ::mail::secrets::done[incr seq]
	set $v ""
	set id [$b listen -path $prompt -interface org.freedesktop.Secret.Prompt -member Completed \
		[list apply {{v m args} { set $v [list done {*}$args] }} $v]]
	set timer [after $promptwait [list set $v timeout]]
	if {[catch {Call $prompt org.freedesktop.Secret.Prompt Prompt s ""} err opts]} {
		after cancel $timer
		catch {$b unlisten $id}
		unset $v
		return -options $opts $err
	}
	if {[set $v] eq ""} { vwait $v }
	after cancel $timer
	catch {$b unlisten $id}
	set r [set $v]
	unset $v
	if {$r eq "timeout"} {
		catch {Call $prompt org.freedesktop.Secret.Prompt Dismiss}
		Fail dismissed "the secret store's prompt was not answered"
	}
	lassign $r - dismissed result
	if {$dismissed} { Fail dismissed "the secret store's prompt was dismissed" }
	return [lindex $result 1]
}

# The default collection, unlocked; made (as "Login", the default) when the store has none.
proc ::mail::secrets::Collection {} {
	variable root
	set c [lindex [Call $root org.freedesktop.Secret.Service ReadAlias s default] 0]
	if {$c in {"" /}} {
		set r [Call $root org.freedesktop.Secret.Service CreateCollection a{sv}s \
			[dict create org.freedesktop.Secret.Collection.Label {s Login}] default]
		lassign $r c prompt
		if {$c in {"" /}} { set c [Prompt $prompt] }
		if {$c in {"" /}} { Fail service "the secret store made no collection" }
	}
	Unlock [list $c]
	return $c
}

# Unlocks the collections PATHS that are locked (the provider may prompt).
proc ::mail::secrets::Unlock {paths} {
	variable root
	if {![llength $paths]} return
	set locked {}
	foreach p $paths {
		set l [Call $p org.freedesktop.DBus.Properties Get ss org.freedesktop.Secret.Collection Locked]
		if {[lindex $l 0 1]} { lappend locked $p }
	}
	if {![llength $locked]} return
	lassign [Call $root org.freedesktop.Secret.Service Unlock ao $locked] unlocked prompt
	if {[llength $unlocked] < [llength $locked]} {
		set unlocked [Prompt $prompt]
		foreach p $locked { if {$p ni $unlocked} { Fail locked "the secret store stays locked" } }
	}
}

proc ::mail::secrets::Check {attrs} {
	if {[catch {dict size $attrs}] || ![dict size $attrs]} { error "attributes must be a non-empty dict" }
}

proc ::mail::secrets::store {attrs label secret} {
	Check $attrs
	set c [Collection]
	set props [dict create org.freedesktop.Secret.Item.Label [list s $label] \
		org.freedesktop.Secret.Item.Attributes [list a{ss} $attrs]]
	set value [list [Session] "" [encoding convertto utf-8 $secret] "text/plain; charset=utf8"]
	lassign [Call $c org.freedesktop.Secret.Collection CreateItem a{sv}(oayays)b $props $value 1] item prompt
	if {$item in {"" /}} { set item [Prompt $prompt] }
	if {$item in {"" /}} { Fail service "the secret store did not save the password" }
	return $item
}

proc ::mail::secrets::Find {attrs} {
	variable root
	Check $attrs
	lassign [Call $root org.freedesktop.Secret.Service SearchItems a{ss} $attrs] unlocked locked
	if {![llength $unlocked] && [llength $locked]} {
		lassign [Call $root org.freedesktop.Secret.Service Unlock ao $locked] unlocked prompt
		if {![llength $unlocked]} { set unlocked [Prompt $prompt] }
		if {![llength $unlocked]} { Fail locked "the secret store stays locked" }
	}
	return $unlocked
}

proc ::mail::secrets::lookup {attrs} {
	variable root
	set items [Find $attrs]
	if {![llength $items]} { Fail none "no password is saved for this account" }
	set item [lindex [lsort $items] 0]
	set r [lindex [Call $root org.freedesktop.Secret.Service GetSecrets aoo [list $item] [Session]] 0]
	if {![dict exists $r $item]} { Fail none "no password is saved for this account" }
	set bytes [lindex [dict get $r $item] 2]
	return [encoding convertfrom utf-8 $bytes]
}

proc ::mail::secrets::clear {attrs} {
	foreach item [Find $attrs] {
		set prompt [lindex [Call $item org.freedesktop.Secret.Item Delete] 0]
		Prompt $prompt
	}
}
