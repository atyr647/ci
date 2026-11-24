# cli.tcl -- what kitkey, kitseal and kitindex share: options, messages, exit codes.
#
# Exit codes, as the kit CLI's (docs/KIT-CLI.md): 0 done, 1 something else failed (minisign, a
# file), 2 bad usage, 4 verification failed (a signature, a role, an expiry, a replay, a rollback).

namespace eval ::kittrust::cli {
    variable prog [file tail $::argv0]
    namespace export say warn die getopts guard now pubkey keyname mk4 trustKitfmt date
}

proc ::kittrust::cli::say {msg} { puts $msg }
proc ::kittrust::cli::warn {msg} { variable prog ; puts stderr "$prog: warning: $msg" }
proc ::kittrust::cli::die {code msg} { variable prog ; puts stderr "$prog: $msg" ; exit $code }

# Parse argv against spec {-opt kind ...}: kind flag (no value), one (a value), many (repeatable).
# -> {options-dict positional-list}
proc ::kittrust::cli::getopts {spec argv usage} {
    set o [dict create]
    dict for {k kind} $spec { dict set o $k [expr {$kind eq "flag" ? 0 : ($kind eq "many" ? {} : "")}] }
    set pos {}
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set a [lindex $argv $i]
        if {$a eq "--"} { lappend pos {*}[lrange $argv [expr {$i + 1}] end] ; break }
        if {[string index $a 0] eq "-" && [string length $a] > 1} {
            if {![dict exists $spec $a]} { die 2 "unknown option $a\nusage: $usage" }
            switch -- [dict get $spec $a] {
                flag { dict set o $a 1 }
                one - many {
                    incr i
                    if {$i >= [llength $argv]} { die 2 "$a needs a value\nusage: $usage" }
                    if {[dict get $spec $a] eq "one"} { dict set o $a [lindex $argv $i] } else { dict lappend o $a [lindex $argv $i] }
                }
            }
            continue
        }
        lappend pos $a
    }
    return [list $o $pos]
}

# Run body; turn KITTRUST and KITFMT errors into a message and exit code 4 (1 for IO/CONFIG).
proc ::kittrust::cli::guard {body} {
    if {[catch {uplevel 1 $body} err opts]} {
        set ec [expr {[dict exists $opts -errorcode] ? [dict get $opts -errorcode] : ""}]
        switch -- [lindex $ec 0] {
            KITTRUST { die [expr {[lindex $ec 1] in {IO CONFIG} ? 1 : 4}] $err }
            KITFMT { die 4 $err }
            default { die 1 $err }
        }
    }
}

# -now WHEN for the checks ("" = the clock)
proc ::kittrust::cli::now {o} {
    if {[dict exists $o -now] && [dict get $o -now] ne ""} {
        ::kittrust configure -now [::kittrust::When [dict get $o -now] [clock seconds]]
    }
}

# A public key: a minisign .pub file, or the base64 key itself.
proc ::kittrust::cli::pubkey {arg} {
    if {[::kittrust::IsPub $arg]} { return $arg }
    if {![file isfile $arg]} { die 2 "$arg is neither a public key file nor a minisign public key" }
    foreach line [split [::kittrust::Slurp $arg] \n] {
        set line [string trim $line]
        if {[::kittrust::IsPub $line]} { return $line }
    }
    die 2 "$arg holds no minisign public key"
}

# The name a key is listed under: given, else the .pub file's name.
proc ::kittrust::cli::keyname {arg given} {
    if {$given ne ""} { return $given }
    if {[file isfile $arg]} { return [file rootname [file tail $arg]] }
    return "key-[::kitfmt::PubKeyId $arg]"
}

# Mk4tcl, for the commands that open kits: -mk4tcl DIR or $KITFMT_MK4TCL (like kitpack).
proc ::kittrust::cli::mk4 {dir {need 1}} {
    if {[llength [info commands ::mk::file]]} { return 1 }
    if {$dir eq "" && [info exists ::env(KITFMT_MK4TCL)]} { set dir $::env(KITFMT_MK4TCL) }
    if {$dir ne "" && $dir ni $::auto_path} { set ::auto_path [linsert $::auto_path 0 $dir] }
    if {[catch {package require Mk4tcl} err]} {
        if {$need} { die 1 "Mk4tcl is needed to open kits (-mk4tcl DIR or KITFMT_MK4TCL): $err" }
        return 0
    }
    return 1
}

# kitfmt checks signatures through the key list from now on.
proc ::kittrust::cli::trustKitfmt {} {
    ::kitfmt configure -keys [::kittrust keys] -verifier ::kittrust::Verify
}

proc ::kittrust::cli::date {t} { return [clock format $t -format "%Y-%m-%d %H:%M UTC" -gmt 1] }
