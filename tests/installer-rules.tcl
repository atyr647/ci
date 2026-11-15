# installer-rules.tcl - what the Tk installer offers on computers and disks
# the backend would refuse at Summary (docs/INSTALLER-PROTOCOL.md 1-2):
# legacy BIOS (machine.efi 0), an MBR disk (alongside.why), ZFS away from
# "Erase disk", swap files on ZFS and bcachefs, and the Hardware page's
# swap and boot loader copy (RIBBON_INSTALLER_SCENE=this file, under xvfb).
# Exits 0 when every check passes.
set here [file dirname [file normalize [info script]]]
set ::env(RIBBON_INSTALLER_FAKE) [file join $here installer-fake-backend.sh]
proc bgerror {msg} { puts stderr "$msg\n$::errorInfo"; exit 1 }
set ::fails 0
proc check {what cond} {
	if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what"; incr ::fails }
}
# every string the page draws
rename ui::text ui::text_drawn
proc ui::text {x top str args} { lappend ::drawn $str; ui::text_drawn $x $top $str {*}$args }
proc show {p} { set ::drawn {}; page::go $p; update; return [join $::drawn " "] }
proc focus_ids {pat} { lsearch -all -inline [lmap f $ui::focusables { lindex $f 0 }] $pat }
proc go_on {} { page::next; update; return $page::S(page) }

set base [exec {*}[backend::cmd probe]]
set nv /dev/nvme0n1
# the probe with changes: machine KEY VALUE ... and disk0 KEY VALUE ...
proc variant {machine disk0} {
	set p $::base
	set m [dict get $p machine]
	foreach {k v} $machine { dict set m $k $v }
	dict set p machine $m
	set ds [dict get $p disks]
	set d [lindex $ds 0]
	foreach {k v} $disk0 { dict set d $k $v }
	lset ds 0 $d
	dict set p disks $ds
	page::init
	page::probed $p
	ui::fset fullname "Alex Tyrone"; page::derive_user
	foreach f {upass1 upass2} { ui::fset $f pw }
	set page::S(encrypt) 0
}
proc on_disk {mode} { set page::S(mode) $mode; show disk; set page::S(mode) $mode; return [show disk] }

puts "the mockups' computer (UEFI, GPT, Windows shut down)"
variant {} {}
set t [show disk]
check "three ways to install" {[focus_ids mode-*] eq {mode-erase mode-alongside mode-manual}}
foreach m {erase alongside manual} {
	on_disk $m
	check "$m: nothing stops it" {[page::mode_problem] eq "" && [page::problem] eq ""}
}
set page::S(mode) erase; show setup
check "erase: Btrfs, ZFS and bcachefs cards" {[focus_ids fs-*] eq {fs-btrfs fs-zfs fs-bcachefs}}
set t [show hardware]
check "swap: zram, Gaming, Hibernate, Custom, None" {[lmap {k l} [page::swap_opts] { set l }] eq {zram Gaming Hibernate Custom None}}
check "boot loader: Limine and GRUB" {[page::boot_opts] eq {limine Limine grub GRUB}}
check "the boot loader note promises nothing about Secure Boot" {[string match "*Limine is fast and simple. GRUB finds other systems itself.*" $t] && ![string match "*Secure Boot*" $t]}

puts "legacy BIOS (machine efi 0)"
variant {efi 0} [list alongside [list possible 0 part ${nv}p3 esp ${nv}p1 boot esp \
	why "The installer was started in legacy BIOS mode, and installing next to Windows needs UEFI. Restart and pick the UEFI entry for the install media in the start-up menu."]]
set t [on_disk alongside]
check "alongside: the probe's reason under the cards" {[string match "*legacy BIOS mode, and installing*" $t]}
check "alongside: Continue stays on the disk page" {[go_on] eq "disk"}
set t [on_disk manual]
check "manual: refused with the reason" {[string match "*legacy BIOS mode; only \"Erase disk\" works there.*" $t] && [go_on] eq "disk"}
set t [on_disk erase]
check "erase: no reason shown, Continue goes on" {![string match "*legacy BIOS*" $t] && [go_on] eq "setup"}
# ZFS boots with ZFSBootMenu, an EFI program (answers.tcl: "only Limine supports that")
page::set_fs zfs
show setup
check "erase: no ZFS card; ZFS fell back to Btrfs and Limine" {[focus_ids fs-*] eq {fs-btrfs fs-bcachefs} && $page::S(fs) eq "btrfs" && $page::S(boot) eq "limine"}
set page::S(boot) grub
set t [show hardware]
check "boot loader: Limine only (GRUB fell back to it)" {[page::boot_opts] eq {limine Limine} && $page::S(boot) eq "limine"}
check "its note names no boot loader that isn't offered" {[string match "*Limine is fast and simple.*" $t] && ![string match "*GRUB*" $t]}
check "answers: limine, erase" {[dict get [page::answers] bootloader] eq "limine" && [dict get [page::answers] mode] eq "erase"}

puts "an MBR disk with Windows (table dos)"
variant {} [list table dos alongside [list possible 0 part ${nv}p3 esp ${nv}p1 boot esp \
	why "This disk has an MBR partition table (legacy BIOS Windows); installing next to Windows needs a GPT disk."]]
set t [on_disk alongside]
check "alongside: refused with the probe's reason" {[string match "*MBR partition table*" $t] && [go_on] eq "disk"}
on_disk manual
check "manual: allowed (UEFI)" {[go_on] eq "manual"}

puts "Windows not shut down fully (the Alongside page's business)"
variant {} [list alongside [list possible 0 part ${nv}p3 esp ${nv}p1 boot esp why "Windows is hibernated."]]
set t [on_disk alongside]
check "alongside: the disk page lets it through to its own page" {![string match "*hibernated*" $t] && [go_on] eq "alongside"}

puts "ZFS only when Ribbon gets the whole disk"
variant {} {}
set page::S(mode) erase
page::set_fs zfs
check "erase: ZFS with ZFSBootMenu" {$page::S(fs) eq "zfs" && $page::S(boot) eq "zfsbootmenu"}
foreach m {alongside manual} {
	set page::S(mode) erase; page::set_fs zfs
	set page::S(mode) $m
	show setup
	check "$m: no ZFS card; ZFS fell back to Btrfs and Limine" {[focus_ids fs-*] eq {fs-btrfs fs-bcachefs} && $page::S(fs) eq "btrfs" && $page::S(boot) eq "limine"}
	check "$m: answers say btrfs" {[dict get [page::answers] fs] eq "btrfs"}
}

puts "swap"
variant {} {}
set page::S(mode) erase
foreach fs {zfs bcachefs} {
	page::set_fs $fs
	set page::S(swap) hibernate
	set t [show hardware]
	check "$fs: no Hibernate or Custom (no swap file there)" {[lmap {k l} [page::swap_opts] { set k }] eq {zram gaming none} && $page::S(swap) eq "zram"}
	page::set_swap gaming
	set t [show hardware]
	check "$fs: Gaming says what it does (zram only)" {[string match "*Compressed swap in memory (100% of RAM),*" $t] && ![string match "*swap file*" $t]}
	set page::S(swap) custom
	check "$fs: answers never carry a swap file" {[dict get [page::answers] swap] eq {mode zram}}
}
page::set_fs btrfs
foreach gib {8 16 32 64} kib {8029248 16303128 32765360 65811372} {
	set p $base
	dict set p machine ram [expr {$kib * 1024}]
	page::init; page::probed $p
	set ram [expr {$kib * 1024}]
	set g [string trimright [dict get [page::swap_plan gaming $ram btrfs] file] G]
	set h [string trimright [dict get [page::swap_plan hibernate $ram btrfs] file] G]
	page::set_swap gaming
	set t [show hardware]
	check "$gib GiB: Gaming's file is the size postinstall makes ($g GB)" {[string match "*zram, plus a $g GB swap file,*" $t]}
	page::set_swap hibernate
	set t [show hardware]
	check "$gib GiB: Hibernate's file too ($h GB)" {[string match "*zram, plus a $h GB swap file the size of RAM,*" $t]}
	check "$gib GiB: Custom starts at Gaming's size" {[ui::fval swapgb] == $g && $page::S(swapsize) == $g * 1000000000}
}
# the account picture is chosen with the Ribbon file chooser (appearance/chooser.tcl), not Tk's stock dialog
check "the installer loads the Ribbon file chooser" {[llength [info commands ::chooser::open_file]] == 1}
image create photo pic_src -width 120 -height 100; pic_src put #3a6ea5 -to 0 0 120 100
set pic [file join $::env(HOME) picked.png]; pic_src write $pic -format png
rename chooser::open_file chooser_open_real
proc chooser::open_file {args} { set ::asked $args; return $::pic }
set page::S(picture) ""
page::choose_picture
check "Choose a picture asks the chooser for pictures and takes the one chosen" {[dict get $::asked -title] eq "Choose a picture" && $page::S(picture) eq $pic}
rename chooser::open_file {}; rename chooser_open_real chooser::open_file
exit [expr {$::fails ? 1 : 0}]
