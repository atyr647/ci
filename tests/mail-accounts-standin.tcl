# mail-accounts-standin.tcl - a stand-in for Mail's accounts provider (apps/mail/accounts.tcl, U42) in Mail's UI
# tests: the fixture's three accounts with their addresses, and a sheet that records that it was asked for. With
# MAIL_TEST_IMAP / MAIL_TEST_SMTP (ports on 127.0.0.1) the Personal account syncs with tests/mail-fixture-server.tcl.
namespace eval ::mail::accounts {
	variable asked 0
}
proc ::mail::accounts::configured {} {
	set out [list Personal [dict create -address maya@lind.page -fullname "Maya Lind"] \
		Studio [dict create -address maya@hearth.studio -fullname "Maya Lind"] \
		ribbon-dev [dict create -address maya@lind.page -fullname "Maya Lind"]]
	if {[info exists ::env(MAIL_TEST_IMAP)]} {
		set pw [list apply {{a} { return "pa ss\"wörd" }}]
		dict set out Personal -imap [list -host 127.0.0.1 -port $::env(MAIL_TEST_IMAP) -security none -user maya@lind.page]
		dict set out Personal -smtp [list -host 127.0.0.1 -port $::env(MAIL_TEST_SMTP) -security none -user maya@lind.page]
		dict set out Personal -password $pw
		dict set out Personal -poll 600000
		dict set out Personal -retry {300}
		set out [dict filter $out key Personal]
	}
	return $out
}
proc ::mail::accounts::sheet {done} {
	variable asked
	incr asked
}
