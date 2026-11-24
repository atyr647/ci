# settings-input.tcl - Settings → Keyboard and mouse, the backend (apps/settings/input.tcl) with no display: the
# settings file, validation, the layout list, touchpad detection, labwc's generated files and the reconfigure.
#   tclsh8.6 tests/settings-input.tcl FILES-DIR TMP-DIR
# The step (tests/steps.d/55-settings-input.sh) gives a fresh HOME / XDG dirs under TMP-DIR and a fake reconfigure
# command that appends a line to TMP-DIR/reconf.log.
lassign $argv D T
set fails 0
proc check {what cond} { if {[uplevel 1 [list expr $cond]]} { puts "ok   $what" } else { puts "FAIL $what"; incr ::fails } }
proc slurp {f} { if {[catch {open $f} fh]} { return "<none>" }; set t [read $fh]; close $fh; return $t }
proc spit {f t} { file mkdir [file dirname $f]; set fh [open $f w]; puts -nonewline $fh $t; close $fh }
proc waitfor {cond {ms 3000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel 1 [list expr $cond]]} { if {[clock milliseconds] > $end} { return 0 }; after 20 {set ::tick 1}; vwait ::tick }
	return 1
}
proc reconfs {} { set t [slurp $::T/reconf.log]; expr {$t eq "<none>" ? 0 : [llength [split [string trim $t] \n]]} }
set FX [file join [file dirname [file normalize [info script]]] fixtures input]
set root $T/root
file mkdir $root/usr/share/X11/xkb/rules $root/proc/bus/input
set ::env(RIBBON_INPUT_ROOT) $root
foreach v {XKB_DEFAULT_LAYOUT XKB_DEFAULT_VARIANT XKB_DEFAULT_OPTIONS LABWC_PID} { unset -nocomplain ::env($v) }
source -encoding utf-8 [file join $D apps settings input.tcl]
set conf [inp::conf_file]
set gen [inp::gen_dir]
check "the settings file is \$XDG_CONFIG_HOME/ribbon/input.conf" {$conf eq "$T/cfg/ribbon/input.conf"}
check "the generated layer is its own (\$XDG_STATE_HOME/ribbon/xdg-input/labwc), not the terminal's" {$gen eq "$T/state/ribbon/xdg-input/labwc"}

# ---- nothing there: no settings file, no rules list, no device list
set m [inp::model]
check "with no file the model is Ribbon's defaults" {[dict get $m LAYOUT] eq "us" && [dict get $m REPEAT_DELAY] == 500 && [dict get $m REPEAT_RATE] == 20 && [dict get $m TOUCH_TAP] eq "yes" && [dict get $m TOUCH_NATURAL] eq "yes" && [dict get $m TOUCH_DWT] eq "yes" && [dict get $m MOUSE_ACCEL] eq "yes" && [dict get $m MOUSE_SPEED] eq "0.00" && [dict get $m NUMLOCK] eq "no"}
check "with no device list there is no touchpad" {[dict get $m touchpad] == 0}
check "with no rules list the built-in layouts are offered" {[llength [inp::layouts]] >= 20 && [inp::layout_name us] eq "English (US)"}
check "  and the subtitle names the layout and the mouse" {[inp::subtitle] eq "English (US) · mouse"}
inp::generate
check "with no settings file nothing is generated" {![file exists $gen/rc.xml] && ![file exists $gen/environment]}

# ---- the rules list
file copy $FX/evdev.lst $root/usr/share/X11/xkb/rules/evdev.lst
set inp::lcache ""
set L [inp::layouts]
check "the rules list gives layouts and variants, by name" {[lmap it $L {lindex $it 1}] eq {{English (Dvorak)} {English (US)} {English (US, intl., with dead keys)} French {French (AZERTY)} German {German (Neo 2)} {Japanese (PC-98)}}}
check "  with the values labwc's environment takes" {[lmap it $L {lindex $it 0}] eq {us(dvorak) us us(intl) fr fr(azerty) de de(neo) nec_vndr/jp}}
check "  (the custom layout and malformed lines are left out)" {[lsearch -index 0 $L custom] < 0 && [llength $L] == 8}

# ---- touchpad detection
file copy $FX/devices-touchpad $root/proc/bus/input/devices
set inp::tp {0 0}
check "a touchpad in the kernel's device list is found" {[inp::has_touchpad] == 1}
check "  and the subtitle says so" {[inp::subtitle] eq "English (US) · mouse, touchpad"}
file copy -force $FX/devices-mouse $root/proc/bus/input/devices
set inp::tp {0 0}
check "a mouse, a touch screen and a pen are not a touchpad (and garbage in the list does no harm)" {[inp::has_touchpad] == 0}
check "the answer is kept for two seconds" {[file copy -force $FX/devices-touchpad $root/proc/bus/input/devices] eq "" && [inp::has_touchpad] == 0}
set inp::tp {0 0}

# ---- what the session inherited shows until the file has a layout
set ::env(XKB_DEFAULT_LAYOUT) "de(neo),us"; set ::env(XKB_DEFAULT_VARIANT) ",dvorak"; set ::env(XKB_DEFAULT_OPTIONS) "compose:ralt,grp:alt_shift_toggle,caps:escape"
check "the session's XKB_DEFAULT_* is shown while the file has no layout" {[inp::layout_value 1] eq "de(neo)" && [inp::layout_value 2] eq "us(dvorak)" && [inp::get SWITCH] eq "alt_shift" && [inp::get CAPS] eq "esc"}
check "a mouse row set then leaves the layout to the session (no environment file)" {[inp::put MOUSE_LEFT yes] && [file exists $gen/rc.xml] && ![file exists $gen/environment] && [string trim [slurp $conf]] eq "MOUSE_LEFT=yes"}
check "  and the first change asked labwc to reconfigure" {[waitfor {[reconfs] == 1}]}
check "a layout row set saves every layout row (what was inherited with it)" {[inp::put CAPS ctrl] && [lsort [split [string trim [slurp $conf]] \n]] eq {CAPS=ctrl LAYOUT2=us LAYOUT=de MOUSE_LEFT=yes SWITCH=alt_shift VARIANT2=dvorak VARIANT=neo}}
check "  and the environment file is written from them" {[slurp $gen/environment] eq "[lindex [split [inp::env_text] \n] 0]\nXKB_DEFAULT_LAYOUT=de,us\nXKB_DEFAULT_VARIANT=neo,dvorak\nXKB_DEFAULT_OPTIONS=grp:alt_shift_toggle,caps:ctrl_modifier\n"}
foreach v {XKB_DEFAULT_LAYOUT XKB_DEFAULT_VARIANT XKB_DEFAULT_OPTIONS} { unset ::env($v) }
check "  so the file, not the session, is what counts from then on" {[inp::layout_value 1] eq "de(neo)" && [inp::get CAPS] eq "ctrl"}
file delete $conf
inp::generate
check "the settings file gone, the generated files go too" {![file exists $gen/rc.xml] && ![file exists $gen/environment]}

# ---- every row: its values, what is refused
set n [reconfs]
foreach {key good bad} {
	REPEAT_DELAY {100 300 600} {99 601 3e2 -5 abc {} 0300 0x12c}
	REPEAT_RATE {8 30 48} {7 49 2.5 x 010 030}
	NUMLOCK {yes no} {on 1 {}}
	MOUSE_SPEED {-1.00 0.00 0.50 1.00} {1.01 -1.5 fast {}}
	MOUSE_ACCEL {yes no} {adaptive}
	MOUSE_NATURAL {yes no} {true}
	MOUSE_LEFT {yes no} {left}
	TOUCH_SPEED {-1.00 0.24 1.00} {2 x}
	TOUCH_TAP {yes no} {maybe}
	TOUCH_NATURAL {yes no} {0}
	TOUCH_DWT {yes no} {Yes}
	SWITCH {win_space alt_shift ctrl_shift alt_space shifts} {grp:toggle {} caps}
	CAPS {caps ctrl esc} {super {}}
} {
	set okall 1
	foreach v $good { if {![inp::put $key $v] || [inp::get $key] ne $v} { set okall 0 } }
	set before [slurp $conf]
	foreach v $bad { if {[inp::put $key $v] || $inp::error eq "" || [inp::get $key] ne [lindex $good end]} { set okall 0 } }
	check "$key takes [join $good {, }] and refuses the rest, leaving the file as it was" {$okall && [slurp $conf] eq $before}
}
check "an unknown key is refused" {![inp::put SHELL /bin/sh] && ![inp::put layout us]}
check "a number is saved with two decimals" {[inp::put MOUSE_SPEED 0.5] && [inp::get MOUSE_SPEED] eq "0.50" && [inp::put TOUCH_SPEED -0.239999] && [inp::get TOUCH_SPEED] eq "-0.24"}
check "many changes close together are few reconfigures (the first at once, the rest together)" {[waitfor {[reconfs] > $n}] && [waitfor {$inp::pending eq ""}] && [reconfs] - $n <= 12}
waitfor {[clock milliseconds] - $inp::last > 300}
set n [reconfs]
foreach v {101 102 103 104 105 106} { inp::put REPEAT_DELAY $v }
check "  six in a row: two" {[waitfor {$inp::pending eq ""}] && [waitfor {[reconfs] == $n + 2}] && [reconfs] == $n + 2}
set n [reconfs]
# the window closed while a reconfigure waits (a slider let go, then the window shut at once): it is sent before the
# process goes, else labwc keeps the value before the last
set kid [file join $T quit-early.tcl]
spit $kid "source -encoding utf-8 [list [file join $D apps settings input.tcl]]\nset inp::last \[clock milliseconds\]\ninp::put REPEAT_DELAY 107\nexit 0\n"
catch {exec [info nameofexecutable] $kid}
check "a change made just before the window closes still reaches labwc" {[inp::get REPEAT_DELAY] == 107 && [waitfor {[reconfs] == $n + 1} 1000]}
set n [reconfs]
check "the same value again writes nothing and asks for nothing" {[inp::put REPEAT_DELAY 107] && [waitfor {[reconfs] > $n} 400] == 0}

# ---- layouts
check "a layout with a variant is saved as both" {[inp::set_layout 1 us(dvorak)] && [inp::get LAYOUT] eq "us" && [inp::get VARIANT] eq "dvorak" && [inp::layout_value 1] eq "us(dvorak)"}
check "the second layout, and none" {[inp::set_layout 2 de] && [inp::layout_value 2] eq "de" && [inp::set_layout 2 ""] && [inp::layout_value 2] eq ""}
check "the first layout cannot be none; a made-up value is refused" {![inp::set_layout 1 ""] && ![inp::set_layout 1 {us;rm -rf}] && ![inp::set_layout 2 {de(a b)}] && [inp::layout_value 1] eq "us(dvorak)"}
check "the subtitle names both layouts" {[inp::set_layout 2 de(neo)] && [inp::subtitle] eq "English (Dvorak), German (Neo 2) · mouse, touchpad"}

# ---- labwc's files
inp::put SWITCH win_space; inp::put CAPS esc
check "two layouts: as many variants, the switch key and the Caps Lock option" {[inp::xkb [inp::settings]] eq {layout us,de variant dvorak,neo options grp:win_space_toggle,caps:escape}}
inp::set_layout 1 us
check "  a variant only on the second keeps its place" {[dict get [inp::xkb [inp::settings]] variant] eq ",neo"}
inp::set_layout 2 ""; inp::put CAPS caps
check "one layout, Caps Lock as it is: the variant and the options are written empty (labwc then clears them)" {[slurp $gen/environment] eq "[lindex [split [inp::env_text] \n] 0]\nXKB_DEFAULT_LAYOUT=us\nXKB_DEFAULT_VARIANT=\nXKB_DEFAULT_OPTIONS=\n"}
foreach {k v} {REPEAT_DELAY 300 REPEAT_RATE 30 NUMLOCK yes MOUSE_SPEED 0 MOUSE_ACCEL no MOUSE_NATURAL no MOUSE_LEFT yes TOUCH_SPEED 0.24 TOUCH_TAP yes TOUCH_NATURAL no TOUCH_DWT yes} { inp::put $k $v }
set rc [slurp $gen/rc.xml]
check "rc.xml: the keyboard's repeat and Num Lock" {[string match {*<keyboard>*<repeatRate>30</repeatRate>*<repeatDelay>300</repeatDelay>*<numlock>on</numlock>*</keyboard>*} $rc]}
check "rc.xml: the mouse category" {[regexp {<device category="non-touch">\s*<pointerSpeed>0.00</pointerSpeed>\s*<accelProfile>flat</accelProfile>\s*<naturalScroll>no</naturalScroll>\s*<leftHanded>yes</leftHanded>\s*</device>} $rc]}
check "rc.xml: the touchpad category" {[regexp {<device category="touchpad">\s*<pointerSpeed>0.24</pointerSpeed>\s*<tap>yes</tap>\s*<naturalScroll>no</naturalScroll>\s*<disableWhileTyping>yes</disableWhileTyping>\s*</device>} $rc]}
check "no temporary file is left beside the settings or the generated files" {[glob -nocomplain $gen/*.tmp [file dirname $conf]/*.tmp] eq ""}
spit $T/rc-for-xmllint.xml $rc

# ---- the file by hand: comments and unknown lines stay, bad values fall back
spit $conf "# mine\nREPEAT_RATE=fast\nFUTURE_KEY=1\nMOUSE_LEFT=yes\n\nnot a line\nLAYOUT=../../etc\nREPEAT_DELAY=250\nREPEAT_DELAY=260\n"
check "a bad value in the file is the default; the last line for a key counts" {[inp::get REPEAT_RATE] == 20 && [inp::get REPEAT_DELAY] == 260 && [inp::get LAYOUT] eq "us" && [inp::get MOUSE_LEFT] eq "yes"}
inp::put REPEAT_DELAY 400
check "a change keeps the comment and the lines it does not know" {[slurp $conf] eq "# mine\nREPEAT_RATE=fast\nFUTURE_KEY=1\nMOUSE_LEFT=yes\n\nnot a line\nLAYOUT=../../etc\nREPEAT_DELAY=400\n"}
check "  and a bad layout in the file never reaches labwc's environment" {![file exists $gen/environment]}
spit $conf "\x00\x01\xff binary\n=\n==\nKEY\n"
check "a file of garbage is every default" {[inp::get REPEAT_DELAY] == 500 && [dict size [inp::model]] == 18}

# ---- a place that cannot be written
set keep $::env(XDG_CONFIG_HOME)
spit $T/afile x
set ::env(XDG_CONFIG_HOME) $T/afile
check "where the file cannot be written a change is refused, with the reason, and the row stays" {![inp::put NUMLOCK yes] && $inp::error ne "" && [inp::get NUMLOCK] eq "no"}
set ::env(XDG_CONFIG_HOME) $keep

# ---- ribbon-input generate (the session's call)
spit $conf "REPEAT_RATE=33\nLAYOUT=fr\nVARIANT=azerty\n"
file delete -force $T/state/ribbon
check "ribbon-input generate writes both files from the settings file" {![catch {exec [info nameofexecutable] [file join $D apps settings input.tcl] generate}] && [string match *<repeatRate>33</repeatRate>* [slurp $gen/rc.xml]] && [string match "*XKB_DEFAULT_LAYOUT=fr\nXKB_DEFAULT_VARIANT=azerty\n*" [slurp $gen/environment]]}
set mt [file mtime $gen/rc.xml]; after 1100
check "  again with nothing changed it writes nothing" {![catch {exec [info nameofexecutable] [file join $D apps settings input.tcl] generate}] && [file mtime $gen/rc.xml] == $mt}
check "  and it refuses anything but generate" {[catch {exec [info nameofexecutable] [file join $D apps settings input.tcl] --reconfigure}]}
check "the terminal's generated rc.xml is another file, untouched" {[spit $T/state/ribbon/xdg/labwc/rc.xml "<labwc_config/>\n"] eq "" && [inp::put REPEAT_RATE 34] && [slurp $T/state/ribbon/xdg/labwc/rc.xml] eq "<labwc_config/>\n"}

# ---- the real rules list, when this machine has one
unset ::env(RIBBON_INPUT_ROOT)
set inp::lcache ""
if {[inp::rules_file] ne ""} {
	set L [inp::layouts]
	set names [lmap it $L {lindex $it 1}]
	check "the real rules list: [llength $L] layouts and variants, every value one input.conf can hold" {[llength $L] > 100 && [inp::layout_name us] eq "English (US)" && [lsearch -index 0 $L us(dvorak)] >= 0 && [lsearch -exact [lmap it $L {regexp {^([^()]+)(\((.*)\))?$} [lindex $it 0] -> l - v; expr {[inp::valid LAYOUT $l] && [inp::valid VARIANT $v]}}] 0] < 0}
	check "  in the order of their names" {$names eq [lsort -dictionary $names]}
	set opts [slurp [inp::rules_file]]
	set missing {}
	foreach {k label o} $inp::switchdefs { if {![regexp -line "^\\s+$o\\s" $opts]} { lappend missing $o } }
	foreach {k o} $inp::capsdefs { if {$o ne "" && ![regexp -line "^\\s+$o\\s" $opts]} { lappend missing $o } }
	check "  and every XKB option the page can write is one the rules know ($missing)" {$missing eq ""}
} else { puts "note no XKB rules list on this machine: the real list is not checked" }
if {[file readable /proc/bus/input/devices]} {
	set inp::tp {0 0}
	check "the real device list reads without error (touchpad: [inp::has_touchpad])" {[inp::has_touchpad] in {0 1}}
}
puts [expr {$fails ? "$fails FAILED" : "all passed"}]
exit [expr {$fails > 0}]
