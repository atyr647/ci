# bgpages.tcl - the desktop background and the login screen: their
# settings, how Apply hands them to ribbon-theme, and (kept apart from the
# rest so they can be redrawn on their own) the two pages.
#
# The desktop: ~/.config/ribbon/wallpaper.conf, written only through
# "ribbon-theme wallpaper ..." (see that script for the keys: MODE, IMAGE,
# FIT, COLOUR, SLIDESHOW_DIR, INTERVAL, CROSSFADE, SHUFFLE, SUBDIRS,
# VIDEO, PAUSE_FULLSCREEN, PAUSE_COVERED, PAUSE_GAME, PAUSE_BATTERY, BARS).
# The login screen: /etc/ribbon/login/ (a background picture and
# options.conf: FIT, BLUR, DIM, CLOCK, COLOUR), written by the privileged
# helper through "ribbon-theme wallpaper login ..." and "ribbon-theme login
# options ...".

namespace eval bg {
	variable desk           ;# dict: mode image fit colour dir interval crossfade shuffle subdirs video pause_fullscreen pause_covered pause_game pause_battery bars
	variable login          ;# dict: same source image fit colour blur dim clock
	variable applied        ;# what was applied last (or found at start): {desk login}
	variable changed 0      ;# Apply changed a background since the start
	variable DESK_KEYS {
		MODE mode IMAGE image FIT fit COLOUR colour SLIDESHOW_DIR dir INTERVAL interval
		CROSSFADE crossfade SHUFFLE shuffle SUBDIRS subdirs VIDEO video
		PAUSE_FULLSCREEN pause_fullscreen PAUSE_COVERED pause_covered PAUSE_GAME pause_game
		PAUSE_BATTERY pause_battery BARS bars
	}
}

proc bg::conf_file {} { file join [store::config] ribbon wallpaper.conf }
proc bg::login_dir {} { file join [store::env RIBBON_LOGIN_ROOT] etc ribbon login }

# KEY=VALUE lines of FILE as a dict (nothing in them is run).
proc bg::read_kv {file} {
	set d {}
	if {[catch {open $file} fh]} { return $d }
	foreach line [split [read $fh 65536] \n] {
		if {[regexp {^([A-Z_0-9]+)=(.*)$} $line -> k v]} { dict set d $k [string trim $v \"'] }
	}
	close $fh
	return $d
}

proc bg::init {} {
	variable desk
	variable login
	variable applied
	variable DESK_KEYS
	set desk [dict create mode pattern image "" fit fill colour [dict get [store::current_palette] FIELD] \
		dir "" interval 600 crossfade 1.5 shuffle yes subdirs no video "" \
		pause_fullscreen yes pause_covered no pause_game no pause_battery no bars see-through]
	set kv [read_kv [conf_file]]
	dict for {k v} $kv {
		if {[dict exists $DESK_KEYS $k]} { dict set desk [dict get $DESK_KEYS $k] $v }
	}
	# a wallpaper.conf from before MODE: a picture if it names one
	if {![dict exists $kv MODE]} { dict set desk mode [expr {[dict get $desk image] ne "" ? "picture" : "pattern"}] }
	set login [dict create same 0 source pattern image "" fit fill colour [dict get $desk colour] blur 0 dim 0 clock yes]
	set best ""; set bt -1
	foreach e {png jpg webp} {
		set f [file join [login_dir] background.$e]
		if {[file isfile $f] && [file mtime $f] > $bt} { set best $f; set bt [file mtime $f] }
	}
	set opts [read_kv [file join [login_dir] options.conf]]
	foreach {k key} {FIT fit BLUR blur DIM dim CLOCK clock COLOUR colour} {
		if {[dict exists $opts $k]} { dict set login $key [dict get $opts $k] }
	}
	if {$best ne ""} {
		dict set login source picture
		dict set login image $best
	} elseif {[dict exists $opts COLOUR] && [dict get $opts COLOUR] ne ""} {
		dict set login source colour
	}
	set applied [list $desk $login]
}

proc bg::snapshot {} {
	variable desk
	variable login
	list $desk $login
}
proc bg::restore {s} {
	variable desk
	variable login
	lassign $s desk login
}
# What is set now counts as applied (scenes and tests set it up by hand).
proc bg::applied_now {} {
	variable applied
	set applied [snapshot]
}

proc bg::applied_since {} {
	variable changed
	return $changed
}

# What a thumbnail shows behind the miniature: the theme's pattern, or a
# picture (W x H, scaled to cover and cropped in the middle).
proc bg::thumb_bg {which w h} {
	variable desk
	variable login
	set d [expr {$which eq "desktop" ? $desk : [effective_login]}]
	set mode [expr {$which eq "desktop" ? [dict get $d mode] : [dict get $d source]}]
	switch -- $mode {
		picture - slideshow - video {
			set f [dict get $d image]
			if {$f ne "" && ![catch {picture $f $w $h} p]} { return [list photo $p] }
		}
		colour {
			set p [ui::mem [list solid [dict get $d colour] $w $h] {
				set i [image create photo -width $w -height $h]
				$i put [dict get $d colour] -to 0 0 $w $h
				set out [$i data -format png]; image delete $i; set out
			}]
			return [list photo $p]
		}
	}
	return pattern
}

# FILE scaled to cover W x H and cropped in the middle, as a photo (the
# shell's wall::prepare does the same at the screen's size).
proc bg::picture {file w h} {
	ui::mem [list picture $file [file mtime $file] $w $h] {
		set tmp [file join [raster::dir] thumb-[pid].png]
		set src ""
		if {[auto_execok gdk-pixbuf-thumbnailer] ne ""} {
			lassign [wall::image_size $file] iw ih
			set s [expr {max(double($w) / $iw, double($h) / $ih)}]
			# only ever down (the thumbnailer enlarges too): a smaller picture is read at its own size, centred below
			set size [expr {$s < 1 ? int(ceil(max($iw * $s, $ih * $s))) : max($iw, $ih)}]
			if {![catch {exec gdk-pixbuf-thumbnailer -s $size $file $tmp}]} { set src [image create photo -file $tmp]; file delete $tmp }
		}
		if {$src eq ""} {
			set src [image create photo -file $file]
			set k [expr {max(1, min([image width $src] / $w, [image height $src] / $h))}]
			if {$k > 1} { set t [image create photo]; $t copy $src -subsample $k; image delete $src; set src $t }
		}
		# larger than W x H: the middle is kept; smaller in a direction: centred on the field's fill
		# (a copy past the source's edge fails in Tk)
		set iw [image width $src]; set ih [image height $src]
		set sw [expr {min($w, $iw)}]; set sh [expr {min($h, $ih)}]
		set sx [expr {max(0, ($iw - $w) / 2)}]; set sy [expr {max(0, ($ih - $h) / 2)}]
		set dx [expr {max(0, ($w - $iw) / 2)}]; set dy [expr {max(0, ($h - $ih) / 2)}]
		set o [image create photo -width $w -height $h]
		$o put [expr {[info exists ui::c(field)] ? $ui::c(field) : "#000000"}] -to 0 0 $w $h
		$o copy $src -from $sx $sy [expr {$sx + $sw}] [expr {$sy + $sh}] -to $dx $dy [expr {$dx + $sw}] [expr {$dy + $sh}]
		set out [$o data -format png]
		image delete $src $o
		set out
	}
}

# The login screen's settings as applied: "same as the desktop" takes the
# desktop's background (its picture for a slideshow or a video).
proc bg::effective_login {} {
	variable desk
	variable login
	if {![dict get $login same]} { return $login }
	set l $login
	switch -- [dict get $desk mode] {
		pattern { dict set l source pattern }
		colour { dict set l source colour; dict set l colour [dict get $desk colour] }
		default {
			if {[dict get $desk image] ne ""} {
				dict set l source picture; dict set l image [dict get $desk image]; dict set l fit [dict get $desk fit]
			} else { dict set l source pattern }
		}
	}
	return $l
}

proc bg::yesno {v} { expr {$v in {1 yes true on} ? "yes" : "no"} }

# A slideshow's interval in whole seconds, 1 minute to 7 days.
proc bg::interval {v} {
	if {![string is double -strict $v]} { return 600 }
	expr {max(60, min(604800, int(round($v))))}
}

# The ribbon-theme commands that apply the backgrounds, as page::run_jobs
# takes them: {what args}. Only what differs from what was applied.
proc bg::apply_jobs {todesk tologin} {
	variable desk
	variable applied
	variable changed
	lassign $applied adesk alogin
	set jobs {}
	if {$todesk && $desk ne $adesk} {
		set d $desk
		switch -- [dict get $d mode] {
			pattern { lappend jobs [list "desktop background" {wallpaper ribbon}] }
			picture { lappend jobs [list "desktop background" [list wallpaper set [dict get $d image] --fit [dict get $d fit]]] }
			colour { lappend jobs [list "desktop background" [list wallpaper colour [dict get $d colour]]] }
			slideshow {
				lappend jobs [list "desktop background" [list wallpaper slideshow [dict get $d dir] \
					--interval [interval [dict get $d interval]] --crossfade [dict get $d crossfade] \
					--shuffle [yesno [dict get $d shuffle]] --subdirs [yesno [dict get $d subdirs]] --fit [dict get $d fit]]]
			}
			video {
				lappend jobs [list "desktop background" [list wallpaper video [dict get $d video] \
					--pause-fullscreen [yesno [dict get $d pause_fullscreen]] --pause-covered [yesno [dict get $d pause_covered]] \
					--pause-game [yesno [dict get $d pause_game]] --pause-battery [yesno [dict get $d pause_battery]] \
					--bars [expr {[dict get $d bars] eq "solid" ? "solid" : "see-through"}]]]
			}
		}
		set adesk $desk
		set changed 1
	}
	set l [effective_login]
	if {$tologin && $l ne $alogin} {
		set old $alogin
		set img [expr {[dict get $l source] eq "picture" ? [dict get $l image] : "ribbon"}]
		set oldimg [expr {[dict get $old source] eq "picture" ? [dict get $old image] : "ribbon"}]
		if {$img ne $oldimg} { lappend jobs [list "login background" [list wallpaper login $img]] }
		set opts [list FIT=[dict get $l fit] BLUR=[dict get $l blur] DIM=[dict get $l dim] CLOCK=[yesno [dict get $l clock]] \
			COLOUR=[expr {[dict get $l source] eq "colour" ? [dict get $l colour] : ""}]]
		lappend jobs [list "login screen" [list login options {*}$opts]]
		set alogin $l
		set changed 1
	}
	set applied [list $adesk $alogin]
	return $jobs
}
