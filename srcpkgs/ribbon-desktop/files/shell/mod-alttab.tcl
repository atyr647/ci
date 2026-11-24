# mod-alttab.tcl - the Alt+Tab switcher: the app list, the grid, the motion and the keys (U17, U18).
#
# Cards are apps, not windows: one per app_id, most recently used first. An
# app's place is that of its most recent window (the activation serial that
# ribbon-shell-watch gives each window, `mru`); its windows follow in the same
# order. Layout is design/tools/gen_alttab.py's, STYLE §21: equal 16:10 cells,
# at most three rows shown, a fanned stack's well as one more row.
#
# Workspaces: the compositor protocols give a window its outputs but not its
# workspace, so no card is marked and every window is listed (dropped by decision).
#
# Keys, stills and window copies come from ribbon-shell-switch (U19, shell-watch/switch.c): it holds
# the keyboard on a layer-shell overlay while the switcher is up, reports Alt release and the keys
# the compositor does not bind, takes the still the background is made from, and copies windows
# (ext-image-copy-capture) where the compositor offers it. Without it the cards stay icons, the
# background flat, and the switcher is driven by the verb alone.
# `switcher next|prev|app` are what rc.xml binds to A-Tab, A-S-Tab and A-grave; `open|fan|close` remain.
#
# Motion (U18): one frame timer (`animate`) drives everything. The grid's scroll eases 160 ms, one line
# at a time. A window or app that leaves is drawn as a ghost (`leave`) for 140 ms: W lifts the window
# (98 % of a card up, 84 %, fading from 34 %), Q and a well's W shrink or fade it (92 % from 32 %). The cards
# behind close up over 160 ms (the re-fit tween, `snap`). A window still listed after 600 ms asked to stay
# (a save prompt), so it keeps its card (`closing`, `poll`). Times come from `now`, so a scene can pin them.

namespace eval alttab {
	variable on 0         ;# the switcher is open
	variable apps {}      ;# per app: dict app label ids (most recent first)
	variable sel 1        ;# the chosen app, an index into apps
	variable first 0      ;# the first grid line shown (the target of the scroll ease)
	variable fan 0        ;# the chosen app's well is open
	variable fanwin 1     ;# the window chosen inside the well
	variable canvas ""
	variable scr {1440 900}  ;# the size of the screen the switcher covers: the main display (display.tcl)
	variable org {0 0}       ;# that display's place on the X screen
	variable shown 0      ;# drawn (a tap under TAPMS switches without ever showing)
	# The two times of an Alt+Tab (U20). REVEALMS: the switcher is mapped this long after the bind, which is
	# the one knob for how fast it feels. TAPMS: an Alt release inside this long after the bind is still a tap
	# (switch to the last window, no stepping); between the two the switcher has been mapped for a moment and
	# is closed at once. Measured on labwc 0.20.3 (U20): 70 ms reveals as soon as the still is blurred.
	variable revealms 70
	variable tapms 150
	variable t_open 0     ;# when the bind opened the switcher
	variable prep 0       ;# the surface is built and drawn but still unmapped (while the reveal timer runs)
	variable shotpend 0   ;# the still has been asked for and has not come back
	variable h ""         ;# the helper's channel
	variable hcaps {}     ;# what the helper says the compositor offers: shot, cap
	variable hidle ""     ;# the timer that quits an idle helper
	variable bg ""        ;# the blurred still, a photo, or ""
	variable ph; array set ph {}       ;# window id -> the photo its card shows
	variable phw; array set phw {}     ;# window id -> the width of that photo
	variable inflight {}  ;# window ids with a copy requested
	variable slices {}    ;# images made for one frame, freed at the next
	variable want {}      ;# the windows the cards on screen show: {id width}
	variable seq 0
	variable closing {}   ;# windows asked to close and not yet seen gone
	variable rects {}     ;# last frame: key -> {x y w h} ("a:APP" a card, "w:ID" a well card, "well")
	variable hits {}      ;# last frame's click targets: {x y w h action arg}
	variable maxfirst 0   ;# the last line the scroll can reach
	variable pos_from 0   ;# the scroll ease: where it started and when
	variable pos_t0 0
	variable snap {}      ;# the re-fit tween: key -> the rect it starts from
	variable snap_t0 0
	variable snap_delay 0
	variable snap_dur 160
	variable ghosts {}    ;# pictures on their way out
	variable anim 0       ;# the frame timer is set
	variable fake ""      ;# a fixed clock (scenes set it to pin a frame)
	variable pollid ""
	variable pollfor 600
}

# Timing probe: with RIBBON_ALTTAB_PROBE=<file> every stage of an open appends "<us> <label>" to it (the
# profile in tests/alttab-native/profile.sh); otherwise it costs one `info exists`.
proc alttab::probe {label} {
	if {![info exists ::env(RIBBON_ALTTAB_PROBE)]} return
	catch {
		set f [::open $::env(RIBBON_ALTTAB_PROBE) a]
		puts $f "[clock microseconds] $label"
		::close $f
	}
}

# Round like Python's round(): halves go to the even integer. The board
# generator rounds this way, so the same sums give the same pixels.
proc alttab::rnd {x} {
	set f [expr {int(floor($x))}]
	set d [expr {$x - $f}]
	if {$d > 0.5} { return [expr {$f + 1}] }
	if {$d < 0.5} { return $f }
	return [expr {$f + ($f % 2)}]
}

# ---- time and easing ------------------------------------------------------

proc alttab::now {} {
	variable fake
	if {$fake ne ""} { return $fake }
	return [clock milliseconds]
}

# Smoothstep: 0 at p = 0, 1 at p = 1.
proc alttab::ease {p} {
	if {$p <= 0} { return 0.0 }
	if {$p >= 1} { return 1.0 }
	return [expr {$p * $p * (3 - 2 * $p)}]
}

# ---- the app list ----------------------------------------------------

# A window's activation serial: 0 until the helper has reported one.
proc alttab::mru {id} {
	if {[info exists ::wm::tl($id)] && [dict exists $::wm::tl($id) mru]} { return [dict get $::wm::tl($id) mru] }
	return 0
}

proc alttab::by_use {a b} {
	set ma [mru $a]
	set mb [mru $b]
	if {$ma != $mb} { return [expr {$ma > $mb ? -1 : 1}] }
	return [expr {[lsearch -exact $::wm::order $a] - [lsearch -exact $::wm::order $b]}]
}

# The apps, most recent first. An app's windows are in use order too.
proc alttab::collect {} {
	variable closing
	set out {}
	foreach id [lsort -command alttab::by_use [wm::windows]] {
		if {$id in $closing} continue
		set app [wm::get $id app]
		# every tab of every terminal group (ribbon-term-GROUP-N) is one ribbon-terminal card, as in dock.tcl
		if {[string match -nocase ribbon-term-* $app]} { set app ribbon-terminal }
		set i [lsearch -exact -index 0 $out $app]
		if {$i < 0} {
			lappend out [list $app [list $id]]
		} else {
			lset out $i 1 [concat [lindex $out $i 1] [list $id]]
		}
	}
	set apps {}
	foreach rec $out {
		lassign $rec app ids
		lappend apps [dict create app $app label [apps::label $app] ids $ids]
	}
	return $apps
}

# ---- the grid ----------------------------------------------------------

# Rows and columns for N apps (FANROW: the row a well opens under, or -1).
# The sizes are the board's: GW 1312 wide, 740 tall with a well, 24 across,
# 28 between rows, 300 a cell at most.
proc alttab::shape {n {fanrow -1}} {
	set rows [expr {min(3, ($n + 4) / 5)}]
	set cols [expr {min(5, ($n + $rows - 1) / $rows)}]
	set nrow [expr {($n + $cols - 1) / $cols}]
	set wells [expr {$fanrow >= 0 ? 1 : 0}]
	set shown [expr {min(3, $nrow + $wells)}]
	set byh [expr {((740 - 28 * ($shown - 1) - 24 * $wells) / double($shown) - 36) * 1.6}]
	set byw [expr {(1312 - 24 * ($cols - 1)) / double($cols)}]
	set cw [expr {int(min(300, $byw, $byh))}]
	set ch [rnd [expr {$cw / 1.6}]]
	# the lines: a row is a card row, a well sits under its row
	set lines {}
	set y 0
	for {set r 0} {$r < $nrow} {incr r} {
		lappend lines [list row $r $y]
		incr y [expr {$ch + 10 + 26 + 28}]
		if {$r == $fanrow} {
			lappend lines [list well $r [expr {$y + 12}]]
			incr y [expr {$ch + 10 + 26 + 24 + 28}]
		}
	}
	return [dict create rows $rows cols $cols nrow $nrow cw $cw ch $ch lines $lines]
}

# The y of line K (a fraction is between two lines).
proc alttab::lyat {lines k} {
	set L [llength $lines]
	if {$k <= 0} { return [lindex $lines 0 2] }
	if {$k >= $L - 1} { return [lindex $lines end 2] }
	set i [expr {int(floor($k))}]
	set f [expr {$k - $i}]
	set a [lindex $lines $i 2]
	set b [lindex $lines [expr {$i + 1}] 2]
	return [expr {$a + ($b - $a) * $f}]
}

# Where everything goes on a W x H screen. FIDX is the app whose well is open
# (-1: none) with NWIN windows; FIRST the first line shown (it may be a fraction
# while the grid eases). Returns the cards, the well and the overflow. Lines past the
# three shown are returned too; the caller covers them.
proc alttab::place {n fanrow fidx nwin W H first} {
	set s [shape $n $fanrow]
	set cols [dict get $s cols]; set cw [dict get $s cw]; set ch [dict get $s ch]
	set lines [dict get $s lines]
	set L [llength $lines]
	set gw [expr {$cols * $cw + 24 * ($cols - 1)}]
	set gx [rnd [expr {$W / 2.0 - $gw / 2.0}]]
	set f [expr {max(0.0, min(double($first), double($L - 3)))}]
	set k2 [expr {min($f + 2, $L - 1)}]
	set y0 [lyat $lines $f]
	set bh [expr {[lyat $lines $k2] + $ch + 36 - $y0}]
	set top [rnd [expr {$H / 2.0 - $bh / 2.0}]]
	set off [expr {$top - $y0}]
	set cards {}
	set well {}
	foreach ln $lines {
		lassign $ln kind r ly
		set y [expr {$ly + $off}]
		if {$kind eq "row"} {
			for {set c 0} {$c < $cols} {incr c} {
				set i [expr {$r * $cols + $c}]
				if {$i >= $n} break
				lappend cards [list $i [expr {$gx + $c * ($cw + 24)}] [rnd $y]]
			}
		} else {
			set c0 [expr {min($fidx % $cols, $cols - $nwin)}]
			set well [dict create x [expr {$gx + $c0 * ($cw + 24) - 12}] y [rnd [expr {$y - 12}]] \
				w [expr {$nwin * $cw + 24 * ($nwin - 1) + 24}] h [expr {$ch + 36 + 24}] \
				nx [expr {$gx + ($fidx % $cols) * ($cw + 24) + $cw / 2}]]
		}
	}
	set over [expr {$L > 3}]
	set vt [expr {$top - 68}]
	set vb [expr {$top + $bh + 68}]
	return [dict create cw $cw ch $ch cols $cols lines $lines first $f top $top bh $bh \
		cards $cards well $well \
		cutTop [expr {$over ? $top - 24 : -1}] cutBottom [expr {$over ? $vb : -1}] \
		up [expr {$over && $f > 0 ? $vt - 8 - 32 : -1}] \
		down [expr {$over && $f + 3 < $L ? $vb + 8 : -1}]]
}

# The scroll: where the first line is now, on the ease from the last target.
proc alttab::curpos {} {
	variable first; variable pos_from; variable pos_t0
	set p [expr {max(0.0, min(1.0, ([now] - $pos_t0) / 160.0))}]
	return [expr {$pos_from + ($first - $pos_from) * [ease $p]}]
}

# Move the grid's first line to N (kept inside the lines), easing over 160 ms.
proc alttab::setfirst {n} {
	variable first; variable pos_from; variable pos_t0; variable maxfirst
	set n [expr {max(0, min($n, $maxfirst))}]
	if {$n == $first} return
	set pos_from [curpos]
	set pos_t0 [now]
	set first $n
	kick
}

# Keep the chosen line in the three shown: the first line moves only when the
# choice would leave them, one line at a time.
proc alttab::follow {L cline} {
	variable first; variable maxfirst
	set maxfirst [expr {max(0, $L - 3)}]
	if {$L <= 3} { setfirst 0; return }
	set f $first
	if {$cline < $f} { set f $cline }
	if {$cline > $f + 2} { set f [expr {$cline - 2}] }
	setfirst [expr {max(0, min($f, $L - 3))}]
}

# ---- the re-fit and the ghosts ----------------------------------------------

# Remember what is on screen, so the cards can close up from it: the rects of the last frame.
proc alttab::relayout {delay} {
	variable rects; variable snap; variable snap_t0; variable snap_delay
	set snap $rects
	set snap_t0 [now]
	set snap_delay $delay
	kick
}

# A card's rect on this frame: the rect it starts from (the re-fit tween), or R.
proc alttab::tween {key r} {
	variable snap; variable snap_t0; variable snap_delay; variable snap_dur
	if {$snap eq "" || ![dict exists $snap $key]} { return $r }
	set p [expr {([now] - $snap_t0 - $snap_delay) / double($snap_dur)}]
	set e [ease $p]
	if {$e >= 1.0} { return $r }
	lassign [dict get $snap $key] x0 y0 w0 h0
	lassign $r x1 y1 w1 h1
	return [list [rnd [expr {$x0 + ($x1 - $x0) * $e}]] [rnd [expr {$y0 + ($y1 - $y0) * $e}]] \
		[rnd [expr {$w0 + ($w1 - $w0) * $e}]] [rnd [expr {$h0 + ($h1 - $h0) * $e}]]]
}

# A picture leaving: KIND lift (W: up, smaller, fading), shrink (Q: the whole card) or fade (a well's W).
proc alttab::leave {kind r info} {
	variable ghosts
	lappend ghosts [dict merge [dict create kind $kind rect $r t0 [now] dur 140] $info]
}

# Where a ghost is at time T: its rect and opacity (0 to 1; the fade starts at the listed value).
proc alttab::ghost_pose {g t} {
	set p [expr {max(0.0, min(1.0, ($t - [dict get $g t0]) / double([dict get $g dur])))}]
	set e [ease $p]
	lassign [dict get $g rect] x y w h
	switch -- [dict get $g kind] {
		lift { set s [expr {1 - 0.16 * $e}]; set dy [expr {-0.98 * $h * $e}]; set a [expr {0.34 * (1 - $p)}] }
		shrink { set s [expr {1 - 0.08 * $e}]; set dy 0; set a [expr {0.32 * (1 - $p)}] }
		default { set s 1.0; set dy 0; set a [expr {0.34 * (1 - $p)}] }
	}
	set sw [rnd [expr {$w * $s}]]
	set sh [rnd [expr {$h * $s}]]
	return [dict create x [rnd [expr {$x + ($w - $sw) / 2.0}]] y [rnd [expr {$y + ($h - $sh) / 2.0 + $dy}]] \
		w $sw h $sh a $a s $s]
}

# ---- drawing -----------------------------------------------------------

# A colour A moved toward B by T (0 = A, 1 = B), both as #RRGGBB.
proc alttab::mix {a b t} {
	set out "#"
	for {set i 1} {$i < 7} {incr i 2} {
		set x [scan [string range $a $i $i+1] %x]
		set y [scan [string range $b $i $i+1] %x]
		append out [format %02X [expr {int(round($x + ($y - $x) * $t))}]]
	}
	return $out
}

proc alttab::truncate {font s w} {
	if {[text::width $font $s] <= $w} { return $s }
	set s [string range $s 0 end-1]
	while {$s ne "" && [text::width $font "$s…"] > $w} { set s [string range $s 0 end-1] }
	return "$s…"
}

# The tag at a card's right end: "Fullscreen" over a fullscreen game, else the window count of a stack.
proc alttab::tagtext {front k} {
	if {$front ne "" && [wm::has $front full]} { return "Fullscreen" }
	if {$k > 1} { return $k }
	return ""
}

# A card's label row, 10 under the card: the app icon, the name, and the tag at the right end.
proc alttab::labelrow {C x ly cw kind label tag lit ink tagbg tagfg bg} {
	$C create image $x $ly -image [theme::icon $kind 16 1.8 $ink] -anchor nw
	set tf [expr {$lit ? "f13s" : "f13m"}]
	set tagw [expr {$tag eq "" ? 0 : [text::width f11s $tag] + 12}]
	set avail [expr {$cw - 24 - $tagw - 8}]
	$C create text [expr {$x + 24}] [expr {$ly + 8}] -anchor w -font $tf -fill $ink \
		-text [truncate $tf $label $avail]
	if {$tag ne ""} {
		rbn::box $C [expr {$x + $cw - $tagw}] [expr {$ly + 4}] $tagw 18 -fill $tagbg -radius 9 -on $bg
		$C create text [expr {$x + $cw - $tagw / 2.0}] [expr {$ly + 13}] -anchor center -font f11s \
			-fill $tagfg -text $tag
	}
}

proc alttab::card {C i x y cw ch lit ring bg} {
	variable apps; variable phw
	upvar #0 theme::c c
	set a [lindex $apps $i]
	set app [dict get $a app]
	set ids [dict get $a ids]
	set k [llength $ids]
	# the stack: one back card for two windows, two for three or more
	for {set b 1} {$b <= min(2, $k - 1)} {incr b} {
		set ins [expr {10 * $b}]; set lift [expr {7 * $b}]
		set f [expr {$b == 1 ? 0.8 : 0.5}]
		rbn::box $C [expr {$x + $ins}] [expr {$y - $lift}] [expr {$cw - 2 * $ins}] $ch \
			-fill [mix $bg $c(FIELD) $f] -radius 12 -ring [list [mix $bg $c(BORDER) $f] 1] -on $bg
	}
	set edge [expr {$ring ? [list $c(ACCENT) 2] : [list $c(BORDER) 1]}]
	rbn::box $C $x $y $cw $ch -fill $c(FIELD) -radius 12 -ring $edge -on $bg
	set kind [apps::iconfor [apps::forwindow $app] $app]
	set front [lindex $ids 0]
	picture $C $front $x $y $cw $ch $kind $c(MUTED) 1.0 $bg
	lappend alttab::want [list $front [expr {$cw - 4}]]
	set ink [expr {$lit ? $c(FG) : $c(MUTED)}]
	labelrow $C $x [expr {$y + $ch + 10}] $cw $kind [dict get $a label] [tagtext $front $k] $lit $ink \
		$c(PILL) $c(MUTED) $bg
}

# A window's picture, its top-left at (X, Y) in a W x H card: the copy when one is held at this
# width, else the app icon on the card's field.
proc alttab::picture {C id x y w h kind ink s bg} {
	variable ph; variable phw
	set pw [expr {$w - 4}]
	if {[info exists ph($id)] && [info exists phw($id)] && $phw($id) == $pw} {
		$C create image [expr {$x + 2}] [expr {$y + 2}] -image $ph($id) -anchor nw
	} else {
		$C create image [rnd [expr {$x + ($w - 48) / 2.0}]] [rnd [expr {$y + ($h - 48) / 2.0}]] \
			-image [theme::icon $kind 48 1.6 $ink] -anchor nw
	}
}

proc alttab::draw {} {
	variable canvas; variable apps; variable sel; variable first; variable fan
	variable fanwin; variable on; variable scr; variable shown; variable want
	variable rects; variable hits; variable maxfirst; variable ghosts; variable prep
	upvar #0 theme::c c
	if {!$on || !($shown || $prep) || $canvas eq ""} return
	lassign $scr W H
	set want {}; set rects {}; set hits {}
	foreach sl $alttab::slices { catch {image delete $sl} }
	set alttab::slices {}
	set bg [mix $c(DESK_TOP) #000000 0.42]
	$canvas delete all
	if {$alttab::bg ne ""} {
		$canvas create image 0 0 -image $alttab::bg -anchor nw
		set bg [mix $c(DESK_TOP) #000000 0.42]   ;# the colour the fades and the overflow cuts match
	} else {
		$canvas create rectangle 0 0 $W $H -fill $bg -outline ""
	}
	set n [llength $apps]
	if {$n == 0} { ghosts_draw $canvas $bg; return }
	set nwin [llength [dict get [lindex $apps $sel] ids]]
	set fidx [expr {$fan && $nwin > 1 ? $sel : -1}]
	set cols [dict get [shape $n] cols]
	set fanrow [expr {$fidx >= 0 ? $sel / $cols : -1}]
	# the line the choice is on: its well when open, else its card's row
	set lines [dict get [shape $n $fanrow] lines]
	set chosenkind [expr {$fidx >= 0 ? "well" : "row"}]
	set cline 0
	foreach ln $lines {
		if {[lindex $ln 0] eq $chosenkind && [lindex $ln 1] == $sel / $cols} { set cline [lsearch -exact $lines $ln] }
	}
	set maxfirst [expr {max(0, [llength $lines] - 3)}]
	follow [llength $lines] $cline
	set g [place $n $fanrow $fidx $nwin $W $H [curpos]]
	set cw [dict get $g cw]; set ch [dict get $g ch]
	foreach card [dict get $g cards] {
		lassign $card i x y
		set key "a:[dict get [lindex $apps $i] app]"
		set r [tween $key [list $x $y $cw $ch]]
		lassign $r x y w h
		dict set rects $key $r
		lappend hits [list $x $y $w $h card $i]
		# the corners blend into what is behind the card: the still's colour on its row
		card $canvas $i $x $y $w $h [expr {$i == $sel}] [expr {$i == $sel && $fidx < 0}] [bgmean [expr {$y + $h / 2}] $bg]
	}
	if {[dict get $g well] ne ""} {
		set wl [dict get $g well]
		set wr [tween well [list [dict get $wl x] [dict get $wl y] [dict get $wl w] [dict get $wl h]]]
		lassign $wr wx wy ww wh
		dict set rects well $wr
		rbn::box $canvas $wx $wy $ww $wh -fill $c(BAR) -radius 24 -ring [list $c(BORDER) 1] -on $bg
		set nx [dict get $wl nx]
		$canvas create polygon [expr {$nx - 10}] $wy $nx [expr {$wy - 10}] [expr {$nx + 10}] $wy \
			-fill $c(BAR) -outline ""
		$canvas create line [expr {$nx - 10}] $wy $nx [expr {$wy - 10}] [expr {$nx + 10}] $wy \
			-fill $c(BORDER) -width 1
		set app [dict get [lindex $apps $sel] app]
		set kind [apps::iconfor [apps::forwindow $app] $app]
		foreach j [seq_ $nwin] {
			set id [lindex [dict get [lindex $apps $sel] ids] $j]
			set r [tween "w:$id" [list [expr {$wx + 12 + $j * ($cw + 24)}] [expr {$wy + 12}] $cw $ch]]
			lassign $r x y w h
			dict set rects "w:$id" $r
			lappend hits [list $x $y $w $h well $j]
			set chosen [expr {$j == $fanwin}]
			set ring [expr {$chosen ? [list $c(ACCENT) 2] : [list $c(BORDER) 1]}]
			rbn::box $canvas $x $y $w $h -fill $c(FIELD) -radius 12 -ring $ring -on $c(BAR)
			picture $canvas $id $x $y $w $h $kind $c(MUTED) 1.0 $c(BAR)
			lappend alttab::want [list $id [expr {$w - 4}]]
			$canvas create text $x [expr {$y + $h + 18}] -anchor w -font f13m \
				-fill [expr {$chosen ? $c(FG) : $c(MUTED)}] -text [truncate f13m [wm::get $id title] $w]
		}
	}
	ghosts_draw $canvas $bg
	# above the three rows: cut clean, 24 over the first row's cards. Below:
	# the next row shows its top 40 px, fading out (a 10 px dither in four bands).
	if {[dict get $g cutTop] >= 0} {
		set b [dict get $g cutBottom]
		cover $canvas 0 [dict get $g cutTop] $bg
		set m [bgmean [expr {$b - 25}] $bg]
		foreach {d stip} {-40 gray25 -30 gray50 -20 gray75 -10 ""} {
			set opt [expr {$stip eq "" ? "" : "-stipple $stip"}]
			$canvas create rectangle 0 [expr {$b + $d}] $W [expr {$b + $d + 10}] -fill $m -outline "" {*}$opt
		}
		cover $canvas $b $H $bg
	}
	foreach {key up} {up 1 down 0} {
		set y [dict get $g $key]
		if {$y < 0} continue
		rbn::box $canvas [expr {$W / 2 - 16}] $y 32 32 -fill $c(FIELD) -radius 16 -ring [list $c(BORDER) 1] -on $bg
		lappend hits [list [expr {$W / 2 - 16}] $y 32 32 arrow [expr {$up ? -1 : 1}]]
		set cx [expr {$W / 2}]; set cy [expr {$y + 16}]
		set d [expr {$up ? 1 : -1}]
		$canvas create line [expr {$cx - 6}] [expr {$cy + 3 * $d}] $cx [expr {$cy - 3 * $d}] [expr {$cx + 6}] [expr {$cy + 3 * $d}] \
			-fill $c(MUTED) -width 2 -capstyle round -joinstyle round
	}
}

# The pictures on their way out (a window lifting, a card shrinking, a well's card fading), over the cards.
proc alttab::ghosts_draw {C bg} {
	variable ghosts
	set t [now]
	foreach g $ghosts { ghost_draw $C $g $bg $t }
}

proc alttab::ghost_draw {C g bg t} {
	variable slices; variable ph
	upvar #0 theme::c c
	set q [ghost_pose $g $t]
	set x [dict get $q x]; set y [dict get $q y]; set w [dict get $q w]; set h [dict get $q h]
	set a [dict get $q a]; set s [dict get $q s]
	set kind [dict get $g kind]
	rbn::box $C $x $y $w $h -fill [mix $bg $c(FIELD) $a] -radius 12 -ring [list [mix $bg $c(BORDER) $a] 1] -on $bg
	set id [dict get $g id]
	if {[info exists ph($id)] && [lsearch -exact [image names] $ph($id)] >= 0} {
		set im [image create photo]
		lappend slices $im
		$im copy $ph($id) -zoom [expr {round(100 * $s)}] -subsample 100
		if {$a < 0.999} {
			set v [veil [image width $im] [image height $im] $bg [expr {1 - $a}]]
			lappend slices $v
			$im copy $v -compositingrule overlay
		}
		$C create image [rnd [expr {$x + 2 * $s}]] [rnd [expr {$y + 2 * $s}]] -image $im -anchor nw
	} else {
		$C create image [rnd [expr {$x + ($w - 48) / 2.0}]] [rnd [expr {$y + ($h - 48) / 2.0}]] \
			-image [theme::icon [dict get $g icon] 48 1.6 [mix $bg $c(MUTED) $a]] -anchor nw
	}
	if {$kind eq "shrink"} {
		set ink [mix $bg $c(MUTED) $a]
		labelrow $C $x [expr {$y + $h + 10}] $w [dict get $g icon] [dict get $g label] [dict get $g tag] 0 \
			$ink [mix $bg $c(PILL) $a] $ink $bg
	}
}

# A translucent photo, all pixels BG at ALPHA (0 to 1): a PNG made here, so Tk can composite it.
proc alttab::veil {w h colour alpha} {
	set r [scan [string range $colour 1 2] %x]
	set g [scan [string range $colour 3 4] %x]
	set b [scan [string range $colour 5 6] %x]
	set al [expr {int(round(255 * $alpha))}]
	set px [binary format c4 [list $r $g $b $al]]
	set row "[binary format c 0][string repeat $px $w]"
	set raw [string repeat $row $h]
	set png "\x89PNG\r\n\x1a\n"
	append png [veil_chunk IHDR [binary format I2c5 [list $w $h] {8 6 0 0 0}]]
	append png [veil_chunk IDAT [zlib compress $raw]]
	append png [veil_chunk IEND {}]
	return [image create photo -data [binary encode base64 $png] -format png]
}

proc alttab::veil_chunk {type data} {
	return [binary format I [string length $data]]$type$data[binary format I [zlib crc32 $type$data]]
}

# Paint rows Y0..Y1 of the screen back over the cards: a slice of the still, or the flat colour.
proc alttab::cover {C y0 y1 flat} {
	variable bg; variable scr; variable slices
	lassign $scr W H
	if {$y1 <= $y0} return
	if {$bg eq ""} {
		$C create rectangle 0 $y0 $W $y1 -fill $flat -outline ""
		return
	}
	set sl [image create photo]
	$sl copy $bg -from 0 $y0 $W $y1 -to 0 0
	lappend slices $sl
	$C create image 0 $y0 -image $sl -anchor nw
}

# The still's average colour along row Y (the fade between the cards and the cut).
proc alttab::bgmean {y flat} {
	variable bg; variable scr
	if {$bg eq ""} { return $flat }
	lassign $scr W H
	set r 0; set g 0; set b 0; set n 0
	for {set x 0} {$x < $W} {incr x 90} {
		lassign [$bg get $x [expr {max(0, min($H - 1, $y))}]] pr pg pb
		incr r $pr; incr g $pg; incr b $pb; incr n
	}
	format #%02X%02X%02X [expr {$r / $n}] [expr {$g / $n}] [expr {$b / $n}]
}

proc alttab::seq_ {n} { set out {}; for {set i 0} {$i < $n} {incr i} { lappend out $i }; return $out }

# One frame timer for every motion: the scroll, the re-fit, the ghosts. It stops when none is left.
proc alttab::kick {} {
	variable anim
	if {!$anim} { set anim 1; after 0 alttab::animate }
}

proc alttab::animate {} {
	variable anim; variable on; variable shown; variable ghosts; variable snap; variable snap_t0
	variable snap_delay; variable snap_dur; variable pos_t0
	set anim 0
	if {!$on} return
	set t [now]
	set keep {}
	foreach g $ghosts { if {$t - [dict get $g t0] < [dict get $g dur]} { lappend keep $g } }
	set ghosts $keep
	if {$snap ne "" && $t >= $snap_t0 + $snap_delay + $snap_dur} { set snap {} }
	set busy [expr {[llength $ghosts] > 0 || $snap ne "" || $t < $pos_t0 + 160}]
	if {$shown} draw
	if {$busy} { set anim 1; after 33 alttab::animate }
}

# ---- the helper ---------------------------------------------------------

# ribbon-shell-switch, started when the switcher is first asked for and quit after a minute idle. Its
# events (shell-watch/switch.c): hello, ready, lost, altup, key NAME, shot FILE W H|fail, cap ID ok W H|fail.
proc alttab::hstart {} {
	variable h; variable hcaps
	if {$h ne ""} return
	set exe [expr {[info exists ::env(RIBBON_SWITCH_HELPER)] ? $::env(RIBBON_SWITCH_HELPER) : "ribbon-shell-switch"}]
	if {[catch {::open |[list $exe 2>@stderr] r+} h]} { set h ""; return }
	set hcaps {}
	fconfigure $h -blocking 0 -buffering line -encoding utf-8 -translation lf
	fileevent $h readable alttab::hread
}

proc alttab::hsend {line} {
	variable h
	if {$h ne ""} { catch {puts $h $line; flush $h} }
}

proc alttab::hstop {} {
	variable h; variable hidle
	after cancel $hidle
	if {$h eq ""} return
	catch {puts $h quit; flush $h}
	catch {::close $h}
	set h ""
}

proc alttab::hread {} {
	variable h
	while {[gets $h line] >= 0} {
		set w [split $line " "]
		probe ev-[lindex $w 0]
		switch -- [lindex $w 0] {
			hello { hsend caps }
			caps { variable hcaps; set hcaps [lrange $w 1 end] }
			altup { altup }
			key { key [lindex $w 1] }
			lost { lost }
			shot { got_shot [lindex $w 1] [lrange $w 2 end] }
			cap { got_cap [lindex $w 1] [lrange $w 2 end] }
		}
	}
	if {[eof $h]} { catch {::close $h}; set h ""; lost }
}

# ---- the still behind the cards ------------------------------------------

# The helper copies the screen as the key goes down, before anything of ours is on it: the main display, the
# output the switcher covers (display::main), at its logical width (a scaled output has more pixels than the
# switcher's canvas). With no output known (plain X) the helper's first output, as it is.
proc alttab::take_shot {} {
	variable seq; variable shotpend
	set shotpend 1
	set over [expr {$::wm::focus ne "" && [wm::has $::wm::focus full]}]
	hsend [shot_cmd [shell::runtime]/alttab-bg.ppm [expr {$over ? 70 : 35}]]
}
proc alttab::shot_cmd {file desat} {
	set name [display::main]
	if {$name eq ""} { return "shot $file $desat" }
	return "shot $file $desat $name [lindex [display::rect] 2]"
}

proc alttab::got_shot {file res} {
	variable on; variable bg; variable shown; variable shotpend; variable prep
	set shotpend 0
	if {[lindex $res 0] eq "fail" || !$on || ![file exists $file]} { catch {file delete $file}; return }
	set over [expr {$::wm::focus ne "" && [wm::has $::wm::focus full]}]
	probe shot-read
	set src [image create photo -file $file]
	catch {file delete $file}
	probe shot-loaded
	set dst [image create photo]
	if {[catch {rbn::blur $src $dst 16 -dim [expr {$over ? 45 : 42}]}]} {
		image delete $dst
	} else {
		if {$bg ne ""} { catch {image delete $bg} }
		set bg $dst
	}
	image delete $src
	probe blurred
	if {$shown || $prep} draw
}

# ---- the windows' pictures ----------------------------------------------------

# Corners outside a circle of radius R are made see-through, so the picture sits in the card's round box.
proc alttab::round {ph w h r} {
	foreach {cx cy sx sy} [list $r $r 0 0  [expr {$w - $r}] $r [expr {$w - $r}] 0  $r [expr {$h - $r}] 0 [expr {$h - $r}]  [expr {$w - $r}] [expr {$h - $r}] [expr {$w - $r}] [expr {$h - $r}]] {
		for {set dy 0} {$dy < $r} {incr dy} {
			for {set dx 0} {$dx < $r} {incr dx} {
				set x [expr {$sx + $dx}]; set y [expr {$sy + $dy}]
				set ddx [expr {$x + 0.5 - $cx}]; set ddy [expr {$y + 0.5 - $cy}]
				if {$ddx * $ddx + $ddy * $ddy > $r * $r} { $ph transparency set $x $y 1 }
			}
		}
	}
}

# Ask for the picture of every window a card on screen shows, once the last answer is in. The helper scales to the
# card's width; Tk cuts it at the card's foot. Only where the compositor offers window copies.
proc alttab::tick {} {
	variable on; variable shown; variable want; variable inflight; variable hcaps; variable apps; variable prep
	after cancel alttab::tick
	if {!$on || !($shown || $prep) || "cap" ni $hcaps} return
	foreach item $want {
		lassign $item id w
		if {$id in $inflight || ![info exists ::wm::tl($id)]} continue
		lappend inflight $id
		hsend "cap $id $w [shell::runtime]/alttab-cap-$id.ppm [wm::get $id app]\t[string map {\t { } \n { }} [wm::get $id title]]"
	}
	after 200 alttab::tick
}

proc alttab::got_cap {id res} {
	variable on; variable shown; variable ph; variable phw; variable inflight; variable want; variable prep
	set inflight [lsearch -all -inline -not -exact $inflight $id]
	set file [shell::runtime]/alttab-cap-$id.ppm
	if {!$on || [lindex $res 0] ne "ok" || ![file exists $file]} { catch {file delete $file}; return }
	set cw 0
	foreach item $want { if {[lindex $item 0] eq $id} { set cw [lindex $item 1] } }
	if {$cw == 0} { catch {file delete $file}; return }
	set ch [expr {int($cw / 1.6) - 0}]
	if {[catch {
		set raw [image create photo -file $file]
		# a copy made at another width is replaced
		if {[info exists ph($id)] && $phw($id) != $cw} { catch {image delete $ph($id)}; unset ph($id) }
		set new [expr {![info exists ph($id)]}]
		if {$new} { set ph($id) [image create photo -width $cw -height $ch]; set phw($id) $cw }
		set sh [expr {min($ch, [image height $raw])}]
		$ph($id) blank
		$ph($id) copy $raw -from 0 0 $cw $sh -to 0 0
		image delete $raw
		round $ph($id) $cw $ch 10
	}]} { catch {file delete $file}; return }
	catch {file delete $file}
	probe cap-$id
	if {$shown || $prep} draw
}

# ---- opening, stepping and the verb -----------------------------------

# Start. HOLD: Alt is down (a key bind), so a tap switches without showing anything and the switcher
# stays until Alt is let go; otherwise it is up until `close`.
proc alttab::open {{hold 0}} {
	variable on; variable apps; variable sel; variable first; variable fan
	variable fanwin; variable tapms; variable shown; variable bg; variable h
	variable pos_from; variable pos_t0; variable closing; variable ghosts; variable snap
	variable revealms; variable t_open
	if {$on} return
	probe open
	set apps [collect]
	set sel [expr {[llength $apps] > 1 ? 1 : 0}]
	set first 0; set fan 0; set fanwin 1
	set pos_from 0; set pos_t0 0
	set closing {}; set ghosts {}; set snap {}
	if {[llength $apps] == 0} return
	set on 1; set shown 0
	if {$hold} { hstart }
	probe helper-up
	if {$hold && $h ne ""} {
		set t_open [now]
		take_shot
		hsend grab
		if {[catch prepare err]} { probe "prepare-failed:[string map {{ } _} $err]" }
		after $revealms alttab::reveal
	} else {
		reveal
	}
}

# Build the surface (once; `warm` does it at start-up) and size it to the main display.
proc alttab::build {} {
	variable canvas; variable scr; variable org
	if {$canvas eq ""} {
		rbn::surface .alttab -class RibbonShellSwitcher -fill $::theme::c(BAR)
		set canvas .alttab.c
		bind $canvas <Button-1> {alttab::click %x %y}
	}
	lassign [display::rect] X Y W H
	set scr [list $W $H]
	set org [list $X $Y]
	$canvas configure -width $W -height $H
}

# While the tap window runs (and the still is on its way) draw the first frame on the unmapped surface and ask
# for the window copies, so that the reveal is only a map and the pictures are already in or close behind.
proc alttab::prepare {} {
	variable prep
	build
	set prep 1
	draw
	tick
	probe prepared
}

# Put the switcher on screen. The surface is withdrawn and mapped afresh: under labwc the stacking of
# override-redirect X windows follows the order they were mapped in (a raise does nothing), so this is what
# puts it above the bar and dock, which were mapped first. It waits (inside the tap window) for the still, so
# the first frame is not the flat scrim.
proc alttab::reveal {} {
	variable on; variable canvas; variable scr; variable shown; variable prep; variable shotpend
	variable t_open; variable tapms; variable org
	after cancel alttab::reveal
	if {!$on || $shown} return
	if {$shotpend && [now] - $t_open < $tapms} { after 10 alttab::reveal; return }
	probe reveal
	build
	lassign $scr W H
	rbn::hide .alttab
	rbn::show .alttab {*}$org $W $H -raise 1
	set wasprep $prep
	set shown 1; set prep 0
	probe mapped
	if {!$wasprep} { draw; tick }
	probe drawn
	if {[info exists ::env(RIBBON_ALTTAB_PROBE)]} { ::update idletasks; probe flushed }
}

# Start-up: the helper running and the surface built, so the first Alt+Tab is no slower than the rest.
proc alttab::warm {} {
	variable on
	if {[info exists ::env(RIBBON_ALTTAB_NOWARM)] || ![info exists ::env(WAYLAND_DISPLAY)]} return
	catch {hstart}
	catch {build}
}

proc alttab::close {} {
	variable on; variable canvas; variable shown; variable bg; variable ph; variable phw; variable inflight; variable hidle
	variable slices; variable closing; variable ghosts; variable snap; variable rects; variable hits; variable pollid
	variable anim; variable prep; variable shotpend
	after cancel alttab::reveal
	after cancel alttab::tick
	after cancel alttab::animate
	if {$pollid ne ""} { after cancel $pollid; set pollid "" }
	if {!$on} return
	set on 0; set shown 0; set anim 0; set prep 0; set shotpend 0
	hsend release
	rbn::hide .alttab
	if {$canvas ne ""} { $canvas delete all }
	foreach sl $slices { catch {image delete $sl} }
	set slices {}
	if {$bg ne ""} { catch {image delete $bg}; set bg "" }
	foreach id [array names ph] { catch {image delete $ph($id)} }
	array unset ph
	array unset phw
	set inflight {}
	set closing {}; set ghosts {}; set snap {}; set rects {}; set hits {}
	foreach f [glob -nocomplain -directory [shell::runtime] alttab-*.ppm] { catch {file delete $f} }
	# the helper stays up (1 MB; no surface while idle), so the next open has no start-up to pay
}

# The window Alt release (or Return) switches to: the chosen app's front window, or the chosen one in a well.
proc alttab::target {} {
	variable apps; variable sel; variable fan; variable fanwin
	if {[llength $apps] == 0} { return "" }
	set ids [dict get [lindex $apps $sel] ids]
	lindex $ids [expr {$fan && [llength $ids] > 1 ? $fanwin : 0}]
}

proc alttab::finish {activate} {
	set id [target]
	close
	if {$activate && $id ne ""} {
		if {[wm::has $id min]} { wm::send "unminimize $id" }
		wm::send "activate $id"
	}
}

# Go to app I (arrows: no wrap).
proc alttab::goto {i} {
	variable apps; variable sel; variable fan; variable fanwin
	set n [llength $apps]
	if {$n == 0} return
	set fan 0; set fanwin 1
	set sel [expr {max(0, min($n - 1, $i))}]
	draw
}

# Step the choice; Tab-like, app by app, wrapping to the first and back to the top.
proc alttab::step {dir} {
	variable apps; variable sel; variable fan; variable fanwin
	set n [llength $apps]
	if {$n == 0} return
	set fan 0; set fanwin 1
	set sel [expr {($sel + $dir + $n) % $n}]
	if {$sel == 0 && $dir > 0 || $sel == $n - 1 && $dir < 0} { setfirst 0 }
	draw
}

# ` opens the chosen stack's well, on its second window.
proc alttab::fan {} {
	variable apps; variable sel; variable fan; variable fanwin
	if {[llength $apps] == 0 || [llength [dict get [lindex $apps $sel] ids]] < 2} return
	set fan 1; set fanwin 1
	draw
}

# Move inside the well, window by window, wrapping.
proc alttab::fanstep {dir} {
	variable apps; variable sel; variable fanwin
	set k [llength [dict get [lindex $apps $sel] ids]]
	set fanwin [expr {($fanwin + $dir + $k) % $k}]
	draw
}

# Arrow moves on the grid: ↓ into a short last row goes to the last card.
proc alttab::move {dx dy} {
	variable apps; variable sel
	set n [llength $apps]
	set cols [dict get [shape $n] cols]
	if {$dx != 0} { goto [expr {$sel + $dx}]; return }
	set to [expr {$sel + $dy * $cols}]
	if {$to < 0} return
	if {$to >= $n} { if {$sel / $cols == ($n - 1) / $cols} return; set to [expr {$n - 1}] }
	goto $to
}

# Close one window (W) or the whole app (Q). The picture leaves at once, the cards behind close up after
# it, and the windows are polled: one still there after pollfor ms asked to stay, so its card stays.
proc alttab::kill {what} {
	variable apps; variable sel; variable fan; variable fanwin; variable closing; variable rects; variable pollfor
	if {[llength $apps] == 0} return
	set app [lindex $apps $sel]
	set ids [dict get $app ids]
	set key "a:[dict get $app app]"
	set front [lindex $ids 0]
	set icon [apps::iconfor [apps::forwindow [dict get $app app]] [dict get $app app]]
	set count [llength $ids]
	if {$what eq "window"} {
		set j [expr {$fan && [llength $ids] > 1 ? $fanwin : 0}]
		set id [lindex $ids $j]
		set inwell [expr {$fan && $count > 1}]
		# W on a stack: the front lifts and the card keeps its place. In a well, or the last window, the card is re-fitted
		if {$inwell} {
			set src "w:$id"
			set kind fade
		} else {
			set src $key
			set kind lift
		}
		if {[dict exists $rects $src]} {
			leave $kind [dict get $rects $src] [dict create id $id icon $icon]
		}
		wm::send "close $id"
		set gone [list $id]
		set ids [lsearch -all -inline -not -exact $ids $id]
		if {$inwell || [llength $ids] == 0} { relayout 140 }
	} else {
		if {[dict exists $rects $key]} {
			leave shrink [dict get $rects $key] [dict create id $front icon $icon label [dict get $app label] \
				tag [tagtext $front $count]]
		}
		foreach id $ids { wm::send "close $id" }
		set gone $ids
		set ids {}
		relayout 140
	}
	set closing [concat $closing $gone]
	if {[llength $ids] == 0} {
		set apps [lreplace $apps $sel $sel]
		set fan 0; set fanwin 1
		if {[llength $apps] == 0} { close; return }
		set sel [expr {min($sel, [llength $apps] - 1)}]
	} else {
		lset apps $sel [dict replace $app ids $ids]
		if {[llength $ids] < 2} { set fan 0 }
		set fanwin [expr {min($fanwin, [llength $ids] - 1)}]
	}
	poll [expr {[now] + $pollfor}]
	draw
	kick
}

# Wait for the closed windows to be gone. Those still listed when the time is up asked to stay (a save prompt)
# and come back with their card; the rest leave the list.
proc alttab::poll {until} {
	variable on; variable closing; variable pollid; variable pollfor
	set pollid ""
	if {!$on || [llength $closing] == 0} return
	set left {}
	foreach id $closing { if {[info exists ::wm::tl($id)]} { lappend left $id } }
	if {[llength $left] && [now] < $until} {
		set pollid [after 40 [list alttab::poll $until]]
		return
	}
	set closing {}
	if {[llength $left]} {
		relayout 0
		refresh
	}
	draw
	kick
}

# The app list again from the windows that are still there, the chosen app kept (or its index, when it has gone).
proc alttab::refresh {} {
	variable apps; variable sel; variable fan; variable fanwin
	set label ""
	if {[llength $apps]} { set label [dict get [lindex $apps $sel] app] }
	set apps [collect]
	set n [llength $apps]
	if {$n == 0} { set sel 0; set fan 0; set fanwin 1; return }
	set sel [expr {min($sel, $n - 1)}]
	set i 0
	foreach a $apps {
		if {[dict get $a app] eq $label} { set sel $i; break }
		incr i
	}
	set k [llength [dict get [lindex $apps $sel] ids]]
	if {$k < 2} { set fan 0 }
	set fanwin [expr {min($fanwin, $k - 1)}]
}

# A click: a card goes to its window (or the well's window), an arrow moves the grid one line.
proc alttab::click {x y} {
	variable hits; variable first
	foreach hit [lreverse $hits] {
		lassign $hit hx hy hw hh what arg
		if {$x < $hx || $x >= $hx + $hw || $y < $hy || $y >= $hy + $hh} continue
		switch -- $what {
			card { goto $arg; finish 1 }
			well { set ::alttab::fanwin $arg; finish 1 }
			arrow { setfirst [expr {$first + $arg}]; draw }
		}
		return
	}
}

# ---- what the helper and the binds say ---------------------------------------

proc alttab::altup {} {
	variable on
	if {$on} { finish 1 }
}

proc alttab::lost {} {
	variable on
	if {$on} { finish 0 }
}

proc alttab::key {name} {
	variable on; variable fan; variable shown
	if {!$on} return
	if {!$shown} reveal
	switch -- $name {
		tab { if {$fan} { set fan 0 }; step 1 }
		btab { if {$fan} { set fan 0 }; step -1 }
		left { if {$fan} { fanstep -1 } else { move -1 0 } }
		right { if {$fan} { fanstep 1 } else { move 1 0 } }
		up { if {$fan} { set fan 0; draw } else { move 0 -1 } }
		down { if {$fan} { set fan 0; draw } else { move 0 1 } }
		grave { if {$fan} { fanstep 1 } else { fan } }
		w { kill window }
		q { kill app }
		esc { if {$fan} { set fan 0; draw } else { finish 0 } }
		enter { finish 1 }
	}
}

# Alt+Tab, Alt+Shift+Tab and Alt+` as labwc passes them on (it consumes a bound key, so the helper
# never sees these three while Alt is down).
proc alttab::hotkey {how} {
	variable on; variable shown
	if {!$on} {
		open 1
		if {!$on} return
		switch -- $how {
			prev { set ::alttab::sel 0; step -1 }
			app { set ::alttab::sel 0; fan }
		}
		return
	}
	if {!$shown} reveal
	switch -- $how {
		next { key tab }
		prev { key btab }
		app { key grave }
	}
}

proc alttab::verb {{cmd open} args} {
	variable on
	switch -- $cmd {
		open { open }
		next - prev - app { hotkey $cmd }
		fan { if {$on} fan }
		close { close }
	}
}

shell::verb switcher alttab::verb

after 1500 alttab::warm
