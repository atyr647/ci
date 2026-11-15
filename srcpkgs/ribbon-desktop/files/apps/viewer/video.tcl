# video.tcl - a video in the Image viewer (Viewer-Final-5-Video, -11-Video-Paused): mpv plays it in a window of its
# own, placed over the fitted picture (--wid), and is driven over its JSON IPC socket; the viewer draws the
# transport in its toolbar's place: play or pause, the position, the scrubber, the length, the volume (a click on
# its icon mutes) and full screen. Until mpv's first frame shows, the stage has the video's first frame
# (stage.tcl, through ffmpeg, as a picture).
#
#   video::available        mpv and the unix_extra package (the IPC socket) are both there
#   video::is FILE          a video by its extension
#   video::open FILE        start mpv on FILE (after the stage has placed the frame: video::place)
#   video::place X Y W H    put mpv's window over the picture's rectangle (each draw)
#   video::close            stop mpv and drop its window
#   video::toolbar SW       the transport, 44 tall, 20 above the window's foot, centred on a stage SW wide
#   video::toggle, seek F, set_volume V, mute    the transport's actions, over IPC
#
# The model (pos, dur, paused, vol, muted, eof) follows mpv's property-change events (observe_property). Volume and
# mute are kept for the next video and the next start in ~/.config/ribbon/viewer.conf. A scene stands the model in
# (video::standin): no mpv is started and the first frame stays on the stage.

namespace eval video {
	variable exts {mp4 m4v mkv webm mov avi}
	variable on 0          ;# a video is open
	variable file ""
	variable pid ""
	variable sock ""
	variable chan ""
	variable win ""        ;# mpv's window (a Tk frame)
	variable started 0
	variable standin 0
	variable pos 0.0
	variable dur 0.0
	variable paused 0
	variable vol 100
	variable muted 0
	variable eof 0
	variable drag ""       ;# scrub | vol while a slider is held
	variable shown ""      ;# what the transport last drew (it is drawn again only when that changes)
	variable tries 0
	variable track {0 0}   ;# the scrubber's x and width
	variable vtrack {0 0}  ;# the volume slider's
	variable frozen ""     ;# mpv's frame while the menu is open
	variable serial 0      ;# mpv's started so far (each has its own socket)
	variable P
	array set P {
		pause  {M7 5h3v14H7z M14 5h3v14h-3z}
		play   {M7 4l13 8-13 8z}
		volume {M11 5L6 9H2v6h4l5 4z M15.54 8.46a5 5 0 0 1 0 7.07 M19.07 4.93a10 10 0 0 1 0 14.14}
		mute   {M11 5L6 9H2v6h4l5 4z M22 9l-6 6 M16 9l6 6}
		expand {M15 3h6v6 M9 21H3v-6 M21 3l-7 7 M3 21l7-7}
	}
}

proc video::available {} {
	if {[auto_execok mpv] eq ""} { return 0 }
	expr {![catch {package require unix_extra}]}
}

proc video::is {file} {
	variable exts
	expr {[string range [string tolower [file extension $file]] 1 end] in $exts}
}

# ---- settings ------------------------------------------------------------------------------------

proc video::conf {} {
	set base [expr {[info exists ::env(XDG_CONFIG_HOME)] ? $::env(XDG_CONFIG_HOME) : "$::env(HOME)/.config"}]
	file join $base ribbon viewer.conf
}

proc video::load_conf {} {
	variable vol; variable muted
	if {[catch {set fh [::open [video::conf] r]}]} return
	foreach line [split [::read $fh] \n] {
		if {[regexp {^volume=(\d+)$} $line -> v]} { set vol [expr {min(100, $v)}] }
		if {[regexp {^muted=([01])$} $line -> m]} { set muted $m }
	}
	::close $fh
}

proc video::save_conf {} {
	variable vol; variable muted
	catch {
		file mkdir [file dirname [video::conf]]
		set fh [::open [video::conf] w]
		puts $fh "volume=[expr {round($vol)}]\nmuted=$muted"
		::close $fh
	}
}

# ---- mpv ------------------------------------------------------------------------------------------

# The IPC socket's path: short (a socket path holds 107 bytes), in a folder only this user can enter (sockdir); one
# for each mpv started, so the last one's clean-up (its delete, mpv's own unlink as it quits) never takes the next
# one's socket. "" when there is no such folder: no mpv is started (anyone could put a socket at a /tmp path first).
proc video::sockpath {} {
	variable serial
	set d [video::sockdir]
	if {$d eq ""} { return "" }
	incr serial
	file join $d "ribbon-viewer-[pid]-$serial.mpv"
}

# The runtime folder (XDG_RUNTIME_DIR) when it is this user's and closed to others, else a private folder of the
# viewer's own (mktemp -d makes it 0700 in one step), removed as the viewer exits; "" when neither can be had.
proc video::private {d} {
	if {$d eq "" || [file type $d] ne "directory" || ![file owned $d]} { return 0 }
	if {[catch {file stat $d st}]} { return 0 }
	expr {($st(mode) & 0o077) == 0}
}
proc video::sockdir {} {
	variable rundir
	if {[info exists ::env(XDG_RUNTIME_DIR)] && ![catch {video::private $::env(XDG_RUNTIME_DIR)} ok] && $ok} { return $::env(XDG_RUNTIME_DIR) }
	if {[info exists rundir] && ![catch {video::private $rundir} ok] && $ok} { return $rundir }
	if {[catch {exec mktemp -d [file join [expr {[info exists ::env(TMPDIR)] && $::env(TMPDIR) ne "" ? $::env(TMPDIR) : "/tmp"}] ribbon-viewer.XXXXXXXX]} d]} { return "" }
	if {[catch {video::private $d} ok] || !$ok} { catch {file delete $d}; return "" }
	set rundir $d
	return $d
}
# The viewer is going: its own socket folder goes with it.
proc video::cleanup {} {
	variable rundir
	video::close
	if {[info exists rundir]} { catch {file delete -force -- $rundir}; unset rundir }
}

proc video::open {file} {
	variable on; variable pos; variable dur; variable paused; variable eof; variable shown; variable started
	video::close
	set ::video::file $file
	set on 1; set pos 0.0; set dur [video::probe_duration $file]; set paused 0; set eof 0; set shown ""; set started 0
}

# The length from the container (ffprobe), so the transport reads right before mpv answers; 0 when unknown.
proc video::probe_duration {file} {
	if {[auto_execok ffprobe] eq ""} { return 0.0 }
	if {[catch {exec ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $file 2>/dev/null} r]} { return 0.0 }
	if {[string is double -strict [string trim $r]]} { return [string trim $r] }
	return 0.0
}

# When the video was made: the container's creation_time (UTC), as epoch seconds; "" when it has none.
proc video::created {file} {
	if {[auto_execok ffprobe] eq ""} { return "" }
	if {[catch {exec ffprobe -v error -show_entries format_tags=creation_time -of default=nw=1:nk=1 $file 2>/dev/null} r]} { return "" }
	if {[regexp {^(\d{4}-\d\d-\d\d)T(\d\d:\d\d:\d\d)} [string trim $r] -> d t]} {
		if {![catch {clock scan "$d $t" -format {%Y-%m-%d %H:%M:%S} -timezone :UTC} s] && $s > 0} { return $s }
	}
	return ""
}

# mpv's window over the picture's rectangle; mpv starts once the window exists.
proc video::place {x y w h} {
	variable on; variable win; variable started; variable standin
	if {!$on || $standin} return
	set top $::viewer::win
	if {$win eq "" || ![winfo exists $win]} {
		set win $top.video
		frame $win -background #000000 -borderwidth 0 -highlightthickness 0 -takefocus 0
		bind $win <ButtonPress-1> {video::toggle}
	}
	::place $win -x [expr {round($x)}] -y [expr {round($y)}] -width [expr {round($w)}] -height [expr {round($h)}]
	raise $win
	if {!$started} {
		set started 1
		update idletasks
		video::start
	}
}

# Freeze the stage while something is drawn over it (the menu): mpv saves the frame it shows, the stage takes it as
# its picture, and mpv's window is hidden; video::place shows it again. Without mpv's frame (no answer in 1 s) the
# window is hidden over the first frame.
proc video::freeze {} {
	variable win; variable chan; variable frozen
	if {$win eq "" || ![winfo exists $win] || ![winfo ismapped $win]} return
	set frozen [stage::tmp png]
	if {![video::send screenshot-to-file $frozen video]} { video::hide; return }
	after 30 [list video::frozen 0 $frozen]
}
# (a frame that lands after its video was closed is dropped: the stage holds the next item)
proc video::frozen {n path} {
	variable frozen; variable on
	if {!$on || $path ne $frozen} { catch {file delete $path}; return }
	if {[file exists $frozen] && [file size $frozen] > 0 && ![catch {stage::still $frozen}]} { video::hide; viewer::draw; return }
	if {$n >= 33} { video::hide; viewer::draw; return }
	after 30 [list video::frozen [incr n] $path]
}
proc video::hide {} {
	variable win
	if {$win ne "" && [winfo exists $win]} { ::place forget $win }
}

proc video::start {} {
	variable file; variable win; variable pid; variable sock; variable vol; variable muted; variable tries
	set sock [video::sockpath]
	if {$sock eq ""} { set pid ""; return }
	catch {file delete $sock}
	set cmd [list mpv --wid=[winfo id $win] --input-ipc-server=$sock --keep-open=yes --idle=no \
		--no-osc --osd-level=0 --no-input-default-bindings --input-vo-keyboard=no --input-cursor=no --cursor-autohide=no \
		--no-terminal --force-window=yes --hwdec=auto-safe --volume=[expr {round($vol)}] --mute=[expr {$muted ? "yes" : "no"}] \
		--loop-file=no -- $file]
	if {[info exists ::env(RIBBON_VIEWER_MPV_ARGS)]} { set cmd [linsert $cmd 1 {*}$::env(RIBBON_VIEWER_MPV_ARGS)] }
	if {[catch {set pid [exec {*}$cmd </dev/null >/dev/null 2>/dev/null &]}]} { set pid ""; return }
	set tries 0
	after 50 video::connect
}

# Connect to mpv's socket (it comes up a moment after mpv starts): up to 5 s.
proc video::connect {} {
	variable sock; variable chan; variable tries; variable on
	if {!$on || $chan ne ""} return
	if {[file exists $sock] && ![catch {unix_extra::connect $sock} c]} {
		set chan $c
		fconfigure $chan -blocking 0 -buffering line -translation lf -encoding utf-8
		fileevent $chan readable [list video::readable $chan]
		set id 0
		foreach p {time-pos duration pause volume mute eof-reached} { video::send observe_property [incr id] $p }
		return
	}
	if {[incr tries] < 100} { after 50 video::connect }
}

# A JSON array of the command's words: numbers and booleans as they are, the rest as strings.
proc video::json {words} {
	set out {}
	foreach w $words {
		if {[string is double -strict $w] || $w in {true false}} { lappend out $w; continue }
		lappend out "\"[string map {\\ \\\\ \" \\\" \n \\n} $w]\""
	}
	return "\[[join $out ,]\]"
}

proc video::send {args} {
	variable chan
	if {$chan eq ""} { return 0 }
	if {[catch {puts $chan "{\"command\":[video::json $args]}"; flush $chan}]} { video::lost; return 0 }
	return 1
}

proc video::readable {c} {
	if {[catch {gets $c line} n] || $n < 0} {
		if {[catch {eof $c} e] || $e} { video::lost }
		return
	}
	video::event $line
}

# One line from mpv: a property change updates the model, then the transport is drawn again when what it shows
# changed (the second, the scrubber's pixel, the buttons).
proc video::event {line} {
	variable pos; variable dur; variable paused; variable vol; variable muted; variable eof; variable drag
	if {![regexp {"event":"property-change"} $line]} return
	if {![regexp {"name":"([^"]+)"} $line -> name]} return
	set data ""
	regexp {"data":(true|false|null|-?[0-9.eE+-]+)} $line -> data
	switch -- $name {
		time-pos { if {[string is double -strict $data] && $drag ne "scrub"} { set pos $data } }
		duration { if {[string is double -strict $data]} { set dur $data } }
		pause { set paused [expr {$data eq "true"}] }
		volume { if {[string is double -strict $data] && $drag ne "vol"} { set vol $data } }
		mute { set muted [expr {$data eq "true"}] }
		eof-reached { set eof [expr {$data eq "true"}] }
	}
	video::changed
}

proc video::changed {} {
	variable shown
	if {[video::key] ne $shown} { viewer::draw }
}

# What the transport shows: the drawn time, the knobs' pixels and the buttons.
proc video::key {} {
	variable pos; variable dur; variable paused; variable vol; variable muted; variable eof
	list [video::hms $pos] [video::hms $dur] [expr {$dur > 0 ? round($pos / $dur * 440) : 0}] [expr {round($vol)}] $paused $muted $eof
}

# mpv went away (it quit, or its socket closed): the model stays as it was, paused.
proc video::lost {} {
	variable chan; variable paused
	if {$chan ne ""} { catch {::close $chan} }
	set chan ""
	set paused 1
}

# Stop mpv (it is asked to quit, and ended half a second later; NOW ends it at once: the viewer is going).
proc video::close {{now 0}} {
	variable on; variable chan; variable pid; variable win; variable sock; variable started; variable drag
	if {$chan ne ""} {
		catch {puts $chan {{"command":["quit"]}}; flush $chan}
		catch {::close $chan}
		set chan ""
	}
	if {$pid ne ""} {
		set p $pid
		# a moment to quit on its own, then it is ended
		if {$now} { catch {exec kill $p 2>/dev/null} } else { after 500 [list catch [list exec kill $p 2>/dev/null]] }
		set pid ""
	}
	if {$win ne "" && [winfo exists $win]} { destroy $win }
	set win ""
	if {$sock ne ""} { after 600 [list catch [list file delete $sock]] }
	set on 0; set started 0; set drag ""; set ::video::frozen ""
}

# ---- the transport's actions ----------------------------------------------------------------------

# Play or pause; at the end, play starts again from the beginning.
proc video::toggle {args} {
	variable paused; variable eof; variable pos
	if {$paused && $eof} { video::send seek 0 absolute; set pos 0.0; set eof 0 }
	set paused [expr {!$paused}]
	video::send set_property pause [expr {$paused ? "true" : "false"}]
	viewer::draw
}

# Seek to F (0 to 1) of the length.
proc video::seek {f {how absolute+exact}} {
	variable dur; variable pos; variable eof
	if {$dur <= 0} return
	set pos [expr {max(0.0, min(1.0, $f)) * $dur}]
	set eof 0
	video::send seek $pos $how
	viewer::draw
}

proc video::set_volume {v} {
	variable vol; variable muted
	set vol [expr {max(0, min(100, round($v)))}]
	video::send set_property volume $vol
	if {$muted && $vol > 0} { set muted 0; video::send set_property mute false }
	viewer::draw
}

proc video::mute {args} {
	variable muted
	set muted [expr {!$muted}]
	video::send set_property mute [expr {$muted ? "true" : "false"}]
	video::save_conf
	viewer::draw
}

# The sliders: the pointer's x along the track, while held (the scrubber seeks to keyframes while dragged, then
# exactly where it is let go).
proc video::frac {x track} {
	lassign $track tx tw
	expr {$tw > 0 ? max(0.0, min(1.0, double($x - $tx) / $tw)) : 0.0}
}
proc video::scrub_press {x y args} { variable drag scrub; variable track; video::seek [video::frac $x $track] absolute+keyframes }
proc video::scrub_drag {x y args} { variable track; video::seek [video::frac $x $track] absolute+keyframes }
proc video::scrub_release {x y args} { variable drag ""; variable track; video::seek [video::frac $x $track] }
proc video::vol_press {x y args} { variable drag vol; variable vtrack; video::set_volume [expr {100 * [video::frac $x $vtrack]}] }
proc video::vol_drag {x y args} { variable vtrack; video::set_volume [expr {100 * [video::frac $x $vtrack]}] }
proc video::vol_release {x y args} { variable drag ""; variable vtrack; video::set_volume [expr {100 * [video::frac $x $vtrack]}]; video::save_conf }

# A key while a video is shown: Space plays or pauses, m mutes. 1 when taken.
proc video::key_press {sym} {
	variable on
	if {!$on} { return 0 }
	switch -- $sym {
		space { video::toggle; return 1 }
		m { video::mute; return 1 }
	}
	return 0
}

# Seconds as m:ss, or h:mm:ss from an hour.
proc video::hms {s} {
	set s [expr {max(0, int($s))}]
	set h [expr {$s / 3600}]; set m [expr {$s / 60 % 60}]; set sec [expr {$s % 60}]
	if {$h > 0} { return [format {%d:%02d:%02d} $h $m $sec] }
	format {%d:%02d} $m $sec
}

# ---- drawing --------------------------------------------------------------------------------------

proc video::icon {name size colour x y {fill 0}} {
	variable P
	set i [raster::icon $P($name) $size 1.9 [ui::col $colour] {} 0 0 $fill]
	$ui::cv create image [expr {round($x)}] [expr {round($y)}] -image $i -anchor nw -tags page
}

# A neutral slider (STYLE.md): the 4 px §pill track, the §muted fill to the knob, the 18 px §fg knob.
proc video::slider {x y w f} {
	array set c [array get ui::c]
	ui::box $x [expr {$y + 18}] $w 4 -fill $c(pill) -radius 2
	set kx [expr {$x + $f * $w}]
	if {$kx - $x >= 1} { ui::box $x [expr {$y + 18}] [expr {$kx - $x}] 4 -fill $c(muted) -radius 2 }
	ui::box [expr {$kx - 9}] [expr {$y + 11}] 18 18 -fill $c(fg) -radius 9
}

# The transport (Viewer-Final-5-Video): the 32 px play/pause button on §pill, the position (600, right-aligned in
# 34), the 440 px scrubber, the length (§muted, 34), a divider, the volume button and its 84 px slider, a divider
# and full screen; items 2 apart, padded 6. 808 wide on the board.
proc video::toolbar {sw} {
	variable pos; variable dur; variable paused; variable vol; variable muted; variable eof; variable track; variable vtrack
	variable shown
	array set c [array get ui::c]
	set W [expr {6 + 32 + 2 + 12 + 2 + 34 + 2 + 14 + 2 + 440 + 2 + 14 + 2 + 34 + 2 + 13 + 2 + 34 + 2 + 4 + 2 + 84 + 2 + 8 + 2 + 13 + 2 + 34 + 6}]
	set x0 [expr {($sw - $W) / 2}]
	set y [expr {$zoom::WH - 20 - 44}]
	ui::box $x0 $y $W 44 -fill $c(bar) -radius 12 -ring [list $c(border) 1]
	set x [expr {$x0 + 6}]
	# play or pause
	bar::tip play [expr {$paused || $eof ? "Play" : "Pause"}] $x [expr {$y + 6}] 32 32 [list $y [expr {$y + 44}] above]
	ui::box $x [expr {$y + 6}] 32 32 -fill [expr {[bar::lit play] ? $c(field) : $c(pill)}] -radius 8
	video::icon [expr {$paused || $eof ? "play" : "pause"}] 14 $c(fg) [expr {$x + 9}] [expr {$y + 15}] 1
	ui::hit $x [expr {$y + 6}] 32 32 video::toggle
	incr x [expr {32 + 2 + 12 + 2}]
	bar::text [expr {$x + 34}] $y 44 [video::hms $pos] i13s $c(fg) e
	incr x [expr {34 + 2 + 14 + 2}]
	set f [expr {$dur > 0 ? max(0.0, min(1.0, $pos / $dur)) : 0.0}]
	set track [list $x 440]
	video::slider $x $y 440 $f
	ui::hit [expr {$x - 9}] [expr {$y + 8}] [expr {440 + 18}] 28 video::scrub_press video::scrub_drag video::scrub_release
	incr x [expr {440 + 2 + 14 + 2}]
	bar::text $x $y 44 [video::hms $dur] i13 $c(muted)
	incr x [expr {34 + 2}]
	ui::box [expr {$x + 6}] [expr {$y + 13}] 1 18 -fill $c(border)
	incr x [expr {13 + 2}]
	bar::tip mute [expr {$muted ? "Unmute" : "Mute"}] $x [expr {$y + 5}] 34 34 [list $y [expr {$y + 44}] above]
	if {[bar::lit mute]} { ui::box $x [expr {$y + 5}] 34 34 -fill $c(field) -radius 8 }
	video::icon [expr {$muted ? "mute" : "volume"}] 16 [expr {[bar::lit mute] ? $c(fg) : $c(muted)}] [expr {$x + 9}] [expr {$y + 14}]
	ui::hit $x [expr {$y + 5}] 34 34 video::mute
	incr x [expr {34 + 2 + 4 + 2}]
	set vtrack [list $x 84]
	video::slider $x $y 84 [expr {$muted ? 0.0 : $vol / 100.0}]
	ui::hit [expr {$x - 9}] [expr {$y + 8}] [expr {84 + 18}] 28 video::vol_press video::vol_drag video::vol_release
	incr x [expr {84 + 2 + 8 + 2}]
	ui::box [expr {$x + 6}] [expr {$y + 13}] 1 18 -fill $c(border)
	incr x [expr {13 + 2}]
	bar::button $x [expr {$y + 5}] expand 0 viewer::fullscreen [list $y [expr {$y + 44}] above]
	set shown [video::key]
}
