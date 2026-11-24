# properties-fixture.tcl - a home for Properties as its boards show it: the
# scheme in use, ~/Pictures/Iceland with the boards' photos (Jökulsárlón
# and five newer ones), four apps that open pictures (Image Viewer, the
# default, then Darkroom, Firefox and Paint) and a mimeapps.list.
#   tclsh8.6 -encoding utf-8 tests/properties-fixture.tcl HOME [graphite|fjord|moss] [PICTURES-CACHE]
# The pictures are drawn once into PICTURES-CACHE and copied from there.
encoding system utf-8
set repo [file dirname [file dirname [file normalize [info script]]]]
lassign $argv home scheme pics
if {$scheme eq ""} { set scheme graphite }
set id [dict get {graphite ribbon fjord ribbon-fjord moss ribbon-moss} $scheme]
set sys [file join $repo srcpkgs ribbon-desktop files themes palettes]
set cfg [file join $home .config]
file mkdir [file join $cfg ribbon] [file join $home .local share applications] [file join $home Pictures Iceland]
file copy -force [file join $sys $id.conf] [file join $cfg ribbon palette.conf]
set fh [open [file join $cfg ribbon theme.conf] w]; puts $fh "PALETTE=$id"; close $fh

# the pictures (PNG data: Tk reads it without gdk-pixbuf, whatever the name)
if {$pics eq ""} { set pics [file join $home .cache pics] }
file mkdir $pics
set mp [file join $repo tests make-picture.tcl]
foreach {name kind w h} {photo photo-dusk-0 379 204 n1 photo-blue-1 70 74 n2 photo-ice-2 70 74 n3 photo-dusk-0 70 74 n4 photo-fern-1 70 74 n5 photo-ember-2 70 74} {
	set f [file join $pics $name.png]
	if {![file exists $f]} { exec tclsh8.6 $mp $kind $w $h $f }
}
set dir [file join $home Pictures Iceland]
file copy -force [file join $pics photo.png] [file join $dir Jökulsárlón.jpg]
set t [clock scan "2026-08-14 21:47" -format {%Y-%m-%d %H:%M}]
file mtime [file join $dir Jökulsárlón.jpg] $t
# the newest five, newest first
set now [clock seconds]
foreach n {1 2 3 4 5} name {Fjallsárlón.png Svínafell.png Vestrahorn.png Þórsmörk.png Reynisfjara.png} {
	file copy -force [file join $pics n$n.png] [file join $dir $name]
	file mtime [file join $dir $name] [expr {$now - 3600 * $n}]
}

# apps that open pictures
foreach {file name generic cats} {
	org.ribbon.imageviewer {Image Viewer} {Image viewer} {Graphics;Viewer;}
	darkroom Darkroom {Photo editor} {Graphics;Photography;}
	firefox Firefox {Web browser} {Network;WebBrowser;}
	paint Paint {Paint program} {Graphics;2DGraphics;}
} {
	set fh [open [file join $home .local share applications $file.desktop] w]
	fconfigure $fh -encoding utf-8
	puts $fh "\[Desktop Entry\]\nType=Application\nName=$name\nGenericName=$generic\nExec=true %f\nCategories=$cats\nMimeType=image/jpeg;image/png;"
	close $fh
}
set fh [open [file join $cfg mimeapps.list] w]
puts $fh "\[Default Applications\]\nimage/jpeg=org.ribbon.imageviewer.desktop\nimage/png=org.ribbon.imageviewer.desktop\n\n\[Added Associations\]\nimage/jpeg=darkroom.desktop;firefox.desktop;paint.desktop;"
close $fh
