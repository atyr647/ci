# datetime.tcl - the logic of Settings → Date and time (no Tk): the time zone, whether the clock is set from the
# internet, setting the date and the time, the zone list, the calendar's month, and the display choices the bar reads.
# The page is page-datetime.tcl.
#
#   dt::start / dt::refresh          read the state (the time service's is asked for without blocking); dt::onchange
#                                    is called when something changed
#   dt::model                        zone abbr ntp_available ntp_on hour24 seconds date weekstart busy error subtitle
#   dt::zones                        every zone's name, sorted ("UTC" first), for the dropdown
#   dt::set_zone ZONE / dt::set_date Y M D / dt::set_time HH:MM / dt::set_ntp 0|1
#                                    through `pkexec ribbon-time-helper zone|set|ntp ...`; a refusal or a cancelled
#                                    prompt leaves the setting as it was and dt::error says why
#   dt::setting KEY / dt::conf_set KEY VALUE
#                                    the display choices, $XDG_CONFIG_HOME/ribbon/clock.conf (HOUR24=yes|no,
#                                    SECONDS=yes|no, DATE=yes|no, WEEKSTART=monday|sunday; written whole to a new file
#                                    and renamed over the old one). The shell's bar reads the file (shell/status.tcl)
#                                    and is told at once through its FIFO (the verb "clock").
#   dt::fmt SECS FORMAT, dt::time_text, dt::long_date, dt::date_text, dt::abbr
#                                    times in the system's zone
#   dt::month Y M WEEKSTART          the calendar: 42 cells {year month day in-this-month}
#
# Where things are read. The zone: the /etc/localtime link (the part after "zoneinfo/"), else /etc/timezone, else TZ,
# else the zone whose file /etc/localtime is a copy of. The zone list: /usr/share/zoneinfo/tzdata.zi (its Z and L
# lines), else zone1970.tab, else zone.tab, else the directory itself; of those, the names under the ten areas
# (Africa ... Pacific) whose file is there, and UTC. The time service: the first of chronyd, chrony, ntpd, openntpd, ntp
# that dinit has a description for (Ribbon ships chrony; its service is chronyd). It is on when `dinitctl status NAME`
# says STARTED or STARTING; when dinitctl cannot say (it answers only root on most systems), when it is enabled:
# /etc/dinit.d/boot.d/NAME, or, on a base whose packages ship runit services (/etc/sv: Void's), the runit-way link
# /var/service/NAME (ribbon-dinit's runit compatibility starts those). Without such a service there is nothing to switch
# and the model says ntp_available 0.
#
# This process after a zone change: nothing is cached and TZ is not touched. Every time shown is formatted with
# -timezone :ZONE, the zone read again from /etc/localtime, so the new zone shows on the next draw.
#
# Tests: with RIBBON_TIME_TEST set, RIBBON_TIME_ROOT (a directory that stands for /), RIBBON_TIME_PKEXEC and
# RIBBON_TIME_HELPER (in place of pkexec and /usr/bin/ribbon-time-helper) and RIBBON_TIME_DINITCTL (in place of
# dinitctl; without it the service is not asked) are read. Without RIBBON_TIME_TEST none of them is.

namespace eval dt {
	variable AREAS {Africa America Antarctica Arctic Asia Atlantic Australia Europe Indian Pacific}
	variable SERVICES {chronyd chrony ntpd openntpd ntp}
	variable DINITDIRS {etc/dinit.d usr/local/lib/dinit.d usr/lib/dinit.d run/dinit.d var/lib/ribbon/dinit.d}
	variable defaults [dict create HOUR24 yes SECONDS no DATE yes WEEKSTART monday]
	variable allowed [dict create HOUR24 {yes no} SECONDS {yes no} DATE {yes no} WEEKSTART {monday sunday}]
	variable zonelist {}     ;# dt::zones, once read
	variable zonesread 0
	variable copyof          ;# "mtime size" of an /etc/localtime that is a file -> the zone it is a copy of
	array set copyof {}
	variable tzok            ;# zone -> 1 when Tcl's clock knows it
	array set tzok {}
	variable service ""      ;# the time service's name, "" when there is none
	variable ntpon 0
	variable busy 0          ;# a helper is running
	variable error ""        ;# why the last change did not happen
	variable onchange ""
	variable seq 0           ;# counts state reads, so that an old answer is dropped
	variable out             ;# channel -> what it has said so far
	array set out {}
}

proc dt::test {} { expr {[info exists ::env(RIBBON_TIME_TEST)] && $::env(RIBBON_TIME_TEST) ne ""} }
proc dt::root {} {
	if {![test] || ![info exists ::env(RIBBON_TIME_ROOT)]} { return "" }
	string trimright $::env(RIBBON_TIME_ROOT) /
}
proc dt::now {} { clock seconds }
proc dt::changed {} {
	variable onchange
	if {$onchange ne ""} { catch {uplevel #0 $onchange} }
}

# ---- the display choices: clock.conf ---------------------------------------------------------------

proc dt::conf_file {} {
	set cfg [expr {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""
		? $::env(XDG_CONFIG_HOME) : [file join [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}] .config]}]
	file join $cfg ribbon clock.conf
}
proc dt::conf_lines {} {
	if {[catch {::open [conf_file]} fh]} { return {} }
	if {[catch {::read $fh 65536} t]} { set t "" }
	::close $fh
	if {$t eq ""} { return {} }
	split [string trimright $t \n] \n
}
# A choice: the file's last line for KEY, or its default when the file has none or a value that is not one.
proc dt::setting {key} {
	variable defaults; variable allowed
	set v [dict get $defaults $key]
	foreach line [conf_lines] {
		if {[regexp "^${key}=(.*)\$" $line -> x]} {
			set x [string trim $x]
			if {$x in [dict get $allowed $key]} { set v $x }
		}
	}
	return $v
}
# Save a choice (every other line of the file is kept) and tell the bar. 1 when it was saved.
proc dt::conf_set {key value} {
	variable allowed; variable error
	if {![dict exists $allowed $key] || $value ni [dict get $allowed $key]} { return 0 }
	set out {}
	set done 0
	foreach line [conf_lines] {
		if {[regexp "^${key}=" $line]} {
			if {!$done} { lappend out "$key=$value"; set done 1 }
			continue
		}
		lappend out $line
	}
	if {!$done} { lappend out "$key=$value" }
	set f [conf_file]
	set tmp [file join [file dirname $f] .clock.conf.[pid].[clock clicks]]
	if {[catch {
		file mkdir [file dirname $f]
		set fh [::open $tmp {WRONLY CREAT EXCL} 0644]
		puts $fh [join $out \n]
		::close $fh
		file rename -force -- $tmp $f
	} err]} {
		catch {::close $fh}
		catch {file delete -- $tmp}
		set error "The setting could not be saved"
		return 0
	}
	set error ""
	poke_shell
	return 1
}
# Tell the running shell that the clock's settings or the zone changed (its ctl FIFO, the verb "clock"). Never waits:
# no shell, no FIFO, a full pipe are all the same as not telling it (the bar looks at the files on its own tick too).
proc dt::poke_shell {} {
	set dir [expr {[info exists ::env(XDG_RUNTIME_DIR)] && $::env(XDG_RUNTIME_DIR) ne "" ? $::env(XDG_RUNTIME_DIR) : "/tmp"}]
	set f [file join $dir ribbon-shell]
	if {[catch {file type $f} t] || $t ne "fifo"} { return 0 }
	if {[catch {::open $f {WRONLY NONBLOCK}} ch]} { return 0 }
	catch {puts $ch clock}
	catch {::close $ch}
	return 1
}

# ---- zones -----------------------------------------------------------------------------------------

proc dt::zoneinfo {} { return [root]/usr/share/zoneinfo }
proc dt::valid_zone {z} {
	expr {[string length $z] <= 64 && [regexp {^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$} $z]}
}
proc dt::zones {} {
	variable zonelist; variable zonesread; variable AREAS
	if {$zonesread} { return $zonelist }
	set zi [zoneinfo]
	set names {}
	if {![catch {::open $zi/tzdata.zi} fh]} {
		if {![catch {::read $fh 4194304} text]} {
			foreach line [split $text \n] {
				switch -glob -- $line {
					"Z *" { lappend names [lindex [split $line] 1] }
					"L *" { lappend names [lindex [split $line] 2] }
				}
			}
		}
		::close $fh
	}
	foreach tab {zone1970.tab zone.tab} {
		if {[llength $names]} break
		if {[catch {::open $zi/$tab} fh]} continue
		if {![catch {::read $fh 4194304} text]} {
			foreach line [split $text \n] {
				if {[string index $line 0] eq "#"} continue
				set z [lindex [split $line \t] 2]
				if {$z ne ""} { lappend names $z }
			}
		}
		::close $fh
	}
	if {![llength $names]} {
		foreach area $AREAS {
			foreach pat {* */*} {
				foreach f [glob -nocomplain -directory $zi/$area -tails -types f $pat] { lappend names $area/$f }
			}
		}
	}
	set pat "^(?:[join $AREAS |])/"
	set list {}
	foreach z [lsort -unique $names] {
		if {[regexp $pat $z] && [valid_zone $z] && [file isfile $zi/$z]} { lappend list $z }
	}
	if {[file isfile $zi/UTC]} { set list [linsert $list 0 UTC] }
	set zonesread 1
	set zonelist $list
}

# The system's zone, "" when nothing says which it is.
proc dt::zone {} {
	variable copyof
	set lt [root]/etc/localtime
	if {![catch {file readlink $lt} target]} {
		if {[regexp {zoneinfo/(?:posix/|right/)?(.+)$} $target -> z] && [valid_zone $z]} { return $z }
	}
	if {![catch {::open [root]/etc/timezone} fh]} {
		if {[catch {::read $fh 256} t]} { set t "" }
		::close $fh
		set z [string trim [lindex [split $t \n] 0]]
		if {[valid_zone $z]} { return $z }
	}
	if {[info exists ::env(TZ)]} {
		set z [string trimleft $::env(TZ) :]
		if {[valid_zone $z] && [file isfile [zoneinfo]/$z]} { return $z }
	}
	# a copy of a zone's file: whose
	if {![catch {file stat $lt st}] && $st(type) eq "file" && $st(size) > 0 && $st(size) < 65536} {
		set sig "$st(mtime) $st(size)"
		if {![info exists copyof($sig)]} {
			set copyof($sig) ""
			set mine [slurp $lt]
			foreach z [zones] {
				set f [zoneinfo]/$z
				if {[catch {file size $f} n] || $n != $st(size)} continue
				if {[slurp $f] eq $mine} { set copyof($sig) $z; break }
			}
		}
		return $copyof($sig)
	}
	return ""
}
proc dt::slurp {f} {
	if {[catch {::open $f rb} fh]} { return "" }
	if {[catch {::read $fh 65536} t]} { set t "" }
	::close $fh
	return $t
}

# ---- times in the system's zone ----------------------------------------------------------------------

# What clock format takes as -timezone for the system's zone: ":Area/City", or "" (the process's own local time) when
# the zone is not known or Tcl has no rules for it.
proc dt::tz {} {
	variable tzok
	set z [zone]
	if {$z eq ""} { return "" }
	if {![info exists tzok($z)]} { set tzok($z) [expr {![catch {clock format 0 -timezone :$z}]}] }
	expr {$tzok($z) ? ":$z" : ""}
}
proc dt::fmt {secs format} {
	set tz [tz]
	if {$tz ne "" && ![catch {clock format $secs -format $format -timezone $tz} t]} { return $t }
	clock format $secs -format $format
}
proc dt::abbr {{secs ""}} {
	if {$secs eq ""} { set secs [now] }
	fmt $secs %Z
}
# 10:42, or 10:42 AM without the 24-hour clock.
proc dt::time_text {secs} {
	if {[setting HOUR24] eq "yes"} { return [fmt $secs %H:%M] }
	string trim [fmt $secs "%l:%M %p"]
}
proc dt::long_date {secs} { regsub -all {\s+} [string trim [fmt $secs "%A %e %B %Y"]] " " }
proc dt::date_text {secs} { regsub -all {\s+} [string trim [fmt $secs "%e %B %Y"]] " " }
# {year month day} of SECS, as numbers.
proc dt::ymd {secs} {
	lassign [fmt $secs "%Y %N %e"] y m d
	list $y [string trim $m] [string trim $d]
}

# ---- the calendar ----------------------------------------------------------------------------------------

# The six weeks that show month M of year Y: 42 cells {year month day in}, in = 1 for the month's own days.
proc dt::month {y m weekstart} {
	set first [clock scan [format %04d-%02d-01 $y $m] -format %Y-%m-%d -timezone :UTC]
	set dow [clock format $first -format %u -timezone :UTC]   ;# 1 Monday .. 7 Sunday
	set lead [expr {$weekstart eq "sunday" ? $dow % 7 : $dow - 1}]
	set jd [expr {[clock format $first -format %J -timezone :UTC] - $lead}]
	set cells {}
	for {set i 0} {$i < 42} {incr i} {
		set t [clock scan [expr {$jd + $i}] -format %J -timezone :UTC]
		lassign [clock format $t -format "%Y %N %e" -timezone :UTC] cy cm cd
		lappend cells [list $cy $cm $cd [expr {$cm == $m && $cy == $y}]]
	}
	return $cells
}
proc dt::weekdays {weekstart} { expr {$weekstart eq "sunday" ? {S M T W T F S} : {M T W T F S S}} }
proc dt::month_title {y m} {
	clock format [clock scan [format %04d-%02d-01 $y $m] -format %Y-%m-%d -timezone :UTC] -format "%B %Y" -timezone :UTC
}
# {year month} DELTA months from Y M.
proc dt::shift_month {y m delta} {
	set n [expr {$y * 12 + $m - 1 + $delta}]
	list [expr {$n / 12}] [expr {$n % 12 + 1}]
}
# {year month day} DELTA days from Y M D.
proc dt::shift_day {y m d delta} {
	set t [clock scan [format %04d-%02d-%02d $y $m $d] -format %Y-%m-%d -timezone :UTC]
	set jd [expr {[clock format $t -format %J -timezone :UTC] + $delta}]
	lassign [clock format [clock scan $jd -format %J -timezone :UTC] -format "%Y %N %e" -timezone :UTC] y m d
	list $y $m $d
}
proc dt::days_in {y m} {
	lassign [shift_month $y $m 1] ny nm
	lindex [shift_day $ny $nm 1 -1] 2
}

# ---- the time service --------------------------------------------------------------------------------------

proc dt::find_service {} {
	variable SERVICES; variable DINITDIRS
	foreach name $SERVICES {
		foreach dir $DINITDIRS {
			if {[file isfile [root]/$dir/$name]} { return $name }
		}
	}
	return ""
}
# Enabled: dinit's own mark, or the runit way where the base has runit services.
proc dt::marked {name} {
	set marks [list etc/dinit.d/boot.d/$name]
	if {[file isdirectory [root]/etc/sv]} { lappend marks var/service/$name etc/runit/runsvdir/default/$name }
	foreach f $marks {
		if {![catch {file lstat [root]/$f st}]} { return 1 }
	}
	return 0
}
proc dt::dinitctl {} {
	if {[test]} {
		return [expr {[info exists ::env(RIBBON_TIME_DINITCTL)] ? $::env(RIBBON_TIME_DINITCTL) : ""}]
	}
	lindex [auto_execok dinitctl] 0
}

# Run CMD (a list) without blocking; DONE gets the exit code and the output appended. 0 when it could not start.
proc dt::run {cmd done} {
	variable out
	if {[catch {::open "|[list {*}$cmd] </dev/null 2>@1" r} ch]} { return 0 }
	fconfigure $ch -blocking 0 -translation binary
	set out($ch) ""
	fileevent $ch readable [list dt::run_read $ch $done]
	return 1
}
proc dt::run_read {ch done} {
	variable out
	if {[catch {::read $ch} data]} { set data "" }
	append out($ch) $data
	if {![eof $ch]} return
	fileevent $ch readable {}
	set text $out($ch)
	unset out($ch)
	fconfigure $ch -blocking 1
	set code 0
	if {[catch {::close $ch} msg opts]} {
		set ec [dict get $opts -errorcode]
		set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : 1}]
	}
	uplevel #0 [list {*}$done $code [encoding convertfrom utf-8 $text]]
}

# Read the state: the service and its mark now, dinit's own word when it comes.
proc dt::refresh {} {
	variable service; variable ntpon; variable seq
	set service [find_service]
	set ntpon [expr {$service ne "" && [marked $service]}]
	incr seq
	if {$service eq ""} return
	set ctl [dinitctl]
	if {$ctl eq ""} return
	run [list $ctl status $service] [list dt::status_done $seq]
}
proc dt::start {} { refresh }
proc dt::status_done {n code text} {
	variable seq; variable ntpon
	if {$n != $seq || $code != 0} return
	if {![regexp -line {^\s*State:\s*([A-Z]+)} $text -> state]} return
	set on [expr {$state in {STARTED STARTING}}]
	if {$on != $ntpon} { set ntpon $on; changed }
}

# ---- changes: pkexec ribbon-time-helper ------------------------------------------------------------------

proc dt::helper_cmd {} {
	if {[test]} {
		set px [expr {[info exists ::env(RIBBON_TIME_PKEXEC)] && $::env(RIBBON_TIME_PKEXEC) ne "" ? $::env(RIBBON_TIME_PKEXEC) : "pkexec"}]
		set h [expr {[info exists ::env(RIBBON_TIME_HELPER)] && $::env(RIBBON_TIME_HELPER) ne "" ? $::env(RIBBON_TIME_HELPER) : "/usr/bin/ribbon-time-helper"}]
		return [list $px $h]
	}
	list pkexec /usr/bin/ribbon-time-helper
}
# One line for a failure: pkexec's 126 is a dialog that was dismissed or a refusal, 127 a failed authentication.
proc dt::helper_error {text code} {
	switch -- $code {
		126 { return "Cancelled" }
		127 { return "Not authorised" }
	}
	set line [string trim [lindex [split [string trim $text] \n] 0]]
	regsub {^ribbon-time-helper: } $line {} line
	if {$line eq ""} { set line "The change failed" }
	if {[string length $line] > 70} { set line "[string range $line 0 66]..." }
	return "[string toupper [string index $line 0]][string range $line 1 end]"
}
# Ask the helper; one at a time. 1 when it was started.
proc dt::helper {args} {
	variable busy; variable error
	if {$busy} { return 0 }
	set error ""
	if {![run [list {*}[helper_cmd] {*}$args] dt::helper_done]} {
		set error "pkexec is not installed"
		changed
		return 0
	}
	set busy 1
	return 1
}
proc dt::helper_done {code text} {
	variable busy 0
	variable error
	if {$code != 0} { set error [helper_error $text $code] } else { poke_shell }
	refresh
	changed
}

proc dt::set_zone {z} {
	if {![valid_zone $z] || $z eq [zone]} { return 0 }
	helper zone $z
}
# The clock is set by hand only when the internet does not set it.
proc dt::manual {} {
	variable service; variable ntpon
	expr {$service eq "" || !$ntpon}
}
# A new date, the time of day kept: the helper reads it when it sets the clock (after the password prompt, which may
# take a while), so the date goes alone.
proc dt::set_date {y m d} {
	if {![manual]} { return 0 }
	foreach v [list $y $m $d] { if {![string is integer -strict $v]} { return 0 } }
	if {$y < 2000 || $y > 2099 || $m < 1 || $m > 12 || $d < 1 || $d > [days_in $y $m]} { return 0 }
	helper set [format %04d-%02d-%02d $y $m $d]
}
# {hour minute} of what was typed (H:MM or HH:MM), {} when it is not a time.
proc dt::parse_time {text} {
	if {![regexp {^\s*(\d{1,2}):(\d{2})\s*$} $text -> h mi]} { return {} }
	scan $h %d h; scan $mi %d mi
	if {$h > 23 || $mi > 59} { return {} }
	list $h $mi
}
# A new time, the date kept.
proc dt::set_time {text} {
	if {![manual]} { return 0 }
	set hm [parse_time $text]
	if {$hm eq {}} { return 0 }
	helper set [fmt [now] %Y-%m-%d] [format %02d:%02d:00 {*}$hm]
}
proc dt::set_ntp {on} {
	variable service
	if {$service eq ""} { return 0 }
	helper ntp [expr {$on ? "on" : "off"}]
}

# ---- what the page draws -------------------------------------------------------------------------------------

proc dt::model {} {
	variable service; variable ntpon; variable busy; variable error
	set zone [zone]
	set abbr [abbr]
	set name [expr {$zone ne "" ? $zone : $abbr}]
	set on [expr {$service ne "" && $ntpon}]
	set sub [expr {$error ne "" ? $error : ($on ? "$name · set from the internet" : $name)}]
	dict create zone $zone name $name abbr $abbr ntp_available [expr {$service ne ""}] ntp_on $on \
		hour24 [expr {[setting HOUR24] eq "yes"}] seconds [expr {[setting SECONDS] eq "yes"}] \
		date [expr {[setting DATE] eq "yes"}] weekstart [setting WEEKSTART] busy $busy error $error subtitle $sub
}
