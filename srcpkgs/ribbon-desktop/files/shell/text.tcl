# text.tcl - Ribbon's text: fonts at the weights the mockups use, and each
# letter where a browser puts it. Shared by the shell, the login screen
# (greeter/), the installer and the Appearance app: source it from
# /usr/lib/ribbon/shell before any font is used.
#
# Two things Tk 8.6 gets wrong on its own:
# - weights: Tk asks fontconfig for every "normal" font at weight 100,
#   which is Medium (500), and can't ask for 600 at all. fonts.conf (here,
#   installed as /etc/fonts/conf.d/30-ribbon-fonts.conf) gives Ribbon's
#   own family names the exact weights: "Ribbon Inter 400" ... "Ribbon
#   Space Grotesk 700", "Ribbon Mono". (Space Grotesk's variable font has
#   no 600 style; ribbon-desktop cuts one out at build time.)
# - placement: Tk rounds every advance to whole pixels and doesn't kern.
#   text::draw places letters itself, with advances from the font file's
#   'hmtx' and pair kerning from its GPOS 'kern' feature (and 'tnum' for
#   tabular figures), and puts a run of letters in one canvas item while
#   Tk's own advances keep each within half a pixel of its place.
#
#   text::font NAME FAMILY PX        a named Tk font (FAMILY: one of the above)
#   text::width FONT TEXT ?LS? ?TNUM?
#   text::draw CANVAS X Y FONT FILL TEXT ?ANCHOR? ?-ls N? ?-tnum 1? ?-tags T?
#   text::clip FONT TEXT WIDTH       TEXT cut to fit WIDTH
#
# ANCHOR is a Tk anchor (default w): its east/west part says where X is,
# its north/south part how Y is read (as Tk does: n top, s bottom, else the
# middle of the line).

namespace eval text {
	variable dir [file dirname [file normalize [info script]]]
	variable spec           ;# named font -> {family px}
	array set spec {}
	variable parsed         ;# family -> parsed font dict, or "" (Tk's advances)
	array set parsed {}
	variable files          ;# family -> font file (from fc-match, cached on disk)
	array set files {}
	variable lay            ;# layout cache
	array set lay {}
	variable tk             ;# Tk's own (whole-pixel) advances
	array set tk {}
	variable g              ;# glyph, advance and kerning caches
	array set g {}
}

# ---- Settings → Accessibility ---------------------------------------------------
# What Ribbon's own apps and the shell take from ~/.config/ribbon/access.conf (apps/settings/access.tcl writes it;
# ribbon-theme gives the toolkits the rest). Read again when the file changes, so a running app follows a change:
#   text::access          a dict: contrast, motion (HIGH_CONTRAST, REDUCE_MOTION: 0 or 1)
#   text::reduce_motion   1: an animation jumps to its end
#   text::high_contrast   1: muted text and rules drawn nearer the text colour (appearance/ui.tcl's ui::colours)
# Text size is not here: Ribbon's own windows are laid out to the pixel (their boards); it reaches the toolkits'
# apps and the terminal through ribbon-theme.

namespace eval text {
	variable acc {contrast 0 motion 0}
	variable acc_stamp ""
}
proc text::access {} {
	variable acc
	variable acc_stamp
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/"}]
	set cfg [expr {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne "" ? $::env(XDG_CONFIG_HOME) : "$home/.config"}]
	set f [file join $cfg ribbon access.conf]
	if {[catch {file stat $f st}]} { set m "" } else { set m "$st(mtime) $st(size) $st(ino)" }
	if {$m eq $acc_stamp} { return $acc }
	set acc_stamp $m
	set acc {contrast 0 motion 0}
	if {$m ne "" && ![catch {::open $f r} h]} {
		foreach line [split [::read $h] \n] {
			if {[regexp {^\s*(HIGH_CONTRAST|REDUCE_MOTION)=["']?(yes|no)["']?\s*$} $line -> k v]} {
				dict set acc [expr {$k eq "HIGH_CONTRAST" ? "contrast" : "motion"}] [expr {$v eq "yes"}]
			}
		}
		::close $h
	}
	return $acc
}
proc text::reduce_motion {} { dict get [access] motion }
proc text::high_contrast {} { dict get [access] contrast }

# ---- fontconfig ----------------------------------------------------------------
# Installed systems have the family names in /etc/fonts/conf.d. Elsewhere
# (the source tree, tests) this process reads fontconfig's configuration
# plus fonts.conf: set before Tk opens its first font, which is when
# fontconfig reads its configuration.
proc text::fontconfig {} {
	variable dir
	if {[file exists /etc/fonts/conf.d/30-ribbon-fonts.conf] || [info exists ::env(RIBBON_FONTS_CONF)]} return
	set base [expr {[info exists ::env(FONTCONFIG_FILE)] ? $::env(FONTCONFIG_FILE) : "/etc/fonts/fonts.conf"}]
	set xml "<?xml version=\"1.0\"?>\n<fontconfig>\n  <include ignore_missing=\"yes\">$base</include>\n  <include>[file join $dir fonts.conf]</include>\n</fontconfig>\n"
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}]
	foreach d [list [expr {[info exists ::env(XDG_RUNTIME_DIR)] ? $::env(XDG_RUNTIME_DIR) : ""}] \
			[expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$home/.cache"}] /tmp] {
		if {$d eq ""} continue
		set f [file join $d ribbon-fonts-[format %08x [zlib crc32 $xml]].conf]
		set tmp $f.[pid]
		if {[catch {file mkdir $d; set fh [open $tmp w]; puts -nonewline $fh $xml; close $fh; file rename -force $tmp $f}]} continue
		set ::env(RIBBON_FONTS_CONF) $f
		set ::env(FONTCONFIG_FILE) $f
		return
	}
}

text::fontconfig

# A named font: NAME at PX pixels.
proc text::font {name family px} {
	variable spec
	catch {::font delete $name}
	::font create $name -family $family -size -$px
	set spec($name) [list $family $px]
	return $name
}

# A named font for FAMILY at PX (made once), for code that thinks in
# families and sizes.
proc text::fontof {family px} {
	variable spec
	set name ::text::f[zlib crc32 $family/$px]
	if {![info exists spec($name)]} { font $name $family $px }
	return $name
}

proc text::spec {font} {
	variable spec
	if {![info exists spec($font)]} {
		set spec($font) [list [::font configure $font -family] [expr {abs([::font configure $font -size])}]]
	}
	return $spec($font)
}

# ---- which file fontconfig draws a family with ------------------------------------
# fc-match, once per family; the answers are kept in the drawing cache
# while fontconfig's configuration and font directories are unchanged.

proc text::stamp {} {
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/"}]
	set cfg [expr {[info exists ::env(XDG_CONFIG_HOME)] ? $::env(XDG_CONFIG_HOME) : "$home/.config"}]
	set data [expr {[info exists ::env(XDG_DATA_HOME)] ? $::env(XDG_DATA_HOME) : "$home/.local/share"}]
	set cache [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$home/.cache"}]
	set s [list [expr {[info exists ::env(RIBBON_FONTS_CONF)] ? "dev" : ""}]]
	foreach p [list /etc/fonts/conf.d /etc/fonts/fonts.conf /var/cache/fontconfig /usr/share/fonts \
			$cfg/fontconfig $data/fonts $home/.fonts $cache/fontconfig] {
		lappend s [expr {[catch {file mtime $p} t] ? 0 : $t}]
	}
	return $s
}

proc text::cachefile {} {
	if {[info commands ::raster::dir] ne ""} { return [file join [::raster::dir] fonts.list] }
	return ""
}

proc text::file_of {family} {
	variable files
	if {[info exists files($family)] && ($files($family) eq "" || [file readable $files($family)])} { return $files($family) }
	set cf [cachefile]
	if {![info exists files()] && $cf ne ""} {
		# the cache: first line the stamp, then family and file
		set files() 1
		if {![catch {open $cf} fh]} {
			set lines [split [read $fh] \n]; close $fh
			if {[lindex $lines 0] eq [stamp]} {
				foreach l [lrange $lines 1 end] { if {[llength $l] == 2} { set files([lindex $l 0]) [lindex $l 1] } }
				if {[info exists files($family)] && [file readable $files($family)]} { return $files($family) }
			}
		}
	}
	set files($family) ""
	if {[auto_execok fc-match] ne "" && ![catch {exec fc-match -f %{file} $family} path] && [file readable $path]} {
		set files($family) $path
	}
	if {$cf ne "" && ![catch {open $cf w} fh]} {
		puts $fh [stamp]
		foreach k [lsort [array names files]] { if {$k ne ""} { puts $fh [list $k $files($k)] } }
		close $fh
	}
	return $files($family)
}

# ---- the font file: cmap, hmtx, GPOS kerning, GSUB tabular figures --------------

proc text::u16 {d o} { binary scan $d @${o}Su v; return $v }
proc text::s16 {d o} { binary scan $d @${o}S v; return $v }
proc text::u32 {d o} { binary scan $d @${o}Iu v; return $v }
# (binary scan only: font data must stay byte arrays, never strings, or
# every read converts the whole table)
proc text::tag {d o} { binary scan $d @${o}a4 v; return $v }

# The parsed font for a family, or "" when its file can't be read.
proc text::parsed {family} {
	variable parsed
	if {[info exists parsed($family)]} { return $parsed($family) }
	set parsed($family) ""
	set path [file_of $family]
	if {$path eq ""} { return "" }
	if {[catch {parse $path} f]} { puts stderr "text: $path: $f"; return "" }
	set parsed($family) $f
}

# Only the tables used are read (of an Inter file's 600 KB, 140 KB).
proc text::parse {path} {
	set fh [open $path rb]
	try {
		set d [read $fh 12]
		set base 0
		if {[tag $d 0] eq "ttcf"} {
			set base [u32 $d 12]
			seek $fh $base; set d [read $fh 12]
		}
		set n [u16 $d 4]
		set dir [read $fh [expr {16 * $n}]]
		array set t {}
		for {set i 0} {$i < $n} {incr i} {
			set r [expr {16 * $i}]
			set t([tag $dir $r]) [list [u32 $dir [expr {$r + 8}]] [u32 $dir [expr {$r + 12}]]]
		}
		foreach k {head hhea hmtx cmap} { if {![info exists t($k)]} { error "no $k table" } }
		set tab {}
		foreach k {head hhea cmap hmtx GPOS GSUB} {
			if {[info exists t($k)]} { lassign $t($k) o l; seek $fh $o; dict set tab $k [read $fh $l] }
		}
	} finally {
		close $fh
	}
	set f [dict create upem [u16 [dict get $tab head] 18] nhm [u16 [dict get $tab hhea] 34] \
		hmtx [dict get $tab hmtx] cmapd [dict get $tab cmap]]
	dict set f cmap [cmap [dict get $tab cmap]]
	dict set f gpos ""; dict set f kern {}; dict set f tnum {}
	if {[dict exists $tab GPOS]} {
		dict set f gpos [dict get $tab GPOS]
		dict set f kern [lookups [dict get $tab GPOS] kern 2 9]
	}
	if {[dict exists $tab GSUB]} { dict set f tnum [tnum [dict get $tab GSUB]] }
	return $f
}

# The best Unicode cmap subtable: {format offset}.
proc text::cmap {d} {
	set best {}
	for {set i 0} {$i < [u16 $d 2]} {incr i} {
		set r [expr {4 + 8 * $i}]
		set pid [u16 $d $r]; set eid [u16 $d [expr {$r + 2}]]
		set off [u32 $d [expr {$r + 4}]]
		set fmt [u16 $d $off]
		if {$fmt == 12 && (($pid == 3 && $eid == 10) || $pid == 0)} { return [list 12 $off] }
		if {$fmt == 4 && (($pid == 3 && $eid == 1) || $pid == 0)} { set best [list 4 $off] }
	}
	if {$best eq ""} { error "no Unicode cmap" }
	return $best
}

proc text::gid {f ch} {
	set d [dict get $f cmapd]
	lassign [dict get $f cmap] fmt off
	scan $ch %c c
	if {$fmt == 12} {
		set lo 0; set hi [expr {[u32 $d [expr {$off + 12}]] - 1}]
		while {$lo <= $hi} {
			set m [expr {($lo + $hi) / 2}]
			set r [expr {$off + 16 + 12 * $m}]
			if {$c < [u32 $d $r]} { set hi [expr {$m - 1}] } elseif {$c > [u32 $d [expr {$r + 4}]]} { set lo [expr {$m + 1}] } else {
				return [expr {[u32 $d [expr {$r + 8}]] + $c - [u32 $d $r]}]
			}
		}
		return 0
	}
	if {$c > 0xffff} { return 0 }
	set segs [expr {[u16 $d [expr {$off + 6}]] / 2}]
	set ends [expr {$off + 14}]
	set starts [expr {$ends + 2 * $segs + 2}]
	set deltas [expr {$starts + 2 * $segs}]
	set ranges [expr {$deltas + 2 * $segs}]
	set lo 0; set hi [expr {$segs - 1}]
	while {$lo < $hi} {
		set m [expr {($lo + $hi) / 2}]
		if {[u16 $d [expr {$ends + 2 * $m}]] < $c} { set lo [expr {$m + 1}] } else { set hi $m }
	}
	set s $lo
	if {[u16 $d [expr {$ends + 2 * $s}]] < $c} { return 0 }
	set start [u16 $d [expr {$starts + 2 * $s}]]
	if {$start > $c} { return 0 }
	set delta [u16 $d [expr {$deltas + 2 * $s}]]
	set ro [u16 $d [expr {$ranges + 2 * $s}]]
	if {$ro == 0} { return [expr {($c + $delta) & 0xffff}] }
	set gl [u16 $d [expr {$ranges + 2 * $s + $ro + 2 * ($c - $start)}]]
	expr {$gl == 0 ? 0 : ($gl + $delta) & 0xffff}
}

proc text::advance {f gl} {
	set nhm [dict get $f nhm]
	if {$gl >= $nhm} { set gl [expr {$nhm - 1}] }
	u16 [dict get $f hmtx] [expr {4 * $gl}]
}

# The subtables of a GPOS/GSUB feature's lookups for Latin (or the default
# script), of lookup TYPE (EXT: the extension type that can wrap it), as a
# list of lists in lookup order.
proc text::lookups {d feature type ext} {
	set sl [u16 $d 4]; set fl [u16 $d 6]; set ll [u16 $d 8]
	set lang ""
	foreach want {latn DFLT} {
		for {set i 0} {$i < [u16 $d $sl]} {incr i} {
			set r [expr {$sl + 2 + 6 * $i}]
			if {[tag $d $r] ne $want} continue
			set s [expr {$sl + [u16 $d [expr {$r + 4}]]}]
			if {[u16 $d $s]} { set lang [expr {$s + [u16 $d $s]}] }
		}
		if {$lang ne ""} break
	}
	if {$lang eq ""} { return {} }
	set ls {}
	for {set i 0} {$i < [u16 $d [expr {$lang + 4}]]} {incr i} {
		set r [expr {$fl + 2 + 6 * [u16 $d [expr {$lang + 6 + 2 * $i}]]}]
		if {[tag $d $r] ne $feature} continue
		set ft [expr {$fl + [u16 $d [expr {$r + 4}]]}]
		for {set j 0} {$j < [u16 $d [expr {$ft + 2}]]} {incr j} { lappend ls [u16 $d [expr {$ft + 4 + 2 * $j}]] }
	}
	set out {}
	foreach li [lsort -integer -unique $ls] {
		set l [expr {$ll + [u16 $d [expr {$ll + 2 + 2 * $li}]]}]
		set subs {}
		for {set k 0} {$k < [u16 $d [expr {$l + 4}]]} {incr k} {
			set st [expr {$l + [u16 $d [expr {$l + 6 + 2 * $k}]]}]
			set t [u16 $d $l]
			if {$t == $ext} { set t [u16 $d [expr {$st + 2}]]; set st [expr {$st + [u32 $d [expr {$st + 4}]]}] }
			if {$t == $type} { lappend subs $st }
		}
		if {[llength $subs]} { lappend out $subs }
	}
	return $out
}

# GSUB 'tnum' single substitutions as a dict: glyph -> tabular glyph.
proc text::tnum {d} {
	set map {}
	foreach subs [lookups $d tnum 1 7] {
		foreach st $subs {
			set fmt [u16 $d $st]
			set cov [expr {$st + [u16 $d [expr {$st + 2}]]}]
			set i 0
			foreach gl [covered $d $cov] {
				if {![dict exists $map $gl]} {
					dict set map $gl [expr {$fmt == 1 ? ($gl + [s16 $d [expr {$st + 4}]]) & 0xffff : [u16 $d [expr {$st + 6 + 2 * $i}]]}]
				}
				incr i
			}
		}
	}
	return $map
}

# Every glyph of a coverage table, in coverage order.
proc text::covered {d c} {
	set out {}
	set n [u16 $d [expr {$c + 2}]]
	if {[u16 $d $c] == 1} {
		for {set i 0} {$i < $n} {incr i} { lappend out [u16 $d [expr {$c + 4 + 2 * $i}]] }
	} else {
		for {set i 0} {$i < $n} {incr i} {
			set r [expr {$c + 4 + 6 * $i}]
			for {set gl [u16 $d $r]} {$gl <= [u16 $d [expr {$r + 2}]]} {incr gl} { lappend out $gl }
		}
	}
	return $out
}

proc text::coverage {d c gl} {
	set n [u16 $d [expr {$c + 2}]]
	set lo 0; set hi [expr {$n - 1}]
	if {[u16 $d $c] == 1} {
		while {$lo <= $hi} {
			set m [expr {($lo + $hi) / 2}]
			set v [u16 $d [expr {$c + 4 + 2 * $m}]]
			if {$gl < $v} { set hi [expr {$m - 1}] } elseif {$gl > $v} { set lo [expr {$m + 1}] } else { return $m }
		}
		return -1
	}
	while {$lo <= $hi} {
		set m [expr {($lo + $hi) / 2}]
		set r [expr {$c + 4 + 6 * $m}]
		if {$gl < [u16 $d $r]} { set hi [expr {$m - 1}] } elseif {$gl > [u16 $d [expr {$r + 2}]]} { set lo [expr {$m + 1}] } else {
			return [expr {[u16 $d [expr {$r + 4}]] + $gl - [u16 $d $r]}]
		}
	}
	return -1
}

proc text::classof {d c gl} {
	if {[u16 $d $c] == 1} {
		set s [u16 $d [expr {$c + 2}]]; set n [u16 $d [expr {$c + 4}]]
		if {$gl < $s || $gl >= $s + $n} { return 0 }
		return [u16 $d [expr {$c + 6 + 2 * ($gl - $s)}]]
	}
	set lo 0; set hi [expr {[u16 $d [expr {$c + 2}]] - 1}]
	while {$lo <= $hi} {
		set m [expr {($lo + $hi) / 2}]
		set r [expr {$c + 4 + 6 * $m}]
		if {$gl < [u16 $d $r]} { set hi [expr {$m - 1}] } elseif {$gl > [u16 $d [expr {$r + 2}]]} { set lo [expr {$m + 1}] } else {
			return [u16 $d [expr {$r + 4}]]
		}
	}
	return 0
}

proc text::vsize {vf} {
	set n 0
	for {set b 0} {$b < 8} {incr b} { if {$vf & (1 << $b)} { incr n 2 } }
	return $n
}

# The x-advance adjustment in a value record (0 if none).
proc text::xadv {d r vf} {
	if {!($vf & 4)} { return 0 }
	s16 $d [expr {$r + 2 * (($vf & 1) + (($vf >> 1) & 1))}]
}

# Kerning between two glyphs, in font units (PairPos formats 1 and 2).
proc text::kern {f g1 g2} {
	set d [dict get $f gpos]
	set total 0
	foreach subs [dict get $f kern] {
		foreach st $subs {
			set cov [coverage $d [expr {$st + [u16 $d [expr {$st + 2}]]}] $g1]
			if {$cov < 0} continue
			set vf1 [u16 $d [expr {$st + 4}]]; set vf2 [u16 $d [expr {$st + 6}]]
			set rec [expr {2 + [vsize $vf1] + [vsize $vf2]}]
			if {[u16 $d $st] == 1} {
				set ps [expr {$st + [u16 $d [expr {$st + 10 + 2 * $cov}]]}]
				set lo 0; set hi [expr {[u16 $d $ps] - 1}]
				set found 0
				while {$lo <= $hi} {
					set m [expr {($lo + $hi) / 2}]
					set r [expr {$ps + 2 + $rec * $m}]
					set v [u16 $d $r]
					if {$g2 < $v} { set hi [expr {$m - 1}] } elseif {$g2 > $v} { set lo [expr {$m + 1}] } else {
						incr total [xadv $d [expr {$r + 2}] $vf1]; set found 1; break
					}
				}
				if {$found} break
				continue
			}
			set c1 [classof $d [expr {$st + [u16 $d [expr {$st + 8}]]}] $g1]
			set c2 [classof $d [expr {$st + [u16 $d [expr {$st + 10}]]}] $g2]
			incr total [xadv $d [expr {$st + 16 + ($c1 * [u16 $d [expr {$st + 14}]] + $c2) * ($rec - 2)}] $vf1]
			break
		}
	}
	return $total
}

# ---- layout and drawing ----------------------------------------------------------

# Where each letter of TEXT is drawn, in px from the left, and the width:
# {x0 x1 ... width}. LS: CSS letter-spacing, after every letter. TNUM:
# tabular figures (CSS font-variant-numeric: tabular-nums); Tk can only
# draw the proportional glyph, so it is centred in the tabular one's place.
# Letters the font file lacks (Tk draws them from another font) take
# Tk's own advance.
proc text::layout {font str {ls 0} {tnum 0}} {
	variable lay
	set key $font\x1f$str\x1f$ls\x1f$tnum
	if {[info exists lay($key)]} { return $lay($key) }
	if {[array size lay] > 4000} { array unset lay }
	variable g
	lassign [spec $font] fam px
	set f [parsed $fam]
	set xs {}
	set x 0.0
	if {$f eq ""} {
		foreach ch [split $str ""] { lappend xs $x; set x [expr {$x + [tkadv $font $ch] + $ls}] }
		lappend xs $x
		return [set lay($key) $xs]
	}
	set k [expr {double($px) / [dict get $f upem]}]
	set tn [expr {$tnum ? [dict get $f tnum] : {}}]
	set prev ""
	foreach ch [split $str ""] {
		if {![info exists g($fam,$ch)]} { set g($fam,$ch) [gid $f $ch] }
		set gl $g($fam,$ch)
		if {$gl == 0} {
			lappend xs $x
			set x [expr {$x + [tkadv $font $ch] + $ls}]
			set prev ""
			continue
		}
		set a [adv $fam $f $gl]
		set cell $a
		if {[dict exists $tn $gl]} { set gl [dict get $tn $gl]; set cell [adv $fam $f $gl] }
		if {$prev ne ""} {
			if {![info exists g(k,$fam,$prev,$gl)]} { set g(k,$fam,$prev,$gl) [kern $f $prev $gl] }
			set x [expr {$x + $g(k,$fam,$prev,$gl) * $k}]
		}
		lappend xs [expr {$x + ($cell - $a) * $k / 2.0}]
		set x [expr {$x + $cell * $k + $ls}]
		set prev $gl
	}
	lappend xs $x
	set lay($key) $xs
}

proc text::adv {fam f gl} {
	variable g
	if {![info exists g(a,$fam,$gl)]} { set g(a,$fam,$gl) [advance $f $gl] }
	return $g(a,$fam,$gl)
}

proc text::tkadv {font ch} {
	variable tk
	if {![info exists tk($font,$ch)]} { set tk($font,$ch) [::font measure $font $ch] }
	return $tk($font,$ch)
}

proc text::width {font str {ls 0} {tnum 0}} { lindex [layout $font $str $ls $tnum] end }

# TEXT cut to fit WIDTH (as CSS overflow: hidden cuts it).
proc text::clip {font str width} {
	set xs [layout $font $str]
	if {[lindex $xs end] <= $width} { return $str }
	set n [string length $str]
	while {$n > 0 && [lindex $xs $n] > $width} { incr n -1 }
	string range $str 0 [expr {$n - 1}]
}

# Draw TEXT on canvas C (see the top of the file). Returns its width.
proc text::draw {c x y font fill str {anchor w} args} {
	array set o {-ls 0 -tnum 0 -tags {}}
	array set o $args
	set xs [layout $font $str $o(-ls) $o(-tnum)]
	set w [lindex $xs end]
	switch -- $anchor {
		center - c { set left [expr {$x - $w / 2.0}]; set ta w }
		n { set left [expr {$x - $w / 2.0}]; set ta nw }
		s { set left [expr {$x - $w / 2.0}]; set ta sw }
		e - ne - se { set left [expr {$x - $w}]; set ta [string map {e w} $anchor] }
		default { set left $x; set ta $anchor }
	}
	# one item per run of letters that Tk's own advances keep within half a
	# pixel of where they belong
	set run ""; set rx 0; set tkw 0
	foreach ch [split $str ""] px [lrange $xs 0 end-1] {
		set px [expr {$left + $px}]
		if {$run ne "" && ($o(-ls) != 0 || abs($rx + $tkw - $px) > 0.5)} {
			$c create text $rx $y -text $run -font $font -fill $fill -anchor $ta -tags $o(-tags)
			set run ""
		}
		if {$run ne ""} {
			append run $ch; incr tkw [tkadv $font $ch]
		} elseif {$ch ne " "} {
			set run $ch; set rx [expr {round($px)}]; set tkw [tkadv $font $ch]
		}
	}
	if {$run ne ""} { $c create text $rx $y -text $run -font $font -fill $fill -anchor $ta -tags $o(-tags) }
	return $w
}
