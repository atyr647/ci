# controls.tcl - the right bar's panels: Sound, Wi-Fi, Bluetooth, Battery
# and power, and Storage when the disk runs low, and session (the power button's Lock, Sleep, Log out, Restart,
# Shut down). Each grows out of the right bar (one shape, like the launcher
# results on the left) and talks to the system's own tools:
#   sound      wpctl / pactl (PipeWire)
#   Wi-Fi      NetworkManager over the system bus (ribbon::dbus, with Settings' apps/settings/nm.tcl): read on
#              the first open and again on each NetworkManager signal; nothing polls
#   Bluetooth  BlueZ over the system bus (ribbon::dbus): one GetManagedObjects per read, read again on BlueZ's signals
#              The system bus is connected by shell::bus when a panel first needs it, not at start-up.
#   power      /sys, powerprofilesctl, brightnessctl
#   storage    ribbon-reserve (pkexec for the system's part of a cleanup)
# Nothing runs while a panel is closed, and nothing the panel runs makes the shell wait: every command is
# read through a pipe by the event loop (panel::spawn). A panel draws its last data at once and redraws
# when a reply arrives; a failing command keeps the last data.

namespace eval panel {
	variable open ""        ;# sound | wifi | bt | power | storage | updates | session | ""
	variable sel 0          ;# the session panel's focused row (hover and Up/Down move it)
	variable hits {}        ;# {x0 y0 x1 y1 script}
	variable sliders {}     ;# {x0 x1 y0 y1 setter}
	variable drag ""
	variable data
	variable ask ""         ;# Wi-Fi network asking for a password
	variable password ""
	variable busy ""        ;# status text while something is happening
	variable pipes {}       ;# channel -> {kind fetch|act done out}: the commands running
	variable pending        ;# kind -> the gather job reading it
	variable jobs           ;# job id -> the gather's state
	variable seq 0
	variable here [file dirname [file normalize [info script]]]  ;# the shell's folder (nm.tcl is found beside it)
	variable bzbusy 0        ;# a BlueZ read is running
	variable bzagain 0       ;# a BlueZ change came while it ran: read once more
	variable bzlisten ""     ;# the bus BlueZ's signals are listened on
	variable bzpath {}       ;# device MAC -> object path
	variable bzadapter ""    ;# the adapter's object path
	array set pending {}
	array set jobs {}
	# the last data, before anything has been read: the panel draws this until a reply comes
	array set data {radio 0 nets {} known {} netinfo {} profiles {} powered 0 devs {} sinks {} vol "" mic "" profile "" bright ""}
}

# The tray button: quick settings; scroll changes the volume, middle-click
# mutes. Its tiles open the full Sound / Wi-Fi / Bluetooth / Power panels.
proc panel::toggle {kind b} {
	variable open
	if {$b == 4 || $b == 5} { status::volume_step [expr {$b == 4 ? 5 : -5}]; if {$open ne ""} { fetch $open; draw }; return }
	if {$b == 2} { fire {wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle}; status::volume_read; return }
	if {$b != 1} return
	if {$open ne ""} { close; return }
	launcher::cancel
	show $kind
}

proc panel::show {kind} {
	variable open
	variable ask
	variable sel
	set open $kind; set ask ""
	if {$kind eq "session"} {
		# the first row is focused; the keys go to the panel until it closes (as the Wi-Fi password does)
		set sel 0
		set launcher::keytarget panel::session_key
		launcher::input_show
	}
	state $kind
	fetch $kind
	bar::draw
	draw
}

proc panel::close {} {
	variable open
	variable ask
	if {$open eq ""} return
	set open ""; set ask ""
	cancel_fetches
	state ""
	upd::closed
	rbn::hide .panel
	launcher::input_hide
	set launcher::keytarget ""
	bar::draw
}

# The open panel, for the shell's state (fault.tcl): restored after a restart.
proc panel::state {kind} {
	if {[llength [info commands ::fault::save]]} { fault::save panel $kind }
}

# ---- running commands without waiting -----------------------------------------

# Runs CMD (a command and its words) in a pipe that the event loop reads. When it ends, DONE is called with
# ok (1 when it ran and exited 0) and its output. KIND is fetch (a panel's data: ended when the panel
# closes) or act (an action: left to finish). Returns the channel, or "" if it did not start.
proc panel::spawn {kind cmd done} {
	variable pipes
	if {[catch {open |[list {*}$cmd 2>/dev/null] r} ch]} {
		after idle [list {*}$done 0 ""]
		return ""
	}
	fconfigure $ch -blocking 0 -encoding utf-8
	dict set pipes $ch [dict create kind $kind done $done out ""]
	fileevent $ch readable [list panel::spawn_read $ch]
	return $ch
}

proc panel::spawn_read {ch} {
	variable pipes
	if {![dict exists $pipes $ch]} { catch {::close $ch}; return }
	set job [dict get $pipes $ch]
	dict set job out [dict get $job out][read $ch]
	if {![eof $ch]} { dict set pipes $ch $job; return }
	fileevent $ch readable {}
	dict unset pipes $ch
	set ok [expr {![catch {::close $ch}]}]
	{*}[dict get $job done] $ok [dict get $job out]
}

# A command whose result is not shown (a volume or brightness change). DONE, if given, runs when it ends.
proc panel::fire {cmd {done ""}} {
	spawn act $cmd [list panel::fired $done]
}
proc panel::fired {done ok out} {
	if {$done ne ""} { {*}$done }
}

# Ends the fetches still running (the panel closed): each pipe is killed and closed, so no channel is left.
proc panel::cancel_fetches {} {
	variable pipes
	variable pending
	variable jobs
	dict for {ch job} $pipes {
		if {[dict get $job kind] ne "fetch"} continue
		fileevent $ch readable {}
		dict unset pipes $ch
		catch {exec kill -TERM {*}[pid $ch]}
		catch {::close $ch}
	}
	array unset pending
	array unset jobs
}

# Runs each of CMDS at once; when they have all ended, FINISH is called with their outputs in order. If one
# failed, FINISH is not called and the panel keeps what it had. A kind has one such job at a time.
proc panel::gather {kind cmds finish} {
	variable pending
	variable jobs
	variable seq
	if {![llength $cmds]} { {*}$finish {}; return }
	set id [incr seq]
	set pending($kind) $id
	set jobs($id) [dict create kind $kind n [llength $cmds] outs [lrepeat [llength $cmds] ""] ok 1 finish $finish]
	set i 0
	foreach c $cmds {
		spawn fetch $c [list panel::gathered $id $i]
		incr i
	}
}

proc panel::gathered {id i ok out} {
	variable jobs
	variable pending
	if {![info exists jobs($id)]} return
	set j $jobs($id)
	dict set j outs [lreplace [dict get $j outs] $i $i $out]
	if {!$ok} { dict set j ok 0 }
	dict incr j n -1
	if {[dict get $j n] > 0} { set jobs($id) $j; return }
	unset jobs($id)
	set kind [dict get $j kind]
	if {[info exists pending($kind)] && $pending($kind) == $id} { unset pending($kind) }
	if {[dict get $j ok]} { {*}[dict get $j finish] [dict get $j outs] }
	refresh $kind
}

# Redraws the open panel when KIND's data has changed (the tray shows all four).
proc panel::refresh {kind} {
	variable open
	if {$open eq $kind || ($open eq "tray" && $kind in {sound wifi bt power})} { draw }
}

# Reads KIND again; the panel redraws when the read is in.
proc panel::settle {kind} {
	fetch $kind
	draw
}

# An action (a click on a row): it runs, then the panel reads its data again.
proc panel::bg {kind args} {
	spawn act $args [list panel::bg_done $kind]
}

proc panel::bg_done {kind ok out} {
	variable open
	variable busy
	set busy ""
	if {$open eq $kind || $open eq "tray"} { fetch $open; draw }
	status::changed
}

# ---- reading the system ---------------------------------------------------

# Starts a read of KIND's data. A read already running is not started again.
proc panel::fetch {kind} {
	variable data
	variable pending
	if {$kind eq "tray"} { foreach k {sound wifi bt power} { fetch $k }; return }
	if {[info exists pending($kind)]} return
	switch $kind {
		sound {
			gather sound [list {pactl get-default-sink} {pactl list sinks} \
				{wpctl get-volume @DEFAULT_AUDIO_SINK@} {wpctl get-volume @DEFAULT_AUDIO_SOURCE@}] panel::got_sound
		}
		wifi { nm_load }
		bt { bz_load }
		storage {
			# measuring caches can take a moment: in the background
			unset -nocomplain data(clean)
			set ::panel::cbuf ""
			if {[catch {open |[list ribbon-reserve cleanup-list 2>/dev/null]} ch]} { set data(clean) {}; return }
			fconfigure $ch -blocking 0
			fileevent $ch readable [list panel::clean_read $ch]
		}
		power { gather power [list {powerprofilesctl get} {brightnessctl -m}] panel::got_power }
	}
}

proc panel::got_sound {outs} {
	variable data
	lassign $outs def list vol mic
	set data(sinks) {}
	set name ""
	set dn [string trim $def]
	foreach line [split $list \n] {
		if {[regexp {^\s*Name: (.*)$} $line -> name]} continue
		if {[regexp {^\s*Description: (.*)$} $line -> desc] && $name ne ""} {
			lappend data(sinks) [list $name $desc [expr {$name eq $dn}]]
			set name ""
		}
	}
	set data(vol) [volume_of $vol]
	set data(mic) [volume_of $mic]
}

# wpctl's "Volume: 0.40 [MUTED]" as {percent muted}
proc panel::volume_of {out} {
	if {![regexp {Volume:\s+([\d.]+)} $out -> v]} { return "" }
	list [expr {round($v * 100)}] [string match *MUTED* $out]
}

# ---- Wi-Fi and Bluetooth over the system bus ------------------------------------------

# The system bus: shell::bus connects it on the first call, so it is connected when a panel first needs it.
# Empty when there is no bus; the panels then show what they had.
proc panel::sysbus {} {
	if {[catch {shell::bus system} bus]} { return "" }
	return $bus
}

# Wi-Fi: Settings' NetworkManager client (apps/settings/nm.tcl, beside the shell's folder once installed) reads
# the model in a coroutine; its PropertiesChanged signals start the next read (nm::listen). Loaded on first use.
# Returns 1 when the client is ready on the shell's bus.
proc panel::nm_bind {} {
	variable here
	set bus [sysbus]
	if {$bus eq ""} { return 0 }
	if {[llength [info commands ::nm::refresh]] == 0} {
		foreach f [list [file join $here .. settings nm.tcl] [file join $here .. apps settings nm.tcl]] {
			# at global level: nm.tcl's namespace nm is ::nm (sourced from the panel namespace it would be ::panel::nm)
			if {[file exists $f]} { uplevel #0 [list ::source -encoding utf-8 $f]; break }
		}
		if {[llength [info commands ::nm::refresh]] == 0} { return 0 }
		set ::nm::onchange panel::nm_changed
	}
	# the client uses the shell's connection; a new one (after the bus was lost) is listened on again
	if {$bus ne $::nm::bus} { set ::nm::bus $bus; set ::nm::listening 0 }
	return 1
}

proc panel::nm_load {} {
	if {[nm_bind]} { ::nm::refresh }
}

# An action of the client (a proc and its arguments), run in a coroutine; the client reads again after it.
proc panel::nm_do {args} {
	if {[nm_bind]} { ::nm::job {*}$args }
}

# The client's model, as the panel's data. A failed read keeps the last data.
proc panel::nm_changed {} {
	variable data
	set m $::nm::model
	if {[dict get $m error] ne ""} { refresh wifi; return }
	set data(radio) [dict get $m wifi]
	# one entry per network: the strongest access point of its name, active if any of its access points is
	set best [dict create]
	foreach d [dict get $m devices] {
		if {[dict get $d type] != 2} continue
		foreach ap [dict get $d aps] {
			set ssid [dict get $ap ssid]
			if {$ssid eq ""} continue
			set e [dict create ssid $ssid on [dict get $ap active] signal [dict get $ap strength] \
				secure [expr {[dict get $ap wpa] || [dict get $ap rsn] || ([dict get $ap flags] & 1)}] \
				freq [dict get $ap freq] dev [dict get $d path] ap [dict get $ap path] \
				bytes [dict get $ap bytes] sae [expr {([dict get $ap rsn] & 0x400) ? 1 : 0}]]
			if {[dict exists $best $ssid]} {
				set old [dict get $best $ssid]
				set pick $old
				if {[dict get $e signal] > [dict get $old signal]} { set pick $e }
				dict set pick on [expr {[dict get $old on] || [dict get $e on]}]
				dict set best $ssid $pick
			} else {
				dict set best $ssid $e
			}
		}
	}
	set nets {}
	dict for {ssid e} $best {
		lappend nets [list $ssid [dict get $e on] [dict get $e signal] [dict get $e secure] [dict get $e freq]]
	}
	set data(nets) [lsort -decreasing -integer -index 1 [lsort -decreasing -integer -index 2 $nets]]
	set data(netinfo) $best
	set data(known) {}
	set data(profiles) {}
	foreach p [dict get $m saved] {
		if {[dict get $p type] ne "802-11-wireless"} continue
		lappend data(known) [dict get $p ssid]
		dict set data(profiles) [dict get $p ssid] [dict get $p path]
	}
	refresh wifi
}

# The Wi-Fi radio: a property change; NetworkManager's signal brings the new state back.
proc panel::set_radio {} {
	variable data
	nm_do ::nm::set_wifi [expr {$data(radio) ? 0 : 1}]
}

# Bluetooth: BlueZ's GetManagedObjects returns the adapter and every device in one call. BlueZ's PropertiesChanged
# and the object manager's InterfacesAdded and InterfacesRemoved start the next read.
proc panel::bz_load {} {
	variable bzbusy
	variable bzagain
	variable seq
	if {$bzbusy} { set bzagain 1; return }
	set bus [sysbus]
	if {$bus eq ""} return
	set bzbusy 1
	coroutine ::panel::bzread[incr seq] panel::bz_run $bus
}

proc panel::bz_run {bus} {
	variable bzbusy
	variable bzagain
	while {1} {
		set bzagain 0
		bz_listen $bus
		lassign [bz_read $bus] ok objs
		if {$ok} { bz_store $objs }
		if {!$bzagain} break
	}
	set bzbusy 0
}

# One read: {1 OBJECTS} (the objects as dicts: path -> interface -> property -> value) or {0 {}} when BlueZ did not answer.
proc panel::bz_read {bus} {
	if {[catch {$bus call org.bluez / org.freedesktop.DBus.ObjectManager GetManagedObjects} r]} { return [list 0 {}] }
	list 1 [ribbon::dbus::strip a{oa{sa{sv}}} [lindex $r 0]]
}

proc panel::bz_listen {bus} {
	variable bzlisten
	if {$bzlisten eq $bus} return
	set bzlisten $bus
	catch {
		$bus listen -sender org.bluez -path_namespace /org/bluez -interface org.freedesktop.DBus.Properties \
			-member PropertiesChanged panel::bz_changed
		$bus listen -sender org.bluez -interface org.freedesktop.DBus.ObjectManager -member InterfacesAdded panel::bz_changed
		$bus listen -sender org.bluez -interface org.freedesktop.DBus.ObjectManager -member InterfacesRemoved panel::bz_changed
	}
}

proc panel::bz_changed args { bz_load }

# A property of one interface of an object, or DEF.
proc panel::bz_prop {ifaces iface name {def ""}} {
	if {![dict exists $ifaces $iface $name]} { return $def }
	dict get $ifaces $iface $name
}

# The paired devices and the adapter's power, as the panel's data (a device that is not paired is not listed).
proc panel::bz_store {objs} {
	variable data
	variable bzpath
	variable bzadapter
	set adapter ""; set powered 0
	dict for {path ifaces} $objs {
		if {$adapter eq "" && [dict exists $ifaces org.bluez.Adapter1]} {
			set adapter $path
			set powered [bz_prop $ifaces org.bluez.Adapter1 Powered 0]
		}
	}
	set devs {}; set paths {}
	dict for {path ifaces} $objs {
		if {![dict exists $ifaces org.bluez.Device1] || ![bz_prop $ifaces org.bluez.Device1 Paired 0]} continue
		set mac [bz_prop $ifaces org.bluez.Device1 Address]
		set name [bz_prop $ifaces org.bluez.Device1 Alias]
		if {$name eq ""} { set name [bz_prop $ifaces org.bluez.Device1 Name] }
		if {$name eq ""} { set name $mac }
		lappend devs [list $mac $name [bz_prop $ifaces org.bluez.Device1 Connected 0] \
			[bz_prop $ifaces org.bluez.Device1 Icon] [bz_prop $ifaces org.bluez.Battery1 Percentage]]
		dict set paths $mac $path
	}
	set data(powered) $powered
	set data(devs) [lsort -decreasing -integer -index 2 $devs]
	set bzpath $paths
	set bzadapter $adapter
	refresh bt
	# the bar shows a device's battery (bar.tcl, bluetooth.conf's BAR_BATTERY)
	catch {status::changed}
}

# Bluetooth actions run in a coroutine; the read follows them (BlueZ's signal also starts one).
proc panel::bz_power {} {
	variable data
	set on [expr {$data(powered) ? 0 : 1}]
	coroutine ::panel::bzact[incr ::panel::seq] panel::bz_do_power $on
}

proc panel::bz_do_power {on} {
	variable bzadapter
	set bus [sysbus]
	if {$bus ne ""} {
		set a [expr {$bzadapter ne "" ? $bzadapter : "/org/bluez/hci0"}]
		catch {$bus call org.bluez $a org.freedesktop.DBus.Properties Set ssv org.bluez.Adapter1 Powered [list b $on]}
	}
	bz_load
}

proc panel::bz_device {mac on} {
	coroutine ::panel::bzact[incr ::panel::seq] panel::bz_do_device $mac $on
}

proc panel::bz_do_device {mac on} {
	variable bzpath
	set bus [sysbus]
	if {$bus ne "" && [dict exists $bzpath $mac]} {
		catch {$bus call org.bluez [dict get $bzpath $mac] org.bluez.Device1 [expr {$on ? "Connect" : "Disconnect"}]}
	}
	bz_load
}

proc panel::got_power {outs} {
	variable data
	lassign $outs profile b
	set data(profile) [string trim $profile]
	set data(bright) ""
	if {[regexp {^[^,]*,backlight,\d+,(\d+)%} $b -> pct]} { set data(bright) $pct }
}

# Battery from /sys: {percent status time-left-text}
proc panel::battery {} {
	foreach d [glob -nocomplain /sys/class/power_supply/BAT*] {
		set get {apply {{d k} { if {[catch {open $d/$k} fh]} { return "" }; set v [string trim [read $fh]]; ::close $fh; return $v }}}
		set cap [{*}$get $d capacity]
		set st [{*}$get $d status]
		set now [{*}$get $d energy_now]; set pw [{*}$get $d power_now]; set full [{*}$get $d energy_full]
		if {$now eq ""} { set now [{*}$get $d charge_now]; set pw [{*}$get $d current_now]; set full [{*}$get $d charge_full] }
		set left ""
		if {$pw ne "" && $pw > 0 && $now ne ""} {
			set h [expr {$st eq "Charging" && $full ne "" ? ($full - $now) / double($pw) : $now / double($pw)}]
			set left [format "%d h %d min" [expr {int($h)}] [expr {int(($h - int($h)) * 60)}]]
			set left [expr {$st eq "Charging" ? "$left to full" : "$left left"}]
		} elseif {$st eq "Full"} { set left "Fully charged" } elseif {$st eq "Charging"} { set left Charging }
		return [list $cap $st $left]
	}
	return {}
}

# ---- drawing ------------------------------------------------------------------

# A panel is a list of blocks, laid out top to bottom with 2 px gaps,
# exactly like the mockup's flex column.
proc panel::blocks {kind} {
	variable data
	variable ask
	set b {}
	switch $kind {
		tray {
			set cur [lsearch -inline -index 1 $data(nets) 1]
			set n 0
			foreach d $data(devs) { if {[lindex $d 2]} { incr n } }
			set sink [lsearch -inline -index 2 $data(sinks) 1]
			lassign [list {*}$data(vol) 0 0] v m
			set prof [dict get {power-saver Saver balanced Balanced performance Performance} [expr {$data(profile) in {power-saver balanced performance} ? $data(profile) : "balanced"}]]
			lappend b [list tiles [list \
				[list wifi Wi-Fi [expr {!$data(radio) ? "Off" : ($cur ne "" ? [lindex $cur 0] : "Not connected")}] $data(radio) {panel::set_radio} wifi] \
				[list bt Bluetooth [expr {!$data(powered) ? "Off" : ($n ? "$n connected" : "On")}] $data(powered) {panel::bz_power} bt] \
				[list [expr {$m ? "volume-x" : "volume"}] Sound [expr {$sink ne "" ? [lindex $sink 1] : "No output"}] [expr {!$m}] {panel::mute_tray} sound] \
				[list zap Power $prof [expr {$data(profile) ne "power-saver"}] {panel::next_profile} power]]]
			if {$data(vol) ne ""} { lappend b [list slider [expr {$m ? "volume-x" : "volume"}] $v [list panel::set_volume @DEFAULT_AUDIO_SINK@] [list panel::mute @DEFAULT_AUDIO_SINK@] 6] }
			if {$data(bright) ne ""} { lappend b [list slider sun $data(bright) panel::set_brightness "" 6] }
			set bat [battery]
			if {[llength $bat]} { lassign $bat cap st left; lappend b [list batrow $cap $left] }
			if {[status::storage_state] ne "ok"} {
				lappend b [list diskrow [status::storage_state] [dict get $status::storage user_free]]
			}
			lappend b [list footer "All settings" ribbon-settings]
		}
		sound {
			set sink [lsearch -inline -index 2 $data(sinks) 1]
			lassign [list {*}$data(vol) 0 0] v m
			lappend b [list header volume Sound [expr {$sink ne "" ? [lindex $sink 1] : "No output"}] {}]
			if {$data(vol) ne ""} {
				lappend b [list slider [expr {$m ? "volume-x" : "volume"}] $v [list panel::set_volume @DEFAULT_AUDIO_SINK@] [list panel::mute @DEFAULT_AUDIO_SINK@] 2]
			}
			lappend b [list label Output]
			foreach s $data(sinks) {
				lassign $s name desc on
				set ic [expr {[regexp -nocase {headphone|headset|bluez} "$name $desc"] ? "headphones" : ([regexp -nocase {hdmi|displayport|dp} "$name $desc"] ? "monitor" : "volume")}]
				lappend b [list row $ic $desc "" $on [list panel::bg sound pactl set-default-sink $name]]
			}
			if {$data(mic) ne ""} {
				lassign [list {*}$data(mic) 0 0] mv mm
				lappend b [list label Input] [list slider [expr {$mm ? "mic-off" : "mic"}] $mv [list panel::set_volume @DEFAULT_AUDIO_SOURCE@] [list panel::mute @DEFAULT_AUDIO_SOURCE@] 6]
			}
			lappend b [list footer "Sound settings" {ribbon-settings --page sound}]
		}
		wifi {
			set cur [lsearch -inline -index 1 $data(nets) 1]
			set sub [expr {!$data(radio) ? "Off" : ($cur ne "" ? "Connected to [lindex $cur 0]" : "Not connected")}]
			lappend b [list header wifi Wi-Fi $sub [list switch $data(radio) {panel::set_radio} ]]
			if {$data(radio)} {
				if {![llength $data(nets)]} { lappend b [list note "Looking for networks…"] }
				foreach n [lrange $data(nets) 0 7] {
					lassign $n ssid on signal secure freq
					set bars [expr {$signal > 66 ? 3 : ($signal > 33 ? 2 : 1)}]
					set band [expr {$freq ne "" && [string index $freq 0] >= 5 ? "5 GHz" : "2.4 GHz"}]
					lappend b [list net $ssid $on $bars $secure "Connected · $band" [list panel::join $ssid $secure]]
					if {$ask eq $ssid} { lappend b [list password $ssid] }
				}
			}
			lappend b [list footer "Network settings" {ribbon-settings --page network}]
		}
		bt {
			set n 0
			foreach d $data(devs) { if {[lindex $d 2]} { incr n } }
			set sub [expr {!$data(powered) ? "Off" : ($n ? "$n device[expr {$n == 1 ? "" : "s"}] connected" : "On")}]
			lappend b [list header bt Bluetooth $sub [list switch $data(powered) {panel::bz_power}]]
			if {$data(powered)} {
				foreach d $data(devs) {
					lassign $d mac name conn icon bat
					set ic [switch -glob -- $icon { audio-head* - audio-card* { list headphones } input-gaming { list game } input-mouse { list mouse } input-keyboard { list keyboard } phone { list phone } default { list bt } }]
					set state [expr {$conn ? "Connected[expr {$bat ne "" ? " · battery $bat%" : ""}]" : "Paired · not connected"}]
					lappend b [list device $ic $name $state $conn [list panel::bz_device $mac [expr {!$conn}]]]
				}
				lappend b [list action plus "Pair a new device" {apps::run {ribbon-settings --page bluetooth}}]
			}
			lappend b [list footer "Bluetooth settings" {ribbon-settings --page bluetooth}]
		}
		storage {
			set st $status::storage
			set uf [expr {[dict exists $st user_free] ? [dict get $st user_free] : 0}]
			lappend b [list header drive Storage "[status::human $uf] left for your files" {}]
			if {[dict exists $st spare] && [dict get $st spare] eq "released"} {
				lappend b [list note "The disk filled up; Ribbon used its spare room."]
			}
			lappend b [list label "Free up space"]
			variable busy
			if {$busy ne ""} {
				lappend b [list note $busy]
			} elseif {![info exists data(clean)]} {
				lappend b [list note "Measuring…"]
			} else {
				set total 0
				foreach it $data(clean) {
					lassign $it key label size
					set on [expr {[info exists data(sel,$key)] ? $data(sel,$key) : $key ne "snapshots"}]
					lappend b [list clean $key $label $size $on]
					if {$on && [string is digit -strict $size]} { incr total $size }
				}
				if {![llength $data(clean)]} {
					lappend b [list note "Nothing to clean up."]
				} else {
					lappend b [list action check "Clean up · [status::human $total]" panel::cleanup]
				}
			}
			lappend b [list footer "Show my files" ribbon-files]
		}
		power {
			set bat [battery]
			if {[llength $bat]} {
				lassign $bat cap st left
				lappend b [list header battery Battery $left [list big "$cap%"]] [list meter $cap]
			} else {
				lappend b [list header zap Power "Mains power" {}]
			}
			if {$data(profile) ne ""} {
				lappend b [list label "Power mode"] [list modes $data(profile)]
			}
			if {$data(bright) ne ""} {
				lappend b [list label Brightness] [list slider sun $data(bright) panel::set_brightness "" 6]
			}
			lappend b [list footer "Power settings" "ribbon-settings --page power"]
		}
		session {
			variable sel
			set k 0
			foreach r [session_rows] { lappend b [list srow $k {*}$r]; incr k }
		}
	}
	return $b
}

# The session panel's rows, in order: icon, label and the command that runs (through apps::run). Lock is the
# session's lock (rc.xml's W-l); Log out is labwc's Exit (labwc --exit, menu.xml).
proc panel::session_rows {} {
	return [list \
		[list lock Lock {ribbon-lock}] \
		[list moon Sleep {loginctl suspend}] \
		[list logout {Log out} {labwc --exit}] \
		[list rotate Restart {loginctl reboot}] \
		[list power {Shut down} {loginctl poweroff}]]
}

# Runs row K's command and closes the panel (the action closes it).
proc panel::session_run {k} {
	set r [lindex [session_rows] $k]
	if {$r eq ""} return
	close
	apps::run [lindex $r 2]
}

# The pointer over a row focuses it (the same row fill as the keys).
proc panel::session_hover {y} {
	variable sel
	set off [expr {$y - 8}]
	set k [expr {int(floor($off / 42.0))}]
	if {$k < 0 || $k >= [llength [session_rows]] || $off - $k * 42 >= 40} return
	if {$k != $sel} { set sel $k; draw }
}

# Up and Down move the focus, Enter runs it, Escape closes.
proc panel::session_key {sym char state} {
	variable sel
	switch -- $sym {
		Up { set sel [expr {max(0, $sel - 1)}] }
		Down { set sel [expr {min([llength [session_rows]] - 1, $sel + 1)}] }
		Return - KP_Enter { session_run $sel; return }
		Escape { close; return }
	}
	draw
}

proc panel::height {blk} {
	switch [lindex $blk 0] {
		tiles { return [expr {8 + 2 * 56 + 8 + 4}] }
		batrow - diskrow - clean { return 40 }
		header { return 50.25 }
		slider { return [expr {[lindex $blk end] + 16 + 10}] }
		label { return 25.31 }
		row - net { return 40 }
		srow { return 40 }
		password { return 40 }
		device { return 44 }
		action { return 42 }
		note { return 36 }
		meter { return 14 }
		modes { return 64 }
		footer { return 33.52 }
	}
}

# The panel's window: one shape with the right bar, see-through around its rounded bottom and its shadow
# (rbnalpha), made on first use.
proc panel::surface {} {
	if {[winfo exists .panel]} return
	rbn::surface .panel -fill $theme::c(BAR)
	bind .panel.c <ButtonPress-1> {panel::press %x %y}
	bind .panel.c <B1-Motion> {panel::motion %x}
	bind .panel.c <ButtonRelease-1> {set panel::drag ""}
	bind .panel.c <Motion> {if {$panel::open eq "updates"} { upd::hover_at %x %y } elseif {$panel::open eq "session"} { panel::session_hover %y }}
}

proc panel::draw {} {
	variable open
	variable sel
	variable hits
	variable sliders
	if {$open eq ""} return
	if {$open eq "updates"} { upd::draw; return }
	# an app's tray menu (tray.tcl, board Tray-2-Menu)
	if {$open eq "sni"} { tray::menu_draw; return }
	array set c [array get theme::c]
	set W [expr {max(320, $bar::rightw)}]
	set X [expr {$bar::rightx + $bar::rightw - $W}]
	set blocks [blocks $open]
	set H 8
	foreach blk $blocks { set H [expr {$H + [height $blk] + 2}] }
	set H [expr {round($H - 2 + 8)}]
	surface
	set d .panel.c
	$d delete all
	$d configure -background $c(BAR)
	set hits {}; set sliders {}
	set later {}
	set y 8.0
	foreach blk $blocks {
		set h [height $blk]
		set y0 [expr {round($y)}]
		set args [lassign $blk kind]
		switch $kind {
			tiles {
				set tw [expr {($W - 32 - 8) / 2.0}]
				set i 0
				foreach t [lindex $args 0] {
					lassign $t icon title sub on toggle detail
					set tx [expr {round(16 + ($i % 2) * ($tw + 8))}]; set ty [expr {$y0 + 8 + ($i / 2) * 64}]
					rbn::box $d $tx $ty [expr {round($tw)}] 56 -fill $c(FIELD) -radius 10 -on $c(BAR)
					rbn::box $d [expr {$tx + 10}] [expr {$ty + 13}] 30 30 -fill [expr {$on ? $c(ACCENT) : $c(BAR)}] -radius 8 -on $c(FIELD)
					lappend later [list icon $icon 16 1.9 [expr {$on ? $c(ON_ACCENT) : $c(MUTED)}] [expr {$tx + 17}] [expr {$ty + 20}]]
					lappend later [list text [expr {$tx + 50}] [expr {$ty + 20}] $title f13s $c(FG) w]
					lappend later [list text [expr {$tx + 50}] [expr {$ty + 37}] [bar::clip f12 $sub [expr {$tw - 50 - 26}]] f12 $c(MUTED) w]
					lappend later [list icon right 13 2 $c(MUTED) [expr {$tx + $tw - 10 - 13}] [expr {$ty + 21.5}]]
					set tg [expr {$detail eq "wifi" || $detail eq "bt" ? [list {*}$toggle [expr {$on ? "off" : "on"}]] : $toggle}]
					lappend hits [list [expr {$tx + 6}] [expr {$ty + 9}] [expr {$tx + 44}] [expr {$ty + 47}] $tg]
					lappend hits [list [expr {$tx + 44}] $ty [expr {$tx + $tw}] [expr {$ty + 56}] [list panel::show $detail]]
					incr i
				}
			}
			batrow {
				lassign $args cap left
				set ex [list 4 10 [expr {max(0.5, 12.2 * $cap / 100.0)}] 4 0.5]
				lappend later [list icon battery 17 1.7 $c(MUTED) 22.5 [expr {$y0 + 6}] $ex]
				lappend later [list text 58 [expr {$y0 + 14}] "Battery $cap%" f13s $c(FG) w]
				lappend later [list text [expr {$W - 18}] [expr {$y0 + 14}] $left f12 $c(MUTED) e]
				rbn::box $d 58 [expr {$y0 + 26}] [expr {$W - 58 - 18}] 4 -fill $c(FIELD) -radius 2 -on $c(BAR)
				rbn::box $d 58 [expr {$y0 + 26}] [expr {max(4, round(($W - 76) * $cap / 100.0))}] 4 -fill $c(ACCENT) -radius 2 -on ""
				lappend hits [list 8 $y0 [expr {$W - 8}] [expr {$y0 + 40}] {panel::show power}]
			}
			diskrow {
				lassign $args state free
				lappend later [list icon drive 16 1.9 $c(ACCENT) 23 [expr {$y0 + 12}]]
				lappend later [list text 58 [expr {$y0 + 20}] [expr {$state eq "critical" ? "Disk almost full" : "Low on space"}] f13s $c(FG) w]
				lappend later [list text [expr {$W - 18 - 13 - 8}] [expr {$y0 + 20}] "[status::human $free] left" f12 $c(MUTED) e]
				lappend later [list icon right 13 2 $c(MUTED) [expr {$W - 18 - 13}] [expr {$y0 + 13.5}]]
				lappend hits [list 8 $y0 [expr {$W - 8}] [expr {$y0 + 40}] {panel::show storage}]
			}
			clean {
				lassign $args key label size on
				rbn::box $d 22 [expr {$y0 + 11}] 18 18 -fill [expr {$on ? $c(ACCENT) : $c(FIELD)}] -radius 5 \
					-ring [list [expr {$on ? $c(ACCENT) : $c(BORDER)}] 1] -on $c(BAR)
				if {$on} { lappend later [list icon check 12 2.4 $c(ON_ACCENT) 25 [expr {$y0 + 14}]] }
				lappend later [list text 58 [expr {$y0 + 20}] $label f13 $c(FG) w]
				set sz [expr {[string is digit -strict $size] ? [status::human $size] : $size}]
				lappend later [list text [expr {$W - 18}] [expr {$y0 + 20}] $sz f12 $c(MUTED) e]
				lappend hits [list 8 $y0 [expr {$W - 8}] [expr {$y0 + 40}] [list panel::clean_toggle $key $on]]
			}
			header {
				lassign $args icon title sub extra
				# opened from the tray: the tile is a way back
				rbn::box $d 16 [expr {$y0 + 9}] 30 30 -fill $c(PILL) -radius 8 -on $c(BAR)
				set icon left
				lappend hits [list 16 [expr {$y0 + 9}] 46 [expr {$y0 + 39}] {panel::show tray}]
				set ex [expr {$icon eq "battery" ? [list 4 10 [expr {max(0.5, 12.2 * $status::battery / 100.0)}] 4 0.5] : {}}]
				lappend later [list icon $icon 16 1.9 $c(ACCENT) 23 [expr {$y0 + 16}] $ex]
				lappend later [list text 58 [expr {round($y + 8 + 7.87)}] $title f13s $c(FG) w]
				lappend later [list text 58 [expr {round($y + 8 + 15.73 + 2 + 7.26)}] $sub f12 $c(MUTED) w]
				switch [lindex $extra 0] {
					switch {
						lassign $extra - on cmd
						set sx [expr {$W - 16 - 36}]; set sy [expr {$y0 + 14}]
						rbn::box $d $sx $sy 36 20 -fill [expr {$on ? $c(ACCENT) : $c(FIELD)}] -radius 10 -on $c(BAR)
						rbn::box $d [expr {$on ? $sx + 18 : $sx + 2}] [expr {$sy + 2}] 16 16 -fill [expr {$on ? $c(ON_ACCENT) : $c(MUTED)}] -radius 8 -on ""
						lappend hits [list $sx $sy [expr {$sx + 36}] [expr {$sy + 20}] [list {*}$cmd [expr {$on ? "off" : "on"}]]]
					}
					big { lappend later [list text [expr {$W - 16}] [expr {$y0 + 25}] [lindex $extra 1] fbig $c(FG) e] }
				}
			}
			slider {
				lassign $args icon v setter toggler top
				set cy [expr {$y0 + $top + 8}]
				lappend later [list icon $icon 16 1.9 $c(MUTED) 23 [expr {$cy - 8}]]
				if {$toggler ne ""} { lappend hits [list 16 [expr {$cy - 12}] 46 [expr {$cy + 12}] $toggler] }
				set tx0 58; set tx1 [expr {$W - 18 - 34 - 12}]
				rbn::box $d $tx0 [expr {$cy - 2}] [expr {$tx1 - $tx0}] 4 -fill $c(FIELD) -radius 2 -on $c(BAR)
				set kx [expr {$tx0 + ($tx1 - $tx0) * min(100, $v) / 100.0}]
				if {$kx - $tx0 >= 4} { rbn::box $d $tx0 [expr {$cy - 2}] [expr {round($kx - $tx0)}] 4 -fill $c(ACCENT) -radius 2 -on "" }
				rbn::box $d [expr {round($kx - 7)}] [expr {$cy - 7}] 14 14 -fill $c(FG) -radius 7 -on ""
				lappend later [list text [expr {$W - 18}] $cy "$v%" f12 $c(MUTED) e tab]
				lappend sliders [list $tx0 $tx1 [expr {$cy - 12}] [expr {$cy + 12}] $setter]
			}
			label {
				lappend later [list spaced 18 [expr {round($y + 8 + 6.66)}] [string toupper [lindex $args 0]]]
			}
			row {
				lassign $args icon name detail on cmd
				if {$on} { rbn::box $d 8 $y0 [expr {$W - 16}] 40 -fill $c(FIELD) -radius 8 -on $c(BAR) }
				lappend later [list icon $icon 16 1.8 [expr {$on ? $c(ACCENT) : $c(MUTED)}] 23 [expr {$y0 + 12}]]
				lappend later [list text 58 [expr {$y0 + 20}] [bar::clip f13 $name [expr {$W - 100}]] [expr {$on ? "f13s" : "f13"}] $c(FG) w]
				if {$on} { lappend later [list icon check 15 2.2 $c(ACCENT) [expr {$W - 18 - 15}] [expr {$y0 + 12.5}]] }
				lappend hits [list 8 $y0 [expr {$W - 8}] [expr {$y0 + 40}] $cmd]
			}
			srow {
				# a row of the session panel: the focused one has the §field fill, §fg icon and weight 600
				lassign $args k icon label cmd
				set on [expr {$k == $sel}]
				if {$on} { rbn::box $d 8 $y0 [expr {$W - 16}] 40 -fill $c(FIELD) -radius 8 -on $c(BAR) }
				lappend later [list icon $icon 16 1.9 [expr {$on ? $c(FG) : $c(MUTED)}] 20 [expr {$y0 + 12}]]
				lappend later [list text 48 [expr {$y0 + 20}] $label [expr {$on ? "f13s" : "f13m"}] $c(FG) w]
				lappend hits [list 8 $y0 [expr {$W - 8}] [expr {$y0 + 40}] [list panel::session_run $k]]
			}
			net {
				lassign $args ssid on bars secure sub cmd
				if {$on} { rbn::box $d 8 $y0 [expr {$W - 16}] 40 -fill $c(FIELD) -radius 8 -on $c(BAR) }
				set col [expr {$on ? $c(ACCENT) : $c(FG)}]
				lappend later [list signal $bars $col $c(BORDER) 23 [expr {$y0 + 12}]]
				if {$on} {
					lappend later [list text 58 [expr {$y0 + 13}] $ssid f13s $c(FG) w] [list text 58 [expr {$y0 + 28}] $sub f11 $c(MUTED) w]
				} else { lappend later [list text 58 [expr {$y0 + 20}] [bar::clip f13 $ssid [expr {$W - 120}]] f13 $c(FG) w] }
				set lockx [expr {$W - 18 - 13}]
				if {$secure} { lappend later [list icon lock 13 2 $c(MUTED) $lockx [expr {$y0 + 13.5}]] }
				if {$on} { lappend later [list icon check 15 2.2 $c(ACCENT) [expr {$lockx - 10 - 15}] [expr {$y0 + 12.5}]] }
				lappend hits [list 8 $y0 [expr {$W - 8}] [expr {$y0 + 40}] $cmd]
			}
			password {
				set fx 58; set bw [expr {round(24 + [text::width f12s Join])}]
				set fw [expr {$W - 18 - $bw - 8 - $fx}]
				rbn::box $d $fx [expr {$y0 + 2}] $fw 30 -fill $c(FIELD) -radius 8 -ring [list $c(ACCENT) 1.5] -on $c(BAR)
				rbn::box $d [expr {$W - 18 - $bw}] [expr {$y0 + 2}] $bw 30 -fill $c(ACCENT) -radius 8 -on $c(BAR)
				lappend later [list password [expr {$fx + 10}] [expr {$y0 + 17}]]
				lappend later [list text [expr {$W - 18 - $bw / 2.0}] [expr {$y0 + 17}] Join f12s $c(ON_ACCENT) center]
				lappend hits [list [expr {$W - 18 - $bw}] [expr {$y0 + 2}] [expr {$W - 18}] [expr {$y0 + 32}] [list panel::connect]]
			}
			device {
				lassign $args icon name state conn cmd
				rbn::box $d 17 [expr {$y0 + 8}] 28 28 -fill [expr {$conn ? $c(PILL) : $c(FIELD)}] -radius 8 -on $c(BAR)
				lappend later [list icon $icon 15 1.9 [expr {$conn ? $c(ACCENT) : $c(MUTED)}] 23.5 [expr {$y0 + 14.5}]]
				lappend later [list text 58 [expr {$y0 + 15}] [bar::clip f13m $name [expr {$W - 80}]] f13m $c(FG) w]
				lappend later [list text 58 [expr {$y0 + 30}] $state f11 [expr {$conn ? $c(ACCENT) : $c(MUTED)}] w]
				lappend hits [list 8 $y0 [expr {$W - 8}] [expr {$y0 + 44}] $cmd]
			}
			action {
				lassign $args icon label cmd
				lappend later [list icon $icon 16 2 $c(ACCENT) 23 [expr {$y0 + 13}]] [list text 58 [expr {$y0 + 21}] $label f13s $c(ACCENT) w]
				lappend hits [list 8 $y0 [expr {$W - 8}] [expr {$y0 + 42}] $cmd]
			}
			note { lappend later [list text 18 [expr {$y0 + 18}] [lindex $args 0] f12 $c(MUTED) w] }
			meter {
				set cap [lindex $args 0]
				rbn::box $d 18 $y0 [expr {$W - 36}] 6 -fill $c(FIELD) -radius 3 -on $c(BAR)
				rbn::box $d 18 $y0 [expr {max(6, round(($W - 36) * $cap / 100.0))}] 6 -fill $c(ACCENT) -radius 3 -on ""
			}
			modes {
				set cur [lindex $args 0]
				set gx 18; set gw [expr {$W - 36}]
				rbn::box $d $gx [expr {$y0 + 2}] $gw 58 -fill $c(FIELD) -radius 9 -on $c(BAR)
				set cw [expr {($gw - 6 - 4) / 3.0}]
				set i 0
				foreach {key label icon} {power-saver Saver leaf balanced Balanced scale performance Performance zap} {
					set bx [expr {round($gx + 3 + $i * ($cw + 2))}]
					set on [expr {$cur eq $key}]
					if {$on} { rbn::box $d $bx [expr {$y0 + 5}] [expr {round($cw)}] 52 -fill $c(ACCENT) -radius 7 -on $c(FIELD) }
					set col [expr {$on ? $c(ON_ACCENT) : $c(MUTED)}]
					lappend later [list icon $icon 16 1.9 $col [expr {$bx + $cw / 2.0 - 8}] [expr {$y0 + 13}]]
					lappend later [list text [expr {$bx + $cw / 2.0}] [expr {$y0 + 43}] $label f11s $col center]
					lappend hits [list $bx [expr {$y0 + 5}] [expr {$bx + $cw}] [expr {$y0 + 57}] [list panel::bg power powerprofilesctl set $key]]
					incr i
				}
			}
			footer {
				lassign $args label cmd
				set ly [expr {round($y + 4)}]
				$d create rectangle 8 $ly [expr {$W - 8}] [expr {$ly + 1}] -fill $c(BORDER) -width 0
				lappend later [list text 18 [expr {round($y + 4 + 1 + 10 + 7.26)}] $label f12 $c(MUTED) w]
				lappend later [list icon right 13 2 $c(MUTED) [expr {$W - 18 - 13}] [expr {$y + 4 + 1 + 10 + 0.76}]]
				lappend hits [list 8 $ly [expr {$W - 8}] [expr {$y0 + $h}] [list apps::run $cmd]]
			}
		}
		set y [expr {$y + $h + 2}]
	}
	foreach l $later {
		set args [lassign $l kind]
		switch $kind {
			icon { lassign $args name sz st col x y ex; bar::icon $d $name $sz $st $col $x $y $ex }
			text {
				lassign $args x y t f col anchor tab
				if {$tab ne ""} { set x [expr {$x - [bar::tabwidth $f $t]}]; bar::tabtext $d $x $y $f $col $t } else {
					text::draw $d $x $y $f $col $t $anchor
				}
			}
			spaced { lassign $args x y t; bar::spaced $d $x $y f11s $c(MUTED) $t 0.88 }
			signal {
				lassign $args bars col off x y
				foreach {k path} {0 {M12 20h.01} 1 {M8.53 16.11a6 6 0 0 1 6.95 0} 2 {M5 12.55a11 11 0 0 1 14 0} 3 {M1.42 9a16 16 0 0 1 21.16 0}} {
					set img2 [raster::icon $path 16 1.9 [expr {$k <= $bars ? $col : $off}]]
					$d create image $x $y -image $img2 -anchor nw
				}
			}
			password {
				variable password
				lassign $args x y
				set dots [string repeat • [string length $password]]
				text::draw $d $x $y f13 $c(FG) $dots w
				set cx [expr {$x + [text::width f13 $dots] + 1}]
				$d create rectangle $cx [expr {$y - 7}] [expr {$cx + 2}] [expr {$y + 8}] -fill $c(ACCENT) -width 0
			}
		}
	}
	rbn::popup .panel [expr {int($X)}] [expr {$bar::Y0 + 54}] $W $H [theme::look pop -radius {0 0 12 12} -ring [list $c(BORDER) 1 lrb]] -clip t
}

# The main display moved (display.tcl): an open panel goes with the right bar. It is taken off the screen and drawn
# again once the bars have their new place (Tk puts a mapped override-redirect window back where it was when it is
# raised before the move is made).
proc panel::moved {} {
	if {$panel::open eq ""} return
	rbn::hide .panel
	after idle { if {$panel::open ne ""} { panel::draw } }
}
display::on_change panel::moved

# ---- interaction --------------------------------------------------------------

proc panel::press {x y} {
	variable hits
	variable sliders
	variable drag
	foreach s $sliders {
		lassign $s x0 x1 y0 y1 setter
		if {$y >= $y0 && $y <= $y1 && $x >= $x0 - 8 && $x <= $x1 + 8} { set drag $s; motion $x; return }
	}
	foreach h $hits {
		lassign $h x0 y0 x1 y1 cmd
		if {$x >= $x0 && $x < $x1 && $y >= $y0 && $y < $y1} { uplevel #0 $cmd; return }
	}
}

proc panel::motion {x} {
	variable drag
	if {$drag eq ""} return
	lassign $drag x0 x1 - - setter
	set v [expr {max(0, min(100, round(100.0 * ($x - $x0) / ($x1 - $x0))))}]
	{*}$setter $v
}

# Sliders apply at most every 50 ms while dragging.
proc panel::set_volume {target v} {
	variable data
	set key [expr {$target eq "@DEFAULT_AUDIO_SINK@" ? "vol" : "mic"}]
	set data($key) [list $v [lindex $data($key) 1]]
	after cancel [list panel::apply_volume $target]
	after 50 [list panel::apply_volume $target]
	draw
}

proc panel::apply_volume {target} {
	variable data
	set key [expr {$target eq "@DEFAULT_AUDIO_SINK@" ? "vol" : "mic"}]
	fire [list wpctl set-volume $target [lindex $data($key) 0]%]
	if {$key eq "vol"} { status::volume_read }
}

proc panel::mute_tray {} { fire {wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle} {panel::settle tray}; status::volume_read }

proc panel::next_profile {} {
	variable data
	set order {power-saver balanced performance}
	set i [lsearch $order $data(profile)]
	bg tray powerprofilesctl set [lindex $order [expr {($i + 1) % 3}]]
}

proc panel::mute {target} {
	fire [list wpctl set-mute $target toggle] {panel::settle sound}
	status::volume_read
}

proc panel::set_brightness {v} {
	variable data
	set data(bright) [expr {max(1, $v)}]
	after cancel panel::apply_brightness
	after 50 panel::apply_brightness
	draw
}

proc panel::apply_brightness {} { variable data; fire [list brightnessctl -q set $data(bright)%] }

# Wi-Fi: known or open networks connect straight away; others ask for the
# password inline (typed through the shell's input window).
proc panel::join {ssid secure} {
	variable data
	variable ask
	variable password
	if {[lsearch -index 1 $data(nets) 1] >= 0 && [lindex [lsearch -inline -index 1 $data(nets) 1] 0] eq $ssid} return
	if {![dict exists $data(netinfo) $ssid]} return
	set e [dict get $data(netinfo) $ssid]
	if {[dict exists $data(profiles) $ssid]} { nm_do ::nm::activate [dict get $data(profiles) $ssid] [dict get $e dev]; return }
	if {!$secure} { nm_do ::nm::connect_ap [dict get $e dev] [dict get $e ap] [dict get $e bytes]; return }
	set ask $ssid; set password ""
	set launcher::keytarget panel::key
	launcher::input_show
	draw
}

proc panel::key {sym char state} {
	variable ask
	variable password
	switch -- $sym {
		Escape { set ask ""; launcher::input_hide; set launcher::keytarget "" }
		Return - KP_Enter { connect; return }
		BackSpace { set password [string range $password 0 end-1] }
		default { if {$char ne "" && [string is print $char]} { append password $char } }
	}
	draw
}

proc panel::connect {} {
	variable ask
	variable password
	variable data
	if {$ask eq "" || $password eq ""} return
	if {[dict exists $data(netinfo) $ask]} {
		set e [dict get $data(netinfo) $ask]
		nm_do ::nm::connect_secured [dict get $e dev] [dict get $e ap] [dict get $e bytes] $password [dict get $e sae]
	}
	set ask ""; set password ""
	launcher::input_hide
	set launcher::keytarget ""
	draw
}

# ---- storage ------------------------------------------------------------------

proc panel::clean_read {ch} {
	variable data
	variable open
	append ::panel::cbuf [read $ch]
	if {![eof $ch]} return
	catch {::close $ch}
	set sizes {}
	foreach l [split $::panel::cbuf \n] { if {[llength $l] == 2} { dict set sizes {*}$l } }
	set st $status::storage
	set data(clean) {}
	foreach {key label from} {trash Trash user cache "App caches" user pkgcache "Downloaded updates" sys snapshots "Old snapshots" sys} {
		set v [expr {$from eq "user" ? ([dict exists $sizes $key] ? [dict get $sizes $key] : 0) : ([dict exists $st $key] ? [dict get $st $key] : 0)}]
		if {$v eq "" || $v == 0} continue
		if {$key eq "snapshots"} { set v "$v snapshot[expr {$v == 1 ? "" : "s"}]" }
		lappend data(clean) [list $key $label $v]
	}
	if {$open eq "storage"} draw
}

proc panel::clean_toggle {key on} {
	variable data
	set data(sel,$key) [expr {!$on}]
	draw
}

# Your part runs as you; the system's part (update downloads, snapshots)
# asks for your password through polkit.
proc panel::cleanup {} {
	variable data
	variable busy
	set mine {}; set sys {}
	foreach it $data(clean) {
		set key [lindex $it 0]
		set on [expr {[info exists data(sel,$key)] ? $data(sel,$key) : $key ne "snapshots"}]
		if {!$on} continue
		if {$key in {trash cache}} { lappend mine $key } else { lappend sys $key }
	}
	if {![llength $mine] && ![llength $sys]} return
	set busy "Cleaning up…"
	draw
	set cmd {}
	if {[llength $mine]} { lappend cmd [list ribbon-reserve cleanup {*}$mine] }
	if {[llength $sys]} { lappend cmd [list pkexec /usr/bin/ribbon-reserve cleanup {*}$sys] }
	set script [join [lmap c $cmd { join $c }] "; "]
	if {[catch {open |[list sh -c $script 2>@1]} ch]} { set busy ""; draw; return }
	fconfigure $ch -blocking 0
	fileevent $ch readable [list panel::cleanup_done $ch]
}

proc panel::cleanup_done {ch} {
	variable busy
	variable open
	read $ch
	if {![eof $ch]} return
	catch {::close $ch}
	set busy ""
	# the service refreshes its numbers every 30 s; read them again soon
	after cancel status::storage_tick
	after 2000 status::storage_tick
	if {$open eq "storage"} { fetch storage; draw }
}

# The power key (XF86PowerOff, labwc's rc.xml runs ribbon-shell-ctl power-menu): with POWER_KEY_ASK=yes in power.conf
# the shell shows its power menu, the session panel (Lock, Sleep, Log out, Restart, Shut down). With no (the default)
# nothing shows, and logind acts on the key.
proc panel::power_key {} {
	if {[bar::power_conf POWER_KEY_ASK no] ne "yes"} return
	if {$panel::open eq "session"} return
	launcher::cancel
	show session
}
# after idle: shell::verb is defined by main.tcl after this file is sourced; the event loop starts after that
after idle {shell::verb power-menu panel::power_key}
