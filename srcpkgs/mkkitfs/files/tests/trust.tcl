# trust.tcl -- mkkitfsd with `trust kittrust`: the signature policy of kit/kittrust (docs/KIT-TRUST.md)
# decides which kits mount with `signed 1`, before the engine parses them.
#
#   tclsh trust.tcl MKKITFS RIBBON_TREE WORKDIR        (needs minisign)
#
# With the test-only keys of tests/fixtures/kittrust: a key list whose root is test-root, with
# test-app as the app key and test-system as the system key.  app.kit re-signed by test-app mounts;
# the golden app.kit (signed by kitfmt's test key, not in the list) is refused as untrusted; a system
# kit signed by the app key is refused (the wrong role); an unsigned kit is refused.
lassign $argv exe tree work
set here [file dirname [file normalize [info script]]]
set tcldir [file join [file dirname $here] tcl]
lappend auto_path $tcldir $tree/kit/kittrust $tree/kit/kitfmt
package require mkkitfs
set K $tree/kit/kittrust
set F $tree/tests/fixtures/kittrust
set G $tree/kit/kitfmt/tests/golden

set failures 0
proc check {what cond {detail ""}} {
    if {$cond} { puts "  ok   $what" } else { puts "  FAIL $what $detail" ; incr ::failures }
}
proc errcode {script} {
    if {![catch {uplevel 1 $script} r opts]} { return ok }
    set ec [dict get $opts -errorcode]
    return [expr {[lindex $ec 0] eq "MKKITFS" ? [lindex $ec 1] : "ERROR: $r"}]
}
proc tool {args} { exec [info nameofexecutable] {*}$args 2>@1 }

file mkdir $work/kits
set L $work/trusted-keys
tool $K/kitkey init -repository org.ribbon.test -root $F/test-root.pub $L
tool $K/kitkey add -role app $L $F/test-app.pub
tool $K/kitkey add -role system $L $F/test-system.pub
tool $K/kitkey sign -key $F/test-root.key $L
foreach k {app system app-header} { file copy -force $G/$k.kit $work/kits/$k.kit }
file copy -force $G/system.kit $work/kits/system-by-app.kit
tool $K/kitseal -key $F/test-app.key -keys $L $work/kits/app.kit
tool $K/kitseal -key $F/test-system.key -keys $L $work/kits/system.kit
tool $K/kitseal -key $F/test-app.key $work/kits/system-by-app.kit

set ch [open $work/mkkitfs.conf w]
puts $ch "linger 0\ntrust kittrust\ntrust-anchor $L\ntrust-state $work/state"
close $ch
file mkdir $work/state
set env(MKKITFS) $exe
# kittrust and kitfmt ahead of the caller's path, which is where unix_sockets may be (UNIX_SOCKETS_DIR in CI)
set env(TCLLIBPATH) [concat [list $tree/kit/kittrust $tree/kit/kitfmt] [expr {[info exists env(TCLLIBPATH)] ? $env(TCLLIBPATH) : ""}]]
exec [info nameofexecutable] $tcldir/mkkitfsd serve -socket $work/s -mountpoint $work/mnt -config $work/mkkitfs.conf -log $work/log 2>>$work/log &
set c ""
for {set i 0} {$i < 500 && $c eq ""} {incr i} { if {[catch {mkkitfs::connect -socket $work/s -start 0} c]} { set c "" ; after 10 } }
if {$c eq ""} { puts "  FAIL mkkitfsd with trust kittrust did not start: [exec cat $work/log]" ; exit 1 }

set rc [catch {
    set k [mkkitfs::mount $c $work/kits/app.kit -signed 1]
    check "kittrust: an app kit signed by the app key mounts with -signed 1 (role [dict get $k role])" \
        [expr {[dict get $k signature] eq "valid" && [dict get $k role] eq "app" && [file exists [dict get $k dir]/bin/hello]}] $k
    set k [mkkitfs::mount $c $work/kits/system.kit -signed 1]
    check "kittrust: a system kit signed by the system key mounts" [expr {[dict get $k signature] eq "valid" && [dict get $k role] eq "system"}] $k
    check "kittrust: kitfmt's golden app.kit (its key is not in the list): SIGNATURE" [expr {[errcode {mkkitfs::mount $c $G/app.kit -signed 1}] eq "SIGNATURE"}]
    check "kittrust: a system kit signed by the app key (the wrong role): SIGNATURE" [expr {[errcode {mkkitfs::mount $c $work/kits/system-by-app.kit -signed 1}] eq "SIGNATURE"}]
    check "kittrust: an unsigned kit: SIGNATURE" [expr {[errcode {mkkitfs::mount $c $work/kits/app-header.kit -signed 1}] eq "SIGNATURE"}]
    set k [mkkitfs::mount $c $G/app.kit]
    check "kittrust: without -signed the untrusted kit mounts, and says so" [expr {[dict get $k signature] eq "untrusted"}] [dict get $k signature]
} err]
if {$rc} { puts "  FAIL trust: $err" ; incr failures }
catch {mkkitfs::Request $c quit}
exit [expr {$failures ? 1 : 0}]
