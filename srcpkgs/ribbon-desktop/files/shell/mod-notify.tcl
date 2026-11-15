# mod-notify.tcl - the shell's notifications: the D-Bus server (notifyd.tcl)
# and the popups (STYLE §19, Notify-Final-1 to 4). A shell module (C2).
#
# The server starts once the shell is up: shell::bus loads ribbon::dbus on that
# first call, and a shell with no session bus runs on without notifications.
# The popups are one ARGB surface at the bottom left: the scrim, the entry
# (its rule at x 28, text from x 48, its foot 64 above the bottom), up to three
# one-liners above it, each fainter. Nothing takes the keyboard. Under a
# compositor the surface is one see-through picture (npaint, below): text on the
# desktop over the scrim, no card.
#
# What an entry shows beyond the spec's summary and body:
#   its app's icon      the shell's line icon for the app (the desktop-entry hint, else
#                       the app's name); else the notification's own picture (image-data,
#                       image-path, or an app_icon that is a file), at most 14 px
#   its progress        the value hint (0 to 100) draws the bar; under it "N %", or the
#                       sender's own words from the x-ribbon-progress-text hint
#                       ("1.2 of 3.4 GB"), and the time left
#   its body            markup is taken out (the server says body-markup: it accepts it)
#
# Hooks for the history (mod-notify-history.tcl), all in namespace notify:
#   notify::history           every entry, newest first (dicts: id app icon summary
#                             body actions hints urgency timeout sender replaces
#                             time seen open value)
#   notify::unseen            entries nobody has seen (the history's count, the bell)
#   notify::seen              mark every entry seen (the history calls this on open)
#   notify::dismiss ID        close ID with reason 2 and take it off the popups
#   notify::forget ID         drop ID from the history as well (Clear)
#   notify::act ID ACTION     invoke ACTION, the action's identifier (the third item of notify::keycaps)
#   notify::keycaps ID        {key label action ...}: ↵ for the default action, then letters
#                             (the history module's list uses the same keys)
#   notify::onchange CMD      CMD is called with: kind id, kind arrived, closed, seen or forgot
#   notify::hold_filter       "" or a command prefix, called with an entry dict; true holds
#                             the entry's popup (Do Not Disturb sets it; critical ones are the filter's call)
#   notify::status            primary when the shell owns the name, else the reason it does not

source -encoding utf-8 [file join [file dirname [file normalize [info script]]] notifyd.tcl]

after idle [list notify::start]

namespace eval notify {
	variable W 1100          ;# the surface: the scrim's size, from the bottom left
	variable H 760
	variable store {}        ;# every entry the server has had, oldest first
	variable shown {}        ;# ids on the popups, oldest first
	variable timers           ;# id -> the after that expires or fades it
	array set timers {}
	variable fading           ;# id -> opacity while it fades out
	array set fading {}
	variable listeners {}
	variable hold_filter {}
	variable status off
	variable scrimkey ""
	variable scrimimg ""
	variable fonts_ok 0
	variable limit 200
	variable hits {}         ;# {x0 y0 x1 y1 script}: the popup's keycaps, from the last draw
	variable cv ""           ;# the canvas the last draw drew on (the surface's, or the stage)
	variable drawing 0
	variable pics             ;# a notification's own picture, by its source
	array set pics {}
	variable sounded 0       ;# when the alert sound last played (ms): a flood plays it once
}

proc notify::log {msg} {
	catch {
		set dir [expr {[info exists ::env(XDG_STATE_HOME)] ? $::env(XDG_STATE_HOME) : "$::env(HOME)/.local/state"}]
		file mkdir [file join $dir ribbon]
		set fh [open [file join $dir ribbon shell.log] a]
		puts $fh "[clock format [clock seconds] -format %H:%M:%S] notify: $msg"
		close $fh
	}
}

proc notify::start {} {
	variable status
	if {[catch {set bus [shell::bus]} err]} {
		set status "off: no session bus"
		notify::log "the server does not start: $err"
		return
	}
	if {[catch {set r [notifyd::start $bus -show notify::arrive -close notify::gone]} err]} {
		set status "off: $err"
		notify::log "the server does not start: $err"
		return
	}
	set status $r
	if {$r ne "primary"} { notify::log "org.freedesktop.Notifications is $r, not ours" }
}

# The stages of the see-through surfaces are made when the shell starts, so that their windows are
# there, drawn once, before the first notification needs them.
proc notify::stages {} {
	variable H
	if {![npaint::on]} return
	npaint::stage notify 464 $H
	npaint::stage nhist 464 [winfo screenheight .]
}
after idle [list after 200 notify::stages]

# The main display moved (display.tcl): the popups on the screen and the open history go with it. The popups are
# taken off the screen first and shown again there: Tk puts a mapped override-redirect window back where it was
# when it is raised before the move is made.
proc notify::moved {} {
	if {[winfo exists .notify] && [winfo ismapped .notify]} { rbn::hide .notify; notify::draw }
	if {[llength [info commands ::nhist::draw]]} { nhist::draw }
}
display::on_change notify::moved

# ---- the store --------------------------------------------------------------

proc notify::find {id} {
	variable store
	foreach e $store { if {[dict get $e id] == $id} { return $e } }
	return ""
}

proc notify::put {e} {
	variable store
	variable limit
	set id [dict get $e id]
	set new {}
	set found 0
	foreach x $store {
		if {[dict get $x id] == $id} { lappend new $e; set found 1 } else { lappend new $x }
	}
	if {!$found} { lappend new $e }
	# keep the history short: the oldest closed entry goes first
	if {[llength $new] > $limit} {
		set i 0
		foreach x $new { if {![dict get $x open]} break; incr i }
		if {$i < [llength $new]} { set new [lreplace $new $i $i] }
	}
	set store $new
}

proc notify::history {} {
	variable store
	lreverse $store
}

proc notify::unseen {} {
	variable store
	set n 0
	foreach e $store { if {![dict get $e seen]} { incr n } }
	return $n
}

proc notify::set_field {id field value} {
	variable store
	set store [lmap x $store { expr {[dict get $x id] == $id ? [dict replace $x $field $value] : $x} }]
}

proc notify::opacity {id} {
	variable fading
	expr {[info exists fading($id)] ? $fading($id) : 1.0}
}

proc notify::seen {} {
	variable store
	set store [lmap x $store { dict replace $x seen 1 }]
	notify::changed seen 0
	notify::draw
}

proc notify::changed {kind id} {
	variable listeners
	foreach l $listeners { catch {{*}$l $kind $id} }
}

proc notify::onchange {cmd} {
	variable listeners
	lappend listeners $cmd
}

# ---- what arrives -----------------------------------------------------------

# An entry's lifetime in ms; 0 stays until it is dismissed or resolved.
# Critical stays; a progress entry without its own timeout stays until it is done (then 5 s).
proc notify::lifetime {e} {
	if {[dict get $e urgency] == 2} { return 0 }
	set v [dict get $e value]
	set t [dict get $e timeout]
	if {$v ne "" && $t > 0} { return $t }
	if {$v ne ""} {
		if {$v >= 100} { return 5000 }
		return 0
	}
	if {$t == 0} { return 0 }
	if {$t < 0} { return 5000 }
	return $t
}

# The alert sound for a new notification (Settings → Sound: Sound for alerts, and the alerts' volume, sound.conf's
# ALERTS and ALERT_VOLUME): the sound theme's message sound through paplay, unless the notification asks for none
# (the suppress-sound hint) or the sound is not installed.
proc notify::sound {hints} {
	if {[dict exists $hints suppress-sound] && [dict get $hints suppress-sound]} return
	if {[bar::conf sound ALERTS yes] eq "no"} return
	set vol [bar::conf sound ALERT_VOLUME 70]
	if {![string is integer -strict $vol] || $vol <= 0} return
	variable sounded
	set now [clock milliseconds]
	if {$now - $sounded < 1000} return
	set sounded $now
	foreach f {/usr/share/sounds/freedesktop/stereo/message.oga /usr/share/sounds/freedesktop/stereo/bell.oga} {
		if {[file readable $f]} {
			catch {exec paplay --volume=[expr {min(65536, $vol * 65536 / 100)}] $f >&/dev/null &}
			return
		}
	}
}

proc notify::arrive {n} {
	variable hold_filter
	variable timers
	variable fading
	variable shown
	set id [dict get $n id]
	set hints [dict get $n hints]
	set value ""
	if {[dict exists $hints value]} { set value [dict get $hints value] }
	# a number, and a finite one (NaN and Inf are doubles too)
	if {$value ne "" && (![string is double -strict $value] || [catch {expr {max(0, min(100, int($value)))}} value])} {
		set value ""
	}
	# a picture is kept at the size it is drawn (the store is the saved history); a malformed one goes
	foreach k {image-data image_data icon_data} {
		if {![dict exists $hints $k]} continue
		set small [notify::shrink [dict get $hints $k]]
		if {$small eq ""} { dict unset hints $k } else { dict set hints $k $small }
	}
	dict set n hints $hints
	set e [dict merge $n [dict create time [clock seconds] seen 0 open 1 value $value t0 [clock seconds] v0 $value]]
	dict set e body [notify::plain [dict get $e body]]
	set old [notify::find $id]
	if {$old eq ""} { notify::sound $hints }
	if {$old ne "" && [dict get $old value] ne "" && $value ne ""} {
		# a progress that goes on keeps when and where it began, for the time left
		dict set e t0 [dict get $old t0]
		dict set e v0 [dict get $old v0]
	}
	notify::put $e
	if {[info exists timers($id)]} { after cancel $timers($id); unset timers($id) }
	catch {unset fading($id)}
	if {$hold_filter ne "" && [catch {{*}$hold_filter $e} held] == 0 && [string is true -strict $held]} {
		notify::changed arrived $id
		return
	}
	set shown [lsearch -all -inline -exact -not $shown $id]
	lappend shown $id
	set ms [notify::lifetime $e]
	if {$ms > 0} { set timers($id) [after $ms [list notify::timeout $id]] }
	notify::draw
	notify::changed arrived $id
}

# The app asked to close one: the server answers with reason 3 itself.
proc notify::gone {id} {
	notify::drop $id
	notify::changed closed $id
	notify::passing $id
}

# A transient notification by-passes the history (the spec's "transient" hint): it goes once it closes.
proc notify::passing {id} {
	set e [notify::find $id]
	if {$e eq ""} return
	set h [dict get $e hints]
	if {[dict exists $h transient] && [string is true -strict [dict get $h transient]]} { notify::forget $id }
}

proc notify::timeout {id} {
	variable timers
	unset -nocomplain timers($id)
	notify::fade $id 0.66
}

proc notify::fade {id a} {
	variable timers
	variable fading
	if {$a <= 0.05} { notify::remove $id 1; return }
	set fading($id) $a
	notify::draw
	set timers($id) [after 90 [list notify::fade $id [expr {$a - 0.22}]]]
}

# Off the popups; the entry stays in the history.
proc notify::drop {id} {
	variable shown
	variable timers
	variable fading
	if {[info exists timers($id)]} { after cancel $timers($id); unset timers($id) }
	catch {unset fading($id)}
	set shown [lsearch -all -inline -exact -not $shown $id]
	notify::set_field $id open 0
	notify::draw
}

proc notify::remove {id reason} {
	notify::drop $id
	notifyd::closed $id $reason
	notify::changed closed $id
	notify::passing $id
}

proc notify::dismiss {id} { notify::remove $id 2 }

proc notify::forget {id} {
	variable store
	notify::drop $id
	set new {}
	foreach x $store { if {[dict get $x id] != $id} { lappend new $x } }
	set store $new
	notify::changed forgot $id
}

# The keys an entry's actions answer to: ↵ for the default, then a letter from
# the label (the first free one), as the boards draw them.
proc notify::keycaps {id} {
	set e [notify::find $id]
	if {$e eq ""} { return {} }
	# the default action (key "default") goes first
	set pairs {}
	set def {}
	foreach {k l} [dict get $e actions] {
		if {$k eq "default"} { set def [list $k $l] } else { lappend pairs $k $l }
	}
	set pairs [concat $def $pairs]
	set out {}
	set used {}
	foreach {k l} $pairs {
		if {$k eq "default"} {
			set key "↵"
		} else {
			set key ""
			foreach ch [split $l ""] {
				set u [string toupper $ch]
				if {[string is alpha $u] && $u ni $used} { set key $u; break }
			}
			if {$key eq ""} { set key "?" }
		}
		lappend used $key
		lappend out $key $l $k
	}
	return $out
}

proc notify::act {id action} {
	set e [notify::find $id]
	if {$e eq ""} return
	notifyd::invoked $id $action
	set hints [dict get $e hints]
	set resident [expr {[dict exists $hints resident] && [dict get $hints resident]}]
	# an action ends the notification unless it is resident or a progress that goes on
	if {!$resident && [dict get $e value] eq ""} { notify::remove $id 2 }
}

# ---- drawing ----------------------------------------------------------------

proc notify::fonts {} {
	variable fonts_ok
	if {$fonts_ok} return
	foreach {name family px} {
		nTitle {Ribbon Space Grotesk 600} 28
		nApp {Ribbon Inter 600} 12
		nTime {Ribbon Inter 400} 12
		nBody {Ribbon Inter 400} 14
		nKey {Ribbon Inter 600} 11
		nAct {Ribbon Inter 600} 13
		nActQ {Ribbon Inter 500} 13
		nOneT {Ribbon Inter 500} 13
		nSmall {Ribbon Inter 400} 12
	} { text::font $name $family $px }
	set fonts_ok 1
}

# a colour a of fg over the scrim's colour (opacity stands in for alpha)
proc notify::tone {a} {
	lassign [raster::rgb $::theme::c(FG)] r1 g1 b1
	lassign [raster::rgb $::theme::c(DESK_BOTTOM)] r2 g2 b2
	set f [list $r1 $g1 $b1]
	set bg [list $r2 $g2 $b2]
	set out "#"
	foreach x $f y $bg { append out [format %02x [expr {int(round($a * $x + (1 - $a) * $y))}]] }
	return $out
}

# a radial scrim from the bottom left (STYLE §19: d2 at 90 %, 70 % at 45 %, none
# at the ellipse's edge, 78 % by 84 % of the surface), at 1/8 size and zoomed
proc notify::scrim_png {bg w h s} {
	lassign [raster::rgb $bg] r g b
	set sw [expr {int(ceil($w / double($s)))}]
	set sh [expr {int(ceil($h / double($s)))}]
	set rows {}
	for {set j 0} {$j < $sh} {incr j} {
		set row {}
		set dy [expr {($h - ($j * $s + $s / 2.0)) / (0.84 * $h)}]
		for {set i 0} {$i < $sw} {incr i} {
			set dx [expr {($i * $s + $s / 2.0) / (0.78 * $w)}]
			set rr [expr {hypot($dx, $dy)}]
			if {$rr <= 0.45} {
				set a [expr {0.9 - 0.2 * $rr / 0.45}]
			} elseif {$rr < 1} {
				set a [expr {0.7 * (1 - ($rr - 0.45) / 0.55)}]
			} else { set a 0 }
			lappend row $r $g $b [expr {int(round(255 * $a))}]
		}
		lappend rows $row
	}
	raster::png $sw $sh $rows
}

proc notify::scrim {} {
	variable W
	variable H
	variable scrimkey
	variable scrimimg
	set bg $::theme::c(DESK_BOTTOM)
	if {$scrimimg ne "" && $scrimkey eq $bg} { return $scrimimg }
	set small [raster::cached [list notify-scrim $bg $W $H] [list notify::scrim_png $bg $W $H 8]]
	set img [image create photo]
	$img copy $small -zoom 8 8
	set scrimimg $img
	set scrimkey $bg
	return $img
}

# A body without its markup (the spec's <b> <i> <u> <a> <img>), its entities read.
proc notify::plain {body} {
	set s [regsub -all -nocase {<br\s*/?>} $body "\n"]
	set s [regsub -all -nocase {<img\M[^>]*\malt="([^"]*)"[^>]*>} $s {\1}]
	set s [regsub -all -nocase {</?(b|i|u|a|img)\M[^>]*>} $s ""]
	notify::entities $s
}

# XML's entities read, each once: the five named ones and &#N; &#xN; (a character Tk can draw; any other
# stays as it was written).
proc notify::entities {s} {
	set out ""
	set at 0
	while {[regexp -start $at -indices {&(lt|gt|quot|apos|amp|#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6});} $s m g]} {
		lassign $m a b
		append out [string range $s $at [expr {$a - 1}]]
		set name [string range $s {*}$g]
		switch -- $name {
			lt { append out < }
			gt { append out > }
			quot { append out \" }
			apos { append out ' }
			amp { append out & }
			default {
				set n [expr {[string match {#[xX]*} $name] ? [scan [string range $name 2 end] %x] : [scan [string range $name 1 end] %d]}]
				if {$n == 9 || $n == 10 || $n == 13 || ($n >= 32 && $n <= 0xFFFD && ($n < 0xD800 || $n > 0xDFFF))} {
					append out [::format %c $n]
				} else {
					append out [string range $s $a $b]
				}
			}
		}
		set at [expr {$b + 1}]
	}
	append out [string range $s $at end]
}

# An image-data hint ({width height rowstride alpha bits channels data}) cut to at most 14 px a side, taking
# every Nth pixel as the picture's subsample does; "" when it is not a picture this draws (8 bits, 3 or 4
# channels, data long enough for its rows).
proc notify::shrink {d} {
	if {[catch {llength $d} n] || $n != 7} { return "" }
	lassign $d iw ih stride alpha bits ch data
	foreach v [list $iw $ih $stride $bits $ch] { if {![string is integer -strict $v]} { return "" } }
	if {$bits != 8 || ($ch != 3 && $ch != 4) || $iw < 1 || $ih < 1 || $stride < $iw * $ch} { return "" }
	set need [expr {($ih - 1) * $stride + $iw * $ch}]
	# the bytes as they came, or as a list of numbers
	if {[string length $data] < $need && ![catch {binary format c* $data} bin]} { set data $bin }
	if {[string length $data] < $need} { return "" }
	set f [expr {int(ceil(max($iw, $ih) / 14.0))}]
	if {$f <= 1} { return [list $iw $ih $stride $alpha $bits $ch $data] }
	set w [expr {($iw + $f - 1) / $f}]
	set h [expr {($ih + $f - 1) / $f}]
	set out ""
	for {set r 0} {$r < $h} {incr r} {
		set row [expr {$r * $f * $stride}]
		for {set c 0} {$c < $w} {incr c} {
			set p [expr {$row + $c * $f * $ch}]
			append out [string range $data $p [expr {$p + $ch - 1}]]
		}
	}
	list $w $h [expr {$w * $ch}] $alpha 8 $ch $out
}

# What stands under a progress bar: the sender's own words (x-ribbon-progress-text), else "N %".
proc notify::done {e} {
	set h [dict get $e hints]
	if {[dict exists $h x-ribbon-progress-text] && [dict get $h x-ribbon-progress-text] ne ""} {
		return [dict get $h x-ribbon-progress-text]
	}
	return "[dict get $e value] %"
}

# The notification's own picture, at most 14 px, or "": the image-data hint, the image-path hint, or
# an app_icon that names a file (icon theme names are not looked up: the shell draws its own icons).
proc notify::picture {e} {
	variable pics
	set hints [dict get $e hints]
	set full ""
	set key ""
	foreach k {image-data image_data icon_data} {
		if {![dict exists $hints $k]} continue
		set d [dict get $hints $k]
		if {[llength $d] != 7} break
		lassign $d iw ih stride - bits ch data
		set key [list data $iw $ih [zlib crc32 $data]]
		if {[info exists pics($key)]} { return $pics($key) }
		if {$bits == 8} {
			# the bytes as they came, or as a list of numbers
			if {[string length $data] < $ih * $stride - $stride + $iw * $ch && ![catch {binary format c* $data} bin]} { set data $bin }
			set full [npaint::raw_photo $iw $ih $stride $ch $data]
		}
		break
	}
	if {$key eq ""} {
		foreach k {image-path image_path -} {
			set p [expr {$k eq "-" ? ([dict exists $e icon] ? [dict get $e icon] : "") : ([dict exists $hints $k] ? [dict get $hints $k] : "")}]
			if {[string match file://* $p]} { set p [string range $p 7 end] }
			if {[string index $p 0] ne "/" || ![file readable $p] || [file isdirectory $p]} continue
			set key [list file $p [file mtime $p]]
			if {[info exists pics($key)]} { return $pics($key) }
			catch {set full [image create photo -file $p]}
			break
		}
	}
	if {$key eq ""} { return "" }
	if {[array size pics] > 64} { array unset pics }
	set img ""
	if {$full ne ""} {
		set f [expr {int(ceil(max([image width $full], [image height $full]) / 14.0))}]
		if {$f > 1} {
			set img [image create photo]
			$img copy $full -subsample $f $f
			image delete $full
		} else { set img $full }
	}
	set pics($key) $img
}

# The entry's icon: {line NAME}, one of the shell's line icons, for its app (the desktop-entry hint,
# else the app's name); else {photo IMG}, the notification's own picture; else "".
proc notify::icon_of {e} {
	set hints [dict get $e hints]
	set app [dict get $e app]
	set did [expr {[dict exists $hints desktop-entry] ? [dict get $hints desktop-entry] : ""}]
	set a ""
	foreach k [list $did $app] {
		if {$k ne "" && $a eq ""} { catch {set a [apps::forwindow $k]} }
	}
	set id [expr {$did ne "" ? $did : $app}]
	set name ""
	if {$a ne ""} {
		catch {set name [apps::iconfor $a $id]}
	} else {
		# the shell's own senders, then apps known by their name alone
		switch -nocase -- $app {
			Screenshot { set name camera }
			Files { set name folder }
			Updates { set name pkg }
			Calendar { set name calendar }
			Power { set name battery }
			Mousepad - Editor { set name file }
			default { catch {set name [apps::iconfor "" $id]} }
		}
	}
	# "grid" is the icon of an app nothing is known about: its own picture says more
	if {$name eq "" || $name eq "grid"} {
		set img [notify::picture $e]
		if {$img ne ""} { return [list photo $img] }
		if {$a eq ""} { set name "" }
	}
	if {$name ne "" && [info exists ::theme::icon($name)]} { return [list line $name] }
	return ""
}

# E's icon at X Y, 14 px: §fg (let through by A), or the accent on a critical one that stands. Returns how
# far along the text after it starts: 22, or 0 for an entry without an icon.
proc notify::icon {c e x y a} {
	lassign [notify::icon_of $e] kind v
	switch -- $kind {
		line {
			set crit [expr {[dict get $e urgency] == 2 && [dict get $e open]}]
			bar::icon $c $v 14 1.9 [expr {$crit ? $::theme::c(ACCENT) : [notify::tone $a]}] $x $y
		}
		photo {
			$c create image [expr {$x + (14 - [image width $v]) / 2}] [expr {$y + (14 - [image height $v]) / 2}] -image $v -anchor nw
		}
		default { return 0 }
	}
	return 22
}

proc notify::wrap {font str width maxlines} {
	set out {}
	set line ""
	foreach word [split $str] {
		set try [expr {$line eq "" ? $word : "$line $word"}]
		if {$line ne "" && [text::width $font $try] > $width} {
			lappend out $line
			# the lines past the last are not drawn: a long body is not measured to its end
			if {[llength $out] >= $maxlines} { return $out }
			set line $word
		} else {
			set line $try
		}
	}
	if {$line ne "" || $out eq ""} { lappend out $line }
	if {[llength $out] > $maxlines} { set out [lrange $out 0 [expr {$maxlines - 1}]] }
	return $out
}

proc notify::ago {t} {
	set d [expr {[clock seconds] - $t}]
	if {$d < 60} { return now }
	if {$d < 3600} { return "[expr {$d / 60}] min" }
	return [clock format $t -format %H:%M]
}

# A popup: returns {top bottom} of the entry, drawn with its foot at FOOT.
proc notify::big {c e a foot} {
	set x 48
	set w 380
	set title [notify::wrap nTitle [dict get $e summary] $w 2]
	set body [expr {[dict get $e body] eq "" ? {} : [notify::wrap nBody [dict get $e body] $w 3]}]
	set v [dict get $e value]
	set acts [notify::keycaps [dict get $e id]]
	# the heights, top to bottom: app line 22, title 6 above it, lines 32
	set hh [expr {22 + 6 + 32 * [llength $title]}]
	if {[llength $body]} { incr hh [expr {4 + 21 * [llength $body]}] }
	# the progress: 10, the bar 4, 8, its line 15 (Notify-Final-3)
	if {$v ne ""} { incr hh 37 }
	if {[llength $acts]} { incr hh [expr {8 + 22}] }
	set top [expr {$foot - $hh}]
	# its rule: what has not been seen, or a critical that stands
	if {([dict get $e seen] == 0 || [dict get $e urgency] == 2) && [dict get $e open]} {
		$c create rectangle 28 [expr {$top + 2}] 31 [expr {$foot - 2}] -fill $::theme::c(ACCENT) -width 0
	}
	set y $top
	set ago [notify::ago [dict get $e time]]
	set app [dict get $e app]
	# the app line: its icon (the accent on a critical one), the app, 8, the time
	set ax [expr {$x + [notify::icon $c $e $x [expr {$y + 4}] $a]}]
	text::draw $c $ax [expr {$y + 11}] nApp [notify::tone $a] $app w
	set aw [text::width nApp $app]
	text::draw $c [expr {$ax + $aw + 8}] [expr {$y + 11}] nTime [notify::tone [expr {0.6 * $a}]] $ago w
	incr y 28
	foreach line $title {
		# the line box is 32, the font's own height 36: it stands 2 above the box (CSS's half-leading)
		text::draw $c $x [expr {$y - 2}] nTitle [notify::tone $a] $line nw
		incr y 32
	}
	if {[llength $body]} {
		incr y 4
		foreach line $body {
			# 21 lines of a 17 px font: 2 into its line box
			text::draw $c $x [expr {$y + 2}] nBody [notify::tone [expr {0.76 * $a}]] $line nw
			incr y 21
		}
	}
	if {$v ne ""} {
		set bar [expr {$y + 10}]
		$c create rectangle $x $bar [expr {$x + $w}] [expr {$bar + 4}] -fill [notify::tone [expr {0.18 * $a}]] -width 0
		$c create rectangle $x $bar [expr {$x + $w * $v / 100.0}] [expr {$bar + 4}] -fill [notify::tone $a] -width 0
		set info [expr {$bar + 12}]
		text::draw $c $x $info nSmall [notify::tone [expr {0.6 * $a}]] [notify::done $e] nw
		set eta [notify::eta $e]
		if {$eta ne ""} { text::draw $c [expr {$x + $w}] $info nSmall [notify::tone [expr {0.6 * $a}]] $eta ne }
	}
	if {[llength $acts]} { notify::keys $c $acts $foot $a [dict get $e id] }
	return [list $top $foot]
}

# time left from the progress so far, or "" until there is a rate
proc notify::eta {e} {
	set v [dict get $e value]
	set dv [expr {$v - [dict get $e v0]}]
	set dt [expr {[clock seconds] - [dict get $e t0]}]
	if {$dv <= 0 || $dt < 1 || $v >= 100} { return "" }
	set s [expr {int(($dt * (100 - $v)) / double($dv))}]
	if {$s < 60} { return "About $s s left" }
	return "About [expr {($s + 30) / 60}] min left"
}

# The keycaps of a popup, 20 apart; the default one is the strong label.
proc notify::keys {c acts foot a id} {
	variable hits
	set y [expr {$foot - 22}]
	set x 48
	set first 1
	foreach {key label action} $acts {
		set kw [expr {max(22, [text::width nKey $key] + 12)}]
		rbn::box $c $x $y $kw 22 -fill $::theme::c(FIELD) -radius 5 -ring [list $::theme::c(BORDER) 1] -on ""
		text::draw $c [expr {$x + $kw / 2.0}] [expr {$y + 11}] nKey [notify::tone $a] $key c
		set lx [expr {$x + $kw + 8}]
		set lw [text::width [expr {$first ? "nAct" : "nActQ"}] $label]
		text::draw $c $lx [expr {$y + 11}] [expr {$first ? "nAct" : "nActQ"}] \
			[notify::tone [expr {($first ? 1.0 : 0.76) * $a}]] $label w
		# a click on the keycap or its label acts at once
		lappend hits [list $x $y [expr {$lx + $lw + 4}] [expr {$y + 22}] [list notify::act $id $action]]
		set x [expr {$lx + $lw + 20}]
		set first 0
	}
}

# A click on the popup: the keycap under it acts.
proc notify::press {x y} {
	variable hits
	foreach h [lreverse $hits] {
		lassign $h x0 y0 x1 y1 script
		if {$x >= $x0 && $x < $x1 && $y >= $y0 && $y < $y1} { uplevel #0 $script; return }
	}
}

# A one-liner: 26 tall, its bottom at BOTTOM (STYLE §19).
proc notify::line {c e bottom a} {
	set y [expr {$bottom - 26}]
	# no more is measured than can fit (a glyph is 2 px at the least)
	set t [dict get $e summary]
	# the body's first line follows the summary (Notify-Final-4: "Ludo · you up for a round tonight?")
	set body [lindex [split [dict get $e body] \n] 0]
	if {$body ne ""} { append t " · " $body }
	set t [string range $t 0 199]
	notify::icon $c $e 48 [expr {$y + 6}] $a
	text::draw $c 70 [expr {$y + 13}] nApp [notify::tone $a] [text::clip nApp [string range [dict get $e app] 0 59] 76] w
	set tw 260
	set clip [text::clip nOneT $t $tw]
	set end [text::draw $c 154 [expr {$y + 13}] nOneT [notify::tone $a] $clip w]
	text::draw $c [expr {154 + $end + 8}] [expr {$y + 13}] nSmall [notify::tone [expr {0.6 * $a}]] \
		[notify::ago [dict get $e time]] w
}

proc notify::draw {} {
	variable W
	variable H
	variable shown
	variable fading
	variable hits
	variable cv
	variable drawing
	# a draw asked for while another reads the stage waits for it
	if {$drawing} { after 5 notify::draw; return }
	notify::fonts
	set hits {}
	set w .notify
	set vis {}
	# an id whose entry is gone (a store replaced underneath) is skipped
	foreach id $shown { set e [notify::find $id]; if {$e ne ""} { lappend vis $e } }
	if {![llength $vis]} {
		if {$cv ne "" && [winfo exists $cv]} { $cv delete all }
		rbn::hide $w
		return
	}
	if {![winfo exists $w]} {
		rbn::surface $w
		# on the surface, not its canvas: a see-through surface has no canvas under the pointer
		bind $w <ButtonPress-1> {notify::press %x %y}
	}
	set paint [npaint::on]
	set c [expr {$paint ? [npaint::stage notify 464 $H] : "$w.c"}]
	set cv $c
	$c delete all
	# from the bottom left of the main display (display.tcl)
	lassign [display::rect] ox oy - oh
	set sy [expr {$oy + $oh - $H}]
	set big [lindex $vis end]
	set foot [expr {$H - 64}]
	lassign [notify::big $c $big [notify::opacity [dict get $big id]] $foot] top bottom
	set boxes [list [list 20 $top 420 [expr {$bottom - $top}]]]
	# the one-liners above, nearest first, at 0.8 / 0.56 / 0.34
	set near [lrange [lreverse [lrange $vis 0 end-1]] 0 2]
	set alphas {0.8 0.56 0.34}
	set bt [expr {$top - 14}]
	set i 0
	foreach e $near {
		set al [lindex $alphas $i]
		incr i
		set aa [expr {$al * [notify::opacity [dict get $e id]]}]
		notify::line $c $e $bt $aa
		lappend boxes [list 20 [expr {$bt - 26}] 420 26]
		set bt [expr {$bt - 26}]
	}
	if {$paint} {
		# one picture: the scrim, the boxes, the text with its alpha. Clicks land on the entries only.
		set drawing 1
		set code [catch {npaint::render notify $c $W $H [list [notify::scrim] 0 0] {{all ""}}} img]
		set drawing 0
		if {!$code && $img ne ""} {
			npaint::present $w $ox $sy $W $H $img $boxes 1
			return
		}
		if {$code} { notify::log "painting failed: $img"; set npaint::ok 0 }
		# the stage could not be read: drawn again, as plain boxes
		return [notify::draw]
	}
	rbn::show $w $ox $sy $W $H -pieces [list [rbn::piece [notify::scrim] 0 0]] \
		-shape $boxes -input $boxes -raise 1
}

# ---- see-through painting ---------------------------------------------------
#
# The popups and the history are text on the desktop over a scrim (STYLE §19: there is no card), so
# their text needs real alpha, which a Tk canvas cannot give: its window is opaque. Under a compositor
# the entries are therefore drawn on a stage, a canvas in a window kept off the screen, and the surface
# shows one picture made from it: the scrim, the stage's boxes and icons, then its text as §fg let
# through by each letter's coverage, over the text's shadow. The coverage is read back from the stage
# (its text in grey on black, through the canvas's own PostScript image of an embedded window, the one
# way Tk 8.6 reads a window), so every letter is the one Xft draws. Without a compositor (or when the
# stage cannot be read) the entries are drawn on the surface's own canvas, as opaque boxes.
#
#   npaint::on                    1 when surfaces are painted this way
#   npaint::stage NAME W H        NAME's stage canvas (made once), W x H
#   npaint::render NAME C W H BASE LAYERS
#       the W x H picture of stage canvas C: BASE is {photo x y ...} (the scrim); LAYERS is a list of
#       {tag clip}, bottom first: the items with that tag, cut to clip {x0 y0 x1 y1} ("" for none).
#       In a layer the boxes and pictures come first, then the text. Returns the photo, or "" when the
#       stage cannot be read (npaint::on is 0 from then on).
#   npaint::present W X Y WW WH PHOTO INPUT RAISE    show surface W with that picture
#   npaint::alpha PHOTO X Y       the picture's {r g b alpha} at a pixel (tests)

namespace eval npaint {
	variable ok -1
	variable onscreen 0     ;# the stage is on the screen (RIBBON_NOTIFY_PAINT=1: a test without a compositor)
	variable st             ;# name -> {W H}
	array set st {}
	variable ink            ;# name,tag -> {key y0 text shadow halo}
	array set ink {}
	variable out            ;# name -> the picture
	array set out {}
	variable grabs 0        ;# how often the stage was read (tests: a hover reads nothing)
}

proc npaint::on {} {
	variable ok
	variable onscreen
	if {$ok >= 0} { return $ok }
	set ok 0
	set force [expr {[info exists ::env(RIBBON_NOTIFY_PAINT)] ? $::env(RIBBON_NOTIFY_PAINT) : ""}]
	if {$force eq "0" || ![rbn::argb]} { return 0 }
	if {$force eq "1"} {
		set onscreen 1
		set ok 1
	} elseif {![catch {rbnalpha::composited} r] && $r} {
		set ok 1
	}
	return $ok
}

proc npaint::stage {name W H} {
	variable st
	variable onscreen
	set t .npaint_$name
	if {![winfo exists $t]} {
		toplevel $t -borderwidth 0 -highlightthickness 0 -background #000000
		wm overrideredirect $t 1
		wm geometry $t ${W}x$H+[expr {$onscreen ? 0 : -$W - 4000}]+[expr {$onscreen ? 0 : -$H - 4000}]
		canvas $t.o -highlightthickness 0 -borderwidth 0 -background #000000 -width $W -height $H
		place $t.o -x 0 -y 0
		frame $t.o.f -background #000000 -borderwidth 0 -highlightthickness 0
		canvas $t.o.f.c -highlightthickness 0 -borderwidth 0 -background #000000 -width $W -height $H \
			-scrollregion [list 0 0 $W 32000] -yscrollincrement 1 -confine 1
		place $t.o.f.c -x 0 -y 0
		$t.o create window 0 0 -window $t.o.f -anchor nw -width $W -height $H -tags win
		set st($name) [list $W $H]
	} elseif {$H > [lindex $st($name) 1]} {
		# a taller main display than the stage was made for (a monitor plugged in): the stage grows to it
		set W [lindex $st($name) 0]
		wm geometry $t ${W}x$H+[expr {$onscreen ? 0 : -$W - 4000}]+[expr {$onscreen ? 0 : -$H - 4000}]
		$t.o configure -height $H
		$t.o.f.c configure -height $H
		$t.o itemconfigure win -height $H
		set st($name) [list $W $H]
	}
	return $t.o.f.c
}

# Rows Y0 to Y0+H of NAME's stage in grey, the top row first, or "" when the stage cannot be read. White
# marks at the end of the first row and the start of the last prove the picture is the stage's, all of it.
proc npaint::grab {name y0 h} {
	variable st
	variable onscreen
	variable grabs
	lassign $st($name) W H
	set t .npaint_$name
	set c $t.o.f.c
	$t.o itemconfigure win -height $h
	$c yview moveto 0
	$c yview scroll $y0 units
	$c create rectangle [expr {$W - 2}] $y0 $W [expr {$y0 + 1}] -fill #ffffff -width 0 -tags npaint_mark
	$c create rectangle 0 [expr {$y0 + $h - 1}] 2 [expr {$y0 + $h}] -fill #ffffff -width 0 -tags npaint_mark
	if {$onscreen} { raise $t }
	set data ""
	foreach try {0 1} {
		# the second try lets the stage's windows arrive first (a stage used as soon as it is made)
		if {$try} { update } else { update idletasks }
		if {![winfo exists $c]} { return "" }
		set data ""
		if {[catch {$t.o postscript -colormode gray -x 0 -y 0 -width $W -height $h} ps]} break
		foreach {m bw bh hex} [regexp -all -inline {(\d+) (\d+) 8 matrix \{\n<([0-9A-F\n]*)>\n\} image} $ps] {
			append data [binary format H* [string map {\n ""} $hex]]
		}
		# the rows come bottom first: the marks are the first and the last bytes
		if {[string length $data] == $W * $h && [string index $data end] eq "\xff" && [string index $data 0] eq "\xff"} break
		set data ""
	}
	$c delete npaint_mark
	$c yview moveto 0
	incr grabs
	if {$data eq ""} { return "" }
	set rows {}
	for {set r [expr {$h - 1}]} {$r >= 0} {incr r -1} {
		lappend rows [string range $data [expr {$r * $W}] [expr {$r * $W + $W - 1}]]
	}
	# the marks are not part of the picture
	lset rows 0 [string range [lindex $rows 0] 0 end-2]\x00\x00
	lset rows end \x00\x00[string range [lindex $rows end] 2 end]
	return $rows
}

proc npaint::chunk {type data} {
	return [binary format I [string length $data]]$type$data[binary format I [zlib crc32 $type$data]]
}

# A photo of one colour whose alpha is ROWS' grey times SCALE (a PNG with a palette: no work per pixel).
proc npaint::mask {W rows rgb scale} {
	set tr ""
	for {set i 0} {$i < 256} {incr i} { append tr [binary format c [expr {int(round($i * $scale))}]] }
	set raw ""
	foreach row $rows { append raw \x00 $row }
	set png "\x89PNG\r\n\x1a\n"
	append png [chunk IHDR [binary format IIccccc $W [llength $rows] 8 3 0 0 0]]
	append png [chunk PLTE [string repeat [binary format ccc {*}$rgb] 256]]
	append png [chunk tRNS $tr]
	append png [chunk IDAT [zlib compress $raw 1]]
	append png [chunk IEND ""]
	image create photo -data $png -format png
}

# A raw picture as a photo: W x H, ROWSTRIDE bytes a row, CH channels (3 or 4) of 8 bits (the
# notification spec's image-data), or "" when the numbers do not fit the data.
proc npaint::raw_photo {W H stride ch data} {
	if {$W < 1 || $H < 1 || $W > 1024 || $H > 1024 || ($ch != 3 && $ch != 4) || $stride < $W * $ch} { return "" }
	if {[string length $data] < ($H - 1) * $stride + $W * $ch} { return "" }
	set raw ""
	for {set r 0} {$r < $H} {incr r} {
		append raw \x00 [string range $data [expr {$r * $stride}] [expr {$r * $stride + $W * $ch - 1}]]
	}
	set png "\x89PNG\r\n\x1a\n"
	append png [chunk IHDR [binary format IIccccc $W $H 8 [expr {$ch == 4 ? 6 : 2}] 0 0 0]]
	append png [chunk IDAT [zlib compress $raw 1]]
	append png [chunk IEND ""]
	if {[catch {image create photo -data $png -format png} img]} { return "" }
	return $img
}

# How much of §fg a text colour lets through: the colours are §fg mixed into the scrim's (notify::tone).
proc npaint::level {fill} {
	lassign [raster::rgb $fill] r g b
	lassign [raster::rgb $::theme::c(FG)] r1 g1 b1
	lassign [raster::rgb $::theme::c(DESK_BOTTOM)] r2 g2 b2
	set n [expr {($r - $r2) * ($r1 - $r2) + ($g - $g2) * ($g1 - $g2) + ($b - $b2) * ($b1 - $b2)}]
	set d [expr {($r1 - $r2) ** 2 + ($g1 - $g2) ** 2 + ($b1 - $b2) ** 2}]
	expr {$d ? max(0.0, min(1.0, double($n) / $d)) : 1.0}
}

# The text of a layer: {} when it has none, "fail" when the stage cannot be read, else {y0 text shadow halo}
# (photos the stage's width, from row y0). Kept while the layer's text is the same (a hover reads nothing).
proc npaint::text {name c tag clip} {
	variable ink
	variable st
	lassign $st($name) SW SH
	lassign $clip - cy0 - cy1
	set items {}
	set key {}
	foreach it [$c find withtag $tag] {
		if {[$c type $it] ne "text"} continue
		lappend items $it
		lappend key [$c coords $it] [$c itemcget $it -text] [$c itemcget $it -font] [$c itemcget $it -fill] [$c itemcget $it -anchor]
	}
	set old [expr {[info exists ink($name,$tag)] ? $ink($name,$tag) : ""}]
	set y0 0; set y1 0
	if {[llength $items]} {
		lassign [$c bbox {*}$items] - y0 - y1
		# room for the shadow
		set y0 [expr {max(int($cy0), $y0 - 24)}]
		set y1 [expr {min(int($cy1), $y1 + 24)}]
	}
	if {$y1 <= $y0} {
		if {$old ne ""} { catch {image delete {*}[lrange $old 2 end]}; unset ink($name,$tag) }
		return {}
	}
	lappend key $y0 $y1 $::theme::c(FG) $::theme::c(DESK_BOTTOM)
	if {$old ne "" && [lindex $old 0] eq $key} { return [lrange $old 1 end] }
	# the layer's text alone, in grey: each colour's share of §fg
	set states {}
	foreach it [$c find all] { lappend states $it [$c itemcget $it -state]; $c itemconfigure $it -state hidden }
	set fills {}
	foreach it $items {
		set f [$c itemcget $it -fill]
		lappend fills $it $f
		set v [expr {int(round(255 * [level $f]))}]
		$c itemconfigure $it -state normal -fill [format #%02x%02x%02x $v $v $v]
	}
	set rows [grab $name $y0 [expr {$y1 - $y0}]]
	foreach {it f} $fills { $c itemconfigure $it -fill $f }
	foreach {it s} $states { $c itemconfigure $it -state $s }
	if {$rows eq ""} { return fail }
	if {$old ne ""} { catch {image delete {*}[lrange $old 2 end]} }
	# STYLE §19: all text carries 0 1px 2px rgba(0,0,0,.45), 0 0 22px rgba(0,0,0,.4)
	set text [mask $SW $rows [raster::rgb $::theme::c(FG)] 1.0]
	set s1 [mask $SW $rows {0 0 0} 0.45]
	set s2 [mask $SW $rows {0 0 0} 0.4]
	set shadow [image create photo]
	set halo [image create photo]
	rbn::blur $s1 $shadow 1
	rbn::blur $s2 $halo 11
	image delete $s1 $s2
	set ink($name,$tag) [list $key $y0 $text $shadow $halo]
	lrange $ink($name,$tag) 1 end
}

# Copy the part of SRC that falls inside the clip onto O at X Y.
proc npaint::over {o src x y clip} {
	lassign $clip cx0 cy0 cx1 cy1
	set w [image width $src]; set h [image height $src]
	set x0 [expr {max($x, $cx0)}]; set y0 [expr {max($y, $cy0)}]
	set x1 [expr {min($x + $w, $cx1)}]; set y1 [expr {min($y + $h, $cy1)}]
	if {$x1 <= $x0 || $y1 <= $y0} return
	$o copy $src -from [expr {$x0 - $x}] [expr {$y0 - $y}] [expr {$x1 - $x}] [expr {$y1 - $y}] -to $x0 $y0
}

proc npaint::render {name c W H base layers} {
	variable out
	variable ok
	variable st
	lassign $st($name) SW SH
	set plan {}
	foreach l $layers {
		lassign $l tag clip
		if {$clip eq ""} { set clip [list 0 0 $W $H] }
		set clip [lmap v $clip { expr {int($v)} }]
		set t [text $name $c $tag $clip]
		if {$t eq "fail"} {
			set ok 0
			catch {notify::log "the stage cannot be read: notifications are drawn as plain boxes"}
			return ""
		}
		lappend plan $tag $clip $t
	}
	if {![info exists out($name)] || [image width $out($name)] != $W || [image height $out($name)] != $H} {
		if {[info exists out($name)]} { image delete $out($name) }
		set out($name) [image create photo -width $W -height $H]
	}
	set o $out($name)
	$o blank
	foreach {img x y} $base { $o copy $img -to $x $y -compositingrule set }
	foreach {tag clip t} $plan {
		lassign $clip cx0 cy0 cx1 cy1
		foreach it [$c find withtag $tag] {
			switch -- [$c type $it] {
				rectangle {
					lassign [$c coords $it] x0 y0 x1 y1
					set x0 [expr {max($cx0, int(round($x0)))}]; set y0 [expr {max($cy0, int(round($y0)))}]
					set x1 [expr {min($cx1, int(round($x1)))}]; set y1 [expr {min($cy1, int(round($y1)))}]
					set f [$c itemcget $it -fill]
					if {$x1 > $x0 && $y1 > $y0 && $f ne ""} { $o put $f -to $x0 $y0 $x1 $y1 }
				}
				image {
					lassign [$c bbox $it] x0 y0
					over $o [$c itemcget $it -image] $x0 $y0 $clip
				}
			}
		}
		if {[llength $t]} {
			lassign $t y0 text shadow halo
			over $o $halo 0 $y0 $clip
			over $o $shadow 0 [expr {$y0 + 1}] $clip
			over $o $text 0 $y0 $clip
		}
	}
	return $o
}

proc npaint::present {w x y ww wh photo input raise} {
	set g ${ww}x$wh+[expr {int($x)}]+[expr {int($y)}]
	if {[wm geometry $w] ne $g} { wm geometry $w $g }
	# the surface's own canvas stays out of the way: the picture is the window's background
	if {[winfo manager $w.c] ne ""} { place forget $w.c; rbn::forget $w }
	rbnalpha::backdrop $w $photo
	rbnalpha::input $w $input
	if {[wm state $w] ne "normal"} { wm deiconify $w }
	if {$raise} { raise $w }
}

# {r g b alpha} of PHOTO at X Y (Tk 8.6 gives a photo's alpha only through what it does over black and white).
proc npaint::alpha {photo x y} {
	set t [image create photo -width 1 -height 1]
	$t put #000000 -to 0 0 1 1
	$t copy $photo -from $x $y [expr {$x + 1}] [expr {$y + 1}]
	lassign [$t get 0 0] kr kg kb
	$t put #ffffff -to 0 0 1 1
	$t copy $photo -from $x $y [expr {$x + 1}] [expr {$y + 1}]
	lassign [$t get 0 0] wr wg wb
	image delete $t
	set a [expr {255 - ($wg - $kg)}]
	if {$a <= 0} { return {0 0 0 0} }
	list [expr {min(255, $kr * 255 / $a)}] [expr {min(255, $kg * 255 / $a)}] [expr {min(255, $kb * 255 / $a)}] $a
}
