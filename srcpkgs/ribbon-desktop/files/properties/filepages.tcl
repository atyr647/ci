# filepages.tcl - a file's and a folder's General page in the Rail (Props-A3-Photo,
# Props-A4-Folder's General), for what the standalone file window
# (win2.tcl) doesn't take: a .kit that kit can't read. Rename, access, owner and the
# app that opens it are edited here and applied together by Apply, through
# pkexec only for what you may not change yourself.

namespace eval fp {
	variable E      ;# the edits: name owner u g o opens
	variable E0     ;# ... as on disk
	array set E {}
	array set E0 {}
	variable handlers {}   ;# {default others} for the file's type
	variable exif {}
	variable dims ""
	variable drive ""
	variable redraw ""
}

# Access for one class of rwx bits: none, ro, rw.
proc fp::level {bits} {
	expr {($bits & 4) && ($bits & 2) ? "rw" : (($bits & 4) ? "ro" : "none")}
}

proc fp::start {} {
	variable E
	variable E0
	variable handlers
	variable exif {}
	variable dims ""
	variable drive ""
	set F $page::F
	set m [dict get $F mode]
	array unset E0
	array set E0 [list name [dict get $F name] owner [dict get $F owner] \
		u [level [expr {($m >> 6) & 7}]] g [level [expr {($m >> 3) & 7}]] o [level [expr {$m & 7}]] opens ""]
	set handlers {"" {}}
	if {[dict get $F isdir]} {
		set drive [facts::drive [dict get $F path]]
		facts::count [dict get $F path] fp::counted
	} else {
		set handlers [facts::handlers [dict get $F mime]]
		set E0(opens) [lindex $handlers 0]
		if {[string match image/* [dict get $F mime]]} {
			set dims [facts::image_size [dict get $F path]]
			set exif [facts::exif [dict get $F path]]
		}
	}
	array unset E
	array set E [array get E0]
	ui::fset name $E(name)
	set page::S(sub) [dict get $F typename]
}

# The folder count moved on: redraw, at most every 150 ms.
proc fp::counted {} {
	variable redraw
	if {$redraw ne "" && $facts::W(busy)} return
	after cancel $redraw
	set redraw [after 150 {set fp::redraw ""; page::draw}]
}

proc fp::dirty {} {
	variable E
	variable E0
	set E(name) [ui::fval name]
	foreach k [array names E] { if {$E($k) ne $E0($k)} { return 1 } }
	return 0
}

proc fp::name_edit {} {
	set ui::focus name
	set ui::fld(name,cur) [string length [file rootname [ui::fval name]]]
	page::draw
}
proc fp::name_cancel {} {
	variable E0
	ui::fset name $E0(name)
	set ui::focus ""
	page::draw
}

proc fp::revert {} {
	variable E
	variable E0
	array set E [array get E0]
	ui::fset name $E0(name)
	set ui::focus ""
	page::draw
}

proc fp::set_ {k v} {
	variable E
	set E($k) $v
	page::draw
}

# ---- Apply -----------------------------------------------------------------------------

# The new mode from the access levels: r and w per class; a folder's x
# follows r (a folder you can read you can open); a file keeps its x bits.
proc fp::mode {} {
	variable E
	set F $page::F
	set m [dict get $F mode]
	set dir [dict get $F isdir]
	set out [expr {$m & 07000}]
	foreach k {u g o} sh {6 3 0} {
		set old [expr {($m >> $sh) & 7}]
		switch -- $E($k) {
			none { set b 0 }
			ro { set b 4 }
			rw { set b 6 }
		}
		if {$dir} { if {$b} { incr b 1 } } else { incr b [expr {$old & 1}] }
		set out [expr {$out | ($b << $sh)}]
	}
	return $out
}

proc fp::apply {} {
	variable E
	variable E0
	set F $page::F
	set E(name) [string trim [ui::fval name]]
	set path [dict get $F path]
	set jobs {}
	set newpath $path
	if {$E(name) ne $E0(name)} {
		if {$E(name) eq "" || [string match */* $E(name)] || $E(name) in {. ..}} {
			dlg::message "Can't rename it" "“$E(name)” can't be a name."
			return
		}
		set newpath [file join [dict get $F dir] $E(name)]
		if {[file exists $newpath] && ![string equal -nocase $newpath $path]} {
			dlg::message "Can't rename it" "There is already something called “$E(name)” here."
			return
		}
		lappend jobs [list rename $path $newpath]
	}
	if {$E(owner) ne $E0(owner)} { lappend jobs [list chown $E(owner) $newpath] }
	set m [mode]
	if {$m != [dict get $F mode]} { lappend jobs [list chmod [format %04o $m] $newpath] }
	if {$E(opens) ne $E0(opens) && $E(opens) ne ""} {
		if {[catch {facts::set_default [dict get $F mime] $E(opens)} err]} { dlg::message "Can't change the app" $err; return }
	}
	set page::S(busy) 1
	. configure -cursor watch
	run_jobs $jobs [list fp::applied $newpath $path]
}

proc fp::applied {path oldpath errs} {
	set page::S(busy) 0
	if {$path ne $oldpath && ![file exists $oldpath]} { openwith::moved $oldpath $path }
	. configure -cursor {}
	set p $page::S(page)
	if {[file exists $path] || ![catch {file lstat $path st}]} { page::open_file $path } else { page::open_file [dict get $page::F path] }
	if {$p in [page::keys]} { set page::S(page) $p }
	set ui::focus ""
	if {[llength $errs]} { dlg::message "Not everything was applied" [join $errs \n] }
	page::draw
}

proc fp::me {} { expr {[catch {exec id -un} u] ? "" : $u} }

proc fp::show {p} {
	exec {*}[expr {[auto_execok ribbon-files] ne "" ? "ribbon-files" : "xdg-open"}] $p >/dev/null 2>@1 &
}

# ---- General ---------------------------------------------------------------------------------

# "4032 × 3024 · Fujifilm X-T5" for a photo, the folder for a folder,
# else the type and where it is.
proc fp::subtitle {} {
	variable dims
	variable exif
	set F $page::F
	if {[dict get $F isdir]} { return [facts::tilde [dict get $F path]] }
	set parts {}
	if {$dims ne ""} { lappend parts "[lindex $dims 0] × [lindex $dims 1]" }
	set cam [facts::camera $exif]
	if {$cam ne ""} { lappend parts $cam }
	if {![llength $parts]} { lappend parts [facts::tilde [dict get $F path]] }
	join $parts " · "
}

# The access rows (owner, you, group, everyone), 46 tall; returns the y below.
proc fp::access {x y} {
	variable E
	array set c [array get ui::c]
	set F $page::F
	set acc {{none None} {ro {Read only}} {rw {Read & write}}}
	ui::label $x $y Access
	set y [expr {$y + 22}]
	set me [fp::me]
	set rows [list [list user Owner owner] [list user [expr {$E(owner) eq $me ? "You" : $E(owner)}] u] \
		[list users Group g] [list globe Everyone o]]
	set n 0
	foreach r $rows {
		lassign $r icon label key
		ui::icon $icon 15 $c(muted) [expr {$x + 1.5}] [expr {$y + 15.5}]
		ui::text [expr {$x + 30}] [expr {$y + 15}] $label i13 $c(muted)
		if {$key eq "owner"} {
			set tw [ui::text [expr {$x + 379}] [expr {$y + 15}] $E(owner) i13m $c(fg) e]
			set users [facts::users]
			if {$E(owner) ni $users} { lappend users $E(owner) }
			set m [dict create id owner x [expr {$x + 379}] y [expr {$y + 39}] top [expr {$y + 7}] \
				items [lmap u $users { list $u $u user }] cur $E(owner) script {fp::set_ owner}]
			ui::hit [expr {$x + 379 - $tw - 8}] [expr {$y + 7}] [expr {$tw + 8}] 32 [list apply {{m x y} { page::menu_toggle $m }} $m]
			ui::focusable owner list [expr {$x + 379 - $tw - 6}] [expr {$y + 11}] [expr {$tw + 6}] 24 6 [list w::dropdown_key $m]
		} else {
			w::dropdown $key [expr {$x + 379 - 150}] [expr {$y + 7}] 150 32 $acc $E($key) [list fp::set_ $key]
		}
		if {$n < 3} { ui::hline $x [expr {$x + 379}] [expr {$y + 45}] $c(border) }
		set y [expr {$y + 46}]
		incr n
	}
	return $y
}

proc fp::footer {} {
	page::footer {{apply Apply primary fp::apply check} {revert Revert ghost fp::revert undo}}
}

proc page::draw_general {} {
	variable F
	variable TOP
	array set c [array get ui::c]
	head General [fp::subtitle]
	if {[dict get $F isdir]} { fp::folder_general; fp::footer; return }
	set path [dict get $F path]
	ui::label 270 $TOP File
	w::namefield name 270 [expr {$TOP + 22}] 379 fp::apply ""
	set rows [list [list Type [list [list t [dict get $F typename]]]] \
		[list Size [list [list t [facts::human [dict get $F size]]] [list m "([facts::commas [dict get $F size]] bytes)"]]] \
		[list Location [list [list t [clip i13 [facts::tilde [dict get $F dir]] 220]]] [list ext [list fp::show [dict get $F dir]]]]]
	if {[dict get $F btime] ne ""} { lappend rows [list Created [list [list t [facts::when [dict get $F btime]]]]] }
	lappend rows [list Modified [list [list t [facts::when [dict get $F mtime]]]]] [list Opened [list [list t [facts::when [dict get $F atime]]]]]
	set y [w::facts 270 [expr {$TOP + 22 + 38 + 6}] 379 $rows 44 96]
	# Opens with: the app, the others that can
	set y [expr {$y + 22}]
	ui::label 270 $y {Opens with}
	lassign $fp::handlers default others
	set all [concat [expr {$default ne "" ? [list $default] : {}}] $others]
	set cur $fp::E(opens)
	set items [lmap id $all { list $id [facts::app_name $id] [facts::app_icon $id] }]
	if {[llength $items]} {
		w::dropdown opens 270 [expr {$y + 22}] 379 38 $items $cur {fp::set_ opens} [facts::app_icon $cur]
		set rest [lmap id $all { if {$id eq $cur} continue; list [facts::app_icon $id] [facts::app_name $id] "" [list fp::set_ opens $id] }]
		set y [expr {$y + 22 + 38}]
		if {[llength $rest]} { w::chips 270 [expr {$y + 10}] 379 $rest 4; set y [expr {$y + 10 + 32}] }
	} else {
		ui::box 270 [expr {$y + 22}] 379 38 -fill $c(field) -radius 8
		ui::ring 270 [expr {$y + 22}] 379 38 8 $c(border) 1
		ui::text 282 [expr {$y + 33}] None i13 $c(muted)
		set y [expr {$y + 22 + 38}]
	}
	# the preview fills what the access rows leave
	set ay $TOP
	if {$page::S(picture) ne ""} {
		set ph [expr {$y - $TOP - 22 - 22 - 206}]
		if {$ph >= 80} {
			ui::label 681 $TOP Preview
			if {![w::picture 681 [expr {$TOP + 22}] 379 $ph $path 10]} {
				ui::box 681 [expr {$TOP + 22}] 379 $ph -fill $c(field) -radius 10
				ui::icon image 32 $c(muted) [expr {681 + 379 / 2.0 - 16}] [expr {$TOP + 22 + $ph / 2.0 - 16}]
			}
			set ay [expr {$TOP + 22 + $ph + 22}]
		}
	}
	fp::access 681 $ay
	fp::footer
}

proc fp::folder_general {} {
	variable drive
	array set c [array get ui::c]
	set F $page::F
	set TOP $page::TOP
	upvar #0 facts::W W
	ui::label 270 $TOP Folder
	w::namefield name 270 [expr {$TOP + 22}] 379 fp::apply ""
	set items [expr {$W(files) + $W(dirs)}]
	set rows [list [list Location [list [list t [page::clip i13 [facts::tilde [dict get $F dir]] 220]]] [list ext [list fp::show [dict get $F dir]]]] \
		[list Contains [list [list t "[facts::commas $items] item[expr {$items == 1 ? "" : "s"}]"] \
			[list m "· [facts::commas $W(files)] file[expr {$W(files) == 1 ? "" : "s"}], [facts::commas $W(dirs)] folder[expr {$W(dirs) == 1 ? "" : "s"}]"]]] \
		[list Size [list [list t [facts::human $W(bytes)]] [list m "([facts::commas $W(bytes)] bytes)"]]]]
	if {[dict get $F btime] ne ""} { lappend rows [list Created [list [list t [facts::when [dict get $F btime]]]]] }
	lappend rows [list Modified [list [list t [facts::when [dict get $F mtime]]]]]
	if {$drive ne ""} { lappend rows [list Drive [list [list t "[lindex $drive 0] · [facts::human [lindex $drive 1]] free"]]] }
	set y [w::facts 270 [expr {$TOP + 22 + 38 + 6}] 379 $rows 44 96]
	set pics [lrange $W(newest) 0 4]
	if {[llength $pics]} {
		set y [expr {$y + 22}]
		ui::label 270 $y Newest
		set n [llength $pics]
		set tw [expr {(379 - 8 * ($n - 1)) / double($n)}]
		set x 270
		foreach p $pics {
			if {![w::picture $x [expr {$y + 22}] $tw 74 [lindex $p 1] 8]} {
				ui::box $x [expr {$y + 22}] $tw 74 -fill $c(field) -radius 8
			}
			ui::hit $x [expr {$y + 22}] $tw 74 [list apply {{p x y} { fp::show $p }} [lindex $p 1]]
			set x [expr {$x + $tw + 8}]
		}
	}
	# what it holds, by kind
	ui::label 681 $TOP Contents
	set parts [list Photos photos $c(accent) Videos videos $c(muted) Documents documents $c(border) Other other $c(pill)]
	set total [expr {max(1, $W(bytes))}]
	set segs {}
	foreach {label k colour} $parts { if {$W($k,b) > 0} { lappend segs [expr {max(1.0, 100.0 * $W($k,b) / $total)}] $colour } }
	if {[llength $segs]} {
		set sum 0; foreach {f col} $segs { set sum [expr {$sum + $f}] }
		set avail [expr {379 - 3 * ([llength $segs] / 2 - 1)}]
		set x 681.0
		foreach {f col} $segs {
			set sw [expr {$avail * $f / $sum}]
			ui::box $x [expr {$TOP + 24}] $sw 10 -fill $col -radius 3
			set x [expr {$x + $sw + 3}]
		}
	} else {
		ui::box 681 [expr {$TOP + 24}] 379 10 -fill $c(field) -radius 3
	}
	set y [expr {$TOP + 42}]
	set n 0
	foreach {label k colour} $parts {
		ui::box 685 [expr {$y + 17}] 10 10 -fill $colour -radius 3
		ui::text 711 [expr {$y + 14}] $label i13 $c(fg)
		ui::text 1060 [expr {$y + 14}] [facts::human $W($k,b)] i13 $c(fg) e 0 {} 1
		ui::text 984 [expr {$y + 14}] "[facts::commas $W($k,n)] item[expr {$W($k,n) == 1 ? "" : "s"}]" i13 $c(muted) e 0 {} 1
		if {$n < 3} { ui::hline 681 1060 [expr {$y + 43}] $c(border) }
		set y [expr {$y + 44}]
		incr n
	}
	fp::access 681 [expr {$y + 22}]
}
