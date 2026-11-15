# shell-alttab-scene.tcl - the Alt+Tab switcher in one board state, headless (U17).
#   RIBBON_SHELL_TEST=this file, with ALTTAB_BOARD = apps | many | scrolled | stack | close | quit | game
#   and ALTTAB_OUT = the PNG to write (the whole screen, grabbed with import).
# The windows are fixtures from design/tools/gen_alttab.py's SIX and MANY, so each
# state matches its board's apps and order. close and quit pin the clock 70 ms into the
# leaving picture (the board's frame) and take the closed windows out of the list, as the
# watch stream would. game is a fullscreen game first (AltTab-6). The grab exits the shell.
set board [expr {[info exists ::env(ALTTAB_BOARD)] ? $::env(ALTTAB_BOARD) : "apps"}]
# app id, then its window titles, most recently used first
set six {
	{ribbonfiles {Downloads Pictures {Games SSD}}}
	{firefox {{Proton compatibility} {Build logs}}}
	{foot {~/src/ribbon}}
	{ribbon-editor {patch-notes.md}}
	{steam Library}
	{ribbon-mail Inbox}
}
set many {
	{ribbonfiles {Downloads Pictures {Games SSD} Music}}
	{firefox {{Proton compatibility} {Build logs}}}
	{foot {~/src/ribbon htop}}
	{ribbon-editor {patch-notes.md}}
	{steam Library}
	{ribbon-mail Inbox}
	{ribbon-monitor {System monitor}}
	{ribbon-notes {Alt+Tab ideas}}
	{strawberry Albums}
	{xfce4-settings-manager Display}
	{ribbon-viewer fjord.png}
	{chat-app {ribbon-dev Mentions}}
	{ribbon-calendar May}
	{vlc lake.mkv}
	{ribbon-kit Updates}
	{obs Recordings}
	{gnome-disks {Games SSD}}
	{podcasts Episodes}
	{transmission Downloads}
	{weather-app Oslo}
	{ribbon-calc Calculator}
	{blueman Devices}
}
set game {
	{cyberpunk {{Cyberpunk 2077}}}
	{firefox {{Build guide: Hades II} {Mail}}}
	{steam {Friends List}}
	{ribbon-chat games}
	{foot htop}
	{ribbonfiles Screenshots}
}
set specs $six
if {$board eq "many" || $board eq "scrolled"} { set specs $many }
if {$board eq "game"} { set specs $game }

# the windows, the first listed the most recent: its serial is the highest
array unset wm::tl
set wm::order {}
set id 0
set nwin 0
foreach spec $specs { lassign $spec app titles; incr nwin [llength $titles] }
foreach spec $specs {
	lassign $spec app titles
	foreach t $titles {
		incr id
		set st {}
		if {$board eq "game" && $id == 1} { set st {full,act} }
		set wm::tl($id) [dict create app $app title $t state $st mru [expr {$nwin + 100 - $id}]]
		lappend wm::order $id
	}
}

namespace eval scene {}
proc scene::grab {} {
	after 500 {
		exec import -window root $::env(ALTTAB_OUT)
		exit 0
	}
}

# the game board: the game's name as the board labels it, and its fullscreen focus
if {$board eq "game"} {
	namespace eval apps {}
	proc apps::label {app} { if {$app eq "cyberpunk"} { return "Cyberpunk 2077" }; return [string totitle $app] }
	set wm::focus 1
}

# a window leaving: the fixture forgets it, as the watch stream reports the window gone
proc scene::gone {ids} {
	foreach id $ids {
		unset -nocomplain ::wm::tl($id)
		set wm::order [lsearch -all -inline -not -exact $wm::order $id]
	}
}

after 100 {
	if {[catch {
		alttab::open
		switch -- $board {
			scrolled { for {set i 0} {$i < 15} {incr i} { alttab::step 1 } }
			stack { alttab::step -1; alttab::fan }
			close - quit {
				# Files is the chosen app (one back), its front window the one that leaves
				alttab::step -1
				set alttab::fake 100000
				if {$board eq "close"} {
					alttab::kill window
					scene::gone {1}
				} else {
					alttab::kill app
					scene::gone {1 2 3}
				}
				set alttab::fake 100070
			}
		}
	} err]} { puts stderr "scene: $err\n$::errorInfo"; exit 3 }
	scene::grab
}
