# preview.tcl - the stage: the real desktop (or the real login screen)
# showing a candidate background while the Appearance sheet picks one,
# without writing wallpaper.conf. Revert puts back what wallpaper.conf
# says; Apply (ribbon-theme) makes the candidate stick.
#
# One adapter for every way of showing it, so the app never cares which:
#   ribbon-wall  its FIFO ($XDG_RUNTIME_DIR/ribbon-wall) takes "preview"
#                lines: the candidate at once (crossfaded; slideshows and
#                videos play), wallpaper.conf untouched; "preview end" goes
#                back (Revert); Apply's "reload" makes it stick
#   swaybg       until ribbon-wall is installed: the candidate is laid out
#                at the screen's size by the shell's wall.tcl (the same
#                pixels the shell paints behind its bars) and swaybg shows it;
#                Revert runs "ribbon-theme wallpaper", which shows the
#                configured one again
#   window       a full-screen window of the app's own under the sheet
#                (tests and scenes: RIBBON_APPEARANCE_STAGE=window)
# The login screen is always the real greeter (greeter/main.tcl with
# greeter/preview.tcl) drawing from a private copy of /etc/ribbon.
#
# A spec says what to show:
#   pattern PALETTE            the Ribbon pattern in a palette (a dict)
#   picture FILE FIT COLOUR    a picture laid out as FIT on COLOUR
#   colour #RRGGBB
#   video FILE FRAME           a looping video (FRAME: its first frame, for
#                              backends that can't play it)
# and, for the login screen, "login SPEC OPTIONS" with OPTIONS a dict of
# FIT BLUR DIM CLOCK COLOUR (options.conf).

namespace eval stage {
	variable W 1440
	variable H 900
	variable spec ""       ;# what is shown now
	variable greeter ""    ;# the greeter preview's pipe
	variable gdir ""       ;# its private /etc and state
	variable pending ""
	variable job ""        ;# the warm job running: {pipe key}
	variable next ""       ;# the one to run after it
}

proc stage::init {w h} {
	variable W $w
	variable H $h
}

proc stage::backend {} {
	set b [store::env RIBBON_APPEARANCE_STAGE]
	if {$b ne ""} { return $b }
	set fifo [file join [store::env XDG_RUNTIME_DIR /tmp] ribbon-wall]
	if {[file exists $fifo] && [file type $fifo] eq "fifo"} { return ribbon-wall }
	return swaybg
}

proc stage::cachedir {} {
	set d [file join [raster::dir] stage]
	file mkdir $d
	return $d
}

# Show SPEC (coalesced: a drag shows only the latest colour).
proc stage::show {s} {
	variable spec
	variable pending
	if {$s eq $spec} return
	set spec $s
	if {$pending eq ""} { set pending [after 40 stage::show_now] }
}

proc stage::show_now {} {
	variable spec
	variable pending ""
	if {[lindex $spec 0] eq "login"} {
		hide_window
		login_show [lindex $spec 1] [lindex $spec 2]
		return
	}
	login_stop
	switch -- [backend] {
		ribbon-wall { wall_send [wall_line $spec] }
		window { window_show }
		default { swaybg_show }
	}
}

# Back to what wallpaper.conf says.
proc stage::revert {} {
	variable spec ""
	variable pending
	after cancel $pending; set pending ""
	login_stop
	switch -- [backend] {
		ribbon-wall { wall_send "preview end" }
		window { hide_window }
		default { catch {exec {*}[runner] wallpaper </dev/null >/dev/null 2>/dev/null &} }
	}
}

proc stage::runner {} {
	set c [store::cmd]
	expr {[file exists $c] && ![file executable $c] ? [list bash $c] : [list $c]}
}

# ---- what is shown, as a picture of the screen -----------------------------------

# The candidate at the screen's size, as a PNG file (cached).
proc stage::screen {s} {
	variable W
	variable H
	set kind [lindex $s 0]
	if {$kind eq "login"} { return [login_file [lindex $s 1] [lindex $s 2]] }
	switch -- $kind {
		picture {
			lassign $s - f fit colour
			if {$f ne "" && [file readable $f]} {
				if {![catch {wall::prepare $f $W $H $fit [expr {$colour ne "" ? $colour : "#000000"}]} out]} { return $out }
			}
			return [screen [list pattern [store::current_palette]]]
		}
		video {
			lassign $s - f frame
			if {$frame ne "" && [file readable $frame]} { return [screen [list picture $frame fill #000000]] }
			return [wall::solid #000000 $W $H]
		}
		colour { return [wall::solid [lindex $s 1] $W $H] }
		default {
			set p [lindex $s 1]
			set key [list $p $W $H]
			set out [raster::keyed_path [cachedir] pattern- $key]
			if {![raster::keyed $out $key]} {
				raster::write_keyed $out $key [raster::png $W $H [wall::rows $p 0 0 $W $H $W $H]]
			}
			return $out
		}
	}
}

# The login screen's background as the greeter draws it: the picture (or
# the pattern in the login palette, or the plain colour), blurred and
# dimmed.
proc stage::login_file {s o} {
	variable W
	variable H
	set colour [dict get $o COLOUR]
	switch -- [lindex $s 0] {
		picture - video {
			set f [expr {[lindex $s 0] eq "video" ? [lindex $s 2] : [lindex $s 1]}]
			if {$f ne "" && [file readable $f]} {
				set bgc [expr {$colour ne "" ? $colour : [dict get [lindex $s end] DESK_BOTTOM]}]
				set blur [dict get $o BLUR]
				set base [wall::prepare_path $f $W $H [dict get $o FIT] $bgc]
				set full [expr {$blur > 0 ? "[file rootname $base]-blur$blur.png" : $base}]
				# with rbnalpha's C blur it is made here and now (~40 ms)
				if {![file exists $full] && [file exists $base] && [wall::fast_blur]} { catch { wall::blurred $base $blur } }
				if {![file exists $full]} { warm $f [dict get $o FIT] $bgc $blur }
				if {[file exists $full]} {
					set base $full
				} elseif {[file exists $base]} {
					# the cheap blur (a few hundred ms until the real one)
					set q [file rootname $base]-quick$blur.png
					if {![file exists $q]} {
						set p [image create photo -file $base]
						set qp [wall::blurred_quick $p $blur]
						$qp write $q -format png
						image delete $p $qp
					}
					set base $q
				} else {
					# not even laid out yet: the plain colour for a moment
					set base [wall::solid $bgc $W $H]
				}
			} else { set base [screen [list pattern [lindex $s end]]] }
		}
		colour { set base [wall::solid [lindex $s 1] $W $H] }
		default { set base [screen [list pattern [lindex $s 1]]] }
	}
	set dim [dict get $o DIM]
	if {$dim <= 0} { return $base }
	# the dim copy is keyed by the base's key (the base may be taken by another key)
	set dkey [list dim [raster::key_of $base] $dim]
	set out [file rootname $base]-dim$dim.png
	if {![raster::keyed $out $dkey]} {
		set p [image create photo -file $base]
		set a [expr {int(round($dim * 2.55))}]
		set shade [image create photo -data [raster::png 1 1 [list [list 0 0 0 $a]]] -format png]
		$p copy $shade -to 0 0 $W $H -compositingrule overlay
		$p write $out.[pid] -format png
		file rename -force $out.[pid] $out
		raster::store_key $out $dkey
		image delete $p $shade
	}
	return $out
}

# The login screen's background blurred and dimmed in memory, from the
# picture laid out at the screen's size ("" while that is not made yet):
# with rbnalpha's C blur straight away (~40 ms; the greeter makes its own
# as fast); else the warm job's blurred file when it is there, and the
# cheap blur (wall::blurred_quick) until then.
proc stage::login_photo {s o} {
	variable W
	variable H
	variable lp
	if {[lindex $s 0] ni {picture video}} { return "" }
	set f [expr {[lindex $s 0] eq "video" ? [lindex $s 2] : [lindex $s 1]}]
	if {$f eq "" || ![file readable $f]} { return "" }
	set colour [dict get $o COLOUR]
	set bgc [expr {$colour ne "" ? $colour : [dict get [lindex $s end] DESK_BOTTOM]}]
	set base [wall::prepare_path $f $W $H [dict get $o FIT] $bgc]
	if {![file exists $base]} { warm $f [dict get $o FIT] $bgc 0; return "" }
	set blur [dict get $o BLUR]
	set full [expr {$blur > 0 ? "[file rootname $base]-blur$blur.png" : $base}]
	set ready [expr {[wall::fast_blur] || [file exists $full]}]
	if {![file exists $full]} { warm $f [dict get $o FIT] $bgc $blur }
	set key [list $base $blur [dict get $o DIM] $ready]
	if {[info exists lp] && [lindex $lp 0] eq $key} { return [lindex $lp 1] }
	variable lsrc
	if {![info exists lsrc] || [lindex $lsrc 0] ne $base} {
		if {[info exists lsrc]} { image delete [lindex $lsrc 1] }
		set lsrc [list $base [image create photo -file $base]]
	}
	if {[info exists lp]} { image delete [lindex $lp 1] }
	if {[wall::fast_blur]} {
		set dst [image create photo]
		rbn::blur [lindex $lsrc 1] $dst $blur -dim [dict get $o DIM]
	} else {
		if {$ready} {
			set dst [image create photo -file $full]
		} elseif {$blur > 0} {
			set dst [wall::blurred_quick [lindex $lsrc 1] $blur]
		} else {
			set dst [image create photo]; $dst copy [lindex $lsrc 1]
		}
		set dim [dict get $o DIM]
		if {$dim > 0} {
			set shade [image create photo -data [raster::png 1 1 [list [list 0 0 0 [expr {int(round($dim * 2.55))}]]]] -format png]
			$dst copy $shade -to 0 0 [image width $dst] [image height $dst] -compositingrule overlay
			image delete $shade
		}
	}
	set lp [list $key $dst]
	return $dst
}

# ---- ribbon-wall -------------------------------------------------------------------

# ribbon-wall's preview commands (docs/WALLPAPER.md, "Previews"): shown at
# once with a crossfade, nothing written; owner= reverts it if the app quits.
proc stage::wall_line {s} {
	set own owner=[pid]
	switch -- [lindex $s 0] {
		picture {
			lassign $s - f fit colour show
			set bg [expr {[regexp {^#[0-9A-Fa-f]{6}$} $colour] ? " colour=$colour" : ""}]
			if {[lindex $show 0] eq "slideshow"} {
				lassign $show - dir interval crossfade shuffle subdirs
				return "preview slideshow $own fit=$fit$bg interval=$interval crossfade=$crossfade shuffle=$shuffle subdirs=$subdirs $dir"
			}
			if {$f eq ""} { return "preview design $own ribbon" }
			return "preview picture $own fit=$fit$bg $f"
		}
		video { return "preview video $own fit=fill [lindex $s 1]" }
		colour { return "preview colour $own [lindex $s 1]" }
		default { return "preview design $own ribbon" }
	}
}

proc stage::wall_send {line} {
	set fifo [file join [store::env XDG_RUNTIME_DIR /tmp] ribbon-wall]
	# never block on a FIFO nobody reads
	if {[catch {open $fifo {WRONLY NONBLOCK}} fh]} return
	catch { puts $fh $line; close $fh }
}

# ---- swaybg -------------------------------------------------------------------------

proc stage::swaybg_show {} {
	variable spec
	set f [screen $spec]
	catch {exec pkill -u [exec id -u] -x swaybg}
	catch {exec setsid swaybg -i $f -m fill >/dev/null 2>/dev/null &}
}

# ---- a window of our own (tests, scenes) -----------------------------------------

proc stage::window_show {} {
	variable spec
	variable W
	variable H
	if {![winfo exists .stage]} {
		toplevel .stage -borderwidth 0 -highlightthickness 0
		wm overrideredirect .stage 1
		wm geometry .stage ${W}x$H+0+0
		canvas .stage.c -width $W -height $H -highlightthickness 0 -borderwidth 0
		pack .stage.c
		image create photo ::stage::shown
		.stage.c create image 0 0 -image ::stage::shown -anchor nw
	}
	::stage::shown read [screen $spec] -shrink
	wm deiconify .stage
	raise .stage
	if {[winfo exists .sheet]} { raise .sheet }
}

proc stage::hide_window {} {
	if {[winfo exists .stage]} { wm withdraw .stage }
}

# ---- the login screen: the greeter itself ----------------------------------------

# A private /etc/ribbon for the greeter: the palette, the picture and
# options.conf as they would be after Apply.
proc stage::login_show {s o} {
	variable greeter
	variable gdir
	if {$gdir eq ""} {
		set gdir [file join [store::env XDG_RUNTIME_DIR [store::env TMPDIR /tmp]] ribbon-appearance-[pid]]
	}
	# updated in place, each file replaced at once: a running greeter may be
	# reading them
	set etc [file join $gdir etc ribbon]
	file mkdir [file join $etc login] [file join $gdir state]
	set pal [lindex $s end]
	if {[lindex $s 0] in {colour}} { set pal [lindex $s 2] }
	pal::write [file join $etc palette.conf] $pal
	set pic ""
	switch -- [lindex $s 0] {
		picture { set pic [lindex $s 1] }
		video { set pic [lindex $s 2] }
	}
	set keep ""
	if {$pic ne "" && [file readable $pic]} {
		set ext [string tolower [file extension $pic]]
		if {$ext eq ".jpeg"} { set ext .jpg }
		# a link: the greeter's cache key is the picture it points to, so it
		# finds what the app has warmed
		set keep [file join $etc login background$ext]
		set tmp $keep.[pid].new
		file delete -force $tmp
		file link -symbolic $tmp [file normalize $pic]
		file rename -force $tmp $keep
	}
	foreach e {png jpg webp} {
		set f [file join $etc login background.$e]
		if {$f ne $keep} { file delete -force $f }
	}
	set out ""
	dict for {k v} $o { append out "$k=$v\n" }
	set f [file join $etc login options.conf]
	set fh [open $f.new w]; puts -nonewline $fh $out; close $fh
	file rename -force $f.new $f
	# running: it redraws in place
	if {$greeter ne "" && ![catch { puts $greeter reload; flush $greeter }]} return
	login_stop
	set dir [find_dir greeter main.tcl]
	set cache [store::env XDG_CACHE_HOME [file join [store::env HOME /tmp] .cache]]
	set env [list RIBBON_GREETER_ETC=[file join $gdir etc] RIBBON_GREETER_STATE=[file join $gdir state] \
		RIBBON_GREETER_CACHE=$cache RIBBON_GREETER_TEST=[file join $dir preview.tcl] RIBBON_PREVIEW_STDIN=1]
	set greeter [open |[list env {*}$env [info nameofexecutable] -encoding utf-8 [file join $dir main.tcl] -name ribbon-greeter-preview 2>@stderr] w]
	# keep the sheet above it once it is up
	foreach t {600 1500 4000 8000} { after $t { if {[winfo exists .sheet]} { raise .sheet } } }
}

# ---- warming the cache: lay out and blur in the background -------------------

# Make the login screen's picture (F laid out as FIT on BG, blurred by BLUR)
# in a background job: the same wall.tcl code and cache as the greeter, so
# both find it. One job at a time; the newest request waits for it.
proc stage::warm {f fit bg blur} {
	variable job
	variable next
	variable W
	variable H
	set key [list $f $W $H $fit $bg $blur]
	if {$job ne "" && [lindex $job 1] eq $key} return
	if {$job ne ""} { set next $key; return }
	set script [file join $::appdir warm.tcl]
	if {[catch {open |[list [info nameofexecutable] -encoding utf-8 $script {*}$key 2>@1] r} fh]} return
	fconfigure $fh -blocking 0
	fileevent $fh readable [list stage::warm_read $fh]
	set job [list $fh $key]
}
proc stage::warm_read {fh} {
	variable job
	variable next
	variable spec
	read $fh
	if {![eof $fh]} return
	catch {close $fh}
	set job ""
	# what is shown now uses it: redraw the sheet, the greeter reloads
	if {[lindex $spec 0] eq "login"} {
		variable greeter
		if {$greeter ne ""} { catch { puts $greeter reload; flush $greeter } }
	}
	if {[info commands os::draw] ne ""} { os::draw }
	if {$next ne ""} { set k $next; set next ""; warm {*}[lrange $k 0 0] {*}[lrange $k 3 5] }
}

proc stage::login_stop {} {
	variable greeter
	if {$greeter eq ""} return
	set pids [pid $greeter]
	catch { puts $greeter quit; flush $greeter }
	catch { exec kill {*}$pids }
	catch { close $greeter }
	set greeter ""
}

proc stage::quit {} {
	variable gdir
	login_stop
	if {$gdir ne ""} { catch {file delete -force $gdir} }
}
