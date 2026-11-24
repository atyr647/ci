# hud-games.tcl - which game is in front: the compositor's windows (ribbon-shell-watch, the shell's helper: this is a
# second, read-only instance of it) and the processes behind them (/proc). No Tk.
#
# A window is a game when
#   its app id is steam_app_N        (a Steam game under Proton; N is the AppID, 0 for a non-Steam shortcut)
#   its app id is gamescope          (a game in a nested gamescope; the AppID comes from the processes)
#   its app id is the program name of a game added by hand (Settings → Game overlay → Add game)
#   it is fullscreen and a game's process runs: a process with SteamAppId (a native Steam game), HEROIC_APP_NAME
#     (Heroic) or a lutris:rungame/SLUG argument (Lutris) in it, or the program of a game added by hand. When the app
#     id names running processes (argv[0] or exe), only theirs count: one in a game (or its parent in one) gives that
#     game; none (a fullscreen browser or video player while a game runs) is not a game
# Its key is the store's: steam:APPID, heroic:APPNAME, lutris:SLUG, path:PROGRAM, or "" (a game the store has no key
# for: it uses Defaults). Everything else is not a game. The foreign-toplevel protocol carries no process id, so the
# process rules need the window to be fullscreen; the newest matching process wins.
#
#   hud::games::start ?-helper CMD? ?-changed CMD?   -> 1 when the helper runs; CMD is called after each batch of changes
#   hud::games::front                -> the active window {id ID app APP title TITLE full 0|1}, or {}
#   hud::games::exists ID            -> 1 while that window is open
#   hud::games::identify WINDOW PROGRAMS   -> {game 0|1 key KEY}; PROGRAMS is {KEY PROGRAM ...} (hud::store::programs)
#   hud::games::scan PROGRAMS        -> {KEY START ...} of the game processes running now, newest first
#   hud::games::producer KEY CANDS PROGRAMS -> which frame producer is the game's (see there)
#   hud::games::key_of_pid PID PROGRAMS   -> the game a process belongs to (its own key, else its nearest parent's),
#                                    "" for none; remembered for 5 s (the frame source asks it at every poll)
#   hud::games::configure -proc DIR  the /proc to read (tests)
#   hud::games::stop

namespace eval ::hud::games {
	variable chan ""
	variable tl                 ;# id -> {app title state}
	array set tl {}
	variable changed_cmd ""
	variable pending ""
	variable ready 0
	variable helper ""
	variable procroot /proc
}

proc ::hud::games::configure {args} {
	variable procroot
	foreach {k v} $args {
		if {$k eq "-proc"} { set procroot [string trimright $v /] } else { error "hud::games::configure: unknown option $k" }
	}
}

proc ::hud::games::start {args} {
	variable chan
	variable changed_cmd
	variable helper
	variable ready
	set def ribbon-shell-watch
	if {[info exists ::env(RIBBON_HUD_WATCH)]} { set def $::env(RIBBON_HUD_WATCH) }
	set o [dict merge [list -helper $def -changed ""] $args]
	set changed_cmd [dict get $o -changed]
	set helper [dict get $o -helper]
	stop
	set ready 0
	if {$helper eq "" || [catch {::open [list | {*}$helper 2>/dev/null] r+} ch]} { return 0 }
	set chan $ch
	fconfigure $ch -blocking 0 -buffering line -translation lf -encoding utf-8
	fileevent $ch readable [list ::hud::games::readable]
	return 1
}

proc ::hud::games::stop {} {
	variable chan
	variable tl
	variable pending
	if {$chan ne ""} { catch {::close $chan}; set chan "" }
	if {$pending ne ""} { after cancel $pending; set pending "" }
	array unset tl
}

proc ::hud::games::running {} { variable chan; variable ready; expr {$chan ne "" && $ready} }

proc ::hud::games::readable {} {
	variable chan
	variable tl
	variable ready
	variable helper
	if {$chan eq ""} return
	while {[gets $chan line] >= 0} {
		set rest ""; set id ""; set field ""
		regexp {^(\S+)(?: (\S+))?(?: (\S+))?(?: (.*))?$} $line -> kind id field rest
		switch -- $kind {
			T+ { set tl($id) [dict create app "" title "" state ""] }
			T {
				if {![info exists tl($id)]} continue
				if {$field eq "done"} { changed; continue }
				if {$field ni {app title state}} continue
				if {$field eq "state" && $rest eq "-"} { set rest "" }
				dict set tl($id) $field $rest
			}
			T- { unset -nocomplain tl($id); changed }
			ready { set ready 1; changed }
		}
	}
	if {[eof $chan]} {
		# the helper went away (no compositor support, or the compositor restarted): one more try when it had worked
		set had $ready
		catch {::close $chan}
		set chan ""
		set ready 0
		array unset tl
		changed
		if {$had} { after 5000 [list ::hud::games::start -helper $helper -changed $::hud::games::changed_cmd] }
	}
}

# one call of the changed command for a burst of lines
proc ::hud::games::changed {} {
	variable pending
	if {$pending ne ""} return
	set pending [after 30 ::hud::games::fire]
}

proc ::hud::games::fire {} {
	variable pending
	variable changed_cmd
	set pending ""
	if {$changed_cmd ne ""} { catch {uplevel #0 $changed_cmd} }
}

proc ::hud::games::exists {id} { variable tl; info exists tl($id) }

proc ::hud::games::front {} {
	variable tl
	foreach id [array names tl] {
		set flags [split [dict get $tl($id) state] ,]
		if {"act" in $flags && "min" ni $flags} {
			return [dict create id $id app [dict get $tl($id) app] title [dict get $tl($id) title] full [expr {"full" in $flags}]]
		}
	}
	return {}
}

# ---- processes ---------------------------------------------------------------------------------------------------

proc ::hud::games::slurp {path} {
	if {[catch {set f [::open $path r]; fconfigure $f -translation binary; set t [::read $f]; ::close $f}]} { return "" }
	return $t
}

# Every readable process: PID -> {key KEY start START ppid PPID names {NAME ...}}. KEY is its game ("" for none) by its
# own command line and environment; NAMES are the file names of its argv[0] and its exe. Only this user's processes
# can be read; the others are skipped.
proc ::hud::games::procs {programs} {
	variable procroot
	set byprog {}
	foreach {k p} $programs { dict set byprog $p $k }
	set out {}
	foreach d [glob -nocomplain -directory $procroot -types d {[0-9]*}] {
		set cmd [split [string trimright [slurp $d/cmdline] \0] \0]
		if {[llength $cmd] == 0} continue
		lassign [own_key $d $cmd $byprog] key exe
		# field 22 of stat is the start time, field 4 the parent; the command name (field 2) may hold spaces, so count
		# from the last ")"
		set stat [slurp $d/stat]
		set after [split [string range $stat [expr {[string last ")" $stat] + 2}] end]]
		set start [lindex $after 19]
		if {![string is wide -strict $start]} { set start 0 }
		set ppid [lindex $after 1]
		set names {}
		foreach n [list [lindex $cmd 0] $exe] {
			if {$n ne ""} { lappend names [lindex [split $n {/\\}] end] }
		}
		dict set out [file tail $d] [dict create key $key start $start ppid $ppid names $names]
	}
	return $out
}

# A process's own game key by its command line, program and environment: {KEY EXE} (KEY "" for none). BYPROG is
# program -> key of the games added by hand.
proc ::hud::games::own_key {d cmd byprog} {
	set key ""
	foreach a $cmd {
		if {[regexp {^lutris:rungame/([^/\s]+)$} $a -> slug]} { set key lutris:$slug; break }
		if {[dict exists $byprog $a]} { set key [dict get $byprog $a]; break }
	}
	if {[catch {file readlink $d/exe} exe]} { set exe "" }
	if {$key eq "" && $exe ne "" && [dict exists $byprog $exe]} { set key [dict get $byprog $exe] }
	if {$key eq ""} {
		foreach e [split [slurp $d/environ] \0] {
			if {[regexp {^SteamAppId=([1-9][0-9]*)$} $e -> n]} { set key steam:$n; break }
			if {[regexp {^HEROIC_APP_NAME=(.+)$} $e -> n]} { set key heroic:$n; break }
		}
	}
	return [list $key $exe]
}

proc ::hud::games::key_of_pid {pid programs} {
	variable procroot
	variable pidkeys
	if {![info exists pidkeys]} { set pidkeys {} }
	if {![string is integer -strict $pid]} { return "" }
	set now [clock milliseconds]
	if {[dict exists $pidkeys $pid] && $now - [lindex [dict get $pidkeys $pid] 0] < 5000} { return [lindex [dict get $pidkeys $pid] 1] }
	set byprog {}
	foreach {k p} $programs { dict set byprog $p $k }
	set key ""
	set p $pid
	for {set n 0} {$n < 64 && $p > 1} {incr n} {
		set d $procroot/$p
		set cmd [split [string trimright [slurp $d/cmdline] \0] \0]
		if {[llength $cmd] == 0} break
		set key [lindex [own_key $d $cmd $byprog] 0]
		if {$key ne ""} break
		set stat [slurp $d/stat]
		set p [lindex [split [string range $stat [expr {[string last ")" $stat] + 2}] end]] 1]
		if {![string is integer -strict $p]} break
	}
	if {[dict size $pidkeys] > 256} { set pidkeys {} }
	dict set pidkeys $pid [list $now $key]
	return $key
}

# Which frame producer to show for the game in front (hud-frames.tcl's pick): CANDS is {{pid frames} ...}, the one
# shown last first, then the busiest. A process of the game KEY; else a producer that does not say its process (""),
# such as a game's own tool writing the pipe; else none ("-"). With KEY "" (no game in front, or one the store has no
# key for) the first.
proc ::hud::games::producer {key cands programs} {
	if {$key eq ""} { return [lindex $cands 0 0] }
	foreach c $cands {
		set pid [lindex $c 0]
		if {$pid ne "" && [key_of_pid $pid $programs] eq $key} { return $pid }
	}
	foreach c $cands { if {[lindex $c 0] eq ""} { return "" } }
	return -
}

# The game processes running now: {KEY START ...}, the newest (largest start time) first.
proc ::hud::games::scan {programs} {
	newest [procs $programs]
}

proc ::hud::games::newest {ps} {
	set found {}
	dict for {pid p} $ps {
		if {[dict get $p key] ne ""} { lappend found [list [dict get $p key] [dict get $p start]] }
	}
	set out {}
	foreach f [lsort -integer -decreasing -index 1 $found] {
		if {![dict exists $out [lindex $f 0]]} { dict set out [lindex $f 0] [lindex $f 1] }
	}
	return $out
}

# the game of a process: its own, else its nearest parent's ("" for none)
proc ::hud::games::game_of {ps pid} {
	for {set n 0} {$n < 64 && [dict exists $ps $pid]} {incr n} {
		if {[dict get $ps $pid key] ne ""} { return [dict get $ps $pid key] }
		set pid [dict get $ps $pid ppid]
	}
	return ""
}

proc ::hud::games::identify {win programs} {
	if {[dict size $win] == 0} { return [dict create game 0 key ""] }
	set app [dict get $win app]
	if {[regexp {^steam_app_(\d+)$} $app -> n]} {
		return [dict create game 1 key [expr {$n > 0 ? "steam:$n" : ""}]]
	}
	foreach {k p} $programs {
		if {$app ne "" && [string equal -nocase $app [file rootname [file tail $p]]]} { return [dict create game 1 key $k] }
	}
	set gs [expr {$app eq "gamescope"}]
	if {!$gs && ![dict get $win full]} { return [dict create game 0 key ""] }
	# the processes the window's app id names (its program's file name, with or without its extension): the window
	# is theirs. One of them in a game (itself or a parent): that game, the newest. Theirs and none in a game (a video
	# player or a browser in fullscreen while a game runs): not a game. None: the newest game process.
	set ps [procs $programs]
	set owned {}
	set owners 0
	dict for {pid p} $ps {
		set mine 0
		foreach n [dict get $p names] {
			if {[string equal -nocase $app $n] || [string equal -nocase $app [file rootname $n]]} { set mine 1 }
		}
		if {!$mine} continue
		incr owners
		set k [game_of $ps $pid]
		if {$k ne ""} { lappend owned [list $k [dict get $p start]] }
	}
	if {[llength $owned]} {
		return [dict create game 1 key [lindex [lsort -integer -decreasing -index 1 $owned] 0 0]]
	}
	if {$owners && !$gs} { return [dict create game 0 key ""] }
	set running [newest $ps]
	if {[dict size $running]} { return [dict create game 1 key [lindex [dict keys $running] 0]] }
	return [dict create game $gs key ""]
}
