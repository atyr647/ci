# settings-defaults-scene.tcl - Settings → Default apps (page-defaults.tcl) in its board's state (Settings-A8-Default-Apps),
# with defaults.tcl's model stood in for (the page's drawing and its hits are what is checked here; defaults.tcl itself is
# tests/settings-defaults.tcl). Sourced by apps/settings/main.tcl through RIBBON_SETTINGS_SCENE.
#   RIBBON_DEFAULTS_SHOT   = file: a grab of the window (ImageMagick import); FILE.open.png is the Web list open
#   RIBBON_DEFAULTS_RESULT = file: the checks, one per line ("ok ..." or "FAIL ...")
proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }
set ui::caretfix off
namespace eval dscene { variable fails 0; variable lines {}; variable calls {}; variable refuse 0; variable watch {} }
proc dscene::check {what cond} { variable fails; variable lines; if {[uplevel #0 [list expr $cond]]} { lappend lines "ok   $what" } else { lappend lines "FAIL $what"; incr fails } }
proc dscene::click {x y} { page::draw_now; ui::press [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; ui::release [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; update }

# the board's rows: id, label, group, icon, the app in use, the apps offered
set dscene::rows {
	web      Web               opens globe    firefox  {chromium Chromium firefox Firefox}
	mail     Mail              opens file     mail     {mail Mail thunderbird Thunderbird}
	files    Files             opens folder   files    {files Files thunar Thunar}
	terminal Terminal          opens terminal terminal {alacritty Alacritty foot Foot terminal Terminal}
	text     Text              opens edit     editor   {writer {LibreOffice Writer} editor {Text editor}}
	pictures Pictures          opens image    viewer   {gimp {GNU Image Manipulation Program} viewer {Image viewer}}
	music    Music             media music    {}       {}
	video    Video             media film     {}       {}
	pdf      {Documents (PDF)} media file     firefox  {firefox Firefox zathura Zathura}
	archives Archives          media box      files    {files Files}
}
proc dscene::name {row app} { foreach {r - - - - items} $::dscene::rows { if {$r eq $row} { return [dict get $items $app] } } }
proc defapps::model {} {
	set rows {}
	set web "No web browser"
	foreach {id label group icon cur apps} $::dscene::rows {
		set items {}
		foreach {a n} $apps { lappend items [list $a.desktop $n] }
		if {$cur eq ""} { set items [linsert $items 0 [list "" "Not set"]] } else { set cur $cur.desktop }
		if {$id eq "web" && $cur ne ""} { set web "[dict get $apps [file rootname $cur]] for the web" }
		lappend rows [dict create id $id label $label group $group icon $icon current $cur items $items]
	}
	dict create subtitle $web rows $rows
}
proc defapps::refresh {{force 0}} { return 0 }
proc defapps::start {cb {while ""}} { set ::dscene::watch [list $cb $while] }
proc defapps::stop {} {}
proc defapps::choose {row app} {
	lappend ::dscene::calls [list $row $app]
	if {$::dscene::refuse} { return 0 }
	set out {}
	foreach {id label group icon cur apps} $::dscene::rows {
		if {$id eq $row} { set cur [file rootname $app] }
		lappend out $id $label $group $icon $cur $apps
	}
	set ::dscene::rows $out
	return 1
}
proc dscene::shown {row} { foreach r [dict get [defapps::model] rows] { if {[dict get $r id] eq $row} { return [dict get $r current] } } }

settings::select defaults
page::draw_now
update
if {[info exists ::env(RIBBON_DEFAULTS_SHOT)]} { after 500; update; exec import -window [winfo id $::settings::win] $::env(RIBBON_DEFAULTS_SHOT) }
dscene::check "the page is registered with the board's ten rows for search" \
	{[settings::get defaults rows] eq {{Opens with} Web Mail Files Terminal Text Pictures Media Music Video {Documents (PDF)} Archives}}
dscene::check "the page watches for changes made elsewhere while it is the one shown" \
	{[lindex $dscene::watch 0] eq "defp::changed" && [uplevel #0 [lindex $dscene::watch 1]]}

# every row's dropdown, as clicks: the dropdown is 220 wide at 429 (840 on the right), 32 tall, 8 under its row's
# top; its list opens 6 under it, the items 36 apart. For each row: the list opens, a click outside closes it and
# chooses nothing, then the other app is picked.
#   row       x    y(row top)  item to pick (0-based)  the call it must make
foreach {row x y pick want} {
	web      539 141 0 chromium.desktop
	mail     539 189 1 thunderbird.desktop
	files    539 237 1 thunar.desktop
	terminal 539 285 0 alacritty.desktop
	text     539 333 0 writer.desktop
	pictures 539 381 0 gimp.desktop
	pdf      950 237 1 zathura.desktop
} {
	set n [llength $dscene::calls]
	dscene::click $x [expr {$y + 24}]
	dscene::check "$row: a click on the dropdown opens its list" "\$sctl::pop eq {def-$row}"
	if {$row eq "web" && [info exists ::env(RIBBON_DEFAULTS_SHOT)]} { page::draw_now; update; after 300; update; exec import -window [winfo id $::settings::win] $::env(RIBBON_DEFAULTS_SHOT).open.png }
	dscene::click 700 650
	dscene::check "  a click outside closes it and chooses nothing" "\$sctl::pop eq {} && \[llength \$dscene::calls\] == $n"
	dscene::click $x [expr {$y + 24}]
	dscene::click $x [expr {$y + 70 + 36 * $pick}]
	dscene::check "  a click on [dscene::name $row [file rootname $want]] calls defapps::choose $row $want, and the row shows it" \
		"\[lindex \$dscene::calls end\] eq {$row $want} && \[llength \$dscene::calls\] == $n + 1 && \$sctl::pop eq {} && \[dscene::shown $row\] eq {$want}"
}
dscene::check "the subtitle follows the web's app" {[dict get [defapps::model] subtitle] eq "Chromium for the web"}
# Archives has one app: picking the one in use writes it again and nothing else
set n [llength $dscene::calls]
dscene::click 950 309
dscene::click 950 355
dscene::check "archives: its one app is picked" {[lindex $dscene::calls end] eq {archives files.desktop} && [llength $dscene::calls] == $n + 1}
# Not set rows: the list has the one item, and picking it calls nothing
foreach {row y} {music 141 video 189} {
	set n [llength $dscene::calls]
	dscene::click 950 [expr {$y + 24}]
	dscene::check "$row (Not set): its list opens" "\$sctl::pop eq {def-$row}"
	dscene::click 950 [expr {$y + 70}]
	dscene::check "  picking Not set chooses nothing and closes the list" "\$sctl::pop eq {} && \[llength \$dscene::calls\] == $n"
}
# the keyboard in an open list: a typed letter jumps, Return picks, Escape closes
dscene::click 539 309
settings::key f f 0
settings::key Return "" 0
dscene::check "terminal: typing f then Return picks Foot" {[lindex $dscene::calls end] eq {terminal foot.desktop} && $sctl::pop eq ""}
dscene::click 539 165
settings::key Escape "" 0
dscene::check "Escape closes an open list" {$sctl::pop eq ""}
# a choice that cannot be written: the row stays as it was
set dscene::refuse 1
dscene::click 539 165
dscene::click 539 247
dscene::check "a refused choice (firefox) is asked for and the row stays as it was (Chromium)" \
	{[lindex $dscene::calls end] eq {web firefox.desktop} && [dscene::shown web] eq "chromium.desktop" && $sctl::pop eq ""}
set dscene::refuse 0
# nothing installed at all, and names too long for the dropdown
set dscene::rows [lmap {id label group icon cur apps} $dscene::rows { list $id $label $group $icon {} {} }]
set dscene::rows [concat {*}$dscene::rows]
page::draw_now; update
dscene::check "the page draws with no app for any row (No web browser)" {[dict get [defapps::model] subtitle] eq "No web browser"}
set dscene::rows [lreplace $dscene::rows 4 5 long {long {An application with a name much too long for the dropdown it is shown in}}]
page::draw_now; update
dscene::check "a long name is cut to the dropdown" {[string match *… [sctl::clip {An application with a name much too long for the dropdown it is shown in} 156]]}
# leaving the page: the list does not stay open, and the watch says it is not needed
dscene::click 539 165
settings::select sound
dscene::check "leaving the page closes its list; the watch ends" {$sctl::pop eq "" && ![uplevel #0 [lindex $dscene::watch 1]]}

if {[info exists ::env(RIBBON_DEFAULTS_RESULT)]} { set f [open $::env(RIBBON_DEFAULTS_RESULT) w]; puts $f [join $dscene::lines \n]; close $f } else { puts [join $dscene::lines \n] }
exit [expr {$dscene::fails > 0}]
