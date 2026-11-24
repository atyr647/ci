# registry.tcl - Settings' pages (C4). The rail lists every item below, with
# its title, icon and group; a page file (page-<id>.tcl) registers its own
# draw proc and the row labels that search reads:
#
#   settings::page ID -title T -icon I -group N -order N -draw PROC -rows {labels}
#
# An item with no page registered yet shows an empty body (its mockup is
# not drawn yet). The title, icon, group and order of a registered page
# override the defaults here.

namespace eval settings {
	variable info          ;# array ID -> dict (title icon group order draw rows)
	# the sixteen items of the rail (Settings-A-Rail, STYLE 3): id, title, icon, group, order
	variable defaults {
		appearance {Appearance palette 1 1}
		display    {Display monitor 1 2}
		sound      {Sound speaker 1 3}
		access     {Accessibility access 1 4}
		network    {Network wifi 2 1}
		bluetooth  {Bluetooth bluetooth 2 2}
		printers   {Printers printer 2 3}
		power      {Power battery 3 1}
		game       {{Game overlay} overlay 3 2}
		keyboard   {{Keyboard and mouse} keyboard 3 3}
		defaults   {{Default apps} grid 3 4}
		users      {Users users 4 1}
		updates    {Updates refresh 4 2}
		datetime   {{Date and time} clock 4 3}
		language   {{Language and region} lang 4 4}
		about      {About info 4 5}
	}
}

proc settings::init_registry {} {
	variable info
	variable defaults
	array unset info
	foreach {id spec} $defaults {
		lassign $spec title icon group order
		set info($id) [dict create title $title icon $icon group $group order $order draw "" rows {}]
	}
}

proc settings::page {id args} {
	variable info
	if {![info exists info($id)]} { error "settings::page: no rail item $id" }
	set d $info($id)
	foreach {k v} $args {
		switch -- $k {
			-title { dict set d title $v }
			-icon { dict set d icon $v }
			-group { dict set d group $v }
			-order { dict set d order $v }
			-draw { dict set d draw $v }
			-rows { dict set d rows $v }
			default { error "settings::page $id: unknown option $k" }
		}
	}
	set info($id) $d
}

# The item ids in rail order: by group, then order.
proc settings::ids {} {
	variable info
	set keys {}
	foreach id [array names info] {
		lappend keys [format "%02d%02d %s" [dict get $info($id) group] [dict get $info($id) order] $id]
	}
	lmap k [lsort $keys] { lindex [split $k] 1 }
}

proc settings::exists {id} {
	variable info
	expr {[info exists info($id)]}
}

proc settings::get {id key} {
	variable info
	dict get $info($id) $key
}

settings::init_registry
