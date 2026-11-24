# tests/kit-mount-failpaths.tcl -- the failure paths of srcpkgs/ribbon-kit/files/lib/mount.tcl that a real kernel does
# not produce on demand, with stand-in tools (KIT_LOSETUP, KIT_MOUNT, KIT_UMOUNT, KIT_MOUNTPOINT, KIT_SWAPMOUNT,
# KIT_MKFS_EROFS) that log what they are asked.  No root, no FUSE, no Mk4tcl.
#   1. losetup attaches a device and then refuses direct I/O: that device is detached again before the plain attach
#   2. kit-swapmount slid the new view beneath the old one (exit 3) and the old one does not detach: the switch
#      fails, `current` stays the old view, the new view's files are removed, and the stage is not left behind
#   tclsh8.6 -encoding utf-8 tests/kit-mount-failpaths.tcl
set top [file dirname [file dirname [file normalize [info script]]]]
encoding system utf-8
fconfigure stdout -encoding utf-8
set fails 0
proc ok {name cond {detail ""}} {
    if {$cond} { puts "  ok   $name" } else { puts "  FAIL $name" ; if {$detail ne ""} { puts "       [string range $detail 0 1500]" } ; incr ::fails }
}
proc spit {p d {mode ""}} { file mkdir [file dirname $p] ; set f [open $p w] ; puts -nonewline $f $d ; close $f ; if {$mode ne ""} { file attributes $p -permissions $mode } }
proc slurp {p} { if {[catch {open $p} f]} { return "" } ; set d [read $f] ; close $f ; return $d }
set W [file normalize [exec mktemp -d]]
set env(STANDIN) $W
# losetup: --direct-io=on attaches /dev/loop9 and fails (as losetup does when the backing file refuses O_DIRECT
# after LOOP_CONFIGURE); a plain attach prints the next /dev/loopN; -d logs
spit $W/bin/losetup {#!/bin/sh
echo "losetup $*" >> "$STANDIN/log"
case $1 in -d) exit 0 ;; esac
case " $* " in *" --direct-io=on "*) [ -f "$STANDIN/dio-fails" ] && { echo /dev/loop9; echo "losetup: /dev/loop9: set direct io failed" >&2; exit 1; } ;; esac
n=$(cat "$STANDIN/next" 2>/dev/null || echo 0); echo $((n + 1)) > "$STANDIN/next"; echo "/dev/loop$n"
} 0755
foreach t {mount mountpoint} { spit $W/bin/$t "#!/bin/sh\necho \"$t \$*\" >> \"\$STANDIN/log\"\nexit 0\n" 0755 }
spit $W/bin/umount {#!/bin/sh
echo "umount $*" >> "$STANDIN/log"
[ "$1" = -l ] && { echo "umount: target is busy" >&2; exit 32; }
exit 0
} 0755
spit $W/bin/kit-swapmount {#!/bin/sh
echo "kit-swapmount $*" >> "$STANDIN/log"
echo "kit-swapmount: the new view is beneath the old one, which could not be detached" >&2
exit 3
} 0755
spit $W/bin/mkfs.erofs {#!/bin/sh
case $1 in -V) echo "mkfs.erofs (erofs-utils) 1.9"; exit 0 ;; esac
echo "mkfs.erofs $*" >> "$STANDIN/log"
[ "$1" = --quiet ] && shift
echo view > "$1"
} 0755
foreach {e t} {KIT_LOSETUP losetup KIT_MOUNT mount KIT_UMOUNT umount KIT_MOUNTPOINT mountpoint KIT_SWAPMOUNT kit-swapmount KIT_MKFS_EROFS mkfs.erofs} {
    set env($e) $W/bin/$t
}
set env(KIT_USR_VIEWS) $W/views
source -encoding utf-8 $top/srcpkgs/ribbon-kit/files/lib/core.tcl
::kit::init
::kit::need mount
proc log {} { return [split [string trim [slurp $::W/log]] \n] }

# ---- 1. direct I/O refused after the attach --------------------------------------------------------------
spit $W/dio-fails 1
spit $W/log ""
set k [dict create path $W/a.kit offset 4096 length 8192]
set dev [::kit::mount::Attach $k]
set L [log]
ok "direct I/O refused: the device losetup attached for it is detached again" [expr {"losetup -d /dev/loop9" in $L}] $L
ok "... then the plain attach gives the device used" [expr {$dev eq "/dev/loop0" && [lindex $L end] eq "losetup --find --show --read-only --offset 4096 --sizelimit 8192 $W/a.kit"}] "$dev $L"
file delete $W/dio-fails $W/next
spit $W/log ""
set dev [::kit::mount::Attach $k]
ok "direct I/O taken: one attach, nothing detached" [expr {$dev eq "/dev/loop0" && [llength [log]] == 1 && [lsearch -glob [log] "losetup -d *"] < 0}] [log]

# ---- 2. beneath the old view, and the old one stays -------------------------------------------------------
# kits are checked with kitfmt elsewhere (tests/kit-mount.tcl); here two that pass
proc ::kit::mount::kits {kits} { lmap k $kits { dict create path [lindex $k 0] root [lindex $k 1] name org.ribbon.[lindex $k 1] version 1 offset 4096 length 4096 } }
file mkdir $W/views $W/usr
spit $W/views/current 1\n
spit $W/views/view-1.erofs old
spit $W/views/view-1.erofs.devices "ribbon-usr-view 1\n"
spit $W/log ""
set rc [catch {::kit::mount::activate [list [list $W/a.kit a] [list $W/b.kit b]] $W/usr} err]
set L [log]
ok "swapmount beneath, the old view busy: the switch fails with umount's words" [expr {$rc && [string match "*target is busy*" $err]}] $err
ok "... after kit-swapmount and umount -l were both asked" [expr {[lsearch -glob $L "kit-swapmount $W/views/stage-2 $W/usr"] >= 0 && [lsearch -glob $L "umount -l $W/usr"] >= 0}] $L
ok "... current still names the old view (what /usr shows)" [expr {[string trim [slurp $W/views/current]] eq "1"}]
ok "... the new view's files are gone, the old one's kept" [expr {![file exists $W/views/view-2.erofs] && ![file exists $W/views/view-2.erofs.devices] && [file exists $W/views/view-1.erofs]}]
ok "... and no stage directory is left" [expr {![file exists $W/views/stage-2]}]
# two kits attached to build the view, two again to stage it, and the view's own image as a loop device (stage)
ok "... the devices built and staged with are all detached, the view's own among them" [expr {[llength [lsearch -all -glob $L "losetup -d *"]] == 5}] $L

file delete -force $W
if {$fails} { puts "kit mount failure paths: $fails checks failed" ; exit 1 }
puts "kit mount failure paths: all checks passed"
