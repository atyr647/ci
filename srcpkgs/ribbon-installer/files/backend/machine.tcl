# machine.tcl - facts about the computer for the installer pages: firmware,
# RAM, laptop and battery, CPU, network, and guesses for time zone, locale
# and keymap. Reads files under ::rb::root (tests use a fake root).

namespace eval ::rb::machine {}

# RIBBON_UEFI=yes|no overrides (tests; the same variable ribbon-install reads)
proc ::rb::machine::efi {} {
    if {[info exists ::env(RIBBON_UEFI)] && $::env(RIBBON_UEFI) in {yes no}} { return [expr {$::env(RIBBON_UEFI) eq "yes"}] }
    file isdirectory [::rb::rpath /sys/firmware/efi]
}

proc ::rb::machine::secureboot {} {
    set f [::rb::rpath /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-e39818d4bd12]
    if {[catch {open $f rb} ch]} { return 0 }
    set d [read $ch]
    close $ch
    # 4 bytes of attributes, then the value
    if {[string length $d] >= 5 && [string index $d 4] eq "\x01"} { return 1 }
    return 0
}

proc ::rb::machine::ram {} {
    foreach line [split [::rb::readall [::rb::rpath /proc/meminfo]] \n] {
        if {[regexp {^MemTotal:\s+(\d+)} $line -> kib]} { return [expr {$kib * 1024}] }
    }
    return 0
}

proc ::rb::machine::chassis {} { ::rb::readfile [::rb::rpath /sys/class/dmi/id/chassis_type] 0 }

proc ::rb::machine::batteries {} {
    lsort [glob -nocomplain -directory [::rb::rpath /sys/class/power_supply] BAT*]
}

# SMBIOS chassis types 8 portable, 9 laptop, 10 notebook, 11 hand held,
# 14 sub notebook, 30 tablet, 31 convertible, 32 detachable (as ribbon-hw).
proc ::rb::machine::laptop {} {
    if {[chassis] in {8 9 10 11 14 30 31 32}} { return 1 }
    expr {[llength [batteries]] > 0}
}

proc ::rb::machine::convertible {} { expr {[chassis] in {30 31 32}} }

# {} without a battery, else {percent N charging 0|1 ac 0|1}
proc ::rb::machine::battery {} {
    set bats [batteries]
    if {![llength $bats]} { return {} }
    set b [lindex $bats 0]
    set pct [::rb::readfile $b/capacity 0]
    set status [::rb::readfile $b/status Unknown]
    set ac 0
    foreach s [glob -nocomplain -directory [::rb::rpath /sys/class/power_supply] *] {
        if {[::rb::readfile $s/type] eq "Mains" && [::rb::readfile $s/online 0] eq "1"} { set ac 1 }
    }
    if {$status in {Charging Full "Not charging"}} { set ac 1 }
    dict create percent $pct charging [expr {$status eq "Charging"}] ac $ac
}

proc ::rb::machine::cpu {} {
    set vendor other
    set model ""
    foreach line [split [::rb::readall [::rb::rpath /proc/cpuinfo]] \n] {
        if {[regexp {^vendor_id\s*:\s*(\S+)} $line -> v]} {
            switch -- $v { GenuineIntel { set vendor intel } AuthenticAMD { set vendor amd } }
        }
        if {$model eq "" && [regexp {^model name\s*:\s*(.*)$} $line -> m]} { set model [string trim $m] }
    }
    regsub -all {\((R|TM|tm)\)} $model "" model
    regsub {\s+(\d+-Core|Processor|CPU)(\s.*)?$} $model "" m2
    if {$m2 ne ""} { set model $m2 }
    regsub -all {\s+} $model " " model
    dict create vendor $vendor model [string trim $model]
}

# {online 0|1 kind wifi|ethernet|{} name SSID-or-connection}
proc ::rb::machine::net {} {
    set online 0
    set kind ""
    set name ""
    if {$::rb::root eq "" && [::rb::have nmcli]} {
        set c [string trim [::rb::out nmcli -t networking connectivity]]
        set online [expr {$c in {full limited portal}}]
        foreach line [split [::rb::out nmcli -t -f TYPE,STATE,CONNECTION device] \n] {
            set f [split $line :]
            if {[lindex $f 1] eq "connected" && [lindex $f 0] in {wifi ethernet}} {
                set kind [lindex $f 0]
                set name [join [lrange $f 2 end] :]
                break
            }
        }
        if {$c eq "full"} { set online 1 } elseif {$c eq ""} { set online [expr {$kind ne ""}] }
    } else {
        # no NetworkManager: an interface that is up, with a default route
        set route [::rb::readall [::rb::rpath /proc/net/route]]
        foreach n [lsort [glob -nocomplain -tails -directory [::rb::rpath /sys/class/net] *]] {
            if {$n eq "lo"} continue
            if {[::rb::readfile [::rb::rpath /sys/class/net/$n/operstate]] ne "up"} continue
            if {![regexp "(?n)^$n\\s+00000000\\s" $route]} continue
            set online 1
            set kind [expr {[file exists [::rb::rpath /sys/class/net/$n/wireless]] ? "wifi" : "ethernet"}]
            set name $n
            break
        }
    }
    dict create online $online kind $kind name $name
}

# Geo-IP lookup (the same service Calamares used), started early and read
# at the end so it overlaps the disk probe. 1.5 s at most.
proc ::rb::machine::geoip_start {} {
    variable geo ""
    if {[info exists ::env(RIBBON_PROBE_GEOIP)] && $::env(RIBBON_PROBE_GEOIP) eq "0"} return
    if {$::rb::root ne "" || ![::rb::have curl]} return
    catch { set geo [open |[list curl -fsS -m 1.5 https://geoip.kde.org/v1/calamares 2>/dev/null] r] }
}

proc ::rb::machine::timezone {} {
    variable geo
    if {[info exists geo] && $geo ne ""} {
        set data [read $geo]
        catch {close $geo}
        set geo ""
        if {[regexp {"time_zone"\s*:\s*"([A-Za-z0-9_+/-]+)"} $data -> tz] && [valid_tz $tz]} { return $tz }
    }
    # the live system's clock setting, else UTC
    if {![catch {file readlink [::rb::rpath /etc/localtime]} l] && [regexp {zoneinfo/(.+)$} $l -> tz] && [valid_tz $tz]} {
        if {$tz ni {UTC Etc/UTC}} { return $tz }
    }
    return UTC
}

proc ::rb::machine::valid_tz {tz} {
    if {![regexp {^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$} $tz]} { return 0 }
    set zi [::rb::rpath /usr/share/zoneinfo]
    if {![file isdirectory $zi]} { return 1 }
    file isfile [file join $zi $tz]
}

proc ::rb::machine::locale {} {
    foreach line [split [::rb::readall [::rb::rpath /etc/locale.conf]] \n] {
        if {[regexp {^LANG="?([^"\s]+)"?} $line -> v]} { return $v }
    }
    return en_US.UTF-8
}

# The console keymap: /etc/vconsole.conf on every base; where it says nothing, the base's own place, asked of the
# package seam (pkg.sh keymap: Void's rc.conf).
proc ::rb::machine::keymap {} {
    set v ""
    foreach line [split [::rb::readall [::rb::rpath /etc/vconsole.conf]] \n] {
        if {[regexp {^\s*KEYMAP=["']?([^"'\s]+)} $line -> k]} { set v $k }
    }
    if {$v ne ""} { return $v }
    return [::rbpkg::keymap $::rb::root]
}

proc ::rb::machine::facts {} {
    dict create efi [efi] secureboot [secureboot] ram [ram] laptop [laptop] \
        battery [battery] cpu [cpu] net [net] timezone [timezone] \
        locale [locale] keymap [keymap]
}
