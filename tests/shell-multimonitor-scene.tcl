# shell-multimonitor-scene.tcl - RIBBON_SHELL_TEST hook (tests/steps.d/46-shell-multimonitor.sh): every shell surface
# on the main display, and only there (W2). The X screen (Xvfb 3040x1080) is two outputs that a stub wlr-randr lists:
# HEADLESS-1 1440x1080 at 0,0 and HEADLESS-2 1600x900 at 1440,180, display.conf "main HEADLESS-2". The launcher's
# results and mode menu, the tray and updates panels, the notification popups and their history, Files' menus,
# Alt+Tab's still and labwc's margin go there; then `ribbon-shell-ctl display` (display.conf naming HEADLESS-1) moves
# what is open within a second, and everything opens on HEADLESS-1; then back, with the panel and the history open. A 60 s limit ends the run if anything waits.

set failed 0
interp bgerror {} {apply {{msg opts} { puts "  FAIL background error: [dict get $opts -errorinfo]"; exit 1 }}}
after 60000 {puts "  FAIL the multi-monitor scene took more than 60 s"; exit 1}
proc ok {what} { puts "  ok   $what" }
proc bad {what why} { global failed; incr failed; puts "  FAIL $what: $why" }
proc check {what cond why} { if {$cond} { ok $what } else { bad $what $why } }

array set wm::tl {1 {app foot title Terminal state act}}
set wm::order {1}
array set wm::ws {1 {name 1 active 1}}
set wm::wsorder {1}
set wm::focus ""
wm::changed
set status::updates 0
proc wm::send {cmd args} {}
proc term::reload {} {}
proc term::press {chord} {}
# no notification server on the test's bus: the popups go in through notify::arrive, as D-Bus would
proc notify::start {} {}
# what the switcher asks its helper
set ::sent {}
proc alttab::hsend {line} { lappend ::sent $line }

proc conf {name} { set f [open [display::confpath] w]; puts $f "main $name"; close $f }
proc geo {w} { update; list [winfo rootx $w] [winfo rooty $w] [winfo width $w] [winfo height $w] }
# a popup's box (its window reaches further, for the shadow): {x y w h} on the screen
proc box {w} { lassign [geo $w] x y; lassign $rbn::shown($w,c) cx cy cw ch; list [expr {$x + $cx}] [expr {$y + $cy}] $cw $ch }
# 1 when the rectangle R lies inside OUT {x y w h}
proc within {r out} {
	lassign $r x y w h; lassign $out ox oy ow oh
	expr {$x >= $ox && $y >= $oy && $x + $w <= $ox + $ow && $y + $h <= $oy + $oh}
}
proc waitfor {cond ms script} {
	if {[uplevel #0 [list expr $cond]] || $ms <= 0} { uplevel #0 $script; return }
	after 50 [list waitfor $cond [expr {$ms - 50}] $script]
}
proc slurp {f} { if {[catch {open $f} fh]} { return "" }; set t [read $fh]; close $fh; return $t }
proc mk {id summary} {
	dict create id $id app Files icon "" summary $summary body "" actions {} hints {} urgency 1 timeout 0 sender :1.1 replaces 0
}

set H1 {0 0 1440 1080}
set H2 {1440 180 1600 900}

# Each surface on OUT (the main output, named NAME): its place, from the main display's top left.
proc surfaces {name out} {
	lassign $out ox oy ow oh
	check "$name: the bars are on it" [expr {[list $bar::X0 $bar::Y0 $bar::W $bar::H] eq $out}] "[list $bar::X0 $bar::Y0 $bar::W $bar::H]"
	# the launcher's results hang from the left bar
	launcher::start app
	set launcher::results [list [list file [list notes.txt $::env(HOME)/notes.txt 0]] [list file [list docs $::env(HOME)/docs 1]]]
	launcher::drop_draw
	lassign [box .drop] x y
	check "$name: the launcher's results hang from the left bar" [expr {$x == $ox + 8 && $y == $oy + 54 && [within [box .drop] $out]}] "box [box .drop]"
	launcher::cancel
	launcher::menu_toggle 1
	lassign [box .menu] x y
	check "$name: the launcher's mode menu hangs from the left bar" [expr {$x == $ox + 8 && $y == $oy + 54 && [within [box .menu] $out]}] "box [box .menu]"
	launcher::menu_toggle 1
	# the tray's and the updates' panels hang from the right bar
	foreach kind {session updates} {
		panel::show $kind
		update
		lassign [box .panel] x y w
		check "$name: the $kind panel hangs from the right bar" [expr {$y == $oy + 54 && $x + $w == $ox + $ow - 8 && [within [box .panel] $out]}] "box [box .panel]"
		panel::close
	}
	# a notification: from the main display's bottom left
	notify::arrive [mk [incr ::nid] "Copied 3 items"]
	update
	lassign [geo .notify] x y w h
	check "$name: a notification pops up at its bottom left" [expr {$x == $ox && $y + $h == $oy + $oh}] "[geo .notify]"
	foreach id $notify::shown { notify::drop $id }
	update
	# the history: its height, from its top left
	nhist::show
	update
	check "$name: the notification history is its height, from its top left" [expr {[geo .nhist] eq [list $ox $oy 780 $oh]}] "[geo .nhist]"
	nhist::close
	# Alt+Tab's still is of this output, at its width
	set ::sent {}
	alttab::take_shot
	check "$name: Alt+Tab asks for a still of it, at its width" \
		[expr {[lindex $::sent end] eq "shot [shell::runtime]/alttab-bg.ppm 35 $name $ow"}] "[lindex $::sent end]"
	set alttab::shotpend 0
	# labwc's margin is this output's only, and labwc was told
	set rc [slurp $::env(RIBBON_MARGIN_RC)]
	check "$name: labwc's margin is written for it only" \
		[expr {[regexp -all {<margin } $rc] == 1 && [string first "<margin top=\"54\" bottom=\"54\" output=\"$name\" />" $rc] >= 0}] "$rc"
}

# Files' menus stay on the output they open on, whichever is the main one.
proc menus {} {
	set items [list [list right Open {} ""] [list info Properties {} ""] [list trash "Move to Trash" {} ""]]
	# a right click 10 px from HEADLESS-1's right edge: the menu stays on HEADLESS-1, not across onto HEADLESS-2
	files::popup_menu . 1430 500 $items
	set b [box .filesmenu]
	check "Files: a menu near HEADLESS-1's right edge stays on HEADLESS-1" [expr {[within $b $::H1] && [lindex $b 0] + [lindex $b 2] <= 1436}] "box $b"
	destroy .filesmenu
	# near HEADLESS-2's foot: it goes up to stay on it
	files::popup_menu . 2000 1070 $items
	set b [box .filesmenu]
	check "Files: a menu near HEADLESS-2's foot stays on HEADLESS-2" [within $b $::H2] "box $b"
	destroy .filesmenu
	# above HEADLESS-2, right of HEADLESS-1, is on no output: the main display bounds it
	files::popup_menu . 3000 20 $items
	set b [box .filesmenu]
	check "Files: a menu off every output is kept on the main display" [within $b [display::rect]] "box $b on [display::rect]"
	destroy .filesmenu
}

proc reloaded {} { split [string trim [slurp $::env(RIBBON_MARGIN_LOG)]] \n }

proc phase1 {} {
	check "display.conf's main output is HEADLESS-2 at 1440,180" [expr {[display::main] eq "HEADLESS-2" && [display::rect] eq $::H2}] "[display::main] [display::rect]"
	waitfor {[reloaded] ne ""} 3000 phase1b
}
proc phase1b {} {
	ok "the notifications are drawn [expr {[npaint::on] ? {as see-through pictures} : {as plain surfaces}}]"
	check "at start labwc is told to read the margin once" [expr {[reloaded] eq {HEADLESS-2}}] "[reloaded]"
	surfaces HEADLESS-2 $::H2
	menus
	# open as the main display changes: a popup, the launcher's results
	notify::arrive [mk [incr ::nid] "Moved 12 items"]
	launcher::start app
	set launcher::results [list [list file [list notes.txt $::env(HOME)/notes.txt 0]]]
	launcher::drop_draw
	update
	# Settings keeps HEADLESS-1 as the main display and tells the shell (`ribbon-shell-ctl display`, the FIFO)
	conf HEADLESS-1
	set ::t0 [clock milliseconds]
	set f [open [file join [shell::runtime] ribbon-shell] {WRONLY NONBLOCK}]
	puts $f display
	close $f
	waitfor {$bar::X0 == 0 && [lindex [geo .drop] 0] < 1440 && [lindex [geo .notify] 0] == 0} 1000 phase2
}

proc phase2 {} {
	set ms [expr {[clock milliseconds] - $::t0}]
	check "within a second the bars move to HEADLESS-1 ($ms ms)" [expr {$bar::X0 == 0 && $ms <= 1000}] "X0 $bar::X0 after $ms ms"
	lassign [box .drop] x y
	check "the open launcher results move with the left bar" [expr {[winfo ismapped .drop] && $x == 8 && $y == 54}] "box [box .drop]"
	lassign [geo .notify] x y w h
	check "the notification on the screen moves to HEADLESS-1's bottom left" [expr {[winfo ismapped .notify] && $x == 0 && $y + $h == 1080}] "[geo .notify]"
	launcher::cancel
	foreach id $notify::shown { notify::drop $id }
	check "labwc is told again, for HEADLESS-1" [expr {[lindex [reloaded] end] eq "HEADLESS-1" && [llength [reloaded]] == 2}] "[reloaded]"
	# the history's stage is made for the screen's height, the tallest display there is
	check "the history's stage is tall enough for HEADLESS-1" [expr {![winfo exists .npaint_nhist] || [lindex $npaint::st(nhist) 1] >= 1080}] "[array get npaint::st]"
	surfaces HEADLESS-1 $::H1
	menus
	# open as it changes back: the session panel (from the right bar) and the history
	nhist::show
	panel::show session
	update
	conf HEADLESS-2
	set ::t0 [clock milliseconds]
	set f [open [file join [shell::runtime] ribbon-shell] {WRONLY NONBLOCK}]
	puts $f display
	close $f
	waitfor {$bar::X0 == 1440 && [lindex [geo .panel] 0] > 1440 && [lindex [geo .nhist] 0] == 1440} 1000 phase3
}

proc phase3 {} {
	set ms [expr {[clock milliseconds] - $::t0}]
	check "within a second the bars move back to HEADLESS-2 ($ms ms)" [expr {$bar::X0 == 1440 && $ms <= 1000}] "X0 $bar::X0 after $ms ms"
	lassign [box .panel] x y w
	check "the open session panel moves with the right bar" [expr {[winfo ismapped .panel] && $y == 234 && $x + $w == 3040 - 8}] "box [box .panel]"
	check "the open history moves to HEADLESS-2's top left, at its height" [expr {[geo .nhist] eq {1440 180 780 900}}] "[geo .nhist]"
	panel::close
	nhist::close
	# a monitor plugged in makes the X screen taller than the history's stage was made for: the stage grows to it
	if {[winfo exists .npaint_nhist]} {
		npaint::stage nhist 464 1500
		update
		check "the history's stage grows for a taller display" [expr {[lindex $npaint::st(nhist) 1] == 1500 && [winfo height .npaint_nhist.o.f.c] == 1500}] \
			"[array get npaint::st] [winfo height .npaint_nhist.o.f.c]"
	}
	if {$::failed} { puts "shell multi-monitor scene: $::failed failed"; exit 1 }
	puts "shell multi-monitor scene: all checks passed"
	exit 0
}

set nid 0
after 300 phase1
