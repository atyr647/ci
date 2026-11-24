# raster-cache.tcl - the shell's raster cache keys (shell/raster.tcl): a CRC32 collision
# is a miss, never another key's picture. Run under wish (it makes photos):
#   wish8.6 -encoding utf-8 tests/raster-cache.tcl WORKDIR
# Prints "  ok ..." per check and "raster-cache: all checks passed" or the failures; exits 1 on a failure.
#
# Two test keys are forced to one CRC by a shim around zlib crc32. The shim answers only for keys
# that start with "testkey", so PNG chunk CRCs (raster::png) and every other key keep the real CRC.

set repo [file dirname [file dirname [file normalize [info script]]]]
lassign $argv work
if {$work eq ""} { set work [file join [pwd] raster-cache-test] }
file delete -force $work
file mkdir $work
wm withdraw .

source -encoding utf-8 [file join $repo srcpkgs ribbon-desktop files shell raster.tcl]
raster::init [file join $work cache]

set fails 0
proc ok {msg} { puts "  ok   $msg" }
proc fail {msg} { global fails; puts "  FAIL $msg"; incr fails }
proc check {cond msg} { if {$cond} { ok $msg } else { fail $msg } }

# ---- the shim: crc32 of a testkey value is the same constant -------------------------
rename ::zlib ::zlib_real
set ::collide 0xDEADBEEF
proc ::zlib {sub args} {
	if {$sub eq "crc32" && [string match testkey* [lindex $args 0]]} { return $::collide }
	return [::zlib_real $sub {*}$args]
}
set crc [format %08x [zlib crc32 {testkey red}]]
check [expr {$crc eq [format %08x [zlib crc32 {testkey blue}]]}] "the two test keys share one CRC ($crc)"
check [expr {[zlib crc32 {other key}] == [::zlib_real crc32 {other key}]}] "other keys keep the real CRC"

# ---- pictures: a 2 x 2 PNG of one colour, and the count of how often a script ran ------
proc solid {hex} {
	scan [string range $hex 1 end] %2x%2x%2x r g b
	set row [list $r $g $b 255 $r $g $b 255]
	raster::png 2 2 [list $row $row]
}
set runs 0
proc paint {hex} {
	global runs
	incr runs
	solid $hex
}
proc pixel {name} { lrange [$name get 0 0] 0 2 }

# ---- two keys, one CRC: each returns its own picture ---------------------------------------
set red [raster::cached {testkey red} {paint #ff0000}]
set blue [raster::cached {testkey blue} {paint #0000ff}]
check [expr {$red ne $blue}] "the two keys get two image names ($red, $blue)"
check [expr {$red eq "::raster::img$crc" && $blue eq "::raster::img$crc.1"}] "the second name is the CRC with .1 ($blue)"
check [expr {[pixel $red] eq {255 0 0}}] "the first key shows its own picture (red)"
check [expr {[pixel $blue] eq {0 0 255}}] "the second key, same CRC, shows its own picture (blue)"
check [expr {[raster::cached {testkey red} {paint #00ff00}] eq $red}] "a key already in memory is the same photo"
check [expr {$runs == 2}] "the scripts ran once per key ($runs runs)"

# ---- the disk entry holds the key of the last one written; another key misses -----------
set f [file join $work cache $crc.png]
check [file exists $f.key] "a sidecar key sits beside the disk entry"
check [raster::keyed $f {testkey blue}] "the sidecar holds the key written last (blue)"
# forget everything in memory, as a new run of the shell would
foreach n [image names] { if {[string match ::raster::* $n]} { image delete $n } }
set raster::keys {}
set runs 0
set again [raster::cached {testkey red} {paint #ff0000}]
check [expr {[pixel $again] eq {255 0 0}}] "after a restart, red is red again (the disk key was blue: a miss, rebuilt)"
check [expr {$runs == 1}] "that disk entry was rebuilt, once"

# ---- a valid disk entry is a hit: no script runs -----------------------------------------------
foreach n [image names] { if {[string match ::raster::* $n]} { image delete $n } }
set raster::keys {}
set runs 0
set hit [raster::cached {testkey red} {paint #ff00ff}]
check [expr {$runs == 0 && [pixel $hit] eq {255 0 0}}] "a valid disk entry is used without building it"

# ---- a corrupt or missing sidecar is a miss, and the entry is rewritten ---------------------
set fh [open $f.key wb]; puts -nonewline $fh "not the key"; close $fh
foreach n [image names] { if {[string match ::raster::* $n]} { image delete $n } }
set raster::keys {}
set runs 0
set bad [raster::cached {testkey red} {paint #ff0000}]
check [expr {$runs == 1 && [pixel $bad] eq {255 0 0}}] "a corrupt stored key is a miss: the picture is built again"
check [expr {[raster::keyed $f {testkey red}]}] "and the rewritten entry carries the right key"
file delete $f.key
foreach n [image names] { if {[string match ::raster::* $n]} { image delete $n } }
set raster::keys {}
set runs 0
set nokey [raster::cached {testkey red} {paint #ff0000}]
check [expr {$runs == 1}] "a missing sidecar is a miss too"

# ---- the C path: the same rules --------------------------------------------------------------
set cc [raster::cached_c {testkey green} {catch {%P put #00ff00 -to 0 0 2 2}}]
check [expr {[pixel $cc] eq {0 255 0}}] "cached_c draws its own picture (green, same CRC)"
foreach n [image names] { if {[string match ::raster::* $n]} { image delete $n } }
set raster::keys {}
set cc2 [raster::cached_c {testkey green} {catch {%P put #00ff00 -to 0 0 2 2}}]
check [expr {[pixel $cc2] eq {0 255 0}}] "cached_c reads its entry back from disk"

# ---- the real keys (no shim) still share one name for one key -------------------------------
rename ::zlib {}
rename ::zlib_real ::zlib
set a [raster::cached {plain key} {paint #123456}]
set b [raster::cached {plain key} {paint #123456}]
check [expr {$a eq $b}] "an ordinary key gives one photo"

# ---- the call sites: two keys, one CRC, each site returns its own picture -------------------
# Here every key but the PNG chunks' collides (the chunk CRCs stay real, or the PNGs are broken).
rename ::zlib ::zlib_real
proc ::zlib {sub args} {
	if {$sub eq "crc32"} {
		set s [lindex $args 0]
		if {[string match testkey* $s] || ![regexp {^(IHDR|IDAT|IEND)} $s]} { return $::collide }
	}
	return [::zlib_real $sub {*}$args]
}
namespace eval wall {}
namespace eval bg {}
set ::bgruns 0
set ::rowsruns 0
# wall::rows and bg::picture stand in for the wallpaper code: a solid picture (bg::picture: red for file A, else blue)
proc wall::rows {pal x0 y0 w h W H} {
	incr ::rowsruns
	array set c $pal
	set rgb [raster::rgb $c(DESK_TOP)]
	set row {}
	for {set x 0} {$x < $W} {incr x} { lappend row {*}$rgb 255 }
	lrepeat $H $row
}
proc bg::picture {file w h} {
	incr ::bgruns
	set fh [open $file rb]; set c [read $fh]; close $fh
	set p [image create photo -width $w -height $h]
	$p put [expr {$c eq "A" ? "#ff0000" : "#0000ff"}] -to 0 0 $w $h
	set p
}
proc auto_execok {cmd} { return "" }
proc px {img x y} { lrange [$img get $x $y] 0 2 }
proc sidecar_junk {f} { set fh [open $f.key wb]; puts -nonewline $fh "junk"; close $fh }
# forget the rbn photos (raster::cached keeps its own memo, which must stay in step with [image names])
proc keep_nothing {} { foreach n [image names] { if {[string match ::rbn::* $n]} { image delete $n } } }

source -encoding utf-8 [file join $repo srcpkgs ribbon-desktop files rbnalpha rbnalpha.tcl]
source -encoding utf-8 [file join $repo srcpkgs ribbon-desktop files appearance ui.tcl]
source -encoding utf-8 [file join $repo srcpkgs ribbon-desktop files appearance preview.tcl]
source -encoding utf-8 [file join $repo srcpkgs ribbon-desktop files appearance onstage.tcl]

# ui::desktop: the wallpaper cache (desk-CRC.png)
namespace eval theme {}
array set ui::c {bar #101010 pill #202020 field #303030 border #404040}
proc desk {hex} {
	array unset theme::c
	array set theme::c [list DESK_TOP $hex]
	ui::desktop 400 100
}
set da [desk #ff0000]
set db [desk #0000ff]
check [expr {[lindex [px $da 200 90] 0] > [lindex [px $da 200 90] 2]}] "ui::desktop: the first palette shows its own wallpaper (red)"
check [expr {[lindex [px $db 200 90] 2] > [lindex [px $db 200 90] 0]}] "ui::desktop: the second palette, same CRC, shows its own wallpaper (blue)"
set n $::rowsruns
set db2 [desk #0000ff]
check [expr {$::rowsruns == $n && [lindex [px $db2 200 90] 2] > [lindex [px $db2 200 90] 0]}] "ui::desktop: its own entry is a hit (no rebuild)"
array unset theme::c; array set theme::c {DESK_TOP #ff0000}
set key [list 3 [array get theme::c] 400 100]
set f [raster::keyed_path $raster::cachedir desk- $key]
sidecar_junk $f
set n $::rowsruns
set da2 [ui::desktop 400 100]
check [expr {$::rowsruns == $n + 1 && [lindex [px $da2 200 90] 0] > [lindex [px $da2 200 90] 2]}] "ui::desktop: a corrupt stored key is a miss, rebuilt"

# rbn::picture and rbn::look: the in-memory names (::rbn::pCRC, LCRC) and the disk entry
rbn::init [file join $work rbn]
set oa {-fill #ff0000 -radius 4}
set ob {-fill #0000ff -radius 4}
set na [lindex [rbn::picture 20 20 $oa] 0]
set nb [lindex [rbn::picture 20 20 $ob] 0]
check [expr {$na ne $nb}] "rbn::picture: two looks with one CRC get two names ($na, $nb)"
check [expr {[lindex [px $na 10 10] 0] > [lindex [px $na 10 10] 2]}] "rbn::picture: the first look shows its own box (red)"
check [expr {[lindex [px $nb 10 10] 2] > [lindex [px $nb 10 10] 0]}] "rbn::picture: the second look shows its own box (blue)"
set ka [rbn::look $oa]
set kb [rbn::look $ob]
check [expr {$ka ne $kb}] "rbn::look: two looks with one CRC get two keys ($ka, $kb)"
check [expr {[rbn::look $oa] eq $ka}] "rbn::look: the same options give the same key"
# a disk entry planted under A's key (blue) must not be given to a box with B's key (green)
keep_nothing
set og {-fill #00ff00 -radius 4}
set keyA [list rbn1 20 20 $oa]
set keyG [list rbn1 20 20 $og]
set fd [raster::keyed_path [rbn::dir] "" $keyA]
set blue [raster::png 20 20 [lrepeat 20 [string repeat "0 0 255 255 " 20]]]
set fh [open $fd wb]; puts -nonewline $fh $blue; close $fh
raster::store_key $fd $keyA
set ng [lindex [rbn::picture 20 20 $og] 0]
check [expr {[lindex [px $ng 10 10] 1] > [lindex [px $ng 10 10] 0]}] "rbn::picture: a box whose CRC matches another's disk entry is drawn itself (green)"
set nA [lindex [rbn::picture 20 20 $oa] 0]
check [expr {[lindex [px $nA 10 10] 2] > [lindex [px $nA 10 10] 0]}] "rbn::picture: its own disk entry is used (blue, planted)"
sidecar_junk $fd
keep_nothing
set nA2 [lindex [rbn::picture 20 20 $oa] 0]
check [expr {[lindex [px $nA2 10 10] 0] > [lindex [px $nA2 10 10] 2]}] "rbn::picture: a corrupt stored key is a miss, drawn again (red)"

# stage::screen (a pattern): preview's pattern cache, read at once as the callers do
set ::stage::W 20
set ::stage::H 20
set pa [stage::screen [list pattern {DESK_TOP #ff0000}]]
set ia [image create photo -file $pa -format png]
check [expr {[lindex [px $ia 5 5] 0] > [lindex [px $ia 5 5] 2]}] "preview pattern: the first palette shows its own picture (red)"
set pb [stage::screen [list pattern {DESK_TOP #0000ff}]]
set ib [image create photo -file $pb -format png]
check [expr {[lindex [px $ib 5 5] 2] > [lindex [px $ib 5 5] 0]}] "preview pattern: the second palette, same CRC, shows its own picture (blue)"
set n $::rowsruns
set ia2 [image create photo -file [stage::screen [list pattern {DESK_TOP #0000ff}]] -format png]
check [expr {$::rowsruns == $n && [lindex [px $ia2 5 5] 2] > [lindex [px $ia2 5 5] 0]}] "preview pattern: its own entry is a hit"
sidecar_junk [raster::keyed_path [stage::cachedir] pattern- [list {DESK_TOP #0000ff} 20 20]]
set n $::rowsruns
set ia3 [image create photo -file [stage::screen [list pattern {DESK_TOP #ff0000}]] -format png]
check [expr {$::rowsruns == $n + 1 && [lindex [px $ia3 5 5] 0] > [lindex [px $ia3 5 5] 2]}] "preview pattern: a corrupt stored key is a miss, drawn again"

# os::frame (video first frame; no ffmpeg here: the disk entry is all there is)
set fa [file join $work a.mp4]; set fb [file join $work b.mp4]
foreach {p txt} [list $fa A $fb B] { set fh [open $p wb]; puts -nonewline $fh $txt; close $fh }
set keyA "$fa [file mtime $fa]"
set keyB "$fb [file mtime $fb]"
check [expr {[zlib crc32 $keyA] == [zlib crc32 $keyB]}] "the two frame keys share one CRC"
set outA [raster::keyed_path [stage::cachedir] frame- $keyA]
set redpng [raster::png 2 2 [list [list 255 0 0 255 255 0 0 255] [list 255 0 0 255 255 0 0 255]]]
set fh [open $outA wb]; puts -nonewline $fh $redpng; close $fh
raster::store_key $outA $keyA
check [expr {[os::frame $fa] eq $outA}] "os::frame: A's own frame is used"
check [expr {[os::frame $fb] eq ""}] "os::frame: B, same CRC, is not given A's frame"
sidecar_junk $outA
catch {unset os::info(frame,$fa)}
check [expr {[os::frame $fa] eq ""}] "os::frame: a corrupt stored key is a miss (no frame)"

# os::thumb_png (the wallpaper thumbnails): read at once as the callers do
set ta [os::thumb_png $fa 4 4]
set tb [os::thumb_png $fb 4 4]
set ia [image create photo -data $ta -format png]
set ib [image create photo -data $tb -format png]
check [expr {[lindex [px $ia 0 0] 0] == 255 && [lindex [px $ia 0 0] 2] == 0 && [lindex [px $ib 0 0] 2] == 255}] "os::thumb_png: A and B (same CRC) each get their own thumbnail"
set n $::bgruns
set ta2 [os::thumb_png $fa 4 4]
check [expr {$::bgruns == $n + 1}] "os::thumb_png: the file holds B's key, so A is drawn again"
sidecar_junk [raster::keyed_path [stage::cachedir] thumb- "$fa [file mtime $fa] 4 4"]
set n $::bgruns
set ta3 [os::thumb_png $fa 4 4]
check [expr {$::bgruns == $n + 1}] "os::thumb_png: a corrupt stored key is a miss"

# restore the real CRC, as the top of this file has it
rename ::zlib {}
rename ::zlib_real ::zlib

puts [expr {$fails == 0 ? "raster-cache: all checks passed" : "raster-cache: $fails checks failed"}]
exit [expr {$fails > 0}]
