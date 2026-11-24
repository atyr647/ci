# tests/hud-readers.tcl - the Game HUD's readers against the fixture /proc and /sys trees (tests/hud-fixtures/a and b,
# one second apart), a missing source, the frame source and the settings interface. Run with tclsh8.6.
# Exit 0 when every check passes; each failure is printed.
set repo [file dirname [file dirname [file normalize [info script]]]]
source [file join $repo srcpkgs/ribbon-desktop/files/apps/hud/hud.tcl]
hud::init_modules

set fails 0
proc check {name got want} {
	global fails
	if {$got eq $want} { return }
	puts "  FAIL $name: got {$got}, want {$want}"
	incr fails
}
proc check_match {name got pattern} {
	global fails
	if {[regexp $pattern $got]} { return }
	puts "  FAIL $name: got {$got}, want match $pattern"
	incr fails
}

set fx [file join $repo tests hud-fixtures]

# --- the first sample: the rates and the CPU use need a second sample
hud::data::configure -proc [file join $fx a proc] -sys [file join $fx a sys]
set s [hud::data::sample 0]
check "first sample: gpu busy" [dict get $s gpu_busy] 97
check "first sample: gpu temp (hwmon temp1 in deg C)" [dict get $s gpu_temp] 71
check "first sample: vram used bytes" [dict get $s vram_used] 14390000000
check "first sample: vram total bytes" [dict get $s vram_total] 21474836480
check "first sample: power (W)" [format %.0f [dict get $s power]] 284
check "first sample: cpu use waits for a second sample" [dict get $s cpu] ""
check "first sample: cpu temp (k10temp)" [dict get $s cpu_temp] 68
check "first sample: memory used (bytes, from MemTotal - MemAvailable)" [dict get $s mem_used] 15249230848
check "first sample: memory total (bytes)" [dict get $s mem_total] 34359738368
check "first sample: network rate waits" [dict get $s net] ""
check "first sample: disk rate waits" [dict get $s disk] ""

# --- the second sample, a second later: CPU 34 %, network 37.6 MB/s (lo excluded), disk 212 MB/s (loop excluded)
hud::data::configure -proc [file join $fx b proc] -sys [file join $fx b sys]
set s [hud::data::sample 1000]
check "cpu use over the second sample (340 of 1000 ticks busy)" [dict get $s cpu] 34
check "network rate, bytes/s (lo not counted)" [format %.0f [dict get $s net]] 37600000
check "disk rate, bytes/s (loop not counted)" [format %.0f [dict get $s disk]] 211968000
check_match "clock is HH:MM" [dict get $s clock] {^\d\d:\d\d$}

# --- the rows, as the board shows them
set rows [hud::data::rows]
set want {
	{gpu GPU "97% \u00b7 71 \u00b0C" 97}
	{vram VRAM "13.4 of 20 GB" 67}
	{cpu CPU "34% \u00b7 68 \u00b0C" 34}
	{mem Memory "14.2 of 32 GB" 44}
	{power Power "284 W" {}}
	{net Network "\u2193 37.6 MB/s" {}}
	{disk Disk "212 MB/s" {}}
}
set i 0
foreach w $want {
	lassign $w key label value meter
	set r [lindex $rows $i]
	check "row $key key" [lindex $r 0] $key
	check "row $key label" [lindex $r 1] $label
	check "row $key value" [lindex $r 2] $value
	check "row $key meter" [lindex $r 3] $meter
	incr i
}
check "row clock key" [lindex $rows 7 0] clock

# --- a missing source: dashes, no meter, no error
hud::data::configure -proc /nonexistent/proc -sys /nonexistent/sys
set s [hud::data::sample 2000]
set rows [hud::data::rows]
set dash "\u2013"
foreach r [lrange $rows 0 6] {
	check "missing source: [lindex $r 0] value" [lindex $r 2] $dash
	check "missing source: [lindex $r 0] meter" [lindex $r 3] {}
}
check "missing source: frames unavailable" [dict get [hud::frames::numbers] ok] 0

# --- other GPUs and CPUs (tests/hud-fixtures/i915, xe, nvidia, amd2): the GPU, VRAM, CPU temperature and Power rows
# poll until CMD is true or MS milliseconds pass (the event loop runs meanwhile)
proc wait_for {cmd ms} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 $cmd] && [clock milliseconds] < $end} {
		after 20 { set ::tick 1 }
		vwait ::tick
	}
	uplevel #0 $cmd
}
proc row {key} {
	foreach r [hud::data::rows] { if {[lindex $r 0] eq $key} { return [lrange $r 2 3] } }
}
set nvlog [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] hud-nvsmi-[pid].log]
set ::env(NVSMI_LOG) $nvlog
file delete $nvlog
hud::data::configure -nvidia-smi [file join $fx nvidia-smi]

# Intel, i915: an integrated card (card0, the older power/rc6_residency_ms) and a discrete one with a hwmon (card1)
hud::data::configure -proc [file join $fx a proc] -sys [file join $fx i915 a sys]
set s [hud::data::sample 0]
check "i915: busy waits for a second sample (it is a rate of the RC6 residency)" [dict get $s gpu_busy] ""
check "i915: coretemp's Package temperature is the CPU temperature (acpitz is not a CPU sensor)" [dict get $s cpu_temp] 72
hud::data::configure -sys [file join $fx i915 b sys]
set s [hud::data::sample 1000]
check "i915: the discrete card (card1) is read: 250 ms of RC6 in 1 s is 75 % busy" [dict get $s gpu_busy] 75
check "i915: power is the rate of the hwmon's energy1_input (45 J in 1 s)" [format %.0f [dict get $s power]] 45
check "i915: no temperature on its hwmon" [dict get $s gpu_temp] ""
check "i915: GPU row" [row gpu] {75% 75}
check "i915: VRAM row is a dash (Intel gives no VRAM figure in sysfs)" [row vram] [list "\u2013" {}]
check "i915: Power row" [row power] {{45 W} {}}
# only the integrated card: the older RC6 file
set tmp [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] hud-igpu-[pid]]
foreach s {a b} {
	file mkdir $tmp/$s/class/drm
	file copy [file join $fx i915 $s sys class drm card0] $tmp/$s/class/drm/card0
}
hud::data::configure -sys $tmp/a
hud::data::sample 2000
hud::data::configure -sys $tmp/b
set s [hud::data::sample 2500]
check "i915 integrated: 900 ms of RC6 in 500 ms clamps to 0 % busy" [dict get $s gpu_busy] 0
check "i915 integrated: no power, no temperature (no hwmon)" [list [dict get $s power] [dict get $s gpu_temp]] {{} {}}
file delete -force $tmp
# a new card between two samples gives no rate from the old card's counters
hud::data::configure -sys [file join $fx i915 a sys]
hud::data::sample 3000
hud::data::configure -sys [file join $fx xe b sys]
set s [hud::data::sample 4000]
check "another card since the last sample: no busy figure yet" [dict get $s gpu_busy] ""

# Intel, xe: gt0's gtidle residency, a hwmon with temp2 only, and power from energy1_input; zenpower's Tctl
hud::data::configure -sys [file join $fx xe a sys]
hud::data::sample 5000
hud::data::configure -sys [file join $fx xe b sys]
set s [hud::data::sample 6000]
check "xe: 600 ms idle in 1 s is 40 % busy (gt0; the media gt1 is not the GPU's busy)" [dict get $s gpu_busy] 40
check "xe: the hwmon's first temperature (temp2_input)" [dict get $s gpu_temp] 58
check "xe: power from energy1_input (120 J in 1 s)" [format %.0f [dict get $s power]] 120
check "xe: zenpower's Tctl is the CPU temperature" [dict get $s cpu_temp] 74
check "xe: GPU row" [row gpu] [list "40% \u00b7 58 \u00b0C" 40]

# two AMD cards: the one with the most VRAM (the discrete card, not the APU's carve-out)
hud::data::configure -sys [file join $fx amd2 sys]
set s [hud::data::sample 7000]
check "amdgpu x2: the discrete card's busy" [dict get $s gpu_busy] 88
check "amdgpu x2: its power1_input (no power1_average)" [format %.0f [dict get $s power]] 251
check "amdgpu x2: VRAM row" [row vram] {{8.0 of 16 GB} 50}
check "amdgpu x2: no NVIDIA card, so nvidia-smi was never started" [file exists $nvlog] 0

# NVIDIA: nvidia-smi in its loop mode (one process), the busiest card, before the Intel card beside it
hud::data::configure -sys [file join $fx nvidia sys]
set s [hud::data::sample 8000]
check "nvidia: before nvidia-smi's first line the GPU is a dash, not the Intel card beside it" [list [dict get $s gpu_busy] [dict get $s vram_total]] {{} {}}
wait_for {expr {[dict get [hud::data::nvidia] vram_total] ne ""}} 3000
set s [hud::data::sample 9000]
check "nvidia: busy (the busier of the two cards)" [dict get $s gpu_busy] 43
check "nvidia: temperature" [dict get $s gpu_temp] 61
check "nvidia: VRAM used and total (MiB)" [list [dict get $s vram_used] [dict get $s vram_total]] [list [expr {3072 * 1048576}] [expr {12282 * 1048576}]]
check "nvidia: power.draw" [format %.0f [dict get $s power]] 118
check "nvidia: GPU row" [row gpu] [list "43% \u00b7 61 \u00b0C" 43]
check "nvidia: VRAM row" [row vram] {{3.0 of 12 GB} 25}
check "nvidia: Power row" [row power] {{118 W} {}}
after 700 { set ::tick 1 }; vwait ::tick
hud::data::sample 9500
check "nvidia: nvidia-smi was started once, in its loop mode, for all the samples" [llength [split [string trim [hud::data::slurp $nvlog]] \n]] 1
set ch $::hud::data::nv_chan
set pids [pid $ch]
hud::data::stop
after 300 { set ::tick 1 }; vwait ::tick
check "nvidia: hud::data::stop ends nvidia-smi" [catch {exec kill -0 {*}$pids}] 1
set ::hud::data::nv_tried [clock milliseconds]
check "nvidia: and forgets its readings (and within 10 s of a start that died it is not started again)" [dict size [hud::data::nvidia]] 0
hud::data::stop
wait_for {expr {[dict size [hud::data::nvidia]] > 0 && [dict get [hud::data::nvidia] vram_total] ne ""}} 3000
check "nvidia: sampling again starts it again at once" [llength [split [string trim [hud::data::slurp $nvlog]] \n]] 2
hud::data::stop
file delete $nvlog
hud::data::configure -nvidia-smi nvidia-smi

# --- the frame source: the stub says unavailable; a fixture source gives the numbers of the board
hud::frames::set_source stub
hud::frames::poll
check "stub: frames unavailable" [dict get [hud::frames::numbers] ok] 0
check "unknown frame source is an error" [catch {hud::frames::set_source nope}] 1

set ft {}
for {set i 0} {$i < 600} {incr i} {
	set v [expr {8.9 + 0.5 * sin($i * 1.3) + 0.3 * sin($i * 3.1)}]
	lappend ft $v
}
# the last 60 carry the board's spikes (outside the last 30, which set the frame time); 8 frames at 11.9 ms in
# the rest set the 1 % low
set base 540
lset ft [expr {$base + 22}] 13.2
lset ft [expr {$base + 10}] 11.6
foreach i {3 77 150 233 301 366 410 488} { lset ft $i 11.9 }
set ::fixture_ft $ft
proc ::fixture_poll {} {
	if {[info exists ::fixture_done]} { return [dict create available 1 times {}] }
	set ::fixture_done 1
	return [dict create available 1 times $::fixture_ft]
}
hud::frames::register fixture ::fixture_poll
hud::frames::set_source fixture
hud::frames::poll
set f [hud::frames::numbers]
check "fixture: frames available" [dict get $f ok] 1
check "fixture: fps (112 on the board)" [dict get $f fps] 112
check "fixture: frame time (8.9 ms on the board)" [dict get $f ft] 8.9
check "fixture: 1 % low (84 on the board)" [dict get $f low] 84
check "fixture: graph has 60 points" [llength [dict get $f series]] 60
hud::frames::reset
hud::frames::set_source stub

# --- the settings interface: defaults, sanitising, the ten metric checkboxes
set d [hud::settings_defaults]
check "defaults: layout" [dict get $d layout] full
check "defaults: position" [dict get $d position] top-right
check "defaults: scale" [dict get $d scale] 100
check "defaults: opacity" [dict get $d opacity] 86
check "defaults: ten contents, no disk or clock" [llength [dict get $d contents]] 10
hud::configure {layout bogus scale 110 opacity 250 contents {gpu clock nope}}
set c [hud::config]
check "bad layout keeps the default" [dict get $c layout] full
check "bad scale keeps the default" [dict get $c scale] 100
check "opacity is clamped to 100" [dict get $c opacity] 100
check "unknown contents are dropped" [dict get $c contents] {gpu clock}
hud::configure {layout compact position bottom-left scale 125 opacity 50}
set c [hud::config]
check "layout set" [dict get $c layout] compact
check "position set" [dict get $c position] bottom-left
check "scale set" [dict get $c scale] 125
check "opacity set" [dict get $c opacity] 50
check "contents kept when not given" [dict get $c contents] {gpu clock}
hud::configure [hud::settings_defaults]

if {$fails} {
	puts "hud readers: $fails failed"
	exit 1
}
puts "hud readers: all checks passed"
exit 0
