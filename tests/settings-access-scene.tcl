# settings-access-scene.tcl - Settings → Accessibility (page-access.tcl) in its board's state
# (Settings-A14-Accessibility) with the REAL access.tcl and appearance/ui.tcl: its file is the step's own
# XDG_CONFIG_HOME/ribbon/access.conf, ribbon-theme the step's stand-in (it logs each run). The window is grabbed for
# the board (the page and the 32 px rail), then every control is used as a person would (clicks, keys) and the file,
# the stand-in's log and the colours read back. Sourced by apps/settings/main.tcl through RIBBON_SETTINGS_SCENE.
#   RIBBON_ACC_SHOT   = file: a grab of the window (ImageMagick import)
#   RIBBON_ACC_RESULT = file: the checks, one per line ("ok ..." or "FAIL ...")
#   RIBBON_ACC_LOG    = the stand-in ribbon-theme's log
proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }
set ui::caretfix off
namespace eval ascene { variable fails 0; variable lines {} }
proc ascene::check {what cond} { variable fails; variable lines; if {[uplevel #0 [list expr $cond]]} { lappend lines "ok   $what" } else { lappend lines "FAIL $what"; incr fails } }
proc ascene::click {x y} { page::draw_now; ui::press [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; ui::release [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; update; page::draw_now; update }
proc ascene::key {sym {char ""}} { page::draw_now; settings::key $sym $char 0; update; page::draw_now; update }
proc ascene::slurp {f} { if {[catch {open $f} h]} { return "" }; set t [read $h]; close $h; set t }
proc ascene::conf {} { slurp [::file join $::env(XDG_CONFIG_HOME) ribbon access.conf] }
proc ascene::runs {} { llength [lsearch -all [split [slurp $::env(RIBBON_ACC_LOG)] \n] access*] }
# until ribbon-theme's runs reach N (it runs in the background), at most 5 s
proc ascene::ran {n} {
	set end [expr {[clock milliseconds] + 5000}]
	while {[runs] < $n || $acc::running ne ""} {
		if {[clock milliseconds] > $end} { return 0 }
		after 20; update
	}
	return 1
}

ascene::check "the rail item: Accessibility, after Sound in the first group, its page and the rows search reads" \
	{[lrange [settings::ids] 0 3] eq {appearance display sound access} && [settings::get access draw] eq "settings::draw_access" && "Reduce motion" in [settings::get access rows]}
ascene::check "search finds it by a row (cursor)" {[settings::matching cursor] eq {access}}
settings::select access
page::draw_now
update
set m [acc::model]
ascene::check "the board's state: 100 %, the default cursor, both switches off, no file yet" \
	{[dict get $m text] == 100 && [dict get $m cursor] == 24 && ![dict get $m contrast] && ![dict get $m motion] && [ascene::conf] eq "" && [dict get $m subtitle] eq "Text 100% · default cursor"}
if {[info exists ::env(RIBBON_ACC_SHOT)]} { after 500; update; exec import -window [winfo id $::settings::win] $::env(RIBBON_ACC_SHOT) }
set muted0 $ui::c(muted); set border0 $ui::c(border)

# Text size: a click on 150 %, then Left (the keyboard on the control)
ascene::click 608 165
ascene::check "a click on 150% writes TEXT_SCALE=150 and runs ribbon-theme access" {[ascene::conf] eq "TEXT_SCALE=150\n" && [ascene::ran 1]}
ascene::check "  the subtitle: Text 150% · default cursor" {[dict get [acc::model] subtitle] eq "Text 150% · default cursor"}
# Cursor size by a click on Larger
ascene::click 608 213
ascene::check "a click on Larger writes CURSOR_SIZE=48 (the line kept with the other)" {[ascene::conf] eq "TEXT_SCALE=150\nCURSOR_SIZE=48\n" && [ascene::ran 2]}
ascene::check "  the subtitle: Text 150% · larger cursor" {[dict get [acc::model] subtitle] eq "Text 150% · larger cursor"}
# High contrast: Settings redraws in the raised colours
ascene::click 1041 165
ascene::check "High contrast's switch writes HIGH_CONTRAST=yes" {[string match "*HIGH_CONTRAST=yes\n" [ascene::conf]] && [dict get [acc::model] contrast] && [ascene::ran 3]}
ascene::check "  Settings is redrawn at once in high contrast: muted text and the rules nearer the text colour" \
	{$ui::c(muted) eq [ui::mix $ui::c(fg) $muted0 0.5] && $ui::c(border) eq [ui::mix $ui::c(fg) $border0 0.4] && [ui::high_contrast]}
ascene::click 1041 213
ascene::check "Reduce motion's switch writes REDUCE_MOTION=yes; ui::reduce_motion says so to Ribbon's apps" \
	{[string match "*REDUCE_MOTION=yes\n" [ascene::conf]] && [ui::reduce_motion] && [ascene::ran 4]}
# the keyboard: Tab to the text size, Left
set ui::focus ""
ascene::key Tab
ascene::check "Tab reaches Text size first" {$ui::focus eq "acc-text"}
ascene::key Left
ascene::check "  Left picks 125%" {[string match "TEXT_SCALE=125\n*" [ascene::conf]] && [ascene::ran 5]}
ascene::key Tab; ascene::key Tab
ascene::check "  Tab twice: High contrast" {$ui::focus eq "acc-contrast"}
ascene::key space
ascene::check "  Space turns it off; the colours are the palette's again" \
	{[string match "*HIGH_CONTRAST=no\n*" [ascene::conf]] && $ui::c(muted) eq $muted0 && $ui::c(border) eq $border0 && [ascene::ran 6]}
# a ribbon-theme that fails: said in the subtitle
set ::env(RIBBON_ACC_FAIL) 1
ascene::click 529 213
ascene::ran 7
ascene::check "ribbon-theme failing: the file is written, the subtitle says what failed" \
	{[string match "*CURSOR_SIZE=32*" [ascene::conf]] && [dict get [acc::model] subtitle] eq "Could not apply: no palette here"}
unset ::env(RIBBON_ACC_FAIL)
ascene::click 450 213
ascene::ran 8
ascene::check "  the next run that works clears it" {[dict get [acc::model] subtitle] eq "Text 125% · default cursor"}

if {[info exists ::env(RIBBON_ACC_RESULT)]} { set f [open $::env(RIBBON_ACC_RESULT) w]; fconfigure $f -encoding utf-8; puts $f [join $ascene::lines \n]; close $f } else { puts [join $ascene::lines \n] }
exit [expr {$ascene::fails > 0}]
