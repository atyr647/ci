# udisks.tcl (fixture) - a UDisks2 stand-in for Ribbon Files' drives (shell/files-drives.tcl). It owns
# org.freedesktop.UDisks2 on DBUS_SYSTEM_BUS_ADDRESS (a private bus in the test), with its object manager at
# /org/freedesktop/UDisks2 as udisksd has it, and these block devices:
#   sda2  the system disk, mounted on /            (HintSystem)
#   sda3  an internal disk mounted on /boot/efi    (HintSystem: no row)
#   sdb1  "Backup", a USB stick, not mounted       (Mount mounts it on UDISKS_MNT)
#   sdc1  "Locked", not mounted                    (Mount fails: org.freedesktop.UDisks2.Error.Failed "Not permitted")
#   sdz1  a volume udisks hides                    (HintIgnore: no row)
#   sda4  swap, no file system                     (no row)
# Mount logs "mount PATH" to UDISKS_LOG and creates UDISKS_STATE/mounted (the df stub then lists the mount).
# A method of its own, org.ribbon.Test.Plug, adds sdd1 "Camera" (not mounted), which signals InterfacesAdded,
# as a plugged-in card does.
lappend auto_path [file join [file dirname [file normalize [info script]]] .. .. srcpkgs ribbon-desktop files]
package require ribbon::dbus
fconfigure stdout -buffering line
set LOG $::env(UDISKS_LOG)
proc logline {args} {
	set fh [open $::LOG a]
	puts $fh [join $args "\t"]
	close $fh
}
set R /org/freedesktop/UDisks2
set bus [ribbon::dbus::connect system]
$bus manage $R

proc z {s} { return [encoding convertto utf-8 $s]\0 }

proc drive {name model removable} {
	global bus R
	$bus export $R/drives/$name org.freedesktop.UDisks2.Drive [list \
		property Model s read [list -value $model] \
		property Removable b read [list -value $removable] \
		property Ejectable b read [list -value $removable]]
}

# A block device; MOUNTS "" for one with no file system.
proc block {name drive label system ignore {mounts -}} {
	global bus R
	set p $R/block_devices/$name
	$bus export $p org.freedesktop.UDisks2.Block [list \
		property Device ay read [list -value [z /dev/$name]] \
		property PreferredDevice ay read [list -value [z /dev/$name]] \
		property IdLabel s read [list -value $label] \
		property HintName s read {-value ""} \
		property HintSystem b read [list -value $system] \
		property HintIgnore b read [list -value $ignore] \
		property Drive o read [list -value $R/drives/$drive]]
	if {$mounts ne "-"} {
		$bus export $p org.freedesktop.UDisks2.Filesystem [list \
			property MountPoints aay read [list -value [lmap m $mounts { z $m }]] \
			method Mount a{sv} s FsMount \
			method Unmount a{sv} "" FsUnmount]
	}
}

drive Disk "Internal SSD" 0
drive Stick "USB Stick" 1
drive Card "Card Reader" 1
block sda2 Disk "" 1 0 [list /]
block sda3 Disk "EFI" 1 0 [list /boot/efi]
block sda4 Disk "" 1 0
block sdb1 Stick Backup 0 0 {}
block sdc1 Stick Locked 0 0 {}
block sdz1 Stick Hidden 0 1 {}

proc FsMount {msg opts} {
	global bus
	set p [dict get $msg path]
	logline mount $p
	if {[string match */sdc1 $p]} { throw {DBUS org.freedesktop.UDisks2.Error.Failed} "Not permitted" }
	set mnt $::env(UDISKS_MNT)
	close [open [file join $::env(UDISKS_STATE) mounted] w]
	$bus set $p org.freedesktop.UDisks2.Filesystem MountPoints [list [z $mnt]]
	return $mnt
}
proc FsUnmount {msg opts} {
	global bus
	logline unmount [dict get $msg path]
	$bus set [dict get $msg path] org.freedesktop.UDisks2.Filesystem MountPoints {}
	return
}

$bus export /org/ribbon/Test org.ribbon.Test [list method Plug "" "" Plug]
proc Plug {msg} {
	logline plug
	block sdd1 Card Camera 0 0 {}
	return
}

if {[$bus request org.freedesktop.UDisks2] ne "primary"} { puts "error cannot own the name"; exit 1 }
puts ready
vwait forever
