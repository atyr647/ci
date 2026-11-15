# settings-display-scene.tcl - Settings → Display in one of the states, for
# screenshots and pixel checks (RIBBON_SETTINGS_SCENE=this file, sourced by
# apps/settings/main.tcl after the window is drawn). The outputs come from the
# stub wlr-randr on PATH (tests/steps.d/50-settings-display.sh).
#   RIBBON_DISPLAY_SCENE = board  (Settings-A1-Display: DP-1 selected, its scale at 125 %, pending)
#                        | popup  (the Resolution list open)
#                        | sheet  (after Apply: the keep-or-revert sheet)
#                        | single (one output)
# Every state waits for the read; the screenshot is RIBBON_SETTINGS_SHOT.
set dscene [expr {[info exists ::env(RIBBON_DISPLAY_SCENE)] ? $::env(RIBBON_DISPLAY_SCENE) : "board"}]
if {[info exists ::env(RIBBON_SETTINGS_EXIT)] || [info exists ::env(RIBBON_SETTINGS_SHOT)]} {
	proc bgerror {msg} { puts stderr "$msg\n$::errorInfo"; exit 1 }
}
settings::select display
after 400 [list display::scene $dscene]

# The run ends when the state is on screen, not at a fixed time: under load the event loop
# runs late and timers fire in a burst, so a fixed exit can come before the shot. The shot
# waits until nothing is in flight and the page has been drawn after the last read (after
# Apply the keep sheet appears only when the read that follows it has finished), then the
# run exits; with RIBBON_DISPLAY_REVERT the run also waits for the revert. Each wait has a
# deadline, so a stuck state still ends the run.
proc display::scene_done {{left 100}} {
	if {[array size display::bufs] > 0 || $display::loaded == 0 || ([info exists ::env(RIBBON_DISPLAY_REVERT)] && [llength $display::snapshot] > 0)} {
		if {$left > 0} { after 100 [list display::scene_done [expr {$left - 1}]]; return }
	}
	exit 0
}
proc display::scene_settled {shot {left 50}} {
	if {[array size display::bufs] > 0 || $display::loaded == 0} {
		if {$left > 0} { after 100 [list display::scene_settled $shot [expr {$left - 1}]]; return }
	}
	after 200 [list display::scene_shot $shot]
}
# RIBBON_DISPLAY_TEXTS = file: every string the page drew (one per line), written with the shot
set ::scene_texts {}
if {[info exists ::env(RIBBON_DISPLAY_TEXTS)]} {
	trace add execution ui::text enter [list ::apply {{cmd op} { lappend ::scene_texts [lindex $cmd 3] }}]
}
proc display::scene_shot {shot} {
	if {[info exists ::env(RIBBON_DISPLAY_TEXTS)]} {
		set ::scene_texts {}
		page::draw_now
		set fh [open $::env(RIBBON_DISPLAY_TEXTS) w]
		puts $fh [join [lsort -unique $::scene_texts] \n]
		close $fh
	}
	exec import -window root $shot
	display::scene_done
}
if {[info exists ::env(RIBBON_SETTINGS_SHOT)]} {
	after 1500 [list display::scene_settled $::env(RIBBON_SETTINGS_SHOT)]
	set ms [expr {[info exists ::env(RIBBON_SETTINGS_EXIT)] ? $::env(RIBBON_SETTINGS_EXIT) : 2500}]
	after [expr {$ms + 10000}] exit 0
} else {
	set ms [expr {[info exists ::env(RIBBON_SETTINGS_EXIT)] ? $::env(RIBBON_SETTINGS_EXIT) : 2500}]
	after $ms exit 0
}
