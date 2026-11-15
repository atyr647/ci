# foot.tcl - the Ledger rail's foot (Monitor-R3-Ledger): the game overlay's Compact panel as a card, there while
# a game runs. It shows the game's name, how long it has run, and the overlay's frame figures (FPS, frame time,
# 1 % low, the last 60 frames); a click starts the overlay in its Compact layout (`ribbon-hud layout compact`).
#
# A game is found the way the overlay finds one among the processes (apps/hud/hud-games.tcl): a process with
# SteamAppId or HEROIC_APP_NAME in its environment, a lutris:rungame/SLUG argument, or the program of a game added
# by hand in Settings (the overlay's store, read through apps/hud/hud-store.tcl when it is installed). The newest
# one is shown.
#
# Frames come from the file a layer in the game writes (RIBBON_HUD_FRAMES, the overlay's "Automatic" source). The
# compositor's pipe belongs to the overlay's daemon (a pipe has one reader), so a game that only gamescope reports
# shows the overlay's own "No frame data" state here.

namespace eval monitor::game {
	variable known          ;# pid/start -> 1 (a game) or 0
	array set known {}
	variable store ""       ;# the overlay's store: "" not looked for yet, 0 not installed, 1 loaded
	variable byhand {}      ;# the programs of the games added by hand
}

# The programs of the games added by hand ({} without the overlay's store).
proc monitor::game::programs {} {
	variable store
	if {$store eq ""} {
		set store 0
		foreach d [list [file join $::appdir .. hud] /usr/lib/ribbon/hud] {
			set f [file join $d hud-store.tcl]
			if {[file readable $f] && ![catch {uplevel #0 [list source -encoding utf-8 $f]}]} { set store 1; break }
		}
	}
	if {!$store} { return {} }
	set out {}
	catch {
		if {[::hud::store::changed]} { ::hud::store::load }
		foreach {k prog} [::hud::store::programs] { lappend out $prog }
	}
	return $out
}

# Is this process (a dict from monitor::scan) a game by its own environment or arguments?
proc monitor::game::is {p} {
	variable known
	set k [dict get $p pid]/[dict get $p start]
	if {[info exists known($k)]} { return $known($k) }
	variable byhand
	set dir [file join $::monitor::proc_root [dict get $p pid]]
	set argv [split [string trimright [::monitor::slurp [file join $dir cmdline]] \0] \0]
	set yes 0
	foreach a $argv { if {[regexp {^lutris:rungame/[^/\s]+$} $a] || $a in $byhand} { set yes 1; break } }
	if {!$yes && [llength $byhand] && ![catch {file readlink [file join $dir exe]} exe] && $exe in $byhand} { set yes 1 }
	if {!$yes} {
		foreach e [split [::monitor::slurp [file join $::monitor::proc_root [dict get $p pid] environ]] \0] {
			if {[regexp {^(SteamAppId=[1-9][0-9]*|HEROIC_APP_NAME=.+)$} $e]} { set yes 1; break }
		}
	}
	return [set known($k) $yes]
}

# The game running now: dict pid name secs (how long it has run), or "". procs: the scan's dicts; names: dict
# pid -> the app's name.
proc monitor::game::find {procs names} {
	variable known
	variable byhand
	set now [programs]
	if {$now ne $byhand} { set byhand $now; array unset known }
	set best ""
	set live {}
	foreach p $procs {
		lappend live [dict get $p pid]/[dict get $p start]
		if {![is $p]} continue
		if {$best eq "" || [dict get $p start] > [dict get $best start]} { set best $p }
	}
	foreach k [array names known] { if {$k ni $live} { unset known($k) } }
	if {$best eq ""} { return "" }
	set pid [dict get $best pid]
	set up 0.0
	scan [::monitor::slurp [file join $::monitor::proc_root uptime]] %f up
	set secs [expr {max(0, int($up - [dict get $best start] / double($::monitor::clk)))}]
	set name [expr {[dict exists $names $pid] && [dict get $names $pid] ni {"" Background} ? [dict get $names $pid] : [dict get $best comm]}]
	return [dict create pid $pid name $name secs $secs]
}

# "1 h 17 min", "12 min", "40 s".
proc monitor::fmt_span {secs} {
	if {$secs >= 3600} { return "[expr {$secs / 3600}] h [expr {$secs % 3600 / 60}] min" }
	if {$secs >= 60} { return "[expr {$secs / 60}] min" }
	return "$secs s"
}

# The frame figures, as the overlay works them out (apps/hud/hud-frames.tcl): frame time is the mean of the last
# 30 frames, FPS 1000 over it, 1 % low 1000 over the 99th-percentile time of the last 600, the series the last
# 60 on a 0-20 ms scale. Words are frame times in ms, or fps=N. {ok 0} when the file has had nothing for 2 s.
proc monitor::game::frames {} {
	if {![info exists ::env(RIBBON_HUD_FRAMES)]} { return [dict create ok 0] }
	set f $::env(RIBBON_HUD_FRAMES)
	if {[catch {file stat $f st}] || $st(type) ne "file" || [clock seconds] - $st(mtime) > 2} { return [dict create ok 0] }
	if {[catch {
		set ch [::open $f r]
		if {$st(size) > 16384} { seek $ch -16384 end; gets $ch }
		set text [::read $ch]
		::close $ch
	}]} { return [dict create ok 0] }
	set times {}
	foreach w [regexp -all -inline {\S+} $text] {
		if {[regexp {^fps=([\d.]+)$} $w -> n] && $n > 0} { lappend times [expr {1000.0 / $n}] } \
		elseif {[string is double -strict $w] && $w > 0} { lappend times [expr {double($w)}] }
	}
	set times [lrange $times end-599 end]
	if {![llength $times]} { return [dict create ok 0] }
	set recent [lrange $times end-29 end]
	set ft [expr {[tcl::mathop::+ {*}$recent] / [llength $recent]}]
	set sorted [lsort -real $times]
	set p99 [lindex $sorted [expr {max(0, int(ceil(0.99 * [llength $sorted])) - 1)}]]
	set series [lmap t [lrange $times end-59 end] {expr {min(100.0, max(0.0, $t / 20.0 * 100))}}]
	return [dict create ok 1 fps [expr {round(1000.0 / $ft)}] ft [format %.1f $ft] low [expr {round(1000.0 / $p99)}] series $series]
}

# Start the overlay's Compact layout.
proc monitor::hud_compact {args} {
	if {$::monitor::scene} return
	catch {::exec {*}$::monitor::cmd(hud) layout compact >/dev/null 2>/dev/null &}
}

# The card: 236 x 138 at 16,606 in the rail, 16 px above the window's foot (DY: the window's height past the board's).
# A window too short to hold it under the rail's rows leaves it out. m: the model (its game and frames).
proc monitor::foot_draw {m} {
	if {![dict exists $m game] || [dict get $m game] eq ""} return
	set dy [expr {$::monitor::H - 760}]
	if {606 + $dy < 500} return
	set g [dict get $m game]
	set fr [expr {[dict exists $m frames] ? [dict get $m frames] : [dict create ok 0]}]
	set ok [dict get $fr ok]
	set c $ui::c(field)
	ui::box 16 [expr {606 + $dy}] 236 138 -fill $c -radius 12 -ring [list $ui::c(border) 1]
	ui::box 30 [expr {618 + $dy}] 20 20 -fill $ui::c(pill) -radius 5
	ui::icon game 12 $ui::c(muted) 34 [expr {622 + $dy}] 1.9
	set tw [ui::text 238 [expr {620 + $dy}] [fmt_span [dict get $g secs]] i12 $ui::c(muted) e 0 {} 1]
	set name [dict get $g name]
	while {[string length $name] > 1 && [ui::measure i12s $name] > 238 - 58 - $tw - 8} { set name "[string range $name 0 end-2]…" }
	ui::text 58 [expr {620 + $dy}] $name i12s $ui::c(fg)
	ui::box 30 [expr {647 + $dy}] 208 1 -fill $ui::c(border)
	set num [expr {$ok ? [dict get $fr fps] : "–"}]
	set nw [ui::text 30 [expr {651 + $dy}] $num sg36 [expr {$ok ? $ui::c(fg) : $ui::c(muted)}] w 0 {} 1]
	ui::text [expr {30 + $nw + 8}] [expr {673 + $dy}] FPS i12s $ui::c(muted)
	if {$ok} {
		ui::text 238 [expr {658 + $dy}] "[dict get $fr ft] ms" i12s $ui::c(fg) e 0 {} 1
		ui::text 238 [expr {675 + $dy}] "1% low [dict get $fr low]" i12 $ui::c(muted) e 0 {} 1
		set pts {}; set i 0
		foreach v [dict get $fr series] { lappend pts [expr {30 + $i * 208 / 59.0}] [expr {734 + $dy - $v * 0.34}]; incr i }
		if {[llength $pts] >= 4} {
			$ui::cv create polygon 30 [expr {734 + $dy}] {*}$pts [lindex $pts end-1] [expr {734 + $dy}] -fill [ui::col [ui::mix $ui::c(fg) $c 0.08]] -outline "" -tags page
			$ui::cv create line {*}$pts -fill [ui::col $ui::c(fg)] -width 1.3 -joinstyle round -tags page
		}
	} else {
		ui::text 238 [expr {658 + $dy}] "– ms" i12s $ui::c(muted) e
		ui::text 238 [expr {675 + $dy}] "No frame data" i12 $ui::c(muted) e
		for {set x 30} {$x < 238} {incr x 6} { ui::box $x [expr {733 + $dy}] 3 1 -fill $ui::c(border) }
	}
	ui::hit 16 [expr {606 + $dy}] 236 138 [list monitor::hud_compact]
}
