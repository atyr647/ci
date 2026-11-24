# shell-clock.tcl - RIBBON_SHELL_TEST hook for the bar's clock (shell/status.tcl, bar.tcl) and Settings → Date and
# time's choices (tests/steps.d/46-shell-clock.sh, on Xvfb, in the real shell): the clock's words with no clock.conf,
# with seconds (and the tick then once a second), without the 24-hour clock, without the date (and the bar drawn so);
# a file changed by hand noticed on the next tick; Settings' own save (apps/settings/datetime.tcl, sourced here) shown
# at once through the shell's FIFO, with no tick due; and the zone followed when the zone link is pointed elsewhere
# (status::localtime stands for /etc/localtime), without a restart. A 40 s limit ends the run if anything waits.
set failed 0
interp bgerror {} {apply {{msg opts} { puts "  FAIL background error: [dict get $opts -errorinfo]"; exit 1 }}}
after 40000 {puts "  FAIL the clock checks took more than 40 s"; exit 1}
proc check {what cond} { global failed; if {[uplevel #0 [list expr $cond]]} { puts "  ok   $what" } else { incr failed; puts "  FAIL $what (date '$::status::date' time '$::status::time')" } }
proc wait {cond {ms 3000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 [list expr $cond]]} {
		if {[clock milliseconds] > $end} { return 0 }
		after 20 {set ::tick 1}; vwait ::tick
	}
	return 1
}
proc spit {f t} { file mkdir [file dirname $f]; set fh [open $f w]; puts -nonewline $fh $t; close $fh }
# the time is FORMAT in ZONE now (or was a moment ago, when the minute has just turned)
proc is_time {zone format} {
	set now [clock seconds]
	expr {$::status::time in [list [clock format $now -format $format -timezone $zone] [clock format [expr {$now - 2}] -format $format -timezone $zone]]}
}
array set wm::ws {1 {name 1 active 1}}
set wm::wsorder {1}
set CF $::env(XDG_CONFIG_HOME)/ribbon/clock.conf
set T $::env(XDG_RUNTIME_DIR)
set ZI /usr/share/zoneinfo
exec ln -s $ZI/Asia/Tokyo $T/localtime
set status::localtime $T/localtime

status::clock_tick
check "no clock.conf: the date and the 24-hour time, as before" {[regexp {^[A-Z][a-z]{2} \d{1,2} [A-Z][a-z]{2}$} $status::date] && [regexp {^\d\d:\d\d$} $status::time]}
check "  in the system's zone (the link's: Asia/Tokyo)" {$status::clocktz eq ":Asia/Tokyo" && [is_time :Asia/Tokyo %H:%M]}
bar::draw; update
# every word on the bar's canvas, run together
proc bartext {} { set t ""; foreach i [.bar.c find all] { if {[.bar.c type $i] eq "text"} { append t [.bar.c itemcget $i -text] } }; regsub -all {\s} $t "" }
set wd [lindex $status::date 0]
check "the bar draws the date and the time" {[string first $wd [bartext]] >= 0 && [string first [string map {: ""} $status::time] [string map {: ""} [bartext]]] >= 0}

# a file written by hand: the next tick sees it
spit $CF "SECONDS=yes\n"
status::clock_tick
check "SECONDS=yes: the time has seconds" {[regexp {^\d\d:\d\d:\d\d$} $status::time]}
set was $status::time
check "  and the clock then ticks every second" {[wait {$status::time ne $was} 2500]}
spit $CF "SECONDS=yes\nHOUR24=no\n"
check "HOUR24=no: 12-hour with AM or PM, noticed on the tick with no restart" {[wait {[regexp {^\d{1,2}:\d\d:\d\d [AP]M$} $status::time]} 2500]}
spit $CF "SECONDS=no\nHOUR24=no\nDATE=no\n"
check "DATE=no: no date" {[wait {$status::date eq "" && [regexp {^\d{1,2}:\d\d [AP]M$} $status::time]} 2500]}
bar::draw; update
check "  and the bar draws the time alone" {[string first $wd [bartext]] < 0 && [regexp {[AP]M} [bartext]]}
spit $CF "\x00\xff garbage\nSECONDS\nHOUR24=sometimes\n"
status::clock_reload
check "a damaged clock.conf is the defaults" {$status::date ne "" && [regexp {^\d\d:\d\d$} $status::time]}

# Settings saves a choice: the shell is told on its FIFO and shows it now (the clock is on its minute tick here)
source -encoding utf-8 [file join $::env(RIBBON_FILES) apps settings datetime.tcl]
file delete $CF
status::clock_reload
check "Settings' save tells the running shell" {[dt::conf_set DATE no] && [file type [file join $::env(XDG_RUNTIME_DIR) ribbon-shell]] eq "fifo"}
check "  which drops the date at once, no tick due" {[wait {$status::date eq ""} 1500]}
dt::conf_set HOUR24 no
check "  and goes 12-hour at once" {[wait {[regexp {^\d{1,2}:\d\d [AP]M$} $status::time]} 1500]}
dt::conf_set HOUR24 yes; dt::conf_set DATE yes; dt::conf_set SECONDS yes
check "  and shows seconds at once" {[wait {$status::date ne "" && [regexp {^\d\d:\d\d:\d\d$} $status::time]} 1500]}
dt::conf_set SECONDS no
check "  and stops showing them" {[wait {[regexp {^\d\d:\d\d$} $status::time]} 1500]}

# the zone link pointed elsewhere: the next tick is in the new zone
file delete $T/localtime
exec ln -s $ZI/America/New_York $T/localtime
status::clock_tick
check "the zone link moved: the clock is in the new zone on its next tick, no restart" {$status::clocktz eq ":America/New_York" && [is_time :America/New_York %H:%M]}
file delete $T/localtime
exec ln -s $ZI/Pacific/Auckland $T/localtime
dt::poke_shell
check "  and at once when Settings says the zone changed" {[wait {$status::clocktz eq ":Pacific/Auckland" && [is_time :Pacific/Auckland %H:%M]} 1500]}
set ::env(TZ) Asia/Kolkata
status::clock_reload
check "a user's own TZ wins over the system's zone" {$status::clocktz eq "" && [is_time :Asia/Kolkata %H:%M]}
unset ::env(TZ)
file delete $T/localtime
status::clock_reload
check "no zone link at all: the clock still shows a time" {[regexp {^\d\d:\d\d$} $status::time]}

if {$failed} { puts "bar clock: $failed failed"; exit 1 }
puts "bar clock: all checks passed"
exit 0
