# input.tcl - the keyboard, the mouse and the touchpad (Settings → Keyboard and mouse; no Tk here).
#
# The settings are $XDG_CONFIG_HOME/ribbon/input.conf (KEY=VALUE, written to a temporary file and renamed). labwc's
# files are DERIVED from it into a layer of their own that ribbon-session puts on XDG_CONFIG_DIRS, so labwc
# (--merge-config) merges them over Ribbon's defaults and under the user's ~/.config/labwc:
#
#   $XDG_STATE_HOME/ribbon/xdg-input/labwc/rc.xml        <keyboard> repeatRate repeatDelay numlock; <libinput> the
#                                                        "non-touch" (mouse) and "touchpad" categories
#   $XDG_STATE_HOME/ribbon/xdg-input/labwc/environment   XKB_DEFAULT_LAYOUT / _VARIANT / _OPTIONS (written only once
#                                                        a layout row has been set; until then Ribbon's or the
#                                                        system's layout stands)
#
# The terminal's generated rc.xml is another layer ($XDG_STATE_HOME/ribbon/xdg), so neither rewrites the other. A
# change is written, the two files are generated again and labwc is asked to reconfigure (SIGHUP to $LABWC_PID, or
# `labwc --reconfigure`; never waited for): labwc reads rc.xml and the environment files again and applies them to
# the keyboards and pointers it has. `ribbon-input generate` (ribbon-session, before labwc starts) derives the files
# again at every login, so they follow input.conf even if the state directory was emptied.
#
#   inp::model                 every setting (validated, defaults filled in) and `touchpad` (1 when one is attached)
#   inp::get KEY               one setting
#   inp::put KEY VALUE         validate, save, generate, reconfigure; 1 when it took, else 0 with inp::error set and
#                              the model as it was
#   inp::set_layout N VALUE    the first or second layout from a list value ("us", "us(dvorak)", "" = none)
#   inp::layout_value N        that value for the layout in use
#   inp::layouts               {value label} for every layout and variant of the XKB rules list (evdev.lst), by label
#   inp::switches              {key label} for the keys that switch between two layouts
#   inp::subtitle              the page's subtitle: the layout(s), then what points
#
# Environment (tests): RIBBON_INPUT_ROOT (a root holding usr/share/X11/xkb/rules/evdev.lst and
# proc/bus/input/devices), RIBBON_INPUT_RECONFIGURE (a command run in place of the reconfigure).

namespace eval inp {
	# KEY -> default. The defaults are what Ribbon's rc.xml and environment give a session that has no input.conf.
	variable defaults {
		LAYOUT us VARIANT {} LAYOUT2 {} VARIANT2 {} SWITCH win_space CAPS caps
		REPEAT_DELAY 500 REPEAT_RATE 20 NUMLOCK no
		MOUSE_SPEED 0.00 MOUSE_ACCEL yes MOUSE_NATURAL no MOUSE_LEFT no
		TOUCH_SPEED 0.00 TOUCH_TAP yes TOUCH_NATURAL yes TOUCH_DWT yes
	}
	# the rows that make XKB_DEFAULT_*: saved together, so that the environment file never mixes a saved value with
	# one that was only inherited
	variable xkbkeys {LAYOUT VARIANT LAYOUT2 VARIANT2 SWITCH CAPS}
	# the switch keys: key, label, XKB option
	variable switchdefs {
		win_space  {Super Space}     grp:win_space_toggle
		alt_shift  {Alt Shift}       grp:alt_shift_toggle
		ctrl_shift {Ctrl Shift}      grp:ctrl_shift_toggle
		alt_space  {Alt Space}       grp:alt_space_toggle
		shifts     {Both Shift keys} grp:shifts_toggle
	}
	variable capsdefs {caps {} ctrl caps:ctrl_modifier esc caps:escape}
	variable RANGE
	array set RANGE {REPEAT_DELAY {100 600} REPEAT_RATE {8 48}}
	variable error ""        ;# why the last inp::put did not take
	variable onchange ""     ;# run after a change
	variable lcache ""       ;# the layout list, once read
	variable lnames          ;# value -> label
	variable tp {0 0}        ;# touchpad: {when read (ms), answer}
	variable last 0          ;# when labwc was last asked to reconfigure (ms)
	variable pending ""      ;# the after id of a reconfigure that waits
	# used when the XKB rules list is missing
	variable fallback {
		us {English (US)} gb {English (UK)} de German fr French es Spanish it Italian pt Portuguese
		br {Portuguese (Brazil)} nl Dutch be Belgian ch {German (Switzerland)} at {German (Austria)}
		se Swedish no Norwegian dk Danish fi Finnish pl Polish cz Czech hu Hungarian ru Russian
		ua Ukrainian tr Turkish gr Greek il Hebrew jp Japanese kr Korean latam {Spanish (Latin American)}
		ca {French (Canada)} ie Irish
	}
}

# ---- files ------------------------------------------------------------------------------------

proc inp::dir {var fallback} {
	if {[info exists ::env($var)] && $::env($var) ne ""} { return $::env($var) }
	file join [expr {[info exists ::env(HOME)] && $::env(HOME) ne "" ? $::env(HOME) : "/tmp"}] {*}$fallback
}
proc inp::root {} { expr {[info exists ::env(RIBBON_INPUT_ROOT)] ? $::env(RIBBON_INPUT_ROOT) : ""} }
proc inp::conf_file {} { file join [inp::dir XDG_CONFIG_HOME .config] ribbon input.conf }
proc inp::gen_dir {} { file join [inp::dir XDG_STATE_HOME {.local state}] ribbon xdg-input labwc }

proc inp::slurp {f} {
	if {[catch {::open $f r} fh]} { return "" }
	fconfigure $fh -encoding utf-8
	if {[catch {::read $fh} t]} { set t "" }
	catch {::close $fh}
	return $t
}
# TEXT into FILE by a temporary file and a rename; an error is the caller's to catch.
proc inp::spit {f text} {
	file mkdir [file dirname $f]
	set tmp "$f.[pid].tmp"
	if {[catch {
		set fh [::open $tmp w]
		fconfigure $fh -encoding utf-8
		puts -nonewline $fh $text
		::close $fh
		file rename -force $tmp $f
	} err]} {
		catch {::close $fh}
		catch {file delete $tmp}
		error $err
	}
}

# ---- the settings -----------------------------------------------------------------------------

# The file's lines, and the KEY=VALUE pairs in them (the last line for a key wins; anything else is kept as it is).
proc inp::conf_lines {} {
	set t [inp::slurp [inp::conf_file]]
	if {[string trim $t] eq ""} { return {} }
	split [string trimright $t \n] \n
}
proc inp::raw {} {
	set d {}
	foreach line [inp::conf_lines] {
		if {[regexp {^([A-Z][A-Z0-9_]*)=(.*)$} $line -> k v]} { dict set d $k [string trim $v] }
	}
	return $d
}

# The XKB option of a switch key ("" when there is no such key).
proc inp::switch_option {key} {
	variable switchdefs
	foreach {k label opt} $switchdefs { if {$k eq $key} { return $opt } }
	return ""
}
# Is VALUE one KEY can hold?
proc inp::valid {key value} {
	variable RANGE; variable switchdefs; variable capsdefs
	switch -glob -- $key {
		LAYOUT { regexp {^[A-Za-z0-9_][A-Za-z0-9_/-]{0,31}$} $value }
		LAYOUT2 { expr {$value eq "" || [regexp {^[A-Za-z0-9_][A-Za-z0-9_/-]{0,31}$} $value]} }
		VARIANT - VARIANT2 { regexp {^[A-Za-z0-9_.+-]{0,48}$} $value }
		SWITCH { expr {$value ne "" && [inp::switch_option $value] ne ""} }
		CAPS { dict exists $capsdefs $value }
		REPEAT_DELAY - REPEAT_RATE {
			lassign $RANGE($key) lo hi
			# no leading zero: Tcl would read "0300" as octal (192) where labwc reads 300
			expr {[regexp {^[1-9][0-9]{0,5}$} $value] && $value >= $lo && $value <= $hi}
		}
		*_SPEED { expr {[regexp {^-?[0-9](\.[0-9]{1,3})?$} $value] && $value >= -1.0 && $value <= 1.0} }
		NUMLOCK - MOUSE_ACCEL - MOUSE_NATURAL - MOUSE_LEFT - TOUCH_TAP - TOUCH_NATURAL - TOUCH_DWT { expr {$value in {yes no}} }
		default { return 0 }
	}
}

# What the session was started with (labwc hands its environment files' XKB_DEFAULT_* to what it starts): the
# layout rows show it until input.conf has rows of its own.
proc inp::inherited {} {
	variable switchdefs
	set d {}
	set get {{n} { expr {[info exists ::env($n)] ? $::env($n) : ""} }}
	set ls [split [apply $get XKB_DEFAULT_LAYOUT] ,]
	set vs [split [apply $get XKB_DEFAULT_VARIANT] ,]
	set i 0
	foreach {lk vk} {LAYOUT VARIANT LAYOUT2 VARIANT2} {
		set l [string trim [lindex $ls $i]]; set v [string trim [lindex $vs $i]]
		# "us(dvorak)" is a layout with its variant, as labwc's own example file writes it
		if {[regexp {^([^()]+)\(([^()]*)\)$} $l -> l2 v2]} { set l $l2; set v $v2 }
		if {$l ne "" && [inp::valid LAYOUT $l]} {
			dict set d $lk $l
			if {[inp::valid VARIANT $v]} { dict set d $vk $v }
		} elseif {$i == 0} break
		incr i
	}
	foreach o [split [apply $get XKB_DEFAULT_OPTIONS] ,] {
		set o [string trim $o]
		foreach {k label opt} $switchdefs { if {$o eq $opt} { dict set d SWITCH $k } }
		switch -- $o { caps:escape { dict set d CAPS esc } caps:ctrl_modifier - ctrl:nocaps { dict set d CAPS ctrl } }
	}
	return $d
}

# Every setting: the file's value when it is one the key can hold, else what the session inherited, else the default.
proc inp::settings {} {
	variable defaults; variable xkbkeys
	set raw [inp::raw]
	set d $defaults
	if {![dict exists $raw LAYOUT] || ![inp::valid LAYOUT [dict get $raw LAYOUT]]} {
		# no layout of our own yet: the layout rows are the session's, whole
		set d [dict merge $d [inp::inherited]]
		foreach k $xkbkeys { dict unset raw $k }
	}
	dict for {k v} $raw {
		if {[dict exists $defaults $k] && [inp::valid $k $v]} { dict set d $k $v }
	}
	foreach k {MOUSE_SPEED TOUCH_SPEED} { dict set d $k [format %.2f [dict get $d $k]] }
	# a variant belongs to its layout: none without one
	if {[dict get $d LAYOUT2] eq ""} { dict set d VARIANT2 "" }
	return $d
}
proc inp::model {} {
	set d [inp::settings]
	dict set d touchpad [inp::has_touchpad]
	return $d
}
proc inp::get {key} { dict get [inp::settings] $key }

# Save PAIRS (key value ...): each key's line is replaced or added; every other line of the file stays.
proc inp::save {pairs} {
	set out {}
	set seen {}
	foreach line [inp::conf_lines] {
		if {[regexp {^([A-Z][A-Z0-9_]*)=} $line -> k] && [dict exists $pairs $k]} {
			if {![dict exists $seen $k]} { lappend out "$k=[dict get $pairs $k]"; dict set seen $k 1 }
		} else {
			lappend out $line
		}
	}
	dict for {k v} $pairs { if {![dict exists $seen $k]} { lappend out "$k=$v" } }
	inp::spit [inp::conf_file] "[join $out \n]\n"
}

# Set PAIRS: all of them valid, or nothing happens. Saved, generated, applied.
proc inp::put_many {pairs} {
	variable error ""
	variable xkbkeys; variable onchange
	set cur [inp::settings]
	set raw [inp::raw]
	set new {}
	dict for {k v} $pairs {
		if {[string match *_SPEED $k] && [string is double -strict $v]} { set v [format %.2f $v] }
		if {![inp::valid $k $v]} { set error "$k cannot be \"$v\""; return 0 }
		dict set new $k $v
	}
	# a layout row brings the others with it (see xkbkeys)
	set touches 0
	dict for {k v} $new { if {$k in $xkbkeys} { set touches 1 } }
	if {$touches} { foreach k $xkbkeys { if {![dict exists $new $k]} { dict set new $k [dict get $cur $k] } } }
	set same 1
	dict for {k v} $new { if {![dict exists $raw $k] || [dict get $raw $k] ne $v} { set same 0 } }
	if {$same} { return 1 }
	if {[catch {inp::save $new} err]} { set error $err; return 0 }
	if {[catch {inp::generate} err]} { set error $err }
	inp::reconfigure
	if {$onchange ne ""} { catch {uplevel #0 $onchange} }
	return 1
}
proc inp::put {key value} { inp::put_many [dict create $key $value] }

# ---- layouts ----------------------------------------------------------------------------------

proc inp::rules_file {} {
	foreach n {evdev.lst base.lst} {
		set f [inp::root]/usr/share/X11/xkb/rules/$n
		if {[file readable $f]} { return $f }
	}
	return ""
}
# {value label} for every layout ("us") and variant ("us(dvorak)") of the rules list, by label. The list's own
# names are used ("English (US)", "English (Dvorak)"). Without the list: a short built-in one.
proc inp::layouts {} {
	variable lcache; variable lnames; variable fallback
	if {$lcache ne ""} { return $lcache }
	array unset lnames
	set f [inp::rules_file]
	set sec ""
	if {$f ne ""} {
		foreach line [split [inp::slurp $f] \n] {
			if {[regexp {^!\s*(\S+)} $line -> s]} { set sec $s; continue }
			if {$sec eq "layout" && [regexp {^\s+(\S+)\s+(\S.*?)\s*$} $line -> code name]} {
				# "custom" needs a symbols file of the user's own
				if {$code ne "custom" && [inp::valid LAYOUT $code]} { set lnames($code) $name }
			} elseif {$sec eq "variant" && [regexp {^\s+(\S+)\s+(\S+):\s+(\S.*?)\s*$} $line -> var code name]} {
				if {[inp::valid LAYOUT $code] && $var ne "" && [inp::valid VARIANT $var]} { set lnames($code\($var\)) $name }
			}
		}
	}
	if {![array size lnames]} { array set lnames $fallback }
	set l {}
	foreach v [array names lnames] { lappend l [list $v $lnames($v)] }
	set lcache [lsort -dictionary -index 1 [lsort -index 0 $l]]
}
proc inp::layout_name {value} {
	variable lnames
	inp::layouts
	expr {[info exists lnames($value)] ? $lnames($value) : $value}
}
proc inp::join_layout {l v} { expr {$l ne "" && $v ne "" ? "$l\($v\)" : $l} }
proc inp::layout_value {n} {
	set d [inp::settings]
	if {$n == 2} { return [inp::join_layout [dict get $d LAYOUT2] [dict get $d VARIANT2]] }
	inp::join_layout [dict get $d LAYOUT] [dict get $d VARIANT]
}
proc inp::set_layout {n value} {
	variable error
	set l $value; set v ""
	regexp {^([^()]*)\(([^()]*)\)$} $value -> l v
	if {$n == 2} { return [inp::put_many [dict create LAYOUT2 $l VARIANT2 $v]] }
	if {$l eq ""} { set error "the first layout cannot be none"; return 0 }
	inp::put_many [dict create LAYOUT $l VARIANT $v]
}
proc inp::switches {} {
	variable switchdefs
	set l {}
	foreach {k label opt} $switchdefs { lappend l [list $k $label] }
	return $l
}
proc inp::subtitle {} {
	set s [inp::layout_name [inp::layout_value 1]]
	if {[inp::layout_value 2] ne ""} { append s ", [inp::layout_name [inp::layout_value 2]]" }
	append s " · mouse"
	if {[inp::has_touchpad]} { append s ", touchpad" }
	return $s
}

# ---- devices ----------------------------------------------------------------------------------

# Bit N of a kernel bitmap as /proc/bus/input/devices prints it (hex words, the highest first).
proc inp::bit {words n} {
	set w [expr {$::tcl_platform(pointerSize) * 8}]
	set word [lindex $words end-[expr {$n / $w}]]
	if {$word eq "" || ![string is xdigit -strict $word] || [scan $word %llx v] != 1} { return 0 }
	expr {($v >> ($n % $w)) & 1}
}
# Is a touchpad attached? The kernel's device list (/proc/bus/input/devices, readable by anyone) is judged as udev's
# input_id judges it: absolute X and Y (or multitouch positions), the finger tool (BTN_TOOL_FINGER), no pen, and not
# a screen (INPUT_PROP_DIRECT). Read again after two seconds, so a touchpad that appears or goes is followed.
proc inp::has_touchpad {} {
	variable tp
	set now [clock milliseconds]
	if {$now - [lindex $tp 0] < 2000} { return [lindex $tp 1] }
	set has 0
	foreach block [split [string map [list "\n\n" \x01] [inp::slurp [inp::root]/proc/bus/input/devices]] \x01] {
		array unset b
		array set b {PROP 0 KEY {} ABS {}}
		foreach line [split $block \n] {
			if {[regexp {^B: (PROP|KEY|ABS)=(.*)$} $line -> k v]} { set b($k) [string trim $v] }
		}
		set xy [expr {([inp::bit $b(ABS) 0] && [inp::bit $b(ABS) 1]) || [inp::bit $b(ABS) 0x35]}]
		if {$xy && [inp::bit $b(KEY) 0x145] && ![inp::bit $b(KEY) 0x140] && ![inp::bit $b(PROP) 1]} { set has 1; break }
	}
	set tp [list $now $has]
	return $has
}

# ---- labwc's files ----------------------------------------------------------------------------

# XKB_DEFAULT_LAYOUT, _VARIANT and _OPTIONS for the settings D: as many variants as layouts (xkbcommon wants that),
# the switch key only with a second layout.
proc inp::xkb {d} {
	variable switchdefs; variable capsdefs
	set ls [list [dict get $d LAYOUT]]; set vs [list [dict get $d VARIANT]]
	set opts {}
	if {[dict get $d LAYOUT2] ne ""} {
		lappend ls [dict get $d LAYOUT2]; lappend vs [dict get $d VARIANT2]
		lappend opts [inp::switch_option [dict get $d SWITCH]]
	}
	if {[dict get $capsdefs [dict get $d CAPS]] ne ""} { lappend opts [dict get $capsdefs [dict get $d CAPS]] }
	set v [join $vs ,]
	if {[string trim $v ,] eq ""} { set v "" }
	dict create layout [join $ls ,] variant $v options [join $opts ,]
}
# An empty value is written too: labwc sets the variable empty, which takes back an earlier variant or option.
proc inp::env_text {{d ""}} {
	if {$d eq ""} { set d [inp::settings] }
	set x [inp::xkb $d]
	set t "# Written by Settings (Keyboard and mouse) from ribbon/input.conf. Not for editing: it is written again.\n"
	append t "XKB_DEFAULT_LAYOUT=[dict get $x layout]\nXKB_DEFAULT_VARIANT=[dict get $x variant]\nXKB_DEFAULT_OPTIONS=[dict get $x options]\n"
}
proc inp::rc_text {{d ""}} {
	if {$d eq ""} { set d [inp::settings] }
	set t "<?xml version=\"1.0\"?>\n"
	append t "<!-- Written by Settings (Keyboard and mouse) from ribbon/input.conf. Not for editing: it is written again. -->\n"
	append t "<labwc_config>\n  <keyboard>\n"
	append t "    <repeatRate>[dict get $d REPEAT_RATE]</repeatRate>\n"
	append t "    <repeatDelay>[dict get $d REPEAT_DELAY]</repeatDelay>\n"
	append t "    <numlock>[expr {[dict get $d NUMLOCK] eq "yes" ? "on" : "off"}]</numlock>\n"
	append t "  </keyboard>\n  <libinput>\n"
	append t "    <device category=\"non-touch\">\n"
	append t "      <pointerSpeed>[dict get $d MOUSE_SPEED]</pointerSpeed>\n"
	append t "      <accelProfile>[expr {[dict get $d MOUSE_ACCEL] eq "yes" ? "adaptive" : "flat"}]</accelProfile>\n"
	append t "      <naturalScroll>[dict get $d MOUSE_NATURAL]</naturalScroll>\n"
	append t "      <leftHanded>[dict get $d MOUSE_LEFT]</leftHanded>\n"
	append t "    </device>\n    <device category=\"touchpad\">\n"
	append t "      <pointerSpeed>[dict get $d TOUCH_SPEED]</pointerSpeed>\n"
	append t "      <tap>[dict get $d TOUCH_TAP]</tap>\n"
	append t "      <naturalScroll>[dict get $d TOUCH_NATURAL]</naturalScroll>\n"
	append t "      <disableWhileTyping>[dict get $d TOUCH_DWT]</disableWhileTyping>\n"
	append t "    </device>\n  </libinput>\n</labwc_config>\n"
}

# labwc's two files from input.conf. With no input.conf there are none (Ribbon's defaults stand); the environment
# file exists only when input.conf has a layout of its own. A file that is already right is left alone.
proc inp::generate {} {
	set dir [inp::gen_dir]
	set raw [inp::raw]
	set want {}
	if {[dict size $raw]} {
		dict set want rc.xml [inp::rc_text]
		if {[dict exists $raw LAYOUT] && [inp::valid LAYOUT [dict get $raw LAYOUT]]} { dict set want environment [inp::env_text] }
	}
	foreach n {rc.xml environment} {
		set f [file join $dir $n]
		if {![dict exists $want $n]} { if {[file exists $f]} { file delete $f }; continue }
		if {[file exists $f] && [inp::slurp $f] eq [dict get $want $n]} continue
		inp::spit $f [dict get $want $n]
	}
	return 1
}

# Ask labwc to read its configuration again. Never waited for. The first change goes at once; more within a
# quarter of a second (a slider being dragged) go together when it has passed.
proc inp::reconfigure {} {
	variable last; variable pending
	if {$pending ne ""} return
	set wait [expr {250 - ([clock milliseconds] - $last)}]
	if {$wait <= 0} { inp::reconfigure_now } else { set pending [after $wait inp::reconfigure_now] }
}
proc inp::reconfigure_now {} {
	variable last [clock milliseconds]
	variable pending ""
	if {[info exists ::env(RIBBON_INPUT_RECONFIGURE)]} {
		set cmd $::env(RIBBON_INPUT_RECONFIGURE)
	} elseif {[info exists ::env(LABWC_PID)] && [regexp {^[1-9][0-9]*$} $::env(LABWC_PID)] && $::env(LABWC_PID) > 1} {
		set cmd [list kill -HUP $::env(LABWC_PID)]
	} else {
		set cmd [list labwc --reconfigure]
	}
	catch {exec {*}$cmd >& /dev/null </dev/null &}
}
# A reconfigure that still waits when the process exits (the window closed just after a change) is sent first.
proc inp::flush {args} {
	variable pending
	if {$pending ne ""} { after cancel $pending; inp::reconfigure_now }
}
if {"inp::flush" ni [lmap t [trace info execution ::exit] { lindex $t 1 }]} { trace add execution ::exit enter inp::flush }

# ---- ribbon-input ------------------------------------------------------------------------------

# `tclsh input.tcl generate`: labwc's files from input.conf, nothing else (the session, before labwc starts).
if {[info exists ::argv0] && [file normalize [info script]] eq [file normalize $::argv0]} {
	if {$::argv ne "generate"} { puts stderr "usage: ribbon-input generate"; exit 2 }
	if {[catch {inp::generate} err]} { puts stderr "ribbon-input: $err"; exit 1 }
	exit 0
}
