# printers.tcl - the logic of Settings → Printers (no Tk): CUPS's printers, the one this account prints to by default,
# each one's paper and two-sided printing for this account, its queue, the driverless printers on the network, and
# adding and removing printers. The page is page-printers.tcl.
#
#   prn::start / prn::refresh       read CUPS (lpstat, lpq, lpoptions); prn::onchange is called when something changed
#   prn::model                      available printers nearby scanning error subtitle
#                                   a printer (the default first, offline ones last): name label state (ready printing paused offline) default uri jobs
#                                     (a job: id file state (printing waiting)) paper papers sides sideses
#                                   a nearby printer: uri label (one not added yet)
#   prn::scan                       look for driverless printers (ippfind, in the background)
#   prn::set_default NAME           this account's default (lpoptions -d: ~/.cups/lpoptions)
#   prn::set_paper NAME SIZE / prn::set_sides NAME DUPLEX
#                                   this account's options for the printer (lpoptions -p NAME -o ...)
#   prn::cancel ID                  cancel a job (cancel ID: your own jobs; an admin's are CUPS's to allow)
#   prn::test_page NAME             print CUPS's test page on it (lp -d NAME testprint)
#   prn::add URI LABEL / prn::remove NAME
#                                   through `pkexec ribbon-printers-helper add NAME URI | remove NAME`, a driverless
#                                   queue (lpadmin -m everywhere); a refusal or a cancelled prompt changes nothing and
#                                   prn::error says why
#
# State. CUPS answers or it does not: with no lpstat, or a scheduler that is not running (lpstat -r), the model says
# available 0. The printers are the scheduler's queues (lpstat -p), not the network's printers CUPS could also reach.
# A printer is printing while lpstat -p says "now printing"; paused when it is disabled, offline when its state
# reasons say so (offline-report, or "Unable to locate" / "not responding" in lpstat's line). Its name is CUPS's
# printer-info, else the queue's name. The paper and the two-sided choices are the printer's own (lpoptions -l:
# PageSize and Duplex), the one marked * being in use.
#
# Tests: with RIBBON_PRINTERS_TEST set, RIBBON_PRINTERS_PKEXEC and RIBBON_PRINTERS_HELPER (in place of pkexec and
# /usr/bin/ribbon-printers-helper) and RIBBON_PRINTERS_TESTPAGE (CUPS's test page) are read; every other program is
# whatever PATH finds.

namespace eval prn {
	variable onchange ""
	variable error ""
	variable available 0
	variable printers {}       ;# the model's printers
	variable nearby {}         ;# {uri label} found by the last scan
	variable scanning 0
	variable scanfd ""
	variable scanbuf ""
	variable busy 0            ;# the helper is running
	variable TESTPAGE /usr/share/cups/data/testprint
}

proc prn::test {} { info exists ::env(RIBBON_PRINTERS_TEST) }
proc prn::pkexec {} { expr {[test] && [info exists ::env(RIBBON_PRINTERS_PKEXEC)] ? $::env(RIBBON_PRINTERS_PKEXEC) : "pkexec"} }
proc prn::helper {} { expr {[test] && [info exists ::env(RIBBON_PRINTERS_HELPER)] ? $::env(RIBBON_PRINTERS_HELPER) : "/usr/bin/ribbon-printers-helper"} }
proc prn::testpage {} {
	variable TESTPAGE
	expr {[test] && [info exists ::env(RIBBON_PRINTERS_TESTPAGE)] ? $::env(RIBBON_PRINTERS_TESTPAGE) : $TESTPAGE}
}
proc prn::notify {} {
	variable onchange
	if {$onchange ne ""} { uplevel #0 $onchange }
}
# A program's output (its own language: C), or "" and 0 in OK when it failed.
proc prn::run {okvar args} {
	upvar 1 $okvar ok
	set ok [expr {![catch {exec env LC_ALL=C {*}$args 2>/dev/null} out]}]
	if {!$ok} { set out "" }
	return $out
}

proc prn::start {} { refresh }

# lpoptions' line: key=value pairs, a value quoted with ' when it has spaces.
proc prn::options {text} {
	set d [dict create]
	foreach {- k v} [regexp -all -inline {([^\s=]+)=('[^']*'|\S*)} $text] {
		if {[string index $v 0] eq "'"} { set v [string range $v 1 end-1] }
		dict set d $k $v
	}
	return $d
}
# lpoptions -l: OPTION/Label: a *b c -> {choices {a b c} cur b} for each option asked for
proc prn::choices {text option} {
	foreach line [split $text \n] {
		if {[regexp "^[list $option]/\[^:\]*:\\s*(.*)$" $line -> rest]} {
			set ch {}; set cur ""
			foreach w $rest {
				if {[string index $w 0] eq "*"} { set w [string range $w 1 end]; set cur $w }
				lappend ch $w
			}
			return [dict create choices $ch cur $cur]
		}
	}
	return [dict create choices {} cur ""]
}

proc prn::refresh {} {
	variable available; variable printers; variable error
	# the scheduler: lpstat -r says whether it runs (and exits 0 either way)
	if {[run ok lpstat -r] ne "scheduler is running" || !$ok} {
		set available 0
		set printers {}
		notify
		return
	}
	set available 1
	# the queues: lpstat -p's (the scheduler's own; lpstat -e would add every driverless printer on the network as a
	# temporary destination). With none added it fails ("No destinations added.").
	set states [run ok lpstat -p]
	set names {}
	foreach line [split $states \n] { if {[regexp {^printer (\S+) } $line -> pn] && $pn ni $names} { lappend names $pn } }
	set devices [run ok lpstat -v]
	set def [run ok lpstat -d]
	set default ""
	regexp {destination:\s*(\S+)} $def -> default
	set ps {}
	foreach n $names {
		# the state: lpstat -p's line and the lines indented under it
		set state ready; set reason ""
		set in 0
		foreach line [split $states \n] {
			if {[regexp {^printer (\S+) (.*)$} $line -> pn rest]} {
				set in [expr {$pn eq $n}]
				if {$in} {
					if {[string match "now printing*" $rest]} { set state printing } elseif {[string match "disabled*" $rest]} { set state paused }
				}
			} elseif {$in} { append reason " " [string trim $line] }
		}
		set uri ""
		foreach line [split $devices \n] { if {[regexp {^device for ([^\s:]+):\s+(\S+)} $line -> dn du] && $dn eq $n} { set uri $du } }
		set o [options [run ok lpoptions -p $n]]
		set label [expr {[dict exists $o printer-info] && [dict get $o printer-info] ne "" ? [dict get $o printer-info] : $n}]
		set reasons [expr {[dict exists $o printer-state-reasons] ? [dict get $o printer-state-reasons] : ""}]
		if {[string match *offline* $reasons] || [regexp -nocase {unable to locate|not responding|unable to connect} $reason]} { set state offline }
		set l [run ok lpoptions -p $n -l]
		set pg [choices $l PageSize]
		set dx [choices $l Duplex]
		set p [dict create name $n label $label state $state default [expr {$n eq $default}] uri $uri jobs [jobs $n] \
			paper [dict get $pg cur] papers [dict get $pg choices] sides [dict get $dx cur] sideses [dict get $dx choices]]
		lappend ps $p
	}
	# the default first, the offline ones last, by name between
	set printers [lmap k [lsort -dictionary -index 0 [lmap p $ps {
		list "[expr {![dict get $p default]}][expr {[dict get $p state] eq "offline"}] [dict get $p label]" $p
	}]] { lindex $k 1 }]
	notify
}

# NAME's queue: lpq's lines under its heading (rank, owner, job, file(s), size).
proc prn::jobs {name} {
	set out [run ok lpq -P $name]
	set js {}
	foreach line [split $out \n] {
		if {[regexp {^(\S+)\s+(\S+)\s+(\d+)\s+(.*?)\s+\d+ bytes$} $line -> rank owner id file]} {
			lappend js [dict create id $id file [string trim $file] state [expr {$rank eq "active" ? "printing" : "waiting"}]]
		}
	}
	return $js
}

proc prn::label_of {state} { dict get {ready Ready printing Printing paused Paused offline Offline} $state }

proc prn::model {} {
	variable available; variable printers; variable nearby; variable scanning; variable error; variable busy
	# the nearby ones not added yet: their address is not a queue's
	set uris [lmap p $printers { dict get $p uri }]
	set near {}
	foreach n $nearby { if {[lindex $n 0] ni $uris} { lappend near [dict create uri [lindex $n 0] label [lindex $n 1]] } }
	set k [llength $printers]
	set sub [expr {!$available ? "Printing is not set up on this computer" : $k == 0 ? "No printers" : $k == 1 ? "1 printer" : "$k printers"}]
	if {$error ne ""} { set sub $error }
	dict create available $available printers $printers nearby $near scanning $scanning busy $busy error $error subtitle $sub
}

# ---- the network ------------------------------------------------------------------------------------------------

# Driverless printers (IPP Everywhere, AirPrint) the network announces: ippfind for 4 seconds, in the background.
proc prn::scan {} {
	variable scanning; variable scanfd; variable scanbuf
	if {$scanning} return
	if {[catch {open |[list env LC_ALL=C ippfind -T 4 _ipp._tcp,_print _ipps._tcp,_print --exec echo "{service_uri}\t{txt_ty}\t{service_name}" \; 2>/dev/null] r} fd]} return
	fconfigure $fd -blocking 0 -encoding utf-8
	set scanfd $fd; set scanbuf ""; set scanning 1
	fileevent $fd readable prn::scan_read
	notify
}
proc prn::scan_read {} {
	variable scanfd; variable scanbuf; variable scanning; variable nearby
	append scanbuf [read $scanfd]
	if {![eof $scanfd]} return
	catch { close $scanfd }
	set scanfd ""; set scanning 0
	set found {}
	foreach line [split $scanbuf \n] {
		lassign [split $line \t] uri ty sname
		if {![regexp {^ipps?://} $uri]} continue
		set label [expr {$ty ne "" ? $ty : $sname ne "" ? $sname : $uri}]
		if {[lsearch -index 0 $found $uri] < 0} { lappend found [list $uri $label] }
	}
	set nearby $found
	notify
}

# ---- changes --------------------------------------------------------------------------------------------------

proc prn::user {okmsg args} {
	variable error
	if {[catch {exec env LC_ALL=C {*}$args 2>@1} out]} {
		set error [expr {[string trim $out] ne "" ? [lindex [split [string trim $out] \n] 0] : $okmsg}]
		notify
		return 0
	}
	set error ""
	refresh
	return 1
}
proc prn::set_default {name} { user "Could not make $name the default" lpoptions -d $name }
proc prn::set_paper {name size} { user "Could not set the paper" lpoptions -p $name -o PageSize=$size }
proc prn::set_sides {name duplex} { user "Could not set two-sided printing" lpoptions -p $name -o Duplex=$duplex }
proc prn::cancel {id} {
	if {![string is digit -strict $id]} { return 0 }
	user "Could not cancel the job" cancel $id
}
proc prn::test_page {name} {
	if {![file readable [testpage]]} { return 0 }
	user "Could not print the test page" lp -d $name -t "Test page" [testpage]
}
proc prn::has_testpage {} { file readable [testpage] }

# A queue's name for a printer called LABEL: letters, digits, - and _, not one there is already.
proc prn::queue_name {label} {
	variable printers
	regsub -all {[^A-Za-z0-9_-]+} $label _ n
	set n [string trim $n _]
	if {$n eq ""} { set n Printer }
	set n [string range $n 0 60]
	set taken [lmap p $printers { dict get $p name }]
	set base $n; set k 2
	while {$n in $taken} { set n ${base}_$k; incr k }
	return $n
}

# The helper through pkexec, in the background: DONE is called with 1 or 0 (prn::error then says why; a dismissed
# prompt says nothing).
proc prn::privileged {args} {
	variable busy; variable error
	if {$busy} { return 0 }
	if {[catch {open |[list [pkexec] [helper] {*}$args 2>@1] r} fd]} {
		set error "Could not ask for permission"
		notify
		return 0
	}
	set busy 1
	fconfigure $fd -blocking 0
	fileevent $fd readable [list prn::privileged_read $fd ""]
	notify
	return 1
}
proc prn::privileged_read {fd buf} {
	variable busy; variable error
	append buf [read $fd]
	if {![eof $fd]} { fileevent $fd readable [list prn::privileged_read $fd $buf]; return }
	fconfigure $fd -blocking 1
	set code 0
	if {[catch {close $fd} msg opts]} {
		set code [lindex [dict get $opts -errorcode] 2]
		if {$code eq ""} { set code 1 }
	}
	set busy 0
	set line [string trim [lindex [split [string trim $buf] \n] end]]
	regsub {^ribbon-printers-helper: } $line "" line
	# 126: the prompt was dismissed (pkexec), 127: not authorised
	set error [expr {$code == 0 || $code == 126 ? "" : $code == 127 ? "Not allowed to change the printers" : $line ne "" ? $line : "The printer could not be changed"}]
	refresh
}
proc prn::add {uri label} {
	if {![regexp {^ipps?://[A-Za-z0-9._~:/%@-]+$} $uri]} { return 0 }
	privileged add [queue_name $label] $uri
}
proc prn::remove {name} {
	if {![regexp {^[A-Za-z0-9_-]+$} $name]} { return 0 }
	privileged remove $name
}
