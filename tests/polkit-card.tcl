# polkit-card.tcl - ribbon-polkit's own main.tcl with the REAL card (apps/polkit/card.tcl) under xvfb, against the fake
# polkitd and PAM helper of tests/polkit-agent.tcl and the keyboard stand-in (tests/fixtures/polkit-keys.tcl).
# The driver here is the person: it types through the stand-in's command file and watches the card through the hook
# (tests/polkit-card-hook.tcl). Run by tests/steps.d/70-polkit.sh after polkit-agent.tcl, same T.
# Proves: the card appears only once the keyboard helper is ready; dots follow what is typed; Enter sends it; a wrong
# password shows the message and asks again; the picker and the arrow keys; Tab moves the focus and the helper's mode;
# Escape and the mouse cancel; losing the keyboard cancels; no keyboard helper means no card; and that neither password
# is anywhere in the agent's process memory after it was used.
set T $env(POLKIT_T)
set repo [file normalize [file join [file dirname [info script]] ..]]
set failed 0
proc ok {what} { puts "  ok   $what" }
proc bad {what why} { global failed; incr failed; puts "  FAIL $what: $why" }
after 150000 {puts "  FAIL the card run took more than 150 s"; stop_agent; exit 1}
# the agent runs until it is stopped (losing polkitd it waits for it to come back): stop it, and with it xvfb-run
proc stop_agent {} {
	global wish hookpid
	if {![info exists wish]} return
	if {$hookpid ne ""} { catch {exec kill -TERM $hookpid} }
	until {[eof $wish]} 5000
	if {![eof $wish]} { catch {exec kill -KILL {*}[pid $wish]} }
	catch {close $wish}
	unset wish
}
proc until {cond {ms 20000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel 1 [list expr $cond]]} {
		if {[clock milliseconds] > $end} { return 0 }
		after 30 {set ::tick 1}
		vwait ::tick
	}
	return 1
}
proc check {what cond} { if {[uplevel 1 [list expr $cond]]} { ok $what } else { bad $what "no ([uplevel 1 [list subst -nocommands -novariables $cond]]) output tail: [string range $::out end-600 end]" } }
proc keys {line} { global T; set f [open $T/keys.cmd a]; puts $f $line; close $f }
proc hookcmd {line} { global T; set f [open $T/hook.cmd a]; puts $f $line; close $f }
proc behave {b} { global T; set f [open $T/keys.behave w]; puts $f $b; close $f }
# only the states since the request began (an earlier card must not satisfy a later check)
set mark 0
proc st {pattern} { expr {[lsearch -glob [lrange $::states $::mark end] $pattern] >= 0} }
proc last {} { lindex $::states end }
# the helper logs each mode it is sent ("keys PID mode text"): keys typed before the new mode lands are dropped
# (nav mode), so the driver waits for the log to show it, rather than typing as soon as the card changes
proc mode_count {} {
	if {[catch {open $::T/keys.log} f]} { return 0 }
	set n [llength [lsearch -all -glob [split [read $f] \n] {* mode text}]]
	close $f
	return $n
}

set me [exec id -u]
set f [open $T/passwd w]; puts $f "tester:x:$me:100:Test User,,,:/home/tester:/bin/sh\nadm:x:5001:100:Admin Two:/home/adm:/bin/sh"; close $f
set f [open $T/group w]; puts $f "wheel:x:10:tester,adm"; close $f
set f [open $T/pam.txt w]; puts $f "tester Tester-Pa55-1 $me\nadm Adm-Pa55-2 5001"; close $f
file delete $T/keys.cmd $T/hook.cmd $T/hook.go $T/keys.behave $T/helper.log

set ev {}
set pd [open |[list tclsh8.6 $repo/tests/fixtures/polkitd.tcl 2>@1] r+]
fconfigure $pd -blocking 0 -buffering line
fileevent $pd readable { while {[gets $pd line] >= 0} { lappend ::ev $line }; if {[eof $pd]} { fileevent $pd readable {} } }
proc seen {pattern} { expr {[lsearch -glob $::ev $pattern] >= 0} }
proc say {line} { puts $::pd $line; flush $::pd }
until {[seen ready]}

set env(XDG_SESSION_ID) c9
set env(RIBBON_POLKIT_TEST) $repo/tests/polkit-card-hook.tcl
set env(RIBBON_POLKIT_HELPER) $T/helper.sh
set env(RIBBON_POLKIT_KEYS) $T/keys.sh
set env(RIBBON_POLKIT_PASSWD) $T/passwd
set env(RIBBON_POLKIT_GROUP) $T/group
set env(POLKIT_FIX) $T
set env(HOME) $T
set env(XDG_CACHE_HOME) $T/cache
set env(RIBBON_POLKIT_CARETFIX) on
set out ""; set states {}; set hookpid ""
set wish [open |[list timeout -k 5 130 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 \
	$repo/srcpkgs/ribbon-desktop/files/apps/polkit/main.tcl -name ribbon-polkit 2>@1] r]
fconfigure $wish -blocking 0
fileevent $wish readable {
	while {[gets $wish line] >= 0} {
		append ::out $line\n
		if {[regexp {^state (.*)} $line -> s]} { lappend ::states $s }
		regexp {^hook pid (\d+)} $line -> ::hookpid
	}
}
check "ribbon-polkit registers with polkitd from its own process, card and agent loaded" {[until {[seen {registered *}]}]}

# 1. one account (me): no picker; a wrong password, then the right one
set mark [llength $states]; say "begin P1 ck-card-1 user:$me"
check "the card appears once the keyboard helper is ready, with no picker" {[until {[st {up=1 choose=0 *prompt=1*}]}]}
check "  the prompt is the usual one: nothing written in the field" {[st {*ph=}] || [st {*ph= }]}
keys "type Wr0ng-Pa55-9"
check "  the field follows what is typed: twelve dots" {[until {[st {* count=12 *}]}]}
set m0 [mode_count]
keys "key enter"
check "  Enter sends it; the card is busy, then shows the message and asks again" {[until {[st {* msg=error *}]}] && [until {[st {* count=0 busy=0 *msg=error*}]}]}
check "  the helper is in text mode again for the next try" {[until {[mode_count] > $m0}]}
keys "type Tester-Pa55-1"
check "  thirteen dots" {[until {[st {* count=13 *}]}]}
keys "key enter"
check "  the right password: polkitd is answered and the card closes" {[until {[seen {begun P1 ok}]}] && [until {[st {up=0}]}]}

# 2. a group: the picker, arrows, Tab
set mark [llength $states]; say "begin P2 ck-card-2 group:10"
check "the picker is shown for two accounts, the first chosen, focus in the field" {[until {[st {up=1 choose=1 chosen=tester count=0 busy=0 focus=pw*}]}]}
keys "key btab"
check "  Shift+Tab moves focus to the picker (the helper stops collecting characters)" {[until {[st {* focus=pick *}]}]}
keys "key down"
check "  Down chooses the next account: the conversation restarts for it" {[until {[st {* chosen=adm *}]}] && [until {[st {* chosen=adm count=0 busy=0 focus=pick*prompt=1*}]}]}
keys "type zzz"
set m0 [mode_count]
keys "key tab"
check "  Tab goes back to the field; typing in the picker was ignored (count stays 0)" {[until {[st {* chosen=adm count=0 busy=0 focus=pw*}]}]}
check "  the helper types into the field again" {[until {[mode_count] > $m0}]}
keys "type Adm-Pa55-2"
check "  the account's password, Enter" {[until {[st {* count=10 *}]}]}
keys "key enter"
check "  authenticated as the second account" {[until {[seen {begun P2 ok}]}] && [seen {response2 5001 ck-card-2}]}

# 3. Escape and the mouse cancel
set mark [llength $states]; say "begin P3 ck-card-3 user:$me"
check "Escape: the card is up" {[until {[st {up=1 choose=0 *count=0*prompt=1*}]}]}
keys "key esc"
check "  Escape cancels the request" {[until {[seen {begun P3 error *Cancelled}]}] && [until {[st {up=0}]}]}
set mark [llength $states]; say "begin P4 ck-card-4 user:$me"
check "the mouse: the card is up" {[until {[st {up=1 choose=0 *count=0*prompt=1*}]}]}
hookcmd "click cancel"
check "  a click on Cancel cancels" {[until {[seen {begun P4 error *Cancelled}]}] && [until {[st {up=0}]}]}

# 4. the keyboard is taken: cancelled
set mark [llength $states]; say "begin P5 ck-card-5 user:$me"
check "keyboard lost: the card is up" {[until {[st {up=1 choose=0 *count=0*prompt=1*}]}]}
keys "lose"
check "  the request is cancelled and the card goes" {[until {[seen {begun P5 error *Cancelled}]}] && [until {[st {up=0}]}]}

# 5. no keyboard helper: no card
set nstates [llength $states]
behave refuse
set mark [llength $states]; say "begin P6 ck-card-6 user:$me"
check "no keyboard helper (the compositor refuses): the request fails and no card was ever shown" {[until {[seen {begun P6 ok}]}] && [llength [lsearch -all -glob [lrange $states $nstates end] {up=1*}]] == 0}
behave ready

# 6. the passwords are not in the agent's memory, which held the card and every conversation
set mark [llength $states]; say "begin P7 ck-card-7 user:$me"
until {[st {up=1 *count=0*prompt=1*}]}
keys "type Tester-Pa55-1"
until {[st {* count=13 *}]}
keys "key enter"
check "one more request, authenticated" {[until {[seen {begun P7 ok}]}]}
hookcmd "wait"
until {[string match "*waiting*" $out]}
# Read here, not by a helper program: with Yama's ptrace_scope 1 (Ubuntu's default) only root or an ancestor of the
# agent may read its memory, and this script is one (tclsh -> timeout -> xvfb-run -> wish)
proc memscan {pid words} {
	foreach w $words { dict set hits $w 0 }
	set m [open /proc/$pid/maps]; set maps [split [read $m] \n]; close $m
	set mem [open /proc/$pid/mem rb]
	fconfigure $mem -buffering none
	foreach line $maps {
		lassign $line range perm
		if {$range eq "" || [string first r $perm] < 0 || [string match {*\[vvar*} $line] || [string match {*\[vsyscall\]*} $line]} continue
		scan $range %llx-%llx s e
		if {[catch {seek $mem $s; read $mem [expr {$e - $s}]} data]} continue
		foreach w $words {
			set n 0; set at 0
			while {[set at [string first $w $data $at]] >= 0} { incr n; incr at }
			dict incr hits $w $n
		}
	}
	close $mem
	set out {}
	dict for {w n} $hits { lappend out $w=$n }
	join $out
}
if {$hookpid eq ""} {
	bad "the passwords are not in the agent's memory" "the hook did not say its pid"
} elseif {[catch {memscan $hookpid {Tester-Pa55-1 Wr0ng-Pa55-9 Adm-Pa55-2 zzz}} scan]} {
	bad "the passwords are not in the agent's memory" "its memory could not be read: $scan"
} else {
	puts "     memory scan of the agent (pid $hookpid): $scan"
	if {[regexp {Tester-Pa55-1=0 Wr0ng-Pa55-9=0 Adm-Pa55-2=0} $scan]} {
		ok "none of the passwords typed is anywhere in the agent's memory (they never entered Tcl or Tk)"
	} else { bad "the passwords are not in the agent's memory" $scan }
}
set f [open $T/hook.go w]; close $f
until {[string match "*FAIL*" $out] || [eof $wish]} 3000
stop_agent
if {[string match "*FAIL*" $out]} { incr failed }
set haystack $out
foreach fl {helper.log keys.log} { catch { set fh [open $T/$fl]; append haystack [read $fh]; close $fh } }
foreach s {Tester-Pa55-1 Wr0ng-Pa55-9 Adm-Pa55-2} {
	if {[string first $s $haystack] >= 0} { bad "no password in the agent's output, the helper's argv and environment or the keyboard log" $s }
}
if {$failed == 0} { ok "no password in the agent's output, the helpers' argv and environment, or the keyboard stand-in's log" }
say quit
puts "polkit card: $failed failed"
exit [expr {$failed ? 1 : 0}]
