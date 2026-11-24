# mod-tray.tcl - apps' tray icons and the bar's tooltips (boards Tray-1-Icons, Tray-2-Menu, Tooltip-1-Bar;
# design/tools/gen_tray.py). A shell module (C2).
#
# Once the shell is up it serves the StatusNotifierWatcher on the session bus (sniwatch.tcl) and is its host
# (tray.tcl): Steam, Discord and every app with a tray icon put it in the right bar, left of the quick-settings
# button, where a click shows the app's window or its menu. bar.tcl lays the icons out (tray::width, tray::draw)
# and controls.tcl draws the menu as the bar's panel "sni" (tray::menu_draw). With no session bus the shell runs
# on without them.
#
# The bar's icon-only buttons have tooltips (tooltip.tcl): their names, read from the bar's own hit list so
# bar.tcl only draws.

foreach f {sniwatch tray tooltip} { source -encoding utf-8 [file join [file dirname [file normalize [info script]]] $f.tcl] }

namespace eval traymod {
	variable status ""      ;# the watcher's: primary, queued, exists, owner, or "off: why"
}

proc traymod::log {msg} {
	set d [file join [expr {[info exists ::env(XDG_STATE_HOME)] && $::env(XDG_STATE_HOME) ne "" ? $::env(XDG_STATE_HOME) : "$::env(HOME)/.local/state"}] ribbon]
	catch {
		file mkdir $d
		set fh [open [file join $d shell.log] a]
		puts $fh "[clock format [clock seconds] -format %H:%M:%S] tray: $msg"
		close $fh
	}
}

proc traymod::start {} {
	variable status
	if {[catch {set bus [shell::bus]} err]} {
		set status "off: no session bus"
		log "the tray does not start: $err"
		return
	}
	if {[catch {
		sniwatch::start $bus -command traymod::watching
		tray::start $bus -onchange shell::refresh
	} err]} {
		set status "off: $err"
		log "the tray does not start: $err"
	}
}
proc traymod::watching {st values} {
	variable status [lindex $values 0]
	if {$status ne "primary"} { log "org.kde.StatusNotifierWatcher is $status, not ours: the bar is a host of that one" }
}

# The bar's buttons that are only an icon, and their names: the scripts bar::draw puts in its hit list.
proc traymod::bar_name {script} {
	switch -- [lindex $script 0] {
		tray::press { return [tray::name [lindex $script 1]] }
		nhist::bell { return Notifications }
		status::updates_click { return Updates }
		bar::wctl {
			# dimmed with no window to act on (they do nothing then): no names
			if {$wm::focus eq ""} { return "" }
			switch -- [lindex $script 1] {
				min { return Minimise }
				max { return [expr {$wm::focus ne "" && [wm::has $wm::focus max] ? "Restore" : "Maximise"}] }
				close { return Close }
			}
		}
		panel::toggle {
			switch -- [lindex $script 1] { tray { return "Quick settings" } session { return Power } }
		}
	}
	return ""
}

# tip::attach's resolver for .bar.c: the button under x y, its name, and the bar's top and bottom (8 and 46).
proc traymod::bar_tip {x y} {
	foreach h $bar::hits {
		lassign $h x0 y0 x1 y1 script
		if {$x < $x0 || $x >= $x1 || $y < $y0 || $y >= $y1} continue
		set name [bar_name $script]
		if {$name eq ""} { return "" }
		return [list $script $name [expr {($x0 + $x1) / 2.0}] 8 46 below]
	}
	return ""
}

proc traymod::init {} {
	# Ribbon Files on its own (main.tcl --files) has no bar
	if {[info exists ::files::standalone] && $::files::standalone} return
	if {![winfo exists .bar.c]} { after 100 traymod::init; return }
	# the pointer over the tray's icons lights them (a bind tag of the tray's own, first, so bar.tcl's stay)
	if {"TrayBar" ni [bindtags .bar.c]} { bindtags .bar.c [linsert [bindtags .bar.c] 0 TrayBar] }
	bind TrayBar <Motion> {tray::bar_motion %x %y}
	bind TrayBar <Leave> {tray::bar_motion -1 -1}
	tip::attach .bar.c traymod::bar_tip
	# a panel opening takes the tooltip down; the menu closes with the panel
	trace add variable ::panel::open write {apply {args { tip::hide; tray::panel_moved }}}
	traymod::start
}
after idle traymod::init
