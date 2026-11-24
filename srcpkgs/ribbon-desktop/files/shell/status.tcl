# status.tcl - clock, Wi-Fi, volume, battery and updates for the right bar.
#
# Cheap by design: the clock wakes once a minute (once a second only while
# Settings' "Seconds in the bar" is on), Wi-Fi and battery are
# small /proc and /sys reads, volume follows PipeWire's change events
# (pactl subscribe) instead of polling, and updates are read from kit's
# cache file once a minute (kit-updater writes it, every 6 h by default).

namespace eval status {
	variable date ""
	variable time ""
	variable wifi ""        ;# "" no Wi-Fi hardware, on, off
	variable bt ""          ;# "" no Bluetooth adapter, on, off
	variable muted 0
	variable volume ""      ;# "" no audio sink known
	variable battery ""     ;# "" no battery, else 0-100
	variable updates 0
	variable storage {}     ;# ribbon-reserve's view: state user_free spare ...; {} without it
	variable volchan ""
	variable volbusy 0      ;# a volume read is running
	variable volagain 0     ;# a volume change came while it ran: read once more
	variable outs           ;# channel -> output read so far (status::run)
	variable clockset {HOUR24 yes SECONDS no DATE yes}   ;# clock.conf, as last read
	variable clocksig "\0"   ;# what clock.conf and /etc/localtime looked like then
	variable clocktz ""     ;# -timezone for the system's zone (":Europe/London"), "" for Tcl's own local time
	variable localtime /etc/localtime   ;# the system's zone (a test points it elsewhere)
}

proc status::start {} {
	clock_tick
	wifi_tick
	battery_tick
	storage_tick
	volume_watch
	updates_tick
	after 3000 status::bt_battery
}

# A Bluetooth device's battery in the bar (bluetooth.conf's BAR_BATTERY, Settings → Bluetooth): the quick panel's
# BlueZ read is started once, and follows BlueZ's changes from then on. Looked at again every minute, for a list
# set later.
proc status::bt_battery {} {
	if {[bar::conf bluetooth BAR_BATTERY ""] ne "" && ![info exists ::panel::data(devs)]} { catch {panel::bz_load} }
	after 60000 status::bt_battery
}

proc status::changed {} {
	after cancel shell::refresh
	after idle shell::refresh
}

# The clock. What it shows is Settings → Date and time's (clock.conf: HOUR24, SECONDS, DATE) and the system's zone
# (/etc/localtime). Both are looked at on every tick (two stats; read again only when one changed), and Settings says
# "clock" on the shell's FIFO when it changed either, so the bar follows at once without a restart.
proc status::clock_sig {} {
	variable localtime
	set sig {}
	set cfg [expr {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""
		? $::env(XDG_CONFIG_HOME) : [file join [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}] .config]}]
	foreach f [list [file join $cfg ribbon clock.conf] $localtime] {
		if {[catch {file lstat $f st}]} { lappend sig - } else { lappend sig $st(mtime) $st(size) $st(ino) }
	}
	return $sig
}
proc status::clock_load {} {
	variable localtime
	variable clockset
	variable clocktz ""
	foreach {k def} {HOUR24 yes SECONDS no DATE yes} {
		set v [bar::conf clock $k $def]
		dict set clockset $k [expr {$v in {yes no} ? $v : $def}]
	}
	# the zone by name when /etc/localtime is a link into zoneinfo: Tcl reads a zone it is asked for by name again,
	# while its own idea of local time is read once per process. A user's TZ wins, as it does everywhere.
	if {[info exists ::env(TZ)] && $::env(TZ) ne ""} return
	if {![catch {file readlink $localtime} target] && [regexp {zoneinfo/(?:posix/|right/)?([A-Za-z0-9_+/-]+)$} $target -> z]
		&& ![catch {clock format 0 -timezone :$z}]} {
		set clocktz :$z
	} else {
		# a copy of a zone's file: make Tcl read /etc/localtime again
		catch {unset ::tcl::clock::CachedSystemTimeZone}
		catch {unset ::tcl::clock::TZData(:Tcl/Localtime)}
	}
}
proc status::clock_format {now fmt} {
	variable clocktz
	if {$clocktz ne "" && ![catch {clock format $now -format $fmt -timezone $clocktz} t]} { return $t }
	clock format $now -format $fmt
}
proc status::clock_tick {} {
	variable date
	variable time
	variable clockset
	variable clocksig
	after cancel status::clock_tick
	set sig [clock_sig]
	if {$sig ne $clocksig} { set clocksig $sig; clock_load }
	set now [clock seconds]
	set secs [expr {[dict get $clockset SECONDS] eq "yes"}]
	set d [expr {[dict get $clockset DATE] eq "yes" ? [regsub { 0} [clock_format $now "%a %d %b"] { }] : ""}]
	if {[dict get $clockset HOUR24] eq "yes"} {
		set t [clock_format $now [expr {$secs ? "%H:%M:%S" : "%H:%M"}]]
	} else {
		set t [string trim [clock_format $now [expr {$secs ? "%l:%M:%S %p" : "%l:%M %p"}]]]
	}
	if {$d ne $date || $t ne $time} { set date $d; set time $t; changed }
	set ms [expr {($secs ? 1000 : (60 - $now % 60) * 1000) - [clock milliseconds] % 1000 + 50}]
	after $ms status::clock_tick
}
# Settings changed the clock's settings, the zone or the time (ribbon-shell-ctl clock): read and show them now.
proc status::clock_reload {args} {
	variable clocksig "\0"
	clock_tick
}
# after idle: shell::verb is defined by main.tcl after this file is sourced (as controls.tcl's power-menu)
after idle {catch {shell::verb clock status::clock_reload}}

proc status::bt_read {} {
	variable bt
	set new ""
	if {[llength [glob -nocomplain /sys/class/bluetooth/hci*]]} {
		set new on
		foreach r [glob -nocomplain /sys/class/rfkill/rfkill*] {
			if {[catch {open $r/type} fh]} continue
			set t [string trim [read $fh]]; close $fh
			if {$t ne "bluetooth"} continue
			if {![catch {open $r/soft} fh]} { if {[string trim [read $fh]] eq "1"} { set new off }; close $fh }
		}
	}
	if {$new ne $bt} { set bt $new; changed }
}

proc status::wifi_tick {} {
	variable wifi
	bt_read
	set new ""
	if {![catch {open /proc/net/wireless} fh]} {
		set lines [lrange [split [string trim [read $fh]] \n] 2 end]
		close $fh
		if {[llength [glob -nocomplain /sys/class/net/*/wireless]]} { set new off }
		foreach l $lines {
			if {[regexp {^\s*\S+:\s+\S+\s+(-?[\d.]+)} $l -> q] && $q > 0} { set new on }
		}
	}
	if {$new ne $wifi} { set wifi $new; changed }
	after 15000 status::wifi_tick
}

proc status::battery_tick {} {
	variable battery
	set new ""
	foreach d [glob -nocomplain /sys/class/power_supply/BAT*] {
		if {![catch {open $d/capacity} fh]} {
			set new [string trim [read $fh]]; close $fh
			break
		}
	}
	if {$new ne $battery} { set battery $new; changed }
	after 60000 status::battery_tick
}

# Disk space left for your files, from the ribbon-reserve service: one
# small file read a minute.
proc status::storage_tick {} {
	variable storage
	set new {}
	if {![catch {open /run/ribbon/reserve} fh]} {
		foreach l [split [read $fh] \n] { if {[regexp {^(\w+)=(.*)$} $l -> k v]} { dict set new $k $v } }
		close $fh
	}
	if {$new ne $storage} { set storage $new; changed }
	after 60000 status::storage_tick
}

proc status::storage_state {} {
	variable storage
	expr {[dict exists $storage state] ? [dict get $storage state] : "ok"}
}

# 3.2 GB, 640 MB
proc status::human {b} {
	if {$b eq ""} { set b 0 }
	if {$b >= 1073741824} { return [format "%.1f GB" [expr {$b / 1073741824.0}]] }
	format "%d MB" [expr {$b / 1048576}]
}

# Runs CMD in a pipe that the event loop reads: nothing waits for it. DONE is called with {ok output} when it ends
# (ok is 0 when it did not start or exited with an error).
proc status::run {cmd done} {
	variable outs
	if {[catch {open |[list {*}$cmd 2>/dev/null] r} ch]} { after idle [list {*}$done 0 ""]; return }
	fconfigure $ch -blocking 0 -encoding utf-8
	set outs($ch) ""
	fileevent $ch readable [list status::run_read $ch $done]
}

proc status::run_read {ch done} {
	variable outs
	append outs($ch) [::read $ch]
	if {![::eof $ch]} return
	fileevent $ch readable {}
	set ok [expr {![catch {::close $ch}]}]
	set out $outs($ch)
	unset outs($ch)
	{*}$done $ok $out
}

# The volume is read in a pipe; a read asked for while one runs is done once more after it.
proc status::volume_read {} {
	variable volbusy
	variable volagain
	if {$volbusy} { set volagain 1; return }
	set volbusy 1
	run {wpctl get-volume @DEFAULT_AUDIO_SINK@} status::volume_got
}

proc status::volume_got {ok out} {
	variable volbusy
	variable volagain
	variable volume
	variable muted
	set volbusy 0
	if {$ok} {
		set v ""; set m 0
		regexp {Volume:\s+([\d.]+)} $out -> v
		set m [string match *MUTED* $out]
		if {$v ne $volume || $m != $muted} { set volume $v; set muted $m; changed }
	}
	if {$volagain} { set volagain 0; volume_read }
}

proc status::volume_watch {} {
	variable volchan
	volume_read
	if {[catch {open |[list pactl subscribe 2>/dev/null]} volchan]} { set volchan ""; return }
	fconfigure $volchan -blocking 0 -buffering line
	fileevent $volchan readable status::volume_event
}

proc status::volume_event {} {
	variable volchan
	set hit 0
	while {[gets $volchan line] >= 0} {
		if {[string match "*sink*" $line] || [string match "*server*" $line]} { set hit 1 }
	}
	if {$hit} { after cancel status::volume_read; after 50 status::volume_read }
	if {[eof $volchan]} { catch {close $volchan}; set volchan ""; after 5000 status::volume_watch }
}

proc status::volume_step {delta} {
	set amount "[expr {abs($delta)}]%"
	if {$delta > 0} { append amount + } else { append amount - }
	run [list wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ $amount] status::volume_stepped
}

proc status::volume_stepped {ok out} { volume_read }

# The updates waiting, from kit's cache file ~/.cache/kit/updates (kit-updater
# writes it after each check): a Tcl dict with notify (yes: show them in the
# bar) and updates (one entry per waiting kit). Nothing waiting, notify off or
# no file yet: 0, which hides the chip.
proc status::updates_tick {} {
	updates_read
	after 60000 status::updates_tick
}

proc status::updates_read {} {
	variable updates
	set n 0
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/"}]
	set cache [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$home/.cache"}]
	# kit's waiting kits (kit-updater) and the system's packages (ribbon update --tcl), both in kit's form; kit's
	# notify (default yes) says whether the count shows at all
	set notify 1
	foreach f [list [file join $cache kit updates] [file join $cache ribbon system-updates]] {
		if {[catch {open $f r} fh]} continue
		fconfigure $fh -encoding utf-8
		set text [read $fh]
		close $fh
		if {[catch {dict size $text}]} continue
		if {[dict exists $text notify] && ![string is true -strict [dict get $text notify]]} { set notify 0 }
		if {[dict exists $text updates]} { incr n [llength [dict get $text updates]] }
	}
	if {!$notify} { set n 0 }
	if {$n != $updates} { set updates $n; changed }
}
