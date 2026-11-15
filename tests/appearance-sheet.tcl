# appearance-sheet.tcl - drive the background sheet (onstage.tcl) with
# clicks and keys and check the stage and what Apply writes: the tabs,
# picking a picture and its fit, Revert, Apply to the desktop and to both
# screens, the slideshow's folder, interval (stepper, typing, the unit
# menu, clamping) and crossfade, a video's pauses and bars, the colour
# picker (a drag shows each colour live), recent colours, the login
# screen's own options, and back to the window. RIBBON_APPEARANCE_SCENE=this
# file; tests/test-appearance.sh sets up the home, the stubs, a fake /etc
# and APPEARANCE_BG (pictures, a slideshow folder, videos if ffmpeg is there).
proc bgerror {msg} { puts stderr "$msg\n$::errorInfo"; exit 1 }
set ::fails 0
proc check {what cond} {
	if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what"; incr ::fails }
}
proc slurp {f} { set fh [open $f]; set d [read $fh]; close $fh; return $d }
proc kv {f k} { if {![file exists $f]} { return "" }; if {[regexp -line "^${k}=(.*)\$" [slurp $f] -> v]} { return [string trim $v \"] }; return "" }
proc settle {} { set n 0; while {$os::S(busy) && $n < 600} { after 50; update; incr n }; update }
proc draw {} { update idletasks; after 60; update }
# the centre of the first hit area whose script matches PATTERN (sheet coordinates)
proc hit_at {pattern} {
	draw
	foreach h $ui::hits {
		lassign $h x0 y0 x1 y1 press
		if {[string match $pattern $press]} { return [list [expr {($x0 + $x1) / 2.0}] [expr {($y0 + $y1) / 2.0}]] }
	}
	error "no hit for $pattern"
}
proc click {pattern} {
	lassign [hit_at $pattern] x y
	ui::press [expr {$x + $ui::ox}] [expr {$y + $ui::oy}]; ui::release [expr {$x + $ui::ox}] [expr {$y + $ui::oy}]
	draw
}
proc clickxy {x y} { draw; ui::press [expr {$x + $ui::ox}] [expr {$y + $ui::oy}]; ui::release [expr {$x + $ui::ox}] [expr {$y + $ui::oy}]; draw }
proc key {sym {char ""} {state 0}} { draw; os::key $sym $char $state; draw }
proc type {text} { foreach ch [split $text ""] { os::key $ch $ch 0 }; draw }

set cfg $::env(XDG_CONFIG_HOME)
set wc $cfg/ribbon/wallpaper.conf
set fx $::env(APPEARANCE_BG)
set pics [lsort [glob -directory $fx/pictures *.png]]
os::list_write pictures.list $pics
set log $::env(PKEXEC_LOG)
set lo $::env(RIBBON_LOGIN_ROOT)/etc/ribbon/login/options.conf

# ---- the window steps aside
page::go desktop
draw
check "Desktop background: the window steps aside, the sheet shows" {![winfo ismapped $app::win] && [winfo ismapped .sheet]}
check "the sheet is an rbnalpha window: 32-bit, see-through corners and shadow" {[rbn::argb] && [winfo depth .sheet] == 32 && [winfo visual .sheet] eq "truecolor"}
check "  its box sits 20 px above the screen's bottom, 80 px in" {[winfo rooty .sheet.c] + 207 == [winfo screenheight .] - 20 && [winfo rootx .sheet.c] == 80}
check "  on the tab of what is in use (the pattern), Show on: Both" {$os::S(tab) eq "ribbon" && $os::S(show) eq "both"}
check "  the stage shows the pattern" {[lindex $stage::spec 0] eq "pattern" && [winfo ismapped .stage]}

# ---- Pictures
click "*os::pick_tab pictures*"
check "the Pictures tab" {$os::S(tab) eq "pictures"}
check "  its count: the pictures in pictures.list" {[llength $os::pictures] == [llength $pics]}
click "*os::choose_picture [list [lindex $pics 1]]*"
check "a picture: the stage shows it, filled" {$stage::spec eq [list picture [lindex $pics 1] fill [dict get $bg::desk colour]]}
check "  wallpaper.conf is not touched" {[kv $wc MODE] in {"" pattern}}
set ok 0
foreach h $ui::hits { if {[string match "*os::set_fit*" [lindex $h 4]]} { incr ok } }
check "the Fit cards" {$ok == 4}
click "*os::set_fit*centre"
check "  Centre: the stage lays it out centred" {[dict get $bg::desk fit] eq "centre" && [lindex $stage::spec 2] eq "centre"}
click "*os::revert*"
check "Revert: back to the pattern, on stage too" {[dict get $bg::desk mode] eq "pattern" && [lindex $stage::spec 0] eq "pattern" && $os::S(tab) eq "ribbon"}
click "*os::pick_tab pictures*"
click "*os::choose_picture [list [lindex $pics 0]]*"
click "*os::set_fit*fit"
click "*os::set_show desktop*"
check "Show on: Desktop" {$os::S(show) eq "desktop"}
click "*os::apply*"
settle
check "Apply: wallpaper.conf has the picture, fitted" {[kv $wc MODE] eq "picture" && [kv $wc IMAGE] eq [lindex $pics 0] && [kv $wc FIT] eq "fit"}
check "  and nothing went to the login screen" {![string match "*set-background*" [slurp $log]]}
check "  what was applied is the new revert point" {$os::S(snap) eq [bg::snapshot]}

# ---- Slideshow
click "*os::pick_tab slideshow*"
dict set bg::desk dir $fx/wallpapers
os::use_slideshow; os::changed
check "a slideshow folder: its pictures, the first on stage" {[llength [os::slides]] == [llength [glob -directory $fx/wallpapers *.png]] && [lindex $stage::spec 1] eq [lindex [os::slides] 0]}
dict set bg::desk interval 600
os::changed
click "*os::step_interval 1*"
check "the stepper: 10 -> 11 minutes" {[dict get $bg::desk interval] == 660}
click "*set ui::focus interval*"
key BackSpace; type 2; key Return
check "typing 2: 2 minutes" {[dict get $bg::desk interval] == 120}
click "*os::unit_menu*"
check "the unit's menu opens" {$os::menu ne ""}
click "*os::set_interval*hours*"
check "  hours: 2 hours" {[dict get $bg::desk interval] == 7200 && $os::menu eq ""}
click "*set ui::focus interval*"
type 999; key Return
check "999 hours is clamped to 7 days" {[dict get $bg::desk interval] == 604800}
os::set_interval 0 minutes
check "0 minutes is clamped to 1 minute" {[dict get $bg::desk interval] == 60}
click "*os::flip subdirs*"
check "Include subfolders" {[dict get $bg::desk subdirs] eq "yes"}
click "*os::apply*"
settle
check "Apply: MODE=slideshow, INTERVAL, SUBDIRS" {[kv $wc MODE] eq "slideshow" && [kv $wc INTERVAL] eq "60" && [kv $wc SUBDIRS] eq "yes" && [kv $wc SLIDESHOW_DIR] eq "$fx/wallpapers"}

# ---- Video
set vids [glob -nocomplain -directory $fx/videos *.mp4]
if {[llength $vids]} {
	os::list_write videos.list $vids
	os::load_lists
	click "*os::pick_tab video*"
	click "*os::choose_video [list [lindex $vids 0]]*"
	check "a video: on stage, its first frame for backends that can't play it" {[lindex $stage::spec 0] eq "video" && [file exists [lindex $stage::spec 2]]}
	check "  its length on the tile" {[os::duration [lindex $vids 0]] eq "0:03"}
	click "*os::flip pause_covered*"
	click "*bars \$k*solid"
	check "Windows cover it, Solid bars" {[dict get $bg::desk pause_covered] eq "yes" && [dict get $bg::desk bars] eq "solid"}
	click "*os::apply*"
	settle
	check "Apply: MODE=video, PAUSE_FULLSCREEN, PAUSE_COVERED, BARS" {[kv $wc MODE] eq "video" && [kv $wc PAUSE_FULLSCREEN] eq "yes" && [kv $wc PAUSE_COVERED] eq "yes" && [kv $wc BARS] eq "solid"}
} else {
	puts "  skip video (no ffmpeg)"
}

# ---- Colour
click "*os::pick_tab colour*"
check "the Colour tab: the colour on stage" {[lindex $stage::spec 0] eq "colour"}
lassign [hit_at "*page::sv_drag*"] sx sy
set seen {}
foreach dx {-40 0 40} {
	set x [expr {$sx + $dx}]
	draw
	ui::press [expr {$x + $ui::ox}] [expr {$sy + $ui::oy}]
	ui::motion [expr {$x + 20 + $ui::ox}] [expr {$sy - 10 + $ui::oy}]
	after 80; update
	lappend seen [lindex $stage::spec 1]
	ui::release [expr {$x + 20 + $ui::ox}] [expr {$sy - 10 + $ui::oy}]
}
check "dragging in the square: each colour is on stage as it moves" {[llength [lsort -unique $seen]] == 3 && [lindex $seen end] eq [dict get $bg::desk colour]}
click "*set ui::focus hex*"
ui::fset hex ""
type #3A5F2B
key Return
check "typing a hex colour" {[dict get $bg::desk colour] eq "#3A5F2B" && [lindex $stage::spec 1] eq "#3A5F2B"}
click "*page::S(mode)*hsl"
check "the HSL switch: H S L in the boxes" {$page::S(mode) eq "hsl" && ![catch {hit_at "*set ui::focus*nchL"}]}
click "*os::pick_colour*[dict get [store::current_palette] ACCENT]"
check "a theme colour" {[dict get $bg::desk colour] eq [dict get [store::current_palette] ACCENT]}
click "*os::set_show both*"
click "*os::apply*"
settle
check "Apply to both: MODE=colour on the desktop" {[kv $wc MODE] eq "colour" && [kv $wc COLOUR] eq [dict get [store::current_palette] ACCENT]}
check "  the login screen: the same colour, through pkexec and the helper" {[string match "*set-options*COLOUR=[dict get [store::current_palette] ACCENT]*" [slurp $log]] && [kv $lo COLOUR] eq [dict get [store::current_palette] ACCENT]}
check "  a recent colour, kept in colours.list" {[lindex [os::list_read colours.list] 0] eq [dict get [store::current_palette] ACCENT]}

# ---- the login screen
click "*os::set_show login*"
check "Show on: Login screen: the greeter is the stage" {[lindex $stage::spec 0] eq "login" && $stage::greeter ne ""}
click "*os::pick_tab pictures*"
click "*os::choose_picture [list [lindex $pics 0]]*"
os::set_login blur 17
os::set_login dim 40
click "*os::set_login clock*"
check "the login screen's own Blur, Dim and clock" {[dict get $bg::login blur] == 17 && [dict get $bg::login dim] == 40 && [dict get $bg::login clock] eq "no"}
check "  the greeter is shown them" {[kv $stage::gdir/etc/ribbon/login/options.conf BLUR] eq "17" && [file exists $stage::gdir/etc/ribbon/login/background.png]}
set before [kv $wc MODE]
click "*os::apply*"
settle
check "Apply: options.conf and the picture, the desktop left alone" {[kv $lo BLUR] eq "17" && [kv $lo DIM] eq "40" && [kv $lo CLOCK] eq "no" && [string match "*set-background [lindex $pics 0]*" [slurp $log]] && [kv $wc MODE] eq $before}

# ---- back
click "*os::pick_tab ribbon*"
key Escape
check "Esc: back to the window; what wasn't applied is undone" {![winfo ismapped .sheet] && [winfo ismapped $app::win] && [dict get $bg::desk mode] eq $before && $stage::greeter eq ""}
check "  the window is on Theme" {$page::S(page) eq "theme"}

# ---- Add video: ribbon-wall --probe decides (RIBBON_WALL_CMD is a stub: "long"
# is 7 minutes, "short" 3 seconds, anything else unreadable; no file is read)
# A refusal is Ribbon's alert (shell/alert.tcl, boards Alert-1-Video-Long and Alert-1b-Not-Applied): a watcher
# records each one shown ({title lines box-x box-y mapped grabbed}) and presses its OK as a click would. A stock Tk
# message box would be recorded in ::stock.
set refused {}
set stock {}
proc tk_messageBox {args} { lappend ::stock $args; return ok }
proc watch_alert {} {
	if {[llength [info commands ::alert::isopen]] && [alert::isopen] && [winfo exists $alert::win.c] && [winfo ismapped $alert::win.c]} {
		set s $alert::spec
		lappend ::refused [list [dict get $s -title] [dict get $s -lines] [winfo rootx $alert::win.c] [winfo rooty $alert::win.c] \
			[winfo width $alert::win.c] [winfo height $alert::win.c] [expr {[grab current] eq $alert::win}]]
		lassign [lindex $alert::hits end] key bx by bw bh
		event generate $alert::win.c <ButtonRelease-1> -x [expr {$bx + 5}] -y [expr {$by + 5}]
	}
	after 50 watch_alert
}
watch_alert
set pick {}
proc dlg::open_file {args} { return $::pick }
set long [file join $fx videos long.mp4]; set short [file join $fx videos short.mp4]; set junk [file join $fx videos notes.mp4]
foreach f [list $long $short $junk] { set fh [open $f w]; puts $fh "not decoded"; close $fh }
set before [llength $os::videos]
set ::pick [list $long]
os::add_video
check "a video over 5 minutes is refused, with the limit" {[llength $refused] == 1 && [lindex $refused 0 0] eq "This video is too long" && [lindex $refused 0 1] eq [list "long.mp4 is 7:00 long, more than 5 minutes"]}
check "  in Ribbon's alert, 440 wide, centred on the screen, holding the sheet until OK" {[lrange [lindex $refused 0] 2 end] eq [list [expr {([winfo screenwidth .] - 440) / 2}] [expr {([winfo screenheight .] - 164) / 2}] 440 164 1]}
check "  the alert is gone after OK, its grab let go" {![alert::isopen] && ![winfo exists $alert::win] && [grab current] eq ""}
check "  not added to the list, nor chosen" {[lsearch -exact $os::videos $long] < 0 && [llength $os::videos] == $before && [dict get $bg::desk video] ne $long}
set ::pick [list $junk]
os::add_video
check "a file ribbon-wall can't read is refused, saying so" {[llength $refused] == 2 && [lindex $refused 1 0] eq "This video can't be used" && [string match "notes.mp4: *no video stream*" [lindex $refused 1 1 0]]}
set ::pick [list $long $short]
os::add_video
check "a video under 5 minutes is added and chosen (the long one still refused)" {[llength $refused] == 3 && [lsearch -exact $os::videos $short] >= 0 && [dict get $bg::desk video] eq $short}
check "  its length, from the probe, on the tile" {$os::info(dur,$short) eq "0:03"}
check "  videos.list has it, not the refused one" {[string match "*short.mp4*" [os::list_read videos.list]] && ![string match "*long.mp4*" [os::list_read videos.list]]}

# Apply that could not do everything: one line per part that failed, the first line of its report
os::applied [list "login screen: permission denied\nmore output" "desktop background: ribbon-wall is not running"]
check "Apply's failures: Ribbon's alert, one line each (board Alert-1b-Not-Applied)" {[llength $refused] == 4 && [lindex $refused 3 0] eq "Not everything was applied" && [lindex $refused 3 1] eq [list "login screen: permission denied" "desktop background: ribbon-wall is not running"] && [lindex $refused 3 5] == 182}
check "no stock Tk message box was shown" {$stock eq ""}

puts "  [expr {$::fails ? "FAIL" : "ok  "}] background sheet: $::fails failed"
stage::quit
exit [expr {$::fails ? 1 : 0}]
