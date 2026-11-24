# hwdb.tcl - every driver Ribbon knows how to set up, as data, and the
# detection that matches it against this computer (PCI, USB, HID, input,
# IIO, CPU, DMI, firmware the kernel asked for).
#
# A rule says what a device is and what it needs:
#   bus       pci | usb | hid
#   class     PCI class (6 hex digits), glob: 0300*      (pci)
#   iface     USB interface class/subclass/protocol, glob: e0/01/01   (usb)
#   vendor    vendor IDs (lower-case hex)
#   ids       vendor:device IDs; a name refers to a list in ::hw::idlists
#   name      regexp on the device name
#   category  shown on the Hardware page
#   driver    what is shown ("kernel": "in the kernel (<bound driver>)")
#   packages  package ids to install (pkg.sh: the base's names are in its
#             pkg-names file; tests/pkg-seam.sh checks that every id is there)
#   services  dinit services to enable when the driver is chosen
#   status    unsupported (else: install if a package is missing, builtin if not)
#   skip      1: not shown (e.g. the HDMI audio function of a graphics card)
#   merge     1: one entry for the category however many devices match
# The first rule that matches a device wins.

namespace eval ::hw {
    variable idlists
    # Broadcom BCM43xx chips only the proprietary wl driver supports (ribbon-hw WL_IDS)
    set idlists(wl) {14e4:4311 14e4:4312 14e4:4313 14e4:4315 14e4:4328 14e4:4329 14e4:432a
        14e4:432b 14e4:432c 14e4:432d 14e4:4353 14e4:4357 14e4:4358 14e4:4359 14e4:4365
        14e4:43a0 14e4:43b1}
    # Xbox One / Series controllers that also work over Bluetooth (xpadneo)
    set idlists(xbox_bt) {045e:02e0 045e:02ea 045e:02fd 045e:0b00 045e:0b05 045e:0b12
        045e:0b13 045e:0b20 045e:0b22}
    # Xbox Wireless Adapter (the USB dongle): xone
    set idlists(xbox_dongle) {045e:02e6 045e:02fe 045e:091e}
    # wired Xbox 360 / One pads: xpad in the kernel
    set idlists(xbox_wired) {045e:028e 045e:028f 045e:0291 045e:02d1 045e:02dd 045e:02e3
        045e:02ff 045e:0719 0e6f:* 24c6:*}
    # Sony DualShock 4 / DualSense: hid-playstation in the kernel
    set idlists(playstation) {054c:05c4 054c:09cc 054c:0ba0 054c:0ce6 054c:0df2}
    set idlists(nintendo) {057e:2006 057e:2007 057e:2009 057e:200e 057e:2017 057e:2069}
    set idlists(steam) {28de:1102 28de:1142 28de:1205 28de:2102}
    # Intel IPU6 cameras (Tiger Lake to Meteor Lake): intel-ipu6 in the
    # kernel plus libcamera; IPU7 (Lunar Lake and later) has no driver yet
    set idlists(ipu6) {8086:9a19 8086:9a39 8086:4e19 8086:465d 8086:462e 8086:a75d 8086:7d19}
    set idlists(ipu7) {8086:645d 8086:6457 8086:b05d}
    # Intel VMD (NVMe behind "RST" in recent laptops): vmd in the kernel
    set idlists(vmd) {8086:9a0b 8086:467f 8086:a77f 8086:7d0b 8086:ad0b 8086:b06f}
    # virtual graphics (QEMU, virtio, VMware, VirtualBox, QXL)
    set idlists(vgpu) {1234:1111 1af4:1050 15ad:0405 80ee:beef 1b36:0100}

    variable rules {
        {bus pci class 03* vendor 10de category Graphics kind nvidia}
        {bus pci class 03* vendor 1002 category Graphics kind gpu gpu amd driver "AMD, open source (Mesa)"}
        {bus pci class 03* vendor 8086 category Graphics kind gpu gpu intel driver "Intel, open source (Mesa)"}
        {bus pci class 03* ids vgpu category Graphics driver kernel}
        {bus pci class 03* category Graphics driver kernel}

        {bus pci class 0280* ids wl category Wi-Fi driver broadcom-wl packages {broadcom-wl}}
        {bus pci class 0280* vendor 14e4 category Wi-Fi driver kernel packages {firmware-broadcom}}
        {bus pci class 0280* category Wi-Fi driver kernel packages {firmware-network}}
        {bus pci class 0200* category Ethernet driver kernel}

        {bus pci class 0403* vendor {10de 1002} skip 1}
        {bus pci class 0401* vendor 8086 category Audio driver "Sound Open Firmware" packages {sof-firmware alsa-ucm-conf}}
        {bus pci class 040380 vendor 8086 category Audio driver "Sound Open Firmware" packages {sof-firmware alsa-ucm-conf}}
        {bus pci class 0480* vendor 1022 name {ACP|Audio Coprocessor|Audio Processor} category Audio driver "Sound Open Firmware" packages {sof-firmware alsa-ucm-conf}}
        {bus pci class 0403* category Audio driver kernel}

        {bus pci ids ipu6 category Webcam driver "libcamera (intel-ipu6 in the kernel)" packages {libcamera}}
        {bus pci ids ipu7 category Webcam status unsupported driver "no Linux driver yet (Intel IPU7)"}

        {bus pci ids vmd category Storage driver "in the kernel (vmd)"}
        {bus pci class 0104* vendor 8086 category Storage status unsupported driver "Intel RST RAID mode: switch the SATA mode to AHCI in the firmware settings"}
        {bus pci class 0108* category Storage driver kernel}
        {bus pci class 0106* category Storage driver kernel}

        {bus pci class 0c0340 category Thunderbolt merge 1 driver "bolt" packages {bolt} services {bolt}}
        {bus pci class 0880* name {Thunderbolt|USB4} category Thunderbolt merge 1 driver "bolt" packages {bolt} services {bolt}}

        {bus usb ids xbox_dongle category Controller driver xone packages {xone}}
        {bus usb ids xbox_bt category Controller driver xpadneo packages {xpadneo}}
        {bus usb ids xbox_wired category Controller driver "in the kernel (xpad)"}
        {bus usb ids playstation category Controller driver "in the kernel (hid-playstation)"}
        {bus usb ids nintendo category Controller driver "in the kernel (hid-nintendo)"}
        {bus usb ids steam category Controller driver "steam-devices" packages {steam-devices}}
        {bus hid ids xbox_bt category Controller driver xpadneo packages {xpadneo}}
        {bus hid ids playstation category Controller driver "in the kernel (hid-playstation)"}
        {bus hid ids nintendo category Controller driver "in the kernel (hid-nintendo)"}

        {bus usb kind fprint category {Fingerprint reader}}

        {bus usb iface e0/01/01 vendor {0a5c 0489 13d3 0b05} name {BCM|Broadcom} category Bluetooth driver "Broadcom Bluetooth firmware" packages {firmware-broadcom-bt}}
        {bus usb iface e0/01/01 vendor 0a5c category Bluetooth driver "Broadcom Bluetooth firmware" packages {firmware-broadcom-bt}}
        {bus usb iface e0/01/01 category Bluetooth driver kernel}

        {bus usb iface 0e/* category Webcam driver kernel}

        {bus usb iface 07/01/04 category Printer driver "CUPS (IPP over USB)" packages {cups cups-filters ipp-usb} services {cupsd}}
        {bus usb iface 07/* vendor 03f0 category Printer driver "CUPS and HPLIP" packages {cups cups-filters hplip} services {cupsd}}
        {bus usb iface 07/* vendor {04b8 04a9 04f9} category Printer driver "CUPS and Gutenprint" packages {cups cups-filters gutenprint} services {cupsd}}
        {bus usb iface 07/* category Printer driver CUPS packages {cups cups-filters} services {cupsd}}
    }

    # Firmware files the kernel asked for -> the package id holding them
    # (first match wins).
    variable firmware_packages {
        amdgpu/* firmware-amd   radeon/* firmware-amd   amd/* firmware-amd
        amd-ucode/* firmware-amd   amdtee/* firmware-amd
        i915/* firmware-intel   xe/* firmware-intel
        intel/sof* sof-firmware   intel/avs/* sof-firmware
        nvidia/* firmware-nvidia
        brcm/*.hcd firmware-broadcom-bt   brcm/* firmware-broadcom
        qcom/* firmware-qualcomm
        iwlwifi-* firmware-network   ath9k_htc/* firmware-network
        ath10k/* firmware-network   ath11k/* firmware-network   ath12k/* firmware-network
        mediatek/* firmware-network   mt7* firmware-network
        rtw88/* firmware-network   rtw89/* firmware-network   rtlwifi/* firmware-network
        rtl_nic/* firmware-network
        * linux-firmware
    }

    variable categories {Graphics Wi-Fi Ethernet Processor Audio Bluetooth Controller
        {Fingerprint reader} Webcam Thunderbolt Printer Touchpad Sensors Storage Firmware}
    variable prefix {Graphics gpu Wi-Fi wifi Ethernet eth Processor cpu Audio audio
        Bluetooth bt Controller pad {Fingerprint reader} fp Webcam cam Thunderbolt tb
        Printer print Touchpad touch Sensors sensor Storage disk Firmware fw}

    # NVIDIA: pci.ids chip names (as ribbon-gpu classifies them) -> driver,
    # then the choices offered, the default first.
    variable nvidia_series {
        {TU1* GA1*} {latest 580 470 nouveau}
        {AD1* GB1* GB2* GH1* GN2*} {latest 580 nouveau}
        {GM1* GM2* GP1* GV1*} {580 470 nouveau}
        {GK1* GK2*} {470 nouveau}
    }
    # choice -> {ribbon-gpu driver, label, driver text, description}
    variable nvidia_choice {
        latest {nvidia Latest "NVIDIA, proprietary (latest)" "The newest NVIDIA driver; best for games"}
        580 {nvidia580 "580 series" "NVIDIA, proprietary (580 series)" "NVIDIA's last driver for GeForce GTX 900 and 10 series (Maxwell, Pascal, Volta)"}
        470 {nvidia470 "470 series" "NVIDIA, proprietary (470 series)" "The older driver for GeForce 600 and 700 series (Kepler)"}
        nouveau {nouveau Nouveau "Nouveau (open source)" "Open source and built in; slower in games, no CUDA"}
    }
}

source [file join $::rb::libdir fprint-ids.tcl]
# pkg.tcl: beside the installed backend (/usr/lib/ribbon), or ribbon-tools' in the source tree
foreach ::hw::f [list [file join $::rb::libdir .. pkg.tcl] [file join $::rb::libdir .. .. .. ribbon-tools files lib pkg.tcl]] {
    if {[file exists $::hw::f]} { source $::hw::f; break }
}
unset ::hw::f

# --- sysfs readers ----------------------------------------------------------

# "0x10de", "10de" -> "10de"
proc ::hw::hex4 {s} {
    set s [string trim $s]
    if {![string match 0x* $s]} { set s 0x$s }
    if {![string is xdigit -strict [string range $s 2 end]]} { return 0000 }
    format %04x [expr {$s}]
}

proc ::hw::realpath {p} {
    for {set i 0} {$i < 32 && [file type $p] eq "link"} {incr i} {
        set l [file readlink $p]
        set p [file normalize [file join [file dirname $p] $l]]
    }
    return [file normalize $p]
}

proc ::hw::bound {dir} {
    if {[catch {file readlink $dir/driver} l]} { return "" }
    return [file tail $l]
}

proc ::hw::pci_devices {} {
    set out {}
    foreach d [lsort [glob -nocomplain -directory [::rb::rpath /sys/bus/pci/devices] *]] {
        set v [hex4 [::rb::readfile $d/vendor 0]]
        set p [hex4 [::rb::readfile $d/device 0]]
        set c [format %06x [expr {[::rb::readfile $d/class 0] + 0}]]
        lappend out [dict create bus pci path $d slot [file tail $d] vendor $v device $p id $v:$p \
            class $c driver [bound $d] modalias [::rb::readfile $d/modalias]]
    }
    return $out
}

proc ::hw::usb_devices {} {
    set out {}
    foreach d [lsort [glob -nocomplain -directory [::rb::rpath /sys/bus/usb/devices] *]] {
        set n [file tail $d]
        if {[string match *:* $n] || ![file exists $d/idVendor]} continue
        set v [hex4 [::rb::readfile $d/idVendor 0]]
        set p [hex4 [::rb::readfile $d/idProduct 0]]
        if {$v eq "1d6b"} continue   ;# root hubs
        if {[::rb::readfile $d/bDeviceClass] eq "09"} continue
        set ifs {}
        set drivers {}
        foreach i [lsort [glob -nocomplain -directory $d "$n:*"]] {
            lappend ifs [format %s/%s/%s [hex4 [::rb::readfile $i/bInterfaceClass 0]] \
                [hex4 [::rb::readfile $i/bInterfaceSubClass 0]] [hex4 [::rb::readfile $i/bInterfaceProtocol 0]]]
            set b [bound $i]
            if {$b ne "" && $b ni $drivers} { lappend drivers $b }
        }
        # interface classes as two hex digits, like lsusb
        set ifs [lmap x $ifs { join [lmap y [split $x /] { string range $y end-1 end }] / }]
        set name [string trim "[::rb::readfile $d/manufacturer] [::rb::readfile $d/product]"]
        lappend out [dict create bus usb path $d vendor $v device $p id $v:$p ifaces $ifs \
            driver [join $drivers ,] sysname $name realpath [realpath $d]]
    }
    return $out
}

# HID devices (USB, Bluetooth, I2C): /sys/bus/hid/devices/BBBB:VVVV:PPPP.NNNN
proc ::hw::hid_devices {} {
    set out {}
    foreach d [lsort [glob -nocomplain -directory [::rb::rpath /sys/bus/hid/devices] *]] {
        if {![regexp {^([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4})\.} [file tail $d] -> b v p]} continue
        set name ""
        foreach line [split [::rb::readall $d/uevent] \n] {
            if {[regexp {^HID_NAME=(.*)$} $line -> name]} break
        }
        lappend out [dict create bus hid path $d hidbus [string tolower $b] vendor [string tolower $v] \
            device [string tolower $p] id [string tolower $v:$p] driver [bound $d] sysname $name]
    }
    return $out
}

# Network interfaces that are Wi-Fi, by the device they sit on
proc ::hw::wifi_devices {} {
    set out {}
    foreach n [lsort [glob -nocomplain -directory [::rb::rpath /sys/class/net] *]] {
        if {![file exists $n/phy80211] && ![file exists $n/wireless]} continue
        if {[catch {realpath $n/device} dev]} continue
        lappend out $dev
    }
    return $out
}

# --- names (pci.ids / usb.ids) ------------------------------------------------

proc ::hw::ids_file {kind} {
    foreach f [list [::rb::rpath /usr/share/hwdata/$kind.ids] [::rb::rpath /usr/share/misc/$kind.ids] \
                   /usr/share/hwdata/$kind.ids /usr/share/misc/$kind.ids] {
        if {[file readable $f]} { return $f }
    }
    return ""
}

# vendor:device -> {vendorname devicename} for the requested IDs
proc ::hw::lookup_names {kind ids} {
    set res {}
    set f [ids_file $kind]
    if {$f eq "" || ![llength $ids]} { return $res }
    set want {}
    foreach id $ids { lassign [split $id :] v d; dict lappend want $v $d }
    set ch [open $f r]
    fconfigure $ch -encoding utf-8
    set data [read $ch]
    close $ch
    set vend ""
    set vname ""
    foreach line [split $data \n] {
        if {$line eq "" || [string index $line 0] eq "#"} continue
        if {[string index $line 0] ne "\t"} {
            if {[regexp {^([0-9a-f]{4})\s+(.*)$} $line -> v n] && [dict exists $want $v]} {
                set vend $v; set vname $n
                foreach d [dict get $want $v] { dict set res $v:$d [list $n ""] }
            } else {
                if {$vend ne "" && [string match C* $line]} break
                set vend ""
            }
            continue
        }
        if {$vend eq "" || [string index $line 1] eq "\t"} continue
        if {[regexp {^\t([0-9a-f]{4})\s+(.*)$} $line -> d n] && $d in [dict get $want $vend]} {
            dict set res $vend:$d [list $vname $n]
        }
    }
    return $res
}

proc ::hw::short_vendor {v name} {
    switch -- $v {
        10de { return NVIDIA }
        1002 - 1022 { return AMD }
        8086 - 8087 { return Intel }
        14e4 - 0a5c { return Broadcom }
        10ec - 0bda { return Realtek }
        168c - 17cb - 0cf3 { return Qualcomm }
        14c3 - 0e8d { return MediaTek }
        144d - 04e8 { return Samsung }
        045e { return Microsoft }
        054c { return Sony }
        057e { return Nintendo }
        27c6 { return Goodix }
        06cb { return Synaptics }
        138a { return Validity }
        04f3 { return Elan }
        03f0 { return HP }
        04b8 { return Epson }
        04a9 { return Canon }
        04f9 { return Brother }
        1987 { return Phison }
        15b7 { return "Western Digital" }
        1c5c { return "SK hynix" }
        c0a9 { return Crucial }
    }
    regsub {\s*\[.*\]} $name "" name
    regsub {,?\s+(Corporation|Corp|Inc|Co|Ltd|Technology|Electronics|Semiconductor|Systems)\M.*$} $name "" name
    return [string trim $name]
}

# "AD104 [GeForce RTX 4070]" -> "GeForce RTX 4070" (graphics: the bracket
# holds the marketing name; elsewhere it is a code name); drop 802.11 noise
proc ::hw::short_device {name {gpu 0}} {
    if {$gpu && [regexp {\[([^\]]+)\]} $name -> b]} { set name $b }
    regsub {\s*\[[^\]]*\]} $name "" name
    regsub {\s+802\.11.*$} $name "" name
    regsub {\s+(Wireless Network Adapter|Network Connection|Controller)$} $name "" name
    return [string trim $name]
}

# --- the installed packages (live system = what the target gets) ---------------
# Asked through the package manager's seam (pkg.tcl, ribbon-tools).

proc ::hw::installed {id} { ::rbpkg::has $::rb::root $id }

proc ::hw::status_for {packages} {
    expr {[llength [::rbpkg::missing $::rb::root $packages]] ? "install" : "builtin"}
}

# Package list for a ribbon-gpu driver, from ribbon-gpu itself (one source).
proc ::hw::gpu_packages {drv} {
    variable gpucache
    if {[info exists gpucache($drv)]} { return $gpucache($drv) }
    set tool ribbon-gpu
    if {[info exists ::env(RIBBON_GPU)]} { set tool $::env(RIBBON_GPU) }
    set pk ""
    if {[file isfile $tool]} {
        set pk [string trim [::rb::out bash $tool packages $drv]]
    } elseif {[::rb::have $tool]} {
        set pk [string trim [::rb::out $tool packages $drv]]
    }
    set gpucache($drv) $pk
    return $pk
}

# --- matching -------------------------------------------------------------------

proc ::hw::ids_of {spec} {
    variable idlists
    set out {}
    foreach x $spec {
        if {[info exists idlists($x)]} { lappend out {*}$idlists($x) } else { lappend out $x }
    }
    return $out
}

proc ::hw::match {rule dev name} {
    if {[dict get $rule bus] ne [dict get $dev bus]} { return 0 }
    if {[dict exists $rule class] && ![string match [dict get $rule class] [dict get $dev class]]} { return 0 }
    if {[dict exists $rule vendor] && [dict get $dev vendor] ni [dict get $rule vendor]} { return 0 }
    if {[dict exists $rule ids]} {
        set hit 0
        foreach id [ids_of [dict get $rule ids]] {
            if {[string match $id [dict get $dev id]]} { set hit 1; break }
        }
        if {!$hit} { return 0 }
    }
    if {[dict exists $rule iface]} {
        set hit 0
        foreach i [dict get $dev ifaces] {
            if {[string match [dict get $rule iface] $i]} { set hit 1; break }
        }
        if {!$hit} { return 0 }
    }
    if {[dict exists $rule name] && ![regexp -nocase -- [dict get $rule name] $name]} { return 0 }
    if {[::rb::get $rule kind] eq "fprint" && [fprint_status [dict get $dev id]] eq ""} { return 0 }
    return 1
}

# supported | unsupported | "" (not a known fingerprint reader). The hwdb
# that libfprint installs is preferred when present.
proc ::hw::fprint_status {id} {
    variable fprint_cache
    if {![info exists fprint_cache]} {
        set fprint_cache {}
        set f [::rb::rpath /usr/lib/udev/hwdb.d/60-autosuspend-libfprint-2.hwdb]
        if {[file readable $f]} {
            set state supported
            foreach line [split [::rb::readall $f] \n] {
                if {[string match "# Supported by*" $line]} { set state supported }
                if {[string match "# Known unsupported*" $line]} { set state unsupported }
                if {[regexp {^usb:v([0-9A-Fa-f]{4})p([0-9A-Fa-f]{4})\*} $line -> v p]} {
                    dict set fprint_cache [string tolower $v:$p] $state
                }
            }
        } else {
            foreach id [concat {*}[dict values $::hw::fprint_supported]] { dict set fprint_cache $id supported }
            foreach id $::hw::fprint_unsupported { dict set fprint_cache $id unsupported }
        }
    }
    ::rb::get $fprint_cache $id
}

proc ::hw::kernel_text {drv} {
    if {$drv eq ""} { return "in the kernel" }
    return "in the kernel ($drv)"
}

# Turn a matched rule + device into a driver entry (without id).
proc ::hw::entry {rule dev name} {
    variable nvidia_series
    variable nvidia_choice
    set e [dict create category [dict get $rule category] device $name ids [list [dict get $dev id]] \
        driver "" status builtin choices {} default {} packages {}]
    set kind [::rb::get $rule kind]
    switch -- $kind {
        nvidia {
            set chip [lindex [split [lindex [::rb::get $dev pciname] 1] " "] 0]
            set offer {nouveau}
            foreach {pats choices} $nvidia_series {
                foreach pat $pats { if {[string match $pat $chip]} { set offer $choices; break } }
                if {$offer ne "nouveau"} break
            }
            if {$offer eq "nouveau" && $chip eq ""} { set offer [nvidia_by_id [dict get $dev device]] }
            set ch {}
            foreach c $offer {
                lassign [dict get $nvidia_choice $c] - label - desc
                if {$c eq [lindex $offer 0]} { append desc ", recommended for this card" }
                lappend ch [list $c $label $desc]
            }
            set def [lindex $offer 0]
            lassign [dict get $nvidia_choice $def] gpu - text
            dict set e driver $text
            dict set e gpu $gpu
            if {[llength $offer] > 1} { dict set e choices $ch; dict set e default $def }
            dict set e packages [gpu_packages $gpu]
            dict set e gpuchoices [dict create {*}[concat {*}[lmap c $offer { list $c [lindex [dict get $nvidia_choice $c] 0] }]]]
        }
        gpu {
            dict set e driver [dict get $rule driver]
            dict set e gpu [dict get $rule gpu]
            dict set e packages [gpu_packages [dict get $rule gpu]]
        }
        fprint {
            if {[fprint_status [dict get $dev id]] eq "supported"} {
                dict set e driver fprintd
                dict set e packages {fprintd libfprint}
            } else {
                dict set e driver "no Linux driver yet (libfprint)"
                dict set e status unsupported
                return $e
            }
        }
        default {
            set drv [::rb::get $rule driver kernel]
            if {$drv eq "kernel"} { set drv [kernel_text [lindex [split [dict get $dev driver] ,] 0]] }
            dict set e driver $drv
            dict set e packages [::rb::get $rule packages]
            if {[dict exists $rule services]} { dict set e services [dict get $rule services] }
        }
    }
    if {[::rb::get $rule status] eq "unsupported"} {
        dict set e status unsupported
        return $e
    }
    dict set e status [status_for [dict get $e packages]]
    return $e
}

# NVIDIA without a pci.ids name: rough device-ID ranges.
proc ::hw::nvidia_by_id {devid} {
    set n [expr {"0x$devid"}]
    if {$n >= 0x1e00} { return {latest 580 nouveau} }
    if {$n >= 0x1340} { return {580 470 nouveau} }
    foreach {a b} {0x0fc0 0x0fff 0x1000 0x103f 0x1180 0x11ff 0x1280 0x12bf} {
        if {$n >= $a && $n <= $b} { return {470 nouveau} }
    }
    return {nouveau}
}

# --- the non-bus detectors ------------------------------------------------------

proc ::hw::cpu_entry {} {
    set c [::rb::machine::cpu]
    set e [dict create category Processor device [dict get $c model] ids {} choices {} default {}]
    switch -- [dict get $c vendor] {
        intel { dict set e driver "Intel microcode updates"; dict set e packages {microcode-intel} }
        amd { dict set e driver "AMD microcode updates"; dict set e packages {firmware-amd} }
        default { return "" }
    }
    if {[dict get $e device] eq ""} { dict set e device [expr {[dict get $c vendor] eq "intel" ? "Intel processor" : "AMD processor"}] }
    dict set e status [status_for [dict get $e packages]]
    return $e
}

proc ::hw::touchpad_entries {} {
    set out {}
    set name ""
    foreach line [split [::rb::readall [::rb::rpath /proc/bus/input/devices]] \n] {
        if {[regexp {^N: Name="(.*)"$} $line -> name]} {
            if {[regexp -nocase {touchpad|trackpad|glidepoint|clickpad} $name]} {
                lappend out [dict create category Touchpad device $name ids {} driver "in the kernel (libinput)" \
                    status builtin choices {} default {} packages {}]
            }
        }
    }
    return [lrange $out 0 0]
}

proc ::hw::sensor_entry {} {
    set names {}
    foreach d [glob -nocomplain -directory [::rb::rpath /sys/bus/iio/devices] iio:device*] {
        lappend names [::rb::readfile $d/name]
    }
    set accel [expr {[lsearch -regexp $names {accel|incli}] >= 0}]
    set als [expr {[lsearch -regexp $names {als|light}] >= 0}]
    if {!$accel && ![::rb::machine::convertible] && !$als} { return "" }
    set what [expr {$accel || [::rb::machine::convertible] ? "Accelerometer (screen rotation)" : "Ambient light sensor"}]
    set e [dict create category Sensors device $what ids {} driver iio-sensor-proxy choices {} default {} \
        packages {iio-sensor-proxy} services {iio-sensor-proxy}]
    dict set e status [status_for [dict get $e packages]]
    return $e
}

proc ::hw::dmesg_text {} {
    if {[info exists ::env(RIBBON_PROBE_DMESG)]} { return [::rb::readall $::env(RIBBON_PROBE_DMESG)] }
    if {$::rb::root ne ""} { return [::rb::readall [::rb::rpath /dmesg.txt]] }
    return [::rb::out dmesg]
}

proc ::hw::firmware_present {file} {
    foreach base [list /usr/lib/firmware /lib/firmware] {
        foreach ext {"" .zst .xz} {
            if {[file exists [::rb::rpath $base/$file$ext]]} { return 1 }
        }
    }
    return 0
}

# Firmware the kernel asked for and didn't find, by package (only packages
# that aren't installed: drivers often try newer files first, harmlessly).
proc ::hw::firmware_entries {} {
    variable firmware_packages
    set bypkg {}
    foreach line [split [dmesg_text] \n] {
        set file ""
        set who ""
        if {[regexp {\]\s*(\S+)\s+(.*):\s+Direct firmware load for (\S+) failed} $line -> who - file]} {
        } elseif {[regexp {\]\s*(\S+)\s+(.*):\s+firmware: failed to load (\S+)} $line -> who - file]} {
        } else continue
        if {[firmware_present $file]} continue
        foreach {pat pkg} $firmware_packages {
            if {[string match $pat $file]} break
        }
        if {[installed $pkg]} continue
        dict lappend bypkg $pkg [list $who $file]
    }
    set out {}
    dict for {pkg hits} $bypkg {
        set whos [lsort -unique [lmap h $hits { lindex $h 0 }]]
        lappend out [dict create category Firmware device "Firmware for [join $whos {, }]" ids {} \
            driver $pkg status install choices {} default {} packages [list $pkg] \
            files [lsort -unique [lmap h $hits { lindex $h 1 }]]]
    }
    return $out
}

# Devices of interesting classes that no driver took and no rule covers.
proc ::hw::unbound_entry {dev name} {
    set cat ""
    if {[dict get $dev bus] eq "pci"} {
        switch -glob -- [dict get $dev class] {
            02* { set cat [expr {[string match 0280* [dict get $dev class]] ? "Wi-Fi" : "Ethernet"}] }
            03* { set cat Graphics }
            04* { set cat Audio }
            0d* { set cat Wi-Fi }
            default { return "" }
        }
    } else { return "" }
    if {[dict get $dev driver] ne ""} { return "" }
    # does the kernel have a module for it at all?
    if {$::rb::root eq "" && [dict get $dev modalias] ne "" && [::rb::have modprobe]} {
        set m [string trim [::rb::out modprobe -R [dict get $dev modalias]]]
        if {$m ne ""} {
            return [dict create category $cat device $name ids [list [dict get $dev id]] \
                driver [kernel_text [lindex $m 0]] status builtin choices {} default {} packages {}]
        }
    }
    dict create category $cat device $name ids [list [dict get $dev id]] \
        driver "no Linux driver found" status unsupported choices {} default {} packages {}
}

# --- everything -----------------------------------------------------------------

proc ::hw::detect {} {
    variable rules
    variable categories
    variable prefix
    set pci [pci_devices]
    set usb [usb_devices]
    set hid [hid_devices]
    set wifi [wifi_devices]

    set pnames [lookup_names pci [lsort -unique [lmap d $pci { dict get $d id }]]]
    set unames [lookup_names usb [lsort -unique [lmap d $usb { dict get $d id }]]]

    set found {}
    set seen {}
    foreach dev [concat $pci $usb $hid] {
        set id [dict get $dev id]
        set bus [dict get $dev bus]
        switch -- $bus {
            pci {
                set n [::rb::get $pnames $id]
                dict set dev pciname $n
                set name [string trim "[short_vendor [dict get $dev vendor] [lindex $n 0]] [short_device [lindex $n 1] [string match 03* [dict get $dev class]]]"]
                if {[lindex $n 1] eq ""} { set name "[short_vendor [dict get $dev vendor] [lindex $n 0]] device $id" }
            }
            usb {
                set n [::rb::get $unames $id]
                set name [dict get $dev sysname]
                if {[lindex $n 1] ne ""} {
                    set name "[short_vendor [dict get $dev vendor] [lindex $n 0]] [short_device [lindex $n 1]]"
                } elseif {$name eq ""} { set name "[short_vendor [dict get $dev vendor] ""] $id" }
            }
            hid {
                set name [dict get $dev sysname]
                if {$name eq ""} { set name "Device $id" }
                # a USB HID device is already covered by its USB entry
                if {[dict get $dev hidbus] eq "0003"} continue
            }
        }
        set name [string trim $name]
        set e ""
        foreach rule $rules {
            if {[match $rule $dev $name]} {
                if {[::rb::get $rule skip 0]} { set e skip; break }
                set e [entry $rule $dev $name]
                if {[::rb::get $rule merge 0]} { dict set e merge 1 }
                break
            }
        }
        if {$e eq "skip"} continue
        # a catch-all "in the kernel" rule, but no driver took the device
        if {$e ne "" && $bus eq "pci" && [dict get $dev driver] eq "" && ![llength [dict get $e packages]]
            && [string match "in the kernel*" [dict get $e driver]] && [dict get $e status] eq "builtin"} {
            set u [unbound_entry $dev $name]
            if {$u ne ""} { set e $u }
        }
        if {$e eq "" && $bus eq "usb" && [dict get $dev realpath] in [lmap w $wifi { file dirname $w }]} {
            set e [dict create category Wi-Fi device $name ids [list $id] status builtin \
                driver [kernel_text [lindex [split [dict get $dev driver] ,] 0]] choices {} default {} packages {}]
        }
        if {$e eq ""} { set e [unbound_entry $dev $name] }
        if {$e eq ""} continue
        # one entry per category + device ID (a pad seen over USB and HID, two
        # identical disks), and per category for merged ones (Thunderbolt)
        set key [expr {[::rb::get $e merge 0] ? [dict get $e category] : "[dict get $e category]/$id"}]
        if {[dict exists $seen $key]} continue
        dict set seen $key 1
        dict unset e merge
        lappend found $e
    }
    set cpu [cpu_entry]
    if {$cpu ne ""} { lappend found $cpu }
    lappend found {*}[touchpad_entries]
    set s [sensor_entry]
    if {$s ne ""} { lappend found $s }
    # firmware entries only for packages nothing else already brings
    set covered {}
    foreach e $found { foreach p [::rb::get $e packages] { dict set covered $p 1 } }
    foreach e [firmware_entries] {
        if {![dict exists $covered [lindex [dict get $e packages] 0]]} { lappend found $e }
    }

    # ids: category prefix + index, in detection order (stable across runs)
    set count {}
    set out {}
    foreach e $found {
        set pre [dict get $prefix [dict get $e category]]
        set n [::rb::get $count $pre 0]
        dict set count $pre [expr {$n + 1}]
        lappend out [dict merge [dict create id $pre$n] $e]
    }
    # order: things to install, then built in, then unsupported; by category
    set rank {install 0 builtin 1 unsupported 2}
    set i 0
    set keyed {}
    foreach e $out {
        lappend keyed [list [dict get $rank [dict get $e status]] [lsearch $categories [dict get $e category]] [incr i] $e]
    }
    set keyed [lsort -integer -index 2 $keyed]
    set keyed [lsort -integer -index 1 $keyed]
    set keyed [lsort -integer -index 0 $keyed]
    return [lmap k $keyed { lindex $k 3 }]
}

# The public part of an entry (what the probe prints).
proc ::hw::public {e} {
    set out {}
    foreach k {id category device ids driver status choices default packages} {
        dict set out $k [::rb::get $e $k]
    }
    return $out
}

# answers' drivers {id choice ...} -> {gpu {drivers} packages {} services {} skipped {}}
# Errors (unknown id or choice) are returned as {error text}.
proc ::hw::plan {chosen detected} {
    set gpus {}
    set pkgs {}
    set svcs {}
    set byid {}
    foreach e $detected { dict set byid [dict get $e id] $e }
    if {[llength $chosen] % 2} { return [list error "drivers must be a list of id and choice pairs"] }
    foreach {id choice} $chosen {
        if {![dict exists $byid $id]} { return [list error "unknown driver id '$id' (not found on this computer)"] }
        set e [dict get $byid $id]
        set choices [lmap c [dict get $e choices] { lindex $c 0 }]
        if {$choice ne "" && $choice ni $choices} {
            return [list error "driver $id ([dict get $e device]) has no choice '$choice'[expr {[llength $choices] ? "; pick one of: [join $choices {, }]" : ""}]"]
        }
        if {[dict get $e status] eq "unsupported"} continue
        if {[dict exists $e gpu]} {
            set g [dict get $e gpu]
            if {$choice ne "" && [dict exists $e gpuchoices]} { set g [dict get $e gpuchoices $choice] }
            if {$g ni $gpus} { lappend gpus $g }
            continue
        }
        if {[dict get $e status] ne "install" && ![dict exists $e services]} continue
        foreach p [dict get $e packages] {
            if {$p ni $pkgs && ![installed $p]} { lappend pkgs $p }
        }
        foreach s [::rb::get $e services] { if {$s ni $svcs} { lappend svcs $s } }
    }
    dict create gpu $gpus packages $pkgs services $svcs
}
