# main.tcl - ribbon-hud: the Game HUD daemon. Draws hud.tcl's layouts on the layer-shell overlay (ribbon-hud-surface)
# and takes its orders from a FIFO ($XDG_RUNTIME_DIR/ribbon-hud, written by the ribbon-hud command: bin/ribbon-hud).
#
#   wish main.tcl [--layout off|fps|compact|full] [--auto]
#     --layout   starts in that layout (default off)
#     --auto     the session's start, or Settings after a change: leaves at once when nothing in the store asks for
#                "Show when a game starts"; a game already in front gets its HUD
#
# SETTINGS. Settings → Game overlay writes ~/.config/ribbon/game-overlay.conf; hud-store.tcl resolves it. The record
# in effect is the one of the game in front (its own fields over Defaults), else Defaults. Position, scale,
# transparency and contents are drawn from it; its layout is the one a game starts in and the one a change in Settings
# switches to; overlay off means no HUD for that game (Super+F12 does nothing); the frame source picks the producer.
# The file is looked at again on every order and window change, and twice a second while the HUD is up.
#
# GAMES. hud-games.tcl follows the compositor's windows. A game window that comes to the front for the first time
# gets the HUD in its layout when its record says on and "Show when a game starts". The HUD belongs to a window (the
# game, or the window in front when Super+F12 brought it up): unpinned it is up only while that window is in front,
# pinned it stays; when the window closes the HUD goes (a pinned one stays). Close hides it until the next Super+F12
# or the next game. Without the helper (RIBBON_HUD_WATCH, default ribbon-shell-watch) there is no focus tracking and
# the HUD is up whenever its layout is not off.
#
# FRAMES. The compositor's pipe ($XDG_RUNTIME_DIR/ribbon-hud-stats, RIBBON_HUD_STATS; gamescope writes it when the game
# is started through ribbon-gamescope) and, for the Automatic source only and before it, the pipe of Ribbon's Vulkan
# layer ($XDG_RUNTIME_DIR/ribbon-hud-frames, RIBBON_HUD_FRAMES; native/hud-frames-layer.c). The daemon makes both
# FIFOs. Every Vulkan program writes the layer's pipe; the frames shown are those of a process of the HUD's game (the
# game in front, or the pinned one; hud::games::key_of_pid), else of a producer that does not say its process, else (a
# game the store has no key for, or no game) the busiest. See hud-frames.tcl.
#
# QUICK MENU. "quick [0|1]" (Super+Esc: ribbon-hud quick; the controller's home button through the surface) opens or
# closes the in-game quick menu (quick.tcl) on the same surface, over a game only (on the desktop it does nothing; the
# home button is Steam's while Steam runs): the game is dimmed, the surface takes the keyboard and every click and grabs
# the controllers; the HUD steps left. Its keys (held arrows repeat), clicks and buttons come back as the surface's
# events.
#
# Environment: RIBBON_HUD_SURFACE (the overlay helper, default ribbon-hud-surface), RIBBON_HUD_WATCH, RIBBON_HUD_LOG (a
# file that gets one line per event and per "state" order; tests read it), RIBBON_HUD_FRAMES, RIBBON_HUD_STATS,
# RIBBON_HUD_PROC (the /proc to read, tests).
# Tk is here for the font metrics the layout needs; no Tk window is shown.
if {$tcl_platform(platform) eq "unix"} { encoding system utf-8 }
wm withdraw .
set appdir [file dirname [file normalize [info script]]]
source -encoding utf-8 [file join $appdir hud.tcl]
hud::init_modules
source -encoding utf-8 [file join $appdir quick.tcl]

namespace eval ::hudd {
	variable layout off          ;# off fps compact full: what Super+F12 cycles
	variable hidden 0            ;# Close: hidden until the next cycle or the next game
	variable interactive 0
	variable fifo ""
	variable runtime [expr {[info exists ::env(XDG_RUNTIME_DIR)] ? $::env(XDG_RUNTIME_DIR) : "/tmp"}]
	variable running 0
	variable key ""              ;# the store key the settings are resolved for ("": Defaults)
	variable rec {}              ;# the record in effect (hud::store::record)
	variable target ""           ;# the window the HUD belongs to ("": none)
	variable frontid ""          ;# the window in front
	variable game 0              ;# it is a game
	variable seen {}             ;# the game windows that have had their start
	variable first 1             ;# the first batch of windows has not come yet
	variable auto 0
	variable idcache {}          ;# "id app full" -> {at result}
	variable lastfront ""
	variable pendquick 0         ;# Super+Esc came before the windows were known
	variable tipkey ""           ;# the button under the pointer (pin close), pressed:KEY after a press on it
	variable tipup ""            ;# the button whose name is shown
	variable tiptimer ""
	variable tiplast 0           ;# when a name last went (ms)
	variable checked 0
	variable kb 0                ;# the surface has been told to take the keyboard and the controllers
}

proc ::hudd::log {text} {
	if {![info exists ::env(RIBBON_HUD_LOG)]} return
	catch {
		set fh [::open $::env(RIBBON_HUD_LOG) a]
		puts $fh "[clock milliseconds] $text"
		::close $fh
	}
}

# 1 while there is focus tracking
proc ::hudd::watching {} { hud::games::running }

# the HUD is to be on screen now
proc ::hudd::want {} {
	variable layout
	variable hidden
	variable target
	variable frontid
	if {$layout eq "off" || $hidden} { return 0 }
	if {[dict get $::hud::runtime pinned] || ![watching] || $target eq "" || $target eq $frontid} { return 1 }
	return 0
}

# Read the store again when the file changed (or FORCE) and take the record for the current key. Returns 1 when the
# record in effect changed.
proc ::hudd::resolve {{force 0}} {
	variable key
	variable rec
	variable layout
	variable checked
	set checked [clock milliseconds]
	if {$force || [hud::store::changed]} { hud::store::load }
	set new [hud::store::record $key]
	if {$new eq $rec} { return 0 }
	set old $rec
	set rec $new
	hud::configure [dict filter $new key position scale opacity contents]
	if {$layout ne "off"} {
		if {![dict get $new on]} {
			set layout off
		} elseif {[dict size $old] && [dict get $old layout] ne [dict get $new layout]} {
			set layout [dict get $new layout]
		}
	}
	frame_source
	set line "settings key=[expr {$key eq "" ? "defaults" : $key}]"
	dict for {k v} $new { append line " $k=[join $v ,]" }
	log $line
	return 1
}

# the files the frame source reads, for the record's source
proc ::hudd::frame_source {} {
	variable rec
	variable runtime
	set stats [expr {[info exists ::env(RIBBON_HUD_STATS)] ? $::env(RIBBON_HUD_STATS) : "$runtime/ribbon-hud-stats"}]
	if {![file exists $stats]} { catch {exec mkfifo -m 600 $stats} }
	set paths [list $stats]
	if {[dict get $rec source] eq "auto"} {
		set layer [expr {[info exists ::env(RIBBON_HUD_FRAMES)] ? $::env(RIBBON_HUD_FRAMES) : "$runtime/ribbon-hud-frames"}]
		if {![file exists $layer]} { catch {exec mkfifo -m 600 $layer} }
		set paths [linsert $paths 0 $layer]
	}
	if {$paths ne [hud::frames::file_paths]} { hud::frames::use_file {*}$paths }
}

# which of the processes that write frame times is shown (hud::frames::configure -pick; hud::games::producer): those
# of the HUD's game, the one in front or, pinned, the one it stays up for (key is kept for it while another is in front)
proc ::hudd::frame_pick {cands} {
	variable key
	hud::games::producer $key $cands [hud::store::programs]
}

# draw the current state on the surface, or hide it
proc ::hudd::redraw {} {
	variable interactive
	variable checked
	if {[clock milliseconds] - $checked >= 500} {
		set checked [clock milliseconds]
		if {[hud::store::changed]} { refresh; return }
	}
	variable layout
	variable kb
	set q [hud::quick::is_open]
	if {$q != $kb} {
		# the input first, then the picture: the menu's frame comes with the keyboard asked for
		set kb $q
		hud::surface::put_line "keyboard $q"
		hud::surface::put_line "grab $q"
		# the HUD steps aside while the menu is open (the "menu" order sets the same flag by hand)
		hud::set_runtime [list menu $q]
	}
	if {![want] && !$q} {
		hud::surface::show {}
		return
	}
	lassign [hud::surface::size] W H
	set ops [expr {[want] ? [hud::ops $W $H 1] : {}}]
	if {$q} {
		hud::quick::set_layout $layout
		lassign [hud::quick::ops $W $H 1] under over
		set ops [concat $under $ops $over]
		hud::surface::show $ops
		hud::surface::region quick
		return
	}
	variable tipup
	if {$tipup ne "" && $interactive} { lappend ops {*}[tip_ops $ops $W] }
	hud::surface::show $ops
	hud::surface::region {*}[expr {$interactive ? {pin close} : {}}]
}

# ---- the tooltips of the HUD's pin and close buttons (shell/tooltip.tcl's rules and look, drawn on the surface) ----
# The name comes 500 ms after the pointer stops over the button and goes when it leaves or presses (not back until it
# has left); a pill (26 tall, padding 0 9, radius 8, §bar, the §border ring, the menu shadow, 12 px 500 §fg) centred
# on the button, 6 px under the HUD's header.
proc ::hudd::tip_motion {x y} {
	variable tipkey
	variable tipup
	variable tiptimer
	set k [expr {$x < 0 ? "" : [hud::surface::hit_at $x $y]}]
	if {$k ni {pin close}} { set k "" }
	if {$k eq $tipkey || ($k ne "" && $k eq "pressed:$tipkey")} return
	if {[string match pressed:* $tipkey] && $k eq [string range $tipkey 8 end]} return
	variable tiplast
	set tipkey $k
	after cancel $tiptimer
	if {$tipup ne ""} { set tipup ""; set tiplast [clock milliseconds]; redraw }
	# moving straight on from a shown name to the other button shows its name at once (as tooltip.tcl)
	if {$k ne ""} { set tiptimer [after [expr {[clock milliseconds] - $tiplast < 400 ? 0 : 500}] ::hudd::tip_show] }
}
proc ::hudd::tip_show {} {
	variable tipkey
	variable tipup
	variable interactive
	if {$tipkey in {pin close} && $interactive} { set tipup $tipkey; log "tip $tipup"; redraw }
}
proc ::hudd::tip_press {} {
	variable tipkey
	variable tipup
	variable tiptimer
	after cancel $tiptimer
	if {$tipkey in {pin close}} { set tipkey pressed:$tipkey }
	if {$tipup ne ""} { set tipup ""; redraw }
}
# the pill's ops for the button whose hit box is in OPS
proc ::hudd::tip_ops {ops W} {
	variable tipup
	set h [lsearch -inline -index 1 [lsearch -all -inline -index 0 $ops hit] $tipup]
	if {$h eq ""} { return {} }
	lassign $h - - hx hy hw hh
	set name [expr {$tipup eq "close" ? "Close" : ([dict get $::hud::runtime pinned] ? "Unpin" : "Pin")}]
	array set c [array get ::hud::draw::c]
	set tw [expr {round(9 + [hud::draw::measure "Ribbon Inter 500" 12 $name] + 9)}]
	set x [expr {round($hx + $hw / 2.0 - $tw / 2.0)}]
	set x [expr {max(4, min($W - 4 - $tw, $x))}]
	# the header's rule is 11.5 under the buttons (at the HUD's scale)
	set y [expr {round($hy + $hh + 11.5 * $hh / 24.0 + 6)}]
	list [list rrect $x $y $tw 26 8 $c(BAR) [list $c(BORDER) 1] {18 40 0.45 #000000}] \
		[list text [expr {$x + 9}] [expr {$y + 13}] w "Ribbon Inter 500" 12 $c(FG) $name]
}

# the quick menu's Overlay card
proc ::hudd::set_layout {l} { verb "layout $l" }

# the quick menu's window orders (minimize|close ID) through the window helper
proc ::hudd::window {verb id} {
	if {$id eq "" || $::hud::games::chan eq ""} return
	puts $::hud::games::chan "$verb $id"
	flush $::hud::games::chan
}

# when the game KEY started, in ms ("" unknown)
proc ::hudd::started {key} { hud::quick::started $key [hud::store::programs] }

# sampling and frame polling run only while something is on screen
proc ::hudd::refresh {} {
	variable layout
	variable running
	resolve
	hud::configure [list layout $layout]
	set want [want]
	if {$want && !$running} { hud::start ::hudd::redraw; set running 1 }
	if {!$want && $running} { hud::stop; set running 0 }
	redraw
}

# what the window in front is: {game 0|1 key KEY}. A process scan is not repeated within 2 s for the same window
proc ::hudd::identify {f} {
	variable idcache
	if {[dict size $f] == 0} { return [dict create game 0 key ""] }
	set ck [list [dict get $f id] [dict get $f app] [dict get $f full]]
	set now [clock milliseconds]
	if {[dict exists $idcache $ck]} {
		lassign [dict get $idcache $ck] at r
		if {[dict get $r game] || $now - $at < 2000} { return $r }
	}
	set r [hud::games::identify $f [hud::store::programs]]
	if {[dict size $idcache] > 64} { set idcache {} }
	dict set idcache $ck [list $now $r]
	return $r
}

# the game's picture for the header; looked for again when the key changes or after 30 s (art Steam fetched since)
proc ::hudd::art {key} {
	variable artcache
	set now [clock milliseconds]
	if {![info exists artcache] || [lindex $artcache 0] ne $key || $now - [lindex $artcache 1] > 30000} {
		set artcache [list $key $now [hud::art::for_key $key]]
	}
	lindex $artcache 2
}

# the compositor's windows changed
proc ::hudd::on_windows {} {
	variable layout
	variable hidden
	variable key
	variable target
	variable frontid
	variable game
	variable seen
	variable first
	variable auto
	variable lastfront
	if {[hud::store::changed]} { hud::store::load }
	set f [hud::games::front]
	set frontid [expr {[dict size $f] ? [dict get $f id] : ""}]
	# the quick menu's game closed
	if {[hud::quick::is_open] && [hud::quick::window_id] ne "" && ![hud::games::exists [hud::quick::window_id]]} {
		hud::quick::close
	}
	# the window the HUD belonged to closed
	if {$target ne "" && ![hud::games::exists $target]} {
		set target ""
		set hidden 0
		if {![dict get $::hud::runtime pinned]} { set layout off }
		log "window closed layout=$layout"
	}
	set keep {}
	foreach s $seen { if {[hud::games::exists $s]} { lappend keep $s } }
	set seen $keep
	set g [identify $f]
	set game [dict get $g game]
	set started 0
	if {$game} {
		set key [dict get $g key]
		set name [hud::store::title $key]
		if {$name eq ""} { set name [dict get $f title] }
		hud::set_runtime [list name $name art [art $key]]
		if {$layout ne "off"} { set target $frontid }
		if {$frontid ni $seen} {
			lappend seen $frontid
			# a HUD the daemon was started for by Super+F12 is the user's: the game in front then gets no start
			set started [expr {!$first || $auto}]
		}
	} elseif {$target eq "" || $layout eq "off"} {
		set key ""
		hud::set_runtime [list name "" art ""]
	}
	set line "front id=$frontid art=[expr {[dict get $::hud::runtime art] ne ""}] app=[expr {[dict size $f] ? [dict get $f app] : ""}] game=$game key=$key name=[dict get $::hud::runtime name]"
	if {$line ne $lastfront} { set lastfront $line; log $line }
	if {[hud::games::running]} { set first 0 }
	# Super+Esc before the windows were known (the daemon started on it): the menu opens now, over a game only
	variable pendquick
	if {$pendquick && [hud::games::running]} {
		set pendquick 0
		if {$game} {
			hud::quick::open $frontid [dict get $::hud::runtime name] [art $key] [started $key]
		} else {
			log "quick ignored: no game in front"
		}
	}
	resolve
	if {$started} {
		variable rec
		if {[dict get $rec on] && [dict get $rec start]} {
			set layout [dict get $rec layout]
			set hidden 0
			set target $frontid
			log "game start key=$key layout=$layout"
		}
	}
	refresh
}

proc ::hudd::on_surface {line} {
	variable interactive
	log "surface $line"
	if {$line eq "gone"} { set ::hudd::done 1; return }
	hud::quick::surface_event $line
	if {[regexp {^key (\d+)} $line -> code]} { hud::quick::key_down $code; return }
	if {[regexp {^keyup (\d+)} $line -> code]} { hud::quick::key_up $code; return }
	if {[regexp {^repeat (-?\d+) (-?\d+)} $line -> rate delay]} { hud::quick::set_repeat $rate $delay; return }
	if {$line eq "focus 0"} { hud::quick::key_up ""; return }
	if {[regexp {^pad (\w+)} $line -> b]} { hud::quick::pad $b; return }
	if {[regexp {^motion (-?\d+) (-?\d+)} $line -> x y]} { tip_motion $x $y; return }
	if {$line eq "leave"} { tip_motion -1 -1; return }
	if {[regexp {^click (-?\d+) (-?\d+)} $line -> x y]} {
		tip_press
		if {[hud::quick::is_open]} { hud::quick::click $x $y; return }
		switch -- [hud::surface::hit_at $x $y] {
			pin { hudd::verb pin }
			close { hudd::verb close }
		}
	}
}

# The controller's home button with the menu closed: the menu, over a game, unless Steam runs: Steam's Guide button
# opens Steam's own overlay (Steam Input reads the controller itself, so the surface's grab does not hold it back),
# and one press must not open two menus. Super+Esc opens Ribbon's then.
proc ::hudd::home {} {
	if {[steam_running]} { log "home left to Steam"; return }
	verb {quick 1}
}
proc ::hudd::steam_running {} {
	foreach d [glob -nocomplain -directory $::hud::games::procroot -types d -- {[0-9]*}] {
		if {[catch {set fh [::open $d/comm r]}]} continue
		set comm [string trim [::read $fh]]
		::close $fh
		if {$comm eq "steam"} { return 1 }
	}
	return 0
}

proc ::hudd::verb {line} {
	variable layout
	variable hidden
	variable interactive
	set words [split [string trim $line]]
	set cmd [lindex $words 0]
	set arg [string trim [join [lrange $words 1 end] " "]]
	switch -- $cmd {
		cycle {
			variable rec
			variable target
			variable frontid
			variable key
			resolve
			if {![dict get $rec on]} {
				log "cycle ignored: the overlay is off for [expr {$key eq "" ? "all games" : $key}]"
				return
			}
			if {$hidden} {
				set hidden 0
				if {$layout eq "off"} { set layout fps }
			} elseif {$layout ne "off" && ![want]} {
				# up for another window: bring it here in the layout it has
			} else {
				set layout [dict get {off fps fps compact compact full full off} $layout]
			}
			set target [expr {$layout eq "off" ? "" : $frontid}]
			refresh
		}
		layout {
			variable target
			variable frontid
			if {$arg in {off fps compact full}} {
				set layout $arg; set hidden 0
				set target [expr {$layout eq "off" ? "" : $frontid}]
				refresh
			}
		}
		reload { resolve 1; refresh }
		pin {
			set cur [dict get $::hud::runtime pinned]
			hud::set_runtime [list pinned [expr {$arg in {0 1} ? $arg : !$cur}]]
			refresh
		}
		close { set hidden 1; refresh }
		menu { if {$arg in {0 1}} { hud::set_runtime [list menu $arg]; redraw } }
		quick {
			variable frontid
			variable game
			variable key
			variable target
			if {$arg eq ""} { set arg [expr {![hud::quick::is_open]}] }
			if {$arg eq "1" && ![hud::quick::is_open]} {
				# only over a game: the game in front. Until the windows are known (the daemon started on Super+Esc)
				# the menu waits for them (on_windows)
				if {![hud::games::running]} { variable pendquick 1; log "quick waits for the windows"; return }
				if {!$game} { log "quick ignored: no game in front"; return }
				hud::quick::open $frontid [dict get $::hud::runtime name] [art $key] [started $key]
			} elseif {$arg eq "0"} {
				hud::quick::close
			}
		}
		name { hud::set_runtime [list name $arg]; redraw }
		configure { hud::configure $arg; refresh }
		interactive { if {$arg in {0 1}} { set interactive $arg; redraw } }
		state {
			variable key
			variable game
			variable rec
			log "state quick=\{[hud::quick::state]\} tip=[set ::hudd::tipup] layout=$layout hidden=$hidden pinned=[dict get $::hud::runtime pinned] menu=[dict get $::hud::runtime menu] interactive=$interactive frames=[dict get [hud::frames::numbers] ok] shown=[want] game=$game key=[expr {$key eq "" ? "defaults" : $key}] source=[dict get $rec source] watch=[watching] name=[dict get $::hud::runtime name] mapped=[set ::hud::surface::mapped] config=[hud::config]"
		}
		snapshot { hud::surface::put_line "snapshot $arg" }
		quit { set ::hudd::done 1 }
	}
}

proc ::hudd::readable {} {
	variable fifo
	if {[catch {gets $fifo line} n] || ($n < 0 && [eof $fifo])} {
		# a reader-writer FIFO never reaches EOF; if it does, stop
		return
	}
	if {$n >= 0} { catch {verb $line} err; if {$err ne "" && ![string is integer -strict $err]} { log "error $err" } }
}

proc ::hudd::main {argv} {
	variable fifo
	variable runtime
	variable layout
	variable auto
	for {set i 0} {$i < [llength $argv]} {incr i} {
		if {[lindex $argv $i] eq "--layout"} { set layout [lindex $argv [incr i]] }
		if {[lindex $argv $i] eq "--auto"} { set auto 1 }
	}
	hud::store::load
	if {$auto && ![hud::store::wants_start]} { exit 0 }
	if {[info exists ::env(RIBBON_HUD_PROC)]} { hud::games::configure -proc $::env(RIBBON_HUD_PROC) }
	hud::frames::configure -pick ::hudd::frame_pick
	hud::quick::configure -layout ::hudd::set_layout -window ::hudd::window -redraw ::hudd::redraw -log ::hudd::log -open ::hudd::home
	set path $runtime/ribbon-hud
	file delete $path
	if {[catch {exec mkfifo -m 600 $path} err]} { puts stderr "ribbon-hud: $err"; exit 1 }
	set fifo [::open $path {RDWR NONBLOCK}]
	fconfigure $fifo -blocking 0 -translation lf
	set fh [::open $runtime/ribbon-hud.pid w]; puts $fh [pid]; ::close $fh
	hud::theme_load
	set cache [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$::env(HOME)/.cache"}]/ribbon/hud
	hud::draw::init $cache
	hud::art::configure -cache $cache
	if {![hud::surface::start -event ::hudd::on_surface]} {
		puts stderr "ribbon-hud: no overlay surface: $::hud::surface::error"
		file delete $path $runtime/ribbon-hud.pid
		exit 1
	}
	fileevent $fifo readable ::hudd::readable
	log "ready [hud::surface::size]"
	refresh
	if {![hud::games::start -changed ::hudd::on_windows]} { log "no window helper: no focus tracking, no game start" }
	vwait ::hudd::done
	hud::stop
	hud::games::stop
	hud::surface::stop
	file delete $path $runtime/ribbon-hud.pid
	exit 0
}
hudd::main $argv
