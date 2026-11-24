# wm.tcl - windows and workspaces, from ribbon-shell-watch.
#
# Tcl can't speak Wayland, so the small C helper ribbon-shell-watch does and
# reports over a pipe (see its header for the line protocol). Nothing here
# polls: the pipe is read when the compositor has news.

namespace eval wm {
	variable chan ""
	variable tl           ;# id -> dict app title state
	variable order {}     ;# window ids, oldest first
	variable ws           ;# id -> dict name active
	variable wsorder {}
	variable focus ""     ;# the app window the user is working in
	variable mru {}       ;# window ids, most recently used first
	array set tl {}
	array set ws {}
}

proc wm::start {} {
	variable chan
	if {[catch {open |[list ribbon-shell-watch 2>@stderr] r+} chan]} {
		set chan ""
		after 5000 wm::start
		return
	}
	fconfigure $chan -blocking 0 -buffering line -encoding utf-8 -translation lf
	fileevent $chan readable wm::read
}

proc wm::own {app} { string match -nocase {ribbon*shell*} $app }

proc wm::read {} {
	variable chan
	variable tl
	variable order
	variable ws
	variable wsorder
	while {[gets $chan line] >= 0} {
		set rest ""
		regexp {^(\S+)(?: (\S+))?(?: (\S+))?(?: (.*))?$} $line -> kind id field rest
		switch -- $kind {
			T+ { set tl($id) {app "" title "" state ""}; lappend order $id }
			T  {
				if {![info exists tl($id)]} continue
				if {$field eq "done"} { changed; continue }
				if {$field eq "state" && $rest eq "-"} { set rest "" }
				dict set tl($id) $field $rest
			}
			T- { unset -nocomplain tl($id); set order [lsearch -all -inline -not -exact $order $id]; changed }
			W+ { set ws($id) {name "" active 0}; lappend wsorder $id }
			W  {
				if {$id eq "done"} { changed; continue }
				if {![info exists ws($id)]} continue
				if {$field eq "name"} { dict set ws($id) name $rest }
				if {$field eq "state"} { dict set ws($id) active [expr {$rest eq "active"}] }
			}
			W- { unset -nocomplain ws($id); set wsorder [lsearch -all -inline -not -exact $wsorder $id]; changed }
			ready { changed }
		}
	}
	if {[eof $chan]} {
		catch {close $chan}
		set chan ""
		array unset tl; set order {}
		array unset ws; set wsorder {}
		changed
		after 2000 wm::start
	}
}

# Coalesce bursts of updates into one redraw.
proc wm::changed {} {
	variable tl
	variable order
	variable focus
	# The app the user is working in: the activated window that isn't the
	# shell itself. While the shell has focus (typing in the field), keep
	# the previous one, so a maximized window stays "under" a solid strip.
	foreach id $order {
		set t $tl($id)
		if {[own [dict get $t app]]} continue
		if {"act" in [split [dict get $t state] ,]} { set focus $id; break }
	}
	if {$focus ne "" && (![info exists tl($focus)] || "min" in [split [dict get $tl($focus) state] ,])} {
		set focus ""
	}
	variable mru
	if {$focus ne ""} { set mru [linsert [lsearch -all -inline -not -exact $mru $focus] 0 $focus] }
	# clicking into another window closes an open panel
	variable lastfocus
	if {[info exists lastfocus] && $lastfocus ne $focus} { panel::close }
	set lastfocus $focus
	after cancel shell::refresh
	after idle shell::refresh
}

proc wm::send {cmd args} {
	if {[llength $args]} { set cmd "$cmd [join $args]" }
	variable chan
	if {$chan ne ""} { catch {puts $chan $cmd; flush $chan} }
}

# Windows for the task list: everything but the shell, oldest first.
proc wm::windows {} {
	variable tl
	variable order
	set out {}
	foreach id $order {
		if {![own [dict get $tl($id) app]] && [dict get $tl($id) app] ne ""} { lappend out $id }
	}
	return $out
}

proc wm::get {id key} {
	variable tl
	if {![info exists tl($id)]} { return "" }
	dict get $tl($id) $key
}

proc wm::has {id flag} { expr {$flag in [split [get $id state] ,]} }

# Is the shell showing a solid strip? Only while the focused window is
# maximized (or fullscreen) and not minimized.
proc wm::solid {} {
	variable focus
	expr {$focus ne "" && ([has $focus max] || [has $focus full]) && ![has $focus min]}
}

proc wm::workspaces {} {
	variable ws
	variable wsorder
	set out {}
	foreach id $wsorder { lappend out [list $id [dict get $ws($id) name] [dict get $ws($id) active]] }
	return $out
}

# Of IDS, the window used most recently (else the first).
proc wm::latest {ids} {
	variable mru
	foreach id $mru { if {$id in $ids} { return $id } }
	lindex $ids 0
}

# Click on a task: minimise it if it's the window in use, else bring it up.
proc wm::toggle {id} {
	variable focus
	if {$id eq $focus && ![has $id min]} {
		send "minimize $id"
	} else {
		send "activate $id"
	}
}
