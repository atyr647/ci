# settings-pictures.tcl - bg::picture on pictures smaller than the thumbnail
# (the Appearance bug: "coordinates for -from option extend outside source
# image"), under xvfb: tclsh-free wish8.6 tests/settings-pictures.tcl DIR TMP,
# DIR the ribbon-desktop/files folder. Exits 1 on any failure.
set D [lindex $argv 0]
set T [lindex $argv 1]
set fails 0
proc check {what ok} {
	global fails
	if {$ok} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}
namespace eval ::app { variable win .w; variable scene 0; variable oy 74 }
set ::app::hosted 1
source -encoding utf-8 [file join $D appearance main.tcl]
array set ui::c {field #2A2826}
raster::init [file join $T cache]

# pictures: smaller in both directions, smaller in one, and larger
set im [image create photo -width 40 -height 30]
$im put #336699 -to 0 0 40 30
$im write [file join $T small.png] -format png
set strip [image create photo -width 1000 -height 40]
$strip put #336699 -to 0 0 1000 40
$strip write [file join $T strip.png] -format png
set big [image create photo -width 900 -height 600]
$big put #336699 -to 0 0 900 600
$big write [file join $T big.png] -format png
foreach {f w h} {small.png 200 120  strip.png 200 120  big.png 200 120  small.png 20 10} {
	set r [catch {bg::picture [file join $T $f] $w $h} data]
	if {$r} { check "$f fits $w x $h: $data"; continue }
	# bg::picture gives a cached photo (ui::mem owns it)
	check "$f comes out $w x $h" [expr {[image type $data] eq "photo" && [image width $data] == $w && [image height $data] == $h}]
}
# a smaller picture is centred on the field's fill, not stretched: the corner is the field
set p [bg::picture [file join $T small.png] 200 120]
check "a picture smaller than the frame sits on the field fill" [expr {[$p get 0 0] eq {42 40 38}}]
check "its middle is the picture" [expr {[$p get 100 60] eq {51 102 153}}]
exit [expr {$fails ? 1 : 0}]
