# pages.tcl - the installer's pages, laid out as in design/mockups/Inst-*.
# Coordinates are window pixels (the mockups' CSS pixels less the window's
# place, 170 x 104): the page column starts at 270. The window is 720 tall,
# or 640 on a small screen (page::layout, the Inst-C* boards).

namespace eval page {
	variable S              ;# the answers being collected, and page state
	array set S {}
	variable probe {}
	variable dialog {}      ;# manual partitioning's New / Edit dialog
	variable steps {
		globe {Welcome} kbd {Keyboard & time} disk {Where to install} lock {Disk set-up}
		chip {Hardware} box {Apps} user {You} list {Summary}
	}
	variable stepof
	array set stepof {noprobe 0 welcome 0 keyboard 1 disk 2 alongside 2 manual 2 setup 3 hardware 4 apps 5 you 6 summary 7 progress 8 done 8}
	variable L 270           ;# page column
	variable R 1060
	# the window's vertical layout (page::layout): the title's top, the
	# space under the subtitle, the footer's line and its buttons' top
	variable TOP 34
	variable GAP 22
	variable FL 648
	variable FB 665
}

# The window's height: 720 as on the Inst-* boards, or on a screen under
# 828 px high (the 720 px window would run under the dock: labwc keeps 54 px
# free at the top and the bottom) the compact 640 of the Inst-C* boards: the
# page's top margin 26, 16 under the subtitle, a 64 px footer; the rail and
# every row keep their sizes.
proc page::compact_for {screenh} { expr {$screenh < 828} }

proc page::layout {compact} {
	variable TOP
	variable GAP
	variable FL
	variable FB
	if {$compact} {
		set ui::H 640; set TOP 26; set GAP 16; set FL 576; set FB 589
	} else {
		set ui::H 720; set TOP 34; set GAP 22; set FL 648; set FB 665
	}
}

# ---- state -----------------------------------------------------------------------

proc page::init {} {
	variable S
	array set S {
		page welcome welcome install lang en_US.UTF-8 layout 0 tz UTC
		langtop 0 laytop 0 tztop 0 tzres {} langres {} drvtop 0 disktop 0 mantop 0
		disk "" games 0 mode erase keep 0 plan {} mansel -1 mandisk "" manmsg "" manok 0
		fs btrfs encrypt 1 pshow 0 drivers {} swap zram swapsize 0 boot limine
		apps {steam heroic discord vlc} autologin 0 ushow 0 userauto 1 hostauto 1 picture ""
		pct 0 stepname "" log {} logtop -1 eta "" err "" started 0 done 0 tostart 0 summary_return 0
		checkmsg "" closing 0 probefail {}
	}
	set S(now) [clock seconds]
	foreach f {langq tzq keytest keep ribbon pass1 pass2 fullname username upass1 upass2 hostname swapgb} { ui::fset $f "" }
	set S(langres) [lang_search]
}

proc page::now {} { variable S; return $S(now) }

# Fill in what the probe knows, unless you already chose.
proc page::probed {p} {
	variable S
	variable probe $p
	set m [expr {[dict exists $p machine] ? [dict get $p machine] : {}}]
	if {[dict exists $m locale]} {
		set i [lsearch -exact [lmap {n e l} $data::languages { set l }] [dict get $m locale]]
		if {$i >= 0} { set S(lang) [dict get $m locale] }
	}
	if {[dict exists $m keymap]} {
		set i 0
		foreach {l lay var} $data::layouts { if {$lay eq [dict get $m keymap] && $var eq ""} { set S(layout) $i; break }; incr i }
	}
	if {[dict exists $m timezone] && [dict get $m timezone] ne ""} { set S(tz) [dict get $m timezone] }
	set S(tzres) [data::zone_search "" $S(tz) [now] 5]
	# the disk: the first one that isn't the install media
	foreach d [disks] { set S(disk) [dict get $d dev]; break }
	set S(mandisk) $S(disk)
	set S(drivers) {}
	foreach d [dget $p drivers] {
		if {[dict get $d status] eq "install"} { dict set S(drivers) [dict get $d id] [dget $d default] }
	}
	# a custom swap file starts at the size Gaming gives
	set gb [string trimright [dict get [swap_plan gaming [dget $m ram 0] btrfs] file] G]
	set S(swapsize) [expr {$gb * 1000000000}]
	ui::fset swapgb $gb
	reset_alongside
	reset_plan
	draw
}

proc page::dget {d k {def ""}} { expr {[dict exists $d $k] ? [dict get $d $k] : $def} }
proc page::machine {k {def ""}} { variable probe; dget [dget $probe machine] $k $def }

proc page::disks {} {
	variable probe
	set out {}
	foreach d [dget $probe disks] { if {![dget $d install_media 0]} { lappend out $d } }
	return $out
}

proc page::disk {{dev ""}} {
	variable S
	if {$dev eq ""} { set dev $S(disk) }
	foreach d [disks] { if {[dict get $d dev] eq $dev} { return $d } }
	return {}
}

# Sizes as the mockups write them: 16 MB, 520 GB, 1 TB, 1.3 TB.
proc page::human {b} {
	if {$b >= 1e12} { return "[regsub {\.0$} [format %.1f [expr {$b / 1e12}]] {}] TB" }
	if {$b >= 1e9} { return "[expr {round($b / 1e9)}] GB" }
	if {$b >= 1e6} { return "[expr {round($b / 1e6)}] MB" }
	return "[expr {round($b / 1e3)}] KB"
}

proc page::fsname {fs} {
	dget {vfat FAT32 fat32 FAT32 ntfs NTFS btrfs Btrfs ext4 ext4 xfs XFS f2fs F2FS zfs ZFS bcachefs bcachefs swap swap exfat exFAT ext3 ext3 ext2 ext2} $fs $fs
}

proc page::disk_title {d} { return "[dict get $d model] · [human [dict get $d size]]" }

proc page::disk_meta {d} {
	set bus [dget {nvme NVMe sata SATA usb USB mmc {SD card} virtio Virtio scsi SCSI ata ATA} [dget $d bus] [string toupper [dget $d bus]]]
	set os [lindex [dget $d os] 0]
	if {$os ne ""} {
		foreach p [dget $d parts] { if {[dict get $p dev] eq [dget $os part]} { return "$bus · [dict get $os name] ([human [dget $p used 0]] used)" } }
		return "$bus · [dict get $os name]"
	}
	set big {}
	foreach p [dget $d parts] { if {$big eq "" || [dget $p size 0] > [dget $big size 0]} { set big $p } }
	if {$big eq ""} { return "$bus · empty" }
	set lab [dget $big label]
	return "$bus · [expr {$lab ne "" ? "\"$lab\" " : ""}][fsname [dget $big fs]] ([human [dget $big used 0]] used)"
}

proc page::disk_used {d} {
	set u 0
	foreach p [dget $d parts] { set u [expr {$u + [dget $p used 0]}] }
	expr {double($u) / max(1, [dget $d size 1])}
}

# What the pages call another system: "Windows" (any version), or its name.
proc page::osname {os} {
	if {[dget $os kind] eq "windows"} { return Windows }
	dget $os name "the other system"
}

# The partition Windows (or another OS) lives on, when it can share.
proc page::shareable {{d ""}} {
	if {$d eq ""} { set d [disk] }
	foreach p [dget $d parts] { if {[dict exists $p resize] && [dget $p os] ne ""} { return $p } }
	return {}
}

# Why the chosen way to install can't work on this computer or disk ("" =
# it can), as the backend's check would say at Summary: alongside on legacy
# BIOS or an MBR disk (the probe's alongside.why), manual on legacy BIOS.
# Windows that wasn't shut down fully is the Alongside page's business.
proc page::mode_problem {} {
	variable S
	set d [disk]
	switch -- $S(mode) {
		alongside {
			set al [dget $d alongside]
			if {![machine efi 1] || [dget $d table gpt] ne "gpt"} {
				return [dget $al why "Installing next to Windows needs a computer started in UEFI mode and a GPT disk."]
			}
		}
		manual {
			if {![machine efi 1]} { return "This computer started in legacy BIOS mode; only \"Erase disk\" works there." }
		}
	}
	return ""
}

# The choices the backend takes with this disk mode and computer: no ZFS
# unless the whole disk is Ribbon's and the computer started in UEFI mode
# (ZFSBootMenu is an EFI program), GRUB only on UEFI, no swap file on
# ZFS or bcachefs. What was chosen falls back to the default when it goes.
proc page::fs_opts {} {
	variable S
	set f {btrfs zfs bcachefs}
	if {$S(mode) ne "erase" || ![machine efi 1]} { set f {btrfs bcachefs} }
	return $f
}
proc page::boot_opts {} {
	variable S
	switch $S(fs) {
		zfs { return {zfsbootmenu ZFSBootMenu} }
		bcachefs { return {limine Limine} }
	}
	if {![machine efi 1]} { return {limine Limine} }
	return {limine Limine grub GRUB}
}
proc page::swap_opts {} {
	variable S
	if {$S(fs) in {zfs bcachefs}} { return {zram zram gaming Gaming none None} }
	return {zram zram gaming Gaming hibernate Hibernate custom Custom none None}
}
proc page::settle {} {
	variable S
	if {$S(fs) ni [fs_opts]} { set_fs btrfs 0 }
	if {$S(boot) ni [lmap {k l} [boot_opts] { set k }]} { set S(boot) [lindex [boot_opts] 0] }
	if {$S(swap) ni [lmap {k l} [swap_opts] { set k }]} { set S(swap) zram }
}

# What postinstall's step_swap sets up for MODE (ribbon-swap's zram, file
# and hibernate), with RAM in bytes as the probe gives it (MemTotal) and
# FS the root filesystem; SIZE in bytes for custom. The Hardware page's
# copy reads from it; tests/installer-swap.sh holds it to step_swap.
proc page::swap_plan {mode ram fs {size 0}} {
	set gib [expr {wide($ram) / 1073741824 + 1}]
	set nofile [expr {$fs in {zfs bcachefs}}]
	set off {zram 50% file off hibernate no}
	switch -- $mode {
		gaming {
			if {$nofile} { return {zram 100% file off hibernate no} }
			return [list zram 50% file [expr {max(8, 40 - $gib)}]G hibernate no]
		}
		hibernate {
			if {$nofile} { return $off }
			return [list zram 25% file ${gib}G hibernate yes]
		}
		custom {
			set mib [expr {wide($size) / 1048576}]
			if {$mib < 256 || $nofile} { return $off }
			return [list zram 50% file ${mib}M hibernate no]
		}
		none { return {zram off file off hibernate no} }
	}
	return $off
}

# The disk that could hold games: another disk's biggest data partition.
proc page::games_part {} {
	variable S
	set best {}
	foreach d [disks] {
		if {[dict get $d dev] eq $S(disk)} continue
		foreach p [dget $d parts] {
			if {[dget $p fs] in {ext4 btrfs xfs f2fs ntfs exfat} && [dget $p type] ne "esp" && ($best eq "" || [dget $p size] > [dget [lindex $best 1] size])} {
				set best [list $d $p]
			}
		}
	}
	return $best
}

# ---- alongside: Windows keeps K bytes of T ------------------------------------

proc page::along_total {} {
	set p [shareable]
	if {$p eq ""} { return 0 }
	set end [expr {[dict get $p start] + [dict get $p size]}]
	set t [dict get $p size]
	foreach f [dget [disk] free] { if {abs([dict get $f start] - $end) <= 1048576} { set t [expr {$t + [dict get $f size]}] } }
	return $t
}

proc page::along_limits {} {
	set p [shareable]
	set r [dget $p resize]
	list [dget $r min 0] [dget $r max [along_total]]
}

proc page::reset_alongside {} {
	variable S
	set p [shareable]
	if {$p eq ""} { set S(keep) 0; return }
	lassign [along_limits] lo hi
	set S(keep) [expr {min($hi, max($lo, [dict get $p size]))}]
	if {$S(keep) >= $hi} { set S(keep) [expr {max($lo, ([along_total] / 2))}] }
	sync_along
}

proc page::sync_along {} {
	variable S
	ui::fset keep [expr {round($S(keep) / 1e9)}]
	ui::fset ribbon [expr {round(([along_total] - $S(keep)) / 1e9)}]
}

proc page::set_keep {k} {
	variable S
	lassign [along_limits] lo hi
	set S(keep) [expr {min($hi, max($lo, $k))}]
	sync_along
	draw
}

# typing in either field moves the bar when the number is in range
proc page::along_typed {which} {
	variable S
	set v [ui::fval $which]
	if {![string is double -strict $v]} return
	set k [expr {$which eq "keep" ? $v * 1e9 : [along_total] - $v * 1e9}]
	lassign [along_limits] lo hi
	if {$k >= $lo && $k <= $hi} {
		set S(keep) [expr {wide($k)}]
		# the other field follows
		if {$which eq "keep"} { ui::fset ribbon [expr {round(([along_total] - $S(keep)) / 1e9)}] } else { ui::fset keep [expr {round($S(keep) / 1e9)}] }
	}
	draw
}

proc page::along_drag {x y} {
	variable S
	set ww [expr {$x - 270 - 7}]
	set k [expr {($ww - 32) / 684.0 * [along_total]}]
	set_keep [expr {wide(round($k / 1e9) * 1e9)}]
}

# ---- manual partitioning: the plan ------------------------------------------------

# Rows per disk: {kind part|new|free dev .. start .. size .. fs .. format 0|1
# mount .. note ..}, in disk order.
proc page::reset_plan {} {
	variable S
	set S(plan) {}
	foreach d [disks] {
		set rows {}
		foreach p [dget $d parts] {
			set note [dget [dget $p os] name]
			if {$note eq ""} { set note [dget {esp {EFI system} msr {Microsoft reserved} swap swap} [dget $p type] [dget $p label]] }
			set mount [expr {[dget $p type] eq "esp" && [dict get $d dev] eq $S(disk) ? "/boot" : ""}]
			lappend rows [dict create kind part dev [dict get $p dev] start [dget $p start 0] size [dget $p size 0] \
				fs [dget $p fs] format 0 mount $mount note $note]
		}
		foreach f [dget $d free] {
			lappend rows [dict create kind free dev free start [dget $f start 0] size [dget $f size 0] fs "" format 0 mount "" note "free space"]
		}
		dict set S(plan) [dict get $d dev] [lsort -command {apply {{a b} { set x [dict get $a start]; set y [dict get $b start]; expr {$x < $y ? -1 : ($x > $y ? 1 : 0)} }}} $rows]
	}
	set S(mansel) -1
}

proc page::plan_rows {} {
	variable S
	if {![dict exists $S(plan) $S(mandisk)]} { return {} }
	dict get $S(plan) $S(mandisk)
}

proc page::set_plan_rows {rows} {
	variable S
	# merge neighbouring free space
	set out {}
	foreach r $rows {
		if {[dict get $r kind] eq "free" && [llength $out] && [dict get [lindex $out end] kind] eq "free"} {
			set l [lindex $out end]
			dict set l size [expr {[dict get $l size] + [dict get $r size]}]
			lset out end $l
		} else { lappend out $r }
	}
	dict set S(plan) $S(mandisk) $out
}

# The next partition name on the disk (nvme0n1 -> nvme0n1p4, sda -> sda2).
proc page::next_part_name {} {
	variable S
	set dev $S(mandisk)
	set n 0
	foreach dd [disks] {
		if {[dict get $dd dev] ne $dev} continue
		foreach p [dget $dd parts] { if {[regexp {(\d+)$} [dict get $p dev] -> k]} { set n [expr {max($n, $k)}] } }
	}
	dict for {d rows} $S(plan) {
		if {$d ne $dev} continue
		foreach r $rows { if {[dict get $r kind] eq "new" && [regexp {(\d+)$} [dict get $r dev] -> k]} { set n [expr {max($n, $k)}] } }
	}
	return "$dev[expr {[string match {*[0-9]} $dev] ? "p" : ""}][incr n]"
}

# Is the plan bootable? Returns {ok text}.
proc page::plan_status {} {
	variable S
	set root 0; set esp 0
	dict for {d rows} $S(plan) {
		foreach r $rows {
			if {[dict get $r mount] eq "/"} { set root 1 }
			if {[dict get $r fs] eq "vfat" && [dict get $r mount] in {/boot /boot/efi}} { set esp 1 }
		}
	}
	set efi [machine efi 1]
	if {$root && ($esp || !$efi)} { return [list 1 "An EFI partition at /boot and a / partition: ready"] }
	if {!$root && $efi && !$esp} { return [list 0 "Needs an EFI partition at /boot and a / partition"] }
	if {!$root} { return [list 0 "Needs a / partition"] }
	return [list 0 "Needs an EFI partition (FAT32) at /boot"]
}

# ---- passwords --------------------------------------------------------------------

# 0..4 from a rough entropy estimate, with a word for it.
proc page::strength {pw} {
	if {$pw eq ""} { return {0 ""} }
	set pool 0
	if {[regexp {[a-z]} $pw]} { incr pool 26 }
	if {[regexp {[A-Z]} $pw]} { incr pool 26 }
	if {[regexp {[0-9]} $pw]} { incr pool 10 }
	if {[regexp {[^a-zA-Z0-9]} $pw]} { incr pool 33 }
	set bits [expr {[string length $pw] * log(max(2, $pool)) / log(2)}]
	if {[string length $pw] < 6} { return {1 {Too short}} }
	if {$bits < 30} { return {1 Weak} }
	if {$bits < 45} { return {2 Fair} }
	if {$bits < 60} { return {3 Good} }
	return {4 Strong}
}

# The four bars and the word, in a row WIDTH wide at x y (15 tall).
proc page::meter {x y w pw} {
	set c [array get ui::c]
	lassign [strength $pw] n word
	set lw [expr {$word eq "" ? 0 : [ui::measure i12 $word] + 10}]
	set gaps [expr {$word eq "" ? 12 : 16}]
	set bw [expr {($w - $lw - $gaps) / 4.0}]
	for {set k 0} {$k < 4} {incr k} {
		ui::box [expr {$x + $k * ($bw + 4)}] [expr {$y + 5.5}] $bw 4 -fill [expr {$k < $n ? [dict get $c accent] : [dict get $c pill]}] -radius 2
	}
	if {$word ne ""} { ui::text [expr {$x + $w}] $y $word i12 [dict get $c muted] e }
}

# ---- the user ---------------------------------------------------------------------

proc page::ascii {s} {
	string map {á a à a â a ä a ã a å a æ ae ç c é e è e ê e ë e í i ì i î i ï i ñ n ó o ò o ô o ö o õ o ø o œ oe ß ss ú u ù u û u ü u ý y ÿ y ł l ś s ź z ż z ć c ń n ą a ę e č c š s ž z ř r ť t ď d ň n ů u ő o ű u} [string tolower $s]
}

proc page::derive_user {} {
	variable S
	set first [lindex [split [string trim [ui::fval fullname]]] 0]
	set u [regsub -all {[^a-z0-9_-]} [ascii $first] ""]
	regsub {^[^a-z_]+} $u "" u
	if {$S(userauto)} { ui::fset username [string range $u 0 31] }
	if {$S(hostauto)} {
		set h [regsub -all {[^a-z0-9-]} [ui::fval username] ""]
		ui::fset hostname [expr {$h eq "" ? "" : "$h-[expr {[machine laptop 0] ? "laptop" : "desktop"}]"}]
	}
}

proc page::user_problem {} {
	set u [ui::fval username]
	if {$u eq ""} { return "" }
	if {![regexp {^[a-z_][a-z0-9_-]*$} $u]} { return "lowercase letters, digits, - and _" }
	if {[string length $u] > 32} { return "at most 32 characters" }
	if {$u in {root bin daemon adm lp sync shutdown halt mail news uucp operator man nobody sys games ftp www-data messagebus polkitd _greeter greeter dbus}} { return "already used by the system" }
	return ""
}

# ---- navigation -----------------------------------------------------------------

proc page::flow {} {
	variable S
	set f {welcome keyboard disk}
	if {$S(mode) eq "alongside"} { lappend f alongside }
	if {$S(mode) eq "manual"} { lappend f manual }
	lappend f setup hardware apps you summary
	return $f
}

proc page::go {p} {
	variable S
	set S(page) $p
	set S(closing) 0
	set ui::focus [dget {keyboard keytest alongside ribbon setup pass1 you fullname hardware swapgb} $p ""]
	if {$p eq "you" && [ui::fval fullname] ne ""} { set ui::focus "" }
	if {$p eq "hardware" && $S(swap) ne "custom"} { set ui::focus "" }
	if {$p eq "setup" && !$S(encrypt)} { set ui::focus "" }
	set ui::kbd 0
	draw
}

proc page::next {} {
	variable S
	if {$S(page) eq "noprobe"} { reprobe; return }
	if {[set why [problem]] ne ""} {
		# Windows not ready: Continue goes to Check again
		if {$why eq "unsafe"} { set ui::focus recheck; set ui::kbd 1; draw }
		return
	}
	if {$S(page) eq "welcome" && $S(welcome) eq "try"} { try_first; return }
	if {$S(page) eq "summary"} { start; return }
	if {$S(page) eq "manual"} {
		set S(manmsg) [backend::check [answers]]
		if {$S(manmsg) ne ""} { draw; return }
	}
	set f [flow]
	if {$S(summary_return) && $S(page) ni {disk alongside manual}} { set nxt summary } else {
		set nxt [lindex $f [expr {[lsearch $f $S(page)] + 1}]]
	}
	if {$nxt eq "summary"} {
		set S(summary_return) 0
		set S(checkmsg) [backend::check [answers]]
	}
	go $nxt
}

proc page::back {} {
	variable S
	if {$S(page) in {progress done}} return
	set f [flow]
	set i [lsearch $f $S(page)]
	if {$i > 0} { go [lindex $f [expr {$i - 1}]] }
}

# Rail: go back to a step already done.
proc page::rail_go {k} {
	variable S
	variable stepof
	if {$S(page) in {progress done}} return
	if {$k >= $stepof($S(page))} return
	foreach p [flow] { if {$stepof($p) == $k} { go $p; return } }
}

# What stops Continue on this page ("" = nothing); focuses the field.
proc page::problem {} {
	variable S
	switch $S(page) {
		disk {
			if {$S(disk) eq ""} { return "no disk" }
			if {[mode_problem] ne ""} { return mode }
		}
		alongside {
			lassign [along_limits] lo hi
			if {$S(keep) < $lo || $S(keep) > $hi} { return range }
			if {![dget [dget [shareable] resize] safe 1]} { return unsafe }
		}
		manual { if {![lindex [plan_status] 0]} { return plan } }
		setup {
			if {$S(encrypt)} {
				if {[ui::fval pass1] eq ""} { set ui::focus pass1; draw; return pass }
				if {[ui::fval pass1] ne [ui::fval pass2]} { set ui::focus pass2; draw; return pass }
			}
		}
		hardware {
			if {$S(swap) eq "custom" && (![string is double -strict [ui::fval swapgb]] || [ui::fval swapgb] <= 0)} { set ui::focus swapgb; draw; return swap }
		}
		you {
			foreach {f bad} [list fullname [expr {[string trim [ui::fval fullname]] eq ""}] \
				username [expr {[ui::fval username] eq "" || [user_problem] ne ""}] \
				upass1 [expr {[ui::fval upass1] eq ""}] upass2 [expr {[ui::fval upass1] ne [ui::fval upass2]}] \
				hostname [expr {![regexp {^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$} [ui::fval hostname]]}]] {
				if {$bad} { set ui::focus $f; set S(youtried) 1; draw; return $f }
			}
		}
		summary { if {$S(checkmsg) ne ""} { return check } }
	}
	return ""
}

# "Try it first": close; the launcher's "Install Ribbon" opens it again.
proc page::try_first {} { exit 0 }

proc page::clicked_outside {} {
	variable dialog
	variable S
	if {$dialog ne "" || $S(closing)} return
	if {[lindex [ui::focused] 1] eq "field"} { set ui::focus ""; draw }
}

# ---- keys -----------------------------------------------------------------------

proc page::key {sym char state} {
	variable S
	variable dialog
	# act on what is on screen (a draw may still be waiting)
	update idletasks
	if {$dialog ne ""} { dialog_key $sym $char $state; return }
	if {$S(closing)} { close_key $sym; return }
	set f [ui::focused]
	lassign $f id kind
	switch -- $sym {
		Tab { ui::cycle 1; return }
		ISO_Left_Tab { ui::cycle -1; return }
	}
	if {$sym eq "Tab" && ($state & 1)} { ui::cycle -1; return }
	if {$kind eq "field"} {
		if {$sym in {Up Down Prior Next} && [list_key $id $sym]} return
		if {$sym in {Return KP_Enter}} { next; return }
		if {$sym eq "Escape"} { set ui::focus ""; draw; return }
		if {[ui::field_key $id $sym $char $state]} { draw; return }
		return
	}
	if {$kind in {list seg button choice}} {
		if {$kind eq "button" && $sym in {Return KP_Enter space}} { uplevel #0 [lindex $f 7]; return }
		if {$kind ne "button" && [uplevel #0 [list {*}[lindex $f 7] $sym]]} { return }
	}
	switch -- $sym {
		Return - KP_Enter { next }
		Escape { back }
		default {
			# typing on a page with a search field goes to it
			set target [dget {welcome langq keyboard tzq} $S(page) ""]
			if {$S(page) eq "keyboard" && $kind eq "list" && $id eq "layouts"} { layout_typeahead $char; return }
			if {$target ne "" && $char ne "" && [string is print $char] && !($state & 12)} {
				set ui::focus $target
				ui::field_key $target $sym $char $state
				draw
			}
		}
	}
}

# Arrow keys in a search field move the list's selection.
proc page::list_key {id sym} {
	variable S
	switch $id {
		langq { return [lang_key $sym] }
		tzq { return [tz_key $sym] }
	}
	return 0
}

# ---- drawing --------------------------------------------------------------------

# Redraws are coalesced: many changes (a burst of keys) make one draw.
proc page::draw {} {
	variable pending
	if {[info exists pending] && $pending ne ""} return
	set pending [after idle page::draw_now]
}

proc page::draw_now {} {
	variable pending ""
	variable S
	variable dialog
	array set c [array get ui::c]
	set ui::dim [expr {$dialog ne "" || $S(closing) ? 0.5 : 0}]
	variable stepof
	set step $stepof($S(page))
	ui::begin [list frame $step] [list page::frame_boxes $step]
	frame $step
	draw_$S(page)
	ui::focus_ring
	if {$dialog ne ""} { set ui::dim 0; dialog_draw } elseif {$S(closing)} { set ui::dim 0; close_draw }
	ui::finish
}

# The frame's boxes: drawn once per step (ui::begin keeps them).
proc page::frame_boxes {step} {
	array set c [array get ui::c]
	set H $ui::H
	ui::box 0 0 1100 $H -fill $c(bar) -radius 16 -ring [list $c(border) 1]
	ui::box 0 0 230 $H -fill $c(d2) -radius {16 0 0 16}
	ui::box 229 0 1 $H -fill $c(border)
	for {set k 0} {$k < 8} {incr k} {
		set y [expr {80 + 44 * $k}]
		if {$k == $step} {
			ui::box 16 $y 198 40 -fill $c(field) -radius 10
			ui::box 16 [expr {$y + 10}] 3 20 -fill $c(accent) -radius 2
		}
		if {$k < $step} { ui::box 28 [expr {$y + 9}] 22 22 -fill $c(softd2) -radius 11 }
	}
	ui::hline 230 1100 $page::FL $c(border)
}

proc page::frame {step} {
	variable S
	variable steps
	array set c [array get ui::c]
	set w [ui::text 28 26 Ribbon sg22 $c(fg) w -0.44]
	ui::text [expr {28 + $w + 8}] 36 installer i12 $c(muted)
	set k 0
	foreach {ic label} $steps {
		set y [expr {80 + 44 * $k}]
		set done [expr {$k < $step}]; set cur [expr {$k == $step}]
		if {$done} {
			ui::icon check 12 $c(accent) 33 [expr {$y + 14}] 2.6
			ui::hit 16 $y 198 40 [list apply {{k x y} { page::rail_go $k }} $k]
		} else {
			ui::icon $ic 16 [expr {$cur ? $c(accent) : $c(muted)}] 31 [expr {$y + 12}]
		}
		ui::text 62 [expr {$y + 12}] $label [expr {$cur ? "i13s" : "i13m"}] [expr {$cur || $done ? $c(fg) : $c(muted)}]
		incr k
	}
	# the machine, at the bottom of the rail
	set sy [expr {$ui::H - 56}]; set by [expr {$ui::H - 33}]
	set net [machine net {}]
	if {[dget $net online 0]} {
		set name [dget $net name]
		if {[dget $net kind] eq "ethernet" || $name eq ""} { set name [expr {$name eq "" ? "Wired" : $name}] }
		ui::icon wifi 14 $c(accent) 28 [expr {$sy + 0.5}]
		ui::text 50 $sy "Online · $name" i12 $c(muted)
	} else {
		ui::icon wifi-off 14 $c(muted) 28 [expr {$sy + 0.5}]
		ui::text 50 $sy Offline i12 $c(muted)
	}
	set bat [machine battery {}]
	ui::icon battery 15 $c(muted) 28 $by
	if {[dget $bat percent] ne ""} {
		ui::text 51 $by "[expr {[dget $bat charging 0] ? "Charging · " : "Battery "}][dget $bat percent]%" i12 $c(muted)
	} else { ui::text 51 $by "Plugged in" i12 $c(muted) }
}

# Title and subtitle; returns where the body starts.
proc page::head {title sub} {
	variable TOP
	variable GAP
	array set c [array get ui::c]
	if {$title eq ""} { return [expr {$TOP + 40}] }
	ui::text 270 $TOP $title sg28 $c(fg) w -0.56
	set y [expr {$TOP + 42}]
	foreach line [ui::wrap i14 $sub 640] { ui::text 270 [expr {$y + 2}] $line i14 $c(muted); incr y 21 }
	return [expr {$y + $GAP}]
}

# Where the body starts under a title and a one-line subtitle (page::head's answer).
proc page::head_end {} { expr {$page::TOP + 42 + 21 + $page::GAP} }

# Back and the primary button, right-aligned in the footer.
proc page::footer {primary {icon arrow} {back 1}} {
	array set c [array get ui::c]
	set x 1060
	set w [ui::button_w $primary primary $icon]
	set x [expr {$x - $w}]
	ui::button continue $x $page::FB $primary primary page::next $icon $w
	if {$back} {
		set bw [ui::button_w Back ghost]
		ui::button back [expr {$x - 10 - $bw}] $page::FB Back ghost page::back "" $bw
	}
}

# A list: rows 36 tall with 2 px gaps; ITEMS {label extra}; SEL index.
proc page::rows {id x y w items sel visible top pick {selextra 1}} {
	array set c [array get ui::c]
	set n [llength $items]
	set top [expr {max(0, min($top, $n - $visible))}]
	for {set k $top} {$k < min($n, $top + $visible)} {incr k} {
		lassign [lindex $items $k] label extra
		set ry [expr {$y + ($k - $top) * 38}]
		set on [expr {$k == $sel}]
		if {$on} { ui::box $x $ry $w 36 -fill $c(field) -radius 8 }
		ui::text [expr {$x + 12}] [expr {$ry + 9.5}] $label [expr {$on ? "i14s" : "i14"}] $c(fg)
		set rx [expr {$x + $w - 12}]
		if {$on} { ui::icon check 15 $c(accent) [expr {$rx - 15}] [expr {$ry + 10.5}] 2.2; set rx [expr {$rx - 25}] }
		if {$extra ne ""} { ui::text $rx [expr {$ry + 10.5}] $extra [expr {$on ? "i12s" : "i12"}] $c(muted) e }
		ui::hit $x $ry $w 36 [list apply {{p k x y} { uplevel #0 [list {*}$p $k] }} $pick $k]
	}
	set h [expr {$visible * 38 - 2}]
	ui::wheel $x $y $w $h [list page::wheel $id]
	ui::focusable $id list $x $y $w [expr {min($n, $visible) * 38 - 2}] 8 [list page::list_nav $id]
	return $top
}

# The warning strip (Summary's: ¶soft, a 1 px accent ring): BOLD in 14/600 over REST in 13 px
# §muted, both wrapped; BUTTON {id label script} a compact button at its right. Returns its height.
proc page::strip {x y w bold rest {button {}}} {
	array set c [array get ui::c]
	set bw 0
	if {[llength $button]} { set bw [expr {[ui::measure i13m [lindex $button 1]] + 28 + 12}] }
	set tw [expr {$w - 32 - 18 - 12 - $bw}]
	set bl [ui::wrap i14s $bold $tw]
	set ml [expr {$rest eq "" ? {} : [ui::wrap i13 $rest $tw]}]
	set h [expr {28 + 20 * [llength $bl] + ([llength $ml] ? 3 + 18 * [llength $ml] : 0)}]
	set soft [ui::mix $c(accent) $c(bar) 0.16]
	ui::box $x $y $w $h -fill $soft -radius 12 -ring [list [ui::mix $c(accent) $soft 0.5] 1]
	ui::icon warn 18 $c(accent) [expr {$x + 16}] [expr {$y + 15}]
	set ty [expr {$y + 15}]
	foreach l $bl { ui::text [expr {$x + 46}] $ty $l i14s $c(fg); incr ty 20 }
	incr ty 3
	foreach l $ml { ui::text [expr {$x + 46}] $ty $l i13 $c(muted); incr ty 18 }
	if {[llength $button]} {
		lassign $button id label script
		ui::cbutton $id [expr {$x + $w - 16}] [expr {$y + ($h - 34) / 2.0}] $label $script e
	}
	return $h
}

proc page::wheel {id d} {
	variable S
	set S(${id}top) [expr {max(0, $S(${id}top) + $d)}]
	draw
}

proc page::list_nav {id sym} {
	switch $id {
		lang { return [lang_key $sym] }
		tz { return [tz_key $sym] }
		layouts { return [layout_key $sym] }
	}
	return 0
}

# Make row SEL visible in a list of VISIBLE rows starting at TOPVAR.
proc page::reveal {topvar sel visible} {
	variable S
	if {$sel < $S($topvar)} { set S($topvar) $sel }
	if {$sel >= $S($topvar) + $visible} { set S($topvar) [expr {$sel - $visible + 1}] }
}

# ---- 1 welcome ------------------------------------------------------------------

proc page::lang_search {} {
	set q [string tolower [string trim [ui::fval langq]]]
	set out {}
	foreach {n e l} $data::languages {
		if {$q eq "" || [string first $q [string tolower $n]] >= 0 || [string first $q [string tolower $e]] >= 0 || [string first $q [string tolower $l]] == 0} {
			lappend out [list $n $l]
		}
	}
	return $out
}

proc page::lang_key {sym} {
	variable S
	set locs [lmap r $S(langres) { lindex $r 1 }]
	set i [lsearch -exact $locs $S(lang)]
	switch -- $sym {
		Up { set i [expr {max(0, $i - 1)}] }
		Down { set i [expr {min([llength $locs] - 1, $i + 1)}] }
		Prior { set i [expr {max(0, $i - 9)}] }
		Next { set i [expr {min([llength $locs] - 1, $i + 9)}] }
		default { return 0 }
	}
	if {$i >= 0 && [llength $locs]} { set S(lang) [lindex $locs $i]; reveal langtop $i 9; draw }
	return 1
}

proc page::draw_welcome {} {
	variable S
	array set c [array get ui::c]
	set y [head "Welcome to Ribbon" "A fast, quiet desktop for work and games. Pick your language to begin."]
	ui::label 270 $y Language
	ui::field langq 270 [expr {$y + 32}] 430 -icon search -ph "Search languages" -onchange page::lang_changed
	set items [lmap r $S(langres) { list [lindex $r 0] "" }]
	set sel [lsearch -exact [lmap r $S(langres) { lindex $r 1 }] $S(lang)]
	set S(langtop) [rows lang 270 [expr {$y + 80}] 430 $items $sel 9 $S(langtop) page::pick_lang]
	if {![llength $items]} { ui::text 306 [expr {$y + 89.5}] "No language matches" i14 $c(muted) }
	# what to do
	set x 756
	ui::label $x $y "What would you like to do"
	set cy [expr {$y + 34}]
	foreach {key title desc} {
		install {Install Ribbon} {Set up Ribbon on this computer. Takes about 6 minutes.}
		try {Try it first} {Use the live desktop. The installer is on the desktop when you are ready.}
	} {
		set on [expr {$S(welcome) eq $key}]
		set lines [ui::wrap i13 $desc 238]
		set h [expr {16 + 19 + 4 + [llength $lines] * 18.85 + 16}]
		ui::box $x $cy 300 $h -fill [expr {$on ? $c(field) : $c(bar)}] -radius 12 -ring [expr {$on ? [list $c(accent) 1.5] : [list $c(border) 1]}]
		ui::radio [expr {$x + 16}] [expr {$cy + 16}] $on [expr {$on ? $c(field) : $c(bar)}]
		ui::text [expr {$x + 46}] [expr {$cy + 16}] $title i15s $c(fg)
		set ly [expr {$cy + 39 + 1}]
		foreach l $lines { ui::text [expr {$x + 46}] $ly $l i13 $c(muted); set ly [expr {$ly + 18.85}] }
		ui::hit $x $cy 300 $h [list apply {{k x y} { set page::S(welcome) $k; page::draw }} $key]
		ui::focusable choice-$key choice $x $cy 300 $h 12 [list apply {{k sym} { if {$sym in {space Up Down}} { set page::S(welcome) [expr {$sym eq "space" ? $k : ($sym eq "Up" ? "install" : "try")}]; page::draw; return 1 }; return 0 }} $key]
		set cy [expr {$cy + $h + 12}]
	}
	footer [expr {$S(welcome) eq "try" ? "Try Ribbon" : "Continue"}] arrow 0
}

proc page::lang_changed {} {
	variable S
	set S(langres) [lang_search]
	set S(langtop) 0
	if {[llength $S(langres)] && [lsearch -exact -index 1 $S(langres) $S(lang)] < 0} { set S(lang) [lindex $S(langres) 0 1] }
}

proc page::pick_lang {k} {
	variable S
	set S(lang) [lindex $S(langres) $k 1]
	draw
}

# ---- 2 keyboard and time --------------------------------------------------------

proc page::layout_key {sym} {
	variable S
	set n [expr {[llength $data::layouts] / 3}]
	switch -- $sym {
		Up { set S(layout) [expr {max(0, $S(layout) - 1)}] }
		Down { set S(layout) [expr {min($n - 1, $S(layout) + 1)}] }
		Prior { set S(layout) [expr {max(0, $S(layout) - 7)}] }
		Next { set S(layout) [expr {min($n - 1, $S(layout) + 7)}] }
		default { return 0 }
	}
	reveal laytop $S(layout) 7
	apply_layout
	draw
	return 1
}

# Type-ahead in the layout list: letters jump to the first match.
proc page::layout_typeahead {char} {
	variable S
	variable ta
	if {$char eq "" || ![string is print $char]} return
	if {![info exists ta] || [clock milliseconds] - [lindex $ta 1] > 1000} { set ta [list "" 0] }
	set q [string tolower "[lindex $ta 0]$char"]
	set ta [list $q [clock milliseconds]]
	set i 0
	foreach {l lay var} $data::layouts {
		if {[string first $q [string tolower $l]] == 0} { set S(layout) $i; reveal laytop $i 7; apply_layout; draw; return }
		incr i
	}
}

# The test field types with the chosen layout (this window is an X client).
proc page::apply_layout {} {
	variable S
	if {[info exists ::env(RIBBON_SCENE)]} return
	lassign [lrange $data::layouts [expr {$S(layout) * 3}] [expr {$S(layout) * 3 + 2}]] - lay var
	catch {exec setxkbmap -layout $lay {*}[expr {$var ne "" ? [list -variant $var] : ""}] 2>/dev/null &}
}

proc page::pick_layout {k} {
	variable S
	set S(layout) $k
	set ui::focus layouts
	apply_layout
	draw
}

proc page::tz_key {sym} {
	variable S
	set i [lsearch -exact $S(tzres) $S(tz)]
	switch -- $sym {
		Up { set i [expr {max(0, $i - 1)}] }
		Down { set i [expr {min([llength $S(tzres)] - 1, $i + 1)}] }
		default { return 0 }
	}
	if {$i >= 0} { set S(tz) [lindex $S(tzres) $i]; reveal tztop $i 5; draw }
	return 1
}

proc page::tz_changed {} {
	variable S
	set S(tzres) [data::zone_search [ui::fval tzq] $S(tz) [now] 5]
	set S(tztop) 0
	if {[llength $S(tzres)] && [ui::fval tzq] ne ""} { set S(tz) [lindex $S(tzres) 0] }
}

proc page::draw_keyboard {} {
	variable S
	array set c [array get ui::c]
	set y [head "Keyboard and time" "Your keyboard layout and where you are, for the clock."]
	ui::label 270 $y "Keyboard layout"
	set items [lmap {l lay var} $data::layouts { list $l "" }]
	set S(laytop) [rows layouts 270 [expr {$y + 32}] 365 $items $S(layout) 7 $S(laytop) page::pick_layout]
	ui::field keytest 270 [expr {$y + 314}] 365 -icon kbd -prefix "Type here to test: "
	# time zone
	set x 691
	ui::label $x $y "Time zone"
	ui::field tzq $x [expr {$y + 32}] 365 -icon search -ph "Search places" -onchange page::tz_changed
	set items {}
	foreach z $S(tzres) {
		lassign [data::zone_now $z [now]] - abbr hm
		lappend items [list $z "$abbr · $hm"]
	}
	set sel [lsearch -exact $S(tzres) $S(tz)]
	set S(tztop) [rows tz $x [expr {$y + 80}] 365 $items $sel 5 $S(tztop) page::pick_tz]
	if {![llength $items]} { ui::text [expr {$x + 12}] [expr {$y + 89.5}] "No place matches" i14 $c(muted) }
	if {0} {
	}
	footer Continue
}

proc page::pick_tz {k} {
	variable S
	set S(tz) [lindex $S(tzres) $k]
	draw
}

# ---- 3 where to install ----------------------------------------------------------

proc page::draw_disk {} {
	variable S
	array set c [array get ui::c]
	set y [head "Where to install" "Pick the disk for Ribbon and what happens to what is on it."]
	ui::label 270 $y Disk
	set cy [expr {$y + 32}]
	# as many cards as fit above the footer (24 clear, with the games line under them); more
	# scroll as Hardware's drivers do (Inst-5b): a thumb, the cards 10 clear of it, a fade
	set all [disks]
	set n [llength $all]
	set vis [expr {max(1, int(($page::FL - 24 - ([games_part] ne "" ? 26 : 0) - $cy + 10) / 98))}]
	set cw 381
	set S(disktop) [expr {max(0, min($S(disktop), $n - $vis))}]
	if {$n > $vis} {
		set cw 367
		set lh [expr {$vis * 98 - 10}]
		ui::wheel 270 $cy 381 $lh {apply {{d} { set page::S(disktop) [expr {max(0, $page::S(disktop) + $d)}]; page::draw }}}
		ui::thumb 647 $cy $lh $n $vis $S(disktop)
	}
	foreach d [lrange $all $S(disktop) [expr {$S(disktop) + $vis - 1}]] {
		set on [expr {[dict get $d dev] eq $S(disk)}]
		set bg [expr {$on ? $c(field) : $c(bar)}]
		ui::box 270 $cy $cw 88 -fill $bg -radius 12 -ring [expr {$on ? [list $c(accent) 1.5] : [list $c(border) 1]}]
		ui::radio 286 [expr {$cy + 24}] $on $bg
		ui::icon disk 18 [expr {$on ? $c(accent) : $c(muted)}] 318 [expr {$cy + 24}]
		ui::text 347 [expr {$cy + 16}] [clipt i14s [disk_title $d] [expr {$cw - 93}]] i14s $c(fg)
		ui::text 347 [expr {$cy + 35}] [clipt i12 [disk_meta $d] [expr {$cw - 93}]] i12 $c(muted)
		set u [disk_used $d]
		set bw [expr {$cw - 32}]; set uw [expr {$bw * $u}]
		if {$uw > 0} { ui::box 286 [expr {$cy + 62}] $uw 10 -fill $c(muted) -radius 3 }
		ui::box [expr {286 + $uw + ($uw > 0 ? 3 : 0)}] [expr {$cy + 62}] [expr {$bw - $uw - ($uw > 0 ? 3 : 0)}] 10 -fill $c(pill) -radius 3
		ui::hit 270 $cy $cw 88 [list apply {{dev x y} { page::pick_disk $dev }} [dict get $d dev]]
		ui::focusable disk-[dict get $d dev] choice 270 $cy $cw 88 12 [list page::disk_key [dict get $d dev]]
		set cy [expr {$cy + 98}]
	}
	if {$S(disktop) + $vis < $n} { ui::fade 270 [expr {$cy - 10 - 28}] $cw 28 }
	if {![llength [disks]]} { ui::text 270 $cy "No disk found to install on." i13 $c(muted); set cy [expr {$cy + 26}] }
	set g [games_part]
	if {$g ne ""} {
		lassign $g gd gp
		set on $S(games)
		ui::icon [expr {$on ? "check" : "plus"}] 13 [expr {$on ? $c(accent) : $c(muted)}] 270 [expr {$cy + 1}] [expr {$on ? 2.2 : 1.9}]
		ui::text 315 $cy "Use the [dict get $gd model] for games too (mounted, nothing erased)" i12 [expr {$on ? $c(fg) : $c(muted)}]
		ui::hit 270 [expr {$cy - 4}] 367 23 {apply {{x y} { set page::S(games) [expr {!$page::S(games)}]; page::draw }}}
		ui::focusable games choice 290 [expr {$cy - 3}] 375 21 6 {apply {{sym} { if {$sym eq "space"} { set page::S(games) [expr {!$page::S(games)}]; page::draw; return 1 }; return 0 }}}
	}
	# how
	set x 679
	ui::label $x $y How
	set d [disk]
	set model [dget $d model "the disk"]
	set win [shareable]
	set modes [list erase "Erase disk and install" "Everything on the $model is removed." ""]
	if {$win ne ""} {
		set os [osname [dget $win os]]
		lappend modes alongside "Install alongside $os" "Keep $os; pick it or Ribbon when you start the computer." ""
	}
	lappend modes manual "Manual partitioning" "Choose partitions yourself." advanced
	if {$S(mode) eq "alongside" && $win eq ""} { set S(mode) erase }
	set cy [expr {$y + 32}]
	foreach {key title desc bdg} $modes {
		set on [expr {$S(mode) eq $key}]
		set bg [expr {$on ? $c(field) : $c(bar)}]
		set lines [ui::wrap i13 $desc 305]
		set th [expr {$bdg ne "" ? 20 : 17}]
		set h [expr {24 + $th + 3 + 16 * [llength $lines]}]
		ui::box $x $cy 381 $h -fill $bg -radius 12 -ring [expr {$on ? [list $c(accent) 1.5] : [list $c(border) 1]}]
		ui::radio [expr {$x + 16}] [expr {$cy + 12}] $on $bg
		set tw [ui::text [expr {$x + 46}] [expr {$cy + 12 + ($th - 17) / 2.0}] $title i14s $c(fg)]
		if {$bdg ne ""} { ui::badge [expr {$x + 46 + $tw + 8}] [expr {$cy + 12}] $bdg 0 $bg }
		set ly [expr {$cy + 12 + $th + 3}]
		foreach l $lines { ui::text [expr {$x + 46}] $ly $l i13 $c(muted); set ly [expr {$ly + 16}] }
		ui::hit $x $cy 381 $h [list apply {{k x y} { set page::S(mode) $k; page::draw }} $key]
		ui::focusable mode-$key choice $x $cy 381 $h 12 [list apply {{k sym} { if {$sym eq "space"} { set page::S(mode) $k; page::draw; return 1 }; return 0 }} $key]
		set cy [expr {$cy + $h + 10}]
	}
	# what stops Continue here, as the Alongside page's notes show theirs
	if {[set why [mode_problem]] ne ""} {
		set ny [expr {$cy + 6}]
		ui::icon warn 14 $c(accent) $x [expr {$ny + 1}]
		foreach l [ui::wrap i13 $why 333] { ui::text [expr {$x + 48}] $ny $l i13 $c(muted); set ny [expr {$ny + 18}] }
	}
	footer Continue
}

# A disk card's keys: Space picks it; Up and Down go to the next card, scrolling the list.
proc page::disk_key {dev sym} {
	variable S
	set devs [lmap d [disks] { dict get $d dev }]
	set i [lsearch -exact $devs $dev]
	switch -- $sym {
		space { pick_disk $dev; return 1 }
		Up - Down {
			set j [expr {$sym eq "Up" ? $i - 1 : $i + 1}]
			if {$j < 0 || $j >= [llength $devs]} { return 1 }
			if {$j < $S(disktop)} { set S(disktop) $j }
			set vis [expr {max(1, int(($page::FL - 24 - ([games_part] ne "" ? 26 : 0) - [head_end] - 32 + 10) / 98))}]
			if {$j >= $S(disktop) + $vis} { set S(disktop) [expr {$j - $vis + 1}] }
			set ui::focus disk-[lindex $devs $j]
			draw
			return 1
		}
	}
	return 0
}

proc page::pick_disk {dev} {
	variable S
	if {$S(disk) eq $dev} return
	set S(disk) $dev
	set S(mandisk) $dev
	set S(games) 0
	reset_alongside
	reset_plan
	draw
}

# ---- 3b alongside -----------------------------------------------------------------

proc page::draw_alongside {} {
	variable S
	array set c [array get ui::c]
	set p [shareable]
	set full [dget [dget $p os] name Windows]
	set os [osname [dget $p os]]
	set y [head "Install alongside $os" "$os is made smaller to make room. Your $os files stay where they are."]
	set d [disk]
	ui::label 270 $y "Drag to share the [disk_title $d]"
	set T [along_total]
	set K $S(keep)
	set by [expr {$y + 22}]
	set ww [expr {max(32, 776.0 * $K / max(1, $T))}]
	ui::box 270 $by $ww 64 -fill $c(pill) -radius {12 0 0 12}
	set hx [expr {270 + $ww}]
	ui::box $hx $by 14 64 -fill $c(bar)
	ui::box [expr {$hx + 5}] [expr {$by + 18}] 4 28 -fill $c(accent) -radius 2
	set rx [expr {$hx + 14}]
	ui::gradbox $rx $by [expr {1060 - $rx}] 64 {0 12 12 0} 150 $c(accent) 0.45 $c(accent) 0.15
	ui::ring 270 $by 790 64 12 $c(border) 1
	ui::text 286 [expr {$by + 16}] $full i14s $c(fg)
	ui::text 286 [expr {$by + 33}] "[human $K] · [human [dget $p used 0]] used" i12 $c(muted)
	ui::text [expr {$rx + 16}] [expr {$by + 16}] Ribbon i14s $c(fg)
	ui::text [expr {$rx + 16}] [expr {$by + 33}] [human [expr {$T - $K}]] i12 $c(muted)
	ui::hit 270 $by 790 64 page::along_drag page::along_drag
	ui::focusable bar seg $hx $by 14 64 2 page::along_key
	# the two sizes
	lassign [along_limits] lo hi
	set fy [expr {$by + 82}]
	ui::label 270 $fy "$os keeps"
	ui::field keep 270 [expr {$fy + 22}] 367 -right [list page::gb_note [expr {round($lo / 1e9)}]] -onchange {page::along_typed keep}
	ui::label 689 $fy "Ribbon gets"
	ui::field ribbon 689 [expr {$fy + 22}] 367 -right [list page::gb_note [expr {round(($T - $hi) / 1e9)}]] -onchange {page::along_typed ribbon}
	# notes
	set ny [expr {$fy + 78}]
	set r [dget $p resize]
	if {[dget $r safe 1]} {
		set notes [list check "$os was shut down fully (not hibernated or Fast Startup), so it can be resized safely."]
	} else {
		# Windows can't be resized yet (Inst-12): the backend's reason, its first sentence over
		# what to do, and Check again, which asks the backend afresh
		set why [dget $r why "$os can't be resized right now."]
		if {![regexp {^(.*?[.:])\s+(.*)$} $why -> bold rest]} { set bold $why; set rest "" }
		set ny [expr {$ny + [strip 270 $ny 790 $bold $rest [list recheck "Check again" page::windows_ready]] + 10}]
		set notes {}
	}
	lappend notes restart "At start-up, choose Ribbon or $os from the menu. Ribbon is the default." \
		warn "Back up anything important first. Resizing is safe, but not risk-free."
	foreach {ic t} $notes {
		ui::icon $ic 14 [expr {$ic eq "restart" ? $c(muted) : $c(accent)}] 270 [expr {$ny + 1}]
		ui::text 294 $ny $t i13 $c(muted)
		set ny [expr {$ny + 26}]
	}
	footer Continue
}

proc page::gb_note {least x y} {
	array set c [array get ui::c]
	ui::text $x [expr {$y + 11}] "GB · at least $least" i13 $c(muted) e
}

proc page::along_key {sym} {
	variable S
	switch -- $sym {
		Left { set_keep [expr {$S(keep) - 1000000000}] }
		Right { set_keep [expr {$S(keep) + 1000000000}] }
		Prior { set_keep [expr {$S(keep) + 10000000000}] }
		Next { set_keep [expr {$S(keep) - 10000000000}] }
		default { return 0 }
	}
	return 1
}

# Re-check after the user restarted Windows (e.g. Fast Startup off).
proc page::windows_ready {} {
	variable probe
	set p [shareable]
	if {[catch {exec {*}[backend::cmd probe --windows-ready [dict get $p dev]] 2>@1} out]} { set out "" }
	set out [string trim $out]
	if {[catch {dict size $out}] || ![dict exists $out safe]} return
	# put the new resize facts into the probe
	set disks {}
	foreach d [dget $probe disks] {
		set parts {}
		foreach q [dget $d parts] {
			if {[dict get $q dev] eq [dict get $p dev]} { dict set q resize [dict merge [dget $q resize] $out] }
			lappend parts $q
		}
		dict set d parts $parts
		lappend disks $d
	}
	dict set probe disks $disks
	draw
}

# ---- 3c manual partitioning ------------------------------------------------------

proc page::draw_manual {} {
	variable S
	array set c [array get ui::c]
	set y [head "Manual partitioning" "Choose where everything goes. Nothing is written until you install."]
	set x 270
	foreach d [disks] {
		set on [expr {[dict get $d dev] eq $S(mandisk)}]
		set w [ui::badge $x $y [disk_title $d] $on]
		ui::hit $x $y $w 20 [list apply {{dev x y} { set page::S(mandisk) $dev; set page::S(mansel) -1; page::draw }} [dict get $d dev]]
		set x [expr {$x + $w + 10}]
	}
	set hy [expr {$y + 32}]
	# table header (STYLE §14): 34 tall, 12 px sentence case, a rule under it
	foreach {cx t} {282 Partition 444 Size 536 Format 638 Mount 740 Note 978 Erase} {
		ui::text $cx [expr {$hy + 10}] $t i12 $c(muted)
	}
	ui::hline 270 1060 [expr {$hy + 33}] $c(border)
	set ry [expr {$hy + 38}]
	# as many rows as leave the tools row 24 clear of the footer; more scroll (a thumb, the rows
	# 10 clear of it, a fade: Inst-5b's list)
	set rows [plan_rows]
	set n [llength $rows]
	set vis [expr {max(3, int(($page::FL - 24 - 38 - 12 - $ry) / 40))}]
	set S(mantop) [expr {max(0, min($S(mantop), $n - $vis))}]
	set RW 790
	if {$n > $vis} {
		set RW 776
		ui::thumb 1056 $ry [expr {$vis * 40}] $n $vis $S(mantop)
	}
	set k -1
	set y0 $ry
	foreach r $rows {
		incr k
		if {$k < $S(mantop) || $k >= $S(mantop) + $vis} continue
		set kind [dict get $r kind]
		set free [expr {$kind eq "free"}]
		if {$k == $S(mansel)} { ui::box 270 $ry $RW 40 -fill $c(field) -radius 8 }
		set col [expr {$free ? $c(muted) : $c(fg)}]
		ui::text 282 [expr {$ry + 12}] [expr {$free ? "free" : [dict get $r dev]}] i13s $col
		ui::text 444 [expr {$ry + 12}] [human [dict get $r size]] i13 $col
		ui::text 536 [expr {$ry + 12}] [fsname [dict get $r fs]] i13 $col
		ui::text 638 [expr {$ry + 12}] [dict get $r mount] i13s $c(fg)
		ui::text 740 [expr {$ry + 12}] [dict get $r note] i13 $c(muted)
		if {!$free} {
			set cy [expr {[dict get $r mount] eq "" ? $ry + 9.5 : $ry + 11}]
			ui::check 978 $cy [expr {[dict get $r format] || $kind eq "new"}]
			if {$kind eq "part"} { ui::hit 970 [expr {$ry + 4}] 34 32 [list apply {{k x y} { page::toggle_format $k }} $k] }
		}
		ui::hit 270 $ry $RW 40 [list page::row_click $k] "" ""
		set ry [expr {$ry + 40}]
	}
	if {$S(mantop) + $vis < $n} { ui::fade 270 [expr {$ry - 28}] $RW 28 }
	ui::wheel 270 $y0 790 [expr {$ry - $y0}] {apply {{d} { set page::S(mantop) [expr {max(0, $page::S(mantop) + $d)}]; page::draw }}}
	ui::focusable parts list 270 $y0 790 [expr {max(40, $ry - $y0)}] 8 page::row_key
	set ty [expr {$ry + 12}]
	set x 270
	set x [expr {$x + 8 + [ui::button new $x $ty New field page::part_new plus]}]
	set x [expr {$x + 8 + [ui::button edit $x $ty Edit field page::part_edit]}]
	ui::button delete $x $ty Delete field page::part_delete
	if {$S(manmsg) ne ""} { set ok 0; set msg [string toupper [string index $S(manmsg) 0]][string range $S(manmsg) 1 end] } else { lassign [plan_status] ok msg }
	# the plan's state, or why the backend's check refused it (Inst-13b), beside the buttons: up
	# to 440 wide, in lines centred on their row
	set lines [ui::wrap i13 $msg 440]
	set n [llength $lines]
	set lx [expr {1060 - ($n > 1 ? 440 : [ui::measure i13 $msg])}]
	ui::icon [expr {$ok ? "check" : "warn"}] 14 $c(accent) [expr {$lx - 22}] [expr {$ty + 12}] [expr {$ok ? 2.2 : 1.9}]
	set ly [expr {$ty + 20 - 9 * $n}]
	foreach l $lines { ui::text $lx $ly $l i13 [expr {$ok ? $c(muted) : $c(fg)}]; incr ly 18 }
	footer Continue
}

proc page::row_click {k x y} {
	variable S
	variable lastclick
	set now [clock milliseconds]
	set dbl [expr {[info exists lastclick] && [lindex $lastclick 0] == $k && $now - [lindex $lastclick 1] < 400}]
	set lastclick [list $k $now]
	set S(mansel) $k
	set ui::focus parts
	if {$dbl} { part_edit } else { draw }
}

proc page::row_key {sym} {
	variable S
	set n [llength [plan_rows]]
	switch -- $sym {
		Up { set S(mansel) [expr {max(0, $S(mansel) - 1)}] }
		Down { set S(mansel) [expr {min($n - 1, $S(mansel) + 1)}] }
		Prior { set S(mansel) [expr {max(0, $S(mansel) - 8)}] }
		Next { set S(mansel) [expr {min($n - 1, $S(mansel) + 8)}] }
		space - e { part_edit; return 1 }
		Delete { part_delete; return 1 }
		Insert - n { part_new; return 1 }
		default { return 0 }
	}
	# keep the selected row in view (the rows that fit: draw_manual's count)
	set vis [expr {max(3, int(($page::FL - 24 - 38 - 12 - [head_end] - 32 - 38) / 40))}]
	if {$S(mansel) >= 0} {
		if {$S(mansel) < $S(mantop)} { set S(mantop) $S(mansel) }
		if {$S(mansel) >= $S(mantop) + $vis} { set S(mantop) [expr {$S(mansel) - $vis + 1}] }
	}
	draw
	return 1
}

proc page::toggle_format {k} {
	variable S
	set rows [plan_rows]
	set r [lindex $rows $k]
	dict set r format [expr {![dict get $r format]}]
	lset rows $k $r
	set_plan_rows $rows
	set S(mansel) $k
	set S(manmsg) ""
	draw
}

proc page::part_new {} {
	variable S
	set rows [plan_rows]
	set k $S(mansel)
	if {$k < 0 || [dict get [lindex $rows $k] kind] ne "free"} {
		set k [lsearch -exact [lmap r $rows { dict get $r kind }] free]
		if {$k < 0} { set S(manmsg) "No free space on this disk: delete or shrink a partition first"; draw; return }
	}
	set S(mansel) $k
	set r [lindex $rows $k]
	set has_root 0
	dict for {d rs} $S(plan) { foreach x $rs { if {[dict get $x mount] eq "/"} { set has_root 1 } } }
	dialog_open new $k [expr {[dict get $r size] / 1e9}] btrfs [expr {$has_root ? "" : "/"}] 1
}

proc page::part_edit {} {
	variable S
	set rows [plan_rows]
	set k $S(mansel)
	if {$k < 0 || $k >= [llength $rows]} return
	set r [lindex $rows $k]
	if {[dict get $r kind] eq "free"} { part_new; return }
	dialog_open edit $k [expr {[dict get $r size] / 1e9}] [dict get $r fs] [dict get $r mount] [dict get $r format]
}

proc page::part_delete {} {
	variable S
	set rows [plan_rows]
	set k $S(mansel)
	if {$k < 0 || $k >= [llength $rows]} return
	set r [lindex $rows $k]
	if {[dict get $r kind] eq "free"} return
	set S(manmsg) ""
	if {[dict get $r kind] eq "part"} {
		# remembered, so the backend removes it
		dict set S(deleted) $S(mandisk) [lsort -unique [concat [dget [array get S] deleted] [list [dict get $r dev]]]]
	}
	lset rows $k [dict create kind free dev free start [dict get $r start] size [dict get $r size] fs "" format 0 mount "" note "free space"]
	set_plan_rows $rows
	set S(mansel) [expr {min($k, [llength [plan_rows]] - 1)}]
	draw
}

# ---- the New / Edit dialog ---------------------------------------------------------

proc page::dialog_open {kind k gb fs mount format} {
	variable dialog
	set dialog [dict create kind $kind row $k fs $fs format $format err ""]
	ui::fset dsize [regsub {\.0$} [format %.1f $gb] {}]
	ui::fset dmount $mount
	set ui::focus [expr {$kind eq "new" ? "dsize" : "dmount"}]
	draw
}

proc page::dialog_close {} {
	variable dialog {}
	set ui::focus parts
	draw
}

proc page::dialog_fs {fs} {
	variable dialog
	dict set dialog fs $fs
	if {$fs eq "vfat" && [ui::fval dmount] eq ""} { ui::fset dmount /boot }
	if {$fs eq "swap"} {
		ui::fset dmount ""
		if {$ui::focus eq "dmount"} { set ui::focus dfs }
	}
	draw
}

proc page::dialog_save {} {
	variable dialog
	variable S
	set rows [plan_rows]
	set k [dict get $dialog row]
	set r [lindex $rows $k]
	set mount [string trim [ui::fval dmount]]
	set fs [dict get $dialog fs]
	if {$mount ne "" && ![string match /* $mount]} { dict set dialog err "A mount point starts with /"; draw; return }
	if {$fs eq "swap"} { set mount "" }
	# a partition already there keeps its filesystem unless it is formatted
	set format [expr {[dict get $dialog kind] eq "new" || [dict get $dialog format] || ([dict get $r kind] eq "part" && $fs ne [dict get $r fs])}]
	if {$mount eq "/" && $fs ni {btrfs bcachefs}} { dict set dialog err "/ must be Btrfs"; draw; return }
	if {$format && $fs ni {btrfs bcachefs vfat swap}} { dict set dialog err "[fsname $fs] can't be formatted here"; draw; return }
	# one partition per mount point
	dict for {d rs} $S(plan) {
		set i 0
		foreach x $rs {
			if {$mount ne "" && [dict get $x mount] eq $mount && !($d eq $S(mandisk) && $i == $k)} { dict set dialog err "$mount is already used"; draw; return }
			incr i
		}
	}
	if {[dict get $dialog kind] eq "new"} {
		set gb [ui::fval dsize]
		if {![string is double -strict $gb] || $gb <= 0} { dict set dialog err "Size in GB, like 100"; draw; return }
		set size [expr {wide(min([dict get $r size], round($gb * 1e9)))}]
		# keep 1 MiB alignment
		set size [expr {$size / 1048576 * 1048576}]
		if {$size < 1048576} { dict set dialog err "Too small"; draw; return }
		set new [dict create kind new dev [next_part_name] start [dict get $r start] size $size fs $fs format 1 mount $mount note new]
		set rest [expr {[dict get $r size] - $size}]
		set repl [list $new]
		if {$rest >= 1048576} { lappend repl [dict create kind free dev free start [expr {[dict get $r start] + $size}] size $rest fs "" format 0 mount "" note "free space"] }
		set rows [lreplace $rows $k $k {*}$repl]
	} else {
		if {[dict get $r kind] eq "part" && $fs ne [dict get $r fs]} { dict set dialog format 1 }
		dict set r fs $fs
		dict set r mount $mount
		if {[dict get $r kind] eq "part"} { dict set r format [dict get $dialog format] }
		lset rows $k $r
	}
	set_plan_rows $rows
	set S(mansel) $k
	set S(manmsg) ""
	dialog_close
}

proc page::dialog_key {sym char state} {
	set f [ui::focused]
	lassign $f id kind
	switch -- $sym {
		Escape { dialog_close; return }
		Return - KP_Enter {
			if {$kind eq "button"} { uplevel #0 [lindex $f 7] } else { dialog_save }
			return
		}
		Tab { ui::cycle 1; return }
		ISO_Left_Tab { ui::cycle -1; return }
	}
	if {$kind eq "field"} { if {[ui::field_key $id $sym $char $state]} { draw }; return }
	if {$kind eq "button" && $sym eq "space"} { uplevel #0 [lindex $f 7]; return }
	if {$kind in {seg choice} && [uplevel #0 [list {*}[lindex $f 7] $sym]]} return
}

# STYLE §15's sheet (Inst-11, Inst-14b; kit's Kit-Sheet-*): 640 wide, centred on the window over
# the 50 % scrim (ui::dim), a 44 tile, the 20 px title over a 13 px line, BODYH of body under a
# rule, a 72 footer under a rule. Only the sheet takes clicks and Tab while it is open. Returns
# {x y L R fy}: its place, its text column and the footer's line.
proc page::sheet {icon title sub bodyh} {
	array set c [array get ui::c]
	set ui::hits {}; set ui::wheels {}; set ui::focusables {}
	ui::layer
	set w 640; set h [expr {88 + $bodyh + 72}]
	set x [expr {(1100 - $w) / 2}]; set y [expr {($ui::H - $h) / 2}]
	ui::box $x $y $w $h -fill $c(bar) -radius 16 -ring [list $c(border) 1] -shadow {24 64 0.6}
	ui::hit $x $y $w $h ""
	set L [expr {$x + 28}]; set R [expr {$x + $w - 28}]
	ui::gradbox $L [expr {$y + 26}] 44 44 12 160 $c(pill) 1 $c(field) 1
	ui::ring $L [expr {$y + 26}] 44 44 12 $c(border) 1
	ui::icon $icon 22 $c(fg) [expr {$L + 11}] [expr {$y + 37}] 1.7
	ui::text [expr {$L + 58}] [expr {$y + 25}] [clipt sg20 $title [expr {$R - $L - 58}]] sg20 $c(fg) w -0.4
	ui::text [expr {$L + 58}] [expr {$y + 53}] [clipt i13 $sub [expr {$R - $L - 58}]] i13 $c(muted)
	set fy [expr {$y + 88 + $bodyh}]
	if {$bodyh > 0} { ui::hline $L $R [expr {$y + 88}] $c(border) }
	ui::hline $x [expr {$x + $w}] $fy $c(border)
	list $x $y $L $R $fy
}

# The sheet's footer: Cancel (ghost) and the primary, right-aligned; returns the left one's x.
proc page::sheet_buttons {R fy cid cancel cscript pid primary pscript} {
	set pw [ui::button_w $primary primary]
	set px [expr {$R - $pw}]
	set cw [ui::button_w $cancel ghost]
	ui::button $cid [expr {$px - 10 - $cw}] [expr {$fy + 17}] $cancel ghost $cscript "" $cw
	ui::button $pid $px [expr {$fy + 17}] $primary primary $pscript "" $pw
}

# The New and Edit partition sheets (Inst-11, Inst-11b): New asks the size, the format and the
# mount point; Edit (the size is the partition's own, in the sheet's line) the format, the mount
# point and, for a partition already there, whether to erase it. Swap has no mount point. Why
# Save was refused is the footer's status.
proc page::dialog_draw {} {
	variable dialog
	variable S
	array set c [array get ui::c]
	set kind [dict get $dialog kind]
	set r [lindex [plan_rows] [dict get $dialog row]]
	set existing [expr {$kind eq "edit" && [dict get $r kind] eq "part"}]
	set fs [dict get $dialog fs]
	set mountrow [expr {$fs ne "swap"}]
	set bodyh [expr {18 + ($kind eq "new" ? 76 : 0) + 60 + ($mountrow ? 76 : 0) + ($existing ? 34 : 0) + 22}]
	set d [disk $S(mandisk)]
	if {$kind eq "new"} {
		lassign [sheet disk "New partition" [disk_title $d] $bodyh] x y L R fy
	} else {
		set sub "[disk_title $d] · [human [dict get $r size]]"
		if {[dict get $r note] ne "" && [dict get $r kind] eq "part"} { append sub " · [dict get $r note]" }
		lassign [sheet disk [dict get $r dev] $sub $bodyh] x y L R fy
	}
	set fw [expr {$R - $L}]
	set iy [expr {$y + 106}]
	if {$kind eq "new"} {
		ui::label $L $iy Size
		ui::field dsize $L [expr {$iy + 22}] $fw -right [list page::dlg_gb [human [dict get $r size]]]
		incr iy 76
	}
	ui::label $L $iy Format
	set opts {btrfs Btrfs vfat FAT32 swap swap}
	if {$fs ni {btrfs vfat swap} && $fs ne ""} { set opts [list $fs [fsname $fs] {*}$opts] }
	ui::seg dfs $L [expr {$iy + 22}] $fw $opts $fs page::dialog_fs
	incr iy 76
	if {$mountrow} {
		ui::label $L $iy "Mount point"
		ui::field dmount $L [expr {$iy + 22}] $fw
		incr iy 76
	}
	if {$existing} {
		set on [dict get $dialog format]
		ui::check $L $iy $on
		ui::text [expr {$L + 28}] [expr {$iy + 1}] "Erase and format it" i13 $c(fg)
		ui::hit [expr {$L - 4}] [expr {$iy - 4}] 160 26 {apply {{x y} { dict set page::dialog format [expr {![dict get $page::dialog format]}]; page::draw }}}
		ui::focusable dformat choice [expr {$L - 4}] [expr {$iy - 3}] 152 24 6 {apply {{sym} { if {$sym eq "space"} { dict set page::dialog format [expr {![dict get $page::dialog format]}]; page::draw; return 1 }; return 0 }}}
	}
	if {[dict get $dialog err] ne ""} {
		ui::icon warn 14 $c(accent) $L [expr {$fy + 29}]
		ui::text [expr {$L + 22}] [expr {$fy + 28}] [clipt i13 [dict get $dialog err] 380] i13 $c(fg)
	}
	sheet_buttons $R $fy dcancel Cancel page::dialog_close dsave Save page::dialog_save
	ui::focus_ring
}

proc page::dlg_gb {free x y} {
	array set c [array get ui::c]
	ui::text $x [expr {$y + 11}] "GB · $free free" i13 $c(muted) e
}

# ---- 4 disk set-up --------------------------------------------------------------------

proc page::draw_setup {} {
	variable S
	array set c [array get ui::c]
	set y [head "Disk set-up" "How Ribbon stores your files. The defaults suit almost everyone."]
	ui::label 270 $y Filesystem
	settle
	set fss {}
	foreach {k t d bdg} {
		btrfs Btrfs {Snapshots before every update; roll back from the boot menu} recommended
		zfs ZFS {Boot environments; native encryption} {}
		bcachefs bcachefs {Snapshots; native encryption} experimental
	} { if {$k in [fs_opts]} { lappend fss $k $t $d $bdg } }
	# one column of cards, as wide as the browser makes it (flex 1.25 of
	# the body); each has a 20 px title row
	set cx 270; set cw 423.33
	set gy [expr {$y + 32}]
	set ry $gy
	foreach {k t d bdg} $fss {
		set lines [ui::wrap i12 $d [expr {$cw - 56}]]
		set rh [expr {12 + 20 + 6 + 16.8 * [llength $lines] + 12}]
		set on [expr {$S(fs) eq $k}]
		set bg [expr {$on ? $c(field) : $c(bar)}]
		ui::box $cx $ry $cw $rh -fill $bg -radius 12 -ring [expr {$on ? [list $c(accent) 1.5] : [list $c(border) 1]}]
		ui::radio [expr {$cx + 14}] [expr {$ry + 13}] $on $bg
		set tw [ui::text [expr {$cx + 42}] [expr {$ry + 13.5}] $t i14s $c(fg)]
		if {$bdg ne ""} { ui::badge [expr {$cx + 42 + $tw + 10}] [expr {$ry + 12}] $bdg [expr {$bdg eq "recommended"}] $bg }
		set ly [expr {$ry + 38}]
		foreach l $lines { ui::text [expr {$cx + 42}] $ly $l i12 $c(muted); set ly [expr {$ly + 16.8}] }
		ui::hit $cx $ry $cw $rh [list apply {{k x y} { page::set_fs $k }} $k]
		ui::focusable fs-$k choice $cx $ry $cw $rh 12 [list apply {{k sym} { if {$sym eq "space"} { page::set_fs $k; return 1 }; return 0 }} $k]
		set ry [expr {$ry + $rh + 10}]
	}
	# encryption
	set x 721.33; set w 338.67
	ui::label $x $y Encryption
	set ey [expr {$y + 32}]
	set on $S(encrypt)
	# switched on, as tall as the filesystem cards, the fields at its foot
	set h [expr {$on ? $ry - 10 - $gy : 81}]
	set bg [expr {$on ? $c(field) : $c(bar)}]
	ui::box $x $ey $w $h -fill $bg -radius 12 -ring [expr {$on ? [list $c(accent) 1.5] : [list $c(border) 1]}]
	ui::icon lock 18 [expr {$on ? $c(accent) : $c(muted)}] [expr {$x + 16}] [expr {$ey + 31.5}]
	ui::text [expr {$x + 46}] [expr {$ey + 16}] "Encrypt the disk" i14s $c(fg)
	set ly [expr {$ey + 35}]
	foreach l [ui::wrap i12 "Asked once at start-up. Keeps your files safe if the computer is lost." [expr {$w - 112}]] {
		ui::text [expr {$x + 46}] $ly $l i12 $c(muted); set ly [expr {$ly + 15}]
	}
	ui::toggle [expr {$x + $w - 16 - 38}] [expr {$ey + 29.5}] $on
	ui::hit [expr {$x + $w - 60}] [expr {$ey + 22}] 50 36 {apply {{x y} { page::toggle_encrypt }}}
	ui::focusable encrypt choice [expr {$x + $w - 57}] [expr {$ey + 26.5}] 44 28 14 {apply {{sym} { if {$sym eq "space"} { page::toggle_encrypt; return 1 }; return 0 }}}
	if {$on} {
		set fx [expr {$x + 16}]; set fw [expr {$w - 32}]
		set fy [expr {$ey + $h - 16 - 107}]
		ui::field pass1 $fx $fy $fw -secret [expr {!$S(pshow)}] -ph "Passphrase" -right page::eye_pass
		ui::field pass2 $fx [expr {$fy + 46}] $fw -secret [expr {!$S(pshow)}] -ph "Repeat the passphrase" -right {page::match_note pass1 pass2}
		meter $fx [expr {$fy + 92}] $fw [ui::fval pass1]
	}
	footer Continue
}

proc page::set_fs {k {redraw 1}} {
	variable S
	set S(fs) $k
	if {$k eq "zfs"} { set S(boot) zfsbootmenu } elseif {$k eq "bcachefs" || $S(boot) eq "zfsbootmenu"} { set S(boot) limine }
	if {$redraw} draw
}

proc page::toggle_encrypt {} {
	variable S
	set S(encrypt) [expr {!$S(encrypt)}]
	set ui::focus [expr {$S(encrypt) ? "pass1" : ""}]
	draw
}

proc page::eye_pass {x y} {
	variable S
	array set c [array get ui::c]
	ui::icon [expr {$S(pshow) ? "eye-off" : "eye"}] 15 $c(muted) [expr {$x - 15}] [expr {$y + 11.5}]
	ui::hit [expr {$x - 19}] [expr {$y + 6}] 23 26 {apply {{x y} { set page::S(pshow) [expr {!$page::S(pshow)}]; page::draw }}}
	return 15
}

proc page::match_note {a b x y} {
	array set c [array get ui::c]
	set v [ui::fval $b]
	if {$v eq ""} { return 0 }
	if {$v eq [ui::fval $a] || [string first $v [ui::fval $a]] == 0 && $ui::focus eq $b} { return 0 }
	return [ui::text $x [expr {$y + 11}] "Doesn't match" i13 $c(accent) e]
}

# ---- 5 hardware ------------------------------------------------------------------------

proc page::driver_icon {cat} {
	dget {graphics chip wi-fi wifi wifi wifi processor cpu cpu cpu audio vol sound vol controller pad gamepad pad {fingerprint reader} finger fingerprint finger bluetooth bt ethernet net network net camera camera webcam camera printer printer display monitor} [string tolower $cat] chip
}

proc page::driver_text {d} {
	variable S
	set id [dict get $d id]
	set drv [dget $d driver]
	if {![dict exists $S(drivers) $id] || [llength [dget $d choices]] == 0} { return $drv }
	set ch [dict get $S(drivers) $id]
	if {$ch eq [dget $d default]} { return $drv }
	set label [lindex [lsearch -inline -index 0 [dget $d choices] $ch] 1]
	if {[regexp {^(.*)\(([^()]*)\)$} $drv -> pre]} { return "${pre}([string tolower $label])" }
	return $label
}

proc page::draw_hardware {} {
	variable S
	variable probe
	array set c [array get ui::c]
	settle
	set y [head "Hardware" "Drivers for everything found on this computer, and start-up settings. Change anything you like."]
	ui::label 270 $y "Drivers · found on this computer"
	set ry [expr {$y + 22}]
	set drivers [dget $probe drivers]
	# as many rows as leave room for the driver choices, swap and the boot
	# loader above the footer (24 px clear of it); more scroll (the wheel,
	# or Up and Down on the list), as on a laptop that finds a dozen devices
	set nc 0
	foreach d $drivers { if {[llength [dget $d choices]] && [dict get $d status] eq "install"} { incr nc } }
	set vis [expr {max(3, int(($page::FL - 24 - 122 - 48 * $nc - $ry) / 34))}]
	set n [llength $drivers]
	set S(drvtop) [expr {max(0, min($S(drvtop), $n - $vis))}]
	# a list that scrolls (Inst-5b): its thumb at the right edge, the rows 10 clear of it, a
	# fade at its foot while more is below
	set RE 1060
	set ly0 $ry
	if {$n > $vis} {
		set RE 1046
		ui::wheel 270 $ry 790 [expr {$vis * 34}] [list page::drv_scroll $n $vis]
		ui::focusable drivers list 270 $ry 790 [expr {$vis * 34}] 8 [list page::drv_key $n $vis]
		ui::thumb 1056 $ry [expr {$vis * 34}] $n $vis $S(drvtop)
	}
	set k -1
	foreach d $drivers {
		incr k
		if {$k < $S(drvtop) || $k >= $S(drvtop) + $vis} continue
		set st [dict get $d status]
		set id [dict get $d id]
		set skip [expr {$st eq "install" && ![dict exists $S(drivers) $id]}]
		ui::hline 270 $RE [expr {$ry + 33}] $c(border)
		ui::icon [driver_icon [dget $d category]] 15 $c(muted) 280 [expr {$ry + 9.5}]
		ui::text 300 [expr {$ry + 9}] [dget $d category] i13 $c(muted)
		ui::text 442 [expr {$ry + 9}] [clipt i13s [dget $d device] 296] i13s $c(fg)
		ui::text 754 [expr {$ry + 9}] [clipt i13 [driver_text $d] [expr {$RE - 854}]] i13 $c(muted)
		switch $st {
			install {
				if {$skip} { ui::badge $RE [expr {$ry + 7}] "skipped" 0 $c(bar) e } else { ui::badge $RE [expr {$ry + 7}] "will install" 0 $c(bar) e }
				ui::hit [expr {$RE - 88}] $ry 84 34 [list apply {{d x y} { page::toggle_driver $d }} $d]
				ui::focusable drv-$id choice [expr {$RE - 94}] [expr {$ry + 3}] 92 28 8 [list apply {{d sym} { if {$sym eq "space"} { page::toggle_driver $d; return 1 }; return 0 }} $d]
			}
			builtin { ui::badge $RE [expr {$ry + 7}] "built in" 0 $c(bar) e }
			default { ui::badge $RE [expr {$ry + 7}] "not supported" 0 $c(bar) e }
		}
		set ry [expr {$ry + 34}]
	}
	if {$S(drvtop) + $vis < $n} { ui::fade 270 [expr {$ry - 28}] [expr {$RE - 270}] 28 }
	if {![llength $drivers]} { ui::text 270 [expr {$ry + 9}] "Nothing here needs a driver of its own." i13 $c(muted); set ry [expr {$ry + 34}] }
	foreach d $drivers {
		if {![llength [dget $d choices]] || [dict get $d status] ne "install"} continue
		set ry [expr {$ry + 10}]
		set id [dict get $d id]
		ui::text 270 [expr {$ry + 11.5}] "[lindex [dget $d device] 0] driver" i12 $c(muted)
		set opts {}
		foreach ch [dget $d choices] { lappend opts {*}$ch }
		set cur [expr {[dict exists $S(drivers) $id] ? [dict get $S(drivers) $id] : ""}]
		ui::seg choice-$id 442 $ry 618 $opts $cur [list page::set_driver $id]
		set ry [expr {$ry + 38}]
	}
	# swap and boot loader
	set sy [expr {$ry + 18}]
	ui::label 270 $sy Swap
	ui::seg swap 270 [expr {$sy + 22}] 437 [swap_opts] $S(swap) page::set_swap
	set ty [expr {$sy + 70}]
	set ram [machine ram 0]
	set ramgb [expr {round($ram / 1073741824.0)}]
	set tx 270
	if {$S(swap) eq "custom"} {
		ui::field swapgb 270 $ty 92 -right {apply {{x y} { ui::text $x [expr {$y + 11}] GB i13 $ui::c(muted) e }}} -onchange page::swap_typed
		set tx 372
	}
	# the sizes postinstall will use (swap_plan)
	set game [swap_plan gaming $ram $S(fs)]
	set big [string trimright [dict get $game file] G]
	set hib [string trimright [dict get [swap_plan hibernate $ram $S(fs)] file] G]
	set lines [dget [list \
		zram [list "Compressed swap in memory (50% of RAM)." "Nothing is written to the disk."] \
		gaming [expr {[dict get $game file] eq "off" ?
			[list "Compressed swap in memory (100% of RAM)," "so the biggest games never run out of memory."] :
			[list "zram, plus a $big GB swap file," "so the biggest games never run out of memory."]}] \
		hibernate [list "zram, plus a $hib GB swap file the size of RAM," "so the computer can hibernate."] \
		custom [list "swap file, plus zram (50% of RAM)." "$ramgb GB of RAM here; $big GB file suits big games."] \
		none [list "No swap at all." "If memory fills up, apps are closed."]] $S(swap)]
	set ly [expr {$ty + 2.2}]
	foreach l $lines { ui::text $tx $ly $l i12 $c(muted); set ly [expr {$ly + 16.8}] }
	set bx 736; set bw 324
	ui::label $bx $sy "Boot loader"
	set opts [boot_opts]
	switch $S(fs) {
		zfs { set note "ZFS starts with ZFSBootMenu: boot environments and snapshots." }
		bcachefs { set note "bcachefs starts with Limine." }
		default { set note [expr {[llength $opts] > 2 ? "Limine is fast and simple. GRUB finds other systems itself." : "Limine is fast and simple."}] }
	}
	ui::seg boot $bx [expr {$sy + 22}] $bw $opts $S(boot) {apply {{k} { set page::S(boot) $k; page::draw }}}
	set ly [expr {$ty + 1}]
	foreach l [ui::wrap i12 $note $bw] { ui::text $bx $ly $l i12 $c(muted); set ly [expr {$ly + 17.4}] }
	footer Continue
}

proc page::clipt {f t w} {
	if {[ui::measure $f $t] <= $w} { return $t }
	while {$t ne "" && [ui::measure $f "$t…"] > $w} { set t [string range $t 0 end-1] }
	return "$t…"
}

proc page::drv_scroll {n vis d} {
	variable S
	set S(drvtop) [expr {max(0, min($n - $vis, $S(drvtop) + $d))}]
	draw
}

proc page::drv_key {n vis sym} {
	switch -- $sym {
		Up { drv_scroll $n $vis -1 } Down { drv_scroll $n $vis 1 }
		Prior { drv_scroll $n $vis -$vis } Next { drv_scroll $n $vis $vis }
		default { return 0 }
	}
	return 1
}

proc page::toggle_driver {d} {
	variable S
	set id [dict get $d id]
	if {[dict exists $S(drivers) $id]} { dict unset S(drivers) $id } else { dict set S(drivers) $id [dget $d default] }
	draw
}

proc page::set_driver {id k} {
	variable S
	dict set S(drivers) $id $k
	draw
}

proc page::set_swap {k} {
	variable S
	set S(swap) $k
	if {$k eq "custom"} { set ui::focus swapgb } elseif {$ui::focus eq "swapgb"} { set ui::focus swap }
	draw
}

proc page::swap_typed {} {
	variable S
	set v [ui::fval swapgb]
	if {[string is double -strict $v] && $v > 0} { set S(swapsize) [expr {wide($v * 1e9)}] }
}

# ---- 6 apps -------------------------------------------------------------------------------

proc page::draw_apps {} {
	variable S
	array set c [array get ui::c]
	set y [head Apps "A head start. Everything else is one search away later."]
	set tiles {}
	foreach {id name what} $data::apps {
		# the text column and the check share what the 36 px icon leaves,
		# shrinking as a flex row does when the text is too long
		set m [expr {max([ui::measure i14s $name], [ui::measure i12 $what])}]
		set tw 86.0; set cw 20.0
		if {$m > 86} { set tw [expr {106.0 * $m / ($m + 20)}]; set cw [expr {106.0 - $tw}] }
		set lines [ui::wrap i12 $what $tw]
		set ch [expr {max(36, 17 + 15 * [llength $lines])}]
		lappend tiles [list $id $name $lines $tw $cw $ch]
	}
	set ty $y
	for {set row 0} {$row * 4 < [llength $tiles]} {incr row} {
		set rt [lrange $tiles [expr {$row * 4}] [expr {$row * 4 + 3}]]
		set rh 0
		foreach t $rt { set rh [expr {max($rh, [lindex $t 5] + 24)}] }
		set col 0
		foreach t $rt {
			lassign $t id name lines tw cw ch
			set tx [expr {270 + $col * 200}]
			set on [expr {$id in $S(apps)}]
			set bg [expr {$on ? $c(field) : $c(bar)}]
			ui::box $tx $ty 190 $rh -fill $bg -radius 12 -ring [expr {$on ? [list $c(accent) 1.5] : [list $c(border) 1]}]
			set iy [expr {$ty + 12 + ($ch - 36) / 2.0}]
			ui::gradbox [expr {$tx + 12}] $iy 36 36 9 150 $c(accent) [expr {$on ? 0.85 : 0.35}] $c(accent) 0.1
			ui::text [expr {$tx + 30}] [expr {$iy + 7.5}] [string index $name 0] sg16b $c(ink) c
			set th [expr {17 + 15 * [llength $lines]}]
			set ly [expr {$ty + 12 + ($ch - $th) / 2.0}]
			ui::text [expr {$tx + 60}] $ly $name i14s $c(fg)
			set ly [expr {$ly + 17}]
			foreach l $lines { ui::text [expr {$tx + 60}] $ly $l i12 $c(muted); set ly [expr {$ly + 15}] }
			set kx [expr {$tx + 12 + 166 - $cw}]
			set ky [expr {$ty + 12 + ($ch - 20) / 2.0}]
			ui::box $kx $ky $cw 20 -fill [expr {$on ? $c(accent) : $c(pill)}] -radius 6
			if {$on} { ui::icon check 12 $c(ink) [expr {$kx + ($cw - 12) / 2.0}] [expr {$ky + 4}] 2.6 }
			ui::hit $tx $ty 190 $rh [list apply {{id x y} { page::toggle_app $id }} $id]
			ui::focusable app-$id choice $tx $ty 190 $rh 12 [list apply {{id sym} { if {$sym eq "space"} { page::toggle_app $id; return 1 }; return 0 }} $id]
			incr col
		}
		set ty [expr {$ty + $rh + 10}]
	}
	set ny [expr {$ty - 10 + 16}]
	footer Continue
}

proc page::toggle_app {id} {
	variable S
	if {$id in $S(apps)} { set S(apps) [lsearch -all -inline -not -exact $S(apps) $id] } else {
		set S(apps) [lmap {i n w} $data::apps { if {$i in $S(apps) || $i eq $id} { set i } else continue }]
	}
	draw
}

# ---- 7 you --------------------------------------------------------------------------------

proc page::draw_you {} {
	variable S
	array set c [array get ui::c]
	set y [head You "Your account. The password is also used for system changes."]
	# picture
	set aw [expr {max(96, [ui::measure i12 "Choose a picture"])}]
	set ax [expr {270 + ($aw - 96) / 2.0}]
	set ay [expr {$y + 22}]
	if {$S(picture) ne "" && ![catch {avatar_photo $S(picture)} ph]} {
		$ui::img copy $ph -to [expr {round($ax)}] [expr {round($ay)}]
		set ring [raster::cached [list avatar-mask [ui::col $c(bar)]] {
			set rows {}
			lassign [raster::rgb [ui::col $c(bar)]] r g b
			for {set j 0} {$j < 96} {incr j} {
				set row {}
				for {set i 0} {$i < 96} {incr i} { lappend row $r $g $b [expr {int((1 - [raster::rbox [expr {$i + 0.5}] [expr {$j + 0.5}] 0 0 96 96 48]) * 255 + 0.5)}] }
				lappend rows $row
			}
			raster::png 96 96 $rows
		}]
		raster::blit $ui::img $ring 0 0 96 96 [expr {round($ax)}] [expr {round($ay)}]
	} else {
		ui::gradbox $ax $ay 96 96 round 150 $c(accent) 1.0 $c(accent) 0.35
		set letter [string toupper [string index [string trim [ui::fval fullname]] 0]]
		if {$letter eq ""} { ui::icon user 40 $c(ink) [expr {$ax + 28}] [expr {$ay + 28}] 1.9 } else {
			ui::text [expr {$ax + 48}] [expr {$ay + 22.5}] $letter sg40 $c(ink) c
		}
	}
	ui::text [expr {270 + $aw / 2.0}] [expr {$ay + 106}] "Choose a picture" i12 $c(muted) c
	ui::hit 270 $ay $aw 122 {apply {{x y} { page::choose_picture }}}
	ui::focusable picture button [expr {$ax}] $ay 96 96 48 page::choose_picture
	# the form
	set x [expr {270 + $aw + 36}]; set w 460
	set tried [expr {[info exists S(youtried)] && $S(youtried)}]
	ui::label $x $y "Your name"
	ui::field fullname $x [expr {$y + 22}] $w -onchange page::name_typed
	ui::label $x [expr {$y + 74}] "User name"
	ui::field username $x [expr {$y + 96}] $w -onchange {apply {{} { set page::S(userauto) [expr {[ui::fval username] eq ""}]; page::derive_user }}} -right page::user_note
	ui::label $x [expr {$y + 148}] Password
	set pw [expr {($w - 10) / 2.0}]
	ui::field upass1 $x [expr {$y + 170}] $pw -secret [expr {!$S(ushow)}] -right page::eye_user
	ui::field upass2 [expr {$x + $pw + 10}] [expr {$y + 170}] $pw -secret [expr {!$S(ushow)}] -ph [expr {[ui::fval upass1] eq "" ? "" : "Repeat it"}] -right {page::match_note upass1 upass2}
	meter $x [expr {$y + 216}] $w [ui::fval upass1]
	ui::label $x [expr {$y + 245}] "Computer name"
	ui::field hostname $x [expr {$y + 267}] $w -onchange {apply {{} { set page::S(hostauto) [expr {[ui::fval hostname] eq ""}] }}}
	# log in automatically: switch, label and note share the row (flex)
	set ry [expr {$y + 319}]
	set note ""
	set m1 [ui::measure i14 "Log in automatically"]; set m2 [ui::measure i12 $note]
	set avail [expr {$w - 38 - 24}]
	if {$m1 + $m2 > $avail} {
		set o [expr {$m1 + $m2 - $avail}]
		set w1 [expr {$m1 - $o * $m1 / ($m1 + $m2)}]; set w2 [expr {$m2 - $o * $m2 / ($m1 + $m2)}]
	} else { set w1 $m1; set w2 $m2 }
	set l1 [ui::wrap i14 "Log in automatically" $w1]
	set l2 [ui::wrap i12 $note $w2]
	set rh [expr {max(22, 17 * [llength $l1], 15 * [llength $l2])}]
	ui::toggle $x [expr {$ry + ($rh - 22) / 2.0}] $S(autologin)
	set ly [expr {$ry + ($rh - 17 * [llength $l1]) / 2.0}]
	foreach l $l1 { ui::text [expr {$x + 50}] $ly $l i14 $c(fg); set ly [expr {$ly + 17}] }
	set ly [expr {$ry + ($rh - 15 * [llength $l2]) / 2.0}]
	foreach l $l2 { ui::text [expr {$x + 50 + $w1 + 12}] $ly $l i12 $c(muted); set ly [expr {$ly + 15}] }
	ui::hit $x $ry [expr {50 + $w1}] $rh {apply {{x y} { set page::S(autologin) [expr {!$page::S(autologin)}]; page::draw }}}
	ui::focusable autologin choice [expr {$x - 3}] [expr {$ry + ($rh - 22) / 2.0 - 3}] 44 28 14 {apply {{sym} { if {$sym eq "space"} { set page::S(autologin) [expr {!$page::S(autologin)}]; page::draw; return 1 }; return 0 }}}
	footer Continue
}

proc page::name_typed {} { derive_user }

proc page::user_note {x y} {
	array set c [array get ui::c]
	if {[ui::fval username] eq ""} { return 0 }
	set why [user_problem]
	if {$why eq ""} { ui::icon check 14 $c(accent) [expr {$x - 14}] [expr {$y + 10.5}] 2.2; return 14 }
	return [ui::text $x [expr {$y + 11}] $why i13 $c(accent) e]
}

proc page::eye_user {x y} {
	variable S
	array set c [array get ui::c]
	ui::icon [expr {$S(ushow) ? "eye-off" : "eye"}] 15 $c(muted) [expr {$x - 15}] [expr {$y + 11.5}]
	ui::hit [expr {$x - 19}] [expr {$y + 6}] 23 26 {apply {{x y} { set page::S(ushow) [expr {!$page::S(ushow)}]; page::draw }}}
	return 15
}

proc page::choose_picture {args} {
	variable S
	set f [chooser::open_file -parent $::app::win -title "Choose a picture" -filetypes {{Pictures {.png .gif}}} \
		-initialdir [expr {[file isdirectory ~/Pictures] ? [file normalize ~/Pictures] : [file normalize ~]}]]
	if {$f ne "" && ![catch {avatar_photo $f}]} { set S(picture) $f }
	draw
}

# The picture scaled down to cover 96 x 96 (centre crop).
proc page::avatar_photo {f} {
	variable avatars
	if {[info exists avatars($f)]} { return $avatars($f) }
	set src [image create photo -file $f]
	set w [image width $src]; set h [image height $src]
	set k [expr {max(1, int(min($w, $h) / 96))}]
	set small [image create photo]
	$small copy $src -subsample $k $k
	image delete $src
	set w [image width $small]; set h [image height $small]
	set out [image create photo -width 96 -height 96]
	set x0 [expr {max(0, ($w - 96) / 2)}]; set y0 [expr {max(0, ($h - 96) / 2)}]
	$out copy $small -from $x0 $y0 [expr {min($w, $x0 + 96)}] [expr {min($h, $y0 + 96)}] -to 0 0
	image delete $small
	set avatars($f) $out
}

# ---- 8 summary ------------------------------------------------------------------------------

proc page::summary_rows {} {
	variable S
	variable probe
	set lang [lindex [lsearch -inline -exact -index 1 [lmap {n e l} $data::languages { list $n $l }] $S(lang)] 0]
	set lay [lindex $data::layouts [expr {$S(layout) * 3}]]
	set d [disk]
	set how [dict get {erase {erase and install} manual {manual partitions}} [expr {$S(mode) eq "alongside" ? "erase" : $S(mode)}]]
	if {$S(mode) eq "alongside"} {
		set how "alongside [osname [dget [shareable] os]] (it keeps [human $S(keep)])"
	}
	set fsl [dict get {btrfs {Btrfs with snapshots} zfs {ZFS with boot environments} bcachefs bcachefs} $S(fs)]
	set setup "$fsl · [expr {$S(encrypt) ? "encrypted" : "not encrypted"}] · 15 GB kept for the system"
	if {$S(mode) eq "manual"} { set setup "[expr {$S(encrypt) ? "encrypted" : "not encrypted"}] · 15 GB kept for the system" }
	set hw {}
	foreach dr [dget $probe drivers] {
		if {[string tolower [dget $dr category]] ne "graphics" || ![dict exists $S(drivers) [dict get $dr id]]} continue
		set t [driver_text $dr]
		if {[regexp {^([^,]+),\s*([^(]*?)\s*(\(.*\))?$} $t -> vendor kind]} { lappend hw "$vendor ($kind)" } else { lappend hw $t }
	}
	set gb [expr {round($S(swapsize) / 1e9)}]
	lappend hw [dict get [list zram {zram swap} gaming {gaming swap} hibernate {swap for hibernation} custom "$gb GB swap file" none {no swap}] $S(swap)]
	lappend hw [dict get {limine Limine grub GRUB zfsbootmenu ZFSBootMenu} $S(boot)]
	set apps [lmap {i n w} $data::apps { if {$i in $S(apps)} { set n } else continue }]
	list \
		globe {Language and region} "$lang · $lay keyboard · $S(tz)" welcome \
		disk Disk "[disk_title $d] · $how" disk \
		lock {Disk set-up} $setup setup \
		chip Hardware [join $hw " · "] hardware \
		box Apps [expr {[llength $apps] ? [join $apps ", "] : "None"}] apps \
		user Account "[ui::fval fullname] ([ui::fval username]) on [ui::fval hostname]" you
}

proc page::draw_summary {} {
	variable S
	array set c [array get ui::c]
	set y [head "Ready to install" "Check everything. Nothing has changed yet."]
	set ry $y
	foreach {ic t d p} [summary_rows] {
		ui::hline 270 1060 [expr {$ry + 51}] $c(border)
		ui::icon $ic 17 $c(muted) 274 [expr {$ry + 17.5}]
		ui::text 305 [expr {$ry + 17.5}] $t i14s $c(fg)
		set cw [expr {[ui::measure i13m Change] + 28}]
		ui::text 489 [expr {$ry + 18}] [clipt i13 $d [expr {1046 - $cw - 14 - 489}]] i13 $c(muted)
		ui::cbutton change-$p [expr {1060 - 4}] [expr {$ry + 9}] Change [list apply {{p} { set page::S(summary_return) 1; page::go $p }} $p] e
		set ry [expr {$ry + 52}]
	}
	set wy [expr {$ry + 18}]
	set d [disk]
	set model [dget $d model "the disk"]
	set os [dget [lindex [dget $d os] 0] name]
	switch $S(mode) {
		erase { set bold "Everything on the $model will be erased"; set rest [expr {$os ne "" ? ", including $os." : "."}] }
		alongside { set bold "[dget [dget [shareable] os] name Windows] will be made smaller"; set rest " to make room. Back up first." }
		manual {
			set n 0
			dict for {dv rows} $S(plan) { foreach r $rows { if {[dict get $r kind] eq "new" || [dict get $r format]} { incr n } } }
			set bold "$n partition[expr {$n == 1 ? "" : "s"}] will be erased"; set rest " (those ticked Erase)."
		}
	}
	if {$S(checkmsg) ne ""} {
		# the backend's check refused the answers (Inst-13): its reason under the strip's line
		strip 270 $wy 790 "The installer can't use these answers" [string toupper [string index $S(checkmsg) 0]][string range $S(checkmsg) 1 end]
		footer [dict get {erase {Erase and install} alongside Install manual Install} $S(mode)] ""
		return
	}
	set soft [ui::mix $c(accent) $c(bar) 0.16]
	ui::box 270 $wy 790 46 -fill $soft -radius 12 -ring [list [ui::mix $c(accent) $soft 0.5] 1]
	ui::icon warn 18 $c(accent) 293 [expr {$wy + 14}]
	set bw [ui::text 318 [expr {$wy + 14.5}] $bold i14s $c(fg)]
	ui::text [expr {318 + $bw}] [expr {$wy + 14.5}] [clipt i14 $rest [expr {724 - $bw}]] i14 $c(fg)
	footer [dict get {erase {Erase and install} alongside Install manual Install} $S(mode)] ""
}

# ---- 9 installing ----------------------------------------------------------------------------

proc page::step_names {} {
	variable S
	set out {{Preparing the disk}}
	if {$S(encrypt)} { lappend out Encrypting }
	lappend out {Copying Ribbon} {Setting up the system} {Boot loader} {Your account}
}

proc page::draw_progress {} {
	variable S
	array set c [array get ui::c]
	if {$S(err) ne ""} {
		set y [head "Something went wrong" "[string trimright $S(err) .]. Nothing more is changed."]
	} else {
		set y [head Installing "You can keep using the live desktop meanwhile."]
	}
	ui::text 270 $y "$S(pct)%" sg54 $c(fg) w -1.62
	ui::text 649 [expr {$y + 40}] $S(eta) i13 $c(muted) e
	ui::box 270 [expr {$y + 79}] 379 8 -fill $c(field) -radius 4
	if {$S(pct) > 0} { ui::box 270 [expr {$y + 79}] [expr {max(8, 379 * $S(pct) / 100.0)}] 8 -fill $c(accent) -radius 4 }
	set names [step_names]
	set cur [lsearch -exact $names $S(stepname)]
	if {$S(done)} { set cur [llength $names] }
	set ry [expr {$y + 109}]
	set k 0
	foreach n $names {
		set st [expr {$k < $cur ? "done" : ($k == $cur ? "now" : "")}]
		if {$st eq "done"} {
			ui::box 270 [expr {$ry + 7}] 20 20 -fill $c(soft) -radius 10
			ui::icon check 11 $c(accent) 274.5 [expr {$ry + 11.5}] 2.6
		} elseif {$st eq "now" && $S(err) ne ""} {
			ui::icon warn 18 $c(accent) 271 [expr {$ry + 8}]
		} else {
			ui::box 270 [expr {$ry + 7}] 20 20 -fill $c(bar) -radius 10 -ring [list [expr {$st eq "now" ? $c(accent) : $c(pill)}] 2]
		}
		ui::text 302 [expr {$ry + 8.5}] $n [expr {$st eq "now" ? "i14s" : "i14"}] [expr {$st eq "" ? $c(muted) : $c(fg)}]
		set ry [expr {$ry + 34}]
		incr k
	}
	# details
	set x 681
	ui::label $x $y Details
	set lh [expr {$ry - $y - 30}]
	ui::box $x [expr {$y + 30}] 379 $lh -fill $c(d2) -radius 12 -ring [list $c(border) 1]
	set n [expr {int(($lh - 28) / 20.4)}]
	# white space runs fold to one, as in the mockup's log; long lines wrap
	set shown {}
	foreach l $S(log) {
		set l [regsub -all {\s+} [string trim $l] " "]
		while {[string length $l] > 46} {
			# at the last space that fits, else where the line is full
			set k [string last " " $l 45]
			if {$k < 8} { set k 46 }
			lappend shown [string trimright [string range $l 0 [expr {$k - 1}]]]
			set l "  [string trimleft [string range $l $k end]]"
		}
		lappend shown $l
	}
	set all [llength $shown]
	set top [expr {$S(logtop) < 0 ? max(0, $all - $n) : min($S(logtop), max(0, $all - $n))}]
	set ly [expr {$y + 44}]
	foreach l [lrange $shown $top [expr {$top + $n - 1}]] {
		ui::text 695 [expr {$ly + 3}] $l mono12 $c(muted)
		set ly [expr {$ly + 20.4}]
	}
	set S(logshown) $all
	ui::wheel $x [expr {$y + 30}] 363 $lh [list page::log_wheel $n]
	ui::focusable details list $x [expr {$y + 30}] 363 $lh 12 [list page::log_key $n]
	if {$S(err) ne ""} {
		set w [ui::button_w Close ghost]
		ui::button close [expr {1060 - $w}] $page::FB Close ghost {exit 1} "" $w
	} else {
		ui::text 1060 [expr {$page::FB + 9}] "Do not turn the computer off" i13 $c(muted) e
	}
}

proc page::log_wheel {n d} {
	variable S
	set all [expr {[info exists S(logshown)] ? $S(logshown) : [llength $S(log)]}]
	set top [expr {$S(logtop) < 0 ? max(0, $all - $n) : $S(logtop)}]
	set top [expr {max(0, $top + $d)}]
	set S(logtop) [expr {$top >= $all - $n ? -1 : $top}]
	draw
}

proc page::log_key {n sym} {
	switch -- $sym {
		Up { log_wheel $n -1 } Down { log_wheel $n 1 } Prior { log_wheel $n -$n } Next { log_wheel $n $n }
		End { set page::S(logtop) -1; draw }
		default { return 0 }
	}
	return 1
}

# Start the install: answers to a file, secrets on stdin.
proc page::start {} {
	variable S
	set S(started) [clock milliseconds]
	set S(pct) 0; set S(log) {}; set S(stepname) [lindex [step_names] 0]; set S(eta) ""
	go progress
	set secrets [list passphrase [expr {$S(encrypt) ? [ui::fval pass1] : ""}] password [ui::fval upass1]]
	backend::install [answers] $secrets page::progress_line
}

# One line from the backend.
proc page::progress_line {line} {
	variable S
	set word [lindex [split $line] 0]
	set rest [string trim [string range $line [string length $word] end]]
	switch -- $word {
		STEP {
			if {[regexp {^(\d+)\s+(\d+)\s+(.*)$} $rest -> i n title]} { set S(stepname) [unbrace $title] }
		}
		PROGRESS {
			if {[regexp {^(\d+)\s*(.*)$} $rest -> p text]} {
				set S(pct) [expr {min(100, max(0, $p))}]
				set S(eta) [eta]
			}
		}
		LOG { lappend S(log) $rest; if {[llength $S(log)] > 2000} { set S(log) [lrange $S(log) end-1999 end] } }
		DONE { set S(done) 1; set S(pct) 100; after 600 {page::go done}; return }
		ERROR { set S(err) [unbrace $rest]; set S(closing) 0; lappend S(log) "ERROR: $S(err)" }
		EXIT {
			set S(closing) 0
			lassign $line - rc msg
			if {!$S(done) && $S(err) eq ""} { set S(err) [expr {$msg ne "" ? $msg : "The installer stopped (exit status $rc)."}] }
		}
		default { if {$line ne ""} { lappend S(log) $line } }
	}
	if {$S(page) eq "progress"} draw
}

proc page::unbrace {t} {
	if {![catch {llength $t} n] && $n == 1} { return [lindex $t 0] }
	return $t
}

proc page::eta {} {
	variable S
	if {$S(pct) < 3} { return "" }
	set el [expr {([clock milliseconds] - $S(started)) / 1000.0}]
	set left [expr {$el / $S(pct) * (100 - $S(pct))}]
	if {$left < 50} { return "less than a minute left" }
	set m [expr {round($left / 60.0)}]
	if {$m <= 1} { return "about a minute left" }
	return "about $m minutes left"
}

# ---- 10 done ----------------------------------------------------------------------------------

proc page::draw_done {} {
	array set c [array get ui::c]
	variable TOP
	variable GAP
	variable FL
	head "" ""
	set lines [ui::wrap i14 "Remove the install media when the screen goes dark. Your apps install the first time you are online." 460]
	set h [expr {84 + 16 + 46 + 16 + 21 * [llength $lines] + 16 + 48}]
	# centred in the body: from under the empty title and subtitle (their
	# 6 px apart and GAP below) to the footer's line
	set top [expr {$TOP + 6 + $GAP}]
	set y [expr {$top + ($FL - $top - $h) / 2.0}]
	ui::box 623 $y 84 84 -fill $c(accent) -radius 42
	ui::icon check 40 $c(ink) 645 [expr {$y + 22}] 2.6
	ui::text 665 [expr {$y + 100}] "Ribbon is installed" sg36 $c(fg) c -0.72
	set ly [expr {$y + 162}]
	foreach l $lines { ui::text 665 [expr {$ly + 2}] $l i14 $c(muted) c; set ly [expr {$ly + 21}] }
	set by [expr {$ly + 26}]
	set g [ui::button_w "Keep trying the live desktop" ghost]
	set p [ui::button_w "Restart now" primary restart]
	set bx [expr {665 - ($g + 10 + $p) / 2.0}]
	ui::button keep $bx $by "Keep trying the live desktop" ghost {exit 0} "" $g
	ui::button restart [expr {$bx + $g + 10}] $by "Restart now" primary page::restart restart $p
	if {$ui::focus eq ""} { set ui::focus restart }
}

# ---- closing the window while installing (Inst-14b) -------------------------------------

# The close button while the install runs: a sheet asks. Stopping takes the backend down with the
# window (it is stopped, and its progress pipe closes); keeping on is the default.
proc page::close_ask {} {
	variable S
	if {$S(closing)} return
	set S(closing) 1
	set ui::focus keep
	set ui::kbd 0
	draw
}

proc page::close_draw {} {
	variable S
	array set c [array get ui::c]
	set model [dget [disk] model "the disk"]
	lassign [sheet warn "Stop installing?" "The $model is left half installed and won’t start." 0] x y L R fy
	ui::text $L [expr {$fy + 28}] "$S(pct)%[expr {$S(stepname) ne "" ? " · $S(stepname)" : ""}]" i13 $c(muted)
	sheet_buttons $R $fy stop "Stop installing" page::close_stop keep "Keep installing" page::close_keep
	ui::focus_ring
}

proc page::close_keep {} {
	variable S
	set S(closing) 0
	set ui::focus ""
	draw
}

proc page::close_stop {} {
	backend::stop
	exit 1
}

proc page::close_key {sym} {
	set f [ui::focused]
	switch -- $sym {
		Escape { close_keep }
		Return - KP_Enter - space { if {[lindex $f 1] eq "button"} { uplevel #0 [lindex $f 7] } else { close_keep } }
		Tab - Right { ui::cycle 1 }
		ISO_Left_Tab - Left { ui::cycle -1 }
	}
}

# ---- the check of the computer could not run (Inst-15) -----------------------------------

# The probe failed (the password prompt refused, or it stopped): say so, with what it said,
# instead of an empty computer. Try again runs it again.
proc page::probe_failed {why detail} {
	variable S
	set S(probefail) [list $why $detail]
	go noprobe
}

proc page::reprobe {} {
	variable S
	set S(probefail) {}
	go welcome
	backend::start_probe page::probed page::probe_failed
}

proc page::draw_noprobe {} {
	variable S
	array set c [array get ui::c]
	lassign $S(probefail) why detail
	set y [head "The installer can't read this computer" $why]
	ui::label 270 $y Details
	ui::box 270 [expr {$y + 22}] 790 160 -fill $c(d2) -radius 12 -ring [list $c(border) 1]
	set shown {}
	foreach l [split [string trim $detail] \n] {
		set l [regsub -all {\s+} [string trim $l] " "]
		while {[string length $l] > 104} { lappend shown [string range $l 0 103]; set l "  [string range $l 104 end]" }
		lappend shown $l
	}
	set ly [expr {$y + 36}]
	foreach l [lrange $shown end-6 end] { ui::text 284 [expr {$ly + 3}] $l mono12 $c(muted); set ly [expr {$ly + 20.4}] }
	set w [ui::button_w "Try again" primary]
	ui::button continue [expr {1060 - $w}] $page::FB "Try again" primary page::reprobe "" $w
	set cw [ui::button_w Close ghost]
	ui::button close [expr {1060 - $w - 10 - $cw}] $page::FB Close ghost {exit 1} "" $cw
	if {$ui::focus eq ""} { set ui::focus continue }
}

proc page::restart {} {
	if {[catch {exec loginctl reboot 2>@1} err]} {
		catch {exec {*}[backend::priv] reboot}
	}
	exit 0
}

# ---- the answers file ----------------------------------------------------------------------

proc page::answers {} {
	variable S
	settle
	set lay [lrange $data::layouts [expr {$S(layout) * 3}] [expr {$S(layout) * 3 + 2}]]
	set keymap [expr {[lindex $lay 2] eq "" ? [lindex $lay 1] : [list [lindex $lay 1] [lindex $lay 2]]}]
	set a [list version 1 locale $S(lang) keymap $keymap timezone $S(tz) disk $S(disk) mode $S(mode)]
	if {$S(mode) eq "alongside"} { lappend a alongside [list part [dget [shareable] dev] keep $S(keep)] }
	if {$S(mode) eq "manual"} {
		set m {}
		dict for {dev rows} $S(plan) {
			foreach r $rows {
				switch [dict get $r kind] {
					part { lappend m [list dev [dict get $r dev] format [dict get $r format] fs [dict get $r fs] mount [dict get $r mount]] }
					new { lappend m [list new 1 disk $dev start [dict get $r start] size [dict get $r size] format 1 fs [dict get $r fs] mount [dict get $r mount]] }
				}
			}
			if {[info exists S(deleted)] && [dict exists $S(deleted) $dev]} {
				foreach p [dict get $S(deleted) $dev] { lappend m [list dev $p delete 1] }
			}
		}
		lappend a manual $m
	}
	lappend a fs $S(fs) encrypt $S(encrypt) bootloader $S(boot)
	set sw [list mode $S(swap)]
	if {$S(swap) eq "custom"} { lappend sw size $S(swapsize) }
	lappend a swap $sw drivers $S(drivers) apps $S(apps)
	set games {}
	if {$S(games) && [set g [games_part]] ne ""} {
		lassign $g gd gp
		set name [string tolower [regsub -all {[^A-Za-z0-9_-]} [dget $gp label games] ""]]
		lappend games [list dev [dict get $gp dev] name [expr {$name eq "" ? "games" : $name}]]
	}
	lappend a games $games
	set u [list fullname [string trim [ui::fval fullname]] name [ui::fval username] hostname [ui::fval hostname] autologin $S(autologin)]
	if {$S(picture) ne ""} { lappend u picture $S(picture) }
	lappend a user $u
	# one key per line, as in the protocol's examples
	set out ""
	foreach {k v} $a { append out [list $k $v] \n }
	return $out
}
