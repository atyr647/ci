# mod-term.tcl - Ribbon Terminal: foot with a Tk tab strip (docs/TERMINAL.md "Recommended build").
#
# One `foot --server`; a tab is a footclient window with the app-id ribbon-term-GROUP-N (GROUP is g1, g2...).
# The shell's toplevel stream (wm::) says which windows are tabs: nothing here polls. For every group this
# module makes one Tk toplevel, the strip (class ribbon-term-strip-GROUP, drawn by strip::draw, apps/term/
# strip.tcl), glued to the top edge of the group's tabs. A tab switch is activate-new plus minimize-old.
#
# labwc can't be asked where a Wayland window is, so the group owns its geometry: it writes a window rule
# (where a new tab maps) and keybinds (place and raise) into a runtime rc.xml that labwc merges
# (merge-config; $XDG_STATE_HOME/ribbon/xdg/labwc/rc.xml), reloads labwc (SIGHUP) and presses the place
# keybind on ribbon-shell-watch's resident virtual keyboard (`key CHORD`). The place keybind moves the strip
# and every tab in one action list, so they move together.
#
# ctl verb `term` (ribbon-term-ctl): new | group | next | prev | close | tab N | snap left|right|max|restore |
# sendto N | activity ID | prefs | restart | show-prefs GROUP | newin HEX (a new tab in the folder named by HEX).
#
# Profiles (apps/term/profiles.tcl): a tab starts with its profile's `footclient -o` overrides; a tab started with a
# command takes the profile that "opens for" it. The preferences are a tab too: a Tk window with the app-id
# ribbon-term-GROUP-prefs (apps/term/prefs.tcl), last in the strip, with the sliders in place of its number. Restart
# terminals (the preferences' button, `term restart`) closes and starts again every tab whose shell runs no command;
# a tab's shell is found by RIBBON_TERM_TAB in its environment (footclient -E).
#
# Callbacks for strip::draw (the contract with strip.tcl): term::activate ID, term::close ID, term::new,
# term::prefs, term::wctl minimize|maximize|close, term::move_start|move_drag|move_end X Y,
# term::resize_start EDGE X Y, term::resize_drag|resize_end X Y. They carry no
# group; the group is the strip the pointer is in (term::active, set on <Enter>/<Motion>), and a tab id names its own.

namespace eval term {
	variable STRIP 42        ;# the strip's height (Term-G Pills A); labwc keeps the window 60 tall, the tabs cover the rest
	variable G               ;# G(g,key): x y w h max saved(rect before max/snap) cur top born seq prev(act/title per id)
	variable groups {}       ;# group names in creation order
	variable active ""       ;# the group whose strip has the pointer, for callbacks that carry no group
	variable lastg ""        ;# the group last used
	variable drag {}
	variable rcsig ""        ;# what the rc.xml holds now
	variable rcn 0           ;# the generated rc.xml's temporary files are numbered
	variable striploaded 0
	variable pending [dict create]  ;# term-groups entries of groups not found again yet (see term::loadstate)
	variable saveafter ""
	array set G {}
}

proc term::log {args} {
	if {[info exists ::env(RIBBON_TERM_LOG)]} { catch { set f [::open $::env(RIBBON_TERM_LOG) a]; puts $f "[clock milliseconds] [join $args { }]"; ::close $f } }
}
proc term::us {} { clock microseconds }

# ---------------------------------------------------------------- the strip's drawing
proc term::load_strip {} {
	variable striploaded
	if {$striploaded} return
	variable dir
	foreach d [list [file join [file dirname $dir] term] [file join $dir .. apps term]] {
		if {[file readable [file join $d strip.tcl]]} {
			uplevel #0 [list source -encoding utf-8 [file join $d strip.tcl]]
			foreach f {profiles menu} { if {[file readable [file join $d $f.tcl]]} { uplevel #0 [list source -encoding utf-8 [file join $d $f.tcl]] } }
			set striploaded 1
			return
		}
	}
	puts stderr "term: strip.tcl not found"
}
# where this module lives, read at source time (strip.tcl is found from it)
set term::dir [file dirname [file normalize [info script]]]

# ---------------------------------------------------------------- finding tabs in the toplevel stream
# group -> {id ...} ordered by the tab's number
proc term::scan {} {
	set found [dict create]
	foreach id $wm::order {
		if {![info exists wm::tl($id)]} continue
		if {[regexp {^ribbon-term-([a-z][a-z0-9]*)-([0-9]+|prefs)$} [dict get $wm::tl($id) app] -> g n] && $g ne "strip"} {
			# the preferences tab goes last; a tab opened next to another has its place (term::newtab)
			variable G
			set k [expr {$n eq "prefs" ? 1000000 : [info exists G($g,pos,$n)] ? $G($g,pos,$n) : $n}]
			dict lappend found $g [list $k $id]
		}
	}
	dict for {g l} $found { dict set found $g [lmap p [lsort -real -index 0 $l] { lindex $p 1 }] }
	return $found
}
proc term::group_of {id} {
	variable G
	variable groups
	foreach g $groups { if {$id in $G($g,tabs)} { return $g } }
	return ""
}

# Called after every wm::changed (a trace; wm.tcl is not edited).
proc term::sync {args} {
	variable G
	variable groups
	set found [scan]
	dict for {g ids} $found { if {$g ni $groups} { create $g } }
	foreach g $groups {
		set ids [expr {[dict exists $found $g] ? [dict get $found $g] : {}}]
		set G($g,back) [lmap b $G($g,back) { lassign $b app old; if {[llength [lmap id $ids { if {$id eq $old || [wm::get $id app] ne $app} continue; set id }]]} continue; set b }]
		if {[llength $G($g,back)]} {
			set G($g,tabs) $ids
			if {[llength $ids]} { track $g }
			continue
		}
		if {![llength $ids] && $G($g,hadfoot) && !$G($g,closing) && [setting lastclose] eq "keep"} {
			# Closing the last tab: Opens a new tab (the window stays; its close button still closes it)
			set G($g,hadfoot) 0; set G($g,born) [clock milliseconds]; set G($g,seen) 0
			newtab $g
			continue
		}
		if {![llength $ids]} {
			# a group asked for and not yet mapped is kept for a while; one whose tabs have all closed goes now
			if {($G($g,seen) && ![llength $G($g,back)]) || [clock milliseconds] - $G($g,born) > 8000} { destroy $g } else { after 8200 term::sync }
			continue
		}
		set G($g,seen) 1
		set G($g,tabs) $ids
		# the last foot tab closed and the preferences are left: Closing the last tab opens a new one, or closes the window
		set feet [lmap id $ids { if {[string match *-prefs [wm::get $id app]]} continue; set id }]
		if {![llength $feet] && !$G($g,closing) && $G($g,hadfoot)} {
			set G($g,hadfoot) 0
			log lastclose $g [setting lastclose] back=$G($g,back) ids=$ids
			if {[setting lastclose] eq "keep"} { newtab $g } else { foreach id $ids { wm::send close $id } }
		} elseif {[llength $feet]} { set G($g,hadfoot) 1 }
		track $g
	}
	unask
}

# The group's current tab, activity marks, and the strip hidden with a minimised group.
proc term::track {g} {
	variable G
	set ids $G($g,tabs)
	set cur $G($g,cur)
	set edge ""
	foreach id $ids {
		set act [wm::has $id act]
		set was [expr {[info exists G($g,act,$id)] ? $G($g,act,$id) : 0}]
		set G($g,act,$id) $act
		# an activation the shell asked for itself (its last switch, or a tab it activated within 600 ms: labwc reports
		# them late) is not a raise from outside
		set mine [expr {[dict exists $G($g,ownt) $id] && [clock milliseconds] - [dict get $G($g,ownt) $id] < 600}]
		if {$act && !$was && !($G($g,own) eq $id) && !$mine} { set edge $id }
		# new output: a title change on a tab that is not in front
		set t [wm::get $id title]
		if {[info exists G($g,title,$id)] && $G($g,title,$id) ne $t && $id ne $cur && [setting marktab]} { set G($g,mark,$id) 1 }
		set G($g,title,$id) $t
	}
	set G($g,own) ""
	# the tab that was front before a shell restart (its number in term-groups) is front again once it is here
	# (until then the tabs' own activation flags, left over from the old shell, are not edges)
	set want [expr {$G($g,want) ne "" ? [tab_numbered $ids $G($g,want)] : ""}]
	if {$G($g,want) ne ""} { set edge "" }
	if {$want ne ""} {
		set G($g,want) ""
		foreach id $ids { if {$id ne $want} { wm::send minimize $id } }
	}
	if {$cur ni $ids && $want eq "" && $G($g,want) ne ""} {
		# after a shell restart: the tab that was in front has not come back yet; nothing else is chosen meanwhile
	} elseif {$cur ni $ids} {
		# the current tab closed (or first sight): the restored tab, else its neighbour, else the one that came up
		set k [lsearch -exact $G($g,order) $cur]
		if {$want ne ""} { set next $want } elseif {$edge ne ""} { set next $edge } elseif {$cur ne "" && $k >= 0} { set next [lindex $ids [expr {min($k, [llength $ids] - 1)}]] } else { set next [lindex $ids end] }
		set G($g,cur) ""
		select $g $next 0
	} elseif {$want ne "" && $want ne $cur} {
		select $g $want 0
	} elseif {$edge ne "" && $edge ne $cur} {
		# raised from outside (the dock, Alt+Tab, a click): it is the current tab now
		select $g $edge 1
	}
	# a tab that was not here before maps where the window rule puts it; the place keybind makes sure
	set fresh [expr {[llength [lmap id $ids { if {$id in $G($g,order)} continue; set id }]] > 0}]
	set G($g,order) $ids
	if {$fresh} { place $g }
	# a minimised group: its strip goes with it, and comes back with the first tab that is shown
	set min [wm::has $G($g,cur) min]
	if {$min && !$G($g,min)} { set G($g,min) 1; catch {wm iconify $G($g,top)} } elseif {!$min && $G($g,min)} {
		set G($g,min) 0; catch {wm deiconify $G($g,top)}; place $g; raise_strip $g
	}
	redraw $g
	unset -nocomplain G($g,mark,$G($g,cur))
	# Show the strip: Two or more. With one tab the strip goes and the tab takes the whole rectangle, with labwc's
	# title bar to move and close it by
	set hide [expr {[llength $ids] == 1 && [setting strip] eq "two"}]
	if {$hide != $G($g,hide)} {
		set G($g,hide) $hide
		if {$hide} { catch {wm withdraw $G($g,top)} } elseif {!$G($g,min)} { catch {wm deiconify $G($g,top)} }
		place $g
		# labwc moves the tab before its title bar has gone (or come): placed again once it has
		after 200 [list term::place $g]
		if {!$hide} { raise_strip $g; after 220 [list term::raise_strip $g] }
	}
}

# ---------------------------------------------------------------- kept across a shell restart
# $XDG_STATE_HOME/ribbon/term-groups: one line per group, "NAME X Y W H MAX CUR SAVED". CUR is the tab's number
# (-: none); SAVED is the rectangle before a max or snap as X,Y,W,H (-: none). Written, debounced, when a group moves,
# snaps or switches tab; the group's line goes at once when the group closes. A shell that starts finds the groups'
# tabs again and gives each its rectangle and tab back. A line whose group is not found within 10 s is dropped.
proc term::statefile {} { file join [fault::dir] term-groups }
proc term::tabnum {id} {
	if {$id ne "" && [regexp -- {-([0-9]+)$} [wm::get $id app] -> n]} { return $n }
	return -
}
proc term::tab_numbered {ids n} {
	foreach id $ids { if {[tabnum $id] eq $n} { return $id } }
	return ""
}
proc term::live {g} {
	variable G
	set n [tabnum $G($g,cur)]
	return [dict create x $G($g,x) y $G($g,y) w $G($g,w) h $G($g,h) max $G($g,max) cur [expr {$n eq "-" ? "" : $n}] saved $G($g,saved)]
}
proc term::line {g r} {
	set cur [expr {[dict get $r cur] eq "" ? "-" : [dict get $r cur]}]
	set saved [expr {[dict get $r saved] eq {} ? "-" : [join [dict get $r saved] ,]}]
	return "$g [dict get $r x] [dict get $r y] [dict get $r w] [dict get $r h] [dict get $r max] $cur $saved"
}
# Debounced: a burst of moves writes once, 400 ms after the last.
proc term::persist {} {
	variable saveafter
	catch {after cancel $saveafter}
	set saveafter [after 400 term::savestate]
}
proc term::savestate {} {
	variable groups
	variable pending
	variable saveafter
	set saveafter ""
	set lines {}
	foreach g $groups { lappend lines [line $g [live $g]] }
	dict for {g r} $pending { if {$g ni $groups} { lappend lines [line $g $r] } }
	if {![llength $lines]} { catch {::file delete [statefile]}; return }
	set tmp [file join [fault::dir] .term-groups.[pid].tmp]
	if {[catch {
		::file mkdir [fault::dir]
		set fh [::open $tmp w]
		fconfigure $fh -encoding utf-8
		puts $fh [join $lines "\n"]
		::close $fh
		::file rename -force $tmp [statefile]
	} err]} {
		catch {::file delete $tmp}
		log state not saved: $err
	}
}
# Read at source time. A file that does not parse is deleted, as fault.tcl does with its state.
proc term::loadstate {} {
	variable pending
	set pending [dict create]
	set path [statefile]
	if {![file exists $path]} return
	if {[catch {
		if {[file size $path] > 4096} { error "larger than 4 KiB" }
		set fh [::open $path r]
		fconfigure $fh -encoding utf-8
		set text [read $fh]
		::close $fh
		foreach line [split $text "\n"] {
			if {$line eq ""} continue
			if {![regexp {^([a-z][a-z0-9]*) (-?[0-9]+) (-?[0-9]+) ([1-9][0-9]*) ([1-9][0-9]*) ([01]) (-|[0-9]+) (-|-?[0-9]+,-?[0-9]+,[1-9][0-9]*,[1-9][0-9]*)$} $line -> g x y w h max cur saved]} {
				error "line does not parse: [string range $line 0 40]"
			}
			dict set pending $g [dict create x $x y $y w $w h $h max $max cur [expr {$cur eq "-" ? "" : $cur}] \
				saved [expr {$saved eq "-" ? {} : [split $saved ,]}]]
		}
	} err]} {
		catch {fault::log "term-groups dropped: $err"}
		catch {::file delete $path}
		set pending [dict create]
	}
}
# A group found again takes the rectangle and tab it had before the restart.
proc term::adopt {g r} {
	variable G
	lassign [list [dict get $r x] [dict get $r y] [dict get $r w] [dict get $r h]] G($g,x) G($g,y) G($g,w) G($g,h)
	set G($g,max) [dict get $r max]
	set G($g,saved) [dict get $r saved]
	set G($g,want) [dict get $r cur]
}
# 10 s after the start: a group that did not come back is gone, and so is its line.
proc term::prune {} {
	variable G
	variable groups
	variable pending
	foreach g $groups { set G($g,want) "" }
	# a group still waiting for its front tab takes one of those it has
	if {[llength $groups]} { sync }
	if {[dict size $pending]} { set pending [dict create]; savestate }
}

# ---------------------------------------------------------------- groups
proc term::create {g} {
	variable G
	variable groups
	variable STRIP
	variable pending
	lappend groups $g
	set k [expr {[llength $groups] - 1}]
	# a new group opens in the middle of the main display (bar::place), between its bars
	set w [expr {min(1100, $bar::W - 160)}]; set h [expr {min(680, $bar::H - 108 - 80)}]
	array set G [list $g,w $w $g,h $h $g,x [expr {$bar::X0 + ($bar::W - $w) / 2 + 28 * $k}] $g,y [expr {$bar::Y0 + 54 + ($bar::H - 108 - $h) / 2 + 28 * $k}] \
		$g,max 0 $g,saved {} $g,cur "" $g,order {} $g,tabs {} $g,min 0 $g,own "" $g,born [clock milliseconds] $g,seq 0 $g,sig "" $g,want "" \
		$g,closing 0 $g,hadfoot 0 $g,hide 0 $g,back {} $g,seen 0 $g,ownt {}]
	if {[dict exists $pending $g]} { adopt $g [dict get $pending $g]; dict unset pending $g }
	set w $G($g,w)
	set top .term_$g
	set G($g,top) $top
	toplevel $top -class ribbon-term-strip-$g -background $theme::c(BAR) -borderwidth 0
	wm title $top Terminal
	wm geometry $top $w\x$STRIP+$G($g,x)+$G($g,y)
	canvas $top.c -highlightthickness 0 -borderwidth 0 -background $theme::c(BAR) -height $STRIP -width $w
	pack $top.c -fill both -expand 1
	bindtags $top.c [linsert [bindtags $top.c] 0 TermStrip$g]
	bind TermStrip$g <Enter> [list set ::term::active $g]
	bind TermStrip$g <Motion> [list set ::term::active $g]
	bind TermStrip$g <ButtonPress> [list set ::term::active $g]
	set ::term::active $g
	load_strip
	log group $g created
	apply_rc
}
proc term::destroy {g} {
	variable G
	variable groups
	variable active
	variable lastg
	catch {::destroy $G($g,top)}
	array unset G $g,*
	set groups [lsearch -all -inline -not -exact $groups $g]
	if {$active eq $g} { set active "" }
	if {$lastg eq $g} { set lastg "" }
	log group $g gone
	variable pending
	dict unset pending $g
	savestate
	apply_rc
}

proc term::redraw {g} {
	variable G
	if {![winfo exists $G($g,top).c]} return
	set tabs {}; set i 0
	foreach id $G($g,tabs) {
		incr i
		set app [wm::get $id app]
		set t [dict create id $id num $i name [expr {[info exists G($g,name,$app)] ? $G($g,name,$app) : [wm::get $id title]}] \
			active [expr {$id eq $G($g,cur)}] activity [info exists G($g,mark,$id)]]
		if {[string match *-prefs $app]} { dict set t icon tabprefs }
		if {[info exists ::term::tabprof($app)] && [llength [info commands ::prof::colours]]} {
			catch { set k [prof::colours $::term::tabprof($app)]; if {[prof::get $::term::tabprof($app) mark] ne ""} { dict set t mark [dict get $k mark] } }
		}
		lappend tabs $t
	}
	set st [dict create maximized $G($g,max) focused [expr {$G($g,cur) ne "" && [wm::has $G($g,cur) act]}]]
	set sig [list $G($g,w) $tabs $st]
	if {$sig eq $G($g,sig)} return
	set G($g,sig) $sig
	if {[catch {strip::draw $G($g,top).c $G($g,w) $tabs $st} err]} { log strip error $err; puts stderr "term: strip::draw: $err" }
}

# Which group a no-group callback means.
proc term::which {} {
	variable active
	variable lastg
	variable groups
	variable G
	set f $wm::focus
	if {$f ne "" && [group_of $f] ne ""} { return [group_of $f] }
	if {$active in $groups} { return $active }
	if {$lastg in $groups} { return $lastg }
	return [lindex $groups end]
}

# ---------------------------------------------------------------- switching
# Make tab ID the front one. MINOLD: minimise the tab it covers (a tab raised from outside already covers it).
proc term::select {g id {ext 0}} {
	variable G
	if {$id eq $G($g,cur)} return
	set t0 [us]
	set old $G($g,cur)
	set G($g,cur) $id
	variable lastg; set lastg $g
	unset -nocomplain G($g,mark,$id)
	set G($g,own) $id
	if {!$ext} { dict set G($g,ownt) $id [clock milliseconds]; wm::send activate $id }
	if {$old ne "" && $old in $G($g,tabs)} { wm::send minimize $old }
	raise_strip $g
	redraw $g
	log select $g $id from $old ext $ext [expr {([us] - $t0) / 1000.0}]
	persist
}
proc term::step {g d} {
	variable G
	set n [llength $G($g,tabs)]
	if {!$n} return
	set k [lsearch -exact $G($g,tabs) $G($g,cur)]
	select $g [lindex $G($g,tabs) [expr {($k + $d) % $n}]]
}

# ---------------------------------------------------------------- the foot server and new tabs
proc term::sock {} { file join [shell::runtime] foot-[expr {[info exists ::env(WAYLAND_DISPLAY)] ? $::env(WAYLAND_DISPLAY) : "wayland-0"}].sock }
proc term::errlog {} { expr {[info exists ::env(RIBBON_TERM_LOG)] ? $::env(RIBBON_TERM_LOG) : "/dev/null"} }
namespace eval term {
	variable tabprof          ;# app-id -> the profile its tab was started with
	array set tabprof {}
}
proc term::spawn {app {profile ""} {cmd {}} {cwd ""} {tries 0}} {
	if {![file exists [sock]]} {
		if {$tries == 0} { catch {exec foot --server --log-level=error >>&[errlog] &} }
		if {$tries < 100} { after 20 [list term::spawn $app $profile $cmd $cwd [incr tries]]; return }
		log spawn $app giving up; return
	}
	load_strip
	set over {}
	if {[llength [info commands ::prof::footargs]]} {
		prof::load
		if {$profile eq "" || ![dict exists $prof::P $profile]} { set profile [prof::for_command $cmd] }
		set over [prof::footargs $profile]
		# Ctrl+, opens the preferences (a foot binding, so other apps keep the key)
		lappend over -o "key-bindings.pipe-visible=\[ribbon-term-ctl prefs\] Control+comma"
	}
	variable tabprof
	set tabprof($app) $profile
	set wd [expr {$cwd ne "" && [file isdirectory $cwd] ? [list --working-directory=$cwd] : {}}]
	log spawn $app $profile
	catch {exec env RIBBON_TERM_TAB=$app footclient -N -E --app-id $app {*}$wd {*}$over {*}$cmd >>&[errlog] &}
}
proc term::newtab {g {profile ""} {cmd {}} {from ""} {dir ""}} {
	variable G
	set mx $G($g,seq)
	foreach id $G($g,tabs) { if {[regexp -- {-([0-9]+)$} [wm::get $id app] -> n] && $n > $mx} { set mx $n } }
	set G($g,seq) [incr mx]
	set cur $G($g,cur)
	set curapp [expr {$cur ne "" ? [wm::get $cur app] : ""}]
	# New tab goes: Next (after the current tab; the strip orders by these places) or At the end (its number)
	if {[setting newat] eq "next" && [regexp -- {-([0-9]+)$} $curapp -> cn]} {
		set here [expr {[info exists G($g,pos,$cn)] ? $G($g,pos,$cn) : $cn}]
		set after {}
		foreach id $G($g,tabs) {
			if {[regexp -- {-([0-9]+)$} [wm::get $id app] -> n]} {
				set p [expr {[info exists G($g,pos,$n)] ? $G($g,pos,$n) : $n}]
				if {$p > $here} { lappend after $p }
			}
		}
		set G($g,pos,$mx) [expr {[llength $after] ? ($here + [tcl::mathfunc::min {*}$after]) / 2.0 : $mx}]
	}
	# New tab opens in: Same folder (the current tab's shell's folder) or Home
	set cwd ""
	if {$from ne ""} { set curapp $from }
	if {($from ne "" || [setting newin] eq "same") && $curapp ne "" && ![string match *-prefs $curapp]} {
		set pid [shell_of $curapp]
		if {$pid ne "" && [catch {file readlink /proc/$pid/cwd} cwd]} { set cwd "" }
	}
	# a folder asked for by the caller (ribbon-terminal run in it) comes before either
	if {$dir ne ""} { set cwd $dir }
	spawn ribbon-term-$g-$mx $profile $cmd $cwd
}
proc term::newgroup {{cmd {}} {dir ""}} {
	variable groups
	variable pending
	set n 1
	while {"g$n" in $groups || [dict exists $pending g$n]} { incr n }
	create g$n
	apply_rc
	newtab g$n "" $cmd "" $dir
}

# ---------------------------------------------------------------- geometry: the generated rc.xml
proc term::rcfile {} {
	if {[info exists ::env(RIBBON_TERM_RC)]} { return $::env(RIBBON_TERM_RC) }
	set st [expr {[info exists ::env(XDG_STATE_HOME)] ? $::env(XDG_STATE_HOME) : "$::env(HOME)/.local/state"}]
	return $st/ribbon/xdg/labwc/rc.xml
}
proc term::rc_text {} {
	variable G
	variable groups
	variable STRIP
	set f {F11 F10 F9 F8}
	set place ""; set rules ""; set k 0; set rais {}
	foreach g $groups {
		set q "ribbon-term-$g-*"; set qs "ribbon-term-strip-$g"
		set off [expr {$G($g,hide) ? 0 : $STRIP}]
		set fy [expr {$G($g,y) + $off}]; set fh [expr {$G($g,h) - $off}]
		set mv "<action name=\"MoveTo\" x=\"$G($g,x)\" y=\"$fy\"/><action name=\"ResizeTo\" width=\"$G($g,w)\" height=\"$fh\"/>"
		# a tab with no strip above it has labwc's title bar (Show the strip: Two or more); the rule covers new tabs
		set deco "<action name=\"SetDecorations\" decorations=\"[expr {$G($g,hide) ? "full" : "none"}]\" forceSSD=\"yes\"/>"
		append place "<action name=\"ForEach\"><query identifier=\"$q\"/><then>$deco$mv</then></action>"
		append place "<action name=\"ForEach\"><query identifier=\"$qs\"/><then><action name=\"MoveTo\" x=\"$G($g,x)\" y=\"$G($g,y)\"/><action name=\"Raise\"/></then></action>"
		append place "<action name=\"ForEach\"><query identifier=\"$q\"/><then><action name=\"Raise\"/></then></action>"
		set G($g,raise) [lindex $f [expr {min($k, 3)}]]
		lappend rais $g
		append rules "<windowRule identifier=\"$q\" serverDecoration=\"[expr {$G($g,hide) ? "yes" : "no"}]\">$mv</windowRule>"
		append rules "<windowRule identifier=\"$qs\" serverDecoration=\"no\" skipTaskbar=\"yes\" skipWindowSwitcher=\"yes\"/>"
		incr k
	}
	if {![llength $groups]} { return "<labwc_config/>\n" }
	set x "<labwc_config><keyboard>\n"
	if {[llength $groups]} {
		append x "<keybind key=\"C-A-S-W-F12\">$place</keybind>\n"
		foreach g $rais {
			append x "<keybind key=\"C-A-S-W-$G($g,raise)\"><action name=\"ForEach\"><query identifier=\"ribbon-term-strip-$g\"/><then><action name=\"Raise\"/></then></action><action name=\"ForEach\"><query identifier=\"ribbon-term-$g-*\"/><then><action name=\"Raise\"/></then></action></keybind>\n"
		}
		# SendToDesktop for the group of the focused tab: its tabs and its strip together (ribbon-term-ctl sendto N)
		foreach n {1 2 3} {
			append x "<keybind key=\"C-A-S-W-F$n\">"
			foreach g $groups {
				append x "<action name=\"If\"><query identifier=\"ribbon-term-$g-*\"/><then>"
				foreach q [list ribbon-term-$g-* ribbon-term-strip-$g] { append x "<action name=\"ForEach\"><query identifier=\"$q\"/><then><action name=\"SendToDesktop\" to=\"$n\" follow=\"no\"/></then></action>" }
				append x "<action name=\"GoToDesktop\" to=\"$n\"/></then></action>"
			}
			append x "</keybind>\n"
		}
	}
	append x "</keyboard>\n<windowRules>$rules</windowRules></labwc_config>\n"
	return $x
}
proc term::apply_rc {} {
	variable rcsig
	set t [rc_text]
	if {$t eq $rcsig} { return 0 }
	set rc [rcfile]
	catch {file mkdir [file dirname $rc]}
	set tmp $rc.[incr ::term::rcn].tmp
	if {[catch { set f [::open $tmp w]; puts -nonewline $f $t; ::close $f; file rename -force $tmp $rc } err]} { catch {file delete $tmp}; log rc error $err; return 0 }
	set rcsig $t
	reload
	return 1
}
proc term::reload {} {
	if {[info exists ::env(LABWC_PID)]} { catch {exec kill -HUP $::env(LABWC_PID)} } else { catch {exec labwc --reconfigure >&/dev/null &} }
}
proc term::press {chord} { wm::send key $chord }
# every tab and the strip of every group to their rectangles
proc term::place {g} {
	set t0 [us]
	set changed [apply_rc]
	press C-A-S-W-F12
	log place $g rc $changed [expr {([us] - $t0) / 1000.0}]
}
proc term::raise_strip {g} {
	variable G
	if {![info exists G($g,raise)]} { apply_rc }
	if {[info exists G($g,raise)]} { press C-A-S-W-$G($g,raise) }
}
proc term::setrect {g x y w h} {
	variable G
	variable STRIP
	lassign [list $x $y $w $h] G($g,x) G($g,y) G($g,w) G($g,h)
	set G($g,sig) ""
	wm geometry $G($g,top) $w\x$STRIP+$x+$y
	$G($g,top).c configure -width $w
	place $g
	redraw $g
	persist
}

# ---------------------------------------------------------------- the strip's callbacks (the contract)
proc term::activate {id} { set g [group_of $id]; if {$g ne ""} { select $g $id } }
proc term::close {id} {
	set g [group_of $id]
	if {$g eq ""} { wm::send close $id; return }
	confirm $g tab [list $id] [list wm::send close $id]
}
proc term::new {{cmd {}} {dir ""}} {
	set g [which]
	if {$g eq ""} { newgroup $cmd $dir } else { newtab $g "" $cmd "" $dir }
}
proc term::prefs {} {
	variable G
	set g [which]
	if {$g eq ""} return
	foreach id $G($g,tabs) { if {[string match *-prefs [wm::get $id app]]} { select $g $id; return } }
	catch {exec ribbon-term-prefs $g >>&[errlog] &}
}
# A setting of profile Default (the strip's own: marks, new tabs, the last tab), terminal.conf read again when it changed.
proc term::setting {key} {
	variable confsig
	load_strip
	if {![llength [info commands ::prof::get]]} { return [expr {$key in {marktab} ? 1 : ""}] }
	set m [expr {[catch {file mtime [prof::conffile]} t] ? 0 : $t}]
	if {![info exists confsig] || $confsig ne $m} { set confsig $m; prof::load }
	prof::get Default $key
}
# A tab's shell: the process whose environment has RIBBON_TERM_TAB=APP. "" when none is found.
proc term::shell_of {app} {
	foreach d [glob -nocomplain -directory /proc -tails {[0-9]*}] {
		if {[catch {set f [::open /proc/$d/environ rb]; set e [read $f]; ::close $f}]} continue
		if {[string first "\0RIBBON_TERM_TAB=$app\0" "\0$e"] >= 0} {
			# the shell is the one whose parent does not carry the same tab (footclient -E's child)
			if {[catch {set f [::open /proc/$d/stat r]; set st [read $f]; ::close $f}]} continue
			set pp [lindex [split [string range $st [expr {[string last ")" $st] + 2}] end]] 1]
			if {[catch {set f [::open /proc/$pp/environ rb]; set pe [read $f]; ::close $f}] || [string first "\0RIBBON_TERM_TAB=$app\0" "\0$pe"] < 0} { return $d }
		}
	}
	return ""
}
# The terminal of process PID: its controlling tty (/proc/PID/stat's tty_nr, a pts), whatever its stdin is.
proc term::tty_of {pid} {
	set f [::open /proc/$pid/stat r]; set st [read $f]; ::close $f
	set nr [lindex [split [string range $st [expr {[string last ")" $st] + 2}] end]] 4]
	set major [expr {($nr >> 8) & 0xfff}]; set minor [expr {($nr & 0xff) | (($nr >> 12) & 0xfff00)}]
	if {$major < 136 || $major > 143} { error "process $pid has no pty" }
	return /dev/pts/[expr {($major - 136) * 256 + $minor}]
}
# Whether a tab's shell runs a command now (it has a child).
proc term::busy {app} {
	set pid [shell_of $app]
	if {$pid eq ""} { return 0 }
	expr {![catch {set f [::open /proc/$pid/task/$pid/children r]; set k [string trim [read $f]]; ::close $f}] && $k ne ""}
}
# ---------------------------------------------------------------- Ask before closing a running command
# What a tab runs in front of its shell: the command line of its terminal's foreground process group when that is not
# the shell's own group (the shell is at its prompt otherwise), "" when it runs nothing. An interpreter's script is
# named by the script ("kit update", not "tclsh /usr/bin/kit update"); long lines are cut at 40 characters.
proc term::running {app} {
	if {[string match *-prefs $app]} { return "" }
	set pid [shell_of $app]
	if {$pid eq "" || [catch {set f [::open /proc/$pid/stat r]; set st [read $f]; ::close $f}]} { return "" }
	set fields [split [string range $st [expr {[string last ")" $st] + 2}] end]]
	set pgrp [lindex $fields 2]; set tpgid [lindex $fields 5]
	if {![string is integer -strict $tpgid] || $tpgid <= 0 || $tpgid == $pgrp} { return "" }
	set argv {}
	if {![catch {set f [::open /proc/$tpgid/cmdline rb]; set a [read $f]; ::close $f}]} { set argv [lrange [split $a \0] 0 end-1] }
	if {![llength $argv] && ![catch {set f [::open /proc/$tpgid/comm r]; set a [string trim [read $f]]; ::close $f}]} { set argv [list $a] }
	if {![llength $argv]} { return "A command" }
	if {[regexp {^(sh|bash|dash|zsh|tclsh[0-9.]*|wish[0-9.]*|python[0-9.]*|perl|ruby|node)$} [file tail [lindex $argv 0]]] && [llength $argv] > 1 \
		&& ![string match -* [lindex $argv 1]]} { set argv [lrange $argv 1 end] }
	set cmd [join [concat [list [file tail [lindex $argv 0]]] [lrange $argv 1 end]] " "]
	if {[string length $cmd] > 40} { set cmd "[string trimright [string range $cmd 0 38]]\u2026" }
	return $cmd
}
# The question (shell/alert.tcl, boards Alert-2, -2b, -2c), a sheet hanging from group G's strip, before SCRIPT closes
# (or restarts) tabs IDS while "Ask before closing a running command" is on and one of them runs a command; SCRIPT runs
# at once otherwise (or NOW). KIND: tab, window or restart. While it asks, any other close waits for its answer.
namespace eval term { variable asking {} }   ;# {g ids} of the open question
# NOW: what runs when nothing is asked (default SCRIPT)
proc term::confirm {g kind ids script {now ""}} {
	variable G
	variable STRIP
	variable dir
	set cmds {}
	if {[setting ask] ne "0"} {
		foreach id $ids { set r [running [wm::get $id app]]; if {$r ne ""} { lappend cmds $r } }
	}
	if {![llength $cmds]} { uplevel #0 [expr {$now ne "" ? $now : $script}]; return }
	if {![llength [info commands ::alert::open]]} { uplevel #0 [list source -encoding utf-8 [file join $dir alert.tcl]] }
	if {[alert::isopen]} return
	set line [expr {[llength $cmds] == 1 ? "[lindex $cmds 0] is still running" : "[llength $cmds] commands are still running"}]
	switch -- $kind {
		tab { set q [list -icon terminal -title "Close this tab?" -buttons {{cancel Cancel} {yes {Close tab}}}] }
		window { set q [list -icon terminal -title "Close this window?" -buttons {{cancel Cancel} {yes {Close window}}}] }
		restart { set q [list -icon refresh -title "Restart terminals?" -buttons {{cancel Cancel} {yes Restart}}] }
	}
	variable asking [list $g $ids]
	log ask $kind $g $ids $cmds
	alert::open {*}$q -lines [list $line] -hang 1 -at [list [expr {$G($g,x) + ($G($g,w) - $alert::W) / 2}] [expr {$G($g,y) + $STRIP}]] \
		-command [list term::answered $kind $script]
}
proc term::answered {kind script key} {
	variable asking {}
	log answered $kind $key
	if {$key eq "yes"} { uplevel #0 $script }
}
# The question goes when what it asks about has gone (its tabs closed from elsewhere, the group closed).
proc term::unask {} {
	variable asking
	variable G
	if {![llength $asking] || ![llength [info commands ::alert::isopen]] || ![alert::isopen]} return
	lassign $asking g ids
	if {![info exists G($g,tabs)] || ![llength [lmap id $ids { expr {$id in $G($g,tabs) ? $id : [continue]} }]]} { alert::cancel }
}

# A restarted tab that never came back is given up on after 8 s.
proc term::restarted {g app} {
	variable G
	if {[info exists G($g,back)]} { set G($g,back) [lsearch -all -inline -not -exact -index 0 $G($g,back) $app] }
}
# Restart terminals: every foot tab whose shell is idle closes and starts again with the same number and profile.
proc term::restart {} {
	variable G
	variable groups
	set all {}
	foreach g $groups { lappend all {*}$G($g,tabs) }
	set g [which]
	if {$g eq ""} return
	# asked first when a tab runs a command (TERMINAL.md §4): Restart starts every tab again, Cancel none
	confirm $g restart $all {term::restart_all 1} {term::restart_all 0}
}
# FORCE: also the tabs that run a command (after the question); else those are kept
proc term::restart_all {{force 0}} {
	variable G
	variable groups
	foreach g $groups { foreach id $G($g,tabs) { restart_tab $g $id $force } }
}
# One tab started again (the menu's Restart with new settings; FORCE: also when it runs a command).
proc term::restart_tab {g id force} {
	variable G
	variable tabprof
	set app [wm::get $id app]
	if {[string match *-prefs $app] || (!$force && [busy $app])} { log restart keeps $id $app; return }
	set pid [shell_of $app]
	set cwd [expr {$pid ne "" && ![catch {file readlink /proc/$pid/cwd} d] ? $d : ""}]
	set p [expr {[info exists tabprof($app)] ? $tabprof($app) : ""}]
	log restart $app $p
	# while the tab comes back the group is neither closing its last tab nor gone (term::sync)
	# (the new window has the old one's app-id: it has come back when a window other than ID has it)
	lappend G($g,back) [list $app $id]; set G($g,born) [clock milliseconds]
	unset -nocomplain G($g,size,$app)
	after 8000 [list term::restarted $g $app]
	wm::send close $id
	after 400 [list term::spawn $app $p {} $cwd]
}
proc term::wctl {action} {
	variable G
	set g [which]
	if {$g eq ""} return
	switch -- $action {
		minimize { if {$G($g,cur) ne ""} { wm::send minimize $G($g,cur) } }
		maximize { snap $g [expr {$G($g,max) ? "restore" : "max"}] }
		close { confirm $g window $G($g,tabs) [list term::close_window $g] }
	}
}
proc term::close_window {g} {
	variable G
	if {![info exists G($g,tabs)]} return
	set G($g,closing) 1
	foreach id $G($g,tabs) { wm::send close $id }
}
proc term::move_start {x y} {
	variable G
	variable drag
	set g [which]
	if {$g eq "" || $G($g,max)} { set drag {}; return }
	set drag [list $g $x $y $G($g,x) $G($g,y) 0]
}
proc term::move_drag {x y} {
	variable G
	variable drag
	if {$drag eq ""} return
	lassign $drag g px py ox oy last
	set now [us]
	if {$now - $last < 50000} return
	lset drag 5 $now
	setrect $g [expr {$ox + $x - $px}] [expr {$oy + $y - $py}] $G($g,w) $G($g,h)
}
proc term::move_end {x y} {
	variable G
	variable drag
	if {$drag eq ""} return
	lassign $drag g px py ox oy last
	set drag {}
	setrect $g [expr {$ox + $x - $px}] [expr {$oy + $y - $py}] $G($g,w) $G($g,h)
}

# Resizing by the group's edges: the strip is the group's top edge, so its top and its two ends are the
# window's top, left and right edges (strip.tcl: resize_start EDGE X Y with EDGE l, r, t, tl or tr, then drag and
# end). The opposite edges stay where they are; the group keeps a least size (the strip's controls, a few tabs
# and some rows). Each step goes the way a move does: setrect, so labwc gets ResizeTo with the new rectangle.
namespace eval term { variable MINW 480; variable MINH 240 }
proc term::resize_rect {edge ox oy ow oh dx dy} {
	variable MINW
	variable MINH
	set x $ox; set y $oy; set w $ow; set h $oh
	if {[string first r $edge] >= 0} { set w [expr {max($MINW, $ow + $dx)}] }
	if {[string first l $edge] >= 0} { set w [expr {max($MINW, $ow - $dx)}]; set x [expr {$ox + $ow - $w}] }
	if {[string first t $edge] >= 0} { set h [expr {max($MINH, $oh - $dy)}]; set y [expr {$oy + $oh - $h}] }
	list $x $y $w $h
}
proc term::resize_start {edge x y} {
	variable G
	variable drag
	set g [which]
	if {$g eq "" || $G($g,max) || $edge ni {l r t tl tr}} { set drag {}; return }
	set drag [list $g $x $y $G($g,x) $G($g,y) 0 $edge $G($g,w) $G($g,h)]
}
proc term::resize_drag {x y} {
	variable drag
	if {[llength $drag] < 9} return
	lassign $drag g px py ox oy last edge ow oh
	set now [us]
	if {$now - $last < 50000} return
	lset drag 5 $now
	setrect $g {*}[resize_rect $edge $ox $oy $ow $oh [expr {$x - $px}] [expr {$y - $py}]]
}
proc term::resize_end {x y} {
	variable drag
	if {[llength $drag] < 9} { set drag {}; return }
	lassign $drag g px py ox oy last edge ow oh
	set drag {}
	# a snapped group that is resized is no longer snapped: Restore has nothing to go back to
	variable G
	set G($g,saved) {}
	setrect $g {*}[resize_rect $edge $ox $oy $ow $oh [expr {$x - $px}] [expr {$y - $py}]]
}

# Move the current tab one place left or right in the strip (the keys' Move tab left / right): it swaps places with
# its neighbour (the places are term::scan's order keys).
proc term::move {g dir} {
	variable G
	set ids $G($g,tabs)
	set k [lsearch -exact $ids $G($g,cur)]
	set j [expr {$dir eq "left" ? $k - 1 : $k + 1}]
	if {$k < 0 || $j < 0 || $j >= [llength $ids]} return
	set a [wm::get [lindex $ids $k] app]; set b [wm::get [lindex $ids $j] app]
	if {![regexp -- {-([0-9]+)$} $a -> na] || ![regexp -- {-([0-9]+)$} $b -> nb]} return
	set pa [expr {[info exists G($g,pos,$na)] ? $G($g,pos,$na) : $na}]
	set pb [expr {[info exists G($g,pos,$nb)] ? $G($g,pos,$nb) : $nb}]
	set G($g,pos,$na) $pb; set G($g,pos,$nb) $pa
	sync
}

# ---------------------------------------------------------------- a tab's menu (apps/term/menu.tcl)
proc term::menu {id X Y} {
	variable active
	set g [group_of $id]
	if {$g eq "" || ![llength [info commands ::tmenu::open]]} return
	set active $g
	tmenu::open $id $X $Y
}
# The tab's text size now: its profile's, moved by the menu's stepper.
proc term::tab_size {id} {
	variable G
	variable tabprof
	set g [group_of $id]; set app [wm::get $id app]
	if {$g ne "" && [info exists G($g,size,$app)]} { return $G($g,size,$app) }
	set p [expr {[info exists tabprof($app)] && $tabprof($app) ne "" ? $tabprof($app) : "Default"}]
	if {[catch {prof::get $p size} v]} { return 14 }
	return $v
}
# foot's chord (Control+Shift+t) as the virtual keyboard's (C-S-t).
proc term::chord {c} {
	set parts [split $c +]
	set out ""
	foreach m [lrange $parts 0 end-1] { append out [dict get {Control C Shift S Mod1 A Mod4 W} $m]- }
	return $out[lindex $parts end]
}
proc term::menu_do {id what {arg ""}} {
	variable G
	variable tabprof
	variable active
	set g [group_of $id]
	if {$g eq ""} return
	set active $g
	set app [wm::get $id app]
	switch -- $what {
		new { newtab $g }
		profile { newtab $g $arg }
		dup { newtab $g [expr {[info exists tabprof($app)] ? $tabprof($app) : ""}] {} $app }
		rename { rename_start $g $id }
		size {
			# foot's font-increase / font-decrease, pressed into that tab (it is brought to the front for the key);
			# a tab's step is 1 pt (profiles.tcl sets font-size-adjustment)
			set v [expr {[tab_size $id] + $arg}]
			if {$v < 6 || $v > 48 || [string match *-prefs $app]} return
			set G($g,size,$app) $v
			set key [chord [prof::get Default [expr {$arg > 0 ? "key_bigger" : "key_smaller"}]]]
			if {$G($g,cur) ne $id} { select $g $id } else { wm::send activate $id }
			after 120 [list term::press $key]
		}
		restart { restart_tab $g $id 1 }
		prefs { prefs }
		window { to_window $g $id }
		close { close $id }
	}
}
# Rename…: the pill's name becomes a field in the strip; Return (or leaving it) keeps the name, Esc the old one,
# an empty name gives the tab its own title back.
proc term::rename_start {g id} {
	variable G
	set G($g,sig) ""; redraw $g
	set r [strip::pill $id]
	if {$r eq {}} return
	lassign $r px py pw ph
	set e $G($g,top).rename
	::destroy $e
	set app [wm::get $id app]
	entry $e -font strip_on -background $theme::c(PILL) -foreground $theme::c(FG) -insertbackground $theme::c(FG) \
		-selectbackground $theme::c(FIELD) -selectforeground $theme::c(FG) -relief flat -borderwidth 0 -highlightthickness 0
	$e insert 0 [expr {[info exists G($g,name,$app)] ? $G($g,name,$app) : [wm::get $id title]}]
	$e selection range 0 end
	place $e -x [expr {$px + 30}] -y [expr {$py + 2}] -width [expr {max(140, $pw - 36)}] -height [expr {$ph - 4}]
	bind $e <Return> [list term::rename_done $g $app 1]
	bind $e <KP_Enter> [list term::rename_done $g $app 1]
	bind $e <Escape> [list term::rename_done $g $app 0]
	bind $e <FocusOut> [list term::rename_done $g $app 1]
	raise $e
	focus -force $e
}
proc term::rename_done {g app keep} {
	variable G
	if {![info exists G($g,top)]} return
	set e $G($g,top).rename
	if {![winfo exists $e]} return
	set name [string trim [$e get]]
	bind $e <FocusOut> {}
	::destroy $e
	if {$keep} { if {$name eq ""} { unset -nocomplain G($g,name,$app) } else { set G($g,name,$app) [string range $name 0 63] } }
	set G($g,sig) ""; redraw $g
}
# Move to a new window: the tab takes the app-id of a new group's first tab (foot's OSC 176, written to the tab's
# terminal through its shell), and the new group, with its own strip, takes it in.
proc term::to_window {g id} {
	variable G
	variable groups
	variable pending
	variable tabprof
	set app [wm::get $id app]
	if {[llength $G($g,tabs)] < 2 || [string match *-prefs $app]} return
	set pid [shell_of $app]
	if {$pid eq ""} return
	set n 1
	while {"g$n" in $groups || [dict exists $pending g$n]} { incr n }
	set new ribbon-term-g$n-1
	if {[catch {
		set f [::open [tty_of $pid] w]
		fconfigure $f -translation binary
		puts -nonewline $f "\033\]176;$new\033\\"
		::close $f
	} err]} { log to_window $err; return }
	if {[info exists tabprof($app)]} { set tabprof($new) $tabprof($app) }
	foreach k {name size} { if {[info exists G($g,$k,$app)]} { set keep($k) $G($g,$k,$app) } }
	create g$n
	set G(g$n,seq) 1
	set G(g$n,x) [expr {$G($g,x) + 28}]; set G(g$n,y) [expr {$G($g,y) + 28}]; set G(g$n,w) $G($g,w); set G(g$n,h) $G($g,h)
	foreach k [array names keep] { set G(g$n,$k,$new) $keep($k) }
	wm geometry $G(g$n,top) $G(g$n,w)x$term::STRIP+$G(g$n,x)+$G(g$n,y)
	$G(g$n,top).c configure -width $G(g$n,w)
	apply_rc
	log to_window $app $new
}

# Rectangles of the work area (between the bars of the main display, with labwc's 8 px gap). The strip owns the group's
# geometry, so labwc's own snap, which would act on one tab, is rebound to these (rc.xml INTEGRATION REQUEST).
proc term::snap {g how} {
	variable G
	set top [expr {$bar::Y0 + 54}]; set H [expr {$bar::H - 108}]; set W $bar::W; set gap 8; set x0 $bar::X0
	if {$how ne "restore" && !($G($g,max) || $G($g,saved) ne {})} { set G($g,saved) [list $G($g,x) $G($g,y) $G($g,w) $G($g,h)] }
	switch -- $how {
		left { set r [list [expr {$x0 + $gap}] [expr {$top + $gap}] [expr {$W / 2 - $gap - $gap / 2}] [expr {$H - 2 * $gap}]]; set G($g,max) 0 }
		right { set r [list [expr {$x0 + $W / 2 + $gap / 2}] [expr {$top + $gap}] [expr {$W / 2 - $gap - $gap / 2}] [expr {$H - 2 * $gap}]]; set G($g,max) 0 }
		max { set r [list $x0 $top $W $H]; set G($g,max) 1 }
		restore {
			set G($g,max) 0
			if {$G($g,saved) eq {}} return
			set r $G($g,saved); set G($g,saved) {}
		}
	}
	setrect $g {*}$r
}

# ---------------------------------------------------------------- ribbon-term-ctl (verb `term`)
proc term::verb {args} {
	variable G
	set what [lindex $args 0]
	switch -- $what {
		group { newgroup; return }
		activity { set id [lindex $args 1]; set g [group_of $id]; if {$g ne "" && $id ne $G($g,cur) && [setting marktab]} { set G($g,mark,$id) 1; redraw $g }; return }
	}
	if {$what eq "activity-app"} {
		# `[desktop-notifications] command=ribbon-term-ctl activity-app ${app-id}`
		foreach id $wm::order { if {[wm::get $id app] eq [lindex $args 1]} { verb activity $id } }
		return
	}
	if {$what eq "new"} { new [lrange $args 1 end]; return }
	if {$what eq "newin"} {
		# `ribbon-term-ctl newin HEX`: a new tab in the folder whose name is HEX (UTF-8 bytes as hex digits)
		set hex [lindex $args 1]
		set dir ""
		if {[regexp {^[0-9a-f]+$} $hex] && [string length $hex] % 2 == 0 && [string length $hex] <= 8192} {
			catch { set dir [encoding convertfrom utf-8 [binary format H* $hex]] }
		}
		new {} [expr {$dir ne "" && [file isdirectory $dir] ? $dir : ""}]
		return
	}
	if {$what eq "restart"} { restart; return }
	if {$what eq "show-prefs"} {
		set g [lindex $args 1]
		if {[info exists G($g,tabs)]} { foreach id $G($g,tabs) { if {[string match *-prefs [wm::get $id app]]} { select $g $id } } }
		return
	}
	if {$what eq "prefs"} { prefs; return }
	set g [which]
	if {$g eq ""} return
	switch -- $what {
		next { step $g 1 }
		prev { step $g -1 }
		close { if {$G($g,cur) ne ""} { close $G($g,cur) } }
		tab { set id [lindex $G($g,tabs) [expr {[lindex $args 1] - 1}]]; if {$id ne ""} { select $g $id } }
		snap { snap $g [lindex $args 1] }
		move { move $g [lindex $args 1] }
		sendto { press C-A-S-W-F[lindex $args 1] }
	}
}
shell::verb term term::verb

# Rules left by an earlier shell (crashed, or restarted with the terminal open) are dropped at start.
proc term::init {} {
	variable rcsig
	set rc [rcfile]
	if {[file exists $rc] && [file size $rc] > 200} { apply_rc }
}

term::loadstate
after 10000 term::prune
trace add execution wm::changed leave term::sync
after idle term::init
