# chooser-portal.tcl - org.freedesktop.impl.portal.FileChooser for the Ribbon session: the file pickers of GTK, Qt,
# Firefox and Flatpak apps (through xdg-desktop-portal) open Ribbon's own file chooser (chooser-main.tcl, boards
# Chooser-*), the one Ribbon's apps use.
#
#   tclsh /usr/lib/ribbon/appearance/chooser-portal.tcl
#        (D-Bus activated: dbus-services/org.freedesktop.impl.portal.desktop.ribbon.service; xdg-desktop-portal finds
#         it from share/xdg-desktop-portal/portals/ribbon.portal, and xdg/xdg-desktop-portal/ribbon-portals.conf
#         prefers it for the FileChooser)
#
# On /org/freedesktop/portal/desktop, org.freedesktop.impl.portal.FileChooser (version 4):
#   OpenFile  (o handle, s app_id, s parent_window, s title, a{sv} options) -> u response, a{sv} results
#   SaveFile  (same)                                                        -> u response, a{sv} results
#   SaveFiles (same)                                                        -> u response, a{sv} results
# options read: accept_label, multiple, directory, filters, current_filter, choices, current_name, current_folder,
# current_file (SaveFile), files (SaveFiles). results: uris, current_filter (the asker's filter in use when the
# chooser closed) when the asker gave filters, and choices (each choice's value) when it gave choices.
# While a chooser is open, its HANDLE carries org.freedesktop.impl.portal.Request; Close there shuts the chooser.
# response: 0 chosen, 1 cancelled, 2 ended otherwise (Close, or the chooser could not run).
#
# Choices (the extra lists and checkboxes an app may add, a(ssa(ss)s): id, label, options, default) are shown in a
# strip under the chooser's list (board Chooser-Save-Choices); a choice with no options is a checkbox ("true" or
# "false"). The values come back as choices, a(ss), every choice the chooser showed.
#
# The chooser runs as its own program, on wish (RIBBON_CHOOSER_WISH, else wish on PATH, else the wish of this Tcl's
# version); the service leaves when the session bus goes.

foreach d [list /usr/lib/ribbon [file dirname [file dirname [file dirname [file normalize [info script]]]]]] {
	if {$d ni $::auto_path} { lappend ::auto_path $d }
}
package require ribbon::dbus

namespace eval portal {
	variable bus ""
	variable name org.freedesktop.impl.portal.desktop.ribbon
	variable main [file join [file dirname [file normalize [info script]]] chooser-main.tcl]
	variable open {}         ;# handle -> {msg channel pid kind}
	variable globs ""        ;# MIME type -> globs (shared-mime-info)
}

# ---- what the asker sent -------------------------------------------------------------

proc portal::opt {options key {default ""}} {
	if {[dict exists $options $key]} { return [lindex [dict get $options $key] 1] }
	return $default
}

# A path sent as ay (with its trailing NUL), as text.
proc portal::bytes_path {b} {
	set b [string trimright $b \0]
	encoding convertfrom utf-8 $b
}

# MIME type -> its globs, from shared-mime-info's globs2 (weight:type:glob) in the XDG data dirs.
proc portal::mime_globs {type} {
	variable globs
	if {$globs eq ""} {
		set globs [dict create]
		set dirs [split [expr {[info exists ::env(XDG_DATA_DIRS)] && $::env(XDG_DATA_DIRS) ne "" ? $::env(XDG_DATA_DIRS) : "/usr/local/share:/usr/share"}] :]
		if {[info exists ::env(HOME)]} { set dirs [linsert $dirs 0 [file join $::env(HOME) .local share]] }
		foreach d $dirs {
			if {[catch {open [file join $d mime globs2]} fh]} continue
			foreach line [split [read $fh] \n] {
				if {[string index $line 0] eq "#"} continue
				lassign [split $line :] - t g
				if {$t ne "" && $g ne ""} { dict lappend globs $t $g }
			}
			close $fh
		}
	}
	set out {}
	dict for {t gs} $globs {
		if {[string match $type $t]} { lappend out {*}$gs }
	}
	lsort -unique $out
}

# A portal filter (s a(us)) as a Tk file type {label patterns}: 0 globs as given, 1 MIME types through their globs.
proc portal::tk_type {filter} {
	lassign $filter label rules
	set pats {}
	foreach r $rules {
		lassign $r kind p
		if {$kind == 0} { lappend pats $p } else { lappend pats {*}[mime_globs $p] }
	}
	if {![llength $pats]} { return {} }
	list $label [lsort -unique $pats]
}

proc portal::uri {path} {
	set out file://
	foreach byte [split [encoding convertto utf-8 $path] ""] {
		if {[string match {[A-Za-z0-9/._~-]} $byte]} { append out $byte } else { append out [format %%%02X [scan $byte %c]] }
	}
	return $out
}

# ---- the calls -----------------------------------------------------------------------

proc portal::OpenFile {msg handle app parent title options} { ask open $msg $handle $title $options }
proc portal::SaveFile {msg handle app parent title options} { ask save $msg $handle $title $options }
proc portal::SaveFiles {msg handle app parent title options} { ask files $msg $handle $title $options }

# The asker's filters as the chooser's file types, in its order: {{label patterns} filter} each; current_filter last
# when it is not one of them.
proc portal::types {options} {
	set out {}
	set cur [opt $options current_filter {}]
	foreach f [concat [opt $options filters {}] [list $cur]] {
		if {![llength $f]} continue
		set t [tk_type $f]
		if {[llength $t] && [lindex $t 0] ne "" && [lsearch -exact -index {0 0} $out [lindex $t 0]] < 0} { lappend out [list $t $f] }
	}
	return $out
}

# The asker's choices as the chooser's -choices: {id label {{id label}...} default} each (one that is not a struct of
# that shape is left out, as is a choice or option whose id has a line break: the chooser's answer is lines, and what
# followed a line break in the choices' line would be read as files the user chose).
proc portal::choices {options} {
	set out {}
	foreach ch [opt $options choices {}] {
		if {[catch {llength $ch} n] || $n != 4} continue
		lassign $ch id label opts def
		if {$id eq "" || [string match "*\[\n\r\]*" $id] || [catch {llength $opts}]} continue
		set opts [lmap o $opts {
			if {[catch {llength $o} m] || $m != 2 || [string match "*\[\n\r\]*" [lindex $o 0]]} continue
			set o
		}]
		lappend out [list $id $label $opts $def]
	}
	return $out
}

# The chooser's arguments for KIND (open, save, files) and the asker's options.
proc portal::chooser_args {kind title options} {
	set a [list -title $title]
	set types [lmap t [types $options] { lindex $t 0 }]
	set cur [opt $options current_filter {}]
	if {[llength $cur]} {
		set t [tk_type $cur]
		if {[llength $t]} { lappend a -initialtype [lindex $t 0] }
	}
	if {[llength $types] && $kind ne "files"} { lappend a -filetypes $types }
	set choices [choices $options]
	if {[llength $choices]} { lappend a -choices $choices }
	set label [opt $options accept_label]
	if {$label ne ""} { lappend a -acceptlabel $label }
	set folder [opt $options current_folder]
	if {$folder ne ""} { lappend a -initialdir [bytes_path $folder] }
	switch $kind {
		open {
			if {[opt $options directory 0]} { lappend a -mode folder } else { lappend a -mode open -multiple [expr {[opt $options multiple 0] ? 1 : 0}] }
		}
		save {
			lappend a -mode save
			set file [opt $options current_file]
			if {$file ne ""} {
				set file [bytes_path $file]
				# (not through file dirname and file tail: Tcl 8.6 gives ./~name for a ~name)
				set i [string last / $file]
				lappend a -initialdir [expr {$i > 0 ? [string range $file 0 [expr {$i - 1}]] : "/"}] \
					-initialfile [string range $file [expr {$i + 1}] end]
			} else {
				lappend a -initialfile [opt $options current_name]
			}
		}
		files { lappend a -mode folder }
	}
	return $a
}

# The wish the chooser runs on, as a command (a list): RIBBON_CHOOSER_WISH, else wish on PATH, else the wish of this
# Tcl's version (a base that installs only wish9.0, say); "" when there is none.
proc portal::wish {} {
	if {[info exists ::env(RIBBON_CHOOSER_WISH)] && $::env(RIBBON_CHOOSER_WISH) ne ""} { return $::env(RIBBON_CHOOSER_WISH) }
	lrange [concat [auto_execok wish] [auto_execok wish[info tclversion]]] 0 0
}

proc portal::ask {kind msg handle title options} {
	variable bus
	variable main
	variable open
	$bus defer $msg
	set wish [wish]
	# the options go as one word that starts with -title: what the asker sent (a title such as "2>FILE") is never
	# taken for the pipeline's redirection
	set cmd [list {*}$wish -encoding utf-8 $main -name ribbon-chooser -- [chooser_args $kind $title $options]]
	if {$wish eq "" || [catch {open |$cmd r} ch]} {
		puts stderr "chooser-portal: the chooser did not start: [expr {$wish eq "" ? "no wish" : $ch}]"
		$bus reply $msg 2 {}
		return
	}
	fconfigure $ch -blocking 0 -encoding utf-8 -translation lf
	dict set open $handle [list $msg $ch [pid $ch] $kind "" $options]
	$bus export $handle org.freedesktop.impl.portal.Request {
		method Close "" "" portal::Close
	}
	fileevent $ch readable [list portal::answer $handle]
}

proc portal::answer {handle} {
	variable open
	if {![dict exists $open $handle]} return
	lassign [dict get $open $handle] msg ch pid kind out options
	append out [read $ch]
	if {![eof $ch]} { dict set open $handle [list $msg $ch $pid $kind $out $options]; return }
	fconfigure $ch -blocking 1
	catch {close $ch}
	finish $handle [string trim $out]
}

proc portal::finish {handle out} {
	variable bus
	variable open
	lassign [dict get $open $handle] msg ch pid kind - options
	dict unset open $handle
	catch {$bus unexport $handle}
	# the chooser's answer: the file type in use (an index, -1 for none), then the paths chosen as a Tcl list
	set nl [string first \n $out]
	set type [string range $out 0 [expr {$nl - 1}]]
	set out [expr {$nl < 0 ? "" : [string range $out [expr {$nl + 1}] end]}]
	# with choices, the next line holds their values: {id value} each
	set chosen {}
	if {[llength [choices $options]] && $out ne ""} {
		set nl [string first \n $out]
		set chosen [string range $out 0 [expr {$nl < 0 ? "end" : $nl - 1}]]
		set out [expr {$nl < 0 ? "" : [string range $out [expr {$nl + 1}] end]}]
		if {[catch {llength $chosen}]} { set chosen {} }
	}
	if {$out eq "" || [catch {llength $out}] || ![llength $out]} { $bus reply $msg 1 {}; return }
	set paths $out
	if {$kind eq "files"} {
		# SaveFiles: the folder chosen, each file's name in it
		set dir [lindex $paths 0]
		# (the name after its last /, never through file tail or file join: Tcl 8.6 takes ~name for a user's home)
		set paths [lmap f [opt $options files {}] {
			set n [lindex [split [bytes_path $f] /] end]
			expr {$dir eq "/" ? "/$n" : "$dir/$n"}
		}]
	}
	set results [dict create uris [list as [lmap p $paths { uri $p }]]]
	# the filter in use: one of the asker's ("All files", which the chooser adds, is not)
	set types [types $options]
	if {$kind ne "files" && [string is integer -strict $type] && $type >= 0 && $type < [llength $types]} {
		dict set results current_filter [list (sa(us)) [lindex $types $type 1]]
	}
	if {[llength $chosen]} {
		dict set results choices [list a(ss) [lmap c $chosen { if {[catch {llength $c} n] || $n != 2} continue; set c }]]
	}
	$bus reply $msg 0 $results
}

# Close on the request: the chooser is shut and the call answered 2.
proc portal::Close {msg} {
	variable open
	variable bus
	set handle [dict get $msg path]
	if {![dict exists $open $handle]} return
	lassign [dict get $open $handle] m ch pid
	catch {exec kill $pid}
	catch {fileevent $ch readable {}}
	catch {close $ch}
	dict unset open $handle
	catch {$bus unexport $handle}
	$bus reply $m 2 {}
	return
}

proc portal::start {{address session}} {
	variable bus
	variable name
	set bus [ribbon::dbus::connect $address -onclose {apply {{why} { exit 0 }}}]
	$bus export /org/freedesktop/portal/desktop org.freedesktop.impl.portal.FileChooser {
		method OpenFile osssa{sv} ua{sv} portal::OpenFile
		method SaveFile osssa{sv} ua{sv} portal::SaveFile
		method SaveFiles osssa{sv} ua{sv} portal::SaveFiles
		property version u read {-value 4 -emits const}
	}
	$bus request $name -noqueue 1
}

if {[info exists ::argv0] && [file normalize $::argv0] eq [file normalize [info script]]} {
	if {[portal::start] ne "primary"} { puts stderr "chooser-portal: $portal::name has an owner"; exit 1 }
	vwait forever
}
