# installer-query.tcl FILE SCRIPT - evaluate SCRIPT with $d set to the dict
# in FILE (ribbon-install-probe output) and print the result. Helpers:
#   disk DEV, part DEV, drv ID, drvcat CATEGORY (the first driver of it)
set f [open [lindex $argv 0]]
fconfigure $f -encoding utf-8
set d [read $f]
close $f
proc disk {dev} {
    foreach x [dict get $::d disks] { if {[dict get $x dev] eq $dev} { return $x } }
    return {}
}
proc part {dev} {
    foreach x [dict get $::d disks] {
        foreach p [dict get $x parts] { if {[dict get $p dev] eq $dev} { return $p } }
    }
    return {}
}
proc drv {id} {
    foreach x [dict get $::d drivers] { if {[dict get $x id] eq $id} { return $x } }
    return {}
}
proc drvcat {cat} {
    foreach x [dict get $::d drivers] { if {[dict get $x category] eq $cat} { return $x } }
    return {}
}
proc get {d args} { if {[dict exists $d {*}$args]} { return [dict get $d {*}$args] }; return {} }
puts [eval [lindex $argv 1]]
