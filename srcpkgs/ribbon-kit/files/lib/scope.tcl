# scope.tcl -- which kits a verb is about.  There are two kinds of kit and one way to ask for either: an app kit is this person's
# (their home, their transaction), a system kit is the machine's (kitd's system scope, as root, after polkit).  Nobody names the
# scope: a kit says what it is in its signed seal, the index that lists it is signed too, and that decides.
#
#   from the index   a typed name that the verified index lists as `system` (every record of it)
#   from the machine a name that is installed in the system's own set (kitd's /var/lib/kit/active, readable by everyone, the same
#                    files `kit list` reads), by its full name or its short name
#
# This only ROUTES.  It is not trusted by anything that matters: kitd fetches and verifies its own copy of the index, checks every
# signature against the system role (a system kit is never valid by another repository's key, KIT-TRUST.md), plans in system scope
# and refuses a kit that is not a system kit (system.tcl refuse); the user scope refuses a system kit in turn.  A route that is
# wrong, or made up by someone who changed their own cache, ends in a refusal, not in a changed system.
#
#   ::kit::scope::run VERB WORDS   run a verb over both scopes as the words say, return its exit code
#   ::kit::scope::listRows         the system kits' rows for `kit list` (short version size mark)
#   ::kit::scope::live             {name version root short} per installed system kit
# Environment (the tests'): KIT_SYSTEM_ROOT is where the system's /var/lib/kit is (default /).

namespace eval ::kit::scope {
    variable verbs {grab check toss rewind mend list info}
}

proc ::kit::scope::sysroot {} { return [::kit::env KIT_SYSTEM_ROOT /] }

# The system's installed set, as a person may read it ({} when there is none, or it cannot be read).
proc ::kit::scope::installed {} {
    set f [file join [sysroot] var/lib/kit/active]
    if {[catch {::kit::slurp $f utf-8} text] || [catch {::kit::store::parse $text $f} A]} { return {} }
    return $A
}

proc ::kit::scope::rootInfo {root} {
    set f [file join [::kit::scope::sysroot] var/lib/kit/store $root info]
    if {[catch {::kit::slurp $f utf-8} d] || [catch {dict size $d}]} { return {} }
    return $d
}

# {name version root short} per live system kit
proc ::kit::scope::live {} {
    set A [installed]
    if {$A eq {}} { return {} }
    set out {}
    foreach name [lsort -unique [lmap {key k} [dict get $A kits] { dict get $k name }]] {
        set l [::kit::store::live $A $name]
        if {$l eq ""} continue
        set inf [rootInfo [dict get $l root]]
        set short [expr {$inf eq {} ? $name : [dict get $inf short]}]
        lappend out [list $name [dict get $l version] [dict get $l root] $short]
    }
    return $out
}

# The full name of the installed system kit a typed word (its full or its short name) means, or "".
proc ::kit::scope::installedName {word} {
    foreach k [live] { if {$word eq [lindex $k 0] || $word eq [lindex $k 3]} { return [lindex $k 0] } }
    return ""
}

# Does the verified index list the typed word as a system kit?  (Every record of that name is: a name that is both is not routed.)
proc ::kit::scope::indexed {I word} {
    if {$I eq ""} { return 0 }
    set kinds [lsort -unique [lmap r [::kit::repo::records $I $word] { dict get $r kind }]]
    return [expr {$kinds eq "system"}]
}

# The system kits' rows for kit list: short name, version, size on disk, the mark.
proc ::kit::scope::listRows {} {
    set rows {}
    foreach k [live] {
        lassign $k name version root short
        set size 0 ; catch {set size [file size [file join [::kit::scope::sysroot] var/lib/kit/store $root kit]]}
        lappend rows [list $short $version $size system]
    }
    return $rows
}

# The words of a verb, split: {user-words system-words}.  A word is a system kit's when the machine has it installed as one, or
# (for grab) the index lists it as one; a file named on the command line is never routed to kitd (it would read a person's file as
# root): a system kit file is refused with the way to install it.
proc ::kit::scope::partition {verb words I} {
    set user {} ; set sys {}
    foreach w $words {
        set name [lindex [split $w @] 0]
        if {[::kit::plan::isFile $w]} { lappend user $w ; continue }
        if {[set full [installedName $name]] ne ""} { lappend sys [string map [list $name $full] $w] ; continue }
        if {$verb eq "grab" && [indexed $I $name]} { lappend sys $w ; continue }
        lappend user $w
    }
    return [list $user $sys]
}

# Plain `kit rewind` takes back the last change, in whichever scope it was made: the newest history entry of the two.
proc ::kit::scope::newestSystem {} {
    set ms 0
    foreach f [glob -nocomplain -tails -directory [file join [sysroot] var/lib/kit/history] *] {
        if {[regexp {^([0-9]+)-[0-9]+$} $f -> t] && $t > $ms} { set ms $t }
    }
    return $ms
}
proc ::kit::scope::newestUser {} {
    set ids [::kit::txn::history]
    if {![llength $ids]} { return 0 }
    regexp {^([0-9]+)-} [lindex $ids 0] -> t
    return $t
}

# The system part of a verb: through kitd, with the same prompt and the same --yes.  1 + message when kitd cannot be reached.
proc ::kit::scope::system {verb words} {
    if {![::kit::kitdc::reachable]} {
        ::kit::fail 3 "system kits are changed through kitd, and there is no system bus to reach it on"
    }
    return [::kit::kitdc::run [linsert $words 0 $verb]]
}

proc ::kit::scope::run {verb words} {
    set V [string toupper [string index $verb 0]][string range $verb 1 end]
    set user $words ; set sys {} ; set plain 0 ; set I ""
    if {[llength $words]} {
        # named kits: each goes where its kind says
        if {$verb eq "grab"} { set I [::kit::verbs::index 3600 1] }
        lassign [partition $verb $words $I] user sys
    } elseif {$verb in {check mend} && [llength [live]]} {
        # plain: this person's kits, and the system's too
        set plain 1
    } elseif {$verb eq "rewind" && [newestSystem] > [newestUser]} {
        # plain rewind takes back the last change, whichever scope made it
        return [system rewind {}]
    }
    set rc 0
    # words were named and none is for this person's scope: nothing runs there (no words would mean "everything")
    if {![llength $words] || [llength $user]} { set rc [::kit::verbs::$V {*}$user] }
    if {[llength $sys]} {
        set src [system $verb $sys]
        if {$rc == 0} { set rc $src }
    } elseif {$plain} {
        if {[::kit::kitdc::reachable]} {
            set src [system $verb {}]
            if {$rc == 0} { set rc $src }
        } else {
            # said, not fatal: the machine's own kits wait until kitd can be reached
            ::kit::note "kit: the system's kits were not [expr {$verb eq "check" ? "checked" : "mended"}]: there is no system bus to reach kitd on"
        }
    }
    return $rc
}
