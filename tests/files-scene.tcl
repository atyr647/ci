# files-scene.tcl - Ribbon Files drawn as the Files-* boards have it, and the flows behind
# them (sourced by the shell via RIBBON_SHELL_TEST; tests/steps.d/61-files-scene.sh runs it):
#   FILES_SCENE=list      ~/Documents in the list view, Budget.md selected (Files-List)
#   FILES_SCENE=thumbs    ~/Pictures/Iceland in the grid with thumbnails (Files-Grid-Thumbs);
#                         FILES_PHOTOS is a folder of the pictures to put there
#   FILES_SCENE=conflict  a paste that meets Budget.md, two more to come (Files-Conflict)
#   FILES_SCENE=marchive  the right-click menu on trip-photos.zip (Files-Menu-Archive)
#   FILES_SCENE=mcompress the right-click menu on five items (Files-Menu-Compress)
#   FILES_SCENE=flows     Replace, Keep both, Skip and "Same for the other N"; Extract here and
#                         Compress (with bsdtar); the thumbnail cache as the freedesktop spec has it
# FILES_SHOT: a grab of the screen once the scene is drawn. Exits 0 when every check passes.
proc bgerror {msg} { puts stderr "error: $msg\n$::errorInfo"; exit 1 }
set fails 0
proc check {what cond} {
	if {[catch {uplevel 1 [list expr $cond]} ok] || !$ok} { puts "  FAIL files: $what"; incr ::fails; return }
	puts "  ok   files: $what"
}
proc put {p data} { set fh [open $p wb]; puts -nonewline $fh $data; close $fh }
proc content {p} { if {![file isfile $p]} { return "" }; set fh [open $p rb]; set d [read $fh]; close $fh; return $d }
proc wait_for {cond ms} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel 1 [list expr $cond]] && [clock milliseconds] < $end} { after 40 {set ::tick 1}; vwait ::tick }
	uplevel 1 [list expr $cond]
}
proc settle {} { update; after 400 {set ::tick 1}; vwait ::tick; update }
proc shot {} {
	if {[info exists ::env(FILES_SHOT)]} { settle; exec import -window root $::env(FILES_SHOT) }
}
# a time today, yesterday, or on a day of this year
proc at {day hm} {
	set y [clock format [clock seconds] -format %Y]
	switch -- $day {
		today { set d [clock format [clock seconds] -format %Y-%m-%d] }
		yesterday { set d [clock format [clock add [clock seconds] -1 day] -format %Y-%m-%d] }
		default { set d "$y-$day" }
	}
	clock scan "$d $hm" -format "%Y-%m-%d %H:%M"
}
proc sized {p n} { exec truncate -s $n $p }

set scene [expr {[info exists ::env(FILES_SCENE)] ? $::env(FILES_SCENE) : "flows"}]
set H $::env(HOME)

# ~/Documents as Files-List has it
proc documents {} {
	set D [file join $::H Documents]
	file mkdir $D
	foreach {name n day} {Letters 14 11-02 Recipes 9 10-30 Work 27 today} {
		file mkdir $D/$name
		for {set i 1} {$i <= $n} {incr i} { put $D/$name/item$i.txt x }
		file mtime $D/$name [expr {$day eq "today" ? [at today 09:12] : [at $day 12:00]}]
	}
	foreach {name size day hm} {Budget.md 4200 today 13:52 {Packing list.txt} 812 11-06 10:00 Reading.md 2600 11-01 10:00
			{Taxes 2025.pdf} 318000 04-04 10:00 trip-photos.zip 212000000 yesterday 18:40} {
		put $D/$name ""
		sized $D/$name $size
		file mtime $D/$name [at $day $hm]
	}
	return $D
}

proc open_at {path view} {
	set w [files::show $path]
	wm geometry $w 840x580+300+160
	set files::st($w,view) $view
	update
	files::draw $w
	return $w
}

proc menu_at {w name X Y {hover ""}} {
	foreach t $files::st($w,tiles) { if {[lindex $t 4] eq $name} { lassign $t x0 y0 } }
	files::context $w [expr {$x0 + 10}] [expr {$y0 + 10 - [$w.main canvasy 0]}] $X $Y
	update
	if {$hover ne ""} { files::menu_hover .filesmenu $hover }
}

switch -- $scene {
	list {
		set w [open_at [documents] list]
		set files::st($w,sel) Budget.md; files::draw $w
		check "the list has a KIND column and folders' item counts" {[files::kindname Budget.md 0] eq "Markdown" && [files::count $H/Documents/Letters] == 14}
		check "the status bar names the selection" {[files::selline $files::st($w,items) Budget.md] eq "8 items · Budget.md selected, 4.2 KB"}
		check "dates are relative" {[files::when [at today 13:52]] eq "Today, 13:52" && [files::when [at yesterday 18:40]] eq "Yesterday, 18:40"}
		shot
	}
	thumbs {
		set P [file join $H Pictures Iceland]
		file mkdir $P/Drone $P/Panoramas $P/Edits
		foreach f [glob -directory $::env(FILES_PHOTOS) *.jpg] { file copy $f $P }
		sized [lindex [glob -directory $P J*.jpg] 0] 21600000
		set w [open_at $P grid]
		set files::st($w,sel) [file tail [lindex [glob -directory $P J*.jpg] 0]]; files::draw $w
		check "every picture's thumbnail is drawn" {[wait_for {[llength [array names files::thumbimg]] == 12} 60000]}
		set vik [lindex [glob -directory $P V*k.jpg] 0]
		check "the thumbnails are in the freedesktop cache with Thumb::URI and Thumb::MTime" {
			[dict get [files::pngtext [files::thumb_cached $vik]] Thumb::MTime] == [file mtime $vik]}
		files::draw $w
		shot
	}
	conflict {
		set D [documents]
		set S [file join $H incoming]; file mkdir $S
		foreach n {Budget.md Reading.md Work} { put $S/$n new }
		set w [open_at $D list]
		set files::st($w,sel) Budget.md; files::draw $w
		files::place $w copy [list $S/Budget.md $S/Reading.md $S/Work] $D
		update
		check "a taken name asks before anything is copied" {[winfo exists .filesconflict] && [content $D/Budget.md] ne "new"}
		shot
	}
	marchive {
		set w [open_at [documents] list]
		set files::st($w,sel) trip-photos.zip; files::draw $w
		menu_at $w trip-photos.zip 670 556 54
		shot
	}
	mcompress {
		set w [open_at [documents] list]
		set files::st($w,sel) {Budget.md {Packing list.txt} Reading.md {Taxes 2025.pdf} trip-photos.zip}; files::draw $w
		menu_at $w Reading.md 670 476 [expr {6 + 32 + 9 + 3 * 32 + 16}]
		check "five selected: Compress, no Extract here, Properties last" {
			[lsearch -index 1 -exact [lmap h $files::menuhits {list [lindex $h 0] [lindex $h 2]}] {}] < 0 &&
			[string match "files::compress *" [lindex $files::menuhits 4 2]] && [string match "files::props *" [lindex $files::menuhits end 2]]}
		shot
	}
	flows {
		set D [documents]
		set S [file join $H incoming]; file mkdir $S/Work
		foreach n {Budget.md Reading.md {Taxes 2025.pdf}} { put $S/$n new }
		put $S/Work/new.txt new
		set w [open_at $D list]
		# Replace for the first, Keep both for the second, Skip for the third
		files::place $w copy [list $S/Budget.md $S/Reading.md $S/Work] $D
		update
		check "the dialog asks about the first, two more to come" {[winfo exists .filesconflict] && [lindex $files::conflictq 3] == 2}
		lassign [lindex $files::conflictq 4 0] x0
		files::conflict_click [expr {$x0 + 5}] [expr {200 - 30}]
		check "Replace: the new one in place of the old" {[wait_for {[content $::D/Budget.md] eq "new"} 10000] && [llength [glob -nocomplain -directory $D .*.ribbon-*]] == 0}
		check "the second question follows" {[wait_for {[winfo exists .filesconflict]} 3000] && [file tail [lindex $files::conflictq 0 2]] eq "Reading.md"}
		lassign [lindex $files::conflictq 4 1] x0
		files::conflict_click [expr {$x0 + 5}] [expr {200 - 30}]
		check "Keep both: the copy under a free name, the old one kept" {[wait_for {[file exists "$::D/Reading (2).md"]} 10000] && [file size $D/Reading.md] == 2600}
		files::conflict_pick skip
		check "Skip: the folder is left alone" {[wait_for {![winfo exists .filesconflict]} 3000] && ![file exists $D/Work/new.txt] && ![file exists "$D/Work (2)"]}
		# the same for the rest
		foreach n {Budget.md Reading.md {Taxes 2025.pdf}} { put $S/$n newer }
		files::place $w copy [list $S/Budget.md $S/Reading.md "$S/Taxes 2025.pdf"] $D
		update
		files::conflict_click 30 100
		check "the box for the rest ticks" {$files::every == 1}
		files::conflict_pick replace
		check "Same for the other 2: all three replaced, one question" {[wait_for {[content "$::D/Taxes 2025.pdf"] eq "newer" && [content $::D/Reading.md] eq "newer" && [content $::D/Budget.md] eq "newer"} 15000] && ![winfo exists .filesconflict]}
		# a copy into its own folder keeps both without a question
		files::place $w copy [list $D/Budget.md] $D
		check "a copy into its own folder: Budget (2).md, no question" {![winfo exists .filesconflict] && [wait_for {[file exists "$::D/Budget (2).md"]} 10000]}
		if {[auto_execok bsdtar] ne ""} {
			file mkdir $H/arc/trip
			put $H/arc/trip/a.txt alpha; put $H/arc/b.txt beta
			files::compress $w [list $H/arc/trip $H/arc/b.txt]
			check "Compress: Archive.zip from two items" {[wait_for {[file exists $::H/arc/Archive.zip]} 10000] && [llength [glob -nocomplain -directory $H/arc .*.ribbon-*]] == 0}
			files::compress $w [list $H/arc/trip]
			check "Compress one item: NAME.zip" {[wait_for {[file exists $::H/arc/trip.zip]} 10000]}
			file rename $H/arc/Archive.zip $H/arc/trip-photos.zip
			files::extract $w $H/arc/trip-photos.zip
			check "Extract here: a folder named after the archive, everything in it" {[wait_for {[file isdirectory $::H/arc/trip-photos]} 10000] &&
				[content $H/arc/trip-photos/trip/a.txt] eq "alpha" && [content $H/arc/trip-photos/b.txt] eq "beta"}
			files::extract $w $H/arc/trip-photos.zip
			check "Extract again: a free name" {[wait_for {[file isdirectory "$::H/arc/trip-photos (2)"]} 10000]}
			put $H/arc/bad.zip "not a zip"
			files::extract $w $H/arc/bad.zip
			check "a broken archive: one line in the status bar, nothing left" {[wait_for {[string match "Couldn't extract bad.zip*" $::files::st($::w,status)]} 10000] &&
				![file exists $H/arc/bad] && [llength [glob -nocomplain -directory $H/arc .*.ribbon-*]] == 0}
			files::go $w $H/arc
			set files::st($w,sel) trip-photos.zip
			menu_at $w trip-photos.zip 600 300
			check "the archive's menu has Extract here and Compress" {[lsearch -glob [lmap h $files::menuhits {lindex $h 2}] "files::extract *"] == 1 &&
				[lsearch -glob [lmap h $files::menuhits {lindex $h 2}] "files::compress *"] > 0}
			destroy .filesmenu
		} else { puts "  skip files: Extract here and Compress (no bsdtar)" }
		# thumbnails: made once, current while the file is unchanged, made again when it changes
		if {[auto_execok ffmpeg] ne "" && [auto_execok convert] ne ""} {
			file mkdir $H/pics
			exec convert -size 400x300 gradient:orange-navy $H/pics/a.png
			set k [files::thumb $H/pics/a.png 83 55]
			check "a thumbnail is made in the background" {$k eq "" && [wait_for {[llength [array names files::thumbimg [list $::H/pics/a.png *]]]} 20000]}
			lassign [files::thumbfile $H/pics/a.png] uri f
			check "it is ~/.cache/thumbnails/normal/MD5(URI).png, at most 128 px, 0600" {[file exists $f] && [file attributes $f -permissions] eq "00600" &&
				[string match "*/thumbnails/normal/[files::md5 $uri].png" $f] && [exec identify -format %wx%h $f] eq "128x96"}
			set m0 [file mtime $f]
			after 1100
			file mtime $H/pics/a.png [expr {[file mtime $H/pics/a.png] - 100}]
			check "a changed file's thumbnail is stale" {[files::thumb_cached $H/pics/a.png] eq ""}
			files::thumb $H/pics/a.png 83 55
			check "and is made again" {[wait_for {[files::thumb_cached $::H/pics/a.png] ne ""} 20000]}
			put $H/pics/bad.png "not a picture"
			files::thumb $H/pics/bad.png 83 55
			lassign [files::thumbfile $H/pics/bad.png fail/ribbon-files] - ff
			check "a picture that cannot be read is noted in fail/ribbon-files" {[wait_for {[file exists $::ff]} 20000]}
			# the next start (nothing in memory): the fail entry is read, ffmpeg is not run again
			wait_for {!$::files::thumbbusy && ![llength $::files::thumbq]} 5000
			array unset files::thumbfail
			set ::ffruns 0
			rename files::thumb_made files::thumb_made_
			proc files::thumb_made {args} { incr ::ffruns; files::thumb_made_ {*}$args }
			files::thumb $H/pics/bad.png 83 55
			update
			check "the next start reads the fail entry and does not try again" {[wait_for {[info exists ::files::thumbfail($::H/pics/bad.png)]} 5000] && !$files::thumbbusy && $::ffruns == 0}
			rename files::thumb_made {}; rename files::thumb_made_ files::thumb_made
			# the cache's own pictures get no thumbnail of their own
			lassign [files::thumbfile $H/pics/a.png] - af
			files::thumb $af 83 55
			check "no thumbnail is made of a picture in the thumbnail cache" {[lsearch -index 0 -exact $files::thumbq $af] < 0 && !$files::thumbbusy}
		} else { puts "  skip files: thumbnails (no ffmpeg or convert)" }
	}
}
exit [expr {$fails ? 1 : 0}]
