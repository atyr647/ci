# defaults.tcl - Settings → Default apps, the logic (no Tk): which installed app opens the web, mail, folders, a
# terminal, text, pictures, music, video, PDF documents and archives, read and written the freedesktop way, with no
# xdg-mime or gio at run time.
#
#   apps       every *.desktop in $XDG_DATA_HOME/applications, then $XDG_DATA_DIRS/applications, then the two Flatpak
#              export folders, and in their subfolders by the spec's id (kde/kwrite.desktop is kde-kwrite.desktop); the
#              first file of an id wins, as in properties/facts.tcl and shell/apps.tcl. An app is
#              OFFERED in a row when it has an Exec, is not Hidden or NoDisplay, is shown on this desktop (OnlyShowIn,
#              NotShowIn against $XDG_CURRENT_DESKTOP) and its TryExec, if it has one, is there to run.
#   a row      the MIME types that make an app a candidate (and, for the web, the WebBrowser category), the types the
#              choice is written for, and patterns for more of the chosen app's own types (ROWS below).
#   reading    the default of the row's first type, found exactly as Files and Properties find it
#              (facts::handlers): [Default Applications] in $XDG_CONFIG_HOME/mimeapps.list, each $XDG_CONFIG_DIRS,
#              Ribbon's own /usr/share/ribbon/xdg/mimeapps.list, each data folder's applications/mimeapps.list; then
#              the first associated app ([Added Associations], then the apps that declare the type); [Removed
#              Associations] take an app out.
#   writing    `type=app.desktop` for every one of the row's types, and for the app's own types the row's patterns
#              match, in [Default Applications] of $XDG_CONFIG_HOME/mimeapps.list. Every other line and section of the
#              file is kept byte for byte; the app is taken out of the file's [Removed Associations] for those types
#              (or the choice would not hold). The file is replaced atomically (a temp file beside it, then rename; a
#              symlinked mimeapps.list keeps its link).
#   Terminal   has no MIME type: the xdg-terminal-exec convention. The apps are those with TerminalEmulator in
#              Categories; the choice is the first entry of xdg-terminals.list ($XDG_CONFIG_HOME, each
#              $XDG_CONFIG_DIRS, each data folder's xdg-terminal-exec/) that is installed, else Ribbon Terminal; it is
#              written as the first entry of $XDG_CONFIG_HOME/xdg-terminals.list, the other lines kept.
#              apps/term/bin/ribbon-terminal (what "open a terminal" runs) reads the same list.
#
#   defapps::refresh ?FORCE?   read again when something on disk changed (or FORCE); 1 when the model changed
#   defapps::model             dict: subtitle, rows (a list of dicts: id label group icon current items), where
#                              items is {{appid name} ...} and current "" when nothing opens the row ("Not set")
#   defapps::choose ROW APPID  make APPID the row's app; 1 when written, else 0 with the reason in defapps::error
#                              (the model is then as it was)
#   defapps::start CALLBACK ?WHILE?   look every two seconds for a change made elsewhere; CALLBACK runs after
#   defapps::stop                     one. The looking ends when the script WHILE is false (the page is not shown).
#
# RIBBON_DEFAULTS_ROOT (tests) is put before the absolute paths that no XDG variable names.

namespace eval defapps {
	# id {label group icon kind  types (written; the first is the one read)  also (patterns over the app's own
	#     types)  offer (the types that make an app a candidate; types when empty)  cats (categories that do)}
	variable ROWS {
		web      {label Web group opens icon globe kind mime
			types {x-scheme-handler/http x-scheme-handler/https text/html}
			also {application/xhtml+xml}
			offer {x-scheme-handler/http x-scheme-handler/https} cats WebBrowser}
		mail     {label Mail group opens icon file kind mime
			types {x-scheme-handler/mailto} also {message/rfc822} offer {} cats {}}
		files    {label Files group opens icon folder kind mime
			types {inode/directory} also {} offer {} cats {}}
		terminal {label Terminal group opens icon terminal kind terminal
			types {} also {} offer {} cats TerminalEmulator}
		text     {label Text group opens icon edit kind mime
			types {text/plain} also {text/* application/x-shellscript application/json application/xml application/toml application/x-desktop} offer {} cats {}}
		pictures {label Pictures group opens icon image kind mime
			types {image/png image/jpeg image/webp image/gif} also {image/*} offer {} cats {}}
		music    {label Music group media icon music kind mime
			types {audio/mpeg audio/flac audio/ogg audio/mp4 audio/x-wav} also {audio/*} offer {} cats {}}
		video    {label Video group media icon film kind mime
			types {video/mp4 video/x-matroska video/webm video/quicktime video/x-msvideo video/mpeg} also {video/*} offer {} cats {}}
		pdf      {label {Documents (PDF)} group media icon file kind mime
			types {application/pdf} also {} offer {} cats {}}
		archives {label Archives group media icon box kind mime
			types {application/zip application/x-tar application/x-7z-compressed}
			also {application/x-compressed-tar application/gzip application/x-gzip application/x-bzip2
				application/x-bzip-compressed-tar application/x-bzip2-compressed-tar application/x-xz
				application/x-xz-compressed-tar application/zstd application/x-zstd-compressed-tar
				application/vnd.rar application/x-rar application/x-rar-compressed application/x-cpio
				application/x-lzma-compressed-tar application/x-lzip-compressed-tar application/x-archive}
			offer {} cats {}}
	}
	variable RIBBON_TERMINAL ribbon-terminal.desktop
	variable apps {}        ;# id -> dict: the entry's keys, and file, mimes, cats, offered
	variable lists {}       ;# mimeapps.list file -> its groups ("Section\tkey" -> ids), in lookup order
	variable termlist {}    ;# the entries of the xdg-terminals.list files, in lookup order
	variable sig ""         ;# what the disk looked like at the last read
	variable cache {}       ;# the model
	variable error ""       ;# why the last choose failed
	variable onchange ""
	variable alive ""       ;# a script: false when nobody is looking any more
	variable timer ""
}

proc defapps::env {name def} { expr {[info exists ::env($name)] && $::env($name) ne "" ? $::env($name) : $def} }
proc defapps::home {} { env HOME / }
proc defapps::root {p} { return [env RIBBON_DEFAULTS_ROOT ""]$p }
proc defapps::datadirs {} {
	set out [list [env XDG_DATA_HOME [file join [home] .local share]]]
	if {[info exists ::env(XDG_DATA_DIRS)] && $::env(XDG_DATA_DIRS) ne ""} {
		lappend out {*}[split $::env(XDG_DATA_DIRS) :]
	} else { lappend out [root /usr/local/share] [root /usr/share] }
	lmap d $out { if {$d eq ""} continue; set d }
}
proc defapps::configdirs {} {
	if {[info exists ::env(XDG_CONFIG_DIRS)] && $::env(XDG_CONFIG_DIRS) ne ""} { set l [split $::env(XDG_CONFIG_DIRS) :] } else { set l [list [root /etc/xdg]] }
	lmap d $l { if {$d eq ""} continue; set d }
}
proc defapps::confighome {} { env XDG_CONFIG_HOME [file join [home] .config] }

# The folders of *.desktop files, most important first (facts::appdirs, apps::dirs).
proc defapps::appdirs {} {
	set out [lmap d [datadirs] { file join $d applications }]
	lappend out [root /var/lib/flatpak/exports/share/applications] [file join [home] .local/share/flatpak/exports/share/applications]
	return $out
}
# The mimeapps.list files, most important first (facts::mimeapps_files).
proc defapps::mimefiles {} {
	set out [list [file join [confighome] mimeapps.list]]
	foreach d [configdirs] { lappend out [file join $d mimeapps.list] }
	lappend out [root /usr/share/ribbon/xdg/mimeapps.list]
	foreach d [datadirs] { lappend out [file join $d applications mimeapps.list] }
	return $out
}
# The xdg-terminals.list files, most important first.
proc defapps::termfiles {} {
	set out [list [file join [confighome] xdg-terminals.list]]
	foreach d [configdirs] { lappend out [file join $d xdg-terminals.list] }
	foreach d [datadirs] { lappend out [file join $d xdg-terminal-exec xdg-terminals.list] }
	return $out
}

# A text file's content ("" when it is missing, unreadable, not a file, or over a megabyte: nothing here is).
proc defapps::slurp {f {enc utf-8}} {
	if {![file isfile $f] || [catch {file size $f} n] || $n > 1048576 || [catch {::open $f r} fh]} { return "" }
	if {$enc eq "binary"} { fconfigure $fh -translation binary } else { fconfigure $fh -encoding $enc -translation lf }
	if {[catch {::read $fh} text]} { set text "" }
	catch {::close $fh}
	return $text
}

# ---- reading ------------------------------------------------------------------------------------------------

# The [Desktop Entry] group of a .desktop file's text, as a dict (facts::desktop_parse; a later key wins).
proc defapps::desktop_parse {text} {
	set e {}; set in 0
	foreach line [split $text \n] {
		set line [string trimright $line "\r \t"]
		if {[string index $line 0] eq "\["} { set in [expr {$line eq "\[Desktop Entry\]"}]; continue }
		if {$in && [regexp {^([A-Za-z0-9-]+)\s*=\s*(.*)$} $line -> k v]} { dict set e $k $v }
	}
	return $e
}
proc defapps::flag {e k} { expr {[dict exists $e $k] && [dict get $e $k] eq "true"} }
proc defapps::semis {v} { lmap x [split $v \;] { set x [string trim $x]; if {$x eq ""} continue; set x } }

# Is the entry's TryExec (if it has one) there to run?
proc defapps::runnable {e} {
	if {![dict exists $e TryExec] || [dict get $e TryExec] eq ""} { return 1 }
	set t [dict get $e TryExec]
	if {[file pathtype $t] eq "absolute"} { return [expr {[file isfile $t] && [file executable $t]}] }
	foreach d [split [env PATH /usr/local/bin:/usr/bin:/bin] :] {
		if {$d ne "" && [file isfile [file join $d $t]] && [file executable [file join $d $t]]} { return 1 }
	}
	return 0
}

# The entries of an applications folder: {id file ...}, its own first, then its subfolders' (the desktop-entry spec's
# ids: kde/kwrite.desktop is kde-kwrite.desktop).
proc defapps::desktop_files {d {pre ""} {depth 0}} {
	set out {}
	foreach f [lsort [glob -nocomplain -directory $d -- *.desktop]] { lappend out $pre[file tail $f] $f }
	if {$depth < 4} {
		foreach s [lsort [glob -nocomplain -types d -directory $d -- *]] {
			if {[file type $s] eq "link"} continue
			lappend out {*}[desktop_files $s $pre[file tail $s]- [expr {$depth + 1}]]
		}
	}
	return $out
}

proc defapps::scan_apps {} {
	variable apps {}
	set desktops [split [env XDG_CURRENT_DESKTOP Ribbon] :]
	foreach d [appdirs] {
		foreach {id f} [desktop_files $d] {
			if {[dict exists $apps $id]} continue
			set e [desktop_parse [slurp $f]]
			if {![dict exists $e Name] || [dict get $e Name] eq "" || ([dict exists $e Type] && [dict get $e Type] ne "Application")} continue
			if {[flag $e Hidden]} continue
			set show [expr {[dict exists $e Exec] && [dict get $e Exec] ne "" && ![flag $e NoDisplay] && [runnable $e]}]
			if {$show && [dict exists $e OnlyShowIn]} {
				set show 0
				foreach x [semis [dict get $e OnlyShowIn]] { if {$x in $desktops} { set show 1 } }
			}
			if {$show && [dict exists $e NotShowIn]} {
				foreach x [semis [dict get $e NotShowIn]] { if {$x in $desktops} { set show 0 } }
			}
			dict set e file $f
			dict set e dir $d
			dict set e mimes [expr {[dict exists $e MimeType] ? [semis [dict get $e MimeType]] : {}}]
			dict set e cats [expr {[dict exists $e Categories] ? [semis [dict get $e Categories]] : {}}]
			dict set e offered $show
			dict set apps $id $e
		}
	}
}

# A mimeapps.list's groups: "Section\tkey" -> ids (facts::mimeapps_read).
proc defapps::mimeapps_read {f} {
	set g {}; set cur ""
	foreach line [split [slurp $f] \n] {
		set line [string trimright $line "\r"]
		if {[regexp {^\[(.*)\]\s*$} $line -> cur]} continue
		if {[regexp {^([^=\s]+)\s*=\s*(.*)$} $line -> k v]} { dict lappend g "$cur\t$k" {*}[semis $v] }
	}
	return $g
}

# What opens type M: {default {every associated app, the most preferred first}} (facts::handlers' order, with the
# mime-apps spec's levels): the lists in turn, each one's Added Associations, then the apps of its own applications
# folder that declare the type; a list's Removed Associations (and a folder's own ids, which shadow the same ids
# further down) hold for that list and the ones after it, not for a more important one. The apps of a folder with no
# list in the order (the Flatpak exports) come last.
proc defapps::declares {e m} {
	set types [dict get $e mimes]
	expr {$m in $types || "[lindex [split $m /] 0]/*" in $types}
}
proc defapps::handlers {m} {
	variable apps; variable lists
	set default ""; set removed {}; set black {}; set all {}; set seen {}
	dict for {f g} $lists {
		if {$default eq "" && [dict exists $g "Default Applications\t$m"]} {
			foreach id [dict get $g "Default Applications\t$m"] { if {[dict exists $apps $id] && $id ni $removed} { set default $id; break } }
		}
		if {[dict exists $g "Added Associations\t$m"]} {
			foreach id [dict get $g "Added Associations\t$m"] { if {[dict exists $apps $id] && $id ni $black && $id ni $all} { lappend all $id } }
		}
		if {[dict exists $g "Removed Associations\t$m"]} {
			lappend removed {*}[dict get $g "Removed Associations\t$m"]
			lappend black {*}[dict get $g "Removed Associations\t$m"]
		}
		set dir [file dirname $f]
		if {[file tail $f] ne "mimeapps.list" || [file tail $dir] ne "applications" || $dir in $seen} continue
		lappend seen $dir
		dict for {id e} $apps {
			if {[dict get $e dir] ne $dir} continue
			if {$id ni $black && $id ni $all && [declares $e $m]} { lappend all $id }
			lappend black $id
		}
	}
	dict for {id e} $apps {
		if {[dict get $e dir] in $seen || $id in $black || $id in $all} continue
		if {[declares $e $m]} { lappend all $id }
	}
	if {$default eq "" && [llength $all]} { set default [lindex $all 0] }
	list $default $all
}

# An entry line of an xdg-terminals.list: a desktop id, perhaps with an action. Comments, blank lines and the
# lines xdg-terminal-exec keeps for itself (-id, +id, /option) are not entries.
proc defapps::term_entry {line} {
	set line [string trim $line]
	if {[regexp {^([A-Za-z0-9][A-Za-z0-9._-]*\.desktop)(:[A-Za-z0-9._-]+)?$} $line -> id]} { return $id }
	return ""
}
proc defapps::scan_terms {} {
	variable termlist {}
	foreach f [termfiles] {
		foreach line [split [slurp $f] \n] {
			set id [term_entry $line]
			if {$id ne ""} { lappend termlist $id }
		}
	}
}
# Is the program an entry's Exec starts there to run? (ribbon-terminal passes over an entry whose program is not.)
proc defapps::program_ok {e} {
	if {![dict exists $e Exec]} { return 0 }
	set x [string trim [dict get $e Exec]]
	if {![regexp {^"((?:[^"\\]|\\.)*)"} $x -> prog]} { set prog [lindex [split $x " \t"] 0] } else { set prog [regsub -all {\\(.)} $prog {\1}] }
	if {$prog eq ""} { return 0 }
	# an entry that runs ribbon-terminal is Ribbon Terminal to ribbon-terminal
	if {[file tail $prog] in {ribbon-terminal ribbon-term-ctl}} { return 1 }
	if {[string first / $prog] >= 0} { return [expr {[file isfile $prog] && [file executable $prog]}] }
	foreach d [split [env PATH /usr/local/bin:/usr/bin:/bin] :] {
		if {$d ne "" && [file isfile [file join $d $prog]] && [file executable [file join $d $prog]]} { return 1 }
	}
	return 0
}
# The terminals to offer: TerminalEmulator apps whose program is installed, without foot's server and client
# entries (neither is a terminal to start on its own).
proc defapps::terminals {} {
	variable apps
	set out {}
	dict for {id e} $apps {
		if {![dict get $e offered] || "TerminalEmulator" ni [dict get $e cats] || ![program_ok $e]} continue
		if {[string match *foot-server.desktop $id] || [string match *footclient.desktop $id]} continue
		lappend out $id
	}
	return $out
}
# The terminal in use: the first entry of the lists that is installed, as ribbon-terminal finds it; with none,
# Ribbon Terminal (it is what ribbon-terminal then opens), else the first terminal there is.
proc defapps::terminal_current {} {
	variable apps; variable termlist; variable RIBBON_TERMINAL
	foreach id $termlist {
		if {$id eq $RIBBON_TERMINAL && [dict exists $apps $id]} { return $id }
		if {[dict exists $apps $id] && [program_ok [dict get $apps $id]]} { return $id }
	}
	if {[dict exists $apps $RIBBON_TERMINAL]} { return $RIBBON_TERMINAL }
	lindex [terminals] 0
}

proc defapps::name {id} {
	variable apps
	if {$id eq ""} { return "Not set" }
	if {[dict exists $apps $id Name]} { return [dict get $apps $id Name] }
	file rootname $id
}

# One row: {current candidates}.
proc defapps::row_state {row} {
	variable ROWS; variable apps
	set r [dict get $ROWS $row]
	if {[dict get $r kind] eq "terminal"} {
		set cur [terminal_current]
		set cand [terminals]
	} else {
		set types [dict get $r types]
		set offer [dict get $r offer]
		if {![llength $offer]} { set offer $types }
		set cur [lindex [handlers [lindex $types 0]] 0]
		set cand {}
		foreach t $offer {
			foreach id [lindex [handlers $t] 1] { if {$id ni $cand && [dict get $apps $id offered]} { lappend cand $id } }
		}
		foreach c [dict get $r cats] {
			dict for {id e} $apps { if {$id ni $cand && [dict get $e offered] && $c in [dict get $e cats]} { lappend cand $id } }
		}
	}
	# the app in use is in the list whatever it is (a hidden handler, say), so the row shows the truth
	if {$cur ne "" && $cur ni $cand} { lappend cand $cur }
	set keyed [lmap id $cand { list [string tolower [name $id]] $id }]
	list $cur [lmap k [lsort -dictionary -index 0 [lsort -index 1 $keyed]] { lindex $k 1 }]
}

proc defapps::build {} {
	variable ROWS; variable cache
	set rows {}
	set web ""
	dict for {row r} $ROWS {
		lassign [row_state $row] cur cand
		set items [lmap id $cand { list $id [name $id] }]
		if {$cur eq ""} { set items [linsert $items 0 [list "" "Not set"]] }
		if {$row eq "web"} { set web $cur }
		lappend rows [dict create id $row label [dict get $r label] group [dict get $r group] icon [dict get $r icon] current $cur items $items]
	}
	set cache [dict create subtitle [expr {$web eq "" ? "No web browser" : "[name $web] for the web"}] rows $rows]
}

# What the disk looks like: every folder's entries and every list, by time and size.
proc defapps::signature {} {
	set s {}
	foreach d [appdirs] {
		foreach {id f} [desktop_files $d] {
			if {![catch {file stat $f st}]} { lappend s $f $st(mtime) $st(size) }
		}
	}
	foreach f [concat [mimefiles] [termfiles]] {
		if {[catch {file stat $f st}]} { lappend s $f - } else { lappend s $f $st(mtime) $st(size) $st(ino) }
	}
	lappend s [env XDG_CURRENT_DESKTOP Ribbon]
	return $s
}

proc defapps::refresh {{force 0}} {
	variable sig; variable cache; variable lists
	set now [signature]
	if {!$force && $now eq $sig && [dict size $cache]} { return 0 }
	set sig $now
	set before $cache
	scan_apps
	set lists {}
	foreach f [mimefiles] { if {![dict exists $lists $f]} { dict set lists $f [mimeapps_read $f] } }
	scan_terms
	build
	expr {$cache ne $before}
}
proc defapps::model {} {
	variable cache
	if {![dict size $cache]} { refresh 1 }
	return $cache
}

# ---- writing ------------------------------------------------------------------------------------------------

# The types a choice of APP in ROW is written for: the row's own, then the app's own that the row's patterns match.
proc defapps::types_for {row app} {
	variable ROWS; variable apps
	set r [dict get $ROWS $row]
	set out [dict get $r types]
	# a type another row writes as its own (text/html is Web's) is never taken by a pattern
	set others {}
	dict for {id o} $ROWS { if {$id ne $row} { lappend others {*}[dict get $o types] } }
	if {[dict exists $apps $app]} {
		foreach t [dict get $apps $app mimes] {
			if {$t in $out || $t in $others || [regexp {[\s=\[\]*]} $t]} continue
			foreach p [dict get $r also] { if {[string match $p $t]} { lappend out $t; break } }
		}
	}
	return $out
}

# Replace F with DATA (bytes) atomically. A symlink is followed, so that the link stays; the file's mode is kept.
proc defapps::replace_file {f data} {
	for {set n 0} {$n < 8 && ![catch {file readlink $f} to]} {incr n} { set f [file join [file dirname $f] $to] }
	file mkdir [file dirname $f]
	set tmp $f.tmp[pid]
	set fh [::open $tmp w]
	if {[catch {
		fconfigure $fh -translation binary
		puts -nonewline $fh $data
		::close $fh
		if {[file exists $f]} { catch {file attributes $tmp -permissions [file attributes $f -permissions]} }
		file rename -force -- $tmp $f
	} err opts]} {
		catch {::close $fh}
		catch {file delete -- $tmp}
		return -options $opts $err
	}
}

# mimeapps.list text (bytes) with APP made the default of TYPES; everything else as it was.
proc defapps::mime_text {text types app} {
	set app [encoding convertto utf-8 $app]
	set lines [split [string trimright $text \n] \n]
	if {[string trim $text] eq ""} { set lines {} }
	set cr [expr {[string index [lindex $lines 0] end] eq "\r" ? "\r" : ""}]
	set out {}; set cur ""; set secs 0; set ins -1
	foreach line $lines {
		set l [string trimright $line "\r"]
		if {[regexp {^\[(.*)\]\s*$} $l -> cur]} {
			if {$cur eq "Default Applications"} { incr secs }
			lappend out $line
			if {$cur eq "Default Applications" && $secs == 1} { set ins [llength $out] }
			continue
		}
		if {[regexp {^([^=\s#]+)\s*=\s*(.*)$} $l -> k v] && $k in $types} {
			if {$cur eq "Default Applications"} {
				if {![info exists done($k)]} {
					lappend out "$k=$app$cr"; set done($k) 1
					if {$secs == 1} { set ins [llength $out] }
				}
				continue
			}
			if {$cur eq "Removed Associations" && $app in [semis $v]} {
				set rest [lmap x [semis $v] { if {$x eq $app} continue; set x }]
				if {[llength $rest]} { lappend out "$k=[join $rest \;]\;$cr" }
				continue
			}
		}
		lappend out $line
		if {$cur eq "Default Applications" && $secs == 1 && [string trim $l] ne ""} { set ins [llength $out] }
	}
	set new [lmap t $types { if {[info exists done($t)]} continue; set t "$t=$app$cr" }]
	if {[llength $new]} {
		if {$ins < 0} {
			if {[llength $out] && [string trim [lindex $out end]] ne ""} { lappend out $cr }
			lappend out "\[Default Applications\]$cr"
			set ins [llength $out]
		}
		set out [linsert $out $ins {*}$new]
	}
	return [join $out \n]\n
}

# xdg-terminals.list text (bytes) with APP as its first entry; the other lines as they were.
proc defapps::term_text {text app} {
	set app [encoding convertto utf-8 $app]
	set lines [split [string trimright $text \n] \n]
	if {[string trim $text] eq ""} { set lines {} }
	set cr [expr {[string index [lindex $lines 0] end] eq "\r" ? "\r" : ""}]
	set out {}; set put 0
	foreach line $lines {
		set l [string trim $line]
		# the app's old place in the list, and a line that left it out
		if {$l eq $app || $l eq "-$app"} continue
		if {!$put && $l ne "" && [string index $l 0] ne "#"} { lappend out $app$cr; set put 1 }
		lappend out $line
	}
	if {!$put} { lappend out $app$cr }
	return [join $out \n]\n
}

# Make APP the app of ROW. 1 when it is written; 0 (and defapps::error) when the row or the app is not known or
# the file cannot be written, and then nothing has changed.
proc defapps::choose {row app} {
	variable ROWS; variable apps; variable error ""
	refresh
	if {![dict exists $ROWS $row]} { set error "no row $row"; return 0 }
	if {![dict exists $apps $app] || ![regexp {^[^\s/;=\[\]#]+\.desktop$} $app]} { set error "no app $app"; return 0 }
	if {[catch {
		if {[dict get $ROWS $row kind] eq "terminal"} {
			set f [file join [confighome] xdg-terminals.list]
			replace_file $f [term_text [slurp $f binary] $app]
		} else {
			set f [file join [confighome] mimeapps.list]
			replace_file $f [mime_text [slurp $f binary] [types_for $row $app] $app]
		}
	} err]} { set error $err; return 0 }
	refresh 1
	return 1
}

# ---- changes made elsewhere ---------------------------------------------------------------------------------

proc defapps::start {callback {while ""}} {
	variable onchange $callback
	variable alive $while
	variable timer
	if {$timer eq ""} { set timer [after 2000 defapps::tick] }
}
proc defapps::stop {} {
	variable timer; variable onchange ""
	if {$timer ne ""} { after cancel $timer; set timer "" }
}
proc defapps::tick {} {
	variable timer ""; variable onchange; variable alive
	if {$alive ne "" && ![uplevel #0 $alive]} return
	set timer [after 2000 defapps::tick]
	if {[refresh] && $onchange ne ""} { uplevel #0 $onchange }
}
