# shell-display.tcl - shell/display.tcl's reader, in tclsh (tests/steps.d/46-shell-display.sh): wlr-randr's JSON
# and plain listings, scaled and turned outputs, the main output from display.conf (and the first one when it
# names none, or one not connected), layouts left of or above 0,0, and an output list that is not this X screen's.

set failed 0
proc ok {what} { puts "  ok   $what" }
proc bad {what why} { global failed; incr failed; puts "  FAIL $what: $why" }
proc check {what cond why} { if {$cond} { ok $what } else { bad $what $why } }

set root [file dirname [file dirname [file normalize [info script]]]]
set tmp [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] shell-display-[pid]]
file mkdir [file join $tmp ribbon]
set ::env(XDG_CONFIG_HOME) $tmp
unset -nocomplain ::env(RIBBON_SCREEN)
source -encoding utf-8 [file join $root srcpkgs/ribbon-desktop/files/shell/display.tcl]
# the X screen, as Tk would say it
set ::screen {2400 900}
proc display::screen {} { set ::screen }
proc conf {text} { set f [open [display::confpath] w]; puts -nonewline $f $text; close $f }

# wlr-randr --json (0.4): a 1920x1080 laptop panel at 1.25 at 0,0 and a 1440x900 monitor right of it
set json {[
  {"name": "eDP-1", "description": "Panel", "make": "BOE", "model": "0x0", "serial": null, "physical_size": {"width": 300, "height": 190},
   "enabled": true, "modes": [{"width": 1920, "height": 1080, "refresh": 60.000999, "preferred": true, "current": true},
   {"width": 1280, "height": 720, "refresh": 60.0, "preferred": false, "current": false}],
   "position": {"x": 0, "y": 0}, "transform": "normal", "scale": 1.250000, "adaptive_sync": false},
  {"name": "DP-2", "description": "Monitor \"24\"", "make": "Dell", "model": "U2412", "serial": "X", "physical_size": {"width": 520, "height": 320},
   "enabled": true, "modes": [{"width": 1440, "height": 900, "refresh": 59.887001, "preferred": true, "current": true}],
   "position": {"x": 1536, "y": 0}, "transform": "normal", "scale": 1.000000, "adaptive_sync": false},
  {"name": "HDMI-A-1", "description": "", "make": "", "model": "", "serial": null, "physical_size": {"width": 0, "height": 0},
   "enabled": false, "modes": [{"width": 1920, "height": 1080, "refresh": 60.0, "preferred": true, "current": false}],
   "position": {"x": 0, "y": 0}, "transform": "normal", "scale": 1.000000, "adaptive_sync": false}
]}
set outs [display::parse $json]
check "JSON: the enabled outputs only, in order" [expr {[lmap o $outs {lindex $o 0}] eq {eDP-1 DP-2}}] "$outs"
check "JSON: a 1920x1080 output at 1.25 is 1536x864 on the X screen" [expr {[lrange [lindex $outs 0] 1 4] eq {0 0 1536 864}}] "[lindex $outs 0]"
check "JSON: the second output keeps its place and size" [expr {[lrange [lindex $outs 1] 1 4] eq {1536 0 1440 900}}] "[lindex $outs 1]"
check "JSON: the scale is kept" [expr {[lindex $outs 0 5] == 1.25}] "[lindex $outs 0 5]"

# plain wlr-randr (before 0.4), as labwc 0.7's headless backend answers it
set text {HEADLESS-1 "Headless output 1"
  Make: (null)
  Model: (null)
  Serial: (null)
  Enabled: yes
  Modes:
    1280x720 px (current)
  Position: 0,0
  Transform: normal
  Scale: 1.000000
  Adaptive Sync: disabled
HEADLESS-2 "Headless output 2"
  Make: (null)
  Enabled: yes
  Modes:
    1920x1080 px, 60.000000 Hz (preferred)
    1440x900 px, 59.887001 Hz (current)
  Position: 1280,0
  Transform: 90
  Scale: 1.500000
  Adaptive Sync: disabled
HEADLESS-3 "Headless output 3"
  Enabled: no
  Modes:
    1280x720 px (current)
  Position: 0,0
  Transform: normal
  Scale: 1.000000
}
set outs [display::parse $text]
check "plain: the enabled outputs only" [expr {[lmap o $outs {lindex $o 0}] eq {HEADLESS-1 HEADLESS-2}}] "$outs"
check "plain: the current mode, not the first" [expr {[lrange [lindex $outs 0] 1 4] eq {0 0 1280 720}}] "[lindex $outs 0]"
check "plain: turned 90 degrees at 1.5, 1440x900 is 600x960" [expr {[lrange [lindex $outs 1] 1 4] eq {1280 0 600 960}}] "[lindex $outs 1]"

# the main output: display.conf's, the first when it names none or one not connected
set ::screen {2976 900}
file delete [display::confpath]
display::take $json
check "no display.conf: the first enabled output is the main one" [expr {[display::main] eq "eDP-1" && [display::rect] eq {0 0 1536 864}}] "[display::main] [display::rect]"
conf "main DP-2\n"
check "display.conf's main output is read (a change is reported)" [display::take $json] "no change"
check "the bars' rectangle is the main output's" [expr {[display::main] eq "DP-2" && [display::rect] eq {1536 0 1440 900}}] "[display::main] [display::rect]"
check "the same again is no change" [expr {![display::take $json]}] "a change"
conf "main HDMI-A-1\n"
display::take $json
check "a main output that is off: the first enabled one" [expr {[display::main] eq "eDP-1"}] [display::main]
conf "# Ribbon\nmain DP-9\n"
display::take $json
check "a main output not connected: the first enabled one" [expr {[display::main] eq "eDP-1"}] [display::main]

# a layout with an output left of 0,0: X coordinates are the layout's own (labwc maps an X window at x -1400 onto the
# output at -1440), and XWayland's root runs from 0,0 to the outputs' furthest right and bottom edges, so it is
# 1920x1080 here (both measured under headless labwc 0.7.1)
set left {[{"name": "A", "enabled": true, "modes": [{"width": 1440, "height": 900, "current": true}], "position": {"x": -1440, "y": 0}, "scale": 1, "transform": "normal"},
	{"name": "B", "enabled": true, "modes": [{"width": 1920, "height": 1080, "current": true}], "position": {"x": 0, "y": 0}, "scale": 1, "transform": "normal"}]}
set ::screen {1920 1080}
namespace eval display { variable trusted 0 }
conf "main B\n"
display::take $left
check "an output left of 0,0: the outputs are this X screen's, the main one keeps its place" [expr {[display::main] eq "B" && [display::rect] eq {0 0 1920 1080}}] "[display::main] [display::rect]"
conf "main A\n"
display::take $left
check "an output left of 0,0 as the main one: its X rectangle starts left of 0" [expr {[display::rect] eq {-1440 0 1440 900}}] [display::rect]

# a fractional scale: wlroots' logical size is the mode divided by the (single-precision) scale, cut to whole
# pixels, so 2560x1440 at 1.5 is 1706x960 (headless labwc 0.7.1: an output right of it sits at 1706, and the X
# root is 1706 + its width)
check "2560x1440 at 1.5 is 1706x960, as wlroots cuts it" [expr {[display::logical 2560 1440 1.500000 normal] eq {1706 960}}] [display::logical 2560 1440 1.500000 normal]
check "1440x900 at 1.2 is 1200x750" [expr {[display::logical 1440 900 1.200000 normal] eq {1200 750}}] [display::logical 1440 900 1.200000 normal]
check "1366x768 at 1.25 is 1092x614" [expr {[display::logical 1366 768 1.250000 normal] eq {1092 614}}] [display::logical 1366 768 1.250000 normal]

# outputs that are not this X screen's (another compositor's, or Xvfb): the whole screen
namespace eval display { variable trusted 0 }
set ::screen {1440 900}
display::take $json
check "outputs that do not span the X screen are not used: the whole screen" [expr {[display::rect] eq {0 0 1440 900} && [display::main] eq ""}] "[display::rect] [display::main]"
display::take ""
check "no outputs at all: the whole screen" [expr {[display::rect] eq {0 0 1440 900}}] [display::rect]
set ::env(RIBBON_SCREEN) 1440x900
check "RIBBON_SCREEN: wlr-randr is not asked" [expr {[display::randr_argv] eq {}}] [display::randr_argv]
unset ::env(RIBBON_SCREEN)

file delete -force $tmp
if {$failed} { puts "shell display: $failed failed"; exit 1 }
puts "shell display: all checks passed"
