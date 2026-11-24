# settings-scene.tcl - Settings in one of the boards' states, on the 1440 x 900
# desktop, for screenshots and pixel checks (RIBBON_SETTINGS_SCENE=this file,
# sourced by apps/settings/main.tcl; the home from the caller).
#   RIBBON_SCENE = appearance (Settings-A4-Appearance, the default) | colours
#                  (Settings-A4b-Colours) | search (the rail filtered to "Duplicate")
#                  | empty (Sound: an item with no page yet) | updates (the rail
#                  with the chip, when kit's cache file says updates are waiting)
#   RIBBON_SETTINGS_SHOT = file: take a screenshot (ImageMagick import)
#   RIBBON_SETTINGS_EXIT = ms: quit after this long (default 1500); any Tcl error fails
set scene [expr {[info exists ::env(RIBBON_SCENE)] ? $::env(RIBBON_SCENE) : "appearance"}]
if {[info exists ::env(RIBBON_SETTINGS_EXIT)] || [info exists ::env(RIBBON_SETTINGS_SHOT)]} {
	proc bgerror {msg} { puts stderr "$msg\n$::errorInfo"; exit 1 }
}
switch -- $scene {
	appearance { settings::open_page theme }
	colours { settings::open_page colours }
	search { settings::set_query Duplicate }
	empty { settings::select sound }
	updates { settings::select updates }
}
set ms [expr {[info exists ::env(RIBBON_SETTINGS_EXIT)] ? $::env(RIBBON_SETTINGS_EXIT) : 1500}]
if {[info exists ::env(RIBBON_SETTINGS_SHOT)]} {
	after 900 [list exec import -window root $::env(RIBBON_SETTINGS_SHOT)]
}
after $ms exit 0
