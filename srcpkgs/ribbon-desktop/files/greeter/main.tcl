# main.tcl - Ribbon's login screen: a greetd greeter in Tcl/Tk.
#
# Run by ribbon-greeter inside labwc (XWayland), as the unprivileged
# _greeter user:  wish /usr/lib/ribbon/greeter/main.tcl -name ribbon-greeter
#
# It shares the Ribbon shell's drawing code: raster.tcl (anti-aliasing,
# rounded boxes, shadows, icons), theme.tcl (the palette), wall.tcl (the
# wallpaper's exact pixels) and status.tcl (Wi-Fi, battery), sourced from
# the shell's directory next to this one (/usr/lib/ribbon/shell).
#
# The palette: /etc/ribbon/palette.conf if the system has one, else
# Graphite. The background: a picture in /etc/ribbon/login/ (background.png,
# .jpg or .webp), scaled to cover the screen and cropped in the middle as the
# desktop's wallpaper is, else the ribbon pattern in the login palette. Both
# are set with "ribbon-theme login" (/usr/lib/ribbon/ribbon-login-theme).
#
# How it looks: /etc/ribbon/login/options.conf (FIT fill|fit|centre|tile,
# BLUR px, DIM percent, CLOCK yes|no, COLOUR #RRGGBB: a plain colour when
# there is no picture), set with "ribbon-theme login options" or the
# Appearance app.

set dir [file dirname [file normalize [info script]]]
set shell [expr {[info exists ::env(RIBBON_SHELL_DIR)] ? $::env(RIBBON_SHELL_DIR) : [file join [file dirname $dir] shell]}]
foreach f {text raster theme wall status} { source -encoding utf-8 [file join $shell $f.tcl] }
foreach f {json greetd system login ui} { source -encoding utf-8 [file join $dir $f.tcl] }

# status.tcl tells the shell to redraw; here that is the greeter
namespace eval shell {}
proc shell::refresh {} { ui::redraw }

namespace eval greeter {}

# A writable place for the drawing cache: the greeter's state directory,
# else the runtime directory.
proc greeter::cache {} {
	foreach d [list [sys::env RIBBON_GREETER_CACHE ""] [file join [sys::env RIBBON_GREETER_STATE /var/lib/greetd] cache] \
			[file join [sys::env XDG_RUNTIME_DIR /tmp] ribbon-greeter]] {
		if {$d ne "" && ![catch {file mkdir $d}] && [file writable $d]} { return $d }
	}
	return [file join /tmp ribbon-greeter-[pid]]
}

# The login background picture, if one is set (the newest, should a change
# have been cut short and left two).
proc greeter::background {} {
	set best ""; set bt -1
	foreach e {png jpg webp} {
		set f [file join $::env(XDG_CONFIG_HOME) ribbon login background.$e]
		if {[file isfile $f] && [file readable $f] && [file mtime $f] > $bt} { set best $f; set bt [file mtime $f] }
	}
	return $best
}

# options.conf as a dict, only the keys and values the helper writes
proc greeter::options {} {
	set d [dict create FIT fill BLUR 0 DIM 0 CLOCK yes COLOUR ""]
	set f [file join $::env(XDG_CONFIG_HOME) ribbon login options.conf]
	if {[catch {open $f} fh]} { return $d }
	foreach line [split [read $fh 4096] \n] {
		if {[regexp {^FIT=(fill|fit|centre|tile)$} $line -> v]} { dict set d FIT $v }
		if {[regexp {^BLUR=([0-9]{1,2})$} $line -> v]} { dict set d BLUR [expr {min(64, $v)}] }
		if {[regexp {^DIM=([0-9]{1,3})$} $line -> v]} { dict set d DIM [expr {min(100, $v)}] }
		if {[regexp {^CLOCK=(yes|no)$} $line -> v]} { dict set d CLOCK $v }
		if {[regexp {^COLOUR=(#[0-9A-Fa-f]{6})?$} $line -> v]} { dict set d COLOUR $v }
	}
	close $fh
	return $d
}

proc greeter::main {} {
	# theme::load reads $XDG_CONFIG_HOME/ribbon/palette.conf: here, /etc
	set ::env(XDG_CONFIG_HOME) [sys::env RIBBON_GREETER_ETC /etc]
	theme::load
	# not the desktop's wallpaper.conf: the login screen has its own
	set ::wall::image [background]
	set ::ui::opt [options]
	theme::fonts
	# wall::prepare keeps the scaled picture in $XDG_CACHE_HOME/ribbon/wallpaper
	set ::env(XDG_CACHE_HOME) [cache]
	raster::init $::env(XDG_CACHE_HOME)
	ui::init
	if {[info exists ::env(RIBBON_GREETER_TEST)]} {
		# tests/greeter-scene.tcl stands in for the clock and sensors
		uplevel #0 [list source -encoding utf-8 $::env(RIBBON_GREETER_TEST)]
	} else {
		login::clock_tick
		status::wifi_tick
		status::battery_tick
		login::start
	}
	ui::redraw
}

greeter::main
