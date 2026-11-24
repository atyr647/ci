# files-watch.tcl - Ribbon Files' folder watch (ribbon-fswatch, shell/files.tcl) and the
# background copy's status and clean-up, inside the shell (RIBBON_SHELL_TEST, with HOME in a
# temp folder). tests/steps.d/63-files-watch.sh runs it once per mode, set in
# RIBBON_FILES_WATCH_MODE: real (the helper on PATH), refuse (a helper that refuses every
# folder), dies (a helper that exits), none (no helper). Exits 0 when every check passes.
proc bgerror {msg} { puts stderr "error: $msg\n$::errorInfo"; exit 1 }
set fails 0
proc check {what cond} {
	global fails
	if {[catch {uplevel 1 [list expr $cond]} ok] || !$ok} { puts "  FAIL watch: $what"; incr fails; return }
	puts "  ok   watch: $what"
}
# run the event loop until EXPR is true; returns the milliseconds it took, or -1 at MS
proc waitfor {ms expr} {
	set t0 [clock milliseconds]
	while {1} {
		update
		if {[uplevel 1 [list expr $expr]]} { return [expr {[clock milliseconds] - $t0}] }
		if {[clock milliseconds] - $t0 > $ms} { return -1 }
		after 10
	}
}
proc names {w} { lmap i $files::st($w,items) { lindex $i 0 } }
# inotify watches held by the helper: one line per watch in its fdinfo
proc watchcount {pid} {
	set n 0
	foreach fd [glob -nocomplain /proc/$pid/fd/*] {
		if {[catch {file readlink $fd} l] || $l ne "anon_inode:inotify"} continue
		set f [open /proc/$pid/fdinfo/[file tail $fd]]
		foreach line [split [read $f] \n] { if {[string match "inotify wd:*" $line]} { incr n } }
		close $f
	}
	return $n
}

set mode $::env(RIBBON_FILES_WATCH_MODE)
set root [file join $::env(HOME) watch]
file delete -force $root
file mkdir $root/a $root/b
set w [files::show $root/a]
update

# the watch comes up (real) or the windows poll (the others)
if {$mode eq "real"} {
	check "the folder is watched: the helper confirmed it" {[waitfor 2000 {$files::st($w,live)}] >= 0}
	check "a watched window has no poll scheduled" {[waitfor 2000 {$files::st($w,pollid) eq ""}] >= 0 || $files::st($w,pollid) eq ""}
	after 1700
	check "after 1.7 s the watched window still has no poll (the timer stopped)" {$files::st($w,pollid) eq ""}
	set pid [lindex [pid $files::fsw] 0]
	check "one watch for the one folder shown" {[watchcount $pid] == 1}
} else {
	check "$mode: the window does not claim a watch" {$files::st($w,live) == 0}
	check "$mode: the window polls" {$files::st($w,pollid) ne ""}
}

# create, rename and delete in the watched folder: the grid follows
# the poll compares whole-second mtimes: give each change its own second
if {$mode ne "real"} { after 1100 }
file mkdir $root/a/new-folder
set fh [open $root/a/one.txt w]; puts $fh x; close $fh
if {$mode eq "real"} {
	set t [waitfor 1000 {[lsearch [names $w] one.txt] >= 0}]
	check "a new file shows within a second, without the poll ([set t] ms)" {$t >= 0}
} else {
	check "$mode: a new file shows (polled, within 3 s)" {[waitfor 3000 {[lsearch [names $w] one.txt] >= 0}] >= 0}
}
if {$mode ne "real"} { after 1100 }
file rename $root/a/one.txt $root/a/two.txt
if {$mode eq "real"} {
	check "a rename shows within a second" {[waitfor 1000 {[lsearch [names $w] two.txt] >= 0 && [lsearch [names $w] one.txt] < 0}] >= 0}
} else {
	check "$mode: a rename shows (polled)" {[waitfor 3000 {[lsearch [names $w] two.txt] >= 0 && [lsearch [names $w] one.txt] < 0}] >= 0}
}
if {$mode ne "real"} { after 1100 }
file delete $root/a/two.txt
if {$mode eq "real"} {
	check "a delete shows within a second" {[waitfor 1000 {[lsearch [names $w] two.txt] < 0}] >= 0}
} else {
	check "$mode: a delete shows (polled)" {[waitfor 3000 {[lsearch [names $w] two.txt] < 0}] >= 0}
}

# navigation moves the watch: only the folder shown is watched
files::go $w $root/b
if {$mode eq "real"} {
	check "navigating watches the new folder and drops the old" \
		{[waitfor 2000 {$files::st($w,live)}] >= 0 && $files::fswpaths eq [list $root/b]}
	# 100 folders in turn: the helper never holds more than the folder shown
	for {set i 0} {$i < 100} {incr i} { file mkdir $root/b/d$i; files::go $w $root/b/d$i }
	check "100 folders in turn: one watch, as before" \
		{[waitfor 1500 {[watchcount $pid] == 1}] >= 0 && [llength $files::fswpaths] == 1}
	files::go $w $root/b
	waitfor 1000 {$files::st($w,live)}
}

# the folder opened clears what a killed copy left in it
set fh [open $root/b/.half.txt.ribbon-part w]; puts $fh partial; close $fh
set fh [open $root/b/.half.txt.ribbon-gone w]; puts $fh partial; close $fh
files::go $w $root/b
check "opening the folder removes .NAME.ribbon-part and .NAME.ribbon-gone" \
	{![file exists $root/b/.half.txt.ribbon-part] && ![file exists $root/b/.half.txt.ribbon-gone]}

# a background copy that fails says why, in one line, and leaves the source
set fh [open $root/a/keep.txt w]; puts $fh keep; close $fh
files::transfer $w copy $root/a/keep.txt $root/missing/keep.txt
check "a failed copy in the background shows one line" \
	{[waitfor 4000 {[string match "Couldn't copy keep.txt*" $files::st($w,status)]}] >= 0}
check "the failed copy leaves the source" {[file exists $root/a/keep.txt] && ![file exists $root/missing/keep.txt]}

# a move across filesystems: queued, verified, the source removed at the end, DONE runs
set shm [file join /dev/shm ribbon-watch-[pid]]
if {[file isdirectory /dev/shm] && ![catch {file mkdir $shm}]} {
	set ::moved_done 0
	files::transfer $w move $root/a/keep.txt $shm/keep.txt [list set ::moved_done 1]
	check "a move across filesystems finishes in the background" \
		{[waitfor 4000 {$::moved_done}] >= 0 && [file exists $shm/keep.txt] && ![file exists $root/a/keep.txt]}
	check "and the copy is the same file" {[file size $shm/keep.txt] == 5}
	file delete -force $shm
} else {
	puts "  skip watch: no second filesystem (/dev/shm)"
}

if {$fails} { puts "files-watch: $fails checks failed"; exit 1 }
puts "files-watch: all checks passed"
exit 0
