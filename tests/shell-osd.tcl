# shell-osd.tcl - RIBBON_SHELL_TEST hook for the volume and brightness OSD (shell/mod-osd.tcl; tests/steps.d/47-osd.sh),
# in the real shell under xvfb. wpctl and brightnessctl are stand-ins on PATH that keep their level in files and log
# their calls (OSD_STUBS). The keys' own command is run: ribbon-osd, through ribbon-shell-ctl and the shell's FIFO.
# Checked: each key changes the level the way it should (a key up unmutes; up to 100 %, or 150 % with "Louder than
# 100%"; brightness never under 1 %) and the pill shows the level read back, at its place over the dock; the pill
# against boards OSD-1, OSD-2 and OSD-3 (grabs written to OSD_SHOTS, compared by the step); held keys are added up
# into one change; the pill goes 1.5 s after the last key. A 60 s limit ends the run if anything waits.
set failed 0
interp bgerror {} {apply {{msg opts} { puts "  FAIL background error: [dict get $opts -errorinfo]"; exit 1 }}}
after 60000 {puts "  FAIL the OSD checks took more than 60 s"; exit 1}
proc ok {what} { puts "  ok   $what" }
proc bad {what why} { global failed; incr failed; puts "  FAIL $what: $why" }
proc check {what cond why} { if {$cond} { ok $what } else { bad $what $why } }
proc wait {cond {ms 4000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 [list expr $cond]]} {
		if {[clock milliseconds] > $end} { return 0 }
		after 20 {set ::tick 1}; vwait ::tick
	}
	return 1
}
proc spit {f t} { file mkdir [file dirname $f]; set fh [open $f w]; puts -nonewline $fh $t; close $fh }
proc slurp {f} { if {[catch {open $f} fh]} { return "" }; set t [read $fh]; close $fh; return $t }

array set wm::ws {1 {name 1 active 1}}
set wm::wsorder {1}
set S $::env(OSD_STUBS)
set SHOTS $::env(OSD_SHOTS)
set BIN $::env(OSD_BIN)
proc calls {} { split [string trim [slurp $::S/calls]] \n }
proc clear_calls {} { spit $::S/calls "" }
proc key {args} { exec sh $::BIN/ribbon-osd {*}$args 2>@1 }
proc shown {} { set osd::shown }
proc mapped {} { expr {[winfo exists .osd] && [winfo ismapped .osd]} }
proc grab {name} {
	update
	after 150 {set ::tick 1}; vwait ::tick
	exec import -window root -crop 300x44+570+794 +repage $::SHOTS/$name.png
}

after 300 run
proc run {} {
	global S
	# ---- volume up: unmuted first, turned up to at most 100 %, read back and shown (board OSD-1-Volume) ----
	spit $S/vol 0.59; spit $S/mute 1
	clear_calls
	key volume +5
	check "a volume key goes through ribbon-shell-ctl to the shell" [wait {[shown] eq {volume 64 0 100}}] "shown {[shown]}"
	check "it unmutes, turns up within 100 % and reads the level back" \
		[expr {[calls] eq [list {get-volume @DEFAULT_AUDIO_SINK@} {set-mute @DEFAULT_AUDIO_SINK@ 0} {set-volume -l 1.00 @DEFAULT_AUDIO_SINK@ 5%+} {get-volume @DEFAULT_AUDIO_SINK@}]}] "calls {[calls]}"
	check "the pill is shown" [mapped] "not mapped"
	update
	set g [list [winfo rootx .osd.c] [winfo rooty .osd.c] [winfo width .osd.c] [winfo height .osd.c]]
	check "the pill is 300 x 44 at 570,794: centred, 16 over the dock" [expr {$g eq {570 794 300 44}}] "at $g"
	check "the bar's speaker follows" [expr {$status::volume eq "0.64" && !$status::muted}] "volume $status::volume muted $status::muted"
	grab volume
	# ---- mute (board OSD-2-Muted) ----
	clear_calls
	key volume mute
	check "Mute toggles and shows Muted" [wait {[shown] eq {volume 64 1 100}}] "shown {[shown]}"
	check "Mute is one set-mute toggle" [expr {[lindex [calls] 0] eq {set-mute @DEFAULT_AUDIO_SINK@ toggle}}] "calls {[calls]}"
	grab muted
	# ---- brightness (board OSD-3-Brightness) ----
	spit $S/bright 75
	clear_calls
	key brightness +5
	check "a brightness key shows the backlight's new level" [wait {[shown] eq {brightness 80 0 100}}] "shown {[shown]}"
	check "it is set as a percentage (brightnessctl -m set 80%)" [expr {[lindex [calls] end] eq {brightnessctl -m set 80%}}] "calls {[calls]}"
	grab brightness
	spit $S/bright 3
	key brightness -5
	check "brightness never goes under 1 %" [wait {[shown] eq {brightness 1 0 100}}] "shown {[shown]}"
	# ---- limits ----
	spit $S/vol 0.98; spit $S/mute 0
	key volume +5
	check "without Louder than 100% a key stops at 100 %" [wait {[shown] eq {volume 100 0 100}}] "shown {[shown]}"
	# a level already over the limit (set by another app, or before "Louder than 100%" was turned off): a key up
	# leaves it, never turns it down to the limit
	spit $S/vol 1.20
	key volume +5
	check "a key up leaves a level already over 100 % where it is" [wait {[shown] eq {volume 120 0 100}}] "shown {[shown]}, vol [slurp $S/vol]"
	spit $S/vol 1.00
	spit $::env(XDG_CONFIG_HOME)/ribbon/sound.conf "OVER=yes\n"
	clear_calls
	key volume +5
	check "with Louder than 100% it goes on to 150 %, the track spanning it" [wait {[shown] eq {volume 105 0 150}}] "shown {[shown]}"
	check "and wpctl is given the 1.50 limit" [expr {[lsearch -exact [calls] {set-volume -l 1.50 @DEFAULT_AUDIO_SINK@ 5%+}] >= 0}] "calls {[calls]}"
	file delete $::env(XDG_CONFIG_HOME)/ribbon/sound.conf
	# ---- a held key: added up, one change at a time, the last level shown ----
	spit $S/vol 0.30
	wait {!$osd::busy}
	clear_calls
	for {set i 0} {$i < 8} {incr i} { osd::verb volume -5 }
	check "eight presses while one runs end at the sum (30 % - 40 % = 0 %)" [wait {[shown] eq {volume 0 0 100} && !$osd::busy}] "shown {[shown]}"
	set n [llength [lsearch -all [calls] set-volume*]]
	check "and are added up into fewer changes ($n of 8)" [expr {$n >= 1 && $n < 8}] "calls {[calls]}"
	set lv [lmap e [lrange $osd::log end-[expr {$n - 1}] end] {lindex $e 1}]
	check "the pill never shows an older level after a newer one ($lv)" [expr {$lv eq [lsort -integer -decreasing $lv]}] "levels $lv"
	# ---- it goes ----
	check "the pill goes 1.5 s after the last key" [expr {[mapped] && [wait {![mapped]} 3000]}] "still shown"
	# a word the verb does not know changes nothing
	clear_calls
	osd::verb volume up; osd::verb speakers +5
	after 300 {set ::tick 1}; vwait ::tick
	check "a malformed request runs nothing" [expr {[calls] eq {}}] "calls {[calls]}"
	if {$::failed} { puts "osd: $::failed failed"; exit 1 }
	puts "osd: all checks passed"
	exit 0
}
