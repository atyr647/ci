# settings-keys-scene.tcl - the Settings host's keyboard and search (main.tcl, rail.tcl), under xvfb: Appearance's
# own shortcuts act only on the Appearance page, Ctrl+Page Down and Tab/Up/Down move through the rail, the search
# field shows that it has the keyboard (accent ring, caret), Return opens the only match, and a click elsewhere
# takes the keyboard from the search. Keys go through the window's own binding (event generate), clicks through
# its canvas binding. Sourced by apps/settings/main.tcl (RIBBON_SETTINGS_SCENE);
# RIBBON_KEYS_RESULT = file for the checks. Exits 0 when all pass. Run by tests/steps.d/57-settings-keys.sh.
proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }
namespace eval ::kscene { variable fails 0; variable lines {} }
proc kscene::check {what ok} {
	variable fails; variable lines
	if {$ok} { lappend lines "ok   $what" } else { lappend lines "FAIL $what"; incr fails }
}
proc kscene::settle {} { update; page::draw_now; update }
# a key through the window's <KeyPress> binding; MODS: Control, Alt
proc kscene::key {sym {mods {}}} {
	set st 0
	if {"Control" in $mods} { incr st 4 }
	if {"Alt" in $mods} { incr st 8 }
	if {"Shift" in $mods} { incr st 1 }
	kscene::settle
	focus -force $::settings::win
	event generate $::settings::win <KeyPress> -keysym $sym -state $st -when now
	kscene::settle
}
proc kscene::type {text} { foreach ch [split $text ""] { kscene::key $ch } }
# a click at window coordinates through the canvas's <ButtonPress-1> binding
proc kscene::click {x y} {
	kscene::settle
	event generate $::ui::cv <ButtonPress-1> -x [expr {$x + $::ui::ox}] -y [expr {$y + $::ui::oy}] -when now
	event generate $::ui::cv <ButtonRelease-1> -x [expr {$x + $::ui::ox}] -y [expr {$y + $::ui::oy}] -when now
	kscene::settle
}
# the red channel of the search field's ring, at its left edge (accent: high; the border: low)
proc kscene::ring_red {} { kscene::settle; lindex [$::ui::img get 16 97] 0 }
proc kscene::next_of {id} { set ids [settings::ids]; lindex $ids [expr {[lsearch -exact $ids $id] + 1}] }

proc kscene::run {} {
	settings::select power
	kscene::settle
	set page0 $::page::S(page)
	kscene::key 3 Alt
	kscene::check "Alt+3 on Power opens nothing of Appearance's (the background picker stays shut, Power stays)" \
		[expr {!$::os::S(open) && $::settings::sel eq "power" && $::page::S(page) eq $page0}]
	kscene::key Escape
	kscene::check "Escape on Power stays on Power" [expr {$::settings::sel eq "power" && !$::os::S(open)}]
	set want [kscene::next_of power]
	kscene::key Next Control
	kscene::check "Ctrl+Page Down moves down the Settings rail (power -> $want)" [expr {$::settings::sel eq $want && !$::os::S(open)}]
	kscene::key Prior Control
	kscene::check "Ctrl+Page Up moves back up (power)" [expr {$::settings::sel eq "power"}]
	kscene::key Next Control
	kscene::key Next Control
	kscene::check "Ctrl+Page Down twice opens no Appearance page" [expr {!$::os::S(open) && $::settings::sel ne "appearance"}]

	# Tab goes through the page, then the search field and the rail: Shift+Tab from nothing is the rail, then the search
	settings::select power
	set ::ui::focus ""
	kscene::key Tab Shift
	kscene::check "Shift+Tab reaches the rail (after the page's controls)" [expr {$::ui::focus eq "rail"}]
	kscene::key Tab Shift
	kscene::check "Shift+Tab again reaches the search field" [expr {$::ui::focus eq "search"}]
	kscene::key Tab
	kscene::check "Tab from the search field is the rail" [expr {$::ui::focus eq "rail"}]
	kscene::key Down
	kscene::check "Down on the rail chooses the next item ($want), and the rail keeps the keyboard" \
		[expr {$::settings::sel eq $want && $::ui::focus eq "rail"}]
	kscene::key Up
	kscene::check "Up on the rail goes back (power)" [expr {$::settings::sel eq "power"}]

	# the search field reached by the keyboard takes what is typed, as a click on it does
	settings::select power
	set ::ui::focus ""
	kscene::key Tab Shift
	kscene::key Tab Shift
	kscene::type blu
	kscene::check "typing on the search field reached by Tab goes to the query (blu), with its ring and caret" \
		[expr {$::settings::query eq "blu" && $::settings::searching && [kscene::ring_red] > 150 && [llength [$::ui::cv find withtag caret]] > 0}]
	settings::set_query ""
	set ::ui::focus ""
	settings::select power

	# the search field: a click gives it the keyboard; it shows that (accent ring, caret)
	set off [kscene::ring_red]
	kscene::click 100 97
	set on [kscene::ring_red]
	kscene::check "a click on the search field gives it the keyboard" [expr {$::settings::searching}]
	kscene::check "the focused search field has the accent ring (red $on, not $off) and a caret" \
		[expr {$on > 150 && $off < 120 && [llength [$::ui::cv find withtag caret]] > 0}]
	kscene::type bluet
	kscene::check "typing goes to the query (bluet: one match)" [expr {$::settings::query eq "bluet" && [settings::matching bluet] eq "bluetooth"}]
	kscene::key Return
	kscene::check "Return opens the only match (Bluetooth) and clears the search" \
		[expr {$::settings::sel eq "bluetooth" && $::settings::query eq "" && !$::settings::searching}]

	# a click elsewhere takes the keyboard from the search: typing no longer goes to the query
	settings::select power
	kscene::click 100 97
	kscene::type ab
	kscene::click 600 400
	kscene::check "a click on the page takes the keyboard from the search" [expr {!$::settings::searching}]
	kscene::type xy
	kscene::check "after it, typing leaves the query as it was (ab)" [expr {$::settings::query eq "ab"}]
	kscene::check "and the field no longer shows the accent ring" [expr {[kscene::ring_red] < 120}]
	# Tab out of the search leaves it too
	kscene::click 100 97
	kscene::key Tab
	kscene::check "Tab takes the keyboard from the search" [expr {!$::settings::searching}]

	# a page's modal sheet (Display's keep-or-revert, which blocks clicks on the rail) keeps the keyboard too: Tab does
	# not reach the search or the rail behind it, and Ctrl+Page Down does not leave the page
	set ::display::asked 1
	set fh [open [file join $::env(RIBBON_FIXTURES) display-outputs.json]]; set ::display::outs [display::parse [read $fh]]; close $fh
	set ::display::loaded 1
	settings::select display
	set ::display::sheet 1
	kscene::settle
	set ids [lmap f $::ui::focusables { lindex $f 0 }]
	kscene::key Tab
	kscene::key Tab
	set f2 $::ui::focus
	kscene::key Next Control
	kscene::check "under Display's keep sheet the rail and the search take no keyboard (stops: $ids; Tab twice: $f2)" \
		[expr {"rail" ni $ids && "search" ni $ids && $f2 ni {rail search} && $::settings::sel eq "display" && !$::os::S(open)}]
	set ::display::sheet 0
	set ::ui::focus ""

	# on the Appearance page its own shortcuts still act: Alt+2 is Colours
	settings::set_query ""
	set ::settings::searching 0
	settings::select appearance
	kscene::key 2 Alt
	kscene::check "on Appearance, Alt+2 still opens Colours" [expr {$::settings::sel eq "appearance" && $::page::S(page) eq "colours"}]
	# Appearance's Ctrl+S (save the colours being edited) is Appearance's only: on Power, with Colours the Appearance
	# page left behind, it saves (or, over a built-in theme, makes) no theme
	set ::kscene::saves 0
	rename ::page::save ::page::kscene_real_save
	proc ::page::save {args} { incr ::kscene::saves; ::page::kscene_real_save {*}$args }
	settings::select power
	kscene::key s Control
	kscene::check "Ctrl+S on Power saves no Appearance theme (saves: $::kscene::saves)" [expr {$::kscene::saves == 0}]
	settings::select appearance
	kscene::check "(Appearance's page is still Colours)" [expr {$::page::S(page) eq "colours"}]
	rename ::page::save {}
	rename ::page::kscene_real_save ::page::save

	variable lines
	if {[info exists ::env(RIBBON_KEYS_RESULT)]} { set fh [open $::env(RIBBON_KEYS_RESULT) w]; puts $fh [join $lines \n]; close $fh }
	puts [join $lines \n]
	exit [expr {$::kscene::fails ? 1 : 0}]
}
after 300 kscene::run
