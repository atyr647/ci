# chooser-main.tcl - the Ribbon file chooser's window: Open, Save as and Choose a folder for every Ribbon app,
# drawn to the Chooser-* boards (design/tools/gen_chooser.py): an 880 x 580 window built from Ribbon Files' parts
# (toolbar, sidebar of places and mounted drives, the list view) with a 72 footer under the list, on the shell's
# rasteriser, palette and text code and Appearance's controls (appearance/ui.tcl).
#
# Apps don't run this file themselves: they call chooser::open_file, chooser::save_file or chooser::choose_folder
# (appearance/chooser.tcl), which runs it as a program of its own and waits for its answer:
#
#   wish chooser-main.tcl -name ribbon-chooser -- -mode open|save|folder ?-title T? ?-initialdir D?
#           ?-initialfile F? ?-filetypes TYPES? ?-multiple 0|1? ?-defaultextension .EXT? ?-confirmoverwrite 0|1?
#           ?-at "X Y W H"? ?-initialtype LABEL? ?-acceptlabel TEXT? ?-choices CHOICES?
#
# The options may also come as one word, a Tcl list of them (chooser.tcl and the portal send them so).
# On a choice it prints a line with the file type in use (its index in -filetypes; -1 when there are none), then the
# chosen paths as a Tcl list, and exits; cancelled, it prints nothing.
# -choices (the FileChooser portal's "choices", board Chooser-Save-Choices) is a list of {id label options default}:
# OPTIONS a list of {id label} makes a list, none a checkbox (its value "true" or "false"). Given, the answer has a
# line between the type and the paths: the choices' values, a Tcl list of {id value}.
# New folder (the toolbar's button in Save as and Choose a folder, Ctrl Shift N; board Chooser-New-Folder) makes
# "New folder" (" 2", " 3" when taken) in the folder shown and puts its name in a field in its row: Return (or a
# press elsewhere) renames it to what was typed, Escape keeps the name it was made with.
# -at is the asking window's place on the screen: the chooser opens centred over it. -initialtype names the file type
# in use at first; -acceptlabel is the primary button's word when the asker gives its own (the FileChooser portal).
#
# Tests: RIBBON_CHOOSER_SCENE=1 draws the window undecorated where the boards put it (280,160 on a 1440 x 900
# screen); RIBBON_CHOOSER_TEST=SCRIPT is sourced once the window is up; RIBBON_CHOOSER_DRIVES=FILE stands in for
# the mounted drives ({label path used size avail} per line); RIBBON_CHOOSER_NOW=SECONDS is "now" for the dates.

if {$tcl_platform(platform) eq "unix"} { encoding system utf-8 }
set appdir [file dirname [file normalize [info script]]]
proc find_dir {name file} {
	foreach d [list [file join [file dirname $::appdir] $name] /usr/lib/ribbon/$name] {
		if {[file exists [file join $d $file]]} { return $d }
	}
	puts stderr "ribbon-chooser: $name/$file was not found"; exit 1
}
set shelldir [expr {[info exists env(RIBBON_SHELL_DIR)] ? $env(RIBBON_SHELL_DIR) : [find_dir shell raster.tcl]}]
foreach d [list /usr/lib/ribbon [file dirname $shelldir]] { if {$d ni $auto_path} { lappend auto_path $d } }
# an app on tclsh with Tk loaded runs this on tclsh too
package require Tk
package require rbnalpha
# text.tcl first: it sets up the fonts' weights before Tk opens a font
foreach f {text raster wall theme} { source -encoding utf-8 [file join $shelldir $f.tcl] }
namespace eval page {}
source -encoding utf-8 [file join $appdir ui.tcl]
# what the boards use beyond Appearance's set: Files' toolbar title, the question's title, Files' icons
set ui::fonts(sg15) {{Ribbon Space Grotesk 600} 15 0.984 0.292}
set ui::fonts(sg20) {{Ribbon Space Grotesk 600} 20 0.984 0.292}
set ui::fonts(i11) {{Ribbon Inter 400} 11 0.96875 0.2412}
array set ui::paths {
	left     {M15 18l-6-6 6-6}
	right    {M9 18l6-6-6-6}
	down     {M6 9l6 6 6-6}
	check    {M20 6L9 17l-5-5}
	home     {M3 10l9-7 9 7v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z M9 22V12h6v10}
	download {M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4 M7 10l5 5 5-5 M12 15V3}
	image    {M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z M8.5 10a1.5 1.5 0 1 0 0-3a1.5 1.5 0 1 0 0 3z M21 15l-5-5L5 21}
	doc      {M4 3h16v18H4z M8 7h8 M8 11h8 M8 15h5}
	music    {M9 18V5l12-2v13 M6 21a3 3 0 1 0 0-6a3 3 0 1 0 0 6z M18 19a3 3 0 1 0 0-6a3 3 0 1 0 0 6z}
	drive    {M22 12H2 M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z M6 16h.01 M10 16h.01}
	folder   {M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z}
	file     {M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z M14 3v5h5}
	folderplus {M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z M12 11v6 M9 14h6}
	film     {M4 3h16a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z M7 3v18 M17 3v18 M3 12h18 M3 7.5h4 M3 16.5h4 M17 7.5h4 M17 16.5h4}
}

namespace eval page {
	variable W 880
	variable H 580
	variable SW 196            ;# the sidebar
	variable TB 46             ;# the toolbar
	variable FT 72             ;# the footer
	variable LT 94             ;# the first row's top: toolbar, 8 in, the 34 header, 4 and the rows' 2
	variable RH 40             ;# a row and the 2 after it
	variable o                 ;# the options the app asked with
	array set o {-mode open -title "" -initialdir "" -initialfile "" -filetypes {} -multiple 0
		-defaultextension "" -confirmoverwrite 1 -at "" -initialtype "" -acceptlabel "" -choices {}}
	variable dir ""            ;# the folder shown
	variable back {}           ;# folders to go back to
	variable fwd {}
	variable items {}          ;# {name isdir size mtime} shown, folders first
	variable sel {}            ;# chosen names
	variable anchor ""         ;# where a shift-click range starts
	variable top 0             ;# the first row shown
	variable hidden 0          ;# dot files shown
	variable types {}          ;# {label patterns} the file types, "All files" last
	variable type 0            ;# the one in use
	variable pop 0             ;# the types' list is open
	variable popidx 0
	variable ask ""            ;# a path whose replacing is being asked
	variable typed ""          ;# type-ahead
	variable typedat 0
	variable mods 0            ;# the modifiers of the click being handled
	variable CH 52             ;# a row of the choices' strip
	variable choices {}        ;# {id label options} the app's choices
	variable cval              ;# id -> its value now
	array set cval {}
	variable cpop ""           ;# the list choice whose list is open
	variable cpopidx 0
	variable renaming ""       ;# the new folder whose name is in the field
	variable rbox {}           ;# the rename field's place {x y w h}
	variable drives {}
	variable pending ""
}

proc page::env {name {default ""}} {
	expr {[info exists ::env($name)] && $::env($name) ne "" ? $::env($name) : $default}
}

proc page::home {} { env HOME / }

# ---- places and drives ---------------------------------------------------------------

# An XDG user folder (localised names included), as Files reads it.
proc page::userdir {key fallback} {
	set f [file join [env XDG_CONFIG_HOME [file join [home] .config]] user-dirs.dirs]
	if {![catch {::open $f} fh]} {
		set t [read $fh]; ::close $fh
		if {[regexp -line "^XDG_${key}_DIR=\"(.*)\"" $t -> p]} { return [string map [list \$HOME [home]] $p] }
	}
	file join [home] $fallback
}

# PLACES: Files' places without the Trash, each only when its folder exists.
proc page::places {} {
	set out [list [list Home home [file normalize [home]]]]
	foreach {label icon key fb} {Downloads download DOWNLOAD Downloads Pictures image PICTURES Pictures
			Documents doc DOCUMENTS Documents Music music MUSIC Music} {
		set p [file normalize [userdir $key $fb]]
		if {$p ne [file normalize [home]] && [file isdirectory $p]} { lappend out [list $label $icon $p] }
	}
	return $out
}

proc page::human {b} {
	foreach {u n} {TB 1e12 GB 1e9 MB 1e6 KB 1e3} {
		if {$b >= $n} { return [regsub {\.0 } [::format "%.1f %s" [expr {$b / $n}] $u] { }] }
	}
	return "$b B"
}

# DRIVES: the system's root and every drive mounted under /run/media/USER, /media or /mnt (where udisks and people
# mount them; Files' sidebar also lists drives not mounted, which a chooser can't open): {label path used size avail}.
proc page::read_drives {} {
	variable drives {}
	set f [env RIBBON_CHOOSER_DRIVES]
	if {$f ne ""} {
		if {![catch {::open $f} fh]} {
			foreach line [split [read $fh] \n] { if {[llength $line] == 5} { lappend drives $line } }
			::close $fh
		}
		return
	}
	set paths [list /]
	if {![catch {::open /proc/mounts} fh]} {
		foreach line [split [read $fh] \n] {
			# drives only: a block device mounted there (not a bind, tmpfs or network share)
			if {![string match /dev/* [lindex $line 0]]} continue
			set m [subst -nocommands -novariables [lindex $line 1]]
			if {[regexp {^/(run/media/[^/]+|media|mnt)/[^/]+$} $m] && [file isdirectory $m]} { lappend paths $m }
		}
		::close $fh
	}
	foreach p [lsort -unique $paths] {
		if {[catch {exec df -P -B1 $p 2>/dev/null} out]} continue
		set l [lindex [split [string trim $out] \n] end]
		lassign $l - size used avail
		if {![string is wide -strict $size] || $size <= 0} continue
		lappend drives [list [expr {$p eq "/" ? "System" : [file tail $p]}] $p $used $size $avail]
	}
}

# ---- the folder ------------------------------------------------------------------------

proc page::mode {} { return $::page::o(-mode) }

# A file type's patterns match NAME: ".png" is any name ending .png, "*" any name, a glob as given.
proc page::wanted {name} {
	variable types
	variable type
	if {![llength $types]} { return 1 }
	foreach p [lindex $types $type 1] {
		if {$p eq "*" || $p eq "*.*"} { return 1 }
		if {[string index $p 0] eq "."} { set p *$p }
		if {[string match -nocase $p $name]} { return 1 }
	}
	return 0
}

# NAME (a name in folder DIR, or a path typed relative to it) as a path. A name that starts with ~ is that name:
# Tcl 8.6's file join would take ~draft.txt for the home folder of a user "draft.txt".
proc page::child {dir name} {
	if {[string index $name 0] eq "~"} { set name ./$name }
	file normalize [file join $dir $name]
}

# The last name in path P, and the folder it is in: Tcl 8.6's file tail gives ./~name for ~name, and file dirname and
# file pathtype take a ~name for a user's home.
proc page::tail {p} { lindex [split $p /] end }
proc page::parent {p} {
	set d [string trimright [string range $p 0 [expr {[string last / $p] - 1}]] /]
	expr {$d eq "" ? "/" : $d}
}

proc page::read_dir {} {
	variable dir
	variable items {}
	variable hidden
	set names [glob -nocomplain -tails -directory $dir *]
	if {$hidden} { lappend names {*}[lsearch -all -inline -not -regexp [glob -nocomplain -tails -types hidden -directory $dir *] {^\.\.?$}] }
	set dirs {}; set files {}
	foreach n $names {
		set p [child $dir $n]
		set isdir [file isdirectory $p]
		if {!$isdir && ([mode] eq "folder" || ![wanted $n])} continue
		if {[catch {file stat $p st}]} { if {[catch {file lstat $p st}]} continue }
		set e [list $n $isdir $st(size) $st(mtime)]
		if {$isdir} { lappend dirs $e } else { lappend files $e }
	}
	set items [concat [lsort -dictionary -index 0 $dirs] [lsort -dictionary -index 0 $files]]
}

# Go to folder P (history: 1 remembers where we were for Back).
proc page::go {p {history 1}} {
	variable dir
	variable back
	variable fwd
	set p [file normalize $p]
	if {![file isdirectory $p] || ![file readable $p] || ![file executable $p]} { return 0 }
	# a new folder being named is named in its own folder before another is shown (the name typed is kept)
	rename_done
	if {$history && $dir ne "" && $dir ne $p} { lappend back $dir; set fwd {} }
	set dir $p
	set ::page::sel {}
	set ::page::anchor ""
	set ::page::top 0
	read_dir
	if {[mode] eq "save"} { match_name }
	draw
	return 1
}

proc page::go_back {} {
	variable back
	variable fwd
	variable dir
	while {[llength $back]} {
		set p [lindex $back end]; set back [lrange $back 0 end-1]
		set was $dir
		if {[go $p 0]} { lappend fwd $was; return }
	}
}

proc page::go_forward {} {
	variable back
	variable fwd
	variable dir
	while {[llength $fwd]} {
		set p [lindex $fwd end]; set fwd [lrange $fwd 0 end-1]
		set was $dir
		if {[go $p 0]} { lappend back $was; return }
	}
}

proc page::go_up {} {
	variable dir
	set up [parent $dir]
	if {$up eq $dir} return
	set was [tail $dir]
	if {[go $up]} { select [list $was]; reveal $was; draw }
}

# The kind column, by the name's extension.
proc page::kind {name isdir} {
	if {$isdir} { return Folder }
	set e [string tolower [string trimleft [file extension $name] .]]
	set k [dict create jpg "JPEG image" jpeg "JPEG image" png "PNG image" gif "GIF image" webp "WebP image" avif "AVIF image" \
		bmp "BMP image" svg "SVG image" heic "HEIC image" tif "TIFF image" tiff "TIFF image" \
		md "Markdown" markdown "Markdown" txt "Plain text" pdf "PDF document" html "HTML page" json "JSON" \
		mp3 "MP3 audio" flac "FLAC audio" ogg "Ogg audio" opus "Opus audio" wav "WAV audio" m4a "MPEG-4 audio" \
		mp4 "MPEG-4 video" mkv "Matroska video" webm "WebM video" mov "QuickTime video" \
		zip "Zip archive" tar "Tar archive" gz "Gzip archive" xz "XZ archive" zst "Zstd archive" 7z "7-Zip archive" \
		iso "Disc image" tcl "Tcl source" py "Python source" sh "Shell script" c "C source" h "C header" rs "Rust source" \
		ribbon-theme "Ribbon theme" conf "Settings" desktop "App launcher"]
	if {[dict exists $k $e]} { return [dict get $k $e] }
	if {$e eq ""} { return File }
	return "[string toupper $e] file"
}

proc page::icon_of {name isdir} {
	if {$isdir} { return folder }
	switch -glob -nocase -- $name {
		*.png - *.jpg - *.jpeg - *.webp - *.gif - *.svg - *.bmp - *.avif - *.heic - *.tif - *.tiff { return image }
		*.mp3 - *.flac - *.ogg - *.opus - *.wav - *.m4a - *.aac { return music }
		*.mp4 - *.mkv - *.webm - *.mov - *.avi { return film }
		default { return file }
	}
}

# The modified column: the time today, "3 Nov" this year, "3 Nov 2024" before.
proc page::when {t} {
	set now [env RIBBON_CHOOSER_NOW [clock seconds]]
	if {[clock format $t -format %Y%m%d] eq [clock format $now -format %Y%m%d]} { return [clock format $t -format %H:%M] }
	set d [string trimleft [clock format $t -format %d] 0]
	if {[clock format $t -format %Y] eq [clock format $now -format %Y]} { return "$d [clock format $t -format %b]" }
	return "$d [clock format $t -format {%b %Y}]"
}

# ---- choosing --------------------------------------------------------------------------

proc page::index_of {name} {
	lsearch -exact -index 0 $::page::items $name
}

proc page::select {names} {
	variable sel $names
	variable anchor [lindex $names end]
}

# Keep row NAME on screen.
proc page::reveal {name} {
	variable top
	set i [index_of $name]
	if {$i < 0} return
	set n [rows_shown]
	if {$i < $top} { set top $i } elseif {$i >= $top + $n} { set top [expr {$i - $n + 1}] }
}

proc page::rows_shown {} {
	variable H; variable FT; variable LT; variable RH
	expr {max(1, ($H - $FT - [strip_h] - $LT - 8 + 2) / $RH)}
}

# A click on row I: chosen alone; with Ctrl added or taken away, with Shift a range (when several may be chosen).
# In Save as a file's name goes into the Name field.
proc page::click_row {i} {
	variable items
	variable sel
	variable anchor
	variable mods
	set name [lindex $items $i 0]
	if {$::page::o(-multiple) && ($mods & 4)} {
		if {$name in $sel} { set sel [lsearch -all -inline -not -exact $sel $name] } else { lappend sel $name }
		set anchor $name
	} elseif {$::page::o(-multiple) && ($mods & 1) && $anchor ne "" && [index_of $anchor] >= 0} {
		set a [index_of $anchor]
		set sel [lmap e [lrange $items [expr {min($a, $i)}] [expr {max($a, $i)}]] { lindex $e 0 }]
	} else {
		select [list $name]
	}
	if {[mode] eq "save" && ![lindex $items $i 1]} { ui::fset name $name }
	draw
}

# A double-click or Return on a row: a folder is opened, a file chosen.
proc page::activate {i} {
	variable items
	lassign [lindex $items $i] name isdir
	if {$name eq ""} return
	if {$isdir} { go [child $::page::dir $name]; return }
	if {[mode] eq "save"} { ui::fset name $name; accept; return }
	if {[mode] eq "open"} { select [list $name]; accept }
}

# The typed name in Save as: the row of that name is chosen.
proc page::match_name {} {
	set t [ui::fval name]
	set i [index_of $t]
	if {$i >= 0} { select [list $t]; reveal $t } else { set ::page::sel {} }
	draw
}

# The primary button: Open, Save or Choose.
proc page::accept {} {
	variable dir
	variable sel
	variable items
	if {$::page::ask ne "" || $::page::pop} return
	switch [mode] {
		open {
			set chosen [lmap n $sel { if {[index_of $n] < 0} continue; set n }]
			if {[llength $chosen] == 1 && [lindex $items [index_of [lindex $chosen 0]] 1]} {
				go [child $dir [lindex $chosen 0]]; return
			}
			set files [lmap n $chosen { if {[lindex $items [index_of $n] 1]} continue; child $dir $n }]
			if {![llength $files]} return
			done $files
		}
		folder {
			set chosen [lmap n $sel { if {[index_of $n] < 0} continue; set n }]
			if {[llength $chosen] == 1} { done [list [child $dir [lindex $chosen 0]]] } else { done [list $dir] }
		}
		save {
			set t [string trim [ui::fval name]]
			if {$t eq ""} return
			if {$t eq "~" || [string match ~/* $t]} { set t [home][string range $t 1 end] }
			set p [child $dir $t]
			if {[file isdirectory $p]} {
				if {[go $p]} { ui::fset name "" ; draw }
				return
			}
			set ext $::page::o(-defaultextension)
			if {$ext ne "" && [file extension $p] eq ""} { append p [expr {[string index $ext 0] eq "." ? $ext : ".$ext"}] }
			if {![file isdirectory [parent $p]]} return
			if {[file exists $p] && $::page::o(-confirmoverwrite)} {
				set ::page::ask $p
				set ui::focus ""
				draw
				return
			}
			done [list $p]
		}
	}
}

proc page::replace {yes} {
	variable ask
	set p $ask
	set ask ""
	if {$yes} { done [list $p]; return }
	set ui::focus name
	draw
}

proc page::done {paths} {
	puts stdout [expr {[llength $::page::types] ? $::page::type : -1}]
	if {[llength $::page::choices]} {
		puts stdout [list {*}[lmap ch $::page::choices { list [lindex $ch 0] $::page::cval([lindex $ch 0]) }]]
	}
	puts stdout [list {*}$paths]
	flush stdout
	exit 0
}

proc page::cancel {} {
	exit 0
}

# ---- the file types ---------------------------------------------------------------------

proc page::open_pop {} {
	variable pop
	variable popidx
	if {$::page::ask ne ""} return
	set pop 1
	set popidx $::page::type
	set ui::focus types-pop
	draw
}

proc page::close_pop {{keys 0}} {
	variable pop 0
	set ui::focus [expr {$keys ? "types" : ""}]
	draw
}

# Use file type I. Chosen with the keys, the keys stay on the dropdown; with the pointer, they go back to the list.
# What was chosen and is still listed stays chosen.
proc page::pick_type {i {keys 0}} {
	variable type $i
	variable pop 0
	set ui::focus [expr {$keys ? "types" : ""}]
	read_dir
	set ::page::sel [lmap n $::page::sel { if {[index_of $n] < 0} continue; set n }]
	if {[mode] eq "save"} { match_name }
	draw
}

proc page::pop_key {sym} {
	variable popidx
	switch -- $sym {
		Up { set popidx [expr {max(0, $popidx - 1)}] }
		Down { set popidx [expr {min([llength $::page::types] - 1, $popidx + 1)}] }
		Return - KP_Enter - space { pick_type $popidx 1; return 1 }
		Escape { close_pop 1; return 1 }
		default { return 0 }
	}
	draw
	return 1
}

# ---- drawing ------------------------------------------------------------------------

proc page::draw {} {
	variable pending
	if {$pending ne ""} return
	set pending [after idle page::draw_now]
}

# The window's frame: Files' §win surface, its §bar sidebar with the rule at its right, the 1 px ring; rounded when
# the window draws its own frame (labwc's frame is square: then neither).
proc page::frame_boxes {} {
	variable W
	variable H
	variable SW
	array set c [array get ui::c]
	set r [ui::outer_radius 12]
	ui::box 0 0 $W $H -fill $c(win) -radius $r
	ui::box 0 0 $SW $H -fill $c(bar) -radius $r
	ui::box [expr {$SW - $r - 1}] 0 [expr {$r + 1}] $H -fill $c(bar)
	ui::box [expr {$SW - 1}] 0 1 $H -fill $c(border)
	if {$r > 0} { ui::ring 0 0 $W $H $r $c(border) 1 } else { ui::ring 0 0 $W $H 0 $c(border) 1 }
}

proc page::draw_now {} {
	variable pending ""
	variable ask
	# the question shades the chooser (a 50 % scrim) and is drawn over it
	set ui::dim [expr {$ask ne "" ? 0.5 : 0}]
	ui::begin [list frame $::page::W $::page::H] page::frame_boxes
	sidebar
	toolbar
	list_rows
	choices_strip
	footer
	if {$::page::pop} { popup }
	if {$::page::cpop ne ""} { choice_popup }
	if {$ask ne ""} {
		ui::layer
		set ui::dim 0
		question
	}
	ui::focus_ring
	ui::finish
}

proc page::sidebar {} {
	variable SW
	array set c [array get ui::c]
	ui::label 18 14 Places
	set y 38
	foreach p [places] {
		lassign $p label icon path
		set on [expr {$path eq $::page::dir}]
		if {$on} { ui::box 8 $y 180 32 -fill $c(field) -radius 8 }
		ui::icon $icon 16 [expr {$on ? $c(accent) : $c(muted)}] 18 [expr {$y + 8}] 1.8
		set f [expr {$on ? "i13s" : "i13"}]
		ui::text 44 [ui::lh $y $f 32] $label $f $c(fg)
		ui::hit 8 $y 180 32 [list apply {{p x y} { page::go $p }} $path]
		incr y 34
	}
	ui::label 18 [expr {$y + 16}] Drives
	incr y [expr {16 + 14 + 4 + 2}]
	foreach d $::page::drives {
		lassign $d label path used size avail
		ui::icon drive 16 $c(muted) 18 [expr {$y + 6}] 1.8
		ui::text 44 [expr {$y + 6}] [ui::clip i13 $label 90] i13 $c(fg)
		ui::text 178 [ui::lh [expr {$y + 6}] i11 16] [human $avail] i11 $c(muted) e
		ui::box 44 [expr {$y + 28}] 134 3 -fill $c(field) -radius 1.5
		if {$size > 0} {
			ui::box 44 [expr {$y + 28}] [expr {max(3, round(134.0 * $used / $size))}] 3 -fill $c(muted) -radius 1.5
		}
		ui::hit 8 $y 180 37 [list apply {{p x y} { page::go $p }} $path]
		incr y 39
	}
}

proc page::toolbar {} {
	variable SW
	variable W
	variable TB
	array set c [array get ui::c]
	ui::hline $SW $W [expr {$TB - 1}] $c(border)
	set x [expr {$SW + 10}]
	ui::icon left 16 [expr {[llength $::page::back] ? $c(fg) : $c(muted)}] [expr {$x + 7}] 15 1.8
	ui::hit $x 8 30 30 {apply {{x y} { page::go_back }}}
	ui::icon right 16 [expr {[llength $::page::fwd] ? $c(fg) : $c(muted)}] [expr {$x + 39}] 15 1.8
	ui::hit [expr {$x + 32}] 8 30 30 {apply {{x y} { page::go_forward }}}
	set name [expr {$::page::dir eq "/" ? "/" : [tail $::page::dir]}]
	set nf [expr {[mode] in {save folder}}]
	ui::text [expr {$x + 74}] [ui::lh 0 sg15 $TB] [ui::clip sg15 $name [expr {$W - $x - 74 - 20 - ($nf ? 40 : 0)}]] sg15 $c(fg)
	# New folder: the button at the toolbar's right end (Save as, Choose a folder)
	if {$nf} {
		ui::icon folderplus 16 $c(muted) [expr {$W - 8 - 30 + 7}] 15 1.8
		ui::hit [expr {$W - 8 - 30}] 8 30 30 {apply {{x y} { page::new_folder }}}
	}
}

proc page::list_rows {} {
	variable SW
	variable W
	variable H
	variable FT
	variable LT
	variable RH
	variable items
	variable top
	array set c [array get ui::c]
	set x0 [expr {$SW + 10}]
	set rw [expr {$W - $SW - 20}]
	set R [expr {$x0 + $rw - 14}]      ;# the modified column's right edge
	# the column heads (Files' list view)
	set hy [expr {$::page::TB + 8}]
	ui::text [expr {$x0 + 42}] [expr {$hy + 10}] NAME i11s $c(muted) w 1.32
	ui::text [expr {$R - 354}] [expr {$hy + 10}] KIND i11s $c(muted) w 1.32
	ui::text [expr {$R - 142}] [expr {$hy + 10}] SIZE i11s $c(muted) e 1.32
	ui::text $R [expr {$hy + 10}] MODIFIED i11s $c(muted) e 1.32
	ui::hline $x0 [expr {$x0 + $rw}] [expr {$hy + 33}] $c(border)
	set bottom [expr {$H - $FT - [strip_h]}]
	if {![llength $items]} {
		ui::text [expr {$x0 + $rw / 2.0}] [expr {$LT + 28}] "This folder is empty" i13 $c(muted) c
	}
	set n [rows_shown]
	set top [expr {max(0, min($top, [llength $items] - $n))}]
	set y $LT
	for {set i $top} {$i < [llength $items] && $y + 38 <= $bottom} {incr i} {
		lassign [lindex $items $i] name isdir size mtime
		set on [expr {$name in $::page::sel}]
		if {$on} { ui::box $x0 $y $rw 38 -fill $c(field) -radius 8 }
		ui::icon [icon_of $name $isdir] 16 $c(muted) [expr {$x0 + 14}] [expr {$y + 11}] 1.7
		set f [expr {$on ? "i13s" : "i13"}]
		set ty [ui::lh $y i13 38]
		if {$name eq $::page::renaming} {
			rename_field [expr {$x0 + 34}] [expr {$y + 3}]
		} else {
			ui::text [expr {$x0 + 42}] $ty [ui::clip $f $name [expr {$R - 354 - 12 - $x0 - 42}]] $f $c(fg) w 0 {} 1
		}
		ui::text [expr {$R - 354}] $ty [kind $name $isdir] i13 $c(muted) w 0 {} 1
		if {!$isdir} { ui::text [expr {$R - 142}] $ty [human $size] i13 $c(fg) e 0 {} 1 }
		ui::text $R $ty [when $mtime] i13 $c(muted) e 0 {} 1
		ui::hit $x0 $y $rw 38 [list apply {{i x y} { page::click_row $i }} $i]
		incr y $RH
	}
	ui::wheel $SW $::page::TB [expr {$W - $SW}] [expr {$bottom - $::page::TB}] page::scroll
}

# ---- New folder (board Chooser-New-Folder) ------------------------------------------------

# The new folder's name field: STYLE §7's small field, 240 x 32, radius 8, 13/500, §bar inside the chosen row, the
# accent ring and caret; it edits as Appearance's fields do (ui::field_key).
proc page::rename_field {x y} {
	variable rbox
	array set c [array get ui::c]
	set w 240; set h 32
	set rbox [list $x $y $w $h]
	ui::box $x $y $w $h -fill $c(bar) -radius 8
	ui::ring $x $y $w $h 8 $c(accent) 1.5
	set tx [expr {$x + 8}]
	set val [ui::fval rename]
	set avail [expr {$w - 16 - 2}]
	set cur [expr {min($ui::fld(rename,cur), [string length $val])}]
	set start 0
	while {$start < $cur && [ui::measure i13m [string range $val $start [expr {$cur - 1}]]] > $avail} { incr start }
	set vis [string range $val $start end]
	while {$vis ne "" && [ui::measure i13m $vis] > $avail + 2} { set vis [string range $vis 0 end-1] }
	ui::text $tx [ui::lh $y i13m $h] $vis i13m $c(fg)
	if {$ui::focus eq "rename"} {
		ui::caret_at [expr {$tx + [ui::measure i13m [string range $val $start [expr {$cur - 1}]]] + 1}] [expr {$y + ($h - 16) / 2.0}]
	}
	ui::hit $x $y $w $h [list ui::field_click rename $tx i13m]
	ui::focusable rename field $x $y $w $h 8 [list "" page::rename_done 255]
}

# New folder: "New folder" (" 2", " 3" when taken) made in the folder shown, chosen and shown, its name in the field.
proc page::new_folder {} {
	variable dir
	if {[mode] ni {save folder} || $::page::ask ne ""} return
	rename_done
	set name "New folder"
	for {set n 2} {[file exists [child $dir $name]]} {incr n} { set name "New folder $n" }
	if {[catch {file mkdir [child $dir $name]}]} return
	read_dir
	select [list $name]
	reveal $name
	variable renaming $name
	ui::fset rename $name
	set ui::focus rename
	draw
}

# The name typed for the new folder: it is renamed to it (an empty name, ".", "..", one with a / or one that is
# taken keeps the name it has); the keys go back to the Name field in Save as.
proc page::rename_done {} {
	variable renaming
	variable dir
	if {$renaming eq ""} return
	set old $renaming
	set renaming ""
	set new [string trim [ui::fval rename]]
	if {$new ne "" && $new ne $old && $new ni {. ..} && [string first / $new] < 0 && ![file exists [child $dir $new]]} {
		if {![catch {file rename -- [child $dir $old] [child $dir $new]}]} { set old $new }
	}
	read_dir
	select [list $old]
	reveal $old
	set ui::focus [expr {[mode] eq "save" ? "name" : ""}]
	draw
}

proc page::rename_cancel {} {
	variable renaming
	if {$renaming eq ""} return
	ui::fset rename $renaming
	rename_done
}

# A press anywhere but in the name field ends the renaming (the name typed is kept).
proc page::press_commit {x y} {
	variable rbox
	if {$::page::renaming eq ""} return
	lassign $rbox rx ry rw rh
	if {$x >= $rx && $x < $rx + $rw && $y >= $ry && $y < $ry + $rh} return
	rename_done
}

# ---- the app's choices (board Chooser-Save-Choices) ---------------------------------------

# The strip's height: a 52 row for each line the choices take (none: 0).
proc page::strip_h {} {
	variable CH
	if {![llength $::page::choices]} { return 0 }
	return [expr {$CH * ([lindex [choice_layout] end] + 1)}]
}

# Where each choice goes: {id kind x line w} each, then the last line's number. A list is its label (13 §muted), 12,
# then a 180 dropdown; a checkbox is the 18 box, 10, its label; 24 between; a choice that does not fit starts a line.
proc page::choice_layout {} {
	variable SW
	variable W
	set out {}
	set x [expr {$SW + 20}]
	set line 0
	foreach ch $::page::choices {
		lassign $ch id label opts
		if {[llength $opts]} {
			set kind list
			set w [expr {[ui::measure i13 $label] + 12 + 180}]
		} else {
			set kind check
			set w [expr {18 + 10 + [ui::measure i13 $label]}]
		}
		if {$x > $SW + 20 && $x + $w > $W - 20} { incr line; set x [expr {$SW + 20}] }
		lappend out [list $id $kind $x $line $w]
		set x [expr {$x + $w + 24}]
	}
	lappend out $line
	return $out
}

proc page::choice_of {id} { lsearch -inline -exact -index 0 $::page::choices $id }

# The label of the option VALUE of list choice ID.
proc page::option_label {id value} {
	set o [lsearch -inline -exact -index 0 [lindex [choice_of $id] 2] $value]
	return [expr {$o eq "" ? $value : [lindex $o 1]}]
}

proc page::choices_strip {} {
	variable SW
	variable W
	variable H
	variable FT
	variable CH
	if {![llength $::page::choices]} return
	array set c [array get ui::c]
	set top [expr {$H - $FT - [strip_h]}]
	ui::hline $SW $W $top $c(border)
	foreach e [lrange [choice_layout] 0 end-1] {
		lassign $e id kind x line w
		set label [lindex [choice_of $id] 1]
		set y [expr {$top + $CH * $line}]
		if {$kind eq "list"} {
			set lw [ui::text $x [ui::lh $y i13 $CH] $label i13 $c(muted)]
			set dx [expr {$x + $lw + 12}]
			set dy [expr {$y + 10}]
			set open [expr {$::page::cpop eq $id}]
			ui::box $dx $dy 180 32 -fill $c(field) -radius 8
			if {$open} { ui::ring $dx $dy 180 32 8 $c(accent) 1.5 } else { ui::ring $dx $dy 180 32 8 $c(border) 1 }
			ui::text [expr {$dx + 12}] [ui::lh $dy i13 32] [ui::clip i13 [option_label $id $::page::cval($id)] 130] i13 $c(fg)
			ui::icon down 14 [expr {$open ? $c(fg) : $c(muted)}] [expr {$dx + 156}] [expr {$dy + 9}] 2
			ui::hit $dx $dy 180 32 [list apply {{id x y} { page::choice_pop $id }} $id]
			ui::focusable choice-$id dropdown $dx $dy 180 32 8 [list apply {{id sym} {
				if {$sym in {Return KP_Enter space Down}} { page::choice_pop $id; return 1 }
				return 0
			}} $id]
		} else {
			set on [expr {$::page::cval($id) eq "true"}]
			set by [expr {$y + 17}]
			# STYLE §9: on, §accent with a 12 px §ink check (stroke 3); off, §field with a 1.5 px §muted ring
			if {$on} {
				ui::box $x $by 18 18 -fill $c(accent) -radius 5
				ui::icon check 12 $c(ink) [expr {$x + 3}] [expr {$by + 3}] 3
			} else {
				ui::box $x $by 18 18 -fill $c(field) -radius 5
				ui::ring $x $by 18 18 5 $c(muted) 1.5
			}
			ui::text [expr {$x + 28}] [ui::lh $y i13 $CH] $label i13 $c(fg)
			ui::hit $x [expr {$y + 10}] $w 32 [list apply {{id x y} { page::choice_toggle $id }} $id]
			ui::focusable choice-$id button $x $by 18 18 5 [list page::choice_toggle $id]
		}
	}
}

proc page::choice_toggle {id} {
	variable cval
	set cval($id) [expr {$cval($id) eq "true" ? "false" : "true"}]
	draw
}

proc page::choice_pop {id} {
	variable cpop
	variable cpopidx
	if {$cpop eq $id} { set cpop ""; draw; return }
	set cpop $id
	set cpopidx [lsearch -exact -index 0 [lindex [choice_of $id] 2] $::page::cval($id)]
	if {$cpopidx < 0} { set cpopidx 0 }
	set ui::focus choice-pop
	draw
}

proc page::choice_pick {i {keys 0}} {
	variable cpop
	set id $cpop
	set ::page::cval($id) [lindex [choice_of $id] 2 $i 0]
	set cpop ""
	set ui::focus [expr {$keys ? "choice-$id" : ""}]
	draw
}

proc page::choice_pop_key {sym} {
	variable cpopidx
	set n [llength [lindex [choice_of $::page::cpop] 2]]
	switch -- $sym {
		Up { set cpopidx [expr {max(0, $cpopidx - 1)}] }
		Down { set cpopidx [expr {min($n - 1, $cpopidx + 1)}] }
		Return - KP_Enter - space { choice_pick $cpopidx 1; return 1 }
		Escape { set id $::page::cpop; set ::page::cpop ""; set ui::focus choice-$id; draw; return 1 }
		default { return 0 }
	}
	draw
	return 1
}

# A list choice's options over the strip: the file types' list (Settings' dropdown list), opening upwards from its
# dropdown, as wide.
proc page::choice_popup {} {
	variable H
	variable FT
	variable CH
	variable cpopidx
	array set c [array get ui::c]
	set id $::page::cpop
	set e [lsearch -inline -exact -index 0 [lrange [choice_layout] 0 end-1] $id]
	lassign $e - - x line
	set x [expr {$x + [ui::measure i13 [lindex [choice_of $id] 1]] + 12}]
	set opts [lindex [choice_of $id] 2]
	set w 180
	set h [expr {12 + 36 * [llength $opts]}]
	set top [expr {$H - $FT - [strip_h] + $CH * $line + 10 - 6 - $h}]
	ui::layer
	ui::hit 0 0 $::page::W $::page::H {apply {{x y} { set page::cpop ""; page::draw }}}
	ui::box $x $top $w $h -fill $c(bar) -radius 12 -ring [list $c(border) 1]
	set i 0
	foreach o $opts {
		lassign $o oid olabel
		set iy [expr {$top + 6 + 36 * $i}]
		if {$i == $cpopidx} { ui::box [expr {$x + 6}] $iy [expr {$w - 12}] 36 -fill $c(field) -radius 8 }
		set on [expr {$oid eq $::page::cval($id)}]
		set f [expr {$on ? "i13s" : "i13m"}]
		ui::text [expr {$x + 18}] [ui::lh $iy $f 36] [ui::clip $f $olabel 120] $f $c(fg)
		if {$on} { ui::icon check 14 $c(accent) [expr {$x + $w - 18 - 14}] [expr {$iy + 11}] 2.4 }
		ui::hit [expr {$x + 6}] $iy [expr {$w - 12}] 36 [list apply {{i x y} { page::choice_pick $i }} $i]
		incr i
	}
	ui::focusable choice-pop list $x $top $w $h 12 page::choice_pop_key
}

proc page::scroll {d} {
	variable top
	set top [expr {max(0, min($top + $d * 3, [llength $::page::items] - [rows_shown]))}]
	draw
}

proc page::footer {} {
	variable SW
	variable W
	variable H
	variable FT
	array set c [array get ui::c]
	set y [expr {$H - $FT}]
	ui::hline $SW $W $y $c(border)
	set x [expr {$SW + 20}]
	if {[mode] eq "save"} {
		set lw [ui::text $x [ui::lh $y i13 $FT] Name i13 $c(muted)]
		ui::field name [expr {$x + $lw + 12}] [expr {$y + 17}] 300 -onenter page::accept -onchange page::match_name -max 4096
	} elseif {[mode] eq "open" && [llength $::page::types] > 1} {
		set dy [expr {$y + 20}]
		set pop $::page::pop
		ui::box $x $dy 200 32 -fill $c(field) -radius 8
		if {$pop} { ui::ring $x $dy 200 32 8 $c(accent) 1.5 } else { ui::ring $x $dy 200 32 8 $c(border) 1 }
		ui::text [expr {$x + 12}] [ui::lh $dy i13 32] [ui::clip i13 [lindex $::page::types $::page::type 0] 150] i13 $c(fg)
		ui::icon down 14 [expr {$pop ? $c(fg) : $c(muted)}] [expr {$x + 176}] [expr {$dy + 9}] 2
		ui::hit $x $dy 200 32 {apply {{x y} { if {$::page::pop} { page::close_pop } else { page::open_pop } }}}
		ui::focusable types dropdown $x $dy 200 32 8 {apply {{sym} {
			if {$sym in {Return KP_Enter space Down}} { page::open_pop; return 1 }
			return 0
		}}}
	}
	set primary [dict get {open Open save Save folder Choose} [mode]]
	# a portal caller's own word for it ("_Upload": GTK's mnemonic mark taken out)
	if {$::page::o(-acceptlabel) ne ""} { set primary [string map {_ ""} $::page::o(-acceptlabel)] }
	set bx [expr {$W - 20}]
	set pw [ui::button_w $primary primary]
	set bx [expr {$bx - $pw}]
	set by [expr {$y + 17}]
	set cw [ui::button_w Cancel ghost]
	ui::button cancel [expr {$bx - 10 - $cw}] $by Cancel ghost page::cancel
	ui::button ok $bx $by $primary primary page::accept
}

# The file types' list, over the footer: Settings' dropdown list (page-power.tcl), opening upwards.
proc page::popup {} {
	variable SW
	variable H
	variable FT
	variable popidx
	array set c [array get ui::c]
	set x [expr {$SW + 20}]
	set w 200
	set n [llength $::page::types]
	set h [expr {12 + 36 * $n}]
	set top [expr {$H - $FT + 20 - 6 - $h}]
	ui::layer
	ui::hit 0 0 $::page::W $::page::H {apply {{x y} { page::close_pop }}}
	ui::box $x $top $w $h -fill $c(bar) -radius 12 -ring [list $c(border) 1]
	set i 0
	foreach t $::page::types {
		set iy [expr {$top + 6 + 36 * $i}]
		if {$i == $popidx} { ui::box [expr {$x + 6}] $iy [expr {$w - 12}] 36 -fill $c(field) -radius 8 }
		set on [expr {$i == $::page::type}]
		set f [expr {$on ? "i13s" : "i13m"}]
		ui::text [expr {$x + 18}] [ui::lh $iy $f 36] [ui::clip $f [lindex $t 0] 140] $f $c(fg)
		if {$on} { ui::icon check 14 $c(accent) [expr {$x + $w - 18 - 14}] [expr {$iy + 11}] 2.4 }
		ui::hit [expr {$x + 6}] $iy [expr {$w - 12}] 36 [list apply {{i x y} { page::pick_type $i }} $i]
		incr i
	}
	ui::focusable types-pop list $x $top $w $h 12 page::pop_key
}

# The header tile: 44 square, radius 12, a 160-degree gradient from §pill to §field, a 1 px §border ring (the
# welcome's and the password prompt's).
proc page::tile {x y icon} {
	array set c [array get ui::c]
	set g [raster::cached [list chooser-tile [ui::col $c(pill)] [ui::col $c(field)] [ui::col $c(border)]] {
		lassign [raster::rgb [ui::col $c(pill)]] r0 g0 b0
		lassign [raster::rgb [ui::col $c(field)]] r1 g1 b1
		lassign [raster::rgb [ui::col $c(border)]] rr rg rb
		set s 44; set r 12
		set dx 0.3420201433256687; set dy 0.9396926207859084
		set len [expr {$s * $dx + $s * $dy}]
		set out {}
		for {set j 0} {$j < $s} {incr j} {
			set row {}
			for {set i 0} {$i < $s} {incr i} {
				set px [expr {$i + 0.5}]; set py [expr {$j + 0.5}]
				set co [raster::rbox $px $py 0 0 $s $s $r]
				if {$co <= 0} { lappend row 0 0 0 0; continue }
				set t [expr {min(1.0, max(0.0, (($px - $s / 2.0) * $dx + ($py - $s / 2.0) * $dy) / $len + 0.5))}]
				set ci [raster::rbox $px $py 1 1 [expr {$s - 1}] [expr {$s - 1}] [expr {$r - 1}]]
				set k [expr {$co - $ci}]
				set fr [expr {$r0 + ($r1 - $r0) * $t}]; set fg [expr {$g0 + ($g1 - $g0) * $t}]; set fb [expr {$b0 + ($b1 - $b0) * $t}]
				lappend row [expr {int($rr * $k + $fr * (1 - $k) + 0.5)}] [expr {int($rg * $k + $fg * (1 - $k) + 0.5)}] \
					[expr {int($rb * $k + $fb * (1 - $k) + 0.5)}] [expr {int($co * 255 + 0.5)}]
			}
			lappend out $row
		}
		raster::png $s $s $out
	}]
	raster::blit $ui::img $g 0 0 44 44 $x $y
	ui::icon $icon 22 $c(fg) [expr {$x + 11}] [expr {$y + 11}] 1.7
}

# Replace "NAME"? (STYLE §15 dialog, 440 wide): the header, then the footer with Cancel and Replace.
proc page::question {} {
	variable W
	variable H
	array set c [array get ui::c]
	set dw 440; set dh 160
	set x [expr {($W - $dw) / 2}]; set y [expr {($H - $dh) / 2}]
	ui::hit 0 0 $W $H {apply {{x y} {}}}
	raster::box $ui::img $x $y $dw $dh -fill $c(bar) -radius 16 -ring [list $c(border) 1] -shadow {24 64 0.6}
	tile [expr {$x + 28}] [expr {$y + 26}] file
	set name [tail $::page::ask]
	ui::text [expr {$x + 86}] [ui::lh [expr {$y + 27}] sg20 23 1] [ui::clip sg20 "Replace “$name”?" 326] sg20 $c(fg) w -0.4
	set where [parent $::page::ask]
	set wname [expr {$where eq [file normalize [home]] ? "your home folder" : [tail $where]}]
	ui::text [expr {$x + 86}] [expr {$y + 53}] [ui::clip i13 "It is already in $wname" 326] i13 $c(muted)
	ui::hline $x [expr {$x + $dw}] [expr {$y + 88}] $c(border)
	set rw [ui::button_w Replace primary]
	set bx [expr {$x + $dw - 28 - $rw}]
	set cw [ui::button_w Cancel ghost]
	ui::button no [expr {$bx - 10 - $cw}] [expr {$y + 105}] Cancel ghost {page::replace 0}
	ui::button yes $bx [expr {$y + 105}] Replace primary {page::replace 1}
}

# Text cut to WIDTH with an ellipsis.
proc ui::clip {f str width} {
	if {[measure $f $str] <= $width} { return $str }
	while {$str ne "" && [measure $f "$str…"] > $width} { set str [string range $str 0 end-1] }
	return "$str…"
}

proc page::clicked_outside {} {}

# ---- keys ---------------------------------------------------------------------------

proc page::move {d {extend 0}} {
	variable items
	variable sel
	variable anchor
	if {![llength $items]} return
	set cur [expr {[llength $sel] ? [index_of [lindex $sel end]] : -1}]
	if {$d eq "home"} { set i 0 } elseif {$d eq "end"} { set i [expr {[llength $items] - 1}] } elseif {$cur < 0} {
		set i [expr {$d > 0 ? 0 : [llength $items] - 1}]
	} else { set i [expr {max(0, min([llength $items] - 1, $cur + $d))}] }
	set name [lindex $items $i 0]
	if {$extend && $::page::o(-multiple) && $anchor ne "" && [index_of $anchor] >= 0} {
		set a [index_of $anchor]
		set sel [lmap e [lrange $items [expr {min($a, $i)}] [expr {max($a, $i)}]] { lindex $e 0 }]
		lappend sel $name
		set sel [lsort -unique $sel]
		set sel [concat [lsearch -all -inline -not -exact $sel $name] [list $name]]
	} else {
		choose_index $i
		return
	}
	reveal $name
	draw
}

# Letters typed while the list has the keys choose the first name that starts with them.
proc page::type_ahead {char} {
	variable typed
	variable typedat
	set now [clock milliseconds]
	if {$now - $typedat > 1000} { set typed "" }
	set typedat $now
	append typed $char
	set i 0
	foreach e $::page::items {
		if {[string match -nocase "$typed*" [lindex $e 0]]} { choose_index $i; return }
		incr i
	}
}

# Row I alone chosen and shown (in Save as a file's name goes into the Name field).
proc page::choose_index {i} {
	lassign [lindex $::page::items $i] name isdir
	select [list $name]
	if {[mode] eq "save" && !$isdir} { ui::fset name $name }
	reveal $name
	draw
}

proc page::key {sym char state} {
	variable ask
	set f [ui::focused]
	set ctrl [expr {$state & 4}]
	set alt [expr {$state & 8}]
	if {$ask ne ""} {
		switch -- $sym {
			Escape { replace 0 }
			Return - KP_Enter { if {[lindex $f 0] eq "no"} { replace 0 } else { replace 1 } }
			Tab - ISO_Left_Tab { ui::cycle [expr {($state & 1) || $sym eq "ISO_Left_Tab" ? -1 : 1}]; draw }
			space { if {$f ne ""} { uplevel #0 [lindex $f 7] } }
		}
		return
	}
	if {$::page::renaming ne "" && $sym eq "Escape"} { rename_cancel; return }
	if {$ctrl && ($state & 1) && $sym in {n N}} { new_folder; return }
	if {$sym in {Tab ISO_Left_Tab}} { ui::cycle [expr {($state & 1) || $sym eq "ISO_Left_Tab" ? -1 : 1}]; draw; return }
	if {$f ne ""} {
		switch [lindex $f 1] {
			field { if {[ui::field_key [lindex $f 0] $sym $char $state]} { draw; return } }
			list - dropdown { if {[uplevel #0 [list {*}[lindex $f 7] $sym]]} return }
			button { if {$sym in {Return KP_Enter space}} { uplevel #0 [lindex $f 7]; return } }
		}
	}
	if {$alt} {
		switch -- $sym { Left { go_back } Right { go_forward } Up { go_up } }
		return
	}
	switch -- $sym {
		Escape { cancel }
		Up { move -1 [expr {$state & 1}] }
		Down { move 1 [expr {$state & 1}] }
		Prior { move [expr {-[rows_shown]}] }
		Next { move [rows_shown] }
		Home { move home }
		End { move end }
		BackSpace { go_up }
		Return - KP_Enter {
			set s $::page::sel
			if {[llength $s] == 1 && [index_of [lindex $s 0]] >= 0 && [lindex $::page::items [index_of [lindex $s 0]] 1] && [mode] ne "folder"} {
				activate [index_of [lindex $s 0]]
			} else { accept }
		}
		default {
			if {$ctrl && $sym in {h H}} { set ::page::hidden [expr {!$::page::hidden}]; read_dir; draw; return }
			if {$ctrl && $sym in {a A} && $::page::o(-multiple)} {
				set ::page::sel [lmap e $::page::items { if {[lindex $e 1]} continue; lindex $e 0 }]; draw; return
			}
			if {!$ctrl && $char ne "" && [string is print $char] && $char ne " "} { type_ahead $char }
		}
	}
}

# ---- the window ---------------------------------------------------------------------

proc page::args {argv} {
	variable o
	foreach {k v} $argv {
		if {![info exists o($k)]} { puts stderr "ribbon-chooser: unknown option $k"; exit 2 }
		set o($k) $v
	}
	if {$o(-mode) ni {open save folder}} { puts stderr "ribbon-chooser: -mode is open, save or folder"; exit 2 }
	# the app's choices: a list needs its default among its options (else its first); a checkbox is true or false
	variable choices {}
	variable cval
	foreach ch $o(-choices) {
		if {[catch {llength $ch} n] || $n != 4} continue
		lassign $ch id label opts def
		# (an id with a line break is left out: the answer is lines)
		if {$id eq "" || [string match "*\[\n\r\]*" $id] || [info exists cval($id)] || [catch {llength $opts}]} continue
		set opts [lmap op $opts {
			if {[catch {llength $op} n] || $n < 2 || [lindex $op 0] eq "" || [string match "*\[\n\r\]*" [lindex $op 0]]} continue
			lrange $op 0 1
		}]
		if {[llength $opts]} {
			if {[lsearch -exact -index 0 $opts $def] < 0} { set def [lindex $opts 0 0] }
		} else {
			set def [expr {$def eq "true" ? "true" : "false"}]
		}
		lappend choices [list $id $label $opts]
		set cval($id) $def
	}
	# the file types: {label patterns ?mac?}, "All files" added when they have none
	variable types {}
	foreach t $o(-filetypes) {
		lassign $t label pats
		if {$label eq ""} continue
		lappend types [list $label $pats]
	}
	if {[llength $types] && ![llength [lsearch -all -inline -regexp [lmap t $types { lindex $t 1 }] {^\*(\.\*)?$}]]} {
		lappend types [list "All files" *]
	}
	# the type in use first: the one named -initialtype (Tk's -typevariable, the portal's current_filter)
	variable type
	set i [lsearch -exact -index 0 $types $o(-initialtype)]
	if {$i >= 0} { set type $i }
}

proc page::main {} {
	variable W
	variable H
	global argv
	# the options after "--" (wish has taken its own, -name, before it; under tclsh they are still there)
	set a $argv
	set i [lsearch -exact $a --]
	if {$i >= 0} { set a [lrange $a [expr {$i + 1}] end] }
	if {[llength $a] == 1} { set a [lindex $a 0] }
	args $a
	set home [home]
	set cache [env XDG_CACHE_HOME [file join $home .cache]]
	theme::load
	array set p [array get theme::c]
	ui::colours [dict create BAR $p(BAR) FIELD $p(FIELD) PILL $p(PILL) BORDER $p(BORDER) FG $p(FG) MUTED $p(MUTED) \
		ACCENT $p(ACCENT) ON_ACCENT $p(ON_ACCENT) DESK_TOP $p(DESK_TOP) DESK_BOTTOM $p(DESK_BOTTOM) \
		DESK_STRIPE $p(DESK_STRIPE) DESK_STRIPE_ALPHA $p(DESK_STRIPE_ALPHA)]
	set ui::c(win) $p(WIN)
	raster::init [file join $cache ribbon chooser]
	ui::fonts
	set H [rbn::fit $H]
	set ui::W $W; set ui::H $H
	set ui::behind ""; set ui::bx 0; set ui::by 0
	wm withdraw .
	set win .w
	set title $page::o(-title)
	if {$title eq ""} { set title [dict get {open Open save {Save as} folder {Choose a folder}} [mode]] }
	if {[env RIBBON_CHOOSER_SCENE] eq "1"} {
		toplevel $win -class RibbonChooser -borderwidth 0 -highlightthickness 0 -background $ui::c(win)
		wm overrideredirect $win 1
		wm geometry $win ${W}x$H+[expr {(1440 - $W) / 2}]+[expr {(900 - $H) / 2}]
		canvas $win.c -width $W -height $H -highlightthickness 0 -borderwidth 0 -background $ui::c(win)
		place $win.c -x 0 -y 0
	} else {
		if {[rbn::appwindow $win RibbonChooser $W $H -fill $ui::c(win)]} { set ui::argbwin $win }
		wm title $win $title
		wm iconname $win $title
		wm resizable $win 0 0
		set SW [winfo screenwidth .]; set SH [winfo screenheight .]
		lassign [expr {[llength $page::o(-at)] == 4 ? $page::o(-at) : [list 0 0 $SW $SH]}] ax ay aw ah
		set x [expr {max(0, min($SW - $W, $ax + ($aw - $W) / 2))}]
		set y [expr {max(0, min($SH - $H, $ay + ($ah - $H) / 2))}]
		wm geometry $win ${W}x$H+$x+$y
		wm protocol $win WM_DELETE_WINDOW page::cancel
	}
	set ui::cv $win.c
	bind $win.c <ButtonPress-1> {set page::mods %s; page::press_commit %x %y; ui::press %x %y}
	bind $win.c <Double-Button-1> {page::double %x %y}
	bind $win.c <B1-Motion> {ui::motion %x %y}
	bind $win.c <ButtonRelease-1> {ui::release %x %y}
	bind $win.c <Button-4> {ui::scroll %x %y -1}
	bind $win.c <Button-5> {ui::scroll %x %y 1}
	bind $win.c <MouseWheel> {ui::scroll %x %y [expr {%D > 0 ? -1 : 1}]}
	bind $win <KeyPress> {page::key %K %A %s}
	read_drives
	# where it starts: the folder asked for (or the one -initialfile names), else the home folder
	set start $page::o(-initialdir)
	set f $page::o(-initialfile)
	if {[string index $f 0] eq "/" && $start eq ""} { set start [parent $f] }
	if {$start eq "" || ![file isdirectory $start]} { set start $home }
	if {![go $start 0]} { go $home 0 }
	if {[mode] eq "save"} {
		ui::fset name [tail $f]
		set ui::focus name
		match_name
	}
	ui::blink
	draw
	focus -force $win
	if {[env RIBBON_CHOOSER_TEST] ne ""} {
		after 300 [list uplevel #0 [list source -encoding utf-8 $::env(RIBBON_CHOOSER_TEST)]]
	}
}

# A double-click on a row opens a folder or chooses a file.
proc page::double {x y} {
	variable LT
	variable RH
	set x [expr {$x - $ui::ox}]; set y [expr {$y - $ui::oy}]
	if {$::page::ask ne "" || $::page::pop} return
	if {$x < $::page::SW + 10 || $x >= $::page::W - 10 || $y < $LT || $y >= $::page::H - $::page::FT} return
	set k [expr {int(($y - $LT) / $RH)}]
	if {($y - $LT) - $k * $RH >= 38} return
	set i [expr {$::page::top + $k}]
	if {$i < [llength $::page::items]} { activate $i }
}

page::main
