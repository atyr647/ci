# settings-defaults-live.tcl - Settings → Default apps with nothing stood in for: the page (page-defaults.tcl) over
# the real defaults.tcl, in the scratch XDG folders tests/steps.d/57-settings-defaults-page.sh makes (two browsers, two
# terminals). A click on a dropdown and on an app must end in the file on disk. Sourced through RIBBON_SETTINGS_SCENE.
#   RIBBON_DEFAULTS_RESULT = file: the checks, one per line ("ok ..." or "FAIL ...")
proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }
set ui::caretfix off
namespace eval dlive { variable fails 0; variable lines {}; variable redraws 0 }
proc dlive::check {what ok} { variable fails; variable lines; if {$ok} { lappend lines "ok   $what" } else { lappend lines "FAIL $what"; incr fails } }
proc dlive::click {x y} { page::draw_now; ui::press [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; ui::release [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; update }
proc dlive::content {name} {
	set f [::file join $::env(XDG_CONFIG_HOME) $name]
	if {![::file exists $f]} { return "" }
	set fh [open $f]; set d [read $fh]; close $fh; return $d
}
proc dlive::row {id} { foreach r [dict get [defapps::model] rows] { if {[dict get $r id] eq $id} { return $r } } }
trace add execution defp::changed enter {apply {{args} { incr ::dlive::redraws }}}

settings::select defaults
page::draw_now
update
dlive::check "the page over the real backend: Chromium for the web (the first that can), Terminal the terminal, Music not set" \
	[expr {[dict get [defapps::model] subtitle] eq "Chromium for the web" && [dict get [dlive::row terminal] current] eq "ribbon-terminal.desktop" && [dict get [dlive::row music] current] eq ""}]
dlive::check "  nothing is written by looking" [expr {[dlive::content mimeapps.list] eq "" && [dlive::content xdg-terminals.list] eq ""}]
# Web: the list is Chromium, Firefox; the second is picked
dlive::click 539 165
dlive::click 539 247
dlive::check "a click on Firefox in Web's list writes http, https, text/html and Firefox's xhtml type to mimeapps.list" \
	[expr {[dlive::content mimeapps.list] eq "\[Default Applications\]\nx-scheme-handler/http=firefox.desktop\nx-scheme-handler/https=firefox.desktop\ntext/html=firefox.desktop\napplication/xhtml+xml=firefox.desktop\n"}]
dlive::check "  and the page says Firefox for the web" [expr {[dict get [defapps::model] subtitle] eq "Firefox for the web"}]
# Terminal: the list is Alacritty, Terminal; the first is picked
dlive::click 539 309
dlive::click 539 355
dlive::check "a click on Alacritty in Terminal's list writes it first in xdg-terminals.list" \
	[expr {[dlive::content xdg-terminals.list] eq "alacritty.desktop\n" && [dict get [dlive::row terminal] current] eq "alacritty.desktop"}]
# a change made by another program while the page is shown
set f [open [file join $::env(XDG_CONFIG_HOME) mimeapps.list] w]; puts $f "\[Default Applications\]\nx-scheme-handler/http=chromium.desktop"; close $f
set t0 [clock milliseconds]
while {$dlive::redraws == 0 && [clock milliseconds] - $t0 < 8000} { after 50; update }
dlive::check "a default changed by another program is drawn within the watch's two seconds ([expr {[clock milliseconds] - $t0}] ms)" \
	[expr {$dlive::redraws > 0 && [dict get [defapps::model] subtitle] eq "Chromium for the web"}]
# a config folder that cannot be written: the row stays, the page still draws
set ::env(XDG_CONFIG_HOME) [file join $::env(XDG_CONFIG_HOME) mimeapps.list under-a-file]
dlive::click 539 165
dlive::click 539 247
page::draw_now; update
dlive::check "with a config folder that cannot be written a choice changes nothing and the page still draws ($defapps::error)" \
	[expr {$defapps::error ne "" && [dict get [dlive::row web] current] ne "firefox.desktop"}]

if {[info exists ::env(RIBBON_DEFAULTS_RESULT)]} { set f [open $::env(RIBBON_DEFAULTS_RESULT) w]; puts $f [join $dlive::lines \n]; close $f } else { puts [join $dlive::lines \n] }
exit [expr {$dlive::fails > 0}]
