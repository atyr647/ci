# tests/hud-store.tcl - the Game HUD's settings and game detection without a display (tclsh):
#   hud-store.tcl   the Game overlay store resolved into the HUD's words, per game, and its change detection
#   hud-games.tcl   the game processes in a /proc tree, and which window is a game (a stand-in window stream)
#   hud-frames.tcl  the file source on a FIFO, gamescope's fps= lines, and two paths in order
set repo [file dirname [file dirname [file normalize [info script]]]]
set D [file join $repo srcpkgs ribbon-desktop files apps]
set T [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] hud-store-[pid]]
file mkdir $T
set ::env(RIBBON_GAMES_CONF) $T/game-overlay.conf
set ::env(RIBBON_GAMES_HOME) [file join $repo tests fixtures launchers steam]
set ::env(HOME) $T
set fails 0
proc check {what got want} {
	if {$got eq $want} { puts "  ok   $what" } else { puts "  FAIL $what: got {$got}, want {$want}"; incr ::fails }
}
source [file join $D hud hud.tcl]
foreach f {hud-frames.tcl hud-store.tcl hud-games.tcl} { source [file join $D hud $f] }

# ---- the store, written the way the page writes it (hudstore.tcl in its own interpreter) ----
set w [interp create]
$w eval [list source [file join $D settings hudstore.tcl]]
proc store {script} { $::w eval $script; $::w eval hud::write_file }

check "no file: the built-in Defaults in the HUD's words" [hud::store::load][hud::store::record ""] \
	"1[dict create on 1 start 1 source auto layout full position top-right scale 100 opacity 86 contents {frametime low graph game gpu vram cpu mem power net}]"
check "the HUD's own defaults are the store's" [dict filter [hud::store::record ""] key layout position scale opacity contents] [hud::settings_defaults]

store {
	hud::put_default pos bl; hud::put_default scale 125; hud::put_default transp 30; hud::put_default layout compact
	hud::put_default contents {frametime low1 gamename cpu clock}
	hud::put steam:570 pos tr; hud::put steam:570 layout fps; hud::put steam:570 source compositor
	hud::put steam:730 on 0
	hud::add_game {My Game} /opt/mygame/run.sh /opt/mygame/art.png
}
check "the file changed" [hud::store::changed] 1
hud::store::load
check "read: not changed any more" [hud::store::changed] 0
set r [hud::store::record ""]
check "Defaults: position, scale, opacity (100 - transparency), layout" \
	[list [dict get $r position] [dict get $r scale] [dict get $r opacity] [dict get $r layout]] {bottom-left 125 70 compact}
check "Defaults: contents in the HUD's names (low1 -> low, gamename -> game)" [dict get $r contents] {frametime low game cpu clock}
set r [hud::store::record steam:570]
check "a game: its own fields over Defaults" \
	[list [dict get $r position] [dict get $r layout] [dict get $r source] [dict get $r scale] [dict get $r opacity]] {top-right fps compositor 125 70}
check "a game with the overlay off" [dict get [hud::store::record steam:730] on] 0
check "an unknown game uses Defaults" [hud::store::record steam:999999] [hud::store::record ""]
check "hud::configure takes the record" [dict get [hud::configure [hud::store::record steam:570]] position] top-right
check "the games added by hand" [hud::store::programs] {path:/opt/mygame/run.sh /opt/mygame/run.sh}
check "a hand-added game's name and art" [list [hud::store::title path:/opt/mygame/run.sh] [hud::store::art path:/opt/mygame/run.sh]] {{My Game} /opt/mygame/art.png}
set steamname [hud::store::title steam:620]
check "a Steam game's name from its manifest (the launcher fixtures)" $steamname {Portal 2}
check "an unknown key has no name" [hud::store::title steam:999999] ""
check "Show when a game starts is on somewhere" [hud::store::wants_start] 1
store { hud::put_default start 0 }
hud::store::load
check "off in Defaults and in every game: nothing asks for a start" [hud::store::wants_start] 0
store { hud::put steam:570 start 1 }
hud::store::load
check "one game asks for it" [hud::store::wants_start] 1
set f [open $T/game-overlay.conf w]; puts $f "this is \{ not a dict"; close $f
hud::store::load
check "a broken file gives the built-in Defaults" [dict get [hud::store::record ""] position] top-right
set f [open $T/game-overlay.conf w]; puts $f "defaults {pos} games {steam:570 {on}} added {path:/x {name}} hidden {k}"; close $f
check "broken sections inside the file: no error, the built-in Defaults" \
	[list [catch {hud::store::load} e] [dict get [hud::store::record ""] position] [dict get [hud::store::record steam:570] on] [hud::store::programs]] {0 top-right 1 {}}

# ---- processes: a /proc tree ----
set P $T/proc
proc mkproc {pid start cmd env {exe ""} {ppid 1}} {
	set d $::P/$pid
	file mkdir $d
	set f [open $d/cmdline w]; fconfigure $f -translation binary; puts -nonewline $f [join $cmd \0]\0; close $f
	set f [open $d/environ w]; fconfigure $f -translation binary; puts -nonewline $f [join $env \0]\0; close $f
	set f [open $d/stat w]; puts $f "$pid (a (odd) name) S $ppid 1 1 0 -1 4194304 1 0 0 0 0 0 0 0 20 0 1 0 $start 1000 100"; close $f
	if {$exe ne ""} { exec ln -s $exe $d/exe }
}
mkproc 100 500 {/usr/bin/steam} {HOME=/home/u PATH=/usr/bin}
mkproc 200 900 {/games/hl2_linux -game portal} {HOME=/home/u SteamAppId=400 SteamGameId=400}
mkproc 201 1200 {wineserver} {SteamAppId=570 X=1}
mkproc 300 700 {python3 /usr/bin/lutris lutris:rungame/quake} {HOME=/home/u}
mkproc 400 600 {/opt/heroic/game} {HEROIC_APP_NAME=Fortnite}
mkproc 500 100 {/bin/sh /opt/mygame/run.sh} {A=1}
mkproc 501 150 {mygame.bin} {A=1} /opt/other/bin
file mkdir $P/self
hud::games::configure -proc $P
set progs {path:/opt/mygame/run.sh /opt/mygame/run.sh path:/opt/other/bin /opt/other/bin}
check "the game processes, newest first" [hud::games::scan $progs] \
	{steam:570 1200 steam:400 900 lutris:quake 700 heroic:Fortnite 600 path:/opt/other/bin 150 path:/opt/mygame/run.sh 100}
check "Steam itself (no SteamAppId) is not a game process" [dict exists [hud::games::scan {}] steam:0] 0

# ---- windows ----
proc win {app full} { dict create id 7 app $app title T full $full }
check "steam_app_N is the game N" [hud::games::identify [win steam_app_1091500 0] {}] {game 1 key steam:1091500}
check "steam_app_0 (a non-Steam shortcut) is a game with no key" [hud::games::identify [win steam_app_0 0] {}] {game 1 key {}}
check "gamescope takes its key from the processes" [hud::games::identify [win gamescope 0] {}] {game 1 key steam:570}
check "a hand-added game by its program name" [hud::games::identify [win Run 0] $progs] {game 1 key path:/opt/mygame/run.sh}
check "a fullscreen window with a game process behind it" [hud::games::identify [win Portal 1] {}] {game 1 key steam:570}
check "the same window not fullscreen is not a game" [hud::games::identify [win Portal 0] {}] {game 0 key {}}
check "a fullscreen game's window takes its own process's game, not the newest one" [hud::games::identify [win hl2_linux 1] {}] {game 1 key steam:400}
mkproc 600 1300 {/usr/lib/firefox/firefox --new-window} {HOME=/home/u} /usr/lib/firefox/firefox
mkproc 601 1310 {/usr/bin/mpv film.mkv} {HOME=/home/u}
check "a fullscreen video in a browser while a game runs is not a game" [hud::games::identify [win firefox 1] {}] {game 0 key {}}
check "a fullscreen video player while a game runs is not a game" [hud::games::identify [win mpv 1] {}] {game 0 key {}}
mkproc 700 1400 {/usr/bin/gamescope -f -- %command%} {SteamAppId=730}
mkproc 701 1410 {/games/csgo/cs2} {HOME=/home/u} "" 700
check "a game's own child process (no marker of its own) takes the game of its parent" [hud::games::identify [win cs2 1] {}] {game 1 key steam:730}
check "gamescope takes the game it runs, not the newest one" [hud::games::identify [win gamescope 0] {}] {game 1 key steam:730}
file delete -force $P/600 $P/601 $P/700 $P/701
check "the Steam client is not a game" [hud::games::identify [win steam 0] $progs] {game 0 key {}}
hud::games::configure -proc $T/empty
check "fullscreen with no game process: not a game" [hud::games::identify [win mpv 1] $progs] {game 0 key {}}
check "gamescope with no known process: a game, Defaults" [hud::games::identify [win gamescope 1] {}] {game 1 key {}}
check "no window" [hud::games::identify {} {}] {game 0 key {}}

# the window stream, from a stand-in for ribbon-shell-watch
set fake $T/watch.sh
set f [open $fake w]
puts $f "#!/bin/sh\nprintf 'T+ 1\\nT 1 app foot\\nT 1 title Terminal\\nT 1 state act\\nT 1 done\\nW+ 1\\nW 1 name One\\nW done\\nready\\n'"
puts $f "read line; printf 'T+ 2\\nT 2 app steam_app_570\\nT 2 title Dota 2\\nT 2 state act,full\\nT 2 done\\nT 1 state -\\nT 1 done\\n'"
puts $f "read line; printf 'T- 2\\nT 1 state act\\nT 1 done\\n'; read line"
close $f
file attributes $fake -permissions 0755
set ::events {}
proc changed {} { lappend ::events [hud::games::front]; set ::tick 1 }
check "the helper starts" [hud::games::start -helper [list $fake] -changed changed] 1
proc waitev {n} { set t [after 3000 {set ::tick timeout}]; while {[llength $::events] < $n && $::tick ne "timeout"} { vwait ::tick }; after cancel $t }
set ::tick 0
waitev 1
check "the window in front" [lindex $::events end] {id 1 app foot title Terminal full 0}
puts $::hud::games::chan go; waitev 2
check "a game comes to the front, fullscreen" [lindex $::events end] {id 2 app steam_app_570 title {Dota 2} full 1}
check "both windows exist" [list [hud::games::exists 1] [hud::games::exists 2]] {1 1}
puts $::hud::games::chan go; waitev 3
check "it closes: the other window is in front again" [list [lindex $::events end] [hud::games::exists 2]] {{id 1 app foot title Terminal full 0} 0}
hud::games::stop
check "a helper that is not there" [hud::games::start -helper [list $T/none]] 0

# ---- frames: a FIFO stays open between polls, gamescope's lines, two paths ----
set pw [hud::frames::parse "8.5 fps=100\nfocus=3 fps=0 x"]
check "frame words: times in ms, fps=N (300 frames of 1000/N ms), other keys skipped" [list [lindex $pw 0] [llength $pw] [lsort -unique [lrange $pw 1 end]]] {8.5 301 10.0}
exec mkfifo $T/stats
hud::frames::use_file $T/layer.txt $T/stats
hud::frames::poll
check "no producer: no frame data" [dict get [hud::frames::numbers] ok] 0
# a producer that opens the pipe for writing only, as gamescope does: it must not block or break between polls
set wr [open $T/stats {WRONLY NONBLOCK}]
fconfigure $wr -buffering line
puts $wr "fps=125.0"; puts $wr "focus=1"
hud::frames::poll
puts $wr "fps=125.0"
hud::frames::poll
check "the pipe's fps= lines give frame times (125 fps = 8.0 ms)" [dict filter [hud::frames::numbers] key ok fps ft] {ok 1 fps 125 ft 8.0}
# gamescope writes one fps= line per 300 frames (its steamcompmgr.cpp): 5 s apart at 60 fps
puts $wr "fps=50.0"
hud::frames::poll
check "a new fps= line is the frame rate now (it stands for 300 frames)" [dict filter [hud::frames::numbers] key ok fps ft] {ok 1 fps 50 ft 20.0}
set st [lindex $::hud::frames::file_state 1]
dict set st last [expr {[clock milliseconds] - 3000}]
lset ::hud::frames::file_state 1 $st
hud::frames::poll
check "3 s after a 50 fps line (the next is due 6 s after it) there is still frame data" [dict get [hud::frames::numbers] ok] 1
set st [lindex $::hud::frames::file_state 1]
dict set st last [expr {[clock milliseconds] - 12000}]
lset ::hud::frames::file_state 1 $st
hud::frames::poll
check "12 s after it (two lines missed): no frame data" [dict get [hud::frames::numbers] ok] 0
puts $wr "fps=125.0"
hud::frames::poll
set f [open $T/layer.txt w]; puts $f "5.0 5.0 5.0 5.0"; close $f
for {set i 0} {$i < 30} {incr i} { set f [open $T/layer.txt a]; puts $f "5.0"; close $f; hud::frames::poll }
check "the first path with data wins (the layer's file before the pipe)" [dict get [hud::frames::numbers] fps] 200
close $wr
hud::frames::use_file $T/stats
hud::frames::poll
check "the source changed: the old numbers are gone" [dict get [hud::frames::numbers] ok] 0

# ---- frames: the Vulkan layer's lines (pid=PID ms ...): several processes on one pipe, the pick, the backlog ----
check "pid= lines by process; an untagged line is the \"\" producer's" \
	[hud::frames::parse_groups "pid=10 8.0 8.5\npid=11 16.0\n7.0 fps=50\npid=10 9.0\n"] \
	[dict create 10 {8.0 8.5 9.0} 11 16.0 "" [concat 7.0 [lrepeat 300 20.0]]]
exec mkfifo $T/layer
set lw [open $T/layer {RDWR NONBLOCK}]
fconfigure $lw -buffering line
# a backlog from before the HUD came up is dropped (all but the last fps= line)
puts $lw "pid=10 50.0 50.0 50.0"
hud::frames::use_file $T/layer
hud::frames::poll
check "the backlog in the pipe when the source starts is not shown" [dict get [hud::frames::numbers] ok] 0
proc feed {line {n 1}} { for {set i 0} {$i < $n} {incr i} { puts $::lw $line }; hud::frames::poll }
feed "pid=10 8.0 8.0 8.0 8.0 8.0" 7
feed "pid=11 25.0 25.0" 2
check "two processes: without a pick the one shown stays (pid 10, 125 fps)" [dict get [hud::frames::numbers] fps] 125
set ::picked {}
proc ::pick_11 {cands} { lappend ::picked $cands; return 11 }
hud::frames::configure -pick ::pick_11
feed "pid=10 8.0 8.0 8.0 8.0 8.0"
check "the pick is given {pid frames} with the one shown first" [lindex $::picked end] {{10 5} {11 0}}
feed "pid=11 25.0 25.0 25.0" 12
check "the pick chose pid 11: its frames only, from afresh (40 fps, not a mix)" [dict filter [hud::frames::numbers] key ok fps low] {ok 1 fps 40 low 40}
proc ::pick_none {cands} { return - }
hud::frames::configure -pick ::pick_none
feed "pid=11 25.0"
feed "pid=11 25.0"
check "a pick of none: no frame data from this path" [dict get [hud::frames::numbers] ok] 0
proc ::pick_err {cands} { error boom }
hud::frames::configure -pick ::pick_err
feed "pid=11 25.0"
check "a pick that fails: none" [dict get [hud::frames::numbers] ok] 0
hud::frames::configure -pick ""
feed "pid=11 25.0"
check "no pick again: the busiest" [dict get [hud::frames::numbers] ok] 1
# drain: the HUD was hidden while the game ran on; what piled up in the pipe is dropped at the next start
for {set i 0} {$i < 50} {incr i} { puts $lw "pid=11 100.0 100.0" }
hud::frames::drain
hud::frames::poll
feed "pid=11 25.0" 2
check "after drain the pile-up is not in the numbers (40 fps, not 10)" [dict get [hud::frames::numbers] fps] 40
close $lw
# which game a process belongs to: its own key, else its parent's (the main.tcl pick matches it to the game in front)
hud::games::configure -proc $P
mkproc 700 1400 {/usr/bin/gamescope -f -- %command%} {SteamAppId=730}
mkproc 701 1410 {/games/csgo/cs2} {HOME=/home/u} "" 700
mkproc 601 1310 {/usr/bin/mpv film.mkv} {HOME=/home/u}
check "key_of_pid: a Steam game's own process" [hud::games::key_of_pid 200 {}] steam:400
check "key_of_pid: a child takes its parent's game (cs2 under gamescope with SteamAppId)" [hud::games::key_of_pid 701 {}] steam:730
check "key_of_pid: a process of no game" [hud::games::key_of_pid 601 {}] ""
check "key_of_pid: a game added by hand, by its program" [hud::games::key_of_pid 501 {path:/opt/other/bin /opt/other/bin}] path:/opt/other/bin
check "key_of_pid: a pid that is gone" [hud::games::key_of_pid 99999 {}] ""
check "producer: the game in front's process, though another is busier" [hud::games::producer steam:730 {{601 9} {701 3}} {}] 701
check "producer: none of the game's: an untagged producer" [hud::games::producer steam:730 {{601 9} {"" 3}} {}] ""
check "producer: none at all: no frame data (not another program's frames)" [hud::games::producer steam:730 {{601 9}} {}] -
check "producer: no game key: the first" [hud::games::producer "" {{601 9} {701 3}} {}] 601

file delete -force $T
if {$fails} { puts "hud-store: $fails failed"; exit 1 }
puts "hud-store: all passed"
