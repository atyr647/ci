# hud-store.tcl - the Game HUD's side of Settings → Game overlay: the store (apps/settings/hudstore.tcl, the file
# ~/.config/ribbon/game-overlay.conf) read and resolved into the HUD's own settings. No Tk.
#
# hudstore.tcl and games.tcl (the launchers' names and art) share the namespace name "hud" with this program, so they
# run in a child interpreter of their own; only values cross. The settings folder is beside this one both in the tree
# (apps/hud, apps/settings) and installed (/usr/lib/ribbon/hud, /usr/lib/ribbon/settings).
#
#   hud::store::load                 read the file (always; cheap). Returns 1 when the store's code was found
#   hud::store::changed              1 when the file is not the one last read (mtime and size)
#   hud::store::record KEY           the settings in effect for a game ("" or an unknown key: Defaults), as
#                                    {on 0|1 start 0|1 source auto|compositor layout .. position .. scale .. opacity .. contents ..}
#                                    with the last five in hud::configure's words
#   hud::store::wants_start          1 when Defaults or any game has the overlay on with "Show when a game starts"
#   hud::store::title KEY            the game's name: a game added by hand, else the launcher's; "" when unknown
#   hud::store::art KEY              its art file, "" for none
#   hud::store::programs             {KEY PROGRAM ...} of the games added by hand
#
# Store words to HUD words: pos tl/tr/bl/br -> top-left…; transp N (0…50) -> opacity 100 - N; contents low1 -> low,
# gamename -> game. Layout and scale are the same words.

namespace eval ::hud::store {
	variable here [file dirname [file normalize [info script]]]
	variable ip ""
	variable stamp ""
	variable known {}       ;# key -> {name art}, from the launchers (read when a key is first asked for)
	variable scanned 0
	variable posmap {tl top-left tr top-right bl bottom-left br bottom-right}
	variable cmap {low1 low gamename game}
}

# the child interpreter with the store's code, "" when the settings folder is not there
proc ::hud::store::interp_get {} {
	variable ip
	variable here
	if {$ip ne ""} { return $ip }
	set dir [file join [file dirname $here] settings]
	if {[info exists ::env(RIBBON_SETTINGS_DIR)]} { set dir $::env(RIBBON_SETTINGS_DIR) }
	if {![file readable [file join $dir hudstore.tcl]]} { return "" }
	set i [interp create]
	if {[catch {
		$i eval [list source -encoding utf-8 [file join $dir hudstore.tcl]]
		if {[file readable [file join $dir games.tcl]]} { $i eval [list source -encoding utf-8 [file join $dir games.tcl]] }
	}]} {
		interp delete $i
		return ""
	}
	set ip $i
	return $ip
}

proc ::hud::store::file_stamp {} {
	set i [interp_get]
	if {$i eq ""} { return "" }
	set p [$i eval hud::path]
	if {[catch {file stat $p st}]} { return none }
	return "$st(mtime) $st(size) $st(ino)"
}

proc ::hud::store::load {} {
	variable stamp
	set i [interp_get]
	if {$i eq ""} { return 0 }
	set stamp [file_stamp]
	$i eval hud::read_file
	return 1
}

proc ::hud::store::changed {} {
	variable stamp
	expr {[file_stamp] ne $stamp}
}

proc ::hud::store::record {key} {
	variable posmap
	variable cmap
	set i [interp_get]
	if {$i eq ""} {
		return [dict merge [dict create on 1 start 1 source auto] [::hud::settings_defaults]]
	}
	set r {}
	foreach f {on start layout pos scale transp source contents} {
		dict set r $f [$i eval [list hud::effective $key $f]]
	}
	set contents {}
	foreach n [dict get $r contents] { lappend contents [expr {[dict exists $cmap $n] ? [dict get $cmap $n] : $n}] }
	dict create on [dict get $r on] start [dict get $r start] source [dict get $r source] \
		layout [dict get $r layout] position [dict get $posmap [dict get $r pos]] scale [dict get $r scale] \
		opacity [expr {100 - [dict get $r transp]}] contents $contents
}

proc ::hud::store::wants_start {} {
	set i [interp_get]
	if {$i eq ""} { return 1 }
	set keys [list ""]
	foreach k [dict keys [$i eval {dict get $::hud::db games}]] { lappend keys $k }
	foreach k $keys {
		set r [record $k]
		if {[dict get $r on] && [dict get $r start]} { return 1 }
	}
	return 0
}

proc ::hud::store::programs {} {
	set i [interp_get]
	if {$i eq ""} { return {} }
	set out {}
	dict for {k a} [$i eval hud::added] {
		if {[dict exists $a program]} { lappend out $k [dict get $a program] }
	}
	return $out
}

# the launchers' games, read once and again when a key is not among them (a game installed since)
proc ::hud::store::scan {} {
	variable known
	variable scanned
	set i [interp_get]
	set known {}
	set scanned [clock seconds]
	if {$i eq "" || [$i eval {llength [info commands gdetect::all]}] == 0} return
	set home [expr {[info exists ::env(RIBBON_GAMES_HOME)] ? $::env(RIBBON_GAMES_HOME) : [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/"}]}]
	if {[catch {$i eval [list gdetect::all $home]} games]} return
	foreach g $games {
		dict set known [dict get $g key] [dict create name [dict get $g name] art [dict get $g art]]
	}
}

proc ::hud::store::lookup {key field} {
	variable known
	variable scanned
	if {$key eq ""} { return "" }
	set i [interp_get]
	if {$i ne ""} {
		set added [$i eval hud::added]
		if {[dict exists $added $key $field]} { return [dict get $added $key $field] }
	}
	if {![dict exists $known $key] && [clock seconds] - $scanned > 30} { scan }
	if {[dict exists $known $key $field]} { return [dict get $known $key $field] }
	return ""
}

proc ::hud::store::title {key} { lookup $key name }
proc ::hud::store::art {key} { lookup $key art }
