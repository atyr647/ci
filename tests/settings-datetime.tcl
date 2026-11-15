# settings-datetime.tcl - apps/settings/datetime.tcl (the logic of Settings → Date and time) with no display, on a fake
# root (RIBBON_TIME_ROOT: /etc/localtime, /etc/timezone, a small zoneinfo of real zone files, dinit's directories), with
# stand-ins for pkexec, date, hwclock and dinitctl, and the REAL ribbon-time-helper behind the pkexec stand-in: the
# display choices' file, the zone list and where it comes from, the zone and its fallbacks, times in the zone (and in a
# new zone within this same process), the calendar, the time service's state, every change through the helper, a
# cancelled prompt, the shell being told, and the event loop staying free while the helper runs. Then the real tzdata.
#   tclsh8.6 -encoding utf-8 tests/settings-datetime.tcl FILESDIR
# The environment (HOME, XDG_CONFIG_HOME, XDG_RUNTIME_DIR, TMPDIR) is the step's (tests/steps.d/55-settings-datetime.sh).
set D [lindex $argv 0]
set fails 0
proc check {what cond} {
	global fails
	if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}
proc slurp {f} { if {[catch {open $f rb} fh]} { return "(none)" }; set t [read $fh]; close $fh; set t }
proc spit {f t} { file mkdir [file dirname $f]; set fh [open $f wb]; puts -nonewline $fh $t; close $fh }
proc script {f body} { spit $f "#!/bin/sh\n$body\n"; file attributes $f -permissions 0755 }
# Wait (the event loop running) until COND holds; 0 when it did not within MS.
proc wait {cond {ms 8000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel 1 [list expr $cond]]} {
		if {[clock milliseconds] > $end} { return 0 }
		after 20 {set ::tick 1}; vwait ::tick
	}
	return 1
}
proc log {} { string trim [slurp $::T/log] }
proc mode {m} { spit $::T/mode $m; file delete $::T/log }

set T [file normalize [file join $::env(TMPDIR) dt-[pid]]]
set R $T/root
set ZI /usr/share/zoneinfo
file mkdir $T $R/etc $R/usr/share/zoneinfo
foreach z {UTC Europe/London Europe/Paris Asia/Tokyo America/New_York Pacific/Auckland Etc/UTC} {
	file mkdir [file dirname $R/usr/share/zoneinfo/$z]
	file copy $ZI/$z $R/usr/share/zoneinfo/$z
}
spit $R/usr/share/zoneinfo/tzdata.zi "# version test\nR x 1 2 - Ja 1 0 0 -\nZ Europe/London -0:1:15 - LMT 1847 D\n0 E GMT/BST\nZ Asia/Tokyo 9:18:59 - LMT 1887 D 31\n9 J J%sT\nZ America/New_York -4:56:2 - LMT 1883\nZ Pacific/Auckland 11:39:4 - LMT 1868\nZ Europe/Atlantis 1 - XXX\nZ Mars/Olympus 0 - MMT\nZ Etc/UTC 0 - UTC\nL Europe/London GB\nL Europe/London Europe/Paris\nL Etc/UTC UTC\n"
file link -symbolic $R/etc/localtime $R/usr/share/zoneinfo/Europe/London
script $T/pkexec {echo "pkexec $*" >>"$LOG"
case "$(cat "$MODE" 2>/dev/null)" in *cancel*) exit 126 ;; *deny*) exit 127 ;; *slow*) sleep 1 ;; esac
exec "$@"}
# asked for the time of day (+%H:%M:%S) it answers 10:42:52: the moment the clock is set, after the prompt
script $T/date {echo "date $*" >>"$LOG"; case $1 in +*) echo 10:42:52 ;; esac}
script $T/hwclock {echo "hwclock $*" >>"$LOG"}
script $T/dinitctl {m=$(cat "$MODE" 2>/dev/null)
case "$1" in
	status) case "$m" in *statusfail*) echo "dinitctl: cannot connect" >&2; exit 1 ;; esac
		printf 'Service: %s\n    State: %s\n    Activation: explicitly started\n' "$2" "$(cat "$ROOT/state" 2>/dev/null || echo STOPPED)"; exit 0 ;;
esac
echo "dinitctl $*" >>"$LOG"
case "$1" in
	enable) mkdir -p "$ROOT/etc/dinit.d/boot.d"; ln -sf "../$2" "$ROOT/etc/dinit.d/boot.d/$2" ;;
	disable) rm -f "$ROOT/etc/dinit.d/boot.d/$2" ;;
	start) echo STARTED >"$ROOT/state" ;;
	stop) echo STOPPED >"$ROOT/state" ;;
esac
exit 0}
array set ::env [list RIBBON_TIME_TEST 1 RIBBON_TIME_ROOT $R RIBBON_TIME_PKEXEC $T/pkexec \
	RIBBON_TIME_HELPER $D/apps/settings/bin/ribbon-time-helper RIBBON_TIME_DATE $T/date RIBBON_TIME_HWCLOCK $T/hwclock \
	RIBBON_TIME_DINITCTL $T/dinitctl LOG $T/log MODE $T/mode ROOT $R]
catch {unset ::env(TZ)}
catch {unset ::env(PKEXEC_UID)}
mode ""

source -encoding utf-8 $D/apps/settings/datetime.tcl
set changes 0
set dt::onchange {incr ::changes}
set CF $::env(XDG_CONFIG_HOME)/ribbon/clock.conf

# ---- the display choices --------------------------------------------------------------------------------
check "no clock.conf: the defaults (24-hour, no seconds, the date, Monday)" {[dt::setting HOUR24] eq "yes" && [dt::setting SECONDS] eq "no" && [dt::setting DATE] eq "yes" && [dt::setting WEEKSTART] eq "monday"}
check "a choice is saved" {[dt::conf_set SECONDS yes] && [slurp $CF] eq "SECONDS=yes\n" && [dt::setting SECONDS] eq "yes"}
spit $CF "# mine\nSECONDS=yes\nOTHER=kept\nSECONDS=no\nHOUR24=perhaps\nWEEKSTART=sunday\n"
check "the last line for a key wins; a value that is not one is the default" {[dt::setting SECONDS] eq "no" && [dt::setting HOUR24] eq "yes" && [dt::setting WEEKSTART] eq "sunday"}
dt::conf_set SECONDS yes
check "saving keeps every other line and leaves one line for the key" {[slurp $CF] eq "# mine\nSECONDS=yes\nOTHER=kept\nHOUR24=perhaps\nWEEKSTART=sunday\n"}
check "nothing but the file is left in its directory (written beside, renamed over)" {[glob -nocomplain -directory [file dirname $CF] -tails * .*.conf.*] eq "clock.conf"}
check "a value or a key it does not have is not saved" {![dt::conf_set SECONDS maybe] && ![dt::conf_set COLOUR red] && ![dt::conf_set WEEKSTART tuesday]}
spit $CF "\x00\xff\xfe garbage\nSECONDS\n=yes\n"
check "a damaged file reads as the defaults" {[dt::setting SECONDS] eq "no" && [dt::setting DATE] eq "yes"}
file delete $CF
# a config directory that cannot be made (its place is taken by a file)
set keep $::env(XDG_CONFIG_HOME)
spit $T/notadir "x"
set ::env(XDG_CONFIG_HOME) $T/notadir
check "a file that cannot be written: not saved, said so, and the choice reads as before" {![dt::conf_set DATE no] && $dt::error ne "" && [dt::setting DATE] eq "yes"}
set ::env(XDG_CONFIG_HOME) $keep
dt::conf_set DATE yes
check "  and the next save that works clears that" {$dt::error eq ""}
file delete $CF
# the shell is told through its FIFO
set fifo $::env(XDG_RUNTIME_DIR)/ribbon-shell
check "no shell running: saving works and tells no one" {[dt::conf_set HOUR24 yes] && ![dt::poke_shell]}
spit $fifo ""
dt::conf_set HOUR24 yes
check "a plain file where the FIFO would be is not written to" {[slurp $fifo] eq ""}
file delete $fifo
exec mkfifo -m 600 $fifo
set sh [open $fifo {RDWR NONBLOCK}]
fconfigure $sh -blocking 0 -buffering line
dt::conf_set SECONDS yes
check "the running shell is told \"clock\" on its FIFO" {[gets $sh] eq "clock"}
close $sh
check "a FIFO nobody reads does not block" {[dt::conf_set SECONDS no] && ![dt::poke_shell]}
file delete $fifo $CF

# ---- the zone list ---------------------------------------------------------------------------------------
check "zones: tzdata.zi's Z and L names under the ten areas whose file is there, UTC first" {[dt::zones] eq {UTC America/New_York Asia/Tokyo Europe/London Europe/Paris Pacific/Auckland}}
set dt::zonesread 0
file rename $R/usr/share/zoneinfo/tzdata.zi $T/tzdata.zi
spit $R/usr/share/zoneinfo/zone1970.tab "# comment\nGB,GG\t+513030-0000731\tEurope/London\tmost of it\nJP\t+353916+1394441\tAsia/Tokyo\nXX\t+0000+0000\tEurope/Atlantis\n"
check "zones: zone1970.tab when there is no tzdata.zi" {[dt::zones] eq {UTC Asia/Tokyo Europe/London}}
set dt::zonesread 0
file delete $R/usr/share/zoneinfo/zone1970.tab
spit $R/usr/share/zoneinfo/zone.tab "JP\t+353916+1394441\tAsia/Tokyo\n"
check "zones: zone.tab after that" {[dt::zones] eq {UTC Asia/Tokyo}}
set dt::zonesread 0
file delete $R/usr/share/zoneinfo/zone.tab
check "zones: the directory itself when there is no list" {[dt::zones] eq {UTC America/New_York Asia/Tokyo Europe/London Europe/Paris Pacific/Auckland}}
set dt::zonesread 0
file rename $R/usr/share/zoneinfo $R/usr/share/zi
check "zones: no zoneinfo at all is an empty list" {[dt::zones] eq {}}
file rename $R/usr/share/zi $R/usr/share/zoneinfo
file rename $T/tzdata.zi $R/usr/share/zoneinfo/tzdata.zi
set dt::zonesread 0

# ---- the zone --------------------------------------------------------------------------------------------
check "the zone is the /etc/localtime link's" {[dt::zone] eq "Europe/London"}
file delete $R/etc/localtime
exec ln -s ../usr/share/zoneinfo/Asia/Tokyo $R/etc/localtime
check "  a relative link too" {[dt::zone] eq "Asia/Tokyo"}
file delete $R/etc/localtime
exec ln -s /usr/share/zoneinfo/posix/America/New_York $R/etc/localtime
check "  and the posix copy is the zone itself" {[dt::zone] eq "America/New_York"}
file delete $R/etc/localtime
spit $R/etc/timezone "Pacific/Auckland\n"
check "no link: /etc/timezone" {[dt::zone] eq "Pacific/Auckland"}
spit $R/etc/timezone "../../etc/passwd\n"
set ::env(TZ) :Asia/Tokyo
check "an /etc/timezone that is not a name: TZ" {[dt::zone] eq "Asia/Tokyo"}
unset ::env(TZ)
file delete $R/etc/timezone
check "nothing says: no zone, and the model still stands" {[dt::zone] eq "" && [dict get [dt::model] zone] eq "" && [dict get [dt::model] name] ne ""}
file copy $R/usr/share/zoneinfo/Europe/Paris $R/etc/localtime
check "a copy of a zone's file: the zone it is a copy of" {[dt::zone] eq "Europe/Paris"}
file delete $R/etc/localtime
spit $R/etc/localtime "TZif-but-nobody's"
check "a file that is no zone's: no zone" {[dt::zone] eq ""}
file delete $R/etc/localtime
file link -symbolic $R/etc/localtime $R/usr/share/zoneinfo/Europe/London

# ---- times in the zone -----------------------------------------------------------------------------------
set t [clock scan "2026-11-07 10:42:30" -format "%Y-%m-%d %H:%M:%S" -timezone :UTC]
proc dt::now {} { return $::t }
check "the time, the long date and the date's value in the zone" {[dt::time_text $t] eq "10:42" && [dt::long_date $t] eq "Saturday 7 November 2026" && [dt::date_text $t] eq "7 November 2026" && [dt::abbr] eq "GMT" && [dt::ymd $t] eq {2026 11 7}}
dt::conf_set HOUR24 no
check "without the 24-hour clock: 10:42 AM, and 1:05 PM" {[dt::time_text $t] eq "10:42 AM" && [dt::time_text [expr {$t + 8580}]] eq "1:05 PM"}
dt::conf_set HOUR24 yes
set s [clock scan "2026-07-01 12:00:00" -format "%Y-%m-%d %H:%M:%S" -timezone :UTC]
check "summer time is the zone's (13:00 BST)" {[dt::time_text $s] eq "13:00" && [dt::abbr $s] eq "BST"}
check "the model: the zone, its abbreviation, the subtitle" {[dict get [dt::model] zone] eq "Europe/London" && [dict get [dt::model] abbr] eq "GMT" && [dict get [dt::model] subtitle] eq "Europe/London"}
file delete $R/etc/localtime
file link -symbolic $R/etc/localtime $R/usr/share/zoneinfo/Asia/Tokyo
check "the link moved under this process: the next reading is the new zone's time (19:42 JST)" {[dt::time_text $t] eq "19:42" && [dt::abbr] eq "JST" && [dt::long_date [expr {$t + 6 * 3600}]] eq "Sunday 8 November 2026"}
file delete $R/etc/localtime
file link -symbolic $R/etc/localtime $R/usr/share/zoneinfo/Europe/London

# ---- the calendar ------------------------------------------------------------------------------------------
set m [dt::month 2026 11 monday]
check "November 2026 from Monday: 42 cells from 26 October to 6 December" {[llength $m] == 42 && [lindex $m 0] eq {2026 10 26 0} && [lindex $m 6] eq {2026 11 1 1} && [lindex $m 35] eq {2026 11 30 1} && [lindex $m 41] eq {2026 12 6 0}}
set m [dt::month 2026 11 sunday]
check "  from Sunday: it starts on the 1st and ends on 12 December" {[lindex $m 0] eq {2026 11 1 1} && [lindex $m 41] eq {2026 12 12 0}}
check "  the weekday letters follow" {[dt::weekdays monday] eq {M T W T F S S} && [dt::weekdays sunday] eq {S M T W T F S}}
set m [dt::month 2027 1 monday]
check "January 2027: the year before in its first week" {[lindex $m 0] eq {2026 12 28 0} && [lindex $m 4] eq {2027 1 1 1} && [dt::month_title 2027 1] eq "January 2027"}
check "months and days step across years; February knows leap years" {[dt::shift_month 2026 12 1] eq {2027 1} && [dt::shift_month 2026 1 -1] eq {2025 12} && [dt::shift_day 2026 12 31 1] eq {2027 1 1} && [dt::shift_day 2028 3 1 -1] eq {2028 2 29} && [dt::days_in 2028 2] == 29 && [dt::days_in 2027 2] == 28 && [dt::days_in 2026 11] == 30}

# ---- the time service --------------------------------------------------------------------------------------
dt::start
check "no time service: nothing to switch, and the clock is set by hand" {![dict get [dt::model] ntp_available] && ![dict get [dt::model] ntp_on] && [dt::manual] && ![dt::set_ntp 1]}
spit $R/run/dinit.d/chronyd "type = process\n"
mode statusfail
dt::refresh
check "chronyd known to dinit, not enabled, dinitctl silent: off" {[dict get [dt::model] ntp_available] && ![dict get [dt::model] ntp_on]}
file mkdir $R/var/service
exec ln -s /etc/sv/chronyd $R/var/service/chronyd
dt::refresh
check "a runit-way link on a base without runit services (no /etc/sv): not enabled" {![dict get [dt::model] ntp_on]}
file mkdir $R/etc/sv
dt::refresh
check "enabled the runit way: on, and the subtitle says so" {[dict get [dt::model] ntp_on] && [dict get [dt::model] subtitle] eq "Europe/London · set from the internet"}
file delete $R/var/service/chronyd
spit $R/state "STARTED\n"
mode ""
set changes 0
dt::refresh
check "not enabled but dinit says STARTED: on once dinit has answered (without blocking)" {![dict get [dt::model] ntp_on] && [wait {$::changes > 0}] && [dict get [dt::model] ntp_on]}
spit $R/state "STOPPED\n"
file mkdir $R/etc/dinit.d/boot.d
spit $R/etc/dinit.d/boot.d/chronyd ""
set changes 0
dt::refresh
check "enabled but dinit says STOPPED: off" {[dict get [dt::model] ntp_on] && [wait {$::changes > 0}] && ![dict get [dt::model] ntp_on]}
file delete $R/etc/dinit.d/boot.d/chronyd

# ---- changes, through pkexec and the real helper -------------------------------------------------------------
mode ""
set changes 0
check "set_zone starts the helper and comes back at once" {[dt::set_zone Asia/Tokyo] && $dt::busy && ![dt::set_zone Europe/Paris]}
check "  the helper was asked through pkexec for that zone, and the link is the new zone's" {[wait {!$dt::busy}] && [lindex [split [log] \n] 0] eq "pkexec $D/apps/settings/bin/ribbon-time-helper zone Asia/Tokyo" && [file readlink $R/etc/localtime] eq "$R/usr/share/zoneinfo/Asia/Tokyo"}
check "  the page is told, and this process shows the new zone's time" {$::changes > 0 && $dt::error eq "" && [dt::zone] eq "Asia/Tokyo" && [dt::time_text $t] eq "19:42"}
mode ""
check "the zone it already is asks for nothing; nor does a name that is not one" {![dt::set_zone Asia/Tokyo] && ![dt::set_zone ../etc/passwd] && [log] eq "(none)"}
mode cancel
dt::set_zone Europe/London
check "a cancelled prompt: the zone as it was, and the reason" {[wait {!$dt::busy}] && [dt::zone] eq "Asia/Tokyo" && $dt::error eq "Cancelled" && [dict get [dt::model] subtitle] eq "Cancelled"}
mode deny
dt::set_zone Europe/London
check "a failed authentication likewise" {[wait {!$dt::busy}] && [dt::zone] eq "Asia/Tokyo" && $dt::error eq "Not authorised"}
mode ""
dt::set_zone Europe/Atlantis
check "a zone the helper refuses: its words, the zone as it was" {[wait {!$dt::busy}] && [dt::zone] eq "Asia/Tokyo" && $dt::error eq "There is no time zone of that name"}
mode slow
set fired 0
set t0 [clock milliseconds]
dt::set_zone Europe/London
after 100 {set ::fired [expr {$dt::busy ? 1 : -1}]}
check "while pkexec waits (a second here) the event loop runs" {[clock milliseconds] - $t0 < 300 && [wait {$::fired != 0}] && $::fired == 1 && [wait {!$dt::busy}] && [dt::zone] eq "Europe/London" && $dt::error eq ""}
# the date and the time: only by hand
# enabled the runit way (a link, as runit's are: turning it off removes it)
exec ln -s /etc/sv/chronyd $R/var/service/chronyd
dt::refresh
mode ""
check "set from the internet: the date and the time are not set by hand" {![dt::manual] && ![dt::set_date 2026 11 12] && ![dt::set_time 09:05] && [log] eq "(none)"}
dt::set_ntp 0
check "set_ntp off: the helper disables and stops chronyd, and the model is off" {[wait {!$dt::busy}] && [log] eq "pkexec $D/apps/settings/bin/ribbon-time-helper ntp off\ndinitctl disable chronyd\ndinitctl stop chronyd" && [wait {![dict get [dt::model] ntp_on]}] && $dt::error eq ""}
check "  and the runit link is gone" {[catch {file lstat $R/var/service/chronyd st}]}
# the time of day kept is the one when the clock is set (10:42:52 by the date stand-in), not when the day was
# clicked (10:42:30): the password prompt in between would put the clock behind by as long as it took
mode slow
dt::set_date 2026 11 12
check "set_date: that date with the time of day kept as it is then (date -s, then hwclock -w)" {[wait {!$dt::busy}] && [log] eq "pkexec $D/apps/settings/bin/ribbon-time-helper set 2026-11-12\ndate +%H:%M:%S\ndate -s 2026-11-12 10:42:52\nhwclock -w" && $dt::error eq ""}
mode ""
dt::set_time 9:05
check "set_time: that time on today's date" {[wait {!$dt::busy}] && [lindex [split [log] \n] 1] eq "date -s 2026-11-07 09:05:00"}
mode ""
check "what is not a time or a date asks for nothing" {![dt::set_time 25:00] && ![dt::set_time 10:60] && ![dt::set_time noon] && ![dt::set_time ""] && ![dt::set_date 2026 2 30] && ![dt::set_date 1999 1 1] && ![dt::set_date 2026 x 1] && [log] eq "(none)"}
dt::set_ntp 1
check "set_ntp on: the helper enables and starts chronyd, and the model is on" {[wait {!$dt::busy}] && [log] eq "pkexec $D/apps/settings/bin/ribbon-time-helper ntp on\ndinitctl enable chronyd\ndinitctl start chronyd" && [wait {[dict get [dt::model] ntp_on]}]}
set ::env(RIBBON_TIME_PKEXEC) $T/no-such-pkexec
mode ""
check "no pkexec: said so, nothing busy" {![dt::set_zone Asia/Tokyo] && !$dt::busy && $dt::error eq "pkexec is not installed"}
set ::env(RIBBON_TIME_PKEXEC) $T/pkexec

# ---- the real tzdata ---------------------------------------------------------------------------------------
unset ::env(RIBBON_TIME_TEST)
set dt::zonesread 0
set real [dt::zones]
set bad {}
foreach z $real { if {![dt::valid_zone $z] || [catch {clock format 0 -timezone :$z}]} { lappend bad $z } }
check "the real zone list: [llength $real] zones, every one a name the helper takes and a zone Tcl's clock knows" {[llength $real] > 300 && "Europe/London" in $real && "America/Argentina/Buenos_Aires" in $real && $bad eq {} && [lsearch -glob $real Etc/*] < 0}
set rz [dt::zone]
check "the real system's zone reads as a name ($rz)" {$rz ne "" && [dt::valid_zone $rz]}

file delete -force $T
if {$fails} { puts "date and time: $fails failed"; exit 1 }
puts "date and time: all checks passed"
