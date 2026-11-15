# palette.tcl - Ribbon colour schemes as data: reading and strictly checking
# a palette file, writing one, the colour roles the Appearance app edits,
# the keys that follow them, and colour maths (HSV, HSL, WCAG contrast).
# Plain Tcl (no Tk), so the tests can use it with tclsh.
#
# A palette file is KEY=VALUE lines (see themes/palettes/ribbon.conf).
# It is never sourced or evaluated here: every line is matched against the
# keys Ribbon knows and the kind of value each takes, the same rules as the
# login helper (bin/ribbon-login-theme) applies before it installs one.

namespace eval pal {
	# key -> kind, in the order a written file lists them
	variable KEYS {
		NAME text
		BAR colour FIELD colour PILL colour BORDER colour FG colour MUTED colour
		ACCENT colour ACCENT2 colour INK colour CLOCK colour OK colour WARN colour CRIT colour
		DESK_TOP colour DESK_BOTTOM colour DESK_STRIPE colour DESK_STRIPE_ALPHA alpha
		DESK_MARK colour DESK_MARK_ALPHA alpha
		ON_ACCENT colour WIN colour BAR_SHADOW shadow
		GTK_THEME word ICON_THEME word BG colour SURFACE colour SURFACE2 colour
		SYN_KW colour SYN_FN colour SYN_VAR colour SYN_STR colour SYN_NUM colour
		SYN_COM colour SYN_OPT colour SYN_PUN colour SYN_NUM0 colour
		LINE colour VADD colour VMOD colour VDEL colour ERR colour
		MATCH colour MATCH_ALPHA alpha WELL colour WELL_ALPHA alpha
	}
	# The roles on the Colours page, in five groups (STYLE §22): the group's
	# title, then its roles as key, label, the alpha key if it has one. BAR_SHADOW
	# is a shadow (DY BLUR ALPHA #RRGGBB), not a colour; BG, SURFACE and SURFACE2
	# are not roles (their copies are kept below).
	# What each drives (ribbon-theme's templates, the shell, the greeter, the editor):
	#   ACCENT      highlights, the clock's colon, focused fields, folder icons
	#   FG          text everywhere (also the terminal's foreground)
	#   MUTED       secondary text and icons
	#   ON_ACCENT   text and marks drawn on the accent
	#   BAR         the bars, menus, window title bars (labwc), GTK headers
	#   FIELD       fields, the selected row, buttons
	#   PILL        pills, toggles' tracks, the terminal's selection
	#   BORDER      hairlines around bars, menus and windows
	#   WIN         window backgrounds (GTK)
	#   DESK_TOP, DESK_BOTTOM   the wallpaper's gradient (also the login screen)
	#   BAR_SHADOW  the shadow under the bars (box-shadow: 0 DY BLUR rgba)
	#   DESK_STRIPE (+ ALPHA)   the wallpaper's diagonal stripes
	#   SYN_*, LINE, WELL, MATCH, ERR, VADD, VMOD, VDEL: the editor and its diffs
	variable GROUPS {
		Interface {ACCENT Accent {} ACCENT2 {Second accent} {} ON_ACCENT {Text on accent} {} FG Text {}
			MUTED {Muted text} {} CLOCK Clock {} BAR Bars {} BAR_SHADOW {Bar shadow} {} WIN Windows {}
			FIELD Fields {} PILL Pills {} BORDER Borders {}}
		Status {INK Links {} OK OK {} WARN Warning {} CRIT Critical {}}
		Desktop {DESK_TOP {Wallpaper top} {} DESK_BOTTOM {Wallpaper bottom} {}
			DESK_STRIPE Stripes DESK_STRIPE_ALPHA DESK_MARK Wordmark DESK_MARK_ALPHA}
		Code {SYN_KW Keywords {} SYN_FN Functions {} SYN_VAR Variables {} SYN_STR Strings {}
			SYN_NUM Numbers {} SYN_OPT Options {} SYN_PUN Brackets {} SYN_COM Comments {}}
		{Editor and diffs} {SYN_NUM0 {Line numbers} {} WELL Gutter WELL_ALPHA LINE {Current line} {}
			MATCH Matches MATCH_ALPHA ERR Errors {} VADD Added {} VMOD Changed {} VDEL Removed {}}
	}
	# every role, in list order (the Colours page's keys and labels come from here)
	variable ROLES {}
	foreach {title roles} $GROUPS { lappend ROLES {*}$roles }
	# A key that copies another (the Colours page shows it as linked until it is
	# edited; the reset button links it again): key source
	variable LINKS {CLOCK FG DESK_MARK DESK_STRIPE}
	# Keys that are copies of another (ribbon-theme reads them, the built-in
	# schemes keep them equal): they follow their source when it changes,
	# as long as they were equal to it.
	variable DERIVED {
		BG BAR SURFACE FIELD SURFACE2 PILL CLOCK FG DESK_MARK DESK_STRIPE
	}
	# Graphite, for any key a palette leaves out
	variable BASE {
		NAME Graphite BAR #1D1C1B FIELD #2A2826 PILL #36302C BORDER #3B3835
		FG #EEE9E3 MUTED #A49D95 ACCENT #FF7A59 ACCENT2 #FFB199 INK #8AB4F8
		CLOCK #EEE9E3 OK #8FD694 WARN #F2C14E CRIT #FF5C5C DESK_TOP #2B2825
		DESK_BOTTOM #121110 DESK_STRIPE #FFFFFF DESK_STRIPE_ALPHA 0.03
		DESK_MARK #FFFFFF DESK_MARK_ALPHA 0.065 ON_ACCENT #1A0F0B WIN #232120
		BAR_SHADOW {6 20 0.35 #000000} GTK_THEME Adwaita-dark ICON_THEME Papirus-Dark
		BG #1D1C1B SURFACE #2A2826 SURFACE2 #36302C
		SYN_KW #E3B580 SYN_FN #F2ECE5 SYN_VAR #8EC3C8 SYN_STR #A9C79A SYN_NUM #F29B7E
		SYN_COM #7A746D SYN_OPT #BDB4AA SYN_PUN #8F877F SYN_NUM0 #5E5852 LINE #242220
		VADD #8DB07C VMOD #7EA6C4 VDEL #E07A6A ERR #EC6A5E MATCH #EEE9E3 MATCH_ALPHA 0.10
		WELL #000000 WELL_ALPHA 0.20
	}
	# the keys a theme must give to be imported (the rest can be filled in)
	variable REQUIRED {BAR FIELD PILL BORDER FG MUTED ACCENT DESK_TOP DESK_BOTTOM}
	variable MAX_BYTES 16384
}

# ---- checking -----------------------------------------------------------------

proc pal::check_value {kind v} {
	set A {(?:0|1|0?\.[0-9]{1,4}|1\.0{1,4})}
	switch -- $kind {
		colour { return [regexp {^#[0-9A-Fa-f]{6}$} $v] }
		alpha  { return [regexp "^$A\$" $v] }
		shadow {
			if {![regexp "^(-?\[0-9\]{1,2}) (\[0-9\]{1,2}) ${A}(?: (#\[0-9A-Fa-f\]{6}))?\$" $v -> dy blur]} { return 0 }
			return [expr {abs($dy) <= 32 && $blur <= 48}]
		}
		word   { return [regexp {^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$} $v] }
		text   { return [valid_name $v] }
	}
	return 0
}

# A theme's name: up to 48 printable characters, no quotes, backslashes,
# $ or backquotes (ribbon-theme's templates are filled in with sed, and
# NAME="..." must stay one shell word).
proc pal::valid_name {v} {
	expr {[string length $v] <= 48 && [string trim $v] ne "" && [regexp {^[[:print:]]+$} $v] && ![regexp {["'\\$`|]} $v]}
}

# BYTES (a file's contents) as a palette dict, or an error naming the first
# bad line. Only known keys, each once, each with a value of its kind.
proc pal::parse {bytes} {
	variable KEYS
	variable MAX_BYTES
	if {[string length $bytes] > $MAX_BYTES} { error "it is too big for a theme (at most $MAX_BYTES bytes)" }
	if {[string first \0 $bytes] >= 0} { error "it is not a text file" }
	set text [encoding convertfrom utf-8 $bytes]
	if {[encoding convertto utf-8 $text] ne $bytes} { error "it is not UTF-8 text" }
	set p [dict create]
	set n 0
	foreach line [split $text \n] {
		incr n
		set line [string trimright $line \r]
		if {[regexp {[\x00-\x08\x0a-\x1f\x7f]} $line]} { error "line $n: control characters" }
		set line [string trim $line " \t"]
		if {$line eq "" || [string index $line 0] eq "#"} continue
		if {![regexp {^([A-Za-z0-9_]+)=(.*)$} $line -> k v]} { error "line $n: not KEY=VALUE" }
		if {![dict exists $KEYS $k]} { error "line $n: unknown key '$k'" }
		if {[dict exists $p $k]} { error "line $n: $k is given twice" }
		if {[regexp {^"([^"]*)"$} $v -> inner] || [regexp {^'([^']*)'$} $v -> inner]} { set v $inner }
		set kind [dict get $KEYS $k]
		if {![check_value $kind $v]} {
			error "line $n: $k: [dict get {colour {not a colour (#RRGGBB)} alpha {not a number from 0 to 1}
				shadow {not a shadow (DY BLUR ALPHA #RRGGBB)} word {not a theme name} text {not a name (up to 48 characters, no quotes)}} $kind]"
		}
		if {$kind eq "colour"} { set v [string toupper $v] }
		dict set p $k $v
	}
	return $p
}

# A palette to import: parsed, with every key a theme needs, the rest
# filled in from its sources or from Graphite.
proc pal::parse_theme {bytes} {
	variable REQUIRED
	set p [parse $bytes]
	set missing {}
	foreach k $REQUIRED { if {![dict exists $p $k]} { lappend missing $k } }
	if {[llength $missing]} { error "it is not a Ribbon theme (no [join $missing {, }])" }
	complete $p
}

# Fill in the keys P lacks: copies from their sources, else Graphite's.
proc pal::complete {p} {
	variable BASE
	variable DERIVED
	foreach {k src} $DERIVED {
		if {![dict exists $p $k] && [dict exists $p $src]} { dict set p $k [dict get $p $src] }
	}
	if {![dict exists $p ON_ACCENT]} { dict set p ON_ACCENT [dict get $p BAR] }
	if {![dict exists $p WIN]} { dict set p WIN [dict get $p FIELD] }
	dict for {k v} $BASE { if {![dict exists $p $k]} { dict set p $k $v } }
	return $p
}

# Read FILE (at most MAX_BYTES), checked; errors say what is wrong.
proc pal::read {file} {
	variable MAX_BYTES
	set fh [open $file rb]
	set d [::read $fh [expr {$MAX_BYTES + 1}]]
	close $fh
	parse $d
}

# ---- writing --------------------------------------------------------------------

proc pal::format {p {comment ""}} {
	variable KEYS
	set out ""
	foreach line [split $comment \n] { if {$line ne ""} { append out "# $line\n" } }
	foreach {k kind} $KEYS {
		if {![dict exists $p $k]} continue
		set v [dict get $p $k]
		if {$kind in {text shadow}} { set v "\"$v\"" }
		append out "$k=$v\n"
	}
	return $out
}

# Write P to FILE atomically (a new file beside it, renamed over it).
proc pal::write {file p {comment ""}} {
	file mkdir [file dirname $file]
	set tmp $file.[pid].tmp
	set fh [open $tmp {WRONLY CREAT TRUNC} 0644]
	puts -nonewline $fh [format $p $comment]
	close $fh
	file rename -force -- $tmp $file
}

# P with KEY set to V, and the keys that follow KEY (and were equal to
# it, and are not UNLINKED) set too.
proc pal::set_key {p key v {unlinked {}}} {
	variable DERIVED
	set old [expr {[dict exists $p $key] ? [dict get $p $key] : ""}]
	foreach {k src} $DERIVED {
		if {$src eq $key && $k ni $unlinked && (![dict exists $p $k] || [string equal -nocase [dict get $p $k] $old])} { dict set p $k $v }
	}
	dict set p $key $v
}

# An alpha as the palette writes it: at most 4 decimals, no trailing zeros
proc pal::alpha_str {a} {
	set s [string trimright [::format %.4f $a] 0]
	set s [string trimright $s .]
	if {$s eq ""} { set s 0 }
	return $s
}

# A BAR_SHADOW value ("DY BLUR ALPHA #RRGGBB") as {dy blur alpha colour};
# the colour is black when the value leaves it out.
proc pal::shadow {v} {
	lassign $v dy blur a c
	if {$c eq ""} { set c #000000 }
	list $dy $blur $a $c
}
proc pal::shadow_make {dy blur a c} {
	list $dy $blur [alpha_str $a] [string toupper $c]
	return "$dy $blur [alpha_str $a] [string toupper $c]"
}

# ---- colour maths -------------------------------------------------------------------

proc pal::rgb {hex} {
	scan [string range $hex 1 end] %2x%2x%2x r g b
	list $r $g $b
}
proc pal::hex {r g b} {
	::format #%02X%02X%02X [clamp255 $r] [clamp255 $g] [clamp255 $b]
}
proc pal::clamp255 {v} { expr {max(0, min(255, int(round($v))))} }

# r g b 0..255 -> h 0..360, s v 0..1
proc pal::rgb2hsv {r g b} {
	set r [expr {$r / 255.0}]; set g [expr {$g / 255.0}]; set b [expr {$b / 255.0}]
	set mx [expr {max($r, $g, $b)}]; set mn [expr {min($r, $g, $b)}]; set d [expr {$mx - $mn}]
	set h 0.0
	if {$d > 0} {
		if {$mx == $r} { set h [expr {60 * fmod(($g - $b) / $d + 6, 6)}] } \
		elseif {$mx == $g} { set h [expr {60 * (($b - $r) / $d + 2)}] } \
		else { set h [expr {60 * (($r - $g) / $d + 4)}] }
	}
	list $h [expr {$mx > 0 ? $d / $mx : 0.0}] $mx
}
proc pal::hsv2rgb {h s v} {
	set h [expr {fmod(fmod($h, 360) + 360, 360)}]
	set c [expr {$v * $s}]; set x [expr {$c * (1 - abs(fmod($h / 60.0, 2) - 1))}]; set m [expr {$v - $c}]
	switch [expr {int($h / 60) % 6}] {
		0 { lassign [list $c $x 0] r g b } 1 { lassign [list $x $c 0] r g b } 2 { lassign [list 0 $c $x] r g b }
		3 { lassign [list 0 $x $c] r g b } 4 { lassign [list $x 0 $c] r g b } 5 { lassign [list $c 0 $x] r g b }
	}
	list [expr {($r + $m) * 255}] [expr {($g + $m) * 255}] [expr {($b + $m) * 255}]
}
proc pal::rgb2hsl {r g b} {
	set r [expr {$r / 255.0}]; set g [expr {$g / 255.0}]; set b [expr {$b / 255.0}]
	set mx [expr {max($r, $g, $b)}]; set mn [expr {min($r, $g, $b)}]; set d [expr {$mx - $mn}]
	set l [expr {($mx + $mn) / 2.0}]
	set h [lindex [rgb2hsv [expr {$r * 255}] [expr {$g * 255}] [expr {$b * 255}]] 0]
	set s [expr {$d == 0 ? 0.0 : $d / (1 - abs(2 * $l - 1))}]
	list $h $s $l
}
proc pal::hsl2rgb {h s l} {
	set c [expr {(1 - abs(2 * $l - 1)) * $s}]
	set v [expr {$l + $c / 2.0}]
	set sv [expr {$v == 0 ? 0.0 : $c / $v}]
	hsv2rgb $h $sv $v
}

# WCAG 2 relative luminance and contrast ratio
proc pal::luminance {hex} {
	set L 0.0
	foreach v [rgb $hex] k {0.2126 0.7152 0.0722} {
		set v [expr {$v / 255.0}]
		set v [expr {$v <= 0.03928 ? $v / 12.92 : pow(($v + 0.055) / 1.055, 2.4)}]
		set L [expr {$L + $k * $v}]
	}
	return $L
}
proc pal::contrast {a b} {
	set la [luminance $a]; set lb [luminance $b]
	expr {(max($la, $lb) + 0.05) / (min($la, $lb) + 0.05)}
}
# The WCAG level for normal text: AAA (7:1), AA (4.5:1), AA large (3:1)
proc pal::level {ratio} {
	if {$ratio >= 7} { return AAA }
	if {$ratio >= 4.5} { return AA }
	if {$ratio >= 3} { return "AA large" }
	return "too low"
}
# "7.3:1" (one decimal, rounded down so 4.49 never reads as 4.5)
proc pal::ratio_text {ratio} {
	::format %.1f:1 [expr {floor($ratio * 10) / 10.0}]
}

# The contrast checks shown under the preview for a text role: {label fg-key bg-key}.
# Roles that are not text (fills, borders, the wordmark, the stripes) have none.
proc pal::checks {role} {
	variable ROLES
	set tbl {
		ACCENT {{{Text on accent} ON_ACCENT ACCENT} {{Accent on bars} ACCENT BAR}}
		ACCENT2 {{{Second accent on bars} ACCENT2 BAR}}
		FG {{{Text on bars} FG BAR} {{Text on fields} FG FIELD}}
		MUTED {{{Muted on bars} MUTED BAR} {{Muted on fields} MUTED FIELD}}
		ON_ACCENT {{{Text on accent} ON_ACCENT ACCENT}}
		CLOCK {{{Clock on wallpaper} CLOCK DESK_TOP}}
		BAR {{{Text on bars} FG BAR} {{Accent on bars} ACCENT BAR}}
		FIELD {{{Text on fields} FG FIELD} {{Muted on fields} MUTED FIELD}}
		PILL {{{Text on pills} FG PILL}}
		BORDER {{{Borders on bars} BORDER BAR}}
		WIN {{{Text on windows} FG WIN}}
		DESK_TOP {{{Clock on wallpaper} FG DESK_TOP}}
		DESK_BOTTOM {{{Text on wallpaper} FG DESK_BOTTOM}}
		INK {{{Links on bars} INK BAR}}
		OK {{{OK on bars} OK BAR}}
		WARN {{{Warning on bars} WARN BAR}}
		CRIT {{{Critical on bars} CRIT BAR}}
	}
	if {[dict exists $tbl $role]} { return [dict get $tbl $role] }
	# the code tokens and the editor's diff marks: against the editor, and the current line
	if {[string match SYN_* $role] && $role ne "SYN_NUM0"} {
		foreach {k l a} $ROLES { if {$k eq $role} { set label $l } }
		return [list [list "$label on editor" $role BAR] [list {On current line} $role LINE]]
	}
	if {$role in {ERR VADD VMOD VDEL}} {
		foreach {k l a} $ROLES { if {$k eq $role} { set label $l } }
		return [list [list "$label on editor" $role BAR]]
	}
	return {}
}
