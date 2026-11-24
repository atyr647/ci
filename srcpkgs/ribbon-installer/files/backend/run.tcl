# run.tcl - `ribbon-install --answers FILE --secrets-stdin --progress`
# (docs/INSTALLER-PROTOCOL.md sections 2 and 3).
#
# Checks the answers (as --check-answers does, against a fresh probe), turns
# them into ribbon-install options, runs the bash engine with the secrets on
# its stdin, and turns the engine's output into protocol lines:
#   STEP i 6 title | PROGRESS pct text | LOG text | DONE | ERROR text
# Every line is a Tcl list.
#
#   tclsh run.tcl --answers FILE [--secrets-stdin] [--progress]
#   tclsh run.tcl --wrap -- ENGINE ARGS...   (ribbon-install --progress without answers)
#
# The engine marks its own events with lines starting "\x1eRIBBON ":
#   STEP i title | SUB pct text (progress inside the step) | DONE |
#   ERROR text | FAIL command

set dir [file dirname [file normalize [info script]]]
foreach f {common.tcl disks.tcl machine.tcl hwdb.tcl answers.tcl} { source [file join $dir $f] }

namespace eval ::run {
    variable total 6
    # overall percent at the start of each step (step 3, copying, is the long one)
    variable range {1 {0 4} 2 {4 7} 3 {7 72} 4 {72 88} 5 {88 95} 6 {95 100}}
    variable step 0
    variable pct 0
    variable lasttext ""
    variable lasttime 0
    variable error ""
    variable fail ""
    variable lastlog ""
    variable done 0
    variable progress 1
}

# One protocol line: a Tcl list, e.g. STEP 3 6 {Copying Ribbon}
# A front end that goes away (EPIPE) must not stop the install part way through a step: the lines are dropped.
proc ::run::emit {kind args} {
    variable progress
    if {$progress} { catch { puts [list $kind {*}$args]; flush stdout }; return }
    # plain mode (no --progress): only the readable part
    catch {
        switch -- $kind {
            LOG { puts [lindex $args 0] }
            STEP { puts "==> [lindex $args 2]" }
            ERROR { puts stderr "ribbon-install: error: [lindex $args 0]" }
        }
    }
}

proc ::run::overall {sub} {
    variable range
    variable step
    if {![dict exists $range $step]} { return 0 }
    lassign [dict get $range $step] lo hi
    if {$sub < 0} { set sub 0 } elseif {$sub > 100} { set sub 100 }
    expr {$lo + int(($hi - $lo) * $sub / 100.0)}
}

proc ::run::progress {p text {force 0}} {
    variable pct
    variable lasttext
    variable lasttime
    if {$p < $pct} { set p $pct }
    set now [clock milliseconds]
    if {!$force && $p == $pct && ($text eq $lasttext || $now - $lasttime < 1000)} return
    set pct $p
    set lasttext $text
    set lasttime $now
    emit PROGRESS $p $text
}

proc ::run::human_rate {r} { regsub {([0-9.]+)([kMGT]?B)/s} $r {\1 \2/s} }

proc ::run::line {l} {
    variable step
    variable total
    variable error
    variable fail
    variable lastlog
    variable done
    regsub -all {\x1b\[[0-9;]*[A-Za-z]} $l "" l
    if {[string match "\x1eRIBBON *" $l]} {
        set rest [string range $l 8 end]
        set kind [lindex [split $rest " "] 0]
        set arg [string range $rest [expr {[string length $kind] + 1}] end]
        switch -- $kind {
            STEP {
                set n [lindex [split $arg " "] 0]
                set title [string range $arg [expr {[string length $n] + 1}] end]
                set step $n
                emit STEP $n $total $title
                progress [overall 0] $title 1
            }
            SUB {
                set p [lindex [split $arg " "] 0]
                set text [string range $arg [expr {[string length $p] + 1}] end]
                if {[string is double -strict $p]} { progress [overall $p] $text }
            }
            DONE { set done 1 }
            ERROR { set error $arg }
            FAIL { set fail $arg }
        }
        return
    }
    # rsync --info=progress2: "  3,123,456,789  62%  210.00MB/s    0:03:02 (xfr#..., to-chk=...)"
    if {[regexp {^\s*([0-9,]+)\s+(\d+)%\s+(\S+/s)\s+(\d+:\d\d:\d\d)} $l -> bytes p rate eta]} {
        set b [string map {, ""} $bytes]
        set text "[::rb::human $b] copied · [human_rate $rate]"
        lassign [split $eta :] h m s
        set left [expr {[scan $h %d] * 60 + [scan $m %d] + ([scan $s %d] > 0 && $p < 100)}]
        if {$p < 100 && $left > 0} { append text " · about $left min left" }
        progress [overall $p] $text
        return
    }
    set l [string trimright $l]
    if {[string trim $l] eq ""} return
    set lastlog $l
    if {[regexp {^ribbon-install: error: (.*)$} $l -> e]} { set error $e }
    emit LOG $l
}

# Run the engine; returns its exit status.
proc ::run::engine {cmd {input ""} {use_stdin 0}} {
    variable error
    variable fail
    variable lastlog
    variable done
    variable step
    if {$use_stdin} {
        set ch [open |[list {*}$cmd <@stdin 2>@1] r]
    } else {
        set ch [open |[list {*}$cmd 2>@1] r+]
        fconfigure $ch -translation binary -encoding utf-8
        puts -nonewline $ch [encoding convertto utf-8 $input]
        flush $ch
        chan close $ch write
    }
    fconfigure $ch -translation auto -encoding utf-8 -buffering line
    while {[gets $ch l] >= 0} { line $l }
    set code 0
    if {[catch {close $ch} msg opts]} {
        set ec [dict get $opts -errorcode]
        set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : 1}]
        if {[lindex $ec 0] eq "CHILDKILLED"} { set error "the install was stopped ([lindex $ec 2])" }
    }
    if {$code == 0 && $done} {
        progress 100 Done 1
        emit DONE
        return 0
    }
    if {$code == 0} { set code 1 }
    if {$error eq ""} {
        if {$fail ne ""} {
            set error "a step failed: $fail"
            if {$lastlog ne ""} { append error " ($lastlog)" }
        } else {
            set error "the install stopped (exit status $code); see Details"
        }
    }
    emit ERROR $error
    return $code
}

proc ::run::engine_path {} {
    if {[info exists ::env(RIBBON_INSTALL_ENGINE)]} { return $::env(RIBBON_INSTALL_ENGINE) }
    set here [file dirname [file normalize [info script]]]
    set repo [file join $here .. bin ribbon-install]
    if {[file exists $repo]} { return [file normalize $repo] }
    return /usr/bin/ribbon-install
}

proc ::run::main {argv} {
    variable progress
    fconfigure stdout -encoding utf-8 -buffering line
    set ::env(RIBBON_ENGINE) 1
    if {[lindex $argv 0] eq "--wrap"} {
        set cmd [lrange $argv 2 end]
        exit [engine $cmd "" 1]
    }
    set file ""
    set secrets 0
    set progress 0
    for {set i 0} {$i < [llength $argv]} {incr i} {
        switch -- [lindex $argv $i] {
            --answers { set file [lindex $argv [incr i]] }
            --secrets-stdin { set secrets 1 }
            --progress { set progress 1 }
            default { emit ERROR "unknown option [lindex $argv $i] with --answers"; exit 2 }
        }
    }
    if {$file eq "" || [catch {open $file r} ch]} { emit ERROR "can't read the answers file '$file'"; exit 1 }
    fconfigure $ch -encoding utf-8
    set answers [read $ch]
    close $ch
    set input ""
    if {$secrets} {
        fconfigure stdin -encoding utf-8
        set input [read stdin]
        if {[catch {dict size $input}]} { emit ERROR "the secrets on stdin are not a Tcl dict"; exit 1 }
    }
    emit LOG "Checking the answers against this computer"
    lassign [::ans::check $answers] res plan
    if {$res ne "ok"} { emit ERROR $plan; exit 1 }
    set args [dict get $plan args]
    set tmp ""
    if {[llength [dict get $plan manual]]} {
        set tmp [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] "ribbon-plan-[pid]"]
        set f [open $tmp {WRONLY CREAT TRUNC} 0600]
        puts $f [join [dict get $plan manual] \n]
        close $f
        lappend args --manual $tmp
        foreach l [dict get $plan manual] { emit LOG "plan: [string map {\t " "} $l]" }
    }
    emit LOG "ribbon-install [join $args { }]"
    set cmd [list bash [engine_path] --yes {*}$args]
    if {$progress} { lappend cmd --progress }
    if {$secrets} { lappend cmd --secrets-stdin }
    set code [engine $cmd $input 0]
    if {$tmp ne ""} { catch {file delete $tmp} }
    exit $code
}

::run::main $argv
