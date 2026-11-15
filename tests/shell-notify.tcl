# shell-notify.tcl - the notification popups in the real shell, for the boards
# (RIBBON_SHELL_TEST=this file, under xvfb; tests/steps.d/40-notify.sh).
#   NOTIFY_SCENE = popup | burst | progress | critical | nobus
# The scene's entries go in through notify::arrive (the same path as D-Bus), with
# no expiry, and the geometry the boards fix is checked: the rule at x 28, the text
# at x 48, the keycaps' foot 64 above the surface's bottom, one-liners above.
# nobus: the server is left to start for real, on the bus the environment names
# (the step gives it none), and the shell must run on with it off.

set scene [expr {[info exists ::env(NOTIFY_SCENE)] ? $::env(NOTIFY_SCENE) : "popup"}]
set failed 0
interp bgerror {} {apply {{msg opts} { puts "  FAIL background error: [dict get $opts -errorinfo]"; exit 1 }}}
after 20000 {puts "  FAIL the popup scene took more than 20 s"; exit 1}
proc ok {what} { puts "  ok   $what" }
proc bad {what why} { global failed; incr failed; puts "  FAIL $what: $why" }

if {$scene ne "nobus"} {
	# no server on the test's bus: the scene feeds the popups itself
	proc notify::start {} {}
}

proc mk {id app summary body urg actions {hints {}}} {
	dict create id $id app $app icon "" summary $summary body $body actions $actions \
		hints $hints urgency $urg timeout 0 sender :1.1 replaces 0
}

proc scene {} {
	global scene failed
	set c $::notify::cv
	switch -- $scene {
		popup {
			notify::arrive [mk 1 Firefox "Download complete" "ribbon-0.3.iso · 1.4 GB, in Downloads" 1 \
				{default Open S {Show in Files}}]
		}
		burst {
			notify::arrive [mk 10 Screenshot "Screenshot taken" "" 1 {}]
			notify::arrive [mk 11 Files "Moved 12 items to Mods" "" 1 {}]
			notify::arrive [mk 12 Firefox "Download complete" "" 1 {}]
			notify::arrive [mk 13 Steam Ludo "you up for a round tonight? bringing the new deck" 1 {default Reply mark {Mark as read}}]
		}
		progress {
			notify::arrive [mk 20 Firefox "Download complete" "" 1 {}]
			notify::arrive [mk 21 Files "Copying to Games SSD" "3 items · Hades II, Proton-GE 9-20 and saves.zip" 1 \
				{pause Pause cancel Cancel} {value 35 x-ribbon-progress-text {1.2 of 3.4 GB}}]
		}
		critical {
			# Notify-Final-4: two earlier ones above it, the nearer with its body after the summary
			notify::arrive [mk 28 Firefox "Download complete" "" 1 {}]
			notify::arrive [mk 29 Steam Ludo "you up for a round tonight?" 1 {}]
			notify::arrive [mk 30 Power "Battery at 4%" "About 6 minutes left. Plug in, or it suspends at 2%." 2 \
				{default {Suspend now} power-saver {Power saver}}]
		}
		checks {
			checks
			return
		}
		nobus {
			after 1000 {
				if {[string match off* $::notify::status]} { ok "no session bus: the server is off, and the shell runs on" } else {
					bad "the server without a bus" "status is $::notify::status"
				}
				exit [expr {$failed ? 1 : 0}]
			}
			return
		}
	}
	after 200 check
}

proc check {} {
	global scene failed
	set c $::notify::cv
	if {![winfo exists .notify] || ![winfo ismapped .notify]} { bad "the popup surface" "not on screen"; finish }
	set sh [winfo screenheight .notify]
	set oy [expr {[winfo rooty .notify] - 0}]
	if {[winfo y .notify] == $sh - 760} { ok "the surface sits at the bottom left, 760 tall" } else {
		bad "the surface" "at y [winfo y .notify], screen $sh"
	}
	# text starts at 48, the rule is at 28 (3 wide)
	set xs {}
	foreach it [$c find all] {
		if {[$c type $it] eq "text"} { lappend xs [lindex [$c coords $it] 0] }
	}
	if {[lsearch -exact $xs 48] >= 0 || [lsearch -exact $xs 48.0] >= 0} { ok "text is at x 48" } else { bad "text x" "no text at 48: $xs" }
	# the app line (Notify-Final-1 to 4): the app's 14 px icon at x 48, its name 22 on, at x 70
	set icons {}
	foreach it [$c find all] {
		lassign [$c bbox $it] ix0 iy0 ix1 iy1
		if {[$c type $it] eq "image" && $ix0 == 48 && $ix1 - $ix0 == 14 && $iy1 - $iy0 == 14} { lappend icons [$c bbox $it] }
	}
	if {[llength $icons] && ([lsearch -exact $xs 70] >= 0 || [lsearch -exact $xs 70.0] >= 0)} {
		ok "the app's icon is at x 48 (14 px), its name at x 70"
	} else { bad "the app line" "icons at x 48: $icons; text xs: $xs" }
	if {$scene eq "progress"} {
		set words {}
		foreach it [$c find all] { if {[$c type $it] eq "text"} { append words [$c itemcget $it -text] } }
		if {[string match "*1.2of3.4GB*" [string map {" " ""} $words]]} { ok "the progress line is the sender's own words" } else { bad "the progress line" $words }
	}
	set rules {}
	foreach it [$c find all] {
		if {[$c type $it] eq "rectangle" && [lindex [$c coords $it] 0] == 28} { lappend rules [$c coords $it] }
	}
	switch -- $scene {
		popup - progress - critical {
			if {[llength $rules] == 1} { ok "one accent rule at x 28" } else { bad "the rule" "[llength $rules] rules" }
		}
		burst {
			if {[llength $rules] == 1} { ok "one accent rule, on the newest" } else { bad "the rule" "[llength $rules] rules" }
		}
	}
	# the foot: the last keycap (or the last progress line) ends 64 above the bottom
	set lowest 0
	foreach it [$c find all] {
		lassign [$c bbox $it] x0 y0 x1 y1
		if {$y1 > $lowest} { set lowest $y1 }
	}
	if {$lowest <= 760 - 64 && $lowest >= 760 - 64 - 2} { ok "the foot is 64 above the bottom edge (y $lowest of 760)" } else {
		bad "the foot" "lowest item ends at $lowest, want 696"
	}
	set n [llength [notify::history]]
	ok "scene $scene: [llength $::notify::shown] on the popups, $n in the history, the rules [llength $rules]"
	finish
}

proc finish {} {
	global failed
	if {$::scene eq "popup" || $::scene eq "burst" || $::scene eq "progress" || $::scene eq "critical"} {
		# a screenshot for the review: the harness grabs the screen once this file says so
		if {[info exists ::env(NOTIFY_READY)]} { catch {exec touch $::env(NOTIFY_READY)} }
	}
	# NOTIFY_HOLD=ms keeps the scene up that long, for a screenshot
	if {[info exists ::env(NOTIFY_HOLD)]} { after $::env(NOTIFY_HOLD) [list exit [expr {$failed ? 1 : 0}]]; return }
	exit [expr {$failed ? 1 : 0}]
}

# checks: what a sender may send that the boards do not show (the spec's timeouts, entities, odd hints, floods)
proc expect {what cond why} { if {$cond} { ok $what } else { bad $what $why } }
proc checks {} {
	global failed
	# an explicit expire_timeout is kept by a progress entry too (a volume or brightness level, notify-send -t)
	expect "a progress entry with an expire_timeout expires then" \
		[expr {[notify::lifetime [dict create urgency 1 value 40 timeout 1500]] == 1500}] \
		"lifetime [notify::lifetime [dict create urgency 1 value 40 timeout 1500]]"
	expect "a progress entry with the server's choice stays until it is done" \
		[expr {[notify::lifetime [dict create urgency 1 value 40 timeout -1]] == 0}] "lifetime"
	expect "a critical one stays, whatever its timeout" \
		[expr {[notify::lifetime [dict create urgency 2 value "" timeout 1500]] == 0}] "lifetime"
	# the body's markup: XML's numeric entities (g_markup_escape_text writes ' as &#39;), read once
	set p [notify::plain {Don&#39;t &#x41;&#66; &amp;#39; &#0; &#xD800; &bogus; &lt;b&gt;}]
	expect "numeric entities in the body are read, once" [expr {$p eq {Don't AB &#39; &#0; &#xD800; &bogus; <b>}}] "plain is \"$p\""
	# a value hint that is not a finite number is no progress, and the notification still arrives
	foreach {id v} {40 NaN 41 Inf 42 -Inf} {
		set code [catch {notify::arrive [mk $id App "odd value" "" 1 {} [list value $v]]} err]
		expect "a value hint of $v is no progress" [expr {!$code && [dict get [notify::find $id] value] eq ""}] \
			[expr {$code ? $::errorInfo : "value [dict get [notify::find $id] value]"}]
	}
	# image-data: kept at the size it is drawn (the store is the saved history), and a malformed one is dropped
	set d [string repeat "\x80\x40\x20\xff" [expr {128 * 128}]]
	notify::arrive [mk 50 "Some App" "a picture" "" 1 {} [list image-data [list 128 128 512 1 8 4 $d]]]
	set e [notify::find 50]
	set kept [lindex [dict get [dict get $e hints] image-data] 6]
	expect "a 128 px image-data is kept at its drawn size" [expr {[string length $kept] <= 14 * 14 * 4}] "[string length $kept] bytes kept"
	lassign [notify::icon_of $e] kind img
	expect "and still draws, at most 14 px" [expr {$kind eq "photo" && [image width $img] <= 14 && [image width $img] >= 10}] "icon $kind $img"
	foreach {id bad} [list 51 {100000 100000 400000 1 8 4 abc} 52 {a b c d e f g} 53 {16 16 64 1 8 4 short}] {
		set code [catch {notify::arrive [mk $id "Some App" "bad picture" "" 1 {} [list image-data $bad]]; notify::draw} err]
		expect "a malformed image-data ([lrange $bad 0 1]) is dropped" [expr {!$code && ![dict exists [dict get [notify::find $id] hints] image-data]}] \
			[expr {$code ? $err : "kept"}]
	}
	# the transient hint bypasses the history (the spec: "by-pass the server's persistence capability")
	notify::arrive [mk 60 App "transient" "" 1 {} {transient 1}]
	notify::dismiss 60
	expect "a transient notification leaves no history once it closes" [expr {[notify::find 60] eq ""}] "still listed"
	notify::arrive [mk 61 App "kept" "" 1 {}]
	notify::dismiss 61
	expect "an ordinary one stays in the history" [expr {[notify::find 61] ne ""}] "gone"
	# a long body or summary (a script's output) costs what its first lines cost: it is drawn on every redraw
	notify::fonts
	set long [string repeat "word " 60000]
	set us [lindex [time {set lines [notify::wrap nBody $long 380 3]}] 0]
	expect "a 300 kB body is wrapped in under 30 ms" [expr {$us < 30000 && [llength $lines] == 3}] "[expr {$us / 1000}] ms, [llength $lines] lines"
	set c [canvas .longline]
	set us [lindex [time {notify::line $c [dict create id 0 app App icon "" summary $long body $long hints {} urgency 1 open 1 time [clock seconds]] 600 1.0}] 0]
	expect "a one-liner with a 300 kB summary is drawn in under 30 ms" [expr {$us < 30000}] "[expr {$us / 1000}] ms"
	destroy $c
	# a flood: one alert sound, not one paplay each
	if {[file readable /usr/share/sounds/freedesktop/stereo/message.oga] || [file readable /usr/share/sounds/freedesktop/stereo/bell.oga]} {
		set ::sounds 0; set notify::sounded 0
		proc ::notify::exec {args} { incr ::sounds }
		for {set i 100} {$i < 140} {incr i} { notify::arrive [mk $i Chat "message $i" "hello" 1 {}] }
		expect "a flood of 40 notifications plays the alert once" [expr {$::sounds == 1}] "$::sounds sounds"
		rename ::notify::exec {}
	}
	puts [expr {$failed ? "  notify checks FAILED" : "  all notify checks passed"}]
	exit [expr {$failed ? 1 : 0}]
}

after 300 scene
