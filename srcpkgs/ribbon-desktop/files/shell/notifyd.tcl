# notifyd.tcl - the D-Bus side of the shell's notification server:
# org.freedesktop.Notifications (Desktop Notifications 1.2) on ribbon::dbus.
# The popups and the history are mod-notify.tcl's; this file only speaks D-Bus.
#
#   notifyd::start BUS ?-show CMD? ?-close CMD? ?-replace 1?
#       -> primary, queued, exists or owner (as $bus request)
#   -show CMD    called with a notification dict: id app icon summary body
#                actions (a list: key label ...) hints (variants stripped)
#                urgency (0 low, 1 normal, 2 critical) timeout (ms; -1 the
#                server's choice, 0 never) sender replaces (1 if it did)
#   -close CMD   called with ID when an app asks to close one
#   notifyd::invoked ID KEY      the person picked an action
#   notifyd::closed ID REASON    1 expired, 2 dismissed, 3 asked to, 4 other
#
# Nothing here loads ribbon::dbus: the caller passes a bus, and the shell
# gets one with shell::bus (mod-notify.tcl does, after the shell is up).

namespace eval notifyd {
	variable bus ""
	variable next 0
	variable live {}        ;# id -> the notification dict
	variable show ""
	variable close ""
	variable capabilities {actions body body-markup icon-static persistence}
	variable path /org/freedesktop/Notifications
	variable iface org.freedesktop.Notifications
}

proc notifyd::start {b args} {
	variable bus $b
	variable show
	variable close
	variable path
	variable iface
	set o [dict merge {-show "" -close "" -replace 0} $args]
	set show [dict get $o -show]
	set close [dict get $o -close]
	$bus export $path $iface {
		method GetCapabilities "" as notifyd::Capabilities
		method Notify susssasa{sv}i u notifyd::Notify
		method CloseNotification u "" notifyd::Close
		method GetServerInformation "" ssss notifyd::Information
		signal NotificationClosed uu
		signal ActionInvoked us
		signal ActivationToken us
	}
	$bus request $iface -replace [dict get $o -replace] -allowreplace 1
}

proc notifyd::Capabilities {msg} { variable capabilities; return $capabilities }
proc notifyd::Information {msg} { list "Ribbon shell" Ribbon 0.1 1.2 }

proc notifyd::Notify {msg app replaces icon summary body actions hints timeout} {
	variable next
	variable live
	variable show
	if {$replaces && [dict exists $live $replaces]} {
		set id $replaces
	} else {
		set id [incr next]
	}
	set h [ribbon::dbus::strip a{sv} $hints]
	# the urgency is a byte, 0 to 2; anything else is normal
	set urgency 1
	if {[dict exists $h urgency] && [dict get $h urgency] in {0 1 2}} { set urgency [dict get $h urgency] }
	set n [dict create id $id app $app icon $icon summary $summary body $body actions $actions hints $h \
		urgency $urgency timeout $timeout \
		sender [dict get $msg sender] replaces [expr {$id == $replaces}]]
	dict set live $id $n
	if {$show ne ""} { uplevel #0 [list {*}$show $n] }
	return $id
}

proc notifyd::Close {msg id} {
	variable live
	variable close
	if {![dict exists $live $id]} return
	if {$close ne ""} { uplevel #0 [list {*}$close $id] }
	closed $id 3
	return
}

# Both signals are broadcast, as dunst and GNOME Shell do: apps watch for
# them on another connection than the one that sent Notify.
proc notifyd::invoked {id key} {
	variable bus
	variable live
	variable path
	variable iface
	if {![dict exists $live $id]} return
	$bus emit $path $iface ActionInvoked us $id $key
}

proc notifyd::closed {id reason} {
	variable bus
	variable live
	variable path
	variable iface
	if {![dict exists $live $id]} return
	dict unset live $id
	$bus emit $path $iface NotificationClosed uu $id $reason
}
