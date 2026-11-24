# tests/hud-quick.tcl - the Game HUD's quick menu (apps/hud/quick.tcl) against stand-ins for its services, and its
# geometry against the boards HUD-Quick-1-Menu, -2-Volume and -3-Quit (design/tools/gen_hud_quick.py; the numbers are
# the boards' DOM boxes at 1440 x 900). wish8.6 under xvfb.
#   env: QFAKE (a directory with the stand-ins: wpctl, ribbon-hdr and ribbon-screenshot record what they are asked),
#        DBUS_SYSTEM_BUS_ADDRESS (a private bus: this test serves power-profiles-daemon on it; unset: no Performance)
package require Tk
wm withdraw .
set repo [file dirname [file dirname [file normalize [info script]]]]
set D [file join $repo srcpkgs ribbon-desktop files]
source [file join $D apps hud hud.tcl]
hud::init_modules
source -encoding utf-8 [file join $D apps hud quick.tcl]
hud::theme_load [file join $D themes palettes ribbon.conf]
set tmp [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] hud-quick-[pid]]
hud::draw::init [file join $tmp cache]
hud::art::configure -cache [file join $tmp cache]

set fails 0
proc ok {name} { puts "  ok   $name" }
proc check {name got want} {
	if {$got eq $want} { ok $name; return }
	puts "  FAIL $name: got {$got}, want {$want}"; incr ::fails
}
proc near {name got want {tol 1.0}} {
	if {[string is double -strict $got] && abs($got - $want) <= $tol} { ok "$name ($got)"; return }
	puts "  FAIL $name: got $got, want $want"; incr ::fails
}
# deadline wait: the event loop runs until COND holds, at most MS
proc waitfor {cond {ms 3000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 [list expr $cond]] && [clock milliseconds] < $end} {
		after 20 [list set ::tick 1]; vwait ::tick
	}
	uplevel #0 [list expr $cond]
}
proc slurp {f} { if {[catch {set h [open $f]; set t [read $h]; close $h}]} { return "" }; return $t }

set Q $::env(QFAKE)
set ::env(RIBBON_WPCTL) [file join $Q wpctl]
set ::env(RIBBON_HDR) [file join $Q ribbon-hdr]
set ::env(RIBBON_SCREENSHOT) [file join $Q ribbon-screenshot]

# ---- power-profiles-daemon on the private system bus ----
set ppd 0
if {[info exists ::env(DBUS_SYSTEM_BUS_ADDRESS)] && ![catch {
	lappend ::auto_path $D
	package require ribbon::dbus
	set sys [ribbon::dbus::connect system]
	set ::profiles {}
	$sys export /net/hadess/PowerProfiles net.hadess.PowerProfiles {
		property ActiveProfile s readwrite {-value balanced -set {apply {{m v} {lappend ::profiles $v}}}}
		property Profiles aa{sv} read {-value {{Profile {s power-saver}} {Profile {s balanced}} {Profile {s performance}}}}
	}
	if {[$sys request net.hadess.PowerProfiles] ne "primary"} { error "cannot own the name" }
} err]} { set ppd 1 } else { puts "  note no power-profiles-daemon stand-in ([expr {[info exists err] ? $err : "no bus"}]): Performance not checked" }

# ---- the daemon's side, stood in for ----
set ::orders {}
set ::redraws 0
proc order {args} { lappend ::orders $args }
hud::quick::configure -layout {order layout} -window {order window} -redraw {incr ::redraws} -log {order log} -open {order open}
hud::set_runtime [list name "Cyberpunk 2077"]
set ::env(WLR_RENDERER) vulkan

# ---- opened: the services are read ----
set start [expr {[clock milliseconds] - 77 * 60000 - 5000}]
hud::quick::set_layout full
if {[info exists ::env(QDEBUG)]} { hud::quick::configure -log {puts stderr} }
hud::quick::open win7 "Cyberpunk 2077" "" $start
set want [expr {$ppd ? "overlay,perf,hdr,vol,shot,desk,quit" : "overlay,hdr,vol,shot,desk,quit"}]
waitfor {[string match "*rows=$::want *" [hud::quick::state]]}
check "open: the rows with a service (board HUD-Quick-1-Menu)" [regsub {.*rows=(\S+).*} [hud::quick::state] {\1}] $want
check "open: the volume read from wpctl (0.64)" [set ::hud::quick::volume] 64
check "open: HDR read from ribbon-hdr status" [set ::hud::quick::hdr] on
if {$ppd} { check "open: the power mode read from power-profiles-daemon" [set ::hud::quick::profile] balanced }
check "open: the time played" [hud::quick::playtime] "1 h 17 min"
check "open: Overlay has the focus" [set ::hud::quick::focus] overlay

# ---- geometry against HUD-Quick-1-Menu (W 1440, H 900) ----
proc opsof {} { lassign [hud::quick::ops 1440 900 1] u o; return [list $u $o] }
lassign [opsof] under over
check "the dim covers the screen at 0.35 and takes all input" [list [lrange [lindex $under 0] 1 4] [lindex $under 0 end] [lindex $under 1]] {{0 0 1440 900} 0.35 {hit quick 0 0 1440 900}}
set card [lindex $over 0]
# without power-profiles-daemon the Performance row is left out: what is below it moves up 50
set dy [expr {$ppd ? 0 : -50}]
check "card: 12 px from the right and top edges, 330 x 512 (board: 1098 12 330 512)" [lrange $card 1 4] [list 1098 12 330 [expr {512 + $dy}]]
check "card: glass at 0.86 with the border ring, radius 16" [list [lindex $card 5] [lindex $card 6] [lindex $card 7 0] [lindex $card end]] {16 #1D1C1B #3B3835 0.86}
proc find {ops kind args} {
	foreach op $ops {
		if {[lindex $op 0] ne $kind} continue
		set m 1
		foreach {i v} $args { if {[lindex $op $i] ne $v} { set m 0; break } }
		if {$m} { return $op }
	}
	return ""
}
set t [find $over text 7 "Cyberpunk 2077"]
check "head: the name at 1158, centred on 44 (board text box 1158 32.5 h 23)" [lrange $t 1 6] {1158 44 w {Ribbon Space Grotesk 600} 18 #EEE9E3}
set t [find $over text 7 "1 h 17 min"]
check "head: the time right-aligned at 1408" [lrange $t 1 3] {1408 44 e}
set im [find $over rrect 1 1118 2 30]
check "head: no picture yet: the pill 28 px at 1118 30, radius 7" [lrange $im 1 5] {1118 30 28 28 7}
set ov [find $over rrect 1 1112 2 76]
check "Overlay card: 1112 76 302 90, field, the accent ring 1.5 (in focus)" [join [concat [lrange $ov 1 6] [lindex $ov 7]]] "1112 76 302 90 10 #2A2826 #FF7A59 1.5"
foreach {txt x} {Off 1158 FPS 1221.8 Compact 1294.9 Full 1368} {
	near "seg: $txt centred at $x (board)" [lindex [find $over text 7 $txt] 1] $x 2.5
}
set pill [find $over rrect 2 125]
near "seg: the chosen part's pill starts at 1337 (board 1337.1)" [lindex $pill 1] 1337 2
near "seg: the chosen part's pill is 62 wide (board 61.9)" [lindex $pill 3] 62 2
foreach {lbl y} {Performance 193 HDR 243 Volume 293 Screenshot 343 {Back to desktop} 393 {Quit game} 443} {
	if {$lbl eq "Performance" && !$ppd} continue
	set t [find $over text 7 $lbl]
	check "row $lbl: label at 1152, centred on $y (board)" [lrange $t 1 2] [list 1152 [expr {$lbl eq "Performance" ? $y : $y + $dy}]]
}
if {$ppd} { check "row Performance: Balanced right-aligned at 1402" [lrange [find $over text 7 Balanced] 1 3] {1402 193 e} }
check "row Volume: 64% right-aligned at 1402" [lrange [find $over text 7 64%] 1 3] [list 1402 [expr {293 + $dy}] e]
check "row HDR: the switch on (accent track 1364 232 38 22)" [lrange [find $over rrect 1 1364] 1 6] [list 1364 [expr {232 + $dy}] 38 22 11 #FF7A59]
check "row Screenshot: the Print key cap ends at 1402 (board 1365 333 37 20)" [lrange [find $over rrect 2 [expr {333 + $dy}]] 1 4] [list 1365 [expr {333 + $dy}] 37 20]
check "footer: the rule at 476 (board 476)" [lrange [find $over rect 2 [expr {476 + $dy}]] 1 4] [list 1112 [expr {476 + $dy}] 302 1]
foreach {g x} {A 1128 B 1217} { near "footer: the $g button centred at $x" [lindex [find $over text 7 $g] 1] $x 1.5 }
check "footer: Change, Close, Layout" [lmap n {Change Close Layout} { expr {[find $over text 7 $n] ne ""} }] {1 1 1}
near "footer: Layout after the two arrow buttons (board 1338.3)" [lindex [find $over text 7 Layout] 1] 1338.3 3

# ---- keys: Up/Down move, Left/Right step, Enter, Esc ----
set ::orders {}
hud::quick::key 105
check "Left on Overlay: the layout steps down (Full -> Compact)" [lindex $::orders 1] {layout compact}
hud::quick::set_layout compact
hud::quick::key 28
check "Enter on Overlay: the next layout" [lindex [lsearch -inline -all $::orders {layout *}] end] {layout full}
hud::quick::set_layout full
hud::quick::key 106
check "Right on Full stays (no wrap)" [llength [lsearch -all $::orders {layout *}]] 2
if {$ppd} {
	hud::quick::key 108
	check "Down: Performance" [set ::hud::quick::focus] perf
	hud::quick::key 106
	waitfor {[lindex $::profiles end] eq "performance"}
	check "Right on Performance: power-profiles-daemon is set to performance" [lindex $::profiles end] performance
	waitfor {[set ::hud::quick::profile] eq "performance"}
	hud::quick::key 105; hud::quick::key 105
	waitfor {[lindex $::profiles end] eq "power-saver"}
	check "Left twice: power-saver" [lindex $::profiles end] power-saver
	waitfor {[set ::hud::quick::profile] eq "power-saver"}
	check "the row shows Saver (Settings → Power's label)" [hud::quick::value perf] Saver
}
hud::quick::key 108
check "Down: HDR" [set ::hud::quick::focus] hdr
hud::quick::key 28
waitfor {[string match "*off*" [slurp $Q/hdr.calls]]}
check "Enter on HDR: ribbon-hdr off" [string trim [slurp $Q/hdr.calls]] off
waitfor {[set ::hud::quick::hdr] eq "off"}
check "HDR reads back off" [set ::hud::quick::hdr] off
lassign [opsof] under over
check "HDR off: the switch's track is the pill colour" [lindex [find $over rrect 1 1364] 6] #36302C
hud::quick::key 108
check "Down: Volume" [set ::hud::quick::focus] vol
lassign [opsof] under over
check "Volume in focus: the footer is Close and left/right Volume (board HUD-Quick-2-Volume)" \
	[list [expr {[find $over text 7 Change] ne ""}] [expr {[find $over text 7 Close] ne ""}] [llength [lsearch -all -exact [lmap op $over {lindex $op end}] Volume]]] {0 1 2}
hud::quick::key 106; waitfor {[set ::hud::quick::volume] == 69}
hud::quick::key 106; waitfor {[set ::hud::quick::volume] == 74}
check "Right twice on Volume: wpctl steps 5 % up twice (64 -> 74)" [set ::hud::quick::volume] 74
check "wpctl was asked with the 100 % limit" [lindex [split [string trim [slurp $Q/wpctl.calls]] \n] 0] "set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+"
hud::quick::key 105; waitfor {[set ::hud::quick::volume] == 69}
check "Left: 5 % down" [set ::hud::quick::volume] 69
# muted: Right unmutes as it steps up (as the volume keys do, mod-osd.tcl); Left only steps down
close [open $Q/muted w]
hud::quick::read_volume; waitfor {[set ::hud::quick::muted]}
check "muted: the row says Muted" [hud::quick::value vol] Muted
hud::quick::key 106; waitfor {![set ::hud::quick::muted] && [set ::hud::quick::volume] == 74}
check "Right while muted: unmuted and 5 % up" [list [set ::hud::quick::muted] [set ::hud::quick::volume] [hud::quick::value vol]] {0 74 74%}
hud::quick::key 105; waitfor {[set ::hud::quick::volume] == 69}
check "Left after that: 5 % down" [set ::hud::quick::volume] 69
check "the row shows 69%" [lindex [find [lindex [opsof] 1] text 7 69%] 7] 69%

# ---- Back to desktop and Quit game ----
hud::quick::key 108; hud::quick::key 108
check "Down twice: Back to desktop" [set ::hud::quick::focus] desk
set ::orders {}
hud::quick::key 28
check "Enter on Back to desktop: the menu closes and the game's window is minimised" [list [hud::quick::is_open] [lindex [lsearch -inline -all $::orders {window *}] 0]] {0 {window minimize win7}}
hud::quick::open win7 "Cyberpunk 2077" "" $start
foreach k {108 108 108 108 108 108 108} { hud::quick::key $k }
check "Down to the last row: Quit game (no wrap)" [set ::hud::quick::focus] quit
hud::quick::key 28
check "Enter on Quit game: the question, Cancel in focus" [regsub {.*ask=(\S+).*} [hud::quick::state] {\1}] cancel
lassign [opsof] under over
check "question: the card is 255 tall (board HUD-Quick-3-Quit: 1098 12 330 255)" [lrange [lindex $over 0] 1 4] {1098 12 330 255}
check "question: the title at 1124, centred on 89.5" [lrange [find $over text 7 "Quit the game?"] 1 6] {1124 89.5 w {Ribbon Inter 600} 15 #EEE9E3}
check "question: Cancel's row in focus at 1112 163 (board)" [lrange [find $over rrect 2 163] 1 4] {1112 163 302 46}
check "question: Quit game at 1152 136, Cancel at 1152 186" [list [lrange [find $over text 7 "Quit game"] 1 2] [lrange [find $over text 7 Cancel] 1 2]] {{1152 136} {1152 186}}
check "question: the footer Select and Back" [list [expr {[find $over text 7 Select] ne ""}] [expr {[find $over text 7 Back] ne ""}]] {1 1}
set ::orders {}
hud::quick::key 28
check "Enter on Cancel: back to the menu, nothing closed" [list [hud::quick::is_open] [regsub {.*ask=(\S+).*} [hud::quick::state] {\1}] [lsearch -all $::orders {window *}]] {1 0 {}}
hud::quick::key 28; hud::quick::key 1
check "Esc in the question: back to the menu" [list [hud::quick::is_open] [regsub {.*ask=(\S+).*} [hud::quick::state] {\1}]] {1 0}
hud::quick::key 28; hud::quick::key 103; hud::quick::key 28
check "Up, Enter on Quit game: the game's window is closed, the menu too" [list [hud::quick::is_open] [lindex [lsearch -inline -all $::orders {window *}] 0]] {0 {window close win7}}

# ---- Screenshot: after the surface has drawn without the menu ----
hud::quick::open win7 "Cyberpunk 2077" "" $start
hud::quick::pad down
while {[set ::hud::quick::focus] ne "shot"} { hud::quick::pad down }
hud::quick::pad a
check "A on Screenshot: the menu closes first" [hud::quick::is_open] 0
after 300 {set ::t 1}; vwait ::t
check "no screenshot while the menu may still be on screen" [file exists $Q/shot.done] 0
hud::quick::surface_event "mapped 0 0 10 10"
waitfor {[file exists $Q/shot.done]}
check "ribbon-screenshot runs once the surface has redrawn" [file exists $Q/shot.done] 1

# ---- controller buttons ----
set ::orders {}
hud::quick::pad home
check "home while closed: the daemon is asked to open" [lsearch -inline $::orders open] open
hud::quick::open "" "" "" ""
check "no game window: no Back to desktop, no Quit game; no time" [list [string match *desk* [regsub {.*rows=(\S+).*} [hud::quick::state] {\1}]] [hud::quick::playtime]] {0 {}}
hud::quick::pad b
check "B closes" [hud::quick::is_open] 0
hud::quick::open "" "" "" ""
hud::quick::pad home
check "home while open closes" [hud::quick::is_open] 0

# ---- the mouse: a click on a row takes it, on the switcher picks a layout, off the card closes ----
proc pause {ms} { after $ms {set ::tick 1}; vwait ::tick }
proc rowy {name} { foreach r [dict get $::hud::quick::geo rows] { if {[lindex $r 0] eq $name} { return [expr {12 + [lindex $r 1] + 23}] } }; return -1 }
hud::quick::open win7 "Cyberpunk 2077" "" $start
waitfor {[string match "*,hdr,*" [hud::quick::state]] && [set ::hud::quick::volume] ne ""}
hud::quick::set_layout full
opsof
set ::orders {}
lassign [lsearch -inline -index 0 $::hud::quick::segs fps] - sx0 sx1 sy0 sy1
hud::quick::click [expr {round(1098 + ($sx0 + $sx1) / 2.0)}] [expr {round(12 + ($sy0 + $sy1) / 2.0)}]
check "a click on the switcher's FPS: that layout" [lindex [lsearch -inline -all $::orders {layout *}] end] {layout fps}
hud::quick::set_layout fps
set hdr0 [set ::hud::quick::hdr]
set nh [llength [split [string trim [slurp $Q/hdr.calls]] \n]]
hud::quick::click 1200 [rowy hdr]
waitfor {[llength [split [string trim [slurp $::Q/hdr.calls]] \n]] > $::nh}
check "a click on HDR: it is switched (ribbon-hdr [expr {$hdr0 eq "on" ? "off" : "on"}]), and it has the focus" \
	[list [lindex [split [string trim [slurp $Q/hdr.calls]] \n] end] [set ::hud::quick::focus]] [list [expr {$hdr0 eq "on" ? "off" : "on"}] hdr]
waitfor {[set ::hud::quick::hdr] ne $::hdr0}
set nv [llength [split [string trim [slurp $Q/wpctl.calls]] \n]]
opsof
hud::quick::click [expr {1098 + 300}] [rowy vol]
waitfor {[llength [split [string trim [slurp $::Q/wpctl.calls]] \n]] > $::nv}
check "a click on Volume's right half: up 5 %" [string match "*5%+" [lindex [split [string trim [slurp $Q/wpctl.calls]] \n] end]] 1
opsof
hud::quick::click [expr {1098 + 40}] [rowy vol]
waitfor {[llength [split [string trim [slurp $::Q/wpctl.calls]] \n]] > $::nv + 1}
check "on its left half: down 5 %" [string match "*5%-" [lindex [split [string trim [slurp $Q/wpctl.calls]] \n] end]] 1
opsof
hud::quick::click 1200 [rowy quit]
check "a click on Quit game: the question" [regsub {.*ask=(\S+).*} [hud::quick::state] {\1}] cancel
opsof
set ::orders {}
hud::quick::click 1200 [rowy cancel]
check "a click on Cancel: back to the menu, nothing closed" [list [hud::quick::is_open] [regsub {.*ask=(\S+).*} [hud::quick::state] {\1}] [lsearch -all $::orders {window *}]] {1 0 {}}
opsof
hud::quick::click 1200 [expr {12 + 156}]
check "a click between the card's rows does nothing" [hud::quick::is_open] 1
hud::quick::click 300 400
check "a click off the card (on the game) closes the menu" [hud::quick::is_open] 0
check "a click with the menu closed is not the menu's" [hud::quick::click 1200 [rowy hdr]] 0

# ---- key repeat: a held arrow repeats at the compositor's rate after its delay; let go, it stops ----
hud::quick::open win7 "Cyberpunk 2077" "" $start
waitfor {[string match "*,hdr,*" [hud::quick::state]]}
set rs [split [regsub {.*rows=(\S+).*} [hud::quick::state] {\1}] ,]
hud::quick::set_repeat 20 150
hud::quick::key_down 108
check "a key down acts at once" [set ::hud::quick::focus] [lindex $rs 1]
pause 100
check "  nothing more before the delay" [set ::hud::quick::focus] [lindex $rs 1]
pause 180
set at [lsearch -exact $rs [set ::hud::quick::focus]]
check "  held past the delay it repeats (row [expr {$at + 1}] of [llength $rs])" [expr {$at >= 2}] 1
hud::quick::key_up 108
set at [set ::hud::quick::focus]
pause 150
check "  let go, it stops" [set ::hud::quick::focus] $at
hud::quick::key_down 103
hud::quick::key_up 103
pause 250
check "a tap is one step" [set ::hud::quick::focus] [lindex $rs [expr {[lsearch -exact $rs $at] - 1}]]
hud::quick::key_down 108
hud::quick::key_up ""
pause 250
check "the keyboard going (focus 0) stops it" [lsearch -exact $rs [set ::hud::quick::focus]] [lsearch -exact $rs $at]
set ::hud::quick::focus overlay
set ::orders {}
hud::quick::key_down 28
pause 250
check "Enter held acts once" [llength [lsearch -all $::orders {layout *}]] 1
hud::quick::key_up 28
hud::quick::close

# ---- a missing service leaves its row out ----
set ::env(WLR_RENDERER) gles2
set ::env(RIBBON_WPCTL) [file join $Q nothing-here]
hud::quick::open win7 "Cyberpunk 2077" "" $start
waitfor {![string match "*,vol*" [hud::quick::state]]}
if {[info exists ::env(QDEBUG)]} { puts stderr [hud::quick::state] }
check "GLES2 session, no wpctl: no HDR, no Volume" [list [string match *hdr* [regsub {.*rows=(\S+).*} [hud::quick::state] {\1}]] [string match *,vol* [hud::quick::state]]] {0 0}
hud::quick::close

# ---- the time played counts from the game's first process, not from a helper it started later ----
set fp [file join $tmp proc]
file mkdir $fp
proc fakeproc {pid start env} {
	file mkdir $::fp/$pid
	foreach {f t} [list cmdline "game.exe\0" stat "$pid (game.exe) S 1 [lrepeat 17 0] $start 0" environ "$env\0"] {
		set h [open $::fp/$pid/$f w]; fconfigure $h -translation binary; puts -nonewline $h $t; close $h
	}
}
set h [open $fp/stat w]; puts $h "cpu 0\nbtime 1000000"; close $h
fakeproc 100 50000 SteamAppId=1091500     ;# the game, started 500 s after boot
fakeproc 200 410000 SteamAppId=1091500    ;# a helper it started an hour later
fakeproc 300 420000 PATH=/bin             ;# not the game's
hud::games::configure -proc $fp
check "the game started at its first process" [hud::quick::started steam:1091500 {}] [expr {1000000 * 1000 + 50000 * 10}]
check "an unknown game has no start" [hud::quick::started steam:1 {}] ""
hud::games::configure -proc /proc

# ---- the Tk drawing of the card (the canvas path of hud::draw::paint) does not fail ----
canvas .c -width 1440 -height 900 -background #000000 -highlightthickness 0
hud::quick::open win7 "Cyberpunk 2077" "" $start
lassign [hud::quick::ops 1440 900 0] u o
if {[catch {hud::draw::paint .c [concat $u $o]} err]} { puts "  FAIL the card does not paint on a canvas: $err"; incr fails } else { ok "the card paints on a Tk canvas" }

file delete -force $tmp
if {$fails} { puts "  $fails failed"; exit 1 }
exit 0
