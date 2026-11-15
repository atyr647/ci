# mail-account-flow.tcl - adding an account through Mail's window (Mail-A6-Account), end to end: apps/mail/main.tcl
# runs this through RIBBON_MAIL_SCENE with the real accounts provider (accounts.tcl, ui-account.tcl); the Secret
# Service is tests/mail-secret-service.tcl on the private bus in DBUS_SESSION_BUS_ADDRESS; the servers are
# tests/mail-fixture-server.tcl on 127.0.0.1. Every action is a press on the window's canvas where the sheet draws it,
# and the text goes into the sheet's fields with key events. Prints "account-flow: ok" at the end.
set here [file dirname [file normalize [info script]]]
proc bgerror {msg} { puts stderr "mail-account-flow: $msg\n$::errorInfo"; exit 1 }
set fails 0
proc ok {name cond} {
	if {$cond} { puts "  ok   $name" } else { puts "  FAIL $name"; incr ::fails }
}
proc until {cond ms} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel 1 [list expr $cond]] && [clock milliseconds] < $end} {
		after 50 {set ::tick 1}
		vwait ::tick
	}
	uplevel 1 [list expr $cond]
}
set f [open [list | tclsh8.6 [file join $here mail-fixture-server.tcl] -plainauth 1 2>@stderr] r+]
fconfigure $f -translation lf -encoding utf-8 -buffering line
gets $f line
set ports [lrange $line 1 end]
proc ctl {args} {
	puts $::f $args
	set ::ctl_ ""
	fileevent $::f readable {set ::ctl_ [gets $::f]}
	until {$::ctl_ ne ""} 10000
	fileevent $::f readable {}
	string range $::ctl_ 2 end
}
proc finish {} {
	catch {exec kill [pid $::f]}
	if {$::fails} { puts "account-flow: $::fails failed"; exit 1 }
	puts "account-flow: ok"
	exit 0
}
after 150000 {puts "  FAIL timed out"; set ::fails 1; finish}

set dir $::env(RIBBON_MAIL_FIXTURES)
file delete -force $dir
file mkdir [file join $dir Mail]
mail::store::set_root [file join $dir Mail]
mail::store::set_cache_root [file join $dir cache]
set ::env(XDG_CONFIG_HOME) [file join $dir config]
# lookups go nowhere: an address's servers are the guess
set mail::accounts::nameservers 127.0.0.1:1
set mail::accounts::urls {}

# the press at the middle of the topmost hit whose script matches PATTERN
proc click {pattern} {
	update
	foreach h [lreverse $::ui::hits] {
		lassign $h x0 y0 x1 y1 script
		if {[string match $pattern $script]} {
			mailapp::press [expr {($x0 + $x1) / 2.0}] [expr {($y0 + $y1) / 2.0}]
			update
			return 1
		}
	}
	return 0
}
# typing into a field of the sheet: focus, the text, and a key release per character
proc type {field text} {
	set w [mail::accounts::W $field]
	focus -force $w
	update
	$w delete 0 end
	foreach ch [split $text ""] {
		$w insert insert $ch
		event generate $w <KeyRelease> -keysym [expr {[regexp {^[A-Za-z0-9]$} $ch] ? $ch : "at"}]
	}
	update
}
proc val {field} { [mail::accounts::W $field] get }

mailapp::show_view inboxes
mailapp::paint
ok "the rail's Accounts row has the add button" [click ::mailapp::add_account]
ok "it opens the Add an account sheet" [mail::accounts::sheet_up]
ok "the window's own hits are covered while it is open" [expr {[lsearch -exact -index 4 $::ui::hits ::mail::accounts::Nothing] >= 0}]
set before $::mailapp::state(conv)
mailapp::press 250 400
ok "a press on the list under it does nothing" [expr {$::mailapp::state(conv) eq $before && [mail::accounts::sheet_up]}]
ok "the sheet's fields are placed" [expr {[winfo ismapped [mail::accounts::W email]] && [winfo ismapped [mail::accounts::W password]]}]
ok "IMAP is chosen at first" [expr {$mail::accounts::sh(provider) eq "imap"}]

# a named provider fills in its servers
click {::mail::accounts::Provider gmail}
ok "Gmail fills in Gmail's servers" [expr {[val imaphost] eq "imap.gmail.com" && [val imapport] eq "993" && [val smtphost] eq "smtp.gmail.com" && [val smtpport] eq "465"}]
click {::mail::accounts::Provider icloud}
ok "iCloud's SMTP is STARTTLS on 587" [expr {[val smtphost] eq "smtp.mail.me.com" && [val smtpport] eq "587" && $mail::accounts::sec(smtp) eq "starttls"}]
click {::mail::accounts::Provider imap}

type name "Maya Lind"
type email maya@lind.page
ok "the user name follows the address" [expr {[val user] eq "maya@lind.page"}]
focus -force [mail::accounts::W password]
ok "leaving Email looks up the servers (here: the guess)" [until {[val imaphost] eq "imap.lind.page" && [val smtphost] eq "smtp.lind.page"} 15000]

# the servers: the fixture's, plain text on this computer
type imaphost 127.0.0.1
type imapport [dict get $ports imap]
type smtphost 127.0.0.1
type smtpport [dict get $ports smtp]
click {::mail::accounts::Pop imapsec}
ok "the IMAP security menu opens" [expr {$mail::accounts::sh(pop) eq "imapsec"}]
ok "it offers SSL/TLS, STARTTLS and None" [click {::mail::accounts::Security imap none}]
ok "None is chosen, the menu closes, the port stays as typed" [expr {$mail::accounts::sec(imap) eq "none" && $mail::accounts::sh(pop) eq "" && [val imapport] eq [dict get $ports imap]}]
click {::mail::accounts::Pop smtpsec}
click {::mail::accounts::Security smtp none}
ok "and for SMTP" [expr {$mail::accounts::sec(smtp) eq "none"}]
click {::mail::accounts::Pop imapauth}
ok "the login menu has Normal password" [expr {$mail::accounts::sh(pop) eq "imapauth"}]
mailapp::escape
ok "Escape closes the menu, not the sheet" [expr {$mail::accounts::sh(pop) eq "" && [mail::accounts::sheet_up]}]

# Test connection
click ::mail::accounts::Add
ok "Add account with no password says so" [expr {$mail::accounts::sh(status) eq "The password is empty" && $mail::accounts::sh(bad) == 1}]
type password wrong
click ::mail::accounts::Test
ok "Test connection with a wrong password: refused" [until {[string match "IMAP: wrong user name or password" $mail::accounts::sh(status)]} 20000]
ok "shown as a failure" [expr {$mail::accounts::sh(bad) == 1}]
type password "pa ss\"wörd"
click ::mail::accounts::Eye
ok "the eye shows the password" [expr {[[mail::accounts::W password] cget -show] eq ""}]
click ::mail::accounts::Test
ok "Test connection logs in to both, shown as an answer (Mail-A15-Tested)" [until {$mail::accounts::sh(status) eq "IMAP and SMTP log in" && $mail::accounts::sh(bad) == 2} 20000]
ok "and saves nothing" [expr {![file exists [file join $dir config ribbon mail-accounts.conf]]}]

# Add account
ctl deliver INBOX {} [binary encode base64 "From: Anna Berg <anna@hearth.studio>\r\nTo: maya@lind.page\r\nSubject: Welcome\r\nMessage-ID: <w1@hearth.studio>\r\nDate: Sat, 7 Nov 2026 10:31:00 +0100\r\n\r\nHello.\r\n"]
click ::mail::accounts::Add
ok "Add account closes the sheet once both servers log in" [until {![mail::accounts::sheet_up]} 20000]
set acc [mail::accounts::configured]
ok "the account is in the accounts file, named by its address" [expr {[dict keys $acc] eq "maya@lind.page" && [dict get $acc maya@lind.page -fullname] eq "Maya Lind"}]
set fh [open [file join $dir config ribbon mail-accounts.conf]]; set text [read $fh]; close $fh
ok "without its password" [expr {[string first "pa ss" $text] < 0}]
ok "the password is in the Secret Service" [expr {[mail::accounts::password maya@lind.page] eq "pa ss\"wörd"}]
ok "the account is open in the rail" [expr {"maya@lind.page" in $::mailapp::open}]
ok "and syncs: the server's mail arrives" [until {[llength [mail::store::keys maya@lind.page Inbox]] == 1} 30000]
ok "the sheet's fields are gone" [expr {![winfo exists [mail::accounts::W email]]}]

# the same address again; Cancel and Escape
mailapp::add_account
type email maya@lind.page
focus -force [mail::accounts::W name]
type password x
click ::mail::accounts::Add
ok "the same address again is refused" [until {$mail::accounts::sh(status) eq "maya@lind.page is in Mail already"} 5000]
click ::mail::accounts::Cancel
ok "Cancel closes the sheet" [expr {![mail::accounts::sheet_up]}]
mailapp::add_account
event generate $::mailapp::win <Control-n>
update
ok "Ctrl+N does nothing while the sheet is open" [expr {![winfo exists .compose]}]
mailapp::escape
ok "Escape closes the sheet" [expr {![mail::accounts::sheet_up]}]
# A login still under way belongs to its own sheet: a run left by Cancel does not act in the next sheet, and the
# password saved is the one that logged in (the servers' answers held back here by a stand-in for test)
rename ::mail::accounts::test ::mail::accounts::test_real
set ::held {}
proc ::mail::accounts::test {d pw cmd} { lappend ::held [list $pw $cmd] }
proc fill {addr pw} {
	type name "Bo Lind"
	type email $addr
	type user $addr
	type imaphost 127.0.0.1
	type imapport [dict get $::ports imap]
	type smtphost 127.0.0.1
	type smtpport [dict get $::ports smtp]
	set mail::accounts::sec(imap) none
	set mail::accounts::sec(smtp) none
	type password $pw
}
mailapp::add_account
fill bo@lind.page first
click ::mail::accounts::Add
click ::mail::accounts::Cancel
mailapp::add_account
fill cy@lind.page second
click ::mail::accounts::Test
{*}[lindex $::held 0 1] {imap ok smtp ok}
update
ok "a login left by Cancel adds nothing when it answers" [expr {"bo@lind.page" ni [dict keys [mail::accounts::configured]]}]
ok "and the open sheet still waits for its own test" [expr {[mail::accounts::sheet_up] && $mail::accounts::sh(status) eq "Testing…"}]
{*}[lindex $::held 1 1] {imap ok smtp ok}
update
ok "its own answer is shown" [expr {$mail::accounts::sh(status) eq "IMAP and SMTP log in"}]
click ::mail::accounts::Add
type password changed
{*}[lindex $::held 2 1] {imap ok smtp ok}
update
ok "Add account saves the password that logged in, not one typed meanwhile" \
	[expr {"cy@lind.page" in [dict keys [mail::accounts::configured]] && [mail::accounts::password cy@lind.page] eq "second"}]
rename ::mail::accounts::test {}
rename ::mail::accounts::test_real ::mail::accounts::test
finish
