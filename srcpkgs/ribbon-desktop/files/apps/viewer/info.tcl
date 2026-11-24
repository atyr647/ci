# info.tcl - the Image Viewer's Info panel (Viewer-Final-2-Info, -3-Info-Edit): the Files
# Properties component (properties/inspector.tcl), docked at the window's right, 330 wide,
# edge to edge, with the footer following the content. Nothing is forked: this file only
# draws the component in the viewer's place, and routes the keys and the open menu of its
# edit view (the Properties page's own handlers, page::key and w::menu_draw, are not used
# here because they quit on Escape and draw a whole page).
#
#   vinfo::draw X H FACTS   the panel at X (the stage's width), H tall, for the picture's facts
#   vinfo::overlay          the open dropdown's menu, drawn last (after the toolbar)
#   vinfo::key SYM CHAR     keys while the edit view has a field or a menu focused; 1 if taken

namespace eval vinfo {}

proc vinfo::draw {x h facts} {
	inspector::draw $x 0 $h [list $facts] -w $::zoom::PW -pad 24 -top 0 -preview 0 -footer follow -keys 76
}

proc vinfo::overlay {} {
	if {[dict size $::page::menu]} { w::menu_draw $::page::menu }
}

# A key while the edit view is open: the focused name field takes the text, Escape
# leaves the edit view, and an open menu takes the arrows and Return.
proc vinfo::key {sym char state} {
	if {[dict size $::page::menu] && [::page::menu_key $sym]} { return 1 }
	lassign [ui::focused] id kind
	if {!$::inspector::edit || $kind ne "field"} { return 0 }
	if {$sym eq "Escape"} { inspector::edit_end; viewer::draw; return 1 }
	if {[ui::field_key $id $sym $char $state]} { viewer::draw }
	return 1
}
