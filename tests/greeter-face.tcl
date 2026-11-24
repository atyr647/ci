# tests/greeter-face.tcl -- the login screen's account picture loader (greeter/system.tcl, sys::face): a PNG or GIF the greeter
# may read, whose OWN HEADER declares at most 2048 pixels a side and 4 million pixels. The picture is decoded by Tk in the one
# process every user's login goes through, and any user can put a file at ~/.face: a 900 KB PNG that declares 30000 x 30000
# decodes to gigabytes in seconds (review finding of 17 Nov), and with normal memory overcommit nothing catches it.
#   tclsh8.6 -encoding utf-8 tests/greeter-face.tcl
set top [file dirname [file dirname [file normalize [info script]]]]
source -encoding utf-8 $top/srcpkgs/ribbon-desktop/files/greeter/system.tcl
set fails 0
proc ok {name cond {detail ""}} {
    if {$cond} { puts "  ok   $name" } else { puts "  FAIL $name" ; if {$detail ne ""} { puts "       $detail" } ; incr ::fails }
}
set W [file normalize [exec mktemp -d]]
file mkdir $W/icons $W/home
set env(RIBBON_GREETER_ICONS) $W/icons

# a PNG's first bytes: signature, IHDR (length 13, type, width, height, depth, colour, 0, 0, 0), crc (not checked: the
# greeter reads the header only, so a bomb needs nothing more)
proc png {path w h {pad 0}} {
    set f [open $path wb]
    puts -nonewline $f "\x89PNG\r\n\x1a\n"
    puts -nonewline $f [binary format Ia4IIccccc 13 IHDR $w $h 8 0 0 0 0]
    puts -nonewline $f [binary format I 0]
    puts -nonewline $f [string repeat x $pad]
    close $f
}
proc gif {path w h} {
    set f [open $path wb]
    puts -nonewline $f "GIF89a[binary format ss $w $h]"
    puts -nonewline $f [string repeat x 20]
    close $f
}
proc face {name} { sys::face [dict create name $name home $::W/home/$name] }

png $W/icons/ann 64 64 100
ok "a 64 x 64 PNG is the picture" [expr {[face ann] eq "$W/icons/ann"}] [face ann]
png $W/icons/big 2048 2048
ok "2048 x 2048 (4 194 304 pixels, the limit) is allowed" [expr {[face big] eq "$W/icons/big"}]
png $W/icons/wide 2049 100
ok "a side of 2049 pixels is refused" [expr {[face wide] eq ""}] [face wide]
png $W/icons/tall 100 2049
ok "  tall as well" [expr {[face tall] eq ""}]
png $W/icons/bomb 30000 30000 200
ok "a PNG that declares 30000 x 30000 is refused from its header, without being decoded" [expr {[face bomb] eq ""}] [face bomb]
png $W/icons/huge 4294967295 4294967295
ok "dimensions at the top of the 32-bit range do not overflow into something small" [expr {[face huge] eq ""}] [face huge]
png $W/icons/zero 0 64
ok "a zero side is no picture" [expr {[face zero] eq ""}]
gif $W/icons/gann 48 48
ok "a small GIF is the picture" [expr {[face gann] eq "$W/icons/gann"}] [face gann]
gif $W/icons/gbomb 40000 40000
ok "a GIF that declares 40000 x 40000 is refused" [expr {[face gbomb] eq ""}]
set f [open $W/icons/short wb] ; puts -nonewline $f "\x89PNG\r\n\x1a\n" ; close $f
ok "a PNG signature with no header after it is refused" [expr {[face short] eq ""}]
set f [open $W/icons/notimg wb] ; puts -nonewline $f "#!/bin/sh\necho hello, this is not a picture at all\n" ; close $f
ok "a file that is not a picture is refused" [expr {[face notimg] eq ""}]
png $W/icons/ihdrless 64 64
set f [open $W/icons/ihdrless r+b] ; seek $f 12 ; puts -nonewline $f "XXXX" ; close $f
ok "a PNG whose first chunk is not IHDR is refused" [expr {[face ihdrless] eq ""}]
# ~/.face is judged the same way when there is no AccountsService icon
file mkdir $W/home/bob ; png $W/home/bob/.face 3000 3000
ok "a bomb at ~/.face is refused too" [expr {[face bob] eq ""}] [face bob]
file mkdir $W/home/cat ; png $W/home/cat/.face 96 96
ok "a small ~/.face is used" [expr {[face cat] eq "$W/home/cat/.face"}]
# the icon is tried first, and a refused icon falls through to ~/.face
png $W/icons/dan 30000 30000 ; file mkdir $W/home/dan ; png $W/home/dan/.face 32 32
ok "a refused icon falls through to a good ~/.face" [expr {[face dan] eq "$W/home/dan/.face"}] [face dan]

file delete -force $W
if {$fails} { puts "greeter face: $fails checks failed" ; exit 1 }
puts "greeter face: all checks passed"
