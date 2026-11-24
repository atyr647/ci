# tests/monitor-scene.tcl - a board scene for the System monitor (RIBBON_MONITOR_SCENE): the
# numbers of Monitor-R3-Ledger (apps) or, with RIBBON_MONITOR_BOARD=processes, of
# Monitor-R3-Ledger-Processes (Discord not responding, its menu open), or with =gpu of
# Monitor-R3-Ledger-GPU. The model is set directly, so the window draws the board's
# values; the live sampler is not started in a scene.
#   RIBBON_MONITOR_SHOT = file: a grab of the window (ImageMagick import), then exit

namespace eval monitor {
	variable scene_board
}
set board [expr {[info exists ::env(RIBBON_MONITOR_BOARD)] ? $::env(RIBBON_MONITOR_BOARD) : "ledger"}]
set G 1073741824.0

proc scene_app {id name count cpu gpu mem disk pids} {
	dict create id $id name $name count $count cpu $cpu gpu $gpu mem $mem disk $disk vram 0 pids $pids
}
proc scene_proc {pid name app cpu mem threads {gpu 0.0} {disk 0.0}} {
	set id [dict get {"Cyberpunk 2077" cyberpunk Steam steam "OBS Studio" obs Firefox firefox Discord discord Background ""} $app]
	dict create pid $pid name $name app $app appid $id cpu $cpu gpu $gpu mem $mem threads $threads disk $disk vram 0 \
		state S stuck [expr {$::board eq "processes" && $pid == 4182}] cmdline $name
}
set ui::caretfix off

if {$board eq "processes"} {
	set procs [list \
		[scene_proc 4182 Discord Discord 6.3 [expr {288 * 1048576.0}] 38] \
		[scene_proc 9310 Cyberpunk2077.exe "Cyberpunk 2077" 23.9 [expr {7.6 * $G}] 112] \
		[scene_proc 2240 steamwebhelper Steam 2.4 [expr {412 * 1048576.0}] 31] \
		[scene_proc 5121 obs OBS\ Studio 2.2 [expr {480 * 1048576.0}] 44] \
		[scene_proc 1033 Xwayland Background 1.1 [expr {96 * 1048576.0}] 9] \
		[scene_proc 3011 firefox Firefox 0.9 [expr {1.1 * $G}] 88] \
		[scene_proc 988 pipewire Background 0.5 [expr {24 * 1048576.0}] 6] \
		[scene_proc 9288 wineserver "Cyberpunk 2077" 0.4 [expr {42 * 1048576.0}] 2] \
		[scene_proc 2201 steam Steam 0.4 [expr {296 * 1048576.0}] 64] \
		[scene_proc 4231 "Discord renderer" Discord 0.0 [expr {196 * 1048576.0}] 22] \
		[scene_proc 902 ribbon-shell Background 0.3 [expr {64 * 1048576.0}] 12] \
		[scene_proc 874 kwin_wayland Background 0.3 [expr {148 * 1048576.0}] 18] \
		[scene_proc 3088 "Isolated Web Co" Firefox 0.2 [expr {380 * 1048576.0}] 29] \
		[scene_proc 5160 obs-browser-page "OBS Studio" 0.1 [expr {122 * 1048576.0}] 17] \
		[scene_proc 1240 gamemoded Background 0.1 [expr {6 * 1048576.0}] 3]]
	set apps [list [scene_app cyberpunk "Cyberpunk 2077" 31 24.6 93 [expr {7.9 * $G}] 2e6 {9310}]]
	set ::monitor::view processes
	set ::monitor::expanded {}
	set ::monitor::sel pid:4182
	set ::monitor::menu [dict create key pid:4182 x 600 y 186 hover end]
} elseif {$board eq "gpu"} {
	set procs {}
	set apps {}
	foreach {id name gpu vram} {cyberpunk "Cyberpunk 2077" 93 12.1 obs "OBS Studio" 2 0.4 firefox Firefox 1 0.3 steam Steam 0 0.2 discord Discord 0 0.1 "" Background 1 0.3} {
		lappend apps [dict create id $id name $name count 1 cpu 0.0 gpu $gpu mem 0 disk 0 vram [expr {$vram * $G}] pids {}]
	}
	# the board's two lines: the load near 97, the temperature near 71
	for {set i 0} {$i < 60} {incr i} {
		monitor::ring::push gpu [expr {97 + 1.5 * sin($i * 0.9) * cos($i * 0.37)}]
		monitor::ring::push gputemp [expr {71 + sin($i * 0.5) * cos($i * 0.23)}]
	}
} else {
	set procs [list \
		[scene_proc 9310 Cyberpunk2077.exe "Cyberpunk 2077" 23.9 [expr {7.6 * $G}] 112 93 2e6] \
		[scene_proc 9311 wineserver "Cyberpunk 2077" 0.4 [expr {42 * 1048576.0}] 2] \
		[scene_proc 9312 pressure-vessel "Cyberpunk 2077" 0.1 [expr {18 * 1048576.0}] 1] \
		[scene_proc 9313 steam.exe "Cyberpunk 2077" 0.1 [expr {96 * 1048576.0}] 3] \
		[scene_proc 9314 winedevice.exe "Cyberpunk 2077" 0.1 [expr {38 * 1048576.0}] 4] \
		[scene_proc 9315 explorer.exe "Cyberpunk 2077" 0.01 [expr {31 * 1048576.0}] 2]]
	# the game's other 25 processes (the board's "25 more" row: 0.1%, 141 MB), and the rest of the 214
	set gamepids {9310 9311 9312 9313 9314 9315}
	for {set i 0} {$i < 25} {incr i} {
		lappend procs [scene_proc [expr {9400 + $i}] wine-helper "Cyberpunk 2077" 0.004 [expr {141 * 1048576.0 / 25}] 1]
		lappend gamepids [expr {9400 + $i}]
	}
	for {set i 0} {$i < 183} {incr i} { lappend procs [scene_proc [expr {10000 + $i}] worker Background 0.0 1048576.0 1] }
	set apps [list \
		[scene_app cyberpunk "Cyberpunk 2077" 31 24.6 93 [expr {7.9 * $G}] 2e6 $gamepids] \
		[scene_app steam Steam 12 3.1 0 [expr {1.1 * $G}] 41e6 {}] \
		[scene_app obs "OBS Studio" 3 2.2 2 [expr {480 * 1048576.0}] 0 {}] \
		[scene_app firefox Firefox 14 1.4 1 [expr {2.4 * $G}] 0 {}] \
		[scene_app discord Discord 6 0.6 0 [expr {612 * 1048576.0}] 0 {}] \
		[scene_app files Files 1 0.1 0 [expr {96 * 1048576.0}] 0 {}] \
		[scene_app terminal Terminal 2 0.1 0 [expr {18 * 1048576.0}] 0 {}] \
		[scene_app "" Background 145 2.2 1 [expr {1.6 * $G}] 1e6 {}]]
	set ::monitor::view apps
	set ::monitor::expanded cyberpunk
	set ::monitor::sel app:steam
}
set ::monitor::metric [expr {$board eq "gpu" ? "gpu" : "apps"}]
set ::monitor::sort cpu
set series {}
for {set i 0} {$i < 60} {incr i} { lappend series [expr {44.5 + 2.5 * sin($i * 1.3) * cos($i * 0.7) + ($i == 22 ? 22 : 0)}] }
set card [dict create driver amdgpu name "Radeon RX 7900 XT" busy 97 vram_used [expr {13.4 * $G}] vram_total [expr {20 * $G}] \
	temp 71 hot 88 fan 1650 power 284 cap 315 clock 2540 mclock 2500 bus "PCIe 4.0 \u00d7 16" dir ""]
# the Display row comes through monitor::display_now: wlr-randr and `ribbon-hdr status` stood in for (HDR on and
# applied), as the board's "2560 × 1440 · 165 Hz · HDR"
set stubs [file join $::env(HOME) monitor-stubs]
file mkdir $stubs
set ch [open [file join $stubs wlr-randr] w]
puts $ch "#!/bin/sh\necho 'DP-1 \"Monitor\"'\necho '    2560x1440 px, 164.956000 Hz (preferred, current)'"
close $ch
set ch [open [file join $stubs ribbon-hdr] w]
puts $ch "#!/bin/sh\necho 'HDR: on   SDR white: 250 nits   game env: yes'\necho 'Renderer in this session: vulkan'"
close $ch
foreach f {wlr-randr ribbon-hdr} { file attributes [file join $stubs $f] -permissions 0755 }
set ::monitor::cmd(randr) [file join $stubs wlr-randr]
set ::monitor::cmd(hdr) [file join $stubs ribbon-hdr]
set ::monitor::model [dict create cpu 34.0 gpu 97.0 vram_used [expr {13.4 * $G}] vram_total [expr {20 * $G}] \
	mem_used [expr {14.2 * $G}] mem_total [expr {32 * $G}] disk 44e6 disk_rd 2e6 disk_wr 42e6 \
	net_rx 37.6e6 net_tx 0.4e6 ncpu 16 apps $apps procs $procs card $card gamemode 1 gpu_secs 4620 \
	display [monitor::display_now] \
	game [dict create pid 9310 name "Cyberpunk 2077" secs 4620] \
	frames [dict create ok 1 fps 112 ft 8.9 low 84 series $series]]
if {$board eq "processes"} { dict set ::monitor::model cpu 40.0 }
if {[info exists ::env(RIBBON_MONITOR_SHOT)]} {
	proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }
	after 600 { update; exec import -window [winfo id $::monitor::win] $::env(RIBBON_MONITOR_SHOT); exit 0 }
}
