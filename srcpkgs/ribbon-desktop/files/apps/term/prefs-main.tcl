# prefs-main.tcl - ribbon-term-prefs: Ribbon Terminal's preferences tab (prefs.tcl). One per terminal window: a second
# request for the same group raises the one there.
#   ribbon-term-prefs GROUP
if {$tcl_platform(platform) eq "unix"} { encoding system utf-8 }
set appdir [file dirname [file normalize [info script]]]
proc find_dir {name file} {
	foreach d [list [file join [file dirname $::appdir] $name] [file join [file dirname [file dirname $::appdir]] $name] /usr/lib/ribbon/$name] {
		if {[file exists [file join $d $file]]} { return $d }
	}
	puts stderr "ribbon-term-prefs: $name/$file was not found"; exit 1
}
set shelldir [expr {[info exists env(RIBBON_SHELL_DIR)] ? $env(RIBBON_SHELL_DIR) : [find_dir shell raster.tcl]}]
set appearancedir [find_dir appearance ui.tcl]
set propsdir [find_dir properties widgets.tcl]
foreach f {text raster wall theme} { source -encoding utf-8 [file join $shelldir $f.tcl] }
source -encoding utf-8 [file join $appearancedir ui.tcl]
source -encoding utf-8 [file join $propsdir widgets.tcl]
foreach f {profiles prefs} { source -encoding utf-8 [file join $appdir $f.tcl] }

proc tp::palette {} {
	array set p [array get theme::c]
	ui::colours [dict create BAR $p(BAR) FIELD $p(FIELD) PILL $p(PILL) BORDER $p(BORDER) FG $p(FG) MUTED $p(MUTED) \
		ACCENT $p(ACCENT) ON_ACCENT $p(ON_ACCENT) DESK_TOP $p(DESK_TOP) DESK_BOTTOM $p(DESK_BOTTOM) \
		DESK_STRIPE $p(DESK_STRIPE) DESK_STRIPE_ALPHA $p(DESK_STRIPE_ALPHA)]
}

proc tp::main {} {
	variable win
	variable scene
	variable group
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}]
	set cache [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$home/.cache"}]
	theme::load
	raster::init [file join $cache ribbon term-prefs]
	ui::fonts
	tp::palette
	set scene [info exists ::env(RIBBON_TERM_PREFS_SCENE)]
	set group [lindex $::argv 0]
	if {!$scene && ![regexp {^[a-z][a-z0-9]*$} $group]} { puts stderr "usage: ribbon-term-prefs GROUP"; exit 2 }
	wm withdraw .
	if {!$scene} {
		set app ribbon-term-prefs-$group
		if {[lsearch -exact [winfo interps] $app] >= 0} { catch {send $app tp::show}; exit 0 }
		tk appname $app
	}
	set W 1240; set H 742
	if {$scene} {
		toplevel $win -class RibbonTermPrefs -borderwidth 0 -highlightthickness 0
		wm overrideredirect $win 1
	} else {
		# the class is the app-id the terminal module takes into the group's tabs (ribbon-term-GROUP-prefs)
		toplevel $win -class ribbon-term-$group-prefs -borderwidth 0 -highlightthickness 0 -background $ui::c(bar)
		wm title $win Preferences
		wm protocol $win WM_DELETE_WINDOW page::quit
		set W 1100; set H 638
	}
	wm geometry $win ${W}x$H
	set ui::W $W; set ui::H $H
	set ui::ox 0; set ui::oy 0; set ui::behind ""; set ui::bx 0; set ui::by 0
	canvas $win.c -width $W -height $H -highlightthickness 0 -borderwidth 0 -background $ui::c(bar)
	pack $win.c -fill both -expand 1
	set ui::cv $win.c
	bind $win.c <ButtonPress-1> {ui::press %x %y}
	bind $win.c <B1-Motion> {ui::motion %x %y}
	bind $win.c <Motion> {page::menu_motion %x %y}
	bind $win.c <ButtonRelease-1> {ui::release %x %y}
	bind $win.c <Configure> {tp::resized %w %h}
	bind $win <KeyPress> {tp::key %K %A %s}
	if {$scene} { uplevel #0 [list source -encoding utf-8 $::env(RIBBON_TERM_PREFS_SCENE)] }
	page::draw
	focus -force $win
	ui::blink
	# the theme or another window's change: the page follows the file
	if {!$scene} { tp::watch }
}
proc tp::resized {w h} {
	if {$w < 600 || $h < 400 || ($w == $ui::W && $h == $ui::H)} return
	set ui::W $w; set ui::H $h
	page::draw
}
proc tp::show {} {
	variable win
	wm deiconify $win
	raise $win
	catch {exec ribbon-term-ctl show-prefs $::tp::group &}
}
# Every 2 s: terminal.conf written elsewhere (another group's preferences), or a new theme, redraws the page.
proc tp::watch {} {
	variable seen
	set sig {}
	foreach f [list [prof::conffile] [file join [prof::confdir] ribbon palette.conf]] { lappend sig [expr {[catch {file mtime $f} m] ? 0 : $m}] }
	if {[info exists seen] && $sig ne $seen && !$::tp::naming} {
		if {[lindex $sig 1] ne [lindex $seen 1]} { theme::load; tp::palette }
		prof::load
		page::draw
	}
	set seen $sig
	after 2000 tp::watch
}
tp::main
