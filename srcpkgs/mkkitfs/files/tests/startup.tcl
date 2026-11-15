# startup.tcl -- how much later a small Tk app is on screen when it runs from its kit through
# mkkitfsd than when it runs bare, from plain files (KIT.md, phase 1: "a Ribbon-built kit of a small
# GUI app that starts within a few ms of running it bare").
#
#   xvfb-run -a tclsh startup.tcl MKKITFS KIT EXTRACTED_DIR WORKDIR ?runs? ?budget-ms?
#
# Each run is what `kit run` does: connect to the session's socket, mount the kit (signature and all
# checks), start `wish main.tcl` from the mount, wait until the window has been drawn and the app
# has exited, unmount, close.  Medians of `runs` runs (default 15):
#   bare            wish EXTRACTED_DIR/main.tcl
#   kit, warm       the kit still mounted (another reference, or lingering): the usual case
#   kit, fresh      a kit nobody has mounted yet: parse in a child, then serve, all page caches of
#                   the mount cold (the kit file itself in the page cache)
# Fails if "kit, warm" is more than budget-ms (default 25) over bare.
lassign $argv exe kitfile ext work runs budget
if {$runs eq ""} { set runs 15 }
if {$budget eq ""} { set budget 25 }
set here [file dirname [file normalize [info script]]]
set tcldir [file join [file dirname $here] tcl]
lappend auto_path $tcldir
package require mkkitfs
set wish [lindex [concat [auto_execok wish] [auto_execok wish[info tclversion]]] 0]

set sock $work/s
set env(MKKITFS) $exe
exec [info nameofexecutable] $tcldir/mkkitfsd serve -socket $sock -mountpoint $work/mnt -linger 0 -log $work/log 2>@stderr &
for {set i 0} {$i < 500} {incr i} { if {![catch {mkkitfs::connect -socket $sock -start 0} c]} break ; after 10 }

proc us {script} { set t [clock microseconds] ; uplevel 1 $script ; return [expr {[clock microseconds] - $t}] }
proc median {l} { set l [lsort -integer $l] ; return [lindex $l [expr {[llength $l] / 2}]] }
proc ms {x} { format %.1f [expr {$x / 1000.0}] }

# one `kit run`, start to exit
proc kitRun {} {
    global sock kitfile wish
    set c [mkkitfs::connect -socket $sock -start 0]
    set k [mkkitfs::mount $c $kitfile]
    exec $wish [dict get $k dir]/main.tcl
    mkkitfs::unmount $c [dict get $k id]
    close $c
}

# warm-up of both (fonts, the X server, wish itself)
exec $wish $ext/main.tcl
set holder [mkkitfs::connect -socket $sock -start 0]
set held [mkkitfs::mount $holder $kitfile]
kitRun

set bare {} ; set warm {} ; set fresh {} ; set mountWarm {} ; set mountFresh {}
for {set i 0} {$i < $runs} {incr i} {
    lappend bare [us { exec $wish $ext/main.tcl }]
    lappend warm [us { kitRun }]
    set c [mkkitfs::connect -socket $sock -start 0]
    lappend mountWarm [us { set k [mkkitfs::mount $c $kitfile] }]
    mkkitfs::unmount $c [dict get $k id]
    close $c
}
# fresh: nobody holds the kit, so each run mounts it anew (linger 0)
mkkitfs::unmount $holder [dict get $held id] -now 1
for {set i 0} {$i < $runs} {incr i} {
    lappend fresh [us { kitRun }]
    set c [mkkitfs::connect -socket $sock -start 0]
    lappend mountFresh [us { set k [mkkitfs::mount $c $kitfile] }]
    mkkitfs::unmount $c [dict get $k id] -now 1
    close $c
}
catch {mkkitfs::Request $holder quit}

set b [median $bare] ; set w [median $warm] ; set f [median $fresh]
puts "  info start-up of a small Tk app (median of $runs): bare [ms $b] ms, from its kit warm [ms $w] ms (+[ms [expr {$w - $b}]]), fresh [ms $f] ms (+[ms [expr {$f - $b}]])"
puts "  info   the mount request alone: [ms [median $mountWarm]] ms with the kit mounted, [ms [median $mountFresh]] ms for a kit not yet mounted (checked in a child first)"
if {$w - $b > $budget * 1000} {
    puts "  FAIL start-up through mkkitfsd is more than $budget ms over bare"
    exit 1
}
puts "  ok   start-up from the kit is within $budget ms of bare"
exit 0
