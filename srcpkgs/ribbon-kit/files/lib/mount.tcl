# mount.tcl -- system kits as one merged erofs /usr view, and its atomic live switch (D57 C, D58 B:
# SYSTEM-UPDATES.md 8.3 and 7.2; HANDOFF "System updates: three points" 1 (b)).
#
# A system kit stays one signed .kit file carrying an uncompressed erofs image (KIT-FORMAT.md 8).  The
# view over a set of them is one small erofs *metadata* image, built here with mkfs.erofs's rebuild mode
# from the kits' images (each attached read-only as a loop device at its sealed offset); mounted with
# those images as its extra devices, it is the whole /usr in one mount, with native lookups (poc 19:
# 0.2 s to build over 32 kits, 11-16 ms to mount).  A new set of kits is a new view: built beside the
# old one, mounted at a staging point, and slid beneath the old one at /usr with kit-swapmount (mkkitfs
# package, src/swapmount.c: move_mount(MOVE_MOUNT_BENEATH) + lazy detach).  Every new lookup sees the
# new view at once; what running programs have open, mapped or as their cwd stays the old view until
# they let go, and the kernel then frees it -- with its loop devices, which are detached here right
# after mounting (autoclear: the kernel drops each one when its last user goes).
#
# Root only (kitd's system scope).  Needs util-linux (losetup, mount, mountpoint), erofs-utils' mkfs.erofs
# >= 1.9 (D68; KIT_EROFS_MIN lowers the floor, e.g. for 1.7.1 in tests: correct for plain images
# without xattrs only, SYSTEM-UPDATES.md 2.5), and kit-swapmount.
#
# The state directory (default /var/lib/kit/system/usr) holds, per view <n>:
#   view-<n>.erofs      the metadata image
#   view-<n>.devices    its devices in mkfs order, plain text (the initramfs reads it with busybox shell):
#                         ribbon-usr-view 1
#                         kit <TAB> <path> <TAB> <offset> <TAB> <length> <TAB> <root> <TAB> <name> <TAB> <version>
#   current             the number of the view /usr shows (written once the switch is done)
#
#   ::kit::mount::kits KITS              check KITS (a list of {path root}) -> list of dicts
#   ::kit::mount::build KITS FILE        the metadata image FILE (+ FILE's .devices) over KITS
#   ::kit::mount::stage FILE DIR         mount the view FILE (and its .devices) read-only at DIR
#   ::kit::mount::activate KITS TARGET   build, stage and swap in a new view at TARGET: the live switch
#   ::kit::mount::restore TARGET         mount the current view at TARGET again (boot, recovery)

namespace eval ::kit::mount {
    variable state [::kit::env KIT_USR_VIEWS /var/lib/kit/system/usr]
    variable minErofs {1 9}     ;# D68 (A): erofs-utils 1.9 or later, KIT_EROFS_MIN overrides
    variable keep 2             ;# views kept: the current one and the one before it
}

proc ::kit::mount::Tool {name env} {
    set p [::kit::env $env]
    if {$p ne ""} { return $p }
    if {$name eq "kit-swapmount"} {
        if {[info exists ::kit::libdir] && [file executable [file join $::kit::libdir kit-swapmount]]} {
            return [file join $::kit::libdir kit-swapmount]
        }
        if {[file executable /usr/lib/ribbon/kit/kit-swapmount]} { return /usr/lib/ribbon/kit/kit-swapmount }
    }
    set p [lindex [auto_execok $name] 0]
    if {$p eq ""} { ::kit::fail 2 "$name is not installed (the merged /usr view needs it)" }
    return $p
}

# exec, with the tool's own message (and nothing of Tcl's) in the error
proc ::kit::mount::Run {args} {
    if {[catch {exec {*}$args 2>@1} out opts]} {
        ::kit::fail 1 "[file tail [lindex $args 0]]: [string trim $out]"
    }
    return $out
}

# erofs-utils' version as {major minor}; {0 0} when it has no --version (1.7 and older)
proc ::kit::mount::ErofsVersion {} {
    catch {exec [Tool mkfs.erofs KIT_MKFS_EROFS] -V 2>@1} out
    if {[regexp -line {^mkfs\.erofs[^0-9\n]*([0-9]+)\.([0-9]+)} $out -> ma mi]} { return [list $ma $mi] }
    return {0 0}
}

proc ::kit::mount::CheckErofs {} {
    variable minErofs
    set min $minErofs
    set o [::kit::env KIT_EROFS_MIN]
    if {$o ne ""} {
        if {![regexp {^([0-9]+)(?:\.([0-9]+))?$} $o -> a b]} { ::kit::fail 2 "KIT_EROFS_MIN must be MAJOR.MINOR" }
        set min [list $a [expr {$b eq "" ? 0 : $b}]]
    }
    lassign [ErofsVersion] ma mi
    lassign $min a b
    if {$ma < $a || ($ma == $a && $mi < $b)} {
        set have [expr {$ma == 0 ? "older than 1.8 (no --version)" : "$ma.$mi"}]
        ::kit::fail 2 "erofs-utils $a.$b or later is needed to build the /usr view (D68); this mkfs.erofs is $have"
    }
}

proc ::kit::mount::LoadKitfmt {} {
    if {![llength [info commands ::kitfmt::Frame]]} {
        uplevel #0 [list source [file join [::kit::kitfmtDir] kitfmt.tcl]]
    }
}

# Each kit: a sealed system kit whose seal names the root kit's records hold (the kit installed is the
# kit checked), with an erofs image at a 4 KiB-aligned offset inside the file.  The seal is read
# without Metakit (KIT-FORMAT.md 1.1); the image's segments were verified when the kit was installed.
proc ::kit::mount::kits {kits} {
    LoadKitfmt
    if {![llength $kits]} { ::kit::fail 2 "a /usr view needs at least one system kit" }
    set out {}
    set seen {}
    foreach k $kits {
        lassign $k path root
        set path [file normalize $path]
        if {[catch {::kitfmt::Frame $path} fr]} { ::kit::fail 1 "$path: $fr" }
        set st [dict get $fr st]
        set name [dict get $st name]
        if {[dict get $st kind] ne "system"} { ::kit::fail 1 "$name ($path) is not a system kit" }
        if {$root eq "" || [dict get $st root] ne $root} {
            ::kit::fail 1 "$name ($path): its seal's root is [dict get $st root], not the installed $root"
        }
        set img [dict get $st image]
        if {$img eq "" || [dict get $img fs] ne "erofs"} { ::kit::fail 1 "$name ($path) carries no erofs image" }
        set off [dict get $img offset] ; set len [dict get $img length]
        if {$off % 4096 || $len % 4096 || $off < [dict get $fr storeStart] || $off + $len > [file size $path]} {
            ::kit::fail 1 "$name ($path): the image at $off+$len is not 4 KiB-aligned inside the kit's store"
        }
        if {[dict exists $seen $name]} { ::kit::fail 1 "$name is in the view twice ([dict get $seen $name] and $path)" }
        dict set seen $name $path
        lappend out [dict create path $path root $root name $name version [dict get $st version] offset $off length $len]
    }
    return $out
}

proc ::kit::mount::Attach {k} {
    set lo [Tool losetup KIT_LOSETUP]
    set args [list --find --show --read-only --offset [dict get $k offset] --sizelimit [dict get $k length] [dict get $k path]]
    # direct I/O: the image's bytes are cached once, not once for the loop and once for the .kit file.  losetup
    # attaches first and sets direct I/O after, so a refusal of direct I/O can leave a device attached that it
    # named on stdout: that one is detached before the plain attach
    if {[catch {exec $lo --direct-io=on {*}$args 2>/dev/null} dev]} {
        foreach l [split $dev \n] {
            if {[regexp {^\s*(/dev/loop[0-9]+)\s*$} $l -> d]} { catch {exec $lo -d $d 2>/dev/null} }
        }
        set dev [Run $lo {*}$args]
    }
    return [string trim $dev]
}

proc ::kit::mount::Detach {devs} {
    foreach d $devs { catch {exec [Tool losetup KIT_LOSETUP] -d $d 2>/dev/null} }
}

proc ::kit::mount::DevicesText {list} {
    set t "ribbon-usr-view 1\n"
    foreach k $list {
        append t [join [list kit [dict get $k path] [dict get $k offset] [dict get $k length] [dict get $k root] \
            [dict get $k name] [dict get $k version]] \t] \n
    }
    return $t
}

proc ::kit::mount::ReadDevices {file} {
    set f $file.devices
    if {![file exists $f]} { ::kit::fail 1 "$f is missing: the view $file can't be mounted" }
    set lines [split [string trimright [::kit::slurp $f utf-8] \n] \n]
    if {[lindex $lines 0] ne "ribbon-usr-view 1"} { ::kit::fail 1 "$f: not a /usr view's device list" }
    set out {}
    foreach l [lrange $lines 1 end] {
        set w [split $l \t]
        if {[llength $w] != 7 || [lindex $w 0] ne "kit"} { ::kit::fail 1 "$f: bad line '$l'" }
        lassign $w - path off len root name version
        lappend out [dict create path $path offset $off length $len root $root name $name version $version]
    }
    return $out
}

# The metadata image over KITS (in this order: on a path two kits both have, the later one wins in
# mkfs.erofs's rebuild mode, which is why a view never holds one kit twice).  Written beside FILE and
# renamed into place with its .devices, so FILE is either the whole view or absent.
proc ::kit::mount::build {kits file} {
    CheckErofs
    set list [kits $kits]
    file mkdir [file dirname $file]
    set devs {}
    set tmp $file.tmp[pid]
    try {
        foreach k $list { lappend devs [Attach $k] }
        file delete -force $tmp
        Run [Tool mkfs.erofs KIT_MKFS_EROFS] --quiet $tmp {*}$devs
        ::kit::spit $file.devices [DevicesText $list]
        file rename -force $tmp $file
        ::kit::durable $file $file.devices
    } finally {
        Detach $devs
        file delete -force $tmp
    }
    return $list
}

# Mount the view FILE read-only at DIR: its kits' images attached in the order of FILE.devices, the
# view's own device option list naming them, then detached again (autoclear: the mount holds them).
# Returns the devices of the view.
proc ::kit::mount::stage {file dir} {
    set list [ReadDevices $file]
    set devs {}
    try {
        foreach k $list { lappend devs [Attach $k] }
        set opts ro
        foreach d $devs { append opts ,device=$d }
        file mkdir $dir
        Run [Tool mount KIT_MOUNT] -t erofs -o $opts $file $dir
    } finally {
        Detach $devs
    }
    return $list
}

proc ::kit::mount::IsMountpoint {dir} {
    return [expr {![catch {exec [Tool mountpoint KIT_MOUNTPOINT] -q $dir}]}]
}

proc ::kit::mount::Current {} {
    variable state
    set f [file join $state current]
    if {![file exists $f]} { return "" }
    set n [string trim [::kit::slurp $f]]
    if {![string is digit -strict $n]} { ::kit::fail 1 "$f does not hold a view number" }
    return $n
}

proc ::kit::mount::ViewFile {n} { variable state ; return [file join $state view-$n.erofs] }

# The live switch: a new view over KITS replaces the one at TARGET in one step.  TARGET that is not a
# mount point yet (the first view, or a test) gets the view moved onto it instead.  On any failure
# before the swap nothing visible changed, and the new view's files are removed again.
proc ::kit::mount::activate {kits target} {
    variable state
    set cur [Current]
    set n [expr {$cur eq "" ? 1 : $cur + 1}]
    while {[file exists [ViewFile $n]]} { incr n }   ;# leftovers of an interrupted switch stay for inspection
    set file [ViewFile $n]
    set stage [file join $state stage-$n]
    set list [build $kits $file]
    set swapped 0
    try {
        stage $file $stage
        if {[IsMountpoint $target]} {
            file stat $stage s
            set dev $s(dev)
            if {[catch {exec [Tool kit-swapmount KIT_SWAPMOUNT] $stage $target 2>@1} out opts]} {
                set code [lindex [dict get $opts -errorcode] end]
                if {[lindex [dict get $opts -errorcode] 0] eq "CHILDSTATUS" && $code == 3} {
                    # beneath the old view already: finish by detaching the old view
                    Run [Tool umount KIT_UMOUNT] -l $target
                } else {
                    ::kit::fail 1 "kit-swapmount: [string trim $out]"
                }
            }
            file stat $target s
            if {$s(dev) != $dev} { ::kit::fail 1 "$target does not show the new view after the switch" }
        } else {
            file mkdir $target
            Run [Tool mount KIT_MOUNT] --move $stage $target
        }
        set swapped 1
        ::kit::spit [file join $state current] $n\n
        ::kit::durable [file join $state current]
    } finally {
        if {!$swapped} {
            catch {exec [Tool umount KIT_UMOUNT] $stage 2>/dev/null}
            file delete -force $file $file.devices
        }
        catch {file delete $stage}
    }
    Prune $n
    return [dict create view $n file $file kits $list]
}

# Old views' files: the kernel keeps what a lazily detached view still uses, open or not
proc ::kit::mount::Prune {n} {
    variable keep
    foreach f [glob -nocomplain -directory $::kit::mount::state view-*.erofs] {
        if {[regexp {view-([0-9]+)\.erofs$} $f -> m] && $m <= $n - $keep} { file delete -force $f $f.devices }
    }
}

# Mount the current view at TARGET (after a boot, or to repair): what the initramfs does in shell.
proc ::kit::mount::restore {target} {
    set n [Current]
    if {$n eq ""} { ::kit::fail 1 "there is no /usr view yet" }
    set list [stage [ViewFile $n] $target]
    return [dict create view $n file [ViewFile $n] kits $list]
}
