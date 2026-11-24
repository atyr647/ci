# mkkitfs.tcl -- the Tcl client of the session's kit server (docs/MKKITFS.md), for `kit run` & co.
#
#   package require mkkitfs
#   set ch [mkkitfs::connect]                  ;# starts mkkitfsd when none runs (-start 0: don't)
#   set k  [mkkitfs::mount $ch ~/.local/share/kit/app.kit -signed 1]
#   dict get $k dir                            ;# where the kit's tree is
#   exec bwrap {*}[mkkitfs::compose [dict get $k dir] -dest /app -overlay tmp] ... /app/bin/hello
#   mkkitfs::unmount $ch [dict get $k id]      ;# or just close $ch: its references go with it
#
# Errors are raised with -errorcode {MKKITFS <CODE> <message>}; the codes are kitfmt's (NOTKIT
# TRUNCATED SEAL VERSION FEATURE STRUCTURE LIMIT ROOT STATEMENT PATH SIGNATURE ...) plus NOSERVER,
# CONFIG, NOENT, BUSY and PROTOCOL.

package require Tcl 8.6-10

namespace eval ::mkkitfs {
    variable version 1.0
    variable proto 1
}

# where the session's socket is: $MKKITFS_SOCKET, else $XDG_RUNTIME_DIR/kit/mkkitfs.sock
proc ::mkkitfs::socketPath {} {
    if {[info exists ::env(MKKITFS_SOCKET)] && $::env(MKKITFS_SOCKET) ne ""} { return $::env(MKKITFS_SOCKET) }
    if {![info exists ::env(XDG_RUNTIME_DIR)] || $::env(XDG_RUNTIME_DIR) eq ""} {
        return -code error -errorcode {MKKITFS CONFIG} "XDG_RUNTIME_DIR is not set"
    }
    return [file join $::env(XDG_RUNTIME_DIR) kit mkkitfs.sock]
}

proc ::mkkitfs::esc {s} { string map [list \\ \\\\ \t \\t \n \\n \r \\r] $s }
proc ::mkkitfs::unesc {s} { string map [list \\\\ \\ \\t \t \\n \n \\r \r] $s }
proc ::mkkitfs::fields {line} {
    set out {}
    foreach f [split $line \t] { lappend out [unesc $f] }
    return $out
}

# connect ?-socket PATH? ?-start 0|1? ?-wait ms? ?-serve {OPTION VALUE ...}? -> channel
#   -serve: mkkitfsd serve's options for a server this starts (e.g. its trust policy); a server already
#   running keeps its own (ask it with status)
proc ::mkkitfs::connect {args} {
    array set o [list -socket "" -start 1 -wait 5000 -serve {}]
    array set o $args
    package require unix_sockets
    set path [expr {$o(-socket) ne "" ? $o(-socket) : [socketPath]}]
    if {![catch {unix_sockets::connect $path} ch]} { return [Setup $ch] }
    if {!$o(-start)} { return -code error -errorcode [list MKKITFS NOSERVER $ch] "no kit server on $path: $ch" }
    # start one: mkkitfsd next to this file (an uninstalled tree), else on PATH
    variable here
    set exe [file join $here mkkitfsd]
    if {![file exists $exe]} { set exe [lindex [auto_execok mkkitfsd] 0] }
    if {$exe eq ""} { return -code error -errorcode {MKKITFS NOSERVER} "no kit server on $path, and no mkkitfsd to start one" }
    # it outlives whoever started it: its log goes next to its socket, not to our stderr
    if {![file isdirectory [file dirname $path]]} {
        file mkdir [file dirname $path]
        catch {file attributes [file dirname $path] -permissions 0700}
    }
    set log [file join [file dirname $path] mkkitfs.log]
    set cmd [list [info nameofexecutable] $exe serve -socket $path -log $log {*}$o(-serve)]
    if {[auto_execok setsid] ne ""} { set cmd [linsert $cmd 0 setsid] }
    exec {*}$cmd </dev/null >/dev/null 2>>$log &
    set until [expr {[clock milliseconds] + $o(-wait)}]
    while {[clock milliseconds] < $until} {
        if {![catch {unix_sockets::connect $path} ch]} { return [Setup $ch] }
        after 10
    }
    return -code error -errorcode [list MKKITFS NOSERVER] "started mkkitfsd, but it did not answer on $path"
}
variable ::mkkitfs::here [file dirname [file normalize [info script]]]

proc ::mkkitfs::Setup {ch} {
    chan configure $ch -translation lf -encoding utf-8 -buffering line -blocking 1
    return $ch
}

# one request: words -> {data-lines last-line-fields}; raises on "err"
proc ::mkkitfs::Request {ch args} {
    set req {}
    foreach w $args { lappend req [esc $w] }
    puts $ch [join $req \t]
    flush $ch
    set data {}
    while {1} {
        if {[gets $ch line] < 0} { return -code error -errorcode {MKKITFS PROTOCOL} "the kit server closed the connection" }
        set f [fields $line]
        switch -- [lindex $f 0] {
            ok { return [list $data [lrange $f 1 end]] }
            err {
                lassign $f - code msg
                return -code error -errorcode [list MKKITFS $code $msg] "$code: $msg"
            }
            default { lappend data [lrange $f 1 end] }
        }
    }
}

proc ::mkkitfs::status {ch} { lindex [Request $ch status] 1 }

# mount ch path ?-signed 0|1? ?-keep 0|1? ?-keys {pubkey ...}? -> dict: id dir name version kind
#   signature keyid comment root refs cached ...
proc ::mkkitfs::mount {ch path args} {
    array set o {-signed 0 -keep 0 -keys {}}
    array set o $args
    set w [list mount [file normalize $path] signed [expr {!!$o(-signed)}] keep [expr {!!$o(-keep)}]]
    foreach k $o(-keys) { lappend w key $k }
    lindex [Request $ch {*}$w] 1
}

# unmount ch id-or-path ?-now 0|1? -> dict: id refs attached
proc ::mkkitfs::unmount {ch what args} {
    array set o {-now 0}
    array set o $args
    if {[string first / $what] >= 0 || [file exists $what]} { set what [file normalize $what] }
    lindex [Request $ch unmount $what now [expr {!!$o(-now)}]] 1
}

# kits ch -> one dict per mounted kit
proc ::mkkitfs::kits {ch} {
    set out {}
    foreach f [lindex [Request $ch list] 0] { lappend out $f }
    return $out
}

# ---------------------------------------------------------------------------------------------------
# Composition: the bubblewrap arguments that put a mounted kit, its writable layer and the shared
# libraries it was resolved to into a sandbox.  What this settles is what the docs settle (D4: the
# session's FUSE mount plus a writable overlay; D5 F, recommended: one overlay layer per store
# entry over the base library directory).  What it does not decide, it takes as arguments: where in
# the sandbox the kit goes (-dest), where the writable layer lives (-overlay), which store entries
# (-libs, from the lock that `kit grab` writes) and onto which directory (-libdir).
#
#   compose kitdir ?-dest /app? ?-overlay none|tmp|DIR? ?-libs {dir ...}? ?-libdir /usr/lib? ?-bwrap exe?
#     -overlay none   the kit read-only (--ro-bind)
#     -overlay tmp    writes go to a tmpfs and vanish with the sandbox (--tmp-overlay)
#     -overlay DIR    writes persist in DIR/upper (DIR/work is overlayfs's work directory)
#     -libs           store entries stacked over -libdir, the last one on top (--overlay-src ... --ro-overlay)
# Overlays need bubblewrap 0.10 or later; with an older one, anything but "-overlay none" and no
# -libs is refused (CONFIG), never quietly composed some other way.
proc ::mkkitfs::compose {kitdir args} {
    array set o [list -dest /app -overlay none -libs {} -libdir /usr/lib -bwrap bwrap]
    foreach {k v} $args {
        if {![info exists o($k)]} { return -code error -errorcode {MKKITFS CONFIG} "compose: unknown option $k" }
        set o($k) $v
    }
    if {($o(-overlay) ne "none" || [llength $o(-libs)]) && ![BwrapOverlay $o(-bwrap)]} {
        return -code error -errorcode {MKKITFS CONFIG} "compose: overlays need bubblewrap 0.10 or later ($o(-bwrap) has no --overlay-src)"
    }
    set a {}
    switch -- $o(-overlay) {
        none { lappend a --ro-bind $kitdir $o(-dest) }
        tmp { lappend a --overlay-src $kitdir --tmp-overlay $o(-dest) }
        default {
            file mkdir [file join $o(-overlay) upper] [file join $o(-overlay) work]
            lappend a --overlay-src $kitdir --overlay [file join $o(-overlay) upper] [file join $o(-overlay) work] $o(-dest)
        }
    }
    if {[llength $o(-libs)]} {
        lappend a --overlay-src $o(-libdir)
        foreach d $o(-libs) { lappend a --overlay-src $d }
        lappend a --ro-overlay $o(-libdir)
    }
    return $a
}

proc ::mkkitfs::BwrapOverlay {exe} {
    variable bwrapOverlay
    if {[info exists bwrapOverlay($exe)]} { return $bwrapOverlay($exe) }
    catch {exec $exe --help 2>@1} out
    set bwrapOverlay($exe) [expr {[string first --overlay-src $out] >= 0}]
}

package provide mkkitfs $::mkkitfs::version
