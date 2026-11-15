# servicespage.tcl - System monitor: Services (Monitor-R4-Services), the rail's row under the metrics and its page.
# The page lists dinit's services from services.tcl, the person's own (Mine) or the system's (System): the name, the
# process ID, the state. A click selects a row; the selected one carries Start (stopped or failed) or Restart and Stop
# (running; none for the services the session stands on). The list is read again every two seconds while the page
# shows, in the background, and at once after an action. Without dinitctl the row is not drawn; the switch shows only
# when the system's side can be asked too (pkexec and the helper are there).

array set ui::paths {
	server {M2 3h20v8H2z M2 13h20v8H2z M6 7h.01 M6 17h.01}
}

namespace eval monitor {
	variable svc_scope user
	variable svc_list ""       ;# the last list read: {name state pid} dicts; "" before the first or when it failed
	variable svc_sel ""        ;# the selected service's name
	variable svc_last 0        ;# when the list was last asked for (ms)
	variable svc_asking 0
	variable svc_scroll 0
	variable svc_busy {}       ;# names with an action under way
}

proc monitor::services_shown {} {
	expr {[services::available user] || [services::available system]}
}

# The rail's Services row, under the metrics (window coordinates from the board).
proc monitor::services_rail_draw {} {
	if {!$::monitor::scene && ![services_shown]} return
	set on [expr {$::monitor::metric eq "services"}]
	ui::box 28 516 212 1 -fill $ui::c(border)
	if {$on} {
		ui::box 16 526 236 40 -fill $ui::c(field) -radius 10
		ui::box 16 536 3 20 -fill $ui::c(accent) -radius 2
	}
	ui::icon server 16 [expr {$on ? $ui::c(accent) : $ui::c(muted)}] 28 538
	ui::text 56 [ui::lh 526 [expr {$on ? "i13s" : "i13m"}] 40] Services [expr {$on ? "i13s" : "i13m"}] [expr {$on ? $ui::c(fg) : $ui::c(muted)}]
	ui::hit 16 526 236 40 [list monitor::services_open]
}

proc monitor::services_open {args} {
	set ::monitor::metric services
	set ::monitor::menu ""
	set ::monitor::svc_last 0
	draw
}

proc monitor::services_scope {scope} {
	variable svc_scope
	if {$scope eq $svc_scope} return
	set svc_scope $scope
	set ::monitor::svc_list ""
	set ::monitor::svc_sel ""
	set ::monitor::svc_scroll 0
	set ::monitor::svc_last 0
	draw
}

# Ask for the list when it is due (the page draws once a second with the samples).
proc monitor::services_poll {{now 0}} {
	variable svc_last
	variable svc_asking
	if {$::monitor::scene || $svc_asking} return
	set ms [clock milliseconds]
	if {!$now && $ms - $svc_last < 2000} return
	set svc_last $ms
	set svc_asking 1
	services::fetch $::monitor::svc_scope [list monitor::services_got $::monitor::svc_scope]
}
proc monitor::services_got {scope list} {
	set ::monitor::svc_asking 0
	if {$scope ne $::monitor::svc_scope} { services_poll 1; return }
	set ::monitor::svc_list $list
	if {$::monitor::metric eq "services" && [winfo exists $::monitor::win]} { draw }
}

proc monitor::services_select {name args} {
	set ::monitor::svc_sel $name
	draw
}

proc monitor::services_do {verb name args} {
	variable svc_busy
	if {$::monitor::scene} return
	if {[services::act $::monitor::svc_scope $verb $name [list monitor::services_done $name]]} { lappend svc_busy $name }
	draw
}
proc monitor::services_done {name ok} {
	variable svc_busy
	set svc_busy [lsearch -all -inline -not -exact $svc_busy $name]
	services_poll 1
}

proc monitor::services_scroll_rows {d} {
	variable svc_scroll
	set n [llength $::monitor::svc_list]
	set svc_scroll [expr {max(0, min($svc_scroll + $d * 40, $n * 40 - ($::monitor::H - 153)))}]
	draw
}

proc monitor::services_draw {m} {
	variable svc_list
	variable svc_sel
	variable svc_scroll
	variable svc_busy
	services_poll
	set dx [expr {$::monitor::W - 1240}]
	set H $::monitor::H
	set L 308; set R [expr {1200 + $dx}]
	set rw [expr {912 + $dx}]
	set running 0
	foreach s $svc_list { if {[dict get $s state] eq "running"} { incr running } }
	ui::text $L [ui::lh 34 sg28 36] Services sg28 $ui::c(fg) w -0.56
	ui::text $L [ui::lh 78 i14 17] "[plural [llength $svc_list] service services] · $running running" i14 $ui::c(muted)
	if {$::monitor::scene || ([services::available user] && [services::available system])} {
		ui::seg svcseg [expr {$R - 141}] 34 141 {user Mine system System} $::monitor::svc_scope monitor::services_scope 38
	}
	set idr [expr {908 + $dx}]; set str [expr {1016 + $dx}]
	ui::text $L [ui::lh 119 i12 34] Service i12 $ui::c(muted)
	ui::text $idr [ui::lh 119 i12 34] ID i12 $ui::c(muted) e
	ui::text $str [ui::lh 119 i12 34] State i12 $ui::c(muted) e
	ui::box 298 152 $rw 1 -fill $ui::c(border)
	set i 0
	set n [llength $svc_list]
	foreach s $svc_list {
		set top [expr {153 + $i * 40 - $svc_scroll}]
		incr i
		if {$top + 40 <= 153 || $top >= $H} continue
		set name [dict get $s name]; set state [dict get $s state]; set pid [dict get $s pid]
		set on [expr {$name eq $svc_sel}]
		set next [lindex $svc_list $i]
		if {$on} { ui::box 298 $top $rw 40 -fill $ui::c(field) -radius 8 } \
		elseif {$i < $n && [dict get $next name] ne $svc_sel} { ui::box 298 [expr {$top + 39}] $rw 1 -fill $ui::c(border) }
		ui::hit 298 $top $rw 40 [list monitor::services_select $name]
		set cy [expr {$top + 20}]
		ui::box 308 [expr {$cy - 12}] 24 24 -fill [expr {$on ? $ui::c(pill) : $ui::c(field)}] -radius 6
		ui::icon server 13 $ui::c(fg) 313.5 [expr {$cy - 6.5}] 1.8
		ui::text 342 [ui::lh [expr {$cy - 10}] i13s 20] $name i13s $ui::c(fg)
		ui::text $idr [ui::lh [expr {$cy - 10}] i13 20] [expr {$pid eq "" ? "–" : $pid}] i13 [expr {$pid eq "" ? $ui::c(muted) : $ui::c(fg)}] e
		set label [string totitle $state]
		switch -- $state {
			running { ui::text $str [ui::lh [expr {$cy - 10}] i13s 20] $label i13s $ui::c(fg) e }
			failed { ui::text $str [ui::lh [expr {$cy - 10}] i13m 20] $label i13m $ui::c(accent) e }
			stopped { ui::text $str [ui::lh [expr {$cy - 10}] i13m 20] $label i13m $ui::c(muted) e }
			default { ui::text $str [ui::lh [expr {$cy - 10}] i13m 20] $label i13m $ui::c(fg) e }
		}
		if {$on && $name ni $svc_busy} {
			set x $R
			foreach verb {stop restart start} label {Stop Restart Start} {
				if {![services::can $verb $name $state]} continue
				set w [expr {28 + [ui::measure i13m $label]}]
				set x [expr {$x - $w}]
				cbutton $x [expr {$top + 3}] $label ghost [list monitor::services_do $verb $name]
				set x [expr {$x - 8}]
			}
		}
	}
	ui::wheel 298 153 $rw [expr {$H - 153}] [list monitor::services_scroll_rows]
}
