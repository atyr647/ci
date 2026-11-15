# hudstore.tcl - the game overlay's settings store (Settings → Game overlay, HUD-Settings-B-1…8).
# No Tk here: the page (page-games.tcl) and the tests use it alike.
#
# One Defaults record {on start layout pos scale transp source contents}. A game stores only the
# fields it overrides (its "own settings"); an empty record means it uses Defaults. Contents is
# overridden as one set (the list of names that are on). A hidden flag is kept beside the records,
# not inside them. Games are keyed by the launcher's own id: steam:APPID, heroic:APPNAME,
# lutris:SLUG, or path:PROGRAM for a game added by hand (the detected ones come from gdetect in games.tcl).
#
# The file is one Tcl dict: {defaults {...} games {KEY {field value ...}} hidden {KEY 1} added {KEY {name N program P art A}}}.
# It is read with dict commands only (never evaluated). A bad value is dropped, and the default used.

namespace eval hud {
	variable db {defaults {} games {} hidden {} added {}}   ;# defaults, games, hidden, added
	variable fields {on start layout pos scale transp source contents}
	variable contents_all {frametime low1 graph gamename gpu vram cpu mem power net disk clock}
	variable contents_names {
		frametime {Frame time} low1 {1% low} graph {Frame graph} gamename {Game name} gpu GPU vram VRAM
		cpu CPU mem Memory power Power net Network disk Disk clock Clock
	}
	variable layouts {fps compact full}
	variable positions {tl tr bl br}
	variable scales {90 100 125 150}
	variable sources {auto compositor}
}

# The built-in Defaults: what the page shows before anything is set (board HUD-Settings-B-1).
proc hud::builtin_defaults {} {
	dict create on 1 start 1 layout full pos tr scale 100 transp 14 source auto \
		contents {frametime low1 graph gamename gpu vram cpu mem power net}
}

# The file the store lives in: RIBBON_GAMES_CONF (tests, and a per-user override), else the XDG config.
proc hud::path {} {
	if {[info exists ::env(RIBBON_GAMES_CONF)] && $::env(RIBBON_GAMES_CONF) ne ""} { return $::env(RIBBON_GAMES_CONF) }
	set base [expr {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne "" ? $::env(XDG_CONFIG_HOME) \
		: [file join [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}] .config]}]
	file join $base ribbon game-overlay.conf
}

# One field's value is allowed (contents is a list of known names; on and start are 0 or 1).
proc hud::valid {field value} {
	variable layouts
	variable positions
	variable scales
	variable sources
	variable contents_all
	switch -- $field {
		on - start { expr {$value in {0 1}} }
		layout { expr {$value in $layouts} }
		pos { expr {$value in $positions} }
		scale { expr {$value in $scales} }
		transp { expr {[string is integer -strict $value] && $value >= 0 && $value <= 50} }
		source { expr {$value in $sources} }
		contents {
			foreach n $value { if {$n ni $contents_all} { return 0 } }
			expr {1}
		}
		default { expr {0} }
	}
}

# hud::valid, but a value that is not even a well-formed value counts as wrong.
proc hud::ok {field value} {
	if {$field ni $::hud::fields} { return 0 }
	if {[catch {hud::valid $field $value} r]} { return 0 }
	return $r
}

# Read the file. Anything unreadable or wrong gives the built-in state: the store never fails the page.
proc hud::read_file {{path ""}} {
	variable db
	if {$path eq ""} { set path [hud::path] }
	set db [dict create defaults {} games {} hidden {} added {}]
	if {[catch {set f [::open $path r]; set text [::read $f]; ::close $f}]} return
	if {[catch {dict size $text}]} return
	foreach k {defaults games hidden added} {
		if {[dict exists $text $k]} { dict set db $k [dict get $text $k] }
		# a section that is not a dict (of dicts, for games and added) is dropped whole
		if {[catch {dict size [dict get $db $k]}]} { dict set db $k {} }
		if {$k in {games added}} {
			dict for {key rec} [dict get $db $k] { if {[catch {dict size $rec}]} { dict unset db $k $key } }
		}
	}
	# drop anything the rules do not allow
	dict for {field v} [dict get $db defaults] { if {![hud::ok $field $v]} { dict unset db defaults $field } }
	dict for {key rec} [dict get $db games] {
		dict for {field v} $rec { if {![hud::ok $field $v]} { dict unset db games $key $field } }
		if {[dict size [dict get $db games $key]] == 0} { dict unset db games $key }
	}
	return
}

# Write the file atomically (a temp name, then rename). Returns 1 or 0 (a read-only home keeps the page working).
proc hud::write_file {{path ""}} {
	variable db
	if {$path eq ""} { set path [hud::path] }
	if {[catch {
		file mkdir [file dirname $path]
		set tmp "$path.tmp"
		set f [::open $tmp w]
		::puts $f $db
		::close $f
		file rename -force $tmp $path
	}]} { return 0 }
	return 1
}

# The Defaults record, with the store applied over the built-in values.
proc hud::defaults {} {
	variable db
	set d [hud::builtin_defaults]
	dict for {f v} [dict get $db defaults] { dict set d $f $v }
	return $d
}

# A game's own fields (a dict; empty when it uses Defaults).
proc hud::own_fields {key} {
	variable db
	if {[dict exists $db games $key]} { return [dict get $db games $key] }
	return {}
}

# The value in effect for KEY: the game's own field, else the Defaults record.
proc hud::effective {key field} {
	set own [hud::own_fields $key]
	if {[dict exists $own $field]} { return [dict get $own $field] }
	dict get [hud::defaults] $field
}

# Set a field for a game (writes the override). An invalid value is refused and nothing changes.
proc hud::put {key field value} {
	variable db
	if {$field ni $::hud::fields || ![hud::valid $field $value]} { return 0 }
	set own [hud::own_fields $key]
	dict set own $field $value
	dict set db games $key $own
	return 1
}

# Remove one field's override, so the row follows Defaults again (the reset button).
proc hud::drop {key field} {
	variable db
	if {![dict exists $db games $key]} return
	set own [dict get $db games $key]
	dict unset own $field
	if {[dict size $own] == 0} { dict unset db games $key } else { dict set db games $key $own }
}

# Reset to defaults: the game's record is cleared (its hidden flag is a list setting and stays).
proc hud::reset {key} {
	variable db
	dict unset db games $key
}

# Set one Defaults field.
proc hud::put_default {field value} {
	variable db
	if {$field ni $::hud::fields || ![hud::valid $field $value]} { return 0 }
	dict set db defaults $field $value
	return 1
}

# The contents set in effect for KEY, as the names that are on.
proc hud::contents_on {key} { hud::effective $key contents }

# Turn one contents item on or off for KEY. Contents is overridden as one set, so the first change
# copies the whole effective set into the game's record.
proc hud::contents_toggle {key name} {
	variable contents_all
	if {$name ni $contents_all} return
	set on [hud::contents_on $key]
	if {$name in $on} { set on [lsearch -all -inline -not -exact $on $name] } else { lappend on $name }
	set ordered {}
	foreach n $contents_all { if {$n in $on} { lappend ordered $n } }
	hud::put $key contents $ordered
}

# How many fields this game overrides ("N own settings").
proc hud::own_count {key} { dict size [hud::own_fields $key] }

proc hud::is_hidden {key} {
	variable db
	expr {[dict exists $db hidden $key] && [dict get $db hidden $key] eq "1"}
}

proc hud::set_hidden {key flag} {
	variable db
	if {$flag} { dict set db hidden $key 1 } else { dict unset db hidden $key }
}

# A game's state, as its list line and page tag read it: hidden, off (its overlay is off), own, or defaults.
proc hud::state {key} {
	if {[hud::is_hidden $key]} { return hidden }
	if {![hud::effective $key on]} { return off }
	if {[hud::own_count $key] > 0} { return own }
	return defaults
}

# The list line's second text for a state.
proc hud::state_text {key} {
	switch -- [hud::state $key] {
		hidden { return Hidden }
		off { return {Overlay off} }
		own { set n [hud::own_count $key]; return [expr {$n == 1 ? "1 own setting" : "$n own settings"}] }
		default { return {Uses defaults} }
	}
}

# Games added by hand: KEY is path:PROGRAM. Returns the key.
proc hud::add_game {name program art} {
	variable db
	set key path:$program
	dict set db added $key [dict create name $name program $program art $art]
	return $key
}

proc hud::remove_game {key} {
	variable db
	dict unset db added $key
	dict unset db games $key
	dict unset db hidden $key
}

# The hand-added games: a dict of KEY -> {name program art}.
proc hud::added {} {
	variable db
	dict get $db added
}

# Only what the page needs in one call: the Defaults' fields in order, as {field value}.
proc hud::default_rows {} {
	set d [hud::defaults]
	foreach f $::hud::fields { lappend rows [list $f [dict get $d $f]] }
	return $rows
}

# The header counts: games, own settings, off. KEYS is every known game key.
proc hud::counts {keys} {
	set own 0; set off 0
	foreach k $keys {
		if {[hud::own_count $k] > 0} { incr own }
		if {![hud::effective $k on]} { incr off }
	}
	list [llength $keys] $own $off
}

# Rename a game added by hand (its key, its record and its flags stay).
proc hud::rename_game {key name} {
	variable db
	if {[dict exists $db added $key]} { dict set db added $key name $name }
}

# Set the art of a game added by hand ("" for none).
proc hud::set_art {key art} {
	variable db
	if {[dict exists $db added $key]} { dict set db added $key art $art }
}
