# settings-users-helper.tcl - apps/settings/bin/ribbon-users-helper on a fake root (RIBBON_USERS_TEST, RIBBON_USERS_ROOT)
# with stand-ins for useradd, usermod, userdel, gpasswd, groupadd and chpasswd (RIBBON_USERS_BIN) that record their
# arguments, their standard input and their environment: what each verb runs, where the password goes (chpasswd's
# standard input and nowhere else), and every refusal. The helper reads its test variables only when it is NOT root,
# so as root this test runs it as another uid (setpriv); it also checks that, as root, the variables are ignored.
#   tclsh8.6 tests/settings-users-helper.tcl HELPER ?SHELL ...?        (each SHELL runs the whole list, default sh)
# Prints one line per check; exits 1 if any failed, 77 if it cannot run here.
encoding system utf-8
set helper [file normalize [lindex $argv 0]]
set shells [lrange $argv 1 end]
if {![llength $shells]} { set shells sh }
set fails 0
set count 0
proc check {what ok} {
	global fails count shell
	incr count
	if {[uplevel 1 [list expr $ok]]} { puts "  ok   \[$shell\] $what" } else { puts "  FAIL \[$shell\] $what"; incr fails }
}
proc slurp {f} { if {[catch {open $f rb} fh]} { return "" }; set t [read $fh]; close $fh; encoding convertfrom utf-8 $t }
proc spit {f t} { file mkdir [file dirname $f]; set fh [open $f wb]; puts -nonewline $fh [encoding convertto utf-8 $t]; close $fh }

set me [exec id -u]
set drop {}
if {$me == 0} {
	if {[auto_execok setpriv] eq ""} { puts "  skip: root here, and no setpriv to run the helper as someone else"; exit 77 }
	set drop [list setpriv --reuid=23456 --regid=23456 --clear-groups --]
}
# a directory the other uid can reach
set T ""
foreach base [list [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] /tmp /var/tmp] {
	set d [file normalize [file join $base uh-[pid]-[clock milliseconds]]]
	if {[catch {file mkdir $d}]} continue
	file attributes $d -permissions 0755
	if {$me != 0 || ![catch {exec {*}$drop test -x $d}]} { set T $d; break }
	file delete -force $d
}
if {$T eq ""} { puts "  skip: no temporary directory that another uid can reach"; exit 77 }
set R $T/root; set B $T/bin; set LOG $T/log

# The stand-ins: "NAME<US>arg<US>arg..." per call in log/argv, the standard input in log/stdin.NAME, the environment in
# log/env; rc.NAME holds the exit code to give (0 without it); chpasswd with rc.chpasswd also says its input out loud,
# as a tool that leaks would.
file mkdir $B $LOG $T/evil
foreach t {useradd usermod userdel gpasswd groupadd chpasswd} {
	spit $B/$t [string map [list @T@ $T @N@ $t] {#!/bin/sh
{ printf '%s' '@N@'; for a in "$@"; do printf '\037%s' "$a"; done; printf '\n'; } >>'@T@/log/argv'
env >>'@T@/log/env'
in=$(cat)
printf '%s' "$in" >>'@T@/log/stdin.@N@'
if [ -r '@T@/rc.@N@' ]; then
	read -r rc <'@T@/rc.@N@'
	[ '@N@' = chpasswd ] && printf 'leak: %s\n' "$in" >&2
	[ '@N@' = userdel ] && echo "userdel: user is currently used by process 1" >&2
	exit "$rc"
fi
exit 0
}]
	file attributes $B/$t -permissions 0755
}
spit $B/tr "#!/bin/sh\nexec /usr/bin/tr \"\$@\"\n"; file attributes $B/tr -permissions 0755
spit $B/flock "#!/bin/sh\nexec [auto_execok flock] \"\$@\"\n"; file attributes $B/flock -permissions 0755
# a trap: tools of the same names on the caller's PATH, and a file a shell would read at start
foreach t {useradd tr id chpasswd} { spit $T/evil/$t "#!/bin/sh\necho x >'$T/evil/ran'\n"; file attributes $T/evil/$t -permissions 0755 }
spit $T/evil/envfile "echo x >'$T/evil/ran'\n"

proc fixture {{admins adam} {extra ""}} {
	global R T
	file delete -force $R
	spit $R/etc/passwd "root:x:0:0:root:/root:/bin/bash\ndaemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\nsshd:x:101:65534::/run/sshd:/usr/sbin/nologin\nadam:x:1000:1000:Adam:/home/adam:/bin/bash\nmira:x:1001:1001:Mira,Room 1,555:/home/mira:/bin/bash\nguest:x:1002:1002::/home/guest:/bin/bash\nsvc:x:1003:1003:A service:/var/svc:/usr/sbin/nologin\nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n$extra"
	spit $R/etc/group "root:x:0:\nwheel:x:10:$admins\nadam:x:1000:\nmira:x:1001:\nguest:x:1002:\naudio:x:29:adam\n"
	spit $R/etc/default/useradd "# useradd defaults\nGROUP=100\nSHELL=/bin/zsh\n"
	spit $R/bin/bash ""; file attributes $R/bin/bash -permissions 0755
	file mkdir $R/run
	if {$::me == 0} { exec chown -R 23456:23456 $T }
}
proc reset {} {
	global LOG T
	file delete -force $LOG {*}[glob -nocomplain $T/rc.*] $T/evil/ran
	file mkdir $LOG
	if {$::me == 0} { exec chown 23456:23456 $LOG }
}
proc calls {} { global LOG; lmap l [split [string trimright [slurp $LOG/argv] \n] \n] { split $l \x1f } }

# Run the helper as the other uid: {exit-code output}. opts: -in TEXT (standard input), -env {NAME VALUE ...} (replaces
# the test's variables), -uid N (PKEXEC_UID, 1000 = adam), -root (run it as root, as it is).
proc run {args} {
	global helper R B T drop shell
	set o [dict create -in "" -uid 1000 -root 0 -dry 0]
	set env [list RIBBON_USERS_TEST 1 RIBBON_USERS_ROOT $R RIBBON_USERS_BIN $B]
	while {[string match -* [lindex $args 0]] && [lindex $args 0] in {-in -env -uid -root -dry}} {
		if {[lindex $args 0] eq "-env"} { set env [lindex $args 1] } else { dict set o [lindex $args 0] [lindex $args 1] }
		set args [lrange $args 2 end]
	}
	if {[dict get $o -uid] ne ""} { lappend env PKEXEC_UID [dict get $o -uid] }
	set pre [expr {[dict get $o -root] ? {} : $drop}]
	set cmd [list {*}$pre env -i PATH=$T/evil:/usr/bin:/bin ENV=$T/evil/envfile BASH_ENV=$T/evil/envfile]
	foreach {k v} $env { lappend cmd $k=$v }
	lappend cmd {*}$shell $helper {*}$args
	if {[dict get $o -dry]} { return $cmd }
	spit $T/in [dict get $o -in]
	set code 0
	if {[catch {exec {*}$cmd <$T/in 2>@1} out opts]} {
		set ec [dict get $opts -errorcode]
		set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : 1}]
	}
	file delete $T/in
	list $code [encoding convertfrom utf-8 [encoding convertto iso8859-1 $out]]
}
# The password is in chpasswd's standard input and nowhere else that was recorded or printed.
proc nowhere {pw out} {
	global LOG
	expr {[string first $pw $out] < 0 && [string first $pw [slurp $LOG/argv]] < 0 && [string first $pw [slurp $LOG/env]] < 0}
}

set PW {tr0ub4dor&3 "x" $(id) `id` ; :colon \ back}
set BAD [list "a b" "a:b" "a;b" "\$(touch $T/evil/ran)" "`touch $T/evil/ran`" "a\nb" "mira\n" "-rf" "--help" "-" "Adam" "1abc" "" \
	[string repeat a 33] "a/b" "../etc" "a*" "ä" "a'b" "a\"b" "a|b" "a&b" "mira;reboot" "mira mira" "a\tb" "a\\b" "a,b" "a=b" "a.b"]

foreach shell $shells {
	if {[auto_execok [lindex $shell 0]] eq ""} { puts "  skip \[$shell\]: not installed"; continue }

	# ---- who may run it -------------------------------------------------------------------------
	fixture; reset
	lassign [run -env {} passwd mira] code out
	check "without the test flag someone who is not root is refused" {$code == 2 && [string match "*through pkexec*" $out] && [calls] eq {}}
	lassign [run -env [list RIBBON_USERS_TEST 1 RIBBON_USERS_ROOT $R] passwd mira] code out
	check "the test flag alone is refused: a test must name its stand-in tools" {$code == 2 && [calls] eq {}}
	lassign [run -env [list RIBBON_USERS_TEST 1 RIBBON_USERS_BIN $B] passwd mira] code out
	check "  and its root" {$code == 2 && [calls] eq {}}
	lassign [run -env [list RIBBON_USERS_TEST 1 RIBBON_USERS_ROOT relative RIBBON_USERS_BIN $B] passwd mira] code out
	check "  an absolute one" {$code == 2 && [calls] eq {}}
	lassign [run -uid "" -in "mira\n$PW\n" passwd mira] code out
	check "without PKEXEC_UID it is refused" {$code == 2 && [string match "*through pkexec*" $out] && [calls] eq {}}
	lassign [run -uid "1000x" -in "mira\n$PW\n" passwd mira] code out
	check "  and with one that is not a number" {$code == 2 && [calls] eq {}}
	if {$me == 0} {
		if {[catch {exec grep -q {^mira:} /etc/passwd}]} {
			lassign [run -root 1 -in "mira\n$PW\n" passwd mira] code out
			check "as root the test variables are not read: the fake root's mira does not exist, no stand-in runs" \
				{$code == 2 && [string match "*there is no user mira*" $out] && [calls] eq {}}
			lassign [run -root 1 -uid "" passwd mira] code out
			check "as root without PKEXEC_UID it is refused" {$code == 2 && [calls] eq {}}
		} else { puts "  skip \[$shell\]: this machine has a real user mira" }
	}

	# ---- the words ------------------------------------------------------------------------------
	foreach a {{} {frob mira} {passwd} {passwd mira extra} {add jonas} {add jonas on} {add jonas maybe Jonas} {add jonas on Jonas more}
		{remove mira} {remove mira purge} {remove mira delete more} {rename mira} {admin mira} {admin mira yes} {admin mira on off}
		{nopass mira} {nopass mira 1} {ADD jonas on Jonas} {-h} {--help}} {
		reset
		lassign [run -in "mira\n$PW\n" {*}$a] code out
		check "refused: [list {*}$a]" {$code == 2 && [calls] eq {}}
	}

	# ---- passwd: the password goes to chpasswd's standard input and nowhere else ----------------
	reset
	lassign [run -in "mira\n$PW\n" passwd mira] code out
	check "passwd mira: chpasswd is run with no argument" {$code == 0 && $out eq "" && [calls] eq {chpasswd}}
	check "  its standard input is mira:PASSWORD and a newline, byte for byte" {[slurp $LOG/stdin.chpasswd] eq "mira:$PW"}
	check "  the password is in no argument, no environment and no output" {[nowhere $PW $out]}
	check "  the caller's PATH and ENV were not used" {![file exists $T/evil/ran]}
	reset
	lassign [run -in "mira\n$PW" passwd mira] code out
	check "a last line without its newline is still the password" {$code == 0 && [slurp $LOG/stdin.chpasswd] eq "mira:$PW"}
	reset
	lassign [run -in "mira\n  spaced out  \n" passwd mira] code out
	check "spaces at the ends of a password are kept" {$code == 0 && [slurp $LOG/stdin.chpasswd] eq "mira:  spaced out  "}
	reset
	lassign [run -in "mira\nłódź-пароль-🔑\n" passwd mira] code out
	check "a password outside ASCII goes through unchanged" {$code == 0 && [slurp $LOG/stdin.chpasswd] eq "mira:łódź-пароль-🔑"}
	reset; spit $T/rc.chpasswd 1
	lassign [run -in "mira\n$PW\n" passwd mira] code out
	check "chpasswd failing (and saying the password out loud): exit 1, and the helper does not repeat it" \
		{$code == 1 && [string match "*not accepted*" $out] && [nowhere $PW $out]}
	foreach {what in} [list "no standard input" "" "only the login" "mira\n" "an empty password" "mira\n\n" "another account's name first" "adam\n$PW\n" \
		"a tab in the password" "mira\na\tb\n" "a carriage return in it" "mira\nabc\r\n" "an escape in it" "mira\na\x1b\[2Jb\n" "257 characters" "mira\n[string repeat x 257]\n"] {
		reset
		lassign [run -in $in passwd mira] code out
		check "passwd refused: $what" {$code == 2 && [calls] eq {} && ($in eq "" || [string first [lindex [split $in \n] 1] $out] < 0 || [lindex [split $in \n] 1] eq "")}
	}
	reset
	lassign [run -in "mira\n[string repeat x 256]\n" passwd mira] code out
	check "256 characters are taken" {$code == 0}
	foreach who {root daemon sshd nobody ghost} {
		reset
		lassign [run -in "$who\n$PW\n" passwd $who] code out
		check "passwd refused for $who (a system account, or no account)" {$code == 2 && [calls] eq {}}
	}
	foreach n $BAD {
		reset
		lassign [run -in "$n\n$PW\n" passwd $n] code out
		check "passwd refused for the name [string map [list \n {\n} \t {\t} $T {}] [list $n]]" {$code == 2 && [calls] eq {} && ![file exists $T/evil/ran]}
	}

	# ---- add ------------------------------------------------------------------------------------
	reset
	lassign [run -in "jonas\n$PW\n" add jonas off "Jonas Lindqvist"] code out
	check "add jonas: useradd -m -U -s SHELL -G GROUPS -c NAME -- jonas, then chpasswd; no group is touched after" \
		{$code == 0 && $out eq "" && [calls] eq {{useradd -m -U -s /bin/bash -G audio -c {Jonas Lindqvist} -- jonas} chpasswd}}
	check "  the password went to chpasswd only" {[slurp $LOG/stdin.chpasswd] eq "jonas:$PW" && [nowhere $PW $out] && [slurp $LOG/stdin.useradd] eq ""}
	reset
	lassign [run -in "jonas\n$PW\n" add jonas on "Jonas Lindqvist"] code out
	check "add jonas on: then gpasswd -a jonas wheel" {$code == 0 && [lindex [calls] 2] eq {gpasswd -a jonas wheel} && [llength [calls]] == 3}
	reset
	lassign [run -in "jonas\n$PW\n" add jonas off ""] code out
	check "no full name: no -c" {$code == 0 && [lindex [calls] 0] eq {useradd -m -U -s /bin/bash -G audio -- jonas}}
	reset
	lassign [run -in "jonas\n$PW\n" add jonas off "  Jo:nas,\x01 L\x7f.\n  "] code out
	check "a full name loses : , and control characters, and is trimmed" {$code == 0 && [lindex [calls] 0 8] eq "Jonas L."}
	reset
	lassign [run -in "jonas\n$PW\n" add jonas off "-c evil --badname"] code out
	check "a full name that looks like options stays one argument after -c" {$code == 0 && [lindex [calls] 0] eq {useradd -m -U -s /bin/bash -G audio -c {-c evil --badname} -- jonas}}
	reset
	lassign [run -in "jonas\n$PW\n" add jonas off "Zoë Łukasiewicz"] code out
	check "a full name outside ASCII is kept" {$code == 0 && [lindex [calls] 0 8] eq "Zoë Łukasiewicz"}
	reset
	lassign [run -in "jonas\n$PW\n" add jonas off [string repeat n 121]] code out
	check "a full name of 121 characters is refused" {$code == 2 && [calls] eq {}}
	# the groups of a new account: the installer's list for the first user, each only where this system has it
	reset; set g0 [slurp $R/etc/group]
	spit $R/etc/group "${g0}kvm:x:24:\nnetwork:x:21:adam\nvideo:x:27:\nsudo:x:27:\ndocker:x:99:\ninput:x:97:\n"; if {$me == 0} { exec chown -R 23456:23456 $R }
	lassign [run -in "jonas\n$PW\n" add jonas off J] code out
	check "a new account is in the installer's groups that exist here, and no other" {$code == 0 && [lrange [lindex [calls] 0] 5 6] eq {-G audio,video,network,kvm}}
	check "  never in input (it reads every keyboard on the machine), though this system has the group" {[string first input [lindex [calls] 0]] < 0}
	# the installer gives the first user the same groups (each of its own list where the system has it)
	set inst [slurp [file normalize [file join $helper .. .. .. .. .. .. .. srcpkgs ribbon-installer files bin ribbon-install]]]
	set help [slurp $helper]
	regexp {for g in wheel ([a-z ]+); do} $inst -> il
	regexp {for ng in ([a-z ]+); do} $help -> hl
	check "the installer's groups for the first user are the helper's for a new one (wheel aside)" {$il eq $hl}
	reset; spit $R/etc/group "root:x:0:\nwheel:x:10:adam\nadam:x:1000:\n"; if {$me == 0} { exec chown -R 23456:23456 $R }
	lassign [run -in "jonas\n$PW\n" add jonas off J] code out
	check "  none of them here: no -G" {$code == 0 && [lindex [calls] 0] eq {useradd -m -U -s /bin/bash -c J -- jonas}}
	spit $R/etc/group $g0; if {$me == 0} { exec chown -R 23456:23456 $R }
	set inst ""; regexp -line {^for g in wheel (.*); do$} [slurp [file join [file dirname [file normalize [info script]]] .. srcpkgs ribbon-installer files bin ribbon-install]] -> inst
	set mine ""; regexp -line {^\tfor ng in (.*); do$} [slurp $helper] -> mine
	check "the helper's list is the installer's (without wheel)" {$inst ne "" && [split $inst " "] eq [split $mine " "]}
	reset; spit $R/bin/zsh ""; file attributes $R/bin/zsh -permissions 0755
	lassign [run -in "jonas\n$PW\n" add jonas off J] code out
	check "the shell is /etc/default/useradd's SHELL when that is there to run" {[lindex [calls] 0 4] eq "/bin/zsh"}
	reset; spit $R/etc/default/useradd "SHELL=/usr/sbin/nologin\n"; spit $R/usr/sbin/nologin ""; file attributes $R/usr/sbin/nologin -permissions 0755
	lassign [run -in "jonas\n$PW\n" add jonas off J] code out
	check "  not when it is nologin" {[lindex [calls] 0 4] eq "/bin/bash"}
	reset; spit $R/etc/default/useradd "SHELL=/bin/zsh;reboot\n"
	lassign [run -in "jonas\n$PW\n" add jonas off J] code out
	check "  nor when it is not a plain path" {[lindex [calls] 0 4] eq "/bin/bash"}
	reset; file delete $R/bin/bash $R/etc/default/useradd
	lassign [run -in "jonas\n$PW\n" add jonas off J] code out
	check "  /bin/sh when there is no bash" {[lindex [calls] 0 4] eq "/bin/sh"}
	fixture; reset; spit $T/rc.chpasswd 1
	lassign [run -in "jonas\n$PW\n" add jonas on "Jonas"] code out
	check "add, the password refused: the new account is removed again (userdel -r), wheel untouched, exit 1" \
		{$code == 1 && [lmap c [calls] { lindex $c 0 }] eq {useradd chpasswd userdel} && [lindex [calls] 2] eq {userdel -r -- jonas} && [nowhere $PW $out]}
	reset; spit $T/rc.useradd 9
	lassign [run -in "jonas\n$PW\n" add jonas on "Jonas"] code out
	check "add, useradd failing: nothing else runs, exit 1" {$code == 1 && [lmap c [calls] { lindex $c 0 }] eq {useradd} && [nowhere $PW $out]}
	foreach {what a in} [list "a name a user has" {add mira off M} "mira\n$PW\n" "a name a group has" {add audio off A} "audio\n$PW\n" \
		"root" {add root on R} "root\n$PW\n" "no password sent" {add jonas off J} "" "an empty password" {add jonas off J} "jonas\n\n" \
		"the password named for another login" {add jonas off J} "mira\n$PW\n"] {
		reset
		lassign [run -in $in {*}$a] code out
		check "add refused: $what" {$code == 2 && [calls] eq {}}
	}
	foreach n $BAD {
		reset
		lassign [run -in "$n\n$PW\n" add $n off "Some One"] code out
		check "add refused for the name [string map [list \n {\n} \t {\t} $T {}] [list $n]]" {$code == 2 && [calls] eq {} && ![file exists $T/evil/ran]}
	}
	fixture adam ""; spit $R/etc/group "root:x:0:\nadam:x:1000:\n"; if {$me == 0} { exec chown -R 23456:23456 $R }
	reset
	lassign [run -in "jonas\n$PW\n" add jonas on J] code out
	check "add as an administrator where there is no wheel group: refused before anything is made" {$code == 2 && [calls] eq {}}
	reset
	lassign [run -in "wheel\n$PW\n" add wheel off W] code out
	check "add refused: wheel where there is no wheel group yet (its own group would make it an administrator)" {$code == 2 && [calls] eq {}}
	# useradd -U gives an account a group of its own name: an account called nopasswdlogin would log in without a password
	fixture; reset
	lassign [run -in "nopasswdlogin\n$PW\n" add nopasswdlogin off N] code out
	check "add refused: nopasswdlogin before that group exists (its own group would let it in without a password)" {$code == 2 && [calls] eq {}}
	# the page's Full name field takes 120 characters; the helper counts characters, not bytes
	reset
	lassign [run -in "jonas\n$PW\n" add jonas off [string repeat ö 120]] code out
	check "a full name of 120 characters outside ASCII (240 bytes) is taken" {$code == 0 && [lindex [calls] 0 8] eq [string repeat ö 120]}
	reset
	lassign [run rename mira [string repeat 🔑 120]] code out
	check "  by rename too (480 bytes)" {$code == 0 && [lindex [calls] 0 2] eq "[string repeat 🔑 120],Room 1,555"}
	reset
	lassign [run -in "jonas\n$PW\n" add jonas off [string repeat ö 121]] code out
	check "  121 of them are refused" {$code == 2 && [calls] eq {}}

	# ---- remove ---------------------------------------------------------------------------------
	fixture; reset
	lassign [run remove mira delete] code out
	check "remove mira delete: userdel -r -- mira" {$code == 0 && $out eq "" && [calls] eq {{userdel -r -- mira}}}
	reset
	lassign [run remove mira keep] code out
	check "remove mira keep: userdel -- mira (the home folder stays)" {$code == 0 && [calls] eq {{userdel -- mira}}}
	reset
	lassign [run remove adam delete] code out
	check "refused: removing the account that asked (PKEXEC_UID)" {$code == 2 && [string match "*your own*" $out] && [calls] eq {}}
	reset
	lassign [run -uid 1001 remove adam delete] code out
	check "refused: removing the only administrator, whoever asks" {$code == 2 && [string match "*only administrator*" $out] && [calls] eq {}}
	foreach who {root daemon sshd nobody ghost} {
		reset
		lassign [run remove $who delete] code out
		check "remove refused for $who" {$code == 2 && [calls] eq {}}
	}
	foreach n $BAD {
		reset
		lassign [run remove $n delete] code out
		check "remove refused for the name [string map [list \n {\n} \t {\t} $T {}] [list $n]]" {$code == 2 && [calls] eq {} && ![file exists $T/evil/ran]}
	}
	reset; spit $T/rc.userdel 8
	lassign [run remove mira delete] code out
	check "userdel's 8 is told as it is: mira is logged in, exit 1" {$code == 1 && [string match "*mira is logged in*" $out]}
	reset; spit $T/rc.userdel 12
	lassign [run remove mira delete] code out
	check "userdel failing with the account still there: exit 1" {$code == 1 && [string match "*userdel:*" $out]}
	# ---- a removed account's number is not handed to the next one (its files are still owned by it) ----------------
	set mark $R/var/lib/ribbon/users-uid-mark
	fixture; reset
	lassign [run remove svc keep] code out
	check "remove records the number it takes away (the highest, 1003) in var/lib/ribbon/users-uid-mark" {$code == 0 && [string trim [slurp $mark]] eq "1003"}
	reset
	lassign [run -in "jonas\n$PW\n" add jonas off "Jonas"] code out
	check "the next add asks for a number above it: -u 1004, not useradd's own highest + 1 (the removed one's)" \
		{$code == 0 && [lindex [calls] 0] eq {useradd -m -U -s /bin/bash -u 1004 -G audio -c Jonas -- jonas}}
	fixture; reset
	lassign [run remove mira delete] code out
	check "a removed number below the highest in use is recorded too" {$code == 0 && [string trim [slurp $mark]] eq "1001"}
	reset
	lassign [run -in "jonas\n$PW\n" add jonas off "Jonas"] code out
	check "  but add leaves the choice to useradd while an account holds a higher number (no -u)" {$code == 0 && [lindex [calls] 0] eq {useradd -m -U -s /bin/bash -G audio -c Jonas -- jonas}}
	reset
	lassign [run remove svc delete] code out
	check "the mark only goes up: removing a higher one raises it" {$code == 0 && [string trim [slurp $mark]] eq "1003"}
	reset
	lassign [run remove guest delete] code out
	check "  and a lower one afterwards leaves it" {$code == 0 && [string trim [slurp $mark]] eq "1003"}
	fixture; reset; spit $mark "not a number\n"
	lassign [run -in "jonas\n$PW\n" add jonas off "Jonas"] code out
	check "a mark that is no number is ignored (no -u)" {$code == 0 && [lindex [calls] 0] eq {useradd -m -U -s /bin/bash -G audio -c Jonas -- jonas}}
	fixture; reset; spit $mark "60000\n"
	lassign [run -in "jonas\n$PW\n" add jonas off "Jonas"] code out
	check "no number left above the mark (past 59999): add is refused, nothing run" {$code == 2 && [string match "*no user number is left*" $out] && [calls] eq {}}
	fixture; reset; spit $R/var/lib/ribbon "in the way"
	lassign [run remove mira delete] code out
	check "the number cannot be recorded: the account is not removed (exit 1, userdel never runs)" {$code == 1 && [string match "*cannot record*mira was not removed*" $out] && [calls] eq {}}
	fixture adam,mira; reset
	lassign [run -uid 1001 remove adam delete] code out
	check "with two administrators one of them can be removed by the other" {$code == 0 && [calls] eq {{userdel -r -- adam}}}
	# a nologin account in wheel is not an administrator who could take over
	fixture adam,svc; reset
	lassign [run -uid 1001 remove adam delete] code out
	check "an account without a login shell in wheel does not count as a second administrator" {$code == 2 && [calls] eq {}}
	fixture adam "pat:x:1004:10:Pat:/home/pat:/bin/bash\n"; reset
	lassign [run -uid 1001 remove adam delete] code out
	check "an account whose own group is wheel does" {$code == 0}

	# ---- rename ---------------------------------------------------------------------------------
	fixture; reset
	lassign [run rename adam "Adam B. Smith"] code out
	check "rename adam: usermod -c NAME -- adam" {$code == 0 && $out eq "" && [calls] eq {{usermod -c {Adam B. Smith} -- adam}}}
	reset
	lassign [run rename mira "Mira Q"] code out
	check "the other GECOS fields (room, telephone) are kept" {$code == 0 && [calls] eq {{usermod -c {Mira Q,Room 1,555} -- mira}}}
	reset
	lassign [run rename guest "x:0:0:pwn:/root:/bin/sh\nevil::0:0::/:/bin/sh"] code out
	check "a name made to break /etc/passwd loses its colons and its newline" {$code == 0 && [lindex [calls] 0 2] eq "x00pwn/root/bin/shevil00//bin/sh"}
	reset
	lassign [run rename guest ""] code out
	check "an empty name is allowed (the login is shown then)" {$code == 0 && [calls] eq {{usermod -c {} -- guest}}}
	foreach who {root daemon nobody ghost "a b" "-c"} {
		reset
		lassign [run rename $who "New Name"] code out
		check "rename refused for [list $who]" {$code == 2 && [calls] eq {}}
	}
	reset; spit $T/rc.usermod 1
	lassign [run rename adam "A"] code out
	check "usermod failing: exit 1" {$code == 1}

	# ---- admin ----------------------------------------------------------------------------------
	fixture; reset
	lassign [run admin mira on] code out
	check "admin mira on: gpasswd -a mira wheel" {$code == 0 && $out eq "" && [calls] eq {{gpasswd -a mira wheel}}}
	reset
	lassign [run admin adam on] code out
	check "admin on for someone who is one already: nothing to do" {$code == 0 && [calls] eq {}}
	reset
	lassign [run admin mira off] code out
	check "admin off for someone who is not one: nothing to do" {$code == 0 && [calls] eq {}}
	reset
	lassign [run admin adam off] code out
	check "refused: taking the right from the only administrator" {$code == 2 && [string match "*only administrator*" $out] && [calls] eq {}}
	reset
	lassign [run -uid 1001 admin adam off] code out
	check "  whoever asks" {$code == 2 && [calls] eq {}}
	fixture adam,mira; reset
	lassign [run admin adam off] code out
	check "with two administrators: gpasswd -d adam wheel" {$code == 0 && [calls] eq {{gpasswd -d adam wheel}}}
	fixture adam "pat:x:1004:10:Pat:/home/pat:/bin/bash\n"; reset
	lassign [run admin pat off] code out
	check "refused: an account whose own group is wheel" {$code == 2 && [calls] eq {}}
	fixture; reset
	foreach who {root daemon nobody ghost "mira adam" "-a"} {
		reset
		lassign [run admin $who on] code out
		check "admin refused for [list $who]" {$code == 2 && [calls] eq {}}
	}
	spit $R/etc/group "root:x:0:\nadam:x:1000:\n"; if {$me == 0} { exec chown -R 23456:23456 $R }
	reset
	lassign [run admin mira on] code out
	check "admin refused where there is no wheel group" {$code == 2 && [calls] eq {}}

	# ---- nopass ---------------------------------------------------------------------------------
	fixture; reset
	lassign [run nopass mira on] code out
	check "nopass mira on, no group yet: groupadd -r nopasswdlogin, gpasswd -a mira nopasswdlogin" \
		{$code == 0 && $out eq "" && [calls] eq {{groupadd -r nopasswdlogin} {gpasswd -a mira nopasswdlogin}}}
	reset
	lassign [run nopass mira off] code out
	check "nopass off with no group: nothing to do" {$code == 0 && [calls] eq {}}
	set g [slurp $R/etc/group]; spit $R/etc/group "${g}nopasswdlogin:x:990:guest,mira\n"; if {$me == 0} { exec chown -R 23456:23456 $R }
	reset
	lassign [run nopass mira on] code out
	check "nopass on for a member: nothing to do" {$code == 0 && [calls] eq {}}
	reset
	lassign [run nopass adam on] code out
	check "nopass on, the group there: gpasswd -a only" {$code == 0 && [calls] eq {{gpasswd -a adam nopasswdlogin}}}
	reset
	lassign [run nopass mira off] code out
	check "nopass mira off: gpasswd -d mira nopasswdlogin" {$code == 0 && [calls] eq {{gpasswd -d mira nopasswdlogin}}}
	foreach who {root daemon nobody ghost "mi ra"} {
		reset
		lassign [run nopass $who on] code out
		check "nopass refused for [list $who]" {$code == 2 && [calls] eq {}}
	}

	# ---- two changes at once --------------------------------------------------------------------
	# B2: stand-ins that really change the fake root's files, slowly (gpasswd -d, userdel): two helpers started together,
	# each taking one of two administrators away, must not both pass the last-administrator check.
	file delete -force $T/bin2; file mkdir $T/bin2
	foreach t {useradd usermod groupadd chpasswd tr flock} { if {[file exists $B/$t]} { file copy $B/$t $T/bin2/$t } }
	spit $T/bin2/gpasswd [string map [list @R@ $R] {#!/bin/sh
sleep 1
awk -F: -v OFS=: -v u="$2" -v g="$3" '$1 == g { n = split($4, m, ","); s = ""; for (i = 1; i <= n; i++) if (m[i] != u) s = s (s == "" ? "" : ",") m[i]; $4 = s } { print }' '@R@/etc/group' >'@R@/etc/group.new' && mv '@R@/etc/group.new' '@R@/etc/group'
}]
	spit $T/bin2/userdel [string map [list @R@ $R] {#!/bin/sh
sleep 1
for a in "$@"; do u=$a; done
grep -v "^$u:" '@R@/etc/passwd' >'@R@/etc/passwd.new'; mv '@R@/etc/passwd.new' '@R@/etc/passwd'
}]
	file attributes $T/bin2/gpasswd -permissions 0755; file attributes $T/bin2/userdel -permissions 0755
	if {$me == 0} { exec chown -R 23456:23456 $T/bin2 }
	proc together {a b} {
		global R T
		set chs {}
		foreach {uid argv} [list {*}$a {*}$b] {
			set env [list RIBBON_USERS_TEST 1 RIBBON_USERS_ROOT $R RIBBON_USERS_BIN $T/bin2]
			set cmd [run -dry 1 -uid $uid -env $env {*}$argv]
			lappend chs [open |[concat [list {*}$cmd] {</dev/null 2>@1}] r]
		}
		set codes {}
		foreach ch $chs {
			read $ch
			if {[catch {close $ch} m opts]} { lappend codes [lindex [dict get $opts -errorcode] 2] } else { lappend codes 0 }
		}
		lsort $codes
	}
	fixture adam,mira; reset
	set codes [together {1000 {admin adam off}} {1001 {admin mira off}}]
	regexp -line {^wheel:x:10:(.*)$} [slurp $R/etc/group] -> left
	check "admin adam off and admin mira off at once: one is made, the other refused; an administrator is left" {$codes eq {0 2} && $left in {adam mira}}
	fixture adam,mira "pat:x:1004:1004:Pat:/home/pat:/bin/bash\n"; reset
	set codes [together {1004 {remove adam delete}} {1004 {admin mira off}}]
	regexp -line {^wheel:x:10:(.*)$} [slurp $R/etc/group] -> left
	check "remove adam and admin mira off at once: an administrator is left" {$codes eq {0 2}}

	# ---- a damaged or missing passwd file -------------------------------------------------------
	fixture; reset; file delete $R/etc/passwd
	lassign [run -in "mira\n$PW\n" passwd mira] code out
	check "no /etc/passwd: exit 1, nothing runs" {$code == 1 && [calls] eq {}}
	fixture adam "::::\nmira2:x:notanumber:5::/:/bin/sh\nbig:x:100000000000000000000:5::/:/bin/sh\n\n"; reset
	lassign [run rename mira2 X] code out
	check "a uid that is not a number is not a person's account" {$code == 2 && [calls] eq {}}
	lassign [run rename big X] code out
	check "  nor one too long to be a uid" {$code == 2 && [calls] eq {}}
	lassign [run rename mira Y] code out
	check "  and the good lines of a damaged file still work" {$code == 0}
}
file delete -force $T
puts "$count checks, $fails failed"
exit [expr {$fails > 0}]
