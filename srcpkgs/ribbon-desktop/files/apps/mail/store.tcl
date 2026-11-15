# store.tcl - the mail on disk (U39). No Tk. Mail is kept in Maildirs: ~/Mail/<account>/<folder>/{cur,new,tmp},
# a nested folder as a subdirectory ("Archive/2025"). A message is one file; its flags are in its name
# ("<unique>:2,FRS", RFC-less but universal: D draft, F flagged, P passed, R replied, S seen, T trashed) and its
# labels are keyword letters a-z after them, named per folder in dovecot-keywords (the Dovecot and mbsync
# convention, so IMAP keywords map onto labels). A message is identified by a key, the list {account folder
# unique}: the unique part of a name never changes when its flags do.
#
# Parsing a message is the costly part, so each folder has an index: one summary per message, kept in memory and
# in $XDG_CACHE_HOME/ribbon/mail/, and reused while the file's size and modification time are unchanged (a flag
# change is a rename, which keeps both). The flags and labels are never cached: they are read from the names.
#
#   mail::store::root / set_root DIR             the mail folder (RIBBON_MAIL_ROOT, else ~/Mail)
#   mail::store::cache_root / set_cache_root DIR the index folder (RIBBON_MAIL_CACHE, else XDG_CACHE_HOME)
#   mail::store::accounts                        the account names
#   mail::store::folders ACCOUNT                 its folders ("Inbox", "Archive/2025"), by role then by name
#   mail::store::role FOLDER                     inbox, drafts, sent, archive, junk, trash or ""
#   mail::store::folder_of ACCOUNT ROLE          the account's first folder with that role; "" if none
#   mail::store::create_folder ACCOUNT FOLDER    makes its cur, new and tmp
#   mail::store::deliver ACCOUNT FOLDER BYTES ?FLAGS?  a new message (written in tmp, renamed in); its key
#   mail::store::keys ACCOUNT FOLDER             the keys of its messages
#   mail::store::path KEY                        the message's file now; error if it is gone
#   mail::store::read KEY                        its bytes
#   mail::store::flags KEY / set_flags KEY F / add_flags KEY F / remove_flags KEY F
#   mail::store::labels KEY / add_label KEY NAME / remove_label KEY NAME / all_labels
#   mail::store::move KEY ACCOUNT FOLDER         its new key; labels follow it
#   mail::store::trash KEY                       moves it to its account's trash folder (made if missing)
#   mail::store::delete KEY                      removes the file for good
#   mail::store::scan ACCOUNT FOLDER             new/ moved to cur/ (the message has been seen by a reader, not
#                                                read), stale tmp/ files (over 36 hours) removed
#   mail::store::messages ACCOUNT FOLDER         the summaries (see below), index refreshed
#   mail::store::summary KEY                     one summary
#   mail::store::count ACCOUNT FOLDER            dict unread total flagged, from the names alone
#   mail::store::folders_of VIEW / view VIEW / view_count VIEW / account_unread ACCOUNT
#
# A VIEW is one of: inboxes, flagged, drafts, sent, archive, junk, trash (every account's folders of that role;
# flagged: the flagged messages outside junk and trash), {label NAME} (labelled messages outside junk and trash),
# {folder ACCOUNT FOLDER}, {account ACCOUNT} (all its folders but junk and trash), all (every account's).
#
# A summary is a dict: key account folder uid path flags unread flagged replied draft labels new (in new/), and
# from the index: msgid refs (References, else the first In-Reply-To) subject from ({name address}) to cc
# (lists of them) date (seconds; the Date header, else the delivery time in the name, else the file's time)
# size snippet text (the body as one line, for search) atts (dicts: section name size type inline) list
# (the List-Id's name).

namespace eval ::mail::store {
	variable root ""
	variable cache ""
	variable mem          ;# index in memory: "account\0folder" -> dict uid -> {size mtime summary}
	array set mem {}
	variable seq 0
	variable version 1
	variable textmax 16384    ;# characters of a body kept in the index for search
	variable roles {
		inbox inbox
		drafts drafts draft drafts
		sent sent {sent items} sent {sent messages} sent {sent mail} sent outbox sent
		archive archive archives archive {all mail} archive
		junk junk spam junk {junk e-mail} junk {junk email} junk {bulk mail} junk
		trash trash deleted trash {deleted items} trash {deleted messages} trash bin trash
	}
	variable order {inbox archive sent junk "" drafts trash}
}

# ---- places ------------------------------------------------------------------------------------------

proc ::mail::store::root {} {
	variable root
	if {$root eq ""} {
		if {[info exists ::env(RIBBON_MAIL_ROOT)] && $::env(RIBBON_MAIL_ROOT) ne ""} {
			set root [file normalize $::env(RIBBON_MAIL_ROOT)]
		} else {
			set root [file join $::env(HOME) Mail]
		}
	}
	return $root
}

proc ::mail::store::set_root {dir} {
	variable root [file normalize $dir]
	variable mem
	array unset mem
	array set mem {}
}

proc ::mail::store::cache_root {} {
	variable cache
	if {$cache eq ""} {
		if {[info exists ::env(RIBBON_MAIL_CACHE)] && $::env(RIBBON_MAIL_CACHE) ne ""} {
			set cache [file normalize $::env(RIBBON_MAIL_CACHE)]
		} elseif {[info exists ::env(XDG_CACHE_HOME)] && $::env(XDG_CACHE_HOME) ne ""} {
			set cache [file join $::env(XDG_CACHE_HOME) ribbon mail]
		} else {
			set cache [file join $::env(HOME) .cache ribbon mail]
		}
	}
	return $cache
}

proc ::mail::store::set_cache_root {dir} {
	variable cache [file normalize $dir]
	variable mem
	array unset mem
	array set mem {}
}

proc ::mail::store::check_name {what name} {
	# a part starting with ~ would be a home directory to Tcl's file join (~root): out of the mail folder
	if {$name eq "" || [string match .* $name] || [regexp {(^|/)\.\.?(/|$)} $name] || [regexp {(^|/)~} $name] \
		|| [string first "\0" $name] >= 0} {
		error "bad $what name: $name"
	}
}

proc ::mail::store::folder_dir {account folder} {
	check_name account $account
	check_name folder $folder
	if {[string first / $account] >= 0} { error "bad account name: $account" }
	return [file join [root] $account {*}[split $folder /]]
}

proc ::mail::store::accounts {} {
	set out {}
	foreach d [glob -nocomplain -types d -directory [root] *] {
		set t [file tail $d]
		if {![catch {check_name account $t}]} { lappend out $t }
	}
	return [lsort $out]
}

proc ::mail::store::role {folder} {
	variable roles
	set last [string tolower [string trim [lindex [split $folder /] end]]]
	if {[dict exists $roles $last]} { return [dict get $roles $last] }
	return ""
}

proc ::mail::store::folders {account} {
	variable order
	check_name account $account
	set base [file join [root] $account]
	set found {}
	set queue [list ""]
	while {[llength $queue]} {
		set rel [lindex $queue 0]
		set queue [lrange $queue 1 end]
		set dir [expr {$rel eq "" ? $base : [file join $base {*}[split $rel /]]}]
		# a Maildir has cur, new and tmp; one that has lost an empty new or tmp (a copy, a checkout) still is one
		if {$rel ne "" && ([file isdirectory [file join $dir cur]] || [file isdirectory [file join $dir new]])} {
			lappend found $rel
		}
		foreach sub [glob -nocomplain -types d -directory $dir *] {
			set t [file tail $sub]
			if {$t in {cur new tmp} || [catch {check_name folder $t}]} continue
			lappend queue [expr {$rel eq "" ? $t : "$rel/$t"}]
		}
	}
	set keyed {}
	foreach f $found {
		set rank [lsearch -exact $order [role $f]]
		# a nested folder sorts after its parent's role: Archive/2025 stays by Archive
		set top [lindex [split $f /] 0]
		set trank [lsearch -exact $order [role $top]]
		if {[llength [split $f /]] > 1 && $trank >= 0 && [role $top] ne ""} { set rank $trank }
		lappend keyed [list $rank $f]
	}
	set out {}
	foreach k [lsort -command ::mail::store::folder_cmp $keyed] { lappend out [lindex $k 1] }
	return $out
}

proc ::mail::store::folder_cmp {a b} {
	set c [expr {[lindex $a 0] - [lindex $b 0]}]
	if {$c != 0} { return $c }
	return [string compare -nocase [lindex $a 1] [lindex $b 1]]
}

proc ::mail::store::folder_of {account role} {
	foreach f [folders $account] {
		if {[role $f] eq $role} { return $f }
	}
	return ""
}

proc ::mail::store::create_folder {account folder} {
	set d [folder_dir $account $folder]
	foreach s {cur new tmp} { file mkdir [file join $d $s] }
	return $d
}

# ---- names -------------------------------------------------------------------------------------------

# {unique flags} of a file name. Names without the ":2," info have no flags.
proc ::mail::store::split_name {name} {
	if {[regexp {^(.*):2,([^:]*)$} $name -> uid flags]} { return [list $uid $flags] }
	if {[regexp {^(.*):1,.*$} $name -> uid]} { return [list $uid ""] }
	return [list $name ""]
}

proc ::mail::store::norm_flags {flags} {
	set out {}
	foreach c [split $flags ""] {
		if {[string match {[A-Za-z]} $c]} { lappend out $c }
	}
	return [join [lsort -unique $out] ""]
}

# Every message file of a folder: a list of {uid path flags innew}.
proc ::mail::store::files {account folder} {
	set d [folder_dir $account $folder]
	if {![file isdirectory $d]} { error "no folder $folder in $account" }
	set out {}
	foreach sub {cur new} {
		foreach p [glob -nocomplain -types f -directory [file join $d $sub] *] {
			lassign [split_name [file tail $p]] uid flags
			lappend out [list $uid $p $flags [expr {$sub eq "new"}]]
		}
	}
	return $out
}

proc ::mail::store::unique {} {
	variable seq
	incr seq
	set t [clock microseconds]
	set host [string map {/ \\057 : \\072} [info hostname]]
	return "[expr {$t / 1000000}].M[expr {$t % 1000000}]P[pid]Q$seq.$host"
}

proc ::mail::store::path {key} {
	lassign $key account folder uid
	set d [folder_dir $account $folder]
	foreach sub {cur new} {
		set p [file join $d $sub $uid]
		if {[file exists $p]} { return $p }
		set lit [string map {\\ \\\\ * \\* ? \\? [ \\[ ] \\] \{ \\\{ \} \\\}} $uid]
		set hits [glob -nocomplain -types f -directory [file join $d $sub] "$lit:*"]
		if {[llength $hits]} { return [lindex $hits 0] }
	}
	error "no message $uid in $account/$folder"
}

proc ::mail::store::keys {account folder} {
	set out {}
	foreach f [files $account $folder] { lappend out [list $account $folder [lindex $f 0]] }
	return $out
}

proc ::mail::store::read {key} {
	set fh [::open [path $key] rb]
	set bytes [::read $fh]
	::close $fh
	return $bytes
}

proc ::mail::store::write_file {file bytes {binary 1}} {
	set tmp "$file.tmp[pid]"
	set fh [::open $tmp w]
	if {$binary} { fconfigure $fh -translation binary } else { fconfigure $fh -encoding utf-8 -translation lf }
	puts -nonewline $fh $bytes
	::close $fh
	file rename -force $tmp $file
}

# A new message: written whole in tmp/, then renamed into new/ (no flags) or cur/ (with them). The rename is the
# delivery: a reader never sees a part-written file.
proc ::mail::store::deliver {account folder bytes {flags ""}} {
	set d [create_folder $account $folder]
	set size [string length $bytes]
	while 1 {
		set uid "[unique],S=$size"
		set tmp [file join $d tmp $uid]
		if {![file exists $tmp]} break
	}
	set fh [::open $tmp {WRONLY CREAT EXCL}]
	fconfigure $fh -translation binary
	puts -nonewline $fh $bytes
	::close $fh
	set flags [norm_flags $flags]
	if {$flags eq "" } {
		file rename $tmp [file join $d new $uid]
	} else {
		file rename $tmp [file join $d cur "$uid:2,$flags"]
	}
	return [list $account $folder $uid]
}

proc ::mail::store::flags {key} {
	return [lindex [split_name [file tail [path $key]]] 1]
}

# Renames the file to carry FLAGS (a message in new/ goes to cur/: it has an info part now).
proc ::mail::store::set_flags {key flags} {
	lassign $key account folder uid
	set p [path $key]
	set flags [norm_flags $flags]
	set dest [file join [folder_dir $account $folder] cur "$uid:2,$flags"]
	if {$p ne $dest} { file rename -force $p $dest }
	return $flags
}

proc ::mail::store::add_flags {key letters} {
	return [set_flags $key "[flags $key]$letters"]
}

proc ::mail::store::remove_flags {key letters} {
	set keep ""
	foreach c [split [flags $key] ""] {
		if {[string first $c $letters] < 0} { append keep $c }
	}
	return [set_flags $key $keep]
}

# ---- labels (keywords) -------------------------------------------------------------------------------

# A folder's keyword names: a dict letter -> name.
proc ::mail::store::keywords {account folder} {
	set f [file join [folder_dir $account $folder] dovecot-keywords]
	set out {}
	if {![file readable $f]} { return $out }
	set fh [::open $f r]
	fconfigure $fh -encoding utf-8
	set lines [split [::read $fh] "\n"]
	::close $fh
	foreach l $lines {
		if {[regexp {^(\d+)\s+(.+?)\s*$} $l -> n name] && $n < 26} {
			dict set out [format %c [expr {97 + $n}]] $name
		}
	}
	return $out
}

# The letter for NAME in the folder, given a new one if it has none (and ADD).
proc ::mail::store::keyword_letter {account folder name {add 1}} {
	set kw [keywords $account $folder]
	dict for {l n} $kw {
		if {$n eq $name} { return $l }
	}
	if {!$add} { return "" }
	for {set i 0} {$i < 26} {incr i} {
		set l [format %c [expr {97 + $i}]]
		if {![dict exists $kw $l]} break
	}
	if {$i == 26} { error "too many labels in $account/$folder" }
	dict set kw $l $name
	set text ""
	foreach k [lsort [dict keys $kw]] { append text "[expr {[::scan $k %c] - 97}] [dict get $kw $k]\n" }
	write_file [file join [folder_dir $account $folder] dovecot-keywords] $text 0
	return $l
}

proc ::mail::store::label_names {account folder flags {kw ""}} {
	if {$kw eq ""} { set kw [keywords $account $folder] }
	set out {}
	foreach c [split $flags ""] {
		if {[dict exists $kw $c]} { lappend out [dict get $kw $c] }
	}
	return $out
}

proc ::mail::store::labels {key} {
	lassign $key account folder
	return [label_names $account $folder [flags $key]]
}

proc ::mail::store::check_label {name} {
	if {$name eq "" || [regexp {[\s()\{\]%*"\\]} $name] || ![string is print $name]} { error "bad label name: $name" }
}

proc ::mail::store::add_label {key name} {
	check_label $name
	lassign $key account folder
	add_flags $key [keyword_letter $account $folder $name]
	return [labels $key]
}

proc ::mail::store::remove_label {key name} {
	lassign $key account folder
	set l [keyword_letter $account $folder $name 0]
	if {$l ne ""} { remove_flags $key $l }
	return [labels $key]
}

# Every label some message outside junk and trash carries, sorted.
proc ::mail::store::all_labels {} {
	set out {}
	foreach af [folders_of all] {
		lassign $af a f
		set kw [keywords $a $f]
		if {$kw eq ""} continue
		foreach file [files $a $f] { lappend out {*}[label_names $a $f [lindex $file 2] $kw] }
	}
	return [lsort -unique -dictionary $out]
}

# ---- moving ------------------------------------------------------------------------------------------

proc ::mail::store::move {key account folder} {
	lassign $key a0 f0 uid
	if {$a0 eq $account && $f0 eq $folder} { return $key }
	set p [path $key]
	set flags [flags $key]
	set names [label_names $a0 $f0 $flags]
	set d [create_folder $account $folder]
	# the standard flags stay; the keyword letters are those of the new folder
	set std [regsub -all {[a-z]} $flags {}]
	foreach n $names { append std [keyword_letter $account $folder $n] }
	set std [norm_flags $std]
	set nuid $uid
	if {![catch {path [list $account $folder $uid]}]} {
		# the same message is there already (a copy): this one gets a unique part of its own
		set nuid "[unique],S=[file size $p]"
	}
	# a message not yet seen by a reader stays in new/
	if {$std eq "" && [file tail [file dirname $p]] eq "new"} {
		set dest [file join $d new $nuid]
	} else {
		set dest [file join $d cur "$nuid:2,$std"]
	}
	if {[catch {file rename $p $dest}]} {
		# another file system: copy through tmp, then remove the original
		set tmp [file join $d tmp $nuid]
		file copy -force $p $tmp
		file rename -force $tmp $dest
		file delete $p
	}
	return [list $account $folder $nuid]
}

proc ::mail::store::trash {key} {
	lassign $key account folder
	if {[role $folder] eq "trash"} { return $key }
	set t [folder_of $account trash]
	if {$t eq ""} {
		set t Trash
		create_folder $account $t
	}
	return [move $key $account $t]
}

proc ::mail::store::delete {key} {
	file delete [path $key]
}

proc ::mail::store::scan {account folder} {
	set d [folder_dir $account $folder]
	set moved 0
	foreach p [glob -nocomplain -types f -directory [file join $d new] *] {
		set name [file tail $p]
		lassign [split_name $name] uid flags
		if {[catch {file rename $p [file join $d cur "$uid:2,[norm_flags $flags]"]}] == 0} { incr moved }
	}
	set old [expr {[clock seconds] - 36 * 3600}]
	foreach p [glob -nocomplain -types f -directory [file join $d tmp] *] {
		if {[file mtime $p] < $old} { catch {file delete $p} }
	}
	return $moved
}

# ---- the index ---------------------------------------------------------------------------------------

proc ::mail::store::esc {s} {
	set out ""
	foreach c [split [encoding convertto utf-8 $s] ""] {
		if {[regexp {^[A-Za-z0-9._-]$} $c]} { append out $c } else { append out [format %%%02X [::scan $c %c]] }
	}
	return $out
}

proc ::mail::store::index_file {account folder} {
	return [file join [cache_root] [esc $account] "[esc $folder].idx"]
}

proc ::mail::store::load_index {account folder} {
	variable mem
	variable version
	set k "$account\0$folder"
	if {[info exists mem($k)]} { return $mem($k) }
	set data {}
	set f [index_file $account $folder]
	if {[file readable $f] && ![catch {
		set fh [::open $f r]
		fconfigure $fh -encoding utf-8
		set head [gets $fh]
		set body [::read $fh]
		::close $fh
	}]} {
		# a damaged or older index is dropped and rebuilt
		if {$head eq "ribbon-mail-index $version" && [string is list $body] && [llength $body] % 2 == 0} {
			if {[catch {dict size $body}] == 0} { set data $body }
		}
	}
	set mem($k) $data
	return $data
}

proc ::mail::store::save_index {account folder data} {
	variable version
	set f [index_file $account $folder]
	file mkdir [file dirname $f]
	if {[catch {write_file $f "ribbon-mail-index $version\n$data" 0} err]} {
		# the index is a cache: a disk that cannot keep it only makes the next start slower
		return
	}
}

# The summary of a message's bytes (the part kept in the index).
proc ::mail::store::summarize {bytes file uid} {
	variable textmax
	set msg [::mail::mime::parse $bytes]
	set root [dict get $msg root]
	set hdr {apply {{msg name} { return [::mail::mime::raw_header [dict get $msg root] $name] }}}
	set msgid [lindex [::mail::mime::msgids [{*}$hdr $msg message-id]] 0]
	set refs [::mail::mime::msgids [{*}$hdr $msg references]]
	set irt [::mail::mime::msgids [{*}$hdr $msg in-reply-to]]
	if {$refs eq "" && $irt ne ""} { set refs [list [lindex $irt 0]] }
	set from [lindex [::mail::mime::addresses [{*}$hdr $msg from]] 0]
	if {$from eq ""} { set from [lindex [::mail::mime::addresses [{*}$hdr $msg sender]] 0] }
	if {$from eq ""} { set from {{} {}} }
	set date [::mail::mime::date [{*}$hdr $msg date]]
	if {$date eq "" && [regexp {^(\d{9,11})\.} $uid -> t]} { set date $t }
	if {$date eq ""} { set date [file mtime $file] }
	set body ""
	catch {set body [::mail::mime::body $msg]}
	set atts {}
	catch {
		foreach a [::mail::mime::attachments $msg] {
			lappend atts [dict filter $a key section name size type inline]
		}
	}
	set list ""
	set lid [::mail::mime::decode_words [{*}$hdr $msg list-id]]
	if {$lid ne ""} {
		if {[regexp {^\s*"?([^"<]*?)"?\s*<([^>]*)>} $lid -> lname lhost]} {
			set list [expr {[string trim $lname] ne "" ? [string trim $lname] : [lindex [split $lhost .] 0]}]
		} else {
			set list [lindex [split [string trim $lid "<> "] .] 0]
		}
	}
	set text [regsub -all {\s+} $body " "]
	if {[string length $text] > $textmax} { set text [string range $text 0 [expr {$textmax - 1}]] }
	return [dict create msgid $msgid refs $refs subject [string trim [regsub -all {\s+} [::mail::mime::header $msg subject] " "]] \
		from $from to [::mail::mime::addresses [{*}$hdr $msg to]] cc [::mail::mime::addresses [{*}$hdr $msg cc]] \
		date $date size [string length $bytes] snippet [::mail::mime::snippet $body] text $text atts $atts list $list]
}

# The folder's index, brought up to date with the files: {uid -> {size mtime summary}}; also the files.
proc ::mail::store::refresh {account folder} {
	variable mem
	set old [load_index $account $folder]
	set new {}
	set changed 0
	set fl [files $account $folder]
	foreach f $fl {
		lassign $f uid p
		if {[catch {file stat $p st}]} continue
		set e [expr {[dict exists $old $uid] ? [dict get $old $uid] : ""}]
		if {$e ne "" && [lindex $e 0] == $st(size) && [lindex $e 1] == $st(mtime)} {
			dict set new $uid $e
			continue
		}
		if {[catch {
			set fh [::open $p rb]
			set bytes [::read $fh]
			::close $fh
		}]} continue
		if {[catch {summarize $bytes $p $uid} sum]} {
			# a message the parser cannot read is still listed (with its delivery time), never lost from view
			set t [expr {[regexp {^(\d{9,11})\.} $uid -> t] ? $t : $st(mtime)}]
			set sum [dict create msgid "" refs {} subject "" from {{} {}} to {} cc {} date $t size $st(size) \
				snippet "" text "" atts {} list ""]
		}
		dict set new $uid [list $st(size) $st(mtime) $sum]
		set changed 1
	}
	if {[dict size $new] != [dict size $old]} { set changed 1 }
	set mem($account\0$folder) $new
	if {$changed} { save_index $account $folder $new }
	return [list $new $fl]
}

proc ::mail::store::live {account folder f kw} {
	lassign $f uid p flags innew
	return [dict create key [list $account $folder $uid] account $account folder $folder uid $uid path $p \
		flags $flags unread [expr {[string first S $flags] < 0}] flagged [expr {[string first F $flags] >= 0}] \
		replied [expr {[string first R $flags] >= 0}] draft [expr {[string first D $flags] >= 0}] \
		labels [label_names $account $folder $flags $kw] new $innew]
}

proc ::mail::store::messages {account folder} {
	lassign [refresh $account $folder] idx fl
	set kw [keywords $account $folder]
	set out {}
	foreach f $fl {
		set uid [lindex $f 0]
		if {![dict exists $idx $uid]} continue
		lappend out [dict merge [lindex [dict get $idx $uid] 2] [live $account $folder $f $kw]]
	}
	return [sort_by_date $out]
}

proc ::mail::store::sort_by_date {sums} {
	return [lsort -command {apply {{a b} {
		set c [expr {[dict get $a date] - [dict get $b date]}]
		if {$c != 0} { return [expr {$c < 0 ? -1 : 1}] }
		return [string compare [dict get $a uid] [dict get $b uid]]
	}}} $sums]
}

proc ::mail::store::summary {key} {
	lassign $key account folder uid
	foreach s [messages $account $folder] {
		if {[dict get $s uid] eq $uid} { return $s }
	}
	error "no message $uid in $account/$folder"
}

proc ::mail::store::count {account folder} {
	set unread 0
	set flagged 0
	set fl [files $account $folder]
	foreach f $fl {
		set flags [lindex $f 2]
		if {[string first S $flags] < 0} { incr unread }
		if {[string first F $flags] >= 0} { incr flagged }
	}
	return [dict create unread $unread total [llength $fl] flagged $flagged]
}

# ---- views -------------------------------------------------------------------------------------------

# The {account folder} pairs a view reads.
proc ::mail::store::folders_of {view} {
	set out {}
	set kind [lindex $view 0]
	switch -- $kind {
		folder { return [list [lrange $view 1 2]] }
		account { set accts [list [lindex $view 1]] }
		default { set accts [accounts] }
	}
	foreach a $accts {
		foreach f [folders $a] {
			set r [role $f]
			switch -- $kind {
				inboxes { if {$r eq "inbox"} { lappend out [list $a $f] } }
				drafts - sent - archive - junk - trash { if {$r eq $kind} { lappend out [list $a $f] } }
				flagged - label - account - all { if {$r ni {junk trash}} { lappend out [list $a $f] } }
				default { error "unknown view: $view" }
			}
		}
	}
	return $out
}

proc ::mail::store::in_view {view s} {
	switch -- [lindex $view 0] {
		flagged { return [dict get $s flagged] }
		label { return [expr {[lindex $view 1] in [dict get $s labels]}] }
		default { return 1 }
	}
}

proc ::mail::store::view {view} {
	set out {}
	foreach af [folders_of $view] {
		foreach s [messages {*}$af] {
			if {[in_view $view $s]} { lappend out $s }
		}
	}
	return [sort_by_date $out]
}

# dict unread total of a view, from the file names alone (no message is parsed).
proc ::mail::store::view_count {view} {
	set unread 0
	set total 0
	foreach af [folders_of $view] {
		lassign $af a f
		if {[lindex $view 0] in {flagged label}} {
			set kw [keywords $a $f]
			foreach file [files $a $f] {
				set flags [lindex $file 2]
				set s [dict create flagged [expr {[string first F $flags] >= 0}] labels [label_names $a $f $flags $kw]]
				if {![in_view $view $s]} continue
				incr total
				if {[string first S $flags] < 0} { incr unread }
			}
		} else {
			set c [count $a $f]
			incr unread [dict get $c unread]
			incr total [dict get $c total]
		}
	}
	return [dict create unread $unread total $total]
}

# The unread messages an account has where new mail lands: every folder but drafts, sent, junk and trash.
proc ::mail::store::account_unread {account} {
	set n 0
	foreach f [folders $account] {
		if {[role $f] in {drafts sent junk trash}} continue
		incr n [dict get [count $account $f] unread]
	}
	return $n
}
