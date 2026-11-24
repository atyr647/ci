# well.tcl - Text editor (U26): the Well gutter (Editor-Final-1: 72 wide, a black tint, numbers in SYN_NUM0, the
# current line raised in a 44 x 18 pill) and the status line (Ln, Col, selection, language, indent, encoding,
# line ending on the left; the path on the right). STYLE §20.
#
# The gutter is a Tk canvas placed at (0, 46) beside the text widget. Numbers are drawn from the text widget's
# dlineinfo, so they stay on their lines when the text scrolls by pixels. Hooks that draw on the gutter later
# (change bars, folds, diagnostics) get the same visible-line list: see hooks.tcl.

namespace eval well {
	variable pillkey ""
	variable pillimg ""
}

# A colour mixed: t of b over a (both #rrggbb).
proc well::mix {a b t} {
	foreach {ar ag ab} [scan_rgb $a] {}
	lassign [scan_rgb $b] br bg bb
	set out "#"
	foreach x [list $ar $ag $ab] y [list $br $bg $bb] {
		append out [format %02x [expr {int($x * (1 - $t) + $y * $t + 0.5)}]]
	}
	return $out
}

proc well::scan_rgb {hex} {
	scan [string range $hex 1 end] %2x%2x%2x r g b
	list $r $g $b
}

# The gutter's canvas background: the bar with a black tint, the rest of the look is the theme's.
proc well::background {} {
	mix $editor::c(bar) #000000 $editor::c(well_alpha)
}

# The visible document lines: {line y} for each line on screen, from dlineinfo.
proc well::visible {t} {
	set out {}
	set first [lindex [split [$t index @0,0] .] 0]
	set last [lindex [split [$t index @0,[expr {[winfo height $t] - 1}]] .] 0]
	for {set n $first} {$n <= $last} {incr n} {
		set info [$t dlineinfo $n.0]
		# an elided line (a folded block's) has a box of height 0
		if {$info eq "" || [lindex $info 3] == 0} continue
		lappend out [list $n [lindex $info 1]]
	}
	return $out
}

proc well::paint {} {
	set g [editor::gutw $split::cur]
	if {![winfo exists $g]} return
	set id $editor::active
	$g delete all
	set bg [background]
	$g configure -background $bg
	$g create rectangle 0 0 $editor::WELL [winfo height $g] -fill $bg -outline ""
	if {$id eq ""} return
	set t [editor::tw $id]
	set cur [lindex [split [$t index insert] .] 0]
	set numc $editor::c(syn_num0)
	foreach row [visible $t] {
		lassign $row n y
		if {$n == $cur} {
			pill_at $g $y $bg
			text::draw $g 48 [expr {$y + 2}] ui_i12 $editor::c(fg) $n ne
		} else {
			text::draw $g 48 [expr {$y + 2}] ui_i12 $numc $n ne
		}
	}
	hooks_gutter $g
}

# The current line's pill: a 44 x 18 rounded box in PILL, made once per colour set.
proc well::pill_at {g y bg} {
	variable pillkey
	variable pillimg
	set key [list $bg $editor::c(pill)]
	if {$key ne $pillkey} {
		if {$pillimg ne ""} { catch {image delete $pillimg} }
		set pillimg [image create photo -width 44 -height 18]
		$pillimg put $bg -to 0 0 44 18
		raster::box $pillimg 0 0 44 18 -fill $editor::c(pill) -radius 6
		set pillkey $key
	}
	$g create image 4 [expr {$y - 1}] -image $pillimg -anchor nw
}

# The status line of pane P, at the bottom of the pane (y 748 to 780). Its caret is the pane's own.
proc well::status {p} {
	set id [split::val $p active]
	set x0 [split::px $p]
	set pw [split::pw $p]
	set y [expr {$editor::H - 32}]
	ui::box $x0 $y $pw 32 -fill $editor::c(bar)
	if {$id eq ""} return
	set t [editor::tw $id $p]
	lassign [split [$t index insert] .] line col
	set items [list "Ln $line, Col [expr {$col + 1}]"]   ;# in FG while the window has the focus (Editor-Final-1/-7)
	set sel [$t tag ranges sel]
	if {[llength $sel]} { lappend items "[$t count -chars {*}[lrange $sel 0 1]] selected" }
	lappend items [doc::lang $id] [doc::indent_label $id] [doc::encoding_label $id] $doc::D($id,eol)
	if {$doc::D($id,conflict)} { lappend items "Changed on disk" }
	set x [expr {$x0 + 16}]
	set k 0
	foreach s $items {
		set col [expr {$k == 0 && $editor::winfocus && $p == $split::cur ? $editor::c(fg) : $editor::c(muted)}]
		ui::text $x [expr {$y + 8}] $s i12 $col
		incr k
		set x [expr {$x + [ui::measure i12 $s] + 20}]
	}
	set path [doc::folder $id]
	set path [expr {$doc::D($id,untitled) ? "" : "$path/[file tail $doc::D($id,path)]"}]
	if {$doc::D($id,untitled)} { set path [doc::name $id] }
	set tw [ui::measure i12 $path]
	diag::status $id [expr {$x0 + $pw - 16 - $tw - 20}] [expr {$y + 8}]
	ui::text [expr {$x0 + $pw - 16 - $tw}] [expr {$y + 8}] $path i12 $editor::c(muted)
}

# the gutter hooks: the change bars and folds (U28) and the diagnostics (U32), gutter.tcl
proc well::hooks_gutter {g} {
	editor::gutter_draw $g
}
