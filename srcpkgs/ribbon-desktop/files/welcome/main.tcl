# main.tcl - the first-login welcome (ribbon-welcome): the few choices worth
# making once, drawn to the Welcome-* boards (design/tools/gen_welcome.py): a
# 440 x 368 dialog with the sheet's anatomy (STYLE.md §15), on the shell's
# rasteriser, palette and text code and Appearance's controls (appearance/ui.tcl).
#
#   wish /usr/lib/ribbon/welcome/main.tcl      (ribbon-welcome, from labwc's
#                                                  autostart while welcome-pending exists)
#
# Steps: choose (Welcome-1: four switches), drive (Welcome-2: the free
# partitions), a choice being carried out (Welcome-3: the footer says what),
# note (Welcome-4: what a command answered). The choices: HDR (ribbon-hdr on), a
# games drive (pkexec ribbon-drives add), Flathub (flatpak remote-add --user) and
# a colour scheme (ribbon-theme pick, which opens Appearance). Finishing removes
# ~/.config/ribbon/welcome-pending; Continue through to the end also writes
# welcome-done, so ribbon-firstrun does not ask again ("Not now" and closing the
# window leave it for the next login).
#
# Tests: RIBBON_WELCOME_DRYRUN=FILE writes each command to FILE instead of
# running it; RIBBON_WELCOME_LSBLK=FILE stands in for lsblk's output;
# RIBBON_WELCOME_SCENE=1 draws the window undecorated where the boards put it
# (500,266 on a 1440 x 900 screen); RIBBON_WELCOME_TEST=SCRIPT is sourced once the
# window is up (tests/welcome-flow.tcl, tests/welcome-scene.tcl).

if {$tcl_platform(platform) eq "unix"} { encoding system utf-8 }
set appdir [file dirname [file normalize [info script]]]
proc find_dir {name file} {
	foreach d [list [file join [file dirname $::appdir] $name] /usr/lib/ribbon/$name] {
		if {[file exists [file join $d $file]]} { return $d }
	}
	puts stderr "welcome: $name/$file was not found"; exit 1
}
set shelldir [expr {[info exists env(RIBBON_SHELL_DIR)] ? $env(RIBBON_SHELL_DIR) : [find_dir shell raster.tcl]}]
set appearancedir [find_dir appearance ui.tcl]
# rbnalpha (next to the shell: /usr/lib/ribbon/rbnalpha): see-through window corners
foreach d [list /usr/lib/ribbon [file dirname $shelldir]] { if {$d ni $auto_path} { lappend auto_path $d } }
package require rbnalpha
# text.tcl first: it sets up the fonts' weights before Tk opens a font
foreach f {text raster wall theme} { source -encoding utf-8 [file join $shelldir $f.tcl] }
namespace eval page {}
source -encoding utf-8 [file join $appearancedir ui.tcl]
# what the boards use beyond Appearance's set: the dialog title's face and the rows' icons
set ui::fonts(sg20) {{Ribbon Space Grotesk 600} 20 0.984 0.292}
array set ui::paths {
	sun     {M12 17a5 5 0 1 0 0-10a5 5 0 1 0 0 10z M12 1v2 M12 21v2 M4.22 4.22l1.42 1.42 M18.36 18.36l1.42 1.42 M1 12h2 M21 12h2 M4.22 19.78l1.42-1.42 M18.36 5.64l1.42-1.42}
	disk    {M22 12H2 M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z M6 16h.01 M10 16h.01}
	box     {M21 16V8l-9-5-9 5v8l9 5 9-5z M3.3 7L12 12l8.7-5 M12 22V12}
	sparkle {M12 3l1.9 5.8L20 10l-6.1 1.2L12 17l-1.9-5.8L4 10l6.1-1.2z}
	arrow   {M5 12h14 M12 5l7 7-7 7}
}

namespace eval page {
	variable W 440
	variable H 368             ;# 88 head + 208 body + 72 footer, on every step
	variable step choose       ;# choose | drive | note
	variable pick              ;# the choices
	array set pick {hdr 0 drives 0 flathub 1 scheme 1}
	variable rows {
		hdr     {sun     "Turn on HDR"}
		drives  {disk    "Mount a games drive at every boot"}
		flathub {box     "Enable Flathub"}
		scheme  {palette "Choose a colour scheme"}
	}
	variable parts {}          ;# {device name details} for the drive step
	variable part ""           ;# the chosen device
	variable top 0             ;# the first partition shown (five fit)
	variable note {}           ;# {icon title line text} for the note step
	variable queue {}          ;# choices still to do
	variable busy ""           ;# what is being done (the footer's status), "" when idle
	variable pending ""
	variable who ""
}

proc page::env {name {default ""}} {
	expr {[info exists ::env($name)] ? $::env($name) : $default}
}

proc page::cfgdir {} {
	file join [env XDG_CONFIG_HOME [file join [env HOME /] .config]] ribbon
}

# The header's line on the choose step: your name (the account's full name, else
# its login) and the computer's.
proc page::who {} {
	variable who
	if {$who ne ""} { return $who }
	set login [env USER [env LOGNAME]]
	if {$login eq "" && [catch {exec id -un} login]} { set login "" }
	set name ""
	if {$login ne "" && ![catch {exec getent passwd $login} pw]} {
		set name [string trim [lindex [split [lindex [split $pw :] 4] ,] 0]]
	}
	if {$name eq ""} { set name $login }
	set host [lindex [split [info hostname] .] 0]
	set who [join [lmap s [list $name $host] { if {$s eq ""} continue; set s }] " · "]
}

# ---- commands -------------------------------------------------------------------

# Run CMD without stopping the window; return whether it succeeded and what it
# printed (stdout and stderr), less the CLI's colours and "ok"/"warn"/"error"
# marks: {ok text}.
proc page::run {cmd} {
	set dry [env RIBBON_WELCOME_DRYRUN]
	if {$dry ne ""} {
		set fh [::open $dry a]; puts $fh $cmd; ::close $fh
		# a test may stand in for what the command answers (RIBBON_WELCOME_ANSWER_<word>=ok|fail:text)
		set k RIBBON_WELCOME_ANSWER_[string map {- _} [lindex $cmd [expr {[lindex $cmd 0] eq "pkexec" ? 1 : 0}]]]
		set a [env $k]
		if {$a eq ""} { return [list 1 ""] }
		lassign [split $a :] r
		return [list [expr {$r eq "ok"}] [clean [string range $a [string length $r:] end]]]
	}
	if {[catch {::open |[list {*}$cmd 2>@1] r} ch]} { return [list 0 $ch] }
	fconfigure $ch -blocking 0 -encoding utf-8 -translation auto
	set out ""
	fileevent $ch readable [list [info coroutine] more]
	while 1 {
		yield
		append out [read $ch]
		if {[eof $ch]} break
	}
	fconfigure $ch -blocking 1
	set ok [expr {![catch {::close $ch}]}]
	list $ok [clean $out]
}

proc page::clean {text} {
	regsub -all {\x1b\[[0-9;]*[A-Za-z]} $text "" text
	set out {}
	foreach line [split [string trim $text] \n] {
		regsub {^\s*(==>|ok|warn|warning|error):?\s+} $line "" line
		lappend out [string trim $line]
	}
	join $out \n
}

# lsblk's size in the boards' words: 1T -> 1 TB, 931.5G -> 931.5 GB.
proc page::size {s} {
	if {[regexp {^([0-9.,]+)([KMGTPE])$} $s - n u]} { return "$n ${u}B" }
	return $s
}

# Partitions that aren't mounted and hold a filesystem ribbon-drives mounts
# (not swap, LUKS, or an LVM / RAID / ZFS member, which look unmounted too):
# {device name details}, the name being the label (the device without one).
proc page::partitions {} {
	set f [env RIBBON_WELCOME_LSBLK]
	if {$f ne ""} {
		set fh [::open $f]; set text [read $fh]; ::close $fh
	} elseif {[catch {exec lsblk -rpno NAME,TYPE,FSTYPE,SIZE,LABEL,MOUNTPOINTS} text]} {
		return {}
	}
	set out {}
	foreach line [split $text \n] {
		lassign [split $line " "] dev type fs size label mnt
		if {$type ne "part" || $fs ni {ext4 xfs f2fs btrfs ntfs ntfs3 exfat vfat} || $mnt ne ""} continue
		# lsblk -r writes spaces and other bytes in labels as \xNN
		set label [string trim [subst -nocommands -novariables [string map {\\x \\u00} $label]]]
		set bits [list $fs [size $size]]
		if {$label ne ""} {
			lappend out [list $dev $label [join [list $dev {*}$bits] " · "]]
		} else {
			lappend out [list $dev $dev [join $bits " · "]]
		}
	}
	return $out
}

# ---- the steps ------------------------------------------------------------------

proc page::toggle {k} {
	variable pick
	if {[set ::page::busy] ne ""} return
	set pick($k) [expr {!$pick($k)}]
	draw
}

proc page::cont {} {
	variable pick
	variable rows
	variable queue
	if {$::page::busy ne "" || $::page::step ne "choose"} return
	set queue {}
	foreach {k -} $rows { if {$pick($k)} { lappend queue $k } }
	coroutine ::page::work page::next
}

proc page::not_now {} {
	if {$::page::busy ne ""} return
	finish 0
}

proc page::show_note {icon title line text} {
	set ::page::note [list $icon $title $line $text]
	set ::page::step note
	draw
}

# Do the queued choices in turn; the drive step and notes wait for a click.
proc page::next {} {
	variable queue
	variable busy
	while {[llength $queue]} {
		set queue [lassign $queue k]
		switch -- $k {
			hdr {
				set busy "Turning on HDR…"; draw
				lassign [run {ribbon-hdr on}] ok text
				set busy ""
				if {!$ok || $text ne ""} {
					show_note sun HDR [expr {$ok ? "Turned on" : "Not turned on"}] $text
					return
				}
				draw
			}
			drives {
				set ::page::parts [partitions]
				if {![llength $::page::parts]} {
					show_note disk "Games drive" "No free partition" ""
					return
				}
				set ::page::part [lindex $::page::parts 0 0]
				set ::page::top 0
				set ::page::step drive
				draw
				return
			}
			flathub {
				set busy "Adding Flathub…"; draw
				lassign [run {flatpak remote-add --user --if-not-exists flathub /usr/share/ribbon/flatpak/flathub.flatpakrepo}] ok text
				set busy ""
				if {!$ok} {
					show_note box Flathub "Not enabled" $text
					return
				}
				draw
			}
			scheme {
				if {[env RIBBON_WELCOME_DRYRUN] ne ""} {
					run {ribbon-theme pick}
				} else {
					catch {exec ribbon-theme pick >/dev/null 2>@1 &}
				}
			}
		}
	}
	finish 1
}

# The drive step's Mount.
proc page::mount {} {
	variable part
	if {$::page::busy ne "" || $::page::step ne "drive" || $part eq ""} return
	coroutine ::page::work apply {{} {
		set name $::page::part
		foreach p $::page::parts { if {[lindex $p 0] eq $::page::part} { set name [lindex $p 1] } }
		set ::page::busy "Mounting $name…"; page::draw
		lassign [page::run [list pkexec ribbon-drives add $::page::part]] ok text
		set ::page::busy ""
		page::show_note disk "Games drive" [expr {$ok ? "Mounted at every boot" : "Not mounted"}] $text
	}}
}

# Skip (the drive step) and OK (a note): on to the next choice.
proc page::skip {} {
	if {$::page::busy ne "" || $::page::step eq "choose"} return
	set ::page::step choose
	coroutine ::page::work page::next
}

proc page::pick_part {dev} {
	if {$::page::busy ne ""} return
	set ::page::part $dev
	draw
}

# Up/Down on the drive step: the partition above or below, scrolled into view.
proc page::move_part {d} {
	variable parts
	variable top
	if {$::page::busy ne ""} return
	set i [lsearch -exact -index 0 $parts $::page::part]
	set i [expr {max(0, min([llength $parts] - 1, $i + $d))}]
	set ::page::part [lindex $parts $i 0]
	if {$i < $top} { set top $i }
	if {$i >= $top + 5} { set top [expr {$i - 4}] }
	draw
}

proc page::scroll_parts {d} {
	variable top
	set top [expr {max(0, min([llength $::page::parts] - 5, $top + $d))}]
	draw
}

proc page::finish {done} {
	set d [cfgdir]
	file mkdir $d
	file delete [file join $d welcome-pending]
	if {$done} { ::close [::open [file join $d welcome-done] w] }
	exit 0
}

# ---- drawing ------------------------------------------------------------------------

proc page::draw {} {
	variable pending
	if {$pending ne ""} return
	set pending [after idle page::draw_now]
}

# The window: §bar, rounded with a 1 px ring when it draws its own frame
# (labwc's frame is square: then neither).
proc page::frame_boxes {} {
	variable W
	variable H
	array set c [array get ui::c]
	set r [ui::outer_radius 16]
	if {$r > 0} {
		ui::box 0 0 $W $H -fill $c(bar) -radius $r -ring [list $c(border) 1]
	} else {
		ui::box 0 0 $W $H -fill $c(bar)
	}
}

proc page::draw_now {} {
	variable pending ""
	variable step
	ui::begin [list frame $::page::W $::page::H] page::frame_boxes
	draw_$step
	ui::focus_ring
	ui::finish
}

# The header tile: 44 square, radius 12, a 160-degree gradient from §pill to
# §field, a 1 px §border ring (as the password prompt's).
proc page::tile {x y icon} {
	array set c [array get ui::c]
	set g [raster::cached [list welcome-tile [ui::col $c(pill)] [ui::col $c(field)] [ui::col $c(border)]] {
		lassign [raster::rgb [ui::col $c(pill)]] r0 g0 b0
		lassign [raster::rgb [ui::col $c(field)]] r1 g1 b1
		lassign [raster::rgb [ui::col $c(border)]] rr rg rb
		set s 44; set r 12
		set dx 0.3420201433256687; set dy 0.9396926207859084
		set len [expr {$s * $dx + $s * $dy}]
		set out {}
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
			lappend out $row
		}
		raster::png $s $s $out
	}]
	raster::blit $ui::img $g 0 0 44 44 $x $y
	ui::icon $icon 22 $c(fg) [expr {$x + 11}] [expr {$y + 11}] 1.7
}

# Header: the tile, a 20 SG title over a 13 px §muted line, the rule 18 below.
proc page::head {icon title line} {
	array set c [array get ui::c]
	tile 28 26 $icon
	ui::text 86 [ui::lh 27 sg20 23 1] $title sg20 $c(fg) w -0.4
	ui::text 86 53 [ui::clip i13 $line 326] i13 $c(muted)
	ui::hline 28 412 88 $c(border)
}

# Footer: the rule, then the buttons from the right ({id label kind script ?icon?}
# ..., the primary first), or what is being done in the left slot.
proc page::foot {buttons} {
	variable W
	variable H
	array set c [array get ui::c]
	set y [expr {$H - 72}]
	ui::hline 0 $W $y $c(border)
	if {$::page::busy ne ""} {
		ui::text 28 [ui::lh $y i13 72] $::page::busy i13 $c(muted)
		return
	}
	set x [expr {$W - 28}]
	foreach b $buttons {
		lassign $b id label kind script icon
		set w [ui::button_w $label $kind $icon]
		set x [expr {$x - $w}]
		ui::button $id $x [expr {$y + 17}] $label $kind $script $icon $w
		set x [expr {$x - 10}]
	}
}

proc page::draw_choose {} {
	variable rows
	variable pick
	array set c [array get ui::c]
	head sparkle "Welcome to Ribbon" [who]
	set y 96
	set n 0
	foreach {k r} $rows {
		lassign $r icon label
		ui::icon $icon 16 $c(muted) 29 [expr {$y + 16}]
		ui::text 58 [ui::lh $y i13 48] $label i13 $c(fg)
		ui::toggle 374 [expr {$y + 13}] $pick($k)
		if {[incr n] < 4} { ui::hline 28 412 [expr {$y + 47}] $c(border) }
		ui::hit 28 $y 384 48 [list apply {{k x y} { page::toggle $k }} $k]
		ui::focusable $k switch 374 [expr {$y + 13}] 38 22 11 [list page::toggle $k]
		incr y 48
	}
	foot {{go Continue primary page::cont arrow} {later {Not now} ghost page::not_now}}
}

proc page::draw_drive {} {
	variable parts
	variable part
	variable top
	array set c [array get ui::c]
	set n [llength $parts]
	head disk "Games drive" [expr {$n == 1 ? "1 free partition" : "$n free partitions"}]
	set y 96
	foreach p [lrange $parts $top [expr {$top + 4}]] {
		lassign $p dev name details
		set on [expr {$dev eq $part}]
		if {$on} { ui::box 18 $y 404 36 -fill $c(field) -radius 8 }
		set f [expr {$on ? "i14s" : "i14"}]
		set dw [ui::measure i12 $details]
		ui::text 387 [ui::lh $y i12 36] $details i12 $c(muted) e
		ui::text 28 [ui::lh $y $f 36] [ui::clip $f $name [expr {387 - $dw - 12 - 28}]] $f $c(fg)
		if {$on} { ui::icon check 15 $c(accent) 397 [expr {$y + 10.5}] 2.2 }
		ui::hit 18 $y 404 36 [list apply {{d x y} { page::pick_part $d }} $dev]
		ui::focusable $dev row 18 $y 404 36 8 [list page::pick_part $dev]
		incr y 36
	}
	ui::wheel 0 88 $::page::W 208 page::scroll_parts
	foot {{mount Mount primary page::mount} {skip Skip ghost page::skip}}
}

proc page::draw_note {} {
	variable note
	array set c [array get ui::c]
	lassign $note icon title line text
	head $icon $title $line
	set lines {}
	foreach para [split $text \n] { lappend lines {*}[ui::wrap i14 $para 384] }
	if {[llength $lines] > 8} { set lines [lreplace [lrange $lines 0 7] end end [ui::clip i14 "[lindex $lines 7]…" 384]] }
	set y 106
	foreach l $lines {
		ui::text 28 [ui::lh $y i14 21 1] $l i14 $c(fg)
		incr y 21
	}
	foot {{ok OK primary page::skip}}
}

# Text cut to WIDTH with an ellipsis.
proc ui::clip {f str width} {
	if {[measure $f $str] <= $width} { return $str }
	while {$str ne "" && [measure $f "$str…"] > $width} { set str [string range $str 0 end-1] }
	return "$str…"
}

proc page::clicked_outside {} {}

proc page::key {sym char state} {
	variable step
	if {$::page::busy ne ""} return
	set f [ui::focused]
	switch -- $sym {
		Tab { if {$state & 1} { ui::cycle -1 } else { ui::cycle 1 }; return }
		ISO_Left_Tab { ui::cycle -1; return }
		Down - Up {
			set d [expr {$sym eq "Down" ? 1 : -1}]
			if {$step eq "drive"} { move_part $d } else { ui::cycle $d }
			return
		}
		Escape {
			switch $step { choose { not_now } default { skip } }
			return
		}
		Return - KP_Enter - space {
			if {$f ne ""} { uplevel #0 [lindex $f 7]; return }
			if {$sym eq "space"} return
			switch $step { choose { cont } drive { mount } note { skip } }
			return
		}
	}
}

# ---- the window ---------------------------------------------------------------------

proc page::main {} {
	variable W
	variable H
	set home [env HOME /tmp]
	set cache [env XDG_CACHE_HOME [file join $home .cache]]
	theme::load
	array set p [array get theme::c]
	ui::colours [dict create BAR $p(BAR) FIELD $p(FIELD) PILL $p(PILL) BORDER $p(BORDER) FG $p(FG) MUTED $p(MUTED) \
		ACCENT $p(ACCENT) ON_ACCENT $p(ON_ACCENT) DESK_TOP $p(DESK_TOP) DESK_BOTTOM $p(DESK_BOTTOM) \
		DESK_STRIPE $p(DESK_STRIPE) DESK_STRIPE_ALPHA $p(DESK_STRIPE_ALPHA)]
	raster::init [file join $cache ribbon welcome]
	ui::fonts
	set ui::W $W; set ui::H $H
	set ui::behind ""; set ui::bx 0; set ui::by 0
	wm withdraw .
	set win .w
	if {[env RIBBON_WELCOME_SCENE] eq "1"} {
		# where the boards put it, undecorated: the card at 500,266 on a 1440 x 900 screen
		toplevel $win -class RibbonWelcome -borderwidth 0 -highlightthickness 0 -background $ui::c(bar)
		wm overrideredirect $win 1
		wm geometry $win ${W}x$H+[expr {(1440 - $W) / 2}]+[expr {(900 - $H) / 2}]
		canvas $win.c -width $W -height $H -highlightthickness 0 -borderwidth 0 -background $ui::c(bar)
		place $win.c -x 0 -y 0
	} else {
		# a managed window, labwc frames it (rbn::framed); with RIBBON_OWN_FRAME=1, see-through corners
		if {[rbn::appwindow $win RibbonWelcome $W $H -fill $ui::c(bar)]} { set ui::argbwin $win }
		wm title $win Welcome
		wm iconname $win Welcome
		wm resizable $win 0 0
		set SW [winfo screenwidth .]; set SH [winfo screenheight .]
		wm geometry $win ${W}x$H+[expr {max(0, ($SW - $W) / 2)}]+[expr {max(0, ($SH - $H) / 2)}]
		wm protocol $win WM_DELETE_WINDOW {if {$::page::busy eq ""} {page::finish 0}}
	}
	set ui::cv $win.c
	bind $win.c <ButtonPress-1> {ui::press %x %y}
	bind $win.c <B1-Motion> {ui::motion %x %y}
	bind $win.c <ButtonRelease-1> {ui::release %x %y}
	bind $win.c <Button-4> {ui::scroll %x %y -1}
	bind $win.c <Button-5> {ui::scroll %x %y 1}
	bind $win.c <MouseWheel> {ui::scroll %x %y [expr {%D > 0 ? -1 : 1}]}
	bind $win <KeyPress> {page::key %K %A %s}
	draw
	focus -force $win
	if {[env RIBBON_WELCOME_TEST] ne ""} {
		after 300 [list uplevel #0 [list source -encoding utf-8 $::env(RIBBON_WELCOME_TEST)]]
	}
}

page::main
