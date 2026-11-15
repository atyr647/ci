# wall.tcl - ribbon-wall's policy, run by ribbon-wall's own Tcl interpreter.
#
# The C side (main.c) draws; this decides what and when:
#   - what ~/.config/ribbon/wallpaper.conf says (docs/DESKTOP.md), at start,
#     on "reload" and on SIGHUP;
#   - previews for the Appearance app: a candidate shown at once, without
#     touching wallpaper.conf, until "preview end" (Revert) or "reload"
#     (Apply: the app has written wallpaper.conf);
#   - the slideshow timer;
#   - when a video pauses (PAUSE_FULLSCREEN, PAUSE_COVERED, PAUSE_GAME,
#     PAUSE_BATTERY);
#   - the procedural designs ("looks"), drawn by look.tcl for each output's
#     exact size and scale, cached;
#   - the control commands, one line each on the FIFO
#     ($XDG_RUNTIME_DIR/ribbon-wall), stdin or the command line.
#
# Commands (key=value options first; a path is the rest of the line):
#   reload                               re-read wallpaper.conf (ends a preview)
#   preview colour #RRGGBB               show a candidate now, nothing saved:
#   preview picture [fit=F] [colour=#C] FILE
#   preview slideshow [fit=F] [colour=#C] [interval=S] [crossfade=S] [shuffle=yes|no] [subdirs=yes|no] DIR
#   preview video [fit=F] [colour=#C] FILE
#   preview design NAME                     (all take fade=MS, default 400, and
#                                            owner=PID: ended when PID exits)
#   preview end                          back to the saved wallpaper (Revert)
#   pause | resume                       an explicit pause
#   hint game on|off                     a game the window list can't show
#   status [FILE]                        state as a Tcl dict (stdout or FILE)
#   quit
# (colour, image, video and look NAME show something until the next reload,
# as the prototype did.)
#
# Copyright 2026 Ribbon OS contributors, MIT licence.

namespace eval wall {
	variable conf {}           ;# wallpaper.conf
	variable saved {}          ;# the wallpaper it describes (a "spec" dict)
	variable shown {}          ;# the spec on screen
	variable preview 0         ;# showing a candidate?
	variable owner 0           ;# the previewing app's pid
	variable out               ;# output name -> {pw ph scale w h lx ly}
	array set out {}
	variable win               ;# window id -> {app states outputs}
	array set win {}
	variable focus ""          ;# the window in use (the shell's own don't count)
	variable explicit 0
	variable hint_game 0
	variable battery 0
	variable paused            ;# output -> reasons
	array set paused {}
	variable slides {}         ;# slideshow: {folder order pos last}
	variable slide_pending 0
	variable games             ;# app id -> 0|1 (desktop file lookups)
	array set games {}
	variable renders           ;# output -> the design file being drawn for it
	array set renders {}
	variable fade 400          ;# ms: changes between candidates and on reload
	variable design_sig ""     ;# the design file, palette and renderer shown
	variable preparing         ;# video -> the prepared copy being made
	array set preparing {}
}

# ---- files ---------------------------------------------------------------------

proc wall::dir {var fallback} {
	if {[info exists ::env($var)] && $::env($var) ne ""} { return $::env($var) }
	return [file join $::env(HOME) $fallback]
}
proc wall::confdir {} { file join [dir XDG_CONFIG_HOME .config] ribbon }
proc wall::conffile {} { file join [confdir] wallpaper.conf }
proc wall::cachedir {} { file join [dir XDG_CACHE_HOME .cache] ribbon wallpaper }
proc wall::statefile {} { file join [dir XDG_STATE_HOME .local/state] ribbon slideshow }
proc wall::runtime {} { expr {[info exists ::env(XDG_RUNTIME_DIR)] ? $::env(XDG_RUNTIME_DIR) : "/tmp"} }

# KEY=value lines (quotes stripped) -> dict
proc wall::read_kv {f} {
	set d {}
	if {[catch {open $f} fh]} { return $d }
	foreach line [split [read $fh] \n] {
		if {[regexp {^\s*([A-Z_0-9]+)=(.*)$} $line -> k v]} { dict set d $k [string trim [string trim $v] \"'] }
	}
	close $fh
	return $d
}

# Set one key of wallpaper.conf, keeping every other line (atomic rename).
proc wall::conf_set {key value} {
	set f [conffile]
	set lines {}
	if {![catch {open $f} fh]} {
		foreach line [split [string trimright [read $fh] \n] \n] {
			if {![string match "$key=*" $line]} { lappend lines $line }
		}
		close $fh
	}
	lappend lines "$key=$value"
	file mkdir [file dirname $f]
	set fh [open $f.tmp w]; puts $fh [join $lines \n]; close $fh
	file rename -force $f.tmp $f
}

proc wall::yes {v {def 0}} {
	if {$v eq ""} { return $def }
	expr {[string tolower $v] in {yes 1 true on}}
}
proc wall::get {key {def ""}} {
	variable conf
	expr {[dict exists $conf $key] && [dict get $conf $key] ne "" ? [dict get $conf $key] : $def}
}
proc wall::colour_ok {c} { regexp {^#[0-9A-Fa-f]{6}$} $c }

proc wall::palette_file {} {
	if {[info exists ::env(RIBBON_WALL_PALETTE)]} { return $::env(RIBBON_WALL_PALETTE) }
	set p [file join [confdir] palette.conf]
	if {[file readable $p]} { return $p }
	return /usr/share/ribbon/themes/palettes/ribbon.conf
}

proc wall::looks_dir {} {
	if {[info exists ::env(RIBBON_WALL_LOOKS)]} { return $::env(RIBBON_WALL_LOOKS) }
	set d [file join $::rw::lib looks]
	if {[file isdirectory $d]} { return $d }
	return /usr/share/ribbon/looks
}

# ---- what wallpaper.conf asks for ---------------------------------------------------

# A "spec": kind colour | picture | slideshow | video | design, and its options.
proc wall::conf_spec {} {
	variable conf
	set mode [get MODE]
	set fit [get FIT fill]
	if {$fit ni {fill fit centre tile}} { set fit fill }
	set bg [get COLOUR #000000]
	if {![colour_ok $bg]} { set bg #000000 }
	set img [get IMAGE]
	switch -- $mode {
		colour { if {[colour_ok [get COLOUR]]} { return [dict create kind colour colour [get COLOUR]] } }
		picture { if {$img ne "" && [file readable $img]} { return [dict create kind picture file $img fit $fit colour $bg] } }
		slideshow {
			set d [get SLIDESHOW_DIR]
			if {$d ne "" && [file isdirectory $d]} {
				return [dict create kind slideshow dir $d fit $fit colour $bg interval [get INTERVAL 600] \
					crossfade [get CROSSFADE 1.5] shuffle [yes [get SHUFFLE yes]] subdirs [yes [get SUBDIRS no]] first $img]
			}
		}
		video {
			set v [get VIDEO]
			if {$v ne "" && [file readable $v]} { return [dict create kind video file $v fit $fit colour $bg first $img] }
		}
		"" { if {$img ne "" && [file readable $img]} { return [dict create kind picture file $img fit $fit colour $bg] } }
	}
	return [dict create kind design name [get DESIGN ribbon]]
}

# A spec without what changes by itself (the slideshow's current picture).
proc wall::spec_key {s} { dict remove $s first owner fade }

proc wall::reload {} {
	variable conf [read_kv [conffile]]
	variable saved [conf_spec]
	variable preview
	variable shown
	set was $preview
	set preview 0
	set sig [expr {[dict get $saved kind] eq "design" ? [design_sig [dict get $saved name]] : ""}]
	if {$was || [spec_key $saved] ne [spec_key $shown] || $sig ne $wall::design_sig} {
		show $saved [expr {$shown eq "" ? 0 : $wall::fade}]
	}
	update_pause
	puts "reload [dict get $saved kind]"
}

# ---- showing a spec ---------------------------------------------------------------

proc wall::show {spec fade} {
	variable shown $spec
	variable slide_pending 0
	after cancel wall::slide_next
	switch -- [dict get $spec kind] {
		colour { rw::colour [dict get $spec colour] $fade }
		picture {
			if {[catch {rw::picture [dict get $spec file] [dict get $spec fit] $fade [dict get $spec colour]} e]} {
				puts "picture-failed $e"
				return [show [dict create kind design name ribbon] $fade]
			}
		}
		video {
			set play [prepared [dict get $spec file] [dict get $spec fit]]
			if {$play eq ""} { set play [dict get $spec file] }
			if {[catch {rw::video $play [dict get $spec fit] $fade [dict get $spec colour]} info]} {
				puts "video-refused $info"
				set f [expr {[dict exists $spec first] ? [dict get $spec first] : ""}]
				if {$f ne "" && [file readable $f]} {
					return [show [dict create kind picture file $f fit [dict get $spec fit] colour [dict get $spec colour]] $fade]
				}
				return [show [dict create kind design name ribbon] $fade]
			}
			puts "video $play $info"
			variable vinfo $info
			variable playing $play
			if {$play eq [dict get $spec file]} { prepare $spec $info }
		}
		design { design_show [dict get $spec name] $fade }
		slideshow { slide_start $spec $fade }
	}
	update_pause
}

# ---- previews (the Appearance app) --------------------------------------------------

proc wall::preview {kind opts rest} {
	variable preview
	variable owner
	set fade [dict_or $opts fade $wall::fade]
	set bg [dict_or $opts colour #000000]
	if {![colour_ok $bg]} { set bg #000000 }
	set fit [dict_or $opts fit fill]
	if {$fit ni {fill fit centre tile}} { set fit fill }
	switch -- $kind {
		end {
			if {!$preview} return
			set preview 0
			set owner 0
			variable shown
			if {[spec_key $wall::saved] ne [spec_key $shown]} { show $wall::saved $fade }
			puts "preview end"
			return
		}
		colour { if {![colour_ok $rest]} { puts "preview-refused not a colour"; return }; set s [dict create kind colour colour $rest] }
		picture { set s [dict create kind picture file $rest fit $fit colour $bg] }
		video { set s [dict create kind video file $rest fit $fit colour $bg] }
		design { set s [dict create kind design name [expr {$rest eq "" ? "ribbon" : $rest}]] }
		slideshow {
			set s [dict create kind slideshow dir $rest fit $fit colour $bg interval [dict_or $opts interval 600] \
				crossfade [dict_or $opts crossfade 1.5] shuffle [yes [dict_or $opts shuffle yes] 1] subdirs [yes [dict_or $opts subdirs no]] first ""]
		}
		default { puts "preview-refused unknown kind $kind"; return }
	}
	if {$kind in {picture video slideshow} && ![file readable $rest]} { puts "preview-refused cannot read $rest"; return }
	set preview 1
	set owner [dict_or $opts owner 0]
	if {$owner} { after 2000 wall::owner_check }
	show $s $fade
	puts "preview $kind"
}

# The app that asked for the preview quit without Apply or Revert: revert.
proc wall::owner_check {} {
	variable owner
	variable preview
	if {!$preview || !$owner} return
	if {![rw::alive $owner]} { preview end {} ""; return }
	after 2000 wall::owner_check
}

proc wall::dict_or {d k def} { expr {[dict exists $d $k] ? [dict get $d $k] : $def} }

# ---- slideshow ----------------------------------------------------------------------

proc wall::pictures {dir subdirs} {
	set out [glob -nocomplain -types f -directory $dir -- *.{png,jpg,jpeg,webp,PNG,JPG,JPEG,WEBP}]
	if {$subdirs} {
		foreach d [glob -nocomplain -types d -directory $dir -- *] {
			if {[file type $d] ne "link"} { lappend out {*}[pictures $d 1] }
		}
	}
	lsort -dictionary $out
}

proc wall::shuffle {l} {
	for {set i [expr {[llength $l] - 1}]} {$i > 0} {incr i -1} {
		set j [expr {int(rand() * ($i + 1))}]
		set t [lindex $l $i]; lset l $i [lindex $l $j]; lset l $j $t
	}
	return $l
}

proc wall::interval {spec} {
	set i [dict get $spec interval]
	if {![string is double -strict $i]} { set i 600 }
	set lo [expr {[info exists ::env(RIBBON_WALL_MIN_INTERVAL)] ? $::env(RIBBON_WALL_MIN_INTERVAL) : 60}]
	expr {min(604800, max($lo, $i))}
}

# The order and position are kept in $XDG_STATE_HOME/ribbon/slideshow (not
# for previews), with the time of the last change, so a restart neither
# repeats a picture nor resets a long interval.
proc wall::slide_start {spec fade} {
	variable slides
	variable preview
	set dir [dict get $spec dir]
	set have [pictures $dir [dict get $spec subdirs]]
	if {![llength $have]} { puts "slideshow-empty $dir"; return [show [dict create kind design name ribbon] $fade] }
	set st {folder "" order {} pos 0 last 0}
	if {!$preview && ![catch {open [statefile]} fh]} {
		set d [read $fh]; close $fh
		if {![catch {dict get $d order}] && [dict exists $d pos] && [dict exists $d last]} { set st $d }
	}
	if {[dict get $st folder] ne $dir || [lsort [dict get $st order]] ne [lsort $have]} {
		set st [dict create folder $dir order [expr {[dict get $spec shuffle] ? [shuffle $have] : $have}] pos 0 last 0]
	}
	set slides $st
	# the picture shown now: wallpaper.conf's IMAGE if it is in the folder
	set first [dict get $spec first]
	set i [lsearch -exact [dict get $st order] $first]
	if {$i < 0} {
		set i [expr {[dict get $st pos] % [llength [dict get $st order]]}]
		dict set slides pos [expr {$i + 1}]
		dict set slides last [clock seconds]
	} else { dict set slides pos [expr {$i + 1}] }
	slide_put [lindex [dict get $st order] $i] $fade
	set wait [expr {[dict get $slides last] + [interval $spec] - [clock seconds]}]
	after [expr {max(1, $wait) * 1000}] wall::slide_next
}

proc wall::slide_put {file fade} {
	variable shown
	variable preview
	if {[catch {rw::picture $file [dict get $shown fit] $fade [dict get $shown colour]} e]} { puts "picture-failed $e"; return 0 }
	dict set shown first $file
	puts "slide $file"
	if {!$preview} {
		conf_set IMAGE $file
		variable slides
		file mkdir [file dirname [statefile]]
		set fh [open [statefile].tmp w]; puts $fh $slides; close $fh
		file rename -force [statefile].tmp [statefile]
	}
	return 1
}

proc wall::slide_next {} {
	variable shown
	variable slides
	variable slide_pending
	if {[dict get $shown kind] ne "slideshow"} return
	# nobody can see it (a fullscreen window): change it later
	if {[all_paused]} { set slide_pending 1; return }
	set have [pictures [dict get $shown dir] [dict get $shown subdirs]]
	if {![llength $have]} { after [expr {[interval $shown] * 1000}] wall::slide_next; return }
	set order [dict get $slides order]; set pos [dict get $slides pos]
	if {[lsort $order] ne [lsort $have] || $pos >= [llength $order]} {
		set order [expr {[dict get $shown shuffle] ? [shuffle $have] : $have}]
		# never the same picture twice in a row across rounds
		if {[llength $order] > 1 && [lindex $order 0] eq [dict get $shown first]} { set order [concat [lrange $order 1 end] [lrange $order 0 0]] }
		set pos 0
	}
	set slides [dict create folder [dict get $shown dir] order $order pos [expr {$pos + 1}] last [clock seconds]]
	slide_put [lindex $order $pos] [expr {int(1000 * [dict get $shown crossfade])}]
	after [expr {[interval $shown] * 1000}] wall::slide_next
}

# ---- videos: a wallpaper-friendly copy -------------------------------------------------
#
# A clip that has to be decoded in software and is bigger than the screens
# (pixels) or faster than 30 frames a second is re-encoded once, in the
# background, into ~/.cache/ribbon/wallpaper/video-KEY.mp4: H.264 (decoded
# in hardware almost everywhere, cheaply in software), scaled down to cover
# the largest output, at most 30 fps, a keyframe every 2 s with closed GOPs
# (the loop starts on a keyframe), no audio. It is played from then on,
# from the next login too; the original stays where it was and VIDEO keeps
# naming it. RIBBON_WALL_PREPARE=0 turns this off. Needs the ffmpeg program.

proc wall::prepare_target {file fit} {
	set W 0; set H 0
	foreach o [array names wall::out] {
		lassign $wall::out($o) pw ph
		set W [expr {max($W, $pw)}]; set H [expr {max($H, $ph)}]
	}
	if {[file exists $file]} { set id "$file [file mtime $file] [file size $file] ${W}x$H $fit" } else { set id $file }
	list $W $H [file join [cachedir] [format video-%08x.mp4 [zlib crc32 $id]]]
}

proc wall::prepared {file fit} {
	if {[info exists ::env(RIBBON_WALL_PREPARE)] && !$::env(RIBBON_WALL_PREPARE)} { return "" }
	lassign [prepare_target $file $fit] W H f
	expr {[file readable $f] ? $f : ""}
}

proc wall::prepare {spec info} {
	variable preparing
	set file [dict get $spec file]; set fit [dict get $spec fit]
	if {[info exists ::env(RIBBON_WALL_PREPARE)] && !$::env(RIBBON_WALL_PREPARE)} return
	if {[dict get $info hw] ne "none" || [auto_execok ffmpeg] eq ""} return
	lassign [prepare_target $file $fit] W H out
	if {!$W || [info exists preparing($out)]} return
	set w [dict get $info width]; set h [dict get $info height]; set fps [dict get $info fps]
	# the scale that still covers (fill) or shows all of (fit) the largest output
	set k [expr {$fit eq "fit" ? min(double($W) / $w, double($H) / $h) : max(double($W) / $w, double($H) / $h)}]
	set k [expr {min(1.0, $k)}]
	if {$k > 0.75 && $fps <= 31} return ;# no worthwhile saving
	set tw [expr {max(2, 2 * round($w * $k / 2))}]; set th [expr {max(2, 2 * round($h * $k / 2))}]
	set rate [expr {$fps > 31 ? $fps / round($fps / 30.0) : $fps}]
	file mkdir [cachedir]
	set cmd [list nice -n 15 ffmpeg -nostdin -v error -y -i $file -an -sn -dn -map 0:v:0 \
		-vf "scale=$tw:$th:flags=lanczos,fps=$rate" -c:v libx264 -preset veryfast -crf 20 \
		-maxrate 12M -bufsize 24M -g [expr {round(2 * $rate)}] -flags +cgop -pix_fmt yuv420p \
		-movflags +faststart $out.tmp.mp4]
	if {[catch {open |[concat $cmd [list 2>@1]] r} ch]} return
	set preparing($out) $ch
	fconfigure $ch -blocking 0
	fileevent $ch readable [list wall::prepare_done $ch $out $file $fit [clock milliseconds]]
	puts "video-preparing $out ${tw}x$th@[format %.3g $rate]"
}

proc wall::prepare_done {ch out file fit t0} {
	variable preparing
	set msg [read $ch]
	if {![eof $ch]} return
	fconfigure $ch -blocking 1
	set failed [catch {close $ch} e]
	unset -nocomplain preparing($out)
	if {$failed || ![file exists $out.tmp.mp4]} { file delete $out.tmp.mp4; puts "video-prepare-failed [string trim "$msg $e"]"; return }
	file rename -force $out.tmp.mp4 $out
	puts "video-prepared $out [expr {[clock milliseconds] - $t0}] ms"
	# keep the copies of the last few videos
	set files [lsort -integer -decreasing -index 0 [lmap f [glob -nocomplain -directory [cachedir] video-*.mp4] { list [file mtime $f] $f }]]
	foreach e [lrange $files 3 end] { file delete [lindex $e 1] }
	variable shown
	if {[dict get $shown kind] eq "video" && [dict get $shown file] eq $file && [dict get $shown fit] eq $fit} { show $shown 800 }
}

# ---- procedural designs ------------------------------------------------------------

# What a design's pictures depend on: the design, the palette, the renderer.
proc wall::design_sig {name} {
	set key ""
	foreach f [list [file join [looks_dir] $name.look] [palette_file] [file join $::rw::lib look.tcl]] {
		if {![catch {open $f rb} fh]} { append key [read $fh]; close $fh }
	}
	format %08x [zlib crc32 $key]
}

proc wall::design_show {name fade} {
	variable design $name
	variable design_sig [design_sig $name]
	set pal [read_kv [palette_file]]
	set bg [expr {[dict exists $pal DESK_BOTTOM] && [colour_ok [dict get $pal DESK_BOTTOM]] ? [dict get $pal DESK_BOTTOM] : "#121110"}]
	rw::perout $bg $fade
	foreach o [array names wall::out] { design_output $o $fade }
}

# The cache key: the design, the palette and the renderer, so editing any of
# them draws anew; old files are pruned to the newest 16.
proc wall::design_file {name o} {
	variable out
	lassign $out($o) pw ph scale
	file join [cachedir] [format "look-%s-%s-%dx%d@%s.png" $name $wall::design_sig $pw $ph $scale]
}

proc wall::design_output {o fade} {
	variable shown
	variable design
	variable out
	variable renders
	if {[dict get $shown kind] ne "design" || ![info exists out($o)]} return
	set f [design_file $design $o]
	if {[file readable $f]} {
		if {[catch {rw::still $o $f $fade} e]} { puts "design-failed $o $e" } else { puts "design-shown $o [file tail $f]" }
		return
	}
	if {[info exists renders($o)] && $renders($o) eq $f} return ;# already drawing it
	set renders($o) $f
	lassign $out($o) pw ph scale
	file mkdir [cachedir]
	set cmd [list [info nameofexecutable] --tcl [file join $::rw::lib look.tcl] \
		[file join [looks_dir] $design.look] [palette_file] $pw $ph $scale $f]
	if {[info exists ::env(RIBBON_WALL_RENDER)]} { set cmd [list {*}$::env(RIBBON_WALL_RENDER) [file join [looks_dir] $design.look] [palette_file] $pw $ph $scale $f] }
	set t0 [clock milliseconds]
	if {[catch {open |[concat $cmd [list 2>@1]] r} ch]} { puts "design-failed $o $ch"; return }
	fconfigure $ch -blocking 0
	fileevent $ch readable [list wall::design_done $ch $o $f $t0]
}

proc wall::design_done {ch o f t0} {
	variable renders
	set msg [read $ch]
	if {![eof $ch]} return
	fconfigure $ch -blocking 1
	set failed [catch {close $ch} e]
	if {[info exists renders($o)] && $renders($o) eq $f} { unset renders($o) }
	if {$failed || ![file readable $f]} { puts "design-failed $o [string trim "$msg $e"]"; return }
	puts "design-rendered $o [file tail $f] [expr {[clock milliseconds] - $t0}] ms"
	prune
	# still wanted? (the output may have changed size, or the wallpaper kind)
	if {[info exists wall::out($o)] && [design_file $wall::design $o] eq $f} { design_output $o 300 }
}

proc wall::prune {} {
	set files [glob -nocomplain -directory [cachedir] look-*.png]
	if {[llength $files] <= 16} return
	set byage [lsort -integer -decreasing -index 0 [lmap f $files { list [file mtime $f] $f }]]
	foreach e [lrange $byage 16 end] { file delete [lindex $e 1] }
}

# ---- outputs and windows (from main.c) ------------------------------------------------

proc wall::output {name pw ph scale w h lx ly} {
	variable out
	set out($name) [list $pw $ph $scale $w $h $lx $ly]
	variable shown
	# a mode or scale change arrives as a few events: draw for where it settles
	after cancel [list wall::design_output $name 0]
	if {$shown ne "" && [dict get $shown kind] eq "design"} { after 150 [list wall::design_output $name 0] }
	# a video started before its outputs were known: the prepared copy's size is known now
	if {$shown ne "" && [dict get $shown kind] eq "video" && [info exists wall::vinfo] && $wall::playing eq [dict get $shown file]} {
		after cancel [list wall::prepare $shown $wall::vinfo]
		after 300 [list wall::prepare $shown $wall::vinfo]
	}
	update_pause
}

proc wall::output_gone {name} {
	variable out
	unset -nocomplain out($name)
	variable paused
	unset -nocomplain paused($name)
}

proc wall::own {app} { string match -nocase *ribbon*shell* $app }

proc wall::toplevel {id app states outs} {
	variable win
	variable focus
	set win($id) [list $app $states $outs]
	if {[info exists ::env(RIBBON_WALL_DEBUG)]} { puts "window $id {$app} {$states} {$outs}" }
	if {"act" in $states && ![own $app]} { set focus $id }
	if {$focus ne "" && (![info exists win($focus)] || "min" in [lindex $win($focus) 1])} { set focus "" }
	update_pause
}

proc wall::toplevel_gone {id} {
	variable win
	variable focus
	unset -nocomplain win($id)
	if {$focus eq $id} { set focus "" }
	update_pause
}

# Is APP a game? Steam's and gamescope's windows, or an app whose desktop
# file is in the Game category.
proc wall::is_game {app} {
	variable games
	if {$app eq ""} { return 0 }
	if {[info exists games($app)]} { return $games($app) }
	set g [expr {[string match -nocase steam_app_* $app] || [string match -nocase gamescope* $app]}]
	if {!$g} {
		set dirs [list [dir XDG_DATA_HOME .local/share]]
		lappend dirs {*}[split [expr {[info exists ::env(XDG_DATA_DIRS)] ? $::env(XDG_DATA_DIRS) : "/usr/local/share:/usr/share"}] :]
		lappend dirs /var/lib/flatpak/exports/share [dir XDG_DATA_HOME .local/share/flatpak/exports/share]
		foreach d $dirs {
			foreach f [glob -nocomplain -directory [file join $d applications] -- *.desktop] {
				set base [file rootname [file tail $f]]
				if {![string equal -nocase $base $app] && ![string match -nocase *.$app $base]} {
					# StartupWMClass is how X11 games name themselves
					if {[catch {open $f} fh]} continue
					set text [read $fh]; close $fh
					if {![regexp -line -nocase "^StartupWMClass=\\Q$app\\E\$" $text]} continue
				} else {
					if {[catch {open $f} fh]} continue
					set text [read $fh]; close $fh
				}
				if {[regexp -line {^Categories=.*\yGame\y} $text]} { set g 1; break }
			}
			if {$g} break
		}
	}
	set games($app) $g
}

# ---- pausing ------------------------------------------------------------------------

proc wall::all_paused {} {
	variable paused
	if {![array size wall::out]} { return 0 }
	foreach o [array names wall::out] { if {![info exists paused($o)] || $paused($o) eq ""} { return 0 } }
	return 1
}

# Why each output's video should hold still; the PAUSE_* keys say which
# reasons count. A covered output needs none of this to save power: the
# compositor stops sending it frame callbacks, so nothing is decoded or drawn.
proc wall::update_pause {} {
	variable out
	variable win
	variable focus
	variable paused
	variable shown
	set pf [yes [get PAUSE_FULLSCREEN] 1]
	set pc [yes [get PAUSE_COVERED] 0]
	set pg [yes [get PAUSE_GAME] 0]
	set pb [yes [get PAUSE_BATTERY] 0]
	set full 0; set game $wall::hint_game
	foreach id [array names win] {
		lassign $win($id) app states
		if {"full" in $states && "min" ni $states} { set full 1 }
		if {$pg && [is_game $app]} { set game 1 }
	}
	set cov {}
	if {$focus ne "" && [info exists win($focus)]} {
		lassign $win($focus) app states outs
		if {("max" in $states || "full" in $states) && "min" ni $states} { set cov $outs }
	}
	set battery_check [expr {$pb && $shown ne "" && [dict get $shown kind] eq "video"}]
	after cancel wall::battery_tick
	if {$battery_check} { variable battery [on_battery]; after 30000 wall::battery_tick }
	set was_all [all_paused]
	foreach o [array names out] {
		set r {}
		if {$wall::explicit} { lappend r explicit }
		if {$pf && $full} { lappend r fullscreen }
		if {$pc && $o in $cov} { lappend r covered }
		if {$pg && $game} { lappend r game }
		if {$battery_check && $wall::battery} { lappend r battery }
		set before [expr {[info exists paused($o)] ? $paused($o) : "-"}]
		set paused($o) $r
		if {$before ne $r} {
			rw::pause $o [expr {[llength $r] > 0}]
			puts "pause $o [expr {[llength $r] > 0}] $r"
		}
	}
	variable slide_pending
	if {$slide_pending && ![all_paused]} { set slide_pending 0; after 500 wall::slide_next }
}

# On battery: a battery present and no mains supply online.
proc wall::on_battery {} {
	set root [expr {[info exists ::env(RIBBON_WALL_POWER)] ? $::env(RIBBON_WALL_POWER) : "/sys/class/power_supply"}]
	set bat 0; set ac 0
	foreach d [glob -nocomplain -directory $root *] {
		if {[catch {open $d/type} fh]} continue
		set t [string trim [read $fh]]; close $fh
		if {$t eq "Battery"} { set bat 1 }
		if {$t eq "Mains" && ![catch {open $d/online} fh]} {
			if {[string trim [read $fh]] eq "1"} { set ac 1 }
			close $fh
		}
	}
	expr {$bat && !$ac}
}

proc wall::battery_tick {} { update_pause }

# ---- commands --------------------------------------------------------------------------

proc wall::command {line} {
	set line [string trim $line]
	if {$line eq "" || [string index $line 0] eq "#"} return
	regexp {^(\S+)\s*(.*)$} $line -> word rest
	set sub ""
	set opts {}
	while {[regexp {^([a-z]+)=(\S*)\s*(.*)$} $rest -> k v r]} { dict set opts $k $v; set rest $r }
	if {$word eq "preview" || $word eq "hint"} { regexp {^(\S+)\s*(.*)$} $rest -> sub rest }
	while {[regexp {^([a-z]+)=(\S*)\s*(.*)$} $rest -> k v r]} { dict set opts $k $v; set rest $r }
	switch -- $word {
		reload { reload }
		preview { preview $sub $opts $rest }
		colour - color { if {[colour_ok $rest]} { show [dict create kind colour colour $rest] [dict_or $opts fade 0] } }
		image { show [dict create kind picture file $rest fit [dict_or $opts fit fill] colour [dict_or $opts colour #000000]] [dict_or $opts fade 0] }
		video { show [dict create kind video file $rest fit [dict_or $opts fit fill] colour [dict_or $opts colour #000000]] [dict_or $opts fade 0] }
		look { show [dict create kind design name $rest] 0 }
		pause { variable explicit 1; update_pause }
		resume { variable explicit 0; update_pause }
		hint { if {$sub eq "game"} { variable hint_game [expr {$rest eq "on"}]; update_pause } }
		status { status $rest }
		quit { rw::quit }
		default { puts "unknown-command $word" }
	}
}

proc wall::status {file} {
	variable shown
	variable paused
	set d [dict create shown $shown preview $wall::preview outputs [rw::outputs] \
		paused [array get paused] engine [rw::stats]]
	if {$file eq ""} { puts "status $d"; return }
	set fh [open $file.tmp w]; puts $fh $d; close $fh
	file rename -force $file.tmp $file
}

proc wall::read_chan {ch} {
	while {[gets $ch line] >= 0} { if {[catch {command $line} e]} { puts stderr "ribbon-wall: $line: $::errorInfo" } }
	if {[eof $ch]} { catch {close $ch} }
}

proc wall::start {} {
	expr {srand([clock clicks])}
	set fifo $::rw::fifo
	if {$fifo eq ""} { set fifo [file join [runtime] ribbon-wall] }
	# one ribbon-wall per session: another one already reads the FIFO
	if {[file exists $fifo] && [file type $fifo] eq "fifo" && ![catch {open $fifo {WRONLY NONBLOCK}} ch]} {
		close $ch
		puts stderr "ribbon-wall: already running (on $fifo)"
		rw::quit
		return
	}
	rw::mkfifo $fifo
	set ch [open $fifo {RDWR NONBLOCK}]
	fconfigure $ch -blocking 0 -buffering line
	fileevent $ch readable [list wall::read_chan $ch]
	fconfigure stdin -blocking 0
	fileevent stdin readable [list wall::read_chan stdin]
	if {[llength $::argv]} {
		variable conf [read_kv [conffile]]
		variable saved [conf_spec]
		foreach c $::argv { command $c }
	} else {
		reload
	}
}
