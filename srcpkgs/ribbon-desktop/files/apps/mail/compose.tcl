# compose.tcl - writing mail (U41): the message a reply, a forward or a new message becomes, and its draft. No Tk.
#
#   mail::compose::reply SUMMARY MINE MODE    a new draft dict answering SUMMARY. MODE: reply | all | forward.
#                                             MINE: your addresses (left out of Reply all)
#   mail::compose::build DRAFT ?NOW?          the RFC 5322 message (bytes) of a draft: text/plain UTF-8 in
#                                             quoted-printable, multipart/mixed with the attachments (base64)
#   mail::compose::recipients DRAFT           the addresses it goes to (To and Cc), for SMTP
#   mail::compose::save_draft DRAFT           writes it to its account's Drafts (\Draft \Seen), replacing the
#                                             draft it was saved as before; returns the draft with its new key
#   mail::compose::discard DRAFT              removes its saved copy
#   mail::compose::parse_address TEXT         {name address} of "Anna Berg <anna@x>" or "anna@x"; "" if no address
#   mail::compose::size_text BYTES            "184 KB", "2.4 MB" (as the boards write sizes)
#
# A draft is a dict: account from ({name address}) to cc (lists of {name address}) subject text atts (files:
# dicts path name size, or, from a forward, dicts key section name size) inreplyto references key (its saved copy
# in Drafts, or "") answers (the key of the message it answers, or "") mode.

namespace eval ::mail::compose {
	variable seq 0
}

proc ::mail::compose::parse_address {text} {
	set text [string trim $text]
	if {[regexp {^(.*)<([^<>@\s]+@[^<>\s]+)>\s*$} $text -> name addr]} {
		return [list [string trim [string trim $name] "\""] $addr]
	}
	if {[regexp {^[^\s<>@,;]+@[^\s<>@,;]+\.[^\s<>@,;]+$} $text]} { return [list "" $text] }
	return ""
}

# Can ADDR go into a header and an SMTP command as it is? (No blank, control character, "<", ">", "," or ";":
# a received message's addresses can hold a bare CR, which the wire would make a new header line.)
proc ::mail::compose::valid {addr} {
	regexp {^[^\s[:cntrl:]<>@,;]+@[^\s[:cntrl:]<>@,;]+$} $addr
}

proc ::mail::compose::size_text {n} {
	if {$n < 1000} { return "$n B" }
	if {$n < 1000000} { return "[expr {max(1, round($n / 1000.0))}] KB" }
	return "[format %.1f [expr {$n / 1000000.0}]] MB"
}

# "Re: " once; "Fwd: " once
proc ::mail::compose::prefixed {prefix subject} {
	set base [string trim $subject]
	if {[string match -nocase "${prefix}*" $base]} { return $base }
	return "$prefix $base"
}

proc ::mail::compose::reply {s mine mode} {
	set lower [lmap m $mine {string tolower $m}]
	set to {}
	set cc {}
	set from [dict get $s from]
	# a received message's addresses: only the ones that are addresses
	foreach k {to cc} { dict set s $k [lmap a [dict get $s $k] {expr {[valid [lindex $a 1]] ? $a : [continue]}}] }
	set fromme [expr {[string tolower [lindex $from 1]] in $lower}]
	if {$mode eq "forward"} {
		set subject [prefixed Fwd: [dict get $s subject]]
	} else {
		set subject [prefixed Re: [dict get $s subject]]
		# answering your own message goes to the people it went to
		if {$fromme} { set to [dict get $s to] } elseif {[valid [lindex $from 1]]} { set to [list $from] }
		if {$mode eq "all"} {
			foreach a [concat [expr {$fromme ? {} : [dict get $s to]}] [dict get $s cc]] {
				if {[string tolower [lindex $a 1]] in $lower} continue
				if {[lsearch -exact [lmap x [concat $to $cc] {string tolower [lindex $x 1]}] [string tolower [lindex $a 1]]] >= 0} continue
				lappend cc $a
			}
		}
	}
	set refs [dict get $s refs]
	set msgid [dict get $s msgid]
	set atts {}
	set text ""
	if {$mode eq "forward"} {
		foreach a [dict get $s atts] {
			lappend atts [dict create key [dict get $s key] section [dict get $a section] name [dict get $a name] size [dict get $a size]]
		}
		set text "\n\n---------- Forwarded message ----------\nFrom: [Show $from]\nDate: [clock format [dict get $s date] -format {%a, %e %b %Y %H:%M} -locale C]\nSubject: [dict get $s subject]\nTo: [join [lmap a [dict get $s to] {Show $a}] {, }]\n\n[Body $s]"
	}
	return [dict create account [dict get $s account] from "" to $to cc $cc subject $subject text $text atts $atts \
		inreplyto [expr {$mode eq "forward" || $msgid eq "" ? "" : $msgid}] \
		references [expr {$mode eq "forward" || $msgid eq "" ? {} : [concat $refs [list $msgid]]}] \
		key "" answers [expr {$mode eq "forward" ? "" : [dict get $s key]}] mode $mode]
}

proc ::mail::compose::Show {a} {
	lassign $a n m
	if {$n eq ""} { return $m }
	return "$n <$m>"
}

proc ::mail::compose::Body {s} {
	if {[catch {mail::mime::body [mail::mime::parse [mail::store::read [dict get $s key]]]} t]} { return "" }
	return $t
}

proc ::mail::compose::recipients {d} {
	set out {}
	foreach a [concat [dict get $d to] [dict get $d cc]] {
		if {[lindex $a 1] ni $out} { lappend out [lindex $a 1] }
	}
	return $out
}

# ---- encoding ---------------------------------------------------------------------------------------------
# A header value: RFC 2047 encoded words (UTF-8, B) when it is not plain ASCII.
proc ::mail::compose::word {s} {
	if {[regexp {^[\x20-\x7e]*$} $s]} { return $s }
	set out {}
	set chunk ""
	foreach ch [split $s ""] {
		# an encoded word is at most 75 characters: 45 bytes of text fit
		if {[string length [encoding convertto utf-8 "$chunk$ch"]] > 45} { lappend out $chunk; set chunk "" }
		append chunk $ch
	}
	lappend out $chunk
	return [join [lmap c $out {string cat "=?UTF-8?B?" [binary encode base64 [encoding convertto utf-8 $c]] "?="}] " "]
}

proc ::mail::compose::addr {a} {
	lassign $a n m
	# never a line break in a header
	regsub -all {[[:cntrl:]]} $m "" m
	if {$n eq ""} { return $m }
	if {[regexp {^[\x20-\x7e]*$} $n]} {
		if {[regexp {[()<>@,;:\\".\[\]]} $n]} { set n "\"[string map {\\ \\\\ \" \\\"} $n]\"" }
		return "$n <$m>"
	}
	return "[word $n] <$m>"
}

proc ::mail::compose::qp {text} {
	set out {}
	foreach line [split $text \n] {
		set b [encoding convertto utf-8 $line]
		set enc ""
		set n [string length $b]
		for {set i 0} {$i < $n} {incr i} {
			set c [string index $b $i]
			scan $c %c v
			if {($v >= 33 && $v <= 126 && $v != 61) || (($v == 32 || $v == 9) && $i < $n - 1)} {
				set e $c
			} else {
				set e [format =%02X $v]
			}
			# soft line breaks keep lines under 76
			set last [string range $enc [expr {[string last \n $enc] + 1}] end]
			if {[string length $last] + [string length $e] > 75} { append enc "=\n" }
			append enc $e
		}
		lappend out $enc
	}
	return [string map [list \n \r\n] [join $out \n]]
}

proc ::mail::compose::b64 {bytes} {
	set s [binary encode base64 -maxlen 76 $bytes]
	return [string map [list \n \r\n] $s]
}

proc ::mail::compose::msgid {d} {
	variable seq
	set dom [lindex [split [lindex [dict get $d from] 1] @] 1]
	if {$dom eq ""} { set dom localhost }
	return "<[clock seconds].[pid].[incr seq].[expr {int(rand() * 1e9)}]@$dom>"
}

proc ::mail::compose::att_bytes {a} {
	if {[dict exists $a path]} {
		set fh [::open [dict get $a path] rb]
		set b [::read $fh]
		::close $fh
		return $b
	}
	set msg [mail::mime::parse [mail::store::read [dict get $a key]]]
	return [mail::mime::data $msg [dict get $a section]]
}

proc ::mail::compose::att_type {name} {
	switch -- [string tolower [file extension $name]] {
		.pdf { return application/pdf }
		.png { return image/png }
		.jpg - .jpeg { return image/jpeg }
		.gif { return image/gif }
		.webp { return image/webp }
		.txt { return text/plain }
		.ods { return application/vnd.oasis.opendocument.spreadsheet }
		.odt { return application/vnd.oasis.opendocument.text }
		.zip { return application/zip }
		default { return application/octet-stream }
	}
}

proc ::mail::compose::build {d {now ""}} {
	if {$now eq ""} { set now [clock seconds] }
	set h {}
	lappend h "Date: [clock format $now -format {%a, %d %b %Y %H:%M:%S %z} -locale C]"
	lappend h "From: [addr [dict get $d from]]"
	if {[llength [dict get $d to]]} { lappend h "To: [join [lmap a [dict get $d to] {addr $a}] ",\r\n "]" }
	if {[llength [dict get $d cc]]} { lappend h "Cc: [join [lmap a [dict get $d cc] {addr $a}] ",\r\n "]" }
	lappend h "Subject: [word [dict get $d subject]]"
	lappend h "Message-ID: [msgid $d]"
	if {[dict get $d inreplyto] ne ""} { lappend h "In-Reply-To: <[dict get $d inreplyto]>" }
	if {[llength [dict get $d references]]} { lappend h "References: [join [lmap r [dict get $d references] {string cat < $r >}] "\r\n "]" }
	lappend h "MIME-Version: 1.0"
	set text "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n[qp [dict get $d text]]\r\n"
	set head [encoding convertto utf-8 [join $h \r\n]]
	if {![llength [dict get $d atts]]} { return "$head\r\n[encoding convertto utf-8 $text]" }
	set bnd "=_ribbon_[clock seconds]_[expr {int(rand() * 1e9)}]"
	set out "$head\r\nContent-Type: multipart/mixed; boundary=\"$bnd\"\r\n\r\n--$bnd\r\n[encoding convertto utf-8 $text]"
	foreach a [dict get $d atts] {
		set name [dict get $a name]
		set fn [expr {[regexp {^[\x20-\x7e]*$} $name] ? "filename=\"[string map {\" \\\"} $name]\"" : "filename*=UTF-8''[Pct $name]"}]
		append out "\r\n--$bnd\r\nContent-Type: [att_type $name]\r\nContent-Transfer-Encoding: base64\r\n"
		append out "Content-Disposition: [expr {[dict exists $a inline] && [dict get $a inline] ? "inline" : "attachment"}]; $fn\r\n\r\n"
		append out [b64 [att_bytes $a]]
	}
	append out "\r\n--$bnd--\r\n"
	return $out
}

proc ::mail::compose::Pct {s} {
	set out ""
	foreach b [split [encoding convertto utf-8 $s] ""] {
		scan $b %c v
		if {[string match {[A-Za-z0-9._-]} $b]} { append out $b } else { append out [format %%%02X $v] }
	}
	return $out
}

# ---- drafts -----------------------------------------------------------------------------------------------
proc ::mail::compose::save_draft {d} {
	set acct [dict get $d account]
	set folder [mail::store::folder_of $acct drafts]
	if {$folder eq ""} { set folder Drafts; mail::store::create_folder $acct $folder }
	set key [mail::store::deliver $acct $folder [build $d] DS]
	if {[dict get $d key] ne ""} { catch {mail::store::delete [dict get $d key]} }
	dict set d key $key
	return $d
}

proc ::mail::compose::discard {d} {
	if {[dict get $d key] ne ""} { catch {mail::store::delete [dict get $d key]} }
	dict set d key ""
	return $d
}
