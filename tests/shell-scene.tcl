# shell-scene.tcl - put the Ribbon shell into one of the mockup scenes, for
# screenshots and pixel comparison (RIBBON_SHELL_TEST=this file).
#   RIBBON_SCENE = idle | floating | launcher | maximized | menu | field-*
set scene [expr {[info exists ::env(RIBBON_SCENE)] ? $::env(RIBBON_SCENE) : "floating"}]

# windows and workspaces as in the mockup
array set wm::tl {
	1 {app RibbonFiles title Downloads state {}}
	2 {app foot title Terminal state {}}
	3 {app steam title Steam state {}}
	4 {app firefox title {GitHub - atyr647/ribbon — Mozilla Firefox} state {}}
}
set wm::order {1 2 3 4}
array set wm::ws {1 {name 1 active 1} 2 {name 2 active 0} 3 {name 3 active 0}}
set wm::wsorder {1 2 3}
# wsmid: the second workspace is the one you are on (the switcher's part 2), with a window in use
if {$scene eq "wsmid"} { array set wm::ws {1 {name 1 active 0} 2 {name 2 active 1} 3 {name 3 active 0}} }
# notasks: no window open, so the dock draws its empty, see-through branch
if {$scene eq "notasks"} { array unset wm::tl; set wm::order {} }
switch -glob -- $scene {
	floating - fmenu - wmenu - tray - wsmid - noupdates - session - powerhover { dict set wm::tl(1) state act }
	maximized - wctl { dict set wm::tl(1) state act,max }
}
wm::changed

# status as in the mockup
set status::wifi on
set status::volume 0.50
set status::battery 82
set status::updates 3
# noupdates: nothing waiting, so the bar has no updates chip
if {$scene eq "noupdates"} { set status::updates 0 }
set status::date "Sun 31 May"
set status::time 00:27

# apps as in the mockup's launcher
set apps::loaded 1
set apps::list {}
foreach {id name comment cats} {
	steam Steam {Game library and store} Game
	rsi {Star Citizen} {RSI Launcher} Game
	strawberry Strawberry {Music player} {AudioVideo;Audio;Player}
	sysmon {System Monitor} {Processes and resources} {System;Monitor}
	firefox Firefox {Browse the web} {Network;WebBrowser}
	foot Terminal {Command line} {System;TerminalEmulator}
} {
	set a [dict create id $id name $name generic "" comment $comment exec true cats $cats wmclass "" terminal 0]
	lappend apps::list $a
	set apps::byid($id) $a
}
array unset apps::usage
array set apps::usage {steam 3 rsi 2 strawberry 1}

# freeze the idle animation on "Steam", holding, cursor on
proc launcher::anim_sync {} {}
set launcher::words {Firefox Steam {Star Citizen} Terminal Files Settings}
set launcher::anim {wi 1 len 5 phase hold t 2}

# a real Ribbon Files window where the mockup has its window (below the
# 40 px title bar labwc would draw); RIBBON_SCENE_FILES=0 skips it
if {$scene in {floating maximized files fmenu wctl wsmid noupdates} && (![info exists ::env(RIBBON_SCENE_FILES)] || $::env(RIBBON_SCENE_FILES))} {
	set d [file join $::env(HOME) Downloads]
	file mkdir $d
	foreach f {Games Screenshots Mods Proton-GE} { file mkdir $d/$f }
	foreach f {RSI-Setup.exe ribbon-0.1.iso wallpaper.png patch-notes.md soundtrack.flac} { if {![file exists $d/$f]} { close [open $d/$f w] } }
	set fw [files::show $d]
	wm geometry $fw [expr {$scene in {maximized wctl} ? "1440x792+0+54" : "840x540+232+168"}]
	set files::st($fw,sel) RSI-Setup.exe; set files::st($fw,anchor) RSI-Setup.exe
	set files::current $fw
	after 300 [list files::draw $fw]
}

# the system behind the right bar's panels, answering like the mockup, through the panels' own reading code:
# Sound and Power run their tools (panel::spawn answers each command with the tool's output, so got_sound and
# got_power parse it), Wi-Fi reads NetworkManager's model (as apps/settings/nm.tcl returns it; nm_changed turns
# it into the rows) and Bluetooth BlueZ's managed objects (bz_store). An action a click runs answers empty.
set status::bt on
proc panel::scene_out {cmd} {
	switch -- $cmd {
		"pactl get-default-sink" { return alsa_output.speakers }
		"pactl list sinks" { return "Sink #1\n\tName: alsa_output.speakers\n\tDescription: Speakers\nSink #2\n\tName: bluez_output.headset\n\tDescription: WH-1000XM5\nSink #3\n\tName: alsa_output.hdmi\n\tDescription: LG UltraGear (HDMI)" }
		"wpctl get-volume @DEFAULT_AUDIO_SINK@" { return "Volume: 0.64" }
		"wpctl get-volume @DEFAULT_AUDIO_SOURCE@" { return "Volume: 0.80" }
		"powerprofilesctl get" { return balanced }
		"brightnessctl -m" { return "intel_backlight,backlight,700,70%,1000" }
	}
	return ""
}
proc panel::spawn {kind cmd done} {
	after 0 [list {*}$done 1 [panel::scene_out $cmd]]
	return ""
}
namespace eval ::nm {}
proc panel::nm_load {} {
	set aps {}
	set n 0
	# ssid strength rsn (0x100 PSK; 0 open) privacy frequency active
	foreach {ssid strength rsn priv freq on} {
		Hearth 92 0x100 1 5180 1  Hearth-Guest 88 0x100 1 2437 0  Ludo_2.4 55 0x100 1 2412 0  {Cafe Lumen} 20 0 0 2462 0
	} {
		binary scan [encoding convertto utf-8 $ssid] cu* bytes
		lappend aps [dict create path /org/freedesktop/NetworkManager/AccessPoint/[incr n] bytes $bytes ssid $ssid \
			strength $strength flags $priv wpa 0 rsn $rsn freq $freq active $on]
	}
	set ::nm::model [dict create wifi 1 error "" active {} \
		devices [list [dict create path /org/freedesktop/NetworkManager/Devices/0 iface wlan0 type 2 aps $aps]] \
		saved [list [dict create path /org/freedesktop/NetworkManager/Settings/1 id Hearth type 802-11-wireless ssid Hearth]]]
	panel::nm_changed
}
proc panel::bz_load {} {
	set A /org/bluez/hci0
	set objs [dict create / {} $A [dict create org.bluez.Adapter1 [dict create Address 00:11:22:33:44:55 Powered 1]]]
	foreach {mac alias conn icon bat} {
		AA:AA:AA:AA:AA:AA WH-1000XM5 1 audio-headset 80
		BB:BB:BB:BB:BB:BB {Xbox Wireless Controller} 1 input-gaming 55
		CC:CC:CC:CC:CC:CC {MX Master 3} 0 input-mouse {}
	} {
		set ifaces [dict create org.bluez.Device1 [dict create Address $mac Alias $alias Paired 1 Connected $conn Icon $icon]]
		if {$bat ne ""} { dict set ifaces org.bluez.Battery1 [dict create Percentage $bat] }
		dict set objs $A/dev_[string map {: _} $mac] $ifaces
	}
	panel::bz_store $objs
}
proc panel::battery {} { list 82 Discharging "3 h 40 min left" }
proc panel::bg {kind args} {}

# RIBBON_SCENE_DUMP=FILE: once the scene is drawn, the open panel's rows as panel::blocks builds them from its data
# ("block ..." lines) and its drawn text, one line per text line on the canvas ("text ..."), for
# tests/steps.d/46-shell-scene-data.sh
proc scene_dump {file} {
	set fh [open $file w]; fconfigure $fh -encoding utf-8
	if {$panel::open ne ""} { foreach b [panel::blocks $panel::open] { puts $fh "block $b" } }
	set runs {}
	if {[winfo exists .panel.c]} {
		foreach i [.panel.c find all] {
			if {[.panel.c type $i] ne "text"} continue
			lassign [.panel.c bbox $i] x0 y0 x1 y1
			lappend runs [list [expr {round([lindex [.panel.c coords $i] 1])}] $x0 $x1 [.panel.c itemcget $i -text]]
		}
	}
	set line ""; set ly ""; set lx ""
	foreach r [lsort -integer -index 0 [lsort -integer -index 1 $runs]] {
		lassign $r y x0 x1 t
		if {$y ne $ly} { if {$ly ne ""} { puts $fh "text $line" }; set line $t; set ly $y; set lx $x1; continue }
		append line [expr {$x0 - $lx > 1 ? " " : ""}] $t; set lx $x1
	}
	if {$ly ne ""} { puts $fh "text $line" }
	close $fh
}
# the dump waits (at most 30 s) until the panel is open and its reads are in (no gather pending, the D-Bus
# models stored), then writes and quits: a slow start (the scene's timers all due at once) cannot dump before the data
proc scene_dump_when_ready {file end} {
	set ready [expr {$panel::open ne "" && ![array size panel::pending] && [winfo exists .panel.c]}]
	if {!$ready && [clock milliseconds] < $end} { after 50 [list scene_dump_when_ready $file $end]; return }
	update
	scene_dump $file
	exit 0
}
if {[info exists ::env(RIBBON_SCENE_DUMP)]} {
	after 300 [list scene_dump_when_ready $::env(RIBBON_SCENE_DUMP) [expr {[clock milliseconds] + 30000}]]
}

# session: the power button's panel over a floating window (the board without the window controls);
# powerhover: the pointer on the power button (its §field fill and §fg icon)
switch -- $scene {
	sound - wifi - bt - power { after 200 [list panel::toggle $scene 1] }
	session { after 200 { panel::show session } }
	powerhover { after 200 { foreach p $bar::placed { if {[lindex $p 0] eq "power"} { bar::motion [expr {[lindex $p 1] + 15}] 27 } } } }
	wmenu { after 300 { dock::window_menu ribbonfiles 1 } }
	tray { after 200 { panel::toggle tray 1 } }
	traylow - storage {
		set status::storage {state low user_free 3435973837 system_free 19327352832 reserve 16106127360 spare present pkgcache 1288490188 snapshots_old 4}
		after 200 { panel::toggle tray 1 }
		if {$scene eq "storage"} { after 400 {
			panel::show storage
			set panel::data(clean) [list {trash Trash 2254857830} {cache {App caches} 4617089843} {pkgcache {Downloaded updates} 1288490188} {snapshots {Old snapshots} {4 snapshots}}]
			panel::draw
		} }
	}
	crowded - more { after 100 {
		set extra {mousepad gimp blender obs discord heroic}
		if {$::scene eq "more"} { lappend extra lutris krita inkscape audacity kdenlive thunderbird libreoffice vlc }
		set i 4
		foreach a $extra {
			incr i
			set wm::tl($i) [list app $a title $a state {}]; lappend wm::order $i
		}
		dict set wm::tl(1) state act
		wm::changed
		if {$::scene eq "more"} { after 300 { dock::more_menu 1 } }
	} }
	wctl { after 400 { set bar::hover close; bar::draw } }
	group - gmenu - tmenu { after 100 {
		set wm::tl(5) {app firefox title {Ribbon OS — Mozilla Firefox} state {}}
		set wm::tl(6) {app foot title {Terminal - htop} state {}}
		set wm::tl(7) {app firefox title {Void Linux — Mozilla Firefox} state {}}
		lappend wm::order 5 6 7
		dict set wm::tl(4) state act
		wm::changed
		if {$::scene eq "gmenu"} { after 300 { dock::group_menu firefox {4 5 7} } }
		if {$::scene eq "tmenu"} { after 300 { dock::window_menu steam 3 } }
	} }
	fmenu { after 700 {
		set fw $files::current
		foreach t $files::st($fw,tiles) { if {[lindex $t 4] eq "wallpaper.png"} { lassign $t x0 y0 x1 y1 } }
		files::context $fw [expr {$x0 + 50}] [expr {$y0 + 50}] [expr {[winfo rootx $fw.main] + $x0 + 50}] [expr {[winfo rooty $fw.main] + $y0 + 50}]
	} }
	wifipass { after 200 { panel::toggle wifi 1; panel::join Ludo_2.4 1; set panel::password secret12; panel::draw } }
	launcher { after 200 { launcher::start app; set launcher::query st; launcher::update_results; bar::draw } }
	menu { after 200 { launcher::menu_toggle 1 } }
	live { rename launcher::anim_sync {}; proc launcher::anim_sync {} { if {$launcher::timer eq ""} { set launcher::timer [after 60 launcher::tick] } } }
}

# for tests/run.sh: quit after drawing; any background error fails
if {[info exists ::env(RIBBON_SHELL_EXIT)]} {
	proc bgerror {msg} { puts stderr $msg; exit 1 }
	after $::env(RIBBON_SHELL_EXIT) { update; exit 0 }
}
