# settings-power-helper.tcl - apps/settings/bin/ribbon-power-helper on a fake root (RIBBON_POWER_TEST, RIBBON_POWER_ROOT,
# RIBBON_POWER_PROC, RIBBON_POWER_KILL): the allow-list, what is written and where, atomic replacement, the safety checks,
# the signals sent to elogind and upowerd, and the charge limit with "apply". No bus, no display, no root.
#   tclsh8.6 tests/settings-power-helper.tcl HELPER
# Prints one line per check; exits 1 if any failed.
set helper [file normalize [lindex $argv 0]]
set fails 0
proc check {what ok} {
	global fails
	if {$ok} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}
proc slurp {f} { if {[catch {open $f rb} fh]} { return "" }; set t [read $fh]; close $fh; set t }
proc spit {f t} { file mkdir [file dirname $f]; set fh [open $f wb]; puts -nonewline $fh $t; close $fh }

set T [file normalize [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] ph-[pid]-[clock milliseconds]]]
file mkdir $T
set R $T/root; set P $T/proc; set KLOG $T/kill.log
file mkdir $R/etc $R/sys $P
spit $T/kill {#!/bin/sh
echo "$*" >> "$KILL_LOG"
}
file attributes $T/kill -permissions 0755
set me [exec id -u]

# Run the helper: {exit-code stdout stderr}. TEST 0 leaves the test flag unset.
proc run {args} { runenv 1 {*}$args }
proc runenv {test args} {
	global helper R P T KLOG
	set env_keep [array get ::env]
	set ::env(RIBBON_POWER_ROOT) $R; set ::env(RIBBON_POWER_PROC) $P; set ::env(RIBBON_POWER_KILL) $T/kill; set ::env(KILL_LOG) $KLOG
	if {$test} { set ::env(RIBBON_POWER_TEST) 1 } else { catch {unset ::env(RIBBON_POWER_TEST)} }
	set err $T/stderr
	set code 0
	if {[catch {exec tclsh8.6 $helper {*}$args 2>$err} out opts]} {
		set ec [dict get $opts -errorcode]
		set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : 1}]
		set out [string trim [slurp $err]]
		if {$out eq "" && [lindex $ec 0] ne "CHILDSTATUS"} { set out [dict get $opts -errorinfo] }
		set o ""
	} else { set o $out }
	set e [string trim [slurp $err]]
	foreach k {RIBBON_POWER_ROOT RIBBON_POWER_PROC RIBBON_POWER_KILL KILL_LOG RIBBON_POWER_TEST} {
		if {[dict exists $env_keep $k]} { set ::env($k) [dict get $env_keep $k] } else { catch {unset ::env($k)} }
	}
	list $code [string trim $o] $e
}
proc tree {dir} {
	set out {}
	foreach f [lsort [glob -nocomplain -directory $dir -types {f d l} *]] {
		lappend out $f
		if {[file isdirectory $f] && [file type $f] ne "link"} { lappend out {*}[tree $f] }
	}
	set out
}
proc hidden {d} { lmap f [glob -nocomplain -directory $d -tails .*] {if {$f in {. ..}} continue; set f} }
proc kills {} { split [string trimright [slurp $::KLOG] \n] \n }
proc fake_proc {pid comm uid} { spit $::P/$pid/comm "$comm\n"; spit $::P/$pid/status "Name:\t$comm\nUid:\t$uid\t$uid\t$uid\t$uid\n" }

set dropin $R/etc/elogind/logind.conf.d/50-ribbon-power.conf
set upconf $R/etc/UPower/UPower.conf
set bat $R/sys/class/power_supply/BAT0
file mkdir $R/etc/elogind $R/etc/UPower
spit $R/etc/elogind/logind.conf "\[Login\]\n#HandlePowerKey=poweroff\n"
set up0 "# UPower\n\[UPower\]\nEnableWattsUpPro=false\n# a comment with a byte \xe9\nPercentageLow=20\nPercentageCritical=5\nPercentageAction=2\nCriticalPowerAction=HybridSleep\n\n\[Other\]\nX=1\n"
spit $upconf $up0
spit $bat/type "Battery\n"; spit $bat/charge_control_end_threshold "100\n"
spit $R/sys/class/power_supply/AC/type "Mains\n"
file mkdir $R/etc/elogind  ;# keep the mode 0755 the test user's umask gives
foreach d [list $R/etc $R/etc/elogind $R/etc/UPower] { file attributes $d -permissions 0755 }
set snapshot [tree $R]

# ---- refused before anything is touched --------------------------------------------------------------------
foreach {what argv} {
	"no arguments" {}
	"an unknown verb" {frob HandlePowerKey ignore}
	"an unknown setting" {set HandleSuspendKey ignore}
	"a path as the setting" {set /etc/passwd ignore}
	"a lower-case setting" {set handlepowerkey ignore}
	"a value outside the list" {set HandlePowerKey kexec}
	"a value in the wrong case" {set HandlePowerKey Ignore}
	"a value with a trailing space" {set HandlePowerKey "ignore "}
	"a value with a newline" {set HandlePowerKey "ignore\nHandleLidSwitch=poweroff"}
	"a lid value the power key does not take" {set HandlePowerKey lock}
	"a critical action in logind's words" {set CriticalPowerAction hibernate}
	"a percentage of 0" {set PercentageAction 0}
	"a percentage over 15" {set PercentageAction 16}
	"a percentage with a sign" {set PercentageAction +5}
	"a percentage with a leading zero" {set PercentageAction 05}
	"a charge limit of 59" {set ChargeLimit 59}
	"a charge limit of 101" {set ChargeLimit 101}
	"a charge limit with a unit" {set ChargeLimit 80%}
	"a path as the value" {set ChargeLimit ../../etc/passwd}
	"too few arguments" {set HandlePowerKey}
	"too many arguments" {set HandlePowerKey ignore /etc/passwd}
	"apply with an argument" {apply /etc/passwd}
} {
	lassign [run {*}$argv] code out err
	check "refused (exit 2, nothing written): $what" [expr {$code == 2 && [tree $R] eq $snapshot && [slurp $upconf] eq $up0 && [kills] eq {}}]
}
lassign [run set HandlePowerKey "ignore\n\x01[string repeat A 300]"] code out err
check "a refusal names the setting's value shortened and printable" [expr {$code == 2 && [string length $err] < 200 && ![regexp {[\x00-\x08\x0b-\x1f]} $err]}]

# ---- logind --------------------------------------------------------------------------------------------------
fake_proc 100 elogind $me
fake_proc 101 elogind-other $me
fake_proc 102 elogind [expr {$me + 1}]   ;# another user's process of that name
fake_proc 103 bash $me
lassign [run set HandlePowerKey ignore] code out err
check "HandlePowerKey ignore: exit 0" [expr {$code == 0}]
check "the drop-in is the one file written, with the key under \[Login\]" [expr {[slurp $dropin] eq "# Written by ribbon-power-helper (Settings, Power). Edit there, not by hand.\n\[Login\]\nHandlePowerKey=ignore\n"}]
check "it is 0644 and a plain file" [expr {[file type $dropin] eq "file" && [file attributes $dropin -permissions] eq "00644"}]
check "no temporary file is left behind" [expr {[llength [hidden [file dirname $dropin]]] == 0 && [llength [glob -nocomplain -directory [file dirname $dropin] *]] == 1}]
check "elogind (and only a root-owned elogind) got SIGHUP" [expr {[kills] eq {{-HUP 100}} && $out eq "elogind reloaded"}]
check "logind.conf itself is untouched" [expr {[slurp $R/etc/elogind/logind.conf] eq "\[Login\]\n#HandlePowerKey=poweroff\n"}]
run set HandleLidSwitch suspend
run set HandleLidSwitchExternalPower ignore
run set HandlePowerKey hibernate
check "later changes keep the other keys and change the one" [expr {[string match "*HandlePowerKey=hibernate\nHandleLidSwitch=suspend\nHandleLidSwitchExternalPower=ignore\n" [slurp $dropin]]}]
spit $dropin "\[Login\]\nHandlePowerKey=ignore\nHandleLidSwitch=\$(evil)\nHandleKillAll=yes\nHandleLidSwitchExternalPower=lock\n"
run set HandlePowerKey poweroff
check "foreign or invalid lines in the drop-in are dropped on the next write" [expr {![string match "*evil*" [slurp $dropin]] && ![string match "*KillAll*" [slurp $dropin]] && [string match "*HandlePowerKey=poweroff\nHandleLidSwitchExternalPower=lock\n" [slurp $dropin]]}]
file delete -force $P/100
lassign [run set HandleLidSwitch ignore] code out err
check "elogind not running: still saved, and the answer says so" [expr {$code == 0 && [string match "*elogind is not running*" $out] && [string match "*HandleLidSwitch=ignore*" [slurp $dropin]]}]

# ---- atomic ---------------------------------------------------------------------------------------------------
file link -hard $T/oldlink $dropin
set old [slurp $dropin]
run set HandlePowerKey suspend
check "a write is a rename: a hard link to the old file still holds the old content whole" [expr {[slurp $T/oldlink] eq $old && [slurp $dropin] ne $old}]
file delete $T/oldlink
spit $T/outside "outside\n"
file delete $dropin
file link -symbolic $dropin $T/outside
run set HandlePowerKey suspend
check "a symlink in place of the drop-in is replaced, not followed" [expr {[slurp $T/outside] eq "outside\n" && [file type $dropin] eq "file"}]
file attributes $R/etc/elogind -permissions 0775
set before [slurp $dropin]
lassign [run set HandlePowerKey ignore] code out err
check "a group-writable /etc/elogind is refused (exit 1) and the old file is kept" [expr {$code == 1 && [string match "*can be written by others*" $err] && [slurp $dropin] eq $before}]
file attributes $R/etc/elogind -permissions 0755
file delete -force $dropin
file mkdir $dropin
lassign [run set HandlePowerKey ignore] code out err
check "a directory in place of the drop-in is refused" [expr {$code == 1 && [file isdirectory $dropin]}]
file delete -force $dropin
spit $R/etc/elogind/logind.conf.d/50-ribbon-power.conf [string repeat x 70000]
lassign [run set HandlePowerKey ignore] code out err
check "an oversize drop-in is refused" [expr {$code == 1 && [string match "*larger than*" $err]}]
file delete -force $R/etc/elogind/logind.conf.d
check "the temp name never survives a failed write" [expr {[llength [hidden $R/etc/elogind]] == 0 && [llength [hidden $R/etc/UPower]] == 0}]

# ---- UPower ---------------------------------------------------------------------------------------------------
spit $KLOG ""
fake_proc 200 upowerd $me
lassign [run set CriticalPowerAction Hibernate] code out err
set expect [string map {CriticalPowerAction=HybridSleep CriticalPowerAction=Hibernate} $up0]
check "CriticalPowerAction Hibernate changes that one line and nothing else (a non-ASCII byte kept)" [expr {$code == 0 && [slurp $upconf] eq $expect}]
check "upowerd got SIGTERM" [expr {[kills] eq {{-TERM 200}}}]
spit $KLOG ""
set ino [file attributes $upconf -permissions]
set mt [file mtime $upconf]
lassign [run set CriticalPowerAction Hibernate] code out err
check "the same value again writes nothing and signals nothing" [expr {$code == 0 && [kills] eq {} && $out eq "UPower already set"}]
run set CriticalPowerAction PowerOff
check "PowerOff" [expr {[string match "*\nCriticalPowerAction=PowerOff\n*" [slurp $upconf]]}]
run set PercentageAction 5
check "PercentageAction 5 lifts PercentageCritical to 6 (UPower needs low > critical > action)" \
	[expr {[string match "*\nPercentageLow=20\nPercentageCritical=6\nPercentageAction=5\n*" [slurp $upconf]]}]
spit $upconf "\[UPower\]\nPercentageLow=8\nPercentageCritical=5\nPercentageAction=2\n"
run set PercentageAction 10
check "and Low above Critical too" [expr {[slurp $upconf] eq "\[UPower\]\nPercentageLow=12\nPercentageCritical=11\nPercentageAction=10\n"}]
spit $upconf "\[UPower\]\nNoPollBatteries=false\n\n\[Other\]\nX=1\n"
run set CriticalPowerAction Hibernate
check "a missing key goes at the end of its section, before the blank line" [expr {[slurp $upconf] eq "\[UPower\]\nNoPollBatteries=false\nCriticalPowerAction=Hibernate\n\n\[Other\]\nX=1\n"}]
spit $upconf "\[UPower\]\nCriticalPowerAction=PowerOff\nCriticalPowerAction=PowerOff\nX=1\n"
run set CriticalPowerAction Hibernate
check "a repeated key is written once" [expr {[slurp $upconf] eq "\[UPower\]\nCriticalPowerAction=Hibernate\nX=1\n"}]
spit $upconf "\[Other\]\nX=1\n"
lassign [run set CriticalPowerAction Hibernate] code out err
check "a file with no \[UPower\] section is refused" [expr {$code == 1 && [slurp $upconf] eq "\[Other\]\nX=1\n"}]
file delete $upconf
lassign [run set CriticalPowerAction Hibernate] code out err
check "a missing UPower.conf is not created" [expr {$code == 1 && ![file exists $upconf]}]
spit $upconf $up0
file delete -force $P/200
lassign [run set CriticalPowerAction Hibernate] code out err
check "upowerd not running: saved, and the answer says so" [expr {$code == 0 && [string match "*upowerd is not running*" $out]}]

# ---- the charge limit -----------------------------------------------------------------------------------------
lassign [run set ChargeLimit 80] code out err
check "ChargeLimit 80 writes the battery's threshold" [expr {$code == 0 && [slurp $bat/charge_control_end_threshold] eq "80\n"}]
check "and remembers it for boot in /etc/ribbon/power-helper.conf" [expr {[string match "*\nCHARGE_LIMIT=80\n" [slurp $R/etc/ribbon/power-helper.conf]]}]
spit $R/sys/class/power_supply/AC/charge_control_end_threshold "100\n"
run set ChargeLimit 70
check "only a Battery is written (a Mains supply with the file is not)" [expr {[slurp $bat/charge_control_end_threshold] eq "70\n" && [slurp $R/sys/class/power_supply/AC/charge_control_end_threshold] eq "100\n"}]
spit $bat/charge_control_end_threshold "100\n"
lassign [run apply] code out err
check "apply puts the saved limit back" [expr {$code == 0 && [slurp $bat/charge_control_end_threshold] eq "70\n"}]
spit $R/etc/ribbon/power-helper.conf "CHARGE_LIMIT=5\n"
spit $bat/charge_control_end_threshold "100\n"
lassign [run apply] code out err
check "apply ignores a saved value outside the list" [expr {$code == 0 && [slurp $bat/charge_control_end_threshold] eq "100\n" && $out eq "nothing saved"}]
file delete -force $R/sys/class/power_supply/BAT0
set st [slurp $R/etc/ribbon/power-helper.conf]
lassign [run set ChargeLimit 90] code out err
check "no battery with a charge limit: refused with exit 1, nothing saved" [expr {$code == 1 && [slurp $R/etc/ribbon/power-helper.conf] eq $st}]

# ---- the test environment is honoured only with the test flag --------------------------------------------------
if {[file exists /etc/ribbon/power-helper.conf] || $me != 0} {
	puts "  skip the test flag check (needs root with no /etc/ribbon/power-helper.conf, or it would touch the real machine)"
} else {
	spit $R/etc/ribbon/power-helper.conf "CHARGE_LIMIT=80\n"
	file mkdir $bat; spit $bat/type "Battery\n"; spit $bat/charge_control_end_threshold "100\n"
	lassign [runenv 0 apply] code out err
	check "without RIBBON_POWER_TEST the fake root is not used (apply read the real /etc and wrote nothing)" \
		[expr {$code == 0 && $out eq "nothing saved" && [slurp $bat/charge_control_end_threshold] eq "100\n"}]
}
if {$me != 0} {
	lassign [runenv 0 set HandlePowerKey ignore] code out err
	check "without the flag, a non-root run is refused" [expr {$code == 1 && [string match "*pkexec*" $err]}]
}

file delete -force $T
if {$fails} { puts "$fails check(s) failed"; exit 1 }
puts "all checks passed"
