# updates.tcl - the updates panel that hangs from the bar's chip (design/tools/gen_kitui.py, boards
# Kit-Bar-2 Panel, 3 Done, 4 History, 5 Rewind): kit's plan as a sheet, the same plan and the same question
# `kit check` prints, and the button carries the question.
#
# The panel is the prompt. It never works out a plan or switches anything itself: it runs kit, as a
# subprocess, with the GUI-only flag --tcl (docs/KIT-CLI.md, scripting), which prints the plan or the result as
# one Tcl list per line:
#     kit check --tcl            plan {rows ... question ... checked ...}     (nothing is done)
#     kit check --tcl --yes      done {rows ... stale ... restart ... time ...}  (the grab, kit's own transaction)
#     kit rewind --tcl           plan {rows ... question ... history {...}}    (nothing is done)
#     kit rewind --tcl --yes     done {...}
# So installing and rewinding are kit's one machinery, whichever front end asks.
#
# The operating system's own packages (the base's, "phase now" of docs/SYSTEM-UPDATES.md §7.10) are ribbon-update's,
# which speaks the same --tcl: `ribbon-update --tcl` gives its plan (no root, nothing done), and
# `pkexec ribbon-update --tcl --yes` does it (a snapshot first) and prints the same done line. The panel asks both
# and shows one plan, kit's rows then the system's, with kit's question for all of them; the button runs the
# system's update first, then kit's grab, and Done shows both results. Rewind and History stay kit's.
#
# Pages: the plan (Update? with Cancel), the result (Done: what switched, "Still running old versions" with
# Restart, "Restart to finish"), History (newest first, Rewind on the change kit would take back), Rewind
# (its plan). While kit works the primary button stays as it is, dimmed: the boards draw no progress.
# Layout is the boards' (generator constants in CSS px): padding 20, a 74 header, 48 rows, a 60 footer.
#
# RIBBON_KIT names the kit command (a Tcl list) when it is not `kit` on the PATH, RIBBON_UPDATE ribbon-update and
# RIBBON_UPDATE_PKEXEC what runs it as root (pkexec): for tests.

namespace eval upd {
	variable page ""         ;# plan | done | history | rewind
	variable back plan       ;# the page History's back tile returns to
	variable busy 0          ;# kit is working: the buttons are dimmed and inert
	variable loading 0       ;# the plan is being fetched; the panel opens when it arrives
	variable kind update     ;# what the busy or finished run is: update | rewind
	variable plan {}         ;# the plan shown: kit's rows, then the system's; kit's question for them; checked
	variable parts           ;# kit | os -> that check's plan ({} when it has nothing waiting)
	array set parts {kit {} os {}}
	variable pending 0       ;# checks still running
	variable perr            ;# kit | os -> why that check failed
	array set perr {kit "" os ""}
	variable steps {}        ;# the update's runs still to go: os, kit
	variable results {}      ;# their done dicts
	variable rerrs {}        ;# their failures
	variable done {}         ;# the result: rows lines stale restart time
	variable hist {}         ;# the history, newest first (kit rewind --tcl)
	variable rplan {}        ;# kit rewind's plan for the newest change
	variable err ""          ;# why the last run failed, shown where the subtitle is
	variable hover 0         ;# the history row under the pointer
	variable buf
	variable pad 20
	variable rects           ;# label -> {x0 y0 x1 y1} of the buttons drawn last (tests/shell-updates.tcl clicks them)
	array set rects {}
}

# ---- talking to kit --------------------------------------------------------------------------------------

proc upd::kit {} {
	if {[info exists ::env(RIBBON_KIT)]} { return $::env(RIBBON_KIT) }
	set k [auto_execok kit]
	expr {$k eq "" ? {} : [list $k]}
}

# Run kit with ARGS in the background, then call `cmd code output` (stderr is in the output).
proc upd::spawn {args cmd} {
	variable buf
	set k [kit]
	if {![llength $k] || [catch {open |[list {*}$k {*}$args 2>@1] r} ch]} {
		after idle [list {*}$cmd 127 "kit is not installed"]
		return
	}
	fconfigure $ch -blocking 0 -encoding utf-8
	set buf($ch) ""
	fileevent $ch readable [list upd::readable $ch $cmd]
}

# ribbon-update, and what runs it as root
proc upd::os {} {
	if {[info exists ::env(RIBBON_UPDATE)]} { return $::env(RIBBON_UPDATE) }
	set k [auto_execok ribbon-update]
	expr {$k eq "" ? {} : [list $k]}
}
proc upd::pkexec {} {
	if {[info exists ::env(RIBBON_UPDATE_PKEXEC)]} { return $::env(RIBBON_UPDATE_PKEXEC) }
	return pkexec
}

# Run ribbon-update with the arguments ARGL (as root when ROOT), then `cmd code output`. Without ribbon-update (a system whose
# packages are all kits) there is nothing to ask: no plan, no failure.
proc upd::osrun {root argl cmd} {
	variable buf
	set o [os]
	if {![llength $o]} { after idle [list {*}$cmd 0 ""]; return }
	set c [expr {$root ? [concat [pkexec] $o $argl] : [concat $o $argl]}]
	if {[catch {open |[list {*}$c 2>@1] r} ch]} { after idle [list {*}$cmd 127 "ribbon-update: $ch"]; return }
	fconfigure $ch -blocking 0 -encoding utf-8
	set buf($ch) ""
	fileevent $ch readable [list upd::readable $ch $cmd]
}

proc upd::readable {ch cmd} {
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
	{*}$cmd $code $out
}

# kit's output: {data text}, the "plan DICT" and "done DICT" lines as a dict, then every other line
proc upd::parse {out} {
	set data {}; set text {}
	foreach l [split $out \n] {
		if {![catch {llength $l} n] && $n == 2 && [lindex $l 0] in {plan done} && ![catch {dict size [lindex $l 1]}]} {
			lappend data [lindex $l 0] [lindex $l 1]
		} elseif {[string trim $l] ne ""} { lappend text [string trim $l] }
	}
	list $data $text
}

# "kit: network failure" -> "network failure" (and ribbon-update's "error ...", the seam's "pkg: ...")
proc upd::reason {text {who kit}} {
	if {![llength $text]} { return [expr {$who eq "os" ? "the system's update failed" : "kit failed"}] }
	regsub {^(?:(?:kit|pkg|ribbon-update): |error )} [lindex $text end] {} r
	return $r
}

# kit's question for a plan's rows (lib/ui.tcl question): Install?, Update?, Install N and update M?, and
# " (takes effect at restart)" when a row carries restart
proc upd::question {rows} {
	set ni 0; set nu 0; set rs 0
	foreach r $rows {
		switch -- [dict get $r action] { install { incr ni } update { incr nu } }
		if {"restart" in [dict get $r tags]} { set rs 1 }
	}
	if {$nu == 0} { set q "Install?" } elseif {$ni == 0} { set q "Update?" } else { set q "Install $ni and update $nu?" }
	if {$rs} { append q " (takes effect at restart)" }
	return $q
}

# The plan shown: kit's rows, then the system's, one question; checked is the older of the two checks.
proc upd::merge {} {
	variable parts
	set rows {}; set checked {}
	foreach p {kit os} {
		if {$parts($p) eq ""} continue
		lappend rows {*}[dict get $parts($p) rows]
		if {[dict exists $parts($p) checked]} { lappend checked [dict get $parts($p) checked] }
	}
	if {![llength $rows]} { return {} }
	dict create rows $rows question [question $rows] checked [expr {[llength $checked] ? [tcl::mathfunc::min {*}$checked] : [clock seconds]}]
}

# The results of the runs as one done dict (kit's keys): rows, lines, stale, names and restart of each, the last time.
proc upd::merge_done {results} {
	set d [dict create rows {} lines {} stale {} names {} restart {} time 0]
	foreach r $results {
		foreach k {rows lines stale restart} { if {[dict exists $r $k]} { dict lappend d $k {*}[dict get $r $k] } }
		if {[dict exists $r names]} { dict set d names [dict merge [dict get $d names] [dict get $r names]] }
		if {[dict exists $r time] && [dict get $r time] > [dict get $d time]} { dict set d time [dict get $r time] }
	}
	return $d
}

# ---- opening, going, going back -------------------------------------------------------------------------

# The chip's click: the plan (kit check --tcl) arrives, then the panel opens under the chip. Work in
# progress, or a result nobody has dismissed yet, is shown as it is.
proc upd::toggle {} {
	variable page
	variable busy
	variable loading
	if {$panel::open eq "updates"} { panel::close; return }
	if {$loading} return
	launcher::cancel
	if {$busy || $page eq "done"} { panel::show updates; return }
	set loading 1
	check_all
}

# Both checks, kit's and the system's; the plan page opens when both have answered.
proc upd::check_all {} {
	variable pending
	set pending 2
	spawn {check --tcl} {upd::got_part kit}
	osrun 0 --tcl {upd::got_part os}
}

proc upd::got_part {who code out} {
	variable parts; variable perr; variable pending
	lassign [parse $out] data text
	set parts($who) {}; set perr($who) ""
	if {[dict exists $data plan]} { set parts($who) [dict get $data plan] } elseif {$code != 0} { set perr($who) [reason $text $who] }
	if {[incr pending -1] == 0} got_plan
}

proc upd::got_plan {} {
	variable page; variable loading; variable plan; variable err; variable perr
	set loading 0
	set plan [merge]
	set err [expr {$perr(kit) ne "" ? $perr(kit) : $perr(os)}]
	set page plan
	panel::show updates
}

# The panel's primary button on the plan page: the system's update (pkexec ribbon-update --tcl --yes), then
# kit check --tcl --yes, each only when its check had something waiting.
proc upd::go {} {
	variable page; variable busy; variable kind; variable parts; variable steps; variable results; variable rerrs
	if {$busy || $page ne "plan"} return
	set busy 1; set kind update
	set steps {}; set results {}; set rerrs {}
	foreach p {os kit} { if {$parts($p) ne "" && [llength [dict get $parts($p) rows]]} { lappend steps $p } }
	next_step
	again
}

proc upd::next_step {} {
	variable steps; variable results; variable rerrs
	if {![llength $steps]} {
		# all done: one result, or the first failure where the subtitle is
		set out [expr {[llength $results] ? [list done [merge_done $results]] : ""}]
		finished [expr {[llength $results] ? 0 : 1}] $out [lindex $rerrs 0]
		return
	}
	set steps [lassign $steps p]
	if {$p eq "os"} { osrun 1 {--tcl --yes} {upd::step_done os} } else { spawn {check --tcl --yes} {upd::step_done kit} }
}

proc upd::step_done {who code out} {
	variable results; variable rerrs
	lassign [parse $out] data text
	# exit 0 with no result: nothing was left to do by now ("Up to date")
	if {[dict exists $data done]} { lappend results [dict get $data done] } elseif {$code != 0} { lappend rerrs [reason $text $who] }
	next_step
}

proc upd::rewind_go {} {
	variable page; variable busy; variable kind
	if {$busy || $page ne "rewind"} return
	set busy 1; set kind rewind
	spawn {rewind --tcl --yes} upd::finished
	again
}

# The result: OUT is a done line (kit's or the merged one); WHY a failure the result still has to say.
proc upd::finished {code out {why ""}} {
	variable page; variable busy; variable done; variable err; variable hist
	lassign [parse $out] data text
	set busy 0
	if {[dict exists $data done]} {
		set done [dict get $data done]
		set err $why
		set page done
	} else {
		# no board for a failure: back where it was, the reason in the subtitle's place
		set err [expr {$why ne "" ? $why : [reason $text]}]
	}
	status::updates_read
	# the system's waiting list is read again, so its cache file (the chip's count) no longer has what was done
	if {$upd::kind eq "update"} { osrun 0 --tcl {apply {{code out} { status::updates_read }}} }
	again
}

proc upd::again {} { if {$panel::open eq "updates"} { panel::draw } }

# History: kit rewind --tcl lists the changes and plans the newest one's rewind.
proc upd::history {} {
	variable page; variable back; variable busy
	if {$busy} return
	if {$page in {plan done}} { set back $page }
	spawn {rewind --tcl} upd::got_history
}

proc upd::got_history {code out} {
	variable page; variable hist; variable rplan; variable hover; variable err
	lassign [parse $out] data text
	set hist {}; set rplan {}; set hover 0
	if {[dict exists $data plan]} {
		set rplan [dict get $data plan]
		if {[dict exists $rplan history]} { set hist [dict get $rplan history] }
	} elseif {$code != 0} { set err [reason $text] ; return }
	set page history
	again
}

proc upd::rewind_page {} {
	variable page; variable rplan
	if {$rplan eq ""} return
	set page rewind
	again
}

proc upd::back_page {} {
	variable page; variable back; variable busy
	if {$busy} return
	set page [expr {$page eq "rewind" ? "history" : $back}]
	again
}

proc upd::cancel {} {
	variable page; variable busy
	if {$busy} return
	if {$page eq "rewind"} { back_page } else { panel::close }
}

# Called by panel::close: a result, History or Rewind nobody is waiting for any more is forgotten.
proc upd::closed {} {
	variable page; variable busy
	if {!$busy && $page in {done history rewind}} { set page "" }
}

# Restart an app that still runs an old version: its windows are closed, then kit starts it again.
proc upd::restart_app {short} {
	variable done
	foreach id [wm::windows] {
		if {[string match -nocase *$short* [wm::get $id app]]} { wm::send close $id }
	}
	after 1200 [list apps::run "[join [lmap w [kit] { apps::shellquote $w }]] run [apps::shellquote $short]"]
	set stale [expr {[dict exists $done stale] ? [dict get $done stale] : {}}]
	dict set done stale [lsearch -all -inline -not -index 0 -exact $stale $short]
	again
}

proc upd::restart_now {} { apps::run "loginctl reboot" }

proc upd::hover_at {x y} {
	variable page; variable hist; variable hover
	if {$page ne "history"} return
	set i [expr {int(floor(($y - 80) / 52.0))}]
	if {$i < 0 || $i >= [llength $hist]} return
	if {$i != $hover} { set hover $i; panel::draw }
}

# ---- what the pages say -------------------------------------------------------------------------------------

# 12 MB, 340 kB: kit's own (core.tcl fmtsize)
proc upd::fmtsize {n} {
	if {$n < 1000000} { return "[expr {($n + 999) / 1000}] kB" }
	if {$n < 10000000000} { return "[expr {round($n / 1e6)}] MB" }
	return "[expr {round($n / 1e9)}] GB"
}

proc upd::total {rows} {
	set n 0
	foreach r $rows {
		if {[dict get $r action] in {install update} && [string is integer -strict [dict get $r bytes]]} { incr n [dict get $r bytes] }
	}
	return $n
}

# the app's own icon when the launcher knows it, else the box (kits that are not apps)
proc upd::icon {short} {
	set i [apps::iconfor "" $short]
	expr {$i eq "grid" ? "pkg" : $i}
}

# 14:20 for today (or "today, 14:20" when long), else 6 Nov, 18:42
proc upd::when {t {long 0}} {
	set hm [clock format $t -format %H:%M]
	if {[clock format $t -format %Y-%m-%d] eq [clock format [clock seconds] -format %Y-%m-%d]} {
		return [expr {$long ? "today, $hm" : $hm}]
	}
	return "[string trim [clock format $t -format {%e %b}]], $hm"
}

proc upd::kits {n} { return "$n kit[expr {$n == 1 ? "" : "s"}]" }

# ---- drawing ---------------------------------------------------------------------------------------------------
# Everything below is laid out from the panel's left edge at 0 and top at 0 (the popup's), x from `pad`; the body starts at y 74, where the header's rule overlays its first pixel.

proc upd::draw {} {
	variable page; variable plan; variable done; variable hist; variable rplan; variable err; variable busy
	variable pad
	array set c [array get theme::c]
	set W $bar::rightw
	set X $bar::rightx
	set R [expr {$W - $pad}]
	set rows {}
	switch $page {
		plan { if {$plan ne ""} { set rows [dict get $plan rows] } }
		rewind { set rows [dict get $rplan rows] }
		done { set rows [dict get $done rows] }
		history { set rows $hist }
	}
	# height: the header, the rule and the body, then the footer
	set body 0
	switch $page {
		plan - rewind { set body [rowsh $rows] }
		done {
			set body [expr {48 * [llength $rows]}]
			set stale [dict get $done stale]
			if {[llength $stale]} { incr body [expr {16 + 21 - 2 + 48 * [llength $stale]}] }
		}
		history { set body [expr {12 + 52 * [llength $rows]}] }
	}
	set foot 1
	if {$page eq "plan" && $plan eq ""} { set foot 0 }
	if {$page eq "done" && ![llength [dict get $done restart]]} { set foot 0 }
	set fy [expr {74 + $body}]
	set H [expr {$fy + ($foot ? 60 : 8)}]
	panel::surface
	set d .panel.c
	$d delete all
	$d configure -background $c(BAR)
	set panel::hits {}; set panel::sliders {}
	array unset upd::rects

	# the header
	switch $page {
		plan {
			if {$plan eq ""} { set sub [expr {$err ne "" ? $err : "Up to date"}] } else {
				set sub "[llength $rows] waiting · checked [clock format [dict get $plan checked] -format %H:%M]"
				if {$err ne ""} { set sub $err }
			}
			head $d $W up Updates $sub [list History clock upd::history]
		}
		done {
			set sub "[kits [llength $rows]] · [when [dict get $done time] 1]"
			if {$err ne ""} { set sub $err }
			head $d $W check [expr {$upd::kind eq "rewind" ? "Rewound" : "Updated"}] $sub [list History clock upd::history]
		}
		history { head $d $W back History "[llength $rows] change[expr {[llength $rows] == 1 ? "" : "s"}]" "" }
		rewind {
			set e [lindex $hist 0]
			set sub [expr {$err ne "" ? $err : "[dict get $e title] · [when [dict get $e time] 1]"}]
			head $d $W back Rewind $sub ""
		}
	}
	$d create rectangle $pad 74 $R 75 -fill $c(BORDER) -width 0

	# the body
	switch $page {
		plan - rewind { planrows $d $W $rows [expr {$page eq "plan"}] }
		done { donerows $d $W $rows [dict get $done restart] [dict get $done stale] [expr {[dict exists $done names] ? [dict get $done names] : {}}] }
		history { histrows $d $W $rows }
	}

	# the footer: a rule across the panel, what it will cost on the left, the buttons on the right
	if {$foot} {
		$d create rectangle 0 $fy $W [expr {$fy + 1}] -fill $c(BORDER) -width 0
		set by [expr {$fy + 13}]
		set x $R
		switch $page {
			plan {
				set q [dict get $plan question]
				foot_text $d $fy "Download [fmtsize [total $rows]]"
				set x [expr {$x - [button $d [expr {$x - [bwidth $q primary "" [tail $q]]}] $by $q primary "" [tail $q] upd::go $c(BAR)]}]
				button $d [expr {$x - 8 - [bwidth Cancel ghost "" ""]}] $by Cancel ghost "" "" upd::cancel $c(BAR)
			}
			rewind {
				set q [dict get $rplan question]
				foot_text $d $fy [expr {[total $rows] == 0 ? "No download" : "Download [fmtsize [total $rows]]"}]
				set x [expr {$x - [button $d [expr {$x - [bwidth $q primary "" ""]}] $by $q primary "" "" upd::rewind_go $c(BAR)]}]
				button $d [expr {$x - 8 - [bwidth Cancel ghost "" ""]}] $by Cancel ghost "" "" upd::cancel $c(BAR)
			}
			done {
				foot_text $d $fy "Restart to finish"
				set x [expr {$x - [button $d [expr {$x - [bwidth "Restart now" primary restart ""]}] $by "Restart now" primary restart "" upd::restart_now $c(BAR)]}]
				button $d [expr {$x - 8 - [bwidth Later ghost "" ""]}] $by Later ghost "" "" panel::close $c(BAR)
			}
			history {
				# Settings → Updates (the full history) is not built yet: the button waits for it
				button $d [expr {$x - [bwidth "All history" ghost ext ""]}] $by "All history" ghost ext "" upd::all_history $c(BAR)
			}
		}
	}
	rbn::popup .panel [expr {int($X)}] [expr {$bar::Y0 + 54}] $W $H [theme::look pop -radius {0 0 12 12} -ring [list $c(BORDER) 1 lrb]] -clip t
}

# "(takes effect at restart)" is the tail of the question, in 500 at 72 %
proc upd::tail {q} {
	if {[regexp {^(.*?) (\(takes effect at restart\))$} $q -> - t]} { return $t }
	return ""
}

# The question without its tail: the word in 600, the tail beside it
proc upd::head_of {q} { regsub { \(takes effect at restart\)$} $q {} q; return $q }

proc upd::foot_text {d fy text} {
	variable pad
	text::draw $d $pad [expr {$fy + 30}] f13 $theme::c(MUTED) $text w -tnum 1
}

# the header: a 44 tile (the page's icon, or the way back), the title in Space Grotesk 20, the line under it,
# and the compact field button on the right
proc upd::head {d W icon title sub {btn {}}} {
	variable pad
	array set c [array get theme::c]
	if {$icon eq "back"} {
		rbn::box $d $pad 14 44 44 -fill $c(FIELD) -radius 12 -ring [list $c(BORDER) 1] -on $c(BAR)
		bar::icon $d left 20 2 $c(FG) [expr {$pad + 12}] 26
		lappend panel::hits [list $pad 14 [expr {$pad + 44}] 58 upd::back_page]
	} else {
		tile $d $pad 14 44 12 $icon 22
	}
	text::draw $d [expr {$pad + 58}] 26 f20g $c(FG) $title w -ls -0.4
	text::draw $d [expr {$pad + 58}] 49 f13 [expr {$upd::err ne "" && $sub eq $upd::err ? $c(FG) : $c(MUTED)}] [bar::clip f13 $sub [expr {$W - $pad * 2 - 58 - 110}]] w -tnum 1
	if {[llength $btn]} {
		lassign $btn label icon cmd
		set w [bwidth $label field $icon ""]
		button $d [expr {$W - $pad - $w}] 19 $label field $icon "" $cmd $c(BAR)
	}
}

# a 1 px ringed tile with its icon, in the sheet's gradient's middle
proc upd::tile {d x y size r icon isz} {
	array set c [array get theme::c]
	rbn::box $d $x $y $size $size -fill [bar::mix $c(PILL) $c(FIELD) 0.5] -radius $r -ring [list $c(BORDER) 1] -on $c(BAR)
	bar::icon $d $icon $isz 1.7 $c(FG) [expr {$x + ($size - $isz) / 2.0}] [expr {$y + ($size - $isz) / 2.0}]
}

# ---- buttons: compact, 34 tall, radius 9, 13 px (STYLE §10) --------------------------------------------------
# kinds: primary (the accent, 600, one per page), ghost (a ring), field (a fill). In flight a primary is
# dimmed and nothing answers clicks.

proc upd::bwidth {label kind icon tail} {
	set w [expr {28 + [text::width [expr {$kind eq "primary" ? "f13s" : "f13m"}] [head_of $label]]}]
	if {$tail ne ""} { set w [expr {$w + 7 + [text::width f13m $tail]}] }
	if {$icon ne ""} { set w [expr {$w + 7 + 13}] }
	return $w
}

# Draws the button with its left edge at x; returns its width. cmd "" draws it without an action.
proc upd::button {d x y label kind icon tail cmd on} {
	variable busy
	array set c [array get theme::c]
	set label [head_of $label]
	set w [bwidth $label $kind $icon $tail]
	set ::upd::rects($label) [list $x $y [expr {$x + $w}] [expr {$y + 34}]]
	switch $kind {
		primary {
			set fill [expr {$busy ? [bar::mix $c(BAR) $c(ACCENT) 0.5] : $c(ACCENT)}]
			rbn::box $d $x $y $w 34 -fill $fill -radius 9 -on $on
			set col $c(ON_ACCENT); set font f13s
		}
		ghost {
			rbn::box $d $x $y $w 34 -fill $on -radius 9 -ring [list $c(BORDER) 1] -on $on
			set col [expr {$busy ? $c(MUTED) : $c(FG)}]; set font f13m
		}
		field {
			rbn::box $d $x $y $w 34 -fill $c(FIELD) -radius 9 -on $on
			set col $c(FG); set font f13m
		}
	}
	set tx [expr {$x + 14}]
	set tx [expr {$tx + [text::draw $d $tx [expr {$y + 17}] $font $col $label w]}]
	if {$tail ne ""} {
		text::draw $d [expr {$tx + 7}] [expr {$y + 17}] f13m [bar::mix $c(ACCENT) $c(ON_ACCENT) 0.72] $tail w
		set tx [expr {$tx + 7 + [text::width f13m $tail]}]
	}
	if {$icon ne ""} { bar::icon $d $icon 13 2 $col [expr {$tx + 7}] [expr {$y + 10.5}] }
	if {$cmd ne "" && !($busy && $kind in {primary ghost})} { lappend panel::hits [list $x $y [expr {$x + $w}] [expr {$y + 34}] $cmd] }
	return $w
}

# ---- the plan: name, from → to, size, tags --------------------------------------------------------------------
proc upd::planrows {d W rows sizes} {
	variable pad
	array set c [array get theme::c]
	set R [expr {$W - $pad}]
	set tags 0
	foreach r $rows { if {[llength [dict get $r tags]]} { set tags 1 } }
	# the columns, from the right with 12 apart: tags 76 (only when some row has one), size 48 (the column
	# is there without sizes, empty), versions 150
	set right $R
	if {$tags} { set tagx [expr {$R - 76}]; set right [expr {$tagx - 12}] }
	set sizex $right
	set right [expr {$right - ($sizes ? 48 : 0) - 12}]
	set verx [expr {$right - 150}]
	set n 0
	set ry 74
	foreach r $rows {
		set h [rowh $r]
		tile $d $pad [expr {$ry + 10}] 28 8 [icon [expr {[dict exists $r short] ? [dict get $r short] : [dict get $r name]}]] 15
		text::draw $d [expr {$pad + 40}] [expr {$ry + 24}] f13s $c(FG) [bar::clip f13s [dict get $r name] [expr {$verx - $pad - 52}]] w
		# from → to
		set x $verx
		set vy [expr {$ry + 24}]
		switch [dict get $r action] {
			install {
				set x [expr {$x + 8 + [text::draw $d $x $vy f13 $c(MUTED) new w -tnum 1]}]
				text::draw $d $x $vy f13 $c(FG) [dict get $r new] w -tnum 1
			}
			remove {
				set x [expr {$x + 6 + [text::draw $d $x $vy f13 $c(MUTED) [dict get $r old] w -tnum 1]}]
				set x [expr {$x + 6 + [text::draw $d $x $vy f13 $c(MUTED) → w]}]
				text::draw $d $x $vy f13 $c(MUTED) removed w
			}
			default {
				set x [expr {$x + 6 + [text::draw $d $x $vy f13 $c(MUTED) [dict get $r old] w -tnum 1]}]
				set x [expr {$x + 6 + [text::draw $d $x $vy f13 $c(MUTED) → w]}]
				text::draw $d $x $vy f13 $c(FG) [dict get $r new] w -tnum 1
			}
		}
		if {$sizes && [dict get $r bytes] ne ""} {
			text::draw $d $sizex $vy f13 $c(MUTED) [fmtsize [dict get $r bytes]] e -tnum 1
		}
		# tags, right-aligned in their column, 6 apart; security takes the accent
		set tx $R
		foreach t [lreverse [dict get $r tags]] {
			set tw [expr {14 + [text::width f11s $t]}]
			set sec [expr {$t eq "security"}]
			rbn::box $d [expr {$tx - $tw}] [expr {$ry + 14}] $tw 20 -fill [expr {$sec ? [bar::mix $c(BAR) $c(ACCENT) 0.16] : $c(PILL)}] -radius 6 -on $c(BAR)
			text::draw $d [expr {$tx - $tw / 2.0}] [expr {$ry + 24}] f11s [expr {$sec ? $c(ACCENT) : $c(MUTED)}] $t center
			set tx [expr {$tx - $tw - 6}]
		}
		# kit's warning under the row (its note, U03d), muted, as the terminal prints it
		if {[dict exists $r note] && [dict get $r note] ne ""} {
			text::draw $d [expr {$pad + 40}] [expr {$ry + 60}] f12 $c(MUTED) [bar::clip f12 [dict get $r note] [expr {$R - $pad - 40}]] w
		}
		if {$n < [llength $rows] - 1} { $d create rectangle $pad [expr {$ry + $h - 1}] $R [expr {$ry + $h}] -fill $c(BORDER) -width 0 }
		incr n
		incr ry $h
	}
}

# a plan row is 48 px, and 24 more when kit gives it a note under the row
proc upd::rowh {r} {
	expr {[dict exists $r note] && [dict get $r note] ne "" ? 72 : 48}
}
proc upd::rowsh {rows} {
	set h 0
	foreach r $rows { incr h [rowh $r] }
	return $h
}

# ---- the result: what switched, what still runs the old version ----------------------------------------------
proc upd::donerows {d W rows restart stale names} {
	variable pad
	array set c [array get theme::c]
	set R [expr {$W - $pad}]
	set n 0
	foreach r $rows {
		set ry [expr {74 + 48 * $n}]
		set name [dict get $r name]
		# kit's rows carry the display name (name) and the kit's identifier (short); stale and restart use short
		set short [expr {[dict exists $r short] ? [dict get $r short] : $name}]
		tile $d $pad [expr {$ry + 10}] 28 8 [icon $short] 15
		text::draw $d [expr {$pad + 40}] [expr {$ry + 24}] f13s $c(FG) $name w
		text::draw $d [expr {$pad + 40 + 70 + 12}] [expr {$ry + 24}] f13 $c(FG) [dict get $r old] w -tnum 1
		set note [dict get {switched Switched installed Installed removed Removed} [dict get $r new]]
		if {[lsearch -exact -index 0 $stale $short] >= 0} { set note "From its next start" }
		foreach k $restart { if {[lindex $k 0] in [list $short $name]} { set note "At restart" } }
		text::draw $d $R [expr {$ry + 24}] f12 $c(MUTED) $note e
		if {$n < [llength $rows] - 1 || [llength $stale]} { $d create rectangle $pad [expr {$ry + 47}] $R [expr {$ry + 48}] -fill $c(BORDER) -width 0 }
		incr n
	}
	if {![llength $stale]} return
	set ly [expr {74 + 48 * [llength $rows] + 16}]
	bar::spaced $d $pad [expr {$ly + 6}] f11s $c(MUTED) "STILL RUNNING OLD VERSIONS" 0.88
	set ry [expr {$ly + 21 - 2}]
	foreach s $stale {
		lassign $s short libs
		tile $d $pad [expr {$ry + 10}] 28 8 [icon $short] 15
		# the strip shows the name the rows show (kit's display name); the restart uses the identifier
		set shown [expr {[dict exists $names $short] ? [dict get $names $short] : $short}]
		set x [expr {$pad + 40}]
		set x [expr {$x + 12 + [text::draw $d $x [expr {$ry + 24}] f13s $c(FG) $shown w]}]
		if {[llength $libs]} { text::draw $d $x [expr {$ry + 24}] f12 $c(MUTED) [join $libs {, }] w }
		set w [bwidth Restart field restart ""]
		button $d [expr {$R - $w}] [expr {$ry + 7}] Restart field restart "" [list upd::restart_app $short] $c(BAR)
		incr ry 48
	}
}

# ---- History: one 52 px row per change, newest first ------------------------------------------------------------
# The change kit rewind would take back (the newest) is the one with the Rewind button, shown while the
# pointer is on it; the row under the pointer has the field fill.
proc upd::histrows {d W rows} {
	variable pad
	variable hover
	array set c [array get theme::c]
	set R [expr {$W - $pad}]
	set n 0
	foreach e $rows {
		set ry [expr {80 + 52 * $n}]
		set on [expr {$n == $hover}]
		if {$on} { rbn::box $d [expr {$pad - 8}] $ry [expr {$W - 2 * $pad + 16}] 52 -fill $c(FIELD) -radius 10 -on $c(BAR) }
		tile $d $pad [expr {$ry + 12}] 28 8 [dict get $e icon] 15
		text::draw $d [expr {$pad + 40}] [expr {$ry + 18}] f13s $c(FG) [dict get $e title] w
		text::draw $d [expr {$pad + 40}] [expr {$ry + 36}] f12 $c(MUTED) [bar::clip f12 [dict get $e sub] [expr {$W - 2 * $pad - 40 - 120}]] w
		# Rewind sits on the change kit would take back next (the history cursor), not on a "Rewound" entry
		set next [expr {[dict exists $e cursor] ? [dict get $e cursor] : $n == 0}]
		if {$on && $next} {
			set w [bwidth Rewind ghost undo ""]
			button $d [expr {$R - 1 - $w}] [expr {$ry + 9}] Rewind ghost undo "" upd::rewind_page $c(FIELD)
		} else {
			text::draw $d $R [expr {$ry + 26}] f12 $c(MUTED) [when [dict get $e time]] e
		}
		lappend panel::hits [list [expr {$pad - 8}] $ry [expr {$R + 8}] [expr {$ry + 52}] [list upd::row $n]]
		incr n
	}
}

# a click on a history row moves the highlight to it (the Rewind button is its own hit, listed first)
proc upd::row {n} { variable hover; if {$n != $hover} { set hover $n; panel::draw } }

# "All history" opens Settings > Updates, which lists the whole log
proc upd::all_history {} { panel::close; apps::run "ribbon-settings --page updates" }
