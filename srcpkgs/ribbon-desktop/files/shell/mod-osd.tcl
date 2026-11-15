# mod-osd.tcl - the volume and brightness OSD (boards OSD-1-Volume, OSD-2-Muted, OSD-3-Brightness;
# design/tools/gen_lock_osd.py). A shell module (C2).
#
# The keys run ribbon-osd (xdg/labwc/rc.xml), which asks the shell: ribbon-shell-ctl osd volume +5 | -5 | mute,
# osd brightness +5 | -5. The shell changes the level (wpctl, brightnessctl), reads it back and shows it in a pill
# centred over the dock (its foot 62 above the main display's), 300 x 44, for 1.5 s after the last key. The pill
# takes no clicks and no keyboard.
#   volume      the default output; a key turns it up to 100 %, or 150 % with Settings → Sound's "Louder than
#               100%" (sound.conf OVER=yes), the track spanning that much; a key up unmutes; mute toggles
#   brightness  the backlight brightnessctl finds, in steps of the screen's maximum, never under 1 % (as the quick
#               panel's slider)
# One change runs at a time: keys pressed meanwhile are added up and done next, so key repeat never queues a
# process per press and the pill never shows an older level after a newer one.

namespace eval osd {
	variable W 300
	variable H 44
	variable hold 1500       ;# ms the pill stays after the last key
	variable queue {}        ;# {kind arg ...} waiting: {volume 10} {volume mute} {brightness -5}
	variable busy 0
	variable shown {}        ;# what the pill shows: {kind pct muted max}
	variable log {}          ;# the last levels shown (tests)
}

# ribbon-shell-ctl osd KIND ARG
proc osd::verb {kind {arg ""}} {
	variable queue
	if {$kind ni {volume brightness}} return
	if {$arg eq "mute" && $kind eq "volume"} {
		lappend queue [list volume mute]
	} elseif {[regexp {^([+-])(\d{1,3})$} $arg -> sign n]} {
		set d [expr {$sign eq "-" ? -$n : $n}]
		# a step after a step of the same kind is added to it
		set last [lindex $queue end]
		if {[lindex $last 0] eq $kind && [string is integer -strict [lindex $last 1]]} {
			lset queue end 1 [expr {max(-100, min(100, [lindex $last 1] + $d))}]
		} else {
			lappend queue [list $kind $d]
		}
	} else return
	run_next
}

proc osd::run_next {} {
	variable queue
	variable busy
	if {$busy || ![llength $queue]} return
	set queue [lassign $queue job]
	set busy 1
	lassign $job kind arg
	if {[catch {osd::$kind $arg} err]} { set busy 0; puts stderr "osd: $err"; after idle osd::run_next }
}

proc osd::done {} {
	variable busy 0
	after idle osd::run_next
}

# Commands in a row (status::run: a pipe the event loop reads), each after the last ends; then THEN with the
# last one's output.
proc osd::chain {cmds then} {
	if {[llength $cmds] == 1} { status::run [lindex $cmds 0] [list osd::chained $then]; return }
	status::run [lindex $cmds 0] [list osd::chain_next [lrange $cmds 1 end] $then]
}
proc osd::chain_next {cmds then ok out} { chain $cmds $then }
proc osd::chained {then ok out} { {*}$then $ok $out }

# ---- volume -----------------------------------------------------------------------

proc osd::volume_max {} { expr {[bar::conf sound OVER no] eq "yes" ? 150 : 100} }

proc osd::volume {arg} {
	set sink @DEFAULT_AUDIO_SINK@
	set max [volume_max]
	if {$arg eq "mute"} {
		set cmds [list [list wpctl set-mute $sink toggle]]
	} elseif {$arg > 0} {
		status::run [list wpctl get-volume $sink] [list osd::volume_up $arg $max]
		return
	} elseif {$arg < 0} {
		set cmds [list [list wpctl set-volume $sink [expr {-$arg}]%-]]
	} else {
		set cmds {}
	}
	lappend cmds [list wpctl get-volume $sink]
	chain $cmds [list osd::volume_got $max]
}

# A key up: wpctl's limit brings a level over it down to it, so a level already over it (set by another app, or
# before "Louder than 100%" was turned off) is the limit instead, and a key up never turns the volume down.
proc osd::volume_up {arg max ok out} {
	set sink @DEFAULT_AUDIO_SINK@
	set lim [::format %.2f [expr {$max / 100.0}]]
	if {$ok && [regexp {Volume:\s+([\d.]+)} $out -> v] && $v > $lim} { set lim $v }
	chain [list [list wpctl set-mute $sink 0] [list wpctl set-volume -l $lim $sink $arg%+] [list wpctl get-volume $sink]] \
		[list osd::volume_got $max]
}

proc osd::volume_got {max ok out} {
	if {$ok && [regexp {Volume:\s+([\d.]+)} $out -> v]} {
		show volume [expr {round($v * 100)}] [string match *MUTED* $out] $max
		# the bar's speaker follows at once (pactl subscribe tells it as well, later)
		set m [string match *MUTED* $out]
		if {$v ne $::status::volume || $m != $::status::muted} { set ::status::volume $v; set ::status::muted $m; status::changed }
	}
	done
}

# ---- brightness ---------------------------------------------------------------------

proc osd::brightness {arg} {
	status::run {brightnessctl -m} [list osd::brightness_set $arg]
}

proc osd::bright_pct {out} {
	if {[regexp -line {^[^,]*,backlight,\d+,(\d+)%} $out -> pct]} { return $pct }
	return ""
}

proc osd::brightness_set {arg ok out} {
	set cur [bright_pct $out]
	if {!$ok || $cur eq ""} { done; return }
	set new [expr {max(1, min(100, $cur + $arg))}]
	status::run [list brightnessctl -m set $new%] osd::brightness_got
}

proc osd::brightness_got {ok out} {
	set pct [bright_pct $out]
	if {$ok && $pct ne ""} {
		show brightness $pct 0 100
		# the quick panel's slider, when it is open on it
		catch {if {$::panel::data(bright) ne ""} { set ::panel::data(bright) $pct; panel::draw }}
	}
	done
}

# ---- the pill -------------------------------------------------------------------------

proc osd::show {kind pct muted max} {
	variable shown [list $kind $pct $muted $max]
	variable log
	variable hold
	lappend log $shown
	set log [lrange $log end-19 end]
	draw
	after cancel osd::hide
	after $hold osd::hide
}

proc osd::hide {} {
	after cancel osd::hide
	if {[winfo exists .osd]} { rbn::hide .osd }
}

# Where the pill is on the screen: centred on the main display, 62 above its foot (16 over the dock).
proc osd::place {} {
	variable W
	variable H
	list [expr {$bar::X0 + ($bar::W - $W) / 2}] [expr {$bar::Y0 + $bar::H - 62 - $H}]
}

proc osd::draw {} {
	variable W
	variable H
	variable shown
	lassign $shown kind pct muted max
	if {$kind eq ""} return
	array set c [array get theme::c]
	if {![winfo exists .osd]} { rbn::surface .osd -fill $c(BAR) }
	set d .osd.c
	$d delete all
	$d configure -background $c(BAR)
	set icon [expr {$kind eq "brightness" ? "sun" : ($muted ? "volume-x" : "volume")}]
	bar::icon $d $icon 16 1.9 [expr {$muted ? $c(MUTED) : $c(FG)}] 16 14
	# the track (§field), filled to the level (§accent; §muted while muted)
	set x0 46; set x1 230
	rbn::box $d $x0 20 [expr {$x1 - $x0}] 4 -fill $c(FIELD) -radius 2 -on $c(BAR)
	set fw [expr {round(($x1 - $x0) * max(0, min($pct, $max)) / double($max))}]
	if {$fw >= 4} { rbn::box $d $x0 20 $fw 4 -fill [expr {$muted ? $c(MUTED) : $c(ACCENT)}] -radius 2 -on "" }
	if {$muted} {
		text::draw $d [expr {$W - 16}] 22 f13m $c(MUTED) Muted e
	} else {
		text::draw $d [expr {$W - 16}] 22 f13s $c(FG) "$pct%" e -tnum 1
	}
	lassign [place] x y
	rbn::popup .osd $x $y $W $H [theme::look bar] -raise 1
}

after idle {catch {shell::verb osd osd::verb}}
