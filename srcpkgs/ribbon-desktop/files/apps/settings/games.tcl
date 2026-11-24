# games.tcl - finds the games on this machine for Settings → Game overlay (U20): Steam (library
# folders and appmanifests, with localconfig for play time), Heroic (GOG and Epic installed lists)
# and Lutris (its game files). Reads files only: no network, no launcher is started.
#
#   gdetect::all HOME  -> a list of game dicts {key source name art played playtime}
#     key       steam:APPID | heroic:APPNAME | lutris:SLUG   (the store's key; hudstore.tcl)
#     played    the last played time, epoch seconds, 0 when unknown
#     playtime  minutes played, 0 when unknown
#     art       a file path to the launcher's art, "" when there is none
#
# Formats: Steam's VDF (libraryfolders.vdf, appmanifest_*.acf, localconfig.vdf), Heroic's JSON
# (gog_store/installed.json, legendaryConfig/legendary/installed.json and the library caches) and
# Lutris's game YAML (config/lutris/games/*.yml). Lutris keeps its play time in pga.db, which Tcl
# cannot read here, so Lutris games show no play time. What is not checked against a real install
# is listed in design/handoff/u21.md.

namespace eval gdetect {
	variable steam_roots {.local/share/Steam .steam/steam}
}

# ---- VDF (Steam's key/value text) ------------------------------------------------------------

# The text as a flat list of {type value} pairs: type s (a quoted string) or b (a brace).
proc gdetect::vdf_tokens {text} {
	set toks {}
	foreach {all q b} [regexp -all -inline {"((?:[^"\\]|\\.)*)"|([{}])} $text] {
		if {$b ne ""} { lappend toks b $b } else { lappend toks s [regsub -all {\\(.)} $q {\1}] }
	}
	return $toks
}

# A dict of the VDF text; a malformed file gives what it read before the fault.
proc gdetect::vdf {text} {
	set toks [gdetect::vdf_tokens $text]
	set i 0
	return [gdetect::vdf_obj $toks i]
}

proc gdetect::vdf_obj {toks iVar} {
	upvar 1 $iVar i
	set d {}
	set n [llength $toks]
	while {$i < $n} {
		set t [lindex $toks $i]; set v [lindex $toks [expr {$i + 1}]]
		incr i 2
		if {$t eq "b"} {
			if {$v eq "\}"} { return $d }
			continue
		}
		# a key: then a value (a string) or a block
		if {$i >= $n} break
		set vt [lindex $toks $i]; set vv [lindex $toks [expr {$i + 1}]]
		incr i 2
		if {$vt eq "b" && $vv eq "\{"} {
			dict set d $v [gdetect::vdf_obj $toks i]
		} elseif {$vt eq "s"} {
			dict set d $v $vv
		}
	}
	return $d
}

# ---- JSON (Heroic's files) ------------------------------------------------------------------

# A JSON text as Tcl values: an object is a dict, an array a list. A bad file gives {}.
proc gdetect::json {text} {
	set i 0
	if {[catch {gdetect::jval $text i} r]} { return {} }
	return $r
}

proc gdetect::jskip {s iVar} {
	upvar 1 $iVar i
	while {$i < [string length $s] && [string is space -strict [string index $s $i]]} { incr i }
}

proc gdetect::jval {s iVar} {
	upvar 1 $iVar i
	gdetect::jskip $s i
	set c [string index $s $i]
	switch -- $c {
		\{ {
			incr i
			set d {}
			while {1} {
				gdetect::jskip $s i
				if {[string index $s $i] eq "\}"} { incr i; return $d }
				set k [gdetect::jstr $s i]
				gdetect::jskip $s i
				if {[string index $s $i] ne ":"} { error "json: expected a colon" }
				incr i
				dict set d $k [gdetect::jval $s i]
				gdetect::jskip $s i
				if {[string index $s $i] eq ","} { incr i }
			}
		}
		\[ {
			incr i
			set l {}
			while {1} {
				gdetect::jskip $s i
				if {[string index $s $i] eq "\]"} { incr i; return $l }
				lappend l [gdetect::jval $s i]
				gdetect::jskip $s i
				if {[string index $s $i] eq ","} { incr i }
			}
		}
		\" { return [gdetect::jstr $s i] }
		default {
			foreach {lit val} {true 1 false 0 null {}} {
				set len [string length $lit]
				if {[string range $s $i [expr {$i + $len - 1}]] eq $lit} { incr i $len; return $val }
			}
			set j $i
			while {$j < [string length $s] && [string first [string index $s $j] "-+.eE0123456789"] >= 0} { incr j }
			if {$j == $i} { error "json: unexpected character at $i" }
			set num [string range $s $i [expr {$j - 1}]]
			set i $j
			return $num
		}
	}
}

proc gdetect::jstr {s iVar} {
	upvar 1 $iVar i
	if {[string index $s $i] ne "\""} { error "json: expected a string" }
	incr i
	set out ""
	set n [string length $s]
	while {$i < $n} {
		set c [string index $s $i]
		if {$c eq "\""} { incr i; return $out }
		if {$c eq "\\"} {
			incr i
			set e [string index $s $i]
			switch -- $e {
				n { append out "\n" } t { append out "\t" } r { append out "\r" } b { append out "\b" } f { append out "\f" }
				u { append out "?"; incr i 4 }
				default { append out $e }
			}
		} else {
			append out $c
		}
		incr i
	}
	error "json: unterminated string"
}

# ---- helpers ----------------------------------------------------------------------------------

# Read a file, or "" when it is missing or unreadable.
proc gdetect::slurp {path} {
	if {![file readable $path] || [file isdirectory $path]} { return "" }
	if {[catch {set f [::open $path r]; set t [::read $f]; ::close $f}]} { return "" }
	return $t
}

proc gdetect::json_file {path} { gdetect::json [gdetect::slurp $path] }

# The art path when it exists, else "".
proc gdetect::art_if {path} {
	if {[file isfile $path]} { return $path }
	return ""
}

# A game dict.
proc gdetect::game {key source name art played playtime} {
	dict create key $key source $source name $name art $art played $played playtime $playtime
}

# ---- Steam ----------------------------------------------------------------------------------

# The Steam roots in HOME that exist (the data folder, then the legacy link).
proc gdetect::steam_roots {home} {
	variable steam_roots
	set out {}
	foreach r $steam_roots {
		set d [file join $home $r]
		if {[file isdirectory [file join $d steamapps]] && [lsearch -exact $out [file normalize $d]] < 0} {
			lappend out [file normalize $d]
		}
	}
	return $out
}

# Every library folder: the root's own steamapps plus the paths in libraryfolders.vdf.
proc gdetect::steam_libraries {root} {
	set libs [list $root]
	set vdf [gdetect::vdf [gdetect::slurp [file join $root steamapps libraryfolders.vdf]]]
	if {[dict exists $vdf libraryfolders]} { set vdf [dict get $vdf libraryfolders] }
	dict for {k v} $vdf {
		if {[catch {dict get $v path} p] || $p eq ""} continue
		set p [file normalize $p]
		if {[lsearch -exact $libs $p] < 0 && [file isdirectory [file join $p steamapps]]} { lappend libs $p }
	}
	return $libs
}

# localconfig.vdf holds each app's last played time and play time (minutes). The first user with
# one is used; Steam writes one per account.
proc gdetect::steam_playtimes {root} {
	set out [dict create]
	foreach cfg [glob -nocomplain [file join $root userdata * config localconfig.vdf]] {
		set apps [dict get [gdetect::vdf [gdetect::slurp $cfg]] UserLocalConfigStore Software Valve Steam apps]
		dict for {id info} $apps {
			if {![dict exists $out $id]} { dict set out $id [dict create played 0 playtime 0] }
			if {[dict exists $info LastPlayed]} { dict set out $id played [dict get $info LastPlayed] }
			if {[dict exists $info Playtime]} { dict set out $id playtime [dict get $info Playtime] }
		}
	}
	return $out
}

proc gdetect::steam {home} {
	set games {}
	foreach root [gdetect::steam_roots $home] {
		set times [gdetect::steam_playtimes $root]
		foreach lib [gdetect::steam_libraries $root] {
			foreach acf [lsort [glob -nocomplain [file join $lib steamapps appmanifest_*.acf]]] {
				set st [dict get [gdetect::vdf [gdetect::slurp $acf]] AppState]
				set id [dict get $st appid]
				set name [dict get $st name]
				set t [expr {[dict exists $times $id] ? [dict get $times $id] : [dict create played 0 playtime 0]}]
				set art [gdetect::art_if [file join $root appcache librarycache ${id}_library_600x900.jpg]]
				if {$art eq ""} { set art [gdetect::art_if [file join $root appcache librarycache ${id}_header.jpg]] }
				# the manifest's own LastPlayed wins over localconfig when both are there
				set played [expr {[dict exists $st LastPlayed] ? [dict get $st LastPlayed] : [dict get $t played]}]
				lappend games [gdetect::game steam:$id steam $name $art $played [dict get $t playtime]]
			}
		}
	}
	return [gdetect::unique $games]
}

# ---- Heroic (GOG and Epic) --------------------------------------------------------------------

# A library cache's titles and art, by app name: a dict app_name -> {title art}.
proc gdetect::heroic_titles {cfg} {
	set out [dict create]
	foreach {file list} {gog_store/store_cache/gog_library.json games store_cache/gog_library.json games \
		store_cache/legendary_library.json library} {
		set j [gdetect::json_file [file join $cfg $file]]
		if {![dict exists $j $list]} continue
		foreach g [dict get $j $list] {
			if {![dict exists $g app_name]} continue
			dict set out [dict get $g app_name] [dict create title [expr {[dict exists $g title] ? [dict get $g title] : ""}]]
		}
	}
	return $out
}

proc gdetect::heroic {home} {
	set cfg [file join $home .config heroic]
	set games {}
	set titles [gdetect::heroic_titles $cfg]
	# GOG: installed.json holds {"installed": [{appName, install_path, title?}]}
	set gog [gdetect::json_file [file join $cfg gog_store installed.json]]
	set gogList [expr {[dict exists $gog installed] ? [dict get $gog installed] : {}}]
	foreach e $gogList {
		if {![dict exists $e appName]} continue
		set app [dict get $e appName]
		set name [gdetect::heroic_name $e $titles $app]
		lappend games [gdetect::game heroic:$app heroic $name "" 0 0]
	}
	# Epic (Legendary): installed.json is {AppName: {app_name, title, install_path, ...}}
	set epic [gdetect::json_file [file join $cfg legendaryConfig legendary installed.json]]
	dict for {app e} $epic {
		set name [gdetect::heroic_name $e $titles $app]
		lappend games [gdetect::game heroic:$app heroic $name "" 0 0]
	}
	return [gdetect::unique $games]
}

# The title: the installed entry's own, else the library cache's, else the app name.
proc gdetect::heroic_name {e titles app} {
	if {[dict exists $e title] && [dict get $e title] ne ""} { return [dict get $e title] }
	if {[dict exists $titles $app] && [dict get $titles $app title] ne ""} { return [dict get $titles $app title] }
	return $app
}

# ---- Lutris -----------------------------------------------------------------------------------

# The top-level "key: value" of a Lutris game file, or "" (a nested key is not read here).
proc gdetect::yaml_value {text key} {
	foreach line [split $text "\n"] {
		if {[regexp "^$key:\\s*(.*)\$" $line -> v]} {
			set v [string trim $v]
			return [string trim $v "\"'"]
		}
	}
	return ""
}

proc gdetect::lutris {home} {
	set games {}
	foreach yml [lsort [glob -nocomplain [file join $home .config lutris games *.yml]]] {
		set text [gdetect::slurp $yml]
		set name [gdetect::yaml_value $text name]
		if {$name eq ""} continue
		set slug [gdetect::yaml_value $text slug]
		if {$slug eq ""} {
			# <slug>-<id>.yml: the slug is the file name before its numeric id
			set slug [regsub -- {-[0-9]+$} [file rootname [file tail $yml]] {}]
		}
		set art [gdetect::art_if [file join $home .local share lutris banners $slug.jpg]]
		lappend games [gdetect::game lutris:$slug lutris $name $art 0 0]
	}
	return [gdetect::unique $games]
}

# ---- all ---------------------------------------------------------------------------------------

# Every game found in HOME, one entry per key (the first wins).
proc gdetect::all {home} {
	set games [concat [gdetect::steam $home] [gdetect::heroic $home] [gdetect::lutris $home]]
	return [gdetect::unique $games]
}

proc gdetect::unique {games} {
	set seen {}
	set out {}
	foreach g $games {
		set k [dict get $g key]
		if {$k in $seen} continue
		lappend seen $k
		lappend out $g
	}
	return $out
}

# "41 h 12 min" for a play time in minutes, "" for none.
proc gdetect::playtime_text {minutes} {
	if {$minutes <= 0} { return "" }
	format {%d h %d min} [expr {$minutes / 60}] [expr {$minutes % 60}]
}

# The last played line: "Today, 21:26", "Yesterday, 23:04", "20 Oct" (this year) or "15 Sep 2025".
proc gdetect::played_text {epoch {now ""}} {
	if {$epoch <= 0} { return "" }
	if {$now eq ""} { set now [clock seconds] }
	set day [clock format $epoch -format %Y-%j]
	set today [clock format $now -format %Y-%j]
	set yest [clock format [expr {$now - 86400}] -format %Y-%j]
	if {$day eq $today} { return "Today, [clock format $epoch -format %H:%M]" }
	if {$day eq $yest} { return "Yesterday, [clock format $epoch -format %H:%M]" }
	if {[clock format $epoch -format %Y] eq [clock format $now -format %Y]} {
		return [clock format $epoch -format {%e %b}]
	}
	return [clock format $epoch -format {%e %b %Y}]
}
