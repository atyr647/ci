# index.tcl - the notes in memory (U33): one entry per note, read again only when its file's mtime or size has
# changed. Entries are sorted pinned first, then newest first. Search matches every word, without case, in the
# name and the body, and returns the count and a snippet with the first match marked.
#
#   notes::index::refresh          re-reads the changed notes; returns how many were read
#   notes::index::entries          every entry: dict folder name pinned mtime title tags body
#   notes::index::in_folder F      the entries of folder F (direct notes only)
#   notes::index::count F          the notes in F and below
#   notes::index::tag_counts       dict: tag -> notes with it
#   notes::index::search QUERY     the matching entries plus: count snippet (dict text at len)
#   notes::index::reads            how many notes the last refresh read

namespace eval ::notes::index {
	variable cache
	array set cache {}
	variable reads 0
}

proc ::notes::index::refresh {} {
	variable cache
	variable reads
	set reads 0
	set seen {}
	foreach folder [linsert [notes::store::folders] 0 ""] {
		foreach name [notes::store::notes $folder] {
			set k "$folder/$name"
			lappend seen $k
			set path [notes::store::note_path $folder $name]
			set mt [file mtime $path]
			set sz [file size $path]
			if {[info exists cache($k)] && [dict get $cache($k) mtime] == $mt && [dict get $cache($k) size] == $sz} continue
			set p [notes::md::parse [notes::store::read_note $folder $name]]
			set body [dict get $p body]
			set cache($k) [dict create folder $folder name $name mtime $mt size $sz \
				pinned [dict get $p pinned] title [notes::md::title $body] tags [notes::md::tags $body] body $body]
			incr reads
		}
	}
	foreach k [array names cache] {
		if {$k ni $seen} { unset cache($k) }
	}
	return $reads
}

proc ::notes::index::order {a b} {
	set pa [dict get $a pinned]
	set pb [dict get $b pinned]
	if {$pa != $pb} { return [expr {$pa > $pb ? -1 : 1}] }
	set ma [dict get $a mtime]
	set mb [dict get $b mtime]
	if {$ma != $mb} { return [expr {$ma > $mb ? -1 : 1}] }
	return [string compare [dict get $a name] [dict get $b name]]
}

proc ::notes::index::entries {} {
	variable cache
	set out {}
	foreach k [array names cache] { lappend out $cache($k) }
	return [lsort -command ::notes::index::order $out]
}

proc ::notes::index::in_folder {folder} {
	set out {}
	foreach e [entries] {
		if {[dict get $e folder] eq $folder} { lappend out $e }
	}
	return $out
}

proc ::notes::index::count {folder} {
	set n 0
	foreach e [entries] {
		set f [dict get $e folder]
		if {$folder eq "" || $f eq $folder || [string match "$folder/*" $f]} { incr n }
	}
	return $n
}

proc ::notes::index::tag_counts {} {
	set counts [dict create]
	foreach e [entries] {
		foreach t [dict get $e tags] { dict incr counts $t }
	}
	return $counts
}

proc ::notes::index::occurrences {hay needle} {
	set n 0
	set i 0
	while {[set i [string first $needle $hay $i]] >= 0} {
		incr n
		incr i [string length $needle]
	}
	return $n
}

# A snippet of BODY around the first match of WORD, spaces collapsed; "at" and "len" mark the match in it.
# The body as a snippet shows it: the Markdown markers at a line's start (heading #s, bullets, checkbox boxes,
# quotes) and the backquotes go, so the snippet reads as the note does.
proc ::notes::index::plain {body} {
	set body [regsub -all {(?n)^[ \t]*(#+[ \t]+|[-*+][ \t]+(\[[ xX]\][ \t]+)?|>[ \t]*)} $body {}]
	return [string map {` {}} $body]
}

proc ::notes::index::snippet {body word} {
	# the title (the first heading) is not part of the snippet: the match in the text is what the list shows
	regsub {^[ \t]*#[^\n]*\n} $body {} body
	set body [plain $body]
	set i [string first [string tolower $word] [string tolower $body]]
	if {$i < 0} { set i 0 }
	set start [expr {max(0, $i - 14)}]
	# a snippet that starts after the start of a word, so it never begins mid-word
	if {$start > 0} {
		set sp [string first " " $body $start]
		if {$sp >= 0 && $sp < $i} { set start [expr {$sp + 1}] }
	}
	set stop [expr {min([string length $body], $i + [string length $word] + 60)}]
	set raw [string range $body $start [expr {$stop - 1}]]
	set text [regsub -all {\s+} $raw " "]
	set pre [expr {$start > 0 ? "..." : ""}]
	set post [expr {$stop < [string length $body] ? "..." : ""}]
	set text "$pre[string trim $text]$post"
	set at [string first [string tolower $word] [string tolower $text]]
	return [dict create text $text at [expr {$at < 0 ? 0 : $at}] len [string length $word]]
}

proc ::notes::index::search {query} {
	set words [regexp -all -inline {\S+} [string tolower $query]]
	if {[llength $words] == 0} { return {} }
	set first [lindex $words 0]
	set hits {}
	foreach e [entries] {
		set hay [string tolower "[dict get $e name]\n[dict get $e body]"]
		set ok 1
		foreach w $words {
			if {[string first $w $hay] < 0} { set ok 0; break }
		}
		if {!$ok} continue
		set count [occurrences $hay $first]
		lappend hits [dict merge $e [dict create count $count snippet [snippet [dict get $e body] $first]]]
	}
	return $hits
}
