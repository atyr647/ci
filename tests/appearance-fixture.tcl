# appearance-fixture.tcl - a home for the Appearance app as its mockups
# show it: the scheme in use (graphite, fjord or moss), and Dusk, a theme
# of your own.
#   tclsh8.6 tests/appearance-fixture.tcl CONFIG-DIR [graphite|fjord|moss]
set repo [file dirname [file dirname [file normalize [info script]]]]
lassign $argv cfg scheme
if {$scheme eq ""} { set scheme graphite }
set id [dict get {graphite ribbon fjord ribbon-fjord moss ribbon-moss} $scheme]
set sys [file join $repo srcpkgs ribbon-desktop files themes palettes]
file mkdir [file join $cfg ribbon palettes]
file copy -force [file join $sys $id.conf] [file join $cfg ribbon palette.conf]
file copy -force [file join $repo tests fixtures appearance dusk.conf] [file join $cfg ribbon palettes dusk.conf]
set fh [open [file join $cfg ribbon theme.conf] w]
puts $fh "PALETTE=$id\nLOGIN_FOLLOWS_THEME=yes"
close $fh
