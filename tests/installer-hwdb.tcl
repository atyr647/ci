# The installer's driver table and machine facts on a fake computer: a fake
# root with /sys (PCI, USB, HID, IIO, DMI, power supplies, network), /proc,
# dmesg, pci.ids/usb.ids and an xbps package database, read through
# RIBBON_PROBE_ROOT. No root needed.
#   tclsh8.6 tests/installer-hwdb.tcl
set repo [file normalize [file join [file dirname [info script]] ..]]
set R [file join [expr {[info exists env(TMPDIR)] ? $env(TMPDIR) : "/tmp"}] ribbon-hwdb-[pid]]
file delete -force $R
set env(RIBBON_PROBE_ROOT) $R
set env(RIBBON_PROBE_GEOIP) 0
unset -nocomplain env(RIBBON_UEFI)
set env(RIBBON_GPU) $repo/srcpkgs/ribbon-tools/files/bin/ribbon-gpu
set env(RIBBON_LIB) $repo/srcpkgs/ribbon-tools/files/lib

set fail 0
proc check {desc cond} {
    if {[uplevel 1 [list expr $cond]]} { puts "  ok   $desc" } else { puts "  FAIL $desc"; set ::fail 1 }
}
proc put {path data} {
    set p $::R$path
    file mkdir [file dirname $p]
    set f [open $p w]; puts -nonewline $f $data; close $f
}
proc putb {path data} {
    set p $::R$path
    file mkdir [file dirname $p]
    set f [open $p wb]; puts -nonewline $f $data; close $f
}
proc link {path target} {
    file mkdir [file dirname $::R$path]
    exec ln -sfn $target $::R$path   ;# (file link wants the target to exist)
}

# --- PCI: slot vendor device class driver
foreach {slot v d c drv} {
    0000:00:02.0 8086 46a6 0x030000 i915
    0000:01:00.0 10de 2786 0x030000 nouveau
    0000:01:00.1 10de 22bc 0x040300 snd_hda_intel
    0000:02:00.0 14e4 43a0 0x028000 {}
    0000:00:1f.3 8086 51c8 0x040100 snd_sof_pci_intel_tgl
    0000:03:00.0 144d a80c 0x010802 nvme
    0000:00:0d.2 8086 9a1b 0x0c0340 thunderbolt
    0000:00:0d.3 8086 9a1d 0x0c0340 thunderbolt
    0000:00:05.0 8086 465d 0x048000 {}
    0000:04:00.0 10ec 8168 0x020000 r8169
    0000:06:00.0 1d6a 07b1 0x020000 {}
    0000:00:00.0 8086 4621 0x060000 {}
} {
    set p /sys/devices/pci0000:00/$slot
    put $p/vendor 0x$v\n; put $p/device 0x$d\n; put $p/class $c\n
    put $p/modalias "pci:v0000${v}d0000${d}\n"
    if {$drv ne ""} { link $p/driver ../../../bus/pci/drivers/$drv }
    link /sys/bus/pci/devices/$slot ../../../devices/pci0000:00/$slot
}
# --- USB: port vendor product name interfaces(class/sub/proto) driver
foreach {port v p name ifs drv} {
    1-3 27c6 538d {Goodix FingerPrint} {ff/00/00} {}
    1-4 27c6 5840 {Goodix MOC Fingerprint} {ff/00/00} {}
    1-5 8087 0032 {} {e0/01/01 e0/01/01} btusb
    1-6 045e 0b12 {Microsoft Xbox Wireless Controller} {ff/47/d0} xpad
    1-7 0c45 6366 {Integrated Webcam} {0e/01/00 0e/02/00} uvcvideo
    1-8 03f0 2b17 {HP LaserJet} {07/01/02} usblp
    1-9 054c 0ce6 {Sony DualSense} {03/00/00} playstation
    1-10 1d6b 0002 {root hub} {09/00/00} hub
    2-1 0bda b812 {802.11ac NIC} {ff/ff/ff} rtw88_8822bu
} {
    set d /sys/devices/pci0000:00/0000:00:14.0/usb1/$port
    put $d/idVendor $v\n; put $d/idProduct $p\n; put $d/product $name\n; put $d/bDeviceClass 00\n
    set i 0
    foreach x $ifs {
        lassign [split $x /] c s pr
        put $d/$port:1.$i/bInterfaceClass $c\n; put $d/$port:1.$i/bInterfaceSubClass $s\n; put $d/$port:1.$i/bInterfaceProtocol $pr\n
        if {$drv ne ""} { link $d/$port:1.$i/driver ../../../../../../bus/usb/drivers/$drv }
        incr i
    }
    link /sys/bus/usb/devices/$port ../../../devices/pci0000:00/0000:00:14.0/usb1/$port
}
# a USB Wi-Fi adapter's network interface
link /sys/class/net/wlx0 ../../devices/pci0000:00/0000:00:14.0/usb1/2-1/2-1:1.0/net/wlx0
put /sys/devices/pci0000:00/0000:00:14.0/usb1/2-1/2-1:1.0/net/wlx0/operstate down\n
file mkdir $R/sys/devices/pci0000:00/0000:00:14.0/usb1/2-1/2-1:1.0/net/wlx0/wireless
link /sys/class/net/wlx0/device ../../../2-1:1.0
# --- HID over Bluetooth: the DualSense again (deduplicated) and an Xbox pad
foreach {n name} {0005:054C:0CE6.0001 {DualSense Wireless Controller} 0005:045E:0B13.0002 {Xbox Wireless Controller}} {
    put /sys/bus/hid/devices/$n/uevent "HID_ID=x\nHID_NAME=$name\n"
}
# --- input, IIO, DMI, power, CPU, memory, network, firmware
put /proc/bus/input/devices "I: Bus=0018\nN: Name=\"SYNA2393:00 06CB:7A13 Touchpad\"\nH: Handlers=mouse0\n\nI: Bus=0011\nN: Name=\"AT Translated Set 2 keyboard\"\n"
put /sys/bus/iio/devices/iio:device0/name accel_3d\n
put /sys/class/dmi/id/chassis_type 31\n
put /sys/class/power_supply/BAT0/capacity 80\n
put /sys/class/power_supply/BAT0/status Discharging\n
put /sys/class/power_supply/AC/type Mains\n
put /sys/class/power_supply/AC/online 0\n
put /proc/cpuinfo "processor\t: 0\nvendor_id\t: GenuineIntel\nmodel name\t: 12th Gen Intel(R) Core(TM) i7-1260P\n"
put /proc/meminfo "MemTotal:       16212345 kB\n"
file mkdir $R/sys/firmware/efi/efivars
putb /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-e39818d4bd12 "\x06\x00\x00\x00\x01"
put /sys/class/net/wlan0/operstate up\n
file mkdir $R/sys/class/net/wlan0/wireless
put /proc/net/route "Iface\tDestination\tGateway\nwlan0\t00000000\t0102A8C0\t0003\n"
link /etc/localtime ../usr/share/zoneinfo/Europe/London
put /usr/share/zoneinfo/Europe/London TZif
put /etc/locale.conf "LANG=en_GB.UTF-8\n"
put /etc/rc.conf "KEYMAP=\"uk\"\n"
put /dmesg.txt [join {
    {[    3.100000] bluetooth hci0: Direct firmware load for brcm/BCM4350C5.hcd failed with error -2}
    {[    4.000000] iwlwifi 0000:00:14.3: Direct firmware load for iwlwifi-so-a0-gf-a0-89.ucode failed with error -2}
    {[    5.000000] rtw89_8852be 0000:05:00.0: Direct firmware load for rtw89/rtl8852b_fw.bin failed with error -2}
    {[    6.000000] cs35l41-hda i2c-CSC3551:00-cs35l41-hda.0: Direct firmware load for cirrus/cs35l41-dsp1-spk-prot-17aa3847.wmfw failed with error -2}
} \n]\n
put /usr/lib/firmware/rtw89/rtl8852b_fw.bin.zst x
put /usr/share/hwdata/pci.ids [join {
    "8086  Intel Corporation"
    "\t46a6  Alder Lake-P GT2 \[Iris Xe Graphics\]"
    "\t51c8  Alder Lake PCH-P High Definition Audio Controller"
    "\t9a1b  Tiger Lake-LP Thunderbolt 4 NHI #0"
    "\t465d  Alder Lake Imaging Signal Processor"
    "10de  NVIDIA Corporation"
    "\t2786  AD104 \[GeForce RTX 4070\]"
    "\t\t1043 8888  some subsystem"
    "\t22bc  AD104 High Definition Audio Controller"
    "10ec  Realtek Semiconductor Co., Ltd."
    "\t8168  RTL8111/8168/8211/8411 PCI Express Gigabit Ethernet Controller"
    "144d  Samsung Electronics Co Ltd"
    "\ta80c  NVMe SSD Controller S4LV008\[Pascal\]"
    "14e4  Broadcom Inc. and subsidiaries"
    "\t43a0  BCM4360 802.11ac Dual Band Wireless Network Adapter"
    "C 00  Unclassified device"
} \n]\n
put /usr/share/hwdata/usb.ids "8087  Intel Corp.\n\t0032  AX210 Bluetooth\n"
set pkgdb "<?xml version=\"1.0\"?>\n<plist version=\"1.0\">\n<dict>\n"
foreach p {sof-firmware alsa-ucm-conf bolt iio-sensor-proxy linux-firmware-network linux-firmware-amd
           linux-firmware-intel mesa-dri mesa-vulkan-intel intel-media-driver vulkan-loader} {
    append pkgdb "\t<key>$p</key>\n\t<dict>\n\t\t<key>pkgver</key>\n\t\t<string>$p-1_1</string>\n\t</dict>\n"
}
put /var/db/xbps/pkgdb-0.38.plist "$pkgdb</dict>\n</plist>\n"

# --- load the backend against the fake root
set be $repo/srcpkgs/ribbon-installer/files/backend
foreach f {common.tcl disks.tcl machine.tcl hwdb.tcl answers.tcl} { source $be/$f }

puts "machine facts"
set m [::rb::machine::facts]
check "UEFI with Secure Boot" {[dict get $m efi] == 1 && [dict get $m secureboot] == 1}
check "RAM in bytes" {[dict get $m ram] == 16212345 * 1024}
check "convertible laptop on battery" {[dict get $m laptop] == 1 && [dict get $m battery] eq "percent 80 charging 0 ac 0"}
check "CPU" {[dict get $m cpu] eq "vendor intel model {12th Gen Intel Core i7-1260P}"}
check "network: Wi-Fi with a default route" {[dict get $m net] eq "online 1 kind wifi name wlan0"}
check "time zone from the live system (no geo-IP)" {[dict get $m timezone] eq "Europe/London"}
check "locale and keymap" {[dict get $m locale] eq "en_GB.UTF-8" && [dict get $m keymap] eq "uk"}
put /etc/vconsole.conf "FONT=ter-v16n\nKEYMAP=de-latin1\n"
check "keymap: /etc/vconsole.conf wins over Void's rc.conf" {[::rb::machine::keymap] eq "de-latin1"}
file delete $R/etc/vconsole.conf

puts "drivers"
set det [::hw::detect]
set byid {}
foreach e $det { dict set byid [dict get $e id] $e }
proc e {id {k ""}} {
    if {![dict exists $::byid $id]} { return "" }
    if {$k eq ""} { return [dict get $::byid $id] }
    return [::rb::get [dict get $::byid $id] $k]
}
proc cat {c} { lmap e $::det { if {[dict get $e category] ne $c} continue; dict get $e id } }
foreach e $det { puts "       [format %-8s [dict get $e id]] [format %-11s [dict get $e status]] [dict get $e category]: [dict get $e device] -> [dict get $e driver]" }

check "installs first, then built in, then unsupported" {[lsort -command {apply {{a b} {expr {[dict get {install 0 builtin 1 unsupported 2} $a] - [dict get {install 0 builtin 1 unsupported 2} $b]}}}} [lmap e $det { dict get $e status }]] eq [lmap e $det { dict get $e status }]}
check "ids are unique" {[llength [lsort -unique [dict keys $byid]]] == [llength $det]}
check "NVIDIA RTX 4070 by its pci.ids name" {[e gpu1 device] eq "NVIDIA GeForce RTX 4070" && [e gpu1 ids] eq "10de:2786"}
check "Ada: latest, 580, nouveau; latest by default" {[lmap c [e gpu1 choices] { lrange $c 0 1 }] eq {{latest Latest} {580 {580 series}} {nouveau Nouveau}} && [e gpu1 default] eq "latest"}
check "choices carry a description" {[string match "*recommended*" [lindex [e gpu1 choices] 0 2]]}
check "NVIDIA driver text and packages (from ribbon-gpu)" {[e gpu1 driver] eq "NVIDIA, proprietary (latest)" && "nvidia" in [e gpu1 packages] && [e gpu1 status] eq "install"}
check "Intel iGPU: Mesa, packages from ribbon-gpu" {[e gpu0 device] eq "Intel Iris Xe Graphics" && "mesa-vulkan-intel" in [e gpu0 packages]}
check "HDMI audio of the graphics card is not listed" {[lsearch -glob [lmap e $det { dict get $e ids }] 10de:22bc] < 0}
check "Broadcom BCM4360: broadcom-wl" {[e wifi0 device] eq "Broadcom BCM4360" && [e wifi0 packages] eq "broadcom-wl" && [e wifi0 status] eq "install"}
check "USB Wi-Fi found by its network interface" {[e wifi1 status] eq "builtin" && [e wifi1 driver] eq "in the kernel (rtw88_8822bu)"}
check "CPU microcode: microcode-intel (Void's intel-ucode is not there)" {[e cpu0 packages] eq "microcode-intel" && [e cpu0 status] eq "install" && [e cpu0 device] eq "12th Gen Intel Core i7-1260P"}
check "Intel Smart Sound: SOF, already on the system" {[e audio0 driver] eq "Sound Open Firmware" && [e audio0 status] eq "builtin"}
check "Intel Bluetooth: in the kernel" {[e bt0 status] eq "builtin" && [e bt0 driver] eq "in the kernel (btusb)" && [e bt0 device] eq "Intel AX210 Bluetooth"}
check "Xbox controller (USB and Bluetooth): xpadneo" {[e pad0 packages] eq "xpadneo" && [e pad2 packages] eq "xpadneo" && [e pad2 device] eq "Xbox Wireless Controller"}
check "DualSense over USB and Bluetooth: one entry, in the kernel" {[llength [cat Controller]] == 3 && [e pad1 driver] eq "in the kernel (hid-playstation)"}
check "Goodix 27c6:5840: fprintd" {[e fp1 packages] eq "fprintd libfprint" && [e fp1 status] eq "install"}
check "Goodix 27c6:538d: no driver (unsupported)" {[e fp0 status] eq "unsupported"}
check "IPU6 camera: libcamera" {[e cam0 packages] eq "libcamera" && [e cam1 driver] eq "in the kernel (uvcvideo)"}
check "Thunderbolt: one entry, bolt (installed)" {[llength [cat Thunderbolt]] == 1 && [e tb0 status] eq "builtin" && [e tb0 driver] eq "bolt"}
check "HP printer: CUPS and HPLIP, cupsd" {[e print0 packages] eq "cups cups-filters hplip" && [e print0 status] eq "install"}
check "touchpad: built in" {[e touch0 device] eq "SYNA2393:00 06CB:7A13 Touchpad" && [e touch0 status] eq "builtin"}
check "convertible: iio-sensor-proxy (installed)" {[e sensor0 packages] eq "iio-sensor-proxy" && [e sensor0 status] eq "builtin"}
check "NVMe: built in" {[e disk0 status] eq "builtin" && [e disk0 driver] eq "in the kernel (nvme)"}
check "Ethernet without a driver: unsupported" {[e eth1 status] eq "unsupported" && [e eth1 driver] eq "no Linux driver found"}
check "missing Broadcom Bluetooth firmware: firmware-broadcom-bt" {[lsearch [lmap e $det { ::rb::get $e packages }] firmware-broadcom-bt] >= 0}
check "missing Cirrus firmware: linux-firmware" {[lsearch [lmap e $det { ::rb::get $e packages }] linux-firmware] >= 0}
check "firmware a driver merely probed for (iwlwifi, present rtw89) is not listed" {[llength [cat Firmware]] == 2}
check "PCI bridges and root hubs are not listed" {[lsearch -glob [lmap e $det { dict get $e ids }] *8086:4621*] < 0 && [lsearch -glob [lmap e $det { dict get $e ids }] *1d6b*] < 0}
check "every entry has the protocol's keys" {[lsort -unique [lmap e $det { llength [::hw::public $e] }]] eq 18}

puts "install plan from the chosen drivers"
set p [::hw::plan {gpu1 580 gpu0 {} wifi0 {} cpu0 {} fp1 {} print0 {} sensor0 {} fp0 {} bt0 {}} $det]
check "GPU drivers for ribbon-gpu" {[dict get $p gpu] eq "nvidia580 intel"}
check "packages to install (not those already there)" {[dict get $p packages] eq "broadcom-wl microcode-intel fprintd libfprint cups cups-filters hplip"}
check "services" {[dict get $p services] eq "cupsd iio-sensor-proxy"}
check "ids left out are skipped" {[dict get [::hw::plan {gpu1 nouveau} $det] gpu] eq "nouveau" && [dict get [::hw::plan {gpu1 nouveau} $det] packages] eq ""}
check "a choice the device doesn't offer" {[string match "error *no choice '470'*" [::hw::plan {gpu1 470} $det]]}
check "an unknown id" {[string match "error *unknown driver id*" [::hw::plan {gpu9 {}} $det]]}

puts "probe command (fake root)"
set out [exec tclsh8.6 $repo/srcpkgs/ribbon-installer/files/bin/ribbon-install-probe --only drivers]
check "prints the drivers section" {[llength [dict get $out drivers]] == [llength $det]}
set out [exec tclsh8.6 $repo/srcpkgs/ribbon-installer/files/bin/ribbon-install-probe --only machine]
check "prints the machine section" {[dict get $out machine laptop] == 1}

puts "a base without xbps (the package seam's answers, from a stand-in)"
file delete -force $R/var/db/xbps
::rbpkg::reset
check "keymap on a base without xbps: rc.conf is Void's place and not read (us)" {[::rb::machine::keymap] eq "us"}
put /etc/vconsole.conf "KEYMAP='fr'\n"
check "keymap on a base without xbps: /etc/vconsole.conf" {[::rb::machine::keymap] eq "fr"}
file delete $R/etc/vconsole.conf
set stub $R/stub-pkg.sh
put /stub-pkg.sh {case "$1" in
	map) echo "broadcom-wl broadcom-wl-dkms"; echo "microcode-intel intel-ucode" ;;
	installed) printf 'broadcom-wl-dkms\nsof-firmware\nalsa-ucm-conf\n' ;;
esac
}
set env(RIBBON_PKG) $stub
::rbpkg::reset
set det2 [::hw::detect]
proc e2 {id k} { foreach e $::det2 { if {[dict get $e id] eq $id} { return [::rb::get $e $k] } } }
check "Broadcom wl: installed, by the seam's names" {[e2 wifi0 status] eq "builtin"}
check "SOF: installed; microcode and bolt: to install" {[e2 audio0 status] eq "builtin" && [e2 cpu0 status] eq "install" && [e2 tb0 status] eq "install"}
unset env(RIBBON_PKG)
::rbpkg::reset

puts "answers helpers"
check "keymap as {layout variant}" {[::ans::keymaps {us intl}] eq "us(intl) us-acentos" && [::ans::keymaps {de nodeadkeys}] eq "de(nodeadkeys) de-latin1"}
check "XKB layouts to console keymaps" {[::ans::keymaps gb] eq "gb uk" && [::ans::keymaps us(intl)] eq "us(intl) us-acentos" && [::ans::keymaps de(nodeadkeys)] eq "de(nodeadkeys) de-latin1"}
check "fprint data: 27c6:538d unsupported, 27c6:5840 supported" {[::hw::fprint_status 27c6:538d] eq "unsupported" && [::hw::fprint_status 27c6:5840] eq "supported"}

file delete -force $R
if {!$fail} { puts "installer driver table: all checks passed" }
exit $fail
