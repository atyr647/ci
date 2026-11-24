# tests/mkkitfs-limits.tcl -- mkkitfs's reader refuses a kit whose paths are over the limits BEFORE it builds them
# (a few-megabyte kit with a 63-deep chain of 255-byte directory names and many leaf directories used to make the
# reader build a ~16 KB path string for each leaf, twice over: gigabytes from a tiny file, in the isolated first parse),
# and `mkkitfs extract` refuses a symlink chain that leaves the destination (a link into a link that points up).
# Needs mkkitfs (MKKITFS or on the PATH), Mk4tcl (KITFMT_MK4TCL) and /usr/bin/time; skips without them.
#   KITFMT_MK4TCL=DIR tclsh8.6 -encoding utf-8 tests/mkkitfs-limits.tcl
set top [file dirname [file dirname [file normalize [info script]]]]
set tclsh [info nameofexecutable]
encoding system utf-8
fconfigure stdout -encoding utf-8
set fails 0
proc ok {name cond {detail ""}} {
    if {$cond} { puts "  ok   $name" } else { puts "  FAIL $name" ; if {$detail ne ""} { puts "       [string range $detail 0 1500]" } ; incr ::fails }
}
set mk4 [expr {[info exists env(KITFMT_MK4TCL)] ? $env(KITFMT_MK4TCL) : ""}]
set engine [expr {[info exists env(MKKITFS)] && $env(MKKITFS) ne "" ? $env(MKKITFS) : [lindex [auto_execok mkkitfs] 0]}]
if {$engine eq "" || [file executable /usr/bin/time] == 0 || [catch {exec $tclsh << "lappend auto_path {$mk4}; package require Mk4tcl"}]} {
    puts "  skip mkkitfs's limits (no mkkitfs, /usr/bin/time or Mk4tcl: KITFMT_MK4TCL)" ; exit 0
}
set W [file normalize [exec mktemp -d]]
set bad $W/deep.kit
file copy $top/kit/kitfmt/tests/golden/app.kit $bad

# the damaged copy: the directory view gets a chain of 63 directories with 255-byte names, then NLEAF one-byte leaves under
# the deepest (each leaf's path is ~16 KB: far over the 4096-byte limit)
set NLEAF 30000
exec $tclsh << "
lappend auto_path {$mk4}
package require Mk4tcl
mk::file open db {$bad}
set n \[mk::view size db.dirs\]
set parent 0
for {set i 0} {\$i < 63} {incr i} {
    set name \[string repeat \[format %c \[expr {97 + \$i % 26}\]\] 255\]
    set row \[mk::row append db.dirs name \$name parent \$parent mode 493\]
    set parent \[expr {\[mk::view size db.dirs\] - 1}\]
}
for {set i 0} {\$i < $NLEAF} {incr i} { mk::row append db.dirs name x parent \$parent mode 493 }
mk::file commit db
mk::file close db
"
proc measure {args} {
    set code 0
    if {[catch {exec /usr/bin/time -f "RSS %M" {*}$args 2>@1} out opts]} {
        set ec [dict get $opts -errorcode]
        set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : "error"}]
    }
    regexp {RSS ([0-9]+)} $out -> kb
    list $code $out [expr {[info exists kb] ? $kb : -1}]
}
lassign [measure $engine open --force $bad] code out kb
ok "the deep, wide kit is refused with a LIMIT, not accepted" [expr {$code == 1 && [string match "*open fail LIMIT*" $out]}] $out
ok "  with the reader's memory in the tens of megabytes (RSS ${kb} kB), not the gigabytes the paths would take" [expr {$kb > 0 && $kb < 200000}] $out

# the golden kit still opens (the limits are not tighter than before for ordinary kits)
lassign [measure $engine open --force $top/kit/kitfmt/tests/golden/app.kit] code out kb
ok "an ordinary kit still opens" [expr {$code == 0 && [string match "*open ok*" $out]}] $out

# ---- extract and symlink chains: a copy of the golden kit gets a directory a and links (the kit's root hash is then
# wrong, so these go through --force, which skips the root check; the link check is what is tested)
proc linkkit {name links} {
    # links: {dirrow path name target ...}: rows of links in the files view of the root (row 0) or of directory row 1
    set f $::W/$name.kit
    file copy $::top/kit/kitfmt/tests/golden/app.kit $f
    exec $::tclsh << "
lappend auto_path {$::mk4}
package require Mk4tcl
mk::file open db {$f}
mk::row append db.dirs name a parent 0 mode 493
set a \[expr {\[mk::view size db.dirs\] - 1}\]
foreach {where lname target} {$links} {
    set v \[expr {\$where eq {root} ? {db.dirs!0.files} : \"db.dirs!\$a.files\"}\]
    mk::row append \$v name \$lname link \$target mode 511 size 0 fsize 0 date 0 codec {} csize 0 hash {}
}
mk::file commit db
mk::file close db
"
    return $f
}
proc extract {kitfile} {
    set dest $::W/out-[file tail $kitfile]
    file mkdir $dest
    set code 0
    if {[catch {exec $::engine extract --force $kitfile $dest 2>@1} out opts]} {
        set ec [dict get $opts -errorcode]
        set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : "error"}]
    }
    list $code $out
}
# a/l -> .. is inside by its own count (a's parent is the root), and l2 -> a/l/.. walks out through a/l
lassign [extract [linkkit chain {a l .. root l2 a/l/..}]] code out
ok "a link that leaves through another link of the archive is refused (exit 1, PATH)" [expr {$code == 1 && [string match "*extract fail PATH*" $out]}] $out
lassign [extract [linkkit plain {a up .. root self a/up/a}]] code out
ok "ordinary links inside the tree extract (a/up -> .., self -> a/up/a is the directory a again)" [expr {$code == 0}] $out
lassign [extract [linkkit abs {root x /etc}]] code out
ok "an absolute target is refused" [expr {$code == 1 && [string match "*extract fail PATH*" $out]}] $out
lassign [extract [linkkit up {root x ..}]] code out
ok "a link out of the root is refused" [expr {$code == 1 && [string match "*extract fail PATH*" $out]}] $out
lassign [extract [linkkit loop {root p q root q p}]] code out
ok "a link loop does not hang the check (it can never resolve, so it cannot leave)" [expr {$code == 0}] $out

file delete -force $W
if {$fails} { puts "mkkitfs limits: $fails checks failed" ; exit 1 }
puts "mkkitfs limits: all checks passed"
