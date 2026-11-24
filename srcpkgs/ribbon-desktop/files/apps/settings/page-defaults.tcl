# page-defaults.tcl - Settings → Default apps (board Settings-A8-Default-Apps): which app opens the web, mail, folders,
# a terminal, text and pictures, and music, video, PDF documents and archives. Each row is a dropdown of the installed
# apps that can do the job, with the row's icon; "Not set" when nothing can. The logic is defaults.tcl (mimeapps.list
# and xdg-terminals.list, read and written the freedesktop way).
#
# Layout (window coordinates; the page runs from 270 to 1060): two columns of 48 px rows, 379 wide, at 270 and 681;
# a column's label is at 119, its rows start at 141; a row's dropdown is 220 wide and ends with the column. The last
# row of a column has no rule.

source -encoding utf-8 [file join [file dirname [file normalize [info script]]] defaults.tcl]

settings::page defaults -title {Default apps} -icon grid -group 3 -order 4 -draw settings::draw_defaults \
	-rows {{Opens with} Web Mail Files Terminal Text Pictures Media Music Video {Documents (PDF)} Archives}

# the rows' icons, as the board draws them
array set ::ui::paths {
	def_globe    {M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0 M2 12h20 M12 2a15 15 0 0 1 0 20 M12 2a15 15 0 0 0 0 20}
	def_file     {M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z M14 3v5h5}
	def_folder   {M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z}
	def_terminal {M4 17l6-6-6-6 M12 19h8}
	def_edit     {M12 20h9 M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4z}
	def_image    {M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z M8.5 10a1.5 1.5 0 1 0 0-3a1.5 1.5 0 1 0 0 3z M21 15l-5-5L5 21}
	def_music    {M9 18V5l12-2v13 M6 21a3 3 0 1 0 0-6a3 3 0 1 0 0 6z M18 19a3 3 0 1 0 0-6a3 3 0 1 0 0 6z}
	def_film     {M4 3h16a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z M7 3v18 M17 3v18 M3 12h18 M3 7.5h4 M3 16.5h4 M17 7.5h4 M17 16.5h4}
	def_box      {M21 16V8l-9-5-9 5v8l9 5 9-5z M3.3 7L12 12l8.7-5 M12 22V12}
}

namespace eval defp {}

# A choice from a row's list. "Not set" is there only when nothing can open the row, and picking it changes nothing;
# a choice that cannot be written leaves the row as it was (defaults.tcl reads the disk again either way).
proc defp::pick {row app} {
	if {$app eq ""} return
	defapps::choose $row $app
}
# A change made elsewhere (Properties' "Opens with", a newly installed app) while the page is shown.
proc defp::changed {} { if {$::settings::sel eq "defaults"} { page::draw } }

proc settings::draw_defaults {} {
	array set c [array get ui::c]
	defapps::refresh
	defapps::start defp::changed {expr {$::settings::sel eq "defaults"}}
	set m [defapps::model]
	ui::text 270 34 {Default apps} sg28 $c(fg) w -0.56
	ui::text 270 [ui::lh 76 i14 21] [dict get $m subtitle] i14 $c(muted)
	foreach {group title x0} {opens {Opens with} 270 media Media 681} {
		sctl::label $x0 119 $title
		set rows [lmap r [dict get $m rows] { if {[dict get $r group] ne $group} continue; set r }]
		set y 141
		set k 0
		foreach r $rows {
			incr k
			sctl::row $x0 [expr {$x0 + 379}] $y [dict get $r label] [expr {$k == [llength $rows]}]
			sctl::dropdown def-[dict get $r id] [expr {$x0 + 159}] $y 220 [dict get $r items] [dict get $r current] \
				[list defp::pick [dict get $r id]] def_[dict get $r icon]
			incr y 48
		}
	}
	sctl::overlay
}
