# kit-scope.tcl -- one kit, two kinds, no flag: a person runs the same verbs for app kits and for system kits, and a kit's own
# (signed) kind decides where they run (srcpkgs/ribbon-kit/files/lib/scope.tcl, kitdc.tcl, bin/kitd's Start/Plan/Answer).
# Real kits (app and system, signed with the app and the system key), a real repository (file://), kitd on a private bus with a
# stand-in polkit, its system scope on a fake root whose /usr is the merged erofs view; `kit` runs as a person with a home of
# its own.  Run as root in a private mount namespace (tests/steps.d/75-kit-scope.sh: unshare -m).
#
# Checked: grab of an app kit and a system kit in one command runs each where its kind says, each with its own plan and
# question; polkit's weak action is asked to look (Start), the strong one only when the plan is answered yes, after the plan was
# shown, and not at all for a no; kit list shows both kinds; kit check, toss and rewind go to the right scope (plain rewind: the
# newest change of the two); kit info of a system kit; no bus to reach kitd on is said and the app part still runs; a system kit
# file is never handed to kitd; kitd itself refuses an app kit however it is asked (a client that lies); a polkit refusal at the
# answer leaves nothing changed and nothing waiting.
#
#   KITFMT_MK4TCL=<dir with Mk4tcl>  KIT_SWAPMOUNT=<built kit-swapmount>  tclsh tests/kit-scope.tcl
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
proc skip {why} { puts "  skip kit scopes ($why)" ; exit 0 }
proc slurp {p} { set f [open $p rb] ; set d [read $f] ; close $f ; return $d }
proc utf {p} { return [encoding convertfrom utf-8 [slurp $p]] }
proc spit {p d {mode ""}} {
    file mkdir [file dirname $p] ; set f [open $p wb] ; puts -nonewline $f $d ; close $f
    if {$mode ne ""} { file attributes $p -permissions $mode }
}
proc readOr {p} { if {[catch {slurp $p} d]} { return "" } ; return $d }

if {[exec id -u] != 0} { skip "needs root" }
if {[catch {exec grep -qw erofs /proc/filesystems}]} { skip "the kernel has no erofs" }
foreach t {losetup mount umount mountpoint mkfs.erofs veritysetup dbus-daemon} { if {[auto_execok $t] eq ""} { skip "no $t" } }
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
set env(KIT_EROFS_MIN) 1.0
unset -nocomplain env(KIT_INDEX) env(KIT_CRASH_AT) env(KIT_USR_VIEWS) env(KIT_USR) env(KIT_CONF) env(XDG_DATA_HOME) env(XDG_CACHE_HOME) env(XDG_CONFIG_HOME)

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

proc skit {name version files {more ""}} {
    global T tclsh top env F
    set src $T/src/$name-$version
    file delete -force $src
    foreach {p d} $files { spit $src/$p $d }
    exec mkfs.erofs -Enoinline_data -T0 --all-root $T/$name-$version.erofs $src >/dev/null 2>@1
    spit $T/$name-$version.manifest "name org.test.$name version $version kind system summary {$name} license MIT x-short $name\n$more"
    file mkdir $T/empty $T/kits
    set out $T/kits/org.test.$name-$version.kit
    exec $tclsh $top/kit/kitfmt/kitpack -q -mk4tcl $env(KITFMT_MK4TCL) -manifest $T/$name-$version.manifest \
        -image $T/$name-$version.erofs -verity yes -sign $F/test-system.key $T/empty $out 2>@1
    return $out
}
proc akit {name version} {
    global T tclsh top env F
    spit $T/src/$name-$version/bin/app "app\n" 493
    spit $T/$name-$version.manifest "name org.test.$name version $version kind app summary {$name} x-short $name entries {{$name bin/app {} cli}}"
    file mkdir $T/kits
    set out $T/kits/org.test.$name-$version.kit
    exec $tclsh $top/kit/kitfmt/kitpack -q -mk4tcl $env(KITFMT_MK4TCL) -manifest $T/$name-$version.manifest \
        -sign $F/test-app.key $T/src/$name-$version $out 2>@1
    return $out
}
if {[catch {
    set kBase [skit base 1 {bin/sh "base sh\n"} "x-essential yes"]
    set kMesa1 [skit mesa 1 {lib/libGL.so.1 "mesa 1\n"}]
    set kMesa2 [skit mesa 2 {lib/libGL.so.1 "mesa 2\n"}]
    set kTools [skit tools 1 {bin/tool "tool 1\n"}]
    set kApp [akit hello 1]
    set kApp2 [akit editor 1]
} e]} { puts "  FAIL making the test kits: $e" ; exit 1 }
set REPO $T/repo
proc publish {args} {
    global REPO T
    file mkdir $REPO.kits
    foreach k $args { file copy -force $k $REPO.kits/ }
    tool kitindex build -key $::F/test-index.key -keys $::L $REPO.kits $REPO
}
publish $kBase $kMesa1 $kTools $kApp $kApp2

# ---- the machine: a fake root, stand-ins, kitd on a private bus with a stand-in polkit -----------------
file mkdir $R/etc $R/usr $T/bin $T/home $T/fix
spit $R/etc/kit.conf "keys = $L\nmirror = file://$REPO\ntimeout = 5\n"
set SNAPLOG $T/snapshot.log
spit $T/bin/snapshot "#!/bin/sh
echo \"\$*\" >>$SNAPLOG
case \$1 in
backend) echo btrfs ;;
pre) n=\$(grep -c '^pre ' $SNAPLOG); echo \$((40 + n)) ;;
esac
" 0755
spit $T/bin/dinitctl "#!/bin/sh\nexit 1\n" 0755
spit $T/bin/udevadm "#!/bin/sh\nexit 0\n" 0755
set env(KIT_SNAPSHOT) $T/bin/snapshot
set env(KIT_DINITCTL) $T/bin/dinitctl
set env(KIT_UDEVADM) $T/bin/udevadm
spit $T/boot_id "boot-1\n"
set env(KIT_BOOT_ID_FILE) $T/boot_id
set env(KITD_ROOT) $R
set env(KITD_IDLE) 60
set env(POLKIT_FIX) $T/fix
set env(KIT_SYSTEM_ROOT) $R
set env(DBUS_SYSTEM_BUS_ADDRESS) unix:path=$T/bus
file mkdir $T/services
set svc [slurp $top/srcpkgs/ribbon-kit/files/dbus/org.ribbon.Kit1.service]
spit $T/services/org.ribbon.Kit1.service [string map [list "Exec=/usr/lib/ribbon/kit/kitd" "Exec=$tclsh $KITD"] $svc]
spit $T/bus.conf "<!DOCTYPE busconfig PUBLIC \"-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN\" \"http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd\">
<busconfig><type>session</type><listen>unix:path=$T/bus</listen><auth>EXTERNAL</auth><servicedir>$T/services</servicedir>
<policy context=\"default\"><allow user=\"*\"/><allow send_destination=\"*\" eavesdrop=\"true\"/><allow eavesdrop=\"true\"/><allow own=\"*\"/></policy></busconfig>"
set pids {}
proc cleanup {} {
    foreach p $::pids { catch {exec kill $p} }
    after 300
    catch {exec umount -l $::R/usr}
}
set dpid [exec timeout 900 dbus-daemon --nofork --nopidfile --config-file=$T/bus.conf >/dev/null 2>$T/daemon.log &]
lappend pids $dpid
set t0 [clock milliseconds]
while {![file exists $T/bus] && [clock milliseconds] - $t0 < 5000} { after 50 }
if {![file exists $T/bus]} { puts "  FAIL dbus-daemon did not start: [readOr $T/daemon.log]" ; cleanup ; exit 1 }
set pk [open |[list $tclsh $top/tests/fixtures/polkit-authority.tcl 2>@1] r+]
lappend pids [pid $pk]
if {[set rl [gets $pk]] ne "ready"} { puts "  FAIL the polkit stand-in did not start: $rl [read $pk]" ; cleanup ; exit 1 }
proc polkit {answer {action ""}} { spit $::T/fix/answer[expr {$action eq "" ? "" : ".$action"}] "$answer\n" }
proc actions {} { return [lmap l [split [string trim [readOr $::T/fix/calls]] \n] { if {$l eq ""} continue ; lindex $l 3 }] }
proc forget {} { file delete $::T/fix/calls }
polkit yes

# ---- the person: kit with a home of its own ---------------------------------------------------------
set env(HOME) $T/home
set env(KIT_CONF) $R/etc/kit.conf
proc kit {args} {
    global KIT tclsh
    set in ""
    if {[lindex $args 0] eq "-in"} { set in [lindex $args 1] ; set args [lrange $args 2 end] }
    set code 0
    if {[catch {exec timeout -k 5 120 $tclsh $KIT {*}$args << $in 2>@1} out opts]} {
        set ec [dict get $opts -errorcode]
        set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : "error"}]
    }
    return [dict create code $code out $out]
}
proc show {r} { return "exit [dict get $r code]\n[dict get $r out]" }
proc userset {} { return [readOr $::T/home/.local/share/kit/active] }
proc sysset {} { return [readOr $::R/var/lib/kit/active] }

set rc [catch {
# ==== one command, two kinds ===========================================================================
set r [kit list]
ok "nothing installed anywhere: kit list says so" {[dict get $r code] == 0 && [string trim [dict get $r out]] eq "No kits installed"} {[show $r]}

forget
set r [kit grab --yes org.test.hello org.test.mesa]
ok "grab of an app kit and a system kit in ONE command: done" {[dict get $r code] == 0} {[show $r]}
ok "  the app kit is in the person's own set, the system kit in the machine's" {
    [string match "*org.test.hello*" [userset]] && ![string match "*org.test.mesa*" [userset]] &&
    [string match "*org.test.mesa*" [sysset]] && ![string match "*org.test.hello*" [sysset]]} {user: [userset]\nsystem: [sysset]}
ok "  the system kit's files are the machine's /usr, and no flag was named" {[readOr $R/usr/lib/libGL.so.1] eq "mesa 1\n"} {[exec ls -R $R/usr]}
set out [dict get $r out]
ok "  each kind had its own plan and question, in kit's own words" {
    [regexp {hello +new +1} $out] && [regexp {mesa +new +1} $out] && [regexp -all {Install\? \[Y/n\] y} $out] == 2} {$out}
set acts [actions]
ok "  polkit was asked to look first (the plan action), then, for the yes, once for the strong action, in that order" {
    $acts eq {org.ribbon.kit.system.plan org.ribbon.kit.system}} {$acts}
ok "  the snapshot of the system change was taken (kitd's snapshot hook), the app kit needed none" {[string match "*pre before kit grab: mesa 1*" [readOr $SNAPLOG]]} {[readOr $SNAPLOG]}

set r [kit list]
ok "kit list shows both kinds, the system kit marked" {
    [dict get $r code] == 0 && [regexp -line {^  hello +1 .*$} [dict get $r out]] && [regexp -line {^  mesa +1 .* system$} [dict get $r out]]} {[show $r]}

# ==== the plan can be refused: nothing changes, the strong action is not asked ===========================
forget
set before [sysset]
set r [kit -in "n\n" grab org.test.tools]
ok "a no to the system plan: exit 1, nothing installed, nothing waiting" {[dict get $r code] == 1 && [sysset] eq $before} {[show $r]}
set acts [actions]
ok "  polkit was asked to look, and never for the strong action (nothing was agreed to)" {$acts eq {org.ribbon.kit.system.plan}} {$acts}
ok "  the worker was released (no transaction left waiting)" {[llength [glob -nocomplain $R/var/lib/kit/queue/*.plan]] == 0} {[glob -nocomplain $R/var/lib/kit/queue/*]}

# ==== polkit refuses the yes ===============================================================================
forget
polkit no org.ribbon.kit.system
set r [kit grab --yes org.test.tools]
ok "polkit refusing the strong action at the answer: not allowed (exit 1), nothing installed" {
    [dict get $r code] == 1 && [string match "*not allowed*" [dict get $r out]] && [sysset] eq $before} {[show $r]}
# the worker polls for the answer a moment; give it that
set t0 [clock milliseconds]
while {([llength [glob -nocomplain $R/var/lib/kit/queue/*.plan]] || [llength [glob -nocomplain $R/var/lib/kit/queue/*.answer]]) && [clock milliseconds] - $t0 < 5000} { after 100 }
ok "  the worker was released all the same (a refused authorization is a no)" {[llength [glob -nocomplain $R/var/lib/kit/queue/*.plan]] == 0 &&
    [llength [glob -nocomplain $R/var/lib/kit/queue/*.answer]] == 0} {[glob -nocomplain $R/var/lib/kit/queue/*]}
file delete $T/fix/answer.org.ribbon.kit.system
polkit yes

# ==== check, info, toss, rewind ============================================================================
publish $kMesa2
set r [kit grab --yes org.test.hello]
ok "an app kit that is up to date: nothing to do, kitd not involved" {[dict get $r code] == 0} {[show $r]}
forget
set r [kit check --yes]
ok "kit check covers the system's kits as well: mesa 2" {[dict get $r code] == 0 && [regexp {mesa +1 +\u2192 2} [dict get $r out]] && [regexp {org\.test\.mesa\t2} [sysset]]} {[show $r]}
ok "  the app part had nothing to update and said nothing of the system" {![regexp {hello +1 +\u2192} [dict get $r out]]}
set r [kit info org.test.mesa]
ok "kit info of a system kit, by name" {[dict get $r code] == 0 && [string match "*mesa*" [dict get $r out]]} {[show $r]}
forget
set r [kit toss --yes mesa]
ok "kit toss by the SHORT name of an installed system kit goes to the machine's scope" {[dict get $r code] == 0 && ![regexp {org.test.mesa\t2} [sysset]]} {[show $r]\n[sysset]}
ok "  the app kit was not asked about" {![string match "*hello*" [dict get $r out]]} {[dict get $r out]}
set r [kit rewind --yes]
ok "plain kit rewind takes back the last change, whichever scope made it: the system's toss, mesa is back" {
    [dict get $r code] == 0 && [string match "*org.test.mesa*" [sysset]]} {[show $r]\n[sysset]}
set r [kit grab --yes org.test.editor]
set r [kit rewind --yes]
ok "  and when the newest change was the app kit's, the person's own scope rewinds it" {
    [dict get $r code] == 0 && ![string match "*org.test.editor*" [userset]] && [string match "*org.test.mesa*" [sysset]]} {[show $r]\n[userset]}

# ==== a file, a missing bus, and a client that lies ===============================================================
set r [kit grab --yes $kTools]
ok "a system kit FILE is refused in the person's scope: it is not handed to kitd" {
    [dict get $r code] == 2 && [string match "*a file is never handed over*" [dict get $r out]] && ![string match "*org.test.tools*" [sysset]]} {[show $r]}
# kitd, asked by a client that lies about the kind (it wants an app kit installed system-wide), refuses on its own
set ::env(KITD_BUS) unix:path=$T/bus
package require Tcl
lappend ::auto_path $top/srcpkgs/ribbon-desktop/files
set b [exec $tclsh << "
lappend auto_path {$top/srcpkgs/ribbon-desktop/files}
package require ribbon::dbus
set bus \[ribbon::dbus::connect system\]
set id \[lindex \[\$bus call org.ribbon.Kit1 /org/ribbon/Kit1 org.ribbon.Kit1 Submit as {grab org.test.editor}\] 0\]
for {set i 0} {\$i < 150} {incr i} {
    set j \[lindex \[\$bus call org.ribbon.Kit1 /org/ribbon/Kit1 org.ribbon.Kit1 Job s \$id\] 0\]
    if {\[lindex \$j 0\] eq {done}} break
    after 200
}
puts \"\[lindex \$j 1\] \[join \[lindex \$j 2\] { }\]\"
"]
ok "a client that asks kitd to install an APP kit system-wide is refused by kitd itself (exit 2), whatever it was told" {
    [string match "2 *org.test.editor is an app kit; app kits are installed per user*" $b] && ![string match "*org.test.editor*" [sysset]]} {$b}
unset ::env(KITD_BUS)

set ::env(DBUS_SYSTEM_BUS_ADDRESS) unix:path=$T/no-such-bus
set r [kit grab --yes org.test.tools]
ok "no system bus: a system kit by name says so (exit 3)" {[dict get $r code] == 3 && [string match "*system kits are changed through kitd, and there is no system bus*" [dict get $r out]]} {[show $r]}
set r [kit grab --yes org.test.editor org.test.tools]
ok "  and the app kit named beside it is still installed" {[string match "*org.test.editor*" [userset]]} {[show $r]\n[userset]}
set r [kit check --yes]
ok "a plain check with no bus: this person's kits are checked, the system's are said to wait, exit 0" {
    [dict get $r code] == 0 && [string match "*the system's kits were not checked*" [dict get $r out]]} {[show $r]}
set ::env(DBUS_SYSTEM_BUS_ADDRESS) unix:path=$T/bus
} err opts]
if {$rc} { puts "  FAIL the test stopped: $err" ; puts [dict get $opts -errorinfo] ; set fail 1 }
cleanup
catch {file delete -force $T}
if {$fail} { puts "kit scopes: FAILED" ; exit 1 }
puts "kit scopes: $nok checks"
