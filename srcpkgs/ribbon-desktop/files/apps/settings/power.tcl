# power.tcl - Settings → Power's model, client and idle timers (U14, board Settings-A-Rail; HANDOFF "Settings → Power").
# The battery over UPower and the power mode over power-profiles-daemon, both on the system bus through ribbon::dbus.
# Every bus call is asynchronous: a read or an action is a coroutine that yields while the bus answers, so Tk keeps drawing.
# No upower, powerprofilesctl or nmcli is forked.
#
#   power::refresh               re-read the model (a refresh asked for during a read runs once more after it)
#   power::job CMD ARGS...       run CMD (a proc) in a coroutine, then refresh; its error is power::error
#   power::set_profile NAME      ActiveProfile: power-saver, balanced or performance (no privilege: PPD's own default)
#   power::setting KEY           a value of ~/.config/ribbon/power.conf, or its default (power::defaults)
#   power::conf_set KEY VALUE    write one value; the other lines of the file are kept
#   power::idle_args BAT DIM     the swayidle arguments for one state: BAT 1 on battery, 0 plugged in; DIM yes|no
#   power::idle_run              read OnBattery and start swayidle when the arguments changed (the daemon's own pass is pidle::run in power-idle.tcl)
#   power::root                  the root settings as the files say them (/etc, /sys; RIBBON_POWER_ROOT moves the root)
#
#   power::root_set ID VALUE     change a root setting (the lid, the power key, the critical action and level, the charge limit)
#                                through `pkexec ribbon-power-helper set NAME VALUE`; a refusal or a cancel leaves the setting as
#                                it was and puts one line in power::error. power::root_menu ID gives a row's items and value.
#   power::lid_step CLOSED BAT   "Turn off the screen" for the lid: blank with wlopm while the lid is closed, light it on opening
#
# The model is a dict: bat (a battery is present) pct state tte ttf (seconds to empty / to full) health (capacity, %)
# cycles onbattery profile profiles error. A missing value is 0, -1 for health and cycles, "" for the profile.

foreach d [list /usr/lib/ribbon [file dirname [file dirname [file dirname [file normalize [info script]]]]]] {
	if {$d ni $::auto_path} { lappend ::auto_path $d }
}
package require ribbon::dbus

namespace eval power {
	variable upower org.freedesktop.UPower
	variable upath /org/freedesktop/UPower
	variable ppd net.hadess.PowerProfiles
	variable ppath /net/hadess/PowerProfiles
	variable bus ""
	variable model {bat 0 pct 0 state 0 tte 0 ttf 0 health -1 cycles -1 onbattery 0 profile "" profiles {} error ""}
	variable error ""      ;# the last action's error (the subtitle shows it)
	variable loaded 0      ;# the first read has ended
	variable started 0     ;# the page asked for the first read
	variable busy 0
	variable again 0
	variable seq 0
	variable onchange ""   ;# a command run after each model change (the page draws)
	variable defaults {IDLE_BAT_OFF 5 IDLE_PL_OFF 15 IDLE_BAT_LOCK 5 IDLE_PL_LOCK 15 IDLE_BAT_SUSPEND 15 IDLE_PL_SUSPEND 0 DIM yes BAR_PERCENT yes
		LID_BAT_SCREEN no LID_PL_SCREEN no POWER_KEY_ASK no}
	variable idle_last ""  ;# the swayidle arguments in effect (so a restart happens only on a change)
	variable lid_blank 0   ;# the lid blanked the screen (so opening it lights it, and nothing else does)
	variable rbusy 0       ;# a helper is running
	variable names {org.freedesktop.UPower UPower net.hadess.PowerProfiles power-profiles-daemon}
}

# ---- the bus ----------------------------------------------------------------------

proc power::ensure_bus {} {
	variable bus
	if {$bus ne "" && [llength [info commands $bus]]} { return }
	set bus [ribbon::dbus::connect system]
}

# The properties of one interface of DEST at PATH, as a dict of plain values.
proc power::props {dest path iface} {
	variable bus
	set v [lindex [$bus call $dest $path org.freedesktop.DBus.Properties GetAll s $iface] 0]
	ribbon::dbus::strip a{sv} $v
}

proc power::get {d key {def ""}} {
	expr {[dict exists $d $key] ? [dict get $d $key] : $def}
}

# The text for a failure: a bus with no such service says the service is not running; anything else is the error's text.
proc power::explain {msg dest} {
	variable names
	if {[lindex $::errorCode 0] eq "DBUS"} {
		set name [lindex $::errorCode 1]
		if {$name in {org.freedesktop.DBus.Error.ServiceUnknown org.freedesktop.DBus.Error.NameHasNoOwner
			org.freedesktop.DBus.Error.NoServer org.freedesktop.DBus.Error.Disconnected}} {
			return "[dict get [dict create {*}$names] $dest] is not running"
		}
	}
	return $msg
}

# ---- reading ----------------------------------------------------------------------

# The battery and the AC state from UPower (the display device, which is the battery when there is one).
proc power::read_upower {} {
	variable bus; variable upower; variable upath
	set top [power::props $upower $upath org.freedesktop.UPower]
	set dev [lindex [$bus call $upower $upath org.freedesktop.UPower GetDisplayDevice] 0]
	set d [power::props $upower $dev org.freedesktop.UPower.Device]
	set out [dict create onbattery [expr {[power::get $top OnBattery 0] ? 1 : 0}] bat 0 pct 0 state 0 tte 0 ttf 0 health -1 cycles -1]
	if {[power::get $d IsPresent 0] && [power::get $d Type 0] == 2} {
		dict set out bat 1
		dict set out pct [power::get $d Percentage 0]
		dict set out state [power::get $d State 0]
		dict set out tte [power::get $d TimeToEmpty 0]
		dict set out ttf [power::get $d TimeToFull 0]
		dict set out health [power::get $d Capacity -1]
		dict set out cycles [power::get $d ChargeCycles -1]
	}
	set out
}

# The power mode and the modes the daemon offers.
proc power::read_ppd {} {
	variable bus; variable ppd; variable ppath
	set p [power::props $ppd $ppath $ppd]
	set names {}
	foreach e [power::get $p Profiles {}] { lappend names [power::get $e Profile] }
	dict create profile [power::get $p ActiveProfile] profiles $names
}

# Read the model. Each service that fails leaves its own text in error; the other still reads.
proc power::fetch {} {
	set m [dict create bat 0 pct 0 state 0 tte 0 ttf 0 health -1 cycles -1 onbattery 0 profile "" profiles {} error ""]
	set errs {}
	variable upower; variable ppd
	if {[catch {power::ensure_bus; set m [dict merge $m [power::read_upower]]} msg]} {
		lappend errs [power::explain $msg $upower]
	}
	if {[catch {power::ensure_bus; set m [dict merge $m [power::read_ppd]]} msg]} {
		lappend errs [power::explain $msg $ppd]
	}
	dict set m error [join $errs "; "]
	set m
}

# Ask for a read; it returns at once and the model (then the page) is updated when the read ends.
proc power::refresh {} {
	variable busy; variable again
	if {$busy} { set again 1; return }
	set busy 1
	coroutine ::power::fetch[incr ::power::seq] power::run_read
}

proc power::run_read {} {
	variable busy; variable again; variable model; variable onchange; variable loaded
	while {1} {
		set again 0
		set model [power::fetch]
		set loaded 1
		if {!$again} break
	}
	set busy 0
	if {$onchange ne ""} { {*}$onchange }
}

# Run an action (a proc and its arguments) in a coroutine, then refresh. Its error goes to power::error.
proc power::job {args} {
	coroutine ::power::job[incr ::power::seq] power::run_job {*}$args
}

proc power::run_job {args} {
	variable error; variable ppd
	set error ""
	if {[catch {power::ensure_bus; {*}$args} msg]} { set error [power::explain $msg $ppd] }
	power::refresh
}

# ---- actions ----------------------------------------------------------------------

proc power::set_profile {name} {
	power::job power::do_set_profile $name
}

proc power::do_set_profile {name} {
	variable bus; variable ppd; variable ppath
	$bus call $ppd $ppath org.freedesktop.DBus.Properties Set ssv $ppd ActiveProfile [list s $name]
}

# ---- the settings file: ~/.config/ribbon/power.conf (KEY=VALUE lines; minutes, 0 = never) --------------

proc power::conf_file {} {
	set cfg [expr {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""
		? $::env(XDG_CONFIG_HOME) : [file join [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}] .config]}]
	file join $cfg ribbon power.conf
}

proc power::conf_lines {} {
	set f [power::conf_file]
	if {[catch {open $f} fh]} { return {} }
	set t [read $fh]
	close $fh
	if {$t eq ""} { return {} }
	split [string trimright $t \n] \n
}

# A setting: the file's last line for KEY, or its default when the file has none or a bad value.
proc power::setting {key} {
	variable defaults
	set v [dict get $defaults $key]
	foreach line [power::conf_lines] {
		if {[regexp "^${key}=(.*)\$" $line -> x]} { set v [string trim $x] }
	}
	if {[string match IDLE_* $key]} {
		if {[string is integer -strict $v] && $v >= 0} { return $v }
		return [dict get $defaults $key]
	}
	if {$v in {yes no}} { return $v }
	return [dict get $defaults $key]
}

# Write KEY=VALUE: its line is replaced (or added), and every other line stays as it was.
proc power::conf_set {key value} {
	set f [power::conf_file]
	set out {}
	set done 0
	foreach line [power::conf_lines] {
		if {[regexp "^${key}=" $line]} {
			if {!$done} { lappend out "${key}=$value"; set done 1 }
		} elseif {$line ne ""} {
			lappend out $line
		}
	}
	if {!$done} { lappend out "${key}=$value" }
	file mkdir [file dirname $f]
	set tmp "$f.tmp"
	set fh [open $tmp w]
	puts $fh [join $out \n]
	close $fh
	file rename -force $tmp $f
}

# ---- the idle timers --------------------------------------------------------------
# swayidle takes its timeouts at start, so the timers are restarted when the state changes: on battery or plugged in
# (OnBattery), or when a value changes. The four states are the two sets of timers, each with and without the dim.

# A word for the shell swayidle runs its commands with (a quoted string when it has special characters).
proc power::shq {s} {
	if {[regexp {^[A-Za-z0-9_./:=+-]+$} $s]} { return $s }
	return "'[string map [list "'" "'\\''"] $s]'"
}

# The swayidle arguments: the dim (20 s before the screen goes off), the screen off (wlopm), the lock (ribbon-lock:
# swaylock in the palette's colours), the suspend (loginctl), and lock before sleep. A timer set to Never (0) is left out.
proc power::idle_args {bat dim} {
	set p [expr {$bat ? "BAT" : "PL"}]
	set off [expr {[power::setting IDLE_${p}_OFF] * 60}]
	set lock [expr {[power::setting IDLE_${p}_LOCK] * 60}]
	set sus [expr {[power::setting IDLE_${p}_SUSPEND] * 60}]
	set args {-w}
	if {$dim eq "yes" && $off > 20} {
		lappend args timeout [expr {$off - 20}] {brightnessctl -q -s set 10%} resume {brightnessctl -q -r}
	}
	if {$off > 0} { lappend args timeout $off {wlopm --off "*"} resume {wlopm --on "*"} }
	if {$lock > 0} { lappend args timeout $lock ribbon-lock }
	if {$sus > 0} { lappend args timeout $sus {loginctl suspend} }
	lappend args before-sleep ribbon-lock
	set args
}

proc power::idle_pidfile {} {
	set d [expr {[info exists ::env(XDG_RUNTIME_DIR)] && $::env(XDG_RUNTIME_DIR) ne ""
		? $::env(XDG_RUNTIME_DIR) : [file dirname [power::conf_file]]}]
	file join $d ribbon-idle.pid
}

# The swayidle this process started: its pid is in the pid file, and that pid is a live process named swayidle (not a
# zombie, not another program that has the number now). RIBBON_PROC is /proc (tests).
proc power::idle_alive {} {
	if {[catch {open [power::idle_pidfile]} fh]} { return 0 }
	set pid [string trim [read $fh]]
	close $fh
	if {![string is integer -strict $pid]} { return 0 }
	set root [expr {[info exists ::env(RIBBON_PROC)] && $::env(RIBBON_PROC) ne "" ? $::env(RIBBON_PROC) : "/proc"}]
	if {[catch {open $root/$pid/stat} sh]} { return 0 }
	set st [read $sh]
	close $sh
	# "PID (COMM) STATE ...": the name may hold spaces and brackets, so it ends at the last ")"
	set e [string last ")" $st]
	set comm [string range $st [expr {[string first "(" $st] + 1}] [expr {$e - 1}]]
	return [expr {$comm eq "swayidle" && [string index $st [expr {$e + 2}]] ne "Z"}]
}

# Is the swayidle with these arguments still there? It is not when they changed, or when it has died (an OOM kill, a
# compositor reconnect, a start-up race): the idle lock and the lock before sleep are then gone, and a laptop suspends
# unlocked until something changes the arguments. A swayidle that keeps dying is tried again at most every 10 seconds.
proc power::idle_current {old args} {
	variable idle_started
	if {$args ne $old} { return 0 }
	if {[power::idle_alive]} { return 1 }
	if {[info exists idle_started] && [clock seconds] - $idle_started < 10} { return 1 }
	return 0
}

# Stop the swayidle this process started (its pid is in the pid file, and only if that pid is still a swayidle: a pid
# the system has handed to another program is not ours to kill), then start the new one detached, as the autostart
# lines do: the shell writes its own pid first, then execs swayidle.
proc power::idle_start {args} {
	variable idle_started
	set pidf [power::idle_pidfile]
	if {[power::idle_alive] && ![catch {open $pidf} fh]} {
		set old [string trim [read $fh]]
		close $fh
		if {[string is integer -strict $old]} { catch {exec kill $old} }
	}
	set idle_started [clock seconds]
	set words {}
	foreach a $args { lappend words [power::shq $a] }
	set script "echo \$\$ > [power::shq $pidf]; exec swayidle [join $words { }]"
	catch {exec sh -c $script >/dev/null 2>@1 &}
}

# Start swayidle for the state, unless it runs already with these arguments. Returns 1 when it started one.
proc power::idle_apply {bat} {
	variable idle_last
	set args [power::idle_args $bat [power::setting DIM]]
	if {[power::idle_current $idle_last {*}$args]} { return 0 }
	set idle_last $args
	power::idle_start {*}$args
	return 1
}

# Read OnBattery and apply the timers for it. A bus without UPower counts as plugged in.
proc power::idle_run {} {
	set on 0
	catch {
		power::ensure_bus
		set on [dict get [power::read_upower] onbattery]
	}
	power::idle_apply $on
	set closed 0
	catch { set closed [power::read_lid] }
	power::lid_step $closed $on
}

# logind's LidClosed (elogind has it too); a bus without logind counts as open.
proc power::read_lid {} {
	variable bus
	power::ensure_bus
	set v [lindex [$bus call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.DBus.Properties Get ss \
		org.freedesktop.login1.Manager LidClosed] 0]
	expr {[ribbon::dbus::strip v $v] ? 1 : 0}
}

# "Turn off the screen" for the lid (logind ignores the lid then: see power::root_set). With the lid closed and the
# setting on for this power state, blank the screen with wlopm; on opening it, light it again. Only what this blanked is
# lit again, so the idle timers' own blanking is left alone. Returns off, on or "" (nothing to do).
proc power::lid_step {closed bat} {
	variable lid_blank
	set key [expr {$bat ? "LID_BAT_SCREEN" : "LID_PL_SCREEN"}]
	set want [expr {$closed && [power::setting $key] eq "yes"}]
	if {$want && !$lid_blank} {
		set lid_blank 1
		catch {exec wlopm --off * >/dev/null 2>@1}
		return off
	}
	if {!$want && $lid_blank} {
		set lid_blank 0
		catch {exec wlopm --on * >/dev/null 2>@1}
		return on
	}
	return ""
}

# The daemon's loop (power-idle.tcl): one pass, then the next in 2 s.
proc power::idle_loop {} {
	coroutine ::power::idle[incr ::power::seq] power::idle_once
}

proc power::idle_once {} {
	catch {power::idle_run}
	after 2000 power::idle_loop
}

# ---- root settings: read only (no privilege), from the files -----------------------------------

proc power::root_file {rel} {
	set r [expr {[info exists ::env(RIBBON_POWER_ROOT)] ? $::env(RIBBON_POWER_ROOT) : ""}]
	if {$r eq ""} { set r / }
	file join $r $rel
}

# The value of KEY in a file of KEY=VALUE lines (a commented line does not match); "" when it is not there.
proc power::ini {file key} {
	set v ""
	if {[catch {open $file} fh]} { return "" }
	foreach line [split [read $fh] \n] {
		if {[regexp "^\\s*${key}\\s*=\\s*(\\S+)" $line -> x]} { set v $x }
	}
	close $fh
	set v
}

# A logind setting: logind.conf, then logind.conf.d/*.conf by file name (elogind reads them in that order; the last wins).
proc power::logind {key} {
	set v [power::ini [power::root_file etc/elogind/logind.conf] $key]
	foreach f [lsort [glob -nocomplain [power::root_file etc/elogind/logind.conf.d/*.conf]]] {
		set x [power::ini $f $key]
		if {$x ne ""} { set v $x }
	}
	set v
}

# The root settings: logind's lid and power key, UPower's critical action and level, and the battery's charge limit.
proc power::root {} {
	set lid [power::logind HandleLidSwitch]
	set ext [power::logind HandleLidSwitchExternalPower]
	set key [power::logind HandlePowerKey]
	set upw [power::root_file etc/UPower/UPower.conf]
	set crit [power::ini $upw CriticalPowerAction]
	set pct [power::ini $upw PercentageAction]
	set limit ""
	foreach f [glob -nocomplain [power::root_file sys/class/power_supply/BAT*/charge_control_end_threshold]] {
		if {![catch {open $f} fh]} { set limit [string trim [read $fh]]; close $fh; break }
	}
	set lid [expr {$lid eq "" ? "suspend" : $lid}]
	dict create lid $lid lid_ext [expr {$ext eq "" ? $lid : $ext}] power_key [expr {$key eq "" ? "poweroff" : $key}] \
		critical [expr {$crit eq "" ? "HybridSleep" : $crit}] critical_pct [expr {$pct eq "" ? 2 : $pct}] \
		charge_limit $limit
}

# A logind or UPower action as the page names it.
proc power::action_label {v} {
	switch -- [string tolower $v] {
		suspend { return Suspend }
		hibernate { return Hibernate }
		hybridsleep - hybrid-sleep { return "Hybrid sleep" }
		poweroff - power-off { return "Shut down" }
		ignore { return "Do nothing" }
		lock { return Lock }
		reboot { return Restart }
	}
	return $v
}

# ---- changing a root setting: pkexec ribbon-power-helper --------------------------------------------
# The helper takes a fixed list of names and values (apps/settings/bin/ribbon-power-helper) and never a path or free text;
# this side picks both from the page's own lists. Tests: with RIBBON_POWER_TEST set, RIBBON_POWER_PKEXEC (a program) and
# RIBBON_POWER_HELPER (a path) replace pkexec and /usr/bin/ribbon-power-helper; without it they are not read.

proc power::helper_cmd {} {
	if {[info exists ::env(RIBBON_POWER_TEST)] && $::env(RIBBON_POWER_TEST) ne ""} {
		set px [expr {[info exists ::env(RIBBON_POWER_PKEXEC)] && $::env(RIBBON_POWER_PKEXEC) ne "" ? $::env(RIBBON_POWER_PKEXEC) : "pkexec"}]
		set h [expr {[info exists ::env(RIBBON_POWER_HELPER)] && $::env(RIBBON_POWER_HELPER) ne "" ? $::env(RIBBON_POWER_HELPER) : "/usr/bin/ribbon-power-helper"}]
		return [list $px $h]
	}
	list pkexec /usr/bin/ribbon-power-helper
}

# One line for a failure: pkexec's 126 is a dialog that was dismissed or a refusal, 127 a failed authentication.
proc power::helper_error {out code} {
	switch -- $code {
		126 { return "Cancelled" }
		127 { return "Not authorised" }
	}
	set line [string trim [lindex [split [string trim $out] \n] 0]]
	regsub {^ribbon-power-helper: } $line {} line
	if {$line eq ""} { set line "The change failed" }
	if {[string length $line] > 70} { set line "[string range $line 0 66]..." }
	return $line
}

# Run the helper for NAME VALUE without blocking Tk (pkexec waits for a password). Must run in a coroutine. Returns "" or the
# error line.
proc power::helper_call {name value} {
	set cmd [list {*}[power::helper_cmd] set $name $value]
	if {[catch {open "|[list {*}$cmd 2>@1]" r} ch]} {
		return [expr {[string match "*no such file*" $ch] ? "pkexec is not installed" : [power::helper_error $ch 1]}]
	}
	set me [info coroutine]
	set out ""
	fconfigure $ch -blocking 0
	fileevent $ch readable [list apply {{ch me} {
		append ::power::hout($me) [read $ch]
		if {[eof $ch]} { $me }
	}} $ch $me]
	set ::power::hout($me) ""
	yield
	fileevent $ch readable {}
	set out $::power::hout($me)
	unset ::power::hout($me)
	fconfigure $ch -blocking 1
	set code 0
	if {[catch {close $ch} msg opts]} {
		set ec [dict get $opts -errorcode]
		set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : 1}]
	}
	if {$code == 0} { return "" }
	power::helper_error $out $code
}

# The items of a root dropdown, its current value and the helper setting behind it: {items current}. Items are
# {value label}. ID: lid_bat lid_pl power_key crit_pct crit_act charge.
proc power::root_menu {id} {
	set root [power::root]
	switch -- $id {
		lid_bat - lid_pl {
			set bat [expr {$id eq "lid_bat"}]
			set cur [dict get $root [expr {$bat ? "lid" : "lid_ext"}]]
			if {$cur eq "ignore" && [power::setting [expr {$bat ? "LID_BAT_SCREEN" : "LID_PL_SCREEN"}]] eq "yes"} { set cur screen }
			return [list {{suspend Suspend} {hibernate Hibernate} {screen {Turn off the screen}} {ignore {Do nothing}}} $cur]
		}
		power_key {
			set cur [dict get $root power_key]
			if {$cur eq "ignore" && [power::setting POWER_KEY_ASK] eq "yes"} { set cur ask }
			return [list {{ask Ask} {poweroff {Shut down}} {suspend Suspend} {hibernate Hibernate}} $cur]
		}
		crit_pct { return [list {{2 2%} {3 3%} {5 5%} {7 7%} {10 10%}} [dict get $root critical_pct]] }
		crit_act { return [list {{PowerOff {Shut down}} {Hibernate Hibernate} {HybridSleep {Hybrid sleep}}} [dict get $root critical]] }
		charge { return [list {{60 60%} {70 70%} {80 80%} {90 90%} {100 100%}} [dict get $root charge_limit]] }
	}
	error "no such setting: $id"
}

# Change a root setting from a dropdown: ID as in root_menu, VALUE one of its items. Asynchronous; the setting stays as it
# was unless the helper succeeds, and power::error says why when it does not.
proc power::root_set {id value} {
	variable rbusy
	if {$rbusy} return
	set rbusy 1
	coroutine ::power::root[incr ::power::seq] power::run_root $id $value
}

proc power::run_root {id value} {
	variable error; variable rbusy
	set error ""
	if {[catch {power::do_root $id $value} msg]} { set error $msg }
	set rbusy 0
	power::refresh
}

# The helper call (skipped when the logind setting already has the value, so a user-only change asks for no password) and
# then the page's own file: "Turn off the screen" is logind's ignore plus LID_*_SCREEN, "Ask" is ignore plus POWER_KEY_ASK.
proc power::do_root {id value} {
	set root [power::root]
	switch -- $id {
		lid_bat - lid_pl {
			set name [expr {$id eq "lid_bat" ? "HandleLidSwitch" : "HandleLidSwitchExternalPower"}]
			set cur [dict get $root [expr {$id eq "lid_bat" ? "lid" : "lid_ext"}]]
			set key [expr {$id eq "lid_bat" ? "LID_BAT_SCREEN" : "LID_PL_SCREEN"}]
			set screen [expr {$value eq "screen"}]
			set want [expr {$screen ? "ignore" : $value}]
			if {$cur ne $want} { power::helper_check $name $want }
			power::conf_set $key [expr {$screen ? "yes" : "no"}]
		}
		power_key {
			set ask [expr {$value eq "ask"}]
			set want [expr {$ask ? "ignore" : $value}]
			if {[dict get $root power_key] ne $want} { power::helper_check HandlePowerKey $want }
			power::conf_set POWER_KEY_ASK [expr {$ask ? "yes" : "no"}]
		}
		crit_pct { power::helper_check PercentageAction $value }
		crit_act { power::helper_check CriticalPowerAction $value }
		charge { power::helper_check ChargeLimit $value }
		default { error "no such setting: $id" }
	}
}

proc power::helper_check {name value} {
	set err [power::helper_call $name $value]
	if {$err ne ""} { error $err }
}

# ---- pure helpers (no bus) ----------------------------------------------------------

# "3 h 40 min" or "40 min" for SECS seconds.
proc power::left {secs} {
	set m [expr {int($secs) / 60}]
	if {$m >= 60} { return "[expr {$m / 60}] h [expr {$m % 60}] min" }
	return "$m min"
}

# The time line under the level: the time to empty, to full, or "Fully charged"; "" when UPower does not say.
proc power::time_text {state tte ttf} {
	switch -- $state {
		1 { if {$ttf > 0} { return "[power::left $ttf] to full" } }
		2 { if {$tte > 0} { return "[power::left $tte] left" } }
		4 { return "Fully charged" }
	}
	return ""
}

proc power::profile_label {p} {
	switch -- $p {
		power-saver { return Saver }
		balanced { return Balanced }
		performance { return Performance }
	}
	return $p
}

# The subtitle is the state of the page (or the error): the battery and the power mode.
proc power::subtitle {} {
	variable model; variable error; variable loaded
	if {$error ne ""} { return $error }
	if {!$loaded} { return "" }
	if {[dict get $model error] ne ""} { return [dict get $model error] }
	set place [expr {[dict get $model bat] ? "Built-in battery" : "No battery"}]
	set p [power::profile_label [dict get $model profile]]
	expr {$p eq "" ? $place : "$place · $p"}
}

# The timeouts the idle dropdowns offer: minutes, 0 is Never.
proc power::timeout_items {} {
	list {1 {1 minute}} {2 {2 minutes}} {5 {5 minutes}} {10 {10 minutes}} {15 {15 minutes}} {30 {30 minutes}} {0 Never}
}

# The setting behind an idle dropdown (bat_off, pl_lock, ...).
proc power::key_of {id} {
	dict get {bat_off IDLE_BAT_OFF pl_off IDLE_PL_OFF bat_lock IDLE_BAT_LOCK pl_lock IDLE_PL_LOCK \
		bat_suspend IDLE_BAT_SUSPEND pl_suspend IDLE_PL_SUSPEND} $id
}

# The label of a timeout in minutes.
proc power::timeout_label {m} {
	foreach item [power::timeout_items] {
		if {[lindex $item 0] == $m} { return [lindex $item 1] }
	}
	return "$m minutes"
}
