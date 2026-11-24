# settings-about.tcl - apps/settings/about.tcl with no display: the model read from a fake root (RIBBON_ABOUT_ROOT:
# os-release, /proc, /sys, /etc made here), stand-ins for labwc, df and stat, a small pci.ids, kit's cache file; the
# board's machine first (every value as Settings-A11-About shows it), then one variation at a time, missing and
# damaged files, a command that never answers; and the name changed through a stub pkexec and the real
# ribbon-hostname-helper on the same fake root. Last, the real machine: what the backend says against what the
# system's own tools say.
#   tclsh8.6 -encoding utf-8 tests/settings-about.tcl FILES-DIR
# Prints one line per check; exits 1 if any failed.
set D [file normalize [lindex $argv 0]]
set fails 0
fconfigure stdout -encoding utf-8
proc check {what cond} {
	global fails
	if {[uplevel #0 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}
proc is {what got want} {
	global fails
	if {$got eq $want} { puts "  ok   $what" } else { puts "  FAIL $what: got '$got', want '$want'"; incr fails }
}
proc spit {f t} { file mkdir [file dirname $f]; set fh [open $f wb]; puts -nonewline $fh [encoding convertto utf-8 $t]; close $fh }
proc slurp {f} { if {[catch {open $f rb} fh]} { return "" }; set t [read $fh]; close $fh; set t }
proc script {f body} { spit $f "#!/bin/sh\n$body\n"; file attributes $f -permissions 0755 }

set T [file normalize [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] about-[pid]-[clock milliseconds]]]
file mkdir $T
set R $T/root
set ::env(RIBBON_ABOUT_ROOT) $R
set ::env(XDG_CACHE_HOME) $T/cache
set ::env(HOME) $T/home
catch {unset ::env(WAYLAND_DISPLAY)}
set ::env(RIBBON_ABOUT_PCIIDS) $T/pci.ids
set ::env(RIBBON_ABOUT_LABWC) $T/labwc
set ::env(RIBBON_ABOUT_DF) $T/df
set ::env(RIBBON_ABOUT_STAT) $T/stat

spit $T/pci.ids "# a few lines of pci.ids
1002  Advanced Micro Devices, Inc. \[AMD/ATI\]
\t15bf  Phoenix1
\t1681  Rembrandt \[Radeon 680M\]
\t\t1681 0040  Not this one \[Wrong\]
\t73df  Navi 22 \[Radeon RX 6700/6700 XT/6750 XT / 6800M/6850M XT\]
10de  NVIDIA Corporation
\t2520  GA106M \[GeForce RTX 3060 Mobile / Max-Q\]
1af4  Red Hat, Inc.
\t1050  Virtio 1.0 GPU
8086  Intel Corporation
# a comment inside a vendor
\t9a49  TigerLake-LP GT2 \[Iris Xe Graphics\]
\t15bf  Not AMD's
C 03  Display controller
\t00  VGA compatible controller
"

# ---- the fake machine ------------------------------------------------------------------------------
proc cpuinfo {name n} {
	set t ""
	for {set i 0} {$i < $n} {incr i} {
		append t "processor\t: $i\nvendor_id\t: X\n"
		if {$name ne ""} { append t "model name\t: $name\n" }
		append t "flags\t\t: fpu vme\n\n"
	}
	set t
}
proc card {n ven dev {path ""}} {
	global R
	if {$path eq ""} { set path devices/pci0000:00/0000:00:0$n.0 }
	spit $R/sys/$path/vendor "0x$ven\n"
	spit $R/sys/$path/device "0x$dev\n"
	file mkdir $R/sys/class/drm/card$n $R/sys/class/drm/card$n-eDP-1
	catch {file delete $R/sys/class/drm/card$n/device}
	file link -symbolic $R/sys/class/drm/card$n/device $R/sys/$path
}
# A disk of SECTORS with a partition: /sys/devices/.../NAME/PART, linked from /sys/class/block and /sys/dev/block.
proc disk {name sectors part devno} {
	global R
	set d $R/sys/devices/pci0000:00/nvme/$name
	spit $d/size "$sectors\n"
	spit $d/$part/size "[expr {$sectors - 4096}]\n"
	spit $d/$part/partition "2\n"
	file mkdir $R/sys/class/block $R/sys/dev/block
	foreach {l to} [list $R/sys/class/block/$name $d $R/sys/class/block/$part $d/$part $R/sys/dev/block/$devno $d/$part] {
		catch {file delete $l}
		file link -symbolic $l $to
	}
}
proc mountinfo {dev type src} {
	spit $::R/proc/self/mountinfo "22 27 0:21 / /proc rw,relatime - proc proc rw\n27 1 $dev / / rw,relatime - $type $src rw\n30 27 0:30 / /home/a\\040b rw - tmpfs tmpfs rw\n"
}
proc machine {} {
	global R T
	file delete -force $R $T/cache
	spit $R/etc/os-release "NAME=\"Ribbon OS\"\nID=\"ribbon\"\nPRETTY_NAME=\"Ribbon OS\"\nVERSION_ID=\"0.9\"\nANSI_COLOR=\"1;35\"\n"
	spit $R/proc/sys/kernel/hostname "ribbon\n"
	spit $R/etc/hostname "ribbon\n"
	spit $R/sys/class/dmi/id/sys_vendor "Framework\n"
	spit $R/sys/class/dmi/id/product_name "Laptop 13 (AMD Ryzen 7040Series)\n"
	spit $R/sys/class/dmi/id/product_version "A5\n"
	spit $R/sys/class/dmi/id/bios_version "03.05\n"
	file mkdir $R/sys/firmware/efi
	spit $R/proc/cpuinfo [cpuinfo "AMD Ryzen 7 7840U w/ Radeon  780M Graphics" 16]
	spit $R/proc/meminfo "MemTotal:       31955412 kB\nMemFree:         1000000 kB\n"
	card 1 1002 15bf
	spit $R/proc/sys/kernel/osrelease "6.18.58_1\n"
	disk nvme0n1 1953525168 nvme0n1p2 259:2
	mountinfo 259:2 ext4 /dev/nvme0n1p2
	spit $T/cache/kit/updates "checked 1790000000 notify yes updates {}\n"
	script $T/labwc {echo "labwc 0.20 (+xwayland +nls +rsvg +libsfdo)"}
	# 412 GB free of a filesystem a little smaller than its disk
	script $T/df "echo 'Filesystem     1024-blocks      Used Available Capacity Mounted on'; echo '/dev/nvme0n1p2   960302096 506800000 402343750      56% /'; echo \"\$*\" > '$T/df.args'"
	script $T/stat "echo \"\$*\" > '$T/stat.args'; echo [clock scan {2026-10-12 09:30:00} -format {%Y-%m-%d %H:%M:%S}]"
}
# Forget what was read, read again, and wait for the three commands (or MS).
proc reload {{ms 3000}} {
	foreach {v val} {started 0 pciread 0 pci {} labwc {} birth {} df {} dfat 0 error {} busy 0} { set ::about::$v $val }
	array unset ::about::F
	set ::answers 0
	set ::about::onchange {incr ::answers}
	about::start
	set until [expr {[clock milliseconds] + $ms}]
	while {[array size ::about::buf] && [clock milliseconds] < $until} { after 10 {set ::tick 1}; vwait ::tick }
	about::model
}
proc row {m label} {
	foreach r [concat [dict get $m computer] [dict get $m system]] { if {[lindex $r 0] eq $label} { return [lindex $r 1] } }
	return "(no row)"
}
proc labels {m} { lmap r [concat [dict get $m computer] [dict get $m system]] { lindex $r 0 } }

source -encoding utf-8 $D/apps/settings/about.tcl

# ---- the board's machine ---------------------------------------------------------------------------
machine
set m [reload]
is "the name is os-release's without its OS" [dict get $m name] Ribbon
is "the version is VERSION_ID" [dict get $m version] 0.9
is "the strip's line: the version, and up to date from kit's cache" [dict get $m status] "Version 0.9 · up to date"
is "the subtitle names the system and the model" [dict get $m subtitle] "Ribbon 0.9 on Framework Laptop 13"
is "the rows, in the board's order" [labels $m] {Name Model Processor Memory Graphics Kernel Desktop Disk Firmware Installed}
is "Name: the kernel's host name" [row $m Name] ribbon
is "Model: the maker before a name that lacks it, the closing bracket dropped" [row $m Model] "Framework Laptop 13"
is "Processor: the name as sold, and the threads" [row $m Processor] "AMD Ryzen 7 7840U · 16 threads"
is "Memory: MemTotal lifted to the size sold" [row $m Memory] "32 GB"
is "Graphics: no sold name in pci.ids, so the one the AMD processor's name carries" [row $m Graphics] "Radeon 780M"
is "Kernel: the release's numbers" [row $m Kernel] "Linux 6.18.58"
is "Desktop: labwc's version, Wayland" [row $m Desktop] "labwc 0.20 · Wayland"
is "Disk: the whole disk under /, and what df says is free" [row $m Disk] "1 TB · 412 GB free"
is "Firmware: the version, UEFI" [row $m Firmware] "03.05 · UEFI"
is "Installed: when / was made" [row $m Installed] "12 October 2026"
is "df is asked about the root's /" [string trim [slurp $T/df.args]] "-Pk $R/"
is "stat is asked for the birth of the root's /" [string trim [slurp $T/stat.args]] "-c %W $R/"
check "each command's answer was announced (about::onchange)" {$::answers == 3}
is "Copy details: every row as Key: value" [about::details] "Version: Ribbon 0.9\nName: ribbon\nModel: Framework Laptop 13\nProcessor: AMD Ryzen 7 7840U · 16 threads\nMemory: 32 GB\nGraphics: Radeon 780M\nKernel: Linux 6.18.58\nDesktop: labwc 0.20 · Wayland\nDisk: 1 TB · 412 GB free\nFirmware: 03.05 · UEFI\nInstalled: 12 October 2026"
check "the model's busy is 0 at rest" {[dict get $m busy] == 0}

# ---- updates ---------------------------------------------------------------------------------------
spit $T/cache/kit/updates "checked 1790000000 notify no updates {{name a} {name b} {name c} {name d} {name e}}\n"
is "five waiting (whatever the bar may show)" [dict get [about::model] status] "Version 0.9 · 5 updates"
spit $T/cache/kit/updates "checked 1790000000 notify yes updates {{name a}}\n"
is "one waiting" [dict get [about::model] status] "Version 0.9 · 1 update"
spit $T/cache/kit/updates "this is \{ not a dict"
is "a damaged cache file says nothing about updates" [dict get [about::model] status] "Version 0.9"
file delete $T/cache/kit/updates
is "no cache file: the version alone" [dict get [about::model] status] "Version 0.9"
is "  and updates is unknown, not 0" [dict get [about::model] updates] ""

# ---- os-release ------------------------------------------------------------------------------------
spit $R/etc/os-release "# comment\nNAME=Void\nVERSION_ID='24.1'\nPRETTY_NAME=\"Void \\\"Linux\\\"\"\n"
set m [about::model]
is "unquoted and single-quoted values" [list [dict get $m name] [dict get $m version]] {Void 24.1}
spit $R/etc/os-release "PRETTY_NAME=\"Some \\\"Linux\\\" OS\"\n"
is "PRETTY_NAME when there is no NAME; no version" [list [dict get [about::model] name] [dict get [about::model] status]] [list {Some "Linux"} {}]
file delete $R/etc/os-release
spit $R/usr/lib/os-release "NAME=\"Ribbon OS\"\nVERSION_ID=1.0\n"
is "/usr/lib/os-release when /etc has none" [dict get [about::model] subtitle] "Ribbon 1.0 on Framework Laptop 13"
file delete $R/usr/lib/os-release
is "no os-release at all: Ribbon, no version" [list [dict get [about::model] name] [dict get [about::model] version] [dict get [about::model] subtitle]] [list Ribbon {} {Ribbon on Framework Laptop 13}]

# ---- the name --------------------------------------------------------------------------------------
machine
file delete $R/proc/sys/kernel/hostname
spit $R/etc/hostname "saved-name\nsecond line\n"
is "the saved name when the kernel's cannot be read" [dict get [about::model] hostname] saved-name
file delete $R/etc/hostname
set m [about::model]
is "no name known: no Name row" [list [dict get $m hostname] [lindex [labels $m] 0]] {{} Model}
foreach {n ok} {ribbon 1 a 1 A-b-9 1 9lives 1 {} 0 -a 0 a- 0 a_b 0 a.b 0 {a b} 0 é 0 "a\nb" 0} { check "valid_name '[string map [list \n {\n}] $n]' is $ok" {[about::valid_name $n] == $ok} }
check "a name of 63 is one, of 64 is not" {[about::valid_name [string repeat a 63]] && ![about::valid_name [string repeat a 64]]}

# ---- the model -------------------------------------------------------------------------------------
proc dmi {vendor name {version ""}} {
	foreach {k v} [list sys_vendor $vendor product_name $name product_version $version] { spit $::R/sys/class/dmi/id/$k "$v\n" }
	set m [reload]
	list [row $m Model] [dict get $m subtitle]
}
machine
is "a placeholder is no model: no row, and the subtitle is the system alone" [dmi "To Be Filled By O.E.M." "To Be Filled By O.E.M."] {{(no row)} {Ribbon 0.9}}
is "  (System Product Name, Default string)" [dmi "System manufacturer" "System Product Name" "Default string"] {{(no row)} {Ribbon 0.9}}
is "Dell Inc. is Dell" [lindex [dmi "Dell Inc." "XPS 13 9310"] 0] "Dell XPS 13 9310"
is "a name that carries its maker is left alone" [lindex [dmi "HP" "HP EliteBook 840 G8 Notebook PC"] 0] "HP EliteBook 840 G8 Notebook PC"
is "Lenovo's name is its version" [lindex [dmi "LENOVO" "20XW0026US" "ThinkPad X1 Carbon Gen 9"] 0] "Lenovo ThinkPad X1 Carbon Gen 9"
is "ASUSTeK COMPUTER INC. is ASUS" [lindex [dmi "ASUSTeK COMPUTER INC." "Zenbook UX3402ZA"] 0] "ASUS Zenbook UX3402ZA"
is "a maker not known by a short name loses its Inc." [lindex [dmi "Star Labs, Inc." "StarBook"] 0] "Star Labs StarBook"
is "a model with no maker" [lindex [dmi "Default string" "NUC11PAHi5"] 0] "NUC11PAHi5"
file delete -force $R/sys/class/dmi
spit $R/sys/firmware/devicetree/base/model "Raspberry Pi 4 Model B Rev 1.4\0"
set m [reload]
is "no DMI: the device tree's model" [row $m Model] "Raspberry Pi 4 Model B Rev 1.4"
is "  and no firmware version: UEFI alone when the system started that way" [row $m Firmware] UEFI
file delete -force $R/sys/firmware
set m [reload]
is "no DMI, no device tree, no EFI: no Model and no Firmware row" [list [row $m Model] [row $m Firmware]] {{(no row)} {(no row)}}

# ---- the processor and the memory ------------------------------------------------------------------
foreach {raw want} {
	{Intel(R) Core(TM) i7-8565U CPU @ 1.80GHz} {Intel Core i7-8565U}
	{12th Gen Intel(R) Core(TM) i5-1240P} {Intel Core i5-1240P}
	{AMD Ryzen 5 5600X 6-Core Processor} {AMD Ryzen 5 5600X}
	{AMD Ryzen 7 5700G with Radeon Graphics} {AMD Ryzen 7 5700G}
	{Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz} {Intel Xeon E5-2680 v4}
	{Intel(R) Core(TM)2 Duo CPU     T7500  @ 2.20GHz} {Intel Core2 Duo T7500}
	{Intel(R) N100} {Intel N100}
	{QEMU Virtual CPU version 2.5+} {QEMU Virtual CPU version 2.5+}
} { is "processor '$raw'" [about::cpu_name $raw] $want }
machine
spit $R/proc/cpuinfo [cpuinfo "Intel(R) Core(TM) i7-1165G7 @ 2.80GHz" 1]
is "one thread is a thread" [row [reload] Processor] "Intel Core i7-1165G7 · 1 thread"
spit $R/proc/cpuinfo [cpuinfo "" 8]
is "no model name (ARM): the threads alone" [row [reload] Processor] "8 threads"
spit $R/proc/cpuinfo [string map [list "flags\t\t" "model name\t: \nstepping\t: 2\nflags\t\t"] [cpuinfo "" 8]]
is "an empty model name (some hypervisors): the threads alone, not the next line" [row [reload] Processor] "8 threads"
spit $R/proc/cpuinfo [binary format a* [string repeat "\x00\xff\x01garbage\n" 400]]
set m [reload]
is "a cpuinfo that is not one: no Processor row" [row $m Processor] "(no row)"
foreach {kb want} {31955412 {32 GB} 16473776 {16 GB} 7900000 {8 GB} 3800000 {4 GB} 1000000 {1 GB} 500000 {512 MB} 65700000 {64 GB}
	23900000 {24 GB} 131000000 {128 GB} 263000000 {256 GB} 5900000 {6 GB} 0 {} junk {}} { is "memory of $kb kB" [about::memory_of $kb] $want }
spit $R/proc/meminfo "nothing here\n"
is "a meminfo without MemTotal: no Memory row" [row [reload] Memory] "(no row)"

# ---- graphics --------------------------------------------------------------------------------------
machine
file delete -force $R/sys/class/drm $R/sys/devices
card 0 8086 9a49
card 1 10de 2520
is "two cards, in order, joined; Intel's is said with Intel" [row [reload] Graphics] "Intel Iris Xe Graphics · GeForce RTX 3060 Mobile / Max-Q"
file delete -force $R/sys/class/drm $R/sys/devices
card 0 1002 1681
is "the name in brackets (the device's line, not a subsystem's)" [row [reload] Graphics] "Radeon 680M"
card 0 1002 abcd
is "a device pci.ids does not know: its maker" [row [reload] Graphics] AMD
card 0 1af4 1050
is "no name in brackets: the maker and the device" [row [reload] Graphics] "Red Hat Virtio 1.0 GPU"
card 0 8086 15bf
is "an id is looked up under its own vendor only" [row [reload] Graphics] "Intel Not AMD's"
card 0 ffee 0001
is "a maker pci.ids does not know: no Graphics row" [row [reload] Graphics] "(no row)"
card 0 1002 1681
spit $R/sys/devices/pci0000:00/0000:00:00.0/vendor "rubbish\n"
is "a vendor file that is not an id: no row" [row [reload] Graphics] "(no row)"
card 0 1002 1681
set ::env(RIBBON_ABOUT_PCIIDS) $T/none
is "no pci.ids: no Graphics row" [row [reload] Graphics] "(no row)"
set ::env(RIBBON_ABOUT_PCIIDS) $T/pci.ids
file delete -force $R/sys/class/drm
is "no cards: no Graphics row" [row [reload] Graphics] "(no row)"

# ---- the kernel, the desktop -----------------------------------------------------------------------
machine
foreach {rel want} {6.18.58_1 {Linux 6.18.58} 6.6.52-0-lts {Linux 6.6.52} 6.12 {Linux 6.12} next-20260101 {Linux next-20260101}} {
	spit $R/proc/sys/kernel/osrelease "$rel\n"
	is "kernel $rel" [row [reload] Kernel] $want
}
file delete $R/proc/sys/kernel/osrelease
is "no osrelease: no Kernel row" [row [reload] Kernel] "(no row)"
script $T/labwc {echo "labwc 0.8.4 (+xwayland)"; echo more}
is "labwc's version from its first numbers" [row [reload] Desktop] "labwc 0.8.4 · Wayland"
script $T/labwc {exit 1}
is "labwc fails: no Desktop row" [row [reload] Desktop] "(no row)"
set ::env(WAYLAND_DISPLAY) wayland-0
is "  but a Wayland session still says so" [row [reload] Desktop] Wayland
unset ::env(WAYLAND_DISPLAY)
set ::env(RIBBON_ABOUT_LABWC) $T/not-there
is "labwc is not installed: no Desktop row" [row [reload] Desktop] "(no row)"
set ::env(RIBBON_ABOUT_LABWC) $T/labwc
script $T/labwc {sleep 20; echo "labwc 9.9"}
set ::about::timeout 300
set t0 [clock milliseconds]
set m [reload 4000]
check "a labwc that never answers is given up on, and nothing waits for it" {[row $m Desktop] eq "(no row)" && [clock milliseconds] - $t0 < 3000}
is "  the other rows are there" [row $m Disk] "1 TB · 412 GB free"
set ::about::timeout 5000

# ---- the disk --------------------------------------------------------------------------------------
foreach {bytes want} {1000204886016 {1 TB} 2000398934016 {2 TB} 1500301910016 {1.5 TB} 512110190592 {512 GB} 256060514304 {256 GB}
	412000000000 {412 GB} 7440000000 {7.4 GB} 9990000000 {10 GB} 999600000 {1 GB} 512000000 {512 MB} 0 {0 MB}} { is "size of $bytes" [about::size $bytes] $want }
machine
# encrypted: / on dm-0, which sits on a partition of the disk
set dm $R/sys/devices/virtual/block/dm-0
spit $dm/size "1953400000\n"; spit $dm/dm/name "luks-root\n"
file mkdir $dm/slaves
file link -symbolic $dm/slaves/nvme0n1p2 $R/sys/devices/pci0000:00/nvme/nvme0n1/nvme0n1p2
file link -symbolic $R/sys/dev/block/254:0 $dm
file link -symbolic $R/sys/class/block/dm-0 $dm
mountinfo 254:0 ext4 /dev/mapper/luks-root
is "an encrypted root: through device-mapper to the whole disk" [row [reload] Disk] "1 TB · 412 GB free"
mountinfo 0:25 btrfs /dev/mapper/luks-root
is "btrfs on it (a device number of its own): by the mapper's name" [row [reload] Disk] "1 TB · 412 GB free"
mountinfo 0:25 btrfs /dev/nvme0n1p2
is "btrfs on a partition: by the source's name" [row [reload] Disk] "1 TB · 412 GB free"
mountinfo 0:30 tmpfs tmpfs
is "/ on no disk: the filesystem's size from df" [row [reload] Disk] "983 GB · 412 GB free"
mountinfo 259:2 ext4 /dev/nvme0n1p2
script $T/df {exit 1}
is "df fails: the disk alone" [row [reload] Disk] "1 TB"
script $T/df {echo "Filesystem 1024-blocks Used Available Capacity Mounted on"; echo "rubbish"}
is "df says something else: the disk alone" [row [reload] Disk] "1 TB"
mountinfo 0:30 tmpfs tmpfs
is "nothing known: no Disk row" [row [reload] Disk] "(no row)"
machine
set m [reload]
script $T/df "echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'; echo '/dev/nvme0n1p2 960302096 606800000 302343750 67% /'"
about::refresh
after 200 {set ::tick 1}; vwait ::tick
is "a refresh within 15 s does not ask df again" [row [about::model] Disk] "1 TB · 412 GB free"
set ::about::dfat [expr {[clock seconds] - 16}]
set ::answers 0
about::refresh
set until [expr {[clock milliseconds] + 3000}]
while {[array size ::about::buf] && [clock milliseconds] < $until} { after 10 {set ::tick 1}; vwait ::tick }
is "a later refresh does, and the free space follows" [row [about::model] Disk] "1 TB · 310 GB free"
check "  and the change was announced once" {$::answers == 1}

# ---- firmware, installed ---------------------------------------------------------------------------
machine
file delete -force $R/sys/firmware/efi
is "no /sys/firmware/efi: BIOS" [row [reload] Firmware] "03.05 · BIOS"
spit $R/sys/class/dmi/id/bios_version "Default string\n"
is "a placeholder version and no EFI: no Firmware row" [row [reload] Firmware] "(no row)"
machine
script $T/stat {echo 0}
set old [clock scan {2025-03-04 12:00:00} -format {%Y-%m-%d %H:%M:%S}]
set new [clock scan {2026-01-02 12:00:00} -format {%Y-%m-%d %H:%M:%S}]
spit $R/etc/machine-id "0123\n"; file mtime $R/etc/machine-id $new
file mkdir $R/lost+found; file mtime $R/lost+found $old
is "no birth time: the older of machine-id and lost+found" [row [reload] Installed] "4 March 2025"
file delete -force $R/lost+found
is "  machine-id alone" [row [reload] Installed] "2 January 2026"
file mtime $R/etc/machine-id 86400
is "  a date from 1970 is not one: no Installed row" [row [reload] Installed] "(no row)"
script $T/stat "echo [expr {[clock seconds] + 10 * 86400}]"
is "a birth in the future is not believed" [row [reload] Installed] "(no row)"
script $T/stat {echo "-"}
is "a stat that knows no birth: no row" [row [reload] Installed] "(no row)"
set ::env(RIBBON_ABOUT_STAT) $T/not-there
file mtime $R/etc/machine-id $new
is "no stat: machine-id" [row [reload] Installed] "2 January 2026"
set ::env(RIBBON_ABOUT_STAT) $T/stat

# ---- nothing at all --------------------------------------------------------------------------------
file delete -force $R $T/cache
file mkdir $R
foreach v {RIBBON_ABOUT_LABWC RIBBON_ABOUT_DF RIBBON_ABOUT_STAT} { set ::env($v) $T/not-there }
set m [reload]
is "an empty root, no tools: the model still comes, with Ribbon's name and no rows" [list [dict get $m name] [dict get $m status] [dict get $m subtitle] [labels $m]] {Ribbon {} Ribbon {}}
is "  and Copy details is the one line" [about::details] "Version: Ribbon"
foreach v {RIBBON_ABOUT_LABWC RIBBON_ABOUT_DF RIBBON_ABOUT_STAT} { set ::env($v) $T/[string tolower [string range $v 13 end]] }

# ---- the name, through pkexec and the helper -------------------------------------------------------
set helper $D/apps/settings/bin/ribbon-hostname-helper
machine
spit $R/etc/hosts "127.0.0.1\tlocalhost\n127.0.1.1\tribbon\n"
set m [reload]
# a pkexec that runs what it is given (the helper, told to work on the fake root), or refuses
script $T/pkexec "echo \"\$*\" >> '$T/pkexec.log'; case \${PKEXEC_SAYS:-run} in run) RIBBON_HOSTNAME_TEST=1 RIBBON_HOSTNAME_ROOT='$R' exec sh \"\$@\" ;; cancel) echo 'Error executing command as another user: Request dismissed' >&2; exit 126 ;; deny) echo 'Error executing command as another user: Not authorized' >&2; exit 127 ;; slow) sleep 1; exit 126 ;; esac"
proc set_name {name} {
	set ::answers 0
	about::set_name $name
	set until [expr {[clock milliseconds] + 5000}]
	while {$::about::busy && [clock milliseconds] < $until} { after 10 {set ::tick 1}; vwait ::tick }
	list [dict get [about::model] hostname] $::about::error
}
is "without RIBBON_ABOUT_TEST the stand-ins are not read: pkexec and the installed helper" [about::helper_cmd] {pkexec /usr/bin/ribbon-hostname-helper}
set ::env(RIBBON_ABOUT_TEST) 1
set ::env(RIBBON_ABOUT_PKEXEC) $T/pkexec
set ::env(RIBBON_ABOUT_HELPER) $helper
is "a new name: asked through pkexec, and the model then has it" [set_name studio-2] {studio-2 {}}
is "  pkexec was given the helper, set and the name" [string trim [slurp $T/pkexec.log]] "$helper set studio-2"
is "  /etc/hostname has it" [slurp $R/etc/hostname] "studio-2\n"
is "  /etc/hosts' 127.0.1.1 line has it" [slurp $R/etc/hosts] "127.0.0.1\tlocalhost\n127.0.1.1\tstudio-2\n"
check "  the change was announced" {$::answers >= 1}
file delete $T/pkexec.log
set ::env(PKEXEC_SAYS) cancel
is "a dismissed prompt: Cancelled, and the name is as it was" [set_name other] {studio-2 Cancelled}
is "  nothing was written" [slurp $R/etc/hostname] "studio-2\n"
set ::env(PKEXEC_SAYS) deny
is "a failed authentication: Not authorised" [set_name other] {studio-2 {Not authorised}}
set ::env(PKEXEC_SAYS) run
file delete $T/pkexec.log
is "a name that cannot be one is not sent" [set_name "bad name"] {studio-2 {Not a computer's name}}
check "  pkexec was not run" {![file exists $T/pkexec.log]}
file attributes $R/etc -permissions 0777
is "the helper's own refusal is the error, in its words" [set_name other] [list studio-2 [string range "$R/etc is not root's alone; not writing there" 0 69]]
file attributes $R/etc -permissions 0755
set ::env(RIBBON_ABOUT_PKEXEC) $T/not-there
is "no pkexec: said so, name as it was" [set_name other] {studio-2 {pkexec is not installed}}
set ::env(RIBBON_ABOUT_PKEXEC) $T/pkexec
set ::env(PKEXEC_SAYS) slow
file delete $T/pkexec.log
about::set_name first
check "while one change is being made the model says busy" {[dict get [about::model] busy] == 1}
about::set_name second
set until [expr {[clock milliseconds] + 5000}]
while {$::about::busy && [clock milliseconds] < $until} { after 10 {set ::tick 1}; vwait ::tick }
is "  and a second one is not started" [string trim [slurp $T/pkexec.log]] "$helper set first"
unset ::env(PKEXEC_SAYS) ::env(RIBBON_ABOUT_TEST)

# ---- the real machine ------------------------------------------------------------------------------
unset ::env(RIBBON_ABOUT_ROOT) ::env(RIBBON_ABOUT_PCIIDS) ::env(RIBBON_ABOUT_LABWC) ::env(RIBBON_ABOUT_DF) ::env(RIBBON_ABOUT_STAT)
set m [reload 8000]
check "the real machine: the model comes ([llength [labels $m]] rows: [join [labels $m] {, }])" {[dict get $m name] ne ""}
if {![catch {exec uname -r} rel] && [regexp {^\d+(\.\d+)*} $rel v]} { is "  Kernel is uname -r's numbers" [row $m Kernel] "Linux $v" }
if {![catch {exec uname -n} node]} { is "  Name is uname -n" [row $m Name] [string trim $node] }
if {![catch {exec nproc --all} n] || ![catch {exec getconf _NPROCESSORS_CONF} n]} {
	check "  Processor ends with the processors there are ($n): [row $m Processor]" {[string match "*$n thread*" [row $m Processor]]}
}
if {![catch {exec labwc --version 2>@1} out] && [regexp {(\d+(?:\.\d+)+)} $out -> v]} {
	is "  Desktop is the real labwc's version" [row $m Desktop] "labwc $v · Wayland"
} else { puts "  skip the real labwc (not installed)" }
if {![catch {exec df -Pk /} out] && [regexp {\s(\d+)\s+(\d+)\s+(\d+)\s+\d+%\s} [lindex [split [string trim $out] \n] end] -> total used avail]} {
	set free ""
	regexp {([0-9.]+) (GB|MB|TB) free} [row $m Disk] -> free unit
	set real [expr {$avail * 1024.0 / [dict get {MB 1e6 GB 1e9 TB 1e12} $unit]}]
	check "  Disk's free space is the real df's ([row $m Disk]; df: [format %.1f $real] $unit)" {$free ne "" && abs($free - $real) <= max(1.0, $real * 0.05)}
} else { puts "  skip the real df" }
if {![catch {exec stat -c %W /} b] && [string is integer -strict $b] && $b > 978307200} {
	is "  Installed is the real birth of /" [row $m Installed] [string trim [clock format $b -format {%e %B %Y} -locale en]]
} else { puts "  skip the real birth time (this filesystem keeps none)" }
foreach f {/usr/share/hwdata/pci.ids /usr/share/misc/pci.ids} {
	if {![file readable $f]} continue
	is "  the real pci.ids ($f): 1002:1681 is Radeon 680M" [about::gpu_name 1002 1681 ""] "Radeon 680M"
	check "  and 10de:2520 is a GeForce ([about::gpu_name 10de 2520 {}])" {[string match "GeForce*" [about::gpu_name 10de 2520 ""]]}
	break
}

file delete -force $T
if {$fails} { puts "about: $fails failed"; exit 1 }
puts "about: all checks passed"
