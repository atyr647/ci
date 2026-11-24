# screensaver.tcl - org.freedesktop.ScreenSaver for the Ribbon session (power-idle's inhibitors). Games under Proton and
# SDL, Steam, Chromium, Firefox and video players under XWayland ask the session bus not to blank the screen with
# Inhibit(application, reason) -> cookie, and give it back with UnInhibit(cookie). swayidle only sees the Wayland
# idle-inhibit protocol, so this keeps the list and power-idle.tcl asks it on every pass: while one is held, the idle
# timers (dim, screen off, lock, suspend) are left out. xdg-desktop-portal-gtk's Inhibit (the portal for flatpak apps)
# falls back to this interface too when no GNOME session manager is there.
#
#   tclsh /usr/lib/ribbon/settings/screensaver.tcl     (D-Bus activated: dbus-services/org.freedesktop.ScreenSaver.service)
#
# On /org/freedesktop/ScreenSaver and /ScreenSaver (apps use either):
#   org.freedesktop.ScreenSaver   Inhibit ss -> u, UnInhibit u
#   org.ribbon.ScreenSaver        Inhibitors -> a(usss): cookie, application, reason, the holder's unique bus name
# An inhibit is dropped when its holder leaves the bus (a game that crashes does not keep the screen on). An unknown
# cookie is ignored, as other desktops do. The service leaves when the session bus goes.

foreach d [list /usr/lib/ribbon [file dirname [file dirname [file dirname [file normalize [info script]]]]]] {
	if {$d ni $::auto_path} { lappend ::auto_path $d }
}
package require ribbon::dbus

namespace eval screensaver {
	variable bus ""
	variable next 0
	variable held {}   ;# cookie -> {application reason sender}
	variable name org.freedesktop.ScreenSaver
}

proc screensaver::Inhibit {msg app reason} {
	variable next
	variable held
	set cookie [incr next]
	dict set held $cookie [list $app $reason [dict get $msg sender]]
	return $cookie
}

# Only the connection that took an inhibit gives it back; another's cookie is ignored like an unknown one.
proc screensaver::UnInhibit {msg cookie} {
	variable held
	if {[dict exists $held $cookie] && [lindex [dict get $held $cookie] 2] eq [dict get $msg sender]} {
		dict unset held $cookie
	}
	return
}

proc screensaver::Inhibitors {msg} {
	variable held
	set out {}
	dict for {cookie v} $held { lappend out [list $cookie {*}$v] }
	return $out
}

# NameOwnerChanged: a unique name that has gone takes its inhibits with it.
proc screensaver::owner {msg name old new} {
	variable held
	if {$new ne "" || ![string match :* $name]} return
	dict for {cookie v} $held {
		if {[lindex $v 2] eq $name} { dict unset held $cookie }
	}
}

proc screensaver::start {{address session}} {
	variable bus
	variable name
	set bus [ribbon::dbus::connect $address -onclose {apply {{why} { exit 0 }}}]
	# watching for holders that leave starts before the name is taken, so no Inhibit can come in ahead of it
	$bus listen -sender org.freedesktop.DBus -interface org.freedesktop.DBus -member NameOwnerChanged screensaver::owner
	foreach path {/org/freedesktop/ScreenSaver /ScreenSaver} {
		$bus export $path org.freedesktop.ScreenSaver {
			method Inhibit ss u screensaver::Inhibit
			method UnInhibit u "" screensaver::UnInhibit
		}
		$bus export $path org.ribbon.ScreenSaver {
			method Inhibitors "" a(usss) screensaver::Inhibitors
		}
	}
	$bus request $name -noqueue 1
}

if {[info exists ::argv0] && [file normalize $::argv0] eq [file normalize [info script]]} {
	if {[screensaver::start] ne "primary"} { puts stderr "screensaver: org.freedesktop.ScreenSaver has an owner"; exit 1 }
	vwait forever
}
