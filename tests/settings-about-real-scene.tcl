# settings-about-real-scene.tcl - Settings → About end to end: the page (page-about.tcl) over the real backend
# (about.tcl) reading a fake root (RIBBON_ABOUT_ROOT, made by tests/steps.d/57-settings-about-page.sh), the real labwc,
# df and stat where they are installed, and the name changed by clicks and keys through a stub pkexec and the real
# ribbon-hostname-helper working on the same fake root. Sourced by apps/settings/main.tcl through
# RIBBON_SETTINGS_SCENE.
#   RIBBON_ABOUT_SHOT   = file: a grab of the window once the name was changed
#   RIBBON_ABOUT_RESULT = file: the checks, one per line ("ok ..." or "FAIL ...")
proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }
set ui::caretfix off
namespace eval ascene { variable fails 0; variable lines {} }
proc ascene::check {what cond} { variable fails; variable lines; if {[uplevel #0 [list expr $cond]]} { lappend lines "ok   $what" } else { lappend lines "FAIL $what"; incr fails } }
proc ascene::draw {} { page::draw_now; update }
proc ascene::click {x y} { ascene::draw; ui::press [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; ui::release [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; update; ascene::draw }
proc ascene::type {text} { foreach ch [split $text ""] { settings::key [expr {$ch eq "-" ? "minus" : $ch}] $ch 0 }; update }
proc ascene::key {sym} { settings::key $sym {} 0; update; ascene::draw }
# Wait until COND holds, at most MS: 1 when it came to hold.
proc ascene::until {cond {ms 8000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 [list expr $cond]]} {
		if {[clock milliseconds] >= $end} { return 0 }
		after 20 {set ::ascene::tick 1}; vwait ::ascene::tick
	}
	return 1
}
proc ascene::row {label} {
	set m [about::model]
	foreach r [concat [dict get $m computer] [dict get $m system]] { if {[lindex $r 0] eq $label} { return [lindex $r 1] } }
	return "(no row)"
}
proc ascene::file {path} { if {[catch {open $::env(RIBBON_ABOUT_ROOT)$path r} fh]} { return "(none)" }; set t [read $fh]; close $fh; set t }
proc ascene::rename_to {name} {
	ascene::click 410 268
	foreach k {BackSpace BackSpace BackSpace BackSpace BackSpace BackSpace BackSpace BackSpace BackSpace BackSpace BackSpace BackSpace} { settings::key $k {} 0 }
	ascene::type $name
	ascene::key Return
}

settings::select about
ascene::draw
ascene::check "the page draws from the fake root: the strip's line and the subtitle" {[dict get [about::model] status] eq "Version 0.9" && [dict get [about::model] subtitle] eq "Ribbon 0.9"}
ascene::check "  the rows the files give: [lmap r [dict get [about::model] computer] {lindex $r 0}]" {[ascene::row Name] eq "ribbon" && [ascene::row Processor] eq "Test Chip 9000 · 2 threads" && [ascene::row Memory] eq "16 GB" && [ascene::row Kernel] eq "Linux 6.18.58" && [ascene::row Model] eq "(no row)"}
if {[auto_execok labwc] ne ""} {
	ascene::check "  the real labwc answers and the Desktop row comes: [expr {[ascene::until {[string match {labwc *} [ascene::row Desktop]]}] ? [ascene::row Desktop] : {no answer}}]" {[regexp {^labwc \d+(\.\d+)+ · Wayland$} [ascene::row Desktop]]}
} else { lappend ascene::lines "skip the real labwc (not installed)" }
if {[auto_execok df] ne ""} {
	ascene::check "  the real df answers and the Disk row says what is free: [expr {[ascene::until {[string match {* free} [ascene::row Disk]]}] ? [ascene::row Disk] : {no answer}}]" {[regexp {^[0-9.]+ (MB|GB|TB) · [0-9.]+ (MB|GB|TB) free$} [ascene::row Disk]]}
}

# the name: a click, the keys, Return; pkexec (a stand-in) runs the real helper on the fake root
ascene::rename_to studio-2
ascene::check "Return starts the change, without waiting for it" {!$abp::edit}
ascene::check "  the helper changed the name: the model has it" {[ascene::until {[dict get [about::model] hostname] eq "studio-2" && !$about::busy}]}
ascene::check "  /etc/hostname was written" {[ascene::file /etc/hostname] eq "studio-2\n"}
ascene::check "  /etc/hosts' 127.0.1.1 line too" {[ascene::file /etc/hosts] eq "127.0.0.1\tlocalhost\n127.0.1.1\tstudio-2\n"}
ascene::check "  pkexec was given the helper, set and the name" {![catch {open $::env(RIBBON_ABOUT_LOG) r} fh] && [string trim [read $fh][close $fh]] eq "$::env(RIBBON_ABOUT_HELPER) set studio-2"}
ascene::draw
if {[info exists ::env(RIBBON_ABOUT_SHOT)]} { after 300; update; exec import -window [winfo id $::settings::win] $::env(RIBBON_ABOUT_SHOT) }
ascene::click 970 161
ascene::check "Copy details has the new name and the real rows" {[string match "Version: Ribbon 0.9\nName: studio-2\nProcessor: Test Chip 9000 · 2 threads\nMemory: 16 GB\nKernel: Linux 6.18.58*" [clipboard get]]}

# a prompt that is dismissed: the name stays
set ::env(PKEXEC_SAYS) cancel
ascene::rename_to other
ascene::until {$about::busy == 0}
ascene::check "a dismissed prompt leaves the name as it was (and the backend knows why: $about::error)" {[dict get [about::model] hostname] eq "studio-2" && [ascene::file /etc/hostname] eq "studio-2\n" && $about::error eq "Cancelled"}
ascene::draw
ascene::check "  the row can be edited again" {[ascene::click 410 268] eq "" && $abp::edit && [ui::fval about-name] eq "studio-2"}
ascene::key Escape

if {[info exists ::env(RIBBON_ABOUT_RESULT)]} { set f [open $::env(RIBBON_ABOUT_RESULT) w]; fconfigure $f -encoding utf-8; puts $f [join $ascene::lines \n]; close $f } else { puts [join $ascene::lines \n] }
exit [expr {$ascene::fails > 0}]
