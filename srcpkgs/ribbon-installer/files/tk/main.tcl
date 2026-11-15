# main.tcl - the Ribbon installer: a Tcl/Tk front end for ribbon-install.
#
# Run as you (not root): wish /usr/lib/ribbon/installer/main.tcl
# The backend runs as root through sudo or pkexec (backend.tcl).
#
# It draws with the Ribbon shell's own rasteriser and palette
# (raster.tcl, theme.tcl, wall.tcl from /usr/lib/ribbon/shell), so it
# follows the active Ribbon scheme exactly as the bars do.
#
# Tests: RIBBON_INSTALLER_SCENE=tests/installer-scene.tcl puts it into one
# of the mockups' states on a desktop the size of the screen (see that file):
# 1440 x 900 for the Inst-* boards, 1366 x 768 or 1280 x 800 for Inst-C*.

set dir [file dirname [file normalize [info script]]]
set shell ""
foreach d [list [expr {[info exists env(RIBBON_SHELL_DIR)] ? $env(RIBBON_SHELL_DIR) : ""}] /usr/lib/ribbon/shell \
		[file join $dir .. .. .. ribbon-desktop files shell]] {
	if {$d ne "" && [file exists [file join $d raster.tcl]]} { set shell $d; break }
}
if {$shell eq ""} { puts stderr "ribbon-installer: the Ribbon shell's raster.tcl was not found"; exit 1 }
# text.tcl first: it gives Tk the font weights the mockups use
# rbnalpha (next to the shell: /usr/lib/ribbon/rbnalpha): see-through
# window corners, and raster.tcl's pixels in C
foreach d [list /usr/lib/ribbon [file dirname $shell]] { if {$d ni $auto_path} { lappend auto_path $d } }
package require rbnalpha
foreach f {text raster wall theme} { source -encoding utf-8 [file join $shell $f.tcl] }
# display.tcl: the outputs (wlr-randr) and the main one, where the bars are
source -encoding utf-8 [file join $shell display.tcl]
foreach f {data ui backend pages} { source -encoding utf-8 [file join $dir $f.tcl] }
# the Ribbon file chooser (ribbon-desktop's appearance/, beside the shell) for the account picture
source -encoding utf-8 [file join [file dirname $shell] appearance chooser.tcl]

namespace eval app {
	variable win .w
	variable scene 0
}

proc app::main {} {
	variable win
	variable scene
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}]
	set cache [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$home/.cache"}]
	theme::load
	raster::init [file join $cache ribbon installer]
	ui::fonts
	ui::colours
	data::load_zones
	set scene [info exists ::env(RIBBON_INSTALLER_SCENE)]
	wm withdraw .
	set SW [winfo screenwidth .]; set SH [winfo screenheight .]
	# the window goes on the main output (the one with the bars), not
	# across all of them; a scene's desktop is the whole screen
	lassign [expr {$scene ? [list 0 0 $SW $SH] : [output]}] OX OY OW OH
	page::layout [page::compact_for $OH]
	set H $ui::H
	page::init
	lassign [place $OW $OH] x y
	incr x $OX; incr y $OY
	if {$scene} {
		# the whole desktop as the mockups show it: wallpaper, shade, the
		# quiet bars, and the window's shadow
		toplevel $win -class RibbonInstaller -borderwidth 0 -highlightthickness 0
		wm overrideredirect $win 1
		wm geometry $win ${SW}x${SH}+0+0
		set ui::ox $x; set ui::oy $y
		set ui::behind [desktop $SW $SH $x $y]
		set ui::bx $x; set ui::by $y
		canvas $win.c -width $SW -height $SH -highlightthickness 0 -borderwidth 0 -background $ui::c(bar)
		$win.c create image 0 0 -image $ui::behind -anchor nw -tags desk
	} else {
		# a plain managed window (labwc draws no title bar for it: a window
		# rule for RibbonInstaller); see-through rounded corners
		# its rounded corners are see-through (rbnalpha: an ARGB window)
		# its rule keeps the server decoration off: it draws its own frame
		# narrower than 1100 (place's x is then negative): the window is
		# the output's width and shows the page's right side, Continue
		# included; the rail's left is cut (ui::cut)
		set ww 1100
		if {$x < $OX} { set ui::cut [expr {$OX - $x}]; set ww [expr {1100 - $ui::cut}]; set ui::ox [expr {-$ui::cut}]; set x $OX }
		if {[rbn::appwindow $win RibbonInstaller $ww $H -fill $ui::c(bar) -ownframe 1]} { set ui::argbwin $win }
		wm title $win "Install Ribbon"
		wm resizable $win 0 0
		wm geometry $win ${ww}x$H+$x+$y
		set ui::behind ""
		set ui::bx 0; set ui::by 0
	}
	wm protocol $win WM_DELETE_WINDOW app::close_window
	pack $win.c
	set ui::cv $win.c
	bind $win.c <ButtonPress-1> {ui::press %x %y}
	bind $win.c <B1-Motion> {ui::motion %x %y}
	bind $win.c <ButtonRelease-1> {ui::release %x %y}
	bind $win.c <Button-4> {ui::scroll %x %y -1}
	bind $win.c <Button-5> {ui::scroll %x %y 1}
	bind $win.c <MouseWheel> {ui::scroll %x %y [expr {%D > 0 ? -1 : 1}]}
	bind $win <KeyPress> {page::key %K %A %s}
	if {$scene} {
		uplevel #0 [list source -encoding utf-8 $::env(RIBBON_INSTALLER_SCENE)]
	} else {
		page::draw
		backend::start_probe page::probed page::probe_failed
	}
	focus -force $win
	ui::blink
}

# The main output's {x y w h} in X coordinates (display.tcl: the output
# the bars are on, from wlr-randr; the whole screen when the outputs are
# not known, as under plain X).
proc app::output {} {
	if {[catch {display::rect} r] || [llength $r] != 4} { return [list 0 0 [winfo screenwidth .] [winfo screenheight .]] }
	return $r
}

# Where the window goes on an output of SW x SH, between the top bars and
# the dock (labwc's <margin top="54" bottom="54">): 1440 x 900 puts the
# 720 px window at 170, 104 as on the Inst-* boards; the compact 640 px one
# is centred, 133, 64 at 1366 x 768 and 90, 80 at 1280 x 800 (Inst-C*).
# A screen under 748 px high has no room for it between the margins: it
# stays clear of the top bars and runs into the dock's margin (Continue is
# at the right, clear of the dock), and only under 694 px does it move up
# to keep the footer on screen. Narrower than 1100 px, its right edge (and
# so Continue) stays on screen and the rail's left runs off it.
proc app::place {SW SH} {
	set H $ui::H
	set x [expr {$SW >= 1100 ? ($SW - 1100) / 2 : $SW - 1100}]
	if {$H == 720} {
		set y [expr {max(54, min(($SH - 720) / 2 + 14, $SH - 54 - 720))}]
	} else {
		set y [expr {max(54, ($SH - $H) / 2)}]
		if {$y + $H > $SH} { set y [expr {max(0, $SH - $H)}] }
	}
	list $x $y
}

# The window's close button (and Alt+F4): quit, except while the install
# runs: closing then would stop the install half done, so a sheet asks
# first (Inst-14b), Keep installing being its default.
proc app::close_window {} {
	if {$page::S(page) eq "progress" && !$page::S(done) && $page::S(err) eq ""} { page::close_ask; return }
	exit 0
}

# The scene's desktop: wallpaper, a 25% shade, the bars at 55% and the
# window's shadow (0 30px 80px rgba(0,0,0,0.55)), cached per palette. The
# window is at X, Y; with the compact window (a small screen) the dock is
# there too, as on the Inst-C* boards.
proc app::desktop {W H X Y} {
	array set c [array get ui::c]
	set WH $ui::H
	set dock [expr {$WH != 720}]
	set f [file join $raster::cachedir desk-[format %08x [zlib crc32 [list 4 [array get theme::c] $W $H $X $Y $WH]]].png]
	if {[file exists $f]} { return [image create photo -file $f -format png] }
	set rows [wall::rows [array get theme::c] 0 0 $W $H $W $H]
	set k [expr {1.0 / (80 / 2.0 * sqrt(2.0))}]
	set fx {}; set fy {}
	for {set x 0} {$x < $W} {incr x} { lappend fx [expr {0.5 * ([raster::erf [expr {($x + 0.5 - $X) * $k}]] - [raster::erf [expr {($x + 0.5 - $X - 1100) * $k}]])}] }
	for {set y 0} {$y < $H} {incr y} { lappend fy [expr {0.5 * ([raster::erf [expr {($y + 0.5 - 30 - $Y) * $k}]] - [raster::erf [expr {($y + 0.5 - 30 - $Y - $WH) * $k}]])}] }
	set out {}
	for {set y 0} {$y < $H} {incr y} {
		set sy [expr {0.55 * [lindex $fy $y]}]
		set new {}
		foreach {r g b a} [lindex $rows $y] s0 $fx {
			set m [expr {0.75 * (1 - $sy * $s0)}]
			lappend new [expr {int($r * $m + 0.5)}] [expr {int($g * $m + 0.5)}] [expr {int($b * $m + 0.5)}] 255
		}
		lappend out $new
	}
	set P [image create photo -data [raster::png $W $H $out] -format png]
	# the bars, drawn at full strength on a copy, then mixed in at 55%:
	# {x y w} of each bar, and the regions {x0 y0 x1 y1} they and their
	# shadows cover
	set bars [list 8 8 330 [expr {$W - 308}] 8 300]
	set regions [list 0 0 370 70 [expr {$W - 340}] 0 $W 70]
	set dx [expr {($W - 150) / 2}]
	if {$dock} {
		lappend bars $dx [expr {$H - 46}] 150
		lappend regions [expr {$dx - 32}] [expr {$H - 70}] [expr {$dx + 182}] $H
	}
	set Q [image create photo -width $W -height $H]
	$Q copy $P
	foreach {x y w} $bars {
		lassign [raster::rrect $w 38 -fill $c(bar) -radius 12 -ring [list $c(border) 1] -shadow {6 20 0.35}] img padx pady
		raster::blit $Q $img 0 0 [image width $img] [image height $img] [expr {$x - $padx}] [expr {$y - $pady}]
	}
	raster::box $Q 12 12 86 30 -fill $c(pill) -radius 8
	raster::box $Q 102 12 232 30 -fill $c(field) -radius 8
	if {$dock} { raster::box $Q [expr {$dx + 4}] [expr {$H - 42}] 142 30 -fill $c(field) -radius 8 }
	foreach {x0 y0 x1 y1} $regions {
		set x0 [expr {max(0, $x0)}]; set x1 [expr {min($W, $x1)}]
		for {set y $y0} {$y < $y1} {incr y} {
			set row {}
			for {set x $x0} {$x < $x1} {incr x} {
				lassign [$P get $x $y] r1 g1 b1; lassign [$Q get $x $y] r2 g2 b2
				lappend row [format #%02x%02x%02x [expr {round($r1 + ($r2 - $r1) * 0.55)}] [expr {round($g1 + ($g2 - $g1) * 0.55)}] [expr {round($b1 + ($b2 - $b1) * 0.55)}]]
			}
			$P put [list $row] -to $x0 $y
		}
	}
	image delete $Q
	$P write $f.[pid] -format png
	file rename -force $f.[pid] $f
	return $P
}

app::main
