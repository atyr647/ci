# settings-games-scene.tcl - Settings → Game overlay in the eight board states (HUD-Settings-B-1…8), under xvfb.
# Loaded by apps/settings/main.tcl with RIBBON_SETTINGS_SCENE set. The data is the boards' own (names and settings), so
# the states match the boards; no launcher is read. RIBBON_GAMES_SHOTS (a folder) gets one PNG per state, the whole root
# window (crop to the window at 170,104); RIBBON_GAMES_RESULT gets one "ok" or "FAIL" line per state.
proc bgerror {msg} { catch {gscene::note "FAIL background error: $msg"}; exit 3 }
namespace eval gscene {
	variable out ""
	variable shots ""
	variable i 0
	variable fails 0
	variable sel ""
}

# the eleven games of boards 1 to 5 and 8 (Elden Ring, Cyberpunk and the rest), and the 34 of boards 6 and 7
proc gscene::games {many} {
	set g {}
	foreach {k n} {
		steam:1245620 {Elden Ring} steam:1091500 {Cyberpunk 2077} steam:1086940 {Baldur's Gate 3}
		steam:1091600 {Star Citizen} steam:1196590 {The Witcher 3} steam:1030300 {Hades II} steam:1800 {Control}
		steam:2344520 {Diablo IV} path:/home/user/Games/Celeste/Celeste {Celeste} steam:367520 {Hollow Knight} steam:1638650 {Balatro}
	} {
		lappend g [dict create key $k name $n source [expr {[string match path:* $k] ? "added" : "steam"}] art "" played [expr {1763000000 - [llength $g] * 90000}] playtime [expr {[llength $g] * 137}]]
	}
	if {$many} {
		foreach n {{Hogwarts Legacy} {Horizon Zero Dawn} {Ghost of Tsushima} {Disco Elysium} {Deep Rock Galactic} {Portal 2} {Stardew Valley} {Slay the Spire} {Factorio} {Hades}} {
			lappend g [dict create key steam:x[llength $g] name $n source steam art "" played [expr {1762000000 - [llength $g] * 60000}] playtime [expr {[llength $g] * 41}]]
		}
		while {[llength $g] < 34} {
			lappend g [dict create key steam:x[llength $g] name "Game [llength $g]" source steam art "" played [expr {1761000000 - [llength $g] * 50000}] playtime [expr {[llength $g] * 23}]]
		}
	}
	return $g
}

# the store for each state: the Elden Ring own set (5), Witcher 1, Star Citizen 3, Balatro 1, Celeste off
proc gscene::store {own} {
	set games [dict create \
		steam:1245620 {layout full pos bl scale 90 transp 30 source compositor} \
		steam:1091600 {layout compact scale 150 source compositor} \
		steam:1196590 {scale 125} \
		steam:1638650 {contents {frametime low1 graph gamename gpu vram cpu mem power net clock}} \
		path:/home/user/Games/Celeste/Celeste {on 0}]
	if {$own} { dict set games steam:x1 {scale 90} }
	dict create defaults {} games $games hidden {} added {path:/home/user/Games/Celeste/Celeste {name Celeste program /home/user/Games/Celeste/Celeste art {}}}
}

proc gscene::state {n} {
	variable sel
	set ::hud::db [gscene::store 0]
	set ::games::games [gscene::games [expr {$n == 6 || $n == 7}]]
	set ::games::scanned 1
	set ::games::top 0
	set ::games::menu ""
	set ::games::sheet ""
	set ::games::query ""
	ui::fset gsearch ""
	set ::games::show all
	set ::games::sort played
	switch -- $n {
		1 { set ::games::sel defaults }
		2 { set ::games::sel steam:1245620 }
		3 { set ::games::sel steam:1091500 }
		4 { set ::games::sel path:/home/user/Games/Celeste/Celeste }
		5 { set ::games::sel steam:1091500; set ::games::sheet add
			ui::fset sheet_prog {~/Games/OuterWilds/OuterWilds.x86_64}; ui::fset sheet_name {Outer Wilds} }
		6 { set ::games::sel steam:1638650; set ::games::menu sort; set ::games::sort played }
		7 { set ::games::sel steam:1638650; set ::games::query ho; ui::fset gsearch ho }
		8 { set ::games::sel steam:1030300; dict set ::hud::db hidden steam:1030300 1 }
	}
	# the rows that follow the boards: state 6 shows its own counts (7 own)
	if {$n == 6 || $n == 7} { dict set ::hud::db games steam:x1 {scale 90} }
}

proc gscene::run {} {
	variable i
	variable out
	variable shots
	variable fails
	incr i
	if {$i > 8} {
		if {[catch {gscene::extra} err]} { gscene::note "FAIL the art and sheet checks: $err :: [string range $::errorInfo 0 400]" }
		if {$out ne ""} {
			set f [open $out a]; puts $f [expr {$fails ? "FAIL $fails" : "ok 8 states"}]; close $f
		}
		exit [expr {$fails ? 1 : 0}]
	}
	if {[catch {
		gscene::state $i
		settings::select game
		page::draw_now
		update
	} err]} {
		incr fails
		set line "FAIL state $i: $err :: [string range $::errorInfo 0 300]"
	} else {
		set line "ok state $i"
	}
	if {$out ne "" && $line ne ""} {
		set f [open $out a]; puts $f $line; close $f
	}
	if {$shots ne "" && [string match ok* $line]} {
		after 250 [list gscene::shot $i]
	} else {
		after 250 gscene::run
	}
}

proc gscene::note {line} {
	variable out
	variable fails
	if {[string match FAIL* $line]} { incr fails }
	if {$out ne ""} { set f [open $out a]; puts $f $line; close $f }
}
proc gscene::check {what cond} { gscene::note [expr {[uplevel 1 [list expr $cond]] ? "ok   $what" : "FAIL $what"}] }
proc gscene::click {x y} { page::draw_now; ui::press [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; ui::release [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; update }
proc gscene::pause {ms} { set end [expr {[clock milliseconds] + $ms}]; while {[clock milliseconds] < $end} { after 20; update } }
proc gscene::red {x y} { lassign [$::ui::img get $x $y] r g b; expr {$r > 150 && $g < 90 && $b < 90} }

# After the eight states: a game's art is drawn (list tile, head tile, preview), the Add
# sheet's Art "Choose…" stores the picture, the sheet has no placeholders, the Shortcut row has no button that does
# nothing, and a change tells the HUD (ribbon-hud reload).
proc gscene::extra {} {
	set T [file dirname $::env(RIBBON_GAMES_CONF)]
	file mkdir $T
	# a red picture, 60 x 90 like Steam's library art; a JPEG when ffmpeg is here (Steam's art is JPEG)
	set ph [image create photo -width 60 -height 90]
	$ph put #c81e1e -to 0 0 60 90
	set art $T/art.png
	$ph write $art -format png
	if {[auto_execok ffmpeg] ne "" && ![catch {exec ffmpeg -nostdin -v error -y -i $art $T/art.jpg </dev/null >/dev/null 2>/dev/null}]} { set art $T/art.jpg }
	# state 2 (Elden Ring chosen, first in the list) with art
	gscene::state 2
	set g [lindex $::games::games 0]
	dict set g art $art
	lset ::games::games 0 $g
	settings::select game; page::draw_now; update
	gscene::check "a game with art: the list tile is the picture ([$::ui::img get 284 284])" {[gscene::red 284 284]}
	gscene::check "the head tile is the picture" {[gscene::red 557 56]}
	gscene::check "the preview is drawn over the art" {[gscene::red 980 120]}
	lassign [$::ui::img get 270 270] r0 g0 b0
	gscene::check "the tile's corners are rounded (the corner pixel is not the picture)" {![gscene::red 270 270]}
	gscene::check "a game without art keeps its initial on a colour" {![gscene::red 284 336]}
	gscene::check "Defaults: the Shortcut row has no button without a job" {[string first shortcut_change [info body games::draw_head]] < 0}
	# the Add sheet: Art Choose… (the file dialog stood in for), then Add game
	gscene::state 5
	set ::games::sheet_art ""
	set ::gscene::art $art
	proc ::dlg::open_file {args} { lappend ::gscene::asked [lindex $args 0]; return $::gscene::art }
	settings::select game; page::draw_now; update
	gscene::check "the sheet's fields carry no placeholder text" {[string first -ph [info body games::draw_sheet]] < 0}
	set ::gscene::art /games/OuterWilds/OuterWilds.x86_64
	gscene::click 798 305
	gscene::check "Program Choose… opens the file dialog and fills the field" {[ui::fval sheet_prog] eq "/games/OuterWilds/OuterWilds.x86_64" && [lindex $::gscene::asked end] eq "Choose a program"}
	set ::gscene::art $art
	gscene::click 798 415
	gscene::check "Art Choose… opens the file dialog and keeps the picture" {$::games::sheet_art eq $art && [lindex $::gscene::asked end] eq "Choose art"}
	page::draw_now; update
	gscene::check "the sheet shows the chosen picture" {[gscene::red 384 415]}
	gscene::click 778 490
	gscene::pause 500
	set key path:[string trim [ui::fval sheet_prog]]
	set f [open $::env(RIBBON_GAMES_CONF) r]; set text [read $f]; close $f
	gscene::check "Add game stores the art in game-overlay.conf" {[dict exists $text added $key art] && [dict get $text added $key art] eq $art}
	gscene::check "the sheet closed and the new game is in the list" {$::games::sheet eq "" && [dict size [games::find $key]] > 0}
	gscene::check "the game that was chosen is gone after the rescan: Defaults is chosen, the page draws" {$::games::sel eq "defaults"}
	if {[info exists ::env(RIBBON_HUD_CMD)]} {
		set log [lindex $::env(RIBBON_HUD_CMD) end].log
		set got ""; catch {set f [open $log r]; set got [string trim [read $f]]; close $f}
		gscene::check "the change told the HUD: ribbon-hud reload (got: $got)" {$got eq "reload"}
	}
	# the footer, left to right, as the boards have it (B-2: a Steam game with own settings; B-4: a game added by hand)
	foreach {n want} {2 {reset_all hide_game} 4 {reset_all edit_game remove_game} 8 {show_in_list}} {
		gscene::state $n
		settings::select game; page::draw_now; update
		set got {}
		foreach f [lsort -real -index 2 $::ui::focusables] {
			if {[lindex $f 0] in {reset_all hide_game edit_game remove_game show_in_list}} { lappend got [lindex $f 0] }
		}
		gscene::check "state $n: the footer's buttons left to right are $want (got $got)" {$got eq $want}
	}
	gscene::check "the footer's labels are the boards' (Add game…, Edit…)" \
		{[string first "{Add game…}" [info body games::draw_footer]] >= 0 && [string first "Edit…" [info body games::draw_footer]] >= 0}
	# B-4: the overlay off dims Show when the game starts with the rows under it (it inherits, as Layout does)
	gscene::state 4
	settings::select game; page::draw_now; update
	# a text is drawn as runs of letters: join the runs on one line (same y) in x order
	set lines {}
	foreach i [$::ui::cv find all] {
		if {[$::ui::cv type $i] ne "text"} continue
		lassign [$::ui::cv coords $i] x y
		if {$x < 690} continue
		dict lappend lines [expr {round($y)}] [list $x [$::ui::cv itemcget $i -text] [$::ui::cv itemcget $i -fill]]
	}
	set fills {}
	dict for {y runs} $lines {
		set t ""; foreach r [lsort -real -index 0 $runs] { append t [lindex $r 1] }
		if {[string match "Show*" $t] || [string match "Layout*" $t]} { lappend fills $t [lindex $runs 0 2] }
	}
	gscene::check "B-4: a game's row reads Show when the game starts, dimmed like Layout ($fills)" \
		{[llength $fills] == 4 && [string match "Showwhenthegame*" [string map {" " ""} [lindex $fills 0]]] && [lindex $fills 1] eq [lindex $fills 3]}
	# B-6: the sort menu covers the list: a layer above the rows' text (canvas items)
	gscene::state 6
	settings::select game; page::draw_now; update
	set all [$::ui::cv find all]
	set row -1
	foreach i $all { if {[$::ui::cv type $i] eq "text" && [string match Eld* [$::ui::cv itemcget $i -text]]} { set row [lsearch $all $i]; break } }
	set top [lsearch $all [lindex [$::ui::cv find withtag top] 0]]
	gscene::check "B-6: the sort menu is a layer above the list's rows (row text $row, menu layer $top)" {$row >= 0 && $top > $row}
	lassign [$::ui::img get 270 312] r g b
	gscene::check "B-6: the chosen sort item is on a field box ([format #%02x%02x%02x $r $g $b], field $::ui::c(field))" {[format #%02x%02x%02x $r $g $b] eq [string tolower $::ui::c(field)]}
	hud::put_default layout full; hud::put_default pos tr
	gscene::check "B-1: the Defaults row reads Full · top right (got [games::defaults_sub])" {[games::defaults_sub] eq "Full · top right"}
	set ::games::menu ""
	# the page's own glyphs use only the path commands raster::path draws (no s/S/q/Q/t/T: those come out as a scrawl)
	set badp {}
	foreach n {geye geyeoff gsearch gx} { if {[regexp {[^MmLlHhVvAaCcZz0-9.,\s-]} $::ui::paths($n)]} { lappend badp $n } }
	gscene::check "the page's glyphs are drawable by raster::path (bad: $badp)" {$badp eq ""}
}

proc gscene::shot {n} {
	variable shots
	catch {exec import -window root [file join $shots [format state%d.png $n]]}
	after 50 gscene::run
}

namespace eval gscene {
	variable out [expr {[info exists ::env(RIBBON_GAMES_RESULT)] ? $::env(RIBBON_GAMES_RESULT) : ""}]
	variable shots [expr {[info exists ::env(RIBBON_GAMES_SHOTS)] ? $::env(RIBBON_GAMES_SHOTS) : ""}]
}
if {$::gscene::out ne ""} { file delete -force $::gscene::out }
after 600 gscene::run
