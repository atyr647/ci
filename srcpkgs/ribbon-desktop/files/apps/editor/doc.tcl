# doc.tcl - Text editor (U26): the document model. Each open document has its own Tk text widget (its undo,
# caret and scroll are its own), its path, its encoding (UTF-8, UTF-8 with a BOM, or Latin-1 when the bytes are
# not UTF-8), its line ending (LF or CRLF, kept on save) and the text it was last saved as (for the "N lines
# changed" count in the close sheet). Dirty is the text widget's own modified flag.
#
# Procs here never draw. The window (main.tcl) repaints after each change.

namespace eval doc {
	variable D          ;# array: ID,field
	variable n 0
	variable recent_max 12
}

# bytes -> {text encoding bom eol}. Strict UTF-8 first: Tcl's lenient decode maps a bad byte to U+FFFD, and
# encoding the result back then differs from the input, which is how a non-UTF-8 file is noticed.
proc doc::decode {bytes} {
	set bom 0
	if {[string range $bytes 0 2] eq "\xEF\xBB\xBF"} { set bom 1; set bytes [string range $bytes 3 end] }
	set enc utf-8
	if {[catch {encoding convertfrom utf-8 $bytes} text] || [encoding convertto utf-8 $text] ne $bytes} {
		set enc iso8859-1
		set text [encoding convertfrom iso8859-1 $bytes]
	}
	set lf [regexp -all {\n} $text]
	set crlf [regexp -all {\r\n} $text]
	set eol LF
	if {$lf > 0 && $crlf == $lf} {
		set eol CRLF
		set text [string map [list \r\n \n] $text]
	}
	return [list $text $enc $bom $eol]
}

# text (lines end in \n) -> the bytes the file has
proc doc::encode {text enc bom eol} {
	if {$eol eq "CRLF"} { set text [string map [list \n \r\n] $text] }
	if {$enc eq "iso8859-1"} { return [encoding convertto iso8859-1 $text] }
	set out [encoding convertto utf-8 $text]
	if {$bom} { set out "\xEF\xBB\xBF$out" }
	return $out
}

proc doc::read_file {path} {
	set f [open $path rb]
	set b [read $f]
	close $f
	return $b
}

# Written beside the file and renamed over it, so a failed save never leaves half a file. The mode is kept.
proc doc::write_file {path bytes} {
	set tmp $path.[pid].tmp
	set f [open $tmp wb]
	puts -nonewline $f $bytes
	close $f
	catch {file attributes $tmp -permissions [file attributes $path -permissions]}
	file rename -force $tmp $path
}

# A document with TEXT (already decoded), in a new text widget inside $editor::page. Returns its id.
proc doc::new {path text enc bom eol} {
	variable D
	variable n
	set id d[incr n]
	set D($id,path) $path
	set D($id,enc) $enc
	set D($id,bom) $bom
	set D($id,eol) $eol
	set D($id,saved) $text
	set D($id,mtime) [expr {$path ne "" && [file exists $path] ? [file mtime $path] : ""}]
	set D($id,conflict) 0
	set D($id,untitled) [expr {$path eq ""}]
	set D($id,folds) {}     ;# the fold tags of the gutter (gutter.tcl)
	set w $editor::page.t$id
	set font $editor::codefont
	set ls [font metrics $font -linespace]
	set sp1 [expr {max(0, (22 - $ls) / 2)}]
	set sp3 [expr {max(0, 22 - $ls - $sp1)}]
	text $w -wrap none -undo 1 -autoseparators 1 -font $font -padx 16 -pady 0 \
		-spacing1 $sp1 -spacing3 $sp3 -tabs [expr {4 * [font measure $font 0]}] \
		-background $editor::bg -foreground $editor::fg -insertbackground $editor::accent \
		-selectbackground $editor::sel -inactiveselectbackground $editor::sel \
		-borderwidth 0 -highlightthickness 0 -relief flat \
		-yscrollcommand [list editor::scrolled $id $w]
	$w insert 1.0 $text
	$w edit reset
	$w edit modified 0
	$w mark set insert 1.0
	set D($id,w) $w
	editor::bind_text $w
	bind $w <Tab> [list apply {{w id} { if {[doc::tab_key $w $id]} { return -code break } }} $w $id]
	editor::highlight_install $id
	return $id
}

# The indent of document ID, read from its first 400 lines: {tabs 4} when its indented lines start with a tab (or none
# is indented: the Tab key then inserts a tab), else {spaces N}: N is the largest of 8, 4, 3 and 2 that divides the
# indent of nine in ten of its space-indented lines (a line aligned under an open bracket is the odd one out).
proc doc::indent {id} {
	variable D
	indent_of [$D($id,w) get 1.0 401.0]
}

proc doc::indent_of {text} {
	set tabs 0
	set ns {}
	foreach line [split $text \n] {
		if {[string trim $line] eq ""} continue
		if {[string index $line 0] eq "\t"} { incr tabs; continue }
		regexp {^ *} $line lead
		set n [string length $lead]
		# a line of a block comment (" * ...") is not an indent
		if {$n > 0 && ![string match "\\**" [string trimleft $line]]} { lappend ns $n }
	}
	if {$tabs >= [llength $ns]} { return {tabs 4} }
	foreach d {8 4 3 2} {
		set k 0
		foreach n $ns { if {$n % $d == 0} { incr k } }
		if {$k * 10 >= [llength $ns] * 9} { return [list spaces $d] }
	}
	return {spaces 4}
}

# The status line's words for the indent: "Tabs" or "Spaces: N".
proc doc::indent_label {id} {
	lassign [indent $id] kind n
	expr {$kind eq "tabs" ? "Tabs" : "Spaces: $n"}
}

# The Tab key in a space-indented document inserts spaces to the next stop of its step; in a tab-indented one, a tab.
proc doc::tab_key {w id} {
	lassign [indent $id] kind n
	if {$kind eq "tabs"} { return 0 }
	if {[llength [$w tag ranges sel]]} { return 0 }
	set col [lindex [split [$w index insert] .] 1]
	$w insert insert [string repeat " " [expr {$n - $col % $n}]]
	$w see insert
	return 1
}

proc doc::dirty {id} { variable D; return [$D($id,w) edit modified] }

proc doc::name {id} {
	variable D
	if {$D($id,untitled)} { return [untitled_name $id] }
	return [file tail $D($id,path)]
}

# "Untitled", then "Untitled 2" and so on, in tab order.
proc doc::untitled_name {id} {
	variable D
	set k 0
	foreach i [split::union] {
		if {$D($i,untitled)} { incr k; if {$i eq $id} { return [expr {$k == 1 ? "Untitled" : "Untitled $k"}] } }
	}
	return "Untitled"
}

# The folder for the tab's hover and the status line: ~ for home, the folder otherwise.
proc doc::folder {id} {
	variable D
	if {$D($id,untitled)} { return "" }
	set d [file dirname $D($id,path)]
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : ""}]
	if {$home ne "" && ($d eq $home || [string match "$home/*" $d])} { set d "~[string range $d [string length $home] end]" }
	return $d
}

# The language named on the status line, from the file name.
proc doc::lang {id} {
	variable D
	if {$D($id,untitled)} { return "Plain text" }
	switch -- [string tolower [file extension $D($id,path)]] {
		.tcl - .tk - .itcl - .tm { return Tcl }
		.sh - .bash - .ksh - .zsh { return Shell }
		.py - .pyw { return Python }
		.c - .h { return C }
		.json { return JSON }
		.md - .markdown { return Markdown }
		.diff - .patch { return Diff }
		.desktop - .ini - .conf - .cfg - .toml { return "Config" }
		.xml - .xsl - .svg - .kit { return XML }
		default { return "Plain text" }
	}
}

# The syntax the highlighter uses for a document (highlight.tcl): tcl sh py c json md diff ini, or "" for none.
proc doc::syntax {id} {
	variable D
	if {$D($id,untitled)} { return "" }
	switch -- [string tolower [file extension $D($id,path)]] {
		.tcl - .tk - .itcl - .tm { return tcl }
		.sh - .bash - .ksh - .zsh { return sh }
		.py - .pyw { return py }
		.c - .h { return c }
		.json { return json }
		.md - .markdown { return md }
		.diff - .patch { return diff }
		.desktop - .ini - .conf - .cfg - .toml { return ini }
		default { return "" }
	}
}

proc doc::encoding_label {id} {
	variable D
	set e [expr {$D($id,enc) eq "iso8859-1" ? "Latin-1" : "UTF-8"}]
	if {$D($id,bom)} { append e " BOM" }
	return $e
}

# The number of lines that differ from the saved text: the larger of lines added and lines removed.
proc doc::changed_lines {id} {
	variable D
	array set cnt {}
	foreach l [split $D($id,saved) \n] { incr cnt($l) -1 }
	foreach l [split [$D($id,w) get 1.0 end-1c] \n] { incr cnt($l) }
	set added 0; set removed 0
	foreach {l v} [array get cnt] {
		if {$v > 0} { incr added $v } elseif {$v < 0} { incr removed [expr {-$v}] }
	}
	return [expr {max($added, $removed)}]
}

# Save to its path (or PATH, which becomes its path). Returns 1 on success.
proc doc::save {id {path ""}} {
	variable D
	if {$path ne ""} {
		set D($id,path) $path
		set D($id,untitled) 0
	}
	if {$D($id,untitled)} { return 0 }
	set text [$D($id,w) get 1.0 end-1c]
	if {[catch {write_file $D($id,path) [encode $text $D($id,enc) $D($id,bom) $D($id,eol)]} err]} {
		puts stderr "ribbon-editor: save $D($id,path): $err"
		return 0
	}
	set D($id,saved) $text
	set D($id,mtime) [file mtime $D($id,path)]
	set D($id,conflict) 0
	$D($id,w) edit modified 0
	recent_add $D($id,path)
	return 1
}

# Reload from disk, keeping the caret where it was (line and column, clamped).
proc doc::reload {id} {
	variable D
	set w $D($id,w)
	lassign [decode [read_file $D($id,path)]] text enc bom eol
	set at [$w index insert]
	$w delete 1.0 end
	$w insert 1.0 $text
	$w mark set insert $at
	$w see insert
	# the whole text is new (its tags went with the old one): the highlighter retags every line, not the changed ones
	catch {set ::highlight::S($id,lines) {}; set ::highlight::S($id,entry) [list ""]}
	set D($id,saved) $text
	set D($id,enc) $enc
	set D($id,bom) $bom
	set D($id,eol) $eol
	set D($id,mtime) [file mtime $D($id,path)]
	set D($id,conflict) 0
	$w edit reset
	$w edit modified 0
}

# Called every second or so: a clean document follows the file; a changed one keeps its text and says so.
proc doc::check_disk {id} {
	variable D
	if {$D($id,untitled) || ![file exists $D($id,path)]} return
	set m [file mtime $D($id,path)]
	if {$m == $D($id,mtime)} return
	if {[dirty $id]} {
		set D($id,conflict) 1
	} else {
		if {![catch {reload $id}]} { set D($id,mtime) $m; catch {highlight::schedule $id} }
	}
}

# Forget a document: its widget goes; the caller has already handled dirty state.
proc doc::destroy_doc {id} {
	variable D
	foreach k [array names D "$id,w*"] { catch {destroy $D($k)} }
	foreach k [array names D "$id,*"] { unset D($k) }
}

# ---- recent files: $XDG_STATE_HOME/ribbon/editor/recent, a Tcl list, most recent first ----

proc doc::state_file {} {
	set base [expr {[info exists ::env(XDG_STATE_HOME)] && $::env(XDG_STATE_HOME) ne ""
		? $::env(XDG_STATE_HOME) : [file join [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}] .local state]}]
	file join $base ribbon editor recent
}

# Where the file chooser starts: $XDG_STATE_HOME/ribbon/editor/startdir (set by Open folder…), else the current folder.
proc doc::start_dir {} {
	if {![catch {set fh [open [file join [file dirname [state_file]] startdir] r]; set d [string trim [read $fh]]; close $fh}] \
		&& [file isdirectory $d]} {
		return $d
	}
	return [pwd]
}

proc doc::set_start_dir {d} {
	catch {
		set f [file join [file dirname [state_file]] startdir]
		file mkdir [file dirname $f]
		set fh [open $f w]
		puts $fh $d
		close $fh
	}
}

proc doc::recent_load {} {
	if {[catch {set fh [open [state_file] r]; set text [read $fh]; close $fh}]} { return {} }
	set out {}
	foreach p $text { if {[string index $p 0] eq "/"} { lappend out $p } }
	return $out
}

proc doc::recent_add {path} {
	variable recent_max
	set list [list $path]
	foreach p [recent_load] { if {$p ne $path} { lappend list $p } }
	set list [lrange $list 0 [expr {$recent_max - 1}]]
	catch {
		set f [state_file]
		file mkdir [file dirname $f]
		set fh [open $f w]
		puts $fh $list
		close $fh
	}
}
