# settings-about-scene.tcl - Settings → About (page-about.tcl) in its board's state (Settings-A11-About), with
# about.tcl's model stood in for (the page's drawing, its hits and its keys are what is checked here; about.tcl itself
# is tests/settings-about.tcl). Sourced by apps/settings/main.tcl through RIBBON_SETTINGS_SCENE.
#   RIBBON_ABOUT_SHOT   = file: a grab of the window (ImageMagick import); FILE-edit.png is the name being edited
#   RIBBON_ABOUT_RESULT = file: the checks, one per line ("ok ..." or "FAIL ...")
proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }
set ui::caretfix off
namespace eval ascene { variable fails 0; variable lines {}; variable calls {}; variable refuse 0; variable refreshed 0 }
proc ascene::check {what cond} { variable fails; variable lines; if {[uplevel #0 [list expr $cond]]} { lappend lines "ok   $what" } else { lappend lines "FAIL $what ([lindex $::ascene::calls end])"; incr fails } }
proc ascene::draw {} { page::draw_now; update }
proc ascene::click {x y} { ascene::draw; ui::press [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; ui::release [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; update; ascene::draw }
proc ascene::type {text} { foreach ch [split $text ""] { settings::key [expr {$ch eq " " ? "space" : $ch eq "-" ? "minus" : $ch eq "!" ? "exclam" : $ch eq "." ? "period" : $ch}] $ch 0 }; update }
proc ascene::key {sym} { settings::key $sym {} 0; update; ascene::draw }
proc ascene::last {} { lindex $::ascene::calls end }

# the board's state
set ascene::M [dict create name Ribbon version 0.9 updates 0 status {Version 0.9 · up to date} \
	subtitle {Ribbon 0.9 on Framework Laptop 13} hostname ribbon busy 0 \
	computer {{Name ribbon} {Model {Framework Laptop 13}} {Processor {AMD Ryzen 7 7840U · 16 threads}} {Memory {32 GB}} {Graphics {Radeon 780M}}} \
	system {{Kernel {Linux 6.18.58}} {Desktop {labwc 0.20 · Wayland}} {Disk {1 TB · 412 GB free}} {Firmware {03.05 · UEFI}} {Installed {12 October 2026}}}]
proc about::start {} {}
proc about::refresh {} { incr ::ascene::refreshed }
proc about::model {} { return $::ascene::M }
proc about::set_name {name} {
	lappend ::ascene::calls [list set_name $name]
	if {$::ascene::refuse} { set ::about::error Cancelled; return }
	dict set ::ascene::M hostname $name
	dict set ::ascene::M computer [lreplace [dict get $::ascene::M computer] 0 0 [list Name $name]]
	abp::changed
}

settings::select about
ascene::draw
if {[info exists ::env(RIBBON_ABOUT_SHOT)]} { after 500; update; exec import -window [winfo id $::settings::win] $::env(RIBBON_ABOUT_SHOT) }

# ---- every control, as clicks (window coordinates)
# Copy details: every row, as text
clipboard clear; clipboard append nothing
ascene::click 970 161
set want "Version: Ribbon 0.9\nName: ribbon\nModel: Framework Laptop 13\nProcessor: AMD Ryzen 7 7840U · 16 threads\nMemory: 32 GB\nGraphics: Radeon 780M\nKernel: Linux 6.18.58\nDesktop: labwc 0.20 · Wayland\nDisk: 1 TB · 412 GB free\nFirmware: 03.05 · UEFI\nInstalled: 12 October 2026"
ascene::check "Copy details puts every row on the clipboard as Key: value lines" {[clipboard get] eq $want}

# the pencil: the name becomes a field holding the name
ascene::click 459 268
ascene::check "a click on the pencil makes the name a field" {$abp::edit && $ui::focus eq "about-name" && [ui::fval about-name] eq "ribbon"}
if {[info exists ::env(RIBBON_ABOUT_SHOT)]} { after 300; update; exec import -window [winfo id $::settings::win] [file rootname $::env(RIBBON_ABOUT_SHOT)]-edit.png }
ascene::check "  the field is the keyboard's, not the search's" {!$settings::searching && [lindex [ui::focused] 1] eq "field"}
ascene::key Escape
ascene::check "  Escape puts the name back and asks for nothing" {!$abp::edit && [ascene::last] ne {set_name ribbon} && [dict get $ascene::M hostname] eq "ribbon"}

# a full name (box.example.com): the field holds its first label, and Return on it unchanged asks for nothing
set ascene::calls {}
dict set ascene::M hostname box.example.com
ascene::click 459 268
ascene::check "a full name opens as its first label" {$abp::edit && [ui::fval about-name] eq "box"}
ascene::key Return
ascene::check "  Return on it unchanged asks for nothing (the full name stays)" {!$abp::edit && [lsearch -glob $ascene::calls {set_name *}] < 0}
dict set ascene::M hostname ribbon

# a click on the name itself does the same; what a name cannot hold never gets into the field
ascene::click 410 268
ascene::check "a click on the name makes it a field too" {$abp::edit}
foreach k {BackSpace BackSpace BackSpace BackSpace BackSpace BackSpace} { settings::key $k {} 0 }
ascene::type "my box!.2"
ascene::check "  typing keeps letters, digits and hyphens only" {[ui::fval about-name] eq "mybox2"}
ascene::key Return
ascene::check "  Return saves the name through the backend" {[ascene::last] eq {set_name mybox2} && !$abp::edit}
ascene::check "  and the row then shows the computer's new name" {[lindex [dict get [about::model] computer] 0 1] eq "mybox2"}

# a name that cannot be one: Return keeps the field
ascene::click 459 268
foreach k {BackSpace BackSpace BackSpace BackSpace BackSpace BackSpace} { settings::key $k {} 0 }
ascene::key Return
ascene::check "an empty name is not saved: the field stays" {$abp::edit && [llength $ascene::calls] == 1}
ascene::type "-pc"
ascene::key Return
ascene::check "  nor is one that starts with a hyphen" {$abp::edit && [ui::fval about-name] eq "-pc" && [llength $ascene::calls] == 1}
settings::key Home {} 0; settings::key Delete {} 0
ascene::type "-"
ascene::check "  (a hyphen can be typed, here after the caret went Home and the first one was deleted)" {[ui::fval about-name] eq "-pc"}
settings::key BackSpace {} 0
ascene::key Return
ascene::check "  with the hyphen gone it is saved" {[ascene::last] eq {set_name pc} && !$abp::edit}

# the name it already has: nothing is asked
ascene::click 410 268
set n [llength $ascene::calls]
ascene::check "(the field is open on the name it has)" {$abp::edit && [ui::fval about-name] eq "pc"}
ascene::key Return
ascene::check "Return on the unchanged name closes the field and asks for nothing" {!$abp::edit && [llength $ascene::calls] == $n}

# a click elsewhere closes the field
ascene::click 440 268
ascene::type "x"
ascene::click 800 560
ascene::check "a click elsewhere puts the name back" {!$abp::edit && [llength $ascene::calls] == $n}

# another page shown meanwhile: the field is closed when About comes back
ascene::click 440 268
settings::select sound; ascene::draw
settings::select about; ascene::draw
ascene::check "leaving the page closes the field" {!$abp::edit}

# a refusal (a cancelled prompt): the row is as it was
set ascene::refuse 1
ascene::click 440 268
ascene::type "z"
ascene::key Return
ascene::check "a refused change is asked for once and leaves the name as it was" {[ascene::last] eq {set_name pcz} && !$abp::edit && [lindex [dict get [about::model] computer] 0 1] eq "pc"}
set ascene::refuse 0

# while the helper is asked the name is not edited again
dict set ascene::M busy 1
ascene::click 440 268
ascene::check "the name is not a field while a change is being made" {!$abp::edit}
dict set ascene::M busy 0

# the keyboard: Tab reaches Copy details and the pencil; Return on the pencil opens the field
set ui::focus ""
ascene::key Tab
set first $ui::focus
ascene::key Tab
ascene::check "Tab reaches Copy details, then the pencil" {$first eq "about-copy" && $ui::focus eq "about-edit"}
ascene::key Return
ascene::check "  Return on the pencil makes the name a field" {$abp::edit && $ui::focus eq "about-name"}
ascene::key Escape

# honest states: no model, no version, updates waiting, nothing known at all
dict set ascene::M computer {{Name pc} {Processor {8 threads}}}
dict set ascene::M system {{Kernel {Linux 6.18.58}}}
dict set ascene::M status {Version 0.9 · 5 updates}
dict set ascene::M subtitle {Ribbon 0.9}
ascene::draw
if {[info exists ::env(RIBBON_ABOUT_SHOT)]} { after 300; update; exec import -window [winfo id $::settings::win] [file rootname $::env(RIBBON_ABOUT_SHOT)]-few.png }
ascene::check "the page draws with the rows there are" 1
dict set ascene::M computer {}; dict set ascene::M system {}; dict set ascene::M status {}; dict set ascene::M hostname {}
ascene::draw
ascene::click 459 268
ascene::check "the page draws with nothing known, and there is no name to edit" {!$abp::edit}
ascene::check "the page asked for the free space again as it was drawn" {$ascene::refreshed > 0}

if {[info exists ::env(RIBBON_ABOUT_RESULT)]} { set f [open $::env(RIBBON_ABOUT_RESULT) w]; puts $f [join $ascene::lines \n]; close $f } else { puts [join $ascene::lines \n] }
exit [expr {$ascene::fails > 0}]
