# inspector.tcl - the file Inspector: one component for the column Files docks
# at its right, the Properties window's pages and the Image viewer's Info. It
# draws the view on the Properties ui (appearance/ui.tcl) into the current
# draw's page, from facts.tcl. Sizes and rows are gen_fileprops.py's (inspector,
# image_parts, folder_parts, text_parts, multi_parts, insp_foot).
#
#   inspector::draw X Y H ITEMS ?-w 380? ?-pad 24? ?-top 20? ?-preview 1? ?-footer pinned? ?-limit Y?
#
#   ITEMS     the facts dicts (facts::of) of the selection: one for a file or a
#             folder, more for several selected
#   -w, -pad  the column's width and its side padding (Files: 380, 24; the viewer: 330, 24)
#   -top      the space above the first line (Files: 20; the viewer's name row
#             lines up with its title bar: 0)
#   -preview  0 leaves out the preview (the viewer's stage is the picture)
#   -keys     the footer's key column (Files: 88; the viewer's narrow column: 76)
#   -footer   pinned: at the panel's foot, over a rule across the panel (Files);
#             follow: 20 under the content, over a rule the column's width (the viewer)
#
# The panel is H tall and fills it with its own surface. The footer's Access
# and Opens with are shown here; the edit view (the pencil) has them as dropdowns,
# with Revert / Apply. A folder's counts come from facts::W: start them with
# inspector::count, and redraw when its done script runs.
#
# Needs appearance/ui.tcl, shell/text.tcl and shell/raster.tcl (the Properties
# app's), and properties/{widgets,facts}.tcl, before it is sourced.
#
# Edit mode (the pencil by the name; the Access and Opens with rows, Revert / Apply): see
# the "edit mode" part at the end. The host (Properties, the Files panel, the viewer) sets
# inspector::redraw to its redraw command, and draws the open dropdown's menu (page::menu,
# widgets.tcl) above the page, as properties/pages.tcl does.
#
# Returns the y the footer ends at (the panel's foot in edit mode).

# Space Grotesk 18 for the name (between the 17 and 22 sizes); its metrics are
# set here so ui::text can place it before ui::fonts runs.
array set ui::fonts {sg18 {{Ribbon Space Grotesk 600} 18 0.984 0.292}}
text::font ui_sg18 {Ribbon Space Grotesk 600} 18
# the exposure strip's figures (Space Grotesk 15) and labels (Inter 11)
array set ui::fonts {sg15 {{Ribbon Space Grotesk 600} 15 0.984 0.292} i11 {{Ribbon Inter 400} 11 0.96875 0.2412}}
text::font ui_sg15 {Ribbon Space Grotesk 600} 15
text::font ui_i11 {Ribbon Inter 400} 11

namespace eval inspector {
	variable cache          ;# memo: the open app per type, the drive per folder, the EXIF per photo
	array set cache {}
	variable edit 0         ;# the edit view is on, for the file EF
	variable EF {}          ;# the facts of the file being edited
	variable E              ;# the edit view's values: name owner u g o x opens
	array set E {}
	variable E0             ;# ... as on disk
	array set E0 {}
	variable bits {{read & write} 6 {read only} 4 {no access} 0}
	variable shown {}       ;# the single item the panel last drew (the pencil edits it)
	variable redraw ""      ;# the host's redraw, a command prefix
	variable busy 0         ;# an Apply is running
	variable mine ""        ;# the per-file choice (openwith) the view shows, if any
	variable errors {}      ;# why the last Apply did not start (a name that is no good)
	variable done ""       ;# the host's Apply callback (the panel's, or the window's): {newpath errs}
	variable rowh 32        ;# the facts rows: 32 tall with 96 for the keys (the panel); the window: 38 and 124
	variable keyw 96
	variable rows_shown {}  ;# the footer rows of the last draw (the window draws its own footer row)
	variable notice ""      ;# a line the host shows under the name (a failed Apply, a failed pick)
}

# Start counting the folder PATH unless facts::W already holds it. DONE runs when
# the count is done (and after each slice).
proc inspector::count {path done} {
	if {![info exists facts::W(path)] || $facts::W(path) ne $path} { facts::count $path $done }
}

# What a single item is drawn as: folder, image, text or file.
proc inspector::kind {F} {
	if {[dict get $F isdir]} { return folder }
	set m [dict get $F mime]
	if {[string match image/* $m]} { return image }
	if {[string match text/* $m] || $m in {application/json application/x-shellscript application/x-tcl application/x-python}} { return text }
	return file
}

# STR cut with an ellipsis to fit W.
proc inspector::clip {f str w {ls 0}} {
	if {[ui::measure $f $str $ls] <= $w} { return $str }
	while {$str ne "" && [ui::measure $f "$str…" $ls] > $w} { set str [string range $str 0 end-1] }
	return "[string trimright $str]…"
}

# The access word for a class's rwx bits.
proc inspector::level {bits} {
	switch -- [expr {$bits & 6}] {
		6 { return "read & write" }
		4 { return "read only" }
		default { return "no access" }
	}
}

# The EXIF and the size of a photo, read once per file version.
proc inspector::photo {F} {
	variable cache
	set key [list photo [dict get $F path] [dict get $F mtime]]
	if {![info exists cache($key)]} {
		set path [dict get $F path]
		set cache($key) [dict create dims [facts::image_size $path] exif [facts::exif $path]]
	}
	return $cache($key)
}

# The app that opens a type: {id name icon}, read once.
proc inspector::opener {F} {
	variable cache
	if {[dict get $F isdir]} { return [list "" Files folder] }
	set m [dict get $F mime]
	if {![info exists cache(app,$m)]} {
		lassign [facts::handlers $m] def
		set cache(app,$m) [expr {$def eq "" ? [list "" None grid] : [list $def [facts::app_name $def] [facts::app_icon $def]]}]
	}
	return $cache(app,$m)
}

# The drive a folder is on, read once: {label free}.
proc inspector::drive {path} {
	variable cache
	if {![info exists cache(drive,$path)]} { set cache(drive,$path) [facts::drive $path] }
	return $cache(drive,$path)
}

# "14 – 16 Aug 2026", "15 Aug – 2 Sep 2026", "14 Aug 2025 – 2 Jan 2026"
proc inspector::range {a b} {
	if {$a == $b} { return [facts::date $a] }
	if {[clock format $a -format %Y] ne [clock format $b -format %Y]} { return "[facts::date $a] – [facts::date $b]" }
	set d1 [string trimleft [clock format $a -format %d] 0]
	set d2 [string trimleft [clock format $b -format %d] 0]
	set m1 [clock format $a -format %b]
	set m2 [clock format $b -format %b]
	set y [clock format $b -format %Y]
	if {$m1 eq $m2} { return "$d1 – $d2 $m2 $y" }
	return "$d1 $m1 – $d2 $m2 $y"
}

# ---- the panel ----------------------------------------------------------------------

proc inspector::draw {x y h items args} {
	variable edit
	variable EF
	variable shown
	variable rows_shown
	array set o {-w 380 -pad 24 -top 20 -preview 1 -footer pinned -keys 88 -ident 1 -limit 0}
	array set o $args
	array set c [array get ui::c]
	# P: the panel and the column, for the parts below (ident 0: the name is drawn elsewhere, as
	# the standalone window's left column does)
	set P [dict create x $x y $y w $o(-w) h $h cx [expr {$x + $o(-pad)}] cw [expr {$o(-w) - 2 * $o(-pad)}] \
		pad $o(-pad) preview $o(-preview) footer $o(-footer) ident $o(-ident) limit $o(-limit)]
	ui::box $x $y $o(-w) $h -fill $c(bar)
	ui::box $x $y 1 $h -fill $c(border)
	set ty [expr {$y + $o(-top)}]
	if {[llength $items] == 1} { set shown [lindex $items 0] }
	if {$edit} {
		if {[llength $items] == 1 && [dict get [lindex $items 0] path] eq [dict get $EF path]} {
			return [edit_draw $P $ty [lindex $items 0]]
		}
		edit_end
	}
	if {[llength $items] > 1} {
		lassign [multi $P $ty $items] ty kw rows
	} else {
		set F [lindex $items 0]
		switch [kind $F] {
			image { lassign [image $P $ty $F] ty kw rows }
			folder { lassign [folder $P $ty $F] ty kw rows }
			text { lassign [text $P $ty $F] ty kw rows }
			default { lassign [other $P $ty $F] ty kw rows }
		}
		set kw $o(-keys)
	}
	set rows_shown $rows
	if {$o(-footer) eq "none"} { return $ty }
	return [footer $P $ty $kw $rows]
}

# The footer: Access and Opens with (or one row per kind of file in a selection).
# ROWS: {key {icon plain|tile} text muted}.
proc inspector::footer {P y kw rows} {
	array set c [array get ui::c]
	set n [llength $rows]
	set fh [expr {14 + 44 * $n - 8 + 16}]
	set cx [dict get $P cx]; set cw [dict get $P cw]
	if {[dict get $P footer] eq "follow"} {
		set ty [expr {$y + 20}]
		ui::hline $cx [expr {$cx + $cw}] $ty $c(border)
	} else {
		set px [dict get $P x]; set pw [dict get $P w]
		set ty [expr {[dict get $P y] + [dict get $P h] - $fh}]
		ui::hline $px [expr {$px + $pw}] $ty $c(border)
	}
	set k 0
	foreach r $rows {
		lassign $r key lead text muted menu
		set ry [expr {$ty + 14 + 44 * $k}]
		ui::text $cx [expr {$ry + 10}] $key i13 $c(muted)
		dropdown [expr {$cx + $kw + 10}] $ry [expr {$cw - $kw - 10}] 36 $lead $text $muted $menu
		incr k
	}
	return [expr {$ty + $fh}]
}

# A dropdown's box, its lead (an icon, or an icon on a tile) and its value.
proc inspector::dropdown {x y w h lead text muted {menu {}}} {
	array set c [array get ui::c]
	lassign $lead icon kind
	ui::box $x $y $w $h -fill $c(field) -radius 8
	ui::ring $x $y $w $h 8 $c(border) 1
	set tx [expr {$x + 12}]
	if {$kind eq "tile"} {
		set tx [expr {$x + 8}]
		ui::box $tx [expr {$y + ($h - 22) / 2.0}] 22 22 -fill $c(pill) -radius 6
		ui::icon $icon 13 $c(fg) [expr {$tx + 4.5}] [expr {$y + ($h - 13) / 2.0}] 1.9
		set tx [expr {$tx + 31}]
	} elseif {$icon ne ""} {
		ui::icon $icon 14 $c(muted) $tx [expr {$y + ($h - 14) / 2.0}] 2
		set tx [expr {$tx + 23}]
	}
	set ty [expr {$y + ($h - 16) / 2.0}]
	# the name ends 10 px short of the chevron (the board's padding); it keeps its room first,
	# and the muted run after it gets what is left
	set room [expr {$x + $w - 34 - $tx}]
	set text [clip i13 $text $room]
	set rest [expr {$room - [ui::measure i13 $text]}]
	if {$muted ne ""} { set muted [expr {$rest > 0 ? [clip i13 $muted $rest] : ""}] }
	set tw [ui::text $tx $ty $text i13 $c(fg) w 0 {} 1]
	if {$muted ne ""} { ui::text [expr {$tx + $tw}] $ty $muted i13 $c(muted) w 0 {} 1 }
	ui::icon chev 14 $c(muted) [expr {$x + $w - 24}] [expr {$y + ($h - 14) / 2.0}] 2
	if {[llength $menu]} { lassign $menu id items cur script; w::dropdown_hit $id $x $y $w $h $items $cur $script }
}

# The footer rows for a file: Access, and what opens it.
proc inspector::file_footer {F {kw 88}} {
	set mode [dict get $F mode]
	set who [dict get $F owner]
	set others [inspector::level [expr {$mode & 7}]]
	lassign [opener $F] id name icon
	set mine [openwith::get [dict get $F path]]
	if {$mine ne ""} { set name [facts::app_name $mine]; set icon [facts::app_icon $mine] }
	return [list $kw [list \
		[list Access {lock plain} $who " · others $others" [access_menu $F]] \
		[list {Opens with} [list $icon tile] $name "" [opens_menu $F]]]]
}

# The menus of the footer's dropdowns: {id items cur script}; the script gets the key picked.
# Access sets the others' level (the mode's last three bits, as the rows make it).
proc inspector::access_menu {F} {
	set m [dict get $F mode]
	set cur [level [expr {$m & 7}]]
	return [list acc.[dict get $F path] {{{read & write} {Read & write} ""} {{read only} {Read only} ""} {{no access} {No access} ""}} $cur [list inspector::pick_others [dict get $F path]]]
}

# Opens with: the file's apps, the choice this file has (or the type's default). A folder opens in Files.
proc inspector::opens_menu {F} {
	set path [dict get $F path]
	if {[dict get $F isdir]} { return [list opens.$path {{files Files folder}} files inspector::noop] }
	lassign [facts::handlers [dict get $F mime]] def others
	set ids {}
	if {$def ne ""} { lappend ids $def }
	lappend ids {*}$others
	set items [lmap id $ids { list $id [facts::app_name $id] [facts::app_icon $id] }]
	set mine [openwith::get $path]
	set cur [expr {$mine ne "" ? $mine : $def}]
	return [list opens.$path $items $cur [list inspector::pick_opener $path]]
}

# A section: its label (margin 20 above it), the rows start below it. Returns the
# y the rows start at.
proc inspector::section {P y title {right ""}} {
	array set c [array get ui::c]
	set cx [dict get $P cx]; set cw [dict get $P cw]
	set ly [expr {$y + 20}]
	ui::label $cx $ly $title
	if {$right ne ""} { ui::text [expr {$cx + $cw}] [expr {$ly + 1}] $right i12 $c(muted) e }
	return [expr {$ly + 19}]
}

# The name (Space Grotesk 18, the pencil at its end) and the kind line under it.
# Returns the y below the kind line.
proc inspector::ident {P y name sub {pencil 1}} {
	if {![dict get $P ident]} { return $y }
	array set c [array get ui::c]
	set cx [dict get $P cx]; set cw [dict get $P cw]
	set ny [expr {$y + 14}]
	ui::text $cx [expr {$ny + 9}] [clip sg18 $name [expr {$cw - 24}] -0.18] sg18 $c(fg) w -0.18
	if {$pencil} {
		ui::icon edit 14 $c(muted) [expr {$cx + $cw - 14}] [expr {$ny + 13}] 2
		ui::hit [expr {$cx + $cw - 24}] [expr {$ny + 2}] 24 24 [list inspector::edit_click]
	}
	ui::text $cx [expr {$ny + 42}] [clip i13 $sub $cw] i13 $c(muted)
	return [expr {$ny + 58}]
}

# A photo as the preview, or a field box with the picture icon where it can't be read.
proc inspector::picture {P y path h} {
	array set c [array get ui::c]
	set cx [dict get $P cx]; set cw [dict get $P cw]
	if {![w::picture $cx $y $cw $h $path 10]} {
		ui::box $cx $y $cw $h -fill $c(field) -radius 10
		ui::icon image 32 $c(muted) [expr {$cx + $cw / 2.0 - 16}] [expr {$y + $h / 2.0 - 16}]
	}
	return [expr {$y + $h}]
}

# ---- one photo ---------------------------------------------------------------------

proc inspector::image {P y F} {
	set path [dict get $F path]
	set info [photo $F]
	set exif [dict get $info exif]
	set cx [dict get $P cx]; set cw [dict get $P cw]
	if {[dict get $P preview]} { set y [picture $P $y $path 160] }
	set y [ident $P $y [dict get $F name] "[dict get $F typename] · [facts::human [dict get $F size]]"]
	set rows {}
	lassign [dict get $info dims] w h
	if {$w ne ""} {
		lappend rows [list Dimensions [list [list t "$w × $h"] [list m "· [expr {round($w * $h / 1e6)}] MP"]]]
	}
	set cam [facts::camera $exif]
	if {$cam ne ""} { lappend rows [list Camera [list [list t $cam]]] }
	if {[dict exists $exif DateTimeOriginal] && ![catch {clock scan [dict get $exif DateTimeOriginal] -format {%Y:%m:%d %H:%M:%S}} t]} {
		lappend rows [list Taken [list [list t [facts::when $t]]]]
	}
	set expo [facts::exposure $exif]
	set strip 0
	foreach v $expo { if {[lindex $v 0] ne ""} { set strip 1 } }
	set where [facts::coords $exif]
	if {$strip || [llength $rows] || $where ne ""} {
		set y [section $P $y Photo]
		if {$strip} { set y [exposure $P $y $expo]; set y [expr {$y + 4}] }
		if {[llength $rows]} { set y [facts_at $P $y $rows] }
		if {$where ne ""} { set y [mapblock $P [expr {$y + 10}] $where] }
	}
	set y [file_rows $P $y $F]
	return [list $y {*}[file_footer $F]]
}

# The exposure strip (the board's exp_strip): aperture, shutter, ISO and focal length in four
# equal cells of a 56 px box with a 10 px radius, a dash for a figure the photo lacks.
# VALS is facts::exposure's {value label} list. Returns the y below it.
proc inspector::exposure {P y vals} {
	array set c [array get ui::c]
	set cx [dict get $P cx]; set cw [dict get $P cw]
	set h 56
	set cell [expr {$cw / 4.0}]
	foreach k {1 2 3} { ui::box [expr {$cx + $k * $cell}] $y 1 $h -fill $c(border) }
	ui::ring $cx $y $cw $h 10 $c(border) 1
	set n 0
	foreach v $vals {
		lassign $v val label
		set mx [expr {$cx + ($n + 0.5) * $cell}]
		ui::text $mx [expr {$y + 11}] [expr {$val eq "" ? "–" : $val}] sg15 $c(fg) c 0 {} 1
		ui::text $mx [expr {$y + 32}] $label i11 $c(muted) c
		incr n
	}
	return [expr {$y + $h}]
}

# The place block (the board's place row): the map tile, 64 tall, 132 wide in the Inspector's
# column and 82 in the viewer's (min(132, width - 200)), beside "Place" and the coordinates.
# The place name needs a gazetteer this OS does not carry, so the block shows the coordinates
# only. Returns the y below the tile.
proc inspector::mapblock {P y where} {
	variable lastplace
	array set c [array get ui::c]
	set cx [dict get $P cx]; set cw [dict get $P cw]
	set mw [expr {min(132, $cw - 200)}]
	set mh 64
	lassign [ui::snap $cx $y $mw $mh] x0 y0 w0 h0
	raster::blit $ui::img [mapphoto $w0 $h0] 0 0 $w0 $h0 $x0 $y0
	ui::corners $x0 $y0 $w0 $h0 8 $c(bar)
	ui::ring $x0 $y0 $w0 $h0 8 $c(border) 1
	# the pin: a 12 px accent dot with a 2.5 px ring, at the middle of the tile and 65 % down
	set px [expr {$cx + $mw / 2.0}]; set py [expr {$y + 0.65 * $mh}]
	ui::box [expr {$px - 8.5}] [expr {$py - 8.5}] 17 17 -fill $c(fg) -radius 8.5
	ui::box [expr {$px - 6}] [expr {$py - 6}] 12 12 -fill $c(accent) -radius 6
	set tx [expr {$cx + $mw + 14}]
	set tw [expr {$cw - $mw - 14}]
	ui::text $tx [expr {$y + 14}] Place i12 $c(muted)
	ui::text $tx [expr {$y + 33}] [clip i13m $where $tw] i13m $c(fg)
	set lastplace [list $x0 $y0 $w0 $h0]
	return [expr {$y + $mh}]
}

# The map tile (the board's mapbox): the same land, sea, lagoon, road and sparkles as the
# board's 380 x 150 art, cut to the tile's size as the browser's slice does, from the palette.
# Each layer is {token kind width alpha path}: a fill (kind fill, alpha over the shape) or a
# stroke (width in the art's units). Drawn from the parsed paths, so nothing is fetched.
namespace eval inspector {
	variable mapart {
		{border stroke 1.4 1 {M0 40 C40 52 70 70 120 74 M0 70 C30 78 70 92 128 96 M300 20 C320 34 350 40 380 38 M310 52 C334 60 356 66 380 64}}
		{fg fill 0 0.16 {M30 0 C64 30 108 44 150 50 C186 54 206 42 214 28 C220 16 222 6 224 0 Z}}
		{bar fill 0 1 {M0 120 C60 112 120 124 178 118 C230 114 300 124 380 116 L380 150 L0 150 Z}}
		{bar fill 0 1 {M120 62 C134 48 160 52 176 46 C196 38 222 44 250 48 C276 52 312 58 306 74 C300 86 276 80 266 88 C246 92 206 90 186 86 C164 82 150 90 136 80 C126 74 112 70 120 62 Z}}
		{bar fill 0 1 {M254 84 L272 84 L270 120 L252 120 Z}}
		{muted stroke 2 1 {M0 104 C80 101 140 106 185 105 C240 104 300 99 380 102}}
		{fg fill 0 0.3 {M176 64 l7 -2 l3 4 l-6 3 Z M228 72 l6 -1 l2 4 l-7 1 Z M204 76 l5 -2 l2 3 l-5 2 Z M266 62 l4 -1 l2 3 l-5 1 Z}}
	}
	variable mapimg         ;# the tiles painted so far, by size and palette
	array set mapimg {}
	variable lastplace {}   ;# where the last place block was drawn: x y w h (the scenes check it)
}

# The tile as a photo W x H: the palette's ground (the first layer's "pill" fill covers it all).
proc inspector::mapphoto {w h} {
	variable mapart
	variable mapimg
	array set c [array get ui::c]
	set key [list $w $h $c(pill) $c(fg) $c(border) $c(bar) $c(muted) $c(accent)]
	if {[info exists mapimg($key)]} { return $mapimg($key) }
	set k [expr {$h / 150.0}]
	set ox [expr {($w - 380 * $k) / 2.0}]
	lassign [raster::rgb $c(pill)] r g b
	set n [expr {$w * $h}]
	set R [lrepeat $n $r]; set G [lrepeat $n $g]; set B [lrepeat $n $b]
	foreach layer $mapart {
		lassign $layer tok kind width alpha d
		lassign [raster::rgb $c($tok)] cr cg cb
		foreach {i cov} [mapcover $w $h [mappolys $kind $width $k $ox $d]] {
			set a [expr {min(1.0, $cov) * $alpha}]
			lset R $i [expr {[lindex $R $i] * (1 - $a) + $cr * $a}]
			lset G $i [expr {[lindex $G $i] * (1 - $a) + $cg * $a}]
			lset B $i [expr {[lindex $B $i] * (1 - $a) + $cb * $a}]
		}
	}
	set rows {}
	for {set y 0} {$y < $h} {incr y} {
		set row {}
		for {set x 0} {$x < $w} {incr x} {
			set i [expr {$y * $w + $x}]
			lappend row [format #%02x%02x%02x [expr {int(round([lindex $R $i]))}] [expr {int(round([lindex $G $i]))}] [expr {int(round([lindex $B $i]))}]]
		}
		lappend rows $row
	}
	set p [::image create photo]
	$p put $rows
	set mapimg($key) $p
	return $p
}

# The polygons of one layer in the tile's pixels: a fill's subpaths as they are, a stroke's
# segments as thin quads WIDTH wide (in the art's units, scaled by K).
proc inspector::mappolys {kind width k ox d} {
	set out {}
	foreach line [raster::path $d] {
		set pts {}
		foreach {px py} $line { lappend pts [expr {$px * $k + $ox}] [expr {$py * $k}] }
		if {$kind eq "fill"} { lappend out $pts; continue }
		set hw [expr {$width * $k / 2.0}]
		set np [expr {[llength $pts] / 2}]
		for {set i 0} {$i < $np - 1} {incr i} {
			set x0 [lindex $pts [expr {2 * $i}]]; set y0 [lindex $pts [expr {2 * $i + 1}]]
			set x1 [lindex $pts [expr {2 * $i + 2}]]; set y1 [lindex $pts [expr {2 * $i + 3}]]
			set len [expr {hypot($x1 - $x0, $y1 - $y0)}]
			if {$len == 0} continue
			set nx [expr {-($y1 - $y0) / $len * $hw}]; set ny [expr {($x1 - $x0) / $len * $hw}]
			lappend out [list [expr {$x0 + $nx}] [expr {$y0 + $ny}] [expr {$x1 + $nx}] [expr {$y1 + $ny}] \
				[expr {$x1 - $nx}] [expr {$y1 - $ny}] [expr {$x0 - $nx}] [expr {$y0 - $ny}]]
		}
	}
	return $out
}

# The coverage of a W x H tile by POLYS (flat x y lists in pixels): 4 samples down each
# column, exact across it, summed over the polygons. Returns {index coverage ...} for the
# pixels touched.
proc inspector::mapcover {w h polys} {
	array set cov {}
	foreach poly $polys {
		set n [expr {[llength $poly] / 2}]
		set edges {}
		for {set i 0} {$i < $n} {incr i} {
			set j [expr {($i + 1) % $n}]
			set ay [lindex $poly [expr {2 * $i + 1}]]; set by [lindex $poly [expr {2 * $j + 1}]]
			if {$ay == $by} continue
			lappend edges [lindex $poly [expr {2 * $i}]] $ay [lindex $poly [expr {2 * $j}]] $by
		}
		for {set sy 0} {$sy < $h * 4} {incr sy} {
			set yc [expr {($sy + 0.5) / 4.0}]
			set row [expr {$sy / 4}]
			set xs {}
			foreach {ax ay bx by} $edges {
				if {($ay <= $yc && $yc < $by) || ($by <= $yc && $yc < $ay)} {
					lappend xs [expr {$ax + ($yc - $ay) * ($bx - $ax) / ($by - $ay)}]
				}
			}
			foreach {a b} [lsort -real $xs] {
				if {$b eq ""} break
				for {set x [expr {max(0, int(floor($a)))}]} {$x < min($w, int(ceil($b)))} {incr x} {
					set o [expr {min($b, $x + 1.0) - max($a, double($x))}]
					if {$o <= 0} continue
					set idx [expr {$row * $w + $x}]
					set cov($idx) [expr {([info exists cov($idx)] ? $cov($idx) : 0.0) + $o / 4.0}]
				}
			}
		}
	}
	return [array get cov]
}

# The File section: where the item is, when it was changed and made.
# Returns the y below it.
proc inspector::file_rows {P y F} {
	variable rowh
	variable keyw
	set where [clip i13 [facts::tilde [dict get $F dir]] [expr {[dict get $P cw] - $keyw - 24}]]
	set rows [list [list Location [list [list t $where]] [list ext ""]] \
		[list Modified [list [list t [facts::when [dict get $F mtime]]]]]]
	if {[dict get $F btime] ne ""} { lappend rows [list Created [list [list t [facts::when [dict get $F btime]]]]] }
	return [w::facts [dict get $P cx] [section $P $y File] [dict get $P cw] $rows $rowh $keyw]
}

# Rows drawn with w::facts at Y (32 tall, 96 for the keys): returns the y below them.
# The facts rows that fit above the limit (the footer's rule, when the window has one): a row that
# would not be whole is not drawn, so none is cut by the rule or the footer.
proc inspector::facts_at {P y rows} {
	variable rowh
	variable keyw
	if {[dict exists $P limit] && [dict get $P limit] > 0} {
		set fit {}
		set ry $y
		foreach r $rows {
			if {$ry + $rowh > [dict get $P limit]} break
			lappend fit $r
			incr ry $rowh
		}
		set rows $fit
	}
	return [w::facts [dict get $P cx] $y [dict get $P cw] $rows $rowh $keyw]
}

# ---- one folder ----------------------------------------------------------------------

# The newest pictures as a mosaic: the first large, four more in a grid.
proc inspector::mosaic {P y names h} {
	array set c [array get ui::c]
	set cx [dict get $P cx]; set cw [dict get $P cw]
	set gap 3
	set lw [expr {round($cw * 0.5)}]
	set rw [expr {$cw - $lw - $gap}]
	set ch [expr {($h - $gap) / 2}]
	set cells [expr {($rw - $gap) / 2}]
	set k 0
	foreach n $names {
		if {$k == 0} { set x $cx; set yy $y; set w $lw; set hh $h } else {
			set x [expr {$cx + $lw + $gap + (($k - 1) % 2) * ($cells + $gap)}]
			set yy [expr {$y + (($k - 1) / 2) * ($ch + $gap)}]
			set w $cells; set hh $ch
		}
		if {![w::picture $x $yy $w $hh $n 0]} { ui::box $x $yy $w $hh -fill $c(field) }
		incr k
		if {$k == 5} break
	}
	if {$k == 0} {
		ui::box $cx $y $cw $h -fill $c(field) -radius 10
		ui::icon folder 32 $c(muted) [expr {$cx + $cw / 2.0 - 16}] [expr {$y + $h / 2.0 - 16}]
	}
	return [expr {$y + $h}]
}

proc inspector::folder {P y F} {
	array set c [array get ui::c]
	upvar #0 facts::W W
	set path [dict get $F path]
	set cx [dict get $P cx]; set cw [dict get $P cw]
	set counted [expr {[info exists W(path)] && $W(path) eq $path}]
	set items [expr {$counted ? $W(files) + $W(dirs) : 0}]
	if {[dict get $P preview]} {
		set names {}
		foreach p [lrange $W(newest) 0 4] { lappend names [lindex $p 1] }
		set y [mosaic $P $y $names 160]
	}
	set sub "Folder"
	if {$counted} { append sub " · [facts::commas $items] item[expr {$items == 1 ? "" : "s"}] · [facts::human $W(bytes)]" }
	set y [ident $P $y [dict get $F name] $sub]
	# what it holds, by kind: a bar of the bytes and the legend
	set ly [section $P $y Contents "[facts::commas $W(files)] files · [facts::commas $W(dirs)] folders"]
	set parts [list Photos photos $c(accent) Videos videos $c(muted) Documents documents [ui::mix $c(muted) $c(bar) 0.55] Other other [ui::mix $c(muted) $c(bar) 0.3]]
	set total [expr {max(1, $W(bytes))}]
	set avail [expr {$cw - 3 * 3}]
	set x $cx
	set segs {}
	foreach {label k colour} $parts {
		if {!$counted || $W($k,b) <= 0} continue
		lappend segs [expr {max(4.0, $avail * $W($k,b) / double($total))}] $colour
	}
	if {[llength $segs] == 0} { ui::box $cx [expr {$ly + 4}] $cw 8 -fill $c(field) -radius 3 }
	foreach {sw colour} $segs {
		ui::box $x [expr {$ly + 4}] $sw 8 -fill $colour -radius 3
		set x [expr {$x + $sw + 3}]
	}
	set ry [expr {$ly + 4 + 8 + 6}]
	set n 0
	foreach {label k colour} $parts {
		set r [expr {$ry + 34 * $n}]
		ui::box $cx [expr {$r + 12.5}] 9 9 -fill $colour -radius 3
		ui::text [expr {$cx + 19}] [expr {$r + 9}] $label i13 $c(fg)
		set cnt [expr {$counted ? $W($k,n) : 0}]
		ui::text [expr {$cx + $cw - 62 - 10}] [expr {$r + 9}] [facts::commas $cnt] i13 $c(muted) e 0 {} 1
		ui::text [expr {$cx + $cw}] [expr {$r + 9}] [expr {$counted ? [facts::human $W($k,b)] : ""}] i13 $c(fg) e 0 {} 1
		if {$n < 3} { ui::hline $cx [expr {$cx + $cw}] [expr {$r + 33}] $c(border) }
		incr n
	}
	set y [expr {$ry + 34 * 4}]
	set rows [list [list Location [list [list t [facts::tilde [dict get $F dir]]]] [list ext ""]]]
	if {$counted} {
		lappend rows [list Size [list [list t [facts::human $W(bytes)]] [list m "([facts::commas $W(bytes)] bytes)"]]]
	}
	lappend rows [list Modified [list [list t [facts::when [dict get $F mtime]]]]]
	if {[dict get $F btime] ne ""} { lappend rows [list Created [list [list t [facts::when [dict get $F btime]]]]] }
	set d [drive $path]
	if {$d ne ""} { lappend rows [list Drive [list [list t "[lindex $d 0] · [facts::human [lindex $d 1]] free"]]] }
	set y [facts_at $P [section $P $y Folder] $rows]
	lassign [opener $F] id name icon
	return [list $y 88 [list \
		[list Access {lock plain} [dict get $F owner] " · others [level [expr {[dict get $F mode] & 7}]]" [access_menu $F]] \
		[list {Opens with} [list $icon tile] $name "" [opens_menu $F]]]]
}

# ---- one text file --------------------------------------------------------------------

# A text file's first lines, numbered, on the code field.
proc inspector::code_box {P y lines h} {
	array set c [array get ui::c]
	set cx [dict get $P cx]; set cw [dict get $P cw]
	ui::box $cx $y $cw $h -fill $c(d2) -radius 10 -ring [list $c(border) 1]
	set n 1
	foreach l $lines {
		set ly [expr {$y + 12 + 20 * ($n - 1)}]
		if {$ly + 20 > $y + $h} break
		ui::text [expr {$cx + 34}] $ly $n mono12 $c(muted) e
		ui::text [expr {$cx + 46}] $ly [clip mono12 $l [expr {$cw - 58}]] mono12 $c(fg)
		incr n
	}
	fade $cx $y $cw $h $c(d2)
	return [expr {$y + $h}]
}

# The code fades into the field over its right 72 px (a ramp from 96 to 24 px in from the
# right edge): each pixel is mixed toward the field's colour, on the frame being drawn.
proc inspector::fade {x0 y0 w h bg} {
	set ax [expr {$x0 + $w - 96}]; set span 72.0
	for {set y [expr {$y0 + 1}]} {$y < $y0 + $h - 1} {incr y} {
		set row {}
		for {set x $ax} {$x < $ax + 72} {incr x} {
			set f [expr {($x - $ax) / $span}]
			lappend row [ui::mix [format #%02X%02X%02X {*}[$::ui::img get $x $y]] $bg [expr {1 - $f}]]
		}
		$::ui::img put [list $row] -to $ax $y
	}
}

proc inspector::text {P y F} {
	set path [dict get $F path]
	set info [facts::text_info $path 12]
	array set c [array get ui::c]
	set cx [dict get $P cx]; set cw [dict get $P cw]
	if {[dict get $P preview]} { set y [code_box $P $y [dict get $info head] 250] }
	set lang [facts::language $path]
	set sub [expr {$lang ne "" ? "$lang source" : [dict get $F typename]}]
	set y [ident $P $y [dict get $F name] "$sub · [facts::human [dict get $F size]]"]
	set chars [dict get $info chars]
	set lines [dict get $info lines]
	set lrun {}
	if {$lines ne ""} { set lrun [list [list t [facts::commas $lines]] [list m "· [facts::commas $chars] characters"]] }
	set rows [list [list Language [list [list t [expr {$lang ne "" ? $lang : [dict get $F typename]}]]]] \
		[list Lines $lrun] \
		[list Encoding [list [list t [dict get $info enc]]]] \
		[list {Line endings} [list [list t [dict get $info eol]]]]]
	set y [facts_at $P [section $P $y Text] $rows]
	set y [file_rows $P $y $F]
	return [list $y {*}[file_footer $F]]
}

# ---- a file with no view of its own -------------------------------------------------------

proc inspector::other {P y F} {
	set y [ident $P $y [dict get $F name] "[dict get $F typename] · [facts::human [dict get $F size]]"]
	set y [file_rows $P $y $F]
	return [list $y {*}[file_footer $F]]
}

# ---- several selected ---------------------------------------------------------------------

# Who a selection's items belong to in one class: {value} or {Mixed}.
proc inspector::same {values} {
	set first [lindex $values 0]
	foreach v $values { if {$v ne $first} { return [list Mixed] } }
	return [list $first]
}

# One Access row of a selection: icon, key, a value and a line under it unless last.
# A value of Mixed is a chip.
proc inspector::access_row {P y icon key value summary last} {
	array set c [array get ui::c]
	set cx [dict get $P cx]; set cw [dict get $P cw]
	ui::icon $icon 14 $c(muted) [expr {$cx + 1}] [expr {$y + 10}] 2
	ui::text [expr {$cx + 24}] [expr {$y + 9}] $key i13 $c(muted)
	set vx [expr {$cx + 106}]
	if {$value eq "Mixed"} {
		set tw [ui::measure i12s Mixed]
		ui::box $vx [expr {$y + 6}] [expr {$tw + 16}] 22 -fill $c(pill) -radius 6
		ui::text [expr {$vx + 8}] [expr {$y + 11}] Mixed i12s $c(fg)
		if {$summary ne ""} { ui::text [expr {$cx + $cw}] [expr {$y + 9}] $summary i13 $c(muted) e 0 {} 1 }
	} elseif {$key eq "Owner"} {
		ui::text $vx [expr {$y + 9}] $value i13m $c(fg)
	} else {
		ui::text $vx [expr {$y + 9}] [sentence $value] i13 $c(fg)
	}
	if {!$last} { ui::hline $cx [expr {$cx + $cw}] [expr {$y + 33}] $c(border) }
	return [expr {$y + 34}]
}

# "Read only" from "read only": the first letter up.
proc inspector::sentence {s} { string cat [string toupper [string range $s 0 0]] [string range $s 1 end] }

# "4 read only · 1 none": how many items have each level, in the order of the levels.
proc inspector::levels_summary {levels} {
	set parts {}
	foreach l {{read & write} {read only} {no access}} {
		set m [llength [lsearch -all -exact $levels $l]]
		if {$m} { lappend parts "$m [expr {$l eq "no access" ? "none" : $l}]" }
	}
	join $parts " · "
}

# The footer's key for a kind of file: photos and videos say what they open in.
proc inspector::open_key {F} {
	if {[dict get $F isdir]} { return "" }
	switch -glob -- [dict get $F mime] {
		image/* { return "Photos open in" }
		video/* { return "Video opens in" }
		default { return "Opens with" }
	}
}

# Several selected: the stack of the pictures, the totals and dates, Access (each
# class's level, or Mixed) and what opens each kind. Returns {y kw rows}.
proc inspector::multi {P y items} {
	array set c [array get ui::c]
	set cx [dict get $P cx]; set cw [dict get $P cw]
	set n [llength $items]
	set pics {}; set bytes 0; set dirs {}; set mtimes {}; set taken {}; set modes {}; set owners {}
	set kinds {}; set jpegs {}
	foreach F $items {
		lappend kinds [kind $F]
		lappend jpegs [expr {[dict get $F mime] eq "image/jpeg"}]
		incr bytes [dict get $F size]
		lappend dirs [dict get $F dir]
		lappend mtimes [dict get $F mtime]
		lappend modes [dict get $F mode]
		lappend owners [dict get $F owner]
		if {[kind $F] eq "image"} {
			lappend pics [dict get $F path]
			set exif [dict get [photo $F] exif]
			if {[dict exists $exif DateTimeOriginal] && ![catch {clock scan [dict get $exif DateTimeOriginal] -format {%Y:%m:%d %H:%M:%S}} t]} { lappend taken $t }
		}
	}
	# the stack: the first four pictures, the last one on top
	if {[dict get $P preview]} { set y [stack $P $y $pics 200] }
	# "4 images · 1 video · 2 folders", by kind
	set words {}
	foreach {k sing plur} {image {image images} file {file files} folder {folder folders}} {
		set m [llength [lsearch -all -exact $kinds $k]]
		if {$m} {
			set name [lindex $sing [expr {$m == 1 ? 0 : 1}]]
			if {$k eq "image" && [llength [lsearch -all -exact $jpegs 1]] == [llength $pics]} { set name [expr {$m == 1 ? "JPEG image" : "JPEG images"}] }
			lappend words "$m $name"
		}
	}
	set y [ident $P $y "$n items" [join $words " · "] 0]
	set ty [section $P $y Together]
	set dsame [same $dirs]
	set loc [expr {[lindex $dsame 0] eq "Mixed" ? [list [list t Mixed]] : [list [list t [clip i13 [facts::tilde [lindex $dsame 0]] [expr {$cw - [opt_keyw] - 24}]]] [list ext ""]]}]
	set rows [list [list Size [list [list t [facts::human $bytes]] [list m "([facts::commas $bytes] bytes)"]]] [list Location $loc]]
	if {[llength $taken]} { lappend rows [list Taken [list [list t [range [tcl::mathfunc::min {*}$taken] [tcl::mathfunc::max {*}$taken]]]]] }
	lappend rows [list Modified [list [list t [range [tcl::mathfunc::min {*}$mtimes] [tcl::mathfunc::max {*}$mtimes]]]]]
	set y [facts_at $P $ty $rows]
	# Access: the owner, you, the group and everyone, each one level or Mixed
	set ay [section $P $y Access]
	set uv {}; set gv {}; set ov {}; set lvl {}
	foreach m $modes {
		lappend uv [level [expr {($m >> 6) & 7}]]
		lappend gv [level [expr {($m >> 3) & 7}]]
		lappend ov [level [expr {$m & 7}]]
	}
	set acc [list [list user Owner $owners] [list user You $uv] [list users Group $gv] [list globe Everyone $ov]]
	set k 0
	foreach r $acc {
		lassign $r icon key values
		set v [same $values]
		set sum [expr {[lindex $v 0] eq "Mixed" ? [levels_summary $values] : ""}]
		set ay [access_row $P $ay $icon $key [lindex $v 0] $sum [expr {$k == 3}]]
		incr k
	}
	# what opens each kind, once per kind
	set frows {}; set seen {}
	foreach F $items {
		set key [open_key $F]
		if {$key eq "" || $key in $seen} continue
		lappend seen $key
		lassign [opener $F] id name icon
		lappend frows [list $key [list $icon tile] $name "" [opens_menu $F]]
	}
	return [list $ay 108 $frows]
}

# The stack of up to four pictures (the last one on top) in a card H tall; the offsets are the
# panel's at 200 and scale with H.
proc inspector::stack {P y pics h} {
	array set c [array get ui::c]
	set cx [dict get $P cx]; set cw [dict get $P cw]
	ui::box $cx $y $cw $h -fill $c(d2) -radius 10 -ring [list $c(border) 1]
	set k 0
	set sc [expr {$h / 200.0}]
	set sx [expr {$cw / 332.0}]
	foreach {dx dy} {-62 40 -22 30 20 32 0 36} {
		set i [expr {[llength $pics] - 1 - $k}]
		if {$i < 0} break
		set px [expr {round($cx + $cw / 2.0 - 86 * $sx + $dx * $sx)}]
		set py [expr {round($y + $dy * $sc)}]
		set pw [expr {round(172 * $sx)}]
		if {![w::picture $px $py $pw 114 [lindex $pics $i] 8]} { ui::box $px $py $pw 114 -fill $c(field) -radius 8 }
		incr k
	}
	return [expr {$y + $h}]
}

# ---- edit mode -----------------------------------------------------------------------------
#
# inspector::edit_begin F turns the panel into the edit view for the one file or folder F
# (the pencil by its name starts it). E holds the rows' values, E0 what is on disk: a row
# that differs shows its undo, and Revert puts every row back. Apply runs the changes the
# way Properties applies its General page: rename, owner, access, through fp::run_jobs
# (pkexec for what you may not change yourself), and the type's app through
# facts::set_default. Access applies to every file of the type, not to this file alone:
# nothing stores a per-file choice yet.

# Start the edit view on F.
proc inspector::edit_begin {F} {
	variable E
	variable E0
	variable EF
	variable edit
	set EF $F
	set m [dict get $F mode]
	array unset E0
	set E0(name) [dict get $F name]
	set E0(owner) [dict get $F owner]
	set E0(u) [level [expr {($m >> 6) & 7}]]
	set E0(g) [level [expr {($m >> 3) & 7}]]
	set E0(o) [level [expr {$m & 7}]]
	set E0(x) [expr {($m & 0111) != 0}]
	set E0(opens) ""
	set E0(every) 1
	if {![dict get $F isdir]} {
		lassign [facts::handlers [dict get $F mime]] E0(opens)
		# a file with its own choice shows it, and its switch is off ("this file only")
		set mine [openwith::get [dict get $F path]]
		if {$mine ne ""} { set E0(opens) $mine; set E0(every) 0 }
	}
	array set E [array get E0]
	ui::fset insp.name $E0(name)
	set ui::focus insp.name
	set ui::fld(insp.name,cur) [string length [file rootname $E0(name)]]
	set edit 1
}

proc inspector::edit_end {} {
	variable edit
	set edit 0
	set ui::focus ""
}

proc inspector::redraw_now {args} {
	variable redraw
	if {$redraw ne ""} { uplevel #0 $redraw }
}

# The name field's keys redraw the panel; the field itself keeps its text.
proc inspector::name_key {args} { redraw_now }

# The pencil.
proc inspector::edit_click {x y} {
	variable shown
	edit_begin $shown
	redraw_now
}

# Choices. A dropdown's script gets the key it chose (page::menu_pick).
proc inspector::pick {k v} {
	variable E
	set E($k) $v
	redraw_now
}
proc inspector::pick_app {id} {
	variable E
	set E(opens) $id
	redraw_now
}
# "Every <type> file": on sets the type's default, off keeps the choice to this file.
proc inspector::toggle_every {} {
	variable E
	set E(every) [expr {!$E(every)}]
	redraw_now
}
proc inspector::toggle_run {} {
	variable E
	set E(x) [expr {!$E(x)}]
	redraw_now
}
proc inspector::undo {k} {
	variable E
	variable E0
	set E($k) $E0($k)
	redraw_now
}
proc inspector::revert {} {
	variable E
	variable E0
	array set E [array get E0]
	ui::fset insp.name $E0(name)
	redraw_now
}

# The owner's choices: the current owner and the users of this machine (facts::users).
proc inspector::owners {} {
	variable E0
	lsort -unique [concat $E0(owner) [facts::users]]
}
# The access choices.
proc inspector::levels {} {
	list {{read & write} {Read & write} ""} {{read only} {Read only} ""} {{no access} {No access} ""}
}

# The mode the access rows make: the level's r and w per class; x as the row says, else as
# it was (a folder you can read, you can open, as fp::mode).
proc inspector::newmode {} {
	variable E
	variable E0
	variable EF
	variable bits
	set m [dict get $EF mode]
	set dir [dict get $EF isdir]
	set out [expr {$m & 07000}]
	set sh 6
	foreach k {u g o} {
		set b [dict get $bits $E($k)]
		set old [expr {($m >> $sh) & 7}]
		if {$dir} {
			set x [expr {$b ? 1 : 0}]
		} elseif {$E(x) eq $E0(x)} {
			set x [expr {$old & 1}]
		} else {
			set x [expr {$E(x) ? 1 : 0}]
		}
		set out [expr {$out | (($b | $x) << $sh)}]
		incr sh -3
	}
	return $out
}

# Whether any of KEYS differs from disk.
proc inspector::changed {keys} {
	variable E
	variable E0
	foreach k $keys { if {$E($k) ne $E0($k)} { return 1 } }
	return 0
}

# Apply from the footer, with the host's callback.
proc inspector::apply_now {} {
	variable done
	apply $done
}

# Apply: the jobs, run in order; DONE gets the new path and the errors (its own, or the
# ones the jobs gave). A name that is no good keeps the edit view open.
proc inspector::apply {done} {
	variable E
	variable E0
	variable EF
	variable busy
	variable errors
	if {$busy} return
	set path [dict get $EF path]
	set dir [dict get $EF dir]
	set jobs {}; set errs {}
	set newpath $path
	set name [string trim [ui::fval insp.name]]
	if {$name ne $E0(name)} {
		set target [file join $dir $name]
		if {$name eq "" || [string match */* $name] || $name in {. ..}} {
			set errors [list "“$name” can't be a name."]
			if {$done ne ""} { uplevel #0 [list {*}$done $path $errors] }
			return
		}
		if {[file exists $target] && ![string equal -nocase $target $path]} {
			set errors [list "There is already something called “$name” here."]
			if {$done ne ""} { uplevel #0 [list {*}$done $path $errors] }
			return
		}
		set newpath $target
		lappend jobs [list rename $path $newpath]
	}
	set errors {}
	if {$E(owner) ne $E0(owner)} { lappend jobs [list chown $E(owner) $newpath] }
	if {[changed {u g o x}]} {
		set m [newmode]
		if {$m != [dict get $EF mode]} { lappend jobs [list chmod [format %04o $m] $newpath] }
	}
	# the app: the type's default (every file of the type) or this file's own choice
	if {![dict get $EF isdir] && ($E(every) != $E0(every) || ($E(opens) ne $E0(opens) && $E(opens) ne ""))} {
		set app [expr {$E(opens) ne "" ? $E(opens) : $E0(opens)}]
		if {$app ne ""} {
			if {$E(every)} {
				if {[catch {facts::set_default [dict get $EF mime] $app} err]} { lappend errs $err } else { openwith::choose $path "" }
			} else {
				openwith::choose $path $app
			}
		}
	}
	set busy 1
	fp::run_jobs $jobs [list inspector::applied $done $newpath $path] $errs
}

proc inspector::applied {done newpath oldpath errs} {
	variable busy
	set busy 0
	if {$newpath ne $oldpath && ![file exists $oldpath]} { openwith::moved $oldpath $newpath }
	edit_end
	if {$done ne ""} { uplevel #0 [list {*}$done $newpath $errs] }
	redraw_now
}

# The preview of the edit view: the same as the view's.
proc inspector::preview {P y F} {
	set path [dict get $F path]
	switch [kind $F] {
		image { return [picture $P $y $path 160] }
		folder {
			upvar #0 facts::W W
			set names {}
			if {[info exists W(newest)]} { foreach p [lrange $W(newest) 0 4] { lappend names [lindex $p 1] } }
			return [mosaic $P $y $names 160]
		}
		text { return [code_box $P $y [dict get [facts::text_info $path 12] head] 250] }
	}
	return $y
}

# A key of a layout dict, or its default (the window's layout sets rowp, ddw and rules).
proc inspector::opt_keyw {} { variable keyw; return $keyw }
proc inspector::opt {P key def} { if {[dict exists $P $key]} { return [dict get $P $key] }; return $def }

# The edit view: the preview, the name field, the kind line, Access, Opens with, the foot.
# Returns the panel's foot.
proc inspector::edit_draw {P y F} {
	array set c [array get ui::c]
	set cx [dict get $P cx]; set cw [dict get $P cw]
	if {[dict get $P preview]} { set y [preview $P $y $F] }
	set ny [expr {$y + 14}]
	w::namefield insp.name $cx $ny $cw inspector::apply_now inspector::name_key
	set sub [expr {[dict get $F isdir] ? "Folder" : "[dict get $F typename] · [facts::human [dict get $F size]]"}]
	ui::text $cx [expr {$ny + 52}] [clip i13 $sub $cw] i13 $c(muted)
	set y [edit_access $P [expr {$ny + 70}] $F]
	if {![dict get $F isdir]} { set y [edit_opens $P $y $F] }
	return [edit_footer $P $y]
}

# Access: Owner, You, Group, Everyone, and Run as program for a file (not for an image: it
# means nothing there). A row that differs has its undo and its label in bold. Returns the y
# below the last row.
proc inspector::edit_access {P y F} {
	variable E
	variable E0
	array set c [array get ui::c]
	set cx [dict get $P cx]; set cw [dict get $P cw]
	set ry [expr {[section $P $y Access] - 5}]
	set rp [opt $P rowp 40]; set dw [opt $P ddw 139]; set rules [opt $P rules 0]
	set ex [expr {$cx + $cw - $dw}]
	foreach {k icon label} {owner user Owner u user You g users Group o globe Everyone} {
		set changed [expr {$E($k) ne $E0($k)}]
		ui::icon $icon 14 [expr {$changed ? $c(fg) : $c(muted)}] [expr {$cx + 1}] [expr {$ry + 11}] 2
		ui::text [expr {$cx + 24}] [expr {$ry + 10}] $label [expr {$changed ? "i13m" : "i13"}] [expr {$changed ? $c(fg) : $c(muted)}]
		if {$k eq "owner"} {
			set items [lmap u [owners] { list $u $u "" }]
		} else {
			set items [levels]
		}
		if {$changed} { w::undo [expr {$ex - 34}] [expr {$ry + 5}] [list inspector::undo $k] }
		w::dropdown insp.$k $ex $ry $dw 36 $items $E($k) [list inspector::pick $k]
		if {$rules} { ui::hline $cx [expr {$cx + $cw}] [expr {$ry + $rp - 1}] $c(border) }
		incr ry $rp
	}
	if {![dict get $F isdir] && [kind $F] ne "image"} {
		set changed [expr {$E(x) ne $E0(x)}]
		ui::icon terminal 14 [expr {$changed ? $c(fg) : $c(muted)}] [expr {$cx + 1}] [expr {$ry + 11}] 2
		ui::text [expr {$cx + 24}] [expr {$ry + 10}] "Run as program" i13 [expr {$changed ? $c(fg) : $c(muted)}]
		w::switch_ insp.x [expr {$cx + $cw - 38}] [expr {$ry + 7}] $E(x) [list inspector::toggle_run]
		incr ry $rp
	}
	return $ry
}

# Opens with: the file's apps, the chosen one checked and tinted. Returns the y below.
proc inspector::edit_opens {P y F} {
	variable E
	array set c [array get ui::c]
	set cx [dict get $P cx]; set cw [dict get $P cw]
	set ry [expr {[section $P $y "Opens with"] - 5}]
	set rp [opt $P rowp 40]
	lassign [facts::handlers [dict get $F mime]] def others
	set ids {}
	if {$def ne ""} { lappend ids $def }
	lappend ids {*}$others
	# the rows stop above the footer's rule (a machine with many apps shows the first ones)
	set limit [expr {[dict get $P y] + [dict get $P h] - 154}]
	foreach id $ids {
		if {$ry > $limit} break
		if {$id eq $E(opens)} {
			ui::box [expr {$cx - 8}] $ry [expr {$cw + 16}] 40 -fill $c(field) -radius 10
			ui::icon check 14 $c(accent) [expr {$cx + $cw - 14}] [expr {$ry + 13}] 2.4
		}
		ui::box [expr {$cx + 8}] [expr {$ry + 9}] 22 22 -fill $c(pill) -radius 6
		ui::icon [facts::app_icon $id] 13 $c(fg) [expr {$cx + 12.5}] [expr {$ry + 13.5}] 1.9
		ui::text [expr {$cx + 38}] [expr {$ry + 12}] [facts::app_name $id] [expr {$id eq $E(opens) ? "i13m" : "i13"}] $c(fg)
		ui::hit [expr {$cx - 8}] $ry [expr {$cw + 16}] 40 [list inspector::pick_app $id]
		incr ry $rp
	}
	# "Every Rust file" (a language) or "Every JPEG image" (the type's name): on is the type's default, off is this file only
	set lang [facts::language [dict get $F path]]
	set noun [expr {$lang ne "" ? "$lang file" : [dict get $F typename]}]
	ui::hline $cx [expr {$cx + $cw}] [expr {$ry + 4}] $c(border)
	ui::text $cx [expr {$ry + 15}] "Every $noun" i13 $c(fg)
	w::switch_ insp.every [expr {$cx + $cw - 38}] [expr {$ry + 9}] $E(every) [list inspector::toggle_every]
	incr ry $rp
	return $ry
}

# Revert and Apply. Pinned (Files): at the panel's foot, with no rule. Follow (the viewer): 20
# under the content Y, over a rule the column's width, as the view footer does. Returns the
# foot of the panel (pinned) or the y the footer ends at (follow).
proc inspector::edit_footer {P {y ""}} {
	array set c [array get ui::c]
	set cx [dict get $P cx]; set cw [dict get $P cw]
	set follow [expr {[opt $P footer pinned] eq "follow"}]
	if {$follow} {
		set ty [expr {$y + 20}]
		ui::hline $cx [expr {$cx + $cw}] $ty $c(border)
		set by [expr {$ty + 14}]
	} else {
		set by [expr {[dict get $P y] + [dict get $P h] - 54}]
	}
	set ax [expr {$cx + $cw - [ui::button_w Apply primary check]}]
	ui::button insp.apply $ax $by Apply primary [list inspector::apply_now] check
	set rw [ui::button_w Revert ghost undo]
	ui::button insp.revert [expr {$ax - 10 - $rw}] $by Revert ghost [list inspector::revert] undo
	return [expr {$follow ? $by + 38 : [dict get $P y] + [dict get $P h]}]
}

# ---- the footer's menus (view mode) -------------------------------------------------------

# Nothing to pick (a folder's Opens with).
proc inspector::noop {args} {}

# Access, from the footer: the others' level, as the edit view's rows make it (r and w, x as it
# was; a folder's x follows its read). The job runs through fp::run_jobs; DONE gets the errors.
proc inspector::pick_others {path key} {
	variable bits
	variable done
	if {[catch {facts::of $path} F]} return
	set m [dict get $F mode]
	set b [dict get $bits $key]
	set x [expr {[dict get $F isdir] ? ($b ? 1 : 0) : ($m & 1)}]
	set new [expr {($m & 07770) | ($b | $x)}]
	if {$new == $m} { redraw_now; return }
	fp::run_jobs [list [list chmod [format %04o $new] $path]] [list inspector::after_pick $path $done]
}

proc inspector::after_pick {path done errs} {
	variable notice
	set notice [lindex $errs 0]
	if {$done ne ""} { uplevel #0 [list {*}$done $path $errs] }
	redraw_now
}

# Opens with, from the footer: this file's own choice.
proc inspector::pick_opener {path id} {
	variable notice
	set notice ""
	if {[catch {openwith::choose $path $id} err]} { set notice $err }
	redraw_now
}

# "Photos open in" and "Video opens in": the type's default, as Properties' General page sets it.
proc inspector::pick_kind {mime id} {
	variable notice
	set notice ""
	if {[catch {facts::set_default $mime $id} err]} { set notice $err }
	redraw_now
}

# The window's footer: one row of two dropdowns across the whole width, under a rule at Y
# (Access at the left, Opens with at the right, key labels as the board sets them). ROWS as
# draw's footer rows.
proc inspector::foot_row {W y rows} {
	array set c [array get ui::c]
	ui::hline 0 $W $y $c(border)
	set ry [expr {$y + 18}]
	set k 0
	foreach r $rows {
		lassign $r key lead text muted menu
		if {$k == 0} {
			ui::text 24 [expr {$ry + 10}] $key i13 $c(muted)
			set dx [expr {24 + [ui::measure i13 $key] + 12}]
			set dw [expr {295 - $dx}]
		} else {
			ui::text 312 [expr {$ry + 10}] $key i13 $c(muted)
			set dx 424; set dw 264
		}
		dropdown $dx $ry $dw 36 $lead $text $muted $menu
		incr k
	}
}

# "4 JPEG images · 1 file": the kinds of a selection, as the multi view's line under its count.
proc inspector::multi_words {items} {
	set kinds {}; set jpegs {}; set pics {}
	foreach F $items {
		lappend kinds [kind $F]
		lappend jpegs [expr {[dict get $F mime] eq "image/jpeg"}]
		if {[kind $F] eq "image"} { lappend pics [dict get $F path] }
	}
	set words {}
	foreach {k sing plur} {image {image images} file {file files} folder {folder folders}} {
		set m [llength [lsearch -all -exact $kinds $k]]
		if {$m} {
			set name [lindex $sing [expr {$m == 1 ? 0 : 1}]]
			if {$k eq "image" && [llength [lsearch -all -exact $jpegs 1]] == [llength $pics]} { set name [expr {$m == 1 ? "JPEG image" : "JPEG images"}] }
			lappend words "$m $name"
		}
	}
	return [join $words " · "]
}
