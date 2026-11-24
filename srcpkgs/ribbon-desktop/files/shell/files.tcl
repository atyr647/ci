# files.tcl - Ribbon Files, the file manager, inside the Ribbon shell.
#
# It has no path bar of its own: the field in the top bar is its address
# bar, both ways. The field shows the folder of the window you're in, and
# typing a path or searching there moves that window. Being part of the
# shell's process, that needs no messages passed around and costs no extra
# memory for a second Tcl/Tk.
#
# The window follows the Ribbon mockup: toolbar (back, forward, grid/list),
# sidebar (places, drives with usage), icon grid or list, status bar.

namespace eval files {
	variable n 0           ;# window counter
	variable st            ;# per-window state: st($w,key)
	variable current ""    ;# the Files window used last (the field follows it)
	variable clip {}       ;# {copy|cut path...}
	variable ops {}        ;# queued file operations: {w verb name cmd dst src done}
	variable opch ""       ;# the running one's pipe
	variable opcur {}      ;# the running operation
	variable opout ""      ;# its output so far
	variable oplines ""    ;# its lines that are not progress
	variable pending {}    ;# destination names queued and not yet made
	variable fsw ""        ;# ribbon-fswatch's pipe
	variable fswpaths {}   ;# folders asked of ribbon-fswatch
	variable fswlive {}    ;# folders it has confirmed watching
	variable fswfailed 0   ;# no watcher here: the windows poll
	variable menuhits {}
	variable here [file dirname [file normalize [info script]]]
	array set st {}
}

proc files::home {} { return $::env(HOME) }

# XDG user folders (Downloads, Pictures, ...), localised names included.
proc files::userdir {key fallback} {
	set f [file join [expr {[info exists ::env(XDG_CONFIG_HOME)] ? $::env(XDG_CONFIG_HOME) : "[home]/.config"}] user-dirs.dirs]
	if {![catch {open $f} fh]} {
		set t [read $fh]; close $fh
		if {[regexp -line "^XDG_${key}_DIR=\"(.*)\"" $t -> p]} { return [string map [list \$HOME [home]] $p] }
	}
	return [file join [home] $fallback]
}

proc files::trashdir {} {
	set d [expr {[info exists ::env(XDG_DATA_HOME)] ? $::env(XDG_DATA_HOME) : "[home]/.local/share"}]/Trash
	file mkdir $d/files $d/info
	return $d
}

proc files::places {} {
	list [list Home home [home]] \
		[list Downloads download [userdir DOWNLOAD Downloads]] \
		[list Pictures image [userdir PICTURES Pictures]] \
		[list Documents doc [userdir DOCUMENTS Documents]] \
		[list Music music [userdir MUSIC Music]] \
		[list Trash trash [trashdir]/files]
}

# The DRIVES rows (files::drives) and the free space under the status bar
# come from shell/files-drives.tcl: UDisks2 and df, both read off the draw
# path. The trash (move, restore, empty, the per-drive trash folders) is
# shell/files-trash.tcl.

proc files::human {b} {
	foreach {u n} {TB 1e12 GB 1e9 MB 1e6 KB 1e3} {
		if {$b >= $n} { return [regsub {\.0 } [format "%.1f %s" [expr {$b / $n}] $u] { }] }
	}
	return "$b B"
}

# The line icon for a file, by name.
proc files::kindicon {name isdir} {
	if {$isdir} { return folder }
	switch -glob -nocase -- $name {
		*.png - *.jpg - *.jpeg - *.webp - *.gif - *.svg - *.bmp - *.avif - *.heic { return image }
		*.mp3 - *.flac - *.ogg - *.opus - *.wav - *.m4a - *.aac { return music }
		*.mp4 - *.mkv - *.webm - *.mov - *.avi { return film }
		*.iso - *.img { return disc }
		*.exe - *.msi - *.deb - *.rpm - *.xbps - *.appimage - *.AppImage - *.flatpakref { return pkg }
		*.zip - *.tar - *.gz - *.xz - *.zst - *.7z - *.rar - *.bz2 { return archive }
		*.c - *.h - *.py - *.sh - *.tcl - *.rs - *.js - *.ts - *.go - *.lua - *.json - *.toml - *.yaml - *.yml { return code }
		default { return file }
	}
}

# ---- windows -------------------------------------------------------------

proc files::show {{path ""}} {
	variable n
	variable st
	if {$path eq ""} { set path [home] }
	set path [file normalize [apps::expand $path]]
	set select ""
	if {[file isfile $path]} { set select [file tail $path]; set path [file dirname $path] }
	if {![file isdirectory $path]} { set path [home] }
	array set c [array get theme::c]
	set w .files[incr n]
	toplevel $w -class RibbonFiles -background $c(WIN)
	wm geometry $w 840x580
	wm minsize $w 520 340
	wm protocol $w WM_DELETE_WINDOW [list files::close_window $w]
	foreach k {back fwd sel} { set st($w,$k) {} }
	set st($w,view) grid
	set st($w,hidden) 0
	set st($w,anchor) ""
	set st($w,typed) ""
	set st($w,status) ""
	set st($w,insp) 0
	set st($w,live) 0
	set st($w,pollid) ""
	set st($w,dirty) ""
	files::modules
	files::looks
	canvas $w.tb -height 46 -highlightthickness 0 -borderwidth 0 -background $c(WIN)
	canvas $w.side -width 196 -highlightthickness 0 -borderwidth 0 -background $c(BAR)
	canvas $w.main -highlightthickness 0 -borderwidth 0 -background $c(WIN) -yscrollincrement 1
	canvas $w.status -height 30 -highlightthickness 0 -borderwidth 0 -background $c(BAR)
	pack $w.tb -side top -fill x
	pack $w.status -side bottom -fill x
	pack $w.side -side left -fill y
	pack $w.main -side left -fill both -expand 1
	# the Inspector panel (insp_toggle packs it before the list)
	canvas $w.insp -width 380 -highlightthickness 0 -borderwidth 0 -background $c(BAR)
	bind $w.insp <ButtonPress-1> {ui::press %x %y}
	bind $w.insp <Motion> {page::menu_motion %x %y}
	bind $w.insp <B1-Motion> {ui::motion %x %y}
	bind $w.insp <ButtonRelease-1> {ui::release %x %y}
	bind $w.insp <Button-4> {ui::scroll %x %y -1}
	bind $w.insp <Button-5> {ui::scroll %x %y 1}
	bind $w.insp <MouseWheel> {ui::scroll %x %y [expr {%D > 0 ? -1 : 1}]}
	bind $w.main <Configure> [list files::layout $w]
	bind $w.tb <Configure> [list files::toolbar $w]
	bind $w.status <Configure> [list files::statusbar $w]
	bind $w.side <Configure> [list files::sidebar $w]
	bind $w.main <Button-1> [list files::click $w %x %y %s]
	bind $w.main <Double-Button-1> [list files::dclick $w %x %y]
	bind $w.main <Button-3> [list files::context $w %x %y %X %Y]
	bind $w.main <Button-4> [list files::scroll $w -60]
	bind $w.main <Button-5> [list files::scroll $w 60]
	bind $w.tb <Button-1> [list files::tbclick $w %x %y]
	bind $w.side <Button-1> [list files::sideclick $w %x %y]
	bind $w <KeyPress> [list files::key $w %K %A %s]
	bind $w <FocusIn> [list files::focused $w]
	dnd_setup $w
	go $w $path 0
	if {$select ne ""} { set st($w,sel) [list $select]; set st($w,anchor) $select; draw $w; reveal $w $select }
	focus $w
	poll $w
	return $w
}

# What Files draws with beyond the shell's own: the title's font, the panel and Documents icons.
proc files::looks {} {
	foreach {f fam px} {f15g {Ribbon Space Grotesk 600} 15 f14 {Ribbon Inter 400} 14 f14s {Ribbon Inter 600} 14} {
		if {![info exists text::spec($f)]} { text::font $f $fam $px }
	}
	foreach {k d} {panel {M3 4h18v16H3z M15 4v16} doc {M4 3h16v18H4z M8 7h8 M8 11h8 M8 15h5}} {
		if {![info exists ::theme::icon($k)]} { set ::theme::icon($k) $d }
	}
}

proc files::close_window {w} {
	variable st
	variable current
	foreach k {pollid dirty} { if {[info exists st($w,$k)] && $st($w,$k) ne ""} { catch {after cancel $st($w,$k)} } }
	destroy $w
	array unset st $w,*
	if {$current eq $w} { set current "" }
	watch_sync
	if {$::files::standalone && ![llength [windows]]} { exit }
}

# The Files windows (not the menu, dialogs and drag chip, which are .files* too).
proc files::windows {} {
	lmap w [lsearch -all -inline [winfo children .] .files*] { if {[winfo class $w] ne "RibbonFiles"} continue; set w }
}

# The field follows the Files window you were in last.
proc files::focused {w} {
	variable current
	if {$current ne $w} { set current $w; after idle shell::refresh }
}

proc files::path {{w ""}} {
	variable st
	variable current
	if {$w eq ""} { set w $current }
	if {$w eq "" || ![info exists st($w,path)]} { return "" }
	return $st($w,path)
}

# Re-read a folder when it changes. This is the fallback: a window whose
# folder ribbon-fswatch confirms as watched doesn't come here (see watch_sync).
proc files::poll {w} {
	variable st
	if {![winfo exists $w]} return
	set st($w,pollid) ""
	if {$st($w,live)} return
	if {[winfo ismapped $w] && ![catch {file mtime $st($w,path)} m] && $m != $st($w,mtime)} { load $w; draw $w }
	set st($w,pollid) [after 1500 [list files::poll $w]]
}

# ---- navigation ------------------------------------------------------------

proc files::go {w path {history 1}} {
	variable st
	set path [file normalize [apps::expand $path]]
	if {![file isdirectory $path]} return
	if {$history && [info exists st($w,path)] && $st($w,path) ne $path} {
		lappend st($w,back) $st($w,path); set st($w,fwd) {}
	}
	set st($w,path) $path
	set st($w,sel) {}; set st($w,anchor) ""
	$w.main yview moveto 0
	wm title $w [expr {$path eq "/" ? "/" : [file tail $path]}]
	clear_parts $path
	load $w
	draw $w
	watch_sync
	after idle shell::refresh
}

proc files::back {w} {
	variable st
	if {![llength $st($w,back)]} return
	lappend st($w,fwd) $st($w,path)
	set p [lindex $st($w,back) end]; set st($w,back) [lrange $st($w,back) 0 end-1]
	go $w $p 0
}

proc files::forward {w} {
	variable st
	if {![llength $st($w,fwd)]} return
	lappend st($w,back) $st($w,path)
	set p [lindex $st($w,fwd) end]; set st($w,fwd) [lrange $st($w,fwd) 0 end-1]
	go $w $p 0
}

proc files::up {w} {
	variable st
	set p [file dirname $st($w,path)]
	if {$p ne $st($w,path)} { set old [file tail $st($w,path)]; go $w $p; set st($w,sel) [list $old]; set st($w,anchor) $old; draw $w; reveal $w $old }
}

# Folder contents: {name isdir size mtime}, folders first, natural order.
proc files::load {w} {
	variable st
	set dir $st($w,path)
	set st($w,mtime) [expr {[catch {file mtime $dir} m] ? 0 : $m}]
	set items {}
	set st($w,real) {}
	if {[trash_view $dir]} {
		# the Trash shows every trash folder: the home one and each drive's (files-trash.tcl)
		set named [trash_items $st($w,hidden)]
		foreach {name p} $named { if {[file dirname $p] ne $dir} { dict set st($w,real) $name $p } }
	} else {
		set named {}
		set paths [glob -nocomplain -directory $dir *]
		if {$st($w,hidden)} { lappend paths {*}[glob -nocomplain -directory $dir -types hidden *] }
		foreach p $paths {
			set name [file tail $p]
			if {$name ni {. ..}} { lappend named $name $p }
		}
	}
	foreach {name p} $named {
		if {[catch {file stat $p s}]} { set s(size) 0; set s(mtime) 0 }
		lappend items [list $name [file isdirectory $p] $s(size) $s(mtime)]
	}
	set dirs [lsort -dictionary -index 0 [lsearch -all -inline -index 1 $items 1]]
	set fls [lsort -dictionary -index 0 [lsearch -all -inline -index 1 $items 0]]
	set st($w,items) [concat $dirs $fls]
}

# ---- drawing -------------------------------------------------------------

proc files::draw {w} {
	toolbar $w
	sidebar $w
	layout $w
	statusbar $w
}

# The toolbar (FileProps boards, Files-List): back, forward, the folder's name; grid, list,
# a rule, the panel.
proc files::toolbar {w} {
	variable st
	array set c [array get theme::c]
	set t $w.tb
	$t delete all
	set W [winfo width $t]; if {$W < 2} { set W 840 }
	$t create line 0 45.5 $W 45.5 -fill $c(BORDER)
	bar::icon $t left 16 1.8 [expr {[llength $st($w,back)] ? $c(FG) : $c(MUTED)}] 17 15
	bar::icon $t right 16 1.8 [expr {[llength $st($w,fwd)] ? $c(FG) : $c(MUTED)}] 49 15
	set title [expr {[trash_view $st($w,path)] ? "Trash" : [file tail $st($w,path)]}]
	if {$title eq ""} { set title [file nativename $st($w,path)] }
	text::draw $t 82 23 f15g $c(FG) [bar::clip f15g $title [expr {$W - 82 - 130}]] w
	lassign [tbx $W] gx lx sx px
	foreach {x on icon} [list $gx [expr {$st($w,view) eq "grid"}] grid $lx [expr {$st($w,view) eq "list"}] list $px $st($w,insp) panel] {
		if {$on} { rbn::box $t $x 8 30 30 -fill $c(FIELD) -radius 8 -on $c(WIN) }
		bar::icon $t $icon 16 1.8 [expr {$on ? $c(FG) : $c(MUTED)}] [expr {$x + 7}] 15
	}
	$t create rectangle $sx 15 [expr {$sx + 1}] 31 -fill $c(BORDER) -width 0
}

# The toolbar's right-hand buttons: grid, list, the rule, the panel (x of each).
proc files::tbx {W} { list [expr {$W - 117}] [expr {$W - 85}] [expr {$W - 47}] [expr {$W - 38}] }

proc files::tbclick {w x y} {
	variable st
	set W [winfo width $w.tb]
	if {$y < 8 || $y > 38} return
	lassign [tbx $W] gx lx sx px
	if {$x >= 10 && $x < 40} { back $w } elseif {$x >= 42 && $x < 72} { forward $w } \
	elseif {$x >= $gx && $x < $gx + 30} { set st($w,view) grid; draw $w } \
	elseif {$x >= $lx && $x < $lx + 30} { set st($w,view) list; draw $w } \
	elseif {$x >= $px && $x < $px + 30} { insp_toggle $w }
}

proc files::sidebar {w} {
	variable st
	array set c [array get theme::c]
	set s $w.side
	$s delete all
	set H [winfo height $s]; if {$H < 2} { set H 504 }
	$s create line 195.5 0 195.5 $H -fill $c(BORDER)
	set st($w,sidehits) {}
	set y 14
	bar::spaced $s 18 [expr {round($y + 6.66)}] f11s $c(MUTED) PLACES 0.88
	set y [expr {$y + 13.31 + 6 + 2}]
	# the place the folder is in: the deepest one that holds it (~/Pictures for ~/Pictures/Iceland)
	set here $st($w,path)
	set cur ""; set best -1
	foreach p [places] {
		set pp [file normalize [lindex $p 2]]
		if {($here eq $pp || [string first $pp/ $here/] == 0) && [string length $pp] > $best} { set cur $pp; set best [string length $pp] }
	}
	foreach p [places] {
		lassign $p label icon path
		set on [expr {$cur eq [file normalize $path]}]
		# the place you are in: the field's colour, its icon in the accent (FileProps boards)
		if {$on} { rbn::box $s 8 [expr {round($y)}] 180 32 -fill $c(FIELD) -radius 8 -on $c(BAR) }
		bar::icon $s $icon 16 1.8 [expr {$on ? $c(ACCENT) : $c(MUTED)}] 18 [expr {$y + 8}]
		text::draw $s 44 [expr {round($y + 16)}] [expr {$on ? "f13s" : "f13"}] $c(FG) $label w
		lappend st($w,sidehits) [list [expr {round($y)}] [expr {round($y + 32)}] [list go $w $path]]
		set y [expr {$y + 34}]
	}
	bar::spaced $s 18 [expr {round($y + 16 + 6.66)}] f11s $c(MUTED) DRIVES 0.88
	set y [expr {$y + 16 + 13.31 + 6 + 2}]
	foreach d [drives] {
		lassign $d label path used size obj
		set top [expr {$y + 7}]
		bar::icon $s drive 16 1.8 $c(MUTED) 18 [expr {$top}]
		text::draw $s 44 [expr {round($top + 8)}] f13 $c(FG) $label w
		# the usage bar once df has answered; a drive that is not mounted has none
		if {$size ne "" && $size > 0} {
			set by [expr {round($top + 15.73 + 6)}]
			rbn::box $s 44 $by 134 3 -fill $c(FIELD) -radius 1.5 -on $c(BAR)
			set fw [expr {max(3, round(134.0 * $used / $size))}]
			rbn::box $s 44 $by $fw 3 -fill $c(ACCENT) -radius 1.5 -on ""
		}
		# a click opens a mounted drive, and mounts one that is not (UDisks2)
		set cmd [expr {$path ne "" ? [list go $w $path] : [list drive_mount $w $obj $label]}]
		lappend st($w,sidehits) [list [expr {round($y)}] [expr {round($y + 38.73)}] $cmd]
		set y [expr {$y + 38.73 + 2}]
	}
}

proc files::sideclick {w x y} {
	variable st
	foreach h $st($w,sidehits) {
		lassign $h y0 y1 cmd
		if {$y >= $y0 && $y < $y1 && $x >= 8 && $x < 188} { {*}$cmd; return }
	}
}

# Place the items (Files-Grid-Thumbs, Files-List): a grid of tiles 108 high, at least 104
# wide and sharing the width, or the list's NAME, KIND, SIZE and MODIFIED.
proc files::layout {w} {
	variable st
	array set c [array get theme::c]
	insp_draw $w
	set m $w.main
	$m delete all
	set W [winfo width $m]; if {$W < 2} { set W 644 }
	set st($w,tiles) {}
	set items $st($w,items)
	if {![llength $items]} {
		text::draw $m [expr {$W / 2}] 120 f13 $c(MUTED) [expr {[trash_view $st($w,path)] ? "Trash is empty" : "This folder is empty"}] center
		$m configure -scrollregion [list 0 0 $W 200]
		return
	}
	set soft [bar::mix $c(WIN) $c(ACCENT) 0.16]
	set soft2 [bar::mix $c(WIN) $c(ACCENT) 0.32]
	if {$st($w,view) eq "grid"} {
		set cols [expr {max(1, ($W - 32 + 6) / 110)}]
		set tw [expr {max(104, ($W - 32 - ($cols - 1) * 6) / $cols)}]
		set pw [expr {$tw - 34}]; set ph [expr {round($pw * 0.66)}]; set ah [expr {$ph + 8}]
		set isz [expr {round($ph * 0.82)}]
		set i 0
		foreach it $items {
			lassign $it name isdir
			set x [expr {16 + ($i % $cols) * ($tw + 6)}]; set y [expr {16 + ($i / $cols) * 114}]
			set sel [expr {$name in $st($w,sel)}]
			if {$sel} { rbn::box $m $x $y $tw 108 -fill $soft -radius 10 -ring [list $soft2 1.5] -on $c(WIN) }
			set cx [expr {$x + $tw / 2.0}]
			set img ""
			if {!$isdir && [thumbable $name]} { set img [thumb [itempath $w $name] $pw $ph] }
			if {$img ne ""} {
				$m create image [expr {round($cx - $pw / 2.0)}] [expr {$y + 14}] -image $img -anchor nw
			} else {
				set ic [kindicon $name $isdir]
				$m create image [expr {round($cx - $isz / 2.0)}] [expr {round($y + 10 + ($ah - $isz) / 2.0)}] -image [theme::icon $ic $isz 1.2 $c(MUTED)] -anchor nw
			}
			set f [expr {$sel ? "f12s" : "f12"}]
			text::draw $m $cx [expr {$y + 10 + $ah + 10 + 7.5}] $f $c(FG) [ellipsis $f $name [expr {$tw - 16}]] center
			lappend st($w,tiles) [list $x $y [expr {$x + $tw}] [expr {$y + 108}] $name]
			incr i
		}
		set rows [expr {($i + $cols - 1) / $cols}]
		$m configure -scrollregion [list 0 0 $W [expr {32 + $rows * 114}]]
		set st($w,cols) $cols
	} else {
		# the head: 34 high, 8 from the top, its rule; columns as the board's (gap 12, from the right
		# edge 24: MODIFIED 130, SIZE 80, KIND 120)
		set kx [expr {$W - 378}]; set sx [expr {$W - 166}]; set dx [expr {$W - 24}]
		$m create line 10 41.5 [expr {$W - 10}] 41.5 -fill $c(BORDER)
		foreach {x t a} [list 52 NAME w $kx KIND w $sx SIZE e $dx MODIFIED e] {
			text::draw $m $x 25 f11s $c(MUTED) $t $a -ls 1.32
		}
		set y 48
		foreach it $items {
			lassign $it name isdir size mtime
			set sel [expr {$name in $st($w,sel)}]
			if {$sel} { rbn::box $m 10 $y [expr {$W - 20}] 38 -fill $soft -radius 8 -ring [list $soft2 1.5] -on $c(WIN) }
			bar::icon $m [kindicon $name $isdir] 16 1.7 $c(MUTED) 24 [expr {$y + 11}]
			set f [expr {$sel ? "f13s" : "f13"}]
			text::draw $m 52 [expr {$y + 19}] $f $c(FG) [ellipsis $f $name [expr {$kx - 12 - 52}]] w
			text::draw $m $kx [expr {$y + 19}] f13 $c(MUTED) [ellipsis f13 [kindname $name $isdir] 120] w
			if {$isdir} {
				set n [count [itempath $w $name]]
				set sz [expr {$n eq "" ? "" : [items $n]}]
			} else { set sz [human $size] }
			text::draw $m $sx [expr {$y + 19}] f13 $c(FG) $sz e -tnum 1
			text::draw $m $dx [expr {$y + 19}] f13 $c(MUTED) [when $mtime] e -tnum 1
			lappend st($w,tiles) [list 10 $y [expr {$W - 10}] [expr {$y + 38}] $name]
			incr y 40
		}
		$m configure -scrollregion [list 0 0 $W [expr {$y + 8}]]
		set st($w,cols) 1
	}
}

# TEXT cut to WIDTH with "…", as the boards' text-overflow: ellipsis.
proc files::ellipsis {font text width} {
	if {[text::width $font $text] <= $width} { return $text }
	return "[string trimright [text::clip $font $text [expr {$width - [text::width $font …]}]]]…"
}

proc files::statusbar {w} {
	variable st
	array set c [array get theme::c]
	set s $w.status
	$s delete all
	set W [winfo width $s]; if {$W < 2} { set W 840 }
	$s create line 0 0.5 $W 0.5 -fill $c(BORDER)
	# a file operation's word stands in for the counts while it lasts
	set left [expr {$st($w,status) ne "" ? $st($w,status) : [selline $st($w,items) $st($w,sel)]}]
	text::draw $s 14 15 f12 $c(MUTED) [bar::clip f12 $left [expr {$W / 2 + 120}]] w -tnum 1
	# the drive this folder is on, and its free space (df runs in the background; drawn when it has answered)
	set free [free_space $st($w,path)]
	if {[llength $free]} {
		lassign $free avail target
		set label [expr {$target eq "/" ? "System" : [string totitle [file tail $target]]}]
		text::draw $s [expr {$W - 14}] 15 f12 $c(MUTED) "$label · [human $avail] free" e
	}
}

proc files::scroll {w d} { $w.main yview scroll $d units }

proc files::reveal {w name} {
	variable st
	foreach t $st($w,tiles) {
		if {[lindex $t 4] eq $name} {
			lassign [$w.main cget -scrollregion] - - - total
			set H [winfo height $w.main]
			set top [$w.main canvasy 0]
			if {[lindex $t 1] < $top || [lindex $t 3] > $top + $H} {
				$w.main yview moveto [expr {max(0.0, ([lindex $t 1] - 16.0) / $total)}]
			}
			return
		}
	}
}

# ---- selection and opening -------------------------------------------------

proc files::at {w x y} {
	variable st
	set y [$w.main canvasy $y]
	foreach t $st($w,tiles) {
		lassign $t x0 y0 x1 y1 name
		if {$x >= $x0 && $x < $x1 && $y >= $y0 && $y < $y1} { return $name }
	}
	return ""
}

proc files::click {w x y state} {
	variable st
	variable press
	focus $w
	set name [at $w $x $y]
	set press [list $w $x $y $name]
	# pressing on a selected item keeps the selection (it may be dragged)
	if {$name ne "" && $name in $st($w,sel) && !($state & 5)} return
	if {$name eq ""} { set st($w,sel) {}; set st($w,anchor) ""
	} elseif {$state & 4} {
		if {$name in $st($w,sel)} { set st($w,sel) [lsearch -all -inline -not -exact $st($w,sel) $name] } else { lappend st($w,sel) $name }
		set st($w,anchor) $name
	} elseif {($state & 1) && $st($w,anchor) ne ""} {
		set names [lmap it $st($w,items) {lindex $it 0}]
		set a [lsearch -exact $names $st($w,anchor)]; set b [lsearch -exact $names $name]
		set st($w,sel) [lrange $names [expr {min($a, $b)}] [expr {max($a, $b)}]]
	} else { set st($w,sel) [list $name]; set st($w,anchor) $name }
	layout $w; statusbar $w
}

proc files::dclick {w x y} {
	set name [at $w $x $y]
	if {$name ne ""} { activate $w $name }
}

proc files::activate {w name} {
	variable st
	set p [itempath $w $name]
	if {[file isdirectory $p]} { go $w $p } elseif {[string match -nocase *.kit $p]} {
		# a kit runs (K4: kit run, terminal and double-click alike)
		apps::run "kit run [apps::shellquote $p]"
	} elseif {![open_with $p] && ![open_default $p]} {
		apps::run "xdg-open [apps::shellquote $p]"
	}
}

proc files::selpaths {w} {
	variable st
	lmap n $st($w,sel) { itempath $w $n }
}

# Where an item the window lists is: in its folder, or (in the Trash) in another drive's trash folder.
proc files::itempath {w name} {
	variable st
	if {[info exists st($w,real)] && [dict exists $st($w,real) $name]} { return [dict get $st($w,real) $name] }
	file join $st($w,path) $name
}

proc files::key {w sym char state} {
	variable st
	if {[focus] ne "" && [winfo class [focus]] eq "Entry"} return
	# the panel's edit view takes the keys: its name field types, Enter applies, Esc leaves the view
	if {[modules] && ([dict size $::page::menu] || $::inspector::edit) && [files::insp_keys $w $sym $char $state]} return
	set ctrl [expr {$state & 4}]; set alt [expr {$state & 8}]; set shift [expr {$state & 1}]
	set names [lmap it $st($w,items) {lindex $it 0}]
	set cur [expr {$st($w,anchor) eq "" ? -1 : [lsearch -exact $names $st($w,anchor)]}]
	set move ""
	switch -- $sym {
		Left { if {$alt} { back $w; return }; set move -1 }
		Right { if {$alt} { forward $w; return }; set move 1 }
		Up { if {$alt} { up $w; return }; set move [expr {-$st($w,cols)}] }
		Down { set move $st($w,cols) }
		Home { set move [expr {-$cur}] }
		End { set move [expr {[llength $names] - 1 - $cur}] }
		Return - KP_Enter {
			if {$alt} {
				props $w
				return
			}
			foreach n $st($w,sel) {
				if {($state & 4) && [file isdirectory [itempath $w $n]]} { show [itempath $w $n] } else { activate $w $n }
			}
			return
		}
		BackSpace { up $w; return }
		Delete { if {$shift} { delete_forever $w } else { trash $w }; return }
		F2 { rename_start $w; return }
		F5 { load $w; draw $w; return }
		F6 { launcher::address; return }
		Escape { set st($w,sel) {}; layout $w; statusbar $w; return }
	}
	if {$ctrl} {
		switch -- [string tolower $sym] {
			a { set st($w,sel) $names; layout $w; statusbar $w }
			c { set_clip copy [selpaths $w] }
			x { set_clip cut [selpaths $w] }
			v { paste $w }
			h { set st($w,hidden) [expr {!$st($w,hidden)}]; load $w; draw $w }
			l - f { launcher::address }
			n { if {$shift} { newfolder $w } else { show $st($w,path) } }
			w { close_window $w }
			1 { set st($w,view) grid; draw $w }
			2 { set st($w,view) list; draw $w }
		}
		return
	}
	if {$move ne "" && [llength $names]} {
		set i [expr {max(0, min([llength $names] - 1, $cur < 0 ? 0 : $cur + $move))}]
		set st($w,anchor) [lindex $names $i]
		set st($w,sel) [list $st($w,anchor)]
		layout $w; statusbar $w; reveal $w $st($w,anchor)
		return
	}
	# type to jump to a name
	if {$char ne "" && [string is print $char] && !$alt} {
		append st($w,typed) [string tolower $char]
		catch {after cancel $st($w,typedtimer)}
		set st($w,typedtimer) [after 900 [list set ::files::st($w,typed) ""]]
		foreach n $names {
			if {[string first $st($w,typed) [string tolower $n]] == 0} {
				set st($w,sel) [list $n]; set st($w,anchor) $n; layout $w; statusbar $w; reveal $w $n; break
			}
		}
	}
}

# ---- file operations -----------------------------------------------------

proc files::set_clip {op paths} {
	variable clip
	if {![llength $paths]} return
	set clip [list $op {*}$paths]
	# other apps get the files too
	clipboard clear
	set uris [lmap p $paths { string cat file:// [uri $p] }]
	clipboard append -type text/uri-list [join $uris \r\n]
	clipboard append -type UTF8_STRING [join $paths \n]
}

proc files::uri {p} {
	set out ""
	# the name's bytes as the file system has them (the system encoding)
	foreach ch [split [encoding convertto [encoding system] $p] ""] {
		# (string match takes a "-" before "]" as a range: it is tested on its own)
		if {[string match {[A-Za-z0-9/._~]} $ch] || $ch eq "-"} { append out $ch } else { scan $ch %c v; append out [format %%%02X $v] }
	}
	return $out
}

# A free name in DIR: "name", "name (2)", "name (3)" ...
proc files::freename {dir name} {
	variable pending
	set taken [expr {[file exists [file join $dir $name]] || [file join $dir $name] in $pending}]
	if {!$taken} { return $name }
	set root [file rootname $name]; set ext [file extension $name]
	if {[file isdirectory [file join $dir $name]]} { set root $name; set ext "" }
	for {set i 2} {[file exists [file join $dir "$root ($i)$ext"]] || [file join $dir "$root ($i)$ext"] in $pending} {incr i} {}
	return "$root ($i)$ext"
}

proc files::paste {w} {
	variable clip
	variable st
	set op ""; set paths {}
	if {[llength $clip]} { set paths [lassign $clip op] } elseif {![catch {clipboard get -type text/uri-list} u]} {
		set op copy
		foreach l [split $u \r\n] { if {[string match file://* $l]} { lappend paths [urldecode [string range $l 7 end]] } }
	}
	place $w [expr {$op eq "cut" ? "move" : "copy"}] $paths $st($w,path)
	if {$op eq "cut"} { set clip {} }
	load $w; draw $w
}

proc files::urldecode {s} {
	set out ""
	set n [string length $s]
	for {set i 0} {$i < $n} {incr i} {
		set hex [string range $s [expr {$i + 1}] [expr {$i + 2}]]
		if {[string index $s $i] eq "%" && [string is xdigit -strict $hex] && [string length $hex] == 2} {
			append out [format %c [scan $hex %x]]; incr i 2
		} else { append out [string index $s $i] }
	}
	encoding convertfrom utf-8 $out
}

# ---- file operations ---------------------------------------------------------
#
# A copy, or a move across filesystems, never writes the final name directly.
# fileop_sh (run by sh, one process per operation) copies into
# .NAME.ribbon-part beside the destination, flushes it to disk with sync(1),
# checks it against the original (names, types and sizes; SHA-256 of every
# file under 16 MiB), renames it into place with a no-clobber mv, and only then
# (for a move) renames the original to .NAME.ribbon-gone and removes that.
# Any failure before the rename removes the part and leaves the original alone.
# A kill leaves a part or a -gone name, which the next open of the folder
# removes (files::clear_parts). The rename from part to name is the only step
# that makes the destination visible, and mv -n never replaces a file.
#
# A move on the same filesystem is one rename(2): atomic, and file rename
# without -force fails when the target exists. So that case stays in Tcl.
#
# RIBBON_FILEOP_KILL_AT=N kills the script just before its Nth step (tests).

namespace eval files {
	variable fileop_sh {#!/bin/sh
# ribbon-fileop copy|move SRC DST ?replace?. DST is an absolute path that must be free,
# unless the fourth word is replace: then what is at DST is replaced (see below).
# On stdout while it copies: "total BYTES" once, then "done BYTES" about every 0.4 s.
set -u
op=$1 src=$2 dst=$3 mode=${4:-}
name=${src##*/}
base=${dst##*/}
dir=${dst%/*}
[ -n "$dir" ] || dir=/
sdir=${src%/*}
[ -n "$sdir" ] || sdir=/
tmp=$dir/.$base.ribbon-part
gone=$sdir/.$name.ribbon-gone
old=$dir/.$base.ribbon-old
n=0
step() {
	n=$((n + 1))
	[ "${RIBBON_FILEOP_KILL_AT:-}" = "$n" ] && kill -9 $$
	return 0
}
fail() {
	rm -rf -- "$tmp"
	printf '%s\n' "$1" >&2
	exit 1
}
reason() { printf '%s' "${1##*: }"; }
manifest() { find "$1" -printf '%y %s %P\n' | sort; }
sums() {
	if [ -d "$1" ]; then
		(cd "$1" && find . -type f -size -16M -exec sha256sum {} + | sort)
	elif [ -f "$1" ] && [ "$(stat -c %s -- "$1")" -lt 16777216 ]; then
		sha256sum < "$1"
	fi
}
same() { [ "$(manifest "$1")" = "$(manifest "$2")" ] && [ "$(sums "$1")" = "$(sums "$2")" ]; }
bytes() { b=$(du -sb -- "$1" 2>/dev/null) && printf '%s' "${b%%[!0-9]*}"; }
# the copy's size so far, while the shell that started it lives
meter() { while kill -0 $$ 2>/dev/null; do sleep 0.4; [ -e "$tmp" ] && printf 'done %s\n' "$(bytes "$tmp")"; done; }
# Replace: DST goes only once the new one is whole beside it. Two files: one rename(2) over it,
# atomic. Anything with a folder: DST is renamed to .NAME.ribbon-old, the new one into place, the
# old one removed; a kill in between leaves the old one under -old, which files::clear_parts puts
# back when DST is missing (and removes when DST is there).
replace() {
	if { [ ! -d "$1" ] || [ -L "$1" ]; } && { [ ! -d "$dst" ] || [ -L "$dst" ]; }; then
		err=$(mv -f -T -- "$1" "$dst" 2>&1) || fail "Couldn't $op $name: $(reason "$err")"
		return 0
	fi
	rm -rf -- "$old"
	step
	err=$(mv -n -T -- "$dst" "$old" 2>&1) || fail "Couldn't $op $name: $(reason "$err")"
	step
	err=$(mv -n -T -- "$1" "$dst" 2>&1) || { mv -n -T -- "$old" "$dst"; fail "Couldn't $op $name: $(reason "$err")"; }
	step
	rm -rf -- "$old"
}
case $op in copy | move) ;; *) fail "Couldn't $op $name: unknown operation" ;; esac
[ -d "$dir" ] || fail "Couldn't $op $name: the destination isn't a folder"
{ [ -e "$src" ] || [ -L "$src" ]; } || fail "Couldn't $op $name: it is gone"
if [ "$mode" != replace ]; then
	{ [ -e "$dst" ] || [ -L "$dst" ]; } && fail "Couldn't $op $name: $base is already there"
fi
if [ "$op" = move ] && [ "$(stat -c %d -- "$src")" = "$(stat -c %d -- "$dir")" ]; then
	step
	if [ "$mode" = replace ] && { [ -e "$dst" ] || [ -L "$dst" ]; }; then
		replace "$src"
	else
		err=$(mv -n -T -- "$src" "$dst" 2>&1) || fail "Couldn't move $name: $(reason "$err")"
		[ -e "$src" ] && fail "Couldn't move $name: $base is already there"
	fi
	step
	sync -- "$dir" 2>/dev/null
	exit 0
fi
rm -rf -- "$tmp"
printf 'total %s\n' "$(bytes "$src")"
step
meter &
mpid=$!
err=$(cp -a -- "$src" "$tmp" 2>&1)
rc=$?
kill "$mpid" 2>/dev/null
wait "$mpid" 2>/dev/null
[ "$rc" = 0 ] || fail "Couldn't $op $name: $(reason "$err")"
step
err=$(find "$tmp" ! -type l -exec sync {} + 2>&1) || fail "Couldn't $op $name: $(reason "$err")"
step
same "$src" "$tmp" || fail "Couldn't $op $name: the copy doesn't match the original"
step
if [ "$mode" = replace ] && { [ -e "$dst" ] || [ -L "$dst" ]; }; then
	replace "$tmp"
else
	err=$(mv -n -T -- "$tmp" "$dst" 2>&1) || fail "Couldn't $op $name: $(reason "$err")"
	[ -e "$tmp" ] && fail "Couldn't $op $name: $base is already there"
fi
step
sync -- "$dir" 2>/dev/null
if [ "$op" = move ]; then
	step
	err=$(mv -n -T -- "$src" "$gone" 2>&1) || { printf '%s\n' "Moved $name, but couldn't remove the original: $(reason "$err")" >&2; exit 1; }
	step
	err=$(rm -rf -- "$gone" 2>&1) || { printf '%s\n' "Moved $name, but couldn't remove the original: $(reason "$err")" >&2; exit 1; }
fi
exit 0
}

}

# The command that runs one copy or move (see fileop_sh above).
proc files::fileop_cmd {op src dst {mode ""}} {
	variable fileop_sh
	return [list sh -c $fileop_sh ribbon-fileop $op $src $dst {*}$mode]
}

# Errors come back as "couldn't ...: reason"; the status line wants the reason
# only where Tcl gives one ("error renaming ...: file already exists").
proc files::reason {err} {
	set r [string trim $err]
	if {[regexp {: ([^:]*)$} $r -> tail]} { return $tail }
	return $r
}

# A word for the status line: one line, shown until the next operation or 8 s.
proc files::status_fail {w msg} {
	variable st
	if {![winfo exists $w]} return
	set st($w,status) $msg
	draw $w
	after 8000 [list files::clear_status $w $msg]
}

proc files::clear_status {w msg} {
	variable st
	if {[winfo exists $w] && $st($w,status) eq $msg} { set st($w,status) ""; draw $w }
}

# Do the same-filesystem check without a stat on the destination (it isn't made yet).
# A link is where the link is, not where it points.
proc files::samedev {src dst} {
	if {[catch {file lstat $src s1} ] || [catch {file stat [file dirname $dst] s2}]} { return 0 }
	return [expr {$s1(dev) == $s2(dev)}]
}

# Copy or move SRC to DST (a free name) from any folder. A move on one
# filesystem is a rename, done now; anything else goes to the background
# queue. DONE runs once the operation has worked (in Tcl, here or later), FAIL
# once it has not.
proc files::transfer {w op src dst {done ""} {fail ""} {mode ""}} {
	if {$op eq "move" && $mode eq "" && [samedev $src $dst]} {
		if {[catch {::file rename -- $src $dst} err]} {
			if {$fail ne ""} { uplevel #0 $fail }
			status_fail $w "Couldn't move [file tail $src]: [reason $err]"
			return 0
		}
		if {$done ne ""} { uplevel #0 $done }
		return 1
	}
	set verb [expr {$op eq "move" ? "Moving" : "Copying"}]
	job_add $verb [file tail $src] $dst $src
	queue $w $verb [file tail $src] [fileop_cmd $op $src $dst $mode] $dst $src $done $fail
	return 0
}

# Background operations, one after another, so the shell never stalls.
proc files::queue {w verb name cmd dst src {done ""} {fail ""}} {
	variable ops
	variable pending
	if {$dst ne ""} { lappend pending $dst }
	lappend ops [list $w $verb $name $cmd $dst $src $done $fail]
	run_next
}

proc files::run_next {} {
	variable ops
	variable opch
	variable opcur
	variable opout
	variable st
	if {$opch ne ""} return
	if {![llength $ops]} { job_end; return }
	set ops [lassign $ops op]
	lassign $op w verb name cmd
	set opcur $op
	set opout ""
	if {[winfo exists $w]} {
		set n [llength $ops]
		set st($w,status) "$verb $name[expr {$n ? " and $n more" : ""}]…"
		statusbar $w
	}
	if {[catch {::open |[list {*}$cmd 2>@1]} fh]} {
		set opcur {}
		op_finish $w $op "Couldn't finish $name: [reason $fh]"
		after idle files::run_next
		return
	}
	set opch $fh
	fconfigure $fh -blocking 0
	fileevent $fh readable [list files::op_read $fh]
}

proc files::op_read {fh} {
	variable opch
	variable opout
	variable oplines
	variable opcur
	append opout [read $fh]
	# the helper's progress lines: "total N" and "done N" (fileop_sh)
	while {[set nl [string first \n $opout]] >= 0} {
		set line [string range $opout 0 [expr {$nl - 1}]]
		if {[regexp {^done (\d+)$} $line -> b]} {
			job_progress $b
		} elseif {![regexp {^total \d*$} $line]} { append oplines $line\n }
		set opout [string range $opout [expr {$nl + 1}] end]
	}
	if {![eof $fh]} return
	append oplines $opout
	set opout $oplines
	set oplines ""
	fileevent $fh readable {}
	# close reports the exit status only on a blocking pipe (jobs.tcl does the same)
	fconfigure $fh -blocking 1
	set rc [catch {::close $fh} err]
	set opch ""
	lassign $opcur w verb name
	if {$rc} {
		# sh prints the one line that says why (its last non-empty line)
		set msg ""
		foreach l [split $opout \n] { if {[string trim $l] ne ""} { set msg [string trim $l] } }
		if {$msg eq ""} { set msg "Couldn't finish $name" }
		op_finish $w $opcur $msg
	} else {
		op_finish $w $opcur ""
	}
	run_next
}

# An operation has ended: an error goes to the status line, success runs DONE.
proc files::op_finish {w op err} {
	variable pending
	variable opcur
	variable st
	variable cancelled
	lassign $op ow verb name cmd dst src done fail
	set opcur {}
	if {$dst ne ""} { set pending [lsearch -all -inline -not -exact $pending $dst] }
	job_step $dst $name [expr {$err eq ""}]
	set killed [expr {$dst ne "" && $dst in $cancelled}]
	set cancelled [lsearch -all -inline -not -exact $cancelled $dst]
	if {$err ne "" && $killed} {
		# cancelled: no word about it; what the killed copy left goes now
		if {$fail ne ""} { uplevel #0 $fail }
		foreach d [list $dst $src] { if {$d ne ""} { clear_parts [file dirname $d] } }
		if {[winfo exists $w]} { set st($w,status) ""; load $w; draw $w }
		return
	}
	if {$err eq ""} {
		if {$done ne ""} { uplevel #0 $done }
		if {[winfo exists $w]} { set st($w,status) "" }
	} else {
		if {$fail ne ""} { uplevel #0 $fail }
		status_fail $w $err
	}
	if {[winfo exists $w]} { load $w; draw $w }
}

# Leftover parts (.NAME.ribbon-part), original parts (.NAME.ribbon-gone) and replaced ones (.NAME.ribbon-old) of
# an operation that was killed. Removed when the folder is opened, unless an
# operation is working on that folder right now.
proc files::clear_parts {dir} {
	variable ops
	variable opcur
	foreach op [concat $ops [list $opcur]] {
		if {[llength $op] == 0} continue
		lassign $op ow ov on oc dst src
		foreach p [list $dst $src] {
			if {$p ne "" && [file dirname $p] eq $dir} { return }
		}
	}
	foreach p [glob -nocomplain -directory $dir .*.ribbon-part .*.ribbon-gone] {
		catch {::file delete -force -- $p}
	}
	# a replace killed half way: the old one goes back where nothing took its place
	foreach p [glob -nocomplain -directory $dir .*.ribbon-old] {
		set name [string range [file tail $p] 1 end-11]
		set orig [file join $dir $name]
		if {$name ne "" && ![file exists $orig] && [catch {file lstat $orig _}]} {
			catch {::file rename -- $p $orig}
		} else { catch {::file delete -force -- $p} }
	}
}

# ---- folder watch ------------------------------------------------------------
#
# ribbon-fswatch (inotify, a small C program beside the shell) watches each
# folder a Files window shows. A window whose folder is confirmed watched does
# not stat it; the 1.5 s poll runs only where the watch is refused or lost, or
# the helper is missing. Commands to the helper, one per line:
#   watch PATH | unwatch PATH
# Replies, tab-separated:
#   watching TAB PATH | refused TAB PATH | lost TAB PATH | changed TAB PATH

proc files::fsw_open {} {
	variable fsw
	variable fswfailed
	if {$fsw ne "" || $fswfailed} return
	set exe [auto_execok ribbon-fswatch]
	if {![llength $exe] || [catch {::open |[list {*}$exe] r+} fh]} { set fswfailed 1; return }
	fconfigure $fh -blocking 0 -buffering line
	fileevent $fh readable [list files::fsw_read $fh]
	set fsw $fh
}

proc files::fsw_send {msg} {
	variable fsw
	if {$fsw eq ""} return
	if {[catch {puts $fsw $msg; flush $fsw}]} { fsw_gone }
}

# The helper has gone (or never ran): every window polls from now on.
proc files::fsw_gone {} {
	variable fsw
	variable fswpaths
	variable fswlive
	variable fswfailed
	if {$fsw ne ""} {
		catch {fileevent $fsw readable {}}
		catch {::close $fsw}
	}
	set fsw ""; set fswpaths {}; set fswlive {}; set fswfailed 1
	sync_live
}

proc files::fsw_read {fh} {
	variable fswpaths
	variable fswlive
	while {[::gets $fh line] >= 0} {
		set i [string first \t $line]
		if {$i < 0} continue
		set cmd [string range $line 0 [expr {$i - 1}]]
		set p [string range $line [expr {$i + 1}] end]
		switch -- $cmd {
			watching {
				if {$p in $fswpaths && $p ni $fswlive} { lappend fswlive $p }
				sync_live
			}
			refused - lost {
				set fswpaths [lsearch -all -inline -not -exact $fswpaths $p]
				set fswlive [lsearch -all -inline -not -exact $fswlive $p]
				fsw_changed $p
				sync_live
			}
			changed { fsw_changed $p }
		}
	}
	if {[eof $fh]} fsw_gone
}

# Something in a folder changed: reload its windows once the burst has settled.
proc files::fsw_changed {p} {
	variable st
	foreach w [windows] {
		if {$st($w,path) ne $p} continue
		if {$st($w,dirty) ne ""} { catch {after cancel $st($w,dirty)} }
		set st($w,dirty) [after 100 [list files::reload $w]]
	}
}

proc files::reload {w} {
	variable st
	set st($w,dirty) ""
	if {[winfo exists $w]} { load $w; draw $w }
}

# Ask the helper for the folders the windows show now; drop the rest.
proc files::watch_sync {} {
	variable st
	variable fsw
	variable fswpaths
	variable fswlive
	set want {}
	foreach w [windows] {
		set p $st($w,path)
		if {[string first \n $p] < 0 && [string first \t $p] < 0 && $p ni $want} { lappend want $p }
	}
	fsw_open
	set old $fswpaths
	set fswpaths $want
	if {$fsw ne ""} {
		foreach p $old { if {$p ni $want} { fsw_send "unwatch $p" } }
		foreach p $want { if {$p ni $old} { fsw_send "watch $p" } }
	}
	set keep {}
	foreach p $fswlive { if {$p in $want} { lappend keep $p } }
	set fswlive $keep
	sync_live
}

# A window polls unless its folder is confirmed watched.
proc files::sync_live {} {
	variable st
	variable fswlive
	foreach w [windows] {
		if {![info exists st($w,path)]} continue
		live_set $w [expr {$st($w,path) in $fswlive}]
	}
}

proc files::live_set {w on} {
	variable st
	if {![info exists st($w,live)]} return
	set st($w,live) $on
	if {!$on && $st($w,pollid) eq ""} { poll $w }
}

# trash, restore, empty_trash and really_delete: files-trash.tcl

proc files::delete_forever {w} {
	variable st
	set paths [selpaths $w]
	if {![llength $paths]} return
	set what [expr {[llength $paths] == 1 ? "\"[file tail [lindex $paths 0]]\"" : "[llength $paths] items"}]
	confirm $w "Delete $what for good?" "This can't be undone." Delete [list files::really_delete $w $paths]
}

proc files::newfolder {w} {
	variable st
	set name [freename $st($w,path) "New folder"]
	if {[catch {file mkdir [file join $st($w,path) $name]}]} return
	load $w
	set st($w,sel) [list $name]; set st($w,anchor) $name
	draw $w; reveal $w $name
	rename_start $w
}

# Rename in place: an entry over the item's name.
proc files::rename_start {w} {
	variable st
	if {[llength $st($w,sel)] != 1} return
	set name [lindex $st($w,sel) 0]
	array set c [array get theme::c]
	foreach t $st($w,tiles) {
		if {[lindex $t 4] ne $name} continue
		lassign $t x0 y0 x1 y1
		set e $w.main.rename
		destroy $e
		entry $e -font f12 -relief flat -borderwidth 0 -highlightthickness 1 -highlightcolor $c(ACCENT) \
			-highlightbackground $c(ACCENT) -background $c(FIELD) -foreground $c(FG) -insertbackground $c(ACCENT) \
			-selectbackground $c(ACCENT) -selectforeground $c(ON_ACCENT) -justify [expr {$st($w,view) eq "grid" ? "center" : "left"}]
		$e insert 0 $name
		set stem [string length [file rootname $name]]
		$e selection range 0 [expr {[file isdirectory [file join $st($w,path) $name]] || $stem == 0 ? "end" : $stem}]
		if {$st($w,view) eq "grid"} {
			$w.main create window [expr {$x0 + 52}] [expr {$y0 + 80}] -window $e -width 112 -height 22
		} else {
			$w.main create window 48 [expr {$y0 + 16}] -window $e -anchor w -width 360 -height 24
		}
		bind $e <Return> [list files::rename_done $w $name]
		bind $e <KP_Enter> [list files::rename_done $w $name]
		bind $e <Escape> [list destroy $e]
		bind $e <FocusOut> [list files::rename_done $w $name]
		focus $e
		return
	}
}

proc files::rename_done {w old} {
	variable st
	set e $w.main.rename
	if {![winfo exists $e]} return
	set new [string trim [$e get]]
	destroy $e
	focus $w
	if {$new eq "" || $new eq $old || [string first / $new] >= 0} return
	set dir $st($w,path)
	if {[file exists [file join $dir $new]]} { set new [freename $dir $new] }
	if {[catch {file rename -- [file join $dir $old] [file join $dir $new]} err]} {
		status_fail $w "Couldn't rename $old: [reason $err]"
		return
	}
	openwith::moved [file join $dir $old] [file join $dir $new]
	load $w; set st($w,sel) [list $new]; set st($w,anchor) $new; draw $w
}

# ---- menus and dialogs, in the Ribbon style ------------------------------------

proc files::context {w x y X Y} {
	variable st
	set name [at $w $x $y]
	# where the menu was asked for: Properties opens beside it (files::props)
	set st($w,ctx) [list $name $X $Y]
	if {$name ne "" && $name ni $st($w,sel)} { set st($w,sel) [list $name]; set st($w,anchor) $name; layout $w; statusbar $w }
	set trash [trash_view $st($w,path)]
	set items {}
	if {$name ne ""} {
		set one [expr {[llength $st($w,sel)] == 1}]
		set p [itempath $w $name]
		if {$trash} {
			lappend items [list undo Restore [list files::restore $w]] [list trash "Delete for good" [list files::delete_forever $w] Shift+Del 1]
		} else {
			# Files-Menu-Archive, Files-Menu-Compress; Properties ends the menu (HANDOFF)
			set tar [expr {[auto_execok bsdtar] ne ""}]
			lappend items [list right Open [list files::activate $w $name] ↵]
			if {$one && [file isdirectory $p]} { lappend items [list plus "Open in new window" [list files::show $p] Ctrl+↵] }
			if {$one && $tar && [archive $name] && [file isfile $p]} { lappend items [list archive "Extract here" [list files::extract $w $p]] }
			lappend items - [list copy Copy [list files::set_clip copy [selpaths $w]] Ctrl+C] \
				[list scissors Cut [list files::set_clip cut [selpaths $w]] Ctrl+X]
			if {$one} { lappend items [list edit Rename [list files::rename_start $w] F2] }
			lappend items [list link "Copy path" [list files::copy_path $w]]
			if {$one && [kindicon $name 0] eq "image"} { lappend items [list image "Set as wallpaper" [list apps::run "ribbon-theme wallpaper set [apps::shellquote $p]"]] }
			if {$tar} { lappend items [list archive Compress [list files::compress $w [selpaths $w]]] }
			lappend items - [list trash "Move to Trash" [list files::trash $w] Del]
			lappend items - [list info Properties [list files::props $w menu] Alt+↵]
		}
	} else {
		if {$trash} {
			lappend items [list trash "Empty trash" [list files::empty_trash $w]]
		} else {
			lappend items [list plus "New folder" [list files::newfolder $w] Ctrl+⇧+N]
			if {[llength $::files::clip]} { lappend items [list paste Paste [list files::paste $w] Ctrl+V] }
			lappend items [list terminal "Open terminal here" [list apps::run "cd [apps::shellquote $st($w,path)] && ribbon-terminal"]] \
				- [list eye [expr {$st($w,hidden) ? "Hide hidden files" : "Show hidden files"}] [list files::toggle_hidden $w] Ctrl+H] \
				[list [expr {$st($w,view) eq "grid" ? "list" : "grid"}] [expr {$st($w,view) eq "grid" ? "View as list" : "View as icons"}] [list files::set_view $w [expr {$st($w,view) eq "grid" ? "list" : "grid"}]] [expr {$st($w,view) eq "grid" ? "Ctrl+2" : "Ctrl+1"}]] \
				[list info Properties [list files::props $w menu]]
		}
	}
	popup_menu $w $X $Y $items
}

proc files::set_view {w v} { variable st; set st($w,view) $v; draw $w }
proc files::toggle_hidden {w} { variable st; set st($w,hidden) [expr {!$st($w,hidden)}]; load $w; draw $w }
proc files::copy_path {w} { clipboard clear; clipboard append [join [selpaths $w] \n] }

# The shell's menu (Menus mockup): 6 px padding, 32 px rows with a line
# icon, the shortcut on the right, hover in the field colour.
# items: {icon label cmd ?key? ?accent? ?chips?} or "-"; chips {name on cmd}
# attached: it hangs from a bar (1: square top) or stands on the dock
# ("up": square bottom), one shape with it; else it floats, with its own
# shadow. Either way it is an ARGB window (rbnalpha), see-through around
# its rounded corners.
# The rectangle a menu opened at X Y stays inside: the output under that point (a window on another display has
# its menus there), else the main display (display.tcl; the whole X screen when the outputs are not known).
proc files::popup_bounds {X Y} {
	foreach o [display::outputs] {
		lassign $o - ox oy ow oh
		if {$X >= $ox && $X < $ox + $ow && $Y >= $oy && $Y < $oy + $oh} { return [list $ox $oy $ow $oh] }
	}
	display::rect
}

proc files::popup_menu {w X Y items {width 240} {attached 0}} {
	variable menuhits
	variable menuinset
	variable menuwidth $width
	# standing on a dock button, rows line up with the button: its 4 px
	# inset, its icon and label columns
	lassign [expr {$attached eq "up" ? {4 14 38} : {6 16 42}}] menuinset ix tx
	array set c [array get theme::c]
	set m .filesmenu
	destroy $m
	rbn::surface $m -fill $c(BAR)
	set h 6
	foreach it $items { incr h [expr {$it eq "-" ? 9 : 32}] }
	incr h 6
	# attached: 1 hangs from a top bar at Y; "up" stands on the dock, Y is
	# its bottom edge. Either way the menu and bar are one shape.
	if {$attached eq "up"} { set Y [expr {$Y - $h}] }
	if {$attached ne "0"} {
		bind $m <Destroy> {if {"%W" eq ".filesmenu"} { set dock::wmenu ""; after idle bar::draw }}
	}
	set y 6
	set menuhits {}
	set later {}
	foreach it $items {
		if {$it eq "-"} { $m.c create rectangle 10 [expr {$y + 4}] [expr {$width - 10}] [expr {$y + 5}] -fill $c(BORDER) -width 0; incr y 9; continue }
		lassign $it icon label cmd key accent chips
		set col [expr {$accent ne "" && $accent ? $c(ACCENT) : $c(FG)}]
		set icol [expr {$accent ne "" && $accent ? $c(ACCENT) : $c(MUTED)}]
		lappend later [list $icon $icol $label $col $key $y]
		set chiphits {}
		set cx [expr {$width - 16}]
		if {$key ne ""} { set cx [expr {round($cx - [text::width f11 $key] - 10)}] }
		foreach ch [lreverse $chips] {
			lassign $ch name on ccmd
			set cx [expr {$cx - 22}]
			# over the hover row too: keep the sprites' alpha
			rbn::box $m.c $cx [expr {$y + 5}] 22 22 -fill [expr {$on ? $c(ACCENT) : $c(FIELD)}] -radius 6 -on ""
			lappend later [list chip $cx $y $name [expr {$on ? $c(ON_ACCENT) : $c(MUTED)}]]
			lappend chiphits [list $cx [expr {$cx + 22}] $ccmd]
			set cx [expr {$cx - 6}]
		}
		lappend menuhits [list $y [expr {$y + 32}] $cmd $chiphits]
		incr y 32
	}
	foreach l $later {
		if {[lindex $l 0] eq "chip"} {
			lassign $l - cx y name col
			text::draw $m.c [expr {$cx + 11}] [expr {$y + 16}] f11s $col $name center
			continue
		}
		lassign $l icon icol label col key y
		bar::icon $m.c $icon 16 1.8 $icol $ix [expr {$y + 8}]
		text::draw $m.c $tx [expr {$y + 16}] f13 $col $label w
		if {$key ne ""} { text::draw $m.c [expr {$width - 16}] [expr {$y + 16}] f11 $c(MUTED) $key e }
	}
	bind $m.c <Motion> [list files::menu_hover $m %y]
	bind $m.c <Button-1> [list files::menu_click $m %x %y]
	bind $m <Escape> [list destroy $m]
	lassign [files::popup_bounds $X $Y] ox oy ow oh
	set X [expr {max($ox + 4, min($X, $ox + $ow - $width - 4))}]; set Y [expr {max($oy, min($Y, $oy + $oh - $h - 4))}]
	switch -- $attached {
		up { rbn::popup $m $X $Y $width $h [theme::look menu -radius {12 12 0 0} -ring [list $c(BORDER) 1 tlr]] -clip b }
		0 { rbn::popup $m $X $Y $width $h [theme::look menu] }
		default { rbn::popup $m $X $Y $width $h [theme::look pop -radius {0 0 12 12} -ring [list $c(BORDER) 1 lrb]] -clip t }
	}
	update idletasks
	catch {grab -global $m}
	bind $m <ButtonPress> [list files::menu_outside $m %X %Y]
}

proc files::menu_hover {m y} {
	variable menuhits
	variable menuinset
	variable menuwidth
	$m.c delete hover
	foreach h $menuhits {
		lassign $h y0 y1 cmd
		if {$y >= $y0 && $y < $y1 && $cmd ne ""} {
			rbn::box $m.c $menuinset $y0 [expr {$menuwidth - 2 * $menuinset}] 32 -fill $theme::c(FIELD) -radius 8 -on $theme::c(BAR) -tags hover
			$m.c lower hover
			return
		}
	}
}

proc files::menu_click {m x y} {
	variable menuhits
	foreach h $menuhits {
		lassign $h y0 y1 cmd chiphits
		if {$y < $y0 || $y >= $y1} continue
		foreach ch $chiphits {
			lassign $ch x0 x1 ccmd
			if {$x >= $x0 && $x < $x1} { destroy $m; after idle $ccmd; return }
		}
		if {$cmd ne ""} { destroy $m; after idle $cmd }
		return
	}
}

# The menu is its canvas (the window around it is its shadow).
proc files::menu_outside {m X Y} {
	set x0 [winfo rootx $m.c]; set y0 [winfo rooty $m.c]
	if {$X < $x0 || $Y < $y0 || $X > $x0 + [winfo width $m.c] || $Y > $y0 + [winfo height $m.c]} { destroy $m }
}

# Yes/no in the Ribbon style, over the window.
proc files::confirm {w title text yes script} {
	array set c [array get theme::c]
	set d .filesconfirm
	destroy $d
	rbn::surface $d -fill $c(BAR)
	set W 340; set H 150
	set bw [expr {round(24 + [text::width f13s $yes])}]
	rbn::box $d.c [expr {$W - 20 - $bw}] [expr {$H - 52}] $bw 32 -fill $c(ACCENT) -radius 8 -on $c(BAR)
	rbn::box $d.c [expr {$W - 20 - $bw - 8 - 84}] [expr {$H - 52}] 84 32 -fill $c(FIELD) -radius 8 -on $c(BAR)
	text::draw $d.c 20 30 f13s $c(FG) $title w
	$d.c create text 20 54 -text $text -font f12 -fill $c(MUTED) -anchor w -width [expr {$W - 40}]
	text::draw $d.c [expr {$W - 20 - $bw / 2}] [expr {$H - 36}] f13s $c(ON_ACCENT) $yes center
	text::draw $d.c [expr {$W - 20 - $bw - 8 - 42}] [expr {$H - 36}] f13 $c(FG) Cancel center
	bind $d.c <Button-1> [list files::confirm_click $d %x %y $W $H $bw $script]
	bind $d <Return> [list files::confirm_yes $d $script]
	bind $d <Escape> [list destroy $d]
	set x [expr {[winfo rootx $w] + ([winfo width $w] - $W) / 2}]
	set y [expr {[winfo rooty $w] + ([winfo height $w] - $H) / 2}]
	rbn::popup $d $x $y $W $H [theme::look pop]
	update idletasks
	catch {grab $d}
	focus -force $d
}

proc files::confirm_click {d x y W H bw script} {
	if {$y < $H - 52 || $y > $H - 20} return
	if {$x >= $W - 20 - $bw && $x < $W - 20} { confirm_yes $d $script } elseif {$x >= $W - 20 - $bw - 92 && $x < $W - 20 - $bw - 8} { destroy $d }
}

proc files::confirm_yes {d script} {
	destroy $d
	uplevel #0 $script
	foreach w [windows] { load $w; draw $w }
}

# ---- drag and drop -------------------------------------------------------------
#
# Inside Ribbon (between Files windows, onto folders, sidebar places and
# the Trash) this is plain Tcl: every Files window lives in this process.
# With tkdnd installed, the same drop logic also serves drags to and from
# other apps (XDND), and tkdnd carries the internal drags too.

namespace eval files {
	variable drag ""       ;# dict: src paths  (while dragging)
	variable press {}      ;# {w x y name} of the last button press
	variable dndext 0      ;# tkdnd available
}

proc files::dnd_setup {w} {
	variable dndext
	if {![catch {package require tkdnd}]} {
		set dndext 1
		foreach t [list $w.main $w.side] {
			tkdnd::drop_target register $t DND_Files
			bind $t <<DropPosition>> [list files::ext_position $w %W %X %Y %A]
			bind $t <<DropLeave>> [list files::drop_mark ""]
			bind $t <<Drop:DND_Files>> [list files::ext_drop $w %W %X %Y %D %A]
		}
		tkdnd::drag_source register $w.main DND_Files
		bind $w.main <<DragInitCmd>> [list files::ext_drag_init $w]
		bind $w.main <<DragEndCmd>> [list files::drop_mark ""]
		return
	}
	bind $w.main <B1-Motion> [list files::drag_motion $w %x %y %X %Y]
	bind $w.main <ButtonRelease-1> [list files::drag_release %X %Y %s]
}

# Where would a drop at screen X Y go? {dir widget tile} or "" (or trash)
proc files::target_at {X Y} {
	variable st
	set win [winfo containing $X $Y]
	if {[regexp {^(\.files\d+)\.(main|side)$} $win -> w part]} {
		set lx [expr {$X - [winfo rootx $win]}]; set ly [expr {$Y - [winfo rooty $win]}]
		if {$part eq "main"} {
			set name [at $w $lx $ly]
			set p [itempath $w $name]
			if {$name ne "" && [file isdirectory $p]} { return [list $p $w.main $name] }
			return [list $st($w,path) $w.main ""]
		}
		foreach h $st($w,sidehits) {
			lassign $h y0 y1 cmd
			# only rows that open a folder take a drop (not a drive that is not mounted)
			if {$ly >= $y0 && $ly < $y1 && [lindex $cmd 0] eq "go"} {
				set p [lindex $cmd end]
				return [list [expr {[trash_view $p] ? "trash" : $p}] $w.side [list $y0 $y1]]
			}
		}
	}
	return ""
}

# Highlight the drop target: a folder tile, a sidebar place, or the folder
# a window shows (an accent frame).
proc files::drop_mark {t} {
	array set c [array get theme::c]
	foreach w [windows] { catch {$w.main delete dropmark}; catch {$w.side delete dropmark} }
	if {$t eq ""} return
	lassign $t dir widget where
	if {[string match *.side $widget]} {
		lassign $where y0 y1
		rbn::box $widget 8 $y0 180 32 -fill $c(FIELD) -radius 8 -ring [list $c(ACCENT) 1.5] -on $c(BAR) -tags dropmark
		$widget lower dropmark
	} elseif {$where ne ""} {
		set w [winfo toplevel $widget]
		foreach tl $files::st($w,tiles) {
			if {[lindex $tl 4] ne $where} continue
			lassign $tl x0 y0 x1 y1
			rbn::box $widget $x0 $y0 [expr {$x1 - $x0}] [expr {$y1 - $y0}] -fill $c(FIELD) -radius 10 -ring [list $c(ACCENT) 1.5] -on [expr {[string match *.side $widget] ? $c(BAR) : $c(WIN)}] -tags dropmark
			$widget lower dropmark
		}
	} else {
		set top [$widget canvasy 0]
		$widget create rectangle 2 [expr {$top + 2}] [expr {[winfo width $widget] - 2}] [expr {$top + [winfo height $widget] - 2}] -outline $c(ACCENT) -width 2 -tags dropmark
	}
}

proc files::drag_motion {w x y X Y} {
	variable drag
	variable press
	variable st
	if {$drag eq ""} {
		lassign $press pw px py name
		if {$pw ne $w || $name eq "" || hypot($x - $px, $y - $py) < 6} return
		if {$name ni $st($w,sel)} { set st($w,sel) [list $name]; set st($w,anchor) $name; layout $w }
		set drag [dict create src $w paths [selpaths $w]]
		ghost_show [dict get $drag paths]
	}
	rbn::move .filesdrag [expr {$X + 14}] [expr {$Y + 10}]
	set t [target_at $X $Y]
	if {$t ne "" && [lindex $t 0] ne "trash" && [lindex $t 0] in [dict get $drag paths]} { set t "" }
	drop_mark $t
}

proc files::drag_release {X Y state} {
	variable drag
	if {$drag eq ""} return
	set paths [dict get $drag paths]
	set drag ""
	destroy .filesdrag
	set t [target_at $X $Y]
	drop_mark ""
	if {$t eq ""} return
	drop_paths $paths [lindex $t 0] [expr {$state & 4 ? "copy" : ($state & 1 ? "move" : "")}]
}

# Move (same drive) or copy (another drive, or Ctrl) PATHS into DIR.
proc files::drop_paths {paths dir {action ""}} {
	if {$dir eq "trash"} { trash_paths $paths; refresh_all; return }
	set dir [file normalize $dir]
	foreach p $paths {
		set p [file normalize $p]
		if {[file dirname $p] eq $dir && $action ne "copy"} continue
		if {$dir eq $p || [string first $p/ $dir/] == 0} continue
		set a $action
		if {$a eq ""} {
			set a copy
			if {![catch {file stat $p s1}] && ![catch {file stat $dir s2}] && $s1(dev) == $s2(dev)} { set a move }
		}
		set w [lindex [windows] 0]
		place $w $a [list $p] $dir 1
	}
	refresh_all
}

proc files::refresh_all {} { foreach w [windows] { load $w; draw $w } }

proc files::trash_paths {paths} {
	variable st
	set w [lindex [windows] 0]
	set keep $st($w,sel); set keeppath $st($w,path)
	foreach p $paths {
		set st($w,path) [file dirname $p]; set st($w,sel) [list [file tail $p]]
		trash $w
	}
	set st($w,path) $keeppath; set st($w,sel) $keep
}

# The chip that follows the pointer: what you're dragging.
proc files::ghost_show {paths} {
	array set c [array get theme::c]
	destroy .filesdrag
	rbn::surface .filesdrag -fill $c(BAR)
	set n [llength $paths]
	set label [expr {$n == 1 ? [bar::clip f12s [file tail [lindex $paths 0]] 200] : "$n items"}]
	set icon [expr {$n == 1 ? [kindicon [lindex $paths 0] [file isdirectory [lindex $paths 0]]] : "copy"}]
	set W [expr {round(10 + 16 + 8 + [text::width f12s $label] + 12)}]
	rbn::popup .filesdrag -1000 -1000 $W 32 [list -fill $c(BAR) -radius 8 -ring [list $c(ACCENT) 1.5] -shadow {10 24 0.5 #000000}]
	bar::icon .filesdrag.c $icon 16 1.8 $c(ACCENT) 10 8
	text::draw .filesdrag.c 34 16 f12s $c(FG) $label w
}

# ---- tkdnd (other apps) ----

proc files::ext_position {w W X Y action} {
	set t [target_at $X $Y]
	drop_mark $t
	if {$t eq ""} { return refuse_drop }
	return [expr {$action eq "move" ? "move" : "copy"}]
}

proc files::ext_drop {w W X Y data action} {
	set t [target_at $X $Y]
	drop_mark ""
	if {$t eq ""} { return refuse_drop }
	set paths [lmap p $data { expr {[string match file://* $p] ? [urldecode [string range $p 7 end]] : $p} }]
	drop_paths $paths [lindex $t 0] [expr {$action eq "move" ? "move" : ""}]
	return $action
}

proc files::ext_drag_init {w} {
	variable press
	variable st
	lassign $press pw px py name
	if {$name eq ""} { return refuse_drop }
	if {$name ni $st($w,sel)} { set st($w,sel) [list $name]; set st($w,anchor) $name; layout $w }
	return [list {copy move} DND_Files [selpaths $w]]
}

# ---- the Inspector panel: a file's or a folder's facts and edit view ----------------------
# The Inspector (properties/inspector.tcl) draws on the Properties app's ui model, so the
# shell sources that model and its modules once, beside itself (installed under /usr/lib/ribbon).
# Without them the panel stays shut and Open with uses the system default.

# Load the modules once. 1 when the panel can draw; 0 when the Properties files are missing.
proc files::modules {} {
	variable here
	variable loaded_modules
	if {[info exists loaded_modules]} { return $loaded_modules }
	set root [file dirname $here]
	set loaded_modules 0
	# sourced in the global namespace: the modules define their own namespaces
	# (openwith::, ui::, page::), which must not be created under files::
	if {[file exists [file join $root properties openwith.tcl]]} {
		uplevel #0 [list source -encoding utf-8 [file join $root properties openwith.tcl]]
	}
	set need {appearance/ui.tcl appearance/dialogs.tcl appearance/bgpages.tcl properties/widgets.tcl
		properties/pages.tcl properties/facts.tcl properties/jobs.tcl properties/inspector.tcl}
	foreach f $need { if {![file exists [file join $root $f]]} { return 0 } }
	namespace eval ::page {}
	foreach f $need { uplevel #0 [list source -encoding utf-8 [file join $root $f]] }
	# the Properties pages' redraw: here, every open panel
	proc ::page::draw {} { files::insp_draw_all }
	::ui::fonts
	set loaded_modules 1
	return 1
}

proc files::insp_colours {} {
	array set p [array get theme::c]
	ui::colours [dict create BAR $p(BAR) FIELD $p(FIELD) PILL $p(PILL) BORDER $p(BORDER) FG $p(FG) MUTED $p(MUTED) \
		ACCENT $p(ACCENT) ON_ACCENT $p(ON_ACCENT) DESK_TOP $p(DESK_TOP) DESK_BOTTOM $p(DESK_BOTTOM) \
		DESK_STRIPE $p(DESK_STRIPE) DESK_STRIPE_ALPHA $p(DESK_STRIPE_ALPHA)]
}

# Show or hide the panel (the toolbar button, Alt+Enter).
proc files::insp_toggle {w} {
	variable st
	if {![winfo exists $w.insp] || ![modules]} return
	set st($w,insp) [expr {!$st($w,insp)}]
	if {$st($w,insp)} { pack $w.insp -side right -fill y -before $w.main } else { pack forget $w.insp }
	toolbar $w
	layout $w
}

# Properties from a menu or Alt+Enter: the selection (or the folder you're in) in the standalone
# window (ribbon-properties, FileProps-Win2-Split); one window per set of items, asked again raises it.
# Where it opens (HANDOFF, "File properties window", 4; win2::place): from the menu (HOW menu), beside
# the right-clicked tile in grid view (--beside its rectangle), else beside the point the menu was
# asked at (list view, the empty area: --beside X Y 0 0); from the keyboard, centred on this window
# (--over its rectangle). Root coordinates.
proc files::props {w {how key}} {
	variable st
	set paths [selpaths $w]
	if {![llength $paths]} { set paths [list $st($w,path)] }
	set cmd "ribbon-properties [props_place $w $how]"
	foreach p $paths { append cmd " [apps::shellquote $p]" }
	apps::run $cmd
}

# The placement arguments for files::props: "--beside X Y W H" or "--over X Y W H".
proc files::props_place {w how} {
	variable st
	if {$how ne "menu"} {
		set t [winfo toplevel $w]
		return "--over [winfo rootx $t] [winfo rooty $t] [winfo width $t] [winfo height $t]"
	}
	if {[info exists st($w,ctx)]} { lassign $st($w,ctx) name X Y } else { set name ""; lassign [winfo pointerxy $w] X Y }
	if {$name ne "" && $st($w,view) eq "grid"} {
		foreach t $st($w,tiles) {
			lassign $t x0 y0 x1 y1 n
			if {$n ne $name} continue
			set c $w.main
			set rx [expr {[winfo rootx $c] + int($x0 - [$c canvasx 0])}]
			set ry [expr {[winfo rooty $c] + int($y0 - [$c canvasy 0])}]
			return "--beside $rx $ry [expr {int($x1 - $x0)}] [expr {int($y1 - $y0)}]"
		}
	}
	return "--beside [expr {int($X)}] [expr {int($Y)}] 0 0"
}

# The keys of the edit view in the panel (1 when used): a menu's keys, the name field's typing,
# Enter (Apply), Tab, and Esc, which leaves the view.
proc files::insp_keys {w sym char state} {
	variable st
	if {![info exists st($w,insp)] || !$st($w,insp)} { return 0 }
	if {[dict size $page::menu]} { page::menu_key $sym; insp_draw $w; return 1 }
	if {$sym eq "Escape"} { ::inspector::edit_end; insp_draw $w; return 1 }
	if {[lindex [ui::focused] 1] ne "field"} { return 0 }
	if {[ui::field_key [lindex [ui::focused] 0] $sym $char $state]} { insp_draw $w }
	return 1
}

# The panel's items: the selection, or the folder you're in when nothing is selected.
proc files::insp_items {w} {
	variable st
	set paths {}
	if {[llength $st($w,sel)]} {
		foreach n $st($w,sel) { lappend paths [itempath $w $n] }
	} else { set paths [list $st($w,path)] }
	set items {}
	foreach p $paths { if {![catch {facts::of $p} F]} { lappend items $F } }
	return $items
}

# Draw the panel for the window W (called by layout, so every redraw, selection change and
# count reaches it).
proc files::insp_draw {w} {
	variable st
	if {![info exists st($w,insp)] || !$st($w,insp) || ![winfo exists $w.insp]} return
	if {![modules]} return
	set c $w.insp
	set H [winfo height $c]; if {$H < 2} { set H 580 }
	insp_colours
	set ui::cv $c; set ui::W 380; set ui::H $H; set ui::ox 0; set ui::oy 0
	set ui::bx 0; set ui::by 0; set ui::behind ""; set ui::argbwin ""
	$c configure -width 380 -height $H
	set inspector::redraw [list files::insp_draw $w]
	set inspector::done [list files::insp_applied $w]
	set items [insp_items $w]
	if {![llength $items]} return
	ui::begin insp.$w {}
	inspector::draw 0 0 $H $items -w 380 -pad 24 -top 20 -preview 1 -footer pinned -keys 88
	if {[dict size $page::menu]} { w::menu_draw $page::menu }
	ui::finish
	if {[llength $items] == 1 && [dict get [lindex $items 0] isdir]} {
		inspector::count [dict get [lindex $items 0] path] [list files::insp_draw $w]
	}
}

proc files::insp_draw_all {} {
	foreach w [windows] { insp_draw $w }
}

# Apply from the panel: a rename selects the new name; a failure shows in the status bar.
proc files::insp_applied {w newpath errs} {
	variable st
	if {![winfo exists $w]} return
	if {[llength $errs]} { set st($w,status) [lindex $errs 0] }
	if {[file dirname $newpath] eq $st($w,path)} { set st($w,sel) [list [file tail $newpath]]; set st($w,anchor) [file tail $newpath] }
	load $w
	draw $w
}

# Open a file with its own choice (openwith), as the desktop app would open it. 1 when a
# choice was found and started; 0 to fall back to the system default.
proc files::open_with {p} {
	if {![llength [info commands ::openwith::get]]} { return 0 }
	set id [openwith::get $p]
	if {$id eq ""} { return 0 }
	launch $id $p
}

# Open a file in its type's default app, the one the Inspector names under "Opens with"
# (facts::handlers: the mime-apps lookup, nearest type first, then the types it is a kind of). 1 when
# it was started; 0 to fall back to xdg-open (no default, or no such app).
proc files::open_default {p} {
	if {![llength [info commands ::facts::handlers]] && ![modules]} { return 0 }
	facts_fresh
	if {[catch {lindex [facts::handlers [facts::mime $p]] 0} id] || $id eq ""} { return 0 }
	launch $id $p
}

# facts reads the desktop entries once (facts::apps); the shell runs for the whole session, so an app
# installed or removed since (a folder of entries changed) is read again.
proc files::facts_fresh {} {
	variable facts_stamp
	if {![llength [info commands ::facts::appdirs]]} return
	set stamp [lmap d [facts::appdirs] { expr {[catch {file mtime $d} t] ? "" : $t} }]
	if {![info exists facts_stamp] || $facts_stamp ne $stamp} { unset -nocomplain ::facts::apps }
	set facts_stamp $stamp
}

# Start the desktop app ID (a .desktop file's name) on the file P. 1 when it was started, 0 when
# there is no such app. The shell's app table first (apps.tcl), then the entries facts reads (an app
# that is not in the launcher, NoDisplay, still opens what it is the default for).
proc files::launch {id p} {
	# the app table is the shell's (apps.tcl): absolute names, as variables do not fall back to ::
	if {![array exists ::apps::byid]} { ::apps::load }
	set key [string tolower [file rootname $id]]
	if {[info exists ::apps::byid($key)]} {
		set a $::apps::byid($key)
		set exec [dict get $a exec]; set term [dict get $a terminal]; set bump [dict get $a id]
	} elseif {[llength [info commands ::facts::apps]] && [dict exists [facts::apps] $id Exec]} {
		set exec [dict get [facts::apps] $id Exec]
		set term [expr {[dict exists [facts::apps] $id Terminal] && [dict get [facts::apps] $id Terminal] eq "true"}]
		set bump [file rootname $id]
	} else { return 0 }
	set cmd [regsub -all {%[fFuUdDnNickvm]} $exec ""]
	set cmd [string map {%% %} [string trim $cmd]]
	if {$cmd eq ""} { return 0 }
	if {$term} { set cmd "ribbon-terminal -e $cmd" }
	apps::bump $bump
	apps::run "$cmd [apps::shellquote $p]"
	return 1
}

# the drives and the trash, beside this file (sourced globally: they add to files::)
apply {{} { foreach f {files-drives.tcl files-trash.tcl files-jobs.tcl files-view.tcl files-place.tcl} { uplevel #0 [list source -encoding utf-8 [file join $::files::here $f]] } }}
