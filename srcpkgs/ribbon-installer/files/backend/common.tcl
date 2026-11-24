# common.tcl - shared helpers for the installer backend (ribbon-install-probe,
# ribbon-install --answers). Plain tclsh 8.6, no packages.
#
# Test hooks (environment):
#   RIBBON_PROBE_ROOT   a fake root for /sys, /proc, /etc, /usr/share, the
#                       xbps package database and dmesg.txt (driver and
#                       machine detection read files under it)
#   RIBBON_PROBE_DISKS  only these block devices are disks (loop devices allowed)
#   RIBBON_PROBE_MEDIA  the install media disk (default: found from the boot)
#   RIBBON_PROBE_GEOIP  0: no geo-IP time zone lookup

namespace eval ::rb {
    variable root ""
    if {[info exists ::env(RIBBON_PROBE_ROOT)]} { set root [string trimright $::env(RIBBON_PROBE_ROOT) /] }
    variable MiB 1048576
    variable GiB 1073741824
    # The smallest Ribbon root partition (the welcome page asks for 32 GB).
    variable ribbon_min [expr {32 * 1073741824}]
    # Free space the EFI partition needs for Ribbon's kernels and initramfs
    # images (two kernels, NVIDIA modules, older kernels kept for snapshots).
    variable esp_need [expr {300 * 1048576}]
    # A newly made EFI partition (erase mode) and the smallest one accepted.
    variable esp_size [expr {2 * 1073741824}]
    variable esp_min [expr {512 * 1048576}]
    # The boot partition made next to Windows when its EFI partition has
    # less than esp_need free (FAT32; it holds the kernels). It comes out of
    # Ribbon's share, on top of ribbon_min.
    variable boot_size [expr {1 * 1073741824}]
}

proc ::rb::rpath {path} { return "$::rb::root$path" }

# First line of a file (trimmed), or the default.
proc ::rb::readfile {path {default ""}} {
    if {[catch {open $path r} f]} { return $default }
    fconfigure $f -encoding utf-8
    set s [read $f]
    close $f
    return [string trim $s]
}

proc ::rb::readall {path} {
    if {[catch {open $path r} f]} { return "" }
    fconfigure $f -encoding utf-8
    set s [read $f]
    close $f
    return $s
}

proc ::rb::have {cmd} { expr {[auto_execok $cmd] ne ""} }

# Run a command; returns {exitcode output} (stdout and stderr together).
proc ::rb::run {args} {
    if {[catch {exec {*}$args 2>@1} out opts]} {
        set code 1
        set ec [dict get $opts -errorcode]
        if {[lindex $ec 0] eq "CHILDSTATUS"} { set code [lindex $ec 2] }
        if {[lindex $ec 0] eq "POSIX"} { set code 127 }
        return [list $code $out]
    }
    return [list 0 $out]
}

# stdout of a command, or "" when it fails.
proc ::rb::out {args} {
    if {[catch {exec {*}$args 2>/dev/null} out]} { return "" }
    return $out
}

# lsblk -P / blkid -o export style output -> list of dicts
proc ::rb::parse_pairs {text} {
    set rows {}
    foreach line [split $text \n] {
        if {[string trim $line] eq ""} continue
        set row {}
        foreach {- k v} [regexp -all -inline {([A-Za-z0-9_:-]+)="((?:[^"\\]|\\.)*)"} $line] {
            dict set row $k [unescape_x $v]
        }
        lappend rows $row
    }
    return $rows
}

proc ::rb::unescape_x {s} {
    # lsblk escapes unsafe bytes as \xHH
    if {[string first \\ $s] < 0} { return $s }
    set out ""
    while {[regexp -indices {\\x([0-9a-fA-F]{2})} $s m h]} {
        append out [string range $s 0 [expr {[lindex $m 0] - 1}]]
        append out [format %c 0x[string range $s {*}$h]]
        set s [string range $s [expr {[lindex $m 1] + 1}] end]
    }
    return [encoding convertfrom utf-8 [encoding convertto iso8859-1 "$out$s"]]
}

# blkid -o export KEY=VALUE lines -> dict
proc ::rb::parse_export {text} {
    set d {}
    foreach line [split $text \n] {
        if {[regexp {^([A-Z_]+)=(.*)$} $line -> k v]} { dict set d $k $v }
    }
    return $d
}

proc ::rb::get {d key {default ""}} {
    if {[dict exists $d $key]} { return [dict get $d $key] }
    return $default
}

proc ::rb::align_up {n a} { expr {(($n + $a - 1) / $a) * $a} }
proc ::rb::align_down {n a} { expr {($n / $a) * $a} }

# Sizes for people: decimal units, like disk makers and the mockups (1 TB, 520 GB).
proc ::rb::human {bytes} {
    if {$bytes eq "" || ![string is wide -strict $bytes]} { return "?" }
    foreach {u f} {TB 1e12 GB 1e9 MB 1e6 kB 1e3} {
        if {$bytes >= $f} {
            set v [expr {$bytes / $f}]
            if {$v >= 100 || abs($v - round($v)) < 0.05} { return "[expr {round($v)}] $u" }
            return "[format %.1f $v] $u"
        }
    }
    return "$bytes B"
}

# Print a dict the way the protocol shows it: one top-level key per line,
# list-valued sections (disks, drivers) one element per line. Any reader
# sees an ordinary Tcl dict.
proc ::rb::pretty {d {listkeys {disks drivers}}} {
    set out ""
    dict for {k v} $d {
        if {$k in $listkeys} {
            append out "$k \{\n"
            foreach e $v { append out "    [list $e]\n" }
            append out "\}\n"
        } else {
            append out "[list $k $v]\n"
        }
    }
    return $out
}

# A path where the installer backend's files live (this directory).
set ::rb::libdir [file dirname [file normalize [info script]]]
