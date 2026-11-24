# page-appearance.tcl - Settings → Appearance: the Theme and Colours pages of
# appearance/pages.tcl, hosted here with the Theme | Colours switch in the header
# (page::head). Desktop background and Login screen open Onstage from their
# Change buttons, as they do in the Appearance app.

settings::page appearance -title Appearance -icon palette -group 1 -order 1 \
	-draw settings::draw_appearance \
	-rows {Theme Colours {Built in} Yours {New from current} {Edit colours} Duplicate Export... Import... \
		{Desktop background} {Login screen} Desktop Apply Revert}

# The page's footer rule (a host draws it; the Appearance window's own is in page::frame_boxes).
proc settings::draw_appearance {} {
	array set c [array get ui::c]
	ui::hline 230 1100 [expr {648 + $::page::dy}] $c(border)
	set p [set ::page::S(page)]
	page::draw_$p
}
