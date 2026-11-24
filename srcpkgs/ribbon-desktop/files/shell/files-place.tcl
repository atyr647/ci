# files-place.tcl - where a paste or a drop puts things in Ribbon Files, and the
# archives' Extract here and Compress (bsdtar).
#
# A name that is taken asks first (Files-Conflict, the STYLE §15 dialog that
# Chooser-Save-Replace has): Replace, Keep both ("name (2)") or Skip, and, when
# more names are taken, "Same for the other N". Replace goes through fileop_sh's
# replace mode: nothing is overwritten before the new one is whole beside it.
# A copy into its own folder keeps both without asking, and nothing replaces a
# folder it came out of.
#
# Extract here makes a folder named after the archive (trip-photos.zip ->
# trip-photos); Compress makes NAME.zip from one item, Archive.zip from several.
# Both run in the background queue and, as copies do, build under
# .NAME.ribbon-part and rename into place at the end.

namespace eval files {
	variable asking {}       ;# the questions still to ask: {w op path dir track}
}

# Copy or move PATHS into DIR; TRACK: a move tells Opens with (openwith::moved).
proc files::place {w op paths dir {track 0}} {
	variable pending
	variable asking
	set dir [file normalize $dir]
	set clashes {}
	foreach p $paths {
		set p [file normalize $p]
		set name [file tail $p]
		set target [file join $dir $name]
		if {$target eq $p} {
			# into its own folder: a copy keeps both, a move has nothing to do
			if {$op eq "copy"} { transfer $w copy $p [file join $dir [freename $dir $name]] }
			continue
		}
		if {[file exists $target] || ![catch {file lstat $target _}] || $target in $pending} {
			lappend clashes [list $w $op $p $dir $track]
		} else {
			put $w $op $p $target $track
		}
	}
	if {[llength $clashes]} {
		set idle [expr {![llength $asking]}]
		lappend asking {*}$clashes
		if {$idle} { ask_next }
	}
}

proc files::put {w op p dst track {mode ""}} {
	set done [expr {$op eq "move" && $track ? [list openwith::moved $p $dst] : ""}]
	transfer $w $op $p $dst $done "" $mode
}

# One answer for one taken name: replace, keep or skip.
proc files::resolve {q choice} {
	lassign $q w op p dir track
	set target [file join $dir [file tail $p]]
	switch -- $choice {
		replace {
			# never a folder the item is inside, and never one still being made
			if {[string first $target/ $p/] == 0 || $target in $::files::pending} { set choice keep } else { put $w $op $p $target $track replace }
		}
	}
	if {$choice eq "keep"} { put $w $op $p [file join $dir [freename $dir [file tail $p]]] $track }
}

# Ask about the next taken name, or answer it with the choice made for all.
proc files::ask_next {{all ""}} {
	variable asking
	while {[llength $asking]} {
		set asking [lassign $asking q]
		if {$all ne ""} { resolve $q $all; continue }
		conflict $q [llength $asking]
		return
	}
	refresh_all
}

# The answer from the dialog: CHOICE for Q, and for the rest when EVERY.
proc files::answer {q choice every} {
	destroy .filesconflict
	resolve $q $choice
	ask_next [expr {$every ? $choice : ""}]
	refresh_all
}

# ---- the dialog (Files-Conflict) -------------------------------------------------------------

proc files::conflict {q rest} {
	variable conflictq
	variable every 0
	lassign $q w op p dir
	array set c [array get theme::c]
	set d .filesconflict
	destroy $d
	looks
	rbn::surface $d -fill $c(BAR)
	set W 480; set H [expr {$rest ? 200 : 160}]
	set conflictq [list $q $W $H $rest]
	set name [file tail $p]
	# the head: the tile (44, radius 12), the question, where it is
	rbn::box $d.c 28 26 44 44 -fill $c(PILL) -radius 12 -ring [list $c(BORDER) 1] -on $c(BAR)
	bar::icon $d.c [expr {[file isdirectory $p] ? "folder" : "file"}] 22 1.7 $c(FG) 39 37
	text::draw $d.c 86 39 f20g $c(FG) [bar::clip f20g "Replace “$name”?" [expr {$W - 86 - 28}]] w
	text::draw $d.c 86 61 f13 $c(MUTED) [bar::clip f13 "It is already in [destlabel $dir]" [expr {$W - 86 - 28}]] w
	if {$rest} { conflict_check $d 0 $rest }
	# the foot: a rule, Skip, Keep both, Replace (the primary), right aligned
	set fy [expr {$H - 72}]
	$d.c create line 0 [expr {$fy + 0.5}] $W [expr {$fy + 0.5}] -fill $c(BORDER)
	set x [expr {$W - 28}]
	set hits {}
	foreach {label kind choice} {Replace primary replace {Keep both} ghost keep Skip ghost skip} {
		set f [expr {$kind eq "primary" ? "f14s" : "f14"}]
		set bw [expr {round([text::width $f $label] + 36)}]
		set x [expr {$x - $bw}]
		if {$kind eq "primary"} {
			rbn::box $d.c $x [expr {$fy + 17}] $bw 38 -fill $c(ACCENT) -radius 10 -on $c(BAR)
			text::draw $d.c [expr {$x + $bw / 2.0}] [expr {$fy + 36}] $f $c(ON_ACCENT) $label center
		} else {
			rbn::box $d.c $x [expr {$fy + 17}] $bw 38 -fill $c(BAR) -radius 10 -ring [list $c(BORDER) 1] -on $c(BAR)
			text::draw $d.c [expr {$x + $bw / 2.0}] [expr {$fy + 36}] $f $c(FG) $label center
		}
		lappend hits [list $x [expr {$x + $bw}] $choice]
		set x [expr {$x - 10}]
	}
	lappend conflictq $hits
	bind $d.c <Button-1> [list files::conflict_click %x %y]
	bind $d <Return> {files::conflict_pick replace}
	bind $d <Escape> {files::conflict_pick skip}
	if {[winfo exists $w]} {
		set x [expr {[winfo rootx $w] + ([winfo width $w] - $W) / 2}]
		set y [expr {[winfo rooty $w] + ([winfo height $w] - $H) / 2}]
	} else {
		set x [expr {([winfo screenwidth .] - $W) / 2}]; set y [expr {([winfo screenheight .] - $H) / 2}]
	}
	rbn::popup $d $x $y $W $H [theme::look pop -radius 16]
	update idletasks
	catch {grab $d}
	focus -force $d
}

proc files::conflict_check {d on rest} {
	array set c [array get theme::c]
	$d.c delete every
	if {$on} {
		rbn::box $d.c 28 92 18 18 -fill $c(ACCENT) -radius 5 -on $c(BAR) -tags every
		$d.c create image 31 95 -image [theme::icon check 12 2.6 $c(ON_ACCENT)] -anchor nw -tags every
	} else {
		rbn::box $d.c 28 92 18 18 -fill $c(FIELD) -radius 5 -ring [list $c(BORDER) 1] -on $c(BAR) -tags every
	}
	text::draw $d.c 56 101 f13 $c(FG) "Same for the other $rest" w -tags every
}

proc files::conflict_click {x y} {
	variable conflictq
	variable every
	lassign $conflictq q W H rest hits
	if {$rest && $y >= 88 && $y < 114 && $x >= 28 && $x < 56 + [text::width f13 "Same for the other $rest"]} {
		set every [expr {!$every}]
		conflict_check .filesconflict $every $rest
		return
	}
	if {$y < $H - 55 || $y >= $H - 17} return
	foreach h $hits {
		lassign $h x0 x1 choice
		if {$x >= $x0 && $x < $x1} { conflict_pick $choice; return }
	}
}

proc files::conflict_pick {choice} {
	variable conflictq
	variable every
	answer [lindex $conflictq 0] $choice $every
}

# ---- archives ------------------------------------------------------------------------------

proc files::archive {name} {
	expr {[string match -nocase *.zip $name] || [regexp -nocase {\.(tar|tgz|tbz2|txz|tzst|7z|rar|cpio|xar|cab|lha|lzh)$} $name]
		|| [regexp -nocase {\.tar\.(gz|bz2|xz|zst|lz|lzma|lz4|z)$} $name]}
}

# trip-photos.zip -> trip-photos, src.tar.gz -> src
proc files::archive_stem {name} {
	if {[regexp -nocase {^(.+)\.tar\.[a-z0-9]+$} $name -> stem]} { return $stem }
	set stem [file rootname $name]
	expr {$stem eq "" ? $name : $stem}
}

namespace eval files {
	# ribbon-archive extract ARCHIVE DST | compress DST DIR NAME...: built in .DST.ribbon-part, renamed into place
	variable archive_sh {#!/bin/sh
set -u
dst=$2
dir=${dst%/*}
base=${dst##*/}
tmp=$dir/.$base.ribbon-part
fail() { rm -rf -- "$tmp"; printf '%s\n' "$1" >&2; exit 1; }
reason() { r=$(printf '%s' "$1" | grep -v '^$' | tail -n 1); printf '%s' "${r##*: }"; }
rm -rf -- "$tmp"
case $1 in
extract)
	a=$3 name=${3##*/}
	mkdir -- "$tmp" || fail "Couldn't extract $name: the folder can't be written to"
	err=$(bsdtar -x -f "$a" -C "$tmp" 2>&1) || fail "Couldn't extract $name: $(reason "$err")"
	;;
compress)
	src=$3
	shift 3
	# the names come as ./NAME (not bsdtar's @ARCHIVE); the entries are stored without the ./
	err=$(cd "$src" && bsdtar -c --format zip -s '|^\./||S' -f "$tmp" -- "$@" 2>&1) || fail "Couldn't compress: $(reason "$err")"
	;;
*) fail "unknown archive operation" ;;
esac
sync -- "$tmp" 2>/dev/null
err=$(mv -n -T -- "$tmp" "$dst" 2>&1) || fail "Couldn't finish $base: $(reason "$err")"
[ -e "$tmp" ] && fail "Couldn't finish $base: it is already there"
exit 0
}
}

proc files::archive_cmd {args} {
	variable archive_sh
	list sh -c $archive_sh ribbon-archive {*}$args
}

proc files::extract {w a} {
	set dir [file dirname $a]
	set dst [file join $dir [freename $dir [archive_stem [file tail $a]]]]
	queue $w Extracting [file tail $a] [archive_cmd extract $dst $a] $dst ""
	if {[winfo exists $w]} { load $w; draw $w }
}

proc files::compress {w paths} {
	if {![llength $paths]} return
	set dir [file dirname [lindex $paths 0]]
	set name [expr {[llength $paths] == 1 ? "[file tail [lindex $paths 0]].zip" : "Archive.zip"}]
	set dst [file join $dir [freename $dir $name]]
	# ./NAME: a name that starts with @ is bsdtar's "the entries of that archive" otherwise
	queue $w Compressing [file tail $dst] [archive_cmd compress $dst $dir {*}[lmap p $paths {string cat ./ [file tail $p]}]] $dst ""
	if {[winfo exists $w]} { load $w; draw $w }
}
