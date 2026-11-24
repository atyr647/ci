# about.tcl - what Settings → About shows (page-about.tcl draws it), with no Tk: the system's name and version, whether
# updates wait, this computer (name, model, processor, memory, graphics) and the system (kernel, desktop, disk, firmware,
# the day it was installed), and the one change the page makes: the computer's name.
#
# Where it comes from. A file gives the answer wherever one can, read under RIBBON_ABOUT_ROOT when that is set (tests):
#   name, version   /etc/os-release (else /usr/lib/os-release): NAME without a closing " OS" (else PRETTY_NAME), VERSION_ID
#   updates         kit's cache file $XDG_CACHE_HOME/kit/updates, the file the bar's chip and Settings' rail read
#                   (shell/status.tcl, rail.tcl): "up to date" or "N updates"; nothing is said when it is not there
#   Name            /proc/sys/kernel/hostname (else /etc/hostname)
#   Model           /sys/class/dmi/id/product_name, with the maker (sys_vendor) before it when the name does not carry
#                   it; a closing "(...)" is dropped; Lenovo's name is in product_version. A board with no DMI:
#                   /sys/firmware/devicetree/base/model. A placeholder ("To Be Filled By O.E.M.") is no model: no row
#   Processor       /proc/cpuinfo: the first "model name" without (R), (TM), "CPU", "@ 2.80GHz", "8-Core Processor" and
#                   "w/ Radeon ... Graphics", then "· N threads" (the processors listed)
#   Memory          /proc/meminfo MemTotal, lifted to the size the machine was sold with (the kernel keeps a little back)
#   Graphics        /sys/class/drm/card*/device/{vendor,device} looked up in pci.ids (/usr/share/hwdata, /usr/share/misc):
#                   the name in brackets when there is one, else the maker and the device's name, else the maker; several
#                   cards are joined by " · "
#   Kernel          /proc/sys/kernel/osrelease, its numbers: "Linux 6.18.58"
#   Desktop         `labwc --version` (asked once, not waited for) and "· Wayland"
#   Disk            the disk under / (/proc/self/mountinfo, then /sys/dev/block, through device-mapper and a partition to
#                   the whole disk) and what is free on / (`df -Pk /`, asked again when the page is looked at): decimal
#                   units, "1 TB · 412 GB free"
#   Firmware        /sys/class/dmi/id/bios_version and "· UEFI" when /sys/firmware/efi is there, else "· BIOS"
#   Installed       when / was made (`stat -c %W /`); where the filesystem keeps no birth time, the older of
#                   /etc/machine-id and /lost+found; no row when none is known or the date cannot be right
# A row whose value is not known is left out. Nothing here waits for a command: the three that are run (labwc, df, stat)
# answer later and about::onchange is called when an answer changes what is shown.
#
#   about::start                 read the files, ask the commands (the first call only)
#   about::refresh               ask for the free space again (at most every 15 s) and read the name again
#   about::model                 dict: name version updates ("" | N) status subtitle hostname busy
#                                computer {{label value} ...} system {{label value} ...}
#   about::details               every row as "Label: value" lines (Copy details)
#   about::valid_name NAME       1 when NAME can be a computer's name (an RFC 1123 label: letters, digits, hyphens, 1..63)
#   about::set_name NAME         change the name: `pkexec ribbon-hostname-helper set NAME`, not waited for; the name shown
#                                stays as it was unless the helper succeeds, and about::error says why when it does not
#   about::onchange              a script the page sets: called when what is shown changed
#
# Tests (tests/settings-about.tcl): RIBBON_ABOUT_ROOT (the files), RIBBON_ABOUT_LABWC, RIBBON_ABOUT_DF, RIBBON_ABOUT_STAT
# (commands in place of labwc, df and stat), RIBBON_ABOUT_PCIIDS (a pci.ids), and, only with RIBBON_ABOUT_TEST set,
# RIBBON_ABOUT_PKEXEC and RIBBON_ABOUT_HELPER in place of pkexec and /usr/bin/ribbon-hostname-helper.

namespace eval about {
	variable onchange ""
	variable started 0
	variable error ""        ;# why the last change of the name failed
	variable busy 0          ;# the name is being changed
	variable F               ;# what the files said: model processor memory graphics kernel firmware disk fallback
	array set F {}
	variable labwc ""        ;# labwc's version
	variable birth ""        ;# seconds: when / was made
	variable df {}           ;# {total free} of /, bytes
	variable dfat 0          ;# when df was last asked
	variable seq 0
	variable timeout 5000    ;# ms a command gets to answer
	variable buf
	array set buf {}
	variable pci ""          ;# pci.ids, read once
	variable pciread 0
}

# ---- reading --------------------------------------------------------------------------------------

proc about::root {} {
	if {![info exists ::env(RIBBON_ABOUT_ROOT)]} { return "" }
	string trimright $::env(RIBBON_ABOUT_ROOT) /
}

# A file's text under the root, at most MAX bytes; "" when it cannot be read.
proc about::slurp {path {max 65536}} {
	set f [root]$path
	if {[catch {::open $f r} fh]} { return "" }
	set t ""
	catch {
		fconfigure $fh -encoding utf-8 -translation lf
		set t [::read $fh $max]
	}
	catch {::close $fh}
	return $t
}

# One line of text, fit to show: no control characters, runs of blanks as one, at most MAX characters.
proc about::clean {s {max 80}} {
	regsub -all {[\u0000-\u001f\u007f]} $s " " s
	regsub -all {\s+} [string trim $s] " " s
	string range $s 0 [expr {$max - 1}]
}
proc about::line {path} { clean [lindex [split [slurp $path 4096] \n] 0] }

# What a command prints, later: DONE is called with its output, "" when it failed, is missing or took too long.
proc about::run {cmd done} {
	variable seq; variable buf; variable timeout
	if {[catch {::open "|[list {*}$cmd 2>/dev/null]" r} ch]} { after idle [list {*}$done ""]; return }
	set id [incr seq]
	set buf($id) ""
	fconfigure $ch -blocking 0 -encoding utf-8 -translation lf
	set timer [after $timeout [list about::run_end $id $ch "" $done 1]]
	fileevent $ch readable [list about::run_read $id $ch $timer $done]
}
proc about::run_read {id ch timer done} {
	variable buf
	if {[catch {append buf($id) [::read $ch]}] || [eof $ch]} { run_end $id $ch $timer $done 0 }
}
proc about::run_end {id ch timer done late} {
	variable buf
	after cancel $timer
	catch {fileevent $ch readable {}}
	set out $buf($id)
	unset buf($id)
	if {$late} {
		set out ""
		catch {::close $ch}
	} else {
		# its exit status says whether to believe it
		catch {fconfigure $ch -blocking 1}
		if {[catch {::close $ch}]} { set out "" }
	}
	uplevel #0 [list {*}$done $out]
}
proc about::tool {var default} {
	expr {[info exists ::env($var)] && $::env($var) ne "" ? $::env($var) : $default}
}
proc about::changed {} {
	variable onchange
	if {$onchange ne ""} { uplevel #0 $onchange }
}

# ---- the system's name and version -----------------------------------------------------------------

proc about::os_release {} {
	set d [dict create]
	foreach f {/etc/os-release /usr/lib/os-release} {
		set t [slurp $f]
		if {$t eq ""} continue
		foreach l [split $t \n] {
			if {![regexp {^\s*([A-Z][A-Z0-9_]*)=(.*)$} $l -> k v]} continue
			set v [string trim $v]
			if {[regexp {^"(.*)"$} $v -> q]} {
				set v [string map [list "\\\"" "\"" "\\\\" "\\" "\\\$" "\$" "\\`" "`"] $q]
			} elseif {[regexp {^'(.*)'$} $v -> q]} { set v $q }
			dict set d $k $v
		}
		break
	}
	return $d
}

# {name version}: "Ribbon" and "0.9".
proc about::os {} {
	set d [os_release]
	set name ""
	foreach k {NAME PRETTY_NAME} {
		if {[dict exists $d $k] && [clean [dict get $d $k] 40] ne ""} { set name [clean [dict get $d $k] 40]; break }
	}
	regsub {\s+OS$} $name "" name
	if {$name eq ""} { set name Ribbon }
	set version [expr {[dict exists $d VERSION_ID] ? [clean [dict get $d VERSION_ID] 24] : ""}]
	list $name $version
}

# The updates waiting, from kit's cache file: a number, or "" when kit has not written one (or it cannot be read as
# what kit writes). Not the bar's "notify": About says what is so, not what the bar is allowed to show.
proc about::updates {} {
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/"}]
	set cache [expr {[info exists ::env(XDG_CACHE_HOME)] && $::env(XDG_CACHE_HOME) ne "" ? $::env(XDG_CACHE_HOME) : "$home/.cache"}]
	if {[catch {::open [file join $cache kit updates] r} fh]} { return "" }
	set text ""
	catch { fconfigure $fh -encoding utf-8; set text [::read $fh 4194304] }
	catch {::close $fh}
	if {[catch {dict get $text updates} ups] || [catch {llength $ups} n]} { return "" }
	return $n
}

# "Version 0.9 · up to date"
proc about::status {version updates} {
	set parts {}
	if {$version ne ""} { lappend parts "Version $version" }
	if {$updates ne ""} {
		lappend parts [expr {$updates == 0 ? "up to date" : $updates == 1 ? "1 update" : "$updates updates"}]
	}
	join $parts " · "
}

# ---- this computer -------------------------------------------------------------------------------

proc about::hostname {} {
	foreach f {/proc/sys/kernel/hostname /etc/hostname} {
		set h [line $f]
		if {$h ne "" && $h ne "(none)"} { return $h }
	}
	if {[root] eq "" && ![catch {info hostname} h]} { return [clean $h] }
	return ""
}

proc about::valid_name {name} {
	regexp {^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$} $name
}

# A DMI field, "" when the maker left a placeholder in it.
proc about::dmi {key} {
	set v [line /sys/class/dmi/id/$key]
	set l [string tolower $v]
	if {$l in {{} {to be filled by o.e.m.} {to be filled by o.e.m} {system product name} {system manufacturer}
		{system version} {system serial number} {default string} {not applicable} {not specified} {not available}
		none n/a oem o.e.m. unknown empty invalid undefined {type1productconfigid} {all series} {no enclosure}
		{chassis manufacture} {base board product name} {base board manufacturer}}} { return "" }
	if {[regexp {^([0x.\- ])\1*$} $l]} { return "" }
	return $v
}

# The maker as it is said: "Dell Inc." is Dell, "ASUSTeK COMPUTER INC." is ASUS.
proc about::maker {v} {
	set known {
		asustek ASUS asus ASUS micro-star MSI msi MSI lenovo Lenovo hewlett-packard HP hp HP dell Dell acer Acer
		gigabyte Gigabyte samsung Samsung toshiba Toshiba huawei Huawei microsoft Microsoft apple Apple
		framework Framework sony Sony fujitsu Fujitsu google Google razer Razer qemu QEMU intel Intel
		{advanced micro devices} AMD nvidia NVIDIA
	}
	set l [string tolower $v]
	foreach {k name} $known {
		if {$l eq $k || [string match "$k *" $l] || [string match "$k,*" $l]} { return $name }
	}
	set v " [string map {, { }} $v] "
	while {[regsub -nocase {\s(inc|corp|corporation|co|ltd|limited|llc|gmbh|ag|computer|computers|technology|technologies|electronics|international)\.?\s} $v " " v]} {}
	clean [string trim $v " ,."] 40
}

proc about::model_name {} {
	set vendor [dmi sys_vendor]
	set name [dmi product_name]
	if {[string equal -nocase [maker $vendor] Lenovo]} {
		# Lenovo's product_name is the type number; the name people know is the version
		set ver [dmi product_version]
		if {$ver ne ""} { set name $ver }
	}
	if {$name eq ""} {
		# a board described by a device tree
		set dt [clean [string map [list \0 ""] [slurp /sys/firmware/devicetree/base/model 512]]]
		return $dt
	}
	regsub {\s*\([^()]*\)\s*$} $name "" short
	if {$short ne ""} { set name $short }
	# the maker before a name that does not say it ("XPS 13 9310" is a Dell; "HP EliteBook" says so itself)
	set m [maker $vendor]
	set words [split [string tolower [regsub -all {[^A-Za-z0-9]+} $name " "]]]
	if {$m ne "" && [string tolower [lindex [split $m] 0]] ni $words} { set name "$m $name" }
	clean $name 60
}

# "AMD Ryzen 7 7840U": the processor's name as it is sold.
proc about::cpu_name {s} {
	regsub -all -nocase {\((r|tm|c)\)} $s "" s
	regsub -nocase {\s+@\s.*$} $s "" s
	regsub -nocase {\s+(w/|with)\s+Radeon.*$} $s "" s
	regsub -nocase {\s+[A-Za-z0-9]+-Core Processor\s*$} $s "" s
	regsub -nocase {\s+(CPU|Processor)\s*$} $s "" s
	regsub {\s+CPU\s+(?=[A-Z]?\d)} $s " " s
	regsub -nocase {^\d+(st|nd|rd|th) Gen\s+} $s "" s
	clean $s 60
}

# {name threads graphics}: graphics is the "Radeon 780M" an AMD processor's own name carries, "" otherwise.
proc about::cpu {} {
	set t [slurp /proc/cpuinfo 4194304]
	set raw ""
	regexp -line {^model name[ \t]*:[ \t]*(.+)$} $t -> raw
	set n [regexp -all -line {^processor\s*:} $t]
	set gfx ""
	if {[regexp -nocase {(?:w/|with)\s+(Radeon\s+\S.*?)\s+Graphics} $raw -> g]} { set gfx [clean $g 40] }
	list [cpu_name $raw] $n $gfx
}
proc about::processor {} {
	lassign [cpu] name n
	set parts {}
	if {$name ne ""} { lappend parts $name }
	if {$n > 0} { lappend parts [expr {$n == 1 ? "1 thread" : "$n threads"}] }
	join $parts " · "
}

# MemTotal (kB) as the size on the box: the next whole GB up to 8, the next even one up to 32, then steps of 8 and 32.
proc about::memory_of {kb} {
	if {![string is wideinteger -strict $kb] || $kb <= 0} { return "" }
	set g [expr {$kb / 1048576.0}]
	if {$g <= 0.75} { return "[expr {int(ceil($kb / 1024.0 / 64.0) * 64)}] MB" }
	set step [expr {$g <= 8 ? 1 : $g <= 32 ? 2 : $g <= 128 ? 8 : 32}]
	return "[expr {int(ceil($g / $step - 0.001)) * $step}] GB"
}
proc about::memory {} {
	if {![regexp -line {^MemTotal:\s+(\d+)\s*kB} [slurp /proc/meminfo] -> kb]} { return "" }
	memory_of $kb
}

# pci.ids, once.
proc about::pci_ids {} {
	variable pci; variable pciread
	if {$pciread} { return $pci }
	set pciread 1
	set files {/usr/share/hwdata/pci.ids /usr/share/misc/pci.ids /usr/share/pci.ids}
	if {[info exists ::env(RIBBON_ABOUT_PCIIDS)] && $::env(RIBBON_ABOUT_PCIIDS) ne ""} { set files [list $::env(RIBBON_ABOUT_PCIIDS)] }
	foreach f $files {
		if {[catch {::open $f r} fh]} continue
		catch { fconfigure $fh -encoding utf-8 -translation lf; set pci [::read $fh 8388608] }
		catch {::close $fh}
		if {$pci ne ""} break
	}
	return $pci
}
# {vendor-name device-name} of two four-digit hex ids; "" for what pci.ids does not know.
proc about::pci_lookup {ven dev} {
	set t [pci_ids]
	if {![regexp -line -indices "^${ven}  (.+)\$" $t all vn]} { return {{} {}} }
	set vendor [string range $t {*}$vn]
	set at [expr {[lindex $all 1] + 2}]
	set device ""
	while {$at < [string length $t]} {
		set e [string first \n $t $at]
		if {$e < 0} { set e [string length $t] }
		set l [string range $t $at [expr {$e - 1}]]
		set at [expr {$e + 1}]
		set c [string index $l 0]
		if {$c eq "#" || $l eq ""} continue
		if {$c ne "\t"} break
		if {[string range $l 1 6] eq "$dev  "} { set device [string range $l 7 end]; break }
	}
	list [clean $vendor] [clean $device]
}
proc about::gpu_name {ven dev cpugfx} {
	lassign [pci_lookup $ven $dev] vendor device
	if {$vendor eq ""} { return "" }
	# the maker: its short name in brackets ("[AMD/ATI]"), else its name without "Corporation"
	if {[regexp {\[([^\]/]+)[^\]]*\]\s*$} $vendor -> short]} { set m [clean $short 24] } else { set m [maker $vendor] }
	if {$device eq ""} { return $m }
	if {[regexp {\[([^\]]+)\]\s*$} $device -> sold]} {
		# "UHD Graphics" is said with its maker
		if {$ven eq "8086" && ![string match -nocase *intel* $sold]} { set sold "Intel $sold" }
		return [clean $sold 60]
	}
	# no name it is sold by in pci.ids: an AMD processor's own name has it ("w/ Radeon 780M Graphics")
	if {$ven eq "1002" && $cpugfx ne ""} { return $cpugfx }
	clean "$m $device" 60
}
proc about::graphics {} {
	set out {}
	set seen {}
	set cards {}
	foreach d [glob -nocomplain -directory [root]/sys/class/drm card*] {
		if {[regexp {^card(\d+)$} [file tail $d] -> n]} { lappend cards [list $n $d] }
	}
	set cpugfx [lindex [cpu] 2]
	foreach c [lsort -integer -index 0 $cards] {
		set d [lindex $c 1]
		set ids {}
		foreach k {vendor device} {
			set v ""
			if {![catch {::open $d/device/$k r} fh]} { catch { set v [string trim [::read $fh 64]] }; catch {::close $fh} }
			if {![regexp -nocase {^(?:0x)?([0-9a-f]{4})$} $v -> hex]} { set ids {}; break }
			lappend ids [string tolower $hex]
		}
		if {[llength $ids] != 2} continue
		# two cards of one device (a card and its render node's twin) are one
		set real $d
		catch { set real [file dirname [file normalize $d/device/vendor]] }
		if {$real in $seen} continue
		lappend seen $real
		set name [gpu_name {*}$ids $cpugfx]
		if {$name eq ""} continue
		if {$name eq $cpugfx} { set cpugfx "" }
		lappend out $name
	}
	join $out " · "
}

# ---- the system ----------------------------------------------------------------------------------

proc about::kernel {} {
	set r [line /proc/sys/kernel/osrelease]
	if {$r eq ""} { return "" }
	if {[regexp {^\d+(\.\d+)*} $r v]} { return "Linux $v" }
	return "Linux [string range $r 0 31]"
}

proc about::desktop {} {
	variable labwc
	if {$labwc ne ""} { return "labwc $labwc · Wayland" }
	# labwc did not answer: say what the session is, when it says
	if {[info exists ::env(WAYLAND_DISPLAY)] && $::env(WAYLAND_DISPLAY) ne ""} { return Wayland }
	return ""
}
proc about::got_labwc {out} {
	variable labwc
	set v ""
	regexp {(\d+(?:\.\d+)+)} $out -> v
	if {$v ne $labwc} { set labwc $v; changed }
}

# Bytes in decimal units, as disks are sold: "1 TB", "1.5 TB", "412 GB", "7.4 GB", "512 MB".
proc about::size {bytes} {
	if {$bytes >= 999.5e9} { set v [expr {$bytes / 1e12}]; set u TB } \
	elseif {$bytes >= 999.5e6} { set v [expr {$bytes / 1e9}]; set u GB } \
	else { return "[expr {int(round($bytes / 1e6))}] MB" }
	if {$u eq "GB" && $v >= 9.95} { return "[expr {int(round($v))}] GB" }
	set s [::format %.1f $v]
	regsub {\.0$} $s "" s
	return "$s $u"
}

# The whole disk under /, in bytes; "" when / is not on one (a network root, memory).
proc about::disk_bytes {} {
	set node ""
	set src ""
	foreach l [split [slurp /proc/self/mountinfo 1048576] \n] {
		# id parent major:minor root mount-point options ... - type source options
		if {[lindex [split $l] 4] ne "/"} continue
		set dev [lindex [split $l] 2]
		set src ""
		regexp { - \S+ (\S+)} $l -> src
	}
	if {![info exists dev]} { return "" }
	set sys [root]/sys
	if {[file exists $sys/dev/block/$dev/size]} { set node $sys/dev/block/$dev } elseif {[string match /dev/* $src]} {
		# btrfs and the like give / a device number of their own: go by the source's name
		set name [file tail $src]
		if {[file exists $sys/class/block/$name/size]} { set node $sys/class/block/$name } else {
			foreach d [glob -nocomplain $sys/class/block/dm-*] {
				if {[string trim [slurp [string range $d/dm/name [string length [root]] end] 256]] eq $name} { set node $d; break }
			}
		}
	}
	if {$node eq ""} { return "" }
	# through device-mapper (encryption, LVM) to what it sits on, then from a partition to its disk
	for {set i 0} {$i < 8} {incr i} {
		set under [lsort [glob -nocomplain -directory $node/slaves *]]
		if {![llength $under]} break
		set node [lindex $under 0]
	}
	if {[catch {file dirname [file normalize $node/size]} real]} { return "" }
	if {[file exists $real/partition] && [file exists [file dirname $real]/size]} { set real [file dirname $real] }
	if {[catch {::open $real/size r} fh]} { return "" }
	set n ""
	catch { set n [string trim [::read $fh 64]] }
	catch {::close $fh}
	if {![string is wideinteger -strict $n] || $n <= 0} { return "" }
	expr {$n * 512}
}

proc about::disk {} {
	variable F; variable df
	lassign $df total free
	set whole $F(disk)
	if {$whole eq "" && $total ne "" && $total > 0} { set whole $total }
	set parts {}
	if {$whole ne ""} { lappend parts [size $whole] }
	if {$free ne ""} { lappend parts "[size $free] free" }
	join $parts " · "
}
proc about::ask_df {} {
	variable dfat
	set dfat [clock seconds]
	run [list {*}[tool RIBBON_ABOUT_DF df] -Pk [root]/] about::got_df
}
proc about::got_df {out} {
	variable df
	set new {}
	# Filesystem 1024-blocks Used Available Capacity Mounted on
	if {[regexp {\s(\d+)\s+(\d+)\s+(\d+)\s+\d+%\s[^\n]*\s*$} $out -> total used avail]} {
		set new [list [expr {wide($total) * 1024}] [expr {wide($avail) * 1024}]]
	}
	if {$new ne $df} { set df $new; changed }
}

proc about::firmware {} {
	set v [dmi bios_version]
	set efi [file isdirectory [root]/sys/firmware/efi]
	if {$v eq ""} { return [expr {$efi ? "UEFI" : ""}] }
	return "[string range $v 0 39] · [expr {$efi ? "UEFI" : "BIOS"}]"
}

# A date an installation can have: after 2001, not in the future.
proc about::plausible {t} {
	expr {[string is wideinteger -strict $t] && $t > 978307200 && $t <= [clock seconds] + 86400}
}
proc about::installed {} {
	variable birth
	set t $birth
	if {![plausible $t]} {
		set t ""
		foreach f {/etc/machine-id /lost+found} {
			if {[catch {file mtime [root]$f} m] || ![plausible $m]} continue
			if {$t eq "" || $m < $t} { set t $m }
		}
	}
	if {$t eq ""} { return "" }
	string trim [clock format $t -format {%e %B %Y} -locale en]
}
proc about::got_birth {out} {
	variable birth
	set v [string trim $out]
	if {![plausible $v]} { set v "" }
	if {$v ne $birth} { set birth $v; changed }
}

# ---- the model -----------------------------------------------------------------------------------

proc about::start {} {
	variable started; variable F
	if {$started} return
	set started 1
	set F(model) [model_name]
	set F(processor) [processor]
	set F(memory) [memory]
	set F(graphics) [graphics]
	set F(kernel) [kernel]
	set F(firmware) [firmware]
	set F(disk) [disk_bytes]
	run [list {*}[tool RIBBON_ABOUT_LABWC labwc] --version] about::got_labwc
	run [list {*}[tool RIBBON_ABOUT_STAT stat] -c %W [root]/] about::got_birth
	ask_df
}

proc about::refresh {} {
	variable started; variable dfat
	if {!$started} { start; return }
	if {[clock seconds] - $dfat >= 15} { ask_df }
}

proc about::model {} {
	variable F; variable busy
	start
	lassign [os] name version
	set updates [updates]
	set computer {}
	set host [hostname]
	if {$host ne ""} { lappend computer [list Name $host] }
	foreach {label key} {Model model Processor processor Memory memory Graphics graphics} {
		if {$F($key) ne ""} { lappend computer [list $label $F($key)] }
	}
	set system {}
	foreach {label value} [list Kernel $F(kernel) Desktop [desktop] Disk [disk] Firmware $F(firmware) Installed [installed]] {
		if {$value ne ""} { lappend system [list $label $value] }
	}
	set sub [string trim "$name $version"]
	if {$F(model) ne ""} { append sub " on $F(model)" }
	dict create name $name version $version updates $updates status [status $version $updates] subtitle $sub \
		hostname $host busy $busy computer $computer system $system
}

# Every row as text, for a bug report or a forum.
proc about::details {} {
	set m [model]
	set lines [list "Version: [string trim "[dict get $m name] [dict get $m version]"]"]
	foreach r [concat [dict get $m computer] [dict get $m system]] { lappend lines "[lindex $r 0]: [lindex $r 1]" }
	join $lines \n
}

# ---- the computer's name: pkexec ribbon-hostname-helper -------------------------------------------
# The helper (apps/settings/bin/ribbon-hostname-helper) takes one name and checks it again itself.

proc about::helper_cmd {} {
	if {[info exists ::env(RIBBON_ABOUT_TEST)] && $::env(RIBBON_ABOUT_TEST) ne ""} {
		return [list [tool RIBBON_ABOUT_PKEXEC pkexec] [tool RIBBON_ABOUT_HELPER /usr/bin/ribbon-hostname-helper]]
	}
	list pkexec /usr/bin/ribbon-hostname-helper
}

# One line for a failure: pkexec's 126 is a prompt that was dismissed or a refusal, 127 a failed authentication.
proc about::helper_error {out code} {
	switch -- $code {
		126 { return "Cancelled" }
		127 { return "Not authorised" }
	}
	set l [lindex [split [string trim $out] \n] 0]
	regsub {^ribbon-hostname-helper: } $l {} l
	set l [clean $l 70]
	if {$l eq ""} { set l "The change failed" }
	return $l
}

proc about::set_name {name} {
	variable busy; variable error
	if {$busy} return
	if {![valid_name $name]} { set error "Not a computer's name"; return }
	set busy 1
	set error ""
	coroutine ::about::co[incr ::about::seq] about::run_set_name $name
}
proc about::run_set_name {name} {
	variable busy; variable error
	if {[catch {helper_call $name} msg]} { set msg "The change failed" }
	set error $msg
	set busy 0
	changed
}
# Run the helper without blocking the event loop (pkexec waits for a password): "" or the error line.
proc about::helper_call {name} {
	variable buf
	set cmd [list {*}[helper_cmd] set $name]
	if {[catch {::open "|[list {*}$cmd 2>@1]" r} ch]} {
		return [expr {[string match -nocase "*no such file*" $ch] ? "pkexec is not installed" : [helper_error $ch 1]}]
	}
	set me [info coroutine]
	set buf($me) ""
	fconfigure $ch -blocking 0
	fileevent $ch readable [list apply {{ch me} {
		if {[catch {append ::about::buf($me) [::read $ch]}] || [eof $ch]} { fileevent $ch readable {}; $me }
	}} $ch $me]
	yield
	set out $buf($me)
	unset buf($me)
	fconfigure $ch -blocking 1
	set code 0
	if {[catch {::close $ch} msg opts]} {
		set ec [dict get $opts -errorcode]
		set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : 1}]
	}
	if {$code == 0} { return "" }
	helper_error $out $code
}
