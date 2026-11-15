# page-updates.tcl - Settings → Updates (boards Settings-A3-Updates and Settings-A3b-Rewind; HANDOFF "Settings → Updates").
#
# The page is a front end to kit, as the bar's updates panel is (shell/updates.tcl): kit runs as a subprocess with
# the GUI-only flag --tcl, asynchronously, and its answer comes back as one Tcl list per line. Nothing is worked out
# here, and no kit transaction is done here:
#     kit check --tcl            plan {rows R question Q checked T}              (nothing is done)
#     kit check --tcl --yes      done {rows R lines L stale S restart X time T}  (the grab)
#     kit rewind --tcl           plan {rows R question Q history H}              (nothing is done)
#     kit rewind --tcl --yes     done {...}                                      (the rewind)
# The operating system's own packages are ribbon-update's, which speaks the same --tcl (docs/SYSTEM-UPDATES.md §7.10,
# phase now): `ribbon-update --tcl` gives its plan (no root, nothing done) and `pkexec ribbon-update --tcl --yes` does
# the update (a snapshot first) and prints a done line. The waiting list is kit's rows, then the system's, under one
# question in kit's words; Update runs the system's update first, then kit's grab. History and Rewind stay kit's.
# The switches are written by kit-updater --set KEY=VALUE, which checks each value. The page reads
# ~/.config/kit/updates.conf with kit-updater's own rules (lib/updater.tcl). Settings' rail count and chip are
# main.tcl's and rail.tcl's (they read kit's cache file).
#
# RIBBON_KIT names kit, RIBBON_KIT_UPDATER kit-updater, RIBBON_UPDATE ribbon-update and RIBBON_UPDATE_PKEXEC what runs
# it as root (each a Tcl list), for tests.

array set ::ui::paths {
	box {M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z M3.27 6.96L12 12.01l8.73-5.05 M12 22.08V12}
	undo {M9 14L4 9l5-5 M4 9h10.5a5.5 5.5 0 0 1 0 11H11}
	chev {M6 9l6 6 6-6}
	check {M20 6L9 17l-5-5}
}

settings::page updates -title Updates -icon refresh -group 4 -order 2 -draw settings::draw_updates \
	-rows {Waiting {Notify} {Download automatically} {Install automatically at} {Check every} {Check now} \
		History Rewind {Restart to finish}}

namespace eval ::kupd {
	variable rows {}        ;# the waiting kits: dicts name short old new bytes tags note
	variable plan {}        ;# the last check's plan (dict); {} when up to date, or not known yet
	variable checked ""     ;# seconds: the last check (the plan's, or the cache's)
	variable err ""         ;# why the last run failed (kit's reason)
	variable doneline ""    ;# the last result's line: "Updated 5 kits · today, 14:20"
	variable restart {}     ;# restart-tagged kits of the last update: "name version" each
	variable busy ""        ;# check | update | rewind | write: a run is in flight
	variable started 0      ;# the first draw has asked kit
	variable conf {}        ;# notify download install interval, as kit-updater reads them
	variable time 03:00     ;# the install time: kept while the switch is off
	variable hist {}        ;# the history, newest first (kit rewind --tcl)
	variable rplan {}       ;# kit rewind's plan: rows, question (the sheet's); {} when nothing to rewind
	variable sheet 0        ;# the Rewind sheet is open
	variable dd ""          ;# an open dropdown: interval | time
	variable dd_top 0       ;# its scroll, in items
	variable hoff 0         ;# the history's scroll, in rows
	variable woff 0         ;# the waiting list's scroll, in rows
	variable parts          ;# kit | os -> that check's plan ({} when nothing is waiting)
	array set parts {kit {} os {}}
	variable perr           ;# kit | os -> why that check failed
	array set perr {kit "" os ""}
	variable pending 0      ;# checks still running
	variable steps {}       ;# the update's runs still to go: os, kit
	variable results {}     ;# their done dicts
	variable rerrs {}       ;# their failures
	variable kept ""        ;# the last update's failure, kept through the check after it
	variable buf
}

# ---- kit, as a subprocess ------------------------------------------------------------------------------------

proc kupd::kitcmd {} {
	if {[info exists ::env(RIBBON_KIT)]} { return $::env(RIBBON_KIT) }
	set k [auto_execok kit]
	expr {$k eq "" ? {} : [list $k]}
}

proc kupd::updater {} {
	if {[info exists ::env(RIBBON_KIT_UPDATER)]} { return $::env(RIBBON_KIT_UPDATER) }
	set k [auto_execok kit-updater]
	expr {$k eq "" ? [list /usr/lib/ribbon/kit/kit-updater] : [list $k]}
}

# ribbon-update, and what runs it as root
proc kupd::oscmd {} {
	if {[info exists ::env(RIBBON_UPDATE)]} { return $::env(RIBBON_UPDATE) }
	set k [auto_execok ribbon-update]
	expr {$k eq "" ? {} : [list $k]}
}
proc kupd::pkexec {} {
	if {[info exists ::env(RIBBON_UPDATE_PKEXEC)]} { return $::env(RIBBON_UPDATE_PKEXEC) }
	return pkexec
}

# ribbon-update with the arguments ARGL (as root when ROOT), then `DONE code output`. Without ribbon-update (a system
# whose packages are all kits) there is nothing to ask: no plan, no failure.
proc kupd::osrun {root argl done} {
	set o [oscmd]
	if {![llength $o]} { after idle [list {*}$done 0 ""]; return }
	spawn [expr {$root ? [concat [pkexec] $o $argl] : [concat $o $argl]}] $done
}

# Run CMD (a list) in the background, then call `DONE code output` (stderr is in the output).
proc kupd::spawn {cmd done} {
	variable buf
	if {![llength $cmd] || [catch {open |[list {*}$cmd 2>@1] r} ch]} {
		after idle [list {*}$done 127 "kit is not installed"]
		return
	}
	fconfigure $ch -blocking 0 -encoding utf-8
	set buf($ch) ""
	fileevent $ch readable [list kupd::readable $ch $done]
}

proc kupd::readable {ch done} {
	variable buf
	append buf($ch) [read $ch]
	if {![eof $ch]} return
	fileevent $ch readable {}
	fconfigure $ch -blocking 1
	set code 0
	if {[catch {close $ch} msg opts]} {
		set ec [dict get $opts -errorcode]
		set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : 1}]
	}
	set out $buf($ch)
	unset buf($ch)
	{*}$done $code $out
}

# kit's output: {data text}, with the "plan DICT" and "done DICT" lines as data and every other line as text.
proc kupd::parse {out} {
	set data {}; set text {}
	foreach l [split $out \n] {
		if {![catch {llength $l} n] && $n == 2 && [lindex $l 0] in {plan done} && ![catch {dict size [lindex $l 1]}]} {
			lappend data [lindex $l 0] [lindex $l 1]
		} elseif {[string trim $l] ne ""} { lappend text [string trim $l] }
	}
	list $data $text
}

# "kit: network failure" -> "network failure"
proc kupd::reason {text {who kit}} {
	if {![llength $text]} { return [expr {$who eq "os" ? "the system's update failed" : "kit failed"}] }
	regsub {^(?:(?:kit|pkg|ribbon-update): |error )} [lindex $text end] {} r
	return $r
}

# kit's question for a plan's rows (lib/ui.tcl question), the same words for the system's rows
proc kupd::question {rows} {
	set ni 0; set nu 0; set rs 0
	foreach r $rows {
		switch -- [dict get $r action] { install { incr ni } update { incr nu } }
		if {"restart" in [dict get $r tags]} { set rs 1 }
	}
	if {$nu == 0} { set q "Install?" } elseif {$ni == 0} { set q "Update?" } else { set q "Install $ni and update $nu?" }
	if {$rs} { append q " (takes effect at restart)" }
	return $q
}

# ---- the runs -----------------------------------------------------------------------------------------------

# kit check --tcl and ribbon-update --tcl: the waiting list and its question. Nothing is installed.
# KEEP: a failure of the update just done, said until the next check (the list it leaves comes from this one).
proc kupd::check {{keep ""}} {
	variable busy; variable pending; variable kept
	if {$busy ne ""} return
	set busy check
	set kept $keep
	set pending 2
	spawn [concat [kitcmd] {check --tcl}] {kupd::got_part kit}
	osrun 0 --tcl {kupd::got_part os}
	page::draw
}

proc kupd::got_part {who code out} {
	variable parts; variable perr; variable pending
	lassign [parse $out] data text
	set parts($who) {}; set perr($who) ""
	# exit 0 and no plan: "Up to date"
	if {[dict exists $data plan]} { set parts($who) [dict get $data plan] } elseif {$code != 0} { set perr($who) [reason $text $who] }
	if {[incr pending -1] == 0} got_plan
}

# The two plans as one: kit's rows, then the system's; checked is the older check. A check that failed keeps its
# rows from before out of the list and says why in the subtitle; the other's rows still show.
proc kupd::got_plan {} {
	variable busy; variable plan; variable rows; variable checked; variable err; variable parts; variable perr
	set busy ""
	set rows {}; set times {}
	foreach p {kit os} {
		if {$parts($p) eq ""} continue
		lappend rows {*}[dict get $parts($p) rows]
		if {[dict exists $parts($p) checked]} { lappend times [dict get $parts($p) checked] }
	}
	set plan [expr {[llength $rows] ? [dict create rows $rows question [question $rows]] : {}}]
	set checked [expr {[llength $times] ? [tcl::mathfunc::min {*}$times] : [clock seconds]}]
	if {[llength $plan]} { dict set plan checked $checked }
	set err [expr {$perr(kit) ne "" ? $perr(kit) : $perr(os) ne "" ? $perr(os) : $::kupd::kept}]
	page::draw
}

# Update: the system's update (pkexec ribbon-update --tcl --yes), then kit check --tcl --yes (kit's grab), each only
# when its check had something waiting. Then the list is read again.
proc kupd::update {} {
	variable busy; variable plan; variable doneline; variable parts; variable steps; variable results; variable rerrs
	if {$busy ne "" || [llength $plan] == 0} return
	set busy update
	set doneline ""
	set steps {}; set results {}; set rerrs {}
	foreach p {os kit} { if {$parts($p) ne "" && [llength [dict get $parts($p) rows]]} { lappend steps $p } }
	next_step
	page::draw
}

proc kupd::next_step {} {
	variable steps; variable results; variable rerrs
	if {![llength $steps]} {
		finished [expr {[llength $results] ? 0 : 1}] [expr {[llength $results] ? [list done [merge_done $results]] : ""}] [lindex $rerrs 0]
		return
	}
	set steps [lassign $steps p]
	if {$p eq "os"} { osrun 1 {--tcl --yes} {kupd::step_done os} } else { spawn [concat [kitcmd] {check --tcl --yes}] {kupd::step_done kit} }
}

proc kupd::step_done {who code out} {
	variable results; variable rerrs
	lassign [parse $out] data text
	if {[dict exists $data done]} { lappend results [dict get $data done] } elseif {$code != 0} { lappend rerrs [reason $text $who] }
	next_step
}

# The runs' results as one done dict (kit's keys).
proc kupd::merge_done {results} {
	set d [dict create rows {} lines {} stale {} names {} restart {} time 0]
	foreach r $results {
		foreach k {rows lines stale restart} { if {[dict exists $r $k]} { dict lappend d $k {*}[dict get $r $k] } }
		if {[dict exists $r names]} { dict set d names [dict merge [dict get $d names] [dict get $r names]] }
		if {[dict exists $r time] && [dict get $r time] > [dict get $d time]} { dict set d time [dict get $r time] }
	}
	return $d
}

# OUT: a done line (kit's, or the runs' merged); WHY: a failure the result still has to say.
proc kupd::finished {code out {why ""}} {
	variable busy; variable doneline; variable err; variable restart; variable plan; variable rows
	lassign [parse $out] data text
	set busy ""
	if {[dict exists $data done]} {
		set d [dict get $data done]
		set err $why
		set restart [dict get $d restart]
		set doneline "Updated [kits [llength [dict get $d rows]]] · [when [dict get $d time] 1]"
		if {[llength $restart]} { append doneline " · restart to finish" }
		set plan {}; set rows {}
		update_count
		check $why
	} else {
		set err [expr {$why ne "" ? $why : [reason $text]}]
	}
	page::draw
}

# kit rewind --tcl: the history and the plan of the newest change's rewind (kit's cursor).
proc kupd::history {} {
	spawn [concat [kitcmd] {rewind --tcl}] kupd::got_history
}

proc kupd::got_history {code out} {
	variable hist; variable rplan; variable hoff; variable err
	lassign [parse $out] data text
	set hist {}; set rplan {}; set hoff 0
	if {[dict exists $data plan]} {
		set rplan [dict get $data plan]
		if {[dict exists $rplan history]} { set hist [dict get $rplan history] }
		if {[dict exists $rplan rows] && [llength [dict get $rplan rows]] == 0} { set rplan {} }
	} elseif {$code != 0} {
		set err [reason $text]
	}
	page::draw
}

# kit rewind --tcl --yes: the sheet's button. Then the history and the waiting list are read again.
proc kupd::rewind_go {} {
	variable busy
	if {$busy ne ""} return
	set busy rewind
	spawn [concat [kitcmd] {rewind --tcl --yes}] kupd::rewound
	page::draw
}

proc kupd::rewound {code out} {
	variable busy; variable sheet; variable doneline; variable err; variable rplan
	lassign [parse $out] data text
	set busy ""
	set sheet 0
	if {[dict exists $data done]} {
		set d [dict get $data done]
		set err ""
		set doneline "Rewound [kits [llength [dict get $d rows]]] · [when [dict get $d time] 1]"
		set rplan {}
		update_count
		history
		check
	} else {
		set err [reason $text]
	}
	page::draw
}

# ---- the switches: kit-updater --set KEY=VALUE, then the file is read again ----------------------------------

proc kupd::write {k v} {
	variable busy
	if {$busy ne ""} return
	set busy write
	spawn [concat [updater] [list --set $k=$v]] kupd::written
	page::draw
}

proc kupd::written {code out} {
	variable busy; variable err
	set busy ""
	if {$code != 0} { set err [reason [lindex [parse $out] 1]] } else { set err "" }
	read_conf
	page::draw
}

# ~/.config/kit/updates.conf, read as kit-updater reads it: the lines KEY = VALUE it knows, valid ones only.
proc kupd::conf_path {} {
	set base [expr {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""
		? $::env(XDG_CONFIG_HOME) : [file join [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/"}] .config]}]
	file join $base kit updates.conf
}

proc kupd::valid {k v} {
	switch -- $k {
		notify - download { if {[string tolower $v] ni {yes no on off true false 1 0}} { return bad } }
		install { if {$v ne "off" && ![regexp {^([01][0-9]|2[0-3]):[0-5][0-9]$} $v]} { return bad } }
		interval {
			if {[catch {seconds $v} n]} { return bad }
			if {$n < 3600 || $n > 7 * 86400} { return bad }
		}
		default { return bad }
	}
	return ""
}

proc kupd::seconds {v} {
	if {![regexp {^([0-9]+)\s*([smhd]?)$} $v -> n u]} { error "an interval looks like 6h" }
	expr {$n * [dict get {"" 1 s 1 m 60 h 3600 d 86400} $u]}
}

proc kupd::read_conf {} {
	variable conf; variable time
	array set s {notify yes download no install off interval 6h}
	if {![catch {open [conf_path] r} fh]} {
		fconfigure $fh -encoding utf-8
		set text [read $fh]
		close $fh
		foreach line [split $text \n] {
			if {[regexp {^\s*([a-z]+)\s*=\s*(.*?)\s*$} $line -> k v] && [info exists s($k)] && [valid $k $v] eq ""} {
				set s($k) $v
			}
		}
	}
	set conf [array get s]
	if {$s(install) ne "off"} { set time $s(install) }
}

proc kupd::cfg {k} { variable conf; dict get $conf $k }
proc kupd::on {v} { expr {[string tolower $v] in {yes on true 1}} }

# the waiting count for the rail's chip (rail.tcl reads kit's cache the same way)
proc kupd::update_count {} {
	catch { set settings::updates [settings::updates_read] }
}

# The cache file's waiting list, shown until kit's plan arrives (no network needed).
# A key of an entry from kit's cache file, or its default.
proc kupd::dget {d k default} {
	expr {[dict exists $d $k] ? [dict get $d $k] : $default}
}

proc kupd::cache_rows {} {
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/"}]
	set cache [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$home/.cache"}]
	set out {}
	# kit's, then the system's (ribbon-update --tcl leaves its plan in the same form)
	foreach f [list [file join $cache kit updates] [file join $cache ribbon system-updates]] {
		if {![catch {open $f r} fh]} {
			fconfigure $fh -encoding utf-8
			set text [read $fh]
			close $fh
			# kit writes the file as a dict (lib/verbs.tcl saveUpdates): checked, notify, and updates, a list of
			# one dict per waiting kit: name, short, version, new, flags, download. An entry that is not a dict is
			# skipped, and a missing key takes its default, so a damaged or older file never stops the page.
			if {![catch {dict get $text updates} ups]} {
				foreach u $ups {
					if {[catch {dict size $u}]} continue
					set full [kupd::dget $u name ""]
					lappend out [dict create name [kupd::dget $u short $full] fullname $full action update \
						old [kupd::dget $u version ""] new [kupd::dget $u new ""] bytes [kupd::dget $u download 0] \
						tags [kupd::dget $u flags {}] note ""]
				}
			}
		}
	}
	set out
}

# ---- what the page says ----------------------------------------------------------------------------------------

proc kupd::fmtsize {n} {
	if {$n < 1000000} { return "[expr {($n + 999) / 1000}] kB" }
	if {$n < 10000000000} { return "[expr {round($n / 1e6)}] MB" }
	return "[expr {round($n / 1e9)}] GB"
}

proc kupd::total {rows} {
	set n 0
	foreach r $rows {
		if {[dict get $r action] in {install update} && [string is integer -strict [dict get $r bytes]]} { incr n [dict get $r bytes] }
	}
	return $n
}

proc kupd::kits {n} { return "$n kit[expr {$n == 1 ? "" : "s"}]" }

# 14:20 for today (or "today, 14:20" when long), else 6 Nov, 18:42
proc kupd::when {t {long 0}} {
	set hm [clock format $t -format %H:%M]
	if {[clock format $t -format %Y-%m-%d] eq [clock format [clock seconds] -format %Y-%m-%d]} {
		return [expr {$long ? "today, $hm" : $hm}]
	}
	return "[string trim [clock format $t -format {%e %b}]], $hm"
}

proc kupd::subtitle {} {
	variable err; variable busy; variable doneline; variable plan; variable rows; variable checked
	if {$err ne ""} { return $err }
	switch $busy {
		check { return "Checking…" }
		update { return "Updating…" }
		rewind { return "Rewinding…" }
		write { return "Saving…" }
	}
	if {$doneline ne ""} { return $doneline }
	if {$checked eq ""} { return "Checking…" }
	if {[llength $rows]} { return "[llength $rows] waiting · checked [when $checked 1]" }
	return "Up to date · checked [when $checked 1]"
}

# The dropdown's items as {value label ...}: the interval's (kit's values) and the install time, on the hour.
proc kupd::items {which} {
	variable conf
	if {$which eq "time"} {
		set out {}
		for {set h 0} {$h < 24} {incr h} { lappend out [format %02d:00 $h] [format %02d:00 $h] }
		return $out
	}
	set out {1h {1 hour} 3h {3 hours} 6h {6 hours} 12h {12 hours} 1d {1 day} 2d {2 days} 7d {7 days}}
	set cur [cfg interval]
	if {![dict exists $out $cur]} { set out [list $cur $cur {*}$out] }
	return $out
}

proc kupd::label_of {which v} {
	foreach {k l} [items $which] { if {$k eq $v} { return $l } }
	return $v
}

# ---- drawing: header 34, body in the page's columns (270 to 1060), footer rule at 648 (window 720) -------------------------

proc kupd::kcolour {name} { array set c [array get ui::c]; set c($name) }

proc kupd::hit {x y w h cmd} {
	ui::hit $x $y $w $h [list apply {{c x y} { uplevel #0 $c }} $cmd]
}

proc kupd::tile {x y icon} {
	ui::box $x $y 28 28 -fill [kcolour field] -radius 8 -ring [list [kcolour border] 1]
	ui::icon $icon 15 [kcolour fg] [expr {$x + 6.5}] [expr {$y + 6.5}]
}

# a tag, right-aligned at RIGHT; security takes the accent. Returns its left edge.
proc kupd::tag {right top t} {
	set w [expr {14 + [ui::measure i11s $t]}]
	set sec [expr {$t eq "security"}]
	set fill [expr {$sec ? [ui::mix [kcolour bar] [kcolour accent] 0.16] : [kcolour pill]}]
	ui::box [expr {$right - $w}] [expr {$top + 14}] $w 20 -fill $fill -radius 6
	ui::text [expr {$right - $w / 2.0}] [ui::lh [expr {$top + 14}] i11s 20] $t i11s [expr {$sec ? [kcolour accent] : [kcolour muted]}] c
	expr {$right - $w - 6}
}

# A kit row's fields: plan rows have name (kit's short name), old, new, bytes, tags and an optional note; the
# cache's rows are made the same way (cache_rows). LABELY is the section label's top; the rows follow 15 below.
proc kupd::field {r k {default ""}} { expr {[dict exists $r $k] ? [dict get $r $k] : $default} }

# The waiting list: rows of 48 under the label, up to the space above the switches; wheel scrolls by whole rows.
proc kupd::waiting {labely} {
	variable rows; variable woff
	set top [expr {$labely + 15}]
	ui::label 270 $labely "Waiting"
	set maxvis [expr {max(1, (404 - $top) / 48)}]
	set n [llength $rows]
	if {$woff > max(0, $n - $maxvis)} { set woff [expr {max(0, $n - $maxvis)}] }
	set first $woff
	set last [expr {min($n, $first + $maxvis) - 1}]
	ui::wheel 270 $top 790 [expr {48 * $maxvis}] [list kupd::scroll_w]
	for {set i $first} {$i <= $last} {incr i} {
		set r [lindex $rows $i]
		set ry [expr {$top + 48 * ($i - $first)}]
		tile 270 [expr {$ry + 10}] box
		set note [field $r note]
		set tagsx 1060
		foreach t [lreverse [field $r tags]] { set tagsx [tag $tagsx $ry $t] }
		if {$note ne ""} {
			ui::text 310 [ui::lh [expr {$ry + 4}] i13s 22] [field $r name] i13s [kcolour fg]
			ui::text 310 [ui::lh [expr {$ry + 24}] i11s 20] $note i11s [kcolour muted]
		} else {
			ui::text 310 [ui::lh $ry i13s 48] [field $r name] i13s [kcolour fg]
		}
		set ty [ui::lh $ry i13 48]
		set x 708
		if {[field $r old] ne ""} {
			set x [expr {$x + [ui::text $x $ty [field $r old] i13 [kcolour muted]] + 8}]
			set x [expr {$x + [ui::text $x $ty → i13 [kcolour muted]] + 8}]
		}
		ui::text $x $ty [field $r new] i13 [kcolour fg]
		set b [field $r bytes]
		if {[string is integer -strict $b]} { ui::text 954 $ty [fmtsize $b] i13 [kcolour muted] e }
		if {$i < $last} { ui::hline 270 1060 [expr {$ry + 47}] [kcolour border] }
	}
	if {$n > $maxvis} {
		ui::text 1060 [ui::lh [expr {$labely}] i12 20] "[expr {$first + 1}]–[expr {$last + 1}] of $n" i12 [kcolour muted] e
	}
}

proc kupd::scroll_w {d} {
	variable woff; variable rows
	set woff [expr {max(0, min([llength $rows] - 1, $woff + $d))}]
	page::draw
}

proc kupd::scroll_h {d} {
	variable hoff; variable hist
	set hoff [expr {max(0, min([llength $hist] - 1, $hoff + $d))}]
	page::draw
}

# The result's restart card: the kits that take effect at restart, and Restart now (as the bar's panel).
proc kupd::restart_card {labely} {
	variable restart
	ui::label 270 $labely "Restart to finish"
	set y [expr {$labely + 15}]
	ui::box 270 $y 790 56 -fill [kcolour field] -radius 12 -ring [list [kcolour border] 1]
	lassign [lindex $restart 0] name ver
	tile 286 [expr {$y + 14}] box
	ui::text 326 [ui::lh $y i14s 56] "$name $ver" i14s [kcolour fg]
	set w [ui::button_w "Restart now" primary refresh]
	ui::button kupd_restart [expr {1046 - $w}] [expr {$y + 11}] "Restart now" primary kupd::restart_now refresh $w
}

proc kupd::restart_now {} {
	catch { exec loginctl reboot >/dev/null 2>@1 & }
}

# The switches: Notify, Download automatically, Install automatically at (a time and a switch), Check every.
proc kupd::switches {top} {
	variable conf; variable time; variable dd
	ui::label 270 $top "When updates are found"
	set rows {notify {Notify} download {Download automatically} install {Install automatically at} interval {Check every}}
	set y [expr {$top + 15}]
	set i 0
	foreach {k label} $rows {
		set ry [expr {$y + 52 * $i}]
		ui::text 270 [ui::lh $ry i14 52] $label i14 [kcolour fg]
		switch $k {
			notify - download {
				set on [on [cfg $k]]
				ui::toggle 610 [expr {$ry + 15}] $on
				hit 610 [expr {$ry + 15}] 38 22 [list kupd::write $k [expr {$on ? "no" : "yes"}]]
			}
			install {
				set on [expr {[cfg install] ne "off"}]
				set shown [expr {$on ? [cfg install] : $time}]
				ui::box 525 [expr {$ry + 9}] 75 34 -fill [kcolour field] -radius 9
				ui::text 562 [ui::lh [expr {$ry + 9}] i14 34] $shown i14 [kcolour fg] c
				hit 525 [expr {$ry + 9}] 75 34 [list kupd::open_dd time]
				ui::toggle 610 [expr {$ry + 15}] $on
				hit 610 [expr {$ry + 15}] 38 22 [list kupd::write install [expr {$on ? "off" : $time}]]
			}
			interval {
				ui::box 519 [expr {$ry + 9}] 129 34 -fill [kcolour field] -radius 9
				ui::text 533 [ui::lh [expr {$ry + 9}] i14 34] [label_of interval [cfg interval]] i14 [kcolour fg]
				ui::icon chev 13 [kcolour muted] 624 [expr {$ry + 19}] 2
				hit 519 [expr {$ry + 9}] 129 34 [list kupd::open_dd interval]
			}
		}
		if {$i < [llength $rows] / 2 - 1} { ui::hline 270 648 [expr {$ry + 52 - 2}] [kcolour border] }
		incr i
	}
}

# The history: one row of 52 from TOP, newest first; the change kit would take back has its Rewind button.
proc kupd::history_rows {top} {
	variable hist; variable hoff; variable rplan
	set maxvis 5
	set n [llength $hist]
	ui::label 681 $top "History"
	set y [expr {$top + 15}]
	ui::wheel 681 $y 379 [expr {52 * $maxvis}] [list kupd::scroll_h]
	set last [expr {min($n, $hoff + $maxvis) - 1}]
	for {set i $hoff} {$i <= $last} {incr i} {
		set e [lindex $hist $i]
		set ry [expr {$y + 52 * ($i - $hoff)}]
		set next [expr {[dict exists $e cursor] && [dict get $e cursor]}]
		if {$next} { ui::box 673 $ry 395 52 -fill [kcolour field] -radius 10 }
		tile 681 [expr {$ry + 12}] [expr {[dict get $e icon] eq "undo" ? "undo" : "box"}]
		ui::text 721 [ui::lh [expr {$ry + 8}] i13s 20] [dict get $e title] i13s [kcolour fg]
		ui::text 721 [ui::lh [expr {$ry + 28}] i12 18] [kupd::fit_text i12 [dict get $e sub] 220] i12 [kcolour muted]
		if {$next && [llength [rplan_rows]]} {
			set w [ui::button_w Rewind ghost undo]
			ui::button kupd_rewind [expr {1060 - $w}] [expr {$ry + 9}] Rewind ghost kupd::rewind_open undo $w
		} else {
			ui::text 1060 [ui::lh [expr {$ry + 17}] i12 18] [when [dict get $e time]] i12 [kcolour muted] e
		}
	}
	if {$n == 0} { ui::text 681 [ui::lh $y i13 48] "No changes yet" i13 [kcolour muted] }
}

# A text cut to W px, with an ellipsis.
proc kupd::fit_text {f s w} {
	if {[ui::measure $f $s] <= $w} { return $s }
	while {[string length $s] > 1 && [ui::measure $f "$s…"] > $w} { set s [string range $s 0 end-1] }
	return "$s…"
}

# kit rewind's plan rows; {} when there is nothing to rewind (kit prints no plan then)
proc kupd::rplan_rows {} {
	variable rplan
	if {[dict exists $rplan rows]} { return [dict get $rplan rows] }
	return {}
}

proc kupd::rewind_open {} {
	variable sheet
	if {![llength [rplan_rows]]} return
	set sheet 1
	page::draw
}

proc kupd::sheet_close {} {
	variable sheet
	set sheet 0
	page::draw
}

proc kupd::open_dd {which} {
	variable dd; variable dd_top
	set dd [expr {$dd eq $which ? "" : $which}]
	set dd_top 0
	page::draw
}

proc kupd::pick {which v} {
	variable dd; variable time
	set dd ""
	if {$which eq "time"} {
		set time $v
		write install $v
	} else {
		write interval $v
	}
}

# The open dropdown, over the page: its items above the field, six at a time, and a click elsewhere closes it.
proc kupd::dropdown {} {
	variable dd; variable dd_top; variable time
	set items [items $dd]
	set n [expr {[llength $items] / 2}]
	# the field each list opens from (its box on the switches: the time at 525, the interval at 519)
	if {$dd eq "time"} {
		set fx 525; set fy 540; set fw 75
		set cur [expr {[cfg install] ne "off" ? [cfg install] : $time}]
	} else {
		set fx 519; set fy 592; set fw 129
		set cur [cfg interval]
	}
	set w [expr {max($fw, 120)}]
	set x [expr {$fx + $fw - $w}]
	set vis [expr {min(6, $n)}]
	set h [expr {32 * $vis + 8}]
	set top [expr {$fy - 6 - $h}]
	if {$dd_top > $n - $vis} { set dd_top [expr {max(0, $n - $vis)}] }
	ui::layer
	ui::hit 0 0 1100 720 [list apply {{c x y} { uplevel #0 $c }} "kupd::open_dd $dd"]
	ui::box $x $top $w $h -fill [kcolour bar] -radius 10 -ring [list [kcolour border] 1]
	ui::wheel $x $top $w $h [list kupd::scroll_dd]
	for {set i 0} {$i < $vis} {incr i} {
		set k [lindex $items [expr {2 * ($dd_top + $i)}]]
		set l [lindex $items [expr {2 * ($dd_top + $i) + 1}]]
		set iy [expr {$top + 4 + 32 * $i}]
		set on [expr {$k eq $cur}]
		if {$on} { ui::box [expr {$x + 4}] $iy [expr {$w - 8}] 32 -fill [kcolour field] -radius 7 }
		ui::text [expr {$x + 14}] [ui::lh $iy [expr {$on ? "i13s" : "i13m"}] 32] $l [expr {$on ? "i13s" : "i13m"}] [kcolour fg]
		hit [expr {$x + 4}] $iy [expr {$w - 8}] 32 [list kupd::pick $dd $k]
	}
}

proc kupd::scroll_dd {d} {
	variable dd; variable dd_top
	set n [expr {[llength [items $dd]] / 2}]
	set dd_top [expr {max(0, min($n - 6, $dd_top + $d))}]
	page::draw
}

# The Rewind sheet (Settings-A3b-Rewind): the page shaded, a 640 px sheet with kit's plan and its question.
proc kupd::sheet {} {
	variable rplan; variable hist
	ui::layer
	ui::hit 0 0 1100 720 [list apply {{c x y} { uplevel #0 $c }} "kupd::noop"]
	ui::fbox 0 0 1100 720 -fill #000000 -alpha 0.35
	set sx 230; set sy 190
	ui::box $sx $sy 640 400 -fill [kcolour bar] -radius 16 -ring [list [kcolour border] 1]
	ui::box [expr {$sx + 28}] [expr {$sy + 28}] 44 44 -fill [kcolour field] -radius 12 -ring [list [kcolour border] 1]
	ui::icon undo 22 [kcolour fg] [expr {$sx + 39}] [expr {$sy + 39}]
	ui::text [expr {$sx + 86}] [ui::lh [expr {$sy + 26}] sg22 30] Rewind sg22 [kcolour fg] w -0.44
	set e [lindex $hist 0]
	set sub [expr {$e eq "" ? "" : "[dict get $e title] · [when [dict get $e time] 1]"}]
	ui::text [expr {$sx + 86}] [ui::lh [expr {$sy + 58}] i14 22] $sub i14 [kcolour muted]
	set y [expr {$sy + 88}]
	set rows [rplan_rows]
	set n 0
	foreach r $rows {
		if {$n == 5} break
		set ry [expr {$y + 48 * $n}]
		tile [expr {$sx + 28}] [expr {$ry + 10}] box
		ui::text [expr {$sx + 68}] [ui::lh $ry i13s 48] [field $r name] i13s [kcolour fg]
		set x [expr {$sx + 224}]
		set ty [ui::lh $ry i13 48]
		if {[field $r old] ne ""} {
			set x [expr {$x + [ui::text $x $ty [field $r old] i13 [kcolour muted]] + 8}]
			set x [expr {$x + [ui::text $x $ty → i13 [kcolour muted]] + 8}]
		}
		ui::text $x $ty [field $r new] i13 [kcolour fg]
		set tx [expr {$sx + 612}]
		foreach t [lreverse [field $r tags]] { set tx [tag $tx $ry $t] }
		if {$n < [llength $rows] - 1 && $n < 4} { ui::hline [expr {$sx + 28}] [expr {$sx + 612}] [expr {$ry + 47}] [kcolour border] }
		incr n
	}
	set fy [expr {$sy + 328}]
	ui::hline [expr {$sx + 28}] [expr {$sx + 612}] $fy [kcolour border]
	set total [total $rows]
	ui::text [expr {$sx + 28}] [ui::lh [expr {$fy + 22}] i13 38] [expr {$total == 0 ? "No download" : "Download [fmtsize $total]"}] i13 [kcolour muted]
	set bx [expr {$sx + 612}]
	set q [dict get $rplan question]
	set w [ui::button_w $q primary]
	set bx [expr {$bx - $w}]
	ui::button kupd_rewind_go $bx [expr {$fy + 22}] $q primary kupd::rewind_go "" $w
	set w [ui::button_w Cancel ghost]
	set bx [expr {$bx - 10 - $w}]
	ui::button kupd_cancel $bx [expr {$fy + 22}] Cancel ghost kupd::sheet_close "" $w
}

proc kupd::noop {} {}

# The page. The first draw asks kit for the plan and the history, and reads the switches.
proc settings::draw_updates {} {
	variable ::kupd::rows; variable ::kupd::started; variable ::kupd::plan; variable ::kupd::restart
	variable ::kupd::sheet; variable ::kupd::dd; variable ::kupd::err
	if {!$started} {
		set started 1
		kupd::read_conf
		if {[llength $rows] == 0} { set rows [kupd::cache_rows] }
		kupd::check
		kupd::history
	}
	array set c [array get ui::c]
	ui::text 270 34 Updates sg28 $c(fg) w -0.56
	ui::text 270 [ui::lh 76 i14 21] [kupd::subtitle] i14 [expr {$err ne "" ? $c(fg) : $c(muted)}]
	set top 126
	if {[llength $restart]} {
		kupd::restart_card $top
		set top 206
	}
	kupd::waiting $top
	kupd::switches 412
	kupd::history_rows 412
	ui::hline 230 1100 648 $c(border)
	# the footer: what it will download, Check now, and the question as the primary button
	if {[llength $rows]} {
		ui::text 270 [ui::lh 665 i13 38] "Download [kupd::fmtsize [kupd::total $rows]]" i13 $c(muted)
	}
	set bx 1060
	if {[llength $plan]} {
		set q [dict get $plan question]
		set w [ui::button_w $q primary]
		set bx [expr {$bx - $w}]
		ui::button kupd_update $bx 665 $q primary kupd::update "" $w
		set bx [expr {$bx - 10}]
	}
	set w [ui::button_w "Check now" ghost refresh]
	ui::button kupd_check [expr {$bx - $w}] 665 "Check now" ghost kupd::check refresh $w
	if {$dd ne ""} { kupd::dropdown }
	if {$sheet} { kupd::sheet }
}
