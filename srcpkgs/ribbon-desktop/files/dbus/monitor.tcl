# monitor.tcl - ribbon::dbus: $bus monitor, the bus's BecomeMonitor (what
# dbus-monitor uses). dbus.tcl reads this file on the first $bus monitor.
#
#   $bus monitor ?-command CB? ?RULE ...? HANDLER
#     RULE is a match rule as a dict (type method_call interface org.x ...);
#     none: everything. From then on the connection only watches: HANDLER
#     gets every message it is sent (a MSG dict) and nothing can be sent.

namespace eval ribbon::dbus::monitor {}

proc ribbon::dbus::monitor::Monitor {bus args} {
	set o [ribbon::dbus::opts args {-command ""}]
	if {![llength $args]} { error "wrong # args: should be \"$bus monitor ?-command cb? ?rule ...? handler\"" }
	set rules [lmap r [lrange $args 0 end-1] { ribbon::dbus::rule $r }]
	set go [list [namespace current]::Become $bus $rules [lindex $args end]]
	if {[dict get $o -command] eq ""} { return [ribbon::dbus::await $go] }
	{*}$go [dict get $o -command]
}

proc ribbon::dbus::monitor::Become {bus rules handler cb} {
	ribbon::dbus::Pending $bus 25000 0 {path /org/freedesktop/DBus interface org.freedesktop.DBus.Monitoring
		member BecomeMonitor destination org.freedesktop.DBus} asu [list $rules 0] [list [namespace current]::became $bus $handler $cb]
}

proc ribbon::dbus::monitor::became {bus handler cb status values} {
	upvar #0 $bus c
	if {$status eq "ok" && [ribbon::dbus::alive $bus]} { set c(monitor) $handler }
	ribbon::dbus::run $cb $status $values
}
