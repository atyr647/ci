# hud-data.tcl - the Game HUD's readers: /proc, /sys, the GPU drivers' sysfs and hwmon, and nvidia-smi.
#
# Sources (each reader returns "" when its source is missing, and the HUD then shows a dash):
#   GPU (one card: NVIDIA when nvidia-smi answers for one, else the AMD card with the most VRAM, else Intel)
#     amdgpu               class/drm/cardN/device: gpu_busy_percent, mem_info_vram_used, mem_info_vram_total; its hwmon
#                          (device/hwmon/hwmonN): temp1_input (edge), power1_average (uW, else power1_input)
#     i915, xe             busy is the time the GPU was not idle between two samples: i915's RC6 residency
#                          (cardN/gt/gt0/rc6_residency_ms, older kernels cardN/power/rc6_residency_ms), xe's
#                          device/tile0/gt0/gtidle/idle_residency_ms. A discrete card's hwmon (i915, xe): the first
#                          temp*_input, power1_input, else the rate of energy1_input (uJ). Intel gives no VRAM figure
#                          in sysfs: that row is a dash
#     nvidia               the driver has none of this in sysfs: "nvidia-smi --query-gpu=... -lms 500", one long-lived
#                          process while the HUD samples (started only when a card's driver is nvidia); utilization.gpu,
#                          memory.used/total (MiB), temperature.gpu, power.draw (W). Several cards: the busiest
#   CPU use                /proc/stat, the first "cpu" line: idle + iowait against the total, between two samples
#   CPU temperature        the first hwmon (class/hwmon/hwmonN) named k10temp, zenpower, coretemp or cpu_thermal:
#                          its Tctl (AMD) or "Package id" (Intel) temperature by label, else temp1_input
#   Memory                 /proc/meminfo: MemTotal and MemAvailable
#   Network                /proc/net/dev: received bytes of every interface but lo, as a rate between two samples
#   Disk                   sys/block/*/stat: sectors read and written of the whole disks (not loop, ram, zram, dm-, sr, md)
#   Clock                  local time, HH:MM (Tcl's clock)
#
# hud::data::sample refreshes the readings (the HUD runs it at 2 Hz); hud::data::stop ends nvidia-smi.
# hud::data::rows turns the readings into the metric rows.
# Roots are /proc and /sys by default; hud::data::configure -proc DIR -sys DIR -nvidia-smi CMD points them at a
# fixture tree and a stand-in (tests).

namespace eval ::hud::data {
	variable roots [dict create proc /proc sys /sys]
	variable prev {}   ;# counters of the last sample: t (ms), idle, total, rx, disk, gpu_idle, gpu_energy (and their card)
	variable nvidia_smi nvidia-smi
	variable nv_chan ""      ;# the running nvidia-smi
	variable nv_cards {}     ;# index -> {busy used total temp power}, its last line for each card
	variable nv_tried 0      ;# when it was last started (ms): not more than once in 10 s
	# the last sample; "" for every reading until the first sample, and for any source that is missing
	variable state [dict create gpu_busy "" gpu_temp "" vram_used "" vram_total "" power "" cpu "" cpu_temp "" \
		mem_used "" mem_total "" net "" disk "" clock ""]
}

proc ::hud::data::configure {args} {
	variable roots
	foreach {k v} $args {
		switch -- $k {
			-proc { dict set roots proc [string trimright $v /] }
			-sys  { dict set roots sys [string trimright $v /] }
			-nvidia-smi { variable nvidia_smi; stop; set nvidia_smi $v }
			default { error "hud::data::configure: unknown option $k" }
		}
	}
}

# the file's text without its final newline, or "" when it cannot be read
proc ::hud::data::slurp {path} {
	if {[catch {::open $path r} fh]} { return "" }
	set text [::read $fh]
	::close $fh
	return [string trimright $text "\n"]
}

# a whole number from a file's text, or ""
proc ::hud::data::number {text} {
	if {[string is wideinteger -strict $text]} { return $text }
	return ""
}

# the kernel driver of a card's device: the uevent's DRIVER= line, else the name the driver link points at
proc ::hud::data::driver_of {dev} {
	if {[regexp {(?m)^DRIVER=(\S+)} [slurp $dev/uevent] -> d]} { return $d }
	if {![catch {file readlink $dev/driver} l]} { return [file tail $l] }
	# a card with no driver line is taken for amdgpu when it has amdgpu's counters
	if {[file exists $dev/gpu_busy_percent] || [file exists $dev/mem_info_vram_total]} { return amdgpu }
	return ""
}

# the cards: {driver card-dir device-dir ...}, in card order
proc ::hud::data::cards {} {
	variable roots
	set sys [dict get $roots sys]
	set out {}
	foreach c [lsort -dictionary [glob -nocomplain $sys/class/drm/card*]] {
		if {![regexp {/card\d+$} $c]} continue
		lappend out [driver_of $c/device] $c $c/device
	}
	return $out
}

# the hwmon directory under DIR whose name is one of NAMES (in that order of preference); {} NAMES takes the first
proc ::hud::data::hwmon_in {dir names} {
	set all [lsort -dictionary [glob -nocomplain $dir/hwmon*]]
	if {![llength $names]} { return [lindex $all 0] }
	foreach name $names {
		foreach h $all { if {[slurp $h/name] eq $name} { return $h } }
	}
	return ""
}

# the first temp*_input of a hwmon, in degrees C, or ""
proc ::hud::data::hwmon_temp {hw {label ""}} {
	set files [lsort -dictionary [glob -nocomplain $hw/temp*_input]]
	if {$label ne ""} {
		foreach f $files {
			if {[string match $label [slurp [string map {_input _label} $f]]]} {
				set t [number [slurp $f]]
				if {$t ne ""} { return [expr {$t / 1000}] }
			}
		}
	}
	foreach f $files {
		set t [number [slurp $f]]
		if {$t ne ""} { return [expr {$t / 1000}] }
	}
	return ""
}

# The GPU's readings: {busy temp vram_used vram_total power card idle energy}. idle and energy are counters (ms, uJ)
# whose rates sample turns into busy and power; card names the card they belong to (cardN, or nvidia).
proc ::hud::data::read_gpu {} {
	set out [dict create busy "" temp "" vram_used "" vram_total "" power "" card "" idle "" energy ""]
	set nv [nvidia]
	if {[dict size $nv]} { return [dict merge $out $nv [dict create card nvidia]] }
	set cards [cards]
	# AMD: the card with the most VRAM (a discrete card before the APU's carve-out)
	set best ""; set most -1
	foreach {drv c dev} $cards {
		if {$drv ne "amdgpu" || !([file exists $dev/gpu_busy_percent] || [file exists $dev/mem_info_vram_total])} continue
		set t [number [slurp $dev/mem_info_vram_total]]
		if {$t eq ""} { set t 0 }
		if {$t > $most} { set most $t; set best $dev }
	}
	if {$best ne ""} {
		set dev $best
		dict set out card [file tail [file dirname $dev]]
		dict set out busy [number [slurp $dev/gpu_busy_percent]]
		dict set out vram_used [number [slurp $dev/mem_info_vram_used]]
		dict set out vram_total [number [slurp $dev/mem_info_vram_total]]
		set hw [hwmon_in $dev/hwmon {}]
		if {$hw ne ""} {
			set t [number [slurp $hw/temp1_input]]
			if {$t ne ""} { dict set out temp [expr {$t / 1000}] }
			set p [number [slurp $hw/power1_average]]
			if {$p eq ""} { set p [number [slurp $hw/power1_input]] }
			if {$p ne ""} { dict set out power [expr {$p / 1000000.0}] }
		}
		return $out
	}
	# Intel: a discrete card (one with a hwmon) before the integrated one
	set best ""
	foreach {drv c dev} $cards {
		if {$drv ni {i915 xe}} continue
		if {$best eq "" || ([hwmon_in $dev/hwmon {}] ne "" && [hwmon_in [lindex $best 2]/hwmon {}] eq "")} {
			set best [list $drv $c $dev]
		}
	}
	if {$best eq ""} { return $out }
	lassign $best drv c dev
	dict set out card [file tail $c]
	if {$drv eq "i915"} {
		set files [list $c/gt/gt0/rc6_residency_ms $c/power/rc6_residency_ms]
	} else {
		set files [lsort -dictionary [glob -nocomplain $dev/tile0/gt0/gtidle/idle_residency_ms $dev/tile*/gt*/gtidle/idle_residency_ms]]
	}
	foreach f $files {
		set v [number [slurp $f]]
		if {$v ne ""} { dict set out idle $v; break }
	}
	set hw [hwmon_in $dev/hwmon {}]
	if {$hw ne ""} {
		dict set out temp [hwmon_temp $hw]
		set p [number [slurp $hw/power1_input]]
		if {$p eq ""} { set p [number [slurp $hw/power1_average]] }
		if {$p ne ""} { dict set out power [expr {$p / 1000000.0}] } else { dict set out energy [number [slurp $hw/energy1_input]] }
	}
	return $out
}

# ---- nvidia-smi ----------------------------------------------------------------------------------------------------

# 1 when a card's driver is nvidia
proc ::hud::data::nvidia_card {} {
	foreach {drv c dev} [cards] { if {$drv eq "nvidia"} { return 1 } }
	return 0
}

# The NVIDIA card's readings from the running nvidia-smi ({busy temp vram_used vram_total power}; all "" before its
# first line), or {} when there is none (no NVIDIA card, no nvidia-smi). Starts nvidia-smi when it is not running.
proc ::hud::data::nvidia {} {
	variable nv_chan
	variable nv_cards
	variable nv_tried
	variable nvidia_smi
	if {$nv_chan eq ""} {
		set now [::clock milliseconds]
		if {$now - $nv_tried < 10000 || ![nvidia_card] || [auto_execok [lindex $nvidia_smi 0]] eq ""} { return {} }
		set nv_tried $now
		set q index,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw
		if {[catch {::open |[concat $nvidia_smi [list --query-gpu=$q --format=csv,noheader,nounits -lms 500 2>/dev/null]] r} ch]} {
			return {}
		}
		set nv_chan $ch
		set nv_cards {}
		fconfigure $ch -blocking 0 -buffering line -encoding utf-8
		fileevent $ch readable [list ::hud::data::nvidia_line $ch]
	}
	# running but no line yet: the NVIDIA card is the one shown (dashes), not the card beside it
	set best [dict create busy "" vram_used "" vram_total "" temp "" power ""]
	dict for {i c} $nv_cards {
		if {[dict get $best vram_total] eq "" || ([dict get $c busy] ne "" && ([dict get $best busy] eq "" || [dict get $c busy] > [dict get $best busy]))} {
			set best $c
		}
	}
	return $best
}

proc ::hud::data::nvidia_line {ch} {
	variable nv_chan
	variable nv_cards
	while {[gets $ch line] >= 0} {
		set f [lmap v [split $line ,] {string trim $v}]
		if {[llength $f] < 6} continue
		lassign $f idx busy used total temp power
		if {![string is integer -strict $idx]} continue
		set c [dict create busy "" vram_used "" vram_total "" temp "" power ""]
		if {[string is double -strict $busy]} { dict set c busy [expr {round($busy)}] }
		if {[string is double -strict $used]} { dict set c vram_used [expr {wide($used * 1048576)}] }
		if {[string is double -strict $total]} { dict set c vram_total [expr {wide($total * 1048576)}] }
		if {[string is double -strict $temp]} { dict set c temp [expr {round($temp)}] }
		if {[string is double -strict $power]} { dict set c power [expr {double($power)}] }
		dict set nv_cards $idx $c
	}
	if {[eof $ch]} {
		catch {::close $ch}
		if {$nv_chan eq $ch} { set nv_chan ""; set nv_cards {} }
	}
}

# end nvidia-smi (the HUD stopped sampling)
proc ::hud::data::stop {} {
	variable nv_chan
	variable nv_cards
	variable nv_tried
	set nv_tried 0
	if {$nv_chan ne ""} {
		catch {exec kill {*}[pid $nv_chan]}
		catch {::close $nv_chan}
		set nv_chan ""
	}
	set nv_cards {}
}

proc ::hud::data::read_cpu_temp {} {
	variable roots
	set hw [hwmon_in [dict get $roots sys]/class/hwmon {k10temp zenpower coretemp cpu_thermal}]
	if {$hw eq ""} { return "" }
	set label [dict get {k10temp Tctl zenpower Tctl coretemp {Package id*} cpu_thermal ""} [slurp $hw/name]]
	return [hwmon_temp $hw $label]
}

# {idle total} from the first "cpu" line of /proc/stat, or {}
proc ::hud::data::read_cpu {} {
	variable roots
	foreach line [split [slurp [dict get $roots proc]/stat] \n] {
		if {[lindex $line 0] ne "cpu"} continue
		set f [lrange $line 1 end]
		set total 0
		foreach v $f { if {[number $v] ne ""} { incr total $v } }
		set idle [expr {[number [lindex $f 3]] + [number [lindex $f 4]]}]
		return [list $idle $total]
	}
	return {}
}

# {used total} in kB from /proc/meminfo, or {}
proc ::hud::data::read_mem {} {
	variable roots
	set total ""; set avail ""
	foreach line [split [slurp [dict get $roots proc]/meminfo] \n] {
		if {[regexp {^MemTotal:\s+(\d+)} $line -> v]} { set total $v }
		if {[regexp {^MemAvailable:\s+(\d+)} $line -> v]} { set avail $v }
	}
	if {$total eq "" || $avail eq ""} { return {} }
	return [list [expr {$total - $avail}] $total]
}

# received bytes, all interfaces but lo, or ""
proc ::hud::data::read_net {} {
	variable roots
	set sum ""
	foreach line [split [slurp [dict get $roots proc]/net/dev] \n] {
		if {![regexp {^\s*([^:|]+):\s*(.*)$} $line -> name rest]} continue
		if {[string trim $name] eq "lo"} continue
		set rx [number [lindex $rest 0]]
		if {$rx eq ""} continue
		if {$sum eq ""} { set sum 0 }
		incr sum $rx
	}
	return $sum
}

# bytes read plus written by the whole disks, or ""
proc ::hud::data::read_disk {} {
	variable roots
	set sum ""
	foreach d [glob -nocomplain [dict get $roots sys]/block/*] {
		set n [file tail $d]
		if {[regexp {^(loop|ram|zram|dm-|sr|md)} $n]} continue
		set f [split [string trim [slurp $d/stat]] " "]
		set r [number [lindex $f 2]]
		set w [number [lindex $f 6]]
		if {$r eq "" || $w eq ""} continue
		if {$sum eq ""} { set sum 0 }
		incr sum [expr {($r + $w) * 512}]
	}
	return $sum
}

# one sample of every reader. NOW is the time in ms (tests pass one); rates need two samples.
proc ::hud::data::sample {{now ""}} {
	variable prev
	variable state
	if {$now eq ""} { set now [::clock milliseconds] }
	set gpu [read_gpu]
	set cpu [read_cpu]
	set mem [read_mem]
	set rx [read_net]
	set disk [read_disk]
	set dt [expr {[dict exists $prev t] ? ($now - [dict get $prev t]) / 1000.0 : 0}]
	set cpu_pct ""; set net ""; set disk_rate ""
	if {$cpu ne "" && [dict exists $prev idle]} {
		set dtot [expr {[lindex $cpu 1] - [dict get $prev total]}]
		set didle [expr {[lindex $cpu 0] - [dict get $prev idle]}]
		if {$dtot > 0} { set cpu_pct [expr {round(100.0 * (1 - double($didle) / $dtot))}] }
	}
	if {$dt > 0} {
		if {$rx ne "" && [dict exists $prev rx]} { set net [expr {($rx - [dict get $prev rx]) / $dt}] }
		if {$disk ne "" && [dict exists $prev disk]} { set disk_rate [expr {($disk - [dict get $prev disk]) / $dt}] }
		# Intel: busy is the share of the time the GPU was not idle, power the energy counter's rate (same card only)
		set same [expr {[dict exists $prev gpu_card] && [dict get $prev gpu_card] eq [dict get $gpu card]}]
		if {$same && [dict get $gpu idle] ne "" && [dict exists $prev gpu_idle]} {
			set didle [expr {[dict get $gpu idle] - [dict get $prev gpu_idle]}]
			if {$didle >= 0} { dict set gpu busy [expr {max(0, min(100, round(100.0 * (1 - $didle / ($dt * 1000.0)))))}] }
		}
		if {$same && [dict get $gpu energy] ne "" && [dict exists $prev gpu_energy]} {
			set de [expr {[dict get $gpu energy] - [dict get $prev gpu_energy]}]
			if {$de >= 0} { dict set gpu power [expr {$de / 1000000.0 / $dt}] }
		}
	}
	set state [dict create \
		gpu_busy [dict get $gpu busy] gpu_temp [dict get $gpu temp] \
		vram_used [dict get $gpu vram_used] vram_total [dict get $gpu vram_total] power [dict get $gpu power] \
		cpu $cpu_pct cpu_temp [read_cpu_temp] \
		mem_used [expr {[llength $mem] ? [lindex $mem 0] * 1024 : ""}] \
		mem_total [expr {[llength $mem] ? [lindex $mem 1] * 1024 : ""}] \
		net $net disk $disk_rate clock [::clock format [::clock seconds] -format %H:%M]]
	set prev [dict create t $now]
	if {$cpu ne ""} { dict set prev idle [lindex $cpu 0]; dict set prev total [lindex $cpu 1] }
	if {$rx ne ""} { dict set prev rx $rx }
	if {$disk ne ""} { dict set prev disk $disk }
	dict set prev gpu_card [dict get $gpu card]
	if {[dict get $gpu idle] ne ""} { dict set prev gpu_idle [dict get $gpu idle] }
	if {[dict get $gpu energy] ne ""} { dict set prev gpu_energy [dict get $gpu energy] }
	return $state
}

# a reading as "13.4": one decimal, or a whole number when it is whole
proc ::hud::data::gb {bytes {whole 0}} {
	set g [expr {$bytes / 1073741824.0}]
	if {$whole && abs($g - round($g)) < 0.05} { return [expr {round($g)}] }
	return [format %.1f $g]
}

# a rate in MB/s: one decimal under 100, else a whole number
proc ::hud::data::rate {bytes_per_s} {
	set m [expr {$bytes_per_s / 1000000.0}]
	if {$m < 100} { return [format %.1f $m] }
	return [format %.0f $m]
}

# The metric rows in the Monitor's order: {key label value meter}. meter is 0..100, or "" for none;
# value is "–" when its source is unavailable. Uses the last sample (see sample).
proc ::hud::data::rows {} {
	variable state
	set d $state
	set dash "–"
	set out {}
	# GPU: busy and temperature
	set busy [dict get $d gpu_busy]; set gt [dict get $d gpu_temp]
	if {$busy eq ""} { set v $dash; set m "" } else {
		set v "$busy%"; set m $busy
		if {$gt ne ""} { append v " · $gt °C" }
	}
	lappend out [list gpu GPU $v $m]
	# VRAM: used of total
	set vu [dict get $d vram_used]; set vt [dict get $d vram_total]
	if {$vu eq "" || $vt eq "" || $vt == 0} { lappend out [list vram VRAM $dash ""] } else {
		lappend out [list vram VRAM "[gb $vu] of [gb $vt 1] GB" [expr {round(100.0 * $vu / $vt)}]]
	}
	# CPU: use and temperature
	set cpu [dict get $d cpu]; set ct [dict get $d cpu_temp]
	if {$cpu eq ""} { set v $dash; set m "" } else {
		set v "$cpu%"; set m $cpu
		if {$ct ne ""} { append v " · $ct °C" }
	}
	lappend out [list cpu CPU $v $m]
	# Memory: used of total
	set mu [dict get $d mem_used]; set mt [dict get $d mem_total]
	if {$mu eq "" || $mt eq "" || $mt == 0} { lappend out [list mem Memory $dash ""] } else {
		lappend out [list mem Memory "[gb $mu] of [gb $mt 1] GB" [expr {round(100.0 * $mu / $mt)}]]
	}
	# Power: the GPU's board power
	set p [dict get $d power]
	lappend out [list power Power [expr {$p eq "" ? $dash : "[format %.0f $p] W"}] ""]
	# Network: received rate
	set n [dict get $d net]
	lappend out [list net Network [expr {$n eq "" ? $dash : "↓ [rate $n] MB/s"}] ""]
	# optional: Disk, Clock
	set dk [dict get $d disk]
	lappend out [list disk Disk [expr {$dk eq "" ? $dash : "[rate $dk] MB/s"}] ""]
	lappend out [list clock Clock [dict get $d clock] ""]
	return $out
}
