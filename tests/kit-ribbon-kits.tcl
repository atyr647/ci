# kit-ribbon-kits.tcl -- Ribbon's own packages as system kits, from the builder to a machine's /usr
# (build/kits/ribbon-kits.sh; docs/SYSTEM-KITS-BUILD.md).  make build in a scratch directory, the builder with the test
# system key, kittrust's index over the kits, then `kitd --work grab ribbon-desktop` on a fake root: the planner brings
# the kits it needs, and the merged erofs /usr view is, file for file, what make install puts into /usr.
#
# Checked: every built package becomes a kit named org.ribbon.NAME at the template's version, signed for the system
# role and of kind system; a kit needs the Ribbon kits its template depends on; what a package installs outside /usr
# is listed and is not in any image; the builder refuses two kits that bring one path; grab by the package's own
# name (the short name) installs it with what it needs; the view's tree equals the staged trees (path, type, mode,
# link target, content); a second build of the same tree makes the same images (reproducible).
# Run as root in a private mount namespace (tests/steps.d/79-kit-ribbon-kits.sh).
#   KITFMT_MK4TCL=<dir with Mk4tcl>  KIT_SWAPMOUNT=<built kit-swapmount>  tclsh tests/kit-ribbon-kits.tcl
set top [file normalize [file join [file dirname [info script]] ..]]
encoding system utf-8
fconfigure stdout -encoding utf-8
set fail 0
set nok 0
proc ok {desc cond {detail ""}} {
    if {[uplevel 1 [list expr $cond]]} { incr ::nok ; puts "  ok   $desc" ; return }
    puts "  FAIL $desc" ; set ::fail 1
    if {$detail ne ""} { foreach l [split [string trimright [uplevel 1 [list subst $detail]]] \n] { puts "       | [string range $l 0 300]" } }
}
proc skip {why} { puts "  skip Ribbon's packages as kits ($why)" ; exit 0 }
proc slurp {p} { set f [open $p rb] ; set d [read $f] ; close $f ; return $d }
proc spit {p d {mode ""}} {
    file mkdir [file dirname $p] ; set f [open $p wb] ; puts -nonewline $f $d ; close $f
    if {$mode ne ""} { file attributes $p -permissions $mode }
}
proc readOr {p} { if {[catch {slurp $p} d]} { return "" } ; return $d }
proc sh {args} { if {[catch {exec {*}$args 2>@1} out]} { return [list 1 $out] } ; return [list 0 $out] }

if {[exec id -u] != 0} { skip "needs root" }
if {[catch {exec grep -qw erofs /proc/filesystems}]} { skip "the kernel has no erofs" }
foreach t {losetup mount umount mountpoint mkfs.erofs veritysetup make cc} { if {[auto_execok $t] eq ""} { skip "no $t" } }
if {![info exists env(KIT_SWAPMOUNT)] || ![file executable $env(KIT_SWAPMOUNT)]} { skip "no kit-swapmount (KIT_SWAPMOUNT)" }
if {![info exists env(KITFMT_MK4TCL)] || $env(KITFMT_MK4TCL) eq ""} { skip "kitpack needs Mk4tcl: set KITFMT_MK4TCL" }

set tclsh [info nameofexecutable]
set T [file normalize [exec mktemp -d]]
set R $T/root
set KITD $top/srcpkgs/ribbon-kit/files/bin/kitd
set KT $top/kit/kittrust
set F $top/tests/fixtures/kittrust
set BUILDER $top/build/kits/ribbon-kits.sh
set env(KIT_NOSYNC) 1
set env(KIT_EROFS_MIN) 1.0
set env(SOURCE_DATE_EPOCH) 1700000000
unset -nocomplain env(KIT_INDEX) env(KIT_CRASH_AT) env(KIT_USR_VIEWS) env(KIT_USR) env(KIT_CONF) env(DESTDIR)
proc cleanup {} { catch {exec umount -l $::R/usr} ; catch {file delete -force $::T} }

set rc [catch {
# ---- make build, in a scratch directory (nothing of the working tree's out/ is used or changed) -------------------
lassign [sh make -s -C $top build O=$T/o DISTDIR=$T/dist] brc bout
if {$brc} { puts "  FAIL make build:\n$bout" ; cleanup ; exit 1 }
set env(O) $T/o
set env(KIT_SIGN) $F/test-system.key
lassign [sh sh $BUILDER $T/k] rc1 out1
ok "the builder runs over every package that make build made" {$rc1 == 0} {$out1}
set kits {}
foreach l [split [string trim [readOr $T/k/kits.txt]] \n] { lassign [split $l \t] n v f ; dict set kits $n [list $v $f] }
set pkgs [lsort [glob -tails -directory $T/k/trees *]]
ok "one kit per built package, named org.ribbon.NAME, at its template's version_revision" {
    [llength $pkgs] >= 7 && [dict size $kits] == [llength $pkgs] && [dict exists $kits org.ribbon.desktop] &&
    [regexp {^[0-9.]+_[0-9]+$} [lindex [dict get $kits org.ribbon.desktop] 0]]} {$pkgs\n$kits}
ok "ribbon-desktop needs the Ribbon kits its template depends on (base, kit), and no kit of the base's" {
    [regexp {needs \{.*\{org.ribbon.base \{\}\}.*\{org.ribbon.kit \{\}\}} [readOr $T/k/src/ribbon-desktop.manifest]] &&
    [regexp -line {^org.ribbon.desktop\t.*labwc} [readOr $T/k/base-needs.txt]]} {[readOr $T/k/src/ribbon-desktop.manifest]}
set outside [readOr $T/k/outside.txt]
ok "what the packages install outside /usr is listed (kit.conf, ribbon.conf, gamemode.ini) and travels in the kit as defaults, with the directories to make" {
    [string match "*ribbon-kit\t/etc/kit.conf*" $outside] && [string match "*ribbon-base\t/etc/ribbon/ribbon.conf*" $outside] &&
    [file exists $T/k/trees/ribbon-kit/share/ribbon/defaults/ribbon-kit/etc/kit.conf] && ![file exists $T/k/trees/ribbon-kit/etc] &&
    [string match "*/var/lib/greetd 0750 _greeter _greeter*" [readOr $T/k/trees/ribbon-desktop/share/ribbon/defaults/ribbon-desktop.state]] &&
    ![string match "*var/lib/ribbon/installed*" $outside]} {$outside}

# reproducible: the same tree gives the same images
lassign [sh sh $BUILDER $T/k2] rc2 out2
set same 1
foreach p $pkgs { if {[slurp $T/k/images/$p.erofs] ne [slurp $T/k2/images/$p.erofs]} { set same 0 ; break } }
ok "a second build makes the same images, byte for byte" {$rc2 == 0 && $same} {$out2}

# two kits, one path: refused, the path named
set mdir $T/manifests
file copy $top/build/install/manifests $mdir
set fh [open $mdir/ribbon-gaming.manifest a] ; puts $fh "file 644 usr/lib/ribbon @repo/LICENSE common.sh" ; close $fh
set env(MANIFESTS) $mdir
lassign [sh sh $BUILDER $T/k3 ribbon-tools ribbon-gaming] rc3 out3
unset env(MANIFESTS)
ok "two kits that bring one path are refused, and the path is named" {
    $rc3 != 0 && [string match "*/usr/lib/ribbon/common.sh:*ribbon-gaming*" $out3] && [string match "*ribbon-tools*" $out3] &&
    ![llength [glob -nocomplain $T/k3/kits/*.kit]]} {$out3}

# ---- publish, and a machine ------------------------------------------------------------------------------------
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
tool kitindex build -key $F/test-index.key -keys $L $T/k/kits $T/repo

file mkdir $R/etc $R/usr $T/bin
spit $R/etc/kit.conf "keys = $L\nmirror = file://$T/repo\ntimeout = 5\n"
spit $T/bin/snapshot "#!/bin/sh\ncase \$1 in backend) echo btrfs ;; pre) echo 41 ;; esac\n" 0755
spit $T/bin/dinitctl "#!/bin/sh\nexit 1\n" 0755
spit $T/bin/udevadm "#!/bin/sh\nexit 0\n" 0755
set env(KIT_SNAPSHOT) $T/bin/snapshot
set env(KIT_DINITCTL) $T/bin/dinitctl
set env(KIT_UDEVADM) $T/bin/udevadm
spit $T/boot_id "boot-1\n"
set env(KIT_BOOT_ID_FILE) $T/boot_id
set env(KITD_ROOT) $R
set seq 0
proc work {args} {
    global R KITD tclsh seq
    set id [clock milliseconds]-[incr seq]
    spit $R/var/lib/kit/queue/$id [dict create id $id uid 0 words $args state running code "" submitted 0 started 0 finished "" pid ""]
    catch {exec timeout -k 5 300 $tclsh $KITD --work $id 2>@1} out
    if {[catch {slurp $R/var/lib/kit/queue/$id} j] || [catch {dict get $j code} code]} { set code "?" }
    return [dict create code $code log [readOr $R/var/lib/kit/queue/$id.log] out $out]
}
set r [work grab ribbon-desktop]
set active [readOr $R/var/lib/kit/active]
ok "kitd installs ribbon-desktop by the package's own name" {[dict get $r code] == 0 && [string match "*org.ribbon.desktop*" $active]} {[dict get $r log]\n[dict get $r out]}
ok "  and brings the Ribbon kits it needs with it (base, kit), not the ones it does not (installer, gaming)" {
    [string match "*org.ribbon.base*" $active] && [string match "*org.ribbon.kit\t*" $active] &&
    ![string match "*org.ribbon.installer*" $active] && ![string match "*org.ribbon.gaming*" $active]} {$active}
set r [work grab ribbon-installer ribbon-gaming ribbon-tools ribbon-dinit]
ok "the rest of Ribbon's packages install the same way" {[dict get $r code] == 0} {[dict get $r log]\n[dict get $r out]}

# the view against the staged trees: every package that is installed, laid into one tree, compared entry by entry
set active [readOr $R/var/lib/kit/active]
file mkdir $T/want
foreach p $pkgs {
    if {![string match "*org.ribbon.[string range $p [expr {[string match ribbon-* $p] ? 7 : 0}] end]\t*" $active]} continue
    exec cp -a $T/k/trees/$p/. $T/want/
    lappend live $p
}
proc listing {dir} {
    set out {}
    foreach f [lsort [split [exec sh -c "cd '$dir' && find . -mindepth 1" ] \n]] {
        set p $dir/$f
        set t [file type $p]
        set extra ""
        switch -- $t {
            link { set extra [file readlink $p] }
            file { set extra "[file attributes $p -permissions] [exec sha256sum $p | cut -d\  -f1]" }
            directory { set extra [file attributes $p -permissions] }
        }
        lappend out "$f $t $extra"
    }
    return $out
}
set want [listing $T/want]
set have [listing $R/usr]
set diff {}
foreach l $want { if {$l ni $have} { lappend diff "missing or different: $l" } }
foreach l $have { if {$l ni $want} { lappend diff "extra: $l" } }
ok "/usr is the installed packages' files and nothing else: [llength $want] entries of [llength $live] kits, equal in path, type, mode, link and content" {
    [llength $want] > 300 && ![llength $diff]} {[join [lrange $diff 0 15] \n]}
ok "  it is one read-only erofs mount, and the session's program is in it, executable" {
    [regexp -line "^\\S+ $R/usr erofs ro" [slurp /proc/mounts]] && [file executable $R/usr/bin/ribbon-session]} {[exec grep $R /proc/mounts]}

# ---- defaults: what the kits ship for /etc and /var is there, where there was none --------------------------------
ok "after the change the kits' defaults are in /etc (ribbon.conf, the sudoers file with its mode), put down by kit-defaults" {
    [readOr $R/etc/ribbon/ribbon.conf] eq [slurp $top/srcpkgs/ribbon-base/files/ribbon.conf] &&
    [file attributes $R/etc/sudoers.d/10-ribbon -permissions] eq [file attributes $T/k/trees/ribbon-base/share/ribbon/defaults/ribbon-base/etc/sudoers.d/10-ribbon -permissions]} {[exec ls -lR $R/etc]}
ok "  a file that was there already is the person's: the machine's own kit.conf was not replaced" {
    [string match "keys = *" [readOr $R/etc/kit.conf]]} {[readOr $R/etc/kit.conf]}
ok "  the directories the packages want are made (/var/lib/greetd 0750; root's until the account exists)" {
    [file isdirectory $R/var/lib/greetd] && [string range [file attributes $R/var/lib/greetd -permissions] end-2 end] eq "750"}
set KD $top/srcpkgs/ribbon-kit/files/bin/kit-defaults
spit $R/etc/ribbon/ribbon.conf "mine\n"
file delete $R/etc/gamemode.ini
lassign [sh sh $KD $R] drc dout
ok "kit-defaults again (as at boot): an edited file stays, a deleted one comes back, nothing else changes" {
    $drc == 0 && [readOr $R/etc/ribbon/ribbon.conf] eq "mine\n" &&
    [readOr $R/etc/gamemode.ini] eq [slurp $top/srcpkgs/ribbon-gaming/files/gamemode.ini]} {$dout}
file delete $R/etc/gamemode.ini
exec ln -s /nowhere $R/etc/gamemode.ini
lassign [sh sh $KD $R] drc dout
ok "  a link in a default's place, even a dangling one, is left alone" {[file type $R/etc/gamemode.ini] eq "link" && [file readlink $R/etc/gamemode.ini] eq "/nowhere"}

# ---- two system kits, one path: kitd refuses before the set changes ------------------------------------------------
proc skit {name version files} {
    global T tclsh top env F
    set src $T/src/$name-$version
    file delete -force $src
    foreach {p d} $files { spit $src/$p $d }
    exec mkfs.erofs -Enoinline_data -T0 --all-root $T/$name-$version.erofs $src >/dev/null 2>@1
    spit $T/$name-$version.manifest "name org.test.$name version $version kind system summary {$name} license MIT x-short $name\n"
    file mkdir $T/empty
    exec $tclsh $top/kit/kitfmt/kitpack -q -mk4tcl $env(KITFMT_MK4TCL) -manifest $T/$name-$version.manifest \
        -image $T/$name-$version.erofs -verity yes -sign $F/test-system.key $T/empty $T/k/kits/org.test.$name-$version.kit 2>@1
}
skit shadow 1 {lib/ribbon/common.sh "not Ribbon's\n"}
skit fine 1 {lib/ribbon/extra.sh "beside Ribbon's\n"}
exec ln -s nowhere $T/linksrc ; file mkdir $T/src/overdir-1 ; exec ln -s /nowhere $T/src/overdir-1/bin
exec mkfs.erofs -Enoinline_data -T0 --all-root $T/overdir-1.erofs $T/src/overdir-1 >/dev/null 2>@1
spit $T/overdir-1.manifest "name org.test.overdir version 1 kind system summary {overdir} license MIT x-short overdir\n"
exec $tclsh $top/kit/kitfmt/kitpack -q -mk4tcl $env(KITFMT_MK4TCL) -manifest $T/overdir-1.manifest \
    -image $T/overdir-1.erofs -verity yes -sign $F/test-system.key $T/empty $T/k/kits/org.test.overdir-1.kit 2>@1
tool kitindex build -key $F/test-index.key -keys $L $T/k/kits $T/repo
foreach f [glob -nocomplain $R/var/cache/kit/index*] { file delete -force $f }   ;# the new index is read (the cached one is an hour good)
set before [readOr $R/var/lib/kit/active]
set mounts [exec grep -c " $R/usr " /proc/mounts]
set r [work grab shadow]
ok "a kit that brings a file another kit holds is refused, both kits and the path named; the set and /usr are as they were" {
    [dict get $r code] == 1 && [string match "*org.ribbon.tools and org.test.shadow both bring /usr/lib/ribbon/common.sh*" [dict get $r log][dict get $r out]] &&
    [readOr $R/var/lib/kit/active] eq $before && [readOr $R/usr/lib/ribbon/common.sh] eq [slurp $top/srcpkgs/ribbon-tools/files/lib/common.sh]} {[dict get $r log]\n[dict get $r out]}
ok "  nothing of the refused kit stays staged or in the store" {
    ![llength [glob -nocomplain $R/var/lib/kit/staging/*]] && ![string match "*org.test.shadow*" [exec sh -c "cat $R/var/lib/kit/store/*/info"]]} {[glob -nocomplain $R/var/lib/kit/staging/* $R/var/lib/kit/store/*]}
set r [work grab overdir]
ok "a link where other kits have a directory (/usr/bin) is refused the same way" {
    [dict get $r code] == 1 && [string match "*both bring /usr/bin*" [dict get $r log][dict get $r out]] && [file isdirectory $R/usr/bin] && [file type $R/usr/bin] eq "directory"} {[dict get $r log]\n[dict get $r out]}
set r [work grab fine]
ok "a kit that only shares directories with the others installs" {[dict get $r code] == 0 && [readOr $R/usr/lib/ribbon/extra.sh] eq "beside Ribbon's\n"} {[dict get $r log]\n[dict get $r out]}
} err opts]
if {$rc} { puts "  FAIL the test stopped: $err" ; puts [dict get $opts -errorinfo] ; set fail 1 }
cleanup
if {$fail} { puts "Ribbon's packages as kits: FAILED" ; exit 1 }
puts "Ribbon's packages as kits: $nok checks"
