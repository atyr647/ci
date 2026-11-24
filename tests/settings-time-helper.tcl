# settings-time-helper.tcl - apps/settings/bin/ribbon-time-helper on a fake root (RIBBON_TIME_TEST, RIBBON_TIME_ROOT,
# and stand-ins for date, hwclock and dinitctl), under every POSIX shell there is here: what it refuses, the zone link
# replaced whole and /etc/timezone with it, the date and time checked as a calendar date, the time service turned on
# and off through dinitctl, the safety checks on /etc, a hostile environment; and against the real things there are
# here: the real zone files (the TZif check), and the real `date` reading the very words the helper hands to `date -s`.
#   tclsh8.6 tests/settings-time-helper.tcl HELPER
# Prints one line per check; exits 1 if any failed. It never runs the helper outside a test root as root: the two
# checks that leave the test (no RIBBON_TIME_TEST, PKEXEC_UID set) run as nobody when this is root, or not at all.
set helper [file normalize [lindex $argv 0]]
set fails 0
proc check {what cond} {
	global fails
	if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what ($::last)"; incr fails }
}
proc slurp {f} { if {[catch {open $f rb} fh]} { return "(none)" }; set t [read $fh]; close $fh; set t }
proc spit {f t} { file mkdir [file dirname $f]; set fh [open $f wb]; puts -nonewline $fh $t; close $fh }
proc script {f body} { spit $f "#!/bin/sh\n$body\n"; file attributes $f -permissions 0755 }

set T [file normalize [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] th-[pid]-[clock milliseconds]]]
file mkdir $T
set R $T/root
set me [exec id -u]
set SH sh
set AS {}
set last ""
set ZI /usr/share/zoneinfo

# Run the helper with EXTRA (a dict over the test's own environment; "(unset)" removes): {exit-code stdout stderr}.
proc run {args} { runenv {} {*}$args }
proc runenv {extra args} {
	global helper R T SH
	set keep [array get ::env]
	array set ::env [list RIBBON_TIME_TEST 1 RIBBON_TIME_ROOT $R RIBBON_TIME_DATE $T/date RIBBON_TIME_HWCLOCK $T/hwclock \
		RIBBON_TIME_DINITCTL $T/dinitctl LOG $T/log MODE $T/mode ROOT $R]
	catch {unset ::env(PKEXEC_UID)}
	foreach {k v} $extra { if {$v eq "(unset)"} { catch {unset ::env($k)} } else { set ::env($k) $v } }
	set code 0
	if {[catch {exec {*}$::AS {*}$SH $helper {*}$args 2>$T/stderr} out opts]} {
		set ec [dict get $opts -errorcode]
		set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : -1}]
		if {$code == -1} { set out [dict get $opts -errorinfo] } else { set out "" }
	}
	foreach k [array names ::env] { if {![dict exists $keep $k]} { unset ::env($k) } }
	array set ::env $keep
	set ::last [list $code [string trim $out] [string trim [slurp $T/stderr]]]
}
proc log {} { string trim [slurp $::T/log] }
proc mode {m} { spit $::T/mode $m; file delete $::T/log }
# what is in /etc besides what the test put there (a temporary file left behind)
proc litter {} { lsort [glob -nocomplain -directory $::R/etc -tails .localtime.* .timezone.*] }

# The stand-ins. Each logs its words; the file MODE says which of them fail.
script $T/date {echo "date $*" >>"$LOG"; m=$(cat "$MODE" 2>/dev/null)
case "$1" in +*) case "$m" in *badnow*) echo "half past ten" ;; *) echo 23:59:58 ;; esac ;; esac
case "$m" in *datefail*) exit 1 ;; esac; exit 0}
script $T/hwclock {echo "hwclock $*" >>"$LOG"; case "$(cat "$MODE" 2>/dev/null)" in *hwfail*) exit 1 ;; esac; exit 0}
script $T/dinitctl {echo "dinitctl $*" >>"$LOG"
m=$(cat "$MODE" 2>/dev/null)
case "$1" in
	enable) case "$m" in *enablefail*) exit 1 ;; esac; mkdir -p "$ROOT/etc/dinit.d/boot.d"; ln -sf "../$2" "$ROOT/etc/dinit.d/boot.d/$2" ;;
	disable) case "$m" in *disablefail*) exit 1 ;; esac; rm -f "$ROOT/etc/dinit.d/boot.d/$2" ;;
	start) case "$m" in *startfail*) exit 1 ;; esac ;;
	stop) case "$m" in *stopfail*) exit 1 ;; esac ;;
esac
exit 0}

# The fake root: /etc with a zone link and /etc/timezone, three real zones, the time service's description.
proc fresh {} {
	global R ZI
	file delete -force $R
	file mkdir $R/etc $R/usr/share/zoneinfo/Europe $R/usr/share/zoneinfo/Asia $R/usr/share/zoneinfo/America/Argentina $R/run/dinit.d
	foreach z {Europe/London Asia/Tokyo America/Argentina/Buenos_Aires} { file copy $ZI/$z $R/usr/share/zoneinfo/$z }
	file mkdir $R/usr/share/zoneinfo/posix/Asia
	file copy $ZI/Asia/Tokyo $R/usr/share/zoneinfo/posix/Asia/Tokyo
	spit $R/usr/share/zoneinfo/Europe/Notazone "not a zone\n"
	file link -symbolic $R/etc/localtime $R/usr/share/zoneinfo/Europe/London
	spit $R/etc/timezone "Europe/London\n"
	spit $R/run/dinit.d/chronyd "type = process\n"
	file attributes $R/etc -permissions 0755
	mode ""
}
proc zone_now {} { expr {[catch {file readlink $::R/etc/localtime} t] ? "(not a link)" : $t} }

proc suite {} {
	global R T me helper SH
	# ---- what it refuses, before anything is touched ------------------------------------------------
	fresh
	foreach {what words} {
		"no words" {}
		"a verb it does not have" {reboot now}
		"zone with no name" {zone}
		"zone with two names" {zone Asia/Tokyo Europe/London}
		"a path up out of zoneinfo" {zone ../../etc/passwd}
		"a path up inside a name" {zone Europe/../../../etc/shadow}
		"an absolute path" {zone /etc/passwd}
		"a name that ends in a slash" {zone Europe/}
		"a doubled slash" {zone Europe//London}
		"an option" {zone -h}
		"a name with a space" {zone "Europe/London x"}
		"a name with a command in it" {zone {Asia/$(id)}}
		"a name with a semicolon" {zone {Asia/Tokyo;id}}
		"a name with a dot" {zone Asia/Tokyo.bak}
		"the posix copy" {zone posix/Asia/Tokyo}
		"a zone there is no file for" {zone Europe/Atlantis}
		"an area (a directory)" {zone Europe}
		"a file that is not a zone" {zone Europe/Notazone}
		"a 65-letter name" {zone AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA}
		"set with three more words" {set 2026-11-07 10:42 x}
		"a date with one digit short" {set 2026-11-7 10:42}
		"month 13" {set 2026-13-01 10:42}
		"month 00" {set 2026-00-10 10:42}
		"30 February" {set 2026-02-30 10:42}
		"29 February in a common year" {set 2027-02-29 10:42}
		"31 April" {set 2026-04-31 10:42}
		"day 00" {set 2026-11-00 10:42}
		"1999" {set 1999-12-31 10:42}
		"2100" {set 2100-01-01 10:42}
		"hour 24" {set 2026-11-07 24:00}
		"minute 60" {set 2026-11-07 10:60}
		"second 60" {set 2026-11-07 10:42:60}
		"a time with one digit short" {set 2026-11-07 9:42}
		"a time with a command in it" {set 2026-11-07 {10:42;id}}
		"a date with a newline" {set "2026-11-07\n" 10:42}
		"date words (tomorrow)" {set tomorrow 10:42}
		"ntp with no word" {ntp}
		"ntp maybe" {ntp maybe}
		"ntp on with one more word" {ntp on chronyd}
	} {
		run {*}$words
		check "refused: $what" {[lindex $::last 0] == 2 && [lindex $::last 1] eq "" && [log] eq "(none)" && [zone_now] eq "$R/usr/share/zoneinfo/Europe/London" && [litter] eq {}}
	}
	# ---- zone -----------------------------------------------------------------------------------------
	run zone Asia/Tokyo
	check "zone: /etc/localtime is a link to the zone's file" {[lindex $::last 0] == 0 && [zone_now] eq "$R/usr/share/zoneinfo/Asia/Tokyo" && [file type $R/etc/localtime] eq "link"}
	check "  /etc/timezone names it, world-readable, and nothing is left behind" {[slurp $R/etc/timezone] eq "Asia/Tokyo\n" && [file attributes $R/etc/timezone -permissions] eq "00644" && [litter] eq {}}
	run zone America/Argentina/Buenos_Aires
	check "zone: a three-part name" {[lindex $::last 0] == 0 && [zone_now] eq "$R/usr/share/zoneinfo/America/Argentina/Buenos_Aires"}
	# tzdata's own zoneinfo/localtime is a link to /etc/localtime (Debian, Ubuntu): taking it would make /etc/localtime a
	# link to itself (a loop: every program falls back to UTC). Absolute, relative, and one link further on.
	foreach {what name link} [list "zoneinfo/localtime -> /etc/localtime" localtime $R/etc/localtime \
		"  the same link, relative" localtime ../../../etc/localtime \
		"  a zone that is a link to that link" Europe/Here ../localtime] {
		fresh
		file link -symbolic $R/usr/share/zoneinfo/localtime $R/etc/localtime
		if {$name ne "localtime"} { exec ln -s $link $R/usr/share/zoneinfo/$name } else { file delete $R/usr/share/zoneinfo/localtime; exec ln -s $link $R/usr/share/zoneinfo/localtime }
		run zone $name
		check "zone: refused, not made a loop: $what" {[lindex $::last 0] == 2 && [zone_now] eq "$R/usr/share/zoneinfo/Europe/London" && [litter] eq {}}
	}
	fresh
	file delete $R/etc/timezone
	run zone Europe/London
	check "zone: /etc/timezone is not created when it was not there" {[lindex $::last 0] == 0 && ![file exists $R/etc/timezone] && [zone_now] eq "$R/usr/share/zoneinfo/Europe/London"}
	file delete $R/etc/localtime
	file copy $R/usr/share/zoneinfo/Europe/London $R/etc/localtime
	run zone Asia/Tokyo
	check "zone: a copied /etc/localtime becomes a link" {[lindex $::last 0] == 0 && [zone_now] eq "$R/usr/share/zoneinfo/Asia/Tokyo"}
	file delete $R/etc/localtime
	run zone Europe/London
	check "zone: no /etc/localtime yet" {[lindex $::last 0] == 0 && [zone_now] eq "$R/usr/share/zoneinfo/Europe/London"}
	file delete $R/etc/localtime
	file mkdir $R/etc/localtime
	run zone Asia/Tokyo
	check "zone: an /etc/localtime that is a directory is not replaced" {[lindex $::last 0] == 1 && [file isdirectory $R/etc/localtime] && [glob -nocomplain -directory $R/etc/localtime *] eq {} && [litter] eq {}}
	file delete -force $R/etc/localtime
	file mkdir $R/elsewhere
	file link -symbolic $R/etc/localtime $R/elsewhere
	run zone Asia/Tokyo
	check "  nor a link to a directory (nothing is put in it)" {[lindex $::last 0] == 1 && [glob -nocomplain -directory $R/elsewhere *] eq {} && [litter] eq {}}
	fresh
	file delete $R/etc/timezone
	spit $R/elsewhere/tz "kept\n"
	file link -symbolic $R/etc/timezone $R/elsewhere/tz
	run zone Asia/Tokyo
	check "zone: an /etc/timezone that is a link is left alone" {[lindex $::last 0] == 0 && [slurp $R/elsewhere/tz] eq "kept\n" && [file type $R/etc/timezone] eq "link"}
	fresh
	file attributes $R/etc -permissions 0775
	run zone Asia/Tokyo
	check "zone: an /etc others can write is not written in" {[lindex $::last 0] == 1 && [zone_now] eq "$R/usr/share/zoneinfo/Europe/London"}
	file attributes $R/etc -permissions 0755
	# ---- set ------------------------------------------------------------------------------------------
	fresh
	run set 2026-11-07 10:42
	check "set: date -s with the date and the time, seconds added; then hwclock -w" {[lindex $::last 0] == 0 && [log] eq "date -s 2026-11-07 10:42:00\nhwclock -w"}
	mode ""
	run set 2028-02-29 23:59:59
	check "set: 29 February in a leap year, seconds given" {[lindex $::last 0] == 0 && [log] eq "date -s 2028-02-29 23:59:59\nhwclock -w"}
	mode ""
	run set 2026-08-09 08:09:09
	check "set: 08 and 09 are numbers, not bad octal" {[lindex $::last 0] == 0 && [log] eq "date -s 2026-08-09 08:09:09\nhwclock -w"}
	mode ""
	run set 2026-11-07
	check "set: the date alone keeps the time of day it is when the clock is set" {[lindex $::last 0] == 0 && [log] eq "date +%H:%M:%S\ndate -s 2026-11-07 23:59:58\nhwclock -w"}
	mode ""
	run set 2026-02-30
	check "  a date alone that is not a date is refused" {[lindex $::last 0] == 2 && [log] eq "(none)"}
	mode badnow
	run set 2026-11-07
	check "  a time of day that cannot be read is a failure, and the clock is not set" {[lindex $::last 0] == 1 && [log] eq "date +%H:%M:%S"}
	mode hwfail
	run set 2026-11-07 00:00
	check "set: a hardware clock that cannot be written is said, not a failure" {[lindex $::last 0] == 0 && [string match "*hardware clock could not be written" [lindex $::last 1]]}
	mode datefail
	run set 2026-11-07 10:42
	check "set: a date that fails is a failure, and hwclock is not run" {[lindex $::last 0] == 1 && [log] eq "date -s 2026-11-07 10:42:00"}
	mode ""
	runenv {RIBBON_TIME_HWCLOCK (unset)} set 2026-11-07 10:42
	check "set: no hwclock program: the clock is still set" {[lindex $::last 0] == 0 && [log] eq "date -s 2026-11-07 10:42:00"}
	mode ""
	runenv {RIBBON_TIME_DATE (unset)} set 2026-11-07 10:42
	check "set: in a test the real date is never run" {[lindex $::last 0] == 1 && [log] eq "(none)"}
	# ---- ntp ------------------------------------------------------------------------------------------
	fresh
	run ntp on
	check "ntp on: dinitctl enable, then start, the service dinit has (chronyd)" {[lindex $::last 0] == 0 && [log] eq "dinitctl enable chronyd\ndinitctl start chronyd" && [lindex $::last 1] eq "chronyd is on"}
	mode enablefail
	run ntp on
	check "ntp on: already enabled is not a failure" {[lindex $::last 0] == 0 && [log] eq "dinitctl enable chronyd\ndinitctl start chronyd"}
	file mkdir $R/var/service
	exec ln -s /etc/sv/chronyd $R/var/service/chronyd
	mode ""
	run ntp off
	check "ntp off on a base without runit services (no /etc/sv): a /var/service link is not touched" {[lindex $::last 0] == 0 && ![catch {file lstat $R/var/service/chronyd st}]}
	file mkdir $R/etc/sv
	mode ""
	run ntp off
	check "ntp off: dinitctl disable and stop, and the runit-way link goes" {[lindex $::last 0] == 0 && [log] eq "dinitctl disable chronyd\ndinitctl stop chronyd" && [catch {file lstat $R/var/service/chronyd st}] && ![file exists $R/etc/dinit.d/boot.d/chronyd]}
	mode enablefail
	run ntp on
	check "ntp on: an enable that fails is a failure (nothing is started)" {[lindex $::last 0] == 1 && [log] eq "dinitctl enable chronyd"}
	mode startfail
	run ntp on
	check "ntp on: a service that does not start is a failure" {[lindex $::last 0] == 1}
	mode disablefail
	run ntp off
	check "ntp off: a disable that leaves it enabled is a failure (it is not stopped)" {[lindex $::last 0] == 1 && [log] eq "dinitctl disable chronyd"}
	mode ""
	run ntp off
	mode stopfail
	run ntp off
	check "ntp off: a service that does not stop is a failure" {[lindex $::last 0] == 1}
	spit $R/etc/dinit.d/ntpd "type = process\n"
	mode ""
	run ntp on
	check "ntp: chronyd comes before ntpd" {[log] eq "dinitctl enable chronyd\ndinitctl start chronyd"}
	file delete $R/run/dinit.d/chronyd
	mode ""
	run ntp on
	check "ntp: ntpd when it is the one there" {[lindex $::last 0] == 0 && [log] eq "dinitctl enable ntpd\ndinitctl start ntpd"}
	file delete $R/etc/dinit.d/ntpd
	mode ""
	run ntp on
	check "ntp: no time service: a failure, dinitctl not run" {[lindex $::last 0] == 1 && [log] eq "(none)" && [string match "*no time service*" [lindex $::last 2]]}
	fresh
	runenv {RIBBON_TIME_DINITCTL (unset)} ntp on
	check "ntp: in a test the real dinitctl is never run" {[lindex $::last 0] == 1 && [log] eq "(none)"}
	# ---- a hostile environment ----------------------------------------------------------------------
	fresh
	file mkdir $T/evil
	foreach tool {ln mv mktemp id find rm chmod dd tr rmdir} { script $T/evil/$tool "echo $tool >>\"$T/evil.log\"; exit 1" }
	runenv [list PATH $T/evil:$::env(PATH) IFS "/" CDPATH $T/evil ENV $T/evil/ln TZ Mars/Olympus] zone Asia/Tokyo
	check "PATH, IFS, CDPATH, ENV and TZ are not trusted" {[lindex $::last 0] == 0 && [zone_now] eq "$R/usr/share/zoneinfo/Asia/Tokyo" && ![file exists $T/evil.log]}
	runenv {RIBBON_TIME_ROOT relative/root} zone Europe/London
	check "a test root that is not absolute is refused" {[lindex $::last 0] == 2}
	runenv {RIBBON_TIME_ROOT /} zone Europe/London
	check "a test root of / is refused" {[lindex $::last 0] == 2}
	file link -symbolic $T/to-root /
	foreach r [list /. /etc/.. //. $T/to-root] {
		runenv [list RIBBON_TIME_ROOT $r] zone Europe/London
		check "  nor / spelt as $r" {[lindex $::last 0] == 2}
	}
	file delete $T/to-root
	# ---- outside a test -----------------------------------------------------------------------------
	# as root these two would act on the real system: they are run as nobody then (setpriv), or not at all
	set ::AS {}
	if {$me == 0 && ![catch {exec setpriv --reuid 65534 --regid 65534 --clear-groups {*}$SH -c {test -r "$1"} sh $helper}]} {
		set ::AS {setpriv --reuid 65534 --regid 65534 --clear-groups}
	}
	if {$me != 0 || $::AS ne {}} {
		runenv {RIBBON_TIME_TEST (unset)} zone Asia/Tokyo
		check "without RIBBON_TIME_TEST it must be root" {[lindex $::last 0] == 1 && [string match "*pkexec*" [lindex $::last 2]] && [zone_now] eq "$R/usr/share/zoneinfo/Asia/Tokyo"}
		fresh
		runenv {PKEXEC_UID 1000} zone Asia/Tokyo
		check "under pkexec (PKEXEC_UID) the test's root is not read" {[lindex $::last 0] == 1 && [zone_now] eq "$R/usr/share/zoneinfo/Europe/London"}
	} else {
		puts "  skip the two checks outside a test (root here, and no setpriv to be nobody)"
	}
	set ::AS {}
}

set shells {}
foreach s {sh dash {busybox sh} {bash --posix}} {
	set at [lindex [auto_execok [lindex $s 0]] 0]
	if {$at ne ""} { lappend shells [list $s [lreplace $s 0 0 $at]] }
}
foreach s $shells {
	puts "  -- under [lindex $s 0]"
	set SH [lindex $s 1]
	suite
}

# ---- the real things ---------------------------------------------------------------------------------
# Every zone the real tzdata has under the ten areas passes the helper's own checks (the name, the file, TZif).
set SH sh
fresh
file delete -force $R/usr/share/zoneinfo
file link -symbolic $R/usr/share/zoneinfo $ZI
set n 0; set bad {}
foreach area {Africa America Antarctica Arctic Asia Atlantic Australia Europe Indian Pacific} {
	foreach f [glob -nocomplain -directory $ZI/$area -tails -types f * */*] {
		incr n
		if {$n % 12} continue   ;# one in twelve is run through the helper; all of them are name-checked below
		run zone $area/$f
		if {[lindex $::last 0] != 0 || [zone_now] ne "$R/usr/share/zoneinfo/$area/$f"} { lappend bad $area/$f }
	}
}
check "the real zone files: one in twelve of $n set through the helper" {$n > 300 && $bad eq {}}
# The real date reads what the helper hands to `date -s` (asked with -d, which parses the same and sets nothing).
script $T/date {echo "date $*" >>"$LOG"; [ "$1" = -s ] || exit 1; exec date -d "$2" '+%Y-%m-%d %H:%M:%S' >>"$LOG"}
mode ""
run set 2026-11-07 10:42
check "the real date reads the helper's words as that date and time" {[lindex $::last 0] == 0 && [lindex [split [log] \n] 1] eq "2026-11-07 10:42:00"}
if {[lindex [auto_execok busybox] 0] ne ""} {
	script $T/date {[ "$1" = -s ] || exit 1; exec busybox date -d "$2" '+%Y-%m-%d %H:%M:%S' >>"$LOG"}
	mode ""
	run set 2028-02-29 23:59:59
	check "  and so does busybox's date" {[lindex $::last 0] == 0 && [lindex [split [log] \n] 0] eq "2028-02-29 23:59:59"}
}
file delete -force $T
if {$fails} { puts "time helper: $fails failed"; exit 1 }
puts "time helper: all checks passed"
