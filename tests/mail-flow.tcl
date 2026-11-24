# mail-flow.tcl - Mail's send and receive, end to end through the app (apps/mail/main.tcl runs this through
# RIBBON_MAIL_SCENE): tests/mail-fixture-server.tcl serves IMAP and SMTP on 127.0.0.1; the Personal account of
# tests/mail-accounts-standin.tcl syncs with it into an empty ~/Mail. A message delivered on the server shows in the
# list; opening it marks it read on the server; the inline reply saves a draft, Send goes out through SMTP (the
# server takes it with In-Reply-To), the answered message is marked on the server and the draft is gone; a new
# message (Mail-A7-Compose) with an attachment is sent; a message to a refused address shows the error and stays.
# Prints "flow: ok" at the end. Any Tcl error fails.
set here [file dirname [file normalize [info script]]]
proc bgerror {msg} { puts stderr "mail-flow: $msg\n$::errorInfo"; exit 1 }
set fails 0
proc ok {name cond} {
	global fails
	if {$cond} { puts "  ok   $name" } else { puts "  FAIL $name"; incr fails }
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
	global f
	puts $f $args
	set ::ctl_ ""
	fileevent $f readable [list apply {{f} { set ::ctl_ [gets $f] }} $f]
	until {$::ctl_ ne ""} 10000
	fileevent $f readable {}
	return [string range $::ctl_ 2 end]
}
set dir $::env(RIBBON_MAIL_FIXTURES)
file delete -force $dir
file mkdir [file join $dir Mail]
mail::store::set_root [file join $dir Mail]
mail::store::set_cache_root [file join $dir cache]
set ::env(MAIL_TEST_IMAP) [dict get $ports imap]
set ::env(MAIL_TEST_SMTP) [dict get $ports smtp]

set m "From: Anna Berg <anna@hearth.studio>\r\nTo: Maya Lind <maya@lind.page>, Jonas Ek <jonas@ek.se>\r\nSubject: Run sheet for Thursday\r\nMessage-ID: <run-1@hearth.studio>\r\nDate: Sat, 7 Nov 2026 10:31:00 +0100\r\n\r\nThe run sheet is attached.\r\n"
ctl deliver INBOX {} [binary encode base64 $m]
ctl mailbox Archive \\Archive
mailapp::start_sync
mailapp::show_view inboxes
ok "a message on the server shows in the list" [until {[llength $::mailapp::convs] == 1 && [dict get [lindex $::mailapp::convs 0] subject] eq "Run sheet for Thursday"} 20000]
mailapp::select [dict get [lindex $::mailapp::convs 0] key]
ok "opening it marks it read on the server" [until {[string match {*\\Seen*} [ctl dump INBOX]]} 15000]

mailapp::reply_open all
ok "Reply all goes to the sender and the others, not to me" \
	[expr {[lmap a [dict get $::mailapp::draft to] {lindex $a 1}] eq "anna@hearth.studio" && [lmap a [dict get $::mailapp::draft cc] {lindex $a 1}] eq "jonas@ek.se"}]
# the mode chip opens its picker (Mail-A12-Reply-mode); Forward there makes it a forward, Reply all back again
mailapp::paint
foreach h $::ui::hits { if {[string match {::mailapp::reply_mode_menu *} [lindex $h 4]]} { uplevel #0 [lindex $h 4] } }
ok "the reply's mode chip opens the picker, the mode checked" [expr {[mailapp::menu_up] && [llength [lindex $::mailapp::menu 2]] == 3}]
mailapp::menu_press 20 [expr {6 + 36 * 2 + 18}]
ok "Forward in the picker makes it a forward and closes the picker" [expr {[dict get $::mailapp::draft mode] eq "forward" && ![mailapp::menu_up]}]
mailapp::paint
foreach h $::ui::hits { if {[string match {::mailapp::reply_mode_menu *} [lindex $h 4]]} { uplevel #0 [lindex $h 4] } }
mailapp::press 5 5
ok "a click beside the picker closes it and does nothing else" [expr {![mailapp::menu_up] && [dict get $::mailapp::draft mode] eq "forward"}]
mailapp::reply_mode_menu 0 0
mailapp::menu_press 20 [expr {6 + 36 + 18}]
ok "Reply all in the picker: to the sender and the others again" [expr {[dict get $::mailapp::draft mode] eq "all" &&
	[lmap a [dict get $::mailapp::draft to] {lindex $a 1}] eq "anna@hearth.studio"}]
$::mailapp::rtext insert 1.0 "Thanks, see you at 18:00.\nMaya"
ok "the draft is saved to Drafts after a pause" [until {[llength [mail::store::keys Personal Drafts]] == 1 && $::mailapp::saved} 8000]
set draftkey [dict get $::mailapp::draft key]
mailapp::paint
mailapp::send_now
ok "Send hands the reply to the SMTP server" [until {[llength [ctl sent]] == 1} 15000]
lassign [lindex [ctl sent] 0] from rcpts b64
set bytes [binary decode base64 $b64]
ok "the reply: from me, to both, Re: subject, In-Reply-To and References, the text" \
	[expr {$from eq "maya@lind.page" && [lsort $rcpts] eq {anna@hearth.studio jonas@ek.se} && [string match "*Subject: Re: Run sheet for Thursday*" $bytes] \
		&& [string match "*In-Reply-To: <run-1@hearth.studio>*" $bytes] && [string match "*References: <run-1@hearth.studio>*" $bytes] && [string match "*see you at 18:00.*" $bytes]}]
ok "the inline reply closes and its draft is gone" [until {!$::mailapp::state(reply) && [catch {mail::store::path $draftkey}]} 5000]
ok "the answered message is marked answered on the server" [until {[string match {*\\Answered*} [ctl dump INBOX]]} 15000]

# a new message with an attachment
set att [file join $dir notes.txt]
set fh [open $att w]; puts -nonewline $fh "release notes"; close $fh
mailapp::compose_new
.compose.to insert 0 "Lea Moreau <lea@moreau.fr>"
mailapp::compose_take to
.compose.subject insert 0 "Release notes"
mailapp::compose_key subject x
.compose.text insert 1.0 "Here they are."
mailapp::attach_files compose [list $att]
ok "the new message is from the account, to the address typed" \
	[expr {[dict get $::mailapp::cdraft from] eq {{Maya Lind} maya@lind.page} && [dict get $::mailapp::cdraft to] eq {{{Lea Moreau} lea@moreau.fr}}}]
# the From chip opens its picker (Mail-A13-From): each account, the one it goes from checked; picking it keeps it
foreach h $::mailapp::cui(ui:hits) { if {[string match {::mailapp::from_menu *} [lindex $h 4]]} { uplevel #0 [lindex $h 4] } }
ok "the From chip opens the accounts picker over the new message" [expr {[mailapp::menu_up] && [winfo parent [lindex $::mailapp::menu 0]] eq ".compose" &&
	[llength [lindex $::mailapp::menu 2]] == [llength [mailapp::compose_accounts]]}]
mailapp::menu_press 20 24
ok "picking the account closes the picker, the message still from it" [expr {![mailapp::menu_up] && [dict get $::mailapp::cdraft account] eq "Personal"}]
mailapp::compose_send
ok "Send takes the new message, with its attachment" [until {[llength [ctl sent]] == 2} 15000]
set bytes [binary decode base64 [lindex [lindex [ctl sent] 1] 2]]
ok "the attachment is in it (base64, its name)" [expr {[string match {*filename="notes.txt"*} $bytes] && [string match "*[binary encode base64 {release notes}]*" $bytes]}]
ok "the window closes once it is sent" [until {![winfo exists .compose]} 5000]

# a refused recipient: the message stays, the error shows
mailapp::compose_new
.compose.to insert 0 "reject@example.org"
mailapp::compose_take to
.compose.text insert 1.0 "x"
mailapp::compose_send
ok "a refused send keeps the window and says why" [until {[string match "Not sent*" $::mailapp::sendmsg] && [winfo exists .compose]} 15000]
mailapp::compose_discard
ok "Discard closes the window and leaves no draft" [expr {![winfo exists .compose] && [llength [mail::store::keys Personal Drafts]] == 0}]

ok "the add-account button opens the accounts sheet" [expr {[mailapp::add_account; set ::mail::accounts::asked] == 1}]

# the composers' keys and drafts
proc drafts {} { llength [mail::store::keys Personal Drafts] }
mailapp::show_view inboxes
mailapp::select [dict get [lindex $::mailapp::convs 0] key]
mailapp::reply_open reply
$::mailapp::rtext insert 1.0 "First words"
mailapp::reply_save
mailapp::reply_open all
ok "Reply all on an open reply keeps its text, as Reply all" \
	[expr {[string match "First words*" [$::mailapp::rtext get 1.0 end-1c]] && [dict get $::mailapp::draft mode] eq "all"}]
$::mailapp::rtext insert end " and more"
mailapp::reply_save
ok "and keeps one draft" [expr {[drafts] == 1}]
focus -force $::mailapp::rtext
update
event generate $::mailapp::rtext <Control-r>
update
ok "Ctrl+R in the reply does not empty it" [string match "First words*" [$::mailapp::rtext get 1.0 end-1c]]
mailapp::attach_files reply [list $att]
while {[dict get $::mailapp::draft mode] ne "forward"} { mailapp::reply_mode }
ok "Forward keeps the files attached to the reply" [expr {[lsearch -exact [lmap a [dict get $::mailapp::draft atts] {expr {[dict exists $a path] ? [dict get $a path] : ""}}] $att] >= 0}]
while {[dict get $::mailapp::draft mode] ne "reply"} { mailapp::reply_mode }
mailapp::reply_save
$::mailapp::rtext delete 1.0 end
set ::mailapp::draft [dict replace $::mailapp::draft atts {}]
mailapp::reply_save
ok "a reply emptied of everything leaves no draft" [expr {[drafts] == 0}]
$::mailapp::rtext insert 1.0 "A reply left open"
set before [llength [ctl sent]]
mailapp::compose_new
.compose.to insert 0 "lea@moreau.fr"
mailapp::compose_take to
.compose.subject insert 0 "Keys"
mailapp::compose_key subject x
.compose.text insert 1.0 "Sent with Ctrl+Return."
focus -force .compose.text
update
event generate .compose.text <Control-Return>
until {[llength [ctl sent]] > $before} 8000
set last [binary decode base64 [lindex [lindex [ctl sent] end] 2]]
ok "Ctrl+Return in the new message sends it, not the open reply" \
	[expr {[llength [ctl sent]] == $before + 1 && [string match "*Subject: Keys*" $last] && $::mailapp::state(reply)}]
until {![winfo exists .compose]} 5000
mailapp::reply_discard
mailapp::compose_new
.compose.subject insert 0 "Unsaved"
.compose.text insert 1.0 "Closed at once."
rename ::exit ::real_exit
proc ::exit {args} {}
mailapp::quit
rename ::exit {}
rename ::real_exit ::exit
ok "closing Mail saves the new message being written" [expr {[drafts] == 1}]

# a folder tree longer than the window: the rail scrolls to its last folder, between the search field and Trash
for {set i 1} {$i <= 24} {incr i} { mail::store::create_folder Personal [format Box%02d $i] }
set ::mailapp::open Personal
mailapp::paint
proc railhit {script} { foreach h $::ui::hits { if {[lindex $h 4] eq $script} { return $h } }; return "" }
proc shown {h} { expr {$h ne "" && [lindex $h 1] >= 116 && [lindex $h 3] <= $::mailapp::H - 56} }
set out 0
foreach h $::ui::hits { if {[string match "*show_view \{folder *" $h] && ![shown $h]} { incr out } }
ok "no folder row is drawn under the search field or Trash" [expr {$out == 0}]
for {set i 0} {$i < 40} {incr i} { mailapp::wheel 100 400 1 }
ok "the rail scrolls to the last folder" [shown [railhit {::mailapp::show_view {folder Personal Box24}}]]
ok "Trash stays at the foot" [expr {[lindex [railhit {::mailapp::show_view trash}] 1] == $::mailapp::H - 48}]

# a hostile message: an address with a bare CR in it must not become a header or an SMTP command in the reply
set s [dict create account Personal key {Personal Inbox x} from {{Eve} eve@evil.example} to {{{} maya@lind.page}} \
	cc [list [list "" "x@y.example\rX-Injected: yes"] {N n@q.example}] subject "Hi" msgid "h@evil.example" refs {} atts {} date 0]
set d [mail::compose::reply $s {maya@lind.page} all]
dict set d from {{Maya Lind} maya@lind.page}
set rc [mail::compose::recipients $d]
set w [mail::smtp::wire [mail::compose::build $d]]
ok "Reply all leaves out an address with a line break in it" \
	[expr {![regexp {[\r\n\s]} [join $rc ""]] && $rc eq {eve@evil.example n@q.example} && ![regexp -line {^X-Injected} [string map {\r ""} $w]]}]

# a sync settling while a long message is read does not move the reading pane
set long "From: Anna Berg <anna@hearth.studio>\r\nTo: maya@lind.page\r\nSubject: A long read\r\nMessage-ID: <long-1@hearth.studio>\r\nDate: Sat, 7 Nov 2026 10:40:00 +0100\r\n\r\n[string repeat "A paragraph of a long message, long enough to wrap over a few lines of the reading measure.\r\n\r\n" 40]"
set lk [mail::store::deliver Personal Inbox [encoding convertto utf-8 $long]]
mailapp::show_view inboxes
mailapp::select $lk
set ::mailapp::pscroll [expr {[mailapp::pane_max] / 2}]
mailapp::paint
set was $::mailapp::pscroll
mailapp::sync_status Personal [dict create state idle folder "" checked [clock seconds] kind "" message "" retry ""]
after 400 {set ::tick 1}; vwait ::tick
ok "a sync settling keeps the reading pane where it was" [expr {$was > 0 && $::mailapp::pscroll == $was && [lindex $::mailapp::state(conv) 2] eq [lindex $lk 2]}]

# Archive on an inbox conversation moves its inbox messages; your reply stays in Sent
set sentf [mail::store::folder_of Personal sent]
ok "the sent reply is fetched into Sent" [until {$sentf ne "" && [llength [mail::store::keys Personal $sentf]] >= 1 || [set sentf [mail::store::folder_of Personal sent]] eq "-"} 15000]
set nsent [llength [mail::store::keys Personal $sentf]]
mailapp::show_view inboxes
foreach c $::mailapp::convs { if {[dict get $c subject] eq "Run sheet for Thursday"} { mailapp::select [dict get $c key] } }
ok "the conversation holds the reply from Sent" [expr {[lsearch -exact [lmap m [dict get $::mailapp::conv msgs] {dict get $m folder}] $sentf] >= 0}]
mailapp::move_to archive
ok "Archive leaves the reply in Sent" [expr {[llength [mail::store::keys Personal $sentf]] == $nsent}]
proc uids {box} { lmap x [ctl dump $box] {lindex $x 0} }
ok "Archive reaches the server: the message leaves the server's INBOX for its Archive" [until {1 ni [uids INBOX] && [llength [uids Archive]] == 1} 15000]
until {[dict get [mail::sync::status Personal] state] eq "idle"} 8000
ok "and the server's copy in Archive is the one moved here (one message there)" [until {[llength [mail::store::keys Personal Archive]] == 1 &&
	[mail::syncstore::uid Personal Archive [lindex [lindex [mail::store::keys Personal Archive] 0] 2]] ne ""} 8000]
mailapp::show_view archive
mailapp::select [dict get [lindex $::mailapp::convs 0] key]
mailapp::move_to trash
ok "Delete moves it to the server's Trash" [until {[uids Archive] eq "" && [llength [uids Trash]] == 1} 15000]
until {[dict get [mail::sync::status Personal] state] eq "idle" && [llength [mail::store::keys Personal Trash]] == 1 &&
	[mail::syncstore::uid Personal Trash [lindex [lindex [mail::store::keys Personal Trash] 0] 2]] ne ""} 8000
mailapp::show_view trash
mailapp::select [dict get [lindex $::mailapp::convs 0] key]
mailapp::move_to trash
ok "Delete in Trash removes it from the server" [until {[uids Trash] eq "" && [llength [mail::store::keys Personal Trash]] == 0} 15000]

# the reading pane scrolled a little: nothing of the message is drawn over its toolbar
mailapp::select $lk
proc inbar {} { llength [$::ui::cv find overlapping 610 2 [expr {$::mailapp::W - 2}] 50] }
set ::mailapp::pscroll 0; mailapp::paint
set n0 [inbar]
set over {}
foreach ps {20 40 55 70 90} {
	set ::mailapp::pscroll $ps; mailapp::paint
	if {[inbar] != $n0} { lappend over $ps }
}
ok "the toolbar stays clear of the scrolled message" [expr {$over eq ""}]
proc inhead {} { llength [$::ui::cv find overlapping 236 2 600 68] }
mailapp::show_view inboxes
set ::mailapp::lscroll 0; mailapp::paint
set n0 [inhead]
set over {}
foreach ls {10 30 50 70} {
	set ::mailapp::lscroll $ls; mailapp::paint
	if {[inhead] != $n0} { lappend over $ls }
}
ok "the list's head stays clear of the scrolled rows" [expr {$over eq ""}]
puts [expr {$fails ? "flow: FAILED" : "flow: ok"}]
catch {puts $f quit}
exit [expr {$fails ? 1 : 0}]
