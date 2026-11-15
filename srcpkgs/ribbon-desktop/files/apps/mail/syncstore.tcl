# syncstore.tcl - the store side of mail::sync over Mail's Maildir store (store.tcl): it keeps, per folder, which
# server UID is which message file and the flags both sides last agreed on, so that a flag changed in the store
# (mail::store::set_flags, add_flags, add_label ...) is found and sent by the next sync without any other hook.
#
#   mail::sync::start ACCT [list ... -store ::mail::syncstore::cmd]
#   mail::syncstore::local ACCT SERVERNAME        the store's folder for a server folder ("" if not synced)
#   mail::syncstore::server ACCT FOLDER           the server folder of a store folder ("" if not synced); after
#                                                 a flag or label change there: mail::sync::push ACCT [server ...]
#   mail::syncstore::uid ACCT FOLDER UNIQUE       the server UID of the store's message FOLDER/UNIQUE ("" if it is
#                                                 not a copy of a server message); before moving or deleting it
#                                                 here: mail::sync::move ACCT [server ...] UID [server ACCT DEST]
#
# A move asked for (mail::sync::move) is kept in the source folder's state (moves) until the server has done it, so
# that one asked for offline, or just before a quit, is done when Mail next starts. The copy already moved here is
# then waited for in the new folder (arriving): when the server's copy comes (its UID from COPYUID, or else its
# Message-ID), it is taken as that copy instead of being fetched as a second one.
#
# A message just sent is copied into the account's Sent folder at once (outbox); the folder's .ribbon-outbox lists
# those copies (one file name each) until the server has its own copy (saved), so that a copy made while the server
# could not be reached is sent to it when Mail next starts (outboxed).
#
# The state of a synced folder is the file .ribbon-sync in its Maildir (next to dovecot-keywords): a Tcl dict
# {server NAME uidvalidity N uidnext N highestmodseq N map {UID {UNIQUE FLAGS} ...} ?moves {UID {dest DEST unique
# UNIQUE msgid ID} ...}? ?arriving {UNIQUE {uid N msgid ID} ...}?}. It is written at each
# setstate, which mail::sync calls after every batch of new mail and at the end of each folder.
#
# Folder names: the server's name as text, its delimiter as "/", the server's INBOX as "Inbox". A folder whose
# special use (\Sent, \Drafts, \Trash, \Junk, \Archive) the store would not see from its name ("Gesendet") is kept
# under the English name of that use, when no other server folder has that name. A leading "." or "~" becomes "_" (the
# store's names cannot start with one), and so does a level named cur, new or tmp.
#
# Flags: \Seen S, \Answered R, \Flagged F, \Draft D, \Deleted T, $Forwarded P (Maildir's letters); a keyword that
# is a label name (not starting with "$") is a label (a keyword letter). Other keywords are not kept. A label that is
# not an IMAP atom (not ASCII, or with an atom-special) stays on this computer: it is never sent as a keyword, and the
# server's flags for the message do not take it off.

if {[info commands ::mail::store::deliver] eq ""} {
	foreach f {mime store} { source [file join [file dirname [info script]] $f.tcl] }
}

namespace eval ::mail::syncstore {
	variable st               ;# array: "acct\0local" -> state dict (loaded on first use)
	array set st {}
	variable names            ;# array: "acct\0server" -> local folder
	array set names {}
	variable pend             ;# array: "acct\0local\0uid" -> {add remove} last handed to sync as pending
	array set pend {}
	variable letters {\\Seen S \\Answered R \\Flagged F \\Draft D \\Deleted T $Forwarded P}
}

proc ::mail::syncstore::cmd {method acct args} {
	switch -- $method {
		folders - folder - drop - state - setstate - reset - uids - deliver - flags - expunge - pending - pushed -
		outbox - outboxed - saved - move - moves - moved {
			return [M_$method $acct {*}$args]
		}
	}
	error "unknown store method $method"
}

proc ::mail::syncstore::K {acct local} { return "$acct\0$local" }

# ---- folder names ------------------------------------------------------------------------------------------------
proc ::mail::syncstore::local {acct server} {
	variable names
	set k "$acct\0$server"
	if {[info exists names($k)]} { return $names($k) }
	# a folder synced before this run: its state file names the server folder
	foreach f [mail::store::folders $acct] {
		set s [Load $acct $f]
		if {[dict exists $s server]} { set names($acct\0[dict get $s server]) $f }
	}
	expr {[info exists names($k)] ? $names($k) : ""}
}
# the server folder a store folder is synced with ("" if none): what mail::sync::push takes after the store's
# flags or labels of a message there were changed
proc ::mail::syncstore::server {acct local} {
	set s [Load $acct $local]
	expr {[dict exists $s server] ? [dict get $s server] : ""}
}
# the server UID of a message the store holds from the server ("" if none)
proc ::mail::syncstore::uid {acct local unique} {
	if {[catch {Load $acct $local} s]} { return "" }
	dict for {u e} [dict get $s map] {
		if {[lindex $e 0] eq $unique} { return $u }
	}
	return ""
}
# one level of a store folder name: no "/", no leading "." or "~" (the store refuses both: a hidden file, a home
# directory), and not cur, new or tmp (they would be the parent Maildir's own directories)
proc ::mail::syncstore::Part {p} {
	set p [string map {/ _ \0 _} $p]
	if {[string match {[.~]*} $p] || $p in {cur new tmp}} { set p _[string trimleft $p .~] }
	if {$p eq ""} { set p _ }
	return $p
}
proc ::mail::syncstore::Name {display role delim taken} {
	if {[string toupper $display] eq "INBOX" || $role eq "inbox"} { return Inbox }
	set parts [expr {$delim eq "" ? [list $display] : [split $display $delim]}]
	set parts [lmap p $parts { Part $p }]
	set name [join $parts /]
	set canon [dict create sent Sent drafts Drafts trash Trash junk Junk archive Archive]
	if {[dict exists $canon $role] && [mail::store::role $name] ne $role && [dict get $canon $role] ni $taken} {
		set name [dict get $canon $role]
	}
	return $name
}

# ---- state files ---------------------------------------------------------------------------------------------------
proc ::mail::syncstore::File {acct local} {
	file join [mail::store::folder_dir $acct $local] .ribbon-sync
}
proc ::mail::syncstore::Load {acct local} {
	variable st
	set k [K $acct $local]
	if {[info exists st($k)]} { return $st($k) }
	set s [dict create map {}]
	set f [File $acct $local]
	if {[file readable $f]} {
		if {![catch {set fh [::open $f r]; fconfigure $fh -encoding utf-8; set text [::read $fh]; ::close $fh}] &&
			![catch {dict size $text}] && [dict exists $text map]} {
			set s $text
		}
	}
	set st($k) $s
	return $s
}
proc ::mail::syncstore::Save {acct local} {
	variable st
	set f [File $acct $local]
	set tmp $f.tmp[pid]
	set fh [::open $tmp w]
	fconfigure $fh -encoding utf-8 -translation lf
	puts -nonewline $fh $st([K $acct $local])
	::close $fh
	file rename -force $tmp $f
}
proc ::mail::syncstore::Local {acct server} {
	set l [local $acct $server]
	if {$l eq ""} { error "folder $server is not synced for $acct" }
	return $l
}

# ---- flags --------------------------------------------------------------------------------------------------------
# IMAP flags -> Maildir letters (keyword letters made as needed)
proc ::mail::syncstore::ToLetters {acct local flags} {
	variable letters
	set out ""
	foreach f $flags {
		set hit 0
		foreach {imap l} $letters {
			if {[string equal -nocase $f $imap]} { append out $l; set hit 1; break }
		}
		if {$hit || [string match {[$\\]*} $f] || [catch {mail::store::check_label $f}]} continue
		if {![catch {mail::store::keyword_letter $acct $local $f} l]} { append out $l }
	}
	mail::store::norm_flags $out
}
# A label the server can keep as a keyword: an IMAP atom (RFC 3501: printable ASCII, no atom-specials). Any other
# label (#reçus, #家族) is local only: it is never sent, so that no server gets it cut to bytes.
proc ::mail::syncstore::Sendable {name} {
	expr {[regexp {^[\x21-\x7e]+$} $name] && ![regexp {[()\{%*"\\\]]} $name] && ![string match {[$\\]*} $name]}
}
# Maildir letters -> IMAP flags (local-only labels left out)
proc ::mail::syncstore::ToFlags {acct local lets} {
	variable letters
	set out {}
	set kw [mail::store::keywords $acct $local]
	foreach c [split $lets ""] {
		set i [lsearch -exact $letters $c]
		if {$i > 0 && $i % 2 == 1} { lappend out [lindex $letters $i-1]; continue }
		if {[dict exists $kw $c] && [Sendable [dict get $kw $c]]} { lappend out [dict get $kw $c] }
	}
	lsort -unique $out
}
# the letters of LETS that are local-only labels (kept when the server's flags replace the others)
proc ::mail::syncstore::LocalOnly {acct local lets} {
	set kw [mail::store::keywords $acct $local]
	set out ""
	foreach c [split $lets ""] {
		if {[dict exists $kw $c] && ![Sendable [dict get $kw $c]]} { append out $c }
	}
	return $out
}
# the part of FLAGS the store can keep, as a sorted list
proc ::mail::syncstore::Kept {acct local flags} {
	ToFlags $acct $local [ToLetters $acct $local $flags]
}

# ---- the methods mail::sync calls ----------------------------------------------------------------------------------
proc ::mail::syncstore::M_folders {acct} {
	set out {}
	foreach f [mail::store::folders $acct] {
		set s [Load $acct $f]
		if {[dict exists $s server]} { lappend out [dict get $s server] }
	}
	return $out
}
proc ::mail::syncstore::M_folder {acct server display role delim} {
	variable names
	variable st
	if {[local $acct $server] ne ""} return
	set taken {}
	foreach k [array names names $acct\0*] { lappend taken $names($k) }
	set name [Name $display $role $delim $taken]
	if {$name in $taken} {
		# two server folders that come out with one name: the second keeps its server spelling
		set name [Part $server]
		# and when that is taken too (a \Sent "Gesendet" came first as Sent, then the server's own "Sent"): a number
		set base $name
		for {set i 2} {$name in $taken} {incr i} { set name "$base $i" }
	}
	mail::store::create_folder $acct $name
	set s [Load $acct $name]
	dict set s server $server
	set st([K $acct $name]) $s
	set names($acct\0$server) $name
	Save $acct $name
}
proc ::mail::syncstore::M_drop {acct server} {
	variable names
	variable st
	set l [local $acct $server]
	if {$l eq ""} return
	# the copies of the server's messages go; anything else in the folder stays, with the folder
	dict for {u e} [dict get [Load $acct $l] map] {
		catch {mail::store::delete [list $acct $l [lindex $e 0]]}
	}
	file delete -force [File $acct $l]
	unset -nocomplain st([K $acct $l]) names($acct\0$server)
	set d [mail::store::folder_dir $acct $l]
	set subs [lsort [lmap x [glob -nocomplain -directory $d -types d *] {file tail $x}]]
	if {$subs eq {cur new tmp} && ![llength [glob -nocomplain -directory $d -types f cur/* new/* tmp/*]]} {
		file delete -force -- [file join $d dovecot-keywords]
		foreach x $subs { catch {file delete -- [file join $d $x]} }
		catch {file delete -- $d}
	}
}
proc ::mail::syncstore::M_state {acct server} {
	set s [Load $acct [Local $acct $server]]
	dict remove $s map server moves arriving
}
proc ::mail::syncstore::M_setstate {acct server d} {
	variable st
	set l [Local $acct $server]
	set s [Load $acct $l]
	foreach k {uidvalidity uidnext highestmodseq} {
		if {[dict exists $d $k]} { dict set s $k [dict get $d $k] }
	}
	set st([K $acct $l]) $s
	Save $acct $l
}
proc ::mail::syncstore::M_reset {acct server} {
	variable st
	set l [Local $acct $server]
	set s [Load $acct $l]
	# the server's UIDs changed meaning: its copies go and come again under the new ones (and so do the copies moved
	# here that were waiting for the server's); a move waiting there no longer knows its message
	dict for {u e} [dict get $s map] {
		catch {mail::store::delete [list $acct $l [lindex $e 0]]}
	}
	if {[dict exists $s arriving]} {
		foreach unique [dict keys [dict get $s arriving]] { catch {mail::store::delete [list $acct $l $unique]} }
	}
	set st([K $acct $l]) [dict create server $server map {}]
	Save $acct $l
}
proc ::mail::syncstore::M_uids {acct server} {
	variable st
	set l [Local $acct $server]
	set s [Load $acct $l]
	set out {}
	set map [dict get $s map]
	set changed 0
	dict for {u e} $map {
		lassign $e unique flags
		if {[catch {mail::store::path [list $acct $l $unique]}]} {
			# gone from the store (moved or deleted here): no longer synced
			dict unset map $u
			set changed 1
			continue
		}
		dict set out $u $flags
	}
	if {$changed} {
		dict set s map $map
		set st([K $acct $l]) $s
	}
	return $out
}
proc ::mail::syncstore::M_deliver {acct server uid flags date bytes} {
	variable st
	set l [Local $acct $server]
	set s [Load $acct $l]
	if {[dict exists $s map $uid]} {
		# delivered before (a sync interrupted before its state was saved): replace that copy
		catch {mail::store::delete [list $acct $l [lindex [dict get $s map $uid] 0]]}
	}
	if {[dict exists $s arriving] && [dict size [dict get $s arriving]]} {
		set unique [Arrival $acct $l $uid $bytes]
		if {$unique ne ""} {
			# the copy moved here: it is this message (its flags as they are here; a difference goes to the server)
			set s [Load $acct $l]
			dict set s map $uid [list $unique [Kept $acct $l $flags]]
			set st([K $acct $l]) $s
			return
		}
		set s [Load $acct $l]
	}
	set key [mail::store::deliver $acct $l $bytes [ToLetters $acct $l $flags]]
	if {$date ne "" && [string is integer -strict $date]} { catch {file mtime [mail::store::path $key] $date} }
	dict set s map $uid [list [lindex $key 2] [Kept $acct $l $flags]]
	set st([K $acct $l]) $s
}
proc ::mail::syncstore::M_flags {acct server uid flags} {
	variable st
	set l [Local $acct $server]
	set s [Load $acct $l]
	if {![dict exists $s map $uid]} return
	set unique [lindex [dict get $s map $uid] 0]
	set key [list $acct $l $unique]
	set keep ""
	if {![catch {mail::store::flags $key} lets]} { set keep [LocalOnly $acct $l $lets] }
	if {[catch {mail::store::set_flags $key [mail::store::norm_flags [ToLetters $acct $l $flags]$keep]}]} return
	dict set s map $uid [list $unique [Kept $acct $l $flags]]
	set st([K $acct $l]) $s
}
proc ::mail::syncstore::M_expunge {acct server uid} {
	variable st
	set l [Local $acct $server]
	set s [Load $acct $l]
	if {![dict exists $s map $uid]} return
	catch {mail::store::delete [list $acct $l [lindex [dict get $s map $uid] 0]]}
	dict unset s map $uid
	set st([K $acct $l]) $s
}
proc ::mail::syncstore::M_pending {acct server} {
	variable pend
	set l [Local $acct $server]
	set out {}
	dict for {u e} [dict get [Load $acct $l] map] {
		lassign $e unique was
		if {[catch {mail::store::flags [list $acct $l $unique]} lets]} continue
		set now [ToFlags $acct $l $lets]
		if {$now eq $was} continue
		set add [lmap f $now { if {$f in $was} continue; set f }]
		set remove [lmap f $was { if {$f in $now} continue; set f }]
		set pend($acct\0$l\0$u) [list $add $remove]
		lappend out [list $u $add $remove]
	}
	return $out
}
proc ::mail::syncstore::M_pushed {acct server uid} {
	variable pend
	variable st
	set l [Local $acct $server]
	set k $acct\0$l\0$uid
	if {![info exists pend($k)]} return
	lassign $pend($k) add remove
	unset pend($k)
	set s [Load $acct $l]
	if {![dict exists $s map $uid]} return
	lassign [dict get $s map $uid] unique was
	set now [lsort -unique [concat [lmap f $was { if {$f in $remove} continue; set f }] $add]]
	dict set s map $uid [list $unique $now]
	set st([K $acct $l]) $s
}

# ---- moves and deletes ----------------------------------------------------------------------------------------------
proc ::mail::syncstore::M_move {acct server uid dest} {
	variable st
	set l [Local $acct $server]
	set s [Load $acct $l]
	set unique ""
	set msgid ""
	if {[dict exists $s map $uid]} {
		set unique [lindex [dict get $s map $uid] 0]
		catch {set msgid [dict get [mail::store::summary [list $acct $l $unique]] msgid]}
		dict unset s map $uid
	}
	dict set s moves $uid [dict create dest $dest unique $unique msgid $msgid]
	set st([K $acct $l]) $s
	Save $acct $l
	return [dict create uidvalidity [expr {[dict exists $s uidvalidity] ? [dict get $s uidvalidity] : ""}]]
}
proc ::mail::syncstore::M_moves {acct} {
	set out {}
	foreach l [mail::store::folders $acct] {
		set s [Load $acct $l]
		if {![dict exists $s server] || ![dict exists $s moves]} continue
		set v [expr {[dict exists $s uidvalidity] ? [dict get $s uidvalidity] : ""}]
		dict for {u e} [dict get $s moves] {
			lappend out [list [dict get $s server] $u [dict get $e dest] $v]
		}
	}
	return $out
}
proc ::mail::syncstore::M_moved {acct server uid res} {
	variable st
	set l [local $acct $server]
	if {$l eq ""} return
	set s [Load $acct $l]
	if {![dict exists $s moves $uid]} return
	set e [dict get $s moves $uid]
	dict unset s moves $uid
	if {![dict size [dict get $s moves]]} { dict unset s moves }
	set st([K $acct $l]) $s
	Save $acct $l
	set dest [dict get $res dest]
	if {[dict get $res status] ne "ok" || $dest eq ""} return
	set dl [local $acct $dest]
	set unique [dict get $e unique]
	if {$dl eq "" || $unique eq "" || [catch {mail::store::path [list $acct $dl $unique]}]} return
	set destuid [expr {[dict exists $res destuid] ? [dict get $res destuid] : ""}]
	if {$destuid eq "" && [dict get $e msgid] eq ""} {
		# nothing tells the server's copy from another: that one is fetched, this one goes
		catch {mail::store::delete [list $acct $dl $unique]}
		return
	}
	set ds [Load $acct $dl]
	dict set ds arriving $unique [dict create uid $destuid msgid [dict get $e msgid]]
	set st([K $acct $dl]) $ds
	Save $acct $dl
}
# a message from the server in a folder with copies moved here waiting: the copy it is ("" if none)
proc ::mail::syncstore::Arrival {acct l uid bytes} {
	variable st
	set s [Load $acct $l]
	set msgid ""
	set got ""
	set arr [dict get $s arriving]
	dict for {unique e} $arr {
		if {[catch {mail::store::path [list $acct $l $unique]}]} {
			# moved or deleted again here meanwhile
			dict unset arr $unique
			continue
		}
		if {[dict get $e uid] ne ""} {
			if {[dict get $e uid] == $uid} { set got $unique; break }
			continue
		}
		if {$msgid eq ""} {
			catch {set msgid [lindex [mail::mime::msgids [mail::mime::raw_header [dict get [mail::mime::parse $bytes] root] message-id]] 0]}
			if {$msgid eq ""} { set msgid "\0" }
		}
		if {[dict get $e msgid] eq $msgid} { set got $unique; break }
	}
	if {$got ne ""} { dict unset arr $got }
	if {[dict size $arr]} { dict set s arriving $arr } else { dict unset s arriving }
	set st([K $acct $l]) $s
	return $got
}

# ---- copies of sent mail ------------------------------------------------------------------------------------------
proc ::mail::syncstore::OutboxFile {acct local} {
	file join [mail::store::folder_dir $acct $local] .ribbon-outbox
}
proc ::mail::syncstore::OutboxRead {acct local} {
	set f [OutboxFile $acct $local]
	if {[catch {set fh [::open $f r]}]} { return {} }
	set l [split [string trim [::read $fh]] \n]
	::close $fh
	return [lsearch -all -inline -not -exact $l ""]
}
proc ::mail::syncstore::OutboxWrite {acct local uniques} {
	set f [OutboxFile $acct $local]
	if {![llength $uniques]} { file delete -- $f; return }
	mail::store::write_file $f "[join $uniques \n]\n" 0
}
proc ::mail::syncstore::M_outbox {acct bytes} {
	set l [mail::store::folder_of $acct sent]
	if {$l eq ""} { set l Sent }
	set key [mail::store::deliver $acct $l $bytes S]
	OutboxWrite $acct $l [concat [OutboxRead $acct $l] [list [lindex $key 2]]]
	return [list $l [lindex $key 2]]
}
proc ::mail::syncstore::M_outboxed {acct} {
	set out {}
	foreach l [mail::store::folders $acct] {
		set keep {}
		foreach u [OutboxRead $acct $l] {
			# a copy deleted here meanwhile is not sent
			if {[catch {mail::store::read [list $acct $l $u]} bytes]} continue
			lappend keep $u
			lappend out [list $l $u] $bytes
		}
		if {[file exists [OutboxFile $acct $l]] && $keep ne [OutboxRead $acct $l]} { OutboxWrite $acct $l $keep }
	}
	return $out
}
proc ::mail::syncstore::M_saved {acct id} {
	lassign $id l u
	catch {mail::store::delete [list $acct $l $u]}
	OutboxWrite $acct $l [lsearch -all -inline -not -exact [OutboxRead $acct $l] $u]
}
