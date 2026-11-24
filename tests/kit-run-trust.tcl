# tests/kit-run-trust.tcl -- kit run mounts with kittrust's policy in mode installed (DECISIONS-DELEGATED 27,
# srcpkgs/ribbon-kit/files/lib/launch.tcl; docs/KIT-TRUST.md T2 A): the session's mkkitfsd that kit run starts
# judges a kit's seal by kit's own key lists, Ribbon's and every other repository's, with roles and
# revocation, and an installed kit signed by a key that has since expired still runs (installed kits are
# not judged again).  Needs /dev/fuse, mkkitfs (on the PATH or MKKITFS), Mk4tcl (KITFMT_MK4TCL), bubblewrap,
# minisign and unix_sockets; skips without them.
#   KITFMT_MK4TCL=DIR tclsh8.6 -encoding utf-8 tests/kit-run-trust.tcl
set top [file dirname [file dirname [file normalize [info script]]]]
set KIT $top/srcpkgs/ribbon-kit/files/bin/kit
set KT $top/kit/kittrust
set F $top/tests/fixtures/kittrust
set MKD $top/srcpkgs/mkkitfs/files/tcl/mkkitfsd
set tclsh [info nameofexecutable]
encoding system utf-8
fconfigure stdout -encoding utf-8
set fails 0
proc ok {name cond {detail ""}} {
    if {$cond} { puts "  ok   $name" } else { puts "  FAIL $name" ; if {$detail ne ""} { puts "       [string range $detail 0 1500]" } ; incr ::fails }
}
proc spit {p d {mode ""}} { file mkdir [file dirname $p] ; set f [open $p w] ; fconfigure $f -translation binary ; puts -nonewline $f [encoding convertto utf-8 $d] ; close $f ; if {$mode ne ""} { file attributes $p -permissions $mode } }
proc tool {args} { if {[catch {exec {*}$args 2>@1} out]} { error "$args: $out" } ; return $out }

set mk4 [expr {[info exists env(KITFMT_MK4TCL)] ? $env(KITFMT_MK4TCL) : ""}]
set engine [expr {[info exists env(MKKITFS)] && $env(MKKITFS) ne "" ? $env(MKKITFS) : [lindex [auto_execok mkkitfs] 0]}]
set why ""
if {![file writable /dev/fuse]} { set why "no /dev/fuse" } \
elseif {$engine eq ""} { set why "no mkkitfs (MKKITFS)" } \
elseif {[auto_execok bwrap] eq "" || [auto_execok minisign] eq ""} { set why "no bubblewrap or minisign" } \
elseif {[catch {exec $tclsh << "lappend auto_path {$mk4}; package require Mk4tcl; package require unix_sockets"}]} { set why "no Mk4tcl (KITFMT_MK4TCL) or unix_sockets" }
if {$why ne ""} { puts "  skip kit run's trust policy ($why)" ; exit 0 }
set env(MKKITFS) $engine

set W [file normalize [exec mktemp -d]]
set RT $W/rt
file mkdir $RT $W/home
file attributes $RT -permissions 0700
set env(HOME) $W/home
set env(XDG_RUNTIME_DIR) $RT
foreach v {XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME KIT_INDEX MKKITFS_SOCKET} { unset -nocomplain env($v) }
set env(KIT_CONF) $W/kit.conf
set env(TCLLIBPATH) [concat [list $top/srcpkgs/mkkitfs/files/tcl $mk4] \
    [expr {[info exists env(TCLLIBPATH)] ? $env(TCLLIBPATH) : ""}]]

# Ribbon's key list: two app keys and the system key (later the second one's validity ends and the first is revoked)
set L $W/keys/trusted-keys
file mkdir $W/keys
tool $tclsh $KT/kitkey init -repository org.ribbon.main -root $F/test-root.pub $L
tool $tclsh $KT/kitkey add -role app -from -30d $L $F/test-app.pub
tool $tclsh $KT/kitkey add -role app -from -60d $L $F/test-app2.pub
tool $tclsh $KT/kitkey add -role system -from -30d $L $F/test-system.pub
tool $tclsh $KT/kitkey sign -key $F/test-root.key $L
# another repository whose list holds the key test-other (its own root)
set R $W/repos.d
file mkdir $R
tool $tclsh $KT/kitkey init -repository com.example.other -root $F/test-root2.pub $R/com.example.other.keys
tool $tclsh $KT/kitkey add -role app -from -30d $R/com.example.other.keys $F/test-other.pub
tool $tclsh $KT/kitkey sign -key $F/test-root2.key $R/com.example.other.keys
spit $R/com.example.other.conf "# a test repository\n"
spit $env(KIT_CONF) "keys = $L\nrepos = $R\n"

proc kit {name key} {
    set dir $::W/src/$name
    spit $dir/bin/app "#!/bin/sh\necho ran-$name\n" 493
    spit $dir.manifest "name org.example.$name version 1 kind app summary {A probe}\nentries {{$name bin/app {} app}}\n"
    tool $::tclsh $::KIT pack -q -sign $key $dir $::W/$name.kit
    return $::W/$name.kit
}
proc run {kitfile} {
    set code 0
    if {[catch {exec timeout -k 5 60 $::tclsh $::KIT run $kitfile 2>@1} out opts]} {
        set ec [dict get $opts -errorcode]
        set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : "error"}]
    }
    list $code $out
}

set good [kit good $F/test-app.key]
lassign [run $good] code out
ok "a kit signed by Ribbon's app key runs" [expr {$code == 0 && [string match *ran-good* $out]}] "$code $out"
catch {exec $tclsh $MKD ctl -socket $RT/kit/mkkitfs.sock status 2>@1} st
ok "... from the server kit run started, which judges by kittrust in mode installed" \
    [expr {[string match "*trust\tkittrust*" $st] && [string match "*trust-mode\tinstalled*" $st]}] $st

lassign [run [kit stranger $F/test-index2.key]] code out
ok "a kit signed by a key in no list is refused as a verification failure (exit 4)" [expr {$code == 4 && ![string match *ran-stranger* $out]}] "$code $out"
lassign [run [kit sys $F/test-system.key]] code out
ok "a kit signed by the system key (another role) is refused for an app kit (exit 4)" [expr {$code == 4 && ![string match *ran-sys* $out]}] "$code $out"
lassign [run [kit other $F/test-other.key]] code out
ok "a kit signed by another repository's app key runs (that repository's own list)" [expr {$code == 0 && [string match *ran-other* $out]}] "$code $out"

# installed kits: what the server judges when kit run starts one by its name
set old [kit old $F/test-app2.key]
foreach k [list $good $old] { tool $tclsh $KIT grab --yes $k }
proc keyid {pub} {
    string trim [exec $::tclsh << "lappend auto_path $::top/kit/kitfmt; package require kitfmt; puts \[::kitfmt::PubKeyId \[lindex \[split \[string trim \[read \[open $pub\]\]\] \\n\] end\]\]"]
}
# the second app key's validity ends (its line again, with -until in the past), and the first app key is revoked
catch {exec $tclsh $MKD ctl -socket $RT/kit/mkkitfs.sock quit 2>@1}
tool $tclsh $KT/kitkey remove $L [keyid $F/test-app2.pub]
tool $tclsh $KT/kitkey add -role app -from -60d -until -1d $L $F/test-app2.pub
tool $tclsh $KT/kitkey revoke -reason test $L [keyid $F/test-app.pub]
tool $tclsh $KT/kitkey sign -key $F/test-root.key $L
lassign [run org.example.old] code out
ok "an installed kit whose signing key has expired since still runs (mode installed: not judged again)" [expr {$code == 0 && [string match *ran-old* $out]}] "$code $out"
lassign [run org.example.good] code out
ok "an installed kit whose key Ribbon's list has revoked since is refused by the server (exit 4)" [expr {$code == 4 && ![string match *ran-good* $out]}] "$code $out"

catch {exec $tclsh $MKD ctl -socket $RT/kit/mkkitfs.sock quit 2>@1}
# the server unmounts after it is told to quit, not before this returns: the directory goes once the mount has
for {set i 0} {$i < 60} {incr i} {
    if {![catch {file delete -force $W}]} break
    catch {exec fusermount3 -uz $RT/kit/mnt 2>@1}
    after 100
}
if {[file exists $W]} { puts "  FAIL the work directory could not be removed (a mount is still there)" ; incr fails }
if {$fails} { puts "kit run trust: $fails checks failed" ; exit 1 }
puts "kit run trust: all checks passed"
