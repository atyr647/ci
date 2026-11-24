# installer-scene.tcl - put the Tk installer into one of the mockups' states
# (design/mockups/Inst-*), on a 1440 x 900 desktop, for screenshots and
# pixel comparison (RIBBON_INSTALLER_SCENE=this file, run by main.tcl).
#   RIBBON_SCENE = welcome | keyboard | disk | alongside | manual | setup |
#                  hardware | apps | you | summary | progress | done
#   and the dialogs, errors and edge states (Inst-11 .. Inst-15, Inst-5b):
#                  dialog | edit | unsafe | check | planerror | error | close |
#                  noprobe | hwscroll
#   RIBBON_INSTALLER_SHOT = file: take a screenshot (ImageMagick import)
#   RIBBON_INSTALLER_EXIT = ms: quit after drawing; any Tcl error fails
set scene [expr {[info exists ::env(RIBBON_SCENE)] ? $::env(RIBBON_SCENE) : "welcome"}]
set here [file dirname [file normalize [info script]]]
if {![info exists ::env(RIBBON_INSTALLER_FAKE)]} { set ::env(RIBBON_INSTALLER_FAKE) [file join $here installer-fake-backend.sh] }
if {[info exists ::env(RIBBON_INSTALLER_EXIT)] || [info exists ::env(RIBBON_INSTALLER_SHOT)]} {
	proc bgerror {msg} { puts stderr "$msg\n$::errorInfo"; exit 1 }
}

# the mockups' moment: 00:27, a winter night in London
set page::S(now) [clock scan "2026-01-11 00:27" -format "%Y-%m-%d %H:%M" -timezone :UTC]
set ui::caretfix on
page::probed [exec {*}[backend::cmd probe]]

proc scene_user {} {
	ui::fset fullname "Alex Tyrone"
	page::derive_user
	ui::fset upass1 "Tr0ub4dor&"
	ui::fset upass2 "Tr0ub4dor&"
	ui::fset pass1 "correcthorse"
	ui::fset pass2 "correcthorse"
	set page::S(layout) 1
	set page::S(tz) Europe/London
}

switch -- $scene {
	welcome { page::go welcome }
	keyboard {
		set page::S(layout) 1
		ui::fset tzq lond
		page::tz_changed
		ui::fset keytest {£ @ " #}
		page::go keyboard
	}
	disk { page::go disk }
	alongside {
		set page::S(mode) alongside
		page::set_keep 520000000000
		page::go alongside
		ui::fset ribbon 480
		page::draw
	}
	manual {
		set page::S(mode) manual
		set rows [page::plan_rows]
		set r [lindex $rows 0]; dict set r format 1; lset rows 0 $r
		set free [lindex $rows 3]
		set new [dict create kind new dev /dev/nvme0n1p4 start [dict get $free start] size 478400000000 fs btrfs format 1 mount / note new]
		set rest [dict create kind free dev free start [expr {[dict get $free start] + 478400000000}] size [expr {[dict get $free size] - 478400000000}] fs "" format 0 mount "" note "free space"]
		set rows [lreplace $rows 3 3 $new $rest]
		page::set_plan_rows $rows
		set page::S(mansel) 3
		page::go manual
	}
	setup {
		ui::fset pass1 "correcthorse"
		page::go setup
		set ui::caretfix off
		ui::blink
		page::draw
	}
	hardware {
		set page::S(swap) custom
		ui::fset swapgb 24
		page::go hardware
	}
	apps { page::go apps }
	you {
		scene_user
		set page::S(userauto) 0
		page::go you
		set ui::focus upass1
		set ui::caretfix off
		ui::blink
		page::draw
	}
	summary {
		scene_user
		page::go summary
	}
	progress {
		scene_user
		set page::S(pct) 62
		set page::S(stepname) "Copying Ribbon"
		set page::S(eta) "about 3 minutes left"
		set page::S(log) [list {==> Creating btrfs with subvolumes} {==> Copying the live system (rsync)} \
			{    usr/lib/libLLVM.so.19.1 (148 MB)} {    usr/share/icons/Papirus-Dark/…} {    62% · 3.1 GB of 5.0 GB · 210 MB/s}]
		page::go progress
	}
	done { page::go done }
	dialog {
		# Inst-11: the New partition sheet over the free space
		set page::S(mode) manual
		page::go manual
		set page::S(mansel) 3
		page::part_new
		set ui::caretfix off
		ui::blink
		page::draw
	}
	edit {
		# Inst-11b: Windows' partition given / and saved: refused
		set page::S(mode) manual
		page::go manual
		set page::S(mansel) 2
		page::part_edit
		ui::fset dmount /
		page::dialog_save
		set ui::caretfix off
		ui::blink
		page::draw
	}
	unsafe {
		# Inst-12: Windows hibernated (the fake backend's --windows-ready says so)
		set page::S(mode) alongside
		page::set_keep 520000000000
		page::go alongside
		ui::fset ribbon 480
		set ::env(RIBBON_FAKE_UNSAFE) 1
		page::windows_ready
		set ui::focus ""
		page::draw
	}
	check {
		# Inst-13: the backend's check refuses the answers at Summary
		scene_user
		page::go summary
		set page::S(checkmsg) "the user name 'alex' is used by the system; pick another"
		page::draw
	}
	planerror {
		# Inst-13b: the plan the backend's check refuses (the EFI partition at /boot/efi with Limine)
		set page::S(mode) manual
		set rows [page::plan_rows]
		set r [lindex $rows 0]; dict set r mount /boot/efi; lset rows 0 $r
		set free [lindex $rows 3]
		set new [dict create kind new dev /dev/nvme0n1p4 start [dict get $free start] size 478400000000 fs btrfs format 1 mount / note new]
		set rest [dict create kind free dev free start [expr {[dict get $free start] + 478400000000}] size [expr {[dict get $free size] - 478400000000}] fs "" format 0 mount "" note "free space"]
		set rows [lreplace $rows 3 3 $new $rest]
		page::set_plan_rows $rows
		set page::S(mansel) -1
		page::go manual
		set page::S(manmsg) "an EFI partition at /boot/efi needs GRUB; with Limine the EFI partition goes at /boot (it holds the kernels)"
		page::draw
	}
	error {
		# Inst-14: the install stopped
		scene_user
		set page::S(pct) 31
		set page::S(stepname) "Copying Ribbon"
		set page::S(log) {{==> Creating btrfs with subvolumes} {==> Copying the live system (rsync)} {rsync: write failed: No space left on device (28)}}
		page::progress_line "ERROR {rsync failed: no space left on the disk}"
		page::go progress
	}
	close {
		# Inst-14b: the close button while installing
		scene_user
		set page::S(pct) 62
		set page::S(stepname) "Copying Ribbon"
		set page::S(eta) "about 3 minutes left"
		set page::S(log) [list {==> Creating btrfs with subvolumes} {==> Copying the live system (rsync)} \
			{    usr/lib/libLLVM.so.19.1 (148 MB)} {    usr/share/icons/Papirus-Dark/…} {    62% · 3.1 GB of 5.0 GB · 210 MB/s}]
		page::go progress
		app::close_window
	}
	noprobe {
		# Inst-15: the probe fails as a dismissed pkexec does
		set ::env(RIBBON_FAKE_PROBE_FAIL) 1
		page::go welcome
		backend::start_probe page::probed page::probe_failed
	}
	hwscroll {
		# Inst-5b: a laptop with fourteen devices (tests/installer-small.tcl's)
		set many {}
		foreach {cat dev} {Graphics {Intel Iris Xe} Graphics {NVIDIA GeForce RTX 3050 Laptop} Wi-Fi {Intel AX211} Ethernet {Realtek RTL8111}
			Processor {Intel Core i7-12700H} Audio {Intel Smart Sound} Bluetooth {Intel AX211} {Fingerprint reader} {Goodix 27c6:63ac}
			Webcam {Integrated Camera} Thunderbolt {Intel Thunderbolt 4} Touchpad {ELAN 0672} Sensors {Intel ISH} Storage {Samsung PM9A1} Firmware {LVFS}} {
			set id d[llength $many]
			if {$dev eq "NVIDIA GeForce RTX 3050 Laptop"} {
				lappend many [list id $id category $cat device $dev ids {} driver "NVIDIA, proprietary (latest)" status install \
					choices {{latest Latest} {580 "580 series"} {nouveau Nouveau}} default latest]
			} elseif {$cat in {Wi-Fi Audio Fingerprint\ reader Thunderbolt}} {
				lappend many [list id $id category $cat device $dev ids {} driver "$cat driver" status install choices {} default {}]
			} else {
				lappend many [list id $id category $cat device $dev ids {} driver "in the kernel" status builtin choices {} default {}]
			}
		}
		dict set page::probe drivers $many
		set page::S(drivers) {}
		foreach d $many { if {[dict get $d status] eq "install"} { dict set page::S(drivers) [dict get $d id] [dict get $d default] } }
		set page::S(swap) zram
		page::go hardware
	}
	install {
		# the whole flow against the fake backend, to Done
		scene_user
		set page::S(summary_return) 0
		page::go summary
		after 200 page::next
	}
}

if {[info exists ::env(RIBBON_INSTALLER_SHOT)]} {
	after 400 {
		update
		exec import -window root $::env(RIBBON_INSTALLER_SHOT)
		if {![info exists ::env(RIBBON_INSTALLER_EXIT)]} { exit 0 }
	}
}
if {[info exists ::env(RIBBON_INSTALLER_EXIT)]} {
	after $::env(RIBBON_INSTALLER_EXIT) { update; exit 0 }
}
