# wall.tcl - Set as wallpaper (Viewer-Final-7-Wallpaper): the viewer only starts Appearance
# on Pictures with the open picture added and chosen. The picker is Appearance's own
# (appearance/onstage.tcl); the --picture option is read in appearance/main.tcl.
#
#   vwall::wallpaper   runs  ribbon-appearance --page desktop --picture FILE --back {Image Viewer}  in the background

namespace eval vwall {}

proc vwall::wallpaper {args} {
	set f $::viewer::file
	if {$f eq ""} return
	catch {exec ribbon-appearance --page desktop --picture $f --back {Image Viewer} &}
}
