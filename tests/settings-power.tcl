# settings-power.tcl - Settings → Power's client (apps/settings/power.tcl) against the UPower and power-profiles-daemon
# stand-ins (tests/fixtures/upower.tcl, tests/fixtures/ppd.tcl) on a private system bus, with no display. Run by
# tests/steps.d/55-settings-power.sh with DBUS_SYSTEM_BUS_ADDRESS, UPOWER_LOG, PPD_LOG, SWAYIDLE_LOG, XDG_CONFIG_HOME and
# RIBBON_POWER_ROOT set, PATH with a swayidle stub first, and TCLLIBPATH="<unix_extra> <files>":
#   tclsh8.6 tests/settings-power.tcl FILES
# Prints one line per check; exits non-zero on the first failure.
set D [lindex $argv 0]
set fails 0
proc check {what ok} {
	global fails
	if {$ok} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}

source -encoding utf-8 [file join $D apps settings power.tcl]

# A background step finished: the model's change callback counts them.
set changes 0
set power::onchange {incr ::changes}

proc settle {n} {
	set t [clock milliseconds]
	while {$::changes <= $n || $power::busy} {
		if {[clock milliseconds] - $t > 8000} { return 0 }
		update
		after 10
	}
	return 1
}

# A process that is running (not stopped, and not a zombie waiting to be reaped).
proc alive {pid} {
	if {![file exists /proc/$pid/stat]} { return 0 }
	set fh [open /proc/$pid/stat]
	set s [read $fh]
	close $fh
	return [expr {![regexp {\) (\S)} $s -> st] || $st ne "Z"}]
}

# Poll until COND (an expression in the caller) is true, or MS pass: a detached swayidle starts a little later.
proc wait_for {cond {ms 4000}} {
	set t [clock milliseconds]
	while {![uplevel 1 [list expr $cond]]} {
		if {[clock milliseconds] - $t > $ms} { return 0 }
		update
		after 20
	}
	return 1
}

proc logged {var} {
	if {![file exists $::env($var)]} { return {} }
	set fh [open $::env($var)]
	set out [split [string trimright [read $fh] \n] \n]
	close $fh
	return $out
}

# ---- the read: the battery and the power mode -------------------------------------------
set n $changes
power::refresh
check "a read finishes" [settle $n]
set m $power::model
check "the read reports no error" [expr {[dict get $m error] eq ""}]
check "a battery is present" [expr {[dict get $m bat] == 1}]
check "the level is 82 %" [expr {[dict get $m pct] == 82.0}]
check "3 h 40 min left (13200 s to empty)" [expr {[power::time_text [dict get $m state] [dict get $m tte] [dict get $m ttf]] eq "3 h 40 min left"}]
check "health (capacity) 91 % and 312 cycles" [expr {[dict get $m health] == 91.0 && [dict get $m cycles] == 312}]
check "on the AC adapter (OnBattery 0)" [expr {[dict get $m onbattery] == 0}]
check "the power mode is balanced" [expr {[dict get $m profile] eq "balanced"}]
check "the three modes are offered" [expr {[dict get $m profiles] eq {power-saver balanced performance}}]
check "the subtitle reads Built-in battery, then the mode" [expr {[power::subtitle] eq "Built-in battery \u00b7 Balanced"}]

# ---- the power mode: set, and a refused name leaves the error for the page -----------------
set n $changes
power::set_profile performance
check "choosing Performance is sent and the model refreshed" [settle $n]
check "the profile line is in the PPD log" [expr {"profile\tperformance" in [logged PPD_LOG]}]
check "the model reads performance" [expr {[dict get $power::model profile] eq "performance"}]
check "no error after the change" [expr {$power::error eq ""}]

set n $changes
power::set_profile turbo
check "a refused profile is reported, not thrown" [settle $n]
check "the refusal is kept as the error" [expr {[string match "*no such profile*" $power::error]}]
check "the refused profile is not logged" [expr {"profile\tturbo" ni [logged PPD_LOG]}]
set n $changes
power::set_profile balanced
check "the profile is put back to balanced" [settle $n]
check "the error clears with the next action" [expr {$power::error eq ""}]

# ---- OnBattery: a change is read, and the idle timers follow -------------------------------
set b [ribbon::dbus::connect system]
$b call org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.DBus.Properties Set ssv org.freedesktop.UPower OnBattery [list b 1]
set n $changes
power::refresh
check "the AC state change is read (on battery)" [expr {[settle $n] && [dict get $power::model onbattery] == 1}]
check "the UPower log has the change" [expr {"onbattery\t1" in [logged UPOWER_LOG]}]

# ---- the four idle states (pure) -------------------------------------------------------------
set battery_dim [list -w timeout 280 {brightnessctl -q -s set 10%} resume {brightnessctl -q -r} \
	timeout 300 {wlopm --off "*"} resume {wlopm --on "*"} timeout 300 ribbon-lock timeout 900 {loginctl suspend} \
	before-sleep ribbon-lock]
set battery_nodim [list -w timeout 300 {wlopm --off "*"} resume {wlopm --on "*"} timeout 300 ribbon-lock \
	timeout 900 {loginctl suspend} before-sleep ribbon-lock]
set plugged_dim [list -w timeout 880 {brightnessctl -q -s set 10%} resume {brightnessctl -q -r} \
	timeout 900 {wlopm --off "*"} resume {wlopm --on "*"} timeout 900 ribbon-lock before-sleep ribbon-lock]
set plugged_nodim [list -w timeout 900 {wlopm --off "*"} resume {wlopm --on "*"} timeout 900 ribbon-lock \
	before-sleep ribbon-lock]
check "on battery, dim: the dim 20 s before the screen goes off, then screen, lock and suspend" \
	[expr {[power::idle_args 1 yes] eq $battery_dim}]
check "on battery, no dim" [expr {[power::idle_args 1 no] eq $battery_nodim}]
check "plugged in, dim" [expr {[power::idle_args 0 yes] eq $plugged_dim}]
check "plugged in, no dim (suspend is Never, so it is left out)" [expr {[power::idle_args 0 no] eq $plugged_nodim}]
check "shell quoting: it's" [expr {[power::shq "it's"] eq {'it'\''s'}}]

# ---- the idle daemon: swayidle starts, is kept on no change, and restarts on a change -------
set n $changes
power::idle_run
check "the first pass starts swayidle for the state (on battery)" [expr {[wait_for {[llength [logged SWAYIDLE_LOG]] == 1}]}]
check "the line is the one for on battery with dim" \
	[expr {[lindex [logged SWAYIDLE_LOG] 0] eq [join $battery_dim " "]}]
check "its pid is in the pid file" [wait_for {[file exists [power::idle_pidfile]] && [string is integer -strict [string trim [read [open [power::idle_pidfile]]]]]}]
set pid1 [string trim [read [open [power::idle_pidfile]]]]
power::idle_run
after 300
check "nothing changed: swayidle is not restarted" [expr {[llength [logged SWAYIDLE_LOG]] == 1}]

$b call org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.DBus.Properties Set ssv org.freedesktop.UPower OnBattery [list b 0]
power::idle_run
check "plugged in: swayidle is restarted with the plugged-in timers" \
	[expr {[wait_for {[llength [logged SWAYIDLE_LOG]] == 2}] && [lindex [logged SWAYIDLE_LOG] 1] eq [join $plugged_dim " "]}]
check "the old swayidle is stopped (not running, a zombie counts as stopped)" [wait_for {![alive $pid1]}]

power::conf_set DIM no
power::idle_run
check "turning the dim off restarts it without the dim" \
	[expr {[wait_for {[llength [logged SWAYIDLE_LOG]] == 3}] && [lindex [logged SWAYIDLE_LOG] 2] eq [join $plugged_nodim " "]}]
power::conf_set DIM yes

# ---- the settings file ---------------------------------------------------------------------------
set f [power::conf_file]
set fh [open $f w]
puts $fh "PALETTE=dusk\nIDLE_BAT_OFF=3"
close $fh
check "the defaults hold where the file has no line (plugged-in off: 15)" [expr {[power::setting IDLE_PL_OFF] == 15}]
check "a line in the file is read" [expr {[power::setting IDLE_BAT_OFF] == 3}]
power::conf_set IDLE_BAT_OFF 7
check "conf_set replaces the line" [expr {[power::setting IDLE_BAT_OFF] == 7}]
check "and keeps the other lines" [expr {"PALETTE=dusk" in [split [read [open $f]] \n]}]
set fh [open $f w]
puts $fh "IDLE_PL_OFF=abc\nBAR_PERCENT=maybe"
close $fh
check "a bad number takes the default" [expr {[power::setting IDLE_PL_OFF] == 15}]
check "a bad yes-or-no takes the default" [expr {[power::setting BAR_PERCENT] eq "yes"}]
power::conf_set BAR_PERCENT no
check "a switch saved as no reads no" [expr {[power::setting BAR_PERCENT] eq "no"}]

# ---- the root settings: read from the files only ---------------------------------------------------
set r $::env(RIBBON_POWER_ROOT)
file mkdir [file join $r etc elogind] [file join $r etc UPower] [file join $r sys class power_supply BAT0]
set fh [open [file join $r etc elogind logind.conf] w]
puts $fh "\[Login\]\nHandleLidSwitch=suspend\n#HandlePowerKey=ignore\nHandlePowerKey=poweroff\nHandleLidSwitchExternalPower=ignore"
close $fh
set fh [open [file join $r sys class power_supply BAT0 charge_control_end_threshold] w]
puts $fh 80
close $fh
set root [power::root]
check "the lid: Suspend" [expr {[power::action_label [dict get $root lid]] eq "Suspend"}]
check "the lid on AC: Do nothing (ignore)" [expr {[power::action_label [dict get $root lid_ext]] eq "Do nothing"}]
check "the power key: Shut down (a commented line is not read)" [expr {[power::action_label [dict get $root power_key]] eq "Shut down"}]
check "the critical action: the UPower default, Hybrid sleep, at 2 % (PercentageAction)" \
	[expr {[power::action_label [dict get $root critical]] eq "Hybrid sleep" && [dict get $root critical_pct] == 2}]
check "the charge limit: 80" [expr {[dict get $root charge_limit] eq "80"}]
file delete [file join $r sys class power_supply BAT0 charge_control_end_threshold]
check "no charge limit file gives no limit" [expr {[dict get [power::root] charge_limit] eq ""}]

# ---- changing a root setting through pkexec ribbon-power-helper (a stub pkexec runs the real helper on the fake root) ----------
# RIBBON_POWER_TEST, RIBBON_POWER_PKEXEC (the stub), RIBBON_POWER_HELPER, PKEXEC_LOG and PKEXEC_MODE come from the step.
proc slurp {f} { if {[catch {open $f} fh]} { return "" }; set t [read $fh]; close $fh; set t }
proc rwait {} {
	set t [clock milliseconds]
	while {$power::rbusy && [clock milliseconds] - $t < 8000} { update; after 10 }
	update
}
proc pklog {} { split [string trimright [slurp $::env(PKEXEC_LOG)] \n] \n }
proc setmode {m} { set fh [open $::env(PKEXEC_MODE) w]; puts $fh $m; close $fh }
proc dropin {} { slurp [file join $::env(RIBBON_POWER_ROOT) etc elogind logind.conf.d 50-ribbon-power.conf] }
proc upconf {} { slurp [file join $::env(RIBBON_POWER_ROOT) etc UPower UPower.conf] }

file mkdir [file join $r sys class power_supply BAT0]
foreach {f v} [list [file join $r sys class power_supply BAT0 type] Battery [file join $r sys class power_supply BAT0 charge_control_end_threshold] 100 \
	[file join $r etc UPower UPower.conf] "\[UPower\]\nPercentageLow=20\nPercentageCritical=5\nPercentageAction=2\nCriticalPowerAction=HybridSleep\n"] {
	set fh [open $f w]; puts $fh $v; close $fh
}
set pkexec_args $::env(PKEXEC_LOG)
setmode ok

power::root_set power_key ask; rwait
check "Ask: pkexec ran the helper with HandlePowerKey ignore" [expr {[lindex [pklog] end] eq "$::env(RIBBON_POWER_HELPER) set HandlePowerKey ignore"}]
check "Ask: logind's drop-in ignores the key" [expr {[string first "\[Login\]\nHandlePowerKey=ignore\n" [dropin]] >= 0}]
check "Ask: the page's file remembers it" [expr {[power::setting POWER_KEY_ASK] eq "yes"}]
check "Ask: the dropdown now reads Ask" [expr {[lindex [power::root_menu power_key] 1] eq "ask"}]
check "Ask: no error" [expr {$power::error eq ""}]

power::root_set power_key poweroff; rwait
check "Shut down: the drop-in says poweroff and Ask is off" [expr {[string match "*HandlePowerKey=poweroff*" [dropin]] && [power::setting POWER_KEY_ASK] eq "no"}]

set n [llength [pklog]]
power::root_set lid_pl screen; rwait
check "Turn off the screen (plugged in) when logind already ignores the lid: no pkexec" [expr {[llength [pklog]] == $n}]
check "Turn off the screen (plugged in): saved for the idle daemon" [expr {[power::setting LID_PL_SCREEN] eq "yes" && [lindex [power::root_menu lid_pl] 1] eq "screen"}]
power::root_set lid_pl suspend; rwait
check "Suspend (plugged in): the helper sets HandleLidSwitchExternalPower and the screen option goes off" \
	[expr {[string match "*HandleLidSwitchExternalPower=suspend*" [dropin]] && [power::setting LID_PL_SCREEN] eq "no"}]
power::root_set lid_bat screen; rwait
check "Turn off the screen (battery) sets logind to ignore the lid" \
	[expr {[string match "*HandleLidSwitch=ignore*" [dropin]] && [power::setting LID_BAT_SCREEN] eq "yes" && [lindex [power::root_menu lid_bat] 1] eq "screen"}]
check "the drop-in keeps the other keys" [expr {[string match "*HandlePowerKey=poweroff*" [dropin]] && [string match "*HandleLidSwitchExternalPower=suspend*" [dropin]]}]

power::root_set crit_act Hibernate; rwait
check "Critical level Hibernate sets CriticalPowerAction" [expr {[string match "*\nCriticalPowerAction=Hibernate\n*" [upconf]] && [dict get [power::root] critical] eq "Hibernate"}]
power::root_set crit_pct 5; rwait
check "Critical level 5% sets PercentageAction (and lifts PercentageCritical above it)" \
	[expr {[string match "*\nPercentageAction=5\n*" [upconf]] && [string match "*\nPercentageCritical=6\n*" [upconf]] && [dict get [power::root] critical_pct] == 5}]
power::root_set charge 80; rwait
check "Charge limit 80% reaches the battery's threshold file" [expr {[string trim [slurp [file join $r sys class power_supply BAT0 charge_control_end_threshold]]] eq "80"}]
check "Charge limit: the dropdown reads 80" [expr {[lindex [power::root_menu charge] 1] eq "80"}]

# a cancelled or refused pkexec leaves the row as it was, with a one-line error
set before [list [dropin] [upconf] [power::setting LID_BAT_SCREEN]]
setmode cancel
power::root_set lid_bat hibernate; rwait
check "a cancelled prompt says Cancelled" [expr {$power::error eq "Cancelled"}]
check "and changes nothing" [expr {[list [dropin] [upconf] [power::setting LID_BAT_SCREEN]] eq $before && [lindex [power::root_menu lid_bat] 1] eq "screen"}]
setmode deny
power::root_set charge 60; rwait
check "a failed authentication says Not authorised" [expr {$power::error eq "Not authorised"}]
check "and the charge limit is still 80" [expr {[string trim [slurp [file join $r sys class power_supply BAT0 charge_control_end_threshold]]] eq "80"}]
setmode ok
power::root_set crit_act Bogus; rwait
check "a value the helper refuses is one line, the helper's own" [expr {$power::error eq "'Bogus' is not allowed for CriticalPowerAction"}]
check "and the mirror is not changed by a refusal" [expr {[dict get [power::root] critical] eq "Hibernate"}]
power::root_set charge 70; rwait
check "after an error, the next change works and clears it" [expr {$power::error eq "" && [lindex [power::root_menu charge] 1] eq "70"}]
set saved $::env(RIBBON_POWER_PKEXEC)
set ::env(RIBBON_POWER_PKEXEC) /nonexistent/pkexec
power::root_set charge 90; rwait
check "no pkexec installed is one line" [expr {$power::error eq "pkexec is not installed"}]
set ::env(RIBBON_POWER_PKEXEC) $saved
set tf $::env(RIBBON_POWER_TEST); unset ::env(RIBBON_POWER_TEST)
check "without RIBBON_POWER_TEST the real pkexec and helper path are used" [expr {[power::helper_cmd] eq "pkexec /usr/bin/ribbon-power-helper"}]
set ::env(RIBBON_POWER_TEST) $tf
check "pkexec 126/127 and a long line" [expr {[power::helper_error "" 126] eq "Cancelled" && [power::helper_error "" 127] eq "Not authorised" \
	&& [string length [power::helper_error [string repeat x 200] 1]] == 70 && [power::helper_error "" 1] eq "The change failed"}]
set n [llength [pklog]]; set power::rbusy 1; power::root_set charge 60; set power::rbusy 0
check "a click while a helper runs is ignored (busy)" [expr {[llength [pklog]] == $n}]

# the lid and the screen (wlopm is a stub on PATH that logs its arguments)
power::conf_set LID_BAT_SCREEN yes
power::conf_set LID_PL_SCREEN no
check "lid closed on battery with the option on blanks the screen" [expr {[power::lid_step 1 1] eq "off"}]
check "and does it once" [expr {[power::lid_step 1 1] eq ""}]
check "opening the lid lights it" [expr {[power::lid_step 0 1] eq "on"}]
check "an open lid does nothing" [expr {[power::lid_step 0 1] eq ""}]
check "lid closed plugged in with that option off does nothing" [expr {[power::lid_step 1 0] eq ""}]
check "wlopm was called --off then --on with the output pattern *" [expr {[split [string trimright [slurp $::env(WLOPM_LOG)] \n] \n] eq {{--off *} {--on *}}}]
power::lid_step 1 1
power::conf_set LID_BAT_SCREEN no
check "turning the option off while closed lights the screen" [expr {[power::lid_step 1 1] eq "on"}]

# ---- the text of a failure ------------------------------------------------------------------------
set ::errorCode {DBUS org.freedesktop.DBus.Error.ServiceUnknown}
check "no UPower on the bus is named" [expr {[power::explain x org.freedesktop.UPower] eq "UPower is not running"}]
check "no power-profiles-daemon is named" [expr {[power::explain x net.hadess.PowerProfiles] eq "power-profiles-daemon is not running"}]
set ::errorCode NONE
check "other errors keep their text" [expr {[power::explain boom net.hadess.PowerProfiles] eq "boom"}]

# ---- the time text ------------------------------------------------------------------------------------
check "40 min" [expr {[power::left 2400] eq "40 min"}]
check "Fully charged" [expr {[power::time_text 4 0 0] eq "Fully charged"}]
check "1 h 0 min to full" [expr {[power::time_text 1 0 3600] eq "1 h 0 min to full"}]
check "a charging battery with no estimate says nothing" [expr {[power::time_text 1 0 0] eq ""}]

# ---- the stand-ins are read through the same path as the page -------------------------------------
check "a read with the stand-ins gives no error" [expr {[dict get [power::fetch] error] eq ""}]
# the swayidle stub is stopped with the test
if {[string is integer -strict [string trim [read [open [power::idle_pidfile]]]]]} { catch {exec kill [string trim [read [open [power::idle_pidfile]]]]} }

if {$fails} { puts "$fails check(s) failed"; exit 1 }
puts "all checks passed"
