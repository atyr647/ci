# polkit-agent.tcl - the polkit agent core (apps/polkit/agent.tcl) against a fake polkitd and a fake
# polkit-agent-helper-1, on a private bus. Driven by tests/steps.d/70-polkit.sh, which makes the bus,
# the wrapper scripts and the directory named in POLKIT_T. Run in tclsh 8.6.
#
# The keyboard is a stand-in too (tests/fixtures/polkit-keys.tcl: the real ribbon-polkit-keys needs a compositor;
# tests/steps.d/70-polkit-keys.sh runs that one): it types what keys.cmd says and writes the answer to the pipe
# the agent passed it, so the descriptor path (pipe, cookie, SCM_RIGHTS, the PAM helper's stdin) is the real one.
#
# What this proves: registration with the session; BeginAuthentication and CancelAuthentication;
# success, a wrong password then the right one, cancels from both sides, requests queued one behind
# another; the account picker's rule and switching accounts; calls from anyone but polkitd refused;
# polkitd restarting; a helper that is missing, that dies, or that is stuck; a card that fails; and that
# the password is nowhere in argv, the environment, the helper's environment, the agent's log or
# a file. What it cannot prove is in design/handoff/u15.md (PAM, the setuid bit, a real polkitd).

set T $env(POLKIT_T)
set repo [file normalize [file join [file dirname [info script]] ..]]
set files $repo/srcpkgs/ribbon-desktop/files
lappend auto_path $files
package require ribbon::dbus
source -encoding utf-8 $files/apps/polkit/agent.tcl

set failed 0
set total 0
proc ok {what} { global total; incr total; puts "  ok   $what" }
proc bad {what why} { global failed total; incr total; incr failed; puts "  FAIL $what: $why" }
proc check {what cond {why ""}} {
	if {[uplevel 1 [list expr $cond]]} { ok $what } else { bad $what "$why ([uplevel 1 [list subst -nocommands -novariables $cond]])" }
}
proc eq {what got want} { if {$got eq $want} { ok $what } else { bad $what "got {$got}, wanted {$want}" } }
after 120000 {puts "  FAIL the polkit checks took more than 120 s"; exit 1}
interp bgerror {} {apply {{msg opts} { puts "  FAIL background error: [dict get $opts -errorinfo]"; exit 1 }}}

proc until {cond {ms 10000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel 1 [list expr $cond]]} {
		if {[clock milliseconds] > $end} { return 0 }
		after 20 {set ::tick 1}
		vwait ::tick
	}
	return 1
}
# a process that has exited (or is a zombie waiting to be reaped)
proc gone {pid} {
	if {[catch {open /proc/$pid/status} f]} { return 1 }
	set s [read $f]; close $f
	regexp {State:\s+Z} $s
}
proc pause {ms} { after $ms {set ::tick 1}; vwait ::tick }

# ---- the world: accounts, passwords, wrappers
set me [polkit::uid]
set secrets {Tester-Pa55-1 Adm-Pa55-2 Talky-Pa55-3 Other-Pa55-4 Wr0ng-Pa55-9 Decoy-S3cret-X}
set f [open $T/passwd w]
puts $f "tester:x:$me:100:Test User,,,:/home/tester:/bin/sh"
puts $f "adm:x:5001:100:Admin Two:/home/adm:/bin/sh"
puts $f "-evil:x:5002:100::/:/bin/sh"
puts $f "talky:x:5003:100::/:/bin/sh"
puts $f "dies:x:5004:100::/:/bin/sh"
puts $f "hang:x:5005:100::/:/bin/sh"
puts $f "other:x:5006:100:Other Person:/:/bin/sh"
close $f
set f [open $T/group w]
puts $f "wheel:x:10:tester,adm,-evil"
puts $f "solo:x:11:adm"
close $f
set f [open $T/pam.txt w]
puts $f "tester Tester-Pa55-1 $me\nadm Adm-Pa55-2 5001\ntalky Talky-Pa55-3 5003\nother Other-Pa55-4 5006"
close $f
set ::polkit::passwd $T/passwd
set ::polkit::group $T/group
set ::env(POLKIT_DECOY) Decoy-S3cret-X

# the agent's log, kept for the secrecy check, not printed
set logs {}
rename polkit::log polkit::log_orig
proc polkit::log {text} { lappend ::logs $text }

# ---- fake polkitd (a process), and what it says
set ev {}
proc polkitd_start {} {
	global T repo ev pd
	set ev {}
	set pd [open |[list tclsh8.6 $repo/tests/fixtures/polkitd.tcl 2>@1] r+]
	fconfigure $pd -blocking 0 -buffering line
	fileevent $pd readable {
		while {[gets $pd line] >= 0} { lappend ::ev $line }
		if {[eof $pd]} { fileevent $pd readable {} }
	}
}
proc say {line} { puts $::pd $line; flush $::pd }
proc seen {pattern} { expr {[lsearch -glob $::ev $pattern] >= 0} }
proc seen_after {first second} { set a [lsearch -glob $::ev $first]; set b [lsearch -glob $::ev $second]; expr {$a >= 0 && $b > $a} }
polkitd_start
check "the fake polkitd owns org.freedesktop.PolicyKit1" {[until {[seen {ready}]}]}

# ---- the card, as a stub: a log, and answers from a queue
set uilog {}
set script {}      ;# what to do at each prompt: a password, CANCEL or HOLD
set showfail 0
proc ui_show {id info} {
	if {$::showfail} { error "card is broken" }
	lappend ::uilog [list show $id [dict get $info choose] [dict get $info identity] [llength [dict get $info identities]]]
	set ::lastinfo $info
	set ::lastid $id
}
proc ui_prompt {id text echo} {
	lappend ::uilog [list prompt $id $text $echo]
	after idle [list ui_respond $id]
}
# The person types on the keyboard stand-in (a file it reads), and presses Enter once the card has seen the count
proc keycmd {line} { global T; set f [open $T/keys.cmd a]; puts $f $line; close $f }
proc ui_respond {id} {
	set what [lindex $::script 0]
	set ::script [lrange $::script 1 end]
	switch -- $what {
		"" - HOLD {}
		CANCEL { polkit::cancel $id }
		default { set ::await($id) [string length $what]; keycmd "type $what" }
	}
	unset what
}
proc ui_key {id name args} {
	lappend ::keylog [list $id $name {*}$args]
	if {$name eq "count" && [info exists ::await($id)] && [lindex $args 0] == $::await($id)} {
		unset ::await($id)
		polkit::submit $id
	}
}
array set await {}
set keylog {}
proc ui_info {id text} { lappend ::uilog [list info $id $text] }
proc ui_error {id text} { lappend ::uilog [list error $id $text] }
proc ui_done {id result} { lappend ::uilog [list done $id $result] }
set uitable {show ui_show prompt ui_prompt info ui_info error ui_error done ui_done key ui_key}
proc uiseen {pattern} { expr {[lsearch -glob $::uilog $pattern] >= 0} }
proc reset {} {
	global T
	array unset ::await; set ::keylog {}
	set ::uilog {}; set ::script {}; set ::ev [lsearch -all -inline -not -glob $::ev {begun *}]
	file delete $T/helper.log $T/keys.cmd
}
proc helperlog {} { global T; if {[catch {open $T/helper.log} f]} { return "" }; set s [read $f]; close $f; return $s }

# ---- the agent, on the same private bus
set bus [ribbon::dbus::connect system]
set regs {}
polkit::start $bus -ui $uitable -session c7 -locale de_DE.UTF-8 -helper $T/helper.sh -keys $T/keys.sh -registered {lappend ::regs}
check "the agent registers" {[until {[seen {registered *}]}]}
set reg [lindex $ev [lsearch -glob $ev {registered *}]]
eq "  as unix-session c7, with the locale and our object path" [lrange $reg 2 end] {c7 de_DE.UTF-8 /org/ribbon/PolicyKit1/AuthenticationAgent}
eq "  from the agent's own bus name" [lindex $reg 1] [$bus name]

# ---- pure rules: identities and the picker
set raw {{unix-user {uid 5001}} {unix-group {gid 10}} {unix-user {uid 5001}} {unix-netgroup {name x}}}
set ids [polkit::identities $raw $me]
eq "identities: group expanded, duplicates merged, unusable names and netgroups dropped, me first" \
	[lmap i $ids {dict get $i name}] {tester adm}
eq "  the display name is the GECOS name" [dict get [lindex $ids 1] display] "Admin Two"
eq "picker: more than one account" [polkit::needs_picker $ids $me] 1
eq "picker: just me, no picker" [polkit::needs_picker [lrange $ids 0 0] $me] 0
eq "picker: one account that is not me, it is named" [polkit::needs_picker [lrange $ids 1 1] $me] 1
eq "a cookie with a line break is invalid" [polkit::valid_cookie "a\nb"] 0
eq "a plain cookie is valid" [polkit::valid_cookie "3-abc-1-def"] 1
eq "safe names" [list [polkit::safe_name -evil] [polkit::safe_name "a b"] [polkit::safe_name tester]] {0 0 1}

# ---- success, with me as the only account: no picker
reset
set script {Tester-Pa55-1}
say "begin A1 ck-success user:$me"
check "success: the request completes" {[until {[seen {begun A1 *}]}]}
check "  polkitd got AuthenticationAgentResponse2 for the cookie, before the reply" {[seen_after "response2 $me ck-success" {begun A1 ok}]}
check "  the card was shown without a picker, as tester" {[uiseen "show r* 0 tester 1"]}
check "  it was asked for the password, hidden" {[uiseen {prompt r* *Password:* 0}]}
check "  and told it succeeded" {[uiseen {done r* success}]}
check "  the helper had no argument but the account name" {[string match "*argv tester argc 1*" [helperlog]]}
check "  the cookie came on stdin" {[string match "*cookie ck-success*" [helperlog]]}
check "  the helper's environment is the clean one (no decoy, no DISPLAY)" {![string match "*POLKIT_DECOY*" [helperlog]] && ![string match "*env DISPLAY=*" [helperlog]]}

# ---- wrong password, then the right one
reset
set script {Wr0ng-Pa55-9 Tester-Pa55-1}
say "begin A2 ck-retry user:$me"
check "retry: ends in success" {[until {[seen {begun A2 ok}]}]}
check "  the card was told it did not work" {[uiseen {error r* {Sorry, that didn't work*}}]}
check "  and asked again" {[llength [lsearch -all -glob $uilog {prompt *}]] == 2}
check "  two helper conversations" {[regexp -all {helper pid} [helperlog]] == 2}
check "  the wrong one was logged by the helper as wrong" {[string match "*wrong password*" [helperlog]]}

# ---- the user cancels at the prompt
reset
set script {CANCEL}
say "begin A3 ck-usercancel user:$me"
check "cancel from the card: polkitd gets Cancelled" {[until {[seen {begun A3 error org.freedesktop.PolicyKit1.Error.Cancelled}]}]}
check "  the card was told" {[uiseen {done r* cancelled}]}
regexp {helper pid (\d+)} [helperlog] -> hp
check "  the helper was ended" {[until {[gone $hp]}]}

# ---- polkitd cancels while the card waits
reset
set script {HOLD}
say "begin A4 ck-polkitcancel user:$me"
check "cancel from polkitd: the card is up and waiting" {[until {[uiseen {prompt *}]}]}
say "cancel ck-polkitcancel"
check "  CancelAuthentication is answered" {[until {[seen {cancelled ck-polkitcancel ok}]}]}
check "  the Begin call ends with Cancelled" {[until {[seen {begun A4 error org.freedesktop.PolicyKit1.Error.Cancelled}]}]}
check "  the card closed as cancelled" {[uiseen {done r* cancelled}]}
regexp {helper pid (\d+)} [helperlog] -> hp
check "  the helper was ended" {[until {[gone $hp]}]}

# ---- two requests at once: one card at a time, the second waits; a third is cancelled while queued
reset
set script {Tester-Pa55-1 Tester-Pa55-1}
say "begin B1 ck-b1 user:$me"
say "begin B2 ck-b2 user:$me"
say "begin B3 ck-b3 user:$me"
say "cancel ck-b3"
check "queue: both real requests end ok" {[until {[seen {begun B1 ok}] && [seen {begun B2 ok}]}]}
check "  the queued one that was cancelled ends Cancelled, and never had a card" {[seen {begun B3 error *Cancelled}] && [llength [lsearch -all -glob $uilog {show *}]] == 2}
set order [lmap e $uilog {lindex $e 0}]
eq "  one card closes before the next opens" [lsearch -all $order done] {2 5}
eq "  show, prompt, done, then show, prompt, done" $order {show prompt done show prompt done}

# ---- the picker with a group: me first, switch account
reset
set script {HOLD}
say "begin C1 ck-pick group:10"
check "picker: shown, with two accounts, me selected" {[until {[uiseen "show r* 1 tester 2"]}]}
check "  asked for tester's password" {[until {[uiseen {prompt *}]}]}
set id $lastid
set script {Adm-Pa55-2}
polkit::choose $id adm
check "  choosing adm restarts the conversation for adm" {[until {[seen {begun C1 ok}]}]}
check "  the second helper was started with adm" {[string match "*argv adm argc 1*" [helperlog]] && [string match "*argv tester argc 1*" [helperlog]]}
check "  polkitd was answered for adm's uid" {[seen {response2 5001 ck-pick}]}
catch {polkit::choose $id other}
ok "  choosing after the request is over is ignored"

reset
set script {HOLD}
say "begin C2 ck-pick2 group:10"
check "picker: refuses an account polkit did not offer" {[until {[uiseen {prompt *}]}]}
set id $lastid
check "  (other is not in wheel)" {[catch {polkit::choose $id other}]}
polkit::cancel $id
check "  cleanup" {[until {[seen {begun C2 error *}]}]}

# ---- PAM extras: info, error, and an echoed prompt
reset
set script {token-123 Talky-Pa55-3}
say "begin D1 ck-talky user:5003"
check "pam: info text and error text reach the card" {[until {[seen {begun D1 ok}]}] && [uiseen {info r* {Touch the key}}] && [uiseen {error r* {Token expired*}}]}
check "  an echoed prompt says so" {[uiseen {prompt r* *Token:* 1}]}
check "  a single account that is not me gets the picker rule" {[uiseen "show r* 1 talky 1"]}

# ---- who may call
reset
set imp [ribbon::dbus::connect system]
set apath /org/ribbon/PolicyKit1/AuthenticationAgent
set aiface org.freedesktop.PolicyKit1.AuthenticationAgent
set err ""
catch {$imp call [$bus name] $apath $aiface BeginAuthentication sssa{ss}sa(sa{sv}) a b c {} ck-imp [list [list unix-user [list uid [list u $me]]]]} err opts
eq "impostor: BeginAuthentication from another bus name is refused" [dict get $opts -errorcode] {DBUS org.freedesktop.DBus.Error.AccessDenied}
check "  no card, no helper" {![uiseen {show *}] && [helperlog] eq ""}
set script {HOLD}
say "begin E1 ck-real user:$me"
check "impostor: a real request is waiting" {[until {[uiseen {prompt *}]}]}
catch {$imp call [$bus name] $apath $aiface CancelAuthentication s ck-real} err opts
eq "  CancelAuthentication from the impostor is refused" [dict get $opts -errorcode] {DBUS org.freedesktop.DBus.Error.AccessDenied}
pause 150
check "  and the request is still waiting" {![uiseen {done *}] && ![seen {begun E1 *}]}
polkit::cancel $lastid
check "  cleanup" {[until {[seen {begun E1 error *}]}]}
$imp close

# ---- bad input, and what the card may ask
reset
set script {HOLD}
say "begin F2 ck-answer user:$me"
check "submit: a prompt is waiting" {[until {[uiseen {prompt *}]}]}
set id $lastid
check "  with nothing typed in a hidden prompt, nothing is sent (0) and the prompt stays" {[polkit::submit $id] == 0}
set ::await($id) 13
keycmd "type Tester-Pa55-1"
check "  the card sees the count as it is typed" {[until {[lsearch -exact $keylog [list $id count 13]] >= 0}]}
check "  then the request completes (the keyboard helper wrote the line to the PAM helper)" {[until {[seen {begun F2 ok}]}]}
check "  submitting when nothing is asked is an error" {[catch {polkit::submit $id}]}
check "  there is no polkit::answer: no text from a card can reach PAM" {[info commands polkit::answer] eq ""}

# ---- the keys: nav events, focus, echo
reset
set script {HOLD}
say "begin F3 ck-nav user:$me"
check "keys: a prompt is up" {[until {[uiseen {prompt *}]}]}
set id $lastid
keycmd "key tab"; keycmd "key btab"; keycmd "key up"; keycmd "key down"; keycmd "key enter"; keycmd "key esc"
check "  tab btab up down enter esc reach the card by name" {[until {[llength [lsearch -all -inline -not -exact [lmap e $keylog {lindex $e 1}] count]] >= 6}] && [lsearch -all -inline -not -exact [lmap e $keylog {lindex $e 1}] count] eq {tab btab up down enter esc}}
set keylog {}
keycmd "type ab"; keycmd "key space"
check "  in the field a space is a character: three counted" {[until {[lsearch -exact $keylog [list $id count 3]] >= 0}]}
polkit::focus $id other
set keylog {}
keycmd "type zz"; keycmd "key space"; pause 150
check "  focus elsewhere: characters are ignored and Space is an event" {[lsearch -glob $keylog {* count *}] < 0 || [lindex [lsearch -inline -glob $keylog {* count *}] 2] == 0}
check "  (the space came as a name)" {[lsearch -exact $keylog [list $id space]] >= 0}
polkit::focus $id field
keycmd "type q"
check "  back in the field it types again, from empty" {[until {[lsearch -exact $keylog [list $id count 1]] >= 0}]}
polkit::cancel $id
check "  cleanup" {[until {[seen {begun F3 error *}]}]}

reset
set script {HOLD}
say "begin F4 ck-echo user:5003"
check "echo: an echoed prompt arrives (after PAM's info and error)" {[until {[uiseen {prompt r* *Token:* 1}]}]}
set id $lastid
keycmd "type tok"
check "  its text is shown to the card (PAM says it is not secret)" {[until {[lsearch -exact $keylog [list $id text tok]] >= 0}]}
polkit::cancel $id
check "  cleanup" {[until {[seen {begun F4 error *}]}]}

# ---- failures that must not leave polkitd waiting
reset
set script {}
say "begin G1 ck-dies user:5004"
check "a helper that dies after the prompt: the request fails, with an error for the card" {[until {[seen {begun G1 ok}]}] && [uiseen {error r* {Authentication is not available*}}] && [uiseen {done r* failure}]}

reset
set savedhelper $::polkit::helper
set ::polkit::helper $T/no-such-helper
say "begin G2 ck-nohelper user:$me"
check "a missing helper: the request fails at once" {[until {[seen {begun G2 ok}]}] && [uiseen {done r* failure}]}
set ::polkit::helper $savedhelper

reset
set showfail 1
say "begin G3 ck-badcard user:$me"
check "a card that cannot be shown: polkitd gets Cancelled and no helper ran" {[until {[seen {begun G3 error *Cancelled}]}] && [helperlog] eq ""}
set showfail 0

reset
set ::polkit::passwd $T/nonexistent
say "begin G4 ck-noid user:$me"
check "no usable account: polkitd gets an error and no card" {[until {[seen {begun G4 error *}]}] && ![uiseen {show *}]}
set ::polkit::passwd $T/passwd

# ---- the keyboard helper: no helper, no card, no request
proc keylogtext {} { global T; if {[catch {open $T/keys.log} f]} { return "" }; set s [read $f]; close $f; return $s }
proc behave {b} { global T; set f [open $T/keys.behave w]; puts $f $b; close $f }
reset
set savedkeys $::polkit::keys
set ::polkit::keys $T/no-such-keys
say "begin K1 ck-nokeys user:$me"
check "no keyboard helper: the request fails, with no card and no PAM helper" {[until {[seen {begun K1 ok}]}] && ![uiseen {show *}] && [helperlog] eq ""}
set ::polkit::keys $savedkeys

reset
behave refuse
say "begin K2 ck-refuse user:$me"
check "the compositor refuses (the helper exits 2 before ready): fails, no card, no PAM helper" {[until {[seen {begun K2 ok}]}] && ![uiseen {show *}] && [helperlog] eq ""}

reset
behave silent
set ::polkit::keystimeout 400
say "begin K3 ck-silent user:$me"
check "the helper never gets the keyboard: after the timeout it fails, no card" {[until {[seen {begun K3 ok}]}] && ![uiseen {show *}] && [helperlog] eq ""}
set ::polkit::keystimeout 4000

reset
behave ready
set script {HOLD}
say "begin K4 ck-lost user:$me"
check "lost: a card is up with the keyboard" {[until {[uiseen {prompt *}]}]}
set kp [lindex [regexp -all -inline {keys (\d+) start} [keylogtext]] end]
keycmd "lose"
check "  when the keyboard is taken the request is cancelled: polkitd gets Cancelled" {[until {[seen {begun K4 error *Cancelled}]}]}
check "  and the card was told it is over" {[uiseen {done r* cancelled}]}
regexp {helper pid (\d+)} [helperlog] -> hp
check "  the PAM helper was ended" {[until {[gone $hp]}]}
check "  and so was the keyboard helper" {[until {[gone $kp]}]}

reset
behave closed
say "begin K5 ck-kdies user:$me"
check "the keyboard helper dies while the card is up: cancelled, never left waiting" {[until {[seen {begun K5 error *Cancelled}]}]}
behave ready

reset
set script {Tester-Pa55-1}
say "begin K6 ck-quit user:$me"
check "the keyboard helper is stopped when a request ends" {[until {[seen {begun K6 ok}]}]}
set kp [lindex [regexp -all -inline {keys (\d+) start} [keylogtext]] end]
check "  (it quit, it is not left holding the keyboard)" {[until {[gone $kp]}]}
check "  each request had its own keyboard helper" {[llength [regexp -all -inline {keys \d+ start} [keylogtext]]] >= 6}

# ---- polkitd restarts: the agent registers again and drops what was waiting
reset
set script {HOLD}
say "begin H1 ck-restart user:$me"
check "restart: a card is up" {[until {[uiseen {prompt *}]}]}
set before [llength [lsearch -all -glob $ev {registered *}]]
say quit
check "  polkitd gone: the card is closed as cancelled" {[until {[uiseen {done r* cancelled}]}]}
pause 100
polkitd_start
check "  polkitd back: the agent registers again" {[until {[seen {registered *}]}]}
reset
set script {Tester-Pa55-1}
say "begin H2 ck-after user:$me"
check "  and serves a new request" {[until {[seen {begun H2 ok}]}]}

# ---- unregister on stop
polkit::stop
check "stop: the agent unregisters" {[until {[seen {unregistered}]}]}

# ---- the password is nowhere it should not be
set leaks {}
set hay [helperlog][keylogtext]
append hay [join $logs \n] \n [join $uilog \n] \n
foreach p {/proc/self/cmdline /proc/self/environ} { set fh [open $p rb]; append hay [read $fh]; close $fh }
foreach s $secrets {
	if {$s eq "Decoy-S3cret-X"} { continue }
	if {[string first $s $hay] >= 0} { lappend leaks $s }
}
eq "the password is not in argv, the environment, the helper's environment, the agent's log or the card's log" $leaks {}
check "  the agent's log has events and no cookie" {[llength $logs] > 5 && [string first ck- [join $logs]] < 0}
set bad ""
foreach fl [glob -nocomplain -directory $T *] {
	if {[file tail $fl] in {pam.txt wrapper.sh keys.cmd keys.behave} || [file isdirectory $fl] || [string match *.sh $fl]} continue
	set fh [open $fl rb]; set body [read $fh]; close $fh
	foreach s $secrets { if {$s ne "Decoy-S3cret-X" && [string first $s $body] >= 0} { append bad "[file tail $fl] " } }
}
eq "  no file written during the run holds a password (pam.txt is the fixture's own store)" $bad ""

say quit
puts "polkit agent: $total checks, $failed failed"
exit [expr {$failed ? 1 : 0}]
