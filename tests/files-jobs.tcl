# files-jobs.tcl - Ribbon Files' copy and move jobs (shell/files-jobs.tcl and the queue in
# shell/files.tcl): the progress notification as Notify-Final-3-Progress has it (its summary,
# items line, "1.2 of 3.4 GB", Pause and Cancel), Pause stopping the helper, Cancel leaving
# nothing behind, the last notification when the job is done, and Replace (fileop_sh's
# replace mode) killed before each of its steps. Plain tclsh, no display; the notification
# server is stood in for by recording what Files sends. tests/steps.d/61-files-jobs.sh runs it.

set here [file dirname [file normalize [info script]]]
# no Tk here: Files' windows do not exist
proc winfo {args} { return 0 }
source [file join $here .. srcpkgs ribbon-desktop files shell files.tcl]

set fails 0
proc check {what cond} {
	global fails
	if {[catch {uplevel 1 [list expr $cond]} ok] || !$ok} { puts "  FAIL jobs: $what"; incr fails; return }
	puts "  ok   jobs: $what"
}
proc put {p data} { set fh [open $p wb]; puts -nonewline $fh $data; close $fh }
proc content {p} { if {![file exists $p]} { return "" }; set fh [open $p rb]; set d [read $fh]; close $fh; return $d }
proc wait_for {cond ms} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel 1 [list expr $cond]] && [clock milliseconds] < $end} {
		after 50 {set ::tick 1}; vwait ::tick
	}
	uplevel 1 [list expr $cond]
}

# the server, stood in for: every Notify and CloseNotification Files sends
set sent {}
set closed {}
set nextid 40
proc files::notify_send {id summary body actions hints cb} {
	global sent nextid
	if {$id == 0} { set id [incr nextid] }
	lappend sent [dict create id $id summary $summary body $body actions $actions hints $hints]
	if {$cb ne ""} { after 0 [list {*}$cb $id] }
}
proc files::notify_close {id} { lappend ::closed $id }
proc files::drives {} { return {} }
proc hint {n k} { set h [dict get $n hints]; expr {[dict exists $h $k] ? [lindex [dict get $h $k] 1] : ""} }

# ---- the words -------------------------------------------------------------------------
check "one item is its name" {[files::itemline {saves.zip}] eq "saves.zip"}
check "three items as the board has them" {[files::itemline {{Hades II} Proton-GE\ 9-20 saves.zip}] eq "3 items · Hades II, Proton-GE 9-20 and saves.zip"}
check "five items name two" {[files::itemline {a b c d e}] eq "5 items · a, b and 3 more"}
check "bytes in the total's unit" {[files::of 1200000000 3400000000] eq "1.2 of 3.4 GB" && [files::of 0 512] eq "0 of 512 B" && [files::of 500000 2000000] eq "0.5 of 2 MB"}

# ---- a job: progress, Pause, Resume, done --------------------------------------------------
set T [string trim [exec mktemp -d]]
set src [file join $T src]; set dstdir [file join $T "Games SSD"]
file mkdir $src $dstdir
# cp stood in for by a slow one (the real cp, a file at a time), so the copy lasts a few seconds
set realcp [lindex [auto_execok cp] 0]
file mkdir [file join $T bin]
put [file join $T bin cp] [string map [list @CP@ $realcp] {#!/bin/sh
if [ "$1" = -a ] && [ "$2" = -- ] && [ -d "$3" ]; then
	mkdir -- "$4" || exit 1
	for f in "$3"/*; do sleep 0.01; @CP@ -a -- "$f" "$4/" || exit 1; done
	exit 0
fi
exec @CP@ "$@"
}]
file attributes [file join $T bin cp] -permissions 0755
set env(PATH) [file join $T bin]:$env(PATH)
set big [file join $src Proton-GE]
file mkdir $big
set N 400
set chunk [string repeat [binary format a* "ribbon jobs test 0123456789abcdef"] 1000]
for {set i 0} {$i < $N} {incr i} { put [file join $big f$i.bin] $chunk }
put [file join $src saves.zip] [string repeat z 5000]

files::transfer "" copy $big [file join $dstdir Proton-GE]
files::transfer "" copy [file join $src saves.zip] [file join $dstdir saves.zip]
check "a job starts with the first item and the second joins it" {[llength $files::job] && [llength [dict get $files::job names]] == 2}
check "the first notification: Copying to the folder, Pause and Cancel" {[wait_for {[llength $::sent] >= 1} 3000] &&
	[dict get [lindex $sent 0] summary] eq "Copying to Games SSD" && [dict get [lindex $sent 0] actions] eq {pause Pause cancel Cancel}}
check "the progress rises with the helper's done lines" {[wait_for {[hint [lindex $::sent end] value] > 0} 30000]}
set total [exec du -sb -- $big]
set total [expr {[lindex $total 0] + 5000}]
check "the items line and the size of the whole job under the bar" {[dict get [lindex $sent end] body] eq "2 items · Proton-GE and saves.zip" &&
	[string match "* of [lindex [files::of 0 $total] end-1] [lindex [files::of 0 $total] end]" [hint [lindex $sent end] x-ribbon-progress-text]]}
set id [dict get [lindex $sent end] id]
check "later notifications replace the first one" {$id > 40 && [lsearch -not -exact [lmap n [lrange $sent 1 end] {dict get $n id}] $id] < 0}

# Pause: the action as the server sends it back (ActionInvoked)
files::notify_invoked {} $id pause
set pids [pid $files::opch]
after 200
set stopped 1
foreach p [concat $pids [files::descendants [lindex $pids 0]]] {
	if {[catch {open /proc/$p/stat} fh]} continue
	set s [read $fh]; close $fh
	if {[lindex [string range $s [expr {[string last ")" $s] + 2}] end] 0] ni {T t Z}} { set stopped 0; puts "     not stopped: $s" }
}
check "Pause stops the helper and everything it runs" {$stopped}
check "a paused job offers Resume" {[wait_for {[dict get [lindex $::sent end] actions] eq {resume Resume cancel Cancel}} 2000]}
set part [file join $dstdir .Proton-GE.ribbon-part]
set a [exec du -sb -- $part]; after 900; set b [exec du -sb -- $part]
check "nothing is copied while it is paused" {$a eq $b}
files::notify_invoked {} $id resume
check "Resume goes on" {[dict get [lindex $sent end] actions] eq {pause Pause cancel Cancel}}
check "the job ends with Copied to and the items, no bar, no actions" {[wait_for {![llength $::files::job]} 60000] &&
	[dict get [lindex $sent end] summary] eq "Copied to Games SSD" && [dict get [lindex $sent end] actions] eq {} &&
	[hint [lindex $sent end] value] eq "" && [dict get [lindex $sent end] id] == $id}
check "both items arrived whole" {[llength [glob -directory [file join $dstdir Proton-GE] *]] == $N && [content [file join $dstdir saves.zip]] eq [content [file join $src saves.zip]]}
set vals [lmap n $sent {hint $n value}]
set rising 1; set last -1
foreach v $vals { if {$v eq ""} continue; if {$v < $last} { set rising 0 }; set last $v }
check "the bar never goes back" {$rising}

# ---- Cancel: nothing left, the queued items dropped ---------------------------------------------
set sent {}; set closed {}
file delete -force [file join $dstdir Proton-GE] [file join $dstdir saves.zip]
set failed 0
files::transfer "" copy $big [file join $dstdir Proton-GE]
files::transfer "" copy [file join $src saves.zip] [file join $dstdir saves.zip] "" {incr ::failed}
wait_for {[llength $::sent] >= 1 && [dict get [lindex $::sent end] id] > 0 && [file exists [file join $::dstdir .Proton-GE.ribbon-part]]} 10000
set id [dict get [lindex $sent end] id]
files::notify_invoked {} $id cancel
check "Cancel ends the job and closes its notification" {[wait_for {![llength $::files::job] && $::files::opch eq ""} 10000] && $closed eq [list $id]}
check "no Copied notification after a cancel" {[lsearch -exact [lmap n $sent {dict get $n summary}] "Copied to Games SSD"] < 0}
check "the cancelled copy left nothing, the waiting one never ran" {![file exists [file join $dstdir Proton-GE]] && ![file exists [file join $dstdir saves.zip]] &&
	[llength [glob -nocomplain -directory $dstdir .*.ribbon-*]] == 0 && $failed == 1}
check "the originals are untouched" {[llength [glob -directory $big *]] == $N && $files::pending eq {}}

# ---- Cancel touches only the job: an archive operation in the queue goes on, and its own error is shown ----
# bsdtar stood in for by a slow one, so the Compress is still running when Cancel comes
set realtar [lindex [auto_execok bsdtar] 0]
if {$realtar ne ""} {
	put [file join $T bin bsdtar] [string map [list @TAR@ $realtar] {#!/bin/sh
sleep 1.5
exec @TAR@ "$@"
}]
	file attributes [file join $T bin bsdtar] -permissions 0755
	set A [file join $T arc]; file mkdir $A
	put [file join $A a.txt] alpha
	set sent {}; set closed {}
	file delete -force [file join $dstdir Proton-GE]
	files::compress "" [list [file join $A a.txt]]
	files::transfer "" copy $big [file join $dstdir Proton-GE]
	check "the job's notification comes while the Compress before it runs" {[wait_for {[llength $::sent] >= 1 && [dict get [lindex $::sent end] id] > 0} 5000] &&
		[lindex $files::opcur 1] eq "Compressing"}
	files::notify_invoked {} [dict get [lindex $sent end] id] cancel
	check "Cancel of a copy leaves a Compress that was running alone" {[wait_for {[file exists [file join $::A a.txt.zip]] && $::files::opch eq ""} 15000] &&
		![file exists [file join $dstdir Proton-GE]] && [llength [glob -nocomplain -directory $dstdir .*.ribbon-*]] == 0}
	# after a Cancel, a new copy is a job of its own with its notification
	set sent {}
	files::compress "" [list [file join $A a.txt]]
	files::transfer "" copy $big [file join $dstdir Proton-GE]
	if {[wait_for {[llength $::sent] >= 1 && [dict get [lindex $::sent end] id] > 0} 5000]} { files::notify_invoked {} [dict get [lindex $sent end] id] cancel }
	set sent {}
	files::transfer "" copy [file join $src saves.zip] [file join $dstdir saves.zip]
	check "a copy queued after a Cancel has its own progress and Copied notification" {[wait_for {![llength $::files::job] && $::files::opch eq ""} 20000] &&
		[lsearch -exact [lmap n $sent {dict get $n summary}] "Copied to Games SSD"] >= 0 && [file exists [file join $dstdir saves.zip]]}
	file delete -force [file join $dstdir saves.zip] [file join $A a.txt.zip] [file join $A "a.txt (2).zip"]
	file delete [file join $T bin bsdtar]
	# a name that starts with @ is a file, not bsdtar's "@archive"
	put [file join $A @notes] "at sign"
	files::compress "" [list [file join $A @notes]]
	check "Compress keeps a file whose name starts with @, stored as its name" {[wait_for {$::files::opch eq "" && [file exists [file join $::A @notes.zip]]} 10000] &&
		[exec $realtar -tf [file join $A @notes.zip]] eq "@notes"}
}

# ---- Replace: old or new, never a mix, never neither ----------------------------------------------
proc run {op src dst {killat ""}} {
	if {$killat ne ""} { set ::env(RIBBON_FILEOP_KILL_AT) $killat } else { catch {unset ::env(RIBBON_FILEOP_KILL_AT)} }
	set rc [catch {exec {*}[files::fileop_cmd $op $src $dst replace] 2>@1} out]
	catch {unset ::env(RIBBON_FILEOP_KILL_AT)}
	return $rc
}
proc tree {d} { if {![file isdirectory $d]} { return [content $d] }; lsort [lmap f [glob -nocomplain -directory $d *] {list [file tail $f] [content $f]}] }
set R [file join $T rep]; file mkdir $R
put [file join $R new.txt] NEW
put [file join $R old.txt] OLD
check "Replace a file with a file: one rename over it" {[run copy [file join $R new.txt] [file join $R old.txt]] == 0 && [content [file join $R old.txt]] eq "NEW" &&
	[llength [glob -nocomplain -directory $R .*.ribbon-*]] == 0}
# folders: copy = cp, sync, verify, (rename to -old, rename into place, remove -old), dir sync
set ok 1
foreach op {copy move} {
	for {set k 1} {$k <= 8} {incr k} {
		file delete -force [file join $R nd] [file join $R od]
		file mkdir [file join $R nd] [file join $R od]
		put [file join $R nd a] new-a; put [file join $R nd b] new-b
		put [file join $R od a] old-a; put [file join $R od c] old-c
		set new [tree [file join $R nd]]; set old [tree [file join $R od]]
		run $op [file join $R nd] [file join $R od] $k
		files::clear_parts $R
		set now [tree [file join $R od]]
		set left [glob -nocomplain -directory $R .*.ribbon-*]
		set srcok [expr {[file exists [file join $R nd]] ? [tree [file join $R nd]] eq $new : $now eq $new}]
		if {!(($now eq $new || $now eq $old) && $srcok && ![llength $left])} {
			puts "     $op killed before step $k: [list $now] left $left"; set ok 0
		}
	}
}
check "Replace a folder, killed before each step: the old one or the new one, never a mix or neither" {$ok}
file delete -force [file join $R nd] [file join $R od]
file mkdir [file join $R nd] [file join $R od]
put [file join $R nd x] X; put [file join $R od y] Y
check "Replace a folder runs through: the new one only" {[run move [file join $R nd] [file join $R od]] == 0 && [tree [file join $R od]] eq [list [list x X]] && ![file exists [file join $R nd]]}

file delete -force $T
if {$fails} { puts "files jobs: $fails failed"; exit 1 }
exit 0
