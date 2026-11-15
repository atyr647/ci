# disks.tcl - disks, partitions, free space, other systems, NTFS resize limits.
# Read-only: partitions are inspected with read-only mounts (no journal
# replay) or, for NTFS, with ntfsprogs, which never write.

namespace eval ::rb::disk {
    variable tmpbase /run/ribbon-probe
    if {[info exists ::env(RIBBON_PROBE_TMP)]} { set tmpbase $::env(RIBBON_PROBE_TMP) }
    variable mcount 0
    variable pending {}      ;# ntfsresize pipelines started, finished in collect
}

# GPT partition type GUIDs and MBR ids -> the protocol's `type`
array set ::rb::disk::gpt_types {
    C12A7328-F81F-11D2-BA4B-00A0C93EC93B esp
    E3C9E316-0B5C-4DB8-817D-F92DF00215AE msr
    DE94BBA4-06D1-4D40-A16A-BFD50179D6AC recovery
    EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 data
    0FC63DAF-8483-4772-8E79-3D69D8477DE4 linux
    4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709 linux
    0657FD6D-A4AB-43C4-84E5-0933C84B4F4F swap
    21686148-6449-6E6F-744E-656564454649 bios
    BC13C2FF-59E6-4262-A352-B275FD6F7172 xbootldr
    E6D6D379-F507-44C2-A23C-238F2A3DF928 lvm
    CA7D7CCB-63ED-4C53-861C-1742536059CC luks
    6A898CC3-1DD2-11B2-99A6-080020736631 zfs
    933AC7E1-2EB4-4F13-B844-0E14E2AEF915 home
    A19D880F-05FC-4D3B-A006-743F0F84911E raid
}
array set ::rb::disk::mbr_types {
    7 data  c data  b data  ef esp  83 linux  82 swap  27 recovery  8e lvm  fd raid  bf zfs
}

proc ::rb::disk::lsblk_rows {} {
    set cols NAME,PATH,TYPE,SIZE,MODEL,TRAN,RM,HOTPLUG,RO,PKNAME,MOUNTPOINT,LOG-SEC
    return [::rb::parse_pairs [::rb::out lsblk -P -b -o $cols]]
}

# Names (kernel names, e.g. sdb) of the disks the live system was started from.
proc ::rb::disk::media_disks {rows} {
    if {[info exists ::env(RIBBON_PROBE_MEDIA)]} {
        set out {}
        foreach d $::env(RIBBON_PROBE_MEDIA) { lappend out [file tail $d] }
        return $out
    }
    set parent {}
    foreach r $rows { dict set parent [dict get $r NAME] [::rb::get $r PKNAME] }
    set devs {}
    # dracut dmsquash-live: root=live:CDLABEL=VOID_LIVE (or LABEL=, UUID=)
    set cmdline [::rb::readfile /proc/cmdline]
    if {[regexp {root=live:(CDLABEL|LABEL|UUID|PARTUUID)=(\S+)} $cmdline -> kind val]} {
        set flag [expr {$kind eq "UUID" ? "-U" : "-L"}]
        if {$kind eq "PARTUUID"} {
            set dev [::rb::out blkid -t PARTUUID=$val -o device]
        } else {
            set dev [::rb::out blkid $flag [string map {\\x20 " "} $val]]
        }
        foreach x [split $dev \n] { if {$x ne ""} { lappend devs [file tail $x] } }
    }
    foreach m {/run/initramfs/live /run/initramfs/isoscan /run/rootfsbase} {
        set src [::rb::out findmnt -no SOURCE $m]
        regsub {\[.*\]$} $src "" src
        if {[string match /dev/* $src]} { lappend devs [file tail $src] }
    }
    set out {}
    foreach d $devs {
        # walk up to the whole disk
        while {[dict exists $parent $d] && [dict get $parent $d] ne ""} { set d [dict get $parent $d] }
        if {$d ni $out} { lappend out $d }
    }
    return $out
}

proc ::rb::disk::is_candidate {r} {
    set name [dict get $r NAME]
    if {[info exists ::env(RIBBON_PROBE_DISKS)]} {
        return [expr {[dict get $r PATH] in $::env(RIBBON_PROBE_DISKS)}]
    }
    if {[dict get $r TYPE] ne "disk"} { return 0 }
    if {[string match zram* $name] || [string match ram* $name]} { return 0 }
    if {[::rb::get $r RO 0] eq "1" || [::rb::get $r SIZE 0] in {"" 0}} { return 0 }
    return 1
}

proc ::rb::disk::bus {r} {
    set t [::rb::get $r TRAN]
    if {$t ne ""} { return $t }
    set n [dict get $r NAME]
    switch -glob -- $n {
        nvme* { return nvme }
        mmcblk* { return mmc }
        vd* { return virtio }
        loop* { return loop }
        md* { return raid }
    }
    return other
}

# sfdisk --dump -> dict {label sector firstlba lastlba parts {{dev start size type uuid name bootable}...}}
proc ::rb::disk::table {dev} {
    lassign [::rb::run sfdisk --dump $dev] code text
    set d [dict create label {} sector 512 firstlba 0 lastlba 0 parts {}]
    if {$code != 0} { return $d }
    foreach line [split $text \n] {
        if {[regexp {^label: (\S+)} $line -> v]} { dict set d label $v }
        if {[regexp {^sector-size: (\d+)} $line -> v]} { dict set d sector $v }
        if {[regexp {^first-lba: (\d+)} $line -> v]} { dict set d firstlba $v }
        if {[regexp {^last-lba: (\d+)} $line -> v]} { dict set d lastlba $v }
        if {[regexp {^(/dev/\S+)\s*:\s*(.*)$} $line -> pdev rest]} {
            set p [dict create dev $pdev start 0 size 0 type {} uuid {} name {}]
            foreach f [split $rest ,] {
                set f [string trim $f]
                if {[regexp {^(\w+)=\s*(.*)$} $f -> k v]} {
                    if {$k eq "name"} { set v [string trim $v \"] }
                    dict set p $k $v
                } elseif {$f eq "bootable"} { dict set p bootable 1 }
            }
            dict lappend d parts $p
        }
    }
    return $d
}

proc ::rb::disk::parttype {table p} {
    set t [string toupper [::rb::get $p type]]
    if {[dict get $table label] eq "gpt"} {
        if {[info exists ::rb::disk::gpt_types($t)]} { return $::rb::disk::gpt_types($t) }
        return other
    }
    set t [string tolower [string trimleft $t 0]]
    if {[info exists ::rb::disk::mbr_types($t)]} { return $::rb::disk::mbr_types($t) }
    if {$t in {5 f 85}} { return extended }
    return other
}

# Free regions (aligned to 1 MiB, at least 1 MiB) -> list of {start S size Z} in bytes
proc ::rb::disk::free_space {table disksize} {
    set ss [dict get $table sector]
    set MiB $::rb::MiB
    if {[dict get $table label] eq "gpt"} {
        set first [expr {[dict get $table firstlba] * $ss}]
        set last [expr {([dict get $table lastlba] + 1) * $ss}]
    } elseif {[dict get $table label] eq "dos"} {
        set first $MiB
        set last $disksize
    } else {
        return [list [dict create start $MiB size [expr {[::rb::align_down $disksize $MiB] - $MiB}]]]
    }
    set used {}
    foreach p [dict get $table parts] {
        # an extended partition holds the logical ones; its own range isn't free
        lappend used [list [expr {[dict get $p start] * $ss}] [expr {([dict get $p start] + [dict get $p size]) * $ss}]]
    }
    set used [lsort -integer -index 0 $used]
    set free {}
    set pos $first
    foreach u [concat $used [list [list $last $last]]] {
        lassign $u s e
        set a [::rb::align_up $pos $MiB]
        set b [::rb::align_down [expr {min($s, $last)}] $MiB]
        if {$b - $a >= $MiB} { lappend free [dict create start $a size [expr {$b - $a}]] }
        if {$e > $pos} { set pos $e }
    }
    return $free
}

# Run a script with the partition mounted read-only at $mnt (or where it is
# already mounted). Returns "" if it can't be mounted.
proc ::rb::disk::with_mount {dev fs mountpoint body} {
    variable tmpbase
    variable mcount
    if {$mountpoint ne ""} {
        uplevel 1 [list set mnt $mountpoint]
        return [uplevel 1 $body]
    }
    switch -- $fs {
        ext4 - ext3 - ext2 { set opts {ro,noload ro} }
        xfs { set opts {ro,norecovery ro} }
        btrfs { set opts {ro,rescue=nologreplay ro,nologreplay ro} }
        f2fs { set opts {ro,norecovery ro} }
        vfat - exfat { set opts {ro} }
        default { return "" }
    }
    set dir [file join $tmpbase "m[pid]-[incr mcount]"]
    file mkdir $dir
    set ok 0
    foreach o $opts {
        if {[lindex [::rb::run mount -t $fs -o $o $dev $dir] 0] == 0} { set ok 1; break }
    }
    if {!$ok} { catch {file delete $dir}; return "" }
    uplevel 1 [list set mnt $dir]
    set rc [catch {uplevel 1 $body} res]
    ::rb::run umount $dir
    catch {file delete $dir}
    if {$rc == 1} { return "" }
    return $res
}

proc ::rb::disk::df {dir} {
    set o [::rb::out df -B1 --output=size,used,avail $dir]
    set l [lindex [split $o \n] end]
    if {[llength $l] == 3 && [string is wide -strict [lindex $l 1]]} { return $l }
    return {}
}

proc ::rb::disk::os_release {dir} {
    foreach f {etc/os-release usr/lib/os-release} {
        set p [file join $dir $f]
        if {[file readable $p]} {
            set name ""
            foreach line [split [::rb::readall $p] \n] {
                if {[regexp {^PRETTY_NAME="?([^"]*)"?} $line -> v]} { return $v }
                if {[regexp {^NAME="?([^"]*)"?} $line -> v]} { set name $v }
            }
            if {$name ne ""} { return $name }
        }
    }
    return ""
}

# --- NTFS --------------------------------------------------------------------

# Windows version from the kernel image's VS_FIXEDFILEINFO (major.minor.build).
proc ::rb::disk::windows_name {dev} {
    if {![::rb::have ntfscat]} { return "" }
    if {[catch {open |[list ntfscat -f $dev /Windows/System32/ntoskrnl.exe 2>/dev/null] rb} f]} { return "" }
    set data [read $f]
    catch {close $f}
    if {[string length $data] < 64} { return "" }
    set i [string first "\xbd\x04\xef\xfe" $data]
    if {$i < 0} { return Windows }
    binary scan [string range $data $i [expr {$i + 15}]] iuiuiuiu sig struc ms ls
    set major [expr {$ms >> 16}]; set minor [expr {$ms & 0xffff}]; set build [expr {$ls >> 16}]
    if {$major == 10 && $build >= 22000} { return "Windows 11" }
    if {$major == 10} { return "Windows 10" }
    switch -- $major.$minor {
        6.3 { return "Windows 8.1" }
        6.2 { return "Windows 8" }
        6.1 { return "Windows 7" }
    }
    return Windows
}

# First bytes of a file on an NTFS volume (or "" if it isn't there).
proc ::rb::disk::ntfs_head {dev path n} {
    if {[catch {open |[list ntfscat -f $dev $path 2>/dev/null] rb} f]} { return "" }
    set data [read $f $n]
    catch {close $f}
    return $data
}

proc ::rb::disk::ntfs_flags {dev} {
    set o [::rb::out ntfsinfo -f -m $dev]
    if {[regexp {Volume Flags:\s*0x([0-9a-fA-F]+)} $o -> hex]} { return [expr {"0x$hex"}] }
    return 0
}

# Fast Startup (HiberbootEnabled) from the SYSTEM registry hive, if hivex is
# installed. Returns 1, 0, or "" (unknown).
proc ::rb::disk::fast_startup {dev} {
    variable tmpbase
    if {![::rb::have hivexget] || ![::rb::have ntfscat]} { return "" }
    file mkdir $tmpbase
    set hive [file join $tmpbase "system-[pid].hive"]
    if {[lindex [::rb::run sh -c {ntfscat -f "$1" /Windows/System32/config/SYSTEM > "$2"} sh $dev $hive] 0] != 0} {
        catch {file delete $hive}
        return ""
    }
    set cur [::rb::out hivexget $hive {\Select} Current]
    set v ""
    if {[regexp {(\d+)} $cur -> n]} {
        set key [format {\ControlSet%03d\Control\Session Manager\Power} $n]
        set o [::rb::out hivexget $hive $key HiberbootEnabled]
        if {[regexp {dword:([0-9a-fA-F]+)} $o -> h]} { set v [expr {"0x$h" != 0}] } \
        elseif {[regexp {^\s*(\d+)\s*$} $o -> d]} { set v [expr {$d != 0}] }
    }
    catch {file delete $hive}
    return $v
}

# Start ntfsresize --info in the background (it reads the whole MFT); the
# result is picked up by ntfs_collect.
proc ::rb::disk::ntfs_start {dev} {
    variable pending
    if {![::rb::have ntfsresize]} { return }
    if {[catch {open |[list ntfsresize --info --force --no-action $dev 2>@1] r} f]} { return }
    dict set pending $dev $f
}

proc ::rb::disk::ntfs_collect {dev} {
    variable pending
    if {![dict exists $pending $dev]} { return [dict create error "ntfsresize is not installed"] }
    set f [dict get $pending $dev]
    dict unset pending $dev
    set out [read $f]
    set err ""
    if {[catch {close $f} e]} { set err $e }
    set r {}
    if {[regexp {Space in use\s*:\s*(\d+) MB} $out -> mb]} { dict set r used [expr {$mb * 1000000}] }
    if {[regexp {You might resize at (\d+) bytes} $out -> b]} {
        dict set r min $b
    } elseif {[regexp {(?:ERROR|error)[^\n]*} $out m]} {
        dict set r error [string trim $m]
    } elseif {$err ne "" || ![dict exists $r min]} {
        set last [lindex [lsearch -all -inline -not [split [string trim $out] \n] {}] end]
        dict set r error [expr {$last ne "" ? $last : "ntfsresize failed"}]
    }
    return $r
}

# The resize dict for a Windows partition: how small Windows can get (with
# room left for it to run and update), how large it can stay (Ribbon needs
# ::rb::ribbon_min next to it, plus `extra` for a boot partition of its own),
# and whether it is safe now.
proc ::rb::disk::resize_info {p free_after {extra 0}} {
    set why {}
    set size [dict get $p size]
    set min 0
    set used [::rb::get $p used 0]
    if {[dict get $p fs] eq "bitlocker"} {
        lappend why "This Windows partition is encrypted with BitLocker, so it can't be resized from Linux.\
            Turn off BitLocker (or Device Encryption) in Windows, or shrink Windows yourself with Disk Management, then restart the installer."
    } else {
        set info [::rb::get $p ntfs]
        if {[::rb::get $info hibernated 0]} {
            lappend why "Windows is hibernated or was shut down with Fast Startup, so resizing it now could lose your Windows files.\
                Start Windows, turn off Fast Startup (Control Panel, Power Options, Choose what the power buttons do), then shut it down fully: hold Shift while you click Shut down."
        } elseif {[::rb::get $info fast_startup 0] == 1} {
            lappend why "Fast Startup is on in Windows: it leaves Windows half-asleep, so resizing it could lose your Windows files.\
                Turn it off in Control Panel, Power Options, Choose what the power buttons do, then shut Windows down."
        }
        if {[::rb::get $info dirty 0]} {
            lappend why "Windows didn't shut down cleanly: the partition is marked for a check.\
                Start Windows and shut it down normally (or run chkdsk /f in Windows), then restart the installer."
        }
        set rz [::rb::get $info resize]
        if {[dict exists $rz error]} {
            lappend why "ntfsresize can't resize this partition: [dict get $rz error]"
        } elseif {[dict exists $rz min]} {
            # Leave Windows room to run and update: 10 GiB or 5% of what it uses.
            set margin [expr {max(10 * $::rb::GiB, [::rb::get $rz used $used] / 20)}]
            set min [::rb::align_up [expr {[dict get $rz min] + $margin}] $::rb::MiB]
            if {$min > $size} { set min $size }
        }
    }
    set need [expr {$::rb::ribbon_min + $extra}]
    set max [::rb::align_down [expr {$size + $free_after - $need}] $::rb::MiB]
    if {$max > $size} { set max $size }
    if {$max < 0} { set max 0 }
    if {[llength $why] == 0 && $max < $min} {
        lappend why "There isn't enough room: Windows needs at least [::rb::human $min] and Ribbon at least [::rb::human $need]."
    }
    set safe [expr {[llength $why] == 0 && $min > 0}]
    if {!$safe && $min == 0 && [llength $why] == 0} { lappend why "The size of Windows' files could not be worked out." }
    return [dict create min $min max $max safe $safe why [join $why " "]]
}

# --- probing -------------------------------------------------------------------

proc ::rb::disk::probe_part {r tp table} {
    set dev [dict get $tp dev]
    set ss [dict get $table sector]
    set number ""
    regexp {(\d+)$} $dev -> number
    set b [::rb::parse_export [::rb::out blkid -p -o export $dev]]
    set fs [string tolower [::rb::get $b TYPE]]
    switch -- $fs {
        crypto_luks { set fs luks }
        zfs_member { set fs zfs }
        ntfs3 { set fs ntfs }
    }
    set p [dict create dev $dev number $number \
        start [expr {[dict get $tp start] * $ss}] size [expr {[dict get $tp size] * $ss}] \
        fs $fs label [::rb::get $b LABEL] uuid [::rb::get $b UUID] \
        type [parttype $table $tp] partlabel [::rb::get $tp name] partuuid [string tolower [::rb::get $tp uuid]] \
        used {} os {} mount [::rb::get $r MOUNTPOINT]]
    set mp [dict get $p mount]
    switch -- $fs {
        vfat {
            set res [with_mount $dev vfat $mp {
                set d [df $mnt]
                list $d [expr {[file exists $mnt/EFI/Microsoft/Boot/bootmgfw.efi] || [file exists $mnt/EFI/Microsoft/Boot/BOOTMGFW.EFI]}]
            }]
            if {$res ne ""} {
                lassign $res d win
                if {$d ne ""} { dict set p used [lindex $d 1]; dict set p free [lindex $d 2] }
                if {$win} { dict set p windows_boot 1 }
            }
        }
        ext4 - ext3 - ext2 - xfs - btrfs - f2fs - exfat {
            set res [with_mount $dev $fs $mp {
                set d [df $mnt]
                set name [os_release $mnt]
                if {$name eq "" && $fs eq "btrfs"} {
                    foreach sv {@ @rootfs root} {
                        set name [os_release $mnt/$sv]
                        if {$name ne ""} break
                    }
                }
                list $d $name
            }]
            if {$res ne ""} {
                lassign $res d name
                if {$d ne ""} { dict set p used [lindex $d 1] }
                if {$name ne ""} { dict set p os [dict create name $name kind linux] }
            }
        }
        ntfs {
            set info {}
            set win [windows_name $dev]
            if {$win ne ""} {
                dict set p os [dict create name $win kind windows]
                set head [string tolower [ntfs_head $dev /hiberfil.sys 4]]
                dict set info hibernated [expr {$head eq "hibr"}]
                dict set info dirty [expr {[ntfs_flags $dev] & 1}]
                set fsu [fast_startup $dev]
                if {$fsu ne ""} { dict set info fast_startup $fsu }
            }
            dict set p ntfs $info
            ntfs_start $dev
        }
        bitlocker {
            dict set p ntfs {}
        }
    }
    return $p
}

# Every disk except the install media, with partitions, free space and the
# systems on it.
proc ::rb::disk::probe {{efi 1}} {
    set rows [lsblk_rows]
    set media [media_disks $rows]
    set disks {}
    foreach r $rows {
        if {![is_candidate $r]} continue
        set name [dict get $r NAME]
        if {$name in $media} continue
        set dev [dict get $r PATH]
        set table [table $dev]
        set size [dict get $r SIZE]
        set model [string trim [::rb::get $r MODEL]]
        if {$model eq ""} { set model [expr {[string match loop* $name] ? "Loop device" : "Disk"}] }
        set rowmap {}
        foreach x $rows { dict set rowmap [dict get $x PATH] $x }
        set parts {}
        foreach tp [dict get $table parts] {
            set pr [::rb::get $rowmap [dict get $tp dev]]
            lappend parts [probe_part $pr $tp $table]
        }
        set free [free_space $table $size]
        lassign [boot_plan $parts] - boot
        set extra [expr {$boot eq "new" ? $::rb::boot_size : 0}]
        # NTFS results (ntfsresize ran in the background meanwhile)
        set out {}
        foreach p $parts {
            if {[dict get $p fs] in {ntfs bitlocker}} {
                set info [dict get $p ntfs]
                if {[dict get $p fs] eq "ntfs"} {
                    set rz [ntfs_collect [dict get $p dev]]
                    dict set info resize $rz
                    if {[dict exists $rz used]} { dict set p used [dict get $rz used] }
                }
                dict set p ntfs $info
                if {[dict get $p os] ne "" || [dict get $p fs] eq "bitlocker"} {
                    set after 0
                    set end [expr {[dict get $p start] + [dict get $p size]}]
                    foreach f $free {
                        set fs [dict get $f start]
                        if {$fs >= $end && $fs - $end <= $::rb::MiB} { set after [expr {$fs + [dict get $f size] - $end}] }
                    }
                    dict set p resize [resize_info $p $after $extra]
                }
                dict unset p ntfs
            }
            lappend out $p
        }
        set parts $out
        set disk [dict create dev $dev model $model size $size bus [bus $r] \
            removable [expr {[::rb::get $r RM 0] eq "1" || [::rb::get $r HOTPLUG 0] eq "1"}] \
            install_media 0 table [expr {[dict get $table label] eq "dos" ? "msdos" : [dict get $table label]}] \
            sector [dict get $table sector] parts $parts free $free]
        dict set disk os [disk_os $parts]
        set al [alongside $disk $efi]
        if {$al ne ""} { dict set disk alongside $al }
        lappend disks $disk
    }
    return $disks
}

proc ::rb::disk::disk_os {parts} {
    set os {}
    set win 0
    foreach p $parts {
        set o [dict get $p os]
        if {$o eq ""} continue
        if {[dict get $o kind] eq "windows"} { set win 1 }
        lappend os [dict create name [dict get $o name] kind [dict get $o kind] part [dict get $p dev]]
    }
    if {!$win} {
        # Windows Boot Manager on the ESP but no readable Windows partition (BitLocker)
        foreach p $parts {
            if {[::rb::get $p windows_boot 0]} {
                set part [dict get $p dev]
                foreach q $parts { if {[dict get $q fs] eq "bitlocker"} { set part [dict get $q dev]; break } }
                lappend os [dict create name Windows kind windows part $part]
                break
            }
        }
    }
    return $os
}

# Where Ribbon's kernels go when it is installed next to Windows:
# {ESP BOOT}. ESP is the disk's EFI system partition (a dict, or "" when the
# disk has none); BOOT is `esp` when it has ::rb::esp_need free (the kernels
# go on it), else `new`: Ribbon makes a boot partition of ::rb::boot_size in
# the space Windows frees, and the EFI partition only gets the boot loader.
proc ::rb::disk::boot_plan {parts} {
    set esp {}
    foreach p $parts {
        if {[dict get $p type] eq "esp" && $esp eq ""} { set esp $p }
    }
    if {$esp ne "" && [::rb::get $esp free 0] >= $::rb::esp_need} { return [list $esp esp] }
    return [list $esp new]
}

# Can Ribbon go next to Windows on this disk? {possible part esp boot why}
proc ::rb::disk::alongside {disk efi} {
    set win {}
    foreach p [dict get $disk parts] {
        if {[dict exists $p resize] && ($win eq "" || [dict get $p size] > [dict get $win size])} { set win $p }
    }
    if {$win eq ""} { return "" }
    lassign [boot_plan [dict get $disk parts]] esp boot
    set why {}
    if {!$efi} {
        lappend why "The installer was started in legacy BIOS mode, and installing next to Windows needs UEFI. Restart and pick the UEFI entry for the install media in the start-up menu."
    }
    if {[dict get $disk table] ne "gpt"} {
        lappend why "This disk has an MBR partition table (legacy BIOS Windows); installing next to Windows needs a GPT disk."
    }
    set rz [dict get $win resize]
    if {![dict get $rz safe]} { lappend why [dict get $rz why] }
    return [dict create possible [expr {[llength $why] == 0}] part [dict get $win dev] \
        esp [expr {$esp eq "" ? "" : [dict get $esp dev]}] boot $boot why [join $why " "]]
}

proc ::rb::disk::find {disks dev} {
    foreach d $disks {
        if {[dict get $d dev] eq $dev} { return $d }
    }
    return ""
}

proc ::rb::disk::find_part {disks dev} {
    foreach d $disks {
        foreach p [dict get $d parts] {
            if {[dict get $p dev] eq $dev} { return [list $d $p] }
        }
    }
    return ""
}
