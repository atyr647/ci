# ui-menu.tcl - Mail's pickers and menus (Mail-A10-More, -A11-List-more, -A12-Reply-mode, -A13-From): Settings'
# dropdown as the account sheet draws it (§bar, radius 12, a 1 px ring, 6 px in, 36 px rows, the current choice
# checked in the accent), with a leading icon or avatar. It is a canvas of its own placed over the window, so that it
# also covers the text and entry widgets placed there (the reply's text, the new message's To and Cc).
#
#   mailapp::menu_open PARENT X Y W ROWS UNDER   opens it at X Y of PARENT (a toplevel); UNDER is the colour behind
#        its corners. ROWS: dicts {lead ICON|@NAME text T ?tail T? ?on 0|1? ?dim 0|1? ?cmd SCRIPT?} (@NAME: NAME's
#        avatar). A row's SCRIPT runs after the menu closes; a dimmed row takes no click.
#   mailapp::menu_close                          closes it (a click elsewhere in the window, Escape)
#   mailapp::menu_up                             1 while one is open

namespace eval ::mailapp {
	variable menu ""          ;# {canvas image hits} of the open menu
}

proc ::mailapp::menu_up {} {
	variable menu
	expr {$menu ne "" && [winfo exists [lindex $menu 0]]}
}

proc ::mailapp::menu_close {} {
	variable menu
	if {$menu eq ""} return
	lassign $menu cv img
	set menu ""
	catch {destroy $cv}
	catch {image delete $img}
}

proc ::mailapp::menu_open {parent x y w rows under} {
	variable c
	variable menu
	menu_close
	set h [expr {12 + 36 * [llength $rows]}]
	set cv [expr {$parent eq "." ? "" : $parent}].menu
	canvas $cv -width $w -height $h -highlightthickness 0 -borderwidth 0 -background $under
	set img [image create photo -width $w -height $h]
	$img put $under -to 0 0 $w $h
	raster::box $img 0 0 $w $h -fill [ui::col $c(bar)] -radius 12 -ring [list $c(border) 1]
	$cv create image 0 0 -image $img -anchor nw
	# the rows are drawn with Mail's own primitives, on this canvas
	set keys {cv img W H}
	foreach k $keys { set save($k) [set ::ui::$k] }
	set ::ui::cv $cv; set ::ui::img $img; set ::ui::W $w; set ::ui::H $h
	set hits {}
	set code [catch {
		set i 0
		foreach r $rows {
			set ry [expr {6 + 36 * $i}]
			set on [expr {[dict exists $r on] && [dict get $r on]}]
			set dim [expr {[dict exists $r dim] && [dict get $r dim]}]
			set lead [dict get $r lead]
			set tx 18
			if {[string index $lead 0] eq "@"} {
				avatar [string range $lead 1 end] 18 [expr {$ry + 8}] 20
				incr tx 30
			} elseif {$lead ne ""} {
				icon $lead 15 $c(muted) 18 [expr {$ry + 10.5}] 2
				incr tx 25
			}
			set tw [ui::text $tx [expr {$ry + 10}] [dict get $r text] [expr {$on ? "i13s" : "i13m"}] [expr {$dim ? $c(muted) : $c(fg)}]]
			if {[dict exists $r tail] && [dict get $r tail] ne ""} {
				ui::text [expr {$tx + $tw + 10}] [expr {$ry + 10}] [dict get $r tail] i13 $c(muted)
			}
			if {$on} { icon check 14 $c(accent) [expr {$w - 32}] [expr {$ry + 11}] 2.4 }
			if {!$dim && [dict exists $r cmd]} { lappend hits [list 6 $ry [expr {$w - 6}] [expr {$ry + 36}] [dict get $r cmd]] }
			incr i
		}
	} err]
	foreach k $keys { set ::ui::$k $save($k) }
	if {$code} { destroy $cv; image delete $img; return -code error $err }
	$cv itemconfigure page -state normal
	bind $cv <ButtonPress-1> {::mailapp::menu_press %x %y}
	bind $cv <Escape> ::mailapp::menu_close
	place $cv -x [expr {round($x)}] -y [expr {round($y)}]
	raise $cv
	focus $cv
	set menu [list $cv $img $hits]
}

proc ::mailapp::menu_press {x y} {
	variable menu
	if {$menu eq ""} return
	foreach h [lindex $menu 2] {
		lassign $h x0 y0 x1 y1 script
		if {$x < $x0 || $x >= $x1 || $y < $y0 || $y >= $y1} continue
		menu_close
		uplevel #0 $script
		return
	}
}

foreach {k v} {check {M20 6L9 17l-5-5} refresh {M23 4v6h-6 M1 20v-6h6 M3.51 9a9 9 0 0 1 14.85-3.36L23 10 M1 14l4.64 4.36A9 9 0 0 0 20.49 15}
	more {M12 12h.01 M19 12h.01 M5 12h.01}} {
	if {![info exists ::mailapp::paths($k)]} { set ::mailapp::paths($k) $v }
}

# ---- the pickers -----------------------------------------------------------------------------------------------
# The inline reply's mode chip (Mail-A12-Reply-mode): who the reply goes to.
proc ::mailapp::reply_mode_menu {x y} {
	variable draft
	variable c
	set cur [dict get $draft mode]
	set rows {}
	foreach {m icn word} {reply reply Reply all replyall {Reply all} forward fwd Forward} {
		lappend rows [dict create lead $icn text $word on [expr {$m eq $cur}] cmd [list ::mailapp::reply_pick $m]]
	}
	menu_open $::mailapp::win $x [expr {$y + 34}] 180 $rows $c(field)
}
proc ::mailapp::reply_pick {mode} {
	variable draft
	if {$draft ne "" && [dict get $draft mode] ne $mode} { reply_mode $mode }
	if {[winfo exists $::mailapp::rtext]} { focus $::mailapp::rtext }
}

# The new message's From chip (Mail-A13-From): the account it goes from, each with its address.
proc ::mailapp::from_menu {x y} {
	variable cdraft
	variable c
	set rows {}
	foreach a [compose_accounts] {
		lappend rows [dict create lead @$a text $a tail [lindex [from_of $a] 1] on [expr {$a eq [dict get $cdraft account]}] \
			cmd [list ::mailapp::compose_from $a]]
	}
	menu_open $::mailapp::cwin $x [expr {$y + 34}] 300 $rows $c(bar)
}
