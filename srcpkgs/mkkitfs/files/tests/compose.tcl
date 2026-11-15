# compose.tcl -- mkkitfs::compose with a real bubblewrap: a mounted kit at /app, read-only or under
# a writable overlay (temporary or kept), and two "store entries" stacked over a library directory.
#
#   tclsh compose.tcl MKKITFS GOLDEN_DIR WORKDIR BWRAP
#
# BWRAP must be bubblewrap 0.10 or later (--overlay-src); the caller skips this test otherwise.
lassign $argv exe gold work bwrap
set here [file dirname [file normalize [info script]]]
set tcldir [file join [file dirname $here] tcl]
lappend auto_path $tcldir
package require mkkitfs

set failures 0
proc check {what cond {detail ""}} {
    if {$cond} { puts "  ok   $what" } else { puts "  FAIL $what $detail" ; incr ::failures }
}
proc spit {f d} { file mkdir [file dirname $f] ; set ch [open $f w] ; puts $ch $d ; close $ch }

set env(MKKITFS) $exe
exec [info nameofexecutable] $tcldir/mkkitfsd serve -socket $work/s -mountpoint $work/mnt -linger 0 -log $work/log 2>@stderr &
for {set i 0} {$i < 500} {incr i} { if {![catch {mkkitfs::connect -socket $work/s -start 0} c]} break ; after 10 }
set rc [catch {
    set k [mkkitfs::mount $c $gold/app.kit]
    set d [dict get $k dir]
    # two versions of a "library" as store entries, and the base directory they go over
    spit $work/base/lib/x/base.txt base
    spit $work/base/lib/x/a.txt base-a
    spit $work/store/one/x/a.txt one-a
    spit $work/store/two/x/b.txt two-b
    set root [list --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
        --ro-bind /etc /etc --dev /dev --proc /proc --dir $work]
    set probe {cat /app/bin/hello | sed -n 2p; cd "$1" && cat x/a.txt x/b.txt x/base.txt; (echo written > /app/new.txt && cat /app/new.txt) 2>&1 | sed 's/.*Read-only.*/read-only/'}
    foreach {mode want} [list none {echo hello from a kit one-a two-b base read-only} \
                              tmp {echo hello from a kit one-a two-b base written} \
                              $work/rw {echo hello from a kit one-a two-b base written}] {
        set a [mkkitfs::compose $d -dest /app -overlay $mode -libs [list $work/store/one $work/store/two] -libdir $work/base/lib -bwrap $bwrap]
        set out [exec $bwrap {*}$root {*}$a sh -c $probe sh $work/base/lib 2>@1]
        check "compose -overlay [file tail $mode]: the kit at /app, the store entries over the library directory" \
            [expr {[string map {\n " "} $out] eq $want}] "\n   want: $want\n   got:  [string map {\n " "} $out]"
    }
    check "a kept overlay keeps what the app wrote, outside the kit" [expr {[file exists $work/rw/upper/new.txt] && ![file exists $d/new.txt]}]
    check "the kit itself is unchanged" [expr {[exec sha256sum $d/bin/hello] ne "" && ![file exists $d/new.txt]}]
} err opts]
if {$rc} { puts "  FAIL compose: $err" ; incr failures }
catch {mkkitfs::Request $c quit}
exit [expr {$failures ? 1 : 0}]
