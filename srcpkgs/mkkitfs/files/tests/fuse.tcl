# fuse.tcl -- mkkitfsd + mkkitfs through a real FUSE mount, driven through the control socket.
#
#   tclsh fuse.tcl MKKITFS GOLDEN_DIR KEYFILE WORKDIR
#
# The golden kits served through the mount must show what their .expect files list (types, modes,
# sizes, link targets, content hashes); the damaged ones are refused at mount with the codes of
# kitfmt; bad-chunk.kit mounts, its chunk 1 reads as EIO (and is logged), its other chunks read;
# references follow connections, keep, linger and unmount.  Prints "ok ..." lines, exits 1 on failure.
lassign $argv exe gold keyfile work
set here [file dirname [file normalize [info script]]]
set tcldir [file join [file dirname $here] tcl]
lappend auto_path $tcldir
package require mkkitfs
encoding system utf-8

set failures 0
proc check {what cond {detail ""}} {
    if {$cond} { puts "  ok   $what" } else { puts "  FAIL $what $detail" ; incr ::failures }
}
proc errcode {script} {
    if {![catch {uplevel 1 $script} r opts]} { return ok }
    set ec [dict get $opts -errorcode]
    return [expr {[lindex $ec 0] eq "MKKITFS" ? [lindex $ec 1] : "ERROR: $r"}]
}
proc slurp {f} { set ch [open $f rb] ; set d [read $ch] ; close $ch ; return $d }

set key [lindex [split [string trim [slurp $keyfile]] \n] 1]
set sock $work/kit/mkkitfs.sock
set mnt $work/kit/mnt
set log $work/server.log
file mkdir $work/kit
set env(MKKITFS) $exe
set conf $work/mkkitfs.conf
set ch [open $conf w] ; puts $ch "linger 0\nisolate 1\ncache 8" ; close $ch
set conf_file $conf
set pid [exec [info nameofexecutable] $tcldir/mkkitfsd serve -socket $sock -mountpoint $mnt -config $conf -log $log 2>>$log &]
set c ""
for {set i 0} {$i < 500 && $c eq ""} {incr i} { if {[catch {mkkitfs::connect -socket $sock -start 0} c]} { set c "" ; after 10 } }
if {$c eq ""} { puts "  FAIL the server did not start: [slurp $log]" ; exit 1 }
check "mkkitfsd answers on its socket" [dict exists [mkkitfs::status $c] mountpoint]

# ---- the valid golden kits, through the mount, against their .expect --------------------------------
proc expectEntries {name} {
    set out {}
    set ch [open $::gold/$name.expect r] ; fconfigure $ch -encoding utf-8
    foreach line [split [read $ch] \n] { if {[string match "entry *" $line]} { lappend out [lrange $line 1 end] } }
    close $ch
    return $out
}
proc walk {dir {pre ""}} {
    set out {}
    foreach f [lsort [glob -nocomplain -tails -directory $dir -types {d f l} * .*]] {
        if {$f in {. ..}} continue
        set p [expr {$pre eq "" ? $f : "$pre/$f"}]
        lappend out $p
        if {[file type $dir/$f] eq "directory"} { lappend out {*}[walk $dir/$f $p] }
    }
    return $out
}
proc served {dir} {
    set out {}
    foreach p [lsort [walk $dir]] {
        file lstat $dir/$p st
        set mode [expr {$st(mode) & 0777}]
        switch -- $st(type) {
            directory { lappend out [list $p dir $mode] }
            link { lappend out [list $p link $mode [file readlink $dir/$p]] }
            file {
                set hx [lindex [exec sha256sum $dir/$p] 0]
                lappend out [list $p file $mode $st(size) $hx]
            }
        }
    }
    return $out
}
foreach name {app app-header system} {
    set k [mkkitfs::mount $c $gold/$name.kit -keys [list $key]]
    set want {}
    foreach e [expectEntries $name] {
        if {[lindex $e 1] eq "file"} { lappend want [list [lindex $e 0] file [lindex $e 2] [lindex $e 3] [lindex $e 7]] } else { lappend want $e }
    }
    set got [served [dict get $k dir]]
    check "$name.kit served as its .expect lists ([llength $got] entries, signature [dict get $k signature])" [expr {$got eq $want}] "\n want $want\n got  $got"
}
set k [mkkitfs::mount $c $gold/app.kit]
check "the same file again: one mount, two references" [expr {[dict get $k cached] == 1 && [dict get $k refs] == 2}] $k
set d [dict get $k dir]
check "stat: mode, size, mtime and block size" [expr {[file attributes $d/bin/hello -permissions] eq "00755" && [file size $d/lib/big.txt] == 46342 && [file mtime $d/lib/big.txt] == 1700000000}]
check "a symlink reads as one" [expr {[file readlink $d/lib/hello-link] eq "../bin/hello" && [slurp $d/lib/hello-link] eq [slurp $d/bin/hello]}]
check "a file is not writable (read-only mount)" [expr {[catch {open $d/main.tcl w} e] && [string match -nocase "*read-only*" $e]}] $e
check "names that are not in the kit: ENOENT" [expr {![file exists $d/nope] && ![file exists $d/lib/nope]}]
set whole [slurp $d/lib/big.txt]
set ok 1
foreach {off len} {0 1 16383 2 16384 16384 16000 20000 30000 100000 46341 1} {
    set ch [open $d/lib/big.txt rb] ; seek $ch $off ; set part [read $ch $len] ; close $ch
    if {$part ne [string range $whole $off [expr {$off + $len - 1}]]} { set ok 0 }
}
check "reads across chunk boundaries" $ok
check "a classic file and an empty file" [expr {[string match "*hello from main.tcl*" [slurp $d/main.tcl]] && [file size $d/empty] == 0}]
check "xattrs: none (the format has none)" [expr {[catch {exec getfattr -d $d/main.tcl 2>@1} r] || ![string match "*user.*" $r]}]

# ---- damaged kits are refused at mount, as kitfmt refuses them ----------------------------------------------
foreach {name want} {truncated TRUNCATED wrong-version VERSION unknown-feature FEATURE bad-name PATH bad-root ROOT} {
    check "$name.kit refused: $want" [expr {[errcode {mkkitfs::mount $c $gold/$name.kit}] eq $want}] [errcode {mkkitfs::mount $c $gold/$name.kit}]
}
check "bad-signature.kit with -signed 1: SIGNATURE (before Metakit parses)" [expr {[errcode {mkkitfs::mount $c $gold/bad-signature.kit -signed 1 -keys [list $key]}] eq "SIGNATURE"}]
check "app-header.kit (unsigned) with -signed 1: SIGNATURE" [expr {[errcode {mkkitfs::mount $c $gold/app-header.kit -signed 1 -keys [list $key]}] eq "SIGNATURE"}]
set k [mkkitfs::mount $c $gold/bad-signature.kit -keys [list $key]]
check "bad-signature.kit without -signed: served, signature invalid" [expr {[dict get $k signature] eq "invalid"}]
check "not a kit at all: NOTKIT/TRUNCATED" [expr {[errcode {mkkitfs::mount $c $gold/app.expect}] in {NOTKIT TRUNCATED}}]

set k [mkkitfs::mount $c $gold/bad-chunk.kit]
set d [dict get $k dir]
set ch [open $d/lib/big.txt rb] ; set first [read $ch 16384] ; close $ch
check "bad-chunk.kit: chunk 0 reads" [expr {[string length $first] == 16384}]
set ch [open $d/lib/big.txt rb] ; seek $ch 16384
set r [catch {read $ch 100} e] ; catch {close $ch}
check "bad-chunk.kit: chunk 1 is an error (EIO), never data" [expr {$r && ([string match -nocase "*input/output*" $e] || [string match "*I/O error*" $e])}] $e
set ch [open $d/lib/big.txt rb] ; seek $ch 32768 ; set third [read $ch] ; close $ch
check "bad-chunk.kit: chunk 2 reads" [expr {[string length $third] == 46342 - 32768}]
after 100
check "the bad chunk is logged" [regexp {bad chunk: kit org.ribbon.golden.app-1.2.0-[0-9]+ \([^)]*bad-chunk.kit\) lib/big.txt chunk 1: HASH} [slurp $log]]
set k [mkkitfs::mount $c $gold/bad-image.kit]
check "bad-image.kit: served (its image is not mkkitfs's to serve; verify fails on it)" [file exists [dict get $k dir]/share/doc/README]

# ---- references -----------------------------------------------------------------------------------------------
set c2 [mkkitfs::connect -socket $sock -start 0]
set k2 [mkkitfs::mount $c2 $gold/system.kit]
set sysdir [dict get $k2 dir]
close $c2
after 300
proc refsOf {c name} {
    foreach x [mkkitfs::kits $c] { if {[dict get $x name] eq $name} { return [dict get $x refs] } }
    return 0
}
check "a closed connection drops its references (system.kit back to 1: ours)" [expr {[refsOf $c org.ribbon.golden.base] == 1}]
set kk [mkkitfs::mount $c $gold/app-header.kit -keep 1]
set r [mkkitfs::unmount $c $gold/app-header.kit]
check "unmount by path" [expr {[dict get $r refs] == 1}] $r
check "unmount of what is not mounted: NOENT" [expr {[errcode {mkkitfs::unmount $c $gold/truncated.kit}] eq "NOENT"}]
set idsys [file tail $sysdir]
mkkitfs::unmount $c $idsys
after 300
check "the last reference gone (linger 0): the kit leaves the mount point" [expr {![file exists $sysdir]}]
close $c
after 500
set c [mkkitfs::connect -socket $sock -start 0]
set left [mkkitfs::kits $c]
check "closing the connection unmounts what it held; a keep reference stays" \
    [expr {[llength $left] == 1 && [dict get [lindex $left 0] keep] == 1}] $left
set st [mkkitfs::status $c]
puts "  info server: [dict get $st reads] reads, [dict get $st misses] cache misses, [dict get $st hits] hits, [dict get $st bad-reads] bad reads"
# the data path parses kits confined (src/confine.cpp): seccomp in filter mode, no_new_privs, and a
# Landlock domain where the kernel has Landlock
set epid [dict get $st pid]
set conf [expr {[dict exists $st confined] ? [dict get $st confined] : "(not reported)"}]
set pst [slurp /proc/$epid/status]
check "the data path is confined: $conf" [expr {[string match seccomp* $conf] && [regexp -line {^Seccomp:\s+2$} $pst] \
    && [regexp -line {^NoNewPrivs:\s+1$} $pst]}] $conf
if {![catch {exec grep -qw landlock /sys/kernel/security/lsm}]} {
    check "the data path is in a Landlock domain" [string match "* landlock-*" $conf] $conf
}
catch {mkkitfs::Request $c quit}
proc mounted {dir} { return [expr {![catch {exec grep -F " $dir " /proc/mounts}]}] }
proc waitFor {ms cond} {
    for {set t 0} {$t < $ms} {incr t 20} { if {[uplevel 1 [list expr $cond]]} { return 1 } ; after 20 }
    return [uplevel 1 [list expr $cond]]
}
check "quit: the mount is gone" [waitFor 3000 {![mounted $mnt]}]

# a crash of the confined data path still takes its mount along (the unmount guard): no
# "Transport endpoint is not connected" left behind, and mkkitfsd ends with it
set pid [exec [info nameofexecutable] $tcldir/mkkitfsd serve -socket $sock -mountpoint $mnt -config $conf_file -log $log 2>>$log &]
set c ""
for {set i 0} {$i < 500 && $c eq ""} {incr i} { if {[catch {mkkitfs::connect -socket $sock -start 0} c]} { set c "" ; after 10 } }
if {$c eq ""} { check "mkkitfsd starts again" 0 [slurp $log] ; exit 1 }
mkkitfs::mount $c $gold/app.kit -keys [list $key]
set epid [dict get [mkkitfs::status $c] pid]
check "a second server serves app.kit" [mounted $mnt]
exec kill -KILL $epid
check "the data path killed: its mount goes with it" [waitFor 5000 {![mounted $mnt]}]
check "the data path killed: mkkitfsd ends too" [waitFor 5000 {[catch {exec kill -0 $pid}] || [string match Z* [lindex [split [slurp /proc/$pid/stat] { }] 2]]}]
catch {close $c}
exit [expr {$failures ? 1 : 0}]
