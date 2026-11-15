# sniwatch.tcl - the StatusNotifierWatcher (org.kde.StatusNotifierWatcher, the freedesktop StatusNotifierItem
# spec): the registry that apps' tray icons (Steam, Discord, Lutris: libappindicator, libayatana-appindicator,
# Electron, Qt's QSystemTrayIcon, KStatusNotifierItem) announce themselves to, and that a host (tray.tcl, in the
# shell's right bar) reads. The shell serves it on the session bus (mod-tray.tcl); nothing here needs Tk.
#
#   sniwatch::start BUS ?-replace 0|1? ?-command CB?
#       exports /StatusNotifierWatcher and asks for the name; CB gets primary, queued, exists or owner
#       (as $bus request: another watcher may already serve the session, and the shell's host then uses it)
#   sniwatch::items    the registered items, as the spec writes them: "SERVICE/PATH"
#
# An item registers with its bus name (org.kde.StatusNotifierItem-PID-N: its object is /StatusNotifierItem) or with
# an object path (libappindicator: /org/ayatana/NotificationItem/steam, on the caller's unique name). Both are kept
# as "BUSNAME/PATH", which hosts split at the first "/". An item goes when its bus name loses its owner (the app quit
# or crashed); a host likewise.

namespace eval sniwatch {
	variable bus ""
	variable items {}        ;# "SERVICE/PATH", in the order they came
	variable owners {}       ;# item -> the unique name that registered it
	variable hosts {}        ;# host bus name -> the unique name that registered it
	variable path /StatusNotifierWatcher
	variable iface org.kde.StatusNotifierWatcher
	variable listen ""
}

proc sniwatch::start {b args} {
	variable bus $b
	variable path
	variable iface
	variable listen
	set o [dict merge {-replace 0 -command ""} $args]
	$bus export $path $iface {
		method RegisterStatusNotifierItem s "" sniwatch::RegisterItem
		method RegisterStatusNotifierHost s "" sniwatch::RegisterHost
		property RegisteredStatusNotifierItems as read {-get sniwatch::Items -emits false}
		property IsStatusNotifierHostRegistered b read {-get sniwatch::HostRegistered -emits false}
		property ProtocolVersion i read {-value 0 -emits const}
		signal StatusNotifierItemRegistered s
		signal StatusNotifierItemUnregistered s
		signal StatusNotifierHostRegistered ""
		signal StatusNotifierHostUnregistered ""
	}
	# an app that quits, or crashes, takes its icon with it
	set listen [$bus listen -sender org.freedesktop.DBus -interface org.freedesktop.DBus -member NameOwnerChanged \
		-command sniwatch::ignore sniwatch::owner_changed]
	set cmd [list $bus request $iface -replace [dict get $o -replace] -allowreplace 1]
	if {[dict get $o -command] ne ""} { lappend cmd -command [dict get $o -command] }
	{*}$cmd
}
proc sniwatch::ignore {args} {}

proc sniwatch::items {} { variable items; return $items }
proc sniwatch::Items {msg} { variable items; return $items }
proc sniwatch::HostRegistered {msg} { variable hosts; expr {[dict size $hosts] > 0} }

proc sniwatch::RegisterItem {msg service} {
	variable bus
	variable items
	variable owners
	variable path
	variable iface
	set sender [dict get $msg sender]
	if {[string index $service 0] eq "/"} {
		# an object path on the caller's own connection (libappindicator)
		set name $sender
		set opath $service
		if {![regexp {^/([A-Za-z0-9_]+(/[A-Za-z0-9_]+)*)?$} $opath]} {
			throw {DBUS org.freedesktop.DBus.Error.InvalidArgs} "not a bus name or an object path: $service"
		}
	} else {
		# a bus name: its object is /StatusNotifierItem (KStatusNotifierItem, Electron)
		set name $service
		set opath /StatusNotifierItem
		if {![regexp {^(:[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+|[A-Za-z_-][A-Za-z0-9_-]*(\.[A-Za-z_-][A-Za-z0-9_-]*)+)$} $name]} {
			throw {DBUS org.freedesktop.DBus.Error.InvalidArgs} "not a bus name or an object path: $service"
		}
	}
	set id $name$opath
	if {$id in $items} return
	lappend items $id
	# the unique name behind it: a well-known name is followed to whoever owns it now
	dict set owners $id [expr {[string index $name 0] eq ":" ? $name : $sender}]
	$bus emit $path $iface StatusNotifierItemRegistered s $id
	return
}

proc sniwatch::RegisterHost {msg service} {
	variable bus
	variable hosts
	variable path
	variable iface
	set first [expr {[dict size $hosts] == 0}]
	dict set hosts $service [dict get $msg sender]
	if {$first} { $bus emit $path $iface StatusNotifierHostRegistered }
	return
}

# NameOwnerChanged: a name that lost its owner takes its items (and hosts) with it.
proc sniwatch::owner_changed {msg name old new} {
	variable bus
	variable items
	variable owners
	variable hosts
	variable path
	variable iface
	if {$new ne ""} return
	foreach id $items {
		set item_name [string range $id 0 [expr {[string first / $id] - 1}]]
		if {$item_name eq $name || [dict get $owners $id] eq $name} {
			set items [lsearch -all -inline -exact -not $items $id]
			dict unset owners $id
			$bus emit $path $iface StatusNotifierItemUnregistered s $id
		}
	}
	set had [dict size $hosts]
	dict for {h u} $hosts { if {$h eq $name || $u eq $name} { dict unset hosts $h } }
	if {$had && ![dict size $hosts]} { $bus emit $path $iface StatusNotifierHostUnregistered }
}
