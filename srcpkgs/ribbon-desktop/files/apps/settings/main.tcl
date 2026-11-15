# main.tcl - Settings (ribbon-settings): the rail (Settings-A-Rail), search over
# the row labels, and the pages that register themselves (page-*.tcl, C4).
# Appearance is hosted: appearance/main.tcl is sourced with app::hosted set (so
# the Appearance window is not made), and its pages draw into this window, under
# the Settings rail in place of the Appearance rail.
#
#   ribbon-settings ?--page appearance|theme|colours|desktop|login? ?--picture FILE? ?--back LABEL?
#   RIBBON_SETTINGS_SCENE = file: a test scene (tests/settings-scene.tcl)
#
# One Settings window (C1): a second ribbon-settings hands its arguments to the one running, which shows the page
# asked for and comes to the front, and then exits. It reaches it through a unix socket in XDG_RUNTIME_DIR (one per
# display), or, without one, through Tk's send to the application named ribbon-settings.

namespace eval settings {
	variable sel appearance   ;# the rail item shown
	variable win .w
	variable scene 0
}
set ::settings::appdir [file dirname [file normalize [info script]]]

# The running instance's socket: $XDG_RUNTIME_DIR/ribbon-settings-DISPLAY.sock, "" without a runtime dir.
proc settings::sock_path {} {
	if {![info exists ::env(XDG_RUNTIME_DIR)] || $::env(XDG_RUNTIME_DIR) eq ""} { return "" }
	set d [expr {[info exists ::env(WAYLAND_DISPLAY)] && $::env(WAYLAND_DISPLAY) ne "" ? $::env(WAYLAND_DISPLAY)
		: ([info exists ::env(DISPLAY)] ? $::env(DISPLAY) : "")}]
	regsub -all {[^A-Za-z0-9._-]} $d _ d
	file join $::env(XDG_RUNTIME_DIR) ribbon-settings-$d.sock
}

# Hand ARGV to a running Settings: 1 when one took it.
proc settings::forward {argv} {
	set sp [settings::sock_path]
	if {$sp ne "" && [file exists $sp] && ![catch {package require unix_extra 0.3}]} {
		if {![catch {
			set ch [unix_extra::connect $sp]
			fconfigure $ch -encoding utf-8 -translation lf -buffering line
			puts $ch [list open $argv]
			set reply [gets $ch]
			close $ch
		}] && $reply eq "ok"} { return 1 }
	}
	set app ribbon-settings
	if {[tk appname] ne $app && $app in [winfo interps]} {
		if {![catch {send $app [list settings::remote $argv]} reply] && $reply eq "ok"} { return 1 }
	}
	return 0
}

# Be the running one: the application name ribbon-settings (for send) and the socket (a stale one is replaced).
proc settings::serve {} {
	if {[tk appname] ne "ribbon-settings"} { catch {tk appname ribbon-settings} }
	set sp [settings::sock_path]
	if {$sp eq "" || [catch {package require unix_extra 0.3}]} return
	catch {file delete $sp}
	if {[catch {unix_extra::listen $sp settings::accept} msg]} { puts stderr "ribbon-settings: $sp: $msg" }
}

proc settings::accept {ch args} {
	fconfigure $ch -encoding utf-8 -translation lf -blocking 0 -buffering line
	fileevent $ch readable [list settings::request $ch]
}

# A request from a second ribbon-settings: one line, {open ARGV}; the arguments are data, never run.
proc settings::request {ch} {
	if {[catch {gets $ch line} n] || $n < 0} {
		if {[catch {eof $ch} e] || $e} { catch {close $ch} }
		return
	}
	set reply error
	if {![catch {llength $line} k] && $k == 2 && [lindex $line 0] eq "open"} {
		if {![catch {settings::remote [lindex $line 1]} r]} { set reply $r }
	}
	catch {puts $ch $reply; flush $ch}
	catch {close $ch}
}

# The running Settings, asked again: the pages in ARGV as at the start, then its window to the front.
proc settings::remote {argv} {
	variable win
	set ::argv $argv
	# the background picker is open (the window stepped aside, the clicks go to its sheet): it closes as Back closes
	# it, what was not applied going back, before the page asked for is shown
	if {$::os::S(open)} {
		set ::os::back_quit 0
		os::back
	}
	# --back is the new caller's (or no one's): back closes the window only when it was given again
	set ::os::back_label Settings
	set ::os::back_quit 0
	app::argv_back
	foreach {opt val} $argv { if {$opt eq "--page"} { open_page $val } }
	app::argv_pick
	page::draw
	wm deiconify $win
	raise $win
	focus -force $win
	return ok
}

if {![info exists ::env(RIBBON_SETTINGS_SCENE)]} {
	wm withdraw .
	if {[settings::forward $::argv]} { exit 0 }
}

# A folder next to this one (the repo's files/, or the installed /usr/lib/ribbon).
proc settings::find {name file} {
	variable appdir
	foreach d [list [file join $appdir .. $name] [file join $appdir .. .. $name] /usr/lib/ribbon/$name] {
		if {[file exists [file join $d $file]]} { return [file normalize $d] }
	}
	puts stderr "ribbon-settings: $name/$file was not found"; exit 1
}

# Appearance's pages, drawn here: the same modules, no window of their own.
namespace eval ::app {
	variable win .w
	variable scene 0
	variable oy 104
}
set ::app::hosted 1
source -encoding utf-8 [file join [settings::find appearance main.tcl] main.tcl]

foreach f {registry rail search controls} { source -encoding utf-8 [file join $::settings::appdir $f.tcl] }

# Appearance's own keys, hosted: Alt+1..4 (its four pages), Ctrl+S (save the colours) and Escape (back to Theme) are Appearance's only on the
# Appearance page; Ctrl+Page Up and Ctrl+Page Down move through the Settings rail on every page (the rail Appearance
# had of its own is the Settings rail here). Everything else is page::key's as it was.
rename ::page::key ::page::appearance_key
proc ::page::key {sym char state} {
	set ctrl [expr {$state & 4}]
	set alt [expr {$state & 8}]
	if {$::page::dialog eq ""} {
		# (not under a page's modal sheet; never Appearance's own rail_key, which would walk Appearance's pages)
		if {$ctrl && $sym in {Prior Next}} {
			if {![settings::modal]} { settings::rail_step [expr {$sym eq "Prior" ? -1 : 1}] }
			return
		}
		if {$::settings::sel ne "appearance"} {
			if {$alt && [string match {[1-4]} $sym]} return
			# Ctrl+S saves the theme being edited on Colours: not from another page (it would make a theme)
			if {$ctrl && $sym in {s S}} return
			# Escape still reaches the focused control (a field, a list); only Appearance's "back to Theme" is held
			if {$sym eq "Escape"} {
				set p $::page::S(page)
				set ::page::S(page) theme
				try { page::appearance_key $sym $char $state } finally {
					if {$::page::S(page) eq "theme"} { set ::page::S(page) $p }
				}
				return
			}
		}
	}
	page::appearance_key $sym $char $state
}
foreach f [lsort [glob -nocomplain [file join $::settings::appdir page-*.tcl]]] { source -encoding utf-8 $f }

# Select a rail item. The Appearance page's sub-pages come through here too.
proc settings::select {id} {
	variable sel
	if {![exists $id]} return
	# nothing of the page that is left stays open (a dropdown's list, a sheet)
	if {$id ne $sel} { sctl::reset }
	set sel $id
	page::draw
}

# Open a page by name: appearance, theme, colours, desktop or login (the last two
# open Onstage, as their Change buttons do).
proc settings::open_page {id} {
	switch -- $id {
		theme - colours - desktop - login { select appearance; page::go $id }
		default { select $id }
	}
}

# The host: the rail, then the selected item's page.
proc settings::draw {} {
	variable sel
	rail
	set d [get $sel draw]
	if {$d ne ""} { {*}$d }
	rail_focus
}

proc settings::main {} {
	variable win
	variable scene
	set scene [info exists ::env(RIBBON_SETTINGS_SCENE)]
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}]
	set cache [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$home/.cache"}]
	theme::load
	raster::init [file join $cache ribbon settings]
	ui::fonts
	page::init
	# the window is 1100 x 720 on every Settings board (STYLE 3); the footer is the
	# bottom 72 px, the same as Appearance's own window, so its footer offset is 0
	set ::page::H 720
	set ::ui::H 720
	set ::page::dy 0
	set ::page::host settings::draw
	set ::app::scene $scene
	set ::app::oy 104
	updates_tick
	wm withdraw .
	set SW [winfo screenwidth .]; set SH [winfo screenheight .]
	if {$scene} {
		toplevel $win -class RibbonSettings -borderwidth 0 -highlightthickness 0
		wm overrideredirect $win 1
		wm geometry $win 1440x900+0+0
		set ui::ox 170; set ui::oy 104
		set ui::behind [ui::desktop 1440 900]
		set ui::bx 170; set ui::by 104
		canvas $win.c -width 1440 -height 900 -highlightthickness 0 -borderwidth 0 -background $ui::c(bar)
		$win.c create image 0 0 -image $ui::behind -anchor nw -tags desk
	} else {
		# a managed window: labwc frames it (title bar, buttons) unless RIBBON_OWN_FRAME=1 (rbn::framed)
		if {[rbn::appwindow $win RibbonSettings 1100 720 -fill $ui::c(bar)]} { set ui::argbwin $win }
		wm title $win Settings
		wm iconname $win Settings
		wm resizable $win 0 0
		set x [expr {max(0, ($SW - 1100) / 2)}]; set y [expr {max(0, ($SH - 720) / 2 + 14)}]
		wm geometry $win 1100x720+$x+$y
		wm protocol $win WM_DELETE_WINDOW page::quit
		set ui::behind ""
		set ui::bx 0; set ui::by 0
	}
	pack $win.c
	set ui::cv $win.c
	bind $win.c <ButtonPress-1> {settings::press %x %y}
	bind $win.c <Double-ButtonPress-1> {page::double %x %y}
	bind $win.c <B1-Motion> {ui::motion %x %y}
	bind $win.c <ButtonRelease-1> {ui::release %x %y}
	bind $win.c <Button-4> {ui::scroll %x %y -1}
	bind $win.c <Button-5> {ui::scroll %x %y 1}
	bind $win.c <MouseWheel> {ui::scroll %x %y [expr {%D > 0 ? -1 : 1}]}
	bind $win <KeyPress> {settings::keypress %K %A %s}
	if {$scene} {
		uplevel #0 [list source -encoding utf-8 $::env(RIBBON_SETTINGS_SCENE)]
	} else {
		# the pages in turn (--page appearance --page desktop: the picker), then the caller's
		# --back and --picture (ribbon-appearance; the viewer's Set as wallpaper), as Appearance's own
		serve
		app::argv_back
		foreach {opt val} $::argv { if {$opt eq "--page"} { open_page $val } }
		app::argv_pick
		page::draw
		page::tick
		after 1500 { after idle os::prewarm_shapes }
	}
	focus -force $win
	ui::blink
}

settings::main
