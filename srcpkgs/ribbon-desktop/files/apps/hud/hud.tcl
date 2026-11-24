# hud.tcl - the Game HUD: entry point, the settings interface, the runtime state and the timers.
#
# Files: hud-data.tcl (readers), hud-frames.tcl (frame source), hud-draw.tcl (layout and drawing), hud-surface.tcl (the
# overlay), hud-store.tcl (Settings → Game overlay's store, resolved), hud-games.tcl (the game in front), hud-art.tcl
# (the game's art for the header), and this file.
# The shell's raster.tcl (rounded boxes and shadows) is sourced from ../../shell.
#
# SETTINGS INTERFACE. The daemon (main.tcl) reads the Game overlay store through hud-store.tcl and passes the record
# in effect for the game in front to hud::configure. Keys and values:
#   layout     off | fps | compact | full                  default full
#   position   top-left | top-right | bottom-left | bottom-right   default top-right
#   scale      90 | 100 | 125 | 150                        default 100
#   opacity    0..100 (glass alpha, percent)               default 86
#   contents   list of: frametime low graph game gpu vram cpu mem power net disk clock
#              default: all but disk and clock           (Disk and Clock are the optional rows)
# hud::configure takes a dict of any of those keys (unknown keys are ignored, bad values fall back to the
# current value) and returns the effective dict. hud::config returns it. hud::settings_defaults returns the defaults.
# The overlay's on/off, Show when a game starts, the frame source and the per-game overrides are the daemon's
# (main.tcl), from the same record.
#
# RUNTIME STATE (set by the surface, U23, not stored): hud::set_runtime takes a dict of
#   pinned 0|1   the HUD stays up when the game loses focus
#   menu 0|1     the in-game quick menu is open (the right-hand HUD moves to 358 px)
#   name         the game's name for the header ("" hides it)
#   art          the game's picture for the header (hud::art::for_key; "" draws the pill)
#   backdrop     "#rrggbb", the colour under the HUD (the glass is blended with it)
#
# DRAWING: hud::view W H builds the view; hud::ops returns the ops; hud::paint canvas W H draws on a canvas.
# TIMERS: hud::start ?redraw? samples the readers at 2 Hz, polls the frame source every frame, and runs the redraw
# command when something changed. hud::stop cancels them.

namespace eval ::hud {
	variable here [file dirname [file normalize [info script]]]
	variable keys {frametime low graph game gpu vram cpu mem power net disk clock}
	variable layouts {off fps compact full}
	variable positions {top-left top-right bottom-left bottom-right}
	variable scales {90 100 125 150}
	variable defaults [dict create layout full position top-right scale 100 opacity 86 \
		contents {frametime low graph game gpu vram cpu mem power net}]
	variable cfg $defaults
	variable runtime [dict create pinned 0 menu 0 name "" art "" backdrop #000000]
	variable redraw_cmd ""
	variable timers {}
	variable loaded 0
	variable palette_file ""
}

proc ::hud::init_modules {} {
	variable here
	variable loaded
	if {$loaded} return
	foreach f [list $here/hud-data.tcl $here/hud-frames.tcl $here/hud-draw.tcl $here/hud-surface.tcl \
		$here/hud-store.tcl $here/hud-games.tcl $here/hud-art.tcl] {
		uplevel #0 [list source -encoding utf-8 $f]
	}
	# the header's art: made by hud-art.tcl, drawn when it is ready
	set ::hud::draw::image_cmd ::hud::art::png
	::hud::art::configure -done ::hud::notify
	# the shell's folder: files/apps/hud -> files/shell in the repo, /usr/lib/ribbon/hud -> /usr/lib/ribbon/shell installed
	foreach d [list [file join $here .. shell] [file join $here .. .. shell]] {
		if {[file exists [file join $d raster.tcl]]} {
			uplevel #0 [list source -encoding utf-8 [file join $d raster.tcl]]
			break
		}
	}
	set loaded 1
}

proc ::hud::settings_defaults {} {
	variable defaults
	return $defaults
}

proc ::hud::config {} {
	variable cfg
	return $cfg
}

# Take a settings dict (see the header). Returns the effective settings.
proc ::hud::configure {d} {
	variable cfg
	variable layouts
	variable positions
	variable scales
	variable keys
	set new $cfg
	if {[dict exists $d layout] && [dict get $d layout] in $layouts} { dict set new layout [dict get $d layout] }
	if {[dict exists $d position] && [dict get $d position] in $positions} { dict set new position [dict get $d position] }
	if {[dict exists $d scale] && [dict get $d scale] in $scales} { dict set new scale [dict get $d scale] }
	if {[dict exists $d opacity] && [string is integer -strict [dict get $d opacity]]} {
		dict set new opacity [expr {max(0, min(100, [dict get $d opacity]))}]
	}
	if {[dict exists $d contents]} {
		set shown {}
		foreach k $keys { if {$k in [dict get $d contents]} { lappend shown $k } }
		dict set new contents $shown
	}
	set cfg $new
	return $cfg
}

# Set the runtime state (see the header). Unknown keys are ignored.
proc ::hud::set_runtime {d} {
	variable runtime
	foreach k {pinned menu name art backdrop} {
		if {[dict exists $d $k]} { dict set runtime $k [dict get $d $k] }
	}
	return $runtime
}

# Load the palette's colours (BAR FIELD PILL BORDER FG MUTED) from KEY=VALUE lines. The file is the given path, or
# the user's palette, or the system's Graphite palette; a missing key keeps its default.
proc ::hud::theme_load {{file ""}} {
	variable palette_file
	init_modules
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/"}]
	set cfgdir [expr {[info exists ::env(XDG_CONFIG_HOME)] ? $::env(XDG_CONFIG_HOME) : "$home/.config"}]
	set cands [expr {$file ne "" ? [list $file] : [list $cfgdir/ribbon/palette.conf /usr/share/ribbon/themes/palettes/ribbon.conf]}]
	set p {}
	foreach f $cands {
		if {[catch {::open $f r} fh]} continue
		set text [::read $fh]
		::close $fh
		foreach line [split $text \n] {
			if {[regexp {^\s*([A-Z_0-9]+)=(.*)$} $line -> k v]} { dict set p $k [string trim [string trim $v] \"']}
		}
		set palette_file $f
		break
	}
	hud::draw::set_palette $p
	return $p
}

# The view for a W x H screen: the settings, the runtime state, the frame numbers and the metric rows.
proc ::hud::view {W H {native 0}} {
	variable cfg
	variable runtime
	set v [dict create W $W H $H native $native]
	foreach k {layout position scale opacity contents} { dict set v $k [dict get $cfg $k] }
	dict set v pos [dict get $cfg position]
	foreach k {pinned menu name art backdrop} { dict set v $k [dict get $runtime $k] }
	dict set v frames [hud::frames::numbers]
	dict set v rows [hud::data::rows]
	return $v
}

# the ops for a W x H screen; native 1: the glass is see-through (alpha on the rrect), for the layer surface
proc ::hud::ops {W H {native 0}} {
	return [hud::draw::ops [view $W $H $native]]
}

# draw on CANVAS, a W x H screen
proc ::hud::paint {canvas W H} {
	hud::draw::paint $canvas [ops $W $H]
}

# the redraw command, run when the readings or the frames change
proc ::hud::start {{redraw ""}} {
	variable redraw_cmd
	variable timers
	init_modules
	set redraw_cmd $redraw
	stop
	# what the frame pipes hold from before the HUD came up is not frames of now
	::hud::frames::drain
	::hud::data::sample
	set timers [list [after 500 ::hud::data_tick] [after 16 ::hud::frame_tick]]
}

proc ::hud::stop {} {
	variable timers
	foreach t $timers { after cancel $t }
	set timers {}
	::hud::data::stop
}

proc ::hud::notify {} {
	variable redraw_cmd
	if {[info exists redraw_cmd] && $redraw_cmd ne ""} { uplevel #0 $redraw_cmd }
}

proc ::hud::data_tick {} {
	variable timers
	::hud::data::sample
	notify
	set timers [lreplace $timers 0 0 [after 500 ::hud::data_tick]]
}

proc ::hud::frame_tick {} {
	variable timers
	set g $::hud::frames::gen
	hud::frames::poll
	if {$::hud::frames::gen != $g} notify
	set timers [lreplace $timers 1 1 [after 16 ::hud::frame_tick]]
}
