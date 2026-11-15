# kitd.tcl -- kit's privileged helper (srcpkgs/ribbon-kit/files/bin/kitd) and the system scope it runs in
# (lib/system.tcl), run by tests/steps.d/72-kitd.sh:
#
#   tclsh8.6 tests/kitd.tcl        (TCLLIBPATH: unix_extra; dbus-daemon on the PATH)
#
# On a private bus standing in for the system bus, with a stand-in polkit Authority
# (tests/fixtures/polkit-authority.tcl) and a fake root: D-Bus activation from the packaged service file's
# name, polkit asked with the caller's bus name (interactive or not; no, challenge, yes), bad verbs refused
# before polkit, transactions run one at a time in system scope (their output, exit code and Finished
# signal), the queue's order, Cancel, a kitd killed mid-transaction and started again, the idle exit and
# activation again, Pending from the restart record of this boot only.  In this process: the system
# scope's paths, refuse in both scopes, the restart record across boots, settle, waiting from the record
# and the queue, the never-live /proc scan on a fake /proc and the real one, and txn.tcl's amend (the
# history entry's "data" answer).  NOT covered: a real polkitd and the real system bus's policy (the
# packaged files are checked with xmllint), a second user calling Cancel, system kits installed for real.

set top [file dirname [file dirname [file normalize [info script]]]]
set KL $top/srcpkgs/ribbon-kit/files/lib
set KITD $top/srcpkgs/ribbon-kit/files/bin/kitd
set tclsh [info nameofexecutable]
lappend auto_path $top/srcpkgs/ribbon-desktop/files
package require ribbon::dbus
set fails 0 ; set nok 0
proc ok {name cond {detail ""}} {
    if {[uplevel 1 [list expr $cond]]} { incr ::nok ; puts "  ok   $name" ; return 1 }
    incr ::fails ; puts "  FAIL $name"
    catch {set detail [uplevel 1 [list subst $detail]]}
    if {$detail ne ""} { foreach l [split [string trimright $detail \n] \n] { puts "         | $l" } }
    return 0
}
proc spit {path data} { file mkdir [file dirname $path] ; set ch [open $path {WRONLY CREAT TRUNC}] ; puts -nonewline $ch $data ; close $ch }
proc slurp {path} { set ch [open $path] ; set d [read $ch] ; close $ch ; return $d }
# poll until SCRIPT is true or MS pass (the event loop runs meanwhile)
proc waitfor {ms script} {
    set end [expr {[clock milliseconds] + $ms}]
    while {[clock milliseconds] < $end} {
        if {[uplevel 1 [list expr $script]]} { return 1 }
        after 50 [list set ::tick 1] ; vwait ::tick
    }
    return [uplevel 1 [list expr $script]]
}

set W [file normalize [exec mktemp -d]]
set R $W/root
set pids {}
proc cleanup {} { foreach p $::pids { catch {exec kill $p} } ; catch {exec kill {*}[owners]} ; file delete -force $::W }
proc owners {} { return {} }

# ==== in this process: system.tcl and txn.tcl ===========================================================
set ::env(KIT_NOSYNC) 1
set ::env(KIT_BOOT_ID_FILE) $W/boot_id
spit $W/boot_id "boot-one\n"
namespace eval ::kit { variable libdir $::KL }
source -encoding utf-8 $KL/core.tcl
::kit::init
foreach m {system store txn} { ::kit::need $m }

ok "user scope: refuse names a system kit as not installable here, lets an app kit through" {
    [catch {::kit::system::refuse system org.ribbon.linux} e] && [string match "*system kit; system kits are installed for the whole system by kitd*" $e] &&
    ![catch {::kit::system::refuse app org.example.app}]} {$e}
ok "user scope: nothing waits (no restart record, no queue)" {![::kit::system::waiting {} {name org.ribbon.linux version 6.18.60}]}

set root [::kit::system::scope $R]
ok "system scope: kit's paths under the root (/var/lib/kit, /var/cache/kit, /etc/kit.conf; keys in data/keys)" {
    $root eq $R && [::kit::path data] eq "$R/var/lib/kit" && [::kit::path store] eq "$R/var/lib/kit/store" &&
    [::kit::path cache] eq "$R/var/cache/kit" && [::kit::path conf] eq "$R/etc/kit.conf" && [::kit::path queue] eq "$R/var/lib/kit/queue" &&
    [::kit::path data keys] eq "$R/var/lib/kit/keys" && [::kit::path lock] eq "$R/var/lib/kit/lock"}
ok "system scope: an app kit is refused by name (app kits are per user), a system kit goes through" {
    [catch {::kit::system::refuse app org.example.app} e1] && [string match "org.example.app is an app kit; app kits are installed per user*" $e1] &&
    [lindex $::errorCode 0] eq "KIT" && [lindex $::errorCode 1] == 2 && ![catch {::kit::system::refuse system org.ribbon.mesa} e2]} {$e1\n$e2}

# the restart record
ok "restart record: empty before anything is recorded" {[::kit::system::pending] eq {}}
::kit::system::pend org.ribbon.linux 6.18.58
::kit::system::pend org.ribbon.linux 6.18.60
::kit::system::pend org.ribbon.dinit 0.19.4
ok "restart record: one entry per kit, the newer version replacing the older, plain text with the boot id" {
    [::kit::system::pending] eq {{org.ribbon.linux 6.18.60} {org.ribbon.dinit 0.19.4}} &&
    [slurp $R/var/lib/kit/restart] eq "boot boot-one\nkit org.ribbon.linux 6.18.60\nkit org.ribbon.dinit 0.19.4\n"} {[slurp $R/var/lib/kit/restart]}
ok "waiting: the recorded version waits for the restart, another version of it does not" {
    [::kit::system::waiting {} {name org.ribbon.linux version 6.18.60}] && ![::kit::system::waiting {} {name org.ribbon.linux version 6.18.61}]}
spit $W/boot_id "boot-two\n"
ok "restart record: after a restart (another boot id) the record is spent: nothing waits" {
    [::kit::system::pending] eq {} && ![::kit::system::waiting {} {name org.ribbon.linux version 6.18.60}]}
::kit::system::pend org.ribbon.mesa 25.2.8
ok "restart record: the first entry of a new boot starts a new record" {[slurp $R/var/lib/kit/restart] eq "boot boot-two\nkit org.ribbon.mesa 25.2.8\n"}

# settle: the kits a transaction changed that take effect at restart are recorded
file delete $R/var/lib/kit/restart
proc kinfo {root kind short fields} {
    spit [::kit::path store $root info] [dict create name x version x short $short kind $kind summary "" size 0 fields $fields needs {} provides {} perms {} entries {} effects {} exports {} signer {} installed 0 origin repo]
}
kinfo r1 system linux {restart yes} ; kinfo r2 system linux {restart yes} ; kinfo r3 system mesa {}
kinfo r4 system glibc {} ; kinfo r5 system glibc {}
proc kset {args} { set k [dict create] ; foreach {n v r why} $args { dict set k "$n $v" [dict create name $n version $v root $r reason $why started 0] } ; return [dict create kits $k] }
set B [kset org.ribbon.linux 6.18.58 r1 user org.ribbon.mesa 25.2.7 r3 user org.gnu.glibc 2.41 r4 user]
set A [kset org.ribbon.linux 6.18.58 r1 prev org.ribbon.linux 6.18.60 r2 user org.ribbon.mesa 25.2.8 r3 user org.gnu.glibc 2.41 r4 user]
set got [::kit::system::settle $B $A]
ok "settle: a new kernel kit (manifest restart) is recorded; mesa (live) and an unchanged glibc are not; the kept old kernel is not" {
    $got eq {{org.ribbon.linux 6.18.60}} && [::kit::system::pending] eq {{org.ribbon.linux 6.18.60}}} {$got}
set got [::kit::system::settle $A [kset org.gnu.glibc 2.42 r5 user org.ribbon.linux 6.18.60 r2 user]]
ok "settle: a never-live kit by its short name (glibc) is recorded too, beside the kernel" {
    $got eq {{org.gnu.glibc 2.42}} && [::kit::system::pending] eq {{org.ribbon.linux 6.18.60} {org.gnu.glibc 2.42}}} {$got}

# waiting from kitd's queue
proc job {id state words} { spit [::kit::path queue $id] [dict create id $id uid 1000 words $words state $state code "" submitted 0 started "" finished "" pid ""] }
job 100-1 queued {grab mesa}
job 100-2 running {check org.ribbon.ffmpeg@7.1.2}
job 100-3 done {grab vulkan}
job 100-4 queued {toss gimp}
set rec {name org.ribbon.mesa version 25.2.9}
ok "waiting: a queued grab of the kit by its short name waits" {[::kit::system::waiting {} $rec]}
ok "waiting: a running check of NAME@VERSION waits for that version only" {
    [::kit::system::waiting {} {name org.ribbon.ffmpeg version 7.1.2}] && ![::kit::system::waiting {} {name org.ribbon.ffmpeg version 7.1.3}]}
ok "waiting: a finished grab, a toss, and kits nobody queued do not wait" {
    ![::kit::system::waiting {} {name org.ribbon.vulkan version 1}] && ![::kit::system::waiting {} {name org.ribbon.gimp version 3}] &&
    ![::kit::system::waiting {} {name org.ribbon.other version 1}]}
set ::env(KITD_JOB) 100-1
ok "waiting: the transaction asking (KITD_JOB) is not waiting for itself" {![::kit::system::waiting {} $rec]}
unset ::env(KITD_JOB)
ok "queue: read in submission order" {[lmap j [::kit::system::queue] { dict get $j id }] eq {100-1 100-2 100-3 100-4}}
file delete -force [::kit::path queue]

# the never-live scan, on a fake /proc
set P $W/proc
proc proc_ {pid comm cmdline maps} { spit $::P/$pid/comm "$comm\n" ; spit $::P/$pid/cmdline [join $cmdline \0]\0 ; spit $::P/$pid/maps $maps }
set lib "7f0000000000-7f0000020000 r-xp 00000000 fd:01 1234                       /usr/lib/libc.so.6"
proc_ 1 dinit {/sbin/dinit} "$lib (deleted)\n"
proc_ 310 dbus-daemon {dbus-daemon --system --nofork} "$lib (deleted)\n7f0000030000-7f0000040000 r--p 00000000 fd:01 99 /usr/lib/libdbus-1.so.3 (deleted)\n"
proc_ 2201 dbus-daemon {dbus-daemon --session --address=unix:path=/run/user/1000/bus} "$lib (deleted)\n"
proc_ 4000 firefox {/usr/lib/firefox/firefox} "$lib (deleted)\n"
proc_ 4001 elogind-daemon {/usr/libexec/elogind/elogind} "$lib\n"
proc_ 4002 greetd {greetd} "7f0000000000-7f0000020000 r-xp 00000000 00:00 0 \[heap\]\n"
spit $P/self/comm x
set ::kit::system::procDir $P
set sc [::kit::system::scan]
ok "scan: processes that map replaced (deleted) files, with the files; live mappings and anonymous ones are not" {
    [lmap s $sc { lindex $s 0 }] eq {1 310 2201 4000} && [lindex $sc 1 2] eq {/usr/lib/libc.so.6 /usr/lib/libdbus-1.so.3}} {$sc}
set st [::kit::system::stale]
ok "stale: the never-live ones only (dinit, the system bus), with their kits; not the session bus, not firefox" {
    $st eq {{dinit dinit 1} {dbus-daemon dbus 310}}} {$st}
set ::kit::system::procDir /proc
ok "scan: the real /proc reads without failing" {![catch {::kit::system::scan} e]} {$e}
ok "waiting still answers in system scope with an empty queue" {![::kit::system::waiting {} {name org.ribbon.x version 1}]}

# txn.tcl: a change's log entry amended after its switch (toss's data answer)
set e0 [dict create op toss time 1 before "" after ""]
spit [::kit::path data history 5-1] $e0
ok "amend: the answer is added to the entry; the rest stays" {[::kit::txn::amend 5-1 data {org.kde.krita kept}] &&
    [dict get [::kit::txn::entry 5-1] data] eq {org.kde.krita kept} && [dict get [::kit::txn::entry 5-1] op] eq "toss"}
ok "amend: a change without an entry (or no id) is left alone" {![::kit::txn::amend 9-9 data x] && ![::kit::txn::amend "" data x]}
ok "amend: no temporary file is left in the log, and the log lists the entry once" {
    [glob -nocomplain -tails -directory [::kit::path data history] *] eq {5-1} && [::kit::txn::history] eq {5-1}}
ok "apply records its id as txn::last (what toss amends)" {[info exists ::kit::txn::last] && [string match {*set ::kit::txn::last $id*} [info body ::kit::txn::apply]]}
file delete -force $R

# ==== kitd on a private bus ==================================================================================
# packaged files
set svc [slurp $top/srcpkgs/ribbon-kit/files/dbus/org.ribbon.Kit1.service]
ok "the activation file: org.ribbon.Kit1, /usr/lib/ribbon/kit/kitd, as root" {
    [regexp -line {^Name=org\.ribbon\.Kit1$} $svc] && [regexp -line {^Exec=/usr/lib/ribbon/kit/kitd$} $svc] && [regexp -line {^User=root$} $svc]}
if {[auto_execok xmllint] ne ""} {
    set pol $top/srcpkgs/ribbon-kit/files/polkit/org.ribbon.kit.policy
    set conf $top/srcpkgs/ribbon-kit/files/dbus/org.ribbon.Kit1.conf
    ok "the polkit policy and the bus policy are well-formed; the policy has kitd's action, an admin kept" {
        ![catch {exec xmllint --noout --nonet $pol $conf 2>@1}] && [string first {<action id="org.ribbon.kit.system">} [slurp $pol]] >= 0 &&
        [string first {<allow_active>auth_admin_keep</allow_active>} [slurp $pol]] >= 0 &&
        [string first {set action org.ribbon.kit.system} [string map {"variable action" "set action"} [slurp $KITD]]] >= 0 &&
        [string first {<allow own="org.ribbon.Kit1"/>} [slurp $conf]] >= 0}
} else { puts "  skip the policies' XML (no xmllint)" }

# the bus: a session-type bus (it starts services itself) at a known path, with a service directory
file mkdir $W/services $R/etc
spit $W/services/org.ribbon.Kit1.service [string map [list "Exec=/usr/lib/ribbon/kit/kitd" "Exec=$tclsh $KITD"] $svc]
spit $W/bus.conf "<!DOCTYPE busconfig PUBLIC \"-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN\" \"http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd\">
<busconfig><type>session</type><listen>unix:path=$W/bus</listen><auth>EXTERNAL</auth><servicedir>$W/services</servicedir>
<policy context=\"default\"><allow user=\"*\"/><allow send_destination=\"*\" eavesdrop=\"true\"/><allow eavesdrop=\"true\"/><allow own=\"*\"/></policy></busconfig>"
set ::env(DBUS_SYSTEM_BUS_ADDRESS) unix:path=$W/bus
set ::env(KITD_ROOT) $R
set ::env(KITD_IDLE) 2
set ::env(POLKIT_FIX) $W
spit $W/boot_id "boot-three\n"
# the stuck mirror: accepts and never answers, so a transaction stays running for a while
set stuck [socket -server [list apply {{ch a p} { lappend ::stuckConns $ch }}] -myaddr 127.0.0.1 0]
set port [lindex [fconfigure $stuck -sockname] 2]
spit $R/etc/kit.conf "mirror = http://127.0.0.1:$port/\ntimeout = 3\n"
set dpid [exec timeout 300 dbus-daemon --nofork --nopidfile --config-file=$W/bus.conf >/dev/null 2>$W/daemon.log &]
lappend pids $dpid
if {![waitfor 5000 {[file exists $W/bus]}]} { puts "  FAIL dbus-daemon did not start: [slurp $W/daemon.log]" ; cleanup ; exit 1 }
set pk [open |[list $tclsh $top/tests/fixtures/polkit-authority.tcl 2>@1] r+]
lappend pids [pid $pk]
if {[gets $pk] ne "ready"} { puts "  FAIL the polkit stand-in did not start" ; cleanup ; exit 1 }
spit $W/answer no

if {[catch {
set bus [ribbon::dbus::connect system]
set K [list org.ribbon.Kit1 /org/ribbon/Kit1 org.ribbon.Kit1]
proc has {name} { lindex [$::bus call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus NameHasOwner s $name] 0 }
proc kitdPid {} { lindex [$::bus call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetConnectionUnixProcessID s org.ribbon.Kit1] 0 }
proc owners {} { if {[catch {kitdPid} p]} { return {} } ; return $p }
proc kcall {member args} { $::bus call {*}$::K $member {*}$args }
proc kcall0 {member} { $::bus call {*}$::K $member }
proc calls {} { if {[catch {slurp $::W/calls} d]} { return {} } ; return [split [string trim $d] \n] }
set finished {} ; set changes 0
$bus listen -interface org.ribbon.Kit1 -member Finished {apply {{m id code} { lappend ::finished $id $code }}}
$bus listen -interface org.ribbon.Kit1 -member Changed {apply {{m} { incr ::changes }}}

ok "before anything calls it, kitd is not running" {![has org.ribbon.Kit1]}
set q [kcall0 Queue]
ok "the first call starts kitd (D-Bus activation) and answers: an empty queue" {[has org.ribbon.Kit1] && [lindex $q 0] eq {}} {$q}

set rc [catch {kcall Submit as {list}} e]
set c [lindex [calls] end]
ok "Submit: polkit says no: AccessDenied, nothing queued" {$rc && [lindex $::errorCode 1] eq "org.freedesktop.DBus.Error.AccessDenied" && [lindex [kcall0 Queue] 0] eq {} &&
    ![llength [glob -nocomplain -directory $R/var/lib/kit/queue *]]} {$e}
ok "Submit: polkit is asked for org.ribbon.kit.system with the caller's bus name as the subject, not interactive" {
    [lindex $c 1] eq "system-bus-name" && [lindex $c 2] eq [$bus name] && [lindex $c 3] eq "org.ribbon.kit.system" && [lindex $c 4] == 0} {$c}
set rc [catch {$bus call -interactive 1 {*}$K Submit as {list}} e]
ok "Submit with interactive authorization allowed: polkit may ask (flags 1)" {$rc && [lindex [lindex [calls] end] 4] == 1} {[lindex [calls] end]}
spit $W/answer challenge
set rc [catch {kcall Submit as {list}} e]
ok "Submit: polkit wants authentication that was not allowed: AccessDenied, saying so" {$rc && [string match "*authentication*" $e]} {$e}
set n [llength [calls]]
set r1 [catch {kcall Submit as {run org.example.app}} e1]
set r2 [catch {kcall Submit as {grab --yes}} e2]
set r3 [catch {kcall Submit as {}} e3]
ok "Submit: a verb kitd does not run, an option, nothing at all: InvalidArgs, and polkit is not even asked" {
    $r1 && $r2 && $r3 && [string match "*not \"run\"*" $e1] && [string match "*not a kit name*" $e2] && [llength [calls]] == $n} {$e1\n$e2\n$e3}

spit $W/answer yes
set id [lindex [kcall Submit as {list}] 0]
ok "Submit with polkit's yes: an id" {[regexp {^[0-9]+-[0-9]+$} $id]} {$id}
ok "the transaction runs in system scope and Finished says how it ended (0)" {[waitfor 15000 {[dict exists $::finished $id]}] && [dict get $finished $id] == 0} {$finished}
set j [kcall Job s $id]
ok "Job: done, its exit code, and what it printed" {[lindex $j 0 0] eq "done" && [lindex $j 0 1] == 0 && [lindex $j 0 2] eq {{No kits installed}}} {$j}
set j [slurp $R/var/lib/kit/queue/$id]
ok "the queue entry on disk: who asked (the uid the bus knows), the words, done with code 0" {
    [dict get $j uid] == [exec id -u] && [dict get $j words] eq {list} && [dict get $j state] eq "done" && [dict get $j code] == 0} {$j}
ok "Changed was signalled as the queue moved" {$changes >= 2} {$changes}

# one at a time, in order; Cancel
set a [lindex [kcall Submit as {check}] 0]
set b [lindex [kcall Submit as {list}] 0]
waitfor 5000 {[llength [lindex [kcall0 Queue] 0]] == 2 && [lindex [kcall0 Queue] 0 0 1] eq "running"}
set q [lindex [kcall0 Queue] 0]
ok "Queue: the first transaction running (the mirror does not answer), the second queued behind it" {
    [lindex $q 0 0] eq $a && [lindex $q 0 1] eq "running" && [lindex $q 1 0] eq $b && [lindex $q 1 1] eq "queued" && [lindex $q 1 3] eq {list}} {$q}
set rc [catch {kcall Cancel s $a} e]
ok "Cancel of the running one: refused (NotQueued)" {$rc && [lindex $::errorCode 1] eq "org.ribbon.Kit1.Error.NotQueued"} {$e}
ok "Cancel of the queued one: it is gone" {![catch {kcall Cancel s $b}] && [llength [lindex [kcall0 Queue] 0]] == 1 && ![file exists $R/var/lib/kit/queue/$b]}
set rc [catch {kcall Cancel s 1-1} e]
ok "Cancel of a transaction that does not exist: InvalidArgs" {$rc && [lindex $::errorCode 1] eq "org.freedesktop.DBus.Error.InvalidArgs"} {$e}
ok "the stuck check ends with kit's network code (3), and the cancelled one never ran" {
    [waitfor 20000 {[dict exists $::finished $a]}] && [dict get $finished $a] == 3 && ![dict exists $finished $b]} {$finished}
set j [kcall Job s $a]
ok "its output says why" {[string match "*127.0.0.1*" [join [lindex $j 0 2] \n]]} {$j}
# that output names the mirror as configured: another user may not read it (root and the one who queued it may)
if {[auto_execok setpriv] ne "" && [exec id -u] == 0} {
    file attributes $W -permissions 0755
    spit $W/probe.tcl [string map [list @LIB@ $top/srcpkgs/ribbon-desktop/files @ID@ $a] {
        lappend auto_path @LIB@
        package require ribbon::dbus
        set b [ribbon::dbus::connect system]
        if {[catch {$b call org.ribbon.Kit1 /org/ribbon/Kit1 org.ribbon.Kit1 Job s @ID@} r]} { puts "error [lindex $::errorCode 1]" } else { puts "ok $r" }
    }]
    file attributes $W/probe.tcl -permissions 0644
    # the other user reads the Tcl packages from copies of its own (the caller's may sit in a private directory)
    set tlp {}
    foreach d [expr {[info exists ::env(TCLLIBPATH)] ? $::env(TCLLIBPATH) : ""}] {
        if {![file isdirectory $d]} continue
        set c $W/tlp/[llength $tlp]
        file mkdir $W/tlp
        file copy $d $c
        lappend tlp $c
    }
    if {[llength $tlp]} { exec chmod -R a+rX $W/tlp }
    catch {exec setpriv --reuid=65534 --regid=65534 --clear-groups env TCLLIBPATH=$tlp $tclsh $W/probe.tcl 2>@1} other
    ok "Job: another user may not read a transaction's output (AccessDenied)" {$other eq "error org.freedesktop.DBus.Error.AccessDenied"} {$other}
} else { puts "  skip Job as another user (needs root and setpriv)" }

# kitd killed while a transaction runs, then started again by the next call
foreach ch [set ::stuckConns] { catch {close $ch} } ; set ::stuckConns {}
set c [lindex [kcall Submit as {check}] 0]
waitfor 5000 {[lindex [kcall0 Queue] 0 0 1] eq "running"}
set wpid [dict get [slurp $R/var/lib/kit/queue/$c] pid]
exec kill -9 [kitdPid]
waitfor 5000 {![has org.ribbon.Kit1]}
set q [kcall0 Queue]
ok "kitd killed mid-transaction: the next call starts it again, and the transaction it left is still shown running" {
    [has org.ribbon.Kit1] && [lindex $q 0 0 0] eq $c && [lindex $q 0 0 1] eq "running"} {$q}
ok "... until its worker ends: then it is done with the worker's own code, and Finished says so" {
    [waitfor 20000 {[dict exists $::finished $c]}] && [dict get $finished $c] == 3 && [dict get [slurp $R/var/lib/kit/queue/$c] state] eq "done"} {$finished}
catch {exec kill $wpid}

# Pending: the restart record of this boot, and the never-live processes (none here map a replaced file)
spit $R/var/lib/kit/restart "boot boot-three\nkit org.ribbon.linux 6.18.60\n"
set p [lindex [kcall0 Pending] 0]
ok "Pending: the kernel recorded in this boot waits for the restart" {[lsearch -inline -index 0 -all $p kit] eq {{kit org.ribbon.linux 6.18.60}}} {$p}
spit $W/boot_id "boot-four\n"
set p [lindex [kcall0 Pending] 0]
ok "Pending: after the restart (another boot id), nothing of the record" {[lsearch -inline -index 0 -all $p kit] eq {}} {$p}

# idle exit, and activation again
ok "with nothing to do kitd leaves (KITD_IDLE: 2 s here)" {[waitfor 8000 {![has org.ribbon.Kit1]}]}
set q [kcall0 Queue]
ok "and the next call starts it again" {[has org.ribbon.Kit1] && [lindex $q 0] eq {}} {$q}

# the idle timer does not run out under a transaction: a check longer than KITD_IDLE, with no other call meanwhile
set d [lindex [kcall Submit as {check}] 0]
ok "a transaction longer than the idle time: kitd stays until it ends, and Finished says how" {
    [waitfor 15000 {[dict exists $::finished $d]}] && [dict get $finished $d] == 3} {$finished}

# kept history of finished transactions: at most 20
for {set i 1} {$i <= 25} {incr i} { spit $R/var/lib/kit/queue/1-$i [dict create id 1-$i uid 0 words list state done code 0 submitted 0 started 0 finished 0 pid ""] }
set id [lindex [kcall Submit as {list}] 0]
waitfor 15000 {[dict exists $::finished $id]}
ok "finished transactions are pruned to the newest 20" {[llength [lsearch -all -inline -regexp [glob -nocomplain -tails -directory $R/var/lib/kit/queue *] {^[0-9]+-[0-9]+$}]] == 20 && [file exists $R/var/lib/kit/queue/$id]} \
    [lsort [glob -nocomplain -tails -directory $R/var/lib/kit/queue *]]

# a transaction left running whose pid now belongs to another process (after a reboot, say): not waited for
waitfor 8000 {![has org.ribbon.Kit1]}
set o 2-1
spit $R/var/lib/kit/queue/$o [dict create id $o uid 0 words check state running code "" submitted 0 started 0 finished "" pid [pid]]
kcall0 Queue
ok "a transaction left running whose pid is another process's now: done as interrupted (2), not waited on" {
    [waitfor 5000 {[dict exists $::finished $o]}] && [dict get $finished $o] == 2} {$finished}

} err opts]} { incr fails ; puts "  FAIL the kitd checks stopped: [dict get $opts -errorinfo]" }
catch {$bus close}
cleanup
puts [expr {$fails ? "kitd: $fails FAILED, $nok ok" : "kitd: all $nok checks passed"}]
exit [expr {$fails > 0}]
