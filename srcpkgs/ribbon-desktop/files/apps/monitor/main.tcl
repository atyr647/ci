# main.tcl - System monitor (ribbon-monitor), the Ledger window (Monitor-R3-Ledger and
# -Ledger-Processes) on the Appearance app's drawing (appearance/ui.tcl) and the shell's
# rasteriser, text and theme code, in the colours of the active theme. The rail's metric rows
# sort the table and GPU opens the GPU page (Monitor-R3-Ledger-GPU, gpupage.tcl); apps open into
# their processes; End (TERM, then KILL) on the selected row; a right click or the Menu key opens
# the row's menu (menu.tcl); Search filters the rows; a process that does not respond is tagged
# (stuck.tcl); the rail's foot is the game overlay's Compact card (foot.tcl). The window opens at the board's
# 1240 x 760 fitted under the shell's bars and resizes and maximises (monitor::resized). Per-app network is not
# shown: no source gives a process's bytes without eBPF.
# Keys: Del End, Shift Del Force end, Alt Enter Properties, Menu the row's menu, Escape closes.
#
#   ribbon-monitor [--view apps|processes]
#   RIBBON_MONITOR_SCENE=FILE  a scene (tests/monitor-scene.tcl) drawn on a 1440 x 900 desktop
#
# The window is drawn from a model dict (see monitor::model_live): the live sampler fills it
# once a second, and a scene can set one directly to reproduce a board's numbers.

if {$tcl_platform(platform) eq "unix"} { encoding system utf-8 }
set appdir [file dirname [file normalize [info script]]]
namespace eval monitor {}

# A folder next to this app (the repo's files/, or the installed /usr/lib/ribbon).
proc monitor::find {name file} {
	foreach d [list [file join $::appdir .. $name] [file join $::appdir .. .. $name] /usr/lib/ribbon/$name] {
		if {[file exists [file join $d $file]]} { return [file normalize $d] }
	}
	puts stderr "ribbon-monitor: $name/$file was not found"; exit 1
}

set shelldir [expr {[info exists ::env(RIBBON_SHELL_DIR)] ? $::env(RIBBON_SHELL_DIR) : [monitor::find shell raster.tcl]}]
set appearancedir [monitor::find appearance ui.tcl]
foreach d [list /usr/lib/ribbon [file dirname $shelldir]] { if {$d ni $auto_path} { lappend auto_path $d } }
catch {package require rbnalpha}
foreach f {text raster wall theme} { source -encoding utf-8 [file join $shelldir $f.tcl] }
source -encoding utf-8 [file join $appearancedir ui.tcl]
foreach f {proc group gpu stuck services history rail table gpupage menu servicespage foot} { source -encoding utf-8 [file join $appdir $f.tcl] }

namespace eval monitor {
	variable win .w
	variable scene 0
	variable view apps        ;# apps | processes
	variable metric apps      ;# the rail row chosen: apps, or cpu gpu vram mem disk net
	variable sort cpu         ;# the table's sort column: cpu gpu vram mem disk (threads, pid in Processes)
	variable W 1240           ;# the window's size: the board's, fitted under the bars, or what it was resized to
	variable H 760
	variable expanded {}      ;# app ids whose processes are open
	variable sel ""           ;# the selected row: app:ID or pid:PID
	variable model {}         ;# what is drawn (monitor::model_live, or a scene's)
	variable prev ""          ;# the last snapshot (for rates)
	variable gfx                ;# pid -> the last gfx ns, for the GPU rate
	array set gfx {}
	variable last_ms 0
	variable tick_ms 1000
	variable timer ""
	variable stuck {}         ;# the pids not responding (stuck.tcl)
	variable slow             ;# what is asked for less often than once a second
	array set slow {n 0 gamemode 0 display ""}
	variable gpu_since 0      ;# when the GPU's history began (seconds)
}
set ui::fonts(i11) {{Ribbon Inter 400} 11 0.96875 0.2412}
set ui::fonts(sg36) {{Ribbon Space Grotesk 600} 36 0.984 0.292}
# ui.tcl's press and its text field call the page; here the page is this window
namespace eval page {
	proc draw {} { ::monitor::draw }
	proc clicked_outside {} { if {$::ui::focus ne ""} { set ::ui::focus ""; ::monitor::draw } }
}

# The model the window draws. Fields: cpu gpu vram_used vram_total mem_used mem_total
# disk net_rx net_tx (rates, bytes a second; cpu and gpu in percent), apps (list of dicts:
# id name count cpu gpu mem disk procs), procs (every process: pid name app cpu mem
# threads). Per-app network is not sampled: no source gives a process's bytes without eBPF.
proc monitor::model_live {} {
	variable prev
	variable gfx
	variable stuck
	variable slow
	set cur [sample]
	set card [gpu::card]
	if {$prev eq ""} {
		# the first sample has no interval yet: every rate is 0
		set zero {}
		foreach p [dict get $cur procs] { dict set p cpu 0.0; dict set p disk_rate 0.0; lappend zero $p }
		set r [dict create cpu 0.0 ncpu [dict get $cur cpu] mem [dict get $cur mem] net_rx 0 net_tx 0 \
			disk_rd 0 disk_wr 0 procs $zero]
		set dt 1.0
	} else {
		set r [rates $prev $cur]
		set dt [expr {max(0.001, ([dict get $cur time] - [dict get $prev time]) / 1000.0)}]
	}
	set prev $cur
	# per-process GPU: the change in engine time over the interval, in percent (xe: its cycles against the
	# engines' total); NVIDIA's processes come from nvidia-smi
	set nv [expr {$card ne "" && [dict get $card driver] eq "nvidia" ? [gpu::nvidia_procs] : {}}]
	set gp [dict create]
	set gsum 0.0
	set gone [array names gfx]
	foreach p [dict get $cur procs] {
		set pid [dict get $p pid]
		set g [gpu::process $pid]
		set now [list [dict get $g gfx] [dict get $g cycles] [dict get $g total]]
		set pct 0.0
		if {[info exists gfx($pid)]} {
			lassign $gfx($pid) ns0 cyc0 tot0
			if {[lindex $now 0] > $ns0} { set pct [expr {100.0 * ([lindex $now 0] - $ns0) / ($dt * 1e9)}] }
			if {[lindex $now 2] > $tot0 && [lindex $now 1] > $cyc0} {
				set pct [expr {$pct + 100.0 * ([lindex $now 1] - $cyc0) / ([lindex $now 2] - $tot0)}]
			}
		}
		set gfx($pid) $now
		set vram [dict get $g vram]
		if {[dict exists $nv $pid]} { lassign [dict get $nv $pid] pct vram }
		set gsum [expr {$gsum + $pct}]
		dict set gp $pid [list $pct $vram]
	}
	foreach pid $gone { if {![dict exists $gp $pid]} { unset gfx($pid); gpu::forget $pid } }
	set procs {}
	foreach p [dict get $r procs] {
		set pid [dict get $p pid]
		set gv [expr {[dict exists $gp $pid] ? [dict get $gp $pid] : {0.0 0}}]
		lappend procs [dict create pid $pid start [dict get $p start] name [dict get $p comm] cmd [dict get $p exe] cmdline [dict get $p cmd] \
			cgroup [dict get $p cgroup] ppid [dict get $p ppid] cpu [dict get $p cpu] state [dict get $p state] \
			mem [dict get $p rss] threads [dict get $p threads] disk [dict get $p disk_rate] \
			gpu [lindex $gv 0] vram [lindex $gv 1] \
			stuck [expr {$pid in $stuck && [dict get $p state] ne "T"}]]
	}
	array set byp {}
	foreach p $procs { set byp([dict get $p pid]) $p }
	set mem [dict get $r mem]
	set total [expr {[dict exists $mem MemTotal] ? [dict get $mem MemTotal] : 0}]
	set avail [expr {[dict exists $mem MemAvailable] ? [dict get $mem MemAvailable] : 0}]
	# apps from the processes' grouping, with the sums each row shows
	set apps {}
	foreach a [group::assign [dict get $r procs] [group::desktops]] {
		set pids [dict get $a pids]
		set ps {}
		foreach pid $pids { if {[info exists byp($pid)]} { lappend ps $byp($pid) } }
		set c 0.0; set g 0.0; set m 0; set d 0.0; set v 0
		foreach p $ps {
			set c [expr {$c + [dict get $p cpu]}]
			set g [expr {$g + [dict get $p gpu]}]
			set m [expr {$m + [dict get $p mem]}]
			set d [expr {$d + [dict get $p disk]}]
			set v [expr {$v + [dict get $p vram]}]
		}
		lappend apps [dict create id [dict get $a id] name [dict get $a name] count [llength $pids] \
			cpu $c gpu $g mem $m disk $d vram $v pids $pids]
	}
	set pname [dict create]; set pid_app [dict create]
	foreach a $apps { foreach pid [dict get $a pids] { dict set pname $pid [dict get $a name]; dict set pid_app $pid [dict get $a id] } }
	set tagged {}
	foreach p $procs {
		set pid [dict get $p pid]
		dict set p app [expr {[dict exists $pname $pid] ? [dict get $pname $pid] : ""}]
		dict set p appid [expr {[dict exists $pid_app $pid] ? [dict get $pid_app $pid] : ""}]
		lappend tagged $p
	}
	set procs $tagged
	# the card's load: its own figure; the Intel drivers have none, so the processes' engine time stands for it
	set gpu_pct 0
	if {$card ne ""} {
		if {[dict get $card busy] eq "" && [dict get $card driver] in {i915 xe}} { dict set card busy [expr {min(100.0, $gsum)}] }
		if {[dict get $card busy] ne ""} { set gpu_pct [dict get $card busy] }
	}
	# GameMode and the screen's mode are other programs' answers: asked every tenth sample
	if {[incr slow(n)] % 10 == 1} { set slow(gamemode) [gamemode_now]; set slow(display) [display_now] }
	return [dict create cpu [dict get $r cpu] gpu $gpu_pct card $card \
		vram_used [expr {$card ne "" && [dict get $card vram_used] ne "" ? [dict get $card vram_used] : 0}] \
		vram_total [expr {$card ne "" && [dict get $card vram_total] ne "" ? [dict get $card vram_total] : 0}] \
		mem_used [expr {max(0, $total - $avail)}] mem_total $total \
		disk [expr {[dict get $r disk_rd] + [dict get $r disk_wr]}] \
		disk_rd [dict get $r disk_rd] disk_wr [dict get $r disk_wr] \
		net_rx [dict get $r net_rx] net_tx [dict get $r net_tx] \
		ncpu [dict get $r ncpu] apps $apps procs $procs \
		game [game::find [dict get $cur procs] $pname] frames [game::frames] \
		gamemode $slow(gamemode) display $slow(display)]
}

# One sample into the model and the histories, then a redraw (no timer).
proc monitor::refresh {} {
	variable model
	variable stuck
	variable gpu_since
	variable sel
	variable menu
	set stuck [stuck::update]
	# a selected process (and its menu) is the process, not the pid: when it has gone, or another process has
	# taken its pid, it is no longer selected
	set was [expr {[string match pid:* $sel] ? [proc_of [string range $sel 4 end]] : ""}]
	set model [model_live]
	if {[string match pid:* $sel]} {
		set now [proc_of [string range $sel 4 end]]
		if {$was eq "" || $now eq "" || [dict get $was start] ne [dict get $now start]} {
			if {$menu ne "" && [dict get $menu key] eq $sel} { set menu "" }
			set sel ""
		}
	}
	ring::push cpu [dict get $model cpu]
	set card [dict get $model card]
	if {$card ne "" && [dict get $card busy] ne ""} {
		if {!$gpu_since} { set gpu_since [clock seconds] }
		ring::push gpu [dict get $model gpu]
		ring::push gputemp [dict get $card temp]
		dict set model gpu_secs [expr {min(3600, max(1, [clock seconds] - $gpu_since))}]
	}
	ring::push mem [dict get $model mem_used]
	draw
}

# The sampling tick: once a second. Asking for one early (after End) does not start a second timer.
proc monitor::tick {} {
	variable timer
	after cancel $timer
	refresh
	set timer [after $::monitor::tick_ms ::monitor::tick]
}

# The buttons' and rows' actions. End sends TERM to the row's processes, and KILL to what is left (menu.tcl).
proc monitor::end_selected {} {
	variable sel
	variable model
	if {[string match app:* $sel]} {
		set id [string range $sel 4 end]
		foreach a [dict get $model apps] { if {[dict get $a id] eq $id} { set pids [dict get $a pids] } }
	} elseif {[string match pid:* $sel]} {
		set pids [string range $sel 4 end]
	} else { return }
	if {![info exists pids]} return
	if {$::monitor::scene} return
	set ids [model_idents $pids]
	set pids [row_signalable $sel]
	if {![llength $pids]} return
	# an app with several processes, or one not responding, asks first (sheet.tcl)
	if {[end_ask $sel]} return
	end_soon $pids 2000 $ids
	set sel ""
	refresh
}

# A right click: the menu of the row under it. The Menu key: the selected row's, under the row.
proc monitor::context {x y} {
	variable metric
	variable menu
	set x [expr {$x - $::ui::ox}]; set y [expr {$y - $::ui::oy}]
	if {$metric in {gpu services}} return
	if {$menu ne ""} { set menu "" }
	set key [row_at $x $y]
	if {$key eq ""} { draw; return }
	menu_open $key $x $y
}
proc monitor::pointer {x y} { menu_motion [expr {$x - $::ui::ox}] [expr {$y - $::ui::oy}] }

# Keys: the menu's when it is open, the search field's when it has the focus, else the table's.
proc monitor::key {sym char state} {
	variable sel
	variable menu
	variable metric
	if {[menu_key $sym]} return
	if {$::ui::focus eq "search"} {
		if {$sym eq "Escape"} { ui::fset search ""; set ::ui::focus ""; search_changed; return }
		if {[ui::field_key search $sym $char $state]} { search_changed }
		return
	}
	if {$metric in {gpu services} || $sel eq ""} return
	set shift [expr {$state & 1}]; set alt [expr {$state & 8}]
	switch -- $sym {
		Delete - KP_Delete { set menu [dict create key $sel x 0 y 0 hover ""]; menu_pick [expr {$shift ? "kill" : "end"}] }
		Return - KP_Enter { if {$alt} { set menu [dict create key $sel x 0 y 0 hover ""]; menu_pick props } }
		Menu { set y [row_y $sel]; if {$y ne ""} { menu_open $sel 500 [expr {$y + 33}] } }
		Escape { set sel ""; draw }
	}
}

# The top of a row on the page ("" when it is scrolled away or gone).
proc monitor::row_y {key} {
	variable model
	variable row_top
	variable row_h
	variable scroll
	set i 0
	foreach r [rows $model] {
		if {$key eq [row_key $r]} {
			set y [expr {$row_top + $i * $row_h - $scroll}]
			return [expr {$y >= $row_top && $y < $::monitor::H ? $y : ""}]
		}
		incr i
	}
	return ""
}

# Choosing a rail row: the table sorts by it.
proc monitor::choose {m} {
	variable metric
	variable sort
	set metric $m
	switch -- $m {
		cpu { set sort cpu } gpu { set sort gpu } vram { set sort vram } mem { set sort mem } disk { set sort disk }
		default { }
	}
	draw
}

proc monitor::draw {} {
	variable win
	variable model
	variable scene
	variable view
	variable metric
	ui::begin [list monitor-$view-$::monitor::metric-$::monitor::sort-[join $::monitor::expanded ,]-$::monitor::sel $::monitor::W $::monitor::H] \
		[list monitor::paint_boxes]
	rail_draw $model
	services_rail_draw
	switch -- $metric { gpu { gpu_draw $model } services { services_draw $model } default { table_draw $model } }
	menu_draw
	ui::finish
}

# A new window size (resized, maximised): the canvas follows at once, and the window is drawn again for it once the
# sizes stop coming (a drag sends many). The frames drawn for the old size are let go.
proc monitor::resized {w h} {
	variable win; variable W; variable H; variable relayout
	if {$w < 2 || $h < 2 || ($w == $W && $h == $H)} return
	set W $w; set H $h
	set ::ui::W $w; set ::ui::H $h
	$win.c configure -width $w -height $h
	place $win.c -x 0 -y 0 -width $w -height $h
	if {[info exists relayout]} { after cancel $relayout }
	set relayout [after 40 monitor::relayout]
}
proc monitor::relayout {} {
	variable relayout; variable W; variable H; variable scroll; variable row_h
	unset -nocomplain relayout
	foreach k [array names ::ui::frames] {
		set key [lindex $k 0]
		if {[string match monitor-* [lindex $key 0]] && [lrange $key 1 2] ne [list $W $H]} {
			catch {image delete $::ui::frames($k)}
			unset ::ui::frames($k)
		}
	}
	# a taller page may show rows that were scrolled off
	set n [llength [rows $::monitor::model]]
	set scroll [expr {max(0, min($scroll, $n * $row_h - ($H - 153)))}]
	if {$::monitor::menu ne ""} { set ::monitor::menu "" }
	draw
}

# The window's chrome, painted into the frame cache (the rail's fill and the page's rules).
proc monitor::paint_boxes {} {
	ui::box 0 0 268 $::monitor::H -fill $::ui::c(d2)
	ui::box 267 0 1 $::monitor::H -fill $::ui::c(border)
}

proc monitor::main {} {
	variable win
	variable scene
	variable view
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}]
	set cache [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$home/.cache"}]
	theme::load
	raster::init [file join $cache ribbon monitor]
	ui::fonts
	ui::colours [array get ::theme::c]
	set scene [info exists ::env(RIBBON_MONITOR_SCENE)]
	foreach {k v} $::argv {
		if {$k eq "--view"} { set view $v }
	}
	wm withdraw .
	set SW [winfo screenwidth .]; set SH [winfo screenheight .]
	if {$scene} {
		set ::ui::W 1240; set ::ui::H 760
		toplevel $win -class RibbonMonitor -borderwidth 0 -highlightthickness 0
		wm overrideredirect $win 1
		wm geometry $win 1440x900+0+0
		set ui::ox 100; set ui::oy 84
		set ui::behind [ui::desktop 1440 900]
		set ui::bx 100; set ui::by 84
		canvas $win.c -width 1440 -height 900 -highlightthickness 0 -borderwidth 0 -background $ui::c(bar)
		$win.c create image 0 0 -image $ui::behind -anchor nw -tags desk
		pack $win.c
	} else {
		# labwc keeps the frame on the screen: a taller window than the room under the bars is fitted (rbn::fit)
		variable W; variable H
		if {[info commands ::rbn::fit] ne ""} { set H [rbn::fit $H] }
		set ::ui::W $W; set ::ui::H $H
		if {[rbn::appwindow $win RibbonMonitor $W $H -fill $ui::c(bar)]} { set ui::argbwin $win }
		wm title $win "System monitor"
		wm iconname $win "System monitor"
		# the window resizes and maximises (monitor::resized): the rail and the page's columns keep their board sizes
		# and places from the right edge, the Name column and the rows take the room. The board's size, fitted under
		# the bars, is where it starts and the least it can be.
		wm minsize $win $W $H
		set x [expr {max(0, ($SW - $W) / 2)}]; set y [expr {max(0, ($SH - $H) / 2 + 14)}]
		wm geometry $win ${W}x$H+$x+$y
		wm protocol $win WM_DELETE_WINDOW exit
		set ui::behind ""
		set ui::bx 0; set ui::by 0
		if {![winfo exists $win.c]} {
			canvas $win.c -width $W -height $H -highlightthickness 0 -borderwidth 0 -background $ui::c(bar)
		}
		$win configure -width $W -height $H
		place $win.c -x 0 -y 0 -width $W -height $H
		bind $win <Configure> {if {"%W" eq $::monitor::win} {monitor::resized %w %h}}
	}
	set ui::cv $win.c
	bind $win.c <ButtonPress-1> {ui::press %x %y}
	bind $win.c <B1-Motion> {ui::motion %x %y}
	bind $win.c <ButtonRelease-1> {ui::release %x %y}
	bind $win.c <Button-4> {ui::scroll %x %y -1}
	bind $win.c <Button-5> {ui::scroll %x %y 1}
	bind $win.c <MouseWheel> {ui::scroll %x %y [expr {%D > 0 ? -1 : 1}]}
	bind $win.c <ButtonPress-3> {monitor::context %x %y}
	bind $win.c <Motion> {monitor::pointer %x %y}
	bind $win <KeyPress> {monitor::key %K %A %s}
	if {$scene} {
		uplevel #0 [list source -encoding utf-8 $::env(RIBBON_MONITOR_SCENE)]
		draw
	} else {
		tick
	}
	focus -force $win
}

monitor::main
