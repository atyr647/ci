# Settings → Game overlay, the store and detection (U20): the defaults/own fallback, reset, contents as one
# set, hidden, hand-added games, the file round trip, and detection on each launcher's fixture. Pure Tcl (no Tk).
# Usage: tclsh8.6 tests/settings-games.tcl REPO_ROOT. Nothing here touches the network.
set repo [lindex $argv 0]
set app [file join $repo srcpkgs ribbon-desktop files apps settings]
source -encoding utf-8 [file join $app games.tcl]
source -encoding utf-8 [file join $app hudstore.tcl]

set fails 0
proc check {label ok} {
	if {$ok} { puts "  ok   $label" } else { puts "  FAIL $label"; incr ::fails }
}

# a temp home with the fixtures copied in and @HOME@ replaced by that home
set tmp [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] ribbon-games-[pid]]
file delete -force $tmp
file mkdir $tmp/home
set src [file join $repo tests fixtures launchers]
foreach root [glob -nocomplain [file join $src *]] {
	set name [file tail $root]
	foreach f [split [exec find $root -type f] "\n"] {
		if {$f eq ""} continue
		# the path under the fixture root, relative (a leading / would make file join drop $tmp)
		set rel [string trimleft [string range $f [string length $root] end] /]
		set dst [file join $tmp home $rel]
		if {![string match "$tmp/home/*" $dst]} { puts "  FAIL fixture path escapes the temp home: $dst"; exit 1 }
		file mkdir [file dirname $dst]
		set in [open $f r]; fconfigure $in -encoding utf-8; set text [read $in]; close $in
		if {[string match *.jpg $f]} { set out [open $dst w] ; close $out; continue }
		regsub -all {@HOME@} $text [file join $tmp home] text
		set out [open $dst w]; fconfigure $out -encoding utf-8; puts -nonewline $out $text; close $out
	}
}
set home [file join $tmp home]

# ---- detection ----------------------------------------------------------------------------------
puts "detection"
set games [gdetect::all $home]
set byKey {}
foreach g $games { dict set byKey [dict get $g key] $g }
set keys [lsort [dict keys $byKey]]
check "every launcher's games are found (Steam 3, Heroic 2, Lutris 2)" \
	[expr {$keys eq {heroic:1207658924 heroic:Ori2 lutris:celeste lutris:outer-wilds steam:1091500 steam:1245620 steam:620}}]
check "Steam: name from the appmanifest" [expr {[dict get $byKey steam:1245620 name] eq "ELDEN RING"}]
check "Steam: a second library folder is read" [expr {[dict get $byKey steam:1091500 name] eq "Cyberpunk 2077"}]
check "Steam: play time from localconfig (2472 min = 41 h 12 min)" \
	[expr {[expr {[gdetect::playtime_text [dict get $byKey steam:1245620 playtime]] eq "41 h 12 min"}]}]
check "Steam: last played from the appmanifest, as epoch seconds" [expr {[dict get $byKey steam:1245620 played] == 1763669160}]
check "Steam: art found in the library cache" [file isfile [dict get $byKey steam:1245620 art]]
check "Steam: no art means an empty path" [expr {[dict get $byKey steam:620 art] eq ""}]
check "Heroic GOG: title from the library cache when installed.json has none" \
	[expr {[dict get $byKey heroic:1207658924 name] eq "The Witcher 3: Wild Hunt"}]
check "Heroic Epic: title from legendary's installed.json" \
	[expr {[dict get $byKey heroic:Ori2 name] eq "Ori and the Will of the Wisps"}]
check "Lutris: name and slug from the game file" [expr {[dict get $byKey lutris:celeste name] eq "Celeste"}]
check "Lutris: a file without slug takes its slug from the file name" \
	[dict exists $byKey lutris:outer-wilds]
check "Lutris: quoted names are unquoted" [expr {[dict get $byKey lutris:outer-wilds name] eq "Outer Wilds"}]
check "the whole list is read without error when a file is missing" \
	[expr {[expr {[llength [gdetect::all [file join $tmp nowhere]]] == 0}]}]

# a broken JSON or VDF file gives nothing rather than an error
file mkdir $tmp/broken/.config/heroic/gog_store
set bf [open $tmp/broken/.config/heroic/gog_store/installed.json w]; puts $bf "\[\{\"installed\": \[ \{\"appName\": \}"; close $bf
check "a broken Heroic file gives no games" [expr {[llength [gdetect::all $tmp/broken]] == 0}]

# ---- store: fallback, own settings, reset --------------------------------------------------------
puts "store"
set ::env(RIBBON_GAMES_CONF) [file join $tmp game-overlay.conf]
hud::read_file
check "defaults are the board's (Full, top right, 14 %, Automatic)" [expr {[hud::effective elden on] == 1 && [hud::effective elden layout] eq "full" && [hud::effective elden pos] eq "tr" && [hud::effective elden transp] == 14 && [hud::effective elden source] eq "auto"}]
check "a game with nothing set uses defaults" [expr {[hud::state elden] eq "defaults"}]
check "its text reads Uses defaults" [expr {[hud::state_text elden] eq "Uses defaults"}]

hud::put elden scale 125
check "changing a row writes that game's override" [expr {[hud::effective elden scale] == 125}]
check "the override counts as one own setting" [expr {[hud::state_text elden] eq "1 own setting"}]
check "another game still has the default scale" [expr {[hud::effective cyber scale] == 100}]
hud::put_default scale 150
check "a changed default reaches games without their own scale" [expr {[hud::effective cyber scale] == 150}]
check "...and not the game that set its own" [expr {[hud::effective elden scale] == 125}]

hud::drop elden scale
check "resetting a row deletes that field, so it follows defaults" [expr {[hud::effective elden scale] == 150}]
check "with no fields left, the record is gone" [expr {[hud::own_count elden] == 0}]

hud::put elden layout compact
hud::put elden pos bl
hud::reset elden
check "reset to defaults clears the game's record" [expr {[hud::own_count elden] == 0}]
check "after the reset the layout is the default again" [expr {[hud::effective elden layout] eq "full"}]

check "an invalid value is refused and nothing changes" \
	[expr {[expr {![hud::put elden scale 80] && [hud::effective elden scale] == 150}]}]
check "an unknown field is refused" [expr {![hud::put elden colour red]}]

# ---- contents: one set --------------------------------------------------------------------------
puts "contents"
check "contents start as the Defaults set (Disk and Clock off)" \
	[expr {"disk" ni [hud::contents_on elden] && "clock" ni [hud::contents_on elden] && "frametime" in [hud::contents_on elden]}]
hud::contents_toggle elden clock
check "toggling one item overrides the whole set" [expr {[hud::own_fields elden] ne ""}]
check "that item is now on" [expr {"clock" in [hud::contents_on elden]}]
check "the other items keep their default state" [expr {"cpu" in [hud::contents_on elden] && "disk" ni [hud::contents_on elden]}]
check "contents is one field: its override counts once" [expr {[hud::own_count elden] == 1}]
hud::contents_toggle elden clock
check "toggling it back removes it from the set" [expr {"clock" ni [hud::contents_on elden]}]
check "a default contents change does not reach a game with its own set" \
	[expr {[expr {[hud::put_default contents {frametime}] == 1 && "gpu" in [hud::contents_on elden] }]}]
hud::put_default contents {frametime low1 graph gamename gpu vram cpu mem power net}

# ---- off, hidden, added -------------------------------------------------------------------------
puts "off, hidden, added"
hud::put cyber on 0
check "an overlay turned off reads Overlay off" [expr {[hud::state_text cyber] eq "Overlay off"}]
check "the header counts off games" [expr {[lindex [hud::counts {elden cyber}] 2] == 1}]
hud::put cyber on 1
hud::set_hidden steam:620 1
check "a hidden game reads Hidden" [expr {[hud::state_text steam:620] eq "Hidden"}]
hud::put steam:620 scale 90
hud::reset steam:620
check "resetting a hidden game keeps it hidden (the flag is a list setting)" [hud::is_hidden steam:620]
hud::set_hidden steam:620 0
check "showing it again" [expr {![hud::is_hidden steam:620]}]
set k [hud::add_game Outer\ Wilds /games/OuterWilds/OuterWilds.x86_64 ""]
check "a game added by hand is keyed by its program" [expr {$k eq "path:/games/OuterWilds/OuterWilds.x86_64"}]
check "it is listed in the added set with its name" \
	[expr {[dict get [hud::added] $k name] eq "Outer Wilds"}]
hud::put $k layout fps
hud::remove_game $k
check "removing a game drops its record too" [expr {[expr {![dict exists [hud::added] $k] && [hud::own_count $k] == 0}]}]

# ---- file round trip and bad files --------------------------------------------------------------
puts "file"
hud::put elden layout compact
hud::set_hidden steam:620 1
hud::put_default transp 30
check "the store writes its file" [hud::write_file]
set before [list [hud::effective elden layout] [hud::effective cyber scale] [hud::is_hidden steam:620] [hud::effective elden transp]]
hud::read_file
set after [list [hud::effective elden layout] [hud::effective cyber scale] [hud::is_hidden steam:620] [hud::effective elden transp]]
check "a read gives back what was written" [expr {$before eq $after}]
check "the file is one Tcl dict, not code" [expr {![catch {dict size [::read [::open $::env(RIBBON_GAMES_CONF)]]}]}]

set bad [open $::env(RIBBON_GAMES_CONF) w]; puts $bad {defaults {on 1 layout spiral transp 900 bogus 1} games {elden {layout spiral contents {nope}} cyber {scale 100}} hidden {}}; close $bad
hud::read_file
check "a bad value in the file falls back to the default" [expr {[hud::effective elden layout] eq "full"}]
check "an out-of-range value falls back to the default" [expr {[hud::effective elden transp] == 14}]
check "a bad contents name is dropped" [expr {[hud::own_count elden] == 0}]
check "a good value in the file is kept" [expr {[hud::effective cyber scale] == 100}]

set bad [open $::env(RIBBON_GAMES_CONF) w]; puts -nonewline $bad "defaults {} games {elden {layout"; close $bad
hud::read_file
check "a truncated file gives the built-in defaults, without an error" [expr {[hud::effective elden layout] eq "full"}]

set bad [open $::env(RIBBON_GAMES_CONF) w]; puts $bad {[exit 3]}; close $bad
hud::read_file
check "a file that is not a dict is never run" [expr {[hud::effective elden layout] eq "full"}]

hud::put elden layout compact
hud::set_hidden steam:620 1
check "states read as their tags: a game with its own settings is not Uses defaults, a hidden one is Hidden" [expr {[hud::state_text elden] ne "Uses defaults" && [hud::state_text steam:620] eq "Hidden"}]

file delete -force $tmp
if {$fails} { puts "settings-games: $fails failed"; exit 1 }
puts "settings-games: all checks passed"
