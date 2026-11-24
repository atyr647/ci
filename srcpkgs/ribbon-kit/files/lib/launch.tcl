# launch.tcl -- kit run: reach a kit's files and start its entry point.
#
# A kit's files are only ever reached through mkkitfs (the session's FUSE server, docs/MKKITFS.md):
# the .kit is mounted read-only, one mount per kit shared by its launches. kit never extracts a
# kit, so a kit runs from its file or not at all: when mkkitfs can't serve it, kit run says so in
# one line and exits 5 (or 4 when the kit file itself is refused, as a verification failure).
# A kit runs only in its sandbox (sandbox.tcl: bubblewrap from its request and your grants, with
# Landlock where the kernel has it); without bubblewrap kit run says so and exits 5.

::kit::need sandbox

namespace eval ::kit::launch {
    # permission vocabulary 1.0 (KIT-FORMAT.md section 4.2): an enforcer refuses any other name
    variable vocabulary {network home folders display audio gpu input camera dbus}
    # kitfmt's refusals: the kit file is not what it should be (exit 4); anything else is a
    # failure to serve it (exit 5)
    variable refused {NOTKIT TRUNCATED SEAL VERSION FEATURE STRUCTURE LIMIT ROOT STATEMENT PATH SIGNATURE HASH}
}

# The files of one .kit: {tree cleanup}.  tree is the directory the kit's files are read from;
# cleanup (a command, or "") drops the mount when the launch is over.
proc ::kit::launch::files {kitfile} {
    variable refused
    if {[catch {Mkkitfs} why]} {
        ::kit::fail 5 "kit run needs mkkitfs, which is not installed or not usable ($why)"
    }
    if {[catch {Mount $kitfile} r opts]} {
        set ec [dict get $opts -errorcode]
        set code [expr {[lindex $ec 0] eq "MKKITFS" && [lindex $ec 1] in $refused ? 4 : 5}]
        ::kit::fail $code "[file tail $kitfile]: mkkitfs could not serve it: $r"
    }
    return $r
}

# mkkitfs's Tcl client: loads when it is installed (and its server starts on demand).
proc ::kit::launch::Mkkitfs {} {
    variable mk
    if {![info exists mk]} {
        if {[catch {package require mkkitfs} err]} { set mk $err } else { set mk ok }
    }
    if {$mk ne "ok"} { return -code error $mk }
    return ok
}

# One reference per launch: the server keeps the mount while this connection is open, and
# takes it down when the last reference goes.  The server judges the kit's signature by kittrust's
# policy over kit's own key lists, in mode installed (DECISIONS-DELEGATED 27, KIT-TRUST T2 A: a kit
# that was valid when it was installed is not judged again by today's expiries): Ribbon's list and
# every other repository's (::kit::trust's lists, with the updates kit accepted for them).  Only
# allow-unsigned with no key list at all (a developer's machine) runs under the plain key check.
proc ::kit::launch::Mount {kitfile} {
    set signed [expr {![::kit::allowUnsigned]}]
    # a server started now finds kit's own kittrust and kitfmt first (they are not in Tcl's own path)
    set had [info exists ::env(TCLLIBPATH)]
    set was [expr {$had ? $::env(TCLLIBPATH) : ""}]
    set ::env(TCLLIBPATH) [concat [list [::kit::kittrustDir] [::kit::kitfmtDir]] $was]
    set rc [catch {::mkkitfs::connect -serve [Policy]} ch copts]
    if {$had} { set ::env(TCLLIBPATH) $was } else { unset ::env(TCLLIBPATH) }
    if {$rc} { return -options $copts $ch }
    if {[catch {
        if {$signed} {
            set st [::mkkitfs::status $ch]
            if {![dict exists $st trust] || [dict get $st trust] ne "kittrust" || [dict get $st trust-mode] ne "installed"} {
                return -code error -errorcode {MKKITFS SIGNATURE} "the kit server running now does not judge kits by kit's trusted key lists (it was started with another trust policy); stop it with: mkkitfsd ctl quit"
            }
        }
        ::mkkitfs::mount $ch $kitfile -signed $signed
    } k opts]} {
        catch {close $ch}
        return -options $opts $k
    }
    return [list [dict get $k dir] [list ::kit::launch::Unmount $ch [dict get $k id]]]
}

# mkkitfsd serve's trust options for the server kit run starts
proc ::kit::launch::Policy {} {
    ::kit::kitfmt
    set anchor [::kit::keysFile]
    if {![file readable $anchor] && [::kit::allowUnsigned]} { return [list -trust keys] }
    set o [list -trust kittrust -trust-mode installed -trust-anchor $anchor -trust-state [::kit::path data keys]]
    foreach {id i} $::kit::others {
        lappend o -trust-other [list $id [dict get [::kit::repos] $id keys] [::kit::path data repos $id keys]]
    }
    return $o
}
proc ::kit::launch::Unmount {ch id} {
    catch {::mkkitfs::unmount $ch $id}
    catch {close $ch}
}

# The entry point to start: the one named like the kit, else its first app entry, else the first.
proc ::kit::launch::entry {info} {
    set es [lsort -index 0 [dict get $info entries]]
    if {![llength $es]} { ::kit::fail 2 "[dict get $info short] has nothing to run (no entry point)" }
    foreach e $es { if {[lindex $e 0] in [list [dict get $info short] [dict get $info name]]} { return $e } }
    foreach e $es { if {[lindex $e 3] eq "app"} { return $e } }
    return [lindex $es 0]
}

proc ::kit::launch::checkPerms {info} {
    variable vocabulary
    foreach p [dict get $info perms] {
        if {[lindex $p 0] ni $vocabulary} {
            ::kit::fail 2 "[dict get $info short] asks for the permission '[lindex $p 0]', which this kit doesn't know; refusing to run it"
        }
    }
}

# The command line to run, as the host sees it (start puts the kit at /app and the sandbox around it).
proc ::kit::launch::command {info tree entry args} {
    lassign $entry name path eargs type
    set exe [file join $tree $path]
    if {![file exists $exe]} { ::kit::fail 4 "[dict get $info short]: its entry point $path is missing" }
    return [list $exe {*}$eargs {*}$args]
}

# Start it in its sandbox and wait.  libs: the library trees, in lock order (each read-only at
# /run/kit/lib/N, their lib/ dirs on LD_LIBRARY_PATH).  Returns {exit-status seconds}.
proc ::kit::launch::start {cmd info tree libs} {
    set bwrap [auto_execok bwrap]
    if {$bwrap eq ""} {
        ::kit::fail 5 "kit run needs bubblewrap (bwrap) to run [dict get $info short] in its sandbox, and it is not installed"
    }
    # this launch's record, for the System monitor (sandbox.tcl, "launches the monitor can name")
    ::kit::sandbox::prune
    set rec ""
    set rdir [::kit::sandbox::recordDir]
    if {$rdir ne "" && ![catch {file mkdir [file join $rdir [pid]]}]} {
        set rec [file join $rdir [pid]]
        catch {file attributes [file dirname $rdir] -permissions 0700}
        ::kit::spit [file join $rec kit] [list name [dict get $info name] short [dict get $info short] version [dict get $info version]]
    }
    set saved [array get ::env]
    set proxy ""
    set rc [catch {
        set P [::kit::sandbox::plan $info $tree $cmd $libs $rec]
        if {[dict get $P proxy] ne ""} { set proxy [StartProxy [dict get $P proxy] [dict get $P proxysock]] }
        dict for {k v} [dict get $P env] { set ::env($k) $v }
        foreach k [dict get $P unset] { unset -nocomplain ::env($k) }
        set run [list {*}$bwrap {*}[dict get $P bwrap] {*}[dict get $P cmd]]
        # bubblewrap writes the sandbox's pid namespace to fd 3 (Tcl's exec passes only 0-2)
        if {$rec ne ""} {
            set run [list sh -c {i=$1; shift; exec "$@" 3>"$i"} sh [file join $rec info] \
                {*}$bwrap --info-fd 3 {*}[dict get $P bwrap] {*}[dict get $P cmd]]
        }
        set t0 [clock milliseconds]
        set xrc [catch {exec {*}$run <@stdin >@stdout 2>@stderr} err opts]
        set secs [expr {([clock milliseconds] - $t0) / 1000.0}]
    } e eopts]
    if {$proxy ne ""} { catch {exec kill $proxy} }
    if {$rec ne ""} { catch {file delete -force $rec} }
    array unset ::env
    array set ::env $saved
    if {$rc} { return -options $eopts $e }
    if {!$xrc} { return [list 0 $secs] }
    set ec [dict get $opts -errorcode]
    switch -- [lindex $ec 0] {
        CHILDSTATUS { return [list [lindex $ec 2] $secs] }
        CHILDKILLED { return [list [expr {128 + [Signum [lindex $ec 2]]}] $secs] }
        default { puts stderr "kit: could not start [lindex $cmd 0]: $err" ; return [list 127 $secs] }
    }
}

# xdg-dbus-proxy for the app's filtered bus: started, and waited for until its socket is there.
proc ::kit::launch::StartProxy {cmd sock} {
    set pid [exec {*}$cmd </dev/null >/dev/null 2>@stderr &]
    set until [expr {[clock milliseconds] + 5000}]
    while {![file exists $sock]} {
        if {[clock milliseconds] > $until || ![file exists /proc/$pid]} {
            catch {exec kill $pid}
            ::kit::fail 5 "the session bus proxy for this kit did not start (xdg-dbus-proxy)"
        }
        after 20
    }
    return $pid
}
proc ::kit::launch::Signum {name} {
    set n [lsearch -exact {- SIGHUP SIGINT SIGQUIT SIGILL SIGTRAP SIGABRT SIGBUS SIGFPE SIGKILL SIGUSR1 SIGSEGV SIGUSR2 SIGPIPE SIGALRM SIGTERM} $name]
    return [expr {$n > 0 ? $n : 9}]
}
