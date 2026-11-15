# answers.tcl - check an answers dict (docs/INSTALLER-PROTOCOL.md section 2)
# against this computer and turn it into ribbon-install's command line.
#
#   ::ans::check ANSWERS  ->  {ok PLAN} | {error TEXT}
#
# PLAN holds `args` (ribbon-install options), `manual` (the partition plan
# lines for --manual), and `summary`.

namespace eval ::ans {
    # filesystems for / (the system): only those with snapshots
    variable fslist {btrfs zfs bcachefs}
    # filesystems that can't hold the system, though data and game drives
    # on them are mounted
    variable dataonly {ext4 xfs f2fs}
    variable swaps {zram gaming hibernate custom none}
    # names that must not be the user's login (system accounts)
    variable reserved {root bin daemon sys adm tty disk lp mail news uucp man proxy kmem
        dialout fax voice cdrom floppy tape sudo audio dip www-data backup operator list irc
        src gnats shadow utmp video sasl plugdev staff games users nobody nogroup wheel
        network storage input kvm polkitd _greeter dbus avahi colord sddm lightdm greetd
        rtkit pulse pipewire chrony ntp sshd systemd-journal render optical scanner xbuilder
        _apt ftp http mysql postgres}
    # Flathub IDs and package ids (pkg.sh) for the short names on the Apps page
    variable app_aliases {
        steam {pkg steam}
        heroic {flatpak com.heroicgameslauncher.hgl}
        lutris {pkg lutris}
        discord {flatpak com.discordapp.Discord}
        vesktop {flatpak dev.vencord.Vesktop}
        spotify {flatpak com.spotify.Client}
        obs {pkg obs}
        obs-studio {pkg obs}
        vlc {pkg vlc}
        libreoffice {pkg libreoffice}
        bottles {flatpak com.usebottles.bottles}
        protonup-qt {flatpak net.davidotek.pupgui2}
        moonlight {flatpak com.moonlight_stream.Moonlight}
        sober {flatpak org.vinegarhq.Sober}
        flatseal {flatpak com.github.tchx84.Flatseal}
    }
    # XKB layouts (what the front end offers) -> console keymaps
    variable console_keymaps {
        us us gb uk uk uk de de-latin1 fr fr-latin1 es es it it pl pl2 pt pt-latin1
        br br-abnt2 nl nl se sv-latin1 no no-latin1 dk dk-latin1 fi fi ch fr_CH-latin1
        be be-latin1 cz cz-qwertz hu hu sk sk-qwertz ru ru tr trq ua ua jp jp106
        latam la-latin1 ie uk ca us
        {us(intl)} us-acentos {us(dvorak)} dvorak {gb(dvorak)} dvorak-uk
    }
}

proc ::ans::err {msg} { return -code error -errorcode {RIBBON ANSWERS} $msg }

proc ::ans::fsname {fs} { dict get {ext4 ext4 xfs XFS f2fs F2FS} $fs }

proc ::ans::int {v what {min 0}} {
    if {![string is wide -strict $v] || $v < $min} { err "$what must be a whole number of bytes (got '$v')" }
    return $v
}

proc ::ans::bool {v what} {
    if {$v ni {0 1}} { err "$what must be 0 or 1 (got '$v')" }
    return $v
}

proc ::ans::user_exists {name} {
    foreach f {/etc/passwd /etc/group} {
        foreach line [split [::rb::readall [::rb::rpath $f]] \n] {
            if {[lindex [split $line :] 0] eq $name} { return 1 }
        }
    }
    return 0
}

proc ::ans::check_user {u} {
    variable reserved
    set name [::rb::get $u name]
    set host [::rb::get $u hostname]
    set full [::rb::get $u fullname]
    if {$name eq ""} { err "the user name is missing" }
    if {![regexp {^[a-z_][a-z0-9_-]{0,31}$} $name]} {
        err "the user name '$name' must start with a lower-case letter and use only a-z, 0-9, _ and - (at most 32)"
    }
    if {$name in $reserved || [user_exists $name]} { err "the user name '$name' is used by the system; pick another" }
    if {$host eq ""} { err "the computer name is missing" }
    if {[string length $host] > 63 || ![regexp {^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$} $host]} {
        err "the computer name '$host' may use only letters, digits and - (not first or last), at most 63"
    }
    if {[regexp {[:,=\n\\]} $full] || [string length $full] > 200} { err "the full name can't contain : , = or \\" }
    set pic [::rb::get $u picture]
    if {$pic ne ""} {
        if {![file isfile $pic] || ![file readable $pic]} { err "the account picture $pic can't be read" }
        if {[file size $pic] > 10000000} { err "the account picture is larger than 10 MB" }
        set f [open $pic rb]; set head [read $f 8]; close $f
        if {$head ne "\x89PNG\r\n\x1a\n" && ![string match GIF8* $head]} { err "the account picture must be a PNG or GIF" }
    }
    bool [::rb::get $u autologin 0] "user autologin"
}

proc ::ans::check_locale {loc} {
    if {![regexp {^[A-Za-z]+(_[A-Za-z]+)?(\.[A-Za-z0-9-]+)?(@[A-Za-z]+)?$} $loc]} { err "bad locale '$loc'" }
    # the locales this system's glibc can make (pkg.tcl); none known: not checked
    set known [::rbpkg::locales $::rb::root]
    if {[llength $known] && $loc ni $known} { err "unknown locale '$loc'" }
}

# XKB layout ("gb", {us intl} = layout and variant, "us(intl)") -> {xkb console}
proc ::ans::keymaps {km} {
    variable console_keymaps
    if {[llength $km] == 2} { set km "[lindex $km 0]([lindex $km 1])" }
    if {![regexp {^[A-Za-z0-9_-]+(\([A-Za-z0-9_-]+\))?$} $km]} { err "bad keymap '$km'" }
    if {[dict exists $console_keymaps $km]} { return [list $km [dict get $console_keymaps $km]] }
    set base [regsub {\(.*\)$} $km ""]
    if {[dict exists $console_keymaps $base]} { return [list $km [dict get $console_keymaps $base]] }
    # a console keymap name given directly
    set dir [::rb::rpath /usr/share/kbd/keymaps]
    if {![file isdirectory $dir] || [llength [glob -nocomplain -directory $dir */*/$km.map* */$km.map*]]} {
        return [list $km $km]
    }
    return [list $km us]
}

# Return the free region of a disk that holds [start, start+size), or "".
proc ::ans::in_free {disk start size} {
    foreach f [dict get $disk free] {
        set fs [dict get $f start]
        set fz [dict get $f size]
        if {$start >= $fs && $start + $size <= $fs + $fz} { return $f }
    }
    return ""
}

proc ::ans::check_manual {plan disks efi bootloader encrypt fs_out} {
    variable dataonly
    upvar 1 $fs_out rootfs
    set MiB $::rb::MiB
    set used {}
    set mounts {}
    set newranges {}
    set lines {}
    set root ""
    set esp ""
    set home ""
    if {![llength $plan]} { err "manual partitioning needs a partition plan" }
    if {!$efi} { err "manual partitioning needs a computer started in UEFI mode" }
    # partitions to delete: their space is free for new ones
    set extra {}
    set i 0
    foreach e $plan {
        incr i
        if {[llength $e] % 2} { err "manual entry $i is not a dict" }
        if {![::rb::get $e delete 0]} continue
        set dev [::rb::get $e dev]
        set dp [::rb::disk::find_part $disks $dev]
        if {$dp eq ""} { err "manual entry $i: partition '$dev' not found (or it is on the install media)" }
        lassign $dp disk p
        if {[dict get $p mount] ne ""} { err "$dev is in use (mounted at [dict get $p mount]); unmount it first" }
        if {[dict exists $used $dev]} { err "$dev is used twice in the plan" }
        dict set used $dev 1
        dict lappend extra [dict get $disk dev] [dict create start [dict get $p start] size [dict get $p size]]
        lappend lines [join [list del $dev [dict get $disk dev] [dict get $p start] [dict get $p size] 0 - - 0] \t]
    }
    # free space per disk, counting deleted partitions (merged with neighbours)
    set regions {}
    foreach d $disks {
        set r [lmap x [concat [dict get $d free] [::rb::get $extra [dict get $d dev]]] { list [dict get $x start] [dict get $x size] }]
        set merged {}
        foreach x [lsort -integer -index 0 $r] {
            lassign $x s z
            if {[llength $merged] && $s <= [lindex $merged end 0] + [lindex $merged end 1] + $MiB} {
                lassign [lindex $merged end] ms mz
                lset merged end [list $ms [expr {max($ms + $mz, $s + $z) - $ms}]]
            } else { lappend merged [list $s $z] }
        }
        dict set regions [dict get $d dev] [lmap x $merged { dict create start [lindex $x 0] size [lindex $x 1] }]
    }
    set i 0
    foreach e $plan {
        incr i
        if {[::rb::get $e delete 0]} continue
        set new [::rb::get $e new 0]
        set format [bool [::rb::get $e format 0] "manual entry $i format"]
        set fs [::rb::get $e fs]
        set mount [::rb::get $e mount]
        if {$new} {
            set dd [::rb::get $e disk]
            set disk [::rb::disk::find $disks $dd]
            if {$disk eq ""} { err "manual entry $i: disk '$dd' not found" }
            set start [int [::rb::get $e start] "manual entry $i start"]
            set size [int [::rb::get $e size] "manual entry $i size" 1]
            # align to 1 MiB inside the region
            set s2 [::rb::align_up $start $MiB]
            set z2 [::rb::align_down [expr {$start + $size - $s2}] $MiB]
            if {$z2 < $MiB} { err "manual entry $i: a new partition must be at least 1 MiB" }
            if {[in_free [dict create free [dict get $regions $dd]] $s2 $z2] eq ""} {
                err "manual entry $i: [::rb::human $size] at [::rb::human $start] is not inside free space on $dd"
            }
            foreach r $newranges {
                lassign $r rd rs rz
                if {$rd eq $dd && $s2 < $rs + $rz && $rs < $s2 + $z2} { err "manual entry $i overlaps another new partition" }
            }
            lappend newranges [list $dd $s2 $z2]
            if {!$format} { err "manual entry $i: a new partition must be formatted (format 1)" }
            set dev ""
            set ptype ""
            set psize $z2
            set pfs ""
        } else {
            set dev [::rb::get $e dev]
            set dp [::rb::disk::find_part $disks $dev]
            if {$dp eq ""} { err "manual entry $i: partition '$dev' not found (or it is on the install media)" }
            lassign $dp disk p
            set dd [dict get $disk dev]
            if {[dict get $p mount] ne ""} { err "$dev is in use (mounted at [dict get $p mount]); unmount it first" }
            if {[dict exists $used $dev]} { err "$dev is used twice in the plan" }
            dict set used $dev 1
            set s2 [dict get $p start]
            set z2 [dict get $p size]
            set ptype [dict get $p type]
            set psize $z2
            set pfs [dict get $p fs]
        }
        if {$format} {
            if {$fs ni {btrfs bcachefs vfat swap}} {
                if {$fs eq "zfs"} { err "ZFS installs use the whole disk: pick \"Erase disk\"" }
                if {$fs in $dataonly && $mount eq "/"} { err "manual entry $i: [fsname $fs] can't hold the system (/): it has no snapshots; use btrfs or bcachefs" }
                err "manual entry $i: can't format as '$fs'"
            }
        } else {
            if {$mount ne "" && $pfs eq ""} { err "manual entry $i: $dev has no filesystem to mount; format it" }
            set fs $pfs
        }
        if {$fs eq "swap"} {
            if {$mount ni {"" swap none}} { err "manual entry $i: swap has no mount point" }
            set mount swap
        } elseif {$mount ne ""} {
            if {![regexp {^/([A-Za-z0-9._@+-]+(/[A-Za-z0-9._@+-]+)*)?$} $mount]} { err "manual entry $i: bad mount point '$mount'" }
            if {[dict exists $mounts $mount]} { err "two partitions are mounted at $mount" }
            dict set mounts $mount 1
        }
        set enc 0
        switch -- $mount {
            / {
                if {!$format} { err "/ must be formatted (Ribbon is copied onto a fresh filesystem)" }
                if {$fs ni {btrfs bcachefs}} { err "manual entry $i: / must be btrfs or bcachefs" }
                set root [list $psize $fs]
                set rootfs $fs
                set enc $encrypt
            }
            /home {
                set home $psize
                if {$format && $fs ne "vfat"} { set enc $encrypt }
            }
            /boot - /boot/efi {
                if {$mount eq "/boot/efi" && $bootloader ne "grub"} {
                    err "an EFI partition at /boot/efi needs GRUB; with Limine the EFI partition goes at /boot (it holds the kernels)"
                }
                if {$fs ne "vfat"} { err "the EFI partition ($mount) must be FAT32 (vfat)" }
                if {$format} {
                    if {$psize < $::rb::esp_min} { err "the EFI partition must be at least [::rb::human $::rb::esp_min]" }
                } else {
                    if {$ptype ne "esp"} { err "$dev is not an EFI system partition; format it as FAT32 or pick the EFI partition" }
                    if {[::rb::get $p free 0] < $::rb::esp_need} {
                        err "the EFI partition $dev has [::rb::human [::rb::get $p free 0]] free; Ribbon's kernels need [::rb::human $::rb::esp_need]. Format it, or pick a larger one"
                    }
                }
                set esp [list $mount $dd]
            }
        }
        if {$fs eq "bcachefs" && $mount ne "/"} { err "bcachefs is supported for / only" }
        if {$enc && $fs eq "bcachefs"} { set enc native }
        # line for ribbon-install --manual (tab-separated):
        #   dev-or-"new" disk start size format fs mount encrypt
        lappend lines [join [list [expr {$new ? "new" : $dev}] $dd $s2 $z2 $format [expr {$fs eq "" ? "-" : $fs}] \
            [expr {$mount eq "" ? "-" : $mount}] $enc] \t]
    }
    if {$root eq ""} { err "the plan has no / partition" }
    if {$esp eq ""} { err "the plan has no EFI partition at /boot[expr {$bootloader eq "grub" ? " or /boot/efi" : ""}]" }
    lassign $root rsize rfs
    set need [expr {$home ne "" ? 20 * $::rb::GiB : $::rb::ribbon_min}]
    if {$rsize < $need} { err "/ is [::rb::human $rsize]; it needs at least [::rb::human $need]" }
    return $lines
}

proc ::ans::check {a} {
    try {
        return [check_ $a]
    } trap {RIBBON ANSWERS} msg {
        return [list error $msg]
    }
}

proc ::ans::check_ {a} {
    variable fslist
    variable dataonly
    variable swaps
    variable app_aliases
    if {[catch {dict size $a}]} { err "the answers file is not a Tcl dict" }
    if {[::rb::get $a version] ne "1"} { err "unsupported answers version '[::rb::get $a version]' (expected 1)" }
    set efi [::rb::machine::efi]
    set args {}

    # --- language, keyboard, time
    set locale [::rb::get $a locale en_US.UTF-8]
    check_locale $locale
    lassign [keymaps [::rb::get $a keymap us]] xkb console
    set tz [::rb::get $a timezone UTC]
    if {![::rb::machine::valid_tz $tz]} { err "unknown time zone '$tz'" }
    lappend args --locale $locale --keymap $console --xkb $xkb --timezone $tz

    # --- user
    set u [::rb::get $a user]
    check_user $u
    lappend args --user [dict get $u name] --hostname [dict get $u hostname]
    if {[::rb::get $u fullname] ne ""} { lappend args --fullname [dict get $u fullname] }
    if {[::rb::get $u autologin 0]} { lappend args --autologin }
    if {[::rb::get $u picture] ne ""} { lappend args --picture [dict get $u picture] }

    # --- filesystem, encryption, boot loader
    set fs [::rb::get $a fs btrfs]
    if {$fs in $dataonly} { err "[fsname $fs] can't hold the system: it has no snapshots; use btrfs, zfs or bcachefs" }
    if {$fs ni $fslist} { err "unknown filesystem '$fs'" }
    set encrypt [bool [::rb::get $a encrypt 0] encrypt]
    set bl [::rb::get $a bootloader limine]
    if {$bl ni {limine grub zfsbootmenu}} { err "unknown boot loader '$bl'" }

    # --- disk and mode
    set disks [::rb::disk::probe $efi]
    set media [::rb::disk::media_disks [::rb::disk::lsblk_rows]]
    set mode [::rb::get $a mode]
    if {$mode ni {erase alongside manual}} { err "mode must be erase, alongside or manual (got '$mode')" }
    set dev [::rb::get $a disk]
    set disk ""
    if {$dev ne "" || $mode ne "manual"} {
        if {$dev eq ""} { err "no disk chosen" }
        if {[file tail $dev] in $media} { err "$dev is the install media; pick another disk" }
        set disk [::rb::disk::find $disks $dev]
        if {$disk eq ""} { err "disk $dev not found" }
        foreach p [dict get $disk parts] {
            if {$mode eq "erase" && [dict get $p mount] ne ""} {
                err "[dict get $p dev] on $dev is in use (mounted at [dict get $p mount]); unmount it first"
            }
        }
    }
    set manual {}
    set ribbon_space 0
    switch -- $mode {
        erase {
            set need [expr {$::rb::esp_size + $::rb::ribbon_min}]
            if {[dict get $disk size] < $need} { err "$dev is [::rb::human [dict get $disk size]]; Ribbon needs at least [::rb::human $need]" }
            set ribbon_space [expr {[dict get $disk size] - $::rb::esp_size}]
            lappend args --disk $dev --mode erase
        }
        alongside {
            if {$fs eq "zfs"} { err "ZFS needs a whole disk; pick btrfs or bcachefs to install next to Windows" }
            set al [::rb::get $a alongside]
            set part [::rb::get $al part]
            set keep [int [::rb::get $al keep] "alongside keep" 1]
            set p ""
            foreach q [dict get $disk parts] { if {[dict get $q dev] eq $part} { set p $q } }
            if {$p eq ""} { err "partition '$part' is not on $dev" }
            if {![dict exists $p resize]} { err "$part is not a Windows partition that can be resized" }
            set dal [::rb::get $disk alongside]
            if {$dal eq "" || [dict get $dal part] ne $part} { err "$part is not the Windows partition on $dev" }
            if {![dict get $dal possible]} { err [dict get $dal why] }
            set rz [dict get $p resize]
            set keep [::rb::align_up $keep $::rb::MiB]
            if {$keep < [dict get $rz min]} { err "Windows must keep at least [::rb::human [dict get $rz min]] (asked for [::rb::human $keep])" }
            if {$keep > [dict get $rz max]} { err "Windows can keep at most [::rb::human [dict get $rz max]], so that Ribbon gets [::rb::human $::rb::ribbon_min]" }
            # (max already leaves room for a boot partition of Ribbon's own)
            set ribbon_space [expr {[dict get $rz max] + $::rb::ribbon_min - $keep}]
            lappend args --disk $dev --mode alongside --alongside-part $part --alongside-keep $keep \
                --alongside-boot [::rb::get $dal boot esp]
            if {[dict get $dal esp] ne ""} { lappend args --esp [dict get $dal esp] }
        }
        manual {
            if {$fs eq "zfs"} { err "ZFS installs use the whole disk: pick \"Erase disk\"" }
            set manual [check_manual [::rb::get $a manual] $disks $efi $bl $encrypt fs]
            lappend args --mode manual
            if {$dev ne ""} { lappend args --disk $dev }
            foreach l $manual { if {[lindex [split $l \t] 6] eq "/"} { set ribbon_space [lindex [split $l \t] 3] } }
        }
    }
    # boot loader rules (as ribbon-install enforces them)
    switch -- $fs {
        zfs { if {$bl eq "grub"} { err "ZFS boots with ZFSBootMenu, not GRUB" }; set bl zfsbootmenu }
        bcachefs { if {$bl ne "limine"} { err "bcachefs needs the Limine boot loader" } }
        default { if {$bl eq "zfsbootmenu"} { err "ZFSBootMenu needs ZFS" } }
    }
    if {!$efi && $bl ne "limine"} { err "this computer started in legacy BIOS mode; only Limine supports that" }
    if {!$efi && $mode ne "erase"} { err "this computer started in legacy BIOS mode; only \"Erase disk\" works there" }
    lappend args --fs $fs --bootloader $bl
    if {$encrypt} { lappend args --encrypt }

    # --- swap
    set sw [::rb::get $a swap {mode zram}]
    set smode [::rb::get $sw mode zram]
    if {$smode ni $swaps} { err "unknown swap mode '$smode'" }
    if {$smode eq "custom"} {
        set size [int [::rb::get $sw size] "swap size" 1]
        if {$size < 256 * $::rb::MiB} { err "a swap file must be at least 256 MiB" }
        if {$fs in {zfs bcachefs}} { err "swap files don't work on $fs; pick zram or none" }
        if {$ribbon_space > 0 && $size > $ribbon_space / 2} { err "a [::rb::human $size] swap file would take more than half of Ribbon's space" }
        lappend args --swap custom:$size
    } else {
        lappend args --swap $smode
    }

    # --- drivers
    set plan [::hw::plan [::rb::get $a drivers] [::hw::detect]]
    if {[lindex $plan 0] eq "error"} { err [lindex $plan 1] }
    set gpus [dict get $plan gpu]
    lappend args --gpu [expr {[llength $gpus] ? [join $gpus " "] : "none"}]
    if {[llength [dict get $plan packages]]} { lappend args --drivers [join [dict get $plan packages] " "] }
    if {[llength [dict get $plan services]]} { lappend args --driver-services [join [dict get $plan services] " "] }

    # --- apps (installed at the first start once online, like the Apps page says)
    set pkgs {}
    set flat {}
    foreach app [::rb::get $a apps] {
        set app [string trim $app]
        if {$app eq ""} continue
        if {![regexp {^[A-Za-z0-9][A-Za-z0-9._+-]*$} $app]} { err "bad app name '$app'" }
        if {[dict exists $app_aliases [string tolower $app]]} {
            lassign [dict get $app_aliases [string tolower $app]] kind id
        } elseif {[regexp {^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+){2,}$} $app]} {
            lassign [list flatpak $app] kind id
        } else {
            # any other name: a package of this system's base, as it is
            lassign [list pkg $app] kind id
        }
        if {$kind eq "flatpak"} { if {$id ni $flat} { lappend flat $id } } elseif {$id ni $pkgs} { lappend pkgs $id }
    }
    if {[llength $pkgs]} { lappend args --later-apps [join $pkgs " "] }
    if {[llength $flat]} { lappend args --later-flatpaks [join $flat " "] }

    # --- game drives
    set gdevs {}
    foreach g [::rb::get $a games] {
        set gd [::rb::get $g dev]
        set gn [::rb::get $g name]
        set dp [::rb::disk::find_part $disks $gd]
        if {$dp eq ""} { err "game drive $gd not found" }
        lassign $dp gdisk gp
        if {[dict get $gp fs] eq ""} { err "game drive $gd has no filesystem" }
        if {$mode eq "erase" && [dict get $gdisk dev] eq $dev} { err "game drive $gd is on $dev, which is erased" }
        foreach l $manual { if {$gd in [lrange [split $l \t] 0 1]} { err "game drive $gd is also in the partition plan" } }
        if {$mode eq "alongside" && $gd eq [dict get [dict get $disk alongside] part]} { err "game drive $gd is Windows' partition, which is resized" }
        if {$gn ne "" && ![regexp {^[A-Za-z0-9_-]+$} $gn]} { err "game drive name '$gn' may use only letters, digits, _ and -" }
        if {$gd in $gdevs} { err "game drive $gd is listed twice" }
        lappend gdevs $gd
        lappend args --games-drive [expr {$gn eq "" ? $gd : "$gd:$gn"}]
    }

    # --- Windows elsewhere: a boot menu entry for it (Limine). Next to
    # Windows that is its own EFI partition, unless this disk has none.
    if {$mode ne "alongside" || [dict get $disk alongside esp] eq ""} {
        foreach d $disks {
            if {$mode in {erase alongside} && [dict get $d dev] eq $dev} continue
            foreach p [dict get $d parts] {
                if {[::rb::get $p windows_boot 0] && [dict get $p partuuid] ne ""} {
                    lappend args --windows-esp [dict get $p partuuid]
                    break
                }
            }
            if {"--windows-esp" in $args} break
        }
    }
    return [list ok [dict create args $args manual $manual]]
}
