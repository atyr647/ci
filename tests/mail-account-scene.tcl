# mail-account-scene.tcl - the Mail window with its Add an account sheet open as Mail-A6-Account draws it (IMAP chosen,
# Maya Lind's address, lind.page's servers), on the fixture Maildirs at the boards' time. Run by apps/mail/main.tcl
# through RIBBON_MAIL_SCENE=this file, with the real accounts provider (accounts.tcl, ui-account.tcl).
#   RIBBON_MAIL_FIXTURES  a scratch folder: the fixture Maildirs are copied there
#   RIBBON_MAIL_SHOT      file: a screenshot of the window, then exit
#   RIBBON_SCENE          "" (Mail-A6-Account) | tested (Mail-A15-Tested) | refused (Mail-A16-Refused)
set dir $::env(RIBBON_MAIL_FIXTURES)
proc bgerror {msg} { puts stderr "mail-account-scene: $msg\n$::errorInfo"; exit 1 }
set here [file dirname [file normalize [info script]]]
file delete -force $dir
file mkdir $dir
file copy [file join $here fixtures maildir] [file join $dir Mail]
mail::store::set_root [file join $dir Mail]
mail::store::set_cache_root [file join $dir cache]
set mail::thread::tz +0100
set ::mailapp::now [clock scan "2026-11-07 10:42" -format "%Y-%m-%d %H:%M" -timezone +0100]
set ::mailapp::checked $::mailapp::now
set ::mailapp::open Personal
# no lookups from a picture
set mail::accounts::nameservers 127.0.0.1:1
set mail::accounts::urls {}
mailapp::show_view inboxes
mail::accounts::sheet {}
set mail::accounts::sh(edited) 1
foreach {f v} {name {Maya Lind} email maya@lind.page user maya@lind.page password abcdefghijkl imaphost imap.lind.page
	imapport 993 smtphost smtp.lind.page smtpport 465} { mail::accounts::Set $f $v }
focus $::mailapp::win
update
set mail::accounts::sh(focus) ""
switch -- [expr {[info exists ::env(RIBBON_SCENE)] ? $::env(RIBBON_SCENE) : ""}] {
	tested { mail::accounts::Say "IMAP and SMTP log in" 2 }
	refused { mail::accounts::Say [mail::accounts::Problem imap {error auth {}}] 1 }
}
mailapp::paint
update
if {[info exists ::env(RIBBON_MAIL_SHOT)]} {
	after 300 [list mailapp::shot_and_exit $::env(RIBBON_MAIL_SHOT)]
}
