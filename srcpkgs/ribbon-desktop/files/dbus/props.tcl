# props.tcl - ribbon::dbus: properties of the objects we export
# (org.freedesktop.DBus.Properties) and object managers
# (org.freedesktop.DBus.ObjectManager). dbus.tcl reads this file the first
# time an export declares a property or $bus manage is called.
#
# In export:  property NAME SIG ACCESS {?-value V? ?-get CMD? ?-set CMD? ?-emits E?}
#   ACCESS read, write or readwrite. The value is kept here (-value), or
#   asked for each time (-get CMD, called with the MSG of the Get, or {}).
#   -set CMD is called with MSG VALUE before a remote Set takes effect; it
#   may throw {DBUS NAME} to refuse it. -emits is the EmitsChangedSignal
#   annotation: true (default; PropertiesChanged carries the value),
#   invalidates (only the name), const or false (no signal).
#
#   $bus set PATH IFACE NAME VALUE ?NAME VALUE...?   one PropertiesChanged
#   $bus changed PATH IFACE NAME...                  for -get properties
#   $bus get PATH IFACE NAME
#   $bus manage PATH      PATH answers GetManagedObjects for the objects
#                         under it, and signals InterfacesAdded/Removed

namespace eval ribbon::dbus::props {
	variable emits org.freedesktop.DBus.Property.EmitsChangedSignal
}

proc ribbon::dbus::props::declare {name sig access popts} {
	ribbon::dbus::onetype $sig
	if {$access ni {read write readwrite}} { error "property $name: access is read, write or readwrite, not \"$access\"" }
	if {[llength $popts] % 2} { error "property $name: options come in pairs" }
	set p [dict merge {-get "" -set "" -emits true} $popts]
	dict for {k v} $p {
		if {$k ni {-value -get -set -emits}} { error "property $name: unknown option $k" }
	}
	if {[dict get $p -emits] ni {true invalidates const false}} { error "property $name: -emits is true, invalidates, const or false" }
	if {$access ne "write" && ![dict exists $p -value] && [dict get $p -get] eq ""} { error "property $name needs -value or -get" }
	if {[dict exists $p -value]} { ribbon::dbus::marshal $sig [list [dict get $p -value]] }
	dict create sig $sig access $access value [expr {[dict exists $p -value] ? [dict get $p -value] : ""}] \
		get [dict get $p -get] set [dict get $p -set] emits [dict get $p -emits]
}

proc ribbon::dbus::props::spec {bus path iface name} {
	upvar #0 $bus c
	if {![dict exists $c(objs) $path $iface props $name]} {
		ribbon::dbus::fail org.freedesktop.DBus.Error.UnknownProperty "no property $name in $iface at $path"
	}
	dict get $c(objs) $path $iface props $name
}

proc ribbon::dbus::props::value {bus path iface name msg} {
	set p [spec $bus $path $iface $name]
	if {[dict get $p get] eq ""} { return [dict get $p value] }
	uplevel #0 [list {*}[dict get $p get] $msg]
}

# The readable properties of an interface, as a{sv}.
proc ribbon::dbus::props::all {bus path iface msg} {
	upvar #0 $bus c
	set out {}
	if {[dict exists $c(objs) $path $iface props]} {
		dict for {name p} [dict get $c(objs) $path $iface props] {
			if {[dict get $p access] ne "write"} { dict set out $name [list [dict get $p sig] [value $bus $path $iface $name $msg]] }
		}
	}
	return $out
}

# PropertiesChanged for these properties, as their annotations say.
proc ribbon::dbus::props::emit {bus path iface names} {
	set changed {}
	set invalid {}
	foreach name $names {
		set p [spec $bus $path $iface $name]
		switch -- [dict get $p emits] {
			true {
				if {[dict get $p access] eq "write"} { lappend invalid $name; continue }
				dict set changed $name [list [dict get $p sig] [value $bus $path $iface $name {}]]
			}
			invalidates { lappend invalid $name }
		}
	}
	if {[dict size $changed] || [llength $invalid]} {
		ribbon::dbus::Emit $bus $path org.freedesktop.DBus.Properties PropertiesChanged sa{sv}as $iface $changed $invalid
	}
}

proc ribbon::dbus::props::Set {bus path iface args} {
	upvar #0 $bus c
	if {![llength $args] || [llength $args] % 2} { error "wrong # args: should be \"$bus set path interface name value ?name value ...?\"" }
	dict for {name v} $args {
		set p [spec $bus $path $iface $name]
		if {[dict get $p get] ne ""} { error "$name is read with -get: say \"$bus changed\" instead" }
		ribbon::dbus::marshal [dict get $p sig] [list $v]
	}
	dict for {name v} $args { dict set c(objs) $path $iface props $name value $v }
	emit $bus $path $iface [dict keys $args]
}

proc ribbon::dbus::props::Changed {bus path iface args} { emit $bus $path $iface $args }
proc ribbon::dbus::props::Get {bus path iface name} { value $bus $path $iface $name {} }

proc ribbon::dbus::props::Manage {bus path} {
	upvar #0 $bus c
	ribbon::dbus::objpath $path
	dict set c(managers) $path 1
}

proc ribbon::dbus::props::under {root path} {
	expr {$path ne $root && ($root eq "/" || [string first $root/ $path] == 0)}
}

proc ribbon::dbus::props::managed {bus root} {
	upvar #0 $bus c
	set out {}
	dict for {path ifaces} $c(objs) {
		if {![under $root $path]} continue
		set d {}
		foreach iface [dict keys $ifaces] { dict set d $iface [all $bus $path $iface {}] }
		dict set out $path $d
	}
	return $out
}

# export and unexport tell the object managers above the path.
proc ribbon::dbus::props::added {bus path iface} {
	upvar #0 $bus c
	if {![info exists c(managers)]} return
	foreach root [dict keys $c(managers)] {
		if {[under $root $path]} {
			ribbon::dbus::Emit $bus $root org.freedesktop.DBus.ObjectManager InterfacesAdded oa{sa{sv}} \
				$path [dict create $iface [all $bus $path $iface {}]]
		}
	}
}
proc ribbon::dbus::props::removed {bus path ifaces} {
	upvar #0 $bus c
	if {![info exists c(managers)]} return
	foreach root [dict keys $c(managers)] {
		if {[under $root $path]} { ribbon::dbus::Emit $bus $root org.freedesktop.DBus.ObjectManager InterfacesRemoved oas $path $ifaces }
	}
}

# A call to org.freedesktop.DBus.Properties or .ObjectManager: 1 if answered.
proc ribbon::dbus::props::incoming {bus m} {
	upvar #0 $bus c
	set path [dict get $m path]
	set member [dict get $m member]
	set sig [dict get $m signature]
	set body [dict get $m body]
	if {[dict get $m interface] eq "org.freedesktop.DBus.ObjectManager"} {
		if {![info exists c(managers)] || ![dict exists $c(managers) $path]} { return 0 }
		if {$member eq "GetManagedObjects" && $sig eq ""} {
			ribbon::dbus::answer $bus $m a{oa{sa{sv}}} [list [managed $bus $path]]
		} else {
			ribbon::dbus::answer $bus $m s [list "no method $member"] org.freedesktop.DBus.Error.UnknownMethod
		}
		return 1
	}
	if {![dict exists $c(objs) $path]} { return 0 }
	set sigs {Get ss GetAll s Set ssv}
	set want [expr {[dict exists $sigs $member] ? [dict get $sigs $member] : ""}]
	set rc [catch {
		if {$want eq "" || $sig ne $want} {
			throw [list DBUS org.freedesktop.DBus.Error.[expr {$want eq "" ? "UnknownMethod" : "InvalidArgs"}]] \
				"Properties.$member takes \"$want\", not \"$sig\""
		}
		set name [lassign $body iface]
		if {$iface ne "" && ![dict exists $c(objs) $path $iface]} {
			throw [list DBUS org.freedesktop.DBus.Error.UnknownInterface] "no interface $iface at $path"
		}
		if {$member eq "GetAll"} {
			ribbon::dbus::answer $bus $m a{sv} [list [all $bus $path $iface $m]]
			return 1
		}
		lassign $name name v
		# an empty interface: the first that has the property
		if {$iface eq ""} {
			foreach i [dict keys [dict get $c(objs) $path]] {
				if {[dict exists $c(objs) $path $i props $name]} { set iface $i; break }
			}
		}
		set p [spec $bus $path $iface $name]
		if {$member eq "Get"} {
			if {[dict get $p access] eq "write"} { throw [list DBUS org.freedesktop.DBus.Error.AccessDenied] "$name can only be written" }
			ribbon::dbus::answer $bus $m v [list [list [dict get $p sig] [value $bus $path $iface $name $m]]]
			return 1
		}
		if {[dict get $p access] eq "read"} { throw [list DBUS org.freedesktop.DBus.Error.PropertyReadOnly] "$name is read-only" }
		lassign $v vsig val
		if {$vsig ne [dict get $p sig]} { throw [list DBUS org.freedesktop.DBus.Error.InvalidArgs] "$name is \"[dict get $p sig]\", not \"$vsig\"" }
		if {[dict get $p set] ne ""} { uplevel #0 [list {*}[dict get $p set] $m $val] }
		if {[dict get $p get] eq "" && [ribbon::dbus::alive $bus]} { dict set c(objs) $path $iface props $name value $val }
		ribbon::dbus::answer $bus $m "" {}
		emit $bus $path $iface [list $name]
	} err opts]
	if {$rc == 1} {
		ribbon::dbus::closefds $m
		ribbon::dbus::answer $bus $m s [list $err] [ribbon::dbus::errname $opts]
	}
	return 1
}

proc ribbon::dbus::props::xml {props} {
	variable emits
	set x ""
	dict for {name p} $props {
		append x "  <property name=\"$name\" type=\"[dict get $p sig]\" access=\"[dict get $p access]\""
		if {[dict get $p emits] eq "true"} { append x "/>\n"; continue }
		append x ">\n   <annotation name=\"$emits\" value=\"[dict get $p emits]\"/>\n  </property>\n"
	}
	return $x
}

# The standard interfaces this file answers for, at path.
proc ribbon::dbus::props::standard {bus path} {
	upvar #0 $bus c
	set x ""
	if {[dict exists $c(objs) $path]} {
		append x " <interface name=\"org.freedesktop.DBus.Properties\">\n"
		append x "  <method name=\"Get\"><arg type=\"s\" direction=\"in\"/><arg type=\"s\" direction=\"in\"/><arg type=\"v\" direction=\"out\"/></method>\n"
		append x "  <method name=\"GetAll\"><arg type=\"s\" direction=\"in\"/><arg type=\"a{sv}\" direction=\"out\"/></method>\n"
		append x "  <method name=\"Set\"><arg type=\"s\" direction=\"in\"/><arg type=\"s\" direction=\"in\"/><arg type=\"v\" direction=\"in\"/></method>\n"
		append x "  <signal name=\"PropertiesChanged\"><arg type=\"s\"/><arg type=\"a{sv}\"/><arg type=\"as\"/></signal>\n </interface>\n"
	}
	if {[info exists c(managers)] && [dict exists $c(managers) $path]} {
		append x " <interface name=\"org.freedesktop.DBus.ObjectManager\">\n"
		append x "  <method name=\"GetManagedObjects\"><arg type=\"a{oa{sa{sv}}}\" direction=\"out\"/></method>\n"
		append x "  <signal name=\"InterfacesAdded\"><arg type=\"o\"/><arg type=\"a{sa{sv}}\"/></signal>\n"
		append x "  <signal name=\"InterfacesRemoved\"><arg type=\"o\"/><arg type=\"as\"/></signal>\n </interface>\n"
	}
	return $x
}
