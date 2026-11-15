# kit-mount.tcl -- srcpkgs/ribbon-kit/files/lib/mount.tcl: system kits as one merged erofs /usr view and
# its atomic live switch (D57 C, D58 B; SYSTEM-UPDATES.md 8.3).  Run as root in a private mount namespace
# (tests/steps.d/74-kit-mount.sh does: unshare -m --propagation private).
#
# Three system kits are packed with kitpack around plain erofs images (base, foo 1, tools); the view over
# them is built and moved onto a target directory; a process holds a file, a mapping-like open fd and its
# cwd in it; foo 2 replaces foo 1 by a live switch while another process stats a path in a tight loop.
# Checked: the new view is what every new lookup sees, the path never vanished during the switch, the
# holder keeps the old bytes, the old view's loop devices go when the holder does, the state files
# (.devices, current, pruning), restore after an unmount, refusals (wrong root, app kit, a kit twice,
# erofs-utils older than the floor) leave the view as it was.
#
#   KITFMT_MK4TCL=<dir with Mk4tcl>  KIT_SWAPMOUNT=<built kit-swapmount>  tclsh tests/kit-mount.tcl
set top [file normalize [file join [file dirname [info script]] ..]]
set fail 0
proc check {desc cond {detail ""}} {
    if {[uplevel 1 [list expr $cond]]} { puts "  ok   $desc" ; return }
    puts "  FAIL $desc" ; set ::fail 1
    if {$detail ne ""} { foreach l [split [string trimright $detail] \n] { puts "       | $l" } }
}
proc skip {why} { puts "  skip merged /usr view ($why)" ; exit 0 }
proc slurp {p} { set f [open $p rb] ; set d [read $f] ; close $f ; return $d }
proc spit {p d} { file mkdir [file dirname $p] ; set f [open $p wb] ; puts -nonewline $f $d ; close $f }
proc waitFor {ms cond} {
    for {set t 0} {$t < $ms} {incr t 20} { if {[uplevel 1 [list expr $cond]]} { return 1 } ; after 20 }
    return [uplevel 1 [list expr $cond]]
}
proc errOf {script} { if {[catch {uplevel 1 $script} m]} { return $m } ; return "" }

if {[exec id -u] != 0} { skip "needs root" }
if {[catch {exec grep -qw erofs /proc/filesystems}]} { skip "the kernel has no erofs" }
foreach t {losetup mount umount mountpoint mkfs.erofs} { if {[auto_execok $t] eq ""} { skip "no $t" } }
if {![info exists env(KIT_SWAPMOUNT)] || ![file executable $env(KIT_SWAPMOUNT)]} { skip "no kit-swapmount (KIT_SWAPMOUNT)" }
# kits with a verity root: kitfmt's statement parser refuses an image line without one (salt "-")
if {[auto_execok veritysetup] eq ""} { skip "kitpack -verity yes needs veritysetup" }
if {![info exists env(KITFMT_MK4TCL)] || $env(KITFMT_MK4TCL) eq ""} { skip "kitpack needs Mk4tcl: set KITFMT_MK4TCL" }

set T [file normalize [exec mktemp -d]]
set env(KIT_USR_VIEWS) $T/state
set env(KIT_NOSYNC) 1
source -encoding utf-8 $top/srcpkgs/ribbon-kit/files/lib/core.tcl
source -encoding utf-8 $top/srcpkgs/ribbon-kit/files/lib/mount.tcl
set tclsh [info nameofexecutable]
set usr $T/usr
file mkdir $usr

# ---- the kits ---------------------------------------------------------------------------------
proc kit {name version files} {
    global T tclsh top env
    set src $T/src/$name-$version
    foreach {p d} $files {
        if {[string match ->* $d]} { file mkdir [file dirname $src/$p] ; exec ln -s [string range $d 2 end] $src/$p } \
        else { spit $src/$p $d }
    }
    # plain (uncompressed) images, as D57 C needs: data blocks the metadata image can point into
    exec mkfs.erofs -Enoinline_data -T0 --all-root $T/$name-$version.erofs $src >/dev/null 2>@1
    spit $T/$name-$version.manifest "name org.test.$name version $version kind system summary {$name} license MIT"
    file mkdir $T/empty
    exec $tclsh $top/kit/kitfmt/kitpack -q -mk4tcl $env(KITFMT_MK4TCL) -manifest $T/$name-$version.manifest \
        -image $T/$name-$version.erofs -verity yes $T/empty $T/$name-$version.kit 2>@1
    set root [dict get [::kitfmt::Frame $T/$name-$version.kit] st root]
    return [list $T/$name-$version.kit $root]
}
::kit::mount::LoadKitfmt
if {[catch {
    set base [kit base 1 {bin/sh "base sh\n" lib/libc.so.6 "libc\n" share/doc/base "doc\n"}]
    set foo1 [kit foo 1 {lib/libfoo.so.1 "foo v1\n" lib/libfoo.so ->libfoo.so.1}]
    set foo2 [kit foo 2 {lib/libfoo.so.1 "foo v2\n" lib/libfoo.so.2 "foo v2 abi 2\n" lib/libfoo.so ->libfoo.so.2}]
    set tools [kit tools 1 {bin/tool "tool v1\n"}]
} e]} { puts "  FAIL making the test kits: $e" ; exit 1 }

proc loopsOf {kit} {
    set out [string trim [exec losetup -j [lindex $kit 0]]]
    return [expr {$out eq "" ? 0 : [llength [split $out \n]]}]
}
proc devOf {p} { file stat $p s ; return $s(dev) }

# ---- the floor: erofs-utils 1.9 (D68) -----------------------------------------------------------
lassign [::kit::mount::ErofsVersion] ma mi
set e [errOf {::kit::mount::build [list $base $foo1 $tools] $T/gate.erofs}]
if {$ma < 1 || ($ma == 1 && $mi < 9)} {
    check "erofs-utils older than 1.9 is refused (D68): $e" {[string match "*erofs-utils 1.9 or later*" $e] && ![file exists $T/gate.erofs]}
    puts "  info mkfs.erofs here is [expr {$ma ? "$ma.$mi" : "older than 1.8"}]: the rest runs with KIT_EROFS_MIN=1.7 (plain images, no xattrs)"
    set env(KIT_EROFS_MIN) 1.7
} else {
    check "erofs-utils $ma.$mi builds a view" {$e eq "" && [file exists $T/gate.erofs]} $e
}

# ---- refusals: nothing is built, nothing changes ----------------------------------------------
set e [errOf {::kit::mount::kits [list [list [lindex $foo1 0] [lindex $foo2 1]]]}]
check "a kit whose seal doesn't name the installed root is refused" {[string match "*not the installed*" $e]} $e
set e [errOf {::kit::mount::kits [list [list $top/kit/kitfmt/tests/golden/app.kit x]]}]
check "an app kit is refused" {[string match "*not a system kit*" $e]} $e
set e [errOf {::kit::mount::kits [list $foo1 $foo2]}]
check "one kit twice in a view is refused" {[string match "*in the view twice*" $e]} $e

# ---- the first view ---------------------------------------------------------------------------
set e [errOf {set r [::kit::mount::activate [list $base $foo1 $tools] $usr]}]
check "the first view is mounted on the target" {$e eq "" && ![catch {exec mountpoint -q $usr}]} $e
check "it shows every kit's files" {[slurp $usr/bin/sh] eq "base sh\n" && [slurp $usr/lib/libfoo.so.1] eq "foo v1\n" \
    && [slurp $usr/bin/tool] eq "tool v1\n" && [file readlink $usr/lib/libfoo.so] eq "libfoo.so.1"}
check "the view is read-only" {[catch {spit $usr/bin/new x}]}
set dev [slurp $T/state/view-1.erofs.devices]
check "view-1.devices lists the kits in order, plain text" {[lindex [split $dev \n] 0] eq "ribbon-usr-view 1" \
    && [llength [split [string trim $dev] \n]] == 4 && [lindex [split [lindex [split $dev \n] 2] \t] 1] eq [lindex $foo1 0]} $dev
check "current is 1" {[string trim [slurp $T/state/current]] eq "1"}
check "each kit's image is one loop device, held by the mount alone (autoclear)" {[loopsOf $foo1] == 1 && [loopsOf $tools] == 1}

# ---- a holder in the old view, a watcher on a path, then the live switch ------------------------
spit $T/holder.tcl {
    set f [open [lindex $argv 0]/lib/libfoo.so.1 r]
    cd [lindex $argv 0]/lib
    puts ready ; flush stdout
    while {[gets stdin cmd] >= 0} {
        switch -- $cmd {
            fd { seek $f 0 ; puts [string trim [read $f]] }
            cwd { set g [open libfoo.so.1 r] ; puts [string trim [read $g]] ; close $g }
            abs { set g [open [lindex $argv 0]/lib/libfoo.so.1 r] ; puts [string trim [read $g]] ; close $g }
            quit { exit 0 }
        }
        flush stdout
    }
}
set holder [open |[list $tclsh $T/holder.tcl $usr] r+]
fconfigure $holder -buffering line
gets $holder
proc ask {cmd} { puts $::holder $cmd ; gets $::holder line ; return $line }
check "the holder reads foo v1" {[ask fd] eq "foo v1"}
set watcher [open |[list sh -c "while :; do \[ -e $usr/bin/tool \] && \[ -e $usr/lib/libfoo.so.1 \] || echo MISSING; done"] r]
fconfigure $watcher -blocking 0
after 100
set old [devOf $usr]
set e [errOf {set r [::kit::mount::activate [list $base $foo2 $tools] $usr]}]
after 100
exec kill [pid $watcher]
set missing [regexp -all MISSING [read $watcher]]
catch {close $watcher}
check "the live switch to foo 2" {$e eq "" && [dict get $r view] == 2} $e
check "every new lookup sees the new view" {[devOf $usr] != $old && [slurp $usr/lib/libfoo.so.1] eq "foo v2\n" \
    && [slurp $usr/lib/libfoo.so.2] eq "foo v2 abi 2\n" && [file readlink $usr/lib/libfoo.so] eq "libfoo.so.2" && [slurp $usr/bin/tool] eq "tool v1\n"}
check "the paths never vanished during the switch (watched in a tight loop)" {$missing == 0} "$missing misses"
check "one mount at the target: the old view was detached, not stacked" \
    {[llength [lsearch -all -exact [lmap l [split [slurp /proc/self/mounts] \n] {lindex $l 1}] $usr]] == 1}
check "the holder's open file still reads foo v1" {[ask fd] eq "foo v1"}
check "the holder's cwd is still in the old view" {[ask cwd] eq "foo v1"}
check "the holder opening the absolute path gets foo v2" {[ask abs] eq "foo v2"}
check "the old view's foo 1 image stays attached while the holder uses it" {[loopsOf $foo1] == 1}
puts $holder quit ; catch {close $holder}
check "the holder gone: the old view and its loop devices go with it" {[waitFor 5000 {[loopsOf $foo1] == 0}]}
check "current is 2" {[string trim [slurp $T/state/current]] eq "2"}

# ---- a refused switch changes nothing ----------------------------------------------------------
set before [devOf $usr]
set e [errOf {::kit::mount::activate [list $base [list [lindex $foo1 0] [lindex $foo2 1]] $tools] $usr}]
check "a switch with a wrong root is refused, and /usr stays as it was" {$e ne "" && [devOf $usr] == $before \
    && [string trim [slurp $T/state/current]] eq "2" && ![file exists $T/state/view-3.erofs]} $e

# ---- pruning, restore ---------------------------------------------------------------------------
set e [errOf {::kit::mount::activate [list $base $foo1 $tools] $usr}]
check "a third view (back to foo 1, as a rewind would)" {$e eq "" && [slurp $usr/lib/libfoo.so.1] eq "foo v1\n"} $e
check "views older than the one before are pruned" {![file exists $T/state/view-1.erofs] && [file exists $T/state/view-2.erofs] \
    && [file exists $T/state/view-3.erofs] && ![file exists $T/state/view-1.erofs.devices]}
exec umount -l $usr
check "unmounted (as after a reboot)" {[catch {exec mountpoint -q $usr}]}
set e [errOf {::kit::mount::restore $usr}]
check "restore mounts the current view again" {$e eq "" && [slurp $usr/lib/libfoo.so.1] eq "foo v1\n" && [slurp $usr/bin/tool] eq "tool v1\n"} $e

exec umount -l $usr
foreach k [list $base $foo1 $foo2 $tools] { waitFor 2000 {[loopsOf $k] == 0} }
set left 0
foreach k [list $base $foo1 $foo2 $tools] { incr left [loopsOf $k] }
check "no loop device left behind" {$left == 0}
file delete -force $T
exit $fail
