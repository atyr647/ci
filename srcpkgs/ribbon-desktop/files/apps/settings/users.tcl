# users.tcl - the logic of Settings → Users, without Tk: who has an account here (read from /etc/passwd and
# /etc/group), and the changes, each of which is one run of `pkexec ribbon-users-helper VERB ...` (the helper's
# header has the security design). page-users.tcl draws from users::model and calls the actions.
#
#   users::start                       read the accounts, and look again every 2 s (another tool may change them)
#   users::model                       dict: users {LIST} wheel 0|1 nopass 0|1 me LOGIN
#                                        a user: login uid name (the full name, else the login) full (the GECOS full
#                                        name as it is) admin you nopass
#                                        wheel: there is a wheel group (no Administrator switch without one)
#                                        nopass: the login screen's PAM stack honours the group nopasswdlogin
#   users::onchange                    a script run when the model, users::error or users::busy changed
#   users::error                       one line about the last change that failed ("" when it worked or was cancelled)
#   users::busy                        a change is running (the password prompt is up): no second one is started
#
#   users::add LOGIN FULLNAME ADMIN PASSWORD ?DONE?     DONE gets STATUS (ok | cancelled | failed) and a message
#   users::remove LOGIN KEEPHOME ?DONE?
#   users::rename LOGIN FULLNAME ?DONE?
#   users::set_admin LOGIN ON ?DONE?
#   users::set_nopass LOGIN ON ?DONE?
#   users::set_password LOGIN NEW CURRENT ?DONE?        your own: passwd(1) run as you, which checks CURRENT (PAM);
#                                                       someone else's: the helper, after an administrator's password
#   users::valid_login NAME / users::login_free NAME / users::suggest_login FULLNAME / users::clean_name TEXT
#   users::removable LOGIN             "" when the account may be removed, else why not (you | admin)
#   users::last_admin LOGIN            LOGIN is the only administrator
#
# A password is never put in a command line, the environment or a file: it is written to the program's standard
# input (the helper's, or passwd's) and the variable that held it is overwritten. The helper refuses whatever this
# file would refuse, and more; the checks here only save a pointless password prompt.
#
# Robustness: a file that is missing, unreadable or damaged gives an empty (or shorter) list, never an error; no
# pkexec gives users::error. Nothing here blocks: the helper runs on a pipe with a fileevent.
#
# Tests: RIBBON_USERS_ROOT stands for / when reading (reading needs no rights, so this is always honoured). With
# RIBBON_USERS_TEST set, RIBBON_USERS_PKEXEC, RIBBON_USERS_HELPER and RIBBON_USERS_PASSWD replace pkexec, the helper
# and passwd, and RIBBON_USERS_UID says who "you" are; without it they are not read.

namespace eval users {
	variable M [dict create users {} wheel 0 nopass 0 me ""]
	variable onchange ""
	variable error ""
	variable busy 0
	variable stamp ""       ;# the files' sizes and times at the last read
	variable started 0
	variable UID_MIN 1000
	variable UID_MAX 59999
}

proc users::root {} {
	expr {[info exists ::env(RIBBON_USERS_ROOT)] ? [string trimright $::env(RIBBON_USERS_ROOT) /] : ""}
}
proc users::testing {} { expr {[info exists ::env(RIBBON_USERS_TEST)] && $::env(RIBBON_USERS_TEST) ne ""} }
proc users::testvar {name default} {
	expr {[testing] && [info exists ::env($name)] && $::env($name) ne "" ? $::env($name) : $default}
}

# A plain file of at most MAX bytes as text; "" when it cannot be read.
proc users::slurp {file {max 4000000}} {
	if {[catch {
		if {![file isfile $file] || [file size $file] > $max} { error skip }
		set f [::open $file rb]
		set t [::read $f]
		::close $f
	}]} { catch {::close $f}; return "" }
	encoding convertfrom utf-8 $t
}

# Your uid, from the kernel (the environment's USER is whatever someone set).
proc users::myuid {} {
	set t [testvar RIBBON_USERS_UID ""]
	if {[string is integer -strict $t]} { return $t }
	if {[regexp -line {^Uid:\s+(\d+)} [slurp /proc/self/status 100000] -> u]} { return $u }
	if {![catch {exec id -u} u] && [string is integer -strict $u]} { return $u }
	return -1
}

# ---- reading --------------------------------------------------------------------------------------

# /etc/passwd's text as a list of dicts (login uid gid gecos shell); lines that are not accounts are skipped.
proc users::parse_passwd {text} {
	set out {}
	foreach line [split $text \n] {
		set f [split $line :]
		if {[llength $f] < 7} continue
		lassign $f login - uid gid gecos - shell
		if {$login eq "" || ![regexp {^\d{1,9}$} $uid] || ![regexp {^\d{1,9}$} $gid]} continue
		lappend out [dict create login $login uid [::scan $uid %d] gid [::scan $gid %d] gecos $gecos shell $shell]
	}
	return $out
}
# /etc/group's text as a dict: name -> {gid members}.
proc users::parse_group {text} {
	set out [dict create]
	foreach line [split $text \n] {
		set f [split $line :]
		if {[llength $f] < 4} continue
		lassign $f name - gid members
		if {$name eq "" || ![regexp {^\d{1,9}$} $gid] || [dict exists $out $name]} continue
		dict set out $name [list [::scan $gid %d] [lsearch -all -inline -not -exact [split $members ,] ""]]
	}
	return $out
}
# A person's account: a uid in 1000..59999 and a shell one can log in with.
proc users::human {a} {
	variable UID_MIN; variable UID_MAX
	set uid [dict get $a uid]
	if {$uid < $UID_MIN || $uid > $UID_MAX} { return 0 }
	expr {[file tail [dict get $a shell]] ni {nologin false sync halt shutdown}}
}
proc users::in_group {groups a name} {
	if {![dict exists $groups $name]} { return 0 }
	lassign [dict get $groups $name] gid members
	expr {[dict get $a login] in $members || [dict get $a gid] == $gid}
}
# The login screen honours nopasswdlogin: its PAM file has a pam_succeed_if line for the group that is not a comment.
proc users::pam_nopass {text} {
	foreach line [split $text \n] {
		set line [string trim $line]
		if {[string index $line 0] eq "#"} continue
		if {[regexp {^auth\s+\S.*pam_succeed_if\.so\s.*\yingroup\s+nopasswdlogin\y} $line]} { return 1 }
	}
	return 0
}
proc users::files {} {
	set r [root]
	list $r/etc/passwd $r/etc/group $r/etc/pam.d/greetd
}
proc users::stamp_now {} {
	set s {}
	foreach f [files] {
		if {[catch {file stat $f st}]} { lappend s - } else { lappend s $st(mtime),$st(size),$st(ino) }
	}
	return $s
}
# Read the files into the model. Returns 1 when the model changed.
proc users::refresh {} {
	variable M; variable stamp
	lassign [files] fp fg fpam
	set stamp [stamp_now]
	set groups [parse_group [slurp $fg]]
	set me [myuid]
	set list {}
	set mine ""
	foreach a [parse_passwd [slurp $fp]] {
		if {![human $a]} continue
		set login [dict get $a login]
		set full [string trim [lindex [split [dict get $a gecos] ,] 0]]
		set you [expr {[dict get $a uid] == $me}]
		if {$you} { set mine $login }
		lappend list [dict create login $login uid [dict get $a uid] name [expr {$full ne "" ? $full : $login}] full $full \
			admin [in_group $groups $a wheel] you $you \
			nopass [expr {[dict exists $groups nopasswdlogin] && $login in [lindex [dict get $groups nopasswdlogin] 1]}]]
	}
	set new [dict create users [lsort -integer -index 3 $list] wheel [dict exists $groups wheel] nopass [pam_nopass [slurp $fpam 200000]] me $mine]
	set names [dict create]
	foreach a [parse_passwd [slurp $fp]] { dict set names [dict get $a login] 1 }
	foreach g [dict keys $groups] { dict set names $g 1 }
	variable taken $names
	if {$new eq $M} { return 0 }
	set M $new
	return 1
}
proc users::model {} { variable M; return $M }
proc users::user {login} {
	variable M
	foreach u [dict get $M users] { if {[dict get $u login] eq $login} { return $u } }
	return ""
}
proc users::changed {} {
	variable onchange
	if {$onchange ne ""} { uplevel #0 $onchange }
}
proc users::start {} {
	variable started
	refresh
	if {$started} return
	set started 1
	after 2000 users::tick
}
proc users::tick {} {
	variable stamp
	after 2000 users::tick
	if {[stamp_now] ne $stamp && [refresh]} { changed }
}

# ---- names ----------------------------------------------------------------------------------------

proc users::valid_login {name} { regexp {^[a-z_][a-z0-9_-]{0,31}$} $name }
# No user and no group has the name (useradd makes both), and it is not one the helper keeps for the system.
proc users::login_free {name} {
	variable taken
	if {$name in {wheel nopasswdlogin}} { return 0 }
	expr {![info exists taken] || ![dict exists $taken $name]}
}
# The user name offered for a full name: its first word in small letters ("Jonas Lindqvist" -> jonas).
proc users::suggest_login {full} {
	set w [string tolower [lindex [regexp -inline {\S+} [string trim $full]] 0]]
	set w [string map {ä a å a á a à a â a ã a ö o ø o ó o ò o ô o õ o ü u ú u ù u û u é e è e ê e ë e í i ì i î i ï i ñ n ç c ß ss ł l ś s ź z ż z ć c ń n ę e ą a š s č c ž z ř r ý y} $w]
	regsub -all {[^a-z0-9_-]} $w "" w
	regsub {^[^a-z_]+} $w "" w
	string range $w 0 31
}
# A full name as the helper will store it: no ":" "," or control characters, trimmed.
proc users::clean_name {text} {
	regsub -all {[:,[:cntrl:]]} $text "" text
	string trim $text
}
proc users::admins {} {
	variable M
	set n 0
	foreach u [dict get $M users] { if {[dict get $u admin]} { incr n } }
	return $n
}
proc users::last_admin {login} {
	set u [user $login]
	expr {$u ne "" && [dict get $u admin] && [admins] <= 1}
}
proc users::removable {login} {
	set u [user $login]
	if {$u eq ""} { return gone }
	if {[dict get $u you]} { return you }
	if {[last_admin $login]} { return admin }
	return ""
}

# ---- running the helper ---------------------------------------------------------------------------

proc users::helper_cmd {} {
	list [testvar RIBBON_USERS_PKEXEC pkexec] [testvar RIBBON_USERS_HELPER /usr/bin/ribbon-users-helper]
}
proc users::passwd_cmd {} {
	set p [testvar RIBBON_USERS_PASSWD ""]
	if {$p eq ""} { foreach c {/usr/bin/passwd /bin/passwd} { if {[file executable $c]} { set p $c; break } } }
	return $p
}
# Overwrite a variable that held a password, and forget it. (Tcl may keep other copies of a value it has handed
# around; this drops ours.)
proc users::wipe {name} {
	upvar 1 $name v
	if {[info exists v]} { set v [string repeat x [string length $v]]; unset v }
}

# One line for the helper's failure. 126: the prompt was dismissed (nothing to say); 127: not authorised.
proc users::helper_error {code out} {
	switch -- $code {
		126 { return "" }
		127 { return "Not authorised" }
	}
	set line ""
	foreach l [split $out \n] { if {[regexp {^ribbon-users-helper: (.+)$} [string trim $l] -> line]} break }
	if {$line eq ""} { return "The change failed" }
	nice $line
}
# A line for the page: its first letter a capital unless it is a login name, cut to 80.
proc users::nice {line} {
	set first [lindex [split $line " "] 0]
	if {[user $first] eq ""} { set line [string toupper [string index $line 0]][string range $line 1 end] }
	if {[string length $line] > 80} { set line "[string range $line 0 78]…" }
	return $line
}
# One line for passwd(1)'s failure, from what it printed (in the C locale).
proc users::passwd_error {out} {
	regsub -all {(Current|New|Retype new|Old|Re-enter new|Enter new|Retype)[^:\n]{0,24}[Pp]assword: ?} $out "\n" out
	set told ""
	foreach l [split $out \n] {
		set l [string trim $l]
		if {$l eq "" || [regexp {^(Changing password for|passwd: |\(current\))} $l]} continue
		regsub {^BAD PASSWORD: } $l "" l
		set told $l
		break
	}
	if {$told ne ""} { return [nice [string trimright $told .]] }
	if {[regexp {Authentication (token manipulation error|failure)} $out]} { return "The current password is not right" }
	return "The password was not changed"
}

# Run CMD on a pipe without blocking: INPUT is written to its standard input, which is then closed; DONE gets the
# exit code and everything it printed. A program that cannot be started gives -1 and Tcl's message.
proc users::spawn {cmd input done} {
	if {[catch {::open "|[list {*}$cmd 2>@1]" r+} ch]} {
		wipe input
		after 0 [list {*}$done -1 $ch]
		return
	}
	fconfigure $ch -blocking 0 -translation binary -buffering none
	catch {
		puts -nonewline $ch [encoding convertto utf-8 $input]
		flush $ch
		::close $ch write
	}
	wipe input
	set ::users::out($ch) ""
	fileevent $ch readable [list users::spawn_read $ch $done]
}
proc users::spawn_read {ch done} {
	variable out
	append out($ch) [::read $ch]
	if {![eof $ch]} return
	fileevent $ch readable {}
	set text [encoding convertfrom utf-8 $out($ch)]
	unset out($ch)
	fconfigure $ch -blocking 1
	set code 0
	if {[catch {::close $ch} msg opts]} {
		set ec [dict get $opts -errorcode]
		set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : 1}]
	}
	{*}$done $code $text
}

# The helper for VERB ARGS (SECRET on its standard input). One at a time.
proc users::call {done secret verb args} {
	variable busy; variable error
	if {$busy} { wipe secret; return }
	set busy 1
	set error ""
	spawn [list {*}[helper_cmd] $verb {*}$args] $secret [list users::finish helper $done]
	wipe secret
	changed
}
proc users::finish {kind done code out} {
	variable busy 0
	variable error
	if {$code == 0} {
		set status ok; set msg ""
	} elseif {$kind eq "passwd"} {
		set status failed
		set msg [expr {$code == -1 ? "passwd is not installed" : [passwd_error $out]}]
	} elseif {$code == -1} {
		set status failed; set msg "pkexec is not installed"
	} else {
		set msg [helper_error $code $out]
		set status [expr {$code == 126 ? "cancelled" : "failed"}]
	}
	set error $msg
	refresh
	if {$done ne ""} { uplevel #0 [list {*}$done $status $msg] }
	changed
}

# ---- the changes ----------------------------------------------------------------------------------

# A full name as the helper's argument. Tcl's open reads a word that starts with <, >, 2>, | or is & as a redirection
# (">x" would truncate the file x); such a name gets a leading space, which the helper trims.
proc users::name_arg {full} {
	set full [clean_name $full]
	if {[regexp {^([<>|&]|2>)} $full]} { set full " $full" }
	return $full
}
proc users::add {login full admin password {done ""}} {
	set secret "$login\n$password\n"
	wipe password
	call $done $secret add $login [expr {$admin ? "on" : "off"}] [name_arg $full]
	wipe secret
}
proc users::remove {login keep {done ""}} { call $done "" remove $login [expr {$keep ? "keep" : "delete"}] }
proc users::rename {login full {done ""}} { call $done "" rename $login [name_arg $full] }
# The last administrator keeps the right (the helper refuses it too; this saves the password prompt).
proc users::set_admin {login on {done ""}} {
	variable busy; variable error
	if {!$on && !$busy && [last_admin $login]} {
		set error "$login is the only administrator"
		if {$done ne ""} { uplevel #0 [list {*}$done failed $error] }
		changed
		return
	}
	call $done "" admin $login [expr {$on ? "on" : "off"}]
}
proc users::set_nopass {login on {done ""}} { call $done "" nopass $login [expr {$on ? "on" : "off"}] }
proc users::set_password {login new current {done ""}} {
	variable busy; variable error
	set u [user $login]
	if {$u eq "" || ![dict get $u you]} {
		wipe current
		set secret "$login\n$new\n"
		wipe new
		call $done $secret passwd $login
		wipe secret
		return
	}
	# your own: passwd asks for the current password, then the new one twice
	if {$busy} { wipe new; wipe current; return }
	set p [passwd_cmd]
	set secret "$current\n$new\n$new\n"
	wipe new; wipe current
	set busy 1
	set error ""
	if {$p eq "" || ![file executable $p]} {
		wipe secret
		after 0 [list users::finish passwd $done -1 ""]
	} else {
		spawn [list /usr/bin/env LC_ALL=C LANGUAGE=C $p] $secret [list users::finish passwd $done]
		wipe secret
	}
	changed
}
