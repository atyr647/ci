# mail-store.tcl - the mail model (U39) without a window, against the fixture Maildirs in tests/fixtures/maildir
# (copied to a temporary root first: the store test moves and flags messages). MIME (RFC 2047 headers, RFC 2231
# names, multipart, base64 and quoted-printable, charsets, attachments listed undecoded), the Maildir store (atomic
# delivery, flags and labels in names, moves, trash, new/ to cur/), the index cache (reused, refreshed, rebuilt),
# JWZ threading (references, loops, missing parents, subject joins), the board models (Mail-A-Ledger's list,
# Mail-A2-Thread's reader) and from: search (Mail-A4-Search), and broken mail.
# Run by tests/steps.d/66-mail-store.sh with tclsh8.6; exits 1 on a failure.
fconfigure stdout -encoding utf-8
set here [file dirname [file normalize [info script]]]
set app [file join $here .. srcpkgs ribbon-desktop files apps mail]
foreach f {mime store thread search} { source [file join $app $f.tcl] }
set tmp [expr {[info exists ::env(TMPDIR)] && $::env(TMPDIR) ne "" ? $::env(TMPDIR) : "/tmp"}]
set root [file join $tmp mail-store-[pid]]
file delete -force $root $root.cache
file copy [file join $here fixtures maildir] $root
# a checkout has no empty directories (git keeps none): take them out here too, so a Maildir without its empty
# new/ or tmp/ is what every run sees
proc prune_empty {d} {
	foreach s [glob -nocomplain -types d -directory $d *] { prune_empty $s }
	if {[glob -nocomplain -directory $d * .*] eq "" || [lsort [glob -nocomplain -tails -directory $d * .*]] eq {. ..}} { file delete $d }
}
prune_empty $root
mail::store::set_root $root
mail::store::set_cache_root $root.cache
set mail::thread::tz +0100
# the boards' clock: Sat 7 Nov, 10:42
set now [clock scan "2026-11-07 10:42" -format "%Y-%m-%d %H:%M" -timezone +0100]

set fails 0
proc ok {name cond} {
	global fails
	if {$cond} { puts "  ok   $name" } else { puts "  FAIL $name"; incr fails }
}
proc eq {name got want} {
	global fails
	if {$got eq $want} { puts "  ok   $name" } else { puts "  FAIL $name\n         got:  $got\n         want: $want"; incr fails }
}
proc find_subject {sums subject} {
	foreach s $sums { if {[dict get $s subject] eq $subject} { return $s } }
	error "no message \"$subject\""
}
proc names {atts} { lmap a $atts {dict get $a name} }

# ---- a bare CR in a header is whitespace, never a line break ------------------------------------------
set m [mail::mime::parse "From: a@x.y\rBcc: evil@z.z\r\nCc: c@x.y\r \r\nSubject: hi\r\n\r\nbody\r\n"]
set fr [mail::mime::header $m from]
ok "a bare CR in From: becomes a space, no header line of its own ($fr)" [expr {[string first "\r" $fr] < 0 && [string first "\n" $fr] < 0 && $fr eq "a@x.y Bcc: evil@z.z"}]
ok "a bare CR in Cc: becomes a space and is trimmed" [expr {[mail::mime::header $m cc] eq "c@x.y"}]

# ---- RFC 2047 headers ----------------------------------------------------------------------------------
eq "an encoded word in B and in Q, the blank between two words dropped" \
	[mail::mime::decode_words {=?UTF-8?B?U8O4bmRhZw==?= =?UTF-8?Q?_lunsj?=}] "S\u00f8ndag lunsj"
eq "a character split across two encoded words is joined before it is converted" \
	[mail::mime::decode_words {=?utf-8?B?w6k=?= =?utf-8?B?w6k=?= =?utf-8?Q?=E2=98?= =?utf-8?Q?=83?=}] "\u00e9\u00e9\u2603"
eq "text between encoded words is kept, charsets per word (iso-8859-1, koi8-r)" \
	[mail::mime::decode_words {caf=?iso-8859-1?q?=E9?= and =?koi8-r?B?8NLJ18XU?=}] "caf\u00e9 and \u041f\u0440\u0438\u0432\u0435\u0442"
eq "an unknown charset is read as UTF-8, a bad Q escape is kept, bad base64 gives nothing" \
	[mail::mime::decode_words {=?x-unknown?Q?a=20b?= =?utf-8?Q?c=ZZ?= =?utf-8?B?!!!?= end}] "a bc=ZZ end"
eq "raw 8-bit header text: UTF-8 when it is, else Windows-1252" \
	[list [mail::mime::decode_words [encoding convertto utf-8 "K\u00f6ln"]] [mail::mime::decode_words "K\xf6ln \x93q\x94"]] \
	[list "K\u00f6ln" "K\u00f6ln \u201cq\u201d"]

# ---- addresses, ids, dates, parameters -----------------------------------------------------------------
eq "address lists: quoted names, comments, groups, encoded names, bare addresses" \
	[mail::mime::addresses {"Berg, Anna" <anna@hearth.studio>, jonas@ek.se (Jonas Ek), Team: a@x.y, =?utf-8?q?L=C3=A9a?= <lea@m.fr>;, <bare@x>}] \
	[list {{Berg, Anna} anna@hearth.studio} {{Jonas Ek} jonas@ek.se} {{} a@x.y} [list L\u00e9a lea@m.fr] {{} bare@x}]
eq "message ids from References (folded), and from a value without brackets" \
	[list [mail::mime::msgids "<a@x>\n <b@y>  <c@z>"] [mail::mime::msgids "d@w"]] {{a@x b@y c@z} d@w}
eq "dates: zone offsets, named zones, two-digit years, no seconds, comments" \
	[list [mail::mime::date {Tue, 3 Nov 2026 09:02:00 +0100 (CET)}] [mail::mime::date {3 Nov 2026 08:02 GMT}] \
		[mail::mime::date {Tue, 03 Nov 26 03:02:00 EST}]] {1793692920 1793692920 1793692920}
eq "a date that cannot be (99 Nov, 31 Feb, no time) is empty" \
	[list [mail::mime::date {Funday, 99 Nov 2026 10:00:00 +0100}] [mail::mime::date {31 Feb 2026 10:00 +0000}] [mail::mime::date {3 Nov 2026}]] {{} {} {}}
set pp [mail::mime::params {attachment; filename*0*=utf-8''floor%20; filename*1="plan.pdf"; size=12}]
eq "RFC 2231 continuations and charsets in parameters" [list [lindex $pp 0] [dict get [lindex $pp 1] filename] [dict get [lindex $pp 1] size]] {attachment {floor plan.pdf} 12}
set pp [mail::mime::params {text/plain; charset="utf-8"; name="a\"b;c.txt"}]
eq "a quoted parameter with escapes and a ; inside" [list [lindex $pp 0] [dict get [lindex $pp 1] charset] [dict get [lindex $pp 1] name]] [list text/plain utf-8 {a"b;c.txt}]

# ---- transfer encodings --------------------------------------------------------------------------------
eq "quoted-printable: soft breaks, =XX in either case, trailing blanks" \
	[mail::mime::qp "caf=E9 =3d=e9=\nnext  \nline"] "caf\xe9 =\xe9next\nline"
eq "base64 with junk and without padding is decoded leniently" [mail::mime::b64 "AAEC!!AwQF*\nBgc"] [binary decode hex 0001020304050607]
eq "HTML as text: head and style gone, paragraphs, entities" \
	[mail::mime::html_text {<html><head><title>T</title><style>p{x}</style></head><body><p>Hi &amp; bye&nbsp;now</p><div>two<br>three &#x2603; &#8217;</div></body></html>}] \
	"Hi & bye\u00a0now\n\ntwo\nthree \u2603 \u2019"
eq "a snippet drops the quote, the wrote: line and the signature" \
	[mail::mime::snippet "Thanks.\n\nOn Tue, Anna wrote:\n> old\n> stuff\n\nSee you.\n-- \nAnna"] "Thanks. See you."

# ---- the fixture corpus: accounts, folders, roles, counts ---------------------------------------------
eq "accounts are the folders under ~/Mail" [mail::store::accounts] {Personal Studio ribbon-dev}
eq "folders in role order (Inbox, Archive, Sent, Junk, then Drafts and Trash)" [mail::store::folders Personal] {Inbox Archive Sent Junk Drafts Trash}
eq "roles from names" [lmap f {INBOX {Sent Items} {[Gmail]/All Mail} Spam {Deleted Messages} Projects} {mail::store::role $f}] {inbox sent archive junk trash {}}
eq "an account's unread count leaves out junk, sent, drafts and trash" [mail::store::account_unread Personal] 9
eq "the unified views count from the names alone" \
	[lmap v {inboxes flagged drafts sent} {mail::store::view_count $v}] \
	{{unread 12 total 27} {unread 2 total 4} {unread 0 total 2} {unread 0 total 2}}
eq "Mail-A-Ledger's rail: All inboxes 12 unread, Flagged 4, Drafts 2; Personal 9 (Inbox 9, Junk 2), Studio 3, ribbon-dev none" \
	[list [dict get [mail::store::view_count inboxes] unread] [dict get [mail::store::view_count flagged] total] [dict get [mail::store::view_count drafts] total] \
		[lmap a {Personal Studio ribbon-dev} {mail::store::account_unread $a}] [dict get [mail::store::count Personal Inbox] unread] [dict get [mail::store::count Personal Junk] unread]] \
	{12 4 2 {9 3 0} 9 2}
eq "labels in use (the trash and junk do not count)" [mail::store::all_labels] {family receipts ribbon studio}
eq "a label view counts its messages" [mail::store::view_count {label family}] {unread 0 total 5}

# ---- MIME on real messages: the launch mail (Mail-A-Ledger reading pane) ------------------------------
set studio [mail::store::messages Studio Inbox]
set launch [find_subject $studio "Re: Ribbon 0.9 launch: venue and the demo machine"]
set launch [lindex [lsort -integer -decreasing -index 1 [lmap s [lsearch -all -inline -glob $studio *launch-4*] {list $s [dict get $s date]}]] 0 0]
eq "the launch mail's attachments: names, types, decoded sizes" \
	[lmap a [dict get $launch atts] {list [dict get $a name] [dict get $a type] [dict get $a size] [dict get $a inline]}] \
	{{floor-plan.pdf application/pdf 2320 0} {print-hall.jpg image/jpeg 3078 0}}
set msg [mail::mime::parse [mail::store::read [dict get $launch key]]]
set decodes 0
rename ::mail::mime::b64 ::mail::mime::b64_real
proc ::mail::mime::b64 {d} { incr ::decodes; ::mail::mime::b64_real $d }
set atts [mail::mime::attachments $msg]
ok "listing attachments decodes nothing" [expr {$decodes == 0 && [llength $atts] == 2}]
set pdf [mail::mime::data $msg [dict get [lindex $atts 0] section]]
ok "an attachment is decoded when asked, byte for byte" [expr {$decodes == 1 && $pdf eq "%PDF-1.4\n[string repeat [binary format c* [lsearch -all [lrepeat 256 x] x]] 9]\n%%EOF\n"}]
rename ::mail::mime::b64 {}
rename ::mail::mime::b64_real ::mail::mime::b64
ok "the decoded size listed is the size of the bytes" [expr {[string length $pdf] == [dict get [lindex $atts 0] size]}]
set out [file join $root saved.pdf]
mail::mime::save $msg [dict get [lindex $atts 0] section] $out
set fh [open $out rb]; set back [read $fh]; close $fh
ok "save writes the decoded attachment" [expr {$back eq $pdf}]
eq "the body: quoted-printable soft breaks joined" [lindex [split [mail::mime::body $msg] "\n"] 2] \
	"The print hall is ours from 16:00. Floor plan and the run sheet are attached: doors at 18:00, talks at 18:30, and the demo at 19:15."

# ---- MIME: related + alternative with an inline image, charsets ----------------------------------------
set personal [mail::store::messages Personal Inbox]
set mum [lindex [lmap s $personal {expr {[dict get $s msgid] eq "lunch-4@posteo.net" ? $s : [continue]}}] 0]
set mmsg [mail::mime::parse [mail::store::read [dict get $mum key]]]
eq "multipart/alternative picks the plain text; iso-8859-1 is read as Windows-1252 (o=92clock)" [mail::mime::body $mmsg] \
	"One o\u2019clock is good. Your brother is coming too, with the baby. The garden finally looks like something:"
eq "the related image is an inline image with its Content-ID; the HTML alternative is not an attachment" \
	[lmap a [mail::mime::attachments $mmsg] {list [dict get $a name] [dict get $a inline] [dict get $a cid]}] {{garden.jpg 1 garden@posteo}}
set inv [find_subject $personal "Invoice for October"]
eq "an HTML-only body is read as text" [dict get $inv snippet] "Your invoice of 412.60 kr is ready. It will be paid by direct debit on 20 Nov. Questions? Reply & we answer."
set ticket [find_subject $personal "Your ticket: Oslo to Bergen, 14 Nov"]
ok "a folded encoded subject; a base64 text part; a two-digit year" [expr {[dict get $ticket snippet] eq "Seat 42, coach 3. Departs 08:25 from Oslo S, platform 4." && [dict get $ticket date] == [clock scan "2026-11-07 09:12" -format "%Y-%m-%d %H:%M" -timezone +0100]}]
eq "8-bit text with no charset and invalid UTF-8 is read as Windows-1252" [dict get [find_subject $personal "Your order has shipped"] snippet] \
	"The Dispossessed and Piranesi are on their way; tracking inside. Caf\u00e9 voucher: 5 \u20ac."
eq "RFC 2231 and RFC 2047 file names" [lmap s [lmap x {"Print hall: floor plan and power" "Studio move, week 38"} {find_subject $studio $x}] {names [dict get $s atts]}] {hall-plan.pdf studio-floor.png}

# ---- broken mail --------------------------------------------------------------------------------------
set arch [mail::store::messages Personal Archive]
eq "every broken message is listed (empty, headerless, cut, no boundary, raw 8-bit, loops, forwarded, signed)" [llength $arch] 12
set cut [find_subject $arch "Missing close"]
ok "a multipart without its closing delimiter: the text and the cut attachment" [expr {[dict get $cut snippet] eq "first part" && [names [dict get $cut atts]] eq "half.bin" && [dict get [lindex [dict get $cut atts] 0] size] == 9}]
set nb [lindex [lmap s $arch {expr {[dict get [dict get $s from] ] eq {{No Boundary} nb@example.org} ? $s : [continue]}}] 0]
ok "a multipart without a boundary is read as text; a bad date falls back to the delivery time" [expr {[dict get $nb snippet] eq "body of a multipart without a boundary" && [dict get $nb date] == 1793900000}]
ok "the header line without a colon is skipped, the next header still read" [expr {[dict get $nb subject] eq "Strange charset and bc=ZZ and" || [string match "Strange charset and *" [dict get $nb subject]]}]
eq "raw UTF-8 and raw Latin-1 headers both read" [lsort -unique [lmap s $arch {expr {[string match *K\u00f6ln [dict get $s subject]] ? "[dict get $s subject]|[lindex [dict get $s from] 0]" : [continue]}}]] \
	[list "Gr\u00fc\u00dfe aus K\u00f6ln|R\u00e5 Latin" "Gr\u00fc\u00dfe aus K\u00f6ln|R\u00e5 \u00dcn\u00efcode"]
set crlf [find_subject $arch "CRLF and mbox"]
ok "CRLF line ends and an mbox From line" [expr {[dict get $crlf from] eq {{CRLF Sender} crlf@example.org} && [dict get $crlf snippet] eq "Line one Line two"}]
set fwd [find_subject $arch "Fwd: the original"]
eq "a forwarded message is one attachment, named by its subject; its parts are not listed" [names [dict get $fwd atts]] {{The original.eml}}
eq "a signature is not an attachment" [dict get [find_subject $arch signed] atts] {}
set empty [lmap s $arch {expr {[dict get $s size] == 0 ? $s : [continue]}}]
ok "an empty file is a message with no headers" [expr {[llength $empty] == 1 && [dict get [lindex $empty 0] subject] eq ""}]
# a pathological nesting does not run away
set deep "Content-Type: multipart/mixed; boundary=b0\n\n"
for {set i 0} {$i < 200} {incr i} { append deep "--b$i\nContent-Type: multipart/mixed; boundary=b[expr {$i + 1}]\n\n" }
append deep "--b200\nContent-Type: text/plain\n\ndeep\n"
ok "a message nested 200 deep is read without running away" [expr {[catch {mail::mime::attachments [mail::mime::parse $deep]}] == 0}]

# ---- threading (JWZ) ----------------------------------------------------------------------------------
set convs [mail::thread::view inboxes]
set rows [lmap c $convs {list [dict get $c sender] [dict get $c count] [mail::thread::when_list [dict get $c shown date] $now] [dict get $c subject] [mail::thread::day_group [dict get $c shown date] $now]}]
eq "Mail-A-Ledger's list: conversations, newest shown message first, with day groups" [lrange $rows 0 3] \
	{{{Anna Berg} 4 10:31 {Ribbon 0.9 launch: venue and the demo machine} today} {{Fjord Rail} 1 09:12 {Your ticket: Oslo to Bergen, 14 Nov} today} {{Jonas Ek} 2 08:47 {Re: kit index on the mirror} today} {Mum 5 Yesterday {Sunday lunch?} yesterday}}
set lunch [lindex $convs 3]
eq "Mail-A2-Thread: the reply in Sent is in the conversation, oldest first, each with its parent" \
	[lmap m [dict get $lunch msgs] {list [mail::thread::name [dict get $m from]] [mail::thread::when_reader [dict get $m date] $now] [mail::thread::recipients $m {maya@lind.page}] [expr {[dict get $m parent] eq "" ? "" : [lindex [dict get $m parent] 1]}]}] \
	{{Mum {31 Oct, 09:14} {to me, Per Lind} {}} {Dad {31 Oct, 10:02} {to me, Mum} Inbox} {{Maya Lind} {31 Oct, 12:40} {to Mum, Dad} Inbox} {Mum {Yesterday, 08:30} {to me, Dad} Sent} {Dad {Yesterday, 19:12} {to me, Mum} Inbox}}
ok "a conversation's unread count, labels and accounts" [expr {[dict get $lunch unread] == 0 && [dict get $lunch labels] eq "family" && [dict get $lunch accounts] eq "Personal"}]
set launchc [lindex $convs 0]
eq "the launch conversation: snippet and attachments of its newest message" \
	[list [string range [dict get $launchc shown snippet] 0 6] [names [dict get $launchc atts]] [dict get $launchc labels]] {{Hi all,} {floor-plan.pdf print-hall.jpg} ribbon}
set kit [lindex $convs 2]
ok "a conversation whose first message is missing holds its replies (an empty container is kept)" \
	[expr {[dict get $kit count] == 2 && [dict get $kit flagged] && [dict get [lindex [dict get $kit msgs] 1] folder] eq "Sent"}]
set dev [lmap c $convs {expr {[dict get $c accounts] eq "ribbon-dev" ? [list [dict get $c sender] [dict get $c count]] : [continue]}}]
eq "a reply without references joins the newest original before it with its subject; two originals stay apart" [lsort $dev] [lsort {{{Ola Nordmann} 2} {Someone 1}}]
eq "two monthly mails with one subject (no reply) are not joined" \
	[llength [mail::thread::build [list \
		[dict create key {a f 1} msgid m1 refs {} subject Invoice date 1 from {A a} to {} cc {} unread 0 flagged 0 labels {} account a atts {}] \
		[dict create key {a f 2} msgid m2 refs {} subject Invoice date 2 from {A a} to {} cc {} unread 0 flagged 0 labels {} account a atts {}]]]] 2
set loop [lmap c [mail::thread::build $arch] {expr {[dict get $c subject] eq "loop" ? [dict get $c count] : [continue]}}]
eq "a reference loop (A refs B, B refs A) gives one conversation, no hang" $loop 2
set dup [mail::thread::build [list \
	[dict create key {a Inbox 1} msgid same refs {} subject X date 1 from {A a} to {} cc {} unread 1 flagged 0 labels {} account a atts {}] \
	[dict create key {a Sent 2} msgid same refs {} subject X date 1 from {A a} to {} cc {} unread 0 flagged 0 labels {} account a atts {}]]]
ok "a message met twice (one Message-ID) is kept once, the first" [expr {[llength $dup] == 1 && [dict get [lindex $dup 0] count] == 1 && [lindex [dict get [lindex $dup 0] key] 1] eq "Inbox"}]
eq "base subjects" [lmap s {{Re: Re[2]: [ribbon-dev] Fwd: AW: Hi} {SV: Hi (fwd)} {Hi}} {mail::thread::base_subject $s}] {hi hi hi}
eq "times for the list and the reader" \
	[lmap t {{2026-11-07 10:31} {2026-11-06 18:05} {2026-11-05 20:10} {2026-11-03 09:02} {2026-10-31 09:14} {2025-06-03 12:00}} {
		set e [clock scan $t -format "%Y-%m-%d %H:%M" -timezone +0100]
		list [mail::thread::when_list $e $now] [mail::thread::when_reader $e $now]}] \
	{{10:31 {Today, 10:31}} {Yesterday {Yesterday, 18:05}} {Thursday {Thu, 20:10}} {Tuesday {Tue, 09:02}} {{31 Oct} {31 Oct, 09:14}} {{3 Jun 2025} {3 Jun 2025, 12:00}}}

# ---- search (Mail-A4-Search) --------------------------------------------------------------------------
eq "query tokens: from: in its three spellings, quoted phrases" \
	[lmap q {{from:Anna floor plan} {from: anna "floor plan"} {from:"Anna Berg" plan}} {mail::search::parse $q}] \
	{{from anna words {floor plan}} {from anna words {floor plan}} {from {{anna berg}} words plan}}
set res [mail::search::run {from:Anna floor plan}]
eq "from:Anna floor plan: the board's five results, newest first, with thread counts" \
	[lmap r [dict get $res rows] {list [dict get $r count] [mail::thread::when_list [dict get $r msg date] $now] [dict get $r msg subject]}] \
	{{4 10:31 {Re: Ribbon 0.9 launch: venue and the demo machine}} {1 {2 Oct} {Print hall: floor plan and power}} {1 {14 Sep} {Studio move, week 38}} {1 {3 Jun} {Kitchen quote}} {1 {11 Mar} {Desk layout for the new hires}}}
set r1 [lindex [dict get $res rows] 0]
eq "the snippet starts at the sentence of the match and \"Floor plan\" is one highlight" \
	[list [string range [dict get $r1 snippet text] 0 34] [dict get $r1 snippet spans] [dict get $r1 att_spans]] \
	{{Floor plan and the run sheet are at} {{0 10}} {{{0 10}} {}}}
eq "highlights in a subject and separate words in a snippet" \
	[list [dict get [lindex [dict get $res rows] 1] subject_spans] [dict get [lindex [dict get $res rows] 3] snippet spans]] {{{12 22}} {{4 9} {46 50}}}
eq "the attachments section: names with a word, from Anna, newest first" \
	[lmap a [dict get $res atts] {list [dict get $a name] [dict get $a spans] [mail::thread::when_list [dict get $a date] $now]}] \
	{{floor-plan.pdf {{0 10}} 10:31} {hall-plan.pdf {{5 9}} {2 Oct}} {studio-floor.png {{7 12}} {14 Sep}}}
eq "scope: one account, the inboxes; the trash is never searched" \
	[list [llength [dict get [mail::search::run {from:Anna floor plan} {account Studio}] rows]] [llength [dict get [mail::search::run {floor plan} inbox] rows]] [llength [dict get [mail::search::run {from:old@example.org}] rows]]] {4 5 0}
eq "from: matches the address too; a word must be in every match" \
	[list [llength [dict get [mail::search::run {from:posteo.net}] rows]] [llength [dict get [mail::search::run {floor nonexistentword}] rows]]] {1 0}

# ---- the store: delivery, flags, labels, moves, the index ---------------------------------------------
set parses 0
rename ::mail::mime::parse ::mail::mime::parse_real
proc ::mail::mime::parse {b} { incr ::parses; ::mail::mime::parse_real $b }
# a fresh process: the in-memory index is gone, the one on disk is used
mail::store::set_cache_root $root.cache
mail::store::messages Studio Inbox
eq "the index on disk is reused: nothing is parsed again" $parses 0
set dmail "From: Test <t@x>\nSubject: delivered\nMessage-ID: <dl@x>\n\nhello\n"
set key [mail::store::deliver Studio Inbox $dmail]
ok "delivery: the file is in new/ under its unique name, tmp/ is empty" \
	[expr {[file dirname [mail::store::path $key]] eq [file join $root Studio Inbox new] && [glob -nocomplain -directory [file join $root Studio Inbox tmp] *] eq ""}]
ok "the unique name carries the size" [string match *,S=[string length $dmail] [lindex $key 2]]
set sums [mail::store::messages Studio Inbox]
ok "a delivered message is indexed (one parse), unread and new" [expr {$parses == 1 && [dict get [find_subject $sums delivered] unread] && [dict get [find_subject $sums delivered] new]}]
mail::store::add_flags $key S
ok "a flag moves the message to cur/ with :2,S" [string match */cur/*:2,S [mail::store::path $key]]
mail::store::add_flags $key FR
mail::store::remove_flags $key R
eq "flags are kept sorted and unique" [mail::store::flags $key] FS
set parses 0
set s [find_subject [mail::store::messages Studio Inbox] delivered]
ok "a flag change is not a new parse (the index is kept by unique name)" [expr {$parses == 0 && ![dict get $s unread] && [dict get $s flagged]}]
eq "a new label gets a free keyword letter (the folder has a and b)" [mail::store::add_label $key launch] launch
ok "the label is the letter c in the name and in dovecot-keywords" [expr {[string match *:2,FSc [mail::store::path $key]] && [dict get [mail::store::keywords Studio Inbox] c] eq "launch"}]
mail::store::add_label $key ribbon
eq "an existing label reuses its letter" [mail::store::flags $key] FSac
set moved [mail::store::move $key Personal Archive]
ok "a move keeps the flags and remaps the labels to the new folder's letters" \
	[expr {[lsort [mail::store::labels $moved]] eq {launch ribbon} && [string match {*:2,FS[a-z][a-z]} [mail::store::path $moved]] && [catch {mail::store::path $key}]}]
set t [mail::store::trash $moved]
eq "trash moves into the account's trash folder" [lrange $t 0 1] {Personal Trash}
mail::store::delete $t
ok "delete removes the file" [catch {mail::store::path $t}]
set k2 [mail::store::deliver ribbon-dev Inbox "Subject: no trash folder yet\n\nx\n"]
set t2 [mail::store::trash $k2]
ok "trash makes a Trash folder where the account has none" [expr {[lrange $t2 0 1] eq {ribbon-dev Trash} && [file isdirectory [file join $root ribbon-dev Trash tmp]]}]
set c0 [mail::store::count Personal Inbox]
eq "scan moves new/ to cur/ (a seen, not read, message stays unread)" [mail::store::scan Personal Inbox] 1
ok "after scan nothing is in new/ and the unread count is the same" \
	[expr {[glob -nocomplain -directory [file join $root Personal Inbox new] *] eq "" && [mail::store::count Personal Inbox] eq $c0}]
file mkdir [file join $root Personal Inbox tmp]
set stale [file join $root Personal Inbox tmp stale]
close [open $stale w]
file mtime $stale [expr {[clock seconds] - 37 * 3600}]
close [open [file join $root Personal Inbox tmp fresh] w]
mail::store::scan Personal Inbox
ok "scan removes tmp/ files older than 36 hours, not newer ones" [expr {![file exists $stale] && [file exists [file join $root Personal Inbox tmp fresh]]}]
# a damaged index is rebuilt
set idx [mail::store::index_file Studio Inbox]
set fh [open $idx w]; puts $fh "ribbon-mail-index 1\n\{broken"; close $fh
mail::store::set_cache_root $root.cache
set parses 0
set again [mail::store::messages Studio Inbox]
ok "a damaged index is dropped and rebuilt" [expr {$parses == [llength $again] && $parses > 0}]
# a message the parser fails on is still listed, with its delivery time
proc ::mail::mime::parse {b} { if {[string first PARSE-BOMB $b] >= 0} { error boom }; ::mail::mime::parse_real $b }
set bomb [mail::store::deliver Studio Inbox "Subject: PARSE-BOMB\n\nx\n"]
set bs [lmap s [mail::store::messages Studio Inbox] {expr {[dict get $s key] eq $bomb ? $s : [continue]}}]
ok "a message the parser fails on is still listed, dated by its delivery" \
	[expr {[llength $bs] == 1 && abs([dict get [lindex $bs 0] date] - [clock seconds]) < 5}]
rename ::mail::mime::parse {}
rename ::mail::mime::parse_real ::mail::mime::parse
ok "names with .. or a leading dot are refused" [expr {[catch {mail::store::folder_dir Studio ../x}] && [catch {mail::store::folder_dir .hidden Inbox}] && [catch {mail::store::folder_dir a/b Inbox}]}]
ok "a label with a blank is refused" [catch {mail::store::add_label [lindex [mail::store::keys Studio Inbox] 0] "two words"}]

# ---- review fixes: hostile and unusual mail --------------------------------------------------------------
ok "a folder or account part starting with ~ is refused (Tcl's file join would leave the mail folder)" \
	[expr {[catch {mail::store::folder_dir Studio x/~}] && [catch {mail::store::folder_dir Studio ~root}] && [catch {mail::store::folder_dir ~ Inbox}]}]
file mkdir [file join $root ./~home] [file join $root Studio ./~x cur]
ok "a directory named ~... under ~/Mail is neither an account nor a folder" \
	[expr {![catch {list [mail::store::accounts] [mail::store::folders Studio]} af] && "~home" ni [lindex $af 0] && "~x" ni [lindex $af 1]}]
set bu "x[format %c 123]y.host"
set fh [open [file join $root Studio Inbox cur "$bu:2,S"] wb]; puts -nonewline $fh "Subject: brace\n\nb\n"; close $fh
ok "a unique name with a brace is found by its key" [expr {![catch {mail::store::flags [list Studio Inbox $bu]} f] && $f eq "S"}]
set nested "Subject: n\nContent-Type: multipart/mixed; boundary=\"b1\"\n\n--b1\nContent-Type: multipart/alternative; boundary=\"b1_alt\"\n\n--b1_alt\nContent-Type: text/plain\n\nhello plain\n--b1_alt\nContent-Type: text/html\n\n<p>hello html</p>\n--b1_alt--\n--b1\nContent-Type: application/pdf; name=a.pdf\n\nAAAA\n--b1--\n"
set nm [mail::mime::parse $nested]
ok "a boundary that begins another (b1, b1_alt) does not split the inner part" \
	[expr {[mail::mime::body $nm] eq "hello plain" && [names [mail::mime::attachments $nm]] eq "a.pdf"}]
set alt "Subject: alt\n"
for {set i 0} {$i < 24} {incr i} { append alt "Content-Type: multipart/alternative; boundary=a$i\n\n--a$i\n" }
append alt "Content-Type: image/png\n\nxx\n"
set am [mail::mime::parse $alt]
set us [lindex [time {mail::mime::body $am; mail::mime::attachments $am}] 0]
ok "alternatives nested 24 deep are read at once, not three times per level" [expr {$us < 2000000}]
set refs {}
for {set i 0} {$i < 3000} {incr i} { lappend refs r$i@x }
set long [list [dict create key {a f 1} msgid m1@x refs $refs subject X date 1 from {A a} to {} cc {} unread 0 flagged 0 labels {} account a atts {}] \
	[dict create key {a f 2} msgid m2@x refs {} subject Y date 2 from {B b} to {} cc {} unread 0 flagged 0 labels {} account a atts {}]]
ok "a References chain 3000 long threads (no nesting limit), the other mail with it" \
	[expr {![catch {mail::thread::build $long} lc] && [llength $lc] == 2}]

file delete -force $root $root.cache
if {$fails} { puts "mail store: $fails failed"; exit 1 }
puts "mail store: ok"
