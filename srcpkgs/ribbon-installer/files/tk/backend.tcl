# backend.tcl - the installer's only link to the machine, as set out in
# docs/INSTALLER-PROTOCOL.md: the probe (a dict on stdout), the answers
# file plus secrets on stdin, and progress lines back.
#
# The window runs as you; the probe and the install run as root through
# sudo (the live user has it without a password) or pkexec. Secrets only
# ever travel on the backend's stdin.
#
# Tests: RIBBON_INSTALLER_FAKE=script runs "script probe ..." and
# "script install ..." instead of the real commands, unprivileged.

namespace eval backend {
	variable probe {}
	variable ch ""
	variable buf ""
	variable answers ""
	variable onprobe ""
}

proc backend::priv {} {
	if {[info exists ::env(RIBBON_INSTALLER_FAKE)]} { return {} }
	if {![catch {exec id -u} uid] && $uid == 0} { return {} }
	if {[auto_execok sudo] ne "" && ![catch {exec sudo -n true 2>/dev/null}]} { return {sudo -n} }
	if {[auto_execok pkexec] ne ""} { return pkexec }
	return {sudo}
}

proc backend::cmd {what args} {
	if {[info exists ::env(RIBBON_INSTALLER_FAKE)]} {
		return [list sh $::env(RIBBON_INSTALLER_FAKE) $what {*}$args]
	}
	set exe [dict get {probe ribbon-install-probe install ribbon-install} $what]
	return [list {*}[priv] $exe {*}$args]
}

# Run the probe in the background; SCRIPT runs with the dict when it's in.
# When there is none (sudo or pkexec refused, or the probe failed) ONFAIL
# runs with why, in a sentence, and what the probe and its runner said.
proc backend::start_probe {script {onfail ""}} {
	variable onprobe $script
	variable onprobefail $onfail
	variable pbuf ""
	variable perr [file join [rundir] ribbon-installer-[pid]-[clock clicks].probe-err]
	if {[catch {open |[list {*}[cmd probe] 2> $perr] r} ch]} { probe_done "" 1 $ch; return }
	fconfigure $ch -blocking 0 -encoding utf-8
	fileevent $ch readable [list backend::probe_read $ch]
}

proc backend::probe_read {ch} {
	variable pbuf
	variable perr
	append pbuf [read $ch]
	if {![eof $ch]} return
	fconfigure $ch -blocking 1
	set rc 0
	if {[catch {close $ch} msg opts]} {
		set ec [dict get $opts -errorcode]
		set rc [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : 1}]
	}
	set said ""
	if {![catch {open $perr} fh]} { fconfigure $fh -encoding utf-8; set said [string trim [read $fh]]; close $fh }
	catch {file delete $perr}
	probe_done $pbuf $rc $said
}

# A refusal by sudo or pkexec (dismissed, not authorised, no password),
# or anything else that stopped the probe.
proc backend::probe_why {rc said} {
	if {$rc in {126 127} || [regexp -nocase {dismissed|not authori[sz]ed|password is required|incorrect password|authentication|not in the sudoers} $said]} {
		return "Permission to look at the disks and hardware was refused."
	}
	return "The check of the disks and hardware stopped."
}

proc backend::probe_done {text rc said} {
	variable probe
	variable onprobe
	variable onprobefail
	if {[catch {dict size $text}] || ![dict exists $text version]} {
		puts stderr "ribbon-installer: no probe (exit $rc): $said"
		set probe {version 1 machine {} disks {} drivers {}}
		if {$onprobefail ne ""} {
			if {$said eq ""} { set said [expr {[string trim $text] eq "" ? "The check ended with exit status $rc and said nothing." : "Its answer could not be read: [string range [string trim $text] 0 200]"}] }
			uplevel #0 [list {*}$onprobefail [probe_why $rc $said] $said]
			return
		}
	} else { set probe $text }
	uplevel #0 [list {*}$onprobe $probe]
}

# Stop the install (the window is closing): the backend, then its pipe,
# and the answers file (the backend read it when it started), as
# install_read does when the install ends.
proc backend::stop {} {
	variable ch
	variable answers_file
	if {$ch eq ""} return
	catch {exec kill -TERM {*}[pid $ch] 2>/dev/null}
	catch {close $ch}
	set ch ""
	if {[info exists answers_file]} { catch {file delete $answers_file} }
}

proc backend::rundir {} {
	expr {[info exists ::env(XDG_RUNTIME_DIR)] && [file isdirectory $::env(XDG_RUNTIME_DIR)] ? $::env(XDG_RUNTIME_DIR) : "/tmp"}
}

# Ask the backend whether the answers are complete and consistent:
# "" when they are, else its reason. Runs synchronously (it's quick).
proc backend::check {answers} {
	set f [write_answers $answers]
	set rc [catch {exec {*}[cmd probe --check-answers $f] 2>@1} out]
	file delete $f
	set out [string trim $out]
	if {[string match ok* $out]} { return "" }
	if {[regexp {^error\s+(.*)$} $out -> why]} { return $why }
	if {$rc} { return "The installer's check failed: [lindex [split $out \n] end]" }
	return ""
}

# A private file for the answers (0600, in the runtime dir).
proc backend::write_answers {answers} {
	set f [file join [rundir] ribbon-installer-[pid]-[clock clicks].answers]
	set fh [open $f {WRONLY CREAT EXCL} 0600]
	fconfigure $fh -encoding utf-8
	puts $fh $answers
	close $fh
	return $f
}

# Start the install: answers in a file, secrets on stdin (then closed),
# progress lines to LINECMD (called with each line).
proc backend::install {answers secrets linecmd} {
	variable ch
	variable answers_file
	variable online $linecmd
	set answers_file [write_answers $answers]
	if {[catch {open |[list {*}[cmd install --answers $answers_file --secrets-stdin --progress] 2>@1] r+} ch]} {
		uplevel #0 [list {*}$linecmd [list ERROR $ch]]
		return
	}
	fconfigure $ch -encoding utf-8 -buffering none
	puts -nonewline $ch $secrets
	flush $ch
	chan close $ch write
	fconfigure $ch -blocking 0 -buffering line
	fileevent $ch readable backend::install_read
}

proc backend::install_read {} {
	variable ch
	variable online
	variable answers_file
	while {[gets $ch line] >= 0} { uplevel #0 [list {*}$online $line] }
	if {![eof $ch]} return
	fconfigure $ch -blocking 1
	set err [catch {close $ch} msg]
	set ch ""
	catch {file delete $answers_file}
	uplevel #0 [list {*}$online [list EXIT [expr {$err ? 1 : 0}] $msg]]
}
