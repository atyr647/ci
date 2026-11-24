# settings-hostname-helper.tcl - apps/settings/bin/ribbon-hostname-helper on a fake root (RIBBON_HOSTNAME_TEST,
# RIBBON_HOSTNAME_ROOT, RIBBON_HOSTNAME_CMD), under every POSIX shell there is here: what it refuses, what it writes
# and where, /etc/hosts line by line, replacing without following a link, the safety checks on /etc, the running
# system named first and named back when the file cannot be written, a hostile environment; and, where unshare can make
# a private UTS namespace, the real `hostname` program naming a real (private) system.
#   tclsh8.6 tests/settings-hostname-helper.tcl HELPER
# Prints one line per check; exits 1 if any failed. It never runs the helper outside a test root as root: the two
# checks that leave the test (no RIBBON_HOSTNAME_TEST, PKEXEC_UID set) run as nobody when this is root.
set helper [file normalize [lindex $argv 0]]
set fails 0
proc check {what cond} {
	global fails
	if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}
proc is {what got want} {
	global fails
	if {$got eq $want} { puts "  ok   $what" } else { puts "  FAIL $what: got '$got', want '$want'"; incr fails }
}
proc slurp {f} { if {[catch {open $f rb} fh]} { return "(none)" }; set t [read $fh]; close $fh; set t }
proc spit {f t} { file mkdir [file dirname $f]; set fh [open $f wb]; puts -nonewline $fh $t; close $fh }
proc script {f body} { spit $f "#!/bin/sh\n$body\n"; file attributes $f -permissions 0755 }

set T [file normalize [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] hh-[pid]-[clock milliseconds]]]
file mkdir $T
set R $T/root
set me [exec id -u]
set SH sh
set AS {}   ;# a command the helper is run under (setpriv, for the checks that must not be root)

# Run the helper with ENV (a dict over the test's own settings): {exit-code stdout stderr}.
proc run {args} { runenv {} {*}$args }
proc runenv {extra args} {
	global helper R T SH
	set keep [array get ::env]
	array set ::env [list RIBBON_HOSTNAME_TEST 1 RIBBON_HOSTNAME_ROOT $R RIBBON_HOSTNAME_CMD $T/hostname HLOG $T/hostname.log ROOT $R]
	catch {unset ::env(PKEXEC_UID)}
	foreach {k v} $extra { if {$v eq "(unset)"} { catch {unset ::env($k)} } else { set ::env($k) $v } }
	set code 0
	if {[catch {exec {*}$::AS {*}$SH $helper {*}$args 2>$T/stderr} out opts]} {
		set ec [dict get $opts -errorcode]
		set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : -1}]
		if {$code == -1} { set out [dict get $opts -errorinfo] } else { set out "" }
	}
	# (the array itself is never unset: Tcl stops passing env on once it is)
	foreach k [array names ::env] { if {![dict exists $keep $k]} { unset ::env($k) } }
	array set ::env $keep
	list $code [string trim $out] [string trim [slurp $T/stderr]]
}
# The fake root: /etc with a name, the kernel's name, a hostname program that logs and writes the kernel's file.
proc fresh {{name old} {hosts ""}} {
	global R T
	file delete -force $R $T/hostname.log
	file mkdir $R/etc $R/proc/sys/kernel
	file attributes $R/etc -permissions 0755
	if {$name ne ""} { spit $R/etc/hostname "$name\n"; spit $R/proc/sys/kernel/hostname "$name\n" }
	if {$hosts ne ""} { spit $R/etc/hosts $hosts }
	script $T/hostname {echo "$*" >> "$HLOG"; printf '%s\n' "$1" > "$ROOT/proc/sys/kernel/hostname"}
}
proc etc {} { lsort [glob -nocomplain -directory $::R/etc -tails * .*] }
proc snapshot {} {
	set out {}
	foreach f [lsort [glob -nocomplain -directory $::R -types {f l} etc/* etc/.* proc/sys/kernel/*]] { lappend out $f [file type $f] [slurp $f] }
	set out
}
proc calls {} { set t [slurp $::T/hostname.log]; expr {$t eq "(none)" ? {} : [split [string trimright $t \n] \n]} }

proc suite {} {
	global R T SH helper me
	# ---- what it refuses, before it touches anything
	fresh
	set before [snapshot]
	foreach {what argv} {
		"no arguments" {}
		"a verb alone" {set}
		"another verb" {get old}
		"apply" {apply}
		"an option" {--help x}
		"three arguments" {set a b}
	} { is "refused: $what" [lindex [run {*}$argv] 0] 2 }
	foreach name [list "" - -a a- a_b a.b "a b" " a" a/b ../etc "a\nb" "a\tb" {$(id)} {a;b} {a`id`} é ａ [string repeat a 64] "a\\"] {
		set r [run set $name]
		check "refused as a name: '[string map [list \n {\n} \t {\t}] [string range $name 0 20]]'" {[lindex $r 0] == 2 && [string match "ribbon-hostname-helper: not a computer's name*" [lindex $r 2]]}
	}
	is "  and nothing was touched, nothing run" [list [snapshot] [calls]] [list $before {}]
	is "a relative test root is refused" [lindex [runenv {RIBBON_HOSTNAME_ROOT relative/dir} set new] 0] 2
	is "a test with no root is refused (it never falls back to the real system)" [lindex [runenv {RIBBON_HOSTNAME_ROOT (unset)} set new] 0] 2
	is "  nor with / as its root" [lindex [runenv {RIBBON_HOSTNAME_ROOT /} set new] 0] 2
	is "  nor //" [lindex [runenv {RIBBON_HOSTNAME_ROOT //} set new] 0] 2
	# as root these two would name the real system: they are run as nobody then (setpriv), or not at all
	set ::AS {}
	if {$me == 0 && ![catch {exec setpriv --reuid 65534 --regid 65534 --clear-groups {*}$SH -c {test -r "$1"} sh $helper}]} {
		set ::AS {setpriv --reuid 65534 --regid 65534 --clear-groups}
	}
	if {$me != 0 || [llength $::AS]} {
		set r [runenv {RIBBON_HOSTNAME_TEST (unset)} set new]
		check "outside a test, not root: refuses to run" {[lindex $r 0] == 1 && [string match "*run me through pkexec*" [lindex $r 2]]}
		set r [runenv {PKEXEC_UID 1000} set new]
		check "under pkexec (PKEXEC_UID) the test's variables are not read" {[lindex $r 0] == 1 && [string match "*run me through pkexec*" [lindex $r 2]]}
		is "  and nothing was touched" [snapshot] $before
		# a root that only spells / some other way, or a link to it, is / too
		file delete -force $T/slash; file link -symbolic $T/slash /
		foreach r [list /. /./ /.. /etc/.. //./ $T/slash $T/slash/] {
			set o [runenv [list RIBBON_HOSTNAME_ROOT $r] set new]
			check "  nor $r as its root (it is /)" {[lindex $o 0] == 2 && [string match "*needs RIBBON_HOSTNAME_ROOT*" [lindex $o 2]]}
		}
		file delete $T/slash
		is "  nor a root that is not there" [lindex [runenv [list RIBBON_HOSTNAME_ROOT $T/no-such-root] set new] 0] 2
		set ::AS {}
	} else {
		puts "  skip outside a test / under PKEXEC_UID (this is root: the helper would name the real system)"
	}

	# ---- a name
	fresh old
	set r [run set new-1]
	is "set new-1: done, and it says so" [lrange $r 0 1] {0 {the computer is now new-1}}
	is "  /etc/hostname is the name and a newline" [slurp $R/etc/hostname] "new-1\n"
	is "  it is a plain file, 0644" [list [file type $R/etc/hostname] [file attributes $R/etc/hostname -permissions]] {file 00644}
	is "  the running system was named, once" [calls] {new-1}
	is "  the kernel's name" [slurp $R/proc/sys/kernel/hostname] "new-1\n"
	is "  nothing else is left in /etc (no hosts was made, no temporary file)" [etc] {. .. hostname}
	foreach name [list a A9 x-y [string repeat b 63] 0] {
		fresh old
		is "a name: '[string range $name 0 20]'" [list [lindex [run set $name] 0] [slurp $R/etc/hostname]] [list 0 "$name\n"]
	}
	fresh ""
	is "no /etc/hostname yet: it is made" [list [lindex [run set first] 0] [slurp $R/etc/hostname]] [list 0 "first\n"]
	fresh old
	set old [pwd]; cd $T
	set r [exec sh -c "umask 077; RIBBON_HOSTNAME_TEST=1 RIBBON_HOSTNAME_ROOT='$R' RIBBON_HOSTNAME_CMD='$T/hostname' HLOG='$T/hostname.log' ROOT='$R' $SH '$helper' set masked"]
	cd $old
	is "under umask 077 the file is still 0644" [file attributes $R/etc/hostname -permissions] 00644

	# ---- /etc/hosts
	foreach {what hosts want} [list \
		"the 127.0.1.1 line is renamed" "127.0.0.1\tlocalhost\n127.0.1.1\told\n::1\tlocalhost\n" "127.0.0.1\tlocalhost\n127.0.1.1\tnew\n::1\tlocalhost\n" \
		"old.domain and old both, the spacing and the comment kept" "127.0.1.1   old.localdomain old   # this machine\n" "127.0.1.1   new.localdomain new   # this machine\n" \
		"the old name in other letters" "127.0.1.1 OLD Old.lan\n" "127.0.1.1 new new.lan\n" \
		"other names on the line stay" "127.0.1.1 old printer older\n" "127.0.1.1 new printer older\n" \
		"a 127.0.1.1 line for another name becomes the name's" "127.0.1.1 something-else # mine\n10.0.0.2 old\n" "127.0.1.1\tnew\t# mine\n10.0.0.2 old\n" \
		"  only the first, when there are two" "127.0.1.1 one\n127.0.1.1 two\n" "127.0.1.1\tnew\n127.0.1.1 two\n" \
		"with two, the one that has the old name" "127.0.1.1 one\n127.0.1.1 old\n" "127.0.1.1 one\n127.0.1.1 new\n" \
		"the old name on other lines stays (they are not this computer's line)" "192.168.1.5 old\n127.0.1.1 old\n# 127.0.1.1 old\n127.0.1.10 old\n" "192.168.1.5 old\n127.0.1.1 new\n# 127.0.1.1 old\n127.0.1.10 old\n" \
	] {
		fresh old $hosts
		set r [run set new]
		is "hosts: $what" [list [lindex $r 0] [slurp $R/etc/hosts]] [list 0 $want]
	}
	fresh old "127.0.0.1 localhost old\n"
	file stat $R/etc/hosts st; set ino $st(ino)
	run set new
	file stat $R/etc/hosts st
	check "hosts with no 127.0.1.1 line is not rewritten at all" {[slurp $R/etc/hosts] eq "127.0.0.1 localhost old\n" && $st(ino) == $ino}
	fresh old "127.0.1.1 old\n"
	file attributes $R/etc/hosts -permissions 0600
	run set new
	is "the new hosts is 0644, and no temporary file is left" [list [file attributes $R/etc/hosts -permissions] [etc]] {00644 {. .. hostname hosts}}
	fresh old
	spit $T/elsewhere "127.0.1.1 old\n"
	file link -symbolic $R/etc/hosts $T/elsewhere
	set r [run set new]
	is "a hosts that is a link is left alone, and so is what it points at" [list [lindex $r 0] [file type $R/etc/hosts] [slurp $T/elsewhere]] [list 0 link "127.0.1.1 old\n"]
	fresh saved "127.0.1.1 running\n"
	spit $R/proc/sys/kernel/hostname "running\n"
	run set new
	is "the running name counts as the old one too" [slurp $R/etc/hosts] "127.0.1.1 new\n"
	fresh old "127.0.1.1 old\n"
	spit $R/etc/hostname "not a name!\n"
	spit $R/proc/sys/kernel/hostname "(none)\n"
	set r [run set new]
	is "an old name that is no name is not looked for: the line becomes the name's" [list [lindex $r 0] [slurp $R/etc/hosts]] [list 0 "127.0.1.1\tnew\n"]

	# ---- links and things that are not files
	fresh old
	file delete $R/etc/hostname
	spit $T/victim "do not touch\n"
	file link -symbolic $R/etc/hostname $T/victim
	set r [run set new]
	is "/etc/hostname as a link: the link is replaced by a file, never followed" [list [lindex $r 0] [file type $R/etc/hostname] [slurp $R/etc/hostname] [slurp $T/victim]] [list 0 file "new\n" "do not touch\n"]
	fresh old
	file delete $R/etc/hostname
	file mkdir $R/etc/hostname
	set r [run set new]
	check "/etc/hostname as a directory: refused, the running system not named" {[lindex $r 0] == 1 && [calls] eq {} && [file isdirectory $R/etc/hostname] && [glob -nocomplain -directory $R/etc/hostname *] eq {}}
	fresh old
	file delete $R/etc/hostname
	file mkdir $T/adir
	file link -symbolic $R/etc/hostname $T/adir
	set r [run set new]
	check "  nor through a link to a directory" {[lindex $r 0] == 1 && [glob -nocomplain -directory $T/adir *] eq {}}

	# ---- /etc itself
	foreach {what mode} {"group-writable" 0775 "world-writable" 0757} {
		fresh old
		file attributes $R/etc -permissions $mode
		set r [run set new]
		check "an /etc that is $what: refused, nothing written or named" {[lindex $r 0] == 1 && [slurp $R/etc/hostname] eq "old\n" && [calls] eq {} && [etc] eq {. .. hostname}}
	}
	fresh old
	file rename $R/etc $R/etc.real
	file link -symbolic $R/etc $R/etc.real
	set r [run set new]
	check "an /etc that is a link: refused" {[lindex $r 0] == 1 && [slurp $R/etc.real/hostname] eq "old\n" && [calls] eq {}}
	fresh old
	file delete -force $R/etc
	check "no /etc: a failure, not a crash" {[lindex [run set new] 0] == 1}
	if {$me == 0 && ![catch {exec chown 65534 $R} ] } {
		fresh old
		exec chown 65534 $R/etc
		set r [run set new]
		check "an /etc owned by someone else: refused" {[lindex $r 0] == 1 && [slurp $R/etc/hostname] eq "old\n" && [calls] eq {}}
		exec chown 0 $R/etc $R
	} else { puts "  skip an /etc owned by someone else (needs root to make one)" }
	if {$me != 0} {
		fresh old
		file attributes $R/etc -permissions 0555
		set r [run set new]
		check "an /etc that cannot be written: a failure, the running system not named" {[lindex $r 0] == 1 && [calls] eq {} && [slurp $R/proc/sys/kernel/hostname] eq "old\n"}
		file attributes $R/etc -permissions 0755
	}

	# ---- the running system
	fresh old
	script $T/hostname {echo "$*" >> "$HLOG"; exit 1}
	set r [run set new]
	is "`hostname` fails: the kernel's file is written instead" [list [lindex $r 0] [slurp $R/proc/sys/kernel/hostname] [slurp $R/etc/hostname]] [list 0 "new\n" "new\n"]
	fresh old
	set r [runenv {RIBBON_HOSTNAME_CMD (unset)} set new]
	is "no `hostname` program: the kernel's file" [list [lindex $r 0] [slurp $R/proc/sys/kernel/hostname] [calls]] [list 0 "new\n" {}]
	fresh old "127.0.1.1 old\n"
	script $T/hostname {exit 1}
	file delete -force $R/proc
	set r [run set new]
	check "the running system cannot be named: a failure, and the files are as they were" {[lindex $r 0] == 1 && [slurp $R/etc/hostname] eq "old\n" && [slurp $R/etc/hosts] eq "127.0.1.1 old\n" && [etc] eq {. .. hostname hosts}}
	# the file cannot be put in place after the system was named (its new file vanishes): the old name comes back
	fresh old
	script $T/hostname {echo "$*" >> "$HLOG"; printf '%s\n' "$1" > "$ROOT/proc/sys/kernel/hostname"; rm -f "$ROOT"/etc/.hostname.*}
	set r [run set new]
	check "the file cannot be put in place: a failure, and the running system has its old name again" {[lindex $r 0] == 1 && [calls] eq {new old} && [slurp $R/proc/sys/kernel/hostname] eq "old\n" && [slurp $R/etc/hostname] eq "old\n"}

	# ---- an environment that means harm
	fresh old "127.0.1.1 old\n"
	file mkdir $T/evil
	foreach tool {mktemp mv rm chmod awk grep find id cat} { script $T/evil/$tool "echo $tool >> '$T/evil.log'; exit 1" }
	set r [runenv [list PATH $T/evil IFS "o" CDPATH $T/evil ENV $T/evil/rm] set new]
	is "PATH, IFS, CDPATH and ENV from the caller are not used" [list [lindex $r 0] [slurp $R/etc/hostname] [slurp $R/etc/hosts] [file exists $T/evil.log]] [list 0 "new\n" "127.0.1.1 new\n" 0]
}

set shells {}
# (by their full paths: one check runs the helper with a PATH that has no shell in it)
foreach s {sh dash {busybox sh} {bash --posix}} {
	set at [lindex [auto_execok [lindex $s 0]] 0]
	if {$at ne ""} { lappend shells [list $s [lreplace $s 0 0 $at]] }
}
foreach s $shells {
	lassign $s shown SH
	puts "  -- under $shown"
	suite
}

# ---- the real hostname program, in a UTS namespace of its own -------------------------------------
if {[auto_execok unshare] ne "" && [auto_execok hostname] ne "" && ![catch {exec unshare --uts true}]} {
	fresh old
	set before [string trim [exec hostname]]
	set cmd "RIBBON_HOSTNAME_TEST=1 RIBBON_HOSTNAME_ROOT='$R' RIBBON_HOSTNAME_CMD=hostname sh '$helper' set ribbon-test-name >/dev/null && hostname"
	if {[catch {exec unshare --uts sh -c $cmd} inside]} { set inside "failed: $inside" }
	is "the real `hostname` names a (private) running system" [string trim $inside] ribbon-test-name
	is "  and this machine's own name is as it was" [string trim [exec hostname]] $before
	is "  the fake root's file has it" [slurp $R/etc/hostname] "ribbon-test-name\n"
} else {
	puts "  skip the real hostname program (no unshare --uts here)"
}

file delete -force $T
if {$fails} { puts "hostname helper: $fails failed"; exit 1 }
puts "hostname helper: all checks passed"
