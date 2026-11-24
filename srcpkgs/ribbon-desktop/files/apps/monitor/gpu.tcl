# gpu.tcl - System monitor: graphics cards. No UI here; gpupage.tcl draws them.
#
#   monitor::gpu::cards        every card found, one dict each (see below)
#   monitor::gpu::card         the card the monitor shows: the first with a load figure, else the first; "" with none
#   monitor::gpu::process PID  one process's use, from /proc/PID/fdinfo (drm-* keys)
#   monitor::gpu::nvidia_procs per-process use on NVIDIA cards (nvidia-smi), dict pid -> {percent bytes}
#
# A card dict: driver (amdgpu i915 xe nvidia), name, busy (%), vram_used vram_total (bytes), temp hot (C: the edge
# and the hotspot), fan (RPM), power cap (W: the draw and its limit), clock mclock (MHz: core and memory), bus
# ("PCIe 4.0 x 16" with the board's multiplication sign), dir. A figure the driver does not give is "".
#
# amdgpu, i915 and xe are read from sysfs (class/drm/cardN/device and its hwmon); the Intel drivers have no load
# figure there, so main.tcl sums the processes' engine time for it. NVIDIA's driver has none of this in sysfs: the
# card and its processes come from nvidia-smi when it is installed. nvidia-smi is slow (its process list samples for
# a second), so it runs beside the window: a call returns what the last run said and starts the next (the first
# call has nothing yet). The roots and the command are variables so the tests read fixture trees
# (tests/monitor-fixtures); real cards are not testable here.

namespace eval monitor::gpu {
	variable nvidia_smi nvidia-smi
	variable pci_ids {/usr/share/hwdata/pci.ids /usr/share/misc/pci.ids /usr/share/pci.ids}
	variable names
	array set names {}
	variable said            ;# nvidia-smi's last answer for each question (cards, procs)
	array set said {}
	variable running         ;# question -> the pipe of the run that is under way
	array set running {}
	variable part
	array set part {}
	variable fds             ;# pid -> {looks gpu-fds other-fds}: what process last found (see there)
	array set fds {}
}

# What nvidia-smi last answered to a question, starting the next run when none is under way. "" before the
# first answer, when the command is not installed, and after a run that failed.
proc monitor::gpu::ask {key args} {
	variable nvidia_smi
	variable said
	variable running
	variable part
	if {![info exists running($key)] && [auto_execok [lindex $nvidia_smi 0]] ne ""} {
		if {![catch {::open |[concat $nvidia_smi $args [list 2>/dev/null]] r} ch]} {
			set running($key) $ch; set part($key) ""
			fconfigure $ch -blocking 0 -encoding utf-8
			fileevent $ch readable [list ::monitor::gpu::answer $key $ch]
		}
	}
	return [expr {[info exists said($key)] ? $said($key) : ""}]
}
proc monitor::gpu::answer {key ch} {
	variable said
	variable running
	variable part
	append part($key) [::read $ch]
	if {![eof $ch]} return
	fconfigure $ch -blocking 1
	set said($key) [expr {[catch {::close $ch}] ? "" : $part($key)}]
	unset running($key)
}

# "123 KiB" / "4 MiB" / "5 GiB" / "678" as bytes (or plain count for drm-engine-* ns).
proc monitor::gpu::to_bytes {v} {
	if {![regexp {^(\d+)\s*(KiB|MiB|GiB)?} $v -> n u]} { return 0 }
	switch -- $u {
		KiB { set m 1024 }
		MiB { set m 1048576 }
		GiB { set m 1073741824 }
		default { set m 1 }
	}
	return [expr {$n * $m}]
}

# The drm-* keys of one fdinfo file: dict key -> raw value.
proc monitor::gpu::parse_fdinfo {text} {
	set d [dict create]
	foreach line [split $text \n] {
		if {[regexp {^(drm-[a-z0-9-]+):\s*(.*)$} $line -> k v]} { dict set d $k [string trim $v] }
	}
	return $d
}

# A whole number from a sysfs file, or "".
proc monitor::gpu::num {path} {
	set v [string trim [::monitor::slurp $path]]
	return [expr {[string is wide -strict $v] ? $v : ""}]
}

# The card's name from the PCI id list (hwdata's pci.ids): the marketing name in the brackets when there is one
# ("Navi 31 [Radeon RX 7900 XT/7900 XTX]" -> "Radeon RX 7900 XT"). "" when the list or the id is missing.
proc monitor::gpu::pci_name {vendor device} {
	variable pci_ids
	variable names
	set vendor [string tolower [string range $vendor 2 end]]; set device [string tolower [string range $device 2 end]]
	if {$vendor eq "" || $device eq ""} { return "" }
	if {[info exists names($vendor:$device)]} { return $names($vendor:$device) }
	set name ""
	foreach f $pci_ids {
		set text [::monitor::slurp $f]
		if {$text eq ""} continue
		set in 0
		foreach line [split $text \n] {
			if {[regexp {^([0-9a-f]{4})\s} $line -> v]} { if {$in} break; set in [expr {$v eq $vendor}]; continue }
			if {$in && [regexp "^\\t$device\\s+(.*)\$" $line -> name]} break
		}
		if {$name ne ""} break
	}
	if {[regexp {\[([^\]]+)\]} $name -> inner]} { set name [string trim [lindex [split $inner /] 0]] }
	return [set names($vendor:$device) [string trim $name]]
}

# "16.0 GT/s PCIe" and a width -> "PCIe 4.0 × 16".
proc monitor::gpu::bus {speed width} {
	if {![regexp {^([\d.]+) GT/s} $speed -> s] || ![string is integer -strict $width] || $width < 1} { return "" }
	set gen [expr {$s >= 64 ? "6.0" : $s >= 32 ? "5.0" : $s >= 16 ? "4.0" : $s >= 8 ? "3.0" : $s >= 5 ? "2.0" : "1.0"}]
	return "PCIe $gen × $width"
}

# The kernel driver of a card's device: the uevent's DRIVER= line, else the name the driver link points at.
proc monitor::gpu::driver_of {dev} {
	if {[regexp {(?m)^DRIVER=(\S+)} [::monitor::slurp [file join $dev uevent]] -> d]} { return $d }
	if {![catch {file readlink [file join $dev driver]} l]} { return [file tail $l] }
	return ""
}

proc monitor::gpu::cards {} {
	set out {}
	foreach cdir [lsort -dictionary [glob -nocomplain [file join $::monitor::sys_root class drm card*]]] {
		if {![regexp {card\d+$} $cdir]} continue
		set dev [file join $cdir device]
		set driver [driver_of $dev]
		# a card with no driver line is taken for amdgpu when it has amdgpu's load file
		if {$driver eq "" && [num [file join $dev gpu_busy_percent]] ne ""} { set driver amdgpu }
		if {$driver ni {amdgpu i915 xe}} continue
		set c [dict create driver $driver dir $cdir name "" busy "" vram_used "" vram_total "" temp "" hot "" fan "" \
			power "" cap "" clock "" mclock "" bus ""]
		dict set c name [pci_name [string trim [::monitor::slurp [file join $dev vendor]]] [string trim [::monitor::slurp [file join $dev device]]]]
		dict set c bus [bus [string trim [::monitor::slurp [file join $dev current_link_speed]]] [string trim [::monitor::slurp [file join $dev current_link_width]]]]
		if {$driver eq "amdgpu"} {
			dict set c busy [num [file join $dev gpu_busy_percent]]
			dict set c vram_used [num [file join $dev mem_info_vram_used]]
			dict set c vram_total [num [file join $dev mem_info_vram_total]]
		} elseif {$driver eq "i915"} {
			dict set c clock [num [file join $cdir gt_act_freq_mhz]]
		} else {
			dict set c clock [num [file join $dev tile0 gt0 freq0 act_freq]]
		}
		foreach h [lsort [glob -nocomplain [file join $dev hwmon hwmon*]]] {
			foreach {key file div} {temp temp1_input 1000 hot temp2_input 1000 fan fan1_input 1 power power1_average 1e6
				power power1_input 1e6 cap power1_cap 1e6 cap power1_max 1e6 clock freq1_input 1e6 mclock freq2_input 1e6} {
				if {[dict get $c $key] ne ""} continue
				set v [num [file join $h $file]]
				if {$v eq ""} continue
				dict set c $key [expr {$div == 1 ? $v : $div == 1000 ? $v / 1000 : $div == 1e6 && $key in {clock mclock} ? round($v / 1e6) : $v / 1e6}]
			}
		}
		if {[dict get $c name] eq ""} {
			dict set c name [dict get {amdgpu "AMD graphics" i915 "Intel graphics" xe "Intel graphics"} $driver]
		}
		lappend out $c
	}
	return [concat $out [nvidia_cards]]
}

# NVIDIA cards from nvidia-smi's CSV (one line a card); {} when the command is missing, fails or has not answered yet.
proc monitor::gpu::nvidia_cards {} {
	set q name,utilization.gpu,memory.used,memory.total,temperature.gpu,fan.speed,power.draw,power.limit
	set text [ask cards --query-gpu=$q --format=csv,noheader,nounits]
	set out {}
	foreach line [split $text \n] {
		set f [lmap v [split $line ,] {string trim $v}]
		if {[llength $f] < 8} continue
		lassign $f name busy used total temp fan power cap
		set c [dict create driver nvidia dir "" name $name busy "" vram_used "" vram_total "" temp "" hot "" fan "" \
			power "" cap "" clock "" mclock "" bus ""]
		if {[string is double -strict $busy]} { dict set c busy [expr {round($busy)}] }
		if {[string is double -strict $used]} { dict set c vram_used [expr {wide($used * 1048576)}] }
		if {[string is double -strict $total]} { dict set c vram_total [expr {wide($total * 1048576)}] }
		if {[string is double -strict $temp]} { dict set c temp [expr {round($temp)}] }
		# nvidia-smi gives the fan in percent, not RPM: there is no RPM to show
		if {[string is double -strict $power]} { dict set c power $power }
		if {[string is double -strict $cap]} { dict set c cap $cap }
		lappend out $c
	}
	return $out
}

# Per-process use on NVIDIA cards: dict pid -> {percent bytes}, from "nvidia-smi pmon -c 1 -s um" (the columns are
# found by the header's names; a dash is no figure). {} without the command.
proc monitor::gpu::nvidia_procs {} {
	set text [ask procs pmon -c 1 -s um]
	set cols {}
	set out [dict create]
	foreach line [split $text \n] {
		set f [regexp -all -inline {\S+} $line]
		if {[lindex $f 0] eq "#"} { if {[lsearch -exact $f pid] >= 0} { set cols [lrange $f 1 end] }; continue }
		set pi [lsearch -exact $cols pid]; set si [lsearch -exact $cols sm]; set fi [lsearch -exact $cols fb]
		if {$pi < 0 || ![string is integer -strict [lindex $f $pi]]} continue
		set pct [expr {$si >= 0 && [string is double -strict [lindex $f $si]] ? [lindex $f $si] : 0.0}]
		set mem [expr {$fi >= 0 && [string is double -strict [lindex $f $fi]] ? wide([lindex $f $fi] * 1048576) : 0}]
		set pid [lindex $f $pi]
		if {[dict exists $out $pid]} { lassign [dict get $out $pid] p0 m0; set pct [expr {$pct + $p0}]; set mem [expr {$mem + $m0}] }
		dict set out $pid [list $pct $mem]
	}
	return $out
}

# The card the window shows.
proc monitor::gpu::card {} {
	set all [cards]
	foreach c $all { if {[dict get $c busy] ne ""} { return $c } }
	return [lindex $all 0]
}

# One process's use: dict vram (bytes now), gfx (engine nanoseconds so far, every engine summed), cycles and
# total (xe counts each engine class's cycles against a total that is the same clock for every class, so the
# classes' cycles are summed and the total is one class's). A DRM client shared by several fds
# is counted once (keyed by drm-client-id). amdgpu, i915 and xe clients are read.
# Every process is looked at every second and some hold thousands of fds, so the fds that are not the GPU's are
# remembered and their fdinfo is read again only every tenth look (an fd number closed and opened again on the GPU).
proc monitor::gpu::process {pid} {
	variable fds
	set clients [dict create]
	# another user's process has an fdinfo folder we may not list: that is no GPU use
	set dir [file join $::monitor::proc_root $pid fdinfo]
	if {[catch {set names [glob -nocomplain -tails -directory $dir *]}]} { set names {} }
	lassign [expr {[info exists fds($pid)] ? $fds($pid) : {0 {} {}}}] looks gpu other
	if {$looks % 10 == 0} { set other {} }
	set other [dict create {*}[concat {*}[lmap n $other {list $n 1}]]]
	set gpu_now {}; set other_now {}
	foreach n $names {
		if {[dict exists $other $n]} { lappend other_now $n; continue }
		set d [parse_fdinfo [::monitor::slurp [file join $dir $n]]]
		if {![dict exists $d drm-driver] || [dict get $d drm-driver] ni {amdgpu i915 xe}} { lappend other_now $n; continue }
		lappend gpu_now $n
		set key [expr {[dict exists $d drm-client-id] ? [dict get $d drm-client-id] : $n}]
		set vram 0; set res 0; set gfx 0; set cyc 0; set tot 0
		dict for {k v} $d {
			if {$k eq "drm-memory-vram"} { set vram [to_bytes $v] } \
			elseif {[string match drm-resident-* $k]} { incr res [to_bytes $v] } \
			elseif {[string match drm-engine-capacity-* $k]} { } \
			elseif {[string match drm-engine-* $k]} { incr gfx [to_bytes $v] } \
			elseif {[string match drm-total-cycles-* $k]} { set tot [expr {max($tot, [to_bytes $v])}] } \
			elseif {[string match drm-cycles-* $k]} { incr cyc [to_bytes $v] }
		}
		# amdgpu names its VRAM; the Intel drivers give what is resident in each memory region
		dict set clients $key [list [expr {$vram > 0 ? $vram : $res}] $gfx $cyc $tot]
	}
	if {[llength $names]} { set fds($pid) [list [expr {$looks + 1}] $gpu_now $other_now] } else { unset -nocomplain fds($pid) }
	set vram 0; set gfx 0; set cyc 0; set tot 0
	dict for {k v} $clients {
		incr vram [lindex $v 0]; incr gfx [lindex $v 1]; incr cyc [lindex $v 2]
		set tot [expr {max($tot, [lindex $v 3])}]
	}
	return [dict create vram $vram gfx $gfx cycles $cyc total $tot]
}

# Forget what process found for the pids that are gone.
proc monitor::gpu::forget {pids} {
	variable fds
	foreach pid $pids { unset -nocomplain fds($pid) }
}
