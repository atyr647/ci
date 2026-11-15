# access.tcl - the logic of Settings → Accessibility (no Tk): text size, cursor size, high contrast and reduce
# motion, kept in the account's access.conf and applied by ribbon-theme. The page is page-access.tcl.
#
#   acc::start / acc::refresh       read the file; acc::onchange is called when something changed
#   acc::model                      text cursor contrast motion subtitle error
#                                   text: 100 125 150; cursor: 24 32 48; contrast, motion: 0 or 1
#   acc::set_text N / acc::set_cursor N / acc::set_contrast 0|1 / acc::set_motion 0|1
#                                   write the file, then `ribbon-theme access` in the background (a failure is said
#                                   in the subtitle); 1 when written
#
# The file: $XDG_CONFIG_HOME/ribbon/access.conf (~/.config/ribbon/access.conf), KEY=VALUE lines that ribbon-theme
# parses (never sources): TEXT_SCALE=100|125|150, CURSOR_SIZE=24|32|48, HIGH_CONTRAST=yes|no, REDUCE_MOTION=yes|no.
# Lines it does not set are kept; it is written whole to a new file and renamed over the old one. ribbon-theme then
# gives the toolkits (GTK 3 and 4, X resources, GSettings), foot and labwc's cursor the values; Ribbon's own apps
# read the file themselves (appearance/ui.tcl: high contrast in ui::colours, ui::reduce_motion).
#
# Tests: acc::theme is the command run after a write (a stand-in in tests/settings-access.tcl).

namespace eval acc {
	variable onchange ""
	variable error ""
	variable conf               ;# KEY -> VALUE as read
	array set conf {}
	variable lines {}           ;# the file's lines as read (kept on write)
	variable theme {ribbon-theme access}
	variable running ""         ;# the ribbon-theme pipe while it runs
	variable again 0            ;# another write came while it ran: run it once more after
	variable KEYS {TEXT_SCALE {100 125 150} CURSOR_SIZE {24 32 48} HIGH_CONTRAST {no yes} REDUCE_MOTION {no yes}}
}

proc acc::path {} {
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/"}]
	set cfg [expr {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne "" ? $::env(XDG_CONFIG_HOME) : "$home/.config"}]
	file join $cfg ribbon access.conf
}

proc acc::start {} { refresh }

proc acc::refresh {} {
	variable conf; variable lines
	array unset conf
	set text ""
	if {![catch {set h [::open [path] r]}]} {
		fconfigure $h -encoding utf-8
		catch {set text [::read $h]}
		::close $h
	}
	set lines [expr {$text eq "" ? {} : [split [string trimright $text \n] \n]}]
	foreach line $lines {
		if {[regexp {^\s*([A-Z_]+)=(.*)$} $line -> k v]} {
			set v [string trim [string trim $v] {"'}]
			set conf($k) $v
		}
	}
	notify
}

proc acc::notify {} {
	variable onchange
	if {$onchange ne ""} { uplevel #0 $onchange }
}

# A key's value as ribbon-theme reads it: the file's when it is one of the allowed, else the first (the default).
proc acc::get {k} {
	variable conf; variable KEYS
	set allowed [dict get $KEYS $k]
	if {[info exists conf($k)] && $conf($k) in $allowed} { return $conf($k) }
	lindex $allowed 0
}

proc acc::model {} {
	variable error
	set text [get TEXT_SCALE]; set cursor [get CURSOR_SIZE]
	set sub "Text $text% · [dict get {24 {default cursor} 32 {large cursor} 48 {larger cursor}} $cursor]"
	if {$error ne ""} { set sub $error }
	dict create text $text cursor $cursor contrast [expr {[get HIGH_CONTRAST] eq "yes"}] \
		motion [expr {[get REDUCE_MOTION] eq "yes"}] subtitle $sub error $error
}

proc acc::set_text {n} { set_key TEXT_SCALE $n }
proc acc::set_cursor {n} { set_key CURSOR_SIZE $n }
proc acc::set_contrast {on} { set_key HIGH_CONTRAST [expr {$on ? "yes" : "no"}] }
proc acc::set_motion {on} { set_key REDUCE_MOTION [expr {$on ? "yes" : "no"}] }

proc acc::set_key {k v} {
	variable KEYS; variable lines; variable error; variable conf
	if {![dict exists $KEYS $k] || $v ni [dict get $KEYS $k]} { return 0 }
	set out {}
	set done 0
	foreach line $lines {
		if {[regexp {^\s*([A-Z_]+)=} $line -> lk] && $lk eq $k} {
			if {!$done} { lappend out "$k=$v"; set done 1 }
			continue
		}
		lappend out $line
	}
	if {!$done} { lappend out "$k=$v" }
	set f [path]
	set tmp $f.new[pid]
	if {[catch {
		file mkdir [file dirname $f]
		if {[file isdirectory $f]} { error "it is a folder" }
		set h [::open $tmp w]
		fconfigure $h -encoding utf-8 -translation lf
		puts -nonewline $h "[join $out \n]\n"
		::close $h
		file rename -force $tmp $f
	} msg]} {
		catch { file delete $tmp }
		set error "Could not save [file tail $f]: $msg"
		notify
		return 0
	}
	set error ""
	set lines $out
	set conf($k) $v
	apply_theme
	notify
	return 1
}

# ribbon-theme access, one at a time: a write while it runs runs it again when it ends.
proc acc::apply_theme {} {
	variable theme; variable running; variable again; variable error
	if {$running ne ""} { set again 1; return }
	if {[auto_execok [lindex $theme 0]] eq ""} {
		set error "Could not apply: [lindex $theme 0] is not installed"
		return
	}
	if {[catch {set running [::open |[list {*}$theme 2>@1] r]} msg]} {
		set running ""
		set error "Could not apply: $msg"
		return
	}
	fconfigure $running -blocking 0
	fileevent $running readable acc::theme_read
}

proc acc::theme_read {} {
	variable running; variable again; variable error
	variable out
	append out [::read $running]
	if {![eof $running]} return
	fconfigure $running -blocking 1
	set failed [catch {::close $running}]
	set running ""
	set text [string trim $out]; set out ""
	if {$failed} {
		regsub {^ribbon-theme: } [lindex [split $text \n] end] "" last
		set error "Could not apply: [expr {$last ne "" ? $last : "ribbon-theme failed"}]"
	} elseif {[string match "Could not apply*" $error]} {
		set error ""
	}
	if {$again} { set again 0; apply_theme }
	notify
}
namespace eval acc { variable out "" }
