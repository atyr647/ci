# main.tcl - Properties: an app's kit, a file or a folder, in Tcl/Tk,
# drawn as its approved mockups (design/mockups/Props-A*.dc.html, direction
# A, "Rail").
#
#   ribbon-properties PATH...              files or folders: the standalone window (win2.tcl), one per set of items;
#                                          a .kit: the Rail
#   ribbon-properties --app DESKTOP-ID     an app of the launcher or the dock
#   ribbon-properties --kit NAME           an installed kit
#   ... --page overview|permissions|storage|libraries|signature|general|photo|contents
#   ... --beside X Y W H | --over X Y W H   where a file window opens: beside that rectangle (a
#                                          tile; the pointer with W = H = 0) or centred on it (the
#                                          window that asked); root coordinates
#
# The window is the Appearance app's: its drawing (appearance/ui.tcl) and
# dialogs (appearance/dialogs.tcl) on the shell's rasteriser, palette and
# text code (shell/raster.tcl, theme.tcl, wall.tcl, text.tcl), in the
# colours of the active theme. App facts, Update, Repair, Uninstall and the
# permissions you grant come from kit's own library, through kitlink.tcl.
#
# Tests: RIBBON_PROPERTIES_SCENE=tests/properties-scene.tcl puts it into one
# of the boards' states on a 1440 x 900 desktop; tests/properties-flow.tcl
# drives it.

# file names are UTF-8 whatever the locale says
if {$tcl_platform(platform) eq "unix"} { encoding system utf-8 }
set appdir [file dirname [file normalize [info script]]]
proc find_dir {name file} {
	foreach d [list [file join [file dirname $::appdir] $name] /usr/lib/ribbon/$name] {
		if {[file exists [file join $d $file]]} { return $d }
	}
	puts stderr "properties: $name/$file was not found"; exit 1
}
set shelldir [expr {[info exists env(RIBBON_SHELL_DIR)] ? $env(RIBBON_SHELL_DIR) : [find_dir shell raster.tcl]}]
set appearancedir [find_dir appearance ui.tcl]
# text.tcl first: it sets up the fonts' weights before Tk opens a font
# rbnalpha (next to the shell: /usr/lib/ribbon/rbnalpha): see-through
# window corners, and raster.tcl's pixels in C
foreach d [list /usr/lib/ribbon [file dirname $shelldir]] { if {$d ni $auto_path} { lappend auto_path $d } }
package require rbnalpha
foreach f {text raster wall theme} { source -encoding utf-8 [file join $shelldir $f.tcl] }
# the Appearance app's window, controls, dialogs and thumbnails (bg::picture)
namespace eval page {}
foreach f {ui dialogs bgpages} { source -encoding utf-8 [file join $appearancedir $f.tcl] }
foreach f {kitlink facts perms widgets pages apppages jobs openwith filepages inspector win2} { source -encoding utf-8 [file join $appdir $f.tcl] }

namespace eval app {
	variable win .w
	variable scene 0
}

proc app::usage {} {
	puts stderr "usage: ribbon-properties PATH... | --app DESKTOP-ID | --kit NAME  \[--page PAGE\]"
	exit 2
}

proc app::main {} {
	variable win
	variable scene
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}]
	set cache [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$home/.cache"}]
	theme::load
	raster::init [file join $cache ribbon properties]
	set ui::fonts(sg20) {{Ribbon Space Grotesk 600} 20 0.984 0.292}
	set ui::fonts(sg34) {{Ribbon Space Grotesk 600} 34 0.984 0.292}
	ui::fonts
	page::chrome
	set scene [info exists ::env(RIBBON_PROPERTIES_SCENE)]
	# the arguments first: the window's size depends on what is asked for
	set what ""; set kind path; set pg ""; set paths {}; set place {}
	for {set i 0} {$i < [llength $::argv]} {incr i} {
		set a [lindex $::argv $i]
		switch -- $a {
			-- { }
			--app { set kind app; set what [lindex $::argv [incr i]] }
			--kit { set kind kit; set what [lindex $::argv [incr i]] }
			--page { set pg [lindex $::argv [incr i]] }
			--beside - --over {
				# where the file window opens (win2::place): four whole numbers, root coordinates
				set r [lrange $::argv [expr {$i + 1}] [expr {$i + 4}]]
				incr i 4
				if {[llength $r] == 4 && [llength [lmap n $r { if {![string is integer -strict $n]} continue; set n }]] == 4} {
					set place [list [string range $a 2 end] {*}$r]
				}
			}
			default { lappend paths $a }
		}
	}
	if {$kind eq "path"} {
		if {![llength $paths] && !$scene} usage
		set paths [lmap p $paths { file normalize $p }]
		set what [lindex $paths 0]
	} elseif {$what eq "" && !$scene} usage
	# files and folders are the standalone window (FileProps-Win2-Split); apps and kits keep the Rail
	set winmode 0
	if {!$scene && $kind eq "path"} {
		set winmode 1
		foreach p $paths { if {![win2::for $p]} { set winmode 0 } }
	}
	wm withdraw .
	set SW [winfo screenwidth .]; set SH [winfo screenheight .]
	# an app or a kit first: its window's height depends on what it is (page::WH)
	if {!$scene && !$winmode} {
		if {[catch {page::open $kind $what} err]} {
			puts stderr "properties: $err"
			exit 1
		}
	}
	if {$winmode} {
		# one window per set of items: a second request raises the one that is open
		if {[win2::forward $paths]} { exit 0 }
	}
	if {$scene} {
		toplevel $win -class RibbonProperties -borderwidth 0 -highlightthickness 0
		wm overrideredirect $win 1
		wm geometry $win 1440x900+0+0
		set ui::ox 170; set ui::oy 104
		set ui::behind [ui::desktop 1440 900]
		set ui::bx 170; set ui::by 104
		canvas $win.c -width 1440 -height 900 -highlightthickness 0 -borderwidth 0 -background $ui::c(bar)
		$win.c create image 0 0 -image $ui::behind -anchor nw -tags desk
	} else {
		set WW [expr {$winmode ? $::win2::W : 1100}]
		set HH [expr {$winmode ? $::win2::H : $::page::WH}]
		# labwc frames it (title bar, buttons) unless RIBBON_OWN_FRAME=1 (rbn::framed)
		if {[rbn::appwindow $win RibbonProperties $WW $HH -fill $ui::c(bar)]} { set ui::argbwin $win }
		wm title $win Properties
		wm iconname $win Properties
		wm resizable $win 0 0
		if {!$winmode} {
			set x [expr {max(0, ($SW - 1100) / 2)}]; set y [expr {max(0, ($SH - $HH) / 2 + 14)}]
			wm geometry $win 1100x$HH+$x+$y
		}
		wm protocol $win WM_DELETE_WINDOW page::quit
		set ui::behind ""
		set ui::bx 0; set ui::by 0
	}
	pack $win.c
	set ui::cv $win.c
	bind $win.c <ButtonPress-1> {ui::press %x %y}
	bind $win.c <B1-Motion> {ui::motion %x %y}
	bind $win.c <Motion> {page::menu_motion %x %y}
	bind $win.c <ButtonRelease-1> {ui::release %x %y}
	bind $win.c <Button-4> {ui::scroll %x %y -1}
	bind $win.c <Button-5> {ui::scroll %x %y 1}
	bind $win.c <MouseWheel> {ui::scroll %x %y [expr {%D > 0 ? -1 : 1}]}
	bind $win <KeyPress> {page::key %K %A %s}
	if {$scene} {
		uplevel #0 [list source -encoding utf-8 $::env(RIBBON_PROPERTIES_SCENE)]
	} elseif {$winmode} {
		win2::open $paths $win 0 $place
	} else {
		if {$pg ne ""} { page::go $pg }
		page::draw
		page::watch_theme
	}
	# tests: a script run in the real window (tests/win2-probe.tcl)
	if {!$scene && [info exists ::env(RIBBON_PROPERTIES_PROBE)]} { after idle [list uplevel #0 [list source -encoding utf-8 $::env(RIBBON_PROPERTIES_PROBE)]] }
	focus -force $win
	ui::blink
}

app::main
