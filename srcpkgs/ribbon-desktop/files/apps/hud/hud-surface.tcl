# hud-surface.tcl - the client of ribbon-hud-surface, the HUD's layer-shell overlay (U23).
#
# The helper (apps/hud/native/hud-surface.c) is a wlr-layer-shell OVERLAY surface with an empty input region and no
# keyboard, except while the quick menu is open (keyboard 1, grab 1, a full-screen input region): it draws the ops of hud-draw.tcl (with view key native 1) with cairo, see-through, and never takes a click
# or a key from the game below. This file starts it, sends it frames and reads its events.
#
#   hud::surface::start ?-helper PATH? ?-event CMD?   -> 1 when the helper runs and said hello, else 0 (the reason is in
#                                                        hud::surface::error); CMD is called with each event line
#   hud::surface::size                                -> {W H}, the output's logical size
#   hud::surface::show OPS                            draw OPS (hud-draw.tcl form); {} hides the surface. A frame equal to
#                                                        the last one is not sent again
#   hud::surface::region ?name ...?                   input rectangles (the "hit" ops named so); none: no input at all
#   hud::surface::put_line LINE                           a raw command (snapshot PATH, ping)
#   hud::surface::stop

namespace eval ::hud::surface {
	variable chan ""
	variable W 0
	variable H 0
	variable error ""
	variable event_cmd ""
	variable last ""
	variable lastregion "-"
	variable hello ""
	variable mapped ""          ;# the last "mapped X Y W H" the helper reported
	variable hits {}            ;# name -> {x y w h} from the last ops shown
}

proc ::hud::surface::start {args} {
	variable chan
	variable W
	variable H
	variable error
	variable event_cmd
	variable hello
	set def /usr/lib/ribbon/hud/ribbon-hud-surface
	if {[info exists ::env(RIBBON_HUD_SURFACE)]} { set def $::env(RIBBON_HUD_SURFACE) } elseif {![file executable $def]} { set def ribbon-hud-surface }
	set o [dict merge [list -helper $def -event ""] $args]
	set event_cmd [dict get $o -event]
	stop
	set error ""
	if {[catch {::open [list | [dict get $o -helper] 2>@stderr] r+} ch]} {
		set error "cannot start [dict get $o -helper]: $ch"
		return 0
	}
	set chan $ch
	fconfigure $ch -blocking 0 -buffering line -translation lf -encoding utf-8
	fileevent $ch readable [list ::hud::surface::readable]
	set hello ""
	set t [after 3000 [list set ::hud::surface::hello timeout]]
	if {$hello eq ""} { vwait ::hud::surface::hello }
	after cancel $t
	if {$hello ne "ok"} {
		set error [expr {$hello eq "timeout" ? "the helper did not say hello" : "the helper stopped: no layer-shell?"}]
		stop
		return 0
	}
	return 1
}

proc ::hud::surface::readable {} {
	variable chan
	variable W
	variable H
	variable hello
	variable mapped
	variable event_cmd
	if {$chan eq ""} return
	if {[catch {gets $chan line} n] || ($n < 0 && [eof $chan])} {
		set hello gone
		catch {::close $chan}
		set chan ""
		if {$event_cmd ne ""} { catch {uplevel #0 [list {*}$event_cmd gone]} }
		return
	}
	if {$n < 0} return
	if {[regexp {^hello (\d+) (\d+)} $line -> w h]} {
		set W $w; set H $h; set hello ok
	} elseif {[regexp {^mapped (.*)} $line -> m]} {
		set mapped $m
	}
	if {$event_cmd ne ""} { catch {uplevel #0 [list {*}$event_cmd $line]} }
}

proc ::hud::surface::size {} { variable W; variable H; list $W $H }
proc ::hud::surface::running {} { variable chan; expr {$chan ne ""} }

proc ::hud::surface::put_line {line} {
	variable chan
	if {$chan eq ""} { return 0 }
	if {[catch {puts $chan $line; flush $chan}]} { return 0 }
	return 1
}

proc ::hud::surface::stop {} {
	variable chan
	variable last
	variable lastregion
	if {$chan ne ""} {
		catch {puts $chan quit; flush $chan}
		catch {::close $chan}
		set chan ""
	}
	set last ""
	set lastregion "-"
}

# one number for the helper: whole numbers stay whole, others get three decimals
proc ::hud::surface::num {v} {
	if {[string is integer -strict $v]} { return $v }
	string trimright [string trimright [format %.3f $v] 0] .
}

# ops -> the helper's frame text (fields separated by TAB)
proc ::hud::surface::encode {ops} {
	variable hits
	set hits {}
	set out "frame\n"
	set T \t
	foreach op $ops {
		switch -- [lindex $op 0] {
			rrect {
				lassign [lrange $op 1 end] x y w h r fill ring shadow alpha
				if {$alpha eq ""} { set alpha 1 }
				lassign [expr {$ring ne "" ? $ring : {- 0}}] rc rw
				lassign [expr {$shadow ne "" ? $shadow : {0 0 0 #000000}}] dy bl sa sc
				append out [join [list rrect [num $x] [num $y] [num $w] [num $h] [num $r] $fill [num $alpha] $rc $rw \
					[num $dy] [num $bl] [num $sa] $sc] $T] "\n"
			}
			rect {
				lassign [lrange $op 1 end] x y w h col
				append out [join [list rect [num $x] [num $y] [num $w] [num $h] $col] $T] "\n"
			}
			text {
				lassign [lrange $op 1 end] x y anchor fam px col str
				append out [join [list text [num $x] [num $y] $anchor $fam [num $px] $col [string map [list \t " " \n " "] $str]] $T] "\n"
			}
			line {
				lassign [lrange $op 1 end] x1 y1 x2 y2 w col dash
				append out [join [list line [num $x1] [num $y1] [num $x2] [num $y2] [num $w] $col [expr {$dash eq "" ? "-" : $dash}]] $T] "\n"
			}
			poly {
				lassign [lrange $op 1 end] pts col
				append out [join [list poly $col {*}[lmap v $pts {num $v}]] $T] "\n"
			}
			pline {
				lassign [lrange $op 1 end] pts w col
				append out [join [list pline [num $w] $col {*}[lmap v $pts {num $v}]] $T] "\n"
			}
			image {
				lassign [lrange $op 1 end] x y w h path
				append out [join [list image [num $x] [num $y] [num $w] [num $h] [string map [list \t " " \n " "] $path]] $T] "\n"
			}
			hit {
				lassign [lrange $op 1 end] name x y w h
				dict set hits $name [list $x $y $w $h]
			}
		}
	}
	append out "end\n"
	return $out
}

proc ::hud::surface::show {ops} {
	variable chan
	variable last
	if {$chan eq ""} { return 0 }
	if {$ops eq ""} { set text "frame\nend\n" } else { set text [encode $ops] }
	if {$text eq $last} { return 1 }
	set last $text
	if {[catch {puts -nonewline $chan $text; flush $chan}]} { return 0 }
	return 1
}

# the named hit boxes of the last frame are the input region; no names: nothing takes input
proc ::hud::surface::region {args} {
	variable hits
	variable lastregion
	set line region
	foreach n $args { if {[dict exists $hits $n]} { append line " [dict get $hits $n]" } }
	if {$line eq $lastregion} { return }
	set lastregion $line
	put_line $line
}

# which hit box holds screen point X Y ("" for none)
proc ::hud::surface::hit_at {x y} {
	variable hits
	dict for {n r} $hits {
		lassign $r rx ry rw rh
		if {$x >= $rx && $x < $rx + $rw && $y >= $ry && $y < $ry + $rh} { return $n }
	}
	return ""
}
