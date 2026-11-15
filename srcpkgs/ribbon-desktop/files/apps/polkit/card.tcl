# card.tcl - the password prompt of ribbon-polkit (boards Polkit-A-Card, Polkit-A2-Choose; STYLE.md).
# It only DRAWS. It binds no keys and has no entry: what is typed arrives from ribbon-polkit-keys through the
# agent as counts ("n 7": seven dots) and key names (tab, up, enter ...), and the answer goes from that helper
# straight into PAM's pipe (agent.tcl). The mouse works as usual (the buttons, the picker rows, Details).
#
# Drawing is the Appearance app's (appearance/ui.tcl on the shell's text.tcl and raster.tcl): every pixel at the
# board's CSS size, text placed letter by letter. Windows are rbnalpha's: a full-screen ARGB scrim at 70 % black
# (rbnalpha::backdrop; without a compositor there is none), and the card, a 440 px box with the board's shadow
# and see-through corners. Neither takes the keyboard: both are override-redirect.
#
# The UI table the agent calls: card::table. See agent.tcl.

namespace eval page {}
proc page::draw {} { card::draw }
proc page::clicked_outside {} {}

namespace eval card {
	variable W 440
	variable id ""          ;# the request on the card now
	variable info {}
	variable identities {}  ;# {uid name display kind} dicts
	variable chosen ""      ;# the account name selected
	variable choose 0       ;# the picker is shown
	variable count 0        ;# characters typed so far
	variable text ""        ;# echo mode: what was typed
	variable echo 0
	variable ph ""          ;# placeholder (a prompt that is not the usual password one)
	variable msg {}         ;# {kind text}: kind error|info
	variable open 0         ;# Details expanded
	variable busy 0         ;# an answer was sent and PAM has not replied
	variable prompting 0
	variable top 0          ;# the box's top-left on the screen (fixed while the card grows)
	variable left 0
	variable pending ""
	variable up 0           ;# a card is on screen
	variable scrim 0
}

# ---- setup: the shell's text and raster code and Appearance's drawing, as the welcome does
proc card::find {name file} {
	set here $::here
	foreach d [list [file join [file dirname $here] $name] [file join [file dirname [file dirname $here]] $name] /usr/lib/ribbon/$name] {
		if {[file exists [file join $d $file]]} { return $d }
	}
	error "$name/$file was not found"
}

proc card::setup {} {
	set shelldir [expr {[info exists ::env(RIBBON_SHELL_DIR)] ? $::env(RIBBON_SHELL_DIR) : [find shell raster.tcl]}]
	set appdir [find appearance ui.tcl]
	# text.tcl first: it sets up the fonts' weights before Tk opens a font
	foreach f {text raster wall theme} { uplevel #0 [list source -encoding utf-8 [file join $shelldir $f.tcl]] }
	uplevel #0 [list source -encoding utf-8 [file join $appdir ui.tcl]]
	package require rbnalpha
	set cache [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : [file join [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}] .cache]}]
	raster::init [file join $cache ribbon polkit]
	rbn::init [file join $cache ribbon rbnalpha]
	# the card's title and initials are Space Grotesk at sizes Appearance does not use
	foreach {k px} {sg20 20 sg12 12 sg13 13} { set ui::fonts($k) [list {Ribbon Space Grotesk 600} $px 0.984 0.292] }
	# the icons the board uses that Appearance does not have (the generators' paths)
	set ui::paths(right) {M9 18l6-6-6-6}
	ui::fonts
	proc ::ui::clip {f str width} { card::clip $f $str $width }
	set ui::caretfix [expr {[info exists ::env(RIBBON_POLKIT_CARETFIX)] ? $::env(RIBBON_POLKIT_CARETFIX) : ""}]
}

proc card::colours {} {
	theme::load
	array set p [array get theme::c]
	ui::colours [dict create BAR $p(BAR) FIELD $p(FIELD) PILL $p(PILL) BORDER $p(BORDER) FG $p(FG) MUTED $p(MUTED) \
		ACCENT $p(ACCENT) ON_ACCENT $p(ON_ACCENT) DESK_TOP $p(DESK_TOP) DESK_BOTTOM $p(DESK_BOTTOM) \
		DESK_STRIPE $p(DESK_STRIPE) DESK_STRIPE_ALPHA $p(DESK_STRIPE_ALPHA)]
}

proc card::table {} {
	list show card::show prompt card::prompt info card::note error card::problem done card::done key card::key
}

# ---- what the board says: the action's sentence as a title, who asked as the line under it
# polkit's message is a whole sentence ("Authentication is required to install system updates"); the board's
# title is the action ("Install system updates").
proc card::title {message} {
	if {[regexp -nocase {^authentication is required to (.+?)\.?$} $message -> rest]} {
		return [string toupper [string index $rest 0]][string range $rest 1 end]
	}
	return $message
}

# The line under the title: the program (pkexec's "program" detail), else the process that asked.
proc card::subtitle {details} {
	if {[dict exists $details program]} { return [file tail [dict get $details program]] }
	if {[dict exists $details polkit.caller-pid]} {
		set pid [dict get $details polkit.caller-pid]
		if {[string is integer -strict $pid] && ![catch {open /proc/$pid/comm} f]} { set n [string trim [read $f]]; close $f; return $n }
	}
	return ""
}

# Detail rows for the expander: the action id, then what polkit sent besides its own bookkeeping.
proc card::detail_rows {} {
	variable info
	set rows [list [list Action [dict get $info action]]]
	dict for {k v} [dict get $info details] {
		if {$k eq "polkit.caller-pid"} { lappend rows [list Process $v]; continue }
		if {[string match polkit.* $k] || $v eq ""} continue
		lappend rows [list [string toupper [string index $k 0]][string range $k 1 end] $v]
	}
	lrange $rows 0 4
}

# ---- the UI table
proc card::show {id inf} {
	variable W; variable info $inf; variable identities; variable chosen; variable choose
	variable count 0; variable text ""; variable echo 0; variable ph ""; variable msg {}; variable open 0
	variable busy 0; variable prompting 0; variable up
	# the card and its scrim are built again for each request: the scrim (.pks) is not kept between them
	catch {destroy .pk}
	catch {destroy .pks}
	set card::id $id
	set identities [dict get $inf identities]
	set chosen [dict get $inf identity]
	set choose [dict get $inf choose]
	set ui::W $W
	set ui::H [height]
	set ui::behind ""; set ui::argbwin ""
	foreach {k v} {ox 0 oy 0 focus pw kbd 0 dim 0} { set ui::$k $v }
	build
	set up 1
	polkit::focus $id field
	draw
	ui::blink
}

proc card::prompt {id asked isecho} {
	variable count 0; variable text ""; variable echo $isecho; variable ph; variable busy 0; variable prompting 1
	# the usual "Password:" is the board's field with nothing in it; anything else is shown in the field
	if {[regexp -nocase {^\s*(password|passwort|mot de passe)[^:]*:?\s*$} $asked] && !$isecho} { set ph "" } else { set ph [string trim $asked] }
	if {$id eq $card::id} { draw }
}

proc card::note {id text} { variable msg [list info $text]; if {$id eq $card::id} { relayout } }
proc card::problem {id text} { variable msg [list error $text]; variable busy 0; if {$id eq $card::id} { relayout } }

proc card::done {id result} {
	variable up 0
	after cancel ui::blink
	rbn::hide .pks
	rbn::hide .pk
	set card::id ""
}

# From the keyboard helper (through the agent).
proc card::key {id name args} {
	variable count; variable text; variable busy; variable chosen; variable identities
	if {$id ne $card::id} return
	switch -- $name {
		count { set count [lindex $args 0]; draw }
		text { set text [lindex $args 0]; draw }
		esc { polkit::cancel $id }
		tab { ui::cycle 1; focus_changed }
		btab { ui::cycle -1; focus_changed }
		up - down { pick_move [expr {$name eq "up" ? -1 : 1}] }
		enter - space {
			set f [ui::focused]
			if {$f eq ""} return
			if {[lindex $f 1] eq "field"} { if {$name eq "enter"} submit; return }
			uplevel #0 [lindex $f 7]
		}
	}
}

proc card::focus_changed {} {
	variable id
	polkit::focus $id [expr {$ui::focus eq "pw" ? "field" : "other"}]
}

proc card::submit {} {
	variable id; variable busy
	if {$busy || $id eq ""} return
	if {![catch {polkit::submit $id} sent] && $sent} { set busy 1; draw }
}

proc card::cancel {} { variable id; if {$id ne ""} { polkit::cancel $id } }

proc card::pick {name} {
	variable id; variable chosen; variable count
	if {$name eq $chosen} return
	set chosen $name
	polkit::choose $id $name
	draw
}

proc card::pick_move {d} {
	variable identities; variable chosen; variable choose
	if {!$choose || $ui::focus ne "pick"} return
	set names [lmap i $identities { dict get $i name }]
	set i [lsearch -exact $names $chosen]
	set j [expr {max(0, min([llength $names] - 1, $i + $d))}]
	pick [lindex $names $j]
}

proc card::toggle_details {} { variable open [expr {!$::card::open}]; relayout }
proc card::clicked_field {x y} { set ui::focus pw; focus_changed; draw }

# ---- geometry (the board's CSS pixels; ids from gen_polkit.py)
proc card::lines {} {
	variable info
	set t [ui::wrap sg20 [title [dict get $info message]] 326 -0.4]
	if {[llength $t] > 2} { set t [list [lindex $t 0] "[ui::clip sg20 [join [lrange $t 1 end] " "] 326]"] }
	return $t
}

proc card::headh {} {
	set n [llength [lines]]
	set sub [expr {[subtitle [dict get $::card::info details]] ne ""}]
	# title lines of 23, 3 gap and a 16 line of sub; the tile is 44
	set h [expr {$n * 23 + ($sub ? 3 + 16 : 0)}]
	expr {max(44, $h)}
}

proc card::whoh {} {
	variable choose; variable identities
	if {!$choose} { return 40 }
	# label 14 + 8, then 44 rows 2 apart
	expr {22 + 2 + [llength $identities] * 44 + ([llength $identities] - 1) * 2}
}

proc card::detailsh {} {
	variable open
	if {!$open} { return 0 }
	expr {[llength [detail_rows]] * 28 + 8}
}

proc card::msgh {} { variable msg; expr {[llength $msg] ? 8 + 16 : 0} }

proc card::height {} {
	# padding 26, head, 18, rule, 18, who, 12, field 38, message, 22, details, footer rule, 72
	expr {26 + [headh] + 18 + 18 + [whoh] + 12 + 38 + [msgh] + 22 + [detailsh] + 72}
}

# ---- the windows
proc card::build {} {
	variable W; variable scrim
	set SW [winfo screenwidth .]; set SH [winfo screenheight .]
	# the scrim: the whole screen at 70 % black, an ARGB window with a tiled background
	if {[rbn::argb] && [rbn::native]} {
		rbn::surface .pks
		destroy .pks.c
		# a tile of black at alpha 178/255 (70 %), the window's background repeats it
		set ::card::dim [image create photo -data [raster::png 16 16 [lrepeat 16 [string repeat {0 0 0 178 } 16]]] -format png]
		rbnalpha::backdrop .pks $::card::dim
		wm geometry .pks ${SW}x${SH}+0+0
		wm deiconify .pks
		raise .pks
		set scrim 1
	} else { set scrim 0 }
	rbn::surface .pk -class RibbonPolkit
	set ui::cv .pk.c
	bind .pk.c <ButtonPress-1> {ui::press %x %y}
	bind .pk.c <B1-Motion> {ui::motion %x %y}
	bind .pk.c <ButtonRelease-1> {ui::release %x %y}
	variable left [expr {max(0, ($SW - $W) / 2)}]
	variable top [expr {max(0, ($SH - [height]) / 2)}]
	place_card
}

proc card::place_card {} {
	variable W; variable left; variable top
	set H [height]
	set ui::H $H
	rbn::popup .pk $left $top $W $H [dict create -fill $ui::c(bar) -radius 16 -ring [list $ui::c(border) 1] -shadow {24 64 0.6}]
	.pk.c configure -width $W -height $H
}

proc card::relayout {} {
	variable up
	if {!$up} return
	place_card
	draw
}

proc card::draw {} {
	variable pending
	if {$pending ne ""} return
	set pending [after idle card::draw_now]
}

# ---- drawing
proc card::frame_boxes {} {
	variable W
	array set c [array get ui::c]
	ui::box 0 0 $W $ui::H -fill $c(bar)
}

proc card::draw_now {} {
	variable pending ""
	variable W; variable up
	if {!$up || ![winfo exists .pk.c]} return
	array set c [array get ui::c]
	variable choose; variable open
	ui::begin [list card $::ui::H] card::frame_boxes
	set hh [headh]
	# head: the tile, the title, who asked
	tile 28 26
	set ty [expr {26 + ($hh - ([llength [lines]] * 23 + ([subtitle [dict get $card::info details]] ne "" ? 19 : 0))) / 2.0}]
	set y $ty
	foreach l [lines] { ui::text 86 [ui::lh $y sg20 23 1] $l sg20 $c(fg) w -0.4; set y [expr {$y + 23}] }
	set sub [subtitle [dict get $card::info details]]
	if {$sub ne ""} { ui::text 86 [expr {$y + 3}] [ui::clip i13 $sub 326] i13 $c(muted) }
	# the body: a rule, then who and the field
	set by [expr {26 + $hh + 18}]
	ui::hline 28 412 $by $c(border)
	set y [expr {$by + 18}]
	if {$choose} { set y [draw_picker $y] } else { draw_one 28 $y }
	set fy [expr {$y + ($choose ? 0 : 40) + 12}]
	draw_field 28 $fy 384
	set y [expr {$fy + 38}]
	if {[llength $card::msg]} {
		lassign $card::msg kind t
		ui::text 28 [expr {$y + 8}] [ui::clip i13 $t 384] i13 [expr {$kind eq "error" ? $::theme::c(ERR) : $c(muted)}]
		set y [expr {$y + 8 + 16}]
	}
	set y [expr {$y + 22}]
	if {$open} { set y [draw_details $y] }
	# the footer
	ui::hline 0 $W $y $c(border)
	set fh 72
	set bx [expr {$y + ($fh - 38) / 2}]
	set aw [ui::button_w Authenticate primary check]
	set cw [ui::button_w Cancel ghost]
	ui::button auth [expr {412 - $aw}] $bx Authenticate primary card::submit check
	ui::button cancel [expr {412 - $aw - 10 - $cw}] $bx Cancel ghost card::cancel
	set dtw [ui::measure i13 Details]
	ui::text 28 [ui::lh [expr {$y + 28}] i13 16] Details i13 $c(muted)
	ui::icon right 13 $c(muted) [expr {28 + $dtw + 8}] [expr {$y + 28 + 1.5}] 2.2
	ui::hit 28 [expr {$y + 20}] [expr {$dtw + 28}] 32 [list apply {{x y} card::toggle_details}]
	ui::focusable details button 28 [expr {$y + 20}] [expr {$dtw + 28}] 32 8 card::toggle_details
	ui::focus_ring
	ui::finish
}

# The lock tile: 44 square, radius 27 %, a 160-degree gradient from the raised tone to the field's, a 1 px ring.
proc card::tile {x y} {
	array set c [array get ui::c]
	set g [raster::cached [list polkit-tile [ui::col $c(pill)] [ui::col $c(field)] [ui::col $c(border)]] {
		lassign [raster::rgb [ui::col $c(pill)]] r0 g0 b0
		lassign [raster::rgb [ui::col $c(field)]] r1 g1 b1
		lassign [raster::rgb [ui::col $c(border)]] rr rg rb
		set s 44; set r 11.88
		set dx 0.3420201433256687; set dy 0.9396926207859084
		set len [expr {$s * $dx + $s * $dy}]
		set rows {}
		for {set j 0} {$j < $s} {incr j} {
			set row {}
			for {set i 0} {$i < $s} {incr i} {
				set px [expr {$i + 0.5}]; set py [expr {$j + 0.5}]
				set co [raster::rbox $px $py 0 0 $s $s $r]
				if {$co <= 0} { lappend row 0 0 0 0; continue }
				set t [expr {min(1.0, max(0.0, (($px - $s / 2.0) * $dx + ($py - $s / 2.0) * $dy) / $len + 0.5))}]
				set ci [raster::rbox $px $py 1 1 [expr {$s - 1}] [expr {$s - 1}] [expr {$r - 1}]]
				set k [expr {$co - $ci}]
				set fr [expr {$r0 + ($r1 - $r0) * $t}]; set fg [expr {$g0 + ($g1 - $g0) * $t}]; set fb [expr {$b0 + ($b1 - $b0) * $t}]
				lappend row [expr {int($rr * $k + $fr * (1 - $k) + 0.5)}] [expr {int($rg * $k + $fg * (1 - $k) + 0.5)}] \
					[expr {int($rb * $k + $fb * (1 - $k) + 0.5)}] [expr {int($co * 255 + 0.5)}]
			}
			lappend rows $row
		}
		raster::png $s $s $rows
	}]
	raster::blit $ui::img $g 0 0 44 44 $x $y
	ui::icon lock 20 $c(fg) [expr {$x + 12}] [expr {$y + 12}] 1.8
}

# The chosen account's avatar: a circle on the accent fading to 35 % (150 degrees), or the raised tone, with an initial.
proc card::avatar {x y size letter on} {
	array set c [array get ui::c]
	if {$on} { ui::fbox $x $y $size $size -fill $c(accent) -radius [expr {$size / 2.0}] -grad 0.35 } \
	else { ui::box $x $y $size $size -fill $c(pill) -radius [expr {$size / 2.0}] }
	set f [expr {$size > 30 ? "sg13" : "sg12"}]
	set w [ui::measure $f $letter]
	ui::text [expr {$x + ($size - $w) / 2.0}] [ui::lh $y $f $size] $letter $f [expr {$on ? $c(ink) : $c(muted)}]
}

proc card::who {} {
	variable identities; variable chosen
	foreach i $identities { if {[dict get $i name] eq $chosen} { return $i } }
	lindex $identities 0
}

# Polkit-A-Card: the one account, a plain line (you are the admin).
proc card::draw_one {x y} {
	array set c [array get ui::c]
	set i [who]
	set disp [dict get $i display]
	avatar $x [expr {$y + 4}] 32 [string toupper [string index $disp 0]] 1
	ui::text [expr {$x + 44}] [expr {$y + 4}] [ui::clip i13s $disp 330] i13s $c(fg)
	ui::text [expr {$x + 44}] [expr {$y + 4 + 17}] [dict get $i name] i12 $c(muted)
}

# Polkit-A2-Choose: "Authenticate as" and a row for each account.
proc card::draw_picker {y} {
	variable identities; variable chosen
	array set c [array get ui::c]
	ui::label 28 $y "Authenticate as"
	set ry [expr {$y + 24}]
	foreach i $identities {
		set on [expr {[dict get $i name] eq $chosen}]
		set disp [dict get $i display]
		if {$on} { ui::box 18 $ry 404 44 -fill $c(field) -radius 10 }
		avatar 28 [expr {$ry + 8}] 28 [string toupper [string index $disp 0]] $on
		ui::text 68 [expr {$ry + 6}] [ui::clip [expr {$on ? "i13s" : "i13m"}] $disp 300] [expr {$on ? "i13s" : "i13m"}] [expr {$on ? $c(fg) : $c(muted)}]
		ui::text 68 [expr {$ry + 6 + 17}] [dict get $i name] i12 $c(muted)
		if {$on} { ui::icon check 15 $c(accent) 397 [expr {$ry + 14.5}] 2.4 }
		ui::hit 18 $ry 404 44 [list apply {{n x y} { set ui::focus pick; card::pick $n }} [dict get $i name]]
		incr ry 46
	}
	ui::focusable pick list 18 [expr {$y + 24}] 404 [expr {$ry - $y - 24 - 2}] 10 card::pick_enter
	return [expr {$y + [whoh]}]
}
proc card::pick_enter {} {}

# The field: a count of dots (or, for a prompt PAM says is not secret, the text), a caret. No eye: nothing typed reaches this process.
proc card::draw_field {x y w} {
	variable count; variable text; variable echo; variable ph
	array set c [array get ui::c]
	set on [expr {$ui::focus eq "pw"}]
	ui::box $x $y $w 38 -fill $c(field) -radius 10
	if {$on} { ui::ring $x $y $w 38 10 $c(accent) 1.5 } else { ui::ring $x $y $w 38 10 $c(border) 1 }
	set tx [expr {$x + 12}]
	set top [ui::lh $y i14 38]
	set avail [expr {$w - 12 - 12 - 2}]
	if {$echo} { set s $text } else { set s [string repeat • $count] }
	if {$s eq "" && $ph ne ""} {
		ui::text $tx $top [ui::clip i14 $ph $avail] i14 $c(muted)
		set cx $tx
	} else {
		# the last characters that fit, as a field scrolls
		while {$s ne "" && [ui::measure i14 $s] > $avail} { set s [string range $s 1 end] }
		set cx [expr {$tx + [expr {$s eq "" ? 0 : [ui::text $tx $top $s i14 $c(fg)]}]}]
	}
	if {$on} { ui::caret_at [expr {$cx + 1}] [expr {$y + 11}] }
	ui::hit $x $y $w 38 card::clicked_field
	ui::focusable pw field $x $y $w 38 10 {}
}

proc card::draw_details {y} {
	array set c [array get ui::c]
	foreach row [detail_rows] {
		lassign $row k v
		ui::text 28 [ui::lh [expr {$y + 14}] i12 28] $k i12 $c(muted)
		ui::text 128 [ui::lh [expr {$y + 14}] mono12 28] [ui::clip mono12 $v 284] mono12 $c(fg)
		incr y 28
	}
	return [expr {$y + 8}]
}

# Text cut to WIDTH with an ellipsis (the welcome's helper).
proc card::clip {f str width} {
	if {[ui::measure $f $str] <= $width} { return $str }
	while {$str ne "" && [ui::measure $f "$str…"] > $width} { set str [string range $str 0 end-1] }
	return "$str…"
}
