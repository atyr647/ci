# settings-wallpaper.tcl - the viewer's Set as wallpaper, through Settings (U38b): the wrapper's
# argv (ribbon-appearance --page desktop --picture FILE --back {Image Viewer}, Settings taking
# --page appearance first) opens the desktop picker with FILE added to Pictures and chosen, its
# back button labelled "Image Viewer", and back closes the window. Under xvfb:
#   wish8.6 -encoding utf-8 tests/settings-wallpaper.tcl DIR TMP
# DIR the ribbon-desktop/files folder, TMP a scratch folder (HOME and XDG dirs point into it).
# Exits 1 on any failure.
set D [lindex $argv 0]
set T [lindex $argv 1]
set fails 0
proc check {what ok} {
	global fails
	if {$ok} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}

set pic [file normalize [file join $T wall.png]]
set im [image create photo -width 64 -height 40]
$im put #336699 -to 0 0 64 40
$im write $pic -format png

# Settings' own window, not the scene: its argv is the wrapper's
catch {unset ::env(RIBBON_SETTINGS_SCENE)}
catch {unset ::env(RIBBON_APPEARANCE_SCENE)}
set ::argv [list --page appearance --page desktop --picture $pic --back {Image Viewer}]
# the network page's D-Bus package (unix_extra) is not needed here: only Appearance is drawn
package provide ribbon::dbus 1.0
source -encoding utf-8 [file join $D apps settings main.tcl]

# the picture is added and chosen once the picker is up (after idle)
set deadline [expr {[clock milliseconds] + 8000}]
while {[os::cur_picture] ne $pic && [clock milliseconds] < $deadline} { after 50; update }

check "Settings is on Appearance" [expr {$::settings::sel eq "appearance"}]
check "the desktop picker is open" [expr {$os::S(kind) eq "desktop" && $os::S(open)}]
check "the picture is added to Pictures" [expr {$pic in $os::pictures}]
check "the picture is chosen on the desktop picker" [expr {[os::cur_picture] eq $pic}]
check "the picker opens on Pictures" [expr {$os::S(tab) eq "pictures"}]
check "the back button reads Image Viewer" [expr {$os::back_label eq "Image Viewer"}]

# back closes the window (page::quit) rather than going to Settings' front page
set ::quit_called 0
proc page::quit {} { set ::quit_called 1 }
os::back
check "back closes the window" [expr {$::quit_called}]

puts [expr {$fails ? "settings-wallpaper: $fails failed" : "settings-wallpaper: all checks passed"}]
exit [expr {$fails ? 1 : 0}]
