# core.tcl -- kit's foundations: paths, /etc/kit.conf, errors and exit codes, the lock,
# small helpers (sizes, ages, versions, ranges, atomic files), loading kitfmt and Mk4tcl.
#
# Exit codes (docs/KIT-CLI.md): 0 done or nothing to do, 1 the user said no, 2 bad usage,
# 3 a network or mirror failure, 4 verification failed.  Errors are raised with
# -errorcode {KIT <exit code>} and turned into "kit: message" plus the exit code by bin/kit.

namespace eval ::kit {
    variable version 1.0.0
    variable libdir [file dirname [file normalize [info script]]]
    variable conf          ;# /etc/kit.conf, parsed: key -> list of values
    variable P             ;# paths, P(data) P(cache) P(config) ...
    variable said          ;# notes already printed in this process
    array set said {}
    variable lockHeld 0
}

proc ::kit::fail {code msg} { return -code error -errorcode [list KIT $code] $msg }

proc ::kit::env {name {default ""}} {
    if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) }
    return $default
}

# ---- paths ------------------------------------------------------------------------------------
# User scope (D10): everything under the user's XDG directories, no root needed.
#   data   ~/.local/share/kit   active (the live set), journal, lock, store/<root>/, staging/,
#                               data/<name>/ (each kit's private data: appdata)
#   cache  ~/.cache/kit         index (+ .minisig, .meta), manifests/, chunks/, updates, run/
#   config ~/.config/kit        updates.conf (the updater's settings)
proc ::kit::init {} {
    variable P
    set home [env HOME [file normalize ~]]
    set P(home) $home
    set P(data) [file join [env XDG_DATA_HOME $home/.local/share] kit]
    set P(cache) [file join [env XDG_CACHE_HOME $home/.cache] kit]
    set P(config) [file join [env XDG_CONFIG_HOME $home/.config] kit]
    set P(xdgdata) [env XDG_DATA_HOME $home/.local/share]
    set P(conf) [env KIT_CONF /etc/kit.conf]
    mk4path
    foreach k {store staging} { set P($k) [file join $P(data) $k] }
    set P(appdata) [file join $P(data) data]
    set P(active) [file join $P(data) active]
    set P(journal) [file join $P(data) journal]
    set P(lock) [file join $P(data) lock]
    set P(running) [file join $P(data) running]
    readConf
}

proc ::kit::path {what args} { variable P ; return [file join $P($what) {*}$args] }

# ---- /etc/kit.conf ------------------------------------------------------------------------------
#   mirror = URL           a repository mirror; repeat for more (tried in order)
#   index = FILE           pin a saved signed index snapshot (like KIT_INDEX=FILE)
#   keys = FILE            Ribbon's root-signed key list (default: the keys line of Ribbon's repository
#                          file, else /etc/kit/trusted-keys)
#   repos = DIR            the repository files (default /etc/kit/repos.d; see "repositories" below)
#   essential = NAME ...   kits that can't be tossed (besides kits whose manifest says x-essential)
#   timeout = SECONDS      per network request (default 30)
#   allow-unsigned = yes   DEVELOPERS ONLY: install unsigned and untrusted kits (loudly)
proc ::kit::readConf {} {
    variable conf ; variable P ; variable reposCache
    set reposCache ""
    array unset conf
    array set conf {}
    if {[catch {open $P(conf)} ch]} { return }
    fconfigure $ch -encoding utf-8
    foreach line [split [read $ch] \n] {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} continue
        if {![regexp {^([a-z][a-z-]*)\s*=\s*(.*)$} $line -> k v]} continue
        lappend conf($k) $v
    }
    close $ch
}

proc ::kit::cfg {key {default ""}} {
    variable conf
    if {[info exists conf($key)]} { return [lindex $conf($key) end] }
    return $default
}
proc ::kit::cfgAll {key} { variable conf ; return [expr {[info exists conf($key)] ? $conf($key) : {}}] }
proc ::kit::truthy {v} { return [expr {[string tolower $v] in {yes 1 true on}}] }

# Ribbon's mirrors: kit.conf's mirror lines first, then the url and mirror lines of Ribbon's
# repository file (repos.d/org.ribbon.main.conf), each once.
proc ::kit::mirrors {} {
    set out {}
    set main [repos]
    set main [expr {[dict exists $main $::kit::mainRepo] ? [dict get $main $::kit::mainRepo] : {}}]
    foreach m [concat [cfgAll mirror] [expr {$main eq "" ? {} : [concat [dict get $main url] [dict get $main mirrors]]}]] {
        foreach u $m {
            set u [string trimright $u /]
            if {$u ni $out} { lappend out $u }
        }
    }
    return $out
}

# ---- repositories (docs/KIT-TRUST.md section 6, T7 A) ------------------------------------------------
# One file per repository in repos = DIR (default /etc/kit/repos.d), named after the repository's
# id: org.ribbon.main.conf for Ribbon's, com.example.apps.conf for another.  Lines (as kit.conf's):
#   url = URL      the repository's address        mirror = URL   another mirror; repeat for more
#   keys = FILE    its root-signed key list (+ FILE.minisig; default DIR/<id>.keys)
# Each repository has its own key list with its own roots, and the list's repository line must be
# the file's id.  Ribbon's is the anchor the CLI has always had (keys = in kit.conf wins over its
# file); its index is the one the CLI fetches, from mirrors.  Another repository's keys sign its own
# app kits and nothing else: the system role is honoured only in Ribbon's list (D42).
namespace eval ::kit { variable mainRepo org.ribbon.main ; variable reposCache "" }

proc ::kit::reposDir {} { return [cfg repos /etc/kit/repos.d] }

# -> dict id -> {url URLS mirrors URLS keys FILE file CONF}; files that are not repository files
# (a bad id, unreadable) are skipped with a warning.
proc ::kit::repos {} {
    variable reposCache
    if {$reposCache ne ""} { return [lindex $reposCache 0] }
    set out [dict create]
    set dir [reposDir]
    foreach f [lsort [glob -nocomplain -types f -directory $dir *.conf]] {
        set id [file rootname [file tail $f]]
        if {![regexp {^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$} $id]} {
            warn "$f is not a repository file (the name must be a repository id such as com.example.apps)"
            continue
        }
        if {[catch {slurp $f utf-8} text]} { warn "$f can't be read: $text" ; continue }
        set r [dict create url {} mirrors {} keys [file join $dir $id.keys] file $f]
        foreach line [split $text \n] {
            set line [string trim $line]
            if {$line eq "" || [string index $line 0] eq "#"} continue
            if {![regexp {^([a-z][a-z-]*)\s*=\s*(.*)$} $line -> k v]} continue
            switch -- $k {
                url { dict lappend r url $v }
                mirror { dict lappend r mirrors $v }
                keys { dict set r keys [file join $dir $v] }
            }
        }
        dict set out $id $r
    }
    set reposCache [list $out]
    return $out
}

# The pinned index (KIT_INDEX wins over index = in /etc/kit.conf), or "".
proc ::kit::pinned {} {
    set f [env KIT_INDEX [cfg index]]
    if {$f eq ""} { return "" }
    return [file normalize $f]
}

proc ::kit::allowUnsigned {} { return [truthy [cfg allow-unsigned no]] }

# ---- notes and warnings (stderr; stdout stays the command's output) --------------------------
proc ::kit::note {msg} {
    variable said
    if {[info exists said($msg)]} return
    set said($msg) 1
    puts stderr $msg
}
proc ::kit::warn {msg} { note "kit: warning: $msg" }

# Said by every command: a pinned index, and the developer setting, loudly.
proc ::kit::prologue {} {
    set p [pinned]
    if {$p ne ""} { note "index pinned to $p" }
    if {[allowUnsigned]} {
        note "kit: WARNING: allow-unsigned = yes in [path conf]: UNSIGNED AND UNTRUSTED KITS CAN BE INSTALLED."
        note "kit: WARNING: this is a developer setting; nothing verifies who made what you install."
    }
}

# ---- small helpers ----------------------------------------------------------------------------
proc ::kit::slurp {path {enc binary}} {
    set ch [open $path r]
    fconfigure $ch -translation [expr {$enc eq "binary" ? "binary" : "auto"}]
    if {$enc ne "binary"} { fconfigure $ch -encoding $enc }
    set d [read $ch]
    close $ch
    return $d
}

# Write a file atomically: a temporary name in the same directory, then rename.
proc ::kit::spit {path data {enc utf-8}} {
    file mkdir [file dirname $path]
    set tmp $path.tmp[pid]
    set ch [open $tmp {WRONLY CREAT TRUNC}]
    if {$enc eq "binary"} { fconfigure $ch -translation binary } else { fconfigure $ch -translation lf -encoding $enc }
    puts -nonewline $ch $data
    close $ch
    file rename -force $tmp $path
}

# Make files and directories durable (fsync).  Tcl has no fsync; coreutils' sync takes paths.
proc ::kit::durable {args} {
    if {[env KIT_NOSYNC] eq "1" || ![llength $args]} return
    catch {exec sync -- {*}$args}
}

# Test hook: KIT_CRASH_AT=<step> kills this process with SIGKILL at that step (no cleanup at all),
# so the tests can kill a transaction at every step and check what the next command recovers.
proc ::kit::crashpoint {step} {
    if {[env KIT_CRASH_AT] eq $step} {
        catch {flush stdout ; flush stderr}
        exec kill -KILL [pid]
    }
}

# 12 MB, 340 kB (decimal units, as the prompt shows them)
proc ::kit::fmtsize {n} {
    if {$n < 1000000} { return "[expr {($n + 999) / 1000}] kB" }
    if {$n < 10000000000} { return "[expr {round($n / 1e6)}] MB" }
    return "[expr {round($n / 1e9)}] GB"
}

# "2 days ago", "40 minutes ago"
proc ::kit::fmtage {secs} {
    if {$secs < 0} { set secs 0 }
    foreach {unit n} {day 86400 hour 3600 minute 60} {
        if {$secs >= $n} {
            set k [expr {$secs / $n}]
            return "$k $unit[expr {$k == 1 ? "" : "s"}] ago"
        }
    }
    return "just now"
}

# ~/.config/obs-studio
proc ::kit::tilde {p} {
    variable P
    if {[string first $P(home)/ $p] == 0} { return ~[string range $p [string length $P(home)] end] }
    return $p
}

proc ::kit::now {} { return [clock seconds] }

# ---- versions (compared like Void/xbps versions) and ranges ---------------------------------
# Numbers compare as numbers; alpha < beta < pre = rc < (nothing) = pl; any other letters sort
# after the number they follow (1.0 < 1.0a < 1.0b); separators don't count; missing parts are 0.
proc ::kit::vparts {v} {
    set out {}
    foreach {- num word} [regexp -all -inline {([0-9]+)|([A-Za-z]+)} $v] {
        if {$num ne ""} {
            lappend out [scan $num %lld]
        } else {
            switch -- [string tolower $word] {
                alpha { lappend out -3 } beta { lappend out -2 } pre - rc { lappend out -1 } pl { lappend out 0 }
                default { lappend out 0 [expr {[scan [string tolower [string index $word 0]] %c] - 96}] }
            }
        }
    }
    return $out
}
proc ::kit::vcmp {a b} {
    if {$a eq $b} { return 0 }
    set pa [vparts $a] ; set pb [vparts $b]
    set n [expr {max([llength $pa], [llength $pb])}]
    for {set i 0} {$i < $n} {incr i} {
        set x [lindex $pa $i] ; set y [lindex $pb $i]
        if {$x eq ""} { set x 0 } ; if {$y eq ""} { set y 0 }
        if {$x < $y} { return -1 } elseif {$x > $y} { return 1 }
    }
    return 0
}
# A range is a list of comparisons (">=8.6 <9"); empty means any version.
proc ::kit::inrange {v range} {
    foreach c $range {
        if {![regexp {^(>=|<=|==|!=|>|<|=)?(.+)$} $c -> op want]} { return 0 }
        if {$op eq ""} { set op = }
        set r [vcmp $v $want]
        switch -- $op {
            >= { if {$r < 0} { return 0 } }  <= { if {$r > 0} { return 0 } }
            >  { if {$r <= 0} { return 0 } } <  { if {$r >= 0} { return 0 } }
            = - == { if {$r != 0} { return 0 } } != { if {$r == 0} { return 0 } }
        }
    }
    return 1
}

# Tab-separated lines, with the escapes of the kit index (KIT-FORMAT.md section 6.2).
proc ::kit::esc {s} { return [string map [list \\ \\\\ \t \\t \n \\n \r \\r] $s] }
proc ::kit::unesc {s} { return [string map [list \\\\ \\ \\t \t \\n \n \\r \r] $s] }
proc ::kit::tline {args} { return [join [lmap a $args { esc $a }] \t] }
proc ::kit::tsplit {line} { return [lmap f [split $line \t] { unesc $f }] }

# The short name people type and see: the manifest's x-short, else the last label of the name.
proc ::kit::shortOf {name {given ""}} {
    if {$given ne ""} { return $given }
    return [lindex [split $name .] end]
}

# ---- the lock: one kit command changes the installed set at a time ---------------------------
proc ::kit::pidAlive {p} { return [expr {[string is integer -strict $p] && [file exists /proc/$p]}] }

proc ::kit::lockOwner {} {
    if {[catch {slurp [path lock] utf-8} p]} { return "" }
    set p [string trim $p]
    return [expr {[pidAlive $p] && $p != [pid] ? $p : ""}]
}

proc ::kit::lock {} {
    variable lockHeld
    if {$lockHeld} return
    file mkdir [path data]
    set waited 0
    for {set i 0} {1} {incr i} {
        if {![catch {open [path lock] {WRONLY CREAT EXCL}} ch]} {
            puts $ch [pid] ; close $ch
            set lockHeld 1
            return
        }
        set owner [lockOwner]
        if {$owner eq ""} {
            # stale: the process that held it is gone (killed, crashed)
            catch {file delete [path lock]}
            continue
        }
        if {!$waited} { note "kit: waiting for another kit command (pid $owner)" ; set waited 1 }
        if {$i > 3000} { fail 2 "another kit command (pid $owner) is still running" }
        after 200
    }
}

proc ::kit::unlock {} {
    variable lockHeld
    if {!$lockHeld} return
    catch {file delete [path lock]}
    set lockHeld 0
}

# Load kit's own modules (lib/<name>.tcl) when first needed: kit list loads three small files.
proc ::kit::need {args} {
    variable libdir ; variable loaded
    foreach m $args {
        if {![info exists loaded($m)]} { set loaded($m) 1 ; uplevel #0 [list source -encoding utf-8 [file join $libdir $m.tcl]] }
    }
}

# ---- kitfmt, Mk4tcl and the trusted keys -------------------------------------------------------
proc ::kit::kitfmtDir {} {
    variable libdir
    foreach d [list [env KIT_KITFMT] [file join $libdir kitfmt] [file join $libdir .. .. .. .. kit kitfmt]] {
        if {$d ne "" && [file exists [file join $d kitfmt.tcl]]} { return [file normalize $d] }
    }
    fail 2 "kitfmt is not installed (looked in $libdir/kitfmt)"
}

# kitfmt, with kittrust (docs/KIT-TRUST.md) as its verifier: Ribbon's root-signed key list as the
# anchor (updates kept in data/keys/), and every other repository's list beside it (::kit::trust).
proc ::kit::kitfmt {} {
    if {[namespace exists ::kitfmt] && [info exists ::kitfmt::version]} return
    mk4path
    source [file join [kitfmtDir] kitfmt.tcl]
    trust
}

# KITFMT_MK4TCL (a directory holding Mk4tcl, as for kitfmt's tests) goes first in auto_path, so
# it wins over any other copy.
proc ::kit::mk4path {} {
    set d [env KITFMT_MK4TCL]
    if {$d ne "" && [lindex $::auto_path 0] ne $d} { set ::auto_path [linsert $::auto_path 0 $d] }
}
proc ::kit::mk4 {} {
    if {[llength [info commands ::mk::file]]} return
    mk4path
    if {[catch {package require Mk4tcl} err]} { fail 2 "Mk4tcl is not installed: $err" }
}

proc ::kit::kittrustDir {} {
    variable libdir
    foreach d [list [env KIT_KITTRUST] [file join $libdir kittrust] [file join $libdir .. .. .. .. kit kittrust]] {
        if {$d ne "" && [file exists [file join $d kittrust.tcl]]} { return [file normalize $d] }
    }
    fail 2 "kittrust is not installed (looked in $libdir/kittrust)"
}

# Load the key lists.  Ribbon's goes into ::kittrust itself (repo.tcl checks Ribbon's index and
# takes its key-list updates there); without a usable one, Ribbon's kits don't verify (every
# signature by its keys is "untrusted" or "unchecked"), which installs nothing unless allow-unsigned
# is on.  Every other repository's list is loaded into an interpreter of its own (kittrust keeps
# one list per process), anchored at its keys file with its accepted updates in
# data/repos/<id>/keys; a list whose repository line is not its file's id is refused as a whole
# (so no file can bring in a list of Ribbon's repository: that id is Ribbon's file), and its keys
# verify nothing.  The verifier (::kit::verify) sends a signature to the list(s) holding its key.
namespace eval ::kit { variable others {} ; variable mainId "" }

proc ::kit::trust {} {
    variable others ; variable mainId ; variable mainRepo
    if {![namespace exists ::kittrust]} { uplevel #0 [list source [file join [kittrustDir] kittrust.tcl]] }
    foreach {id i} $others { catch {interp delete $i} }
    set others {} ; set mainId ""
    set ok 1
    # named by Ribbon's repository file (not by kit.conf's keys =, a developer setting), the list
    # must be Ribbon's: its repository line is read before anything of it is trusted, and so is the
    # anchor recorded in data/keys (which kittrust loads in preference to the file, and which
    # kit.conf's keys = may once have pinned to another repository's list)
    set wrong ""
    if {[cfg keys] eq "" && [dict exists [repos] $mainRepo]} {
        foreach f [list [keysFile] [path data keys anchor]] {
            if {[file exists $f] && ![catch {::kittrust parsekeys [slurp $f]} A] && [dict get $A repository] ne $mainRepo} {
                set wrong "$f is the key list of repository [dict get $A repository], not $mainRepo"
                if {$f ne [keysFile]} { append wrong " (remove [path data keys] to re-anchor)" }
                break
            }
        }
    }
    if {$wrong ne ""} {
        warn "$wrong: nothing can be verified"
        set ok 0
    } elseif {[catch {::kittrust load -anchor [keysFile] -state [path data keys]} sum]} {
        warn "no usable trusted key list ([keysFile]: $sum): nothing can be verified"
        set ok 0
    } else {
        set mainId [dict get $sum repository]
    }
    dict for {id r} [repos] {
        if {$id eq $mainRepo || $id eq $mainId} continue
        if {[catch {OtherList $id [dict get $r keys]} i]} { warn "repository $id: $i" ; continue }
        lappend others $id $i
    }
    ::kitfmt configure -keys [allKeys] -verifier ::kit::verify
    return $ok
}

# One other repository's list, loaded and checked in its own interpreter -> the interpreter.
proc ::kit::OtherList {id keys} {
    set i [interp create]
    if {[catch {
        $i eval [list source [file join [kitfmtDir] kitfmt.tcl]]
        $i eval [list source [file join [kittrustDir] kittrust.tcl]]
        # the repository line first: a list for another repository is never anchored
        set rid [dict get [$i eval [list ::kittrust parsekeys [slurp $keys]]] repository]
        if {$rid ne $id} { error "its key list $keys is for repository $rid, not $id: refused" }
        set sum [$i eval [list ::kittrust load -anchor $keys -state [path data repos $id keys]]]
        if {[dict get $sum repository] ne $id} { error "its recorded key list is for repository [dict get $sum repository], not $id: refused" }
    } err]} {
        interp delete $i
        if {[string match "its *" $err]} { error $err }
        error "no usable key list ($keys: $err): its kits can't be verified"
    }
    return $i
}

# Every key kitfmt should send to the verifier: Ribbon's (revoked ones included, as ::kittrust keys
# gives them) and every other repository's, each once.
proc ::kit::allKeys {} {
    variable others
    set out {}
    if {![catch {::kittrust keys} ks]} { set out $ks }
    foreach {id i} $others { foreach k [$i eval {::kittrust keys}] { if {$k ni $out} { lappend out $k } } }
    return $out
}

# Whether Ribbon's loaded list holds this key (as a key, revoked or not).
proc ::kit::mainHolds {kid} {
    if {[catch {::kittrust list} cur] || [dict get $cur list] eq ""} { return 0 }
    set L [dict get $cur list]
    return [expr {[dict exists $L keys $kid] || [dict exists $L revoked $kid]}]
}

# The repositories whose key lists hold this key (as a key, revoked or not): Ribbon's first, then the
# others in the order ::kit::trust loaded them.  What a reader asks before naming a key's signer.
proc ::kit::keyHolder {kid} {
    variable others ; variable mainId ; variable mainRepo
    set out {}
    if {[mainHolds $kid]} { lappend out [expr {$mainId ne "" ? $mainId : $mainRepo}] }
    foreach {id i} $others {
        if {[catch {dict get [$i eval {::kittrust list}] list} L] || $L eq ""} continue
        if {[dict exists $L keys $kid] || [dict exists $L revoked $kid]} { lappend out $id }
    }
    return $out
}
# The key list of repository ID as kittrust holds it (::kittrust list's list: repository serial expires
# roots keys revoked ...), or "" when no list of that id is loaded.
proc ::kit::keyList {id} {
    variable others ; variable mainId ; variable mainRepo
    if {$id eq $mainId || ($mainId eq "" && $id eq $mainRepo)} {
        if {[catch {dict get [::kittrust list] list} L]} { return "" }
        return $L
    }
    foreach {oid i} $others {
        if {$oid eq $id && ![catch {dict get [$i eval {::kittrust list}] list} L]} { return $L }
    }
    return ""
}

# kitfmt's verifier: 1, or {0 reason}.  Ribbon's list judges its own keys as before; another
# repository's list judges the keys only it has, except that a system kit is never valid by one.
proc ::kit::verify {stmt sig pk} {
    variable others
    set kid [::kitfmt::PubKeyId $pk]
    # a key in Ribbon's list is judged by Ribbon's list alone: another list that copies it can't
    # give it another role or bring it back after Ribbon revoked it
    if {[mainHolds $kid]} { return [::kittrust::Verify $stmt $sig $pk] }
    set why ""
    set role [::kittrust role $stmt]
    set mode [dict get [::kittrust configure] -mode] ; set now [dict get [::kittrust configure] -now]
    foreach {id i} $others {
        if {$pk ni [$i eval {::kittrust keys}]} continue
        if {$role eq "system"} {
            if {$why eq ""} { set why "key $kid is a key of repository $id: only Ribbon's key list may sign system kits" }
            continue
        }
        $i eval [list ::kittrust configure -mode $mode -now $now]
        set r [$i eval [list ::kittrust::Verify $stmt $sig $pk]]
        if {[lindex $r 0] eq "1"} { return 1 }
        if {$why eq ""} { set why "[lindex $r 1] (repository $id)" }
    }
    if {$why eq ""} { set why "key $kid is in no trusted key list" }
    return [list 0 $why]
}

# Ribbon's key list: kit.conf's keys =, else the keys line of Ribbon's repository file, else the default.
proc ::kit::keysFile {} {
    variable mainRepo
    set k [cfg keys]
    if {$k ne ""} { return $k }
    set R [repos]
    if {[dict exists $R $mainRepo]} { return [dict get $R $mainRepo keys] }
    return /etc/kit/trusted-keys
}
proc ::kit::trustedKeys {} { kitfmt ; return [::kitfmt configure -keys] }

# Whether a signature state may be installed: valid always; unsigned, untrusted and unchecked
# only with allow-unsigned; invalid never (a bad signature means the bytes were changed).
proc ::kit::sigAcceptable {state} {
    if {$state eq "valid"} { return 1 }
    if {$state eq "invalid"} { return 0 }
    return [allowUnsigned]
}
