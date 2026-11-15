# apps.tcl - installed apps (.desktop files), files and launching.

namespace eval apps {
	variable list {}        ;# dicts: id name generic comment exec icon cats wmclass
	variable byid
	variable loaded 0
	variable usage
	variable files {}       ;# file index for Files mode: {name path isdir}
	variable fileswalk {}
	array set byid {}
	array set usage {}
}

proc apps::dirs {} {
	set home $::env(HOME)
	set data [expr {[info exists ::env(XDG_DATA_HOME)] ? $::env(XDG_DATA_HOME) : "$home/.local/share"}]
	set sys [expr {[info exists ::env(XDG_DATA_DIRS)] && $::env(XDG_DATA_DIRS) ne "" ? $::env(XDG_DATA_DIRS) : "/usr/local/share:/usr/share"}]
	set out [list $data/applications]
	foreach d [split $sys :] { lappend out $d/applications }
	lappend out /var/lib/flatpak/exports/share/applications $home/.local/share/flatpak/exports/share/applications
	return $out
}

proc apps::load {} {
	variable list
	variable byid
	variable loaded
	set list {}; array unset byid
	set seen {}
	set desktops [split [expr {[info exists ::env(XDG_CURRENT_DESKTOP)] ? $::env(XDG_CURRENT_DESKTOP) : "Ribbon"}] :]
	foreach dir [dirs] {
		foreach f [lsort [glob -nocomplain -directory $dir *.desktop]] {
			set id [file tail $f]
			if {$id in $seen} continue
			lappend seen $id
			# foot's own entries give way to Ribbon Terminal (apps/term: tabs, one dock button)
			if {$id in {foot.desktop footclient.desktop foot-server.desktop org.codeberg.dnkl.foot.desktop org.codeberg.dnkl.footclient.desktop org.codeberg.dnkl.foot-server.desktop}} continue
			if {[catch {open $f} fh]} continue
			fconfigure $fh -encoding utf-8
			set e {}; set in 0
			while {[gets $fh line] >= 0} {
				if {[string index $line 0] eq "\["} { set in [expr {$line eq "\[Desktop Entry\]"}]; continue }
				if {$in && [regexp {^([A-Za-z]+)\s*=\s*(.*)$} $line -> k v]} { dict set e $k $v }
			}
			close $fh
			if {[dict exists $e Type] && [dict get $e Type] ne "Application"} continue
			if {![dict exists $e Name] || ![dict exists $e Exec]} continue
			if {[dict exists $e NoDisplay] && [dict get $e NoDisplay] eq "true"} continue
			if {[dict exists $e Hidden] && [dict get $e Hidden] eq "true"} continue
			if {[dict exists $e OnlyShowIn]} {
				set ok 0
				foreach d [split [dict get $e OnlyShowIn] \;] { if {$d ne "" && $d in $desktops} { set ok 1 } }
				if {!$ok} continue
			}
			set a [dict create id [file rootname $id] name [dict get $e Name] \
				generic [expr {[dict exists $e GenericName] ? [dict get $e GenericName] : ""}] \
				comment [expr {[dict exists $e Comment] ? [dict get $e Comment] : ""}] \
				exec [dict get $e Exec] \
				cats [expr {[dict exists $e Categories] ? [dict get $e Categories] : ""}] \
				wmclass [expr {[dict exists $e StartupWMClass] ? [dict get $e StartupWMClass] : ""}] \
				terminal [expr {[dict exists $e Terminal] && [dict get $e Terminal] eq "true"}]]
			lappend list $a
			set byid([string tolower [file rootname $id]]) $a
			if {[dict get $a wmclass] ne ""} { set byid([string tolower [dict get $a wmclass]]) $a }
		}
	}
	set loaded 1
	load_usage
}

proc apps::usagefile {} {
	set home $::env(HOME)
	set st [expr {[info exists ::env(XDG_STATE_HOME)] ? $::env(XDG_STATE_HOME) : "$home/.local/state"}]
	return $st/ribbon/launcher-usage
}

proc apps::load_usage {} {
	variable usage
	array unset usage
	if {![catch {open [usagefile]} fh]} {
		foreach {k v} [read $fh] { set usage($k) $v }
		close $fh
	}
}

proc apps::bump {id} {
	variable usage
	if {![info exists usage($id)]} { set usage($id) 0 }
	incr usage($id)
	catch {
		file mkdir [file dirname [usagefile]]
		set fh [open [usagefile] w]; puts $fh [array get usage]; close $fh
	}
}

# The app behind a window's app_id (Wayland app_id or X11 WM_CLASS).
proc apps::forwindow {appid} {
	variable byid
	variable list
	variable loaded
	if {!$loaded} load
	set k [string tolower $appid]
	foreach cand [list $k [lindex [split $k .] end] org.$k] {
		if {[info exists byid($cand)]} { return $byid($cand) }
	}
	foreach a $list { if {[string tolower [dict get $a name]] eq $k} { return $a } }
	return {}
}

# Short label for a window's app. Ribbon's own short names for the core
# apps, else the app's Name.
proc apps::label {appid} {
	set k [string tolower $appid]
	set short {ribbonfiles Files foot Terminal org.codeberg.dnkl.foot Terminal
		steam Steam firefox Firefox org.mozilla.firefox Firefox ribbon-settings Settings
		ribboninstaller Installer ribbonwelcome Welcome}
	if {[dict exists $short $k]} { return [dict get $short $k] }
	# a tab of Ribbon Terminal (ribbon-term-GROUP-N, its preferences ribbon-term-GROUP-prefs; shell/mod-term.tcl)
	if {[string match ribbon-term-* $k]} { return Terminal }
	set a [forwindow $appid]
	if {$a ne ""} { return [dict get $a name] }
	return [string totitle [lindex [split $appid .] end]]
}

proc apps::kind {appid} {
	set k [string tolower $appid]
	if {[string match *ribbonfiles* $k] || [string match *thunar* $k] || [string match *nautilus* $k] || [string match *pcmanfm* $k]} { return files }
	if {[regexp {firefox|chromium|chrome|librewolf|brave|epiphany|qutebrowser|falkon|vivaldi} $k]} { return web }
	set a [forwindow $appid]
	if {$a ne "" && [string match *WebBrowser* [dict get $a cats]]} { return web }
	if {$a ne "" && [string match *FileManager* [dict get $a cats]]} { return files }
	return app
}

# The line icon for an app, from its name and categories.
proc apps::iconfor {a {appid ""}} {
	set name [string tolower [expr {$a ne "" ? [dict get $a name] : $appid}]]
	set cats [expr {$a ne "" ? [dict get $a cats] : ""}]
	if {[string match "*star citizen*" $name] || [string match *rsi* $name]} { return star }
	switch -glob -- [string tolower $appid] {
		*ribbonfiles* - *thunar* { return folder }
		*terminal* { return terminal }
		*steam* { return game }
		*firefox* - *chrom* { return globe }
	}
	foreach {pat ic} {
		*FileManager* folder *TerminalEmulator* terminal *WebBrowser* globe *Game* game
		*Monitor* pulse *Audio* music *Music* music *Player* music *Graphics* image *Photography* image
		*Development* code *Settings* sliders *System* sliders *Office* file *TextEditor* file
		*Utility* pkg
	} {
		if {[string match $pat $cats]} { return $ic }
	}
	return grid
}

proc apps::desc {a} {
	if {[dict get $a comment] ne ""} { return [dict get $a comment] }
	return [dict get $a generic]
}

# Rank apps for a query: name prefix, then word prefix, then substring,
# then the letters in order; ties by how often you launch it, then name.
proc apps::search {q} {
	variable list
	variable loaded
	variable usage
	if {!$loaded} load
	set q [string tolower [string trim $q]]
	if {$q eq ""} { return {} }
	set pat "*[join [split $q {}] *]*"
	set hits {}
	foreach a $list {
		set n [string tolower [dict get $a name]]
		if {[string first $q $n] == 0} { set r 0
		} elseif {[string first " $q" $n] >= 0 || [string first "-$q" $n] >= 0} { set r 1
		} elseif {[string first $q $n] >= 0} { set r 2
		} elseif {[string first $q [string tolower [dict get $a generic]]] >= 0} { set r 3
		} elseif {[string match $pat $n]} { set r 4
		} else continue
		set u [expr {[info exists usage([dict get $a id])] ? $usage([dict get $a id]) : 0}]
		lappend hits [list $r [expr {-$u}] $n $a]
	}
	set out {}
	foreach h [lsort -command apps::cmp $hits] { lappend out [lindex $h 3] }
	return $out
}

proc apps::cmp {a b} {
	foreach i {0 1} { set d [expr {[lindex $a $i] - [lindex $b $i]}]; if {$d} { return $d } }
	string compare [lindex $a 2] [lindex $b 2]
}

# Words for the idle animation: Ribbon's favourites if installed, then any
# app with a short name.
proc apps::idlewords {} {
	variable list
	variable loaded
	if {!$loaded} load
	set names {}
	foreach a $list { lappend names [dict get $a name] }
	set out {}
	foreach w {Firefox Steam {Star Citizen} Terminal Files Settings} {
		set hit [expr {$w in $names}]
		if {!$hit && $w eq "Files"} { set hit [expr {[lsearch -glob $names *Thunar*] >= 0}] }
		if {!$hit && $w eq "Terminal"} { set hit [expr {[lsearch -glob $names *Terminal*] >= 0}] }
		if {!$hit && $w eq "Settings"} { set hit [expr {[lsearch -glob $names *Settings*] >= 0}] }
		if {$hit} { lappend out $w }
	}
	foreach n $names {
		if {[llength $out] >= 6} break
		if {[string length $n] <= 14 && $n ni $out} { lappend out $n }
	}
	if {![llength $out]} { set out {Firefox Steam Terminal} }
	return $out
}

proc apps::run {cmd} {
	catch {exec sh -c "exec setsid -f sh -c [shellquote $cmd] >/dev/null 2>&1" &}
}

proc apps::shellquote {s} { return "'[string map {' '\\''} $s]'" }

# Properties (ribbon-properties): of a file, a folder or a .kit, or of an
# app (A, an app's dict) by its launcher entry.
proc apps::properties {path} { run "ribbon-properties [shellquote $path]" }
proc apps::app_properties {a} {
	if {$a eq ""} return
	run "ribbon-properties --app [shellquote [dict get $a id]]"
}

proc apps::launch {a} {
	set cmd [regsub -all {%[fFuUdDnNickvm]} [dict get $a exec] ""]
	set cmd [string map {%% %} [string trim $cmd]]
	# a terminal program runs in the chosen terminal (Settings → Default apps), a tab of Ribbon Terminal by default
	if {[dict get $a terminal]} { set cmd "ribbon-terminal -e $cmd" }
	bump [dict get $a id]
	run $cmd
}

# ---- files -----------------------------------------------------------

proc apps::expand {p} {
	if {[string index $p 0] eq "~"} { return $::env(HOME)[string range $p 1 end] }
	return $p
}

proc apps::tilde {p} {
	set h $::env(HOME)
	if {$p eq $h} { return ~ }
	if {[string first $h/ $p] == 0} { return ~[string range $p [string length $h] end] }
	return $p
}

# Completion for a typed path: the rest of the first match, with a slash
# on directories. "" when there is nothing to add.
proc apps::complete {typed} {
	set p [expand $typed]
	if {[string index $p end] eq "/"} { set dir $p; set part "" } else {
		set dir [file dirname $p]; set part [file tail $p]
	}
	if {![file isdirectory $dir]} { return "" }
	set hits [lsort -dictionary [glob -nocomplain -tails -directory $dir -- [string map {* \\* ? \\? [ \\[ \\ \\\\} $part]*]]
	if {$part eq "" || [string index $part 0] ne "."} { set hits [lsearch -all -inline -not -glob $hits .*] }
	foreach h $hits {
		set rest [string range $h [string length $part] end]
		if {[file isdirectory [file join $dir $h]]} { append rest / }
		if {$rest ne ""} { return $rest }
	}
	return ""
}

# A small index of names under $HOME (4 levels, hidden skipped), built in
# slices from the event loop so typing never stalls.
proc apps::index_files {} {
	variable files
	variable fileswalk
	if {[llength $files] || [llength $fileswalk]} return
	set fileswalk [list [list $::env(HOME) 0]]
	after idle apps::index_step
}

proc apps::index_step {} {
	variable files
	variable fileswalk
	set budget 200
	while {[llength $fileswalk] && [incr budget -1] > 0} {
		lassign [lindex $fileswalk 0] dir depth
		set fileswalk [lrange $fileswalk 1 end]
		foreach p [glob -nocomplain -directory $dir *] {
			set isdir [file isdirectory $p]
			lappend files [list [string tolower [file tail $p]] $p $isdir]
			if {$isdir && $depth < 3 && [file type $p] ne "link"} { lappend fileswalk [list $p [expr {$depth + 1}]] }
		}
		if {[llength $files] > 20000} { set fileswalk {} }
	}
	if {[llength $fileswalk]} { after 1 apps::index_step }
}

proc apps::findfiles {q} {
	variable files
	index_files
	set q [string tolower [string trim $q]]
	if {$q eq ""} { return {} }
	set a {}; set b {}
	foreach f $files {
		set i [string first $q [lindex $f 0]]
		if {$i == 0} { lappend a $f } elseif {$i > 0} { lappend b $f }
		if {[llength $a] >= 6} break
	}
	return [lrange [concat $a $b] 0 5]
}

# The folder app chosen in Settings → Default apps when it is not Ribbon Files: the first inode/directory entry
# of [Default Applications] in the person's own mimeapps.list (where Settings writes the choice). "" otherwise.
proc apps::folder_choice {} {
	set cfg [expr {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne "" ? $::env(XDG_CONFIG_HOME) : [file join $::env(HOME) .config]}]
	if {[catch {open [file join $cfg mimeapps.list]} fh]} { return "" }
	fconfigure $fh -encoding utf-8
	set sec ""; set id ""
	if {[catch {read $fh} text]} { set text "" }
	close $fh
	foreach line [split $text \n] {
		set line [string trim $line]
		if {[regexp {^\[(.*)\]$} $line -> s]} { set sec $s; continue }
		if {$sec eq "Default Applications" && [regexp {^inode/directory\s*=\s*([^;\s]+)} $line -> id]} break
	}
	expr {$id eq "ribbon-files.desktop" ? "" : $id}
}

# Open a folder or a file by its path. A folder opens in Ribbon Files (in the focused Files window when there
# is one) unless another folder app was chosen in Settings; then xdg-open hands it to that app.
proc apps::open_path {p} {
	set p [file normalize [expand $p]]
	if {[file isdirectory $p]} {
		if {[launcher::files_focused]} { files::go $files::current $p
		} elseif {[folder_choice] ne ""} { run "xdg-open [shellquote $p]"
		} else { files::show $p }
	} elseif {[file exists $p]} {
		run "xdg-open [shellquote $p]"
	}
}

# Show a file in Ribbon Files, selected.
proc apps::reveal {p} {
	set p [file normalize [expand $p]]
	if {[launcher::files_focused]} {
		set w $files::current
		files::go $w [file dirname $p]
		set files::st($w,sel) [list [file tail $p]]; set files::st($w,anchor) [file tail $p]
		files::draw $w; files::reveal $w [file tail $p]
	} else { files::show $p }
}

proc apps::urlish {q} {
	expr {[regexp {^[a-z][a-z0-9+.-]*://} $q] || [regexp {^[\w-]+(\.[\w-]+)*\.[a-z]{2,}(:\d+)?(/\S*)?$} $q]}
}

proc apps::open_web {q} {
	set q [string trim $q]
	if {$q eq ""} return
	if {[urlish $q]} {
		set url [expr {[regexp {^[a-z][a-z0-9+.-]*://} $q] ? $q : "https://$q"}]
	} else {
		set enc ""
		foreach ch [split [encoding convertto utf-8 $q] ""] {
			scan $ch %c n
			if {[string match {[A-Za-z0-9._~-]} $ch]} { append enc $ch } elseif {$ch eq " "} { append enc + } else { append enc [format %%%02X $n] }
		}
		set url "https://duckduckgo.com/?q=$enc"
	}
	run "xdg-open [shellquote $url]"
}
