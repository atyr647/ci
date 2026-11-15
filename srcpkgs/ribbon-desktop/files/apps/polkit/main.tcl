# main.tcl - ribbon-polkit: the polkit authentication agent for the session (C6: its own process,
# so the password never lives in the shell). The agent is agent.tcl; this file connects it to the
# system bus and to the card (card.tcl, which only draws). Keys come from ribbon-polkit-keys, a native
# Wayland helper started by the agent; without it there is no prompt and the request fails.
#
#   ribbon-polkit            (autostart; exits 1 if it cannot register)

set here [file dirname [file normalize [info script]]]
# /usr/lib/ribbon (installed) or the repo's files/ (two up from files/apps/polkit)
foreach d [list /usr/lib/ribbon [file dirname [file dirname $here]]] { if {$d ni $auto_path} { lappend auto_path $d } }
package require Tk
source -encoding utf-8 [file join $here agent.tcl]
wm withdraw .

# A background error is logged as its first line only: the full trace can hold the arguments
# of whatever was running, and the agent must never print what it was given.
interp bgerror {} {apply {{msg opts} { polkit::log "background error: [lindex [split $msg \n] 0]" }}}

source -encoding utf-8 [file join $here card.tcl]
card::setup
card::colours

# A board state without a bus or an agent (tests/steps.d/70-polkit-card.sh): the file draws a card with card::show.
if {[info exists env(RIBBON_POLKIT_SCENE)] && $env(RIBBON_POLKIT_SCENE) ne ""} {
	namespace eval polkit {
		proc focus {args} {}
		proc choose {args} {}
		proc cancel {args} {}
		proc submit {args} { return 1 }
	}
	source -encoding utf-8 $env(RIBBON_POLKIT_SCENE)
	return
}
package require ribbon::dbus
set ui [card::table]

# Test hooks (tests/steps.d/70-polkit.sh). RIBBON_POLKIT_TEST names a Tcl file to source once the
# agent is registered; only then are the helper path and the session id taken from the environment.
# The helpers receive the password, so the real paths are never overridable in normal use.
set opts [list -ui $ui -registered {registered}]
if {[info exists env(RIBBON_POLKIT_TEST)] && $env(RIBBON_POLKIT_TEST) ne ""} {
	if {[info exists env(RIBBON_POLKIT_HELPER)]} { lappend opts -helper $env(RIBBON_POLKIT_HELPER) }
	if {[info exists env(RIBBON_POLKIT_KEYS)]} { lappend opts -keys $env(RIBBON_POLKIT_KEYS) }
	foreach {v f} {RIBBON_POLKIT_PASSWD passwd RIBBON_POLKIT_GROUP group} {
		if {[info exists env($v)]} { set ::polkit::$f $env($v) }
	}
}
if {[info exists env(XDG_SESSION_ID)] && $env(XDG_SESSION_ID) ne ""} { lappend opts -session $env(XDG_SESSION_ID) }

proc registered {status values} {
	if {$status ne "ok"} { polkit::log "exiting: not registered"; exit 1 }
	if {[info exists ::env(RIBBON_POLKIT_TEST)] && $::env(RIBBON_POLKIT_TEST) ne ""} {
		source -encoding utf-8 $::env(RIBBON_POLKIT_TEST)
	}
}

if {[catch {ribbon::dbus::connect system} bus]} {
	polkit::log "no system bus: [lindex [split $bus \n] 0]"
	exit 1
}
polkit::start $bus {*}$opts
