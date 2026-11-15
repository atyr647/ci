# mail-sync-local.tcl - what Mail keeps on this computer while it syncs (apps/mail/sync.tcl over syncstore.tcl and the
# real Maildir store), against tests/mail-fixture-server.tcl on 127.0.0.1:
#   - a label that is not an IMAP atom (#reçus) stays local: it is never sent as a keyword (no truncated bytes on the
#     server), the server's flag changes do not take it off; an ASCII label (#ribbon) is sent as before
#   - a message sent while the IMAP server does not answer is in the local Sent at once; it stays there when Mail
#     quits (the account stopped), and goes to the server's Sent when Mail starts again, leaving one copy
#   - the password lookup may wait in the event loop: no second session is opened meanwhile
# Prints "ok ..." lines and "sync-local: ok"; any failure exits 1.   tclsh8.6 tests/mail-sync-local.tcl

set here [file dirname [file normalize [info script]]]
set app [file join $here .. srcpkgs ribbon-desktop files apps mail]
source -encoding utf-8 [file join $app sync.tcl]
source -encoding utf-8 [file join $app syncstore.tcl]
set PW "pa ss\"wörd"
set USER maya@lind.page
set fails 0
proc ok {name cond} {
	if {$cond} { puts "  ok   $name" } else { puts "  FAIL $name"; incr ::fails }
}
proc until {cond {ms 10000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 [list expr $cond]]} {
		if {[clock milliseconds] > $end} { return 0 }
		after 10 {set ::tick_ 1}
		vwait ::tick_
	}
	return 1
}
set T [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] mailsl[pid]]
file delete -force $T
mail::store::set_root $T/Mail
mail::store::set_cache_root $T/cache

set f [open [list | [info nameofexecutable] [file join $here mail-fixture-server.tcl] -plainauth 1 2>@stderr] r+]
fconfigure $f -translation lf -encoding utf-8 -buffering line
gets $f line
lassign $line - - IMAP - - - SMTP
proc ctl {args} {
	puts $::f $args
	set ::ctl_ ""
	fileevent $::f readable {set ::ctl_ [gets $::f]}
	until {$::ctl_ ne ""} 10000
	fileevent $::f readable {}
	string range $::ctl_ 2 end
}
after 120000 {puts "  FAIL timed out"; exec kill [pid $f]; exit 1}

set lookups 0
proc pw {a} {
	incr ::lookups
	# a lookup that waits in the event loop, as the Secret Service's does
	after 200 {set ::pwwait 1}
	vwait ::pwwait
	return $::PW
}
proc opts {} {
	list -imap [list -host 127.0.0.1 -port $::IMAP -security none -user $::USER] \
		-smtp [list -host 127.0.0.1 -port $::SMTP -security none -user $::USER] \
		-password ::pw -store ::mail::syncstore::cmd -poll 600000 -retry {300}
}
proc idle {} { expr {[dict get [mail::sync::status p] state] in {idle waiting}} }

ctl deliver INBOX {} [binary encode base64 "From: anna@hearth.studio\r\nTo: maya@lind.page\r\nSubject: Labels\r\nMessage-ID: <l1@x>\r\n\r\nHi.\r\n"]
mail::sync::start p [opts]
# a check asked for while the password is still being looked up
after 50 {mail::sync::check p}
ok "the account syncs" [until {[idle] && [llength [mail::store::keys p Inbox]] == 1}]
ok "a check during the password lookup opens no second session (one lookup)" [expr {$lookups == 1}]

# ---- labels ----
set key [lindex [mail::store::keys p Inbox] 0]
mail::store::add_label $key ribbon
mail::store::add_label $key reçus
mail::sync::push p INBOX
until {[string match "*ribbon*" [lindex [ctl dump INBOX] 0 1]]} 8000
set flags [lindex [ctl dump INBOX] 0 1]
ok "an ASCII label goes to the server as a keyword ($flags)" [expr {"ribbon" in $flags}]
ok "a label that is not an IMAP atom is not sent (no reçus, no cut bytes)" [expr {[llength [lsearch -all -regexp $flags {^re}]] == 0}]
ok "and the server sees no pending change for it again" [expr {[mail::syncstore::cmd pending p INBOX] eq ""}]
set uid [lindex [ctl dump INBOX] 0 0]
ctl flags INBOX $uid {\\Seen \\Flagged}
mail::sync::check p
until {[string match *F* [mail::store::flags [lindex [mail::store::keys p Inbox] 0]]]} 8000
set key [lindex [mail::store::keys p Inbox] 0]
set labels [mail::store::labels $key]
ok "the server's flags replace the others (ribbon off, flagged on): $labels" [expr {"ribbon" ni $labels && [string match *F* [mail::store::flags $key]]}]
ok "but the local-only label stays" [expr {"reçus" in $labels}]

# ---- a message sent while IMAP does not answer ----
until {[idle]} 5000
ctl mute on
ctl kick
set msg "From: Maya Lind <maya@lind.page>\r\nTo: anna@hearth.studio\r\nSubject: Offline copy\r\nMessage-ID: <o1@lind.page>\r\n\r\nSent while IMAP was away.\r\n"
set ::sent ""
mail::sync::send p maya@lind.page anna@hearth.studio $msg {apply {{args} {set ::sent $args}}}
ok "SMTP takes the message" [until {$::sent ne ""} 10000]
proc local_sent {} {
	set out {}
	foreach k [mail::store::keys p Sent] { if {[string match "*Offline copy*" [mail::store::read $k]]} { lappend out $k } }
	return $out
}
ok "its copy is in the local Sent at once" [expr {[llength [local_sent]] == 1}]
ok "listed as not yet on the server" [expr {[llength [mail::syncstore::cmd outboxed p]] == 2}]
# Mail quits before IMAP comes back
mail::sync::stop p
ok "the copy stays when Mail quits" [expr {[llength [local_sent]] == 1}]
ok "and the server's Sent does not have it" [expr {![llength [ctl dump Sent]]}]
ctl mute off
# Mail starts again (a new run: the store is read from disk)
array unset ::mail::syncstore::st
array unset ::mail::syncstore::names
mail::sync::start p [opts]
ok "the next start sends the copy to the server's Sent" [until {[llength [ctl dump Sent]] == 1} 15000]
ok "with \\Seen" [expr {"\\Seen" in [lindex [ctl dump Sent] 0 1]}]
ok "and the local Sent has it once (the server's copy)" [until {[idle] && [llength [local_sent]] == 1 && [mail::syncstore::cmd outboxed p] eq ""} 15000]
set k [lindex [local_sent] 0]
ok "that copy is the synced one" [expr {[lindex $k 2] in [lmap e [dict values [dict get [mail::syncstore::Load p Sent] map]] {lindex $e 0}]}]
mail::sync::stop p
ok "no second copy on the server after another start" [expr {[llength [ctl dump Sent]] == 1}]

exec kill [pid $f]
file delete -force $T
if {$fails} { puts "sync-local: $fails failed"; exit 1 }
puts "sync-local: ok"
exit 0
