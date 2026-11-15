# display.tcl - Settings → Display (U11): the outputs (wlr-randr --json), the
# commands that apply a layout and the HDR state (ribbon hdr), the revert timer,
# the kanshi profile and the main display. No drawing here: page-display.tcl
# draws the page and calls these procs.
#
# Every command runs in the background: display::run opens a pipe and reads it
# from a fileevent, so the page never waits on a child process.
#
#   ~/.config/ribbon/display.conf   "main NAME": the main display (the bars go there)
#   ~/.config/kanshi/config         profiles named ribbon-NAMES, kept beside the user's own

namespace eval display {
	variable dir [file dirname [file normalize [info script]]]
	variable outs {}        ;# the outputs as read: a list of dicts (see display::parse)
	variable loaded 0       ;# 0 not read yet, 1 read, -1 the read failed
	variable want {}        ;# pending edits: dict NAME -> dict (on w h r scale transform adaptive)
	variable want_hdr {}    ;# pending HDR edits: dict (on nits), absent = as now
	variable main ""        ;# the main display: its name
	variable hdr_now {}     ;# HDR as read: dict (known on nits)
	variable bufs
	array set bufs {}
	variable revert_secs 15 ;# the Apply timer; RIBBON_DISPLAY_REVERT overrides (tests)
	variable secs 0
	variable snapshot {}    ;# the jobs that put back the state before the last Apply
	variable timer ""
	variable sheet 0        ;# the keep-or-revert sheet is open
	variable err ""
	variable nits_min 80
	variable nits_max 440
	if {[info exists ::env(RIBBON_DISPLAY_REVERT)]} { set revert_secs $::env(RIBBON_DISPLAY_REVERT) }
}

# ---- running commands ------------------------------------------------------------

# A done callback that does nothing.
proc display::ignore {code out} {}

# Run ARGV in the background; DONE gets the exit code and the output (stdout and stderr).
proc display::run {argv done} {
	variable bufs
	if {[catch {open |[list {*}$argv 2>@1] r} ch]} {
		after idle [list {*}$done 127 "[lindex $argv 0]: $ch"]
		return
	}
	fconfigure $ch -blocking 0 -encoding utf-8
	set bufs($ch) ""
	fileevent $ch readable [list display::readable $ch $done]
}

proc display::readable {ch done} {
	variable bufs
	append bufs($ch) [read $ch]
	if {![eof $ch]} return
	fileevent $ch readable {}
	fconfigure $ch -blocking 1
	set code 0
	if {[catch {close $ch} msg opts]} {
		set ec [dict get $opts -errorcode]
		set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : 1}]
	}
	set out $bufs($ch)
	unset bufs($ch)
	{*}$done $code $out
}

# Run JOBS (argv lists) one after another; DONE gets the first failing code (or 0) and its output.
proc display::chain {jobs done {out ""}} {
	if {![llength $jobs]} { {*}$done 0 $out; return }
	display::run [lindex $jobs 0] [list display::chain_next [lrange $jobs 1 end] $done]
}

proc display::chain_next {rest done code out} {
	if {$code != 0} { {*}$done $code $out; return }
	display::chain $rest $done $out
}

# ---- reading the outputs -----------------------------------------------------------

# Minimal JSON reader: objects become dicts, arrays lists, strings their text,
# numbers and true/false the literal text, null "". No dependency needed.
proc display::json {text} {
	set p 0
	display::jvalue $text p
}

proc display::jskip {t pv} {
	upvar $pv p
	while {$p < [string length $t] && [string is space [string index $t $p]]} { incr p }
}

proc display::jvalue {t pv} {
	upvar $pv p
	display::jskip $t p
	set c [string index $t $p]
	switch -- $c {
		\{ {
			incr p
			set d {}
			display::jskip $t p
			if {[string index $t $p] eq "\}"} { incr p; return $d }
			while 1 {
				display::jskip $t p
				set k [display::jvalue $t p]
				display::jskip $t p
				incr p                       ;# the colon
				lappend d $k [display::jvalue $t p]
				display::jskip $t p
				set c2 [string index $t $p]
				incr p
				if {$c2 eq "\}"} break
			}
			return $d
		}
		\[ {
			incr p
			set l {}
			display::jskip $t p
			if {[string index $t $p] eq "\]"} { incr p; return $l }
			while 1 {
				lappend l [display::jvalue $t p]
				display::jskip $t p
				set c2 [string index $t $p]
				incr p
				if {$c2 eq "\]"} break
			}
			return $l
		}
		\" {
			incr p
			set s ""
			while {[set ch [string index $t $p]] ne "\""} {
				if {$ch eq "\\"} {
					incr p
					set e [string index $t $p]
					switch -- $e {
						n { append s \n }
						t { append s \t }
						u { append s [format %c 0x[string range $t [expr {$p + 1}] [expr {$p + 4}]]]; incr p 4 }
						default { append s $e }
					}
				} else {
					append s $ch
				}
				incr p
			}
			incr p
			return $s
		}
		default {
			set s $p
			while {$p < [string length $t] && ![string is space [string index $t $p]] && [string index $t $p] ni {, \] \}}} { incr p }
			set lit [string range $t $s [expr {$p - 1}]]
			# the text as it came (expr would turn 1.000000 into 1.0)
			if {$lit eq "null"} { return "" }
			return $lit
		}
	}
}

# A dict's value, or DEF.
proc display::g {d key {def ""}} {
	if {[dict exists $d $key]} { return [dict get $d $key] }
	return $def
}

# wlr-randr's plain listing (0.3 and older have no --json), read into the shape the
# JSON has: one dict per output with name, make, model, enabled, modes (width,
# height, refresh, current), position (x, y), transform, scale and adaptive_sync.
#   NAME "description"            a line at the left: an output
#     Make: X / Model: X          (null) when the compositor gave none
#     Enabled: yes|no
#     Modes:
#       2560x1440 px, 164.998001 Hz (preferred, current)
#     Position: X,Y / Transform: T / Scale: S / Adaptive Sync: enabled|disabled
proc display::parse_text {text} {
	set out {}
	set o {}
	foreach line [split $text \n] {
		if {[regexp {^(\S+)(?:\s+"(.*)")?\s*$} $line -> name desc]} {
			if {[dict size $o]} { lappend out $o }
			set o [dict create name $name make "" model "" enabled false modes {} \
				position {x 0 y 0} transform normal scale 1.000000 adaptive_sync false]
			continue
		}
		if {![dict size $o]} continue
		set l [string trim $line]
		if {[regexp {^(Make|Model):\s*(.*)$} $l -> k v]} {
			if {$v eq "(null)"} { set v "" }
			dict set o [string tolower $k] $v
		} elseif {[regexp {^Enabled:\s*(\S+)} $l -> v]} {
			dict set o enabled [expr {$v eq "yes" ? "true" : "false"}]
		} elseif {[regexp {^(\d+)x(\d+) px(?:, ([0-9.]+) Hz)?(?: \((.*)\))?$} $l -> w h r flags]} {
			if {$w == 0 || $h == 0} continue
			# a mode the compositor gives no rate for (a headless or virtual output) is rate 0, as --json has it
			set m [dict create width $w height $h refresh [expr {$r eq "" ? 0 : $r}]]
			dict set m current [expr {"current" in [split [string map {" " ""} $flags] ,] ? "true" : "false"}]
			dict lappend o modes $m
		} elseif {[regexp {^Position:\s*(-?\d+),(-?\d+)} $l -> x y]} {
			dict set o position [dict create x $x y $y]
		} elseif {[regexp {^Transform:\s*(\S+)} $l -> v]} {
			dict set o transform $v
		} elseif {[regexp {^Scale:\s*([0-9.]+)} $l -> v]} {
			dict set o scale $v
		} elseif {[regexp {^Adaptive Sync:\s*(\S+)} $l -> v]} {
			dict set o adaptive_sync [expr {$v eq "enabled" ? "true" : "false"}]
		}
	}
	if {[dict size $o]} { lappend out $o }
	set out
}

# The outputs from wlr-randr --json (or, without it, its plain listing): one dict per
# output, with its current mode and the modes it offers. Refresh is kept as "%.3f" Hz,
# the form --mode takes.
proc display::parse {json} {
	set out {}
	if {[string index [string trimleft $json] 0] eq "\["} {
		set raw [display::json $json]
	} else {
		set raw [display::parse_text $json]
	}
	foreach o $raw {
		set modes {}
		set cur {w 0 h 0 r 60.000}
		foreach m [display::g $o modes] {
			set mode [dict create w [display::g $m width] h [display::g $m height] r [format %.3f [display::g $m refresh 60]]]
			lappend modes $mode
			if {[display::g $m current] eq "true"} { set cur $mode }
		}
		if {![llength $modes]} { set modes [list $cur] }
		if {[dict get $cur w] == 0 && [llength $modes]} { set cur [lindex $modes 0] }
		set pos [display::g $o position]
		set scale [display::g $o scale 1]
		lappend out [dict create name [display::g $o name] make [display::g $o make] model [display::g $o model] \
			on [expr {[display::g $o enabled] eq "true" ? 1 : 0}] \
			w [dict get $cur w] h [dict get $cur h] r [dict get $cur r] \
			x [display::g $pos x 0] y [display::g $pos y 0] scale $scale \
			transform [display::g $o transform normal] \
			adaptive [expr {[display::g $o adaptive_sync] eq "true" ? 1 : 0}] \
			modes $modes]
	}
	set out
}

# wlr-randr --json (0.4 and newer); a wlr-randr without it is read from its plain listing.
proc display::fetch {} {
	display::run {wlr-randr --json} display::read_done
}

proc display::read_done {code out {plain 0}} {
	variable outs
	variable loaded
	variable main
	if {$code != 0 && !$plain} {
		display::run {wlr-randr} {display::read_done_plain}
		return
	}
	if {$code == 0 && ![catch {display::parse $out} parsed] && [llength $parsed]} {
		set outs $parsed
		set loaded 1
		if {[display::out $main] eq {}} { set main [display::main_default] }
		display::run {ribbon hdr status} display::hdr_read_done
	} else {
		set outs {}
		set loaded -1
	}
	page::draw
}

proc display::read_done_plain {code out} { display::read_done $code $out 1 }

proc display::hdr_read_done {code out} {
	variable hdr_now
	if {$code == 0 && [regexp {HDR: (on|off)\s+SDR white: (\d+) nits} $out -> on nits]} {
		set hdr_now [dict create known 1 on [expr {$on eq "on" ? 1 : 0}] nits $nits]
	} else {
		set hdr_now [dict create known 0 on 0 nits 250]
	}
	page::draw
}

# The output dict with NAME, or {}.
proc display::out {name} {
	variable outs
	foreach o $outs { if {[dict get $o name] eq $name} { return $o } }
	return {}
}

# The main display from display.conf when it is still connected, else the first enabled output.
proc display::main_default {} {
	variable outs
	set m [display::main_conf]
	if {$m ne "" && [display::out $m] ne {}} { return $m }
	foreach o $outs { if {[dict get $o on]} { return [dict get $o name] } }
	if {[llength $outs]} { return [dict get [lindex $outs 0] name] }
	return ""
}

# ---- the pending edits -----------------------------------------------------------------

# A value for an output: its pending edit, else the value now.
proc display::val {name key} {
	variable want
	if {[dict exists $want $name $key]} { return [dict get $want $name $key] }
	return [dict get [display::out $name] $key]
}

proc display::set_val {name key v} {
	variable want
	dict set want $name $key $v
}

# The pending HDR edit or the value now (HDR on/off and the SDR white level).
proc display::hdr_val {key} {
	variable want_hdr
	variable hdr_now
	if {[dict exists $want_hdr $key]} { return [dict get $want_hdr $key] }
	return [display::g $hdr_now $key [expr {$key eq "nits" ? 250 : 0}]]
}

proc display::discard {} {
	variable want
	variable want_hdr
	set want {}
	set want_hdr {}
}

proc display::hz {r} {
	if {abs($r - round($r)) < 0.005} { return "[expr {round($r)}] Hz" }
	return [format {%.2f Hz} $r]
}

# Resolutions the output offers, largest first, as {WxH label} pairs.
proc display::res_items {name} {
	set seen {}
	set items {}
	foreach m [dict get [display::out $name] modes] {
		set k "[dict get $m w]x[dict get $m h]"
		if {$k in $seen} continue
		lappend seen $k
		lappend items [list $k "[dict get $m w] × [dict get $m h]" [expr {[dict get $m w] * [dict get $m h]}]]
	}
	set items [lsort -integer -decreasing -index 2 $items]
	lmap i $items { lrange $i 0 1 }
}

# Refresh rates the output offers at W x H, fastest first, as {rate label} pairs.
proc display::rate_items {name w h} {
	set items {}
	foreach m [dict get [display::out $name] modes] {
		if {[dict get $m w] != $w || [dict get $m h] != $h} continue
		set r [dict get $m r]
		if {[lsearch -exact -index 0 $items $r] < 0} { lappend items [list $r [display::hz $r]] }
	}
	lsort -real -decreasing -index 0 $items
}

# The scale in percent, for the segmented control, and back.
proc display::scale_pct {s} { expr {round($s * 100)} }

# A layout from the outputs and the pending edits: the wlr-randr command. CFG is a
# list of dicts (name on w h r x y scale transform adaptive).
proc display::layout_argv {cfg} {
	set a [list wlr-randr]
	foreach c $cfg {
		lappend a --output [dict get $c name]
		if {![dict get $c on]} { lappend a --off; continue }
		# a mode with no rate (0: a virtual output) is named by its size alone
		set rate [expr {[dict get $c r] > 0 ? "@[dict get $c r]Hz" : ""}]
		lappend a --on --mode "[dict get $c w]x[dict get $c h]$rate" \
			--pos "[dict get $c x],[dict get $c y]" --scale [dict get $c scale] \
			--transform [dict get $c transform]
		# adaptive sync is passed only when it changes: wlr-randr fails the whole call on an output without it
		if {[dict get $c adaptive] ne ""} {
			lappend a --adaptive-sync [expr {[dict get $c adaptive] ? "enabled" : "disabled"}]
		}
	}
	set a
}

# The outputs as they are now, as CFG.
proc display::now_cfg {} {
	variable outs
	set cfg {}
	foreach o $outs {
		set n [dict get $o name]
		set c [dict remove $o modes]
		# the state to put back: adaptive sync only where the pending edit changes it
		if {[display::val $n adaptive] == [dict get $o adaptive]} { dict set c adaptive "" }
		lappend cfg $c
	}
	set cfg
}

# The outputs with the pending edits applied, as CFG.
proc display::want_cfg {} {
	variable outs
	set cfg {}
	foreach o $outs {
		set n [dict get $o name]
		set c [dict remove $o modes]
		foreach k {on w h r scale transform} { dict set c $k [display::val $n $k] }
		# adaptive sync is set only where it changes (see layout_argv)
		set a [display::val $n adaptive]
		dict set c adaptive [expr {$a == [dict get $o adaptive] ? "" : $a}]
		lappend cfg $c
	}
	set cfg
}

# The HDR commands for the given on and nits (HDR toggled first, then the SDR white).
proc display::hdr_jobs {on nits} {
	list [list ribbon hdr [expr {$on ? "on" : "off"}]] [list ribbon hdr sdr-white $nits]
}

# ---- apply, keep and revert ---------------------------------------------------------

# Apply the pending edits; a timer then puts back the state before them unless Keep.
proc display::apply {} {
	variable hdr_now
	variable err
	set err ""
	set back [list [display::layout_argv [display::now_cfg]]]
	if {[display::g $hdr_now known 0]} {
		lappend back {*}[display::hdr_jobs [display::g $hdr_now on] [display::g $hdr_now nits]]
	}
	set jobs [list [display::layout_argv [display::want_cfg]]]
	if {[display::g $hdr_now known 0]} {
		lappend jobs {*}[display::hdr_jobs [display::hdr_val on] [display::hdr_val nits]]
	}
	display::chain $jobs [list display::applied $back]
}

proc display::applied {back code out} {
	variable err
	variable snapshot
	variable sheet
	variable secs
	variable revert_secs
	variable timer
	if {$code != 0} {
		set err [string trim [lindex [split $out \n] 0]]
		if {$err eq ""} { set err "The displays did not change." }
		page::draw
		return
	}
	set snapshot $back
	set sheet 1
	set secs $revert_secs
	set timer [after 1000 display::tick]
	display::discard
	display::fetch
}

proc display::tick {} {
	variable secs
	variable timer
	incr secs -1
	if {$secs <= 0} { set timer ""; display::revert; return }
	set timer [after 1000 display::tick]
	page::draw
}

proc display::keep {} {
	variable timer
	variable sheet
	variable snapshot
	if {$timer ne ""} { after cancel $timer; set timer "" }
	set sheet 0
	set snapshot {}
	display::save_main
	display::save_profile
	display::tell_shell
	page::draw
}

# The shell reads display.conf and the outputs again at once (its watch would in 2 s): the bars, the dock and the
# window margin go to the main display now. A shell that is not running is fine.
proc display::tell_shell {} {
	display::run {ribbon-shell-ctl display} display::ignore
}

# Put back the state before the last Apply (the sheet's Revert, Escape, or the timer).
proc display::revert {} {
	variable snapshot
	variable timer
	variable sheet
	if {$timer ne ""} { after cancel $timer; set timer "" }
	set sheet 0
	if {[llength $snapshot]} {
		display::chain [display::snapshot_jobs] [list display::reverted]
	} else {
		page::draw
	}
}

proc display::snapshot_jobs {} {
	variable snapshot
	set snapshot
}

proc display::reverted {code out} {
	variable err
	variable snapshot
	set snapshot {}
	if {$code != 0} { set err "Could not put the displays back: [string trim [lindex [split $out \n] 0]]" }
	display::fetch
}

# ---- main display, kanshi profile -------------------------------------------------------

proc display::confdir {} {
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} { return $::env(XDG_CONFIG_HOME) }
	return [file join [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}] .config]
}

proc display::main_conf {} {
	set f [file join [display::confdir] ribbon display.conf]
	if {![file readable $f]} { return "" }
	set fh [open $f]
	set s [read $fh]
	close $fh
	if {[regexp {(?m)^main (\S+)} $s -> m]} { return $m }
	return ""
}

proc display::save_main {} {
	variable main
	set d [file join [display::confdir] ribbon]
	catch {
		file mkdir $d
		set fh [open [file join $d display.conf] w]
		puts $fh "main $main"
		close $fh
	}
}

# The kanshi profile for the layout kept: its block replaces the older ribbon-* blocks,
# and anything else in the user's config is kept as it is.
proc display::profile_block {} {
	variable outs
	variable main
	set names {}
	set lines {}
	foreach o $outs {
		set n [dict get $o name]
		if {![display::val $n on]} {
			lappend lines "\toutput $n disable"
			continue
		}
		lappend names $n
		lappend lines "\toutput $n enable mode [display::val $n w]x[display::val $n h]@[display::val $n r]Hz \
			position [display::val $n x],[display::val $n y] scale [display::val $n scale] \
			transform [display::val $n transform] adaptive_sync [expr {[display::val $n adaptive] ? "on" : "off"}]"
	}
	set pname "ribbon-[join $names _]"
	# when kanshi puts this layout on (a monitor plugged in), the shell moves to its main display
	lappend lines "\texec ribbon-shell-ctl display"
	list $pname "profile $pname \{\n[join $lines \n]\n\}\n"
}

proc display::save_profile {} {
	set f [file join [display::confdir] kanshi config]
	lassign [display::profile_block] pname block
	set kept {}
	set skip 0
	if {[file readable $f]} {
		set fh [open $f]
		foreach line [split [read $fh] \n] {
			if {[regexp {^profile ribbon-} $line]} { set skip 1; continue }
			if {$skip} { if {$line eq "\}"} { set skip 0 }; continue }
			lappend kept $line
		}
		close $fh
	}
	catch {
		file mkdir [file dirname $f]
		set fh [open $f w]
		puts -nonewline $fh [string trimright [join $kept \n] \n]
		if {[llength $kept]} { puts $fh "" }
		puts -nonewline $fh $block
		close $fh
	}
	# kanshi reads its config at start; reload it when it runs (missing kanshictl is fine)
	catch {display::run {kanshictl reload} display::ignore}
}

# ---- identify -----------------------------------------------------------------------

# Draw each enabled output's number on it for a few seconds (identify.tcl).
proc display::identify {} {
	variable dir
	variable outs
	set args {}
	set n 0
	foreach o $outs {
		set name [dict get $o name]
		if {![display::val $name on]} continue
		incr n
		set s [display::val $name scale]
		set w [expr {[display::val $name w] / $s}]
		set h [expr {[display::val $name h] / $s}]
		if {[display::val $name transform] in {90 270}} { lassign [list $h $w] w h }
		lappend args [expr {round([display::val $name x])}] [expr {round([display::val $name y])}] [expr {round($w)}] [expr {round($h)}] $n
	}
	if {[llength $args]} {
		display::run [list [info nameofexecutable] -encoding utf-8 [file join $dir identify.tcl] {*}$args] display::ignore
	}
}

# ---- the subtitle: the state of the page ------------------------------------------------

proc display::subtitle {} {
	variable outs
	variable loaded
	variable err
	if {$err ne ""} { return $err }
	if {$loaded == 0} { return "Reading the displays" }
	if {$loaded < 0} { return "Could not read the displays" }
	set n [llength $outs]
	if {$n == 1} { return "1 display" }
	set ys {}
	set xs {}
	foreach o $outs { lappend ys [dict get $o y]; lappend xs [dict get $o x] }
	if {[llength [lsort -unique $ys]] == 1} { return "$n displays · arranged side by side" }
	if {[llength [lsort -unique $xs]] == 1} { return "$n displays · stacked" }
	return "$n displays"
}

# The states the scene file (tests/settings-display-scene.tcl) draws; never called by the app.
proc display::scene {which} {
	variable sel
	variable main
	variable sheet
	variable outs
	if {$outs eq {}} { after 100 [list display::scene $which]; return }
	switch -- $which {
		board {
			set sel DP-1
			set main DP-1
			display::set_val DP-1 scale 1.25
		}
		popup {
			set sel DP-1
			set main DP-1
			display::open_pop res
		}
		sheet {
			set sel DP-1
			set main DP-1
			display::set_val DP-1 scale 1.25
			display::apply
		}
		single {
			set sel eDP-1
			set main eDP-1
			set outs [lrange $outs 1 1]
		}
	}
	page::draw
}
