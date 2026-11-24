# hud-art.tcl - the game's art for the HUD's header (HUD-Default: a 20 px rounded square beside the name). No Tk.
#
#   hud::art::for_key KEY            the launcher's picture for a game key (hud-games.tcl's keys), "" for none:
#       steam:APPID   the Steam client's library cache (appcache/librarycache under ~/.local/share/Steam or
#                     ~/.steam/steam): APPID_icon.jpg, else the icon of the newer per-app folder (APPID/<sha1>.jpg),
#                     else the header (APPID_header.jpg, APPID/header.jpg)
#       lutris:SLUG   Lutris's icon (~/.local/share/icons/hicolor/128x128/apps/lutris_SLUG.png, else
#                     ~/.local/share/lutris/icons/SLUG.png)
#       any key       else the art Settings → Game overlay knows for it (hud::store::art: a game added by hand, the
#                     launchers' covers)
#   hud::art::png SRC PX RADIUS RING the picture as a PX x PX PNG, centre-cropped to a square, with the board's rounded
#                     corners (RADIUS px, transparent outside) and its inset ring (RING px of white at 8 %), ready for
#                     the Tk canvas and the overlay helper alike. "" until it is made: ffmpeg makes it in the background
#                     (Steam's art is JPEG, which Tk cannot read) and the done command (configure -done) runs then.
#                     Made once per picture and size, in the cache folder; a picture ffmpeg cannot read stays ""
#   hud::art::configure -cache DIR -home DIR -done CMD -ffmpeg CMD
#
# The home is RIBBON_GAMES_HOME, else HOME (as hud-store.tcl's).

namespace eval ::hud::art {
	variable cache ""
	variable home ""
	variable done_cmd ""
	variable ffmpeg ffmpeg
	variable made {}          ;# name -> path or "" (failed)
	variable running {}       ;# name -> channel
	variable steam_roots {.local/share/Steam .steam/steam}
}

proc ::hud::art::configure {args} {
	foreach {k v} $args {
		switch -- $k {
			-cache { variable cache; variable made; set cache $v; set made {} }
			-home { variable home; set home $v }
			-done { variable done_cmd; set done_cmd $v }
			-ffmpeg { variable ffmpeg; set ffmpeg $v }
			default { error "hud::art::configure: unknown option $k" }
		}
	}
}

proc ::hud::art::home {} {
	variable home
	if {$home ne ""} { return $home }
	if {[info exists ::env(RIBBON_GAMES_HOME)]} { return $::env(RIBBON_GAMES_HOME) }
	if {[info exists ::env(HOME)]} { return $::env(HOME) }
	return /
}

# the first of PATHS that is a non-empty file, or ""
proc ::hud::art::first {paths} {
	foreach p $paths {
		if {[file isfile $p] && [file size $p] > 0} { return $p }
	}
	return ""
}

proc ::hud::art::for_key {key} {
	variable steam_roots
	set h [home]
	set found ""
	if {[regexp {^steam:([0-9]+)$} $key -> id]} {
		foreach r $steam_roots {
			set lc [file join $h $r appcache librarycache]
			if {![file isdirectory $lc]} continue
			set icon [lsort [glob -nocomplain -types f -directory [file join $lc $id] {[0-9a-f]*.jpg}]]
			set icon [lsearch -all -inline -regexp $icon {/[0-9a-f]{40}\.jpg$}]
			set found [first [list [file join $lc ${id}_icon.jpg] {*}$icon [file join $lc ${id}_header.jpg] [file join $lc $id header.jpg]]]
			if {$found ne ""} break
		}
	} elseif {[regexp {^lutris:(.+)$} $key -> slug]} {
		set found [first [list [file join $h .local share icons hicolor 128x128 apps lutris_$slug.png] \
			[file join $h .local share lutris icons $slug.png]]]
	}
	if {$found eq "" && $key ne "" && [llength [info commands ::hud::store::art]]} {
		set a [::hud::store::art $key]
		if {$a ne "" && [file isfile $a]} { set found $a }
	}
	return $found
}

# the ffmpeg filter: a centred square at PX, the rounded corners as alpha and the inset ring blended in
proc ::hud::art::filter {px r ring} {
	# e: how far inside the rounded square a pixel's centre is (capped at R); the corners' alpha is its coverage
	set e "($r-hypot(X+0.5-clip(X+0.5,$r,W-$r),Y+0.5-clip(Y+0.5,$r,H-$r)))"
	set k "0.08*clip($ring+0.5-$e,0,1)"
	set g {}
	foreach c {r g b} { lappend g "$c='${c}(X,Y)+(255-${c}(X,Y))*$k'" }
	lappend g "a='alpha(X,Y)*clip($e+0.5,0,1)'"
	return "crop='min(iw,ih)':'min(iw,ih)',scale=$px:$px:flags=lanczos,format=rgba,geq=[join $g :]"
}

proc ::hud::art::png {src px r ring} {
	variable cache
	variable made
	variable running
	variable ffmpeg
	if {$src eq "" || $cache eq "" || ![string is integer -strict $px] || $px < 1} { return "" }
	if {[catch {file stat $src st}]} { return "" }
	set r [::format %g [expr {min($r, $px / 2.0)}]]
	set name [format %08x [zlib crc32 "$src|$st(mtime)|$st(size)|$px|$r|$ring"]]
	if {[dict exists $made $name]} { return [dict get $made $name] }
	set out [file join $cache art $name.png]
	if {[file isfile $out] && [file size $out] > 0} {
		dict set made $name $out
		return $out
	}
	if {[dict exists $running $name]} { return "" }
	if {[auto_execok [lindex $ffmpeg 0]] eq ""} { dict set made $name ""; return "" }
	file mkdir [file join $cache art]
	set tmp $out.part.png
	set cmd [concat $ffmpeg [list -nostdin -v error -y -i $src -frames:v 1 -vf [filter $px $r $ring] $tmp 2>@1]]
	if {[catch {::open |$cmd r} ch]} { dict set made $name ""; return "" }
	fconfigure $ch -blocking 0
	dict set running $name $ch
	fileevent $ch readable [list ::hud::art::finished $name $ch $tmp $out]
	return ""
}

proc ::hud::art::finished {name ch tmp out} {
	variable made
	variable running
	variable done_cmd
	::read $ch
	if {![eof $ch]} return
	fconfigure $ch -blocking 1
	set failed [catch {::close $ch}]
	dict unset running $name
	if {!$failed && [file isfile $tmp] && [file size $tmp] > 0} {
		file rename -force $tmp $out
		dict set made $name $out
	} else {
		catch {file delete $tmp}
		dict set made $name ""
	}
	if {$done_cmd ne ""} { catch {uplevel #0 $done_cmd} }
}

# wait (with the event loop) until no picture is being made, at most MS milliseconds (tests)
proc ::hud::art::settle {{ms 5000}} {
	variable running
	set end [expr {[clock milliseconds] + $ms}]
	while {[dict size $running] && [clock milliseconds] < $end} {
		after 20 [list set ::hud::art::tick 1]
		vwait ::hud::art::tick
	}
	expr {[dict size $running] == 0}
}
