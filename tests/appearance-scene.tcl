# appearance-scene.tcl - put the Appearance app into one of its mockups'
# states (design/mockups/Appear-*), on a 1440 x 900 desktop, for
# screenshots and pixel comparison (RIBBON_APPEARANCE_SCENE=this file, run
# by appearance/main.tcl; the home from tests/appearance-fixture.tcl).
#   RIBBON_SCENE = theme | colours (the boards A4c) | colours-code (A4d) |
#                  colours-shadow (A4e); stripes | dusk | yours |
#                  delete | rename (other states); bg-ribbon | bg-pictures |
#                  bg-slideshow | bg-video | bg-colour | bg-login (the
#                  background sheet, BG-Onstage-*; APPEARANCE_BG: fixtures)
#   RIBBON_APPEARANCE_SHOT = file: take a screenshot (ImageMagick import)
#   RIBBON_APPEARANCE_EXIT = ms: quit after drawing; any Tcl error fails
set scene [expr {[info exists ::env(RIBBON_SCENE)] ? $::env(RIBBON_SCENE) : "theme"}]
if {[info exists ::env(RIBBON_APPEARANCE_EXIT)] || [info exists ::env(RIBBON_APPEARANCE_SHOT)]} {
	proc bgerror {msg} { puts stderr "$msg\n$::errorInfo"; exit 1 }
}
# The background sheet (BG-Onstage-*) as the boards show it. The fixture
# folder (APPEARANCE_BG, made by tests/steps.d/58-bg-onstage.sh from
# tests/fixtures/onstage/pictures) holds pictures/NAME.png, a slideshow
# folder (wallpapers/) and videos/NAME.mp4.
proc onstage_scene {tab} {
	set fx $::env(APPEARANCE_BG)
	set home $::env(HOME)
	set pics [lsort [glob -nocomplain -directory $fx/pictures *.png]]
	# the boards' order: Lake at dusk, Glacier, Pines, Canyon, Harbour, Moor, ...
	set order {}
	foreach n {{Lake at dusk} Glacier Pines Canyon Harbour Moor} { if {[file exists $fx/pictures/$n.png]} { lappend order $fx/pictures/$n.png } }
	foreach f $pics { if {$f ni $order} { lappend order $f } }
	os::list_write pictures.list [lrange $order 0 11]
	set vids {}
	foreach n {Tide Rain Ember} { if {[file exists $fx/videos/$n.mp4]} { lappend vids $fx/videos/$n.mp4 } }
	os::list_write videos.list $vids
	os::list_write colours.list {#24343A #1E2A30 #2B2620 #101418 #3A3026 #1C2A22 #000000 #2E3238}
	# the stage: a window of the app's own unless the caller chose one (swaybg under a compositor)
	if {![info exists ::env(RIBBON_APPEARANCE_STAGE)]} { set ::env(RIBBON_APPEARANCE_STAGE) window }
	set lake [file join $fx pictures "Lake at dusk.png"]
	dict set bg::desk fit fill
	switch -- $tab {
		ribbon { dict set bg::desk mode pattern }
		pictures { dict set bg::desk mode picture; dict set bg::desk image $lake }
		slideshow {
			set dir [file join $home Pictures Wallpapers]
			file mkdir $dir
			foreach f [glob -nocomplain -directory $fx/wallpapers *] { file copy -force $f $dir }
			dict set bg::desk mode slideshow; dict set bg::desk dir $dir
			dict set bg::desk image [lindex [lsort [glob -directory $dir *.png]] 0]
			dict set bg::desk interval 1800; dict set bg::desk crossfade 1.5
			dict set bg::desk shuffle yes; dict set bg::desk subdirs no
		}
		video {
			dict set bg::desk mode video; dict set bg::desk video [lindex $vids 0]
			dict set bg::desk pause_fullscreen yes; dict set bg::desk bars see-through
		}
		colour { dict set bg::desk mode colour; dict set bg::desk colour #24343A }
		login {
			dict set bg::login same 0; dict set bg::login source picture; dict set bg::login image $lake
			dict set bg::login fit fill; dict set bg::login blur 12; dict set bg::login dim 25; dict set bg::login clock yes
			# the greeter preview, as greeter-scene.tcl's fixtures
			set g [file join [file dirname [file normalize [info script]]] fixtures greeter]
			set ::env(RIBBON_GREETER_PASSWD) $g/passwd
			set ::env(RIBBON_GREETER_XKB) $g/00-keyboard.conf
			set ::env(RIBBON_PREVIEW_USER) alex
			set ::env(RIBBON_PREVIEW_TIME) "00:27|Sunday 31 May"
			set ::env(RIBBON_PREVIEW_STATUS) "on|82"
		}
	}
	bg::applied_now
	os::start [expr {$tab eq "login" ? "login" : "desktop"}]
	switch -- $tab {
		video { os::set_show desktop }
		colour { set page::S(mode) rgb; page::from_hex #24343A; set page::S(h) 197; os::draw }
	}
	set ui::focus ""
	set ui::caretfix off
}

# the mockups' moment
set page::S(time) 00:27
set ui::caretfix off
# the boards show Graphite chosen, whichever scheme the desktop has
if {![string match bg-* $scene]} { page::pick_now [expr {[info exists ::env(APPEARANCE_SCENE_THEME)] ? $::env(APPEARANCE_SCENE_THEME) : "ribbon"}] }
# the role list shows the group's head first (the boards' scroll)
proc scene_top {title} {
	lassign [page::ritems] items
	set i 0
	foreach it $items {
		if {[lindex $it 0] eq "head" && [lindex $it 2] eq $title} {
			set page::S(rtop) [page::rclamp $i $page::S(listH)]
			return
		}
		incr i
	}
}
switch -- $scene {
	theme { page::go theme }
	colours {
		# A4c: the wordmark, its list scrolled to Status
		page::go colours
		page::role DESK_MARK
		scene_top Status
		set ui::focus hex
	}
	colours-code {
		# A4d: a code token, its list at Code
		page::go colours
		page::role SYN_STR
		scene_top Code
	}
	colours-shadow {
		# A4e: the bar shadow, its list at Interface
		page::go colours
		page::role BAR_SHADOW
		scene_top Interface
		set ui::focus hex
	}
	stripes {
		page::go colours
		set page::S(mode) hsl
		page::role DESK_STRIPE
	}
	dusk {
		page::pick_now dusk
		page::go colours
		page::role FG
	}
	yours { page::pick_now dusk }
	delete { page::pick_now dusk; page::delete dusk; set ui::kbd 1 }
	rename { page::pick_now dusk; page::rename_start dusk }
	bg-ribbon - bg-pictures - bg-slideshow - bg-video - bg-colour - bg-login { onstage_scene [string range $scene 3 end] }
}
page::draw

# RIBBON_APPEARANCE_READY = file: made once the scene is drawn (a caller outside, such as a compositor's capture, waits for it)
if {[info exists ::env(RIBBON_APPEARANCE_READY)]} {
	after idle { after 0 { update; close [open $::env(RIBBON_APPEARANCE_READY) w] } }
}
if {[info exists ::env(RIBBON_APPEARANCE_SHOT)]} {
	after [expr {[info exists ::env(RIBBON_APPEARANCE_SHOT_DELAY)] ? $::env(RIBBON_APPEARANCE_SHOT_DELAY) : 600}] {
		update
		exec import -window root $::env(RIBBON_APPEARANCE_SHOT)
		if {![info exists ::env(RIBBON_APPEARANCE_EXIT)]} { exit 0 }
	}
}
if {[info exists ::env(RIBBON_APPEARANCE_EXIT)]} {
	after $::env(RIBBON_APPEARANCE_EXIT) { update; exit 0 }
}
