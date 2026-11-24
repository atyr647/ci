# system.tcl -- system kits: a small policy layer over the app code paths (docs/KIT.md, "Principle:
# everything is a kit"; KIT-CLI.md K5; SYSTEM-UPDATES.md section 7).
#
# System kits use everything app kits use, unchanged: the .kit format (with an embedded erofs image as
# the payload, D58 B), kittrust verification, the index, download and chunk store (repo.tcl), the store and
# assembly (store.tcl), the planner (plan.tcl), the journal and atomic switch (txn.tcl), and the one
# prompt (ui.tcl).  They differ only on the principle's seven points, and each has its place here:
#
#   1 privilege   scope      system scope is the same engine with its paths under /var/lib/kit, run
#                 refuse     by the privileged helper kitd (bin/kitd, D16) one queued transaction at
#                 queue      a time; `kit` itself stays in user scope
#   2 no sandbox             launch.tcl's sandbox hook (::kit::launch::command) leaves them alone
#   3 signer      (kittrust) the system role is read from the seal's kind (KIT-TRUST.md); the
#                 effect      capability flags: which effects a kit may declare
#   4 snapshot   snapshot    taken before every system change (plan.tcl execute, before the staging)
#   5 restart     restart    rows tagged "restart" only where 7.5 says; new kernels install beside
#                 waiting    the running one, and check doesn't offer them again until the restart
#   6 services   afterSwitch the /usr view switched, then dinit restarts (a txn::afterSwitch command, 7.6)
#   7 essential              store.tcl essential: x-essential, or `essential =` in /etc/kit.conf

namespace eval ::kit::system {
    # never-live processes and the kits they come from (7.5): they are not restarted live, so a
    # new version of them takes effect at restart.  Kernel, module, firmware and microcode kits
    # say so themselves with the manifest field "restart".  The core libraries that nearly every
    # never-live process maps are here too (U03b): glibc, libgcc, libstdc++, ld.so, libcrypto,
    # libssl, zlib, libelogind, libsystemd, libdbus.  Matched by the kit's short name (x-short).
    variable neverLive {glibc dinit dbus elogind turnstile greetd \
        libgcc libstdc++ ld.so libcrypto libssl zlib libelogind libsystemd libdbus}
    # the processes of 7.6's "never restarted live" list, by their comm, and the kit each comes from: a
    # never-live process that still maps a replaced (deleted) file needs a restart, whatever replaced it
    # (the /proc scan, D64 C).  The bus is the system bus only (dbus-daemon --system); session buses
    # and other user services pick up new versions at the next login (D60).
    variable neverLiveProcs {dinit dinit dbus-daemon dbus elogind-daemon elogind turnstiled turnstile greetd greetd}
    variable scope user                ;# user (kit) or system (kitd's transactions)
    variable offline 0                 ;# system scope on a root that is not the running system (kitd --root: an install's
                                       ;# target, an image being built): no snapshot, no kernel made bootable, no service
                                       ;# or udev touched; the view's device list names the kits as that system will
    variable procDir /proc             ;# where the scan reads processes (a fake tree in the tests)
    variable bootIdFile [::kit::env KIT_BOOT_ID_FILE /proc/sys/kernel/random/boot_id]
}

# 1: system kits install system-wide, through kitd; app kits per user (D10), never through kitd.  In kitd's
# system scope a system kit is planned, fetched whole (D46 A), staged and verified like an app kit, then
# activated through the merged erofs /usr view (D57 C, D58 B: afterSwitch below, lib/mount.tcl).  kit itself
# (user scope) never changes the system: a system kit named there is refused before anything is fetched.
proc ::kit::system::refuse {kind name} {
    variable scope
    if {$scope eq "system"} {
        if {$kind ne "system"} { ::kit::fail 2 "$name is an app kit; app kits are installed per user, with kit grab" }
        return
    }
    if {$kind eq "system"} {
        ::kit::fail 2 "$name is a system kit; system kits are installed for the whole system by kitd (org.ribbon.Kit1), not by kit in a person's own scope: name it (kit grab NAME) and kit hands it to kitd, a file is never handed over"
    }
}

# The kind of kit a scope plans for: kit check offers only these kits' updates (plan.tcl updates).
proc ::kit::system::kind {} {
    variable scope
    return [expr {$scope eq "system" ? "system" : "app"}]
}

# 4 (kit rewind): a system kit goes back in system scope only (kitd), where the rewind is a system change like
# a grab: a snapshot first (snapshot below), then the earlier kits' view (afterSwitch).  The rewind code
# (plan.tcl restore, verbs.tcl RewindKit) calls this for every kit a rewind would change.
proc ::kit::system::refuseRewind {kind name} {
    variable scope
    if {$scope eq "system"} {
        if {$kind ne "system"} { ::kit::fail 2 "$name is an app kit; app kits are rewound per user, with kit rewind" }
        return
    }
    if {$kind eq "system"} {
        ::kit::fail 2 "$name is a system kit; system kits are rewound for the whole system by kitd (org.ribbon.Kit1), not by kit"
    }
}

# 3: effects beyond an app's (desktop, icon, mime, font, dbus: store.tcl Exports) belong to system kits, in
# system scope only.  Their files are in the kit's image, so they are in /usr as soon as the view is; nothing
# is exported.  What they ask for happens after the switch (afterSwitch): a service is reloaded and restarted
# (7.6), udev rules are reloaded; module and firmware kits take effect at restart (the manifest's restart).
proc ::kit::system::effect {name type value} {
    variable scope
    if {$type ni {module firmware service udev}} { ::kit::fail 2 "$name: unknown effect '$type'" }
    if {$scope ne "system"} {
        ::kit::fail 2 "$name: the effect '$type' is a system kit's; kit installs app kits only (system kits: kitd)"
    }
    if {$type eq "service"} {
        if {![regexp {^[A-Za-z0-9_][A-Za-z0-9_.@-]*$} $value]} { ::kit::fail 4 "$name: '$value' is not a dinit service name" }
    } elseif {$value eq "" || [string index $value 0] eq "/" || ".." in [split $value /]} {
        ::kit::fail 4 "$name: its $type effect '$value' is not a path inside the kit"
    }
}

# 5: does this candidate (plan.tcl) take effect only at a restart?  Only system kits can.
proc ::kit::system::restart {c} {
    variable neverLive
    if {[dict get $c kind] ne "system"} { return 0 }
    set f [dict get $c ki fields]
    if {[dict exists $f restart] && [::kit::truthy [dict get $f restart]]} { return 1 }
    return [expr {[dict get $c short] in $neverLive}]
}

# 5: is the update `rec` of the installed line `line` already waiting: installed and waiting for a
# restart (a kernel beside the running one: the restart record of this boot), or queued in kitd by another
# transaction?  App kits never wait (they switch at their next start), and outside system scope there is
# neither a record nor a queue, so this costs one failed open.
proc ::kit::system::waiting {line rec} {
    set name [dict get $rec name] ; set version [dict get $rec version]
    if {[list $name $version] in [pending]} { return 1 }
    if {![info exists ::kit::P(queue)]} { return 0 }
    set short [::kit::shortOf $name [expr {[dict exists $rec short] ? [dict get $rec short] : ""}]]
    set self [::kit::env KITD_JOB]
    foreach j [queue] {
        if {[dict get $j id] eq $self || [dict get $j state] ni {queued running}} continue
        set words [lassign [dict get $j words] verb]
        if {$verb ni {grab check}} continue
        foreach w $words {
            if {[regexp {^(.*)@(.*)$} $w -> w v] && $v ne $version} continue
            if {$w in [list $name $short]} { return 1 }
        }
    }
    return 0
}

# ---- system scope (kitd) ------------------------------------------------------------------------------
# kitd's paths, under ROOT (/ on a running system; a directory in the tests).  The same names as the user
# scope's (core.tcl ::kit::init), so the rest of kit runs unchanged:
#   data   ROOT/var/lib/kit     active, journal, lock, store/, staging/, history/, keys/ (KIT-TRUST.md:
#                               /var/lib/kit/keys), restart (the record below), queue/ (kitd's transactions)
#   cache  ROOT/var/cache/kit   index, manifests/, chunks/
#   conf   ROOT/etc/kit.conf    (KIT_CONF still wins, as for kit)
proc ::kit::system::scope {root {off 0}} {
    variable scope system
    variable offline $off
    set root [file normalize $root]
    set data [file join $root var/lib/kit]
    array set ::kit::P [list root $root home [file join $root root] data $data cache [file join $root var/cache/kit] \
        config [file join $root etc/kit] xdgdata [file join $root usr/share] \
        conf [::kit::env KIT_CONF [file join $root etc/kit.conf]] \
        store $data/store staging $data/staging appdata $data/data active $data/active journal $data/journal \
        lock $data/lock running $data/running queue $data/queue restart $data/restart]
    # a target root has no configuration of its own yet (it comes with the kits): the running system's is used
    # (its repositories and keys are named by absolute paths there already)
    if {$off} { set ::kit::P(conf) [::kit::env KIT_CONF /etc/kit.conf] }
    ::kit::readConf
    return $root
}

# ---- kitd's queue ------------------------------------------------------------------------------------
# data/queue/<id>: one transaction kitd was asked for, a dict: id uid words (the kit verb and its
# arguments) state (queued running done) code (the verb's exit code, when done) submitted started finished
# pid; data/queue/<id>.log is what it printed.  kitd writes them (atomically: ::kit::spit); this reads them.
proc ::kit::system::queue {} {
    set out {}
    foreach f [glob -nocomplain -tails -directory [::kit::path queue] *] {
        if {![regexp {^[0-9]+-[0-9]+$} $f]} continue
        if {[catch {::kit::slurp [::kit::path queue $f] utf-8} d] || [catch {dict get $d state}]} continue
        lappend out $d
    }
    return [lsort -command ::kit::system::JobOrder $out]
}
proc ::kit::system::JobOrder {a b} {
    lassign [split [dict get $a id] -] ta na ; lassign [split [dict get $b id] -] tb nb
    return [expr {$ta != $tb ? ($ta < $tb ? -1 : 1) : ($na < $nb ? -1 : ($na > $nb))}]
}

# ---- the restart record (7.5) ------------------------------------------------------------------------
# data/restart, plain text: "boot BOOT-ID", then "kit NAME VERSION" per system kit installed in that boot
# that takes effect at a restart.  A record from an earlier boot is spent: the restart happened.
proc ::kit::system::bootId {} {
    variable bootIdFile
    if {[catch {string trim [::kit::slurp $bootIdFile utf-8]} id] || $id eq ""} { return unknown }
    return $id
}
# {NAME VERSION} per kit waiting for a restart in this boot
proc ::kit::system::pending {} {
    if {![info exists ::kit::P(restart)] || [catch {::kit::slurp [::kit::path restart] utf-8} text]} { return {} }
    set out {} ; set boot ""
    foreach line [split $text \n] {
        if {[regexp {^boot (\S+)$} $line -> boot]} continue
        if {[regexp {^kit (\S+) (\S+)$} $line -> n v]} { lappend out [list $n $v] }
    }
    return [expr {$boot eq [bootId] ? $out : {}}]
}
# NAME VERSION takes effect at the next restart (a newer version of NAME replaces an older one's entry)
proc ::kit::system::pend {name version} {
    set lines [list "boot [bootId]"]
    foreach p [pending] { if {[lindex $p 0] ne $name} { lappend lines "kit [join $p { }]" } }
    lappend lines "kit $name $version"
    ::kit::spit [::kit::path restart] "[join $lines \n]\n"
    ::kit::durable [::kit::path restart]
}

# The system kits a transaction changed that take effect at restart: called by kitd with the live set
# before and after (store.tcl sets), it records each in the restart record.  -> the {NAME VERSION} recorded.
proc ::kit::system::settle {B A} {
    set was [dict create]
    dict for {key k} [dict get $B kits] { if {[dict get $k reason] ne "prev"} { dict set was [dict get $k name] [dict get $k version] } }
    set out {}
    dict for {key k} [dict get $A kits] {
        if {[dict get $k reason] eq "prev"} continue
        set n [dict get $k name] ; set v [dict get $k version]
        if {[dict exists $was $n] && [dict get $was $n] eq $v} continue
        set inf [::kit::store::kinfo [dict get $k root]]
        set c [dict create kind [dict get $inf kind] short [::kit::shortOf $n [expr {[dict get $inf short] eq "?" ? "" : [dict get $inf short]}]] \
            ki [dict create fields [dict get $inf fields]]]
        if {[restart $c]} { pend $n $v ; lappend out [list $n $v] }
    }
    return $out
}

# ---- the never-live scan (7.5, 7.6; D64 C) -------------------------------------------------------------
# Processes that map a file which has since been replaced or removed (the kernel marks the mapping
# "(deleted)"): {pid comm paths} each.  Unreadable processes (another user's, or gone) are skipped.
proc ::kit::system::scan {} {
    variable procDir
    set out {}
    foreach d [glob -nocomplain -tails -directory $procDir {[0-9]*}] {
        if {![string is digit $d]} continue
        if {[catch {::kit::slurp [file join $procDir $d maps]} maps]} continue
        set paths {}
        foreach line [split $maps \n] {
            if {[regexp {^\S+ \S+ \S+ \S+ \S+\s+(/.*) \(deleted\)$} $line -> p] && $p ni $paths} { lappend paths $p }
        }
        if {![llength $paths]} continue
        if {[catch {string trim [::kit::slurp [file join $procDir $d comm]]} comm]} continue
        lappend out [list $d $comm $paths]
    }
    return [lsort -integer -index 0 $out]
}
# The never-live processes among them: {comm kit pid} each, the system bus's dbus-daemon only.  They
# keep the old code until the machine restarts, so each one is a reason to restart.
proc ::kit::system::stale {} {
    variable procDir ; variable neverLiveProcs
    set out {}
    foreach s [scan] {
        lassign $s pid comm
        if {![dict exists $neverLiveProcs $comm]} continue
        if {$comm eq "dbus-daemon"} {
            if {[catch {::kit::slurp [file join $procDir $pid cmdline]} cl] || "--system" ni [split $cl \0]} continue
        }
        lappend out [list $comm [dict get $neverLiveProcs $comm] $pid]
    }
    return $out
}

# ---- fetching and staging a system kit (D46 A: whole kits) ----------------------------------------------
# A system kit's payload is one erofs image at a sealed offset of the file (KIT-FORMAT.md 8), which can't be
# rebuilt from chunks the way an app kit's store is (store.tcl assemble): mirrors keep the whole signed file
# beside its manifest, <mirror>/kits/<root>.kit.  It is fetched before anything changes, into
# cache/kits/<root>.kit, and checked against its root there; the staging verifies it in full (store.tcl
# stage: the signature, the root, every image segment).
proc ::kit::system::whole {c} {
    return [expr {[dict get $c kind] eq "system" && [dict get $c origin] eq "repo"}]
}
proc ::kit::system::cached {root} { return [::kit::path cache kits $root.kit] }

# Bytes a candidate still needs from a mirror: the sealed image's end (the file's size is not sealed; what
# follows the image is the kit's small store and seal).
proc ::kit::system::bytes {c} {
    set root [dict get $c root]
    if {[file isfile [::kit::path store $root kit]] || [file isfile [cached $root]]} { return 0 }
    return [ImageEnd $c]
}
proc ::kit::system::ImageEnd {c} {
    set img [expr {[dict exists $c st image] ? [dict get $c st image] : ""}]
    if {$img eq "" || ![dict exists $img offset]} { return 0 }
    return [expr {[dict get $img offset] + [dict get $img length]}]
}

proc ::kit::system::fetch {cands} {
    ::kit::kitfmt
    dict for {root c} $cands {
        if {![whole $c] || [file isfile [::kit::path store $root kit]]} continue
        set f [cached $root]
        if {[file isfile $f] && ![catch {::kitfmt::Frame $f} fr] && [dict get $fr st root] eq $root} continue
        file mkdir [file dirname $f]
        # no more than the sealed image and 64 MiB of store and seal around it
        set max [expr {[ImageEnd $c] + 67108864}]
        set why {}
        set done 0
        foreach mirror [::kit::repo::mirrorOrder] {
            set tmp $f.[pid]
            file delete $tmp
            if {[catch {::kit::net::get $mirror/kits/$root.kit -max $max -file $tmp} r]} {
                set ::kit::repo::bad($mirror) 1 ; lappend why "$mirror: $r" ; file delete $tmp ; continue
            }
            if {[catch {::kitfmt::Frame $tmp} fr] || [dict get $fr st root] ne $root} {
                set ::kit::repo::bad($mirror) 1 ; lappend why "$mirror/kits/$root.kit is not the kit its index names"
                file delete $tmp ; continue
            }
            file rename -force $tmp $f
            set done 1 ; break
        }
        if {!$done} {
            if {![llength $why]} { ::kit::fail 3 "no mirror is configured (add mirror = URL to [::kit::path conf])" }
            ::kit::fail [expr {[string match "*is not the kit*" [join $why]] ? 4 : 3}] "[dict get $c name] [dict get $c version]: [join $why {; }]"
        }
    }
}

# plan.tcl Build for a system kit: the fetched file is moved into the staging and verified there.
proc ::kit::system::build {c dir} {
    set f [cached [dict get $c root]]
    if {![file isfile $f]} { ::kit::fail 3 "[dict get $c name] [dict get $c version] was not fetched" }
    file rename -force $f $dir/kit
    ::kit::store::stage $dir [dict get $c bundle] repo
}

# ---- 4: the snapshot before every system change (7.3 step 6; D66, D62 A) -------------------------------
# ribbon-snapshot pre LABEL takes one read-only snapshot of the root and arms the boot fallback to it (the try
# counter, D62 A); prune keeps the newest 10 (D66).  A root filesystem without snapshots (ribbon-snapshot
# backend: none) is said once and changes anyway, as ribbon update does; a snapshot that fails stops the
# change before anything is staged.  KIT_SNAPSHOT names another command (the tests' stand-in).
# -> the snapshot's id, or "" when there is none.
namespace eval ::kit::system { variable snapshotId "" }
proc ::kit::system::Label {op rows} {
    set parts {}
    foreach r $rows {
        switch -- [dict get $r action] {
            update { lappend parts "[dict get $r short] [dict get $r old] \u2192 [dict get $r new]" }
            install { lappend parts "[dict get $r short] [dict get $r new]" }
            remove { lappend parts "[dict get $r short] [dict get $r old] removed" }
        }
    }
    if {[llength $parts] > 4} { set parts [list {*}[lrange $parts 0 3] "\u2026"] }
    return "before kit $op: [join $parts {, }]"
}
proc ::kit::system::snapshot {op rows} {
    variable scope ; variable snapshotId ; variable offline
    set snapshotId ""
    if {$scope ne "system" || $offline} { return "" }
    set sys [lmap r $rows { if {[dict get $r kind] ne "system"} continue ; set r }]
    if {![llength $sys]} { return "" }
    set cmd [::kit::env KIT_SNAPSHOT]
    if {$cmd eq ""} { set cmd [lindex [auto_execok ribbon-snapshot] 0] }
    if {$cmd eq ""} { ::kit::fail 2 "ribbon-snapshot is not installed: no system change without the snapshot before it" }
    if {[catch {string trim [exec $cmd backend 2>/dev/null]} be]} { set be none }
    if {$be eq "none"} {
        ::kit::note "No snapshot: the root filesystem has no snapshots."
        return ""
    }
    set label [Label $op $sys]
    # the id is pre's first line on stdout (as ribbon-snapshot's own arm takes it); its stderr (the boot
    # fallback's message, the boot menu's) is kept apart and said only when the snapshot fails
    set ef [file tempfile]
    set rc [catch {exec $cmd pre $label 2>@ $ef} out]
    seek $ef 0
    set err [read $ef]
    close $ef
    if {$rc} {
        ::kit::fail 2 "the snapshot before this change failed, so nothing was changed: [string trim "$err\n[regsub {child process exited abnormally$} $out {}]"]"
    }
    set snapshotId [string trim [lindex [split [string trim $out] \n] 0]]
    catch {exec $cmd prune 2>/dev/null}
    return $snapshotId
}

# ---- 6: after the switch: the /usr view, then services (7.3 step 10, 7.6) -------------------------------
# A txn::afterSwitch command (plan.tcl execute adds it in system scope; recovery runs it again): the live
# set's system kits become the /usr view (one new merged erofs view, swapped in live: mount.tcl activate)
# unless the view already shows exactly them.  Then, once per change, for the kits that came or changed:
# their services (the manifest's service effects) are reloaded and, when running, restarted, in the order
# the kits list them, except the never-live ones (7.6), which wait for the restart (the restart record);
# udev rules are reloaded when such a kit carries any.  A failing service restart is said, not undone.
# KIT_USR (default ROOT/usr) is the view's mount point, KIT_DINITCTL and KIT_UDEVADM the tools.
proc ::kit::system::Views {} {
    ::kit::need mount
    if {[::kit::env KIT_USR_VIEWS] eq ""} { set ::kit::mount::state [::kit::path data system usr] }
    variable offline
    if {$offline} { set ::kit::mount::root [string trimright $::kit::P(root) /] }
}
proc ::kit::system::target {} { return [::kit::env KIT_USR [file join $::kit::P(root) usr]] }

# {name version root} per live system kit of the set A, by name
proc ::kit::system::kitsOf {A} {
    set out {}
    dict for {key k} [dict get $A kits] {
        if {[dict get $k reason] eq "prev"} continue
        if {[catch {::kit::store::kinfo [dict get $k root]} inf] || [dict get $inf kind] ne "system"} continue
        lappend out [list [dict get $k name] [dict get $k version] [dict get $k root]]
    }
    return [lsort -index 0 $out]
}
# {name version root} per kit the current view shows ({} when there is none)
proc ::kit::system::viewKits {} {
    Views
    set n [::kit::mount::Current]
    if {$n eq "" || [catch {::kit::mount::ReadDevices [::kit::mount::ViewFile $n]} list]} { return {} }
    return [lsort -index 0 [lmap k $list { list [dict get $k name] [dict get $k version] [dict get $k root] }]]
}

# No path in two kits (docs/SYSTEM-KITS-BUILD.md 2b, decision 127): the merged view takes the later image's entry for a
# path two images hold, without a word, and a link in one replaces a directory of another.  So before a staged set
# becomes the set, every live system kit's entries are compared; only a directory may be in more than one.  A kit's
# list is made once (its image mounted alone) and kept in the cache by its root.
proc ::kit::system::Paths {root} {
    set f [::kit::path cache paths $root]
    if {![catch {::kit::slurp $f utf-8} text] && [string match "ribbon-kit-paths 1\n*" $text]} {
        return [lrange [split [string trimright $text \0] \0] 1 end]
    }
    Views
    set list [lmap e [::kit::mount::listing [::kit::path store $root kit] $root] { join $e \t }]
    file mkdir [file dirname $f]
    ::kit::spit $f "ribbon-kit-paths 1\n\0[join $list \0]\0" utf-8
    return $list
}
proc ::kit::system::beforeSwitch {A} {
    variable scope
    if {$scope ne "system"} return
    set seen [dict create]
    foreach k [kitsOf $A] {
        lassign $k name version root
        foreach e [Paths $root] {
            set t [string first \t $e]
            set type [string range $e 0 [expr {$t - 1}]] ; set path [string range $e [expr {$t + 1}] end]
            if {[dict exists $seen $path]} {
                lassign [dict get $seen $path] otype oname
                if {$type ne "d" || $otype ne "d"} {
                    ::kit::fail 1 "$oname and $name both bring /usr/$path: two system kits cannot hold one path, nothing was changed"
                }
                continue
            }
            dict set seen $path [list $type $name]
        }
    }
}

proc ::kit::system::afterSwitch {A} {
    variable scope ; variable snapshotId
    if {$scope ne "system"} return
    set want [kitsOf $A]
    set have [viewKits]
    if {$want eq $have || ![llength $want]} return
    set kits [lmap k $want { list [::kit::path store [lindex $k 2] kit] [lindex $k 2] }]
    variable offline
    set kernelsBefore [KernelVersions]
    ::kit::mount::activate $kits [target]
    if {!$offline} { KernelsBeside $kernelsBefore }
    # what the kits ship for /etc and /var, where it is missing (kit-defaults; KIT_DEFAULTS names another command)
    set kd [::kit::env KIT_DEFAULTS]
    foreach c [list [file join $::kit::libdir kit-defaults] [file join $::kit::libdir .. bin kit-defaults]] {
        if {$kd eq "" && [file executable $c]} { set kd $c }
    }
    if {$kd ne ""} {
        if {[catch {exec $kd [string trimright $::kit::P(root) /] 2>@1} out]} { set out "defaults were not put down: $out" }
        if {[string trim $out] ne ""} { ::kit::note "kit: [string trim $out]" }
    }
    if {$offline} return   ;# not the running system: its services and udev are not this root's
    if {$snapshotId ne "" && $::kit::txn::last ne ""} { catch {::kit::txn::amend $::kit::txn::last snapshot $snapshotId} }
    set was [dict create]
    foreach k $have { dict set was [lindex $k 0] [lindex $k 2] }
    set services {} ; set udev 0
    foreach k $want {
        lassign $k name version root
        if {[dict exists $was $name] && [dict get $was $name] eq $root} continue
        foreach e [dict get [::kit::store::kinfo $root] effects] {
            lassign $e type value
            if {$type eq "service" && $value ni $services} { lappend services $value }
            if {$type eq "udev"} { set udev 1 }
        }
    }
    # the change is made by now: rules that don't reload are said, and the services still restart
    if {$udev && [catch {Tool KIT_UDEVADM udevadm control --reload} err]} {
        ::kit::note "kit: udev rules were not reloaded: [string trim [regsub {child process exited abnormally$} $err {}]]"
    }
    Services $services
}

# A kernel kit brings /usr/lib/modules/VERSION/vmlinuz (the freedesktop layout); nothing else puts it on /boot.  The kernels
# the view shows now that it did not show before are made bootable beside the running one (7.3: a kernel kit is never
# swapped in): /usr/lib/ribbon/kernel-boot-files (ribbon-tools) copies the image to /boot, builds its initramfs and
# refreshes the boot menu, and it only adds: the running kernel's files stay, and so do older ones until ribbon-snapshot's
# prune (snapshots still boot them).  A kernel that could not be made bootable is said; the change itself stands.
# KIT_KERNEL_BOOT_FILES names another command (tests).
proc ::kit::system::KernelVersions {} {
    set out {}
    foreach f [glob -nocomplain -directory [file join [target] lib modules] */vmlinuz] { lappend out [file tail [file dirname $f]] }
    return [lsort $out]
}
proc ::kit::system::KernelsBeside {before} {
    set cmd [::kit::env KIT_KERNEL_BOOT_FILES /usr/lib/ribbon/kernel-boot-files]
    foreach v [KernelVersions] {
        if {$v in $before} continue
        if {![file executable $cmd]} {
            ::kit::note "kit: kernel $v is installed, but $cmd is missing: it is not on the boot menu (run: sudo ribbon boot update)"
            continue
        }
        if {[catch {exec $cmd install $v </dev/null 2>@1} out]} {
            set out [string trim [regsub {(^|\n)child process exited abnormally$} [string trim $out] {}]]
            ::kit::note "kit: kernel $v could not be made bootable: [expr {$out eq "" ? "kernel-boot-files failed" : [lindex [split $out \n] end]}]"
        } else {
            ::kit::note "Kernel $v is on the boot menu; it starts at the next restart."
        }
    }
}

proc ::kit::system::Tool {env name args} {
    set t [::kit::env $env]
    if {$t eq ""} { set t [lindex [auto_execok $name] 0] }
    if {$t eq ""} { return -code error "$name is not installed" }
    return [exec $t {*}$args 2>@1]
}

# 7.6: reload each service's description, restart the running ones; dinit's never-live services are left
# to the restart (their kits are tagged restart), and so is a service dinit doesn't know.
proc ::kit::system::Services {names} {
    set never {dinit dbus elogind turnstiled turnstile greetd}
    set restarted {} ; set failed {}
    foreach s $names {
        if {$s in $never || [string match agetty* $s] || [string match getty* $s]} continue
        catch {Tool KIT_DINITCTL dinitctl reload $s}
        if {[catch {Tool KIT_DINITCTL dinitctl is-started $s}]} continue
        if {[catch {Tool KIT_DINITCTL dinitctl restart $s} err]} { lappend failed "$s ([string trim $err])" } else { lappend restarted $s }
    }
    if {[llength $restarted]} { ::kit::note "Restarted [join $restarted {, }]." }
    if {[llength $failed]} { ::kit::note "kit: [join $failed {, }] did not restart" }
    return $restarted
}

# The view and the live set agree again after an interrupted change (a crash between the set's switch and the
# view's): plan.tcl execute runs it before each system change; kitd's recovery runs afterSwitch itself.
proc ::kit::system::reconcile {} {
    variable scope
    if {$scope ne "system"} return
    afterSwitch [::kit::store::load]
}
