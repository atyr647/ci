# page-datetime.tcl - Settings → Date and time (boards Settings-A10-Date-Time and -A10b-Date-Picker): the strip (the
# time, the long date, the zone and its abbreviation), Clock (Set from the internet, Time zone, Date, Time) and Shown
# as (24-hour clock, Seconds in the bar, Date in the bar, Week starts on). The logic is datetime.tcl.
#
# Layout (window coordinates; the page runs from 270 to 1060): the strip is 64 tall at 119, then two columns 379 wide
# (270 and 681) of 48 px rows from 229 under their block labels at 207. The date picker is a 248 x 276 card whose right
# edge is the Date box's, 8 under it: a 7-column grid of 32 px cells (the month and two chevrons, the weekdays, six
# weeks).
#
# The zone, the date, the time and the switch are root settings: each goes through dt::set_* (pkexec, the helper). A
# refusal or a cancelled prompt leaves the row as it was and puts one line in the subtitle; while the helper is asked
# those rows take no clicks. Date and Time are set by hand only while the clock is not set from the internet: with the
# switch on they are drawn as values (the box, no clicks, no focus). Without a time service on this computer the switch
# row is not drawn. The four display choices are the user's own (clock.conf) and are saved at once.
#
# The date picker: a click on a day sets that date (a day of the month before or after too). The filled day is the
# one Return sets; it starts on today (ringed) and the arrow keys move it, Page Up and Page Down by a month. The
# chevrons show another month. Escape or a click elsewhere closes it. Its weeks start on the day "Week starts on" says.

source -encoding utf-8 [file join [file dirname [file normalize [info script]]] datetime.tcl]

settings::page datetime -title {Date and time} -icon clock -group 4 -order 3 -draw settings::draw_datetime \
	-rows {Clock {Set from the internet} {Time zone} Date Time {Shown as} {24-hour clock} {Seconds in the bar} \
		{Date in the bar} {Week starts on}}

namespace eval dtp {
	variable started 0
	variable drawn -1      ;# ui::drawno when the page was last drawn
	variable cal 0         ;# the date picker is open
	variable cy 2000       ;# the month it shows
	variable cm 1
	variable sel {}        ;# its filled day {year month day}
	variable timer ""      ;# the redraw at the next minute
	variable items {}      ;# the zone dropdown's items, and the zone they were made for
	variable itemsfor "\0"
}
set ::ui::paths(dt_right) {M9 18l6-6-6-6}

# The first draw starts the reads; coming back to the page reads again. A change draws the page while it is shown.
proc dtp::begin {} {
	variable started; variable drawn; variable cal
	if {!$started} {
		set started 1
		set dt::onchange dtp::changed
		dt::start
	} elseif {$ui::drawno != $drawn + 1} {
		set dt::error ""
		set cal 0
		dt::refresh
	}
	set drawn $ui::drawno
}
proc dtp::changed {} { if {$::settings::sel eq "datetime"} { page::draw } }

# The page shows the minute: it is drawn again when the next one starts (armed at every draw, so a clock that was just
# set is followed from its new time).
proc dtp::arm {} {
	variable timer
	after cancel $timer
	set ms [expr {(60 - [clock seconds] % 60) * 1000 - [clock milliseconds] % 1000 + 30}]
	set timer [after [expr {max(250, $ms)}] dtp::changed]
}

# A value in a dropdown's box (32 tall, radius 8, ringed, a chevron): the Date, and a row that takes no clicks now.
proc dtp::value {x y w label {open 0}} {
	array set c [array get ui::c]
	ui::box $x $y $w 32 -fill $c(field) -radius 8 -ring [list [expr {$open ? $c(accent) : $c(border)}] [expr {$open ? 1.5 : 1}]]
	ui::text [expr {$x + 12}] [expr {$y + 8}] [sctl::clip $label [expr {$w - 42}]] i13 $c(fg)
	ui::icon sctl_chev 14 [expr {$open ? $c(fg) : $c(muted)}] [expr {$x + $w - 24}] [expr {$y + 9}] 2
}

proc dtp::zone_items {zone} {
	variable items; variable itemsfor
	if {$itemsfor ne $zone} {
		set names [dt::zones]
		if {$zone ne "" && $zone ni $names} { set names [linsert $names 0 $zone] }
		set items [lmap z $names { list $z $z }]
		set itemsfor $zone
	}
	return $items
}

proc dtp::flip {key} { dt::conf_set $key [expr {[dt::setting $key] eq "yes" ? "no" : "yes"}] }
proc dtp::week {day} { dt::conf_set WEEKSTART $day; page::draw }

# ---- the time field -------------------------------------------------------------------------------------

# A click in the field: the keys are the field's (not the rail's search), the caret where the click was.
proc dtp::time_click {tx f x y} {
	if {[info exists ::settings::searching]} { set ::settings::searching 0 }
	ui::field_click dt-time $tx $f $x $y
}
# Only digits and a colon stay in the field.
proc dtp::time_typed {} {
	set t [ui::fval dt-time]
	regsub -all {[^0-9:]} $t "" ok
	if {$ok eq $t} return
	set cur [expr {max(0, $ui::fld(dt-time,cur) - ([string length $t] - [string length $ok]))}]
	ui::fset dt-time $ok
	set ui::fld(dt-time,cur) $cur
}
# Return: what is not a time keeps the field open; the time it already is changes nothing.
proc dtp::time_enter {} {
	set hm [dt::parse_time [ui::fval dt-time]]
	if {$hm eq {}} return
	set ui::focus ""
	if {[format %02d:%02d {*}$hm] ne [dt::fmt [dt::now] %H:%M]} { dt::set_time [ui::fval dt-time] }
	page::draw
}

# ---- the date picker ------------------------------------------------------------------------------------

proc dtp::cal_toggle {} {
	variable cal; variable cy; variable cm; variable sel
	if {$cal} { set cal 0; set ui::focus ""; return }
	set sel [dt::ymd [dt::now]]
	lassign $sel cy cm
	set cal 1
	set ::sctl::pop ""
	set ui::focus dt-cal
}
proc dtp::cal_close {} {
	variable cal 0
	set ui::focus ""
	page::draw
}
proc dtp::cal_show {delta} {
	variable cy; variable cm
	lassign [dt::shift_month $cy $cm $delta] y m
	if {$y >= 2000 && $y <= 2099} { set cy $y; set cm $m }
	page::draw
}
# The date is set to Y M D (today again changes nothing) and the picker closes.
proc dtp::cal_pick {y m d} {
	variable cal 0
	set ui::focus ""
	if {[list $y $m $d] ne [dt::ymd [dt::now]]} { dt::set_date $y $m $d }
	page::draw
}
proc dtp::cal_key {sym} {
	variable sel; variable cy; variable cm
	lassign $sel y m d
	switch -- $sym {
		Left { set to [dt::shift_day $y $m $d -1] }
		Right { set to [dt::shift_day $y $m $d 1] }
		Up { set to [dt::shift_day $y $m $d -7] }
		Down { set to [dt::shift_day $y $m $d 7] }
		Prior - Next {
			lassign [dt::shift_month $y $m [expr {$sym eq "Prior" ? -1 : 1}]] ny nm
			set to [list $ny $nm [expr {min($d, [dt::days_in $ny $nm])}]]
		}
		Return - KP_Enter - space { cal_pick $y $m $d; return 1 }
		Escape { cal_close; return 1 }
		default { return 0 }
	}
	if {[lindex $to 0] >= 2000 && [lindex $to 0] <= 2099} {
		set sel $to
		lassign $to cy cm
	}
	page::draw
	return 1
}
# The card, its right edge at X1 and its top at Y, over the page.
proc dtp::cal_draw {x1 y} {
	variable cy; variable cm; variable sel
	array set c [array get ui::c]
	set x [expr {$x1 - 248}]
	set gx [expr {$x + 12}]
	set today [dt::ymd [dt::now]]
	set ws [dt::setting WEEKSTART]
	ui::layer
	ui::hit 0 0 1100 720 {apply {{x y} { dtp::cal_close }}}
	raster::box $ui::img $x $y 248 276 -fill $c(bar) -radius 12 -ring [list $c(border) 1] -shadow {16 40 0.5}
	ui::hit $x $y 248 276 {apply {{x y} {}}}
	# the month and the two chevrons, over the last two columns
	ui::text [expr {$gx + 9}] [expr {$y + 20}] [dt::month_title $cy $cm] i13s $c(fg)
	foreach {icon col delta} {left 5 -1 dt_right 6 1} {
		set bx [expr {$gx + 32 * $col}]
		ui::icon $icon 15 $c(muted) [expr {$bx + 8.5}] [expr {$y + 20.5}] 2
		ui::hit $bx [expr {$y + 12}] 32 32 [list apply {{d x y} { dtp::cal_show $d }} $delta]
	}
	set i 0
	foreach l [dt::weekdays $ws] {
		ui::text [expr {$gx + 32 * $i + 16}] [expr {$y + 53}] $l i11s $c(muted) c
		incr i
	}
	set i 0
	foreach cell [dt::month $cy $cm $ws] {
		lassign $cell dy dm dd in
		set bx [expr {$gx + 32 * ($i % 7)}]
		set by [expr {$y + 72 + 32 * ($i / 7)}]
		set day [list $dy $dm $dd]
		set f i13
		set fg [expr {$in ? $c(fg) : $c(muted)}]
		if {$day eq $sel} {
			ui::box $bx $by 32 32 -fill $c(accent) -radius 8
			set f i13s
			set fg $c(ink)
		} elseif {$day eq $today} {
			ui::ring $bx $by 32 32 8 $c(muted) 1.5
			set f i13s
		}
		ui::text [expr {$bx + 16}] [expr {$by + 8}] $dd $f $fg c 0 {} 1
		if {$dy >= 2000 && $dy <= 2099} {
			ui::hit $bx $by 32 32 [list apply {{y m d px py} { dtp::cal_pick $y $m $d }} $dy $dm $dd]
		}
		incr i
	}
	ui::focusable dt-cal list $x $y 248 276 12 dtp::cal_key
}

# ---- the page ---------------------------------------------------------------------------------------------

proc settings::draw_datetime {} {
	array set c [array get ui::c]
	dtp::begin
	dtp::arm
	set m [dt::model]
	set now [dt::now]
	set busy [dict get $m busy]
	set ntp [dict get $m ntp_available]
	set byhand [expr {(!$ntp || ![dict get $m ntp_on]) && !$busy}]
	if {!$byhand} { set dtp::cal 0 }
	ui::text 270 34 {Date and time} sg28 $c(fg) w -0.56
	ui::text 270 [ui::lh 76 i14 21] [sctl::clip [dict get $m subtitle] 790 i14] i14 $c(muted)
	# the strip
	ui::box 270 119 790 64 -fill $c(field) -radius 12 -ring [list $c(border) 1]
	ui::box 284 133 36 36 -fill $c(pill) -radius 10
	ui::icon clock 18 $c(fg) 293 142 1.9
	set tw [ui::text 334 137 [dt::time_text $now] sg22 $c(fg) w 0 {} 1]
	ui::text [expr {334 + $tw + 14}] 142.5 [dt::long_date $now] i14 $c(muted)
	set where [expr {[dict get $m zone] ne "" ? "[dict get $m zone] · [dict get $m abbr]" : [dict get $m abbr]}]
	ui::text 1040 143 [sctl::clip $where 300] i13 $c(muted) e
	# Clock
	sctl::label 270 207 Clock
	set y 229
	if {$ntp} {
		sctl::row 270 649 $y {Set from the internet}
		if {$busy} { ui::toggle 611 [expr {$y + 13}] [dict get $m ntp_on] } else {
			sctl::toggle dt-ntp 649 $y [dict get $m ntp_on] [list dt::set_ntp [expr {![dict get $m ntp_on]}]]
		}
		incr y 48
	}
	sctl::row 270 649 $y {Time zone}
	set items [dtp::zone_items [dict get $m zone]]
	if {$busy || ![llength $items]} { dtp::value 449 [expr {$y + 8}] 200 [dict get $m name] } else {
		sctl::dropdown dt-zone 449 $y 200 $items [dict get $m zone] dt::set_zone
	}
	incr y 48
	sctl::row 270 649 $y Date
	set caly [expr {$y + 8}]
	dtp::value 449 $caly 200 [dt::date_text $now] $dtp::cal
	if {$byhand} {
		sctl::hit 449 $caly 200 32 dtp::cal_toggle
		ui::focusable dt-date button 449 $caly 200 32 8 {dtp::cal_toggle; page::draw}
	}
	incr y 48
	sctl::row 270 649 $y Time 1
	if {$byhand} {
		if {$ui::focus ne "dt-time"} { ui::fset dt-time [dt::fmt $now %H:%M] }
		ui::field dt-time 573 [expr {$y + 8}] 76 -h 32 -font i13m -pad 19 -radius 8 -max 5 \
			-onchange dtp::time_typed -onenter dtp::time_enter
		ui::hit 573 [expr {$y + 8}] 76 32 [list dtp::time_click 592 i13m]
	} else {
		ui::box 573 [expr {$y + 8}] 76 32 -fill $c(field) -radius 8 -ring [list $c(border) 1]
		ui::text 611 [expr {$y + 16}] [dt::fmt $now %H:%M] i13m $c(fg) c 0 {} 1
	}
	# Shown as
	sctl::label 681 207 {Shown as}
	sctl::row 681 1060 229 {24-hour clock}
	sctl::toggle dt-24 1060 229 [dict get $m hour24] {dtp::flip HOUR24}
	sctl::row 681 1060 277 {Seconds in the bar}
	sctl::toggle dt-seconds 1060 277 [dict get $m seconds] {dtp::flip SECONDS}
	sctl::row 681 1060 325 {Date in the bar}
	sctl::toggle dt-date-bar 1060 325 [dict get $m date] {dtp::flip DATE}
	sctl::row 681 1060 373 {Week starts on} 1
	ui::seg dt-week 860 381 200 {monday Monday sunday Sunday} [dict get $m weekstart] dtp::week
	if {$dtp::cal} { dtp::cal_draw 649 [expr {$caly + 40}] }
	sctl::overlay
}
