# /usr/lib/ribbon/pkg.tcl - the package manager's seam for Tcl (the installer's
# backend). It asks pkg.sh, beside it, so the backends and their name maps
# exist once:
#
#   ::rbpkg::has ROOT ID          1 when everything package id ID needs is installed
#   ::rbpkg::missing ROOT IDS     the ids of IDS that are not installed
#   ::rbpkg::locales ROOT         the locales the system can generate
#   ::rbpkg::keymap ROOT          the console keymap (vconsole.conf, else the base's own place; us)
#   ::rbpkg::reset                forget what was read (a new root, tests)
#
# ROOT is "" for this system or the path of a mounted one. RIBBON_PKG names a
# stand-in for pkg.sh (tests): it is run as `bash RIBBON_PKG VERB ARGS...`.

namespace eval ::rbpkg {
    variable dir [file dirname [file normalize [info script]]]
    variable cache
    array set cache {}
}

proc ::rbpkg::sh {} {
    variable dir
    if {[info exists ::env(RIBBON_PKG)] && $::env(RIBBON_PKG) ne ""} { return $::env(RIBBON_PKG) }
    return [file join $dir pkg.sh]
}

# pkg.sh's answer, or "" when it fails.
proc ::rbpkg::ask {root args} {
    if {[catch {exec env RIBBON_ROOT=$root bash [sh] {*}$args 2>/dev/null} out]} { return "" }
    return $out
}

# id -> the base's names, for the ids the map knows
proc ::rbpkg::map {root} {
    variable cache
    if {![info exists cache(map,$root)]} {
        set m {}
        foreach line [split [ask $root map] \n] {
            if {[llength $line] >= 2} { dict set m [lindex $line 0] [lrange $line 1 end] }
        }
        set cache(map,$root) $m
    }
    return $cache(map,$root)
}

proc ::rbpkg::installed {root} {
    variable cache
    if {![info exists cache(inst,$root)]} {
        set d {}
        foreach n [split [ask $root installed] \n] { if {$n ne ""} { dict set d $n 1 } }
        set cache(inst,$root) $d
    }
    return $cache(inst,$root)
}

proc ::rbpkg::names {root id} {
    set m [map $root]
    if {[dict exists $m $id]} { return [dict get $m $id] }
    return [list $id]
}

proc ::rbpkg::has {root id} {
    set inst [installed $root]
    foreach n [names $root $id] {
        if {![dict exists $inst $n]} { return 0 }
    }
    return 1
}

proc ::rbpkg::missing {root ids} {
    set out {}
    foreach id $ids { if {![has $root $id]} { lappend out $id } }
    return $out
}

proc ::rbpkg::locales {root} {
    variable cache
    if {![info exists cache(loc,$root)]} {
        set cache(loc,$root) [lsearch -all -inline -not [split [ask $root locales] \n] {}]
    }
    return $cache(loc,$root)
}

proc ::rbpkg::keymap {root} {
    set k [string trim [ask $root keymap]]
    return [expr {$k eq "" ? "us" : $k}]
}

proc ::rbpkg::reset {} {
    variable cache
    array unset cache
    array set cache {}
}
