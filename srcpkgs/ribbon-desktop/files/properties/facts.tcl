# facts.tcl - what a file or a folder is: stat data, its type and the apps
# that open it (the desktop's MIME associations), a photo's EXIF, and a
# folder's contents (counted in the background, a slice at a time).

namespace eval facts {
	variable walk {}       ;# folder walk: directories still to read
	variable W             ;# its counts
	array set W {}
}

proc facts::home {} { expr {[info exists ::env(HOME)] ? $::env(HOME) : "/"} }
proc facts::env {name def} { expr {[info exists ::env($name)] && $::env($name) ne "" ? $::env($name) : $def} }

# ~/Pictures/Iceland
proc facts::tilde {p} {
	set h [home]
	if {$p eq $h} { return ~ }
	if {[string first $h/ $p] == 0} { return ~[string range $p [string length $h] end] }
	return $p
}

# 21.6 MB, 3.1 GB, 640 MB, 6.8 KB, 812 MB: one decimal under 100, a whole number from
# 100 up, the ".0" dropped (the boards: FileProps-Inspector-*, Viewer-Final-2-Info). A
# value that rounds to 1000 is the next unit up (999.96 KB is 1 MB).
proc facts::human {b} {
	if {$b < 1000} { return "$b bytes" }
	set u KB; set n 1e3
	foreach {nu nn} {MB 1e6 GB 1e9 TB 1e12} { if {$b >= $nn} { set u $nu; set n $nn } }
	set v [expr {$b / $n}]
	if {$v < 99.95} {
		set s [regsub {\.0$} [format %.1f $v] {}]
	} else {
		set s [format %.0f $v]
	}
	if {$s >= 1000 && $u ne "TB"} { return "1 [lindex {MB GB TB} [lsearch {KB MB GB} $u]]" }
	return "$s $u"
}

# 4,218,903
proc facts::commas {n} {
	set s ""
	set n [string reverse $n]
	for {set i 0} {$i < [string length $n]} {incr i 3} { lappend s [string reverse [string range $n $i [expr {$i + 2}]]] }
	join [lreverse $s] ,
}

# "Today, 08:31", "Yesterday, 22:14", "14 Aug 2026, 21:47"
proc facts::when {t {now ""}} {
	if {$t eq "" || $t <= 0} { return "" }
	if {$now eq ""} { set now [clock seconds] }
	set d [clock format $t -format %Y%m%d]
	set hm [clock format $t -format %H:%M]
	if {$d eq [clock format $now -format %Y%m%d]} { return "Today, $hm" }
	if {$d eq [clock format [clock add $now -1 day] -format %Y%m%d]} { return "Yesterday, $hm" }
	return "[string trimleft [clock format $t -format %d] 0] [clock format $t -format {%b %Y}], $hm"
}
proc facts::date {t} {
	if {$t eq "" || $t <= 0} { return "" }
	return "[string trimleft [clock format $t -format %d] 0] [clock format $t -format {%b %Y}]"
}

# ---- one file or folder ------------------------------------------------------------

# Everything the General page shows: a dict.
proc facts::of {path} {
	set path [file normalize $path]
	file lstat $path st
	set F [dict create path $path name [file tail $path] dir [file dirname $path] type $st(type) \
		size $st(size) mtime $st(mtime) atime $st(atime) btime "" uid $st(uid) gid $st(gid) mode [expr {$st(mode) & 07777}]]
	# the birth time: Tcl's stat has none; coreutils' stat says 0 where the
	# filesystem doesn't keep one
	if {![catch {exec stat -c %W -- $path} b] && [string is integer -strict $b] && $b > 0} { dict set F btime $b }
	dict set F owner [expr {[catch {file attributes $path -owner} o] ? $st(uid) : $o}]
	dict set F group [expr {[catch {file attributes $path -group} g] ? $st(gid) : $g}]
	set isdir [file isdirectory $path]
	dict set F isdir $isdir
	if {$isdir} {
		dict set F mime inode/directory
		dict set F typename Folder
	} else {
		set m [mime $path]
		dict set F mime $m
		dict set F typename [mime_comment $m]
	}
	return $F
}

# The MIME type: file(1) reads the contents; the name decides when it can't.
proc facts::mime {path} {
	if {[auto_execok file] ne "" && ![catch {exec file --brief --mime-type -- $path} m] && [regexp {^[a-z]+/[-+.a-zA-Z0-9]+$} $m]} {
		# file(1) says octet-stream or text/plain for what it can't tell
		if {$m ni {application/octet-stream text/plain application/zip}} { return $m }
	}
	set byext {
		jpg image/jpeg jpeg image/jpeg png image/png webp image/webp gif image/gif svg image/svg+xml avif image/avif heic image/heic
		mp3 audio/mpeg flac audio/flac ogg audio/ogg opus audio/ogg wav audio/x-wav m4a audio/mp4
		mp4 video/mp4 mkv video/x-matroska webm video/webm mov video/quicktime avi video/x-msvideo
		pdf application/pdf txt text/plain md text/markdown html text/html zip application/zip tar application/x-tar
		gz application/gzip xz application/x-xz zst application/zstd kit application/x-ribbon-kit
		tcl text/x-tcl py text/x-python sh application/x-shellscript c text/x-c json application/json
	}
	set e [string tolower [string trimleft [file extension $path] .]]
	if {[dict exists $byext $e]} { return [dict get $byext $e] }
	if {[info exists m] && [regexp {^[a-z]+/} $m]} { return $m }
	return application/octet-stream
}

# "JPEG image": shared-mime-info's English comment for the type.
proc facts::mime_comment {m} {
	foreach d [concat [list [env XDG_DATA_HOME [home]/.local/share]] [split [env XDG_DATA_DIRS /usr/local/share:/usr/share] :]] {
		set f [file join $d mime $m.xml]
		if {[catch {open $f} fh]} continue
		fconfigure $fh -encoding utf-8
		set x [read $fh]; close $fh
		if {[regexp {<comment>([^<]*)</comment>} $x -> c]} { return [string map {&amp; & &lt; < &gt; >} $c] }
	}
	set known {application/x-ribbon-kit {Ribbon kit} inode/directory Folder}
	if {[dict exists $known $m]} { return [dict get $known $m] }
	lassign [split $m /] major minor
	return "[string toupper [regsub {^x-} $minor ""]] [expr {$major in {image audio video text} ? $major : "file"}]"
}

# ---- apps and MIME associations ----------------------------------------------------

# The [Desktop Entry] group of a .desktop file's text as a dict.
proc facts::desktop_parse {text} {
	set e {}; set in 0
	foreach line [split $text \n] {
		if {[string index $line 0] eq "\["} { set in [expr {$line eq "\[Desktop Entry\]"}]; continue }
		if {$in && [regexp {^([A-Za-z]+)\s*=\s*(.*)$} $line -> k v]} { dict set e $k $v }
	}
	return $e
}

proc facts::appdirs {} {
	set out [list [file join [env XDG_DATA_HOME [home]/.local/share] applications]]
	foreach d [split [env XDG_DATA_DIRS /usr/local/share:/usr/share] :] { lappend out [file join $d applications] }
	# kits' launcher entries (kit links them into ~/.local/share/applications;
	# also read straight from the store)
	lappend out /var/lib/flatpak/exports/share/applications [file join [home] .local/share/flatpak/exports/share/applications]
	return $out
}

# Every app: id -> dict (Name Exec MimeType Categories GenericName ...).
proc facts::apps {} {
	variable apps
	if {[info exists apps]} { return $apps }
	set apps {}
	foreach d [appdirs] {
		foreach f [lsort [glob -nocomplain -directory $d *.desktop]] {
			set id [file tail $f]
			if {[dict exists $apps $id] || [catch {open $f} fh]} continue
			fconfigure $fh -encoding utf-8
			set e [desktop_parse [read $fh]]; close $fh
			if {![dict exists $e Name] || ([dict exists $e Type] && [dict get $e Type] ne "Application")} continue
			if {[dict exists $e Hidden] && [dict get $e Hidden] eq "true"} continue
			dict set e file $f
			dict set apps $id $e
		}
	}
	return $apps
}

# mimeapps.list files, most important first (the XDG order).
proc facts::mimeapps_files {} {
	set cfg [env XDG_CONFIG_HOME [home]/.config]
	set out [list [file join $cfg mimeapps.list]]
	foreach d [split [env XDG_CONFIG_DIRS /etc/xdg] :] { lappend out [file join $d mimeapps.list] }
	lappend out /usr/share/ribbon/xdg/mimeapps.list
	foreach d [concat [list [env XDG_DATA_HOME [home]/.local/share]] [split [env XDG_DATA_DIRS /usr/local/share:/usr/share] :]] {
		lappend out [file join $d applications mimeapps.list]
	}
	return $out
}

proc facts::mimeapps_read {f} {
	set g {}
	if {[catch {open $f} fh]} { return $g }
	fconfigure $fh -encoding utf-8
	set cur ""
	foreach line [split [read $fh] \n] {
		if {[regexp {^\[(.*)\]\s*$} $line -> cur]} continue
		if {[regexp {^([^=\s]+)\s*=\s*(.*)$} $line -> k v]} { dict lappend g "$cur\t$k" {*}[lmap x [split $v \;] { if {$x eq ""} continue; set x }] }
	}
	close $fh
	return $g
}

# ---- the type tree: shared-mime-info's aliases and subclasses --------------------------------------------------
# mime/aliases ("alias type") and mime/subclasses ("type parent") in each data folder (update-mime-database writes
# them), read once for a given data path; the most important folder's line for a type wins. Every text/* type is
# also a kind of text/plain (the shared-mime-info spec). application/octet-stream, everything's last parent, is
# left out: an app for "any file" is not what opens a file of a type that has none.
proc facts::mime_dirs {} {
	concat [list [env XDG_DATA_HOME [home]/.local/share]] [split [env XDG_DATA_DIRS /usr/local/share:/usr/share] :]
}
proc facts::mime_tree {} {
	variable tree
	set dirs [mime_dirs]
	if {[info exists tree] && [lindex $tree 0] eq $dirs} { return [lrange $tree 1 2] }
	set alias {}; set parents {}
	foreach d $dirs {
		set mine {}
		foreach {name kind} {aliases a subclasses p} {
			if {[catch {open [file join $d mime $name]} fh]} continue
			fconfigure $fh -encoding utf-8
			foreach line [split [read $fh] \n] {
				if {[llength [set w [split [string trim [string tolower $line]]]]] != 2} continue
				lassign $w k v
				if {$kind eq "a"} {
					if {![dict exists $alias $k]} { dict set alias $k $v }
				} elseif {![dict exists $parents $k] || $k in $mine} {
					if {$k ni $mine} { lappend mine $k; dict set parents $k {} }
					dict lappend parents $k $v
				}
			}
			close $fh
		}
	}
	set tree [list $dirs $alias $parents]
	list $alias $parents
}

# Type M and every type it is a kind of, nearest first (breadth first, as GLib walks them), aliases resolved and
# text/plain last: text/x-python -> text/x-python application/x-executable text/plain.
proc facts::mime_chain {m} {
	lassign [mime_tree] alias parents
	set m [string tolower $m]
	set out [list $m]
	if {[dict exists $alias $m]} { lappend out [dict get $alias $m] }
	for {set i 0} {$i < [llength $out]} {incr i} {
		set t [lindex $out $i]
		set up [expr {[dict exists $parents $t] ? [dict get $parents $t] : {}}]
		foreach p $up {
			if {[dict exists $alias $p]} { set p [dict get $alias $p] }
			if {$p ni $out && $p ne "application/octet-stream"} { lappend out $p }
		}
	}
	# text/plain, the root of every text/* type, comes after the types between
	if {[lsearch -glob $out text/*] >= 0} {
		set out [lsearch -all -inline -exact -not $out text/plain]
		lappend out text/plain
	}
	return $out
}

# What opens type M: {default {other ...}}, app ids that exist. The mime-apps spec's lookup, for M and then for
# each type it is a kind of (mime_chain), the way GLib does it: the nearest type that has a default or an
# associated app decides, its default first, then its first associated app (a kind of text no app names opens in
# text/plain's app; one an installed app names opens in that app). The others are every associated app, M's own
# first, then its parents'. An app taken out of a type ([Removed Associations]) stays out of its parents' lists for M too.
proc facts::handlers {m} {
	set default ""; set all {}; set removed {}
	set lists [lmap f [mimeapps_files] { mimeapps_read $f }]
	foreach t [mime_chain $m] {
		lassign [handlers_of $t $lists $removed] d a removed
		if {$default eq ""} { set default [expr {$d ne "" ? $d : [lindex $a 0]}] }
		foreach id $a { if {$id ni $all} { lappend all $id } }
	}
	set others [lmap id $all { if {$id eq $default} continue; set id }]
	list $default $others
}

# One type's own lookup in LISTS (mimeapps_read of each mimeapps_files): {default associated removed}, REMOVED (the
# apps taken out of the types nearer M) added to.
proc facts::handlers_of {m lists removed} {
	set apps [apps]
	set default ""; set added {}
	foreach g $lists {
		if {$default eq "" && [dict exists $g "Default Applications\t$m"]} {
			foreach id [dict get $g "Default Applications\t$m"] { if {[dict exists $apps $id] && $id ni $removed} { set default $id; break } }
		}
		if {[dict exists $g "Added Associations\t$m"]} { lappend added {*}[dict get $g "Added Associations\t$m"] }
		if {[dict exists $g "Removed Associations\t$m"]} { lappend removed {*}[dict get $g "Removed Associations\t$m"] }
	}
	set all {}
	foreach id $added { if {[dict exists $apps $id] && $id ni $removed && $id ni $all} { lappend all $id } }
	set major [lindex [split $m /] 0]
	foreach id [dict keys $apps] {
		set e [dict get $apps $id]
		if {![dict exists $e MimeType] || $id in $removed || $id in $all} continue
		set types [split [string tolower [dict get $e MimeType]] \;]
		if {$m in $types || "$major/*" in $types} { lappend all $id }
	}
	list $default $all $removed
}

proc facts::app_name {id} {
	set apps [apps]
	if {![dict exists $apps $id]} { return [file rootname $id] }
	dict get $apps $id Name
}

# The line icon for an app (the shell's apps::iconfor rules).
proc facts::app_icon {id} {
	set apps [apps]
	set e [expr {[dict exists $apps $id] ? [dict get $apps $id] : {}}]
	app_icon_for [expr {[dict exists $e Name] ? [dict get $e Name] : $id}] [expr {[dict exists $e Categories] ? [dict get $e Categories] : ""}] $id
}
proc facts::app_icon_for {name cats {id ""}} {
	set k [string tolower "$name $id"]
	if {[regexp {firefox|chrom|browser} $k]} { return globe }
	if {[regexp {terminal} $k]} { return terminal }
	if {[regexp {steam} $k]} { return game }
	if {[regexp {files|thunar} $k]} { return folder }
	if {[regexp {paint|draw} $k]} { return paint }
	if {[regexp {darkroom|editor|gimp|krita} $k] && [string match *Graphics* $cats]} { return edit }
	foreach {pat ic} {
		*Database* database *WebBrowser* globe *FileManager* folder *TerminalEmulator* terminal *Game* game
		*Photography* edit *Viewer* image *Graphics* image *Recorder* rec *Audio* music *Video* film *Development* code
		*TextEditor* doc *Office* file *Settings* sliders *System* sliders
	} { if {[string match $pat $cats]} { return $ic } }
	return grid
}

# Make APP the default for type M (~/.config/mimeapps.list, [Default
# Applications]), keeping every other line.
proc facts::set_default {m app} {
	set f [lindex [mimeapps_files] 0]
	set lines {}
	if {![catch {open $f} fh]} { fconfigure $fh -encoding utf-8; set lines [split [string trimright [read $fh] \n] \n]; close $fh }
	set out {}; set cur ""; set done 0; set saw 0
	foreach line $lines {
		if {[regexp {^\[(.*)\]\s*$} $line -> sec]} {
			if {$cur eq "Default Applications" && !$done} { lappend out "$m=$app"; set done 1 }
			set cur $sec
			if {$sec eq "Default Applications"} { set saw 1 }
		} elseif {$cur eq "Default Applications" && [regexp {^([^=\s]+)\s*=} $line -> k] && $k eq $m} {
			if {!$done} { lappend out "$m=$app"; set done 1 }
			continue
		}
		lappend out $line
	}
	if {!$done} {
		if {!$saw} { lappend out {[Default Applications]} }
		lappend out "$m=$app"
	}
	file mkdir [file dirname $f]
	set tmp $f.tmp[pid]
	set fh [open $tmp w]; fconfigure $fh -encoding utf-8 -translation lf
	puts $fh [join $out \n]; close $fh
	file rename -force $tmp $f
}

# ---- photos --------------------------------------------------------------------------

# {w h} of a picture, or "".
proc facts::image_size {path} {
	if {[catch {wall::image_size $path} wh]} { return "" }
	return $wh
}

# A JPEG's EXIF (APP1): a dict of what the Photo page shows: Make Model
# LensModel ExposureTime FNumber ISO FocalLength DateTimeOriginal.
proc facts::exif {path} {
	if {[catch {open $path rb} fh]} { return {} }
	set d [read $fh 131072]; close $fh
	if {[string range $d 0 1] ne "\xff\xd8"} { return {} }
	set i 2
	while {$i < [string length $d] - 4} {
		binary scan $d @${i}cucuSu ff m len
		if {$ff != 0xff || $m == 0xda} break
		if {$m == 0xe1 && [string range $d [expr {$i + 4}] [expr {$i + 9}]] eq "Exif\0\0"} {
			return [tiff [string range $d [expr {$i + 10}] [expr {$i + 2 + $len - 1}]]]
		}
		incr i [expr {2 + $len}]
	}
	return {}
}

proc facts::tiff {t} {
	set bo [string range $t 0 1]
	if {$bo eq "II"} { set s s; set I i } elseif {$bo eq "MM"} { set s S; set I I } else { return {} }
	binary scan $t @4${I}u ifd0
	# the main IFD's tags, the Exif IFD's (through ExifIFD) and the GPS IFD's (through GPSInfo)
	set names {0x010f Make 0x0110 Model 0x8769 ExifIFD 0x8825 GPSInfo 0x829a ExposureTime 0x829d FNumber 0x8827 ISO
		0x920a FocalLength 0x9003 DateTimeOriginal 0xa434 LensModel}
	set gpsnames {0x0001 GPSLatitudeRef 0x0002 GPSLatitude 0x0003 GPSLongitudeRef 0x0004 GPSLongitude}
	set out {}
	set todo [list [list $ifd0 main]]
	set seen {}
	while {[llength $todo]} {
		lassign [lindex $todo 0] off kind
		set todo [lrange $todo 1 end]
		if {$off in $seen || $off + 2 > [string length $t]} continue
		lappend seen $off
		binary scan $t @$off${s}u n
		for {set k 0} {$k < $n && $k < 200} {incr k} {
			set e [expr {$off + 2 + 12 * $k}]
			if {$e + 12 > [string length $t]} break
			binary scan $t @$e${s}u${s}u${I}u tag type count
			set tag [format 0x%04x $tag]
			if {$kind eq "gps"} {
				if {![dict exists $gpsnames $tag]} continue
				set name [dict get $gpsnames $tag]
			} else {
				if {![dict exists $names $tag]} continue
				set name [dict get $names $tag]
			}
			set sizes {1 1 2 1 3 2 4 4 5 8 7 1 9 4 10 8}
			set sz [expr {[dict exists $sizes $type] ? [dict get $sizes $type] * $count : 0}]
			if {$sz <= 4} { set vo [expr {$e + 8}] } else { binary scan $t @[expr {$e + 8}]${I}u vo }
			switch -- $type {
				2 { set v [string trimright [string range $t $vo [expr {$vo + $count - 1}]] "\0 "] }
				3 { binary scan $t @$vo${s}u v }
				4 { binary scan $t @$vo${I}u v }
				5 {
					# a rational; GPS coordinates are three of them (degrees, minutes, seconds)
					set v {}
					for {set j 0} {$j < $count && $j < 3} {incr j} {
						binary scan $t @[expr {$vo + 8 * $j}]${I}u${I}u a b
						lappend v [expr {$b ? double($a) / $b : 0.0}]
					}
					if {$count == 1} { set v [lindex $v 0] }
				}
				default { continue }
			}
			switch -- $name {
				ExifIFD { lappend todo [list $v main] }
				GPSInfo { lappend todo [list $v gps] }
				default { dict set out $name $v }
			}
		}
	}
	return $out
}

# "64.078° N, 16.231° W" from the GPS tags of an EXIF dict, or "".
proc facts::coords {x} {
	foreach k {GPSLatitude GPSLongitude} { if {![dict exists $x $k] || [llength [dict get $x $k]] != 3} { return "" } }
	set out {}
	foreach {k ref pos neg} {GPSLatitude GPSLatitudeRef N S GPSLongitude GPSLongitudeRef E W} {
		lassign [dict get $x $k] d m sec
		set deg [expr {$d + $m / 60.0 + $sec / 3600.0}]
		set hemi [expr {[dict exists $x $ref] && [dict get $x $ref] eq $neg ? $neg : $pos}]
		lappend out [format "%.3f° %s" $deg $hemi]
	}
	join $out ", "
}

# The language a text file is in, from its name: "Rust", "Shell script", ...
proc facts::language {path} {
	set e [string tolower [string trimleft [file extension $path] .]]
	set langs {rs Rust tcl Tcl py Python c C h C cc {C++} cpp {C++} hpp {C++} js JavaScript ts TypeScript
		go Go sh {Shell script} md Markdown txt {Plain text} json JSON toml TOML yaml YAML html HTML css CSS
		xml XML sql SQL}
	if {[dict exists $langs $e]} { return [dict get $langs $e] }
	return ""
}

# A text file's facts: its lines, characters, encoding and line endings, and
# its first N lines. Files over 8 MB are read as far as that and counted to there
# (lines and characters are then left "").
proc facts::text_info {path {n 12}} {
	set d [dict create lines "" chars "" enc "" eol "" head {}]
	if {[catch {open $path rb} fh]} { return $d }
	set size [file size $path]
	set whole [expr {$size <= 8000000}]
	set data [read $fh [expr {$whole ? $size : 8000000}]]
	close $fh
	if {[string first \0 $data] >= 0} { return $d }
	# Tcl's utf-8 decoder substitutes for bad bytes rather than failing, so UTF-8 is
	# a file that survives the round trip
	set txt [encoding convertfrom utf-8 $data]
	set enc [expr {[encoding convertto utf-8 $txt] eq $data ? "UTF-8" : "Unknown"}]
	if {$enc eq "Unknown"} { set txt [encoding convertfrom iso8859-1 $data] }
	set lines [split $txt \n]
	set eol [expr {[string first \r\n $data] >= 0 ? "CRLF" : ([string first \n $data] >= 0 ? "LF" : "None")}]
	if {$whole} {
		dict set d lines [expr {[llength $lines] - ([string index $txt end] eq "\n" ? 1 : 0)}]
		dict set d chars [string length $txt]
	}
	dict set d enc $enc
	dict set d eol $eol
	dict set d head [lmap l [lrange $lines 0 [expr {$n - 1}]] { string trimright $l "\r" }]
	return $d
}

# "Fujifilm X-T5": the camera, the maker's name once.
proc facts::camera {x} {
	set make [expr {[dict exists $x Make] ? [string trim [dict get $x Make]] : ""}]
	set model [expr {[dict exists $x Model] ? [string trim [dict get $x Model]] : ""}]
	if {$model eq ""} { return "" }
	set short [lindex [split [string totitle [lindex [split $make] 0]]] 0]
	if {$short ne "" && [string first [string tolower $short] [string tolower $model]] == 0} { set model [string range $model [string length $short] end] }
	string trim "$short [string trim $model]"
}

# A number from an EXIF dict, or "" (a tag a camera left out, or one that isn't a number).
proc facts::num {x k} {
	if {![dict exists $x $k]} { return "" }
	set v [dict get $x $k]
	if {![string is double -strict $v] || $v <= 0} { return "" }
	return $v
}

# A shutter speed as photographers write it: "1/250" for a fraction of a second that
# is a whole number of parts (0.4 is "0.4 s"), "2 s" from a second up.
proc facts::shutter {t} {
	if {$t >= 1} { return "[format %g $t] s" }
	set n [expr {round(1.0 / $t)}]
	if {abs(1.0 / $t - $n) <= 0.1} { return "1/$n" }
	return "[format %g $t] s"
}

# The four figures of the Photo section's exposure strip, as {value label} in the board's
# order: aperture, shutter, ISO, focal length. A figure the photo doesn't have is "".
proc facts::exposure {x} {
	set f ""; set s ""; set iso ""; set fl ""
	if {[set v [num $x FNumber]] ne ""} { set f "f/[format %g $v]" }
	if {[set v [num $x ExposureTime]] ne ""} { set s [shutter $v] }
	if {[set v [num $x ISO]] ne ""} { set iso [format %d [expr {round($v)}]] }
	if {[set v [num $x FocalLength]] ne ""} { set fl "[format %g $v] mm" }
	return [list [list $f Aperture] [list $s Shutter] [list $iso ISO] [list $fl Focal]]
}

# ---- a folder: counted in the background -----------------------------------------------------

proc facts::category {name} {
	switch -glob -nocase -- $name {
		*.png - *.jpg - *.jpeg - *.webp - *.gif - *.heic - *.avif - *.raw - *.raf - *.cr2 - *.cr3 - *.nef - *.arw - *.dng - *.tif - *.tiff - *.bmp - *.svg { return photos }
		*.mp4 - *.mkv - *.webm - *.mov - *.avi - *.m4v { return videos }
		*.pdf - *.txt - *.md - *.doc - *.docx - *.odt - *.ods - *.odp - *.xls - *.xlsx - *.ppt - *.pptx - *.rtf - *.epub { return documents }
		default { return other }
	}
}

# Start counting PATH (recursively); DONE runs (with no arguments) after
# every slice and at the end, while facts::W(busy) says which. W(top,NAME):
# the bytes under each of PATH's own entries; W(newest): {mtime path} of
# the newest pictures, W(recent) of the newest files.
proc facts::count {path done} {
	variable walk
	variable W
	after cancel facts::count_step
	array unset W
	array set W {files 0 dirs 0 bytes 0 busy 1 newest {} recent {} tops {}}
	set W(path) $path
	foreach k {photos videos documents other} { set W($k,n) 0; set W($k,b) 0 }
	set W(done) $done
	set walk [list [list $path ""]]
	after idle facts::count_step
}

proc facts::count_step {} {
	variable walk
	variable W
	set t0 [clock milliseconds]
	while {[llength $walk] && [clock milliseconds] - $t0 < 25} {
		lassign [lindex $walk end] d top
		set walk [lrange $walk 0 end-1]
		foreach p [glob -nocomplain -directory $d * .*] {
			set n [file tail $p]
			if {$n in {. ..}} continue
			if {[catch {file lstat $p st}]} continue
			set t [expr {$top eq "" ? $n : $top}]
			if {$top eq ""} { lappend W(tops) $n; set W(top,$n) 0 }
			if {$st(type) eq "directory"} { incr W(dirs); lappend walk [list $p $t]; continue }
			if {$st(type) ne "file"} continue
			incr W(files)
			incr W(bytes) $st(size)
			incr W(top,$t) $st(size)
			set c [category $n]
			incr W($c,n); incr W($c,b) $st(size)
			lappend W(recent) [list $st(mtime) $p]
			if {[string match -nocase {*.[jp][pn]*g} $n]} { lappend W(newest) [list $st(mtime) $p] }
			if {[llength $W(recent)] > 60} { set W(recent) [lrange [lsort -decreasing -integer -index 0 $W(recent)] 0 19] }
			if {[llength $W(newest)] > 60} { set W(newest) [lrange [lsort -decreasing -integer -index 0 $W(newest)] 0 19] }
		}
	}
	set W(recent) [lrange [lsort -decreasing -integer -index 0 $W(recent)] 0 19]
	set W(newest) [lrange [lsort -decreasing -integer -index 0 $W(newest)] 0 19]
	if {[llength $walk]} { after 1 facts::count_step } else { set W(busy) 0 }
	uplevel #0 $W(done)
}

# The drive a path is on: {label free} ("System", 412 GB free).
proc facts::drive {path} {
	if {[catch {exec df -B1 --output=target,avail -- $path 2>/dev/null} df]} { return "" }
	lassign [lindex [split $df \n] 1] target avail
	if {$target eq "/"} { set label System } elseif {[string match /mnt/games/* $target]} { set label [string totitle [file tail $target]] } \
	elseif {$target eq "/home" || [string match /home/* $target]} { set label Home } else { set label [file tail $target] }
	list $label $avail
}

# Users who could own a file: root and real accounts (uid >= 1000).
proc facts::users {} {
	set out {}
	if {![catch {open /etc/passwd} fh]} {
		foreach line [split [read $fh] \n] {
			lassign [split $line :] n - uid
			if {$n ne "" && [string is integer -strict $uid] && ($uid == 0 || ($uid >= 1000 && $uid < 60000))} { lappend out $n }
		}
		close $fh
	}
	return $out
}
