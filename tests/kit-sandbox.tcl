# tests/kit-sandbox.tcl -- kit run's sandbox (srcpkgs/ribbon-kit/files/lib/sandbox.tcl, launch.tcl,
# files/landlock/kit-landlock.c): Properties' grants file read back by kit, the request and the
# grants merged, the bubblewrap command composed from them, and then real launches of a fixture
# kit in bubblewrap: a folder that is not granted is not there, a read-only grant can't be
# written, a grant widens and narrows the request, the network is unreachable unless granted,
# a real compositor (headless labwc) only with the display grant, the app's $HOME is its private
# data, kit's own state is hidden even from an app with your
# home, nested user namespaces only when granted, the session bus only through the proxy, the
# Landlock layer's limits, and the System monitor naming the sandbox's processes after the kit
# while it runs.  With FUSE, mkkitfs and Mk4tcl, also kit run of a packed .kit end to end.
#
#   tclsh8.6 tests/kit-sandbox.tcl            KIT_LANDLOCK=<built kit-landlock> for the Landlock checks
# Exits 1 on any failure; 0 with "skip" lines where bubblewrap can't make a sandbox here.
set here [file dirname [file normalize [info script]]]
set top [file dirname $here]
set kitlib [file join $top srcpkgs ribbon-kit files lib]

# ---- the child: one launch, as kit run makes it -------------------------------------------------------
#   tclsh8.6 kit-sandbox.tcl launch NAME PERMS TYPE TREE LIBS ARGS...
# (started through a two-line "kit" in the test's folder, so its command line is "kit run launch ...",
# as kit run's is: the System monitor counts a launch record only while its pid is kit run)
if {[lindex $argv 0] eq "launch"} {
    lassign $argv - name perms type tree libs
    source -encoding utf-8 [file join $kitlib core.tcl]
    ::kit::init
    ::kit::need launch
    set info [dict create name $name version 1.0 short [lindex [split $name .] end] perms $perms \
        entries [list [list probe bin/probe {} $type]] provides {}]
    set cmd [::kit::launch::command $info $tree [::kit::launch::entry $info] {*}[lrange $argv 6 end]]
    if {[catch {::kit::launch::start $cmd $info $tree $libs} r o]} {
        puts "error=[lrange [dict get $o -errorcode] 0 1] $r"
    } else {
        puts "status=[lindex $r 0]"
    }
    exit 0
}

set fails 0
proc ok {name cond {detail ""}} {
    if {[uplevel 1 [list expr $cond]]} { puts "  ok   $name" } else {
        puts "  FAIL $name"
        if {$detail ne ""} { puts "       [string map [list \n "\n       "] $detail]" }
        incr ::fails
    }
}
proc spit {path data} {
    file mkdir [file dirname $path]
    set f [open $path w]; fconfigure $f -encoding utf-8 -translation lf; puts -nonewline $f $data; close $f
}
proc slurp {path} { set f [open $path]; fconfigure $f -encoding utf-8; set d [read $f]; close $f; return $d }

set W [exec mktemp -d]
set H $W/home
set RT $W/rt
file mkdir $H $RT $W/bin $W/kitbin
set f [open $W/kitbin/kit w]
puts $f {set argv [lrange $argv 1 end]}
puts $f [list source -encoding utf-8 [info script]]
close $f
file attributes $RT -permissions 0700
set env(HOME) $H
set env(XDG_RUNTIME_DIR) $RT
foreach v {XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME WAYLAND_DISPLAY DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS LD_LIBRARY_PATH KIT_CONF} {
    unset -nocomplain env($v)
}
set env(KIT_CONF) $W/kit.conf

source -encoding utf-8 [file join $kitlib core.tcl]
::kit::init
::kit::need launch

# ---- 1. the grants file: Properties writes it, kit reads it ---------------------------------------------
namespace eval ui {}
set ::appdir [file join $top srcpkgs ribbon-desktop files properties]
source -encoding utf-8 [file join $::appdir kitlink.tcl]
kitlink::grants_write org.example.probe [dict create folders {Documents rw} network yes nested 1 dbus "org.example.A\tx\nnot/a.name"]
set gf [::kit::sandbox::grantsFile org.example.probe]
ok "grants: Properties' file is where kit looks (~/.config/kit/grants/<kit>)" {[file exists $gf] && [string match $H/.config/kit/grants/org.example.probe $gf]}
set g [::kit::sandbox::grants org.example.probe]
ok "grants: kit reads back what Properties wrote, escapes included" {[dict get $g folders] eq {Documents rw} && [dict get $g network] eq "yes" && [dict get $g nested] eq "1" && [dict get $g dbus] eq "org.example.A\tx\nnot/a.name"} $g
spit $H/.config/kit/grants/org.example.bad "ribbon-kit-grants 2\nperm\tnetwork\tyes\n"
ok "grants: another format version is not read" {[::kit::sandbox::grants org.example.bad] eq {}}
spit $H/.config/kit/grants/org.example.odd "ribbon-kit-grants 1\nperm\tfrobnicate\t1\nperm\tnetwork\tyes\nnoise\nperm\tgpu\n"
ok "grants: unknown names and malformed lines are left out" {[::kit::sandbox::grants org.example.odd] eq {network yes}} [::kit::sandbox::grants org.example.odd]
ok "grants: a name that is a path is never read" {[::kit::sandbox::grants ../kit/grants/org.example.probe] eq {} && [::kit::sandbox::grants a/b] eq {}}

# ---- 2. what the app gets -----------------------------------------------------------------------------
set req {{network no} {folders {Downloads ro Pictures rw}} {display wayland} {audio 1}}
set E [::kit::sandbox::effective [dict create name org.example.probe perms $req]]
ok "effective: a grant replaces the request of its name (folders, network)" {[dict get $E folders] eq {Documents rw} && [dict get $E network] eq "yes"} $E
ok "effective: a name with no grant gets the request (display, audio); one nobody names gets nothing" {[dict get $E display] eq "wayland" && [dict get $E audio] eq "1" && [dict get $E gpu] eq "0" && [dict get $E home] eq "none"} $E
ok "effective: the desktop's own names come from the grants (nested)" {[dict get $E nested] eq "1"}
ok "effective: dbus keeps only the words that are bus names" {[dict get $E dbus] eq "org.example.A"} [dict get $E dbus]
set E2 [::kit::sandbox::effective [dict create name org.example.none perms $req]]
ok "effective: without a grants file, the request" {[dict get $E2 folders] eq {Downloads ro Pictures rw} && [dict get $E2 network] eq "no"}
spit $H/.config/kit/grants/org.example.narrow "ribbon-kit-grants 1\nperm\tnetwork\tno\nperm\taudio\t0\n"
set E3 [::kit::sandbox::effective [dict create name org.example.narrow perms {{network yes} {audio mic}}]]
ok "effective: a grant can be narrower than the request" {[dict get $E3 network] eq "no" && [dict get $E3 audio] eq "0"}

# ---- 3. the bubblewrap command --------------------------------------------------------------------------
proc planfor {name perms {libs {}} {type app}} {
    set info [dict create name $name version 1 short [lindex [split $name .] end] perms $perms entries [list [list probe bin/probe {} $type]]]
    return [::kit::sandbox::plan $info $::W/tree [list $::W/tree/bin/probe a] $libs $::W/rec]
}
proc has {args_ seq} {
    set n [llength $seq]
    for {set i 0} {$i + $n <= [llength $args_]} {incr i} { if {[lrange $args_ $i [expr {$i + $n - 1}]] eq $seq} { return 1 } }
    return 0
}
set P [planfor org.example.p1 {{network no}}]
set A [dict get $P bwrap]
ok "plan: every namespace unshared, no network, no nested user namespaces, no capabilities" {[has $A --unshare-all] && [has $A --unshare-user] && ![has $A --share-net] && [has $A --disable-userns] && [has {*}[list $A {--cap-drop ALL}]]} $A
ok "plan: the system read-only, the kit read-only at /app, the command run from /app" {[has $A {--ro-bind /usr /usr}] && [has $A {--ro-bind /etc /etc}] && [has $A [list --ro-bind $W/tree /app]] && [lindex [dict get $P cmd] end-1] eq "/app/bin/probe" && [lindex [dict get $P cmd] end] eq "a"} [dict get $P cmd]
ok "plan: the private data is \$HOME" {[has $A [list --bind $H/.local/share/kit/data/org.example.p1 $H]] && [dict get $P env HOME] eq $H && [dict get $P env KIT_DATA] eq $H && [file isdirectory $H/.local/share/kit/data/org.example.p1]}
ok "plan: an app has its own terminal session; a command-line entry keeps its terminal" {[has $A --new-session] && ![has [dict get [planfor org.example.p1 {} {} cli] bwrap] --new-session]}
ok "plan: no display, sound or bus unless granted" {[lsort {WAYLAND_DISPLAY DISPLAY DBUS_SESSION_BUS_ADDRESS PULSE_SERVER}] eq [lsort [lsearch -all -inline -regexp [dict get $P unset] {^(WAYLAND_DISPLAY|DISPLAY|DBUS_SESSION_BUS_ADDRESS|PULSE_SERVER)$}]] && ![string match *pipewire* $A] && ![string match */dev/dri* $A]}
set A [dict get [planfor org.example.p2 {{network yes} {gpu 1} {input 1}}] bwrap]
ok "plan: network yes shares the host's network" {[has $A --share-net]}
ok "plan: gpu and input bind their devices and sysfs read-only" {[has $A {--dev-bind-try /dev/dri /dev/dri}] && [has $A {--dev-bind-try /dev/input /dev/input}] && [has $A {--dev-bind-try /dev/uinput /dev/uinput}] && [has $A {--ro-bind-try /sys/devices /sys/devices}]} $A
set env(WAYLAND_DISPLAY) wayland-7
set P [planfor org.example.p3 {{display wayland} {audio mic}}]
set A [dict get $P bwrap]
ok "plan: display wayland binds the compositor's socket and nothing of X" {[has $A [list --ro-bind-try $RT/wayland-7 $RT/wayland-7]] && [dict get $P env WAYLAND_DISPLAY] eq "$RT/wayland-7" && "DISPLAY" in [dict get $P unset] && ![string match *X11-unix* $A]}
ok "plan: audio binds PipeWire's socket and its PulseAudio one" {[has $A [list --ro-bind-try $RT/pipewire-0 $RT/pipewire-0]] && [has $A [list --ro-bind-try $RT/pulse/native $RT/pulse/native]]}
unset env(WAYLAND_DISPLAY)
set env(DISPLAY) :3
set env(XAUTHORITY) $W/xauth
set P [planfor org.example.p4 {{display x11}}]
ok "plan: display x11 binds the X server's socket and the Xauthority file" {[has [dict get $P bwrap] {--ro-bind-try /tmp/.X11-unix/X3 /tmp/.X11-unix/X3}] && [has [dict get $P bwrap] [list --ro-bind-try $W/xauth $W/xauth]] && "WAYLAND_DISPLAY" in [dict get $P unset]}
unset env(DISPLAY) env(XAUTHORITY)
spit $H/.config/user-dirs.dirs "# written by xdg-user-dirs-update\nXDG_DOWNLOAD_DIR=\"\$HOME/Fetched\"\nXDG_DESKTOP_DIR=\"\$HOME/\"\n"
set A [dict get [planfor org.example.p5 {{folders {Downloads rw Music ro /mnt/games ro Projects ro Desktop rw / rw /proc ro /run/user/0 rw}}}] bwrap]
ok "plan: an XDG folder is where user-dirs.dirs puts it; read-write and read-only binds" {[has $A [list --bind-try $H/Fetched $H/Fetched]] && [has $A [list --ro-bind-try $H/Music $H/Music]]} $A
ok "plan: an absolute folder and a name under your home" {[has $A {--ro-bind-try /mnt/games /mnt/games}] && [has $A [list --ro-bind-try $H/Projects $H/Projects]]}
ok "plan: never your whole home through a folder, nor /, /proc or the runtime directories" {![has $A [list --bind-try $H $H]] && ![has $A {--bind-try / /}] && ![has $A {--ro-bind-try /proc /proc}] && ![string match */run/user/0* $A]} $A
# a kit's request is not to be trusted: no folder reaches kit's own state, /run's sockets, X's
# sockets or the runtime directory, by name or through a link
file mkdir $H/.config/kit/grants $H/.local/share/kit/data/org.example.other $W/home2
file link -symbolic $H/to-rt $RT
file link -symbolic $H/to-local $H/.local
set A [dict get [planfor org.example.p5b [list [list folders [list .config/kit/grants rw .local/share/kit/data/org.example.other ro \
    /run rw /var/run ro /tmp rw /tmp/.X11-unix ro to-rt ro to-local rw $W ro /run/media ro]]]] bwrap]
ok "plan: no folder in kit's state (the grants, another kit's data), nor /run, /var/run, /tmp, a link to the runtime directory or to kit's state, nor a folder holding your home" \
    {![string match *grants* $A] && ![string match *org.example.other* $A] && ![has $A {--bind-try /run /run}] && ![has $A {--ro-bind-try /var/run /var/run}] && ![has $A {--bind-try /tmp /tmp}] && ![string match *X11-unix* $A] && ![string match *to-rt* $A] && ![string match *to-local* $A] && ![has $A [list --ro-bind-try $W $W]]} $A
ok "plan: ... but removable media under /run" {[has $A {--ro-bind-try /run/media /run/media}]} $A
set E [::kit::sandbox::effective [dict create name org.example.n0 perms {{dbus {org.freedesktop.Notifications org.example.A}}}]]
ok "effective: a request for the notification service is the notifications switch" {[dict get $E notifications] eq "1" && [dict get $E dbus] eq "org.example.A"} $E
set P [planfor org.example.p6 {{home rw}}]
set A [dict get $P bwrap]
ok "plan: home rw binds your home, hides kit's state, and gives the private data at its own place" {[has $A [list --bind $H $H]] && [has $A [list --tmpfs $H/.local/share/kit]] && [has $A [list --tmpfs $H/.config/kit]] && [has $A [list --bind $H/.local/share/kit/data/org.example.p6 $H/.local/share/kit/data/org.example.p6]] && [dict get $P env KIT_DATA] eq "$H/.local/share/kit/data/org.example.p6"} $A
set i1 [lsearch -exact $A --tmpfs]; set i2 [lsearch -exact $A $H/.local/share/kit/data/org.example.p6]
ok "plan: ... the private data after the mask over kit's state" {$i1 >= 0 && $i2 > $i1}
file mkdir $W/lib1/lib $W/lib2
set P [planfor org.example.p7 {} [list $W/lib1 $W/lib2]]
ok "plan: each library read-only at /run/kit/lib/N, its lib/ on LD_LIBRARY_PATH" {[has [dict get $P bwrap] [list --ro-bind $W/lib1 /run/kit/lib/0]] && [has [dict get $P bwrap] [list --ro-bind $W/lib2 /run/kit/lib/1]] && [dict get $P env LD_LIBRARY_PATH] eq "/run/kit/lib/0/lib"}
# the session bus: only through xdg-dbus-proxy, talking only to the names granted
spit $W/bin/xdg-dbus-proxy "#!/bin/sh\necho \"\$\$ \$*\" > \"$W/proxy.args\"\n: > \"\$2\"\nexec sleep 60\n"
file attributes $W/bin/xdg-dbus-proxy -permissions 0755
set env(PATH) $W/bin:$env(PATH)
set env(DBUS_SESSION_BUS_ADDRESS) unix:path=$W/no-bus
spit $H/.config/kit/grants/org.example.p8 "ribbon-kit-grants 1\nperm\tnotifications\t1\n"
set P [planfor org.example.p8 {{dbus {org.example.Service}}}]
ok "plan: dbus names and the notifications grant become the proxy's --talk list" {[dict get $P proxy] eq [list $W/bin/xdg-dbus-proxy unix:path=$W/no-bus $W/rec/bus --filter --talk=org.example.Service --talk=org.freedesktop.Notifications]} [dict get $P proxy]
ok "plan: ... the app's bus address is the proxy's socket inside" {[has [dict get $P bwrap] [list --ro-bind $W/rec/bus $RT/bus]] && [dict get $P env DBUS_SESSION_BUS_ADDRESS] eq "unix:path=$RT/bus"}
ok "plan: no bus for an app with no dbus and no notifications grant" {[dict get [planfor org.example.p9 {}] proxy] eq "" && "DBUS_SESSION_BUS_ADDRESS" in [dict get [planfor org.example.p9 {}] unset]}
spit $H/.config/kit/grants/org.example.n1 "ribbon-kit-grants 1\nperm\tnotifications\t0\n"
set P [planfor org.example.n1 {{dbus {org.freedesktop.Notifications org.example.B}}}]
ok "plan: a grant of notifications 0 takes a requested notification service off the proxy's --talk list" {[dict get $P proxy] eq [list $W/bin/xdg-dbus-proxy unix:path=$W/no-bus $W/rec/bus --filter --talk=org.example.B]} [dict get $P proxy]
set P [planfor org.example.n2 {{dbus {org.freedesktop.Notifications}}}]
ok "plan: ... with only that service requested, no bus at all; without the grant, the service" {[dict get [planfor org.example.n1 {{dbus {org.freedesktop.Notifications}}}] proxy] eq "" && [string match *--talk=org.freedesktop.Notifications [dict get $P proxy]]} [dict get $P proxy]

# ---- 4. real launches ------------------------------------------------------------------------------------
if {[catch {exec bwrap --unshare-all --unshare-user --disable-userns --ro-bind / / true 2>@1} why]} {
    puts "  skip the launches in bubblewrap (bwrap can't make a sandbox here: [string trim $why])"
    file delete -force $W
    exit [expr {$fails ? 1 : 0}]
}
# hx: the built kit-landlock (it closes inherited descriptors on any kernel); ll: it, where the
# kernel has Landlock
set hx [expr {[info exists env(KIT_LANDLOCK)] && [file executable $env(KIT_LANDLOCK)] ? $env(KIT_LANDLOCK) : ""}]
set ll $hx
if {$ll ne "" && [string trim [exec $ll --abi]] < 1} { set ll "" }
set env(KIT_LANDLOCK) [expr {$hx eq "" ? "none" : $hx}]

# the fixture kit's tree: one probe that reports what it can reach
spit $W/tree/bin/probe {#!/usr/bin/env tclsh8.6
proc say {k v} { puts "$k=$v" }
say exe [info script]
foreach v {HOME KIT_TREE KIT_DATA KIT_NAME DBUS_SESSION_BUS_ADDRESS LD_LIBRARY_PATH} { say env:$v [expr {[info exists env($v)] ? $env($v) : "-"}] }
say pwd [pwd]
foreach a $argv {
    regexp {^([a-z]+):?(.*)$} $a -> op x
    switch -- $op {
        exists { say $a [file exists $x] }
        read { say $a [expr {![catch {set f [open $x]; read $f; close $f}]}] }
        write { say $a [expr {![catch {set f [open $x w]; puts $f probe; close $f}]}] }
        tcp { say $a [expr {![catch {close [socket 127.0.0.1 $x]}]}] }
        netdev { set f [open /proc/net/dev]; set n [llength [lrange [split [string trim [read $f]] \n] 2 end]]; close $f; say $a $n }
        unshare { say $a [expr {![catch {exec unshare -U true 2>/dev/null}]}] }
        fds { say $a [lsort -integer [lmap f [glob -tails -directory /proc/[pid]/fd *] { set f }]] }
        wait { while {![file exists $x]} { after 50 } ; say $a 1 }
        run { say $a [expr {![catch {exec {*}[split $x ,] >/dev/null 2>/dev/null}]}] }
    }
}
}
file attributes $W/tree/bin/probe -permissions 0755
file mkdir $H/Documents $H/Downloads $H/Fetched
spit $H/Documents/secret.txt "only mine\n"
spit $H/Fetched/file.txt "fetched\n"
file delete $H/.config/user-dirs.dirs

proc launch {name perms args} {
    set libs {}
    set type app
    set pre {}
    while {[string match -* [lindex $args 0]]} {
        switch -- [lindex $args 0] {
            -libs { set libs [lindex $args 1] } -type { set type [lindex $args 1] }
            -leak { set pre [list sh -c {exec 7</dev/null 9<"$0"; exec "$@"} [lindex $args 1]] }
        }
        set args [lrange $args 2 end]
    }
    set out [exec {*}$pre [info nameofexecutable] $::W/kitbin/kit run launch $name $perms $type $::W/tree $libs {*}$args 2>@1]
    set r [dict create out $out]
    foreach line [split $out \n] { if {[regexp {^([^=]+)=(.*)$} $line -> k v]} { dict set r $k $v } }
    return $r
}
# a process that has ended (gone, or a zombie its parent has not reaped yet)
proc gone {pid} { expr {[catch {slurp /proc/$pid/status} st] || [regexp -line {^State:\s+[ZX]} $st]} }
proc got {r k} { expr {[dict exists $r $k] ? [dict get $r $k] : "?"} }

# kit run started holding descriptors it does not close on exec (as from a CI runner, or a
# launcher that leaks them): one to a folder outside the sandbox
set r [launch org.example.probe1 {{folders {Downloads ro}}} -leak $H/Documents exists:$H/Documents read:$H/Documents/secret.txt read:$H/Downloads/../Documents/secret.txt \
    exists:$H/Downloads write:$H/Downloads/new.txt write:$H/x.txt fds]
ok "run: the entry point runs from /app, with its environment" {[got $r exe] eq "/app/bin/probe" && [got $r env:KIT_TREE] eq "/app" && [got $r env:KIT_NAME] eq "org.example.probe1" && [got $r status] eq "0"} [dict get $r out]
ok "run: a folder that is not granted is not there (Documents)" {[got $r exists:$H/Documents] eq "0" && [got $r read:$H/Documents/secret.txt] eq "0" && [got $r read:$H/Downloads/../Documents/secret.txt] eq "0"} [dict get $r out]
ok "run: a read-only grant is there and can't be written (Downloads)" {[got $r exists:$H/Downloads] eq "1" && [got $r write:$H/Downloads/new.txt] eq "0" && ![file exists $H/Downloads/new.txt]}
ok "run: \$HOME is the private data: a file the app writes there lands in ~/.local/share/kit/data/<kit>" {[got $r write:$H/x.txt] eq "1" && [file exists $H/.local/share/kit/data/org.example.probe1/x.txt] && ![file exists $H/x.txt]}
if {$hx ne ""} {
    ok "run: it starts in its home, and holds no descriptor but 0, 1, 2 (and the one listing them)" {[got $r pwd] eq $H && [llength [got $r fds]] == 4 && [lrange [got $r fds] 0 2] eq {0 1 2}} [dict get $r out]
    set r [exec sh -c {exec 7</dev/null 9<"$0"; exec "$@"} $H $hx --no-landlock -- [info nameofexecutable] $W/tree/bin/probe fds]
    ok "run: ... kit-landlock closes them also where the kernel has no Landlock (--no-landlock)" {[regexp -line {^fds=0 1 2 \d+$} $r]} $r
} else {
    puts "  skip run: no inherited descriptor reaches the app (no KIT_LANDLOCK helper: it closes them)"
}

# grants widen and narrow it
spit $H/.config/kit/grants/org.example.probe2 "ribbon-kit-grants 1\nperm\tfolders\tDocuments rw\n"
set r [launch org.example.probe2 {{folders {Downloads ro}}} read:$H/Documents/secret.txt write:$H/Documents/by-app.txt exists:$H/Downloads]
ok "run: a grant widens the request (Documents rw is there and writable)" {[got $r read:$H/Documents/secret.txt] eq "1" && [got $r write:$H/Documents/by-app.txt] eq "1" && [file exists $H/Documents/by-app.txt]} [dict get $r out]
ok "run: ... and replaces it (Downloads, requested, is gone)" {[got $r exists:$H/Downloads] eq "0"}

# the network
set srv [socket -server {apply {{ch a p} {close $ch}}} -myaddr 127.0.0.1 0]
set port [lindex [fconfigure $srv -sockname] 2]
set r [launch org.example.net1 {{network no}} tcp:$port netdev]
ok "run: network no: only lo, and the host's port can't be reached" {[got $r tcp:$port] eq "0" && [got $r netdev] eq "1"} [dict get $r out]
spit $H/.config/kit/grants/org.example.net2 "ribbon-kit-grants 1\nperm\tnetwork\tyes\n"
set r [launch org.example.net2 {{network no}} tcp:$port]
ok "run: a network grant reaches it" {[got $r tcp:$port] eq "1"} [dict get $r out]
spit $H/.config/kit/grants/org.example.net3 "ribbon-kit-grants 1\nperm\tnetwork\tno\n"
set r [launch org.example.net3 {{network yes}} tcp:$port]
ok "run: a grant of no network takes the request's away" {[got $r tcp:$port] eq "0"} [dict get $r out]
close $srv

# the display: a real compositor (headless labwc), reached through the bound socket only when granted
if {[auto_execok labwc] ne "" && [auto_execok wlr-randr] ne ""} {
    file mkdir $W/labwc
    set lpid [exec env WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1 \
        labwc -C $W/labwc >$W/labwc.log 2>@1 &]
    set until [expr {[clock milliseconds] + 10000}]
    set sock ""
    while {$sock eq "" && [clock milliseconds] < $until} {
        set sock [lindex [lsort [glob -nocomplain -tails -directory $RT -types s {wayland-[0-9]}]] 0]
        if {$sock eq ""} { after 50 }
    }
    if {$sock eq ""} {
        ok "run: headless labwc starts for the display checks" 0 [slurp $W/labwc.log]
    } else {
        set env(WAYLAND_DISPLAY) $sock
        set r [launch org.example.wl1 {{display wayland}} run:wlr-randr]
        set r2 [launch org.example.wl2 {} run:wlr-randr exists:$RT/$sock]
        unset env(WAYLAND_DISPLAY)
        ok "run: display wayland reaches the compositor (wlr-randr inside the sandbox)" {[got $r run:wlr-randr] eq "1"} [dict get $r out]
        ok "run: ... and with no display grant there is no socket to reach" {[got $r2 run:wlr-randr] eq "0" && [got $r2 exists:$RT/$sock] eq "0"} [dict get $r2 out]
    }
    catch {exec kill $lpid}
} else {
    puts "  skip the display checks (no labwc / wlr-randr)"
}

# your home, but not kit's state
set r [launch org.example.home1 {{home rw}} read:$H/Documents/secret.txt exists:$H/.config/kit/grants/org.example.probe2 \
    write:$H/.config/kit/grants/org.example.home1 exists:$H/.local/share/kit/data/org.example.probe1/x.txt write:$H/.local/share/kit/data/org.example.home1/mine]
ok "run: home rw reaches your files" {[got $r read:$H/Documents/secret.txt] eq "1"} [dict get $r out]
ok "run: ... but never the grants (to read or to grant itself more) nor other kits' data" {[got $r exists:$H/.config/kit/grants/org.example.probe2] eq "0" && ![file exists $H/.config/kit/grants/org.example.home1] && [got $r exists:$H/.local/share/kit/data/org.example.probe1/x.txt] eq "0"} [dict get $r out]
ok "run: ... and its private data is at its own place" {[got $r write:$H/.local/share/kit/data/org.example.home1/mine] eq "1" && [file exists $H/.local/share/kit/data/org.example.home1/mine]}

# a kit that asks for the grants folder itself does not get it (it would grant itself everything)
set r [launch org.example.home2 {{folders {.config/kit/grants rw to-rt ro}}} write:$H/.config/kit/grants/org.example.home2 exists:$H/to-rt/kit]
ok "run: a requested folder in kit's state is not given (the app can't write its own grants), nor a link to the runtime directory" {[got $r status] eq "0" && ![file exists $H/.config/kit/grants/org.example.home2] && [got $r exists:$H/to-rt/kit] eq "0"} [dict get $r out]

# home ro, with no ~/.config/kit yet (nothing to hide there, and no mount point can be made in a read-only home)
set env(XDG_CONFIG_HOME) $H/.config-fresh
set r [launch org.example.homero {{home ro}} read:$H/Documents/secret.txt write:$H/Documents/z.txt write:$H/.local/share/kit/data/org.example.homero/z]
unset env(XDG_CONFIG_HOME)
ok "run: home ro reads your files and writes none, with no kit config folder yet; its private data is writable" {[got $r status] eq "0" && [got $r read:$H/Documents/secret.txt] eq "1" && [got $r write:$H/Documents/z.txt] eq "0" && [got $r write:$H/.local/share/kit/data/org.example.homero/z] eq "1"} [dict get $r out]

# nested sandboxes (D22 A)
if {[auto_execok unshare] ne ""} {
    set r [launch org.example.nest1 {} unshare]
    spit $H/.config/kit/grants/org.example.nest2 "ribbon-kit-grants 1\nperm\tnested\t1\n"
    set r2 [launch org.example.nest2 {} unshare]
    ok "run: no user namespaces inside unless nested is granted" {[got $r unshare] eq "0" && [got $r2 unshare] eq "1"} "[dict get $r out]\n[dict get $r2 out]"
} else {
    puts "  skip nested sandboxes (no unshare)"
}

# libraries, and the bus through the proxy (the stand-in records how it was started)
file mkdir $W/libg/lib
spit $W/libg/lib/greeting.txt "hi\n"
spit $H/.config/kit/grants/org.example.bus1 "ribbon-kit-grants 1\nperm\tnotifications\t1\n"
set r [launch org.example.bus1 {} -libs [list $W/libg] read:/run/kit/lib/0/lib/greeting.txt exists:$RT/bus exists:$W/no-bus]
ok "run: a library at /run/kit/lib/0, on LD_LIBRARY_PATH" {[got $r read:/run/kit/lib/0/lib/greeting.txt] eq "1" && [string match /run/kit/lib/0/lib* [got $r env:LD_LIBRARY_PATH]]} [dict get $r out]
set pargs [expr {[file exists $W/proxy.args] ? [slurp $W/proxy.args] : ""}]
ok "run: the notifications grant starts the bus proxy, and the app's bus is its socket" {[string match "* --filter --talk=org.freedesktop.Notifications*" $pargs] && [got $r env:DBUS_SESSION_BUS_ADDRESS] eq "unix:path=$RT/bus" && [got $r exists:$RT/bus] eq "1"} "$pargs\n[dict get $r out]"
ok "run: ... and stops it when the app is done" {$pargs ne "" && [gone [lindex $pargs 0]]} [expr {[catch {slurp /proc/[lindex $pargs 0]/status} st] ? "" : $st}]
set r [launch org.example.bus2 {} exists:$RT/bus]
ok "run: no bus at all without a grant" {[got $r env:DBUS_SESSION_BUS_ADDRESS] eq "-" && [got $r exists:$RT/bus] eq "0"} [dict get $r out]
unset env(DBUS_SESSION_BUS_ADDRESS)

# Landlock (kit-landlock inside the sandbox): writes only to the app's places
if {$ll ne ""} {
    set r [launch org.example.ll1 {} write:/run/x write:/tmp/x write:$H/y]
    set env(KIT_LANDLOCK) none
    set r2 [launch org.example.ll2 {} write:/run/x]
    set env(KIT_LANDLOCK) $ll
    ok "run: Landlock: /run (the sandbox's own tmpfs) can't be written, /tmp and \$HOME can" {[got $r write:/run/x] eq "0" && [got $r write:/tmp/x] eq "1" && [got $r write:$H/y] eq "1"} [dict get $r out]
    ok "run: ... and without the Landlock layer /run can (so the layer is what refused it)" {[got $r2 write:/run/x] eq "1"} [dict get $r2 out]
} else {
    puts "  skip the Landlock layer (no KIT_LANDLOCK helper, or no Landlock in this kernel)"
}

# no bubblewrap: kit run refuses (exit 5), it never runs a kit unconfined
set savedpath $env(PATH)
set env(PATH) $W/bin
set r [launch org.example.nobwrap {}]
set env(PATH) $savedpath
ok "run: without bubblewrap kit run refuses with exit 5" {[string match "error=KIT 5 kit run needs bubblewrap*" [dict get $r out]]} [dict get $r out]

# ---- 5. the System monitor names the sandbox's processes after the kit ---------------------------------------
set appdir [file join $top srcpkgs ribbon-desktop files apps monitor]
foreach f {proc group} { source -encoding utf-8 [file join $appdir $f.tcl] }
set ::monitor::group::sandboxes $RT/kit/sandbox
spit $H/.local/share/applications/kit-org.example.watched.desktop "\[Desktop Entry\]\nName=Watched\nExec=[file join $top srcpkgs ribbon-kit files bin kit] run org.example.watched\n"
set go $H/Downloads/go
spit $H/.config/kit/grants/org.example.watched "ribbon-kit-grants 1\nperm\tfolders\tDownloads rw\n"
# kit run as the launcher starts it ("kit run NAME" on its command line), here the test's child
set ch [open |[list [info nameofexecutable] $W/kitbin/kit run launch org.example.watched {} app $W/tree {} wait:$go 2>@1] r]
set kpid [pid $ch]
set until [expr {[clock milliseconds] + 10000}]
while {![file exists $RT/kit/sandbox/$kpid/info] || ![regexp {pid-namespace} [slurp $RT/kit/sandbox/$kpid/info]]} {
    if {[clock milliseconds] > $until} break
    after 50
}
ok "monitor: kit run records the launch (the kit, and bubblewrap's pid namespace)" {[file exists $RT/kit/sandbox/$kpid/kit] && [dict get [slurp $RT/kit/sandbox/$kpid/kit] name] eq "org.example.watched" && [file exists $RT/kit/sandbox/$kpid/info]}
# the probe, inside, is the process whose command line is /app/bin/probe
set probe ""
set until [expr {[clock milliseconds] + 10000}]
while {$probe eq "" && [clock milliseconds] < $until} {
    foreach d [glob -nocomplain -directory /proc -tails {[0-9]*}] {
        if {![catch {set f [open /proc/$d/cmdline]; set c [read $f]; close $f}] && [string match "*/app/bin/probe*wait:*" $c]} { set probe $d }
    }
    if {$probe eq ""} { after 50 }
}
set apps [monitor::group::assign [monitor::scan] [monitor::group::desktops [list $H/.local/share/applications]]]
set named ""
foreach a $apps { if {$probe ne "" && $probe in [dict get $a pids]} { set named [list [dict get $a id] [dict get $a name]] } }
ok "monitor: the process in the sandbox is grouped as the kit, by its launcher entry's name" {$named eq {kit-org.example.watched Watched}} "probe $probe named '$named'"
spit $go ""
set out [read $ch]
catch {close $ch}
ok "monitor: ... and the record goes when the app ends" {![file exists $RT/kit/sandbox/$kpid] && [string match *status=0* $out]} $out

# ---- 6. kit run of a packed .kit, served by mkkitfs through FUSE ------------------------------------------
set mk4 [expr {[info exists env(KITFMT_MK4TCL)] ? $env(KITFMT_MK4TCL) : ""}]
if {[file writable /dev/fuse] && [auto_execok mkkitfs] ne "" && ![catch {exec [info nameofexecutable] << "lappend auto_path {$mk4}; package require Mk4tcl"}]} {
    # mkkitfs and Mk4tcl first, then whatever else is on TCLLIBPATH (unix_sockets, for mkkitfsd)
    set env(TCLLIBPATH) [concat [list [file join $top srcpkgs mkkitfs files tcl] $mk4] \
        [expr {[info exists env(TCLLIBPATH)] ? $env(TCLLIBPATH) : ""}]]
    spit $W/kit.conf "allow-unsigned = yes\n"
    set src $W/src/hello
    file mkdir $src/bin
    file copy $W/tree/bin/probe $src/bin/probe
    spit $src.manifest "name org.example.hello version 1.0 kind app summary {A probe}\nperms {network no folders {Downloads ro}}\nentries {{probe bin/probe {} app}}\n"
    set KIT [file join $top srcpkgs ribbon-kit files bin kit]
    catch {exec [info nameofexecutable] $KIT pack -q $src $W/hello.kit 2>@1} packout
    if {![file exists $W/hello.kit]} {
        ok "fuse: kit pack makes the fixture kit" 0 $packout
    } else {
        catch {exec [info nameofexecutable] $KIT run $W/hello.kit exists:$H/Documents exists:$H/Downloads 2>@1} out
        set r [dict create]
        foreach line [split $out \n] { if {[regexp {^([^=]+)=(.*)$} $line -> k v]} { dict set r $k $v } }
        ok "fuse: kit run FILE.kit runs it from /app through mkkitfs, in its sandbox" {[got $r exe] eq "/app/bin/probe" && [got $r exists:$H/Documents] eq "0" && [got $r exists:$H/Downloads] eq "1"} $out
    }
    catch {exec [info nameofexecutable] [file join $top srcpkgs mkkitfs files tcl mkkitfsd] ctl -socket $RT/kit/mkkitfs.sock quit 2>@1}
} else {
    puts "  skip kit run of a .kit through FUSE (needs /dev/fuse, mkkitfs on the PATH and Mk4tcl: KITFMT_MK4TCL)"
}

catch {exec sh -c "fusermount3 -u $RT/kit/mnt 2>/dev/null; true"}
file delete -force $W
if {$fails} { puts "kit sandbox: $fails check(s) failed"; exit 1 }
puts "kit sandbox: all checks passed"
