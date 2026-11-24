# main.tcl - Appearance: Ribbon's theme, colours, desktop background and
# login screen, in Tcl/Tk, drawn as its approved mockups
# (design/mockups/Appear-*.dc.html).
#
#   wish /usr/lib/ribbon/appearance/main.tcl ?--page theme|colours|desktop|login?
#   (ribbon-appearance; "ribbon-theme pick" opens it too)
#
# It draws with the Ribbon shell's own rasteriser and palette code
# (raster.tcl, theme.tcl, wall.tcl from /usr/lib/ribbon/shell) and places
# its text with the shell's text.tcl, as the installer and the login screen
# do. Applying goes through ribbon-theme
# (the desktop) and, for the login screen, its privileged helper.
#
# Tests: RIBBON_APPEARANCE_SCENE=tests/appearance-scene.tcl puts it into one
# of the mockups' states on a 1440 x 900 desktop (see that file).

set appdir [file dirname [file normalize [info script]]]
proc find_dir {name file} {
	foreach d [list [file join [file dirname $::appdir] $name] /usr/lib/ribbon/$name] {
		if {[file exists [file join $d $file]]} { return $d }
	}
	puts stderr "appearance: $name/$file was not found"; exit 1
}
set shelldir [expr {[info exists env(RIBBON_SHELL_DIR)] ? $env(RIBBON_SHELL_DIR) : [find_dir shell raster.tcl]}]
# text.tcl first: it sets up the fonts' weights before Tk opens a font
# rbnalpha (next to the shell: /usr/lib/ribbon/rbnalpha): see-through
# window corners, and raster.tcl's pixels in C
foreach d [list /usr/lib/ribbon [file dirname $shelldir]] { if {$d ni $auto_path} { lappend auto_path $d } }
package require rbnalpha
foreach f {text raster wall theme} { source -encoding utf-8 [file join $shelldir $f.tcl] }
foreach f {palette store ui thumbs pages bgpages dialogs preview onstage} { source -encoding utf-8 [file join $appdir $f.tcl] }

namespace eval app {
	variable win .w
	variable scene 0
	variable oy 104
}

# The options a caller passes (ribbon-appearance; the viewer's Set as wallpaper), read here
# by app::main and, hosted, by Settings:
#   --page P       the page (Settings takes each --page in turn)
#   --picture FILE with --page desktop: FILE is added to Pictures and chosen
#   --back LABEL   the picker's back button reads LABEL, and back closes the window
proc app::argv_value {opt} {
	set i [lsearch -exact $::argv $opt]
	if {$i < 0 || $i + 1 >= [llength $::argv]} { return "" }
	return [lindex $::argv [expr {$i + 1}]]
}

proc app::argv_pick {} {
	set f [app::argv_value --picture]
	if {$f eq "" || [lsearch -exact $::argv desktop] < 0} return
	after idle [list apply {{f} { set f [file normalize $f]; if {$f ni $os::pictures} { lappend os::pictures $f; os::list_write pictures.list $os::pictures }; set os::S(tab) pictures; os::choose_picture $f }} $f]
}

proc app::argv_back {} {
	set b [app::argv_value --back]
	if {$b eq ""} return
	set os::back_label $b
	set os::back_quit 1
}

proc app::main {} {
	variable win
	variable scene
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}]
	set cache [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$home/.cache"}]
	theme::load
	raster::init [file join $cache ribbon appearance]
	ui::fonts
	page::init
	set scene [info exists ::env(RIBBON_APPEARANCE_SCENE)]
	wm withdraw .
	set SW [winfo screenwidth .]; set SH [winfo screenheight .]
	if {$scene} {
		# the whole desktop as the mockups show it: wallpaper, shade, the
		# quiet bars, and the window's shadow
		toplevel $win -class RibbonAppearance -borderwidth 0 -highlightthickness 0
		wm overrideredirect $win 1
		wm geometry $win 1440x900+0+0
		set ui::ox 170; set ui::oy 104
		set ui::behind [desktop 1440 900]
		set ui::bx 170; set ui::by 104
		canvas $win.c -width 1440 -height 900 -highlightthickness 0 -borderwidth 0 -background $ui::c(bar)
		$win.c create image 0 0 -image $ui::behind -anchor nw -tags desk
	} else {
		# a managed window: labwc frames it (title bar, buttons) unless RIBBON_OWN_FRAME=1 (rbn::framed)
		if {[rbn::appwindow $win RibbonAppearance 1100 720 -fill $ui::c(bar)]} { set ui::argbwin $win }
		wm title $win Appearance
		wm iconname $win Appearance
		wm resizable $win 0 0
		set x [expr {max(0, ($SW - 1100) / 2)}]; set y [expr {max(0, ($SH - 720) / 2 + 14)}]
		wm geometry $win 1100x720+$x+$y
		wm protocol $win WM_DELETE_WINDOW page::quit
		set ui::behind ""
		set ui::bx 0; set ui::by 0
	}
	pack $win.c
	set ui::cv $win.c
	bind $win.c <ButtonPress-1> {ui::press %x %y}
	bind $win.c <Double-ButtonPress-1> {page::double %x %y}
	bind $win.c <B1-Motion> {ui::motion %x %y}
	bind $win.c <ButtonRelease-1> {ui::release %x %y}
	bind $win.c <Button-4> {ui::scroll %x %y -1}
	bind $win.c <Button-5> {ui::scroll %x %y 1}
	bind $win.c <MouseWheel> {ui::scroll %x %y [expr {%D > 0 ? -1 : 1}]}
	bind $win <KeyPress> {page::key %K %A %s}
	if {$scene} {
		uplevel #0 [list source -encoding utf-8 $::env(RIBBON_APPEARANCE_SCENE)]
	} else {
		app::argv_back
		set i [lsearch -exact $::argv --page]
		if {$i >= 0} { page::go [lindex $::argv [expr {$i + 1}]] }
		app::argv_pick
		page::draw
		page::tick
		after 1500 { after idle os::prewarm_shapes }
	}
	focus -force $win
	ui::blink
}

# The scene's desktop (ui::desktop, shared with Properties).
proc app::desktop {W H} { ui::desktop $W $H }

# Settings sources this file with app::hosted set: it draws its own window (apps/settings/main.tcl)
if {![info exists ::app::hosted]} { app::main }
