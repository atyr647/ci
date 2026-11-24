# ui-reader.tcl - the reading pane (U41, Mail-A-Ledger, -A2-Thread, -A4-Search): the toolbar (where the message
# is, or the search's matches with previous and next; Reply, Reply all, Forward, Archive, Delete, Flag), the
# subject with the message count, the account and the labels, the earlier messages as one-line rows (more than
# three, or with the reply open: "N earlier"), the messages shown in full on a 560 px measure, inline pictures and
# the attachment cards (a press saves one). Search words are highlighted in the text.

namespace eval ::mailapp {
	variable pane_end 0
	variable thumbs
	array set thumbs {}
	variable bodies
	array set bodies {}
	variable matchy {}           ;# the tops of the search matches in the open message, unscrolled
}

proc ::mailapp::pane_max {} {
	variable pane_end
	variable H
	expr {max(0, $pane_end - $H + 44)}
}

# The text of a message: its body as paragraphs, each {quote? text}.
proc ::mailapp::paras {key} {
	variable bodies
	if {[info exists bodies($key)]} { return $bodies($key) }
	if {[catch {mail::mime::body [mail::mime::parse [mail::store::read $key]]} t]} { set t "" }
	set out {}
	foreach p [split [regsub -all {\n[ \t]*\n(\s*\n)*} [string trim [string map {\r ""} $t]] \u0000] \u0000] {
		set lines [split $p \n]
		set q [expr {[string index [string trimleft [lindex $lines 0]] 0] eq ">"}]
		# a signature and what follows it is left out of the reading measure's paragraphs only where it is the
		# standard "-- " delimiter
		if {[lindex $lines 0] eq "-- "} break
		if {$q} {
			lappend out [list 1 [join [lmap l $lines {string trimleft [string trimleft $l] "> "}] " "]]
		} else {
			lappend out [list 0 [join [lmap l $lines {string trim $l}] " "]]
		}
	}
	set out [lmap p $out {expr {[string trim [lindex $p 1]] eq "" ? [continue] : $p}}]
	set bodies($key) $out
	return $out
}

# A picture of an attachment, W x H, cover-cropped (through ffmpeg: Tk reads no JPEG); "" when it cannot be made.
proc ::mailapp::thumb {key section w h} {
	variable thumbs
	set k [list $key $section $w $h]
	if {[info exists thumbs($k)]} { return $thumbs($k) }
	set thumbs($k) ""
	if {[auto_execok ffmpeg] eq ""} { return "" }
	set dir [file join [raster::dir] thumbs]
	file mkdir $dir
	set base [file join $dir [string map {/ _ " " _} "[join $key _]-$section-${w}x$h"]]
	if {![file exists $base.png]} {
		if {[catch {
			mail::mime::save [mail::mime::parse [mail::store::read $key]] $section $base.src
			exec ffmpeg -v error -y -i $base.src -vf "scale=$w:$h:force_original_aspect_ratio=increase,crop=$w:$h" -frames:v 1 $base.png 2>@1
			file delete $base.src
		}]} { catch {file delete $base.src}; return "" }
	}
	if {[catch {image create photo -file $base.png} img]} { return "" }
	set thumbs($k) $img
	return $img
}

# A picture with rounded corners R at X Y (W x H) on the page.
proc ::mailapp::picture {img x y w h r} {
	variable c
	if {$img eq ""} {
		ui::box $x $y $w $h -fill $c(pill) -radius $r
		return
	}
	$::ui::img copy $img -to [expr {round($x)}] [expr {round($y)}]
	ui::corners $x $y $w $h $r $c(bar)
}

proc ::mailapp::words {} {
	variable state
	if {$state(query) eq ""} { return {} }
	dict get [mail::search::parse $state(query)] words
}

# Lines of TEXT wrapped at WIDTH in F, from TOP, each LH tall; search words highlighted. Returns the bottom.
proc ::mailapp::para_draw {x top text f colour width lh} {
	variable c
	variable matchy
	variable pscroll
	set words [words]
	set y $top
	foreach line [ui::wrap $f $text $width] {
		set ty [ui::lh $y $f $lh]
		if {$y + $lh > 52 && $y < $::mailapp::H} {
			set sp [expr {[llength $words] ? [mail::search::spans $line $words] : {}}]
			if {[llength $sp]} {
				set xs [ui::layout $f $line]
				foreach s $sp {
					lassign $s a b
					set x0 [lindex $xs $a]
					set x1 [expr {$b >= [string length $line] ? [lindex $xs end] : [lindex $xs $b]}]
					ui::box [expr {$x + $x0 - 1}] [expr {$ty - 1}] [expr {$x1 - $x0 + 2}] [expr {[ui::lhn $f] + 2}] -fill $c(hit) -radius 3
				}
			}
			ui::text $x $ty $line $f $colour
		}
		if {[llength $words] && [llength [mail::search::spans $line $words]]} { lappend matchy [expr {$y + $pscroll}] }
		set y [expr {$y + $lh}]
	}
	return $y
}

proc ::mailapp::pane_top {} {
	variable c
	variable state
	variable conv
	variable W
	ui::box 604 0 [expr {$W - 604}] 52 -fill $c(bar)
	ui::box 604 51 [expr {$W - 604}] 1 -fill $c(border)
	if {$conv eq ""} return
	if {$state(query) ne ""} {
		set n [llength $::mailapp::matchy]
		if {$n} {
			set w [ui::text 642 18 [expr {$state(match) + 1}] i13s $c(fg) w 0 {} 1]
			ui::text [expr {642 + $w}] 18 " of $n" i13 $c(muted) w 0 {} 1
			iconbtn chevup 692.5 10 32 15 {::mailapp::match_step -1}
			iconbtn chev 728.5 10 32 15 {::mailapp::match_step 1}
		}
	} else {
		set last [dict get $conv last]
		set x 642
		set parts [list [dict get $last account] [dict get $last folder]]
		foreach p $parts i {0 1} {
			set on [expr {$i == 1}]
			set w [ui::text $x 18 $p [expr {$on ? "i13m" : "i13"}] [expr {$on ? $c(fg) : $c(muted)}]]
			set x [expr {$x + $w + 8}]
			if {!$on} { icon right 12 $c(muted) $x 20 2; set x [expr {$x + 20}] }
		}
	}
	set x [expr {$W - 265}]
	iconbtn reply $x 10 32 15 {::mailapp::reply_open reply}
	iconbtn replyall [expr {$x + 34}] 10 32 15 {::mailapp::reply_open all}
	iconbtn fwd [expr {$x + 68}] 10 32 15 {::mailapp::reply_open forward}
	ui::box [expr {$x + 108}] 17 1 18 -fill $c(border)
	iconbtn archive [expr {$x + 117}] 10 32 15 {::mailapp::move_to archive}
	iconbtn trash [expr {$x + 151}] 10 32 15 {::mailapp::move_to trash}
	set fl [dict get $conv flagged]
	iconbtn flag [expr {$x + 185}] 10 32 15 ::mailapp::toggle_flag [expr {$fl ? $c(fg) : ""}] [expr {$fl ? $c(field) : ""}]
}

proc ::mailapp::match_step {d} {
	variable state
	variable matchy
	variable pscroll
	set n [llength $matchy]
	if {!$n} return
	set state(match) [expr {($state(match) + $d + $n) % $n}]
	set y [lindex $matchy $state(match)]
	set pscroll [expr {max(0, min([pane_max], $y - 200))}]
	paint
}

# The pane's left edge of the measure.
proc ::mailapp::px {} {
	variable W
	expr {604 + (($W - 604) - 560) / 2}
}

proc ::mailapp::pane_paint {} {
	variable c
	variable conv
	variable expanded
	variable earlier
	variable pscroll
	variable pane_end
	variable state
	variable matchy
	set matchy {}
	if {$conv eq ""} { pane_top; return }
	set x [px]
	set y [expr {78 - $pscroll}]
	set lines [ui::wrap sg26 [dict get $conv subject] 560 -0.52]
	foreach l $lines {
		if {$y > 0} { ui::text $x [ui::lh $y sg26 31.2] $l sg26 $c(fg) w -0.52 }
		set y [expr {$y + 31.2}]
	}
	set n [dict get $conv count]
	set w [ui::text $x [expr {$y + 18.4}] "$n message[expr {$n == 1 ? "" : "s"}]" i13 $c(muted) w 0 {} 1]
	set mx [expr {$x + $w + 8}]
	set mx [expr {$mx + [ui::text $mx [expr {$y + 18.4}] · i13 $c(muted)] + 8}]
	set mx [expr {$mx + [ui::text $mx [expr {$y + 18.4}] [join [dict get $conv accounts] ", "] i13 $c(muted)] + 20}]
	foreach l [dict get $conv labels] { set mx [expr {$mx + [chip $mx [expr {$y + 14.4}] $l 24] + 8}] }
	set y [expr {$y + 60.4}]
	set msgs [dict get $conv msgs]
	set ex [lmap m $msgs {expr {[dict get $m key] in $expanded ? $m : [continue]}}]
	set big [expr {[llength $ex] == 1}]
	# the rows before the first message in full fold into "N earlier" past three, or while the reply is open
	set before {}
	foreach m $msgs { if {[dict get $m key] in $expanded} break; lappend before $m }
	set fold [expr {!$earlier && ([llength $before] > 3 || ($state(reply) && [llength $before] > 1))}]
	set lastex [dict get [lindex $ex end] key]
	set shown 0
	foreach m $msgs {
		set k [dict get $m key]
		if {$k ni $expanded} {
			set i [lsearch -exact $before $m]
			if {$fold && $i >= 0 && $i < [llength $before] - 1} {
				if {$i == 0} {
					if {$y > 0} {
						ui::text $x [expr {$y + 12}] "[expr {[llength $before] - 1}] earlier" i13 $c(muted)
						icon chev 13 $c(muted) [expr {$x + 56.5}] [expr {$y + 13.5}] 2
						ui::box $x [expr {$y + 39}] 560 1 -fill $c(border)
						ui::hit $x $y 560 40 {set ::mailapp::earlier 1; ::mailapp::paint}
					}
					set y [expr {$y + 40}]
				}
				continue
			}
			collapsed $x $y $m
			set y [expr {$y + 52}]
			continue
		}
		if {$big} {
			set y [expr {$y + 22}]
			set y [message_draw $x $y $m 36 18]
		} else {
			set top $y
			set y [message_draw $x [expr {$y + 20}] $m 32 14]
			if {$k ne $lastex} {
				set y [expr {$y + 18}]
				ui::box $x [expr {$y - 1}] 560 1 -fill $c(border)
			} else {
				set y [expr {$y + 4}]
			}
		}
	}
	if {$state(reply)} { set y [reply_paint $x [expr {$y + 18}]] }
	set pane_end [expr {$y + $pscroll}]
	clear_band 605 0 [expr {$::mailapp::W - 1}] 51
	pane_top
}

proc ::mailapp::collapsed {x y m} {
	variable c
	if {$y > 0 && $y < $::mailapp::H} {
		set name [mail::thread::name [dict get $m from]]
		avatar $name $x [expr {$y + 12}] 28
		ui::text [expr {$x + 40}] [expr {$y + 18}] [elide i13s $name 92] i13s $c(fg)
		set when [mail::thread::when_reader [dict get $m date] [clock_now]]
		if {$::mailapp::state(reply)} { set when [mail::thread::when_list [dict get $m date] [clock_now]] }
		set ww [ui::text [expr {$x + 560}] [expr {$y + 18.5}] $when i12 $c(muted) e 0 {} 1]
		ui::text [expr {$x + 144}] [expr {$y + 18}] [elide i13 [dict get $m snippet] [expr {560 - 144 - $ww - 12}]] i13 $c(muted)
		ui::box $x [expr {$y + 51}] 560 1 -fill $c(border)
	}
	ui::hit $x $y 560 52 [list ::mailapp::expand [dict get $m key]]
}

proc ::mailapp::expand {k} {
	variable expanded
	lappend expanded $k
	paint
}

# A message in full at Y: the head (avatar SIZE), GAP, the text, pictures and attachments. Returns the bottom.
proc ::mailapp::message_draw {x y m size gap} {
	variable c
	set name [mail::thread::name [dict get $m from]]
	set mine [mine]
	if {$y + $size > 0 && $y < $::mailapp::H} {
		avatar $name $x $y $size
		set tx [expr {$x + $size + 12}]
		set h0 [expr {$size == 36 ? 1 : -1}]
		set nw [ui::text $tx [expr {$y + $h0}] $name i14s $c(fg)]
		ui::text [expr {$tx + $nw + 8}] [expr {$y + $h0 + 2}] [lindex [dict get $m from] 1] i12 $c(muted)
		ui::text $tx [expr {$y + $h0 + 19}] [mail::thread::recipients $m $mine] i12 $c(muted)
		ui::text [expr {$x + 560}] [expr {$y + $h0 + 2}] [mail::thread::when_reader [dict get $m date] [clock_now]] i12 $c(muted) e 0 {} 1
	}
	set y [expr {$y + $size + $gap}]
	set ps [paras [dict get $m key]]
	set i 0
	foreach p $ps {
		lassign $p q t
		set last [expr {$i == [llength $ps] - 1}]
		if {$q} {
			ui::box $x [expr {$y + 3}] 2 [expr {[llength [ui::wrap i15 $t 546]] * 24.75 - 6}] -fill $c(border)
			set y [para_draw [expr {$x + 14}] $y $t i15 $c(muted) 546 24.75]
		} else {
			set y [para_draw $x $y $t i15 $c(fg) 560 24.75]
		}
		if {!$last} { set y [expr {$y + 14}] }
		incr i
	}
	# inline pictures, two to a row; the other attachments as cards
	set pics {}
	set cards {}
	foreach a [dict get $m atts] {
		if {[dict get $a inline] && [string match image/* [dict get $a type]]} { lappend pics $a } else { lappend cards $a }
	}
	if {[llength $pics]} {
		set y [expr {$y + 14}]
		set px $x
		foreach a $pics {
			if {$px > $x + 300} { set px $x; set y [expr {$y + 160}] }
			if {$y + 150 > 0 && $y < $::mailapp::H} { picture [thumb [dict get $m key] [dict get $a section] 268 150] $px $y 268 150 10 }
			ui::hit $px $y 268 150 [list ::mailapp::save_attachment [dict get $m key] [dict get $a section] [dict get $a name]]
			set px [expr {$px + 278}]
		}
		set y [expr {$y + 150}]
	}
	if {[llength $cards]} {
		set y [expr {$y + 20}]
		set total 0
		foreach a $cards { incr total [dict get $a size] }
		set n [llength $cards]
		if {$y > 0} { ui::text $x [expr {$y + 1.6}] [string toupper "$n attachment[expr {$n == 1 ? "" : "s"}] · [mail::compose::size_text $total]"] i11s $c(muted) w 1.32 }
		set y [expr {$y + 25}]
		set cx $x
		foreach a $cards {
			if {$cx > $x + 300} { set cx $x; set y [expr {$y + 72}] }
			attcard $cx $y $m $a
			set cx [expr {$cx + 284}]
		}
		set y [expr {$y + 60}]
	}
	return $y
}

proc ::mailapp::attcard {x y m a} {
	variable c
	if {$y + 60 > 0 && $y < $::mailapp::H} {
		ui::box $x $y 272 60 -fill $c(field) -radius 12 -ring [list $c(border) 1]
		if {[string match image/* [dict get $a type]]} {
			picture [thumb [dict get $m key] [dict get $a section] 44 44] [expr {$x + 8}] [expr {$y + 8}] 44 44 7
		} else {
			ui::box [expr {$x + 8}] [expr {$y + 8}] 44 44 -fill $c(pill) -radius 9
			icon pdf 20 $c(fg) [expr {$x + 20}] [expr {$y + 20}] 1.7
		}
		htext [expr {$x + 64}] [expr {$y + 13.5}] [dict get $a name] i13m $c(fg) [mail::search::spans [dict get $a name] [words]] 160
		ui::text [expr {$x + 64}] [expr {$y + 31.5}] [mail::compose::size_text [dict get $a size]] i12 $c(muted) w 0 {} 1
		icon download 14 $c(muted) [expr {$x + 242}] [expr {$y + 23}]
	}
	ui::hit $x $y 272 60 [list ::mailapp::save_attachment [dict get $m key] [dict get $a section] [dict get $a name]]
}
