# onstage.tcl - choosing the desktop background and the login screen
# "on stage" (design/mockups/BG-Onstage-*): the Appearance window steps
# aside, the real desktop (or the real login screen) shows the candidate
# full size, and one floating sheet at the bottom does the picking.
#
# The sheet: a top row (back to Appearance, the sources, Show on, Revert,
# Apply) and one content row, the same height on every tab:
#   Ribbon designs  the patterns Ribbon draws itself (now: the Ribbon pattern)
#   Pictures        your pictures (~/.config/ribbon/pictures.list) and Fit
#   Slideshow       a folder, shuffle, subfolders, how often, crossfade
#   Video           your videos (videos.list), when to pause, the bars
#   Colour          a plain colour: the Colours page's picker, theme and
#                   recent colours (colours.list)
# With Show on = Login screen the stage is the greeter itself, and the row
# ends with the login screen's own Blur, Dim and clock.
#
# Everything is drawn as the rest of the app (ui.tcl, the shell's raster
# and text code), in the sheet's own window. Sizes are the boards' at
# 1440 x 900; the sheet keeps 80 px from the screen's sides.

namespace eval os {
	variable S
	array set S {open 0 kind desktop tab pictures show both scroll 0 dirty 0 snap {} applied 0 busy 0}
	variable pictures {}
	variable back_label Settings   ;# the back button's label (--back LABEL: "Image Viewer")
	variable back_quit 0           ;# --back given: back closes the window
	variable videos {}
	variable recent {}
	variable designs {ribbon Ribbon}
	variable TABS {ribbon {Ribbon designs} pictures Pictures slideshow Slideshow video Video colour Colour}
	variable SHOWS {desktop Desktop login {Login screen} both Both}
	variable SW 1440
	variable SH 900
	variable SX 80         ;# the sheet in the screen
	variable SY 673
	variable SWID 1280
	variable SHGT 207
	variable TW 140
	variable TH 88
	variable info          ;# per file: video duration etc.
	array set info {}
}

# ---- lists kept in ~/.config/ribbon --------------------------------------------

proc os::list_file {name} { file join [store::config] ribbon $name }
proc os::list_read {name} {
	set out {}
	if {![catch {open [list_file $name]} fh]} {
		foreach l [split [read $fh 65536] \n] { set l [string trim $l]; if {$l ne "" && $l ni $out} { lappend out $l } }
		close $fh
	}
	return $out
}
proc os::list_write {name items} {
	set f [list_file $name]
	file mkdir [file dirname $f]
	set fh [open $f.[pid] w]; puts -nonewline $fh [join $items \n][expr {[llength $items] ? "\n" : ""}]; close $fh
	file rename -force $f.[pid] $f
}

proc os::load_lists {} {
	variable pictures
	variable videos
	variable recent
	set pictures [lmap f [list_read pictures.list] { expr {[file readable $f] ? $f : [continue]} }]
	set videos [lmap f [list_read videos.list] { expr {[file readable $f] ? $f : [continue]} }]
	set recent [lmap c [list_read colours.list] { expr {[regexp {^#[0-9A-Fa-f]{6}$} $c] ? [string toupper $c] : [continue]} }]
	# what is in use is always there
	foreach d [list $bg::desk $bg::login] {
		set f [dict get $d image]
		if {[dict exists $d mode] && [dict get $d mode] ne "picture"} continue
		if {[dict exists $d source] && [dict get $d source] ne "picture"} continue
		if {$f ne "" && [file readable $f] && $f ni $pictures} { set pictures [linsert $pictures 0 $f] }
	}
	set v [dict get $bg::desk video]
	if {$v ne "" && [file readable $v] && $v ni $videos} { set videos [linsert $videos 0 $v] }
}

# ---- opening and closing -------------------------------------------------------

# Open the sheet for KIND (desktop | login): the window steps aside.
proc os::start {kind} {
	variable S
	variable SW
	variable SH
	variable SX
	variable SY
	variable SWID
	set SW [winfo screenwidth .]; set SH [winfo screenheight .]
	set SWID [expr {$SW - 160}]; set SX 80
	set SY [expr {$SH - 20 - 207}]
	stage::init $SW $SH
	set S(kind) $kind
	set S(show) [expr {$kind eq "login" ? "login" : "both"}]
	set S(snap) [bg::snapshot]
	set S(applied) 0
	set S(scroll) 0
	load_lists
	set S(tab) [tab_of]
	set page::S(ptarget) os::colour_target
	if {[winfo exists $app::win]} { wm withdraw $app::win }
	if {![winfo exists .sheet]} {
		# an rbnalpha window (labwc: RibbonAppearanceSheet, no decorations):
		# its box is the canvas .sheet.c, the rest is see-through
		rbn::surface .sheet -class RibbonAppearanceSheet -managed 1 -fill $ui::c(bar)
		wm title .sheet Appearance
		bind .sheet.c <ButtonPress-1> {ui::press %x %y}
		bind .sheet.c <B1-Motion> {ui::motion %x %y}
		bind .sheet.c <ButtonRelease-1> {ui::release %x %y}
		bind .sheet.c <Button-4> {ui::scroll %x %y -1}
		bind .sheet.c <Button-5> {ui::scroll %x %y 1}
		bind .sheet.c <MouseWheel> {ui::scroll %x %y [expr {%D > 0 ? -1 : 1}]}
		bind .sheet <KeyPress> {os::key %K %A %s}
		wm protocol .sheet WM_DELETE_WINDOW os::back
	}
	# the box is drawn at the origin of its canvas: the hit areas are box coordinates
	set ui::cv .sheet.c
	set ui::ox 0; set ui::oy 0
	set ui::focus ""
	set S(open) 1
	show_box
	focus -force .sheet
	update_stage
	draw
}

# The sheet's look: its box, edge, ring and shadow (rbnalpha draws them).
proc os::look {} {
	array set c [array get ui::c]
	list -fill $c(bar) -radius 18 -ring [list $c(border) 1] -shadow {24 70 0.6}
}

# Show the sheet's box where it belongs (the bottom of the screen, 80 px in).
proc os::show_box {} {
	variable SX
	variable SY
	variable SWID
	rbn::popup .sheet $SX $SY $SWID 207 [look]
}

# Back to Settings (the Appearance page); what wasn't applied goes back.
proc os::back {} {
	variable S
	if {$S(busy)} return
	if {[bg::snapshot] ne $S(snap) || !$S(applied)} { bg::restore $S(snap) }
	stage::revert
	variable back_quit
	if {$back_quit} { page::quit }
	set S(open) 0
	unset -nocomplain page::S(ptarget)
	set page::S(ptarget) ""
	rbn::hide .sheet
	set ui::cv $app::win.c
	set ui::ox [expr {$app::scene ? 170 : 0}]; set ui::oy [expr {$app::scene ? $app::oy : 0}]
	set ui::focus ""
	if {[winfo exists $app::win]} { wm deiconify $app::win; raise $app::win; focus -force $app::win }
	page::go theme
}

# The tab that shows what is in use now.
proc os::tab_of {} {
	variable S
	if {$S(show) eq "login" && ![dict get $bg::login same]} {
		return [dict get {pattern ribbon picture pictures colour colour} [dict get $bg::login source]]
	}
	return [dict get {pattern ribbon picture pictures colour colour slideshow slideshow video video} [dict get $bg::desk mode]]
}

# ---- what the stage shows -------------------------------------------------------

proc os::palette {} { store::current_palette }

# The desktop candidate, as a stage spec.
proc os::desk_spec {} {
	set d $bg::desk
	switch -- [dict get $d mode] {
		picture { return [list picture [dict get $d image] [dict get $d fit] [dict get $d colour]] }
		slideshow {
			# the first picture for backends that can't play it; ribbon-wall plays the slideshow
			return [list picture [dict get $d image] [dict get $d fit] [dict get $d colour] \
				[list slideshow [dict get $d dir] [bg::interval [dict get $d interval]] [dict get $d crossfade] \
					[bg::yesno [dict get $d shuffle]] [bg::yesno [dict get $d subdirs]]]]
		}
		video { return [list video [dict get $d video] [frame [dict get $d video]]] }
		colour { return [list colour [dict get $d colour]] }
	}
	return [list pattern [palette]]
}

# The login candidate (what the greeter will show), as a stage spec.
proc os::login_spec {} {
	set l [bg::effective_login]
	set p [store::login_palette]
	set o [dict create FIT [dict get $l fit] BLUR [dict get $l blur] DIM [dict get $l dim] \
		CLOCK [bg::yesno [dict get $l clock]] COLOUR [expr {[dict get $l source] eq "colour" ? [dict get $l colour] : ""}]]
	switch -- [dict get $l source] {
		picture { set s [list picture [dict get $l image] [dict get $l fit] "" $p] }
		colour { set s [list colour [dict get $l colour] $p] }
		default { set s [list pattern $p] }
	}
	list login $s $o
}

proc os::stage_spec {} {
	variable S
	expr {$S(show) eq "login" ? [login_spec] : [desk_spec]}
}

proc os::update_stage {} {
	stage::show [stage_spec]
}

# ---- changing the candidate -------------------------------------------------------

# The settings the sheet edits: the desktop's, or with Show on = Login
# screen the login screen's own.
proc os::login_side {} {
	variable S
	expr {$S(show) eq "login"}
}

proc os::changed {} {
	variable S
	set S(dirty) [expr {[bg::snapshot] ne $S(snap)}]
	update_stage
	prewarm
	draw
}

# Start making the login screen's blurred picture before it is needed (a
# picture chosen, the Login screen tab opened): the greeter then starts
# from the cache.
proc os::prewarm {} {
	set l [bg::effective_login]
	if {[dict get $l source] ne "picture" || [dict get $l image] eq "" || ![file readable [dict get $l image]]} return
	set colour [expr {[dict get $l source] eq "colour" ? [dict get $l colour] : ""}]
	set bgc [expr {$colour ne "" ? $colour : [dict get [store::login_palette] DESK_BOTTOM]}]
	set base [wall::prepare_path [dict get $l image] $stage::W $stage::H [dict get $l fit] $bgc]
	set b [dict get $l blur]
	if {![file exists [expr {$b > 0 ? "[file rootname $base]-blur$b.png" : $base}]]} {
		stage::warm [dict get $l image] [dict get $l fit] $bgc $b
	}
}

proc os::pick_tab {t} {
	variable S
	set S(tab) $t
	set S(scroll) 0
	set ui::focus tabs
	switch -- $t {
		ribbon { choose_design ribbon; return }
		colour {
			if {[login_side]} { bg_set login source colour; bg_set login same 0 } else { dict set bg::desk mode colour }
			page::from_hex [colour_target get]
		}
		slideshow { if {[dict get $bg::desk dir] ne ""} { use_slideshow } }
		video { if {[dict get $bg::desk video] ne ""} { use_video [dict get $bg::desk video] } }
	}
	changed
}

proc os::bg_set {which key value} {
	if {$which eq "login"} { dict set bg::login $key $value } else { dict set bg::desk $key $value }
}

proc os::choose_design {id} {
	if {[login_side]} {
		dict set bg::login same 0; dict set bg::login source pattern
	} else {
		dict set bg::desk mode pattern
	}
	changed
}

proc os::choose_picture {f} {
	if {[login_side]} {
		dict set bg::login same 0; dict set bg::login source picture; dict set bg::login image $f
	} else {
		dict set bg::desk mode picture; dict set bg::desk image $f
	}
	changed
}

proc os::set_fit {fit} {
	if {[login_side]} { dict set bg::login fit $fit } else { dict set bg::desk fit $fit }
	changed
}
proc os::cur_fit {} { expr {[login_side] ? [dict get $bg::login fit] : [dict get $bg::desk fit]} }

proc os::cur_picture {} {
	if {[login_side]} {
		set l [bg::effective_login]
		return [expr {[dict get $l source] eq "picture" ? [dict get $l image] : ""}]
	}
	expr {[dict get $bg::desk mode] eq "picture" ? [dict get $bg::desk image] : ""}
}

proc os::add_pictures {} {
	variable pictures
	set fs [dlg::open_file "Add pictures" {{Pictures {.png .jpg .jpeg .webp .PNG .JPG .JPEG .WEBP}} {{All files} *}} "" 1]
	set added ""
	foreach f $fs {
		if {[catch {wall::image_size $f}]} continue
		set f [file normalize $f]
		if {$f ni $pictures} { lappend pictures $f }
		set added $f
	}
	list_write pictures.list $pictures
	if {$added ne ""} { choose_picture $added } else { draw }
}

proc os::remove_picture {f} {
	variable pictures
	set pictures [lsearch -all -inline -not -exact $pictures $f]
	list_write pictures.list $pictures
	draw
}

# The slideshow: the folder's pictures, and the one shown now.
proc os::slides {} {
	set dir [dict get $bg::desk dir]
	if {$dir eq "" || ![file isdirectory $dir]} { return {} }
	set out {}
	set todo [list $dir]
	while {[llength $todo]} {
		set d [lindex $todo 0]; set todo [lrange $todo 1 end]
		foreach f [lsort [glob -nocomplain -directory $d -types f *]] {
			if {[string tolower [file extension $f]] in {.png .jpg .jpeg .webp}} { lappend out $f }
		}
		if {[bg::yesno [dict get $bg::desk subdirs]] eq "yes"} {
			lappend todo {*}[lsort [glob -nocomplain -directory $d -types d *]]
		}
		if {[llength $out] > 5000} break
	}
	return $out
}

proc os::use_slideshow {} {
	set s [slides]
	set cur [dict get $bg::desk image]
	if {$cur ni $s} { set cur [lindex $s 0] }
	dict set bg::desk mode slideshow
	dict set bg::desk image $cur
	if {[login_side]} { dict set bg::login same 0; dict set bg::login source picture; dict set bg::login image $cur }
}

proc os::change_folder {} {
	set d [dlg::choose_dir "Slideshow folder" [dict get $bg::desk dir]]
	if {$d eq ""} return
	dict set bg::desk dir [file normalize $d]
	dict set bg::desk image ""
	use_slideshow
	changed
}

proc os::flip {key} {
	dict set bg::desk $key [expr {[bg::yesno [dict get $bg::desk $key]] eq "yes" ? "no" : "yes"}]
	if {$key eq "subdirs"} { use_slideshow }
	changed
}

# The slideshow's interval: a number and a unit.
proc os::interval_parts {} {
	set s [bg::interval [dict get $bg::desk interval]]
	if {$s % 86400 == 0} { return [list [expr {$s / 86400}] days] }
	if {$s % 3600 == 0} { return [list [expr {$s / 3600}] hours] }
	list [expr {$s / 60}] minutes
}
proc os::set_interval {n unit} {
	set k [dict get {minutes 60 hours 3600 days 86400} $unit]
	if {![string is integer -strict $n]} return
	dict set bg::desk interval [bg::interval [expr {$n * $k}]]
	changed
}
proc os::step_interval {d} {
	lassign [interval_parts] n unit
	set_interval [expr {max(1, $n + $d)}] $unit
}

proc os::use_video {f} {
	dict set bg::desk mode video
	dict set bg::desk video $f
	dict set bg::desk image [frame $f]
	if {[login_side]} { dict set bg::login same 0; dict set bg::login source picture; dict set bg::login image [frame $f] }
}
proc os::choose_video {f} { use_video $f; changed }
proc os::add_video {} {
	variable videos
	variable info
	set fs [dlg::open_file "Add video" {{Videos {.mp4 .webm .mkv .mov .MP4 .WEBM .MKV .MOV}} {{All files} *}} "" 1]
	set added ""
	foreach f $fs {
		set f [file normalize $f]
		lassign [probe $f] status len max why
		if {$status ne "ok"} { refuse_video $f $status $len $max $why; continue }
		set info(dur,$f) $len
		if {$f ni $videos} { lappend videos $f }
		set added $f
	}
	list_write videos.list $videos
	if {$added ne ""} { choose_video $added } else { draw }
}

# "ribbon-wall --probe FILE" says a clip's length and whether it may be used
# (at most 5 minutes). Returns {ok M:SS MAX-SECONDS ""}, {long M:SS MAX ""}
# or {unreadable "" MAX WHY}. RIBBON_WALL_CMD: the command (a test's stub).
proc os::probe {f} {
	set wall [expr {[info exists ::env(RIBBON_WALL_CMD)] ? $::env(RIBBON_WALL_CMD) : [auto_execok ribbon-wall]}]
	if {$wall eq ""} { return [list unreadable "" 300 "ribbon-wall is not installed"] }
	# exit 1 when refused: the report is on stdout either way
	catch {exec timeout 30 {*}$wall --probe $f 2>/dev/null} out
	set max 300
	if {[regexp {max ([0-9.]+)} $out -> m]} { set max [expr {int(round($m))}] }
	if {![regexp {duration ([0-9.]+)} $out -> d] || ![regexp {ok ([01])} $out -> ok]} {
		return [list unreadable "" $max "ribbon-wall could not read it"]
	}
	set s [expr {int(round($d))}]
	set len [format %d:%02d [expr {$s / 60}] [expr {$s % 60}]]
	if {$ok} { return [list ok $len $max ""] }
	if {$d > $max} { return [list long $len $max ""] }
	set why "could not be played"
	regexp {error (.*)} $out -> why
	return [list unreadable "" $max [string trim $why]]
}

# Refused: Ribbon's alert (shell/alert.tcl, board Alert-1-Video-Long), centred on the screen over the sheet,
# which it holds until OK; the clip is not added.
proc os::refuse_video {f status len max why} {
	set name [file tail $f]
	set min [expr {$max / 60}]
	if {$status eq "long"} {
		tell film "This video is too long" [list "$name is $len long, more than $min minutes"]
	} else {
		tell film "This video can't be used" [list "$name: $why"]
	}
}

# The alert with one button, OK, waiting for it (the alert is loaded from the shell's folder on first use).
proc os::tell {icon title lines} {
	if {![llength [info commands ::alert::ask]]} { uplevel #0 [list source -encoding utf-8 [file join $::text::dir alert.tcl]] }
	alert::ask -icon $icon -title $title -lines $lines -buttons {{ok OK}} -modal 1
}

proc os::frame {f} {
	variable info
	if {$f eq ""} { return "" }
	set key "$f [file mtime $f]"
	# the memo is used only while the file still holds this key (another frame may have taken it)
	if {[info exists info(frame,$f)]} {
		set p $info(frame,$f)
		if {$p eq "" || [raster::keyed $p $key]} { return $p }
	}
	set out [raster::keyed_path [stage::cachedir] frame- $key]
	if {![raster::keyed $out $key] && [auto_execok ffmpeg] ne ""} {
		if {![catch {exec ffmpeg -nostdin -v error -y -i $f -frames:v 1 $out </dev/null >/dev/null 2>/dev/null}]} { raster::store_key $out $key }
	}
	set info(frame,$f) [expr {[raster::keyed $out $key] ? $out : ""}]
}
proc os::duration {f} {
	variable info
	if {[info exists info(dur,$f)]} { return $info(dur,$f) }
	set d ""
	if {[auto_execok ffprobe] ne "" && ![catch {exec ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $f 2>/dev/null} s] && [string is double -strict [string trim $s]]} {
		set s [expr {int(round([string trim $s]))}]
		set d [format %d:%02d [expr {$s / 60}] [expr {$s % 60}]]
	}
	set info(dur,$f) $d
}

proc os::set_login {key value} {
	dict set bg::login $key $value
	changed
}

# The Colour tab's picker edits this (page::cur_colour / set_colour).
proc os::colour_target {op {hex ""}} {
	if {$op eq "get"} {
		if {[login_side]} { return [string toupper [dict get $bg::login colour]] }
		return [string toupper [dict get $bg::desk colour]]
	}
	if {[login_side]} {
		dict set bg::login same 0; dict set bg::login source colour; dict set bg::login colour $hex
	} else {
		dict set bg::desk mode colour; dict set bg::desk colour $hex
	}
	changed
}
proc os::pick_colour {hex} {
	page::from_hex $hex
	page::set_colour $hex
}

proc os::set_show {s} {
	variable S
	set S(show) $s
	if {$s ne "login"} { set S(tab) [tab_of] } else { set S(tab) [tab_of] }
	if {$S(tab) eq "colour"} { page::from_hex [colour_target get] }
	set ui::focus show
	changed
}

# ---- Apply and Revert -------------------------------------------------------------

proc os::apply {} {
	variable S
	variable recent
	if {$S(busy)} return
	switch -- $S(show) {
		desktop { set d 1; set l 0 }
		login { set d 0; set l 1 }
		default { set d 1; set l 1; dict set bg::login same 1 }
	}
	# a plain colour applied goes to the front of the recent ones
	set c ""
	if {$d && [dict get $bg::desk mode] eq "colour"} { set c [dict get $bg::desk colour] }
	if {$l && [dict get [bg::effective_login] source] eq "colour"} { set c [dict get [bg::effective_login] colour] }
	if {$c ne ""} {
		set recent [lrange [linsert [lsearch -all -inline -not -exact $recent [string toupper $c]] 0 [string toupper $c]] 0 7]
		list_write colours.list $recent
	}
	set jobs [bg::apply_jobs $d $l]
	set S(busy) 1
	draw
	page::run_jobs $jobs os::applied
}

proc os::applied {errs} {
	variable S
	set S(busy) 0
	set S(snap) [bg::snapshot]
	set S(dirty) 0
	set S(applied) 1
	draw
	# what failed, one line each (board Alert-1b-Not-Applied): the first line of each job's report, four at most
	if {[llength $errs]} {
		set lines [lmap e [lrange $errs 0 3] { string range [lindex [split [string trim $e] \n] 0] 0 199 }]
		tell image "Not everything was applied" $lines
	}
}

proc os::revert {} {
	variable S
	bg::restore $S(snap)
	set S(tab) [tab_of]
	if {$S(tab) eq "colour"} { page::from_hex [colour_target get] }
	changed
}

# ---- drawing ------------------------------------------------------------------------

proc os::draw {} {
	variable pending
	if {[info exists pending] && $pending ne ""} return
	set pending [after idle os::draw_now]
}

# The sheet's box (rounded, ringed, shadowed) is the look's picture: made in
# the background as the app starts, so the first opening is quick.
proc os::prewarm_shapes {} {
	rbn::look [look]
}

proc os::draw_now {} {
	variable pending ""
	variable S
	variable SWID
	if {!$S(open)} return
	set cv .sheet.c
	$cv delete all
	set ui::hits {}; set ui::wheels {}; set ui::focusables {}
	incr ui::drawno
	# the box's contents: the bar colour, then the sheet's own drawing (the
	# window's corners and shadow are rbnalpha's, see show_box)
	variable base
	if {[info exists base] && $base ne ""} { image delete $base }
	set base [image create photo -width $SWID -height 207]
	$base put $ui::c(bar) -to 0 0 $SWID 207
	set ui::img $base
	$cv create image 0 0 -image $base -anchor nw -tags page
	head
	draw_$S(tab)
	ui::focus_ring
	$cv move page $ui::ox $ui::oy
	ui::mem_trim
}

# ---- the top row ----------------------------------------------------------------------

proc os::head {} {
	variable S
	variable TABS
	variable SHOWS
	variable SWID
	variable designs
	variable pictures
	variable videos
	array set c [array get ui::c]
	# ‹ Appearance
	variable back_label
	set bw [expr {10 + 16 + 6 + [ui::measure i13s $back_label] + 14}]
	ui::box 20 18 $bw 38 -fill $c(field) -radius 10
	ui::icon left 16 $c(fg) 30 29 2
	ui::text 52 [ui::lh 18 i13s 38] $back_label i13s $c(fg)
	ui::hit 20 18 $bw 38 {apply {{x y} { os::back }}}
	ui::focusable back button 20 18 $bw 38 10 os::back
	# the sources
	set counts [dict create ribbon [expr {[llength $designs] / 2}] pictures [llength $pictures] video [llength $videos]]
	set x [expr {20 + $bw + 10}]
	set items {}
	foreach {k l} $TABS { lappend items $k $l [expr {[dict exists $counts $k] ? [dict get $counts $k] : ""}] }
	seg2 tabs $x 18 $items $S(tab) os::pick_tab
	# Apply, Revert, Show on, from the right
	set r [expr {$SWID - 20}]
	set aw [ui::button_w Apply primary check]
	set r [expr {$r - $aw}]
	ui::button apply $r 18 Apply primary os::apply check $aw
	set rw [ui::button_w Revert ghost undo]
	set r [expr {$r - 10 - $rw}]
	ui::button revert $r 18 Revert ghost os::revert undo $rw
	set items {}
	foreach {k l} $SHOWS { lappend items $k $l "" }
	set sw [seg2_w $items]
	set r [expr {$r - 26 - $sw}]
	seg2 show $r 18 $items $S(show) os::set_show
	ui::text [expr {$r - 12}] [ui::lh 18 i13 38] "Show on" i13 $c(muted) e
}

# The boards' segmented control: items {key label count ...}, 38 tall.
proc os::seg2_w {items} {
	set w 6
	foreach {k l n} $items {
		set w [expr {$w + 28 + [ui::measure i13s $l] + ($n ne "" ? 7 + [ui::measure i13m $n] : 0) + 2}]
	}
	expr {$w - 2}
}
proc os::seg2 {id x y items cur script} {
	array set c [array get ui::c]
	set w [seg2_w $items]
	ui::box $x $y $w 38 -fill $c(field) -radius 10
	ui::ring $x $y $w 38 10 $c(border) 1
	set ix [expr {$x + 3}]
	set keys {}
	foreach {k l n} $items {
		lappend keys $k $l
		set iw [expr {28 + [ui::measure i13s $l] + ($n ne "" ? 7 + [ui::measure i13m $n] : 0)}]
		set on [expr {$k eq $cur}]
		if {$on} { raster::box $ui::img [expr {round($ix)}] [expr {$y + 3}] [expr {round($ix + $iw) - round($ix)}] 32 -fill $c(pill) -radius 8 -shadow {1 3 0.35} }
		set ty [ui::lh [expr {$y + 3}] i13s 32]
		set tw [ui::text [expr {$ix + 14}] $ty $l [expr {$on ? "i13s" : "i13m"}] [expr {$on ? $c(fg) : $c(muted)}]]
		if {$n ne ""} { ui::text [expr {$ix + 14 + $tw + 7}] $ty $n i13m $c(muted) }
		ui::hit $ix [expr {$y + 3}] $iw 32 [list apply {{s k x y} { uplevel #0 [list {*}$s $k] }} $script $k]
		set ix [expr {$ix + $iw + 2}]
	}
	ui::focusable $id seg $x $y $w 38 10 [list ui::seg_key $keys $cur $script]
}

# ---- parts of the content row ---------------------------------------------------------

proc os::y0 {} { return 74 }

# A group's heading: the section label (STYLE: 11 px caps, 600, 0.12em, §muted) centred on the 17 px line the
# tiles' captions use, and the 8 px under it.
proc os::group_head {x t} {
	array set c [array get ui::c]
	ui::text $x [ui::lh [os::y0] i11s 17] [string toupper $t] i11s $c(muted) w 1.32
}

# A card: 88 tall, radius 12, the field colour, ringed (2 px accent when on).
proc os::card {x y w on} {
	array set c [array get ui::c]
	ui::box $x $y $w 88 -fill $c(field) -radius 12
	if {$on} { ui::ring $x $y $w 88 12 $c(accent) 2 } else { ui::ring $x $y $w 88 12 $c(border) 1 }
}

# A divider between groups: 1 px, 24 px either side, the row's height.
proc os::div {x} {
	array set c [array get ui::c]
	ui::box [expr {$x + 24}] [os::y0] 1 113 -fill $c(border)
	expr {$x + 49}
}

# A tile's frame: the ring (2 px accent when chosen, else a faint white
# line) and the tick.
proc os::tile_ring {x y w h on} {
	array set c [array get ui::c]
	if {$on} {
		ui::ring $x $y $w $h 10 $c(accent) 2
		ui::fbox [expr {$x + $w - 25}] [expr {$y + 7}] 18 18 -fill $c(accent) -radius 9
		ui::icon check 10 $c(ink) [expr {$x + $w - 21}] [expr {$y + 11}] 2.8
	} else {
		ui::ring $x $y $w $h 10 #FFFFFF 1 0.07
	}
}

proc os::caption {x y t on {maxw 140}} {
	array set c [array get ui::c]
	set f [expr {$on ? "i13s" : "i13m"}]
	if {[ui::measure $f $t] > $maxw} {
		while {$t ne "" && [ui::measure $f "$t…"] > $maxw} { set t [string range $t 0 end-1] }
		set t "$t…"
	}
	ui::text $x $y $t $f [expr {$on ? $c(fg) : $c(muted)}]
}

# A picture (or video frame) cropped to fill W x H, as a photo; "" if it
# can't be read. MODE: fill, or the Fit card's fit / centre / tile.
proc os::thumb {f w h {mode fill}} {
	if {$f eq "" || ![file readable $f]} { return "" }
	set key [list thumb $f [file mtime $f] $w $h $mode]
	if {[catch {ui::mem $key { os::thumb_png $f $w $h }} p]} { return "" }
	return $p
}

# PNG bytes of F scaled to cover W x H and cropped in the middle: ffmpeg
# (area averaging), else gdk-pixbuf, else Tk in whole steps.
proc os::thumb_png {f w h} {
	set key "$f [file mtime $f] $w $h"
	set out [raster::keyed_path [stage::cachedir] thumb- $key]
	if {![raster::keyed $out $key]} {
		set ok 0
		if {[auto_execok ffmpeg] ne ""} {
			set ok [expr {![catch {exec ffmpeg -nostdin -v error -y -i $f -frames:v 1 \
				-vf "scale=$w:$h:force_original_aspect_ratio=increase:flags=area,crop=$w:$h" $out </dev/null >/dev/null 2>/dev/null}]}]
		}
		if {!$ok} {
			[bg::picture $f $w $h] write $out -format png
		}
		raster::store_key $out $key
	}
	set fh [open $out rb]; set d [read $fh]; close $fh
	return $d
}

# Draw photo P (W x H) at x y with the tile's rounded corners (radius R) on
# the sheet.
proc os::rounded {p x y w h {r 10}} {
	array set c [array get ui::c]
	raster::blit $ui::img $p 0 0 $w $h [expr {round($x)}] [expr {round($y)}]
	ui::corners [expr {round($x)}] [expr {round($y)}] $w $h $r $c(bar)
}

# The Ribbon pattern drawn for a box of its own shape (as on a screen
# 1440 px wide), with its wordmark.
proc os::pattern_tile {w h} {
	set p [palette]
	set key [list ptile $w $h [dict get $p DESK_TOP] [dict get $p DESK_BOTTOM] [dict get $p DESK_STRIPE] [dict get $p DESK_STRIPE_ALPHA]]
	ui::mem $key {
		set s [expr {$w / 1440.0}]
		set W 1440.0; set H [expr {round(1440.0 * $h / $w)}]
		lassign [raster::rgb [dict get $p DESK_TOP]] tr tg tb
		lassign [raster::rgb [dict get $p DESK_BOTTOM]] br bgc bb
		lassign [raster::rgb [dict get $p DESK_STRIPE]] sr sg sb
		set sa [dict get $p DESK_STRIPE_ALPHA]
		set k 0.7071067811865476
		set L [expr {($W + $H) * $k}]
		set rows {}
		for {set y 0} {$y < $h} {incr y} {
			set row {}
			for {set x 0} {$x < $w} {incr x} {
				set r 0.0; set g 0.0; set b 0.0
				foreach sy {0.25 0.75} {
					set Y [expr {($y + $sy) / $s}]
					set t [expr {$Y / $H}]
					set r0 [expr {$tr + ($br - $tr) * $t}]; set g0 [expr {$tg + ($bgc - $tg) * $t}]; set b0 [expr {$tb + ($bb - $tb) * $t}]
					foreach sx {0.25 0.75} {
						set X [expr {($x + $sx) / $s}]
						set q [expr {fmod(($X - $W / 2.0) * $k - ($Y - $H / 2.0) * $k + $L / 2.0, 150.0)}]
						if {$q >= 106.0} {
							set r [expr {$r + $r0 + ($sr - $r0) * $sa}]; set g [expr {$g + $g0 + ($sg - $g0) * $sa}]; set b [expr {$b + $b0 + ($sb - $b0) * $sa}]
						} else { set r [expr {$r + $r0}]; set g [expr {$g + $g0}]; set b [expr {$b + $b0}] }
					}
				}
				lappend row [expr {int($r / 4 + 0.5)}] [expr {int($g / 4 + 0.5)}] [expr {int($b / 4 + 0.5)}] 255
			}
			lappend rows $row
		}
		raster::png $w $h $rows
	}
}

# A strip of tiles that scrolls sideways (the wheel) and, when FADE, fades
# out over its last 70 px: draw into a photo of its own, then fade.
# ITEMS: {kind file name} with kind add | picture | video | design.
proc os::strip {x w items sel fade addlabel {pick ""} {kind picture}} {
	variable S
	variable TW
	variable TH
	array set c [array get ui::c]
	set y [y0]
	set h 113
	set n [llength $items]
	set step [expr {$TW + 16}]
	set vis [expr {int(($w + 16) / $step)}]
	set S(scroll) [expr {max(0, min($S(scroll), $n + 1 - $vis))}]
	set keep $ui::img
	set p [image create photo -width $w -height $h]
	$p put $c(bar) -to 0 0 $w $h
	set ui::img $p
	# icons drawn now are at the strip's own coordinates: moved after
	set mark [.sheet.c create line 0 0 0 0]
	set texts {}
	set tx 0
	set all [linsert $items 0 [list add "" $addlabel]]
	foreach it [lrange $all $S(scroll) end] {
		if {$tx >= $w} break
		lassign $it k f name
		set on [expr {$k ne "add" && $f eq $sel}]
		switch -- $k {
			add {
				ui::dashed $tx 0 $TW $TH 10 $c(border)
				ui::icon plus 15 $c(muted) [expr {$tx + 62.5}] 36.5 2
			}
			design { os::rounded [pattern_tile $TW $TH] $tx 0 $TW $TH; tile_ring $tx 0 $TW $TH $on }
			video {
				set t [thumb [frame $f] $TW $TH]
				if {$t ne ""} { os::rounded $t $tx 0 $TW $TH } else { ui::box $tx 0 $TW $TH -fill $c(field) -radius 10 }
				set d [duration $f]
				if {$d ne ""} {
					set bw [expr {6 + 8 + 4 + [ui::measure i10b $d] + 6}]
					ui::fbox [expr {$tx + 7}] [expr {$TH - 25}] $bw 18 -fill #000000 -alpha 0.6 -radius 5
					lappend texts [list icon play 8 $c(fg) [expr {$tx + 13}] [expr {$TH - 20}]] [list text [expr {$tx + 25}] [ui::lh [expr {$TH - 25}] i10b 18] $d i10b $c(fg)]
				}
				tile_ring $tx 0 $TW $TH $on
			}
			default {
				set t [thumb $f $TW $TH]
				if {$t ne ""} { os::rounded $t $tx 0 $TW $TH } else { ui::box $tx 0 $TW $TH -fill $c(field) -radius 10 }
				tile_ring $tx 0 $TW $TH $on
			}
		}
		lappend texts [list caption $tx 96 $name $on]
		lappend hitl [list $tx $k $f]
		set tx [expr {$tx + $step}]
	}
	if {$fade} {
		# CSS mask-image: linear-gradient(90deg, #000 calc(100% - 70px), transparent)
		for {set i [expr {max(0, $w - 70)}]} {$i < $w} {incr i} {
			set a [expr {($w - ($i + 0.5)) / 70.0}]
			set col {}
			for {set j 0} {$j < $h} {incr j} { lappend col [ui::mix [format #%02x%02x%02x {*}[$p get $i $j]] $c(bar) $a] }
			$p put [lmap v $col { list $v }] -to $i 0
		}
	}
	set ui::img $keep
	raster::blit $ui::img $p 0 0 $w $h [expr {round($x)}] $y
	image delete $p
	foreach i [.sheet.c find all] { if {$i > $mark} { .sheet.c move $i [expr {round($x)}] $y } }
	.sheet.c delete $mark
	# the text and icons, faded the same way, clipped to the strip
	foreach t $texts {
		switch [lindex $t 0] {
			caption {
				lassign $t - cx cy name on
				fade_text [expr {$x + $cx}] [expr {$y + $cy}] $name [expr {$on ? "i13s" : "i13m"}] [expr {$on ? $c(fg) : $c(muted)}] [expr {$x + $w}] $fade
			}
			text {
				lassign $t - tx2 ty2 str f col
				fade_text [expr {$x + $tx2}] [expr {$y + $ty2}] $str $f $col [expr {$x + $w}] $fade
			}
			icon {
				lassign $t - name size col ix iy
				if {$ix < $w} { ui::icon $name $size $col [expr {$x + $ix}] [expr {$y + $iy}] 0.01 {} 1 }
			}
		}
	}
	foreach hl [expr {[info exists hitl] ? $hitl : {}}] {
		lassign $hl hx k f
		set hw [expr {min($TW, $w - $hx)}]
		if {$hw <= 0} continue
		if {$k eq "add"} {
			ui::hit [expr {$x + $hx}] $y $hw 113 [list apply {{s x y} { uplevel #0 $s }} [expr {$kind eq "video" ? "os::add_video" : "os::add_pictures"}]]
		} elseif {$pick ne ""} {
			ui::hit [expr {$x + $hx}] $y $hw 113 [list apply {{s f x y} { uplevel #0 [list {*}$s $f] }} $pick $f]
		}
	}
	ui::wheel $x $y $w 113 os::strip_wheel
	ui::focusable strip list $x $y $w 113 10 [list os::strip_key $items $sel $pick]
}

proc os::strip_wheel {d} {
	variable S
	incr S(scroll) $d
	draw
}

proc os::strip_key {items sel pick sym} {
	set files [lmap it $items { lindex $it 1 }]
	set i [lsearch -exact $files $sel]
	switch -- $sym {
		Left { set i [expr {max(0, $i - 1)}] }
		Right { set i [expr {min([llength $files] - 1, $i + 1)}] }
		Delete { if {$sel ne "" && [os::tab] eq "pictures"} { remove_picture $sel }; return 1 }
		default { return 0 }
	}
	if {$i >= 0 && $pick ne ""} { uplevel #0 [list {*}$pick [lindex $files $i]] }
	set ui::focus strip
	return 1
}
proc os::tab {} { variable S; return $S(tab) }

# Text that fades out like the strip it is in (letter by letter), clipped at X1.
proc os::fade_text {x y str f col x1 fade} {
	array set c [array get ui::c]
	set xs [ui::layout $f $str]
	if {!$fade || $x + [lindex $xs end] < $x1 - 70} {
		if {$x + [lindex $xs end] <= $x1} { ui::text $x $y $str $f $col; return }
	}
	foreach ch [split $str ""] cx [lrange $xs 0 end-1] cx1 [lrange $xs 1 end] {
		set lx [expr {$x + $cx}]
		if {$lx >= $x1} break
		set mid [expr {$x + ($cx + $cx1) / 2.0}]
		set a [expr {$fade ? max(0.0, min(1.0, ($x1 - $mid) / 70.0)) : 1.0}]
		if {$a <= 0} continue
		ui::text $lx $y $ch $f [ui::mix $col $c(bar) $a]
	}
}

# A Fit card's little screen: the picture placed as each mode places it.
proc os::fit_mini {x y w h mode f} {
	array set c [array get ui::c]
	ui::box $x $y $w $h -fill $c(d2) -radius 6
	if {$f ne ""} {
		switch -- $mode {
			fill { set t [thumb $f $w $h]; if {$t ne ""} { raster::blit $ui::img $t 0 0 $w $h $x $y } }
			fit {
				lassign [picture_size $f] pw ph
				set ah [expr {$h}]; set aw [expr {round($h * double($pw) / $ph)}]
				if {$aw > $w} { set aw $w; set ah [expr {round($w * double($ph) / $pw)}] }
				set t [thumb $f $aw $ah]
				if {$t ne ""} { raster::blit $ui::img $t 0 0 $aw $ah [expr {$x + ($w - $aw) / 2}] [expr {$y + ($h - $ah) / 2}] }
			}
			centre {
				set ah [expr {round($h * 0.5)}]; set aw [expr {round($h * 0.75)}]
				set t [thumb $f $aw $ah]
				if {$t ne ""} { raster::blit $ui::img $t 0 0 $aw $ah [expr {$x + ($w - $aw) / 2}] [expr {$y + ($h - $ah) / 2}] }
			}
			tile {
				set tw [expr {round($w / 4.0)}]; set th [expr {round($h / 2.0)}]
				set t [thumb $f $tw $th]
				if {$t ne ""} {
					for {set j 0} {$j < 2} {incr j} { for {set i 0} {$i < 4} {incr i} {
						set ix [expr {$x + $i * $tw}]; set iw [expr {min($tw, $x + $w - $ix)}]
						if {$iw > 0} { raster::blit $ui::img $t 0 0 $iw $th $ix [expr {$y + $j * $th}] }
					} }
				}
			}
		}
	}
	ui::corners $x $y $w $h 6 $c(field)
	ui::ring $x $y $w $h 6 $c(border) 1
}

proc os::picture_size {f} {
	if {[catch {wall::image_size $f} wh]} { return {3 2} }
	return $wh
}

# The Fit group: four cards 104 wide.
proc os::fit_group {x {cw 104}} {
	array set c [array get ui::c]
	group_head $x Fit
	set y [expr {[y0] + 25}]
	set cur [cur_fit]
	set f [cur_picture]
	foreach {m l} {fill Fill fit Fit centre Centre tile Tile} {
		set on [expr {$m eq $cur}]
		card $x $y $cw $on
		fit_mini [expr {$x + 14}] [expr {$y + 12}] [expr {$cw - 28}] 40 $m $f
		ui::text [expr {$x + 14}] [expr {$y + 60}] $l i13s [expr {$on ? $c(fg) : $c(muted)}]
		ui::hit $x $y $cw 88 [list apply {{m x y} { os::set_fit $m }} $m]
		set x [expr {$x + $cw + 10}]
	}
	ui::focusable fit seg [expr {$x - 4 * ($cw + 10)}] $y [expr {4 * $cw + 30}] 88 12 [list ui::seg_key {fill Fill fit Fit centre Centre tile Tile} $cur os::set_fit]
	return $x
}

# A switch with its label (13 px, 10 px after it).
proc os::switch_label {id x y on t script} {
	array set c [array get ui::c]
	ui::toggle $x $y $on
	set tw [ui::text [expr {$x + 48}] [ui::lh $y i13 22] $t i13 $c(fg)]
	ui::hit $x $y [expr {48 + $tw}] 22 [list apply {{s x y} { uplevel #0 $s }} $script]
	ui::focusable $id toggle $x $y 38 22 11 $script
	expr {48 + $tw}
}

# The boards' slider: a 4 px track, filled in the muted colour, an 18 px
# knob. VALUE: the text at its right (min. 44 wide), or "".
proc os::slider {id x y w frac value script} {
	array set c [array get ui::c]
	set vw [expr {$value ne "" ? max(44, [ui::measure i13 $value 0 1]) : 0}]
	set tw [expr {$w - ($value ne "" ? 14 + $vw : 0)}]
	set ty [expr {$y + 10}]
	ui::box $x $ty $tw 4 -fill $c(pill) -radius 2
	if {$frac > 0} { ui::fbox $x $ty [expr {$tw * $frac}] 4 -fill $c(muted) -radius 2 }
	set kx [expr {$x + $tw * $frac}]
	knob $kx [expr {$ty + 2}] 18 $c(fg) {2 6 0.5}
	if {$value ne ""} { ui::text [expr {$x + $w}] [ui::lh $y i13 24] $value i13 $c(fg) e 0 {} 1 }
	ui::hit [expr {$x - 9}] $y [expr {$tw + 18}] 24 [list os::slide $script $x $tw] [list os::slide $script $x $tw]
	ui::focusable $id slider $x $ty $tw 4 2 [list os::slider_key $script $frac]
}
# A round knob D px across in COLOUR with a drop shadow, centred at cx cy.
proc os::knob {cx cy d colour shadow} {
	set x [expr {$cx - $d / 2.0}]; set y [expr {$cy - $d / 2.0}]
	set ix [expr {int(floor($x))}]; set iy [expr {int(floor($y))}]
	set fx [expr {round(($x - $ix) * 4) / 4.0}]; set fy [expr {round(($y - $iy) * 4) / 4.0}]
	lassign [raster::rrect $d $d -fill $colour -radius [expr {$d / 2.0}] -shadow $shadow -offset [list $fx $fy]] img padx pady
	raster::blit $ui::img $img 0 0 [image width $img] [image height $img] [expr {$ix - $padx}] [expr {$iy - $pady}]
}

proc os::slide {script x0 w x y} {
	uplevel #0 [list {*}$script [expr {max(0.0, min(1.0, ($x - $x0) / double($w)))}]]
}
proc os::slider_key {script frac sym} {
	switch -- $sym {
		Left - Down { set frac [expr {$frac - 0.02}] }
		Right - Up { set frac [expr {$frac + 0.02}] }
		Home { set frac 0 }
		End { set frac 1 }
		default { return 0 }
	}
	uplevel #0 [list {*}$script [expr {max(0.0, min(1.0, $frac))}]]
	return 1
}

# A box one step darker than its card (the boards' "inbox"): 32 tall.
proc os::inbox {x y w} {
	array set c [array get ui::c]
	ui::box $x $y $w 32 -fill $c(bar) -radius 8
	ui::ring $x $y $w 32 8 $c(border) 1
}

# ---- the tabs -------------------------------------------------------------------------

proc os::draw_ribbon {} {
	variable designs
	variable TW
	array set c [array get ui::c]
	set items {}
	foreach {id name} $designs { lappend items [list design $id $name] }
	set sel [expr {[tab_of] eq "ribbon" ? "ribbon" : ""}]
	# the tiles spread over the row, as the boards' eight do
	set n 8
	set gap [expr {(1240 - $n * $TW) / double($n - 1)}]
	set x 20
	foreach it $items {
		lassign $it - id name
		set on [expr {$id eq $sel}]
		os::rounded [pattern_tile $TW 88] $x [y0] $TW 88
		tile_ring $x [y0] $TW 88 $on
		caption $x [expr {[y0] + 96}] $name $on
		ui::hit $x [y0] $TW 113 [list apply {{id x y} { os::choose_design $id }} $id]
		set x [expr {$x + $TW + $gap}]
	}
	ui::focusable designs list 20 [y0] $TW 113 10 {apply {{sym} { if {$sym in {Return space}} { os::choose_design ribbon; return 1 }; return 0 }}}
}

proc os::draw_pictures {} {
	variable pictures
	variable S
	array set c [array get ui::c]
	set items [lmap f $pictures { list picture $f [file rootname [file tail $f]] }]
	set sel [cur_picture]
	if {$S(show) eq "login"} {
		# the login screen: two tiles, Fit, and its own Blur, Dim and clock
		set x [strip 20 296 $items $sel 0 "Add pictures" os::choose_picture]
		set x [div [expr {20 + 296}]]
		set x [fit_group $x]
		set x [div [expr {$x - 10}]]
		login_group $x
		return
	}
	set fitw [expr {4 * 104 + 30}]
	set sw [expr {1240 - $fitw - 49}]
	strip 20 $sw $items $sel 1 "Add pictures" os::choose_picture
	div [expr {20 + $sw}]
	fit_group [expr {20 + $sw + 49}]
}

proc os::login_group {x} {
	array set c [array get ui::c]
	set l $bg::login
	group_head $x "Login screen"
	set y [expr {[y0] + 25}]
	foreach {key t max unit} {blur Blur 34 " px" dim Dim 100 %} {
		card $x $y 128 0
		set v [dict get $l $key]
		ui::text [expr {$x + 14}] [expr {$y + 12}] $t i13s $c(fg)
		ui::text [expr {$x + 114}] [expr {$y + 12}] "$v$unit" i13 $c(muted) e 0 {} 1
		slider l$key [expr {$x + 14}] [expr {$y + 52}] 100 [expr {min(1.0, $v / double($max))}] "" \
			[list apply {{key max f} { os::set_login $key [expr {int(round($f * $max))}] }} $key $max]
		set x [expr {$x + 138}]
	}
	set on [expr {[bg::yesno [dict get $l clock]] eq "yes"}]
	card $x $y 122 0
	ui::icon clock 18 $c(fg) [expr {$x + 14}] [expr {$y + 14}]
	ui::toggle [expr {$x + 122 - 14 - 38}] [expr {$y + 12}] $on
	ui::text [expr {$x + 14}] [expr {$y + 44}] "Show the" i13s $c(fg)
	ui::text [expr {$x + 14}] [expr {$y + 60}] clock i13s $c(fg)
	set s {os::set_login clock [expr {[bg::yesno [dict get $bg::login clock]] eq "yes" ? "no" : "yes"}]}
	ui::hit $x $y 122 88 [list apply {{s x y} { uplevel #0 $s }} $s]
	ui::focusable lclock toggle [expr {$x + 70}] [expr {$y + 12}] 38 22 11 $s
}

proc os::draw_slideshow {} {
	array set c [array get ui::c]
	set d $bg::desk
	set y [expr {[y0] + 25}]
	set fw [expr {1240 - 520 - 24}]
	group_head 20 Folder
	card 20 $y $fw 0
	# the mosaic: the folder's first four pictures
	set s [slides]
	set mx 34; set my [expr {$y + 12}]
	ui::box $mx $my 64 64 -fill $c(field) -radius 8
	foreach f [lrange $s 0 3] {i j} {0 0 1 0 0 1 1 1} {
		if {$f eq ""} break
		set t [thumb $f 31 31]
		if {$t ne ""} { raster::blit $ui::img $t 0 0 31 31 [expr {$mx + 33 * $i}] [expr {$my + 33 * $j}] }
	}
	ui::corners $mx $my 64 64 8 $c(field)
	set dir [dict get $d dir]
	set rx 112
	if {$dir eq ""} {
		ui::text $rx [ui::lh [expr {$y + 12}] i14s 32] "No folder yet" i14s $c(muted)
	} else {
		set home [store::env HOME]
		set shown [expr {$home ne "" && [string first $home/ $dir/] == 0 ? "~[string range $dir [string length $home] end]" : $dir}]
		set tw [ui::text $rx [ui::lh [expr {$y + 12}] i14s 32] $shown i14s $c(fg)]
		set n [llength $s]
		ui::text [expr {$rx + $tw + 12}] [ui::lh [expr {$y + 12}] i13 32] "$n [expr {$n == 1 ? "picture" : "pictures"}]" i13 $c(muted)
	}
	set bw [expr {28 + [ui::measure i13s Change]}]
	set bx [expr {20 + $fw - 14 - $bw}]
	os::inbox $bx [expr {$y + 12}] $bw
	ui::text [expr {$bx + 14}] [ui::lh [expr {$y + 12}] i13s 32] Change i13s $c(fg)
	ui::hit $bx [expr {$y + 12}] $bw 32 {apply {{x y} { os::change_folder }}}
	ui::focusable change button $bx [expr {$y + 12}] $bw 32 8 os::change_folder
	set tx $rx
	set tx [expr {$tx + 28 + [switch_label shuffle $tx [expr {$y + 54}] [expr {[bg::yesno [dict get $d shuffle]] eq "yes"}] Shuffle {os::flip shuffle}]}]
	switch_label subdirs $tx [expr {$y + 54}] [expr {[bg::yesno [dict get $d subdirs]] eq "yes"}] "Include subfolders" {os::flip subdirs}
	# timing
	set x [expr {20 + $fw + 24}]
	group_head $x Timing
	card $x $y 520 0
	set ly [expr {$y + 10}]
	ui::text [expr {$x + 14}] [ui::lh $ly i13 32] "Change every" i13 $c(muted)
	lassign [interval_parts] n unit
	set sx [expr {$x + 120}]
	os::inbox $sx $ly 78
	set on [expr {$ui::focus eq "interval"}]
	if {$on} { ui::ring $sx $ly 78 32 8 $c(accent) 1.5 }
	set shown [expr {$on && [info exists ::os::numbuf] && $::os::numbuf ne "" ? $::os::numbuf : $n}]
	ui::text [expr {$sx + 12}] [ui::lh $ly i14s 32] $shown i14s $c(fg) w 0 {} 1
	ui::box [expr {$sx + 54}] $ly 1 32 -fill $c(border)
	ui::box [expr {$sx + 55}] [expr {$ly + 16}] 22 1 -fill $c(border)
	ui::icon up 11 $c(fg) [expr {$sx + 61}] [expr {$ly + 2.5}] 2.4
	ui::icon down 11 $c(fg) [expr {$sx + 61}] [expr {$ly + 18.5}] 2.4
	ui::hit $sx $ly 54 32 {apply {{x y} { set ::os::numbuf ""; set ui::focus interval; os::draw }}}
	ui::hit [expr {$sx + 54}] $ly 24 16 {apply {{x y} { os::step_interval 1 }}}
	ui::hit [expr {$sx + 54}] [expr {$ly + 16}] 24 16 {apply {{x y} { os::step_interval -1 }}}
	ui::focusable interval num $sx $ly 78 32 8 os::interval_key
	set dx [expr {$sx + 88}]; set dw [expr {$x + 520 - 14 - $dx}]
	os::inbox $dx $ly $dw
	ui::text [expr {$dx + 12}] [ui::lh $ly i14 32] $unit i14 $c(fg)
	ui::icon down 14 $c(muted) [expr {$dx + $dw - 24}] [expr {$ly + 9}] 2
	ui::hit $dx $ly $dw 32 [list apply {{x0 y0 w x y} { os::unit_menu $x0 [expr {$y0 + 34}] $w }} $dx $ly $dw]
	ui::focusable unit seg $dx $ly $dw 32 8 [list ui::seg_key {minutes minutes hours hours days days} $unit {apply {{u} { os::set_interval [lindex [os::interval_parts] 0] $u }}}]
	set ly2 [expr {$y + 46}]
	ui::text [expr {$x + 14}] [ui::lh $ly2 i13 32] Crossfade i13 $c(muted)
	set cf [dict get $d crossfade]
	slider crossfade [expr {$x + 120}] [expr {$ly2 + 4}] [expr {520 - 14 - 120}] [expr {min(1.0, $cf / 5.0)}] [format "%.1f s" $cf] \
		{apply {{f} { dict set ::bg::desk crossfade [expr {round($f * 50) / 10.0}]; os::changed }}}
	# the unit menu, when open
	variable menu
	if {[info exists menu] && $menu ne ""} { draw_menu }
}

proc os::interval_key {sym {char ""}} {
	variable numbuf
	if {![info exists numbuf]} { set numbuf "" }
	lassign [interval_parts] n unit
	switch -- $sym {
		Up { step_interval 1; return 1 }
		Down { step_interval -1; return 1 }
		BackSpace { set numbuf [string range $numbuf 0 end-1]; draw; return 1 }
		Return - KP_Enter - Tab { if {$numbuf ne ""} { set_interval [scan $numbuf %d] $unit }; set numbuf ""; draw; return [expr {$sym ne "Tab"}] }
		Escape { set numbuf ""; draw; return 1 }
	}
	if {[string is digit -strict $char] && [string length $numbuf] < 4} { append numbuf $char; draw; return 1 }
	return 0
}

# The unit's menu: minutes, hours, days, under the box.
proc os::unit_menu {x y w} {
	variable menu
	set menu [list $x $y $w]
	draw
}
proc os::draw_menu {} {
	variable menu
	array set c [array get ui::c]
	lassign $menu x y w
	lassign [interval_parts] n unit
	set h [expr {3 * 32 + 8}]
	# no room under the box in the sheet: it opens upwards
	set y [expr {$y - 34 - $h - 4}]
	set ui::hits {}
	ui::hit -1000 -1000 4000 4000 {apply {{x y} { set ::os::menu ""; os::draw }}}
	set keep $ui::img
	set x [expr {round($x)}]; set y [expr {round($y)}]
	set p [image create photo -width $w -height $h]
	$p copy $keep -from $x [expr {max(0, $y)}] [expr {$x + $w}] [expr {max(0, $y) + $h}] -to 0 [expr {max(0, -$y)}]
	set ui::img $p
	ui::box 0 0 $w $h -fill $c(field) -radius 10 -ring [list $c(border) 1]
	set ui::img $keep
	.sheet.c create image $x $y -image $p -anchor nw -tags page
	set iy [expr {$y + 4}]
	foreach u {minutes hours days} {
		if {$u eq $unit} {
			set q [image create photo -width [expr {$w - 8}] -height 32]
			$q copy $p -from 4 [expr {$iy - $y}] [expr {$w - 4}] [expr {$iy - $y + 32}]
			set ui::img $q; ui::box 0 0 [expr {$w - 8}] 32 -fill $c(pill) -radius 8; set ui::img $keep
			.sheet.c create image [expr {$x + 4}] $iy -image $q -anchor nw -tags page
		}
		ui::text [expr {$x + 12}] [ui::lh $iy i14 32] $u i14 [expr {$u eq $unit ? $c(fg) : $c(muted)}]
		ui::hit [expr {$x + 4}] $iy [expr {$w - 8}] 32 [list apply {{u x y} { set ::os::menu ""; os::set_interval [lindex [os::interval_parts] 0] $u }} $u]
		set iy [expr {$iy + 32}]
	}
}

proc os::draw_video {} {
	variable videos
	array set c [array get ui::c]
	set items [lmap f $videos { list video $f [file rootname [file tail $f]] }]
	set sel [expr {[dict get $bg::desk mode] eq "video" ? [dict get $bg::desk video] : ""}]
	set sw [expr {3 * 140 + 32}]
	strip 20 $sw $items $sel 1 "Add video" os::choose_video video
	set x [div [expr {20 + $sw}]]
	# pause when ...
	set bw 160
	set pw [expr {1240 + 20 - $x - 24 - $bw}]
	group_head $x "Pause when"
	set y [expr {[y0] + 25}]
	set cw [expr {($pw - 30) / 4.0}]
	foreach {key icon l1 l2} {pause_fullscreen full {A window is} fullscreen pause_covered wins Windows {cover it}
			pause_game game {A game is} running pause_battery battery {On battery} ""} {
		set on [expr {[bg::yesno [dict get $bg::desk $key]] eq "yes"}]
		set cx [expr {round($x)}]; set cww [expr {round($x + $cw) - $cx}]
		card $cx $y $cww 0
		set col [expr {$on ? $c(fg) : $c(muted)}]
		ui::icon $icon 18 $col [expr {$cx + 14}] [expr {$y + 14}]
		ui::toggle [expr {$cx + $cww - 14 - 38}] [expr {$y + 12}] $on
		if {$l2 eq ""} {
			ui::text [expr {$cx + 14}] [expr {$y + 60}] $l1 i13s $col
		} else {
			ui::text [expr {$cx + 14}] [expr {$y + 44}] $l1 i13s $col
			ui::text [expr {$cx + 14}] [expr {$y + 60}] $l2 i13s $col
		}
		set s [list os::flip $key]
		ui::hit $cx $y $cww 88 [list apply {{s x y} { uplevel #0 $s }} $s]
		ui::focusable $key toggle [expr {$cx + $cww - 52}] [expr {$y + 12}] 38 22 11 $s
		set x [expr {$x + $cw + 10}]
	}
	set x [expr {1260 - $bw}]
	group_head $x Bars
	card $x $y $bw 0
	set cur [dict get $bg::desk bars]
	set iy [expr {$y + 3}]
	foreach {k l} {see-through See-through solid Solid} {
		set on [expr {$k eq $cur}]
		if {$on} { raster::box $ui::img [expr {$x + 3}] $iy [expr {$bw - 6}] 40 -fill $c(pill) -radius 8 -shadow {1 3 0.35} }
		if {$k eq "solid"} {
			ui::box [expr {$x + 15}] [expr {$iy + 14}] 26 12 -fill $c(bar) -radius 4
			ui::ring [expr {$x + 15}] [expr {$iy + 14}] 26 12 4 $c(border) 1
		} else {
			ui::fbox [expr {$x + 15}] [expr {$iy + 14}] 26 12 -fill #FFFFFF -alpha 0.10 -radius 4 -ring {#FFFFFF 1 0.22}
		}
		ui::text [expr {$x + 51}] [ui::lh $iy i13s 40] $l i13s [expr {$on ? $c(fg) : $c(muted)}]
		ui::hit [expr {$x + 3}] $iy [expr {$bw - 6}] 40 [list apply {{k x y} { dict set ::bg::desk bars $k; os::changed }} $k]
		set iy [expr {$iy + 42}]
	}
	ui::focusable bars seg $x $y $bw 88 12 [list ui::seg_key {see-through See-through solid Solid} $cur {apply {{k} { dict set ::bg::desk bars $k; os::changed }}}]
}

# Colour: the Colours page's picker (page::picker_sv, page::track and the
# number keys), the theme's colours and the recent ones.
proc os::draw_colour {} {
	variable recent
	array set c [array get ui::c]
	set y [expr {[y0] + 25}]
	set cw 470
	set svw [expr {1240 - $cw - 18 - 49 - 184 - 24 - 184}]
	group_head 20 Colour
	page::picker_sv 20 $y $svw 88 {2 8 0.6}
	# (the boards' 8 px spacer shrinks away between two 10 px gaps)
	set x [expr {20 + $svw + 20}]
	# hue
	ui::text $x [ui::lh $y i13 32] Hue i13 $c(muted)
	set nx [expr {$x + $cw - 64}]
	set tx [expr {$x + 42}]
	page::track hue $tx [expr {$y + 10}] [expr {$nx - 12 - $tx}] [expr {$page::S(h) / 360.0}] hue $y 32
	nbox nhue $nx $y 64 "" "[expr {round($page::S(h)) % 360}]°" hue
	# RGB / HSL and the numbers, the hex
	set ry [expr {$y + 56}]
	set mode [expr {$page::S(mode) eq "hsl" ? "hsl" : "rgb"}]
	set items {rgb RGB "" hsl HSL ""}
	set sw [seg2_w12 $items]
	seg2_12 cmode $x $ry $items $mode {apply {{m} { set ::page::S(mode) $m; os::draw }}}
	lassign [pal::rgb [page::cur_colour]] r g b
	if {$mode eq "rgb"} {
		set vals [list R $r chR G $g chG B $b chB]
	} else {
		lassign [pal::rgb2hsl $r $g $b] h s l
		set vals [list H [expr {round($h) % 360}] chH S [expr {round($s * 100)}] chS L [expr {round($l * 100)}] chL]
	}
	set bx [expr {$x + $sw + 8}]
	foreach {p v id} $vals {
		nbox n$id $bx $ry 62 $p $v $id
		set bx [expr {$bx + 70}]
	}
	hexbox [expr {$x + $cw - 128}] $ry
	# theme and recent
	set x [div [expr {20 + $svw + 18 + $cw}]]
	set p [palette]
	group_head $x Theme
	swatches $x $y [lmap k {DESK_BOTTOM DESK_TOP BAR FIELD PILL BORDER MUTED ACCENT} { dict get $p $k }] theme
	set x [expr {$x + 184 + 24}]
	group_head $x Recent
	swatches $x $y $recent recent
}

proc os::swatches {x y cols id} {
	array set c [array get ui::c]
	set cur [page::cur_colour]
	set i 0
	foreach col $cols {
		set sx [expr {$x + ($i % 4) * 48}]; set sy [expr {$y + ($i / 4) * 48}]
		set on [expr {$id eq "recent" && [string equal -nocase $col $cur]}]
		ui::fbox $sx $sy 40 40 -fill $col -radius 9 -ring [expr {$on ? [list $c(accent) 2 1] : {#FFFFFF 1 0.10}}]
		ui::hit $sx $sy 40 40 [list apply {{col x y} { os::pick_colour $col }} $col]
		incr i
		if {$i >= 8} break
	}
}

# The boards' number box: 32 tall, a prefix (12 px bold, muted), the value
# right-aligned. Typing works as on the Colours page (page::num_key).
proc os::nbox {id x y w pre val chan} {
	array set c [array get ui::c]
	ui::box $x $y $w 32 -fill $c(field) -radius 8
	set on [expr {$ui::focus eq $id}]
	if {$on} { ui::ring $x $y $w 32 8 $c(accent) 1.5 } else { ui::ring $x $y $w 32 8 $c(border) 1 }
	if {$pre ne ""} { ui::text [expr {$x + 10}] [ui::lh $y i12b 32] $pre i12b $c(muted) }
	set shown [expr {$on && [info exists page::S(numbuf)] && $page::S(numbuf) ne "" ? $page::S(numbuf) : $val}]
	ui::text [expr {$x + $w - 10}] [ui::lh $y i13 32] $shown i13 $c(fg) e 0 {} 1
	ui::hit $x $y $w 32 [list apply {{id x y} { set ::page::S(numbuf) ""; set ui::focus $id; os::draw }} $id]
	ui::focusable $id num $x $y $w 32 8 [list page::num_key $chan]
}

proc os::hexbox {x y} {
	array set c [array get ui::c]
	set w 128
	set on [expr {$ui::focus eq "hex"}]
	ui::box $x $y $w 32 -fill $c(field) -radius 8
	if {$on} { ui::ring $x $y $w 32 8 $c(accent) 1.5 } else { ui::ring $x $y $w 32 8 $c(border) 1 }
	ui::text [expr {$x + 10}] [ui::lh $y i12b 32] Hex i12b $c(muted)
	set v [expr {$on ? [ui::fval hex] : [page::cur_colour]}]
	set tw [ui::text [expr {$x + $w - 10}] [ui::lh $y mono13 32] $v mono13 $c(fg) e]
	if {$on} { ui::caret_at [expr {$x + $w - 9}] [expr {$y + 8}] }
	ui::hit $x $y $w 32 {apply {{x y} { ui::fset hex [page::cur_colour]; set ui::focus hex; os::draw }}}
	ui::focusable hex field $x $y $w 32 8 [list page::hex_typed page::hex_done 7]
}

# A smaller segmented control (32 tall, 12 px): the RGB / HSL switch.
proc os::seg2_w12 {items} {
	set w 6
	foreach {k l n} $items { set w [expr {$w + 24 + [ui::measure i13s $l] + 2}] }
	expr {$w - 2}
}
# STYLE §8 at 32: 13 px, 12 px part padding, track radius 9, part radius 6
proc os::seg2_12 {id x y items cur script} {
	array set c [array get ui::c]
	set w [seg2_w12 $items]
	ui::box $x $y $w 32 -fill $c(field) -radius 9
	ui::ring $x $y $w 32 9 $c(border) 1
	set ix [expr {$x + 3}]
	set keys {}
	foreach {k l n} $items {
		lappend keys $k $l
		set iw [expr {24 + [ui::measure i13s $l]}]
		set on [expr {$k eq $cur}]
		if {$on} { raster::box $ui::img [expr {round($ix)}] [expr {$y + 3}] [expr {round($ix + $iw) - round($ix)}] 26 -fill $c(pill) -radius 6 -shadow {1 2 0.3} }
		set f [expr {$on ? "i13s" : "i13m"}]
		ui::text [expr {$ix + 12}] [ui::lh [expr {$y + 3}] $f 26] $l $f [expr {$on ? $c(fg) : $c(muted)}]
		ui::hit $ix [expr {$y + 3}] $iw 26 [list apply {{s k x y} { uplevel #0 [list {*}$s $k] }} $script $k]
		set ix [expr {$ix + $iw + 2}]
	}
	ui::focusable $id seg $x $y $w 32 9 [list ui::seg_key $keys $cur $script]
}

# ---- keys ------------------------------------------------------------------------------

proc os::key {sym char state} {
	variable menu
	update idletasks
	if {[info exists menu] && $menu ne ""} {
		if {$sym eq "Escape"} { set menu ""; draw }
		return
	}
	set f [ui::focused]
	lassign $f id kind
	switch -- $sym {
		Tab { if {$state & 1} { ui::cycle -1 } else { ui::cycle 1 }; draw; return }
		ISO_Left_Tab { ui::cycle -1; draw; return }
	}
	if {$kind eq "field"} {
		if {$sym eq "Escape"} { set ui::focus ""; page::hex_done; draw; return }
		if {$sym in {Return KP_Enter}} { page::hex_done; set ui::focus ""; draw; return }
		if {[ui::field_key $id $sym $char $state]} { draw }
		return
	}
	if {$kind eq "num"} {
		if {[uplevel #0 [list {*}[lindex $f 7] $sym $char]]} { draw; return }
	}
	if {$kind in {button toggle} && $sym in {Return KP_Enter space}} { uplevel #0 [lindex $f 7]; return }
	if {$kind in {list seg slider area} && [uplevel #0 [list {*}[lindex $f 7] $sym]]} { draw; return }
	switch -- $sym {
		Escape { back }
		Return - KP_Enter { apply }
	}
}
