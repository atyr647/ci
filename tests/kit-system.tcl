# kit-system.tcl -- system kits end to end in kitd's system scope (srcpkgs/ribbon-kit/files/lib/system.tcl and
# plan.tcl; SYSTEM-UPDATES.md 7.3-7.7, D57 C / D58 B): installed, updated, rewound and tossed by `kitd --work`
# on a fake root, their /usr a merged erofs view (lib/mount.tcl) mounted at ROOT/usr.  Run as root in a private
# mount namespace (tests/steps.d/75-kit-system.sh: unshare -m --propagation private).
#
# Stand-ins: ribbon-snapshot (KIT_SNAPSHOT: logs its arguments, answers backend/pre/prune; pre prints the id on
# stdout, then the boot fallback's message on stderr, as the real one's arm does), dinitctl
# (KIT_DINITCTL: logs, says sshd is started) and udevadm (KIT_UDEVADM).  Mirrors are a file:// repository built
# with kittrust's kitindex, each system kit beside its manifest as kits/<root>.kit (D46 A).
#
# Checked: a system grab fetches the whole kit, takes the snapshot (labelled with the plan) before anything
# changes and records its id in the change's log entry, switches /usr live (a holder keeps the old bytes),
# reloads and restarts the kit's running services, reloads udev rules; kit check updates system kits in
# system scope; a kit tagged restart lands in the restart record; kit (user scope) refuses system kits and
# the effects only they may have; kitd refuses app kits; a failing snapshot stops the change before it
# changes anything; a root without snapshots changes and says so; a crash after the set's switch is
# finished by kitd's recovery, view included (and the next system change finds it right); plain kit rewind and kit rewind KIT (rows
# tagged held) bring the earlier view back; an essential system kit can't be tossed.
#
#   KITFMT_MK4TCL=<dir with Mk4tcl>  KIT_SWAPMOUNT=<built kit-swapmount>  tclsh tests/kit-system.tcl
set top [file normalize [file join [file dirname [info script]] ..]]
encoding system utf-8
fconfigure stdout -encoding utf-8
set fail 0
set nok 0
proc ok {desc cond {detail ""}} {
    if {[uplevel 1 [list expr $cond]]} { incr ::nok ; puts "  ok   $desc" ; return }
    puts "  FAIL $desc" ; set ::fail 1
    if {$detail ne ""} { foreach l [split [string trimright [uplevel 1 [list subst $detail]]] \n] { puts "       | $l" } }
}
proc skip {why} { puts "  skip system kits ($why)" ; exit 0 }
proc slurp {p} { set f [open $p rb] ; set d [read $f] ; close $f ; return $d }
proc utf {p} { return [encoding convertfrom utf-8 [slurp $p]] }
proc spit {p d {mode ""}} {
    file mkdir [file dirname $p] ; set f [open $p wb] ; puts -nonewline $f $d ; close $f
    if {$mode ne ""} { file attributes $p -permissions $mode }
}
proc readOr {p} { if {[catch {slurp $p} d]} { return "" } ; return $d }
proc utfOr {p} { if {[catch {utf $p} d]} { return "" } ; return $d }

if {[exec id -u] != 0} { skip "needs root" }
if {[catch {exec grep -qw erofs /proc/filesystems}]} { skip "the kernel has no erofs" }
foreach t {losetup mount umount mountpoint mkfs.erofs veritysetup} { if {[auto_execok $t] eq ""} { skip "no $t" } }
if {![info exists env(KIT_SWAPMOUNT)] || ![file executable $env(KIT_SWAPMOUNT)]} { skip "no kit-swapmount (KIT_SWAPMOUNT)" }
if {![info exists env(KITFMT_MK4TCL)] || $env(KITFMT_MK4TCL) eq ""} { skip "kitpack needs Mk4tcl: set KITFMT_MK4TCL" }

set tclsh [info nameofexecutable]
set T [file normalize [exec mktemp -d]]
set R $T/root
set KITD $top/srcpkgs/ribbon-kit/files/bin/kitd
set KIT $top/srcpkgs/ribbon-kit/files/bin/kit
set KT $top/kit/kittrust
set F $top/tests/fixtures/kittrust
set env(KIT_NOSYNC) 1
set env(KIT_EROFS_MIN) 1.0   ;# plain images without xattrs (mount.tcl: correct with 1.7 too)
unset -nocomplain env(KIT_INDEX) env(KIT_CRASH_AT) env(KIT_USR_VIEWS) env(KIT_USR) env(KIT_CONF)

# ---- keys: a root-signed list with app, system and index keys -------------------------------------------
proc tool {name args} {
    if {[catch {exec $::tclsh $::KT/$name {*}$args 2>@1} out]} { error "$name $args: $out" }
    return $out
}
set L $T/keys/trusted-keys
file mkdir $T/keys
tool kitkey init -repository org.ribbon.test -root $F/test-root.pub $L
tool kitkey add -role app -from -30d $L $F/test-app.pub
tool kitkey add -role system -from -30d $L $F/test-system.pub
tool kitkey add -role index -from -30d $L $F/test-index.pub
tool kitkey sign -key $F/test-root.key $L

# ---- the kits: plain erofs images, sealed by the system key -------------------------------------------
# skit NAME VERSION FILES ?MANIFEST-ADDITIONS? -> the .kit
proc skit {name version files {more ""}} {
    global T tclsh top env F
    set src $T/src/$name-$version
    file delete -force $src
    foreach {p d} $files { spit $src/$p $d }
    exec mkfs.erofs -Enoinline_data -T0 --all-root $T/$name-$version.erofs $src >/dev/null 2>@1
    spit $T/$name-$version.manifest "name org.test.$name version $version kind system summary {$name} license MIT x-short $name\n$more"
    file mkdir $T/empty
    set out $T/kits/org.test.$name-$version.kit
    file mkdir $T/kits
    exec $tclsh $top/kit/kitfmt/kitpack -q -mk4tcl $env(KITFMT_MK4TCL) -manifest $T/$name-$version.manifest \
        -image $T/$name-$version.erofs -verity yes -sign $F/test-system.key $T/empty $out 2>@1
    return $out
}
proc akit {name version} {
    global T tclsh top env F
    spit $T/src/$name-$version/bin/app "app\n"
    spit $T/$name-$version.manifest "name org.test.$name version $version kind app summary {$name} entries {{$name bin/app {} cli}}"
    set out $T/kits/org.test.$name-$version.kit
    exec $tclsh $top/kit/kitfmt/kitpack -q -mk4tcl $env(KITFMT_MK4TCL) -manifest $T/$name-$version.manifest \
        -sign $F/test-app.key $T/src/$name-$version $out 2>@1
    return $out
}
if {[catch {
    set kBase [skit base 1 {bin/sh "base sh\n" lib/libc.so.6 "libc\n"} "x-essential yes"]
    set kMesa1 [skit mesa 1 {lib/libGL.so.1 "mesa 1\n" lib/udev/rules.d/70-gl.rules "# mesa 1\n" share/dinit.d/sshd "type = process\n"} \
        "effects {{service sshd} {udev lib/udev/rules.d/70-gl.rules}}"]
    set kMesa2 [skit mesa 2 {lib/libGL.so.1 "mesa 2\n" lib/udev/rules.d/70-gl.rules "# mesa 2\n" share/dinit.d/sshd "type = process\n"} \
        "effects {{service sshd} {udev lib/udev/rules.d/70-gl.rules}}"]
    set kLinux [skit linux 1 {lib/modules/1/vmlinuz "kernel 1\n"} "restart yes"]
    set kTools [skit tools 1 {bin/tool "tool 1\n"}]
    set kApp [akit hello 1]
} e]} { puts "  FAIL making the test kits: $e" ; exit 1 }

# ---- the repository ---------------------------------------------------------------------------------
set REPO $T/repo
proc publish {args} {
    global REPO T
    file mkdir $REPO.kits
    foreach k $args { file copy -force $k $REPO.kits/ }
    # kittrust's publishing puts every system kit whole beside its bundle (D46 A), kits/<root>.kit
    tool kitindex build -key $::F/test-index.key -keys $::L $REPO.kits $REPO
}
source -encoding utf-8 $top/kit/kitfmt/kitfmt.tcl
publish $kBase $kMesa1 $kTools $kLinux $kApp
set wholes [lmap k [list $kBase $kMesa1 $kTools $kLinux] { file exists $REPO/kits/[dict get [::kitfmt::Frame $k] st root].kit }]
ok "publishing puts each system kit whole beside its bundle, and no app kit" {$wholes eq {1 1 1 1} &&
    ![file exists $REPO/kits/[dict get [::kitfmt::Frame $kApp] st root].kit]} {$wholes}

# ---- the fake root, the stand-ins -------------------------------------------------------------------
file mkdir $R/etc $R/usr $T/bin
spit $R/etc/kit.conf "keys = $L\nmirror = file://$REPO\ntimeout = 5\n"
set SNAPLOG $T/snapshot.log
set DINITLOG $T/dinit.log
set UDEVLOG $T/udev.log
spit $T/bin/snapshot "#!/bin/sh
echo \"\$*\" >>$SNAPLOG
case \$1 in
backend) cat $T/backend 2>/dev/null || echo btrfs ;;
pre) if \[ -e $T/snapfail \]; then echo 'snapper: no space left' >&2; exit 1; fi; n=\$(grep -c '^pre ' $SNAPLOG); echo \$((40 + n)); echo '==> if the next 3 boots do not reach the login screen, snapshot '\$((40 + n))' starts instead' >&2 ;;
esac
" 0755
spit $T/bin/dinitctl "#!/bin/sh
echo \"\$*\" >>$DINITLOG
case \"\$1 \$2\" in
'is-started sshd') exit 0 ;;
is-started*) exit 1 ;;
esac
" 0755
spit $T/bin/udevadm "#!/bin/sh\necho \"\$*\" >>$UDEVLOG\nif \[ -e $T/udevfail \]; then echo 'udevadm: no udevd' >&2; exit 1; fi\n" 0755
set env(KIT_SNAPSHOT) $T/bin/snapshot
set env(KIT_DINITCTL) $T/bin/dinitctl
set env(KIT_UDEVADM) $T/bin/udevadm
spit $T/boot_id "boot-1\n"
set env(KIT_BOOT_ID_FILE) $T/boot_id

# kitd's way: a queue entry, then `kitd --work ID` in system scope -> dict code log
set seq 0
proc work {args} {
    global R KITD tclsh seq
    set id [clock milliseconds]-[incr seq]
    spit $R/var/lib/kit/queue/$id [dict create id $id uid 0 words $args state running code "" submitted 0 started 0 finished "" pid ""]
    set env(KITD_ROOT) $R
    set ::env(KITD_ROOT) $R
    catch {exec timeout -k 5 120 $tclsh $KITD --work $id 2>@1} out
    if {[catch {utf $R/var/lib/kit/queue/$id} j] || [catch {dict get $j code} code]} { set code "?" } else {
        dict set j state done ; spit $R/var/lib/kit/queue/$id $j   ;# as kitd marks it
    }
    return [dict create code $code log [readOr $R/var/lib/kit/queue/$id.log] out $out]
}
proc show {r} { return "exit [dict get $r code]\n[dict get $r log][dict get $r out]" }
proc usr {p} { return [readOr $::R/usr/$p] }
proc active {} { return [readOr $::R/var/lib/kit/active] }
proc lastEntry {} {
    set ids [lsort -command {apply {{a b} {
        lassign [split $a -] ta pa ; lassign [split $b -] tb pb
        expr {$ta != $tb ? ($ta < $tb ? -1 : 1) : ($pa < $pb ? -1 : ($pa > $pb))}
    }}} [glob -nocomplain -tails -directory $::R/var/lib/kit/history {[0-9]*-[0-9]*}]]
    return [utf $::R/var/lib/kit/history/[lindex $ids end]]
}
proc clearLogs {} { foreach f [list $::SNAPLOG $::DINITLOG $::UDEVLOG] { file delete $f } }

set rc [catch {
# ==== user scope: kit leaves system kits alone ==========================================================
set ::env(HOME) $T/home
set ::env(KIT_CONF) $R/etc/kit.conf
# a system kit named to kit goes to kitd (scope.tcl): with no bus to reach it on (this test has none), that is said, and nothing is fetched
set ::env(DBUS_SYSTEM_BUS_ADDRESS) unix:path=$T/no-such-bus
catch {exec timeout -k 5 60 $tclsh $KIT grab --yes org.test.mesa 2>@1} out
ok "kit grab of a system kit by name wants kitd, and says so when there is no system bus; nothing is fetched" {[string match "*system kits are changed through kitd, and there is no system bus*" $out] &&
    ![file exists $T/home/.cache/kit/kits]} {$out}
catch {exec timeout -k 5 60 $tclsh $KIT grab --yes $kMesa1 2>@1} out
ok "a system kit FILE is refused in a person's own scope: it is never handed to kitd (root would read a file the person chose)" {[string match "*org.test.mesa is a system kit; system kits are installed for the whole system by kitd*a file is never handed over*" $out] &&
    ![file exists $T/home/.cache/kit/kits]} {$out}
unset ::env(DBUS_SYSTEM_BUS_ADDRESS)
set ::env(HOME) $T/roothome ; unset ::env(KIT_CONF)

# ==== the first system grab ===========================================================================
clearLogs
set r [work grab org.test.base org.test.mesa]
ok "kitd grab base mesa: done" {[dict get $r code] == 0} {[show $r]}
ok "/usr is the merged view of both kits" {[usr bin/sh] eq "base sh\n" && [usr lib/libGL.so.1] eq "mesa 1\n" &&
    ![catch {exec mountpoint -q $R/usr}]} {[exec ls -R $R/usr]}
set snap [readOr $SNAPLOG]
ok "the snapshot was taken first, labelled with the plan, then pruned" {[string match "*backend\npre before kit grab: base 1, mesa 1\nprune\n" $snap]} {$snap}
set e [lastEntry]
ok "the change's log entry records the snapshot's id" {[dict exists $e snapshot] && [dict get $e snapshot] eq "41"} {$e}
set d [readOr $DINITLOG]
ok "mesa's service: reloaded, found running, restarted" {[string match "reload sshd\nis-started sshd\nrestart sshd\n" $d] &&
    [string match "*Restarted sshd.*" [dict get $r log]]} {$d\n[show $r]}
ok "mesa's udev rules: udev reloaded" {[readOr $UDEVLOG] eq "control --reload\n"} {[readOr $UDEVLOG]}
ok "the whole kits were fetched (D46 A) and moved into the store" {
    [llength [glob -nocomplain $R/var/lib/kit/store/*/kit]] == 2 && ![llength [glob -nocomplain $R/var/cache/kit/kits/*]]}
ok "the view's device list names both kits, for the initramfs" {
    [regexp -all {\tkit\t|^kit\t|\nkit\t} [readOr $R/var/lib/kit/system/usr/view-1.erofs.devices]] >= 2} {[readOr $R/var/lib/kit/system/usr/view-1.erofs.devices]}

# ==== kitd refuses app kits; nothing changes ============================================================
set before [active]
set r [work grab org.test.hello]
ok "kitd refuses an app kit (exit 2), nothing changes" {[dict get $r code] == 2 && [string match "*org.test.hello is an app kit*" [dict get $r log]] && [active] eq $before} {[show $r]}

# ==== kit check updates system kits; a holder keeps the old bytes ======================================
publish $kMesa2
# (as if an hour had passed: the cached index is not fresh any more)
foreach f [glob -nocomplain $R/var/cache/kit/index*] { file delete $f }
set hold [open $R/usr/lib/libGL.so.1 r]
clearLogs
set r [work check]
ok "kitd check: mesa 1 -> 2" {[dict get $r code] == 0 && [string match "*mesa*1*2*" [dict get $r log]]} {[show $r]}
ok "the new view shows mesa 2; base is still there" {[usr lib/libGL.so.1] eq "mesa 2\n" && [usr bin/sh] eq "base sh\n"}
ok "a program that had mesa 1 open keeps reading mesa 1" {[read $hold] eq "mesa 1\n"}
close $hold
# the stand-in logs the label as the bytes it was given (UTF-8): read back as UTF-8, not as bytes
ok "the snapshot before the update is labelled with it" {[string match "*pre before kit grab: mesa 1 \u2192 2\n*" [utfOr $SNAPLOG]]} {[utfOr $SNAPLOG]}
ok "sshd restarted again (mesa changed)" {[string match "*restart sshd*" [readOr $DINITLOG]]}

# ==== a kit that takes effect at restart ===============================================================
clearLogs
set r [work grab org.test.linux]
ok "kitd grab linux: installed, tagged restart, 'Restart to finish'" {[dict get $r code] == 0 &&
    [string match "*Restart to finish: linux 1.*" [dict get $r log]]} {[show $r]}
ok "the restart record of this boot names it" {[string match "boot boot-1\nkit org.test.linux 1\n" [readOr $R/var/lib/kit/restart]]} {[readOr $R/var/lib/kit/restart]}
ok "linux's files are in /usr; nothing restarted (no service changed)" {[usr lib/modules/1/vmlinuz] eq "kernel 1\n" && [readOr $DINITLOG] eq ""}

# ==== snapshots: a failing one stops the change; no snapshots at all is said ===============================
spit $T/snapfail ""
set before [active]
set r [work grab org.test.tools]
ok "a snapshot that fails: refused before anything is staged, /usr unchanged" {[dict get $r code] == 2 &&
    [string match "*snapshot before this change failed*no space left*" [dict get $r log]] && [active] eq $before && [usr bin/tool] eq "" &&
    ![llength [glob -nocomplain $R/var/lib/kit/staging/*]]} {[show $r]}
file delete $T/snapfail
spit $T/backend "none\n"
clearLogs
set r [work grab org.test.tools]
ok "a root without snapshots: the change happens and says so" {[dict get $r code] == 0 && [string match "*No snapshot: the root filesystem has no snapshots.*" [dict get $r log]] &&
    [usr bin/tool] eq "tool 1\n" && ![string match "*pre *" [readOr $SNAPLOG]]} {[show $r]}
file delete $T/backend

# ==== a crash after the set's switch: recovery puts the view right =======================================
set r [work toss org.test.tools]
ok "toss tools: gone from /usr" {[dict get $r code] == 0 && [usr bin/tool] eq ""} {[show $r]}
set ::env(KIT_CRASH_AT) switched
set r [work grab org.test.tools]
unset ::env(KIT_CRASH_AT)
ok "crash right after the switch: the set has tools, the view not yet" {[string match "*org.test.tools*" [active]] && [usr bin/tool] eq ""} {[active]}
set r [work list]
ok "recovery finishes the set's switch" {[string match "*finished an interrupted grab*" [dict get $r log]]} {[show $r]}
ok "recovery brings the /usr view to the set: /usr shows tools" {[usr bin/tool] eq "tool 1\n"} {[show $r]}
clearLogs
set r [work toss org.test.linux]
ok "the next system change first puts the view right: /usr shows tools (and then not linux)" {[dict get $r code] == 0 &&
    [usr bin/tool] eq "tool 1\n" && [usr lib/modules/1/vmlinuz] eq ""} {[show $r]}

# ==== rewinds ==========================================================================================
set r [work toss org.test.tools]
clearLogs
set r [work rewind]
ok "plain kit rewind (undo the toss): tools back in /usr, a snapshot first" {[dict get $r code] == 0 && [usr bin/tool] eq "tool 1\n" &&
    [string match "*pre before kit rewind: tools 1\n*" [readOr $SNAPLOG]]} {[show $r]\n[readOr $SNAPLOG]}
spit $T/udevfail ""
clearLogs
set r [work rewind org.test.mesa]
file delete $T/udevfail
ok "kit rewind mesa: back to mesa 1, its row tagged held" {[dict get $r code] == 0 && [usr lib/libGL.so.1] eq "mesa 1\n" &&
    [regexp -line {mesa.*2.*1.*held} [dict get $r log]]} {[show $r]}
ok "udev rules that don't reload are said; sshd is restarted all the same" {[string match "*restart sshd*" [readOr $DINITLOG]] &&
    [string match "*no udevd*" [dict get $r log]]} {[show $r]\n[readOr $DINITLOG]}
set r [work check]
ok "kit check doesn't offer the held mesa" {[dict get $r code] == 0 && [usr lib/libGL.so.1] eq "mesa 1\n"} {[show $r]}

# ==== a system kit's desktop entry is in its image: nothing is exported into the read-only view =========
set kDesk [skit desk 1 {bin/desk "desk\n" share/applications/desk.desktop "\[Desktop Entry\]\nName=Desk\nExec=desk\nType=Application\n"} \
    "effects {{desktop share/applications/desk.desktop}}"]
publish $kDesk
foreach f [glob -nocomplain $R/var/cache/kit/index*] { file delete $f }
set r [work grab org.test.desk]
ok "a system kit with a desktop effect: grabbed, its entry in /usr from the image, nothing exported there" {[dict get $r code] == 0 &&
    [string match "*Name=Desk*" [usr share/applications/desk.desktop]] && [glob -nocomplain $R/usr/share/applications/kit-*] eq ""} {[show $r]}

# ==== essential ========================================================================================
set before [active]
set r [work toss org.test.base]
ok "an essential system kit can't be tossed" {[dict get $r code] == 2 && [string match "*base is needed for the system to run*" [dict get $r log]] && [active] eq $before} {[show $r]}

# ==== effects only system kits may have ===============================================================
set ::env(HOME) $T/home2
set ::env(KIT_CONF) $T/user.conf
spit $T/user.conf "keys = $L\nallow-unsigned = yes\n"
spit $T/src/svc/bin/app "x\n"
spit $T/svc.manifest "name org.test.svc version 1 kind app summary svc entries {{svc bin/app {} cli}} effects {{service sshd}}"
exec $tclsh $top/kit/kitfmt/kitpack -q -mk4tcl $env(KITFMT_MK4TCL) -manifest $T/svc.manifest -sign $F/test-app.key $T/src/svc $T/svc.kit 2>@1
catch {exec timeout -k 5 60 $tclsh $KIT grab --yes $T/svc.kit 2>@1} out
ok "an app kit with a service effect: refused by kit" {[string match "*the effect 'service' is a system kit's*" $out]} {$out}
set ::env(HOME) $T/roothome ; unset ::env(KIT_CONF)
} err opts]
if {$rc} { puts "  FAIL the test stopped: $err" ; puts [dict get $opts -errorinfo] ; set fail 1 }

catch {exec umount -l $R/usr 2>/dev/null}
foreach l [split [string trim [exec losetup -a]] \n] {
    if {[string match "*$T/*" $l]} { catch {exec losetup -d [lindex [split $l :] 0]} }
}
file delete -force $T
puts "  [expr {$fail ? "FAIL" : "ok  "}] system kits: $nok checks"
exit $fail
