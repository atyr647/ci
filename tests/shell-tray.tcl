# shell-tray.tcl - RIBBON_SHELL_TEST hook (tests/steps.d/47-shell-tray.sh): apps' tray icons and the bar's tooltips
# in the real shell under xvfb (shell/sniwatch.tcl, tray.tcl, tooltip.tcl, mod-tray.tcl; boards Tray-1-Icons,
# Tray-2-Menu, Tray-3-Submenu, Tray-4-Fallback, Tooltip-1-Bar). The session bus is private; Steam and Discord are stood in for by
# tests/fixtures/sni-items.py, which speaks through GLib's D-Bus as the real apps' libraries do: Steam registers an
# object path (libappindicator) and has no Activate, Discord registers its own name (Electron) and sends pixmaps.
# Grabs of the right bar go to TRAY_SHOTS for the step to compare with the boards. A 90 s limit ends a stuck run.

set failed 0
interp bgerror {} {apply {{msg opts} { puts "  FAIL background error: [dict get $opts -errorinfo]"; exit 1 }}}
after 90000 {puts "  FAIL the tray checks took more than 90 s"; exit 1}
proc ok {what} { puts "  ok   $what" }
proc bad {what why} { global failed; incr failed; puts "  FAIL $what: $why" }
proc check {what cond why} { if {$cond} { ok $what } else { bad $what $why } }
proc wait {cond {ms 5000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 [list expr $cond]]} {
		if {[clock milliseconds] > $end} { return 0 }
		after 20 {set ::tick 1}; vwait ::tick
	}
	return 1
}
proc pause {ms} { after $ms {set ::tick 1}; vwait ::tick }
proc slurp {f} { if {[catch {open $f} fh]} { return "" }; set t [read $fh]; close $fh; return $t }
proc logged {} { split [string trim [slurp $::LOG]] \n }
proc logged_has {pat} { expr {[lsearch -glob [logged] $pat] >= 0} }

# the shell as the boards have it: three workspaces, Wi-Fi on, the clock at 21:12, no window
array set wm::ws {1 {name 1 active 1} 2 {name 2 active 0} 3 {name 3 active 0}}
set wm::wsorder {1 2 3}
wm::changed
set status::wifi on
set status::volume ""
set status::battery 0
set status::updates 0
set status::date "Sat 7 Nov"
set status::time 21:12
proc wm::send {cmd args} {}

set T $::env(TRAY_TMP)
set SHOTS $::env(TRAY_SHOTS)
set LOG $T/items.log
file mkdir $T/icons $SHOTS

# the apps' pictures, white line drawings on clear (the boards' glyphs): Steam's as a PNG in its IconThemePath,
# Discord's at 16 and 32 px for its pixmaps
proc white_png {f d size width} {
	set mask [raster::strokemask $d $size $width 0 0]
	set rows {}
	for {set y 0} {$y < $size} {incr y} {
		set row {}
		foreach a [lrange [lindex $mask $y] 0 [expr {$size - 1}]] { lappend row 255 255 255 [expr {int($a * 255 + 0.5)}] }
		lappend rows $row
	}
	set fh [open $f wb]; puts -nonewline $fh [raster::png $size $size $rows]; close $fh
}
set STEAM {M12 2a10 10 0 1 0 0 20a10 10 0 1 0 0-20z M15.5 6.5a2.5 2.5 0 1 0 0 5a2.5 2.5 0 1 0 0-5z M13.4 10.3L9.2 14.2 M8 13.2a2.2 2.2 0 1 0 0 4.4a2.2 2.2 0 1 0 0-4.4z M2.6 13.6l3.5 1.4}
set DISCORD {M8.5 5.5C7 5.8 5.6 6.3 4.4 7C2.6 9.8 2 12.6 2.2 15.4C3.7 16.6 5.2 17.4 6.8 17.9l1.1-1.8 M15.5 5.5c1.5.3 2.9.8 4.1 1.5c1.8 2.8 2.4 5.6 2.2 8.4c-1.5 1.2-3 2-4.6 2.5l-1.1-1.8 M7.2 15.8c3.2 1.3 6.4 1.3 9.6 0 M8.6 6.6c2.3-.6 4.5-.6 6.8 0 M9 11.2a1.3 1.3 0 1 0 0 2.6a1.3 1.3 0 1 0 0-2.6z M15 11.2a1.3 1.3 0 1 0 0 2.6a1.3 1.3 0 1 0 0-2.6z}
white_png $T/icons/steam_tray_mono.png $STEAM 16 1.8
white_png $T/icons/discord16.png $DISCORD 16 1.8
white_png $T/icons/discord32.png $DISCORD 32 1.8

proc grab {name w h x y {ms 200}} {
	update
	if {$ms} { pause $ms }
	exec import -window root -crop ${w}x$h+$x+$y +repage $::SHOTS/$name.png
}
proc slot {key} { lindex [lsearch -index 0 -inline $tray::placed $key] 1 }
proc motion {x y} { event generate .bar.c <Motion> -x $x -y $y; update }
proc click {x y b} { event generate .bar.c <ButtonPress-$b> -x $x -y $y; event generate .bar.c <ButtonRelease-$b> -x $x -y $y; update }
proc cmd {line} { puts $::items $line; flush $::items; gets $::items }
proc steam {} { lsearch -inline -glob $tray::items *steam }
proc discord {} { lsearch -inline -glob $tray::items *StatusNotifierItem }
# gdbus through a pipe, read from the event loop: the shell must stay free to answer it
proc watcher_prop {name} {
	set ch [open |[list gdbus call --session --dest org.kde.StatusNotifierWatcher --object-path /StatusNotifierWatcher \
		--method org.freedesktop.DBus.Properties.Get org.kde.StatusNotifierWatcher $name 2>@1] r]
	fconfigure $ch -blocking 0
	set ::gd ""
	fileevent $ch readable [list apply {{ch} { append ::gd [read $ch]; if {[eof $ch]} { close $ch; set ::gdone 1 } }} $ch]
	vwait ::gdone
	return $::gd
}
# tray::png_decode in an interp of its own with a 2 s limit: {ok|error|timeout RESULT}
proc decode_limited {d} {
	set i [interp create]
	$i eval [list namespace eval tray {}]
	$i eval [list proc tray::png_decode d [info body tray::png_decode]]
	interp limit $i time -seconds [expr {[clock seconds] + 2}]
	set rc [catch {$i eval [list tray::png_decode $d]} r]
	interp delete $i
	list [expr {!$rc ? "ok" : [string match "time limit*" $r] ? "timeout" : "error"}] [string range $r 0 80]
}
# a call through gdbus, read from the event loop (the shell answers it): its output
proc gdbus_call {args} {
	set ch [open |[list gdbus call --session {*}$args 2>@1] r]
	fconfigure $ch -blocking 0
	set ::gd ""
	fileevent $ch readable [list apply {{ch} { append ::gd [read $ch]; if {[eof $ch]} { catch {close $ch}; set ::gdone 1 } }} $ch]
	vwait ::gdone
	return $::gd
}
proc tipup {} { expr {[winfo exists .ribbontip] && [winfo ismapped .ribbontip]} }
# the pill's text (text::draw puts it down in runs)
proc tiptext {} { join [lmap i [.ribbontip.c find all] { if {[.ribbontip.c type $i] eq "text"} { .ribbontip.c itemcget $i -text } else continue }] "" }

proc run {} {
	global T LOG failed
	# ---- the pieces on their own: pictures --------------------------------------------------------------------
	lassign [tray::png_decode [tray::readfile $T/icons/steam_tray_mono.png]] w h px
	check "a PNG of the shell's own is read (16 x 16, RGBA)" [expr {$w == 16 && $h == 16 && [string length $px] == 1024}] "$w x $h, [string length $px] bytes"
	foreach f {filtered.png palette.png} {
		set ok [expr {[file exists $T/$f] && ![catch {tray::png_decode [tray::readfile $T/$f]} r]}]
		set same 0
		if {$ok} {
			# against Tk's own reading, at the opaque pixels
			lassign $r w h px
			binary scan $px cu* v
			set img [image create photo -file $T/$f]
			set same 1
			foreach {x y} {16 16 10 20 24 8 5 5} {
				set k [expr {($y * $w + $x) * 4}]
				if {[lindex $v [expr {$k + 3}]] == 255 && [lrange $v $k [expr {$k + 2}]] ne [$img get $x $y]} { set same 0 }
			}
		}
		check "a PNG ImageMagick wrote ($f) is read as Tk reads it" [expr {$ok && $same}] [expr {$ok ? "pixels differ" : $r}]
	}
	# a purple picture comes out grey, between the bar and §muted
	set purple [binary format cu* [lrepeat 256 88 101 242 255]]
	array set tray::it [list x,src [tray::fit $purple 16 16 16]]
	set img [tray::picture x $theme::c(MUTED) $theme::c(BAR)]
	lassign [$img get 8 8] r g b
	lassign [raster::rgb $theme::c(BAR)] r0 g0 b0
	lassign [raster::rgb $theme::c(MUTED)] r1 g1 b1
	set l [expr {(0.2126 * 88 + 0.7152 * 101 + 0.0722 * 242) / 255.0}]
	check "an app's colour is not drawn: its picture is grey, in the bar's glyph colours" \
		[expr {abs($r - ($r0 + ($r1 - $r0) * $l)) <= 1 && abs($b - ($b0 + ($b1 - $b0) * $l)) <= 1}] "got $r $g $b"
	array unset tray::it x,*
	check "a 32 px pixmap and a 16 px one: the 16 is used" [expr {[lindex [tray::pick_pixmap [list [list 32 32 [string repeat x 4096]] [list 16 16 [string repeat y 1024]]] 16] 0] == 16}] ""
	# a damaged PNG (an app names any file): refused, and quickly (png_decode in an interp with a time limit)
	set hdr "\x89PNG\r\n\x1a\n"
	set ihdr [binary format I 13]IHDR[binary format IIcucucucucu 1 1 8 6 0 0 0][binary format I 0]
	set neg $hdr$ihdr[binary format I -12]IDAT[string repeat x 16]
	check "a PNG with a negative chunk length is refused, not looped on" [expr {[lindex [decode_limited $neg] 0] eq "error"}] [decode_limited $neg]
	set idat [zlib compress [binary format cu* {0 1 2 3 4}]]
	set huge $hdr[binary format I 13]IHDR[binary format IIcucucucucu 30000 30000 8 6 0 0 0][binary format I 0][binary format I [string length $idat]]IDAT$idat[binary format I 0]
	check "a PNG that says 30000 x 30000 over a few bytes is refused, not decoded" [expr {[lindex [decode_limited $huge] 0] eq "error"}] [decode_limited $huge]
	# a decompression bomb: 1 x 1 over IDAT that inflates to 64 MB (it took 800 MB and seconds before): only the rows are inflated
	set idat [zlib compress [string repeat \0 [expr {64 << 20}]]]
	set bomb $hdr$ihdr[binary format I [string length $idat]]IDAT$idat[binary format I 0]
	set t0 [clock milliseconds]
	set got [decode_limited $bomb]
	set ms [expr {[clock milliseconds] - $t0}]
	check "a 1 x 1 PNG whose IDAT inflates to 64 MB is decoded from its one row, quickly" [expr {[lindex $got 0] eq "ok" && [lrange [lindex $got 1] 0 1] eq "1 1" && $ms < 400}] "$got in $ms ms"
	unset idat bomb
	check "a 4096 px pixmap is not an icon" [expr {[tray::pick_pixmap [list [list 4096 4096 [string repeat x [expr {4096 * 4096 * 4}]]]] 16] eq ""}] ""
	check "menu labels lose their mnemonics" [expr {[tray::mnemonic _Quit] eq "Quit" && [tray::mnemonic Save__As] eq "Save_As"}] ""

	# ---- the apps come -------------------------------------------------------------------------------------
	check "the shell serves org.kde.StatusNotifierWatcher" [wait {$traymod::status eq "primary"}] "$traymod::status"
	set py $::env(TRAY_PYTHON)
	set ::items [open |[list $py $::env(TRAY_FIXTURES)/sni-items.py $T/icons $LOG 2>@1] r+]
	set ::ready ""
	fconfigure $::items -blocking 0 -encoding utf-8
	wait {[gets $::items ::ready] >= 0 || [eof $::items]} 10000
	fconfigure $::items -blocking 1
	check "the stand-in apps register with the shell's watcher" [expr {$::ready eq "ready"}] "said: $::ready"
	check "Steam and Discord come into the bar, in the order they came" [wait {[llength [tray::keys]] == 2}] "keys: [tray::keys]; status $traymod::status"
	set reg [watcher_prop RegisteredStatusNotifierItems]
	check "the watcher lists Steam by its path and Discord by its name (gdbus)" \
		[expr {[regexp {:[0-9.]+/org/ayatana/NotificationItem/steam} $reg] && [regexp {org\.kde\.StatusNotifierItem-\d+-1/StatusNotifierItem} $reg]}] $reg
	set host [watcher_prop IsStatusNotifierHostRegistered]
	check "the shell is the watcher's host (gdbus)" [string match *true* $host] $host
	# an item registered by a path that is not an object path: the watcher refuses it, the host never takes one
	set r [gdbus_call --dest org.kde.StatusNotifierWatcher --object-path /StatusNotifierWatcher \
		--method org.kde.StatusNotifierWatcher.RegisterStatusNotifierItem {/bad path}]
	check "the watcher refuses an item whose path is not an object path" [string match *InvalidArgs* $r] $r
	check "and the host takes none from another watcher" [expr {![catch {tray::add {:1.999/bad path}} e] && {:1.999/bad path} ni $tray::items}] $e
	update
	check "the bar still has Steam and Discord" [expr {[llength [tray::keys]] == 2}] [tray::keys]
	check "Steam first, then Discord" [expr {[string match *steam [lindex [tray::keys] 0]] && [string match *StatusNotifierItem [lindex [tray::keys] 1]]}] [tray::keys]
	update
	set q [lsearch -index 0 -inline $bar::placed tray]
	set s [lsearch -index 0 -inline $bar::placed sni]
	check "the icons sit left of the quick-settings button, 30 a slot and 4 between" \
		[expr {$s ne "" && [lindex $s 2] == 64 && [lindex $s 1] + 64 + 4 == [lindex $q 1]}] "sni $s, tray $q"
	check "Steam's PNG and Discord's pixmap are both drawn" [expr {[tray::picture_src [steam]] ne "none" && [tray::picture_src [discord]] ne "none"}] ""
	grab Tray-1-Icons 520 520 920 0

	# ---- the pointer: a slot lights, the name comes after 500 ms ------------------------------------------------
	set dx [slot [discord]]
	motion [expr {$dx + 15}] 27
	check "the pointer lights Discord's slot" [expr {$tray::hover eq [discord]}] "hover $tray::hover"
	pause 250
	check "no name before 500 ms" [expr {![tipup]}] "up after 250 ms"
	# the lit slot before the pill comes (without a compositor the pill's window, shadow and all, hides the bar)
	grab Tooltip-1-Bar-slot 520 520 920 0 0
	check "(the slot was grabbed before the name came)" [expr {![tipup]}] "the pill was up"
	check "Discord's name comes after 500 ms" [wait {[tipup]} 800] "no tooltip"
	check "the tooltip is the app's title and nothing else" [expr {[tiptext] eq "Discord"}] [tiptext]
	grab Tooltip-1-Bar 520 520 920 0
	motion 600 300
	check "it goes when the pointer leaves" [expr {![tipup] && $tray::hover eq ""}] "up [tipup] hover $tray::hover"
	# the bar's own icon-only buttons: their names
	set pw [lindex [lsearch -index 0 -inline $bar::placed power] 1]
	motion [expr {$pw + 15}] 27
	check "the power button's name is Power" [expr {[wait {[tipup]} 900] && [tiptext] eq "Power"}] [tiptext]
	event generate .bar.c <ButtonPress-3> -x [expr {$pw + 15}] -y 27; update
	check "a press takes it down" [expr {![tipup]}] "still up"
	pause 700
	check "and it does not come back while the pointer stays" [expr {![tipup]}] "back"
	motion 600 300
	set qx [lindex $q 1]
	motion [expr {$qx + 20}] 27
	check "the quick-settings button's name" [expr {[wait {[tipup]} 900] && [tiptext] eq "Quick settings"}] [tiptext]
	motion [expr {$dx + 15}] 27
	check "moving straight on to the next button shows its name at once" [expr {[wait {[tipup]} 150] && [tiptext] eq "Discord"}] [tiptext]
	motion 600 300
	set clock [lindex [lsearch -index 0 -inline $bar::placed clock] 1]
	motion [expr {$clock + 10}] 27
	pause 800
	check "the clock (it has words) has no tooltip" [expr {![tipup]}] "up: [tiptext]"
	motion 600 300

	# the window controls: named while there is a window to act on, not while they are dimmed (no window)
	set keep $wm::focus
	set wm::focus ""
	check "dimmed window controls have no names" [expr {[traymod::bar_name {bar::wctl min}] eq "" && [traymod::bar_name {bar::wctl close}] eq ""}] [traymod::bar_name {bar::wctl close}]
	set wm::focus 0x1
	check "with a window: Minimise and Close" [expr {[traymod::bar_name {bar::wctl min}] eq "Minimise" && [traymod::bar_name {bar::wctl close}] eq "Close"}] [traymod::bar_name {bar::wctl min}]
	set wm::focus $keep

	# a toolbar at the foot of a window (board Tooltip-2-Viewer): the name goes over it, 6 px clear, centred
	toplevel .tb -background black; wm overrideredirect .tb 1; wm geometry .tb 300x44+500+700
	canvas .tb.c -width 300 -height 44 -highlightthickness 0 -background black; pack .tb.c
	update
	tip::attach .tb.c [list apply {{x y} { if {$x >= 100 && $x < 134} { list rotate Rotate 117 0 44 above } }}]
	event generate .tb.c <Motion> -x 110 -y 20
	check "a toolbar button's name comes" [expr {[wait {[tipup]} 900] && [tiptext] eq "Rotate"}] [tiptext]
	# the pill's window has its new size and place (it showed Discord's name, wider, before)
	update idletasks; update
	lassign $rbn::shown(.ribbontip,c) cx cy
	set bx [expr {[winfo rootx .ribbontip] + $cx}]; set by [expr {[winfo rooty .ribbontip] + $cy}]
	set bw [winfo width .ribbontip.c]
	check "over the toolbar, 6 px clear, centred on the button" [expr {$by + 26 == 700 - 6 && abs($bx + $bw / 2.0 - 617) <= 1}] "box at $bx $by, $bw wide"
	destroy .tb
	check "and goes with its window" [expr {![tipup]}] "still up"

	# ---- clicks ---------------------------------------------------------------------------------------------
	click [expr {$dx + 15}] 27 1
	set ::want "discord Activate [expr {int($dx + 15)}] 46"
	check "a left click on Discord is its Activate, at the slot's foot" [wait {[logged_has $::want]}] [logged]
	click [expr {$dx + 15}] 27 2
	check "a middle click is its SecondaryActivate" [wait {[logged_has "discord SecondaryActivate *"]}] [logged]
	click [expr {$dx + 15}] 27 5
	check "the wheel is its Scroll" [wait {[logged_has "discord Scroll 120 vertical"]}] [logged]
	set sx [slot [steam]]
	click [expr {$sx + 15}] 27 1
	check "Steam has no Activate (libappindicator): a left click opens its menu" [wait {$panel::open eq "sni"}] "open: $panel::open"
	check "the menu's rows are Steam's, the separator before Exit Steam" \
		[expr {[lmap r [dict get $tray::menu rows] {expr {$r eq "sep" ? "-" : [lindex $r 2]}}] eq {Store Library Community Friends Screenshots Settings {Big Picture} - {Exit Steam}}}] \
		[dict get $tray::menu rows]
	check "the app is told its menu opened" [wait {[logged_has "steam Event 0 opened"]}] [logged]
	check "the quick-settings button is not lit while the menu is open" [expr {![bar::tray_open]}] ""
	update
	# the pointer on Library (the second row: 8 + 42)
	event generate .panel.c <Motion> -x 100 -y 70; update
	check "the row under the pointer is lit" [expr {[dict get $tray::menu sel] == 1}] "sel [dict get $tray::menu sel]"
	check "the menu hangs from the right bar at its width" \
		[expr {[lindex $rbn::shown(.panel,c) 0] >= 0 && [winfo width .panel.c] == max(320, $bar::rightw)}] "[winfo width .panel.c] vs $bar::rightw"
	grab Tray-2-Menu 520 520 920 0
	event generate .panel.c <ButtonPress-1> -x 100 -y 70; update
	check "picking Library sends its clicked event" [wait {[logged_has "steam Event 2 clicked"]}] [logged]
	check "and the menu closes" [expr {$panel::open eq "" && ![dict exists $tray::menu key]}] "open $panel::open"
	# right click on Discord: its menu; Acknowledgements is greyed out and takes no click
	click [expr {$dx + 15}] 27 3
	check "a right click opens Discord's menu" [wait {$panel::open eq "sni" && [dict exists $tray::menu key] && [dict get $tray::menu key] eq [discord]}] "open $panel::open"
	set rows [dict get $tray::menu rows]
	check "a row the app greys out is drawn but takes no click" \
		[expr {[lindex $rows 2 3] == 0 && [lsearch -glob $panel::hits *menu_pick\ 3*] < 0 && [lsearch -glob $panel::hits *menu_pick\ 1*] >= 0}] "$rows / $panel::hits"
	cmd "menu discord Open Discord,-,Quit Discord"
	check "the app changes its menu while it is open: the panel follows" [wait {[llength [dict get $tray::menu rows]] == 3}] [dict get $tray::menu rows]
	click [expr {$dx + 15}] 27 3
	check "a second right click closes it, and the app is told" [expr {[wait {[logged_has "discord Event 0 closed"]}] && $panel::open eq ""}] [logged]
	# a menu open, then another panel: the menu goes
	click [expr {$sx + 15}] 27 3
	wait {$panel::open eq "sni"}
	panel::show session
	check "another panel closes the menu" [expr {![dict exists $tray::menu key]}] ""
	panel::close

	# a menu with a submenu and checked items (board Tray-3-Submenu): the submenu is a section under its name,
	# its items after it; a checkmark or radio that is on has the check
	cmd "menu discord Open Discord,Check for Updates…,-,*Mute,+Deafen,-,Status>*Online|Idle|Do Not Disturb|Invisible,-,Quit Discord"
	click [expr {$dx + 15}] 27 3
	check "Discord's menu opens" [wait {$panel::open eq "sni" && [dict exists $tray::menu key] && [dict get $tray::menu key] eq [discord] && [llength [dict get $tray::menu rows]] == 13}] \
		[expr {[dict exists $tray::menu rows] ? [dict get $tray::menu rows] : ""}]
	set rows [dict get $tray::menu rows]
	check "the submenu is a section: a rule, its name, its items, a rule" \
		[expr {[lmap r $rows {expr {$r eq "sep" ? "-" : ([lindex $r 0] eq "label" ? "#[lindex $r 1]" : [lindex $r 2])}}] eq
			[list Open\ Discord Check\ for\ Updates… - Mute Deafen - #Status Online Idle Do\ Not\ Disturb Invisible - Quit\ Discord]}] $rows
	check "checked: Mute (a checkmark on) and Online (the radio item on); Deafen and Idle not" \
		[expr {[lindex $rows 3 4] == 1 && [lindex $rows 4 4] == 0 && [lindex $rows 7 4] == 1 && [lindex $rows 8 4] == 0}] $rows
	# the pointer on Idle: 8 + 42 + 42 + 11 + 42 + 42 + 11 + 27.31 = 225.31 + 42 = 267.31
	event generate .panel.c <Motion> -x 100 -y 287; update
	check "the row under the pointer in the section is lit" [expr {[dict get $tray::menu sel] == 8}] "sel [dict get $tray::menu sel]"
	grab Tray-3-Submenu 520 520 920 0
	event generate .panel.c <ButtonPress-1> -x 100 -y 287; update
	check "picking Idle (the submenu's second item, id 9) sends its clicked event" [wait {[logged_has "discord Event 9 clicked"]}] [logged]
	check "and the menu closes" [expr {$panel::open eq "" && ![dict exists $tray::menu key]}] "open $panel::open"
	# a submenu inside a submenu is a section too (none was shown before)
	set deep [list 0 {} [list [list 1 {label {s Sync} children-display {s submenu}} [list [list 2 {label {s Folders} children-display {s submenu}} [list [list 3 {label {s Photos}} {}]]]]]]]
	set flat [lmap r [tray::rows $deep] {expr {$r eq "sep" ? "-" : ([lindex $r 0] eq "label" ? "#[lindex $r 1]" : [lindex $r 2])}}]
	check "a submenu's submenu is a section too, not dropped" [expr {$flat eq [list #Sync #Folders Photos]}] $flat

	# an app whose picture cannot be read (a damaged PNG; board Tray-4-Fallback): the box glyph in its slot
	motion 600 300
	cmd "add heroic"
	check "a third app comes" [wait {[llength [tray::keys]] == 3}] [tray::keys]
	set ::hk [lsearch -inline -glob [tray::keys] *-3/StatusNotifierItem]
	check "its picture is none: the bar draws the box glyph" [wait {$::hk ne "" && [tray::picture_src $::hk] eq "none"}] $::hk
	grab Tray-4-Fallback 520 520 920 0
	cmd "quit heroic"
	wait {[llength [tray::keys]] == 2}

	# ---- the apps' signals ---------------------------------------------------------------------------------
	cmd "status discord NeedsAttention"
	check "an app asking for attention is drawn in the accent" [wait {[tray::prop [discord] Status] eq "NeedsAttention"}] ""
	update
	# the bar's own drawing: an image on .bar.c is the accent's picture
	check "its picture is in the accent's colours" [wait {[info exists tray::it([discord],img,$theme::c(ACCENT))] &&
		$tray::it([discord],img,$theme::c(ACCENT)) in [lmap i [.bar.c find all] {expr {[.bar.c type $i] eq "image" ? [.bar.c itemcget $i -image] : ""}}]}] [array names tray::it *img*]
	cmd "status discord Passive"
	check "a passive app leaves the bar" [wait {[llength [tray::keys]] == 1}] [tray::keys]
	cmd "status discord Active"
	wait {[llength [tray::keys]] == 2}
	cmd "title discord Discord Canary"
	check "a new title is the new tooltip" [wait {[tray::name [discord]] eq "Discord Canary"}] [tray::name [discord]]
	cmd "quit steam"
	check "an app that quits leaves the bar" [wait {[llength [tray::keys]] == 1 && [steam] eq ""}] [tray::keys]
	set reg [watcher_prop RegisteredStatusNotifierItems]
	check "and the watcher's list" [expr {![string match *steam* $reg]}] $reg
	close $::items
	check "when the last app goes, the bar has no room for icons" [wait {[tray::width] == 0}] [tray::keys]
	update
	check "and nothing of the tray is placed" [expr {[lsearch -index 0 $bar::placed sni] < 0}] $bar::placed

	if {$failed} { puts "tray: $failed failed" } else { puts "tray: all checks passed" }
	exit 0
}
after 300 run
