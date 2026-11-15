# main.tcl - the Ribbon shell: bars, launcher and menus, in Tcl/Tk.
#
# Run as: wish /usr/lib/ribbon/shell/main.tcl -name ribbon-shell
# Control: ribbon-shell-ctl open [app|files|web] | files [PATH] | wallpaper | reload | quit
# Ribbon Files on its own (no shell running): main.tcl --files [PATH]

set dir [file dirname [file normalize [info script]]]
# fault isolation first (shell/fault.tcl): the bgerror handler, the state file
# and the crash-loop policy, which may exit here (robustness 4a, 4b)
if {[file exists [file join $dir fault.tcl]]} {
	source -encoding utf-8 [file join $dir fault.tcl]
	# Ribbon Files on its own is not a shell start
	if {[lindex $argv 0] ne "--files"} { fault::start_policy }
}
# rbnalpha (C, /usr/lib/ribbon/rbnalpha): see-through rounded windows with
# real shadows, and raster.tcl's pixels in C. From the source tree its
# library comes from RBNALPHA_LIB; without it the shell still runs, with
# square opaque windows.
foreach d [list /usr/lib/ribbon [file dirname $dir]] { if {$d ni $auto_path} { lappend auto_path $d } }
package require rbnalpha
foreach f {text raster theme wm status apps bar dock launcher files controls updates} { source -encoding utf-8 [file join $dir $f.tcl] }
set files::standalone 0

namespace eval shell {}

proc shell::refresh {} {
	after cancel shell::refresh
	# A fullscreen window gets the whole screen: the bars and the dock step
	# aside until it leaves fullscreen or another window is focused.
	set f $wm::focus
	if {$f ne "" && [wm::has $f full] && ![wm::has $f min]} {
		if {[winfo ismapped .bar]} {
			panel::close
			launcher::cancel
			rbn::hide .bar
			rbn::hide .dock
		}
		return
	}
	# bar::draw shows the bars and the dock again (rbn::show)
	bar::draw
	launcher::anim_sync
}

proc shell::runtime {} {
	if {[info exists ::env(XDG_RUNTIME_DIR)]} { return $::env(XDG_RUNTIME_DIR) }
	return /tmp
}

# The D-Bus connection, for what needs one (the notification server, then
# the polkit agent, the portal, MPRIS): ribbon::dbus is loaded and the bus
# connected on the first call, never at start-up. A lost bus is connected
# again on the next call.
proc shell::bus {{which session}} {
	variable buses
	if {![info exists buses($which)]} {
		set lib [file dirname $::dir]
		if {$lib ni $::auto_path} { lappend ::auto_path $lib }
		package require ribbon::dbus
		set buses($which) [ribbon::dbus::connect $which -onclose [list shell::bus_lost $which]]
	}
	return $buses($which)
}
proc shell::bus_lost {which why} {
	variable buses
	catch {$buses($which) close}
	unset -nocomplain buses($which)
}

# Commands from ribbon-shell-ctl, through a FIFO.
proc shell::control {} {
	set f [file join [runtime] ribbon-shell]
	catch {file delete $f}
	if {[catch {exec mkfifo -m 600 $f}]} return
	set ch [open $f {RDWR NONBLOCK}]
	fconfigure $ch -blocking 0 -buffering line
	fileevent $ch readable [list shell::command $ch]
}

# A module (shell/mod-*.tcl) registers a ctl verb: shell::verb NAME PROC. The
# proc gets the words after the verb, as separate arguments.
namespace eval shell { variable verbs [dict create] }
proc shell::verb {name proc} {
	variable verbs
	dict set verbs $name $proc
}

proc shell::command {ch} {
	while {[gets $ch line] >= 0} {
		set args [split [string trim $line]]
		switch -- [lindex $args 0] {
			open { launcher::toggle [lindex $args 1] }
			files { files::show [string trim [string range $line 5 end]] }
			wallpaper { theme::load; shell::refresh }
			reload { shell::respawn restart }
			quit { shell::respawn stop }
			default {
				set verb [lindex $args 0]
				if {[dict exists $shell::verbs $verb]} {
					{*}[dict get $shell::verbs $verb] {*}[lrange $args 1 end]
				}
			}
		}
	}
}

# quit and reload under dinit: the supervisor is asked, so a quit is not
# restarted and a reload does not leave two shells. Not supervised (started by
# hand, or the autostart fallback), reload starts a new shell and quit exits.
proc shell::respawn {how} {
	# a terminal move in the last moments is written before the shell goes (mod-term debounces its saves)
	catch {if {$::term::saveafter ne ""} {after cancel $::term::saveafter; term::savestate}}
	if {$how eq "restart"} {
		if {[fault::supervised] && ![catch {exec dinitctl --user restart ribbon-shell &}]} { return }
		exec {*}[list [info nameofexecutable] [info script] -name ribbon-shell] &
		exit
	}
	if {[fault::supervised] && ![catch {exec dinitctl --user stop ribbon-shell &}]} { return }
	exit
}

proc shell::main {} {
	set home $::env(HOME)
	set cache [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$home/.cache"}]
	theme::load
	theme::fonts
	fault::load
	raster::init [file join $cache ribbon shell]
	rbn::init [file join $cache ribbon shell]
	bar::init
	dock::init
	bind . <FocusOut> {after 150 shell::focus_check}
	control
	# tests/shell-scene.tcl stands in for the compositor and sensors
	if {[info exists ::env(RIBBON_SHELL_TEST)]} { uplevel #0 [list source -encoding utf-8 $::env(RIBBON_SHELL_TEST)] } else {
		wm::start
		status::start
	}
	shell::refresh
}

# Leaving the shell (clicking a window) closes the launcher.
proc shell::focus_check {} {
	if {[focus -displayof .] eq ""} { launcher::cancel }
}

# Ribbon Files without the shell (another session, or the shell not running)
proc shell::files_only {path} {
	set home $::env(HOME)
	set cache [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$home/.cache"}]
	theme::load
	theme::fonts
	raster::init [file join $cache ribbon shell]
	rbn::init [file join $cache ribbon shell]
	wm withdraw .
	set files::standalone 1
	proc ::shell::refresh {} {}
	proc ::launcher::address {} {}
	files::show $path
}

# modules: shell/mod-*.tcl, in name order, after the core procs they call
foreach f [lsort [glob -nocomplain -directory $dir mod-*.tcl]] { source -encoding utf-8 $f }

if {[lindex $argv 0] eq "--files"} { shell::files_only [lindex $argv 1] } else { shell::main }
