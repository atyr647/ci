# settings-users.tcl - apps/settings/users.tcl (the logic of Settings → Users) without a display: reading /etc/passwd
# and /etc/group under a fake root (RIBBON_USERS_ROOT), the names, and each change as the one helper call it makes,
# with a stand-in pkexec that records its arguments, environment and standard input (the password is in the standard
# input only). Then the whole chain: users.tcl → the stand-in pkexec → the real ribbon-users-helper on the fake root
# → stand-in shadow tools, and your own password through a stand-in passwd.
#   tclsh8.6 tests/settings-users.tcl FILES-DIR
# Prints one line per check; exits 1 if any failed.
encoding system utf-8
set D [file normalize [lindex $argv 0]]
set fails 0
set count 0
proc check {what ok} {
	global fails count
	incr count
	if {[uplevel 1 [list expr $ok]]} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}
proc slurp {f} { if {[catch {open $f rb} fh]} { return "" }; set t [read $fh]; close $fh; encoding convertfrom utf-8 $t }
proc spit {f t} { file mkdir [file dirname $f]; set fh [open $f wb]; puts -nonewline $fh [encoding convertto utf-8 $t]; close $fh }
proc exe {f t} { spit $f $t; file attributes $f -permissions 0755 }

set me [exec id -u]
set T ""
foreach base [list [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] /tmp /var/tmp] {
	set d [file normalize [file join $base us-[pid]-[clock milliseconds]]]
	if {[catch {file mkdir $d}]} continue
	file attributes $d -permissions 0755
	set T $d; break
}
set R $T/root
proc fixture {{wheel "wheel:x:10:adam\n"} {extra ""} {pam ""}} {
	global R
	file delete -force $R
	spit $R/etc/passwd "root:x:0:0:root:/root:/bin/bash\ndaemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\nmira:x:1001:1001:Mira,Room 1,555:/home/mira:/bin/bash\nadam:x:1000:1000:Adam:/home/adam:/bin/bash\nguest:x:1002:1002::/home/guest:/bin/sh\nsvc:x:1003:1003:A service:/var/svc:/usr/sbin/nologin\nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n$extra"
	spit $R/etc/group "root:x:0:\n${wheel}adam:x:1000:\nmira:x:1001:\nguest:x:1002:\naudio:x:29:adam\n"
	if {$pam ne ""} { spit $R/etc/pam.d/greetd $pam }
}
set env(RIBBON_USERS_ROOT) $R
set env(RIBBON_USERS_TEST) 1
set env(RIBBON_USERS_UID) 1000
source -encoding utf-8 $D/apps/settings/users.tcl

# ---- reading ----------------------------------------------------------------------------------
fixture
users::refresh
set m [users::model]
check "people only: uid 1000..59999 with a login shell, in uid order" {[lmap u [dict get $m users] { dict get $u login }] eq {adam mira guest}}
check "the name is the GECOS full name, else the login" {[lmap u [dict get $m users] { dict get $u name }] eq {Adam Mira guest}}
check "an administrator is a member of wheel" {[lmap u [dict get $m users] { dict get $u admin }] eq {1 0 0}}
check "you are the account with your uid" {[dict get $m me] eq "adam" && [dict get [users::user adam] you] && ![dict get [users::user mira] you]}
check "there is a wheel group; the login screen does not honour nopasswdlogin" {[dict get $m wheel] && ![dict get $m nopass]}
fixture "wheel:x:10:\n" "pat:x:1004:10:Pat Lee:/home/pat:/bin/zsh\n"
users::refresh
check "wheel as someone's own group makes them an administrator" {[dict get [users::user pat] admin] && ![dict get [users::user adam] admin]}
fixture ""
users::refresh
check "no wheel group: nobody is an administrator, and the model says so" {![dict get [users::model] wheel] && [users::admins] == 0}
fixture "wheel:x:10:adam\nnopasswdlogin:x:990:guest\n" "" "#%PAM-1.0\nauth sufficient pam_succeed_if.so user ingroup nopasswdlogin\nauth include system-login\n"
users::refresh
check "nopasswdlogin's members, and a PAM stack that honours the group" {[dict get [users::model] nopass] && [dict get [users::user guest] nopass] && ![dict get [users::user adam] nopass]}
check "a commented PAM line does not count" {![users::pam_nopass "# auth sufficient pam_succeed_if.so user ingroup nopasswdlogin\n"]}
check "another group's line does not count" {![users::pam_nopass "auth sufficient pam_succeed_if.so user ingroup wheel\n"]}
spit $R/etc/passwd "garbage\n::::::\nadam:x:1000:1000:Adam:/home/adam:/bin/bash\nbad:x:12x:5::/:/bin/sh\nhuge:x:99999999999999999999:5::/:/bin/sh\n\xff\xfe:x:1005:1005::/:/bin/sh\nshort:x:1006\n"
check "a damaged passwd file: the good lines are read, nothing throws" {![catch {users::refresh}] && "adam" in [lmap u [dict get [users::model] users] { dict get $u login }] && "bad" ni [lmap u [dict get [users::model] users] { dict get $u login }]}
file delete $R/etc/passwd $R/etc/group
check "no passwd and no group file: an empty list" {![catch {users::refresh}] && [dict get [users::model] users] eq {} && ![dict get [users::model] wheel]}
file mkdir $R/etc/passwd
check "passwd is a directory: an empty list" {![catch {users::refresh}] && [dict get [users::model] users] eq {}}
unset env(RIBBON_USERS_UID)
check "your uid comes from the kernel" {[users::myuid] == $me}
set env(RIBBON_USERS_UID) 1000

# ---- names ------------------------------------------------------------------------------------
fixture; users::refresh
foreach {full want} {"Jonas Lindqvist" jonas "  Alex Tyrone " alex "Zoë Łukasiewicz" zoe "42 Marvin" marvin... "O'Brien Pat" obrien "" "" "李 雷" "" "Jean-Luc P" jean-luc "_svc x" _svc} {
	if {$want eq "marvin..."} { set want "" }
	check "the user name offered for [list $full] is [list $want]" {[users::suggest_login $full] eq $want}
}
check "a long first word is cut to 32" {[string length [users::suggest_login [string repeat a 40]]] == 32}
foreach n {jonas _x a-b a_b9 a} { check "a user name: $n" {[users::valid_login $n]} }
foreach n {"" Jonas 9a -a "a b" a:b "a;b" {$(x)} "a\nb" ä a.b} { check "not a user name: [string map [list \n {\n}] [list $n]]" {![users::valid_login $n]} }
check "33 letters are not a user name" {![users::valid_login [string repeat a 33]] && [users::valid_login [string repeat a 32]]}
check "a name is free unless a user or a group has it" {[users::login_free jonas] && ![users::login_free mira] && ![users::login_free audio] && ![users::login_free daemon]}
check "nopasswdlogin and wheel are never free (the helper keeps them for the system)" {![users::login_free nopasswdlogin] && ![users::login_free wheel]}
check "a full name loses : , and control characters" {[users::clean_name "  Jo:nas,\x01 L\n "] eq "Jonas L"}
check "Remove is not for you" {[users::removable adam] eq "you"}
check "  nor for the only administrator" {[users::last_admin adam] && [users::removable mira] eq ""}

# ---- each change is one helper call; the password goes to its standard input only ---------------
set PW {tr0ub4dor&3 "x" $(id) ; :c łódź}
exe $T/pkexec [string map [list @T@ $T] {#!/bin/sh
{ printf 'pkexec'; for a in "$@"; do printf '\037%s' "$a"; done; printf '\n'; } >>'@T@/px.argv'
env >'@T@/px.env'
cat >'@T@/px.stdin'
[ -r '@T@/px.out' ] && cat '@T@/px.out' >&2
read -r rc <'@T@/px.rc' 2>/dev/null || rc=0
exit "$rc"
}]
set env(RIBBON_USERS_PKEXEC) $T/pkexec
set env(RIBBON_USERS_HELPER) /usr/bin/ribbon-users-helper
proc calls {} { global T; lmap l [split [string trimright [slurp $T/px.argv] \n] \n] { lrange [split $l \x1f] 1 end } }
proc reset {{rc 0} {out ""}} { global T; file delete $T/px.argv $T/px.env $T/px.stdin $T/px.out; spit $T/px.rc "$rc\n"; if {$out ne ""} { spit $T/px.out $out }; set ::got {} }
proc done {status msg} { set ::got [list $status $msg] }
# Wait until the change's DONE ran (a deadline, not a sleep).
proc settle {} {
	set t [after 10000 { set ::got {timeout {}} }]
	while {$::got eq {}} { vwait ::got }
	after cancel $t
}
set changes 0
set users::onchange { incr ::changes }

reset
users::add jonas "Jonas: Lindqvist," 1 $PW done; settle
check "add: pkexec HELPER add jonas on \"Jonas Lindqvist\" (the name cleaned)" {$got eq {ok {}} && [calls] eq {{/usr/bin/ribbon-users-helper add jonas on {Jonas Lindqvist}}}}
check "  the standard input is the login, a newline, the password, a newline" {[slurp $T/px.stdin] eq "jonas\n$PW\n"}
check "  the password is in no argument and not in the environment" {[string first $PW [slurp $T/px.argv]] < 0 && [string first {tr0ub4dor} [slurp $T/px.env]] < 0}
check "  the page was told (busy, then done)" {$changes >= 2 && !$users::busy}
reset
users::add jonas "" 0 $PW done; settle
check "add, standard, no full name" {[calls] eq {{/usr/bin/ribbon-users-helper add jonas off {}}}}
reset
users::remove mira 0 done; settle
check "remove: ... remove mira delete, nothing on the standard input" {$got eq {ok {}} && [calls] eq {{/usr/bin/ribbon-users-helper remove mira delete}} && [slurp $T/px.stdin] eq ""}
reset
users::remove mira 1 done; settle
check "remove, keeping the home folder: ... remove mira keep" {[calls] eq {{/usr/bin/ribbon-users-helper remove mira keep}}}
reset
users::rename mira "Mira Q" done; settle
check "rename: ... rename mira \"Mira Q\"" {[calls] eq {{/usr/bin/ribbon-users-helper rename mira {Mira Q}}}}
# a full name that starts as one of Tcl's redirections (<, >, 2>, |) is still one argument, and opens no file
foreach name [list ">$T/victim" "<$T/victim" "2>$T/victim" ">>$T/victim" "|cat" "<3 Mira" "&"] {
	reset; file delete $T/victim
	users::rename mira $name done; settle
	set c [lindex [calls] 0]
	check "rename to [list [string map [list $T {}] $name]]: one argument, which the helper trims to the name; no file" \
		{$got eq {ok {}} && [llength $c] == 4 && [lrange $c 0 2] eq {/usr/bin/ribbon-users-helper rename mira} && [string trimleft [lindex $c 3] " "] eq $name && ![file exists $T/victim]}
	reset; file delete $T/victim
	users::add jonas $name 0 $PW done; settle
	set c [lindex [calls] 0]
	check "  and in add" {$got eq {ok {}} && [llength $c] == 5 && [string trimleft [lindex $c 4] " "] eq $name && ![file exists $T/victim] && [slurp $T/px.stdin] eq "jonas\n$PW\n"}
}
reset
users::set_admin mira 1 done; settle
check "administrator on: ... admin mira on" {[calls] eq {{/usr/bin/ribbon-users-helper admin mira on}}}
reset
users::set_admin mira 0 done; settle
check "administrator off: ... admin mira off" {[calls] eq {{/usr/bin/ribbon-users-helper admin mira off}}}
reset
set got {}
users::set_admin adam 0 done
check "administrator off for the only administrator: refused here, no password prompt" {$got eq {failed {adam is the only administrator}} && [calls] eq {} && !$users::busy && $users::error eq "adam is the only administrator"}
reset
users::set_nopass guest 1 done; settle
check "log in without a password on: ... nopass guest on" {[calls] eq {{/usr/bin/ribbon-users-helper nopass guest on}}}
reset
users::set_nopass guest 0 done; settle
check "  off: ... nopass guest off" {[calls] eq {{/usr/bin/ribbon-users-helper nopass guest off}}}
reset
users::set_password mira $PW "" done; settle
check "someone else's password: ... passwd mira, the password on the standard input only" \
	{$got eq {ok {}} && [calls] eq {{/usr/bin/ribbon-users-helper passwd mira}} && [slurp $T/px.stdin] eq "mira\n$PW\n" && [string first {tr0ub4dor} [slurp $T/px.argv][slurp $T/px.env]] < 0}

# what comes back
reset 126
users::set_admin mira 1 done; settle
check "a dismissed prompt (126): cancelled, and nothing is said" {$got eq {cancelled {}} && $users::error eq ""}
reset 127
users::set_admin mira 1 done; settle
check "not authorised (127)" {$got eq {failed {Not authorised}} && $users::error eq "Not authorised"}
reset 2 "ribbon-users-helper: mira is logged in\n"
users::remove mira 0 done; settle
check "the helper's reason is the error line (a login name keeps its small letter)" {$got eq {failed {mira is logged in}} && $users::error eq "mira is logged in"}
reset 2 "ribbon-users-helper: there is already a user jonas\n"
users::add jonas J 0 $PW done; settle
check "  other lines get a capital" {[lindex $got 1] eq "There is already a user jonas"}
reset 1 "something else\n"
users::rename mira X done; settle
check "a failure with no reason: The change failed" {[lindex $got 1] eq "The change failed"}
reset
users::set_admin mira 1 done; settle
check "the next change that works clears the error" {$users::error eq ""}
set env(RIBBON_USERS_PKEXEC) $T/no-such-pkexec
reset
users::set_admin mira 1 done; settle
check "no pkexec: it says so, and nothing throws" {$got eq {failed {pkexec is not installed}}}
set env(RIBBON_USERS_PKEXEC) $T/pkexec
# one at a time
exe $T/slow "#!/bin/sh\ncat >/dev/null\nwhile \[ ! -e '$T/go' \]; do sleep 0.05; done\nexit 0\n"
set env(RIBBON_USERS_PKEXEC) $T/slow
reset
users::set_admin mira 1 done
check "while a change runs the model says busy" {$users::busy}
set second {}
users::set_admin guest 1 {apply {{s m} { set ::second ran }}}
spit $T/go ""; settle
check "  and a second change is not started" {$got eq {ok {}} && $second eq {} && !$users::busy}
set env(RIBBON_USERS_PKEXEC) $T/pkexec

# ---- your own password: passwd(1), as you ---------------------------------------------------------
exe $T/passwd [string map [list @T@ $T] {#!/bin/sh
{ printf 'passwd'; for a in "$@"; do printf '\037%s' "$a"; done; printf '\n'; } >>'@T@/px.argv'
env >'@T@/px.env'
cat >'@T@/px.stdin'
[ -r '@T@/px.out' ] && cat '@T@/px.out'
read -r rc <'@T@/px.rc' 2>/dev/null || rc=0
exit "$rc"
}]
set env(RIBBON_USERS_PASSWD) $T/passwd
reset 0 "Changing password for adam.\nCurrent password: New password: Retype new password: passwd: password updated successfully\n"
users::set_password adam $PW "the old one" done; settle
check "your own password: passwd with no argument, not pkexec" {$got eq {ok {}} && [calls] eq {{}} && [string match "passwd*" [slurp $T/px.argv]]}
check "  its standard input: the current password, the new one, the new one again" {[slurp $T/px.stdin] eq "the old one\n$PW\n$PW\n"}
check "  neither password is in an argument or the environment; passwd runs in the C locale" \
	{[string first {tr0ub4dor} [slurp $T/px.argv][slurp $T/px.env]] < 0 && [string first {the old one} [slurp $T/px.env]] < 0 && [string match "*LC_ALL=C*" [slurp $T/px.env]]}
reset 10 "Changing password for adam.\nCurrent password: passwd: Authentication token manipulation error\npasswd: password unchanged\n"
users::set_password adam $PW wrong done; settle
check "a wrong current password" {$got eq {failed {The current password is not right}}}
reset 10 "Changing password for adam.\nCurrent password: New password: Retype new password: You must choose a longer password.\nNew password: Retype new password: passwd: Authentication token manipulation error\npasswd: password unchanged\n"
users::set_password adam short old done; settle
check "what PAM says about the new password is passed on" {$got eq {failed {You must choose a longer password}}}
reset 10 "Current password: New password: BAD PASSWORD: The password is shorter than 8 characters\nNew password: passwd: Authentication token manipulation error\n"
users::set_password adam short old done; settle
check "  pwquality's too" {[lindex $got 1] eq "The password is shorter than 8 characters"}
reset 1 ""
users::set_password adam $PW old done; settle
check "passwd failing without a word" {$got eq {failed {The password was not changed}}}
set env(RIBBON_USERS_PASSWD) $T/no-such-passwd
reset
users::set_password adam $PW old done; settle
check "no passwd program: it says so" {$got eq {failed {passwd is not installed}}}

# ---- the whole chain: users.tcl → pkexec (stand-in) → the real helper → stand-in shadow tools ------
set helper $D/apps/settings/bin/ribbon-users-helper
set drop {}
set chain 1
if {$me == 0} {
	if {[auto_execok setpriv] eq ""} { set chain 0 } else {
		set drop "setpriv --reuid=23456 --regid=23456 --clear-groups --"
		if {[catch {exec {*}$drop test -x $T}]} { set chain 0 }
	}
}
if {!$chain} { puts "  skip the chain through the real helper (root here, and no way to run it as another uid)" } else {
	file mkdir $T/bin $T/log
	foreach t {useradd usermod userdel gpasswd groupadd chpasswd} {
		exe $T/bin/$t [string map [list @T@ $T @N@ $t] {#!/bin/sh
{ printf '%s' '@N@'; for a in "$@"; do printf '\037%s' "$a"; done; printf '\n'; } >>'@T@/log/argv'
cat >>'@T@/log/stdin.@N@'
exit 0
}]
	}
	exe $T/bin/tr "#!/bin/sh\nexec /usr/bin/tr \"\$@\"\n"
	exe $T/bin/flock "#!/bin/sh\nexec [auto_execok flock] \"\$@\"\n"
	# pkexec: a cleaned environment, PKEXEC_UID, root's place taken by another uid in the helper's test mode
	exe $T/pkexec-real "#!/bin/sh\nexec $drop env -i PATH=/usr/bin:/bin PKEXEC_UID=1000 RIBBON_USERS_TEST=1 RIBBON_USERS_ROOT='$R' RIBBON_USERS_BIN='$T/bin' \"\$@\"\n"
	set env(RIBBON_USERS_PKEXEC) $T/pkexec-real
	set env(RIBBON_USERS_HELPER) $helper
	fixture; spit $R/bin/bash ""; file attributes $R/bin/bash -permissions 0755; file mkdir $R/run
	if {$me == 0} { exec chown -R 23456:23456 $T }
	users::refresh
	proc tools {} { global T; lmap l [split [string trimright [slurp $T/log/argv] \n] \n] { split $l \x1f } }
	set got {}
	users::add jonas "Jonas Lindqvist" 1 $PW done; settle
	check "chain, add: useradd, chpasswd, gpasswd as the helper runs them" \
		{$got eq {ok {}} && [tools] eq {{useradd -m -U -s /bin/bash -G audio -c {Jonas Lindqvist} -- jonas} chpasswd {gpasswd -a jonas wheel}}}
	check "  chpasswd got jonas:PASSWORD on its standard input; no tool got it as an argument" \
		{[slurp $T/log/stdin.chpasswd] eq "jonas:$PW\n" && [string first {tr0ub4dor} [slurp $T/log/argv]] < 0}
	file delete -force $T/log; file mkdir $T/log; if {$me == 0} { exec chown 23456:23456 $T/log }
	set got {}
	users::set_password mira $PW "" done; settle
	check "chain, someone else's password" {$got eq {ok {}} && [tools] eq {chpasswd} && [slurp $T/log/stdin.chpasswd] eq "mira:$PW\n"}
	set got {}
	users::remove adam 0 done; settle
	check "chain: the helper's refusal comes back as the error (your own account)" {$got eq {failed {You cannot remove your own account}}}
	set got {}
	users::set_admin adam 0 done; settle
	check "chain: the only administrator stays one" {$got eq {failed {adam is the only administrator}}}
	set got {}
	users::rename mira "Mira Quill" done; settle
	check "chain, rename: usermod keeps the other GECOS fields" {$got eq {ok {}} && [lindex [tools] end] eq {usermod -c {Mira Quill,Room 1,555} -- mira}}
	set got {}
	users::rename mira ">_< Mira" done; settle
	check "chain, rename to \">_< Mira\": the helper stores it as typed" {$got eq {ok {}} && [lindex [tools] end] eq {usermod -c {>_< Mira,Room 1,555} -- mira}}
}

file delete -force $T
puts "$count checks, $fails failed"
exit [expr {$fails > 0}]
