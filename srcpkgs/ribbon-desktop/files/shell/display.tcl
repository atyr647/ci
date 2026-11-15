# display.tcl - the main display: the output the bars, the dock and Alt+Tab go on (U11, Settings → Display).
#
#   display::rect      {x y w h}: the main output's rectangle in X (XWayland root) coordinates
#   display::main      the main output's name ("" when the outputs are not known)
#   display::outputs   the enabled outputs: {name x y w h scale} each, in X coordinates
#   display::read      read the outputs and display.conf again; 1 when the main rectangle changed
#
# Sources: ~/.config/ribbon/display.conf ("main NAME", written by apps/settings/display.tcl when a layout is
# kept) names the main output; the outputs and their places come from the compositor (`wlr-randr --json`, or
# its plain listing on wlr-randr before 0.4). A main output that is not connected, or no display.conf, gives
# the first enabled output: the same rule as Settings' main_default.
#
# XWayland's root is the output layout at scale 1 (labwc scales X windows itself), so an output's X rectangle
# is its logical one: its layout position as it is (left of or above 0,0 too: X windows there are drawn on it),
# and its mode divided by its scale as wlroots cuts it (turned for 90/270 transforms). The root runs from 0,0
# to the outputs' furthest right and bottom edges. An output
# list that does not span exactly the X screen is not this session's (another compositor, or plain Xvfb) and is
# not used until one does; the whole X screen is then the main display. RIBBON_SCREEN=WxH (the scene tests)
# is the whole screen at that size.
#
# The rectangle follows changes: `ribbon-shell-ctl display` reads again at once, display.conf is looked at
# every 2 s, and the outputs every 10 s (a monitor plugged in or out), without blocking.

namespace eval display {
	variable outs {}        ;# {name x y w h scale} of each enabled output, X coordinates
	variable main ""        ;# the main output's name
	variable rect {}        ;# the main output's {x y w h}
	variable trusted 0      ;# an output list has spanned the X screen once
	variable stamp ""       ;# display.conf's main name when last read
	variable polling 0
	variable pending ""     ;# the channel of a wlr-randr run in flight
	variable listeners {}   ;# scripts run when the rectangle changes
}

proc display::confpath {} {
	set cfg [expr {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""
		? $::env(XDG_CONFIG_HOME) : [file join [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}] .config]}]
	file join $cfg ribbon display.conf
}

# The name on display.conf's "main NAME" line, or "".
proc display::conf_main {} {
	set m ""
	if {![catch {::open [confpath]} fh]} {
		foreach line [split [::read $fh] \n] { regexp {^main (\S+)} $line -> m }
		::close $fh
	}
	return $m
}

# ---- reading wlr-randr --------------------------------------------------------------------

# Minimal JSON reader (as apps/settings/display.tcl's): objects become dicts, arrays lists, strings their
# text, numbers and true/false the literal text, null "".
proc display::json {text} { set p 0; jvalue $text p }
proc display::jskip {t pv} {
	upvar $pv p
	while {$p < [string length $t] && [string is space [string index $t $p]]} { incr p }
}
proc display::jvalue {t pv} {
	upvar $pv p
	jskip $t p
	switch -- [string index $t $p] {
		\{ {
			incr p; set d {}; jskip $t p
			if {[string index $t $p] eq "\}"} { incr p; return $d }
			while 1 {
				jskip $t p; set k [jvalue $t p]; jskip $t p
				incr p
				lappend d $k [jvalue $t p]
				jskip $t p
				set c [string index $t $p]; incr p
				if {$c ne ","} break
			}
			return $d
		}
		\[ {
			incr p; set l {}; jskip $t p
			if {[string index $t $p] eq "\]"} { incr p; return $l }
			while 1 {
				lappend l [jvalue $t p]
				jskip $t p
				set c [string index $t $p]; incr p
				if {$c ne ","} break
			}
			return $l
		}
		\" {
			incr p; set s ""
			while {$p < [string length $t] && [set ch [string index $t $p]] ne "\""} {
				if {$ch eq "\\"} {
					incr p
					set e [string index $t $p]
					switch -- $e {
						n { append s \n }
						t { append s \t }
						u { append s [::format %c 0x[string range $t [expr {$p + 1}] [expr {$p + 4}]]]; incr p 4 }
						default { append s $e }
					}
				} else { append s $ch }
				incr p
			}
			incr p
			return $s
		}
		default {
			set s $p
			while {$p < [string length $t] && ![string is space [string index $t $p]] && [string index $t $p] ni {, \] \}}} { incr p }
			set lit [string range $t $s [expr {$p - 1}]]
			if {$lit eq "null"} { return "" }
			return $lit
		}
	}
}
proc display::g {d key {def ""}} { expr {[dict exists $d $key] ? [dict get $d $key] : $def} }

# An output's logical size: the mode divided by the scale, turned for a 90 or 270 degree transform. wlroots
# (wlr_output_effective_resolution) divides in single precision and cuts to whole pixels: 2560 at 1.5 is 1706.
proc display::f32 {v} { binary scan [binary format f $v] f r; return $r }
proc display::logical {w h scale transform} {
	if {![string is double -strict $scale] || $scale <= 0} { set scale 1 }
	set fs [f32 $scale]
	set lw [expr {int([f32 [expr {$w / $fs}]])}]
	set lh [expr {int([f32 [expr {$h / $fs}]])}]
	if {[regexp {(^|-)(90|270)$} $transform]} { return [list $lh $lw] }
	list $lw $lh
}

# wlr-randr --json: the enabled outputs, {name x y w h scale} each, in layout coordinates.
proc display::parse_json {text} {
	set out {}
	foreach o [json $text] {
		if {[g $o enabled] ne "true"} continue
		set mw 0; set mh 0
		foreach m [g $o modes] {
			if {[g $m current] eq "true"} { set mw [g $m width 0]; set mh [g $m height 0] }
		}
		if {!$mw || !$mh} continue
		set pos [g $o position]
		set scale [g $o scale 1]
		lassign [logical $mw $mh $scale [g $o transform normal]] w h
		lappend out [list [g $o name] [expr {int([g $pos x 0])}] [expr {int([g $pos y 0])}] $w $h $scale]
	}
	return $out
}

# Plain wlr-randr (before 0.4): NAME "description", then indented Enabled, Modes (the current one marked),
# Position, Transform and Scale lines.
proc display::parse_text {text} {
	set out {}
	set cur {}
	foreach line [concat [split $text \n] [list "END"]] {
		if {[regexp {^(\S+)} $line -> name]} {
			if {[dict exists $cur name] && [dict get $cur on] && [dict get $cur mw]} {
				lassign [logical [dict get $cur mw] [dict get $cur mh] [dict get $cur scale] [dict get $cur transform]] w h
				lappend out [list [dict get $cur name] [dict get $cur x] [dict get $cur y] $w $h [dict get $cur scale]]
			}
			set cur [dict create name $name on 1 mw 0 mh 0 x 0 y 0 scale 1 transform normal]
			continue
		}
		if {![dict exists $cur name]} continue
		if {[regexp {^\s+Enabled:\s+(\S+)} $line -> v]} { dict set cur on [expr {$v eq "yes"}] }
		if {[regexp {^\s+(\d+)x(\d+) px.*\(.*current.*\)} $line -> w h]} { dict set cur mw $w; dict set cur mh $h }
		if {[regexp {^\s+Position:\s+(-?\d+),(-?\d+)} $line -> x y]} { dict set cur x $x; dict set cur y $y }
		if {[regexp {^\s+Transform:\s+(\S+)} $line -> v]} { dict set cur transform $v }
		if {[regexp {^\s+Scale:\s+([0-9.]+)} $line -> v]} { dict set cur scale $v }
	}
	return $out
}

# wlr-randr's text: JSON when it starts with [, else the plain listing.
proc display::parse {text} {
	if {[string index [string trimleft $text] 0] eq "\["} { return [parse_json $text] }
	parse_text $text
}

# Layout coordinates to X ones: they are the same. XWayland's root starts at the layout's 0,0 whatever lies left
# of or above it, and labwc puts an X window at its X position in the layout (measured under labwc 0.7.1).
proc display::to_x {outs} { return $outs }

# The X screen's size: RIBBON_SCREEN, else Tk's.
proc display::screen {} {
	if {[info exists ::env(RIBBON_SCREEN)] && [regexp {^(\d+)x(\d+)$} $::env(RIBBON_SCREEN) -> w h]} { return [list $w $h] }
	list [winfo screenwidth .] [winfo screenheight .]
}

# 1 when OUTS span exactly an X screen of SW x SH.
proc display::spans {outs sw sh} {
	if {![llength $outs]} { return 0 }
	set x1 0; set y1 0
	foreach o $outs { lassign $o - x y w h; set x1 [expr {max($x1, $x + $w)}]; set y1 [expr {max($y1, $y + $h)}] }
	expr {abs($x1 - $sw) <= 1 && abs($y1 - $sh) <= 1}
}

# The main output of OUTS for the name M: that output when it is there, else the first.
proc display::pick {outs m} {
	foreach o $outs { if {[lindex $o 0] eq $m} { return $o } }
	lindex $outs 0
}

# Take the outputs from wlr-randr's TEXT (or none) and display.conf; 1 when the main rectangle changed.
proc display::take {text} {
	variable outs; variable main; variable rect; variable trusted; variable stamp
	set stamp [mtime]
	lassign [screen] sw sh
	set got [to_x [parse $text]]
	if {[info exists ::env(RIBBON_SCREEN)]} { set got {} }
	if {[llength $got] && ($trusted || [spans $got $sw $sh])} {
		set trusted 1
		set outs $got
		set o [pick $outs [conf_main]]
		set main [lindex $o 0]
		set new [lrange $o 1 4]
	} else {
		set outs {}
		set main ""
		set new [list 0 0 $sw $sh]
	}
	set changed [expr {$new ne $rect}]
	set rect $new
	return $changed
}

# What the watch compares: display.conf's main name (a few bytes, read every 2 s; a time could miss two
# writes in one second)
proc display::mtime {} { conf_main }

proc display::randr_argv {} {
	if {[info exists ::env(RIBBON_SCREEN)] || ![info exists ::env(WAYLAND_DISPLAY)] || [auto_execok wlr-randr] eq ""} { return {} }
	list wlr-randr
}

# Read now, waiting for wlr-randr (at start-up; it answers in milliseconds). 1 when the rectangle changed.
proc display::read {} {
	set text ""
	set argv [randr_argv]
	if {[llength $argv]} {
		if {[catch {exec {*}$argv --json 2>/dev/null} text]} {
			if {[catch {exec {*}$argv 2>/dev/null} text]} { set text "" }
		}
	}
	take $text
}

proc display::rect {} {
	variable rect
	if {![llength $rect]} { read }
	return $rect
}
proc display::main {} { rect; variable main; return $main }
proc display::outputs {} { rect; variable outs; return $outs }

# Run SCRIPT whenever the main rectangle changes.
proc display::on_change {script} {
	variable listeners
	if {$script ni $listeners} { lappend listeners $script }
}
proc display::changed {} {
	variable listeners
	foreach s $listeners { if {[catch {uplevel #0 $s} err]} { puts stderr "display: $s: $err" } }
}

# Read again without blocking; the listeners run when the rectangle changed.
proc display::refresh {} {
	variable pending
	set argv [randr_argv]
	if {![llength $argv]} { if {[take ""]} { changed }; return }
	if {$pending ne ""} return
	if {[catch {::open |[list sh -c {wlr-randr --json 2>/dev/null || wlr-randr 2>/dev/null}] r} ch]} { return }
	set pending $ch
	variable got_$ch ""
	fconfigure $ch -blocking 0
	fileevent $ch readable [list display::readable $ch]
}
proc display::readable {ch} {
	variable pending
	variable got_$ch
	append got_$ch [::read $ch]
	if {![eof $ch]} return
	catch {::close $ch}
	set text [set got_$ch]
	unset got_$ch
	set pending ""
	if {[take $text]} { changed }
}

# The watch: display.conf's time every 2 s, the outputs every 10 s.
proc display::poll {{n 0}} {
	variable stamp
	if {[mtime] ne $stamp || $n % 5 == 4} { refresh }
	after 2000 [list display::poll [expr {($n + 1) % 5}]]
}
proc display::start {} {
	variable polling
	if {$polling} return
	set polling 1
	after 2000 display::poll
	if {[llength [info commands ::shell::verb]]} { shell::verb display display::refresh }
}
