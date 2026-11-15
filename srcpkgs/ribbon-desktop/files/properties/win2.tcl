# win2.tcl - the standalone file window (FileProps-Win2-Split): one file, a folder or several
# files, opened by `ribbon-properties PATH...` (right-click → Properties, Alt+Return, another app).
# 720 x 494, radius 16 (main.tcl makes it an ARGB window). It opens where the caller says
# (win2::place): beside the right-clicked tile or the pointer (--beside X Y W H), centred on the
# window that asked (--over X Y W H), else centred in the work area below the bar.
#   left column, 279 px, §d2: the preview (photo, folder mosaic, code, stack), the name with the
#   pencil, the kind line;  right page: the Inspector's facts (inspector.tcl);  a rule across the
#   foot, and the footer row: Access and Opens with (or one row per kind in a selection), dropdowns
#   that open menus and pick.
# The pencil swaps the page to the edit view: Access and Opens with rows, Revert / Apply, the
# name field on the left (inspector.tcl's edit code). Esc leaves the edit view, else closes.
# One window per file: a second request for the same items raises this one (main.tcl, win2::show),
# asked over a socket in $XDG_RUNTIME_DIR/ribbon-properties (unix_extra; Tk's send, which needs
# X11, only where that is missing). The window is pinned to its files: ribbon-fswatch (inotify)
# watches their folders, or a 1.5 s poll where it can't, and the window redraws when they change,
# follows a file renamed or moved within its folder, and closes when its files are gone.

namespace eval win2 {
	variable paths {}      ;# the items shown: one path, or several selected
	variable W 720
	variable H 494
	variable win .w
	variable fsw ""        ;# ribbon-fswatch's pipe, "" while polling
	variable fswdirs {}    ;# the folders asked of it
	variable sig {}        ;# what each path was when last drawn: {path dev ino mode size mtime uid gid}
	variable dirty ""      ;# the refresh waiting for a burst of changes to settle
	variable polling ""    ;# the poll's next turn
	variable sock ""       ;# the socket this window answers on
	variable listener ""
	variable drawn 0       ;# redraws, for the tests
}

# Whether PATH opens here (a file or a folder that exists, not a kit).
proc win2::for {what} {
	expr {[file exists $what] && ![string match -nocase *.kit $what]}
}

# The name a window for PATHS is known by to other instances (one window per set of items).
proc win2::name {paths} {
	return "ribbon-win2-[regsub -all {[^A-Za-z0-9]} [join [lsort $paths] |] _]"
}

# Raise this window (asked for again by another instance).
proc win2::show {} {
	variable win
	wm deiconify $win
	raise $win
	focus -force $win
}

# Set the window up for PATHS in WIN and draw it, placed by SPEC (win2::place). A scene
# (RIBBON_PROPERTIES_SCENE) keeps its own canvas and places the window where the board does.
proc win2::open {paths w {scene 0} {spec {}}} {
	variable W
	variable H
	variable win
	set win $w
	set ::win2::paths {}
	foreach p $paths { lappend ::win2::paths [file normalize $p] }
	set ui::W $W; set ui::H $H
	# the page's own redraw, key and cancel go to this window
	proc ::page::draw {} { ::win2::draw }
	proc ::fp::name_cancel {} { ::win2::escape }
	if {$scene} {
		set ui::ox 360; set ui::oy 226; set ui::bx 360; set ui::by 226
	} else {
		lassign [place $spec [winfo screenwidth .] [winfo screenheight .] [others]] x y
		wm geometry $win ${W}x${H}+$x+$y
		bind $win <Escape> {page::quit}
		serve
		watch_start
	}
	win2::draw
}

# ---- where it opens ---------------------------------------------------------------------------
# SPEC {beside X Y W H}: right of that rectangle (a grid tile; the pointer when W and H are 0), 16
# apart, or left of it when there is no room, its top 10 above; {over X Y W H}: centred on the
# window that asked; {}: centred in the area under the bar (46 px). Kept 8 px inside the screen and
# under the bar; on the place of another Properties window (TAKEN: {x y} each) it steps 28 px down
# and right (HANDOFF, "File properties window" 4). Returns {x y}.
proc win2::place {spec SW SH {taken {}}} {
	variable W
	variable H
	lassign [lrange $spec 1 end] x y w h
	switch -- [lindex $spec 0] {
		beside {
			set X [expr {$x + $w + 16}]
			if {$X + $W > $SW - 8} { set X [expr {$x - 16 - $W}] }
			set Y [expr {$y - 10}]
		}
		over { set X [expr {$x + ($w - $W) / 2}]; set Y [expr {$y + ($h - $H) / 2}] }
		default { set X [expr {($SW - $W) / 2}]; set Y [expr {46 + ($SH - 46 - $H) / 2}] }
	}
	set fit {{X Y SW SH W H} { list [expr {int(max(8, min($X, $SW - 8 - $W)))}] [expr {int(max(54, min($Y, $SH - 8 - $H)))}] }}
	lassign [apply $fit $X $Y $SW $SH $W $H] X Y
	::for {set n 0} {$n < 20 && [list $X $Y] in $taken} {incr n} {
		lassign [apply $fit [expr {$X + 28}] [expr {$Y + 28}] $SW $SH $W $H] X2 Y2
		if {$X2 == $X && $Y2 == $Y} break
		set X $X2; set Y $Y2
	}
	list $X $Y
}

# ---- one window per set of items: the socket ---------------------------------------------------

proc win2::sockdir {} {
	if {![info exists ::env(XDG_RUNTIME_DIR)] || $::env(XDG_RUNTIME_DIR) eq "" || [catch {package require unix_extra 0.3}]} { return "" }
	file join $::env(XDG_RUNTIME_DIR) ribbon-properties
}
proc win2::sockpath {paths} {
	set d [sockdir]
	if {$d eq ""} { return "" }
	file join $d "[format %08x [zlib crc32 [encoding convertto utf-8 [join [lsort $paths] \n]]]].sock"
}

# One request to the window at socket PATH: its one-line reply, "" when nothing answers (in 2 s).
proc win2::ask {path line} {
	if {[catch {unix_extra::connect $path} ch]} { return "" }
	fconfigure $ch -encoding utf-8 -translation lf -buffering line -blocking 0
	set key ::win2::reply([incr ::win2::asks])
	set $key ""
	fileevent $ch readable [list apply {{ch key} {
		if {[gets $ch l] >= 0 || [eof $ch]} { fileevent $ch readable {}; set $key [list ok $l] }
	}} $ch $key]
	set t [after 2000 [list set $key {none {}}]]
	if {[catch {puts $ch $line}]} { set $key {none {}} }
	if {[lindex [set $key] 0] eq ""} { vwait $key }
	after cancel $t
	set r [set $key]
	unset $key
	catch {close $ch}
	expr {[lindex $r 0] eq "ok" ? [lindex $r 1] : ""}
}

# Hand PATHS to a window that shows them: 1 when one was raised.
proc win2::forward {paths} {
	set sp [sockpath $paths]
	if {$sp ne ""} {
		return [expr {[file exists $sp] && [ask $sp [list show $paths]] eq "ok"}]
	}
	# no socket (unix_extra missing): Tk's send, under X11
	set app [name $paths]
	if {[lsearch -exact [winfo interps] $app] >= 0 && ![catch {send $app win2::show}]} { return 1 }
	tk appname $app
	return 0
}

# Where the other Properties windows are: {x y} each.
proc win2::others {} {
	variable sock
	set d [sockdir]
	if {$d eq ""} { return {} }
	set out {}
	foreach p [glob -nocomplain -directory $d *.sock] {
		if {$p eq $sock} continue
		set r [ask $p where]
		if {[llength $r] == 2 && [string is integer -strict [lindex $r 0]] && [string is integer -strict [lindex $r 1]]} { lappend out $r }
	}
	return $out
}

# Answer on the socket for the items shown now (again after they are renamed).
proc win2::serve {} {
	variable paths
	variable sock
	variable listener
	if {$listener ne ""} { catch {close $listener}; catch {file delete $sock}; set listener "" }
	set sock [sockpath $paths]
	if {$sock eq ""} return
	file mkdir [file dirname $sock]
	catch {file attributes [file dirname $sock] -permissions 0700}
	# a socket nothing answers on is left over from a window that died
	if {[file exists $sock]} {
		if {[ask $sock where] ne ""} { set sock ""; return }
		catch {file delete $sock}
	}
	if {[catch {unix_extra::listen $sock win2::accept} listener]} { set listener ""; set sock ""; return }
	trace add execution exit enter [list apply {{args} { catch {file delete $::win2::sock} }}]
}
proc win2::accept {ch args} {
	fconfigure $ch -encoding utf-8 -translation lf -buffering line -blocking 0
	fileevent $ch readable [list win2::request $ch]
}
# A request: {show PATHS} (raised when they are this window's) or where; the words are data, never run.
proc win2::request {ch} {
	variable paths
	variable win
	if {[catch {gets $ch line} n] || $n < 0} {
		if {[catch {eof $ch} e] || $e} { catch {close $ch} }
		return
	}
	set reply other
	if {[catch {llength $line} k]} { set k 0 }
	if {$k == 2 && [lindex $line 0] eq "show" && [lsort [lindex $line 1]] eq [lsort $paths]} {
		set reply ok
		after idle win2::show
	} elseif {$line eq "where" && [winfo exists $win]} {
		set reply "[winfo rootx $win] [winfo rooty $win]"
	}
	catch {puts $ch $reply; flush $ch}
	catch {close $ch}
}

# ---- pinned to its files: the watch -----------------------------------------------------------

# What each path is now: {path dev ino mode size mtime uid gid}, empty fields when it is gone.
proc win2::stat_all {} {
	variable paths
	lmap p $paths {
		if {[catch {file lstat $p st}]} { list $p "" "" "" "" "" "" "" } else {
			list $p $st(dev) $st(ino) $st(mode) $st(size) $st(mtime) $st(uid) $st(gid)
		}
	}
}

proc win2::watch_start {} {
	variable sig [stat_all]
	variable fsw
	set exe [auto_execok ribbon-fswatch]
	if {[llength $exe] && ![catch {::open |[list {*}$exe] r+} fh]} {
		fconfigure $fh -blocking 0 -buffering line -encoding utf-8
		fileevent $fh readable [list win2::fsw_read $fh]
		set fsw $fh
		watch_sync
	} else { poll }
}

# The folders to watch: each item's own folder (a rename, a chmod, a write in it shows there),
# and a folder shown itself.
proc win2::watch_sync {} {
	variable paths
	variable fsw
	variable fswdirs
	if {$fsw eq ""} return
	set want {}
	foreach p $paths {
		foreach d [list [file dirname $p] [expr {[file isdirectory $p] ? $p : ""}]] {
			if {$d ne "" && $d ni $want && ![regexp {[\n\t]} $d]} { lappend want $d }
		}
	}
	if {[catch {
		foreach d $fswdirs { if {$d ni $want} { puts $fsw "unwatch $d" } }
		foreach d $want { if {$d ni $fswdirs} { puts $fsw "watch $d" } }
		flush $fsw
	}]} { fsw_gone; return }
	set fswdirs $want
}

proc win2::fsw_read {fh} {
	while {[gets $fh line] >= 0} {
		set i [string first \t $line]
		if {$i < 0} continue
		switch -- [string range $line 0 [expr {$i - 1}]] {
			changed - lost { changed }
			refused { changed; poll }
		}
	}
	if {[eof $fh]} fsw_gone
}
proc win2::fsw_gone {} {
	variable fsw
	variable fswdirs {}
	if {$fsw ne ""} { catch {fileevent $fsw readable {}}; catch {close $fsw} }
	set fsw ""
	poll
}

# Without inotify (or where a folder can't be watched): look every 1.5 s.
proc win2::poll {} {
	variable polling
	if {$polling ne ""} return
	set polling [after 1500 {set ::win2::polling ""; win2::refresh; win2::poll}]
}

# Something changed: refresh once the burst has settled.
proc win2::changed {} {
	variable dirty
	if {$dirty ne ""} { after cancel $dirty }
	set dirty [after 100 {set ::win2::dirty ""; win2::refresh}]
}

# Look at the items again: follow one renamed or moved in its folder (the same file: device and
# inode), drop one that is gone, close when none is left, redraw when anything changed.
proc win2::refresh {} {
	variable paths
	variable sig
	set now {}
	set moved 0
	foreach s $sig {
		lassign $s p dev ino
		if {![catch {file lstat $p st}] && ($dev eq "" || ($st(dev) == $dev && $st(ino) == $ino))} { lappend now $p; continue }
		set found ""
		if {$dev ne ""} {
			foreach q [glob -nocomplain -directory [file dirname $p] * .*] {
				if {[file tail $q] in {. ..} || [catch {file lstat $q st}]} continue
				if {$st(dev) == $dev && $st(ino) == $ino} { set found $q; break }
			}
		}
		if {$found ne ""} {
			lappend now [file normalize $found]
			set moved 1
		} elseif {![catch {file lstat $p st}]} {
			# a new file under its name, the old one gone (an editor's save: written beside, renamed over)
			lappend now $p
		} else { set moved 1 }
	}
	if {![llength $now]} { page::quit; return }
	# one file under two of its names (one renamed over the other): once
	set now [lmap p $now { if {[info exists seen($p)]} continue; set seen($p) 1; set p }]
	if {[llength $now] < [llength $sig]} { set moved 1 }
	set paths $now
	set new [stat_all]
	if {$new eq $sig && !$moved} return
	set sig $new
	if {$moved} { watch_sync; serve; catch {wm title $::win2::win [file tail [lindex $paths 0]]} }
	win2::draw
}

# Esc: out of the edit view, else the window closes.
proc win2::escape {} {
	if {$::inspector::edit} { inspector::edit_end; win2::draw; return }
	page::quit
}

# The Apply of the edit view: the window follows the file to its new name.
proc win2::applied {newpath errs} {
	variable paths
	set inspector::notice [lindex $errs 0]
	if {[llength $paths] == 1 && [llength $errs] == 0 && $newpath ne [lindex $paths 0]} {
		set paths [list $newpath]
		variable sig [stat_all]
		watch_sync
		serve
	}
	win2::draw
}

# The window's contents for the current items.
proc win2::draw {} {
	variable paths
	variable W
	variable H
	variable drawn
	incr drawn
	set items {}
	foreach p $paths { if {![catch {facts::of $p} F]} { lappend items $F } }
	if {![llength $items]} return
	set one [expr {[llength $items] == 1}]
	set F [lindex $items 0]
	if {$one && [dict get $F isdir]} { inspector::count [dict get $F path] [list win2::draw] }
	set ui::W $W; set ui::H $H
	array set c [array get ui::c]
	# the sizes of the facts rows and their keys, as the board sets them
	set inspector::rowh 38; set inspector::keyw 112
	set inspector::redraw [list win2::draw]
	set inspector::done [list win2::applied]
	ui::begin win2 {}
	# the column stops at the footer rule (422): the footer row runs the whole width, as on the boards
	ui::box 0 0 279 422 -fill $c(d2)
	set edit [expr {$one && $inspector::edit && [dict get $F path] eq [dict get $inspector::EF path]}]
	if {!$edit && $inspector::edit} { inspector::edit_end }
	set L [dict create x 0 y 0 w 279 h $H cx 24 cw 232 pad 24 preview 1 footer none ident 1]
	set bottom [left_preview $L $items $one]
	if {$edit} {
		set ny [expr {$bottom + 13}]
		w::namefield insp.name 14 $ny 252 inspector::apply_now inspector::name_key
		set sub "[dict get $F typename] · [facts::human [dict get $F size]]"
		if {[dict get $F isdir]} { set sub "Folder" }
		ui::text 24 [expr {$ny + 43}] [inspector::clip i13 $sub 232] i13 $c(muted)
		if {$inspector::notice ne ""} { ui::text 24 [expr {$ny + 68}] [inspector::clip i13 $inspector::notice 232] i13 $c(muted) }
		set P [dict create x 279 y 0 w 441 h $H cx 312 cw 375 pad 33 preview 0 footer none ident 0 rowp 48 ddw 172 rules 1]
		set y [inspector::edit_access $P 15 $F]
		if {![dict get $F isdir]} { inspector::edit_opens $P $y $F }
		inspector::edit_footer $P
		ui::hline 0 $W 422 $c(border)
	} else {
		if {$one} {
			set sub [expr {[dict get $F isdir] ? "Folder" : "[dict get $F typename] · [facts::human [dict get $F size]]"}]
			inspector::ident $L [expr {$bottom - 2}] [dict get $F name] $sub 1
		} else {
			inspector::ident $L [expr {$bottom - 2}] "[llength $items] items" [inspector::multi_words $items] 0
		}
		# the right page: the facts, with no preview and no name of its own
		# the facts stop above the footer rule at 422 (a row that would not fit whole is left out)
		# the page and its divider stop at the footer rule too, so no rule cuts through the footer's dropdowns
		inspector::draw 279 0 422 $items -w 441 -pad 33 -top 10 -preview 0 -ident 0 -footer none -keys 112 -limit 414
		ui::box 0 422 $W [expr {$H - 422}] -fill $c(bar)
		inspector::foot_row $W 422 $inspector::rows_shown
	}
	if {[dict size $page::menu]} { w::menu_draw $page::menu }
	ui::focus_ring
	ui::finish
}

# The preview column: the picture, the folder's mosaic, the code, or the stack of a selection.
# Returns the y the preview ends at.
proc win2::left_preview {L items one} {
	array set c [array get ui::c]
	set F [lindex $items 0]
	if {!$one} {
		set pics {}
		foreach F2 $items { if {[inspector::kind $F2] eq "image"} { lappend pics [dict get $F2 path] } }
		return [inspector::stack $L 24 $pics 304]
	}
	switch [inspector::kind $F] {
		folder {
			upvar #0 facts::W Wc
			set names {}
			set p [dict get $F path]
			if {[info exists Wc(path)] && $Wc(path) eq $p} { foreach q [lrange $Wc(newest) 0 4] { lappend names [lindex $q 1] } }
			return [inspector::mosaic $L 24 $names 304]
		}
		image { return [inspector::picture $L 24 [dict get $F path] 155] }
		text { return [inspector::code_box $L 24 [dict get [facts::text_info [dict get $F path] 12] head] 304] }
		default {
			ui::box 24 24 232 155 -fill $c(field) -radius 10
			ui::icon file 32 $c(muted) [expr {24 + 116 - 16}] [expr {24 + 77.5 - 16}]
			return 179
		}
	}
}
