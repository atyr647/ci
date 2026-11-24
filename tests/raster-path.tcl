# raster-path.tcl - shell/raster.tcl's SVG path reader: S/s (the smooth cubic, which icons such as the eye and the bell
# use) must draw what the same curve spelt with C draws.
#   tclsh8.6 tests/raster-path.tcl shell/raster.tcl
source [lindex $argv 0]
proc near {a b} { set a [concat {*}$a]; set b [concat {*}$b]; if {[llength $a] != [llength $b]} { return 0 }; foreach p $a q $b { if {abs($p-$q) > 1e-9} { return 0 } }; return 1 }
set bad 0
foreach {what s c} {
	"eye, relative s"   {M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7z} {M2 12C2 12 5.5 5 12 5C18.5 5 22 12 22 12C22 12 18.5 19 12 19C5.5 19 2 12 2 12z}
	"absolute S"        {M0 0C1 2 3 2 4 0S7 -2 8 0} {M0 0C1 2 3 2 4 0C5 -2 7 -2 8 0}
	"S after a line"    {M0 0L4 0S7 -2 8 0} {M0 0L4 0C4 0 7 -2 8 0}
	"bell, h then s"    {M6 8c0 7-3 9-3 9h18s-3-2-3-9} {M6 8c0 7-3 9-3 9h18C21 17 18 15 18 8}
} {
	set ok [near [raster::path $s] [raster::path $c]]
	puts "[expr {$ok ? "  ok  " : "  FAIL"}] raster::path: $what"; if {!$ok} { set bad 1 }
}

# the cache without raster::init: under $XDG_CACHE_HOME/ribbon/raster, never in the directory the program runs in
package require Tk
wm withdraw .
set wd [file normalize [file join [pwd] .raster-wd-[pid]]]; set ch [file normalize [file join [pwd] .raster-ch-[pid]]]
file mkdir $wd $ch
set ::env(XDG_CACHE_HOME) $ch
cd $wd
set raster::cachedir ""
set img [raster::icon {M4 17l6-6-6-6} 22 1.7 #ffffff {} 0 0 0]
set inwd [glob -nocomplain -directory $wd *]
set inch [glob -nocomplain -directory [file join $ch ribbon raster] *.png]
cd ..
file delete -force $wd $ch
set ok [expr {$inwd eq {} && [llength $inch] == 1}]
puts "[expr {$ok ? "  ok  " : "  FAIL"}] raster: without init the cache is \$XDG_CACHE_HOME/ribbon/raster, not the working directory"
if {!$ok} { puts "       in the working directory: $inwd; in the cache: $inch"; set bad 1 }
exit $bad
