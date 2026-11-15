# tray.tcl - apps' tray icons in the right bar: a StatusNotifierHost (the freedesktop StatusNotifierItem spec, as
# Steam, Discord, Lutris and every libappindicator, Electron or Qt app speaks it), the icons it draws, and the
# app's menu (com.canonical.dbusmenu) as the right bar's panel. Boards Tray-1-Icons, Tray-2-Menu, Tray-3-Submenu
# and Tray-4-Fallback (design/tools/gen_tray.py). The watcher the apps register with is sniwatch.tcl; mod-tray.tcl starts both.
#
#   tray::start BUS ?-onchange CMD?   be a host: register with the watcher (now, and whenever one appears),
#                                     read its items and follow them; CMD runs when what the bar shows changes
#   tray::keys                        the items the bar shows, in the order they came (Passive ones are left out)
#   tray::prop KEY NAME ?DEF?         an item's property (Id, Title, Status, IconName, Menu, ItemIsMenu, ...)
#   tray::width                       the bar's room for them: 30 per icon, 4 between; 0 with none
#   tray::draw CANVAS X               bar.tcl: draws the slots from X (y 12, 30 tall) and puts their hits down
#   tray::press KEY B                 a click on an icon (B: 1 left, 2 middle, 3 right, 4 and 5 scroll)
#   tray::menu_draw                   controls.tcl's panel::draw, while panel::open is "sni"
#
# Clicks: left is the app's Activate (it shows its window); an app that says its icon is only a menu
# (ItemIsMenu), or that has no Activate (libappindicator answers UnknownMethod), opens its menu instead. Right
# opens the menu (or asks the app for its own, ContextMenu, when it has no dbusmenu). Middle is SecondaryActivate;
# the wheel is Scroll.
#
# Pictures: IconPixmap (ARGB32 in network order, several sizes) or IconName (a PNG file in IconThemePath, the
# hicolor theme or pixmaps; a picture that cannot be read, an SVG-only name or none at all is the bar's box glyph,
# Tray-4-Fallback). The bar's glyphs are one colour, so a
# picture is turned grey and laid between §bar (its dark parts) and §muted (its light parts): §fg when lit, the
# accent while the app asks for attention (Status NeedsAttention, its AttentionIcon when it has one).

namespace eval tray {
	variable bus ""
	variable onchange ""
	variable hostname ""
	variable watcher org.kde.StatusNotifierWatcher
	variable iface org.kde.StatusNotifierItem
	variable items {}          ;# the keys ("SERVICE/PATH", as the watcher has them), in the order they came
	variable it                ;# KEY,svc KEY,path KEY,props KEY,ready KEY,listen KEY,src KEY,img,COLOUR
	array set it {}
	variable hover ""          ;# the icon under the pointer
	variable placed {}         ;# {KEY x} from the last draw, in the bar's canvas
	variable menu {}           ;# the open menu: key svc path rows sel listen (empty: none)
	variable size 16           ;# the icon's size in the slot
}

# ---- the host ------------------------------------------------------------------------------------------------

proc tray::start {b args} {
	variable bus $b
	variable onchange
	variable hostname
	variable watcher
	set o [dict merge {-onchange ""} $args]
	set onchange [dict get $o -onchange]
	set hostname org.kde.StatusNotifierHost-[pid]
	$bus request $hostname -command tray::ignore
	$bus listen -sender $watcher -path /StatusNotifierWatcher -interface $watcher -member StatusNotifierItemRegistered \
		-command tray::ignore tray::registered
	$bus listen -sender $watcher -path /StatusNotifierWatcher -interface $watcher -member StatusNotifierItemUnregistered \
		-command tray::ignore tray::unregistered
	# a watcher that comes (ours after a restart, or another desktop's) is told about us again; an app that goes
	# takes its icon even when the watcher is slow to say so
	$bus listen -sender org.freedesktop.DBus -interface org.freedesktop.DBus -member NameOwnerChanged \
		-command tray::ignore tray::owner_changed
	watcher_up
}
proc tray::ignore {args} {}

proc tray::watcher_up {} {
	variable bus
	variable hostname
	variable watcher
	$bus call -command tray::ignore $watcher /StatusNotifierWatcher $watcher RegisterStatusNotifierHost s $hostname
	$bus call -command tray::got_items $watcher /StatusNotifierWatcher org.freedesktop.DBus.Properties Get ss \
		$watcher RegisteredStatusNotifierItems
}

proc tray::got_items {status values} {
	variable items
	if {$status ne "ok"} return
	set now [ribbon::dbus::strip v [lindex $values 0]]
	foreach k $items { if {$k ni $now} { remove $k } }
	foreach k $now { add $k }
}

proc tray::registered {msg id} { add $id }
proc tray::unregistered {msg id} { remove $id }

proc tray::owner_changed {msg name old new} {
	variable watcher
	variable items
	variable it
	if {$name eq $watcher} {
		if {$new ne ""} { watcher_up }
		return
	}
	if {$new ne ""} return
	foreach k $items { if {$it($k,svc) eq $name || $it($k,owner) eq $name} { remove $k } }
}

# An item: "SERVICE/PATH", or a bare bus name (its object is /StatusNotifierItem).
proc tray::add {key} {
	variable bus
	variable items
	variable it
	variable iface
	if {$key in $items} return
	set i [string first / $key]
	if {$i < 0} { set svc $key; set path /StatusNotifierItem } else {
		set svc [string range $key 0 [expr {$i - 1}]]; set path [string range $key $i end]
	}
	# what another watcher passes on unchecked: a key that names no object is left out
	if {$svc eq "" || ![regexp {^/([A-Za-z0-9_]+(/[A-Za-z0-9_]+)*)?$} $path]
		|| ![regexp {^(:[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+|[A-Za-z_-][A-Za-z0-9_-]*(\.[A-Za-z_-][A-Za-z0-9_-]*)+)$} $svc]} return
	lappend items $key
	array set it [list $key,svc $svc $key,path $path $key,props {} $key,ready 0 $key,owner $svc $key,src "" $key,again ""]
	set it($key,listen) [$bus listen -sender $svc -path $path -interface $iface -command tray::ignore [list tray::signal $key]]
	fetch $key
}

proc tray::remove {key} {
	variable bus
	variable items
	variable it
	variable menu
	variable hover
	if {$key ni $items} return
	set items [lsearch -all -inline -exact -not $items $key]
	catch {$bus unlisten $it($key,listen)}
	after cancel $it($key,again)
	forget_pictures $key
	array unset it $key,*
	if {$hover eq $key} { set hover "" }
	if {[dict exists $menu key] && [dict get $menu key] eq $key} { menu_close }
	changed
}

proc tray::fetch {key} {
	variable bus
	variable it
	variable iface
	$bus call -command [list tray::got_props $key] $it($key,svc) $it($key,path) org.freedesktop.DBus.Properties GetAll s $iface
}

proc tray::got_props {key status values} {
	variable it
	if {![info exists it($key,svc)]} return
	if {$status ne "ok"} return
	set it($key,props) [ribbon::dbus::strip a{sv} [lindex $values 0]]
	set it($key,ready) 1
	forget_pictures $key
	changed
}

# The item's signals: NewIcon, NewTitle, NewStatus, NewToolTip, NewMenu ... Each says "read me again"; a burst
# is read once.
proc tray::signal {key msg args} {
	variable it
	if {![info exists it($key,svc)]} return
	if {[dict get $msg member] eq "NewStatus" && [llength $args]} {
		dict set it($key,props) Status [lindex $args 0]
		changed
	}
	after cancel $it($key,again)
	set it($key,again) [after 40 [list tray::fetch $key]]
}

proc tray::prop {key name {def ""}} {
	variable it
	if {[info exists it($key,props)] && [dict exists $it($key,props) $name]} { return [dict get $it($key,props) $name] }
	return $def
}

proc tray::keys {} {
	variable items
	variable it
	lmap k $items { if {$it($k,ready) && [prop $k Status Active] ne "Passive"} { set k } else continue }
}

# The app's name, for its tooltip: its title, else what its tooltip calls it, else its id.
proc tray::name {key} {
	set t [string trim [prop $key Title]]
	if {$t eq ""} { set t [string trim [lindex [prop $key ToolTip] 2]] }
	if {$t eq ""} { set t [prop $key Id] }
	return $t
}

proc tray::changed {} {
	variable onchange
	if {$onchange eq ""} return
	after cancel $onchange
	after idle $onchange
}

# ---- clicks ------------------------------------------------------------------------------------------------

# Where the app may put something of its own (its menu, a window): under the slot, in screen pixels.
proc tray::spot {key} {
	variable placed
	set i [lsearch -index 0 $placed $key]
	set x [expr {$i < 0 ? 0 : [lindex $placed $i 1]}]
	set X0 [expr {[info exists ::bar::X0] ? $::bar::X0 : 0}]
	set Y0 [expr {[info exists ::bar::Y0] ? $::bar::Y0 : 0}]
	list [expr {int($X0 + $x + 15)}] [expr {int($Y0 + 46)}]
}

proc tray::press {key b} {
	variable bus
	variable it
	variable iface
	variable menu
	if {![info exists it($key,svc)]} return
	lassign [spot $key] x y
	set call [list $bus call -command tray::ignore $it($key,svc) $it($key,path) $iface]
	switch -- $b {
		1 {
			if {[menu_of $key]} { menu_close; return }
			if {[prop $key ItemIsMenu 0]} { menu_open $key $x $y; return }
			$bus call -command [list tray::activated $key $x $y] $it($key,svc) $it($key,path) $iface Activate ii $x $y
		}
		2 { {*}$call SecondaryActivate ii $x $y }
		3 { if {[menu_of $key]} { menu_close } else { menu_open $key $x $y } }
		4 - 5 { {*}$call Scroll is [expr {$b == 4 ? -120 : 120}] vertical }
	}
}

# Activate failed: the app has no window to show (libappindicator has no Activate), so its menu is what it offers.
proc tray::activated {key x y status values} {
	if {$status eq "ok"} return
	menu_open $key $x $y
}

# ---- the menu (com.canonical.dbusmenu) ------------------------------------------------------------------

proc tray::menu_of {key} {
	variable menu
	expr {[dict exists $menu key] && [dict get $menu key] eq $key && [info exists ::panel::open] && $::panel::open eq "sni"}
}

proc tray::menu_open {key x y} {
	variable bus
	variable it
	variable iface
	set mpath [prop $key Menu]
	if {$mpath eq "" || $mpath eq "/"} {
		# no dbusmenu: the app shows its own
		$bus call -command tray::ignore $it($key,svc) $it($key,path) $iface ContextMenu ii $x $y
		return
	}
	set svc $it($key,svc)
	$bus call -command tray::ignore $svc $mpath com.canonical.dbusmenu AboutToShow i 0
	$bus call -command [list tray::got_layout $key $svc $mpath 1] $svc $mpath com.canonical.dbusmenu GetLayout iias 0 -1 {}
}

proc tray::got_layout {key svc mpath first status values} {
	variable bus
	variable menu
	if {$status ne "ok"} return
	if {!$first && ![menu_of $key]} return
	set rows [rows [lindex $values 1]]
	if {![llength $rows]} return
	if {$first} {
		menu_close
		set l [$bus listen -sender $svc -path $mpath -interface com.canonical.dbusmenu -command tray::ignore [list tray::menu_signal $key]]
		set menu [dict create key $key svc $svc path $mpath rows $rows sel -1 listen $l]
		$bus call -command tray::ignore $svc $mpath com.canonical.dbusmenu Event isvu 0 opened {i 0} [clock seconds]
		if {[info commands ::panel::show] ne ""} {
			# panel::show closes nothing: what was open goes first (the launcher, another panel)
			if {[info exists ::panel::open] && $::panel::open ne ""} { panel::close }
			catch {launcher::cancel}
			panel::show sni
		}
	} else {
		dict set menu rows $rows
		if {[info commands ::panel::draw] ne ""} { panel::draw }
	}
	changed
}

# The app changed its menu while it is open: read it again.
proc tray::menu_signal {key msg args} {
	variable menu
	if {![menu_of $key]} return
	after cancel tray::menu_reload
	after 40 tray::menu_reload
}
proc tray::menu_reload {} {
	variable bus
	variable menu
	if {![dict exists $menu key]} return
	dict with menu {
		$bus call -command [list tray::got_layout $key $svc $path 0] $svc $path com.canonical.dbusmenu GetLayout iias 0 -1 {}
	}
}

# The layout (ia{sv}av) as the panel's rows: {item ID LABEL ENABLED CHECK} {sep} {label TEXT}. Hidden items are
# left out, separators at either end or twice in a row too; a submenu's items follow its name as a section label
# between rules, a submenu's submenu too (Tray-3-Submenu); CHECK: a checkmark or radio item that is on.
proc tray::rows {node {depth 0}} {
	set out {}
	foreach ch [lindex $node 2] {
		if {[llength $ch] == 2 && [string index [lindex $ch 0] 0] eq "("} { set ch [lindex $ch 1] }
		lassign $ch id props kids
		set p [ribbon::dbus::strip a{sv} $props]
		if {[dict exists $p visible] && ![dict get $p visible]} continue
		set type [expr {[dict exists $p type] ? [dict get $p type] : "standard"}]
		if {$type eq "separator"} { lappend out sep; continue }
		set label [expr {[dict exists $p label] ? [mnemonic [dict get $p label]] : ""}]
		set enabled [expr {[dict exists $p enabled] ? [dict get $p enabled] : 1}]
		set check [expr {[dict exists $p toggle-type] && [dict get $p toggle-type] in {checkmark radio}
			&& [dict exists $p toggle-state] && [dict get $p toggle-state] == 1}]
		set sub [expr {([dict exists $p children-display] && [dict get $p children-display] eq "submenu") || [llength $kids]}]
		if {$sub} {
			# a submenu (at any depth) is a section: its name, then its items (board Tray-3-Submenu)
			lappend out sep [list label $label] {*}[rows $ch [expr {$depth + 1}]] sep
		} else {
			lappend out [list item $id $label $enabled $check]
		}
	}
	if {$depth} { return $out }
	# separators only between rows
	set clean {}
	foreach r $out {
		if {$r eq "sep" && ([llength $clean] == 0 || [lindex $clean end] eq "sep" || [lindex $clean end 0] eq "label")} continue
		lappend clean $r
	}
	while {[llength $clean] && [lindex $clean end] eq "sep"} { set clean [lrange $clean 0 end-1] }
	return $clean
}

# "_Quit" -> "Quit"; "__" is a real underscore.
proc tray::mnemonic {s} { string map {__ _ _ ""} $s }

proc tray::menu_pick {id} {
	variable bus
	variable menu
	if {![dict exists $menu key]} return
	$bus call -command tray::ignore [dict get $menu svc] [dict get $menu path] com.canonical.dbusmenu Event isvu $id clicked {i 0} [clock seconds]
	if {[info commands ::panel::close] ne ""} { panel::close } else { menu_close }
}

# The menu is gone (picked, clicked away, panel::close): the app is told, as hosts do.
proc tray::menu_close {} {
	variable bus
	variable menu
	if {![dict exists $menu key]} return
	set m $menu
	set menu {}
	catch {$bus unlisten [dict get $m listen]}
	catch {$bus call -command tray::ignore [dict get $m svc] [dict get $m path] com.canonical.dbusmenu Event isvu 0 closed {i 0} [clock seconds]}
	if {[info exists ::panel::open] && $::panel::open eq "sni"} { panel::close }
	changed
}
# panel::open moved off "sni" (another panel, a click away, Escape): the menu is closed.
proc tray::panel_moved {args} {
	variable menu
	if {[dict exists $menu key] && $::panel::open ne "sni"} { menu_close }
}

# ---- pictures ----------------------------------------------------------------------------------------------

proc tray::forget_pictures {key} {
	variable it
	foreach n [array names it $key,img,*] { catch {image delete $it($n)}; unset it($n) }
	set it($key,src) ""
}

# The item's picture as 16 x 16 RGBA bytes (attention picture while it asks for attention), "" if none.
proc tray::picture_src {key} {
	variable it
	variable size
	if {$it($key,src) ne ""} { return $it($key,src) }
	set att [expr {[prop $key Status] eq "NeedsAttention"}]
	set src ""
	foreach pre [expr {$att ? {Attention ""} : {""}}] {
		set pix [pick_pixmap [prop $key ${pre}IconPixmap] $size]
		if {$pix ne ""} { lassign $pix w h data; set src [fit [argb_to_rgba $data] $w $h $size]; break }
		set file [find_icon [prop $key ${pre}IconName] [prop $key IconThemePath] $size]
		if {$file ne "" && ![catch {png_decode [readfile $file]} img]} { lassign $img w h data; set src [fit $data $w $h $size]; break }
	}
	set it($key,src) [expr {$src eq "" ? "none" : $src}]
}

# The best of IconPixmap's sizes for SIZE: the smallest at least that big, else the biggest.
proc tray::pick_pixmap {list size} {
	set best ""; set bw 0
	foreach p $list {
		lassign $p w h data
		# past 1024 px a side is not an icon (as png_decode): its pixels would hold the shell up and its memory
		if {$w <= 0 || $h <= 0 || $w > 1024 || $h > 1024 || [string length $data] < $w * $h * 4} continue
		if {$best eq "" || ($bw < $size && $w > $bw) || ($w >= $size && $w < $bw)} { set best [list $w $h $data]; set bw $w }
	}
	return $best
}

proc tray::argb_to_rgba {data} {
	binary scan $data cu* v
	set out {}
	foreach {a r g b} $v { lappend out $r $g $b $a }
	binary format cu* $out
}

proc tray::readfile {f} { set fh [::open $f rb]; set d [::read $fh]; ::close $fh; return $d }

# A PNG file for an icon name: the name as a path, IconThemePath, then the hicolor theme and pixmaps in the XDG
# data dirs; of the sizes there, the smallest at least SIZE.
proc tray::find_icon {name themepath size} {
	if {$name eq ""} { return "" }
	if {[string index $name 0] eq "/"} { return [expr {[file readable $name] && [string match -nocase *.png $name] ? $name : ""}] }
	set roots {}
	if {$themepath ne ""} { lappend roots $themepath }
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/"}]
	set dh [expr {[info exists ::env(XDG_DATA_HOME)] && $::env(XDG_DATA_HOME) ne "" ? $::env(XDG_DATA_HOME) : "$home/.local/share"}]
	set dd [expr {[info exists ::env(XDG_DATA_DIRS)] && $::env(XDG_DATA_DIRS) ne "" ? $::env(XDG_DATA_DIRS) : "/usr/local/share:/usr/share"}]
	foreach d [list $dh {*}[split $dd :]] { lappend roots $d/icons }
	set best ""; set bs 0
	foreach r $roots {
		set found [glob -nocomplain -types f -- $r/$name.png $r/hicolor/*/*/$name.png $r/*/*/$name.png]
		foreach f $found {
			set s [expr {[regexp {/(\d+)x\d+(@\d+)?/} $f -> n] ? $n : 0}]
			if {$s == 0 && ![catch {png_size $f} wh]} { set s [lindex $wh 0] }
			if {$best eq "" || ($bs < $size && $s > $bs) || ($s >= $size && $s < $bs)} { set best $f; set bs $s }
		}
		if {$best ne ""} { return $best }
	}
	foreach d [list $dh {*}[split $dd :]] { if {[file readable $d/pixmaps/$name.png]} { return $d/pixmaps/$name.png } }
	return ""
}

proc tray::png_size {f} {
	set fh [::open $f rb]; set head [::read $fh 24]; ::close $fh
	if {[string range $head 0 7] ne "\x89PNG\r\n\x1a\n" || [binary scan $head @16II w h] != 2} { error "not a PNG" }
	list $w $h
}

# A PNG (8 or 16 bits, grey, RGB, palette, grey + alpha or RGBA; not interlaced) as {w h RGBA-bytes}.
proc tray::png_decode {d} {
	if {[string range $d 0 7] ne "\x89PNG\r\n\x1a\n"} { error "not a PNG" }
	set at 8; set idat ""; set plte ""; set trns ""
	while {$at + 8 <= [string length $d]} {
		binary scan $d @${at}Iua4 len type
		set body [string range $d [expr {$at + 8}] [expr {$at + 7 + $len}]]
		switch $type {
			IHDR { binary scan $body IIcucucucucu w h depth ctype comp filt lace }
			PLTE { set plte $body }
			tRNS { set trns $body }
			IDAT { append idat $body }
		}
		set at [expr {$at + 12 + $len}]
		if {$type eq "IEND"} break
	}
	if {$lace || $depth ni {8 16} || $ctype ni {0 2 3 4 6} || ($ctype == 3 && $depth != 8)} { error "unsupported PNG" }
	set ch [dict get {0 1 2 3 3 1 4 2 6 4} $ctype]
	set bpp [expr {$ch * $depth / 8}]
	# an icon: a picture past 1024 px a side is not one (and would hold the shell up for minutes)
	if {$w < 1 || $h < 1 || $w > 1024 || $h > 1024} { error "unsupported PNG size $w x $h" }
	set stride [expr {$w * $bpp}]
	# no more than the rows need is inflated: a few KB of IDAT can say gigabytes (and hold the shell's memory)
	set need [expr {$h * ($stride + 1)}]
	set z [zlib stream decompress]
	if {[catch {$z put $idat; set rows [$z get $need]} err]} { $z close; error "a damaged PNG: $err" }
	$z close
	binary scan $rows cu* raw
	if {[llength $raw] < $need} { error "a damaged PNG: too few rows" }
	set prev [lrepeat $stride 0]
	set px {}
	set i 0
	for {set y 0} {$y < $h} {incr y} {
		set f [lindex $raw $i]; incr i
		set line [lrange $raw $i [expr {$i + $stride - 1}]]; incr i $stride
		set cur {}
		for {set x 0} {$x < $stride} {incr x} {
			set v [lindex $line $x]
			set a [expr {$x >= $bpp ? [lindex $cur [expr {$x - $bpp}]] : 0}]
			set b [lindex $prev $x]
			switch $f {
				1 { set v [expr {($v + $a) & 255}] }
				2 { set v [expr {($v + $b) & 255}] }
				3 { set v [expr {($v + ($a + $b) / 2) & 255}] }
				4 {
					set c [expr {$x >= $bpp ? [lindex $prev [expr {$x - $bpp}]] : 0}]
					set p [expr {$a + $b - $c}]
					set pa [expr {abs($p - $a)}]; set pb [expr {abs($p - $b)}]; set pc [expr {abs($p - $c)}]
					set v [expr {($v + ($pa <= $pb && $pa <= $pc ? $a : ($pb <= $pc ? $b : $c))) & 255}]
				}
			}
			lappend cur $v
		}
		set prev $cur
		# to RGBA, 8 bits
		if {$depth == 16} { set cur [lmap {hi lo} $cur {set hi}] }
		switch $ctype {
			0 { foreach g $cur { lappend px $g $g $g 255 } }
			2 { foreach {r g b} $cur { lappend px $r $g $b 255 } }
			3 {
				foreach k $cur {
					binary scan $plte @[expr {$k * 3}]cucucu r g b
					set a 255
					if {$k < [string length $trns]} { binary scan $trns @${k}cu a }
					lappend px $r $g $b $a
				}
			}
			4 { foreach {g a} $cur { lappend px $g $g $g $a } }
			6 { lappend px {*}$cur }
		}
	}
	list $w $h [binary format cu* $px]
}

# RGBA bytes W x H fitted into SIZE x SIZE (aspect kept, centred), each pixel the area-weighted mean of what it
# covers (premultiplied, so see-through pixels do not darken the edges).
proc tray::fit {data w h size} {
	binary scan $data cu* v
	set s [expr {double($size) / max($w, $h)}]
	set ow [expr {$w * $s}]; set oh [expr {$h * $s}]
	set ox [expr {($size - $ow) / 2.0}]; set oy [expr {($size - $oh) / 2.0}]
	set out {}
	for {set y 0} {$y < $size} {incr y} {
		set sy0 [expr {($y - $oy) / $s}]; set sy1 [expr {($y + 1 - $oy) / $s}]
		for {set x 0} {$x < $size} {incr x} {
			set sx0 [expr {($x - $ox) / $s}]; set sx1 [expr {($x + 1 - $ox) / $s}]
			set r 0.0; set g 0.0; set b 0.0; set a 0.0; set area 0.0
			for {set yy [expr {max(0, int(floor($sy0)))}]} {$yy < min($h, int(ceil($sy1)))} {incr yy} {
				set wy [expr {min($yy + 1, $sy1) - max($yy, $sy0)}]
				if {$wy <= 0} continue
				for {set xx [expr {max(0, int(floor($sx0)))}]} {$xx < min($w, int(ceil($sx1)))} {incr xx} {
					set wx [expr {min($xx + 1, $sx1) - max($xx, $sx0)}]
					if {$wx <= 0} continue
					set k [expr {($yy * $w + $xx) * 4}]
					set pa [expr {[lindex $v [expr {$k + 3}]] / 255.0 * $wx * $wy}]
					set r [expr {$r + [lindex $v $k] * $pa}]
					set g [expr {$g + [lindex $v [expr {$k + 1}]] * $pa}]
					set b [expr {$b + [lindex $v [expr {$k + 2}]] * $pa}]
					set a [expr {$a + $pa}]
				}
			}
			# the pixel's whole area counts, so an edge only half covered by the picture is half see-through
			set cover [expr {$s * $s}]
			if {$a <= 0} { lappend out 0 0 0 0; continue }
			lappend out [expr {round($r / $a)}] [expr {round($g / $a)}] [expr {round($b / $a)}] [expr {min(255, round(255 * $a * $cover))}]
		}
	}
	binary format cu* $out
}

# The picture in the bar's glyph colours: grey, between BASE (black) and COLOUR (white); alpha kept. A photo.
proc tray::picture {key colour base} {
	variable it
	variable size
	set src [picture_src $key]
	if {$src eq "none"} { return "" }
	if {[info exists it($key,img,$colour)]} { return $it($key,img,$colour) }
	lassign [raster::rgb $base] r0 g0 b0
	lassign [raster::rgb $colour] r1 g1 b1
	binary scan $src cu* v
	set rows {}; set row {}
	foreach {r g b a} $v {
		set l [expr {(0.2126 * $r + 0.7152 * $g + 0.0722 * $b) / 255.0}]
		lappend row [expr {round($r0 + ($r1 - $r0) * $l)}] [expr {round($g0 + ($g1 - $g0) * $l)}] [expr {round($b0 + ($b1 - $b0) * $l)}] $a
		if {[llength $row] == $size * 4} { lappend rows $row; set row {} }
	}
	set img [image create photo -format png -data [raster::png $size $size $rows]]
	set it($key,img,$colour) $img
}

# ---- in the bar --------------------------------------------------------------------------------------------

proc tray::width {} {
	set n [llength [keys]]
	expr {$n ? $n * 30 + ($n - 1) * 4 : 0}
}

proc tray::draw {C x} {
	variable placed
	variable hover
	variable size
	array set c [array get theme::c]
	set placed {}
	foreach k [keys] {
		set lit [expr {$k eq $hover || [menu_of $k]}]
		if {$lit} { rbn::box $C $x 12 30 30 -fill $c(FIELD) -radius 8 -on $c(BAR) }
		set col [expr {[prop $k Status] eq "NeedsAttention" ? $c(ACCENT) : ($lit ? $c(FG) : $c(MUTED))}]
		set img [picture $k $col $c(BAR)]
		if {$img ne ""} {
			$C create image [expr {$x + 7}] 19 -image $img -anchor nw
		} else {
			bar::icon $C pkg 16 1.8 $col [expr {$x + 7}] 19
		}
		bar::hit $x 12 [expr {$x + 30}] 42 [list tray::press $k]
		lappend placed [list $k $x]
		incr x 34
	}
}

# The pointer over the bar (a bind tag of its own on .bar.c, so bar.tcl's bindings stay as they are).
proc tray::bar_motion {x y} {
	variable placed
	variable hover
	set h ""
	if {$y >= 12 && $y < 42} {
		foreach p $placed { lassign $p k px; if {$x >= $px && $x < $px + 30} { set h $k } }
	}
	if {$h ne $hover} { set hover $h; changed }
}

# ---- the menu in the bar's panel -----------------------------------------------------------------------------

proc tray::row_height {r} {
	switch [lindex $r 0] { item { return 40 } sep { return 9 } label { return 25.31 } }
}

proc tray::menu_draw {} {
	variable menu
	if {![dict exists $menu key]} { panel::close; return }
	array set c [array get theme::c]
	set W [expr {max(320, $bar::rightw)}]
	set X [expr {$bar::rightx + $bar::rightw - $W}]
	set rows [dict get $menu rows]
	set sel [dict get $menu sel]
	set H 8
	foreach r $rows { set H [expr {$H + [row_height $r] + 2}] }
	set H [expr {round($H - 2 + 8)}]
	panel::surface
	if {"TrayMenu" ni [bindtags .panel.c]} {
		bindtags .panel.c [linsert [bindtags .panel.c] 0 TrayMenu]
		bind TrayMenu <Motion> {if {$panel::open eq "sni"} { tray::menu_hover %y }}
		bind TrayMenu <Leave> {if {$panel::open eq "sni"} { tray::menu_hover -1 }}
	}
	set d .panel.c
	$d delete all
	$d configure -background $c(BAR)
	set panel::hits {}; set panel::sliders {}
	set y 8.0
	set k 0
	foreach r $rows {
		set y0 [expr {round($y)}]
		switch [lindex $r 0] {
			item {
				lassign $r - id label enabled check
				set on [expr {$k == $sel && $enabled}]
				if {$on} { rbn::box $d 8 $y0 [expr {$W - 16}] 40 -fill $c(FIELD) -radius 8 -on $c(BAR) }
				text::draw $d 20 [expr {$y0 + 20}] [expr {$on ? "f13s" : "f13m"}] [expr {$enabled ? $c(FG) : $c(MUTED)}] [text::clip f13s $label [expr {$W - 40 - ($check ? 22 : 0)}]] w
				if {$check} { bar::icon $d check 14 2 [expr {$enabled ? $c(FG) : $c(MUTED)}] [expr {$W - 20 - 14}] [expr {$y0 + 13}] }
				if {$enabled} { lappend panel::hits [list 8 $y0 [expr {$W - 8}] [expr {$y0 + 40}] [list tray::menu_pick $id]] }
			}
			sep { $d create rectangle 20 [expr {$y0 + 4}] [expr {$W - 20}] [expr {$y0 + 5}] -fill $c(BORDER) -width 0 }
			label { bar::spaced $d 18 [expr {round($y + 8 + 6.66)}] f11s $c(MUTED) [string toupper [lindex $r 1]] 0.88 }
		}
		set y [expr {$y + [row_height $r] + 2}]
		incr k
	}
	rbn::popup .panel [expr {int($X)}] [expr {$bar::Y0 + 54}] $W $H [theme::look pop -radius {0 0 12 12} -ring [list $c(BORDER) 1 lrb]] -clip t
}

# The row under the pointer is lit (a row the app greys out is not).
proc tray::menu_hover {py} {
	variable menu
	if {![dict exists $menu key]} return
	set sel -1
	set y 8.0
	set k 0
	foreach r [dict get $menu rows] {
		set h [row_height $r]
		if {[lindex $r 0] eq "item" && [lindex $r 3] && $py >= $y && $py < $y + $h} { set sel $k }
		set y [expr {$y + $h + 2}]
		incr k
	}
	if {$sel != [dict get $menu sel]} { dict set menu sel $sel; menu_draw }
}
