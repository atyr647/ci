# kit-updater's check of the system's own packages (lib/updater.tcl, ::kit::updater::systemCheck): the updater runs
# `ribbon-update --tcl` as the user each cycle, so the bar's chip and Settings' rail count the system's packages without
# a panel opened first. Stand-ins for ribbon-update (KIT_RIBBON_UPDATE) say what it answers; the check logs one line.
# Needs no Mk4tcl, network or root: only updater.tcl and the few kit procs it uses.
set top [file dirname [file dirname [file normalize [info script]]]]
namespace eval ::kit {}
proc ::kit::env {name {default ""}} { if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) }; return $default }
source -encoding utf-8 $top/srcpkgs/ribbon-kit/files/lib/updater.tcl

set fails 0
proc ok {what cond {detail ""}} {
	global fails
	if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what $detail"; incr fails }
}
set tmp [file normalize [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]]
set dir [file join $tmp kit-updater-system-[pid]]
file mkdir $dir
proc stub {name body} {
	global dir
	set f [file join $dir $name]
	set fh [open $f w]; puts $fh "#!/bin/sh\n$body"; close $fh
	file attributes $f -permissions 0755
	return $f
}
# the log goes to stderr: capture it through a channel redirect of the proc that writes it
set logged {}
rename ::kit::updater::log ::kit::updater::log_real
proc ::kit::updater::log {msg} { global logged; lappend logged $msg }
proc check {exe} {
	global logged
	set logged {}
	set ::env(KIT_RIBBON_UPDATE) $exe
	::kit::updater::systemCheck
	return $logged
}

set plan {plan {rows {{name foo short foo old 1 new 2 action update bytes 10 tags {} note {}} {name bar short bar old {} new 3 action install bytes {} tags restart note {}}} question {Install 1 and update 1? (takes effect at restart)} checked 1}}
set r [check [stub plan "echo '$plan'"]]
ok "a plan: the log says how many packages wait" {$r eq {{system packages: 2 waiting}}} $r
set r [check [stub uptodate "echo 'Up to date'"]]
ok "up to date: said as ribbon-update says it" {$r eq {{system packages: Up to date}}} $r
set r [check [stub none "echo 'Nothing to update outside kit'"]]
ok "a base with no package manager of its own: said, not an error" {$r eq {{system packages: Nothing to update outside kit}}} $r
set r [check [stub failing "echo 'ribbon-update: cannot reach the repository' >&2; exit 1"]]
ok "the package manager failing costs this cycle only: the reason is logged, nothing raised" {$r eq {{system packages: not checked (ribbon-update: cannot reach the repository)}}} $r
set r [check [stub silent "exit 1"]]
ok "a failure with no words still says so" {$r eq {{system packages: not checked (ribbon-update failed)}}} $r
set r [check [stub args "case \"\$*\" in --tcl) echo 'Up to date';; *) echo \"wrong arguments: \$*\"; exit 1;; esac"]]
ok "it asks for the plan only (--tcl, never --yes): nothing is installed by the updater" {$r eq {{system packages: Up to date}}} $r
set r [check [stub stdin "cat >/dev/null; echo 'Up to date'"]]
ok "it gives the command no terminal input (a package manager never waits on the service's stdin)" {$r eq {{system packages: Up to date}}} $r
unset -nocomplain ::env(KIT_RIBBON_UPDATE)
set ::env(PATH) $dir
set r [check ""]
ok "ribbon-update missing from PATH: nothing logged, nothing raised" {$r eq {}} $r
file delete -force $dir
if {$fails} { puts "$fails failed"; exit 1 }
puts "all kit-updater system checks passed"
