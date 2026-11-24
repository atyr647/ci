# mime.tcl - one message's bytes as headers and a MIME tree (U39). No Tk. The message is kept as its raw bytes
# (a byte string: one character per byte) and every part is a pair of offsets into it, so a part's content is
# decoded only when it is asked for: listing a message's attachments never decodes them.
#
#   mail::mime::parse BYTES             a message: a dict {raw BYTES root PART}
#   mail::mime::header MSG NAME         the first NAME header, unfolded and decoded (RFC 2047); "" if none
#   mail::mime::raw_header PART NAME    the first NAME header of PART as bytes, unfolded; "" if none
#   mail::mime::decode_words BYTES      a header value with its encoded words and 8-bit text decoded
#   mail::mime::addresses BYTES         an address list as {name address} pairs (groups flattened)
#   mail::mime::msgids BYTES            the <message-ids> in a Message-ID / References / In-Reply-To value
#   mail::mime::date BYTES              an RFC 5322 date as seconds since the epoch; "" if it cannot be read
#   mail::mime::leaves MSG              every leaf part, in order
#   mail::mime::part MSG SECTION        the part with that section number ("" is the whole message, "1.2" ...)
#   mail::mime::body MSG                the text of the message's body parts (text/plain chosen over HTML)
#   mail::mime::attachments MSG         the attachments and inline images, each a dict (see below); not decoded
#   mail::mime::data MSG SECTION        that part's content, transfer-decoded, as bytes
#   mail::mime::text MSG SECTION        that part's content as text (its charset converted, LF line ends)
#   mail::mime::save MSG SECTION FILE   writes the decoded content to FILE (through a temporary and a rename)
#   mail::mime::snippet TEXT ?LEN?      a one-line preview: quotes, the "wrote:" line and the signature dropped
#   mail::mime::html_text HTML          HTML as plain text
#
# A part is a dict: section, type ("text/plain", lowercased), params (a dict, names lowercased), disposition
# ("inline", "attachment" or ""), dparams, encoding (the transfer encoding, lowercased), headers ({name bytes}
# pairs, names lowercased), hstart/bstart/bend (offsets into raw: headers, content, end of content) and, for a
# multipart or a message/rfc822, children.
# An attachment is a dict: section, name (decoded), type, size (the decoded size in bytes, computed without
# decoding), inline (1 for an image shown in the text: a related part, or one marked inline), cid (Content-ID).
#
# Broken mail is read as far as it goes: a header line without a colon is skipped, a multipart without its
# boundary or its closing delimiter ends at the end of the message, bad base64 and quoted-printable are decoded
# leniently, an unknown charset is read as UTF-8, and text that is not valid UTF-8 is read as Windows-1252.

namespace eval ::mail::mime {
	variable maxdepth 24     ;# nesting deeper than this is read as one opaque part
	variable maxparts 2000   ;# parts past this many are not split further
	variable qpmap {}        ;# =XX -> byte, built once
	variable charsets {
		us-ascii utf-8 ascii utf-8 utf8 utf-8 unicode-1-1-utf-8 utf-8 latin1 cp1252 iso-8859-1 cp1252
		iso8859-1 cp1252 iso_8859-1 cp1252 l1 cp1252 latin-1 cp1252 x-user-defined cp1252
		iso-8859-2 iso8859-2 iso-8859-3 iso8859-3 iso-8859-4 iso8859-4 iso-8859-5 iso8859-5 iso-8859-6 iso8859-6
		iso-8859-7 iso8859-7 iso-8859-8 iso8859-8 iso-8859-8-i iso8859-8 iso-8859-9 cp1254 iso-8859-10 iso8859-10
		iso-8859-11 iso8859-11 iso-8859-13 iso8859-13 iso-8859-14 iso8859-14 iso-8859-15 iso8859-15
		iso-8859-16 iso8859-16 latin9 iso8859-15 latin2 iso8859-2
		windows-1250 cp1250 windows-1251 cp1251 windows-1252 cp1252 windows-1253 cp1253 windows-1254 cp1254
		windows-1255 cp1255 windows-1256 cp1256 windows-1257 cp1257 windows-1258 cp1258 windows-874 cp874
		koi8-r koi8-r koi8-u koi8-u ibm866 cp866 cp866 cp866 ibm850 cp850 ibm437 cp437
		gb2312 cp936 gbk cp936 gb18030 cp936 x-gbk cp936 euc-cn cp936 hz-gb-2312 cp936 cp936 cp936
		big5 cp950 big5-hkscs cp950 cp950 cp950
		shift_jis cp932 shift-jis cp932 sjis cp932 x-sjis cp932 ms_kanji cp932 windows-31j cp932 cp932 cp932
		euc-jp euc-jp iso-2022-jp iso2022-jp csiso2022jp iso2022-jp
		euc-kr cp949 ks_c_5601-1987 cp949 ks_c_5601 cp949 windows-949 cp949 cp949 cp949 iso-2022-kr iso2022-kr
		tis-620 tis-620 macintosh macRoman x-mac-roman macRoman
	}
}

# ---- bytes and text ----------------------------------------------------------------------------------

# The Tcl encoding for a MIME charset name; utf-8 for one Tcl does not have.
proc ::mail::mime::encoding_of {charset} {
	variable charsets
	set cs [string tolower [string trim $charset " \t\"'"]]
	# RFC 2231 allows a language after a star: utf-8*en
	regsub {\*.*$} $cs {} cs
	if {[dict exists $charsets $cs]} { return [dict get $charsets $cs] }
	if {$cs in [encoding names]} { return $cs }
	if {[regexp {^(?:cp|windows-?|x-cp)(\d+)$} $cs -> n] && "cp$n" in [encoding names]} { return cp$n }
	if {[regexp {^iso[-_]?8859[-_]?(\d+)$} $cs -> n] && "iso8859-$n" in [encoding names]} { return iso8859-$n }
	return utf-8
}

# Bytes known to be UTF-8 or not: valid UTF-8 survives the round trip unchanged.
proc ::mail::mime::is_utf8 {bytes} {
	if {![regexp {[\x80-\xff]} $bytes]} { return 1 }
	# the byte patterns of well-formed UTF-8 (RFC 3629), no overlongs or surrogates
	return [regexp {^(?:[\x00-\x7f]|[\xc2-\xdf][\x80-\xbf]|\xe0[\xa0-\xbf][\x80-\xbf]|[\xe1-\xec\xee\xef][\x80-\xbf]{2}|\xed[\x80-\x9f][\x80-\xbf]|\xf0[\x90-\xbf][\x80-\xbf]{2}|[\xf1-\xf3][\x80-\xbf]{3}|\xf4[\x80-\x8f][\x80-\xbf]{2})*$} $bytes]
}

# Bytes in CHARSET as text. A charset that cannot be right (UTF-8 or ASCII given for bytes that are not
# UTF-8) falls back to Windows-1252, which maps every byte.
proc ::mail::mime::convert {bytes charset} {
	set enc [encoding_of $charset]
	if {$enc eq "utf-8"} {
		if {[is_utf8 $bytes]} { return [encoding convertfrom utf-8 $bytes] }
		return [encoding convertfrom cp1252 $bytes]
	}
	if {[catch {encoding convertfrom $enc $bytes} text]} { return [encoding convertfrom cp1252 $bytes] }
	return $text
}

# 8-bit header text with no charset: UTF-8 when it is, else Windows-1252.
proc ::mail::mime::raw_text {bytes} {
	if {[is_utf8 $bytes]} { return [encoding convertfrom utf-8 $bytes] }
	return [encoding convertfrom cp1252 $bytes]
}

proc ::mail::mime::b64 {data} {
	regsub -all {[^A-Za-z0-9+/]} $data {} data
	switch [expr {[string length $data] % 4}] {
		1 { set data [string range $data 0 end-1] }
		2 { append data == }
		3 { append data = }
	}
	if {[catch {binary decode base64 $data} out]} { return "" }
	return $out
}

proc ::mail::mime::qp {data {header 0}} {
	variable qpmap
	if {$qpmap eq ""} {
		set hex 0123456789ABCDEF
		for {set i 0} {$i < 256} {incr i} {
			set hi [string index $hex [expr {$i >> 4}]]
			set lo [string index $hex [expr {$i & 15}]]
			set ch [format %c $i]
			foreach h [lsort -unique [list $hi [string tolower $hi]]] {
				foreach l [lsort -unique [list $lo [string tolower $lo]]] { lappend qpmap "=$h$l" $ch }
			}
		}
	}
	if {$header} {
		set data [string map {_ " "} $data]
	} else {
		# trailing blanks are not part of a line (RFC 2045 6.7); a soft break joins two lines
		regsub -all {[ \t]+(\r?\n)} $data {\1} data
		regsub -all {=[ \t]*\r?\n} $data {} data
		regsub {=[ \t]*$} $data {} data
	}
	return [string map $qpmap $data]
}

# ---- headers -----------------------------------------------------------------------------------------

# The header block of the bytes from START: {headers bodystart}. headers is a list of {name value} pairs, names
# lowercased, values unfolded bytes with the outer blanks trimmed.
proc ::mail::mime::read_headers {raw start end} {
	set rest [string range $raw $start [expr {$end - 1}]]
	# a part that starts with a blank line has no headers
	if {[regexp {^\r?\n} $rest m]} { return [list {} [expr {$start + [string length $m]}]] }
	if {[regexp -indices {\r?\n\r?\n} $rest sep]} {
		set block [string range $rest 0 [expr {[lindex $sep 0] - 1}]]
		set bstart [expr {$start + [lindex $sep 1] + 1}]
	} else {
		set block $rest
		set bstart $end
	}
	set headers {}
	set lines [split [string map {"\r\n" "\n"} $block] "\n"]
	# an mbox "From " line before the headers is not a header
	if {[string match "From *" [lindex $lines 0]]} { set lines [lrange $lines 1 end] }
	set cur ""
	foreach line $lines {
		# a bare CR left in a line is whitespace (RFC 5322 allows none there): kept, it would end a header line
		# wherever the value is written out again (a reply's To:, an SMTP command)
		set line [string map {"\r" " "} $line]
		if {[regexp {^[ \t]} $line]} {
			if {$cur ne ""} { lset headers end 1 "[lindex $headers end 1] [string trim $line]" }
			continue
		}
		if {[regexp {^([^:\s]+)[ \t]*:(.*)$} $line -> name value]} {
			set cur [string tolower $name]
			lappend headers [list $cur [string trim $value]]
		} else {
			set cur ""
		}
	}
	return [list $headers $bstart]
}

proc ::mail::mime::hget {headers name} {
	set name [string tolower $name]
	foreach h $headers {
		if {[lindex $h 0] eq $name} { return [lindex $h 1] }
	}
	return ""
}

proc ::mail::mime::raw_header {part name} {
	return [hget [dict get $part headers] $name]
}

proc ::mail::mime::header {msg name} {
	return [decode_words [raw_header [dict get $msg root] $name]]
}

# RFC 2047: encoded words decoded, the blanks between two of them dropped, the bytes of adjacent words in one
# charset joined before they are converted (a character may be split across two words); the other text read as
# UTF-8 or Windows-1252.
proc ::mail::mime::decode_words {value} {
	set re {=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?=}
	set out ""
	set pos 0
	set pend ""      ;# bytes of the encoded words not yet converted
	set pendcs ""
	set gap ""       ;# the text after the last encoded word, kept until we know another does not follow
	# regexp -all -inline -indices gives each match followed by its three groups
	set all [regexp -all -inline -indices $re $value]
	if {$all eq ""} { return [raw_text $value] }
	set i 0
	while {$i < [llength $all]} {
		lassign [lindex $all $i] ms me
		lassign [lindex $all [expr {$i + 1}]] cs0 cs1
		lassign [lindex $all [expr {$i + 2}]] e0 e1
		lassign [lindex $all [expr {$i + 3}]] t0 t1
		incr i 4
		set between [string range $value $pos [expr {$ms - 1}]]
		set cs [string range $value $cs0 $cs1]
		set kind [string toupper [string range $value $e0 $e1]]
		set txt [string range $value $t0 $t1]
		set bytes [expr {$kind eq "B" ? [b64 $txt] : [qp $txt 1]}]
		if {$pendcs ne "" && [string trim $between] eq ""} {
			# a word right after another (only blanks between): the blanks go
			if {[string equal -nocase $pendcs $cs]} {
				append pend $bytes
			} else {
				append out [convert $pend $pendcs]
				set pend $bytes
				set pendcs $cs
			}
		} else {
			if {$pendcs ne ""} { append out [convert $pend $pendcs] }
			append out [raw_text $between]
			set pend $bytes
			set pendcs $cs
		}
		set pos [expr {$me + 1}]
	}
	if {$pendcs ne ""} { append out [convert $pend $pendcs] }
	append out [raw_text [string range $value $pos end]]
	return $out
}

# A structured value's "type; a=b; c="d"" as {type params}, params a dict with names lowercased. RFC 2231
# continuations (name*0, name*1*) and charsets (name*=utf-8''%E2%98%83) are joined and decoded.
proc ::mail::mime::params {value} {
	set value [string trim $value]
	set semi [string first ";" $value]
	if {$semi < 0} { return [list [string tolower [string trim $value]] {}] }
	set type [string tolower [string trim [string range $value 0 [expr {$semi - 1}]]]]
	set rest [string range $value [expr {$semi + 1}] end]
	set raw {}
	set n [string length $rest]
	set i 0
	while {$i < $n} {
		# name
		if {![regexp -start $i {\A[\s;]*([^=;\s]+)\s*} $rest m name]} break
		set i [expr {$i + [string length $m]}]
		if {[string index $rest $i] ne "="} { continue }
		incr i
		while {$i < $n && [string is space [string index $rest $i]]} { incr i }
		if {[string index $rest $i] eq "\""} {
			incr i
			set v ""
			while {$i < $n} {
				set c [string index $rest $i]
				if {$c eq "\\" && $i + 1 < $n} { append v [string index $rest [incr i]]; incr i; continue }
				if {$c eq "\""} { incr i; break }
				append v $c
				incr i
			}
		} else {
			set j [string first ";" $rest $i]
			if {$j < 0} { set j $n }
			set v [string trim [string range $rest $i [expr {$j - 1}]]]
			set i $j
		}
		lappend raw [string tolower $name] $v
	}
	# RFC 2231: join the numbered pieces, then decode the starred ones
	set out {}
	set pieces {}
	foreach {name v} $raw {
		if {[regexp {^(.+?)\*(\d+)(\*?)$} $name -> base num star]} {
			dict set pieces $base [scan $num %d] [list $v $star]
		} elseif {[regexp {^(.+)\*$} $name -> base]} {
			dict set out $base [ext_value $v 1]
		} elseif {![dict exists $out $name]} {
			dict set out $name $v
		}
	}
	dict for {base nums} $pieces {
		set bytes ""
		set cs ""
		foreach num [lsort -integer [dict keys $nums]] {
			lassign [dict get $nums $num] v star
			if {$num == 0 && $star eq "*" && [regexp {^([^']*)'[^']*'(.*)$} $v -> cs v]} {}
			append bytes [expr {$star eq "*" ? [pct $v] : $v}]
		}
		dict set out $base [expr {$cs ne "" ? [convert $bytes $cs] : [raw_text $bytes]}]
	}
	return [list $type $out]
}

proc ::mail::mime::pct {v} {
	set out ""
	set n [string length $v]
	for {set i 0} {$i < $n} {incr i} {
		set c [string index $v $i]
		if {$c eq "%" && [string is xdigit -strict [string range $v $i+1 $i+2]] && [string length [string range $v $i+1 $i+2]] == 2} {
			append out [format %c 0x[string range $v $i+1 $i+2]]
			incr i 2
		} else {
			append out $c
		}
	}
	return $out
}

# RFC 2231 charset'language'%XX value.
proc ::mail::mime::ext_value {v star} {
	if {[regexp {^([^']*)'[^']*'(.*)$} $v -> cs rest]} {
		return [convert [pct $rest] [expr {$cs eq "" ? "utf-8" : $cs}]]
	}
	return [raw_text [pct $v]]
}

# ---- addresses, message ids, dates -------------------------------------------------------------------

# An address list as {name address} pairs. Quoted names, comments (a comment is the name when there is no other),
# angle addresses, bare addresses, groups ("Team: a@x, b@y;") and encoded words in names are understood.
proc ::mail::mime::addresses {value} {
	set out {}
	set n [string length $value]
	set i 0
	set phrase ""   ;# the text outside <>, quotes kept as text
	set comment ""
	set angle ""
	set inangle 0
	set seen_angle 0
	set flush {
		set p [string trim [regsub -all {\s+} $phrase " "]]
		if {$seen_angle} {
			set addr [string trim $angle]
			set name $p
		} else {
			set addr ""
			set name ""
			# a bare address: the word with an @, the rest of the phrase is not a name
			foreach w [split $p " "] { if {[string first @ $w] >= 0} { set addr $w } }
			if {$addr eq "" && $p ne ""} { set addr $p }
		}
		if {$name eq ""} { set name [string trim $comment] }
		set name [string trim [decode_words $name] " \t\"'"]
		set addr [string trim [raw_text $addr] " \t<>\"'"]
		if {$addr ne "" || $name ne ""} { lappend out [list $name $addr] }
		set phrase ""
		set comment ""
		set angle ""
		set seen_angle 0
	}
	while {$i < $n} {
		set c [string index $value $i]
		if {$c eq "\""} {
			# a quoted string; the quotes go, escapes are undone
			incr i
			set q ""
			while {$i < $n} {
				set d [string index $value $i]
				if {$d eq "\\" && $i + 1 < $n} { append q [string index $value [incr i]]; incr i; continue }
				if {$d eq "\""} break
				append q $d
				incr i
			}
			if {$inangle} { append angle $q } else { append phrase $q }
		} elseif {$c eq "("} {
			set depth 1
			incr i
			set q ""
			while {$i < $n && $depth > 0} {
				set d [string index $value $i]
				if {$d eq "\\" && $i + 1 < $n} { append q [string index $value [incr i]]; incr i; continue }
				if {$d eq "("} { incr depth } elseif {$d eq ")"} { incr depth -1; if {$depth == 0} break }
				append q $d
				incr i
			}
			if {$comment eq ""} { set comment $q }
		} elseif {$c eq "<" && !$inangle} {
			set inangle 1
			set seen_angle 1
			set angle ""
		} elseif {$c eq ">" && $inangle} {
			set inangle 0
		} elseif {$inangle} {
			append angle $c
		} elseif {$c eq ","} {
			eval $flush
		} elseif {$c eq ":" && !$seen_angle && [string first @ $phrase] < 0} {
			# a group's name: it names no address
			set phrase ""
			set comment ""
		} elseif {$c eq ";"} {
			eval $flush
		} else {
			append phrase $c
		}
		incr i
	}
	eval $flush
	return $out
}

proc ::mail::mime::msgids {value} {
	set ids {}
	foreach {- id} [regexp -all -inline {<([^<>\s]+)>} $value] { lappend ids $id }
	if {$ids eq ""} {
		# no angle brackets (broken mail): words with an @ are the ids
		foreach w [regexp -all -inline {[^\s<>,;]+@[^\s<>,;]+} $value] { lappend ids $w }
	}
	return $ids
}

proc ::mail::mime::date {value} {
	regsub -all {\([^)]*\)} $value { } v
	set v [string trim [regsub -all {\s+} $v " "]]
	regsub {^[A-Za-z]+,?\s*} $v {} v
	if {![regexp -nocase {^(\d{1,2})[ -]([a-z]{3})[a-z]*\.?[ -](\d{2,4})\s+(\d{1,2})[:.](\d{2})(?:[:.](\d{2}))?\s*(.*)$} $v -> d mon y hh mm ss zone]} {
		return ""
	}
	set months {jan 1 feb 2 mar 3 apr 4 may 5 jun 6 jul 7 aug 8 sep 9 oct 10 nov 11 dec 12}
	set mon [string tolower $mon]
	if {![dict exists $months $mon]} { return "" }
	set m [dict get $months $mon]
	scan $d %d d
	scan $y %d y
	scan $hh %d hh
	scan $mm %d mm
	if {$ss eq ""} { set ss 0 } else { scan $ss %d ss }
	if {[string length $y] <= 2 || $y < 100} { set y [expr {$y < 50 ? 2000 + $y : 1900 + $y}] } elseif {$y < 1000} { incr y 1900 }
	if {$d < 1 || $d > 31 || $hh > 23 || $mm > 59 || $ss > 60} { return "" }
	if {$ss == 60} { set ss 59 }
	set off 0
	set zone [string trim $zone]
	if {[regexp {^([+-])(\d{2})(\d{2})} $zone -> sign zh zm]} {
		scan $zh %d zh
		scan $zm %d zm
		set off [expr {($zh * 3600 + $zm * 60) * ($sign eq "-" ? -1 : 1)}]
	} else {
		set zones {ut 0 utc 0 gmt 0 z 0 est -5 edt -4 cst -6 cdt -5 mst -7 mdt -6 pst -8 pdt -7}
		set z [string tolower [lindex [split $zone " "] 0]]
		if {[dict exists $zones $z]} { set off [expr {[dict get $zones $z] * 3600}] }
	}
	if {[catch {clock scan [::format "%04d-%02d-%02d %02d:%02d:%02d" $y $m $d $hh $mm $ss] -format "%Y-%m-%d %H:%M:%S" -gmt 1} t]} {
		return ""
	}
	# a day that does not exist in the month (31 Feb) rolls over in clock scan: refuse it
	if {[clock format $t -format %d -gmt 1] != $d} { return "" }
	return [expr {$t - $off}]
}

# ---- the MIME tree -----------------------------------------------------------------------------------

proc ::mail::mime::parse {bytes} {
	variable count 0
	return [dict create raw $bytes root [entity $bytes 0 [string length $bytes] "" 0 text/plain]]
}

# The part in RAW from START to END: its headers, its content range and its children.
proc ::mail::mime::entity {raw start end section depth deftype} {
	variable maxdepth
	variable maxparts
	variable count
	incr count
	lassign [read_headers $raw $start $end] headers bstart
	set ct [hget $headers content-type]
	lassign [params $ct] type ps
	if {$type eq "" || ![regexp {^[a-z0-9!#$&.+^_-]+/[a-z0-9!#$&.+^_-]+$} $type]} {
		# no Content-Type, or one that cannot be read: the default (RFC 2045 5.2)
		set type $deftype
		if {$ct eq ""} { set ps {} }
	}
	lassign [params [hget $headers content-disposition]] disp dps
	set enc [string tolower [string trim [hget $headers content-transfer-encoding] " \t\""]]
	set part [dict create section $section type $type params $ps disposition $disp dparams $dps \
		encoding $enc headers $headers hstart $start bstart $bstart bend $end]
	if {$depth >= $maxdepth || $count > $maxparts} { return $part }
	if {[string match multipart/* $type]} {
		set b [expr {[dict exists $ps boundary] ? [dict get $ps boundary] : ""}]
		set kids [expr {$b eq "" ? {} : [split_multipart $raw $bstart $end $b]}]
		if {$kids eq ""} {
			# a multipart without a boundary or without any part: read as text
			dict set part type text/plain
			return $part
		}
		set child_default [expr {$type eq "multipart/digest" ? "message/rfc822" : "text/plain"}]
		set children {}
		set k 0
		foreach range $kids {
			incr k
			set sec [expr {$section eq "" ? $k : "$section.$k"}]
			lappend children [entity $raw {*}$range $sec [expr {$depth + 1}] $child_default]
		}
		dict set part children $children
	} elseif {$type eq "message/rfc822" && $enc in {"" 7bit 8bit binary}} {
		dict set part children [list [entity $raw $bstart $end [expr {$section eq "" ? 1 : "$section.1"}] [expr {$depth + 1}] text/plain]]
	}
	return $part
}

# The parts of a multipart body as {start end} ranges. The delimiter is "--B" at the start of a line; the CRLF
# before it belongs to the delimiter. A missing closing delimiter ends the last part at the end of the body.
proc ::mail::mime::split_multipart {raw start end boundary} {
	set delim "--$boundary"
	set dl [string length $delim]
	set ranges {}
	# the first delimiter: at the very start of the body, or after a line end
	set pos -1
	if {[string range $raw $start [expr {$start + $dl - 1}]] eq $delim && [is_delim $raw [expr {$start + $dl}]]} {
		set pos $start
	} else {
		set at [next_delim $raw $start $delim]
		if {$at >= 0 && $at < $end} { set pos [expr {$at + 1}] }
	}
	if {$pos < 0} { return {} }
	while {$pos >= 0} {
		set after [expr {$pos + $dl}]
		if {[string range $raw $after [expr {$after + 1}]] eq "--"} break
		# the rest of the delimiter line (transport padding) is skipped
		set nl [string first "\n" $raw $after]
		if {$nl < 0 || $nl >= $end} break
		set pstart [expr {$nl + 1}]
		set next [next_delim $raw $pstart $delim]
		if {$next < 0 || $next >= $end} {
			lappend ranges [list $pstart $end]
			break
		}
		set pend $next
		if {$pend > $pstart && [string index $raw [expr {$pend - 1}]] eq "\r"} { incr pend -1 }
		lappend ranges [list $pstart [expr {max($pstart, $pend)}]]
		set pos [expr {$next + 1}]
	}
	return $ranges
}

# Does a delimiter line go on as one (RFC 2046 5.1.1: "--" or blanks then the line end) at AT? "--b1" is not
# found inside "--b1_alt", the boundary of a part nested in it.
proc ::mail::mime::is_delim {raw at} {
	set c [string index $raw $at]
	return [expr {$c eq "" || [string is space $c] || [string range $raw $at [expr {$at + 1}]] eq "--"}]
}

# The offset of the line end before the next delimiter line from START; -1 if there is none.
proc ::mail::mime::next_delim {raw start delim} {
	set dl [string length $delim]
	while {[set at [string first "\n$delim" $raw $start]] >= 0} {
		if {[is_delim $raw [expr {$at + 1 + $dl}]]} { return $at }
		set start [expr {$at + 1}]
	}
	return -1
}

# Every part, depth first, in order.
proc ::mail::mime::all_parts {msg} {
	set out {}
	set stack [list [dict get $msg root]]
	while {[llength $stack]} {
		set p [lindex $stack end]
		set stack [lrange $stack 0 end-1]
		lappend out $p
		if {[dict exists $p children]} { lappend stack {*}[lreverse [dict get $p children]] }
	}
	return $out
}

proc ::mail::mime::leaves {msg} {
	set out {}
	foreach p [all_parts $msg] {
		if {![dict exists $p children]} { lappend out $p }
	}
	return $out
}

proc ::mail::mime::part {msg section} {
	foreach p [all_parts $msg] {
		if {[dict get $p section] eq $section} { return $p }
	}
	error "no part $section"
}

# ---- content -----------------------------------------------------------------------------------------

proc ::mail::mime::content {msg p} {
	set raw [dict get $msg raw]
	set data [string range $raw [dict get $p bstart] [expr {[dict get $p bend] - 1}]]
	switch -- [dict get $p encoding] {
		base64 { return [b64 $data] }
		quoted-printable { return [qp $data] }
		default { return $data }
	}
}

proc ::mail::mime::data {msg section} {
	return [content $msg [part $msg $section]]
}

proc ::mail::mime::part_text {msg p} {
	set ps [dict get $p params]
	set cs [expr {[dict exists $ps charset] ? [dict get $ps charset] : "us-ascii"}]
	set text [convert [content $msg $p] $cs]
	return [string map {"\r\n" "\n" "\r" "\n"} $text]
}

proc ::mail::mime::text {msg section} {
	return [part_text $msg [part $msg $section]]
}

proc ::mail::mime::save {msg section file} {
	set bytes [data $msg $section]
	set tmp "$file.part[pid]"
	set fh [::open $tmp wb]
	puts -nonewline $fh $bytes
	::close $fh
	file rename -force $tmp $file
	return $file
}

proc ::mail::mime::filename {p} {
	foreach {key k} {dparams filename params name} {
		set ps [dict get $p $key]
		if {[dict exists $ps $k] && [dict get $ps $k] ne ""} {
			# names are often encoded words even where RFC 2047 does not allow them
			set v [decode_words [dict get $ps $k]]
			# a path in a name is never used: only its last part
			set v [lindex [split [string map {\\ /} $v] /] end]
			return $v
		}
	}
	return ""
}

# Is P part of the text (as opposed to an attachment)?
proc ::mail::mime::is_text {p} {
	set t [dict get $p type]
	if {[dict get $p disposition] eq "attachment"} { return 0 }
	if {$t ni {text/plain text/html text/enriched}} { return 0 }
	if {[filename $p] ne "" && [dict get $p disposition] ne "inline"} { return 0 }
	return 1
}

# The parts that make the body, in order: {kind part} pairs, kind plain or html. ALT (from multipart/alternative)
# picks one child; a mixed multipart takes every inline text part.
proc ::mail::mime::body_parts {p} {
	set t [dict get $p type]
	if {[dict exists $p children]} {
		set kids [dict get $p children]
		switch -glob -- $t {
			multipart/alternative {
				# the last child is the richest (RFC 2046 5.1.4); plain text is preferred, then HTML, then any
				# each child is read once: nested alternatives would otherwise be read three times per level
				set got {}
				foreach c [lreverse $kids] { lappend got [body_parts $c] }
				foreach want {plain html any} {
					foreach g $got {
						if {$g eq ""} continue
						if {$want eq "any" || [lindex $g 0 0] eq $want} { return $g }
					}
				}
				return {}
			}
			multipart/related {
				# the root is the start parameter's part, else the first
				set ps [dict get $p params]
				if {[dict exists $ps start]} {
					set want [string trim [dict get $ps start] "<> "]
					foreach c $kids {
						if {[string trim [hget [dict get $c headers] content-id] "<> "] eq $want} { return [body_parts $c] }
					}
				}
				return [body_parts [lindex $kids 0]]
			}
			multipart/signed { return [body_parts [lindex $kids 0]] }
			multipart/encrypted { return {} }
			message/rfc822 { return {} }
			default {
				set out {}
				foreach c $kids {
					if {[dict exists $c children]} {
						if {[dict get $c type] ne "message/rfc822"} { lappend out {*}[body_parts $c] }
					} elseif {[is_text $c]} {
						lappend out {*}[body_parts $c]
					}
				}
				return $out
			}
		}
	}
	if {![is_text $p]} { return {} }
	return [list [list [expr {$t eq "text/html" ? "html" : "plain"}] $p]]
}

proc ::mail::mime::body {msg} {
	set out {}
	foreach bp [body_parts [dict get $msg root]] {
		lassign $bp kind p
		set t [part_text $msg $p]
		if {$kind eq "html"} { set t [html_text $t] }
		set t [string trim $t "\n"]
		if {$t ne ""} { lappend out $t }
	}
	return [join $out "\n\n"]
}

# The size of a part's decoded content, without decoding it.
proc ::mail::mime::decoded_size {msg p} {
	set n [expr {[dict get $p bend] - [dict get $p bstart]}]
	if {$n <= 0} { return 0 }
	set raw [dict get $msg raw]
	set data [string range $raw [dict get $p bstart] [expr {[dict get $p bend] - 1}]]
	switch -- [dict get $p encoding] {
		base64 {
			# the base64 characters: the line ends, blanks and padding taken out (a per-character count is slow
			# on a large attachment)
			if {[regexp {[^A-Za-z0-9+/=\s]} $data]} {
				# junk among the characters (broken mail): count the real ones
				set k [regexp -all {[A-Za-z0-9+/]} $data]
			} else {
				set k [string length [string map {"\n" "" "\r" "" " " "" "\t" "" "=" ""} $data]]
			}
			return [expr {$k * 3 / 4}]
		}
		quoted-printable {
			set esc [regexp -all {=[0-9A-Fa-f]{2}} $data]
			return [expr {$n - [string length [join [regexp -all -inline {=[ \t]*\r?\n} $data] ""]] - 2 * $esc}]
		}
		default { return $n }
	}
}

# Attachments: every leaf that is not body text, a forwarded message as one (its own parts are not listed), but
# no signature of a signed message and no text that is only another version of the body (an HTML alternative).
proc ::mail::mime::attachments {msg} {
	set inbody {}
	foreach bp [body_parts [dict get $msg root]] { lappend inbody [dict get [lindex $bp 1] section] }
	set related {}
	set signatures {}
	set forwarded {}
	foreach p [all_parts $msg] {
		if {![dict exists $p children]} continue
		set kids [dict get $p children]
		switch -- [dict get $p type] {
			multipart/related { foreach c [lrange $kids 1 end] { lappend related [dict get $c section] } }
			multipart/signed { foreach c [lrange $kids 1 end] { lappend signatures [dict get $c section] } }
			message/rfc822 { lappend forwarded [dict get $p section] }
		}
	}
	set out {}
	foreach p [all_parts $msg] {
		set sec [dict get $p section]
		set t [dict get $p type]
		if {$sec in $inbody || $sec in $signatures} continue
		set within 0
		foreach f $forwarded { if {[string match "$f.*" $sec]} { set within 1; break } }
		if {$within} continue
		if {[dict exists $p children] && $t ne "message/rfc822"} continue
		set name [filename $p]
		if {[string match text/* $t] && $name eq "" && [dict get $p disposition] ne "attachment"} continue
		if {$t eq "message/rfc822" && $name eq "" && [dict exists $p children]} {
			set name [decode_words [hget [dict get [lindex [dict get $p children] 0] headers] subject]]
			set name [expr {$name eq "" ? "message.eml" : "$name.eml"}]
		}
		set cid [string trim [hget [dict get $p headers] content-id] "<> \t"]
		set inline [expr {[string match image/* $t] && ($sec in $related || [dict get $p disposition] eq "inline")}]
		lappend out [dict create section $sec name $name type $t size [decoded_size $msg $p] inline $inline cid $cid]
	}
	return $out
}

# ---- text helpers ------------------------------------------------------------------------------------

proc ::mail::mime::html_text {html} {
	set h $html
	foreach tag {script style head title} {
		regsub -all -nocase "<$tag\\y\[^>\]*>(?:\[^<\]|<(?!/$tag))*</$tag\\s*>" $h {} h
	}
	regsub -all {<!--.*?-->} $h {} h
	regsub -all -nocase {<br\s*/?>} $h "\n" h
	regsub -all -nocase {</?(p|div|tr|h[1-6]|blockquote|ul|ol|table|pre|section|article|header|footer)\y[^>]*>} $h "\n\n" h
	regsub -all -nocase {<li\y[^>]*>} $h "\n- " h
	regsub -all -nocase {</t[dh]\s*>} $h " " h
	regsub -all {<[^>]*>} $h {} h
	# the blanks of HTML collapse; the line ends made above are kept
	regsub -all {[ \t\r\n]*\n\n[ \t\r\n]*} $h "\x01" h
	regsub -all {[ \t]*\n[ \t]*} $h "\x02" h
	regsub -all {[ \t\r\n]+} $h " " h
	set h [string map [list \x01 "\n\n" \x02 "\n"] $h]
	set h [entities $h]
	return [string trim $h]
}

proc ::mail::mime::entities {s} {
	set named {amp & lt < gt > quot \" apos ' nbsp \u00a0 copy \u00a9 reg \u00ae hellip \u2026 mdash \u2014
		ndash \u2013 lsquo \u2018 rsquo \u2019 ldquo \u201c rdquo \u201d bull \u2022 middot \u00b7 euro \u20ac
		pound \u00a3 times \u00d7 deg \u00b0 laquo \u00ab raquo \u00bb shy {} zwnj {} zwj {}}
	set out ""
	set pos 0
	foreach {m -} [regexp -all -inline -indices {&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);} $s] {
		lassign $m a b
		set name [string range $s [expr {$a + 1}] [expr {$b - 1}]]
		append out [string range $s $pos [expr {$a - 1}]]
		if {[regexp {^#[xX]([0-9a-fA-F]+)$} $name -> h]} {
			set cp [expr {"0x$h"}]
			append out [expr {$cp > 0 && $cp < 0x110000 ? [::format %c $cp] : "\ufffd"}]
		} elseif {[regexp {^#([0-9]+)$} $name -> d]} {
			scan $d %d cp
			append out [expr {$cp > 0 && $cp < 0x110000 ? [::format %c $cp] : "\ufffd"}]
		} elseif {[dict exists $named $name]} {
			append out [dict get $named $name]
		} else {
			append out [string range $s $a $b]
		}
		set pos [expr {$b + 1}]
	}
	append out [string range $s $pos end]
	return $out
}

proc ::mail::mime::snippet {text {len 200}} {
	# a preview needs only the start of a long text
	if {[string length $text] > 20000} { set text [string range $text 0 19999] }
	# the signature goes, and so do quoted lines and the "On ... wrote:" line that leads into them
	set i [string first "\n-- \n" "\n$text"]
	if {$i >= 0} { set text [string range $text 0 [expr {$i - 2}]] }
	set keep {}
	set lines [split $text "\n"]
	set n [llength $lines]
	for {set k 0} {$k < $n} {incr k} {
		set l [lindex $lines $k]
		if {[regexp {^\s*>} $l]} continue
		if {[regexp {wrote:\s*$} $l]} {
			# a "wrote:" line is the lead-in when quoted lines follow it (possibly after blank lines)
			set j [expr {$k + 1}]
			while {$j < $n && [string trim [lindex $lines $j]] eq ""} { incr j }
			if {$j >= $n || [regexp {^\s*>} [lindex $lines $j]]} continue
		}
		lappend keep $l
	}
	set s [string trim [regsub -all {\s+} [join $keep " "] " "]]
	if {[string length $s] > $len} {
		set s [string range $s 0 [expr {$len - 1}]]
		set sp [string last " " $s]
		if {$sp > $len / 2} { set s [string range $s 0 [expr {$sp - 1}]] }
		append s "\u2026"
	}
	return $s
}
