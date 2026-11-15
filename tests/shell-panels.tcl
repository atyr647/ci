# shell-panels.tcl - the bar's panels over the system bus and the shell's pipes (U50b; controls.tcl, status.tcl,
# bar.tcl), in the real shell under xvfb (RIBBON_SHELL_TEST=this file; tests/steps.d/46-shell-panels.sh).
# The step starts a private system bus with the NetworkManager stand-in (tests/fixtures/nm.tcl) and the BlueZ
# stand-in (tests/fixtures/bluez.tcl) on it, and a wpctl stub that sleeps 3 s and logs its calls (PANEL_STUBS).
# The checks: the system bus is connected only when a panel first opens; Wi-Fi is read from NetworkManager and
# Bluetooth from BlueZ, with no polling (signals start the reads); actions are method calls; a failed read keeps
# the last data; the volume read and step are pipes, so the event loop runs while wpctl sleeps; the power key
# shows the session panel only with POWER_KEY_ASK=yes; the battery percentage follows BAR_PERCENT.

set failed 0
interp bgerror {} {apply {{msg opts} { puts "  FAIL background error: [dict get $opts -errorinfo]"; exit 1 }}}
after 90000 {puts "  FAIL the panel checks took more than 90 s"; exit 1}
proc ok {what} { puts "  ok   $what" }
proc bad {what why} { global failed; incr failed; puts "  FAIL $what: $why" }
proc check {what cond why} { if {$cond} { ok $what } else { bad $what $why } }

# the event loop counts while nothing blocks it
set ::ticks 0
proc tick {} { incr ::ticks; after 20 tick }
tick

# a plan: each step runs after its delay in ms; a failing step is reported and the plan goes on
set ::plan {}
proc at {ms script} { lappend ::plan [list $ms $script] }
proc run_plan {} {
	if {![llength $::plan]} { finish; return }
	set item [lindex $::plan 0]
	set ::plan [lrange $::plan 1 end]
	after [lindex $item 0] [list run_one [lindex $item 1]]
}
proc run_one {script} {
	if {[catch {uplevel #0 $script} err]} { bad "a check step" "$err | $::errorInfo" }
	run_plan
}
proc finish {} {
	puts [expr {$::failed ? "  panel checks FAILED" : "  all panel checks passed"}]
	exit [expr {$::failed ? 1 : 0}]
}

# the log of a stand-in: the lines with TAB separators, as a list of lists
proc logged {file} {
	if {![file exists $file]} { return {} }
	set fh [open $file]; set t [read $fh]; close $fh
	set out {}
	foreach l [split [string trim $t] \n] { lappend out [split $l \t] }
	return $out
}
proc nlogged {file verb} {
	set n 0
	foreach l [logged $file] { if {[lindex $l 0] eq $verb} { incr n } }
	return $n
}
proc lastlog {file verb} {
	set last ""
	foreach l [logged $file] { if {[lindex $l 0] eq $verb} { set last $l } }
	return $last
}

# a client of the stand-ins on the same private bus, for the changes made from outside (signals)
package require ribbon::dbus
set ::client [ribbon::dbus::connect system]
set NMLOG $::env(NM_LOG)
set BZLOG $::env(BLUEZ_LOG)

# the reads are counted: the NetworkManager client's (installed once it is loaded, by the first panel) and BlueZ's.
# A NetworkManager read can be made to fail, as a stopped NetworkManager would fail it.
set ::fail_nm 0
set ::nmreads 0
set ::bzreads 0
rename ::panel::bz_read ::panel::bz_read_real
proc ::panel::bz_read {bus} { incr ::bzreads; ::panel::bz_read_real $bus }
proc install_nm_counter {} {
	rename ::nm::read ::nm::read_real
	proc ::nm::read {} {
		if {$::fail_nm} { return [dict create wifi 0 devices {} error "NetworkManager is not running" saved {} active {}] }
		incr ::nmreads
		::nm::read_real
	}
}
proc dev_conn {name} {
	foreach d $::panel::data(devs) { if {[lindex $d 1] eq $name} { return [lindex $d 2] } }
	return "missing"
}

# 1. nothing is connected to the system bus before a panel opens (shell::bus connects it on first use)
at 0 {
	check "the system bus is not connected at start" [expr {![info exists ::shell::buses(system)]}] \
		"connected: [array names ::shell::buses]"
	panel::show wifi
	install_nm_counter
	check "nothing is listed until NetworkManager answers" [expr {$::panel::data(nets) eq {}}] "nets $::panel::data(nets)"
	check "the panel is drawn while it waits" [expr {[llength [.panel.c find all]] > 0}] "nothing drawn"
	set ::ticks0 $::ticks
}

# 2. the Wi-Fi networks come from NetworkManager (the stand-in's five networks, the strongest of each name)
at 400 {
	check "the system bus is connected by the first panel" [info exists ::shell::buses(system)] "no bus"
	check "the event loop ran while the bus answered (ticks in 0.4 s: [expr {$::ticks - $::ticks0}])" \
		[expr {$::ticks - $::ticks0 >= 15}] "blocked"
	set names {}
	foreach n $::panel::data(nets) { lappend names [lindex $n 0] }
	check "five networks are listed, the hidden one left out" [expr {[llength $names] == 5}] "nets $names"
	check "the active network comes first and is on" \
		[expr {[lindex $::panel::data(nets) 0 0] eq "Hearth" && [lindex $::panel::data(nets) 0 1] == 1}] \
		"first [lindex $::panel::data(nets) 0]"
	check "the strongest access point of a name is its signal (Hearth 82)" \
		[expr {[lindex $::panel::data(nets) 0 2] == 82}] "signal [lindex $::panel::data(nets) 0 2]"
	check "a network with a password is secured, an open one is not" \
		[expr {[lindex $::panel::data(nets) end 0] eq "Cafe Lumen" && [lindex $::panel::data(nets) end 3] == 0}] \
		"nets $::panel::data(nets)"
	check "the saved network is known (Hearth; the WireGuard profile is not Wi-Fi)" \
		[expr {$::panel::data(known) eq "Hearth"}] "known $::panel::data(known)"
	check "the Wi-Fi radio is on" [expr {$::panel::data(radio) == 1}] "radio $::panel::data(radio)"
	check "the panel draws the networks" [expr {[llength [.panel.c find all]] > 20}] "few items"
}

# 3. no polling: with nothing changing, nothing is read; a second refresh while one runs is coalesced
at 0 {
	set ::reads0 $::nmreads
}
at 1600 {
	check "no NetworkManager read happens while nothing changes (1.5 s idle, reads: [expr {$::nmreads - $::reads0}])" \
		[expr {$::nmreads == $::reads0}] "read $::nmreads, was $::reads0"
}

# 4. a NetworkManager signal starts the read: the radio switched from outside shows at once
at 0 {
	set ::reads1 $::nmreads
	$::client call org.freedesktop.NetworkManager /org/freedesktop/NetworkManager org.freedesktop.DBus.Properties \
		Set ssv org.freedesktop.NetworkManager WirelessEnabled [list b 0]
}
at 400 {
	check "a NetworkManager signal starts a read (the radio changed outside)" [expr {$::nmreads > $::reads1}] \
		"reads $::nmreads"
	check "the radio's new state is shown" [expr {$::panel::data(radio) == 0}] "radio $::panel::data(radio)"
	# the tray panel's data is refreshed too
	$::client call org.freedesktop.NetworkManager /org/freedesktop/NetworkManager org.freedesktop.DBus.Properties \
		Set ssv org.freedesktop.NetworkManager WirelessEnabled [list b 1]
}
at 400 {
	check "the radio comes back on by a signal" [expr {$::panel::data(radio) == 1}] "radio $::panel::data(radio)"
}

# 5. the radio switch is an action: a method call on the client (nm::set_wifi)
at 0 {
	set ::wlog0 [nlogged $NMLOG wifi]
	panel::set_radio
}
at 400 {
	check "the radio switch calls NetworkManager (wifi 0 logged)" \
		[expr {[nlogged $NMLOG wifi] == $::wlog0 + 1 && [lindex [lastlog $NMLOG wifi] 1] eq "0"}] "log [lastlog $NMLOG wifi]"
	check "the radio is off after the switch's signal" [expr {$::panel::data(radio) == 0}] "radio $::panel::data(radio)"
	panel::set_radio
}
at 400 {
	check "the switch back on is logged and shown" \
		[expr {[lindex [lastlog $NMLOG wifi] 1] eq "1" && $::panel::data(radio) == 1}] "radio $::panel::data(radio)"
}

# 6. a failed read keeps the last data (NetworkManager stopped)
at 0 {
	set ::nets_before $::panel::data(nets)
	set ::fail_nm 1
	panel::nm_load
}
at 300 {
	check "a failed read keeps the last networks" [expr {$::panel::data(nets) eq $::nets_before}] \
		"nets changed to $::panel::data(nets)"
	set ::fail_nm 0
}

# 7. a join is a method call: an open network connects, a secured one asks for its password first
at 0 {
	panel::join {Cafe Lumen} 0
}
at 300 {
	set l [lastlog $NMLOG connect]
	check "an open network is joined through NetworkManager (connect Cafe Lumen)" \
		[expr {[lindex $l 1] eq "Cafe Lumen" && [lindex $l 4] eq "none"}] "log $l"
	panel::join Hearth 1
}
at 0 {
	check "the network that is already on is not joined again" [expr {[nlogged $NMLOG activate] == 0 && [lindex [lastlog $NMLOG connect] 1] eq "Cafe Lumen"}] \
		"activate [nlogged $NMLOG activate]"
	panel::join Hearth-Guest 1
}
at 0 {
	check "a secured network asks for its password" [expr {$::panel::ask eq "Hearth-Guest"}] "ask $::panel::ask"
	foreach c {h u n t e r} { panel::key $c $c 0 }
	panel::key Return "" 0
}
at 300 {
	set l [lastlog $NMLOG connect]
	check "the password goes to NetworkManager (connect Hearth-Guest, psk, secret sent)" \
		[expr {[lindex $l 1] eq "Hearth-Guest" && [lindex $l 4] eq "wpa-psk" && [lindex $l 5] eq "1"}] "log $l"
	check "the password is cleared after the connect" [expr {$::panel::ask eq "" && $::panel::password eq ""}] \
		"ask $::panel::ask"
	panel::close
}

# 8. Bluetooth: BlueZ's paired devices, the headset (connected, 64%) first, the speaker (not paired) left out
at 0 {
	panel::show bt
}
at 400 {
	check "Bluetooth reads BlueZ's paired devices (the speaker, not paired, is left out)" \
		[expr {[llength $::panel::data(devs)] == 2}] "devs $::panel::data(devs)"
	set d [lindex $::panel::data(devs) 0]
	check "the connected headset comes first, with its battery" \
		[expr {[lindex $d 1] eq "Headphones" && [lindex $d 2] == 1 && [lindex $d 4] eq "64"}] "devs $::panel::data(devs)"
	check "the keyboard is paired and not connected" \
		[expr {[lindex $::panel::data(devs) 1 1] eq "Keyboard" && [lindex $::panel::data(devs) 1 2] == 0}] \
		"devs $::panel::data(devs)"
	check "the adapter is powered" [expr {$::panel::data(powered) == 1}] "powered $::panel::data(powered)"
	check "the BlueZ read ran once" [expr {$::bzreads >= 1}] "bzreads $::bzreads"
}

# 9. BlueZ's signal starts a read: the adapter switched from outside
at 0 {
	set ::bz0 $::bzreads
	$::client call org.bluez /org/bluez/hci0 org.freedesktop.DBus.Properties Set ssv org.bluez.Adapter1 Powered [list b 0]
}
at 400 {
	check "a BlueZ signal starts a read (the adapter went off outside)" [expr {$::bzreads > $::bz0}] "reads $::bzreads"
	check "the adapter's power is shown" [expr {$::panel::data(powered) == 0}] "powered $::panel::data(powered)"
	# 10. actions: the power switch and a device's connection are method calls
	panel::bz_power
}
at 400 {
	check "the power switch calls BlueZ (power 1 logged)" [expr {[lindex [lastlog $BZLOG power] 1] eq "1"}] \
		"log [lastlog $BZLOG power]"
	check "the adapter is on after the switch" [expr {$::panel::data(powered) == 1}] "powered $::panel::data(powered)"
	panel::bz_device AA:BB:CC:DD:EE:FF 0
}
at 400 {
	check "a device's disconnect is a method call on its path" \
		[expr {[lindex [lastlog $BZLOG disconnect] 1] eq "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"}] \
		"log [lastlog $BZLOG disconnect]"
	check "the headset shows disconnected after BlueZ's signal" [expr {[dev_conn Headphones] == 0}] \
		"devs $::panel::data(devs)"
	panel::bz_device 11:22:33:44:55:66 1
}
at 400 {
	check "the keyboard connects (connect logged)" \
		[expr {[lindex [lastlog $BZLOG connect] 1] eq "/org/bluez/hci0/dev_11_22_33_44_55_66"}] "log [lastlog $BZLOG connect]"
	panel::close
}

# 11. the volume is read in a pipe: the stub wpctl sleeps 3 s, and the event loop runs meanwhile
at 0 {
	set ::ticks1 $::ticks
	status::volume_step 5
	status::volume_read
}
at 1000 {
	check "a volume step does not block the event loop (ticks in 1 s: [expr {$::ticks - $::ticks1}])" \
		[expr {$::ticks - $::ticks1 >= 25}] "blocked"
}
at 2600 {
	check "the volume is read after wpctl's 3 s (0.40)" [expr {$status::volume eq "0.40"}] "volume $status::volume"
	check "wpctl was run for the step and the read" \
		[expr {[file exists [file join $::env(PANEL_STUBS) calls]] && [string match "*set-volume*" [read_file [file join $::env(PANEL_STUBS) calls]]]}] \
		"no set-volume call"
}

# 12. the power key: only with POWER_KEY_ASK=yes in power.conf does it show the session panel (Lock, Sleep, ...)
proc read_file {f} { set fh [open $f]; set t [read $fh]; close $fh; return $t }
at 0 {
	check "the power key verb is registered (ribbon-shell-ctl power-menu)" [dict exists $shell::verbs power-menu] \
		"verbs [dict keys $shell::verbs]"
	set cfg [file join $::env(XDG_CONFIG_HOME) ribbon]
	file mkdir $cfg
	set fh [open [file join $cfg power.conf] w]; puts $fh "DIM=yes\nPOWER_KEY_ASK=no"; close $fh
	{*}[dict get $shell::verbs power-menu]
}
at 0 {
	check "the power key does nothing with POWER_KEY_ASK=no" [expr {$panel::open eq ""}] "open $panel::open"
	set fh [open [file join $::env(XDG_CONFIG_HOME) ribbon power.conf] w]; puts $fh "POWER_KEY_ASK=yes"; close $fh
	{*}[dict get $shell::verbs power-menu]
}
at 0 {
	check "the power key shows the session panel with POWER_KEY_ASK=yes" [expr {$panel::open eq "session"}] "open $panel::open"
	panel::close
	check "the bar's power setting reads the last line (POWER_KEY_ASK=yes)" \
		[expr {[bar::power_conf POWER_KEY_ASK no] eq "yes"}] "value [bar::power_conf POWER_KEY_ASK no]"
	check "BAR_PERCENT defaults to yes when the file has no such key" [expr {[bar::power_conf BAR_PERCENT yes] eq "yes"}] \
		"value [bar::power_conf BAR_PERCENT yes]"
}

# 13. the battery's percentage in the tray, when BAR_PERCENT is not no (the tray is wider by the text and its gap)
at 0 {
	set status::battery 80
	bar::draw
	set wp [lsearch -inline -index 0 $bar::placed tray]
	set with [lindex $wp 2]
	set fh [open [file join $::env(XDG_CONFIG_HOME) ribbon power.conf] w]; puts $fh "BAR_PERCENT=no"; close $fh
	bar::draw
	set without [lindex [lsearch -inline -index 0 $bar::placed tray] 2]
	check "BAR_PERCENT=no hides the percentage (the tray is [expr {$with - $without}] px narrower with it)" \
		[expr {$with - $without == [expr {round([text::width f12s 80%])}] + 7}] "difference [expr {$with - $without}]"
	set fh [open [file join $::env(XDG_CONFIG_HOME) ribbon power.conf] w]; puts $fh "BAR_PERCENT=yes"; close $fh
	bar::draw
	check "BAR_PERCENT=yes shows it again" [expr {[lindex [lsearch -inline -index 0 $bar::placed tray] 2] == $with}] \
		"tray [lindex [lsearch -inline -index 0 $bar::placed tray] 2], was $with"
	set status::battery ""
	bar::draw
}

# every right-bar panel, opened in turn: its box starts under the bar's row (y 54) and ends inside the screen,
# and nothing it draws is above its top or below its bottom (the first row is not under the bar)
at 100 {
	foreach kind {tray sound wifi bt power storage session} {
		panel::show $kind
		update
		set d .panel.c
		set top [winfo rooty $d]
		set bottom [expr {$top + [winfo height $d]}]
		check "the $kind panel starts below the bar's row (y $top)" [expr {$top >= 54}] "top $top"
		check "the $kind panel ends inside the screen (bottom $bottom of [winfo screenheight .])" \
			[expr {$bottom <= [winfo screenheight .]}] "bottom $bottom"
		set box [$d bbox all]
		check "the $kind panel's rows are all inside its box" \
			[expr {[llength $box] == 4 && [lindex $box 1] >= 0 && [lindex $box 3] <= [winfo height $d]}] "bbox $box, height [winfo height $d]"
		panel::close
		update
	}
}

# the first step is the one that connects the bus: the plan runs in order, from the event loop
after 50 run_plan
