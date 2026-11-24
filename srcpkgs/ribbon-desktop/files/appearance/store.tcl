# store.tcl - the themes on disk and what Apply does with them.
#
# Built-in themes: /usr/share/ribbon/themes/palettes/<id>.conf, read-only.
# Ribbon's own are Graphite (ribbon), Fjord (ribbon-fjord) and Moss
# (ribbon-moss); the older schemes (slate, amber, midnight, dark)
# stay installed for anyone who uses them but are listed only while one of
# them is the scheme in use. Your themes: ~/.config/ribbon/palettes/<id>.conf.
# A built-in is never written: editing one saves a new theme of your own,
# and no theme of yours may take a built-in's id (ribbon-theme looks in
# your folder first, so that would hide the built-in).
#
# Export writes the theme as NAME.ribbon-theme: the same KEY=VALUE text as a
# palette .conf (it can be dropped into ~/.config/ribbon/palettes by hand),
# under a name that says what it is when it is mailed or downloaded and
# that no program mistakes for its own .conf. Import takes .ribbon-theme
# or .conf, and checks every line (pal::parse_theme); nothing in the file
# is ever run.
#
# Tests: RIBBON_THEMES_DIR (the built-ins' folder), RIBBON_THEME_CMD (the
# ribbon-theme to run), XDG_CONFIG_HOME.

namespace eval store {
	variable themes {}      ;# list of dicts: id name builtin file pal
	variable OWN {ribbon ribbon-fjord ribbon-moss}
}

proc store::env {name {def ""}} {
	expr {[info exists ::env($name)] && $::env($name) ne "" ? $::env($name) : $def}
}

proc store::config {} {
	env XDG_CONFIG_HOME [file join [env HOME /tmp] .config]
}
proc store::userdir {} { file join [config] ribbon palettes }
proc store::sysdir {} {
	foreach d [list [env RIBBON_THEMES_DIR] /usr/share/ribbon/themes \
			[file join $::appdir .. themes]] {
		if {$d ne "" && [file isdirectory [file join $d palettes]]} { return [file join [file normalize $d] palettes] }
	}
	error "the built-in themes were not found"
}

proc store::cmd {} {
	set c [env RIBBON_THEME_CMD]
	if {$c ne ""} { return $c }
	if {[auto_execok ribbon-theme] ne ""} { return ribbon-theme }
	return [file join $::appdir .. bin ribbon-theme]
}

# ~/.config/ribbon/theme.conf: PALETTE=, LOGIN_FOLLOWS_THEME=
proc store::conf_get {key {def ""}} {
	set v $def
	if {![catch {open [file join [config] ribbon theme.conf]} fh]} {
		foreach line [split [read $fh] \n] { regexp "^${key}=(.*)\$" $line -> v }
		close $fh
	}
	return $v
}

# ---- the list --------------------------------------------------------------------

proc store::load {} {
	variable themes {}
	variable OWN
	set cur [conf_get PALETTE ribbon]
	set sys [sysdir]
	foreach id $OWN {
		set f [file join $sys $id.conf]
		if {[file readable $f]} { add $id $f 1 }
	}
	# an older built-in, while it is the one in use
	if {$cur ni $OWN && [file readable [file join $sys $cur.conf]] && ![file exists [file join [userdir] $cur.conf]]} {
		add $cur [file join $sys $cur.conf] 1
	}
	set mine {}
	foreach f [glob -nocomplain -directory [userdir] *.conf] {
		set id [file rootname [file tail $f]]
		if {![valid_id $id] || [file exists [file join $sys $id.conf]]} continue
		lappend mine $id $f
	}
	set rows {}
	foreach {id f} $mine {
		if {[catch {pal::complete [pal::read $f]} p]} { puts stderr "appearance: skipping $f: $p"; continue }
		lappend rows [list [string tolower [dict get $p NAME]] $id $f $p]
	}
	foreach r [lsort -index 0 $rows] {
		lassign $r - id f p
		lappend themes [dict create id $id name [dict get $p NAME] builtin 0 file $f pal $p]
	}
}

proc store::add {id f builtin} {
	variable themes
	if {[catch {pal::complete [pal::read $f]} p]} { puts stderr "appearance: $f: $p"; return }
	lappend themes [dict create id $id name [dict get $p NAME] builtin $builtin file $f pal $p]
}

proc store::valid_id {id} { regexp {^[a-z0-9][a-z0-9._-]{0,63}$} $id }

proc store::get {id {key ""}} {
	variable themes
	foreach t $themes {
		if {[dict get $t id] eq $id} { return [expr {$key eq "" ? $t : [dict get $t $key]}] }
	}
	error "no theme $id"
}
proc store::exists {id} {
	variable themes
	expr {[lsearch -exact [lmap t $themes { dict get $t id }] $id] >= 0}
}
proc store::ids {{builtin ""}} {
	variable themes
	set out {}
	foreach t $themes {
		if {$builtin eq "" || [dict get $t builtin] == $builtin} { lappend out [dict get $t id] }
	}
	return $out
}

# A name no theme has yet: NAME, else "NAME 2", "NAME 3" ...
proc store::unique_name {name {except ""}} {
	variable themes
	set taken {}
	foreach t $themes { if {[dict get $t id] ne $except} { lappend taken [string tolower [dict get $t name]] } }
	if {[string tolower $name] ni $taken} { return $name }
	set base $name
	regexp {^(.*) [0-9]+$} $name -> base
	for {set n 2} {1} {incr n} {
		set try [string range $base 0 [expr {44 - [string length $n]}]]
		set try "[string trimright $try] $n"
		if {[string tolower $try] ni $taken} { return $try }
	}
}

# An id for a new theme of yours: the name in lower case, never a
# built-in's id (installed or not) nor one of yours.
proc store::new_id {name} {
	set id [string tolower [regsub -all {[^A-Za-z0-9]+} $name -]]
	set id [string trim $id -]
	if {$id eq "" || ![valid_id $id]} { set id theme }
	set id [string range $id 0 40]
	# the built-ins' ids all start with "ribbon"
	if {[string match ribbon* $id]} { set id my-$id }
	set sys [sysdir]
	set n 1; set try $id
	while {[file exists [file join $sys $try.conf]] || [file exists [file join [userdir] $try.conf]]} {
		incr n; set try $id-$n
	}
	return $try
}

# ---- changes -------------------------------------------------------------------------

# Save P as a new theme of yours called NAME; returns its id.
proc store::save_new {name p} {
	if {![pal::valid_name $name]} { error "a name can't have quotes, \\, \$ or |, and is at most 48 characters" }
	set name [unique_name $name]
	set id [new_id $name]
	dict set p NAME $name
	pal::write [file join [userdir] $id.conf] $p "$name - made with Appearance\nid: $id"
	load
	return $id
}

# Save P over your theme ID (never a built-in).
proc store::save {id p} {
	set t [get $id]
	if {[dict get $t builtin]} { error "[dict get $t name] is built in; save it as a new theme" }
	dict set p NAME [dict get $t name]
	pal::write [dict get $t file] $p "[dict get $t name] - made with Appearance\nid: $id"
	load
}

proc store::rename {id name} {
	set t [get $id]
	if {[dict get $t builtin]} { error "a built-in theme can't be renamed" }
	set name [string trim $name]
	if {![pal::valid_name $name]} { error "a name can't have quotes, \\, \$ or |, and is at most 48 characters" }
	set name [unique_name $name $id]
	set p [dict get $t pal]
	dict set p NAME $name
	pal::write [dict get $t file] $p "$name - made with Appearance\nid: $id"
	load
	return $name
}

proc store::delete {id} {
	set t [get $id]
	if {[dict get $t builtin]} { error "a built-in theme can't be deleted" }
	file delete -- [dict get $t file]
	load
}

proc store::duplicate {id} {
	set t [get $id]
	save_new "[dict get $t name] copy" [dict get $t pal]
}

# Export ID to FILE (see the top of this file for the format).
proc store::export {id file} {
	set t [get $id]
	set p [dict get $t pal]
	pal::write $file $p "[dict get $t name] - a Ribbon theme (exported by Appearance)\nImport it in Appearance, or copy it to ~/.config/ribbon/palettes/<id>.conf"
}

# Import FILE as a new theme of yours; returns its id. Errors say what is
# wrong with the file.
proc store::import {file} {
	if {![file isfile $file]} { error "it is not a file" }
	if {[file size $file] > $pal::MAX_BYTES} { error "it is too big for a theme" }
	set fh [open $file rb]; set d [read $fh [expr {$pal::MAX_BYTES + 1}]]; close $fh
	set p [pal::parse_theme $d]
	set name [expr {[dict exists $p NAME] && [dict get $p NAME] ne "Graphite" ? [dict get $p NAME] : [file rootname [file tail $file]]}]
	if {![pal::valid_name $name]} { set name "Imported theme" }
	save_new $name $p
}

# The palette in use on the desktop now (~/.config/ribbon/palette.conf).
proc store::current_palette {} {
	set f [file join [config] ribbon palette.conf]
	if {[file readable $f] && ![catch {pal::complete [pal::read $f]} p]} { return $p }
	set id [conf_get PALETTE ribbon]
	if {[exists $id]} { return [get $id pal] }
	return [pal::complete {}]
}

# The login screen's palette after Apply: the theme's when the login screen
# follows it, else the one it has now (/etc/ribbon/palette.conf).
proc store::login_palette {} {
	if {[conf_get LOGIN_FOLLOWS_THEME yes] ne "no"} { return [current_palette] }
	set f [file join [env RIBBON_LOGIN_ROOT] etc ribbon palette.conf]
	if {[file readable $f] && ![catch {pal::complete [pal::read $f]} p]} { return $p }
	return [current_palette]
}

# ---- applying ---------------------------------------------------------------------

# Run ribbon-theme with ARGS; returns {ok output}.
proc store::run {args} {
	set c [cmd]
	set ok [expr {![catch {exec {*}[expr {[file extension $c] eq "" && [file exists $c] && ![file executable $c] ? [list bash $c] : [list $c]}] {*}$args 2>@1 </dev/null} out]}]
	list $ok $out
}

# Apply theme ID to the desktop, the login screen, or both. Returns a list
# of problems ("" when all went well).
proc store::apply_theme {id desktop login} {
	set errs {}
	if {$desktop} {
		lassign [run apply $id --quiet --no-login] ok out
		if {!$ok} { lappend errs "desktop: $out" }
	}
	lassign [run login follow [expr {$login ? "yes" : "no"}]] ok out
	if {$login} {
		lassign [run login $id] ok out
		if {!$ok} { lappend errs "login screen: [string trim $out]" }
	}
	return $errs
}
