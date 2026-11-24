# quick.tcl - the Game HUD's in-game quick menu (boards HUD-Quick-1-Menu, -2-Volume, -3-Quit; design/tools/gen_hud_quick.py).
#
# Super+Esc (rc.xml: ribbon-hud quick) or the controller's home button opens it on the HUD's layer surface: the game is
# dimmed and the surface takes the keyboard and every click (ribbon-hud-surface "keyboard 1" and a full-screen input
# region), so the game gets no input while it is open; a right-hand HUD steps left to 358 px. The rows and their
# services:
#   Overlay          the HUD's layout (Off FPS Compact Full): left/right step it, A takes the next (the layout command)
#   Performance      power-profiles-daemon's ActiveProfile on the system bus (ribbon::dbus): left/right, A the next
#   HDR              ribbon-hdr on|off; only while the session runs the renderer HDR needs (WLR_RENDERER=vulkan), where
#                    ribbon-hdr applies it at once (otherwise it would wait for the next login)
#   Volume           the default output through wpctl: left/right 5 % down/up (to 100 %; up unmutes)
#   Screenshot       the menu closes, then ribbon-screenshot (the Print bind's command) once the surface has redrawn
#   Back to desktop  the menu closes and the game's window is minimised (the window command: ribbon-shell-watch)
#   Quit game        asks first (HUD-Quick-3-Quit, Cancel in focus); Quit game closes the game's window
# A row whose service is missing is left out (no power-profiles-daemon, no HDR renderer, no wpctl answer, no game
# window for the last two). Frame limit is not offered (no backend outside Game Mode). B / Esc closes (in the
# question: back to the menu). The mouse works too: a click on a row takes it (Volume: its left half down, its right
# half up), on the Overlay switcher picks that layout, off the card closes; a held arrow key repeats.
# It opens only over a game (the daemon's "quick"), and the home button is left to Steam while Steam runs (its Guide
# opens Steam's own overlay: two menus would open on one press).
#
#   hud::quick::configure ?-layout CMD? ?-window CMD? ?-redraw CMD? ?-log CMD? ?-open CMD?
#        -layout: called with off|fps|compact|full; -window: called with minimize|close ID; -redraw: the daemon redraws;
#        -open: the home button while the menu is closed (the daemon opens it for the game in front)
#   hud::quick::open WINDOW NAME ART START     WINDOW the game's window id ("" none), START its start in ms ("" unknown)
#   hud::quick::adopt WINDOW NAME ART START    the game's window, known only after the menu opened
#   hud::quick::close | is_open | window_id
#   hud::quick::started KEY PROGRAMS  -> when the game KEY started, in ms ("" unknown)
#   hud::quick::set_layout L          the HUD's layout now (the Overlay card shows it)
#   hud::quick::key CODE              a key press from the surface (Linux input codes: Up 103 Down 108 Left 105
#                                     Right 106 Enter 28/96 Space 57 Esc 1)
#   hud::quick::key_down CODE, key_up CODE, set_repeat RATE DELAY
#                                     a key held repeats (the arrows) at the compositor's rate after its delay
#   hud::quick::click X Y             a click (screen pixels): a row focused and taken, a layout, off the card closes
#   hud::quick::pad NAME              a controller button: home a b left right up down
#   hud::quick::surface_event LINE    the surface's events (a screenshot waits for the redraw without the menu)
#   hud::quick::ops W H NATIVE        -> {under over}: the dim (under the HUD) and the card, hud-draw.tcl op forms
#   hud::quick::state                 -> a line for the daemon's state order and the tests
# Environment: RIBBON_WPCTL, RIBBON_HDR, RIBBON_SCREENSHOT (the commands; tests use stand-ins), WLR_RENDERER.

namespace eval ::hud::quick {
	variable isopen 0
	variable focus overlay
	variable ask 0                 ;# the Quit question is up
	variable askfocus cancel
	variable layout off
	variable window ""
	variable name ""
	variable art ""
	variable start ""
	variable opts {-layout "" -window "" -redraw "" -log "" -open ""}
	variable here [file dirname [file normalize [info script]]]
	variable profile ""            ;# power-saver balanced performance ("": no power-profiles-daemon)
	variable profiles {}
	variable hdr ""                ;# on off ("": the row is left out)
	variable volume ""             ;# percent ("": no answer from wpctl)
	variable muted 0
	variable bus ""
	variable after_redraw ""       ;# a command to run once the surface has drawn the closed menu
	variable LAYOUTS {off fps compact full}
	variable LNAMES {Off FPS Compact Full}
	variable col
	array set col {ACCENT #FF7A59 ON_ACCENT #1A0F0B}
	variable icons {
		overlay {M3 4h18v16H3z M13 7h5v6h-5z}
		perf {M13 2L3 14h9l-1 8 10-12h-9z}
		hdr {M3 5h18v14H3z M7 9v6 M7 12h3 M10 9v6 M14 9v6h2a2 2 0 0 0 2-2v-2a2 2 0 0 0-2-2h-2}
		vol {M11 5L6 9H2v6h4l5 4z M15.54 8.46a5 5 0 0 1 0 7.07 M19.07 4.93a10 10 0 0 1 0 14.14}
		shot {M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z M12 17a4 4 0 1 0 0-8a4 4 0 1 0 0 8z}
		desk {M3 10l9-7 9 7v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z M9 22V12h6v10}
		quit {M18.36 6.64a9 9 0 1 1-12.73 0 M12 2v10}
		cancel {M18 6L6 18 M6 6l12 12}
	}
	variable iconcache {}
	variable geo {}                ;# the card as last drawn: x y w h (screen) and its rows {name y h} (card)
	variable segs {}               ;# the Overlay switcher's parts {layout x0 x1 y0 y1} (card)
	variable held ""               ;# the arrow key held down {CODE after-id}
	variable rep {25 600}          ;# key repeat: per second, delay in ms (the compositor's, from the surface)
}

proc ::hud::quick::configure {args} {
	variable opts
	foreach {k v} $args {
		if {![dict exists $opts $k]} { error "hud::quick::configure: unknown option $k" }
		dict set opts $k $v
	}
}

proc ::hud::quick::call {opt args} {
	variable opts
	set cmd [dict get $opts $opt]
	if {$cmd eq ""} { return }
	if {[catch {uplevel #0 [list {*}$cmd {*}$args]} err]} { log "error $opt: $err" }
}

proc ::hud::quick::log {text} {
	variable opts
	if {[dict get $opts -log] ne ""} { catch {uplevel #0 [list {*}[dict get $opts -log] "quick $text"]} }
}

proc ::hud::quick::redraw {} { call -redraw }
proc ::hud::quick::pal {} { array get ::hud::draw::c }
proc ::hud::quick::is_open {} { variable isopen; return $isopen }
proc ::hud::quick::window_id {} { variable window; return $window }
proc ::hud::quick::set_layout {l} { variable layout; set layout $l }

# ---- open and close -------------------------------------------------------------------------------------------------

proc ::hud::quick::open {win nm artsrc started} {
	variable isopen
	variable focus
	variable ask
	variable window
	variable name
	variable art
	variable start
	set window $win; set name $nm; set art $artsrc; set start $started
	set isopen 1; set focus overlay; set ask 0
	colours
	read_all
	log "open window=$win name=$nm"
	redraw
}

# the game's window, learnt after the menu opened (the daemon had not had the windows yet)
proc ::hud::quick::adopt {win nm artsrc started} {
	variable window
	variable name
	variable art
	variable start
	if {$win eq ""} return
	set window $win; set name $nm; set art $artsrc; set start $started
	log "adopt window=$win name=$nm"
	redraw
}

proc ::hud::quick::close {} {
	variable isopen
	variable ask
	if {!$isopen} return
	set isopen 0; set ask 0
	key_up ""
	log "close"
	redraw
}

# the surface's events: a "mapped" or "hidden" after the menu closed means the screen no longer shows it
proc ::hud::quick::surface_event {line} {
	variable after_redraw
	variable isopen
	if {$after_redraw eq "" || $isopen} return
	if {[regexp {^(mapped|hidden)} $line]} {
		set cmd $after_redraw
		set after_redraw ""
		# the compositor shows the new buffer at its next frame
		after 120 $cmd
	}
}

# ---- the rows -------------------------------------------------------------------------------------------------------

proc ::hud::quick::rows {} {
	variable profile
	variable hdr
	variable volume
	variable window
	set r {overlay}
	if {$profile ne ""} { lappend r perf }
	if {$hdr ne ""} { lappend r hdr }
	if {$volume ne ""} { lappend r vol }
	lappend r shot
	if {$window ne ""} { lappend r desk quit }
	return $r
}

proc ::hud::quick::label {row} {
	dict get {overlay Overlay perf Performance hdr HDR vol Volume shot Screenshot desk {Back to desktop} quit {Quit game}} $row
}

proc ::hud::quick::profile_label {p} {
	switch -- $p { power-saver { return Saver } balanced { return Balanced } performance { return Performance } }
	return $p
}

# the value text at the right of a row ("" for none)
proc ::hud::quick::value {row} {
	variable profile
	variable volume
	variable muted
	switch -- $row {
		perf { return [profile_label $profile] }
		vol { return [expr {$muted ? "Muted" : "$volume%"}] }
	}
	return ""
}

# what A and left/right say in the footer for the row in focus: {A-label adjust-label}
proc ::hud::quick::footer {} {
	variable focus
	variable ask
	if {$ask} { return {Select "" Back} }
	switch -- $focus {
		overlay { return {Change Layout Close} }
		perf { return {Change Performance Close} }
		hdr { return {Change "" Close} }
		vol { return {"" Volume Close} }
	}
	return {Select "" Close}
}

# ---- input ----------------------------------------------------------------------------------------------------------

proc ::hud::quick::key {code} {
	switch -- $code {
		103 { pad up }
		108 { pad down }
		105 { pad left }
		106 { pad right }
		28 - 96 - 57 { pad a }
		1 { pad b }
	}
}

# A key held down repeats at the compositor's rate after its delay (the surface's "repeat RATE DELAY"), as keys do in
# any window: the arrows only (a held Enter or Esc acts once).
proc ::hud::quick::key_down {code} {
	variable held
	variable rep
	key_up ""
	key $code
	if {$code in {103 108 105 106} && [is_open] && [lindex $rep 0] > 0} {
		set held [list $code [after [lindex $rep 1] [list ::hud::quick::key_repeat $code]]]
	}
}
proc ::hud::quick::key_repeat {code} {
	variable held
	variable rep
	if {[lindex $held 0] ne $code || ![is_open]} { set held ""; return }
	key $code
	set held [list $code [after [expr {max(1, 1000 / [lindex $rep 0])}] [list ::hud::quick::key_repeat $code]]]
}
# the key let go (CODE), or "" any (the keyboard went, the menu closed)
proc ::hud::quick::key_up {code} {
	variable held
	if {$held eq "" || ($code ne "" && [lindex $held 0] ne $code)} return
	after cancel [lindex $held 1]
	set held ""
}
proc ::hud::quick::set_repeat {rate delay} {
	variable rep
	if {[string is integer -strict $rate] && [string is integer -strict $delay] && $rate >= 0 && $delay >= 0} { set rep [list $rate $delay] }
}

# A click (screen pixels; the surface takes every click while the menu is open): off the card it closes the menu, as
# B does; on a row it is that row focused and taken (A); on the Overlay card's switcher, that layout; on the Quit
# question, its answer.
proc ::hud::quick::click {x y} {
	variable isopen
	variable geo
	variable segs
	variable focus
	variable ask
	variable askfocus
	if {!$isopen || ![dict exists $geo x]} { return 0 }
	set cx [expr {$x - [dict get $geo x]}]; set cy [expr {$y - [dict get $geo y]}]
	if {$cx < 0 || $cy < 0 || $cx >= [dict get $geo w] || $cy >= [dict get $geo h]} { pad b; return 1 }
	foreach r [dict get $geo rows] {
		lassign $r name ry rh
		if {$cx < 14 || $cx >= 316 || $cy < $ry || $cy >= $ry + $rh} continue
		if {$ask} {
			set askfocus $name
			pad a
			return 1
		}
		set focus $name
		if {$name eq "overlay"} {
			foreach sg $segs {
				lassign $sg l x0 x1 y0 y1
				if {$cx >= $x0 && $cx < $x1 && $cy >= $y0 && $cy < $y1} { set_overlay $l; break }
			}
			log "focus $focus"
			redraw
			return 1
		}
		# Volume: a click on the row's left half turns it down, on the right half up (as Left and Right)
		if {$name eq "vol"} { adjust [expr {$cx < 165 ? -1 : 1}]; log "focus $focus"; redraw; return 1 }
		pad a
		return 1
	}
	return 1
}

proc ::hud::quick::pad {b} {
	variable isopen
	variable focus
	variable ask
	variable askfocus
	if {$b eq "home"} {
		if {$isopen} { close } else { log "home"; call -open }
		return
	}
	if {!$isopen} return
	if {$ask} {
		switch -- $b {
			up - down { set askfocus [expr {$askfocus eq "quit" ? "cancel" : "quit"}] }
			a {
				if {$askfocus eq "quit"} { quit_game; return }
				set ask 0
			}
			b { set ask 0 }
		}
		redraw
		return
	}
	set rs [rows]
	set i [lsearch -exact $rs $focus]
	if {$i < 0} { set i 0; set focus [lindex $rs 0] }
	switch -- $b {
		up { if {$i > 0} { set focus [lindex $rs [expr {$i - 1}]] } }
		down { if {$i < [llength $rs] - 1} { set focus [lindex $rs [expr {$i + 1}]] } }
		left { adjust -1 }
		right { adjust 1 }
		a { activate }
		b { close; return }
	}
	log "focus $focus"
	redraw
}

proc ::hud::quick::adjust {d} {
	variable focus
	variable layout
	variable LAYOUTS
	variable profiles
	variable profile
	switch -- $focus {
		overlay {
			set i [expr {[lsearch -exact $LAYOUTS $layout] + $d}]
			if {$i >= 0 && $i < 4} { set_overlay [lindex $LAYOUTS $i] }
		}
		perf {
			set i [expr {[lsearch -exact $profiles $profile] + $d}]
			if {$i >= 0 && $i < [llength $profiles]} { set_profile [lindex $profiles $i] }
		}
		hdr { set_hdr [expr {$d > 0 ? "on" : "off"}] }
		vol { set_volume [expr {$d > 0 ? "5%+" : "5%-"}] }
	}
}

proc ::hud::quick::activate {} {
	variable focus
	variable layout
	variable LAYOUTS
	variable profiles
	variable profile
	variable hdr
	variable ask
	variable askfocus
	switch -- $focus {
		overlay { set_overlay [lindex $LAYOUTS [expr {([lsearch -exact $LAYOUTS $layout] + 1) % 4}]] }
		perf {
			set i [lsearch -exact $profiles $profile]
			set_profile [lindex $profiles [expr {($i + 1) % [llength $profiles]}]]
		}
		hdr { set_hdr [expr {$hdr eq "on" ? "off" : "on"}] }
		shot { screenshot }
		desk { to_desktop }
		quit { set ask 1; set askfocus cancel; log "ask quit" }
	}
}

# ---- the actions ----------------------------------------------------------------------------------------------------

proc ::hud::quick::set_overlay {l} {
	variable layout
	set layout $l
	log "overlay $l"
	call -layout $l
}

proc ::hud::quick::screenshot {} {
	variable after_redraw
	set cmd [cmd RIBBON_SCREENSHOT ribbon-screenshot]
	set after_redraw [list ::hud::quick::run_detached $cmd]
	log "screenshot"
	close
}

proc ::hud::quick::run_detached {cmd} {
	log "run $cmd"
	if {[catch {exec {*}$cmd </dev/null >/dev/null 2>/dev/null &} err]} { log "error $err" }
}

proc ::hud::quick::to_desktop {} {
	variable window
	set w $window
	log "desktop $w"
	close
	call -window minimize $w
}

proc ::hud::quick::quit_game {} {
	variable window
	set w $window
	log "quit $w"
	close
	call -window close $w
}

# a command from the environment variable VAR (a list), else DEF
proc ::hud::quick::cmd {var def} {
	if {[info exists ::env($var)] && $::env($var) ne ""} { return $::env($var) }
	return $def
}

# run CMD ARGS without waiting; DONE is called with {ok output} when it has finished
proc ::hud::quick::pipe {done cmd args} {
	if {[catch {::open [list | {*}$cmd {*}$args 2>@1] r} ch]} { uplevel #0 [list {*}$done 0 ""]; return }
	fconfigure $ch -blocking 0 -translation lf
	fileevent $ch readable [list ::hud::quick::pipe_read $ch $done ""]
}

proc ::hud::quick::pipe_read {ch done acc} {
	append acc [::read $ch]
	if {![eof $ch]} { fileevent $ch readable [list ::hud::quick::pipe_read $ch $done $acc]; return }
	fconfigure $ch -blocking 1
	set ok [expr {![catch {::close $ch}]}]
	uplevel #0 [list {*}$done $ok $acc]
}

# ---- the services ---------------------------------------------------------------------------------------------------

proc ::hud::quick::read_all {} {
	read_volume
	read_hdr
	read_profile
}

proc ::hud::quick::read_volume {} {
	pipe ::hud::quick::got_volume [cmd RIBBON_WPCTL wpctl] get-volume @DEFAULT_AUDIO_SINK@
}

proc ::hud::quick::got_volume {ok out} {
	variable volume
	variable muted
	set v ""; set m 0
	if {$ok && [regexp {Volume:\s*([0-9.]+)} $out -> f]} {
		set v [expr {int(round($f * 100))}]
		set m [regexp {MUTED} $out]
	}
	if {$v ne $volume || $m != $muted} {
		set volume $v; set muted $m
		log "volume [expr {$v eq "" ? "none" : $v}][expr {$m ? " muted" : ""}]"
		fix_focus
		redraw
	}
}

proc ::hud::quick::set_volume {step} {
	variable muted
	log "volume $step"
	# up unmutes first, as the volume keys do (mod-osd.tcl); else Right would change nothing that is heard or shown
	if {$muted && [string match *+ $step]} {
		pipe [list ::hud::quick::after_unmute $step] [cmd RIBBON_WPCTL wpctl] set-mute @DEFAULT_AUDIO_SINK@ 0
		return
	}
	pipe [list ::hud::quick::after_set read_volume] [cmd RIBBON_WPCTL wpctl] set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ $step
}

proc ::hud::quick::after_unmute {step ok out} {
	variable muted
	if {!$ok} { log "error [string trim $out]" }
	set muted 0
	set_volume $step
}

proc ::hud::quick::after_set {reread ok out} {
	if {!$ok} { log "error [string trim $out]" }
	$reread
}

# HDR is offered while the session runs the Vulkan renderer: there ribbon-hdr switches it at once (labwc
# --reconfigure); under GLES2 turning it on waits for the next login, which an in-game switch cannot say
proc ::hud::quick::hdr_live {} {
	expr {[info exists ::env(WLR_RENDERER)] && $::env(WLR_RENDERER) eq "vulkan"}
}

proc ::hud::quick::read_hdr {} {
	variable hdr
	if {![hdr_live]} { set hdr ""; return }
	pipe ::hud::quick::got_hdr [cmd RIBBON_HDR ribbon-hdr] status
}

proc ::hud::quick::got_hdr {ok out} {
	variable hdr
	set h ""
	if {[regexp {HDR:\s*(on|off)} $out -> s]} { set h $s }
	if {$h ne $hdr} { set hdr $h; log "hdr [expr {$h eq "" ? "none" : $h}]"; fix_focus; redraw }
}

proc ::hud::quick::set_hdr {v} {
	variable hdr
	if {$v eq $hdr} return
	log "hdr set $v"
	set hdr $v
	redraw
	pipe [list ::hud::quick::after_set read_hdr] [cmd RIBBON_HDR ribbon-hdr] $v
}

proc ::hud::quick::dbus {} {
	variable bus
	if {$bus ne ""} { return $bus }
	if {[catch {
		variable here
		foreach d [list /usr/lib/ribbon [file dirname [file dirname $here]]] {
			if {$d ni $::auto_path} { lappend ::auto_path $d }
		}
		package require ribbon::dbus
		set bus [ribbon::dbus::connect system]
	} err]} {
		log "no system bus: $err"
		set bus ""
	}
	return $bus
}

proc ::hud::quick::read_profile {} {
	set b [dbus]
	if {$b eq ""} { got_profile error {}; return }
	if {[catch {$b call -command ::hud::quick::got_profile -timeout 2000 -noautostart 1 net.hadess.PowerProfiles /net/hadess/PowerProfiles \
		org.freedesktop.DBus.Properties GetAll s net.hadess.PowerProfiles} err]} { got_profile error $err }
}

proc ::hud::quick::got_profile {status vals} {
	variable profile
	variable profiles
	set p ""; set ps {}
	if {$status ne "ok"} { log "power-profiles-daemon: [lindex $vals end]" }
	if {$status eq "ok"} {
		set d [ribbon::dbus::strip a{sv} [lindex $vals 0]]
		if {[dict exists $d Profiles]} {
			foreach e [dict get $d Profiles] {
				if {[dict exists $e Profile]} { lappend ps [dict get $e Profile] }
			}
		}
		if {[dict exists $d ActiveProfile]} { set p [dict get $d ActiveProfile] }
	}
	if {$p ni $ps} { set p "" }
	if {$p ne $profile || $ps ne $profiles} {
		set profile $p; set profiles $ps
		log "profile [expr {$p eq "" ? "none" : $p}]"
		fix_focus
		redraw
	}
}

proc ::hud::quick::set_profile {p} {
	variable profile
	if {$p eq $profile || $p eq ""} return
	set b [dbus]
	if {$b eq ""} return
	log "profile set $p"
	set profile $p
	redraw
	if {[catch {$b call -command [list ::hud::quick::profile_set] -timeout 5000 net.hadess.PowerProfiles /net/hadess/PowerProfiles \
		org.freedesktop.DBus.Properties Set ssv net.hadess.PowerProfiles ActiveProfile [list s $p]} err]} { log "error $err"; read_profile }
}

proc ::hud::quick::profile_set {status vals} {
	if {$status ne "ok"} { log "error profile: $vals" }
	read_profile
}

# a row that went away (its service left) takes the focus to the first row
proc ::hud::quick::fix_focus {} {
	variable focus
	if {$focus ni [rows]} { set focus overlay }
}

# ---- drawing --------------------------------------------------------------------------------------------------------

proc ::hud::quick::colours {} {
	variable col
	if {[catch {::open $::hud::palette_file r} fh]} return
	foreach line [split [::read $fh] \n] {
		if {[regexp {^\s*(ACCENT|ON_ACCENT)=["']?(#[0-9A-Fa-f]{6})} $line -> k v]} { set col($k) $v }
	}
	::close $fh
}

# when the game KEY started, in ms ("" unknown): its first process's start (clock ticks after boot; not the newest, a
# helper the game started later) and the boot time. PROGRAMS as hud::games::procs takes it
proc ::hud::quick::started {key programs} {
	if {$key eq ""} { return "" }
	set first ""
	dict for {pid p} [hud::games::procs $programs] {
		if {[dict get $p key] eq $key && ($first eq "" || [dict get $p start] < $first)} { set first [dict get $p start] }
	}
	if {$first eq ""} { return "" }
	if {![regexp -line {^btime\s+(\d+)} [hud::games::slurp $::hud::games::procroot/stat] -> bt]} { return "" }
	expr {($bt * 1000) + $first * 10}
}

proc ::hud::quick::playtime {} {
	variable start
	if {$start eq ""} { return "" }
	set m [expr {max(0, ([clock milliseconds] - $start) / 60000)}]
	if {$m >= 60} { return "[expr {$m / 60}] h [expr {$m % 60}] min" }
	return "$m min"
}

# icon NAME at the 16 px box X Y in COLOUR: open polylines (1.9 on the 24 grid)
proc ::hud::quick::icon {nm x y colour} {
	variable icons
	variable iconcache
	if {![dict exists $iconcache $nm]} { dict set iconcache $nm [::raster::path [dict get $icons $nm]] }
	set k [expr {16 / 24.0}]
	set out {}
	foreach pl [dict get $iconcache $nm] {
		set pts {}
		foreach {px py} $pl { lappend pts [expr {$x + $px * $k}] [expr {$y + $py * $k}] }
		if {[llength $pts] >= 4} { lappend out [list pline $pts [expr {1.9 * $k}] $colour] }
	}
	return $out
}

# a key cap ending at X (right edge), its top at Y: {ops width}
proc ::hud::quick::keycap {t xr y} {
	set c [pal]
	set w [expr {max(20, [hud::draw::measure "Ribbon Inter 600" 11 $t] + 12)}]
	set x [expr {$xr - $w}]
	list [list [list rrect $x $y $w 20 5 [dict get $c PILL] "" ""] \
		[list text [expr {$x + $w / 2.0}] [expr {$y + 10}] c "Ribbon Inter 600" 11 [dict get $c MUTED] $t]] $w
}

# The segmented control of the Overlay card in a track at X Y W (32 tall): equal parts, a part never narrower than
# its text with 12 px each side (gen_installer.seg: flex 1, padding 0 12, gap 2, padding 3)
proc ::hud::quick::seg {x y w cur} {
	variable LNAMES
	variable LAYOUTS
	set c [pal]
	set ops [list [list rrect $x $y $w 32 9 [dict get $c BAR] [list [dict get $c BORDER] 1] ""]]
	set inner [expr {$w - 6 - 2 * 3}]
	set need {}
	foreach t $LNAMES l $LAYOUTS {
		lappend need [expr {[hud::draw::measure [expr {$l eq $cur ? "Ribbon Inter 600" : "Ribbon Inter 500"}] 13 $t] + 24}]
	}
	set fixed {}
	for {set pass 0} {$pass < 4} {incr pass} {
		set free $inner; set n 0
		foreach k {0 1 2 3} { if {$k in $fixed} { set free [expr {$free - [lindex $need $k]}] } else { incr n } }
		set share [expr {$n ? $free / double($n) : 0}]
		set more 0
		foreach k {0 1 2 3} { if {$k ni $fixed && [lindex $need $k] > $share} { lappend fixed $k; set more 1 } }
		if {!$more} break
	}
	set px [expr {$x + 3}]
	variable segs {}
	foreach t $LNAMES l $LAYOUTS k {0 1 2 3} {
		set pw [expr {$k in $fixed ? [lindex $need $k] : $share}]
		lappend segs [list $l $px [expr {$px + $pw}] $y [expr {$y + 32}]]
		if {$l eq $cur} {
			lappend ops [list rrect [expr {round($px)}] [expr {$y + 3}] [expr {round($pw)}] 26 6 [dict get $c PILL] "" {1 2 0.3 #000000}]
			lappend ops [list text [expr {$px + $pw / 2.0}] [expr {$y + 16}] c "Ribbon Inter 600" 13 [dict get $c FG] $t]
		} else {
			lappend ops [list text [expr {$px + $pw / 2.0}] [expr {$y + 16}] c "Ribbon Inter 500" 13 [dict get $c MUTED] $t]
		}
		set px [expr {$px + $pw + 2}]
	}
	return $ops
}

# a 46 px row at Y (card coordinates): icon, label, value or switch, the focus ring
proc ::hud::quick::row {row y focused {lbl ""}} {
	variable col
	variable hdr
	set c [pal]
	set ops {}
	if {$focused} { lappend ops [list rrect 14 $y 302 46 10 [dict get $c FIELD] [list $col(ACCENT) 1.5] ""] }
	set cy [expr {$y + 23}]
	set ic [expr {$row eq "overlay" ? "overlay" : $row}]
	lappend ops {*}[icon $ic 26 [expr {$cy - 8}] [expr {$focused ? $col(ACCENT) : [dict get $c MUTED]}]]
	lappend ops [list text 54 $cy w "Ribbon Inter 400" 13 [dict get $c FG] [expr {$lbl ne "" ? $lbl : [label $row]}]]
	if {$row eq "hdr"} {
		set on [expr {$hdr eq "on"}]
		lappend ops [list rrect 266 [expr {$y + 12}] 38 22 11 [expr {$on ? $col(ACCENT) : [dict get $c PILL]}] "" ""]
		lappend ops [list rrect [expr {$on ? 285 : 269}] [expr {$y + 15}] 16 16 8 [expr {$on ? $col(ON_ACCENT) : [dict get $c MUTED]}] "" ""]
	} elseif {$row eq "shot"} {
		lassign [keycap Print 304 [expr {$y + 13}]] k
		lappend ops {*}$k
	} else {
		set v [value $row]
		if {$v ne ""} { lappend ops [list text 304 $cy e "Ribbon Inter 400" 13 [dict get $c MUTED] $v] }
	}
	return $ops
}

# the footer: its rule at Y, the controller hints under it
proc ::hud::quick::foot {y glass} {
	set c [pal]
	lassign [footer] a adj b
	set ops [list [list rect 14 $y 302 1 [dict get $c BORDER]]]
	set x 20
	set cy [expr {$y + 22}]
	foreach {glyphs text} [list [expr {$a ne "" ? "A" : ""}] $a B $b [expr {$adj ne "" ? "◂ ▸" : ""}] $adj] {
		if {$text eq ""} continue
		foreach g $glyphs {
			lappend ops [list rrect $x [expr {$cy - 10}] 20 20 10 $glass [list [dict get $c MUTED] 1.5] ""]
			set gx [expr {$x + 10}]
			switch -- $g {
				◂ { lappend ops [list poly [list [expr {$gx + 2}] [expr {$cy - 3}] [expr {$gx + 2}] [expr {$cy + 3}] [expr {$gx - 2.5}] $cy] [dict get $c FG]] }
				▸ { lappend ops [list poly [list [expr {$gx - 2}] [expr {$cy - 3}] [expr {$gx - 2}] [expr {$cy + 3}] [expr {$gx + 2.5}] $cy] [dict get $c FG]] }
				default { lappend ops [list text $gx $cy c "Ribbon Inter 700" 10 [dict get $c FG] $g] }
			}
			set x [expr {$x + 27}]
		}
		lappend ops [list text $x $cy w "Ribbon Inter 400" 12 [dict get $c MUTED] $text]
		set x [expr {$x + [hud::draw::measure "Ribbon Inter 400" 12 $text] + 18}]
	}
	return $ops
}

# {under over}: the dim over the whole screen, and the card at the right edge (the "quick" hit covers the screen)
proc ::hud::quick::ops {W H native {backdrop #000000}} {
	variable isopen
	variable ask
	variable askfocus
	variable focus
	variable layout
	variable name
	variable art
	variable col
	if {!$isopen} { return {{} {}} }
	set c [pal]
	if {$native} {
		set dim [list [list rrect 0 0 $W $H 0 #000000 "" "" 0.35]]
		set galpha [list 0.86]
		set glass [dict get $c BAR]
	} else {
		set dim {}
		set galpha {}
		set glass [hud::draw::mix [dict get $c BAR] [hud::draw::mix #000000 $backdrop 0.35] 0.86]
	}
	lappend dim [list hit quick 0 0 $W $H]
	set rowsat {}
	set ops {}
	# the head: the game's picture, its name, the time played
	lappend ops [list image 20 18 28 28 7 $art 1]
	lappend ops [list text 60 32 w "Ribbon Space Grotesk 600" 18 [dict get $c FG] $name]
	set t [playtime]
	if {$t ne ""} { lappend ops [list text 310 32 e "Ribbon Inter 400" 12 [dict get $c MUTED] $t] }
	if {$ask} {
		lappend ops [list text 26 77.5 w "Ribbon Inter 600" 15 [dict get $c FG] "Quit the game?"]
		set y 101
		foreach r {quit cancel} lbl {{Quit game} Cancel} {
			lappend ops {*}[row $r $y [expr {$askfocus eq $r}] $lbl]
			lappend rowsat [list $r $y 46]
			incr y 50
		}
	} else {
		set f [expr {$focus eq "overlay"}]
		set ring [if {$f} { list $col(ACCENT) 1.5 } else { list }]
		lappend ops [list rrect 14 64 302 90 10 [dict get $c FIELD] $ring ""]
		lappend ops {*}[icon overlay 26 79 [expr {$f ? $col(ACCENT) : [dict get $c MUTED]}]]
		lappend ops [list text 54 87 w "Ribbon Inter 400" 13 [dict get $c FG] Overlay]
		lassign [keycap F12 304 77] k w
		lappend ops {*}$k
		lassign [keycap Super [expr {304 - $w - 4}] 77] k
		lappend ops {*}$k
		lappend ops {*}[seg 26 110 278 $layout]
		lappend rowsat [list overlay 64 90]
		set y 158
		foreach r [lrange [rows] 1 end] {
			lappend ops {*}[row $r $y [expr {$focus eq $r}]]
			lappend rowsat [list $r $y 46]
			incr y 50
		}
	}
	set fy [expr {$y - 4 + 10}]
	lappend ops {*}[foot $fy $glass]
	set h [expr {$fy + 34 + 14}]
	set card [linsert $ops 0 [list rrect 0 0 330 $h 16 $glass [list [dict get $c BORDER] 1] {12 40 0.5 #000000} {*}$galpha]]
	set over [hud::draw::images [move $card [expr {$W - 12 - 330}] 12]]
	variable geo [dict create x [expr {$W - 12 - 330}] y 12 w 330 h $h rows $rowsat]
	return [list $dim $over]
}

# ops moved by DX DY (at 1:1: the 1.5 px rings stay 1.5, unlike hud::draw::xform's)
proc ::hud::quick::move {ops dx dy} {
	set out {}
	foreach op $ops {
		switch -- [lindex $op 0] {
			rrect - rect - text - image { lset op 1 [expr {[lindex $op 1] + $dx}]; lset op 2 [expr {[lindex $op 2] + $dy}] }
			pline - poly {
				set p {}
				foreach {x y} [lindex $op 1] { lappend p [expr {$x + $dx}] [expr {$y + $dy}] }
				lset op 1 $p
			}
		}
		lappend out $op
	}
	return $out
}

proc ::hud::quick::state {} {
	variable isopen
	variable focus
	variable ask
	variable askfocus
	variable layout
	variable profile
	variable hdr
	variable volume
	variable window
	return "open=$isopen focus=$focus ask=[expr {$ask ? $askfocus : 0}] layout=$layout rows=[join [rows] ,] profile=$profile hdr=$hdr volume=$volume window=$window"
}
