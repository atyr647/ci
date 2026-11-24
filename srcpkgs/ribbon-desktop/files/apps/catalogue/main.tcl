# main.tcl - the Catalogue: find and install apps from Ribbon's kits and from Flathub, in Tcl/Tk,
# drawn as its boards (design/mockups/Catalogue-1..8).
#
#   ribbon-catalogue                 every app (Catalogue-1-Browse)
#   ribbon-catalogue FILE.flatpakref that app's page (Catalogue-8-Flatpakref); Files opens .flatpakref
#                                    files here (application/vnd.flatpak.ref)
#
# The window is Properties' (properties/widgets.tcl and perms.tcl, the Appearance app's drawing and
# dialogs, the shell's rasteriser, palette and text), in the active theme's colours. What it shows
# and does is source.tcl's: kit's own library through kitq.tcl, and the flatpak command.
#
# Tests: RIBBON_CATALOGUE_SCENE=tests/catalogue-scene.tcl puts it into a board's state on a
# 1440 x 900 desktop; tests/catalogue-flow.tcl drives it.

if {$tcl_platform(platform) eq "unix"} { encoding system utf-8 }
set appdir [file dirname [file normalize [info script]]]
proc find_dir {name file} {
	foreach d [list [file join [file dirname [file dirname $::appdir]] $name] [file join [file dirname $::appdir] $name] /usr/lib/ribbon/$name] {
		if {[file exists [file join $d $file]]} { return $d }
	}
	puts stderr "catalogue: $name/$file was not found"; exit 1
}
set shelldir [expr {[info exists env(RIBBON_SHELL_DIR)] ? $env(RIBBON_SHELL_DIR) : [find_dir shell raster.tcl]}]
set appearancedir [find_dir appearance ui.tcl]
set propertiesdir [find_dir properties widgets.tcl]
foreach d [list /usr/lib/ribbon [file dirname $shelldir]] { if {$d ni $auto_path} { lappend auto_path $d } }
package require rbnalpha
foreach f {text raster wall theme} { source -encoding utf-8 [file join $shelldir $f.tcl] }
namespace eval page {}
foreach f {ui dialogs} { source -encoding utf-8 [file join $appearancedir $f.tcl] }
foreach f {widgets perms} { source -encoding utf-8 [file join $propertiesdir $f.tcl] }
foreach f {source page} { source -encoding utf-8 [file join $appdir $f.tcl] }

namespace eval app { variable win .w }

proc page::changed {} {
	page::job_ended
	page::draw
}

proc app::main {} {
	variable win
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}]
	set cache [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$home/.cache"}]
	theme::load
	raster::init [file join $cache ribbon catalogue]
	set ui::fonts(sg20) {{Ribbon Space Grotesk 600} 20 0.984 0.292}
	ui::fonts
	page::chrome
	set scene [info exists ::env(RIBBON_CATALOGUE_SCENE)]
	set ref ""
	foreach a $::argv {
		if {$a eq "--"} continue
		if {[string match -* $a]} { puts stderr "usage: ribbon-catalogue \[FILE.flatpakref\]"; exit 2 }
		set ref [file normalize $a]
	}
	wm withdraw .
	if {$scene} {
		toplevel $win -class RibbonCatalogue -borderwidth 0 -highlightthickness 0
		wm overrideredirect $win 1
		wm geometry $win 1440x900+0+0
		set ui::ox 170; set ui::oy 104
		set ui::behind [ui::desktop 1440 900]
		set ui::bx 170; set ui::by 104
		canvas $win.c -width 1440 -height 900 -highlightthickness 0 -borderwidth 0 -background $ui::c(bar)
		$win.c create image 0 0 -image $ui::behind -anchor nw -tags desk
	} else {
		if {[rbn::appwindow $win RibbonCatalogue 1100 720 -fill $ui::c(bar)]} { set ui::argbwin $win }
		wm title $win Catalogue
		wm iconname $win Catalogue
		wm resizable $win 0 0
		set SW [winfo screenwidth .]; set SH [winfo screenheight .]
		wm geometry $win 1100x720+[expr {max(0, ($SW - 1100) / 2)}]+[expr {max(0, ($SH - 720) / 2 + 14)}]
		wm protocol $win WM_DELETE_WINDOW page::quit
		set ui::behind ""
		set ui::bx 0; set ui::by 0
	}
	pack $win.c
	set ui::cv $win.c
	bind $win.c <ButtonPress-1> {ui::press %x %y}
	bind $win.c <B1-Motion> {ui::motion %x %y}
	bind $win.c <ButtonRelease-1> {ui::release %x %y}
	bind $win.c <Button-4> {ui::scroll %x %y -1}
	bind $win.c <Button-5> {ui::scroll %x %y 1}
	bind $win.c <MouseWheel> {ui::scroll %x %y [expr {%D > 0 ? -1 : 1}]}
	bind $win <KeyPress> {page::key %K %A %s}
	set cat::changed page::changed
	if {$scene} {
		uplevel #0 [list source -encoding utf-8 $::env(RIBBON_CATALOGUE_SCENE)]
	} else {
		cat::load_kits
		cat::load_flat
		if {$ref ne ""} {
			if {[catch {cat::open_ref $ref} err]} {
				dlg::message "Couldn't open it" "[file tail $ref]: $err"
			} else { set page::nav flathub; set page::view app }
		}
		page::draw
		page::watch_theme
	}
	if {!$scene && [info exists ::env(RIBBON_CATALOGUE_PROBE)]} { after idle [list uplevel #0 [list source -encoding utf-8 $::env(RIBBON_CATALOGUE_PROBE)]] }
	focus -force $win
	ui::blink
}

app::main
