# games.tcl - Steam screenshots by game (Viewer-Final-6-Steam). Steam keeps a game's screenshots in
# <root>/userdata/<account>/760/remote/<appid>/screenshots; the viewer names that folder by its game (the
# appmanifest_<appid>.acf of the root's libraries, read with Settings' VDF reader, settings/games.tcl), and the
# title bar's game button opens the games list: each game with its cover, its screenshots' count and the latest
# one's day, the chosen one marked. Choosing a game shows its folder, newest first. Show in Files opens Files
# on the picture shown.
#
#   steam::where FILE        {root R account U appid A} when FILE is a Steam screenshot, else {}
#   steam::games ROOT ACCOUNT  the account's games: dicts {appid name dir count bytes latest}, latest first
#   steam::items DIR         a game's screenshots, newest first (Steam names them YYYYMMDDhhmmss_N)
#   steam::taken FILE        when a screenshot was taken, from its name; "" when the name does not say
#   steam::day T NOW         the list's day: Today, the weekday within the week, else the date
#   steam::cover ROOT APPID  the game's art in Steam's library cache (the icon, else the header), or ""
# No Tk above "drawing"; the list (gamelist::*) draws on the viewer's ui model.

namespace eval steam {
	# the data folders Steam keeps in HOME: native, the legacy link, the Flatpak's
	variable roots {.local/share/Steam .steam/steam .var/app/com.valvesoftware.Steam/.local/share/Steam}
}

proc steam::where {file} {
	set f [file normalize $file]
	if {![regexp {^(.+)/userdata/(\d+)/760/remote/(\d+)/screenshots/[^/]+$} $f -> root uid appid]} { return {} }
	dict create root $root account $uid appid $appid
}

# The app names of a root: every library's appmanifests (libraryfolders.vdf lists the libraries).
proc steam::names {root} {
	set out [dict create]
	set libs [list $root]
	if {[info commands ::gdetect::steam_libraries] ne ""} { catch {set libs [gdetect::steam_libraries $root]} }
	foreach lib $libs {
		foreach acf [glob -nocomplain [file join $lib steamapps appmanifest_*.acf]] {
			if {[catch {dict get [gdetect::vdf [gdetect::slurp $acf]] AppState} st]} continue
			if {[dict exists $st appid] && [dict exists $st name]} { dict set out [dict get $st appid] [dict get $st name] }
		}
	}
	return $out
}

proc steam::is_shot {name} {
	expr {[string tolower [file extension $name]] in {.jpg .jpeg .png .webp}}
}

# When a screenshot was taken: Steam's name (20261108213104_1.jpg), else the file's time.
proc steam::taken {file} {
	if {[regexp {^(\d{14})_\d+\.} [file tail $file] -> stamp] && ![catch {clock scan $stamp -format %Y%m%d%H%M%S} t]} { return $t }
	if {[catch {file mtime $file} t]} { return "" }
	return $t
}

proc steam::items {dir} {
	set names {}
	foreach p [glob -nocomplain -types f -directory $dir *] {
		if {[steam::is_shot $p]} { lappend names [file tail $p] }
	}
	lmap n [lsort -dictionary -decreasing $names] { file join $dir $n }
}

proc steam::games {root uid} {
	set names [steam::names $root]
	set out {}
	foreach d [glob -nocomplain -types d [file join $root userdata $uid 760 remote * screenshots]] {
		set appid [file tail [file dirname $d]]
		if {![string is digit -strict $appid]} continue
		set items [steam::items $d]
		if {![llength $items]} continue
		set bytes 0
		foreach p $items { catch {incr bytes [file size $p]} }
		set name [expr {[dict exists $names $appid] ? [dict get $names $appid] : $appid}]
		lappend out [dict create appid $appid name $name dir $d count [llength $items] bytes $bytes latest [steam::taken [lindex $items 0]]]
	}
	lsort -command steam::later $out
}
proc steam::later {a b} {
	set d [expr {[dict get $b latest] - [dict get $a latest]}]
	if {$d != 0} { return [expr {$d > 0 ? 1 : -1}] }
	string compare [dict get $a name] [dict get $b name]
}

# "804 screenshots · 4 games · 6.2 GB"
proc steam::summary {games} {
	set n 0; set b 0
	foreach g $games { incr n [dict get $g count]; incr b [dict get $g bytes] }
	set gw [expr {[llength $games] == 1 ? "game" : "games"}]
	set sw [expr {$n == 1 ? "screenshot" : "screenshots"}]
	return "$n $sw · [llength $games] $gw · [steam::bytes $b]"
}

# Sizes as Files gives them: decimal units, one place under 100.
proc steam::bytes {b} {
	foreach {u d} {GB 1e9 MB 1e6 kB 1e3} {
		if {$b >= $d} {
			set v [expr {$b / $d}]
			return "[expr {$v < 100 ? [format %.1f $v] : round($v)}] $u"
		}
	}
	return "$b B"
}

proc steam::day {t now} {
	if {$t eq ""} { return "" }
	set d0 [clock scan [clock format $now -format %Y-%m-%d] -format %Y-%m-%d]
	set d1 [clock scan [clock format $t -format %Y-%m-%d] -format %Y-%m-%d]
	set days [expr {round(($d0 - $d1) / 86400.0)}]
	if {$days == 0} { return Today }
	if {$days > 0 && $days < 8} { return [regsub -all {\s+} [clock format $t -format {%a %e %b}] { }] }
	if {[clock format $t -format %Y] eq [clock format $now -format %Y]} { return [string trim [clock format $t -format {%e %b}]] }
	string trim [clock format $t -format {%e %b %Y}]
}

# The game's art in Steam's library cache: the icon (the old layout's <appid>_icon.jpg, or the hashed .jpg in the
# new layout's <appid>/ folder), else the header or the capsule, which the list crops square.
proc steam::cover {root appid} {
	set lc [file join $root appcache librarycache]
	set f [file join $lc ${appid}_icon.jpg]
	if {[file isfile $f]} { return $f }
	foreach f [glob -nocomplain -types f -directory [file join $lc $appid] *.jpg] {
		if {[regexp {^[0-9a-f]{40}\.jpg$} [file tail $f]]} { return $f }
	}
	foreach f [list [file join $lc $appid header.jpg] [file join $lc ${appid}_header.jpg] \
			[file join $lc $appid library_600x900.jpg] [file join $lc ${appid}_library_600x900.jpg]] {
		if {[file isfile $f]} { return $f }
	}
	return ""
}

# ---- drawing --------------------------------------------------------------------------------------------------

namespace eval gamelist {
	variable open 0
	variable covers        ;# {path size} -> photo
	array set covers {}
	variable top 0         ;# the first row shown when the list is longer than the window
	variable now ""        ;# "now" for the days (a scene's stand-in); the clock when ""
	variable P
	array set P {
		game   {M6 11h4 M8 9v4 M15 12h.01 M18 10h.01 M17.3 5H6.7a4 4 0 0 0-3.96 3.43l-.9 6.3A3 3 0 0 0 4.8 18c.94 0 1.83-.44 2.4-1.2l2.05-2.7a2 2 0 0 1 1.6-.8h3.1a2 2 0 0 1 1.6.8l2.05 2.7a3 3 0 0 0 2.4 1.2a3 3 0 0 0 2.96-3.27l-.9-6.3A4 4 0 0 0 17.3 5z}
		up     {M18 15l-6-6-6 6}
		down   {M6 9l6 6 6-6}
		check  {M20 6L9 17l-5-5}
		folder {M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z}
	}
}

proc gamelist::icon {name size sw colour x y} {
	variable P
	set i [raster::icon $P($name) $size $sw [ui::col $colour] {} 0 0 0]
	$ui::cv create image [expr {round($x)}] [expr {round($y)}] -image $i -anchor nw -tags page
}

# The cover, S px square (cropped from the middle), through ffmpeg into the viewer's cache; "" without one.
proc gamelist::photo {path s} {
	variable covers
	if {$path eq ""} { return "" }
	if {[info exists covers([list $path $s])]} { return $covers([list $path $s]) }
	set p ""
	set out [stage::tmp png]
	if {[auto_execok ffmpeg] ne "" && ![catch {exec ffmpeg -nostdin -v error -y -i $path -frames:v 1 \
			-vf "scale=$s:$s:force_original_aspect_ratio=increase:flags=bicubic,crop=$s:$s" $out </dev/null >/dev/null 2>/dev/null}]} {
		catch {set p [image create photo -file $out]}
	}
	catch {file delete $out}
	set covers([list $path $s]) $p
	return $p
}

# The cover at X Y, S px with R px corners on BG (the corners outside the arc are BG, blended at the edge); a
# §field square with the game icon when there is no art.
proc gamelist::cover {path x y s r bg} {
	set p [gamelist::photo $path $s]
	if {$p eq ""} {
		ui::box $x $y $s $s -fill $ui::c(pill) -radius $r
		gamelist::icon game [expr {round($s * 0.6)}] 1.7 $ui::c(muted) [expr {$x + $s * 0.2}] [expr {$y + $s * 0.2}]
		return
	}
	set x [expr {round($x)}]; set y [expr {round($y)}]
	$ui::img copy $p -to $x $y
	lassign [raster::rgb [ui::col $bg]] br bgg bb
	foreach {cx cy} [list $r $r [expr {$s - $r}] $r $r [expr {$s - $r}] [expr {$s - $r}] [expr {$s - $r}]] {
		set ix0 [expr {$cx < $s / 2 ? 0 : $s - $r}]; set iy0 [expr {$cy < $s / 2 ? 0 : $s - $r}]
		for {set j $iy0} {$j < $iy0 + $r} {incr j} {
			for {set i $ix0} {$i < $ix0 + $r} {incr i} {
				set d [expr {hypot($i + 0.5 - $cx, $j + 0.5 - $cy)}]
				set a [expr {max(0.0, min(1.0, $r - $d + 0.5))}]
				if {$a >= 1.0} continue
				lassign [$ui::img get [expr {$x + $i}] [expr {$y + $j}]] pr pg pb
				$ui::img put [format #%02x%02x%02x [expr {round($pr * $a + $br * (1 - $a))}] \
					[expr {round($pg * $a + $bgg * (1 - $a))}] [expr {round($pb * $a + $bb * (1 - $a))}]] -to [expr {$x + $i}] [expr {$y + $j}]
			}
		}
	}
}

# The title bar's game button at x 16: 34 tall, §field, radius 9, the 22 px cover, the name 14/600, the chevron
# (up while the list is open). Returns its right edge.
proc gamelist::button {name cover} {
	variable open
	set y [expr {($zoom::TB - 34) / 2}]
	set w [expr {6 + 22 + 8 + [bar::width i14s $name] + 8 + 14 + 10}]
	ui::box 16 $y $w 34 -fill $ui::c(field) -radius 9
	gamelist::cover $cover 22 [expr {$y + 6}] 22 6 $ui::c(field)
	bar::text 52 $y 34 $name i14s $ui::c(fg)
	gamelist::icon [expr {$open ? "up" : "down"}] 14 2.2 $ui::c(fg) [expr {16 + $w - 10 - 14}] [expr {$y + 10}]
	ui::hit 16 $y $w 34 gamelist::toggle
	return [expr {16 + $w}]
}

proc gamelist::toggle {args} {
	variable open; variable top
	set open [expr {!$open}]
	set top 0
	viewer::draw
}

# The games list (the bar panel's anatomy, 400 wide, radius 12, under the game button at 16, 58): the head (the
# tile, "Steam screenshots", the summary), the rows (44 tall; the chosen one §field with the accent check) and the
# foot with Show in Files. Rows past the window's foot scroll with the wheel.
proc gamelist::draw {games root cur} {
	variable top
	array set c [array get ui::c]
	set x 16; set y [expr {$zoom::TB - 10}]; set w 400
	set fits [expr {max(1, ($zoom::WH - 20 - $y - 64 - 20 - 60 - 20) / 46)}]
	set n [llength $games]
	set shown [expr {min($n, $fits)}]
	set top [expr {max(0, min($top, $n - $shown))}]
	set h [expr {20 + 44 + 18 + 10 + $shown * 44 + ($shown - 1) * 2 + 10 + 60}]
	# a click outside closes the list
	ui::hit 0 0 $zoom::WW $zoom::WH gamelist::toggle
	ui::layer
	ui::box $x $y $w $h -fill $c(bar) -radius 12 -ring [list $c(border) 1]
	ui::hit $x $y $w $h viewer::noop
	# the head
	ui::box [expr {$x + 20}] [expr {$y + 20}] 44 44 -fill $c(pill) -radius 12 -ring [list $c(border) 1]
	gamelist::icon game 22 1.7 $c(fg) [expr {$x + 31}] [expr {$y + 31}]
	ui::text [expr {$x + 78}] [expr {$y + 19}] "Steam screenshots" sg20 $c(fg) w -0.4
	ui::text [expr {$x + 78}] [expr {$y + 47}] [steam::summary $games] i13 $c(muted)
	set ry [expr {$y + 20 + 44 + 18}]
	ui::box [expr {$x + 20}] $ry 360 1 -fill $c(border)
	incr ry 10
	set now [expr {$::gamelist::now eq "" ? [clock seconds] : $::gamelist::now}]
	foreach g [lrange $games $top [expr {$top + $shown - 1}]] {
		set on [expr {[dict get $g appid] eq $cur}]
		set bg [expr {$on ? $c(field) : $c(bar)}]
		if {$on} { ui::box [expr {$x + 12}] $ry 376 44 -fill $c(field) -radius 8 }
		gamelist::cover [steam::cover $root [dict get $g appid]] [expr {$x + 20}] [expr {$ry + 8}] 28 7 $bg
		set f [expr {$on ? "i13s" : "i13m"}]
		set nx [expr {$x + 60}]
		set dayx [expr {$x + 351}]
		set day [steam::day [dict get $g latest] $now]
		set cnt [dict get $g count]
		# the name gives way (ellipsis) before the count and the day
		set room [expr {$dayx - [bar::width i13 $day] - 16 - $nx - 12 - [bar::width i13 $cnt]}]
		set name [gamelist::fit [dict get $g name] $f $room]
		bar::text $nx $ry 44 $name $f $c(fg)
		bar::text [expr {$nx + [bar::width $f $name] + 12}] $ry 44 $cnt i13 $c(muted)
		bar::text $dayx $ry 44 $day i13 $c(muted) e
		if {$on} { gamelist::icon check 15 2.4 $c(accent) [expr {$x + 363}] [expr {$ry + 14.5}] }
		ui::hit [expr {$x + 12}] $ry 376 44 [list gamelist::choose [dict get $g dir]]
		incr ry 46
	}
	if {$n > $shown} { ui::wheel $x $y $w $h gamelist::scroll }
	set fy [expr {$y + $h - 60}]
	ui::box $x $fy $w 1 -fill $c(border)
	# Show in Files: a compact ghost button (34 tall, radius 9, padding 14, the 13 px icon 7 after the label)
	set bw [expr {14 + [bar::width i13m "Show in Files"] + 7 + 13 + 14}]
	set bx [expr {$x + $w - 20 - $bw}]
	set by [expr {$fy + 13}]
	ui::box $bx $by $bw 34 -fill $c(bar) -radius 9 -ring [list $c(border) 1]
	bar::text [expr {$bx + 14}] $by 34 "Show in Files" i13m $c(fg)
	gamelist::icon folder 13 2 $c(fg) [expr {$bx + $bw - 14 - 13}] [expr {$by + 10.5}]
	ui::hit $bx $by $bw 34 viewer::show_in_files
}

proc gamelist::scroll {d} {
	variable top
	set top [expr {max(0, $top + ($d > 0 ? 1 : -1))}]
	viewer::draw
}

proc gamelist::fit {s f room} {
	if {[bar::width $f $s] <= $room} { return $s }
	while {[string length $s] > 1 && [bar::width $f "$s…"] > $room} { set s [string range $s 0 end-1] }
	return "[string trimright $s]…"
}

proc gamelist::choose {dir args} {
	variable open
	set open 0
	viewer::open_items [steam::items $dir] 0
}

# The list's title, 20/600 Space Grotesk (the bar panels' head), and the menu's keys, 11 px (Files' menu rows):
# two sizes the ui model's fonts did not have
namespace eval ::ui {}
set ::ui::fonts(sg20) {{Ribbon Space Grotesk 600} 20 0.984 0.292}
set ::ui::fonts(i11) {{Ribbon Inter 400} 11 0.96875 0.2412}
