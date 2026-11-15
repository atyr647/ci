# tests/monitor-lib.tcl - the System monitor's libraries (U24) on the fixture trees in
# tests/monitor-fixtures. Run: tclsh tests/monitor-lib.tcl. Exits 1 on any failure.
set here [file dirname [file normalize [info script]]]
set appdir [file join [file dirname $here] srcpkgs ribbon-desktop files apps monitor]
set fx [file join $here monitor-fixtures]
namespace eval ui {}
foreach f {proc group gpu stuck services history rail gpupage foot} { source -encoding utf-8 [file join $appdir $f.tcl] }
set ::monitor::gpu::pci_ids [list [file join $here monitor-fixtures pci.ids]]
set ::monitor::proc_root [file join $fx proc]
set ::monitor::sys_root [file join $fx sys]
set ::monitor::group::dirs [list [file join $fx applications]]

set fails 0
proc check {name ok} {
	global fails
	if {$ok} { puts "  ok   $name" } else { puts "  FAIL $name"; incr fails }
}

# readers
set st [monitor::parse_stat [monitor::slurp $::monitor::proc_root/stat]]
check "stat: busy, total and CPU count" [expr {[dict get $st busy] == 1500 && [dict get $st total] == 9600 && [dict get $st ncpu] == 2}]
check "meminfo: MemTotal in bytes" [expr {[dict get [monitor::parse_meminfo [monitor::slurp $::monitor::proc_root/meminfo]] MemTotal] == 32768000 * 1024}]
set nd [monitor::parse_netdev [monitor::slurp $::monitor::proc_root/net/dev]]
check "net/dev: lo left out, rx and tx summed" [expr {[dict get $nd rx] == 6000 && [dict get $nd tx] == 3500}]
set ds [monitor::parse_diskstats [monitor::slurp $::monitor::proc_root/diskstats]]
check "diskstats: whole disks only (sda, nvme0n1), 512-byte sectors" [expr {[dict get $ds read] == 300 * 512 && [dict get $ds write] == 700 * 512}]
set ps [monitor::parse_pid_stat "7 (a)b) S 1 1 1 0 0 0 0 0 0 0 5 6 0 0 20 0 3 0 9 0 0"]
check "pid stat: comm with a ')' inside" [expr {[dict get $ps comm] eq "a)b" && [dict get $ps ppid] == 1 && [dict get $ps utime] == 5 && [dict get $ps threads] == 3}]
set ps2 [monitor::parse_pid_stat [monitor::slurp $::monitor::proc_root/5001/stat]]
check "pid stat: comm with a space" [expr {[dict get $ps2 comm] eq "sleepy job" && [dict get $ps2 state] eq "S"}]
check "cgroup leaf and cmdline argv0" [expr {[monitor::parse_cgroup "0::/user.slice/app-x-1.scope\n"] eq "app-x-1.scope" && [monitor::parse_cmdline "/usr/bin/a b\0"] eq "/usr/bin/a b"}]

# scan and sample
set procs [monitor::scan]
set pids [lsort -integer [lmap p $procs {dict get $p pid}]]
check "scan: every numeric pid folder is read" [expr {$pids eq {1 2001 2002 2999 3001 4001 5001 5002}}]
set by [dict create]
foreach p $procs { dict set by [dict get $p pid] $p }
check "scan: argv0 names the process" [expr {[dict get $by 3001] ne "" && [dict get [dict get $by 3001] exe] eq "Cyberpunk2077.exe"}]
check "scan: rss from statm pages" [expr {[dict get [dict get $by 4001] rss] == 300000 * 4096}]
check "scan: disk is read plus write bytes" [expr {[dict get [dict get $by 2001] disk] == 4900000}]

# rates: a second snapshot with user ticks +500, idle +500 and process 3001 +100 ticks
set tmp [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] monitor-lib-[pid]]
file delete -force $tmp
file copy $::monitor::proc_root $tmp
set f [open [file join $tmp stat] w]; puts $f "cpu  1500 0 500 8500 100 0 0 0 0 0\ncpu0 1 0 1 1 1 0 0 0 0 0\ncpu1 1 0 1 1 1 0 0 0 0 0"; close $f
set f [open [file join $tmp 3001 stat] w]; puts $f "3001 (Cyberpunk2077.ex) R 2999 1 1 0 0 0 0 0 0 0 4100 112 0 0 20 0 112 0 900 0 0"; close $f
set prev [monitor::sample]
dict set prev time 1000
set ::monitor::proc_root $tmp
set cur [monitor::sample]
dict set cur time 2000
set ::monitor::proc_root [file join $fx proc]
set r [monitor::rates $prev $cur]
check "rates: whole-machine CPU is busy over total ticks" [expr {abs([dict get $r cpu] - 50.0) < 0.01}]
set rate3001 0.0
foreach p [dict get $r procs] { if {[dict get $p pid] == 3001} { set rate3001 [dict get $p cpu] } }
check "rates: process CPU is its ticks over the machine's capacity (100 ticks, 2 CPUs)" [expr {abs($rate3001 - 50.0) < 0.01}]
file delete -force $tmp

# grouping
set desk [monitor::group::desktops]
check "desktops: Exec names map to Name and id" [expr {[dict get $desk steam name] eq "Steam" && [dict get $desk firefox id] eq "firefox"}]
set apps [monitor::group::assign $procs $desk]
check "desktops: a shell or another wrapper names no app" [expr {![dict exists $desk sh] && ![dict exists $desk pkexec]}]
check "desktops: the plainest of the files that start one program names it" [expr {[dict get $desk foot name] eq "Foot"}]
check "desktops: the program after env and its settings" [expr {[dict exists $desk editor] && [dict get $desk editor name] eq "Editor"}]
# the desktop files are read again only when a folder of them has changed (the sampler asks every second)
set D [exec mktemp -d]
foreach f [glob [file join $fx applications *.desktop]] { file copy $f $D }
set ::reads 0
proc count_reads {args} { incr ::reads }
trace add execution monitor::slurp enter count_reads
set d1 [monitor::group::desktops [list $D]]
set r1 $::reads
set d2 [monitor::group::desktops [list $D]]
set r2 [expr {$::reads - $r1}]
set ch [open $D/zed.desktop w]; puts $ch "\[Desktop Entry\]\nName=Zed\nExec=zed %F"; close $ch
file mtime $D [expr {[file mtime $D] + 5}]
set d3 [monitor::group::desktops [list $D]]
trace remove execution monitor::slurp enter count_reads
check "desktops: a second look at unchanged folders reads no file" [expr {$r1 > 0 && $r2 == 0 && $d1 eq $d2}]
check "desktops: a file added to a folder is read" [expr {[dict exists $d3 zed] && [dict get $d3 zed name] eq "Zed"}]
file delete -force $D
proc app_pids {apps id} { foreach a $apps { if {[dict get $a id] eq $id} { return [lsort -integer [dict get $a pids]] } }; return {} }
check "group: steam by its command name, its children and the game it started with it (2001, 2002, 2999, 3001)" [expr {[app_pids $apps steam] eq {2001 2002 2999 3001}}]
check "group: a systemd app scope names no app (no launcher on this base makes one)" [expr {[app_pids $apps cyberpunk] eq {}}]
check "group: firefox by its command name" [expr {[app_pids $apps firefox] eq {4001}}]
check "group: init and unnamed processes are Background" [expr {[app_pids $apps ""] eq {1 5001 5002}}]
set chain [list [dict create pid 2001 ppid 1 exe steam comm steam cgroup app-steam-2001.scope] \
	[dict create pid 9 ppid 2001 exe sh comm sh cgroup session-9.scope]]
check "group: a child with no app of its own joins its parent's app" [expr {[app_pids [monitor::group::assign $chain $desk] steam] eq {9 2001}}]

# kits: kit run's records ($XDG_RUNTIME_DIR/kit/sandbox/<pid of kit run>/{kit,info}) name the
# processes of a kit's sandbox by its pid namespace, and kit run itself by its pid
set K [exec mktemp -d]
file mkdir $K/proc $K/sandbox $K/apps
proc fake_proc {pid ns cmdline} {
	file mkdir $::K/proc/$pid/ns
	exec ln -s "pid:\[$ns\]" $::K/proc/$pid/ns/pid
	set f [open $::K/proc/$pid/cmdline w]; fconfigure $f -translation binary; puts -nonewline $f $cmdline; close $f
}
proc record {pid kit info} {
	file mkdir $::K/sandbox/$pid
	set f [open $::K/sandbox/$pid/kit w]; puts -nonewline $f $kit; close $f
	if {$info ne ""} { set f [open $::K/sandbox/$pid/info w]; puts -nonewline $f $info; close $f }
}
# a launcher entry kit exported for org.mozilla.firefox; a plain kit run of a .kit with none
set f [open $K/apps/kit-org.mozilla.firefox.desktop w]; puts $f "\[Desktop Entry\]\nName=Firefox (kit)\nExec=/usr/bin/kit run org.mozilla.firefox %u"; close $f
fake_proc 700 4026531836 "tclsh8.6\0/usr/bin/kit\0run\0org.mozilla.firefox\0"
fake_proc 701 4026531836 "bwrap\0--unshare-all\0"
fake_proc 702 4026532265 "bwrap\0--unshare-all\0"
fake_proc 703 4026532265 "/app/bin/firefox\0"
fake_proc 704 4026532265 "/app/bin/firefox\0-contentproc\0"
fake_proc 800 4026531836 "tclsh8.6\0/home/u/bin/kit\0run\0Downloads/hello.kit\0"
fake_proc 802 4026532300 "/app/bin/hello\0"
fake_proc 900 4026531836 "sleep\0"
fake_proc 901 4026532400 "/app/bin/ghost\0"
record 700 {name org.mozilla.firefox short firefox version 134.0.1} "{\n    \"child-pid\": 702,\n    \"pid-namespace\": 4026532265\n}\n"
record 800 {name org.example.hello short hello version 1} {{"child-pid": 802, "pid-namespace": 4026532300}}
# a record left by a kit run that was killed: its pid is now a sleep, its namespace number reused
record 900 {name org.example.ghost short ghost version 1} {{"child-pid": 901, "pid-namespace": 4026532400}}
set kprocs [list [dict create pid 1 ppid 0 exe init comm init] \
	[dict create pid 700 ppid 1 exe tclsh8.6 comm kit] [dict create pid 701 ppid 700 exe bwrap comm bwrap] \
	[dict create pid 702 ppid 701 exe bwrap comm bwrap] [dict create pid 703 ppid 702 exe firefox comm firefox] \
	[dict create pid 704 ppid 1 exe firefox comm firefox] \
	[dict create pid 800 ppid 1 exe tclsh8.6 comm kit] [dict create pid 802 ppid 1 exe hello comm hello] \
	[dict create pid 900 ppid 1 exe sleep comm sleep] [dict create pid 901 ppid 1 exe ghost comm ghost]]
set saved_root $::monitor::proc_root
set ::monitor::proc_root $K/proc
set ::monitor::group::sandboxes $K/sandbox
set kdesk [monitor::group::desktops [list $K/apps [file join $fx applications]]]
check "desktops: kit's launcher entry (Exec=kit run NAME) names the kit, not the program kit" [expr {[dict exists $kdesk kit:org.mozilla.firefox] && ![dict exists $kdesk kit] && [dict get $kdesk kit:org.mozilla.firefox name] eq "Firefox (kit)"}]
set kapps [monitor::group::assign $kprocs $kdesk]
proc app_named {apps id} { foreach a $apps { if {[dict get $a id] eq $id} { return [dict get $a name] } }; return "" }
check "group: a kit's sandbox by its pid namespace, kit run by its pid, bwrap as kit run's child (firefox as the kit, not /usr/share's firefox)" \
	[expr {[app_pids $kapps kit-org.mozilla.firefox] eq {700 701 702 703 704} && [app_named $kapps kit-org.mozilla.firefox] eq "Firefox (kit)" && [app_pids $kapps firefox] eq {}}]
check "group: a kit with no launcher entry, by its name and short name" [expr {[app_pids $kapps org.example.hello] eq {800 802} && [app_named $kapps org.example.hello] eq "hello"}]
check "group: a record whose kit run is gone names nothing, even with its pid and namespace number reused" [expr {[app_pids $kapps org.example.ghost] eq {} && {900} in [app_pids $kapps ""] && {901} in [app_pids $kapps ""]}]
set ::monitor::group::sandboxes ""
check "group: without kit records the namespaces are not read" [expr {[app_pids [monitor::group::assign $kprocs $kdesk] firefox] eq {703 704}}]
set ::monitor::proc_root $saved_root
file delete -force $K

# GPU
check "gpu: sizes with KiB, MiB and plain" [expr {[monitor::gpu::to_bytes {2048 KiB}] == 2097152 && [monitor::gpu::to_bytes {99 MiB}] == 99 * 1048576 && [monitor::gpu::to_bytes {9000000 ns}] == 9000000}]
set card [monitor::gpu::card]
check "gpu: card busy, VRAM, temperature, power and fan" [expr {[dict get $card busy] == 97 && [dict get $card vram_total] == 21458059264 && [dict get $card temp] == 71 && [dict get $card fan] == 1650 && abs([dict get $card power] - 284.0) < 0.01}]
set g3001 [monitor::gpu::process 3001]
check "gpu: a DRM client held by two fds counts once" [expr {[dict get $g3001 vram] == 2097152 && [dict get $g3001 gfx] == 9000000}]
check "gpu: other drivers are ignored" [expr {[dict get [monitor::gpu::process 4001] vram] == 0}]

# services
set sv [monitor::services::parse [monitor::slurp [file join $fx dinit-list.txt]]]
check "services: started and stopped from the brackets" [expr {[lmap s $sv {dict get $s running}] eq {1 0 1}}]
check "services: fetch is safe without dinitctl" [expr {[catch {monitor::services::fetch system}] == 0}]

# histories
for {set i 0} {$i < 3700} {incr i} { monitor::ring::push cpu $i }
check "history: 1 min, 10 min and 1 h rings" [expr {[llength [monitor::ring::series cpu 60]] == 60 && [llength [monitor::ring::series cpu 600]] == 600 && [llength [monitor::ring::series cpu 3600]] == 3600}]
check "history: newest value last" [expr {[lindex [monitor::ring::series cpu 60] end] == 3699}]

# signals, on sacrificial processes (alive() reads the real /proc here)
set ::monitor::proc_root /proc
set pid [string trim [exec sh -c {sleep 300 </dev/null >/dev/null 2>&1 & echo $!}]]
check "end: a sacrificial process ends on SIGTERM" [expr {[monitor::alive $pid] && [monitor::end [list $pid]] eq {} && ![monitor::alive $pid]}]
set pid2 [string trim [exec sh -c {trap "" TERM; sleep 300 </dev/null >/dev/null 2>&1 & echo $!}]]
# SIGKILL is delivered asynchronously: monitor::end returns after sending it, so the check waits for the
# process to be gone (a deadline, not a fixed pause)
proc wait_gone {pid ms} {
	set until [expr {[clock milliseconds] + $ms}]
	while {[monitor::alive $pid]} {
		if {[clock milliseconds] >= $until} { return 0 }
		after 20
	}
	return 1
}
set killed [monitor::end [list $pid2] 300]
check "end: one that ignores SIGTERM is killed with SIGKILL" [expr {$killed eq [list $pid2] && [wait_gone $pid2 5000]}]
check "signal: a missing pid is not sent" [expr {[monitor::signal {999999} TERM] eq {}}]

# signals that must not be sent: a pid that now names another process, init, the monitor and the session, and
# another user's process. A stood-in kill logs what it is asked (and, for pid 4242, its TERM stands for the
# process exiting and the pid being reused at once by a new process).
set S [exec mktemp -d]
proc fake_proc {root pid comm ppid start {uid 1000} {cmdline ""}} {
	file mkdir $root/$pid
	set ch [open $root/$pid/stat w]; puts $ch "$pid ($comm) S $ppid 1 1 0 0 0 0 0 0 0 1 1 0 0 20 0 1 0 $start 0 0"; close $ch
	set ch [open $root/$pid/status w]; puts $ch "Name:\t$comm\nUid:\t$uid\t$uid\t$uid\t$uid"; close $ch
	set ch [open $root/$pid/cmdline w]; puts -nonewline $ch [expr {$cmdline eq "" ? "$comm\0" : "[join $cmdline \0]\0"}]; close $ch
}
foreach {p c pp st u cl} {1 init 0 1 0 {} 600 labwc 1 50 1000 {labwc -m} 610 wish8.6 600 60 1000 {wish8.6 -encoding utf-8 /usr/lib/ribbon/shell/main.tcl -name ribbon-shell}
	700 sh 1 70 1000 {} 701 wish8.6 700 71 1000 {wish8.6 /usr/lib/ribbon/monitor/main.tcl -name ribbon-monitor}
	4242 game 1 100 1000 {} 4300 editor 1 300 1000 {} 4400 sshd 1 400 0 {}} {
	fake_proc $S $p $c $pp $st $u $cl
}
set ch [open $S/kill.sh w]
puts $ch "echo \"\$1 \$2\" >> $S/kill.log
if \[ \"\$1 \$2\" = \"-TERM 4242\" \]; then echo '4242 (newer) S 1 1 1 0 0 0 0 0 0 0 1 1 0 0 20 0 1 0 200 0 0' > $S/4242/stat; fi"
close $ch
set ::monitor::proc_root $S
set ok [expr {[info exists ::monitor::kill] && [info exists ::monitor::self] && [info exists ::monitor::me]}]
check "signal: the kill command, the monitor's own pid and its uids can be stood in for" $ok
if {$ok} {
	set ::monitor::kill [list sh $S/kill.sh]
	set ::monitor::self 701
	set ::monitor::me {1000 1000}
	proc kill_log {} { set l [monitor::slurp $::S/kill.log]; file delete $::S/kill.log; return [string trim $l] }
	check "signal: never init, the monitor, what it was started under, the compositor or the shell" \
		[expr {[monitor::signalable {1 600 610 700 701 4300}] eq {4300} && [monitor::signal {1 600 610 700 701} KILL] eq {} && [kill_log] eq ""}]
	check "signal: not another user's process (root's sshd)" [expr {[monitor::signalable {4400 4300}] eq {4300} && [monitor::signal {4400} TERM] eq {} && [kill_log] eq ""}]
	set ::monitor::me {0 0}
	check "signal: root may signal another user's process" [expr {[monitor::signalable {4400}] eq {4400}}]
	set ::monitor::me {1000 1000}
	check "signal: a pid whose process is not the one asked for (its start time differs) is not sent" \
		[expr {[monitor::signal {4300} STOP [dict create 4300 299]] eq {} && [kill_log] eq "" && [monitor::signal {4300} STOP [dict create 4300 300]] eq {4300} && [kill_log] eq "-STOP 4300"}]
	check "end: the KILL after the grace time is not sent to a new process that took the pid" \
		[expr {[monitor::end {4242} 200] eq {} && [kill_log] eq "-TERM 4242"}]
	check "end: the same process still there after the grace time is killed" \
		[expr {[monitor::end {4300} 200] eq {4300} && [kill_log] eq "-TERM 4300\n-KILL 4300"}]
	set ::monitor::kill kill
	set ::monitor::self [pid]
	set ::monitor::me ""
}
file delete -force $S
set ::monitor::proc_root /proc

# GPU: the other figures and the other drivers (fixture trees; real cards are hardware)
set ::monitor::proc_root [file join $fx proc]
set g [list dict get $card]
check "gpu amdgpu: name from pci.ids, hotspot, limit, clocks and bus" [expr {[{*}$g driver] eq "amdgpu" && [{*}$g name] eq "Radeon RX 7900 XT" && [{*}$g hot] == 88 && abs([{*}$g cap] - 315.0) < 0.01 && [{*}$g clock] == 2540 && [{*}$g mclock] == 2500 && [{*}$g bus] eq "PCIe 4.0 × 16"}]
check "gpu: facts are the board's lines" [expr {[monitor::card_facts $card] eq [list {Clock {2,540 MHz · memory 2,500 MHz}} {Hotspot {88 °C · fan 1,650 RPM}} {{Power limit} {315 W}} [list Bus "PCIe 4.0 × 16"] {Driver amdgpu}]}]
set mt [monitor::card_meters $card]
check "gpu: the four meters" [expr {[lmap x $mt {lindex $x 0}] eq {Load Temperature Power VRAM} && [lindex $mt 0 1] eq "97%" && [lindex $mt 1 1] eq "71 °C" && [lindex $mt 2 1] eq "284 W" && abs([lindex $mt 2 2] - 100.0 * 284 / 315) < 0.01 && [lindex $mt 3 1] eq "13.4 GB"}]
set ::monitor::sys_root [file join $fx sys-i915]
set ic [monitor::gpu::card]
check "gpu i915: found by its driver, clock from gt_act_freq_mhz, hwmon temperature and fan" [expr {[dict get $ic driver] eq "i915" && [dict get $ic name] eq "Arc A770" && [dict get $ic clock] == 1350 && [dict get $ic temp] == 64 && [dict get $ic fan] == 1200 && [dict get $ic bus] eq "PCIe 3.0 × 16"}]
check "gpu i915: what the driver does not give is empty (load, VRAM, power)" [expr {[dict get $ic busy] eq "" && [dict get $ic vram_used] eq "" && [dict get $ic power] eq "" && abs([dict get $ic cap] - 120.0) < 0.01}]
set im [monitor::card_meters $ic]
check "gpu i915: a missing figure is a dash and an empty track" [expr {[lindex $im 0 1] eq "–" && [lindex $im 0 2] eq "" && [lindex $im 2 1] eq "–" && [lindex $im 2 2] eq "" && [lindex $im 3 1] eq "–"}]
check "gpu i915: a missing fact has no row" [expr {[lmap x [monitor::card_facts $ic] {lindex $x 0}] eq {Clock Fan {Power limit} Bus Driver}}]
set ::monitor::sys_root [file join $fx sys-xe]
set xc [monitor::gpu::card]
check "gpu xe: found by its driver, clock from tile0/gt0/freq0" [expr {[dict get $xc driver] eq "xe" && [dict get $xc clock] == 1100 && [dict get $xc name] eq "Raptor Lake-S GT1" && [monitor::card_facts $xc] eq {{Clock {1,100 MHz}} {Driver xe}}}]
set ::monitor::sys_root [file join $fx sys-other]
check "gpu: a card of another driver is not shown, and none is no card" [expr {[monitor::gpu::cards] eq {} && [monitor::gpu::card] eq ""}]
set ::monitor::proc_root [file join $fx proc-gpu]
set p1 [monitor::gpu::process 7001]
check "gpu i915 fdinfo: engine time summed (not the capacity), resident memory" [expr {[dict get $p1 gfx] == 6000000 && [dict get $p1 vram] == 2097152}]
set p2 [monitor::gpu::process 7002]
check "gpu xe fdinfo: cycles against the engines' total" [expr {[dict get $p2 cycles] == 5000 && [dict get $p2 total] == 10000 && [dict get $p2 vram] == 1048576 && [dict get $p2 gfx] == 0}]
check "gpu: a process with no fdinfo uses nothing" [expr {[monitor::gpu::process 99999] eq [dict create vram 0 gfx 0 cycles 0 total 0]}]
# fdinfo is read again only for the GPU's fds and for fds that are new since the last look (the sampler looks at
# every process every second, and a browser holds thousands of fds); all of them every tenth look
set G [exec mktemp -d]
file mkdir $G/9001/fdinfo
for {set fd 0} {$fd < 50} {incr fd} { set ch [open $G/9001/fdinfo/$fd w]; puts $ch "pos:\t0\nflags:\t02"; close $ch }
file copy [file join $fx proc-gpu 7001 fdinfo 5] $G/9001/fdinfo/50
set c51 [string map {"client-id:\t7" "client-id:\t8"} [monitor::slurp [file join $fx proc-gpu 7001 fdinfo 5]]]
set ::monitor::proc_root $G
set ::reads 0
trace add execution monitor::slurp enter count_reads
set q1 [monitor::gpu::process 9001]; set r1 $::reads
set q2 [monitor::gpu::process 9001]; set r2 [expr {$::reads - $r1}]
set ch [open $G/9001/fdinfo/51 w]; puts -nonewline $ch $c51; close $ch
set q3 [monitor::gpu::process 9001]; set r3 [expr {$::reads - $r1 - $r2}]
trace remove execution monitor::slurp enter count_reads
check "gpu: a second look reads only the GPU's fdinfo" [expr {$r1 == 51 && $r2 == 1 && $q1 eq $q2}]
check "gpu: a new fd is read" [expr {$r3 == 2 && [dict get $q3 vram] == 2 * [dict get $q1 vram]}]
set ::monitor::proc_root [file join $fx proc-gpu]
file delete -force $G
# nvidia-smi runs beside the caller: the first call starts it, the answer is there once it has ended
proc wait_for {script ms} {
	set until [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 $script]} {
		if {[clock milliseconds] >= $until} { return 0 }
		after 20 {set ::tick 1}; vwait ::tick
	}
	return 1
}
set ::monitor::gpu::nvidia_smi [list sh [file join $fx nvidia-smi]]
set first [monitor::gpu::nvidia_cards]
wait_for {expr {[info exists ::monitor::gpu::said(cards)]}} 5000
set nc [lindex [monitor::gpu::cards] 0]
check "gpu nvidia: nothing before nvidia-smi has answered, then its card" [expr {$first eq {} && $nc ne "" && [dict get $nc driver] eq "nvidia" && [dict get $nc name] eq "NVIDIA GeForce RTX 4070" && [dict get $nc busy] == 43 && [dict get $nc vram_used] == 3072 * 1048576 && [dict get $nc temp] == 61 && abs([dict get $nc power] - 118.5) < 0.01 && [dict get $nc fan] eq ""}]
monitor::gpu::nvidia_procs
wait_for {expr {[info exists ::monitor::gpu::said(procs)]}} 5000
set np [monitor::gpu::nvidia_procs]
check "gpu nvidia: per-process load and memory from pmon, a dash is none" [expr {[dict exists $np 4242] && [dict get $np 4242] eq [list 37 [expr {2048 * 1048576}]] && [lindex [dict get $np 4243] 0] == 0.0 && [lindex [dict get $np 4243] 1] == 64 * 1048576}]
set ::monitor::gpu::nvidia_smi [list [file join $fx no-such-command]]
array unset ::monitor::gpu::said
check "gpu nvidia: no nvidia-smi, no card and no error" [expr {[monitor::gpu::nvidia_cards] eq {} && [monitor::gpu::nvidia_procs] eq {}}]
check "gpu: the graph's newest value is at the right edge, 100 at the top" [expr {[monitor::graph_points {50 100} 60 0 0 590 100] eq {580.0 50.0 590.0 0.0}}]

# not responding: ss's table, then a real socket whose client never reads
set socks [monitor::stuck::parse [monitor::slurp [file join $fx ss-xn.txt]]]
check "stuck: connected stream sockets from ss -xn" [expr {[llength $socks] == 6 && [lindex $socks 1] eq {5002 5001 4096 *}}]
check "stuck: the programs' ends of the display sockets, not other sockets" [expr {[monitor::stuck::clients $socks {/run/user/1000/wayland-0 /tmp/.X11-unix/X* @/tmp/.X11-unix/X*}] eq [dict create 5002 4096 6002 128]}]
set ::monitor::stuck::ss [list [file join $fx no-such-command]]
check "stuck: without ss nothing is marked" [expr {[monitor::stuck::update] eq {}}]
set ::monitor::stuck::ss {ss -xn}
set ::monitor::proc_root /proc
if {[auto_execok ss] ne "" && [auto_execok python3] ne ""} {
	set T [exec mktemp -d]
	set hang [exec python3 [file join $fx hang.py] $T/display $T/pid 20 </dev/null >/dev/null 2>/dev/null &]
	wait_for [list file exists $T/pid] 5000
	set child [string trim [monitor::slurp $T/pid]]
	set ::monitor::stuck::displays [list $T/display]
	set ::monitor::stuck::need 3
	set one [monitor::stuck::update]
	set found 0
	set until [expr {[clock milliseconds] + 10000}]
	while {[clock milliseconds] < $until} {
		after 300
		set late [monitor::stuck::update]
		if {$child in $late} { set found 1; break }
	}
	check "stuck: a client that leaves the display's data unread is found, after several looks" [expr {$child ne "" && $child ni $one && $found}]
	check "stuck: the display's own end is not marked" [expr {$hang ni $late}]
	catch {exec kill $hang}
	catch {exec kill -9 $child}
	wait_gone $child 3000
	check "stuck: a client that has gone is forgotten" [expr {$child ni [monitor::stuck::update] && [array size ::monitor::stuck::seen] == 0}]
	file delete -force $T
} else {
	puts "  skip stuck on a real socket (no ss / python3)"
}

# the game for the rail's foot, and its frame figures
set T [exec mktemp -d]
file mkdir $T/proc/8001 $T/proc/8002 $T/proc/8003
set ch [open $T/proc/8001/environ w]; puts -nonewline $ch "HOME=/home/u\0SteamAppId=1091500\0"; close $ch
set ch [open $T/proc/8002/environ w]; puts -nonewline $ch "HOME=/home/u\0SteamAppId=0\0"; close $ch
foreach {pid args} {8001 {game.exe} 8002 {steam} 8003 {lutris-wrapper lutris:rungame/quake} 8004 {/opt/doom/doom -fullscreen}} {
	file mkdir $T/proc/$pid
	set ch [open $T/proc/$pid/cmdline w]; puts -nonewline $ch "[join $args \0]\0"; close $ch
}
set ch [open $T/proc/uptime w]; puts $ch "5000.00 9000.00"; close $ch
set ::monitor::proc_root $T/proc
set gp [list [dict create pid 8001 start 400000 comm game.exe cmd game.exe] [dict create pid 8002 start 450000 comm steam cmd steam] \
	[dict create pid 8003 start 100000 comm lutris-wrapper cmd "lutris-wrapper lutris:rungame/quake"]]
set ::monitor::game::store 0
set game [monitor::game::find $gp [dict create 8001 "Cyberpunk 2077" 8002 Steam]]
check "game: found by SteamAppId (not Steam itself), named after its app, with its running time" [expr {$game eq [dict create pid 8001 name "Cyberpunk 2077" secs 1000]}]
check "game: a lutris:rungame argument" [expr {[dict get [monitor::game::find [lrange $gp 1 2] {}] pid] == 8003}]
set doom [list [dict create pid 8004 start 480000 comm doom cmd "/opt/doom/doom -fullscreen"]]
check "game: none (Steam itself is not a game)" [expr {[monitor::game::find [concat [lrange $gp 1 1] $doom] {}] eq ""}]
# a game added by hand: the overlay's store, stood in for
namespace eval ::hud::store { proc changed {} { return 0 }; proc load {} {}; proc programs {} { return {path:/opt/doom/doom /opt/doom/doom} } }
set ::monitor::game::store 1
check "game: the program of a game added by hand in Settings" [expr {[dict get [monitor::game::find [concat [lrange $gp 1 1] $doom] {}] pid] == 8004}]
set ::monitor::game::store 0
unset -nocomplain ::env(RIBBON_HUD_FRAMES)
check "frames: no source, no figures" [expr {[dict get [monitor::game::frames] ok] == 0}]
set ::env(RIBBON_HUD_FRAMES) $T/frames
set ch [open $T/frames w]; puts $ch [concat [lrepeat 99 8.0] fps=50]; close $ch
set fr [monitor::game::frames]
check "frames: FPS, frame time and 1% low as the overlay works them out" [expr {[dict get $fr ok] && [dict get $fr fps] == 119 && [dict get $fr ft] eq "8.4" && [dict get $fr low] == 125 && [llength [dict get $fr series]] == 60 && [lindex [dict get $fr series] end] == 100.0}]
file mtime $T/frames [expr {[clock seconds] - 10}]
check "frames: a file that has stopped is no frame data" [expr {[dict get [monitor::game::frames] ok] == 0}]
check "spans: seconds, minutes, hours" [expr {[monitor::fmt_span 40] eq "40 s" && [monitor::fmt_span 720] eq "12 min" && [monitor::fmt_span 4620] eq "1 h 17 min"}]
# the GPU page's Display row: wlr-randr's current mode, and HDR when `ribbon-hdr status` says it is on and applied
set randr [file join $T wlr-randr]
set ch [open $randr w]
puts $ch "#!/bin/sh\ncat <<'EOF'\nDP-1 \"Some Monitor\"\n  Modes:\n    1920x1080 px, 60.000000 Hz\n    2560x1440 px, 164.958000 Hz (preferred, current)\n  Enabled: yes\nEOF"
close $ch
set hdr [file join $T ribbon-hdr]
proc hdr_stub {setting renderer} {
	set ch [open $::hdr w]
	puts $ch "#!/bin/sh\n\[ \"\$1\" = status \] || exit 2\necho 'HDR: $setting   SDR white: 250 nits   game env: yes'\necho 'Renderer in this session: $renderer'"
	close $ch
}
file attributes $randr -permissions 0755
set ::monitor::cmd(randr) $randr
set ::monitor::cmd(hdr) $hdr
hdr_stub on vulkan; file attributes $hdr -permissions 0755
check "display: the mode, with HDR when it is on (2560 × 1440 · 165 Hz · HDR)" [expr {[monitor::display_now] eq "2560 \u00d7 1440 \u00b7 165 Hz \u00b7 HDR"}]
hdr_stub on {gles2 (default)}
check "display: HDR saved but not applied (the GL renderer) is not HDR" [expr {[monitor::display_now] eq "2560 \u00d7 1440 \u00b7 165 Hz"}]
hdr_stub off vulkan
check "display: HDR off" [expr {[monitor::display_now] eq "2560 \u00d7 1440 \u00b7 165 Hz"}]
set ::monitor::cmd(hdr) [file join $T no-such-ribbon-hdr]
check "display: no ribbon-hdr, no HDR" [expr {[monitor::display_now] eq "2560 \u00d7 1440 \u00b7 165 Hz"}]
set ::monitor::cmd(randr) [file join $T no-such-wlr-randr]
check "display: no wlr-randr, no row" [expr {[monitor::display_now] eq ""}]
file delete -force $T
set ::monitor::proc_root /proc

puts [expr {$fails ? "monitor-lib: $fails failure(s)" : "monitor-lib: all checks passed"}]
exit [expr {$fails ? 1 : 0}]
