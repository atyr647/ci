# tests/monitor-r4-scene.tcl - the System monitor's round-4 boards as scenes (RIBBON_MONITOR_SCENE), on top of
# tests/monitor-scene.tcl's numbers: RIBBON_MONITOR_R4 = priority (Monitor-R4-Priority: the row menu with Priority's
# submenu open), stuck (Monitor-R4-Stuck: Discord not responding, the strip above the table), end (Monitor-R4-End: the
# End sheet for Discord) or services (Monitor-R4-Services: the person's dinit services, pipewire selected).
#   RIBBON_MONITOR_SHOT = file: a grab of the window, then exit (monitor-scene.tcl)

set r4 $::env(RIBBON_MONITOR_R4)
set ::env(RIBBON_MONITOR_BOARD) [expr {$r4 eq "priority" ? "processes" : "ledger"}]
uplevel #0 [list source -encoding utf-8 [file join [file dirname [file normalize [info script]]] monitor-scene.tcl]]
set M 1048576.0

if {$r4 eq "priority"} {
	set ::monitor::menu [dict create key pid:4182 x 600 y 186 hover prio sub 1 subhover low]
} elseif {$r4 in {stuck end}} {
	# Discord's six processes, the first not responding for 41 s
	set dprocs {}
	foreach {pid name cpu mem} {4182 Discord 6.2 288 4231 "Discord renderer" 0.0 196 4210 "Discord GPU process" 0.1 74
	                            4219 "Discord network" 0.0 32 4224 "Discord audio" 0.0 14 4190 "Discord zygote" 0.0 8} {
		set p [scene_proc $pid $name Discord $cpu [expr {$mem * $M}] 4]
		dict set p stuck [expr {$pid == 4182}]
		lappend dprocs $p
	}
	set apps {}
	foreach a [dict get $::monitor::model apps] {
		if {[dict get $a id] eq "discord"} { dict set a cpu 6.3; dict set a pids {4182 4231 4210 4219 4224 4190} }
		lappend apps $a
	}
	dict set ::monitor::model apps $apps
	# (six of the Background workers make room for them: the board's 214 processes)
	dict set ::monitor::model procs [concat $dprocs [lrange [dict get $::monitor::model procs] 0 end-6]]
	dict set ::monitor::model cpu 40.0
	set ::monitor::expanded {}
	set ::monitor::sel ""
	set ::monitor::stuck::since [dict create 4182 [expr {[clock milliseconds] - 41000}]]
	if {$r4 eq "end"} { monitor::end_ask app:discord }
} elseif {$r4 eq "services"} {
	dict set ::monitor::model cpu 40.0
	set ::monitor::metric services
	set ::monitor::svc_scope user
	set ::monitor::svc_sel pipewire
	set ::monitor::svc_list {}
	foreach {name pid state} {dbus 1402 running pipewire 1418 running pipewire-pulse 1431 running wireplumber 1426 running
	                          ribbon-shell 1450 running ribbon-notes-sync "" stopped syncthing "" failed mkkitfsd 1502 running
	                          ribbon-hud 1477 running foot-server 1466 running} {
		lappend ::monitor::svc_list [dict create name $name state $state pid $pid running [expr {$state eq "running"}]]
	}
}
