# ribbon::dbus: a D-Bus client in pure Tcl (dbus.tcl). Installed in
# /usr/lib/ribbon/dbus; lappend auto_path /usr/lib/ribbon to find it.
package ifneeded ribbon::dbus 1.0 [list source -encoding utf-8 [file join $dir dbus.tcl]]
