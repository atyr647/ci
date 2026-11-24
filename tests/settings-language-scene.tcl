# settings-language-scene.tcl - Settings → Language and region (page-language.tcl) in its board's state
# (Settings-A13-Language-Region) with the REAL locale.tcl: its `locale` is the step's stand-in (glibc's data for
# en_GB, en_US and de_DE from tests/fixtures/locale), its file the step's own XDG_CONFIG_HOME/locale.conf. The page is
# grabbed for the board, then its dropdowns are used as a person would (clicks, keys) and the file is read back.
# Sourced by apps/settings/main.tcl through RIBBON_SETTINGS_SCENE.
#   RIBBON_LANG_SHOT   = file: a grab of the window (ImageMagick import)
#   RIBBON_LANG_RESULT = file: the checks, one per line ("ok ..." or "FAIL ...")
proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }
set ui::caretfix off
namespace eval lscene { variable fails 0; variable lines {} }
proc lscene::check {what cond} { variable fails; variable lines; if {[uplevel #0 [list expr $cond]]} { lappend lines "ok   $what" } else { lappend lines "FAIL $what"; incr fails } }
proc lscene::click {x y} { page::draw_now; ui::press [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; ui::release [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; update; page::draw_now; update }
proc lscene::key {sym {char ""}} { page::draw_now; settings::key $sym $char 0; update; page::draw_now; update }
proc lscene::conf {} { set f [::file join $::env(XDG_CONFIG_HOME) locale.conf]; if {[catch {open $f} h]} { return "" }; set t [read $h]; close $h; set t }

# the rail item: registry.tcl's, after Date and time in the last group
lscene::check "the rail lists Language and region after Date and time, before About" \
	{[lrange [settings::ids] 13 15] eq {datetime language about}}
lscene::check "the page registers itself on the rail item (title, icon, its rows for search)" \
	{[settings::get language draw] eq "settings::draw_language" && [settings::get language icon] eq "lang" && "Formats" in [settings::get language rows]}
settings::select language
page::draw_now
update
lscene::check "the board's state: English (United Kingdom), United Kingdom, from the system's locale.conf" \
	{[loc::language] eq "en_GB.UTF-8" && [loc::formats] eq "en_GB.UTF-8" && [lscene::conf] eq ""}
if {[info exists ::env(RIBBON_LANG_SHOT)]} { after 500; update; exec import -window [winfo id $::settings::win] $::env(RIBBON_LANG_SHOT) }

# Language: a click opens the list on the language in use; a click on Deutsch picks it
lscene::click 539 165
lscene::check "a click on Language opens its list, on the language in use" \
	{$sctl::pop eq "lg-language" && [lindex [dict get $sctl::popd items] [dict get $sctl::popd idx] 0] eq "en_GB.UTF-8"}
lscene::key Up
lscene::key Up
lscene::key Return
lscene::check "  Up twice (past English (Canada)) and Return pick Deutsch: LANG=de_DE.UTF-8 in locale.conf" {[lscene::conf] eq "LANG=de_DE.UTF-8\n" && $sctl::pop eq ""}
lscene::check "  the subtitle says from your next login" {[dict get [loc::model] subtitle] eq "Deutsch · Germany · from your next login"}
lscene::check "  and Shown as shows the German formats (they follow the language)" {[dict get [loc::model] examples date] eq "Samstag, 7. November 2026"}
# Formats: picked by a click in the open list
lscene::click 539 213
lscene::check "a click on Formats opens its list" {$sctl::pop eq "lg-formats"}
set i [lsearch -index 0 [dict get $sctl::popd items] en_US.UTF-8]
set top [dict get $sctl::popd top]
# the list's rows (sctl::pop_draw): 36 apart from 6 inside a card 38 under the box's top (above it when it would not fit)
set shown [expr {min([llength [dict get $sctl::popd items]], $sctl::ROWS)}]
set ctop [expr {[dict get $sctl::popd y] + 38}]
if {$ctop + 12 + 36 * $shown > 708} { set ctop [expr {[dict get $sctl::popd y] - 6 - 12 - 36 * $shown}] }
set py [expr {$ctop + 6 + 36 * ($i - $top) + 18}]
lscene::click 539 $py
lscene::check "  a click on United States writes the five LC_ lines" \
	{[lscene::conf] eq "LANG=de_DE.UTF-8\nLC_TIME=en_US.UTF-8\nLC_NUMERIC=en_US.UTF-8\nLC_MONETARY=en_US.UTF-8\nLC_MEASUREMENT=en_US.UTF-8\nLC_PAPER=en_US.UTF-8\n"}
lscene::check "  Shown as is the American formats" {[dict get [loc::model] examples money] eq {$1,234.56} && [dict get [loc::model] examples measures] eq "US · Letter"}
# the keyboard: Tab reaches the dropdowns, Down on Language picks the next
set ui::focus ""
lscene::key Tab
lscene::check "Tab reaches Language first" {$ui::focus eq "lg-language"}
lscene::key Down
lscene::check "  Down picks the next language (English (Canada)): LANG changes, the formats stay" \
	{[string match "LANG=en_CA.UTF-8\nLC_TIME=en_US.UTF-8\n*" [lscene::conf]]}
lscene::key Tab
lscene::check "  Tab then Formats" {$ui::focus eq "lg-formats"}

if {[info exists ::env(RIBBON_LANG_RESULT)]} { set f [open $::env(RIBBON_LANG_RESULT) w]; puts $f [join $lscene::lines \n]; close $f } else { puts [join $lscene::lines \n] }
exit [expr {$lscene::fails > 0}]
